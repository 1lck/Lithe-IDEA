//! POSIX behavior shared by Linux and macOS hosts.

use std::ffi::{CStr, OsStr};
use std::fs;
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// Remote user facts. Environment variables win because `docker exec` and
/// SSH set them for the session; the password database is the fallback for
/// containers that start without them.
pub(crate) struct Account {
    pub(crate) user_name: Option<String>,
    pub(crate) home_directory: Option<String>,
    pub(crate) shell: Option<String>,
}

pub(crate) fn current_account() -> Account {
    let from_environment = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    let mut account = Account {
        user_name: from_environment("USER").or_else(|| from_environment("LOGNAME")),
        home_directory: from_environment("HOME"),
        shell: from_environment("SHELL"),
    };
    if account.user_name.is_some() && account.home_directory.is_some() && account.shell.is_some() {
        return account;
    }
    // SAFETY: getpwuid returns a pointer to static storage or null. It is
    // only called from the dispatcher thread during the handshake, and every
    // field is copied before returning.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if !entry.is_null() {
            let copy = |field: *const libc::c_char| {
                (!field.is_null())
                    .then(|| CStr::from_ptr(field).to_string_lossy().into_owned())
                    .filter(|value| !value.is_empty())
            };
            account.user_name = account.user_name.or_else(|| copy((*entry).pw_name));
            account.home_directory = account.home_directory.or_else(|| copy((*entry).pw_dir));
            account.shell = account.shell.or_else(|| copy((*entry).pw_shell));
        }
    }
    account
}

