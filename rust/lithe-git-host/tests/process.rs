//! Native integration fixtures execute only this test binary, never installed tools.
use lithe_git_host::{run, Failure, ProcessTree};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const TREE_DEADLINE: Duration = Duration::from_secs(5);

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
    if mode == "tree-parent" || mode == "tree-child" {
        run_tree_fixture(&mode);
        return;
    }
    #[cfg(unix)]
    if mode == "sigint-survivor" {
        run_sigint_survivor_fixture();
        return;
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

/// A two-level tree like `cmd -> mvn -> java`. Both levels block on the
/// test's stdin pipe, so they also end on their own once the test drops it.
fn run_tree_fixture(mode: &str) {
    let mut descendant = (mode == "tree-parent").then(|| {
        let descendant = Command::new(std::env::current_exe().expect("test executable"))
            .args(["--exact", "process_fixture", "--nocapture"])
            .env("LITHE_GIT_PROCESS_FIXTURE", "tree-child")
            .stdin(Stdio::inherit())
            .stdout(Stdio::null())
            .spawn()
            .expect("spawn descendant");
        println!("descendant-pid {}", descendant.id());
        std::io::stdout().flush().expect("announce descendant");
        descendant
    });
    let _ = std::io::stdin().read_to_end(&mut Vec::new());
    if let Some(descendant) = descendant.as_mut() {
        let _ = descendant.wait();
    }
}

struct TreeFixture {
    tree: ProcessTree,
    descendant: u32,
    root_exit: mpsc::Receiver<()>,
    // Dropped last: closing it lets any survivor exit on its own.
    _input: std::process::ChildStdin,
}

fn spawn_tree_fixture() -> TreeFixture {
    let mut command = Command::new(std::env::current_exe().expect("test executable"));
    command
        .args(["--exact", "process_fixture", "--nocapture"])
        .env("LITHE_GIT_PROCESS_FIXTURE", "tree-parent")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    ProcessTree::prepare(&mut command);
    let mut root = command.spawn().expect("spawn tree root");
    let input = root.stdin.take().expect("root input");
    let output = root.stdout.take().expect("root output");
    let tree = ProcessTree::adopt(&mut root).expect("adopt tree");
    let descendant = read_descendant_pid(output);
    TreeFixture {
        tree,
        descendant,
        root_exit: reap_in_background(root),
        _input: input,
    }
}

fn read_descendant_pid(output: std::process::ChildStdout) -> u32 {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            let Ok(line) = line else { return };
            if let Some(pid) = line.strip_prefix("descendant-pid ") {
                let _ = sender.send(pid.trim().parse::<u32>().expect("descendant pid"));
                return;
            }
        }
    });
    receiver
        .recv_timeout(TREE_DEADLINE)
        .expect("tree fixture did not start its descendant")
}

/// A Unix group still counts an unreaped root, so the owner reaps it while
/// the tree is being ended, as the Run host's exit waiter does.
fn reap_in_background(mut root: Child) -> mpsc::Receiver<()> {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = root.wait();
        let _ = sender.send(());
    });
    receiver
}

#[cfg(unix)]
static SURVIVED_SIGINT: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn record_sigint(_: libc::c_int) {
    SURVIVED_SIGINT.store(true, Ordering::SeqCst);
}

/// Survives SIGINT by handling it, so a parent can observe that a graceful
/// stop delivered the signal before its grace period forces the kill.
#[cfg(unix)]
fn run_sigint_survivor_fixture() {
    unsafe {
        libc::signal(libc::SIGINT, record_sigint as libc::sighandler_t);
    }
    println!("fixture-ready");
    std::io::stdout().flush().expect("announce fixture");
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if SURVIVED_SIGINT.load(Ordering::SeqCst) {
            println!("sigint-received");
            std::io::stdout().flush().expect("announce signal");
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = std::io::stdin().read_to_end(&mut Vec::new());
}

#[cfg(unix)]
struct SurvivorFixture {
    tree: ProcessTree,
    root: Child,
    // Dropped last: closing it lets the fixture exit on its own.
    _input: std::process::ChildStdin,
    lines: mpsc::Receiver<String>,
}

#[cfg(unix)]
fn spawn_sigint_survivor_fixture() -> SurvivorFixture {
    let mut command = Command::new(std::env::current_exe().expect("test executable"));
    command
        .args(["--exact", "process_fixture", "--nocapture"])
        .env("LITHE_GIT_PROCESS_FIXTURE", "sigint-survivor")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    ProcessTree::prepare(&mut command);
    let mut root = command.spawn().expect("spawn sigint fixture");
    let input = root.stdin.take().expect("root input");
    let output = root.stdout.take().expect("root output");
    let tree = ProcessTree::adopt(&mut root).expect("adopt sigint fixture");
    let (sender, lines) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            let Ok(line) = line else { return };
            if line.starts_with("fixture-") || line == "sigint-received" {
                if sender.send(line).is_err() {
                    return;
                }
            }
        }
    });
    SurvivorFixture {
        tree,
        root,
        _input: input,
        lines,
    }
}

