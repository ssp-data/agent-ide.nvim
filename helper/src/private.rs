//! Files derived from transcripts (the metadata cache, the search index) are as private as the
//! transcripts: the cache directory is 0700, the files 0600, written through a temporary file
//! created 0600 and renamed into place. Temporary files left by a helper that was killed while
//! saving are removed on the next start.
use std::fs::{DirBuilder, OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub const DIR_MODE: u32 = 0o700;
pub const FILE_MODE: u32 = 0o600;
/// Without `/proc`, a temporary file this old is taken as left behind.
const STALE_AGE: Duration = Duration::from_secs(600);

/// Creates `dir` (and parents) 0700; an existing one is tightened to 0700 when we may (only
/// its owner can change its mode).
pub fn ensure_dir(dir: &Path) -> bool {
    if DirBuilder::new().recursive(true).mode(DIR_MODE).create(dir).is_err() {
        return false;
    }
    let _ = std::fs::set_permissions(dir, Permissions::from_mode(DIR_MODE));
    true
}

fn temp_of(file: &Path) -> PathBuf {
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    file.with_file_name(format!("{name}.tmp{}", std::process::id()))
}

/// Writes `bytes` to `file` (mode 0600) atomically. `false` when anything failed; no temporary
/// file is left behind then.
pub fn write(file: &Path, bytes: &[u8]) -> bool {
    if let Some(parent) = file.parent() {
        if !ensure_dir(parent) {
            return false;
        }
    }
    let tmp = temp_of(file);
    let _ = std::fs::remove_file(&tmp); // our own pid: a leftover of an earlier failure
    let ok = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(FILE_MODE)
        .open(&tmp)
        .and_then(|mut f| f.write_all(bytes).and_then(|_| f.flush()))
        .and_then(|_| std::fs::rename(&tmp, file))
        .is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
    }
    ok
}

fn alive(pid: u32) -> Option<bool> {
    if pid == std::process::id() {
        return Some(true);
    }
    Path::new("/proc/self").exists().then(|| Path::new(&format!("/proc/{pid}")).exists())
}

/// Tightens `file` to 0600 when it exists and removes `<file>.tmp<pid>` files whose process is
/// gone (or, without `/proc`, that are older than ten minutes).
pub fn tidy(file: &Path) {
    let _ = std::fs::set_permissions(file, Permissions::from_mode(FILE_MODE));
    let (Some(dir), Some(name)) = (file.parent(), file.file_name()) else { return };
    let prefix = format!("{}.tmp", name.to_string_lossy());
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let Some(pid) = n.strip_prefix(&prefix).and_then(|p| p.parse::<u32>().ok()) else { continue };
        let gone = match alive(pid) {
            Some(a) => !a,
            None => e.metadata().and_then(|m| m.modified()).ok().and_then(|t| SystemTime::now().duration_since(t).ok()).is_some_and(|age| age > STALE_AGE),
        };
        if gone {
            let _ = std::fs::remove_file(e.path());
        }
    }
}
