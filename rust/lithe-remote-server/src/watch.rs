//! Recursive file watching.
//!
//! The platform backend (inotify or FSEvents) reports raw changes to a
//! coalescer, which merges bursts, such as a build writing thousands of files
//! or an editor's save sequence, into sorted batches. A batch is sent after
//! [`QUIET_PERIOD`] without new changes, or at the latest [`MAX_BATCH_DELAY`]
//! after its first change. When changes are lost, the batch carries
//! `overflow` and the client rescans instead of trusting partial data.

use crate::connection::Context;
use crate::fs::host_path;
use crate::platform::watcher;
use crate::resources::Registry;
use crate::session::Session;
use crate::{parse, to_value};
use lithe_remote_protocol::methods::{
    self, ChangeKind, FileChange, WatchChangedEvent, WatchErrorCode, WatchErrorEvent, WatchParams,
    WatchStartParams, WatchStartResult, WatchState,
};
use lithe_remote_protocol::{ErrorCode, RemoteError};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const QUIET_PERIOD: Duration = Duration::from_millis(50);
const MAX_BATCH_DELAY: Duration = Duration::from_millis(250);

/// Changes per batch before the batch degrades to `overflow`. Beyond this
/// a rescan is cheaper for the client than applying individual changes.
const MAX_BATCH_CHANGES: usize = 5000;

/// A change as reported by a backend, before coalescing.
pub(crate) enum RawEvent {
    Change(PathBuf, ChangeKind),
    /// The backend dropped events.
    Overflow,
    /// Only per-directory backends (inotify) have a limit.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    LimitReached(String),
    RootRemoved,
}

/// Directory names below the root that are neither watched nor reported.
pub(crate) struct Excludes {
    root: PathBuf,
    names: BTreeSet<String>,
}

impl Excludes {
    pub(crate) fn new(root: PathBuf, names: Vec<String>) -> Self {
        Self {
            root,
            names: names.into_iter().collect(),
        }
    }

    pub(crate) fn contains(&self, path: &Path) -> bool {
        let Ok(relative) = path.strip_prefix(&self.root) else {
            return false;
        };
        relative.components().any(|component| {
            component
                .as_os_str()
                .to_str()
                .is_some_and(|name| self.names.contains(name))
        })
    }

    #[cfg_attr(target_os = "macos", allow(dead_code))]
    pub(crate) fn is_excluded_name(&self, name: &std::ffi::OsStr) -> bool {
        name.to_str().is_some_and(|name| self.names.contains(name))
    }
}

/// Receives raw events from a backend thread.
pub(crate) type Sink = Sender<RawEvent>;

pub(crate) struct WatchTable {
    registry: Registry<RunningWatch>,
}

struct RunningWatch {
    root: String,
    /// Dropping the backend handle stops the backend, which closes the
    /// coalescer's channel and ends its thread.
    _backend: watcher::Watcher,
}

