//! Windows-owned application logging, retention, diagnostics, and settings commands.

use chrono::{DateTime, Duration, FixedOffset, Local, Utc};
use lithe_core::diagnostics::logging as policy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, RwLock};
use std::thread;
use std::time::Duration as StdDuration;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_opener::OpenerExt;

const LOG_CONFIG_FILE: &str = "lithe-log-settings.json";
const CUSTOM_LOG_SUBDIRECTORY: [&str; 2] = ["Lithe", "logs"];
const MAX_LOG_FILE_BYTES: u64 = policy::MAX_LOG_FILE_BYTES;
const MAX_LOG_FILES_PER_DAY: usize = 5;
const MAX_LOG_LINE_BYTES: usize = policy::MAX_LOG_LINE_BYTES;
const MAX_LOG_READ_BYTES: u64 = 2 * 1024 * 1024;
const LOG_RETENTION_HOURS: i64 = 30 * 24;
const LOG_QUEUE_CAPACITY: usize = 8_000;
const LOG_QUEUE_NORMAL_CAPACITY: usize = 6_000;
const DIRECTORY_OPERATION_TIMEOUT: StdDuration = StdDuration::from_secs(2);
const WRITER_CONTROL_TIMEOUT: StdDuration = StdDuration::from_secs(10);
const WRITER_FLUSH_INTERVAL: StdDuration = StdDuration::from_secs(1);
const TRUNCATED_LOG_NOTICE: &str =
    "[Earlier log content omitted; open the log directory for the complete file.]\n";
const CONTROL_PENDING: u8 = 0;
const CONTROL_EXECUTING: u8 = 1;
const CONTROL_CANCELLED: u8 = 2;
const CONTROL_COMPLETE: u8 = 3;

