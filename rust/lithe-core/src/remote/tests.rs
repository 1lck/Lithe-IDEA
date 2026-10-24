use super::*;
#[cfg(unix)]
use crate::tests::support::temporary_root;
use serde_json::json;
#[cfg(unix)]
use std::path::{Path, PathBuf};

fn connection(value: serde_json::Value) -> SshConnection {
    serde_json::from_value(value).expect("valid connection")
}

/// The local command line the connection produces for the probe.
fn command_line(value: serde_json::Value) -> Vec<String> {
    let hop = ssh_hop(&connection(value)).expect("valid hop");
    TransportChain::new(vec![Hop::Ssh(hop)])
        .command(&probe_command())
        .unwrap()
}

fn option_value(command: &[String], key: &str) -> Option<String> {
    command
        .windows(2)
        .filter(|pair| pair[0] == "-o")
        .find_map(|pair| pair[1].strip_prefix(&format!("{key}=")).map(str::to_owned))
}

#[test]
fn private_key_connections_offer_only_the_chosen_key() {
    let command = command_line(json!({
        "host": "devbox.example",
        "port": 2222,
        "user": "dev",
        "authentication": "privateKey",
        "identityFile": "~/.ssh/id_ed25519",
        "connectTimeoutSeconds": 20,
        "keepAliveSeconds": 30,
    }));
    assert!(command.windows(2).any(|pair| pair == ["-p", "2222"]));
    assert_eq!(&command[command.len() - 2], "dev@devbox.example");
    assert_eq!(
        option_value(&command, "IdentityFile").as_deref(),
        Some("~/.ssh/id_ed25519")
    );
    assert_eq!(
        option_value(&command, "IdentitiesOnly").as_deref(),
        Some("yes")
    );
    assert_eq!(
        option_value(&command, "PreferredAuthentications").as_deref(),
        Some("publickey")
    );
    assert_eq!(
        option_value(&command, "ConnectTimeout").as_deref(),
        Some("20")
    );
    // OpenSSH keeps the first value, so the profile's interval must come
    // before the transport's default.
    assert_eq!(
        option_value(&command, "ServerAliveInterval").as_deref(),
        Some("30")
    );
    assert_eq!(option_value(&command, "BatchMode").as_deref(), Some("no"));
}

#[test]
fn other_authentication_methods_select_matching_ssh_options() {
    let password = command_line(json!({ "host": "h", "authentication": "password" }));
    assert_eq!(
        option_value(&password, "PreferredAuthentications").as_deref(),
        Some("keyboard-interactive,password")
    );
    assert_eq!(
        option_value(&password, "PubkeyAuthentication").as_deref(),
        Some("no")
    );

    let agent = command_line(json!({ "host": "h", "authentication": "agent" }));
    assert_eq!(
        option_value(&agent, "PreferredAuthentications").as_deref(),
        Some("publickey")
    );
    assert_eq!(option_value(&agent, "IdentityFile"), None);

    // Automatic leaves the order to OpenSSH and the user's configuration,
    // and an alias without a user or port stays untouched.
    let automatic = command_line(json!({ "host": "devbox" }));
    assert_eq!(option_value(&automatic, "PreferredAuthentications"), None);
    assert_eq!(&automatic[automatic.len() - 2], "devbox");
    assert!(!automatic.iter().any(|argument| argument == "-p"));
    assert_eq!(
        option_value(&automatic, "ConnectTimeout").as_deref(),
        Some(DEFAULT_CONNECT_TIMEOUT_SECONDS.to_string().as_str())
    );
}

#[test]
fn malformed_connections_are_rejected_before_ssh_starts() {
    for value in [
        json!({ "host": "" }),
        json!({ "host": "dev@box" }),
        json!({ "host": "-oProxyCommand=touch x" }),
        json!({ "host": "box", "user": "-oProxyCommand=x" }),
        json!({ "host": "box", "user": "a b" }),
        json!({ "host": "box", "authentication": "privateKey" }),
    ] {
        let hop = ssh_hop(&connection(value.clone()));
        let command = hop.and_then(|hop| {
            TransportChain::new(vec![Hop::Ssh(hop)])
                .command(&probe_command())
                .map_err(|error| CoreError::new(ErrorCode::InvalidRequest, error.to_string()))
        });
        assert!(
            matches!(command, Err(ref error) if matches!(error.code, ErrorCode::InvalidRequest)),
            "{value} was accepted"
        );
    }
    assert!(
        serde_json::from_value::<SshConnection>(json!({ "host": "h", "password": "x" })).is_err()
    );
}

