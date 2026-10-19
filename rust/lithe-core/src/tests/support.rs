use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    OnceLock,
};
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn fixture() -> Value {
    let fixture_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../shared/fixtures/search/basic.json");
    serde_json::from_str(&fs::read_to_string(fixture_path).expect("fixture should be readable"))
        .expect("fixture should be valid JSON")
}

pub(super) fn temporary_root(label: &str) -> PathBuf {
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
        "lithe-core-{label}-{}-{nonce}-{sequence}",
        std::process::id()
    ))
}

#[test]
fn temporary_roots_do_not_alias_with_the_same_label_and_process_timestamp() {
    let roots: std::collections::HashSet<_> =
        (0..10_000).map(|_| temporary_root("same-label")).collect();
    assert_eq!(roots.len(), 10_000, "Each fixture must own a distinct path");
}

/// The answer JDT's `javaEntrypoints` operation gives for these sources.
///
/// Tests state it explicitly because Core must never derive entry points from
/// source text; JDT decides which classes are launchable.
pub(super) fn jdt_entrypoints(entries: &[(&str, &str)]) -> Value {
    json!({
        "schemaVersion": 1,
        "entries": entries
            .iter()
            .map(|(source_path, main_class)| json!({
                "sourcePath": source_path,
                "mainClass": main_class
            }))
            .collect::<Vec<_>>(),
        "diagnostics": []
    })
}