thread_local! {
    static IS_LOG_WRITER_THREAD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static PANIC_HOOK_ACTIVE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

struct PanicHookGuard;

impl PanicHookGuard {
    fn enter() -> Option<Self> {
        PANIC_HOOK_ACTIVE.with(|active| {
            if active.replace(true) {
                None
            } else {
                Some(Self)
            }
        })
    }
}

impl Drop for PanicHookGuard {
    fn drop(&mut self) {
        PANIC_HOOK_ACTIVE.with(|active| active.set(false));
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {
    fn parse(value: &str) -> Self {
        match value.to_ascii_lowercase().as_str() {
            "debug" | "trace" => Self::Debug,
            "warn" | "warning" => Self::Warn,
            "error" | "fatal" => Self::Error,
            _ => Self::Info,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Debug => "DEBUG",
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }
}

#[derive(Clone, Debug)]
struct PreparedEvent {
    timestamp: DateTime<FixedOffset>,
    level: LogLevel,
    scope: String,
    message: String,
    fields: BTreeMap<String, String>,
    key: String,
    sequence: u64,
}

impl PreparedEvent {
    fn new(
        level: LogLevel,
        scope: impl Into<String>,
        message: impl Into<String>,
        fields: BTreeMap<String, String>,
        sanitizer: &LogSanitizer,
    ) -> Self {
        let prepared = policy::prepare_log_event(policy::LogEventRequest {
            scope: scope.into(),
            message: message.into(),
            fields: fields
                .into_iter()
                .map(|(key, text)| {
                    let value = if text.starts_with('{') || text.starts_with('[') {
                        serde_json::from_str(&text).unwrap_or(Value::String(text))
                    } else {
                        Value::String(text)
                    };
                    (key, value)
                })
                .collect(),
        });
        let scope = prepared.scope;
        let message = sanitizer.sanitize_free_text(&prepared.message);
        let fields = prepared
            .fields
            .into_iter()
            .map(|(key, value)| (key, compact_json(&value)))
            .collect::<BTreeMap<_, _>>();
        let fields = fields
            .into_iter()
            .map(|(key, value)| {
                let key = snake_case_key(&key);
                let value = if is_sensitive_key(&key) {
                    "<redacted>".to_string()
                } else {
                    sanitizer.sanitize_field(&key, &value)
                };
                (key, value)
            })
            .collect::<BTreeMap<_, _>>();
        let key = format!("{}|{}|{}|{:?}", level.label(), scope, message, fields);
        Self {
            timestamp: Local::now().fixed_offset(),
            level,
            scope,
            message,
            fields,
            key,
            sequence: EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed),
        }
    }
}

#[derive(Debug)]
struct QueuedEvent {
    event: PreparedEvent,
    repeated: u64,
}

#[derive(Default)]
struct DroppedLines {
    debug: u64,
    info: u64,
    high_priority: u64,
}

struct QueueState {
    events: VecDeque<QueuedEvent>,
    controls: VecDeque<QueuedControl>,
    dropped: DroppedLines,
    write_failures: u64,
    dropped_total: u64,
    write_failures_total: u64,
    shutdown: bool,
}

impl Default for QueueState {
    fn default() -> Self {
        Self {
            events: VecDeque::new(),
            controls: VecDeque::new(),
            dropped: DroppedLines::default(),
            write_failures: 0,
            dropped_total: 0,
            write_failures_total: 0,
            shutdown: false,
        }
    }
}

enum Control {
    Switch {
        writer: ActiveWriter,
        previous_path: PathBuf,
        configured_path: Option<PathBuf>,
        fallback_reason: Option<String>,
        ticket: ControlTicket,
        reply: mpsc::Sender<Result<(), String>>,
    },
    Clear {
        ticket: ControlTicket,
        reply: mpsc::Sender<Result<ClearLogResult, String>>,
    },
    Flush {
        reply: mpsc::Sender<()>,
    },
    Shutdown {
        reply: mpsc::Sender<()>,
    },
}

#[derive(Clone)]
struct ControlTicket {
    state: Arc<AtomicU8>,
}

impl ControlTicket {
    fn new() -> Self {
        Self {
            state: Arc::new(AtomicU8::new(CONTROL_PENDING)),
        }
    }

    fn begin(&self) -> bool {
        self.state
            .compare_exchange(
                CONTROL_PENDING,
                CONTROL_EXECUTING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn cancel(&self) -> bool {
        self.state
            .compare_exchange(
                CONTROL_PENDING,
                CONTROL_CANCELLED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn complete(&self) {
        self.state.store(CONTROL_COMPLETE, Ordering::Release);
    }

    fn is_executing_or_complete(&self) -> bool {
        matches!(
            self.state.load(Ordering::Acquire),
            CONTROL_EXECUTING | CONTROL_COMPLETE
        )
    }
}

fn wait_for_control<T>(
    receiver: mpsc::Receiver<T>,
    ticket: &ControlTicket,
    operation: &str,
) -> Result<T, String> {
    wait_for_control_timeout(receiver, ticket, operation, WRITER_CONTROL_TIMEOUT)
}

fn wait_for_control_timeout<T>(
    receiver: mpsc::Receiver<T>,
    ticket: &ControlTicket,
    operation: &str,
    timeout: StdDuration,
) -> Result<T, String> {
    match receiver.recv_timeout(timeout) {
        Ok(result) => Ok(result),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            Err(format!("Log writer stopped while {operation}"))
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            if ticket.cancel() {
                return Err(format!("Timed out while {operation}"));
            }
            if ticket.is_executing_or_complete() {
                // Once execution begins, the operation must reach one definitive
                // result; returning early would allow persisted and runtime paths to diverge.
                receiver
                    .recv()
                    .map_err(|_| format!("Log writer stopped while {operation}"))
            } else {
                Err(format!("Timed out while {operation}"))
            }
        }
    }
}

struct QueuedControl {
    control: Control,
    pending_events: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct LogSettingsSnapshot {
    pub default_path: String,
    pub configured_path: Option<String>,
    pub effective_path: String,
    pub fallback_reason: Option<String>,
    pub diagnostic_enabled: bool,
    pub diagnostic_category: Option<String>,
    pub dropped_events: u64,
    pub write_failures: u64,
}

#[derive(Clone, Debug)]
struct RuntimeState {
    default_path: PathBuf,
    configured_path: Option<PathBuf>,
    effective_path: PathBuf,
    fallback_reason: Option<String>,
    diagnostic_enabled: bool,
    diagnostic_category: Option<String>,
    diagnostic_deadline: Option<std::time::Instant>,
    active_file_path: PathBuf,
}

impl RuntimeState {
    fn snapshot(&self) -> LogSettingsSnapshot {
        LogSettingsSnapshot {
            default_path: display_path(&self.default_path),
            configured_path: self.configured_path.as_ref().map(|path| display_path(path)),
            effective_path: display_path(&self.effective_path),
            fallback_reason: self.fallback_reason.clone(),
            diagnostic_enabled: self.diagnostic_enabled
                && self
                    .diagnostic_deadline
                    .is_some_and(|end| std::time::Instant::now() < end),
            diagnostic_category: self.diagnostic_category.clone(),
            dropped_events: 0,
            write_failures: 0,
        }
    }
}

struct SharedState {
    app: Option<AppHandle>,
    queue: Mutex<QueueState>,
    queue_ready: Condvar,
    writer: Mutex<ActiveWriter>,
    runtime: RwLock<RuntimeState>,
    panic_path: RwLock<PathBuf>,
    writer_alive: AtomicBool,
    sanitizer: LogSanitizer,
}

#[derive(Clone, Debug, Serialize)]
pub struct LogDirectoryChangeResult {
    pub settings: LogSettingsSnapshot,
    pub previous_custom_path: Option<String>,
    pub previous_log_bytes: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct ClearLogResult {
    pub deleted_files: usize,
    pub freed_bytes: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct LitheLogFileResponse {
    pub path: String,
    pub content: String,
    pub target_line: usize,
    pub truncated: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct HostLogConfig {
    custom_root: Option<String>,
}

#[derive(Default)]
struct StartupNotes {
    config_warning: Option<String>,
    cleanup_warnings: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogSelection {
    pub category: Option<String>,
    pub minimum_level: Option<String>,
    pub session: Option<String>,
    pub search: Option<String>,
    pub since: Option<String>,
    pub until: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogTimeline {
    pub content: String,
    pub truncated: bool,
    pub matched_lines: usize,
}

pub struct CollectedLog {
    pub relative_path: String,
    pub category: String,
    pub text: String,
}

pub struct LogManager {
    shared: Arc<SharedState>,
    config_path: PathBuf,
    session_id: String,
    config_update: Mutex<()>,
    pending_previous_custom: Mutex<Option<PathBuf>>,
    degraded_reason: Option<String>,
}

impl LogManager {
    pub fn initialize(app: &AppHandle) -> Result<Arc<Self>, String> {
        let default_path = app
            .path()
            .app_log_dir()
            .map_err(|error| format!("Unable to resolve the default log directory: {error}"))?;
        let config_directory = app.path().app_config_dir().map_err(|error| {
            format!("Unable to resolve the log configuration directory: {error}")
        })?;
        let config_path = config_directory.join(LOG_CONFIG_FILE);
        fs::create_dir_all(&default_path)
            .map_err(|error| format!("Unable to create the default log directory: {error}"))?;

        let (config, config_warning) = read_host_config(&config_path);
        let configured_path = config
            .custom_root
            .as_deref()
            .map(PathBuf::from)
            .map(|root| derive_custom_log_path(&root));
        let (effective_path, fallback_reason) = match configured_path.as_ref() {
            Some(path) => match probe_directory_with_timeout(path.clone()) {
                Ok(()) => (path.clone(), None),
                Err(reason) => (default_path.clone(), Some(reason)),
            },
            None => (default_path.clone(), None),
        };

        let mut notes = StartupNotes {
            config_warning,
            cleanup_warnings: Vec::new(),
        };
        for path in unique_paths([default_path.clone(), effective_path.clone()]) {
            match cleanup_expired_logs_with_timeout(path.clone(), None) {
                Ok(warnings) => notes.cleanup_warnings.extend(warnings),
                Err(reason) => notes
                    .cleanup_warnings
                    .push(format!("directory={} reason={reason}", display_path(&path))),
            }
        }

        let session_id = create_session_id();
        let writer = ActiveWriter::open(effective_path.clone(), session_id.clone())?;
        if let Err(reason) = writer.enforce_budget() {
            notes.cleanup_warnings.push(reason);
        }
        let active_file_path = writer.path().to_path_buf();
        let panic_path = panic_sidecar_path(&effective_path, &session_id);
        let shared = Arc::new(SharedState {
            app: Some(app.clone()),
            queue: Mutex::new(QueueState::default()),
            queue_ready: Condvar::new(),
            writer: Mutex::new(writer),
            runtime: RwLock::new(RuntimeState {
                default_path,
                configured_path,
                effective_path,
                fallback_reason: fallback_reason.clone(),
                diagnostic_enabled: false,
                diagnostic_category: None,
                diagnostic_deadline: None,
                active_file_path,
            }),
            panic_path: RwLock::new(panic_path),
            writer_alive: AtomicBool::new(true),
            sanitizer: LogSanitizer::new(),
        });

        let manager = Arc::new(Self {
            shared: shared.clone(),
            config_path,
            session_id,
            config_update: Mutex::new(()),
            pending_previous_custom: Mutex::new(None),
            degraded_reason: None,
        });
        spawn_writer(shared, manager.session_id.clone())?;
        manager.install_panic_hook();

        let mut start_fields = BTreeMap::new();
        start_fields.insert("version".into(), app.package_info().version.to_string());
        start_fields.insert("platform".into(), "windows".into());
        manager.emit(LogLevel::Info, "session", "session started", start_fields);
        if let Some(reason) = fallback_reason {
            let snapshot = manager.snapshot();
            manager.emit(
                LogLevel::Warn,
                "log.writer",
                "fallback_to_default",
                BTreeMap::from([
                    ("reason".into(), reason),
                    (
                        "configured_dir".into(),
                        snapshot.configured_path.unwrap_or_default(),
                    ),
                    ("effective_dir".into(), snapshot.effective_path),
                ]),
            );
        }
        if let Some(warning) = notes.config_warning {
            manager.emit(
                LogLevel::Warn,
                "log.config",
                "invalid log configuration; using defaults",
                BTreeMap::from([("details".into(), warning)]),
            );
        }
        for warning in notes.cleanup_warnings {
            manager.emit(
                LogLevel::Warn,
                "log.cleanup",
                "cleanup skipped",
                BTreeMap::from([("details".into(), warning)]),
            );
        }
        let previous_panics =
            count_previous_panic_sidecars(&manager.effective_path(), &manager.session_id);
        if previous_panics > 0 {
            manager.emit(
                LogLevel::Warn,
                "log.writer",
                "previous session panic logs found",
                BTreeMap::from([(
                    "previous_session_panics".into(),
                    previous_panics.to_string(),
                )]),
            );
        }
        Ok(manager)
    }

    pub fn degraded(app: &AppHandle, reason: String) -> Arc<Self> {
        let fallback_root = if app.config().identifier == "app.lithe.windows.dev" {
            std::env::temp_dir().join(app.config().identifier.as_str())
        } else {
            std::env::temp_dir().join("Lithe")
        };
        let default_path = app
            .path()
            .app_log_dir()
            .unwrap_or_else(|_| fallback_root.join("logs"));
        let config_path = app
            .path()
            .app_config_dir()
            .unwrap_or(fallback_root)
            .join(LOG_CONFIG_FILE);
        Self::degraded_with_paths(default_path, config_path, reason)
    }

    fn degraded_with_paths(
        default_path: PathBuf,
        config_path: PathBuf,
        reason: String,
    ) -> Arc<Self> {
        let session_id = create_session_id();
        let unavailable_path = default_path.join("lithe.unavailable.log");
        let shared = Arc::new(SharedState {
            app: None,
            queue: Mutex::new(QueueState {
                shutdown: true,
                ..QueueState::default()
            }),
            queue_ready: Condvar::new(),
            writer: Mutex::new(ActiveWriter::disabled(
                default_path.clone(),
                session_id.clone(),
            )),
            runtime: RwLock::new(RuntimeState {
                default_path: default_path.clone(),
                configured_path: None,
                effective_path: default_path.clone(),
                fallback_reason: Some("logging_unavailable".into()),
                diagnostic_enabled: false,
                diagnostic_category: None,
                diagnostic_deadline: None,
                active_file_path: unavailable_path,
            }),
            panic_path: RwLock::new(PathBuf::new()),
            writer_alive: AtomicBool::new(false),
            sanitizer: LogSanitizer::new(),
        });
        Arc::new(Self {
            shared,
            config_path,
            session_id,
            config_update: Mutex::new(()),
            pending_previous_custom: Mutex::new(None),
            degraded_reason: Some(reason),
        })
    }

    pub fn snapshot(&self) -> LogSettingsSnapshot {
        let mut snapshot = self
            .shared
            .runtime
            .read()
            .map(|state| state.snapshot())
            .unwrap_or_else(|poisoned| poisoned.into_inner().snapshot());
        if let Ok(queue) = self.shared.queue.lock() {
            snapshot.dropped_events = queue.dropped_total;
            snapshot.write_failures = queue.write_failures_total;
        }
        snapshot
    }

    fn effective_path(&self) -> PathBuf {
        self.shared
            .runtime
            .read()
            .map(|state| state.effective_path.clone())
            .unwrap_or_else(|poisoned| poisoned.into_inner().effective_path.clone())
    }

    fn emit(
        &self,
        level: LogLevel,
        scope: impl Into<String>,
        message: impl Into<String>,
        fields: BTreeMap<String, String>,
    ) {
        let scope = scope.into();
        let diagnostic_enabled = self
            .shared
            .runtime
            .read()
            .map(|state| {
                state.snapshot().diagnostic_enabled
                    && state
                        .diagnostic_category
                        .as_ref()
                        .is_none_or(|category| category == policy::log_category(&scope))
            })
            .unwrap_or(false);
        if level == LogLevel::Debug && !diagnostic_enabled {
            return;
        }
        let event = PreparedEvent::new(level, scope, message, fields, &self.shared.sanitizer);
        if let Some(reason) = &self.degraded_reason {
            let reason = self.shared.sanitizer.sanitize_free_text(reason);
            eprint!(
                "[logging unavailable: {reason}] {}",
                format_event_line(&event, &self.session_id)
            );
            return;
        }
        enqueue_event(&self.shared, event);
    }

    pub fn emit_json(&self, level: &str, scope: String, message: String, payload: Option<Value>) {
        let fields = payload_fields(payload);
        self.emit(LogLevel::parse(level), scope, message, fields);
    }

    pub fn set_diagnostic_enabled(&self, enabled: bool) -> LogSettingsSnapshot {
        self.set_diagnostic_category(enabled, None)
    }

    pub fn set_diagnostic_category(
        &self,
        enabled: bool,
        category: Option<String>,
    ) -> LogSettingsSnapshot {
        if let Ok(mut state) = self.shared.runtime.write() {
            state.diagnostic_enabled = enabled;
            state.diagnostic_category =
                category.filter(|category| policy::LOG_CATEGORIES.contains(&category.as_str()));
            state.diagnostic_deadline = enabled.then(|| {
                std::time::Instant::now() + StdDuration::from_millis(policy::DIAGNOSTIC_DURATION_MS)
            });
        }
        self.emit(
            LogLevel::Info,
            "log.settings",
            if enabled {
                "diagnostic logging enabled"
            } else {
                "diagnostic logging disabled"
            },
            BTreeMap::new(),
        );
        self.snapshot()
    }

    pub fn set_custom_root(
        &self,
        custom_root: Option<PathBuf>,
    ) -> Result<LogDirectoryChangeResult, String> {
        self.ensure_available()?;
        let _update_guard = self
            .config_update
            .lock()
            .map_err(|_| "Log configuration update is unavailable".to_string())?;
        let target_path = custom_root
            .as_ref()
            .map(|root| derive_custom_log_path(root))
            .unwrap_or_else(|| {
                self.shared
                    .runtime
                    .read()
                    .map(|state| state.default_path.clone())
                    .unwrap_or_default()
            });
        probe_directory_with_timeout(target_path.clone())
            .map_err(|reason| format!("Log directory is not writable: {reason}"))?;

        let previous_configured_path = self
            .shared
            .runtime
            .read()
            .map(|state| state.configured_path.clone())
            .unwrap_or_default();
        let current_effective_path = self.effective_path();
        if previous_configured_path.as_ref() == custom_root.as_ref().map(|_| &target_path)
            && current_effective_path == target_path
        {
            return Ok(LogDirectoryChangeResult {
                settings: self.snapshot(),
                previous_custom_path: None,
                previous_log_bytes: 0,
            });
        }

        let prepared_writer = ActiveWriter::open(target_path.clone(), self.session_id.clone())?;
        prepared_writer.enforce_budget()?;
        let previous_config = read_host_config(&self.config_path).0;
        let next_config = HostLogConfig {
            custom_root: custom_root.as_ref().map(|path| display_path(path)),
        };
        if let Err(error) = write_host_config(&self.config_path, &next_config) {
            cleanup_aborted_writer(prepared_writer, custom_root.as_deref());
            return Err(error);
        }

        if let Err(error) =
            self.switch_writer(prepared_writer, custom_root.as_ref().map(|_| target_path))
        {
            let _ = write_host_config(&self.config_path, &previous_config);
            return Err(error);
        }

        let previous_log_bytes = previous_configured_path
            .as_ref()
            .map(|path| managed_log_stats(path).1)
            .unwrap_or(0);
        if let Ok(mut pending) = self.pending_previous_custom.lock() {
            *pending = previous_configured_path.clone();
        }
        Ok(LogDirectoryChangeResult {
            settings: self.snapshot(),
            previous_custom_path: previous_configured_path
                .as_ref()
                .map(|path| display_path(path)),
            previous_log_bytes,
        })
    }

    fn switch_writer(
        &self,
        writer: ActiveWriter,
        configured_path: Option<PathBuf>,
    ) -> Result<(), String> {
        let (reply_tx, reply_rx) = mpsc::channel();
        let ticket = ControlTicket::new();
        self.push_control(Control::Switch {
            writer,
            previous_path: self.effective_path(),
            configured_path,
            fallback_reason: None,
            ticket: ticket.clone(),
            reply: reply_tx,
        })?;
        wait_for_control(reply_rx, &ticket, "switching the log writer")?
    }

    pub fn resolve_previous_custom_cleanup(&self, delete: bool) -> Result<ClearLogResult, String> {
        self.ensure_available()?;
        let path = self
            .pending_previous_custom
            .lock()
            .map_err(|_| "Previous log directory state is unavailable".to_string())?
            .take();
        if !delete {
            return Ok(ClearLogResult {
                deleted_files: 0,
                freed_bytes: 0,
            });
        }
        path.map(|path| delete_managed_logs(&path, None))
            .transpose()?
            .ok_or_else(|| "There is no previous custom log directory to clean".to_string())
    }

    pub fn clear_current_logs(&self) -> Result<ClearLogResult, String> {
        self.ensure_available()?;
        let (reply_tx, reply_rx) = mpsc::channel();
        let ticket = ControlTicket::new();
        self.push_control(Control::Clear {
            ticket: ticket.clone(),
            reply: reply_tx,
        })?;
        wait_for_control(reply_rx, &ticket, "clearing logs")?
    }

    pub fn read_current_log(&self) -> Result<LitheLogFileResponse, String> {
        self.ensure_available()?;
        self.flush();
        let path = self
            .shared
            .runtime
            .read()
            .map_err(|_| "Log runtime state is unavailable".to_string())?
            .active_file_path
            .clone();
        let mut file =
            File::open(&path).map_err(|error| format!("Unable to open the log file: {error}"))?;
        let length = file
            .metadata()
            .map_err(|error| format!("Unable to inspect the log file: {error}"))?
            .len();
        let truncated = length > MAX_LOG_READ_BYTES;
        if truncated {
            file.seek(SeekFrom::End(-(MAX_LOG_READ_BYTES as i64)))
                .map_err(|error| format!("Unable to seek in the log file: {error}"))?;
        }
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .map_err(|error| format!("Unable to read the log file: {error}"))?;
        if truncated {
            if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
                bytes.drain(..=newline);
            }
        }
        let body = String::from_utf8_lossy(&bytes);
        let content = if truncated {
            format!("{TRUNCATED_LOG_NOTICE}{body}")
        } else {
            body.into_owned()
        };
        let target_line = content.lines().count().max(1);
        Ok(LitheLogFileResponse {
            path: display_path(&path),
            content,
            target_line,
            truncated,
        })
    }

    pub fn collect_logs(
        &self,
        selection: &LogSelection,
    ) -> Result<(Vec<CollectedLog>, bool), String> {
        self.ensure_available()?;
        let (tx, rx) = mpsc::channel();
        self.push_control(Control::Flush { reply: tx })?;
        rx.recv_timeout(WRITER_CONTROL_TIMEOUT)
            .map_err(|_| "Log snapshot timed out".to_string())?;
        let root = self.effective_path();
        let mut available = managed_log_files(&root);
        available.sort_by(|left, right| right.1.timestamp.cmp(&left.1.timestamp));
        let session = match selection.session.as_deref().unwrap_or("current") {
            "all" => None,
            "previous" => Some(
                available
                    .iter()
                    .find(|(_, parsed)| parsed.session_id != self.session_id)
                    .map(|(_, parsed)| parsed.session_id.clone())
                    .unwrap_or_else(|| "missing".into()),
            ),
            _ => Some(self.session_id.clone()),
        };
        let mut budget = policy::MAX_LOG_EXPORT_BYTES;
        let eligible = available
            .into_iter()
            .filter(|(path, parsed)| {
                let category = path
                    .parent()
                    .and_then(|p| p.file_name())
                    .and_then(|n| n.to_str())
                    .filter(|c| policy::LOG_CATEGORIES.contains(c))
                    .unwrap_or("application");
                selection.category.as_ref().is_none_or(|c| c == category)
                    && session.as_ref().is_none_or(|s| s == &parsed.session_id)
            })
            .collect::<Vec<_>>();
        let mut truncated = eligible.len() > 200;
        let mut collected = Vec::new();
        for (path, _) in eligible.into_iter().take(200) {
            let category = path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                .filter(|c| policy::LOG_CATEGORIES.contains(c))
                .unwrap_or("application")
                .to_string();
            if budget == 0 {
                truncated = true;
                break;
            }
            let mut file = File::open(&path).map_err(|e| e.to_string())?;
            let size = file.metadata().map_err(|e| e.to_string())?.len();
            let count = budget.min(MAX_LOG_READ_BYTES as usize);
            let offset = size.saturating_sub(count as u64);
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| e.to_string())?;
            let mut bytes = Vec::new();
            file.take(count as u64)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if offset > 0 {
                truncated = true;
                if let Some(newline) = bytes.iter().position(|b| *b == b'\n') {
                    bytes.drain(..=newline);
                }
            }
            budget = budget.saturating_sub(bytes.len());
            let text = policy::sanitize_log_text_unbounded(&String::from_utf8_lossy(&bytes));
            let result = policy::query_logs(policy::LogQueryRequest {
                sources: vec![policy::LogSource {
                    category: category.clone(),
                    text,
                }],
                category: selection.category.clone(),
                minimum_level: selection.minimum_level.clone(),
                session_id: None,
                search: selection.search.clone(),
                since: selection.since.clone(),
                until: selection.until.clone(),
                limit: Some(10000),
            });
            truncated |= result.truncated;
            if !result.content.is_empty() {
                let relative = path
                    .strip_prefix(&root)
                    .map_err(|_| "Invalid log path")?
                    .to_string_lossy()
                    .replace('\\', "/");
                collected.push(CollectedLog {
                    relative_path: format!("logs/{relative}"),
                    category,
                    text: format!("{}\n", result.content),
                });
            }
        }
        Ok((collected, truncated))
    }

    pub fn query_logs(&self, selection: LogSelection) -> Result<LogTimeline, String> {
        let (logs, truncated) = self.collect_logs(&selection)?;
        let result = policy::query_logs(policy::LogQueryRequest {
            sources: logs
                .into_iter()
                .map(|log| policy::LogSource {
                    category: log.category,
                    text: log.text,
                })
                .collect(),
            limit: Some(2000),
            ..Default::default()
        });
        Ok(LogTimeline {
            content: result.content,
            truncated: truncated || result.truncated,
            matched_lines: result.matched_lines,
        })
    }

    /// Returns the directory a diagnostic bundle export should treat as the
    /// source of log and panic-sidecar files.
    pub(crate) fn export_log_directory(&self) -> PathBuf {
        self.effective_path()
    }

    fn flush(&self) {
        if self.degraded_reason.is_some() {
            return;
        }
        let (reply_tx, reply_rx) = mpsc::channel();
        if self
            .push_control(Control::Flush { reply: reply_tx })
            .is_ok()
        {
            let _ = reply_rx.recv_timeout(WRITER_CONTROL_TIMEOUT);
        }
    }

    pub fn shutdown(&self) {
        self.emit(
            LogLevel::Info,
            "session",
            "session ended",
            BTreeMap::from([("reason".into(), "normal".into())]),
        );
        let (reply_tx, reply_rx) = mpsc::channel();
        if self
            .push_control(Control::Shutdown { reply: reply_tx })
            .is_ok()
        {
            let _ = reply_rx.recv_timeout(WRITER_CONTROL_TIMEOUT);
        }
    }

    fn ensure_available(&self) -> Result<(), String> {
        self.degraded_reason
            .as_ref()
            .map(|reason| Err(format!("Application file logging is unavailable: {reason}")))
            .unwrap_or(Ok(()))
    }

    fn push_control(&self, control: Control) -> Result<(), String> {
        let mut queue = self
            .shared
            .queue
            .lock()
            .map_err(|_| "Log writer queue is unavailable".to_string())?;
        if queue.shutdown {
            return Err("Log writer has stopped".to_string());
        }
        let pending_events = queue.events.len();
        queue.controls.push_back(QueuedControl {
            control,
            pending_events,
        });
        self.shared.queue_ready.notify_one();
        Ok(())
    }

    fn install_panic_hook(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if let Some(manager) = weak.upgrade() {
                manager.write_panic(info);
            }
            previous(info);
        }));
    }

    fn write_panic(&self, info: &std::panic::PanicHookInfo<'_>) {
        let Some(_guard) = PanicHookGuard::enter() else {
            return;
        };
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .copied()
            .or_else(|| info.payload().downcast_ref::<String>().map(String::as_str))
            .unwrap_or("Rust panic");
        let mut fields = BTreeMap::new();
        if let Some(location) = info.location() {
            fields.insert(
                "location".into(),
                format!(
                    "{}:{}:{}",
                    location.file(),
                    location.line(),
                    location.column()
                ),
            );
        }
        let backtrace = std::backtrace::Backtrace::force_capture()
            .to_string()
            .lines()
            .filter(|line| !line.trim().is_empty())
            .take(8)
            .collect::<Vec<_>>()
            .join("\n");
        if !backtrace.is_empty() {
            fields.insert("backtrace".into(), backtrace);
        }
        self.write_panic_event_unchecked(message, fields);
    }

    #[cfg(test)]
    fn write_panic_event(&self, message: &str, fields: BTreeMap<String, String>) {
        let Some(_guard) = PanicHookGuard::enter() else {
            return;
        };
        self.write_panic_event_unchecked(message, fields);
    }

    fn write_panic_event_unchecked(&self, message: &str, fields: BTreeMap<String, String>) {
        let event = PreparedEvent::new(
            LogLevel::Error,
            "runtime.rust.panic",
            message,
            fields,
            &self.shared.sanitizer,
        );
        let line = format_event_line(&event, &self.session_id);
        let is_writer_thread = IS_LOG_WRITER_THREAD.with(|flag| flag.get());
        if !is_writer_thread && self.shared.writer_alive.load(Ordering::Acquire) {
            if let Ok(mut writer) = self.shared.writer.try_lock() {
                if writer.write_preformatted(&line, true).is_ok() {
                    return;
                }
            }
        }
        let panic_path = self
            .shared
            .panic_path
            .read()
            .map(|path| path.clone())
            .unwrap_or_default();
        if panic_path.as_os_str().is_empty() {
            return;
        }
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(panic_path)
        {
            let _ = file.write_all(line.as_bytes());
            let _ = file.flush();
        }
    }
}

fn spawn_writer(shared: Arc<SharedState>, session_id: String) -> Result<(), String> {
    thread::Builder::new()
        .name("lithe-log-writer".into())
        .spawn(move || writer_loop(shared, session_id))
        .map(|_| ())
        .map_err(|error| format!("Unable to start the application log writer: {error}"))
}

fn writer_loop(shared: Arc<SharedState>, session_id: String) {
    IS_LOG_WRITER_THREAD.with(|flag| flag.set(true));
    loop {
        let work = {
            let mut queue = match shared.queue.lock() {
                Ok(queue) => queue,
                Err(poisoned) => poisoned.into_inner(),
            };
            if queue.controls.is_empty() && queue.events.is_empty() && !queue.shutdown {
                let result = shared
                    .queue_ready
                    .wait_timeout(queue, WRITER_FLUSH_INTERVAL);
                queue = match result {
                    Ok((queue, _)) => queue,
                    Err(poisoned) => poisoned.into_inner().0,
                };
            }
            take_writer_work(&mut queue)
        };

        match work {
            WriterWork::Event(queued, dropped, write_failures) => {
                if dropped.debug + dropped.info + dropped.high_priority > 0 {
                    let event = PreparedEvent::new(
                        LogLevel::Warn,
                        "log.writer",
                        "log lines dropped",
                        BTreeMap::from([
                            ("debug".into(), dropped.debug.to_string()),
                            ("info".into(), dropped.info.to_string()),
                            ("warn_error".into(), dropped.high_priority.to_string()),
                        ]),
                        &shared.sanitizer,
                    );
                    write_event(&shared, &event, &session_id, true);
                }
                if write_failures > 0 {
                    let event = PreparedEvent::new(
                        LogLevel::Warn,
                        "log.writer",
                        "write failures recovered",
                        BTreeMap::from([("write_failures".into(), write_failures.to_string())]),
                        &shared.sanitizer,
                    );
                    write_event(&shared, &event, &session_id, true);
                }
                write_event(
                    &shared,
                    &queued.event,
                    &session_id,
                    queued.event.level >= LogLevel::Warn,
                );
                if queued.repeated > 0 {
                    let event = PreparedEvent::new(
                        queued.event.level,
                        "log.writer",
                        "last message repeated",
                        BTreeMap::from([("count".into(), queued.repeated.to_string())]),
                        &shared.sanitizer,
                    );
                    write_event(
                        &shared,
                        &event,
                        &session_id,
                        queued.event.level >= LogLevel::Warn,
                    );
                }
            }
            WriterWork::Control(control) => match control {
                Control::Switch {
                    mut writer,
                    previous_path,
                    configured_path,
                    fallback_reason,
                    ticket,
                    reply,
                } => {
                    if !ticket.begin() {
                        cleanup_aborted_writer(writer, None);
                        let _ = reply.send(Err("Log directory switch was cancelled".into()));
                        continue;
                    }
                    let result = (|| {
                        if let Ok(mut current) = shared.writer.lock() {
                            let switching = PreparedEvent::new(
                                LogLevel::Info,
                                "log.writer",
                                "switching log directory",
                                BTreeMap::from([(
                                    "effective_dir".into(),
                                    display_path(&writer.directory),
                                )]),
                                &shared.sanitizer,
                            );
                            let _ = current.write_preformatted(
                                &format_event_line(&switching, &session_id),
                                true,
                            );
                            std::mem::swap(&mut *current, &mut writer);
                            let switched = PreparedEvent::new(
                                LogLevel::Info,
                                "log.writer",
                                "log directory switched; session continues",
                                BTreeMap::from([(
                                    "previous_directory".into(),
                                    display_path(&previous_path),
                                )]),
                                &shared.sanitizer,
                            );
                            let _ = current.write_preformatted(
                                &format_event_line(&switched, &session_id),
                                true,
                            );
                            let mut runtime = shared
                                .runtime
                                .write()
                                .unwrap_or_else(|poisoned| poisoned.into_inner());
                            runtime.configured_path = configured_path;
                            runtime.effective_path = current.directory.clone();
                            runtime.active_file_path = current.path().to_path_buf();
                            runtime.fallback_reason = fallback_reason;
                            if let Ok(mut panic_path) = shared.panic_path.write() {
                                *panic_path = panic_sidecar_path(&current.directory, &session_id);
                            }
                            Ok(())
                        } else {
                            Err("Log writer is unavailable".to_string())
                        }
                    })();
                    if result.is_err() {
                        cleanup_aborted_writer(writer, None);
                    }
                    ticket.complete();
                    let _ = reply.send(result);
                }
                Control::Clear { ticket, reply } => {
                    if !ticket.begin() {
                        let _ = reply.send(Err("Log clearing was cancelled".into()));
                        continue;
                    }
                    let result = clear_active_writer(&shared, &session_id);
                    ticket.complete();
                    let _ = reply.send(result);
                }
                Control::Flush { reply } => {
                    flush_or_fallback(&shared, &session_id);
                    let _ = reply.send(());
                }
                Control::Shutdown { reply } => {
                    if let Ok(mut writer) = shared.writer.lock() {
                        let _ = writer.close();
                    }
                    shared.writer_alive.store(false, Ordering::Release);
                    if let Ok(mut queue) = shared.queue.lock() {
                        queue.shutdown = true;
                    }
                    let _ = reply.send(());
                    break;
                }
            },
            WriterWork::Flush => {
                flush_or_fallback(&shared, &session_id);
            }
            WriterWork::Stop => break,
        }
    }
    shared.writer_alive.store(false, Ordering::Release);
}

enum WriterWork {
    Event(QueuedEvent, DroppedLines, u64),
    Control(Control),
    Flush,
    Stop,
}

fn take_writer_work(queue: &mut QueueState) -> WriterWork {
    if queue
        .controls
        .front()
        .is_some_and(|control| control.pending_events == 0)
    {
        if let Some(control) = queue.controls.pop_front() {
            return WriterWork::Control(control.control);
        }
    }
    if let Some(event) = queue.events.pop_front() {
        for control in &mut queue.controls {
            control.pending_events = control.pending_events.saturating_sub(1);
        }
        let dropped = std::mem::take(&mut queue.dropped);
        let write_failures = std::mem::take(&mut queue.write_failures);
        return WriterWork::Event(event, dropped, write_failures);
    }
    if queue.shutdown {
        WriterWork::Stop
    } else {
        WriterWork::Flush
    }
}

fn enqueue_event(shared: &Arc<SharedState>, event: PreparedEvent) {
    let mut queue = shared
        .queue
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if queue.shutdown {
        return;
    }
    let can_merge = queue
        .controls
        .back()
        .is_none_or(|control| control.pending_events < queue.events.len());
    if let Some(last) = queue.events.back_mut() {
        if can_merge && last.event.key == event.key {
            last.repeated = last.repeated.saturating_add(1);
            last.event.fields.insert(
                "first_timestamp".into(),
                last.event.timestamp.with_timezone(&Utc).to_rfc3339(),
            );
            last.event.fields.insert(
                "last_timestamp".into(),
                event.timestamp.with_timezone(&Utc).to_rfc3339(),
            );
            return;
        }
    }
    let capacity = if event.level >= LogLevel::Warn {
        LOG_QUEUE_CAPACITY
    } else {
        LOG_QUEUE_NORMAL_CAPACITY
    };
    if queue.events.len() >= capacity {
        if event.level == LogLevel::Debug
            || (!evict_oldest(&mut queue, LogLevel::Debug)
                && !evict_oldest(&mut queue, LogLevel::Info)
                && !(event.level == LogLevel::Error && evict_oldest(&mut queue, LogLevel::Warn)))
        {
            queue.dropped_total = queue.dropped_total.saturating_add(1);
            // Error storms must not turn logging into synchronous UI disk I/O.
            // Counts are exported even if no later record can be accepted.
            match event.level {
                LogLevel::Debug => queue.dropped.debug = queue.dropped.debug.saturating_add(1),
                LogLevel::Info => queue.dropped.info = queue.dropped.info.saturating_add(1),
                _ => queue.dropped.high_priority = queue.dropped.high_priority.saturating_add(1),
            }
            return;
        }
    }
    queue.events.push_back(QueuedEvent { event, repeated: 0 });
    shared.queue_ready.notify_one();
}

fn evict_oldest(queue: &mut QueueState, level: LogLevel) -> bool {
    if let Some(index) = queue
        .events
        .iter()
        .position(|entry| entry.event.level == level)
    {
        if let Some(removed) = queue.events.remove(index) {
            queue.dropped_total = queue.dropped_total.saturating_add(1);
            for control in &mut queue.controls {
                if index < control.pending_events {
                    control.pending_events = control.pending_events.saturating_sub(1);
                }
            }
            match removed.event.level {
                LogLevel::Debug => queue.dropped.debug = queue.dropped.debug.saturating_add(1),
                LogLevel::Info => queue.dropped.info = queue.dropped.info.saturating_add(1),
                _ => queue.dropped.high_priority = queue.dropped.high_priority.saturating_add(1),
            }
        }
        true
    } else {
        false
    }
}

fn write_event(
    shared: &Arc<SharedState>,
    event: &PreparedEvent,
    session_id: &str,
    flush: bool,
) -> bool {
    let line = format_event_line(event, session_id);
    let result = shared.writer.lock().map_err(|_| ()).and_then(|mut writer| {
        let previous_path = writer.path().to_path_buf();
        writer
            .write_routed(&line, policy::log_category(&event.scope), flush)
            .map_err(|_| ())?;
        let next_path = writer.path().to_path_buf();
        if previous_path != next_path {
            if let Ok(mut runtime) = shared.runtime.write() {
                runtime.active_file_path = next_path;
            }
        }
        Ok(())
    });
    if result.is_err() {
        if fallback_runtime_to_default(shared, session_id, Some(&line)) {
            return true;
        }
        if let Ok(mut queue) = shared.queue.lock() {
            queue.write_failures = queue.write_failures.saturating_add(1);
            queue.write_failures_total = queue.write_failures_total.saturating_add(1);
        }
        false
    } else {
        true
    }
}

fn flush_or_fallback(shared: &Arc<SharedState>, session_id: &str) {
    let failed = shared
        .writer
        .lock()
        .map(|mut writer| writer.flush().is_err())
        .unwrap_or(true);
    if failed {
        let _ = fallback_runtime_to_default(shared, session_id, None);
    }
}

fn fallback_runtime_to_default(
    shared: &Arc<SharedState>,
    session_id: &str,
    pending_line: Option<&str>,
) -> bool {
    let (default_path, effective_path, configured_path) = match shared.runtime.read() {
        Ok(runtime) if runtime.effective_path != runtime.default_path => (
            runtime.default_path.clone(),
            runtime.effective_path.clone(),
            runtime.configured_path.clone(),
        ),
        _ => return false,
    };
    let mut fallback_writer = match ActiveWriter::open(default_path.clone(), session_id.to_string())
    {
        Ok(writer) => writer,
        Err(_) => return false,
    };
    let fallback_event = PreparedEvent::new(
        LogLevel::Warn,
        "log.writer",
        "fallback_to_default",
        BTreeMap::from([
            ("reason".into(), "not_writable".into()),
            ("configured_dir".into(), display_path(&effective_path)),
            ("effective_dir".into(), display_path(&default_path)),
        ]),
        &shared.sanitizer,
    );
    if fallback_writer
        .write_preformatted(&format_event_line(&fallback_event, session_id), true)
        .is_err()
    {
        return false;
    }
    if let Some(line) = pending_line {
        let scope = line
            .split_once("[scope=")
            .and_then(|(_, tail)| tail.split_once(']'))
            .map(|(scope, _)| scope)
            .unwrap_or("application");
        if fallback_writer
            .write_routed(line, policy::log_category(scope), true)
            .is_err()
        {
            return false;
        }
    }
    let active_file_path = fallback_writer.path().to_path_buf();
    if let Ok(mut writer) = shared.writer.lock() {
        *writer = fallback_writer;
    } else {
        return false;
    }
    let snapshot = {
        let mut runtime = match shared.runtime.write() {
            Ok(runtime) => runtime,
            Err(poisoned) => poisoned.into_inner(),
        };
        runtime.configured_path = configured_path;
        runtime.effective_path = default_path.clone();
        runtime.active_file_path = active_file_path;
        runtime.fallback_reason = Some("not_writable".into());
        runtime.snapshot()
    };
    if let Ok(mut panic_path) = shared.panic_path.write() {
        *panic_path = panic_sidecar_path(&default_path, session_id);
    }
    if let Some(app) = &shared.app {
        let _ = app.emit("lithe-log-runtime-fallback", snapshot);
    }
    true
}

fn clear_active_writer(
    shared: &Arc<SharedState>,
    session_id: &str,
) -> Result<ClearLogResult, String> {
    let mut writer = shared
        .writer
        .lock()
        .map_err(|_| "Log writer is unavailable".to_string())?;
    writer.close()?;
    let result = delete_managed_logs(&writer.directory, None)?;
    *writer = ActiveWriter::open(writer.directory.clone(), session_id.to_string())?;
    let event = PreparedEvent::new(
        LogLevel::Info,
        "log.cleared",
        "logs cleared",
        BTreeMap::from([
            ("deleted_files".into(), result.deleted_files.to_string()),
            ("freed_bytes".into(), result.freed_bytes.to_string()),
        ]),
        &shared.sanitizer,
    );
    writer.write_preformatted(&format_event_line(&event, session_id), true)?;
    if let Ok(mut runtime) = shared.runtime.write() {
        runtime.active_file_path = writer.path().to_path_buf();
    }
    Ok(result)
}

struct ActiveWriter {
    directory: PathBuf,
    session_id: String,
    created_date: String,
    segment: u16,
    bytes_written: u64,
    path: PathBuf,
    file: Option<BufWriter<File>>,
    modules: BTreeMap<String, ActiveWriter>,
    routes_modules: bool,
    maintenance_bytes: u64,
}

impl ActiveWriter {
    fn disabled(directory: PathBuf, session_id: String) -> Self {
        Self {
            path: directory.join("lithe.unavailable.log"),
            directory,
            session_id,
            created_date: Local::now().format("%Y-%m-%d").to_string(),
            segment: 0,
            bytes_written: 0,
            file: None,
            modules: BTreeMap::new(),
            routes_modules: true,
            maintenance_bytes: 0,
        }
    }

    fn open(directory: PathBuf, session_id: String) -> Result<Self, String> {
        Self::open_at(directory, session_id, true)
    }

    fn open_at(
        directory: PathBuf,
        session_id: String,
        routes_modules: bool,
    ) -> Result<Self, String> {
        let storage = if routes_modules {
            directory.join("application")
        } else {
            directory.clone()
        };
        if storage
            .symlink_metadata()
            .is_ok_and(|m| m.file_type().is_symlink())
        {
            return Err("A module log directory cannot be a symbolic link".into());
        }
        fs::create_dir_all(&storage).map_err(|error| error.to_string())?;

        fs::create_dir_all(&directory)
            .map_err(|error| format!("Unable to create the log directory: {error}"))?;
        let now = Local::now();
        let created_date = now.format("%Y-%m-%d").to_string();
        enforce_daily_limit(&storage, &created_date, None)?;
        let segment = next_segment_number(&storage, &created_date, &session_id);
        let path = regular_log_path(&storage, &session_id, segment, now);
        let file = open_log_file(&path)?;
        Ok(Self {
            directory,
            session_id,
            created_date,
            segment,
            bytes_written: file.metadata().map(|metadata| metadata.len()).unwrap_or(0),
            path,
            file: Some(BufWriter::new(file)),
            modules: BTreeMap::new(),
            routes_modules,
            maintenance_bytes: 0,
        })
    }

    fn write_routed(&mut self, line: &str, category: &str, flush: bool) -> Result<(), String> {
        if category == "application" || !self.routes_modules {
            self.write_preformatted(line, flush)?;
        } else {
            if !self.modules.contains_key(category) {
                let writer = Self::open_at(
                    self.directory.join(category),
                    self.session_id.clone(),
                    false,
                )?;
                self.modules.insert(category.into(), writer);
            }
            self.modules
                .get_mut(category)
                .expect("module was inserted")
                .write_preformatted(line, flush)?;
        }
        self.maintenance_bytes += line.len() as u64;
        if self.maintenance_bytes >= 1024 * 1024 {
            self.maintenance_bytes = 0;
            self.enforce_budget()?;
        }
        Ok(())
    }

    fn enforce_budget(&self) -> Result<(), String> {
        let mut files = managed_log_files(&self.directory);
        files.sort_by(|left, right| left.1.timestamp.cmp(&right.1.timestamp));
        let mut total: u64 = files
            .iter()
            .map(|(p, _)| p.metadata().map(|m| m.len()).unwrap_or(0))
            .sum();
        let mut performance: u64 = files
            .iter()
            .filter(|(p, _)| p.parent() == Some(self.directory.join("performance").as_path()))
            .map(|(p, _)| p.metadata().map(|m| m.len()).unwrap_or(0))
            .sum();
        let active = std::iter::once(&self.path)
            .chain(self.modules.values().map(|w| &w.path))
            .collect::<Vec<_>>();
        for (path, parsed) in files {
            if active.contains(&&path) {
                continue;
            }
            let is_performance =
                path.parent() == Some(self.directory.join("performance").as_path());
            let expired = Utc::now().signed_duration_since(parsed.timestamp)
                >= Duration::hours(LOG_RETENTION_HOURS);
            if expired
                || total > policy::MAX_LOG_TOTAL_BYTES
                || (is_performance && performance > policy::MAX_PERFORMANCE_BYTES)
            {
                let bytes = path.metadata().map(|m| m.len()).unwrap_or(0);
                fs::remove_file(&path).map_err(|e| e.to_string())?;
                total = total.saturating_sub(bytes);
                if is_performance {
                    performance = performance.saturating_sub(bytes);
                }
            }
        }
        Ok(())
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn write_preformatted(&mut self, line: &str, flush: bool) -> Result<(), String> {
        let today = Local::now().format("%Y-%m-%d").to_string();
        if self.created_date != today
            || self.bytes_written.saturating_add(line.len() as u64) > MAX_LOG_FILE_BYTES
        {
            self.rotate()?;
        }
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| "Log file is closed".to_string())?;
        file.write_all(line.as_bytes())
            .map_err(|error| format!("Unable to write the log file: {error}"))?;
        self.bytes_written = self.bytes_written.saturating_add(line.len() as u64);
        if flush {
            file.flush()
                .map_err(|error| format!("Unable to flush the log file: {error}"))?;
        }
        Ok(())
    }

    fn rotate(&mut self) -> Result<(), String> {
        if let Some(mut file) = self.file.take() {
            file.flush().map_err(|e| e.to_string())?;
        }
        let now = Local::now();
        let date = now.format("%Y-%m-%d").to_string();
        self.segment = if date == self.created_date {
            self.segment.saturating_add(1)
        } else {
            1
        };
        self.created_date = date;
        let storage = if self.routes_modules {
            self.directory.join("application")
        } else {
            self.directory.clone()
        };
        enforce_daily_limit(&storage, &self.created_date, None)?;
        self.path = regular_log_path(&storage, &self.session_id, self.segment, now);
        self.file = Some(BufWriter::new(open_log_file(&self.path)?));
        self.bytes_written = 0;
        Ok(())
    }

    fn close(&mut self) -> Result<(), String> {
        for writer in self.modules.values_mut() {
            writer.close()?;
        }
        self.modules.clear();
        if let Some(mut file) = self.file.take() {
            file.flush()
                .map_err(|error| format!("Unable to flush the log file: {error}"))?;
        }
        Ok(())
    }

    fn flush(&mut self) -> Result<(), String> {
        for writer in self.modules.values_mut() {
            writer.flush()?;
        }
        if let Some(file) = self.file.as_mut() {
            file.flush()
                .map_err(|error| format!("Unable to flush the log file: {error}"))?;
        }
        Ok(())
    }
}

fn open_log_file(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("Unable to open the log file: {error}"))
}

fn regular_log_path(
    directory: &Path,
    session_id: &str,
    segment: u16,
    now: DateTime<Local>,
) -> PathBuf {
    let timestamp = now.format("%Y-%m-%dT%H-%M-%S%.3f%z");
    directory.join(format!("lithe.{timestamp}.{session_id}.{segment:03}.log"))
}

fn panic_sidecar_path(directory: &Path, session_id: &str) -> PathBuf {
    let timestamp = Local::now().format("%Y-%m-%dT%H-%M-%S%.3f%z");
    directory.join(format!("lithe.panic.{timestamp}.{session_id}.log"))
}

#[derive(Clone, Debug)]
struct ParsedLogFile {
    timestamp: DateTime<FixedOffset>,
    session_id: String,
    panic: bool,
}

fn log_file_regex() -> &'static Regex {
    static REGEX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r"^lithe\.(?:(panic)\.)?(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}[+-]\d{4})\.([A-Fa-f0-9]+)(?:\.(\d{3,5}))?\.log$",
        )
        .expect("the managed log filename regex is valid")
    })
}

fn parse_log_file_name(name: &str) -> Option<ParsedLogFile> {
    let captures = log_file_regex().captures(name)?;
    let timestamp =
        DateTime::parse_from_str(captures.get(2)?.as_str(), "%Y-%m-%dT%H-%M-%S%.3f%z").ok()?;
    Some(ParsedLogFile {
        timestamp,
        session_id: captures.get(3)?.as_str().to_string(),
        panic: captures.get(1).is_some(),
    })
}

fn cleanup_expired_logs_with_timeout(
    directory: PathBuf,
    active_path: Option<PathBuf>,
) -> Result<Vec<String>, String> {
    run_with_timeout(DIRECTORY_OPERATION_TIMEOUT, move || {
        cleanup_expired_logs(&directory, active_path.as_deref())
    })?
}

fn cleanup_expired_logs(
    directory: &Path,
    active_path: Option<&Path>,
) -> Result<Vec<String>, String> {
    if !directory.exists() {
        return Ok(Vec::new());
    }
    let mut warnings = Vec::new();
    let now = Local::now().fixed_offset();
    let entries = fs::read_dir(directory)
        .map_err(|error| format!("Unable to inspect the log directory: {error}"))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if active_path == Some(path.as_path()) || !path.is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !name.starts_with("lithe.") || !name.ends_with(".log") {
            continue;
        }
        let Some(parsed) = parse_log_file_name(name) else {
            warnings.push(format!("skipped_unparseable file={name}"));
            continue;
        };
        let age = now.signed_duration_since(parsed.timestamp);
        if age >= Duration::hours(LOG_RETENTION_HOURS) {
            if let Err(error) = fs::remove_file(&path) {
                warnings.push(format!("delete_failed file={name} error={error}"));
            }
        }
    }
    Ok(warnings)
}

fn enforce_daily_limit(
    directory: &Path,
    date: &str,
    active_path: Option<&Path>,
) -> Result<(), String> {
    let mut files = managed_log_files(directory)
        .into_iter()
        .filter(|(path, parsed)| {
            !parsed.panic
                && parsed.timestamp.format("%Y-%m-%d").to_string() == date
                && active_path != Some(path.as_path())
        })
        .collect::<Vec<_>>();
    files.sort_by(|left, right| left.1.timestamp.cmp(&right.1.timestamp));
    while files.len() >= MAX_LOG_FILES_PER_DAY {
        let (path, _) = files.remove(0);
        fs::remove_file(path)
            .map_err(|error| format!("Unable to enforce the daily log limit: {error}"))?;
    }
    Ok(())
}

fn managed_log_files(directory: &Path) -> Vec<(PathBuf, ParsedLogFile)> {
    let folders = std::iter::once(directory.to_path_buf())
        .chain(policy::LOG_CATEGORIES.iter().map(|c| directory.join(c)));
    folders
        .filter(|p| {
            !p.symlink_metadata()
                .is_ok_and(|m| m.file_type().is_symlink())
        })
        .flat_map(|p| fs::read_dir(p).into_iter().flatten().flatten())
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter_map(|entry| {
            let path = entry.path();
            let parsed = parse_log_file_name(path.file_name()?.to_str()?)?;
            Some((path, parsed))
        })
        .collect()
}

fn managed_log_stats(directory: &Path) -> (usize, u64) {
    managed_log_files(directory)
        .into_iter()
        .fold((0usize, 0u64), |(count, bytes), (path, _)| {
            let size = path.metadata().map(|metadata| metadata.len()).unwrap_or(0);
            (count + 1, bytes.saturating_add(size))
        })
}

fn delete_managed_logs(
    directory: &Path,
    active_path: Option<&Path>,
) -> Result<ClearLogResult, String> {
    let files = managed_log_files(directory);
    let mut result = ClearLogResult {
        deleted_files: 0,
        freed_bytes: 0,
    };
    for (path, _) in files {
        if active_path == Some(path.as_path()) {
            continue;
        }
        let size = path.metadata().map(|metadata| metadata.len()).unwrap_or(0);
        fs::remove_file(&path)
            .map_err(|error| format!("Unable to delete {}: {error}", display_path(&path)))?;
        result.deleted_files += 1;
        result.freed_bytes = result.freed_bytes.saturating_add(size);
    }
    Ok(result)
}

fn count_previous_panic_sidecars(directory: &Path, current_session: &str) -> usize {
    managed_log_files(directory)
        .into_iter()
        .filter(|(_, parsed)| parsed.panic && parsed.session_id != current_session)
        .count()
}

fn next_segment_number(directory: &Path, date: &str, session_id: &str) -> u16 {
    managed_log_files(directory)
        .into_iter()
        .filter_map(|(path, parsed)| {
            if parsed.panic
                || parsed.session_id != session_id
                || parsed.timestamp.format("%Y-%m-%d").to_string() != date
            {
                return None;
            }
            path.file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| log_file_regex().captures(name))
                .and_then(|captures| {
                    captures
                        .get(4)
                        .and_then(|value| value.as_str().parse().ok())
                })
        })
        .max()
        .unwrap_or(0u16)
        .saturating_add(1)
}

