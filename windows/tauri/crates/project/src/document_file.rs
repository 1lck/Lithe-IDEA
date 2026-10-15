//! Native local document persistence. Disk checks and replacement share one write gate.
use encoding_rs::{
    BIG5, EUC_JP, EUC_KR, Encoding, GB18030, GBK, KOI8_R, SHIFT_JIS, UTF_8, UTF_16BE, UTF_16LE,
    WINDOWS_1250, WINDOWS_1251, WINDOWS_1252,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
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
    Saved {
        identity: String,
    },
    Conflict {
        content: Option<String>,
        identity: Option<String>,
    },
}

/// BOM policy advertised by the shared encoding catalog.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DocumentEncodingBom {
    None,
    Utf8,
    Utf16Le,
    Utf16Be,
}

/// Native side of the shared document-encoding extension point.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DocumentEncodingDescriptor {
    pub id: &'static str,
    pub stable_id: &'static str,
    pub display_name: &'static str,
    pub aliases: &'static [&'static str],
    pub supports_read: bool,
    pub supports_write: bool,
    pub bom: DocumentEncodingBom,
}

/// Text encoding used when decoding or publishing a local document.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DocumentEncoding {
    Utf8,
    Utf8Bom,
    Utf16LeBom,
    Utf16BeBom,
    Utf16Le,
    Utf16Be,
    Gbk,
    Gb18030,
    Big5,
    ShiftJis,
    EucJp,
    EucKr,
    Windows1250,
    Windows1251,
    Windows1252,
    Koi8R,
}

