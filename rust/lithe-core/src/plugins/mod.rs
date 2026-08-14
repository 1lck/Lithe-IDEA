use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};

pub const PLUGIN_MANIFEST_SCHEMA_VERSION: u32 = 1;
pub const PLUGIN_API_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct PluginVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl PluginVersion {
    pub fn parse(value: &str) -> Option<Self> {
        let mut parts = value.split('.');
        let version = Self {
            major: parts.next()?.parse().ok()?,
            minor: parts.next()?.parse().ok()?,
            patch: parts.next()?.parse().ok()?,
        };
        parts.next().is_none().then_some(version)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PluginValidationError {
    InvalidJson,
    UnsupportedSchema { plugin: String, version: u32 },
    UnsupportedApi { plugin: String, version: u32 },
    InvalidVersion { plugin: String, value: String },
    IncompatibleHost { plugin: String },
    InvalidEntrypoint { plugin: String },
    DuplicatePlugin(String),
    DuplicateModule(String),
    EmptyPlugin(String),
    UnsortedPlugins,
    UnsortedModules { plugin: String },
    InvalidLanguageSupport { plugin: String, language: String },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginCatalogFixture {
    pub schema_version: u32,
    pub host_version: String,
    #[serde(rename = "pluginAPIVersion")]
    pub plugin_api_version: u32,
    pub plugins: Vec<PluginPackageManifest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginPackageManifest {
    pub id: String,
    pub display_name: String,
    pub version: String,
    pub api_version: u32,
    pub host_compatibility: HostCompatibility,
    pub vendor: PluginVendor,
    pub entrypoint: PluginEntrypoint,
    #[serde(rename = "moduleIDs")]
    pub module_ids: Vec<String>,
    #[serde(default)]
    pub language_supports: Vec<LanguageSupportManifest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanguageSupportManifest {
    pub id: String,
    pub display_name: String,
    #[serde(default)]
    pub file_extensions: Vec<String>,
    #[serde(default)]
    pub file_names: Vec<String>,
    #[serde(default)]
    pub project_file_names: Vec<String>,
    #[serde(rename = "languageServerModuleID")]
    pub language_server_module_id: Option<String>,
    #[serde(rename = "executionModuleID")]
    pub execution_module_id: Option<String>,
    #[serde(rename = "testingModuleID")]
    pub testing_module_id: Option<String>,
    #[serde(rename = "debugModuleID")]
    pub debug_module_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostCompatibility {
    pub minimum: String,
    pub maximum_exclusive: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginVendor {
    pub id: String,
    pub display_name: String,
    pub signature_requirement: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginEntrypoint {
    pub kind: String,
    pub target_name: Option<String>,
    pub bundle_identifier: Option<String>,
    pub principal_class: Option<String>,
    pub bundle_path: Option<String>,
}

pub fn validate_plugin_catalog_json(
    input: &str,
    host_version: PluginVersion,
) -> Result<BTreeMap<String, String>, PluginValidationError> {
    let catalog: PluginCatalogFixture =
        serde_json::from_str(input).map_err(|_| PluginValidationError::InvalidJson)?;
    if catalog.schema_version != PLUGIN_MANIFEST_SCHEMA_VERSION {
        return Err(PluginValidationError::UnsupportedSchema {
            plugin: "catalog".into(),
            version: catalog.schema_version,
        });
    }
    if catalog.plugin_api_version != PLUGIN_API_VERSION {
        return Err(PluginValidationError::UnsupportedApi {
            plugin: "catalog".into(),
            version: catalog.plugin_api_version,
        });
    }
    let catalog_host = parse_version("catalog", &catalog.host_version)?;
    if catalog_host != host_version {
        return Err(PluginValidationError::IncompatibleHost {
            plugin: "catalog".into(),
        });
    }
    let plugin_ids: Vec<&str> = catalog
        .plugins
        .iter()
        .map(|plugin| plugin.id.as_str())
        .collect();
    if !plugin_ids.windows(2).all(|pair| pair[0] < pair[1]) {
        return Err(PluginValidationError::UnsortedPlugins);
    }

    let mut seen_plugins = BTreeSet::new();
    let mut module_owners = BTreeMap::new();
    for plugin in catalog.plugins {
        if !seen_plugins.insert(plugin.id.clone()) {
            return Err(PluginValidationError::DuplicatePlugin(plugin.id));
        }
        if plugin.api_version != PLUGIN_API_VERSION {
            return Err(PluginValidationError::UnsupportedApi {
                plugin: plugin.id,
                version: plugin.api_version,
            });
        }
        let _version = parse_version(&plugin.id, &plugin.version)?;
        let minimum = parse_version(&plugin.id, &plugin.host_compatibility.minimum)?;
        let maximum = plugin
            .host_compatibility
            .maximum_exclusive
            .as_deref()
            .map(|value| parse_version(&plugin.id, value))
            .transpose()?;
        if host_version < minimum || maximum.is_some_and(|value| host_version >= value) {
            return Err(PluginValidationError::IncompatibleHost { plugin: plugin.id });
        }
        if plugin.display_name.is_empty()
            || plugin.vendor.id.is_empty()
            || plugin.vendor.display_name.is_empty()
            || plugin.vendor.signature_requirement != "sameTeamAsHost"
            || !valid_entrypoint(&plugin.entrypoint)
        {
            return Err(PluginValidationError::InvalidEntrypoint { plugin: plugin.id });
        }
        if plugin.module_ids.is_empty() {
            return Err(PluginValidationError::EmptyPlugin(plugin.id));
        }
        if !plugin.module_ids.windows(2).all(|pair| pair[0] < pair[1]) {
            return Err(PluginValidationError::UnsortedModules { plugin: plugin.id });
        }
        validate_language_supports(&plugin)?;
        for module_id in plugin.module_ids {
            if module_owners
                .insert(module_id.clone(), plugin.id.clone())
                .is_some()
            {
                return Err(PluginValidationError::DuplicateModule(module_id));
            }
        }
    }
    Ok(module_owners)
}

fn validate_language_supports(plugin: &PluginPackageManifest) -> Result<(), PluginValidationError> {
    let owned_modules: BTreeSet<&str> = plugin.module_ids.iter().map(String::as_str).collect();
    let mut language_ids = BTreeSet::new();
    for support in &plugin.language_supports {
        let module_ids: Vec<&str> = [
            support.language_server_module_id.as_deref(),
            support.execution_module_id.as_deref(),
            support.testing_module_id.as_deref(),
            support.debug_module_id.as_deref(),
        ]
        .into_iter()
        .flatten()
        .collect();
        let recognition_is_empty = support.file_extensions.is_empty()
            && support.file_names.is_empty()
            && support.project_file_names.is_empty();
        let invalid_names = support.id.is_empty()
            || support.id != support.id.trim().to_lowercase()
            || support.display_name.is_empty()
            || !strictly_sorted(&support.file_extensions)
            || !strictly_sorted(&support.file_names)
            || !strictly_sorted(&support.project_file_names)
            || support
                .file_extensions
                .iter()
                .any(|value| value.starts_with('.') || value.contains('/'))
            || support.file_names.iter().any(|value| value.contains('/'))
            || support
                .project_file_names
                .iter()
                .any(|value| value.contains('/'));
        if !language_ids.insert(support.id.as_str())
            || recognition_is_empty
            || invalid_names
            || module_ids.is_empty()
            || !module_ids.iter().all(|id| owned_modules.contains(id))
        {
            return Err(PluginValidationError::InvalidLanguageSupport {
                plugin: plugin.id.clone(),
                language: support.id.clone(),
            });
        }
    }
    Ok(())
}

fn strictly_sorted(values: &[String]) -> bool {
    values.windows(2).all(|pair| pair[0] < pair[1])
}

fn parse_version(plugin: &str, value: &str) -> Result<PluginVersion, PluginValidationError> {
    PluginVersion::parse(value).ok_or_else(|| PluginValidationError::InvalidVersion {
        plugin: plugin.into(),
        value: value.into(),
    })
}

fn valid_entrypoint(entrypoint: &PluginEntrypoint) -> bool {
    match entrypoint.kind.as_str() {
        "builtIn" => {
            entrypoint
                .target_name
                .as_ref()
                .is_some_and(|value| !value.is_empty())
                && entrypoint.bundle_identifier.is_none()
                && entrypoint.principal_class.is_none()
                && entrypoint.bundle_path.is_none()
        }
        "nativeBundle" => {
            entrypoint.target_name.is_none()
                && entrypoint
                    .bundle_identifier
                    .as_ref()
                    .is_some_and(|value| !value.is_empty())
                && entrypoint
                    .principal_class
                    .as_ref()
                    .is_some_and(|value| !value.is_empty())
                && entrypoint
                    .bundle_path
                    .as_ref()
                    .is_some_and(|value| valid_relative_path(value))
        }
        _ => false,
    }
}

fn valid_relative_path(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('/')
        && !value
            .split('/')
            .any(|component| component == ".." || component.is_empty())
}
