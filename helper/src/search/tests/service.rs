use super::synth::*;
use crate::events::parse_bytes;
use crate::protocol::{Out, Server};
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Instant;

struct Capture(Arc<Mutex<Vec<u8>>>);
impl Write for Capture {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn server(cache: Option<&Path>) -> (Server, Arc<Mutex<Vec<u8>>>) {
    let buf = Arc::new(Mutex::new(Vec::new()));
    (Server::new(cache.map(Path::to_path_buf), Out::new(Box::new(Capture(buf.clone())))), buf)
}

fn call(s: &mut Server, method: &str, params: Value) -> Value {
    let line = json!({"id": 1, "method": method, "params": params}).to_string();
    s.handle_line(&line).unwrap()
}

fn search(s: &mut Server, dir: &Path, extra: Value) -> Value {
    let mut p = json!({"projects_dir": dir.to_string_lossy(), "wait": true});
    for (k, v) in extra.as_object().unwrap() {
        p[k] = v.clone();
    }
    let r = call(s, "search", p);
    assert!(r["error"].is_null(), "{r}");
    r["result"].clone()
}

fn notes(buf: &Arc<Mutex<Vec<u8>>>) -> Vec<Value> {
    let text = String::from_utf8(buf.lock().unwrap().clone()).unwrap();
    text.lines().map(|l| serde_json::from_str(l).unwrap()).filter(|v: &Value| v["method"] == "search_ready").collect()
}

#[test]
fn first_search_builds_saves_and_notifies_then_the_cache_is_reused() {
    let root = tmp("svc");
    let projects = root.join("projects");
    let cache = root.join("cache");
    write(&projects, "-w-a", "a", &(user("deploy the parser", 1) + &answer("parser deployed", 2)));
    let b = write(&projects, "-w-b", "b", &user("unrelated", 3));
    let (mut s, buf) = server(Some(&cache));
    let r = search(&mut s, &projects, json!({"query": "parser", "kinds": ["prompt", "answer"]}));
    assert_eq!(r["indexing"], false);
    assert_eq!((r["sessions"].as_u64(), r["chunks"].as_u64()), (Some(2), Some(3)));
    let hits = r["hits"].as_array().unwrap();
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0]["kind"], "prompt");
    assert_eq!(hits[0]["session"], "a");
    assert_eq!(hits[0]["event"], 1);
    assert_eq!(hits[0]["match"], "prefix");
    assert!(hits[0]["ts"].is_u64() && hits[0]["positions"].is_array() && hits[0]["path"].is_string());
    assert!(!notes(&buf).is_empty(), "search_ready after the build");
    assert!(cache.join(crate::search::store::FILE_NAME).exists());

    append(&b, &user("parser news", 4));
    let (mut s2, _) = server(Some(&cache));
    let r = search(&mut s2, &projects, json!({"query": "parser", "kinds": ["prompt"]}));
    assert_eq!(r["from_cache"], 2);
    assert_eq!(r["hits"].as_array().unwrap().len(), 2, "the appended prompt is indexed too");
}

#[test]
fn later_changes_are_written_at_most_every_30_s_and_when_the_helper_exits() {
    let root = tmp("save");
    let projects = root.join("projects");
    let cache = root.join("cache");
    let p = write(&projects, "-w", "s", &user("first", 1));
    let file = cache.join(crate::search::store::FILE_NAME);
    let (mut s, _) = server(Some(&cache));
    search(&mut s, &projects, json!({}));
    let saved = std::fs::read(&file).unwrap();
    append(&p, &user("second", 2));
    std::thread::sleep(std::time::Duration::from_millis(1100)); // the next pass may start
    let r = search(&mut s, &projects, json!({"query": "second", "kinds": ["prompt"]}));
    assert_eq!(r["hits"].as_array().unwrap().len(), 1);
    assert_eq!(std::fs::read(&file).unwrap(), saved, "not written again within 30 s");
    drop(s);
    let docs = crate::search::store::load(&file, &projects.to_string_lossy()).unwrap();
    assert_eq!(docs[0].chunks.len(), 2, "written when the helper exits");
}