fn derive_custom_log_path(root: &Path) -> PathBuf {
    CUSTOM_LOG_SUBDIRECTORY
        .iter()
        .fold(root.to_path_buf(), |path, segment| path.join(segment))
}

fn cleanup_aborted_writer(mut writer: ActiveWriter, custom_root: Option<&Path>) {
    let file_path = writer.path().to_path_buf();
    let directory = writer.directory.clone();
    let _ = writer.close();
    drop(writer);
    let _ = fs::remove_file(&file_path);
    // Module routing creates one owned application subdirectory. Remove it
    // only when empty; never recursively delete a user-selected directory.
    if let Some(parent) = file_path
        .parent()
        .filter(|parent| *parent != directory.as_path())
    {
        let _ = fs::remove_dir(parent);
    }
    let _ = fs::remove_dir(&directory);
    if let Some(root) = custom_root {
        let _ = fs::remove_dir(root.join(CUSTOM_LOG_SUBDIRECTORY[0]));
    }
}

fn probe_directory_with_timeout(directory: PathBuf) -> Result<(), String> {
    run_with_timeout(DIRECTORY_OPERATION_TIMEOUT, move || {
        probe_directory(&directory)
    })?
}

fn run_with_timeout<T: Send + 'static>(
    timeout: StdDuration,
    task: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(task());
    });
    receiver
        .recv_timeout(timeout)
        .map_err(|_| "timed_out".to_string())
}

