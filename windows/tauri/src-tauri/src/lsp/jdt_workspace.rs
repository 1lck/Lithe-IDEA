//! Windows filesystem ownership for JDT LS workspace fingerprints and cache directories.

use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::BTreeSet;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Root build declarations whose presence feeds the Java workspace fingerprint.
///
/// Only presence counts: JDT LS compares each POM and Gradle script's timestamp
/// with the state it saved and updates the changed projects itself, so an edit
/// keeps the imported workspace. The wrapper descriptor is listed because
/// Buildship reads it, and its Gradle version is observed separately (see
/// [`gradle_wrapper_distribution`]). `gradle.properties` is deliberately not
/// observed: mod projects add and remove it freely.
const GRADLE_WRAPPER_DESCRIPTOR: &str = "gradle/wrapper/gradle-wrapper.properties";
const WORKSPACE_BUILD_FILES: &[&str] = &[
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    GRADLE_WRAPPER_DESCRIPTOR,
];
pub(super) const JDT_CACHE_LAST_USED_MARKER: &str = ".lithe-last-used";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JdtBuildFileObservation {
    pub(super) path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct JdtWorkspaceFingerprintInputs {
    pub(super) build_files: Vec<JdtBuildFileObservation>,
    pub(super) direct_maven_modules: Vec<String>,
    /// The wrapper's `distributionUrl`; JDT LS does not notice a Gradle version
    /// change on its own, so the version selects a fresh state directory.
    pub(super) gradle_wrapper_distribution: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JdtWorkspaceFingerprintPlan {
    workspace_fingerprint: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct JdtCacheEntryMetadata {
    workspace_key: String,
    last_modified_unix_seconds: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JdtCacheRetentionPlan {
    retention_days: u64,
    expired_workspace_keys: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct JdtCacheCleanupResult {
    pub(super) retention_days: u64,
    pub(super) removed_workspace_keys: Vec<String>,
}

/// Observes root build files and direct Maven modules without recursive traversal.
pub(super) fn collect_workspace_fingerprint_inputs(
    workspace_root: &Path,
) -> Result<JdtWorkspaceFingerprintInputs, String> {
    fn build_file_observation(
        path: &Path,
        relative_path: &str,
    ) -> Result<Option<JdtBuildFileObservation>, String> {
        match std::fs::metadata(path) {
            Ok(_) => Ok(Some(JdtBuildFileObservation {
                path: relative_path.to_string(),
            })),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!(
                "Failed to inspect Java build file {}: {error}",
                path.display()
            )),
        }
    }

    let mut build_files = Vec::new();
    for name in WORKSPACE_BUILD_FILES {
        let path = workspace_root.join(name);
        if let Some(observation) = build_file_observation(&path, name)? {
            build_files.push(observation);
        }
    }

    let mut direct_maven_modules = Vec::new();
    let entries = std::fs::read_dir(workspace_root).map_err(|error| {
        format!(
            "Failed to list Java workspace {}: {error}",
            workspace_root.display()
        )
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "Failed to inspect an entry in Java workspace {}: {error}",
                workspace_root.display()
            )
        })?;
        let path = entry.path();
        let file_type = entry.file_type().map_err(|error| {
            format!(
                "Failed to inspect Java workspace entry {}: {error}",
                path.display()
            )
        })?;
        if !file_type.is_dir() {
            continue;
        }
        match std::fs::metadata(path.join("pom.xml")) {
            Ok(metadata) if metadata.is_file() => {}
            Ok(_) => continue,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(format!(
                    "Failed to inspect Maven module descriptor {}: {error}",
                    path.join("pom.xml").display()
                ))
            }
        }
        let name = entry.file_name().into_string().map_err(|_| {
            format!(
                "Java workspace module name is not valid UTF-8: {}",
                path.display()
            )
        })?;
        direct_maven_modules.push(name);
    }

    Ok(JdtWorkspaceFingerprintInputs {
        build_files,
        direct_maven_modules,
        gradle_wrapper_distribution: gradle_wrapper_distribution(workspace_root)?,
    })
}

/// The `distributionUrl` of the workspace's Gradle wrapper descriptor, if any.
///
/// The descriptor is a Java properties file, whose writer escapes `:` and `=`
/// in values (`https\://services.gradle.org/...`); escapes are removed so the
/// same version always reads the same.
pub(super) fn gradle_wrapper_distribution(workspace_root: &Path) -> Result<Option<String>, String> {
    let path = workspace_root.join(GRADLE_WRAPPER_DESCRIPTOR);
    let contents = match std::fs::read_to_string(&path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "Failed to read Gradle wrapper descriptor {}: {error}",
                path.display()
            ))
        }
    };
    for line in contents.lines() {
        let line = line.trim_start();
        if line.starts_with('#') || line.starts_with('!') {
            continue;
        }
        let Some(value) = line
            .strip_prefix("distributionUrl")
            .map(str::trim_start)
            .and_then(|rest| rest.strip_prefix(['=', ':']))
        else {
            continue;
        };
        let mut unescaped = String::with_capacity(value.len());
        let mut characters = value.trim().chars();
        while let Some(character) = characters.next() {
            if character == '\\' {
                unescaped.extend(characters.next());
            } else {
                unescaped.push(character);
            }
        }
        return Ok(Some(unescaped).filter(|value| !value.is_empty()));
    }
    Ok(None)
}

