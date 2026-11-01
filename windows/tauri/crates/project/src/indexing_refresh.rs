//! Bounded, root-owned invalidation epochs shared by every native window.

use std::sync::{
    Condvar, Mutex,
    atomic::{AtomicU64, Ordering},
};

#[derive(Default)]
pub struct IndexingRefresh {
    requested: AtomicU64,
    applied: AtomicU64,
    notified: AtomicU64,
    last_status: Mutex<Option<String>>,
    running: Mutex<bool>,
    available: Condvar,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrent_holders_share_each_epoch_and_publish_once() {
        use std::{
            sync::{Arc, atomic::AtomicUsize, mpsc},
            time::Duration,
        };
        let state = Arc::new(IndexingRefresh::default());
        let calls = Arc::new(AtomicUsize::new(0));
        state.invalidate();
        let (started, start) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let (finished, done) = mpsc::channel();
        let first = Arc::clone(&state);
        let count = Arc::clone(&calls);
        let worker = std::thread::spawn(move || {
            let result = first.ensure_fresh(|| {
                if count.fetch_add(1, Ordering::SeqCst) == 0 {
                    started.send(()).unwrap();
                    gate.recv_timeout(Duration::from_secs(5)).map_err(|_| ())?;
                }
                Ok::<_, ()>(String::new())
            });
            let _ = finished.send(result);
        });
        start.recv_timeout(Duration::from_secs(5)).unwrap();
        state.invalidate();
        release.send(()).unwrap();
        // The main caller waits for the same root; neither holder repeats an acknowledged epoch.
        state
            .ensure_fresh(|| {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok::<_, ()>(String::new())
            })
            .unwrap();
        done.recv_timeout(Duration::from_secs(5)).unwrap().unwrap();
        worker.join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(state.take_completed());
        assert!(!state.take_completed());
    }

    #[test]
    fn batches_share_work_and_events_during_refresh_get_another_pass() {
        let state = IndexingRefresh::default();
        state.invalidate();
        state.invalidate();
        let mut calls = 0;
        state
            .ensure_fresh(|| {
                calls += 1;
                if calls == 1 {
                    state.invalidate();
                }
                Ok::<_, ()>(String::new())
            })
            .unwrap();
        state
            .ensure_fresh(|| {
                calls += 1;
                Ok::<_, ()>(String::new())
            })
            .unwrap();
        assert_eq!(calls, 2);
        assert!(state.is_clean());
    }

    #[test]
    fn failed_and_continuously_superseded_refreshes_remain_dirty() {
        let state = IndexingRefresh::default();
        state.invalidate();
        assert!(matches!(
            state.ensure_fresh(|| Err::<String, _>("failure")),
            Err(RefreshError::Failed("failure"))
        ));
        assert!(!state.is_clean());
        let mut calls = 0;
        assert!(matches!(
            state.ensure_fresh(|| {
                calls += 1;
                state.invalidate();
                Ok::<_, ()>(String::new())
            }),
            Err(RefreshError::Superseded)
        ));
        assert_eq!(calls, 3);
        assert!(!state.is_clean());
        assert_eq!(
            state.refresh_now(|| Ok::<_, ()>("status".into())).unwrap(),
            "status"
        );
        assert!(state.is_clean());
    }
}

#[derive(Debug)]
pub enum RefreshError<E> {
    Failed(E),
    Superseded,
    TimedOut,
}

struct RefreshGuard<'a>(&'a IndexingRefresh);
impl Drop for RefreshGuard<'_> {
    fn drop(&mut self) {
        *self
            .0
            .running
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = false;
        self.0.available.notify_all();
    }
}

impl IndexingRefresh {
    fn acquire<E>(&self) -> Result<RefreshGuard<'_>, RefreshError<E>> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let mut running = self
            .running
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        while *running {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(RefreshError::TimedOut);
            }
            let (next, timeout) = self
                .available
                .wait_timeout(running, remaining)
                .unwrap_or_else(|error| error.into_inner());
            running = next;
            if timeout.timed_out() && *running {
                return Err(RefreshError::TimedOut);
            }
        }
        *running = true;
        Ok(RefreshGuard(self))
    }

    pub fn discard_status(&self) {
        *self.last_status.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    pub fn invalidate(&self) {
        self.requested.fetch_add(1, Ordering::AcqRel);
    }

    pub fn epoch(&self) -> u64 {
        self.requested.load(Ordering::Acquire)
    }

    pub fn is_clean(&self) -> bool {
        self.epoch() == self.applied.load(Ordering::Acquire)
    }

    /// Every clean epoch is broadcast once, including work consumed by a waiting query.
    pub fn take_completed(&self) -> bool {
        let epoch = self.applied.load(Ordering::Acquire);
        if epoch != self.epoch() {
            return false;
        }
        self.notified.fetch_max(epoch, Ordering::AcqRel) < epoch
    }

    /// Explicit activation/refresh requests return the real Core status to their own owner.
    pub fn refresh_now<E>(
        &self,
        refresh: impl FnOnce() -> Result<String, E>,
    ) -> Result<String, RefreshError<E>> {
        self.invalidate();
        let _running = self.acquire()?;
        let epoch = self.epoch();
        if self.is_clean() {
            if let Some(status) = self
                .last_status
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
            {
                return Ok(status);
            }
        }
        let result = refresh().map_err(RefreshError::Failed)?;
        *self.last_status.lock().unwrap_or_else(|e| e.into_inner()) = Some(result.clone());
        self.applied.store(epoch, Ordering::Release);
        if self.is_clean() {
            Ok(result)
        } else {
            Err(RefreshError::Superseded)
        }
    }

    /// One shared worker consumes each observed epoch; a newer event is never acknowledged early.
    pub fn ensure_fresh<E>(
        &self,
        mut refresh: impl FnMut() -> Result<String, E>,
    ) -> Result<bool, RefreshError<E>> {
        let _running = self.acquire()?;
        let mut refreshed = false;
        for _ in 0..3 {
            let epoch = self.epoch();
            if epoch == self.applied.load(Ordering::Acquire) {
                return Ok(refreshed);
            }
            let status = refresh().map_err(RefreshError::Failed)?;
            *self.last_status.lock().unwrap_or_else(|e| e.into_inner()) = Some(status);
            refreshed = true;
            self.applied.store(epoch, Ordering::Release);
        }
        if self.is_clean() {
            Ok(refreshed)
        } else {
            Err(RefreshError::Superseded)
        }
    }
}
