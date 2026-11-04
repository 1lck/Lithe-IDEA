//! One terminal trace per Core request and the request context nested traces inherit.
//!
//! The dispatcher owns the only request boundary every host shares, so recording
//! here covers workspace, plugin and button-driven calls without per-domain code.
//! Failures are WARN because Core cannot know whether the host retries, degrades
//! or gives up. A host notice backed by these facts links to this record; the host
//! adds its own terminal event only for facts Core does not have.

use super::core_events;
use super::record::LogLevel;
use crate::git::console::Source;
use crate::protocol::{CoreRequest, CoreResponse, ErrorCode};
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::time::Instant;

/// Payload keys that name the directory a request works in, in priority order.
const PATH_KEYS: [&str; 7] = [
    "root",
    "workspaceRoot",
    "repositoryRoot",
    "projectRoot",
    "rootPath",
    "directory",
    "path",
];

/// Correlation inherited by Git process traces started inside the request.
#[derive(Debug, Clone, Default)]
pub(crate) struct Context {
    /// Operation shared by the user action, its requests and their Git processes.
    pub(crate) op: Option<String>,
    /// Provenance resolved once from the request envelope.
    pub(crate) source: Source,
}

thread_local! {
    static CURRENT: RefCell<Context> = RefCell::new(Context::default());
}

/// Snapshot for traces that finish on another thread, such as streamed history.
pub(crate) fn current() -> Context {
    CURRENT.with(|current| current.borrow().clone())
}

/// Active request trace; dropping it restores the enclosing request's context.
pub(crate) struct Request {
    method: String,
    operation: Option<String>,
    source: Source,
    trigger: Option<String>,
    path: Option<String>,
    remote: bool,
    op: Option<String>,
    hot: bool,
    started: Instant,
    previous: Context,
}

impl Request {
    /// Captures trace fields before the dispatcher moves the payload into a domain.
    pub(crate) fn begin(request: &CoreRequest) -> Self {
        let origin = request.origin.clone().unwrap_or_default();
        let source = effective_source(
            origin.source,
            request.git_execution.as_ref().map(|options| options.source),
        );
        let op = origin
            .operation
            .filter(|value| identity(value))
            .or_else(|| request.operation_id.clone().filter(|value| identity(value)))
            .or_else(|| request.id.clone().filter(|value| identity(value)));
        let previous = CURRENT.with(|current| {
            current.replace(Context {
                op: op.clone(),
                source,
            })
        });
        let hot = is_hot(&request.command);
        Self {
            method: request.command.clone(),
            operation: (!hot)
                .then(|| request.payload["operation"].as_str().and_then(token))
                .flatten(),
            source,
            trigger: origin.trigger.as_deref().and_then(token),
            path: (!hot).then(|| request_path(&request.payload)).flatten(),
            remote: request.remote_workspace.is_some(),
            op,
            hot,
            started: Instant::now(),
            previous,
        }
    }

    /// Records the terminal event for the response the host will receive.
    pub(crate) fn finish(&self, response: &CoreResponse) {
        if self.hot || token(&self.method).is_none() {
            return;
        }
        let cancelled = response
            .error
            .as_ref()
            .is_some_and(|error| matches!(error.code, ErrorCode::Cancelled));
        let (event, level) = match (&response.error, cancelled) {
            (Some(_), false) => ("app.core.request.failed", LogLevel::Warn),
            _ if self.source == Source::User => ("app.core.request.finished", LogLevel::Info),
            _ => ("app.core.request.traced", LogLevel::Debug),
        };
        if !core_events::accepts(level, "app") {
            return;
        }
        let mut fields = BTreeMap::from([
            ("method".to_string(), json!(self.method)),
            ("source".to_string(), json!(source_token(self.source))),
            (
                "duration_ms".to_string(),
                json!(self.started.elapsed().as_millis() as u64),
            ),
        ]);
        if let Some(operation) = &self.operation {
            fields.insert("operation".into(), json!(operation));
        }
        if let Some(trigger) = &self.trigger {
            fields.insert("trigger".into(), json!(trigger));
        }
        if let Some(path) = &self.path {
            fields.insert("path".into(), json!(path));
        }
        if self.remote {
            fields.insert("remote".into(), json!(true));
        }
        match &response.error {
            Some(error) if !cancelled => {
                let code = serde_json::to_value(&error.code).expect("Core error codes encode");
                fields.insert(
                    "error".into(),
                    json!(crate::git::execution_events::redact(&error.message)),
                );
                fields.insert("error_code".into(), code);
                fields.insert("error_domain".into(), json!("core"));
            }
            _ if cancelled => {
                fields.insert("cancelled".into(), json!(true));
            }
            _ => {}
        }
        if core_events::record(event, fields, self.op.clone()).is_err() {
            core_events::note_dropped();
        }
    }
}

