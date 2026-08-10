use crate::error::{invalid_relative_path, CoreError, ErrorCode};
use crate::java::JavaRunConfigurationsRequest;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

const VERSION: u32 = 2;
const LEGACY_VERSION: u32 = 1;
/// Toolchain requirements and `project.json` are separate documents that happen
/// to live under `.lithe`. Their schema did not change with run-config v2, so
/// they keep their own version and must not be validated against `VERSION`.
const SIDECAR_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateRequest {
    pub root: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub module_paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveRequest {
    pub root: String,
    #[serde(default)]
    pub toolchain_candidates: Vec<ToolchainCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolchainCandidate {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub vendor: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchPlanRequest {
    pub root: String,
    pub configuration_id: String,
    #[serde(default)]
    pub current_file: Option<String>,
    #[serde(default)]
    pub class_path: Option<String>,
    #[serde(default)]
    pub debug_port: Option<u16>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateOptionsRequest {
    pub root: String,
    pub scope: String,
    pub configuration_id: String,
    #[serde(default)]
    pub working_directory: String,
    #[serde(default)]
    pub jvm_arguments: String,
    /// Common program arguments. `programArguments` remains a wire alias for
    /// clients from before the generic run-options migration.
    #[serde(default, alias = "programArguments")]
    pub arguments: String,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub maven_profiles: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateUserConfigurationRequest {
    pub root: String,
    pub scope: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub module: String,
    #[serde(default)]
    pub main_class: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RunConfigurationDocument {
    pub version: u32,
    #[serde(default)]
    pub generator: Option<GeneratorMetadata>,
    #[serde(default)]
    pub configurations: Vec<RunConfiguration>,
}

/// Rewrites a v1 document in place into the v2 shape.
///
/// Ids are preserved verbatim. The three-layer merge matches configurations by
/// id, so rewriting them would silently detach every override a user wrote in
/// the team or local layer -- a failure with no error message.
pub fn migrate_document_value(document: &mut Value) -> bool {
    if document.get("version").and_then(Value::as_u64) != Some(LEGACY_VERSION as u64) {
        return false;
    }
    if let Some(items) = document
        .get_mut("configurations")
        .and_then(Value::as_array_mut)
    {
        for item in items {
            migrate_configuration_value(item);
        }
    }
    document["version"] = json!(VERSION);
    true
}

fn migrate_configuration_value(item: &mut Value) {
    let Some(object) = item.as_object_mut() else {
        return;
    };
    let legacy_type = object
        .remove("type")
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_else(|| "java.current-file".to_string());

    let mut maven = serde_json::Map::new();
    for (legacy_key, target_key) in [
        ("mainClass", "mainClass"),
        ("module", "module"),
        ("jvmArguments", "jvmArguments"),
        ("programArguments", "programArguments"),
        ("mavenProfiles", "profiles"),
    ] {
        if let Some(value) = object.remove(legacy_key) {
            let is_empty = value
                .as_array()
                .map(|items| items.is_empty())
                .unwrap_or(false);
            if !value.is_null() && !is_empty {
                maven.insert(target_key.to_string(), value);
            }
        }
    }
    if let Some(working_directory) = object.remove("workingDirectory") {
        object.insert("cwd".to_string(), working_directory);
    }
    if !maven.is_empty() {
        object
            .entry("extensions")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .map(|extensions| extensions.insert("maven".to_string(), Value::Object(maven)));
    }

    let execution = match legacy_type.as_str() {
        "spring-boot.maven" => "service",
        "java.current-file" => "application",
        _ => "task",
    };
    object.insert("provider".to_string(), json!(legacy_type));
    object.insert("execution".to_string(), json!(execution));
    object.insert("confidence".to_string(), json!("native"));
    object.insert("debug".to_string(), json!({ "adapter": "jdwp" }));
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneratorMetadata {
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub inputs: BTreeMap<String, String>,
}

/// How a configuration behaves once started.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Execution {
    /// User-launched program whose lifetime is not assumed to be long-running.
    Application,
    /// Long-running process: has stop semantics and may expose a port.
    Service,
    /// Runs to completion and exits.
    Task,
    /// Orchestrates other configurations by id.
    Group,
}

impl Default for Execution {
    fn default() -> Self {
        Self::Application
    }
}

/// How the configuration was discovered. Ranks dedupe winners: a native parse
/// beats a manifest declaration, which beats an entry-point guess.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Heuristic,
    Declared,
    Native,
}

impl Default for Confidence {
    fn default() -> Self {
        Self::Declared
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugCapability {
    pub adapter: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunConfiguration {
    pub id: String,
    pub name: String,
    /// Open namespaced discriminator, e.g. `maven.module`, `npm.script`.
    /// Deliberately not an enum: new ecosystems must not require a contract change.
    pub provider: String,
    #[serde(default)]
    pub execution: Execution,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default = "dot")]
    pub cwd: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub confidence: Confidence,
    #[serde(default)]
    pub toolchains: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug: Option<DebugCapability>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub members: Vec<String>,
    /// Ecosystem-specific payload keyed by namespace (`maven`, `npm`, ...).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub extensions: BTreeMap<String, Value>,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

fn dot() -> String {
    ".".to_string()
}

/// Accessors for the `maven` extension namespace. Keeps JDWP and Spring Boot
/// launch assembly working after the fields moved out of the common shape.
impl RunConfiguration {
    pub fn extension_string(&self, namespace: &str, key: &str) -> Option<String> {
        self.extensions
            .get(namespace)?
            .get(key)?
            .as_str()
            .map(str::to_string)
    }

    pub fn main_class(&self) -> Option<String> {
        self.extension_string("maven", "mainClass")
    }

    pub fn module(&self) -> Option<String> {
        self.extension_string("maven", "module")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolchainRequirementsDocument {
    pub version: u32,
    #[serde(default)]
    pub toolchains: BTreeMap<String, ToolchainRequirement>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolchainRequirement {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub minimum_version: Option<String>,
    #[serde(default)]
    pub preferred_vendor: Option<String>,
    #[serde(default)]
    pub wrapper: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub java: Option<String>,
}

pub fn inspect(request: InspectRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let generated = read_document(&root, "run/generated.json")?;
    let requirements = read_requirements(&root)?;
    for relative in [
        "run/configurations.json",
        "run/local.json",
        "toolchains/local.json",
        "project.json",
    ] {
        if let Some(document) = read_document_value(&root, relative)? {
            if relative.starts_with("run/") {
                validate_version_value(&document)?;
                configuration_ids(&document)?;
            } else {
                validate_sidecar_version_value(&document)?;
                if relative == "toolchains/local.json"
                    && document
                        .get("toolchains")
                        .and_then(Value::as_object)
                        .is_none()
                {
                    return Err(CoreError::new(
                        ErrorCode::ParseFailed,
                        "Local toolchains must contain a toolchains object",
                    ));
                }
            }
        }
    }
    if let Some(document) = generated.as_ref() {
        validate_version(document.version)?;
    }
    if let Some(document) = requirements.as_ref() {
        validate_sidecar_version(document.version)?;
    }
    let mut diagnostics = Vec::new();
    if let Some(metadata) = generated
        .as_ref()
        .and_then(|document| document.generator.as_ref())
    {
        let current_inputs = project_inputs(&root)?;
        if metadata.fingerprint != fingerprint_from_inputs(&current_inputs) {
            let message = if metadata.inputs.is_empty() {
                "Project inputs changed after run configuration generation".to_string()
            } else {
                input_change_summary(&metadata.inputs, &current_inputs)
            };
            diagnostics.push(json!({
                "code": "staleFingerprint",
                "message": message
            }));
        }
    }
    Ok(json!({
        "status": if generated.is_some() { "ready" } else { "missing" },
        "generated": generated,
        "toolchainRequirements": requirements,
        "diagnostics": diagnostics,
        "paths": { "generated": ".lithe/run/generated.json", "configurations": ".lithe/run/configurations.json", "local": ".lithe/run/local.json" }
    }))
}

pub fn generate(request: GenerateRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let has_java_sources = request
        .paths
        .iter()
        .any(|path| path.to_lowercase().ends_with(".java"));
    let has_maven_project = root.join("pom.xml").is_file() || root.join("mvnw").is_file();
    let has_java_ecosystem = has_java_sources || has_maven_project;
    let module_paths = inferred_maven_module_paths(&root, &request.paths, request.module_paths);
    let scanned = crate::java::run_configurations(JavaRunConfigurationsRequest {
        root: request.root.clone(),
        paths: request.paths,
        module_paths,
    })?;
    let java_entry_count = scanned.configurations.len();
    let mut configurations = scanned
        .configurations
        .into_iter()
        .map(|value| {
            let provider = match value.kind.as_str() {
                "springBoot" => "spring-boot.maven",
                "javaMain" => "java.main",
                "mavenModule" => "maven.module",
                _ => "java.current-file",
            };
            let mut maven = serde_json::Map::new();
            maven.insert(
                "module".to_string(),
                json!(value.module_path.unwrap_or_else(|| ".".to_string())),
            );
            if let Some(main_class) = value.main_class {
                maven.insert("mainClass".to_string(), json!(main_class));
            }
            RunConfiguration {
                id: value.id,
                name: value.name,
                provider: provider.to_string(),
                execution: match provider {
                    "spring-boot.maven" => Execution::Service,
                    "java.main" | "java.current-file" => Execution::Application,
                    _ => Execution::Task,
                },
                command: None,
                args: Vec::new(),
                cwd: ".".to_string(),
                env: BTreeMap::new(),
                confidence: Confidence::Native,
                toolchains: if provider == "java.current-file" {
                    [("java".to_string(), "project-jdk".to_string())]
                        .into_iter()
                        .collect()
                } else {
                    [
                        ("java".to_string(), "project-jdk".to_string()),
                        ("maven".to_string(), "project-maven".to_string()),
                    ]
                    .into_iter()
                    .collect()
                },
                debug: (provider != "java.main").then(|| DebugCapability {
                    adapter: "jdwp".to_string(),
                }),
                members: Vec::new(),
                extensions: [("maven".to_string(), Value::Object(maven))]
                    .into_iter()
                    .collect(),
                disabled: false,
                source: None,
            }
        })
        .collect::<Vec<_>>();
    if has_java_sources {
        configurations.push(RunConfiguration {
            id: "current-file".to_string(),
            name: "Current File".to_string(),
            provider: "java.current-file".to_string(),
            execution: Execution::Application,
            command: None,
            args: Vec::new(),
            cwd: ".".to_string(),
            env: BTreeMap::new(),
            confidence: Confidence::Native,
            toolchains: [("java".to_string(), "project-jdk".to_string())]
                .into_iter()
                .collect(),
            debug: Some(DebugCapability {
                adapter: "jdwp".to_string(),
            }),
            members: Vec::new(),
            extensions: [("maven".to_string(), json!({ "module": "." }))]
                .into_iter()
                .collect(),
            disabled: false,
            source: None,
        });
    }
    let inputs = project_inputs(&root)?;
    // Detectors run after the Java scan so a Java configuration always keeps its
    // id: `detected_configurations` skips ids the Java pass already claimed
    // rather than overwriting them, which would detach team and local overrides.
    let claimed = configurations
        .iter()
        .map(|item| item.id.clone())
        .collect::<BTreeSet<_>>();
    let detected = detected_configurations(&root, &claimed)?;
    // Counts real entry points, not documents: the always-present "Current File"
    // fallback is excluded so an empty project still reports zero and the UI can
    // say so, while a detected npm service correctly reports one.
    let entry_count = java_entry_count + detected.len();
    configurations.extend(detected);
    let requirements = detect_requirements(&root, has_java_ecosystem, &configurations)?;
    let generated = RunConfigurationDocument {
        version: VERSION,
        generator: Some(GeneratorMetadata {
            fingerprint: fingerprint_from_inputs(&inputs),
            inputs,
        }),
        configurations,
    };
    Ok(
        json!({ "generated": generated, "toolchainRequirements": requirements, "entryCount": entry_count }),
    )
}

/// Translates detector output into the run-configuration contract.
///
/// Detected entries are always process-based: the detector resolved the command,
/// so there is no toolchain binding and no ecosystem-specific launch assembly.
/// That is what keeps a new ecosystem from needing changes in `create_launch_plan`.
fn detected_configurations(
    root: &Path,
    claimed: &BTreeSet<String>,
) -> Result<Vec<RunConfiguration>, CoreError> {
    Ok(crate::detectors::detect_all(root)?
        .into_iter()
        .map(|item| RunConfiguration {
            id: item.id(),
            name: item.name,
            provider: item.provider,
            execution: item.execution,
            command: Some(item.command),
            args: item.args,
            cwd: item.cwd,
            env: item.env,
            confidence: item.confidence,
            toolchains: BTreeMap::new(),
            debug: None,
            members: Vec::new(),
            extensions: item.extensions,
            disabled: false,
            source: Some(item.source),
        })
        .filter(|item| !claimed.contains(&item.id))
        .filter(|item| validate_configuration(item).is_ok())
        .collect())
}

fn inferred_maven_module_paths(
    root: &Path,
    paths: &[String],
    configured: Vec<String>,
) -> Vec<String> {
    let mut modules = configured.into_iter().collect::<BTreeSet<_>>();
    for path in paths {
        if !path.to_lowercase().ends_with(".java") {
            continue;
        }
        let Some(relative) = normalize_project_relative(path) else {
            continue;
        };
        let mut directory = root.join(relative).parent().map(Path::to_path_buf);
        while let Some(candidate) = directory {
            if candidate == root {
                break;
            }
            if candidate.join("pom.xml").is_file() {
                if let Ok(relative) = candidate.strip_prefix(root) {
                    modules.insert(relative.to_string_lossy().replace('\\', "/"));
                }
                break;
            }
            directory = candidate.parent().map(Path::to_path_buf);
        }
    }
    modules.into_iter().collect()
}

fn normalize_project_relative(value: &str) -> Option<PathBuf> {
    let path = Path::new(value);
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return None;
    }
    Some(path.to_path_buf())
}

pub fn resolve(request: ResolveRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let generated = read_document_value(&root, "run/generated.json")?.ok_or_else(|| {
        CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Run configuration has not been generated",
        )
    })?;
    let team = read_document_value(&root, "run/configurations.json")?
        .unwrap_or_else(|| json!({"version": VERSION, "configurations": []}));
    let local = read_document_value(&root, "run/local.json")?
        .unwrap_or_else(|| json!({"version": VERSION, "configurations": []}));
    let manifest = read_document_value(&root, "project.json")?;
    validate_version_value(&generated)?;
    validate_version_value(&team)?;
    validate_version_value(&local)?;
    if let Some(manifest) = manifest.as_ref() {
        validate_sidecar_version_value(manifest)?;
    }
    let generated_ids = configuration_ids(&generated)?;
    let mut diagnostics = Vec::new();
    diagnostics.extend(toolchain_diagnostics(&root, &request.toolchain_candidates)?);
    for source in [&team, &local] {
        for id in configuration_ids(source)?.keys() {
            if !generated_ids.contains_key(id) && !id.starts_with("user:") {
                diagnostics.push(json!({
                    "id": id,
                    "code": "orphanedOverride",
                    "message": "Override no longer matches an automatically generated configuration"
                }));
            }
        }
    }
    let mut configurations = merge_values(&generated, &team, &local)?;
    for configuration in &mut configurations {
        validate_configuration(configuration)?;
        if configuration.disabled {
            diagnostics.push(json!({
                "id": configuration.id,
                "code": "disabled",
                "message": "Run configuration is disabled"
            }));
            continue;
        }
        if let Some(module) = configuration.module().filter(|value| value != ".") {
            if !project_directory_exists(&root, &module) {
                configuration.disabled = true;
                diagnostics.push(json!({
                    "id": configuration.id,
                    "code": "missingModule",
                    "message": format!("Module directory does not exist: {module}")
                }));
                continue;
            }
        }
        if !project_directory_exists(&root, &configuration.cwd) {
            configuration.disabled = true;
            diagnostics.push(json!({
                "id": configuration.id,
                "code": "missingWorkingDirectory",
                "message": format!("Working directory does not exist: {}", configuration.cwd)
            }));
            continue;
        }
        if let Some(main_class) = configuration.main_class() {
            if !main_class_exists(&root, &main_class)? {
                configuration.disabled = true;
                diagnostics.push(json!({
                    "id": configuration.id,
                    "code": "missingMainClass",
                    "message": format!("Main class source no longer exists: {main_class}")
                }));
            }
        }
    }
    configurations.retain(|configuration| !configuration.disabled);
    let mut default_run_configuration = manifest
        .as_ref()
        .and_then(|value| value.get("defaultRunConfiguration"))
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(default_id) = default_run_configuration.as_deref() {
        if !configurations
            .iter()
            .any(|configuration| configuration.id == default_id)
        {
            diagnostics.push(json!({
                "code": "missingDefaultConfiguration",
                "message": format!("Default run configuration is unavailable: {default_id}")
            }));
            default_run_configuration = None;
        }
    }
    Ok(json!({
        "version": VERSION,
        "configurations": configurations,
        "diagnostics": diagnostics,
        "defaultRunConfiguration": default_run_configuration
    }))
}

pub fn update_options(request: UpdateOptionsRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let relative = scope_document(&request.scope)?;
    let resolved = resolve(ResolveRequest {
        root: request.root.clone(),
        toolchain_candidates: Vec::new(),
    })?;
    let provider = resolved["configurations"]
        .as_array()
        .and_then(|items| items.iter().find(|value| value["id"] == request.configuration_id))
        .and_then(|value| value["provider"].as_str())
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Run configuration was not found"))?;
    let uses_maven_capability = matches!(
        provider,
        "java.current-file" | "java.main" | "spring-boot.maven" | "maven.module"
    );
    let working_directory = normalize_project_directory(
        &root,
        if request.working_directory.trim().is_empty() {
            "."
        } else {
            request.working_directory.trim()
        },
        false,
    )?;
    let mut document = read_document_value(&root, relative)?
        .unwrap_or_else(|| json!({"version": VERSION, "configurations": []}));
    validate_version_value(&document)?;
    let configurations = document["configurations"]
        .as_array_mut()
        .ok_or_else(|| CoreError::new(ErrorCode::ParseFailed, "configurations must be an array"))?;
    let mut patch = json!({
        "id": request.configuration_id,
        "cwd": working_directory,
        "env": request.environment
    });
    if uses_maven_capability {
        patch["extensions"] = json!({
            "maven": {
                "jvmArguments": split_arguments(&request.jvm_arguments),
                "programArguments": split_arguments(&request.arguments),
                "profiles": request.maven_profiles.into_iter().collect::<BTreeSet<_>>()
            }
        });
    } else {
        patch["args"] = json!(split_arguments(&request.arguments));
    }
    if let Some(existing) = configurations
        .iter_mut()
        .find(|value| value["id"] == patch["id"])
    {
        let target = existing.as_object_mut().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration must be an object",
            )
        })?;
        for (key, value) in patch.as_object_mut().expect("patch is an object") {
            if key == "extensions" {
                merge_extensions(target, value)?;
                continue;
            }
            target.insert(key.clone(), value.take());
        }
    } else {
        configurations.push(patch);
    }
    configurations.sort_by(|left, right| {
        left["id"]
            .as_str()
            .unwrap_or("")
            .cmp(right["id"].as_str().unwrap_or(""))
    });
    Ok(json!({
        "document": serde_json::to_string_pretty(&document).expect("document should encode")
    }))
}

pub fn create_user_configuration(
    request: CreateUserConfigurationRequest,
) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let relative = scope_document(&request.scope)?;
    let name = request.name.trim();
    if name.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Configuration name is required",
        ));
    }
    let configuration_kind = match request.kind.as_str() {
        "springBoot" => "spring-boot.maven",
        "mavenModule" => "maven.module",
        _ => {
            return Err(CoreError::new(
                ErrorCode::NotSupported,
                "Only Spring Boot and Maven Module configurations can be created",
            ));
        }
    };
    let module = normalize_project_directory(
        &root,
        if request.module.trim().is_empty() {
            "."
        } else {
            request.module.trim()
        },
        true,
    )?;
    let main_class = request.main_class.trim();
    if configuration_kind == "spring-boot.maven" {
        if main_class.is_empty() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Spring Boot main class is required",
            ));
        }
        if !main_class_exists(&root, main_class)? {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Spring Boot main class source does not exist",
            )
            .with_details(main_class));
        }
    }
    let mut existing_ids = std::collections::BTreeSet::new();
    for source in [
        "run/generated.json",
        "run/configurations.json",
        "run/local.json",
    ] {
        if let Some(document) = read_document_value(&root, source)? {
            validate_version_value(&document)?;
            existing_ids.extend(configuration_ids(&document)?.into_keys());
        }
    }
    let id = unique_user_configuration_id(name, &existing_ids);
    let mut document = read_document_value(&root, relative)?
        .unwrap_or_else(|| json!({"version": VERSION, "configurations": []}));
    validate_version_value(&document)?;
    let configurations = document["configurations"]
        .as_array_mut()
        .ok_or_else(|| CoreError::new(ErrorCode::ParseFailed, "configurations must be an array"))?;
    let mut maven = json!({
        "module": module,
        "jvmArguments": [],
        "programArguments": [],
        "profiles": []
    });
    if !main_class.is_empty() {
        maven["mainClass"] = json!(main_class);
    }
    let configuration = json!({
        "id": id,
        "name": name,
        "provider": configuration_kind,
        "execution": if configuration_kind == "spring-boot.maven" { "service" } else { "task" },
        "confidence": "native",
        "toolchains": {"java": "project-jdk", "maven": "project-maven"},
        "cwd": ".",
        "debug": {"adapter": "jdwp"},
        "extensions": {"maven": maven}
    });
    configurations.push(configuration);
    configurations.sort_by(|left, right| {
        left["id"]
            .as_str()
            .unwrap_or("")
            .cmp(right["id"].as_str().unwrap_or(""))
    });
    Ok(json!({
        "id": id,
        "document": serde_json::to_string_pretty(&document).expect("document should encode")
    }))
}

