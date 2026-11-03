//! Bounded process-owned handoff of catalog facts to the host's single log writer.

use super::catalog::event_by_id;
use super::channel::LogError;
use super::record::{prepare_catalog_event, LogLevel, StructuredLogEvent};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, OnceLock};

const MAX_EVENTS: usize = 256;
static QUEUE: OnceLock<Mutex<CoreEventQueue>> = OnceLock::new();

/// Normalized fact ready for a host to assign its own session sequence.
#[derive(Debug, Clone, Serialize)]
pub struct CoreEvent {
    /// UTC observation time; the process queue owns the wall clock at this boundary.
    pub ts: String,
    /// Canonical directory severity.
    pub level: LogLevel,
    /// Catalog identity owned by lithe-core.
    pub event: String,
    /// Channel derived exclusively from catalog fields.
    pub channel: String,
    /// Optional correlation inherited from the owning operation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub op: Option<String>,
    /// Redacted, validated scalar disk fields.
    pub fields: BTreeMap<String, Value>,
}

/// One atomic queue snapshot; subsequent records belong to the next drain.
#[derive(Debug, Serialize)]
pub struct DrainedCoreEvents {
    /// At most 256 normalized facts, in observation order.
    pub events: Vec<CoreEvent>,
    /// Overflow or duplicate facts suppressed since the previous drain.
    pub dropped: u64,
}

#[derive(Default)]
struct CoreEventQueue {
    events: VecDeque<CoreEvent>,
    dropped: u64,
}

impl CoreEventQueue {
    fn record(&mut self, event: CoreEvent) {
        // Repeated inaccessible-directory facts cannot fill the queue. The scan
        // is bounded by MAX_EVENTS and needs no second, independently growing set.
        if self.events.len() == MAX_EVENTS
            || self.events.iter().any(|old| {
                old.event == event.event
                    && old.channel == event.channel
                    && old.fields == event.fields
                    && old.op == event.op
            })
        {
            self.dropped = self.dropped.saturating_add(1);
        } else {
            self.events.push_back(event);
        }
    }

    fn drain(&mut self) -> DrainedCoreEvents {
        DrainedCoreEvents {
            events: self.events.drain(..).collect(),
            dropped: std::mem::take(&mut self.dropped),
        }
    }
}

/// Validates owner, normalizes private input, and enqueues without filesystem I/O.
/// Invalid facts return their logging contract error and never enter the queue.
pub fn record(
    event: &str,
    fields: BTreeMap<String, Value>,
    op: Option<String>,
) -> Result<(), LogError> {
    let fact = prepare(event, fields, op)?;
    QUEUE
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .record(fact);
    Ok(())
}

fn prepare(
    event: &str,
    fields: BTreeMap<String, Value>,
    op: Option<String>,
) -> Result<CoreEvent, LogError> {
    let metadata =
        event_by_id(event).ok_or_else(|| LogError::new(-32053, "Unknown catalog event"))?;
    if metadata.owner != "lithe-core" {
        return Err(LogError::new(-32059, "Core event owner mismatch"));
    }
    let mut input = StructuredLogEvent {
        ts: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        level: metadata.level,
        seq: 0,
        event: event.into(),
        op,
        msg: String::new(),
        fields,
    };
    let channel = prepare_catalog_event(&mut input, &json!({}))?;
    Ok(CoreEvent {
        ts: input.ts,
        level: input.level,
        event: input.event,
        channel,
        op: input.op,
        fields: input.fields,
    })
}

/// Drains all pending facts and resets the overflow counter in one short lock.
pub fn drain() -> DrainedCoreEvents {
    QUEUE
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .drain()
}

/// Records a known category-only cleanup fact; invalid declarations count as lost
/// evidence instead of silently disappearing or falling back to a second writer.
pub(crate) fn cleanup_failed(event: &str, category: &str) {
    if record(
        event,
        if event == "app.workspace.scratch_cleanup_failed" {
            BTreeMap::from([
                ("error".into(), json!("Scratch cleanup failed")),
                ("error_code".into(), json!(category)),
                ("error_domain".into(), json!("io")),
            ])
        } else {
            BTreeMap::from([("failure_code".into(), json!(category))])
        },
        None,
    )
    .is_err()
    {
        note_dropped();
    }
}

