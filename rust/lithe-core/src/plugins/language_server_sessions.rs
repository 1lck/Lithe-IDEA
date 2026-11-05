//! Plugin-owned language server sessions (plan API-25, with API-20 state).
//!
//! A plugin whose backend drives its own language server declares, at
//! `languageServers` 3, which requests and notifications the backend may
//! send to that server, which `workspace/executeCommand` commands run one at
//! a time, which server notifications reach the backend, how long per-
//! workspace state is kept, and whether the server works on a remote
//! workspace. At `serverProcess` 3 the backend may also resolve the command
//! line each time the server starts (`launch.kind: "backend"`).
//!
//! Core validates those declarations, turns them into the session policy
//! the LSP engine enforces, decodes the backend's launch answer, and selects
//! state directories to prune. The host calls the function, creates the
//! directories, and starts the process; it never interprets the answer.

use super::declarative::{
    decode_payload, invalid, is_safe_relative_path, PluginRejection, Validation,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// How long the host waits for a launch function by default, in
/// milliseconds; a manifest may choose a value within the bounds below.
pub(crate) const RESOLVE_TIMEOUT_MILLISECONDS: u64 = 30_000;
const MIN_RESOLVE_TIMEOUT_MILLISECONDS: u64 = 1_000;
const MAX_RESOLVE_TIMEOUT_MILLISECONDS: u64 = 120_000;

/// How long a forwarded request may take when the backend names no timeout,
/// and the longest timeout it may name, in milliseconds.
pub(crate) const DEFAULT_REQUEST_TIMEOUT_MILLISECONDS: u64 = 60_000;
pub(crate) const MAX_REQUEST_TIMEOUT_MILLISECONDS: u64 = 300_000;

/// Most request or notification methods one server may expose to its
/// backend. Bounded so the policy stays a short list the engine scans.
const MAX_REQUEST_METHODS: usize = 64;
/// Most `workspace/executeCommand` commands one server may expose.
const MAX_COMMANDS: usize = 128;
/// Most server notifications forwarded to the backend.
const MAX_FORWARD_NOTIFICATIONS: usize = 32;
/// Longest method or command name, in UTF-8 bytes.
const MAX_NAME_BYTES: usize = 256;
/// Bounds of `state.retention`.
const MAX_RETENTION_ENTRIES: u32 = 64;
const MAX_RETENTION_DAYS: u32 = 365;
const SECONDS_PER_DAY: u64 = 86_400;

/// Bounds of one launch answer. An answer is an untrusted value from the
/// plugin backend, so every list and text it carries has a limit.
const MAX_ARGUMENTS: usize = 1024;
const MAX_ARGUMENT_BYTES: usize = 32 * 1024;
const MAX_ENVIRONMENT: usize = 256;
const MAX_ENVIRONMENT_VALUE_BYTES: usize = 32 * 1024;
const MAX_OPTIONS_BYTES: usize = 1024 * 1024;
const MAX_GATES: usize = 8;
const MAX_GATE_MATCH_BYTES: usize = 4 * 1024;
const MAX_WRITABLE_PATHS: usize = 32;

/// The request that carries server commands.
pub(crate) const EXECUTE_COMMAND: &str = "workspace/executeCommand";
/// The notification that replaces the server's settings. A backend may
/// always send it, because only the backend knows the server's settings.
pub(crate) const DID_CHANGE_CONFIGURATION: &str = "workspace/didChangeConfiguration";

/// Methods the host sends itself to keep the session and the open documents
/// consistent. A backend sending one of them would desynchronize the host's
/// view of the server, so no declaration may name them.
const HOST_OWNED_METHODS: &[&str] = &[
    "initialize",
    "initialized",
    "shutdown",
    "exit",
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didClose",
    "textDocument/didSave",
    "textDocument/willSave",
    "textDocument/willSaveWaitUntil",
    "workspace/didChangeWorkspaceFolders",
];

/// Whether a method belongs to the host's own session management. `$/`
/// methods are protocol plumbing such as cancellation and progress.
pub(crate) fn is_host_owned_method(method: &str) -> bool {
    method.starts_with("$/") || HOST_OWNED_METHODS.contains(&method)
}

/// The `languageServers` 3 session fields, flattened into the server's
/// declaration. Every field is optional so a version 1 or 2 manifest that
/// names one can be refused with the field it used.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionDeclaration {
    /// Requests and notifications the backend may send to the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    request_methods: Option<Vec<String>>,
    /// Commands the backend may run through `workspace/executeCommand`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    commands: Option<Vec<String>>,
    /// Commands that run one at a time; a request for a command already
    /// running joins it instead of starting it again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    serialized_commands: Option<Vec<String>>,
    /// Server notifications forwarded to the backend.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    forward_notifications: Option<Vec<String>>,
    /// How the host keeps the server's per-workspace state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    state: Option<StateDeclaration>,
    /// Whether the server works on a remote workspace; supported when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    remote: Option<RemoteSupport>,
}

