//! Every golden in tests/fixtures/golden must equal the events parsed from its fixture.
use agent_ide_helper::events::parse_bytes;
use serde_json::Value;
use std::path::PathBuf;

/// golden name -> fixture transcript (relative to tests/fixtures).
const TABLE: &[(&str, &str)] = &[
    ("alpha-basic", "projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl"),
    ("edge-cases", "edge/edge-cases.jsonl"),
];

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("tests").join("fixtures")
}

#[test]
fn every_golden_matches_its_fixture() {
    let mut seen = 0;
    for (name, fixture) in TABLE {
        let golden: Value = serde_json::from_str(
            &std::fs::read_to_string(root().join("golden").join(format!("{name}.events.json"))).unwrap(),
        )
        .unwrap();
        // bytes, not a string: the edge fixture holds invalid UTF-8 on purpose
        let data = std::fs::read(root().join(fixture)).unwrap();
        let got = Value::Array(parse_bytes(&data));
        assert_eq!(got, golden, "golden {name}");
        seen += 1;
    }
    assert_eq!(seen, TABLE.len());
}

#[test]
fn table_covers_every_golden_file() {
    let mut names: Vec<String> = std::fs::read_dir(root().join("golden"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter_map(|n| n.strip_suffix(".events.json").map(String::from))
        .collect();
    names.sort();
    let mut table: Vec<String> = TABLE.iter().map(|(n, _)| n.to_string()).collect();
    table.sort();
    assert_eq!(names, table);
}
