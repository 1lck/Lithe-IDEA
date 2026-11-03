//! Catalog identities, role routing, and bounded stderr framing for managed engines.

use super::engine::LspRuntimeError;
use crate::diagnostics::channel::validate_segment;
use crate::lsp::languages::jdt::MavenProfileProjectResult;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

type Fields = BTreeMap<String, Value>;

/// Host-declared protocol process role, independent of its opaque provider ID.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionRole {
    /// Default for old hosts that do not send a role.
    #[default]
    LanguageServer,
    /// A version-control provider with an explicit VCS subject.
    Vcs,
    /// A build provider owned by a plugin.
    Build,
    /// A plugin-owned toolchain provider.
    Toolchain,
    /// A plugin backend serving plugin functions and host requests.
    Backend,
}

/// Session-owned validated routing identity; no host-provided path can override it.
pub(super) struct SessionLogIdentity {
    pub(super) role: SessionRole,
    subject: String,
}

impl SessionLogIdentity {
    pub(super) fn new(
        role: SessionRole,
        provider: &str,
        plugin: Option<&str>,
        subject: Option<&str>,
    ) -> Self {
        let raw = match role {
            SessionRole::LanguageServer => Some(provider),
            SessionRole::Vcs => subject,
            _ => plugin,
        };
        // Language IDs such as c++ are valid process identities but unsafe path
        // segments. Never reject startup or drop evidence: use a stable sha256
        // prefix of the original identity (or provider for an absent subject).
        // The prefix plus 32 hex digits is valid and does not expose raw input.
        let subject = match raw.filter(|id| validate_segment(id).is_ok()) {
            Some(id) => id.to_owned(),
            None => format!(
                "invalid-{:x}",
                Sha256::digest(raw.unwrap_or(provider).as_bytes())
            )[..40]
                .to_owned(),
        };
        debug_assert!(validate_segment(&subject).is_ok());
        Self { role, subject }
    }

    fn field(&self) -> &'static str {
        match self.role {
            SessionRole::LanguageServer => "server",
            SessionRole::Vcs => "provider",
            _ => "plugin",
        }
    }

    pub(super) fn channel(&self) -> String {
        match self.role {
            SessionRole::LanguageServer => format!("lsp/{}", self.subject),
            SessionRole::Vcs => format!("vcs/{}", self.subject),
            _ => format!("plugins/{}/host", self.subject),
        }
    }

    fn event(&self, suffix: &str) -> String {
        let prefix = match self.role {
            SessionRole::LanguageServer => "lsp",
            SessionRole::Vcs => "vcs",
            _ => "plugins.host",
        };
        format!("{prefix}.{suffix}")
    }
}

/// Pure host request for the exact routing identity used at engine startup.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ResolveEngineLogSubjectRequest {
    /// Explicit protocol role; never inferred from a provider name.
    role: SessionRole,
    /// Opaque provider catalog identity, including IDs unsafe as path segments.
    provider_id: String,
    /// Owning plugin for build, toolchain, and backend roles.
    plugin_id: Option<String>,
    /// Explicit VCS catalog identity for version-control roles.
    log_subject: Option<String>,
}

/// Core-derived routing segment and channel, without starting a session or doing I/O.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ResolvedEngineLogSubject {
    /// Complete logical channel selected by the engine role.
    channel: String,
    /// Safe identity segment shared by Core and host-owned catalog facts.
    segment: String,
}

/// Reuses startup identity rules so pre-start host facts route to the same channel.
pub(crate) fn resolve_engine_log_subject(
    request: ResolveEngineLogSubjectRequest,
) -> ResolvedEngineLogSubject {
    let identity = SessionLogIdentity::new(
        request.role,
        &request.provider_id,
        request.plugin_id.as_deref(),
        request.log_subject.as_deref(),
    );
    ResolvedEngineLogSubject {
        channel: identity.channel(),
        segment: identity.subject,
    }
}

