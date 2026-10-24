//! Probing, installing and starting the server over one connection.
//!
//! [`crate::bootstrap::Bootstrapper`] runs one command per step, so an SSH
//! host that asks for a password asks once per step. This module does all
//! steps inside one remote shell on one stream instead:
//!
//! 1. the shell reports the platform between markers;
//! 2. the client picks the artifact for it and sends one line naming its
//!    version, SHA-256 and size;
//! 3. the shell keeps an installed binary that reports that SHA-256, or
//!    receives exactly `size` bytes, installs them under a temporary name and
//!    verifies the result;
//! 4. the shell `exec`s the server, whose preamble starts the protocol on the
//!    same stream, ready for [`crate::RemoteSession::from_streams`].
//!
//! The script crosses SSH hops, so it is a single line without `'`, `\` or
//! `!` (see [`crate::transport`]). Install directories match the bootstrapper's,
//! so both paths reuse each other's installs.

use crate::bootstrap::{parse_probe, ProbeReport, ServerArtifact, INSTALL_HASH_PREFIX};
use std::fmt;
use std::io::{self, Read, Write};

const INSTALL_PRESENT: &str = "LITHE-INSTALL-PRESENT";
const INSTALL_NEEDED: &str = "LITHE-INSTALL-NEEDED";
const PROBE_END: &str = "LITHE-PROBE-END";

/// Output accepted before the probe block ends, for example a login banner.
const NOISE_LIMIT: usize = 64 * 1024;

/// `$1` is the install root; empty means `$HOME/.lithe-server`. The remaining
/// arguments are passed to the server, for example `--stdio`.
const LAUNCH_SCRIPT: &str = concat!(
    crate::bootstrap::host_details_script!(),
    "echo LITHE-PROBE-BEGIN; uname -s; uname -m; echo \"$HOME\"; echo LITHE-PROBE-END; ",
    "read version sha size name || exit 90; ",
    "root=\"$1\"; [ -n \"$root\" ] || root=\"$HOME/.lithe-server\"; ",
    "dir=\"$root/bin/$name\"; exe=\"$dir/lithe-remote-server\"; ",
    "if \"$exe\" --identity 2>/dev/null | grep -q \"$sha\"; then echo LITHE-INSTALL-PRESENT; else ",
    "echo LITHE-INSTALL-NEEDED; umask 077; ",
    "mkdir -p \"$dir\" && head -c \"$size\" > \"$dir/.upload.$$\" && chmod 700 \"$dir/.upload.$$\" ",
    "&& mv -f \"$dir/.upload.$$\" \"$exe\" || { echo LITHE-INSTALL-FAILED >&2; exit 92; }; ",
    "\"$exe\" --identity 2>/dev/null | grep -q \"$sha\" || { echo LITHE-INSTALL-FAILED >&2; exit 93; }; ",
    "fi; shift; exec \"$exe\" \"$@\""
);

/// Command to run at the end of a chain. `root` overrides the install root,
/// for hosts with a read-only home or for tests; `server_arguments` start
/// the server, for example `["--stdio"]`.
pub fn launch_command(root: Option<&str>, server_arguments: &[&str]) -> Vec<String> {
    let mut command = vec![
        "sh".into(),
        "-c".into(),
        LAUNCH_SCRIPT.into(),
        "lithe-launch".into(),
        root.unwrap_or_default().into(),
    ];
    command.extend(server_arguments.iter().map(|argument| argument.to_string()));
    command
}

/// What happened before the server took over the stream.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Launched {
    pub report: ProbeReport,
    /// Whether this launch uploaded the binary.
    pub uploaded: bool,
}

#[derive(Debug)]
pub enum LaunchError {
    /// The stream ended before the shell reported its platform, usually
    /// because the connection or authentication failed.
    NoShell,
    /// The caller has no artifact for the reported platform.
    NoArtifact(Box<ProbeReport>),
    /// The shell answered something other than this script's protocol.
    Protocol(String),
    Io(io::Error),
}

