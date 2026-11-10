//! On-disk search index: `<cache-dir>/search-v1.json`, next to the metadata cache. It holds the
//! crate version, the projects directory and every `Doc`. A file written by another crate
//! version or for another projects directory is ignored (and replaced on the next save).
use super::index::Doc;
use crate::cache::VERSION;
use serde::{Deserialize, Serialize};
use std::path::Path;

pub const FILE_NAME: &str = "search-v1.json";

#[derive(Deserialize)]
struct Stored {
    version: String,
    dir: String,
    docs: Vec<Doc>,
}

#[derive(Serialize)]
struct StoredRef<'a> {
    version: &'a str,
    dir: &'a str,
    docs: Vec<&'a Doc>,
}

pub fn load(file: &Path, dir: &str) -> Option<Vec<Doc>> {
    let bytes = std::fs::read(file).ok()?;
    let st: Stored = serde_json::from_slice(&bytes).ok()?;
    (st.version == VERSION && st.dir == dir).then_some(st.docs)
}

/// Writes the index (best effort; a temporary file renamed into place, never a partial file).
pub fn save<'a>(file: &Path, dir: &str, docs: impl Iterator<Item = &'a Doc>) -> bool {
    let mut docs: Vec<&Doc> = docs.collect();
    docs.sort_by(|a, b| a.meta.path.cmp(&b.meta.path));
    let Ok(bytes) = serde_json::to_vec(&StoredRef { version: VERSION, dir, docs }) else { return false };
    if let Some(parent) = file.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return false;
        }
    }
    let tmp = file.with_extension(format!("json.tmp{}", std::process::id()));
    if std::fs::write(&tmp, bytes).is_ok() && std::fs::rename(&tmp, file).is_ok() {
        return true;
    }
    let _ = std::fs::remove_file(&tmp);
    false
}
