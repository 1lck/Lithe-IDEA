//! Shared bookkeeping for client-identified resources.

use crate::protocol::{ErrorCode, RemoteError};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Highest resource id any client used in this session, so a reconnecting or
/// restarted client can continue numbering without collisions.
#[derive(Default)]
pub(crate) struct IdWatermark(AtomicU64);

impl IdWatermark {
    pub(crate) fn observe(&self, id: u64) {
        self.0.fetch_max(id, Ordering::AcqRel);
    }

    pub(crate) fn next(&self) -> u64 {
        self.0.load(Ordering::Acquire) + 1
    }
}

/// Starts are registered by the connection reader, before worker scheduling.
/// A later close must wait for publication (or failure), not race an empty table.
#[derive(Default)]
pub(crate) struct PendingStarts {
    entries: Mutex<BTreeMap<(&'static str, String), Arc<StartCompletion>>>,
}

#[derive(Default)]
pub(crate) struct StartCompletion {
    finished: Mutex<bool>,
    changed: Condvar,
    close_params: Mutex<Option<Value>>,
    cleanup_failure: Mutex<Option<RemoteError>>,
}

impl StartCompletion {
    pub(crate) fn wait(&self, timeout: Duration) -> Result<(), RemoteError> {
        let deadline = Instant::now() + timeout;
        let mut finished = crate::server::lock(&self.finished);
        while !*finished {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(RemoteError::new(
                    ErrorCode::Busy,
                    "resource is still starting",
                ));
            }
            finished = self
                .changed
                .wait_timeout(finished, remaining)
                .unwrap_or_else(|error| error.into_inner())
                .0;
        }
        match crate::server::lock(&self.cleanup_failure).clone() {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
}

impl PendingStarts {
    pub(crate) fn reserve(
        self: &Arc<Self>,
        family: &'static str,
        id: impl ToString,
    ) -> Result<StartGuard, RemoteError> {
        let mut entries = crate::server::lock(&self.entries);
        let key = (family, id.to_string());
        if entries.contains_key(&key) {
            return Err(RemoteError::new(
                ErrorCode::ResourceIdInUse,
                "resource is already starting",
            ));
        }
        let completion = Arc::new(StartCompletion::default());
        entries.insert(key.clone(), Arc::clone(&completion));
        Ok(StartGuard {
            starts: Arc::clone(self),
            key,
            completion,
        })
    }

    pub(crate) fn cancel(
        &self,
        family: &'static str,
        id: impl ToString,
        params: &Value,
    ) -> Option<Arc<StartCompletion>> {
        let entries = crate::server::lock(&self.entries);
        let completion = entries.get(&(family, id.to_string()))?;
        let mut close = crate::server::lock(&completion.close_params);
        // Multiple cancellation attempts may strengthen, but never downgrade,
        // an explicit force kill while the child is still being created.
        if close
            .as_ref()
            .is_none_or(|value| value.get("force") != Some(&Value::Bool(true)))
        {
            *close = Some(params.clone());
        }
        Some(Arc::clone(completion))
    }
}

/// Dropping the worker's reservation releases waiters even after spawn failure,
/// worker scheduling failure, or panic. No lifecycle lock covers host I/O.
pub(crate) struct StartGuard {
    starts: Arc<PendingStarts>,
    key: (&'static str, String),
    completion: Arc<StartCompletion>,
}

impl StartGuard {
    /// Preserve creator-owned cleanup errors for close requests waiting on it.
    pub(crate) fn cleanup_failed(&self, error: RemoteError) {
        *crate::server::lock(&self.completion.cleanup_failure) = Some(error);
    }

