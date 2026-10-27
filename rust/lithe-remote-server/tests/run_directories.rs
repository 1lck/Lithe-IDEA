//! Runtime snapshot allocation and cleanup through the real protocol.

mod support;

use lithe_remote_protocol::{methods, ErrorCode};
use serde_json::json;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use support::{TempDir, STEP_TIMEOUT};

#[test]
fn run_directory_release_is_idempotent_and_never_adopts_existing_paths() {
    let home = TempDir::new("run-home");
    let (session, _) = support::connect_with_environment(&[("HOME", home.str())]);
    let request = |method: &str, id: &str| {
        session.request_value(method, json!({"directoryId": id}), STEP_TIMEOUT)
    };
    assert!(session
        .hello()
        .host
        .features
        .contains(&methods::Feature::RunDirectories));
    let allocated = request(methods::FS_CREATE_RUN_DIRECTORY, "owned").unwrap();
    let path = Path::new(allocated["path"].as_str().unwrap());
    assert_eq!(std::fs::metadata(path).unwrap().mode() & 0o777, 0o700);
    std::fs::write(path.join("plugin"), b"approved bytes").unwrap();
    assert!(request(methods::FS_CREATE_RUN_DIRECTORY, "owned").is_err());
    request(methods::FS_RELEASE_RUN_DIRECTORY, "owned").unwrap();
    request(methods::FS_RELEASE_RUN_DIRECTORY, "owned").unwrap();
    assert!(!path.exists());
    std::fs::create_dir(path).unwrap();
    std::fs::write(path.join("user"), b"not owned").unwrap();
    assert!(request(methods::FS_CREATE_RUN_DIRECTORY, "owned").is_err());
    request(methods::FS_RELEASE_RUN_DIRECTORY, "owned").unwrap();
    assert_eq!(std::fs::read(path.join("user")).unwrap(), b"not owned");
    let invalid = request(methods::FS_CREATE_RUN_DIRECTORY, "../escape").unwrap_err();
    assert!(
        matches!(invalid, lithe_remote_client::session::ClientError::Remote(error) if error.code == ErrorCode::InvalidRequest)
    );
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn another_session_cannot_adopt_or_release_an_active_snapshot() {
    let home = TempDir::new("shared-run-home");
    let (owner, _) = support::connect_with_environment(&[("HOME", home.str())]);
    let (other, _) = support::connect_with_environment(&[("HOME", home.str())]);
    let params = json!({"directoryId": "same-identity"});
    let allocated = owner
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            params.clone(),
            STEP_TIMEOUT,
        )
        .unwrap();
    let path = Path::new(allocated["path"].as_str().unwrap());
    std::fs::write(path.join("plugin"), b"owned bytes").unwrap();
    assert!(other
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            params.clone(),
            STEP_TIMEOUT
        )
        .is_err());
    other
        .request_value(
            methods::FS_RELEASE_RUN_DIRECTORY,
            params.clone(),
            STEP_TIMEOUT,
        )
        .unwrap();
    other.shutdown(STEP_TIMEOUT);
    assert_eq!(std::fs::read(path.join("plugin")).unwrap(), b"owned bytes");
    owner
        .request_value(methods::FS_RELEASE_RUN_DIRECTORY, params, STEP_TIMEOUT)
        .unwrap();
    assert!(!path.exists());
    owner.shutdown(STEP_TIMEOUT);
}

