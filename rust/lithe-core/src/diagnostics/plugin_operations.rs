//! Core-owned `plugins.operation.*` results for declarative plugin contributions.
//!
//! A declarative contribution has no plugin process that could report through
//! `lithe/log`; the host or a Core engine runs the declared process or command
//! instead. Every such attempt is one [`DeclarativeOperation`]. Contribution kinds
//! differ only by their row in [`CONTRIBUTIONS`]: the operation token and the
//! [`Lifecycle`] that decides which failure stages exist and which `host.*` code
//! each stage means. A new declarative contract adds a row, never a code path.
//!
//! The owner of the process lifecycle records the terminal result: Core for the
//! language-server start it supervises, the host for attempts it supervises. Either
//! way the fact passes the same validation and lands on the plugin's
//! `plugins/<id>/host` channel, next to the facts its SDK-backed peers report. No
//! plugin output, path, or error text crosses this ingress.

use super::{
    channel::{identity_segment, LogError},
    core_events,
};
use serde::{Deserialize, Deserializer};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// Boundary where an attempt failed. Only the contribution's [`Lifecycle`] turns it
/// into a `host.*` code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    /// The declared command plan could not be prepared.
    Plan,
    /// The declared executable or launch input could not be resolved.
    Resolve,
    /// The resolved process could not be started.
    Launch,
    /// The protocol handshake failed after the process started.
    Initialize,
    /// The attempt exceeded its host or Core deadline.
    Timeout,
    /// The process exited before it was ready, or a command exited nonzero.
    Exit,
    /// The command output was not a valid document for the contract.
    Decode,
}

/// How a declarative attempt runs. The lifecycle owns the stage-to-code table, so a
/// code keeps one meaning across every contribution that shares the lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lifecycle {
    /// A long-lived process that becomes ready when its protocol handshake succeeds.
    ProcessStart,
    /// A one-shot command whose output the host decodes into a contract document.
    CommandRun,
}

impl Lifecycle {
    /// Stable code for a failed stage; `None` marks a stage this lifecycle cannot
    /// reach, and such a fact is rejected instead of mapped.
    pub fn code(self, stage: Stage) -> Option<&'static str> {
        use Lifecycle::{CommandRun, ProcessStart};
        Some(match (self, stage) {
            (_, Stage::Resolve) => "host.executableUnavailable",
            (_, Stage::Launch) => "host.launchFailed",
            (_, Stage::Timeout) => "host.timedOut",
            (ProcessStart, Stage::Initialize) => "host.initializeFailed",
            (ProcessStart, Stage::Exit) => "host.exitedEarly",
            (CommandRun, Stage::Plan) => "host.planFailed",
            (CommandRun, Stage::Exit) => "host.commandFailed",
            (CommandRun, Stage::Decode) => "host.outputInvalid",
            (ProcessStart, Stage::Plan | Stage::Decode) | (CommandRun, Stage::Initialize) => {
                return None
            }
        })
    }
}

/// One declarative contribution kind whose attempts the host or Core supervises.
#[derive(Debug, PartialEq, Eq)]
pub struct Contribution {
    /// Wire and log token. Command contributions reuse the SDK method name, so a
    /// declarative plugin and an SDK-backed one log the same work the same way.
    pub operation: &'static str,
    /// Decides the reachable failure stages and their codes.
    pub lifecycle: Lifecycle,
}

/// `languageServers[]`: from launch resolution to the `initialize` result.
pub static LANGUAGE_SERVER_START: Contribution = Contribution {
    operation: "languageServer/start",
    lifecycle: Lifecycle::ProcessStart,
};

/// `debugAdapters[]`: from launch resolution to the DAP `initialize` result.
pub static DEBUG_ADAPTER_START: Contribution = Contribution {
    operation: "debugAdapter/start",
    lifecycle: Lifecycle::ProcessStart,
};

/// `buildSystems[].model` with a command source: one model load.
pub static BUILD_MODEL: Contribution = Contribution {
    operation: "lithe/build/model",
    lifecycle: Lifecycle::CommandRun,
};

