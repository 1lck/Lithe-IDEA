//! Plugin manifest parsing, compatibility checks, and deterministic catalog merging.

use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};

/// Manifest schema understood by this Core build.
pub const PLUGIN_MANIFEST_SCHEMA_VERSION: u32 = 1;
/// Host/plugin API level required by compatible packages.
pub const PLUGIN_API_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
/// Strict three-component semantic version used for compatibility comparisons.
pub struct PluginVersion {
    /// Breaking-change component.
    pub major: u32,
    /// Backward-compatible feature component.
    pub minor: u32,
    /// Backward-compatible fix component.
    pub patch: u32,
}

impl PluginVersion {
    /// Parses exactly `major.minor.patch`; prerelease tags and missing parts are
    /// rejected because the manifest contract does not define their ordering.
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
/// Deterministic reason a catalog cannot be loaded by the current host.
pub enum PluginValidationError {
    /// The catalog is not valid JSON or does not match the manifest shape.
    InvalidJson,
    /// A catalog or plugin uses an unknown manifest schema.
    UnsupportedSchema {
        /// Plugin identifier, or `catalog` when the top-level schema failed.
        plugin: String,
        /// Unsupported manifest schema version found in the input.
        version: u32,
    },
    /// A catalog or plugin targets a different plugin API.
    UnsupportedApi {
        /// Plugin identifier, or `catalog` when the top-level API failed.
        plugin: String,
        /// Unsupported plugin API level found in the input.
        version: u32,
    },
    /// A version does not use the strict three-component format.
    InvalidVersion {
        /// Plugin whose version or compatibility bound is malformed.
        plugin: String,
        /// Original version string that could not be parsed.
        value: String,
    },
    /// The current host falls outside the package's declared version interval.
    IncompatibleHost {
        /// Plugin identifier, or `catalog` for a fixture-host mismatch.
        plugin: String,
    },
    /// Entrypoint metadata is incomplete or inconsistent with its kind.
    InvalidEntrypoint {
        /// Plugin containing inconsistent loading or publisher metadata.
        plugin: String,
    },
    /// More than one package declares the same plugin identifier.
    DuplicatePlugin(String),
    /// More than one package claims ownership of the same module identifier.
    DuplicateModule(String),
    /// A plugin contains no modules and therefore cannot contribute behavior.
    EmptyPlugin(String),
    /// Plugin packages are not in canonical identifier order.
    UnsortedPlugins,
    /// A package's module identifiers are not in canonical order.
    UnsortedModules {
        /// Plugin whose module identifiers are not in canonical order.
        plugin: String,
    },
    /// Language recognition or capability ownership is invalid.
    InvalidLanguageSupport {
        /// Plugin declaring the invalid language contribution.
        plugin: String,
        /// Language identifier whose recognition or module ownership is invalid.
        language: String,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Top-level plugin catalog fixture consumed by compatibility verification.
pub struct PluginCatalogFixture {
    /// Version of the catalog JSON shape.
    pub schema_version: u32,
    /// Exact host version for which the fixture was assembled.
    pub host_version: String,
    /// Plugin API level shared by every package in the catalog.
    #[serde(rename = "pluginAPIVersion")]
    pub plugin_api_version: u32,
    /// Packages sorted by stable plugin identifier.
    pub plugins: Vec<PluginPackageManifest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Compatibility and ownership metadata for one plugin package.
pub struct PluginPackageManifest {
    /// Stable package identifier used as the catalog key.
    pub id: String,
    /// Human-readable name presented by host applications.
    pub display_name: String,
    /// Package version in strict `major.minor.patch` form.
    pub version: String,
    /// Plugin API level against which the package was built.
    pub api_version: u32,
    /// Inclusive lower and optional exclusive upper host bounds.
    pub host_compatibility: HostCompatibility,
    /// Publisher identity and signature policy.
    pub vendor: PluginVendor,
    /// Native or built-in loading metadata.
    pub entrypoint: PluginEntrypoint,
    /// Stable module identifiers owned by this package, in sorted order.
    #[serde(rename = "moduleIDs")]
    pub module_ids: Vec<String>,
    /// Language capabilities contributed by the package.
    #[serde(default)]
    pub language_supports: Vec<LanguageSupportManifest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// File recognition and module ownership for one contributed language.
pub struct LanguageSupportManifest {
    /// Lowercase stable language identifier.
    pub id: String,
    /// Human-readable language name.
    pub display_name: String,
    /// Extensions without a leading dot, kept in deterministic order.
    #[serde(default)]
    pub file_extensions: Vec<String>,
    /// Exact file names recognized as this language.
    #[serde(default)]
    pub file_names: Vec<String>,
    /// Project marker names that activate language support for a workspace.
    #[serde(default)]
    pub project_file_names: Vec<String>,
    /// Package-owned module providing language-server integration.
    #[serde(rename = "languageServerModuleID")]
    pub language_server_module_id: Option<String>,
    /// Package-owned module providing run configurations.
    #[serde(rename = "executionModuleID")]
    pub execution_module_id: Option<String>,
    /// Package-owned module providing test integration.
    #[serde(rename = "testingModuleID")]
    pub testing_module_id: Option<String>,
    /// Package-owned module providing debug integration.
    #[serde(rename = "debugModuleID")]
    pub debug_module_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Half-open host-version interval supported by a plugin.
pub struct HostCompatibility {
    /// Oldest compatible host version, inclusive.
    pub minimum: String,
    /// First incompatible host version, when an upper bound is required.
    pub maximum_exclusive: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Plugin publisher identity and the signature relationship required by the host.
pub struct PluginVendor {
    /// Stable publisher identifier.
    pub id: String,
    /// Human-readable publisher name.
    pub display_name: String,
    /// Signature policy; currently only `sameTeamAsHost` is accepted.
    pub signature_requirement: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Mutually exclusive loading metadata for built-in and native-bundle plugins.
pub struct PluginEntrypoint {
    /// Entrypoint discriminator: `builtIn` or `nativeBundle`.
    pub kind: String,
    /// Build target used by a built-in plugin.
    pub target_name: Option<String>,
    /// Bundle identifier required for a native plugin.
    pub bundle_identifier: Option<String>,
    /// Principal class required for a native plugin.
    pub principal_class: Option<String>,
    /// Workspace-relative bundle location required for a native plugin.
    pub bundle_path: Option<String>,
}

/// Validates a complete catalog and returns the owning plugin for every module.
///
/// Validation also enforces deterministic ordering, host/API compatibility,
/// entrypoint consistency, and that language capabilities reference only
/// modules owned by their declaring package.
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