pub fn create_launch_plan(request: LaunchPlanRequest) -> Result<Value, CoreError> {
    let resolved = resolve(ResolveRequest {
        root: request.root,
        toolchain_candidates: Vec::new(),
    })?;
    let config = resolved["configurations"]
        .as_array()
        .and_then(|items| items.iter().find(|v| v["id"] == request.configuration_id))
        .ok_or_else(|| {
            CoreError::new(ErrorCode::InvalidRequest, "Run configuration was not found")
        })?;
    if config["disabled"].as_bool().unwrap_or(false) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration is disabled",
        ));
    }
    let provider = config["provider"].as_str().unwrap_or("");

    // A configuration carrying its own `command` is process-based: the detector
    // already resolved what to run, so there is nothing ecosystem-specific to
    // assemble. Dispatching here keeps the Java branches below untouched.
    if let Some(command) = config["command"].as_str().filter(|value| !value.is_empty()) {
        return process_launch_plan(config, command);
    }
    if let Some(toolchain) = config["toolchains"]["runtime"]
        .as_str()
        .filter(|value| !value.is_empty())
    {
        return toolchain_process_launch_plan(config, toolchain);
    }
    if !matches!(
        provider,
        "java.current-file" | "java.main" | "spring-boot.maven" | "maven.module"
    ) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run provider must declare a command or runtime toolchain",
        )
        .with_details(provider));
    }

    let maven = &config["extensions"]["maven"];
    let mut jvm_arguments = maven["jvmArguments"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let program_arguments = maven["programArguments"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut arguments = Vec::new();
    let is_current = provider == "java.current-file";
    let is_java_main = provider == "java.main";
    if let Some(port) = request.debug_port {
        jvm_arguments.insert(
            0,
            json!(format!(
                "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:{port}"
            )),
        );
        jvm_arguments.insert(1, json!("-Duser.language=en"));
        jvm_arguments.insert(2, json!("-Duser.country=US"));
    }
    if is_current {
        arguments.extend(jvm_arguments);
        if let Some(class_path) = request.class_path.filter(|value| !value.is_empty()) {
            arguments.extend([json!("--class-path"), json!(class_path)]);
        }
        let current_file = request.current_file.ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Current File requires a Java source path",
            )
        })?;
        if invalid_relative_path(&current_file) || !current_file.to_lowercase().ends_with(".java") {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Current Java source path is invalid",
            ));
        }
        arguments.push(json!(current_file));
        arguments.extend(program_arguments);
    } else if is_java_main {
        arguments.extend([json!("-B"), json!("-ntp")]);
        if let Some(module) = maven["module"].as_str().filter(|m| *m != ".") {
            arguments.extend([json!("-pl"), json!(module)]);
        }
        let main = maven["mainClass"].as_str().ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Java application is missing its main class",
            )
        })?;
        arguments.push(json!(format!("-Dexec.mainClass={main}")));
        if !program_arguments.is_empty() {
            arguments.push(json!(format!(
                "-Dexec.args={}",
                string_arguments(&program_arguments)
            )));
        }
        arguments.push(json!("org.codehaus.mojo:exec-maven-plugin:3.5.0:java"));
    } else {
        arguments.extend([json!("-B"), json!("-ntp")]);
        if let Some(module) = maven["module"].as_str().filter(|m| *m != ".") {
            arguments.extend([json!("-pl"), json!(module)]);
        }
        if let Some(profiles) = maven["profiles"].as_array().filter(|p| !p.is_empty()) {
            arguments.extend([
                json!("-P"),
                json!(profiles
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(",")),
            ]);
        }
        if let Some(main) = maven["mainClass"].as_str() {
            arguments.push(json!(format!("-Dspring-boot.run.main-class={main}")));
        }
        if !jvm_arguments.is_empty() {
            arguments.push(json!(format!(
                "-Dspring-boot.run.jvmArguments={}",
                string_arguments(&jvm_arguments)
            )));
        }
        if !program_arguments.is_empty() {
            arguments.push(json!(format!(
                "-Dspring-boot.run.arguments={}",
                string_arguments(&program_arguments)
            )));
        }
        arguments.push(json!("spring-boot:run"));
    }
    let executable_kind = if is_current { "java" } else { "maven" };
    let executable_toolchain = config["toolchains"][executable_kind]
        .as_str()
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Run configuration is missing its executable toolchain",
            )
            .with_details(executable_kind)
        })?;
    let java_toolchain = config["toolchains"]["java"]
        .as_str()
        .unwrap_or("project-jdk");
    Ok(json!({
        "executable": { "toolchain": executable_toolchain },
        "arguments": arguments,
        "workingDirectory": config["cwd"].as_str().unwrap_or("."),
        "environment": {
            "JAVA_HOME": { "toolchain": java_toolchain, "property": "home" }
        }
    }))
}

