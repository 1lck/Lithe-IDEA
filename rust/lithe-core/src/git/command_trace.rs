//! One terminal trace per Git process, recorded at the execution point.
//!
//! Every local and remote Git spawn passes through here so the log shows which
//! command ran, for which source and how it ended. Argument text reaches the log
//! only through `format_arguments`; formatting argv anywhere else would bypass
//! redaction. Stdout, stdin and the process environment are never recorded.

use super::console::Source;
use super::{execution_events, execution_policy};
use crate::diagnostics::core_events;
use crate::diagnostics::record::LogLevel;
use crate::diagnostics::request_trace;
use crate::protocol::{CoreError, ErrorCode};
use serde_json::json;
use std::collections::BTreeMap;
use std::time::Instant;

/// Text fields share the record encoder's 1 KiB cap; keeping the bound here lets
/// truncation mark itself instead of being cut silently.
const MAX_TEXT_BYTES: usize = 1024;
const STDERR_LINES: usize = 8;
/// Git prints its reason last; older stderr is irrelevant once the tail is known.
const STDERR_TAIL_BYTES: usize = 16 * 1024;
const MESSAGE: &str = "<message>";

/// Config keys whose values carry credentials or personal identity.
const SENSITIVE_CONFIG: [&str; 10] = [
    "credential",
    "extraheader",
    "token",
    "password",
    "secret",
    "auth",
    "cookie",
    "user.",
    "author.",
    "committer.",
];

/// Active process trace; `finish` records exactly one terminal event.
pub(super) struct Trace {
    arguments: Vec<String>,
    repository: String,
    source: Source,
    remote: bool,
    visible: bool,
    op: Option<String>,
    started: Instant,
    exit_code: Option<i32>,
    stderr: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Succeeded,
    Cancelled,
    Failed,
}

impl Trace {
    /// Captures provenance on the request thread, before any reader thread exists.
    pub(super) fn begin(repository: &str, arguments: &[String], visible: bool) -> Self {
        let context = request_trace::current();
        let source = match execution_policy::current().source {
            Source::Unknown => context.source,
            source => source,
        };
        Self {
            arguments: arguments.to_vec(),
            repository: repository.to_owned(),
            source,
            remote: crate::remote::workspace::is_remote(),
            visible,
            op: context.op,
            started: Instant::now(),
            exit_code: None,
            stderr: Vec::new(),
        }
    }

    /// Keeps the native exit status and the stderr tail as soon as the process ends,
    /// so runner errors raised afterwards still report what Git printed.
    pub(super) fn observe(&mut self, exit_code: Option<i32>, stderr: &[u8]) {
        self.exit_code = exit_code;
        let start = stderr.len().saturating_sub(STDERR_TAIL_BYTES);
        self.stderr = stderr[start..].to_vec();
    }

