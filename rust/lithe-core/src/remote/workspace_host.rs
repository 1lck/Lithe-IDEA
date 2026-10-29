//! Product access to the existing lightweight workspace host protocol.
//!
//! Streaming calls own their resource and subscription together. Cancellation,
//! failed creation, and caller disconnect all close the remote process tree;
//! ordinary host requests cannot create an unobserved streaming resource.

use super::sessions::{lookup, request_error};
use crate::git::execution_events;
use crate::protocol::{cancellation, CoreError, ErrorCode};
use lithe_remote::client::session::{ClientError, Event, RemoteSession};
use lithe_remote::protocol::methods;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const EVENT_POLL: Duration = Duration::from_millis(20);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
const EARLY_EVENT_LIMIT: usize = 8 * 1024 * 1024;

/// Waits for finite host work while preserving the owning Core cancellation.
pub(crate) fn request_cancellable(
    session: &RemoteSession,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, ClientError> {
    let pending = session.begin_request_value(method, params, timeout)?;
    loop {
        if cancellation::check().is_err() {
            return Err(ClientError::Protocol("Operation was cancelled".into()));
        }
        if let Some(value) = pending.poll(EVENT_POLL)? {
            return Ok(value);
        }
    }
}

/// One host operation. Parameters retain the versioned remote protocol shape.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    session_id: String,
    #[serde(default)]
    method: String,
    params: Value,
    /// Optional process runtime bound; cleanup remains owned after expiry.
    #[serde(default)]
    timeout_milliseconds: Option<u64>,
}

/// Forwards finite host operations and controls of already observed resources.
pub(crate) fn request(request: Request) -> Result<Value, CoreError> {
    if !allowed_method(&request.method) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "This host operation requires a resource owner",
        ));
    }
    cancellation::check()?;
    let connection = lookup(&request.session_id)?;
    let timeout = if request.method == methods::ENVIRONMENT_RESOLVE {
        // Interactive and non-interactive login probes each have a host deadline.
        Duration::from_secs(60)
    } else {
        REQUEST_TIMEOUT
    };
    let result = request_cancellable(
        &connection.session,
        &request.method,
        request.params,
        timeout,
    );
    cancellation::check()?;
    result.map_err(|error| request_error(&request.session_id, error))
}

fn allowed_method(method: &str) -> bool {
    matches!(
        method,
        methods::FS_STAT
            | methods::FS_READ_DIR
            | methods::FS_READ_FILE
            | methods::FS_WRITE_FILE
            | methods::FS_CREATE_DIR
            | methods::FS_REMOVE
            | methods::FS_RENAME
            | methods::FS_COPY
            | methods::FS_TRASH
            | methods::FS_REAL_PATH
            | methods::FS_SET_PERMISSIONS
            | methods::FS_VOLUME_INFO
            | methods::FS_TEMP_DIRECTORY
            | methods::FS_UPLOAD_START
            | methods::FS_UPLOAD_CHUNK
            | methods::FS_UPLOAD_COMMIT
            | methods::FS_UPLOAD_ABORT
            | methods::FS_CREATE_RUN_DIRECTORY
            | methods::FS_RELEASE_RUN_DIRECTORY
            | methods::ENVIRONMENT_RESOLVE
            | methods::PROCESS_WRITE_STDIN
            | methods::PROCESS_CLOSE_STDIN
            | methods::PROCESS_KILL
            | methods::TERMINAL_WRITE
            | methods::TERMINAL_RESIZE
            | methods::TERMINAL_CLOSE
            | methods::PORTS_LISTENING
    )
}

/// Starts a process with a subscription installed before any output can arrive.
pub(crate) fn run_process(request: Request) -> Result<Value, CoreError> {
    run_resource(request, "process", methods::PROCESS_SPAWN)
}

/// Starts a PTY with the same subscription, cancellation and cleanup ownership.
pub(crate) fn run_terminal(request: Request) -> Result<Value, CoreError> {
    run_resource(request, "terminal", methods::TERMINAL_OPEN)
}

/// Owns a recursive watch until cancellation, disconnect, or root removal.
pub(crate) fn run_watch(request: Request) -> Result<Value, CoreError> {
    run_resource(request, "watch", methods::WATCH_START)
}

/// Bounded byte capture for tool probes; long-lived backends use streaming calls.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CaptureRequest {
    session_id: String,
    params: methods::SpawnParams,
    timeout_milliseconds: u64,
    max_output_bytes: usize,
}

