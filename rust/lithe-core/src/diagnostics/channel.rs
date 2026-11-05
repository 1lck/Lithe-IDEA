//! Validates logical log channels and derives paths inside host-owned writable log roots.

use chrono::{DateTime, NaiveDateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

/// Maximum distinct persisted channels in one session, excluding the overflow sink.
pub const MAX_SESSION_CHANNELS: usize = 128;
/// Fixed routing roots shared by both native hosts.
pub const CHANNEL_ROOTS: [&str; 12] = [
    "app", "editor", "perf", "lsp", "vcs", "run", "debug", "terminal", "remote", "agent", "update",
    "plugins",
];

/// Closed routing domains; hosts may specialize a domain only with validated segments.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChannelRoot {
    /// Application lifecycle.
    App,
    /// Editor operations.
    Editor,
    /// Performance evidence with a separate disk budget.
    Perf,
    /// Language-server operations.
    Lsp,
    /// Version-control operations.
    Vcs,
    /// Run lifecycle.
    Run,
    /// Debug lifecycle.
    Debug,
    /// Terminal lifecycle.
    Terminal,
    /// Remote connection lifecycle.
    Remote,
    /// Agent lifecycle.
    Agent,
    /// Application updates.
    Update,
    /// Plugin lifecycle and native host evidence.
    Plugins,
}

impl ChannelRoot {
    /// Parses an exact lowercase root; unrecognized domains return -32031.
    pub fn parse(value: &str) -> Result<Self, LogError> {
        match value {
            "app" => Ok(Self::App),
            "editor" => Ok(Self::Editor),
            "perf" => Ok(Self::Perf),
            "lsp" => Ok(Self::Lsp),
            "vcs" => Ok(Self::Vcs),
            "run" => Ok(Self::Run),
            "debug" => Ok(Self::Debug),
            "terminal" => Ok(Self::Terminal),
            "remote" => Ok(Self::Remote),
            "agent" => Ok(Self::Agent),
            "update" => Ok(Self::Update),
            "plugins" => Ok(Self::Plugins),
            _ => Err(LogError::new(-32031, "Unknown channel root")),
        }
    }
}

/// Maps every structured root into the existing product's six log categories.
pub fn log_category(channel: &str) -> &'static str {
    match channel.split('/').next().unwrap_or("") {
        "editor" | "lsp" => "language",
        "vcs" => "git",
        "perf" => "performance",
        "run" | "debug" | "terminal" => "run",
        "plugins" => "plugins",
        _ => "application",
    }
}

/// Owned domain failure. Numeric codes have one documented meaning across hosts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogError {
    /// Stable logging-v2 error code; see the shared Core contract.
    pub code: i32,
    /// Safe parser explanation without echoing untrusted input or credentials.
    pub reason: String,
}

impl LogError {
    pub(crate) fn new(code: i32, reason: &str) -> Self {
        Self {
            code,
            reason: reason.into(),
        }
    }
}

/// Validated owned channel. Construction prevents traversal and arbitrary subdirectories.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogChannel(String);

impl LogChannel {
    /// Parses a fixed root, non-plugin root/segment, or plugins/plugin-id/host channel.
    pub fn parse(value: &str) -> Result<Self, LogError> {
        let parts: Vec<_> = value.split('/').collect();
        ChannelRoot::parse(parts[0])?;
        if !(parts.len() == 1
            || (parts.len() == 2 && parts[0] != "plugins")
            || (parts.len() == 3 && parts[0] == "plugins" && parts[2] == "host"))
        {
            return Err(LogError::new(-32032, "Unsupported channel shape"));
        }
        for part in &parts[1..] {
            validate_segment(part)?;
        }
        Ok(Self(value.into()))
    }

    /// Borrows the canonical channel without allocating a second identity.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Rejects traversal, noncanonical characters, and names that alias Windows device paths.
pub fn validate_segment(value: &str) -> Result<(), LogError> {
    let valid = !value.is_empty()
        && value.len() <= 64
        && (value.as_bytes()[0].is_ascii_lowercase() || value.as_bytes()[0].is_ascii_digit())
        && value
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || b"._-".contains(&c));
    // Win32 strips trailing dots and reserves device basenames even with an extension.
    // Reject them on every host so the same identity always names the same file.
    let basename = value.split('.').next().unwrap_or("");
    let device = matches!(basename, "con" | "prn" | "aux" | "nul")
        || (basename.len() == 4
            && (basename.starts_with("com") || basename.starts_with("lpt"))
            && matches!(basename.as_bytes()[3], b'1'..=b'9'));
    if !valid || value.ends_with('.') || device {
        return Err(LogError::new(-32033, "Invalid channel segment"));
    }
    Ok(())
}

