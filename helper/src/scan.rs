//! Session discovery and per-session metadata (port of `lua/agent-ide/index/lua_scan.lua`).
//!
//! Intended difference from the Lua fallback: the title is the last `aiTitle` anywhere in the
//! file, not only in the first 256 KiB. Everything else (cwd, branch, first-prompt title) is
//! looked up in the same 256 KiB head window as in Lua so both backends agree.
use crate::cache::Cache;
use crate::events::{is_space, parse_line};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Cursor};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::UNIX_EPOCH;

const HEAD_WINDOW: usize = 256 * 1024;
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
    serde_json::from_slice::<Value>(line).ok().filter(|v| matches!(v, Value::Object(_) | Value::Array(_)))
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

/// Metadata from a stream of transcript lines.
pub fn meta_from_reader<R: BufRead>(path: &str, mtime: u64, size: u64, mut reader: R) -> SessionMeta {
    let mut meta = default_meta(path, mtime, size);
    let (mut ai_title, mut first_prompt): (Option<String>, Option<String>) = (None, None);
    let mut buf = Vec::new();
    let mut offset = 0usize;
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let start = offset;
                offset += n;
                let line: &[u8] = if buf.last() == Some(&b'\n') { &buf[..buf.len() - 1] } else { &buf };
                if line.is_empty() {
                    continue;
                }
                let head: Option<&[u8]> = (start < HEAD_WINDOW).then(|| &line[..line.len().min(HEAD_WINDOW - start)]);
                if let Some(h) = head {
                    if meta.cwd.is_none() && contains(h, b"\"cwd\"") {
                        if let Some(rec) = decode(h) {
                            if let Some(cwd) = nonempty_str(&rec, "cwd") {
                                meta.cwd = Some(cwd.to_string());
                                meta.branch = nonempty_str(&rec, "gitBranch").map(String::from);
                            }
                        }
                    }
                    if contains(h, b"\"aiTitle\"") {
                        if let Some(t) = ai_title_of(h) {
                            ai_title = Some(t);
                        }
                    } else if first_prompt.is_none() && contains(h, b"\"user\"") {
                        first_prompt = first_prompt_text(h);
                    }
                }
                // Part of the line beyond the Lua head window: only the title is looked up there.
                if head.map_or(true, |h| h.len() < line.len()) && contains(line, b"\"aiTitle\"") {
                    if let Some(t) = ai_title_of(line) {
                        ai_title = Some(t);
                    }
                }
            }
        }
    }
    if let Some(t) = ai_title {
        meta.title = t;
    } else if let Some(p) = first_prompt {
        meta.title = collapse_newlines(&p).chars().take(TITLE_MAX).collect();
    }
    meta
}

fn ai_title_of(line: &[u8]) -> Option<String> {
    let rec = decode(line)?;
    if rec.get("type").and_then(Value::as_str) != Some("ai-title") {
        return None;
    }
    nonempty_str(&rec, "aiTitle").map(String::from)
}

pub fn meta_from_bytes(path: &str, mtime: u64, size: u64, bytes: &[u8]) -> SessionMeta {
    meta_from_reader(path, mtime, size, Cursor::new(bytes))
}

/// Reads the file; an unreadable file gives the default `(untitled)` meta.
pub fn read_meta(path: &Path, mtime: u64, size: u64) -> SessionMeta {
    let p = path.to_string_lossy();
    match std::fs::File::open(path) {
        Ok(f) => meta_from_reader(&p, mtime, size, BufReader::with_capacity(1 << 20, f)),
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
