//! `lithe/host/run/start`: the parameters a plugin backend hands the host to start a Run session.
//!
//! The process has the shape a build provider's run preparation returns, so both go through
//! the same bounded-argument, environment and workspace-directory checks. The executable is
//! either a tool the plugin required by definition ID or a file packaged with the plugin; the
//! host resolves it and owns the process. Nothing here starts a process or writes a file.

use super::decode;
use super::run_preparation::{
    process_fields, valid_configuration_type, DecodeRunPreparationRequest, MAX_ARGUMENT_BYTES,
};
use crate::lsp::interface::plugin_function::is_function_id;
use crate::plugins::declarative::{
    decode_payload, outcome, validate_manifest_value, PluginRejection, Validation,
};
use crate::protocol::CoreError;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

const MAX_LABEL_CHARS: usize = 256;
const MAX_TEMPORARY_FILES: usize = 4;
const MAX_TEMPORARY_FILE_BYTES: usize = 4 * 1024 * 1024;
const MAX_TEMPORARY_NAME_BYTES: usize = 64;
const MAX_PACKAGED_PATH_BYTES: usize = 4096;
const MAX_RERUN_DATA_BYTES: usize = 64 * 1024;
/// How a process argument or environment value names a temporary file.
const TEMPORARY_FILE_REFERENCE: &str = "${temporaryFile:";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecodeStartPayload {
    /// The plugin's manifest; its `requiresTools` limits the tools a run may start.
    manifest: Value,
    /// Absolute root of the workspace the run belongs to.
    workspace_root: String,
    /// Absolute directory the host created for this run's temporary files; required when the
    /// run has any.
    #[serde(default)]
    temporary_directory: Option<String>,
    params: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartParams {
    /// A reference the host resolved before the service saw the request.
    #[serde(default, rename = "context")]
    _context: Option<Value>,
    label: String,
    process: Map<String, Value>,
    #[serde(default)]
    temporary_files: Vec<TemporaryFile>,
    #[serde(default)]
    debug: Option<StartDebug>,
    #[serde(default)]
    rerun: Option<Rerun>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TemporaryFile {
    name: String,
    contents: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartDebug {
    configuration_type: String,
    target: Map<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Rerun {
    function: String,
    data: Value,
}

fn invalid(field: &str, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.run.invalidStart", field, message)
}

/// `run.decodeStart`: the normalized start with its executable reference, process, the files
/// to write with their final paths, and the debug and rerun choices.
pub(crate) fn run_decode_start_command(payload: Value) -> Result<Value, CoreError> {
    let payload: DecodeStartPayload = decode_payload(payload, "run.decodeStart")?;
    Ok(outcome(
        validate_manifest_value(payload.manifest.clone())
            .and_then(|manifest| decode_start(&payload, manifest.required_tools()))
            .map(|start| ("start", start)),
    ))
}

fn decode_start(payload: &DecodeStartPayload, required_tools: &[String]) -> Validation<Value> {
    let params: StartParams = serde_json::from_value(payload.params.clone())
        .map_err(|_| invalid("params", "The run start parameters are malformed."))?;
    check_label(&params.label)?;
    let executable = executable(&params.process, required_tools)?;
    let files = temporary_files(
        &params.temporary_files,
        payload.temporary_directory.as_deref(),
    )?;
    for key in params.process.keys() {
        if !["executable", "arguments", "workingDirectory", "environment"].contains(&key.as_str()) {
            return Err(invalid(
                &format!("process.{key}"),
                "The process has no such field.",
            ));
        }
    }
    let fields = process_fields(&DecodeRunPreparationRequest {
        workspace_root: payload.workspace_root.clone(),
        root: ".".to_string(),
        result: Value::Object(params.process.clone()),
        launch_options: None,
    })
    .map_err(|_| {
        invalid(
            "process",
            "The process arguments, directory or environment are invalid.",
        )
    })?;
    let paths: BTreeMap<&str, &str> = files
        .iter()
        .map(|file| (file.name.as_str(), file.path.as_str()))
        .collect();
    let arguments = fields["arguments"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(index, argument)| {
            substitute(
                argument.as_str().unwrap_or_default(),
                &paths,
                &format!("process.arguments[{index}]"),
            )
        })
        .collect::<Validation<Vec<_>>>()?;
    let mut environment = Map::new();
    for (key, value) in fields["environment"].as_object().into_iter().flatten() {
        environment.insert(
            key.clone(),
            Value::String(substitute(
                value.as_str().unwrap_or_default(),
                &paths,
                &format!("process.environment.{key}"),
            )?),
        );
    }
    let mut start = json!({
        "label": params.label,
        "executable": executable,
        "arguments": arguments,
        "workingDirectory": fields["workingDirectory"],
        "environment": environment,
        "temporaryFiles": files
            .iter()
            .map(|file| json!({"path": file.path, "contents": file.contents}))
            .collect::<Vec<_>>(),
    });
    if let Some(debug) = &params.debug {
        start["debug"] = start_debug(debug)?;
    }
    if let Some(rerun) = &params.rerun {
        start["rerun"] = rerun_target(rerun)?;
    }
    Ok(start)
}

fn check_label(label: &str) -> Validation<()> {
    let characters = label.chars().count();
    if label.trim().is_empty()
        || characters > MAX_LABEL_CHARS
        || label.chars().any(char::is_control)
    {
        return Err(invalid(
            "label",
            "A label is 1 to 256 characters without control characters.",
        ));
    }
    Ok(())
}

/// A tool the manifest requires, or a relative file inside the plugin's package.
fn executable(process: &Map<String, Value>, required_tools: &[String]) -> Validation<Value> {
    let executable = process
        .get("executable")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("process.executable", "The process names no executable."))?;
    let text = |key: &str| executable.get(key).and_then(Value::as_str);
    match (text("kind"), executable.len()) {
        (Some("tool"), 2) => {
            let tool = text("tool").unwrap_or_default();
            if !required_tools.iter().any(|required| required == tool) {
                return Err(invalid(
                    "process.executable.tool",
                    "The tool is not listed in the manifest's requiresTools.",
                ));
            }
            Ok(json!({"kind": "toolchain", "value": tool}))
        }
        (Some("packaged"), 2) => {
            let path = text("path").unwrap_or_default();
            if path.is_empty()
                || path.len() > MAX_PACKAGED_PATH_BYTES
                || decode::request_path(path, "executable").map_or(true, |clean| clean != path)
            {
                return Err(invalid(
                    "process.executable.path",
                    "A packaged executable is a normalized relative path inside the plugin.",
                ));
            }
            Ok(json!({"kind": "packaged", "value": path}))
        }
        _ => Err(invalid(
            "process.executable",
            "An executable is {kind:\"tool\",tool} or {kind:\"packaged\",path}.",
        )),
    }
}

/// A temporary file the host writes before the process starts.
struct PlannedFile {
    name: String,
    path: String,
    contents: String,
}

fn temporary_files(
    files: &[TemporaryFile],
    directory: Option<&str>,
) -> Validation<Vec<PlannedFile>> {
    if files.len() > MAX_TEMPORARY_FILES {
        return Err(invalid(
            "temporaryFiles",
            "A run has at most 4 temporary files.",
        ));
    }
    if files.is_empty() {
        return Ok(Vec::new());
    }
    let directory = directory
        .filter(|directory| {
            !directory.is_empty()
                && directory.len() <= MAX_PACKAGED_PATH_BYTES
                && !directory.contains('\0')
                && std::path::Path::new(directory).is_absolute()
        })
        .ok_or_else(|| {
            invalid(
                "temporaryDirectory",
                "The host supplies an absolute temporary directory for temporary files.",
            )
        })?;
    let directory = directory.trim_end_matches(['/', '\\']);
    let mut names = BTreeSet::new();
    let mut planned = Vec::new();
    for (index, file) in files.iter().enumerate() {
        if !valid_temporary_name(&file.name) || !names.insert(file.name.as_str()) {
            return Err(invalid(
                &format!("temporaryFiles[{index}].name"),
                "A temporary file name is unique, 1 to 64 letters, digits, '.', '_' or '-', and starts with a letter or digit.",
            ));
        }
        if file.contents.len() > MAX_TEMPORARY_FILE_BYTES || file.contents.contains('\0') {
            return Err(invalid(
                &format!("temporaryFiles[{index}].contents"),
                "A temporary file holds at most 4 MiB of text.",
            ));
        }
        planned.push(PlannedFile {
            name: file.name.clone(),
            path: format!("{directory}{}{}", std::path::MAIN_SEPARATOR, file.name),
            contents: file.contents.clone(),
        });
    }
    Ok(planned)
}

fn valid_temporary_name(name: &str) -> bool {
    name.len() <= MAX_TEMPORARY_NAME_BYTES
        && name
            .bytes()
            .next()
            .is_some_and(|first| first.is_ascii_alphanumeric())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// Replaces every `${temporaryFile:<name>}` with the file's path. Any other `${...}` is data.
fn substitute(text: &str, paths: &BTreeMap<&str, &str>, field: &str) -> Validation<String> {
    let mut output = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(TEMPORARY_FILE_REFERENCE) {
        output.push_str(&rest[..start]);
        let after = &rest[start + TEMPORARY_FILE_REFERENCE.len()..];
        let (name, tail) = after
            .split_once('}')
            .ok_or_else(|| invalid(field, "A temporary file reference is not closed with '}'."))?;
        let path = paths.get(name).ok_or_else(|| {
            invalid(
                field,
                "A temporary file reference names no declared temporary file.",
            )
        })?;
        output.push_str(path);
        rest = tail;
    }
    output.push_str(rest);
    if output.len() > MAX_ARGUMENT_BYTES {
        return Err(invalid(
            field,
            "The value is too long once temporary file paths are inserted.",
        ));
    }
    Ok(output)
}

fn start_debug(debug: &StartDebug) -> Validation<Value> {
    if !valid_configuration_type(&debug.configuration_type) {
        return Err(invalid(
            "debug.configurationType",
            "The configuration type is bounded text without control characters.",
        ));
    }
    let kind = debug.target.get("kind").and_then(Value::as_str);
    let target = match (kind, debug.target.len()) {
        (Some("launch"), 1) => json!({"kind": "launch"}),
        (Some("connection"), 2) => {
            let port = debug
                .target
                .get("port")
                .and_then(Value::as_u64)
                .filter(|port| (1..=65535).contains(port))
                .ok_or_else(|| {
                    invalid(
                        "debug.target.port",
                        "A connection target names a port from 1 to 65535.",
                    )
                })?;
            json!({"kind": "connection", "port": port})
        }
        _ => {
            return Err(invalid(
                "debug.target",
                "A debug target is {kind:\"launch\"} or {kind:\"connection\",port}.",
            ))
        }
    };
    Ok(json!({"configurationType": debug.configuration_type, "target": target}))
}

fn rerun_target(rerun: &Rerun) -> Validation<Value> {
    if !is_function_id(&rerun.function) {
        return Err(invalid(
            "rerun.function",
            "A rerun names one of the plugin's registered function IDs.",
        ));
    }
    // The function protocol passes an object as the params of a function, so the data is one.
    if !rerun.data.is_object() {
        return Err(invalid(
            "rerun.data",
            "Rerun data is a JSON object, the params of the function.",
        ));
    }
    if serde_json::to_vec(&rerun.data).map_or(usize::MAX, |bytes| bytes.len())
        > MAX_RERUN_DATA_BYTES
    {
        return Err(invalid("rerun.data", "Rerun data is at most 64 KiB."));
    }
    Ok(json!({"function": rerun.function, "data": rerun.data}))
}
