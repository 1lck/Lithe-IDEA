//! Native integration fixtures execute only this test binary, never installed tools.
use lithe_git_host::{run, Failure};
use std::io::Write;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[test]
fn process_fixture() {
    let Ok(mode) = std::env::var("LITHE_GIT_PROCESS_FIXTURE") else {
        return;
    };
    if mode == "failure" {
        println!("fixture output");
        eprintln!("fixture error");
        std::process::exit(23);
    }
    // Output is the synchronization signal. The helper also has its own hard
    // deadline, so a broken parent cancellation path cannot leave it running.
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if std::io::stdout().write_all(b"fixture-ready\n").is_err() {
            break;
        }
    }
}

#[test]
fn incremental_output_can_cancel_before_the_child_exits() {
    let began = Instant::now();
    let started = AtomicBool::new(false);
    let received = AtomicBool::new(false);
    let mut command = Command::new(std::env::current_exe().expect("test executable"));
    command
        .args(["--exact", "process_fixture", "--nocapture"])
        .env("LITHE_GIT_PROCESS_FIXTURE", "cancel");
    let outcome = run(
        &mut command,
        None,
        || received.load(Ordering::Relaxed) || began.elapsed() > Duration::from_secs(2),
        || started.store(true, Ordering::Relaxed),
        |_, bytes| {
            assert!(started.load(Ordering::Relaxed));
            if bytes
                .windows(b"fixture-ready".len())
                .any(|window| window == b"fixture-ready")
            {
                received.store(true, Ordering::Relaxed);
            }
        },
    );
    assert!(
        received.load(Ordering::Relaxed),
        "deadline elapsed before fixture output"
    );
    assert!(matches!(outcome.failure, Some(Failure::Cancelled)));
    assert!(
        outcome.status.is_some(),
        "owned child must be reaped before return"
    );
}

#[test]
fn nonzero_exit_retains_both_streams() {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut command = Command::new(std::env::current_exe().expect("test executable"));
    command
        .args(["--exact", "process_fixture", "--nocapture"])
        .env("LITHE_GIT_PROCESS_FIXTURE", "failure");
    let outcome = run(
        &mut command,
        None,
        || Instant::now() > deadline,
        || {},
        |_, _| {},
    );
    assert!(outcome.failure.is_none());
    assert_eq!(outcome.status.and_then(|status| status.code()), Some(23));
    assert!(String::from_utf8_lossy(&outcome.stdout).contains("fixture output"));
    assert!(String::from_utf8_lossy(&outcome.stderr).contains("fixture error"));
}
