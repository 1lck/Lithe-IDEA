//! `debugAdapters[]` of an API level 4 plugin manifest: what a host must know
//! about a debug adapter before starting any process for it.
//!
//! A declaration names the adapter, how its process is started and reached
//! (stdio or a loopback TCP endpoint), and optional matching, default DAP
//! arguments and capability suppression. It carries no behavior: there is no
//! resolver, workflow or host integration, so a plugin can only choose among
//! facts Core already understands. DAP capabilities belong to the running
//! adapter and are negotiated in `initialize`; `capabilities.disabled` can
//! only switch standard ones off.
//!
//! Validation has three layers. `validate_declarations` checks the manifest
//! on its own. `check_package_resources` checks the declaration against the
//! files of the installed package. `plan` checks one debug start against the
//! facts of that moment (target, registration and runtime generation).
//!
//! Note: the decision is recorded in .agents/notes/proposed/architecture/2026-10-25-unified-debug-engine-and-adapter-registry.md

use crate::plugins::declarative::{
    invalid, is_safe_relative_path, validate_process_arguments, PluginRejection, ServerProcess,
    ServerRole, Validation,
};
use crate::plugins::settings::DeclaredSettings;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

/// Most adapters one plugin may declare.
const MAX_ADAPTERS: usize = 16;
/// Longest display name or DAP adapter ID, in characters.
const MAX_NAME: usize = 128;
/// Longest adapter-local ID, in characters.
const MAX_LOCAL_ID: usize = 64;
/// Most selectors one adapter may declare.
const MAX_SELECTORS: usize = 16;
/// Most imported `launch.json` type aliases one adapter may declare.
const MAX_CONFIGURATION_TYPES: usize = 16;
/// Longest announced-endpoint prefix, in bytes.
const MAX_ENDPOINT_PREFIX: usize = 256;

/// Runtimes a `runSelectedRuntime` launch may name: the tools Run can select
/// a runtime for.
const SELECTED_RUNTIME_TOOLS: &[&str] = &["java", "node", "python"];

/// Target kinds a selector may match.
const TARGET_KINDS: &[&str] = &["connection", "executable", "file", "process", "runTarget"];

/// `process` keys of a debug adapter launch. `initializationOptions` is an
/// LSP field and has no meaning for a DAP transport.
const PROCESS_KEYS: &[&str] = &[
    "launch",
    "arguments",
    "validationArguments",
    "runtimeDependencies",
];

/// Standard DAP `Capabilities` booleans plus the exception filter list; the
/// only names `capabilities.disabled` accepts.
const DAP_CAPABILITIES: &[&str] = &[
    "exceptionBreakpointFilters",
    "supportSuspendDebuggee",
    "supportTerminateDebuggee",
    "supportsANSIStyling",
    "supportsBreakpointLocationsRequest",
    "supportsCancelRequest",
    "supportsClipboardContext",
    "supportsCompletionsRequest",
    "supportsConditionalBreakpoints",
    "supportsConfigurationDoneRequest",
    "supportsDataBreakpointBytes",
    "supportsDataBreakpoints",
    "supportsDelayedStackTraceLoading",
    "supportsDisassembleRequest",
    "supportsEvaluateForHovers",
    "supportsExceptionFilterOptions",
    "supportsExceptionInfoRequest",
    "supportsExceptionOptions",
    "supportsFunctionBreakpoints",
    "supportsGotoTargetsRequest",
    "supportsHitConditionalBreakpoints",
    "supportsInstructionBreakpoints",
    "supportsLoadedSourcesRequest",
    "supportsLogPoints",
    "supportsModulesRequest",
    "supportsReadMemoryRequest",
    "supportsRestartFrame",
    "supportsRestartRequest",
    "supportsSetExpression",
    "supportsSetVariable",
    "supportsSingleThreadExecutionRequests",
    "supportsStepBack",
    "supportsStepInTargetsRequest",
    "supportsSteppingGranularity",
    "supportsTerminateRequest",
    "supportsTerminateThreadsRequest",
    "supportsValueFormattingOptions",
    "supportsWriteMemoryRequest",
];

