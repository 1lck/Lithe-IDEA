//! End-to-end behavior of the server binary over the local transport.

mod support;

use lithe_remote_client::bootstrap::Bootstrapper;
use lithe_remote_client::session::ClientError;
use lithe_remote_client::{InstallLocation, RemoteSession, ServerArtifact, TransportChain};
use lithe_remote_protocol::frame::{read_frame, skip_preamble, write_frame};
use lithe_remote_protocol::methods::{
    self, decode_bytes, encode_bytes, FileKind, FileMetadata, OperatingSystem, OrphanProtection,
    ReadDirResult, ReadFileResult, SpawnResult, VolumeInfo,
};
use lithe_remote_protocol::{ErrorCode, Message};
use serde_json::{json, Value};
use std::io::BufReader;
use std::process::{Command, Stdio};
use support::{
    connect, connect_command, wait_for_exit, wait_until_gone, TempDir, SERVER, STEP_TIMEOUT,
};

fn call(session: &RemoteSession, method: &str, params: Value) -> Result<Value, ClientError> {
    session.request_value(method, params, STEP_TIMEOUT)
}

fn error_code(result: Result<Value, ClientError>) -> ErrorCode {
    match result {
        Err(ClientError::Remote(error)) => error.code,
        other => panic!("expected a remote error, got {other:?}"),
    }
}

#[test]
fn handshake_reports_the_host_as_capabilities() {
    let (session, _events) = connect();
    let host = &session.hello().host;
    let expected_os = if cfg!(target_os = "macos") {
        OperatingSystem::Macos
    } else {
        OperatingSystem::Linux
    };
    assert_eq!(host.os, expected_os);
    assert_eq!(host.arch, std::env::consts::ARCH);
    assert_eq!(host.path_separator, "/");
    assert_eq!(
        host.process.orphan_protection,
        if cfg!(target_os = "linux") {
            OrphanProtection::ParentDeathSignal
        } else {
            OrphanProtection::ServerShutdown
        }
    );
    assert!(host
        .home_directory
        .as_deref()
        .is_some_and(|home| home.starts_with('/')));
    assert!(!host.features.is_empty());
    session.shutdown(STEP_TIMEOUT);
}

// The handshake gate and protocol-version check are observed on the raw
// stream, because the client library always says hello first.
#[test]
fn requests_before_hello_and_foreign_protocol_versions_are_rejected() {
    let mut child = Command::new(SERVER)
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    skip_preamble(&mut output, 0).unwrap();
    let mut exchange = |message: Message| -> Message {
        write_frame(&mut input, &serde_json::to_vec(&message).unwrap()).unwrap();
        serde_json::from_slice(&read_frame(&mut output).unwrap().unwrap()).unwrap()
    };

    let early = exchange(Message::Request {
        id: 1,
        method: methods::FS_STAT.into(),
        params: json!({ "path": "/" }),
    });
    assert!(
        matches!(early, Message::Response { error: Some(ref error), .. } if error.code == ErrorCode::InvalidRequest)
    );

    let mismatch = exchange(Message::Request {
        id: 2,
        method: methods::SERVER_HELLO.into(),
        params: json!({ "protocolVersion": 999, "clientName": "test" }),
    });
    assert!(
        matches!(mismatch, Message::Response { error: Some(ref error), .. } if error.code == ErrorCode::ProtocolMismatch)
    );

    drop(input);
    let status = child.wait().unwrap();
    assert!(status.success());
}

