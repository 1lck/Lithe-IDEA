//! Native local document persistence. Disk checks and replacement share one write gate.
use encoding_rs::{Encoding, GB18030, GBK, SHIFT_JIS, UTF_8, WINDOWS_1252};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
};

const MAX_DOCUMENT_BYTES: u64 = 32 * 1024 * 1024;
static WRITE_GATE: Mutex<()> = Mutex::new(());
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum SaveOutcome {
    Saved {
        identity: String,
    },
    Conflict {
        content: Option<String>,
        identity: Option<String>,
    },
}

/// Text encoding used when decoding or publishing a local document.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DocumentEncoding {
    Utf8,
    Utf8Bom,
    Gbk,
    Gb18030,
    ShiftJis,
    Windows1252,
}

impl DocumentEncoding {
    /// Returns the stable label exchanged with the Tauri frontend.
    pub fn label(self) -> &'static str {
        match self {
            Self::Utf8 => "UTF-8",
            Self::Utf8Bom => "UTF-8 with BOM",
            Self::Gbk => "GBK",
            Self::Gb18030 => "GB18030",
            Self::ShiftJis => "Shift JIS",
            Self::Windows1252 => "Windows-1252",
        }
    }

    fn codec(self) -> &'static Encoding {
        match self {
            Self::Utf8 | Self::Utf8Bom => UTF_8,
            Self::Gbk => GBK,
            Self::Gb18030 => GB18030,
            Self::ShiftJis => SHIFT_JIS,
            Self::Windows1252 => WINDOWS_1252,
        }
    }

    /// Parses a user-facing encoding label, defaulting to UTF-8.
    pub fn parse(value: Option<&str>) -> io::Result<Self> {
        match value
            .unwrap_or("UTF-8")
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "utf-8" | "utf8" => Ok(Self::Utf8),
            "utf-8 with bom" | "utf8-bom" | "utf-8-bom" => Ok(Self::Utf8Bom),
            "gbk" => Ok(Self::Gbk),
            "gb18030" => Ok(Self::Gb18030),
            "shift jis" | "shift-jis" | "shift_jis" => Ok(Self::ShiftJis),
            "windows-1252" | "cp1252" => Ok(Self::Windows1252),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Unsupported document encoding",
            )),
        }
    }

    fn decode(self, bytes: &[u8]) -> io::Result<String> {
        let bytes = if matches!(self, Self::Utf8 | Self::Utf8Bom)
            && bytes.starts_with(&[0xEF, 0xBB, 0xBF])
        {
            &bytes[3..]
        } else {
            bytes
        };
        let (text, had_errors) = self.codec().decode_without_bom_handling(bytes);
        if had_errors {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Document contains invalid bytes for the selected encoding",
            ));
        }
        Ok(text.into_owned())
    }

    fn encode(self, text: &str) -> io::Result<Vec<u8>> {
        let (encoded, _, had_errors) = self.codec().encode(text);
        if had_errors {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Document contains characters unavailable in the selected encoding",
            ));
        }
        let mut bytes = encoded.into_owned();
        if self == Self::Utf8Bom {
            bytes.splice(0..0, [0xEF, 0xBB, 0xBF]);
        }
        Ok(bytes)
    }
}

/// Decoded text and the encoding selected for the document.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentRead {
    /// Text decoded from the bounded file bytes.
    pub content: String,
    /// Stable label for the codec used to decode `content`.
    pub encoding: String,
    /// SHA-256 of the exact bytes read from disk, used for optimistic saves.
    pub identity: String,
}

/// A missing file is distinct from an unreadable or unsupported file.
pub fn read_document(path: &Path) -> io::Result<Option<String>> {
    Ok(read_document_with_encoding(path, None)?.map(|document| document.content))
}

/// Reads a bounded document using an explicit encoding or a conservative auto-detection policy.
pub fn read_document_with_encoding(
    path: &Path,
    encoding: Option<&str>,
) -> io::Result<Option<DocumentRead>> {
    let bytes = read_document_bytes(path)?;
    let Some(bytes) = bytes else {
        return Ok(None);
    };
    let selected = match encoding {
        Some(value) => DocumentEncoding::parse(Some(value))?,
        None if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) => DocumentEncoding::Utf8Bom,
        None => match DocumentEncoding::Utf8.decode(&bytes) {
            Ok(_) => DocumentEncoding::Utf8,
            Err(_) => {
                let text = DocumentEncoding::Gb18030.decode(&bytes)?;
                if DocumentEncoding::Gbk.encode(&text).is_ok() {
                    DocumentEncoding::Gbk
                } else {
                    DocumentEncoding::Gb18030
                }
            }
        },
    };
    Ok(Some(DocumentRead {
        content: selected.decode(&bytes)?,
        encoding: selected.label().to_string(),
        identity: bytes_identity(&bytes),
    }))
}

