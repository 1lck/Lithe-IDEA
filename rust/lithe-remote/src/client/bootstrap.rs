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

use crate::client::command::{self, CommandOutput};
use crate::client::transport::{TransportChain, TransportError};
use crate::protocol::methods::ServerIdentity;
use crate::protocol::PROTOCOL_VERSION;
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
const PROBE_SCRIPT: &str = concat!(
    host_details_script!(),
    "echo LITHE-PROBE-BEGIN; uname -s; uname -m; echo \"$HOME\"; echo LITHE-PROBE-END"
);

/// Reports facts shown to the user as `key=value` lines between markers.
/// Every command is optional: a missing tool leaves its line empty. Raw
/// command output is parsed here rather than on the host, because the
/// script must avoid the characters that cannot cross an SSH hop.
macro_rules! host_details_script {
    () => {
        concat!(
            "echo LITHE-DETAILS-BEGIN; ",
            "echo \"hostName=$(uname -n)\"; echo \"kernel=$(uname -r)\"; ",
            "if [ -r /etc/os-release ]; then ( . /etc/os-release; echo \"operatingSystem=$PRETTY_NAME\" ); ",
            "elif command -v sw_vers >/dev/null 2>&1; then echo \"operatingSystem=macOS $(sw_vers -productVersion)\"; fi; ",
            "echo \"cpuCount=$(getconf _NPROCESSORS_ONLN 2>/dev/null)\"; ",
            "if [ -r /proc/meminfo ]; then echo \"memInfo=$(grep MemTotal /proc/meminfo)\"; ",
            "else echo \"memoryBytes=$(sysctl -n hw.memsize 2>/dev/null)\"; fi; ",
            "echo \"disk=$(df -Pk \"$HOME\" 2>/dev/null | tail -n 1)\"; ",
            "if [ -r /proc/uptime ]; then echo \"uptime=$(cat /proc/uptime)\"; fi; ",
            "echo LITHE-DETAILS-END; "
        )
    };
}
pub(crate) use host_details_script;

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
pub(crate) const INSTALL_HASH_PREFIX: usize = 16;

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
        let argv = probe_command();
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let output = self.run(&argv, None, self.command_timeout)?;
        let Some(report) = parse_probe(&output.stdout) else {
            return Err(BootstrapError::ProbeFailed {
                stderr: output.stderr_text(),
            });
        };
        let target = report
            .target()
            .ok_or_else(|| BootstrapError::UnsupportedPlatform {
                system: report.system.clone(),
                machine: report.machine.clone(),
            })?;
        Ok(HostProbe {
            target,
            home: report.home,
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

/// What the probe reported about the end of a chain.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProbeReport {
    /// `uname -s`, for example `Linux` or `Darwin`.
    pub system: String,
    /// `uname -m`, for example `x86_64` or `arm64`.
    pub machine: String,
    /// `$HOME` when it is an absolute path.
    pub home: Option<String>,
    pub details: HostDetails,
}

/// Facts about the host for display; each is `None` when it could not be read.
#[derive(Clone, Debug, Default, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostDetails {
    /// `uname -n`.
    pub host_name: Option<String>,
    /// For example `Ubuntu 22.04.4 LTS` or `macOS 15.1`.
    pub operating_system: Option<String>,
    /// `uname -r`.
    pub kernel: Option<String>,
    pub cpu_count: Option<u32>,
    pub memory_bytes: Option<u64>,
    /// Size of the file system holding the home directory.
    pub disk_total_bytes: Option<u64>,
    pub disk_available_bytes: Option<u64>,
    pub uptime_seconds: Option<u64>,
}