impl WatchTable {
    pub(crate) fn new() -> Self {
        Self {
            registry: Registry::new("watch"),
        }
    }

    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        match method {
            methods::WATCH_START => to_value(self.start(&context.session, parse(params)?)?),
            methods::WATCH_STOP => {
                let params: WatchParams = parse(params)?;
                self.registry
                    .remove(params.watch_id)
                    .map(|_| Value::Null)
                    .ok_or_else(|| self.registry.unknown(params.watch_id))
            }
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                format!("unknown method {method}"),
            )),
        }
    }

    pub(crate) fn states(&self) -> Vec<WatchState> {
        self.registry
            .lock()
            .iter()
            .map(|(watch_id, watch)| WatchState {
                watch_id: *watch_id,
                root: watch.root.clone(),
            })
            .collect()
    }

    pub(crate) fn stop_all(&self) {
        let watches = std::mem::take(&mut *self.registry.lock());
        drop(watches);
    }

    fn start(
        &self,
        session: &Arc<Session>,
        params: WatchStartParams,
    ) -> Result<WatchStartResult, RemoteError> {
        session.ids.observe(params.watch_id);
        self.registry.ensure_free(params.watch_id)?;
        let root = host_path(&params.root)?;
        if !std::fs::metadata(&root)
            .map_err(|error| crate::fs::io_error(error, &params.root))?
            .is_dir()
        {
            return Err(RemoteError::new(
                ErrorCode::NotADirectory,
                "only directories can be watched",
            ));
        }
        let excludes = Arc::new(Excludes::new(root.clone(), params.exclude_names));
        let (sink, raw) = mpsc::channel();
        let (backend, watched_directories) = watcher::start(root, excludes, sink)
            .map_err(|error| crate::fs::io_error(error, &params.root))?;
        self.registry.insert(
            params.watch_id,
            RunningWatch {
                root: params.root,
                _backend: backend,
            },
        )?;
        let session = Arc::clone(session);
        let watch_id = params.watch_id;
        thread::Builder::new()
            .name("remote-watch".into())
            .spawn(move || coalesce(raw, |batch| deliver(&session, watch_id, batch)))
            .map_err(|error| crate::fs::io_error(error, ""))?;
        Ok(WatchStartResult {
            watched_directories,
        })
    }
}

/// What the coalescer hands to delivery.
pub(crate) enum Delivery {
    Changes {
        changes: Vec<FileChange>,
        overflow: bool,
    },
    Error(WatchErrorCode, String),
}

fn deliver(session: &Session, watch_id: u64, delivery: Delivery) {
    match delivery {
        Delivery::Changes { changes, overflow } => session.link.emit(
            methods::EVENT_WATCH_CHANGED,
            WatchChangedEvent {
                watch_id,
                changes,
                overflow,
            },
        ),
        Delivery::Error(code, message) => {
            if code == WatchErrorCode::RootRemoved {
                session.watches.registry.remove(watch_id);
            }
            session.link.emit(
                methods::EVENT_WATCH_ERROR,
                WatchErrorEvent {
                    watch_id,
                    code,
                    message,
                },
            );
        }
    }
}

#[derive(Default)]
struct Batch {
    changes: BTreeMap<PathBuf, ChangeKind>,
    overflow: bool,
}

impl Batch {
    fn add(&mut self, path: PathBuf, kind: ChangeKind) {
        if self.overflow {
            return;
        }
        let merged = match (self.changes.get(&path), kind) {
            // A file created and then written in one burst is still new.
            (Some(ChangeKind::Created), ChangeKind::Modified) => ChangeKind::Created,
            // Deleted and recreated, as atomic saves do: the client keeps
            // its entry and reloads the content.
            (Some(ChangeKind::Deleted), ChangeKind::Created) => ChangeKind::Modified,
            (_, kind) => kind,
        };
        self.changes.insert(path, merged);
        if self.changes.len() > MAX_BATCH_CHANGES {
            self.changes.clear();
            self.overflow = true;
        }
    }

    fn take(&mut self) -> Option<Delivery> {
        let batch = std::mem::take(self);
        if batch.changes.is_empty() && !batch.overflow {
            return None;
        }
        let mut overflow = batch.overflow;
        let mut changes = Vec::with_capacity(batch.changes.len());
        for (path, kind) in batch.changes {
            match path.into_os_string().into_string() {
                Ok(path) => changes.push(FileChange { path, kind }),
                // Not addressable in this protocol version; a rescan shows it.
                Err(_) => overflow = true,
            }
        }
        Some(Delivery::Changes { changes, overflow })
    }
}