/// Source-selected facts; messages and v1 details never select catalog identities.
#[derive(Clone, Copy)]
pub(super) enum EngineLog {
    ProcessStarted,
    ProtocolInitialized,
    ConfigurationCleaned,
    ConfigurationCleanupFailed,
    LegacyRemoved,
    MavenSettingsForwarded,
    MavenConfigurationUpdated,
    MavenCancelled,
    MavenProjectFinished,
    MavenApplied,
    MavenPartiallyApplied,
    MavenApplicationStarted,
    MavenStartFailed,
    MavenTimedOut,
    MavenTaskUpdated,
    NavigationCacheHit,
    NavigationLimited,
    NavigationMarkerFailed,
    NavigationResolved,
    ResponseSkipped,
    WorkspaceProgressReceived,
    WorkspaceWaiting,
    WorkspaceImportFinished,
    WorkspaceStalled,
    BuildWaiting,
    BuildExecution,
    ShutdownTimedOut,
    StderrReceived,
    StderrReadFailed,
    MessageLogged,
    MessageShown,
    TraceReceived,
    NotificationReceived,
    SessionUpdated,
    Dropped,
}

/// Source-owned scalar inputs, independent of the compatibility detail string.
pub(super) struct EngineLogInput {
    pub(super) identity: EngineLog,
    pub(super) fields: Value,
}

impl From<EngineLog> for EngineLogInput {
    fn from(identity: EngineLog) -> Self {
        Self {
            identity,
            fields: Value::Null,
        }
    }
}

fn copy(fields: &mut Fields, target: &str, input: &Value, key: &str) {
    if let Some(value) = input.get(key).filter(|v| !v.is_null()) {
        fields.insert(target.into(), value.clone());
    }
}

fn failure(fields: &mut Fields, code: &str) {
    // Engine-produced failure details can contain paths, command output, or
    // protocol payloads. Retain the stable classification, never that dump.
    fields.insert("error".into(), json!("Engine operation failed"));
    fields.insert("error_code".into(), json!(code));
    fields.insert("error_domain".into(), json!("lsp"));
}

impl EngineLog {
    pub(super) fn with_fields(self, fields: Value) -> EngineLogInput {
        EngineLogInput {
            identity: self,
            fields,
        }
    }

