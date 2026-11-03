//! Detected run configurations, held in memory for each workspace.
//!
//! Generation derives the detected layer from the project tree and, for Java,
//! from the language service's answer. That makes it session state, not a
//! project document: it lives here, keyed by workspace, and is replaced by each
//! generation. Nothing is written into the workspace, so opening a project
//! never fails on a read-only checkout and never leaves files for version
//! control. Only configurations a user saves are project documents.
//!
//! The one thing worth carrying across sessions is the Java entry points JDT
//! reported last time, so the Run list is complete before the language service
//! answers again. Hosts pass an application cache directory for that; the cache
//! is an optimization, and failing to read or write it changes nothing else.

use super::configuration::{RunConfigurationDocument, ToolchainRequirementsDocument};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

/// One generation's output for a workspace.
pub(super) struct GeneratedLayer {
    /// Detected run configurations.
    pub document: RunConfigurationDocument,
    /// Toolchain requirements derived from the same scan.
    pub requirements: ToolchainRequirementsDocument,
}

static LAYERS: OnceLock<Mutex<HashMap<PathBuf, Arc<GeneratedLayer>>>> = OnceLock::new();

const CACHE_SUBDIRECTORY: &str = "run-configurations";

fn layers() -> &'static Mutex<HashMap<PathBuf, Arc<GeneratedLayer>>> {
    LAYERS.get_or_init(Default::default)
}

/// Spellings of one workspace (a trailing separator, a symlinked path) share
/// one layer.
fn key(root: &Path) -> PathBuf {
    fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf())
}

/// The layer the latest generation produced for `root`, if any this session.
pub(super) fn get(root: &Path) -> Option<Arc<GeneratedLayer>> {
    layers()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&key(root))
        .cloned()
}

/// Replaces the layer of `root`.
pub(super) fn store(root: &Path, layer: GeneratedLayer) {
    layers()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(key(root), Arc::new(layer));
}

fn cache_path(cache_directory: &Path, root: &Path) -> PathBuf {
    let digest = Sha256::digest(key(root).to_string_lossy().as_bytes());
    let name = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    cache_directory
        .join(CACHE_SUBDIRECTORY)
        .join(format!("{name}.json"))
}

/// Generated document a previous session cached for `root`, if readable.
pub(super) fn cached_document(cache_directory: &Path, root: &Path) -> Option<Value> {
    let text = fs::read_to_string(cache_path(cache_directory, root)).ok()?;
    let mut entry: Value = serde_json::from_str(&text).ok()?;
    // The file name is a digest; the recorded root rules out a collision.
    if entry.get("root").and_then(Value::as_str) != Some(&*key(root).to_string_lossy()) {
        return None;
    }
    Some(entry.get_mut("generated")?.take())
}

/// Replaces the detected document or the requirements of `root` as if
/// generation had produced them; the part passed as `None` is kept.
#[cfg(test)]
pub(crate) fn seed(root: &Path, document: Option<Value>, requirements: Option<Value>) {
    let current = get(root);
    let document = match document {
        Some(mut document) => {
            super::configuration::migrate_document_value(&mut document);
            serde_json::from_value(document).expect("seeded run configurations")
        }
        None => current.as_ref().map_or_else(
            || {
                serde_json::from_value(json!({ "version": 2, "configurations": [] }))
                    .expect("empty run configurations")
            },
            |layer| layer.document.clone(),
        ),
    };
    let requirements = match requirements {
        Some(requirements) => serde_json::from_value(requirements).expect("seeded requirements"),
        None => current.as_ref().map_or_else(
            || {
                serde_json::from_value(json!({ "version": 1, "toolchains": {} }))
                    .expect("empty requirements")
            },
            |layer| layer.requirements.clone(),
        ),
    };
    store(
        root,
        GeneratedLayer {
            document,
            requirements,
        },
    );
}

/// Forgets `root`, as a new process would.
#[cfg(test)]
pub(crate) fn forget(root: &Path) {
    layers()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&key(root));
}

/// Records `document` for the next session. Failures are ignored: the cache
/// only shortens the time before Java entries appear.
pub(super) fn cache_document(
    cache_directory: &Path,
    root: &Path,
    document: &RunConfigurationDocument,
) {
    let path = cache_path(cache_directory, root);
    let Some(parent) = path.parent() else {
        return;
    };
    let entry = json!({ "root": key(root).to_string_lossy(), "generated": document });
    let Ok(bytes) = serde_json::to_vec(&entry) else {
        return;
    };
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let written = fs::create_dir_all(parent)
        .and_then(|()| fs::write(&temporary, bytes))
        .and_then(|()| fs::rename(&temporary, &path));
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
}