/// `state` of a language server: the host prunes its per-workspace state
/// directories by `retention` and offers to reset the current one.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StateDeclaration {
    scope: StateScope,
    retention: Retention,
}

/// What one state directory belongs to. Only workspaces exist today; the
/// field is explicit so another scope can be added without guessing.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum StateScope {
    Workspace,
}

/// How many inactive state directories are kept, and for how long.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Retention {
    max_entries: u32,
    max_age_days: u32,
}

impl Retention {
    fn validate(&self) -> Result<(), &'static str> {
        if !(1..=MAX_RETENTION_ENTRIES).contains(&self.max_entries) {
            return Err("maxEntries must be between 1 and 64.");
        }
        if !(1..=MAX_RETENTION_DAYS).contains(&self.max_age_days) {
            return Err("maxAgeDays must be between 1 and 365.");
        }
        Ok(())
    }
}

/// Whether the host may start the server for a remote workspace.
#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RemoteSupport {
    #[default]
    Supported,
    Unsupported,
}

impl SessionDeclaration {
    /// The first session field the manifest names, for refusing it below
    /// `languageServers` 3.
    fn first_declared(&self) -> Option<&'static str> {
        [
            ("requestMethods", self.request_methods.is_some()),
            ("commands", self.commands.is_some()),
            ("serializedCommands", self.serialized_commands.is_some()),
            ("forwardNotifications", self.forward_notifications.is_some()),
            ("state", self.state.is_some()),
            ("remote", self.remote.is_some()),
        ]
        .into_iter()
        .find_map(|(name, present)| present.then_some(name))
    }

    /// Whether the backend may talk to the server, which needs the
    /// `languageServer.request` permission.
    pub(crate) fn exposes_server(&self) -> bool {
        self.request_methods.as_ref().is_some_and(|m| !m.is_empty())
            || self
                .forward_notifications
                .as_ref()
                .is_some_and(|m| !m.is_empty())
    }

    /// Checks the session fields of the server at `field`.
    pub(crate) fn validate(&self, field: &str, capability_version: u32) -> Validation<()> {
        if capability_version < 3 {
            return match self.first_declared() {
                Some(name) => Err(invalid(
                    format!("{field}.{name}"),
                    "Language server session fields require languageServers 3.",
                )),
                None => Ok(()),
            };
        }
        let methods = unique_names(
            self.request_methods.as_deref(),
            &format!("{field}.requestMethods"),
            MAX_REQUEST_METHODS,
        )?;
        if let Some(method) = methods.iter().find(|method| is_host_owned_method(method)) {
            return Err(invalid(
                format!("{field}.requestMethods"),
                format!("The host sends {method} itself; a plugin backend cannot."),
            ));
        }
        let commands = unique_names(
            self.commands.as_deref(),
            &format!("{field}.commands"),
            MAX_COMMANDS,
        )?;
        // A command list without the request that carries it, or the
        // request without a list, would declare a grant nothing can use.
        if commands.is_empty() == methods.contains(EXECUTE_COMMAND) {
            return Err(invalid(
                format!("{field}.commands"),
                "commands are declared exactly when requestMethods lists workspace/executeCommand.",
            ));
        }
        let serialized = unique_names(
            self.serialized_commands.as_deref(),
            &format!("{field}.serializedCommands"),
            MAX_COMMANDS,
        )?;
        if let Some(command) = serialized
            .iter()
            .find(|command| !commands.contains(*command))
        {
            return Err(invalid(
                format!("{field}.serializedCommands"),
                format!("The serialized command {command} is not listed in commands."),
            ));
        }
        let forwarded = unique_names(
            self.forward_notifications.as_deref(),
            &format!("{field}.forwardNotifications"),
            MAX_FORWARD_NOTIFICATIONS,
        )?;
        if let Some(method) = forwarded.iter().find(|method| is_host_owned_method(method)) {
            return Err(invalid(
                format!("{field}.forwardNotifications"),
                format!("The host consumes {method} itself and cannot forward it."),
            ));
        }
        if let Some(state) = &self.state {
            state
                .retention
                .validate()
                .map_err(|message| invalid(format!("{field}.state.retention"), message))?;
        }
        Ok(())
    }

    /// The session policy the LSP engine enforces for this server, in the
    /// shape `lsp.startServer` accepts as `sessionPolicy`. Lists are sorted
    /// so equal declarations give equal policies.
    pub(crate) fn policy(&self, server_id: &str) -> Value {
        let sorted = |values: &Option<Vec<String>>| {
            values
                .iter()
                .flatten()
                .cloned()
                .collect::<BTreeSet<String>>()
        };
        let mut policy = json!({
            "serverID": server_id,
            "requestMethods": sorted(&self.request_methods),
            "commands": sorted(&self.commands),
            "serializedCommands": sorted(&self.serialized_commands),
            "forwardNotifications": sorted(&self.forward_notifications),
            "remote": self.remote.unwrap_or_default(),
            "gates": [],
        });
        if let Some(state) = &self.state {
            policy["state"] = json!(state);
        }
        policy
    }
}