impl fmt::Display for LaunchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoShell => formatter.write_str("the remote shell did not start"),
            Self::NoArtifact(report) => write!(
                formatter,
                "no remote server is available for {} {}",
                report.system, report.machine
            ),
            Self::Protocol(message) => write!(formatter, "unexpected remote output: {message}"),
            Self::Io(error) => write!(formatter, "remote stream failed: {error}"),
        }
    }
}

impl std::error::Error for LaunchError {}

/// Drives the script on a started connection. `output` is read one byte at
/// a time so that nothing after the script's lines is consumed; the session
/// reads the rest. Blocking reads end when the caller closes the connection.
pub fn launch(
    output: &mut impl Read,
    input: &mut impl Write,
    artifact_for: impl FnOnce(&ProbeReport) -> Option<ServerArtifact>,
) -> Result<Launched, LaunchError> {
    let mut probe_output = Vec::new();
    loop {
        let line = read_line(output, NOISE_LIMIT.saturating_sub(probe_output.len()))?
            .ok_or(LaunchError::NoShell)?;
        probe_output.extend_from_slice(&line);
        probe_output.push(b'\n');
        if String::from_utf8_lossy(&line).trim_end() == PROBE_END {
            break;
        }
    }
    let report = parse_probe(&probe_output).ok_or(LaunchError::NoShell)?;
    let artifact =
        artifact_for(&report).ok_or_else(|| LaunchError::NoArtifact(Box::new(report.clone())))?;
    let binary = std::fs::read(&artifact.path).map_err(LaunchError::Io)?;
    let name = format!(
        "{}-{}",
        artifact.version,
        &artifact.sha256[..INSTALL_HASH_PREFIX.min(artifact.sha256.len())]
    );
    for field in [&artifact.version, &artifact.sha256, &name] {
        if field.is_empty()
            || !field
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
        {
            return Err(LaunchError::Protocol(format!(
                "invalid artifact field {field:?}"
            )));
        }
    }
    writeln!(
        input,
        "{} {} {} {name}",
        artifact.version,
        artifact.sha256,
        binary.len()
    )
    .and_then(|()| input.flush())
    .map_err(LaunchError::Io)?;

    let answer = read_line(output, NOISE_LIMIT)?.ok_or(LaunchError::NoShell)?;
    let answer = String::from_utf8_lossy(&answer).trim_end().to_owned();
    let uploaded = match answer.as_str() {
        INSTALL_PRESENT => false,
        INSTALL_NEEDED => {
            input
                .write_all(&binary)
                .and_then(|()| input.flush())
                .map_err(LaunchError::Io)?;
            true
        }
        other => return Err(LaunchError::Protocol(other.to_owned())),
    };
    Ok(Launched { report, uploaded })
}

/// Reads up to a newline. `None` at end of stream before any byte.
fn read_line(output: &mut impl Read, limit: usize) -> Result<Option<Vec<u8>>, LaunchError> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match output.read(&mut byte) {
            Ok(0) if line.is_empty() => return Ok(None),
            Ok(0) => return Ok(Some(line)),
            Ok(_) if byte[0] == b'\n' => return Ok(Some(line)),
            Ok(_) => {
                if line.len() >= limit {
                    return Err(LaunchError::Protocol(
                        "too much output before the server".into(),
                    ));
                }
                line.push(byte[0]);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(LaunchError::Io(error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The script crosses SSH hops through the transport's quoting, which
    // rejects these characters instead of escaping them.
    #[test]
    fn the_script_can_cross_an_ssh_hop() {
        assert!(!LAUNCH_SCRIPT
            .chars()
            .any(|character| matches!(character, '\'' | '\\' | '!') || character.is_control()));
        let chain = crate::TransportChain::new(vec![crate::Hop::Ssh(crate::SshHop::new("box"))]);
        chain.command(&launch_command(None, &["--stdio"])).unwrap();
    }
}