#[test]
fn ssh_failures_map_to_stable_statuses() {
    let cases: [(&str, ProbeStatus); 6] = [
        (
            "dev@box: Permission denied (publickey,password).",
            ProbeStatus::AuthenticationFailed,
        ),
        (
            "Received disconnect: Too many authentication failures",
            ProbeStatus::AuthenticationFailed,
        ),
        (
            "Host key verification failed.",
            ProbeStatus::HostKeyRejected,
        ),
        (
            "ssh: Could not resolve hostname nowhere: nodename nor servname provided",
            ProbeStatus::Unreachable,
        ),
        (
            "ssh: connect to host 10.0.0.1 port 22: Operation timed out",
            ProbeStatus::Unreachable,
        ),
        (
            "kex_exchange_identification: read: Connection reset by peer",
            ProbeStatus::Failed,
        ),
    ];
    for (stderr, expected) in cases {
        let result = classify(None, b"", stderr.as_bytes());
        assert_eq!(result.status, expected, "{stderr}");
        assert_eq!(result.host, None);
        assert_eq!(result.diagnostics, stderr);
    }
}

#[test]
fn a_reported_platform_decides_between_connected_and_unsupported() {
    let connected = classify(
        None,
        b"motd\nLITHE-PROBE-BEGIN\nLinux\naarch64\n/home/dev\nLITHE-PROBE-END\n",
        b"",
    );
    assert_eq!(connected.status, ProbeStatus::Connected);
    assert_eq!(
        connected.host,
        Some(ProbedHost {
            system: "Linux".into(),
            machine: "aarch64".into(),
            home_directory: Some("/home/dev".into()),
            server_target: Some("aarch64-unknown-linux-musl"),
            details: Default::default(),
        })
    );
    let unsupported = classify(
        None,
        b"LITHE-PROBE-BEGIN\nFreeBSD\namd64\n/home/dev\nLITHE-PROBE-END\n",
        b"",
    );
    assert_eq!(unsupported.status, ProbeStatus::UnsupportedPlatform);
    assert_eq!(unsupported.host.unwrap().server_target, None);
}

#[test]
fn diagnostics_keep_the_redacted_end_of_long_output() {
    let noise = "debug1: x\n".repeat(1_000);
    let result = classify(
        None,
        format!("{noise}Permission denied for /Users/someone/.ssh/id_ed25519").as_bytes(),
        b"",
    );
    // Standard output without a probe block is not the shell's report.
    assert_eq!(result.status, ProbeStatus::Failed);
    let result = classify(
        None,
        b"",
        format!("{noise}Permission denied for /Users/someone/.ssh/id_ed25519").as_bytes(),
    );
    assert!(result.diagnostics.len() <= DIAGNOSTICS_LIMIT);
    assert!(
        result.diagnostics.ends_with("<HOME>/.ssh/id_ed25519"),
        "{}",
        result.diagnostics
    );
}

/// Stand-in for OpenSSH: ignores its options and runs the remote command
/// with the local shell, or fails like a rejecting server.
#[cfg(unix)]
struct FakeSsh {
    root: PathBuf,
    program: PathBuf,
}