/// Merges raw events into batches until the backend closes the channel.
pub(crate) fn coalesce(raw: Receiver<RawEvent>, mut deliver: impl FnMut(Delivery)) {
    let mut batch = Batch::default();
    loop {
        // Wait for the first event of a batch without a deadline.
        let Ok(first) = raw.recv() else {
            return;
        };
        let started = Instant::now();
        let mut next = Some(first);
        loop {
            match next.take() {
                Some(RawEvent::Change(path, kind)) => batch.add(path, kind),
                Some(RawEvent::Overflow) => {
                    batch.changes.clear();
                    batch.overflow = true;
                }
                Some(RawEvent::LimitReached(message)) => {
                    if let Some(changes) = batch.take() {
                        deliver(changes);
                    }
                    deliver(Delivery::Error(WatchErrorCode::LimitReached, message));
                }
                Some(RawEvent::RootRemoved) => {
                    if let Some(changes) = batch.take() {
                        deliver(changes);
                    }
                    deliver(Delivery::Error(
                        WatchErrorCode::RootRemoved,
                        "the watched directory was removed".into(),
                    ));
                    return;
                }
                None => {}
            }
            let waited = started.elapsed();
            if waited >= MAX_BATCH_DELAY {
                break;
            }
            match raw.recv_timeout(QUIET_PERIOD.min(MAX_BATCH_DELAY - waited)) {
                Ok(event) => next = Some(event),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    if let Some(changes) = batch.take() {
                        deliver(changes);
                    }
                    return;
                }
            }
        }
        if let Some(changes) = batch.take() {
            deliver(changes);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn changes_of(deliveries: &[Delivery]) -> Vec<(String, ChangeKind)> {
        deliveries
            .iter()
            .flat_map(|delivery| match delivery {
                Delivery::Changes { changes, .. } => changes
                    .iter()
                    .map(|change| (change.path.clone(), change.kind))
                    .collect(),
                Delivery::Error(..) => Vec::new(),
            })
            .collect()
    }

    // An editor's atomic save deletes and recreates the file, and a new file
    // is usually written right after creation. Clients must see one
    // `modified` and one `created`, not the raw sequence.
    #[test]
    fn bursts_merge_into_one_sorted_batch() {
        let (sender, receiver) = mpsc::channel();
        for (path, kind) in [
            ("/w/b.txt", ChangeKind::Deleted),
            ("/w/a.txt", ChangeKind::Created),
            ("/w/b.txt", ChangeKind::Created),
            ("/w/a.txt", ChangeKind::Modified),
        ] {
            sender.send(RawEvent::Change(path.into(), kind)).unwrap();
        }
        drop(sender);
        let mut deliveries = Vec::new();
        coalesce(receiver, |delivery| deliveries.push(delivery));
        assert_eq!(
            changes_of(&deliveries),
            vec![
                ("/w/a.txt".into(), ChangeKind::Created),
                ("/w/b.txt".into(), ChangeKind::Modified),
            ]
        );
    }

    #[test]
    fn lost_events_turn_the_batch_into_an_overflow() {
        let (sender, receiver) = mpsc::channel();
        sender
            .send(RawEvent::Change("/w/a".into(), ChangeKind::Created))
            .unwrap();
        sender.send(RawEvent::Overflow).unwrap();
        sender
            .send(RawEvent::Change("/w/b".into(), ChangeKind::Created))
            .unwrap();
        drop(sender);
        let mut deliveries = Vec::new();
        coalesce(receiver, |delivery| deliveries.push(delivery));
        assert!(matches!(
            deliveries.as_slice(),
            [Delivery::Changes { changes, overflow: true }] if changes.is_empty()
        ));
    }

    #[test]
    fn excluded_names_match_any_component_below_the_root() {
        let excludes = Excludes::new("/w".into(), vec!["node_modules".into(), "target".into()]);
        assert!(excludes.contains(Path::new("/w/node_modules/x/index.js")));
        assert!(excludes.contains(Path::new("/w/app/target/classes")));
        assert!(!excludes.contains(Path::new("/w/src/target.rs")));
        // The root's own ancestors never count, even if one is named target.
        let nested = Excludes::new("/srv/target/w".into(), vec!["target".into()]);
        assert!(!nested.contains(Path::new("/srv/target/w/src/main.rs")));
    }
}
