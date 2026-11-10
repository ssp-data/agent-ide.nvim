//! On-disk search index: `<cache-dir>/search-v1.json`, next to the metadata cache. It holds the
//! crate version, the parse rules version (`events::RULES_VERSION`), the format (`FORMAT`), the
//! projects directory and every `Doc`. A file written with another crate version, rules or
//! format, or for another projects directory, is ignored (and replaced on the next save). The
//! file is private: 0600 in a 0700 directory (see `private`).
use super::index::Doc;
use crate::cache::VERSION;
use crate::events::RULES_VERSION;
use serde::{Deserialize, Serialize};
use std::path::Path;

pub const FILE_NAME: &str = "search-v1.json";
/// Bumped whenever the stored shape, or what is indexed, changes.
pub const FORMAT: u32 = 2;

#[derive(Deserialize)]
struct Stored {
    version: String,
    rules: u64,
    format: u32,
    dir: String,
    docs: Vec<Doc>,
}

#[derive(Serialize)]
struct StoredRef<'a> {
    version: &'a str,
    rules: u64,
    format: u32,
    dir: &'a str,
    docs: Vec<&'a Doc>,
}

pub fn load(file: &Path, dir: &str) -> Option<Vec<Doc>> {
    crate::private::tidy(file);
    let bytes = std::fs::read(file).ok()?;
    let st: Stored = serde_json::from_slice(&bytes).ok()?;
    let ok = st.version == VERSION && st.rules == RULES_VERSION && st.format == FORMAT && st.dir == dir;
    ok.then_some(st.docs)
}

/// Writes the index (best effort; a private temporary file renamed into place, never a partial file).
pub fn save<'a>(file: &Path, dir: &str, docs: impl Iterator<Item = &'a Doc>) -> bool {
    let mut docs: Vec<&Doc> = docs.collect();
    docs.sort_by(|a, b| a.meta.path.cmp(&b.meta.path));
    let stored = StoredRef { version: VERSION, rules: RULES_VERSION, format: FORMAT, dir, docs };
    let Ok(bytes) = serde_json::to_vec(&stored) else { return false };
    crate::private::write(file, &bytes)
}
