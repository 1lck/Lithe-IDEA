//! Private native configuration transactions. Only the owning provider/Core
//! knows format semantics; the existing document adapter owns atomic publication.
//! Source and replacement bytes never become a serializable frontend value.

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
    output_file: PathBuf,
    manifest: Value,
    system: String,
    snapshot: Value,
    edits: Value,
}

/// Checks non-sensitive source versions without returning private XML. Alias
/// and resolved target paths both remain observable after symlink replacement.
pub fn check_sources(sources: &Value) -> Result<Value, NativeConfigurationError> {
    use NativeConfigurationError::*;
    let sources = sources
        .as_array()
        .filter(|sources| sources.len() <= 16)
        .ok_or(Invalid)?;
    let mut current = true;
    let mut paths = Vec::new();
    for source in sources {
        let expected = source["revision"].as_str().ok_or(Invalid)?;
        if expected != "missing"
            && !(expected.len() == 71
                && expected.starts_with("sha256:")
                && expected[7..]
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()))
        {
            return Err(Invalid);
        }
        if source["uri"].as_str().is_none_or(|uri| uri.len() > 8192) {
            return Err(Invalid);
        }
        let path = source_path(source)?;
        let target = resolve_target(&path)?;
        let text = read_with_writability(&target, false)?;
        let revision = text
            .as_ref()
            .map(|text| format!("sha256:{:x}", Sha256::digest(text.as_bytes())))
            .unwrap_or_else(|| "missing".into());
        current &= expected == revision;
        paths.push(path);
        if paths.last() != Some(&target) {
            paths.push(target);
        }
    }
    Ok(json!({"current":current,"paths":paths}))
}

/// Prepares only changed, Core-approved fields against exact source bytes.
pub fn prepare(
    manifest: &Value,
    system: &str,
    snapshot: &Value,
    edits: &Value,
    immutable_roots: &[PathBuf],
    output_file: PathBuf,
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
    let decoded: Value = serde_json::from_str(&lithe_core::execute_json(&json!({
        "command":"build.decodeConfiguration","payload":{"manifest":manifest,"buildSystemID":system,"request":{"result":snapshot}}
    }).to_string())).map_err(|_| Invalid)?;
    if decoded["ok"] != true || decoded["data"]["status"] != "ok" {
        return Err(Invalid);
    }
    let values = edits["values"].as_object().ok_or(Invalid)?;
    let fields = selected["fields"].as_array().ok_or(Invalid)?;
    if values.iter().all(|(id, value)| {
        fields
            .iter()
            .any(|field| field["id"] == *id && field["value"] == *value)
    }) {
        return Ok(None);
    }
    let output = validated_target(&output_file, immutable_roots)?;
    if !same_path(&output, &output_file) || same_path(&output, &target) {
        return Err(ReadOnly);
    }
    fs::create_dir_all(output.parent().ok_or(Invalid)?).map_err(|_| Unreadable)?;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(&output).map_err(|_| Unreadable)?;
    Ok(Some(PreparedNativeConfiguration {
        source,
        target,
        expected,
        output_file: output,
        manifest: manifest.clone(),
        system: system.to_owned(),
        snapshot: snapshot.clone(),
        edits: edits.clone(),
    }))
}

impl Drop for PreparedNativeConfiguration {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.output_file) {
            if error.kind() != std::io::ErrorKind::NotFound {
                log::warn!(
                    "Native configuration staging cleanup failed: {}",
                    error.kind()
                );
            }
        }
    }
}

