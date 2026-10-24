//! Remote development connections: checking that a saved SSH connection
//! reaches a usable host before any workspace is opened on it.
//!
//! The command builds the transport chain with `lithe-remote-client`, runs
//! its platform probe through the system OpenSSH client, and relays every
//! question OpenSSH asks (passwords, key passphrases, one-time codes, unknown
//! host keys) to the host UI through the shared AskPass session. Core never
//! stores an answer; hosts keep saved secrets in their own secure storage.
//!
//! Note: .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

use crate::git::execution_events;
use crate::protocol::{CoreError, ErrorCode};
use lithe_remote_client::bootstrap::{parse_probe, probe_command};
use lithe_remote_client::{Hop, SshHop, TransportChain};
use serde::{Deserialize, Serialize};
use std::process::{Command, ExitStatus};
use std::time::{Duration, Instant};

pub(crate) mod sessions;

/// Seconds OpenSSH waits for the TCP connection when the profile sets none.
const DEFAULT_CONNECT_TIMEOUT_SECONDS: u32 = 15;

/// Upper bound for one probe, including the time the user needs to answer
/// prompts. Each prompt is additionally bounded by the AskPass session.
const PROBE_DEADLINE: Duration = Duration::from_secs(5 * 60);

/// Bytes of OpenSSH's standard error kept as diagnostics.
const DIAGNOSTICS_LIMIT: usize = 4 * 1024;

/// How the connection proves the user's identity. Every method still lets
/// OpenSSH ask follow-up questions, such as a one-time code.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Authentication {
    /// OpenSSH's own order: keys and agent first, then interactive methods.
    #[default]
    Auto,
    /// Keys offered by the running SSH agent or the SSH configuration.
    Agent,
    /// Only the private key named by `identityFile`.
    PrivateKey,
    /// Password or keyboard-interactive prompts, without trying keys.
    Password,
}

/// One saved SSH connection. Only facts that change the target or the
/// authentication are sent; names and colors stay in the host.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SshConnection {
    /// Host name, address, or a `Host` alias from the user's SSH configuration.
    host: String,
    /// `None` keeps the port from the SSH configuration (22 by default).
    #[serde(default)]
    port: Option<u16>,
    /// `None` keeps the user from the SSH configuration.
    #[serde(default)]
    user: Option<String>,
    #[serde(default)]
    authentication: Authentication,
    /// Private key path; required for [`Authentication::PrivateKey`]. OpenSSH
    /// expands a leading `~` itself.
    #[serde(default)]
    identity_file: Option<String>,
    #[serde(default)]
    connect_timeout_seconds: Option<u32>,
    /// `None` keeps the transport's keep-alive default.
    #[serde(default)]
    keep_alive_seconds: Option<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProbeRequest {
    connection: SshConnection,
}

