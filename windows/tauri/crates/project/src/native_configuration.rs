//! Private native configuration transactions. Only the owning provider/Core
//! knows fields; the existing document adapter owns guarded atomic publication.
//! Raw XML and credentials never become a serializable frontend value.

use crate::document_file::{self, SaveOutcome};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
};

const MAX_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeConfigurationError {
    Conflict,
    ReadOnly,
    Unreadable,
    Invalid,
}

/// Deliberately not Serialize or Debug: the bytes may contain native secrets.
pub struct PreparedNativeConfiguration {
    source: PathBuf,
    target: PathBuf,
    expected: Option<String>,
    replacement: String,
}

/// Prepares only changed, Core-approved fields against exact source bytes.
pub fn prepare(
    manifest: &Value,
    system: &str,
    snapshot: &Value,
    edits: &Value,
    immutable_roots: &[PathBuf],
) -> Result<Option<PreparedNativeConfiguration>, NativeConfigurationError> {
    use NativeConfigurationError::*;
    let sources = snapshot["sources"].as_array().ok_or(Invalid)?;
    let selected = sources
        .iter()
        .find(|source| source["id"] == edits["sourceID"])
        .ok_or(Invalid)?;
    if selected["writable"] != true || selected["scope"] == "installation" {
        return Err(ReadOnly);
    }
    let source = source_path(selected)?;
    let target = validated_target(&source, immutable_roots)?;
    // Distinct provider URIs may resolve to the same file through links or case
    // aliases. Such a source must never use an editable alias to an installation.
    for other in sources {
        if other["id"] != selected["id"]
            && same_path(&resolve_target(&source_path(other)?)?, &target)
        {
            return Err(ReadOnly);
        }
    }
    let expected = read(&target)?;
    let revision = expected
        .as_ref()
        .map(|text| format!("sha256:{:x}", Sha256::digest(text.as_bytes())))
        .unwrap_or_else(|| "missing".into());
    if selected["revision"] != revision || edits["revision"] != revision {
        return Err(Conflict);
    }
    let request = json!({"command":"build.editConfigurationDocument", "payload": {
        "manifest":manifest,"buildSystemID":system,"request":{"snapshot":snapshot,"edits":edits,"document":expected}
    }});
    let result: Value = serde_json::from_str(&lithe_core::execute_json(&request.to_string()))
        .map_err(|_| Invalid)?;
    if result["ok"] != true || result["data"]["status"] != "ok" {
        return Err(Invalid);
    }
    let edited = &result["data"]["edit"];
    if edited["changed"] == false {
        return Ok(None);
    }
    let mut replacement = edited["document"]
        .as_str()
        .filter(|text| text.len() as u64 <= MAX_BYTES)
        .ok_or(Invalid)?
        .to_owned();
    // Core edits XML text. Preserve the native UTF-8 byte-order marker as an
    // encoding choice even when the XML writer omits it from edited text.
    if expected
        .as_ref()
        .is_some_and(|text| text.starts_with('\u{feff}'))
        && !replacement.starts_with('\u{feff}')
    {
        replacement.insert(0, '\u{feff}');
    }
    if replacement.len() as u64 > MAX_BYTES {
        return Err(Invalid);
    }
    Ok(Some(PreparedNativeConfiguration {
        source,
        target,
        expected,
        replacement,
    }))
}

impl PreparedNativeConfiguration {
    /// Recheck link targets and protected roots immediately before the existing
    /// document module compares disk bytes, preserves metadata and publishes.
    pub fn commit(self, immutable_roots: &[PathBuf]) -> Result<(), NativeConfigurationError> {
        use NativeConfigurationError::*;
        let target = validated_target(&self.source, immutable_roots)?;
        if !same_path(&target, &self.target) {
            return Err(Conflict);
        }
        let parent = target.parent().ok_or(ReadOnly)?;
        fs::create_dir_all(parent).map_err(|_| Unreadable)?;
        // A parent created or redirected while preparing must not change the
        // destination that was shown to the user.
        if !same_path(
            &validated_target(&self.source, immutable_roots)?,
            &self.target,
        ) {
            return Err(Conflict);
        }
        match document_file::save_document(&target, &self.replacement, self.expected.as_deref())
            .map_err(|_| Unreadable)?
        {
            SaveOutcome::Saved { .. } => {
                if read(&target)?.as_deref() != Some(&self.replacement) {
                    return Err(Conflict);
                }
                Ok(())
            }
            // Conflict contains current disk text for editor callers. Do not
            // serialize it or forward it to a frontend/native settings form.
            SaveOutcome::Conflict { .. } => Err(Conflict),
        }
    }
}

fn source_path(source: &Value) -> Result<PathBuf, NativeConfigurationError> {
    use NativeConfigurationError::*;
    let uri = url::Url::parse(source["uri"].as_str().ok_or(Invalid)?).map_err(|_| Invalid)?;
    if uri.scheme() != "file"
        || uri.query().is_some()
        || uri.fragment().is_some()
        || !uri.username().is_empty()
        || uri.password().is_some()
    {
        return Err(Invalid);
    }
    uri.to_file_path().map_err(|_| Invalid)
}

fn read(path: &Path) -> Result<Option<String>, NativeConfigurationError> {
    use NativeConfigurationError::*;
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Unreadable),
    };
    let metadata = file.metadata().map_err(|_| Unreadable)?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES {
        return Err(Unreadable);
    }
    if metadata.permissions().readonly() {
        return Err(ReadOnly);
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Unreadable)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(Unreadable);
    }
    String::from_utf8(bytes).map(Some).map_err(|_| Unreadable)
}

fn validated_target(
    source: &Path,
    immutable_roots: &[PathBuf],
) -> Result<PathBuf, NativeConfigurationError> {
    let target = resolve_target(source)?;
    for root in immutable_roots {
        let root = resolve_target(root)?;
        let target_key = path_key(&target);
        let root_key = path_key(&root);
        if target_key == root_key || target_key.starts_with(&(root_key + "/")) {
            return Err(NativeConfigurationError::ReadOnly);
        }
    }
    Ok(target)
}

fn resolve_target(path: &Path) -> Result<PathBuf, NativeConfigurationError> {
    use NativeConfigurationError::*;
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err(ReadOnly);
    }
    let mut parent = path;
    let mut missing = Vec::new();
    loop {
        match fs::symlink_metadata(parent) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                missing.push(parent.file_name().ok_or(Unreadable)?.to_owned());
                parent = parent.parent().ok_or(Unreadable)?;
            }
            Err(_) => return Err(Unreadable),
        }
    }
    let mut target = parent.canonicalize().map_err(|_| Unreadable)?;
    for part in missing.into_iter().rev() {
        target.push(part);
    }
    Ok(target)
}

fn same_path(left: &Path, right: &Path) -> bool {
    path_key(left) == path_key(right)
}
fn path_key(path: &Path) -> String {
    let path = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        path.to_lowercase()
    } else {
        path
    }
}

#[cfg(test)]
mod tests;
