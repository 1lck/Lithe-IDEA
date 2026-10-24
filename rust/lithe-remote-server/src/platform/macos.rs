//! macOS host adapter, used for remote Macs reached over SSH.

use super::unix;
use lithe_remote_protocol::methods::{OperatingSystem, OrphanProtection};
use std::io;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub(crate) const OPERATING_SYSTEM: OperatingSystem = OperatingSystem::Macos;

/// macOS has no parent-death signal. Process groups are terminated when the
/// server shuts down or loses its client; a kqueue-based supervisor that also
/// covers a killed server is planned with session persistence.
pub(crate) const ORPHAN_PROTECTION: OrphanProtection = OrphanProtection::ServerShutdown;

pub(crate) fn prepare_child(command: &mut Command) {
    // SAFETY: the closure only calls setsid, which is async-signal-safe.
    unsafe {
        command.pre_exec(unix::start_new_session);
    }
}

pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    let from_c = unix::c_path(from)?;
    let to_c = unix::c_path(to)?;
    // SAFETY: both pointers reference NUL-terminated strings that outlive the
    // call.
    let status = unsafe { libc::renamex_np(from_c.as_ptr(), to_c.as_ptr(), libc::RENAME_EXCL) };
    if status == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        // Volumes such as SMB or FAT mounts may not support RENAME_EXCL.
        Some(libc::ENOTSUP) | Some(libc::EINVAL) => unix::rename_if_absent(from, to),
        _ => Err(error),
    }
}

/// APFS and HFS+ volumes are case-insensitive by default but can be
/// formatted case-sensitive, so the answer is per volume.
pub(crate) fn case_sensitive(path: &Path) -> Option<bool> {
    let Ok(c_path) = unix::c_path(path) else {
        return None;
    };
    // SAFETY: the pointer references a NUL-terminated string that outlives
    // the call.
    match unsafe { libc::pathconf(c_path.as_ptr(), libc::_PC_CASE_SENSITIVE) } {
        1 => Some(true),
        0 => Some(false),
        _ => unix::probe_case_sensitivity(path),
    }
}
