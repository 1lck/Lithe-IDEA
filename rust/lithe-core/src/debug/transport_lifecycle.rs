//! Platform-neutral lifecycle rules for one IDE-to-adapter byte stream.
//!
//! This is a reducer, separate from the DAP protocol state in `engine.rs`: the
//! platform reports what happened (an endpoint resolved, a write finished, a
//! timer fired) and Core answers with the effects to run next (connect, write,
//! arm a timer, close). Core never reads a clock, opens a socket or holds the
//! bytes. Hosts keep the real socket, DNS, timers and queued `Data`; only sizes
//! and counts cross the JSON boundary. That keeps one rule set, one deadline
//! policy and one set of lifecycle tests for every platform network layer.

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::protocol::{CoreError, ErrorCode};

/// Endpoint discovery, such as a cold language-server start.
const DEFAULT_DISCOVERY_MILLISECONDS: u64 = 10_000;
/// Establishing the socket once the endpoint is known.
const DEFAULT_CONNECT_MILLISECONDS: u64 = 10_000;
/// One outgoing write against a stalled peer, never the length of a debug session.
const DEFAULT_WRITE_MILLISECONDS: u64 = 10_000;
const DEFAULT_BUFFERED_BYTES: u64 = 8 * 1024 * 1024;
const DEFAULT_BUFFERED_WRITES: u64 = 1_024;
/// Best-effort flush of queued frames, including `disconnect`, before closing.
const DEFAULT_DRAIN_MILLISECONDS: u64 = 1_000;
/// Window a DAP `initialize` round trip gets once the socket is connected.
const DAP_HANDSHAKE_MILLISECONDS: u64 = 10_000;
/// Keeps host-supplied limits inside what every platform integer can hold.
const MAX_LIMIT: u64 = i32::MAX as u64;

static TRANSPORTS: OnceLock<Mutex<HashMap<String, Lifecycle>>> = OnceLock::new();

/// Deadline and queue policy for one transport.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct TransportLimits {
    discovery_milliseconds: u64,
    connect_milliseconds: u64,
    write_milliseconds: u64,
    buffered_bytes: u64,
    buffered_writes: u64,
    drain_milliseconds: u64,
}

impl Default for TransportLimits {
    fn default() -> Self {
        Self {
            discovery_milliseconds: DEFAULT_DISCOVERY_MILLISECONDS,
            connect_milliseconds: DEFAULT_CONNECT_MILLISECONDS,
            write_milliseconds: DEFAULT_WRITE_MILLISECONDS,
            buffered_bytes: DEFAULT_BUFFERED_BYTES,
            buffered_writes: DEFAULT_BUFFERED_WRITES,
            drain_milliseconds: DEFAULT_DRAIN_MILLISECONDS,
        }
    }
}

/// Per-transport overrides; an absent field keeps the Core default.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LimitOverrides {
    discovery_milliseconds: Option<u64>,
    connect_milliseconds: Option<u64>,
    write_milliseconds: Option<u64>,
    buffered_bytes: Option<u64>,
    buffered_writes: Option<u64>,
    drain_milliseconds: Option<u64>,
}

impl TransportLimits {
    fn resolve(overrides: Option<LimitOverrides>) -> Result<Self, CoreError> {
        let overrides = overrides.unwrap_or_default();
        let defaults = Self::default();
        let pick = |value: Option<u64>, default: u64, field: &str| match value {
            None => Ok(default),
            Some(value) if (1..=MAX_LIMIT).contains(&value) => Ok(value),
            Some(_) => Err(CoreError::new(
                ErrorCode::InvalidRequest,
                format!("Debug transport {field} must be between 1 and {MAX_LIMIT}."),
            )),
        };
        Ok(Self {
            discovery_milliseconds: pick(
                overrides.discovery_milliseconds,
                defaults.discovery_milliseconds,
                "discoveryMilliseconds",
            )?,
            connect_milliseconds: pick(
                overrides.connect_milliseconds,
                defaults.connect_milliseconds,
                "connectMilliseconds",
            )?,
            write_milliseconds: pick(
                overrides.write_milliseconds,
                defaults.write_milliseconds,
                "writeMilliseconds",
            )?,
            buffered_bytes: pick(
                overrides.buffered_bytes,
                defaults.buffered_bytes,
                "bufferedBytes",
            )?,
            buffered_writes: pick(
                overrides.buffered_writes,
                defaults.buffered_writes,
                "bufferedWrites",
            )?,
            drain_milliseconds: pick(
                overrides.drain_milliseconds,
                defaults.drain_milliseconds,
                "drainMilliseconds",
            )?,
        })
    }
}

