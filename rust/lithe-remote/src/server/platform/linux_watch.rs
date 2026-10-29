//! inotify backend for recursive watching on Linux.
//!
//! inotify watches single directories, so the backend registers every
//! directory of the tree and follows creations, moves and deletions to keep
//! the registration current. Directories created after the walk are
//! registered on their creation event, and their existing contents are
//! reported as created, because files written before the registration
//! produce no events of their own.

use crate::protocol::methods::{ChangeKind, WatchBackend};
use crate::server::watch::{Excludes, RawEvent, Sink};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

pub(crate) const BACKEND: WatchBackend = WatchBackend::Inotify;

const WATCH_MASK: u32 = libc::IN_CREATE
    | libc::IN_DELETE
    | libc::IN_MOVED_FROM
    | libc::IN_MOVED_TO
    | libc::IN_MODIFY
    | libc::IN_CLOSE_WRITE
    | libc::IN_ATTRIB
    | libc::IN_DELETE_SELF
    | libc::IN_MOVE_SELF
    | libc::IN_ONLYDIR
    | libc::IN_DONT_FOLLOW
    | libc::IN_EXCL_UNLINK;

/// Read buffer for events; one event is at most a header plus `NAME_MAX`.
const EVENT_BUFFER_BYTES: usize = 64 * 1024;

/// Per-user directory limit configured on the host.
pub(crate) fn directory_limit() -> Option<u64> {
    std::fs::read_to_string("/proc/sys/fs/inotify/max_user_watches")
        .ok()?
        .trim()
        .parse()
        .ok()
}

