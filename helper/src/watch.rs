//! Change notifications for `*.jsonl` files below a projects directory.
use crate::protocol::Out;
use notify::{EventKind, RecursiveMode, Watcher as _};
use serde_json::json;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

const BATCH: Duration = Duration::from_millis(200);

/// Keeps the OS watcher alive; dropping it stops the watch and ends the batching thread.
pub struct Watch {
    _watcher: notify::RecommendedWatcher,
}

pub fn start(dir: &Path, out: Arc<Out>) -> Result<Watch, String> {
    let (tx, rx) = mpsc::channel::<PathBuf>();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, EventKind::Access(_)) {
            return;
        }
        for p in ev.paths {
            if p.extension().map_or(false, |e| e == "jsonl") {
                let _ = tx.send(p);
            }
        }
    })
    .map_err(|e| e.to_string())?;
    watcher.watch(dir, RecursiveMode::Recursive).map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        // Block for the first change, then collect for BATCH, then emit one notification.
        while let Ok(first) = rx.recv() {
            let mut paths = BTreeSet::from([first]);
            let deadline = Instant::now() + BATCH;
            while let Some(left) = deadline.checked_duration_since(Instant::now()) {
                match rx.recv_timeout(left) {
                    Ok(p) => {
                        paths.insert(p);
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => break,
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            let list: Vec<String> = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            out.send(&json!({"method": "changed", "params": {"paths": list}}));
        }
    });
    Ok(Watch { _watcher: watcher })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::Mutex;

    struct Capture(Arc<Mutex<Vec<u8>>>);
    impl Write for Capture {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn changes_are_batched_into_one_notification() {
        let dir = std::env::temp_dir().join(format!("agent-ide-helper-watch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("-p")).unwrap();
        let buf = Arc::new(Mutex::new(Vec::new()));
        let out = Out::new(Box::new(Capture(buf.clone())));
        let _w = start(&dir, out).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        std::fs::write(dir.join("-p/a.jsonl"), "x").unwrap();
        std::fs::write(dir.join("-p/b.jsonl"), "x").unwrap();
        std::fs::write(dir.join("-p/ignored.txt"), "x").unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while buf.lock().unwrap().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        std::thread::sleep(Duration::from_millis(400));
        let text = String::from_utf8(buf.lock().unwrap().clone()).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 1, "got {text:?}");
        let v: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(v["method"], "changed");
        let paths: Vec<&str> = v["params"]["paths"].as_array().unwrap().iter().map(|p| p.as_str().unwrap()).collect();
        assert_eq!(paths.len(), 2);
        assert!(paths.iter().all(|p| p.ends_with(".jsonl")));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
