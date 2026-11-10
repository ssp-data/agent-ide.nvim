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
    std::fs::write(cache_dir.join(crate::cache::FILE_NAME), "garbage").unwrap();
    let projects = root.join("projects");
    project(&projects, "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n");
    let reads = AtomicUsize::new(0);
    let mut c = Cache::load(Some(&cache_dir));
    let got = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(got.len(), 1);
    assert_eq!(reads.load(Ordering::SeqCst), 1);
    let text = std::fs::read_to_string(cache_dir.join(crate::cache::FILE_NAME)).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["version"], crate::cache::VERSION);
    let entry = v["entries"].as_object().unwrap().values().next().unwrap();
    assert!(entry.get("mtime").is_some() && entry.get("size").is_some() && entry.get("meta").is_some());
}

#[test]
fn no_cache_dir_means_no_cache_file() {
    let c = Cache::load(None);
    assert!(c.get("x", 1, 1).is_none());
    let m = SessionMeta { id: "a".into(), path: "x".into(), cwd: None, title: "t".into(), branch: None, mtime: 1, activity: 1, size: 1 };
    let mut c = c;
    c.insert(m);
    c.save(); // must not panic or write anywhere
}

#[test]
fn cache_written_by_another_version_is_ignored() {
    assert_eq!(crate::cache::FILE_NAME, "index-v3.json");
    let root = tmp("version");
    let cache_dir = root.join("cache");
    let projects = root.join("projects");
    let f = project(&projects, "{\"type\":\"user\",\"message\":{\"content\":\"fresh\"}}\n");
    let reads = AtomicUsize::new(0);
    let mut c = Cache::load(Some(&cache_dir));
    let first = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(first[0].title, "fresh");
    // same entries, stale title, older version: must not be served
    let file = cache_dir.join(crate::cache::FILE_NAME);
    let mut v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    v["version"] = "0.0.0-old".into();
    let key = f.to_string_lossy().into_owned();
    v["entries"][&key]["meta"]["title"] = "stale".into();
    std::fs::write(&file, v.to_string()).unwrap();
    let mut c = Cache::load(Some(&cache_dir));
    let again = scan::scan(&projects, Some(&mut c), &reads);
    assert_eq!(reads.load(Ordering::SeqCst), 2);
    assert_eq!(again[0].title, "fresh");
    let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(v["version"], crate::cache::VERSION);
}

#[test]
fn cache_with_other_rules_or_format_is_ignored_and_the_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let root = tmp("rules");
    let cache_dir = root.join("cache");
    let projects = root.join("projects");
    let f = project(&projects, "{\"type\":\"user\",\"message\":{\"content\":\"fresh\"}}\n");
    let reads = AtomicUsize::new(0);
    let mut c = Cache::load(Some(&cache_dir));
    scan::scan(&projects, Some(&mut c), &reads);
    let file = cache_dir.join(crate::cache::FILE_NAME);
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(&cache_dir), 0o700);
    let key = f.to_string_lossy().into_owned();
    let changes = [
        ("rules", serde_json::json!(crate::events::RULES_VERSION + 1)),
        ("format", serde_json::json!(crate::cache::FORMAT + 1)),
    ];
    for (field, value) in changes {
        let mut v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        v[field] = value;
        v["entries"][&key]["meta"]["title"] = "stale".into();
        std::fs::write(&file, v.to_string()).unwrap();
        let mut c = Cache::load(Some(&cache_dir));
        assert_eq!(scan::scan(&projects, Some(&mut c), &reads)[0].title, "fresh", "{field}");
    }
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn older_index_versions_are_removed_when_the_current_one_is_written() {
    use crate::cache::is_old_version;
    assert!(is_old_version("index-v1.json"));
    assert!(is_old_version("index-v2.json"));
    assert!(is_old_version("index-v42.json"));
    assert!(!is_old_version(crate::cache::FILE_NAME));
    for other in ["index-v.json", "index-vx.json", "index-v1.json.tmp", "xindex-v1.json", "index-v1.jsonl", "search-v1.json", "index-v1"] {
        assert!(!is_old_version(other), "{other}");
    }

    let root = tmp("old-versions");
    let cache_dir = root.join("cache");
    std::fs::create_dir_all(cache_dir.join("index-v9.json")).unwrap(); // a folder of that name stays
    let keep = ["search-v1.json", "index-v1.json.tmp", "notes.txt", "index-vx.json"];
    for f in ["index-v1.json", "index-v2.json"].iter().chain(keep.iter()) {
        std::fs::write(cache_dir.join(f), "x").unwrap();
    }
    let below = cache_dir.join("index-v9.json").join("index-v1.json");
    std::fs::write(&below, "x").unwrap();
    let projects = root.join("projects");
    project(&projects, "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n");
    let reads = AtomicUsize::new(0);
    let mut c = Cache::load(Some(&cache_dir));
    scan::scan(&projects, Some(&mut c), &reads);
    c.save();
    assert!(cache_dir.join(crate::cache::FILE_NAME).is_file());
    assert!(!cache_dir.join("index-v1.json").exists());
    assert!(!cache_dir.join("index-v2.json").exists());
    for f in keep {
        assert!(cache_dir.join(f).is_file(), "{f} must stay");
    }
    assert!(below.is_file(), "nothing below the folder is touched");
    let _ = std::fs::remove_dir_all(&root);
}
