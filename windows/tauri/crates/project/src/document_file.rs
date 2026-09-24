//! Native local document persistence. Disk checks and replacement share one write gate.
use serde::Serialize;
#[cfg(windows)]
use std::time::Duration;
use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

const MAX_DOCUMENT_BYTES: u64 = 32 * 1024 * 1024;
#[cfg(windows)]
const WINDOWS_REPLACE_RETRY_DELAYS: [Duration; 4] = [
    Duration::from_millis(10),
    Duration::from_millis(25),
    Duration::from_millis(50),
    Duration::from_millis(100),
];
static WRITE_GATE: Mutex<()> = Mutex::new(());
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum SaveOutcome {
    Saved,
    Conflict { content: Option<String> },
}

/// A missing file is distinct from an unreadable or unsupported file.
pub fn read_document(path: &Path) -> io::Result<Option<String>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Document must be a regular file, not a symbolic link",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() != 1 {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Hard-linked documents require an explicit copy",
            ));
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::{fs::MetadataExt, io::AsRawHandle};
        use windows_sys::Win32::Storage::FileSystem::{
            BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
        };
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Reparse-point documents are not supported",
            ));
        }
        let file = fs::File::open(path)?;
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        // The handle and output storage are valid for the duration of this call.
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } == 0 {
            return Err(io::Error::last_os_error());
        }
        if info.nNumberOfLinks != 1 {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Hard-linked documents require an explicit copy",
            ));
        }
    }
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(MAX_DOCUMENT_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_DOCUMENT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Document exceeds the 32 MB editing limit",
        ));
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

struct TemporaryFile(PathBuf);
impl Drop for TemporaryFile {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.0) {
            if error.kind() != io::ErrorKind::NotFound {
                log::warn!("Could not remove document staging file: {error}");
            }
        }
    }
}

/// Compares actual UTF-8 bytes, including equal-length edits with unchanged mtimes.
/// The second check narrows but cannot eliminate races with non-cooperating writers.
pub fn save_document(path: &Path, text: &str, expected: Option<&str>) -> io::Result<SaveOutcome> {
    save_with_precommit(path, text, expected, || {})
}