    fn suffix(self) -> &'static str {
        match self {
            Self::ProcessStarted => "process.started",
            Self::ProtocolInitialized => "protocol.initialized",
            Self::ConfigurationCleaned => "configuration.cleaned",
            Self::ConfigurationCleanupFailed => "configuration.cleanup_failed",
            Self::LegacyRemoved => "workspace.legacy_removed",
            Self::MavenSettingsForwarded => "maven.settings_forwarded",
            Self::MavenConfigurationUpdated => "maven.configuration_updated",
            Self::MavenCancelled => "maven.cancelled",
            Self::MavenProjectFinished => "maven.project_finished",
            Self::MavenApplied => "maven.applied",
            Self::MavenPartiallyApplied => "maven.partially_applied",
            Self::MavenApplicationStarted => "maven.application_started",
            Self::MavenStartFailed => "maven.start_failed",
            Self::MavenTimedOut => "maven.timed_out",
            Self::MavenTaskUpdated => "maven.task_updated",
            Self::NavigationCacheHit => "navigation.cache_hit",
            Self::NavigationLimited => "navigation.limited",
            Self::NavigationMarkerFailed => "navigation.marker_failed",
            Self::NavigationResolved => "navigation.resolved",
            Self::ResponseSkipped => "response.skipped",
            Self::WorkspaceProgressReceived => "workspace.progress_received",
            Self::WorkspaceWaiting => "workspace.waiting",
            Self::WorkspaceImportFinished => "workspace.import_finished",
            Self::WorkspaceStalled => "workspace.stalled",
            Self::BuildWaiting => "build.waiting",
            Self::BuildExecution => "build.execution",
            Self::ShutdownTimedOut => "shutdown.timed_out",
            Self::StderrReceived => "stderr.received",
            Self::StderrReadFailed => "stderr.read_failed",
            Self::MessageLogged => "message.logged",
            Self::MessageShown => "message.shown",
            Self::TraceReceived => "trace.received",
            Self::NotificationReceived => "notification.received",
            Self::SessionUpdated => "session.updated",
            Self::Dropped => "log.dropped",
        }
    }

    pub(super) fn fact(
        self,
        identity: &SessionLogIdentity,
        input: &Value,
        error: Option<&LspRuntimeError>,
    ) -> (String, Fields) {
        let mut fields = Fields::from([(identity.field().into(), json!(identity.subject))]);
        let mut id = identity.event(self.suffix());
        let code = error.map(|e| e.code.as_str()).unwrap_or("operation_failed");
        match self {
            Self::StderrReceived => {
                fields.insert(
                    "diagnostic".into(),
                    input
                        .get("diagnostic")
                        .cloned()
                        .unwrap_or_else(|| json!("")),
                );
                copy(&mut fields, "truncated", &input, "truncated");
            }
            Self::StderrReadFailed | Self::ConfigurationCleanupFailed | Self::MavenStartFailed => {
                failure(&mut fields, code)
            }
            Self::MessageLogged | Self::MessageShown => {
                copy(&mut fields, "diagnostic", &input, "diagnostic");
                copy(&mut fields, "severity", &input, "severity");
            }
            Self::TraceReceived => {
                copy(&mut fields, "diagnostic", &input, "diagnostic");
            }
            Self::NotificationReceived => {
                copy(&mut fields, "method", &input, "method");
            }
            Self::SessionUpdated | Self::MavenTaskUpdated => {
                copy(&mut fields, "state", &input, "state");
            }
            Self::ConfigurationCleaned => {
                fields.insert(
                    "removed".into(),
                    json!(input["removedKeys"].as_array().map_or(0, Vec::len)),
                );
            }
            Self::LegacyRemoved => {
                fields.insert(
                    "removed_files".into(),
                    json!(input["removedFiles"].as_array().map_or(0, Vec::len)),
                );
                fields.insert(
                    "state_reset".into(),
                    json!(input["stateReset"].as_bool().unwrap_or(false)),
                );
            }
            Self::MavenSettingsForwarded => {
                fields.insert("reason".into(), json!(code));
            }
            Self::MavenConfigurationUpdated => {
                for (target, source) in [
                    ("settings_changed", "settingsChanged"),
                    ("projects_reloaded", "projectsReloaded"),
                    ("profiles_updating", "profilesUpdating"),
                ] {
                    copy(&mut fields, target, &input, source);
                }
            }
            Self::MavenApplicationStarted => {
                copy(&mut fields, "projects", &input, "projectCount");
            }
            Self::MavenProjectFinished => {
                fields.insert(
                    "project".into(),
                    json!(input["projectUri"].as_str().unwrap_or("<PATH>")),
                );
                fields.insert(
                    "outcome".into(),
                    json!(input["status"].as_str().unwrap_or("unknown")),
                );
                if error.is_some() {
                    id = identity.event("maven.project_failed");
                    failure(&mut fields, code);
                }
            }
            Self::NavigationCacheHit
            | Self::NavigationLimited
            | Self::NavigationMarkerFailed
            | Self::NavigationResolved => {
                for name in [
                    "document",
                    "document_version",
                    "duration_ms",
                    "tasks",
                    "limit",
                    "code_lenses",
                    "markers",
                ] {
                    copy(&mut fields, name, &input, name);
                }
                if matches!(self, Self::NavigationMarkerFailed) {
                    failure(&mut fields, code);
                }
            }
            Self::ResponseSkipped => {
                // JSON-RPC response IDs are opaque upstream strings. Only numeric
                // IDs are useful safe tokens; never record an arbitrary string ID.
                if let Some(request) = input.as_str().filter(|id| {
                    id.bytes().all(|b| b.is_ascii_digit()) && id.len() <= 64 && !id.is_empty()
                }) {
                    fields.insert("request".into(), json!(request));
                }
            }
            Self::WorkspaceProgressReceived => {
                // The upstream progress phase is free text. Keep the observation
                // structured rather than persisting status, project, or artifact text.
                fields.insert("phase".into(), json!("import"));
                copy(&mut fields, "completed", &input, "progressPercent");
                if fields.contains_key("completed") {
                    fields.insert("total".into(), json!(100));
                }
            }
            Self::WorkspaceImportFinished => {
                copy(&mut fields, "duration_ms", &input, "importMilliseconds");
            }
            Self::WorkspaceStalled => {
                fields.insert(
                    "duration_ms".into(),
                    json!(input["idleMilliseconds"].as_u64().unwrap_or(0)),
                );
            }
            Self::BuildWaiting => {
                copy(&mut fields, "reason", &input, "reason");
            }
            Self::BuildExecution => {
                id = identity.event(if input["errorCode"].as_str().is_some() {
                    "build.execution.failed"
                } else if input.get("outcome").is_some() {
                    "build.execution.finished"
                } else {
                    "build.execution.started"
                });
                if let Some(code) = input["errorCode"].as_str() {
                    failure(&mut fields, code);
                }
                if input.get("outcome").is_some() {
                    fields.insert(
                        "duration_ms".into(),
                        json!(input["elapsedMilliseconds"].as_u64().unwrap_or(0)),
                    );
                }
                fields.insert(
                    "waiters".into(),
                    json!(input["waiterCount"].as_u64().unwrap_or(0)),
                );
                for (target, source) in [
                    ("waited_ms", "waitedMilliseconds"),
                    ("outcome", "outcome"),
                    ("marker_scope", "markerScope"),
                    ("builder_failed_earlier", "builderFailedEarlier"),
                ] {
                    copy(&mut fields, target, &input, source);
                }
                if let Some(recovery) = input.get("recovery").filter(|v| !v.is_null()) {
                    fields.insert(
                        "recovery".into(),
                        json!(recovery
                            .as_bool()
                            .unwrap_or_else(|| recovery.as_str().is_some_and(|v| v != "none"))),
                    );
                }
            }
            Self::Dropped => {
                fields.clear();
                fields.insert("count".into(), input["count"].clone());
                id = "log.dropped".into();
            }
            _ => {}
        }
        (id, fields)
    }

    pub(super) fn maven_project_fact(
        identity: &SessionLogIdentity,
        result: &MavenProfileProjectResult,
    ) -> (String, Fields) {
        let input = json!({"projectUri": result.project_uri, "status": result.status});
        // State updates carry no duplicate error payload; the explicit issue event
        // owns the failure boundary, while this entry describes the project state.
        Self::MavenProjectFinished.fact(identity, &input, None)
    }

    pub(super) fn notification(method: &str, params: &Value) -> (Self, Value) {
        match method {
            "window/logMessage" | "window/showMessage" => {
                let severity = match params["type"].as_u64() {
                    Some(1) => "error",
                    Some(2) => "warning",
                    Some(3) => "info",
                    Some(4) => "log",
                    _ => "debug",
                };
                (
                    if method == "window/logMessage" {
                        Self::MessageLogged
                    } else {
                        Self::MessageShown
                    },
                    json!({"diagnostic": params["message"].as_str().unwrap_or_default(), "severity": severity}),
                )
            }
            "$/logTrace" => {
                // Verbose trace can contain raw RPC bodies and document text.
                // Only the diagnostic summary may cross the v2 persistence ingress.
                // Bound before copying; shared normalization then redacts it.
                let diagnostic: String = params["message"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .scan(0, |bytes, c| {
                        *bytes += c.len_utf8();
                        (*bytes <= 1024).then_some(c)
                    })
                    .collect();
                (Self::TraceReceived, json!({"diagnostic": diagnostic}))
            }
            _ => {
                let method = if method.len() <= 64
                    && method
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._:/-$".contains(&b))
                {
                    method
                } else {
                    "unknown"
                };
                (Self::NotificationReceived, json!({"method": method}))
            }
        }
    }
}