fn probe_directory(directory: &Path) -> Result<(), String> {
    fs::create_dir_all(directory).map_err(|error| classify_directory_error(&error))?;
    let probe_name = format!(
        ".lithe-log-probe-{}-{}",
        std::process::id(),
        PROBE_ID.fetch_add(1, Ordering::Relaxed)
    );
    let probe_path = directory.join(probe_name);
    File::create(&probe_path)
        .and_then(|mut file| file.write_all(b"probe"))
        .map_err(|error| classify_directory_error(&error))?;
    fs::remove_file(probe_path).map_err(|error| classify_directory_error(&error))
}

static PROBE_ID: AtomicU64 = AtomicU64::new(1);

fn classify_directory_error(error: &std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::PermissionDenied => "not_writable".into(),
        std::io::ErrorKind::NotFound
        | std::io::ErrorKind::NotConnected
        | std::io::ErrorKind::TimedOut => "unavailable".into(),
        _ => "not_writable".into(),
    }
}

fn read_host_config(path: &Path) -> (HostLogConfig, Option<String>) {
    let Ok(file) = File::open(path) else {
        return (HostLogConfig::default(), None);
    };
    match serde_json::from_reader(BufReader::new(file)) {
        Ok(config) => (config, None),
        Err(error) => (HostLogConfig::default(), Some(error.to_string())),
    }
}