/// Delegates portable ordering and serialization of observations to Rust Core.
pub(super) fn resolve_workspace_fingerprint(
    inputs: JdtWorkspaceFingerprintInputs,
    jdtls_version: &str,
    operation_id: &str,
) -> Result<String, String> {
    let request = json!({
        "id": operation_id,
        "operationId": operation_id,
        "command": "java.jdtWorkspaceFingerprint",
        "payload": {
            "buildFiles": inputs.build_files,
            "directMavenModules": inputs.direct_maven_modules,
            "gradleWrapperDistribution": inputs.gradle_wrapper_distribution,
            "jdtlsVersion": jdtls_version,
        }
    });
    let response = lithe_core::execute_json(&request.to_string());
    let envelope: serde_json::Value = serde_json::from_str(&response).map_err(|error| {
        format!("Rust Core returned invalid workspace-fingerprint JSON: {error}")
    })?;
    if envelope.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
        let message = envelope
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Rust Core workspace-fingerprint resolution failed");
        return Err(message.to_string());
    }
    let plan: JdtWorkspaceFingerprintPlan = serde_json::from_value(
        envelope.get("data").cloned().unwrap_or_default(),
    )
    .map_err(|error| format!("Rust Core returned an invalid workspace fingerprint: {error}"))?;
    Ok(plan.workspace_fingerprint)
}

