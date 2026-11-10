use crate::protocol::{Out, Server};
use serde_json::{json, Value};

fn server() -> Server {
    Server::new(None, Out::sink())
}

#[test]
fn nonsense_line_is_error_with_null_id() {
    let r = server().handle_line("nonsense").unwrap();
    assert_eq!(r["id"], Value::Null);
    assert!(r["error"]["message"].is_string());
}

#[test]
fn unknown_method_keeps_id_and_process_runs_on() {
    let mut s = server();
    let r = s.handle_line(r#"{"id":3,"method":"nope"}"#).unwrap();
    assert_eq!(r["id"], json!(3));
    assert!(r["error"]["message"].is_string());
    let r = s.handle_line(r#"{"id":4,"method":"history","params":{"path":"/nonexistent/a.jsonl"}}"#).unwrap();
    assert_eq!(r["id"], json!(4));
    assert!(r["error"]["message"].is_string());
}

#[test]
fn bad_params_are_errors() {
    let mut s = server();
    assert!(s.handle_line(r#"{"id":1,"method":"scan"}"#).unwrap()["error"].is_object());
    assert!(s.handle_line(r#"{"id":2,"method":"history","params":{}}"#).unwrap()["error"].is_object());
    assert!(s.handle_line(r#"{"id":5}"#).unwrap()["error"].is_object());
    assert!(s.handle_line("[1]").unwrap()["error"].is_object());
}

#[test]
fn blank_line_gets_no_response() {
    assert!(server().handle_line("  ").is_none());
}

#[test]
fn scan_and_history_over_fixtures() {
    let root = format!("{}/../tests/fixtures", env!("CARGO_MANIFEST_DIR"));
    let mut s = server();
    let r = s.handle_line(&json!({"id":1,"method":"scan","params":{"projects_dir":format!("{root}/projects")}}).to_string()).unwrap();
    assert_eq!(r["result"]["sessions"].as_array().unwrap().len(), 4);
    let p = format!("{root}/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl");
    let r = s.handle_line(&json!({"id":2,"method":"history","params":{"path":p}}).to_string()).unwrap();
    let golden: Value = serde_json::from_str(&std::fs::read_to_string(format!("{root}/golden/alpha-basic.events.json")).unwrap()).unwrap();
    assert_eq!(r["result"]["events"], golden);
}

#[test]
fn hello_reports_the_rules_version() {
    let r = server().handle_line(r#"{"id":7,"method":"hello"}"#).unwrap();
    assert_eq!(r["id"], json!(7));
    assert_eq!(r["result"]["rules_version"], json!(crate::events::RULES_VERSION));
    assert_eq!(r["result"]["crate_version"], json!(env!("CARGO_PKG_VERSION")));
}

/// The Lua parser's `M.RULES_VERSION` must equal ours: both backends follow the same rules.
#[test]
fn rules_version_matches_the_lua_side() {
    let path = format!("{}/../lua/agent-ide/transcript/parse.lua", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(path).unwrap();
    let line = text.lines().find(|l| l.starts_with("M.RULES_VERSION = ")).expect("M.RULES_VERSION in parse.lua");
    let lua: u64 = line["M.RULES_VERSION = ".len()..].trim().parse().unwrap();
    assert_eq!(lua, crate::events::RULES_VERSION);
}
