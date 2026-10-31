//! Persist Core-created Provider selectors through the existing guarded document
//! writer. Preparation is read-only; no executable or private model is saved.
use crate::document_file::{self, SaveOutcome};
use crate::native_configuration::{NativeConfigurationError as Error, validated_target};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

const MAX_BYTES: u64 = 2 * 1024 * 1024;

/// Native-only write intent; source bytes never enter the WebView.
pub struct PreparedProviderRun {
    root: PathBuf,
    target: PathBuf,
    expected: Option<String>,
    identity: Option<String>,
    replacement: String,
    id: String,
}

pub fn prepare(
    root: &Path,
    reference: Value,
    name: &str,
    immutable: &[PathBuf],
) -> Result<PreparedProviderRun, Error> {
    let root = root.canonicalize().map_err(|_| Error::Unreadable)?;
    let target = target(&root, immutable)?;
    let expected = read(&target)?;
    // The shared command owns schema, stable IDs and preserving unrelated data.
    let response: Value = serde_json::from_str(&lithe_core::execute_json(
        &json!({
            "command":"runConfig.createUserConfiguration", "payload":{
                "root":root,"scope":"local","name":name,"type":"buildProvider","build":reference
            }
        })
        .to_string(),
    ))
    .map_err(|_| Error::Invalid)?;
    if response["ok"] != true {
        return Err(Error::Invalid);
    }
    let id = response["data"]["id"]
        .as_str()
        .ok_or(Error::Invalid)?
        .to_owned();
    let replacement = response["data"]["document"]
        .as_str()
        .filter(|text| text.len() as u64 <= MAX_BYTES)
        .ok_or(Error::Invalid)?
        .to_owned();
    Ok(PreparedProviderRun {
        root,
        target,
        expected: expected.as_ref().map(|doc| doc.content.clone()),
        identity: expected.map(|doc| doc.identity),
        replacement,
        id,
    })
}

impl PreparedProviderRun {
    /// Reject external edits and path redirection, then verify the exact result.
    /// The host serializes this transaction with its other Run document writes.
    pub fn commit(self, immutable: &[PathBuf], ignore_entries: &[&str]) -> Result<String, Error> {
        if target(&self.root, immutable)? != self.target {
            return Err(Error::Conflict);
        }
        if read(&self.target)?.map(|doc| doc.identity) != self.identity {
            return Err(Error::Conflict);
        }
        fs::create_dir_all(self.target.parent().ok_or(Error::Invalid)?)
            .map_err(|_| Error::Unreadable)?;
        if target(&self.root, immutable)? != self.target {
            return Err(Error::Conflict);
        }
        ensure_ignored(&self.root, immutable, ignore_entries)?;
        if target(&self.root, immutable)? != self.target {
            return Err(Error::Conflict);
        }
        match document_file::save_document_with_encoding(
            &self.target,
            &self.replacement,
            self.expected.as_deref(),
            Some("UTF-8"),
            Some("UTF-8"),
            self.identity.as_deref(),
        )
        .map_err(|_| Error::Unreadable)?
        {
            SaveOutcome::Conflict { .. } => Err(Error::Conflict),
            SaveOutcome::Saved { .. } => {
                if read(&self.target)?.as_ref().map(|doc| doc.content.as_str())
                    != Some(self.replacement.as_str())
                {
                    return Err(Error::Conflict);
                }
                Ok(self.id)
            }
        }
    }
}

fn ensure_ignored(root: &Path, immutable: &[PathBuf], entries: &[&str]) -> Result<(), Error> {
    if entries.is_empty() {
        return Ok(());
    }
    let source = root.join(".lithe/.gitignore");
    let path = validated_target(&source, immutable)?;
    if !path.starts_with(root) {
        return Err(Error::ReadOnly);
    }
    let expected = read(&path)?;
    let text = expected
        .as_ref()
        .map(|doc| doc.content.as_str())
        .unwrap_or_default();
    let mut replacement = text.to_owned();
    for entry in entries {
        if !replacement.lines().any(|line| line.trim() == *entry) {
            if !replacement.is_empty() && !replacement.ends_with('\n') {
                replacement.push('\n');
            }
            replacement.push_str(entry);
            replacement.push('\n');
        }
    }
    if replacement == text {
        return Ok(());
    }
    if validated_target(&source, immutable)? != path {
        return Err(Error::Conflict);
    }
    match document_file::save_document_with_encoding(
        &path,
        &replacement,
        expected.as_ref().map(|doc| doc.content.as_str()),
        Some("UTF-8"),
        Some("UTF-8"),
        expected.as_ref().map(|doc| doc.identity.as_str()),
    )
    .map_err(|_| Error::Unreadable)?
    {
        SaveOutcome::Conflict { .. } => Err(Error::Conflict),
        SaveOutcome::Saved { .. } => {
            if read(&path)?.as_ref().map(|doc| doc.content.as_str()) == Some(replacement.as_str()) {
                Ok(())
            } else {
                Err(Error::Conflict)
            }
        }
    }
}

