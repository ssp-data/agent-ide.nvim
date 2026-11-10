//! Session discovery and per-session metadata (port of `lua/agent-ide/index/lua_scan.lua`).
//!
//! Title rule, identical in Lua: the last `aiTitle` in the last 256 KiB (its first, possibly
//! partial, line ignored), else the last one in the first 256 KiB, else the first prompt in the
//! first 256 KiB, else `(untitled)`. A file of 512 KiB or less is read whole and its last
//! `aiTitle` anywhere wins. cwd and branch come from the first 256 KiB. Files are never read
//! beyond these two windows.
use crate::cache::Cache;
use crate::events::{is_space, parse_line};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::UNIX_EPOCH;

const WINDOW: usize = 256 * 1024;
const TITLE_MAX: usize = 60;
const UNTITLED: &str = "(untitled)";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMeta {
    pub id: String,
    pub path: String,
    pub cwd: Option<String>,
    pub title: String,
    pub branch: Option<String>,
    pub mtime: u64,
    pub size: u64,
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    let Some(&first) = needle.first() else { return true };
    let mut from = 0;
    while let Some(p) = hay[from..].iter().position(|b| *b == first) {
        let at = from + p;
        if hay[at..].starts_with(needle) {
            return true;
        }
        from = at + 1;
    }
    false
}

fn decode(line: &[u8]) -> Option<Value> {
    let fixed = String::from_utf8_lossy(line);
    serde_json::from_slice::<Value>(fixed.as_bytes()).ok().filter(|v| matches!(v, Value::Object(_) | Value::Array(_)))
}

fn nonempty_str<'a>(rec: &'a Value, key: &str) -> Option<&'a str> {
    match rec.get(key) {
        Some(Value::String(s)) if !s.is_empty() => Some(s),
        _ => None,
    }
}

/// Lua `gsub('%s*\n%s*', ' ')`: every whitespace run that contains a newline becomes one space.
fn collapse_newlines(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut run = String::new();
    let mut run_has_nl = false;
    let flush = |out: &mut String, run: &mut String, nl: &mut bool| {
        if *nl {
            out.push(' ');
        } else {
            out.push_str(run);
        }
        run.clear();
        *nl = false;
    };
    for c in s.chars() {
        if c.is_ascii() && is_space(c as u8) {
            run.push(c);
            run_has_nl |= c == '\n';
        } else {
            flush(&mut out, &mut run, &mut run_has_nl);
            out.push(c);
        }
    }
    flush(&mut out, &mut run, &mut run_has_nl);
    out
}

fn default_meta(path: &str, mtime: u64, size: u64) -> SessionMeta {
    let tail = path.rsplit('/').next().unwrap_or(path);
    let id = tail.strip_suffix(".jsonl").unwrap_or(tail).to_string();
    SessionMeta { id, path: path.to_string(), cwd: None, title: UNTITLED.into(), branch: None, mtime, size }
}

fn first_prompt_text(line: &[u8]) -> Option<String> {
    for ev in parse_line(line) {
        if ev["kind"] != "prompt" || ev.get("sidechain").is_some() {
            continue;
        }
        if let Value::String(t) = &ev["text"] {
            if t.bytes().any(|b| !is_space(b)) {
                return Some(t.clone());
            }
        }
    }
    None
}

fn lines(b: &[u8]) -> impl Iterator<Item = &[u8]> {
    b.split(|c| *c == b'\n').filter(|l| !l.is_empty())
}

/// The last non-empty `aiTitle` of an ai-title record among the lines of `b`.
fn last_ai_title(b: &[u8]) -> Option<String> {
    lines(b).filter(|l| contains(l, b"\"aiTitle\"")).filter_map(ai_title_of).last()
}

fn ai_title_of(line: &[u8]) -> Option<String> {
    let rec = decode(line)?;
    if rec.get("type").and_then(Value::as_str) != Some("ai-title") {
        return None;
    }
    nonempty_str(&rec, "aiTitle").map(String::from)
}

/// What metadata is read from: the first `WINDOW` bytes, and either the whole file (when it is
/// `2 * WINDOW` bytes or less) or its last `WINDOW` bytes.
pub enum Windows<'a> {
    Whole(&'a [u8]),
    HeadTail(&'a [u8], &'a [u8]),
}

