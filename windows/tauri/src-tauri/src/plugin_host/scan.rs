//! Scans package directories and asks Core to validate every manifest.
//!
//! The host owns package bytes and install records; Core owns every manifest
//! semantic. A package Core rejects is quarantined with Core's stable
//! rejection code and never registered as a language owner. Validation runs
//! through the same `lithe_core::execute_json` envelope the frontend uses, so
//! the shared fixtures acceptance covers the real production path.

use super::store::{self, DiscoveredPackage};
pub(crate) use super::ScannedPackage;
use super::{CatalogEntry, CatalogLanguage, CatalogRejection};
use serde_json::{json, Value};
use tauri::AppHandle;

pub fn build_catalog(app: &AppHandle) -> Result<Vec<ScannedPackage>, String> {
    build_catalog_from(&store::bundled_root(app)?, &store::install_root(app)?)
}

/// Catalog builder over explicit roots so tests can exercise the full scan
/// without a running Tauri app.
pub fn build_catalog_from(
    bundled_root: &std::path::Path,
    install_root: &std::path::Path,
) -> Result<Vec<ScannedPackage>, String> {
    let mut discovered = store::discover_bundled_in(bundled_root)?;
    discovered.extend(store::discover_installed_in(install_root)?);
    Ok(discovered.into_iter().map(scan_package).collect())
}

fn scan_package(package: DiscoveredPackage) -> ScannedPackage {
    let fallback_id = package
        .root
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let manifest = match read_manifest(&package.root) {
        Ok(manifest) => manifest,
        Err(error) => {
            return quarantined(
                package,
                fallback_id,
                "0",
                catalog_rejection("plugin.manifest.invalid", error, None),
            );
        }
    };
    if let Some(problem) = package.record_problem.clone() {
        return quarantined(
            package,
            manifest_id(&manifest).unwrap_or(fallback_id),
            &manifest_version(&manifest).unwrap_or_default(),
            catalog_rejection("plugin.store.installationRecordInvalid", problem, None),
        );
    }
    match validate_manifest(&manifest) {
        Ok(plugin) => {
            let entry = CatalogEntry {
                plugin_id: plugin["id"].as_str().unwrap_or(&fallback_id).to_string(),
                display_name: plugin["displayName"]
                    .as_str()
                    .unwrap_or("plugin")
                    .to_string(),
                version: plugin["version"].as_str().unwrap_or("0").to_string(),
                api_version: plugin["pluginAPIVersion"].as_u64().unwrap_or(0) as u32,
                source: package.source,
                enabled: package.enabled,
                status: "accepted",
                languages: catalog_languages(&plugin),
                declared_settings: plugin["settings"].as_array().cloned().unwrap_or_default(),
                declares_tests: plugin["executionProviders"]
                    .as_array()
                    .is_some_and(|providers| {
                        providers
                            .iter()
                            .any(|provider| provider.get("test").is_some())
                    }),
                primary_language_id: plugin["languageServers"]
                    .as_array()
                    .and_then(|servers| servers.first())
                    .and_then(|server| server["languageID"].as_str())
                    .map(str::to_string),
                rejection: None,
            };
            ScannedPackage {
                entry,
                root: package.root,
                manifest,
            }
        }
        Err(rejection) => quarantined(
            package,
            manifest_id(&manifest).unwrap_or(fallback_id),
            &manifest_version(&manifest).unwrap_or_default(),
            rejection,
        ),
    }
}

fn quarantined(
    package: DiscoveredPackage,
    plugin_id: String,
    version: &str,
    rejection: CatalogRejection,
) -> ScannedPackage {
    ScannedPackage {
        entry: CatalogEntry {
            plugin_id,
            display_name: plugin_id_display(&package.root),
            version: version.to_string(),
            api_version: 0,
            source: package.source,
            enabled: false,
            status: "rejected",
            languages: Vec::new(),
            declared_settings: Vec::new(),
            declares_tests: false,
            primary_language_id: None,
            rejection: Some(rejection),
        },
        root: package.root,
        manifest: Value::Null,
    }
}

fn plugin_id_display(root: &std::path::Path) -> String {
    root.file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

fn catalog_rejection(code: &str, message: String, path: Option<String>) -> CatalogRejection {
    CatalogRejection {
        code: code.to_string(),
        message,
        path,
    }
}

fn manifest_id(manifest: &Value) -> Option<String> {
    manifest["id"].as_str().map(|id| id.to_string())
}

fn manifest_version(manifest: &Value) -> Option<String> {
    manifest["version"]
        .as_str()
        .map(|version| version.to_string())
}

fn catalog_languages(plugin: &Value) -> Vec<CatalogLanguage> {
    plugin["languages"]
        .as_array()
        .map(|languages| {
            languages
                .iter()
                .map(|language| CatalogLanguage {
                    id: language["id"].as_str().unwrap_or_default().to_string(),
                    display_name: language["displayName"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                    file_extensions: string_list(&language["fileExtensions"]),
                    file_names: string_list(&language["fileNames"]),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn string_list(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(|text| text.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

fn read_manifest(root: &std::path::Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(root.join("plugin.json"))
        .map_err(|error| format!("plugin.json could not be read: {error}"))?;
    serde_json::from_str(&text).map_err(|error| format!("plugin.json is not valid JSON: {error}"))
}

/// Executes one Core command through the shared JSON envelope. Command-level
/// outcomes (including manifest rejections) arrive as `ok: true` data with a
/// `status` field; only malformed requests or host bugs surface as `Err`.
pub(crate) fn core_execute(command: &str, payload: Value) -> Result<Value, String> {
    let request = json!({ "command": command, "payload": payload });
    let response_text = lithe_core::execute_json(&request.to_string());
    let response: Value = serde_json::from_str(&response_text)
        .map_err(|error| format!("{command} returned an unreadable response: {error}"))?;
    if response["ok"] == json!(true) {
        Ok(response["data"].clone())
    } else {
        Err(format!(
            "{command} failed: {}",
            response["error"]["message"]
                .as_str()
                .unwrap_or("unknown error")
        ))
    }
}

/// Validates one manifest with this host's capability declaration. `Ok`
/// carries Core's normalized manifest. `host: None` runs pure contract
/// validation, which is what the shared fixture acceptance asserts.
pub(crate) fn validate_manifest_with(
    manifest: &Value,
    host: Option<Value>,
) -> Result<Value, CatalogRejection> {
    let mut payload = json!({ "manifest": manifest });
    if let Some(host) = host {
        payload["hostCapabilities"] = host;
    }
    let outcome = core_execute("plugins.declarative.validate", payload)
        .map_err(|error| catalog_rejection("plugin.host.coreFailure", error, None))?;
    if outcome["status"] == json!("rejected") {
        return Err(CatalogRejection {
            code: outcome["error"]["code"]
                .as_str()
                .unwrap_or("plugin.manifest.invalid")
                .to_string(),
            message: outcome["error"]["message"]
                .as_str()
                .unwrap_or("rejected")
                .to_string(),
            path: outcome["error"]["field"]
                .as_str()
                .map(|field| field.to_string()),
        });
    }
    Ok(outcome["plugin"].clone())
}

/// Host-scoped validation used by the scan path.
pub(crate) fn validate_manifest(manifest: &Value) -> Result<Value, CatalogRejection> {
    validate_manifest_with(manifest, Some(super::host_capabilities()))
}

/// Test entry point for the per-package scan path.
#[cfg(test)]
pub(crate) fn scan_package_for_tests(package: super::store::DiscoveredPackage) -> ScannedPackage {
    scan_package(package)
}