impl Drop for Request {
    fn drop(&mut self) {
        let previous = std::mem::take(&mut self.previous);
        CURRENT.with(|current| current.replace(previous));
    }
}

/// Methods called per keystroke, per frame, per poll tick or per watcher batch.
/// Tracing them would bury user operations and fill the Core queue, so they
/// record nothing; add every new high-frequency method here.
pub(crate) fn is_hot(method: &str) -> bool {
    // The logging system must never trace its own drain, query or encode calls.
    method == "core.ping"
        || method.starts_with("diagnostics.")
        // Typing, caret movement and rendering run these on every edit or frame.
        || method.starts_with("editor.")
        || method.starts_with("keymap.")
        || matches!(
            method,
            "document.classifyText"
                | "document.lifecycle"
                | "markdown.render"
                | "lsp.syncDocument"
                | "lsp.closeDocument"
                | "lsp.request"
                | "lsp.applyTextEdits"
                | "lsp.plainSnippet"
                | "lsp.builtinCompletions"
                | "lsp.builtinHover"
                | "lsp.builtinNavigation"
                | "java.codeVision"
                | "java.navigationMarkers"
                | "java.runMarkers"
                | "java.structure"
        )
        // Search-as-you-type issues one request per query revision.
        || matches!(
            method,
            "search.actions"
                | "workspace.search"
                | "workspace.searchEverywhere"
                | "workspace.replacePreview"
        )
        // Polling loops and message pumps run continuously while a session lives.
        || matches!(
            method,
            "lsp.pollEvents"
                | "lsp.waitEvents"
                | "lsp.cancelOperation"
                | "lsp.hostResponse"
                | "lsp.hostNotify"
                | "debug.receive"
                | "debug.transport.handle"
                | "git.consolePresentation"
        )
        // File watchers forward one batch per debounce window.
        || matches!(
            method,
            "workspace.filterChanges" | "lsp.workspaceFilesChanged"
        )
}

/// Explicit host provenance wins; Git provenance covers hosts that send only that.
pub(crate) fn effective_source(origin: Option<Source>, git: Option<Source>) -> Source {
    match origin {
        Some(source) if source != Source::Unknown => source,
        _ => git.unwrap_or_default(),
    }
}

pub(crate) fn source_token(source: Source) -> &'static str {
    match source {
        Source::User => "user",
        Source::Background => "background",
        Source::Unknown => "unknown",
    }
}

fn request_path(payload: &Value) -> Option<String> {
    PATH_KEYS.iter().find_map(|key| {
        payload[*key]
            .as_str()
            .filter(|path| std::path::Path::new(path).is_absolute())
            .map(str::to_owned)
    })
}

