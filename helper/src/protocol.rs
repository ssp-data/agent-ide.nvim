//! Line protocol: one JSON object per line on stdin and stdout.
use crate::cache::Cache;
use crate::{events, scan, search, watch};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex};

/// The single place that writes to the output stream: whole lines, one lock, flushed each time,
/// so notifications from the watcher thread never interleave with responses.
pub struct Out {
    w: Mutex<Box<dyn Write + Send>>,
}

impl Out {
    pub fn new(w: Box<dyn Write + Send>) -> Arc<Out> {
        Arc::new(Out { w: Mutex::new(w) })
    }
    pub fn stdout() -> Arc<Out> {
        Out::new(Box::new(std::io::stdout()))
    }
    pub fn sink() -> Arc<Out> {
        Out::new(Box::new(std::io::sink()))
    }
    pub fn send(&self, msg: &Value) {
        let mut line = serde_json::to_vec(msg).unwrap_or_else(|_| b"{}".to_vec());
        line.push(b'\n');
        let mut w = self.w.lock().unwrap_or_else(|e| e.into_inner());
        let _ = w.write_all(&line).and_then(|_| w.flush());
    }
}

pub struct Server {
    cache: Cache,
    out: Arc<Out>,
    watch: Option<watch::Watch>,
    search: search::service::Service,
}

fn error(id: Value, message: impl Into<String>) -> Value {
    json!({"id": id, "error": {"message": message.into()}})
}

fn str_param<'a>(params: &'a Value, key: &str) -> Result<&'a str, String> {
    params.get(key).and_then(Value::as_str).ok_or_else(|| format!("missing string param `{key}`"))
}

impl Server {
    pub fn new(cache_dir: Option<PathBuf>, out: Arc<Out>) -> Server {
        let search = search::service::Service::new(cache_dir.as_deref(), out.clone());
        Server { cache: Cache::load(cache_dir.as_deref()), out, watch: None, search }
    }

    /// Handles one request line. `None` for blank lines; otherwise exactly one response.
    /// Never panics and never terminates the process.
    pub fn handle_line(&mut self, line: &str) -> Option<Value> {
        if line.trim().is_empty() {
            return None;
        }
        let req: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => return Some(error(Value::Null, format!("invalid JSON: {e}"))),
        };
        let Some(obj) = req.as_object() else {
            return Some(error(Value::Null, "request must be a JSON object"));
        };
        let id = obj.get("id").cloned().unwrap_or(Value::Null);
        let Some(method) = obj.get("method").and_then(Value::as_str) else {
            return Some(error(id, "missing `method`"));
        };
        let params = obj.get("params").cloned().unwrap_or(Value::Null);
        let method = method.to_string();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.dispatch(&method, &params)))
            .unwrap_or_else(|_| Err(format!("internal error in `{method}`")));
        Some(match result {
            Ok(r) => json!({"id": id, "result": r}),
            Err(m) => error(id, m),
        })
    }

    fn dispatch(&mut self, method: &str, params: &Value) -> Result<Value, String> {
        match method {
            "hello" => Ok(json!({"rules_version": events::RULES_VERSION, "crate_version": env!("CARGO_PKG_VERSION")})),
            "scan" => {
                let dir = str_param(params, "projects_dir")?;
                let sessions = scan::scan(Path::new(dir), Some(&mut self.cache), &AtomicUsize::new(0));
                Ok(json!({"sessions": sessions}))
            }
            "history" => {
                let path = str_param(params, "path")?;
                let data = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
                Ok(json!({"events": events::parse_bytes(&data)}))
            }
            "watch" => {
                let dir = str_param(params, "projects_dir")?;
                self.watch = None;
                self.watch = Some(watch::start(Path::new(dir), self.out.clone())?);
                Ok(json!({}))
            }
            "search" => self.search.search(params),
            "context" => self.search.context(params),
            other => Err(format!("unknown method `{other}`")),
        }
    }

    /// Reads requests until `input` closes.
    pub fn run(&mut self, mut input: impl std::io::BufRead) {
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match input.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => return,
                Ok(_) => {
                    let line = String::from_utf8_lossy(&buf);
                    if let Some(resp) = self.handle_line(&line) {
                        self.out.send(&resp);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