fn bytes_identity(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn read_document_bytes(path: &Path) -> io::Result<Option<Vec<u8>>> {
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
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
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
    Ok(Some(bytes))
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

/// Compares exact disk bytes, including equal-length edits with unchanged mtimes.
/// The second check narrows but cannot eliminate races with non-cooperating writers.
pub fn save_document(path: &Path, text: &str, expected: Option<&str>) -> io::Result<SaveOutcome> {
    save_document_with_encoding(path, text, expected, Some("UTF-8"), Some("UTF-8"), None)
}

/// Saves text using the requested encoding while retaining guarded, atomic publication.
pub fn save_document_with_encoding(
    path: &Path,
    text: &str,
    expected: Option<&str>,
    encoding: Option<&str>,
    expected_encoding: Option<&str>,
    expected_identity: Option<&str>,
) -> io::Result<SaveOutcome> {
    let selected = DocumentEncoding::parse(encoding)?;
    let expected_codec = DocumentEncoding::parse(expected_encoding.or(encoding))?;
    let bytes = selected.encode(text)?;
    save_with_precommit(
        path,
        &bytes,
        expected,
        expected_codec,
        expected_identity,
        || {},
    )
}

fn save_with_precommit(
    path: &Path,
    bytes: &[u8],
    expected: Option<&str>,
    expected_encoding: DocumentEncoding,
    expected_identity: Option<&str>,
    before_commit: impl FnOnce(),
) -> io::Result<SaveOutcome> {
    if !path.is_absolute() || bytes.len() as u64 > MAX_DOCUMENT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid document path or size",
        ));
    }
    let expected_bytes = expected
        .map(|text| expected_encoding.encode(text))
        .transpose()?;
    let fallback_identity = expected_bytes.as_deref().map(bytes_identity);
    let expected_identity = expected_identity.or(fallback_identity.as_deref());
    let _gate = WRITE_GATE
        .lock()
        .map_err(|_| io::Error::other("Document write gate failed"))?;
    let current = read_document_with_encoding(path, Some(expected_encoding.label()))?;
    if !matches_expected(&current, expected, expected_identity) {
        return Ok(SaveOutcome::Conflict {
            identity: current.as_ref().map(|document| document.identity.clone()),
            content: current.map(|document| document.content),
        });
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
    file.write_all(bytes)?;
    file.sync_all()?;
    if let Ok(metadata) = fs::metadata(path) {
        file.set_permissions(metadata.permissions())?;
    }
    drop(file);
    before_commit();
    let latest = read_document_with_encoding(path, Some(expected_encoding.label()))?;
    if !matches_expected(&latest, expected, expected_identity) {
        return Ok(SaveOutcome::Conflict {
            identity: latest.as_ref().map(|document| document.identity.clone()),
            content: latest.map(|document| document.content),
        });
    }
    if expected.is_none() {
        // Creation must never replace a file created after the missing-file check.
        create_without_replacing(&temporary.0, path)?;
    } else {
        replace(&temporary.0, path)?;
    }
    Ok(SaveOutcome::Saved {
        identity: bytes_identity(bytes),
    })
}

