//! The line of a hit shown in the picker, with the byte ranges of what matched.
use super::matching::{Fuzzy, Word};

/// Lines longer than this are shown as a window around the match.
pub const WIDTH: usize = 160;
const BEFORE: usize = 40;
const MORE: &str = "…";

fn floor(s: &str, mut i: usize) -> usize {
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Merge overlapping or touching ranges (sorted by start).
fn merge(mut v: Vec<[usize; 2]>) -> Vec<[usize; 2]> {
    v.sort_unstable();
    let mut out: Vec<[usize; 2]> = Vec::with_capacity(v.len());
    for r in v {
        match out.last_mut() {
            Some(last) if r[0] <= last[1] => last[1] = last[1].max(r[1]),
            _ => out.push(r),
        }
    }
    out
}

/// Byte ranges of `words` in `body`: every exact occurrence, else the letters of the fuzzy match.
fn positions(body: &str, words: &[Word], fuzzies: &mut [Option<Fuzzy>]) -> Vec<[usize; 2]> {
    let mut out = Vec::new();
    for (i, w) in words.iter().enumerate() {
        let mut from = 0;
        let mut found = false;
        while let Some((s, e)) = w.find(body, from) {
            out.push([s, e]);
            found = true;
            from = e.max(s + 1);
        }
        if found {
            continue;
        }
        if let Some(f) = fuzzies.get_mut(i).and_then(Option::as_mut) {
            for b in f.indices(body) {
                if body.is_char_boundary(b) {
                    let len = body[b..].chars().next().map_or(1, char::len_utf8);
                    out.push([b, b + len]);
                }
            }
        }
    }
    merge(out)
}

/// The line of `text` holding byte `at` (a window of about `WIDTH` bytes around it when the
/// line is longer, marked with `…`), and the matched ranges in it. ASCII control characters
/// (tabs, carriage returns) become spaces, so the ranges stay valid byte offsets.
pub fn make(text: &str, at: usize, words: &[Word], fuzzies: &mut [Option<Fuzzy>]) -> (String, Vec<[usize; 2]>) {
    let at = floor(text, at.min(text.len()));
    let ls = text[..at].rfind('\n').map_or(0, |p| p + 1);
    let le = text[at..].find('\n').map_or(text.len(), |p| at + p);
    let (s, e) = if le - ls <= WIDTH {
        (ls, le)
    } else {
        let s = floor(text, at.saturating_sub(BEFORE).max(ls));
        (s, floor(text, (s + WIDTH).min(le)))
    };
    let body = &text[s..e];
    let pre = if s > ls { MORE } else { "" };
    let mut out = String::with_capacity(body.len() + 6);
    out.push_str(pre);
    out.extend(body.chars().map(|c| if c.is_ascii_control() { ' ' } else { c }));
    if e < le {
        out.push_str(MORE);
    }
    let shift = pre.len();
    let pos = positions(body, words, fuzzies).into_iter().map(|[a, b]| [a + shift, b + shift]).collect();
    (out, pos)
}
