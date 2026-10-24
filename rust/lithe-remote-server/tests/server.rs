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
