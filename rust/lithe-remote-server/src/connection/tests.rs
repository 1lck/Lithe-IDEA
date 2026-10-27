//! Deterministic scheduling regressions for creation followed by cancellation.

use super::*;
use std::sync::mpsc;
use std::time::Instant;

const STEP: Duration = Duration::from_secs(5);

#[test]
fn cancellation_waits_for_process_terminal_and_watch_publication() {
    let root = WatchRoot::new();
    for (start, stop, params, close) in [
        (
            methods::PROCESS_SPAWN,
            methods::PROCESS_KILL,
            json!({"processId": 1, "argv": ["/bin/cat"], "pipeStdin": true}),
            json!({"processId": 1, "force": true}),
        ),
        (
            methods::TERMINAL_OPEN,
            methods::TERMINAL_CLOSE,
            json!({"terminalId": 1, "argv": ["/bin/cat"], "columns": 80, "rows": 24}),
            json!({"terminalId": 1}),
        ),
        (
            methods::WATCH_START,
            methods::WATCH_STOP,
            json!({"watchId": 1, "root": root.0}),
            json!({"watchId": 1}),
        ),
    ] {
        let session = Session::new(false).unwrap();
        let cleanup = Cleanup(Arc::clone(&session));
        let creation = ResourceOrder::prepare(&session, start, &params).unwrap();
        let cancellation = ResourceOrder::prepare(&session, stop, &close).unwrap();
        // The close worker runs first, while the creation worker is not yet
        // scheduled. It must not reach the still-empty resource table.
        assert!(cancellation.wait(Duration::ZERO).is_err());
        assert!(ResourceOrder::prepare(&session, start, &params).is_err());
        let (done, completed) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = cancellation.wait(STEP);
            let _ = done.send(result);
        });
        let result = handle(
            &Context {
                session: Arc::clone(&session),
                connection: 1,
                closed: Arc::default(),
            },
            start,
            params,
        );
        creation.finish(&Context {
            session: Arc::clone(&session),
            connection: 1,
            closed: Arc::default(),
        });
        drop(creation);
        let outcome = completed
            .recv_timeout(STEP)
            .expect("close worker must finish");
        worker.join().unwrap();
        result.unwrap();
        outcome.unwrap();
        // Monitor threads report leader exit asynchronously. Observe the
        // public state with a local deadline, never synchronize with sleeps.
        let deadline = Instant::now() + STEP;
        loop {
            let state = session.state();
            if state.processes.is_empty() && state.terminals.is_empty() && state.watches.is_empty()
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "cancelled resource remained active: {state:?}"
            );
            std::thread::yield_now();
        }
        drop(cleanup);
    }
}

#[test]
fn failed_or_unscheduled_start_releases_only_its_own_waiters() {
    let session = Session::new(false).unwrap();
    let _cleanup = Cleanup(Arc::clone(&session));
    let params = json!({"processId": 7, "force": true});
    let creation = ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
    let cancellation = ResourceOrder::prepare(&session, methods::PROCESS_KILL, &params).unwrap();
    assert!(cancellation.wait(Duration::ZERO).is_err());
    // A different id and resource family remain independently schedulable.
    ResourceOrder::prepare(&session, methods::PROCESS_KILL, &json!({"processId": 8}))
        .unwrap()
        .wait(Duration::ZERO)
        .unwrap();
    ResourceOrder::prepare(&session, methods::TERMINAL_CLOSE, &json!({"terminalId": 7}))
        .unwrap()
        .wait(Duration::ZERO)
        .unwrap();
    drop(creation);
    cancellation.wait(Duration::ZERO).unwrap();
    ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
}

#[test]
fn cancellation_remains_owned_when_the_close_worker_is_rejected() {
    let session = Session::new(false).unwrap();
    let _cleanup = Cleanup(Arc::clone(&session));
    let params = json!({"processId": 11, "argv": ["/bin/cat"], "pipeStdin": true});
    let creation = ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
    let context = Context {
        session: Arc::clone(&session),
        connection: 1,
        closed: Arc::default(),
    };
    let mut slots = 0;
    while session.workers.try_acquire() {
        slots += 1;
    }
    let (send, receive) = mpsc::sync_channel(1);
    dispatch_to_worker(
        &context,
        99,
        methods::PROCESS_KILL.into(),
        json!({"processId": 11, "force": true}),
        &Outbox(send),
    );
    let crate::link::Outgoing::Message(message) = receive.recv_timeout(STEP).unwrap() else {
        panic!("expected reply");
    };
    assert_eq!(
        serde_json::to_value(message).unwrap()["error"]["code"],
        "BUSY"
    );
    for _ in 0..slots {
        session.workers.release();
    }
    handle(&context, methods::PROCESS_SPAWN, params).unwrap();
    creation.finish(&context);
    drop(creation);
    let deadline = Instant::now() + STEP;
    while !session.state().processes.is_empty() {
        assert!(
            Instant::now() < deadline,
            "rejected close leaked its pending child"
        );
        std::thread::yield_now();
    }
}

