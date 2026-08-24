//! JDT LS-specific policy kept outside the generic LSP client and transport.
//!
//! The adapter is deliberately pure: it describes launch arguments, provider
//! notifications, configuration responses, and virtual-source requests. The
//! process engine remains responsible for creating directories and performing
//! all I/O.

#![allow(dead_code)] // This module is an engine adapter seam; integration is intentionally separate.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const JAVA_PROVIDER_ID: &str = "java";
const JDT_URI_SCHEME: &str = "jdt";
const JDTLS_DATA_DIRECTORY: &str = "jdtls";
const JAVA_DECOMPILE_COMMAND: &str = "java.decompile";
const DID_CHANGE_CONFIGURATION_METHOD: &str = "workspace/didChangeConfiguration";
const LANGUAGE_STATUS_METHOD: &str = "language/status";
const SERVICE_READY_STATUS: &str = "ServiceReady";
const ERROR_STATUS: &str = "Error";

/// JDT LS readiness transition conveyed through its `language/status`
/// extension after the standard LSP initialize handshake.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) enum JdtReadinessSignal {
    /// Project import and Java service initialization have completed.
    Ready,
    /// JDT LS reported that its Java service could not become usable.
    Failed(String),
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JdtStartContext {
    pub provider_id: String,
    pub workspace_root: PathBuf,
    /// Engine-owned cache/state root. The adapter only derives a child path.
    pub data_root: PathBuf,
    #[serde(default)]
    pub selected_java_executable: Option<PathBuf>,
    #[serde(default)]
    pub arguments: Vec<String>,
    /// Opaque platform-provided digest of the build-system inputs that decide
    /// how JDT LS will import the workspace: root build files and the set of
    /// module directories, plus the bundled JDT LS version.
    ///
    /// JDT LS never invalidates its own `-data` state, so a workspace that
    /// gains or loses a module keeps resolving against a stale project model
    /// and silently loses cross-module navigation. Mixing this digest into the
    /// state-directory name gives structurally different workspaces different
    /// directories while keeping the previous one intact for a later switch
    /// back. `None` preserves the pre-fingerprint directory name so existing
    /// caches stay valid.
    #[serde(default)]
    pub workspace_fingerprint: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// Request for the deterministic directory key used by JDT LS state.
pub(crate) struct JdtWorkspaceKeyRequest {
    /// Absolute platform workspace path used only to derive a stable local key.
    pub workspace_root: String,
    /// Optional platform-computed build-structure digest mixed into the key.
    #[serde(default)]
    pub workspace_fingerprint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// Stable key returned to platform cache-maintenance adapters.
pub(crate) struct JdtWorkspaceKeyResponse {
    /// Lowercase SHA-256 key naming the workspace's JDT LS state directory.
    pub workspace_key: String,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JdtStartAdaptation {
    pub arguments: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_directory: Option<PathBuf>,
}

#[derive(Debug, Clone, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WorkspaceConfigurationItem {
    #[serde(default)]
    pub scope_uri: Option<String>,
    #[serde(default)]
    pub section: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProviderNotification {
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProviderLocation {
    pub uri: String,
    #[serde(default)]
    pub is_read_only: bool,
    #[serde(default)]
    pub display_path: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExecuteCommandParams {
    pub command: String,
    pub arguments: Vec<Value>,
}

/// Applies the JDT LS-owned part of a provider start plan.
///
/// `data_directory` is returned to the engine as a directory requirement; this
/// function never creates it. Arguments owned by this adapter are replaced so
/// repeated adaptation is deterministic and cannot leave two `-data` roots.
pub(crate) fn adapt_start(context: &JdtStartContext) -> JdtStartAdaptation {
    if !is_java_provider(&context.provider_id) {
        return JdtStartAdaptation {
            arguments: context.arguments.clone(),
            data_directory: None,
        };
    }

    let data_directory = context
        .data_root
        .join(JDTLS_DATA_DIRECTORY)
        .join(workspace_key(
            &context.workspace_root,
            context.workspace_fingerprint.as_deref(),
        ));
    let mut arguments = without_jdt_owned_arguments(&context.arguments);
    if let Some(java_executable) = &context.selected_java_executable {
        arguments.push("--java-executable".to_string());
        arguments.push(java_executable.to_string_lossy().into_owned());
    }
    arguments.extend([
        "--jvm-arg=-Xms256m".to_string(),
        "--jvm-arg=-Xmx1024m".to_string(),
        "-data".to_string(),
        data_directory.to_string_lossy().into_owned(),
    ]);

    JdtStartAdaptation {
        arguments,
        data_directory: Some(data_directory),
    }
}

/// Adds the JDT LS client extensions required for class-file navigation.
///
/// Catalog-provided options are preserved, while the provider-owned capability
/// is authoritative because virtual class files cannot be opened without it.
pub(crate) fn adapt_initialization_options(
    provider_id: &str,
    initialization_options: Option<Value>,
) -> Option<Value> {
    if !is_java_provider(provider_id) {
        return initialization_options;
    }

    let mut options = match initialization_options {
        Some(Value::Object(options)) => options,
        _ => Map::new(),
    };
    let extended = options
        .entry("extendedClientCapabilities")
        .or_insert_with(|| json!({}));
    if !extended.is_object() {
        *extended = json!({});
    }
    extended
        .as_object_mut()
        .expect("the extended capabilities were normalized to an object")
        .insert("classFileContentsSupport".to_string(), Value::Bool(true));

    Some(Value::Object(options))
}

/// Returns JDT LS configuration values in the same order as the requested
/// `workspace/configuration` items. `None` delegates non-Java providers to the
/// generic engine behavior.
pub(crate) fn workspace_configuration(
    provider_id: &str,
    items: &[WorkspaceConfigurationItem],
) -> Option<Vec<Value>> {
    if !is_java_provider(provider_id) {
        return None;
    }
    Some(
        items
            .iter()
            .map(|item| java_configuration_for_section(item.section.as_deref()))
            .collect(),
    )
}

/// Notification the engine sends after the generic `initialized` handshake.
pub(crate) fn initialized_notification(provider_id: &str) -> Option<ProviderNotification> {
    is_java_provider(provider_id).then(|| ProviderNotification {
        method: DID_CHANGE_CONFIGURATION_METHOD.to_string(),
        params: json!({
            "settings": java_settings()
        }),
    })
}

/// Returns whether the provider has a readiness phase after standard LSP
/// initialization. JDT LS cannot safely serve semantic requests until its Java
/// project import publishes `ServiceReady`.
pub(crate) fn waits_for_service_ready(provider_id: &str) -> bool {
    is_java_provider(provider_id)
}

/// Reduces one JDT LS status notification to the readiness transition owned by
/// the generic process engine. Other providers and informational statuses do
/// not affect lifecycle state.
pub(crate) fn readiness_signal(
    provider_id: &str,
    method: Option<&str>,
    params: Option<&Value>,
) -> Option<JdtReadinessSignal> {
    if !is_java_provider(provider_id) || method != Some(LANGUAGE_STATUS_METHOD) {
        return None;
    }
    let params = params?.as_object()?;
    match params.get("type").and_then(Value::as_str) {
        Some(SERVICE_READY_STATUS) => Some(JdtReadinessSignal::Ready),
        Some(ERROR_STATUS) => Some(JdtReadinessSignal::Failed(
            params
                .get("message")
                .and_then(Value::as_str)
                .filter(|message| !message.trim().is_empty())
                .unwrap_or("JDT LS reported an unknown Java service error.")
                .to_string(),
        )),
        _ => None,
    }
}

/// Marks JDT virtual locations as read-only and gives them a source-like path.
/// File locations and locations from other providers pass through unchanged.
pub(crate) fn normalize_location(
    provider_id: &str,
    mut location: ProviderLocation,
) -> ProviderLocation {
    if is_java_provider(provider_id) && has_uri_scheme(&location.uri, JDT_URI_SCHEME) {
        location.is_read_only = true;
        location.display_path = jdt_display_path(&location.uri);
    }
    location
}

/// Converts a JDT virtual URI into `workspace/executeCommand` parameters. The
/// generic engine owns request IDs and JSON-RPC framing.
pub(crate) fn virtual_source_resolve_params(
    provider_id: &str,
    uri: &str,
) -> Option<ExecuteCommandParams> {
    if !is_virtual_source_uri(provider_id, uri) {
        return None;
    }
    Some(ExecuteCommandParams {
        command: JAVA_DECOMPILE_COMMAND.to_string(),
        arguments: vec![json!(uri)],
    })
}

/// Returns whether a URI names a virtual source document owned by JDT LS.
pub(crate) fn is_virtual_source_uri(provider_id: &str, uri: &str) -> bool {
    is_java_provider(provider_id) && has_uri_scheme(uri, JDT_URI_SCHEME)
}

/// Extracts the text shape returned by JDT LS for `java.decompile`.
/// Different JDT LS versions return either the string directly or wrap it in
/// a `content` member.
pub(crate) fn virtual_source_content(provider_id: &str, result: &Value) -> Option<String> {
    if !is_java_provider(provider_id) {
        return None;
    }
    result
        .as_str()
        .or_else(|| result.get("content").and_then(Value::as_str))
        .filter(|content| !content.is_empty())
        .map(str::to_string)
}

fn is_java_provider(provider_id: &str) -> bool {
    provider_id.trim().eq_ignore_ascii_case(JAVA_PROVIDER_ID)
}

fn without_jdt_owned_arguments(arguments: &[String]) -> Vec<String> {
    let mut retained = Vec::with_capacity(arguments.len());
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        let owns_following_value = argument == "--java-executable" || argument == "-data";
        let owns_inline_value = argument.starts_with("--java-executable=")
            || argument.starts_with("-data=")
            || argument.starts_with("--jvm-arg=-Xms")
            || argument.starts_with("--jvm-arg=-Xmx");
        if owns_following_value {
            index += usize::from(index + 1 < arguments.len()) + 1;
        } else {
            if !owns_inline_value {
                retained.push(argument.clone());
            }
            index += 1;
        }
    }
    retained
}

fn java_settings() -> Value {
    json!({
        "java": {
            "eclipse": {
                "downloadSources": true
            },
            "maven": {
                "downloadSources": true
            },
            "configuration": {
                "updateBuildConfiguration": "automatic"
            },
            "inlayHints": {
                "parameterNames": {
                    "enabled": "all"
                }
            },
            // Show "N implementations" code lens above interface methods and classes.
            "implementationsCodeLens": {
                "enabled": true
            },
            // Show "N references" code lens above declarations.
            "referencesCodeLens": {
                "enabled": true
            }
        }
    })
}

fn java_configuration_for_section(section: Option<&str>) -> Value {
    match section {
        Some("java") => json!({
            "eclipse": {
                "downloadSources": true
            },
            "maven": {
                "downloadSources": true
            },
            "configuration": {
                "updateBuildConfiguration": "automatic"
            },
            "inlayHints": {
                "parameterNames": {
                    "enabled": "all"
                }
            },
            "implementationsCodeLens": {
                "enabled": true
            },
            "referencesCodeLens": {
                "enabled": true
            }
        }),
        Some("java.inlayHints") => json!({
            "parameterNames": {
                "enabled": "all"
            }
        }),
        Some("java.inlayHints.parameterNames") => json!({ "enabled": "all" }),
        Some("java.inlayHints.parameterNames.enabled") => json!("all"),
        Some("java.eclipse") => json!({ "downloadSources": true }),
        Some("java.eclipse.downloadSources") => json!(true),
        Some("java.maven") => json!({ "downloadSources": true }),
        Some("java.maven.downloadSources") => json!(true),
        Some("java.configuration") => json!({ "updateBuildConfiguration": "automatic" }),
        Some("java.configuration.updateBuildConfiguration") => json!("automatic"),
        Some("java.implementationsCodeLens") => json!({ "enabled": true }),
        Some("java.implementationsCodeLens.enabled") => json!(true),
        Some("java.referencesCodeLens") => json!({ "enabled": true }),
        Some("java.referencesCodeLens.enabled") => json!(true),
        _ => Value::Null,
    }
}

/// Resolves a platform request through the same key algorithm used at startup.
pub(crate) fn resolve_workspace_key(request: JdtWorkspaceKeyRequest) -> JdtWorkspaceKeyResponse {
    JdtWorkspaceKeyResponse {
        workspace_key: workspace_key(
            Path::new(&request.workspace_root),
            request.workspace_fingerprint.as_deref(),
        ),
    }
}

/// Hashes the normalized workspace identity and optional structural fingerprint.
pub(crate) fn workspace_key(workspace_root: &Path, fingerprint: Option<&str>) -> String {
    let mut identity = normalized_workspace_identity(workspace_root);
    // Mix the structural fingerprint in as a null-delimited suffix so changes
    // to build files or the module set produce a fresh state directory without
    // touching the previous one.  Absent fingerprint keeps the legacy key.
    if let Some(fp) = fingerprint {
        identity.push('\x00');
        identity.push_str(fp);
    }
    let digest = Sha256::digest(identity.as_bytes());
    let mut key = String::with_capacity(digest.len() * 2);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in digest {
        key.push(HEX[(byte >> 4) as usize] as char);
        key.push(HEX[(byte & 0x0f) as usize] as char);
    }
    key
}

fn normalized_workspace_identity(workspace_root: &Path) -> String {
    let raw = workspace_root.to_string_lossy().replace('\\', "/");
    let bytes = raw.as_bytes();
    let has_drive = bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':';
    let is_unc = raw.starts_with("//");
    let (prefix, remainder, is_absolute, protected_components, fold_case) = if has_drive {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        let remainder = &raw[2..];
        (
            format!("{drive}:"),
            remainder,
            remainder.starts_with('/'),
            0,
            true,
        )
    } else if is_unc {
        ("//".to_string(), raw.trim_start_matches('/'), true, 2, true)
    } else if raw.starts_with('/') {
        ("/".to_string(), raw.trim_start_matches('/'), true, 0, false)
    } else {
        (String::new(), raw.as_str(), false, 0, false)
    };

    let mut components: Vec<String> = Vec::new();
    for component in remainder.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if components.len() > protected_components
                    && components.last().is_some_and(|value| value != "..")
                {
                    components.pop();
                } else if !is_absolute {
                    components.push("..".to_string());
                }
            }
            value => components.push(if fold_case {
                value.to_lowercase()
            } else {
                value.to_string()
            }),
        }
    }

    let joined = components.join("/");
    match (prefix.as_str(), joined.is_empty(), is_absolute) {
        ("", true, _) => ".".to_string(),
        ("/", true, _) => "/".to_string(),
        ("//", true, _) => "//".to_string(),
        (prefix, true, _) => prefix.to_string(),
        ("", false, _) => joined,
        ("/", false, _) => format!("/{joined}"),
        ("//", false, _) => format!("//{joined}"),
        (prefix, false, true) => format!("{prefix}/{joined}"),
        (prefix, false, false) => format!("{prefix}{joined}"),
    }
}

fn has_uri_scheme(uri: &str, expected: &str) -> bool {
    uri.split_once(':')
        .is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case(expected))
}

