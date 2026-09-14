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

// Each live scope owns a token. A nested request with the same ID temporarily
// becomes the cancellation target without unregistering its still-live caller.
type Registrations = HashMap<String, Vec<Arc<AtomicBool>>>;
static OPERATIONS: OnceLock<Mutex<Registrations>> = OnceLock::new();

thread_local! {
    static CURRENT: RefCell<Option<State>> = const { RefCell::new(None) };
}

/// Guard that installs cancellation and timeout state for the current thread.
///
/// Dropping the scope unregisters the operation and restores the previous
/// thread-local state, including when a command exits through an error path.
pub struct Scope {
    operation_id: Option<String>,
    /// A synchronous callback may execute another Core request on this thread.
    previous_state: Option<State>,
    /// Remove only this registration, including when same-ID requests overlap.
    cancelled: Arc<AtomicBool>,
}

impl Scope {
    /// Begins a cancellable operation with an optional relative timeout.
    pub fn begin(operation_id: Option<String>, timeout_milliseconds: Option<u64>) -> Self {
        let cancelled = Arc::new(AtomicBool::new(false));
        if let Some(operation_id) = operation_id.as_deref() {
            registry()
                .lock()
                .expect("operation registry should not be poisoned")
                .entry(operation_id.to_string())
                .or_default()
                .push(Arc::clone(&cancelled));
        }
        let previous_state = CURRENT.with(|current| {
            current.replace(Some(State {
                cancelled: Arc::clone(&cancelled),
                deadline: timeout_milliseconds
                    .filter(|milliseconds| *milliseconds > 0)
                    .map(|milliseconds| Instant::now() + Duration::from_millis(milliseconds)),
            }))
        });
        Self {
            operation_id,
            previous_state,
            cancelled,
        }
    }
}

impl Drop for Scope {
    fn drop(&mut self) {
        CURRENT.with(|current| current.replace(self.previous_state.take()));
        if let Some(operation_id) = self.operation_id.take() {
            let mut registry = registry()
                .lock()
                .expect("operation registry should not be poisoned");
            if let Some(tokens) = registry.get_mut(&operation_id) {
                tokens.retain(|token| !Arc::ptr_eq(token, &self.cancelled));
                if tokens.is_empty() {
                    registry.remove(&operation_id);
                }
            }
        }
    }
}

pub fn cancel(operation_id: &str) -> bool {
    registry()
        .lock()
        .expect("operation registry should not be poisoned")
        .get(operation_id)
        .and_then(|tokens| tokens.last())
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

/// Runs bounded outcome inspection after a mutation's cancellation or deadline.
///
/// Cleanup must determine whether a ref already moved without inheriting the
/// cancelled request token. The original thread state is restored on every exit.
pub(crate) fn with_cleanup_deadline<T>(timeout: Duration, operation: impl FnOnce() -> T) -> T {
    struct RestoreState(Option<State>);
    impl Drop for RestoreState {
        fn drop(&mut self) {
            CURRENT.with(|current| *current.borrow_mut() = self.0.take());
        }
    }
    let previous = CURRENT.with(|current| {
        current.replace(Some(State {
            cancelled: Arc::new(AtomicBool::new(false)),
            deadline: Some(Instant::now() + timeout),
        }))
    });
    let _restore = RestoreState(previous);
    operation()
}

fn registry() -> &'static Mutex<Registrations> {
    OPERATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(test)]
mod tests {
    use super::{cancel, check, Scope};
    use crate::protocol::ErrorCode;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn nested_scopes_restore_the_outer_cancellation_registration() {
        let outer = Scope::begin(Some("nested-cancellation".into()), None);
        {
            let _inner = Scope::begin(Some("nested-cancellation".into()), None);
            assert!(cancel("nested-cancellation"));
            assert!(matches!(check().unwrap_err().code, ErrorCode::Cancelled));
        }
        assert!(
            check().is_ok(),
            "The inner cancellation must not replace the outer token"
        );
        assert!(cancel("nested-cancellation"));
        assert!(matches!(check().unwrap_err().code, ErrorCode::Cancelled));
        drop(outer);
        assert!(!cancel("nested-cancellation"));
    }

    #[test]
    fn nested_scopes_restore_the_outer_deadline() {
        let _outer = Scope::begin(None, None);
        // Install an already reached monotonic deadline, avoiding sleeps or a
        // machine-speed dependency while testing restoration across a callback.
        super::CURRENT.with(|state| {
            state.borrow_mut().as_mut().unwrap().deadline = Some(std::time::Instant::now())
        });
        {
            let _inner = Scope::begin(None, None);
            assert!(check().is_ok());
        }
        assert!(matches!(check().unwrap_err().code, ErrorCode::TimedOut));
    }

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