/// Records only workspace-relative traversal identity and a stable Core category.
pub(crate) fn directory_skipped(event: &str, path: &str, code: &crate::protocol::ErrorCode) {
    let category = serde_json::to_value(code).expect("Core error category encodes");
    if record(
        event,
        BTreeMap::from([
            ("path".into(), json!(path)),
            ("error".into(), json!("Directory traversal failed")),
            ("error_code".into(), category),
            ("error_domain".into(), json!("core")),
        ]),
        None,
    )
    .is_err()
    {
        note_dropped();
    }
}

fn note_dropped() {
    let mut queue = QUEUE
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    queue.dropped = queue.dropped.saturating_add(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_bounds_deduplicates_and_resets_drain() {
        let mut queue = CoreEventQueue::default();
        for i in 0..300 {
            let fact = prepare(
                "app.workspace.directory_skipped",
                BTreeMap::from([
                    ("path".into(), json!(format!("src/{i}"))),
                    ("error".into(), json!("Directory traversal failed")),
                    ("error_code".into(), json!("permission_denied")),
                    ("error_domain".into(), json!("core")),
                ]),
                None,
            )
            .unwrap();
            queue.record(fact.clone());
            queue.record(fact);
        }
        let snapshot = queue.drain();
        assert_eq!(snapshot.events.len(), MAX_EVENTS);
        assert_eq!(snapshot.dropped, 600 - MAX_EVENTS as u64);
        assert_eq!(snapshot.events[0].channel, "app");
        assert!(queue.drain().events.is_empty());
        assert_eq!(queue.drain().dropped, 0);
    }

    #[test]
    fn remote_failure_categories_never_contain_peer_details() {
        use lithe_remote::client::session::ClientError;
        use lithe_remote::protocol::{ErrorCode, RemoteError};
        for (error, expected) in [
            (ClientError::Timeout, "timeout"),
            (
                ClientError::Disconnected {
                    diagnostics: "/private/address".into(),
                },
                "closed",
            ),
            (ClientError::Protocol("private payload".into()), "protocol"),
            (
                ClientError::Remote(RemoteError::new(
                    ErrorCode::PermissionDenied,
                    "private scratch",
                )),
                "remote_permission_denied",
            ),
        ] {
            assert_eq!(client_failure_category(&error), expected);
        }
        let safe = prepare(
            "app.workspace.scratch_cleanup_failed",
            BTreeMap::from([
                ("error".into(), json!("Scratch cleanup failed")),
                ("error_code".into(), json!("PermissionDenied")),
                ("error_domain".into(), json!("io")),
            ]),
            None,
        )
        .unwrap();
        assert_eq!(safe.channel, "app");
    }

    #[test]
    fn queue_rejects_non_core_owner_and_invalid_fields() {
        assert_eq!(
            prepare("app.font.missing", BTreeMap::new(), None)
                .unwrap_err()
                .code,
            -32059
        );
        assert_eq!(
            prepare("missing.event.id", BTreeMap::new(), None)
                .unwrap_err()
                .code,
            -32053
        );
        assert!(prepare(
            "app.workspace.scratch_cleanup_failed",
            BTreeMap::from([("failure_code".into(), json!({}))]),
            None
        )
        .is_err());
    }
}

/// Stable transport/protocol category; never copies a peer message or address.
pub(crate) fn client_failure_category(
    error: &lithe_remote::client::session::ClientError,
) -> String {
    use lithe_remote::client::session::ClientError;
    match error {
        ClientError::Timeout => "timeout".into(),
        ClientError::Disconnected { .. } => "closed".into(),
        ClientError::Transport(_) => "transport".into(),
        ClientError::Spawn(_) => "spawn".into(),
        ClientError::Protocol(_) => "protocol".into(),
        ClientError::Remote(error) => format!(
            "remote_{}",
            serde_json::to_value(error.code)
                .expect("protocol code encodes")
                .as_str()
                .expect("protocol code is a token")
                .to_ascii_lowercase()
        ),
    }
}