/// Accepts an optional list of method or command names: at most `limit`,
/// each non-empty, without whitespace or control characters, and unique.
fn unique_names<'a>(
    values: Option<&'a [String]>,
    field: &str,
    limit: usize,
) -> Validation<BTreeSet<&'a str>> {
    let values = values.unwrap_or_default();
    if values.len() > limit {
        return Err(invalid(
            field,
            format!("At most {limit} entries are allowed."),
        ));
    }
    let mut names = BTreeSet::new();
    for value in values {
        if !is_protocol_name(value) {
            return Err(invalid(
                field,
                "Entries must be non-empty names without whitespace.",
            ));
        }
        if !names.insert(value.as_str()) {
            return Err(invalid(field, format!("{value} is listed twice.")));
        }
    }
    Ok(names)
}

/// A method or command name: short text without whitespace or controls.
pub(crate) fn is_protocol_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_NAME_BYTES
        && !value
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
}

/// Checks `launch.timeoutMilliseconds` of a backend launch.
pub(crate) fn validate_resolve_timeout(value: Option<u64>, field: &str) -> Validation<()> {
    match value {
        Some(milliseconds)
            if !(MIN_RESOLVE_TIMEOUT_MILLISECONDS..=MAX_RESOLVE_TIMEOUT_MILLISECONDS)
                .contains(&milliseconds) =>
        {
            Err(invalid(
                field,
                "timeoutMilliseconds must be between 1000 and 120000.",
            ))
        }
        _ => Ok(()),
    }
}

/// Writable host directories of one start, each already trimmed of a
/// trailing separator. Every path a launch answer may write lies in one.
pub(crate) struct LaunchDirectories<'a> {
    pub(crate) state: &'a str,
    pub(crate) workspace_state: &'a str,
    pub(crate) log: &'a str,
    pub(crate) temporary: &'a str,
}

impl LaunchDirectories<'_> {
    fn contains(&self, path: &str) -> bool {
        [self.state, self.workspace_state, self.log, self.temporary]
            .into_iter()
            .filter(|directory| !directory.is_empty())
            .any(|directory| is_within(path, directory))
    }
}

/// Whether `path` is `directory` or lies below it, compared as text.
/// Components `.` and `..` are refused, so text containment is real
/// containment once the host joins nothing further.
fn is_within(path: &str, directory: &str) -> bool {
    if path.contains('\0')
        || path
            .split(['/', '\\'])
            .any(|component| component == "." || component == "..")
    {
        return false;
    }
    match path.strip_prefix(directory) {
        Some("") => true,
        Some(rest) => rest.starts_with(['/', '\\']),
        None => false,
    }
}

/// Params of the launch function, apart from `context` and `tools`, which
/// the host attaches: the server, the machine, the writable directories,
/// and the plugin's effective settings.
pub(crate) fn resolve_params(
    server_id: &str,
    architecture: &str,
    directories: &LaunchDirectories<'_>,
    settings: &BTreeMap<String, Value>,
) -> Value {
    json!({
        "serverID": server_id,
        "platform": { "os": std::env::consts::OS, "arch": architecture },
        "stateDirectory": directories.state,
        "workspaceStateDirectory": directories.workspace_state,
        "logDirectory": directories.log,
        "temporaryDirectory": directories.temporary,
        "settings": settings,
    })
}