    /// After publication, atomically transfers close ownership either to the
    /// creating worker or to a subsequent ordinary close request.
    pub(crate) fn take_cancellation(&self) -> Option<Value> {
        crate::server::lock(&self.starts.entries).remove(&self.key);
        crate::server::lock(&self.completion.close_params).take()
    }
}

impl Drop for StartGuard {
    fn drop(&mut self) {
        let mut entries = crate::server::lock(&self.starts.entries);
        *crate::server::lock(&self.completion.finished) = true;
        if entries
            .get(&self.key)
            .is_some_and(|entry| Arc::ptr_eq(entry, &self.completion))
        {
            entries.remove(&self.key);
        }
        self.completion.changed.notify_all();
    }
}

/// Live resources of one family, keyed by the client's id. The condition
/// variable lets shutdown wait, with a deadline, until resources have ended.
pub(crate) struct Registry<T> {
    family: &'static str,
    entries: Mutex<BTreeMap<u64, T>>,
    changed: Condvar,
}

impl<T> Registry<T> {
    pub(crate) fn new(family: &'static str) -> Self {
        Self {
            family,
            entries: Mutex::new(BTreeMap::new()),
            changed: Condvar::new(),
        }
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, BTreeMap<u64, T>> {
        crate::server::lock(&self.entries)
    }

    /// Fails when the id is already live. The check and the later insert are
    /// separated by the resource's start-up, so callers insert a placeholder
    /// through [`Registry::reserve`] when start-up can be slow.
    pub(crate) fn ensure_free(&self, id: u64) -> Result<(), RemoteError> {
        if self.lock().contains_key(&id) {
            return Err(self.in_use(id));
        }
        Ok(())
    }

    pub(crate) fn insert(&self, id: u64, entry: T) -> Result<(), RemoteError> {
        let mut entries = self.lock();
        if entries.contains_key(&id) {
            return Err(self.in_use(id));
        }
        entries.insert(id, entry);
        Ok(())
    }

    pub(crate) fn remove(&self, id: u64) -> Option<T> {
        let removed = self.lock().remove(&id);
        self.changed.notify_all();
        removed
    }

    /// Keeps only the entries for which `keep` returns true.
    pub(crate) fn retain(&self, keep: impl Fn(&T) -> bool) {
        let mut entries = self.lock();
        let before = entries.len();
        entries.retain(|_, entry| keep(entry));
        let changed = entries.len() != before;
        drop(entries);
        if changed {
            self.changed.notify_all();
        }
    }

    pub(crate) fn unknown(&self, id: u64) -> RemoteError {
        RemoteError::new(
            ErrorCode::UnknownResource,
            format!("{} {id} is not active", self.family),
        )
    }

    fn in_use(&self, id: u64) -> RemoteError {
        RemoteError::new(
            ErrorCode::ResourceIdInUse,
            format!("{} {id} already exists", self.family),
        )
    }

    /// Waits until an entry is removed or `timeout` elapses.
    pub(crate) fn wait_for_change(&self, timeout: Duration) {
        let entries = self.lock();
        let _ = self.changed.wait_timeout(entries, timeout);
    }
}

/// Upper bound of requests executing on worker threads. Further requests
/// fail with `BUSY` rather than spawning unbounded threads.
const MAX_IN_FLIGHT_REQUESTS: usize = 64;

/// Requests currently executing on worker threads.
#[derive(Default)]
pub(crate) struct InFlight {
    count: Mutex<usize>,
    changed: Condvar,
}

impl InFlight {
    /// Reserves a slot, or returns `false` when the limit is reached.
    pub(crate) fn try_acquire(&self) -> bool {
        let mut count = crate::server::lock(&self.count);
        if *count >= MAX_IN_FLIGHT_REQUESTS {
            return false;
        }
        *count += 1;
        true
    }

    pub(crate) fn release(&self) {
        *crate::server::lock(&self.count) -= 1;
        self.changed.notify_all();
    }

    /// Waits until no request is running or `grace` has passed, and returns
    /// how many are still running.
    pub(crate) fn drain(&self, grace: Duration) -> usize {
        let deadline = Instant::now() + grace;
        let mut count = crate::server::lock(&self.count);
        while *count > 0 {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            count = self
                .changed
                .wait_timeout(count, remaining)
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        }
        *count
    }
}