/// One debug adapter a plugin implements.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugAdapterDeclaration {
    /// Plugin-local ID. The Registry identity is qualified by the plugin ID.
    pub(crate) id: String,
    pub(crate) display_name: String,
    /// DAP `initialize.adapterID`; the local ID when absent.
    #[serde(default, rename = "adapterID", skip_serializing_if = "Option::is_none")]
    pub(crate) adapter_id: Option<String>,
    /// Requests the adapter serves; `launch` only when absent.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) requests: Vec<DebugRequest>,
    /// Automatic matching; absent means explicit selection only.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) selectors: Vec<DebugSelector>,
    /// Imported `launch.json` `type` values this adapter answers to.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) configuration_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) configurations: Option<DebugConfigurations>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) capabilities: Option<DebugCapabilities>,
    pub(crate) launch: DebugLaunch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DebugRequest {
    Launch,
    Attach,
}

/// Optional automatic matching: OR between selectors, AND between fields.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugSelector {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) target_kinds: Vec<String>,
    #[serde(default, rename = "languageIDs", skip_serializing_if = "Vec::is_empty")]
    pub(crate) language_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugConfigurations {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) launch: Option<DebugConfiguration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) attach: Option<DebugConfiguration>,
}

/// Defaults for the DAP arguments of one request.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugConfiguration {
    /// Adapter-owned default DAP arguments, ordinary JSON data.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) arguments: Option<Map<String, Value>>,
    /// Packaged JSON schema of the final merged arguments.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) parameters_schema: Option<String>,
    /// Which target fact fills which missing DAP argument.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) target_bindings: Option<DebugTargetBindings>,
}

/// Typed projections from the target into known DAP fields. Each field has
/// exactly one legal source, so a binding is a fact, not an expression.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugTargetBindings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) program: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) process_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) cwd: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugCapabilities {
    /// Standard DAP capability names the host treats as absent.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) disabled: Vec<String>,
}

/// How the adapter process is started and reached.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugLaunch {
    pub(crate) process: DebugProcess,
    pub(crate) transport: DebugTransport,
    /// Required by, and only allowed for, the TCP transports.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) endpoint: Option<DebugEndpoint>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DebugTransport {
    Stdio,
    TcpAnnounced,
    TcpPort,
}

/// Where a TCP adapter listens. The fields of the other transport must stay
/// absent, which `validate` checks.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DebugEndpoint {
    /// `tcpAnnounced`: the stream the adapter prints its endpoint on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) stream: Option<String>,
    /// `tcpAnnounced`: the text before the endpoint on that line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) prefix: Option<String>,
    /// `tcpAnnounced`: `port` or `hostPort`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) value: Option<String>,
    /// `tcpPort`: a fixed loopback port of the adapter process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) port: Option<u16>,
}

/// The adapter process: the launch fields every plugin server process shares,
/// or the runtime Run selected for the target.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub(crate) enum DebugProcess {
    Server(ServerProcess),
    SelectedRuntime(SelectedRuntimeProcess),
}

/// `serverProcess` 2: start the adapter on the runtime Run selected for the
/// target, not on a runtime the plugin names a version of.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SelectedRuntimeProcess {
    launch: SelectedRuntimeLaunch,
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default)]
    validation_arguments: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SelectedRuntimeLaunch {
    kind: SelectedRuntimeKind,
    tool: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
enum SelectedRuntimeKind {
    #[serde(rename = "runSelectedRuntime")]
    RunSelectedRuntime,
}

impl<'de> Deserialize<'de> for DebugProcess {
    /// Chooses the branch by `launch.kind` and refuses fields a DAP adapter
    /// cannot use, so `ServerProcess` keeps one shape for every owner.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let value = Value::deserialize(deserializer)?;
        let object = value
            .as_object()
            .ok_or_else(|| D::Error::custom("a debug adapter process is an object"))?;
        let selected = object
            .get("launch")
            .and_then(|launch| launch.get("kind"))
            .and_then(Value::as_str)
            == Some("runSelectedRuntime");
        if selected {
            return serde_json::from_value(value)
                .map(Self::SelectedRuntime)
                .map_err(D::Error::custom);
        }
        if let Some(key) = object
            .keys()
            .find(|key| !PROCESS_KEYS.contains(&key.as_str()))
        {
            return Err(D::Error::custom(format!(
                "unknown field `{key}` in a debug adapter process"
            )));
        }
        serde_json::from_value(value)
            .map(Self::Server)
            .map_err(D::Error::custom)
    }
}

