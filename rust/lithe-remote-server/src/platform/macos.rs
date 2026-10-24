//! macOS host adapter, used for remote Macs reached over SSH.

use super::{unix, ChildKind};
use lithe_remote_protocol::methods::{ListeningPort, OperatingSystem, OrphanProtection};
use std::io;
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

pub(crate) const OPERATING_SYSTEM: OperatingSystem = OperatingSystem::Macos;

/// macOS has no parent-death signal. Process groups are terminated when the
/// server shuts down or its session expires; a kqueue-based supervisor that
/// also covers a killed server is a later addition.
pub(crate) const ORPHAN_PROTECTION: OrphanProtection = OrphanProtection::ServerShutdown;

/// Bound for `lsof`, which inspects every open file of the user.
const LSOF_TIMEOUT: Duration = Duration::from_secs(5);

pub(crate) fn prepare_child(command: &mut Command, kind: ChildKind) {
    // SAFETY: the closure only calls setsid and ioctl, which are
    // async-signal-safe.
    unsafe {
        command.pre_exec(move || {
            unix::start_new_session()?;
            if kind == ChildKind::Terminal {
                unix::acquire_controlling_terminal()?;
            }
            Ok(())
        });
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

/// Processes whose session id is `session`. macOS has no `/proc`; the pid
/// list comes from libproc and each session id from `getsid`.
pub(crate) fn session_members(session: u32) -> Vec<u32> {
    // SAFETY: a null buffer asks for the number of pids.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Vec::new();
    }
    // Room for processes started between the two calls.
    let mut pids = vec![0 as libc::pid_t; count as usize + 64];
    let bytes = (pids.len() * std::mem::size_of::<libc::pid_t>()) as libc::c_int;
    // SAFETY: the buffer is writable for `bytes` bytes.
    let filled = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    if filled <= 0 {
        return Vec::new();
    }
    pids.truncate(filled as usize);
    pids.into_iter()
        .filter(|pid| *pid > 0)
        // SAFETY: getsid has no memory-safety preconditions.
        .filter(|pid| unsafe { libc::getsid(*pid) } == session as libc::pid_t)
        .map(|pid| pid as u32)
        .collect()
}

pub(crate) fn peer_uid(socket: RawFd) -> io::Result<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: the out-pointers reference live locals.
    if unsafe { libc::getpeereid(socket, &mut uid, &mut gid) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

/// Listening TCP sockets of the remote user's processes. macOS has no
/// `/proc`; `lsof` ships with the system and is the supported way to list
/// sockets without elevated rights.
pub(crate) fn listening_ports() -> io::Result<Vec<ListeningPort>> {
    let mut command = Command::new("lsof");
    command
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-Fn"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let child = command.spawn()?;
    let (status, stdout) = unix::collect_output(child, LSOF_TIMEOUT)?;
    // lsof exits with 1 when nothing matches, which is an empty list.
    if !status.success() && !stdout.is_empty() {
        return Err(io::Error::other(format!("lsof failed with {status}")));
    }
    Ok(parse_lsof(&String::from_utf8_lossy(&stdout)))
}

fn parse_lsof(output: &str) -> Vec<ListeningPort> {
    output
        .lines()
        .filter_map(|line| line.strip_prefix('n'))
        .filter_map(|name| {
            let (address, port) = name.rsplit_once(':')?;
            let address = address.trim_start_matches('[').trim_end_matches(']');
            Some(ListeningPort {
                address: if address == "*" {
                    "0.0.0.0".into()
                } else {
                    address.into()
                },
                port: port.parse().ok()?,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lsof_field_output_yields_addresses_and_ports() {
        let output = "p123\nf5\nn127.0.0.1:5432\nf6\nn[::1]:5432\np456\nf9\nn*:3000\n";
        assert_eq!(
            parse_lsof(output),
            vec![
                ListeningPort {
                    address: "127.0.0.1".into(),
                    port: 5432
                },
                ListeningPort {
                    address: "::1".into(),
                    port: 5432
                },
                ListeningPort {
                    address: "0.0.0.0".into(),
                    port: 3000
                },
            ]
        );
    }
}
