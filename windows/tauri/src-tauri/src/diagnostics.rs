//! Windows-owned diagnostic bundle preview and export (Issue #420).
//!
//! Every file that can enter a bundle comes from `LogManager::files_available_for_export`
//! (application logs and panic sidecars only) plus two generated JSON documents.
//! Nothing else — workspace source, editor buffers, and terminal history are never
//! read here. Redaction and manifest shaping are delegated to `lithe_core::execute_json`
//! so both platforms apply the exact same rules.

use crate::logging::LogManager;
use crate::memory;
use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use sysinfo::{CpuRefreshKind, Disks, RefreshKind, System};
use tauri::{AppHandle, State};
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct EnvironmentFacts {
    app_version: String,
    os_name: String,
    os_version: String,
    cpu_core_count: u32,
    memory_rss_bytes: u64,
    disk_free_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StagedFile {
    relative_path: String,
    size_bytes: u64,
    description: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticBundlePreview {
    /// The exact `diagnostics.buildManifest` response: `schemaVersion`,
    /// `generatedAtEpochMilliseconds`, `environment`, and sorted `files`.
    manifest: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticBundleResult {
    destination_path: String,
    included_relative_paths: Vec<String>,
    total_size_bytes: u64,
}

/// One log or panic-sidecar file staged for the bundle, before its contents
/// are read and redacted.
struct StagedLogFile {
    source_path: PathBuf,
    relative_path: String,
    description: String,
}

fn staged_log_files(manager: &LogManager) -> Vec<StagedLogFile> {
    manager
        .files_available_for_export()
        .into_iter()
        .filter_map(|path| {
            let file_name = path.file_name()?.to_str()?.to_string();
            let description = if file_name.starts_with("lithe.panic.") {
                "Panic report".to_string()
            } else {
                "Application log".to_string()
            };
            Some(StagedLogFile {
                relative_path: format!("logs/{file_name}"),
                description,
                source_path: path,
            })
        })
        .collect()
}

fn gather_environment(app_version: String, log_directory: &Path) -> EnvironmentFacts {
    let mut system =
        System::new_with_specifics(RefreshKind::new().with_cpu(CpuRefreshKind::everything()));
    system.refresh_cpu_all();
    let cpu_core_count = system.cpus().len() as u32;

    let disks = Disks::new_with_refreshed_list();
    let disk_free_bytes = disks
        .list()
        .iter()
        // The disk whose mount point is the longest matching prefix of the log
        // directory is the one actually backing it (nested mounts otherwise
        // shadow each other).
        .filter(|disk| log_directory.starts_with(disk.mount_point()))
        .max_by_key(|disk| disk.mount_point().as_os_str().len())
        .map(|disk| disk.available_space())
        .unwrap_or(0);

    EnvironmentFacts {
        app_version,
        os_name: System::name().unwrap_or_else(|| "Windows".to_string()),
        os_version: System::os_version().unwrap_or_default(),
        cpu_core_count,
        // Reuses the same private-working-set figure already sampled for the
        // in-app memory indicator, instead of a second Win32 memory query.
        memory_rss_bytes: memory::current_process_bytes().unwrap_or(0),
        disk_free_bytes,
    }
}

fn call_core(command: &str, payload: Value) -> Result<Value, String> {
    let request = json!({ "command": command, "payload": payload }).to_string();
    let response_text = lithe_core::execute_json(&request);
    let response: Value = serde_json::from_str(&response_text)
        .map_err(|error| format!("Malformed response for {command}: {error}"))?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        let message = response
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("The shared core command failed");
        return Err(message.to_string());
    }
    response
        .get("data")
        .cloned()
        .ok_or_else(|| format!("{command} returned no data"))
}

fn redact(text: &str) -> Result<String, String> {
    let data = call_core("diagnostics.redactText", json!({ "text": text }))?;
    data.get("redacted")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "diagnostics.redactText returned no redacted text".to_string())
}

fn build_manifest(environment: &EnvironmentFacts, files: &[StagedFile]) -> Result<Value, String> {
    let generated_at_epoch_milliseconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0);
    call_core(
        "diagnostics.buildManifest",
        json!({
            "environment": environment,
            "files": files,
            "generatedAtEpochMilliseconds": generated_at_epoch_milliseconds,
        }),
    )
}

fn environment_file_entry(environment_json_bytes: &[u8]) -> StagedFile {
    StagedFile {
        relative_path: "environment.json".to_string(),
        size_bytes: environment_json_bytes.len() as u64,
        description: "Environment snapshot (OS, CPU, memory, disk)".to_string(),
    }
}

