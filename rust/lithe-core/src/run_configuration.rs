use crate::error::{invalid_relative_path, CoreError, ErrorCode};
use crate::java::JavaRunConfigurationsRequest;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

const VERSION: u32 = 1;

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
    #[serde(default)]
    pub program_arguments: String,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneratorMetadata {
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub inputs: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunConfiguration {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub module: Option<String>,
    #[serde(default)]
    pub main_class: Option<String>,
    #[serde(default)]
    pub toolchains: BTreeMap<String, String>,
    #[serde(default = "dot")]
    pub working_directory: String,
    #[serde(default)]
    pub jvm_arguments: Vec<String>,
    #[serde(default)]
    pub program_arguments: Vec<String>,
    #[serde(default)]
    pub maven_profiles: Vec<String>,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

fn dot() -> String {
    ".".to_string()
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
            validate_version_value(&document)?;
            if relative.starts_with("run/") {
                configuration_ids(&document)?;
            } else if relative == "toolchains/local.json"
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
    if let Some(document) = generated.as_ref() {
        validate_version(document.version)?;
    }
    if let Some(document) = requirements.as_ref() {
        validate_version(document.version)?;
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
    let module_paths = inferred_maven_module_paths(
        &root,
        &request.paths,
        request.module_paths,
    );
    let scanned = crate::java::run_configurations(JavaRunConfigurationsRequest {
        root: request.root.clone(),
        paths: request.paths,
        module_paths,
    })?;
    let entry_count = scanned.configurations.len();
    let mut configurations = scanned
        .configurations
        .into_iter()
        .map(|value| RunConfiguration {
            id: value.id,
            name: value.name,
            kind: match value.kind.as_str() {
                "springBoot" => "spring-boot.maven",
                "mavenModule" => "maven.module",
                _ => "java.current-file",
            }
            .to_string(),
            module: value.module_path.or_else(|| Some(".".to_string())),
            main_class: value.main_class,
            toolchains: [
                ("java".to_string(), "project-jdk".to_string()),
                ("maven".to_string(), "project-maven".to_string()),
            ]
            .into_iter()
            .collect(),
            working_directory: ".".to_string(),
            jvm_arguments: Vec::new(),
            program_arguments: Vec::new(),
            maven_profiles: Vec::new(),
            disabled: false,
            source: None,
        })
        .collect::<Vec<_>>();
    configurations.push(RunConfiguration {
        id: "current-file".to_string(),
        name: "Current File".to_string(),
        kind: "java.current-file".to_string(),
        module: Some(".".to_string()),
        main_class: None,
        toolchains: [("java".to_string(), "project-jdk".to_string())]
            .into_iter()
            .collect(),
        working_directory: ".".to_string(),
        jvm_arguments: Vec::new(),
        program_arguments: Vec::new(),
        maven_profiles: Vec::new(),
        disabled: false,
        source: None,
    });
    let inputs = project_inputs(&root)?;
    let generated = RunConfigurationDocument {
        version: VERSION,
        generator: Some(GeneratorMetadata {
            fingerprint: fingerprint_from_inputs(&inputs),
            inputs,
        }),
        configurations,
    };
    let requirements = detect_requirements(&root)?;
    Ok(
        json!({ "generated": generated, "toolchainRequirements": requirements, "entryCount": entry_count }),
    )
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
            matches!(component, Component::ParentDir | Component::RootDir | Component::Prefix(_))
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
        validate_version_value(manifest)?;
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
        if let Some(module) = configuration
            .module
            .as_deref()
            .filter(|value| *value != ".")
        {
            if !project_directory_exists(&root, module) {
                configuration.disabled = true;
                diagnostics.push(json!({
                    "id": configuration.id,
                    "code": "missingModule",
                    "message": format!("Module directory does not exist: {module}")
                }));
                continue;
            }
        }
        if !project_directory_exists(&root, &configuration.working_directory) {
            configuration.disabled = true;
            diagnostics.push(json!({
                "id": configuration.id,
                "code": "missingWorkingDirectory",
                "message": format!(
                    "Working directory does not exist: {}",
                    configuration.working_directory
                )
            }));
            continue;
        }
        if let Some(main_class) = configuration.main_class.as_deref() {
            if !main_class_exists(&root, main_class)? {
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
        "workingDirectory": working_directory,
        "jvmArguments": split_arguments(&request.jvm_arguments),
        "programArguments": split_arguments(&request.program_arguments),
        "mavenProfiles": request.maven_profiles.into_iter().collect::<std::collections::BTreeSet<_>>()
    });
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
    let mut configuration = json!({
        "id": id,
        "name": name,
        "type": configuration_kind,
        "module": module,
        "toolchains": {"java": "project-jdk", "maven": "project-maven"},
        "workingDirectory": ".",
        "jvmArguments": [],
        "programArguments": [],
        "mavenProfiles": []
    });
    if !main_class.is_empty() {
        configuration["mainClass"] = json!(main_class);
    }
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
    let kind = config["type"].as_str().unwrap_or("");
    let mut jvm_arguments = config["jvmArguments"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let program_arguments = config["programArguments"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut arguments = Vec::new();
    let is_current = kind == "java.current-file";
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
    } else {
        arguments.extend([json!("-B"), json!("-ntp")]);
        if let Some(module) = config["module"].as_str().filter(|m| *m != ".") {
            arguments.extend([json!("-pl"), json!(module)]);
        }
        if let Some(profiles) = config["mavenProfiles"].as_array().filter(|p| !p.is_empty()) {
            arguments.extend([
                json!("-P"),
                json!(profiles
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(",")),
            ]);
        }
        if let Some(main) = config["mainClass"].as_str() {
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
        "workingDirectory": config["workingDirectory"].as_str().unwrap_or("."),
        "environment": {
            "JAVA_HOME": { "toolchain": java_toolchain, "property": "home" }
        }
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
    if !matches!(
        configuration.kind.as_str(),
        "java.current-file" | "spring-boot.maven" | "maven.module"
    ) {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported run configuration type",
        )
        .with_details(configuration.kind.clone()));
    }
    for (field, value) in [
        ("module", configuration.module.as_deref().unwrap_or(".")),
        ("workingDirectory", configuration.working_directory.as_str()),
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
    serde_json::from_str(&text).map(Some).map_err(|e| {
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
    serde_json::from_str(&text).map(Some).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })
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

fn detect_requirements(root: &Path) -> Result<ToolchainRequirementsDocument, CoreError> {
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
    let mut toolchains = BTreeMap::from([("project-jdk".to_string(), jdk)]);
    if root.join("pom.xml").is_file() || root.join("mvnw").is_file() {
        toolchains.insert("project-maven".to_string(), maven);
    }
    Ok(ToolchainRequirementsDocument {
        version: VERSION,
        toolchains,
    })
}

fn toolchain_diagnostics(
    root: &Path,
    candidates: &[ToolchainCandidate],
) -> Result<Vec<Value>, CoreError> {
    let Some(requirements) = read_requirements(root)? else {
        return Ok(Vec::new());
    };
    validate_version(requirements.version)?;
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
        Some(".git" | ".lithe" | ".idea" | ".gradle" | "target" | "build")
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
        )
    )
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
