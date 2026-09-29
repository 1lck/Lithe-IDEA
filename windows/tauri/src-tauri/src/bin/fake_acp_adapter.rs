//! Deterministic ACP agent fixture for the Windows connection-bridge tests.
//!
//! The bridge's lifecycle guarantees need a *live* Agent whose process tree has
//! more than one process, so a test can prove that closing a connection, or
//! destroying the window that owns it, reclaims the whole tree instead of only
//! the wrapper process. Real adapters behave that way: `codex-acp` starts a
//! separate app-server that inherits stdout and can outlive the wrapper.
//!
//! `fake_dap_adapter` is gated behind `test-support`, which no test suite
//! enables, so its tests never run in CI. This fixture must run in the ordinary
//! Windows Rust suite, therefore it is a regular binary. It is never bundled:
//! `tauri.conf.json` packages only the application binary.
//!
//! Usage: `fake-acp-adapter serve <pid-file>` answers the ACP handshake from a
//! wrapper process, starts `fake-acp-adapter grandchild <pid-file>`, records
//! both process ids in `<pid-file>` as `<role> <pid>` lines, and stays alive
//! until its stdin closes. The grandchild inherits stdout to keep the host's
//! output pipe open, exactly like a wrapper that launches a second process, and
//! exits on its own after a bounded guard so a leaked fixture cannot outlive a
//! failed test run.

use serde_json::{json, Value};
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Upper bound for the grandchild, so a fixture leaked by a failing test ends by
/// itself. Tests never wait for it: they assert the host reclaimed the tree.
const GRANDCHILD_GUARD: Duration = Duration::from_secs(120);

fn main() {
    let mut arguments = std::env::args().skip(1);
    let role = arguments.next().unwrap_or_else(|| "serve".to_string());
    let pid_file = arguments.next().map(PathBuf::from);
    match role.as_str() {
        "grandchild" => grandchild(pid_file.as_deref()),
        _ => serve(pid_file.as_deref()),
    }
}

/// Records a process id, then waits to be killed by the host.
fn grandchild(pid_file: Option<&Path>) {
    record(pid_file, "grandchild");
    let guard = Instant::now() + GRANDCHILD_GUARD;
    while Instant::now() < guard {
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Answers the handshake, starts the grandchild, and then serves ACP requests.
fn serve(pid_file: Option<&Path>) {
    record(pid_file, "adapter");
    spawn_grandchild(pid_file);

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in BufReader::new(stdin.lock()).lines() {
        let Ok(line) = line else {
            break;
        };
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        // Notifications carry no id and need no reply.
        let Some(id) = message.get("id").cloned() else {
            continue;
        };
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let reply = json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result_for(method),
        });
        if writeln!(stdout, "{reply}").is_err() || stdout.flush().is_err() {
            break;
        }
    }
}

/// The ACP result the bridge needs: an agent that accepts a gateway API key.
fn result_for(method: &str) -> Value {
    match method {
        "initialize" => json!({
            "protocolVersion": 1,
            "agentCapabilities": {},
            "authMethods": [{ "id": "gateway", "name": "Custom API key" }],
            "agentInfo": { "name": "fake-acp-adapter", "version": "0.0.0" },
        }),
        "session/new" => json!({ "sessionId": "fake-session" }),
        _ => json!({}),
    }
}

fn spawn_grandchild(pid_file: Option<&Path>) {
    let Ok(executable) = std::env::current_exe() else {
        return;
    };
    let mut command = Command::new(executable);
    command.arg("grandchild");
    if let Some(pid_file) = pid_file {
        command.arg(pid_file);
    }
    // Inherit stdout like the real adapters: the host must kill the tree rather
    // than rely on the output pipe closing when the wrapper exits.
    command
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    let _ = command.spawn();
}

fn record(pid_file: Option<&Path>, role: &str) {
    let Some(pid_file) = pid_file else {
        return;
    };
    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(pid_file) else {
        return;
    };
    let _ = writeln!(file, "{role} {}", std::process::id());
    let _ = file.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_request_method_gets_a_parseable_result() {
        let initialize = result_for("initialize");
        assert_eq!(initialize["protocolVersion"], 1);
        assert_eq!(initialize["authMethods"][0]["id"], "gateway");
        assert!(initialize["agentInfo"]["name"].is_string());
        assert!(result_for("authenticate").is_object());
        assert_eq!(result_for("session/new")["sessionId"], "fake-session");
    }
}
