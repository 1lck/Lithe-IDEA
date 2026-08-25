//! Deterministic Java workspace discovery and change classification shared by hosts.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

const JDT_CACHE_RETENTION_DAYS: u64 = 30;
const SECONDS_PER_DAY: u64 = 24 * 60 * 60;

const IGNORED_DIRECTORIES: &[&str] = &[
    ".git",
    ".gradle",
    ".idea",
    ".lithe",
    ".worktree",
    ".worktrees",
    "build",
    "dist",
    "node_modules",
    "out",
    "target",
    "vendor",
];

const BUILD_FILE_NAMES: &[&str] = &[
    "build.gradle",
    "build.gradle.kts",
    "gradle.properties",
    "gradlew",
    "gradlew.bat",
    "mvnw",
    "mvnw.cmd",
    "pom.xml",
    "settings.gradle",
    "settings.gradle.kts",
];

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Workspace-relative paths used to decide Java activation and refresh policy.
pub(crate) struct JavaWorkspacePolicyRequest {
    /// Current files discovered by the platform workspace adapter.
    #[serde(default)]
    pub workspace_paths: Vec<String>,
    /// Files added, changed, or removed since the previous observation.
    #[serde(default)]
    pub changed_paths: Vec<String>,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Shared Java workspace activation and change plan.
pub(crate) struct JavaWorkspacePolicyResponse {
    /// Whether at least one non-ignored Java source exists in the workspace.
    pub should_start: bool,
    /// Deterministically selected Java source used only to attach the session.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub representative_java_path: Option<String>,
    /// Deterministically ordered classifications for the supplied changes.
    pub changes: Vec<JavaWorkspaceChange>,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One normalized changed path and the action category it belongs to.
pub(crate) struct JavaWorkspaceChange {
    /// Normalized workspace-relative path with `/` separators.
    pub path: String,
    /// Shared semantic category consumed by platform workflow adapters.
    pub kind: JavaWorkspaceChangeKind,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Java workspace reaction required for one changed path.
pub(crate) enum JavaWorkspaceChangeKind {
    /// An ignored output, dependency, metadata, or linked-worktree path.
    Ignored,
    /// A Java document synchronized through versioned LSP document events.
    Source,
    /// Maven or Gradle structure that requires a debounced project refresh.
    BuildConfiguration,
    /// A workspace file that does not affect the Java project model.
    Other,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Filesystem metadata used to select expired JDT LS workspace directories.
pub(crate) struct JdtCacheRetentionRequest {
    /// Unix timestamp supplied by the platform clock.
    pub now_unix_seconds: u64,
    /// Workspace key currently owned by a running session and never removable.
    #[serde(default)]
    pub active_workspace_key: Option<String>,
    /// Candidate directories discovered by the platform filesystem adapter.
    #[serde(default)]
    pub entries: Vec<JdtCacheEntry>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Modification metadata for one candidate JDT LS workspace directory.
pub(crate) struct JdtCacheEntry {
    /// SHA-256 workspace directory name produced by `lsp.jdtWorkspaceKey`.
    pub workspace_key: String,
    /// Last modification time reported by the host filesystem.
    pub last_modified_unix_seconds: u64,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ordered JDT LS directories that a platform may remove.
pub(crate) struct JdtCacheRetentionResponse {
    /// Stable product retention period exposed for diagnostics and tests.
    pub retention_days: u64,
    /// Valid inactive workspace keys older than the retention period.
    pub expired_workspace_keys: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Platform-observed inputs used to derive one portable JDT LS workspace fingerprint.
pub(crate) struct JdtWorkspaceFingerprintRequest {
    /// Root build descriptors observed without recursive filesystem traversal.
    #[serde(default)]
    pub build_files: Vec<JdtBuildFileObservation>,
    /// Names of direct child directories that contain a Maven descriptor.
    #[serde(default)]
    pub direct_maven_modules: Vec<String>,
    /// JDT LS version resolved by the platform package adapter.
    pub jdtls_version: String,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Filesystem metadata for one root-level Java build descriptor.
pub(crate) struct JdtBuildFileObservation {
    /// Workspace-relative build descriptor path with `/` separators.
    pub path: String,
    /// Last modification time expressed as Unix epoch milliseconds.
    pub modified_unix_milliseconds: u64,
    /// File size in bytes.
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable opaque fingerprint consumed by JDT LS workspace-key derivation.
pub(crate) struct JdtWorkspaceFingerprintResponse {
    /// Opaque deterministic value that platforms pass back without parsing.
    pub workspace_fingerprint: String,
}

/// Builds the cross-platform Java activation and change-classification plan.
pub(crate) fn java_workspace_policy(
    request: JavaWorkspacePolicyRequest,
) -> Result<JavaWorkspacePolicyResponse, CoreError> {
    let workspace_paths = normalize_paths(request.workspace_paths)?;
    let changed_paths = normalize_paths(request.changed_paths)?;
    let representative_java_path = workspace_paths
        .iter()
        .find(|path| !is_ignored(path) && is_java_source(path))
        .cloned();
    let changes = changed_paths
        .into_iter()
        .map(|path| JavaWorkspaceChange {
            kind: classify_change(&path),
            path,
        })
        .collect();

    Ok(JavaWorkspacePolicyResponse {
        should_start: representative_java_path.is_some(),
        representative_java_path,
        changes,
    })
}

/// Reduces platform filesystem observations to the shared JDT LS fingerprint format.
pub(crate) fn jdt_workspace_fingerprint(
    request: JdtWorkspaceFingerprintRequest,
) -> Result<JdtWorkspaceFingerprintResponse, CoreError> {
    let version = request.jdtls_version.trim();
    if version.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The JDT LS version must not be empty.",
        ));
    }