/// Stable outcome of a probe. Failures to connect are results, not Core
/// errors, so the host can show a specific explanation for each.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ProbeStatus {
    /// A shell ran on the host and a server build exists for it.
    Connected,
    /// The host answered, but no server build exists for its platform.
    UnsupportedPlatform,
    /// The server rejected every offered credential.
    AuthenticationFailed,
    /// The host key is unknown and was declined, or it changed.
    HostKeyRejected,
    /// The name did not resolve, or the host could not be reached in time.
    Unreachable,
    /// The connection failed for another reason; see `diagnostics`.
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProbedHost {
    /// `uname -s`, for example `Linux` or `Darwin`.
    system: String,
    /// `uname -m`, for example `x86_64` or `arm64`.
    machine: String,
    home_directory: Option<String>,
    /// Rust target of the server build for this host, or `None`.
    server_target: Option<&'static str>,
    /// Facts for display, such as the distribution and memory.
    details: lithe_remote_client::bootstrap::HostDetails,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProbeResult {
    status: ProbeStatus,
    /// Present when the host's shell ran the probe.
    host: Option<ProbedHost>,
    /// Redacted tail of OpenSSH's standard error.
    diagnostics: String,
}

/// Probes the host named by the request's connection.
pub(crate) fn probe(request: ProbeRequest) -> Result<ProbeResult, CoreError> {
    probe_with(request, None)
}

/// `ssh_program` replaces the `ssh` found on `PATH`; tests use a stand-in.
fn probe_with(request: ProbeRequest, ssh_program: Option<&str>) -> Result<ProbeResult, CoreError> {
    let mut hop = ssh_hop(&request.connection)?;
    if let Some(program) = ssh_program {
        hop.program = program.into();
    }
    let chain = TransportChain::new(vec![Hop::Ssh(hop)]);
    let argv = chain.command(&probe_command()).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid SSH connection")
            .with_details(error.to_string())
    })?;
    let (program, arguments) = argv
        .split_first()
        .expect("an SSH hop always produces a command");
    let mut process = Command::new(program);
    process.args(arguments);

    let mut authentication = lithe_git_host::authentication::Session::new().map_err(|error| {
        CoreError::new(
            ErrorCode::ProcessStartFailed,
            "Could not prepare SSH authentication",
        )
        .with_details(error.to_string())
    })?;
    authentication.configure(&mut process).map_err(|error| {
        CoreError::new(
            ErrorCode::ProcessStartFailed,
            "Could not configure SSH authentication",
        )
        .with_details(error.to_string())
    })?;

    let deadline = Instant::now() + PROBE_DEADLINE;
    let mut stop = None;
    let output = lithe_git_host::run(
        &mut process,
        None,
        || {
            if let Err(error) = crate::protocol::cancellation::check() {
                stop = Some(error);
            } else if Instant::now() >= deadline {
                stop = Some(CoreError::new(
                    ErrorCode::TimedOut,
                    "The SSH connection did not finish in time",
                ));
            } else {
                match authentication.poll() {
                    Ok(challenges) => {
                        for challenge in challenges {
                            execution_events::emit(serde_json::json!({
                                "type": "authentication",
                                "requestId": challenge.request_id,
                                "prompt": execution_events::redact(&challenge.prompt),
                                "secret": challenge.secret,
                                "attempt": challenge.attempt,
                            }));
                        }
                    }
                    Err(error) => {
                        stop = Some(
                            CoreError::new(
                                ErrorCode::ProcessFailed,
                                "SSH authentication transport failed",
                            )
                            .with_details(error.to_string()),
                        )
                    }
                }
            }
            stop.is_some()
        },
        || {},
        |_, _| {},
    );
    if let Some(error) = stop {
        return Err(error);
    }
    match output.failure {
        None => {}
        Some(lithe_git_host::Failure::Start(error)) => {
            return Err(
                CoreError::new(ErrorCode::RuntimeMissing, "Could not start the SSH client")
                    .with_details(error.to_string()),
            )
        }
        Some(failure) => {
            return Err(
                CoreError::new(ErrorCode::ProcessFailed, "The SSH client failed")
                    .with_details(format!("{failure:?}")),
            )
        }
    }
    Ok(classify(output.status, &output.stdout, &output.stderr))
}

/// Answers a prompt that a running probe relayed.
pub(crate) fn respond(request_id: &str, answer: Option<String>) -> bool {
    lithe_git_host::authentication::respond(request_id, answer)
}

