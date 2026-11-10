use crate::scan::*;
use std::path::PathBuf;
use std::sync::atomic::AtomicUsize;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("tests").join("fixtures").join("projects")
}

fn run(dir: &std::path::Path) -> Vec<SessionMeta> {
    scan(dir, None, &AtomicUsize::new(0))
}

fn by_prefix<'a>(v: &'a [SessionMeta], p: &str) -> &'a SessionMeta {
    v.iter().find(|s| s.id.starts_with(p)).unwrap()
}

#[test]
fn fixtures_scan() {
    let all = run(&fixtures());
    assert_eq!(all.len(), 4);
    let a = by_prefix(&all, "1111");
    assert_eq!((a.title.as_str(), a.cwd.as_deref(), a.branch.as_deref()), ("Alpha basics", Some("/home/u/git/alpha"), Some("feat/x")));
    assert!(a.size > 0 && a.mtime > 0);
    assert_eq!(by_prefix(&all, "2222").title, "Write the docs intro paragraph");
    assert_eq!(by_prefix(&all, "3333").title, "Meeting notes summary");
    let d = by_prefix(&all, "4444");
    assert_eq!((d.title.as_str(), d.cwd.as_deref()), ("(untitled)", None));
}

#[test]
fn missing_dir_is_empty() {
    assert!(run(std::path::Path::new("/nonexistent/x")).is_empty());
}

#[test]
fn unreadable_file_is_untitled() {
    let m = read_meta(std::path::Path::new("/nonexistent/x/abc.jsonl"), 1, 2);
    assert_eq!((m.id.as_str(), m.title.as_str(), m.cwd.as_deref()), ("abc", "(untitled)", None));
}

#[test]
fn title_rules() {
    let m = |text: &str| meta_from_bytes("/p/a.jsonl", 1, 1, text.as_bytes());
    let user = |s: &str| format!("{}\n", serde_json::json!({"type":"user","message":{"content":s}}));
    assert_eq!(m(&user("a \n\n  b\tc")).title, "a b\tc");
    assert_eq!(m(&user(&"é".repeat(70))).title, "é".repeat(60));
    assert_eq!(m(&user("   ")).title, "(untitled)");
    // small file: last aiTitle anywhere wins; first prompt only when none
    let t = format!("{}{}{}", user("p"), "{\"type\":\"ai-title\",\"aiTitle\":\"One\"}\n", "{\"type\":\"ai-title\",\"aiTitle\":\"Two\"}\n");
    assert_eq!(m(&t).title, "Two");
    // sidechain prompts do not count
    let sc = "{\"type\":\"user\",\"isSidechain\":true,\"message\":{\"content\":\"side\"}}\n";
    assert_eq!(m(sc).title, "(untitled)");
}

#[test]
fn json_to_the_wire_has_null_cwd() {
    let m = meta_from_bytes("/p/a.jsonl", 1, 1, b"");
    let v = serde_json::to_value(&m).unwrap();
    assert!(v["cwd"].is_null() && v["branch"].is_null());
}

#[test]
fn non_string_prompt_text_keeps_the_session_and_is_skipped() {
    let dir = std::env::temp_dir().join(format!("agent-ide-helper-nonstr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("-p")).unwrap();
    let body = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":5}]}}\n{\"type\":\"user\",\"message\":{\"content\":\"real prompt\"}}\n";
    std::fs::write(dir.join("-p/abc.jsonl"), body).unwrap();
    let got = run(&dir);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].title, "real prompt");
    let _ = std::fs::remove_dir_all(&dir);
}

const KIB: usize = 1024;

fn filler(n_bytes: usize) -> String {
    let line = format!("{}\n", serde_json::json!({"type":"assistant","message":{"content":[{"type":"text","text":"f".repeat(1000)}]}}));
    line.repeat(n_bytes / line.len() + 1)
}

fn title_line(t: &str) -> String {
    format!("{}\n", serde_json::json!({"type":"ai-title","aiTitle":t}))
}

/// A synthetic transcript of more than 600 KiB.
fn big(early: Option<&str>, middle: Option<&str>, late: Option<&str>) -> String {
    let mut s = String::from("{\"type\":\"user\",\"cwd\":\"/w\",\"message\":{\"content\":\"first prompt\"}}\n");
    if let Some(t) = early { s += &title_line(t); }
    s += &filler(300 * KIB);
    if let Some(t) = middle { s += &title_line(t); }
    s += &filler(300 * KIB);
    if let Some(t) = late { s += &title_line(t); }
    s += &filler(10 * KIB);
    assert!(s.len() > 600 * KIB);
    s
}

