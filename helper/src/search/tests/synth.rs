//! Synthetic transcript records for the search tests (never real data).
use serde_json::json;
use std::path::{Path, PathBuf};

/// A temporary directory, removed when dropped.
pub struct Tmp(PathBuf);

impl std::ops::Deref for Tmp {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn tmp(name: &str) -> Tmp {
    let d = std::env::temp_dir().join(format!("agent-ide-search-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    Tmp(d)
}

fn ts(n: u32) -> String {
    format!("2026-01-{:02}T10:{:02}:00Z", 1 + n / 60 % 28, n % 60)
}

pub fn user(text: &str, n: u32) -> String {
    json!({"type": "user", "cwd": "/w/repo", "timestamp": ts(n), "message": {"role": "user", "content": text}}).to_string() + "\n"
}

pub fn answer(text: &str, n: u32) -> String {
    json!({"type": "assistant", "timestamp": ts(n), "message": {"content": [{"type": "text", "text": text}]}}).to_string() + "\n"
}

pub fn tool(name: &str, command: &str, id: &str) -> String {
    json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": id, "name": name, "input": {"command": command}}]}})
        .to_string()
        + "\n"
}

pub fn result(id: &str, text: &str) -> String {
    json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": text}]}}).to_string() + "\n"
}

pub fn side(text: &str) -> String {
    json!({"type": "user", "isSidechain": true, "message": {"content": text}}).to_string() + "\n"
}

pub fn title(t: &str) -> String {
    json!({"type": "ai-title", "aiTitle": t}).to_string() + "\n"
}

/// Writes `text` to `<root>/<project>/<id>.jsonl` and returns the path.
pub fn write(root: &Path, project: &str, id: &str, text: &str) -> PathBuf {
    let dir = root.join(project);
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join(format!("{id}.jsonl"));
    std::fs::write(&p, text).unwrap();
    p
}

pub fn append(p: &Path, text: &str) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new().append(true).open(p).unwrap();
    f.write_all(text.as_bytes()).unwrap();
}

/// A session of `rounds` prompt/answer/tool rounds of about `size` bytes in total.
pub fn session(rounds: u32, words: &str, pad: usize) -> String {
    let mut s = String::new();
    let out = "x".repeat(pad);
    for n in 0..rounds {
        s += &user(&format!("prompt {n} about {words}"), n);
        s += &answer(&format!("answer {n} explaining {words} in detail"), n);
        s += &tool("Bash", "ls -la", &format!("t{n}"));
        s += &result(&format!("t{n}"), &out);
    }
    s
}

/// A session of realistic prose: prompts of 100–400 bytes, answers of 1–4 KiB, and a tool
/// call with `pad` bytes of output per round.
pub fn prose_session(seed: u64, rounds: u32, pad: usize) -> String {
    let mut s = String::new();
    let out = "x".repeat(pad);
    for n in 0..rounds {
        let k = seed * 1000 + n as u64;
        s += &user(&prose(k, 100 + (k as usize * 37) % 300), n);
        s += &answer(&prose(k + 7, 1024 + (k as usize * 997) % 3072), n);
        s += &tool("Bash", "ls -la", &format!("t{n}"));
        s += &result(&format!("t{n}"), &out);
    }
    s
}

const WORDS: &[&str] = &[
    "the", "parser", "index", "search", "migrate", "database", "umlaut", "Übersetzung", "Größe", "Brücke",
    "function", "returns", "error", "handling", "documentation", "release", "notes", "window", "buffer",
    "session", "transcript", "fold", "render", "query", "result", "with", "and", "for", "when", "über",
    "test", "cargo", "build", "Neovim", "plugin", "should", "because", "können", "müssen", "Straße",
    "jazz", "pizza", "fuzzy", "lazy", "zone", "quick", "xenon", "box", "zip", "quiz", "waltz", "zigzag",
];

/// Pseudo-random prose of about `bytes` bytes from a fixed vocabulary (deterministic per seed).
pub fn prose(seed: u64, bytes: usize) -> String {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    let mut s = String::with_capacity(bytes + 16);
    let mut n = 0;
    while s.len() < bytes {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        s.push_str(WORDS[(x >> 33) as usize % WORDS.len()]);
        n += 1;
        s.push(if n % 14 == 0 { '\n' } else { ' ' });
    }
    s
}
