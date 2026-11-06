//! Helpers the command tests share: sending a request and owning scratch paths.

use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    OnceLock,
};
use std::time::{SystemTime, UNIX_EPOCH};

/// Sends `request` through the same entry point the Windows host uses.
pub(super) fn execute_json(request: &str) -> String {
    crate::try_execute(request).expect("the request should name a legacy Java command")
}

pub(crate) fn temporary_root(label: &str) -> PathBuf {
    static NONCE: OnceLock<u128> = OnceLock::new();
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    // A clock tick is not a unique ID: parallel fixtures must never share cleanup ownership.
    let nonce = NONCE.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be valid")
            .as_nanos()
    });
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "lithe-legacy-tooling-{label}-{}-{nonce}-{sequence}",
        std::process::id()
    ))
}

#[test]
fn temporary_roots_do_not_alias_with_the_same_label_and_process_timestamp() {
    let roots: std::collections::HashSet<_> =
        (0..10_000).map(|_| temporary_root("same-label")).collect();
    assert_eq!(roots.len(), 10_000, "Each fixture must own a distinct path");
}
