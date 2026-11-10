//! Matching one query word against one text.
//!
//! Exact matching is a case-insensitive substring search (smart case: a word with an uppercase
//! letter matches case-sensitively). Non-ASCII words compare characters lower-cased one by one,
//! so `über` finds `Über`. Fuzzy matching uses `neo_frizbee` (Smith-Waterman, typo-tolerant) per
//! line of the text; lines longer than `SEGMENT` bytes are matched in pieces so a match stays
//! local. A fuzzy match counts only when it scores at least a minimum and its matched letters
//! lie close together (within the word's length plus its typos plus 2 bytes), so letters
//! scattered over a line never match.
use neo_frizbee::{CaseMatching, Config, Matcher, Matching, Pattern, PatternConfig, SortStrategy, UnicodeMatching};

pub const SEGMENT: usize = 512;
const FUZZY_MIN_CHARS: usize = 3;

pub struct Word {
    pub raw: String,
    /// Lower-cased unless the word is case-sensitive.
    needle: String,
    chars: Vec<char>,
    ascii: bool,
    case_sensitive: bool,
}

fn low(c: char) -> char {
    if c.is_ascii() {
        c.to_ascii_lowercase()
    } else {
        c.to_lowercase().next().unwrap_or(c)
    }
}

impl Word {
    pub fn new(raw: &str) -> Word {
        let case_sensitive = raw.chars().any(char::is_uppercase);
        let needle: String = if case_sensitive { raw.to_string() } else { raw.chars().map(low).collect() };
        Word { raw: raw.to_string(), chars: needle.chars().collect(), ascii: raw.is_ascii(), needle, case_sensitive }
    }

    /// Byte range of the first match in `hay` starting at or after byte `from`.
    pub fn find(&self, hay: &str, from: usize) -> Option<(usize, usize)> {
        if from > hay.len() || self.needle.is_empty() {
            return None;
        }
        let n = self.needle.as_bytes();
        if self.ascii {
            let h = &hay.as_bytes()[from..];
            if self.case_sensitive {
                return memchr::memmem::find(h, n).map(|p| (from + p, from + p + n.len()));
            }
            let (a, b) = (n[0].to_ascii_lowercase(), n[0].to_ascii_uppercase());
            let mut at = 0;
            while let Some(p) = memchr::memchr2(a, b, &h[at..]) {
                let s = at + p;
                if h.len() - s >= n.len() && h[s..s + n.len()].eq_ignore_ascii_case(n) {
                    return Some((from + s, from + s + n.len()));
                }
                at = s + 1;
            }
            return None;
        }
        let mut start = from;
        while !hay.is_char_boundary(start) {
            start += 1;
        }
        for (i, _) in hay[start..].char_indices() {
            let s = start + i;
            let mut it = hay[s..].char_indices();
            let mut ok = true;
            for want in &self.chars {
                match it.next() {
                    Some((_, c)) if (if self.case_sensitive { c } else { low(c) }) == *want => {}
                    _ => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                let end = it.next().map_or(hay.len(), |(j, _)| s + j);
                return Some((s, end));
            }
        }
        None
    }

    /// Best exact match: the first one at a word start (`true`), else the first one.
    pub fn exact(&self, hay: &str) -> Option<(usize, usize, bool)> {
        let first = self.find(hay, 0)?;
        let mut m = first;
        loop {
            if word_start(hay, m.0) {
                return Some((m.0, m.1, true));
            }
            match self.find(hay, m.0 + 1) {
                Some(next) => m = next,
                None => return Some((first.0, first.1, false)),
            }
        }
    }

    pub fn fuzzy_ok(&self) -> bool {
        self.chars.len() >= FUZZY_MIN_CHARS
    }
}

fn word_start(hay: &str, at: usize) -> bool {
    hay[..at].chars().next_back().map_or(true, |c| !c.is_alphanumeric())
}

/// Lines of `text` as byte ranges, long lines cut into pieces of at most `SEGMENT` bytes.
pub fn segments(text: &str) -> impl Iterator<Item = (usize, usize)> + '_ {
    let mut out = Vec::new();
    let mut start = 0;
    for line in text.split('\n') {
        let end = start + line.len();
        let mut s = start;
        while end - s > SEGMENT {
            let mut e = s + SEGMENT;
            while !text.is_char_boundary(e) {
                e -= 1;
            }
            out.push((s, e));
            s = e;
        }
        if end > s {
            out.push((s, end));
        }
        start = end + 1;
    }
    out.into_iter()
}

pub struct Fuzzy {
    m: Matcher,
    min: u16,
    /// Largest distance in bytes from the first to the last matched letter.
    span: usize,
}

impl Fuzzy {
    pub fn new(w: &Word) -> Option<Fuzzy> {
        if !w.fuzzy_ok() {
            return None;
        }
        let n = w.chars.len();
        let typos = if n >= 9 { 2 } else if n >= 5 { 1 } else { 0 };
        let config = Config::default()
            .max_typos(Some(typos))
            .casing(CaseMatching::Smart)
            .unicode(UnicodeMatching::Smart)
            .matching(Matching::Fuzzy)
            .sort(SortStrategy::Unsorted);
        let m = Matcher::new(Pattern::new(&w.raw, PatternConfig::default()), &config);
        // A contiguous match scores 12 per character plus bonuses; letters scattered over a
        // line (`f....o....l....d` scores 49 for `fold`) stay below two thirds of that plus 20.
        let min = (n as u16).saturating_mul(8).saturating_add(20);
        Some(Fuzzy { m, min, span: w.raw.len() + typos as usize + 2 })
    }

    /// Best score over the segments of `text`, with the segment's start.
    pub fn best(&mut self, text: &str) -> Option<(u16, usize)> {
        let mut best: Option<(u16, usize)> = None;
        for (s, e) in segments(text) {
            if let Some(m) = self.m.match_one(&text[s..e], 0) {
                if m.score >= self.min && best.map_or(true, |b| m.score > b.0) && self.close(&text[s..e]) {
                    best = Some((m.score, s));
                }
            }
        }
        best
    }

    /// The matched letters of the best alignment in `seg` lie within `span` bytes.
    fn close(&mut self, seg: &str) -> bool {
        let idx = self.indices(seg);
        match (idx.first(), idx.last()) {
            (Some(a), Some(b)) => b - a < self.span,
            _ => false,
        }
    }

    /// Byte offsets of the matched characters in `seg`, ascending.
    pub fn indices(&mut self, seg: &str) -> Vec<usize> {
        let mut v: Vec<usize> = self.m.match_one_indices(seg, 0).map_or_else(Vec::new, |m| m.indices.iter().map(|i| *i as usize).collect());
        v.sort_unstable();
        v
    }
}