/// `buildSystems[].dependencies` with a command source: one dependency tree load.
pub static BUILD_DEPENDENCIES: Contribution = Contribution {
    operation: "lithe/build/dependencies",
    lifecycle: Lifecycle::CommandRun,
};

/// Every contribution kind this ingress accepts. Supporting a new declarative
/// contract means adding its row here and reporting the same token from its owner.
pub static CONTRIBUTIONS: &[&Contribution] = &[
    &LANGUAGE_SERVER_START,
    &DEBUG_ADAPTER_START,
    &BUILD_MODEL,
    &BUILD_DEPENDENCIES,
];

impl Contribution {
    /// Row for a wire token; unknown tokens are not host facts.
    pub fn find(operation: &str) -> Option<&'static Contribution> {
        CONTRIBUTIONS
            .iter()
            .copied()
            .find(|row| row.operation == operation)
    }
}

/// One terminal result. Cancellation is never recorded: the user ended the attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeclarativeOperation {
    /// Installed plugin that declared the contribution, known from the launch source.
    pub plugin_id: String,
    /// Row that names the operation and maps the failed stage.
    pub contribution: &'static Contribution,
    /// `None` when the attempt finished; otherwise the boundary that failed.
    pub failure: Option<Stage>,
    /// Monotonic elapsed milliseconds for the whole attempt.
    pub duration_ms: u64,
    /// Host operation that already correlates this attempt's lifecycle facts.
    pub operation_id: Option<String>,
}

/// Wire form of `diagnostics.recordPluginOperation`; `stage` is required iff failed.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    plugin_id: String,
    operation: String,
    outcome: Outcome,
    #[serde(default, deserialize_with = "present")]
    stage: Option<Stage>,
    duration_ms: u64,
    #[serde(default, deserialize_with = "present")]
    operation_id: Option<String>,
}

/// An optional field is either absent or a value; an explicit `null` is rejected.
fn present<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Outcome {
    Finished,
    Failed,
}

/// Every rejected request shares one code: the request is not a valid host fact.
/// The message never echoes the rejected value.
fn invalid() -> LogError {
    LogError::new(-32064, "Invalid host plugin operation")
}

// Same token grammar as SDK `operationId`, then the persisted record identity rule.
fn valid_operation_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:/-$".contains(&b))
        && super::record::identity(value).is_ok()
}

fn fact(input: &DeclarativeOperation) -> Result<(&'static str, BTreeMap<String, Value>), LogError> {
    if input.duration_ms > MAX_SAFE_INTEGER
        || input
            .operation_id
            .as_deref()
            .is_some_and(|op| !valid_operation_id(op))
    {
        return Err(invalid());
    }
    let mut fields = BTreeMap::from([
        // The SDK route maps the same plugin through the same function, so both
        // writers share one `plugins/<id>/host` channel.
        ("plugin".into(), json!(identity_segment(&input.plugin_id))),
        ("operation".into(), json!(input.contribution.operation)),
        ("duration_ms".into(), json!(input.duration_ms)),
    ]);
    let Some(stage) = input.failure else {
        return Ok(("plugins.operation.finished", fields));
    };
    let code = input
        .contribution
        .lifecycle
        .code(stage)
        .ok_or_else(invalid)?;
    fields.insert("code".into(), json!(code));
    Ok(("plugins.operation.failed", fields))
}

/// Validates the whole fact before touching the process queue.
pub fn record(input: DeclarativeOperation) -> Result<(), LogError> {
    let (event, fields) = fact(&input)?;
    core_events::record(event, fields, input.operation_id)
}

/// Engine-side recording: a rejected or dropped fact becomes the queue's drop count.
pub(crate) fn record_or_note_drop(input: DeclarativeOperation) {
    #[cfg(test)]
    test_capture::push(&input);
    if record(input).is_err() {
        core_events::note_dropped();
    }
}

