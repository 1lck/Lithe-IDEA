//! Bounded process-owned handoff of catalog facts to the host's single log writer,
//! with a coalesced wake so facts recorded without other host activity still
//! reach the writer without polling.

use super::catalog::event_by_id;
use super::channel::LogError;
use super::record::{prepare_catalog_event, LogLevel, StructuredLogEvent};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock, RwLock};

const MAX_EVENTS: usize = 256;
static QUEUE: OnceLock<Mutex<CoreEventQueue>> = OnceLock::new();
// DEBUG facts are evidence the host keeps only while detailed diagnostics is
// active. Rejecting them here keeps them from occupying the bounded queue and
// evicting WARN/ERROR facts when nobody would write them.
static DEBUG_ENABLED: AtomicBool = AtomicBool::new(false);
static DEBUG_ROOTS: RwLock<Option<Vec<String>>> = RwLock::new(None);
// One process writer may own the pending-fact signal; a later install replaces it.
static WAKER: Mutex<Option<Waker>> = Mutex::new(None);
// Set by the first change after a drain and cleared by the next drain, so a
// burst of facts produces one host wakeup instead of one callback per fact.
static WAKE_REQUESTED: AtomicBool = AtomicBool::new(false);

/// Host callback that schedules the existing single writer to drain this queue.
///
/// `context` is an opaque host address. Core never dereferences it; it is only
/// passed back to `callback` while the installation lock is held.
#[derive(Clone, Copy)]
struct Waker {
    callback: unsafe extern "C" fn(*mut c_void),
    context: usize,
}

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
    fn is_empty(&self) -> bool {
        self.events.is_empty() && self.dropped == 0
    }

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
/// DEBUG facts the host has not enabled return `Ok` without entering the queue
/// or counting as dropped: the host asked not to receive them.
pub fn record(
    event: &str,
    fields: BTreeMap<String, Value>,
    op: Option<String>,
) -> Result<(), LogError> {
    if let Some(metadata) = event_by_id(event) {
        if !accepts(metadata.level, channel_root(metadata.channel)) {
            return Ok(());
        }
    }
    let fact = prepare(event, fields, op)?;
    #[cfg(test)]
    let Some(fact) = capture::divert(fact) else {
        return Ok(());
    };
    queue().record(fact);
    wake();
    Ok(())
}

fn queue() -> MutexGuard<'static, CoreEventQueue> {
    QUEUE
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

/// Signals the installed writer once per drain cycle. Must be called without
/// the queue lock: the host callback may take its own writer lock.
fn wake() {
    if WAKE_REQUESTED.swap(true, Ordering::AcqRel) {
        return;
    }
    // Holding WAKER across the call serializes every callback with removal, so
    // after `remove_waker` returns the host may release `context`.
    let waker = WAKER.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(waker) = *waker {
        // SAFETY: `install_waker`'s caller guarantees the callback is safe to
        // invoke from any thread with `context` until `remove_waker` returns.
        unsafe { (waker.callback)(waker.context as *mut c_void) }
    }
}

/// Installs the process writer's pending-fact callback, replacing any previous
/// writer. Facts already waiting are signaled immediately so a writer attached
/// after early Core work does not wait for unrelated activity.
///
/// # Safety
///
/// `callback` must not unwind, must not call back into Core synchronously, and
/// must be safe to run on any thread. `context` must stay valid until
/// [`remove_waker`] returns for the same context or another install replaces it.
pub(crate) unsafe fn install_waker(callback: unsafe extern "C" fn(*mut c_void), context: usize) {
    *WAKER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Waker { callback, context });
    // A request raised while no writer was installed was never delivered.
    WAKE_REQUESTED.store(false, Ordering::Release);
    if !queue().is_empty() {
        wake();
    }
}

/// Removes the callback only when `context` still owns it. Returns whether it
/// was removed; either way no callback for `context` is running afterward.
pub(crate) fn remove_waker(context: usize) -> bool {
    let mut waker = WAKER.lock().unwrap_or_else(|e| e.into_inner());
    if waker.is_some_and(|current| current.context == context) {
        *waker = None;
        true
    } else {
        false
    }
}

/// Reports whether `record` would keep a fact of this level and channel root.
/// Callers check it before building fields so rejected facts cost one branch.
pub(crate) fn accepts(level: LogLevel, root: &str) -> bool {
    if level != LogLevel::Debug {
        return true;
    }
    #[cfg(test)]
    if let Some(debug) = capture::debug_override() {
        return debug;
    }
    DEBUG_ENABLED.load(Ordering::Acquire)
        && DEBUG_ROOTS
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_none_or(|roots| roots.iter().any(|enabled| enabled == root))
}

/// Applies the host's detailed-diagnostics state; `roots: None` enables every root.
/// The default is disabled, so a host that never calls this receives no DEBUG facts.
pub(crate) fn configure(debug: bool, roots: Option<Vec<String>>) {
    *DEBUG_ROOTS.write().unwrap_or_else(|e| e.into_inner()) = roots;
    DEBUG_ENABLED.store(debug, Ordering::Release);
}

fn channel_root(channel: &str) -> &str {
    channel.split('/').next().unwrap_or(channel)
}

