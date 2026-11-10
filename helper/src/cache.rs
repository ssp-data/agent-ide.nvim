//! On-disk metadata cache: `<cache-dir>/index-v3.json`, holding the crate version, the parse
//! rules version (`events::RULES_VERSION`), the file format (`FORMAT`) and a map
//! path -> { mtime, size, meta }. A file written with another value of any of the three is
//! ignored and rewritten, so a change to the metadata rules never serves stale titles. The file
//! is private: 0600 in a 0700 directory (see `private`).
use crate::events::RULES_VERSION;
use crate::scan::SessionMeta;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = "index-v3.json";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Bumped whenever the stored shape changes.
pub const FORMAT: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    mtime: u64,
    size: u64,
    meta: SessionMeta,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    version: String,
    rules: u64,
    format: u32,
    entries: BTreeMap<String, Entry>,
}

#[derive(Serialize)]
struct StoredRef<'a> {
    version: &'a str,
    rules: u64,
    format: u32,
    entries: &'a BTreeMap<String, Entry>,
}

#[derive(Debug, Default)]
pub struct Cache {
    file: Option<PathBuf>,
    entries: BTreeMap<String, Entry>,
    dirty: bool,
}

impl Cache {
    /// Loads the cache; a missing, corrupt, unreadable or other-version file gives an empty
    /// cache (rewritten on the next save). `None` means no cache at all.
    pub fn load(dir: Option<&Path>) -> Cache {
        let Some(dir) = dir else { return Cache::default() };
        let file = dir.join(FILE_NAME);
        crate::private::tidy(&file);
        let (entries, dirty) = match std::fs::read(&file) {
            Ok(bytes) => match serde_json::from_slice::<Stored>(&bytes) {
                Ok(st) if st.version == VERSION && st.rules == RULES_VERSION && st.format == FORMAT => (st.entries, false),
                _ => (BTreeMap::new(), true),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (BTreeMap::new(), false),
            Err(_) => (BTreeMap::new(), true),
        };
        Cache { file: Some(file), entries, dirty }
    }

    /// The cached meta, only when both mtime and size still match.
    pub fn get(&self, path: &str, mtime: u64, size: u64) -> Option<&SessionMeta> {
        self.entries.get(path).filter(|e| e.mtime == mtime && e.size == size).map(|e| &e.meta)
    }

    pub fn insert(&mut self, meta: SessionMeta) {
        let entry = Entry { mtime: meta.mtime, size: meta.size, meta };
        let key = entry.meta.path.clone();
        if self.entries.get(&key).map(|e| (e.mtime, e.size, &e.meta)) != Some((entry.mtime, entry.size, &entry.meta)) {
            self.entries.insert(key, entry);
            self.dirty = true;
        }
    }

    /// Drops entries below `dir` whose file is no longer listed in `seen`.
    pub fn forget_missing_under(&mut self, dir: &str, seen: &HashSet<&str>) {
        let prefix = format!("{}/", dir.trim_end_matches('/'));
        let before = self.entries.len();
        self.entries.retain(|p, _| !p.starts_with(&prefix) || seen.contains(p.as_str()));
        if self.entries.len() != before {
            self.dirty = true;
        }
    }

    /// Writes the cache if it changed (best effort; never panics).
    pub fn save(&mut self) {
        let Some(file) = &self.file else { return };
        if !self.dirty {
            return;
        }
        let stored = StoredRef { version: VERSION, rules: RULES_VERSION, format: FORMAT, entries: &self.entries };
        let Ok(bytes) = serde_json::to_vec(&stored) else { return };
        if crate::private::write(file, &bytes) {
            self.dirty = false;
            if let Some(dir) = file.parent() {
                remove_old_versions(dir);
            }
        }
    }
}

/// True for `index-v<digits>.json` of another format version than `FILE_NAME`.
pub fn is_old_version(name: &str) -> bool {
    name != FILE_NAME
        && name
            .strip_prefix("index-v")
            .and_then(|r| r.strip_suffix(".json"))
            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// Removes cache files of earlier format versions (`index-v<n>.json`) from `dir`, the helper's
/// own cache folder; nothing else there and nothing below it is touched. Best effort.
fn remove_old_versions(dir: &Path) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for entry in rd.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if is_old_version(name) && entry.file_type().is_ok_and(|t| t.is_file()) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests;
