//! Linux host adapter, used for SSH hosts and containers.

use super::unix;
use lithe_remote_protocol::methods::{OperatingSystem, OrphanProtection};
use std::io;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub(crate) const OPERATING_SYSTEM: OperatingSystem = OperatingSystem::Linux;
pub(crate) const ORPHAN_PROTECTION: OrphanProtection = OrphanProtection::ParentDeathSignal;

/// Configures a child to lead its own process group and to be killed by the
/// kernel if the server dies.
///
/// `PR_SET_PDEATHSIG` fires when the *thread* that forked the child exits,
/// not the process, which is why the dispatcher spawns from its own
/// long-lived thread.
pub(crate) fn prepare_child(command: &mut Command) {
    // SAFETY: getpid has no preconditions.
    let server = unsafe { libc::getpid() };
    // SAFETY: the closure only calls async-signal-safe functions, as required
    // between fork and exec.
    unsafe {
        command.pre_exec(move || {
            unix::start_new_session()?;
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == -1 {
                return Err(io::Error::last_os_error());
            }
            // The signal is not delivered retroactively: if the server died
            // before prctl, the child has already been re-parented.
            if libc::getppid() != server {
                libc::_exit(1);
            }
            Ok(())
        });
    }
}

/// Atomic rename that fails when `to` exists. `renameat2` is called through
/// `syscall` because musl and older glibc builds may lack the wrapper.
pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    let from_c = unix::c_path(from)?;
    let to_c = unix::c_path(to)?;
    // SAFETY: both pointers reference NUL-terminated strings that outlive the
    // call; the remaining arguments are plain integers.
    let status = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            from_c.as_ptr(),
            libc::AT_FDCWD,
            to_c.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if status == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        // Kernels before 3.15 lack the call; some filesystems reject the flag.
        Some(libc::ENOSYS) | Some(libc::EINVAL) => unix::rename_if_absent(from, to),
        _ => Err(error),
    }
}

pub(crate) fn case_sensitive(path: &Path) -> Option<bool> {
    unix::probe_case_sensitivity(path)
}