const MAX_STDERR_LINE: usize = 4096;
const MAX_STDERR_LINES_PER_SECOND: u64 = 200;

/// Reader-owned framing and rate state. The caller supplies monotonic elapsed
/// milliseconds, making window transitions testable without sleeps or timers.
#[derive(Default)]
pub(super) struct StderrLines {
    line: Vec<u8>,
    truncated: bool,
    window: u64,
    accepted: u64,
    dropped: u64,
}

/// Bounded observation emitted to the session only after framing a whole line.
#[derive(Debug, PartialEq)]
pub(super) enum StderrFact {
    Line { diagnostic: String, truncated: bool },
    Dropped(u64),
}

impl StderrLines {
    fn roll(&mut self, milliseconds: u64, emit: &mut impl FnMut(StderrFact)) {
        let window = milliseconds / 1000;
        if window > self.window {
            self.flush_dropped(emit);
            self.window = window;
            self.accepted = 0;
        }
    }

    fn flush_dropped(&mut self, emit: &mut impl FnMut(StderrFact)) {
        if self.dropped > 0 {
            emit(StderrFact::Dropped(std::mem::take(&mut self.dropped)));
        }
    }

    fn finish_line(&mut self, emit: &mut impl FnMut(StderrFact)) {
        if !self.truncated && self.line.last() == Some(&b'\r') {
            self.line.pop();
        }
        if !self.line.is_empty() {
            if self.accepted < MAX_STDERR_LINES_PER_SECOND {
                self.accepted += 1;
                let mut diagnostic = String::from_utf8_lossy(&self.line).into_owned();
                // Lossy replacement can expand invalid UTF-8; keep the byte bound.
                let mut end = diagnostic.len().min(MAX_STDERR_LINE);
                while !diagnostic.is_char_boundary(end) {
                    end -= 1;
                }
                diagnostic.truncate(end);
                emit(StderrFact::Line {
                    diagnostic,
                    truncated: self.truncated,
                });
            } else {
                self.dropped = self.dropped.saturating_add(1);
            }
        }
        self.line.clear();
        self.truncated = false;
    }

