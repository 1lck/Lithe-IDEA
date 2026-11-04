//! Window-bound ownership and cancellation of native tool preparation.
//! No processes or paths live here; active leases remain owned until cleanup.
use std::{
    collections::BTreeMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

const CANCELLED: &str = "toolchain.native.cancelled";
const LIMIT: usize = 64;
static NEXT: AtomicU64 = AtomicU64::new(1);

struct Entry {
    owner: String,
    created: Instant,
    claimed: bool,
    cancelled: Arc<AtomicBool>,
}

/// Pure-memory registration must precede the blocking native invocation. This
/// makes cancellation before worker dispatch observable instead of a lost race.
#[derive(Default, Clone)]
pub struct Operations(Arc<Mutex<BTreeMap<String, Entry>>>);

impl Operations {
    pub fn begin(&self, owner: &str) -> Result<String, String> {
        self.begin_at(owner, Instant::now())
    }

    fn begin_at(&self, owner: &str, now: Instant) -> Result<String, String> {
        let mut entries = self.0.lock().map_err(|_| CANCELLED)?;
        entries.retain(|_, entry| {
            entry.claimed || now.saturating_duration_since(entry.created) < Duration::from_secs(30)
        });
        if entries.len() >= LIMIT {
            return Err("toolchain.native.limitExceeded".into());
        }
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        if sequence == 0 {
            return Err("toolchain.native.limitExceeded".into());
        }
        let id = format!("tool-{}-{sequence}", std::process::id());
        entries.insert(
            id.clone(),
            Entry {
                owner: owner.into(),
                created: now,
                claimed: false,
                cancelled: Arc::new(AtomicBool::new(false)),
            },
        );
        Ok(id)
    }

    pub fn claim(&self, owner: &str, id: &str) -> Result<Lease, String> {
        let mut entries = self.0.lock().map_err(|_| CANCELLED)?;
        let entry = entries
            .get_mut(id)
            .filter(|entry| {
                entry.owner == owner
                    && !entry.claimed
                    && entry.created.elapsed() < Duration::from_secs(30)
            })
            .ok_or(CANCELLED)?;
        entry.claimed = true;
        Ok(Lease {
            operations: self.clone(),
            id: id.into(),
            cancelled: entry.cancelled.clone(),
        })
    }

    /// Only the owning window can revoke a token. Unclaimed registrations can
    /// be removed immediately; an active lease remains until its worker exits.
    pub fn cancel(&self, owner: &str, id: &str) {
        if let Ok(mut entries) = self.0.lock() {
            let remove = entries
                .get(id)
                .filter(|entry| entry.owner == owner)
                .map(|entry| {
                    entry.cancelled.store(true, Ordering::Release);
                    !entry.claimed
                })
                .unwrap_or(false);
            if remove {
                entries.remove(id);
            }
        }
    }

    pub fn close_window(&self, owner: &str) {
        if let Ok(mut entries) = self.0.lock() {
            entries.retain(|_, entry| {
                if entry.owner != owner {
                    return true;
                }
                entry.cancelled.store(true, Ordering::Release);
                entry.claimed
            });
        }
    }
}

/// Drop only after the worker has closed its sessions and mutable state.
pub struct Lease {
    operations: Operations,
    id: String,
    cancelled: Arc<AtomicBool>,
}
impl Lease {
    pub fn current(&self) -> Result<(), String> {
        if self.cancelled.load(Ordering::Acquire) {
            Err(CANCELLED.into())
        } else {
            Ok(())
        }
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if let Ok(mut entries) = self.operations.0.lock() {
            entries.remove(&self.id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_before_dispatch_cannot_be_lost_or_cross_window() {
        let operations = Operations::default();
        let id = operations.begin("left").unwrap();
        operations.cancel("right", &id);
        assert!(operations.claim("right", &id).is_err());
        operations.cancel("left", &id);
        assert!(operations.claim("left", &id).is_err());
    }

    #[test]
    fn window_close_revokes_all_its_leases_but_preserves_the_other_window() {
        let operations = Operations::default();
        let a = operations.begin("left").unwrap();
        let b = operations.begin("right").unwrap();
        let first = operations.claim("left", &a).unwrap();
        let second = operations.claim("right", &b).unwrap();
        assert!(operations.claim("left", &a).is_err());
        operations.close_window("left");
        assert_eq!(first.current(), Err(CANCELLED.into()));
        assert!(second.current().is_ok());
        drop(first);
        operations.cancel("left", &b);
        assert!(second.current().is_ok());
        drop(second);
        assert!(operations.0.lock().unwrap().is_empty());
    }

    #[test]
    fn pending_registrations_expire_but_active_owners_are_never_evicted() {
        let operations = Operations::default();
        let before = Instant::now();
        let active = operations.begin_at("left", before).unwrap();
        let lease = operations.claim("left", &active).unwrap();
        for _ in 1..LIMIT {
            operations.begin_at("left", before).unwrap();
        }
        assert!(operations.begin_at("left", before).is_err());
        let later = before + Duration::from_secs(31);
        let replacement = operations.begin_at("left", later).unwrap();
        assert!(lease.current().is_ok());
        assert_eq!(operations.0.lock().unwrap().len(), 2);
        operations.cancel("left", &replacement);
        drop(lease);
        assert!(operations.0.lock().unwrap().is_empty());
    }
}
