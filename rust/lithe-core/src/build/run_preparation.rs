//! Provider-owned run preparation and validation of portable launch plans.
//! Upstream providers own build/classpath facts; Core only validates selectors,
//! bounded arguments, executable references, and workspace path containment.

use super::decode::{self, Workspace};
use super::manifest::{BuildExecution, BuildSystemDeclaration, TaskSource};
use super::plans::{self, OutputPlanRequest, SelectedEntity};
use crate::plugins::declarative::{is_bare_command, is_identifier, Validation};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

const MAX_ARGUMENTS: usize = 1024;
const MAX_ARGUMENT_BYTES: usize = 65536;
const MAX_ENVIRONMENT: usize = 64;

/// Resolved user choices; only the owning provider interprets runtime semantics.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LaunchOptions {
    execution: BuildExecution,
    runtime_arguments: Vec<String>,
    arguments: Vec<String>,
    environment: BTreeMap<String, String>,
    #[serde(
        default,
        deserialize_with = "optional_launch_string",
        skip_serializing_if = "Option::is_none"
    )]
    working_directory: Option<String>,
    #[serde(
        default,
        deserialize_with = "optional_launch_string",
        skip_serializing_if = "Option::is_none"
    )]
    entrypoint: Option<String>,
    #[serde(
        default,
        deserialize_with = "optional_runtime_debug",
        skip_serializing_if = "Option::is_none"
    )]
    debug: Option<RuntimeDebug>,
}

/// A host-selected loopback JVM endpoint; providers may not select a remote host.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeDebug {
    runtime: String,
    port: u16,
}

/// Omitted debug means Run; explicit null must never silently discard Debug.
fn optional_runtime_debug<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<RuntimeDebug>, D::Error> {
    RuntimeDebug::deserialize(deserializer).map(Some)
}

/// Optional means absent; an explicitly null launch choice is malformed.
fn optional_launch_string<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    String::deserialize(deserializer).map(Some)
}

impl LaunchOptions {
    /// Bounds wire values and verifies an explicit directory in the host workspace.
    fn validate(&self, workspace_root: Option<&str>) -> Validation<()> {
        let invalid = || plans::invalid_selection("Invalid provider launch options.");
        if self.debug.as_ref().is_some_and(|debug| {
            debug.runtime != "jvm" || debug.port == 0 || self.execution != BuildExecution::Service
        }) {
            return Err(invalid());
        }
        for arguments in [&self.runtime_arguments, &self.arguments] {
            if arguments.len() > MAX_ARGUMENTS
                || arguments
                    .iter()
                    .any(|arg| arg.len() > MAX_ARGUMENT_BYTES || arg.contains('\0'))
            {
                return Err(invalid());
            }
        }
        if self.environment.len() > MAX_ENVIRONMENT
            || self.environment.iter().any(|(key, value)| {
                !valid_environment_key(key)
                    || value.len() > MAX_ARGUMENT_BYTES
                    || value.contains('\0')
            })
            || self
                .entrypoint
                .as_ref()
                .is_some_and(|value| value.is_empty() || value.len() > 4096 || value.contains('\0'))
        {
            return Err(invalid());
        }
        if let Some(cwd) = &self.working_directory {
            if cwd.is_empty()
                || cwd.len() > 4096
                || decode::request_path(cwd, "workingDirectory")? != *cwd
            {
                return Err(invalid());
            }
            let workspace = Workspace::new(workspace_root.ok_or_else(invalid)?)?;
            if !workspace.read_path(cwd).is_some_and(|path| path.is_dir()) {
                return Err(invalid());
            }
        }
        Ok(())
    }
}

/// Portable environment names shared by user inputs and returned launch plans.
fn valid_environment_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key.bytes().enumerate().all(|(index, byte)| {
            byte == b'_' || byte.is_ascii_alphabetic() || index > 0 && byte.is_ascii_digit()
        })
}

/// Host-selected model target and the run declaration that can prepare it.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PrepareRunRequest {
    #[serde(flatten)]
    pub(crate) base: OutputPlanRequest,
    pub(crate) run: String,
    pub(crate) target: SelectedEntity,
    #[serde(default)]
    pub(crate) user_arguments: Vec<String>,
    #[serde(default)]
    pub(crate) workspace_root: Option<String>,
    #[serde(default)]
    pub(crate) launch_options: Option<LaunchOptions>,
}

