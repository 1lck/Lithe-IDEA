//! FSEvents backend for recursive watching on macOS.
//!
//! FSEvents watches whole trees with one stream and works in SSH sessions,
//! because the system daemon `fseventsd` records changes, not the session.
//! Its per-file flags are cumulative within a delivery, so the kind of a
//! change is decided by whether the path exists now rather than by flags
//! alone. The bindings are declared here directly, which keeps the server
//! free of framework wrapper crates.

use crate::protocol::methods::{ChangeKind, WatchBackend};
use crate::server::watch::{Excludes, RawEvent, Sink};
use std::collections::HashSet;
use std::ffi::{c_char, c_void, CStr};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub(crate) const BACKEND: WatchBackend = WatchBackend::Fsevents;

/// Created paths remembered to correct cumulative flags; beyond this the
/// memory is cleared, and a later write may again be reported as a creation,
/// which clients treat like a modification of a known file.
const CREATED_MEMORY_LIMIT: usize = 100_000;

/// FSEvents has no per-directory limit.
pub(crate) fn directory_limit() -> Option<u64> {
    None
}

/// Seconds FSEvents waits to batch changes. The coalescer adds its own short
/// quiet period, so this only needs to bound syscall chatter.
const LATENCY_SECONDS: f64 = 0.05;

type FSEventStreamRef = *mut c_void;
type CFRef = *const c_void;

#[repr(C)]
struct FSEventStreamContext {
    version: isize,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}

type FSEventStreamCallback = extern "C" fn(
    stream: *const c_void,
    info: *mut c_void,
    count: usize,
    paths: *mut c_void,
    flags: *const u32,
    ids: *const u64,
);

const EVENT_ID_SINCE_NOW: u64 = u64::MAX;
const CREATE_FLAG_NO_DEFER: u32 = 0x0000_0002;
const CREATE_FLAG_WATCH_ROOT: u32 = 0x0000_0004;
const CREATE_FLAG_FILE_EVENTS: u32 = 0x0000_0010;
const EVENT_FLAG_MUST_SCAN_SUBDIRS: u32 = 0x0000_0001;
const EVENT_FLAG_USER_DROPPED: u32 = 0x0000_0002;
const EVENT_FLAG_KERNEL_DROPPED: u32 = 0x0000_0004;
const EVENT_FLAG_ROOT_CHANGED: u32 = 0x0000_0020;
const EVENT_FLAG_ITEM_CREATED: u32 = 0x0000_0100;
const STRING_ENCODING_UTF8: u32 = 0x0800_0100;

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeArrayCallBacks: c_void;
    fn CFStringCreateWithBytes(
        allocator: CFRef,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> CFRef;
    fn CFArrayCreate(
        allocator: CFRef,
        values: *const CFRef,
        count: isize,
        callbacks: *const c_void,
    ) -> CFRef;
    fn CFRelease(object: CFRef);
}

#[link(name = "CoreServices", kind = "framework")]
extern "C" {
    fn FSEventStreamCreate(
        allocator: CFRef,
        callback: FSEventStreamCallback,
        context: *const FSEventStreamContext,
        paths: CFRef,
        since: u64,
        latency: f64,
        flags: u32,
    ) -> FSEventStreamRef;
    fn FSEventStreamSetDispatchQueue(stream: FSEventStreamRef, queue: *mut c_void);
    fn FSEventStreamStart(stream: FSEventStreamRef) -> u8;
    fn FSEventStreamStop(stream: FSEventStreamRef);
    fn FSEventStreamInvalidate(stream: FSEventStreamRef);
    fn FSEventStreamRelease(stream: FSEventStreamRef);
}

