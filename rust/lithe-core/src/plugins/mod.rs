//! Plugin manifest parsing, compatibility checks, and deterministic catalog merging.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use url::Url;

/// Manifest schema understood by this Core build.
pub const PLUGIN_MANIFEST_SCHEMA_VERSION: u32 = 1;
/// Host/plugin API level required by compatible packages.
pub const PLUGIN_API_VERSION: u32 = 1;

fn default_schema_version() -> u32 {
    PLUGIN_MANIFEST_SCHEMA_VERSION
}

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
        let parse_component = |part: &str| {
            (!part.is_empty()
                && part.chars().all(|character| character.is_ascii_digit())
                && (part == "0" || !part.starts_with('0')))
            .then(|| part.parse().ok())
            .flatten()
        };
        let version = Self {
            major: parse_component(parts.next()?)?,
            minor: parse_component(parts.next()?)?,
            patch: parse_component(parts.next()?)?,
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
    /// A full module declaration disagrees with the compact module ID list.
    InvalidModuleDeclaration {
        /// Plugin containing the inconsistent declaration.
        plugin: String,
        /// Stable reason suitable for diagnostics.
        detail: String,
    },
    /// A language-server/tool manifest is incomplete or unsafe.
    InvalidLanguageServerManifest {
        /// Plugin owning the tool manifest.
        plugin: String,
        /// Stable validation detail suitable for diagnostics.
        detail: String,
    },
    /// The lifecycle action is not valid for the current plugin state.
    InvalidLifecycleTransition {
        /// Plugin whose state could not advance.
        plugin: String,
        /// Current state and requested action.
        state: PluginLifecycleState,
        /// Action that was rejected.
        action: PluginLifecycleAction,
    },
    /// A plugin cannot be disabled or uninstalled while it owns resources.
    ActiveResources {
        /// Plugin whose resources are still active.
        plugin: String,
        /// Stable resource identifiers still bound to the plugin.
        resources: Vec<String>,
    },
    /// The lifecycle generation cannot be incremented further.
    GenerationOverflow {
        /// Plugin whose lifecycle exhausted its generation space.
        plugin: String,
    },
}

impl fmt::Display for PluginValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidJson => formatter.write_str("invalid plugin JSON"),
            Self::UnsupportedSchema { plugin, version } => {
                write!(
                    formatter,
                    "plugin {plugin} uses unsupported schema version {version}"
                )
            }
            Self::UnsupportedApi { plugin, version } => {
                write!(
                    formatter,
                    "plugin {plugin} uses unsupported API version {version}"
                )
            }
            Self::InvalidVersion { plugin, value } => {
                write!(formatter, "plugin {plugin} has invalid version {value}")
            }
            Self::IncompatibleHost { plugin } => {
                write!(formatter, "plugin {plugin} is incompatible with this host")
            }
            Self::InvalidEntrypoint { plugin } => {
                write!(formatter, "plugin {plugin} has invalid entrypoint metadata")
            }
            Self::DuplicatePlugin(plugin) => write!(formatter, "duplicate plugin {plugin}"),
            Self::DuplicateModule(module) => write!(formatter, "duplicate module {module}"),
            Self::EmptyPlugin(plugin) => write!(formatter, "plugin {plugin} declares no modules"),
            Self::UnsortedPlugins => formatter.write_str("plugin packages are not sorted"),
            Self::UnsortedModules { plugin } => {
                write!(formatter, "plugin {plugin} modules are not sorted")
            }
            Self::InvalidLanguageSupport { plugin, language } => {
                write!(
                    formatter,
                    "plugin {plugin} has invalid language support {language}"
                )
            }
            Self::InvalidModuleDeclaration { plugin, detail } => {
                write!(
                    formatter,
                    "plugin {plugin} has invalid module declaration: {detail}"
                )
            }
            Self::InvalidLanguageServerManifest { plugin, detail } => {
                write!(
                    formatter,
                    "plugin {plugin} has invalid language-server manifest: {detail}"
                )
            }
            Self::InvalidLifecycleTransition {
                plugin,
                state,
                action,
            } => {
                write!(
                    formatter,
                    "plugin {plugin} cannot apply {} in {}",
                    lifecycle_action_name(*action),
                    lifecycle_state_name(*state)
                )
            }
            Self::ActiveResources { plugin, resources } => {
                write!(
                    formatter,
                    "plugin {plugin} still owns resources: {}",
                    resources.join(", ")
                )
            }
            Self::GenerationOverflow { plugin } => {
                write!(formatter, "plugin {plugin} lifecycle generation overflowed")
            }
        }
    }
}