/// Captures one process without leaking a child on timeout or excessive output.
pub(crate) fn capture_process(request: CaptureRequest) -> Result<Value, CoreError> {
    if !(1..=30_000).contains(&request.timeout_milliseconds)
        || !(1..=methods::MAX_TRANSFER_BYTES as usize).contains(&request.max_output_bytes)
        || request.params.pipe_stdin
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid host capture limits",
        ));
    }
    let connection = lookup(&request.session_id)?;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let exit = run_observing(
        &connection.session,
        Request {
            session_id: request.session_id,
            method: String::new(),
            params: serde_json::to_value(request.params).expect("spawn parameters encode"),
            timeout_milliseconds: None,
        },
        "process",
        methods::PROCESS_SPAWN,
        None,
        Some(Instant::now() + Duration::from_millis(request.timeout_milliseconds)),
        &mut |event| {
            if event.event == methods::EVENT_PROCESS_OUTPUT {
                let output: methods::ProcessOutputEvent = event.decode().map_err(|error| {
                    CoreError::new(ErrorCode::ParseFailed, "Invalid host process output")
                        .with_details(error.to_string())
                })?;
                let bytes = methods::decode_bytes(&output.data).map_err(|error| {
                    CoreError::new(ErrorCode::ParseFailed, "Invalid host process bytes")
                        .with_details(error.to_string())
                })?;
                if stdout.len() + stderr.len() + bytes.len() > request.max_output_bytes {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Host process output exceeded its limit",
                    ));
                }
                match output.stream {
                    methods::OutputStream::Stdout => stdout.extend_from_slice(&bytes),
                    methods::OutputStream::Stderr => stderr.extend_from_slice(&bytes),
                }
            }
            Ok(())
        },
    )?;
    Ok(
        json!({"stdout": methods::encode_bytes(&stdout), "stderr": methods::encode_bytes(&stderr),
        "exitCode": exit["exitCode"], "signal": exit["signal"]}),
    )
}

struct Resource<'a> {
    session: &'a RemoteSession,
    family: &'static str,
    id: u64,
    /// A lost spawn response can still mean the host created the resource.
    creation_attempted: bool,
}

impl Drop for Resource<'_> {
    fn drop(&mut self) {
        // Drop the receiver before the cleanup request: a full subscriber must
        // never block the protocol reader from delivering the close response.
        self.session.unsubscribe(self.family, self.id);
        if self.creation_attempted {
            let (method, params) = match self.family {
                "terminal" => (methods::TERMINAL_CLOSE, json!({"terminalId": self.id})),
                "watch" => (methods::WATCH_STOP, json!({"watchId": self.id})),
                _ => (
                    methods::PROCESS_KILL,
                    json!({"processId": self.id, "force": true}),
                ),
            };
            let _ = self.session.request_value(method, params, CLEANUP_TIMEOUT);
        }
    }
}

fn run_resource(request: Request, family: &'static str, method: &str) -> Result<Value, CoreError> {
    cancellation::check()?;
    let connection = lookup(&request.session_id)?;
    run_on_session(&connection.session, request, family, method)
}

fn run_on_session(
    session: &RemoteSession,
    request: Request,
    family: &'static str,
    method: &str,
) -> Result<Value, CoreError> {
    let deadline = request
        .timeout_milliseconds
        .map(|timeout| Instant::now() + Duration::from_millis(timeout.min(86_400_000)));
    run_observing(
        session,
        request,
        family,
        method,
        None,
        deadline,
        &mut |event| {
            execution_events::emit(json!({
                "type": "remote", "event": event.event, "params": event.params,
            }));
            Ok(())
        },
    )
}

/// Runs an owned host process with byte-preserving output and optional input.
pub(crate) fn process_observing(
    session: &RemoteSession,
    params: methods::SpawnParams,
    input: Option<&[u8]>,
    observer: &mut impl FnMut(Event) -> Result<(), CoreError>,
) -> Result<Value, CoreError> {
    run_observing(
        session,
        Request {
            session_id: String::new(),
            method: String::new(),
            params: serde_json::to_value(params).expect("spawn parameters encode"),
            timeout_milliseconds: None,
        },
        "process",
        methods::PROCESS_SPAWN,
        input,
        None,
        observer,
    )
}

