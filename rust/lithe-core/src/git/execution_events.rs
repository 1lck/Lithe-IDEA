//! Request-scoped Git diagnostics and bounded, incremental output decoding.
//!
//! Events contain sanitized diagnostics, never command input or environment.
//! Native process ownership belongs to the `lithe-git-host` adapter.

use crate::protocol::CoreError;
use serde::Serialize;
use std::cell::RefCell;
use std::sync::{Arc, OnceLock};
use std::time::Instant;

const MAX_LINE_BYTES: usize = 16 * 1024;
const MAX_DIAGNOSTIC_BYTES: usize = 512 * 1024;
const MAX_OUTPUT_EVENTS: usize = 4096;
/// A serialized event consumer, invoked synchronously during its owning request.
pub type EventSink = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
/// One ordered diagnostic event within a Core request.
struct Event<'a> {
    operation_id: &'a str,
    #[serde(flatten)]
    kind: Kind<'a>,
}

#[derive(Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
/// Process start is evidence of a spawned child; failure may have no exit code.
enum Kind<'a> {
    RequestStarted,
    RequestFinished {
        error: Option<serde_json::Value>,
    },
    Started {
        invocation_id: u64,
        working_directory: &'a str,
        arguments: &'a [String],
    },
    Output {
        invocation_id: u64,
        stream: &'a str,
        text: String,
        progress: bool,
        truncated: bool,
    },
    Finished {
        invocation_id: u64,
        exit_code: Option<i32>,
        duration_milliseconds: u128,
        error: Option<&'a CoreError>,
    },
}

/// Per-request identity and sequence shared by nested Git invocations.
struct Context {
    sink: EventSink,
    operation_id: String,
    next_invocation: u64,
}
thread_local! { static CURRENT: RefCell<Option<Context>> = const { RefCell::new(None) }; }

/// Installs a consumer only for the duration of this synchronous request.
pub(crate) fn with_sink<T>(sink: EventSink, operation: impl FnOnce() -> T) -> T {
    struct Restore(Option<Context>);
    impl Drop for Restore {
        fn drop(&mut self) {
            CURRENT.with(|current| {
                current.replace(self.0.take());
            });
        }
    }
    let _restore = Restore(CURRENT.with(|current| {
        current.replace(Some(Context {
            sink,
            operation_id: String::new(),
            next_invocation: 0,
        }))
    }));
    operation()
}

/// Called after cancellation registration so immediate cancellation cannot race startup.
pub(crate) fn request_started(operation_id: Option<&str>) {
    let context = CURRENT.with(|current| {
        let mut current = current.borrow_mut();
        let context = current.as_mut()?;
        context.operation_id = operation_id.unwrap_or_default().to_string();
        Some((context.sink.clone(), context.operation_id.clone()))
    });
    if let Some((sink, operation_id)) = context {
        send(&sink, &operation_id, Kind::RequestStarted);
    }
}

/// A final event shares the same ordered channel, including preflight failures.
pub(crate) fn request_finished(response: &str) {
    let context = CURRENT.with(|current| {
        current
            .borrow()
            .as_ref()
            .map(|context| (context.sink.clone(), context.operation_id.clone()))
    });
    let Some((sink, operation_id)) = context else {
        return;
    };
    let value: serde_json::Value = serde_json::from_str(response).unwrap_or_default();
    let raw_error = value
        .get("error")
        .filter(|value| !value.is_null())
        .or_else(|| {
            value
                .pointer("/data/operationError")
                .filter(|value| !value.is_null())
        });
    let error = raw_error.map(|error| serde_json::json!({
        "code": error.get("code"),
        "message": redact(error.get("message").and_then(|value| value.as_str()).unwrap_or("Git operation failed")),
        "details": error.get("details").and_then(|value| value.as_str()).map(redact),
    }));
    let error = error.or_else(|| value.pointer("/data/exitCode").and_then(|value| value.as_i64()).filter(|code| *code != 0).map(|code| serde_json::json!({ "code": "process_failed", "message": format!("Git exited with code {code}") })));
    send(&sink, &operation_id, Kind::RequestFinished { error });
}