/// Maps an installed identity to its channel segment. A valid identity stays readable;
/// anything else becomes a stable digest, so evidence is kept and raw input never
/// reaches a path. Every writer of one plugin's channel must use this mapping.
pub fn identity_segment(raw: &str) -> String {
    if validate_segment(raw).is_ok() {
        raw.to_owned()
    } else {
        digest_segment(raw)
    }
}

/// Stable `invalid-` plus 32 hex digits, always a valid segment and never raw input.
pub fn digest_segment(raw: &str) -> String {
    format!("invalid-{:x}", Sha256::digest(raw.as_bytes()))[..40].to_owned()
}

/// Returns a slash-separated file path relative to the writable session directory.
/// Index zero is active; positive indices produce numbered rotation siblings.
pub fn relative_log_path(channel: &LogChannel, rotation_index: u32) -> String {
    log_path(channel.as_str(), rotation_index)
}

fn log_path(channel: &str, rotation_index: u32) -> String {
    if rotation_index == 0 {
        format!("{channel}.log")
    } else {
        // `~` cannot occur in a channel, keeping rotations disjoint from active files.
        format!("{channel}~{rotation_index}.log")
    }
}

/// Returns the plugin-owned files directory relative to a writable session, with a trailing slash.
/// Native adapters own its contents and must never resolve it inside an installation bundle.
pub fn plugin_files_path(plugin_id: &str) -> Result<String, LogError> {
    validate_segment(plugin_id)?;
    Ok(format!("plugins/{plugin_id}/files/"))
}

/// Resolves a new channel against an existing set without mutating that set.
/// Existing channels keep their paths even after the 128-channel budget is reached.
pub fn bounded_log_path(
    channel: &LogChannel,
    existing: &BTreeSet<String>,
    rotation_index: u32,
) -> String {
    if existing.len() >= MAX_SESSION_CHANNELS && !existing.contains(channel.as_str()) {
        log_path("_overflow", rotation_index)
    } else {
        relative_log_path(channel, rotation_index)
    }
}

pub(crate) fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

/// Parsed session directory identity; the UUID suffix is only a display prefix, not a full UUID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDirectory {
    /// UTC start time normalized to RFC3339 seconds.
    pub started: String,
    /// Eight lowercase hexadecimal UUID characters.
    pub uuid_prefix: String,
}

/// Generates a session name from caller-owned UTC time and a full UUID, without reading a clock.
pub fn session_directory_name(started: &str, session_uuid: &str) -> Result<String, LogError> {
    if !valid_uuid(session_uuid) {
        return Err(LogError::new(-32034, "Invalid session UUID"));
    }
    let time = DateTime::parse_from_rfc3339(started)
        .map_err(|_| LogError::new(-32035, "Invalid timestamp"))?
        .with_timezone(&Utc);
    let stamp = time.format("%Y-%m-%dT%H-%M-%S").to_string();
    let name = format!("{stamp}_{}", session_uuid[..8].to_ascii_lowercase());
    parse_session_directory_name(&name)?;
    Ok(name)
}

/// Parses only canonical session directory names, rejecting extra path components.
pub fn parse_session_directory_name(name: &str) -> Result<SessionDirectory, LogError> {
    let error = || LogError::new(-32036, "Invalid session directory name");
    let (stamp, prefix) = name.split_once('_').ok_or_else(error)?;
    if stamp.len() != 19
        || prefix.len() != 8
        || !prefix
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(error());
    }
    let time = NaiveDateTime::parse_from_str(stamp, "%Y-%m-%dT%H-%M-%S").map_err(|_| error())?;
    if time.format("%Y-%m-%dT%H-%M-%S").to_string() != stamp {
        return Err(error());
    }
    Ok(SessionDirectory {
        started: time
            .and_utc()
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        uuid_prefix: prefix.into(),
    })
}

/// Returns a path relative to the host-provided writable log root.
/// Sessions and all child logs live outside installed application resources.
pub fn session_relative_path(started: &str, session_uuid: &str) -> Result<String, LogError> {
    Ok(format!(
        "sessions/{}",
        session_directory_name(started, session_uuid)?
    ))
}