impl PreparedNativeConfiguration {
    /// Only this private destination is exposed to the owning backend.
    pub fn output_file(&self) -> &Path {
        &self.output_file
    }
    /// Recheck link targets and protected roots immediately before the existing
    /// document module compares disk bytes, preserves metadata and publishes.
    pub fn commit(
        self,
        immutable_roots: &[PathBuf],
        receipt: &Value,
    ) -> Result<bool, NativeConfigurationError> {
        use NativeConfigurationError::*;
        let decoded: Value = serde_json::from_str(&lithe_core::execute_json(&json!({
            "command":"build.decodeConfigurationEdit", "payload":{"manifest":self.manifest,"buildSystemID":self.system,
                "request":{"snapshot":self.snapshot,"edits":self.edits,"result":receipt}}
        }).to_string())).map_err(|_| Invalid)?;
        if decoded["ok"] != true || decoded["data"]["status"] != "ok" {
            return Err(Invalid);
        }
        let edit = &decoded["data"]["edit"];
        if edit["changed"] == false {
            return Ok(false);
        }
        if !same_path(&resolve_target(&self.output_file)?, &self.output_file) {
            return Err(ReadOnly);
        }
        let replacement = read(&self.output_file)?.ok_or(Unreadable)?;
        if edit["revision"] != format!("sha256:{:x}", Sha256::digest(replacement.as_bytes())) {
            return Err(Conflict);
        }
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
        match document_file::save_document(&target, &replacement, self.expected.as_deref())
            .map_err(|_| Unreadable)?
        {
            SaveOutcome::Saved { .. } => {
                if read(&target)?.as_deref() != Some(&replacement) {
                    return Err(Conflict);
                }
                Ok(true)
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
    read_with_writability(path, true)
}

fn read_with_writability(
    path: &Path,
    require_writable: bool,
) -> Result<Option<String>, NativeConfigurationError> {
    use NativeConfigurationError::*;
    match fs::metadata(path) {
        Ok(metadata) if !metadata.is_file() || metadata.len() > MAX_BYTES => {
            return Err(Unreadable);
        }
        Ok(metadata) if require_writable && metadata.permissions().readonly() => {
            return Err(ReadOnly);
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Unreadable),
    }
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Unreadable),
    };
    let metadata = file.metadata().map_err(|_| Unreadable)?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES {
        return Err(Unreadable);
    }
    if require_writable && metadata.permissions().readonly() {
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

pub(crate) fn validated_target(
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
    #[cfg(windows)]
    if path.components().any(|part| match part {
        std::path::Component::Normal(name) => name.to_str().is_none_or(windows_ambiguous_component),
        std::path::Component::Prefix(prefix) => !matches!(
            prefix.kind(),
            std::path::Prefix::Disk(_)
                | std::path::Prefix::VerbatimDisk(_)
                | std::path::Prefix::UNC(_, _)
                | std::path::Prefix::VerbatimUNC(_, _)
        ),
        _ => false,
    }) {
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

#[cfg(any(windows, test))]
fn windows_ambiguous_component(name: &str) -> bool {
    if name.ends_with(['.', ' ']) || name.contains(':') {
        return true;
    }
    let stem = name.split('.').next().unwrap_or("").to_ascii_lowercase();
    matches!(stem.as_str(), "con" | "prn" | "aux" | "nul")
        || ["com", "lpt"].iter().any(|prefix| {
            stem.strip_prefix(prefix).is_some_and(|suffix| {
                suffix.len() == 1 && (b'1'..=b'9').contains(&suffix.as_bytes()[0])
            })
        })
}

fn same_path(left: &Path, right: &Path) -> bool {
    path_key(left) == path_key(right)
}
fn path_key(path: &Path) -> String {
    native_path_key(&path.to_string_lossy(), cfg!(windows))
}

// Canonical Windows paths use verbatim prefixes, while file URIs use ordinary
// drive/UNC paths. This changes spelling only; resolve_target separately rejects
// device paths and DOS aliases whose spelling could select a different file.
fn native_path_key(path: &str, windows: bool) -> String {
    let path = path.replace('\\', "/");
    if !windows {
        return path;
    }
    let path = path.to_lowercase();
    if let Some(unc) = path.strip_prefix("//?/unc/") {
        return format!("//{unc}");
    }
    if let Some(drive) = path.strip_prefix("//?/") {
        let bytes = drive.as_bytes();
        if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && &bytes[1..3] == b":/" {
            return drive.to_owned();
        }
    }
    path
}

#[cfg(test)]
mod tests;