/// The launch function's answer.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LaunchAnswer {
    executable: AnsweredExecutable,
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default)]
    environment: BTreeMap<String, String>,
    #[serde(default)]
    initialization_options: Option<Value>,
    #[serde(default)]
    workspace_configuration: Option<Value>,
    #[serde(default)]
    gates: Vec<Gate>,
    #[serde(default)]
    writable_paths: Vec<String>,
}

/// The program the host starts: a file inside the plugin package, or the
/// executable the host resolved for one of the plugin's tool definitions.
#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum AnsweredExecutable {
    Packaged { path: String },
    Tool { tool: String },
}

/// A condition the server must reach before the backend's requests are
/// sent: until then the engine holds them in order.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Gate {
    pub(crate) id: String,
    until: GateCondition,
    pub(crate) method: String,
    #[serde(rename = "match")]
    pub(crate) pattern: Map<String, Value>,
}

/// What opens a gate. Only a server notification does today.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum GateCondition {
    Notification,
}

fn invalid_answer(message: impl Into<String>) -> PluginRejection {
    PluginRejection::new("plugin.launch.invalidResult", message)
}

fn serialized_bytes(value: &Value) -> usize {
    serde_json::to_vec(value).map_or(usize::MAX, |bytes| bytes.len())
}

/// Decodes and bounds a launch answer. The result is the start plan the
/// host runs, in the shape of a declarative launch plan, plus the gates
/// that join the session policy.
pub(crate) fn decode_answer(
    answer: Value,
    directories: &LaunchDirectories<'_>,
    tool_ids: &BTreeSet<&str>,
) -> Validation<(Value, Vec<Gate>)> {
    let answer: LaunchAnswer = serde_json::from_value(answer)
        .map_err(|error| invalid_answer(format!("The launch answer is malformed: {error}")))?;
    let mut package_paths = Vec::new();
    let launch = match answer.executable {
        AnsweredExecutable::Packaged { path } => {
            if !is_safe_relative_path(&path) {
                return Err(PluginRejection::new(
                    "plugin.launch.outsidePackage",
                    "The packaged executable must stay inside the plugin package.",
                ));
            }
            package_paths.push(path.clone());
            json!({ "kind": "packaged", "path": path })
        }
        AnsweredExecutable::Tool { tool } => {
            if !tool_ids.contains(tool.as_str()) {
                return Err(PluginRejection::new(
                    "plugin.launch.undeclaredTool",
                    format!("The plugin declares no tool definition {tool}."),
                ));
            }
            json!({ "kind": "tool", "tool": tool })
        }
    };
    if answer.arguments.len() > MAX_ARGUMENTS
        || answer
            .arguments
            .iter()
            .any(|argument| argument.len() > MAX_ARGUMENT_BYTES || argument.contains('\0'))
    {
        return Err(invalid_answer(
            "At most 1024 arguments of at most 32 KiB each, without NUL, are allowed.",
        ));
    }
    if answer.environment.len() > MAX_ENVIRONMENT
        || answer.environment.iter().any(|(name, value)| {
            name.is_empty()
                || name.contains(['=', '\0'])
                || value.contains('\0')
                || value.len() > MAX_ENVIRONMENT_VALUE_BYTES
        })
    {
        return Err(invalid_answer(
            "At most 256 environment variables with names without '=' and values of at most 32 KiB are allowed.",
        ));
    }
    for (name, options) in [
        ("initializationOptions", &answer.initialization_options),
        ("workspaceConfiguration", &answer.workspace_configuration),
    ] {
        if let Some(options) = options {
            if !options.is_object() || serialized_bytes(options) > MAX_OPTIONS_BYTES {
                return Err(invalid_answer(format!(
                    "{name} must be a JSON object of at most 1 MiB."
                )));
            }
        }
    }
    if answer.gates.len() > MAX_GATES {
        return Err(invalid_answer("At most 8 gates are allowed."));
    }
    let mut gate_ids = BTreeSet::new();
    for gate in &answer.gates {
        if !is_protocol_name(&gate.id) || !gate_ids.insert(gate.id.as_str()) {
            return Err(invalid_answer("Gate IDs must be unique non-empty names."));
        }
        if !is_protocol_name(&gate.method)
            || serialized_bytes(&Value::Object(gate.pattern.clone())) > MAX_GATE_MATCH_BYTES
        {
            return Err(invalid_answer(
                "A gate names a notification method and a match object of at most 4 KiB.",
            ));
        }
    }
    if answer.writable_paths.len() > MAX_WRITABLE_PATHS {
        return Err(invalid_answer("At most 32 writable paths are allowed."));
    }
    if let Some(path) = answer
        .writable_paths
        .iter()
        .find(|path| !directories.contains(path))
    {
        return Err(PluginRejection::new(
            "plugin.launch.unwritablePath",
            format!("{path} is not inside a directory the host provides for the server."),
        ));
    }
    let mut plan = json!({
        "launch": launch,
        "arguments": answer.arguments,
        "validationArguments": [],
        "runtimeRequirements": [],
        "environment": answer.environment,
        "writablePaths": answer.writable_paths.iter().collect::<BTreeSet<_>>(),
        "requiredDirectories": [],
        "requiredPackagePaths": package_paths,
    });
    if let Some(options) = answer.initialization_options {
        plan["initializationOptions"] = options;
    }
    if let Some(configuration) = answer.workspace_configuration {
        plan["workspaceConfiguration"] = configuration;
    }
    Ok((plan, answer.gates))
}

