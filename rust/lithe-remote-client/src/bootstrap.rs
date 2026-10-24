//! Installing `lithe-remote-server` at the end of a transport chain.
//!
//! The client always uploads the server itself instead of letting the remote
//! download it, because many SSH hosts and containers have no internet access.
//! The upload goes through the same chain as the session, so it works for
//! every kind of hop without extra file-transfer tooling.
//!
//! Installed binaries are reused only when they report the exact SHA-256 of
//! the artifact this client ships. Each version lives in its own directory, so
//! clients of different releases can share a host.

use crate::command::{self, CommandOutput};
use crate::transport::{TransportChain, TransportError};
use lithe_remote_protocol::methods::ServerIdentity;
use lithe_remote_protocol::PROTOCOL_VERSION;
use sha2::{Digest, Sha256};
use std::fmt;
use std::fs::File;
use std::io;
use std::path::PathBuf;
use std::time::Duration;

const PROBE_BEGIN: &str = "LITHE-PROBE-BEGIN";
const PROBE_END: &str = "LITHE-PROBE-END";

/// Reports system, machine and home directory between markers, so output
/// from the remote user's shell startup files is ignored.
const PROBE_SCRIPT: &str =
    "echo LITHE-PROBE-BEGIN; uname -s; uname -m; echo \"$HOME\"; echo LITHE-PROBE-END";

/// Receives the binary on standard input. It is written under a temporary
/// name and renamed into place, so a broken upload never leaves a truncated
/// executable that a later identity check could run. `umask 077` keeps other
/// users on a shared host from replacing it.
const INSTALL_SCRIPT: &str = "umask 077 && mkdir -p \"$1\" && cat > \"$1/.upload.$$\" && chmod 700 \"$1/.upload.$$\" && mv -f \"$1/.upload.$$\" \"$1/lithe-remote-server\"";

/// Runs the binary passed as `$0` with `--identity`.
const IDENTITY_SCRIPT: &str = "exec \"$0\" --identity";

pub const SERVER_EXECUTABLE: &str = "lithe-remote-server";

/// Hex digits of the SHA-256 used in the install directory name. Sixteen
/// keep paths short while making accidental collisions between builds of the
/// same version practically impossible; the full hash is still verified.
const INSTALL_HASH_PREFIX: usize = 16;

/// Server build target selected from the remote's `uname` output.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum ServerTarget {
    LinuxX86_64,
    LinuxAarch64,
    MacosX86_64,
    MacosAarch64,
}

impl ServerTarget {
    /// Rust target triple the artifact is built for. Linux uses musl so one
    /// static binary runs on glibc and musl distributions alike.
    pub fn rust_target(self) -> &'static str {
        match self {
            Self::LinuxX86_64 => "x86_64-unknown-linux-musl",
            Self::LinuxAarch64 => "aarch64-unknown-linux-musl",
            Self::MacosX86_64 => "x86_64-apple-darwin",
            Self::MacosAarch64 => "aarch64-apple-darwin",
        }
    }

    /// Maps `uname -s` and `uname -m`. Architecture comes from the remote,
    /// not the local machine: an amd64 container on an Apple silicon Mac
    /// needs the x86_64 server.
    pub fn from_uname(system: &str, machine: &str) -> Option<Self> {
        let arm = matches!(machine, "aarch64" | "arm64" | "aarch64_be");
        let intel = matches!(machine, "x86_64" | "amd64");
        match system {
            "Linux" if intel => Some(Self::LinuxX86_64),
            "Linux" if arm => Some(Self::LinuxAarch64),
            "Darwin" if intel => Some(Self::MacosX86_64),
            "Darwin" if arm => Some(Self::MacosAarch64),
            _ => None,
        }
    }
}

/// A server binary available on the local machine.
#[derive(Clone, Debug)]
pub struct ServerArtifact {
    pub target: ServerTarget,
    pub path: PathBuf,
    pub version: String,
    pub sha256: String,
}

impl ServerArtifact {
    /// Describes a binary on disk, hashing it.
    pub fn from_file(
        target: ServerTarget,
        path: PathBuf,
        version: impl Into<String>,
    ) -> io::Result<Self> {
        let mut hasher = Sha256::new();
        io::copy(&mut File::open(&path)?, &mut hasher)?;
        Ok(Self {
            target,
            path,
            version: version.into(),
            sha256: hasher
                .finalize()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
        })
    }
}

/// Where the server is installed on the remote.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InstallLocation {
    /// `$HOME/.lithe-server`, the default.
    Home,
    /// An explicit private directory, for hosts with a read-only home or for
    /// tests. It must not be writable by other users.
    Directory(String),
}