fn decode(input: Value) -> Result<DeclarativeOperation, LogError> {
    let request: Request = serde_json::from_value(input).map_err(|_| invalid())?;
    let contribution = Contribution::find(&request.operation).ok_or_else(invalid)?;
    let failure = match (request.outcome, request.stage) {
        (Outcome::Finished, None) => None,
        (Outcome::Failed, Some(stage)) => Some(stage),
        _ => return Err(invalid()),
    };
    Ok(DeclarativeOperation {
        plugin_id: request.plugin_id,
        contribution,
        failure,
        duration_ms: request.duration_ms,
        operation_id: request.operation_id,
    })
}

/// `diagnostics.recordPluginOperation`: strict host ingress; returns `{}` once queued.
pub fn record_request(input: Value) -> Result<Value, LogError> {
    record(decode(input)?)?;
    Ok(json!({}))
}

/// Attempt the host began and handed to Core, which owns the rest of it.
///
/// The host records only failures before the handoff; Core records the single
/// terminal result after it. Wire form: `{pluginId, operationId, elapsedMs}`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AttemptHandoff {
    /// Plugin whose declaration the attempt runs. It is named here rather than
    /// taken from the session, because a plugin API 1 server is launched as a
    /// host-owned process with no plugin identity of its own.
    pub plugin_id: String,
    /// Host operation that already correlates the attempt's lifecycle facts.
    pub operation_id: String,
    /// Monotonic milliseconds the host spent on the attempt before the handoff.
    pub elapsed_ms: u64,
}

/// Declarative attempt in flight inside a Core engine.
#[derive(Debug)]
pub(crate) struct Attempt {
    contribution: &'static Contribution,
    plugin_id: String,
    operation_id: String,
    host_elapsed_ms: u64,
    started: Instant,
}

/// Shared by every code path that can end one attempt. Whichever path reaches a
/// terminal result first takes the attempt, so it is recorded at most once even
/// when two paths race to end it.
pub(crate) type AttemptSlot = Arc<Mutex<Option<Attempt>>>;

impl Attempt {
    /// Slot holding a handed-off attempt, timed from now.
    pub(crate) fn slot(
        contribution: &'static Contribution,
        handoff: AttemptHandoff,
    ) -> AttemptSlot {
        Arc::new(Mutex::new(Some(Self {
            contribution,
            plugin_id: handoff.plugin_id,
            operation_id: handoff.operation_id,
            host_elapsed_ms: handoff.elapsed_ms,
            started: Instant::now(),
        })))
    }

    /// Slot for work that carries no declarative attempt; finishing it is a no-op.
    pub(crate) fn none() -> AttemptSlot {
        Arc::new(Mutex::new(None))
    }
}

/// Records the attempt's terminal result unless another path already did.
pub(crate) fn finish(slot: &AttemptSlot, failure: Option<Stage>) {
    let Some(attempt) = slot.lock().unwrap_or_else(|e| e.into_inner()).take() else {
        return;
    };
    let core_elapsed_ms = u64::try_from(attempt.started.elapsed().as_millis()).unwrap_or(u64::MAX);
    record_or_note_drop(DeclarativeOperation {
        plugin_id: attempt.plugin_id,
        contribution: attempt.contribution,
        failure,
        duration_ms: attempt.host_elapsed_ms.saturating_add(core_elapsed_ms),
        operation_id: Some(attempt.operation_id),
    });
}

/// Ends the attempt without a result: the user cancelled or stopped it.
pub(crate) fn abandon(slot: &AttemptSlot) {
    slot.lock().unwrap_or_else(|e| e.into_inner()).take();
}

/// Engine results as recorded, for engine tests. The process queue is shared and
/// bounded, so a parallel test run can fill it; tests read their own facts back
/// by plugin ID instead.
#[cfg(test)]
pub(crate) mod test_capture {
    use super::DeclarativeOperation;
    use std::sync::Mutex;

    static FACTS: Mutex<Vec<DeclarativeOperation>> = Mutex::new(Vec::new());

