//! Transcript record -> Event conversion.
//!
//! This is a line-for-line port of `lua/agent-ide/transcript/parse.lua`; where that file has
//! quirks (Lua `ipairs` stopping at `null`, `x or default` treating `false` like `nil`, the
//! hand-written scanner that finds the original text of content blocks) they are reproduced on
//! purpose, because the user's deal-breaker is any difference between the two backends.
use rayon::prelude::*;
use serde_json::{Map, Value};

pub type Event = Value;

const BOOKKEEPING: &[&str] = &[
    "last-prompt",
    "mode",
    "permission-mode",
    "atis-latch",
    "attachment",
    "file-history-snapshot",
    "file-history-delta",
    "ai-title",
    "api-request",
    "api-request-shape",
    "api-request-blob",
    "system",
    "summary",
    "queue-operation",
    "cost-state",
    "pr-link",
    "frame-link",
    "artifact-autoreact-ledger",
    "artifact-comment-monitor",
];

/// C-locale `isspace`, which is what Lua's `%s` and `%S` mean.
pub fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

fn is_space_char(c: char) -> bool {
    c.is_ascii() && is_space(c as u8)
}

fn trim(s: &str) -> &str {
    s.trim_matches(is_space_char)
}

/// Lua field access on a decoded table: objects only (arrays have no named fields) and JSON
/// `null` is `nil` (the Lua side decodes with `luanil`).
fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Object(m) => m.get(key).filter(|x| !x.is_null()),
        _ => None,
    }
}

fn is_true(v: Option<&Value>) -> bool {
    matches!(v, Some(Value::Bool(true)))
}

/// Lua `x or ''`.
fn or_empty(v: Option<&Value>) -> Value {
    match v {
        None | Some(Value::Bool(false)) => Value::String(String::new()),
        Some(x) => x.clone(),
    }
}

/// C `%.14g`, which is how LuaJIT prints numbers.
fn lua_number(f: f64) -> String {
    if f == 0.0 {
        return "0".into();
    }
    if !f.is_finite() {
        return if f.is_nan() { "nan".into() } else if f > 0.0 { "inf".into() } else { "-inf".into() };
    }
    let sci = format!("{:.13e}", f); // 14 significant digits, already rounded
    let (mant, exp) = sci.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    if exp < -4 || exp >= 14 {
        let m = if mant.contains('.') { mant.trim_end_matches('0').trim_end_matches('.') } else { mant };
        format!("{m}e{}{:02}", if exp < 0 { '-' } else { '+' }, exp.abs())
    } else {
        let s = format!("{:.*}", (13 - exp).max(0) as usize, f);
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s }
    }
}

/// Lua `tostring(v)` for the values that can appear as a block `type`.
fn lua_tostring(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => "nil".into(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Number(n)) => n.as_f64().map_or_else(|| n.to_string(), lua_number),
        Some(_) => "table".into(),
    }
}

/// Lua `type(v)` for non-table values.
fn lua_type_name(v: &Value) -> &'static str {
    match v {
        Value::String(_) => "string",
        Value::Number(_) => "number",
        Value::Bool(_) => "boolean",
        _ => "table",
    }
}

fn event(kind: &str, fields: Vec<(&str, Value)>) -> Event {
    let mut m = Map::new();
    m.insert("kind".into(), kind.into());
    for (k, v) in fields {
        m.insert(k.into(), v);
    }
    Value::Object(m)
}

fn unknown(label: String, raw: String) -> Event {
    event("unknown", vec![("label", label.into()), ("raw", raw.into())])
}

// ---------------------------------------------------------------------------------------------
// Original text of message.content elements (port of `raw_content_blocks`).

fn find_any(s: &[u8], from: usize, set: &[u8]) -> Option<usize> {
    if from >= s.len() {
        return None;
    }
    s[from..].iter().position(|b| set.contains(b)).map(|p| p + from)
}

/// Position of the closing quote of the JSON string whose opening quote is at `i`.
fn string_end(s: &[u8], i: usize) -> Option<usize> {
    let mut j = i + 1;
    loop {
        j = find_any(s, j, b"\"\\")?;
        if s[j] == b'\\' {
            j += 2;
        } else {
            return Some(j);
        }
    }
}

fn skip_space(s: &[u8], mut k: usize) -> usize {
    while k < s.len() && is_space(s[k]) {
        k += 1;
    }
    k
}

const STRUCT: &[u8] = b"\"{}[]";

