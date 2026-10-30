//! Reads and edits the user's own Maven settings (`~/.m2/settings.xml`).
//!
//! This is Maven's native user-level configuration, not a Lithe copy: every
//! project and command-line build reads it, so the settings page can edit it
//! without a project open. Only `<localRepository>` is edited; mirrors,
//! servers and their credentials are never returned to the frontend. A write
//! names the revision it was based on and is refused when another program
//! changed the file since, so a stale page cannot overwrite it.

use super::settings_xml::read_local_repository;
use crate::run::atomic_write;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

// Error prefixes the frontend translates; anything else is an OS diagnostic.
/// The file changed after the page read it.
pub(super) const CONFLICT_ERROR: &str = "mavenUserSettingsChanged";
/// The file is not a well-formed UTF-8 settings document.
pub(super) const INVALID_ERROR: &str = "mavenUserSettingsInvalid";
/// The edit has no repository path.
pub(super) const EMPTY_ERROR: &str = "mavenUserSettingsEmptyRepository";
/// The user profile directory that owns `.m2` is unknown.
pub(super) const NO_HOME_ERROR: &str = "mavenUserSettingsNoHome";

/// A new file starts from Maven's documented minimal settings document.
const NEW_SETTINGS_DOCUMENT: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<settings xmlns=\"http://maven.apache.org/SETTINGS/1.2.0\">\n</settings>\n";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenUserSettings {
    /// The user-level settings path Maven reads.
    pub path: String,
    pub status: MavenUserSettingsStatus,
    /// `<localRepository>` exactly as written, before `${user.home}` expansion.
    pub local_repository: Option<String>,
    /// Maven's built-in repository used when the settings declare none.
    pub default_local_repository: String,
    /// Content identity the next write must match; `None` while the file is absent.
    pub revision: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MavenUserSettingsStatus {
    Missing,
    Readable,
    /// The file exists but is not a well-formed settings document.
    Invalid,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteMavenUserLocalRepositoryArgs {
    pub local_repository: String,
    /// The revision the edit was based on; `None` when the file was absent.
    pub expected_revision: Option<String>,
}

fn settings_path(home: &Path) -> PathBuf {
    home.join(".m2").join("settings.xml")
}

fn revision(contents: &[u8]) -> String {
    format!("{:x}", Sha256::digest(contents))
}

pub(super) fn read(home: &Path) -> Result<MavenUserSettings, String> {
    let path = settings_path(home);
    let default_local_repository = home.join(".m2").join("repository");
    let mut settings = MavenUserSettings {
        path: path.to_string_lossy().into_owned(),
        status: MavenUserSettingsStatus::Missing,
        local_repository: None,
        default_local_repository: default_local_repository.to_string_lossy().into_owned(),
        revision: None,
    };
    let contents = match fs::read(&path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(settings),
        // An unreadable file must not look like an empty one.
        Err(error) => return Err(error.to_string()),
    };
    settings.revision = Some(revision(&contents));
    match std::str::from_utf8(&contents)
        .ok()
        .map(|text| read_local_repository(text.trim_start_matches('\u{feff}')))
    {
        Some(Ok(local_repository)) => {
            settings.status = MavenUserSettingsStatus::Readable;
            settings.local_repository = local_repository;
        }
        _ => settings.status = MavenUserSettingsStatus::Invalid,
    }
    Ok(settings)
}

pub(super) fn write_local_repository(
    home: &Path,
    args: WriteMavenUserLocalRepositoryArgs,
) -> Result<MavenUserSettings, String> {
    let local_repository = args.local_repository.trim();
    if local_repository.is_empty() {
        return Err(EMPTY_ERROR.into());
    }
    let path = settings_path(home);
    let current = match fs::read(&path) {
        Ok(contents) => Some(contents),
        Err(error) if error.kind() == ErrorKind::NotFound => None,
        Err(error) => return Err(error.to_string()),
    };
    if current.as_deref().map(revision) != args.expected_revision {
        return Err(CONFLICT_ERROR.into());
    }
    let source = match &current {
        Some(contents) => std::str::from_utf8(contents)
            .map_err(|_| INVALID_ERROR.to_string())?
            .to_string(),
        None => NEW_SETTINGS_DOCUMENT.to_string(),
    };
    // Keep a byte-order mark the user's editor wrote.
    let (bom, document) = match source.strip_prefix('\u{feff}') {
        Some(rest) => ("\u{feff}", rest),
        None => ("", source.as_str()),
    };
    // The writer streams events and would carry an unclosed element through.
    if read_local_repository(document).is_err() {
        return Err(INVALID_ERROR.into());
    }
    let rewritten = lithe_core::settings_with_local_repository(document, local_repository)
        .map_err(|error| {
            format!(
                "{INVALID_ERROR}: {}",
                error.details.unwrap_or(error.message)
            )
        })?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    atomic_write(&path, format!("{bom}{rewritten}").as_bytes())?;
    read(home)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A per-test home directory; tests never touch the developer's own `~/.m2`.
    struct TemporaryHome(PathBuf);

    impl TemporaryHome {
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TemporaryHome {
        fn drop(&mut self) {
            if let Err(error) = fs::remove_dir_all(&self.0) {
                eprintln!("Could not remove Maven settings test directory: {error}");
            }
        }
    }

    fn home() -> TemporaryHome {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "lithe-maven-user-settings-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).expect("temporary home");
        TemporaryHome(path)
    }

    #[test]
    fn a_missing_file_reports_maven_defaults_without_creating_anything() {
        let home = home();
        let settings = read(home.path()).expect("read");
        assert_eq!(settings.status, MavenUserSettingsStatus::Missing);
        assert_eq!(settings.local_repository, None);
        assert_eq!(settings.revision, None);
        assert!(settings.default_local_repository.ends_with("repository"));
        assert!(!home.path().join(".m2").exists());
    }

    #[test]
    fn the_first_write_creates_a_settings_document() {
        let home = home();
        let written = write_local_repository(
            home.path(),
            WriteMavenUserLocalRepositoryArgs {
                local_repository: " D:/maven/repository ".into(),
                expected_revision: None,
            },
        )
        .expect("write");
        assert_eq!(written.status, MavenUserSettingsStatus::Readable);
        assert_eq!(
            written.local_repository.as_deref(),
            Some("D:/maven/repository")
        );
        assert!(written.revision.is_some());
    }

    #[test]
    fn a_write_changes_only_the_repository_and_keeps_secrets_on_disk() {
        let home = home();
        let path = settings_path(home.path());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let original = "\u{feff}<settings>\n  <!-- team mirror -->\n  <localRepository>${user.home}/.m2/old</localRepository>\n  <servers><server><id>corp</id><password>fixture-secret</password></server></servers>\n</settings>\n";
        fs::write(&path, original).unwrap();
        let read_back = read(home.path()).expect("read");
        assert_eq!(
            read_back.local_repository.as_deref(),
            Some("${user.home}/.m2/old")
        );

        let written = write_local_repository(
            home.path(),
            WriteMavenUserLocalRepositoryArgs {
                local_repository: "D:/R&D/repository".into(),
                expected_revision: read_back.revision,
            },
        )
        .expect("write");
        assert_eq!(
            written.local_repository.as_deref(),
            Some("D:/R&D/repository")
        );
        let contents = fs::read_to_string(&path).unwrap();
        assert!(contents.starts_with('\u{feff}'));
        assert!(contents.contains("<!-- team mirror -->"));
        assert!(contents.contains("<password>fixture-secret</password>"));
        assert!(contents.contains("<localRepository>D:/R&amp;D/repository</localRepository>"));
        // The read model never carries the rest of the document.
        assert!(!format!("{written:?}").contains("fixture-secret"));
    }

    #[test]
    fn a_stale_revision_is_refused_and_leaves_the_file_unchanged() {
        let home = home();
        let path = settings_path(home.path());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "<settings/>").unwrap();
        let stale = read(home.path()).expect("read").revision;
        fs::write(&path, "<settings><offline>true</offline></settings>").unwrap();

        let error = write_local_repository(
            home.path(),
            WriteMavenUserLocalRepositoryArgs {
                local_repository: "D:/repository".into(),
                expected_revision: stale,
            },
        )
        .expect_err("conflict");
        assert!(error.starts_with(CONFLICT_ERROR));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "<settings><offline>true</offline></settings>"
        );

        // A file created after the page read "missing" is a conflict too.
        let created = write_local_repository(
            home.path(),
            WriteMavenUserLocalRepositoryArgs {
                local_repository: "D:/repository".into(),
                expected_revision: None,
            },
        );
        assert!(created.unwrap_err().starts_with(CONFLICT_ERROR));
    }

    #[test]
    fn an_invalid_document_is_reported_and_not_rewritten() {
        let home = home();
        let path = settings_path(home.path());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "<settings><localRepository>D:/repo").unwrap();
        let settings = read(home.path()).expect("read");
        assert_eq!(settings.status, MavenUserSettingsStatus::Invalid);

        let result = write_local_repository(
            home.path(),
            WriteMavenUserLocalRepositoryArgs {
                local_repository: "D:/repository".into(),
                expected_revision: settings.revision,
            },
        );
        assert!(result.is_err());
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "<settings><localRepository>D:/repo"
        );
    }

    #[test]
    fn an_empty_repository_is_rejected() {
        let home = home();
        let result = write_local_repository(
            home.path(),
            WriteMavenUserLocalRepositoryArgs {
                local_repository: "  ".into(),
                expected_revision: None,
            },
        );
        assert_eq!(result.unwrap_err(), EMPTY_ERROR);
        assert!(!settings_path(home.path()).exists());
    }
}
