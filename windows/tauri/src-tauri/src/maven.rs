//! Windows persistence for Maven project and machine-local configuration.
//!
//! Portable selections stay below the workspace `.lithe` directory. Maven,
//! JDK, and settings paths are stored only in the application data directory.

use crate::run::{atomic_write, resolve_java_home, resolve_maven_executable};
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

/// Arguments for resolving the configuration a Maven launch would use. Every
/// value mirrors one of the machine-local fields; empty means "detect it".
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveEffectiveConfigurationArgs {
    pub root: PathBuf,
    /// Reactor path relative to the workspace root; empty means the root itself.
    #[serde(default)]
    pub working_directory: String,
    #[serde(default)]
    pub settings_path: String,
    #[serde(default)]
    pub local_repository_path: String,
    #[serde(default)]
    pub maven_executable_path: String,
    #[serde(default)]
    pub java_home_path: String,
}

/// The values a Maven launch would actually use, alongside the values detection
/// found when every saved override is ignored. `None` means detection found
/// nothing for that field.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenEffectiveConfiguration {
    pub settings_path: Option<String>,
    pub local_repository_path: Option<String>,
    pub maven_executable_path: Option<String>,
    pub java_home_path: Option<String>,
    pub detected_settings_path: Option<String>,
    pub detected_local_repository_path: Option<String>,
    pub detected_maven_executable_path: Option<String>,
    pub detected_java_home_path: Option<String>,
}

/// Resolves the effective Maven configuration for the saved settings, so the
/// configuration surfaces can show what their empty fields resolve to.
///
/// The Maven executable and JDK come from the same resolution the launch path
/// uses, which keeps the reported values identical to the launched ones.
#[tauri::command]
pub fn maven_resolve_effective_configuration(
    args: ResolveEffectiveConfigurationArgs,
) -> Result<MavenEffectiveConfiguration, String> {
    let root = existing_directory(&args.root)?;
    let working_directory = match args.working_directory.trim() {
        "" => root.clone(),
        reactor => root.join(reactor),
    };
    // Detection is resolved once with empty overrides. A saved path is resolved
    // only when the user set one, so the automatic case does not probe twice.
    let detected_maven = resolve_maven_executable(&root, &working_directory, "").ok();
    let detected_java = resolve_java_home(&root, "").ok().flatten();
    let selected_maven = if args.maven_executable_path.trim().is_empty() {
        detected_maven.clone()
    } else {
        resolve_maven_executable(&root, &working_directory, &args.maven_executable_path).ok()
    };
    let selected_java = if args.java_home_path.trim().is_empty() {
        detected_java.clone()
    } else {
        resolve_java_home(&root, &args.java_home_path).ok().flatten()
    };
    Ok(assemble_effective_configuration(
        &args.settings_path,
        &args.local_repository_path,
        &args.maven_executable_path,
        &args.java_home_path,
        detected_maven,
        detected_java,
        selected_maven,
        selected_java,
        user_home_directory().as_deref(),
    ))
}

/// Combines saved overrides with already resolved executables.
///
/// `detected_*` arguments are what the machine finds with every override blank.
/// `selected_*` arguments are the executables a launch would use, which equal
/// the detected ones when the corresponding override is blank.
fn assemble_effective_configuration(
    configured_settings: &str,
    configured_repository: &str,
    configured_maven: &str,
    configured_java: &str,
    detected_maven: Option<String>,
    detected_java: Option<String>,
    selected_maven: Option<String>,
    selected_java: Option<String>,
    home: Option<&Path>,
) -> MavenEffectiveConfiguration {
    let maven_executable_path = if configured_maven.trim().is_empty() {
        detected_maven.clone()
    } else {
        selected_maven
    };
    let java_home_path = if configured_java.trim().is_empty() {
        detected_java.clone()
    } else {
        selected_java
    };
    let detected_settings_path = effective_settings_path("", home, detected_maven.as_deref());
    let settings_path = effective_settings_path(
        configured_settings,
        home,
        maven_executable_path.as_deref(),
    );
    let detected_local_repository_path =
        effective_local_repository_path("", detected_settings_path.as_deref(), home);
    let local_repository_path = effective_local_repository_path(
        configured_repository,
        settings_path.as_deref(),
        home,
    );
    MavenEffectiveConfiguration {
        settings_path,
        local_repository_path,
        maven_executable_path,
        java_home_path,
        detected_settings_path,
        detected_local_repository_path,
        detected_maven_executable_path: detected_maven,
        detected_java_home_path: detected_java,
    }
}

