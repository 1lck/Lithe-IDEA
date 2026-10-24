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
use linux as host;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as host;

pub(crate) use host::{case_sensitive, prepare_child, rename_no_replace};
pub(crate) use unix::signal_process_group;

use lithe_remote_protocol::methods::{Feature, HostCapabilities, ProcessCapabilities};

pub(crate) fn host_capabilities() -> HostCapabilities {
    let account = unix::current_account();
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
        features: vec![Feature::Filesystem, Feature::Process],
    }
}
