//! Ranked search over the indexed documents.
//!
//! The query is split on whitespace; every word must match the same chunk, in any order. A
//! word matches as `prefix` (case-insensitive substring at a word start), `substring`, or
//! `fuzzy` (see `matching`); a title also matches a word found in its project's name. The
//! chunk's match is its weakest word. Order: exact (prefix or substring) before fuzzy, then
//! title > prompt > answer > tool, then prefix before substring and fuzzy by score, then newest
//! first. An empty query lists chunks newest first (`recent`): with kinds = prompt, that is the
//! prompt history.
use super::index::{Chunk, Doc, Kind};
use super::matching::{segments, Fuzzy, Word};
use super::snippet;
use rayon::prelude::*;
use serde::Serialize;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

pub const DEFAULT_LIMIT: usize = 50;
pub const MAX_LIMIT: usize = 500;

#[derive(Clone, Debug)]
pub enum Scope {
    All,
    Sessions(HashSet<String>),
    Session(String),
}

#[derive(Clone, Debug)]
pub struct Params {
    pub query: String,
    pub scope: Scope,
    pub kinds: Vec<Kind>,
    pub limit: usize,
    pub fuzzy: bool,
    /// cwd -> project name (from the Lua side's grouping); else the basename of cwd.
    pub projects: HashMap<String, String>,
}

impl Default for Params {
    fn default() -> Params {
        Params {
            query: String::new(),
            scope: Scope::All,
            kinds: vec![Kind::Title, Kind::Prompt, Kind::Answer],
            limit: DEFAULT_LIMIT,
            fuzzy: true,
            projects: HashMap::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Quality {
    Fuzzy,
    Substring,
    Prefix,
    Recent,
}

#[derive(Debug, Serialize)]
pub struct Hit {
    pub session: String,
    pub path: String,
    pub cwd: Option<String>,
    pub project: String,
    pub title: String,
    pub kind: Kind,
    pub event: Option<u32>,
    pub ts: Option<u64>,
    pub snippet: String,
    pub positions: Vec<[usize; 2]>,
    #[serde(rename = "match")]
    pub quality: Quality,
    pub score: u32,
}

struct Cand<'a> {
    doc: &'a Doc,
    chunk: Option<&'a Chunk>,
    kind: Kind,
    quality: Quality,
    score: u32,
}

impl Cand<'_> {
    fn kind(&self) -> Kind {
        self.kind
    }
    fn ts(&self) -> Option<u64> {
        self.chunk.map_or(Some(self.doc.meta.activity), |c| c.ts)
    }
    fn text(&self) -> &str {
        self.chunk.map_or(&self.doc.meta.title, |c| &c.text)
    }
    fn event(&self) -> Option<u32> {
        self.chunk.map(|c| c.event)
    }
}

fn project_name<'a>(doc: &'a Doc, projects: &'a HashMap<String, String>) -> &'a str {
    match &doc.meta.cwd {
        Some(cwd) => projects.get(cwd).map(String::as_str).unwrap_or_else(|| cwd.rsplit('/').next().unwrap_or(cwd)),
        None => "?",
    }
}

fn in_scope(doc: &Doc, scope: &Scope) -> bool {
    match scope {
        Scope::All => true,
        Scope::Sessions(ids) => ids.contains(&doc.meta.id),
        Scope::Session(id) => doc.meta.id == *id,
    }
}

fn fuzzies(words: &[Word], on: bool) -> Vec<Option<Fuzzy>> {
    words.iter().map(|w| if on { Fuzzy::new(w) } else { None }).collect()
}

/// The weakest word's quality, the fuzzy score and whether a word matched only the project
/// name; `None` when a word does not match.
fn match_text(text: &str, words: &[Word], fz: &mut [Option<Fuzzy>], project: Option<&str>) -> Option<(Quality, u32, bool)> {
    let mut worst = Quality::Prefix;
    let mut score = 0u32;
    let mut via_project = false;
    for (i, w) in words.iter().enumerate() {
        let q = if let Some((_, _, prefix)) = w.exact(text) {
            if prefix { Quality::Prefix } else { Quality::Substring }
        } else if project.is_some_and(|p| w.find(p, 0).is_some()) {
            via_project = true;
            Quality::Substring
        } else {
            let (s, _) = fz[i].as_mut()?.best(text)?;
            score += s as u32;
            Quality::Fuzzy
        };
        worst = worst.min(q);
    }
    Some((worst, score, via_project))
}

/// One searchable text: a session's title (`chunk` = None) or one chunk.
type Unit<'a> = (&'a Doc, Option<&'a Chunk>);

fn match_unit<'a>(u: &Unit<'a>, words: &[Word], fz: &mut [Option<Fuzzy>], p: &Params) -> Option<Cand<'a>> {
    let (doc, chunk) = *u;
    if words.is_empty() {
        let kind = chunk.map_or(Kind::Title, |c| c.kind);
        return Some(Cand { doc, chunk, kind, quality: Quality::Recent, score: 0 });
    }
    match chunk {
        None => {
            let project = project_name(doc, &p.projects);
            let (quality, score, via) = match_text(&doc.meta.title, words, fz, Some(project))?;
            // a session found through its project's name ranks after every other hit
            Some(Cand { doc, chunk, kind: if via { Kind::Project } else { Kind::Title }, quality, score })
        }
        Some(c) => {
            let (quality, score, _) = match_text(&c.text, words, fz, None)?;
            Some(Cand { doc, chunk, kind: c.kind, quality, score })
        }
    }
}