/// Running backend. Dropping it stops the thread and closes the inotify
/// descriptor, which releases every registration at once.
pub(crate) struct Watcher {
    stop: Option<OwnedFd>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for Watcher {
    fn drop(&mut self) {
        // Closing the write end makes the stop pipe readable (end-of-file).
        self.stop.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

pub(crate) fn start(
    root: PathBuf,
    excludes: Arc<Excludes>,
    sink: Sink,
) -> io::Result<(Watcher, Option<u64>)> {
    // SAFETY: inotify_init1 has no memory-safety preconditions.
    let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
    if fd == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the descriptor was just created and is owned here.
    let inotify = unsafe { OwnedFd::from_raw_fd(fd) };
    let mut tree = Tree {
        fd: inotify.as_raw_fd(),
        root: root.clone(),
        by_descriptor: HashMap::new(),
        limit_reported: false,
        excludes,
    };
    let root_descriptor = tree.add(&root)?;
    tree.add_below(&root, &sink, false);
    let watched = tree.by_descriptor.len() as u64;

    let (stop_read, stop_write) = pipe()?;
    let thread = thread::Builder::new()
        .name("remote-inotify".into())
        .spawn(move || {
            let _inotify = inotify;
            tree.run(root_descriptor, stop_read, sink);
        })?;
    Ok((
        Watcher {
            stop: Some(stop_write),
            thread: Some(thread),
        },
        Some(watched),
    ))
}

struct Tree {
    fd: RawFd,
    root: PathBuf,
    by_descriptor: HashMap<i32, PathBuf>,
    limit_reported: bool,
    excludes: Arc<Excludes>,
}

impl Tree {
    fn add(&mut self, directory: &Path) -> io::Result<i32> {
        let path = std::ffi::CString::new(directory.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL"))?;
        // SAFETY: the path is a NUL-terminated string that outlives the call.
        let descriptor = unsafe { libc::inotify_add_watch(self.fd, path.as_ptr(), WATCH_MASK) };
        if descriptor == -1 {
            return Err(io::Error::last_os_error());
        }
        self.by_descriptor
            .insert(descriptor, directory.to_path_buf());
        Ok(descriptor)
    }

    /// Registers every directory below `directory`. With `report`, every
    /// entry found is also reported as created.
    fn add_below(&mut self, directory: &Path, sink: &Sink, report: bool) {
        let mut pending = vec![directory.to_path_buf()];
        while let Some(current) = pending.pop() {
            let Ok(entries) = std::fs::read_dir(&current) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if report {
                    let _ = sink.send(RawEvent::Change(path.clone(), ChangeKind::Created));
                }
                let is_directory = entry.file_type().is_ok_and(|kind| kind.is_dir());
                if !is_directory || self.excludes.is_excluded_name(&entry.file_name()) {
                    continue;
                }
                if self.limit_reported {
                    continue;
                }
                match self.add(&path) {
                    Ok(_) => pending.push(path),
                    Err(error) if error.raw_os_error() == Some(libc::ENOSPC) => {
                        self.limit_reported = true;
                        let _ = sink.send(RawEvent::LimitReached(format!(
                            "the inotify watch limit was reached after {} directories; raise fs.inotify.max_user_watches",
                            self.by_descriptor.len()
                        )));
                    }
                    // Removed or unreadable meanwhile; nothing to watch.
                    Err(_) => {}
                }
            }
        }
    }

    fn forget_below(&mut self, directory: &Path) {
        let stale: Vec<i32> = self
            .by_descriptor
            .iter()
            .filter(|(_, path)| path.starts_with(directory))
            .map(|(descriptor, _)| *descriptor)
            .collect();
        for descriptor in stale {
            // SAFETY: removing a registration has no memory-safety
            // preconditions; a stale descriptor only yields EINVAL.
            unsafe { libc::inotify_rm_watch(self.fd, descriptor) };
            self.by_descriptor.remove(&descriptor);
        }
    }

    fn run(&mut self, root_descriptor: i32, stop: OwnedFd, sink: Sink) {
        let mut buffer = vec![0_u8; EVENT_BUFFER_BYTES];
        loop {
            let mut descriptors = [
                libc::pollfd {
                    fd: self.fd,
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: stop.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            // SAFETY: the array is live and its length is passed.
            let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) };
            if ready == -1 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return;
            }
            if descriptors[1].revents != 0 {
                return;
            }
            // SAFETY: the buffer is writable for its full length.
            let read = unsafe { libc::read(self.fd, buffer.as_mut_ptr().cast(), buffer.len()) };
            if read <= 0 {
                continue;
            }
            if !self.dispatch(&buffer[..read as usize], root_descriptor, &sink) {
                return;
            }
        }
    }

    /// Handles one read of events. Returns `false` when the root is gone.
    fn dispatch(&mut self, mut bytes: &[u8], root_descriptor: i32, sink: &Sink) -> bool {
        let header = std::mem::size_of::<libc::inotify_event>();
        while bytes.len() >= header {
            // SAFETY: at least one header is available; read_unaligned does
            // not require the byte buffer to be aligned.
            let event: libc::inotify_event =
                unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast()) };
            let name_length = event.len as usize;
            let Some(name_bytes) = bytes.get(header..header + name_length) else {
                return true;
            };
            let name = name_bytes
                .split(|byte| *byte == 0)
                .next()
                .unwrap_or_default();
            bytes = &bytes[header + name_length..];

            if event.mask & libc::IN_Q_OVERFLOW != 0 {
                let _ = sink.send(RawEvent::Overflow);
                continue;
            }
            if event.wd == root_descriptor
                && event.mask & (libc::IN_DELETE_SELF | libc::IN_MOVE_SELF) != 0
            {
                let _ = sink.send(RawEvent::RootRemoved);
                return false;
            }
            if event.mask & libc::IN_IGNORED != 0 {
                self.by_descriptor.remove(&event.wd);
                continue;
            }
            let Some(directory) = self.by_descriptor.get(&event.wd).cloned() else {
                continue;
            };
            if name.is_empty() {
                continue;
            }
            let path = directory.join(OsStr::from_bytes(name));
            if self.excludes.contains(&path) && path != self.root {
                continue;
            }
            let is_directory = event.mask & libc::IN_ISDIR != 0;
            if event.mask & (libc::IN_CREATE | libc::IN_MOVED_TO) != 0 {
                let _ = sink.send(RawEvent::Change(path.clone(), ChangeKind::Created));
                if is_directory
                    && !self.excludes.is_excluded_name(OsStr::from_bytes(name))
                    && !self.limit_reported
                {
                    match self.add(&path) {
                        Ok(_) => self.add_below(&path, sink, true),
                        Err(error) if error.raw_os_error() == Some(libc::ENOSPC) => {
                            self.limit_reported = true;
                            let _ = sink.send(RawEvent::LimitReached(
                                "the inotify watch limit was reached; raise fs.inotify.max_user_watches".into(),
                            ));
                        }
                        Err(_) => {}
                    }
                }
            } else if event.mask & (libc::IN_DELETE | libc::IN_MOVED_FROM) != 0 {
                let _ = sink.send(RawEvent::Change(path.clone(), ChangeKind::Deleted));
                if is_directory {
                    self.forget_below(&path);
                }
            } else if event.mask & (libc::IN_MODIFY | libc::IN_CLOSE_WRITE | libc::IN_ATTRIB) != 0 {
                let _ = sink.send(RawEvent::Change(path, ChangeKind::Modified));
            }
        }
        true
    }
}

fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut descriptors = [0 as RawFd; 2];
    // SAFETY: the array holds the two descriptors pipe2 writes.
    if unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe2 succeeded, so both descriptors are open and owned here.
    Ok(unsafe {
        (
            OwnedFd::from_raw_fd(descriptors[0]),
            OwnedFd::from_raw_fd(descriptors[1]),
        )
    })
}
