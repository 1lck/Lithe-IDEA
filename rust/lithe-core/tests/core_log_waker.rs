//! Verifies the C ABI wake signal for the process-global Core diagnostic queue.
//!
//! The queue and waker are process globals, so this file is its own test binary
//! and keeps every assertion in one test: no other test can record or drain.

use lithe_core::diagnostics::core_events::{drain, record};
use serde_json::json;
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};

extern "C" {
    fn lithe_core_install_log_waker(
        callback: Option<unsafe extern "C" fn(*mut c_void)>,
        context: *mut c_void,
    );
    fn lithe_core_remove_log_waker(context: *mut c_void) -> i32;
}

static FIRST: AtomicUsize = AtomicUsize::new(0);
static SECOND: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" fn count_wake(context: *mut c_void) {
    (*(context as *const AtomicUsize)).fetch_add(1, Ordering::SeqCst);
}

fn context(counter: &'static AtomicUsize) -> *mut c_void {
    counter as *const AtomicUsize as *mut c_void
}

fn record_skipped(path: &str) {
    record(
        "app.workspace.directory_skipped",
        BTreeMap::from([
            ("path".into(), json!(path)),
            ("error".into(), json!("Directory traversal failed")),
            ("error_code".into(), json!("permission_denied")),
            ("error_domain".into(), json!("core")),
        ]),
        None,
    )
    .expect("catalog fact is valid");
}

#[test]
fn log_waker_signals_once_per_drain_cycle_and_stops_after_removal() {
    let first = context(&FIRST);
    let second = context(&SECOND);
    unsafe { lithe_core_install_log_waker(Some(count_wake), first) };
    assert_eq!(
        FIRST.load(Ordering::SeqCst),
        0,
        "an empty queue needs no wake"
    );

    record_skipped("src/a");
    record_skipped("src/b");
    assert_eq!(
        FIRST.load(Ordering::SeqCst),
        1,
        "a burst coalesces into one wake"
    );

    assert_eq!(drain().events.len(), 2);
    record_skipped("src/c");
    assert_eq!(
        FIRST.load(Ordering::SeqCst),
        2,
        "a drain re-arms the signal"
    );

    assert_eq!(unsafe { lithe_core_remove_log_waker(second) }, 0);
    assert_eq!(drain().events.len(), 1);
    record_skipped("src/d");
    assert_eq!(
        FIRST.load(Ordering::SeqCst),
        3,
        "a non-owner cannot remove the waker"
    );

    assert_eq!(unsafe { lithe_core_remove_log_waker(first) }, 1);
    assert_eq!(drain().events.len(), 1);
    record_skipped("src/e");
    assert_eq!(FIRST.load(Ordering::SeqCst), 3, "no wake after removal");

    unsafe { lithe_core_install_log_waker(Some(count_wake), second) };
    assert_eq!(
        SECOND.load(Ordering::SeqCst),
        1,
        "facts recorded before install wake the new writer immediately"
    );
    assert_eq!(unsafe { lithe_core_remove_log_waker(second) }, 1);
    assert_eq!(drain().events.len(), 1);
}