/// Where a transport is in its life. `Stopped` is both the initial and the final phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum TransportPhase {
    Stopped,
    /// The host is looking for the endpoint, for example by starting a language server.
    Discovering,
    /// The endpoint is known and the host is establishing the socket.
    Connecting,
    Ready,
    /// The owner asked to stop: queued frames flush, new data and late messages are refused.
    Draining,
}

/// Events the platform reports or asks for. Callback events carry the `generation`
/// the host captured when it started the work they answer; user-driven events
/// (`start`, `send`, `stop`, `finishSendingAndStop`) always address the live lifecycle.
#[derive(Debug, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum TransportEvent {
    /// Begins a lifecycle; ignored while one is already running.
    Start {
        limits: Option<LimitOverrides>,
    },
    /// Queues one outgoing frame of `bytes` bytes. The host keeps the bytes.
    Send {
        bytes: u64,
    },
    /// User cancel: tears everything down silently, without a termination.
    Stop {},
    /// Flushes queued frames for a bounded time, then closes silently.
    FinishSendingAndStop {},
    /// Endpoint discovery finished. `port` stays signed so a bad provider value is
    /// a transport failure rather than a malformed request.
    EndpointResolved {
        generation: u64,
        host: String,
        port: i64,
    },
    ConnectionReady {
        generation: u64,
    },
    /// Bytes arrived; Core decides whether the host may forward them.
    DataReceived {
        generation: u64,
    },
    /// The peer closed the stream (EOF).
    PeerClosed {
        generation: u64,
    },
    /// Discovery, connect, socket or write failed. `message` is upstream diagnostics.
    Failed {
        generation: u64,
        message: String,
    },
    WriteCompleted {
        generation: u64,
        write_id: u64,
    },
    TimerFired {
        generation: u64,
        timer_id: u64,
    },
}

/// Why a timer was armed, so a host can log or label it. Core matches on `timerId`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum TimerPurpose {
    Discovery,
    Connect,
    Write,
    Drain,
}

/// Stable failure categories. The host owns the localized text for each.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum FailureReason {
    /// Discovery or connect exceeded its deadline.
    StartupTimedOut,
    /// The peer did not accept the in-flight write in time.
    WriteTimedOut,
    /// The outgoing queue exceeded its byte or count budget.
    BufferLimit,
    /// The resolved endpoint has no host or its port is outside 1-65535.
    InvalidEndpoint,
    /// The host reported the failure; the effect carries its own message.
    Host,
}

/// Work the host performs, in order, after a step.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum TransportEffect {
    /// Start looking for the endpoint and report `endpointResolved` or `failed`.
    DiscoverEndpoint,
    ArmTimer {
        timer_id: u64,
        purpose: TimerPurpose,
        after_milliseconds: u64,
    },
    CancelTimer {
        timer_id: u64,
    },
    /// Open the socket and report `connectionReady`, `dataReceived`, `peerClosed` or `failed`.
    Connect {
        host: String,
        port: u16,
    },
    /// Send the oldest queued frame, which must be `bytes` long, then report `writeCompleted`.
    Write {
        write_id: u64,
        bytes: u64,
    },
    /// Forward the received bytes to the owner.
    DeliverData,
    /// Cancel pending discovery, unhook and stop the socket, drop queued frames.
    Close,
    /// Surface the failure to the owner's error output before termination.
    ReportFailure {
        reason: FailureReason,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// Tell the owner the stream ended: exit code 0 for a clean EOF, 1 after a failure.
    NotifyTermination {
        exit_code: i32,
    },
}

