//! Linux host adapter, used for SSH hosts and containers.

use super::{unix, ChildKind};
use crate::protocol::methods::{ListeningPort, OperatingSystem, OrphanProtection};
use std::collections::HashSet;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub(crate) const OPERATING_SYSTEM: OperatingSystem = OperatingSystem::Linux;
pub(crate) const ORPHAN_PROTECTION: OrphanProtection = OrphanProtection::ParentDeathSignal;

/// TCP socket state `LISTEN` in `/proc/net/tcp`.
const TCP_LISTEN_STATE: &str = "0A";

/// Configures a child to lead its own session and process group and to be
/// killed by the kernel if the server dies.
///
/// `PR_SET_PDEATHSIG` fires when the *thread* that forked the child exits,
/// not the process, which is why every spawn runs on the spawner thread.
pub(crate) fn prepare_child(command: &mut Command, kind: ChildKind) {
    // SAFETY: getpid has no preconditions.
    let server = unsafe { libc::getpid() };
    // SAFETY: the closure only calls async-signal-safe functions, as required
    // between fork and exec.
    unsafe {
        command.pre_exec(move || {
            unix::start_new_session()?;
            if kind == ChildKind::Terminal {
                unix::acquire_controlling_terminal()?;
            }
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

/// Processes whose session id is `session`, read from `/proc/<pid>/stat`.
pub(crate) fn session_members(session: u32) -> Vec<u32> {
    process_sessions()
        .filter(|(_, member_session)| *member_session == session)
        .map(|(pid, _)| pid)
        .collect()
}

/// The sessions among `sessions` that have a member, from one scan.
pub(crate) fn sessions_with_members(sessions: &HashSet<u32>) -> HashSet<u32> {
    process_sessions()
        .map(|(_, session)| session)
        .filter(|session| sessions.contains(session))
        .collect()
}

/// `(pid, session id)` of every process.
fn process_sessions() -> impl Iterator<Item = (u32, u32)> {
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_name().to_str()?.parse::<u32>().ok())
        .filter_map(|pid| {
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            Some((pid, stat_session(&stat)?))
        })
}

/// The session id is the fourth field after the command name, which is
/// parenthesized and may itself contain spaces and parentheses.
fn stat_session(stat: &str) -> Option<u32> {
    let (_, after_name) = stat.rsplit_once(')')?;
    after_name.split_whitespace().nth(3)?.parse().ok()
}

/// User id of the process on the other end of a Unix socket.
pub(crate) fn peer_uid(socket: RawFd) -> io::Result<u32> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the out-pointers reference live locals of the declared size.
    let status = unsafe {
        libc::getsockopt(
            socket,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if status == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(credentials.uid)
}

/// Listening TCP sockets in the server's network namespace, which inside a
/// container is the container's own. Sockets of other users are included:
/// Docker's port proxies, for example, run as root.
pub(crate) fn listening_ports() -> io::Result<Vec<ListeningPort>> {
    let mut ports = Vec::new();
    for (table, ipv6) in [("/proc/net/tcp", false), ("/proc/net/tcp6", true)] {
        match std::fs::read_to_string(table) {
            Ok(contents) => ports.extend(parse_proc_net_tcp(&contents, ipv6)),
            // Kernels without IPv6 have no tcp6 table.
            Err(error) if error.kind() == io::ErrorKind::NotFound && ipv6 => {}
            Err(error) => return Err(error),
        }
    }
    Ok(ports)
}

fn parse_proc_net_tcp(contents: &str, ipv6: bool) -> Vec<ListeningPort> {
    contents
        .lines()
        .skip(1)
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let local = fields.nth(1)?;
            let state = fields.nth(1)?;
            if state != TCP_LISTEN_STATE {
                return None;
            }
            let (address, port) = local.split_once(':')?;
            Some(ListeningPort {
                address: if ipv6 {
                    parse_ipv6(address)?.to_string()
                } else {
                    parse_ipv4(address)?.to_string()
                },
                port: u16::from_str_radix(port, 16).ok()?,
            })
        })
        .collect()
}

/// The kernel prints each 32-bit word of an address in host byte order.
fn parse_ipv4(hex: &str) -> Option<Ipv4Addr> {
    let word = u32::from_str_radix(hex, 16).ok()?;
    Some(Ipv4Addr::from(word.to_ne_bytes()))
}

fn parse_ipv6(hex: &str) -> Option<Ipv6Addr> {
    if hex.len() != 32 {
        return None;
    }
    let mut bytes = [0_u8; 16];
    for (index, chunk) in bytes.chunks_mut(4).enumerate() {
        let word = u32::from_str_radix(&hex[index * 8..index * 8 + 8], 16).ok()?;
        chunk.copy_from_slice(&word.to_ne_bytes());
    }
    Some(Ipv6Addr::from(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Fixture lines copied from a little-endian host: 127.0.0.1:8080 and
    // 0.0.0.0:22 listening, plus an established connection that is ignored.
    #[test]
    fn session_ids_are_read_after_the_parenthesized_name() {
        let stat = "4242 (my (odd) name) S 1 4242 4242 34816 4242 4194560 0";
        assert_eq!(stat_session(stat), Some(4242));
    }

    #[test]
    fn proc_net_tables_yield_listening_sockets_only() {
        let ipv4 = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1 0 100 0 0 10 0\n   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1 0 100 0 0 10 0\n   2: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 3 1 0 20 4 30 10 -1\n";
        let ports = parse_proc_net_tcp(ipv4, false);
        assert_eq!(
            ports,
            vec![
                ListeningPort {
                    address: "127.0.0.1".into(),
                    port: 8080
                },
                ListeningPort {
                    address: "0.0.0.0".into(),
                    port: 22
                },
            ]
        );
        let ipv6 = "  sl  local_address remote_address st\n   0: 00000000000000000000000001000000:1538 00000000000000000000000000000000:0000 0A\n";
        assert_eq!(
            parse_proc_net_tcp(ipv6, true),
            vec![ListeningPort {
                address: "::1".into(),
                port: 5432
            }]
        );
    }
}