fn target(root: &Path, immutable: &[PathBuf]) -> Result<PathBuf, Error> {
    let target = validated_target(&root.join(".lithe/run/local.json"), immutable)?;
    if !target.starts_with(root) {
        return Err(Error::ReadOnly);
    }
    Ok(target)
}

fn read(path: &Path) -> Result<Option<document_file::DocumentRead>, Error> {
    match fs::metadata(path) {
        Ok(meta) if !meta.is_file() || meta.len() > MAX_BYTES => return Err(Error::Unreadable),
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            return Err(Error::Unreadable);
        }
        _ => {}
    }
    document_file::read_document_with_encoding(path, Some("UTF-8")).map_err(|_| Error::Unreadable)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-provider-run-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path.canonicalize().unwrap())
        }
        fn local(&self) -> PathBuf {
            self.0.join(".lithe/run/local.json")
        }
        fn write(&self, value: &[u8]) {
            fs::create_dir_all(self.local().parent().unwrap()).unwrap();
            fs::write(self.local(), value).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn reference(args: &[&str]) -> Value {
        json!({"pluginID":"dev.example.build","buildSystemID":"example","root":".",
        "run":"serve","projectID":"app","targetID":"target","execution":"service","userArguments":args})
    }

    #[test]
    fn preparation_is_read_only_and_saved_selectors_keep_ids_and_unrelated_fields() {
        let f = Fixture::new();
        let first = prepare(&f.0, reference(&["", "two words"]), "Service", &[]).unwrap();
        assert!(!f.0.join(".lithe").exists());
        let id = first.commit(&[], &["run/local.json"]).unwrap();
        assert_eq!(
            fs::read_to_string(f.0.join(".lithe/.gitignore")).unwrap(),
            "run/local.json\n"
        );
        let mut doc: Value = serde_json::from_slice(&fs::read(f.local()).unwrap()).unwrap();
        doc["toolchain"] = json!({"java":{"homePath":"C:/Example JDK"}});
        f.write(&serde_json::to_vec(&doc).unwrap());
        assert_eq!(
            prepare(&f.0, reference(&["new"]), "Renamed", &[])
                .unwrap()
                .commit(&[], &["run/local.json"])
                .unwrap(),
            id
        );
        let doc: Value = serde_json::from_slice(&fs::read(f.local()).unwrap()).unwrap();
        assert_eq!(doc["configurations"].as_array().unwrap().len(), 1);
        assert_eq!(
            doc["configurations"][0]["extensions"]["build"]["userArguments"],
            json!(["new"])
        );
        assert_eq!(doc["toolchain"]["java"]["homePath"], "C:/Example JDK");
    }

    #[test]
    fn external_creation_or_edit_conflicts_and_retains_original_bytes() {
        let f = Fixture::new();
        for original in [
            None,
            Some(b"{\"version\":2,\"configurations\":[]}".as_slice()),
        ] {
            if let Some(bytes) = original {
                f.write(bytes);
            } else {
                let _ = fs::remove_file(f.local());
            }
            let prepared = prepare(&f.0, reference(&[]), "Service", &[]).unwrap();
            f.write(b"external editor content");
            assert_eq!(
                prepared.commit(&[], &["run/local.json"]).unwrap_err(),
                Error::Conflict
            );
            assert_eq!(fs::read(f.local()).unwrap(), b"external editor content");
        }
    }

    #[test]
    fn malformed_source_and_immutable_locations_never_write() {
        let f = Fixture::new();
        f.write(b"malformed");
        assert!(prepare(&f.0, reference(&[]), "Service", &[]).is_err());
        assert_eq!(fs::read(f.local()).unwrap(), b"malformed");
        let protected = Fixture::new();
        assert!(matches!(
            prepare(
                &protected.0,
                reference(&[]),
                "Service",
                &[protected.0.clone()]
            ),
            Err(Error::ReadOnly)
        ));
        assert!(!protected.0.join(".lithe").exists());
    }

    #[cfg(unix)]
    #[test]
    fn ignore_file_alias_cannot_write_outside_the_workspace() {
        let f = Fixture::new();
        let outside = Fixture::new();
        let prepared = prepare(&f.0, reference(&[]), "Service", &[]).unwrap();
        fs::create_dir_all(f.0.join(".lithe")).unwrap();
        let foreign = outside.0.join("ignore");
        fs::write(&foreign, "keep outside bytes").unwrap();
        std::os::unix::fs::symlink(&foreign, f.0.join(".lithe/.gitignore")).unwrap();
        assert_eq!(
            prepared.commit(&[], &["run/local.json"]).unwrap_err(),
            Error::ReadOnly
        );
        assert_eq!(fs::read_to_string(foreign).unwrap(), "keep outside bytes");
        assert!(!f.local().exists());
    }

    #[cfg(unix)]
    #[test]
    fn redirected_parent_is_rejected_before_write() {
        let f = Fixture::new();
        let outside = Fixture::new();
        let prepared = prepare(&f.0, reference(&[]), "Service", &[]).unwrap();
        std::os::unix::fs::symlink(&outside.0, f.0.join(".lithe")).unwrap();
        assert!(prepared.commit(&[], &["run/local.json"]).is_err());
        assert!(!outside.0.join("run").exists());
    }
}