/// Launch plan for configurations that name their own executable.
///
/// `executable.command` is a bare program name resolved on PATH by the host, as
/// opposed to `executable.toolchain` which the host resolves from its toolchain
/// registry. The two are mutually exclusive and the host branches on which key
/// is present. No JAVA_HOME is injected -- a Go or Node service has no use for
/// it, and injecting it would leak a Java assumption into every ecosystem.
fn process_launch_plan(config: &Value, command: &str) -> Result<Value, CoreError> {
    if command.contains('/') || command.contains('\\') {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration command must be a bare program name",
        )
        .with_details(command));
    }
    let arguments = config["args"].as_array().cloned().unwrap_or_default();
    if arguments.iter().any(|value| !value.is_string()) {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration arguments must be strings",
        ));
    }
    Ok(json!({
        "executable": { "command": command },
        "arguments": arguments,
        "workingDirectory": config["cwd"].as_str().unwrap_or("."),
        // `environment` is reserved for toolchain-derived values the host must
        // resolve. Literal key/value pairs stay in `env` so the two never
        // collide in one field.
        "environment": {},
        "env": config["env"].as_object().cloned().unwrap_or_default()
    }))
}

/// Launch plan for a language provider whose executable is supplied by the
/// host Toolchain Registry. The shared contract uses the stable `runtime` key;
/// provider-specific SDK metadata stays in other toolchain/extension entries.
fn toolchain_process_launch_plan(config: &Value, toolchain: &str) -> Result<Value, CoreError> {
    let arguments = config["args"].as_array().cloned().unwrap_or_default();
    if arguments.iter().any(|value| !value.is_string()) {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration arguments must be strings",
        ));
    }
    Ok(json!({
        "executable": { "toolchain": toolchain },
        "arguments": arguments,
        "workingDirectory": config["cwd"].as_str().unwrap_or("."),
        "environment": {},
        "env": config["env"].as_object().cloned().unwrap_or_default()
    }))
}

