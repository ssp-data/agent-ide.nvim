//! On-disk metadata cache: `<cache-dir>/index-v2.json`, holding the crate version and a map
//! path -> { mtime, size, meta }. A file written by another version is ignored and rewritten,
//! so a change to the metadata rules never serves stale titles.
use crate::scan::SessionMeta;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = "index-v2.json";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    mtime: u64,
    size: u64,
    meta: SessionMeta,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    version: String,
    entries: BTreeMap<String, Entry>,
}

#[derive(Serialize)]
struct StoredRef<'a> {
    version: &'a str,
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
        let (entries, dirty) = match std::fs::read(&file) {
            Ok(bytes) => match serde_json::from_slice::<Stored>(&bytes) {
                Ok(st) if st.version == VERSION => (st.entries, false),
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
        let Ok(bytes) = serde_json::to_vec(&StoredRef { version: VERSION, entries: &self.entries }) else { return };
        if let Some(parent) = file.parent() {
            if std::fs::create_dir_all(parent).is_err() {
                return;
            }
        }
        let tmp = file.with_extension(format!("json.tmp{}", std::process::id()));
        if std::fs::write(&tmp, bytes).is_ok() && std::fs::rename(&tmp, file).is_ok() {
            self.dirty = false;
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

#[cfg(test)]
mod tests;