// libdispatch is part of libSystem, which every macOS binary links.
extern "C" {
    fn dispatch_queue_create(label: *const c_char, attributes: *const c_void) -> *mut c_void;
    fn dispatch_sync_f(queue: *mut c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
    fn dispatch_release(object: *mut c_void);
}

/// State the callback reads through the stream's `info` pointer.
struct CallbackState {
    sink: Sink,
    excludes: Arc<Excludes>,
    /// Root as the client spelled it, and as FSEvents reports it (resolved
    /// through links such as `/var` → `/private/var`).
    requested_root: PathBuf,
    reported_root: PathBuf,
    /// Paths reported as created and not deleted since. FSEvents keeps the
    /// "created" flag on every later event of such a file, so without this
    /// each save of a new file would look like another creation.
    created: Mutex<HashSet<PathBuf>>,
}

pub(crate) struct Watcher {
    stream: FSEventStreamRef,
    queue: *mut c_void,
    state: *mut CallbackState,
}

// SAFETY: the stream and queue are only used from `Drop`, and FSEvents
// documents its stream functions as callable from any thread.
unsafe impl Send for Watcher {}

impl Drop for Watcher {
    fn drop(&mut self) {
        // SAFETY: the pointers were created in `start` and are released
        // exactly once here. The empty synchronous block runs after any
        // callback still executing on the serial queue, so the state is no
        // longer referenced when it is freed.
        unsafe {
            FSEventStreamStop(self.stream);
            FSEventStreamInvalidate(self.stream);
            FSEventStreamRelease(self.stream);
            dispatch_sync_f(self.queue, std::ptr::null_mut(), drain);
            dispatch_release(self.queue);
            drop(Box::from_raw(self.state));
        }
    }
}

extern "C" fn drain(_: *mut c_void) {}

pub(crate) fn start(
    root: PathBuf,
    excludes: Arc<Excludes>,
    sink: Sink,
) -> io::Result<(Watcher, Option<u64>)> {
    let reported_root = std::fs::canonicalize(&root)?;
    let state = Box::into_raw(Box::new(CallbackState {
        sink,
        excludes,
        requested_root: root,
        reported_root: reported_root.clone(),
        created: Mutex::new(HashSet::new()),
    }));
    let context = FSEventStreamContext {
        version: 0,
        info: state.cast(),
        retain: std::ptr::null(),
        release: std::ptr::null(),
        copy_description: std::ptr::null(),
    };
    let bytes = reported_root.as_os_str().as_bytes();
    // SAFETY: every CoreFoundation object created here is released before
    // returning; the stream retains the path array it needs. The context is
    // copied by FSEventStreamCreate, and `state` outlives the stream.
    unsafe {
        let path = CFStringCreateWithBytes(
            std::ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            STRING_ENCODING_UTF8,
            0,
        );
        if path.is_null() {
            drop(Box::from_raw(state));
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "path is not UTF-8",
            ));
        }
        let paths = CFArrayCreate(std::ptr::null(), &path, 1, &kCFTypeArrayCallBacks);
        let stream = FSEventStreamCreate(
            std::ptr::null(),
            callback,
            &context,
            paths,
            EVENT_ID_SINCE_NOW,
            LATENCY_SECONDS,
            CREATE_FLAG_NO_DEFER | CREATE_FLAG_WATCH_ROOT | CREATE_FLAG_FILE_EVENTS,
        );
        CFRelease(paths);
        CFRelease(path);
        if stream.is_null() {
            drop(Box::from_raw(state));
            return Err(io::Error::other("FSEventStreamCreate failed"));
        }
        let queue = dispatch_queue_create(c"dev.lithe.remote.fsevents".as_ptr(), std::ptr::null());
        FSEventStreamSetDispatchQueue(stream, queue);
        if FSEventStreamStart(stream) == 0 {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            dispatch_release(queue);
            drop(Box::from_raw(state));
            return Err(io::Error::other("FSEventStreamStart failed"));
        }
        Ok((
            Watcher {
                stream,
                queue,
                state,
            },
            None,
        ))
    }
}

extern "C" fn callback(
    _stream: *const c_void,
    info: *mut c_void,
    count: usize,
    paths: *mut c_void,
    flags: *const u32,
    _ids: *const u64,
) {
    // SAFETY: FSEvents passes the `info` pointer from our context, which
    // stays valid until `Drop` drains the queue, and arrays of `count` C
    // strings and flags, as documented for streams without CF types.
    unsafe {
        let state = &*(info as *const CallbackState);
        let paths = paths as *const *const c_char;
        for index in 0..count {
            let flag = *flags.add(index);
            let raw = CStr::from_ptr(*paths.add(index));
            state.handle(
                PathBuf::from(std::ffi::OsStr::from_bytes(raw.to_bytes())),
                flag,
            );
        }
    }
}

impl CallbackState {
    fn handle(&self, reported: PathBuf, flag: u32) {
        if flag
            & (EVENT_FLAG_MUST_SCAN_SUBDIRS | EVENT_FLAG_USER_DROPPED | EVENT_FLAG_KERNEL_DROPPED)
            != 0
        {
            let _ = self.sink.send(RawEvent::Overflow);
            return;
        }
        if flag & EVENT_FLAG_ROOT_CHANGED != 0 {
            if !self.requested_root.exists() {
                let _ = self.sink.send(RawEvent::RootRemoved);
            }
            return;
        }
        let path = match reported.strip_prefix(&self.reported_root) {
            Ok(relative) if relative.as_os_str().is_empty() => return,
            Ok(relative) => self.requested_root.join(relative),
            Err(_) => return,
        };
        if self.excludes.contains(&path) {
            return;
        }
        let mut created = crate::server::lock(&self.created);
        let kind = if std::fs::symlink_metadata(&path).is_err() {
            created.remove(&path);
            ChangeKind::Deleted
        } else if flag & EVENT_FLAG_ITEM_CREATED != 0 && !created.contains(&path) {
            if created.len() >= CREATED_MEMORY_LIMIT {
                created.clear();
            }
            created.insert(path.clone());
            ChangeKind::Created
        } else {
            ChangeKind::Modified
        };
        drop(created);
        let _ = self.sink.send(RawEvent::Change(path, kind));
    }
}
