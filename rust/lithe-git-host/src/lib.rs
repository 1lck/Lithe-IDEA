//! Native Git process ownership, incremental pipe reads, and bounded cleanup.
//!
//! This adapter does not construct Git arguments or interpret Git output.
//! The compatibility Core caller supplies policy and cancellation; both hosts
//! share this native adapter while the existing Git command ABI is retained.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const POLL_INTERVAL: Duration = Duration::from_millis(10);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
const PIPE_DRAIN_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_CAPTURE_BYTES: usize = 32 * 1024 * 1024;
const TERMINATION_GRACE: Duration = Duration::from_millis(500);
static INPUT_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Identifies an independently decoded process output stream.
#[derive(Clone, Copy)]
pub enum Stream {
    Stdout,
    Stderr,
}

/// Raw output remains intact for Core parsers; capture overflow is an error.
pub struct Outcome {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub status: Option<ExitStatus>,
    pub failure: Option<Failure>,
}

/// Native failures are translated to stable application errors by the caller.
#[derive(Debug)]
pub enum Failure {
    Start(io::Error),
    Io(io::Error),
    Cancelled,
    OutputLimit,
    Cleanup,
}

/// Runs off the UI thread. Callbacks execute serially on the calling thread.
/// Input is backed by an owned file so a child that stops reading stdin cannot
/// prevent cancellation or block draining stdout/stderr.
pub fn run(
    command: &mut Command,
    input: Option<&[u8]>,
    mut cancelled: impl FnMut() -> bool,
    mut started: impl FnMut(),
    mut output: impl FnMut(Stream, &[u8]),
) -> Outcome {
    let mut result = Outcome {
        stdout: Vec::new(),
        stderr: Vec::new(),
        status: None,
        failure: None,
    };
    let prepared = (|| -> io::Result<_> {
        let input_file = input.map(InputFile::new).transpose()?;
        command
            .stdin(match &input_file {
                Some(file) => Stdio::from(file.file.try_clone()?),
                None => Stdio::null(),
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        platform::prepare(command);
        let child = command.spawn()?;
        Ok((OwnedChild::new(child)?, input_file))
    })();
    let (mut child, _input_file) = match prepared {
        Ok(value) => value,
        Err(error) => {
            result.failure = Some(Failure::Start(error));
            return result;
        }
    };
    started();
    let mut stdout = child.child.stdout.take().expect("piped stdout");
    let mut stderr = child.child.stderr.take().expect("piped stderr");
    if let Err(error) = platform::nonblocking(&stdout).and_then(|_| platform::nonblocking(&stderr))
    {
        result.failure = Some(Failure::Io(error));
        return result;
    }
    let mut stdout_eof = false;
    let mut stderr_eof = false;
    let mut exited_at = None;
    loop {
        if cancelled() {
            result.failure = Some(Failure::Cancelled);
            break;
        }
        let reads = drain(
            &mut stdout,
            &mut stdout_eof,
            &mut result.stdout,
            Stream::Stdout,
            &mut output,
        )
        .and_then(|_| {
            drain(
                &mut stderr,
                &mut stderr_eof,
                &mut result.stderr,
                Stream::Stderr,
                &mut output,
            )
        });
        if let Err(error) = reads {
            result.failure = Some(error);
            break;
        }
        if result.status.is_none() {
            match child.child.try_wait() {
                Ok(Some(status)) => {
                    result.status = Some(status);
                    exited_at = Some(Instant::now());
                }
                Ok(None) => (),
                Err(error) => {
                    result.failure = Some(Failure::Io(error));
                    break;
                }
            }
        }
        if result.status.is_some() && stdout_eof && stderr_eof {
            break;
        }
        if exited_at.is_some_and(|time| time.elapsed() >= PIPE_DRAIN_TIMEOUT) {
            result.failure = Some(Failure::Cleanup);
            break;
        }
        std::thread::sleep(POLL_INTERVAL);
    }
    // This also cleans up helpers that inherited pipes after their parent exited.
    if !child.cleanup() {
        result.failure = Some(Failure::Cleanup);
    }
    if result.status.is_none() {
        result.status = child.child.try_wait().ok().flatten();
    }
    result
}

fn drain<R: Read + platform::Pipe>(
    reader: &mut R,
    eof: &mut bool,
    captured: &mut Vec<u8>,
    stream: Stream,
    output: &mut impl FnMut(Stream, &[u8]),
) -> Result<(), Failure> {
    if *eof {
        return Ok(());
    }
    let mut buffer = [0u8; 8192];
    // A noisy stream cannot starve the other stream or cancellation checks.
    for _ in 0..8 {
        let count = match platform::read(reader, &mut buffer) {
            Ok(0) => {
                *eof = true;
                return Ok(());
            }
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(Failure::Io(error)),
        };
        output(stream, &buffer[..count]);
        if captured.len() + count > MAX_CAPTURE_BYTES {
            return Err(Failure::OutputLimit);
        }
        captured.extend_from_slice(&buffer[..count]);
    }
    Ok(())
}

struct OwnedChild {
    child: Child,
    group: platform::Group,
    cleaned: bool,
}
impl OwnedChild {
    fn new(mut child: Child) -> io::Result<Self> {
        match platform::Group::new(&child) {
            Ok(group) => Ok(Self {
                child,
                group,
                cleaned: false,
            }),
            Err(error) => {
                let _ = child.kill();
                let deadline = Instant::now() + CLEANUP_TIMEOUT;
                while Instant::now() < deadline {
                    if child.try_wait()?.is_some() {
                        break;
                    }
                    std::thread::sleep(POLL_INTERVAL);
                }
                Err(error)
            }
        }
    }
    fn cleanup(&mut self) -> bool {
        if self.cleaned {
            return true;
        }
        self.group.terminate(false);
        let began = Instant::now();
        let deadline = began + CLEANUP_TIMEOUT;
        let mut forced = false;
        while Instant::now() < deadline {
            match self.child.try_wait() {
                Ok(Some(_)) => {
                    self.group.terminate(true);
                    self.cleaned = true;
                    return true;
                }
                Err(_) => break,
                Ok(None) => {
                    if !forced && began.elapsed() >= TERMINATION_GRACE {
                        self.group.terminate(true);
                        let _ = self.child.kill();
                        forced = true;
                    }
                    std::thread::sleep(POLL_INTERVAL);
                }
            }
        }
        false
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if !self.cleaned {
            self.cleanup();
        }
    }
}

struct InputFile {
    file: File,
    path: PathBuf,
}
impl InputFile {
    fn new(input: &[u8]) -> io::Result<Self> {
        for _ in 0..32 {
            let path = std::env::temp_dir().join(format!(
                "lithe-git-input-{}-{}",
                std::process::id(),
                INPUT_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let mut options = OpenOptions::new();
            options.read(true).write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            match options.open(&path) {
                Ok(file) => {
                    let mut owned = Self { file, path };
                    owned.file.write_all(input)?;
                    owned.file.seek(SeekFrom::Start(0))?;
                    return Ok(owned);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Could not allocate Git input",
        ))
    }
}
impl Drop for InputFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(unix)]
mod platform {
    use super::*;
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;
    pub trait Pipe: AsRawFd {}
    impl<T: AsRawFd> Pipe for T {}
    pub fn prepare(command: &mut Command) {
        command.process_group(0);
    }
    pub fn nonblocking(pipe: &impl Pipe) -> io::Result<()> {
        // SAFETY: the borrowed descriptor is valid and remains owned by its pipe.
        unsafe {
            let flags = libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL);
            if flags < 0
                || libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }
    pub fn read<R: Read + Pipe>(reader: &mut R, buffer: &mut [u8]) -> io::Result<usize> {
        reader.read(buffer)
    }
    pub struct Group(i32);
    impl Group {
        pub fn new(child: &Child) -> io::Result<Self> {
            Ok(Self(child.id() as i32))
        }
        pub fn terminate(&self, force: bool) {
            // SAFETY: a negative PID addresses only the process group we created.
            unsafe {
                libc::kill(-self.0, if force { libc::SIGKILL } else { libc::SIGTERM });
            }
        }
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use std::os::windows::{io::AsRawHandle, process::CommandExt};
    use windows_sys::Win32::{
        Foundation::*,
        System::{Diagnostics::ToolHelp::*, JobObjects::*, Pipes::PeekNamedPipe, Threading::*},
    };
    pub trait Pipe: AsRawHandle {}
    impl<T: AsRawHandle> Pipe for T {}
    pub fn prepare(command: &mut Command) {
        // Assign the job before the first thread can spawn credential/SSH helpers.
        command.creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
    }
    pub fn nonblocking(_: &impl Pipe) -> io::Result<()> {
        Ok(())
    }
    pub fn read<R: Read + Pipe>(reader: &mut R, buffer: &mut [u8]) -> io::Result<usize> {
        let mut available = 0;
        unsafe {
            if PeekNamedPipe(
                reader.as_raw_handle(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            ) == 0
            {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
                    return Ok(0);
                }
                return Err(error);
            }
        }
        if available == 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let count = buffer.len().min(available as usize);
        reader.read(&mut buffer[..count])
    }
    pub struct Group(HANDLE);
    impl Group {
        pub fn new(child: &Child) -> io::Result<Self> {
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle.is_null() {
                    return Err(io::Error::last_os_error());
                }
                let group = Self(handle);
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const _,
                    std::mem::size_of_val(&info) as u32,
                ) == 0
                    || AssignProcessToJobObject(handle, child.as_raw_handle()) == 0
                {
                    return Err(io::Error::last_os_error());
                }
                resume_child(child.id())?;
                Ok(group)
            }
        }
        pub fn terminate(&self, _force: bool) {
            unsafe {
                TerminateJobObject(self.0, 1);
            }
        }
    }
    fn resume_child(process_id: u32) -> io::Result<()> {
        // SAFETY: each OS handle is checked, borrowed only while valid, and
        // closed on every return. The suspended process owns exactly one thread.
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }
            let mut entry: THREADENTRY32 = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
            let mut available = Thread32First(snapshot, &mut entry);
            while available != 0 {
                if entry.th32OwnerProcessID == process_id {
                    let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                    let result = if thread.is_null() {
                        Err(io::Error::last_os_error())
                    } else {
                        let resumed = ResumeThread(thread);
                        let error = (resumed == u32::MAX).then(io::Error::last_os_error);
                        CloseHandle(thread);
                        error.map_or(Ok(()), Err)
                    };
                    CloseHandle(snapshot);
                    return result;
                }
                available = Thread32Next(snapshot, &mut entry);
            }
            CloseHandle(snapshot);
            Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Could not resume the owned Git process",
            ))
        }
    }
    impl Drop for Group {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}
