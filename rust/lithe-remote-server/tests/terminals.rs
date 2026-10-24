//! Pseudo-terminal sessions.

mod support;

use lithe_remote_client::api::{TerminalEvent, TerminalHandle};
use lithe_remote_client::TerminalSpec;
use std::collections::BTreeMap;
use std::time::Instant;
use support::{connect, wait_until_gone, STEP_TIMEOUT};

/// A plain `sh` with a fixed prompt, so the test does not depend on the
/// developer's login shell and its configuration. `HISTFILE` keeps an
/// interactive bash (`/bin/sh` on macOS) away from the user's real history.
fn plain_shell() -> TerminalSpec {
    TerminalSpec {
        argv: Some(vec!["/bin/sh".into()]),
        cwd: None,
        env: BTreeMap::from([
            ("PS1".into(), "$ ".into()),
            ("ENV".into(), String::new()),
            ("HISTFILE".into(), "/dev/null".into()),
        ]),
        columns: 100,
        rows: 40,
    }
}

/// Reads output until it contains `needle`.
fn read_until(terminal: &TerminalHandle<'_>, needle: &str) -> String {
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut output = Vec::new();
    while !String::from_utf8_lossy(&output).contains(needle) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match terminal.next_event(remaining) {
            Ok(Some(TerminalEvent::Output(bytes))) => output.extend(bytes),
            other => panic!(
                "waiting for {needle:?}: {other:?}; output so far: {:?}",
                String::from_utf8_lossy(&output)
            ),
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn read_until_exit(
    terminal: &TerminalHandle<'_>,
) -> lithe_remote_protocol::methods::TerminalExitEvent {
    let deadline = Instant::now() + STEP_TIMEOUT;
    loop {
        match terminal.next_event(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(TerminalEvent::Output(_))) => {}
            Ok(Some(TerminalEvent::Exit(exit))) => return exit,
            other => panic!("terminal did not exit: {other:?}"),
        }
    }
}

// The command's own output, not the echoed input line, proves execution:
// the input contains `$((6*7))` while only the shell can print `42`.
#[test]
fn commands_run_on_a_controlling_terminal() {
    let (session, _events) = connect();
    let terminal = session.open_terminal(plain_shell()).unwrap();
    terminal.write(b"echo result-$((6*7)); tty\n").unwrap();
    let output = read_until(&terminal, "result-42");
    let output = output + &read_until(&terminal, "/dev/");
    assert!(!output.contains("not a tty"), "{output}");

    terminal.write(b"exit 7\n").unwrap();
    assert_eq!(read_until_exit(&terminal).exit_code, Some(7));
    drop(terminal);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn resizing_changes_the_size_programs_see() {
    let (session, _events) = connect();
    let terminal = session.open_terminal(plain_shell()).unwrap();
    terminal.write(b"stty size\n").unwrap();
    read_until(&terminal, "40 100");
    terminal.resize(132, 50).unwrap();
    terminal.write(b"stty size\n").unwrap();
    read_until(&terminal, "50 132");
    terminal.close().unwrap();
    read_until_exit(&terminal);
    drop(terminal);
    session.shutdown(STEP_TIMEOUT);
}

// Closing a terminal window hangs up the shell and its jobs.
#[test]
fn closing_hangs_up_the_shell_and_its_jobs() {
    let (session, _events) = connect();
    let terminal = session.open_terminal(plain_shell()).unwrap();
    // The echoed input reads `job: $! :end`; only the shell's output has a
    // number there. The spaces around `$!` keep interactive bash from
    // treating `!` as a history expansion.
    terminal.write(b"sleep 60 & echo job: $! :end\n").unwrap();
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut output = String::new();
    let job = loop {
        let found = output.split("job:").skip(1).find_map(|rest| {
            let (pid, _) = rest.split_once(":end")?;
            pid.trim().parse::<u32>().ok()
        });
        if let Some(job) = found {
            break job;
        }
        match terminal.next_event(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(TerminalEvent::Output(bytes))) => {
                output.push_str(&String::from_utf8_lossy(&bytes))
            }
            other => panic!("no job pid: {other:?} in {output:?}"),
        }
    };
    terminal.close().unwrap();
    read_until_exit(&terminal);
    assert!(wait_until_gone(terminal.pid));
    assert!(
        wait_until_gone(job),
        "background job {job} survived the hangup"
    );
    drop(terminal);
    session.shutdown(STEP_TIMEOUT);
}
