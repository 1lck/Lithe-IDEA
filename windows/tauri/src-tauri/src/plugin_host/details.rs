//! Read-only detail model for packages already discovered by the plugin host.
//!
//! Callers identify a cached package by plugin ID and catalog source; they
//! never submit a filesystem path. Every live package read holds the same
//! lifecycle lease used by launch probes, stays inside the owning package
//! root, and re-verifies the bytes before reporting trust or provenance.

use super::signature::{self, InstallOrigin};
use super::store::{self, InstallationRecord};
use super::{CatalogRejection, PluginHostState, ScannedPackage};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

/// Stable frontend-facing failure from the detail read boundary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginDetailsError {
    pub code: String,
    pub message: String,
}

impl PluginDetailsError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

/// Complete detail snapshot for one package identity.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginDetails {
    pub identity: PluginDetailsIdentity,
    pub display_name: String,
    pub vendor_name: Option<String>,
    pub description: Option<String>,
    pub localized_descriptions: BTreeMap<String, String>,
    pub api_version: u32,
    pub enabled: bool,
    pub status: &'static str,
    pub rejection: Option<CatalogRejection>,
    pub settings: Vec<Value>,
    pub primary_language_id: Option<String>,
    pub features: Vec<PluginFeature>,
    pub permissions: Vec<String>,
    /// Full canonical program objects returned by Core install review.
    pub programs: Vec<Value>,
    pub versions: PluginVersionDetails,
    pub operations: PluginDetailOperations,
}

/// Selection identity that must travel with every asynchronous response.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginDetailsIdentity {
    pub plugin_id: String,
    pub version: String,
    pub source: String,
}