fn write_host_config(path: &Path, config: &HostLogConfig) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "Log configuration path has no parent directory".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("Unable to create the log configuration directory: {error}"))?;
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(config)
        .map_err(|error| format!("Unable to serialize the log configuration: {error}"))?;
    fs::write(&temporary, bytes)
        .map_err(|error| format!("Unable to write the log configuration: {error}"))?;
    replace_file_atomically(&temporary, path)
}

#[cfg(target_os = "windows")]
pub(crate) fn replace_file_atomically(source: &Path, destination: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // MoveFileExW provides the replace-existing primitive needed to avoid a
    // missing-config window between deleting the old file and renaming the new one.
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(format!(
            "Unable to commit the log configuration: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

#[cfg(not(target_os = "windows"))]
pub(crate) fn replace_file_atomically(source: &Path, destination: &Path) -> Result<(), String> {
    fs::rename(source, destination)
        .map_err(|error| format!("Unable to commit the log configuration: {error}"))
}

fn unique_paths(paths: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    let mut result = Vec::new();
    for path in paths {
        if !result.iter().any(|existing| existing == &path) {
            result.push(path);
        }
    }
    result
}

fn payload_fields(payload: Option<Value>) -> BTreeMap<String, String> {
    let Some(Value::Object(payload)) = payload else {
        return BTreeMap::new();
    };
    payload
        .into_iter()
        .map(|(key, value)| (snake_case_key(&key), compact_json(&value)))
        .collect()
}

fn compact_json(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        _ => serde_json::to_string(value).unwrap_or_else(|_| "[unserializable]".into()),
    }
}

fn format_event_line(event: &PreparedEvent, session_id: &str) -> String {
    let mut line = format!(
        "{} {:<5} [session={}] [scope={}] {}",
        event
            .timestamp
            .with_timezone(&Utc)
            .format("%Y-%m-%dT%H:%M:%S%.3fZ"),
        event.level.label(),
        session_id,
        event.scope,
        event.message
    );
    line.push_str(&format!(
        " schema_version=1 category={} sequence={:020} process_id={}",
        policy::log_category(&event.scope),
        event.sequence,
        std::process::id()
    ));
    for (key, value) in &event.fields {
        line.push(' ');
        line.push_str(key);
        line.push('=');
        line.push_str(&format_log_value(value));
    }
    line = truncate_log_line(line);
    line.push('\n');
    line
}

fn format_log_value(value: &str) -> String {
    if !value.is_empty()
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._/-:+<>".contains(character))
    {
        return value.to_string();
    }
    let escaped = value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t");
    format!("\"{escaped}\"")
}

fn truncate_log_line(mut line: String) -> String {
    const MARKER: &str = " truncated=true";
    if line.len() < MAX_LOG_LINE_BYTES {
        return line;
    }
    let limit = MAX_LOG_LINE_BYTES.saturating_sub(MARKER.len() + 1);
    while line.len() > limit {
        line.pop();
    }
    line.push_str(MARKER);
    line
}

fn snake_case_key(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    for (index, character) in value.chars().enumerate() {
        if character.is_ascii_uppercase() {
            if index > 0 && !result.ends_with('_') {
                result.push('_');
            }
            result.push(character.to_ascii_lowercase());
        } else if character.is_ascii_alphanumeric() || character == '_' {
            result.push(character.to_ascii_lowercase());
        } else if !result.ends_with('_') {
            result.push('_');
        }
    }
    result.trim_matches('_').to_string()
}

fn is_sensitive_key(key: &str) -> bool {
    [
        "token",
        "authorization",
        "password",
        "secret",
        "api_key",
        "cookie",
    ]
    .iter()
    .any(|sensitive| key.contains(sensitive))
}

struct LogSanitizer {
    user_profile_patterns: Vec<Regex>,
}

impl LogSanitizer {
    fn new() -> Self {
        let user_profile_patterns = std::env::var("USERPROFILE")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .into_iter()
            .flat_map(|profile| [profile.clone(), profile.replace('\\', "/")])
            .filter_map(|profile| Regex::new(&format!("(?i){}", regex::escape(&profile))).ok())
            .collect();
        Self {
            user_profile_patterns,
        }
    }

    fn sanitize_text(&self, value: &str) -> String {
        let shared = policy::sanitize_log_text(value);
        let mut sanitized = shared
            .replace("\r\n", "\\n")
            .replace('\n', "\\n")
            .replace('\r', "\\r");
        for pattern in &self.user_profile_patterns {
            sanitized = pattern
                .replace_all(&sanitized, "<redacted_path>")
                .into_owned();
        }
        sanitized = authorization_header_regex()
            .replace_all(&sanitized, "$1=<redacted>")
            .into_owned();
        sanitized = sensitive_assignment_regex()
            .replace_all(&sanitized, "$1=<redacted>")
            .into_owned();
        sanitized = sensitive_query_regex()
            .replace_all(&sanitized, "$1=<redacted>")
            .into_owned();
        sanitized = credential_shape_regex()
            .replace_all(&sanitized, "<redacted>")
            .into_owned();
        sanitized
    }

    fn sanitize_free_text(&self, value: &str) -> String {
        redact_absolute_paths(&self.sanitize_text(value))
    }

    fn sanitize_field(&self, key: &str, value: &str) -> String {
        let sanitized = self.sanitize_text(value);
        if allows_platform_absolute_path(key) {
            sanitized
        } else {
            redact_absolute_paths(&sanitized)
        }
    }
}

fn authorization_header_regex() -> &'static Regex {
    static REGEX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?i)\b(authorization)\s*[:=]\s*(?:bearer|basic)\s+[^\s,;]+")
            .expect("the authorization header regex is valid")
    })
}

