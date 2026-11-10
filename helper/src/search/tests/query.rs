use super::synth::*;
use crate::search::index::{refresh, Doc, Kind};
use crate::search::query::{search, Hit, Params, Quality, Scope};
use std::collections::HashMap;

fn build(files: &[(&str, &str, String)]) -> HashMap<String, Doc> {
    static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let root = tmp(&format!("q{}", N.fetch_add(1, std::sync::atomic::Ordering::SeqCst)));
    for (project, id, text) in files {
        write(&root, project, id, text);
    }
    refresh(&root.to_string_lossy(), &HashMap::new()).changed.into_iter().map(|d| (d.meta.path.clone(), d)).collect()
}

fn params(q: &str) -> Params {
    Params { query: q.into(), ..Params::default() }
}

/// Prompts and answers only: the title of a session without `ai-title` is its first prompt.
fn texts(q: &str) -> Params {
    Params { kinds: vec![Kind::Prompt, Kind::Answer], ..params(q) }
}

fn run(docs: &HashMap<String, Doc>, p: &Params) -> Vec<Hit> {
    search(docs.values(), p)
}

fn ids(hits: &[Hit]) -> Vec<(String, Kind)> {
    hits.iter().map(|h| (h.session.clone(), h.kind)).collect()
}

#[test]
fn prefix_before_substring_before_fuzzy() {
    let docs = build(&[
        ("-p", "fuzzy", user("mig rate the tables", 1)),
        ("-p", "sub", user("we remigrate later", 2)),
        ("-p", "prefix", user("migrate the db", 3)),
        ("-p", "none", user("nothing to see", 4)),
    ]);
    let hits = run(&docs, &texts("migrate"));
    let got: Vec<(&str, Quality)> = hits.iter().map(|h| (h.session.as_str(), h.quality)).collect();
    assert_eq!(got, vec![("prefix", Quality::Prefix), ("sub", Quality::Substring), ("fuzzy", Quality::Fuzzy)]);
    let exact = run(&docs, &Params { fuzzy: false, ..texts("migrate") });
    assert_eq!(exact.len(), 2);
}

#[test]
fn title_before_prompt_before_answer_then_newest_first() {
    let docs = build(&[
        ("-p", "answer", title("A") + &user("x", 9) + &answer("deploy finished", 9)),
        ("-p", "prompt-old", title("B") + &user("deploy now", 1)),
        ("-p", "prompt-new", title("C") + &user("deploy again", 5)),
        ("-p", "title", title("Deploy pipeline") + &user("y", 0)),
    ]);
    let hits = run(&docs, &params("deploy"));
    assert_eq!(
        ids(&hits),
        vec![
            ("title".into(), Kind::Title),
            ("prompt-new".into(), Kind::Prompt),
            ("prompt-old".into(), Kind::Prompt),
            ("answer".into(), Kind::Answer),
        ]
    );
    assert_eq!(hits[0].event, None);
    assert_eq!(hits[1].event, Some(1));
    assert!(hits[1].ts.unwrap() > hits[2].ts.unwrap());
}

#[test]
fn multi_word_queries_match_in_any_order_within_one_chunk() {
    let docs = build(&[
        ("-p", "both", user("the alpha release and the beta release", 1)),
        ("-p", "one", user("alpha only", 2) + &answer("beta elsewhere", 2)),
    ]);
    let hits = run(&docs, &Params { fuzzy: false, ..texts("beta alpha") });
    assert_eq!(ids(&hits), vec![("both".into(), Kind::Prompt)]);
    let h = &hits[0];
    let marked: Vec<&str> = h.positions.iter().map(|[s, e]| &h.snippet[*s..*e]).collect();
    assert_eq!(marked, vec!["alpha", "beta"]);
}

#[test]
fn smart_case_and_umlauts() {
    let docs = build(&[
        ("-p", "upper", user("Rust and Über die Brücke", 1)),
        ("-p", "lower", user("rust und über grüße", 2)),
    ]);
    let s = |q: &str| {
        let mut v: Vec<String> = run(&docs, &Params { fuzzy: false, ..texts(q) }).into_iter().map(|h| h.session).collect();
        v.sort();
        v
    };
    assert_eq!(s("rust"), vec!["lower", "upper"]);
    assert_eq!(s("Rust"), vec!["upper"]);
    assert_eq!(s("über"), vec!["lower", "upper"]);
    assert_eq!(s("Über"), vec!["upper"]);
    assert_eq!(s("brücke"), vec!["upper"]);
    assert_eq!(s("GRÜSSE"), Vec::<String>::new());
    let h = &run(&docs, &texts("brücke"))[0];
    let [a, b] = h.positions[0];
    assert_eq!(&h.snippet[a..b], "Brücke");
}

#[test]
fn spaces_only_is_the_empty_query_and_special_characters_are_literal() {
    let docs = build(&[("-p", "s", user("call f(x) then a.b* and ^$!'", 1) + &user("second", 2))]);
    let empty = run(&docs, &params("   \t "));
    assert_eq!(empty.len(), 3, "title and both prompts, newest first");
    assert!(empty.iter().all(|h| h.quality == Quality::Recent));
    for q in ["f(x)", "a.b*", "^$!'", "\\", "\"", "[", "%s"] {
        let hits = run(&docs, &texts(q));
        if ["f(x)", "a.b*", "^$!'"].contains(&q) {
            assert_eq!(hits.len(), 1, "query {q:?}");
            assert_ne!(hits[0].quality, Quality::Fuzzy, "query {q:?}");
        }
    }
}