#[test]
fn scope_and_bad_params() {
    let root = tmp("scope");
    write(&root, "-w-a", "a", &user("shared word", 1));
    write(&root, "-w-b", "b", &user("shared word", 2));
    let (mut s, _) = server(None);
    let n = |r: &Value| r["hits"].as_array().unwrap().len();
    assert_eq!(n(&search(&mut s, &root, json!({"query": "shared", "kinds": ["prompt"]}))), 2);
    assert_eq!(n(&search(&mut s, &root, json!({"query": "shared", "kinds": ["prompt"], "scope": {"session": "b"}}))), 1);
    let r = search(&mut s, &root, json!({"query": "shared", "kinds": ["prompt"], "scope": {"project": "/w/a", "sessions": ["a"]}}));
    assert_eq!(r["hits"][0]["session"], "a");
    assert_eq!(n(&r), 1);
    assert!(call(&mut s, "search", json!({"query": "x"}))["error"].is_object());
    assert!(call(&mut s, "search", json!({"projects_dir": "/x", "scope": 3}))["error"].is_object());
    assert!(call(&mut s, "context", json!({"path": "/x"}))["error"].is_object());
    assert!(call(&mut s, "context", json!({"path": "/nonexistent/x.jsonl", "event": 1}))["error"].is_object());
}

#[test]
fn context_returns_the_turn_of_an_event_even_after_a_rewrite() {
    let root = tmp("ctx");
    let text = answer("before any prompt", 0)
        + &user("first", 1)
        + &answer("one", 2)
        + &tool("Bash", "ls", "t1")
        + &result("t1", "out")
        + &user("second", 3)
        + &answer("two", 4);
    let p = write(&root, "-w", "s", &text);
    let (mut s, _) = server(None);
    search(&mut s, &root, json!({"query": ""}));
    let all = parse_bytes(text.as_bytes());
    let ctx = |s: &mut Server, ev: u32| call(s, "context", json!({"path": p.to_string_lossy(), "event": ev}))["result"].clone();
    let r = ctx(&mut s, 4);
    assert_eq!(r["first"], 2);
    assert_eq!(r["events"], Value::Array(all[1..5].to_vec()));
    assert_eq!(ctx(&mut s, 1)["events"], Value::Array(all[0..1].to_vec()));
    assert_eq!(ctx(&mut s, 7)["first"], 6);
    // rewritten behind the index's back: the anchors no longer fit, the whole file is parsed
    let other = user("new first", 1) + &answer("x", 2) + &answer("y", 3) + &user("new second", 4) + &answer("z", 5);
    std::fs::write(&p, &other).unwrap();
    let all = parse_bytes(other.as_bytes());
    let r = ctx(&mut s, 3);
    assert_eq!(r["first"], 1);
    assert_eq!(r["events"], Value::Array(all[0..3].to_vec()));
    assert!(call(&mut s, "context", json!({"path": p.to_string_lossy(), "event": 99}))["error"].is_object());
}

/// Speed budgets of the search (release builds only: `cargo test --release`; the Lua budget
/// test measures the same through the built helper).
#[test]
#[cfg_attr(debug_assertions, ignore)]
fn budget_200_sessions_of_50_mb_build_under_3_s_and_query_under_30_ms() {
    let root = tmp("budget");
    let mut total = 0;
    for i in 0..200 {
        let text = prose_session(i, 60, 1500);
        total += text.len();
        write(&root, &format!("-w-p{}", i % 30), &format!("s{i}"), &text);
    }
    assert!(total > 45_000_000, "{total}");
    let (mut s, _) = server(None);
    let t0 = Instant::now();
    let r = search(&mut s, &root, json!({"query": ""}));
    let build = t0.elapsed().as_millis();
    assert_eq!(r["sessions"], 200);
    let text = r["text_bytes"].as_u64().unwrap();
    eprintln!("build of {total} bytes ({text} bytes of indexed text): {build} ms, {} chunks", r["chunks"]);
    assert!(text > 25_000_000, "realistic volume of indexed text: {text}");
    assert!(build < 3000, "build took {build} ms");
    let queries = [
        "parser", "release notes", "übersetzung", "prsr", "zzzzzz", "Übersetzungsfehlerbehebungsmaßnahmen",
        "größenänderung brückenpfeiler", "documentaton", "qxjvkw",
    ];
    for q in queries {
        let mut best = f64::MAX;
        for _ in 0..3 {
            let r = search(&mut s, &root, json!({"query": q, "kinds": ["title", "prompt", "answer", "tool"], "limit": 200}));
            best = best.min(r["took_ms"].as_f64().unwrap());
        }
        eprintln!("query {q:?}: {best:.2} ms");
        assert!(best < 30.0, "query {q:?} took {best} ms");
    }
}