/// What the step did with the event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum StepOutcome {
    Applied,
    /// A stale callback, a repeat or a no-op; nothing changed.
    Ignored,
    /// `send` on a transport that is not running; the host throws "stopped".
    RejectedNotRunning,
    /// `send` over budget; Core already failed the transport, the host throws "buffer full".
    RejectedBufferLimit,
}

/// Core's answer to one event.
///
/// A host that re-enters Core while running `effects` (an observer restarting the
/// transport) must compare the live generation with this one and abandon the rest
/// of an older response.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TransportStep {
    /// Generation after the step; callbacks of the new work must carry it.
    generation: u64,
    phase: TransportPhase,
    outcome: StepOutcome,
    effects: Vec<TransportEffect>,
}

/// A failure that ends the lifecycle with exit code 1.
enum Failure {
    Reason(FailureReason),
    Host(String),
}

#[derive(Debug)]
struct Lifecycle {
    limits: TransportLimits,
    /// Bumped whenever work is invalidated, so any older callback is recognizably stale.
    generation: u64,
    phase: TransportPhase,
    /// Sizes of queued frames, oldest first; the host holds the matching bytes.
    queued: VecDeque<u64>,
    buffered_bytes: u64,
    /// At most one write is in flight, and it is always the head of `queued`.
    active_write: Option<u64>,
    /// Discovery, then connect, deadline; cancelled once the stream is ready.
    startup_timer: Option<u64>,
    write_timer: Option<u64>,
    drain_timer: Option<u64>,
    next_timer_id: u64,
    next_write_id: u64,
}

impl Lifecycle {
    fn new() -> Self {
        Self {
            limits: TransportLimits::default(),
            generation: 0,
            phase: TransportPhase::Stopped,
            queued: VecDeque::new(),
            buffered_bytes: 0,
            active_write: None,
            startup_timer: None,
            write_timer: None,
            drain_timer: None,
            next_timer_id: 1,
            next_write_id: 1,
        }
    }

    fn handle(&mut self, event: TransportEvent) -> Result<TransportStep, CoreError> {
        let mut effects = Vec::new();
        let outcome = match event {
            TransportEvent::Start { limits } => {
                let limits = TransportLimits::resolve(limits)?;
                self.start(limits, &mut effects)
            }
            TransportEvent::Send { bytes } => self.send(bytes, &mut effects),
            TransportEvent::Stop {} if self.phase == TransportPhase::Stopped => {
                StepOutcome::Ignored
            }
            TransportEvent::Stop {} => {
                self.clean_up(&mut effects);
                StepOutcome::Applied
            }
            TransportEvent::FinishSendingAndStop {} => self.finish_sending_and_stop(&mut effects),
            TransportEvent::EndpointResolved {
                generation,
                host,
                port,
            } => self.endpoint_resolved(generation, host, port, &mut effects),
            TransportEvent::ConnectionReady { generation } => {
                self.connection_ready(generation, &mut effects)
            }
            TransportEvent::DataReceived { generation } => {
                self.data_received(generation, &mut effects)
            }
            TransportEvent::PeerClosed { generation } => {
                self.report(generation, None, &mut effects)
            }
            TransportEvent::Failed {
                generation,
                message,
            } => self.report(generation, Some(Failure::Host(message)), &mut effects),
            TransportEvent::WriteCompleted {
                generation,
                write_id,
            } => self.write_completed(generation, write_id, &mut effects),
            TransportEvent::TimerFired {
                generation,
                timer_id,
            } => self.timer_fired(generation, timer_id, &mut effects),
        };
        Ok(TransportStep {
            generation: self.generation,
            phase: self.phase,
            outcome,
            effects,
        })
    }

    /// A callback is current only while the lifecycle it was started under is alive.
    fn is_current(&self, generation: u64) -> bool {
        self.phase != TransportPhase::Stopped && self.generation == generation
    }

    fn start(
        &mut self,
        limits: TransportLimits,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        // A draining lifecycle has already been released by its owner, so a new
        // start replaces it instead of waiting for the flush.
        if self.phase == TransportPhase::Draining {
            self.clean_up(effects);
        }
        if self.phase != TransportPhase::Stopped {
            return StepOutcome::Ignored;
        }
        self.limits = limits;
        self.generation += 1;
        self.phase = TransportPhase::Discovering;
        self.arm_startup_timer(
            TimerPurpose::Discovery,
            limits.discovery_milliseconds,
            effects,
        );
        effects.push(TransportEffect::DiscoverEndpoint);
        StepOutcome::Applied
    }