impl std::error::Error for PluginValidationError {}

fn lifecycle_state_name(state: PluginLifecycleState) -> &'static str {
    match state {
        PluginLifecycleState::Discovered => "discovered",
        PluginLifecycleState::Installing => "installing",
        PluginLifecycleState::Installed => "installed",
        PluginLifecycleState::Enabling => "enabling",
        PluginLifecycleState::Enabled => "enabled",
        PluginLifecycleState::Disabling => "disabling",
        PluginLifecycleState::Disabled => "disabled",
        PluginLifecycleState::Uninstalling => "uninstalling",
        PluginLifecycleState::Uninstalled => "uninstalled",
        PluginLifecycleState::Failed => "failed",
    }
}

fn lifecycle_action_name(action: PluginLifecycleAction) -> &'static str {
    match action {
        PluginLifecycleAction::BeginInstall => "beginInstall",
        PluginLifecycleAction::CompleteInstall => "completeInstall",
        PluginLifecycleAction::Enable => "enable",
        PluginLifecycleAction::CompleteEnable => "completeEnable",
        PluginLifecycleAction::Disable => "disable",
        PluginLifecycleAction::CompleteDisable => "completeDisable",
        PluginLifecycleAction::Uninstall => "uninstall",
        PluginLifecycleAction::CompleteUninstall => "completeUninstall",
        PluginLifecycleAction::Fail => "fail",
        PluginLifecycleAction::Reset => "reset",
    }
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Compatibility and ownership metadata for one plugin package.
pub struct PluginPackageManifest {
    /// Version of the per-package manifest schema.
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
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
    #[serde(default)]
    pub module_ids: Vec<String>,
    /// Full module declarations used by an installed plugin's `plugin.json`.
    /// Catalog fixtures may use the compact `moduleIDs` representation.
    #[serde(default)]
    pub modules: Vec<PluginModuleManifest>,
    /// Language capabilities contributed by the package.
    #[serde(default)]
    pub language_supports: Vec<LanguageSupportManifest>,
}

/// Module declaration accepted in a plugin-owned manifest.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginModuleManifest {
    /// Stable module identifier owned by the plugin package.
    pub id: String,
    /// Remaining module fields are preserved so Core validation does not erase
    /// the host-facing module graph while the generated bindings are migrated.
    #[serde(flatten)]
    pub metadata: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Half-open host-version interval supported by a plugin.
pub struct HostCompatibility {
    /// Oldest compatible host version, inclusive.
    pub minimum: String,
    /// First incompatible host version, when an upper bound is required.
    pub maximum_exclusive: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
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

/// Build-time language-server package metadata owned by one plugin.
///
/// The archive is fetched and unpacked by the platform adapter, while Core
/// validates the identity, fixed version, checksum shape, and safe relative
/// paths. This keeps download policy out of the host language catalog.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PluginLanguageServerManifest {
    /// Version of this tool manifest schema.
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    /// Plugin that owns the tool and its lifecycle.
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    /// Language recognized by this tool.
    #[serde(rename = "languageID")]
    pub language_id: String,
    /// Stable tool identifier, for example `intelephense`.
    #[serde(rename = "toolID")]
    pub tool_id: String,
    /// Exact upstream version included in the package.
    pub version: String,
    /// Fixed HTTPS archive source used at build time.
    #[serde(rename = "archiveURL")]
    pub archive_url: String,
    /// SHA-256 digest of the complete upstream archive.
    #[serde(rename = "archiveSHA256")]
    pub archive_sha256: String,
    /// Archive format understood by the build script.
    pub archive_format: String,
    /// Archive root stripped before installation.
    pub archive_root: String,
    /// Entrypoint path inside the upstream archive.
    pub entrypoint: String,
    /// Launcher path inside the installed plugin bundle, relative to its
    /// language-server resource directory.
    pub launcher_relative_path: String,
    /// License file path inside the upstream archive.
    pub license: String,
    /// Ordered launcher arguments passed to the generic LSP runtime.
    #[serde(default)]
    pub arguments: Vec<String>,
}

