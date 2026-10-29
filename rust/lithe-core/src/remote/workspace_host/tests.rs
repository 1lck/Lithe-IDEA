//! Socket-level regressions for product resource ownership and event ordering.

#![cfg(unix)]

use super::*;
use lithe_remote::client::ConnectOptions;
use lithe_remote::protocol::frame::{read_frame, write_frame};
use lithe_remote::protocol::{Message, PREAMBLE};
use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{mpsc, Arc, Mutex};

const STEP: Duration = Duration::from_secs(3);

/// A real framed session with a deterministic peer. Socket deadlines and an
/// explicit completion signal bound failed assertions and thread cleanup.
struct Peer {
    session: RemoteSession,
    socket: UnixStream,
    completed: mpsc::Receiver<Vec<String>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Peer {
    fn new(exit: bool) -> Self {
        Self::with_watch(exit, false)
    }

    fn with_watch(exit: bool, watch: bool) -> Self {
        let (client, mut server) = UnixStream::pair().unwrap();
        server.set_read_timeout(Some(STEP)).unwrap();
        server.set_write_timeout(Some(STEP)).unwrap();
        let socket = client.try_clone().unwrap();
        let (done, completed) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            let mut seen = Vec::new();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                server.write_all(PREAMBLE).unwrap();
                while let Ok(Some(frame)) = read_frame(&mut server) {
                    let Message::Request { id, method, params } =
                        serde_json::from_slice(&frame).unwrap()
                    else {
                        continue;
                    };
                    seen.push(method.clone());
                    let result = match method.as_str() {
                        methods::SERVER_HELLO => json!({
                            "protocolVersion": 1, "serverVersion": "test",
                            "host": {"os": "linux", "arch": "x86_64", "hostName": "test-host",
                                "userName": "dev", "homeDirectory": "/home/dev", "defaultShell": "/bin/sh",
                                "pathSeparator": "/", "process": {"orphanProtection": "parentDeathSignal"},
                                "watch": {"backend": "inotify", "directoryLimit": 128}, "features": []},
                            "session": {"persistent": false, "resumed": false, "nextResourceId": 7, "lastEventSeq": 0}
                        }),
                        methods::SERVER_RESUME => json!({"truncated": false}),
                        methods::PROCESS_SPAWN => {
                            // A fast child writes and exits before spawn's reply.
                            // The resource subscription must already exist.
                            let process = params["processId"].as_u64().unwrap();
                            assert_eq!(process, 7);
                            send(
                                &mut server,
                                Message::Event {
                                    event: methods::EVENT_PROCESS_OUTPUT.into(),
                                    params: json!({"processId": process, "stream": "stdout", "data": methods::encode_bytes(b"early\0output")}),
                                    seq: None,
                                },
                            );
                            if exit {
                                send(
                                    &mut server,
                                    Message::Event {
                                        event: methods::EVENT_PROCESS_EXIT.into(),
                                        params: json!({"processId": process, "exitCode": 19, "signal": null}),
                                        seq: None,
                                    },
                                );
                            }
                            json!({"pid": 101})
                        }
                        methods::WATCH_START if watch => {
                            assert_eq!(params["watchId"], 7);
                            send(
                                &mut server,
                                Message::Event {
                                    event: methods::EVENT_WATCH_CHANGED.into(),
                                    params: json!({"watchId": 7, "changes": [{"path": "/workspace/a", "kind": "modified"}], "overflow": true}),
                                    seq: None,
                                },
                            );
                            if exit {
                                send(
                                    &mut server,
                                    Message::Event {
                                        event: methods::EVENT_WATCH_ERROR.into(),
                                        params: json!({"watchId": 7, "code": "ROOT_REMOVED", "message": "root moved"}),
                                        seq: None,
                                    },
                                );
                            }
                            json!({"watchedDirectories": 1})
                        }
                        methods::PROCESS_KILL | methods::WATCH_STOP => {
                            assert_eq!(
                                params,
                                if watch {
                                    json!({"watchId": 7})
                                } else {
                                    json!({"processId": 7, "force": true})
                                }
                            );
                            send(&mut server, Message::success(id, Value::Null));
                            break;
                        }
                        _ => panic!("unexpected method {method}"),
                    };
                    send(&mut server, Message::success(id, result));
                }
            }));
            // Signal before propagating a peer assertion so teardown can join.
            let _ = done.send(seen);
            if let Err(error) = result {
                std::panic::resume_unwind(error);
            }
        });
        let (session, events) = RemoteSession::from_streams(
            client.try_clone().unwrap(),
            client,
            &ConnectOptions {
                handshake_timeout: STEP,
                ..ConnectOptions::default()
            },
        )
        .unwrap();
        drop(events);
        Self {
            session,
            socket,
            completed,
            thread: Some(thread),
        }
    }

    fn finish(&mut self) -> Vec<String> {
        let seen = self
            .completed
            .recv_timeout(STEP)
            .expect("peer must finish within its socket deadline");
        self.thread.take().unwrap().join().unwrap();
        seen
    }
}

