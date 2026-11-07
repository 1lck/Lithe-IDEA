//! Catalog identities, role routing, and bounded stderr framing for managed engines.

use super::engine::LspRuntimeError;
use crate::diagnostics::channel::{digest_segment, identity_segment, validate_segment};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
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
        // segments. Never reject startup or drop evidence: an invalid identity, or
        // the provider when the subject is absent, becomes a stable digest segment.
        let subject = match raw {
            Some(id) => identity_segment(id),
            None => digest_segment(provider),
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

    /// Safe catalog identity shared by typed plugin facts and process lifecycle facts.
    pub(super) fn segment(&self) -> &str {
        &self.subject
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
    ProcessCleanupFailed,
    ProtocolInitialized,
    ResponseSkipped,
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
            Self::ProcessCleanupFailed => "process.cleanup_failed",
            Self::ProcessStarted => "process.started",
            Self::ProtocolInitialized => "protocol.initialized",
            Self::ResponseSkipped => "response.skipped",
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
            Self::ProcessCleanupFailed | Self::StderrReadFailed => failure(&mut fields, code),
            Self::MessageLogged | Self::MessageShown => {
                copy(&mut fields, "diagnostic", &input, "diagnostic");
                copy(&mut fields, "severity", &input, "severity");
                let severity = match input["severity"].as_str() {
                    Some("error") => Some("error"),
                    Some("warning") => Some("warning"),
                    Some("info") => None,
                    _ => Some("detail"),
                };
                if let Some(severity) = severity {
                    let outcome = if matches!(self, Self::MessageLogged) {
                        "logged"
                    } else {
                        "shown"
                    };
                    id = identity.event(&format!("message.{severity}.{outcome}"));
                }
            }
            Self::TraceReceived => {
                copy(&mut fields, "diagnostic", &input, "diagnostic");
            }
            Self::NotificationReceived => {
                copy(&mut fields, "method", &input, "method");
            }
            Self::SessionUpdated => {
                copy(&mut fields, "state", &input, "state");
                if input["state"] == "failed" {
                    id = identity.event("session.failed");
                    fields.insert("code".into(), json!(code));
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
            Self::Dropped => {
                fields.clear();
                fields.insert("count".into(), input["count"].clone());
                id = "log.dropped".into();
            }
            _ => {}
        }
        (id, fields)
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
    fn upstream_severity_follows_explicit_type_and_unclassified_stderr_is_detail() {
        let identity = SessionLogIdentity::new(SessionRole::LanguageServer, "go", None, None);
        for method in ["window/logMessage", "window/showMessage"] {
            for (kind, level) in [
                (1, "ERROR"),
                (2, "WARN"),
                (3, "INFO"),
                (4, "DEBUG"),
                (99, "DEBUG"),
            ] {
                let (event, input) = EngineLog::notification(
                    method,
                    &json!({"type":kind,"message":"upstream fact"}),
                );
                let (id, fields) = event.fact(&identity, &input, None);
                crate::diagnostics::catalog::validate_fields(&id, &fields).unwrap();
                assert_eq!(
                    crate::diagnostics::catalog::event_by_id(&id)
                        .unwrap()
                        .level
                        .label(),
                    level
                );
            }
        }
        assert_eq!(
            crate::diagnostics::catalog::event_by_id("lsp.stderr.received")
                .unwrap()
                .level
                .label(),
            "DEBUG"
        );
        let plugin = SessionLogIdentity::new(
            SessionRole::Backend,
            "provider",
            Some("unsafe:plugin"),
            None,
        );
        assert!(plugin.segment().starts_with("invalid-"));
    }

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
            (
                SessionRole::LanguageServer,
                "tool-a",
                None,
                None,
                "lsp/tool-a",
            ),
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
                EngineLog::ProcessCleanupFailed,
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
        // Cleanup uses the same role-owned directory fields and never derives a
        // catalog fact from legacy message/detail strings.
        for role in [
            SessionRole::LanguageServer,
            SessionRole::Vcs,
            SessionRole::Backend,
        ] {
            let identity = SessionLogIdentity::new(role, "tool-a", Some("io.plugin"), Some("git"));
            let (id, fields) = EngineLog::ProcessCleanupFailed.fact(&identity, &Value::Null, None);
            crate::diagnostics::catalog::validate_fields(&id, &fields).unwrap();
            assert_eq!(fields["error_code"], "operation_failed");
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
