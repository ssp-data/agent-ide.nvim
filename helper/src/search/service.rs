//! The `search` and `context` requests and the background indexer.
//!
//! The first search of a projects directory starts a background thread that loads the stored
//! index (if any), then re-indexes every new or changed transcript in batches and saves the
//! index. Later searches start such a refresh again at most once per `REFRESH` interval.
//! Searches never wait for it (unless `wait` is set, for tests and benchmarks): they answer from
//! what is indexed so far and say `indexing: true`. A `search_ready` notification follows when
//! the index changed, so the picker can ask again.
use super::context;
use super::index::{self, Doc, Kind};
use super::query::{self, Params, Scope};
use super::store;
use crate::protocol::Out;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::time::{Duration, Instant};

const REFRESH: Duration = Duration::from_secs(1);
const BATCH: usize = 32;
const PROGRESS: Duration = Duration::from_millis(300);
const WAIT_MAX: Duration = Duration::from_secs(300);

#[derive(Default)]
struct State {
    dir: Option<String>,
    docs: HashMap<String, Doc>,
    loaded: bool,
    build_ms: u64,
    from_cache: usize,
}

#[derive(Default)]
struct Work {
    running: bool,
    last: Option<Instant>,
}

struct Inner {
    out: Arc<Out>,
    file: Option<PathBuf>,
    state: RwLock<State>,
    work: Mutex<Work>,
    idle: Condvar,
}

pub struct Service {
    inner: Arc<Inner>,
}

fn counts(st: &State) -> (usize, usize) {
    (st.docs.len(), st.docs.values().map(|d| d.chunks.len()).sum())
}

impl Inner {
    fn read(&self) -> std::sync::RwLockReadGuard<'_, State> {
        self.state.read().unwrap_or_else(|e| e.into_inner())
    }
    fn write(&self) -> std::sync::RwLockWriteGuard<'_, State> {
        self.state.write().unwrap_or_else(|e| e.into_inner())
    }
    fn notify(&self) {
        let (sessions, chunks) = counts(&self.read());
        self.out.send(&json!({"method": "search_ready", "params": {"sessions": sessions, "chunks": chunks}}));
    }

    /// One indexing pass over `dir` (runs on the background thread).
    fn pass(&self, dir: &str) {
        let t0 = Instant::now();
        let mut changed = false;
        if !self.read().loaded {
            let docs = self.file.as_deref().and_then(|f| store::load(f, dir)).unwrap_or_default();
            let mut st = self.write();
            if st.dir.as_deref() != Some(dir) {
                return;
            }
            st.from_cache = docs.len();
            st.docs = docs.into_iter().map(|d| (d.meta.path.clone(), d)).collect();
            st.loaded = true;
            drop(st);
            self.notify();
        }
        let files = crate::scan::list_files(dir);
        let mut shown = Instant::now();
        for batch in files.chunks(BATCH) {
            let fresh = index::changed(batch, &self.read().docs);
            if fresh.is_empty() {
                continue;
            }
            changed = true;
            let mut st = self.write();
            if st.dir.as_deref() != Some(dir) {
                return;
            }
            for d in fresh {
                st.docs.insert(d.meta.path.clone(), d);
            }
            drop(st);
            if shown.elapsed() >= PROGRESS {
                shown = Instant::now();
                self.notify();
            }
        }
        let removed = index::missing(dir, &files, &self.read().docs);
        if !removed.is_empty() {
            changed = true;
            let mut st = self.write();
            for p in removed {
                st.docs.remove(&p);
            }
        }
        if changed {
            if let Some(f) = &self.file {
                store::save(f, dir, self.read().docs.values());
            }
            self.write().build_ms = t0.elapsed().as_millis() as u64;
            self.notify();
        }
    }
}

