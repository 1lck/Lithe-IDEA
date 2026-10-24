//! Persistent sessions: surviving disconnection, replay and expiry.

mod support;

use lithe_remote_client::api::{ProcessEvent, TerminalEvent};
use lithe_remote_client::{SpawnSpec, TerminalSpec};
use lithe_remote_protocol::methods::{self, OutputStream, ProcessExitEvent, ProcessOutputEvent};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};
use support::{wait_until_gone, Daemon, TempDir, STEP_TIMEOUT};

fn argv(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

// A build keeps running while the network is down, its output produced in
// the meantime is replayed, and the exit arrives after the output.
#[test]
fn processes_survive_a_disconnect_and_their_output_is_replayed() {
    let daemon = Daemon::new("replay");
    let gate = TempDir::new("gate");
    let release = gate.join("release");
    let (session, events) = daemon.connect(None);
    assert!(session.hello().session.persistent);
    assert!(!session.hello().session.resumed);
    // The process waits for a file the test creates while disconnected, so
    // its output is produced only when no client is attached.
    let script = format!("while [ ! -e '{release}' ]; do sleep 0.05; done; echo after-release");
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", &script]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let (process_id, pid) = (process.id, process.pid);
    drop(process);
    drop(events);
    drop(session);

    std::fs::write(&release, b"").unwrap();
    // Wait for the process to finish while detached, so the replay must
    // contain both its output and its exit.
    assert!(wait_until_gone(pid), "process {pid} did not finish");

    let (session, events) = daemon.connect(None);
    let hello = session.hello();
    assert!(hello.session.resumed);
    assert!(!hello.session.replay_truncated);
    assert!(hello.session.next_resource_id > process_id);

    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut stdout = Vec::new();
    loop {
        let event = events
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap_or_else(|_| panic!("no replayed exit; output {stdout:?}\n{}", daemon.log()));
        match event.event.as_str() {
            methods::EVENT_PROCESS_OUTPUT => {
                let output: ProcessOutputEvent = event.decode().unwrap();
                assert_eq!(output.process_id, process_id);
                assert_eq!(output.stream, OutputStream::Stdout);
                stdout.extend(methods::decode_bytes(&output.data).unwrap());
            }
            methods::EVENT_PROCESS_EXIT => {
                let exit: ProcessExitEvent = event.decode().unwrap();
                assert_eq!(exit.process_id, process_id);
                assert_eq!(exit.exit_code, Some(0));
                break;
            }
            _ => {}
        }
    }
    assert_eq!(stdout, b"after-release\n");
    session.shutdown(STEP_TIMEOUT);
    assert!(
        daemon.wait_until_stopped(),
        "the daemon kept running after shutdown"
    );
}

// After an app restart the client learns from `server.state` which
// terminals still run and attaches to them.
#[test]
fn terminals_can_be_reattached_after_reconnecting() {
    let daemon = Daemon::new("reattach");
    let (session, _events) = daemon.connect(None);
    let terminal = session
        .open_terminal(TerminalSpec {
            argv: Some(vec!["/bin/sh".into()]),
            cwd: None,
            env: BTreeMap::from([
                ("PS1".into(), "$ ".into()),
                ("ENV".into(), String::new()),
                ("HISTFILE".into(), "/dev/null".into()),
            ]),
            columns: 80,
            rows: 24,
        })
        .unwrap();
    let terminal_id = terminal.id;
    drop(terminal);
    drop(session);

    let (session, _events) = daemon.connect(None);
    let state = session.state().unwrap();
    let running = state
        .terminals
        .iter()
        .find(|running| running.terminal_id == terminal_id)
        .expect("the terminal survived the disconnect");
    let terminal = session.attach_terminal(running.terminal_id, running.pid);
    terminal.write(b"echo still-$((40+2))\n").unwrap();
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut output = Vec::new();
    while !String::from_utf8_lossy(&output).contains("still-42") {
        match terminal.next_event(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(TerminalEvent::Output(bytes))) => output.extend(bytes),
            other => panic!("{other:?}; output {:?}", String::from_utf8_lossy(&output)),
        }
    }
    drop(terminal);
    session.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}

// A session nobody returns to must not keep processes running forever.
#[test]
fn idle_sessions_end_after_their_timeout() {
    let daemon = Daemon::new("idle");
    let (session, _events) = daemon.connect(Some(Duration::from_secs(1)));
    let pid = session
        .spawn(SpawnSpec {
            argv: argv(&["sleep", "60"]),
            ..SpawnSpec::default()
        })
        .unwrap()
        .pid;
    drop(session);
    assert!(
        daemon.wait_until_stopped(),
        "the idle daemon did not stop\n{}",
        daemon.log()
    );
    assert!(wait_until_gone(pid), "process {pid} outlived its session");
}

// Two proxies racing to start the daemon end up in one daemon. A session
// has one client at a time: the later connection replaces the earlier one,
// whose handshake may then fail, which is the documented outcome.
#[test]
fn concurrent_connections_share_one_daemon() {
    let daemon = Daemon::new("race");
    let attempt = || {
        lithe_remote_client::RemoteSession::connect(
            &lithe_remote_client::TransportChain::local(),
            &daemon.command(),
            &support::options(),
        )
    };
    let results = std::thread::scope(|scope| {
        let first = scope.spawn(attempt);
        let second = scope.spawn(attempt);
        [first.join().unwrap(), second.join().unwrap()]
    });
    let survivor = results
        .into_iter()
        .filter_map(Result::ok)
        .map(|(session, _events)| session)
        .find(|session| session.ping().is_ok())
        .unwrap_or_else(|| panic!("no connection survived\n{}", daemon.log()));
    let process = survivor
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "printf shared"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let output = process.wait(STEP_TIMEOUT).unwrap();
    assert_eq!(output.stdout, b"shared");
    drop(process);
    // Exactly one daemon owns the key; the other exited at the lock.
    let run = daemon.state.path().join("run");
    let locks = std::fs::read_dir(run)
        .unwrap()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().ends_with(".lock"))
        .count();
    assert_eq!(locks, 1);
    assert!(daemon.pid().is_some());
    survivor.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}

#[test]
fn subscribed_events_bypass_the_general_channel() {
    let daemon = Daemon::new("general");
    let (session, events) = daemon.connect(None);
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "printf routed"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    // The handle's subscription receives the events, not the general channel.
    match process.next_event(STEP_TIMEOUT).unwrap() {
        Some(ProcessEvent::Output(_, bytes)) => assert_eq!(bytes, b"routed"),
        other => panic!("unexpected {other:?}"),
    }
    assert!(events.try_recv().is_err());
    drop(process);
    session.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}
