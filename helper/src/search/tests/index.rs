use super::synth::*;
use crate::events::parse_bytes;
use crate::search::index::{index_file, refresh, Doc, Kind, TEXT_CAP};
use crate::search::store;
use std::collections::HashMap;

fn docs_of(dir: &std::path::Path) -> HashMap<String, Doc> {
    let r = refresh(&dir.to_string_lossy(), &HashMap::new());
    assert!(r.removed.is_empty());
    r.changed.into_iter().map(|d| (d.meta.path.clone(), d)).collect()
}

#[test]
fn chunk_event_indexes_point_into_the_history_event_list() {
    let root = tmp("idx");
    let text = user("first question", 1)
        + &title("Some title")
        + &answer("first answer", 2)
        + &tool("Bash", "cargo test", "t1")
        + &result("t1", "ok")
        + "not json at all\n"
        + &side("subagent prompt")
        + &user("second question", 3)
        + &answer("second answer", 4);
    let p = write(&root, "-w-repo", "s1", &text);
    let doc = index_file(&p, None).unwrap();
    let events = parse_bytes(&std::fs::read(&p).unwrap());
    assert_eq!(doc.events as usize, events.len());
    let kinds: Vec<(Kind, &str)> = doc.chunks.iter().map(|c| (c.kind, c.text.as_str())).collect();
    assert_eq!(
        kinds,
        vec![
            (Kind::Prompt, "first question"),
            (Kind::Answer, "first answer"),
            (Kind::Tool, "Bash: cargo test"),
            (Kind::Prompt, "second question"),
            (Kind::Answer, "second answer"),
        ]
    );
    for c in &doc.chunks {
        let ev = &events[c.event as usize - 1];
        let want = match c.kind {
            Kind::Prompt => "prompt",
            Kind::Answer => "text",
            Kind::Tool => "tool_call",
            Kind::Title => unreachable!(),
        };
        assert_eq!(ev["kind"], want);
        if c.kind != Kind::Tool {
            assert_eq!(ev["text"], c.text.as_str());
        }
    }
    assert_eq!(doc.chunks[0].ts, Some(crate::scan::parse_timestamp("2026-01-01T10:01:00Z").unwrap()));
    assert_eq!(doc.chunks[2].ts, None);
    assert_eq!(doc.meta.title, "Some title");
    assert_eq!(doc.meta.cwd.as_deref(), Some("/w/repo"));
    // two turns start at the two main-thread prompts
    let turns: Vec<u32> = doc.anchors.iter().map(|a| a.turn).collect();
    assert_eq!(turns, vec![1, doc.chunks[3].event]);
}

#[test]
fn texts_are_capped_at_a_char_boundary() {
    let root = tmp("cap");
    let long = "ä".repeat(TEXT_CAP); // 2 bytes each
    let p = write(&root, "-w", "s", &(user(&long, 1) + &answer(&"b".repeat(TEXT_CAP * 3), 2) + &user("   \n ", 3)));
    let doc = index_file(&p, None).unwrap();
    assert_eq!(doc.chunks.len(), 2, "blank prompt skipped");
    assert!(doc.chunks[0].text.len() <= TEXT_CAP && doc.chunks[0].cut);
    assert_eq!(doc.chunks[0].text.chars().count(), TEXT_CAP / 2);
    assert_eq!(doc.chunks[1].text.len(), TEXT_CAP);
    assert!(doc.chunks[1].cut);
}

#[test]
fn appended_lines_are_indexed_from_the_last_offset_and_keep_indexes() {
    let root = tmp("append");
    let p = write(&root, "-w", "s", &(user("one", 1) + &answer("two", 2)));
    let first = index_file(&p, None).unwrap();
    // a partial last line is not indexed until it is complete
    append(&p, &(user("three", 3) + "{\"type\":\"assist"));
    let second = index_file(&p, Some(&first)).unwrap();
    assert_eq!(second.chunks.len(), 3);
    append(&p, "ant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"four\"}]}}\n");
    let third = index_file(&p, Some(&second)).unwrap();
    let full = index_file(&p, None).unwrap();
    assert_eq!(third.chunks, full.chunks);
    assert_eq!(third.events, full.events);
    assert_eq!(third.anchors, full.anchors);
    assert_eq!(third.indexed, std::fs::metadata(&p).unwrap().len());
}

#[test]
fn a_rewritten_or_shrunk_file_is_indexed_again() {
    let root = tmp("shrink");
    let p = write(&root, "-w", "s", &(user("old prompt", 1) + &answer("old answer", 2)));
    let first = index_file(&p, None).unwrap();
    std::fs::write(&p, user("new", 1)).unwrap();
    let second = index_file(&p, Some(&first)).unwrap();
    assert_eq!(second.chunks.len(), 1);
    assert_eq!(second.chunks[0].text, "new");
}

#[test]
fn refresh_reports_changed_and_removed_files_only() {
    let root = tmp("refresh");
    let a = write(&root, "-w-a", "a", &user("alpha", 1));
    write(&root, "-w-b", "b", &user("beta", 1));
    let mut docs = docs_of(&root);
    assert_eq!(docs.len(), 2);
    let dir = root.to_string_lossy().into_owned();
    let r = refresh(&dir, &docs);
    assert!(r.changed.is_empty() && r.removed.is_empty());
    std::fs::remove_file(&a).unwrap();
    append(&root.join("-w-b/b.jsonl"), &answer("more", 2));
    let r = refresh(&dir, &docs);
    assert_eq!(r.removed, vec![a.to_string_lossy().into_owned()]);
    assert_eq!(r.changed.len(), 1);
    assert_eq!(r.changed[0].chunks.len(), 2);
    for d in r.changed {
        docs.insert(d.meta.path.clone(), d);
    }
}

#[test]
fn missing_dir_and_unreadable_file_give_nothing() {
    let r = refresh("/nonexistent/agent-ide", &HashMap::new());
    assert!(r.changed.is_empty());
    assert!(index_file(std::path::Path::new("/nonexistent/x.jsonl"), None).is_none());
}

#[test]
fn store_round_trip_and_other_versions_are_ignored() {
    let root = tmp("store");
    write(&root, "-w", "s", &(user("stored prompt", 1) + &answer("stored answer", 2)));
    let docs = docs_of(&root);
    let file = root.join("cache").join(store::FILE_NAME);
    let dir = root.to_string_lossy().into_owned();
    store::save(&file, &dir, docs.values());
    let back = store::load(&file, &dir).unwrap();
    assert_eq!(back.len(), 1);
    assert_eq!(back[0].chunks, docs.values().next().unwrap().chunks);
    assert!(store::load(&file, "/other/dir").is_none(), "another projects dir is not reused");
    let mut v: serde_json::Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    v["version"] = "0.0.0-other".into();
    std::fs::write(&file, serde_json::to_vec(&v).unwrap()).unwrap();
    assert!(store::load(&file, &dir).is_none());
    std::fs::write(&file, "garbage").unwrap();
    assert!(store::load(&file, &dir).is_none());
    assert!(store::FILE_NAME.starts_with("search-v"));
}
