//! Search documents of one transcript.
//!
//! A `Doc` is a session's metadata (the scan title rule) plus one `Chunk` per main-thread
//! prompt, answer text and tool call. Each chunk keeps the 1-based index of its event in the
//! list `history` returns (`events::parse_bytes`), so the Lua side can map a hit to a rendered
//! line. Texts are capped (`TEXT_CAP`, `TOOL_CAP`, cut at a character boundary): the index never
//! holds whole transcripts. Sidechain (subagent) events are not indexed.
//!
//! Transcripts are append-only, so a grown file is parsed from the end of the last complete
//! line indexed (`Doc::indexed`); a shrunk file, or one whose indexed part no longer ends with a
//! newline, is indexed again from the start. Only complete lines are indexed: the line being
//! written is picked up once it ends.
use crate::events::{is_space, parse_record, Event};
use crate::scan::{self, SessionMeta};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::time::UNIX_EPOCH;

pub const TEXT_CAP: usize = 4096;
pub const TOOL_CAP: usize = 200;
const SUMMARY_FIELDS: &[&str] = &["command", "file_path", "skill", "pattern", "description", "prompt"];
const SUMMARY_CHARS: usize = 80;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Title,
    Prompt,
    Answer,
    Tool,
}

impl Kind {
    /// Ranking order: title before prompt before answer before tool.
    pub fn rank(self) -> u8 {
        self as u8
    }
    pub fn name(self) -> &'static str {
        match self {
            Kind::Title => "title",
            Kind::Prompt => "prompt",
            Kind::Answer => "answer",
            Kind::Tool => "tool",
        }
    }
    pub fn parse(s: &str) -> Option<Kind> {
        [Kind::Title, Kind::Prompt, Kind::Answer, Kind::Tool].into_iter().find(|k| k.name() == s)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Chunk {
    pub kind: Kind,
    /// 1-based index of the event in the session's event list.
    pub event: u32,
    /// UNIX seconds of the record's `timestamp`, when it has a valid one.
    pub ts: Option<u64>,
    pub text: String,
    /// The text was longer than the cap.
    #[serde(default)]
    pub cut: bool,
}

/// A line holding the first event of a turn (a main-thread prompt), for reading one turn
/// without parsing the whole transcript.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Anchor {
    /// 1-based index of the turn's first event.
    pub turn: u32,
    /// 1-based index of the first event of the line.
    pub line_event: u32,
    /// Byte offset of the line.
    pub offset: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Doc {
    pub meta: SessionMeta,
    /// Bytes indexed: the file up to and including its last complete line.
    pub indexed: u64,
    /// Events in those bytes.
    pub events: u32,
    pub chunks: Vec<Chunk>,
    pub anchors: Vec<Anchor>,
}

/// `s` cut to at most `max` bytes at a character boundary; `true` when it was cut.
pub fn cap(s: &str, max: usize) -> (String, bool) {
    if s.len() <= max {
        return (s.to_string(), false);
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    (s[..end].to_string(), true)
}

fn first_line(s: &str) -> &str {
    s.split(['\n', '\r']).next().unwrap_or("")
}

/// `Name: summary` as in the renderer's tool call header.
fn tool_text(ev: &Event) -> String {
    let name = ev.get("name").and_then(Value::as_str).unwrap_or("?");
    let mut summary = String::new();
    if let Some(input) = ev.get("input").and_then(Value::as_object) {
        if let Some(v) = SUMMARY_FIELDS.iter().find_map(|f| input.get(*f)) {
            let s = match v {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            summary = first_line(&s).chars().take(SUMMARY_CHARS).collect();
        }
    }
    format!("{}: {}", first_line(name), summary)
}

#[derive(Deserialize)]
struct TsOnly {
    #[serde(default)]
    timestamp: Option<Value>,
}

fn timestamp_of(line: &[u8]) -> Option<u64> {
    let fixed = String::from_utf8_lossy(line);
    let rec: TsOnly = serde_json::from_str(&fixed).ok()?;
    scan::parse_timestamp(rec.timestamp?.as_str()?)
}

fn nonblank(s: &str) -> bool {
    s.bytes().any(|b| !is_space(b))
}

/// What one line contributes, with event indexes relative to the line.
struct LineOut {
    events: u32,
    chunks: Vec<Chunk>,
    turns: Vec<u32>,
}

fn index_line(line: &[u8]) -> LineOut {
    let (events, _) = parse_record(line);
    let mut chunks = Vec::new();
    let mut turns = Vec::new();
    for (i, ev) in events.iter().enumerate() {
        if ev.get("sidechain").is_some() {
            continue;
        }
        let kind = ev.get("kind").and_then(Value::as_str).unwrap_or("");
        if kind == "prompt" {
            turns.push(i as u32);
        }
        let (kind, text, cut) = match kind {
            "prompt" | "text" => match ev.get("text").and_then(Value::as_str) {
                Some(t) if nonblank(t) => {
                    let (t, cut) = cap(t, TEXT_CAP);
                    (if kind == "prompt" { Kind::Prompt } else { Kind::Answer }, t, cut)
                }
                _ => continue,
            },
            "tool_call" => {
                let (t, cut) = cap(&tool_text(ev), TOOL_CAP);
                (Kind::Tool, t, cut)
            }
            _ => continue,
        };
        chunks.push(Chunk { kind, event: i as u32, ts: None, text, cut });
    }
    if !chunks.is_empty() {
        let ts = timestamp_of(line);
        for c in &mut chunks {
            c.ts = ts;
        }
    }
    LineOut { events: events.len() as u32, chunks, turns }
}

/// Indexes the complete lines of `data` (which starts at file offset `base`) into `doc`.
fn index_bytes(doc: &mut Doc, data: &[u8], base: u64) {
    let end = match data.iter().rposition(|b| *b == b'\n') {
        Some(p) => p + 1,
        None => return,
    };
    let mut lines: Vec<(u64, &[u8])> = Vec::new();
    let mut start = 0;
    for (i, b) in data[..end].iter().enumerate() {
        if *b == b'\n' {
            if i > start {
                lines.push((base + start as u64, &data[start..i]));
            }
            start = i + 1;
        }
    }
    let outs: Vec<LineOut> = lines.par_iter().map(|(_, l)| index_line(l)).collect();
    for ((offset, _), out) in lines.iter().zip(outs) {
        let first = doc.events + 1;
        for t in out.turns {
            doc.anchors.push(Anchor { turn: first + t, line_event: first, offset: *offset });
        }
        for mut c in out.chunks {
            c.event += first;
            doc.chunks.push(c);
        }
        doc.events += out.events;
    }
    doc.indexed = base + end as u64;
}

/// `(mtime seconds, size)` of a file.
pub fn stat(path: &Path) -> Option<(u64, u64)> {
    let st = std::fs::metadata(path).ok()?;
    let mtime = st.modified().ok()?.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    Some((mtime, st.len()))
}

/// Reads the bytes after `prev.indexed`, or `None` when the file must be indexed again.
fn appended(path: &Path, prev: &Doc, size: u64) -> Option<Vec<u8>> {
    if prev.indexed == 0 || size < prev.indexed {
        return None;
    }
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(prev.indexed - 1)).ok()?;
    let mut buf = Vec::with_capacity((size - prev.indexed + 1) as usize);
    f.read_to_end(&mut buf).ok()?;
    (buf.first() == Some(&b'\n')).then(|| buf.split_off(1))
}

/// Indexes `path`, continuing from `prev` when the file only grew. `None` when unreadable.
pub fn index_file(path: &Path, prev: Option<&Doc>) -> Option<Doc> {
    let (mtime, size) = stat(path)?;
    let p = path.to_string_lossy().into_owned();
    if let Some(prev) = prev {
        if let Some(rest) = appended(path, prev, size) {
            let mut doc = prev.clone();
            index_bytes(&mut doc, &rest, prev.indexed);
            doc.meta = scan::read_meta(path, mtime, size);
            return Some(doc);
        }
    }
    let data = std::fs::read(path).ok()?;
    let meta = scan::meta_from_bytes(&p, mtime, size, &data);
    let mut doc = Doc { meta, indexed: 0, events: 0, chunks: Vec::new(), anchors: Vec::new() };
    index_bytes(&mut doc, &data, 0);
    Some(doc)
}

pub struct Refresh {
    pub changed: Vec<Doc>,
    pub removed: Vec<String>,
}

/// Files below `dir` that are new or changed (mtime or size) compared with `docs`, indexed in
/// parallel, and the paths of `docs` below `dir` whose file is gone.
pub fn refresh(dir: &str, docs: &HashMap<String, Doc>) -> Refresh {
    let files = scan::list_files(dir);
    Refresh { changed: changed(&files, docs), removed: missing(dir, &files, docs) }
}

/// The docs of those `files` that are new or changed compared with `docs`, indexed in parallel.
pub fn changed(files: &[String], docs: &HashMap<String, Doc>) -> Vec<Doc> {
    stale(files, docs).par_iter().filter_map(|(p, prev)| index_file(Path::new(p), *prev)).collect()
}

/// Those `files` that are new or changed (mtime or size) compared with `docs`, with their doc.
pub fn stale<'a>(files: &'a [String], docs: &'a HashMap<String, Doc>) -> Vec<(&'a String, Option<&'a Doc>)> {
    files
        .iter()
        .filter_map(|p| {
            let (mtime, size) = stat(Path::new(p))?;
            let prev = docs.get(p);
            (!prev.is_some_and(|d| d.meta.mtime == mtime && d.meta.size == size)).then_some((p, prev))
        })
        .collect()
}

/// Paths of `docs` below `dir` that are not among `files` (sorted).
pub fn missing(dir: &str, files: &[String], docs: &HashMap<String, Doc>) -> Vec<String> {
    let listed: std::collections::HashSet<&str> = files.iter().map(String::as_str).collect();
    let prefix = format!("{}/", dir.trim_end_matches('/'));
    let mut removed: Vec<String> =
        docs.keys().filter(|p| p.starts_with(&prefix) && !listed.contains(p.as_str())).cloned().collect();
    removed.sort();
    removed
}