impl DocumentEncoding {
    /// The native mapping must stay in lockstep with the frontend catalog.
    pub const CATALOG: &'static [DocumentEncodingDescriptor] = &[
        DocumentEncodingDescriptor {
            id: "UTF-8",
            stable_id: "utf-8",
            display_name: "UTF-8",
            aliases: &["utf8"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "UTF-8 with BOM",
            stable_id: "utf-8-bom",
            display_name: "UTF-8 with BOM",
            aliases: &["utf8-bom", "utf-8-bom"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::Utf8,
        },
        DocumentEncodingDescriptor {
            id: "UTF-16 LE with BOM",
            stable_id: "utf-16le-bom",
            display_name: "UTF-16 LE with BOM",
            aliases: &["utf16le-bom", "utf-16le-bom"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::Utf16Le,
        },
        DocumentEncodingDescriptor {
            id: "UTF-16 BE with BOM",
            stable_id: "utf-16be-bom",
            display_name: "UTF-16 BE with BOM",
            aliases: &["utf16be-bom", "utf-16be-bom"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::Utf16Be,
        },
        DocumentEncodingDescriptor {
            id: "UTF-16 LE",
            stable_id: "utf-16le",
            display_name: "UTF-16 LE",
            aliases: &["utf16le"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "UTF-16 BE",
            stable_id: "utf-16be",
            display_name: "UTF-16 BE",
            aliases: &["utf16be"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "GBK",
            stable_id: "gbk",
            display_name: "GBK",
            aliases: &["cp936"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "GB18030",
            stable_id: "gb18030",
            display_name: "GB18030",
            aliases: &[],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "Big5",
            stable_id: "big5",
            display_name: "Big5",
            aliases: &["cp950"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "Shift JIS",
            stable_id: "shift-jis",
            display_name: "Shift JIS",
            aliases: &["shift-jis", "shift_jis"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "EUC-JP",
            stable_id: "euc-jp",
            display_name: "EUC-JP",
            aliases: &["eucjp"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "EUC-KR",
            stable_id: "euc-kr",
            display_name: "EUC-KR",
            aliases: &["euckr", "cp949"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "Windows-1250",
            stable_id: "windows-1250",
            display_name: "Windows-1250",
            aliases: &["cp1250"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "Windows-1251",
            stable_id: "windows-1251",
            display_name: "Windows-1251",
            aliases: &["cp1251"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "Windows-1252",
            stable_id: "windows-1252",
            display_name: "Windows-1252",
            aliases: &["cp1252", "iso-8859-1", "latin1"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
        DocumentEncodingDescriptor {
            id: "KOI8-R",
            stable_id: "koi8-r",
            display_name: "KOI8-R",
            aliases: &["koi8r"],
            supports_read: true,
            supports_write: true,
            bom: DocumentEncodingBom::None,
        },
    ];

    /// Returns the stable label exchanged with the Tauri frontend.
    pub fn label(self) -> &'static str {
        match self {
            Self::Utf8 => "UTF-8",
            Self::Utf8Bom => "UTF-8 with BOM",
            Self::Utf16LeBom => "UTF-16 LE with BOM",
            Self::Utf16BeBom => "UTF-16 BE with BOM",
            Self::Utf16Le => "UTF-16 LE",
            Self::Utf16Be => "UTF-16 BE",
            Self::Gbk => "GBK",
            Self::Gb18030 => "GB18030",
            Self::Big5 => "Big5",
            Self::ShiftJis => "Shift JIS",
            Self::EucJp => "EUC-JP",
            Self::EucKr => "EUC-KR",
            Self::Windows1250 => "Windows-1250",
            Self::Windows1251 => "Windows-1251",
            Self::Windows1252 => "Windows-1252",
            Self::Koi8R => "KOI8-R",
        }
    }

    fn codec(self) -> &'static Encoding {
        match self {
            Self::Utf8 | Self::Utf8Bom => UTF_8,
            Self::Utf16LeBom | Self::Utf16Le => UTF_16LE,
            Self::Utf16BeBom | Self::Utf16Be => UTF_16BE,
            Self::Gbk => GBK,
            Self::Gb18030 => GB18030,
            Self::Big5 => BIG5,
            Self::ShiftJis => SHIFT_JIS,
            Self::EucJp => EUC_JP,
            Self::EucKr => EUC_KR,
            Self::Windows1250 => WINDOWS_1250,
            Self::Windows1251 => WINDOWS_1251,
            Self::Windows1252 => WINDOWS_1252,
            Self::Koi8R => KOI8_R,
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
            "utf-16 le with bom" | "utf16le-bom" | "utf-16le-bom" => Ok(Self::Utf16LeBom),
            "utf-16 be with bom" | "utf16be-bom" | "utf-16be-bom" => Ok(Self::Utf16BeBom),
            "utf-16 le" | "utf-16le" | "utf16le" => Ok(Self::Utf16Le),
            "utf-16 be" | "utf-16be" | "utf16be" => Ok(Self::Utf16Be),
            "gbk" | "cp936" => Ok(Self::Gbk),
            "gb18030" => Ok(Self::Gb18030),
            "big5" | "cp950" => Ok(Self::Big5),
            "shift jis" | "shift-jis" | "shift_jis" => Ok(Self::ShiftJis),
            "euc-jp" | "eucjp" => Ok(Self::EucJp),
            "euc-kr" | "euckr" | "cp949" => Ok(Self::EucKr),
            "windows-1250" | "cp1250" => Ok(Self::Windows1250),
            "windows-1251" | "cp1251" => Ok(Self::Windows1251),
            "windows-1252" | "cp1252" | "iso-8859-1" | "latin1" => Ok(Self::Windows1252),
            "koi8-r" | "koi8r" => Ok(Self::Koi8R),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Unsupported document encoding",
            )),
        }
    }

    /// Byte order mark written by and stripped for this encoding.
    ///
    /// Plain UTF-8 has no mark of its own but still tolerates one, so a file
    /// reopened as UTF-8 does not show U+FEFF at the start of the buffer.
    fn bom(self) -> &'static [u8] {
        match self {
            Self::Utf8 | Self::Utf8Bom => &[0xEF, 0xBB, 0xBF],
            Self::Utf16LeBom => &[0xFF, 0xFE],
            Self::Utf16BeBom => &[0xFE, 0xFF],
            Self::Utf16Le
            | Self::Utf16Be
            | Self::Gbk
            | Self::Gb18030
            | Self::Big5
            | Self::ShiftJis
            | Self::EucJp
            | Self::EucKr
            | Self::Windows1250
            | Self::Windows1251
            | Self::Windows1252
            | Self::Koi8R => &[],
        }
    }

    fn strip_bom(self, bytes: &[u8]) -> &[u8] {
        bytes.strip_prefix(self.bom()).unwrap_or(bytes)
    }

    fn decode(self, bytes: &[u8]) -> io::Result<String> {
        let (text, had_errors) = self
            .codec()
            .decode_without_bom_handling(self.strip_bom(bytes));
        if had_errors {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Document contains invalid bytes for the selected encoding",
            ));
        }
        Ok(text.into_owned())
    }

    fn decode_lossy(self, bytes: &[u8]) -> String {
        self.codec()
            .decode_without_bom_handling(self.strip_bom(bytes))
            .0
            .into_owned()
    }

    fn encode_utf16(self, text: &str, to_bytes: fn(u16) -> [u8; 2]) -> Vec<u8> {
        let mut bytes = self.bom().to_vec();
        bytes.extend(text.encode_utf16().flat_map(to_bytes));
        bytes
    }

    fn encode(self, text: &str) -> io::Result<Vec<u8>> {
        // encoding_rs only decodes UTF-16; its encoder falls back to UTF-8, so
        // the code units are serialized here.
        match self {
            Self::Utf16LeBom | Self::Utf16Le => {
                return Ok(self.encode_utf16(text, u16::to_le_bytes));
            }
            Self::Utf16BeBom | Self::Utf16Be => {
                return Ok(self.encode_utf16(text, u16::to_be_bytes));
            }
            _ => {}
        }
        let (encoded, _, had_errors) = self.codec().encode(text);
        if had_errors {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Document contains characters unavailable in the selected encoding",
            ));
        }
        let mut bytes = encoded.into_owned();
        if self == Self::Utf8Bom {
            bytes.splice(0..0, self.bom().iter().copied());
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

/// A watcher hint is checked against raw bytes before applying the read codec.
#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum DocumentChangeRead {
    Unchanged,
    Missing,
    Changed { document: DocumentRead },
}

pub fn read_document_change(
    path: &Path,
    encoding: Option<&str>,
    known_identity: Option<&str>,
) -> io::Result<DocumentChangeRead> {
    let Some(bytes) = read_document_bytes(path)? else {
        return Ok(DocumentChangeRead::Missing);
    };
    if known_identity.is_some_and(|identity| bytes_identity(&bytes) == identity) {
        return Ok(DocumentChangeRead::Unchanged);
    }
    Ok(DocumentChangeRead::Changed {
        document: decode_document_bytes(&bytes, encoding)?,
    })
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
    Ok(Some(decode_document_bytes(&bytes, encoding)?))
}

/// UTF-32 LE byte order mark; Lithe has no UTF-32 codec and must not mistake it for UTF-16 LE.
const UTF32_LE_BOM: [u8; 4] = [0xFF, 0xFE, 0x00, 0x00];

fn decode_document_bytes(bytes: &[u8], encoding: Option<&str>) -> io::Result<DocumentRead> {
    let selected = match encoding {
        Some(value) => DocumentEncoding::parse(Some(value))?,
        None if bytes.starts_with(DocumentEncoding::Utf8Bom.bom()) => DocumentEncoding::Utf8Bom,
        // UTF-16 text is full of NUL bytes and never validates as UTF-8, so only
        // a byte order mark can identify it without guessing. The UTF-32 LE mark
        // (FF FE 00 00) begins with the UTF-16 LE one, so it is excluded here
        // rather than silently decoded and rewritten as UTF-16; such a file stays
        // unreadable unless the user picks an encoding explicitly.
        None if bytes.starts_with(DocumentEncoding::Utf16LeBom.bom())
            && !bytes.starts_with(&UTF32_LE_BOM) =>
        {
            DocumentEncoding::Utf16LeBom
        }
        None if bytes.starts_with(DocumentEncoding::Utf16BeBom.bom()) => {
            DocumentEncoding::Utf16BeBom
        }
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
    let content = if encoding.is_some() {
        selected.decode_lossy(&bytes)
    } else {
        selected.decode(&bytes)?
    };
    Ok(DocumentRead {
        content,
        encoding: selected.label().to_string(),
        identity: bytes_identity(&bytes),
    })
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
    // A supplied raw identity is authoritative. Reopened text may not be
    // representable by the original disk codec and must not be re-encoded here.
    let expected_bytes = if expected_identity.is_none() {
        expected
            .map(|text| expected_encoding.encode(text))
            .transpose()?
    } else {
        None
    };
    let fallback_identity = expected_bytes.as_deref().map(bytes_identity);
    let expected_identity = expected_identity.or(fallback_identity.as_deref());
    let _gate = WRITE_GATE
        .lock()
        .map_err(|_| io::Error::other("Document write gate failed"))?;
    let current = read_document_bytes(path)?;
    if !matches_expected(&current, expected_bytes.as_deref(), expected_identity) {
        return Ok(disk_conflict(current, expected_encoding));
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
    let latest = read_document_bytes(path)?;
    if !matches_expected(&latest, expected_bytes.as_deref(), expected_identity) {
        return Ok(disk_conflict(latest, expected_encoding));
    }
    if expected.is_none() {
        // Creation must never replace a file created after the missing-file check.
        create_without_replacing(&temporary.0, path)?;
        return Ok(SaveOutcome::Saved {
            identity: bytes_identity(bytes),
        });
    }
    replace(
        &temporary.0,
        path,
        expected_identity.expect("existing documents have a baseline identity"),
        expected_encoding,
        bytes_identity(bytes),
    )
}

fn matches_expected(
    current: &Option<Vec<u8>>,
    expected_bytes: Option<&[u8]>,
    expected_identity: Option<&str>,
) -> bool {
    if let Some(identity) = expected_identity {
        return current.as_deref().map(bytes_identity).as_deref() == Some(identity);
    }
    match expected_bytes {
        Some(expected) => current.as_deref() == Some(expected),
        None => current.is_none(),
    }
}

fn disk_conflict(bytes: Option<Vec<u8>>, encoding: DocumentEncoding) -> SaveOutcome {
    // An external encoding change still returns a conflict even if its bytes
    // cannot be decoded. Never substitute replacement characters or overwrite it.
    SaveOutcome::Conflict {
        identity: bytes.as_deref().map(bytes_identity),
        content: bytes
            .as_deref()
            .and_then(|bytes| encoding.decode(bytes).ok()),
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
fn replace(
    from: &Path,
    to: &Path,
    _expected_identity: &str,
    _expected_encoding: DocumentEncoding,
    identity: String,
) -> io::Result<SaveOutcome> {
    fs::rename(from, to)?;
    Ok(SaveOutcome::Saved { identity })
}

#[cfg(windows)]
fn replace(
    from: &Path,
    to: &Path,
    expected_identity: &str,
    expected_encoding: DocumentEncoding,
    identity: String,
) -> io::Result<SaveOutcome> {
    use std::os::windows::ffi::OsStrExt;
    let from_wide: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let to_wide: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    // ReplaceFile preserves the destination's ACL and metadata. Fail instead of
    // falling back to a rename that could lose permissions or target a new file.
    retry_windows_replace(
        || replace_file_once(&from_wide, &to_wide),
        || read_document_bytes(to),
        expected_identity,
        expected_encoding,
        identity,
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
    mut read_current: impl FnMut() -> io::Result<Option<Vec<u8>>>,
    expected_identity: &str,
    expected_encoding: DocumentEncoding,
    identity: String,
    mut wait: impl FnMut(Duration),
) -> io::Result<SaveOutcome> {
    for (retry_index, retry_delay) in WINDOWS_REPLACE_RETRY_DELAYS.iter().enumerate() {
        match replace_once() {
            Ok(()) => {
                return Ok(SaveOutcome::Saved {
                    identity: identity.clone(),
                });
            }
            Err(error) if is_transient_windows_replace_error(&error) => {
                log::debug!(
                    "Retrying Windows document replacement after transient error ({}/{} in {} ms): {error}",
                    retry_index + 1,
                    WINDOWS_REPLACE_RETRY_DELAYS.len(),
                    retry_delay.as_millis()
                );
                wait(*retry_delay);
                let current = read_current()?;
                if current.as_deref().map(bytes_identity).as_deref() != Some(expected_identity) {
                    return Ok(disk_conflict(current, expected_encoding));
                }
            }
            Err(error) => return Err(error),
        }
    }
    replace_once().map(|()| SaveOutcome::Saved { identity })
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
    fn identity_guard_does_not_decode_disk_bytes_with_the_save_encoding() {
        let directory = Directory::new();
        let path = directory.0.join("reopened-with-different-encoding.txt");
        let original = DocumentEncoding::Gbk.encode("中文").unwrap();
        fs::write(&path, &original).unwrap();
        let identity = bytes_identity(&original);

        let outcome = save_document_with_encoding(
            &path,
            "更新",
            Some("中文"),
            Some("GBK"),
            Some("UTF-8"),
            Some(&identity),
        )
        .unwrap();

        assert!(matches!(outcome, SaveOutcome::Saved { .. }));
        assert_eq!(
            read_document_with_encoding(&path, Some("GBK"))
                .unwrap()
                .unwrap()
                .content,
            "更新"
        );
    }

    #[test]
    fn watcher_identity_is_checked_before_decoding_with_current_read_encoding() {
        let directory = Directory::new();
        let path = directory.0.join("reopened-with-different-encoding.txt");
        let original = DocumentEncoding::Gbk.encode("中文").unwrap();
        fs::write(&path, &original).unwrap();
        let identity = bytes_identity(&original);

        assert!(matches!(
            read_document_change(&path, Some("UTF-8"), Some(&identity)).unwrap(),
            DocumentChangeRead::Unchanged
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
    fn explicit_encoding_replaces_invalid_bytes_and_preserves_bom_policy() {
        let directory = Directory::new();
        let invalid = directory.0.join("invalid.txt");
        fs::write(&invalid, [0xFF, 0xFE]).unwrap();
        let decoded = read_document_with_encoding(&invalid, Some("UTF-8"))
            .unwrap()
            .unwrap();
        assert_eq!(decoded.content, "��");
        assert_eq!(decoded.encoding, "UTF-8");

        let bom = directory.0.join("bom.txt");
        fs::write(&bom, DocumentEncoding::Utf8Bom.encode("带 BOM").unwrap()).unwrap();
        let read = read_document_with_encoding(&bom, Some("UTF-8"))
            .unwrap()
            .unwrap();
        assert_eq!(read.content, "带 BOM");
        assert_eq!(read.encoding, "UTF-8");
    }

    #[test]
    fn utf16_documents_are_detected_by_bom_and_round_trip_with_it() {
        let directory = Directory::new();
        // The shape reported in the issue: a UTF-16 LE HTML file with a BOM.
        let text = "<html><body>数据库文档 😀</body></html>";
        for (name, encoding, bom) in [
            ("le.html", DocumentEncoding::Utf16LeBom, [0xFF, 0xFE]),
            ("be.html", DocumentEncoding::Utf16BeBom, [0xFE, 0xFF]),
        ] {
            let path = directory.0.join(name);
            let bytes = encoding.encode(text).unwrap();
            assert_eq!(bytes[..2], bom);
            fs::write(&path, &bytes).unwrap();

            let read = read_document_with_encoding(&path, None).unwrap().unwrap();
            assert_eq!(read.encoding, encoding.label());
            assert_eq!(read.content, text);

            let outcome = save_document_with_encoding(
                &path,
                "changed",
                Some(text),
                Some(encoding.label()),
                Some(encoding.label()),
                Some(&read.identity),
            )
            .unwrap();
            assert!(matches!(outcome, SaveOutcome::Saved { .. }));
            assert_eq!(
                fs::read(&path).unwrap(),
                encoding.encode("changed").unwrap()
            );
        }
    }

    #[test]
    fn utf32_le_bom_is_not_mistaken_for_utf16() {
        let directory = Directory::new();
        let path = directory.0.join("utf32.txt");
        // "A" as UTF-32 LE with BOM: FF FE 00 00 41 00 00 00.
        fs::write(&path, [0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]).unwrap();
        assert!(read_document_with_encoding(&path, None).is_err());
        // A UTF-16 LE file whose first character is U+0000 is the only ambiguous
        // case, and an explicit reopen still reaches it.
        let read = read_document_with_encoding(&path, Some("UTF-16 LE with BOM"))
            .unwrap()
            .unwrap();
        assert_eq!(read.encoding, "UTF-16 LE with BOM");
    }

    #[test]
    fn utf16_decoding_rejects_odd_lengths_and_unpaired_surrogates() {
        assert!(
            DocumentEncoding::Utf16LeBom
                .decode(&[0xFF, 0xFE, 0x41])
                .is_err()
        );
        assert!(
            DocumentEncoding::Utf16LeBom
                .decode(&[0xFF, 0xFE, 0x00, 0xD8])
                .is_err()
        );
        // An explicit reopen stays lossy so a wrong choice remains visible.
        assert_eq!(
            DocumentEncoding::Utf16LeBom.decode_lossy(&[0xFF, 0xFE, 0x41, 0x00, 0x42]),
            "A\u{FFFD}"
        );
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
    #[test]
    fn catalog_has_unique_stable_ids_and_protocol_labels() {
        let mut stable_ids = std::collections::HashSet::new();
        assert_eq!(DocumentEncoding::CATALOG.len(), 16);
        for descriptor in DocumentEncoding::CATALOG {
            assert!(stable_ids.insert(descriptor.stable_id));
            assert!(!descriptor.id.is_empty());
            assert!(descriptor.supports_read || descriptor.supports_write);
            // Every name a caller may send must resolve to the descriptor it belongs to.
            for name in [descriptor.id, descriptor.stable_id]
                .into_iter()
                .chain(descriptor.aliases.iter().copied())
            {
                assert_eq!(
                    DocumentEncoding::parse(Some(name)).unwrap().label(),
                    descriptor.id,
                    "{name}"
                );
            }
        }
    }

    #[test]
    fn common_legacy_and_unmarked_unicode_encodings_round_trip_explicitly() {
        let directory = Directory::new();
        for (label, text, expected) in [
            ("UTF-16 LE", "A中", &[0x41, 0x00, 0x2D, 0x4E][..]),
            ("UTF-16 BE", "A中", &[0x00, 0x41, 0x4E, 0x2D][..]),
            ("Big5", "中文", &[0xA4, 0xA4, 0xA4, 0xE5][..]),
            ("EUC-JP", "日本", &[0xC6, 0xFC, 0xCB, 0xDC][..]),
            ("EUC-KR", "한글", &[0xC7, 0xD1, 0xB1, 0xDB][..]),
            ("Windows-1250", "Łódź", &[0xA3, 0xF3, 0x64, 0x9F][..]),
            (
                "Windows-1251",
                "Привет",
                &[0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2][..],
            ),
            (
                "KOI8-R",
                "Привет",
                &[0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4][..],
            ),
        ] {
            let encoding = DocumentEncoding::parse(Some(label)).unwrap();
            let bytes = encoding.encode(text).unwrap();
            assert_eq!(bytes, expected, "{label}");

            let path = directory.0.join(format!("{}.txt", encoding.label()));
            fs::write(&path, &bytes).unwrap();
            let read = read_document_with_encoding(&path, Some(label))
                .unwrap()
                .unwrap();
            assert_eq!(read.content, text, "{label}");
            assert_eq!(read.encoding, label);
        }
        // Characters the target codec cannot hold are rejected before any bytes are produced.
        assert!(DocumentEncoding::Windows1251.encode("中").is_err());
        assert!(DocumentEncoding::Big5.encode("한").is_err());
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
                Ok(Some(b"old".to_vec()))
            },
            &bytes_identity(b"old"),
            DocumentEncoding::Utf8,
            "new-id".to_owned(),
            |delay| waits.push(delay),
        )
        .unwrap();

        assert!(matches!(outcome, SaveOutcome::Saved { .. }));
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
    fn windows_replace_rechecks_raw_bytes_before_retrying() {
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
            || Ok(Some(b"external".to_vec())),
            &bytes_identity(b"old"),
            DocumentEncoding::Utf8,
            "new-id".to_owned(),
            |delay| waits.push(delay),
        )
        .unwrap();

        assert!(matches!(
            outcome,
            SaveOutcome::Conflict {
                content: Some(ref content),
                ..
            } if content == "external"
        ));
        assert_eq!(attempts, 1);
        assert_eq!(waits, WINDOWS_REPLACE_RETRY_DELAYS[..1].to_vec());
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
            || read_document_bytes(&target),
            &bytes_identity(b"old"),
            DocumentEncoding::Utf8,
            "new-id".to_owned(),
            |_| {
                waits += 1;
                drop(held.take());
            },
        )
        .unwrap();

        assert!(matches!(outcome, SaveOutcome::Saved { .. }));
        assert_eq!(waits, 1);
        assert_eq!(fs::read_to_string(&target).unwrap(), "mine");
        assert!(!staging.exists());
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
                Ok(Some(b"old".to_vec()))
            },
            &bytes_identity(b"old"),
            DocumentEncoding::Utf8,
            "new-id".to_owned(),
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
                Ok(Some(b"old".to_vec()))
            },
            &bytes_identity(b"old"),
            DocumentEncoding::Utf8,
            "new-id".to_owned(),
            |delay| waits.push(delay),
        )
        .unwrap_err();

        assert_eq!(error.raw_os_error(), Some(5));
        assert_eq!(attempts, 1);
        assert_eq!(checks, 0);
        assert!(waits.is_empty());
    }
}