/// Texts of the top-level `{...}`/`[...]` elements of `message.content` as written in `line`.
/// Scalar elements are skipped, exactly as in the Lua scanner (so indexes can drift).
fn raw_content_blocks(line: &[u8]) -> Option<Vec<String>> {
    let mut depth: i32 = 0;
    let mut top_key: Option<&[u8]> = None;
    let mut i = 0usize;
    loop {
        i = find_any(line, i, STRUCT)?;
        let c = line[i];
        if c != b'"' {
            depth += if c == b'{' || c == b'[' { 1 } else { -1 };
            i += 1;
            continue;
        }
        let e = string_end(line, i)?;
        let k = skip_space(line, e + 1);
        if k < line.len() && line[k] == b':' {
            let key = &line[i + 1..e];
            if depth == 1 {
                top_key = Some(key);
            }
            if depth == 2 && key == b"content" && top_key == Some(b"message") {
                let arr = skip_space(line, k + 1);
                if arr >= line.len() || line[arr] != b'[' {
                    return None;
                }
                // One entry per element (scalars included) so indexes line up with the array.
                let mut blocks = Vec::new();
                let (mut d, mut s0, mut j) = (0i32, arr + 1, arr + 1);
                let push = |s0: usize, e: usize, blocks: &mut Vec<String>| {
                    let t = String::from_utf8_lossy(&line[s0..e]).trim_matches(|c| c < '\u{80}' && is_space(c as u8)).to_string();
                    if !t.is_empty() {
                        blocks.push(t);
                    }
                };
                loop {
                    j = find_any(line, j, b"\"{},[]")?;
                    match line[j] {
                        b'"' => j = string_end(line, j)?,
                        b'{' | b'[' => d += 1,
                        b',' => {
                            if d == 0 {
                                push(s0, j, &mut blocks);
                                s0 = j + 1;
                            }
                        }
                        _ => {
                            d -= 1;
                            if d < 0 {
                                push(s0, j, &mut blocks);
                                return Some(blocks);
                            }
                        }
                    }
                    j += 1;
                }
            }
        }
        i = e + 1;
    }
}

// ---------------------------------------------------------------------------------------------

fn tool_result_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(items)) => {
            let mut parts = Vec::new();
            for item in items.iter().take_while(|x| !x.is_null()) {
                match item {
                    Value::Object(_) => {
                        if let (Some(Value::String(t)), Some(Value::String(txt))) = (field(item, "type"), field(item, "text")) {
                            if t == "text" {
                                parts.push(txt.clone());
                                continue;
                            }
                        }
                        parts.push(format!("[{}]", lua_tostring(field(item, "type"))));
                    }
                    Value::Array(_) => parts.push("[nil]".into()),
                    other => parts.push(format!("[{}]", lua_type_name(other))),
                }
            }
            parts.join("\n")
        }
        _ => String::new(),
    }
}

fn user_string_events(is_meta: bool, s: &str) -> Vec<Event> {
    const NAME_OPEN: &str = "<command-name>";
    const NAME_CLOSE: &str = "</command-name>";
    const ARGS_OPEN: &str = "<command-args>";
    const ARGS_CLOSE: &str = "</command-args>";
    const OUT_OPEN: &str = "<local-command-stdout>";
    const OUT_CLOSE: &str = "</local-command-stdout>";

    fn between<'a>(s: &'a str, open: &str, close: &str) -> Option<&'a str> {
        let a = s.find(open)? + open.len();
        let b = s[a..].find(close)? + a;
        Some(&s[a..b])
    }

    if let Some(name) = between(s, NAME_OPEN, NAME_CLOSE) {
        let args = between(s, ARGS_OPEN, ARGS_CLOSE).unwrap_or("");
        let text = trim(&format!("{name} {args}")).to_string();
        return vec![event("prompt", vec![("text", text.into())])];
    }
    // ^%s*<local-command-stdout>(.-)</local-command-stdout>%s*$
    let lead = s.trim_start_matches(is_space_char);
    if let Some(rest) = lead.strip_prefix(OUT_OPEN) {
        if let Some(inner) = rest.trim_end_matches(is_space_char).strip_suffix(OUT_CLOSE) {
            return vec![event("meta", vec![("label", "command output".into()), ("text", inner.into())])];
        }
    }
    if s.starts_with('<') || is_meta {
        return vec![event("meta", vec![("label", "meta".into()), ("text", s.into())])];
    }
    vec![event("prompt", vec![("text", s.into())])]
}

