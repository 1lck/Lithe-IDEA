//! Process execution and the login environment.

mod support;

use lithe_remote::client::api::ProcessEvent;
use lithe_remote::client::session::ClientError;
use lithe_remote::client::SpawnSpec;
use lithe_remote::protocol::methods::{
    self, EnvironmentSource, OutputStream, ResolvedEnvironmentSource,
};
use lithe_remote::protocol::ErrorCode;
use serde_json::json;
use std::collections::BTreeMap;
use support::{connect, connect_with_environment, wait_until_gone, TempDir, STEP_TIMEOUT};

fn argv(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

#[test]
fn process_output_precedes_its_exit_event() {
    let (session, _events) = connect();
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "printf out; printf err >&2; exit 3"]),
            env: BTreeMap::from([("LITHE_TEST".into(), "1".into())]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let output = process.wait(STEP_TIMEOUT).unwrap();
    assert_eq!(output.stdout, b"out");
    assert_eq!(output.stderr, b"err");
    assert_eq!(output.exit.unwrap().exit_code, Some(3));
    drop(process);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn standard_input_is_forwarded_and_closed() {
    let (session, _events) = connect();
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["cat"]),
            pipe_stdin: true,
            ..SpawnSpec::default()
        })
        .unwrap();
    process.write_stdin(b"echoed").unwrap();
    process.close_stdin().unwrap();
    let output = process.wait(STEP_TIMEOUT).unwrap();
    assert_eq!(output.stdout, b"echoed");
    assert_eq!(output.exit.unwrap().exit_code, Some(0));
    drop(process);
    session.shutdown(STEP_TIMEOUT);
}

// Build tools start worker processes; killing only the leader would leave
// them running on the remote host.
#[test]
fn kill_reaches_the_whole_process_group() {
    let (session, _events) = connect();
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "sleep 60 & echo $!; wait"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let mut line = Vec::new();
    while !line.contains(&b'\n') {
        match process.next_event(STEP_TIMEOUT).unwrap() {
            Some(ProcessEvent::Output(OutputStream::Stdout, bytes)) => line.extend(bytes),
            other => panic!("unexpected event {other:?}"),
        }
    }
    let worker: u32 = String::from_utf8(line).unwrap().trim().parse().unwrap();
    process.kill(false).unwrap();
    let exit = process.wait(STEP_TIMEOUT).unwrap().exit.unwrap();
    assert_eq!(exit.signal, Some(libc::SIGTERM));
    assert!(
        wait_until_gone(worker),
        "worker {worker} survived the group kill"
    );
    match process.kill(false) {
        Err(ClientError::Remote(error)) => assert_eq!(error.code, ErrorCode::UnknownResource),
        other => panic!("expected UNKNOWN_RESOURCE, got {other:?}"),
    }
    drop(process);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn a_live_resource_id_cannot_be_reused() {
    let (session, _events) = connect();
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sleep", "60"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let duplicate = session.request_value(
        methods::PROCESS_SPAWN,
        json!({ "processId": process.id, "argv": ["true"] }),
        STEP_TIMEOUT,
    );
    match duplicate {
        Err(ClientError::Remote(error)) => assert_eq!(error.code, ErrorCode::ResourceIdInUse),
        other => panic!("expected RESOURCE_ID_IN_USE, got {other:?}"),
    }
    let state = session.state().unwrap();
    assert_eq!(state.processes.len(), 1);
    assert_eq!(state.processes[0].argv, ["sleep", "60"]);
    process.kill(true).unwrap();
    process.wait(STEP_TIMEOUT).unwrap();
    drop(process);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn disconnecting_a_stdio_session_terminates_its_processes() {
    let (session, events) = connect();
    let pid = session
        .spawn(SpawnSpec {
            argv: argv(&["sleep", "60"]),
            ..SpawnSpec::default()
        })
        .unwrap()
        .pid;
    drop(events);
    // Dropping without shutdown is what a lost network connection looks like.
    drop(session);
    assert!(wait_until_gone(pid), "process {pid} outlived the session");
}

/// Starts a session whose leader exits right away while a member keeps
/// running, as a build tool that leaves a daemon behind does. Returns the
/// handle and the surviving member's pid after the leader's exit event.
fn spawn_session_that_outlives_its_leader(
    session: &lithe_remote::client::RemoteSession,
) -> (lithe_remote::client::api::ProcessHandle<'_>, u32) {
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let output = process.wait(STEP_TIMEOUT).unwrap();
    assert_eq!(output.exit.unwrap().exit_code, Some(0));
    let member = String::from_utf8(output.stdout)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    (process, member)
}

#[test]
fn kill_reaches_members_that_outlive_the_leader() {
    let (session, _events) = connect();
    let (process, member) = spawn_session_that_outlives_its_leader(&session);
    let state = session.state().unwrap();
    assert!(state
        .processes
        .iter()
        .any(|running| running.process_id == process.id && running.leader_exited));
    process.kill(true).unwrap();
    assert!(wait_until_gone(member), "member {member} survived the kill");
    drop(process);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn disconnecting_terminates_members_that_outlive_the_leader() {
    let (session, events) = connect();
    let (process, member) = spawn_session_that_outlives_its_leader(&session);
    drop(process);
    drop(events);
    drop(session);
    assert!(
        wait_until_gone(member),
        "member {member} outlived the session"
    );
}

// Tools that version managers add to PATH in profile files must be found by
// builds started from the IDE, not only in an interactive terminal. The
// profile and shell are fixed here so the test does not run the developer's
// own shell configuration.
#[test]
fn login_environment_includes_what_profiles_export() {
    let home = TempDir::new("profile");
    std::fs::write(
        home.path().join(".profile"),
        "echo 'profile banner'\nexport LITHE_PROFILE_MARK=from-profile\n",
    )
    .unwrap();
    let (session, _events) =
        connect_with_environment(&[("HOME", home.str()), ("SHELL", "/bin/sh"), ("ENV", "")]);

    let resolved = session.resolve_environment(false).unwrap();
    assert_ne!(
        resolved.source,
        ResolvedEnvironmentSource::Server,
        "{:?}",
        resolved.diagnostics
    );
    assert_eq!(
        resolved
            .environment
            .get("LITHE_PROFILE_MARK")
            .map(String::as_str),
        Some("from-profile")
    );
    assert!(!resolved.environment.contains_key("SHLVL"));

    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "printf %s \"$LITHE_PROFILE_MARK\""]),
            environment: EnvironmentSource::Login,
            ..SpawnSpec::default()
        })
        .unwrap();
    assert_eq!(process.wait(STEP_TIMEOUT).unwrap().stdout, b"from-profile");
    drop(process);
    session.shutdown(STEP_TIMEOUT);
}