/// One declaration-derived feature and whether this host can execute it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginFeature {
    pub kind: &'static str,
    pub subject: String,
    pub title: String,
    /// `available` means the corresponding capability is implemented by this
    /// host. `declaredOnly` is informative and never promises execution.
    pub availability: &'static str,
    pub detail: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginVersionDetails {
    pub current: VersionProvenance,
    pub previous: Option<VersionProvenance>,
    /// Marketplace index data is supplied by M2. Until it is connected, the
    /// detail surface must not invent an update or "latest" state.
    pub update_status: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionProvenance {
    pub version: String,
    pub origin: &'static str,
    pub channel: &'static str,
    pub source_id: Option<String>,
    pub source_name: Option<String>,
    pub repository: Option<String>,
    pub file_name: Option<String>,
    pub archive_sha256: Option<String>,
    pub content_digest: Option<String>,
    pub verification: ProvenanceVerification,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProvenanceVerification {
    /// `publisherSignature`, `hostSeal`, `approvedDigest`, `rejected`, or
    /// `unknown`. Only the first three are successful verification results.
    pub status: &'static str,
    pub key_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginDetailOperations {
    pub can_set_enabled: bool,
    pub can_uninstall: bool,
    pub can_rollback: bool,
}

/// Reads one package already present in the host catalog. `source` resolves
/// duplicate bundled/installed IDs without exposing a path-shaped selector.
#[tauri::command]
pub async fn declarative_plugins_details(
    app: AppHandle,
    plugin_id: String,
    source: String,
) -> Result<PluginDetails, PluginDetailsError> {
    // Package digests can cover a bundled language server; keep their file IO
    // off the UI and async executor threads while the worker owns its lease.
    tauri::async_runtime::spawn_blocking(move || read_catalog_details(app, plugin_id, source))
        .await
        .map_err(|error| PluginDetailsError::new("plugin.details.readFailed", error.to_string()))?
}

fn read_catalog_details(
    app: AppHandle,
    plugin_id: String,
    source: String,
) -> Result<PluginDetails, PluginDetailsError> {
    if source != "bundled" && source != "installed" {
        return Err(PluginDetailsError::new(
            "plugin.details.invalidSource",
            "Plugin details can only be read from the bundled or installed catalog.",
        ));
    }
    let _lease = app
        .state::<super::lifecycle::LifecycleState>()
        .acquire(&plugin_id)
        .map_err(|message| PluginDetailsError::new("plugin.details.changing", message))?;
    let package = app
        .state::<PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| package.entry.plugin_id == plugin_id && package.entry.source == source)
        .ok_or_else(|| {
            PluginDetailsError::new(
                "plugin.details.notFound",
                "The selected plugin is no longer present. Refresh the plugin list.",
            )
        })?;
    let install_root = store::install_root(&app)
        .map_err(|message| PluginDetailsError::new("plugin.details.storageUnavailable", message))?;
    let bundled_root = store::bundled_root(&app)
        .map_err(|message| PluginDetailsError::new("plugin.details.storageUnavailable", message))?;
    build_details(&package, &install_root, &bundled_root)
}

pub(crate) fn build_details(
    package: &ScannedPackage,
    install_root: &Path,
    bundled_root: &Path,
) -> Result<PluginDetails, PluginDetailsError> {
    let expected_root = match package.entry.source {
        "bundled" => bundled_root,
        "installed" => install_root,
        _ => {
            return Err(PluginDetailsError::new(
                "plugin.details.invalidSource",
                "The cached plugin source is not supported by the detail reader.",
            ))
        }
    };
    ensure_within(package.root.as_path(), expected_root)?;

    let record = if package.entry.source == "installed" {
        read_installation_record(install_root, &package.entry.plugin_id)
    } else {
        Ok(None)
    };
    if package.entry.status == "rejected" {
        let record = record.ok().flatten();
        return Ok(quarantined_details(package, record.as_ref()));
    }
    let record = record.map_err(|message| {
        PluginDetailsError::new("plugin.details.installationRecordChanged", message)
    })?;
    if package.entry.source == "installed" && record.is_none() {
        return Err(PluginDetailsError::new(
            "plugin.details.installationRecordChanged",
            "The installation record disappeared after the catalog was scanned. Refresh the plugin list.",
        ));
    }

    // The scan cache selects the package, but detail content comes from the
    // live package under the lease. This also catches edits after a scan.
    let manifest = read_manifest(&package.root)?;
    let normalized = super::scan::validate_manifest(&manifest).map_err(|rejection| {
        PluginDetailsError::new(
            "plugin.details.packageChanged",
            format!("{}: {}", rejection.code, rejection.message),
        )
    })?;
    if normalized["id"].as_str() != Some(package.entry.plugin_id.as_str())
        || normalized["version"].as_str() != Some(package.entry.version.as_str())
    {
        return Err(PluginDetailsError::new(
            "plugin.details.packageChanged",
            "The package identity changed after the catalog was scanned. Refresh the plugin list.",
        ));
    }
    let trust = package.trust.as_ref().ok_or_else(|| {
        PluginDetailsError::new(
            "plugin.details.trustUnavailable",
            "The accepted package has no verified trust evidence.",
        )
    })?;
    if let Some(record) = &record {
        if record.schema_version != 2
            || record.plugin_id != package.entry.plugin_id
            || record.version != package.entry.version
            || record.origin != Some(trust.origin)
            || record.active_content_digest() != trust.expected_content_digest.as_deref()
        {
            return Err(PluginDetailsError::new(
                "plugin.details.installationRecordChanged",
                "The active installation no longer matches the catalog package. Refresh the plugin list.",
            ));
        }
    }
    signature::verify_for_origin(
        &package.root,
        &package.entry.plugin_id,
        &package.entry.version,
        &manifest,
        trust.origin,
        trust.expected_content_digest.as_deref(),
        Some(bundled_root),
        &signature::trusted_keys(),
    )
    .map_err(|error| {
        PluginDetailsError::new(
            "plugin.details.packageChanged",
            format!(
                "The package no longer passes verification: {}",
                error.message()
            ),
        )
    })?;

    let approved_programs = record.as_ref().map(active_approved_programs).transpose()?;
    let review = install_review(&manifest, approved_programs.as_deref())?;
    let current = current_provenance(
        &package.entry.version,
        trust.origin,
        record.as_ref(),
        &package.root,
    )?;
    let previous = record.as_ref().and_then(previous_provenance);
    let settings = normalized["settings"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    Ok(PluginDetails {
        identity: PluginDetailsIdentity {
            plugin_id: package.entry.plugin_id.clone(),
            version: package.entry.version.clone(),
            source: package.entry.source.to_string(),
        },
        display_name: normalized["displayName"]
            .as_str()
            .unwrap_or(package.entry.display_name.as_str())
            .to_string(),
        vendor_name: normalized["vendor"]["displayName"]
            .as_str()
            .map(str::to_string),
        description: normalized["description"].as_str().map(str::to_string),
        localized_descriptions: localized_descriptions(&normalized),
        api_version: package.entry.api_version,
        enabled: record
            .as_ref()
            .map_or(package.entry.enabled, |record| record.enabled),
        status: "accepted",
        rejection: None,
        primary_language_id: normalized["languageServers"]
            .as_array()
            .and_then(|servers| servers.first())
            .and_then(|server| server["languageID"].as_str())
            .map(str::to_string),
        settings,
        features: features(&normalized),
        permissions: review.permissions,
        programs: review.programs,
        versions: PluginVersionDetails {
            current,
            previous,
            update_status: "unknown",
        },
        operations: PluginDetailOperations {
            can_set_enabled: package.entry.source == "installed",
            can_uninstall: package.entry.source == "installed",
            can_rollback: record
                .as_ref()
                .and_then(|record| record.previous_version.as_ref())
                .is_some(),
        },
    })
}

fn quarantined_details(
    package: &ScannedPackage,
    record: Option<&InstallationRecord>,
) -> PluginDetails {
    let current = VersionProvenance {
        version: package.entry.version.clone(),
        origin: "unknown",
        channel: "unknown",
        source_id: None,
        source_name: None,
        repository: None,
        file_name: None,
        archive_sha256: None,
        content_digest: None,
        verification: ProvenanceVerification {
            status: "rejected",
            key_id: None,
        },
    };
    PluginDetails {
        identity: PluginDetailsIdentity {
            plugin_id: package.entry.plugin_id.clone(),
            version: package.entry.version.clone(),
            source: package.entry.source.to_string(),
        },
        display_name: package.entry.display_name.clone(),
        vendor_name: None,
        description: None,
        localized_descriptions: BTreeMap::new(),
        api_version: package.entry.api_version,
        enabled: false,
        status: "rejected",
        rejection: package.entry.rejection.clone(),
        settings: Vec::new(),
        primary_language_id: None,
        features: Vec::new(),
        permissions: Vec::new(),
        programs: Vec::new(),
        versions: PluginVersionDetails {
            current,
            previous: record.and_then(previous_provenance),
            update_status: "unknown",
        },
        operations: PluginDetailOperations {
            can_set_enabled: false,
            can_uninstall: package.entry.source == "installed",
            can_rollback: record
                .and_then(|record| record.previous_version.as_ref())
                .is_some(),
        },
    }
}

struct InstallReview {
    permissions: Vec<String>,
    programs: Vec<Value>,
}

fn install_review(
    manifest: &Value,
    approved_programs: Option<&[Value]>,
) -> Result<InstallReview, PluginDetailsError> {
    let outcome = super::scan::core_execute(
        "plugins.marketplace.installReview",
        json!({
            "manifest": manifest,
            "hostCapabilities": super::host_capabilities(),
            "approvedPrograms": approved_programs,
        }),
    )
    .map_err(|message| PluginDetailsError::new("plugin.details.reviewUnavailable", message))?;
    if outcome["status"] != json!("ok") {
        return Err(PluginDetailsError::new(
            "plugin.details.reviewRejected",
            outcome["error"]["message"]
                .as_str()
                .unwrap_or("Core could not review the installed package."),
        ));
    }
    if approved_programs.is_some()
        && outcome["review"]["newPrograms"]
            .as_array()
            .is_some_and(|programs| !programs.is_empty())
    {
        return Err(PluginDetailsError::new(
            "plugin.details.approvalChanged",
            "The program declarations no longer match the installation approval. Reinstall the plugin before using it.",
        ));
    }
    Ok(InstallReview {
        permissions: strings(&outcome["review"]["permissions"]),
        programs: outcome["review"]["programs"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    })
}

fn read_manifest(root: &Path) -> Result<Value, PluginDetailsError> {
    let text = std::fs::read_to_string(root.join("plugin.json")).map_err(|error| {
        PluginDetailsError::new(
            "plugin.details.packageChanged",
            format!("plugin.json could not be read: {error}"),
        )
    })?;
    serde_json::from_str(&text).map_err(|error| {
        PluginDetailsError::new(
            "plugin.details.packageChanged",
            format!("plugin.json is no longer valid JSON: {error}"),
        )
    })
}

fn read_installation_record(
    install_root: &Path,
    plugin_id: &str,
) -> Result<Option<InstallationRecord>, String> {
    let component = Path::new(plugin_id);
    if component
        .parent()
        .is_some_and(|parent| parent != Path::new(""))
        || component.file_name().and_then(|value| value.to_str()) != Some(plugin_id)
        || matches!(plugin_id, "" | "." | "..")
    {
        return Err("The selected plugin ID is not a safe store component.".to_string());
    }
    let path = install_root.join(plugin_id).join("installation.json");
    if path.exists() {
        ensure_within(&path, install_root).map_err(|error| error.message)?;
    }
    match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text)
            .map(Some)
            .map_err(|error| format!("installation.json could not be decoded: {error}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("installation.json could not be read: {error}")),
    }
}

fn ensure_within(package_root: &Path, expected_root: &Path) -> Result<(), PluginDetailsError> {
    let root = expected_root.canonicalize().map_err(|error| {
        PluginDetailsError::new(
            "plugin.details.storageUnavailable",
            format!("The plugin store could not be resolved: {error}"),
        )
    })?;
    let package = package_root.canonicalize().map_err(|error| {
        PluginDetailsError::new(
            "plugin.details.packageChanged",
            format!("The selected package could not be resolved: {error}"),
        )
    })?;
    if !package.starts_with(&root) || package == root {
        return Err(PluginDetailsError::new(
            "plugin.details.pathBoundary",
            "The selected package is outside its catalog store.",
        ));
    }
    Ok(())
}

fn active_approved_programs(record: &InstallationRecord) -> Result<Vec<Value>, PluginDetailsError> {
    let values = match (&record.marketplace, &record.disk) {
        (Some(marketplace), None) => &marketplace.approved_programs,
        (None, Some(disk)) => &disk.approved_programs,
        _ => {
            return Err(PluginDetailsError::new(
                "plugin.details.provenanceUnavailable",
                "The active installation has no single approved program record.",
            ))
        }
    };
    values
        .iter()
        .map(|program| {
            serde_json::from_str(program).map_err(|error| {
                PluginDetailsError::new(
                    "plugin.details.provenanceUnavailable",
                    format!("An approved program declaration is unreadable: {error}"),
                )
            })
        })
        .collect()
}

fn current_provenance(
    version: &str,
    origin: InstallOrigin,
    record: Option<&InstallationRecord>,
    package_root: &Path,
) -> Result<VersionProvenance, PluginDetailsError> {
    let key_id = if signature::has_signature_file(package_root) {
        Some(
            signature::read_signature_document(package_root)
                .map_err(|error| {
                    PluginDetailsError::new(
                        "plugin.details.packageChanged",
                        format!(
                            "The verified signature document is unreadable: {}",
                            error.message()
                        ),
                    )
                })?
                .key_id,
        )
    } else {
        None
    };
    let verification = ProvenanceVerification {
        status: if key_id.is_some() {
            "publisherSignature"
        } else if origin == InstallOrigin::Bundled {
            "hostSeal"
        } else {
            "approvedDigest"
        },
        key_id,
    };
    let mut value = VersionProvenance {
        version: version.to_string(),
        origin: origin_name(origin),
        channel: if origin == InstallOrigin::Bundled {
            "bundled"
        } else {
            "unknown"
        },
        source_id: None,
        source_name: None,
        repository: None,
        file_name: None,
        archive_sha256: None,
        content_digest: None,
        verification,
    };
    if let Some(record) = record {
        apply_provenance(
            &mut value,
            record.marketplace.as_ref(),
            record.disk.as_ref(),
        );
    }
    Ok(value)
}

fn previous_provenance(record: &InstallationRecord) -> Option<VersionProvenance> {
    let version = record.previous_version.as_ref()?;
    let origin = record.previous_origin?;
    let mut value = VersionProvenance {
        version: version.clone(),
        origin: origin_name(origin),
        channel: if origin == InstallOrigin::Bundled {
            "bundled"
        } else {
            "unknown"
        },
        source_id: None,
        source_name: None,
        repository: None,
        file_name: None,
        archive_sha256: None,
        content_digest: None,
        // Previous bytes are verified only when rollback begins; the record
        // is provenance, not proof that the dormant directory is unchanged.
        verification: ProvenanceVerification {
            status: "unknown",
            key_id: None,
        },
    };
    apply_provenance(
        &mut value,
        record.previous_marketplace.as_ref(),
        record.previous_disk.as_ref(),
    );
    Some(value)
}

fn apply_provenance(
    target: &mut VersionProvenance,
    marketplace: Option<&store::MarketplaceProvenance>,
    disk: Option<&store::DiskProvenance>,
) {
    match (marketplace, disk) {
        (Some(marketplace), None) => {
            target.channel = "marketplace";
            target.source_id = Some(marketplace.source_id.clone());
            target.source_name = Some(marketplace.source_name.clone());
            target.repository = Some(marketplace.repository.clone());
            target.archive_sha256 = Some(marketplace.archive_sha256.clone());
            target.content_digest = Some(marketplace.content_digest.clone());
        }
        (None, Some(disk)) => {
            target.channel = "disk";
            target.file_name = Some(disk.file_name.clone());
            target.archive_sha256 = disk.archive_sha256.clone();
            target.content_digest = Some(disk.content_digest.clone());
        }
        _ => {}
    }
}

fn origin_name(origin: InstallOrigin) -> &'static str {
    match origin {
        InstallOrigin::Bundled => "bundled",
        InstallOrigin::Marketplace => "marketplace",
        InstallOrigin::Community => "community",
    }
}

fn localized_descriptions(plugin: &Value) -> BTreeMap<String, String> {
    plugin["localizedDescriptions"]
        .as_object()
        .map(|descriptions| {
            descriptions
                .iter()
                .filter_map(|(locale, value)| {
                    value
                        .as_str()
                        .map(|description| (locale.clone(), description.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn features(plugin: &Value) -> Vec<PluginFeature> {
    let language_titles: HashMap<String, String> = plugin["languages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|language| {
            Some((
                language["id"].as_str()?.to_string(),
                language["displayName"].as_str()?.to_string(),
            ))
        })
        .collect();
    let mut result = Vec::new();
    for language in array(plugin, "languages") {
        push_feature(
            &mut result,
            "language",
            &language["id"],
            &language["displayName"],
            "languages",
            Some(json!({
                "fileExtensions": language["fileExtensions"],
                "fileNames": language["fileNames"],
            })),
        );
    }
    for server in array(plugin, "languageServers") {
        let id = server["languageID"].as_str().unwrap_or_default();
        result.push(PluginFeature {
            kind: "languageServer",
            subject: id.to_string(),
            title: language_titles
                .get(id)
                .cloned()
                .unwrap_or_else(|| id.to_string()),
            availability: availability("languageServers"),
            detail: server
                .get("launch")
                .and_then(|launch| launch.get("kind"))
                .cloned()
                .map(|kind| json!({ "launchKind": kind })),
        });
    }
    for provider in array(plugin, "executionProviders") {
        let id = provider["languageID"].as_str().unwrap_or_default();
        let title = language_titles
            .get(id)
            .cloned()
            .unwrap_or_else(|| id.to_string());
        if provider.get("run").is_some() {
            result.push(PluginFeature {
                kind: "run",
                subject: id.to_string(),
                title: title.clone(),
                availability: availability("executionProviders"),
                detail: None,
            });
        }
        if provider.get("test").is_some() {
            result.push(PluginFeature {
                kind: "test",
                subject: id.to_string(),
                title,
                availability: availability("executionProviders"),
                detail: None,
            });
        }
    }
    for build in array(plugin, "buildSystems") {
        push_feature(
            &mut result,
            "buildSystem",
            &build["id"],
            &build["displayName"],
            "buildSystems",
            None,
        );
    }
    for generator in array(plugin, "projectGenerators") {
        push_feature(
            &mut result,
            "projectGenerator",
            &generator["id"],
            &generator["displayName"],
            "projectGenerators",
            None,
        );
    }
    if let Some(ui) = plugin.get("ui") {
        for window in array(ui, "toolWindows") {
            push_feature(
                &mut result,
                "toolWindow",
                &window["id"],
                &window["title"],
                "ui",
                None,
            );
        }
        for command in array(ui, "commands") {
            push_feature(
                &mut result,
                "command",
                &command["id"],
                &command["title"],
                "ui",
                None,
            );
        }
    }
    result.sort_by(|left, right| {
        feature_rank(left.kind)
            .cmp(&feature_rank(right.kind))
            .then_with(|| left.title.cmp(&right.title))
            .then_with(|| left.subject.cmp(&right.subject))
    });
    result
}

fn push_feature(
    result: &mut Vec<PluginFeature>,
    kind: &'static str,
    subject: &Value,
    title: &Value,
    capability: &str,
    detail: Option<Value>,
) {
    let subject = subject.as_str().unwrap_or_default().to_string();
    result.push(PluginFeature {
        kind,
        title: title.as_str().unwrap_or(subject.as_str()).to_string(),
        subject,
        availability: availability(capability),
        detail,
    });
}

fn availability(capability: &str) -> &'static str {
    if super::host_capabilities()
        .get(capability)
        .and_then(Value::as_array)
        .is_some_and(|versions| !versions.is_empty())
    {
        "available"
    } else {
        "declaredOnly"
    }
}

fn feature_rank(kind: &str) -> usize {
    [
        "language",
        "languageServer",
        "run",
        "test",
        "buildSystem",
        "projectGenerator",
        "toolWindow",
        "command",
    ]
    .iter()
    .position(|candidate| *candidate == kind)
    .unwrap_or(usize::MAX)
}

fn array<'a>(value: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    value[key].as_array().into_iter().flatten()
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| item.as_str().map(str::to_string))
        .collect()
}

#[cfg(test)]
pub(crate) fn installation_record_path(root: &Path, plugin_id: &str) -> PathBuf {
    root.join(plugin_id).join("installation.json")
}