    /// Records the process outcome; `error` is the runner error returned to the caller.
    pub(super) fn finish(self, error: Option<&CoreError>) {
        let outcome = outcome(
            &self.arguments,
            self.exit_code,
            error,
            self.visible,
            self.source,
        );
        let (event, level) = match outcome {
            Outcome::Failed => ("vcs.git.command.failed", LogLevel::Warn),
            _ if self.visible && self.source == Source::User => {
                ("vcs.git.command.finished", LogLevel::Info)
            }
            _ => ("vcs.git.command.traced", LogLevel::Debug),
        };
        if !core_events::accepts(level, "vcs") {
            return;
        }
        let command = execution_policy::command_index(&self.arguments)
            .map(|index| self.arguments[index].as_str())
            .filter(|command| token(command))
            .unwrap_or("unknown");
        let mut fields = BTreeMap::from([
            ("command".to_string(), json!(command)),
            (
                "arguments".to_string(),
                json!(format_arguments(&self.arguments)),
            ),
            (
                "source".to_string(),
                json!(request_trace::source_token(self.source)),
            ),
            (
                "duration_ms".to_string(),
                json!(self.started.elapsed().as_millis() as u64),
            ),
        ]);
        if !self.repository.is_empty() {
            fields.insert("repository".into(), json!(self.repository));
        }
        if self.remote {
            fields.insert("remote".into(), json!(true));
        }
        if let Some(code) = self.exit_code {
            fields.insert("exit_code".into(), json!(code));
        }
        if outcome == Outcome::Cancelled {
            fields.insert("cancelled".into(), json!(true));
        }
        if outcome == Outcome::Failed {
            if let Some(error) = error {
                let code = serde_json::to_value(&error.code).expect("Core error codes encode");
                fields.insert(
                    "error".into(),
                    json!(execution_events::redact(&error.message)),
                );
                fields.insert("error_code".into(), code);
                fields.insert("error_domain".into(), json!("core"));
            }
        }
        if outcome != Outcome::Succeeded || self.exit_code.is_some_and(|code| code != 0) {
            if let Some(stderr) = stderr_tail(&self.stderr) {
                fields.insert("stderr".into(), json!(stderr));
            }
        }
        if core_events::record(event, fields, self.op).is_err() {
            core_events::note_dropped();
        }
    }
}

/// Classifies one process; nonzero exits are failures only where Git means failure.
fn outcome(
    arguments: &[String],
    exit_code: Option<i32>,
    error: Option<&CoreError>,
    visible: bool,
    source: Source,
) -> Outcome {
    match (error, exit_code) {
        (Some(error), _) if matches!(error.code, ErrorCode::Cancelled) => Outcome::Cancelled,
        (Some(_), _) => Outcome::Failed,
        (None, Some(0)) => Outcome::Succeeded,
        (None, Some(code)) if exit_is_answer(arguments, code) => Outcome::Succeeded,
        // Background plumbing reports a nonzero exit to a caller that decides what it
        // means; the request trace records the failure if the caller returns one.
        (None, Some(_)) if !visible && source != Source::User => Outcome::Succeeded,
        _ => Outcome::Failed,
    }
}

/// Exit statuses that answer a question instead of reporting an error.
/// Add a row whenever Core starts relying on another command's documented status.
pub(super) fn exit_is_answer(arguments: &[String], code: i32) -> bool {
    let Some(index) = execution_policy::command_index(arguments) else {
        return false;
    };
    let rest = &arguments[index + 1..];
    let has = |flags: &[&str]| {
        rest.iter()
            .any(|argument| flags.contains(&argument.as_str()))
    };
    match (arguments[index].as_str(), code) {
        ("config", 1) => has(&["--get", "--get-all", "--get-regexp"]),
        ("merge-base", 1) => has(&["--is-ancestor"]),
        ("diff" | "diff-index" | "diff-files", 1) => has(&["--quiet", "--exit-code"]),
        ("rev-parse", 1) => has(&["--verify"]) && has(&["--quiet", "-q"]),
        ("symbolic-ref", 1) => has(&["--quiet", "-q"]),
        ("show-ref", 1) => has(&["--verify", "--quiet", "-q"]),
        ("show-ref", 2) => has(&["--exists"]),
        ("check-ignore" | "check-ref-format" | "grep", 1) => true,
        ("ls-remote", 2) => has(&["--exit-code"]),
        // Repository discovery outside a work tree and counts without an upstream.
        ("rev-parse", 128) => has(&[
            "--show-toplevel",
            "--absolute-git-dir",
            "--git-dir",
            "--git-common-dir",
            "--is-inside-work-tree",
        ]),
        ("rev-list", 128) => rest
            .iter()
            .any(|argument| argument.contains("@{upstream}") || argument.contains("@{u}")),
        _ => false,
    }
}