fn string_arguments(values: &[Value]) -> String {
    values
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>()
        .join(" ")
}

fn validate_version_value(document: &Value) -> Result<(), CoreError> {
    let version = document.get("version").and_then(Value::as_u64).unwrap_or(0) as u32;
    validate_version(version)
}

fn validate_version(version: u32) -> Result<(), CoreError> {
    if version != VERSION {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported run configuration version",
        )
        .with_details(format!("expected {VERSION}, found {version}")));
    }
    Ok(())
}

fn validate_sidecar_version(version: u32) -> Result<(), CoreError> {
    if version != SIDECAR_VERSION {
        return Err(
            CoreError::new(ErrorCode::NotSupported, "Unsupported document version")
                .with_details(format!("expected {SIDECAR_VERSION}, found {version}")),
        );
    }
    Ok(())
}

fn validate_sidecar_version_value(document: &Value) -> Result<(), CoreError> {
    let version = document.get("version").and_then(Value::as_u64).unwrap_or(0) as u32;
    validate_sidecar_version(version)
}

fn merge_values(
    base: &Value,
    team: &Value,
    local: &Value,
) -> Result<Vec<RunConfiguration>, CoreError> {
    let mut result: BTreeMap<String, Value> = BTreeMap::new();
    for (source_index, source) in [base, team, local].into_iter().enumerate() {
        let Some(items) = source.get("configurations").and_then(Value::as_array) else {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "configurations must be an array",
            ));
        };
        for item in items {
            let Some(id) = item.get("id").and_then(Value::as_str) else {
                return Err(CoreError::new(
                    ErrorCode::ParseFailed,
                    "Run configuration id is required",
                ));
            };
            if source_index > 0 && !result.contains_key(id) && !id.starts_with("user:") {
                continue;
            }
            if let Some(existing) = result.get_mut(id) {
                let (Some(target), Some(patch)) = (existing.as_object_mut(), item.as_object())
                else {
                    return Err(CoreError::new(
                        ErrorCode::ParseFailed,
                        "Run configuration must be an object",
                    ));
                };
                for (key, value) in patch {
                    if key == "source" {
                        continue;
                    }
                    if key == "extensions" {
                        merge_extensions(target, &mut value.clone())?;
                        continue;
                    }
                    if key == "toolchains" {
                        let target_map = target
                            .entry(key.clone())
                            .or_insert_with(|| json!({}))
                            .as_object_mut()
                            .ok_or_else(|| {
                                CoreError::new(
                                    ErrorCode::ParseFailed,
                                    "Run configuration toolchains must be an object",
                                )
                            })?;
                        let patch_map = value.as_object().ok_or_else(|| {
                            CoreError::new(
                                ErrorCode::ParseFailed,
                                "Run configuration toolchains must be an object",
                            )
                        })?;
                        for (toolchain_kind, toolchain_id) in patch_map {
                            target_map.insert(toolchain_kind.clone(), toolchain_id.clone());
                        }
                    } else {
                        target.insert(key.clone(), value.clone());
                    }
                }
                target.insert(
                    "source".to_string(),
                    json!(["generated", "project", "local"][source_index]),
                );
            } else {
                let mut value = item.clone();
                if let Some(object) = value.as_object_mut() {
                    object.insert(
                        "source".to_string(),
                        json!(["generated", "project", "local"][source_index]),
                    );
                }
                result.insert(id.to_string(), value);
            }
        }
    }
    result
        .into_values()
        .map(|item| {
            serde_json::from_value::<RunConfiguration>(item).map_err(|e| {
                CoreError::new(ErrorCode::ParseFailed, "Invalid merged run configuration")
                    .with_details(e.to_string())
            })
        })
        .collect()
}