fn jdt_display_path(uri: &str) -> Option<String> {
    let (_, remainder) = uri.split_once(':')?;
    let path = if let Some(with_authority) = remainder.strip_prefix("//") {
        with_authority
            .find('/')
            .map(|index| &with_authority[index + 1..])?
    } else {
        remainder.trim_start_matches('/')
    };
    let path = path.split_once(['?', '#']).map_or(path, |(value, _)| value);
    let decoded = percent_decode(path);
    let mut components: Vec<_> = decoded
        .split('/')
        .filter(|component| !component.is_empty())
        .map(str::to_string)
        .collect();
    let last = components.last_mut()?;
    if let Some(class_name) = last.strip_suffix(".class") {
        *last = format!("{class_name}.java");
    }
    Some(components.join("/"))
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                decoded.push((high << 4) | low);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn java_start_context() -> JdtStartContext {
        JdtStartContext {
            provider_id: "java".to_string(),
            workspace_root: PathBuf::from("/workspace/project"),
            data_root: PathBuf::from("/cache/Lithe"),
            selected_java_executable: Some(PathBuf::from("/jdk/bin/java")),
            arguments: vec!["--stdio".to_string()],
            workspace_fingerprint: None,
        }
    }

    #[test]
    fn java_start_adds_runtime_memory_and_unique_data_arguments() {
        let context = java_start_context();
        let adapted = adapt_start(&context);
        let data_directory = adapted.data_directory.as_ref().unwrap();

        assert_eq!(
            data_directory.parent().unwrap(),
            Path::new("/cache/Lithe/jdtls")
        );
        assert_eq!(
            data_directory.file_name().unwrap().to_string_lossy().len(),
            64
        );
        assert_eq!(
            adapted.arguments,
            vec![
                "--stdio",
                "--java-executable",
                "/jdk/bin/java",
                "--jvm-arg=-Xms256m",
                "--jvm-arg=-Xmx1024m",
                "-data",
                data_directory.to_string_lossy().as_ref()
            ]
        );
    }

    #[test]
    fn java_start_replaces_adapter_owned_arguments_and_is_stable() {
        let mut context = java_start_context();
        context.arguments = vec![
            "--java-executable".to_string(),
            "/old/java".to_string(),
            "--jvm-arg=-Xms2g".to_string(),
            "--jvm-arg=-Xmx4g".to_string(),
            "--jvm-arg=-Duser.language=en".to_string(),
            "-data".to_string(),
            "/old/data".to_string(),
        ];
        let first = adapt_start(&context);
        context.arguments = first.arguments.clone();
        let second = adapt_start(&context);

        assert_eq!(first, second);
        assert!(first
            .arguments
            .contains(&"--jvm-arg=-Duser.language=en".to_string()));
        assert!(!first.arguments.contains(&"/old/java".to_string()));
        assert!(!first.arguments.contains(&"/old/data".to_string()));
    }

    #[test]
    fn workspace_identity_is_lexical_cross_platform_and_unique() {
        assert_eq!(
            workspace_key(Path::new(r"C:\Users\Ada\Project\.\src\.."), None),
            workspace_key(Path::new("c:/users/ada/project"), None)
        );
        assert_eq!(
            workspace_key(Path::new("/workspace/project/./src/.."), None),
            workspace_key(Path::new("/workspace/project"), None)
        );
        assert_ne!(
            workspace_key(Path::new("/workspace/project"), None),
            workspace_key(Path::new("/workspace/other"), None)
        );
    }

    #[test]
    fn workspace_fingerprint_changes_data_directory() {
        let mut context = java_start_context();
        let without = adapt_start(&context).data_directory.unwrap();
        context.workspace_fingerprint = Some("pom=111|modules=core,web|jdtls=1.38.0".to_string());
        let first = adapt_start(&context).data_directory.unwrap();
        context.workspace_fingerprint = Some("pom=222|modules=core,web|jdtls=1.38.0".to_string());
        let changed = adapt_start(&context).data_directory.unwrap();

        assert_ne!(without, first);
        assert_ne!(first, changed);
        assert_eq!(without.parent(), first.parent());
        assert_eq!(first.parent(), changed.parent());
        assert_eq!(without.file_name().unwrap().to_string_lossy().len(), 64);
        assert_eq!(first.file_name().unwrap().to_string_lossy().len(), 64);
        assert_eq!(changed.file_name().unwrap().to_string_lossy().len(), 64);

        context.workspace_fingerprint = Some("pom=111|modules=core,web|jdtls=1.38.0".to_string());
        let repeated = adapt_start(&context).data_directory.unwrap();
        assert_eq!(first, repeated);
    }

    #[test]
    fn workspace_key_request_uses_the_same_compatibility_algorithm() {
        let response = resolve_workspace_key(JdtWorkspaceKeyRequest {
            workspace_root: "/workspace/project".to_string(),
            workspace_fingerprint: Some("pom=111|jdtls=1.38.0".to_string()),
        });

        assert_eq!(
            response.workspace_key,
            workspace_key(
                Path::new("/workspace/project"),
                Some("pom=111|jdtls=1.38.0")
            )
        );
    }

    #[test]
    fn non_java_start_is_a_generic_noop() {
        let mut context = java_start_context();
        context.provider_id = "rust".to_string();
        let adapted = adapt_start(&context);

        assert_eq!(adapted.arguments, context.arguments);
        assert_eq!(adapted.data_directory, None);
        assert!(workspace_configuration("rust", &[]).is_none());
        assert!(initialized_notification("rust").is_none());
        assert!(virtual_source_resolve_params("rust", "jdt://contents/A.class").is_none());
        assert_eq!(
            adapt_initialization_options("rust", Some(json!({ "custom": true }))),
            Some(json!({ "custom": true }))
        );
        let location = ProviderLocation {
            uri: "jdt://contents/A.class".to_string(),
            is_read_only: false,
            display_path: None,
        };
        assert_eq!(normalize_location("rust", location.clone()), location);
    }

    #[test]
    fn java_initialization_enables_class_file_content_without_losing_catalog_options() {
        let options = adapt_initialization_options(
            "JAVA",
            Some(json!({
                "workspace": { "custom": true },
                "extendedClientCapabilities": {
                    "customCapability": true,
                    "classFileContentsSupport": false
                }
            })),
        )
        .unwrap();

        assert_eq!(options["workspace"]["custom"], true);
        assert_eq!(
            options["extendedClientCapabilities"]["customCapability"],
            true
        );
        assert_eq!(
            options["extendedClientCapabilities"]["classFileContentsSupport"],
            true
        );
    }

    #[test]
    fn java_workspace_configuration_matches_each_section_shape() {
        let items = [
            "java",
            "java.eclipse.downloadSources",
            "java.maven.downloadSources",
            "java.inlayHints",
            "java.inlayHints.parameterNames",
            "java.inlayHints.parameterNames.enabled",
            "java.implementationsCodeLens",
            "java.implementationsCodeLens.enabled",
            "java.referencesCodeLens",
            "java.referencesCodeLens.enabled",
            "java.unknown",
        ]
        .map(|section| WorkspaceConfigurationItem {
            scope_uri: Some("file:///workspace/project".to_string()),
            section: Some(section.to_string()),
        });
        let values = workspace_configuration("java", &items).unwrap();

        assert_eq!(values[0]["inlayHints"]["parameterNames"]["enabled"], "all");
        assert_eq!(values[0]["eclipse"]["downloadSources"], true);
        assert_eq!(values[0]["maven"]["downloadSources"], true);
        assert_eq!(values[0]["implementationsCodeLens"]["enabled"], true);
        assert_eq!(values[0]["referencesCodeLens"]["enabled"], true);
        assert_eq!(values[1], true); // java.eclipse.downloadSources
        assert_eq!(values[2], true); // java.maven.downloadSources
        assert_eq!(values[3]["parameterNames"]["enabled"], "all"); // java.inlayHints
        assert_eq!(values[4]["enabled"], "all"); // java.inlayHints.parameterNames
        assert_eq!(values[5], "all"); // java.inlayHints.parameterNames.enabled
        assert_eq!(values[6]["enabled"], true); // java.implementationsCodeLens
        assert_eq!(values[7], true); // java.implementationsCodeLens.enabled
        assert_eq!(values[8]["enabled"], true); // java.referencesCodeLens
        assert_eq!(values[9], true); // java.referencesCodeLens.enabled
        assert_eq!(values[10], Value::Null); // java.unknown
    }

    #[test]
    fn java_initialized_notification_publishes_inlay_settings() {
        let notification = initialized_notification("JAVA").unwrap();

        assert_eq!(notification.method, "workspace/didChangeConfiguration");
        assert_eq!(
            notification.params["settings"]["java"]["inlayHints"]["parameterNames"]["enabled"],
            "all"
        );
        assert_eq!(
            notification.params["settings"]["java"]["eclipse"]["downloadSources"],
            true
        );
        assert_eq!(
            notification.params["settings"]["java"]["maven"]["downloadSources"],
            true
        );
        assert_eq!(
            notification.params["settings"]["java"]["implementationsCodeLens"]["enabled"],
            true
        );
        assert_eq!(
            notification.params["settings"]["java"]["referencesCodeLens"]["enabled"],
            true
        );
    }

    #[test]
    fn jdt_location_is_read_only_with_a_source_display_path() {
        let location = normalize_location(
            "java",
            ProviderLocation {
                uri: "jdt://contents/java.base/java/util/Map%24Entry.class?=demo".to_string(),
                is_read_only: false,
                display_path: None,
            },
        );

        assert!(location.is_read_only);
        assert_eq!(
            location.display_path.as_deref(),
            Some("java.base/java/util/Map$Entry.java")
        );

        let unchanged = normalize_location(
            "java",
            ProviderLocation {
                uri: "file:///workspace/Main.java".to_string(),
                is_read_only: false,
                display_path: Some("Main.java".to_string()),
            },
        );
        assert!(!unchanged.is_read_only);
        assert_eq!(unchanged.display_path.as_deref(), Some("Main.java"));
    }

    #[test]
    fn virtual_source_uses_java_decompile_execute_command_params() {
        let uri = "jdt://contents/java.base/java/lang/String.class";
        let params = virtual_source_resolve_params("java", uri).unwrap();
        let encoded = serde_json::to_value(params).unwrap();

        assert_eq!(encoded["command"], "java.decompile");
        assert_eq!(encoded["arguments"], json!([uri]));
        assert!(virtual_source_resolve_params("java", "file:///tmp/String.java").is_none());
    }

    #[test]
    fn virtual_source_content_accepts_supported_jdt_result_shapes() {
        assert_eq!(
            virtual_source_content("java", &json!("class String {}")),
            Some("class String {}".to_string())
        );
        assert_eq!(
            virtual_source_content("java", &json!({ "content": "class Object {}" })),
            Some("class Object {}".to_string())
        );
        assert!(virtual_source_content("go", &json!("class String {}")).is_none());
        assert!(virtual_source_content("java", &Value::Null).is_none());
    }
}
