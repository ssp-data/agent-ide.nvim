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
    // last aiTitle anywhere wins; first prompt only when none
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
