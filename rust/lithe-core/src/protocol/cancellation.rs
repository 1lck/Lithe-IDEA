//! Cooperative operation cancellation and per-thread deadline tracking.

use crate::protocol::{CoreError, ErrorCode};
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

#[derive(Clone)]
/// Cancellation flag and absolute deadline installed for the current command.
struct State {
    cancelled: Arc<AtomicBool>,
    deadline: Option<Instant>,
}

static OPERATIONS: OnceLock<Mutex<HashMap<String, Arc<AtomicBool>>>> = OnceLock::new();

thread_local! {
    static CURRENT: RefCell<Option<State>> = const { RefCell::new(None) };
}

/// Guard that installs cancellation and timeout state for the current thread.
///
/// Dropping the scope unregisters the operation and restores the previous
/// thread-local state, including when a command exits through an error path.
pub struct Scope {
    operation_id: Option<String>,
}

impl Scope {
    /// Begins a cancellable operation with an optional relative timeout.
    pub fn begin(operation_id: Option<String>, timeout_milliseconds: Option<u64>) -> Self {
        let cancelled = Arc::new(AtomicBool::new(false));
        if let Some(operation_id) = operation_id.as_deref() {
            registry()
                .lock()
                .expect("operation registry should not be poisoned")
                .insert(operation_id.to_string(), Arc::clone(&cancelled));
        }
        CURRENT.with(|current| {
            *current.borrow_mut() = Some(State {
                cancelled,
                deadline: timeout_milliseconds
                    .filter(|milliseconds| *milliseconds > 0)
                    .map(|milliseconds| Instant::now() + Duration::from_millis(milliseconds)),
            });
        });
        Self { operation_id }
    }
}

impl Drop for Scope {
    fn drop(&mut self) {
        CURRENT.with(|current| *current.borrow_mut() = None);
        if let Some(operation_id) = self.operation_id.take() {
            registry()
                .lock()
                .expect("operation registry should not be poisoned")
                .remove(&operation_id);
        }
    }
}

pub fn cancel(operation_id: &str) -> bool {
    registry()
        .lock()
        .expect("operation registry should not be poisoned")
        .get(operation_id)
        .map(|token| {
            token.store(true, Ordering::Release);
            true
        })
        .unwrap_or(false)
}

pub fn check() -> Result<(), CoreError> {
    CURRENT.with(|current| {
        let Some(state) = current.borrow().as_ref().cloned() else {
            return Ok(());
        };
        if state.cancelled.load(Ordering::Acquire) {
            return Err(CoreError::new(
                ErrorCode::Cancelled,
                "Operation was cancelled",
            ));
        }
        if state
            .deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            state.cancelled.store(true, Ordering::Release);
            return Err(CoreError::new(ErrorCode::TimedOut, "Operation timed out"));
        }
        Ok(())
    })
}

fn registry() -> &'static Mutex<HashMap<String, Arc<AtomicBool>>> {
    OPERATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(test)]
mod tests {
    use super::{cancel, check, Scope};
    use crate::protocol::ErrorCode;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn cancellation_is_visible_to_the_active_scope() {
        let _scope = Scope::begin(Some("cancellation-test".to_string()), None);
        assert!(cancel("cancellation-test"));
        assert!(matches!(check().unwrap_err().code, ErrorCode::Cancelled));
    }

    #[test]
    fn deadline_returns_a_stable_timeout_error() {
        let _scope = Scope::begin(Some("timeout-test".to_string()), Some(1));
        thread::sleep(Duration::from_millis(3));
        assert!(matches!(check().unwrap_err().code, ErrorCode::TimedOut));
    }
}
