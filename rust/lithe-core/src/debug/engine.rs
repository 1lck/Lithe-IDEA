//! Stateful DAP reducer whose byte transport and process lifecycle remain platform owned.

use super::protocol::{frame_message, parse_messages};
use super::types::*;
use crate::protocol::{CoreError, ErrorCode};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};

static SESSIONS: OnceLock<Mutex<HashMap<String, DebugSession>>> = OnceLock::new();

#[derive(Debug)]
struct DebugSession {
    id: String,
    adapter_id: String,
    root_path: String,
    state: DebugSessionState,
    next_request_sequence: i64,
    next_event_sequence: u64,
    read_buffer: Vec<u8>,
    pending_requests: BTreeMap<i64, PendingRequest>,
    breakpoints: BTreeMap<String, Vec<SourceBreakpoint>>,
    exception_breakpoints: Vec<ExceptionBreakpoint>,
    did_configure_exception_breakpoints: bool,
    function_breakpoints: Vec<FunctionBreakpoint>,
    data_breakpoints: Vec<DataBreakpoint>,
    supports_run_in_terminal_request: bool,
    pending_run_in_terminal_requests: BTreeMap<String, i64>,
    did_receive_initialized: bool,
    supports_configuration_done: bool,
    capabilities: DebugCapabilities,
    stepping_filters: DebugSteppingFilters,
    debug_request_kind: Option<DebugRequestKind>,
    pending_launch: Option<(String, DebugLaunchConfiguration)>,
    outbound_frames: Vec<Vec<u8>>,
    events: Vec<DebugEvent>,
}

#[derive(Debug)]
enum PendingRequest {
    Initialize,
    Launch {
        operation_id: String,
    },
    SetBreakpoints {
        source_path: String,
        requested: Vec<SourceBreakpoint>,
    },
    SetExceptionBreakpoints,
    SetFunctionBreakpoints {
        requested: Vec<FunctionBreakpoint>,
    },
    DataBreakpointInfo {
        operation_id: String,
    },
    SetDataBreakpoints {
        requested: Vec<DataBreakpoint>,
    },
    SetVariable {
        operation_id: String,
        name: String,
    },
    Cancel,
    ConfigurationDone,
    Execute {
        operation_id: String,
        command: DebugExecutionCommand,
        single_thread: bool,
    },
    Inspect {
        operation_id: String,
        kind: DebugInspectKind,
    },
    Disconnect,
}

/// Creates a session and returns the framed DAP `initialize` request to send.
pub(crate) fn create_session(
    request: CreateSessionRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.session_id, "sessionId")?;
    validate_identifier(&request.adapter_id, "adapterId")?;
    validate_path(&request.root_path, "rootPath")?;
    let mut sessions = sessions_lock()?;
    if sessions.contains_key(&request.session_id) {
        return Err(invalid_request(
            "A debug session with this sessionId already exists.",
        ));
    }
    let mut session = DebugSession {
        id: request.session_id.clone(),
        adapter_id: request.adapter_id,
        root_path: request.root_path,
        state: DebugSessionState::Idle,
        next_request_sequence: 1,
        next_event_sequence: 1,
        read_buffer: Vec::new(),
        pending_requests: BTreeMap::new(),
        breakpoints: BTreeMap::new(),
        exception_breakpoints: Vec::new(),
        did_configure_exception_breakpoints: false,
        function_breakpoints: Vec::new(),
        data_breakpoints: Vec::new(),
        supports_run_in_terminal_request: request.supports_run_in_terminal_request,
        pending_run_in_terminal_requests: BTreeMap::new(),
        did_receive_initialized: false,
        supports_configuration_done: false,
        capabilities: DebugCapabilities::default(),
        stepping_filters: DebugSteppingFilters::unfiltered(),
        debug_request_kind: None,
        pending_launch: None,
        outbound_frames: Vec::new(),
        events: Vec::new(),
    };
    session.transition(DebugSessionState::Initializing);
    session.send_request(
        "initialize",
        json!({
            "clientID": "lithe",
            "clientName": "Lithe",
            "adapterID": session.adapter_id,
            "linesStartAt1": true,
            "columnsStartAt1": true,
            "pathFormat": "path",
            "supportsVariableType": true,
            "supportsVariablePaging": true,
            "supportsRunInTerminalRequest": session.supports_run_in_terminal_request,
            "supportsMemoryReferences": false,
            "supportsProgressReporting": false,
            "supportsInvalidatedEvent": true
        }),
        PendingRequest::Initialize,
    )?;
    let update = session.take_update();
    sessions.insert(request.session_id, session);
    Ok(update)
}

/// Queues launch or attach now, or stores it until initialize completes.
pub(crate) fn launch(request: LaunchRequest) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.operation_id, "operationId")?;
    with_session(&request.session_id, |session| {
        match session.state {
            DebugSessionState::Initializing => {
                session.pending_launch = Some((request.operation_id, request.configuration));
            }
            DebugSessionState::Ready => {
                session.perform_launch(request.operation_id, request.configuration)?;
            }
            _ => {
                return Err(invalid_request(
                    "The debug session is not ready to launch or attach.",
                ))
            }
        }
        Ok(session.take_update())
    })
}

/// Returns deterministic adapter defaults or a normalized native-client override.
pub(crate) fn stepping_filters(
    request: DebugSteppingFiltersRequest,
) -> Result<DebugSteppingFilters, CoreError> {
    validate_identifier(&request.adapter_id, "adapterId")?;
    normalize_stepping_filters(
        request
            .filters
            .unwrap_or_else(|| DebugSteppingFilters::defaults_for_adapter(&request.adapter_id)),
    )
}

/// Stores a deterministic breakpoint set and sends it after DAP initialization.
pub(crate) fn set_breakpoints(
    mut request: SetBreakpointsRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    validate_path(&request.source_path, "sourcePath")?;
    for breakpoint in &request.breakpoints {
        if breakpoint.line < 1 || breakpoint.column.is_some_and(|column| column < 1) {
            return Err(invalid_request(
                "Debug breakpoint line and column values must be one-based.",
            ));
        }
    }
    request.breakpoints.sort_by_key(|breakpoint| {
        (
            breakpoint.line,
            breakpoint.column.unwrap_or(0),
            breakpoint.enabled,
            breakpoint.condition.clone().unwrap_or_default(),
            breakpoint.hit_condition.clone().unwrap_or_default(),
            breakpoint.log_message.clone().unwrap_or_default(),
        )
    });
    request.breakpoints.dedup();
    with_session(&request.session_id, |session| {
        session
            .breakpoints
            .insert(request.source_path.clone(), request.breakpoints);
        if session.did_receive_initialized {
            session.send_breakpoints(&request.source_path)?;
        }
        Ok(session.take_update())
    })
}

/// Stores deterministic exception filters and sends them after DAP initialization.
pub(crate) fn set_exception_breakpoints(
    mut request: SetExceptionBreakpointsRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    for breakpoint in &mut request.breakpoints {
        breakpoint.filter = breakpoint.filter.trim().to_string();
        if breakpoint.filter.is_empty() {
            return Err(invalid_request(
                "Debug exception breakpoint filters cannot be empty.",
            ));
        }
        breakpoint.condition = breakpoint
            .condition
            .take()
            .map(|condition| condition.trim().to_string())
            .filter(|condition| !condition.is_empty());
    }
    request.breakpoints.sort_by(|left, right| {
        (&left.filter, left.enabled, &left.condition).cmp(&(
            &right.filter,
            right.enabled,
            &right.condition,
        ))
    });
    request
        .breakpoints
        .dedup_by(|left, right| left.filter == right.filter);
    with_session(&request.session_id, |session| {
        session.exception_breakpoints = request.breakpoints;
        session.did_configure_exception_breakpoints = true;
        if session.did_receive_initialized {
            session.send_exception_breakpoints()?;
        }
        Ok(session.take_update())
    })
}

/// Stores deterministic function breakpoints and sends them when supported.
pub(crate) fn set_function_breakpoints(
    mut request: SetFunctionBreakpointsRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    for breakpoint in &mut request.breakpoints {
        breakpoint.name = breakpoint.name.trim().to_string();
        if breakpoint.name.is_empty() {
            return Err(invalid_request(
                "Debug function breakpoint names cannot be empty.",
            ));
        }
        breakpoint.condition = normalize_optional_text(breakpoint.condition.take());
        breakpoint.hit_condition = normalize_optional_text(breakpoint.hit_condition.take());
    }
    request.breakpoints.sort_by(|left, right| {
        (
            &left.name,
            left.enabled,
            &left.condition,
            &left.hit_condition,
        )
            .cmp(&(
                &right.name,
                right.enabled,
                &right.condition,
                &right.hit_condition,
            ))
    });
    request
        .breakpoints
        .dedup_by(|left, right| left.name == right.name);
    with_session(&request.session_id, |session| {
        session.function_breakpoints = request.breakpoints;
        if session.did_receive_initialized && session.capabilities.supports_function_breakpoints {
            session.send_function_breakpoints()?;
        }
        Ok(session.take_update())
    })
}

/// Resolves one adapter-owned data breakpoint identity for the selected variable.
pub(crate) fn data_breakpoint_info(
    mut request: DataBreakpointInfoRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.operation_id, "operationId")?;
    request.name = request.name.trim().to_string();
    if request.name.is_empty() {
        return Err(invalid_request(
            "Debug data breakpoint info requires a variable name.",
        ));
    }
    if request
        .variables_reference
        .is_some_and(|reference| reference < 1)
    {
        return Err(invalid_request(
            "Debug variablesReference must be positive.",
        ));
    }
    if request.frame_id.is_some_and(|frame_id| frame_id < 0) {
        return Err(invalid_request("Debug frameId cannot be negative."));
    }
    if request.variables_reference.is_none() && request.frame_id.is_none() {
        return Err(invalid_request(
            "Debug data breakpoint info requires a variable reference or frame.",
        ));
    }
    with_session(&request.session_id, |session| {
        if !session.capabilities.supports_data_breakpoints {
            return Err(invalid_request(
                "The debug adapter does not support data breakpoints.",
            ));
        }
        let mut arguments = Map::new();
        arguments.insert("name".to_string(), json!(request.name));
        insert_option(
            &mut arguments,
            "variablesReference",
            request.variables_reference,
        );
        insert_option(&mut arguments, "frameId", request.frame_id);
        session.send_request(
            "dataBreakpointInfo",
            Value::Object(arguments),
            PendingRequest::DataBreakpointInfo {
                operation_id: request.operation_id,
            },
        )?;
        Ok(session.take_update())
    })
}

/// Stores deterministic adapter-resolved data breakpoints and sends them when supported.
pub(crate) fn set_data_breakpoints(
    mut request: SetDataBreakpointsRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    for breakpoint in &mut request.breakpoints {
        breakpoint.data_id = breakpoint.data_id.trim().to_string();
        if breakpoint.data_id.is_empty() {
            return Err(invalid_request(
                "Debug data breakpoint identifiers cannot be empty.",
            ));
        }
        breakpoint.label = normalize_optional_text(breakpoint.label.take());
        breakpoint.access_type = normalize_optional_text(breakpoint.access_type.take());
        breakpoint.condition = normalize_optional_text(breakpoint.condition.take());
        breakpoint.hit_condition = normalize_optional_text(breakpoint.hit_condition.take());
    }
    request.breakpoints.sort_by(|left, right| {
        (
            &left.data_id,
            &left.access_type,
            left.enabled,
            &left.condition,
            &left.hit_condition,
        )
            .cmp(&(
                &right.data_id,
                &right.access_type,
                right.enabled,
                &right.condition,
                &right.hit_condition,
            ))
    });
    request.breakpoints.dedup_by(|left, right| {
        left.data_id == right.data_id && left.access_type == right.access_type
    });
    with_session(&request.session_id, |session| {
        session.data_breakpoints = request.breakpoints;
        if session.did_receive_initialized && session.capabilities.supports_data_breakpoints {
            session.send_data_breakpoints()?;
        }
        Ok(session.take_update())
    })
}

/// Queues one capability-gated variable mutation while execution is paused.
pub(crate) fn set_variable(
    mut request: SetVariableRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.operation_id, "operationId")?;
    if request.variables_reference < 1 {
        return Err(invalid_request(
            "Debug variablesReference must be positive.",
        ));
    }
    request.name = request.name.trim().to_string();
    if request.name.is_empty() {
        return Err(invalid_request(
            "Debug setVariable requires a variable name.",
        ));
    }
    with_session(&request.session_id, |session| {
        if session.state != DebugSessionState::Paused {
            return Err(invalid_request(
                "Variable mutation requires a paused debug session.",
            ));
        }
        if !session.capabilities.supports_set_variable {
            return Err(invalid_request(
                "The debug adapter does not support variable mutation.",
            ));
        }
        session.send_request(
            "setVariable",
            json!({
                "variablesReference": request.variables_reference,
                "name": request.name,
                "value": request.value
            }),
            PendingRequest::SetVariable {
                operation_id: request.operation_id,
                name: request.name,
            },
        )?;
        Ok(session.take_update())
    })
}