/// Deep-merges the `extensions` object one namespace at a time.
///
/// A shallow insert would let a layer that touches a single maven key drop the
/// whole npm namespace it never mentioned.
fn merge_extensions(
    target: &mut serde_json::Map<String, Value>,
    patch: &mut Value,
) -> Result<(), CoreError> {
    let patch_map = patch.as_object().ok_or_else(|| {
        CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration extensions must be an object",
        )
    })?;
    let target_map = target
        .entry("extensions".to_string())
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration extensions must be an object",
            )
        })?;
    for (namespace, value) in patch_map {
        let slot = target_map
            .entry(namespace.clone())
            .or_insert_with(|| json!({}));
        match (slot.as_object_mut(), value.as_object()) {
            (Some(existing), Some(incoming)) => {
                for (key, item) in incoming {
                    existing.insert(key.clone(), item.clone());
                }
            }
            _ => {
                *slot = value.clone();
            }
        }
    }
    Ok(())
}

fn configuration_ids(document: &Value) -> Result<BTreeMap<String, ()>, CoreError> {
    let Some(items) = document.get("configurations").and_then(Value::as_array) else {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "configurations must be an array",
        ));
    };
    let mut result = BTreeMap::new();
    for item in items {
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration id is required",
            ));
        };
        result.insert(id.to_string(), ());
    }
    Ok(result)
}