/// A traced invocation. The byte decoders are independent for stdout/stderr.
pub(super) struct Invocation {
    sink: EventSink,
    operation_id: String,
    id: u64,
    clock: Instant,
    output_bytes: usize,
    output_events: usize,
    omitted: bool,
    stdout: LineDecoder,
    stderr: LineDecoder,
}
impl Invocation {
    pub(super) fn current() -> Option<Self> {
        CURRENT.with(|current| {
            let mut current = current.borrow_mut();
            let context = current.as_mut()?;
            context.next_invocation += 1;
            Some(Self {
                sink: context.sink.clone(),
                operation_id: context.operation_id.clone(),
                id: context.next_invocation,
                clock: Instant::now(),
                output_bytes: 0,
                output_events: 0,
                omitted: false,
                stdout: LineDecoder::default(),
                stderr: LineDecoder::default(),
            })
        })
    }
    pub(super) fn started(&self, root: &str, arguments: &[String]) {
        let arguments = arguments
            .iter()
            .map(|argument| redact(argument))
            .collect::<Vec<_>>();
        send(
            &self.sink,
            &self.operation_id,
            Kind::Started {
                invocation_id: self.id,
                working_directory: root,
                arguments: &arguments,
            },
        );
    }
    pub(super) fn output(&mut self, stream: lithe_git_host::Stream, bytes: &[u8]) {
        if self.omitted {
            return;
        }
        self.output_bytes += bytes.len();
        if self.output_bytes > MAX_DIAGNOSTIC_BYTES {
            self.omitted = true;
            self.stdout = LineDecoder::default();
            self.stderr = LineDecoder::default();
            send(
                &self.sink,
                &self.operation_id,
                Kind::Output {
                    invocation_id: self.id,
                    stream: "stderr",
                    text: "[Further Git output omitted: diagnostic limit]".into(),
                    progress: false,
                    truncated: true,
                },
            );
            return;
        }
        let (decoder, name) = match stream {
            lithe_git_host::Stream::Stdout => (&mut self.stdout, "stdout"),
            lithe_git_host::Stream::Stderr => (&mut self.stderr, "stderr"),
        };
        let sink = &self.sink;
        let operation_id = &self.operation_id;
        let id = self.id;
        let output_events = &mut self.output_events;
        let omitted = &mut self.omitted;
        decoder.push(bytes, &mut |text, progress, truncated| {
            if *omitted {
                return;
            }
            *output_events += 1;
            if *output_events > MAX_OUTPUT_EVENTS {
                *omitted = true;
                send(
                    sink,
                    operation_id,
                    Kind::Output {
                        invocation_id: id,
                        stream: name,
                        text: "[Further Git output omitted: diagnostic limit]".into(),
                        progress: false,
                        truncated: true,
                    },
                );
                return;
            }
            send(
                sink,
                operation_id,
                Kind::Output {
                    invocation_id: id,
                    stream: name,
                    text,
                    progress,
                    truncated,
                },
            );
        });
    }
    pub(super) fn finished(mut self, exit_code: Option<i32>, error: Option<&CoreError>) {
        if self.omitted {
            self.stdout = LineDecoder::default();
            self.stderr = LineDecoder::default();
        }
        for (name, decoder) in [("stdout", &mut self.stdout), ("stderr", &mut self.stderr)] {
            decoder.flush(&mut |text, progress, truncated| {
                send(
                    &self.sink,
                    &self.operation_id,
                    Kind::Output {
                        invocation_id: self.id,
                        stream: name,
                        text,
                        progress,
                        truncated,
                    },
                )
            });
        }
        // Errors may include native details. They use the same redaction as output.
        let error = error.map(|error| CoreError {
            code: error.code.clone(),
            message: redact(&error.message),
            details: error.details.as_ref().map(|value| redact(value)),
        });
        send(
            &self.sink,
            &self.operation_id,
            Kind::Finished {
                invocation_id: self.id,
                exit_code,
                duration_milliseconds: self.clock.elapsed().as_millis(),
                error: error.as_ref(),
            },
        );
    }
}

fn send(sink: &EventSink, operation_id: &str, kind: Kind<'_>) {
    if let Ok(json) = serde_json::to_string(&Event { operation_id, kind }) {
        sink(&json);
    }
}

/// Redacts complete records, including credentials split across native chunks.
fn redact(text: &str) -> String {
    static URL_AUTH: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = URL_AUTH.get_or_init(|| {
        regex::Regex::new(r"(?i)(https?|ssh)://[^\s/@]+(?::[^\s/@]*)?@")
            .expect("valid URL redaction")
    });
    let text = pattern.replace_all(text, "$1://redacted@").into_owned();
    crate::diagnostics::redact_text(crate::diagnostics::RedactTextRequest { text }).redacted
}