/// Ends one caller-owned operation and ignores any later adapter response.
pub(crate) fn cancel_operation(
    request: CancelOperationRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.operation_id, "operationId")?;
    with_session(&request.session_id, |session| {
        let pending_sequence = session
            .pending_requests
            .iter()
            .find_map(|(sequence, pending)| {
                (pending.operation_id() == Some(request.operation_id.as_str())).then_some(*sequence)
            });
        let Some(pending_sequence) = pending_sequence else {
            return Ok(session.take_update());
        };
        let pending = session
            .pending_requests
            .remove(&pending_sequence)
            .expect("located pending debug operation should still exist");
        let command = pending.command().to_string();
        let message = match request.reason {
            DebugCancellationReason::Cancelled => "Debug operation was cancelled.",
            DebugCancellationReason::TimedOut => "Debug operation timed out.",
        };
        session.emit(DebugEventBody::OperationFailed {
            operation_id: request.operation_id,
            command,
            code: match request.reason {
                DebugCancellationReason::Cancelled => DebugOperationFailureCode::Cancelled,
                DebugCancellationReason::TimedOut => DebugOperationFailureCode::TimedOut,
            },
            message: message.to_string(),
        });
        if matches!(pending, PendingRequest::Launch { .. }) {
            session.transition(DebugSessionState::Failed);
        }
        if session.capabilities.supports_cancel_request {
            session.send_request(
                "cancel",
                json!({"requestId": pending_sequence}),
                PendingRequest::Cancel,
            )?;
        }
        Ok(session.take_update())
    })
}

/// Queues one continue, pause, or stepping request.
pub(crate) fn execute(request: ExecuteRequest) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.operation_id, "operationId")?;
    with_session(&request.session_id, |session| {
        if !matches!(
            session.state,
            DebugSessionState::Running | DebugSessionState::Paused
        ) {
            return Err(invalid_request(
                "Execution control requires a running or paused debug session.",
            ));
        }
        if matches!(
            request.command,
            DebugExecutionCommand::Next
                | DebugExecutionCommand::StepIn
                | DebugExecutionCommand::StepOut
                | DebugExecutionCommand::StepBack
                | DebugExecutionCommand::Goto
        ) && session.state != DebugSessionState::Paused
        {
            return Err(invalid_request("Stepping requires a paused debug session."));
        }
        if request.command == DebugExecutionCommand::Pause
            && session.state != DebugSessionState::Running
        {
            return Err(invalid_request("Pause requires a running debug session."));
        }
        if request.command == DebugExecutionCommand::Continue
            && session.state != DebugSessionState::Paused
        {
            return Err(invalid_request("Continue requires a paused debug session."));
        }
        if request.single_thread
            && !session
                .capabilities
                .supports_single_thread_execution_requests
        {
            return Err(invalid_request(
                "The debug adapter does not support single-thread execution control.",
            ));
        }
        if request.command == DebugExecutionCommand::StepBack
            && !session.capabilities.supports_step_back
        {
            return Err(invalid_request(
                "The debug adapter does not support stepping backwards.",
            ));
        }
        if request.command == DebugExecutionCommand::Goto
            && !session.capabilities.supports_goto_targets_request
        {
            return Err(invalid_request(
                "The debug adapter does not support run to cursor.",
            ));
        }
        if request.command == DebugExecutionCommand::Restart
            && !session.capabilities.supports_restart_request
        {
            return Err(invalid_request(
                "The debug adapter does not support restart requests.",
            ));
        }
        if request.command == DebugExecutionCommand::Terminate
            && !session.capabilities.supports_terminate_request
        {
            return Err(invalid_request(
                "The debug adapter does not support terminate requests.",
            ));
        }
        if matches!(
            request.command,
            DebugExecutionCommand::Next
                | DebugExecutionCommand::StepIn
                | DebugExecutionCommand::StepOut
                | DebugExecutionCommand::StepBack
                | DebugExecutionCommand::Goto
        ) && request.thread_id.is_none()
        {
            return Err(invalid_request("Stepping requires a selected thread."));
        }
        let mut arguments = Map::new();
        if !matches!(
            request.command,
            DebugExecutionCommand::Restart | DebugExecutionCommand::Terminate
        ) {
            if let Some(thread_id) = request.thread_id {
                arguments.insert("threadId".to_string(), json!(thread_id));
            }
        }
        if request.command == DebugExecutionCommand::Goto {
            insert_option(
                &mut arguments,
                "targetId",
                Some(required_positive(request.target_id, "targetId")?),
            );
        } else if request.command == DebugExecutionCommand::StepIn {
            if let Some(target_id) = request.target_id {
                if target_id < 1 {
                    return Err(invalid_request("Debug targetId must be positive."));
                }
                arguments.insert("targetId".to_string(), json!(target_id));
            }
        } else if request.target_id.is_some() {
            return Err(invalid_request(
                "Debug targetId is only valid for stepIn or goto.",
            ));
        }
        if matches!(
            request.command,
            DebugExecutionCommand::Continue
                | DebugExecutionCommand::Next
                | DebugExecutionCommand::StepIn
                | DebugExecutionCommand::StepOut
                | DebugExecutionCommand::StepBack
                | DebugExecutionCommand::Goto
                | DebugExecutionCommand::Pause
        ) {
            arguments.insert(
                "singleThread".to_string(),
                Value::Bool(request.single_thread),
            );
        }
        session.send_request(
            request.command.command(),
            Value::Object(arguments),
            PendingRequest::Execute {
                operation_id: request.operation_id,
                command: request.command,
                single_thread: request.single_thread,
            },
        )?;
        Ok(session.take_update())
    })
}

/// Queues one typed thread, stack, scope, variable, or evaluation request.
pub(crate) fn inspect(request: InspectRequest) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.operation_id, "operationId")?;
    let arguments = inspect_arguments(&request)?;
    with_session(&request.session_id, |session| {
        if !matches!(
            session.state,
            DebugSessionState::Running | DebugSessionState::Paused
        ) {
            return Err(invalid_request(
                "Debugger inspection requires a running or paused session.",
            ));
        }
        if request.kind == DebugInspectKind::StepInTargets
            && !session.capabilities.supports_step_in_targets_request
        {
            return Err(invalid_request(
                "The debug adapter does not support smart step into.",
            ));
        }
        if request.kind == DebugInspectKind::GotoTargets
            && !session.capabilities.supports_goto_targets_request
        {
            return Err(invalid_request(
                "The debug adapter does not support run to cursor.",
            ));
        }
        if request.kind == DebugInspectKind::ExceptionInfo {
            if session.state != DebugSessionState::Paused {
                return Err(invalid_request(
                    "Exception information requires a paused debug session.",
                ));
            }
            if !session.capabilities.supports_exception_info_request {
                return Err(invalid_request(
                    "The debug adapter does not support exception information.",
                ));
            }
        }
        session.send_request(
            request.kind.command(),
            Value::Object(arguments),
            PendingRequest::Inspect {
                operation_id: request.operation_id,
                kind: request.kind,
            },
        )?;
        Ok(session.take_update())
    })
}

/// Reduces one transport byte chunk and returns ordered writes and events.
pub(crate) fn receive(request: ReceiveRequest) -> Result<DebugSessionUpdate, CoreError> {
    let bytes = BASE64.decode(request.data_base64).map_err(|error| {
        invalid_request("Debug transport dataBase64 was invalid.").with_details(error.to_string())
    })?;
    with_session(&request.session_id, |session| {
        let messages = match parse_messages(&mut session.read_buffer, &bytes) {
            Ok(messages) => messages,
            Err(error) => {
                session.transition(DebugSessionState::Failed);
                return Err(error);
            }
        };
        for message in messages {
            session.handle_message(message)?;
        }
        Ok(session.take_update())
    })
}

/// Completes one adapter-originated terminal launch and emits its DAP response.
pub(crate) fn run_in_terminal_response(
    request: DebugRunInTerminalResponseRequest,
) -> Result<DebugSessionUpdate, CoreError> {
    validate_identifier(&request.request_id, "requestId")?;
    with_session(&request.session_id, |session| {
        let Some(&request_sequence) = session
            .pending_run_in_terminal_requests
            .get(&request.request_id)
        else {
            // Native terminal creation is asynchronous. A response that races
            // session shutdown, timeout, or a previous completion must not be
            // applied to a later adapter request.
            return Ok(session.take_update());
        };

        if request.success {
            validate_dap_process_id(request.process_id, "processId")?;
            validate_dap_process_id(request.shell_process_id, "shellProcessId")?;
        }
        session
            .pending_run_in_terminal_requests
            .remove(&request.request_id);

        if request.success {
            let mut body = Map::new();
            insert_option(&mut body, "processId", request.process_id);
            insert_option(&mut body, "shellProcessId", request.shell_process_id);
            session.send_response_with_body(
                request_sequence,
                "runInTerminal",
                true,
                None,
                Some(Value::Object(body)),
            )?;
        } else {
            let message = normalize_optional_text(request.message)
                .unwrap_or_else(|| "Lithe could not start the debuggee terminal.".to_string());
            session.send_response_with_body(
                request_sequence,
                "runInTerminal",
                false,
                Some(&message),
                None,
            )?;
        }
        Ok(session.take_update())
    })
}

/// Begins a graceful DAP disconnect while the host keeps transport ownership.
pub(crate) fn disconnect(request: SessionRequest) -> Result<DebugSessionUpdate, CoreError> {
    with_session(&request.session_id, |session| {
        if matches!(
            session.state,
            DebugSessionState::Terminating | DebugSessionState::Terminated
        ) {
            return Ok(session.take_update());
        }
        session.fail_pending_run_in_terminal_requests(
            "The debug session stopped before the terminal could start.",
        )?;
        // An attach session does not own the remote JVM, so disconnect must
        // never terminate it. A launch session owns the local debuggee.
        let terminate_debuggee = session.debug_request_kind == Some(DebugRequestKind::Launch);
        session.send_request(
            "disconnect",
            json!({"restart": false, "terminateDebuggee": terminate_debuggee}),
            PendingRequest::Disconnect,
        )?;
        session.transition(DebugSessionState::Terminating);
        Ok(session.take_update())
    })
}

/// Removes a session after the platform has closed its socket or process.
pub(crate) fn destroy_session(request: SessionRequest) -> Result<(), CoreError> {
    let mut sessions = sessions_lock()?;
    if sessions.remove(&request.session_id).is_none() {
        return Err(session_not_found(&request.session_id));
    }
    Ok(())
}

impl DebugSession {
    fn perform_launch(
        &mut self,
        operation_id: String,
        configuration: DebugLaunchConfiguration,
    ) -> Result<(), CoreError> {
        let request_kind = configuration.request;
        let mut arguments = configuration.arguments;
        let filters = normalize_stepping_filters(
            configuration
                .stepping_filters
                .unwrap_or_else(|| DebugSteppingFilters::defaults_for_adapter(&self.adapter_id)),
        )?;
        if self.adapter_id == "java" && !arguments.contains_key("stepFilters") {
            arguments.insert("stepFilters".to_string(), java_step_filters(&filters));
        }
        self.stepping_filters = filters;
        arguments
            .entry("name".to_string())
            .or_insert(Value::String(configuration.name));
        arguments
            .entry("cwd".to_string())
            .or_insert(Value::String(self.root_path.clone()));
        self.debug_request_kind = Some(request_kind);
        self.transition(DebugSessionState::Launching);
        self.send_request(
            request_kind.command(),
            Value::Object(arguments),
            PendingRequest::Launch { operation_id },
        )
    }

    fn send_breakpoints(&mut self, source_path: &str) -> Result<(), CoreError> {
        let requested = self
            .breakpoints
            .get(source_path)
            .cloned()
            .unwrap_or_default();
        let active: Vec<SourceBreakpoint> = requested
            .iter()
            .filter(|breakpoint| breakpoint.enabled)
            .cloned()
            .collect();
        let breakpoints: Vec<Value> = active
            .iter()
            .map(|breakpoint| {
                let mut value = Map::new();
                value.insert("line".to_string(), json!(breakpoint.line));
                insert_option(&mut value, "column", breakpoint.column);
                insert_nonempty(&mut value, "condition", breakpoint.condition.as_deref());
                insert_nonempty(
                    &mut value,
                    "hitCondition",
                    breakpoint.hit_condition.as_deref(),
                );
                insert_nonempty(&mut value, "logMessage", breakpoint.log_message.as_deref());
                Value::Object(value)
            })
            .collect();
        let source_name = source_path
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or(source_path);
        self.send_request(
            "setBreakpoints",
            json!({
                "source": {"name": source_name, "path": source_path},
                "breakpoints": breakpoints,
                "sourceModified": false
            }),
            PendingRequest::SetBreakpoints {
                source_path: source_path.to_string(),
                requested: active,
            },
        )
    }