    let mut build_files = BTreeMap::new();
    for observation in request.build_files {
        let path = normalize_relative_path(&observation.path)?;
        build_files.insert(
            path,
            (
                observation.modified_unix_milliseconds,
                observation.size_bytes,
            ),
        );
    }
    let modules = request
        .direct_maven_modules
        .into_iter()
        .map(|module| normalize_module_name(&module))
        .collect::<Result<BTreeSet<_>, _>>()?;
    let build_files = build_files
        .into_iter()
        .map(|(path, (modified, size))| format!("{path}@{modified}:{size}"))
        .collect::<Vec<_>>()
        .join(",");
    let modules = modules.into_iter().collect::<Vec<_>>().join(",");

    Ok(JdtWorkspaceFingerprintResponse {
        workspace_fingerprint: format!("build={build_files}|modules={modules}|jdtls={version}"),
    })
}

/// Selects inactive JDT LS workspace caches older than the shared retention period.
pub(crate) fn jdt_cache_retention(
    request: JdtCacheRetentionRequest,
) -> Result<JdtCacheRetentionResponse, CoreError> {
    if let Some(active_key) = request.active_workspace_key.as_deref() {
        validate_workspace_key(active_key)?;
    }

    // Duplicate observations are reduced to the newest timestamp so a stale
    // filesystem event cannot delete a directory that was subsequently reused.
    let mut newest_by_key = BTreeMap::new();
    for entry in request.entries {
        if !is_workspace_key(&entry.workspace_key) {
            continue;
        }
        newest_by_key
            .entry(entry.workspace_key)
            .and_modify(|timestamp: &mut u64| {
                *timestamp = (*timestamp).max(entry.last_modified_unix_seconds)
            })
            .or_insert(entry.last_modified_unix_seconds);
    }
    let retention_seconds = JDT_CACHE_RETENTION_DAYS * SECONDS_PER_DAY;
    let expired_workspace_keys = newest_by_key
        .into_iter()
        .filter_map(|(workspace_key, last_modified)| {
            let is_active = request.active_workspace_key.as_deref() == Some(workspace_key.as_str());
            let age = request.now_unix_seconds.saturating_sub(last_modified);
            (!is_active && age > retention_seconds).then_some(workspace_key)
        })
        .collect();

    Ok(JdtCacheRetentionResponse {
        retention_days: JDT_CACHE_RETENTION_DAYS,
        expired_workspace_keys,
    })
}

fn validate_workspace_key(value: &str) -> Result<(), CoreError> {
    if is_workspace_key(value) {
        Ok(())
    } else {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The active JDT LS workspace key must be a lowercase SHA-256 value.",
        ))
    }
}

fn is_workspace_key(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn normalize_paths(paths: Vec<String>) -> Result<Vec<String>, CoreError> {
    paths
        .into_iter()
        .map(|path| normalize_relative_path(&path))
        .collect::<Result<BTreeSet<_>, _>>()
        .map(BTreeSet::into_iter)
        .map(Iterator::collect)
}

fn normalize_relative_path(path: &str) -> Result<String, CoreError> {
    let normalized = path.trim().replace('\\', "/");
    let normalized = normalized.trim_start_matches("./");
    let is_windows_absolute = normalized
        .as_bytes()
        .get(1)
        .is_some_and(|separator| *separator == b':');
    if normalized.is_empty()
        || normalized.starts_with('/')
        || is_windows_absolute
        || normalized
            .split('/')
            .any(|component| component.is_empty() || matches!(component, "." | ".."))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Java workspace paths must be workspace-relative.",
        )
        .with_details(path.to_string()));
    }
    Ok(normalized.to_string())
}

fn normalize_module_name(value: &str) -> Result<String, CoreError> {
    let normalized = value.trim();
    if normalized.is_empty() || normalized.contains(['/', '\\']) || matches!(normalized, "." | "..")
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Direct Maven module names must be single path components.",
        )
        .with_details(value.to_string()));
    }
    Ok(normalized.to_string())
}

