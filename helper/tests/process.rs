//! End-to-end: the real binary over pipes.
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

fn fixtures() -> String {
    format!("{}/../tests/fixtures/projects", env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn answers_every_line_survives_garbage_and_exits_when_stdin_closes() {
    let cache = std::env::temp_dir().join(format!("agent-ide-helper-proc-{}", std::process::id()));
    let mut child = Command::new(env!("CARGO_BIN_EXE_agent-ide-helper"))
        .arg("--cache-dir")
        .arg(&cache)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let mut ask = |line: &str| -> serde_json::Value {
        writeln!(stdin, "{line}").unwrap();
        let mut resp = String::new();
        out.read_line(&mut resp).unwrap();
        serde_json::from_str(&resp).unwrap()
    };
    assert!(ask("{{{{").get("error").is_some());
    assert!(ask(r#"{"id":1,"method":"nope"}"#)["error"]["message"].is_string());
    let r = ask(&format!(r#"{{"id":2,"method":"scan","params":{{"projects_dir":"{}"}}}}"#, fixtures()));
    assert_eq!(r["id"], 2);
    assert_eq!(r["result"]["sessions"].as_array().unwrap().len(), 4);
    assert!(cache.join("index-v1.json").exists());
    drop(stdin);
    let status = child.wait().unwrap();
    assert!(status.success());
    let _ = std::fs::remove_dir_all(&cache);
}