    fn send(&mut self, bytes: u64, effects: &mut Vec<TransportEffect>) -> StepOutcome {
        if !matches!(
            self.phase,
            TransportPhase::Discovering | TransportPhase::Connecting | TransportPhase::Ready
        ) {
            return StepOutcome::RejectedNotRunning;
        }
        if bytes == 0 {
            return StepOutcome::Applied;
        }
        let room = self
            .limits
            .buffered_bytes
            .saturating_sub(self.buffered_bytes);
        if self.queued.len() as u64 >= self.limits.buffered_writes || bytes > room {
            self.finish(Some(Failure::Reason(FailureReason::BufferLimit)), effects);
            return StepOutcome::RejectedBufferLimit;
        }
        self.queued.push_back(bytes);
        self.buffered_bytes += bytes;
        self.send_next(effects);
        StepOutcome::Applied
    }

    fn finish_sending_and_stop(&mut self, effects: &mut Vec<TransportEffect>) -> StepOutcome {
        if matches!(
            self.phase,
            TransportPhase::Stopped | TransportPhase::Draining
        ) {
            return StepOutcome::Ignored;
        }
        // Nothing can flush before the stream is ready or when nothing is queued.
        if self.phase != TransportPhase::Ready || self.queued.is_empty() {
            self.clean_up(effects);
            return StepOutcome::Applied;
        }
        self.phase = TransportPhase::Draining;
        let timer_id = self.arm_timer(TimerPurpose::Drain, self.limits.drain_milliseconds, effects);
        self.drain_timer = Some(timer_id);
        self.send_next(effects);
        StepOutcome::Applied
    }

    fn endpoint_resolved(
        &mut self,
        generation: u64,
        host: String,
        port: i64,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        if !self.is_current(generation) || self.phase != TransportPhase::Discovering {
            return StepOutcome::Ignored;
        }
        // User endpoints are validated before this point; a provider can still hand
        // back anything, and every platform needs a safe native port conversion.
        let Some(port) = u16::try_from(port).ok().filter(|port| *port != 0) else {
            self.finish(
                Some(Failure::Reason(FailureReason::InvalidEndpoint)),
                effects,
            );
            return StepOutcome::Applied;
        };
        if host.is_empty() {
            self.finish(
                Some(Failure::Reason(FailureReason::InvalidEndpoint)),
                effects,
            );
            return StepOutcome::Applied;
        }
        self.phase = TransportPhase::Connecting;
        // Discovery is over; connecting gets its own budget instead of the remainder.
        self.arm_startup_timer(
            TimerPurpose::Connect,
            self.limits.connect_milliseconds,
            effects,
        );
        effects.push(TransportEffect::Connect { host, port });
        StepOutcome::Applied
    }

    fn connection_ready(
        &mut self,
        generation: u64,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        if !self.is_current(generation) || self.phase != TransportPhase::Connecting {
            return StepOutcome::Ignored;
        }
        self.phase = TransportPhase::Ready;
        cancel_timer(&mut self.startup_timer, effects);
        self.send_next(effects);
        StepOutcome::Applied
    }

    fn data_received(
        &mut self,
        generation: u64,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        // Draining refuses late messages: the owner has already released its session.
        if self.is_current(generation)
            && matches!(
                self.phase,
                TransportPhase::Connecting | TransportPhase::Ready
            )
        {
            effects.push(TransportEffect::DeliverData);
            StepOutcome::Applied
        } else {
            StepOutcome::Ignored
        }
    }

    /// Handles EOF (`failure` is `None`) and host-reported errors alike.
    fn report(
        &mut self,
        generation: u64,
        failure: Option<Failure>,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        if !self.is_current(generation) {
            return StepOutcome::Ignored;
        }
        self.finish(failure, effects);
        StepOutcome::Applied
    }

