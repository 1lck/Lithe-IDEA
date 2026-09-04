//! Windows persistence for Maven project and machine-local configuration.
//!
//! Portable selections stay below the workspace `.lithe` directory. Maven,
//! JDK, and settings paths are stored only in the application data directory.

use crate::run::atomic_write;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

const MAVEN_CONFIGURATION_VERSION: u32 = 1;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenPortableConfiguration {
    pub version: u32,
    #[serde(default)]
    pub selected_profiles: Vec<String>,
    #[serde(default)]
    pub custom_profiles: Vec<String>,
    #[serde(default)]
    pub skip_tests: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenLocalConfiguration {
    pub version: u32,
    #[serde(default)]
    pub settings_path: Option<String>,
    #[serde(default)]
    pub local_repository_path: Option<String>,
    #[serde(default)]
    pub maven_executable_path: Option<String>,
    #[serde(default)]
    pub java_home_path: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenStoredConfiguration {
    pub portable: Option<MavenPortableConfiguration>,
    pub local: Option<MavenLocalConfiguration>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteMavenConfigurationArgs {
    pub root: PathBuf,
    pub reactor_path: String,
    pub configuration: MavenStoredConfiguration,
}

#[tauri::command]
pub fn maven_load_configuration(
    app: AppHandle,
    root: PathBuf,
    reactor_path: String,
) -> Result<MavenStoredConfiguration, String> {
    let root = existing_directory(&root)?;
    let portable = read_optional::<MavenPortableConfiguration>(&portable_path(&root))?;
    let local = read_optional::<MavenLocalConfiguration>(&local_path(&app, &root, &reactor_path)?)?;
    validate_versions(portable.as_ref(), local.as_ref())?;
    Ok(MavenStoredConfiguration { portable, local })
}

#[tauri::command]
pub fn maven_write_configuration(
    app: AppHandle,
    args: WriteMavenConfigurationArgs,
) -> Result<(), String> {
    let root = existing_directory(&args.root)?;
    validate_versions(
        args.configuration.portable.as_ref(),
        args.configuration.local.as_ref(),
    )?;
    write_optional(&portable_path(&root), args.configuration.portable.as_ref())?;
    write_optional(
        &local_path(&app, &root, &args.reactor_path)?,
        args.configuration.local.as_ref(),
    )
}

fn validate_versions(
    portable: Option<&MavenPortableConfiguration>,
    local: Option<&MavenLocalConfiguration>,
) -> Result<(), String> {
    if portable.is_some_and(|value| value.version != MAVEN_CONFIGURATION_VERSION)
        || local.is_some_and(|value| value.version != MAVEN_CONFIGURATION_VERSION)
    {
        return Err(
            "The Maven configuration was created by an unsupported version of Lithe.".into(),
        );
    }
    Ok(())
}

fn portable_path(root: &Path) -> PathBuf {
    root.join(".lithe").join("maven").join("config.json")
}

fn local_path(app: &AppHandle, root: &Path, reactor_path: &str) -> Result<PathBuf, String> {
    let app_data = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?;
    let mut digest = Sha256::new();
    let identity = storage_identity(&root.to_string_lossy(), reactor_path);
    digest.update(identity.as_bytes());
    Ok(app_data
        .join("maven")
        .join(format!("{:x}.json", digest.finalize())))
}

fn storage_identity(workspace_path: &str, reactor_path: &str) -> String {
    format!(
        "{}\0{}",
        workspace_path.to_lowercase(),
        reactor_path.replace('\\', "/")
    )
}

fn existing_directory(path: &Path) -> Result<PathBuf, String> {
    let root = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    if !root.is_dir() {
        return Err("The project directory is unavailable.".into());
    }
    Ok(root)
}

fn read_optional<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
    if !path.is_file() {
        return Ok(None);
    }
    let contents = fs::read(path).map_err(|_| {
        format!(
            "Unable to read Maven configuration {}.",
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("file")
        )
    })?;
    serde_json::from_slice(&contents).map(Some).map_err(|_| {
        format!(
            "The Maven configuration in {} is invalid.",
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("file")
        )
    })
}

fn write_optional<T: Serialize>(path: &Path, value: Option<&T>) -> Result<(), String> {
    let Some(value) = value else {
        if path.is_file() {
            fs::remove_file(path).map_err(|error| error.to_string())?;
        }
        return Ok(());
    };
    let parent = path
        .parent()
        .ok_or_else(|| "Maven configuration path has no parent directory.".to_string())?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let mut contents = serde_json::to_string_pretty(value).map_err(|error| error.to_string())?;
    contents.push('\n');
    atomic_write(path, contents.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_directory() -> PathBuf {
        static NEXT_DIRECTORY_ID: AtomicU64 = AtomicU64::new(1);
        let id = NEXT_DIRECTORY_ID.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("lithe-maven-config-{}-{id}", std::process::id()));
        fs::create_dir_all(&path).expect("temp directory");
        path
    }

    #[test]
    fn portable_configuration_round_trips_without_local_paths() {
        let root = temp_directory();
        let path = portable_path(&root);
        let portable = MavenPortableConfiguration {
            version: 1,
            selected_profiles: vec!["dev".into(), "qa".into()],
            custom_profiles: vec!["qa".into()],
            skip_tests: true,
        };
        write_optional(&path, Some(&portable)).expect("write portable configuration");
        let loaded = read_optional::<MavenPortableConfiguration>(&path)
            .expect("read portable configuration")
            .expect("portable configuration");

        assert_eq!(loaded.selected_profiles, ["dev", "qa"]);
        assert!(loaded.skip_tests);
        let text = fs::read_to_string(&path).expect("portable text");
        assert!(!text.contains("settingsPath"));
        assert!(!text.contains("mavenExecutablePath"));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn rejects_unsupported_configuration_versions() {
        let portable = MavenPortableConfiguration {
            version: 2,
            selected_profiles: Vec::new(),
            custom_profiles: Vec::new(),
            skip_tests: false,
        };
        assert!(validate_versions(Some(&portable), None)
            .unwrap_err()
            .contains("unsupported version"));
    }

    #[test]
    fn windows_storage_identity_matches_shared_contract() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../shared/fixtures/maven/platform-contract-v1.json"
        )))
        .expect("Maven platform contract fixture");
        let cases = fixture["storageIdentityCases"]
            .as_array()
            .expect("storage identity cases");
        let windows_cases: Vec<_> = cases
            .iter()
            .filter(|item| item["platform"] == "windows")
            .collect();

        assert!(
            !windows_cases.is_empty(),
            "Windows fixture case is required"
        );
        for item in windows_cases {
            assert_eq!(
                storage_identity(
                    item["workspacePath"].as_str().expect("workspace path"),
                    item["reactorPath"].as_str().expect("reactor path"),
                ),
                item["expectedIdentity"]
                    .as_str()
                    .expect("expected identity")
            );
        }
    }
}