/// Stable lifecycle states for resources owned by an installed plugin.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PluginLifecycleState {
    /// Metadata has been discovered but no package is installed.
    Discovered,
    /// Package verification and atomic installation are in progress.
    Installing,
    /// Package is installed and can be enabled.
    Installed,
    /// Module activation is in progress.
    Enabling,
    /// Plugin modules may own capabilities and resources.
    Enabled,
    /// Disable is stopping owned resources.
    Disabling,
    /// Plugin remains installed but owns no active resources.
    Disabled,
    /// Package removal is in progress.
    Uninstalling,
    /// No package remains installed.
    Uninstalled,
    /// A terminal failure requires repair or reinstall.
    Failed,
}

/// User or adapter action applied to one plugin lifecycle.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PluginLifecycleAction {
    /// Begin atomic package installation.
    BeginInstall,
    /// Commit a verified package installation.
    CompleteInstall,
    /// Begin module activation.
    Enable,
    /// Commit module activation.
    CompleteEnable,
    /// Begin stopping module resources.
    Disable,
    /// Commit module shutdown.
    CompleteDisable,
    /// Begin package removal.
    Uninstall,
    /// Commit package removal.
    CompleteUninstall,
    /// Enter failed state after an operation error.
    Fail,
    /// Return a resource-free failed lifecycle to discovery.
    Reset,
}

/// One deterministic lifecycle transition emitted to platform adapters.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PluginLifecycleEvent {
    /// Plugin owning the transition.
    pub plugin_id: String,
    /// Monotonic generation incremented for every accepted action.
    pub generation: u64,
    /// Operation identifier supplied by the caller.
    pub operation_id: String,
    /// State before the action.
    pub previous_state: PluginLifecycleState,
    /// State after the action.
    pub state: PluginLifecycleState,
    /// Resources still owned after the transition.
    pub resources: Vec<String>,
}

/// Pure Core state machine for plugin package and resource ownership.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PluginLifecycle {
    /// Stable plugin identifier whose resources are being reduced.
    pub plugin_id: String,
    /// Current lifecycle state.
    pub state: PluginLifecycleState,
    /// Monotonic transition generation supplied to stale-result guards.
    pub generation: u64,
    /// Core-owned sessions and processes that must stop before disable/uninstall.
    #[serde(default)]
    pub resources: BTreeSet<String>,
}

/// JSON request for the stateless lifecycle reducer exposed by Core.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PluginLifecycleRequest {
    /// Lifecycle snapshot returned by the previous transition.
    pub lifecycle: PluginLifecycle,
    /// Requested state transition.
    pub action: PluginLifecycleAction,
    /// Caller operation identity copied into the transition event.
    #[serde(default)]
    pub operation_id: String,
}

/// JSON response containing the new lifecycle snapshot and its event.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginLifecycleResponse {
    /// Updated lifecycle snapshot after the accepted action.
    pub lifecycle: PluginLifecycle,
    /// Event describing the accepted transition.
    pub event: PluginLifecycleEvent,
}

impl PluginLifecycle {
    /// Creates a lifecycle in the discovered state.
    pub fn new(plugin_id: impl Into<String>) -> Self {
        Self {
            plugin_id: plugin_id.into(),
            state: PluginLifecycleState::Discovered,
            generation: 0,
            resources: BTreeSet::new(),
        }
    }

    /// Binds one Core-owned resource, such as an LSP session or process.
    pub fn bind_resource(
        &mut self,
        resource: impl Into<String>,
    ) -> Result<(), PluginValidationError> {
        if !matches!(
            self.state,
            PluginLifecycleState::Enabled | PluginLifecycleState::Enabling
        ) {
            return Err(PluginValidationError::InvalidLifecycleTransition {
                plugin: self.plugin_id.clone(),
                state: self.state,
                action: PluginLifecycleAction::CompleteEnable,
            });
        }
        let resource = resource.into();
        if !resource.is_empty() {
            self.resources.insert(resource);
        }
        Ok(())
    }

    /// Releases one resource after its platform process/session has stopped.
    pub fn unbind_resource(&mut self, resource: &str) {
        self.resources.remove(resource);
    }