fn both(name: &str, text: &str) -> (SessionMeta, SessionMeta) {
    let dir = std::env::temp_dir().join(format!("agent-ide-helper-big-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("abc.jsonl");
    std::fs::write(&f, text).unwrap();
    let from_file = read_meta(&f, 1, text.len() as u64);
    let _ = std::fs::remove_dir_all(&dir);
    let p = f.to_string_lossy().into_owned();
    (meta_from_bytes(&p, 1, text.len() as u64, text.as_bytes()), from_file)
}

#[test]
fn big_file_title_comes_from_the_tail_window_first() {
    let (a, b) = both("late", &big(Some("Early"), None, Some("Late")));
    assert_eq!((a.title.as_str(), a.cwd.as_deref()), ("Late", Some("/w")));
    assert_eq!(a, b);
}

#[test]
fn big_file_without_late_title_uses_the_head_window() {
    let (a, b) = both("early", &big(Some("Early"), Some("Middle"), None));
    assert_eq!(a.title, "Early");
    assert_eq!(a, b);
}

#[test]
fn big_file_title_outside_both_windows_is_not_seen() {
    let (a, b) = both("middle", &big(None, Some("Middle"), None));
    assert_eq!(a.title, "first prompt");
    assert_eq!(a, b);
}

#[test]
fn first_line_of_the_tail_window_is_ignored() {
    // the late title line starts exactly where the tail window starts
    let head = big(Some("Early"), None, None);
    let rest = filler(300 * KIB);
    let late = title_line("Late");
    let pad = filler(256 * KIB);
    let pad = &pad[..256 * KIB - late.len()];
    let pad = format!("{}\n", &pad[..pad.len() - 1]);
    let text = format!("{head}{rest}{late}{pad}");
    assert_eq!(text.len() - (late.len() + pad.len()), text.len() - 256 * KIB);
    let (a, b) = both("edge", &text);
    assert_eq!(a.title, "Early");
    assert_eq!(a, b);
}

#[test]
fn a_user_line_with_an_ai_title_key_can_still_be_the_first_prompt() {
    let text = "{\"type\":\"user\",\"aiTitle\":\"not a title record\",\"message\":{\"content\":\"quoted prompt\"}}\n";
    assert_eq!(meta_from_bytes("/p/a.jsonl", 1, 1, text.as_bytes()).title, "quoted prompt");
}

fn rec(ty: &str, ts: &str) -> String {
    format!("{}\n", serde_json::json!({"type": ty, "timestamp": ts, "message": {"content": "x"}}))
}

const TS: &str = "2026-01-02T03:04:05.000Z";
const TS_SECONDS: u64 = 1767323045;

#[test]
fn activity_is_last_conversational_record() {
    let m = |t: &str, mtime: u64| meta_from_bytes("/p/a.jsonl", mtime, t.len() as u64, t.as_bytes());
    let text = format!(
        "{}{}{}{}",
        rec("user", "2026-01-01T00:00:00Z"),
        rec("assistant", TS),
        "{\"type\":\"ai-title\",\"aiTitle\":\"T\",\"timestamp\":\"2030-01-01T00:00:00.000Z\"}\n",
        "{\"type\":\"mode\",\"timestamp\":\"2031-01-01T00:00:00.000Z\"}\n"
    );
    let a = m(&text, 1_900_000_000);
    assert_eq!((a.activity, a.mtime), (TS_SECONDS, 1_900_000_000));
    // no conversational record, or an empty file: mtime
    assert_eq!(m("{\"type\":\"ai-title\",\"aiTitle\":\"T\",\"timestamp\":\"2030-01-01T00:00:00.000Z\"}\n", 1234).activity, 1234);
    assert_eq!(m("", 77).activity, 77);
    // unparsable timestamps are skipped; fraction optional; sidechain/meta count
    let bad = format!(
        "{}{}{}{}{}",
        rec("user", TS),
        rec("assistant", "garbage"),
        rec("assistant", "2026-13-40T99:00:00Z"),
        "{\"type\":\"user\",\"timestamp\":5}\n",
        rec("assistant", "2026-01-02T03:04:05.000+01:00")
    );
    assert_eq!(m(&bad, 9).activity, TS_SECONDS);
    assert_eq!(m(&rec("assistant", "2026-01-02T03:04:05Z"), 9).activity, TS_SECONDS);
    let flags = "{\"type\":\"assistant\",\"isSidechain\":true,\"isMeta\":true,\"timestamp\":\"2026-01-02T03:04:05.000Z\"}\n";
    assert_eq!(m(flags, 9).activity, TS_SECONDS);
    assert_eq!(m(&rec("assistant", "1969-12-31T23:59:59Z"), 9).activity, 9);
}

#[test]
fn activity_windows_on_big_files() {
    let m = |t: &str, mtime: u64| meta_from_bytes("/p/a.jsonl", mtime, t.len() as u64, t.as_bytes());
    let filler = |n: usize| "{\"type\":\"progress\",\"x\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"}\n".repeat(n / 100 + 1);
    // the last message is in the tail window; a middle one outside both windows is not looked at
    let big = format!("{}{}{}{}{}{}", rec("user", "2026-01-01T00:00:00.000Z"), filler(300 * 1024), rec("user", "2026-06-01T00:00:00Z"), filler(300 * 1024), rec("assistant", TS), filler(10 * 1024));
    assert_eq!(m(&big, 5).activity, TS_SECONDS);
    // no conversational record in the tail window: the head window decides
    let progress = "{\"type\":\"progress\",\"timestamp\":\"2030-01-01T00:00:00Z\"}\n";
    let head_only = format!("{}{}", rec("assistant", TS), progress.repeat(14000));
    assert!(head_only.len() > 512 * 1024);
    assert_eq!(m(&head_only, 5).activity, TS_SECONDS);
    let none = progress.repeat(12000);
    assert_eq!(m(&none, 5).activity, 5);
}