#[test]
fn failed_release_reports_an_error_and_keeps_ownership_for_retry() {
    let home = TempDir::new("run-retry-home");
    let (session, _) = support::connect_with_environment(&[("HOME", home.str())]);
    let params = json!({"directoryId": "retry"});
    let allocated = session
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            params.clone(),
            STEP_TIMEOUT,
        )
        .unwrap();
    let path = Path::new(allocated["path"].as_str().unwrap());
    // Replacing the empty owned directory with a file produces a deterministic
    // removal error, even when the suite runs as root on Linux.
    std::fs::remove_dir(path).unwrap();
    std::fs::write(path, b"not a directory").unwrap();
    assert!(session
        .request_value(
            methods::FS_RELEASE_RUN_DIRECTORY,
            params.clone(),
            STEP_TIMEOUT
        )
        .is_err());
    assert_eq!(std::fs::read(path).unwrap(), b"not a directory");
    std::fs::remove_file(path).unwrap();
    std::fs::create_dir(path).unwrap();
    std::fs::write(path.join("plugin"), b"retry cleanup").unwrap();
    session
        .request_value(methods::FS_RELEASE_RUN_DIRECTORY, params, STEP_TIMEOUT)
        .unwrap();
    assert!(!path.exists());
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn allocation_rejects_shared_or_linked_parents_without_changing_them() {
    let home = TempDir::new("run-parent-home");
    let base = home.path().join(".lithe-server");
    std::fs::create_dir(&base).unwrap();
    std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (session, _) = support::connect_with_environment(&[("HOME", home.str())]);
    let params = json!({"directoryId": "private"});
    let error = session
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            params.clone(),
            STEP_TIMEOUT,
        )
        .unwrap_err();
    assert!(
        matches!(error, lithe_remote_client::session::ClientError::Remote(error)
        if error.code == ErrorCode::PermissionDenied)
    );
    assert_eq!(std::fs::metadata(&base).unwrap().mode() & 0o777, 0o755);
    assert!(!base.join("plugin-runs").exists());
    std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o700)).unwrap();
    let target = home.path().join("user-data");
    std::fs::create_dir(&target).unwrap();
    std::os::unix::fs::symlink(&target, base.join("plugin-runs")).unwrap();
    assert!(session
        .request_value(methods::FS_CREATE_RUN_DIRECTORY, params, STEP_TIMEOUT)
        .is_err());
    assert!(std::fs::symlink_metadata(base.join("plugin-runs"))
        .unwrap()
        .is_symlink());
    assert_eq!(std::fs::read_dir(target).unwrap().count(), 0);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn lost_client_snapshot_is_released_when_the_stdio_session_ends() {
    let home = TempDir::new("run-disconnect-home");
    let (session, _) = support::connect_with_environment(&[("HOME", home.str())]);
    let allocated = session
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            json!({"directoryId": "disconnected"}),
            STEP_TIMEOUT,
        )
        .unwrap();
    let path = Path::new(allocated["path"].as_str().unwrap());
    std::fs::write(path.join("plugin"), b"approved bytes").unwrap();
    drop(session);
    // Server exit is external to this process; observe the owned path with a
    // monotonic deadline, never wait on a fixed sleep or shared user directory.
    let deadline = std::time::Instant::now() + STEP_TIMEOUT;
    while path.exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "stdio disconnect leaked its snapshot"
        );
        std::thread::yield_now();
    }
}

#[test]
fn persistent_disconnect_retains_snapshot_until_explicit_shutdown() {
    let home = TempDir::new("persistent-run-home");
    let daemon = support::Daemon::new("persistent-run");
    let mut command = vec!["env".into(), format!("HOME={}", home.str())];
    command.extend(daemon.command());
    let (session, _) = support::connect_command(&command);
    let allocated = session
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            json!({"directoryId": "persistent"}),
            STEP_TIMEOUT,
        )
        .unwrap();
    let path = Path::new(allocated["path"].as_str().unwrap());
    std::fs::write(path.join("plugin"), b"approved bytes").unwrap();
    drop(session);
    let (replacement, _) = support::connect_command(&command);
    assert_eq!(
        std::fs::read(path.join("plugin")).unwrap(),
        b"approved bytes"
    );
    // The consuming process is still using this snapshot when the session
    // ends. Teardown must stop it before removing its working directory.
    let process = replacement
        .spawn(lithe_remote_client::SpawnSpec {
            argv: vec!["/bin/cat".into()],
            cwd: Some(path.to_string_lossy().into_owned()),
            pipe_stdin: true,
            ..Default::default()
        })
        .unwrap();
    let pid = process.pid;
    drop(process); // Dropping the subscription leaves the consumer running.
    replacement.shutdown(STEP_TIMEOUT);
    assert!(daemon.wait_until_stopped());
    assert!(
        support::wait_until_gone(pid),
        "snapshot consumer survived shutdown"
    );
    assert!(!path.exists());
}

#[test]
fn abandoned_desktop_snapshot_is_reclaimed_after_persistent_session_expiry() {
    let home = TempDir::new("expired-run-home");
    let daemon = support::Daemon::new("expired-run");
    let mut command = vec!["env".into(), format!("HOME={}", home.str())];
    command.extend(daemon.command());
    let mut options = support::options();
    options.idle_timeout = Some(std::time::Duration::from_secs(1));
    let (session, _) = lithe_remote_client::RemoteSession::connect(
        &lithe_remote_client::TransportChain::local(),
        &command,
        &options,
    )
    .unwrap();
    let allocated = session
        .request_value(
            methods::FS_CREATE_RUN_DIRECTORY,
            json!({"directoryId": "expired"}),
            STEP_TIMEOUT,
        )
        .unwrap();
    let path = Path::new(allocated["path"].as_str().unwrap());
    std::fs::write(path.join("plugin"), b"approved bytes").unwrap();
    drop(session);
    assert!(daemon.wait_until_stopped());
    assert!(!path.exists());
}
