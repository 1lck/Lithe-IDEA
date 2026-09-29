//! Content-addressed copies of the Maven settings documents JDT LS reads.
//!
//! JDT LS decides whether Maven settings changed by comparing the settings
//! *paths* it receives (`StandardPreferenceManager.update`). Only a changed path
//! makes it reload the settings and force-update every Maven project. A file
//! edited in place, or a generated file rewritten under a fixed name, therefore
//! leaves the running import on the old mirrors and local repository.
//!
//! Every settings document Lithe hands to JDT LS is copied into the session's
//! `-data` directory under a name derived from its contents. A content change is
//! then always a path change, which lets the upstream change detection do the
//! reload instead of Lithe re-implementing it. The copies live and die with the
//! JDT LS workspace state that uses them, and never touch the user's files or
//! the installed product.

use crate::project::MavenJdtConfiguration;
use crate::protocol::{CoreError, ErrorCode};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Directory inside the JDT LS `-data` directory that holds the copies.
const SETTINGS_DIRECTORY: &[&str] = &[".lithe", "maven"];
/// File-name prefix of the user-level copy (`java.configuration.maven.userSettings`).
const USER_SETTINGS_PREFIX: &str = "user-settings-";
/// File-name prefix of the installation-level copy (`java.configuration.maven.globalSettings`).
const GLOBAL_SETTINGS_PREFIX: &str = "global-settings-";
/// Hex digits of the content digest kept in a file name.
const DIGEST_LENGTH: usize = 16;

/// Bare user-level settings used when Maven Settings overrides the local
/// repository without naming a settings file of its own.
const EMPTY_MAVEN_SETTINGS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
</settings>
"#;

/// Settings paths to send to JDT LS for one Maven configuration.
#[derive(Debug, Default, Eq, PartialEq)]
pub(crate) struct MaterializedMavenSettings {
    /// Path sent as `userSettings`, or `None` to leave JDT LS on Maven's default.
    pub user_settings_path: Option<String>,
    /// Path sent as `globalSettings`, or `None` when no installation is known.
    pub global_settings_path: Option<String>,
    /// Problems that degraded a document to its original path. They are
    /// reported to the session log rather than failing startup, because a
    /// stale settings path must not cost every Java file its language service.
    pub warnings: Vec<String>,
}

/// Directory holding the settings copies for one JDT LS `-data` directory.
pub(crate) fn settings_directory(data_directory: &Path) -> PathBuf {
    SETTINGS_DIRECTORY
        .iter()
        .fold(data_directory.to_path_buf(), |path, part| path.join(part))
}

/// Maven's default user-level settings file, `${user.home}/.m2/settings.xml`.
///
/// Maven reads it whenever no settings file is configured, so JDT LS must see
/// the same document through a content-addressed copy. The home directory
/// comes from the language server's launch environment first, because that is
/// the environment Maven inside JDT LS observes.
pub(crate) fn default_user_settings_path(
    environment: &std::collections::BTreeMap<String, String>,
) -> Option<PathBuf> {
    let variable = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    let home = environment
        .get(variable)
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os(variable).map(PathBuf::from))?;
    Some(home.join(".m2").join("settings.xml"))
}