    fn write_completed(
        &mut self,
        generation: u64,
        write_id: u64,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        if !self.is_current(generation) || self.active_write != Some(write_id) {
            return StepOutcome::Ignored;
        }
        cancel_timer(&mut self.write_timer, effects);
        self.active_write = None;
        if let Some(bytes) = self.queued.pop_front() {
            self.buffered_bytes = self.buffered_bytes.saturating_sub(bytes);
        }
        if self.phase == TransportPhase::Draining && self.queued.is_empty() {
            self.clean_up(effects);
        } else {
            self.send_next(effects);
        }
        StepOutcome::Applied
    }

    fn timer_fired(
        &mut self,
        generation: u64,
        timer_id: u64,
        effects: &mut Vec<TransportEffect>,
    ) -> StepOutcome {
        if !self.is_current(generation) {
            return StepOutcome::Ignored;
        }
        // Match on the armed ids so a timer the host failed to cancel stays harmless.
        if self.startup_timer == Some(timer_id) {
            self.startup_timer = None;
            self.finish(
                Some(Failure::Reason(FailureReason::StartupTimedOut)),
                effects,
            );
        } else if self.write_timer == Some(timer_id) {
            self.write_timer = None;
            self.finish(Some(Failure::Reason(FailureReason::WriteTimedOut)), effects);
        } else if self.drain_timer == Some(timer_id) {
            self.drain_timer = None;
            self.clean_up(effects);
        } else {
            return StepOutcome::Ignored;
        }
        StepOutcome::Applied
    }

    /// Starts the next write unless one is already in flight.
    fn send_next(&mut self, effects: &mut Vec<TransportEffect>) {
        if !matches!(self.phase, TransportPhase::Ready | TransportPhase::Draining)
            || self.active_write.is_some()
        {
            return;
        }
        let Some(&bytes) = self.queued.front() else {
            return;
        };
        let write_id = self.next_write_id;
        self.next_write_id += 1;
        self.active_write = Some(write_id);
        let timer_id = self.arm_timer(TimerPurpose::Write, self.limits.write_milliseconds, effects);
        self.write_timer = Some(timer_id);
        effects.push(TransportEffect::Write { write_id, bytes });
    }

    /// Ends the lifecycle once. A draining lifecycle ends silently because its
    /// owner already released the session; otherwise the owner hears the failure
    /// (if any) and then the termination.
    fn finish(&mut self, failure: Option<Failure>, effects: &mut Vec<TransportEffect>) {
        if self.phase == TransportPhase::Stopped {
            return;
        }
        let silent = self.phase == TransportPhase::Draining;
        // Invalidate first: the host's close and observer callbacks can re-enter.
        self.clean_up(effects);
        if silent {
            return;
        }
        let exit_code = if failure.is_some() { 1 } else { 0 };
        match failure {
            Some(Failure::Reason(reason)) => effects.push(TransportEffect::ReportFailure {
                reason,
                message: None,
            }),
            Some(Failure::Host(message)) => effects.push(TransportEffect::ReportFailure {
                reason: FailureReason::Host,
                message: Some(message),
            }),
            None => {}
        }
        effects.push(TransportEffect::NotifyTermination { exit_code });
    }

    /// Idempotent teardown that also invalidates every outstanding callback.
    fn clean_up(&mut self, effects: &mut Vec<TransportEffect>) {
        if self.phase == TransportPhase::Stopped {
            return;
        }
        self.generation += 1;
        self.phase = TransportPhase::Stopped;
        cancel_timer(&mut self.drain_timer, effects);
        cancel_timer(&mut self.startup_timer, effects);
        cancel_timer(&mut self.write_timer, effects);
        self.queued.clear();
        self.buffered_bytes = 0;
        self.active_write = None;
        effects.push(TransportEffect::Close);
    }

    fn arm_startup_timer(
        &mut self,
        purpose: TimerPurpose,
        after_milliseconds: u64,
        effects: &mut Vec<TransportEffect>,
    ) {
        cancel_timer(&mut self.startup_timer, effects);
        let timer_id = self.arm_timer(purpose, after_milliseconds, effects);
        self.startup_timer = Some(timer_id);
    }