/// Builds the public request without inferring language-specific launch facts.
pub(crate) fn plan(
    build_system: &BuildSystemDeclaration,
    request: &PrepareRunRequest,
    protocol_version: u32,
) -> Validation<Value> {
    let declaration = build_system
        .run
        .iter()
        .find(|run| run.id == request.run && run.source == TaskSource::Provider)
        .ok_or_else(|| plans::unavailable(build_system, "this provider run"))?;
    let execution = declaration.execution.unwrap_or(BuildExecution::Application);
    match &request.launch_options {
        Some(options) => {
            if options.debug.is_some() && protocol_version < 11 {
                return Err(plans::invalid_selection(
                    "Runtime debug options require buildProviders 11.",
                ));
            }
            if protocol_version < 10 || options.execution != execution {
                return Err(plans::invalid_selection(
                    "Launch options require buildProviders 10 and the declared execution kind.",
                ));
            }
            options.validate(request.workspace_root.as_deref())?;
        }
        None if execution != BuildExecution::Application => {
            return Err(plans::invalid_selection(
                "Service and task runs require launch options.",
            ));
        }
        None => {}
    }
    if request.base.output_file.is_some() {
        return Err(plans::invalid_selection(
            "Provider run preparation does not use an output file.",
        ));
    }
    let context = plans::PlanContext::new(build_system, &request.base.base)?;
    let project = request
        .base
        .project
        .as_ref()
        .ok_or_else(|| plans::invalid_selection("A run target needs its project."))?;
    let project = plans::selection(project, &context.root, None, "project")?;
    let target = plans::selection(
        &request.target,
        &context.root,
        Some(&project.path),
        "target",
    )?;
    if !declaration
        .from_targets
        .as_ref()
        .is_some_and(|from| target.tags.iter().any(|tag| from.tags.contains(tag)))
    {
        return Err(plans::invalid_selection(
            "This run does not apply to the selected target.",
        ));
    }
    plans::check_argument_limits(&request.user_arguments)?;
    let mut params = plans::provider_hints(&request.base)?;
    params.insert("run".to_string(), json!(declaration.id));
    params.insert("userArguments".to_string(), json!(request.user_arguments));
    if let Some(options) = &request.launch_options {
        params.insert("launchOptions".to_string(), json!(options));
    }
    for (name, selected) in [("project", project), ("target", target)] {
        params.insert(
            name.to_string(),
            json!({"name":selected.name,"path":selected.path,
            "tags":selected.tags,"properties":selected.properties}),
        );
    }
    let provider = build_system
        .provider
        .as_ref()
        .ok_or_else(|| plans::unavailable(build_system, "a provider"))?;
    Ok(context.provider_plan(
        provider,
        "lithe/build/prepareRun",
        "litheRunPreparation",
        params,
    ))
}

/// The platform supplies its writable workspace root, never an installation path.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeRunPreparationRequest {
    pub(crate) workspace_root: String,
    pub(crate) root: String,
    pub(crate) result: Value,
    #[serde(default)]
    pub(crate) launch_options: Option<LaunchOptions>,
}

/// Validates all launch data before a platform executable resolver sees it.
pub(crate) fn decode(
    build_system: &BuildSystemDeclaration,
    request: &DecodeRunPreparationRequest,
    protocol_version: u32,
) -> Validation<Value> {
    if !build_system
        .run
        .iter()
        .any(|run| run.source == TaskSource::Provider)
    {
        return Err(plans::unavailable(build_system, "run preparation"));
    }
    let invalid = || decode::invalid_output("Invalid provider run preparation result.");
    if request.launch_options.is_some() && protocol_version < 10 {
        return Err(invalid());
    }
    if request
        .launch_options
        .as_ref()
        .is_some_and(|options| options.debug.is_some())
        && protocol_version < 11
    {
        return Err(invalid());
    }
    let value = &request.result;
    if serde_json::to_vec(value).map_or(usize::MAX, |bytes| bytes.len()) > decode::MAX_OUTPUT_BYTES
    {
        return Err(invalid());
    }
    let executable = value.get("executable").ok_or_else(invalid)?;
    let kind = executable["kind"].as_str().ok_or_else(invalid)?;
    let name = executable["value"].as_str().ok_or_else(invalid)?;
    if name.len() > 120
        || !(kind == "command" && is_bare_command(name)
            || kind == "toolchain" && is_identifier(name))
    {
        return Err(invalid());
    }
    let mut fields = process_fields(request)?;
    fields["executable"] = json!({"kind":kind,"value":name});
    Ok(fields)
}

/// Common bounded arguments, environment and workspace-contained directory.
pub(super) fn process_fields(request: &DecodeRunPreparationRequest) -> Validation<Value> {
    let invalid = || decode::invalid_output("Invalid provider process preparation result.");
    let value = &request.result;
    if serde_json::to_vec(value).map_or(usize::MAX, |bytes| bytes.len()) > decode::MAX_OUTPUT_BYTES
    {
        return Err(invalid());
    }
    let args = value["arguments"]
        .as_array()
        .filter(|args| args.len() <= MAX_ARGUMENTS)
        .ok_or_else(invalid)?;
    if args.iter().any(|arg| {
        !arg.as_str()
            .is_some_and(|text| text.len() <= MAX_ARGUMENT_BYTES && !text.contains('\0'))
    }) {
        return Err(invalid());
    }
    let root = decode::request_path(&request.root, "root")?;
    let cwd = value["workingDirectory"].as_str().ok_or_else(invalid)?;
    let cwd = decode::request_path(cwd, "workingDirectory").map_err(|_| invalid())?;
    let workspace = Workspace::new(&request.workspace_root)?;
    let instance = workspace
        .read_path(&root)
        .filter(|path| path.is_dir())
        .ok_or_else(invalid)?;
    let override_cwd = request
        .launch_options
        .as_ref()
        .and_then(|options| options.working_directory.as_deref());
    if let Some(options) = &request.launch_options {
        options
            .validate(Some(&request.workspace_root))
            .map_err(|_| invalid())?;
    }
    let permitted = if let Some(expected) = override_cwd {
        cwd == expected && workspace.read_path(&cwd).is_some_and(|path| path.is_dir())
    } else {
        decode::contains(&root, &cwd)
            && workspace
                .read_path(&cwd)
                .is_some_and(|path| path.is_dir() && path.starts_with(&instance))
    };
    if !permitted {
        return Err(invalid());
    }
    let environment = value["environment"]
        .as_object()
        .filter(|env| env.len() <= MAX_ENVIRONMENT)
        .ok_or_else(invalid)?;
    for (key, value) in environment {
        if !valid_environment_key(key)
            || !value
                .as_str()
                .is_some_and(|text| text.len() <= MAX_ARGUMENT_BYTES && !text.contains('\0'))
        {
            return Err(invalid());
        }
    }
    Ok(json!({"arguments":args,"workingDirectory":cwd,"environment":environment}))
}