fn classify_change(path: &str) -> JavaWorkspaceChangeKind {
    if is_ignored(path) {
        JavaWorkspaceChangeKind::Ignored
    } else if is_java_source(path) {
        JavaWorkspaceChangeKind::Source
    } else if is_build_configuration(path) {
        JavaWorkspaceChangeKind::BuildConfiguration
    } else {
        JavaWorkspaceChangeKind::Other
    }
}

fn is_ignored(path: &str) -> bool {
    path.split('/').any(|component| {
        let component = component.to_ascii_lowercase();
        IGNORED_DIRECTORIES.contains(&component.as_str())
    })
}

fn is_java_source(path: &str) -> bool {
    path.rsplit_once('.')
        .is_some_and(|(_, extension)| extension.eq_ignore_ascii_case("java"))
}

fn is_build_configuration(path: &str) -> bool {
    let components: Vec<_> = path.split('/').collect();
    let file_name = components
        .last()
        .map(|component| component.to_ascii_lowercase())
        .unwrap_or_default();
    BUILD_FILE_NAMES.contains(&file_name.as_str())
        || components.iter().any(|component| {
            component.eq_ignore_ascii_case(".mvn") || component.eq_ignore_ascii_case("gradle")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_paths_that_escape_or_replace_the_workspace_root() {
        for path in ["../Main.java", "/tmp/Main.java", "C:/work/Main.java"] {
            let error = java_workspace_policy(JavaWorkspacePolicyRequest {
                workspace_paths: vec![path.to_string()],
                changed_paths: Vec::new(),
            })
            .expect_err("absolute and escaping paths must be rejected");
            assert!(matches!(error.code, ErrorCode::InvalidRequest));
        }
    }

    #[test]
    fn rejects_invalid_workspace_fingerprint_observations() {
        for request in [
            JdtWorkspaceFingerprintRequest {
                build_files: vec![JdtBuildFileObservation {
                    path: "../pom.xml".to_string(),
                    modified_unix_milliseconds: 1,
                    size_bytes: 1,
                }],
                direct_maven_modules: Vec::new(),
                jdtls_version: "1.38.0".to_string(),
            },
            JdtWorkspaceFingerprintRequest {
                build_files: Vec::new(),
                direct_maven_modules: vec!["nested/core".to_string()],
                jdtls_version: "1.38.0".to_string(),
            },
            JdtWorkspaceFingerprintRequest {
                build_files: Vec::new(),
                direct_maven_modules: Vec::new(),
                jdtls_version: "  ".to_string(),
            },
        ] {
            let error = jdt_workspace_fingerprint(request)
                .expect_err("invalid fingerprint observations must be rejected");
            assert!(matches!(error.code, ErrorCode::InvalidRequest));
        }
    }
}