impl DebugProcess {
    fn validate(&self, field: &str, context: &DeclarationContext<'_>) -> Validation<()> {
        match self {
            Self::Server(process) => process.validate(
                field,
                context.plugin_api_version,
                context.declared_settings,
                ServerRole::DebugAdapter,
            ),
            Self::SelectedRuntime(process) => {
                let tool = process.launch.tool.as_str();
                if !SELECTED_RUNTIME_TOOLS.contains(&tool) {
                    return Err(PluginRejection::at(
                        "plugin.runtime.unsupported",
                        format!("{field}.launch.tool"),
                        format!("The host cannot start a debug adapter on {tool}."),
                    ));
                }
                validate_process_arguments(
                    &process.arguments,
                    &process.validation_arguments,
                    context.declared_settings,
                    field,
                )
            }
        }
    }

    /// The runtime tool this adapter needs Run to have selected.
    pub(crate) fn selected_runtime_tool(&self) -> Option<&str> {
        match self {
            Self::SelectedRuntime(process) => Some(process.launch.tool.as_str()),
            Self::Server(_) => None,
        }
    }
}

/// What validation needs from the manifest around the declarations.
pub(crate) struct DeclarationContext<'a> {
    pub(crate) plugin_api_version: u32,
    pub(crate) declared_settings: &'a DeclaredSettings,
}

/// Validates every declaration and sorts them by ID.
pub(crate) fn validate_declarations(
    adapters: &mut [DebugAdapterDeclaration],
    context: &DeclarationContext<'_>,
) -> Validation<()> {
    if adapters.is_empty() {
        return Ok(());
    }
    if adapters.len() > MAX_ADAPTERS {
        return Err(invalid(
            "debugAdapters",
            format!("A plugin declares at most {MAX_ADAPTERS} debug adapters."),
        ));
    }
    let mut ids = BTreeSet::new();
    for (index, adapter) in adapters.iter_mut().enumerate() {
        let field = format!("debugAdapters[{index}]");
        adapter.validate(&field, context)?;
        if !ids.insert(adapter.id.clone()) {
            return Err(invalid(
                format!("{field}.id"),
                "A debug adapter is declared more than once.",
            ));
        }
    }
    adapters.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(())
}

/// Whether any adapter starts on the selected runtime, which is the only use
/// of `serverProcess` 2.
pub(crate) fn uses_selected_runtime(adapters: &[DebugAdapterDeclaration]) -> bool {
    adapters
        .iter()
        .any(|adapter| adapter.launch.process.selected_runtime_tool().is_some())
}

/// Whether any adapter serves `attach`, which needs its own permission.
pub(crate) fn serves_attach(adapters: &[DebugAdapterDeclaration]) -> bool {
    adapters
        .iter()
        .any(|adapter| adapter.requests.contains(&DebugRequest::Attach))
}

impl DebugAdapterDeclaration {
    fn validate(&mut self, field: &str, context: &DeclarationContext<'_>) -> Validation<()> {
        if !is_local_id(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A debug adapter ID is a lowercase letter followed by up to 63 lowercase letters, digits, dots, underscores, or hyphens.",
            ));
        }
        validate_name(&self.display_name, &format!("{field}.displayName"))?;
        if let Some(adapter_id) = &self.adapter_id {
            validate_name(adapter_id, &format!("{field}.adapterID"))?;
        }

        // `launch` is the default; an explicit empty list would serve nothing.
        if self.requests.is_empty() {
            self.requests = vec![DebugRequest::Launch];
        }
        self.requests.sort();
        let before = self.requests.len();
        self.requests.dedup();
        if self.requests.len() != before {
            return Err(invalid(
                format!("{field}.requests"),
                "A request is listed more than once.",
            ));
        }

        self.validate_selectors(field)?;
        self.validate_configuration_types(field)?;
        if let Some(configurations) = &self.configurations {
            // A configuration for a request the adapter does not serve could
            // never apply.
            for (name, request, configuration) in [
                ("launch", DebugRequest::Launch, &configurations.launch),
                ("attach", DebugRequest::Attach, &configurations.attach),
            ] {
                let Some(configuration) = configuration else {
                    continue;
                };
                let configuration_field = format!("{field}.configurations.{name}");
                if !self.requests.contains(&request) {
                    return Err(invalid(
                        configuration_field,
                        "The configuration is for a request the adapter does not declare.",
                    ));
                }
                configuration.validate(&configuration_field, request)?;
            }
        }
        if let Some(capabilities) = &mut self.capabilities {
            capabilities.validate(&format!("{field}.capabilities"))?;
        }
        self.launch.validate(&format!("{field}.launch"), context)
    }

    fn validate_selectors(&mut self, field: &str) -> Result<(), PluginRejection> {
        if self.selectors.len() > MAX_SELECTORS {
            return Err(invalid(
                format!("{field}.selectors"),
                format!("An adapter declares at most {MAX_SELECTORS} selectors."),
            ));
        }
        for (index, selector) in self.selectors.iter_mut().enumerate() {
            let selector_field = format!("{field}.selectors[{index}]");
            if selector.target_kinds.is_empty() && selector.language_ids.is_empty() {
                return Err(invalid(
                    selector_field,
                    "A selector matches on at least one field.",
                ));
            }
            if let Some(kind) = selector
                .target_kinds
                .iter()
                .find(|kind| !TARGET_KINDS.contains(&kind.as_str()))
            {
                return Err(invalid(
                    format!("{selector_field}.targetKinds"),
                    format!("{kind} is not a target kind."),
                ));
            }
            if selector.language_ids.iter().any(|id| !is_language_id(id)) {
                return Err(invalid(
                    format!("{selector_field}.languageIDs"),
                    "A language ID is lowercase letters, digits, and + _ -.",
                ));
            }
            sort_unique(
                &mut selector.target_kinds,
                &format!("{selector_field}.targetKinds"),
            )?;
            sort_unique(
                &mut selector.language_ids,
                &format!("{selector_field}.languageIDs"),
            )?;
        }
        Ok(())
    }

    fn validate_configuration_types(&mut self, field: &str) -> Validation<()> {
        let types_field = format!("{field}.configurationTypes");
        if self.configuration_types.len() > MAX_CONFIGURATION_TYPES
            || self
                .configuration_types
                .iter()
                .any(|name| name.trim().is_empty() || name.chars().any(char::is_control))
        {
            return Err(invalid(
                types_field,
                format!("Configuration types are up to {MAX_CONFIGURATION_TYPES} non-empty names."),
            ));
        }
        sort_unique(&mut self.configuration_types, &types_field)
    }
}