fn sensitive_assignment_regex() -> &'static Regex {
    static REGEX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r"(?i)\b(token|authorization|password|secret|api[_-]?key|cookie)\s*[:=]\s*[^\s,;]+",
        )
        .expect("the sensitive assignment regex is valid")
    })
}

fn sensitive_query_regex() -> &'static Regex {
    static REGEX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?i)([?&](?:token|key|api_key|access_token|auth))=[^&#\s]+")
            .expect("the sensitive query regex is valid")
    })
}

fn credential_shape_regex() -> &'static Regex {
    static REGEX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9_-]{8,})\b",
        )
        .expect("the credential shape regex is valid")
    })
}

fn windows_absolute_path_regex() -> &'static Regex {
    static REGEX: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r#"(?i)(?:\"(?:[A-Z]:[\\/]|\\\\)[^\"]+\"|'(?:[A-Z]:[\\/]|\\\\)[^']+'|\b[A-Z]:[\\/][^\s\"'<>|,;]+|\\\\[^\s\"'<>|,;]+)"#,
        )
        .expect("the Windows absolute path regex is valid")
    })
}

fn redact_absolute_paths(value: &str) -> String {
    windows_absolute_path_regex()
        .replace_all(value, "<redacted_path>")
        .into_owned()
}

fn allows_platform_absolute_path(key: &str) -> bool {
    matches!(
        key,
        "directory"
            | "configured_dir"
            | "effective_dir"
            | "default_path"
            | "configured_path"
            | "effective_path"
            | "previous_directory"
    )
}

fn create_session_id() -> String {
    let timestamp = Local::now().timestamp_micros() as u64;
    let mixed = timestamp
        ^ ((std::process::id() as u64) << 24)
        ^ SESSION_ID.fetch_add(1, Ordering::Relaxed);
    format!("{:08x}", mixed as u32)
}

static SESSION_ID: AtomicU64 = AtomicU64::new(1);
static EVENT_SEQUENCE: AtomicU64 = AtomicU64::new(1);

fn display_path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[tauri::command]
pub fn get_log_settings(manager: State<'_, Arc<LogManager>>) -> LogSettingsSnapshot {
    manager.snapshot()
}

#[tauri::command]
pub async fn set_log_directory(
    parent_path: Option<String>,
    manager: State<'_, Arc<LogManager>>,
) -> Result<LogDirectoryChangeResult, String> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        manager.set_custom_root(
            parent_path
                .filter(|path| !path.trim().is_empty())
                .map(PathBuf::from),
        )
    })
    .await
    .map_err(|error| format!("Log directory task failed: {error}"))?
}

#[tauri::command]
pub fn set_diagnostic_logging(
    enabled: bool,
    category: Option<String>,
    manager: State<'_, Arc<LogManager>>,
) -> LogSettingsSnapshot {
    manager.set_diagnostic_category(enabled, category)
}

#[tauri::command]
pub async fn query_lithe_logs(
    selection: LogSelection,
    manager: State<'_, Arc<LogManager>>,
) -> Result<LogTimeline, String> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.query_logs(selection))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn read_lithe_log(
    manager: State<'_, Arc<LogManager>>,
) -> Result<LitheLogFileResponse, String> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.read_current_log())
        .await
        .map_err(|error| format!("Read log task failed: {error}"))?
}

#[tauri::command]
pub async fn clear_lithe_logs(
    manager: State<'_, Arc<LogManager>>,
) -> Result<ClearLogResult, String> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.clear_current_logs())
        .await
        .map_err(|error| format!("Clear log task failed: {error}"))?
}

#[tauri::command]
pub async fn resolve_previous_log_cleanup(
    delete: bool,
    manager: State<'_, Arc<LogManager>>,
) -> Result<ClearLogResult, String> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.resolve_previous_custom_cleanup(delete))
        .await
        .map_err(|error| format!("Previous log cleanup task failed: {error}"))?
}

#[tauri::command]
pub fn open_log_directory(
    app: AppHandle,
    manager: State<'_, Arc<LogManager>>,
) -> Result<(), String> {
    manager.ensure_available()?;
    app.opener()
        .open_path(display_path(&manager.effective_path()), None::<&str>)
        .map_err(|error| format!("Unable to open the log directory: {error}"))
}

#[tauri::command]
pub fn frontend_trace(
    level: String,
    scope: String,
    message: String,
    payload: Option<Value>,
    manager: State<'_, Arc<LogManager>>,
) {
    manager.emit_json(&level, scope, message, payload);
}

#[tauri::command]
pub fn record_startup_milestone(milestone: String, manager: State<'_, Arc<LogManager>>) {
    manager.emit(LogLevel::Info, "startup", milestone, BTreeMap::new());
}

