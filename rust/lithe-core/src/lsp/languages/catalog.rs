use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const BUILTIN_LANGUAGE_PROVIDERS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/resources/lsp/language-providers.json"
));

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderCatalog {
    pub version: u32,
    pub providers: Vec<LspProviderDescriptor>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<LspProviderConfigDiagnostic>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderConfigDiagnostic {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderDescriptor {
    pub id: String,
    pub display_name: String,
    pub file_extensions: Vec<String>,
    pub file_names: Vec<String>,
    pub file_name_prefixes: Vec<String>,
    pub capabilities: Vec<LspProviderCapability>,
    pub activation_policy: LspActivationPolicy,
    pub language_id: Option<String>,
    pub language_ids_by_extension: BTreeMap<String, String>,
    pub language_ids_by_file_name: BTreeMap<String, String>,
    pub language_server_launch: Option<LspServerLaunchDescriptor>,
    pub language_server_installation: Option<LspServerInstallationDescriptor>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LspServerLaunchDescriptor {
    pub executable_names: Vec<String>,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub validation_arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub initialization_options: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LspServerInstallationDescriptor {
    #[serde(default)]
    pub homebrew_formula: Option<String>,
    #[serde(default, rename = "officialDownloadURL")]
    pub official_download_url: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspProviderCapability {
    Run,
    LanguageServer,
    DebugAdapter,
    Formatting,
    Testing,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspActivationPolicy {
    OnDemand,
    Always,
}

impl Default for LspActivationPolicy {
    fn default() -> Self {
        Self::OnDemand
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LspProviderConfigDocument {
    #[serde(default, rename = "$schema")]
    _schema: Option<String>,
    #[serde(default = "default_config_version")]
    version: u32,
    #[serde(default)]
    providers: Vec<LspProviderPatch>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LspProviderPatch {
    id: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    file_extensions: Option<Vec<String>>,
    #[serde(default)]
    file_names: Option<Vec<String>>,
    #[serde(default)]
    file_name_prefixes: Option<Vec<String>>,
    #[serde(default)]
    capabilities: Option<Vec<LspProviderCapability>>,
    #[serde(default)]
    activation_policy: Option<LspActivationPolicy>,
    #[serde(default)]
    language_id: Option<String>,
    #[serde(default)]
    language_ids_by_extension: Option<BTreeMap<String, String>>,
    #[serde(default)]
    language_ids_by_file_name: Option<BTreeMap<String, String>>,
    #[serde(default)]
    language_server_launch: Option<LspServerLaunchDescriptor>,
    #[serde(default)]
    language_server_installation: Option<LspServerInstallationDescriptor>,
    #[serde(default)]
    disabled: bool,
}
pub fn provider_catalog_json(workspace_root: Option<&Path>) -> String {
    let catalog = provider_catalog(workspace_root);
    serde_json::to_string(&catalog)
        .unwrap_or_else(|_| "{\"version\":1,\"providers\":[]}".to_string())
}

pub fn provider_catalog(workspace_root: Option<&Path>) -> LspProviderCatalog {
    let mut diagnostics = Vec::new();
    let mut document = match parse_document(BUILTIN_LANGUAGE_PROVIDERS, "builtin:lsp") {
        Ok(document) => document,
        Err(message) => {
            diagnostics.push(LspProviderConfigDiagnostic {
                path: "builtin:lsp".to_string(),
                message,
            });
            LspProviderConfigDocument {
                _schema: None,
                version: 1,
                providers: Vec::new(),
            }
        }
    };

    if let Some(root) = workspace_root {
        let path = project_config_path(root);
        if path.is_file() {
            match std::fs::read_to_string(&path) {
                Ok(raw) => match parse_document(&raw, &path.display().to_string()) {
                    Ok(project_document) => {
                        document = merge_documents(document, project_document);
                    }
                    Err(message) => diagnostics.push(LspProviderConfigDiagnostic {
                        path: path.display().to_string(),
                        message,
                    }),
                },
                Err(error) => diagnostics.push(LspProviderConfigDiagnostic {
                    path: path.display().to_string(),
                    message: error.to_string(),
                }),
            }
        }
    }

    let mut providers = Vec::new();
    for patch in document.providers {
        if patch.disabled {
            continue;
        }
        providers.push(LspProviderDescriptor::from_patch(patch));
    }
    LspProviderCatalog {
        version: document.version,
        providers,
        diagnostics,
    }
}

fn parse_document(raw: &str, source: &str) -> Result<LspProviderConfigDocument, String> {
    serde_json::from_str(raw).map_err(|error| format!("{source}: {error}"))
}

fn merge_documents(
    mut base: LspProviderConfigDocument,
    project: LspProviderConfigDocument,
) -> LspProviderConfigDocument {
    base.version = project.version.max(base.version);
    for patch in project.providers {
        if let Some(existing) = base
            .providers
            .iter_mut()
            .find(|provider| provider.id == patch.id)
        {
            existing.apply(patch);
        } else {
            base.providers.push(patch);
        }
    }
    base
}

fn project_config_path(root: &Path) -> PathBuf {
    root.join(".lithe")
        .join("lsp")
        .join("language-providers.json")
}

fn default_config_version() -> u32 {
    1
}

impl LspProviderPatch {
    fn apply(&mut self, patch: LspProviderPatch) {
        if patch.display_name.is_some() {
            self.display_name = patch.display_name;
        }
        if patch.file_extensions.is_some() {
            self.file_extensions = patch.file_extensions;
        }
        if patch.file_names.is_some() {
            self.file_names = patch.file_names;
        }
        if patch.file_name_prefixes.is_some() {
            self.file_name_prefixes = patch.file_name_prefixes;
        }
        if patch.capabilities.is_some() {
            self.capabilities = patch.capabilities;
        }
        if patch.activation_policy.is_some() {
            self.activation_policy = patch.activation_policy;
        }
        if patch.language_id.is_some() {
            self.language_id = patch.language_id;
        }
        if patch.language_ids_by_extension.is_some() {
            self.language_ids_by_extension = patch.language_ids_by_extension;
        }
        if patch.language_ids_by_file_name.is_some() {
            self.language_ids_by_file_name = patch.language_ids_by_file_name;
        }
        if patch.language_server_launch.is_some() {
            self.language_server_launch = patch.language_server_launch;
        }
        if patch.language_server_installation.is_some() {
            self.language_server_installation = patch.language_server_installation;
        }
        self.disabled = patch.disabled;
    }
}

impl LspProviderDescriptor {
    fn from_patch(patch: LspProviderPatch) -> Self {
        let id = normalized_id(&patch.id);
        let display_name = patch
            .display_name
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| id.clone());
        let capabilities = patch.capabilities.unwrap_or_else(|| {
            vec![
                LspProviderCapability::LanguageServer,
                LspProviderCapability::Formatting,
            ]
        });
        Self {
            id: id.clone(),
            display_name,
            file_extensions: normalized_values(patch.file_extensions.unwrap_or_default(), true),
            file_names: normalized_values(patch.file_names.unwrap_or_default(), false),
            file_name_prefixes: normalized_values(
                patch.file_name_prefixes.unwrap_or_default(),
                false,
            ),
            capabilities,
            activation_policy: patch.activation_policy.unwrap_or_default(),
            language_id: patch.language_id.filter(|value| !value.trim().is_empty()),
            language_ids_by_extension: normalized_map(
                patch.language_ids_by_extension.unwrap_or_default(),
                true,
            ),
            language_ids_by_file_name: normalized_map(
                patch.language_ids_by_file_name.unwrap_or_default(),
                false,
            ),
            language_server_launch: patch.language_server_launch,
            language_server_installation: patch.language_server_installation,
        }
    }
}

fn normalized_id(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn normalized_values(values: Vec<String>, trim_dot: bool) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        let normalized = normalized_key(&value, trim_dot);
        if !normalized.is_empty() && !result.contains(&normalized) {
            result.push(normalized);
        }
    }
    result
}

fn normalized_map(values: BTreeMap<String, String>, trim_dot: bool) -> BTreeMap<String, String> {
    values
        .into_iter()
        .filter_map(|(key, value)| {
            let key = normalized_key(&key, trim_dot);
            if key.is_empty() || value.trim().is_empty() {
                None
            } else {
                Some((key, value))
            }
        })
        .collect()
}

fn normalized_key(value: &str, trim_dot: bool) -> String {
    let mut value = value.trim().to_ascii_lowercase();
    if trim_dot {
        value = value.trim_start_matches('.').to_string();
    }
    value
}