    fn send_exception_breakpoints(&mut self) -> Result<(), CoreError> {
        let active: Vec<&ExceptionBreakpoint> = self
            .exception_breakpoints
            .iter()
            .filter(|breakpoint| breakpoint.enabled)
            .collect();
        let filters: Vec<&str> = active
            .iter()
            .map(|breakpoint| breakpoint.filter.as_str())
            .collect();
        let filter_options: Vec<Value> = if self.capabilities.supports_exception_filter_options {
            active
                .iter()
                .filter_map(|breakpoint| {
                    breakpoint.condition.as_ref().map(|condition| {
                        json!({
                            "filterId": breakpoint.filter,
                            "condition": condition
                        })
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        let mut arguments = Map::new();
        arguments.insert("filters".to_string(), json!(filters));
        if !filter_options.is_empty() {
            arguments.insert("filterOptions".to_string(), Value::Array(filter_options));
        }
        self.send_request(
            "setExceptionBreakpoints",
            Value::Object(arguments),
            PendingRequest::SetExceptionBreakpoints,
        )
    }

    fn send_function_breakpoints(&mut self) -> Result<(), CoreError> {
        let requested: Vec<FunctionBreakpoint> = self
            .function_breakpoints
            .iter()
            .filter(|breakpoint| breakpoint.enabled)
            .cloned()
            .collect();
        let breakpoints: Vec<Value> = requested
            .iter()
            .map(|breakpoint| {
                let mut value = Map::new();
                value.insert("name".to_string(), json!(breakpoint.name));
                insert_nonempty(&mut value, "condition", breakpoint.condition.as_deref());
                insert_nonempty(
                    &mut value,
                    "hitCondition",
                    breakpoint.hit_condition.as_deref(),
                );
                Value::Object(value)
            })
            .collect();
        self.send_request(
            "setFunctionBreakpoints",
            json!({"breakpoints": breakpoints}),
            PendingRequest::SetFunctionBreakpoints { requested },
        )
    }

    fn send_data_breakpoints(&mut self) -> Result<(), CoreError> {
        let requested: Vec<DataBreakpoint> = self
            .data_breakpoints
            .iter()
            .filter(|breakpoint| breakpoint.enabled)
            .cloned()
            .collect();
        let breakpoints: Vec<Value> = requested
            .iter()
            .map(|breakpoint| {
                let mut value = Map::new();
                value.insert("dataId".to_string(), json!(breakpoint.data_id));
                insert_nonempty(&mut value, "accessType", breakpoint.access_type.as_deref());
                insert_nonempty(&mut value, "condition", breakpoint.condition.as_deref());
                insert_nonempty(
                    &mut value,
                    "hitCondition",
                    breakpoint.hit_condition.as_deref(),
                );
                Value::Object(value)
            })
            .collect();
        self.send_request(
            "setDataBreakpoints",
            json!({"breakpoints": breakpoints}),
            PendingRequest::SetDataBreakpoints { requested },
        )
    }

    fn send_request(
        &mut self,
        command: &str,
        arguments: Value,
        pending: PendingRequest,
    ) -> Result<(), CoreError> {
        let sequence = self.next_request_sequence;
        self.next_request_sequence += 1;
        let message = json!({
            "seq": sequence,
            "type": "request",
            "command": command,
            "arguments": arguments
        });
        self.outbound_frames.push(frame_message(&message)?);
        self.pending_requests.insert(sequence, pending);
        Ok(())
    }

    fn send_response(
        &mut self,
        request_sequence: i64,
        command: &str,
        success: bool,
        message: Option<&str>,
    ) -> Result<(), CoreError> {
        self.send_response_with_body(request_sequence, command, success, message, None)
    }

    fn send_response_with_body(
        &mut self,
        request_sequence: i64,
        command: &str,
        success: bool,
        message: Option<&str>,
        body: Option<Value>,
    ) -> Result<(), CoreError> {
        let sequence = self.next_request_sequence;
        self.next_request_sequence += 1;
        let mut response = json!({
            "seq": sequence,
            "type": "response",
            "request_seq": request_sequence,
            "success": success,
            "command": command
        });
        if let Some(message) = message {
            response["message"] = Value::String(message.to_string());
        }
        if let Some(body) = body {
            response["body"] = body;
        }
        self.outbound_frames.push(frame_message(&response)?);
        Ok(())
    }

    fn handle_message(&mut self, message: Value) -> Result<(), CoreError> {
        match message.get("type").and_then(Value::as_str) {
            Some("response") => self.handle_response(&message),
            Some("event") => self.handle_event(&message),
            Some("request") => self.handle_server_request(&message),
            _ => Err(CoreError::new(
                ErrorCode::ParseFailed,
                "DAP message did not contain a supported type.",
            )),
        }
    }

    fn handle_response(&mut self, message: &Value) -> Result<(), CoreError> {
        let request_sequence = required_i64(message, "request_seq")?;
        let Some(pending) = self.pending_requests.remove(&request_sequence) else {
            return Ok(());
        };
        let success = message
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !success {
            let command = pending.command().to_string();
            let detail = message
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("The debug adapter rejected the request.")
                .to_string();
            if let Some(operation_id) = pending.operation_id() {
                self.emit(DebugEventBody::OperationFailed {
                    operation_id: operation_id.to_string(),
                    command,
                    code: DebugOperationFailureCode::AdapterRejected,
                    message: detail,
                });
            }
            if matches!(
                pending,
                PendingRequest::Initialize | PendingRequest::Launch { .. }
            ) {
                self.transition(DebugSessionState::Failed);
            }
            return Ok(());
        }
        let body = message.get("body").cloned().unwrap_or_else(|| json!({}));
        match pending {
            PendingRequest::Initialize => {
                self.capabilities = parse_capabilities(&body);
                if !self.did_configure_exception_breakpoints {
                    self.exception_breakpoints = self
                        .capabilities
                        .exception_breakpoint_filters
                        .iter()
                        .map(|filter| ExceptionBreakpoint {
                            filter: filter.filter.clone(),
                            enabled: filter.default,
                            condition: None,
                        })
                        .collect();
                }
                self.supports_configuration_done = self.capabilities.supports_configuration_done;
                self.emit(DebugEventBody::Capabilities {
                    capabilities: self.capabilities.clone(),
                });
                self.transition(DebugSessionState::Ready);
                if let Some((operation_id, configuration)) = self.pending_launch.take() {
                    self.perform_launch(operation_id, configuration)?;
                }
            }
            PendingRequest::Launch { operation_id } => {
                self.transition(DebugSessionState::Running);
                self.emit(DebugEventBody::OperationCompleted {
                    operation_id,
                    result: DebugOperationResult::Acknowledged {
                        command: "launch".to_string(),
                    },
                });
            }
            PendingRequest::SetBreakpoints {
                source_path,
                requested,
            } => self.emit_breakpoint_results(&body, &source_path, &requested),
            PendingRequest::SetExceptionBreakpoints => {}
            PendingRequest::SetFunctionBreakpoints { requested } => {
                self.emit_function_breakpoint_results(&body, &requested)
            }
            PendingRequest::DataBreakpointInfo { operation_id } => {
                self.emit(DebugEventBody::OperationCompleted {
                    operation_id,
                    result: DebugOperationResult::DataBreakpointInfo {
                        data_id: string_field(&body, "dataId"),
                        description: body
                            .get("description")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        access_types: body
                            .get("accessTypes")
                            .and_then(Value::as_array)
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .map(str::to_string)
                            .collect(),
                        can_persist: bool_field(&body, "canPersist"),
                    },
                });
            }
            PendingRequest::SetDataBreakpoints { requested } => {
                self.emit_data_breakpoint_results(&body, &requested)
            }
            PendingRequest::SetVariable { operation_id, name } => {
                self.emit(DebugEventBody::OperationCompleted {
                    operation_id,
                    result: DebugOperationResult::SetVariable {
                        variable: DebugVariable {
                            name,
                            value: required_str(&body, "value")?.to_string(),
                            r#type: string_field(&body, "type"),
                            evaluate_name: None,
                            variables_reference: body
                                .get("variablesReference")
                                .and_then(Value::as_i64)
                                .unwrap_or(0),
                            named_variables: nonnegative_count_field(&body, "namedVariables"),
                            indexed_variables: nonnegative_count_field(&body, "indexedVariables"),
                        },
                    },
                });
            }
            PendingRequest::Cancel => {}
            PendingRequest::ConfigurationDone => {}
            PendingRequest::Execute {
                operation_id,
                command,
                single_thread,
            } => {
                if command != DebugExecutionCommand::Pause
                    && command != DebugExecutionCommand::Terminate
                    && !(single_thread && command == DebugExecutionCommand::Continue)
                {
                    self.transition(DebugSessionState::Running);
                }
                self.emit(DebugEventBody::OperationCompleted {
                    operation_id,
                    result: DebugOperationResult::Acknowledged {
                        command: command.command().to_string(),
                    },
                });
            }
            PendingRequest::Inspect { operation_id, kind } => {
                let result =
                    normalize_inspection(kind, &body, &self.stepping_filters, &self.root_path)?;
                self.emit(DebugEventBody::OperationCompleted {
                    operation_id,
                    result,
                });
            }
            PendingRequest::Disconnect => {}
        }
        Ok(())
    }

    fn handle_event(&mut self, message: &Value) -> Result<(), CoreError> {
        let event = required_str(message, "event")?;
        let body = message.get("body").cloned().unwrap_or_else(|| json!({}));
        match event {
            "initialized" => {
                self.did_receive_initialized = true;
                self.emit(DebugEventBody::Initialized);
                self.send_exception_breakpoints()?;
                if self.capabilities.supports_function_breakpoints {
                    self.send_function_breakpoints()?;
                }
                if self.capabilities.supports_data_breakpoints {
                    self.send_data_breakpoints()?;
                }
                let sources: Vec<String> = self.breakpoints.keys().cloned().collect();
                for source in sources {
                    self.send_breakpoints(&source)?;
                }
                if self.supports_configuration_done {
                    self.send_request(
                        "configurationDone",
                        json!({}),
                        PendingRequest::ConfigurationDone,
                    )?;
                }
            }
            "output" => self.emit(DebugEventBody::Output {
                category: body
                    .get("category")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                output: body
                    .get("output")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            }),
            "stopped" => {
                self.transition(DebugSessionState::Paused);
                self.emit(DebugEventBody::Stopped {
                    reason: body
                        .get("reason")
                        .and_then(Value::as_str)
                        .unwrap_or("pause")
                        .to_string(),
                    thread_id: body.get("threadId").and_then(Value::as_i64),
                    description: body
                        .get("description")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                });
            }
            "continued" => {
                if body
                    .get("allThreadsContinued")
                    .and_then(Value::as_bool)
                    .unwrap_or(true)
                {
                    self.transition(DebugSessionState::Running);
                }
                self.emit(DebugEventBody::Continued {
                    thread_id: body.get("threadId").and_then(Value::as_i64),
                });
            }
            "terminated" => {
                self.transition(DebugSessionState::Terminated);
                self.emit(DebugEventBody::Terminated { exit_code: None });
            }
            "exited" => {
                self.transition(DebugSessionState::Terminated);
                self.emit(DebugEventBody::Terminated {
                    exit_code: body.get("exitCode").and_then(Value::as_i64),
                });
            }
            "breakpoint" => {
                if let Some(value) = body.get("breakpoint") {
                    self.emit(DebugEventBody::Breakpoint {
                        breakpoint: parse_breakpoint(value, None, None, 0),
                    });
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn handle_server_request(&mut self, message: &Value) -> Result<(), CoreError> {
        let request_sequence = required_i64(message, "seq")?;
        let command = required_str(message, "command")?;
        if command == "runInTerminal" && self.supports_run_in_terminal_request {
            let arguments = message.get("arguments").unwrap_or(&Value::Null);
            match parse_run_in_terminal_request(arguments) {
                Ok(request) => {
                    let request_id = format!("runInTerminal-{request_sequence}");
                    if self
                        .pending_run_in_terminal_requests
                        .contains_key(&request_id)
                    {
                        // One DAP sequence can have only one response. Keep the
                        // original native launch pending instead of replacing
                        // it or starting a second process for a malformed retry.
                        return Ok(());
                    }
                    self.pending_run_in_terminal_requests
                        .insert(request_id.clone(), request_sequence);
                    self.emit(DebugEventBody::RunInTerminalRequested {
                        request_id,
                        request,
                    });
                    return Ok(());
                }
                Err(error) => {
                    return self.send_response(
                        request_sequence,
                        command,
                        false,
                        Some(&error.message),
                    );
                }
            }
        }
        self.send_response(
            request_sequence,
            command,
            false,
            Some("This debug adapter request is not supported by Lithe."),
        )
    }

    fn fail_pending_run_in_terminal_requests(&mut self, message: &str) -> Result<(), CoreError> {
        let pending = std::mem::take(&mut self.pending_run_in_terminal_requests);
        for (_, request_sequence) in pending {
            self.send_response(request_sequence, "runInTerminal", false, Some(message))?;
        }
        Ok(())
    }

    fn emit_breakpoint_results(
        &mut self,
        body: &Value,
        source_path: &str,
        requested: &[SourceBreakpoint],
    ) {
        let values = body
            .get("breakpoints")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for (index, value) in values.iter().enumerate() {
            let fallback = requested.get(index).map(|breakpoint| breakpoint.line);
            self.emit(DebugEventBody::Breakpoint {
                breakpoint: parse_breakpoint(value, None, Some(source_path), fallback.unwrap_or(0)),
            });
        }
    }

    fn emit_function_breakpoint_results(&mut self, body: &Value, requested: &[FunctionBreakpoint]) {
        let values = body
            .get("breakpoints")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for (index, value) in values.iter().enumerate() {
            let function_name = requested
                .get(index)
                .map(|breakpoint| breakpoint.name.as_str());
            self.emit(DebugEventBody::Breakpoint {
                breakpoint: parse_breakpoint(value, function_name, None, 0),
            });
        }
    }

    fn emit_data_breakpoint_results(&mut self, body: &Value, requested: &[DataBreakpoint]) {
        let values = body
            .get("breakpoints")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for (index, value) in values.iter().enumerate() {
            let mut breakpoint = parse_breakpoint(value, None, None, 0);
            breakpoint.data_id = requested.get(index).map(|item| item.data_id.clone());
            self.emit(DebugEventBody::Breakpoint { breakpoint });
        }
    }

    fn transition(&mut self, state: DebugSessionState) {
        if self.state == state {
            return;
        }
        self.state = state;
        self.emit(DebugEventBody::StateChanged { state });
    }

    fn emit(&mut self, body: DebugEventBody) {
        let sequence = self.next_event_sequence;
        self.next_event_sequence += 1;
        self.events.push(DebugEvent { sequence, body });
    }

    fn take_update(&mut self) -> DebugSessionUpdate {
        DebugSessionUpdate {
            session_id: self.id.clone(),
            state: self.state,
            outbound_frames: std::mem::take(&mut self.outbound_frames)
                .into_iter()
                .map(|frame| BASE64.encode(frame))
                .collect(),
            events: std::mem::take(&mut self.events),
        }
    }
}

impl PendingRequest {
    fn command(&self) -> &'static str {
        match self {
            Self::Initialize => "initialize",
            Self::Launch { .. } => "launch",
            Self::SetBreakpoints { .. } => "setBreakpoints",
            Self::SetExceptionBreakpoints => "setExceptionBreakpoints",
            Self::SetFunctionBreakpoints { .. } => "setFunctionBreakpoints",
            Self::DataBreakpointInfo { .. } => "dataBreakpointInfo",
            Self::SetDataBreakpoints { .. } => "setDataBreakpoints",
            Self::SetVariable { .. } => "setVariable",
            Self::Cancel => "cancel",
            Self::ConfigurationDone => "configurationDone",
            Self::Execute { command, .. } => command.command(),
            Self::Inspect { kind, .. } => kind.command(),
            Self::Disconnect => "disconnect",
        }
    }

    fn operation_id(&self) -> Option<&str> {
        match self {
            Self::Launch { operation_id }
            | Self::Execute { operation_id, .. }
            | Self::Inspect { operation_id, .. }
            | Self::DataBreakpointInfo { operation_id }
            | Self::SetVariable { operation_id, .. } => Some(operation_id),
            _ => None,
        }
    }
}

fn inspect_arguments(request: &InspectRequest) -> Result<Map<String, Value>, CoreError> {
    if request.kind != DebugInspectKind::Variables
        && (request.variable_filter.is_some() || request.start.is_some() || request.count.is_some())
    {
        return Err(invalid_request(
            "Debug variable paging is only valid for variables inspection.",
        ));
    }
    let mut arguments = Map::new();
    match request.kind {
        DebugInspectKind::Threads => {}
        DebugInspectKind::StackTrace => {
            arguments.insert(
                "threadId".to_string(),
                json!(required_positive(request.thread_id, "threadId")?),
            );
        }
        DebugInspectKind::Scopes => {
            arguments.insert(
                "frameId".to_string(),
                json!(required_nonnegative(request.frame_id, "frameId")?),
            );
        }
        DebugInspectKind::Variables => {
            arguments.insert(
                "variablesReference".to_string(),
                json!(required_positive(
                    request.variables_reference,
                    "variablesReference"
                )?),
            );
            if let Some(filter) = request.variable_filter {
                arguments.insert("filter".to_string(), json!(filter.argument()));
            }
            if let Some(start) = request.start {
                arguments.insert(
                    "start".to_string(),
                    json!(required_nonnegative(Some(start), "start")?),
                );
            }
            if let Some(count) = request.count {
                arguments.insert(
                    "count".to_string(),
                    json!(required_positive(Some(count), "count")?),
                );
            }
        }
        DebugInspectKind::Evaluate => {
            let expression = request.expression.as_deref().unwrap_or_default().trim();
            if expression.is_empty() {
                return Err(invalid_request("Debug evaluate requires an expression."));
            }
            arguments.insert("expression".to_string(), json!(expression));
            arguments.insert("context".to_string(), json!("watch"));
            if let Some(frame_id) = request.frame_id {
                if frame_id < 0 {
                    return Err(invalid_request("Debug frameId cannot be negative."));
                }
                arguments.insert("frameId".to_string(), json!(frame_id));
            }
        }
        DebugInspectKind::ExceptionInfo => {
            arguments.insert(
                "threadId".to_string(),
                json!(required_positive(request.thread_id, "threadId")?),
            );
        }
        DebugInspectKind::StepInTargets => {
            arguments.insert(
                "frameId".to_string(),
                json!(required_nonnegative(request.frame_id, "frameId")?),
            );
        }
        DebugInspectKind::GotoTargets => {
            let source_path = request.source_path.as_deref().unwrap_or_default().trim();
            if source_path.is_empty() {
                return Err(invalid_request("Debug gotoTargets requires a source path."));
            }
            arguments.insert("source".to_string(), json!({"path": source_path}));
            arguments.insert(
                "line".to_string(),
                json!(required_positive(request.line, "line")?),
            );
            if let Some(column) = request.column {
                if column < 1 {
                    return Err(invalid_request("Debug column must be positive."));
                }
                arguments.insert("column".to_string(), json!(column));
            }
        }
    }
    Ok(arguments)
}

fn normalize_inspection(
    kind: DebugInspectKind,
    body: &Value,
    stepping_filters: &DebugSteppingFilters,
    root_path: &str,
) -> Result<DebugOperationResult, CoreError> {
    match kind {
        DebugInspectKind::Threads => Ok(DebugOperationResult::Threads {
            threads: required_array(body, "threads")?
                .iter()
                .filter_map(parse_thread)
                .collect(),
        }),
        DebugInspectKind::StackTrace => Ok(DebugOperationResult::StackTrace {
            stack_frames: required_array(body, "stackFrames")?
                .iter()
                .filter_map(|value| parse_stack_frame(value, stepping_filters, root_path))
                .collect(),
        }),
        DebugInspectKind::Scopes => Ok(DebugOperationResult::Scopes {
            scopes: required_array(body, "scopes")?
                .iter()
                .filter_map(parse_scope)
                .collect(),
        }),
        DebugInspectKind::Variables => Ok(DebugOperationResult::Variables {
            variables: required_array(body, "variables")?
                .iter()
                .filter_map(parse_variable)
                .collect(),
        }),
        DebugInspectKind::Evaluate => Ok(DebugOperationResult::Evaluate {
            variable: DebugVariable {
                name: body
                    .get("evaluateName")
                    .and_then(Value::as_str)
                    .unwrap_or("Expression")
                    .to_string(),
                value: required_str(body, "result")?.to_string(),
                r#type: string_field(body, "type"),
                evaluate_name: string_field(body, "evaluateName"),
                variables_reference: body
                    .get("variablesReference")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                named_variables: nonnegative_count_field(body, "namedVariables"),
                indexed_variables: nonnegative_count_field(body, "indexedVariables"),
            },
        }),
        DebugInspectKind::ExceptionInfo => Ok(DebugOperationResult::ExceptionInfo {
            exception_info: DebugExceptionInfo {
                exception_id: required_str(body, "exceptionId")?.to_string(),
                description: string_field(body, "description"),
                break_mode: required_str(body, "breakMode")?.to_string(),
                details: body.get("details").and_then(parse_exception_details),
            },
        }),
        DebugInspectKind::StepInTargets => Ok(DebugOperationResult::StepInTargets {
            targets: required_array(body, "targets")?
                .iter()
                .filter_map(parse_step_in_target)
                .collect(),
        }),
        DebugInspectKind::GotoTargets => Ok(DebugOperationResult::GotoTargets {
            targets: required_array(body, "targets")?
                .iter()
                .filter_map(parse_goto_target)
                .collect(),
        }),
    }
}

fn parse_exception_details(value: &Value) -> Option<DebugExceptionDetails> {
    value.as_object()?;
    Some(DebugExceptionDetails {
        message: string_field(value, "message"),
        type_name: string_field(value, "typeName"),
        full_type_name: string_field(value, "fullTypeName"),
        evaluate_name: string_field(value, "evaluateName"),
        stack_trace: string_field(value, "stackTrace"),
        inner_exceptions: value
            .get("innerException")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(parse_exception_details)
            .collect(),
    })
}

fn parse_step_in_target(value: &Value) -> Option<DebugStepInTarget> {
    Some(DebugStepInTarget {
        id: value.get("id")?.as_i64()?,
        label: value.get("label")?.as_str()?.to_string(),
        line: value.get("line").and_then(Value::as_i64),
        column: value.get("column").and_then(Value::as_i64),
        end_line: value.get("endLine").and_then(Value::as_i64),
        end_column: value.get("endColumn").and_then(Value::as_i64),
    })
}

fn parse_goto_target(value: &Value) -> Option<DebugGotoTarget> {
    Some(DebugGotoTarget {
        id: value.get("id")?.as_i64()?,
        label: value.get("label")?.as_str()?.to_string(),
        line: value.get("line")?.as_i64()?,
        column: value.get("column").and_then(Value::as_i64),
        end_line: value.get("endLine").and_then(Value::as_i64),
        end_column: value.get("endColumn").and_then(Value::as_i64),
        instruction_pointer_reference: string_field(value, "instructionPointerReference"),
    })
}

fn parse_thread(value: &Value) -> Option<DebugThread> {
    Some(DebugThread {
        id: value.get("id")?.as_i64()?,
        name: value.get("name")?.as_str()?.to_string(),
    })
}

fn parse_stack_frame(
    value: &Value,
    stepping_filters: &DebugSteppingFilters,
    root_path: &str,
) -> Option<DebugStackFrame> {
    let name = value.get("name")?.as_str()?.to_string();
    let source_path = value
        .get("source")
        .and_then(|source| source.get("path"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let presentation_hint = value.get("presentationHint").and_then(Value::as_str);
    Some(DebugStackFrame {
        id: value.get("id")?.as_i64()?,
        is_filtered: stack_frame_matches_filters(
            &name,
            source_path.as_deref(),
            presentation_hint,
            stepping_filters,
            root_path,
        ),
        name,
        source_path,
        line: value.get("line").and_then(Value::as_i64).unwrap_or(1),
        column: value.get("column").and_then(Value::as_i64).unwrap_or(1),
    })
}

fn normalize_stepping_filters(
    mut filters: DebugSteppingFilters,
) -> Result<DebugSteppingFilters, CoreError> {
    const MAXIMUM_FILTER_COUNT: usize = 256;
    const MAXIMUM_FILTER_LENGTH: usize = 256;

    let mut normalized = Vec::with_capacity(filters.class_name_filters.len());
    for filter in filters.class_name_filters {
        let filter = filter.trim();
        if filter.is_empty() {
            continue;
        }
        if filter.chars().count() > MAXIMUM_FILTER_LENGTH || filter.chars().any(char::is_control) {
            return Err(invalid_request(
                "Debug stepping filters must be short single-line class patterns.",
            ));
        }
        normalized.push(filter.to_string());
    }
    normalized.sort();
    normalized.dedup();
    if normalized.len() > MAXIMUM_FILTER_COUNT {
        return Err(invalid_request(
            "Debug stepping filters cannot contain more than 256 class patterns.",
        ));
    }
    filters.class_name_filters = normalized;
    Ok(filters)
}

fn java_step_filters(filters: &DebugSteppingFilters) -> Value {
    json!({
        "skipClasses": filters.class_name_filters,
        "skipSynthetics": filters.skip_synthetics,
        "skipStaticInitializers": filters.skip_static_initializers,
        "skipConstructors": filters.skip_constructors
    })
}

fn stack_frame_matches_filters(
    name: &str,
    source_path: Option<&str>,
    presentation_hint: Option<&str>,
    filters: &DebugSteppingFilters,
    root_path: &str,
) -> bool {
    filters
        .class_name_filters
        .iter()
        .any(|filter| match filter.as_str() {
            "$JDK" => is_jdk_frame(name, source_path, presentation_hint),
            "$Libraries" => is_library_frame(source_path, presentation_hint, root_path),
            pattern => class_pattern_matches_frame(pattern, name, source_path),
        })
}

fn class_pattern_matches_frame(pattern: &str, name: &str, source_path: Option<&str>) -> bool {
    if wildcard_match(pattern, name) || name == pattern || name.starts_with(&format!("{pattern}."))
    {
        return true;
    }

    let simple_type = name.split('.').next().unwrap_or(name);
    if source_path.is_none()
        && !pattern.contains('*')
        && pattern
            .rsplit('.')
            .next()
            .is_some_and(|value| value == simple_type)
    {
        return true;
    }

    source_path.is_some_and(|source_path| source_path_matches_pattern(source_path, pattern))
}

fn source_path_matches_pattern(source_path: &str, pattern: &str) -> bool {
    let source_path = source_path.replace('\\', "/");
    let slash_pattern = format!("*{}*", pattern.replace('.', "/"));
    let dotted_pattern = format!("*{pattern}*");
    wildcard_match(&slash_pattern, &source_path) || wildcard_match(&dotted_pattern, &source_path)
}

fn is_jdk_frame(name: &str, source_path: Option<&str>, presentation_hint: Option<&str>) -> bool {
    if ["com.sun.", "java.", "javax.", "jdk.", "org.omg.", "sun."]
        .iter()
        .any(|prefix| name.starts_with(prefix))
    {
        return true;
    }
    if presentation_hint == Some("subtle") && source_path.is_none() {
        return true;
    }
    let Some(source_path) = source_path else {
        return false;
    };
    let source_path = source_path.replace('\\', "/");
    if source_path.contains("/java.base/")
        || source_path.contains("/java.desktop/")
        || source_path.contains("/java.logging/")
        || source_path.contains("/java.management/")
        || source_path.contains("/java.naming/")
        || source_path.contains("/java.net.http/")
        || source_path.contains("/java.sql/")
        || source_path.contains("/java.xml/")
        || source_path.contains("/jdk.")
    {
        return true;
    }
    [
        "java/applet",
        "java/awt",
        "java/beans",
        "java/io",
        "java/lang",
        "java/math",
        "java/net",
        "java/nio",
        "java/rmi",
        "java/security",
        "java/sql",
        "java/text",
        "java/time",
        "java/util",
        "javax",
        "jdk",
        "sun",
        "com/sun",
        "org/omg",
    ]
    .iter()
    .any(|prefix| source_has_path_prefix(&source_path, prefix))
}

fn source_has_path_prefix(source_path: &str, prefix: &str) -> bool {
    source_path.contains(&format!("/{prefix}/")) || source_path.contains(&format!("/{prefix}."))
}

fn is_library_frame(
    source_path: Option<&str>,
    presentation_hint: Option<&str>,
    root_path: &str,
) -> bool {
    if presentation_hint == Some("subtle") || source_path.is_none() {
        return true;
    }
    let source_path = source_path.unwrap_or_default();
    !source_path_is_within_root(source_path, root_path) && path_is_absolute_or_uri(source_path)
}

fn source_path_is_within_root(source_path: &str, root_path: &str) -> bool {
    let source_path = normalized_comparison_path(source_path);
    let root_path = normalized_comparison_path(root_path);
    source_path == root_path
        || source_path
            .strip_prefix(&root_path)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

fn normalized_comparison_path(path: &str) -> String {
    path.strip_prefix("file://")
        .unwrap_or(path)
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_ascii_lowercase()
}

fn path_is_absolute_or_uri(path: &str) -> bool {
    let bytes = path.as_bytes();
    path.starts_with('/') || path.contains("://") || (bytes.len() >= 2 && bytes[1] == b':')
}

fn wildcard_match(pattern: &str, value: &str) -> bool {
    let pattern = pattern.as_bytes();
    let value = value.as_bytes();
    let (mut pattern_index, mut value_index) = (0, 0);
    let (mut star_index, mut star_value_index) = (None, 0);

    while value_index < value.len() {
        if pattern_index < pattern.len() && pattern[pattern_index] == value[value_index] {
            pattern_index += 1;
            value_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            star_index = Some(pattern_index);
            pattern_index += 1;
            star_value_index = value_index;
        } else if let Some(star) = star_index {
            pattern_index = star + 1;
            star_value_index += 1;
            value_index = star_value_index;
        } else {
            return false;
        }
    }
    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }
    pattern_index == pattern.len()
}

fn parse_scope(value: &Value) -> Option<DebugScope> {
    Some(DebugScope {
        name: value.get("name")?.as_str()?.to_string(),
        variables_reference: value.get("variablesReference")?.as_i64()?,
        expensive: value
            .get("expensive")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        named_variables: nonnegative_count_field(value, "namedVariables"),
        indexed_variables: nonnegative_count_field(value, "indexedVariables"),
    })
}

fn parse_variable(value: &Value) -> Option<DebugVariable> {
    Some(DebugVariable {
        name: value.get("name")?.as_str()?.to_string(),
        value: value.get("value")?.as_str()?.to_string(),
        r#type: string_field(value, "type"),
        evaluate_name: string_field(value, "evaluateName"),
        variables_reference: value
            .get("variablesReference")
            .and_then(Value::as_i64)
            .unwrap_or(0),
        named_variables: nonnegative_count_field(value, "namedVariables"),
        indexed_variables: nonnegative_count_field(value, "indexedVariables"),
    })
}

fn nonnegative_count_field(value: &Value, key: &str) -> i64 {
    value.get(key).and_then(Value::as_i64).unwrap_or(0).max(0)
}

fn parse_breakpoint(
    value: &Value,
    function_name: Option<&str>,
    source_path: Option<&str>,
    fallback_line: i64,
) -> DebugBreakpoint {
    DebugBreakpoint {
        id: value.get("id").and_then(Value::as_i64).unwrap_or(0),
        verified: value
            .get("verified")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        message: string_field(value, "message"),
        function_name: function_name.map(str::to_string),
        data_id: None,
        source_path: value
            .get("source")
            .and_then(|source| source.get("path"))
            .and_then(Value::as_str)
            .or(source_path)
            .map(str::to_string),
        line: value
            .get("line")
            .and_then(Value::as_i64)
            .or((fallback_line > 0).then_some(fallback_line)),
        column: value.get("column").and_then(Value::as_i64),
    }
}

fn parse_capabilities(value: &Value) -> DebugCapabilities {
    DebugCapabilities {
        supports_configuration_done: bool_field(value, "supportsConfigurationDoneRequest"),
        supports_conditional_breakpoints: bool_field(value, "supportsConditionalBreakpoints"),
        supports_hit_conditional_breakpoints: bool_field(
            value,
            "supportsHitConditionalBreakpoints",
        ),
        supports_log_points: bool_field(value, "supportsLogPoints"),
        supports_function_breakpoints: bool_field(value, "supportsFunctionBreakpoints"),
        supports_data_breakpoints: bool_field(value, "supportsDataBreakpoints"),
        supports_exception_options: bool_field(value, "supportsExceptionOptions"),
        supports_exception_filter_options: bool_field(value, "supportsExceptionFilterOptions"),
        supports_set_variable: bool_field(value, "supportsSetVariable"),
        supports_cancel_request: bool_field(value, "supportsCancelRequest"),
        supports_single_thread_execution_requests: bool_field(
            value,
            "supportsSingleThreadExecutionRequests",
        ),
        supports_restart_request: bool_field(value, "supportsRestartRequest"),
        supports_terminate_request: bool_field(value, "supportsTerminateRequest"),
        supports_step_back: bool_field(value, "supportsStepBack"),
        supports_exception_info_request: bool_field(value, "supportsExceptionInfoRequest"),
        supports_step_in_targets_request: bool_field(value, "supportsStepInTargetsRequest"),
        supports_goto_targets_request: bool_field(value, "supportsGotoTargetsRequest"),
        exception_breakpoint_filters: value
            .get("exceptionBreakpointFilters")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(parse_exception_breakpoint_filter)
            .collect(),
    }
}

fn parse_exception_breakpoint_filter(value: &Value) -> Option<DebugExceptionBreakpointFilter> {
    let filter = value.get("filter")?.as_str()?.trim();
    let label = value.get("label")?.as_str()?.trim();
    if filter.is_empty() || label.is_empty() {
        return None;
    }
    Some(DebugExceptionBreakpointFilter {
        filter: filter.to_string(),
        label: label.to_string(),
        description: string_field(value, "description"),
        default: bool_field(value, "default"),
        supports_condition: bool_field(value, "supportsCondition"),
        condition_description: string_field(value, "conditionDescription"),
    })
}

fn with_session<T>(
    session_id: &str,
    operation: impl FnOnce(&mut DebugSession) -> Result<T, CoreError>,
) -> Result<T, CoreError> {
    let mut sessions = sessions_lock()?;
    let session = sessions
        .get_mut(session_id)
        .ok_or_else(|| session_not_found(session_id))?;
    operation(session)
}

fn sessions_lock(
) -> Result<std::sync::MutexGuard<'static, HashMap<String, DebugSession>>, CoreError> {
    SESSIONS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Debug session state is unavailable."))
}

fn parse_run_in_terminal_request(value: &Value) -> Result<DebugRunInTerminalRequest, CoreError> {
    const MAX_ARGUMENT_COUNT: usize = 4_096;
    const MAX_ENVIRONMENT_COUNT: usize = 4_096;

    let object = value
        .as_object()
        .ok_or_else(|| invalid_request("Debug runInTerminal arguments must be a JSON object."))?;
    let kind = match object.get("kind") {
        None => DebugRunInTerminalKind::Integrated,
        Some(Value::String(value)) if value == "integrated" => DebugRunInTerminalKind::Integrated,
        Some(Value::String(value)) if value == "external" => DebugRunInTerminalKind::External,
        _ => {
            return Err(invalid_request(
                "Debug runInTerminal kind must be integrated or external.",
            ))
        }
    };
    let title = match object.get("title") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => normalize_optional_text(Some(value.clone())),
        _ => {
            return Err(invalid_request(
                "Debug runInTerminal title must be a string.",
            ))
        }
    };
    let cwd = object
        .get("cwd")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_request("Debug runInTerminal cwd must be a string."))?
        .to_string();
    if cwd.contains('\0') {
        return Err(invalid_request(
            "Debug runInTerminal cwd contains an invalid null byte.",
        ));
    }
    let argument_values = object
        .get("args")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_request("Debug runInTerminal args must be an array."))?;
    if argument_values.is_empty() || argument_values.len() > MAX_ARGUMENT_COUNT {
        return Err(invalid_request(
            "Debug runInTerminal args must contain between 1 and 4096 items.",
        ));
    }
    let mut args = Vec::with_capacity(argument_values.len());
    for value in argument_values {
        let argument = value.as_str().ok_or_else(|| {
            invalid_request("Debug runInTerminal args must contain only strings.")
        })?;
        if argument.contains('\0') {
            return Err(invalid_request(
                "Debug runInTerminal args contain an invalid null byte.",
            ));
        }
        args.push(argument.to_string());
    }
    if args[0].trim().is_empty() {
        return Err(invalid_request(
            "Debug runInTerminal args must begin with an executable.",
        ));
    }

    let mut environment = Vec::new();
    if let Some(value) = object.get("env") {
        let values = value
            .as_object()
            .ok_or_else(|| invalid_request("Debug runInTerminal env must be a JSON object."))?;
        if values.len() > MAX_ENVIRONMENT_COUNT {
            return Err(invalid_request(
                "Debug runInTerminal env cannot exceed 4096 entries.",
            ));
        }
        let mut names: Vec<&String> = values.keys().collect();
        names.sort();
        for name in names {
            if name.is_empty() || name.contains(['=', '\0']) {
                return Err(invalid_request(
                    "Debug runInTerminal env contains an invalid variable name.",
                ));
            }
            let value = match &values[name] {
                Value::Null => None,
                Value::String(value) if !value.contains('\0') => Some(value.clone()),
                _ => {
                    return Err(invalid_request(
                        "Debug runInTerminal env values must be strings or null.",
                    ))
                }
            };
            environment.push(DebugRunInTerminalEnvironmentVariable {
                name: name.clone(),
                value,
            });
        }
    }
    let args_can_be_interpreted_by_shell = match object.get("argsCanBeInterpretedByShell") {
        None => false,
        Some(Value::Bool(value)) => *value,
        _ => {
            return Err(invalid_request(
                "Debug runInTerminal argsCanBeInterpretedByShell must be a boolean.",
            ))
        }
    };

    Ok(DebugRunInTerminalRequest {
        kind,
        title,
        cwd,
        args,
        environment,
        args_can_be_interpreted_by_shell,
    })
}

fn validate_dap_process_id(value: Option<i64>, field: &str) -> Result<(), CoreError> {
    if value.is_some_and(|value| !(1..=i32::MAX as i64).contains(&value)) {
        return Err(invalid_request(&format!(
            "Debug runInTerminal {field} must be between 1 and {}.",
            i32::MAX
        )));
    }
    Ok(())
}

fn validate_identifier(value: &str, field: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() || value.contains('\0') || value.len() > 512 {
        return Err(invalid_request(&format!("Debug {field} was invalid.")));
    }
    Ok(())
}

fn validate_path(value: &str, field: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() || value.contains('\0') {
        return Err(invalid_request(&format!("Debug {field} was invalid.")));
    }
    Ok(())
}

fn required_positive(value: Option<i64>, field: &str) -> Result<i64, CoreError> {
    value
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid_request(&format!("Debug {field} must be positive.")))
}

fn required_nonnegative(value: Option<i64>, field: &str) -> Result<i64, CoreError> {
    value
        .filter(|value| *value >= 0)
        .ok_or_else(|| invalid_request(&format!("Debug {field} cannot be negative.")))
}

fn required_str<'a>(value: &'a Value, field: &str) -> Result<&'a str, CoreError> {
    value.get(field).and_then(Value::as_str).ok_or_else(|| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("DAP message did not contain a valid {field}."),
        )
    })
}

fn required_i64(value: &Value, field: &str) -> Result<i64, CoreError> {
    value.get(field).and_then(Value::as_i64).ok_or_else(|| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("DAP message did not contain a valid {field}."),
        )
    })
}