fn matches_expected(
    current: &Option<DocumentRead>,
    expected: Option<&str>,
    expected_identity: Option<&str>,
) -> bool {
    match (current, expected_identity) {
        (Some(document), Some(identity)) => document.identity == identity,
        (None, Some(_)) => false,
        _ => current.as_ref().map(|document| document.content.as_str()) == expected,
    }
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
    fn rejects_matching_text_with_a_different_raw_identity() {
        let directory = Directory::new();
        let path = directory.0.join("identity.txt");
        fs::write(&path, "same").unwrap();
        let read = read_document_with_encoding(&path, Some("UTF-8"))
            .unwrap()
            .unwrap();
        fs::write(&path, b"same\n").unwrap();
        assert!(matches!(
            save_document_with_encoding(
                &path,
                "replacement",
                Some("same"),
                Some("UTF-8"),
                Some("UTF-8"),
                Some(&read.identity),
            )
            .unwrap(),
            SaveOutcome::Conflict { .. }
        ));
    }
    #[test]
    fn rechecks_after_staging_and_cleans_temporary_file() {
        let directory = Directory::new();
        let path = directory.0.join("a.txt");
        fs::write(&path, "old").unwrap();
        let outcome = save_with_precommit(
            &path,
            b"mine",
            Some("old"),
            DocumentEncoding::Utf8,
            None,
            || {
                fs::write(&path, "external").unwrap();
            },
        )
        .unwrap();
        assert!(matches!(outcome, SaveOutcome::Conflict { .. }));
        assert_eq!(fs::read_to_string(&path).unwrap(), "external");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    #[test]
    fn decodes_and_reencodes_gbk_without_loss() {
        let directory = Directory::new();
        let path = directory.0.join("gbk.txt");
        let text = "中文文件";
        let encoded = DocumentEncoding::Gbk.encode(text).unwrap();
        fs::write(&path, encoded).unwrap();
        let decoded = read_document_with_encoding(&path, Some("GBK"))
            .unwrap()
            .unwrap();
        assert_eq!(decoded.content, text);
        assert_eq!(decoded.encoding, "GBK");
        assert!(matches!(
            save_document_with_encoding(
                &path,
                "更新后的中文",
                Some(text),
                Some("GBK"),
                Some("GBK"),
                None,
            )
            .unwrap(),
            SaveOutcome::Saved { .. }
        ));
        assert_eq!(
            read_document_with_encoding(&path, Some("GBK"))
                .unwrap()
                .unwrap()
                .content,
            "更新后的中文"
        );
    }

    #[test]
    fn auto_detection_falls_back_to_gbk_after_invalid_utf8() {
        let directory = Directory::new();
        let path = directory.0.join("gbk-auto.txt");
        fs::write(&path, DocumentEncoding::Gbk.encode("自动检测").unwrap()).unwrap();
        let decoded = read_document_with_encoding(&path, None).unwrap().unwrap();
        assert_eq!(decoded.encoding, "GBK");
        assert_eq!(decoded.content, "自动检测");
    }

    #[test]
    fn explicit_encoding_rejects_invalid_bytes_and_preserves_bom_policy() {
        let directory = Directory::new();
        let invalid = directory.0.join("invalid.txt");
        fs::write(&invalid, [0xFF, 0xFE]).unwrap();
        assert_eq!(
            read_document_with_encoding(&invalid, Some("UTF-8"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );

        let bom = directory.0.join("bom.txt");
        fs::write(&bom, DocumentEncoding::Utf8Bom.encode("带 BOM").unwrap()).unwrap();
        let read = read_document_with_encoding(&bom, Some("UTF-8"))
            .unwrap()
            .unwrap();
        assert_eq!(read.content, "带 BOM");
        assert_eq!(read.encoding, "UTF-8");
    }

    #[test]
    fn rejects_unrepresentable_text_before_publishing() {
        let directory = Directory::new();
        let path = directory.0.join("cp1252.txt");
        fs::write(&path, b"old").unwrap();
        let error = save_document_with_encoding(
            &path,
            "中文",
            Some("old"),
            Some("Windows-1252"),
            Some("Windows-1252"),
            None,
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(fs::read(&path).unwrap(), b"old");
    }
    #[test]
    fn missing_file_requires_explicit_creation_and_new_baseline_is_checked() {
        let directory = Directory::new();
        let path = directory.0.join("a.txt");
        assert!(matches!(
            save_document(&path, "mine", Some("old")).unwrap(),
            SaveOutcome::Conflict { content: None, .. }
        ));
        assert!(!path.exists());
        assert!(matches!(
            save_document(&path, "mine", None).unwrap(),
            SaveOutcome::Saved { .. }
        ));
        assert!(matches!(
            save_document(&path, "new mine", Some("mine")).unwrap(),
            SaveOutcome::Saved { .. }
        ));
        assert!(matches!(
            save_document(&path, "stale window", Some("mine")).unwrap(),
            SaveOutcome::Conflict { .. }
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "new mine");
    }
}
