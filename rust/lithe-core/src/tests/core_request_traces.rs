use super::support::temporary_root;
use crate::diagnostics::core_events::{capture, CoreEvent};
use crate::diagnostics::record::LogLevel;
use crate::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn repository(label: &str) -> PathBuf {
    let root = temporary_root(label);
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    for arguments in [
        &["init", "-q"][..],
        &["config", "user.name", "Trace Test"],
        &["config", "user.email", "trace@example.invalid"],
        &["config", "commit.gpgsign", "false"],
    ] {
        let status = Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .status()
            .expect("git should be available");
        assert!(status.success(), "git {arguments:?}");
    }
    root
}

fn send(request: Value) -> (Value, Vec<CoreEvent>) {
    let (response, events) = capture::run(false, || execute_json(&request.to_string()));
    (
        serde_json::from_str(&response).expect("Core response should be JSON"),
        events,
    )
}

fn git_command(root: &Path, origin: Value, arguments: &[&str]) -> Value {
    json!({
        "id": "request-1",
        "command": "git.command",
        "origin": origin,
        "payload": {"root": root, "arguments": arguments}
    })
}

fn only<'a>(events: &'a [CoreEvent], id: &str) -> &'a CoreEvent {
    let matching = events
        .iter()
        .filter(|event| event.event == id)
        .collect::<Vec<_>>();
    assert_eq!(matching.len(), 1, "{id} in {events:?}");
    matching[0]
}

#[test]
fn user_git_command_records_redacted_argv_under_the_action_operation() {
    let root = repository("trace-commit");
    let origin = json!({"source": "user", "trigger": "vcs.commit", "operation": "action-1"});
    let (response, events) = send(git_command(
        &root,
        origin,
        &["commit", "--allow-empty", "-m", "secret subject"],
    ));
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["exitCode"], 0);

    let git = only(&events, "vcs.git.command.finished");
    assert_eq!(git.level, LogLevel::Info);
    assert_eq!(git.channel, "vcs/git");
    assert_eq!(git.op.as_deref(), Some("action-1"));
    assert_eq!(git.fields["command"], "commit");
    assert_eq!(git.fields["source"], "user");
    assert_eq!(git.fields["exit_code"], 0);
    let arguments = git.fields["arguments"].as_str().unwrap();
    assert!(
        arguments.contains("commit --allow-empty -m <message>"),
        "{arguments}"
    );
    assert!(!git.fields.contains_key("stderr"));

    let request = only(&events, "app.core.request.finished");
    assert_eq!(request.op.as_deref(), Some("action-1"));
    assert_eq!(request.fields["method"], "git.command");
    assert_eq!(request.fields["trigger"], "vcs.commit");
    assert_eq!(request.fields["path"], "<PATH>");

    let serialized = serde_json::to_string(&events).unwrap();
    assert!(!serialized.contains("secret"), "{serialized}");
    assert!(
        !serialized.contains(&*root.to_string_lossy()),
        "{serialized}"
    );
    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn failing_git_command_warns_with_exit_code_and_stderr_tail() {
    let root = repository("trace-checkout");
    let (response, events) = send(git_command(
        &root,
        json!({"source": "user"}),
        &["checkout", "missing-ref"],
    ));
    // The raw command reports Git's status as data; the process trace owns the failure.
    assert_eq!(response["ok"], true);
    assert_ne!(response["data"]["exitCode"], 0);

    let git = only(&events, "vcs.git.command.failed");
    assert_eq!(git.level, LogLevel::Warn);
    assert_eq!(git.op.as_deref(), Some("request-1"));
    assert_eq!(git.fields["command"], "checkout");
    assert!(git.fields["exit_code"]
        .as_i64()
        .is_some_and(|code| code != 0));
    let stderr = git.fields["stderr"].as_str().unwrap();
    assert!(stderr.contains("missing-ref"), "{stderr}");
    assert!(!git.fields.contains_key("error"));
    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn background_reads_trace_only_while_detailed_diagnostics_are_enabled() {
    let root = repository("trace-background");
    let request = json!({
        "id": "status-1",
        "command": "git.status",
        "origin": {"source": "background"},
        "payload": {"root": root}
    })
    .to_string();
    let (_, gated) = capture::run(false, || execute_json(&request));
    assert!(gated.is_empty(), "{gated:?}");

    let (response, enabled) = capture::run(true, || execute_json(&request));
    let response: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(response["ok"], true);
    let traced = enabled
        .iter()
        .filter(|event| event.event == "vcs.git.command.traced")
        .collect::<Vec<_>>();
    assert!(!traced.is_empty(), "{enabled:?}");
    for event in &traced {
        assert_eq!(event.level, LogLevel::Debug);
        assert_eq!(event.fields["source"], "background");
        assert_eq!(event.op.as_deref(), Some("status-1"));
    }
    let request = only(&enabled, "app.core.request.traced");
    assert_eq!(request.fields["method"], "git.status");
    fs::remove_dir_all(root).expect("temporary repository should be removable");
}