fn validate_configuration(configuration: &RunConfiguration) -> Result<(), CoreError> {
    if configuration.id.trim().is_empty() || configuration.name.trim().is_empty() {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration id and name are required",
        ));
    }
    if !valid_provider(&configuration.provider) {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported run configuration provider",
        )
        .with_details(configuration.provider.clone()));
    }
    let module = configuration.module().unwrap_or_else(|| ".".to_string());
    for (field, value) in [
        ("module", module.as_str()),
        ("workingDirectory", configuration.cwd.as_str()),
    ] {
        if invalid_relative_path(value) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Run configuration contains an invalid project-relative path",
            )
            .with_details(format!("{field}: {value}")));
        }
    }
    Ok(())
}

fn scope_document(scope: &str) -> Result<&'static str, CoreError> {
    match scope {
        "local" => Ok("run/local.json"),
        "project" => Ok("run/configurations.json"),
        _ => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration scope must be local or project",
        )),
    }
}

fn normalize_project_directory(
    root: &Path,
    value: &str,
    must_exist: bool,
) -> Result<String, CoreError> {
    let candidate = Path::new(value);
    if (!candidate.is_absolute() && invalid_relative_path(value))
        || candidate
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Project configuration paths must stay inside the project",
        ));
    }
    let canonical_root = fs::canonicalize(root)?;
    let target = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };
    if !must_exist {
        let normalized = target.components().collect::<PathBuf>();
        let relative = normalized.strip_prefix(root).map_err(|_| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Project configuration paths must stay inside the project",
            )
        })?;
        return if relative.as_os_str().is_empty() {
            Ok(".".to_string())
        } else {
            Ok(relative.to_string_lossy().replace('\\', "/"))
        };
    }
    let canonical_target = fs::canonicalize(&target).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Project configuration directory does not exist",
        )
        .with_details(format!("{}: {error}", target.display()))
    })?;
    let relative = canonical_target
        .strip_prefix(&canonical_root)
        .map_err(|_| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Project configuration paths must stay inside the project",
            )
        })?;
    if relative.as_os_str().is_empty() {
        Ok(".".to_string())
    } else {
        Ok(relative.to_string_lossy().replace('\\', "/"))
    }
}

fn project_directory_exists(root: &Path, value: &str) -> bool {
    if invalid_relative_path(value) {
        return false;
    }
    let Ok(canonical_root) = fs::canonicalize(root) else {
        return false;
    };
    let Ok(canonical_target) = fs::canonicalize(root.join(value)) else {
        return false;
    };
    canonical_target.is_dir() && canonical_target.starts_with(canonical_root)
}

fn unique_user_configuration_id(
    name: &str,
    existing_ids: &std::collections::BTreeSet<String>,
) -> String {
    let mut slug = String::new();
    let mut separator = false;
    for character in name.to_lowercase().chars() {
        if character.is_alphanumeric() {
            slug.push(character);
            separator = false;
        } else if !slug.is_empty() {
            separator = true;
        }
        if separator && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    let base = format!(
        "user:{}",
        if slug.is_empty() {
            "configuration"
        } else {
            slug
        }
    );
    if !existing_ids.contains(&base) {
        return base;
    }
    let mut suffix = 2;
    loop {
        let candidate = format!("{base}-{suffix}");
        if !existing_ids.contains(&candidate) {
            return candidate;
        }
        suffix += 1;
    }
}

fn split_arguments(input: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in input.chars() {
        if escaped {
            current.push(character);
            escaped = false;
        } else if character == '\\' && quote != Some('\'') {
            escaped = true;
        } else if matches!(character, '\'' | '"') {
            if quote == Some(character) {
                quote = None;
            } else if quote.is_none() {
                quote = Some(character);
            } else {
                current.push(character);
            }
        } else if character.is_whitespace() && quote.is_none() {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(character);
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

fn read_document(
    root: &Path,
    relative: &str,
) -> Result<Option<RunConfigurationDocument>, CoreError> {
    let path = root.join(".lithe").join(relative);
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|e| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            format!("Could not read run configuration: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })?;
    let mut value: Value = serde_json::from_str(&text).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Run configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })?;
    migrate_document_value(&mut value);
    serde_json::from_value(value).map(Some).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Run configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })
}

fn read_document_value(root: &Path, relative: &str) -> Result<Option<Value>, CoreError> {
    let path = root.join(".lithe").join(relative);
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|e| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            "Could not read run configuration",
        )
        .with_details(e.to_string())
    })?;
    let mut value: Value = serde_json::from_str(&text).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })?;
    // Only run/* documents carry the run-configuration schema. project.json and
    // the toolchain files share the .lithe root and a version field, but their
    // schema is unrelated -- migrating them would bump a version they never own.
    if relative.starts_with("run/") {
        migrate_document_value(&mut value);
    }
    Ok(Some(value))
}

fn read_requirements(root: &Path) -> Result<Option<ToolchainRequirementsDocument>, CoreError> {
    let path = root.join(".lithe/toolchains/requirements.json");
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(path).map_err(|error| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            "Could not read toolchain requirements: .lithe/toolchains/requirements.json",
        )
        .with_details(error.to_string())
    })?;
    serde_json::from_str(&text).map(Some).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            "Toolchain requirements JSON is invalid: .lithe/toolchains/requirements.json",
        )
        .with_details(e.to_string())
    })
}