fn order(a: &Cand, b: &Cand, empty: bool) -> Ordering {
    let ts = b.ts().unwrap_or(0).cmp(&a.ts().unwrap_or(0));
    let lead = if empty {
        ts.then(a.kind().rank().cmp(&b.kind().rank()))
    } else {
        let exact = |c: &Cand| c.quality >= Quality::Substring;
        exact(b)
            .cmp(&exact(a))
            .then(a.kind().rank().cmp(&b.kind().rank()))
            .then(b.quality.cmp(&a.quality))
            .then(b.score.cmp(&a.score))
            .then(ts)
    };
    lead.then_with(|| a.doc.meta.id.cmp(&b.doc.meta.id)).then(a.event().cmp(&b.event()))
}

/// Byte offset the snippet is centred on: the first exact match of a word, else the first
/// letter of the first fuzzy match, else the first non-blank character.
fn anchor(text: &str, words: &[Word], fz: &mut [Option<Fuzzy>]) -> usize {
    if let Some(s) = words.iter().find_map(|w| w.exact(text).map(|m| m.0)) {
        return s;
    }
    for f in fz.iter_mut().flatten() {
        if let Some((_, seg)) = f.best(text) {
            let end = segments(text).find(|(s, _)| *s == seg).map_or(text.len(), |(_, e)| e);
            return seg + f.indices(&text[seg..end]).first().copied().unwrap_or(0);
        }
    }
    text.find(|c: char| !c.is_whitespace()).unwrap_or(0)
}

fn hit(c: &Cand, words: &[Word], p: &Params) -> Hit {
    let mut fz = fuzzies(words, p.fuzzy);
    let text = c.text();
    let at = anchor(text, words, &mut fz);
    let (snippet, positions) = snippet::make(text, at, words, &mut fz);
    let m = &c.doc.meta;
    Hit {
        session: m.id.clone(),
        path: m.path.clone(),
        cwd: m.cwd.clone(),
        project: project_name(c.doc, &p.projects).to_string(),
        title: m.title.clone(),
        kind: c.kind(),
        event: c.event(),
        ts: c.ts(),
        snippet,
        positions,
        quality: c.quality,
        score: c.score,
    }
}

pub fn search<'a>(docs: impl Iterator<Item = &'a Doc>, p: &Params) -> Vec<Hit> {
    search_counted(docs, p).0
}

/// The hits and how many matched in all (the hits are the best `limit` of them; with fuzzy
/// matching the count is a lower bound when the exact matches alone filled the limit).
pub fn search_counted<'a>(docs: impl Iterator<Item = &'a Doc>, p: &Params) -> (Vec<Hit>, usize) {
    let mut words: Vec<Word> = p.query.split_whitespace().map(Word::new).collect();
    // the longest word first: it fails soonest on texts that do not match
    words.sort_by_key(|w| std::cmp::Reverse(w.raw.len()));
    let mut kinds = [false; 5];
    for k in &p.kinds {
        kinds[*k as usize] = true;
    }
    let mut units: Vec<Unit> = Vec::new();
    for d in docs.filter(|d| in_scope(d, &p.scope)) {
        if kinds[Kind::Title as usize] {
            units.push((d, None));
        }
        units.extend(d.chunks.iter().filter(|c| kinds[c.kind as usize]).map(|c| (d, Some(c))));
    }
    let empty = words.is_empty();
    let limit = p.limit.clamp(1, MAX_LIMIT);
    // Exact matches rank before fuzzy ones: the fuzzy pass runs only when they leave room.
    let exact: Vec<Option<Cand>> =
        units.par_iter().map_init(|| fuzzies(&words, false), |fz, u| match_unit(u, &words, fz, p)).collect();
    let mut cands: Vec<Cand> = Vec::new();
    let mut missed: Vec<&Unit> = Vec::new();
    for (u, c) in units.iter().zip(exact) {
        match c {
            Some(c) => cands.push(c),
            None => missed.push(u),
        }
    }
    if p.fuzzy && !empty && cands.len() < limit {
        let fuzzy: Vec<Cand> =
            missed.par_iter().map_init(|| fuzzies(&words, true), |fz, u| match_unit(u, &words, fz, p)).flatten().collect();
        cands.extend(fuzzy);
    }
    let total = cands.len();
    if cands.len() > limit {
        cands.select_nth_unstable_by(limit - 1, |a, b| order(a, b, empty));
        cands.truncate(limit);
    }
    cands.sort_by(|a, b| order(a, b, empty));
    (cands.par_iter().map(|c| hit(c, &words, p)).collect(), total)
}