/// The only formatter allowed to put Git argv into a log record.
/// Message values become `<message>`, sensitive `-c` values are removed, URL
/// userinfo and private paths are redacted, and the result is capped at 1 KiB.
pub(crate) fn format_arguments(arguments: &[String]) -> String {
    let mut parts = Vec::with_capacity(arguments.len());
    let mut message_next = false;
    let mut config_next = false;
    for argument in arguments {
        let part = if std::mem::take(&mut message_next) {
            MESSAGE.to_owned()
        } else if std::mem::take(&mut config_next) {
            redact_config(argument)
        } else {
            match argument.as_str() {
                "-m" | "--message" => {
                    message_next = true;
                    argument.clone()
                }
                "-c" => {
                    config_next = true;
                    argument.clone()
                }
                value if value.starts_with("--message=") => format!("--message={MESSAGE}"),
                value if value.len() > 2 && value.starts_with("-m") => format!("-m{MESSAGE}"),
                value => value.to_owned(),
            }
        };
        parts.push(quote(execution_events::redact(&part)));
    }
    truncate_end(parts.join(" "))
}

fn redact_config(assignment: &str) -> String {
    let Some((key, _)) = assignment.split_once('=') else {
        return assignment.to_owned();
    };
    let lower = key.to_ascii_lowercase();
    if SENSITIVE_CONFIG.iter().any(|marker| lower.contains(marker)) {
        format!("{key}=<redacted>")
    } else {
        assignment.to_owned()
    }
}

fn quote(argument: String) -> String {
    if argument.is_empty()
        || argument
            .chars()
            .any(|character| character.is_whitespace() || matches!(character, '"' | '\'' | '\\'))
    {
        format!("{argument:?}")
    } else {
        argument
    }
}

/// Last non-empty stderr lines, redacted and joined with ` | `, oldest text dropped first.
pub(super) fn stderr_tail(stderr: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(stderr);
    let lines = text
        .split(['\n', '\r'])
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    let start = lines.len().saturating_sub(STDERR_LINES);
    let tail = lines[start..]
        .iter()
        .map(|line| execution_events::redact(line))
        .collect::<Vec<_>>()
        .join(" | ");
    (!tail.is_empty()).then(|| truncate_start(tail))
}

fn truncate_end(text: String) -> String {
    if text.len() <= MAX_TEXT_BYTES {
        return text;
    }
    let mut end = MAX_TEXT_BYTES - '…'.len_utf8();
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &text[..end])
}

fn truncate_start(text: String) -> String {
    if text.len() <= MAX_TEXT_BYTES {
        return text;
    }
    let mut start = text.len() - (MAX_TEXT_BYTES - '…'.len_utf8());
    while !text.is_char_boundary(start) {
        start += 1;
    }
    format!("…{}", &text[start..])
}