#[test]
fn empty_prompt_query_lists_the_newest_prompts_first() {
    let docs = build(&[
        ("-a", "a", user("old prompt", 1) + &answer("an answer", 2) + &user("newer prompt", 30)),
        ("-b", "b", user("middle prompt", 10)),
    ]);
    let hits = run(&docs, &Params { kinds: vec![Kind::Prompt], ..params("") });
    let texts: Vec<&str> = hits.iter().map(|h| h.snippet.as_str()).collect();
    assert_eq!(texts, vec!["newer prompt", "middle prompt", "old prompt"]);
    let limited = run(&docs, &Params { kinds: vec![Kind::Prompt], limit: 2, ..params("") });
    assert_eq!(limited.len(), 2);
}

#[test]
fn scope_kinds_and_tool_calls() {
    let docs = build(&[
        ("-a", "a", user("cargo build please", 1) + &tool("Bash", "cargo build --release", "t1") + &result("t1", "cargo output")),
        ("-b", "b", user("cargo here too", 2)),
    ]);
    let hits = run(&docs, &texts("cargo"));
    assert!(hits.iter().all(|h| h.kind != Kind::Tool), "tool calls only on request");
    assert!(hits.iter().all(|h| !h.snippet.contains("output")), "tool output is never indexed");
    let with_tool = run(&docs, &Params { kinds: vec![Kind::Tool], ..params("cargo") });
    assert_eq!(ids(&with_tool), vec![("a".into(), Kind::Tool)]);
    assert_eq!(with_tool[0].snippet, "Bash: cargo build --release");
    let one = run(&docs, &Params { scope: Scope::Session("b".into()), ..texts("cargo") });
    assert_eq!(ids(&one), vec![("b".into(), Kind::Prompt)]);
    let some = run(&docs, &Params { scope: Scope::Sessions(["a".to_string()].into()), ..texts("cargo") });
    assert_eq!(ids(&some), vec![("a".into(), Kind::Prompt)]);
}

#[test]
fn titles_match_the_project_name_and_hits_carry_it() {
    let docs = build(&[("-w-repo", "s", title("Fix the parser") + &user("hello", 1))]);
    let mut p = Params { fuzzy: false, ..params("agents parser") };
    assert!(run(&docs, &p).is_empty());
    p.projects = [("/w/repo".to_string(), "agents-ide".to_string())].into();
    let hits = run(&docs, &p);
    assert_eq!(ids(&hits), vec![("s".into(), Kind::Project)]);
    assert_eq!(hits[0].project, "agents-ide");
    assert_eq!(hits[0].cwd.as_deref(), Some("/w/repo"));
    let plain = run(&docs, &params("hello"));
    assert_eq!(plain[0].project, "repo", "basename of cwd without a projects map");
}

#[test]
fn snippets_of_long_lines_are_windows_on_char_boundaries() {
    let line = format!("{} needle {}", "ö".repeat(400), "ü".repeat(400));
    let docs = build(&[("-p", "s", user(&line, 1))]);
    let h = &run(&docs, &texts("needle"))[0];
    assert!(h.snippet.len() < 300, "snippet is a window, got {} bytes", h.snippet.len());
    assert!(h.snippet.starts_with('…') && h.snippet.ends_with('…'));
    let [a, b] = h.positions[0];
    assert_eq!(&h.snippet[a..b], "needle");
}

#[test]
fn fuzzy_hits_mark_the_matched_letters_and_tolerate_typos() {
    let docs = build(&[("-p", "s", user("fix the umlaut bug", 1))]);
    let h = &run(&docs, &texts("umlatu"))[0];
    assert_eq!(h.quality, Quality::Fuzzy);
    assert!(!h.positions.is_empty());
    for [a, b] in &h.positions {
        assert!(h.snippet[*a..*b].chars().all(|c| "umlaut".contains(c)));
    }
    assert!(run(&docs, &params("zzzz")).is_empty());
}

#[test]
fn a_project_name_match_ranks_after_title_and_prompt_hits() {
    let docs = build(&[
        ("-w-agents", "p1", title("Parser fixes") + &user("first", 1)),
        ("-w-agents", "p2", title("Docs") + &user("second", 2)),
        ("-w-other", "o1", title("Other") + &user("agents talk about the parser", 3)),
        ("-w-other", "o2", title("Agents overview") + &user("x", 4)),
    ]);
    let p = Params { fuzzy: false, projects: [("/w/repo".to_string(), "agents".to_string())].into(), ..params("agents") };
    let hits = run(&docs, &p);
    // every session's cwd is /w/repo, named `agents`: titles and prompts first, then the
    // sessions found only through the project name, newest first
    assert_eq!(
        ids(&hits),
        vec![
            ("o2".into(), Kind::Title),
            ("o1".into(), Kind::Prompt),
            ("o1".into(), Kind::Project),
            ("p2".into(), Kind::Project),
            ("p1".into(), Kind::Project),
        ]
    );
}

#[test]
fn nonsense_queries_over_prose_find_nothing_and_typos_still_match() {
    let mut files = Vec::new();
    for i in 0..20 {
        files.push(("-p", ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t"][i], user(&prose(i as u64, 300), 1) + &answer(&prose(i as u64 + 100, 4000), 2)));
    }
    let docs = build(&files);
    for q in ["zzzzzz", "qxjvkw", "Donaudampfschifffahrtsgesellschaftskapitän", "xylophonequartz", "ßßßßßß"] {
        let hits = run(&docs, &texts(q));
        assert!(hits.is_empty(), "{q:?} gave {} hits, first {:?}", hits.len(), hits.first().map(|h| &h.snippet));
    }
    for q in ["migrte", "umlatu", "Übersetzng", "documentaton"] {
        assert!(!run(&docs, &texts(q)).is_empty(), "{q:?} found nothing");
    }
}