impl DebugConfiguration {
    fn validate(&self, field: &str, request: DebugRequest) -> Validation<()> {
        if self.arguments.is_none()
            && self.parameters_schema.is_none()
            && self.target_bindings.is_none()
        {
            return Err(invalid(
                field,
                "A configuration declares at least one field.",
            ));
        }
        if let Some(path) = &self.parameters_schema {
            if !is_safe_relative_path(path) || path.contains(':') {
                return Err(invalid(
                    format!("{field}.parametersSchema"),
                    "The parameters schema must be a file inside the plugin package.",
                ));
            }
        }
        let Some(bindings) = &self.target_bindings else {
            return Ok(());
        };
        let binding_field = format!("{field}.targetBindings");
        if bindings.program.is_none() && bindings.process_id.is_none() && bindings.cwd.is_none() {
            return Err(invalid(
                &binding_field,
                "A binding list declares a binding.",
            ));
        }
        for (name, source, expected) in [
            ("program", &bindings.program, "target.path"),
            ("processId", &bindings.process_id, "target.processID"),
            ("cwd", &bindings.cwd, "target.workingDirectory"),
        ] {
            if source.as_deref().is_some_and(|source| source != expected) {
                return Err(invalid(
                    format!("{binding_field}.{name}"),
                    format!("{name} can only be bound to {expected}."),
                ));
            }
        }
        // `processId` names a running process, which only attach has.
        if (bindings.process_id.is_some() && request != DebugRequest::Attach)
            || (bindings.program.is_some() && request != DebugRequest::Launch)
        {
            return Err(invalid(
                binding_field,
                "The binding does not apply to this request.",
            ));
        }
        Ok(())
    }
}

impl DebugCapabilities {
    fn validate(&mut self, field: &str) -> Validation<()> {
        let disabled_field = format!("{field}.disabled");
        if self.disabled.is_empty() {
            return Err(invalid(
                disabled_field,
                "Disabled capabilities list at least one name.",
            ));
        }
        if let Some(index) = self
            .disabled
            .iter()
            .position(|name| !DAP_CAPABILITIES.contains(&name.as_str()))
        {
            return Err(invalid(
                format!("{disabled_field}[{index}]"),
                "Only standard DAP capability names can be disabled.",
            ));
        }
        sort_unique(&mut self.disabled, &disabled_field)
    }
}

