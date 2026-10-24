//! POSIX behavior shared by Linux and macOS hosts.

use std::ffi::{CStr, OsStr};
use std::fs;
use std::io;
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
