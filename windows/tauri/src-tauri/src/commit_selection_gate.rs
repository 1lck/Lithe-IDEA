//! Owns commit-selection cancellation from UI admission through Core startup.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

const MAX_RESERVATIONS: usize = 256;

struct Entry {
    owner: String,
    cancelled: Arc<AtomicBool>,
    started: bool,
}

#[derive(Default)]
pub(crate) struct GateRegistry(Mutex<HashMap<String, Entry>>);

impl GateRegistry {
    pub(crate) fn reserve(&self, owner: &str, id: &str) -> bool {
        if owner.is_empty() || id.is_empty() || id.len() > 128 {
            return false;
        }
        let mut entries = self.0.lock().unwrap_or_else(|error| error.into_inner());
        if entries.len() >= MAX_RESERVATIONS || entries.contains_key(id) {
            return false;
        }
        entries.insert(
            id.to_string(),
            Entry {
                owner: owner.to_string(),
                cancelled: Arc::new(AtomicBool::new(false)),
                started: false,
            },
        );
        true
    }

    pub(crate) fn start(&self, owner: &str, id: &str) -> Option<Arc<AtomicBool>> {
        let mut entries = self.0.lock().unwrap_or_else(|error| error.into_inner());
        let entry = entries.get_mut(id)?;
        if entry.owner != owner || entry.started {
            return None;
        }
        entry.started = true;
        Some(Arc::clone(&entry.cancelled))
    }

    pub(crate) fn cancel(&self, id: &str) -> bool {
        let entries = self.0.lock().unwrap_or_else(|error| error.into_inner());
        entries.get(id).is_some_and(|entry| {
            entry.cancelled.store(true, Ordering::Release);
            true
        })
    }

    pub(crate) fn release(&self, owner: &str, id: &str) {
        let mut entries = self.0.lock().unwrap_or_else(|error| error.into_inner());
        if entries
            .get(id)
            .is_some_and(|entry| entry.owner == owner && !entry.started)
        {
            entries.remove(id);
        }
    }

    pub(crate) fn finish(&self, id: &str) {
        self.0
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(id);
    }

    /// Cancel running work; unstarted reservations cannot be launched after closure.
    pub(crate) fn close_owner(&self, owner: &str) -> Vec<String> {
        let mut entries = self.0.lock().unwrap_or_else(|error| error.into_inner());
        let mut running = Vec::new();
        entries.retain(|id, entry| {
            if entry.owner != owner {
                return true;
            }
            entry.cancelled.store(true, Ordering::Release);
            if entry.started {
                running.push(id.clone());
            }
            entry.started
        });
        running
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_before_core_start_is_retained_until_finish() {
        let registry = GateRegistry::default();
        assert!(registry.reserve("window", "operation"));
        assert!(registry.cancel("operation"));
        let latch = registry.start("window", "operation").unwrap();
        assert!(latch.load(Ordering::Acquire));
        assert!(registry.start("window", "operation").is_none());
        registry.finish("operation");
        assert!(!registry.cancel("operation"));
    }
    #[test]
    fn closing_a_window_rejects_unstarted_and_cancels_started_operations() {
        let registry = GateRegistry::default();
        assert!(registry.reserve("one", "pending"));
        assert!(registry.reserve("one", "running"));
        assert!(registry.reserve("two", "other"));
        let running = registry.start("one", "running").unwrap();
        assert_eq!(registry.close_owner("one"), vec!["running"]);
        assert!(running.load(Ordering::Acquire));
        assert!(registry.start("one", "pending").is_none());
        assert!(registry.start("two", "other").is_some());
        registry.finish("running");
        registry.finish("other");
    }
    #[test]
    fn only_the_owner_can_release_an_unstarted_reservation() {
        let registry = GateRegistry::default();
        assert!(registry.reserve("one", "operation"));
        registry.release("other", "operation");
        assert!(registry.start("one", "operation").is_some());
        registry.release("one", "operation");
        assert!(registry.cancel("operation"));
        registry.finish("operation");
        assert!(!registry.cancel("operation"));
    }
}