pub(crate) fn host_name() -> String {
    let mut buffer = [0 as libc::c_char; 256];
    // SAFETY: the buffer is writable for its full length, and the last byte
    // is reserved so the result is always NUL-terminated.
    let status = unsafe { libc::gethostname(buffer.as_mut_ptr(), buffer.len() - 1) };
    if status != 0 {
        return String::new();
    }
    // SAFETY: gethostname wrote a NUL-terminated string into the buffer.
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

/// Puts the spawned program in its own session and process group, so that
/// signals reach every process it starts and none of them can read the
/// server's controlling terminal, if it has one.
pub(crate) fn start_new_session() -> io::Result<()> {
    // SAFETY: setsid is async-signal-safe and is called between fork and exec.
    if unsafe { libc::setsid() } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Sends `signal` to the process group led by `leader`.
pub(crate) fn signal_process_group(leader: u32, signal: libc::c_int) -> io::Result<()> {
    let group = libc::pid_t::try_from(leader)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "pid out of range"))?;
    // SAFETY: killpg has no memory-safety preconditions.
    if unsafe { libc::killpg(group, signal) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Whether any process is still in the process group `group`. A zombie
/// member counts until it is reaped; `EPERM` means a member exists that the
/// server may not signal.
pub(crate) fn process_group_exists(group: u32) -> bool {
    let Ok(group) = libc::pid_t::try_from(group) else {
        return false;
    };
    // SAFETY: signal 0 performs only the existence and permission check.
    if unsafe { libc::killpg(group, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// The leaders among `leaders` whose sessions still have a member. Groups
/// are checked with a signal first; the process table is scanned at most
/// once, for the leaders whose own group is already empty.
pub(crate) fn live_sessions(leaders: &[u32]) -> std::collections::HashSet<u32> {
    let mut live: std::collections::HashSet<u32> = leaders
        .iter()
        .copied()
        .filter(|leader| process_group_exists(*leader))
        .collect();
    let remaining: std::collections::HashSet<u32> = leaders
        .iter()
        .copied()
        .filter(|leader| !live.contains(leader))
        .collect();
    if !remaining.is_empty() {
        live.extend(super::host::sessions_with_members(&remaining));
    }
    live
}

/// Sends `signal` to every process of the session led by `leader`: its own
/// process group and the separate groups that job control gives background
/// jobs. Shells differ in whether they forward hangups to their jobs, so the
/// server does it for them. Fails with `ESRCH` when nothing was signalled.
pub(crate) fn signal_session(leader: u32, signal: libc::c_int) -> io::Result<()> {
    let mut signalled = signal_process_group(leader, signal).is_ok();
    for pid in super::host::session_members(leader) {
        // SAFETY: kill has no memory-safety preconditions.
        signalled |= unsafe { libc::kill(pid as libc::pid_t, signal) } == 0;
    }
    if signalled {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(libc::ESRCH))
    }
}

/// Determines case sensitivity without writing: it looks up the nearest
/// component with letters under its swapped-case spelling and checks whether
/// that resolves to the same file. Only components on the same device as
/// `path` are used, because a mount point can change the answer.
pub(crate) fn probe_case_sensitivity(path: &Path) -> Option<bool> {
    let mut current = fs::canonicalize(path).ok()?;
    let device = fs::metadata(&current).ok()?.dev();
    loop {
        let original = fs::symlink_metadata(&current).ok()?;
        if original.dev() != device {
            return None;
        }
        let swapped = current.file_name().map(swap_ascii_case);
        if let Some(swapped) = swapped.filter(|swapped| {
            Some(swapped.as_slice()) != current.file_name().map(|name| name.as_bytes())
        }) {
            let sibling = current.with_file_name(OsStr::from_bytes(&swapped));
            return match fs::symlink_metadata(&sibling) {
                Ok(other) => Some(other.dev() != original.dev() || other.ino() != original.ino()),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Some(true),
                Err(_) => None,
            };
        }
        if !current.pop() {
            return None;
        }
    }
}

fn swap_ascii_case(name: &OsStr) -> Vec<u8> {
    name.as_bytes()
        .iter()
        .map(|byte| {
            if byte.is_ascii_lowercase() {
                byte.to_ascii_uppercase()
            } else {
                byte.to_ascii_lowercase()
            }
        })
        .collect()
}

/// Fallback for hosts or filesystems without an atomic no-replace rename.
/// The check and the rename are separate calls, so a concurrent creation of
/// `to` can still be overwritten.
pub(crate) fn rename_if_absent(from: &Path, to: &Path) -> io::Result<()> {
    match fs::symlink_metadata(to) {
        Ok(_) => Err(io::Error::from(io::ErrorKind::AlreadyExists)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::rename(from, to),
        Err(error) => Err(error),
    }
}

pub(crate) fn c_path(path: &Path) -> io::Result<std::ffi::CString> {
    std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL"))
}

pub(crate) fn current_uid() -> u32 {
    // SAFETY: getuid has no preconditions.
    unsafe { libc::getuid() }
}

/// Opens a pseudo-terminal pair sized `columns` x `rows`. Both descriptors
/// are close-on-exec, so no other child inherits the master; the child that
/// uses the slave receives it as its standard streams, which exec keeps.
pub(crate) fn open_pty(columns: u16, rows: u16) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut master: RawFd = -1;
    let mut slave: RawFd = -1;
    let mut size = window_size(columns, rows);
    // SAFETY: the out-pointers reference live locals; a null name and
    // terminal attributes request the defaults.
    let status = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            // Linux declares the parameter const and macOS mutable; a raw
            // mutable pointer fits both.
            std::ptr::addr_of_mut!(size),
        )
    };
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty succeeded, so both descriptors are open and owned here.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    for fd in [&master, &slave] {
        set_close_on_exec(std::os::fd::AsRawFd::as_raw_fd(fd))?;
    }
    Ok((master, slave))
}

pub(crate) fn set_window_size(master: RawFd, columns: u16, rows: u16) -> io::Result<()> {
    let size = window_size(columns, rows);
    // SAFETY: TIOCSWINSZ reads a winsize from the pointer, which references a
    // live local.
    if unsafe { libc::ioctl(master, libc::TIOCSWINSZ as _, &size) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn window_size(columns: u16, rows: u16) -> libc::winsize {
    libc::winsize {
        ws_row: rows.max(1),
        ws_col: columns.max(1),
        ws_xpixel: 0,
        ws_ypixel: 0,
    }
}

fn set_close_on_exec(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on a descriptor this process owns.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Makes the child's standard input, a pseudo-terminal slave, its
/// controlling terminal. Must run after `setsid` between fork and exec.
pub(crate) fn acquire_controlling_terminal() -> io::Result<()> {
    // SAFETY: ioctl is async-signal-safe; descriptor 0 is the slave.
    if unsafe { libc::ioctl(0, libc::TIOCSCTTY as _, 0) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Interval between exit checks of a bounded helper command.
const HELPER_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(10);

/// Reads a helper's standard output and waits for it with a deadline. On
/// timeout the helper's whole process group is killed, so shells that started
/// background jobs from profile files do not linger.
pub(crate) fn collect_output(
    mut child: std::process::Child,
    timeout: std::time::Duration,
) -> io::Result<(std::process::ExitStatus, Vec<u8>)> {
    use std::io::Read;
    let (sender, receiver) = std::sync::mpsc::channel();
    if let Some(mut stdout) = child.stdout.take() {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stdout.read_to_end(&mut bytes);
            let _ = sender.send(bytes);
        });
    } else {
        let _ = sender.send(Vec::new());
    }
    let deadline = std::time::Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = signal_process_group(child.id(), libc::SIGKILL);
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "helper command timed out",
            ));
        }
        std::thread::sleep(HELPER_POLL_INTERVAL);
    };
    // Descendants may keep the pipe open; their output is not waited for.
    let stdout = receiver
        .recv_timeout(std::time::Duration::from_millis(500))
        .unwrap_or_default();
    Ok((status, stdout))
}
