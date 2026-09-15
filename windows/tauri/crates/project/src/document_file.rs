//! Native local document persistence. Disk checks and replacement share one write gate.
use serde::Serialize;
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
        fs::hard_link(&temporary.0, path)?;
    } else {
        replace(&temporary.0, path)?;
    }
    Ok(SaveOutcome::Saved)
}

#[cfg(not(windows))]
fn replace(from: &Path, to: &Path) -> io::Result<()> {
    fs::rename(from, to)
}

#[cfg(windows)]
fn replace(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::ReplaceFileW;
    let from: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let to: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    // ReplaceFile preserves the destination's ACL and metadata. Fail instead of
    // falling back to a rename that could lose permissions or target a new file.
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
}