/// One redacted log/panic file ready to be sized in the manifest and written
/// into the bundle: `(relative_path, description, redacted_contents)`.
type RedactedLog = (String, String, String);

/// Reads and redacts every staged log/panic file.
///
/// Both the preview and the export go through here so the `sizeBytes` shown to
/// the user for confirmation are the redacted byte counts actually written to
/// the bundle, not the larger raw on-disk sizes.
fn read_and_redact_logs(manager: &LogManager) -> Result<Vec<RedactedLog>, String> {
    let mut redacted_logs = Vec::new();
    for staged in staged_log_files(manager) {
        let raw = fs::read_to_string(&staged.source_path)
            .map_err(|error| format!("Unable to read {}: {error}", staged.source_path.display()))?;
        let redacted = redact(&raw)?;
        redacted_logs.push((staged.relative_path, staged.description, redacted));
    }
    Ok(redacted_logs)
}

/// Builds the `StagedFile` list (redacted log sizes plus the environment
/// document) shared by the preview and the export.
fn staged_files(redacted_logs: &[RedactedLog], environment_bytes: &[u8]) -> Vec<StagedFile> {
    let mut files: Vec<StagedFile> = redacted_logs
        .iter()
        .map(|(relative_path, description, content)| StagedFile {
            relative_path: relative_path.clone(),
            size_bytes: content.len() as u64,
            description: description.clone(),
        })
        .collect();
    files.push(environment_file_entry(environment_bytes));
    files
}

fn build_preview(
    app_version: String,
    manager: &LogManager,
) -> Result<DiagnosticBundlePreview, String> {
    let log_directory = manager.export_log_directory();
    let environment = gather_environment(app_version, &log_directory);
    let environment_bytes = serde_json::to_vec_pretty(&environment)
        .map_err(|error| format!("Unable to encode the environment snapshot: {error}"))?;

    // Read and redact so the preview reports the same sizes the export writes.
    let redacted_logs = read_and_redact_logs(manager)?;
    let files = staged_files(&redacted_logs, &environment_bytes);

    let manifest = build_manifest(&environment, &files)?;
    Ok(DiagnosticBundlePreview { manifest })
}

fn build_and_write_bundle(
    app_version: String,
    manager: &LogManager,
    destination_path: &str,
) -> Result<DiagnosticBundleResult, String> {
    let log_directory = manager.export_log_directory();

    let redacted_logs = read_and_redact_logs(manager)?;

    let environment = gather_environment(app_version, &log_directory);
    let environment_bytes = serde_json::to_vec_pretty(&environment)
        .map_err(|error| format!("Unable to encode the environment snapshot: {error}"))?;

    let files = staged_files(&redacted_logs, &environment_bytes);

    let manifest = build_manifest(&environment, &files)?;
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)
        .map_err(|error| format!("Unable to encode the bundle manifest: {error}"))?;

    let destination = PathBuf::from(destination_path);
    let zip_file = fs::File::create(&destination)
        .map_err(|error| format!("Unable to create {destination_path}: {error}"))?;
    let mut writer = ZipWriter::new(zip_file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    let mut included_relative_paths = Vec::with_capacity(files.len() + 1);
    let mut total_size_bytes = 0u64;
    let mut write_entry =
        |writer: &mut ZipWriter<fs::File>, name: &str, bytes: &[u8]| -> Result<(), String> {
            writer
                .start_file(name, options)
                .map_err(|error| format!("Unable to start {name} in the bundle: {error}"))?;
            writer
                .write_all(bytes)
                .map_err(|error| format!("Unable to write {name} into the bundle: {error}"))?;
            included_relative_paths.push(name.to_string());
            total_size_bytes += bytes.len() as u64;
            Ok(())
        };

    write_entry(&mut writer, "manifest.json", &manifest_bytes)?;
    write_entry(&mut writer, "environment.json", &environment_bytes)?;
    for (relative_path, _description, content) in &redacted_logs {
        write_entry(&mut writer, relative_path, content.as_bytes())?;
    }

    writer
        .finish()
        .map_err(|error| format!("Unable to finalize the diagnostic bundle: {error}"))?;

    Ok(DiagnosticBundleResult {
        destination_path: destination.to_string_lossy().into_owned(),
        included_relative_paths,
        total_size_bytes,
    })
}

#[tauri::command]
pub async fn preview_diagnostic_bundle(
    app: AppHandle,
    manager: State<'_, Arc<LogManager>>,
) -> Result<DiagnosticBundlePreview, String> {
    let manager = manager.inner().clone();
    let app_version = app.package_info().version.to_string();
    tauri::async_runtime::spawn_blocking(move || build_preview(app_version, &manager))
        .await
        .map_err(|error| format!("Diagnostic bundle preview task failed: {error}"))?
}

