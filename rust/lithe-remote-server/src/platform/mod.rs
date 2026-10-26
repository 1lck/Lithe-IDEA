//! Host adapters.
//!
//! Every behavior that differs between Linux and macOS hosts is implemented
//! here and reported to clients as a capability. Code outside this module
//! must not test the target OS itself; it calls the functions re-exported
//! below, which each host module implements with the same signatures.

mod unix;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub(crate) mod linux_watch;
#[cfg(target_os = "linux")]
use linux as host;
#[cfg(target_os = "linux")]
pub(crate) use linux_watch as watcher;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub(crate) mod macos_watch;
#[cfg(target_os = "macos")]
use macos as host;
#[cfg(target_os = "macos")]
pub(crate) use macos_watch as watcher;

pub(crate) use host::{
    case_sensitive, listening_ports, peer_uid, prepare_child, rename_no_replace,
};
pub(crate) use unix::{
    collect_output, current_account, current_uid, live_sessions, open_pty, set_window_size,
    signal_process_group, signal_session,
};

use lithe_remote_protocol::methods::{
    Feature, HostCapabilities, ProcessCapabilities, WatchCapabilities,
};

/// How a child is attached to its parent's session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ChildKind {
    /// A new session and process group without a controlling terminal.
    Plain,
    /// A new session whose controlling terminal is the child's standard
    /// input, which must be a pseudo-terminal slave.
    Terminal,
}

pub(crate) fn host_capabilities() -> HostCapabilities {
    let account = unix::current_account();
    let mut features = vec![
        Feature::Filesystem,
        Feature::Upload,
        Feature::Walk,
        Feature::Watch,
        Feature::Process,
        Feature::Terminal,
        Feature::Environment,
        Feature::Tunnel,
        Feature::Persistence,
    ];
    features.sort();
    HostCapabilities {
        os: host::OPERATING_SYSTEM,
        arch: std::env::consts::ARCH.into(),
        host_name: unix::host_name(),
        user_name: account.user_name,
        home_directory: account.home_directory,
        default_shell: account.shell,
        path_separator: "/".into(),
        process: ProcessCapabilities {
            orphan_protection: host::ORPHAN_PROTECTION,
        },
        watch: WatchCapabilities {
            backend: watcher::BACKEND,
            directory_limit: watcher::directory_limit(),
        },
        features,
    }
}
