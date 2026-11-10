use super::*;
use serde_json::{json, Value};

fn one(line: &str) -> Vec<Value> {
    parse_line(line.as_bytes())
}

#[test]
fn cut_off_last_line_and_invalid_lines_yield_nothing() {
    assert!(one("").is_empty());
    assert!(one("   \t").is_empty());
    assert!(one(r#"{"type":"user","message":{"content":"hal"#).is_empty());
    assert!(one("not json").is_empty());
    assert!(one("42").is_empty());
    assert!(one("\"str\"").is_empty());
    assert!(one("null").is_empty());
    assert!(parse_text("not json\n{\"type\":\"user\",\"message\":{\"content\":\"hal").is_empty());
}

#[test]
fn unknown_record_keeps_original_line() {
    let line = r#"{"type":"future-thing",  "x":1}"#;
    assert_eq!(one(line), vec![json!({"kind":"unknown","label":"future-thing","raw":line})]);
}

#[test]
fn non_object_json_that_is_a_table_in_lua_is_unknown_question_mark() {
    assert_eq!(one("[1,2]"), vec![json!({"kind":"unknown","label":"?","raw":"[1,2]"})]);
    assert_eq!(one("{}"), vec![json!({"kind":"unknown","label":"?","raw":"{}"})]);
    assert_eq!(one(r#"{"type":5}"#), vec![json!({"kind":"unknown","label":"?","raw":r#"{"type":5}"#})]);
}

#[test]
fn bookkeeping_yields_nothing() {
    assert!(one(r#"{"type":"api-request-blob","hash":"h","message":{"content":"zzz"}}"#).is_empty());
}

#[test]
fn user_strings() {
    let u = |s: &str| one(&json!({"type":"user","message":{"content":s}}).to_string());
    assert_eq!(u("hi"), vec![json!({"kind":"prompt","text":"hi"})]);
    assert_eq!(u("<command-name>/compact</command-name><command-args>x y</command-args>"), vec![json!({"kind":"prompt","text":"/compact x y"})]);
    assert_eq!(u("<command-name>/clear</command-name>"), vec![json!({"kind":"prompt","text":"/clear"})]);
    assert_eq!(u("  \n<local-command-stdout>out</local-command-stdout> \n"), vec![json!({"kind":"meta","label":"command output","text":"out"})]);
    assert_eq!(u("<local-command-stdout>a</local-command-stdout>b"), vec![json!({"kind":"meta","label":"meta","text":"<local-command-stdout>a</local-command-stdout>b"})]);
    assert_eq!(u("<x>"), vec![json!({"kind":"meta","label":"meta","text":"<x>"})]);
    let m = one(r#"{"type":"user","isMeta":true,"message":{"content":"plain"}}"#);
    assert_eq!(m, vec![json!({"kind":"meta","label":"meta","text":"plain"})]);
}

#[test]
fn assistant_string_content_is_text() {
    assert_eq!(one(r#"{"type":"assistant","message":{"content":""}}"#), vec![json!({"kind":"text","text":""})]);
}

#[test]
fn blocks_and_sidechain() {
    let line = r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"thinking","thinking":""},{"type":"tool_use","name":"B"},{"type":"video","a":1},"s",{"type":"x"}]}}"#;
    let ev = one(line);
    assert_eq!(ev[0], json!({"kind":"tool_call","name":"B","input":{},"sidechain":true}));
    // raw text comes from the original line; Lua's scanner skips the string element, so it is misaligned.
    assert_eq!(ev[1], json!({"kind":"unknown","label":"video","raw":r#"{"type":"video","a":1}"#,"sidechain":true}));
    assert_eq!(ev[2], json!({"kind":"unknown","label":"string","raw":r#"{"type":"x"}"#,"sidechain":true}));
    assert_eq!(ev[3], json!({"kind":"unknown","label":"x","raw":r#"{"type":"x"}"#,"sidechain":true}));
}

#[test]
fn tool_result_flattening() {
    let line = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":[{"type":"text","text":"l1"},{"type":"image"},{},"s",5],"is_error":true},{"type":"tool_result","content":{"k":1}}]}}"#;
    assert_eq!(
        one(line),
        vec![
            json!({"kind":"tool_result","id":"a","text":"l1\n[image]\n[nil]\n[string]\n[number]","is_error":true}),
            json!({"kind":"tool_result","text":"","is_error":false}),
        ]
    );
}

#[test]
fn null_in_content_array_stops_iteration_like_lua_ipairs() {
    let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"a"},null,{"type":"text","text":"b"}]}}"#;
    assert_eq!(one(line), vec![json!({"kind":"text","text":"a"})]);
}

#[test]
fn non_table_content_is_unknown_record() {
    let line = r#"{"type":"user","message":{"content":5}}"#;
    assert_eq!(one(line), vec![json!({"kind":"unknown","label":"user","raw":line})]);
    assert!(one(r#"{"type":"user","message":{"content":{"a":1}}}"#).is_empty());
}