fn token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:/-$".contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn arguments_hide_messages_credentials_and_quote_where_needed() {
        assert_eq!(
            format_arguments(&args(&["commit", "-m", "fix secret bug", "--", "a b.txt"])),
            r#"commit -m <message> -- "a b.txt""#
        );
        assert_eq!(
            format_arguments(&args(&["tag", "-mrelease notes", "--message=body", "v1"])),
            "tag -m<message> --message=<message> v1"
        );
        assert_eq!(
            format_arguments(&args(&["merge", "--message", "Merge it", "topic"])),
            "merge --message <message> topic"
        );
        assert_eq!(
            format_arguments(&args(&[
                "-c",
                "http.extraHeader=Authorization: Bearer abc",
                "-c",
                "credential.helper=store",
                "-c",
                "core.quotePath=false",
                "fetch",
                "https://alice:hunter2@example.com/repo.git",
                ""
            ])),
            r#"-c http.extraHeader=<redacted> -c credential.helper=<redacted> -c core.quotePath=false fetch https://redacted@example.com/repo.git """#
        );
        let formatted = format_arguments(&args(&["commit", "-m", "fix secret bug"]));
        assert!(!formatted.contains("secret"));
    }

    #[test]
    fn arguments_are_capped_with_a_visible_marker() {
        let long = vec!["x".repeat(600), "é".repeat(400)];
        let formatted = format_arguments(&long);
        assert!(formatted.len() <= MAX_TEXT_BYTES);
        assert!(formatted.ends_with('…'));
        assert!(formatted.starts_with(&"x".repeat(600)));
    }

    #[test]
    fn documented_answer_statuses_are_not_failures() {
        for (arguments, code) in [
            (args(&["config", "--get", "remote.origin.url"]), 1),
            (
                args(&["-c", "a=b", "merge-base", "--is-ancestor", "a", "b"]),
                1,
            ),
            (args(&["diff", "--quiet"]), 1),
            (args(&["diff-files", "--exit-code"]), 1),
            (args(&["rev-parse", "--verify", "--quiet", "HEAD"]), 1),
            (args(&["symbolic-ref", "--quiet", "HEAD"]), 1),
            (
                args(&["show-ref", "--verify", "--quiet", "refs/heads/x"]),
                1,
            ),
            (args(&["show-ref", "--exists", "refs/heads/x"]), 2),
            (args(&["check-ignore", "-q", "file"]), 1),
            (args(&["ls-remote", "--exit-code", "origin"]), 2),
            (args(&["rev-parse", "--show-toplevel"]), 128),
            (args(&["rev-list", "--count", "@{upstream}...HEAD"]), 128),
        ] {
            assert!(exit_is_answer(&arguments, code), "{arguments:?} {code}");
        }
        for (arguments, code) in [
            (args(&["config", "--get", "a"]), 128),
            (args(&["rev-parse", "--verify", "HEAD"]), 1),
            (args(&["checkout", "missing"]), 1),
            (args(&["ls-remote", "origin"]), 2),
            (args(&["--version"]), 1),
        ] {
            assert!(!exit_is_answer(&arguments, code), "{arguments:?} {code}");
        }
    }

    #[test]
    fn outcome_separates_errors_answers_and_background_exits() {
        let checkout = args(&["checkout", "missing"]);
        let cancelled = CoreError::new(ErrorCode::Cancelled, "Operation was cancelled");
        let start = CoreError::new(ErrorCode::ProcessStartFailed, "Could not start Git");
        use Outcome::*;
        use Source::*;
        assert_eq!(
            outcome(&checkout, None, Some(&cancelled), true, User),
            Cancelled
        );
        assert_eq!(
            outcome(&checkout, None, Some(&start), false, Background),
            Failed
        );
        assert_eq!(outcome(&checkout, Some(0), None, true, User), Succeeded);
        assert_eq!(outcome(&checkout, Some(1), None, true, User), Failed);
        assert_eq!(outcome(&checkout, Some(1), None, false, User), Failed);
        assert_eq!(
            outcome(&checkout, Some(1), None, false, Background),
            Succeeded
        );
        assert_eq!(outcome(&checkout, None, None, true, User), Failed);
        let probe = args(&["config", "--get", "user.name"]);
        assert_eq!(outcome(&probe, Some(1), None, true, User), Succeeded);
    }

    #[test]
    fn stderr_keeps_the_last_redacted_lines() {
        let stderr = (1..=12)
            .map(|line| format!("line {line}\n"))
            .collect::<String>()
            + "\rReceiving objects: 50%\rfatal: https://bob:pw@example.com/x.git not found\n\n";
        let tail = stderr_tail(stderr.as_bytes()).unwrap();
        assert!(tail.starts_with("line 7 | line 8"), "{tail}");
        assert!(tail.ends_with("fatal: https://redacted@example.com/x.git not found"));
        assert!(!tail.contains("pw@"));
        assert_eq!(stderr_tail(b" \n\r\n"), None);
        let long = format!("{}\nfatal: last words\n", "y".repeat(4000));
        let tail = stderr_tail(long.as_bytes()).unwrap();
        assert!(tail.len() <= MAX_TEXT_BYTES);
        assert!(tail.starts_with('…') && tail.ends_with("fatal: last words"));
    }
}