/// Owned JSON request for channel resolution and optional session channel accounting.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveLogChannelRequest {
    /// Logical channel; never an arbitrary filesystem path.
    pub channel: String,
    /// Zero for the active file.
    #[serde(default)]
    pub rotation_index: u32,
    /// Already admitted channel identities for this session.
    #[serde(default)]
    pub existing_channels: BTreeSet<String>,
}

/// Resolved owned path, suitable for joining only to a host-owned writable session directory.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedLogChannel {
    /// Existing product category shared by filtering and verbose diagnostic admission.
    pub category: String,
    /// Plugin-owned files sibling resolved by the same validated identity rule.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_files_path: Option<String>,
    /// Session-relative file destination, possibly the overflow sink.
    pub relative_path: String,
}

/// Validates every supplied identity before resolving the bounded channel destination.
pub fn resolve_log_channel(
    request: ResolveLogChannelRequest,
) -> Result<ResolvedLogChannel, LogError> {
    let channel = LogChannel::parse(&request.channel)?;
    for existing in &request.existing_channels {
        LogChannel::parse(existing)?;
    }
    let plugin_files_path = match channel.as_str().split('/').collect::<Vec<_>>().as_slice() {
        ["plugins", plugin, "host"] => Some(plugin_files_path(plugin)?),
        _ => None,
    };
    Ok(ResolvedLogChannel {
        category: log_category(channel.as_str()).into(),
        plugin_files_path,
        relative_path: bounded_log_path(
            &channel,
            &request.existing_channels,
            request.rotation_index,
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_paths_are_disjoint_from_rotations_and_safe_on_windows() {
        let base = LogChannel::parse("vcs/git").unwrap();
        let dotted = LogChannel::parse("vcs/git.1").unwrap();
        assert_ne!(relative_log_path(&base, 1), relative_log_path(&dotted, 0));
        assert_eq!(relative_log_path(&base, 1), "vcs/git~1.log");
        for segment in ["con", "aux", "nul.txt", "prn", "com1", "lpt9.log", "git."] {
            assert_eq!(validate_segment(segment).unwrap_err().code, -32033);
            assert!(plugin_files_path(segment).is_err());
        }
        for segment in ["console", "com0", "com10", "lpt0", "git.1"] {
            assert!(validate_segment(segment).is_ok());
        }
        assert_eq!(
            LogChannel::parse("plugins/example").unwrap_err().code,
            -32032
        );
        let existing = (0..128).map(|i| format!("vcs/git{i}")).collect();
        assert_eq!(bounded_log_path(&base, &existing, 2), "_overflow~2.log");
    }

    #[test]
    fn rotations_never_alias_legal_active_channels() {
        for name in ["foo", "foo.1", "foo.2", "foo.1.2"] {
            let channel = LogChannel::parse(&format!("lsp/{name}")).unwrap();
            for index in 1..=3 {
                let rotated = relative_log_path(&channel, index);
                assert_eq!(rotated, format!("lsp/{name}~{index}.log"));
                assert!(LogChannel::parse(rotated.strip_suffix(".log").unwrap()).is_err());
            }
        }
    }

    #[test]
    fn session_names_roundtrip_and_overflow_preserves_existing_channels() {
        let name = session_directory_name(
            "2026-11-03T10:00:00+02:00",
            "ABCDEF12-3456-7890-abcd-ef1234567890",
        )
        .unwrap();
        assert_eq!(name, "2026-11-03T08-00-00_abcdef12");
        assert_eq!(
            parse_session_directory_name(&name).unwrap().started,
            "2026-11-03T08:00:00Z"
        );
        assert!(parse_session_directory_name("2026-02-30T00-00-00_abcdef12").is_err());
        let existing = (0..128).map(|i| format!("vcs/git{i}")).collect();
        assert_eq!(
            bounded_log_path(&LogChannel::parse("app").unwrap(), &existing, 0),
            "_overflow.log"
        );
        assert_eq!(
            bounded_log_path(&LogChannel::parse("vcs/git0").unwrap(), &existing, 1),
            "vcs/git0~1.log"
        );
        assert_eq!(
            plugin_files_path("io.example.plugin").unwrap(),
            "plugins/io.example.plugin/files/"
        );
    }
}