/// Result of probing the end of a chain.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostProbe {
    pub target: ServerTarget,
    pub home: Option<String>,
}

/// An installed, verified server.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstalledServer {
    /// Absolute path of the executable on the remote.
    pub path: String,
    pub target: ServerTarget,
    /// Whether this call uploaded it.
    pub uploaded: bool,
}

impl InstalledServer {
    /// Command line of a session that ends with the connection.
    pub fn stdio_command(&self) -> Vec<String> {
        vec![self.path.clone(), "--stdio".into()]
    }

    /// Command line of the persistent session `key`, which survives a
    /// dropped connection. `key` must be 1–64 characters from
    /// `[A-Za-z0-9._-]`, for example a hash of the workspace path.
    pub fn connect_command(&self, key: &str) -> Vec<String> {
        vec![self.path.clone(), "--connect".into(), key.into()]
    }
}

#[derive(Debug)]
pub enum BootstrapError {
    Transport(TransportError),
    /// A local command could not run or exceeded its deadline.
    Command(io::Error),
    /// The chain did not reach a POSIX shell. `stderr` usually explains why,
    /// for example an SSH authentication failure.
    ProbeFailed {
        stderr: String,
    },
    UnsupportedPlatform {
        system: String,
        machine: String,
    },
    /// This client ships no server for the remote's platform.
    NoArtifact(ServerTarget),
    /// The remote reported no home directory and no explicit location was set.
    NoInstallLocation,
    InstallFailed {
        stderr: String,
    },
    /// The installed binary did not report the uploaded artifact's identity.
    VerificationFailed {
        expected: String,
        found: Option<String>,
    },
}

impl fmt::Display for BootstrapError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport(error) => error.fmt(formatter),
            Self::Command(error) => write!(formatter, "connection command failed: {error}"),
            Self::ProbeFailed { stderr } => {
                write!(formatter, "cannot reach a shell on the remote: {stderr}")
            }
            Self::UnsupportedPlatform { system, machine } => {
                write!(
                    formatter,
                    "remote platform {system} {machine} is not supported"
                )
            }
            Self::NoArtifact(target) => write!(
                formatter,
                "no remote server is available for {}",
                target.rust_target()
            ),
            Self::NoInstallLocation => formatter.write_str("the remote user has no home directory"),
            Self::InstallFailed { stderr } => {
                write!(formatter, "installing the remote server failed: {stderr}")
            }
            Self::VerificationFailed { expected, found } => write!(
                formatter,
                "installed remote server reports {} instead of {expected}",
                found.as_deref().unwrap_or("no identity")
            ),
        }
    }
}

impl std::error::Error for BootstrapError {}

impl From<TransportError> for BootstrapError {
    fn from(error: TransportError) -> Self {
        Self::Transport(error)
    }
}

/// Probes the end of a chain and installs the server there.
pub struct Bootstrapper {
    pub chain: TransportChain,
    pub location: InstallLocation,
    /// Deadline for each probe or identity command.
    pub command_timeout: Duration,
    /// Deadline for the upload, which moves several megabytes.
    pub upload_timeout: Duration,
}

impl Bootstrapper {
    pub fn new(chain: TransportChain) -> Self {
        Self {
            chain,
            location: InstallLocation::Home,
            command_timeout: Duration::from_secs(30),
            upload_timeout: Duration::from_secs(300),
        }
    }

    pub fn probe(&self) -> Result<HostProbe, BootstrapError> {
        let output = self.run(&["sh", "-c", PROBE_SCRIPT], None, self.command_timeout)?;
        let Some(lines) = probe_lines(&output.stdout) else {
            return Err(BootstrapError::ProbeFailed {
                stderr: output.stderr_text(),
            });
        };
        let [system, machine, home] = lines.as_slice() else {
            return Err(BootstrapError::ProbeFailed {
                stderr: output.stderr_text(),
            });
        };
        let target = ServerTarget::from_uname(system, machine).ok_or_else(|| {
            BootstrapError::UnsupportedPlatform {
                system: system.clone(),
                machine: machine.clone(),
            }
        })?;
        Ok(HostProbe {
            target,
            home: Some(home.clone()).filter(|home| home.starts_with('/')),
        })
    }

