use crate::cache::Cache;
use crate::scan::{self, SessionMeta};
use std::sync::atomic::{AtomicUsize, Ordering};

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("agent-ide-helper-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn project(root: &std::path::Path, body: &str) -> std::path::PathBuf {
    let p = root.join("-p");
    std::fs::create_dir_all(&p).unwrap();
    let f = p.join("abc.jsonl");
    std::fs::write(&f, body).unwrap();
    f
}

#[test]
fn unchanged_file_is_not_reread_and_size_change_invalidates() {
    let root = tmp("reuse");
    let cache_dir = root.join("cache");
    let projects = root.join("projects");
    let f = project(&projects, "{\"type\":\"user\",\"cwd\":\"/a\",\"message\":{\"content\":\"one\"}}\n");
    let reads = AtomicUsize::new(0);

    let mut c = Cache::load(Some(&cache_dir));
    let first = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(reads.load(Ordering::SeqCst), 1);

    let mut c = Cache::load(Some(&cache_dir));
    let second = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(reads.load(Ordering::SeqCst), 1, "second scan must use the cache");
    assert_eq!(first, second);

    std::fs::write(&f, "{\"type\":\"user\",\"cwd\":\"/a\",\"message\":{\"content\":\"longer text\"}}\n").unwrap();
    let mut c = Cache::load(Some(&cache_dir));
    let third = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(reads.load(Ordering::SeqCst), 2);
    assert_eq!(third[0].title, "longer text");
}

#[test]
fn garbage_cache_file_is_ignored_and_rewritten() {
    let root = tmp("garbage");
    let cache_dir = root.join("cache");
    std::fs::create_dir_all(&cache_dir).unwrap();
    std::fs::write(cache_dir.join("index-v1.json"), "garbage").unwrap();
    let projects = root.join("projects");
    project(&projects, "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n");
    let reads = AtomicUsize::new(0);
    let mut c = Cache::load(Some(&cache_dir));
    let got = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(got.len(), 1);
    assert_eq!(reads.load(Ordering::SeqCst), 1);
    let text = std::fs::read_to_string(cache_dir.join("index-v1.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    let entry = v.as_object().unwrap().values().next().unwrap();
    assert!(entry.get("mtime").is_some() && entry.get("size").is_some() && entry.get("meta").is_some());
}

#[test]
fn no_cache_dir_means_no_cache_file() {
    let c = Cache::load(None);
    assert!(c.get("x", 1, 1).is_none());
    let m = SessionMeta { id: "a".into(), path: "x".into(), cwd: None, title: "t".into(), branch: None, mtime: 1, size: 1 };
    let mut c = c;
    c.insert(m);
    c.save(); // must not panic or write anywhere
}