// Shared by this module's own tests and by other Windows modules (such as
// `diagnostics`) that need a real `LogManager` backed by a temporary
// directory without going through `LogManager::initialize`'s `AppHandle`
// requirement.
#[cfg(test)]
pub(crate) fn temporary_directory(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "lithe-log-tests-{name}-{}-{}",
        std::process::id(),
        SESSION_ID.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

#[cfg(test)]
pub(crate) fn test_manager(directory: &Path) -> Arc<LogManager> {
    let session_id = "deadbeef".to_string();
    let writer = ActiveWriter::open(directory.to_path_buf(), session_id.clone()).unwrap();
    let active_file_path = writer.path().to_path_buf();
    let shared = Arc::new(SharedState {
        app: None,
        queue: Mutex::new(QueueState::default()),
        queue_ready: Condvar::new(),
        writer: Mutex::new(writer),
        runtime: RwLock::new(RuntimeState {
            default_path: directory.to_path_buf(),
            configured_path: None,
            effective_path: directory.to_path_buf(),
            fallback_reason: None,
            diagnostic_enabled: false,
            diagnostic_category: None,
            diagnostic_deadline: None,
            active_file_path,
        }),
        panic_path: RwLock::new(panic_sidecar_path(directory, &session_id)),
        writer_alive: AtomicBool::new(true),
        sanitizer: LogSanitizer::new(),
    });
    Arc::new(LogManager {
        shared,
        config_path: directory.join(LOG_CONFIG_FILE),
        session_id,
        config_update: Mutex::new(()),
        pending_previous_custom: Mutex::new(None),
        degraded_reason: None,
    })
}

#[cfg(test)]
pub(crate) fn start_test_writer(manager: &Arc<LogManager>) {
    spawn_writer(manager.shared.clone(), manager.session_id.clone())
        .expect("test writer should start");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collection_filters_before_file_limit_and_reports_omitted_matching_files() {
        let directory = temporary_directory("collection-file-limit");
        let manager = test_manager(&directory);
        start_test_writer(&manager);
        struct Cleanup(Arc<LogManager>, PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                self.0.shutdown();
                let _ = fs::remove_dir_all(&self.1);
            }
        }
        let _cleanup = Cleanup(manager.clone(), directory.clone());
        (|| {
            fs::create_dir_all(directory.join("git")).unwrap();
            let old = "lithe.2026-10-19T00-00-00.000+0000.cafebabe.001.log";
            fs::write(
                directory.join("git").join(old),
                "2026-10-19T00:00:00.000Z INFO git evidence\n",
            )
            .unwrap();
            for index in 1..=201 {
                let name = format!("lithe.2026-10-20T00-00-00.000+0000.cafebabe.{index:03}.log");
                fs::write(
                    directory.join("application").join(name),
                    "2026-10-20T00:00:00.000Z INFO application evidence\n",
                )
                .unwrap();
            }
            let selection = LogSelection {
                category: Some("git".into()),
                session: Some("all".into()),
                ..Default::default()
            };
            let (git, truncated) = manager.collect_logs(&selection)?;
            assert!(!truncated);
            assert!(git.iter().any(|log| log.text.contains("git evidence")));
            let (previous, _) = manager.collect_logs(&LogSelection {
                session: Some("previous".into()),
                ..selection
            })?;
            assert!(previous.iter().any(|log| log.text.contains("git evidence")));
            let (_, truncated) = manager.collect_logs(&LogSelection {
                category: Some("application".into()),
                session: Some("all".into()),
                ..Default::default()
            })?;
            assert!(truncated);
            Ok::<_, String>(())
        })()
        .unwrap();
    }

    #[test]
    fn formats_single_line_and_redacts_sensitive_values() {
        let sanitizer = LogSanitizer::new();
        let event = PreparedEvent::new(
            LogLevel::Info,
            "runtime.test",
            "line one\nline two token=secret-value",
            BTreeMap::from([("apiKey".into(), "secret".into())]),
            &sanitizer,
        );
        let line = format_event_line(&event, "abcd1234");
        assert_eq!(line.lines().count(), 1);
        assert!(line.contains("line one\\nline two"));
        assert!(line.contains("api_key=<redacted>"));
        assert!(!line.contains("secret-value"));
    }

    #[test]
    fn redacts_authorization_headers_token_shapes_and_free_text_paths() {
        let sanitizer = LogSanitizer::new();
        let event = PreparedEvent::new(
            LogLevel::Error,
            "runtime.console",
            "Authorization: Bearer ghp_1234567890abcdef failed at D:\\work\\customer-x\\main.rs and \\\\server\\share\\secret.txt",
            BTreeMap::from([
                ("reason".into(), "github_pat_1234567890abcdef".into()),
                ("directory".into(), "E:/Lithe/logs".into()),
            ]),
            &sanitizer,
        );
        let line = format_event_line(&event, "abcd1234");
        assert!(!line.contains("ghp_"));
        assert!(!line.contains("github_pat_"));
        assert!(!line.contains("customer-x"));
        assert!(!line.contains("server"));
        assert!(line.contains("<redacted_path>"));
        assert!(line.contains("directory=E:/Lithe/logs"));
    }

    #[test]
    fn cleanup_uses_filename_timestamp_and_keeps_unparseable_files() {
        let directory = temporary_directory("cleanup");
        let old = directory.join("lithe.2020-01-01T00-00-00.000+0000.deadbeef.001.log");
        let unknown = directory.join("lithe.unknown.log");
        fs::write(&old, "old").unwrap();
        fs::write(&unknown, "unknown").unwrap();
        let warnings = cleanup_expired_logs(&directory, None).unwrap();
        assert!(!old.exists());
        assert!(unknown.exists());
        assert!(warnings
            .iter()
            .any(|warning| warning.contains("lithe.unknown.log")));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn daily_limit_excludes_panic_sidecars() {
        let directory = temporary_directory("daily-limit");
        for index in 0..MAX_LOG_FILES_PER_DAY {
            let path = directory.join(format!(
                "lithe.2026-08-18T00-00-0{index}.000+0000.deadbeef.{:03}.log",
                index + 1
            ));
            fs::write(path, "regular").unwrap();
        }
        let panic = directory.join("lithe.panic.2026-08-18T00-00-09.000+0000.deadbeef.log");
        fs::write(&panic, "panic").unwrap();
        enforce_daily_limit(&directory, "2026-08-18", None).unwrap();
        assert_eq!(
            managed_log_files(&directory)
                .into_iter()
                .filter(|(_, parsed)| !parsed.panic)
                .count(),
            MAX_LOG_FILES_PER_DAY - 1
        );
        assert!(panic.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn writer_rotates_at_ten_megabytes() {
        let directory = temporary_directory("size-rotation");
        let mut writer = ActiveWriter::open(directory.clone(), "deadbeef".into()).unwrap();
        let original_path = writer.path().to_path_buf();
        writer.bytes_written = MAX_LOG_FILE_BYTES;
        writer.write_preformatted("next line\n", true).unwrap();
        assert_ne!(writer.path(), original_path);
        assert_eq!(writer.segment, 2);
        drop(writer);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn writer_rotates_at_midnight_and_resets_the_segment() {
        let directory = temporary_directory("midnight-rotation");
        let mut writer = ActiveWriter::open(directory.clone(), "deadbeef".into()).unwrap();
        writer.created_date = "2000-01-01".into();
        writer.segment = 9;
        writer.write_preformatted("new day\n", true).unwrap();
        assert_eq!(
            writer.created_date,
            Local::now().format("%Y-%m-%d").to_string()
        );
        assert_eq!(writer.segment, 1);
        drop(writer);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn probe_creates_the_derived_custom_directory() {
        let root = temporary_directory("probe");
        let target = derive_custom_log_path(&root);
        probe_directory(&target).unwrap();
        assert!(target.is_dir());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_directory_operation_reports_timeout() {
        let result = run_with_timeout(StdDuration::from_millis(5), || {
            thread::sleep(StdDuration::from_millis(50));
            "late"
        });
        assert_eq!(result.unwrap_err(), "timed_out");
    }

    #[test]
    fn degraded_manager_keeps_commands_safe_when_file_logging_cannot_initialize() {
        let directory = temporary_directory("degraded-manager");
        let manager = LogManager::degraded_with_paths(
            directory.clone(),
            directory.join(LOG_CONFIG_FILE),
            "test initialization failure".into(),
        );
        assert_eq!(
            manager.snapshot().fallback_reason.as_deref(),
            Some("logging_unavailable")
        );
        assert!(manager.read_current_log().is_err());
        assert!(manager.clear_current_logs().is_err());
        assert!(manager
            .set_custom_root(Some(directory.join("custom")))
            .is_err());
        assert!(manager.set_diagnostic_enabled(true).diagnostic_enabled);
        manager.emit_json("error", "runtime.console".into(), "still safe".into(), None);
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn control_commands_wait_for_events_already_in_the_queue() {
        let sanitizer = LogSanitizer::new();
        let event = PreparedEvent::new(
            LogLevel::Info,
            "test",
            "before flush",
            BTreeMap::new(),
            &sanitizer,
        );
        let (reply, _) = mpsc::channel();
        let mut queue = QueueState::default();
        queue.events.push_back(QueuedEvent { event, repeated: 0 });
        queue.controls.push_back(QueuedControl {
            control: Control::Flush { reply },
            pending_events: 1,
        });

        assert!(matches!(
            take_writer_work(&mut queue),
            WriterWork::Event(..)
        ));
        assert!(matches!(
            take_writer_work(&mut queue),
            WriterWork::Control(Control::Flush { .. })
        ));
    }

    #[test]
    fn eviction_after_a_control_boundary_does_not_advance_that_boundary() {
        let sanitizer = LogSanitizer::new();
        let first = PreparedEvent::new(
            LogLevel::Info,
            "queue",
            "before",
            BTreeMap::new(),
            &sanitizer,
        );
        let later = PreparedEvent::new(
            LogLevel::Debug,
            "queue",
            "after",
            BTreeMap::new(),
            &sanitizer,
        );
        let mut queue = QueueState::default();
        queue.events.push_back(QueuedEvent {
            event: first,
            repeated: 0,
        });
        let (tx, _rx) = mpsc::channel();
        queue.controls.push_back(QueuedControl {
            control: Control::Flush { reply: tx },
            pending_events: 1,
        });
        queue.events.push_back(QueuedEvent {
            event: later,
            repeated: 0,
        });
        assert!(evict_oldest(&mut queue, LogLevel::Debug));
        assert_eq!(queue.controls.front().unwrap().pending_events, 1);
        assert!(matches!(
            take_writer_work(&mut queue),
            WriterWork::Event(..)
        ));
        assert!(matches!(
            take_writer_work(&mut queue),
            WriterWork::Control(..)
        ));
    }

    #[test]
    fn identical_events_do_not_merge_across_a_flush_boundary() {
        let directory = temporary_directory("dedup-boundary");
        let manager = test_manager(&directory);
        let event = || {
            PreparedEvent::new(
                LogLevel::Warn,
                "language.java",
                "same failure",
                BTreeMap::new(),
                &manager.shared.sanitizer,
            )
        };
        enqueue_event(&manager.shared, event());
        let (tx, _rx) = mpsc::channel();
        manager.push_control(Control::Flush { reply: tx }).unwrap();
        enqueue_event(&manager.shared, event());
        let queue = manager.shared.queue.lock().unwrap();
        assert_eq!(queue.events.len(), 2);
        assert_eq!(queue.events.front().unwrap().repeated, 0);
        drop(queue);
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn normal_queue_pressure_evicts_debug_before_info() {
        let directory = temporary_directory("queue-pressure");
        let manager = test_manager(&directory);
        for index in 0..LOG_QUEUE_NORMAL_CAPACITY {
            let event = PreparedEvent::new(
                LogLevel::Debug,
                "queue",
                format!("debug {index}"),
                BTreeMap::new(),
                &manager.shared.sanitizer,
            );
            enqueue_event(&manager.shared, event);
        }
        let info = PreparedEvent::new(
            LogLevel::Info,
            "queue",
            "important info",
            BTreeMap::new(),
            &manager.shared.sanitizer,
        );
        enqueue_event(&manager.shared, info);
        let queue = manager.shared.queue.lock().unwrap();
        assert_eq!(queue.events.len(), LOG_QUEUE_NORMAL_CAPACITY);
        assert_eq!(queue.dropped.debug, 1);
        assert!(queue
            .events
            .iter()
            .any(|entry| entry.event.message == "important info"));
        drop(queue);
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn saturated_warning_queue_reports_loss_without_writing_on_the_producer() {
        let directory = temporary_directory("bounded-error-storm");
        let manager = test_manager(&directory);
        for index in 0..LOG_QUEUE_CAPACITY {
            enqueue_event(
                &manager.shared,
                PreparedEvent::new(
                    LogLevel::Warn,
                    "queue",
                    format!("warning {index}"),
                    BTreeMap::new(),
                    &manager.shared.sanitizer,
                ),
            );
        }
        enqueue_event(
            &manager.shared,
            PreparedEvent::new(
                LogLevel::Error,
                "queue",
                "critical queued event",
                BTreeMap::new(),
                &manager.shared.sanitizer,
            ),
        );
        assert_eq!(
            manager.shared.queue.lock().unwrap().events.len(),
            LOG_QUEUE_CAPACITY
        );
        assert_eq!(manager.snapshot().dropped_events, 1);
        assert_eq!(
            manager
                .shared
                .queue
                .lock()
                .unwrap()
                .events
                .back()
                .unwrap()
                .event
                .message,
            "critical queued event"
        );
        let active = manager
            .shared
            .runtime
            .read()
            .unwrap()
            .active_file_path
            .clone();
        assert!(fs::read_to_string(active).unwrap().is_empty());
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn modules_keep_independent_files_and_nested_secrets_never_reach_disk() {
        let directory = temporary_directory("module-routing");
        let manager = test_manager(&directory);
        let event = PreparedEvent::new(
            LogLevel::Error,
            "language.java",
            "failed",
            BTreeMap::from([(
                "context".into(),
                r#"{"password":"synthetic-secret","operationID":"op-a"}"#.into(),
            )]),
            &manager.shared.sanitizer,
        );
        assert!(write_event(
            &manager.shared,
            &event,
            &manager.session_id,
            true
        ));
        let files = managed_log_files(&directory);
        let language = files
            .iter()
            .find(|(path, _)| path.parent() == Some(directory.join("language").as_path()))
            .unwrap();
        let text = fs::read_to_string(&language.0).unwrap();
        assert!(!text.contains("synthetic-secret"));
        assert!(text.contains("op-a"));
        assert!(text.contains("schema_version=1"));
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn diagnostic_deadline_is_checked_before_accepting_debug_events() {
        let directory = temporary_directory("diagnostic-expiry");
        let manager = test_manager(&directory);
        manager.set_diagnostic_category(true, Some("language".into()));
        manager.emit_json("debug", "git.fetch".into(), "wrong module".into(), None);
        manager.emit_json("debug", "language.java".into(), "included".into(), None);
        manager.shared.runtime.write().unwrap().diagnostic_deadline =
            Some(std::time::Instant::now());
        manager.emit_json("debug", "language.java".into(), "expired".into(), None);
        let queue = manager.shared.queue.lock().unwrap();
        assert!(queue.events.iter().any(|e| e.event.message == "included"));
        assert!(!queue
            .events
            .iter()
            .any(|e| e.event.message == "expired" || e.event.message == "wrong module"));
        drop(queue);
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn write_failure_is_reported_after_the_writer_recovers() {
        let directory = temporary_directory("write-recovery");
        let manager = test_manager(&directory);
        *manager.shared.writer.lock().unwrap() =
            ActiveWriter::disabled(directory.clone(), manager.session_id.clone());
        let failed = PreparedEvent::new(
            LogLevel::Info,
            "test",
            "will fail",
            BTreeMap::new(),
            &manager.shared.sanitizer,
        );
        assert!(!write_event(
            &manager.shared,
            &failed,
            &manager.session_id,
            true
        ));

        let recovered = ActiveWriter::open(directory.clone(), manager.session_id.clone()).unwrap();
        let recovered_path = recovered.path().to_path_buf();
        *manager.shared.writer.lock().unwrap() = recovered;
        manager.shared.runtime.write().unwrap().active_file_path = recovered_path.clone();
        spawn_writer(manager.shared.clone(), manager.session_id.clone()).unwrap();
        manager.emit(LogLevel::Info, "test", "writer recovered", BTreeMap::new());
        manager.shutdown();
        assert!(fs::read_to_string(recovered_path)
            .unwrap()
            .contains("write failures recovered"));
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn runtime_write_failure_falls_back_to_default_and_retries_the_line() {
        let root = temporary_directory("runtime-fallback");
        let custom = root.join("custom");
        let default = root.join("default");
        fs::create_dir_all(&custom).unwrap();
        fs::create_dir_all(&default).unwrap();
        let manager = test_manager(&custom);
        {
            let mut runtime = manager.shared.runtime.write().unwrap();
            runtime.default_path = default.clone();
            runtime.configured_path = Some(custom.clone());
            runtime.effective_path = custom.clone();
        }
        *manager.shared.writer.lock().unwrap() =
            ActiveWriter::disabled(custom, manager.session_id.clone());
        let event = PreparedEvent::new(
            LogLevel::Warn,
            "runtime.test",
            "retry after fallback",
            BTreeMap::new(),
            &manager.shared.sanitizer,
        );
        assert!(write_event(
            &manager.shared,
            &event,
            &manager.session_id,
            true
        ));
        let runtime = manager.shared.runtime.read().unwrap().clone();
        assert_eq!(runtime.effective_path, default);
        assert!(runtime.configured_path.is_some());
        assert_eq!(runtime.fallback_reason.as_deref(), Some("not_writable"));
        let content = fs::read_to_string(runtime.active_file_path).unwrap();
        assert!(content.contains("fallback_to_default"));
        assert!(content.contains("retry after fallback"));
        drop(manager);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn panic_falls_back_to_sidecar_while_the_main_writer_is_locked() {
        let directory = temporary_directory("panic-sidecar");
        let manager = test_manager(&directory);
        let writer_guard = manager.shared.writer.lock().unwrap();
        let worker = {
            let manager = manager.clone();
            thread::spawn(move || manager.write_panic_event("locked writer panic", BTreeMap::new()))
        };
        worker.join().unwrap();
        drop(writer_guard);
        let sidecar = manager.shared.panic_path.read().unwrap().clone();
        let content = fs::read_to_string(sidecar).unwrap();
        assert!(content.contains("locked writer panic"));
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn panic_on_the_writer_thread_skips_the_main_lock() {
        let directory = temporary_directory("writer-panic-sidecar");
        let manager = test_manager(&directory);
        let worker = {
            let manager = manager.clone();
            thread::spawn(move || {
                IS_LOG_WRITER_THREAD.with(|flag| flag.set(true));
                manager.write_panic_event("writer thread panic", BTreeMap::new());
            })
        };
        worker.join().unwrap();
        let sidecar = manager.shared.panic_path.read().unwrap().clone();
        assert!(fs::read_to_string(sidecar)
            .unwrap()
            .contains("writer thread panic"));
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_panics_finish_without_deadlocking() {
        let directory = temporary_directory("concurrent-panic");
        let manager = test_manager(&directory);
        let writer_guard = manager.shared.writer.lock().unwrap();
        let (finished_tx, finished_rx) = mpsc::channel();
        let workers = (0..2)
            .map(|index| {
                let manager = manager.clone();
                let finished_tx = finished_tx.clone();
                thread::spawn(move || {
                    manager
                        .write_panic_event(&format!("concurrent panic {index}"), BTreeMap::new());
                    let _ = finished_tx.send(());
                })
            })
            .collect::<Vec<_>>();
        for _ in 0..2 {
            finished_rx
                .recv_timeout(StdDuration::from_secs(1))
                .expect("panic logging must not deadlock");
        }
        for worker in workers {
            worker.join().unwrap();
        }
        drop(writer_guard);
        let sidecar = manager.shared.panic_path.read().unwrap().clone();
        let content = fs::read_to_string(sidecar).unwrap();
        assert!(content.contains("concurrent panic 0"));
        assert!(content.contains("concurrent panic 1"));
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn panic_guard_resets_after_each_hook_invocation() {
        let directory = temporary_directory("sequential-panics");
        let manager = test_manager(&directory);
        manager.write_panic_event("first panic", BTreeMap::new());
        manager.write_panic_event("second panic", BTreeMap::new());
        let active = manager
            .shared
            .runtime
            .read()
            .unwrap()
            .active_file_path
            .clone();
        let content = fs::read_to_string(active).unwrap();
        assert!(content.contains("first panic"));
        assert!(content.contains("second panic"));
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn directory_switch_updates_runtime_and_persists_only_the_parent() {
        let directory = temporary_directory("directory-switch");
        let custom_root = directory.join("chosen-parent");
        let manager = test_manager(&directory);
        let original_file = manager
            .shared
            .runtime
            .read()
            .unwrap()
            .active_file_path
            .clone();
        spawn_writer(manager.shared.clone(), manager.session_id.clone()).unwrap();

        let result = manager.set_custom_root(Some(custom_root.clone())).unwrap();
        let expected = derive_custom_log_path(&custom_root);
        assert_eq!(
            result.settings.configured_path.as_deref(),
            Some(display_path(&expected).as_str())
        );
        assert_eq!(result.settings.effective_path, display_path(&expected));
        assert_eq!(
            read_host_config(&manager.config_path).0.custom_root,
            Some(display_path(&custom_root))
        );
        let switched_file = manager
            .shared
            .runtime
            .read()
            .unwrap()
            .active_file_path
            .clone();
        assert!(fs::read_to_string(original_file)
            .unwrap()
            .contains("switching log directory"));
        assert!(fs::read_to_string(switched_file)
            .unwrap()
            .contains("session continues"));

        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn persistence_failure_aborts_a_directory_switch() {
        let directory = temporary_directory("directory-switch-failure");
        let manager = test_manager(&directory);
        let original_effective = manager.snapshot().effective_path;
        let blocked_parent = directory.join("blocked-parent");
        fs::write(&blocked_parent, "not a directory").unwrap();
        let manager = Arc::new(LogManager {
            shared: manager.shared.clone(),
            config_path: blocked_parent.join(LOG_CONFIG_FILE),
            session_id: manager.session_id.clone(),
            config_update: Mutex::new(()),
            pending_previous_custom: Mutex::new(None),
            degraded_reason: None,
        });

        let result = manager.set_custom_root(Some(directory.join("next-parent")));
        assert!(result.is_err());
        assert_eq!(manager.snapshot().effective_path, original_effective);
        assert!(!directory.join("next-parent").join("Lithe").exists());
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn an_aborted_writer_releases_its_empty_module_directory() {
        let root = temporary_directory("aborted-module-directory");
        let target = derive_custom_log_path(&root);
        let writer = ActiveWriter::open(target.clone(), "deadbeef".into()).unwrap();
        cleanup_aborted_writer(writer, Some(&root));
        assert!(!target.exists());
        assert!(root.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn timed_out_switch_is_cancelled_before_the_writer_can_execute_it() {
        let directory = temporary_directory("cancelled-switch");
        let target = directory.join("target").join("Lithe").join("logs");
        let manager = test_manager(&directory);
        let original = manager.snapshot().effective_path;
        let writer = ActiveWriter::open(target.clone(), manager.session_id.clone()).unwrap();
        let ticket = ControlTicket::new();
        let (reply_tx, reply_rx) = mpsc::channel();
        manager
            .push_control(Control::Switch {
                writer,
                previous_path: PathBuf::from(&original),
                configured_path: Some(target),
                fallback_reason: None,
                ticket: ticket.clone(),
                reply: reply_tx,
            })
            .unwrap();
        let result = wait_for_control_timeout(
            reply_rx,
            &ticket,
            "testing a directory switch",
            StdDuration::from_millis(1),
        );
        assert!(result.is_err());
        spawn_writer(manager.shared.clone(), manager.session_id.clone()).unwrap();
        thread::sleep(StdDuration::from_millis(25));
        assert_eq!(manager.snapshot().effective_path, original);
        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_config_destination_does_not_replace_an_existing_config() {
        let directory = temporary_directory("config-transaction");
        let config_path = directory.join(LOG_CONFIG_FILE);
        let original = HostLogConfig {
            custom_root: Some("D:/original".into()),
        };
        write_host_config(&config_path, &original).unwrap();
        let blocked_parent = directory.join("blocked");
        fs::write(&blocked_parent, "not a directory").unwrap();
        let result = write_host_config(
            &blocked_parent.join(LOG_CONFIG_FILE),
            &HostLogConfig {
                custom_root: Some("E:/next".into()),
            },
        );
        assert!(result.is_err());
        assert_eq!(
            read_host_config(&config_path).0.custom_root,
            original.custom_root
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