#[cfg(unix)]
#[test]
fn graceful_stop_forces_a_tree_that_survives_sigint() {
    let mut fixture = spawn_sigint_survivor_fixture();
    fixture
        .lines
        .recv_timeout(TREE_DEADLINE)
        .expect("fixture did not start");
    let forced = fixture
        .tree
        .terminate_gracefully(Duration::from_millis(300))
        .expect("graceful stop ends the tree");
    assert!(forced, "a tree that survives SIGINT must be killed");
    fixture
        .root
        .wait()
        .expect("the forced root is reaped by its owner");
}

#[cfg(unix)]
#[test]
fn graceful_stop_lets_a_tree_that_honours_sigint_exit_on_its_own() {
    let fixture = spawn_tree_fixture();
    assert_ne!(fixture.descendant, 0);
    let forced = fixture
        .tree
        .terminate_gracefully(TREE_DEADLINE)
        .expect("graceful stop ends the tree");
    assert!(!forced, "a tree that exits on SIGINT must not be killed");
    fixture
        .root_exit
        .recv_timeout(TREE_DEADLINE)
        .expect("root ended");
}

#[cfg(unix)]
#[test]
fn a_second_graceful_stop_kills_right_away() {
    let mut fixture = spawn_sigint_survivor_fixture();
    fixture
        .lines
        .recv_timeout(TREE_DEADLINE)
        .expect("fixture did not start");
    std::thread::scope(|scope| {
        let tree = &fixture.tree;
        let first = scope.spawn(move || {
            tree.terminate_gracefully(Duration::from_secs(30))
        });
        // The fixture only reports the signal after the first request has
        // sent it, so the second request is provably not the graceful one.
        let line = fixture
            .lines
            .recv_timeout(TREE_DEADLINE)
            .expect("no signal delivery report");
        assert_eq!(line, "sigint-received");
        let began = Instant::now();
        let forced = tree
            .terminate_gracefully(TREE_DEADLINE)
            .expect("second stop ends the tree");
        assert!(forced, "the second stop must kill right away");
        assert!(
            began.elapsed() < TREE_DEADLINE,
            "the second stop must not wait out the first grace period"
        );
        let forced = first
            .join()
            .expect("first stop thread")
            .expect("first stop ends the tree");
        assert!(forced, "the first stop observed the forced phase");
        fixture
            .root
            .wait()
            .expect("the forced root is reaped by its owner");
    });
}

#[cfg(windows)]
#[test]
fn graceful_stop_on_windows_ends_the_tree_by_force() {
    let fixture = spawn_tree_fixture();
    assert_ne!(fixture.descendant, 0);
    let forced = fixture
        .tree
        .terminate_gracefully(TREE_DEADLINE)
        .expect("graceful stop ends the tree");
    assert!(forced, "Windows ends the tree by force right away");
    fixture
        .root_exit
        .recv_timeout(TREE_DEADLINE)
        .expect("root ended");
    // A second request after the tree is empty is harmless.
    fixture
        .tree
        .terminate_gracefully(TREE_DEADLINE)
        .expect("an empty tree terminates");
}

#[test]
fn process_tree_terminate_ends_the_root_and_its_descendants() {
    let fixture = spawn_tree_fixture();
    assert_ne!(fixture.descendant, 0);

    fixture
        .tree
        .terminate(TREE_DEADLINE)
        .expect("every process of the tree ends");
    fixture
        .root_exit
        .recv_timeout(TREE_DEADLINE)
        .expect("root ended");
    // A second request after the tree is empty is harmless.
    fixture
        .tree
        .terminate(TREE_DEADLINE)
        .expect("an empty tree terminates");
}

#[cfg(windows)]
#[test]
fn dropping_a_process_tree_ends_it_like_a_crashed_host() {
    // The kernel closes the job handle when the host dies; dropping the tree
    // closes it the same way, without an explicit terminate.
    let fixture = spawn_tree_fixture();
    let TreeFixture {
        tree,
        root_exit,
        _input,
        ..
    } = fixture;
    drop(tree);
    root_exit
        .recv_timeout(TREE_DEADLINE)
        .expect("closing the job ends the root");
}