#[cfg(unix)]
impl FakeSsh {
    fn new(label: &str, body: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;
        let root = temporary_root(label);
        std::fs::create_dir_all(&root).unwrap();
        let program = root.join("ssh");
        std::fs::write(&program, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { root, program }
    }

    fn path(&self) -> &str {
        self.program.to_str().unwrap()
    }
}

#[cfg(unix)]
impl Drop for FakeSsh {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[cfg(unix)]
fn probe_request() -> ProbeRequest {
    serde_json::from_value(json!({ "connection": { "host": "devbox", "user": "dev" } })).unwrap()
}

#[cfg(unix)]
fn local_uname(flag: &str) -> String {
    let output = Command::new("uname").arg(flag).output().unwrap();
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[cfg(unix)]
#[test]
fn probing_runs_the_platform_report_through_the_ssh_client() {
    let ssh = FakeSsh::new(
        "remote-probe",
        "for last; do :; done\nexec /bin/sh -c \"$last\"",
    );
    let result = probe_with(probe_request(), Some(ssh.path())).unwrap();
    let host = result.host.expect("the probe block was read");
    assert_eq!(host.system, local_uname("-s"));
    assert_eq!(host.machine, local_uname("-m"));
    assert!(host
        .home_directory
        .as_deref()
        .is_some_and(|home| Path::new(home).is_absolute()));
    assert_eq!(result.status, ProbeStatus::Connected);
    // The details block ran with the real shell and tools.
    assert_eq!(
        host.details.kernel.as_deref(),
        Some(local_uname("-r").as_str())
    );
    assert!(host.details.cpu_count.is_some_and(|count| count > 0));
    assert!(host.details.disk_total_bytes.is_some());
}

#[cfg(unix)]
#[test]
fn a_rejecting_server_is_reported_as_an_authentication_failure() {
    let ssh = FakeSsh::new(
        "remote-probe-denied",
        "echo 'dev@devbox: Permission denied (publickey).' >&2\nexit 255",
    );
    let result = probe_with(probe_request(), Some(ssh.path())).unwrap();
    assert_eq!(result.status, ProbeStatus::AuthenticationFailed);
    assert_eq!(
        result.diagnostics,
        "dev@devbox: Permission denied (publickey)."
    );
}

#[cfg(unix)]
#[test]
fn a_missing_ssh_client_is_a_runtime_error() {
    let missing = temporary_root("remote-probe-missing").join("ssh");
    let error = probe_with(probe_request(), missing.to_str()).unwrap_err();
    assert!(matches!(error.code, ErrorCode::RuntimeMissing), "{error:?}");
}

#[cfg(unix)]
fn connect_request(servers: serde_json::Value) -> sessions::ConnectRequest {
    serde_json::from_value(json!({
        "connection": { "host": "devbox", "user": "dev" },
        "servers": servers,
        "serverVersion": "0.1.0",
    }))
    .unwrap()
}

// A rejected login ends before the remote shell runs; the result names the
// reason instead of failing the request.
#[cfg(unix)]
#[test]
fn connecting_to_a_rejecting_server_reports_the_reason() {
    let ssh = FakeSsh::new(
        "remote-connect-denied",
        "echo 'dev@devbox: Permission denied (password).' >&2\nexit 255",
    );
    let result = sessions::connect_with(connect_request(json!([])), Some(ssh.path())).unwrap();
    let value = serde_json::to_value(result).unwrap();
    assert_eq!(value["status"], "authenticationFailed");
    assert_eq!(value["session"], serde_json::Value::Null);
    assert_eq!(
        value["diagnostics"],
        "dev@devbox: Permission denied (password)."
    );
}

// The shell runs and reports its platform, but the host ships no server for
// it, so nothing is uploaded and the platform is reported.
#[cfg(unix)]
#[test]
fn connecting_without_a_matching_server_reports_the_platform() {
    let ssh = FakeSsh::new(
        "remote-connect-platform",
        "for last; do :; done\nexec /bin/sh -c \"$last\"",
    );
    let result = sessions::connect_with(connect_request(json!([])), Some(ssh.path())).unwrap();
    let value = serde_json::to_value(result).unwrap();
    assert_eq!(value["status"], "unsupportedPlatform");
    assert_eq!(value["host"]["system"], local_uname("-s"));
}

#[test]
fn unknown_server_targets_are_rejected() {
    let request: sessions::ConnectRequest = serde_json::from_value(json!({
        "connection": { "host": "devbox" },
        "servers": [{ "target": "riscv64-unknown-linux-musl", "path": "/nowhere" }],
        "serverVersion": "0.1.0",
    }))
    .unwrap();
    let error = sessions::connect(request).unwrap_err();
    assert!(matches!(error.code, ErrorCode::InvalidRequest), "{error:?}");
}

#[test]
fn closed_connections_cannot_be_used() {
    let request: sessions::ReadDirRequest =
        serde_json::from_value(json!({ "sessionId": "missing", "path": "/" })).unwrap();
    assert!(matches!(
        sessions::read_dir(request).unwrap_err().code,
        ErrorCode::ConnectionClosed
    ));
    let request: sessions::DisconnectRequest =
        serde_json::from_value(json!({ "sessionId": "missing" })).unwrap();
    assert!(!sessions::disconnect(request));
}

// Application exit closes whatever is open and must be safe with nothing open.
#[test]
fn closing_all_connections_with_none_open_succeeds() {
    assert_eq!(sessions::close_registered(), 0);
}

// ssh splits an option value on whitespace, so a key path with spaces must
// reach it quoted.
#[test]
fn private_key_paths_with_spaces_are_quoted() {
    let command = command_line(json!({
        "host": "devbox.example",
        "authentication": "privateKey",
        "identityFile": "/Users/me/My Keys/id_rsa",
    }));
    assert_eq!(
        option_value(&command, "IdentityFile").as_deref(),
        Some("\"/Users/me/My Keys/id_rsa\"")
    );
}
