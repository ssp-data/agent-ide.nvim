//! The events of the turn holding one event, for the picker's preview. Uses the turn anchors
//! of the index to read only that turn's lines; falls back to parsing the whole transcript when
//! there are none or the file no longer matches them.
//!
//! Texts the renderer shows only the start of (tool output after 200 lines, a Bash command or
//! a written file after 60, each side of an edit after 30, an unknown record after 20) are cut
//! to those lines plus one newline for each line left out, so the renderer's `… N more lines`
//! stays exact and `render(trimmed) == render(full)`, without sending megabytes of output.
use super::index::Anchor;
use crate::events::{parse_bytes, Event};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

// The renderer's caps (lua/agent-ide/transcript/render.lua).
const CAP_RESULT: usize = 200;
const CAP_INPUT: usize = 60;
const CAP_EDIT_SIDE: usize = 30;
const CAP_UNKNOWN: usize = 20;

/// `s` with its first `keep` lines (line breaks as the renderer counts them: `\r\n`, `\r`,
/// `\n`) and a bare newline for every further line; `None` when it has no more lines.
fn trim_lines(s: &str, keep: usize) -> Option<String> {
    let b = s.as_bytes();
    let (mut lines, mut cut, mut i) = (1usize, None, 0usize);
    while i < b.len() {
        if b[i] == b'\n' || b[i] == b'\r' {
            if lines == keep && cut.is_none() {
                cut = Some(i);
            }
            lines += 1;
            if b[i] == b'\r' && i + 1 < b.len() && b[i + 1] == b'\n' {
                i += 1;
            }
        }
        i += 1;
    }
    let cut = cut?;
    let mut out = String::with_capacity(cut + lines - keep);
    out.push_str(&s[..cut]);
    out.extend(std::iter::repeat('\n').take(lines - keep));
    Some(out)
}

fn trim_field(obj: &mut serde_json::Map<String, Value>, key: &str, keep: usize) {
    if let Some(Value::String(t)) = obj.get(key) {
        if let Some(short) = trim_lines(t, keep) {
            obj.insert(key.to_string(), Value::String(short));
        }
    }
}

/// Cut what the renderer would not show (see the module comment).
fn trim(ev: &mut Event) {
    let Value::Object(m) = ev else { return };
    match m.get("kind").and_then(Value::as_str) {
        Some("tool_result") => trim_field(m, "text", CAP_RESULT),
        Some("unknown") => trim_field(m, "raw", CAP_UNKNOWN),
        Some("tool_call") => {
            let name = m.get("name").and_then(Value::as_str).unwrap_or("").to_string();
            let Some(Value::Object(input)) = m.get_mut("input") else { return };
            match name.as_str() {
                // '$ ' .. command: the same line count as the command
                "Bash" => trim_field(input, "command", CAP_INPUT),
                "Write" => trim_field(input, "content", CAP_INPUT),
                "Edit" => {
                    trim_field(input, "old_string", CAP_EDIT_SIDE);
                    trim_field(input, "new_string", CAP_EDIT_SIDE);
                }
                _ => {}
            }
        }
        _ => {}
    }
}

fn starts_turn(ev: &Event) -> bool {
    ev["kind"] == "prompt" && ev.get("sidechain").is_none()
}

/// The turn holding `event` among `events` (numbered from `first`): its first index and events.
/// `None` when `event` is outside, or when the turn starts before `events` (`first` > 1).
fn slice_turn(events: &[Event], first: u32, event: u32) -> Option<(u32, Vec<Event>)> {
    if event < first {
        return None;
    }
    let k = (event - first) as usize;
    if k >= events.len() {
        return None;
    }
    let start = match (0..=k).rev().find(|&i| starts_turn(&events[i])) {
        Some(s) => s,
        None if first == 1 => 0,
        None => return None,
    };
    let end = (k + 1..events.len()).find(|&i| starts_turn(&events[i])).unwrap_or(events.len());
    Some((first + start as u32, events[start..end].to_vec()))
}

/// Bytes from `from` to the end of the line that starts at `to` (or to the end of the file).
fn read_range(path: &Path, from: u64, to: Option<u64>) -> Option<Vec<u8>> {
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(from)).ok()?;
    let mut buf = Vec::new();
    match to {
        None => {
            f.read_to_end(&mut buf).ok()?;
        }
        Some(to) => {
            let mut r = BufReader::new(f);
            buf.resize(to.checked_sub(from)? as usize, 0);
            r.read_exact(&mut buf).ok()?;
            r.read_until(b'\n', &mut buf).ok()?;
        }
    }
    Some(buf)
}

fn from_anchors(path: &Path, anchors: &[Anchor], event: u32) -> Option<(u32, Vec<Event>)> {
    let i = anchors.partition_point(|a| a.turn <= event);
    let (from, line_event, turn) = match i {
        0 => (0, 1, 1),
        _ => (anchors[i - 1].offset, anchors[i - 1].line_event, anchors[i - 1].turn),
    };
    let next = anchors.get(i);
    let data = read_range(path, from, next.map(|a| a.offset))?;
    let events = parse_bytes(&data);
    let (first, evs) = slice_turn(&events, line_event, event)?;
    // the file must still look as indexed: the turn starts where the anchors say
    let ends_ok = next.map_or(true, |n| first + evs.len() as u32 == n.turn);
    (ends_ok && (i == 0 || first == turn)).then_some((first, evs))
}

/// `(first, events)` of the turn holding `event` (1-based) in the transcript at `path`.
pub fn turn(path: &Path, anchors: Option<&[Anchor]>, event: u32) -> Result<(u32, Vec<Event>), String> {
    let (first, mut events) = match anchors.and_then(|a| from_anchors(path, a, event)) {
        Some(r) => r,
        None => {
            let data = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
            slice_turn(&parse_bytes(&data), 1, event).ok_or_else(|| format!("event {event} is not in the transcript"))?
        }
    };
    events.iter_mut().for_each(trim);
    Ok((first, events))
}
