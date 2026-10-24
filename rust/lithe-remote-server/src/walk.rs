//! Streaming recursive listings for file indexes and "go to file".
//!
//! One `walk.start` replaces thousands of `fs.readDir` round trips, which over
//! a high-latency link is the difference between seconds and minutes for a
//! large repository. Entries arrive in depth-first, name-sorted batches.

use crate::connection::Context;
use crate::fs::{host_path, kind_of};
use crate::parse;
use crate::resources::Registry;
use crate::session::Session;
use lithe_remote_protocol::methods::{
    self, FileKind, WalkDoneEvent, WalkEntriesEvent, WalkEntry, WalkParams, WalkStartParams,
};
use lithe_remote_protocol::{ErrorCode, RemoteError};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

/// Entries per `walk.entries` event: large enough to amortize framing,
/// small enough to keep each frame far below the size limit.
const BATCH_ENTRIES: usize = 2000;

pub(crate) struct WalkTable {
    registry: Registry<RunningWalk>,
}

struct RunningWalk {
    connection: u64,
    cancelled: Arc<AtomicBool>,
}

impl WalkTable {
    pub(crate) fn new() -> Self {
        Self {
            registry: Registry::new("walk"),
        }
    }

    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        match method {
            methods::WALK_START => self.start(context, parse(params)?).map(|()| Value::Null),
            methods::WALK_CANCEL => {
                let params: WalkParams = parse(params)?;
                let walks = self.registry.lock();
                let walk = walks
                    .get(&params.walk_id)
                    .ok_or_else(|| self.registry.unknown(params.walk_id))?;
                walk.cancelled.store(true, Ordering::Release);
                Ok(Value::Null)
            }
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                format!("unknown method {method}"),
            )),
        }
    }

    pub(crate) fn cancel_owned_by(&self, connection: u64) {
        for walk in self.registry.lock().values() {
            if walk.connection == connection {
                walk.cancelled.store(true, Ordering::Release);
            }
        }
    }

    pub(crate) fn cancel_all(&self) {
        for walk in self.registry.lock().values() {
            walk.cancelled.store(true, Ordering::Release);
        }
    }

    fn start(&self, context: &Context, params: WalkStartParams) -> Result<(), RemoteError> {
        let session = &context.session;
        session.ids.observe(params.walk_id);
        let root = host_path(&params.root)?;
        if !std::fs::metadata(&root)
            .map_err(|error| crate::fs::io_error(error, &params.root))?
            .is_dir()
        {
            return Err(RemoteError::new(
                ErrorCode::NotADirectory,
                "only directories can be walked",
            ));
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        self.registry.insert(
            params.walk_id,
            RunningWalk {
                connection: context.connection,
                cancelled: Arc::clone(&cancelled),
            },
        )?;
        let session = Arc::clone(session);
        let walker = Walker {
            walk_id: params.walk_id,
            root,
            excludes: params.exclude_names.into_iter().collect(),
            limit: params.max_entries.unwrap_or(u64::MAX),
            cancelled,
        };
        thread::Builder::new()
            .name("remote-walk".into())
            .spawn(move || {
                let done = walker.run(&session);
                session.walks.registry.remove(done.walk_id);
                session.link.emit(methods::EVENT_WALK_DONE, done);
            })
            .map_err(|error| crate::fs::io_error(error, ""))?;
        Ok(())
    }
}

struct Walker {
    walk_id: u64,
    root: PathBuf,
    excludes: BTreeSet<String>,
    limit: u64,
    cancelled: Arc<AtomicBool>,
}

impl Walker {
    fn run(&self, session: &Session) -> WalkDoneEvent {
        let mut done = WalkDoneEvent {
            walk_id: self.walk_id,
            total: 0,
            truncated: false,
            cancelled: false,
            skipped_non_utf8: 0,
            unreadable_directories: 0,
        };
        let mut batch = Vec::with_capacity(BATCH_ENTRIES);
        // Each stack frame is a directory's remaining, reverse-sorted
        // children, so popping yields name order depth-first.
        let mut stack: Vec<Vec<(String, PathBuf, FileKind)>> = Vec::new();
        match self.children(&self.root, "", &mut done) {
            Some(children) => stack.push(children),
            None => done.unreadable_directories += 1,
        }
        while let Some(frame) = stack.last_mut() {
            if self.cancelled.load(Ordering::Acquire) {
                done.cancelled = true;
                break;
            }
            let Some((relative, path, kind)) = frame.pop() else {
                stack.pop();
                continue;
            };
            if done.total >= self.limit {
                done.truncated = true;
                break;
            }
            done.total += 1;
            let descend = kind == FileKind::Directory
                && !path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| self.excludes.contains(name));
            batch.push(WalkEntry {
                path: relative.clone(),
                kind,
            });
            if batch.len() >= BATCH_ENTRIES {
                self.flush(session, &mut batch);
            }
            if descend {
                match self.children(&path, &relative, &mut done) {
                    Some(children) => stack.push(children),
                    None => done.unreadable_directories += 1,
                }
            }
        }
        self.flush(session, &mut batch);
        done
    }

    fn children(
        &self,
        directory: &Path,
        relative: &str,
        done: &mut WalkDoneEvent,
    ) -> Option<Vec<(String, PathBuf, FileKind)>> {
        let entries = std::fs::read_dir(directory).ok()?;
        let mut children = Vec::new();
        for entry in entries.flatten() {
            let Ok(name) = entry.file_name().into_string() else {
                done.skipped_non_utf8 += 1;
                continue;
            };
            // `DirEntry::file_type` does not follow links, so a link to a
            // directory is reported as a link and never descended into.
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            let path_relative = if relative.is_empty() {
                name.clone()
            } else {
                format!("{relative}/{name}")
            };
            children.push((path_relative, entry.path(), kind_of(&file_type)));
        }
        children.sort_by(|left, right| right.0.cmp(&left.0));
        Some(children)
    }

    fn flush(&self, session: &Session, batch: &mut Vec<WalkEntry>) {
        if batch.is_empty() {
            return;
        }
        session.link.emit(
            methods::EVENT_WALK_ENTRIES,
            WalkEntriesEvent {
                walk_id: self.walk_id,
                entries: std::mem::take(batch),
            },
        );
    }
}