pub fn meta_from_windows(path: &str, mtime: u64, size: u64, w: Windows) -> SessionMeta {
    let mut meta = default_meta(path, mtime, size);
    let head = match w {
        Windows::Whole(all) => &all[..all.len().min(WINDOW)],
        Windows::HeadTail(h, _) => h,
    };
    let mut first_prompt: Option<String> = None;
    for line in lines(head) {
        if meta.cwd.is_none() && contains(line, b"\"cwd\"") {
            if let Some(rec) = decode(line) {
                if let Some(cwd) = nonempty_str(&rec, "cwd") {
                    meta.cwd = Some(cwd.to_string());
                    meta.branch = nonempty_str(&rec, "gitBranch").map(String::from);
                }
            }
        }
        if first_prompt.is_none() && contains(line, b"\"user\"") {
            first_prompt = first_prompt_text(line);
        }
        if meta.cwd.is_some() && first_prompt.is_some() {
            break;
        }
    }
    let ai_title = match w {
        Windows::Whole(all) => last_ai_title(all),
        Windows::HeadTail(h, tail) => {
            let rest = tail.iter().position(|c| *c == b'\n').map_or(&tail[tail.len()..], |p| &tail[p + 1..]);
            last_ai_title(rest).or_else(|| last_ai_title(h))
        }
    };
    if let Some(t) = ai_title {
        meta.title = t;
    } else if let Some(p) = first_prompt {
        meta.title = collapse_newlines(&p).chars().take(TITLE_MAX).collect();
    }
    meta
}

/// Metadata of a transcript held in memory (applies the same windows as `read_meta`).
pub fn meta_from_bytes(path: &str, mtime: u64, size: u64, bytes: &[u8]) -> SessionMeta {
    if bytes.len() <= 2 * WINDOW {
        meta_from_windows(path, mtime, size, Windows::Whole(bytes))
    } else {
        meta_from_windows(path, mtime, size, Windows::HeadTail(&bytes[..WINDOW], &bytes[bytes.len() - WINDOW..]))
    }
}

fn read_windows(f: &mut std::fs::File) -> std::io::Result<(Vec<u8>, Option<Vec<u8>>)> {
    let len = f.seek(SeekFrom::End(0))?;
    f.seek(SeekFrom::Start(0))?;
    if len <= (2 * WINDOW) as u64 {
        let mut all = Vec::with_capacity(len as usize);
        f.read_to_end(&mut all)?;
        return Ok((all, None));
    }
    let mut head = Vec::with_capacity(WINDOW);
    f.by_ref().take(WINDOW as u64).read_to_end(&mut head)?;
    f.seek(SeekFrom::Start(len - WINDOW as u64))?;
    let mut tail = Vec::with_capacity(WINDOW);
    f.read_to_end(&mut tail)?;
    Ok((head, Some(tail)))
}

/// Reads the file's windows; an unreadable file gives the default `(untitled)` meta.
pub fn read_meta(path: &Path, mtime: u64, size: u64) -> SessionMeta {
    let p = path.to_string_lossy();
    let read = std::fs::File::open(path).and_then(|mut f| read_windows(&mut f));
    match read {
        Ok((all, None)) => meta_from_windows(&p, mtime, size, Windows::Whole(&all)),
        Ok((head, Some(tail))) => meta_from_windows(&p, mtime, size, Windows::HeadTail(&head, &tail)),
        Err(_) => default_meta(&p, mtime, size),
    }
}

/// `*.jsonl` files directly inside each sub-directory of `projects_dir`, sorted by path.
pub fn list_files(projects_dir: &str) -> Vec<String> {
    let mut files = Vec::new();
    let Ok(top) = std::fs::read_dir(projects_dir) else { return files };
    for entry in top.flatten() {
        let sub = format!("{}/{}", projects_dir, entry.file_name().to_string_lossy());
        // metadata() follows symlinks, like the Lua isdirectory() check.
        if !std::fs::metadata(&sub).map(|m| m.is_dir()).unwrap_or(false) {
            continue;
        }
        let Ok(inner) = std::fs::read_dir(&sub) else { continue };
        for f in inner.flatten() {
            let name = f.file_name().to_string_lossy().into_owned();
            if name.ends_with(".jsonl") && f.file_type().map(|t| t.is_file() || t.is_symlink()).unwrap_or(false) {
                files.push(format!("{sub}/{name}"));
            }
        }
    }
    files.sort();
    files
}

/// Scans every session under `projects_dir`. `reads` counts files actually read (cache misses).
pub fn scan(projects_dir: &Path, cache: Option<&mut Cache>, reads: &AtomicUsize) -> Vec<SessionMeta> {
    let dir = projects_dir.to_string_lossy().into_owned();
    let files = list_files(&dir);
    let cached: Option<&Cache> = cache.as_deref();
    let sessions: Vec<SessionMeta> = files
        .par_iter()
        .filter_map(|p| {
            let st = std::fs::metadata(p).ok()?;
            let mtime = st.modified().ok()?.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let size = st.len();
            if let Some(hit) = cached.and_then(|c| c.get(p, mtime, size)) {
                return Some(hit.clone());
            }
            reads.fetch_add(1, Ordering::SeqCst);
            Some(read_meta(Path::new(p), mtime, size))
        })
        .collect();
    if let Some(c) = cache {
        let seen: HashSet<&str> = sessions.iter().map(|s| s.path.as_str()).collect();
        c.forget_missing_under(&dir, &seen);
        for s in &sessions {
            c.insert(s.clone());
        }
        c.save();
    }
    sessions
}

#[cfg(test)]
mod tests;