fn run_observing(
    session: &RemoteSession,
    request: Request,
    family: &'static str,
    method: &str,
    input: Option<&[u8]>,
    deadline: Option<Instant>,
    observer: &mut impl FnMut(Event) -> Result<(), CoreError>,
) -> Result<Value, CoreError> {
    let id = session.allocate_id();
    let key = format!("{family}Id");
    let mut params = request.params;
    params
        .as_object_mut()
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Host parameters must be an object",
            )
        })?
        .insert(key.clone(), json!(id));
    // Validate before subscribing or sending. The host allocates IDs; callers
    // cannot steal another resource by supplying an ID in their parameters.
    match family {
        "terminal" => {
            decode::<methods::TerminalOpenParams>(params.clone())?;
        }
        "watch" => {
            decode::<methods::WatchStartParams>(params.clone())?;
        }
        _ => {
            decode::<methods::SpawnParams>(params.clone())?;
        }
    }
    let resource = Resource {
        session,
        family,
        id,
        creation_attempted: true,
    };
    let events = session.subscribe(family, id);
    let pending = session
        .begin_request_value(method, params, REQUEST_TIMEOUT)
        .map_err(|error| request_error(&request.session_id, error))?;
    let mut early = VecDeque::new();
    let mut early_bytes = 0usize;
    let started = loop {
        cancellation::check()?;
        check_deadline(deadline)?;
        if let Some(value) = pending
            .poll(EVENT_POLL)
            .map_err(|error| request_error(&request.session_id, error))?
        {
            break value;
        }
        while let Ok(event) = events.try_recv() {
            early_bytes = early_bytes.saturating_add(event.params.to_string().len());
            if early_bytes > EARLY_EVENT_LIMIT {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Host startup output exceeded its limit",
                ));
            }
            early.push_back(event);
        }
    };
    observer(Event {
        event: format!("{family}.started"),
        params: json!({key: id, "pid": started.get("pid")}),
        seq: None,
    })?;
    let outcome = receive_events(
        &resource,
        &events,
        early,
        &request.session_id,
        input,
        deadline,
        observer,
    );
    // See Resource::drop: remove backpressure before trying to stop the tree.
    drop(events);
    drop(resource);
    outcome
}

fn receive_events(
    resource: &Resource<'_>,
    events: &Receiver<Event>,
    mut early: VecDeque<Event>,
    session_id: &str,
    mut input: Option<&[u8]>,
    deadline: Option<Instant>,
    observer: &mut impl FnMut(Event) -> Result<(), CoreError>,
) -> Result<Value, CoreError> {
    let exit = format!("{}.exit", resource.family);
    let mut writing = None;
    let mut write_count = 0usize;
    loop {
        cancellation::check()?;
        check_deadline(deadline)?;
        let mut observed = 0;
        while let Ok(event) = early
            .pop_front()
            .map(Ok)
            .unwrap_or_else(|| events.try_recv())
        {
            validate_event(resource, &event)?;
            let finished = event.event == exit || watch_ended(&event);
            let result = event.params.clone();
            observer(event)?;
            if finished {
                return Ok(result);
            }
            observed += 1;
            if observed >= 32 {
                break;
            }
        }
        if let Some(pending) = &writing {
            match lithe_remote::client::session::PendingRequest::poll(pending, Duration::ZERO) {
                Ok(Some(_)) => {
                    input = if write_count == 0 {
                        None
                    } else {
                        input.map(|bytes| &bytes[write_count..])
                    };
                    writing = None;
                }
                Ok(None) => {}
                Err(ClientError::Remote(error))
                    if error.code == lithe_remote::protocol::ErrorCode::Busy =>
                {
                    writing = None
                }
                // A child can finish between its input and exit event. Drain
                // the authoritative exit before treating a closed pipe as failure.
                Err(ClientError::Remote(error))
                    if matches!(
                        error.code,
                        lithe_remote::protocol::ErrorCode::UnknownResource
                            | lithe_remote::protocol::ErrorCode::InvalidRequest
                    ) =>
                {
                    input = None;
                    writing = None;
                }
                Err(error) => return Err(request_error(session_id, error)),
            }
        }
        if let Some(remaining) = input.filter(|_| writing.is_none()) {
            let count = remaining.len().min(32 * 1024);
            let (method, params) = if count == 0 {
                (
                    methods::PROCESS_CLOSE_STDIN,
                    json!({"processId": resource.id}),
                )
            } else {
                (
                    methods::PROCESS_WRITE_STDIN,
                    json!({"processId": resource.id,
                    "data": methods::encode_bytes(&remaining[..count])}),
                )
            };
            write_count = count;
            writing = Some(
                resource
                    .session
                    .begin_request_value(method, params, REQUEST_TIMEOUT)
                    .map_err(|error| request_error(session_id, error))?,
            );
        }
        match events.recv_timeout(EVENT_POLL) {
            Ok(event) => {
                validate_event(resource, &event)?;
                let finished = event.event == exit || watch_ended(&event);
                let result = event.params.clone();
                observer(event)?;
                if finished {
                    return Ok(result);
                }
            }
            Err(RecvTimeoutError::Timeout) if !resource.session.is_closed() => {}
            Err(_) => {
                return Err(request_error(
                    session_id,
                    ClientError::Disconnected {
                        diagnostics: String::new(),
                    },
                ))
            }
        }
    }
}

