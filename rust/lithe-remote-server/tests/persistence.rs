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
// terminals still run, attaches to them, and only then resumes, so output
// produced while it was away reaches the terminal handle instead of the
// general channel.
#[test]
fn terminals_can_be_reattached_after_reconnecting() {
    let daemon = Daemon::new("reattach");
    let gate = TempDir::new("reattach-gate");
    let release = gate.join("release");
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
    // The answer is printed only after the test creates the gate file while
    // no client is connected.
    let command =
        format!("while [ ! -e '{release}' ]; do sleep 0.05; done; echo later-$((40+2))\n");
    terminal.write(command.as_bytes()).unwrap();
    let terminal_id = terminal.id;
    drop(terminal);
    let seen = session.last_event_seq();
    drop(session);
    std::fs::write(&release, b"").unwrap();

    let (session, events) = daemon.connect_deferred();
    let state = session.state().unwrap();
    let running = state
        .terminals
        .iter()
        .find(|running| running.terminal_id == terminal_id)
        .expect("the terminal survived the disconnect");
    let terminal = session.attach_terminal(running.terminal_id, running.pid);
    let resumed = session.resume(Some(seen)).unwrap();
    assert!(!resumed.truncated);
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut output = Vec::new();
    while !String::from_utf8_lossy(&output).contains("later-42") {
        match terminal.next_event(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(TerminalEvent::Output(bytes))) => output.extend(bytes),
            other => panic!("{other:?}; output {:?}", String::from_utf8_lossy(&output)),
        }
    }
    assert!(
        events
            .try_iter()
            .all(|event| event.resource() != Some(("terminal", terminal_id))),
        "replayed terminal output went to the general channel"
    );
    terminal.write(b"echo still-$((40+3))\n").unwrap();
    while !String::from_utf8_lossy(&output).contains("still-43") {
        match terminal.next_event(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(TerminalEvent::Output(bytes))) => output.extend(bytes),
            other => panic!("{other:?}; output {:?}", String::from_utf8_lossy(&output)),
        }
    }
    drop(terminal);
    session.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}

// Regression: events the dying connection's outbox or socket had already
// accepted were lost. The client resumes after the last event it actually
// processed and must then receive every later event exactly once.
#[test]
fn resuming_after_a_lost_connection_delivers_every_event_exactly_once() {
    let daemon = Daemon::new("lossless");
    let lines = 20_000;
    let (session, _events) = daemon.connect(None);
    let process_id = session.allocate_id();
    let subscription = session.subscribe("process", process_id);
    session
        .request_value(
            methods::PROCESS_SPAWN,
            serde_json::json!({
                "processId": process_id,
                "argv": ["awk", format!("BEGIN {{ for (i = 1; i <= {lines}; i++) print i }}")],
            }),
            STEP_TIMEOUT,
        )
        .unwrap();
    // Process only the first event. Every later event, up to the exit, is
    // sent over this connection but treated as lost in transit, as events in
    // a dying connection's outbox or socket buffers are.
    let first = subscription
        .recv_timeout(STEP_TIMEOUT)
        .expect("first output");
    let output: ProcessOutputEvent = first.decode().unwrap();
    let mut stdout = methods::decode_bytes(&output.data).unwrap();
    let last_processed = first.seq.unwrap();
    let deadline = Instant::now() + STEP_TIMEOUT;
    loop {
        let event = subscription
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("the process exit on the first connection");
        if event.event == methods::EVENT_PROCESS_EXIT {
            break;
        }
    }
    drop(subscription);
    drop(session);

    let (session, _events) = daemon.connect_deferred();
    let subscription = session.subscribe("process", process_id);
    assert!(!session.resume(Some(last_processed)).unwrap().truncated);
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut previous = last_processed;
    loop {
        let event = subscription
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("the process exit after resuming");
        let seq = event.seq.unwrap();
        assert!(
            seq > previous,
            "event {seq} repeated or out of order after {previous}"
        );
        previous = seq;
        match event.event.as_str() {
            methods::EVENT_PROCESS_OUTPUT => {
                let output: ProcessOutputEvent = event.decode().unwrap();
                stdout.extend(methods::decode_bytes(&output.data).unwrap());
            }
            methods::EVENT_PROCESS_EXIT => break,
            _ => {}
        }
    }
    let expected: String = (1..=lines).map(|line| format!("{line}\n")).collect();
    assert!(
        stdout == expected.as_bytes(),
        "output has {} of {} bytes",
        stdout.len(),
        expected.len()
    );
    drop(subscription);
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

// Regression: the daemon kept a copy of each connection's socket, so the
// proxy never saw end-of-file and stayed on the host after every disconnect.
#[test]
fn the_proxy_exits_by_itself_when_its_client_disconnects() {
    let daemon = Daemon::new("proxy-exit");
    // Start the daemon through an ordinary session first.
    let (session, _events) = daemon.connect(None);
    drop(session);

    let command = daemon.command();
    let mut proxy = std::process::Command::new(&command[0])
        .args(&command[1..])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    // Closing standard input is what a dropped SSH connection does.
    drop(proxy.stdin.take());
    let deadline = Instant::now() + STEP_TIMEOUT;
    let status = loop {
        if let Some(status) = proxy.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = proxy.kill();
            let _ = proxy.wait();
            panic!("the proxy kept running after its input closed");
        }
        // test-stability: allow(rust-real-sleep) reason: the proxy is a child process whose exit is polled with try_wait under a monotonic deadline; std offers no timed wait.
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "{status}");
    let (session, _events) = daemon.connect(None);
    session.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}