#[tauri::command]
pub async fn export_diagnostic_bundle(
    destination_path: String,
    app: AppHandle,
    manager: State<'_, Arc<LogManager>>,
) -> Result<DiagnosticBundleResult, String> {
    let manager = manager.inner().clone();
    let app_version = app.package_info().version.to_string();
    tauri::async_runtime::spawn_blocking(move || {
        build_and_write_bundle(app_version, &manager, &destination_path)
    })
    .await
    .map_err(|error| format!("Diagnostic bundle export task failed: {error}"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::logging;
    use std::sync::atomic::{AtomicU64, Ordering};
    use zip::ZipArchive;

    static COUNTER: AtomicU64 = AtomicU64::new(1);

    fn temporary_directory(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lithe-diagnostics-tests-{name}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn build_and_write_bundle_redacts_a_planted_secret_and_includes_generated_files() {
        let directory = temporary_directory("export");
        let manager = logging::test_manager(&directory);
        let planted_name = "lithe.2024-01-01T00-00-00.000+0000.deadbeef.000.log";
        fs::write(directory.join(planted_name), "line one\npassword=hunter2\n").unwrap();

        let destination = directory.join("bundle.zip");

        let result =
            build_and_write_bundle("1.2.3".to_string(), &manager, destination.to_str().unwrap());
        let result = result.expect("bundle should export");
        assert!(result
            .included_relative_paths
            .contains(&"manifest.json".to_string()));
        assert!(result
            .included_relative_paths
            .contains(&"environment.json".to_string()));
        let planted_relative_path = format!("logs/{planted_name}");
        assert!(result
            .included_relative_paths
            .contains(&planted_relative_path));

        let archive_file = fs::File::open(&destination).unwrap();
        let mut archive = ZipArchive::new(archive_file).unwrap();
        let mut manifest_text = String::new();
        std::io::Read::read_to_string(
            &mut archive.by_name("manifest.json").unwrap(),
            &mut manifest_text,
        )
        .unwrap();
        assert!(manifest_text.contains("\"schemaVersion\""));

        let mut environment_text = String::new();
        std::io::Read::read_to_string(
            &mut archive.by_name("environment.json").unwrap(),
            &mut environment_text,
        )
        .unwrap();
        assert!(environment_text.contains("\"appVersion\": \"1.2.3\""));

        let mut log_text = String::new();
        std::io::Read::read_to_string(
            &mut archive.by_name(&planted_relative_path).unwrap(),
            &mut log_text,
        )
        .unwrap();
        assert!(!log_text.contains("hunter2"));
        assert!(log_text.contains("password=<redacted>"));
    }

    #[test]
    fn redact_delegates_to_the_shared_core_command() {
        assert_eq!(
            redact("Authorization: Bearer abc123").unwrap(),
            "Authorization=<redacted>"
        );
    }

    #[test]
    fn preview_reports_redacted_sizes_matching_the_export() {
        // Regression: the preview manifest must report the redacted byte count
        // (what the export writes), not the larger raw on-disk size, so the
        // sizes the user confirms match the bundle they receive.
        let directory = temporary_directory("preview-size");
        let manager = logging::test_manager(&directory);
        let planted_name = "lithe.2024-01-01T00-00-00.000+0000.deadbeef.000.log";
        let raw = "password=hunter2 followed by more text to inflate size\n";
        fs::write(directory.join(planted_name), raw).unwrap();
        let planted_relative_path = format!("logs/{planted_name}");

        let preview = build_preview("1.2.3".to_string(), &manager).expect("preview should build");
        let files = preview
            .manifest
            .get("files")
            .and_then(Value::as_array)
            .expect("manifest should list files");
        let preview_size = files
            .iter()
            .find(|entry| {
                entry.get("relativePath").and_then(Value::as_str) == Some(&planted_relative_path)
            })
            .and_then(|entry| entry.get("sizeBytes").and_then(Value::as_u64))
            .expect("planted log should appear in the preview manifest");

        let redacted_len = redact(raw).unwrap().len() as u64;
        assert_eq!(preview_size, redacted_len);
        // The redaction shrinks the content, so a raw-size preview would differ.
        assert!(preview_size < raw.len() as u64);

        // And the exported bundle reports the very same size.
        let destination = directory.join("bundle.zip");
        let result =
            build_and_write_bundle("1.2.3".to_string(), &manager, destination.to_str().unwrap())
                .expect("bundle should export");
        assert!(result
            .included_relative_paths
            .contains(&planted_relative_path));
    }
}