fn required_array<'a>(value: &'a Value, field: &str) -> Result<&'a Vec<Value>, CoreError> {
    value.get(field).and_then(Value::as_array).ok_or_else(|| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("DAP response did not contain a valid {field} array."),
        )
    })
}

fn string_field(value: &Value, field: &str) -> Option<String> {
    value.get(field).and_then(Value::as_str).map(str::to_string)
}

fn bool_field(value: &Value, field: &str) -> bool {
    value.get(field).and_then(Value::as_bool).unwrap_or(false)
}

fn insert_option<T: serde::Serialize>(map: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        map.insert(key.to_string(), json!(value));
    }
}

fn insert_nonempty(map: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|value| !value.is_empty()) {
        map.insert(key.to_string(), Value::String(value.to_string()));
    }
}

fn normalize_optional_text(value: Option<String>) -> Option<String> {
    value
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

fn invalid_request(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn session_not_found(session_id: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Debug session was not found.")
        .with_details(session_id.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request_message(sequence: i64, command: &str, arguments: Value) -> Value {
        json!({
            "seq": sequence,
            "type": "request",
            "command": command,
            "arguments": arguments
        })
    }

    fn response_message(request_sequence: i64, command: &str, body: Value) -> Value {
        json!({
            "seq": 100 + request_sequence,
            "type": "response",
            "request_seq": request_sequence,
            "success": true,
            "command": command,
            "body": body
        })
    }

    fn receive_messages(session_id: &str, messages: Vec<Value>) -> DebugSessionUpdate {
        let bytes = messages
            .into_iter()
            .flat_map(|message| frame_message(&message).unwrap())
            .collect::<Vec<_>>();
        receive(ReceiveRequest {
            session_id: session_id.to_string(),
            data_base64: BASE64.encode(bytes),
        })
        .unwrap()
    }

    fn decode_frame(frame: &str) -> Value {
        let bytes = BASE64.decode(frame).unwrap();
        let body_start = bytes
            .windows(4)
            .position(|value| value == b"\r\n\r\n")
            .unwrap()
            + 4;
        serde_json::from_slice(&bytes[body_start..]).unwrap()
    }

    #[test]
    fn debug_update_serializes_variant_fields_with_contract_casing() {
        let update = DebugSessionUpdate {
            session_id: "debug-contract-casing".to_string(),
            state: DebugSessionState::Paused,
            outbound_frames: Vec::new(),
            events: vec![
                DebugEvent {
                    sequence: 1,
                    body: DebugEventBody::Stopped {
                        reason: "breakpoint".to_string(),
                        thread_id: Some(13),
                        description: None,
                    },
                },
                DebugEvent {
                    sequence: 2,
                    body: DebugEventBody::OperationCompleted {
                        operation_id: "stack-1".to_string(),
                        result: DebugOperationResult::StackTrace {
                            stack_frames: vec![DebugStackFrame {
                                id: 7,
                                name: "example.Main.run".to_string(),
                                source_path: Some("/workspace/Main.java".to_string()),
                                line: 12,
                                column: 1,
                                is_filtered: false,
                            }],
                        },
                    },
                },
            ],
        };

        let value = serde_json::to_value(update).unwrap();
        assert_eq!(value["events"][0]["threadId"], 13);
        assert!(value["events"][0].get("thread_id").is_none());
        assert_eq!(value["events"][1]["operationId"], "stack-1");
        assert!(value["events"][1].get("operation_id").is_none());
        assert_eq!(value["events"][1]["result"]["kind"], "stackTrace");
        assert_eq!(value["events"][1]["result"]["stackFrames"][0]["id"], 7);
        assert_eq!(
            value["events"][1]["result"]["stackFrames"][0]["isFiltered"],
            false
        );
        assert!(value["events"][1]["result"].get("stack_frames").is_none());
    }

    #[test]
    fn disconnect_policy_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/debug/disconnect-policy-v1.json"
        )))
        .unwrap();

        for case in fixture["cases"].as_array().unwrap() {
            let request_name = case["request"].as_str().unwrap_or("unstarted");
            let session_id = format!("debug-disconnect-{request_name}");
            create_session(CreateSessionRequest {
                session_id: session_id.clone(),
                adapter_id: "java".to_string(),
                root_path: "/workspace".to_string(),
                supports_run_in_terminal_request: false,
            })
            .unwrap();

            if case["request"].is_string() {
                let request_kind = serde_json::from_value(case["request"].clone()).unwrap();
                launch(LaunchRequest {
                    session_id: session_id.clone(),
                    operation_id: format!("{request_name}-main"),
                    configuration: DebugLaunchConfiguration {
                        name: "Main".to_string(),
                        request: request_kind,
                        arguments: Map::new(),
                        stepping_filters: None,
                    },
                })
                .unwrap();
                let initialized = receive_messages(
                    &session_id,
                    vec![response_message(1, "initialize", json!({}))],
                );
                assert_eq!(
                    decode_frame(&initialized.outbound_frames[0])["command"],
                    request_name
                );
            }

            let disconnected = disconnect(SessionRequest {
                session_id: session_id.clone(),
            })
            .unwrap();
            let request = decode_frame(&disconnected.outbound_frames[0]);
            assert_eq!(request["command"], "disconnect");
            assert_eq!(request["arguments"], case["expectedArguments"]);
            destroy_session(SessionRequest { session_id }).unwrap();
        }
    }

    #[test]
    fn variable_paging_arguments_reject_invalid_combinations() {
        let base = InspectRequest {
            session_id: "debug-variable-validation".to_string(),
            operation_id: "variables".to_string(),
            kind: DebugInspectKind::Variables,
            thread_id: None,
            frame_id: None,
            variables_reference: Some(700),
            variable_filter: Some(DebugVariableFilter::Indexed),
            start: Some(0),
            count: Some(100),
            expression: None,
            source_path: None,
            line: None,
            column: None,
        };

        let mut negative_start = base.clone();
        negative_start.start = Some(-1);
        let error = inspect_arguments(&negative_start).unwrap_err();
        assert!(matches!(error.code, ErrorCode::InvalidRequest));

        let mut zero_count = base.clone();
        zero_count.count = Some(0);
        let error = inspect_arguments(&zero_count).unwrap_err();
        assert!(matches!(error.code, ErrorCode::InvalidRequest));

        let mut non_variable_request = base;
        non_variable_request.kind = DebugInspectKind::Threads;
        non_variable_request.variables_reference = None;
        non_variable_request.start = None;
        non_variable_request.count = None;
        let error = inspect_arguments(&non_variable_request).unwrap_err();
        assert!(matches!(error.code, ErrorCode::InvalidRequest));
    }

    #[test]
    fn variable_child_counts_are_normalized_for_scopes_and_evaluation() {
        let scopes = normalize_inspection(
            DebugInspectKind::Scopes,
            &json!({
                "scopes": [{
                    "name": "Locals",
                    "variablesReference": 700,
                    "expensive": false,
                    "namedVariables": -2,
                    "indexedVariables": 250
                }]
            }),
            &DebugSteppingFilters::default(),
            "/workspace",
        )
        .unwrap();
        let scopes = serde_json::to_value(scopes).unwrap();
        assert_eq!(scopes["scopes"][0]["namedVariables"], 0);
        assert_eq!(scopes["scopes"][0]["indexedVariables"], 250);

        let evaluation = normalize_inspection(
            DebugInspectKind::Evaluate,
            &json!({
                "result": "Customer[250]",
                "variablesReference": 701,
                "namedVariables": 4,
                "indexedVariables": -1
            }),
            &DebugSteppingFilters::default(),
            "/workspace",
        )
        .unwrap();
        let evaluation = serde_json::to_value(evaluation).unwrap();
        assert_eq!(evaluation["variable"]["namedVariables"], 4);
        assert_eq!(evaluation["variable"]["indexedVariables"], 0);
    }

    #[test]
    fn java_stepping_filters_are_normalized_projected_and_mark_stack_frames() {
        let defaults = stepping_filters(DebugSteppingFiltersRequest {
            adapter_id: "java".to_string(),
            filters: None,
        })
        .unwrap();
        assert!(defaults.class_name_filters.contains(&"$JDK".to_string()));
        assert!(defaults.skip_synthetics);
        assert!(!defaults.skip_constructors);

        let filters = stepping_filters(DebugSteppingFiltersRequest {
            adapter_id: "java".to_string(),
            filters: Some(DebugSteppingFilters {
                class_name_filters: vec![
                    " org.mockito.* ".to_string(),
                    "$JDK".to_string(),
                    "org.mockito.*".to_string(),
                    String::new(),
                ],
                skip_synthetics: true,
                skip_static_initializers: false,
                skip_constructors: true,
                hide_filtered_stack_frames: true,
            }),
        })
        .unwrap();
        assert_eq!(filters.class_name_filters, ["$JDK", "org.mockito.*"]);

        let multiline_error = stepping_filters(DebugSteppingFiltersRequest {
            adapter_id: "java".to_string(),
            filters: Some(DebugSteppingFilters {
                class_name_filters: vec!["example.Valid\nexample.Invalid".to_string()],
                skip_synthetics: false,
                skip_static_initializers: false,
                skip_constructors: false,
                hide_filtered_stack_frames: false,
            }),
        })
        .unwrap_err();
        assert!(matches!(multiline_error.code, ErrorCode::InvalidRequest));

        let excessive_filter_error = stepping_filters(DebugSteppingFiltersRequest {
            adapter_id: "java".to_string(),
            filters: Some(DebugSteppingFilters {
                class_name_filters: (0..257)
                    .map(|index| format!("example.Type{index}"))
                    .collect(),
                skip_synthetics: false,
                skip_static_initializers: false,
                skip_constructors: false,
                hide_filtered_stack_frames: false,
            }),
        })
        .unwrap_err();
        assert!(matches!(
            excessive_filter_error.code,
            ErrorCode::InvalidRequest
        ));

        let session_id = "debug-java-stepping-filters";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: Some(filters),
            },
        })
        .unwrap();
        let initialized = receive_messages(
            session_id,
            vec![response_message(1, "initialize", json!({}))],
        );
        let launch_request = decode_frame(&initialized.outbound_frames[0]);
        assert_eq!(launch_request["command"], "launch");
        assert_eq!(
            launch_request["arguments"]["stepFilters"]["skipClasses"],
            json!(["$JDK", "org.mockito.*"])
        );
        assert_eq!(
            launch_request["arguments"]["stepFilters"]["skipConstructors"],
            true
        );
        receive_messages(
            session_id,
            vec![
                response_message(2, "launch", json!({})),
                json!({
                    "seq": 103,
                    "type": "event",
                    "event": "stopped",
                    "body": {"reason": "breakpoint", "threadId": 11}
                }),
            ],
        );
        inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: "stack".to_string(),
            kind: DebugInspectKind::StackTrace,
            thread_id: Some(11),
            frame_id: None,
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap();
        let stack = receive_messages(
            session_id,
            vec![response_message(
                3,
                "stackTrace",
                json!({"stackFrames": [
                    {
                        "id": 7,
                        "name": "Method.invoke(Object,Object[])",
                        "source": {
                            "path": "jdt://contents/java.base/java/lang/reflect/Method.class"
                        },
                        "line": 1,
                        "column": 1
                    },
                    {
                        "id": 8,
                        "name": "MockMethodInterceptor.intercept(Object,Method,Object[],Invoker)",
                        "source": {
                            "path": "jdt://contents/mockito-core/org/mockito/internal/creation/bytebuddy/MockMethodInterceptor.class"
                        },
                        "line": 1,
                        "column": 1
                    },
                    {
                        "id": 9,
                        "name": "example.LoginService.authenticate",
                        "source": {"path": "/workspace/LoginService.java"},
                        "line": 24,
                        "column": 5
                    }
                ]}),
            )],
        );
        assert!(stack.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted {
                operation_id,
                result: DebugOperationResult::StackTrace { stack_frames }
            } if operation_id == "stack"
                && stack_frames.len() == 3
                && stack_frames[0].is_filtered
                && stack_frames[1].is_filtered
                && !stack_frames[2].is_filtered
        )));
        let library_filters = DebugSteppingFilters {
            class_name_filters: vec!["$Libraries".to_string()],
            skip_synthetics: false,
            skip_static_initializers: false,
            skip_constructors: false,
            hide_filtered_stack_frames: true,
        };
        assert!(stack_frame_matches_filters(
            "Dependency.call()",
            Some("/dependencies/example/Dependency.java"),
            None,
            &library_filters,
            "/workspace"
        ));
        assert!(!stack_frame_matches_filters(
            "LoginService.authenticate()",
            Some("/workspace/LoginService.java"),
            None,
            &library_filters,
            "/workspace"
        ));
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn initialize_launch_breakpoints_and_inspection_are_reduced_in_order() {
        let session_id = "debug-engine-flow";
        let created = create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        assert_eq!(created.state, DebugSessionState::Initializing);
        assert_eq!(
            decode_frame(&created.outbound_frames[0])["command"],
            "initialize"
        );

        let queued = launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch-1".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::from_iter([("mainClass".to_string(), json!("example.Main"))]),
                stepping_filters: None,
            },
        })
        .unwrap();
        assert!(queued.outbound_frames.is_empty());
        set_breakpoints(SetBreakpointsRequest {
            session_id: session_id.to_string(),
            source_path: "/workspace/src/Main.java".to_string(),
            breakpoints: vec![
                SourceBreakpoint {
                    line: 12,
                    column: None,
                    enabled: true,
                    condition: Some("value > 1".to_string()),
                    hit_condition: Some("3".to_string()),
                    log_message: Some("value = {value}".to_string()),
                },
                SourceBreakpoint {
                    line: 14,
                    column: None,
                    enabled: false,
                    condition: None,
                    hit_condition: None,
                    log_message: None,
                },
            ],
        })
        .unwrap();
        set_exception_breakpoints(SetExceptionBreakpointsRequest {
            session_id: session_id.to_string(),
            breakpoints: vec![
                ExceptionBreakpoint {
                    filter: "uncaught".to_string(),
                    enabled: false,
                    condition: None,
                },
                ExceptionBreakpoint {
                    filter: "caught".to_string(),
                    enabled: true,
                    condition: Some(" example.CustomException ".to_string()),
                },
            ],
        })
        .unwrap();
        set_function_breakpoints(SetFunctionBreakpointsRequest {
            session_id: session_id.to_string(),
            breakpoints: vec![
                FunctionBreakpoint {
                    name: " example.Main.run ".to_string(),
                    enabled: true,
                    condition: Some("ready".to_string()),
                    hit_condition: Some("2".to_string()),
                },
                FunctionBreakpoint {
                    name: "example.Main.skip".to_string(),
                    enabled: false,
                    condition: None,
                    hit_condition: None,
                },
            ],
        })
        .unwrap();

        let initialized = receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({
                    "supportsConfigurationDoneRequest": true,
                    "supportsConditionalBreakpoints": true,
                    "supportsHitConditionalBreakpoints": true,
                    "supportsLogPoints": true,
                    "supportsFunctionBreakpoints": true,
                    "supportsDataBreakpoints": true,
                    "supportsSetVariable": true,
                    "supportsRestartRequest": true,
                    "supportsExceptionFilterOptions": true,
                    "exceptionBreakpointFilters": [{
                        "filter": "caught",
                        "label": "Caught Exceptions",
                        "default": false,
                        "supportsCondition": true
                    }]
                }),
            )],
        );
        assert_eq!(initialized.state, DebugSessionState::Launching);
        assert!(initialized.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::Capabilities { capabilities }
                if capabilities.supports_conditional_breakpoints
                    && capabilities.supports_hit_conditional_breakpoints
                    && capabilities.supports_log_points
                    && capabilities.supports_function_breakpoints
                    && capabilities.supports_data_breakpoints
                    && capabilities.supports_set_variable
                    && capabilities.supports_restart_request
                    && capabilities.exception_breakpoint_filters.len() == 1
        )));
        assert_eq!(
            decode_frame(&initialized.outbound_frames[0])["command"],
            "launch"
        );

        let configured = receive_messages(
            session_id,
            vec![json!({"seq": 102, "type": "event", "event": "initialized"})],
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[0])["command"],
            "setExceptionBreakpoints"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[1])["command"],
            "setFunctionBreakpoints"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[2])["command"],
            "setDataBreakpoints"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[3])["command"],
            "setBreakpoints"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[4])["command"],
            "configurationDone"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[0])["arguments"]["filters"],
            json!(["caught"])
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[0])["arguments"]["filterOptions"][0]
                ["condition"],
            "example.CustomException"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[1])["arguments"]["breakpoints"][0]["name"],
            "example.Main.run"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[1])["arguments"]["breakpoints"][0]
                ["condition"],
            "ready"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[1])["arguments"]["breakpoints"][0]
                ["hitCondition"],
            "2"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[1])["arguments"]["breakpoints"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[3])["arguments"]["breakpoints"][0]
                ["condition"],
            "value > 1"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[3])["arguments"]["breakpoints"][0]
                ["hitCondition"],
            "3"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[3])["arguments"]["breakpoints"][0]
                ["logMessage"],
            "value = {value}"
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[3])["arguments"]["breakpoints"]
                .as_array()
                .unwrap()
                .len(),
            1
        );

        let running = receive_messages(
            session_id,
            vec![
                response_message(2, "launch", json!({})),
                response_message(3, "setExceptionBreakpoints", json!({})),
                response_message(
                    4,
                    "setFunctionBreakpoints",
                    json!({"breakpoints": [{"id": 8, "verified": true}]}),
                ),
                response_message(5, "setDataBreakpoints", json!({"breakpoints": []})),
                response_message(
                    6,
                    "setBreakpoints",
                    json!({"breakpoints": [{"id": 7, "verified": true, "line": 12}]}),
                ),
                response_message(7, "configurationDone", json!({})),
            ],
        );
        assert_eq!(running.state, DebugSessionState::Running);
        assert!(running
            .events
            .iter()
            .any(|event| matches!(event.body, DebugEventBody::Breakpoint { .. })));
        assert!(running.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::Breakpoint { breakpoint }
                if breakpoint.function_name.as_deref() == Some("example.Main.run")
                    && breakpoint.verified
        )));

        let inspection = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: "threads-1".to_string(),
            kind: DebugInspectKind::Threads,
            thread_id: None,
            frame_id: None,
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap();
        assert_eq!(
            decode_frame(&inspection.outbound_frames[0])["command"],
            "threads"
        );
        let completed = receive_messages(
            session_id,
            vec![response_message(
                8,
                "threads",
                json!({"threads": [{"id": 1, "name": "main"}]}),
            )],
        );
        assert!(completed.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted { operation_id, result: DebugOperationResult::Threads { threads } }
                if operation_id == "threads-1" && threads.len() == 1
        )));

        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn data_breakpoint_identity_and_verification_are_correlated() {
        let session_id = "debug-data-breakpoint";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        set_data_breakpoints(SetDataBreakpointsRequest {
            session_id: session_id.to_string(),
            breakpoints: vec![
                DataBreakpoint {
                    data_id: " field:count ".to_string(),
                    label: Some("count".to_string()),
                    enabled: true,
                    access_type: Some(" write ".to_string()),
                    condition: Some(" count > 1 ".to_string()),
                    hit_condition: Some(" 2 ".to_string()),
                },
                DataBreakpoint {
                    data_id: "field:ignored".to_string(),
                    label: None,
                    enabled: false,
                    access_type: None,
                    condition: None,
                    hit_condition: None,
                },
            ],
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({"supportsDataBreakpoints": true}),
            )],
        );
        let configured = receive_messages(
            session_id,
            vec![json!({"seq": 102, "type": "event", "event": "initialized"})],
        );
        assert_eq!(
            decode_frame(&configured.outbound_frames[1])["command"],
            "setDataBreakpoints"
        );
        let arguments = &decode_frame(&configured.outbound_frames[1])["arguments"]["breakpoints"];
        assert_eq!(arguments.as_array().unwrap().len(), 1);
        assert_eq!(arguments[0]["dataId"], "field:count");
        assert_eq!(arguments[0]["accessType"], "write");
        assert_eq!(arguments[0]["condition"], "count > 1");
        assert_eq!(arguments[0]["hitCondition"], "2");

        let verified = receive_messages(
            session_id,
            vec![
                response_message(2, "setExceptionBreakpoints", json!({})),
                response_message(
                    3,
                    "setDataBreakpoints",
                    json!({"breakpoints": [{"id": 9, "verified": true}]}),
                ),
            ],
        );
        assert!(verified.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::Breakpoint { breakpoint }
                if breakpoint.data_id.as_deref() == Some("field:count")
                    && breakpoint.verified
        )));

        let info = data_breakpoint_info(DataBreakpointInfoRequest {
            session_id: session_id.to_string(),
            operation_id: "field-info".to_string(),
            name: " count ".to_string(),
            variables_reference: Some(42),
            frame_id: Some(7),
        })
        .unwrap();
        let request = decode_frame(&info.outbound_frames[0]);
        assert_eq!(request["command"], "dataBreakpointInfo");
        assert_eq!(request["arguments"]["name"], "count");
        assert_eq!(request["arguments"]["variablesReference"], 42);
        assert_eq!(request["arguments"]["frameId"], 7);
        let completed = receive_messages(
            session_id,
            vec![response_message(
                4,
                "dataBreakpointInfo",
                json!({
                    "dataId": "field:count",
                    "description": "Main.count",
                    "accessTypes": ["read", "write"],
                    "canPersist": true
                }),
            )],
        );
        assert!(completed.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted {
                operation_id,
                result: DebugOperationResult::DataBreakpointInfo {
                    data_id,
                    description,
                    access_types,
                    can_persist
                }
            } if operation_id == "field-info"
                && data_id.as_deref() == Some("field:count")
                && description == "Main.count"
                && access_types == &["read", "write"]
                && *can_persist
        )));
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn variable_mutation_is_capability_gated_and_correlated() {
        let session_id = "debug-set-variable";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({"supportsSetVariable": true}),
            )],
        );
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "breakpoint", "threadId": 11}
            })],
        );

        let update = set_variable(SetVariableRequest {
            session_id: session_id.to_string(),
            operation_id: "set-count".to_string(),
            variables_reference: 42,
            name: " count ".to_string(),
            value: "7".to_string(),
        })
        .unwrap();
        let request = decode_frame(&update.outbound_frames[0]);
        assert_eq!(request["command"], "setVariable");
        assert_eq!(request["arguments"]["variablesReference"], 42);
        assert_eq!(request["arguments"]["name"], "count");
        assert_eq!(request["arguments"]["value"], "7");

        let completed = receive_messages(
            session_id,
            vec![response_message(
                3,
                "setVariable",
                json!({
                    "value": "7",
                    "type": "int",
                    "variablesReference": 0,
                    "namedVariables": -1,
                    "indexedVariables": 2
                }),
            )],
        );
        assert!(completed.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted {
                operation_id,
                result: DebugOperationResult::SetVariable { variable }
            } if operation_id == "set-count"
                && variable.name == "count"
                && variable.value == "7"
                && variable.r#type.as_deref() == Some("int")
                && variable.named_variables == 0
                && variable.indexed_variables == 2
        )));
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn cancelled_operation_forwards_dap_cancel_and_ignores_late_response() {
        let session_id = "debug-cancel-operation";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({
                    "supportsCancelRequest": true,
                    "supportsSingleThreadExecutionRequests": true
                }),
            )],
        );
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "breakpoint", "threadId": 11}
            })],
        );
        let pending = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: "threads-timeout".to_string(),
            kind: DebugInspectKind::Threads,
            thread_id: None,
            frame_id: None,
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap();
        assert_eq!(decode_frame(&pending.outbound_frames[0])["seq"], 3);

        let cancelled = cancel_operation(CancelOperationRequest {
            session_id: session_id.to_string(),
            operation_id: "threads-timeout".to_string(),
            reason: DebugCancellationReason::TimedOut,
        })
        .unwrap();
        assert!(cancelled.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationFailed { operation_id, command, code, message }
                if operation_id == "threads-timeout"
                    && command == "threads"
                    && *code == DebugOperationFailureCode::TimedOut
                    && message == "Debug operation timed out."
        )));
        let cancel = decode_frame(&cancelled.outbound_frames[0]);
        assert_eq!(cancel["command"], "cancel");
        assert_eq!(cancel["arguments"]["requestId"], 3);

        let late = receive_messages(
            session_id,
            vec![
                response_message(3, "threads", json!({"threads": []})),
                response_message(4, "cancel", json!({})),
            ],
        );
        assert!(!late
            .events
            .iter()
            .any(|event| matches!(event.body, DebugEventBody::OperationCompleted { .. })));
        let resumed = execute(ExecuteRequest {
            session_id: session_id.to_string(),
            operation_id: "resume-main-thread".to_string(),
            command: DebugExecutionCommand::Continue,
            thread_id: Some(11),
            target_id: None,
            single_thread: true,
        })
        .unwrap();
        let resumed_request = decode_frame(&resumed.outbound_frames[0]);
        assert_eq!(resumed_request["command"], "continue");
        assert_eq!(resumed_request["arguments"]["threadId"], 11);
        assert_eq!(resumed_request["arguments"]["singleThread"], true);
        let resumed = receive_messages(
            session_id,
            vec![
                response_message(5, "continue", json!({})),
                json!({
                    "seq": 108,
                    "type": "event",
                    "event": "continued",
                    "body": {"threadId": 11, "allThreadsContinued": false}
                }),
            ],
        );
        assert_eq!(resumed.state, DebugSessionState::Paused);
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn advanced_execution_controls_are_capability_gated_and_correlated() {
        let session_id = "debug-advanced-control";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({
                    "supportsStepBack": true,
                    "supportsRestartRequest": true,
                    "supportsTerminateRequest": true
                }),
            )],
        );
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "breakpoint", "threadId": 11}
            })],
        );

        let step_back = execute(ExecuteRequest {
            session_id: session_id.to_string(),
            operation_id: "step-back".to_string(),
            command: DebugExecutionCommand::StepBack,
            thread_id: Some(11),
            target_id: None,
            single_thread: false,
        })
        .unwrap();
        let request = decode_frame(&step_back.outbound_frames[0]);
        assert_eq!(request["command"], "stepBack");
        assert_eq!(request["arguments"]["threadId"], 11);
        assert_eq!(request["arguments"]["singleThread"], false);
        let stepped =
            receive_messages(session_id, vec![response_message(3, "stepBack", json!({}))]);
        assert!(stepped.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted { operation_id, result: DebugOperationResult::Acknowledged { command } }
                if operation_id == "step-back" && command == "stepBack"
        )));

        let restart = execute(ExecuteRequest {
            session_id: session_id.to_string(),
            operation_id: "restart".to_string(),
            command: DebugExecutionCommand::Restart,
            thread_id: Some(11),
            target_id: None,
            single_thread: false,
        })
        .unwrap();
        let request = decode_frame(&restart.outbound_frames[0]);
        assert_eq!(request["command"], "restart");
        assert!(request["arguments"].get("threadId").is_none());
        receive_messages(session_id, vec![response_message(4, "restart", json!({}))]);

        let terminate = execute(ExecuteRequest {
            session_id: session_id.to_string(),
            operation_id: "terminate".to_string(),
            command: DebugExecutionCommand::Terminate,
            thread_id: Some(11),
            target_id: None,
            single_thread: false,
        })
        .unwrap();
        let request = decode_frame(&terminate.outbound_frames[0]);
        assert_eq!(request["command"], "terminate");
        assert!(request["arguments"].get("threadId").is_none());
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn smart_step_and_goto_targets_are_normalized_before_targeted_execution() {
        let session_id = "debug-targeted-control";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({
                    "supportsStepInTargetsRequest": true,
                    "supportsGotoTargetsRequest": true
                }),
            )],
        );
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "breakpoint", "threadId": 11}
            })],
        );

        let step_targets = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: "step-targets".to_string(),
            kind: DebugInspectKind::StepInTargets,
            thread_id: None,
            frame_id: Some(7),
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap();
        let request = decode_frame(&step_targets.outbound_frames[0]);
        assert_eq!(request["command"], "stepInTargets");
        assert_eq!(request["arguments"]["frameId"], 7);
        let step_targets = receive_messages(
            session_id,
            vec![response_message(
                3,
                "stepInTargets",
                json!({"targets": [{
                    "id": 21,
                    "label": "service.load()",
                    "line": 12,
                    "column": 9,
                    "endLine": 12,
                    "endColumn": 23
                }]}),
            )],
        );
        assert!(step_targets.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted {
                operation_id,
                result: DebugOperationResult::StepInTargets { targets }
            } if operation_id == "step-targets"
                && targets.first().map(|target| target.id) == Some(21)
        )));
        let targeted_step = execute(ExecuteRequest {
            session_id: session_id.to_string(),
            operation_id: "targeted-step".to_string(),
            command: DebugExecutionCommand::StepIn,
            thread_id: Some(11),
            target_id: Some(21),
            single_thread: false,
        })
        .unwrap();
        assert_eq!(
            decode_frame(&targeted_step.outbound_frames[0])["arguments"]["targetId"],
            21
        );
        receive_messages(session_id, vec![response_message(4, "stepIn", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 105,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "step", "threadId": 11}
            })],
        );

        let goto_targets = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: "goto-targets".to_string(),
            kind: DebugInspectKind::GotoTargets,
            thread_id: None,
            frame_id: None,
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: Some("/workspace/src/Main.java".to_string()),
            line: Some(20),
            column: Some(5),
        })
        .unwrap();
        let request = decode_frame(&goto_targets.outbound_frames[0]);
        assert_eq!(request["command"], "gotoTargets");
        assert_eq!(
            request["arguments"]["source"]["path"],
            "/workspace/src/Main.java"
        );
        assert_eq!(request["arguments"]["line"], 20);
        let goto_targets = receive_messages(
            session_id,
            vec![response_message(
                5,
                "gotoTargets",
                json!({"targets": [{"id": 31, "label": "Main.java:20", "line": 20}]}),
            )],
        );
        assert!(goto_targets.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::OperationCompleted {
                operation_id,
                result: DebugOperationResult::GotoTargets { targets }
            } if operation_id == "goto-targets"
                && targets.first().map(|target| target.id) == Some(31)
        )));
        let goto = execute(ExecuteRequest {
            session_id: session_id.to_string(),
            operation_id: "goto".to_string(),
            command: DebugExecutionCommand::Goto,
            thread_id: Some(11),
            target_id: Some(31),
            single_thread: false,
        })
        .unwrap();
        let request = decode_frame(&goto.outbound_frames[0]);
        assert_eq!(request["command"], "goto");
        assert_eq!(request["arguments"]["targetId"], 31);
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn exception_information_is_capability_gated_and_normalized() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/debug/exception-info-v1.json"
        )))
        .unwrap();
        let session_id = "debug-exception-info";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        let initialized = receive_messages(
            session_id,
            vec![response_message(
                1,
                "initialize",
                json!({"supportsExceptionInfoRequest": true}),
            )],
        );
        assert!(initialized.events.iter().any(|event| matches!(
            &event.body,
            DebugEventBody::Capabilities { capabilities }
                if capabilities.supports_exception_info_request
        )));
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "exception", "threadId": fixture["request"]["threadId"]}
            })],
        );

        let inspection = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: fixture["request"]["operationId"]
                .as_str()
                .unwrap()
                .to_string(),
            kind: DebugInspectKind::ExceptionInfo,
            thread_id: fixture["request"]["threadId"].as_i64(),
            frame_id: None,
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap();
        let request = decode_frame(&inspection.outbound_frames[0]);
        assert_eq!(request["command"], "exceptionInfo");
        assert_eq!(
            request["arguments"]["threadId"],
            fixture["request"]["threadId"]
        );

        let completed = receive_messages(
            session_id,
            vec![response_message(
                3,
                "exceptionInfo",
                fixture["adapterResponse"].clone(),
            )],
        );
        let result = completed.events.iter().find_map(|event| match &event.body {
            DebugEventBody::OperationCompleted {
                operation_id,
                result,
            } if operation_id == fixture["request"]["operationId"].as_str().unwrap() => {
                Some(result)
            }
            _ => None,
        });
        assert_eq!(
            serde_json::to_value(result.unwrap()).unwrap(),
            fixture["expected"]
        );
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn variable_paging_is_forwarded_and_normalized_from_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/debug/variable-paging-v1.json"
        )))
        .unwrap();
        let session_id = "debug-variable-paging";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(1, "initialize", json!({}))],
        );
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "breakpoint", "threadId": 11}
            })],
        );

        let inspection = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: fixture["request"]["operationId"]
                .as_str()
                .unwrap()
                .to_string(),
            kind: DebugInspectKind::Variables,
            thread_id: None,
            frame_id: None,
            variables_reference: fixture["request"]["variablesReference"].as_i64(),
            variable_filter: serde_json::from_value(fixture["request"]["variableFilter"].clone())
                .unwrap(),
            start: fixture["request"]["start"].as_i64(),
            count: fixture["request"]["count"].as_i64(),
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap();
        let request = decode_frame(&inspection.outbound_frames[0]);
        assert_eq!(request["command"], "variables");
        assert_eq!(request["arguments"]["variablesReference"], 700);
        assert_eq!(request["arguments"]["filter"], "indexed");
        assert_eq!(request["arguments"]["start"], 100);
        assert_eq!(request["arguments"]["count"], 2);

        let completed = receive_messages(
            session_id,
            vec![response_message(
                3,
                "variables",
                fixture["adapterResponse"].clone(),
            )],
        );
        let result = completed.events.iter().find_map(|event| match &event.body {
            DebugEventBody::OperationCompleted {
                operation_id,
                result,
            } if operation_id == fixture["request"]["operationId"].as_str().unwrap() => {
                Some(result)
            }
            _ => None,
        });
        assert_eq!(
            serde_json::to_value(result.unwrap()).unwrap(),
            fixture["expected"]
        );
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn exception_information_is_rejected_when_the_adapter_does_not_support_it() {
        let session_id = "debug-exception-info-unsupported";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();
        launch(LaunchRequest {
            session_id: session_id.to_string(),
            operation_id: "launch".to_string(),
            configuration: DebugLaunchConfiguration {
                name: "Main".to_string(),
                request: DebugRequestKind::Launch,
                arguments: Map::new(),
                stepping_filters: None,
            },
        })
        .unwrap();
        receive_messages(
            session_id,
            vec![response_message(1, "initialize", json!({}))],
        );
        receive_messages(session_id, vec![response_message(2, "launch", json!({}))]);
        receive_messages(
            session_id,
            vec![json!({
                "seq": 103,
                "type": "event",
                "event": "stopped",
                "body": {"reason": "exception", "threadId": 13}
            })],
        );

        let error = inspect(InspectRequest {
            session_id: session_id.to_string(),
            operation_id: "exception-main".to_string(),
            kind: DebugInspectKind::ExceptionInfo,
            thread_id: Some(13),
            frame_id: None,
            variables_reference: None,
            variable_filter: None,
            start: None,
            count: None,
            expression: None,
            source_path: None,
            line: None,
            column: None,
        })
        .unwrap_err();
        assert!(matches!(error.code, ErrorCode::InvalidRequest));
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn run_in_terminal_request_is_normalized_completed_and_stale_safe() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/debug/run-in-terminal-v1.json"
        )))
        .unwrap();
        let session_id = "debug-run-in-terminal";
        let created = create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: true,
        })
        .unwrap();
        assert_eq!(
            decode_frame(&created.outbound_frames[0])["arguments"]["supportsRunInTerminalRequest"],
            true
        );

        let requested = receive_messages(session_id, vec![fixture["adapterRequest"].clone()]);
        assert!(requested.outbound_frames.is_empty());
        let request_id = requested
            .events
            .iter()
            .find_map(|event| match &event.body {
                DebugEventBody::RunInTerminalRequested {
                    request_id,
                    request,
                } => {
                    assert_eq!(
                        serde_json::to_value(request).unwrap(),
                        fixture["expectedRequest"]
                    );
                    Some(request_id.clone())
                }
                _ => None,
            })
            .unwrap();

        let duplicate = receive_messages(session_id, vec![fixture["adapterRequest"].clone()]);
        assert!(duplicate.outbound_frames.is_empty());
        assert!(duplicate.events.is_empty());

        let invalid = run_in_terminal_response(DebugRunInTerminalResponseRequest {
            session_id: session_id.to_string(),
            request_id: request_id.clone(),
            success: true,
            process_id: Some(0),
            shell_process_id: None,
            message: None,
        })
        .unwrap_err();
        assert!(matches!(invalid.code, ErrorCode::InvalidRequest));

        let success = run_in_terminal_response(DebugRunInTerminalResponseRequest {
            session_id: session_id.to_string(),
            request_id: request_id.clone(),
            success: true,
            process_id: fixture["successResponse"]["processId"].as_i64(),
            shell_process_id: fixture["successResponse"]["shellProcessId"].as_i64(),
            message: None,
        })
        .unwrap();
        let response = decode_frame(&success.outbound_frames[0]);
        assert_eq!(response["request_seq"], fixture["adapterRequest"]["seq"]);
        assert_eq!(response["success"], true);
        assert_eq!(response["body"], fixture["expectedSuccessBody"]);

        let stale = run_in_terminal_response(DebugRunInTerminalResponseRequest {
            session_id: session_id.to_string(),
            request_id,
            success: false,
            process_id: None,
            shell_process_id: None,
            message: Some(fixture["failureMessage"].as_str().unwrap().to_string()),
        })
        .unwrap();
        assert!(stale.outbound_frames.is_empty());
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn malformed_run_in_terminal_request_gets_an_explicit_failure_response() {
        let session_id = "debug-run-in-terminal-invalid";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: true,
        })
        .unwrap();

        let update = receive_messages(
            session_id,
            vec![request_message(
                45,
                "runInTerminal",
                json!({"cwd": "/workspace", "args": []}),
            )],
        );

        let response = decode_frame(&update.outbound_frames[0]);
        assert_eq!(response["request_seq"], 45);
        assert_eq!(response["success"], false);
        assert!(response["message"]
            .as_str()
            .unwrap()
            .contains("between 1 and 4096"));
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }

    #[test]
    fn unknown_server_request_gets_an_explicit_failure_response() {
        let session_id = "debug-server-request";
        create_session(CreateSessionRequest {
            session_id: session_id.to_string(),
            adapter_id: "java".to_string(),
            root_path: "/workspace".to_string(),
            supports_run_in_terminal_request: false,
        })
        .unwrap();

        let update = receive_messages(
            session_id,
            vec![request_message(44, "runInTerminal", json!({}))],
        );

        let response = decode_frame(&update.outbound_frames[0]);
        assert_eq!(response["request_seq"], 44);
        assert_eq!(response["success"], false);
        destroy_session(SessionRequest {
            session_id: session_id.to_string(),
        })
        .unwrap();
    }
}
