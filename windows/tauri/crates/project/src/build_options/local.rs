//! Machine-local Build preferences. The document adapter owns atomic writes;
//! Core owns merge/edit semantics. Reads never create files or probe tools.
use crate::document_file::{self, SaveOutcome};
use crate::native_configuration::{NativeConfigurationError as Error, validated_target};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::Mutex,
};

static WRITES: Mutex<()> = Mutex::new(());
const MAX_BYTES: u64 = 2 * 1024 * 1024;

pub struct BuildOptionsSnapshot {
    pub document: Value,
    pub empty_selections: Value,
    pub revision: String,
    team: Value,
    local: Value,
    local_text: Option<String>,
    local_identity: Option<String>,
    target: PathBuf,
}

fn read(path: &Path) -> Result<Option<document_file::DocumentRead>, Error> {
    match fs::metadata(path) {
        Ok(meta) if !meta.is_file() || meta.len() > MAX_BYTES => return Err(Error::Unreadable),
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            return Err(Error::Unreadable);
        }
        _ => {}
    }
    // Match the reader's limit before text decoding, and reject a file which
    // grew after metadata. The shared adapter supplies the replacement identity.
    if path.exists() {
        let mut bytes = Vec::new();
        fs::File::open(path)
            .map_err(|_| Error::Unreadable)?
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Unreadable)?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::Unreadable);
        }
    }
    document_file::read_document_with_encoding(path, Some("UTF-8")).map_err(|_| Error::Unreadable)
}

fn core(command: &str, payload: Value) -> Result<Value, Error> {
    let reply: Value = serde_json::from_str(&lithe_core::execute_json(
        &json!({"command":command,"payload":payload}).to_string(),
    ))
    .map_err(|_| Error::Invalid)?;
    if reply["ok"] != true || reply["data"]["status"] != "ok" {
        return Err(Error::Invalid);
    }
    Ok(reply["data"].clone())
}

pub fn read_snapshot(workspace: &Path, local_path: &Path) -> Result<BuildOptionsSnapshot, Error> {
    let root = workspace.canonicalize().map_err(|_| Error::Unreadable)?;
    let team_path = validated_target(&root.join(".lithe/build/options.json"), &[])?;
    if !team_path.starts_with(&root) {
        return Err(Error::ReadOnly);
    }
    let target = validated_target(local_path, &[])?;
    let team_raw = read(&team_path)?;
    let local_raw = read(&target)?;
    let team = match &team_raw {
        Some(raw) => serde_json::from_str(raw.content.trim_start_matches('\u{feff}'))
            .map_err(|_| Error::Invalid)?,
        None => json!({"version":1,"systems":{}}),
    };
    let local = match &local_raw {
        Some(raw) => serde_json::from_str(raw.content.trim_start_matches('\u{feff}'))
            .map_err(|_| Error::Invalid)?,
        None => json!({"version":1,"document":{"version":1,"systems":{}},"emptySelections":{}}),
    };
    let result = core(
        "build.resolveStoredOptions",
        json!({"document":team,"local":local}),
    )?;
    let mut digest = Sha256::new();
    for value in [
        team_path.to_string_lossy().into_owned(),
        target.to_string_lossy().into_owned(),
        team_raw
            .as_ref()
            .map(|raw| raw.identity.clone())
            .unwrap_or_default(),
        local_raw
            .as_ref()
            .map(|raw| raw.identity.clone())
            .unwrap_or_default(),
    ] {
        digest.update(value.len().to_le_bytes());
        digest.update(value.as_bytes());
    }
    Ok(BuildOptionsSnapshot {
        document: result["storage"]["document"].clone(),
        empty_selections: result["storage"]["emptySelections"].clone(),
        revision: format!("sha256:{:x}", digest.finalize()),
        team,
        local: result["storage"]["local"].clone(),
        local_text: local_raw.as_ref().map(|raw| raw.content.clone()),
        local_identity: local_raw.map(|raw| raw.identity),
        target,
    })
}