impl DebugLaunch {
    fn validate(&self, field: &str, context: &DeclarationContext<'_>) -> Validation<()> {
        self.process
            .validate(&format!("{field}.process"), context)?;
        let endpoint_field = format!("{field}.endpoint");
        match (self.transport, &self.endpoint) {
            (DebugTransport::Stdio, None) => Ok(()),
            (DebugTransport::Stdio, Some(_)) => Err(invalid(
                endpoint_field,
                "The stdio transport has no endpoint.",
            )),
            (_, None) => Err(invalid(
                endpoint_field,
                "A TCP transport needs an endpoint.",
            )),
            (DebugTransport::TcpAnnounced, Some(endpoint)) => {
                let valid = endpoint.port.is_none()
                    && matches!(endpoint.stream.as_deref(), Some("stdout" | "stderr"))
                    && matches!(endpoint.value.as_deref(), Some("port" | "hostPort"))
                    && endpoint.prefix.as_deref().is_some_and(|prefix| {
                        !prefix.is_empty()
                            && prefix.len() <= MAX_ENDPOINT_PREFIX
                            && !prefix.contains(['\r', '\n', '\0'])
                    });
                if valid {
                    Ok(())
                } else {
                    Err(invalid(
                        endpoint_field,
                        "An announced endpoint names a stream, a one-line prefix, and port or hostPort.",
                    ))
                }
            }
            (DebugTransport::TcpPort, Some(endpoint)) => {
                let valid = endpoint.stream.is_none()
                    && endpoint.prefix.is_none()
                    && endpoint.value.is_none()
                    && endpoint.port.is_some_and(|port| port >= 1);
                if valid {
                    Ok(())
                } else {
                    Err(invalid(
                        endpoint_field,
                        "A fixed endpoint is a loopback port from 1 to 65535.",
                    ))
                }
            }
        }
    }
}

/// Event that activates the plugin when a debug session needs the adapter.
pub(crate) fn activation_event(adapter: &DebugAdapterDeclaration) -> String {
    format!("onDebug:{}", adapter.id)
}

/// Install-review entries: the adapter process with the runtimes it needs.
/// Pointing an adapter at another executable or transport is a new program
/// the user must approve. A selected-runtime adapter adds no runtime entry:
/// the runtime is the one the user already chose for Run.
pub(crate) fn programs(adapter: &DebugAdapterDeclaration) -> Vec<Value> {
    let mut program = match &adapter.launch.process {
        DebugProcess::Server(process) => process.program(ServerRole::DebugAdapter),
        DebugProcess::SelectedRuntime(process) => json!({
            "kind": "selectedRuntimeDebugAdapter",
            "tool": process.launch.tool,
            "arguments": process.arguments,
            "validationArguments": process.validation_arguments,
        }),
    };
    program["debugAdapter"] = json!(adapter.id);
    program["transport"] = json!(adapter.launch.transport);
    program["endpoint"] = json!(adapter.launch.endpoint);
    let mut programs = vec![program];
    if let DebugProcess::Server(process) = &adapter.launch.process {
        programs.extend(process.runtime_programs());
    }
    programs
}

// The install check and start plan have no caller until the debug start
// command reads Registry entries (macOS provider, step 2); tests run them now.

/// A file of the installed package, as the installer found it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) struct PackageResource {
    pub(crate) path: String,
    pub(crate) kind: PackageResourceKind,
    /// Link target of a symlink, as stored in the package.
    #[serde(default)]
    pub(crate) target: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) enum PackageResourceKind {
    File,
    Directory,
    Symlink,
}

/// Checks that every packaged file an adapter refers to is a regular file or
/// a link that stays inside the package. Only the installer can see the
/// files, so this is separate from the manifest checks.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn check_package_resources(
    adapters: &[DebugAdapterDeclaration],
    resources: &[PackageResource],
) -> Validation<()> {
    for (index, adapter) in adapters.iter().enumerate() {
        let Some(configurations) = &adapter.configurations else {
            continue;
        };
        for (name, configuration) in [
            ("launch", &configurations.launch),
            ("attach", &configurations.attach),
        ] {
            let Some(path) = configuration
                .as_ref()
                .and_then(|configuration| configuration.parameters_schema.as_ref())
            else {
                continue;
            };
            let field = format!("debugAdapters[{index}].configurations.{name}.parametersSchema");
            let Some(resource) = resources.iter().find(|resource| resource.path == *path) else {
                return Err(invalid(
                    field,
                    "The parameters schema is not in the package.",
                ));
            };
            match resource.kind {
                PackageResourceKind::File => {}
                PackageResourceKind::Directory => {
                    return Err(invalid(field, "The parameters schema is a directory."));
                }
                PackageResourceKind::Symlink => {
                    if !link_stays_inside(&resource.path, resource.target.as_deref()) {
                        return Err(invalid(
                            field,
                            "The parameters schema links outside the plugin package.",
                        ));
                    }
                }
            }
        }
    }
    Ok(())
}