/// Writes the content-addressed settings copies for `configuration` into
/// `directory`. Copies remain valid until the owning JDT workspace is removed:
/// sending a notification does not acknowledge that JDT LS has read the file.
///
/// The user-level source is the configured settings file, else Maven's default
/// user settings when they exist, else an empty document when only a local
/// repository override is configured. JDT LS has no repository preference, so
/// that override is written into the user-level copy.
pub(crate) fn materialize(
    directory: &Path,
    configuration: &MavenJdtConfiguration,
    default_user_settings: Option<&Path>,
) -> Result<MaterializedMavenSettings, CoreError> {
    let mut warnings = Vec::new();

    let user_source = match configuration.settings_path.as_deref() {
        Some(path) => Some(SettingsSource::Configured(path.to_string())),
        None => default_user_settings
            .filter(|path| path.is_file())
            .map(|path| SettingsSource::Configured(path.to_string_lossy().into_owned()))
            .or_else(|| {
                configuration
                    .local_repository_path
                    .as_ref()
                    .map(|_| SettingsSource::Empty)
            }),
    };
    let user_settings_path = match user_source {
        None => None,
        Some(source) => match source.read() {
            Ok(document) => {
                let document = match configuration.local_repository_path.as_deref() {
                    Some(repository) => {
                        crate::project::settings_with_local_repository(&document, repository)?
                    }
                    None => document,
                };
                let path = write_copy(directory, USER_SETTINGS_PREFIX, &document)?;
                Some(path.to_string_lossy().into_owned())
            }
            Err((path, error)) => {
                warnings.push(format!(
                    "Could not read the Maven settings file {path}, so the Java language service reads it directly and ignores the local repository override: {error}"
                ));
                Some(path)
            }
        },
    };

    let global_settings_path = match configuration.global_settings_path.as_deref() {
        None => None,
        Some(path) => match std::fs::read_to_string(path) {
            Ok(document) => {
                let copy = write_copy(directory, GLOBAL_SETTINGS_PREFIX, &document)?;
                Some(copy.to_string_lossy().into_owned())
            }
            Err(error) => {
                warnings.push(format!(
                    "Could not read the Maven installation settings file {path}, so the Java language service reads it directly: {error}"
                ));
                Some(path.to_string())
            }
        },
    };

    Ok(MaterializedMavenSettings {
        user_settings_path,
        global_settings_path,
        warnings,
    })
}

/// Where the user-level document comes from.
enum SettingsSource {
    /// A settings file on disk, configured or Maven's default.
    Configured(String),
    /// No file exists, but a local repository override needs a document.
    Empty,
}

impl SettingsSource {
    fn read(&self) -> Result<String, (String, std::io::Error)> {
        match self {
            Self::Configured(path) => {
                std::fs::read_to_string(path).map_err(|error| (path.clone(), error))
            }
            Self::Empty => Ok(EMPTY_MAVEN_SETTINGS.to_string()),
        }
    }
}

