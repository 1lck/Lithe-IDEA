//! Shared bookkeeping for client-identified resources.

use lithe_remote_protocol::{ErrorCode, RemoteError};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};
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
        crate::lock(&self.entries)
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
        let mut count = crate::lock(&self.count);
        if *count >= MAX_IN_FLIGHT_REQUESTS {
            return false;
        }
        *count += 1;
        true
    }

    pub(crate) fn release(&self) {
        *crate::lock(&self.count) -= 1;
        self.changed.notify_all();
    }

    /// Waits until no request is running or `grace` has passed, and returns
    /// how many are still running.
    pub(crate) fn drain(&self, grace: Duration) -> usize {
        let deadline = Instant::now() + grace;
        let mut count = crate::lock(&self.count);
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