fn save_with_precommit(
    path: &Path,
    text: &str,
    expected: Option<&str>,
    before_commit: impl FnOnce(),
) -> io::Result<SaveOutcome> {
    if !path.is_absolute() || text.len() as u64 > MAX_DOCUMENT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid document path or size",
        ));
    }
    let _gate = WRITE_GATE
        .lock()
        .map_err(|_| io::Error::other("Document write gate failed"))?;
    let current = read_document(path)?;
    if current.as_deref() != expected {
        return Ok(SaveOutcome::Conflict { content: current });
    }
    if fs::metadata(path).is_ok_and(|metadata| metadata.permissions().readonly()) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Document is read-only",
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("Missing document parent"))?;
    let mut staged = None;
    for _ in 0..16 {
        let temporary = parent.join(format!(
            ".lithe-document-{}-{}.tmp",
            std::process::id(),
            TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => {
                staged = Some((TemporaryFile(temporary), file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    let (temporary, mut file) =
        staged.ok_or_else(|| io::Error::other("Could not stage document"))?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    if let Ok(metadata) = fs::metadata(path) {
        file.set_permissions(metadata.permissions())?;
    }
    drop(file);
    before_commit();
    let latest = read_document(path)?;
    if latest.as_deref() != expected {
        return Ok(SaveOutcome::Conflict { content: latest });
    }
    if expected.is_none() {
        // Creation must never replace a file created after the missing-file check.
        create_without_replacing(&temporary.0, path)?;
        return Ok(SaveOutcome::Saved);
    }
    replace(
        &temporary.0,
        path,
        expected.expect("existing documents have a baseline"),
    )
}

// Same-directory publication must reject a concurrently created destination.
#[cfg(windows)]
fn create_without_replacing(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::MoveFileExW;
    let from: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let to: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    // Zero flags prohibit replacement and cross-volume copying. Unlike hard
    // links this also supports writable FAT/exFAT volumes.
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
fn create_without_replacing(from: &Path, to: &Path) -> io::Result<()> {
    fs::hard_link(from, to)
}

#[cfg(not(windows))]
fn replace(from: &Path, to: &Path, _expected: &str) -> io::Result<SaveOutcome> {
    fs::rename(from, to)?;
    Ok(SaveOutcome::Saved)
}

#[cfg(windows)]
fn replace(from: &Path, to: &Path, expected: &str) -> io::Result<SaveOutcome> {
    use std::os::windows::ffi::OsStrExt;
    let from_wide: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let to_wide: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    // ReplaceFile preserves the destination's ACL and metadata. Fail instead of
    // falling back to a rename that could lose permissions or target a new file.
    retry_windows_replace(
        || replace_file_once(&from_wide, &to_wide),
        || read_document(to),
        expected,
        std::thread::sleep,
    )
}

#[cfg(windows)]
fn replace_file_once(from: &[u16], to: &[u16]) -> io::Result<()> {
    use windows_sys::Win32::Storage::FileSystem::ReplaceFileW;
    if unsafe {
        ReplaceFileW(
            to.as_ptr(),
            from.as_ptr(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            std::ptr::null(),
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(windows)]
fn retry_windows_replace(
    mut replace_once: impl FnMut() -> io::Result<()>,
    mut read_current: impl FnMut() -> io::Result<Option<String>>,
    expected: &str,
    mut wait: impl FnMut(Duration),
) -> io::Result<SaveOutcome> {
    for (retry_index, retry_delay) in WINDOWS_REPLACE_RETRY_DELAYS.iter().enumerate() {
        match replace_once() {
            Ok(()) => return Ok(SaveOutcome::Saved),
            Err(error) if is_transient_windows_replace_error(&error) => {
                log::debug!(
                    "Retrying Windows document replacement after transient error ({}/{} in {} ms): {error}",
                    retry_index + 1,
                    WINDOWS_REPLACE_RETRY_DELAYS.len(),
                    retry_delay.as_millis()
                );
                wait(*retry_delay);
                let current = read_current()?;
                if current.as_deref() != Some(expected) {
                    return Ok(SaveOutcome::Conflict { content: current });
                }
            }
            Err(error) => return Err(error),
        }
    }
    replace_once().map(|()| SaveOutcome::Saved)
}

#[cfg(windows)]
fn is_transient_windows_replace_error(error: &io::Error) -> bool {
    use windows_sys::Win32::Foundation::{
        ERROR_LOCK_VIOLATION, ERROR_SHARING_VIOLATION, ERROR_UNABLE_TO_REMOVE_REPLACED,
    };
    error.raw_os_error().is_some_and(|code| {
        matches!(
            code as u32,
            ERROR_SHARING_VIOLATION | ERROR_LOCK_VIOLATION | ERROR_UNABLE_TO_REMOVE_REPLACED
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-document-test-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn new_file_publication_never_replaces_a_concurrent_creator() {
        let directory = Directory::new();
        let target = directory.0.join("new.txt");
        let staging = directory.0.join("staging.tmp");
        fs::write(&staging, "mine").unwrap();
        let cleanup = TemporaryFile(staging.clone());
        // Another writer wins after the final baseline read, before publication.
        fs::write(&target, "external").unwrap();
        assert!(create_without_replacing(&staging, &target).is_err());
        drop(cleanup);
        assert_eq!(fs::read_to_string(&target).unwrap(), "external");
        assert!(!staging.exists());
    }

    #[test]
    fn rejects_external_change_even_when_mtime_and_size_match() {
        let directory = Directory::new();
        let path = directory.0.join("a.txt");
        fs::write(&path, "old").unwrap();
        let modified = fs::metadata(&path).unwrap().modified().unwrap();
        fs::write(&path, "new").unwrap();
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(modified)
            .unwrap();
        assert!(matches!(
            save_document(&path, "mine", Some("old")).unwrap(),
            SaveOutcome::Conflict { .. }
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "new");
    }
    #[test]
    fn rechecks_after_staging_and_cleans_temporary_file() {
        let directory = Directory::new();
        let path = directory.0.join("a.txt");
        fs::write(&path, "old").unwrap();
        let outcome = save_with_precommit(&path, "mine", Some("old"), || {
            fs::write(&path, "external").unwrap();
        })
        .unwrap();
        assert!(matches!(outcome, SaveOutcome::Conflict { .. }));
        assert_eq!(fs::read_to_string(&path).unwrap(), "external");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }
    #[test]
    fn missing_file_requires_explicit_creation_and_new_baseline_is_checked() {
        let directory = Directory::new();
        let path = directory.0.join("a.txt");
        assert!(matches!(
            save_document(&path, "mine", Some("old")).unwrap(),
            SaveOutcome::Conflict { content: None }
        ));
        assert!(!path.exists());
        assert!(matches!(
            save_document(&path, "mine", None).unwrap(),
            SaveOutcome::Saved
        ));
        assert!(matches!(
            save_document(&path, "new mine", Some("mine")).unwrap(),
            SaveOutcome::Saved
        ));
        assert!(matches!(
            save_document(&path, "stale window", Some("mine")).unwrap(),
            SaveOutcome::Conflict { .. }
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "new mine");
    }

    #[cfg(windows)]
    #[test]
    fn windows_replace_retries_transient_errors_without_real_waits() {
        use windows_sys::Win32::Foundation::{
            ERROR_SHARING_VIOLATION, ERROR_UNABLE_TO_REMOVE_REPLACED,
        };
        let mut attempts = 0;
        let mut checks = 0;
        let mut waits = Vec::new();
        let outcome = retry_windows_replace(
            || {
                attempts += 1;
                match attempts {
                    1 => Err(io::Error::from_raw_os_error(
                        ERROR_UNABLE_TO_REMOVE_REPLACED as i32,
                    )),
                    2 => Err(io::Error::from_raw_os_error(ERROR_SHARING_VIOLATION as i32)),
                    _ => Ok(()),
                }
            },
            || {
                checks += 1;
                Ok(Some("old".to_owned()))
            },
            "old",
            |delay| waits.push(delay),
        )
        .unwrap();

        assert!(matches!(outcome, SaveOutcome::Saved));
        assert_eq!(attempts, 3);
        assert_eq!(checks, 2);
        assert_eq!(
            waits,
            WINDOWS_REPLACE_RETRY_DELAYS[..2].to_vec(),
            "the injected waiter makes retry timing deterministic"
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_replace_recovers_after_a_non_delete_sharing_handle_closes() {
        use std::os::windows::{ffi::OsStrExt, fs::OpenOptionsExt};
        use windows_sys::Win32::Storage::FileSystem::{FILE_SHARE_READ, FILE_SHARE_WRITE};
        let directory = Directory::new();
        let target = directory.0.join("locked.txt");
        let staging = directory.0.join("staging.tmp");
        fs::write(&target, "old").unwrap();
        fs::write(&staging, "mine").unwrap();
        let mut held = Some(
            OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
                .open(&target)
                .unwrap(),
        );
        let from_wide: Vec<u16> = staging.as_os_str().encode_wide().chain(Some(0)).collect();
        let to_wide: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut waits = 0;

        let outcome = retry_windows_replace(
            || replace_file_once(&from_wide, &to_wide),
            || read_document(&target),
            "old",
            |_| {
                waits += 1;
                drop(held.take());
            },
        )
        .unwrap();

        assert!(matches!(outcome, SaveOutcome::Saved));
        assert_eq!(waits, 1);
        assert_eq!(fs::read_to_string(&target).unwrap(), "mine");
        assert!(!staging.exists());
    }

    #[cfg(windows)]
    #[test]
    fn windows_replace_recheck_preserves_an_external_change() {
        use windows_sys::Win32::Foundation::ERROR_UNABLE_TO_REMOVE_REPLACED;
        let mut attempts = 0;
        let mut waits = Vec::new();
        let outcome = retry_windows_replace(
            || {
                attempts += 1;
                Err(io::Error::from_raw_os_error(
                    ERROR_UNABLE_TO_REMOVE_REPLACED as i32,
                ))
            },
            || Ok(Some("external".to_owned())),
            "old",
            |delay| waits.push(delay),
        )
        .unwrap();

        assert!(matches!(
            outcome,
            SaveOutcome::Conflict {
                content: Some(ref content)
            } if content == "external"
        ));
        assert_eq!(attempts, 1);
        assert_eq!(waits, WINDOWS_REPLACE_RETRY_DELAYS[..1].to_vec());
    }

    #[cfg(windows)]
    #[test]
    fn windows_replace_retry_budget_is_bounded() {
        use windows_sys::Win32::Foundation::ERROR_LOCK_VIOLATION;
        let mut attempts = 0;
        let mut checks = 0;
        let mut waits = Vec::new();
        let error = retry_windows_replace(
            || {
                attempts += 1;
                Err(io::Error::from_raw_os_error(ERROR_LOCK_VIOLATION as i32))
            },
            || {
                checks += 1;
                Ok(Some("old".to_owned()))
            },
            "old",
            |delay| waits.push(delay),
        )
        .unwrap_err();

        assert_eq!(error.raw_os_error(), Some(ERROR_LOCK_VIOLATION as i32));
        assert_eq!(attempts, WINDOWS_REPLACE_RETRY_DELAYS.len() + 1);
        assert_eq!(checks, WINDOWS_REPLACE_RETRY_DELAYS.len());
        assert_eq!(waits, WINDOWS_REPLACE_RETRY_DELAYS);
    }

    #[cfg(windows)]
    #[test]
    fn windows_replace_does_not_retry_permanent_errors() {
        let mut attempts = 0;
        let mut checks = 0;
        let mut waits = Vec::new();
        let error = retry_windows_replace(
            || {
                attempts += 1;
                Err(io::Error::from_raw_os_error(5))
            },
            || {
                checks += 1;
                Ok(Some("old".to_owned()))
            },
            "old",
            |delay| waits.push(delay),
        )
        .unwrap_err();

        assert_eq!(error.raw_os_error(), Some(5));
        assert_eq!(attempts, 1);
        assert_eq!(checks, 0);
        assert!(waits.is_empty());
    }
}