fn parse_params(p: &Value) -> Result<Params, String> {
    let mut out = Params::default();
    if let Some(q) = p.get("query").and_then(Value::as_str) {
        out.query = q.to_string();
    }
    out.scope = match p.get("scope") {
        None | Some(Value::Null) => Scope::All,
        Some(Value::String(s)) if s == "all" => Scope::All,
        Some(Value::Object(o)) if o.get("session").is_some_and(Value::is_string) => {
            Scope::Session(o["session"].as_str().unwrap_or_default().to_string())
        }
        Some(Value::Object(o)) if o.contains_key("project") => Scope::Sessions(
            o.get("sessions").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(String::from).collect(),
        ),
        Some(other) => return Err(format!("bad `scope`: {other}")),
    };
    if let Some(kinds) = p.get("kinds").and_then(Value::as_array) {
        let ks: Vec<Kind> = kinds.iter().filter_map(Value::as_str).filter_map(Kind::parse).collect();
        if !ks.is_empty() {
            out.kinds = ks;
        }
    }
    if let Some(n) = p.get("limit").and_then(Value::as_u64) {
        out.limit = n as usize;
    }
    if let Some(f) = p.get("fuzzy").and_then(Value::as_bool) {
        out.fuzzy = f;
    }
    if let Some(m) = p.get("projects").and_then(Value::as_object) {
        out.projects = m.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string()))).collect();
    }
    Ok(out)
}

impl Service {
    pub fn new(cache_dir: Option<&Path>, out: Arc<Out>) -> Service {
        let inner = Inner {
            out,
            file: cache_dir.map(|d| d.join(store::FILE_NAME)),
            state: RwLock::new(State::default()),
            work: Mutex::new(Work::default()),
            idle: Condvar::new(),
        };
        Service { inner: Arc::new(inner) }
    }

    /// Starts a background pass over `dir` unless one runs or one started less than `REFRESH` ago.
    fn kick(&self, dir: &str) {
        {
            let mut st = self.inner.write();
            if st.dir.as_deref() != Some(dir) {
                *st = State { dir: Some(dir.to_string()), ..State::default() };
            }
        }
        let mut w = self.inner.work.lock().unwrap_or_else(|e| e.into_inner());
        if w.running || w.last.is_some_and(|t| t.elapsed() < REFRESH) && self.inner.read().loaded {
            return;
        }
        w.running = true;
        w.last = Some(Instant::now());
        let inner = self.inner.clone();
        let dir = dir.to_string();
        std::thread::spawn(move || {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| inner.pass(&dir)));
            let mut w = inner.work.lock().unwrap_or_else(|e| e.into_inner());
            w.running = false;
            inner.idle.notify_all();
        });
    }

    fn wait_idle(&self) {
        let w = self.inner.work.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self.inner.idle.wait_timeout_while(w, WAIT_MAX, |w| w.running);
    }

    fn running(&self) -> bool {
        self.inner.work.lock().unwrap_or_else(|e| e.into_inner()).running
    }

    pub fn search(&self, p: &Value) -> Result<Value, String> {
        let dir = p.get("projects_dir").and_then(Value::as_str).ok_or("missing string param `projects_dir`")?;
        let params = parse_params(p)?;
        self.kick(dir);
        if p.get("wait").and_then(Value::as_bool) == Some(true) {
            self.wait_idle();
        }
        let t0 = Instant::now();
        let st = self.inner.read();
        let hits = query::search(st.docs.values(), &params);
        let took = t0.elapsed().as_secs_f64() * 1000.0;
        let (sessions, chunks) = counts(&st);
        let text: usize = st.docs.values().flat_map(|d| d.chunks.iter()).map(|c| c.text.len()).sum();
        Ok(json!({
            "hits": hits, "indexing": self.running() || !st.loaded, "sessions": sessions, "chunks": chunks,
            "took_ms": took, "build_ms": st.build_ms, "from_cache": st.from_cache, "text_bytes": text,
        }))
    }

    pub fn context(&self, p: &Value) -> Result<Value, String> {
        let path = p.get("path").and_then(Value::as_str).ok_or("missing string param `path`")?;
        let event = p.get("event").and_then(Value::as_u64).filter(|e| *e >= 1).ok_or("missing number param `event`")?;
        let anchors = self.inner.read().docs.get(path).map(|d| d.anchors.clone());
        let (first, events) = context::turn(Path::new(path), anchors.as_deref(), event as u32)?;
        Ok(json!({"first": first, "events": events}))
    }
}
