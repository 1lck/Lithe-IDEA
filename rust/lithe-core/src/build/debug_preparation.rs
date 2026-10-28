//! Native executable preparation uses a same-package DebugAdapter Registry entry.
//! Providers own build facts; Core validates portable data and declared bindings.

use super::decode::{self, Workspace};
use super::manifest::{BuildSystemDeclaration, RunDeclaration, TaskSource};
use super::plans;
use super::run_preparation::{self, DecodeRunPreparationRequest, PrepareRunRequest};
use crate::debug::adapters::{DebugAdapterDeclaration, DebugRequest};
use crate::plugins::declarative::Validation;
use serde::Deserialize;
use serde_json::{json, Value};

/// No backend-selected adapter, process, endpoint, or arbitrary DAP arguments.
pub(crate) fn adapter<'a>(
    run: &RunDeclaration,
    adapters: &'a [DebugAdapterDeclaration],
) -> Validation<&'a DebugAdapterDeclaration> {
    let invalid = || {
        plans::invalid_selection("Native debug preparation needs a same-plugin launch adapter with program, cwd, args and env target bindings, without overriding defaults.")
    };
    let id = &run.debug.as_ref().ok_or_else(invalid)?.adapter;
    let adapter = adapters
        .iter()
        .find(|adapter| &adapter.id == id)
        .ok_or_else(invalid)?;
    let configuration = adapter
        .configurations
        .as_ref()
        .and_then(|configs| configs.launch.as_ref())
        .ok_or_else(invalid)?;
    let bindings = configuration.target_bindings.as_ref().ok_or_else(invalid)?;
    if run.source != TaskSource::Provider
        || !adapter.requests.contains(&DebugRequest::Launch)
        || bindings.program.as_deref() != Some("target.path")
        || bindings.cwd.as_deref() != Some("target.workingDirectory")
        || bindings.args.as_deref() != Some("target.arguments")
        || bindings.env.as_deref() != Some("target.environment")
        || bindings.process_id.is_some()
        || configuration.arguments.as_ref().is_some_and(|args| {
            ["program", "cwd", "args", "env"]
                .iter()
                .any(|key| args.contains_key(*key))
        })
        || !adapter
            .selectors
            .iter()
            .any(|selector| selector.target_kinds.contains(&"executable".to_string()))
    {
        return Err(invalid());
    }
    Ok(adapter)
}

/// Validates the ordinary run selector before changing its method and admission.
pub(crate) fn plan(
    build: &BuildSystemDeclaration,
    request: &PrepareRunRequest,
) -> Validation<Value> {
    let mut value = run_preparation::plan(build, request)?;
    if !build
        .run
        .iter()
        .any(|run| run.id == request.run && run.debug.is_some())
    {
        return Err(plans::unavailable(build, "debug preparation"));
    }
    value["provider"]["method"] = json!("lithe/build/prepareDebug");
    value["decoder"] = json!("litheDebugPreparation");
    Ok(value)
}

/// The host keeps the selected run separate from the untrusted provider result.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeDebugPreparationRequest {
    #[serde(flatten)]
    pub(crate) base: DecodeRunPreparationRequest,
    pub(crate) run: String,
}

/// Reuses bounded argv/environment/cwd validation without accepting an executable command.
pub(crate) fn decode(
    build: &BuildSystemDeclaration,
    request: &DecodeDebugPreparationRequest,
) -> Validation<Value> {
    let run = build
        .run
        .iter()
        .find(|run| run.id == request.run && run.debug.is_some())
        .ok_or_else(|| plans::unavailable(build, "debug preparation"))?;
    let invalid = || decode::invalid_output("Invalid provider native debug preparation result.");
    let object = request.base.result.as_object().ok_or_else(invalid)?;
    if object.len() != 4
        || !["program", "arguments", "workingDirectory", "environment"]
            .iter()
            .all(|key| object.contains_key(*key))
    {
        return Err(invalid());
    }
    let program = decode::request_path(object["program"].as_str().ok_or_else(invalid)?, "program")
        .map_err(|_| invalid())?;
    let root = decode::request_path(&request.base.root, "root")?;
    let workspace = Workspace::new(&request.base.workspace_root)?;
    let instance = workspace
        .read_path(&root)
        .filter(|path| path.is_dir())
        .ok_or_else(invalid)?;
    if !decode::contains(&root, &program)
        || !workspace
            .read_path(&program)
            .is_some_and(|path| path.is_file() && path.starts_with(&instance))
    {
        return Err(invalid());
    }
    let validated = run_preparation::process_fields(&request.base)?;
    Ok(
        json!({"adapter":run.debug.as_ref().expect("selected debug declaration").adapter,
        "root":root,"program":program,"arguments":validated["arguments"],"environment":validated["environment"],"workingDirectory":validated["workingDirectory"]}),
    )
}