pub(super) fn prepare(
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
    let mut queue = queue();
    // Cleared under the queue lock: any fact recorded after this snapshot
    // raises a new wakeup, so no fact can wait behind a stale request.
    WAKE_REQUESTED.store(false, Ordering::Release);
    queue.drain()
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

pub(crate) fn note_dropped() {
    {
        let mut queue = queue();
        queue.dropped = queue.dropped.saturating_add(1);
    }
    // The drop summary is evidence too; it must reach disk without other activity.
    wake();
}

/// Hands a category-only recovery failure to the host; callers own the decision
/// to continue, so WARN describes degradation without exposing error payloads.
pub(crate) fn recovery_failed(event: &str, stage: &str, code: &str, domain: &str) {
    let fields = BTreeMap::from([
        ("stage".into(), json!(stage)),
        ("error".into(), json!("Core recovery failed")),
        ("error_code".into(), json!(code)),
        ("error_domain".into(), json!(domain)),
    ]);
    if record(event, fields, None).is_err() {
        note_dropped();
    }
}

/// Fixed-size cleanup summary: batch callers emit once rather than once per file.
#[derive(Default)]
pub(crate) struct StorageCleanup {
    count: i64,
    first: Option<std::io::ErrorKind>,
}

impl StorageCleanup {
    /// Missing staging files are normal after failed creation or concurrent eviction.
    pub(crate) fn observe(&mut self, result: std::io::Result<()>) {
        match result {
            Ok(()) => {}
            // log-exempt: Expected absence: creation may have failed before a file existed.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                self.count = self.count.saturating_add(1);
                self.first.get_or_insert(error.kind());
            }
        }
    }

    /// Removes a directory only when empty; retained contents belong to the caller.
    pub(crate) fn empty_directory(&mut self, path: &std::path::Path) {
        match std::fs::read_dir(path) {
            Ok(mut entries) => match entries.next() {
                None => self.observe(std::fs::remove_dir(path)),
                Some(Ok(_)) => {} // Retained snapshots/settings still own the directory.
                Some(Err(error)) => self.observe(Err(error)),
            },
            Err(error) => self.observe(Err(error)),
        }
    }

    /// Records one WARN at the storage recovery boundary, preserving normal results.
    pub(crate) fn finish(self, stage: &str) {
        if let Some(kind) = self.first {
            if record(
                "app.storage.cleanup_failed",
                BTreeMap::from([
                    ("stage".into(), json!(stage)),
                    ("count".into(), json!(self.count)),
                    ("error".into(), json!("Storage cleanup failed")),
                    ("error_code".into(), json!(format!("{kind:?}"))),
                    ("error_domain".into(), json!("io")),
                ]),
                None,
            )
            .is_err()
            {
                note_dropped();
            }
        }
    }
}

/// Test-only per-thread sink: traces recorded on the capturing thread bypass the
/// process queue, so parallel tests never observe or drain each other's facts.
#[cfg(test)]
pub(crate) mod capture {
    use super::CoreEvent;
    use std::cell::RefCell;

    struct Capture {
        debug: bool,
        events: Vec<CoreEvent>,
    }

    thread_local! {
        static CURRENT: RefCell<Option<Capture>> = const { RefCell::new(None) };
    }

    /// Runs `body` with this thread's facts captured; `debug` replaces the global gate.
    pub(crate) fn run<T>(debug: bool, body: impl FnOnce() -> T) -> (T, Vec<CoreEvent>) {
        let previous = CURRENT.with(|current| {
            current.borrow_mut().replace(Capture {
                debug,
                events: Vec::new(),
            })
        });
        let value = body();
        let captured =
            CURRENT.with(|current| std::mem::replace(&mut *current.borrow_mut(), previous));
        (
            value,
            captured.map(|capture| capture.events).unwrap_or_default(),
        )
    }

    pub(super) fn debug_override() -> Option<bool> {
        CURRENT.with(|current| current.borrow().as_ref().map(|capture| capture.debug))
    }

    pub(super) fn divert(event: CoreEvent) -> Option<CoreEvent> {
        CURRENT.with(|current| match current.borrow_mut().as_mut() {
            Some(capture) => {
                capture.events.push(event);
                None
            }
            None => Some(event),
        })
    }
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
            assert!(!remote_resource_already_gone(&error));
        }
        assert!(remote_resource_already_gone(&ClientError::Remote(
            RemoteError::new(ErrorCode::UnknownResource, "process 7 is not active")
        )));
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

/// Records a recovery failure whose cause is a [`CoreError`], keeping only its
/// stable code token so details and paths never reach the log.
pub(crate) fn core_failed(event: &str, stage: &str, error: &crate::protocol::CoreError) {
    let code = serde_json::to_value(&error.code).expect("Core error codes serialize");
    let code = code.as_str().expect("Core error codes serialize as tokens");
    recovery_failed(event, stage, code, "core");
}

/// True when a remote cleanup request found nothing to clean: the host prunes
/// exited processes, stopped watches and closed terminals, so `UnknownResource`
/// is the expected missing case rather than a cleanup failure.
pub(crate) fn remote_resource_already_gone(
    error: &lithe_remote::client::session::ClientError,
) -> bool {
    matches!(
        error,
        lithe_remote::client::session::ClientError::Remote(remote)
            if remote.code == lithe_remote::protocol::ErrorCode::UnknownResource
    )
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
