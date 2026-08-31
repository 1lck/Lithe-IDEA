//! Stable requests, updates, events, and inspection results for shared debugging.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Lifecycle state reduced from DAP requests, responses, and events.
pub enum DebugSessionState {
    Idle,
    Initializing,
    Ready,
    Launching,
    Running,
    Paused,
    Terminating,
    Terminated,
    Failed,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Creates a protocol session without opening a socket or starting a process.
pub struct CreateSessionRequest {
    pub session_id: String,
    pub adapter_id: String,
    pub root_path: String,
    /// Whether the native host can launch adapter-requested processes in a terminal.
    #[serde(default)]
    pub supports_run_in_terminal_request: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Identifies one existing debug session.
pub struct SessionRequest {
    pub session_id: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// DAP request used to begin a debuggee session.
pub enum DebugRequestKind {
    Launch,
    Attach,
}

impl DebugRequestKind {
    pub(crate) fn command(self) -> &'static str {
        match self {
            Self::Launch => "launch",
            Self::Attach => "attach",
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Provider-specific launch arguments wrapped in a language-neutral contract.
pub struct DebugLaunchConfiguration {
    pub name: String,
    pub request: DebugRequestKind,
    #[serde(default)]
    pub arguments: serde_json::Map<String, Value>,
    /// Optional portable stepping policy projected into adapter-specific launch arguments.
    #[serde(default)]
    pub stepping_filters: Option<DebugSteppingFilters>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Portable class and method filters used for stepping and stack-frame presentation.
pub struct DebugSteppingFilters {
    /// Adapter-neutral class-name patterns; Java also accepts `$JDK` and `$Libraries`.
    #[serde(default)]
    pub class_name_filters: Vec<String>,
    /// Whether compiler-generated methods should be skipped.
    #[serde(default)]
    pub skip_synthetics: bool,
    /// Whether class static initializers should be skipped.
    #[serde(default)]
    pub skip_static_initializers: bool,
    /// Whether constructors should be skipped.
    #[serde(default)]
    pub skip_constructors: bool,
    /// Whether native clients should collapse stack frames matched by the class filters.
    #[serde(default)]
    pub hide_filtered_stack_frames: bool,
}

impl DebugSteppingFilters {
    pub(crate) fn defaults_for_adapter(adapter_id: &str) -> Self {
        if adapter_id == "java" {
            Self::default()
        } else {
            Self::unfiltered()
        }
    }

    pub(crate) fn unfiltered() -> Self {
        Self {
            class_name_filters: Vec::new(),
            skip_synthetics: false,
            skip_static_initializers: false,
            skip_constructors: false,
            hide_filtered_stack_frames: false,
        }
    }
}

impl Default for DebugSteppingFilters {
    fn default() -> Self {
        Self {
            class_name_filters: default_java_class_name_filters(),
            skip_synthetics: true,
            skip_static_initializers: true,
            // IDEA leaves constructor skipping off by default because application
            // initialization is often meaningful user code.
            skip_constructors: false,
            hide_filtered_stack_frames: true,
        }
    }
}

fn default_java_class_name_filters() -> Vec<String> {
    [
        "$JDK",
        "$Libraries",
        "com.ibm.ws.*",
        "com.springsource.loaded.*",
        "com.sun.proxy.*",
        "javassist.*",
        "jdk.proxy*.*",
        "junit.*",
        "net.bytebuddy.*",
        "net.sf.cglib.*",
        "org.apache.webbeans.*",
        "org.junit.*",
        "org.mockito.*",
        "org.springframework.aop.framework.*",
        "org.springframework.cglib.*",
        "org.springsource.loaded.*",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Returns an adapter's defaults or normalizes a native client's stepping policy.
pub struct DebugSteppingFiltersRequest {
    /// Stable adapter identifier, such as `java`.
    pub adapter_id: String,
    /// Optional client override; omission requests the adapter defaults.
    #[serde(default)]
    pub filters: Option<DebugSteppingFilters>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Queues launch or attach, waiting for initialization when necessary.
pub struct LaunchRequest {
    pub session_id: String,
    pub operation_id: String,
    pub configuration: DebugLaunchConfiguration,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One requested source breakpoint using one-based DAP coordinates.
pub struct SourceBreakpoint {
    pub line: i64,
    #[serde(default)]
    pub column: Option<i64>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub condition: Option<String>,
    #[serde(default)]
    pub hit_condition: Option<String>,
    #[serde(default)]
    pub log_message: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Replaces the complete breakpoint set for one absolute source path.
pub struct SetBreakpointsRequest {
    pub session_id: String,
    pub source_path: String,
    #[serde(default)]
    pub breakpoints: Vec<SourceBreakpoint>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// One adapter-defined exception filter and its optional exception condition.
pub struct ExceptionBreakpoint {
    pub filter: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub condition: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Replaces the complete exception breakpoint selection for one session.
pub struct SetExceptionBreakpointsRequest {
    pub session_id: String,
    #[serde(default)]
    pub breakpoints: Vec<ExceptionBreakpoint>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// One named function or method breakpoint understood by the active adapter.
pub struct FunctionBreakpoint {
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub condition: Option<String>,
    #[serde(default)]
    pub hit_condition: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Replaces the complete function breakpoint set for one session.
pub struct SetFunctionBreakpointsRequest {
    pub session_id: String,
    #[serde(default)]
    pub breakpoints: Vec<FunctionBreakpoint>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Resolves an adapter-owned data identifier for one visible variable or expression.
pub struct DataBreakpointInfoRequest {
    pub session_id: String,
    pub operation_id: String,
    pub name: String,
    #[serde(default)]
    pub variables_reference: Option<i64>,
    #[serde(default)]
    pub frame_id: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// One adapter-resolved field or data breakpoint.
pub struct DataBreakpoint {
    pub data_id: String,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub access_type: Option<String>,
    #[serde(default)]
    pub condition: Option<String>,
    #[serde(default)]
    pub hit_condition: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Replaces the complete adapter-resolved data breakpoint set for one session.
pub struct SetDataBreakpointsRequest {
    pub session_id: String,
    #[serde(default)]
    pub breakpoints: Vec<DataBreakpoint>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Replaces one visible variable value in its adapter-owned parent container.
pub struct SetVariableRequest {
    pub session_id: String,
    pub operation_id: String,
    pub variables_reference: i64,
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// Why a native host ended one pending debug operation.
pub enum DebugCancellationReason {
    Cancelled,
    TimedOut,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Ends one pending operation and optionally forwards DAP cancellation.
pub struct CancelOperationRequest {
    pub session_id: String,
    pub operation_id: String,
    pub reason: DebugCancellationReason,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// Supported execution controls shared by every DAP provider.
pub enum DebugExecutionCommand {
    Continue,
    Pause,
    Next,
    StepIn,
    StepOut,
    StepBack,
    Goto,
    Restart,
    Terminate,
}

impl DebugExecutionCommand {
    pub(crate) fn command(self) -> &'static str {
        match self {
            Self::Continue => "continue",
            Self::Pause => "pause",
            Self::Next => "next",
            Self::StepIn => "stepIn",
            Self::StepOut => "stepOut",
            Self::StepBack => "stepBack",
            Self::Goto => "goto",
            Self::Restart => "restart",
            Self::Terminate => "terminate",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Queues a control request and correlates its eventual result to an operation.
pub struct ExecuteRequest {
    pub session_id: String,
    pub operation_id: String,
    pub command: DebugExecutionCommand,
    #[serde(default)]
    pub thread_id: Option<i64>,
    #[serde(default)]
    pub target_id: Option<i64>,
    #[serde(default)]
    pub single_thread: bool,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// Normalized debugger data requests supported by the shared UI contract.
pub enum DebugInspectKind {
    Threads,
    StackTrace,
    Scopes,
    Variables,
    Evaluate,
    ExceptionInfo,
    StepInTargets,
    GotoTargets,
}

impl DebugInspectKind {
    pub(crate) fn command(self) -> &'static str {
        match self {
            Self::Threads => "threads",
            Self::StackTrace => "stackTrace",
            Self::Scopes => "scopes",
            Self::Variables => "variables",
            Self::Evaluate => "evaluate",
            Self::ExceptionInfo => "exceptionInfo",
            Self::StepInTargets => "stepInTargets",
            Self::GotoTargets => "gotoTargets",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// Selects the named or indexed child collection of a debugger variable.
pub enum DebugVariableFilter {
    Named,
    Indexed,
}

impl DebugVariableFilter {
    pub(crate) fn argument(self) -> &'static str {
        match self {
            Self::Named => "named",
            Self::Indexed => "indexed",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Parameters for one thread, frame, variable, or expression inspection.
pub struct InspectRequest {
    pub session_id: String,
    pub operation_id: String,
    pub kind: DebugInspectKind,
    #[serde(default)]
    pub thread_id: Option<i64>,
    #[serde(default)]
    pub frame_id: Option<i64>,
    #[serde(default)]
    pub variables_reference: Option<i64>,
    #[serde(default)]
    pub variable_filter: Option<DebugVariableFilter>,
    /// Zero-based child offset for a paged variables request.
    #[serde(default)]
    pub start: Option<i64>,
    /// Maximum child count for a paged variables request.
    #[serde(default)]
    pub count: Option<i64>,
    #[serde(default)]
    pub expression: Option<String>,
    #[serde(default)]
    pub source_path: Option<String>,
    #[serde(default)]
    pub line: Option<i64>,
    #[serde(default)]
    pub column: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Base64-encoded bytes received from a platform-owned DAP transport.
pub struct ReceiveRequest {
    pub session_id: String,
    pub data_base64: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Terminal surface requested by a Debug Adapter Protocol reverse request.
pub enum DebugRunInTerminalKind {
    Integrated,
    External,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One deterministic environment mutation requested for a debuggee process.
pub struct DebugRunInTerminalEnvironmentVariable {
    pub name: String,
    /// A missing value removes the inherited variable from the child environment.
    pub value: Option<String>,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized platform request for launching a debuggee inside a terminal.
pub struct DebugRunInTerminalRequest {
    pub kind: DebugRunInTerminalKind,
    pub title: Option<String>,
    pub cwd: String,
    /// The executable is the first item; remaining items are passed without a shell.
    pub args: Vec<String>,
    pub environment: Vec<DebugRunInTerminalEnvironmentVariable>,
    /// True only when the adapter intentionally supplied shell-language arguments.
    pub args_can_be_interpreted_by_shell: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Completes one pending `runInTerminal` reverse request from the native host.
pub struct DebugRunInTerminalResponseRequest {
    pub session_id: String,
    pub request_id: String,
    pub success: bool,
    #[serde(default)]
    pub process_id: Option<i64>,
    #[serde(default)]
    pub shell_process_id: Option<i64>,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Effects produced by one deterministic session reduction.
pub struct DebugSessionUpdate {
    pub session_id: String,
    pub state: DebugSessionState,
    /// Complete framed byte sequences, base64 encoded in send order.
    pub outbound_frames: Vec<String>,
    pub events: Vec<DebugEvent>,
}

#[derive(Debug, Clone, Default, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Adapter abilities negotiated by the DAP initialize response.
pub struct DebugCapabilities {
    pub supports_configuration_done: bool,
    pub supports_conditional_breakpoints: bool,
    pub supports_hit_conditional_breakpoints: bool,
    pub supports_log_points: bool,
    pub supports_function_breakpoints: bool,
    pub supports_data_breakpoints: bool,
    pub supports_exception_options: bool,
    pub supports_exception_filter_options: bool,
    pub supports_set_variable: bool,
    pub supports_cancel_request: bool,
    pub supports_single_thread_execution_requests: bool,
    pub supports_restart_request: bool,
    pub supports_terminate_request: bool,
    pub supports_step_back: bool,
    pub supports_exception_info_request: bool,
    pub supports_step_in_targets_request: bool,
    pub supports_goto_targets_request: bool,
    pub exception_breakpoint_filters: Vec<DebugExceptionBreakpointFilter>,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One adapter-defined exception category presented by native clients.
pub struct DebugExceptionBreakpointFilter {
    pub filter: String,
    pub label: String,
    pub description: Option<String>,
    pub default: bool,
    pub supports_condition: bool,
    pub condition_description: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Ordered event projected to platform feature models.
pub struct DebugEvent {
    pub sequence: u64,
    #[serde(flatten)]
    pub body: DebugEventBody,
}

#[derive(Debug, Clone, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
/// Provider-neutral lifecycle, output, breakpoint, and request result events.
pub enum DebugEventBody {
    StateChanged {
        state: DebugSessionState,
    },
    Initialized,
    Capabilities {
        capabilities: DebugCapabilities,
    },
    Output {
        category: Option<String>,
        output: String,
    },
    Stopped {
        reason: String,
        thread_id: Option<i64>,
        description: Option<String>,
    },
    Continued {
        thread_id: Option<i64>,
    },
    Terminated {
        exit_code: Option<i64>,
    },
    Breakpoint {
        breakpoint: DebugBreakpoint,
    },
    RunInTerminalRequested {
        request_id: String,
        request: DebugRunInTerminalRequest,
    },
    OperationCompleted {
        operation_id: String,
        result: DebugOperationResult,
    },
    OperationFailed {
        operation_id: String,
        command: String,
        code: DebugOperationFailureCode,
        message: String,
    },
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable reason for a terminal debug operation failure.
pub enum DebugOperationFailureCode {
    AdapterRejected,
    Cancelled,
    TimedOut,
}

#[derive(Debug, Clone, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
/// Typed terminal data for one caller-owned debug operation.
pub enum DebugOperationResult {
    Acknowledged {
        command: String,
    },
    Threads {
        threads: Vec<DebugThread>,
    },
    StackTrace {
        stack_frames: Vec<DebugStackFrame>,
    },
    Scopes {
        scopes: Vec<DebugScope>,
    },
    Variables {
        variables: Vec<DebugVariable>,
    },
    Evaluate {
        variable: DebugVariable,
    },
    ExceptionInfo {
        exception_info: DebugExceptionInfo,
    },
    SetVariable {
        variable: DebugVariable,
    },
    DataBreakpointInfo {
        data_id: Option<String>,
        description: String,
        access_types: Vec<String>,
        can_persist: bool,
    },
    StepInTargets {
        targets: Vec<DebugStepInTarget>,
    },
    GotoTargets {
        targets: Vec<DebugGotoTarget>,
    },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One adapter-selected call expression eligible for targeted step-in.
pub struct DebugStepInTarget {
    pub id: i64,
    pub label: String,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub end_line: Option<i64>,
    pub end_column: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One executable location returned for a run-to-cursor request.
pub struct DebugGotoTarget {
    pub id: i64,
    pub label: String,
    pub line: i64,
    pub column: Option<i64>,
    pub end_line: Option<i64>,
    pub end_column: Option<i64>,
    pub instruction_pointer_reference: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Adapter-verified breakpoint and its optional resolved source location.
pub struct DebugBreakpoint {
    pub id: i64,
    pub verified: bool,
    pub message: Option<String>,
    /// Requested function name for a function-breakpoint verification result.
    pub function_name: Option<String>,
    /// Adapter-owned identity for a data-breakpoint verification result.
    pub data_id: Option<String>,
    pub source_path: Option<String>,
    pub line: Option<i64>,
    pub column: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One debuggee thread.
pub struct DebugThread {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One stack frame using one-based DAP source coordinates.
pub struct DebugStackFrame {
    pub id: i64,
    pub name: String,
    pub source_path: Option<String>,
    pub line: i64,
    pub column: i64,
    /// True when the active portable stepping policy matches this frame.
    pub is_filtered: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One variable scope associated with a selected stack frame.
pub struct DebugScope {
    pub name: String,
    pub variables_reference: i64,
    pub expensive: bool,
    /// Adapter-reported count of named children, or zero when unavailable.
    pub named_variables: i64,
    /// Adapter-reported count of indexed children, or zero when unavailable.
    pub indexed_variables: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// A debugger variable or evaluated expression result.
pub struct DebugVariable {
    pub name: String,
    pub value: String,
    pub r#type: Option<String>,
    pub evaluate_name: Option<String>,
    pub variables_reference: i64,
    /// Adapter-reported count of named children, or zero when unavailable.
    pub named_variables: i64,
    /// Adapter-reported count of indexed children, or zero when unavailable.
    pub indexed_variables: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Exception metadata returned for the thread that caused an exception pause.
pub struct DebugExceptionInfo {
    pub exception_id: String,
    pub description: Option<String>,
    pub break_mode: String,
    pub details: Option<DebugExceptionDetails>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Optional adapter-provided exception detail tree.
pub struct DebugExceptionDetails {
    pub message: Option<String>,
    pub type_name: Option<String>,
    pub full_type_name: Option<String>,
    pub evaluate_name: Option<String>,
    pub stack_trace: Option<String>,
    pub inner_exceptions: Vec<DebugExceptionDetails>,
}