// Regression: a daemon ending its session (here waiting out a process that
// ignores SIGTERM) removed its socket but still held the lock, so a client
// reconnecting in that window got a daemon that exited at once and a
// connection failure.
#[test]
fn reconnecting_while_the_previous_daemon_shuts_down_starts_a_fresh_session() {
    let daemon = Daemon::new("handover");
    let (session, _events) = daemon.connect(None);
    let stubborn = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "trap '' TERM; while :; do sleep 0.1; done"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let stubborn_pid = stubborn.pid;
    drop(stubborn);
    session.shutdown(STEP_TIMEOUT);

    let (session, _events) = daemon.connect(None);
    assert!(!session.hello().session.resumed, "reached the old session");
    assert!(
        wait_until_gone(stubborn_pid),
        "the old session's process survived"
    );
    session.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}

// Regression: a session kept after its leader exited was forgotten only on
// the next spawn or kill. Until then its id could be reused by an unrelated
// process, which a later kill or the final cleanup would have signalled.
#[test]
fn emptied_sessions_are_forgotten_without_further_requests() {
    let daemon = Daemon::new("reaper");
    let (session, _events) = daemon.connect(None);
    let process = session
        .spawn(SpawnSpec {
            argv: argv(&["sh", "-c", "sleep 0.3 >/dev/null 2>&1 & echo $!"]),
            ..SpawnSpec::default()
        })
        .unwrap();
    let output = process.wait(STEP_TIMEOUT).unwrap();
    let member: u32 = String::from_utf8(output.stdout)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let process_id = process.id;
    drop(process);
    assert!(wait_until_gone(member));
    // `server.state` only reads; nothing else would prune the entry.
    let deadline = Instant::now() + STEP_TIMEOUT;
    while session
        .state()
        .unwrap()
        .processes
        .iter()
        .any(|running| running.process_id == process_id)
    {
        assert!(
            Instant::now() < deadline,
            "the emptied session was never forgotten"
        );
        // test-stability: allow(rust-real-sleep) reason: the reaper runs on its own interval inside another process; the poll observes it through server.state under a monotonic deadline.
        std::thread::sleep(Duration::from_millis(50));
    }
    session.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
}
