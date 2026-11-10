use super::*;
use serde_json::{json, Value};

fn one(line: &str) -> Vec<Value> {
    parse_line(line.as_bytes())
}

fn inv(raw: &str) -> Value {
    json!({"kind":"unknown","label":"invalid JSON","raw":raw})
}

#[test]
fn blank_lines_yield_nothing_and_invalid_lines_are_unknown() {
    assert!(one("").is_empty());
    assert!(one("   \t").is_empty());
    let cut = r#"{"type":"user","message":{"content":"hal"#;
    assert_eq!(one(cut), vec![inv(cut)]);
    assert_eq!(one("not json"), vec![inv("not json")]);
    assert_eq!(one("42"), vec![json!({"kind":"unknown","label":"?","raw":"42"})]);
    assert_eq!(one("\"str\""), vec![json!({"kind":"unknown","label":"?","raw":"\"str\""})]);
    assert_eq!(one("null"), vec![json!({"kind":"unknown","label":"?","raw":"null"})]);
}

#[test]
fn only_an_unterminated_last_line_that_does_not_decode_is_skipped() {
    let cut = r#"{"type":"user","message":{"content":"hal"#;
    assert_eq!(parse_text(&format!("not json\n{cut}")), vec![inv("not json")]);
    assert_eq!(parse_text(&format!("{cut}\n")), vec![inv(cut)]);
    assert_eq!(parse_text(r#"{"type":"user","message":{"content":"whole"}}"#), vec![json!({"kind":"prompt","text":"whole"})]);
}

#[test]
fn object_content_and_null_elements_lose_nothing() {
    let obj = r#"{"type":"assistant","message":{"content":{"type":"text","text":"t"}}}"#;
    assert_eq!(one(obj), vec![json!({"kind":"unknown","label":"content","raw":obj})]);
    let nulls = r#"{"type":"user","message":{"content":{"a":null}}}"#;
    assert_eq!(one(nulls), vec![json!({"kind":"unknown","label":"content","raw":nulls})]);
    assert!(one(r#"{"type":"assistant","message":{"content":[]}}"#).is_empty());
    let n = json!({"kind":"unknown","label":"null","raw":"null"});
    assert_eq!(
        one(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"a"},null,{"type":"text","text":"b"},null]}}"#),
        vec![json!({"kind":"text","text":"a"}), n.clone(), json!({"kind":"text","text":"b"}), n]
    );
    let tr = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":[{"type":"text","text":"a"},null,{"type":"text","text":"b"}]}]}}"#;
    assert_eq!(one(tr)[0]["text"], json!("a\n[null]\nb"));
}

#[test]
fn invalid_utf8_is_replaced_before_decoding() {
    let ev = parse_line(b"{\"type\":\"user\",\"message\":{\"content\":\"bad \xff byte\"}}");
    assert_eq!(ev, vec![json!({"kind":"prompt","text":"bad \u{fffd} byte"})]);
    let ev = parse_line(b"not json \xfe");
    assert_eq!(ev, vec![inv("not json \u{fffd}")]);
}

#[test]
fn system_records_are_meta_events() {
    assert_eq!(
        one(r#"{"type":"system","subtype":"compact_boundary","content":"done"}"#),
        vec![json!({"kind":"meta","label":"system: compact_boundary","text":"done"})]
    );
    let line = r#"{"type":"system","isSidechain":true,"content":{"a":1}}"#;
    assert_eq!(one(line), vec![json!({"kind":"meta","label":"system","text":line,"sidechain":true})]);
    assert!(one(r#"{"type":"attachment","x":1}"#).is_empty());
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
    // raw is always the original text of that exact block, scalars included
    assert_eq!(ev[1], json!({"kind":"unknown","label":"video","raw":r#"{"type":"video","a":1}"#,"sidechain":true}));
    assert_eq!(ev[2], json!({"kind":"unknown","label":"string","raw":r#""s""#,"sidechain":true}));
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
fn non_table_content_is_unknown_record() {
    let line = r#"{"type":"user","message":{"content":5}}"#;
    assert_eq!(one(line), vec![json!({"kind":"unknown","label":"user","raw":line})]);
}

#[test]
fn raw_is_exact_substring_with_braces_escapes_and_nesting() {
    let block = r#"{"type": "odd" , "k":"{[\"x\"]} \\", "n":[[1,{"a":"]"}], 2],"o":{"z":[]}}"#;
    let line = format!(r#"{{"type":"assistant","message":{{"content":["scalar", 7 ,{block},{{"type":"text","text":"ok"}}]}}}}"#);
    let ev = one(&line);
    assert_eq!(ev[0], json!({"kind":"unknown","label":"string","raw":r#""scalar""#}));
    assert_eq!(ev[1], json!({"kind":"unknown","label":"number","raw":"7"}));
    assert_eq!(ev[2], json!({"kind":"unknown","label":"odd","raw":block}));
    assert_eq!(ev[3], json!({"kind":"text","text":"ok"}));
}

#[test]
fn numeric_block_type_label_uses_lua_number_format() {
    let label = |n: &str| one(&format!(r#"{{"type":"assistant","message":{{"content":[{{"type":{n}}}]}}}}"#))[0]["label"].clone();
    assert_eq!(label("100000000000000"), json!("1e+14"));
    assert_eq!(label("99999999999999"), json!("99999999999999"));
    assert_eq!(label("5"), json!("5"));
    assert_eq!(label("1.5"), json!("1.5"));
    assert_eq!(label("0.0001"), json!("0.0001"));
    assert_eq!(label("0.00001"), json!("1e-05"));
    assert_eq!(label("123456789012345678"), json!("1.2345678901235e+17"));
}