    /// Applies one lifecycle action and returns the event consumed by the host.
    pub fn apply(
        &mut self,
        action: PluginLifecycleAction,
        operation_id: impl Into<String>,
    ) -> Result<PluginLifecycleEvent, PluginValidationError> {
        if matches!(
            action,
            PluginLifecycleAction::Disable
                | PluginLifecycleAction::CompleteDisable
                | PluginLifecycleAction::Uninstall
                | PluginLifecycleAction::CompleteUninstall
                | PluginLifecycleAction::Fail
                | PluginLifecycleAction::Reset
        ) && !self.resources.is_empty()
        {
            return Err(PluginValidationError::ActiveResources {
                plugin: self.plugin_id.clone(),
                resources: self.resources.iter().cloned().collect(),
            });
        }
        let next = match (self.state, action) {
            (
                PluginLifecycleState::Discovered | PluginLifecycleState::Uninstalled,
                PluginLifecycleAction::BeginInstall,
            ) => PluginLifecycleState::Installing,
            (PluginLifecycleState::Installing, PluginLifecycleAction::CompleteInstall) => {
                PluginLifecycleState::Installed
            }
            (
                PluginLifecycleState::Installed | PluginLifecycleState::Disabled,
                PluginLifecycleAction::Enable,
            ) => PluginLifecycleState::Enabling,
            (PluginLifecycleState::Enabling, PluginLifecycleAction::CompleteEnable) => {
                PluginLifecycleState::Enabled
            }
            (PluginLifecycleState::Enabled, PluginLifecycleAction::Disable) => {
                PluginLifecycleState::Disabling
            }
            (PluginLifecycleState::Disabling, PluginLifecycleAction::CompleteDisable) => {
                PluginLifecycleState::Disabled
            }
            (
                PluginLifecycleState::Installed | PluginLifecycleState::Disabled,
                PluginLifecycleAction::Uninstall,
            ) => PluginLifecycleState::Uninstalling,
            (PluginLifecycleState::Uninstalling, PluginLifecycleAction::CompleteUninstall) => {
                PluginLifecycleState::Uninstalled
            }
            (_, PluginLifecycleAction::Fail) => PluginLifecycleState::Failed,
            (PluginLifecycleState::Failed, PluginLifecycleAction::Reset) => {
                PluginLifecycleState::Discovered
            }
            _ => {
                return Err(PluginValidationError::InvalidLifecycleTransition {
                    plugin: self.plugin_id.clone(),
                    state: self.state,
                    action,
                })
            }
        };
        let previous_state = self.state;
        let next_generation = self.generation.checked_add(1).ok_or_else(|| {
            PluginValidationError::GenerationOverflow {
                plugin: self.plugin_id.clone(),
            }
        })?;
        self.state = next;
        self.generation = next_generation;
        Ok(PluginLifecycleEvent {
            plugin_id: self.plugin_id.clone(),
            generation: self.generation,
            operation_id: operation_id.into(),
            previous_state,
            state: next,
            resources: self.resources.iter().cloned().collect(),
        })
    }
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
            || !matches!(
                plugin.vendor.signature_requirement.as_str(),
                "sameTeamAsHost" | "publisherPackage"
            )
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

/// Validates one plugin directory's `plugin.json` using the same rules as a
/// merged catalog. The platform adapter may call this before loading a Bundle.
pub fn validate_plugin_manifest_json(
    input: &str,
    host_version: PluginVersion,
) -> Result<PluginPackageManifest, PluginValidationError> {
    let manifest: PluginPackageManifest =
        serde_json::from_str(input).map_err(|_| PluginValidationError::InvalidJson)?;
    if manifest.schema_version != PLUGIN_MANIFEST_SCHEMA_VERSION {
        return Err(PluginValidationError::UnsupportedSchema {
            plugin: manifest.id.clone(),
            version: manifest.schema_version,
        });
    }
    if manifest.api_version != PLUGIN_API_VERSION {
        return Err(PluginValidationError::UnsupportedApi {
            plugin: manifest.id.clone(),
            version: manifest.api_version,
        });
    }
    let _ = parse_version(&manifest.id, &manifest.version)?;
    let minimum = parse_version(&manifest.id, &manifest.host_compatibility.minimum)?;
    let maximum = manifest
        .host_compatibility
        .maximum_exclusive
        .as_deref()
        .map(|value| parse_version(&manifest.id, value))
        .transpose()?;
    if host_version < minimum || maximum.is_some_and(|value| host_version >= value) {
        return Err(PluginValidationError::IncompatibleHost {
            plugin: manifest.id.clone(),
        });
    }
    validate_manifest_shape(&manifest)?;
    Ok(manifest)
}

fn validate_manifest_shape(manifest: &PluginPackageManifest) -> Result<(), PluginValidationError> {
    if manifest.id.is_empty()
        || manifest.display_name.is_empty()
        || manifest.vendor.id.is_empty()
        || manifest.vendor.display_name.is_empty()
        || !matches!(
            manifest.vendor.signature_requirement.as_str(),
            "sameTeamAsHost" | "publisherPackage"
        )
        || !valid_entrypoint(&manifest.entrypoint)
        || manifest.module_ids().is_empty()
    {
        return Err(PluginValidationError::InvalidEntrypoint {
            plugin: manifest.id.clone(),
        });
    }
    let compact_module_ids = manifest.module_ids.clone();
    let full_module_ids: Vec<String> = manifest
        .modules
        .iter()
        .map(|module| module.id.clone())
        .collect();
    if !compact_module_ids.is_empty()
        && !full_module_ids.is_empty()
        && compact_module_ids != full_module_ids
    {
        return Err(PluginValidationError::InvalidModuleDeclaration {
            plugin: manifest.id.clone(),
            detail: "moduleIDs and modules disagree".into(),
        });
    }
    let module_ids = manifest.module_ids();
    if !strictly_sorted(&module_ids)
        || module_ids.iter().any(|module| !valid_identifier(module))
        || manifest.modules.iter().any(|module| module.id.is_empty())
    {
        return Err(PluginValidationError::UnsortedModules {
            plugin: manifest.id.clone(),
        });
    }
    validate_language_supports(manifest)
}

impl PluginPackageManifest {
    /// Returns stable module IDs declared by this package.
    pub fn module_ids(&self) -> Vec<String> {
        if self.module_ids.is_empty() {
            self.modules
                .iter()
                .map(|module| module.id.clone())
                .collect()
        } else {
            self.module_ids.clone()
        }
    }
}

/// Validates a plugin-owned `language-server.json` document.
pub fn validate_language_server_manifest_json(
    input: &str,
    plugin_id: &str,
) -> Result<PluginLanguageServerManifest, PluginValidationError> {
    let manifest: PluginLanguageServerManifest = serde_json::from_str(input).map_err(|error| {
        PluginValidationError::InvalidLanguageServerManifest {
            plugin: plugin_id.into(),
            detail: format!("invalid JSON: {error}"),
        }
    })?;
    let valid_sha = manifest.archive_sha256.len() == 64
        && manifest
            .archive_sha256
            .chars()
            .all(|value| value.is_ascii_hexdigit());
    let valid_url = Url::parse(&manifest.archive_url).is_ok_and(|url| {
        url.scheme() == "https"
            && url.host_str().is_some_and(|host| !host.is_empty())
            && url.username().is_empty()
            && url.password().is_none()
            && !url.path().is_empty()
    });
    let valid = manifest.schema_version == PLUGIN_MANIFEST_SCHEMA_VERSION
        && manifest.plugin_id == plugin_id
        && valid_identifier(&manifest.language_id)
        && valid_identifier(&manifest.tool_id)
        && PluginVersion::parse(&manifest.version).is_some()
        && valid_url
        && valid_sha
        && manifest.archive_format == "tarGzip"
        && valid_relative_path(&manifest.archive_root)
        && valid_relative_path(&manifest.entrypoint)
        && valid_relative_path(&manifest.launcher_relative_path)
        && valid_relative_path(&manifest.license)
        && !manifest
            .arguments
            .iter()
            .any(|argument| argument.contains('\0'));
    if !valid {
        return Err(PluginValidationError::InvalidLanguageServerManifest {
            plugin: plugin_id.into(),
            detail: "schema, identity, source, checksum, or relative path is invalid".into(),
        });
    }
    Ok(manifest)
}

fn validate_language_supports(plugin: &PluginPackageManifest) -> Result<(), PluginValidationError> {
    let module_ids = plugin.module_ids();
    let owned_modules: BTreeSet<&str> = module_ids.iter().map(String::as_str).collect();
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
        && !value.starts_with('\\')
        && !value.contains('\\')
        && !value.contains('\0')
        && !value.as_bytes().get(1).is_some_and(|byte| *byte == b':')
        && !value
            .split('/')
            .any(|component| component == ".." || component == "." || component.is_empty())
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}