/// Resolves a symlink target lexically from the link's directory. A target
/// that climbs above the package root, or is absolute, escapes.
#[cfg_attr(not(test), allow(dead_code))]
fn link_stays_inside(link: &str, target: Option<&str>) -> bool {
    let Some(target) = target else {
        return false;
    };
    if target.is_empty() || target.starts_with('/') || target.contains(['\\', '\0']) {
        return false;
    }
    let mut depth = link.split('/').count().saturating_sub(1);
    for component in target.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if depth == 0 {
                    return false;
                }
                depth -= 1;
            }
            _ => depth += 1,
        }
    }
    true
}

/// Facts of one debug start that the manifest cannot know.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) struct StartFacts {
    pub(crate) registration: Generation,
    #[serde(default)]
    pub(crate) runtime_selection: Option<Generation>,
    pub(crate) target: TargetFacts,
}

/// A generation the plan was made against and the one current at start.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) struct Generation {
    pub(crate) generation: u64,
    pub(crate) current_generation: u64,
}

impl Generation {
    #[cfg_attr(not(test), allow(dead_code))]
    fn is_stale(self) -> bool {
        self.generation != self.current_generation
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) struct TargetFacts {
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) path: Option<String>,
    #[serde(default, rename = "processID")]
    pub(crate) process_id: Option<u64>,
    #[serde(default)]
    pub(crate) working_directory: Option<String>,
}

/// Checks one debug start against the registration, the selected runtime and
/// the target facts the request's bindings read.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn plan(
    adapter: &DebugAdapterDeclaration,
    request: DebugRequest,
    facts: &StartFacts,
) -> Validation<()> {
    if facts.registration.is_stale() {
        return Err(PluginRejection::at(
            "debug.provider.stale",
            "registration",
            "The adapter registration changed after this start was prepared.",
        ));
    }
    if !adapter.requests.contains(&request) {
        return Err(PluginRejection::at(
            "debug.request.unsupported",
            "request",
            "The adapter does not serve this request.",
        ));
    }
    if adapter.launch.process.selected_runtime_tool().is_some()
        && facts.runtime_selection.map_or(true, Generation::is_stale)
    {
        return Err(PluginRejection::at(
            "debug.runtime.stale",
            "runtimeSelection",
            "The selected runtime changed after this start was prepared.",
        ));
    }
    let bindings = adapter
        .configurations
        .as_ref()
        .and_then(|configurations| match request {
            DebugRequest::Launch => configurations.launch.as_ref(),
            DebugRequest::Attach => configurations.attach.as_ref(),
        })
        .and_then(|configuration| configuration.target_bindings.as_ref());
    let Some(bindings) = bindings else {
        return Ok(());
    };
    let missing = |field: &'static str, fact: &str| {
        PluginRejection::at(
            "debug.target.invalid",
            field,
            format!("The target has no {fact}, which the adapter's configuration reads."),
        )
    };
    let target = &facts.target;
    if bindings.program.is_some() && target.path.as_deref().map_or(true, str::is_empty) {
        return Err(missing("target.path", "path"));
    }
    if bindings.process_id.is_some() && target.process_id.is_none() {
        return Err(missing("target.processID", "process ID"));
    }
    if bindings.cwd.is_some()
        && target
            .working_directory
            .as_deref()
            .map_or(true, str::is_empty)
    {
        return Err(missing("target.workingDirectory", "working directory"));
    }
    Ok(())
}

fn validate_name(value: &str, field: &str) -> Validation<()> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.chars().count() > MAX_NAME
        || trimmed.chars().any(char::is_control)
    {
        return Err(invalid(field, "A name is one line of 1-128 characters."));
    }
    Ok(())
}

fn is_local_id(value: &str) -> bool {
    let mut characters = value.chars();
    value.len() <= MAX_LOCAL_ID
        && characters
            .next()
            .is_some_and(|first| first.is_ascii_lowercase())
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || "._-".contains(character)
        })
}

fn is_language_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_LOCAL_ID
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || "+_-".contains(character)
        })
}

/// Sorts a list and rejects a repeated entry, so equal declarations compare
/// equal whatever order the author wrote.
fn sort_unique(values: &mut Vec<String>, field: &str) -> Validation<()> {
    values.sort();
    let before = values.len();
    values.dedup();
    if values.len() == before {
        Ok(())
    } else {
        Err(invalid(field, "An entry is listed more than once."))
    }
}