#[derive(Default)]
/// Complete-line decoding avoids exposing a secret before its delimiter arrives.
/// Overlong lines are discarded in full rather than publishing a secret prefix.
struct LineDecoder {
    bytes: Vec<u8>,
    cr: bool,
    overflow: bool,
}
impl LineDecoder {
    fn push(&mut self, bytes: &[u8], emit: &mut impl FnMut(String, bool, bool)) {
        for &byte in bytes {
            if self.cr {
                self.emit(byte != b'\n', emit);
                self.cr = false;
                if byte == b'\n' {
                    continue;
                }
            }
            match byte {
                b'\r' => self.cr = true,
                b'\n' => self.emit(false, emit),
                _ if self.bytes.len() < MAX_LINE_BYTES && !self.overflow => self.bytes.push(byte),
                _ => {
                    self.bytes.clear();
                    self.overflow = true;
                }
            }
        }
    }
    fn emit(&mut self, progress: bool, emit: &mut impl FnMut(String, bool, bool)) {
        let text = if self.overflow {
            "[Git output line omitted: size limit]".to_string()
        } else {
            redact(&String::from_utf8_lossy(&self.bytes))
        };
        emit(text, progress, self.overflow);
        self.bytes.clear();
        self.overflow = false;
    }
    fn flush(&mut self, emit: &mut impl FnMut(String, bool, bool)) {
        if !self.bytes.is_empty() || self.overflow || self.cr {
            self.emit(self.cr, emit);
        }
        self.cr = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn emitted_events_match_the_shared_fixture_and_observer_scope_is_released() {
        let captured = Arc::new(std::sync::Mutex::new(Vec::<serde_json::Value>::new()));
        let sink_capture = captured.clone();
        with_sink(
            Arc::new(move |json| {
                sink_capture
                    .lock()
                    .unwrap()
                    .push(serde_json::from_str(json).unwrap())
            }),
            || {
                request_started(Some("fixture"));
                let mut invocation = Invocation::current().unwrap();
                invocation.started("/workspace", &["fetch".into(), "--progress".into()]);
                invocation.output(
                    lithe_git_host::Stream::Stderr,
                    b"Receiving: 50%\rReceiving: 100%\n",
                );
                invocation.output(lithe_git_host::Stream::Stdout, b"reference updated\n");
                invocation.finished(Some(0), None);
                request_finished(r#"{"ok":true,"data":{"exitCode":0}}"#);
            },
        );
        assert!(Invocation::current().is_none());
        let mut events = captured.lock().unwrap().clone();
        for event in &mut events {
            if event.get("durationMilliseconds").is_some() {
                event["durationMilliseconds"] = serde_json::json!(0);
            }
        }
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/execution-events-v1.json"
        ))
        .unwrap();
        assert_eq!(serde_json::json!(events), fixture["events"]);
    }

    #[test]
    fn diagnostic_budget_keeps_the_final_event_after_output_is_omitted() {
        let captured = Arc::new(std::sync::Mutex::new(Vec::<serde_json::Value>::new()));
        let sink_capture = captured.clone();
        with_sink(
            Arc::new(move |json| {
                sink_capture
                    .lock()
                    .unwrap()
                    .push(serde_json::from_str(json).unwrap())
            }),
            || {
                request_started(Some("budget"));
                let mut invocation = Invocation::current().unwrap();
                invocation.started("/workspace", &["fetch".into()]);
                invocation.output(
                    lithe_git_host::Stream::Stdout,
                    &vec![b'\n'; MAX_OUTPUT_EVENTS + 100],
                );
                invocation.output(lithe_git_host::Stream::Stdout, b"must stay omitted\n");
                invocation.finished(Some(0), None);
            },
        );
        let events = captured.lock().unwrap();
        assert_eq!(events.len(), MAX_OUTPUT_EVENTS + 4);
        assert_eq!(events[events.len() - 2]["truncated"], true);
        assert_eq!(events.last().unwrap()["type"], "finished");
    }

    #[test]
    fn output_handles_split_utf8_crlf_progress_and_credentials() {
        let mut decoder = LineDecoder::default();
        let mut lines = Vec::new();
        let mut emit = |text, progress, truncated| lines.push((text, progress, truncated));
        for byte in "获取\r\nReceiving: 10%\rReceiving: 20%\nhttps://user:secret@example.invalid/repo?token=fake\nlast".as_bytes() {
            decoder.push(&[*byte], &mut emit);
        }
        decoder.flush(&mut emit);
        assert_eq!(lines.len(), 5);
        assert_eq!(lines[0], ("获取".into(), false, false));
        assert_eq!(lines[1], ("Receiving: 10%".into(), true, false));
        assert!(!lines[3].0.contains("secret"));
        assert!(!lines[3].0.contains("fake"));
        assert_eq!(lines[4].0, "last");
    }
    #[test]
    fn overlong_output_is_bounded_and_recovers_at_next_line() {
        let mut decoder = LineDecoder::default();
        let mut lines = Vec::new();
        let mut emit = |text, progress, truncated| lines.push((text, progress, truncated));
        decoder.push(&vec![b'x'; MAX_LINE_BYTES * 3], &mut emit);
        assert!(decoder.bytes.is_empty());
        decoder.push(b"\nsafe\n", &mut emit);
        assert!(lines[0].2);
        assert_eq!(lines[1].0, "safe");
    }
}