    fn arm_timer(
        &mut self,
        purpose: TimerPurpose,
        after_milliseconds: u64,
        effects: &mut Vec<TransportEffect>,
    ) -> u64 {
        let timer_id = self.next_timer_id;
        self.next_timer_id += 1;
        effects.push(TransportEffect::ArmTimer {
            timer_id,
            purpose,
            after_milliseconds,
        });
        timer_id
    }
}

fn cancel_timer(slot: &mut Option<u64>, effects: &mut Vec<TransportEffect>) {
    if let Some(timer_id) = slot.take() {
        effects.push(TransportEffect::CancelTimer { timer_id });
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TransportEventRequest {
    transport_id: String,
    event: TransportEvent,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TransportRequest {
    transport_id: String,
}

fn transports_lock() -> Result<std::sync::MutexGuard<'static, HashMap<String, Lifecycle>>, CoreError>
{
    TRANSPORTS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Debug transport state is unavailable."))
}

fn parse<T: for<'de> Deserialize<'de>>(payload: Value) -> Result<T, CoreError> {
    serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid debug transport request.",
        )
        .with_details(error.to_string())
    })
}

fn validate_transport_id(transport_id: &str) -> Result<(), CoreError> {
    if transport_id.trim().is_empty() || transport_id.contains('\0') || transport_id.len() > 512 {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Debug transportId was invalid.",
        ));
    }
    Ok(())
}

/// Returns the default deadlines and budgets, and the session `initialize`
/// deadline that must outlast a connect, without creating any state.
pub(crate) fn transport_policy(_payload: Value) -> Result<Value, CoreError> {
    let limits = TransportLimits::default();
    Ok(json!({
        "limits": limits,
        "initializationMilliseconds": limits.connect_milliseconds + DAP_HANDSHAKE_MILLISECONDS,
    }))
}

/// Applies one event to a transport's lifecycle and returns the effects to run.
/// Only `start` creates a transport; a late callback for a released one is stale.
pub(crate) fn handle_transport_event(payload: Value) -> Result<Value, CoreError> {
    let request: TransportEventRequest = parse(payload)?;
    validate_transport_id(&request.transport_id)?;
    let mut transports = transports_lock()?;
    let step = match transports.get_mut(&request.transport_id) {
        Some(lifecycle) => lifecycle.handle(request.event)?,
        None if matches!(request.event, TransportEvent::Start { .. }) => {
            let mut lifecycle = Lifecycle::new();
            let step = lifecycle.handle(request.event)?;
            transports.insert(request.transport_id, lifecycle);
            step
        }
        None => TransportStep {
            generation: 0,
            phase: TransportPhase::Stopped,
            outcome: if matches!(request.event, TransportEvent::Send { .. }) {
                StepOutcome::RejectedNotRunning
            } else {
                StepOutcome::Ignored
            },
            effects: Vec::new(),
        },
    };
    Ok(serde_json::to_value(step).expect("Transport step should encode"))
}