    pub(super) fn push(input: &DeclarativeOperation) {
        FACTS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(input.clone());
    }

    /// Removes and returns the facts recorded for `plugin_id`, in record order.
    pub(crate) fn take(plugin_id: &str) -> Vec<DeclarativeOperation> {
        let mut facts = FACTS.lock().unwrap_or_else(|e| e.into_inner());
        let (taken, kept) = facts
            .drain(..)
            .partition(|fact| fact.plugin_id == plugin_id);
        *facts = kept;
        taken
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const STAGES: [&str; 7] = [
        "plan",
        "resolve",
        "launch",
        "initialize",
        "timeout",
        "exit",
        "decode",
    ];

    fn prepare(payload: Value) -> Result<core_events::CoreEvent, LogError> {
        let input = decode(payload)?;
        let (event, fields) = fact(&input)?;
        core_events::prepare(event, fields, input.operation_id)
    }

    // Guards the one-meaning-per-code rule: each lifecycle's stage table is pinned,
    // and every unreachable pair is rejected rather than mapped.
    #[test]
    fn diagnostics_host_plugin_operations_map_each_stage_to_one_code() {
        let expected = |lifecycle: Lifecycle, stage: &str| -> Option<&str> {
            let command = lifecycle == Lifecycle::CommandRun;
            match (stage, command) {
                ("plan", true) => Some("host.planFailed"),
                ("resolve", _) => Some("host.executableUnavailable"),
                ("launch", _) => Some("host.launchFailed"),
                ("initialize", false) => Some("host.initializeFailed"),
                ("timeout", _) => Some("host.timedOut"),
                ("exit", true) => Some("host.commandFailed"),
                ("exit", false) => Some("host.exitedEarly"),
                ("decode", true) => Some("host.outputInvalid"),
                _ => None,
            }
        };
        for row in CONTRIBUTIONS {
            let finished = prepare(json!({"pluginId":"io.example.contribution",
                "operation":row.operation, "outcome":"finished", "durationMs":412,
                "operationId":"attempt-7"}))
            .unwrap();
            assert_eq!(finished.channel, "plugins/io.example.contribution/host");
            assert_eq!(finished.event, "plugins.operation.finished");
            assert_eq!(finished.fields["operation"], json!(row.operation));
            assert_eq!(finished.op.as_deref(), Some("attempt-7"));
            assert!(finished.fields.get("code").is_none());
            for stage in STAGES {
                let result = prepare(json!({"pluginId":"io.example.contribution",
                    "operation":row.operation, "outcome":"failed", "stage":stage,
                    "durationMs":2}));
                let operation = row.operation;
                match expected(row.lifecycle, stage) {
                    Some(code) => {
                        let failed = result.unwrap();
                        assert_eq!(failed.event, "plugins.operation.failed");
                        assert_eq!(failed.fields["code"], json!(code), "{operation} {stage}");
                    }
                    None => assert_eq!(result.unwrap_err().code, -32064, "{operation} {stage}"),
                }
            }
        }
    }

    // Each row is one contract; the table must not map one token twice or drift
    // from the manifest contribution it names.
    #[test]
    fn diagnostics_host_plugin_operations_table_names_each_contribution_once() {
        let pinned = [
            ("languageServer/start", Lifecycle::ProcessStart),
            ("debugAdapter/start", Lifecycle::ProcessStart),
            ("lithe/build/model", Lifecycle::CommandRun),
            ("lithe/build/dependencies", Lifecycle::CommandRun),
        ];
        let rows: Vec<_> = CONTRIBUTIONS
            .iter()
            .map(|row| (row.operation, row.lifecycle))
            .collect();
        assert_eq!(rows, pinned);
        for row in CONTRIBUTIONS {
            assert!(std::ptr::eq(
                Contribution::find(row.operation).unwrap(),
                *row
            ));
        }
    }

    // A manifest ID longer than one segment must land where the SDK route writes it.
    #[test]
    fn diagnostics_host_plugin_operations_share_the_sdk_channel_mapping() {
        let long = format!("io.example.{}", "a".repeat(64));
        let fact = prepare(json!({"pluginId":long, "operation":"debugAdapter/start",
            "outcome":"finished", "durationMs":1}))
        .unwrap();
        assert_eq!(
            fact.channel,
            format!("plugins/{}/host", identity_segment(&long))
        );
        assert!(!fact.channel.contains(&long));
    }

    #[test]
    fn diagnostics_host_plugin_operations_reject_private_or_invalid_input() {
        let valid = json!({"pluginId":"io.example.contribution",
            "operation":"languageServer/start", "outcome":"failed", "stage":"resolve",
            "durationMs":2});
        for (key, value) in [
            ("operation", json!("private/query")),
            ("stage", json!("private")),
            ("stage", Value::Null),
            ("outcome", json!("finished")),
            ("outcome", json!("cancelled")),
            ("message", json!("private secret")),
            ("durationMs", json!(-1)),
            ("durationMs", json!(MAX_SAFE_INTEGER + 1)),
            ("operationId", json!("private secret")),
            ("operationId", json!("")),
        ] {
            let mut input = valid.clone();
            input[key] = value;
            let error = prepare(input).unwrap_err();
            assert_eq!(error.code, -32064, "{key}");
            assert!(!serde_json::to_string(&error).unwrap().contains("private"));
        }
        for key in ["pluginId", "operation", "outcome", "stage", "durationMs"] {
            let mut input = valid.clone();
            input.as_object_mut().unwrap().remove(key);
            assert_eq!(prepare(input).unwrap_err().code, -32064, "{key}");
        }
        // Optional fields are absent or a value; `null` is neither.
        let finished = json!({"pluginId":"io.example.contribution",
            "operation":"languageServer/start", "outcome":"finished", "durationMs":2});
        assert!(prepare(finished.clone()).is_ok());
        for key in ["stage", "operationId"] {
            let mut input = finished.clone();
            input[key] = Value::Null;
            assert_eq!(prepare(input).unwrap_err().code, -32064, "{key}");
        }
    }

    // The first terminal path takes the attempt; later paths and abandoned slots
    // record nothing.
    #[test]
    fn diagnostics_host_plugin_operations_attempt_slot_ends_once() {
        let handoff = AttemptHandoff {
            plugin_id: "io.example.lsp".into(),
            operation_id: "attempt-9".into(),
            elapsed_ms: 40,
        };
        let slot = Attempt::slot(&LANGUAGE_SERVER_START, handoff);
        let taken = slot.lock().unwrap().take().unwrap();
        assert!(std::ptr::eq(taken.contribution, &LANGUAGE_SERVER_START));
        assert_eq!(taken.plugin_id, "io.example.lsp");
        assert_eq!(taken.host_elapsed_ms, 40);
        assert_eq!(taken.operation_id, "attempt-9");
        finish(&slot, Some(Stage::Exit));
        assert!(slot.lock().unwrap().is_none());

        let none = Attempt::none();
        finish(&none, None);
        abandon(&none);
        assert!(none.lock().unwrap().is_none());
    }

    // The shared fixture is the contract example in rust-core-api.md.
    #[test]
    fn diagnostics_host_plugin_operations_match_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/diagnostics/engine-logging-v2.json"
        ))
        .unwrap();
        for case in fixture["hostOperations"].as_array().unwrap() {
            let result = prepare(case["payload"].clone());
            match case.get("event").and_then(Value::as_str) {
                Some(event) => {
                    let fact = result.unwrap();
                    assert_eq!(fact.event, event);
                    assert_eq!(fact.channel, case["channel"].as_str().unwrap());
                    assert_eq!(fact.fields.get("code"), case.get("code"));
                }
                None => assert_eq!(
                    i64::from(result.unwrap_err().code),
                    case["rejected"].as_i64().unwrap()
                ),
            }
        }
    }
}