/// Rechecks both source layers and cancellation at the publication boundary.
/// The local path comes from app-data, never from a frontend-controlled path.
pub fn save_option(
    workspace: &Path,
    local_path: &Path,
    manifest: &Value,
    system: &str,
    mut request: Value,
    expected_revision: &str,
    immutable: &[PathBuf],
    current: impl Fn() -> Result<(), Error>,
) -> Result<Value, Error> {
    let _write = WRITES.lock().map_err(|_| Error::Unreadable)?;
    current()?;
    let before = read_snapshot(workspace, local_path)?;
    if before.revision != expected_revision
        || validated_target(local_path, immutable)? != before.target
    {
        return Err(Error::Conflict);
    }
    let request = request.as_object_mut().ok_or(Error::Invalid)?;
    request.insert("document".into(), before.team.clone());
    request.insert("local".into(), before.local.clone());
    let result = core(
        "build.editStoredOption",
        json!({"manifest":manifest,"buildSystemID":system,"request":request}),
    )?;
    let next = &result["edit"]["local"];
    if next == &before.local {
        return Ok(result["edit"]["options"].clone());
    }
    let replacement = serde_json::to_string_pretty(next).map_err(|_| Error::Invalid)?;
    if read_snapshot(workspace, local_path)?.revision != before.revision {
        return Err(Error::Conflict);
    }
    current()?;
    fs::create_dir_all(before.target.parent().ok_or(Error::ReadOnly)?)
        .map_err(|_| Error::Unreadable)?;
    if validated_target(local_path, immutable)? != before.target {
        return Err(Error::Conflict);
    }
    current()?;
    match document_file::save_document_with_encoding(
        &before.target,
        &replacement,
        before.local_text.as_deref(),
        Some("UTF-8"),
        Some("UTF-8"),
        before.local_identity.as_deref(),
    )
    .map_err(|_| Error::Unreadable)?
    {
        SaveOutcome::Conflict { .. } => return Err(Error::Conflict),
        SaveOutcome::Saved { .. } => {}
    }
    let after = read_snapshot(workspace, local_path)?;
    if after.local != *next || after.team != before.team {
        return Err(Error::Conflict);
    }
    Ok(result["edit"]["options"].clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lithe-build-local-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("workspace/.lithe/build")).unwrap();
            Self(root.canonicalize().unwrap())
        }
        fn workspace(&self) -> PathBuf {
            self.0.join("workspace")
        }
        fn local(&self) -> PathBuf {
            self.0.join("app-data/build-options/workspace.json")
        }
        fn team(&self) -> PathBuf {
            self.workspace().join(".lithe/build/options.json")
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn manifest() -> Value {
        serde_json::from_str(include_str!("../../../../../../shared/contracts/plugins/v1/fixtures/build-instance-options.plugin.json")).unwrap()
    }
    fn request() -> Value {
        json!({"root":"app","optionID":"release","value":false,"modelValues":{}})
    }

    #[test]
    fn explicit_local_save_and_reset_roundtrip_without_changing_team_or_sibling_values() {
        let f = Fixture::new();
        let team=json!({"version":1,"systems":{"cargo":{"instanceDefaults":{"release":true},"instances":{"other":{"label":"keep"}}},"dormant":{"options":{"text":"keep"}}}}).to_string();
        fs::write(f.team(), &team).unwrap();
        let before = read_snapshot(&f.workspace(), &f.local()).unwrap();
        assert!(!f.local().exists());
        let mut unchanged = request();
        unchanged["value"] = Value::Null;
        save_option(
            &f.workspace(),
            &f.local(),
            &manifest(),
            "cargo",
            unchanged,
            &before.revision,
            &[],
            || Ok(()),
        )
        .unwrap();
        assert!(
            !f.local().exists(),
            "Resetting an inherited option must not create a local override"
        );
        save_option(
            &f.workspace(),
            &f.local(),
            &manifest(),
            "cargo",
            request(),
            &before.revision,
            &[],
            || Ok(()),
        )
        .unwrap();
        let after = read_snapshot(&f.workspace(), &f.local()).unwrap();
        assert_eq!(
            after.document["systems"]["cargo"]["instances"]["app"]["release"],
            false
        );
        assert_eq!(
            after.document["systems"]["cargo"]["instances"]["other"]["label"],
            "keep"
        );
        assert_eq!(
            after.document["systems"]["dormant"]["options"]["text"],
            "keep"
        );
        assert_ne!(before.revision, after.revision);
        assert_eq!(fs::read_to_string(f.team()).unwrap(), team);
        let mut reset = request();
        reset["value"] = Value::Null;
        save_option(
            &f.workspace(),
            &f.local(),
            &manifest(),
            "cargo",
            reset,
            &after.revision,
            &[],
            || Ok(()),
        )
        .unwrap();
        let reopened = read_snapshot(&f.workspace(), &f.local()).unwrap();
        assert!(
            reopened.document["systems"]["cargo"]["instances"]["app"]
                .get("release")
                .is_none()
        );
        assert_eq!(
            reopened.document["systems"]["cargo"]["instanceDefaults"]["release"],
            true
        );
        assert_eq!(fs::read_to_string(f.team()).unwrap(), team);
    }
    #[test]
    fn external_source_edits_invalid_values_and_cancelled_saves_preserve_original_files() {
        let f = Fixture::new();
        let before = read_snapshot(&f.workspace(), &f.local()).unwrap();
        fs::write(
            f.team(),
            json!({"version":1,"systems":{"cargo":{"options":{"offline":true}}}}).to_string(),
        )
        .unwrap();
        assert_eq!(
            save_option(
                &f.workspace(),
                &f.local(),
                &manifest(),
                "cargo",
                request(),
                &before.revision,
                &[],
                || Ok(())
            ),
            Err(Error::Conflict)
        );
        let before = read_snapshot(&f.workspace(), &f.local()).unwrap();
        assert_eq!(
            save_option(
                &f.workspace(),
                &f.local(),
                &manifest(),
                "cargo",
                request(),
                &before.revision,
                &[],
                || Err(Error::Conflict)
            ),
            Err(Error::Conflict)
        );
        let mut wrong = request();
        wrong["value"] = json!("false");
        assert_eq!(
            save_option(
                &f.workspace(),
                &f.local(),
                &manifest(),
                "cargo",
                wrong,
                &before.revision,
                &[],
                || Ok(())
            ),
            Err(Error::Invalid)
        );
        assert!(!f.local().exists());
        save_option(
            &f.workspace(),
            &f.local(),
            &manifest(),
            "cargo",
            request(),
            &before.revision,
            &[],
            || Ok(()),
        )
        .unwrap();
        let before = read_snapshot(&f.workspace(), &f.local()).unwrap();
        fs::write(f.local(), "external invalid bytes").unwrap();
        assert!(
            save_option(
                &f.workspace(),
                &f.local(),
                &manifest(),
                "cargo",
                request(),
                &before.revision,
                &[],
                || Ok(())
            )
            .is_err()
        );
        assert_eq!(
            fs::read_to_string(f.local()).unwrap(),
            "external invalid bytes"
        );
    }
    #[test]
    fn installed_resource_targets_and_oversized_local_documents_are_rejected() {
        let f = Fixture::new();
        let before = read_snapshot(&f.workspace(), &f.local()).unwrap();
        assert_eq!(
            save_option(
                &f.workspace(),
                &f.local(),
                &manifest(),
                "cargo",
                request(),
                &before.revision,
                &[f.0.join("app-data")],
                || Ok(())
            ),
            Err(Error::ReadOnly)
        );
        assert!(!f.local().exists());
        fs::create_dir_all(f.local().parent().unwrap()).unwrap();
        fs::write(f.local(), "x".repeat(MAX_BYTES as usize + 1)).unwrap();
        assert!(matches!(
            read_snapshot(&f.workspace(), &f.local()),
            Err(Error::Unreadable)
        ));
    }
    #[cfg(unix)]
    #[test]
    fn redirected_local_alias_cannot_publish_into_an_installation() {
        let f = Fixture::new();
        let before = read_snapshot(&f.workspace(), &f.local()).unwrap();
        let installed = f.0.join("installed");
        fs::create_dir_all(&installed).unwrap();
        fs::create_dir_all(f.local().parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(installed.join("resource.json"), f.local()).unwrap();
        assert!(
            save_option(
                &f.workspace(),
                &f.local(),
                &manifest(),
                "cargo",
                request(),
                &before.revision,
                &[installed.clone()],
                || Ok(())
            )
            .is_err()
        );
        assert!(!installed.join("resource.json").exists());
    }
}