fn detect_requirements(
    root: &Path,
    has_java_ecosystem: bool,
    configurations: &[RunConfiguration],
) -> Result<ToolchainRequirementsDocument, CoreError> {
    let mut jdk = ToolchainRequirement {
        kind: "java".to_string(),
        minimum_version: None,
        preferred_vendor: None,
        wrapper: None,
        version: None,
        java: None,
    };
    let mut maven = ToolchainRequirement {
        kind: "maven".to_string(),
        minimum_version: None,
        preferred_vendor: None,
        wrapper: None,
        version: None,
        java: Some("project-jdk".to_string()),
    };
    let pom = root.join("pom.xml");
    if let Ok(text) = fs::read_to_string(pom) {
        let re = regex::Regex::new(r"(?:maven.compiler.release|maven.compiler.source|maven.compiler.target|java.version)\s*>?\s*[:=]?\s*([0-9]+)").unwrap();
        jdk.minimum_version = re
            .captures(&text)
            .and_then(|c| c.get(1).map(|m| m.as_str().to_string()));
    }
    if let Some((version, vendor)) = declared_java_version(root) {
        jdk.minimum_version = Some(version);
        jdk.preferred_vendor = vendor;
    }
    if root.join("mvnw").exists() {
        maven.wrapper = Some("./mvnw".to_string());
    }
    maven.version = maven_wrapper_version(root);
    let mut toolchains = BTreeMap::new();
    if has_java_ecosystem {
        toolchains.insert("project-jdk".to_string(), jdk);
    }
    if root.join("pom.xml").is_file() || root.join("mvnw").is_file() {
        toolchains.insert("project-maven".to_string(), maven);
    }
    let providers = configurations
        .iter()
        .map(|configuration| configuration.provider.as_str())
        .collect::<Vec<_>>();
    if providers.iter().any(|provider| provider.starts_with("go.")) {
        toolchains.insert(
            "project-go".to_string(),
            generic_requirement("go", declared_go_version(root)),
        );
    }
    if providers
        .iter()
        .any(|provider| provider.starts_with("python."))
    {
        toolchains.insert(
            "project-python".to_string(),
            generic_requirement("python", declared_python_version(root)),
        );
    }
    if providers
        .iter()
        .any(|provider| provider.starts_with("npm."))
    {
        toolchains.insert(
            "project-node".to_string(),
            generic_requirement("node", declared_node_version(root)),
        );
    }
    if providers
        .iter()
        .any(|provider| provider.starts_with("cargo."))
    {
        toolchains.insert(
            "project-cargo".to_string(),
            generic_requirement("rust", declared_rust_version(root)),
        );
    }
    Ok(ToolchainRequirementsDocument {
        version: SIDECAR_VERSION,
        toolchains,
    })
}

fn generic_requirement(kind: &str, minimum_version: Option<String>) -> ToolchainRequirement {
    ToolchainRequirement {
        kind: kind.to_string(),
        minimum_version,
        preferred_vendor: None,
        wrapper: None,
        version: None,
        java: None,
    }
}

fn toolchain_diagnostics(
    root: &Path,
    candidates: &[ToolchainCandidate],
) -> Result<Vec<Value>, CoreError> {
    let Some(requirements) = read_requirements(root)? else {
        return Ok(Vec::new());
    };
    validate_sidecar_version(requirements.version)?;
    let mut diagnostics = Vec::new();
    for (id, requirement) in requirements.toolchains {
        let Some(candidate) = candidates
            .iter()
            .find(|candidate| candidate.id == id && candidate.kind == requirement.kind)
        else {
            diagnostics.push(json!({
                "code": "missingToolchain",
                "toolchain": id,
                "message": format!("No local {} toolchain is selected", requirement.kind)
            }));
            continue;
        };
        let required_version = requirement
            .minimum_version
            .as_deref()
            .or(requirement.version.as_deref());
        if let Some(required) = required_version {
            if !version_satisfies(
                &candidate.version,
                required,
                requirement.minimum_version.is_some(),
            ) {
                diagnostics.push(json!({
                    "code": "toolchainVersionMismatch",
                    "toolchain": id,
                    "message": format!(
                        "{} {} does not satisfy required version {}",
                        requirement.kind, candidate.version, required
                    )
                }));
            }
        }
        if let Some(vendor) = requirement.preferred_vendor.as_deref() {
            if !candidate
                .vendor
                .to_lowercase()
                .contains(&vendor.to_lowercase())
            {
                diagnostics.push(json!({
                    "code": "toolchainVendorMismatch",
                    "toolchain": id,
                    "message": format!("Preferred Java vendor is {vendor}")
                }));
            }
        }
    }
    Ok(diagnostics)
}

fn version_satisfies(actual: &str, required: &str, minimum: bool) -> bool {
    let actual_parts = version_parts(actual);
    let required_parts = version_parts(required);
    if actual_parts.is_empty() || required_parts.is_empty() {
        return false;
    }
    if minimum {
        actual_parts >= required_parts
    } else {
        actual_parts.starts_with(&required_parts)
    }
}

fn version_parts(value: &str) -> Vec<u32> {
    value
        .split(|character: char| !character.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect()
}

fn project_inputs(root: &Path) -> Result<BTreeMap<String, String>, CoreError> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                if !ignored_directory(&path) {
                    stack.push(path);
                }
            } else if fingerprint_input(&path) {
                if let Ok(relative) = path.strip_prefix(root) {
                    files.push(relative.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    files.sort();
    let mut result = BTreeMap::new();
    for relative in files {
        if let Ok(bytes) = fs::read(root.join(&relative)) {
            result.insert(relative, format!("sha256:{:x}", Sha256::digest(bytes)));
        }
    }
    Ok(result)
}

fn fingerprint_from_inputs(inputs: &BTreeMap<String, String>) -> String {
    let mut digest = Sha256::new();
    for (relative, content_hash) in inputs {
        digest.update(relative.as_bytes());
        digest.update([0]);
        digest.update(content_hash.as_bytes());
        digest.update([0]);
    }
    format!("sha256:{:x}", digest.finalize())
}

fn input_change_summary(
    previous: &BTreeMap<String, String>,
    current: &BTreeMap<String, String>,
) -> String {
    let added = current
        .keys()
        .filter(|path| !previous.contains_key(*path))
        .count();
    let removed = previous
        .keys()
        .filter(|path| !current.contains_key(*path))
        .count();
    let changed = current
        .iter()
        .filter(|(path, hash)| previous.get(*path).is_some_and(|old| old != *hash))
        .count();
    format!("Project inputs changed: {added} added, {removed} removed, {changed} modified")
}

fn ignored_directory(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some(
            ".git"
                | ".lithe"
                | ".idea"
                | ".gradle"
                | ".venv"
                | "venv"
                | "node_modules"
                | "vendor"
                | "target"
                | "build"
                | "dist"
                | "out"
        )
    )
}

fn fingerprint_input(path: &Path) -> bool {
    if path.extension().and_then(|extension| extension.to_str()) == Some("java") {
        return true;
    }
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some(
            "pom.xml"
                | "mvnw"
                | "maven-wrapper.properties"
                | ".java-version"
                | ".sdkmanrc"
                | "mise.toml"
                | "package.json"
                | "package-lock.json"
                | "pnpm-lock.yaml"
                | "yarn.lock"
                | "bun.lock"
                | "bun.lockb"
                | "docker-compose.yml"
                | "docker-compose.yaml"
                | "compose.yml"
                | "compose.yaml"
                | "pyproject.toml"
                | "manage.py"
                | "Cargo.toml"
                | "rust-toolchain"
                | "rust-toolchain.toml"
                | "go.mod"
                | "Procfile"
                | "Procfile.dev"
                | "Procfile.local"
                | "Makefile"
                | "makefile"
                | "GNUmakefile"
                | "justfile"
                | "Justfile"
                | ".justfile"
        )
    )
}