/// Catalog token shape; anything else is omitted rather than failing the record.
fn token(value: &str) -> Option<String> {
    (!value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:/-$".contains(&byte)))
    .then(|| value.to_owned())
}

/// Correlation identity accepted by the record encoder, bounded for one log line.
pub(crate) fn identity(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:/@+-".contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::core_events::capture;

    fn request(value: Value) -> CoreRequest {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn source_prefers_explicit_origin_then_git_policy() {
        use Source::*;
        assert_eq!(effective_source(Some(User), Some(Background)), User);
        assert_eq!(
            effective_source(Some(Unknown), Some(Background)),
            Background
        );
        assert_eq!(effective_source(None, Some(User)), User);
        assert_eq!(effective_source(None, None), Unknown);
    }

    #[test]
    fn hot_methods_record_nothing_and_user_operations_still_trace() {
        for method in [
            "core.ping",
            "diagnostics.drainCoreEvents",
            "editor.lineEdit",
            "keymap.evaluateContext",
            "lsp.syncDocument",
            "lsp.pollEvents",
            "document.lifecycle",
            "workspace.search",
            "workspace.filterChanges",
            "debug.transport.handle",
        ] {
            assert!(is_hot(method), "{method}");
        }
        for method in [
            "git.write",
            "git.status",
            "workspace.snapshot",
            "file.write",
            "lsp.startServer",
            "remote.connect",
            "debug.launch",
        ] {
            assert!(!is_hot(method), "{method}");
        }
        let ((), events) = capture::run(true, || {
            let trace = Request::begin(&request(json!({
                "command": "lsp.syncDocument",
                "origin": {"source": "user"},
                "payload": {}
            })));
            trace.finish(&CoreResponse::success(None, json!({})));
        });
        assert!(events.is_empty());
    }

    #[test]
    fn fields_keep_valid_tokens_and_omit_invalid_ones() {
        let ((), events) = capture::run(false, || {
            let trace = Request::begin(&request(json!({
                "id": "request-1",
                "command": "git.write",
                "origin": {"source": "user", "trigger": "vcs.fetch", "operation": "action-7"},
                "payload": {"operation": "fetch", "root": "/tmp/project", "path": "/ignored"}
            })));
            assert_eq!(current().op.as_deref(), Some("action-7"));
            assert_eq!(current().source, Source::User);
            trace.finish(&CoreResponse::success(None, json!({})));
            drop(trace);
            assert_eq!(current().op, None);

            let trace = Request::begin(&request(json!({
                "id": "request-2",
                "command": "git.write",
                "origin": {"source": "user", "trigger": "Fetch now", "operation": "has space"},
                "payload": {"operation": "push --force", "root": "relative/project"}
            })));
            trace.finish(&CoreResponse::success(None, json!({})));
        });
        assert_eq!(events.len(), 2);
        let first = &events[0];
        assert_eq!(first.event, "app.core.request.finished");
        assert_eq!(first.channel, "app/core");
        assert_eq!(first.op.as_deref(), Some("action-7"));
        assert_eq!(first.fields["method"], "git.write");
        assert_eq!(first.fields["operation"], "fetch");
        assert_eq!(first.fields["trigger"], "vcs.fetch");
        assert_eq!(first.fields["source"], "user");
        assert_eq!(first.fields["path"], "<PATH>");
        assert!(first.fields.contains_key("duration_ms"));
        let second = &events[1];
        assert_eq!(second.op.as_deref(), Some("request-2"));
        for omitted in ["operation", "trigger", "path"] {
            assert!(!second.fields.contains_key(omitted), "{omitted}");
        }
    }

    #[test]
    fn failures_warn_and_background_success_obeys_the_debug_gate() {
        use crate::protocol::CoreError;
        let failing = || {
            let trace = Request::begin(&request(json!({
                "command": "workspace.snapshot",
                "gitExecution": {"source": "background"},
                "payload": {}
            })));
            trace.finish(&CoreResponse::failure(
                None,
                CoreError::new(ErrorCode::PermissionDenied, "Workspace is not readable"),
            ));
        };
        let background = || {
            let trace = Request::begin(&request(json!({
                "command": "git.status",
                "origin": {"source": "background"},
                "payload": {}
            })));
            trace.finish(&CoreResponse::success(None, json!({})));
        };
        let ((), gated) = capture::run(false, || {
            failing();
            background();
        });
        assert_eq!(gated.len(), 1);
        assert_eq!(gated[0].event, "app.core.request.failed");
        assert_eq!(gated[0].level, LogLevel::Warn);
        assert_eq!(gated[0].fields["error"], "Workspace is not readable");
        assert_eq!(gated[0].fields["error_code"], "permission_denied");
        assert_eq!(gated[0].fields["error_domain"], "core");
        assert_eq!(gated[0].fields["source"], "background");

        let ((), enabled) = capture::run(true, background);
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].event, "app.core.request.traced");
        assert_eq!(enabled[0].level, LogLevel::Debug);
        assert_eq!(enabled[0].fields["source"], "background");
    }

    #[test]
    fn cancellation_is_an_outcome_not_a_failure() {
        use crate::protocol::CoreError;
        let ((), events) = capture::run(false, || {
            let trace = Request::begin(&request(json!({
                "command": "git.write",
                "origin": {"source": "user"},
                "payload": {"operation": "fetch"}
            })));
            trace.finish(&CoreResponse::failure(
                None,
                CoreError::new(ErrorCode::Cancelled, "Operation cancelled"),
            ));
        });
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event, "app.core.request.finished");
        assert_eq!(events[0].fields["cancelled"], true);
        assert!(!events[0].fields.contains_key("error"));
    }
}