    /// Returns a verified server, uploading `artifact_for(target)` when the
    /// remote has no binary with the same identity.
    pub fn ensure_installed(
        &self,
        artifact_for: impl Fn(ServerTarget) -> Option<ServerArtifact>,
    ) -> Result<InstalledServer, BootstrapError> {
        let probe = self.probe()?;
        let artifact =
            artifact_for(probe.target).ok_or(BootstrapError::NoArtifact(probe.target))?;
        let root = match &self.location {
            InstallLocation::Directory(directory) => directory.trim_end_matches('/').to_owned(),
            InstallLocation::Home => format!(
                "{}/.lithe-server",
                probe
                    .home
                    .as_deref()
                    .ok_or(BootstrapError::NoInstallLocation)?
                    .trim_end_matches('/')
            ),
        };
        let directory = format!(
            "{root}/bin/{}-{}",
            artifact.version,
            &artifact.sha256[..INSTALL_HASH_PREFIX.min(artifact.sha256.len())]
        );
        let path = format!("{directory}/{SERVER_EXECUTABLE}");
        let installed = |uploaded| InstalledServer {
            path: path.clone(),
            target: probe.target,
            uploaded,
        };

        if self.identity(&path)?.as_deref() == Some(artifact.sha256.as_str()) {
            return Ok(installed(false));
        }
        let binary = std::fs::read(&artifact.path).map_err(BootstrapError::Command)?;
        let output = self.run(
            &["sh", "-c", INSTALL_SCRIPT, "sh", &directory],
            Some(&binary),
            self.upload_timeout,
        )?;
        if !output.success() {
            return Err(BootstrapError::InstallFailed {
                stderr: output.stderr_text(),
            });
        }
        match self.identity(&path)? {
            Some(found) if found == artifact.sha256 => Ok(installed(true)),
            found => Err(BootstrapError::VerificationFailed {
                expected: artifact.sha256,
                found,
            }),
        }
    }

    /// SHA-256 reported by the binary at `path`, or `None` when it is absent,
    /// does not run, or speaks another protocol version.
    fn identity(&self, path: &str) -> Result<Option<String>, BootstrapError> {
        // Run through `sh` so that a missing binary is an ordinary non-zero
        // exit on every chain, including the local one, where executing a
        // missing path directly would fail before any process starts.
        let output = self.run(
            &["sh", "-c", IDENTITY_SCRIPT, path],
            None,
            self.command_timeout,
        )?;
        if !output.success() {
            return Ok(None);
        }
        let text = String::from_utf8_lossy(&output.stdout);
        Ok(text
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<ServerIdentity>(line).ok())
            .filter(|identity| identity.protocol_version == PROTOCOL_VERSION)
            .map(|identity| identity.sha256))
    }

    fn run(
        &self,
        argv: &[&str],
        stdin: Option<&[u8]>,
        timeout: Duration,
    ) -> Result<CommandOutput, BootstrapError> {
        let argv: Vec<String> = argv.iter().map(|argument| argument.to_string()).collect();
        let command = self.chain.command(&argv)?;
        command::run(&command, stdin, timeout).map_err(BootstrapError::Command)
    }
}

fn probe_lines(stdout: &[u8]) -> Option<Vec<String>> {
    let text = String::from_utf8_lossy(stdout);
    let mut lines = text.lines().map(str::trim_end);
    lines.by_ref().find(|line| *line == PROBE_BEGIN)?;
    let mut collected = Vec::new();
    for line in lines {
        if line == PROBE_END {
            return Some(collected);
        }
        collected.push(line.to_owned());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uname_values_map_to_server_targets() {
        assert_eq!(
            ServerTarget::from_uname("Linux", "x86_64"),
            Some(ServerTarget::LinuxX86_64)
        );
        assert_eq!(
            ServerTarget::from_uname("Linux", "aarch64"),
            Some(ServerTarget::LinuxAarch64)
        );
        assert_eq!(
            ServerTarget::from_uname("Darwin", "arm64"),
            Some(ServerTarget::MacosAarch64)
        );
        assert_eq!(
            ServerTarget::from_uname("Darwin", "x86_64"),
            Some(ServerTarget::MacosX86_64)
        );
        assert_eq!(ServerTarget::from_uname("Linux", "armv7l"), None);
        assert_eq!(ServerTarget::from_uname("FreeBSD", "amd64"), None);
    }

    // Shell startup files may print before and after the probe; only the
    // marked block is trusted.
    #[test]
    fn probe_output_is_read_between_markers() {
        let stdout =
            b"Welcome!\nLITHE-PROBE-BEGIN\nLinux\nx86_64\n/home/dev\nLITHE-PROBE-END\nbye\n";
        assert_eq!(
            probe_lines(stdout).unwrap(),
            vec!["Linux".to_string(), "x86_64".into(), "/home/dev".into()]
        );
        assert_eq!(probe_lines(b"LITHE-PROBE-BEGIN\nLinux\n"), None);
        assert_eq!(probe_lines(b"Permission denied\n"), None);
    }
}