fn declared_go_version(root: &Path) -> Option<String> {
    highest_version(
        project_manifest_paths(root, &["go.mod"])
            .into_iter()
            .filter_map(|path| fs::read_to_string(path).ok())
            .filter_map(|text| {
                text.lines().find_map(|line| {
                    line.trim()
                        .strip_prefix("go ")
                        .and_then(first_numeric_version)
                })
            })
            .collect(),
    )
}

fn declared_python_version(root: &Path) -> Option<String> {
    let expression = regex::Regex::new(
        r#"(?m)^\s*(?:requires-python|python)\s*=\s*[\"']([^\"']+)[\"']"#,
    )
    .ok()?;
    highest_version(
        project_manifest_paths(root, &["pyproject.toml"])
            .into_iter()
            .filter_map(|path| fs::read_to_string(path).ok())
            .filter_map(|text| {
                expression
                    .captures(&text)
                    .and_then(|capture| capture.get(1))
                    .and_then(|value| first_numeric_version(value.as_str()))
            })
            .collect(),
    )
}

fn declared_node_version(root: &Path) -> Option<String> {
    highest_version(
        project_manifest_paths(root, &["package.json"])
            .into_iter()
            .filter_map(|path| fs::read_to_string(path).ok())
            .filter_map(|text| serde_json::from_str::<Value>(&text).ok())
            .filter_map(|document| {
                document
                    .get("engines")?
                    .get("node")?
                    .as_str()
                    .and_then(first_numeric_version)
            })
            .collect(),
    )
}

fn declared_rust_version(root: &Path) -> Option<String> {
    let mut versions = Vec::new();
    for path in project_manifest_paths(root, &["Cargo.toml"]) {
        let Some(document) = fs::read_to_string(path)
            .ok()
            .and_then(|text| text.parse::<toml::Table>().ok())
        else {
            continue;
        };
        if let Some(version) = document
            .get("package")
            .and_then(|package| package.get("rust-version"))
            .and_then(|value| value.as_str())
            .and_then(first_numeric_version)
        {
            versions.push(version);
        }
    }
    for path in project_manifest_paths(root, &["rust-toolchain", "rust-toolchain.toml"]) {
        let Ok(text) = fs::read_to_string(path) else {
            continue;
        };
        if let Some(version) = first_numeric_version(&text) {
            versions.push(version);
        }
    }
    highest_version(versions)
}

fn first_numeric_version(value: &str) -> Option<String> {
    regex::Regex::new(r"[0-9]+(?:\.[0-9]+)+")
        .ok()?
        .find(value)
        .map(|value| value.as_str().to_string())
}

fn highest_version(versions: Vec<String>) -> Option<String> {
    versions
        .into_iter()
        .max_by(|left, right| version_parts(left).cmp(&version_parts(right)))
}

fn project_manifest_paths(root: &Path, names: &[&str]) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if !ignored_directory(&path) {
                    stack.push(path);
                }
            } else if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| names.contains(&name))
            {
                result.push(path);
            }
        }
    }
    result
}

fn declared_java_version(root: &Path) -> Option<(String, Option<String>)> {
    if let Ok(text) = fs::read_to_string(root.join(".java-version")) {
        let value = text.trim();
        if let Some(version) = major_version(value) {
            return Some((version, vendor_from_version(value)));
        }
    }
    if let Ok(text) = fs::read_to_string(root.join(".sdkmanrc")) {
        if let Some(value) = text
            .lines()
            .find_map(|line| line.trim().strip_prefix("java="))
        {
            return major_version(value).map(|version| (version, vendor_from_version(value)));
        }
    }
    if let Ok(text) = fs::read_to_string(root.join("mise.toml")) {
        let expression = regex::Regex::new(r#"(?m)^\s*java\s*=\s*[\"']([^\"']+)[\"']"#).ok()?;
        if let Some(value) = expression
            .captures(&text)
            .and_then(|capture| capture.get(1))
        {
            let value = value.as_str();
            return major_version(value).map(|version| (version, vendor_from_version(value)));
        }
    }
    None
}

fn major_version(value: &str) -> Option<String> {
    regex::Regex::new(r"(?:^|[^0-9])(?:1\.)?([0-9]{1,2})(?:[._+-]|$)")
        .ok()?
        .captures(value)
        .and_then(|capture| capture.get(1))
        .map(|value| value.as_str().to_string())
}

fn vendor_from_version(value: &str) -> Option<String> {
    let lower = value.to_lowercase();
    if lower.contains("tem") || lower.contains("temurin") {
        Some("temurin".to_string())
    } else if lower.contains("zulu") {
        Some("zulu".to_string())
    } else if lower.contains("graal") {
        Some("graalvm".to_string())
    } else {
        None
    }
}

fn maven_wrapper_version(root: &Path) -> Option<String> {
    let text = fs::read_to_string(root.join(".mvn/wrapper/maven-wrapper.properties")).ok()?;
    regex::Regex::new(r"apache-maven-([0-9]+(?:\.[0-9]+)+)-bin\.(?:zip|tar\.gz)")
        .ok()?
        .captures(&text)
        .and_then(|capture| capture.get(1))
        .map(|value| value.as_str().to_string())
}

fn main_class_exists(root: &Path, main_class: &str) -> Result<bool, CoreError> {
    let (package_name, simple_name) = main_class
        .rsplit_once('.')
        .map_or(("", main_class), |(package, name)| (package, name));
    let file_name = format!("{simple_name}.java");
    let package_expression =
        regex::Regex::new(r"(?m)^\s*package\s+([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\s*;")
            .map_err(|error| CoreError::new(ErrorCode::Unknown, error.to_string()))?;
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.is_dir() {
                if !ignored_directory(&path) {
                    stack.push(path);
                }
            } else if path.file_name().and_then(|name| name.to_str()) == Some(file_name.as_str()) {
                let source = fs::read_to_string(&path)?;
                let declared_package = package_expression
                    .captures(&source)
                    .and_then(|capture| capture.get(1))
                    .map(|value| value.as_str())
                    .unwrap_or("");
                if declared_package == package_name {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    if !path.is_dir() {
        return Err(CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Project root does not exist",
        ));
    }
    Ok(path)
}

#[allow(dead_code)]
fn valid_relative(value: &str) -> bool {
    !invalid_relative_path(value)
}

/// `namespace.name`, both segments lowercase kebab starting with a letter.
/// Shape is checked, membership is not: an unknown ecosystem must be able to
/// register a provider without touching this file.
fn valid_provider(value: &str) -> bool {
    let Some((namespace, name)) = value.split_once('.') else {
        return false;
    };
    [namespace, name].iter().all(|segment| {
        segment
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_lowercase())
            && segment
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    })
}