    pub(super) fn feed(
        &mut self,
        bytes: &[u8],
        milliseconds: u64,
        mut emit: impl FnMut(StderrFact),
    ) {
        self.roll(milliseconds, &mut emit);
        for byte in bytes {
            if *byte == b'\n' {
                self.finish_line(&mut emit);
            } else if self.line.len() < MAX_STDERR_LINE {
                self.line.push(*byte);
            } else {
                self.truncated = true;
            }
        }
    }

    pub(super) fn finish(&mut self, milliseconds: u64, mut emit: impl FnMut(StderrFact)) {
        self.roll(milliseconds, &mut emit);
        self.finish_line(&mut emit);
        self.flush_dropped(&mut emit);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostics_resolve_engine_subject_matches_startup_and_rejects_invalid_arguments() {
        for (role, provider, plugin, subject) in [
            (SessionRole::LanguageServer, "c++", None, None),
            (
                SessionRole::Vcs,
                "opaque:any",
                Some("io.example"),
                Some("git"),
            ),
            (SessionRole::Build, "opaque:any", Some("io.example"), None),
            (
                SessionRole::Toolchain,
                "opaque:any",
                Some("../plugin"),
                None,
            ),
            (SessionRole::Backend, "opaque:any", None, None),
        ] {
            let response: Value = serde_json::from_str(&crate::runtime::execute_json(&json!({
                "version": 1, "command": "diagnostics.resolveEngineLogSubject",
                "payload": {"role": role, "providerId": provider, "pluginId": plugin, "logSubject": subject}
            }).to_string())).unwrap();
            let expected = SessionLogIdentity::new(role, provider, plugin, subject);
            assert_eq!(
                response["data"],
                json!({"channel": expected.channel(), "segment": expected.subject})
            );
        }
        for payload in [
            json!({}),
            json!({"role":"unknown", "providerId":"id"}),
            json!({"role":"language_server", "providerId": 5}),
        ] {
            let response: Value = serde_json::from_str(&crate::runtime::execute_json(
                &json!({
                    "version":1, "command":"diagnostics.resolveEngineLogSubject", "payload":payload
                })
                .to_string(),
            ))
            .unwrap();
            assert_eq!(response["error"]["code"], "invalid_request");
        }
    }

    #[test]
    fn stderr_frames_chunks_crlf_long_lines_and_eof_without_clock_waits() {
        let mut lines = StderrLines::default();
        let mut facts = Vec::new();
        lines.feed(b"\n\r\nfirst\r", 0, |f| facts.push(f));
        lines.feed(b"\nsecond\n", 0, |f| facts.push(f));
        lines.feed(&vec![b'x'; 6000], 0, |f| facts.push(f));
        lines.feed(b"ignored\nlast", 0, |f| facts.push(f));
        lines.finish(0, |f| facts.push(f));
        assert_eq!(
            facts,
            vec![
                StderrFact::Line {
                    diagnostic: "first".into(),
                    truncated: false
                },
                StderrFact::Line {
                    diagnostic: "second".into(),
                    truncated: false
                },
                StderrFact::Line {
                    diagnostic: "x".repeat(4096),
                    truncated: true
                },
                StderrFact::Line {
                    diagnostic: "last".into(),
                    truncated: false
                },
            ]
        );
    }

    #[test]
    fn stderr_counts_overflow_on_window_roll_and_session_end() {
        let mut lines = StderrLines::default();
        let mut facts = Vec::new();
        lines.feed("line\n".repeat(205).as_bytes(), 999, |f| facts.push(f));
        assert_eq!(facts.len(), 200);
        lines.feed(b"next\n", 1000, |f| facts.push(f));
        assert_eq!(facts[200], StderrFact::Dropped(5));
        lines.feed("line\n".repeat(201).as_bytes(), 1001, |f| facts.push(f));
        lines.finish(1001, |f| facts.push(f));
        assert_eq!(facts.last(), Some(&StderrFact::Dropped(2)));
        assert_eq!(
            facts
                .iter()
                .filter(|f| matches!(f, StderrFact::Line { .. }))
                .count(),
            400
        );
    }

    #[test]
    fn roles_route_opaque_provider_ids_without_parsing_prefixes() {
        for (role, provider, subject, plugin, expected) in [
            (SessionRole::LanguageServer, "java", None, None, "lsp/java"),
            (
                SessionRole::Vcs,
                "vcsProvider:any:thing",
                Some("git"),
                Some("io.git"),
                "vcs/git",
            ),
            (
                SessionRole::Build,
                "opaque:any",
                None,
                Some("io.build"),
                "plugins/io.build/host",
            ),
            (
                SessionRole::Toolchain,
                "opaque:any",
                None,
                Some("io.build"),
                "plugins/io.build/host",
            ),
            (
                SessionRole::Backend,
                "opaque:any",
                None,
                Some("io.build"),
                "plugins/io.build/host",
            ),
        ] {
            let identity = SessionLogIdentity::new(role, provider, plugin, subject);
            assert_eq!(identity.channel(), expected);
            for event in [
                EngineLog::StderrReceived,
                EngineLog::StderrReadFailed,
                EngineLog::MessageLogged,
                EngineLog::MessageShown,
                EngineLog::TraceReceived,
                EngineLog::NotificationReceived,
                EngineLog::ProcessStarted,
                EngineLog::ProtocolInitialized,
                EngineLog::ResponseSkipped,
                EngineLog::ShutdownTimedOut,
                EngineLog::SessionUpdated,
            ] {
                assert!(
                    crate::diagnostics::catalog::event_by_id(&identity.event(event.suffix()))
                        .is_some()
                );
            }
        }
        for (role, value) in [
            (SessionRole::LanguageServer, "c++"),
            (SessionRole::Vcs, "invalid:id"),
            (SessionRole::Backend, "../plugin"),
        ] {
            let first = SessionLogIdentity::new(role, value, Some(value), Some(value));
            assert!(first.subject.starts_with("invalid-"));
            assert_eq!(
                first.channel(),
                SessionLogIdentity::new(role, value, Some(value), Some(value)).channel()
            );
            assert!(crate::diagnostics::channel::LogChannel::parse(&first.channel()).is_ok());
        }
        let missing = SessionLogIdentity::new(SessionRole::Vcs, "opaque:id", None, None);
        assert!(missing.subject.starts_with("invalid-"));
    }
}