fn ssh_hop(connection: &SshConnection) -> Result<SshHop, CoreError> {
    let invalid = |reason: &str| CoreError::new(ErrorCode::InvalidRequest, reason.to_string());
    let host = connection.host.trim();
    if host.is_empty() || host.contains('@') {
        return Err(invalid("Enter a host name or address without a user"));
    }
    let destination = match connection.user.as_deref().map(str::trim) {
        Some(user) if !user.is_empty() => {
            if user.starts_with('-')
                || user
                    .chars()
                    .any(|character| matches!(character, '@' | ':') || character.is_whitespace())
            {
                return Err(invalid("The user name contains characters SSH cannot use"));
            }
            format!("{user}@{host}")
        }
        _ => host.to_string(),
    };
    let mut hop = SshHop::new(destination);
    hop.port = connection.port.filter(|port| *port != 0);
    let mut option = |key: &str, value: String| hop.options.push((key.into(), value));
    option(
        "ConnectTimeout",
        connection
            .connect_timeout_seconds
            .filter(|seconds| *seconds > 0)
            .unwrap_or(DEFAULT_CONNECT_TIMEOUT_SECONDS)
            .to_string(),
    );
    if let Some(seconds) = connection.keep_alive_seconds {
        option("ServerAliveInterval", seconds.to_string());
    }
    // Prompts must reach AskPass even when the user's configuration sets
    // BatchMode for scripts.
    option("BatchMode", "no".into());
    match connection.authentication {
        Authentication::Auto => {}
        Authentication::Agent => option("PreferredAuthentications", "publickey".into()),
        Authentication::PrivateKey => {
            let identity = connection
                .identity_file
                .as_deref()
                .map(str::trim)
                .filter(|path| !path.is_empty())
                .ok_or_else(|| invalid("Choose a private key file"))?;
            if identity.chars().any(char::is_control) {
                return Err(invalid("The private key path is invalid"));
            }
            // ssh splits an option value on whitespace, so a path such as
            // "~/My Keys/id_rsa" must be quoted (ssh_config quoting rules).
            let identity = if identity
                .chars()
                .any(|c| c.is_whitespace() || c == '"' || c == '\\')
            {
                format!(
                    "\"{}\"",
                    identity.replace('\\', "\\\\").replace('"', "\\\"")
                )
            } else {
                identity.to_string()
            };
            option("IdentityFile", identity);
            // Without this, keys from the agent are tried first and can use
            // up the server's attempt limit before the chosen key is offered.
            option("IdentitiesOnly", "yes".into());
            option("PreferredAuthentications", "publickey".into());
        }
        Authentication::Password => {
            option(
                "PreferredAuthentications",
                "keyboard-interactive,password".into(),
            );
            option("PubkeyAuthentication", "no".into());
        }
    }
    Ok(hop)
}

/// Interprets the finished probe. OpenSSH reports connection failures only
/// as text, so the categories match its stable English messages.
fn classify(exit: Option<ExitStatus>, stdout: &[u8], stderr: &[u8]) -> ProbeResult {
    let stderr_text = String::from_utf8_lossy(stderr);
    let diagnostics = diagnostics(&stderr_text);
    if let Some(report) = parse_probe(stdout) {
        let server_target = report.target().map(|target| target.rust_target());
        return ProbeResult {
            status: if server_target.is_some() {
                ProbeStatus::Connected
            } else {
                ProbeStatus::UnsupportedPlatform
            },
            host: Some(ProbedHost {
                system: report.system,
                machine: report.machine,
                home_directory: report.home,
                server_target,
                details: report.details,
            }),
            diagnostics,
        };
    }
    let lower = stderr_text.to_ascii_lowercase();
    let mentions = |needles: &[&str]| needles.iter().any(|needle| lower.contains(needle));
    let status = if mentions(&[
        "host key verification failed",
        "remote host identification has changed",
    ]) {
        ProbeStatus::HostKeyRejected
    } else if mentions(&[
        "permission denied",
        "too many authentication failures",
        "no supported authentication methods",
    ]) {
        ProbeStatus::AuthenticationFailed
    } else if mentions(&[
        "could not resolve hostname",
        "connection refused",
        "connection timed out",
        "operation timed out",
        "no route to host",
        "network is unreachable",
    ]) {
        ProbeStatus::Unreachable
    } else {
        ProbeStatus::Failed
    };
    let diagnostics = if diagnostics.is_empty() {
        // Some failures, such as a remote shell that exits early, print
        // nothing; the exit status is then the only clue.
        match exit.and_then(|exit| exit.code()) {
            Some(code) => format!("ssh exited with status {code}"),
            None => "ssh was terminated by a signal".into(),
        }
    } else {
        diagnostics
    };
    ProbeResult {
        status,
        host: None,
        diagnostics,
    }
}

/// Keeps the end of the output, where OpenSSH prints the reason it gave up,
/// and removes credentials and home directory paths.
fn diagnostics(stderr: &str) -> String {
    let trimmed = stderr.trim();
    let mut start = trimmed.len().saturating_sub(DIAGNOSTICS_LIMIT);
    while !trimmed.is_char_boundary(start) {
        start += 1;
    }
    execution_events::redact(&trimmed[start..])
}

#[cfg(test)]
mod tests;