/// Writes `document` under a name derived from its contents.
///
/// An existing file with that name already holds the same bytes, so it is
/// reused. New files are written beside the target and renamed into place so
/// JDT LS never reads a partially written document.
fn write_copy(directory: &Path, prefix: &str, document: &str) -> Result<PathBuf, CoreError> {
    let digest = Sha256::digest(document.as_bytes());
    let name = format!("{prefix}{}.xml", &hex(&digest)[..DIGEST_LENGTH]);
    let target = directory.join(name);
    if target.is_file() {
        return Ok(target);
    }
    std::fs::create_dir_all(directory).map_err(|error| {
        CoreError::new(
            ErrorCode::ProcessStartFailed,
            "Could not create the Maven settings directory.",
        )
        .with_details(error.to_string())
    })?;
    static NEXT_COPY: AtomicU64 = AtomicU64::new(0);
    // Exclusive creation also avoids truncating a stale staging file after PID reuse.
    let (staging, mut file) = loop {
        let nonce = NEXT_COPY.fetch_add(1, Ordering::Relaxed);
        let path = directory.join(format!(".{prefix}{}-{nonce}.tmp", std::process::id()));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&path) {
            Ok(file) => break (path, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(CoreError::new(
                    ErrorCode::ProcessStartFailed,
                    "Could not create the generated Maven settings.",
                )
                .with_details(error.to_string()))
            }
        }
    };
    file.write_all(document.as_bytes())
        .and_then(|()| {
            drop(file);
            std::fs::rename(&staging, &target).or_else(|error| {
                // Windows can reject replacing a copy another writer just published.
                // Only accept that result when the full content matches.
                if std::fs::read(&target).is_ok_and(|bytes| bytes == document.as_bytes()) {
                    std::fs::remove_file(&staging)
                } else {
                    Err(error)
                }
            })
        })
        .map_err(|error| {
            let _ = std::fs::remove_file(&staging);
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not write the generated Maven settings.",
            )
            .with_details(error.to_string())
        })?;
    Ok(target)
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push(DIGITS[(byte >> 4) as usize] as char);
        value.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Temporary directory removed when the test ends, pass or fail.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(label: &str) -> Self {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock should be valid")
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "lithe-maven-settings-{label}-{}-{nonce}",
                std::process::id()
            ));
            std::fs::create_dir_all(&root).expect("scratch directory should be creatable");
            Self(root)
        }

        fn write(&self, name: &str, contents: &str) -> String {
            let path = self.0.join(name);
            std::fs::write(&path, contents).expect("fixture should be writable");
            path.to_string_lossy().into_owned()
        }

        fn copies(&self) -> PathBuf {
            settings_directory(&self.0.join("data"))
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn configuration(
        settings_path: Option<String>,
        global_settings_path: Option<String>,
        local_repository_path: Option<&str>,
    ) -> MavenJdtConfiguration {
        MavenJdtConfiguration {
            profiles: Vec::new(),
            settings_path,
            global_settings_path,
            local_repository_path: local_repository_path.map(ToString::to_string),
            project_paths: Vec::new(),
            source_paths: Vec::new(),
        }
    }

    fn read(path: &Option<String>) -> String {
        std::fs::read_to_string(path.as_deref().expect("a copy should be produced"))
            .expect("copy should exist")
    }

    #[test]
    fn a_repository_override_keeps_the_configured_mirrors() {
        // JDT LS has no repository preference, so the override travels inside a
        // settings document. The copy must not drop the mirrors the workspace
        // already resolves through.
        let scratch = Scratch::new("repository-override");
        let configured = scratch.write(
            "settings.xml",
            r#"<settings><localRepository>/old</localRepository><mirrors><mirror><id>aliyunmaven</id></mirror></mirrors></settings>"#,
        );

        let materialized = materialize(
            &scratch.copies(),
            &configuration(Some(configured.clone()), None, Some("/opt/repository")),
            None,
        )
        .expect("settings should be materialized");

        let document = read(&materialized.user_settings_path);
        assert!(document.contains("<localRepository>/opt/repository</localRepository>"));
        assert!(document.contains("<id>aliyunmaven</id>"));
        assert!(!document.contains("/old"));
        assert!(materialized.warnings.is_empty());
        let original = std::fs::read_to_string(configured).expect("source should still exist");
        assert!(original.contains("<localRepository>/old</localRepository>"));
    }

    #[test]
    fn a_repository_override_without_settings_uses_a_minimal_document() {
        let scratch = Scratch::new("repository-only");

        let materialized = materialize(
            &scratch.copies(),
            &configuration(None, None, Some("/opt/repository")),
            None,
        )
        .expect("settings should be materialized");

        assert!(read(&materialized.user_settings_path)
            .contains("<localRepository>/opt/repository</localRepository>"));
    }

    #[test]
    fn configured_settings_without_an_override_are_still_copied() {
        // Passing the user's own path would let an in-place edit go unnoticed:
        // JDT LS compares paths, so the copy is what makes the edit visible.
        let scratch = Scratch::new("no-override");
        let configured = scratch.write("settings.xml", "<settings><mirrors/></settings>");

        let materialized = materialize(
            &scratch.copies(),
            &configuration(Some(configured.clone()), None, None),
            None,
        )
        .expect("settings should be materialized");

        let copy = materialized.user_settings_path.clone().expect("copy");
        assert_ne!(copy, configured);
        assert!(Path::new(&copy).starts_with(scratch.copies()));
        assert_eq!(
            read(&materialized.user_settings_path),
            "<settings><mirrors/></settings>"
        );
    }

    #[test]
    fn editing_a_settings_file_changes_the_path_jdt_ls_receives() {
        // Regression for #970: a generated file under a fixed name made every
        // later settings change invisible to JDT LS's path comparison.
        let scratch = Scratch::new("content-change");
        let configured = scratch.write("settings.xml", "<settings><mirrors/></settings>");
        let first = materialize(
            &scratch.copies(),
            &configuration(Some(configured.clone()), None, Some("/first")),
            None,
        )
        .expect("first materialization");
        let unchanged = materialize(
            &scratch.copies(),
            &configuration(Some(configured.clone()), None, Some("/first")),
            None,
        )
        .expect("repeated materialization");
        let repository_changed = materialize(
            &scratch.copies(),
            &configuration(Some(configured.clone()), None, Some("/second")),
            None,
        )
        .expect("repository change");
        scratch.write(
            "settings.xml",
            "<settings><mirrors><mirror/></mirrors></settings>",
        );
        let file_edited = materialize(
            &scratch.copies(),
            &configuration(Some(configured), None, Some("/second")),
            None,
        )
        .expect("file edit");

        assert_eq!(first.user_settings_path, unchanged.user_settings_path);
        assert_ne!(
            first.user_settings_path,
            repository_changed.user_settings_path
        );
        assert_ne!(
            repository_changed.user_settings_path,
            file_edited.user_settings_path
        );
    }

    #[test]
    fn installation_settings_are_copied_by_content() {
        let scratch = Scratch::new("global");
        let global = scratch.write("global.xml", "<settings><mirrors/></settings>");

        let first = materialize(
            &scratch.copies(),
            &configuration(None, Some(global.clone()), None),
            None,
        )
        .expect("global settings");
        assert_eq!(
            read(&first.global_settings_path),
            "<settings><mirrors/></settings>"
        );
        assert_eq!(first.user_settings_path, None);
        scratch.write("global.xml", "<settings><proxies/></settings>");
        let edited = materialize(
            &scratch.copies(),
            &configuration(None, Some(global), None),
            None,
        )
        .expect("edited global settings");

        assert_ne!(first.global_settings_path, edited.global_settings_path);
        assert_eq!(
            read(&edited.global_settings_path),
            "<settings><proxies/></settings>"
        );
    }

    #[test]
    fn maven_default_user_settings_are_used_when_none_are_configured() {
        let scratch = Scratch::new("default-user");
        let default =
            PathBuf::from(scratch.write("default.xml", "<settings><servers/></settings>"));

        let materialized = materialize(
            &scratch.copies(),
            &configuration(None, None, None),
            Some(&default),
        )
        .expect("default settings");
        assert_eq!(
            read(&materialized.user_settings_path),
            "<settings><servers/></settings>"
        );
        let absent = materialize(
            &scratch.copies(),
            &configuration(None, None, None),
            Some(&scratch.0.join("missing.xml")),
        )
        .expect("absent default settings");

        // Without a document JDT LS keeps Maven's own default, as the CLI does.
        assert_eq!(absent.user_settings_path, None);
    }

    #[test]
    fn copies_remain_readable_until_the_workspace_is_removed() {
        let scratch = Scratch::new("prune");
        let first = materialize(
            &scratch.copies(),
            &configuration(None, None, Some("/first")),
            None,
        )
        .expect("first");
        let second = materialize(
            &scratch.copies(),
            &configuration(None, None, Some("/second")),
            None,
        )
        .expect("second");

        assert!(read(&first.user_settings_path).contains("/first"));
        assert!(Path::new(second.user_settings_path.as_deref().unwrap()).exists());
    }

    #[test]
    fn an_unowned_staging_file_is_never_truncated_or_removed() {
        let scratch = Scratch::new("staging-owner");
        let copies = scratch.copies();
        std::fs::create_dir_all(&copies).unwrap();
        // The old PID-only name could belong to another update in this process.
        let other = copies.join(format!(".{USER_SETTINGS_PREFIX}{}.tmp", std::process::id()));
        std::fs::write(&other, "another writer's settings").unwrap();
        let result = materialize(&copies, &configuration(None, None, Some("/new")), None).unwrap();
        assert!(read(&result.user_settings_path).contains("/new"));
        assert_eq!(
            std::fs::read_to_string(other).unwrap(),
            "another writer's settings"
        );
    }

    #[test]
    fn an_unreadable_settings_file_warns_instead_of_failing_the_java_session() {
        // Losing the repository override costs one optional setting. Failing
        // here would leave every Java file without completion, navigation, and
        // diagnostics because of a stale path in Maven Settings.
        let scratch = Scratch::new("unreadable");
        let missing = scratch.0.join("deleted.xml").to_string_lossy().into_owned();

        let materialized = materialize(
            &scratch.copies(),
            &configuration(
                Some(missing.clone()),
                Some(missing.clone()),
                Some("/opt/repository"),
            ),
            None,
        )
        .expect("an unreadable settings file must not fail startup");

        assert_eq!(
            materialized.user_settings_path.as_deref(),
            Some(missing.as_str())
        );
        assert_eq!(
            materialized.global_settings_path.as_deref(),
            Some(missing.as_str())
        );
        assert_eq!(materialized.warnings.len(), 2);
        assert!(materialized.warnings[0].contains("local repository override"));
    }

    #[test]
    fn the_default_user_settings_follow_the_launch_environment() {
        let variable = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        let environment =
            std::collections::BTreeMap::from([(variable.to_string(), "/fixture/home".to_string())]);

        assert_eq!(
            default_user_settings_path(&environment),
            Some(
                PathBuf::from("/fixture/home")
                    .join(".m2")
                    .join("settings.xml")
            )
        );
    }
}
