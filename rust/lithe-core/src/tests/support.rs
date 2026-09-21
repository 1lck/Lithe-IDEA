use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn fixture() -> Value {
    let fixture_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../shared/fixtures/search/basic.json");
    serde_json::from_str(&fs::read_to_string(fixture_path).expect("fixture should be readable"))
        .expect("fixture should be valid JSON")
}

pub(super) fn temporary_root(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be valid")
        .as_nanos();
    std::env::temp_dir().join(format!("lithe-core-{label}-{}-{nonce}", std::process::id()))
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