/// Forgets a transport once the host has stopped it and dropped its handles.
pub(crate) fn release_transport(payload: Value) -> Result<Value, CoreError> {
    let request: TransportRequest = parse(payload)?;
    validate_transport_id(&request.transport_id)?;
    let released = transports_lock()?.remove(&request.transport_id).is_some();
    Ok(json!({ "released": released }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(lifecycle: &mut Lifecycle, event: Value) -> Value {
        let event: TransportEvent = serde_json::from_value(event).expect("event decodes");
        serde_json::to_value(lifecycle.handle(event).expect("event is valid"))
            .expect("step encodes")
    }

    /// Replays every scripted scenario against a fresh lifecycle. The same file is
    /// the contract any platform adapter's tests can reuse.
    #[test]
    fn lifecycle_fixture_scenarios_match_expected_steps() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/debug/transport-lifecycle-v1.json"
        )))
        .expect("transport lifecycle fixture is JSON");
        for scenario in fixture["scenarios"].as_array().expect("scenarios") {
            let mut lifecycle = Lifecycle::new();
            for (index, scripted) in scenario["steps"]
                .as_array()
                .expect("scenario steps")
                .iter()
                .enumerate()
            {
                let actual = step(&mut lifecycle, scripted["event"].clone());
                assert_eq!(
                    actual, scripted["expect"],
                    "{} step {index}: {}",
                    scenario["name"], scripted["event"]
                );
            }
        }
    }

    #[test]
    fn invalid_limit_overrides_are_rejected_before_any_state_changes() {
        let mut lifecycle = Lifecycle::new();
        for limits in [
            json!({"writeMilliseconds": 0}),
            json!({"bufferedBytes": 0}),
            json!({"discoveryMilliseconds": MAX_LIMIT + 1}),
        ] {
            let event: TransportEvent =
                serde_json::from_value(json!({"type": "start", "limits": limits})).unwrap();
            let error = lifecycle.handle(event).expect_err("invalid limits");
            assert!(matches!(error.code, ErrorCode::InvalidRequest));
        }
        assert_eq!(lifecycle.phase, TransportPhase::Stopped);
        assert_eq!(lifecycle.generation, 0);
    }

    #[test]
    fn unknown_event_fields_and_types_are_invalid_requests() {
        for payload in [
            json!({"transportId": "t", "event": {"type": "nope"}}),
            json!({"transportId": "t", "event": {"type": "stop", "extra": 1}}),
            json!({"transportId": "", "event": {"type": "stop"}}),
            json!({"transportId": "t"}),
        ] {
            let error = handle_transport_event(payload).expect_err("invalid request");
            assert!(matches!(error.code, ErrorCode::InvalidRequest));
        }
    }

    #[test]
    fn json_boundary_creates_on_start_and_treats_released_transports_as_stale() {
        let id = "transport-lifecycle-json-boundary";
        let before = handle_transport_event(
            json!({"transportId": id, "event": {"type": "send", "bytes": 1}}),
        )
        .unwrap();
        assert_eq!(before["outcome"], "rejectedNotRunning");

        let started =
            handle_transport_event(json!({"transportId": id, "event": {"type": "start"}})).unwrap();
        assert_eq!(started["generation"], 1);
        assert_eq!(started["phase"], "discovering");

        assert_eq!(
            release_transport(json!({"transportId": id})).unwrap()["released"],
            true
        );
        assert_eq!(
            release_transport(json!({"transportId": id})).unwrap()["released"],
            false
        );
        // A callback that outlives its transport must not resurrect it.
        let late = handle_transport_event(json!({
            "transportId": id,
            "event": {"type": "connectionReady", "generation": 1}
        }))
        .unwrap();
        assert_eq!(late["outcome"], "ignored");
        assert_eq!(late["phase"], "stopped");
    }

    #[test]
    fn policy_reports_core_defaults_and_an_initialization_deadline_past_connect() {
        let policy = transport_policy(json!({})).unwrap();
        assert_eq!(policy["limits"]["discoveryMilliseconds"], 10_000);
        assert_eq!(policy["limits"]["connectMilliseconds"], 10_000);
        assert_eq!(policy["limits"]["writeMilliseconds"], 10_000);
        assert_eq!(policy["limits"]["bufferedBytes"], 8 * 1024 * 1024);
        assert_eq!(policy["limits"]["bufferedWrites"], 1_024);
        assert_eq!(policy["limits"]["drainMilliseconds"], 1_000);
        assert_eq!(policy["initializationMilliseconds"], 20_000);
    }

    #[test]
    fn a_cancelled_timer_the_host_still_fires_cannot_fail_a_ready_stream() {
        // The host may race a timer callback with the cancel effect.
        let mut lifecycle = Lifecycle::new();
        step(&mut lifecycle, json!({"type": "start"}));
        step(
            &mut lifecycle,
            json!({"type": "endpointResolved", "generation": 1, "host": "127.0.0.1", "port": 5005}),
        );
        step(
            &mut lifecycle,
            json!({"type": "connectionReady", "generation": 1}),
        );
        let late = step(
            &mut lifecycle,
            json!({"type": "timerFired", "generation": 1, "timerId": 2}),
        );
        assert_eq!(late["outcome"], "ignored");
        assert_eq!(late["phase"], "ready");
    }
}