#[test]
fn files_are_written_atomically_and_guarded_against_concurrent_changes() {
    let directory = TempDir::new("files");
    let (session, _events) = connect();
    let file = directory.join("nested/a.txt");

    let created: FileMetadata = serde_json::from_value(
        call(
            &session,
            methods::FS_WRITE_FILE,
            json!({ "path": file, "data": encode_bytes(b"one"), "createParents": true }),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!((created.kind, created.size), (FileKind::File, 3));

    // Without a version guard an existing file is never replaced silently.
    assert_eq!(
        error_code(call(
            &session,
            methods::FS_WRITE_FILE,
            json!({ "path": file, "data": encode_bytes(b"x") })
        )),
        ErrorCode::AlreadyExists
    );

    let expected = json!({ "size": created.size, "modifiedMs": created.modified_ms });
    call(
        &session,
        methods::FS_WRITE_FILE,
        json!({ "path": file, "data": encode_bytes(b"second"), "expected": expected }),
    )
    .unwrap();
    // The first version is now stale: another editor's change must not be lost.
    assert_eq!(
        error_code(call(
            &session,
            methods::FS_WRITE_FILE,
            json!({ "path": file, "data": encode_bytes(b"third"), "expected": expected })
        )),
        ErrorCode::Conflict
    );

    let read: ReadFileResult = serde_json::from_value(
        call(
            &session,
            methods::FS_READ_FILE,
            json!({ "path": file, "offset": 2, "length": 3 }),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(decode_bytes(&read.data).unwrap(), b"con");
    assert!(!read.eof);

    // No temporary files are left next to the target.
    let listing: ReadDirResult = serde_json::from_value(
        call(
            &session,
            methods::FS_READ_DIR,
            json!({ "path": directory.join("nested") }),
        )
        .unwrap(),
    )
    .unwrap();
    let names: Vec<_> = listing
        .entries
        .iter()
        .map(|entry| entry.name.as_str())
        .collect();
    assert_eq!(names, ["a.txt"]);
    session.shutdown(STEP_TIMEOUT);
}

// Two creations of one path both pass the existence check before either
// commits. The commit must refuse to replace, or the first file is lost
// while both requests report success.
#[test]
fn concurrent_creations_of_one_path_keep_exactly_one_file() {
    let directory = TempDir::new("create-race");
    let (session, _events) = connect();
    for round in 0..20 {
        let file = directory.join(&format!("{round}.txt"));
        let results: Vec<_> = std::thread::scope(|scope| {
            let writers: Vec<_> = [b"left".as_slice(), b"right".as_slice()]
                .into_iter()
                .map(|data| {
                    let (session, file) = (&session, &file);
                    scope.spawn(move || {
                        let result = call(
                            session,
                            methods::FS_WRITE_FILE,
                            json!({ "path": file, "data": encode_bytes(data) }),
                        );
                        (data, result)
                    })
                })
                .collect();
            writers
                .into_iter()
                .map(|writer| writer.join().unwrap())
                .collect()
        });
        let winners: Vec<&[u8]> = results
            .iter()
            .filter(|(_, result)| result.is_ok())
            .map(|(data, _)| *data)
            .collect();
        assert_eq!(winners.len(), 1, "round {round}: {results:?}");
        for (_, result) in results.into_iter().filter(|(_, result)| result.is_err()) {
            assert_eq!(error_code(result), ErrorCode::AlreadyExists);
        }
        assert_eq!(std::fs::read(&file).unwrap(), winners[0]);
    }
    session.shutdown(STEP_TIMEOUT);
}

// A client that disconnects right after sending a write must not leave the
// write's temporary file behind: the server lets running filesystem
// requests finish before it exits.
#[test]
fn a_write_in_flight_at_disconnect_completes_without_leftovers() {
    let directory = TempDir::new("drain");
    let file = directory.join("large.bin");
    let data = vec![7_u8; 8 << 20];
    let mut child = Command::new(SERVER)
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    skip_preamble(&mut output, 0).unwrap();
    let mut send = |id, method: &str, params| {
        let message = Message::Request {
            id,
            method: method.into(),
            params,
        };
        write_frame(&mut input, &serde_json::to_vec(&message).unwrap()).unwrap();
    };
    send(
        1,
        methods::SERVER_HELLO,
        json!({ "protocolVersion": lithe_remote_protocol::PROTOCOL_VERSION, "clientName": "test" }),
    );
    send(
        2,
        methods::FS_WRITE_FILE,
        json!({ "path": file, "data": encode_bytes(&data) }),
    );
    drop(input);
    // Responses are drained so the server never blocks on a full pipe.
    while read_frame(&mut output).ok().flatten().is_some() {}
    assert!(child.wait().unwrap().success());

    assert_eq!(std::fs::read(&file).unwrap(), data);
    let names: Vec<_> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, ["large.bin"]);
}

#[test]
fn writing_through_a_symbolic_link_keeps_the_link() {
    let directory = TempDir::new("links");
    std::fs::write(directory.path().join("target.txt"), b"old").unwrap();
    std::os::unix::fs::symlink("target.txt", directory.path().join("link.txt")).unwrap();
    let (session, _events) = connect();

    call(
        &session,
        methods::FS_WRITE_FILE,
        json!({ "path": directory.join("link.txt"), "data": encode_bytes(b"new"), "overwrite": true }),
    )
    .unwrap();
    let link: FileMetadata = serde_json::from_value(
        call(
            &session,
            methods::FS_STAT,
            json!({ "path": directory.join("link.txt") }),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(link.kind, FileKind::Symlink);
    assert_eq!(link.symlink_target.as_deref(), Some("target.txt"));
    assert_eq!(link.symlink_target_kind, Some(FileKind::File));
    assert_eq!(
        std::fs::read(directory.path().join("target.txt")).unwrap(),
        b"new"
    );
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn directory_operations_report_stable_error_codes() {
    let directory = TempDir::new("dirs");
    let (session, _events) = connect();
    let tree = directory.join("tree");
    call(
        &session,
        methods::FS_CREATE_DIR,
        json!({ "path": format!("{tree}/b/c"), "recursive": true }),
    )
    .unwrap();
    std::fs::write(format!("{tree}/a.txt"), b"a").unwrap();

    let listing: ReadDirResult = serde_json::from_value(
        call(&session, methods::FS_READ_DIR, json!({ "path": tree })).unwrap(),
    )
    .unwrap();
    let names: Vec<_> = listing
        .entries
        .iter()
        .map(|entry| entry.name.as_str())
        .collect();
    assert_eq!(names, ["a.txt", "b"]);

    assert_eq!(
        error_code(call(
            &session,
            methods::FS_RENAME,
            json!({ "from": format!("{tree}/b"), "to": format!("{tree}/a.txt") })
        )),
        ErrorCode::AlreadyExists
    );
    call(
        &session,
        methods::FS_RENAME,
        json!({ "from": format!("{tree}/b"), "to": format!("{tree}/d") }),
    )
    .unwrap();
    assert_eq!(
        error_code(call(
            &session,
            methods::FS_REMOVE,
            json!({ "path": format!("{tree}/d") })
        )),
        ErrorCode::DirectoryNotEmpty
    );
    call(
        &session,
        methods::FS_REMOVE,
        json!({ "path": format!("{tree}/d"), "recursive": true }),
    )
    .unwrap();
    assert_eq!(
        error_code(call(
            &session,
            methods::FS_STAT,
            json!({ "path": format!("{tree}/d") })
        )),
        ErrorCode::NotFound
    );
    assert_eq!(
        error_code(call(
            &session,
            methods::FS_STAT,
            json!({ "path": "relative/path" })
        )),
        ErrorCode::InvalidPath
    );
    let volume: VolumeInfo = serde_json::from_value(
        call(&session, methods::FS_VOLUME_INFO, json!({ "path": tree })).unwrap(),
    )
    .unwrap();
    assert!(volume.case_sensitive.is_some());
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn process_output_precedes_its_exit_event() {
    let (session, events) = connect();
    let spawned: SpawnResult = session
        .request(
            methods::PROCESS_SPAWN,
            &json!({ "argv": ["sh", "-c", "printf out; printf err >&2; exit 3"], "env": { "LITHE_TEST": "1" } }),
            STEP_TIMEOUT,
        )
        .unwrap();
    let finished = wait_for_exit(&events, spawned.process_id);
    assert_eq!(finished.stdout, b"out");
    assert_eq!(finished.stderr, b"err");
    assert_eq!(finished.exit.unwrap().exit_code, Some(3));
    assert!(!finished.output_after_exit);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn standard_input_is_forwarded_and_closed() {
    let (session, events) = connect();
    let spawned: SpawnResult = session
        .request(
            methods::PROCESS_SPAWN,
            &json!({ "argv": ["cat"], "pipeStdin": true }),
            STEP_TIMEOUT,
        )
        .unwrap();
    let process = json!({ "processId": spawned.process_id });
    call(
        &session,
        methods::PROCESS_WRITE_STDIN,
        json!({ "processId": spawned.process_id, "data": encode_bytes(b"echoed") }),
    )
    .unwrap();
    call(&session, methods::PROCESS_CLOSE_STDIN, process).unwrap();
    let finished = wait_for_exit(&events, spawned.process_id);
    assert_eq!(finished.stdout, b"echoed");
    assert_eq!(finished.exit.unwrap().exit_code, Some(0));
    session.shutdown(STEP_TIMEOUT);
}

// Build tools start worker processes; killing only the leader would leave
// them running on the remote host.
#[test]
fn kill_reaches_the_whole_process_group() {
    let (session, events) = connect();
    let spawned: SpawnResult = session
        .request(
            methods::PROCESS_SPAWN,
            &json!({ "argv": ["sh", "-c", "sleep 60 & echo $!; wait"] }),
            STEP_TIMEOUT,
        )
        .unwrap();
    let worker = read_first_line_pid(&events, spawned.process_id);
    call(
        &session,
        methods::PROCESS_KILL,
        json!({ "processId": spawned.process_id }),
    )
    .unwrap();
    let finished = wait_for_exit(&events, spawned.process_id);
    assert_eq!(finished.exit.unwrap().signal, Some(libc::SIGTERM));
    assert!(
        wait_until_gone(worker),
        "worker {worker} survived the group kill"
    );
    assert_eq!(
        error_code(call(
            &session,
            methods::PROCESS_KILL,
            json!({ "processId": spawned.process_id })
        )),
        ErrorCode::ProcessNotFound
    );
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn disconnecting_terminates_spawned_processes() {
    let (session, events) = connect();
    let spawned: SpawnResult = session
        .request(
            methods::PROCESS_SPAWN,
            &json!({ "argv": ["sleep", "60"] }),
            STEP_TIMEOUT,
        )
        .unwrap();
    drop(events);
    // Dropping without shutdown is what a lost network connection looks like.
    drop(session);
    assert!(
        wait_until_gone(spawned.pid),
        "process {} outlived the session",
        spawned.pid
    );
}

/// Starts a group whose leader exits right away while a member keeps
/// running, as a build tool that leaves a daemon behind does. Returns the
/// process id and the surviving member's pid after the leader's exit event.
fn spawn_group_that_outlives_its_leader(
    session: &RemoteSession,
    events: &std::sync::mpsc::Receiver<lithe_remote_client::session::Event>,
) -> (u64, u32) {
    let spawned: SpawnResult = session
        .request(
            methods::PROCESS_SPAWN,
            &json!({ "argv": ["sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!"] }),
            STEP_TIMEOUT,
        )
        .unwrap();
    let finished = wait_for_exit(events, spawned.process_id);
    assert_eq!(finished.exit.unwrap().exit_code, Some(0));
    let member = String::from_utf8(finished.stdout)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    (spawned.process_id, member)
}

#[test]
fn kill_reaches_members_that_outlive_the_leader() {
    let (session, events) = connect();
    let (process_id, member) = spawn_group_that_outlives_its_leader(&session, &events);
    call(
        &session,
        methods::PROCESS_KILL,
        json!({ "processId": process_id, "force": true }),
    )
    .unwrap();
    assert!(
        wait_until_gone(member),
        "member {member} survived the group kill"
    );
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn disconnecting_terminates_members_that_outlive_the_leader() {
    let (session, events) = connect();
    let (_, member) = spawn_group_that_outlives_its_leader(&session, &events);
    drop(events);
    drop(session);
    assert!(
        wait_until_gone(member),
        "member {member} outlived the session"
    );
}

/// Reader that blocks while its gate is closed, standing in for a server
/// whose input stopped being consumed.
struct GatedReader {
    inner: std::io::PipeReader,
    gate: std::sync::Arc<Gate>,
}

#[derive(Default)]
struct Gate {
    closed: std::sync::Mutex<bool>,
    changed: std::sync::Condvar,
}

impl Gate {
    fn set_closed(&self, closed: bool) {
        *self.closed.lock().unwrap() = closed;
        self.changed.notify_all();
    }
}

impl std::io::Read for GatedReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let mut closed = self.gate.closed.lock().unwrap();
        while *closed {
            closed = self.gate.changed.wait(closed).unwrap();
        }
        drop(closed);
        self.inner.read(buffer)
    }
}

/// Opens the gate on drop so the server thread can finish after a failure.
struct OpenOnDrop(std::sync::Arc<Gate>);

impl Drop for OpenOnDrop {
    fn drop(&mut self) {
        self.0.set_closed(false);
    }
}

// A request whose frame cannot be written because the peer stopped reading
// must still end at its timeout, and must not hold up later requests.
#[test]
fn a_peer_that_stops_reading_cannot_block_requests_past_their_timeout() {
    let (server_input, client_output) = std::io::pipe().unwrap();
    let (client_input, server_output) = std::io::pipe().unwrap();
    let gate = std::sync::Arc::new(Gate::default());
    let _open = OpenOnDrop(std::sync::Arc::clone(&gate));
    let (served, server_done) = std::sync::mpsc::channel();
    {
        let reader = GatedReader {
            inner: server_input,
            gate: std::sync::Arc::clone(&gate),
        };
        std::thread::spawn(move || {
            let _ = served.send(lithe_remote_server::serve(reader, server_output));
        });
    }
    let options = lithe_remote_client::session::ConnectOptions {
        client_name: "test".into(),
        handshake_timeout: STEP_TIMEOUT,
    };
    let (session, _events) =
        RemoteSession::from_streams(client_input, client_output, &options).unwrap();
    let session = std::sync::Arc::new(session);
    let directory = TempDir::new("stalled");

    gate.set_closed(true);
    // The requests run on a helper thread so that a regression fails at the
    // test's own deadline instead of hanging the suite.
    let (finished, stalled) = std::sync::mpsc::channel();
    {
        let session = std::sync::Arc::clone(&session);
        // Far larger than a pipe buffer, so writing it blocks.
        let large =
            json!({ "path": directory.join("large"), "data": encode_bytes(&vec![0; 1 << 20]) });
        std::thread::spawn(move || {
            let short = std::time::Duration::from_millis(200);
            let first = session.request_value(methods::FS_WRITE_FILE, large, short);
            let second = session.request_value(methods::FS_STAT, json!({ "path": "/" }), short);
            // Released before reporting, so the test can take the session back.
            drop(session);
            let _ = finished.send((first, second));
        });
    }
    let (first, second) = stalled
        .recv_timeout(STEP_TIMEOUT)
        .expect("requests blocked past their timeout");
    assert!(matches!(first, Err(ClientError::Timeout)), "{first:?}");
    assert!(matches!(second, Err(ClientError::Timeout)), "{second:?}");

    gate.set_closed(false);
    let session = std::sync::Arc::try_unwrap(session)
        .ok()
        .expect("the helper thread released the session");
    call(&session, methods::FS_STAT, json!({ "path": "/" })).unwrap();
    session.shutdown(STEP_TIMEOUT);
    server_done
        .recv_timeout(STEP_TIMEOUT)
        .expect("server did not stop after shutdown")
        .unwrap();
}

#[test]
fn shell_banners_before_the_server_are_ignored() {
    let (session, _events) = connect_command(&[
        "sh".into(),
        "-c".into(),
        "printf 'Welcome to devbox'; exec \"$0\" --stdio".into(),
        SERVER.into(),
    ]);
    call(&session, methods::FS_STAT, json!({ "path": "/" })).unwrap();
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn a_missing_server_reports_the_transport_output() {
    let options = lithe_remote_client::session::ConnectOptions {
        client_name: "test".into(),
        handshake_timeout: STEP_TIMEOUT,
    };
    let result = RemoteSession::connect(
        &TransportChain::local(),
        &[
            "sh".into(),
            "-c".into(),
            "echo 'lithe-remote-server: not found' >&2; exit 127".into(),
        ],
        &options,
    );
    match result {
        Err(ClientError::Disconnected { diagnostics }) => {
            assert!(diagnostics.contains("not found"), "{diagnostics}")
        }
        Err(other) => panic!("unexpected error {other:?}"),
        Ok(_) => panic!("connected to a missing server"),
    }
}

#[test]
fn bootstrap_uploads_once_and_reuses_the_verified_binary() {
    let install = TempDir::new("install");
    let mut bootstrapper = Bootstrapper::new(TransportChain::local());
    bootstrapper.location = InstallLocation::Directory(install.path().to_str().unwrap().into());
    let probe = bootstrapper.probe().unwrap();
    let artifact =
        ServerArtifact::from_file(probe.target, SERVER.into(), env!("CARGO_PKG_VERSION")).unwrap();
    let artifact_for = |target| (target == artifact.target).then(|| artifact.clone());

    let first = bootstrapper.ensure_installed(artifact_for).unwrap();
    assert!(first.uploaded);
    assert!(first.path.starts_with(install.path().to_str().unwrap()));
    let second = bootstrapper.ensure_installed(artifact_for).unwrap();
    assert!(!second.uploaded);
    assert_eq!(first.path, second.path);

    let (session, _events) = connect_command(&first.stdio_command());
    call(&session, methods::FS_STAT, json!({ "path": "/" })).unwrap();
    session.shutdown(STEP_TIMEOUT);
}

fn read_first_line_pid(
    events: &std::sync::mpsc::Receiver<lithe_remote_client::session::Event>,
    process_id: u64,
) -> u32 {
    let mut line = Vec::new();
    let deadline = std::time::Instant::now() + STEP_TIMEOUT;
    while !line.contains(&b'\n') {
        let event = events
            .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .expect("worker pid was not printed");
        if event.event != methods::EVENT_PROCESS_OUTPUT {
            continue;
        }
        let output: methods::ProcessOutputEvent = serde_json::from_value(event.params).unwrap();
        if output.process_id == process_id {
            line.extend(decode_bytes(&output.data).unwrap());
        }
    }
    String::from_utf8(line).unwrap().trim().parse().unwrap()
}