/// Enumerates JDT LS state, delegates expiry selection to Core, and removes validated targets.
pub(super) fn cleanup_expired_java_index_directories(
    cache_directory: &Path,
    active_workspace_key: &str,
    now_unix_seconds: u64,
    operation_id: &str,
) -> Result<JdtCacheCleanupResult, String> {
    if !is_workspace_key(active_workspace_key) {
        return Err("Rust Core returned an invalid active JDTLS workspace key.".to_string());
    }
    let jdtls_cache = cache_directory.join("jdtls");
    let directory_entries = match std::fs::read_dir(&jdtls_cache) {
        Ok(entries) => Some(entries),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(format!(
                "Failed to enumerate JDTLS cache directory {}: {error}",
                jdtls_cache.display()
            ))
        }
    };

    let mut observed_keys = BTreeSet::new();
    let mut entries = Vec::new();
    if let Some(directory_entries) = directory_entries {
        for entry in directory_entries {
            let entry = entry.map_err(|error| {
                format!(
                    "Failed to inspect an entry in {}: {error}",
                    jdtls_cache.display()
                )
            })?;
            let path = entry.path();
            let metadata = std::fs::symlink_metadata(&path)
                .map_err(|error| format!("Failed to inspect {}: {error}", path.display()))?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                continue;
            }
            let Some(workspace_key) = entry.file_name().to_str().map(str::to_string) else {
                continue;
            };
            if !is_workspace_key(&workspace_key) {
                continue;
            }

            let modified = if workspace_key == active_workspace_key {
                std::fs::write(
                    path.join(JDT_CACHE_LAST_USED_MARKER),
                    now_unix_seconds.to_string(),
                )
                .map_err(|error| {
                    format!(
                        "Failed to mark JDTLS cache {} as active: {error}",
                        path.display()
                    )
                })?;
                now_unix_seconds
            } else {
                let directory_modified =
                    system_time_unix_seconds(metadata.modified().map_err(|error| {
                        format!("Failed to read {} timestamp: {error}", path.display())
                    })?)?;
                let marker_modified = match std::fs::metadata(path.join(JDT_CACHE_LAST_USED_MARKER))
                {
                    Ok(marker) => Some(system_time_unix_seconds(marker.modified().map_err(
                        |error| {
                            format!(
                                "Failed to read {} marker timestamp: {error}",
                                path.display()
                            )
                        },
                    )?)?),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                    Err(error) => {
                        return Err(format!(
                            "Failed to inspect {} last-used marker: {error}",
                            path.display()
                        ))
                    }
                };
                marker_modified
                    .map(|value| value.max(directory_modified))
                    .unwrap_or(directory_modified)
            };
            observed_keys.insert(workspace_key.clone());
            entries.push(JdtCacheEntryMetadata {
                workspace_key,
                last_modified_unix_seconds: modified,
            });
        }
    }

    let plan = plan_jdt_cache_retention(
        now_unix_seconds,
        active_workspace_key,
        &entries,
        operation_id,
    )?;
    let mut removed_workspace_keys = Vec::new();
    for workspace_key in plan.expired_workspace_keys {
        if workspace_key == active_workspace_key
            || !is_workspace_key(&workspace_key)
            || !observed_keys.contains(&workspace_key)
        {
            return Err("Rust Core returned an unobserved JDTLS retention target.".to_string());
        }
        let target = jdtls_cache.join(&workspace_key);
        let metadata = std::fs::symlink_metadata(&target)
            .map_err(|error| format!("Failed to revalidate {}: {error}", target.display()))?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(format!(
                "JDTLS retention target is not a removable directory: {}",
                target.display()
            ));
        }
        std::fs::remove_dir_all(&target).map_err(|error| {
            format!(
                "Failed to remove expired JDTLS cache {}: {error}",
                target.display()
            )
        })?;
        removed_workspace_keys.push(workspace_key);
    }
    Ok(JdtCacheCleanupResult {
        retention_days: plan.retention_days,
        removed_workspace_keys,
    })
}

fn plan_jdt_cache_retention(
    now_unix_seconds: u64,
    active_workspace_key: &str,
    entries: &[JdtCacheEntryMetadata],
    operation_id: &str,
) -> Result<JdtCacheRetentionPlan, String> {
    let request = json!({
        "id": operation_id,
        "operationId": operation_id,
        "command": "java.jdtCacheRetention",
        "payload": {
            "nowUnixSeconds": now_unix_seconds,
            "activeWorkspaceKey": active_workspace_key,
            "entries": entries,
        }
    });
    let response = lithe_core::execute_json(&request.to_string());
    let envelope: serde_json::Value = serde_json::from_str(&response)
        .map_err(|error| format!("Rust Core returned invalid cache-retention JSON: {error}"))?;
    if envelope.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
        let message = envelope
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Rust Core cache-retention planning failed");
        return Err(message.to_string());
    }
    serde_json::from_value(envelope.get("data").cloned().unwrap_or_default())
        .map_err(|error| format!("Rust Core returned an invalid cache-retention plan: {error}"))
}

fn is_workspace_key(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn now_unix_seconds() -> Result<u64, String> {
    system_time_unix_seconds(SystemTime::now())
}

fn system_time_unix_seconds(value: SystemTime) -> Result<u64, String> {
    value
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|error| format!("System clock is before the Unix epoch: {error}"))
}

/// Deletes only the workspace/fingerprint cache directory selected by Core.
pub(super) fn clear_java_index_directory(
    cache_directory: &Path,
    workspace_root: &Path,
    workspace_fingerprint: Option<&str>,
) -> Result<(), String> {
    let workspace_key = lithe_core::jdt_workspace_key(workspace_root, workspace_fingerprint);
    let target = cache_directory.join("jdtls").join(workspace_key);
    match std::fs::symlink_metadata(&target) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
            std::fs::remove_dir_all(&target).map_err(|error| {
                format!(
                    "Failed to remove JDTLS index at {}: {error}",
                    target.display()
                )
            })?;
        }
        Ok(_) => {
            return Err(format!(
                "JDTLS index target is not a removable directory: {}",
                target.display()
            ))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "Failed to inspect JDTLS index at {}: {error}",
                target.display()
            ))
        }
    }
    Ok(())
}