/// Reads the details block; missing or malformed lines leave fields unset.
fn parse_details(text: &str) -> HostDetails {
    let mut details = HostDetails::default();
    let mut lines = text.lines().map(str::trim_end);
    if lines
        .by_ref()
        .find(|line| *line == "LITHE-DETAILS-BEGIN")
        .is_none()
    {
        return details;
    }
    let present = |value: &str| Some(value.trim().to_owned()).filter(|value| !value.is_empty());
    for line in lines {
        if line == "LITHE-DETAILS-END" {
            break;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "hostName" => details.host_name = present(value),
            "kernel" => details.kernel = present(value),
            "operatingSystem" => details.operating_system = present(value),
            "cpuCount" => details.cpu_count = value.trim().parse().ok(),
            "memoryBytes" => details.memory_bytes = value.trim().parse().ok(),
            // `MemTotal:       16303780 kB`
            "memInfo" => {
                details.memory_bytes = value
                    .split_whitespace()
                    .nth(1)
                    .and_then(|kilobytes| kilobytes.parse::<u64>().ok())
                    .map(|kilobytes| kilobytes * 1024)
            }
            // `df -Pk`: file system, 1024-blocks, used, available, capacity, mount.
            "disk" => {
                let fields: Vec<&str> = value.split_whitespace().collect();
                if fields.len() >= 6 {
                    let kilobytes =
                        |index: usize| fields[index].parse::<u64>().ok().map(|value| value * 1024);
                    details.disk_total_bytes = kilobytes(1);
                    details.disk_available_bytes = kilobytes(3);
                }
            }
            // `/proc/uptime`: seconds since boot, then idle seconds.
            "uptime" => {
                details.uptime_seconds = value
                    .split_whitespace()
                    .next()
                    .and_then(|seconds| seconds.parse::<f64>().ok())
                    .map(|seconds| seconds as u64)
            }
            _ => {}
        }
    }
    details
}

impl ProbeReport {
    /// Server build for this platform, or `None` when none is shipped.
    pub fn target(&self) -> Option<ServerTarget> {
        ServerTarget::from_uname(&self.system, &self.machine)
    }
}

/// Command that reports the remote platform. Callers that run it with their
/// own process handling, for example to answer SSH prompts, pass it to
/// [`TransportChain::command`] and read the output with [`parse_probe`].
pub fn probe_command() -> Vec<String> {
    vec!["sh".into(), "-c".into(), PROBE_SCRIPT.into()]
}

/// Reads the output of [`probe_command`]; `None` when the marked block is
/// missing or incomplete, for example because the shell never ran.
pub fn parse_probe(stdout: &[u8]) -> Option<ProbeReport> {
    let lines = probe_lines(stdout)?;
    let [system, machine, home] = lines.as_slice() else {
        return None;
    };
    Some(ProbeReport {
        system: system.clone(),
        machine: machine.clone(),
        home: Some(home.clone()).filter(|home| home.starts_with('/')),
        details: parse_details(&String::from_utf8_lossy(stdout)),
    })
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
    fn host_details_are_read_from_raw_command_output() {
        let stdout = b"LITHE-DETAILS-BEGIN\nhostName=devbox\nkernel=6.8.0-45-generic\n\
operatingSystem=Ubuntu 22.04.4 LTS\ncpuCount=4\nmemInfo=MemTotal:       16303780 kB\n\
disk=/dev/vda1 82045336 23412820 55282748 30% /\nuptime=93784.52 351234.11\nLITHE-DETAILS-END\n\
LITHE-PROBE-BEGIN\nLinux\nx86_64\n/root\nLITHE-PROBE-END\n";
        let details = parse_probe(stdout).unwrap().details;
        assert_eq!(
            details,
            HostDetails {
                host_name: Some("devbox".into()),
                operating_system: Some("Ubuntu 22.04.4 LTS".into()),
                kernel: Some("6.8.0-45-generic".into()),
                cpu_count: Some(4),
                memory_bytes: Some(16_303_780 * 1024),
                disk_total_bytes: Some(82_045_336 * 1024),
                disk_available_bytes: Some(55_282_748 * 1024),
                uptime_seconds: Some(93_784),
            }
        );
        // macOS reports memory directly and has no /proc; empty values stay unset.
        let mac = parse_details(
            "LITHE-DETAILS-BEGIN\nmemoryBytes=17179869184\ncpuCount=\nLITHE-DETAILS-END\n",
        );
        assert_eq!(mac.memory_bytes, Some(17_179_869_184));
        assert_eq!(mac.cpu_count, None);
    }

    // The probe crosses SSH hops through the transport's quoting, which
    // rejects these characters instead of escaping them.
    #[test]
    fn the_probe_can_cross_an_ssh_hop() {
        assert!(!PROBE_SCRIPT
            .chars()
            .any(|character| matches!(character, '\'' | '\\' | '!') || character.is_control()));
    }

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
        assert_eq!(
            parse_probe(stdout).unwrap(),
            ProbeReport {
                system: "Linux".into(),
                machine: "x86_64".into(),
                home: Some("/home/dev".into()),
                details: HostDetails::default(),
            }
        );
        // A relative or empty `$HOME` is not a usable install location.
        assert_eq!(
            parse_probe(b"LITHE-PROBE-BEGIN\nLinux\nx86_64\n\nLITHE-PROBE-END\n")
                .unwrap()
                .home,
            None
        );
    }
}