fn check_deadline(deadline: Option<Instant>) -> Result<(), CoreError> {
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        Err(CoreError::new(
            ErrorCode::TimedOut,
            "Host process timed out",
        ))
    } else {
        Ok(())
    }
}

fn watch_ended(event: &Event) -> bool {
    event.event == methods::EVENT_WATCH_ERROR && event.params["code"] == "ROOT_REMOVED"
}

fn validate_event(resource: &Resource<'_>, event: &Event) -> Result<(), CoreError> {
    if event.resource() != Some((resource.family, resource.id)) {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Host resource identity changed",
        ));
    }
    let valid_data = |data: &str| {
        methods::decode_bytes(data)
            .is_ok_and(|bytes| bytes.len() <= methods::MAX_TRANSFER_BYTES as usize)
    };
    let valid = match event.event.as_str() {
        methods::EVENT_PROCESS_OUTPUT => event
            .decode::<methods::ProcessOutputEvent>()
            .is_ok_and(|event| valid_data(&event.data)),
        methods::EVENT_PROCESS_EXIT => event.decode::<methods::ProcessExitEvent>().is_ok(),
        methods::EVENT_TERMINAL_OUTPUT => event
            .decode::<methods::TerminalOutputEvent>()
            .is_ok_and(|event| valid_data(&event.data)),
        methods::EVENT_TERMINAL_EXIT => event.decode::<methods::TerminalExitEvent>().is_ok(),
        methods::EVENT_WATCH_CHANGED => event.decode::<methods::WatchChangedEvent>().is_ok(),
        methods::EVENT_WATCH_ERROR => event.decode::<methods::WatchErrorEvent>().is_ok(),
        _ => false,
    };
    if !valid {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Invalid host resource event",
        ));
    }
    Ok(())
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, CoreError> {
    serde_json::from_value(value).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid host resource parameters",
        )
        .with_details(error.to_string())
    })
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod request_tests {
    use super::*;

    #[test]
    fn finite_requests_cannot_create_unobserved_resources_or_change_session_delivery() {
        for method in [
            methods::PROCESS_SPAWN,
            methods::TERMINAL_OPEN,
            methods::WALK_START,
            methods::WATCH_START,
            methods::TUNNEL_OPEN,
            methods::SERVER_SHUTDOWN,
            methods::SERVER_ACK,
            methods::SERVER_RESUME,
        ] {
            assert!(!allowed_method(method), "{method}");
        }
        for method in [
            methods::FS_STAT,
            methods::FS_CREATE_RUN_DIRECTORY,
            methods::FS_RELEASE_RUN_DIRECTORY,
            methods::ENVIRONMENT_RESOLVE,
            methods::PROCESS_WRITE_STDIN,
            methods::PROCESS_KILL,
            methods::TERMINAL_RESIZE,
            methods::TERMINAL_CLOSE,
        ] {
            assert!(allowed_method(method), "{method}");
        }
    }

    #[test]
    fn host_request_rejects_unowned_operations_before_looking_up_a_connection() {
        let result = request(Request {
            session_id: "missing-session".into(),
            method: methods::TERMINAL_OPEN.into(),
            params: json!({}),
            timeout_milliseconds: None,
        });
        assert!(matches!(
            result.unwrap_err().code,
            ErrorCode::InvalidRequest
        ));
    }
}