/// The current user's home directory, which owns the Maven user-level defaults
/// (`~/.m2/settings.xml` and `~/.m2/repository`).
fn user_home_directory() -> Option<PathBuf> {
    std::env::var("USERPROFILE")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// The settings file Maven itself would read: the configured path, then the
/// user-level default, then the detected installation's global settings.
///
/// A configured path is reported even when the file is missing, because that is
/// what the launch would ask for and the surface must not hide the user's input.
fn effective_settings_path(
    configured: &str,
    home: Option<&Path>,
    maven_executable_path: Option<&str>,
) -> Option<String> {
    let configured = configured.trim();
    if !configured.is_empty() {
        return Some(configured.to_string());
    }
    let mut candidates = Vec::new();
    if let Some(home) = home {
        candidates.push(home.join(".m2").join("settings.xml"));
    }
    if let Some(executable) = maven_executable_path {
        // `<installation>/bin/mvn.cmd` -> `<installation>/conf/settings.xml`.
        if let Some(installation) = Path::new(executable).parent().and_then(Path::parent) {
            candidates.push(installation.join("conf").join("settings.xml"));
        }
    }
    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .map(|path| path.to_string_lossy().into_owned())
}

/// The local repository Maven would use: the configured path, then the
/// `<localRepository>` of the effective settings, then the `~/.m2/repository`
/// default.
fn effective_local_repository_path(
    configured: &str,
    settings_path: Option<&str>,
    home: Option<&Path>,
) -> Option<String> {
    let configured = configured.trim();
    if !configured.is_empty() {
        return Some(configured.to_string());
    }
    if let Some(settings_path) = settings_path {
        let contents = fs::read_to_string(settings_path).unwrap_or_default();
        if let Some(repository) = parse_local_repository(&contents) {
            return Some(repository);
        }
    }
    home.map(|home| {
        home.join(".m2")
            .join("repository")
            .to_string_lossy()
            .into_owned()
    })
}

/// Extracts the `<localRepository>` element of a Maven settings document.
///
/// Hand-parsed rather than regex-matched: the element is a single tag with no
/// nested markup, and a missing closing tag must stay undetected instead of
/// being reported as a repository path.
fn parse_local_repository(settings: &str) -> Option<String> {
    const OPENING_TAG: &str = "<localRepository>";
    const CLOSING_TAG: &str = "</localRepository>";
    let remainder = &settings[settings.find(OPENING_TAG)? + OPENING_TAG.len()..];
    let value = remainder
        .split_once(CLOSING_TAG)
        .map(|(value, _)| value)
        .unwrap_or(remainder)
        .trim();
    (!value.is_empty()).then(|| value.to_string())
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
    fn parses_the_local_repository_element() {
        let settings =
            "<settings>\n  <localRepository>D:\\repo\\maven</localRepository>\n</settings>";
        assert_eq!(
            parse_local_repository(settings).as_deref(),
            Some("D:\\repo\\maven")
        );
        // Surrounding whitespace is formatting, not part of the path.
        assert_eq!(
            parse_local_repository("<localRepository>\n  D:/repo  \n</localRepository>").as_deref(),
            Some("D:/repo")
        );
        // Empty and absent elements are undetected, and an unterminated element
        // must not turn the rest of the document into a repository path.
        assert_eq!(
            parse_local_repository("<localRepository>  </localRepository>"),
            None
        );
        assert_eq!(parse_local_repository("<settings></settings>"), None);
        assert_eq!(parse_local_repository("<settings/>"), None);
    }

    #[test]
    fn local_repository_prefers_configured_then_settings_then_default() {
        let home = temp_directory();
        let settings = home.join("user-settings.xml");
        fs::write(
            &settings,
            "<settings><localRepository>C:\\from-settings</localRepository></settings>",
        )
        .expect("write settings");
        let settings = settings.to_string_lossy();
        let home_default = home
            .join(".m2")
            .join("repository")
            .to_string_lossy()
            .into_owned();

        assert_eq!(
            effective_local_repository_path("D:\\custom", Some(&settings), Some(&home)).as_deref(),
            Some("D:\\custom")
        );
        assert_eq!(
            effective_local_repository_path("", Some(&settings), Some(&home)).as_deref(),
            Some("C:\\from-settings")
        );
        assert_eq!(
            effective_local_repository_path("", None, Some(&home)).as_deref(),
            Some(home_default.as_str())
        );
        // Without a home directory there is no default to fall back to.
        assert_eq!(effective_local_repository_path("", None, None), None);
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn settings_path_prefers_configured_then_user_then_installation() {
        let home = temp_directory();
        let installation = temp_directory();
        let configured = home.join("configured.xml");
        fs::write(&configured, "<settings/>").expect("write configured settings");
        let executable = installation
            .join("bin")
            .join("mvn.cmd")
            .to_string_lossy()
            .into_owned();
        let user_settings = home.join(".m2").join("settings.xml");
        let global_settings = installation.join("conf").join("settings.xml");
        fs::create_dir_all(installation.join("conf")).expect("conf directory");

        // The configured path wins even when the file does not exist yet: the
        // launch would fail on it, so the surface must keep showing it.
        assert_eq!(
            effective_settings_path(
                &configured.to_string_lossy(),
                Some(&home),
                Some(&executable)
            )
            .as_deref(),
            Some(configured.to_string_lossy().as_ref())
        );

        // Neither default exists yet.
        assert_eq!(
            effective_settings_path("", Some(&home), Some(&executable)),
            None
        );

        // The user-level file wins over the installation-level one.
        fs::create_dir_all(home.join(".m2")).expect("user m2");
        fs::write(&user_settings, "<settings/>").expect("write user settings");
        fs::write(&global_settings, "<settings/>").expect("write global settings");
        assert_eq!(
            effective_settings_path("", Some(&home), Some(&executable)).as_deref(),
            Some(user_settings.to_string_lossy().as_ref())
        );

        // Removing the user-level file falls back to the installation.
        fs::remove_file(&user_settings).expect("remove user settings");
        assert_eq!(
            effective_settings_path("", Some(&home), Some(&executable)).as_deref(),
            Some(global_settings.to_string_lossy().as_ref())
        );

        fs::remove_dir_all(home).ok();
        fs::remove_dir_all(installation).ok();
    }

    #[test]
    fn detected_paths_stay_visible_when_overrides_are_configured() {
        let home = temp_directory();
        fs::create_dir_all(home.join(".m2")).expect("user m2");
        let user_settings = home.join(".m2").join("settings.xml");
        fs::write(
            &user_settings,
            "<settings><localRepository>C:\\from-settings</localRepository></settings>",
        )
        .expect("write user settings");

        let resolved = assemble_effective_configuration(
            "D:\\custom-settings.xml",
            "D:\\custom-repo",
            "D:\\custom-maven",
            "D:\\custom-jdk",
            Some("D:\\detected\\mvn.cmd".into()),
            Some("D:\\detected-jdk".into()),
            Some("D:\\custom-maven\\bin\\mvn.cmd".into()),
            Some("D:\\custom-jdk".into()),
            Some(&home),
        );

        assert_eq!(
            resolved.maven_executable_path.as_deref(),
            Some("D:\\custom-maven\\bin\\mvn.cmd")
        );
        assert_eq!(
            resolved.detected_maven_executable_path.as_deref(),
            Some("D:\\detected\\mvn.cmd")
        );
        assert_eq!(resolved.java_home_path.as_deref(), Some("D:\\custom-jdk"));
        assert_eq!(
            resolved.detected_java_home_path.as_deref(),
            Some("D:\\detected-jdk")
        );
        assert_eq!(
            resolved.settings_path.as_deref(),
            Some("D:\\custom-settings.xml")
        );
        assert_eq!(
            resolved.detected_settings_path.as_deref(),
            Some(user_settings.to_string_lossy().as_ref())
        );
        assert_eq!(
            resolved.local_repository_path.as_deref(),
            Some("D:\\custom-repo")
        );
        assert_eq!(
            resolved.detected_local_repository_path.as_deref(),
            Some("C:\\from-settings")
        );
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn blank_configuration_uses_the_detected_values() {
        let home = temp_directory();
        let resolved = assemble_effective_configuration(
            "",
            "",
            "",
            "",
            Some("D:\\detected\\mvn.cmd".into()),
            None,
            Some("D:\\detected\\mvn.cmd".into()),
            None,
            Some(&home),
        );
        let repository = home.join(".m2").join("repository");

        assert_eq!(
            resolved.maven_executable_path.as_deref(),
            Some("D:\\detected\\mvn.cmd")
        );
        assert_eq!(
            resolved.detected_maven_executable_path.as_deref(),
            Some("D:\\detected\\mvn.cmd")
        );
        assert_eq!(resolved.java_home_path, None);
        assert_eq!(resolved.detected_java_home_path, None);
        assert_eq!(
            resolved.local_repository_path.as_deref(),
            Some(repository.to_string_lossy().as_ref())
        );
        assert_eq!(
            resolved.detected_local_repository_path,
            resolved.local_repository_path
        );
        fs::remove_dir_all(home).ok();
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