fn block_event(rtype: &str, is_meta: bool, block: &Value, raw: &mut dyn FnMut() -> String) -> Option<Event> {
    if !matches!(block, Value::Object(_) | Value::Array(_)) {
        return Some(unknown(lua_type_name(block).into(), raw()));
    }
    let bt = field(block, "type");
    let bt_str = match bt {
        Some(Value::String(s)) => Some(s.as_str()),
        _ => None,
    };
    match (rtype, bt_str) {
        ("user", Some("tool_result")) => {
            let mut f = Vec::new();
            if let Some(id) = field(block, "tool_use_id") {
                f.push(("id", id.clone()));
            }
            f.push(("text", tool_result_text(field(block, "content")).into()));
            f.push(("is_error", is_true(field(block, "is_error")).into()));
            Some(event("tool_result", f))
        }
        ("user", Some("text")) => {
            let text = or_empty(field(block, "text"));
            Some(if is_meta {
                event("meta", vec![("text", text), ("label", "meta".into())])
            } else {
                event("prompt", vec![("text", text)])
            })
        }
        ("assistant", Some("text")) => Some(event("text", vec![("text", or_empty(field(block, "text")))])),
        ("assistant", Some("thinking")) => match field(block, "thinking") {
            Some(Value::String(t)) if !t.is_empty() => Some(event("thinking", vec![("text", t.clone().into())])),
            _ => None,
        },
        ("assistant", Some("tool_use")) => {
            let mut f = Vec::new();
            if let Some(id) = field(block, "id") {
                f.push(("id", id.clone()));
            }
            if let Some(name) = field(block, "name") {
                f.push(("name", name.clone()));
            }
            let input = match field(block, "input") {
                None | Some(Value::Bool(false)) => Value::Object(Map::new()),
                Some(v) => v.clone(),
            };
            f.push(("input", input));
            Some(event("tool_call", f))
        }
        _ => Some(unknown(lua_tostring(bt), raw())),
    }
}

fn conversation_events(rtype: &str, is_meta: bool, message: Option<&Value>, line: &[u8]) -> Vec<Event> {
    let content = message.and_then(|m| field(m, "content"));
    let line_text = || String::from_utf8_lossy(line).into_owned();
    match content {
        Some(Value::String(s)) => {
            if rtype == "user" {
                user_string_events(is_meta, s)
            } else {
                vec![event("text", vec![("text", s.clone().into())])]
            }
        }
        Some(Value::Array(items)) => {
            let mut raws: Option<Vec<String>> = None;
            let mut out = Vec::new();
            for (idx, block) in items.iter().take_while(|b| !b.is_null()).enumerate() {
                let mut raw = || {
                    let r = raws.get_or_insert_with(|| raw_content_blocks(line).unwrap_or_default());
                    r.get(idx).cloned().unwrap_or_else(|| block.to_string())
                };
                out.extend(block_event(rtype, is_meta, block, &mut raw));
            }
            out
        }
        // An object is a Lua table with no array part: `ipairs` yields nothing.
        Some(Value::Object(_)) => Vec::new(),
        _ => vec![unknown(rtype.into(), line_text())],
    }
}

/// Events of one transcript line (empty for blank, invalid or cut-off lines).
pub fn parse_line(line: &[u8]) -> Vec<Event> {
    if !line.iter().any(|b| !is_space(*b)) {
        return Vec::new();
    }
    let rec: Value = match serde_json::from_slice(line) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    if !matches!(rec, Value::Object(_) | Value::Array(_)) {
        return Vec::new();
    }
    let rtype = match field(&rec, "type") {
        Some(Value::String(s)) => s.as_str(),
        _ => "?",
    };
    let mut events = if BOOKKEEPING.contains(&rtype) {
        return Vec::new();
    } else if rtype == "user" || rtype == "assistant" {
        conversation_events(rtype, is_true(field(&rec, "isMeta")), field(&rec, "message"), line)
    } else {
        vec![unknown(rtype.into(), String::from_utf8_lossy(line).into_owned())]
    };
    if is_true(field(&rec, "isSidechain")) {
        for ev in &mut events {
            if let Value::Object(m) = ev {
                m.insert("sidechain".into(), Value::Bool(true));
            }
        }
    }
    events
}

/// Events of a whole transcript, in file order (lines are parsed in parallel).
pub fn parse_bytes(data: &[u8]) -> Vec<Event> {
    let lines: Vec<&[u8]> = data.split(|b| *b == b'\n').filter(|l| !l.is_empty()).collect();
    let parsed: Vec<Vec<Event>> = lines.par_iter().map(|l| parse_line(l)).collect();
    parsed.into_iter().flatten().collect()
}

pub fn parse_text(text: &str) -> Vec<Event> {
    parse_bytes(text.as_bytes())
}

#[cfg(test)]
mod tests;