#[test]
fn watch_changes_before_start_reply_are_delivered_and_removed_root_stops_subscription() {
    let mut peer = Peer::with_watch(true, true);
    let _scope = cancellation::Scope::begin(Some("remote-watch-root".into()), Some(3_000));
    let observed = Arc::new(Mutex::new(Vec::<Value>::new()));
    let records = Arc::clone(&observed);
    let sink = Arc::new(move |raw: &str| {
        records
            .lock()
            .unwrap()
            .push(serde_json::from_str(raw).unwrap());
    });
    let result = execution_events::with_sink(sink, || {
        run_on_session(
            &peer.session,
            Request {
                session_id: "socket-test".into(),
                method: String::new(),
                timeout_milliseconds: None,
                params: json!({"root": "/workspace"}),
            },
            "watch",
            methods::WATCH_START,
        )
    })
    .unwrap();
    assert_eq!(result["code"], "ROOT_REMOVED");
    let records = observed.lock().unwrap();
    assert_eq!(
        records
            .iter()
            .map(|value| value["event"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["watch.started", "watch.changed", "watch.error"]
    );
    assert_eq!(records[1]["params"]["overflow"], true);
    assert_eq!(
        peer.finish().last().map(String::as_str),
        Some(methods::WATCH_STOP)
    );
}

#[test]
fn cancellation_of_a_watch_stops_its_host_resource_before_returning() {
    let mut peer = Peer::with_watch(false, true);
    let _scope = cancellation::Scope::begin(Some("remote-watch-cancel".into()), Some(3_000));
    let sink = Arc::new(|raw: &str| {
        let event: Value = serde_json::from_str(raw).unwrap();
        if event["event"] == "watch.started" {
            assert!(cancellation::cancel("remote-watch-cancel"));
        }
    });
    let result = execution_events::with_sink(sink, || {
        run_on_session(
            &peer.session,
            Request {
                session_id: "socket-test".into(),
                method: String::new(),
                timeout_milliseconds: None,
                params: json!({"root": "/workspace"}),
            },
            "watch",
            methods::WATCH_START,
        )
    });
    assert!(matches!(result.unwrap_err().code, ErrorCode::Cancelled));
    assert_eq!(
        peer.finish().last().map(String::as_str),
        Some(methods::WATCH_STOP)
    );
}

impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.socket.shutdown(Shutdown::Both);
        if self.thread.is_some() && self.completed.recv_timeout(STEP + STEP).is_ok() {
            let _ = self.thread.take().unwrap().join();
        }
    }
}

fn send(socket: &mut UnixStream, message: Message) {
    write_frame(socket, &serde_json::to_vec(&message).unwrap()).unwrap();
    socket.flush().unwrap();
}

fn spawn_request() -> Request {
    Request {
        session_id: "socket-test".into(),
        method: String::new(),
        timeout_milliseconds: None,
        params: json!({"argv": ["test-tool"], "cwd": "/workspace", "processId": 999}),
    }
}

#[test]
fn early_binary_output_and_exit_are_ordered_after_started_and_tree_is_cleaned() {
    let mut peer = Peer::new(true);
    let observed = Arc::new(Mutex::new(Vec::<Value>::new()));
    let records = Arc::clone(&observed);
    let sink = Arc::new(move |raw: &str| {
        records
            .lock()
            .unwrap()
            .push(serde_json::from_str(raw).unwrap())
    });
    let _scope = cancellation::Scope::begin(Some("remote-early-output".into()), Some(3_000));
    let result = execution_events::with_sink(sink, || {
        run_on_session(
            &peer.session,
            spawn_request(),
            "process",
            methods::PROCESS_SPAWN,
        )
    })
    .unwrap();
    assert_eq!(result["exitCode"], 19);
    let records = observed.lock().unwrap();
    assert_eq!(
        records
            .iter()
            .map(|value| value["event"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["process.started", "process.output", "process.exit"]
    );
    assert_eq!(records[0]["params"]["processId"], 7);
    assert_eq!(
        methods::decode_bytes(records[1]["params"]["data"].as_str().unwrap()).unwrap(),
        b"early\0output"
    );
    assert_eq!(
        peer.finish().last().map(String::as_str),
        Some(methods::PROCESS_KILL)
    );
}

#[test]
fn cancellation_after_started_kills_the_owned_tree_before_returning() {
    let mut peer = Peer::new(false);
    let _scope = cancellation::Scope::begin(Some("remote-cancel-resource".into()), Some(3_000));
    let sink = Arc::new(|raw: &str| {
        let event: Value = serde_json::from_str(raw).unwrap();
        if event["event"] == "process.started" {
            assert!(cancellation::cancel("remote-cancel-resource"));
        }
    });
    let result = execution_events::with_sink(sink, || {
        run_on_session(
            &peer.session,
            spawn_request(),
            "process",
            methods::PROCESS_SPAWN,
        )
    });
    assert!(matches!(result.unwrap_err().code, ErrorCode::Cancelled));
    assert_eq!(
        peer.finish().last().map(String::as_str),
        Some(methods::PROCESS_KILL)
    );
}