#[test]
fn malformed_close_does_not_cancel_a_pending_creation() {
    let session = Session::new(false).unwrap();
    let _cleanup = Cleanup(Arc::clone(&session));
    let params = json!({"processId": 3});
    let creation = ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
    assert!(ResourceOrder::prepare(
        &session,
        methods::PROCESS_KILL,
        &json!({"processId": 3, "force": "invalid"})
    )
    .is_err());
    let ResourceOrder::Start { guard, .. } = &creation else {
        panic!("expected start");
    };
    assert!(guard.take_cancellation().is_none());
}

#[test]
fn forced_cancellation_and_a_new_reservation_survive_old_guard_release() {
    let session = Session::new(false).unwrap();
    let _cleanup = Cleanup(Arc::clone(&session));
    let params = json!({"processId": 17});
    let creation = ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
    let forced = ResourceOrder::prepare(
        &session,
        methods::PROCESS_KILL,
        &json!({"processId": 17, "force": true}),
    )
    .unwrap();
    let ordinary = ResourceOrder::prepare(&session, methods::PROCESS_KILL, &params).unwrap();
    let ResourceOrder::Start { guard, .. } = &creation else {
        panic!("expected start");
    };
    assert_eq!(
        guard.take_cancellation(),
        Some(json!({"processId": 17, "force": true}))
    );
    // Ownership transfers before the old guard drops. Its completion must
    // not remove a newer reservation for the same key.
    let replacement = ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
    drop(creation);
    forced.wait(Duration::ZERO).unwrap();
    ordinary.wait(Duration::ZERO).unwrap();
    assert!(ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).is_err());
    drop(replacement);
    ResourceOrder::prepare(&session, methods::PROCESS_SPAWN, &params).unwrap();
}

#[test]
fn disconnect_reclaims_late_publication_only_for_nonpersistent_sessions() {
    let root = WatchRoot::new();
    for persistent in [false, true] {
        let session = Session::new(persistent).unwrap();
        let _cleanup = Cleanup(Arc::clone(&session));
        let params = json!({"watchId": 21, "root": root.0});
        let creation = ResourceOrder::prepare(&session, methods::WATCH_START, &params).unwrap();
        let context = Context {
            session: Arc::clone(&session),
            connection: 1,
            closed: Arc::new(AtomicBool::new(true)),
        };
        // The reader has disconnected before the creation worker publishes.
        // Persistent sessions retain resources for a later reconnection.
        handle(&context, methods::WATCH_START, params).unwrap();
        creation.finish(&context);
        drop(creation);
        assert_eq!(session.state().watches.len(), usize::from(persistent));
    }
}

#[test]
fn shutdown_reclaims_late_publication_in_persistent_sessions() {
    let root = WatchRoot::new();
    for explicit_shutdown in [false, true] {
        let session = Session::new(true).unwrap();
        let _cleanup = Cleanup(Arc::clone(&session));
        let params = json!({"watchId": 23, "root": root.0});
        let creation = ResourceOrder::prepare(&session, methods::WATCH_START, &params).unwrap();
        // Explicit shutdown and idle expiry may both drain an empty table
        // before a previously scheduled creation has published its resource.
        if explicit_shutdown {
            session.begin_shutdown();
        } else {
            session.terminate_all();
        }
        let context = Context {
            session: Arc::clone(&session),
            connection: 1,
            closed: Arc::default(),
        };
        handle(&context, methods::WATCH_START, params).unwrap();
        creation.finish(&context);
        drop(creation);
        assert!(session.state().watches.is_empty());
    }
}

/// Watch an owned empty directory, never the user's shared temporary tree.
struct WatchRoot(String);

impl WatchRoot {
    fn new() -> Self {
        let result: methods::RealPathResult = serde_json::from_value(
            fs::handle(
                methods::FS_TEMP_DIRECTORY,
                json!({"prefix": "lithe-remote-lifecycle"}),
            )
            .unwrap(),
        )
        .unwrap();
        Self(result.path)
    }
}

impl Drop for WatchRoot {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_dir(&self.0) {
            eprintln!("failed to remove test watch root: {error}");
        }
    }
}

struct Cleanup(Arc<Session>);
impl Drop for Cleanup {
    fn drop(&mut self) {
        self.0.terminate_all();
    }
}