/// Whether a notification's params satisfy a gate's match object: every
/// member of the pattern is present with an equal value, and nested
/// objects match the same way.
pub(crate) fn matches_pattern(params: &Value, pattern: &Map<String, Value>) -> bool {
    let Some(params) = params.as_object() else {
        return pattern.is_empty();
    };
    pattern
        .iter()
        .all(|(key, expected)| match (params.get(key), expected) {
            (Some(actual @ Value::Object(_)), Value::Object(expected)) => {
                matches_pattern(actual, expected)
            }
            (Some(actual), expected) => actual == expected,
            (None, _) => false,
        })
}

/// `plugins.languageServers.stateRetention` request: the per-workspace
/// state directories of one server and the ones in use.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StateRetentionRequest {
    retention: Retention,
    now_unix_seconds: u64,
    entries: Vec<StateEntry>,
    /// Directories of workspaces that are open; they are never pruned.
    #[serde(default)]
    active_names: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StateEntry {
    name: String,
    last_modified_unix_seconds: u64,
}

/// A directory name the host may delete: one path component.
fn is_state_entry_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != "."
        && name != ".."
        && !name.contains(['/', '\\', '\0'])
}

/// `plugins.languageServers.stateRetention`: selects the inactive state
/// directories to delete. A directory older than `maxAgeDays` goes, and of
/// the rest only the newest fill the `maxEntries` the active ones leave.
/// Duplicate observations keep the newest time so a stale event never
/// deletes a directory that was reused since.
pub fn state_retention_command(payload: Value) -> Result<Value, CoreError> {
    let request: StateRetentionRequest =
        decode_payload(payload, "plugins.languageServers.stateRetention")?;
    request
        .retention
        .validate()
        .map_err(|message| CoreError::new(ErrorCode::InvalidRequest, message.to_string()))?;
    let active: BTreeSet<&str> = request.active_names.iter().map(String::as_str).collect();
    let mut newest: BTreeMap<&str, u64> = BTreeMap::new();
    for entry in &request.entries {
        if !is_state_entry_name(&entry.name) {
            continue;
        }
        let time = newest.entry(entry.name.as_str()).or_insert(0);
        *time = (*time).max(entry.last_modified_unix_seconds);
    }
    let kept_active = newest.keys().filter(|name| active.contains(*name)).count();
    let mut inactive: Vec<(&str, u64)> = newest
        .into_iter()
        .filter(|(name, _)| !active.contains(name))
        .collect();
    // Newest first; equal times fall back to the name so the result is stable.
    inactive.sort_by(|left, right| right.1.cmp(&left.1).then(left.0.cmp(right.0)));
    let slots = (request.retention.max_entries as usize).saturating_sub(kept_active);
    let max_age = u64::from(request.retention.max_age_days) * SECONDS_PER_DAY;
    let mut expired: Vec<&str> = inactive
        .iter()
        .enumerate()
        .filter(|(index, (_, time))| {
            *index >= slots || request.now_unix_seconds.saturating_sub(*time) > max_age
        })
        .map(|(_, (name, _))| *name)
        .collect();
    expired.sort_unstable();
    Ok(json!({ "expiredNames": expired }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn directories() -> LaunchDirectories<'static> {
        LaunchDirectories {
            state: "/state/metals",
            workspace_state: "/state/metals/workspaces/abc",
            log: "/logs/plugin",
            temporary: "/tmp/plugin",
        }
    }

    fn tools() -> BTreeSet<&'static str> {
        BTreeSet::from(["coursier"])
    }

    #[test]
    fn writable_paths_stay_in_host_directories() {
        let dirs = directories();
        assert!(dirs.contains("/state/metals/workspaces/abc/index"));
        assert!(dirs.contains("/tmp/plugin"));
        assert!(!dirs.contains("/state/metalsx"));
        assert!(!dirs.contains("/state/metals/../other"));
        assert!(!dirs.contains("/home/user/.cache"));
    }

    #[test]
    fn a_packaged_answer_becomes_a_launch_plan() {
        let (plan, gates) = decode_answer(
            json!({
                "executable": {"kind": "packaged", "path": "server/bin/metals"},
                "arguments": ["-Dmetals.client=lithe"],
                "environment": {"COURSIER_CACHE": "/tmp/plugin/coursier"},
                "initializationOptions": {"isHttpEnabled": false},
                "gates": [{"id": "indexed", "until": "notification",
                           "method": "metals/status", "match": {"text": "Indexing complete"}}],
                "writablePaths": ["/tmp/plugin/coursier"],
            }),
            &directories(),
            &tools(),
        )
        .expect("answer decodes");
        assert_eq!(
            plan["launch"],
            json!({"kind": "packaged", "path": "server/bin/metals"})
        );
        assert_eq!(plan["requiredPackagePaths"], json!(["server/bin/metals"]));
        assert_eq!(plan["writablePaths"], json!(["/tmp/plugin/coursier"]));
        assert_eq!(gates.len(), 1);
    }

    #[test]
    fn answers_outside_their_bounds_are_refused() {
        let refused = |answer: Value| {
            decode_answer(answer, &directories(), &tools())
                .expect_err("answer is refused")
                .code
        };
        assert_eq!(
            refused(json!({"executable": {"kind": "packaged", "path": "../bin/metals"}})),
            "plugin.launch.outsidePackage"
        );
        assert_eq!(
            refused(json!({"executable": {"kind": "tool", "tool": "sbt"}})),
            "plugin.launch.undeclaredTool"
        );
        assert_eq!(
            refused(json!({"executable": {"kind": "tool", "tool": "coursier"},
                           "writablePaths": ["/home/user/.metals"]})),
            "plugin.launch.unwritablePath"
        );
        assert_eq!(
            refused(json!({"executable": {"kind": "tool", "tool": "coursier"},
                           "arguments": vec!["x"; MAX_ARGUMENTS + 1]})),
            "plugin.launch.invalidResult"
        );
        assert_eq!(
            refused(json!({"executable": {"kind": "tool", "tool": "coursier"},
                           "initializationOptions": ["not", "an", "object"]})),
            "plugin.launch.invalidResult"
        );
        assert_eq!(
            refused(json!({"executable": {"kind": "tool", "tool": "coursier"},
                           "directories": {}})),
            "plugin.launch.invalidResult"
        );
    }

    #[test]
    fn gate_patterns_match_nested_members() {
        let pattern = json!({"type": "Started", "detail": {"phase": "ready"}});
        let pattern = pattern.as_object().expect("object");
        assert!(matches_pattern(
            &json!({"type": "Started", "detail": {"phase": "ready", "extra": 1}}),
            pattern
        ));
        assert!(!matches_pattern(&json!({"type": "Starting"}), pattern));
    }

    #[test]
    fn retention_keeps_active_and_newest_state() {
        let day = SECONDS_PER_DAY;
        let response = state_retention_command(json!({
            "retention": {"maxEntries": 2, "maxAgeDays": 30},
            "nowUnixSeconds": 100 * day,
            "entries": [
                {"name": "open", "lastModifiedUnixSeconds": day},
                {"name": "recent", "lastModifiedUnixSeconds": 99 * day},
                {"name": "older", "lastModifiedUnixSeconds": 98 * day},
                {"name": "stale", "lastModifiedUnixSeconds": 10 * day},
                {"name": "../escape", "lastModifiedUnixSeconds": 0},
            ],
            "activeNames": ["open"],
        }))
        .expect("retention runs");
        assert_eq!(response["expiredNames"], json!(["older", "stale"]));
    }

    #[test]
    fn retention_bounds_are_checked() {
        let error = state_retention_command(json!({
            "retention": {"maxEntries": 0, "maxAgeDays": 30},
            "nowUnixSeconds": 0,
            "entries": [],
        }))
        .expect_err("zero entries is refused");
        assert!(matches!(error.code, ErrorCode::InvalidRequest));
    }
}
