//! Provider-owned run preparation and validation of portable launch plans.
//! Upstream providers own build/classpath facts; Core only validates selectors,
//! bounded arguments, executable references, and workspace path containment.

use super::decode::{self, Workspace};
use super::manifest::{BuildSystemDeclaration, TaskSource};
use super::plans::{self, OutputPlanRequest, SelectedEntity};
use crate::plugins::declarative::{is_bare_command, is_identifier, Validation};
use serde::Deserialize;
use serde_json::{json, Value};

const MAX_ARGUMENTS: usize = 1024;
const MAX_ARGUMENT_BYTES: usize = 65536;
const MAX_ENVIRONMENT: usize = 64;

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
}

/// Builds the public request without inferring language-specific launch facts.
pub(crate) fn plan(
    build_system: &BuildSystemDeclaration,
    request: &PrepareRunRequest,
) -> Validation<Value> {
    let declaration = build_system
        .run
        .iter()
        .find(|run| run.id == request.run && run.source == TaskSource::Provider)
        .ok_or_else(|| plans::unavailable(build_system, "this provider run"))?;
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
}

/// Validates all launch data before a platform executable resolver sees it.
pub(crate) fn decode(
    build_system: &BuildSystemDeclaration,
    request: &DecodeRunPreparationRequest,
) -> Validation<Value> {
    if !build_system
        .run
        .iter()
        .any(|run| run.source == TaskSource::Provider)
    {
        return Err(plans::unavailable(build_system, "run preparation"));
    }
    let invalid = || decode::invalid_output("Invalid provider run preparation result.");
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
    if !decode::contains(&root, &cwd)
        || !workspace
            .read_path(&cwd)
            .is_some_and(|path| path.is_dir() && path.starts_with(&instance))
    {
        return Err(invalid());
    }
    let environment = value["environment"]
        .as_object()
        .filter(|env| env.len() <= MAX_ENVIRONMENT)
        .ok_or_else(invalid)?;
    for (key, value) in environment {
        let valid_key = !key.is_empty()
            && key.len() <= 128
            && key.bytes().enumerate().all(|(index, byte)| {
                byte == b'_' || byte.is_ascii_alphabetic() || index > 0 && byte.is_ascii_digit()
            });
        if !valid_key
            || !value
                .as_str()
                .is_some_and(|text| text.len() <= MAX_ARGUMENT_BYTES && !text.contains('\0'))
        {
            return Err(invalid());
        }
    }
    Ok(
        json!({"executable":{"kind":kind,"value":name},"arguments":args,
        "workingDirectory":cwd,"environment":environment}),
    )
}
