//! Deterministic shaping of the diagnostic bundle manifest shared by every host.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// One file a host has already redacted and staged for inclusion in a diagnostic bundle.
pub struct DiagnosticsFileEntry {
    /// Path relative to the bundle root, using `/` separators (e.g. `logs/lithe.log`).
    pub relative_path: String,
    /// Size in bytes of the staged, already-redacted file.
    pub size_bytes: u64,
    /// Short description shown to the user before they confirm the export (e.g. "Application log").
    pub description: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Environment facts a host gathers natively and passes in for the manifest; the
/// Core never reads the filesystem or process table itself.
pub struct DiagnosticsEnvironmentInfo {
    pub app_version: String,
    pub os_name: String,
    pub os_version: String,
    pub cpu_core_count: u32,
    pub memory_rss_bytes: u64,
    pub disk_free_bytes: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to shape one deterministic manifest from host-gathered facts.
pub struct BuildManifestRequest {
    pub environment: DiagnosticsEnvironmentInfo,
    pub files: Vec<DiagnosticsFileEntry>,
    /// Milliseconds since epoch when the export was requested, supplied by the
    /// host so the manifest is reproducible in tests without a system clock
    /// dependency in this deterministic core.
    pub generated_at_epoch_milliseconds: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministic manifest describing exactly what a diagnostic bundle contains.
pub struct DiagnosticsManifest {
    pub schema_version: u32,
    pub generated_at_epoch_milliseconds: i64,
    pub environment: DiagnosticsEnvironmentInfo,
    pub files: Vec<DiagnosticsFileEntry>,
}

const MANIFEST_SCHEMA_VERSION: u32 = 1;

/// Shapes a diagnostic bundle manifest from facts the host already gathered.
///
/// Files are sorted by relative path so the manifest (and therefore the
/// zip listing shown to the user before they confirm the export) is
/// deterministic across runs and across platforms.
pub fn build_manifest(request: BuildManifestRequest) -> DiagnosticsManifest {
    let mut files = request.files;
    files.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));

    DiagnosticsManifest {
        schema_version: MANIFEST_SCHEMA_VERSION,
        generated_at_epoch_milliseconds: request.generated_at_epoch_milliseconds,
        environment: request.environment,
        files,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_manifest, BuildManifestRequest, DiagnosticsEnvironmentInfo, DiagnosticsFileEntry,
    };

    fn environment() -> DiagnosticsEnvironmentInfo {
        DiagnosticsEnvironmentInfo {
            app_version: "1.2.3".to_owned(),
            os_name: "macOS".to_owned(),
            os_version: "15.0".to_owned(),
            cpu_core_count: 8,
            memory_rss_bytes: 123_456_789,
            disk_free_bytes: 987_654_321,
        }
    }

    #[test]
    fn sorts_files_by_relative_path_for_deterministic_output() {
        let manifest = build_manifest(BuildManifestRequest {
            environment: environment(),
            files: vec![
                DiagnosticsFileEntry {
                    relative_path: "logs/lithe.2.log".to_owned(),
                    size_bytes: 10,
                    description: "Rotated log".to_owned(),
                },
                DiagnosticsFileEntry {
                    relative_path: "environment.json".to_owned(),
                    size_bytes: 5,
                    description: "Environment snapshot".to_owned(),
                },
                DiagnosticsFileEntry {
                    relative_path: "logs/lithe.log".to_owned(),
                    size_bytes: 20,
                    description: "Current log".to_owned(),
                },
            ],
            generated_at_epoch_milliseconds: 1_700_000_000_000,
        });

        let paths: Vec<&str> = manifest
            .files
            .iter()
            .map(|f| f.relative_path.as_str())
            .collect();
        assert_eq!(
            paths,
            vec!["environment.json", "logs/lithe.2.log", "logs/lithe.log"]
        );
    }

    #[test]
    fn preserves_schema_version_and_environment() {
        let manifest = build_manifest(BuildManifestRequest {
            environment: environment(),
            files: Vec::new(),
            generated_at_epoch_milliseconds: 42,
        });

        assert_eq!(manifest.schema_version, 1);
        assert_eq!(manifest.generated_at_epoch_milliseconds, 42);
        assert_eq!(manifest.environment.app_version, "1.2.3");
    }
}
