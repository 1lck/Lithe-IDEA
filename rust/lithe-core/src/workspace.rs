use crate::error::{invalid_relative_path, CoreError, ErrorCode};
use crate::model::{
    FileReadResponse, FileWriteResponse, ReplacementPreviewResponse, SearchMatch, SearchResponse,
    WorkspaceNode, WorkspaceSnapshotResponse,
};
use regex::{Regex, RegexBuilder};
use serde::Deserialize;
use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

const BUILT_IN_HIDDEN_DIRECTORIES: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "build",
    "DerivedData",
    ".gradle",
    ".next",
    "dist",
    "coverage",
    "design-qa-artifacts",
];
const BUILT_IN_HIDDEN_FILE_PATTERNS: &[&str] = &[".DS_Store"];
const MAX_FILE_SIZE: u64 = 2 * 1024 * 1024;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSnapshotRequest {
    pub root: String,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub root: String,
    pub query: String,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub whole_words: bool,
    #[serde(default)]
    pub regular_expression: bool,
    #[serde(default = "default_max_results")]
    pub max_results: usize,
    #[serde(default)]
    pub max_file_results: Option<usize>,
    #[serde(default)]
    pub max_content_results: Option<usize>,
    #[serde(default)]
    pub max_symbol_results: Option<usize>,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
    /// 逗号分隔的文件掩码，如 `*.java, *.kt`。空串表示不过滤。
    #[serde(default)]
    pub file_mask: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplacementPreviewRequest {
    pub root: String,
    pub query: String,
    pub replacement: String,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub whole_words: bool,
    #[serde(default)]
    pub regular_expression: bool,
    /// 保留原命中的大小写形态：全大写、首字母大写、其余照抄替换串。
    #[serde(default)]
    pub preserve_case: bool,
    #[serde(default)]
    pub file_mask: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub text_overrides: HashMap<String, String>,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileReadRequest {
    pub root: String,
    pub path: String,
    #[serde(default)]
    pub format_aware: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileWriteRequest {
    pub root: String,
    pub path: String,
    pub text: String,
    #[serde(default)]
    pub expected_version: Option<String>,
    #[serde(default = "default_line_ending")]
    pub line_ending: String,
    #[serde(default)]
    pub has_utf8_bom: bool,
    #[serde(default)]
    pub create_only: bool,
    #[serde(default)]
    pub format_aware: bool,
}

fn default_max_results() -> usize {
    200
}

fn default_line_ending() -> String {
    "lf".to_string()
}

pub fn snapshot(request: WorkspaceSnapshotRequest) -> Result<WorkspaceSnapshotResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let mut files = Vec::new();
    let node = scan_node(&root, &root, &rules, &mut files)?;
    Ok(WorkspaceSnapshotResponse { root: node, files })
}

pub fn search(request: SearchRequest) -> Result<SearchResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let query = request.query.trim().to_string();
    if query.is_empty() {
        return Ok(SearchResponse {
            matches: Vec::new(),
        });
    }

    let snapshot = snapshot(WorkspaceSnapshotRequest {
        root: root.to_string_lossy().into_owned(),
        hidden_directory_names: request.hidden_directory_names,
        hidden_file_patterns: request.hidden_file_patterns,
    })?;
    let matcher = Matcher::new(
        &query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let masks = parse_file_mask(&request.file_mask);
    let limit = request.max_results.max(1).min(10_000);
    let file_limit = request.max_file_results.unwrap_or(limit).min(limit);
    let content_limit = request.max_content_results.unwrap_or(limit).min(limit);
    let mut matches = Vec::new();
    let mut file_matches = 0;

    for path in &snapshot.files {
        crate::cancellation::check()?;
        if matches.len() >= limit || file_matches >= file_limit {
            break;
        }
        if !file_mask_allows(&masks, path) {
            continue;
        }
        if matcher.matches(path) {
            matches.push(SearchMatch {
                kind: "file".to_string(),
                path: path.clone(),
                line: None,
                preview: path.clone(),
                symbol_name: None,
            });
            file_matches += 1;
        }
    }

    let mut content_matches = 0;
    for path in &snapshot.files {
        crate::cancellation::check()?;
        if matches.len() >= limit || content_matches >= content_limit {
            break;
        }
        if !file_mask_allows(&masks, path) {
            continue;
        }
        let file = root.join(path);
        if !is_readable_text_file(&file) {
            continue;
        }
        let metadata = match fs::metadata(&file) {
            Ok(metadata) if metadata.len() <= MAX_FILE_SIZE => metadata,
            _ => continue,
        };
        if !metadata.is_file() {
            continue;
        }
        let text = match fs::read_to_string(&file) {
            Ok(text) => text,
            Err(_) => continue,
        };
        for (index, line) in text.split('\n').enumerate() {
            crate::cancellation::check()?;
            if matcher.matches(line) {
                matches.push(SearchMatch {
                    kind: "content".to_string(),
                    path: path.clone(),
                    line: Some(index + 1),
                    preview: line.trim().to_string(),
                    symbol_name: None,
                });
                content_matches += 1;
                if matches.len() >= limit {
                    break;
                }
            }
        }
    }

    Ok(SearchResponse { matches })
}

pub fn search_everywhere(request: SearchRequest) -> Result<SearchResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let response = search(request.clone())?;
    let query = request.query.trim().to_string();
    if query.is_empty() {
        return Ok(response);
    }

    let snapshot = snapshot(WorkspaceSnapshotRequest {
        root: root.to_string_lossy().into_owned(),
        hidden_directory_names: request.hidden_directory_names,
        hidden_file_patterns: request.hidden_file_patterns,
    })?;
    let matcher = Matcher::new(
        &query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let symbol_limit = request.max_symbol_results.unwrap_or(50).min(50);
    let mut types = Vec::new();
    let mut symbols = Vec::new();
    for path in snapshot.files {
        crate::cancellation::check()?;
        if types.len() >= symbol_limit && symbols.len() >= symbol_limit {
            break;
        }
        if !path.to_lowercase().ends_with(".java") {
            continue;
        }
        let file = root.join(&path);
        let Ok(text) = fs::read_to_string(&file) else {
            continue;
        };
        for symbol in java_symbols(&path, &text) {
            crate::cancellation::check()?;
            if !matcher.matches(&symbol.name) {
                continue;
            }
            let result = SearchMatch {
                kind: symbol.kind,
                path: path.clone(),
                line: Some(symbol.line),
                preview: symbol.signature,
                symbol_name: Some(symbol.name),
            };
            if result.kind == "type" {
                if types.len() < symbol_limit {
                    types.push(result);
                }
            } else if symbols.len() < symbol_limit {
                symbols.push(result);
            }
        }
    }

    let (file_matches, other_matches): (Vec<_>, Vec<_>) = response
        .matches
        .into_iter()
        .partition(|value| value.kind == "file");
    let mut matches = Vec::new();
    matches.extend(file_matches);
    matches.extend(types);
    matches.extend(symbols);
    matches.extend(other_matches);
    let total_limit = request.max_results.max(1).min(10_000);
    matches.truncate(total_limit);
    Ok(SearchResponse { matches })
}

pub fn replace_preview(
    request: ReplacementPreviewRequest,
) -> Result<ReplacementPreviewResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let query = request.query.trim().to_string();
    if query.is_empty() {
        return Ok(ReplacementPreviewResponse { files: Vec::new() });
    }
    let matcher = Matcher::new(
        &query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let paths = if request.paths.is_empty() {
        snapshot(WorkspaceSnapshotRequest {
            root: root.to_string_lossy().into_owned(),
            hidden_directory_names: request.hidden_directory_names,
            hidden_file_patterns: request.hidden_file_patterns,
        })?
        .files
    } else {
        request.paths
    };
    let masks = parse_file_mask(&request.file_mask);
    let mut files = Vec::new();
    for path in paths {
        crate::cancellation::check()?;
        let relative = safe_relative_path_string(&path)?;
        if !file_mask_allows(&masks, &relative) {
            continue;
        }
        let file = root.join(&relative);
        let text = request
            .text_overrides
            .get(&relative)
            .cloned()
            .or_else(|| read_searchable_text(&file));
        let Some(text) = text else { continue };
        let mut matches = Vec::new();
        let mut replaced_lines = Vec::new();
        for (index, line) in text.split('\n').enumerate() {
            crate::cancellation::check()?;
            let (after, occurrence_count) =
                matcher.replace_with_options(line, &request.replacement, request.preserve_case);
            replaced_lines.push(after.clone());
            if occurrence_count > 0 {
                matches.push(crate::model::ReplacementMatch {
                    line: index + 1,
                    before: line.to_string(),
                    after,
                    occurrence_count,
                });
            }
        }
        if !matches.is_empty() {
            files.push(crate::model::ReplacementFile {
                path: relative,
                matches,
                replacement_text: replaced_lines.join("\n"),
            });
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(ReplacementPreviewResponse { files })
}

pub fn read_file(request: FileReadRequest) -> Result<FileReadResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let path = safe_relative_path(&root, &request.path)?;
    let bytes = fs::read(&path)?;
    let decoded = decode_file_bytes(&bytes)?;
    let text = if request.format_aware {
        decoded.text
    } else {
        std::str::from_utf8(&bytes)
            .map_err(invalid_utf8_error)?
            .to_string()
    };
    Ok(FileReadResponse {
        path: relative_path(&path, &root),
        text,
        version: raw_version(&bytes),
        line_ending: decoded.line_ending.as_str().to_string(),
        has_utf8_bom: decoded.has_utf8_bom,
    })
}

pub fn write_file(request: FileWriteRequest) -> Result<FileWriteResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let path = writable_relative_path(&root, &request.path)?;
    if request.create_only && request.expected_version.is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "createOnly cannot be combined with expectedVersion",
        ));
    }
    let line_ending = if request.format_aware {
        Some(LineEnding::parse(&request.line_ending)?)
    } else {
        None
    };
    verify_write_precondition(
        &path,
        request.expected_version.as_deref(),
        request.create_only,
    )?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let bytes = match line_ending {
        Some(line_ending) => encode_file_bytes(&request.text, line_ending, request.has_utf8_bom),
        None => request.text.into_bytes(),
    };
    let mut temporary = PendingFile::create(path.parent().unwrap_or(&root))?;
    if let Ok(metadata) = fs::metadata(&path) {
        temporary
            .file
            .as_ref()
            .expect("pending save file should be open")
            .set_permissions(metadata.permissions())
            .map_err(write_error)?;
    }
    temporary
        .file
        .as_mut()
        .expect("pending save file should be open")
        .write_all(&bytes)
        .map_err(write_error)?;
    temporary
        .file
        .as_ref()
        .expect("pending save file should be open")
        .sync_all()
        .map_err(write_error)?;
    verify_write_precondition(
        &path,
        request.expected_version.as_deref(),
        request.create_only,
    )?;
    if request.create_only {
        temporary.close()?;
        fs::hard_link(&temporary.path, &path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                external_conflict("File was recreated before the save completed")
            } else {
                write_error(error)
            }
        })?;
    } else {
        temporary.close()?;
        atomic_replace(&temporary.path, &path).map_err(write_error)?;
        temporary.committed = true;
    }
    Ok(FileWriteResponse {
        path: relative_path(&path, &root),
        bytes_written: bytes.len(),
        new_version: raw_version(&bytes),
    })
}

#[derive(Clone, Copy)]
enum LineEnding {
    Lf,
    CrLf,
}

impl LineEnding {
    fn parse(value: &str) -> Result<Self, CoreError> {
        match value {
            "lf" => Ok(Self::Lf),
            "crlf" => Ok(Self::CrLf),
            _ => Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "lineEnding must be lf or crlf",
            )),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Lf => "lf",
            Self::CrLf => "crlf",
        }
    }
}

struct DecodedFile {
    text: String,
    line_ending: LineEnding,
    has_utf8_bom: bool,
}

fn decode_file_bytes(bytes: &[u8]) -> Result<DecodedFile, CoreError> {
    const UTF8_BOM: &[u8] = b"\xEF\xBB\xBF";
    let has_utf8_bom = bytes.starts_with(UTF8_BOM);
    let content = if has_utf8_bom {
        &bytes[UTF8_BOM.len()..]
    } else {
        bytes
    };
    let source = std::str::from_utf8(content).map_err(invalid_utf8_error)?;
    let crlf_count = source.match_indices("\r\n").count();
    let lf_count = source.bytes().filter(|byte| *byte == b'\n').count();
    let line_ending = if crlf_count > lf_count.saturating_sub(crlf_count) {
        LineEnding::CrLf
    } else {
        LineEnding::Lf
    };
    Ok(DecodedFile {
        text: source.replace("\r\n", "\n").replace('\r', "\n"),
        line_ending,
        has_utf8_bom,
    })
}

fn invalid_utf8_error(error: std::str::Utf8Error) -> CoreError {
    CoreError::new(ErrorCode::ParseFailed, "File is not valid UTF-8")
        .with_details(error.to_string())
}

fn encode_file_bytes(text: &str, line_ending: LineEnding, has_utf8_bom: bool) -> Vec<u8> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let encoded = match line_ending {
        LineEnding::Lf => normalized,
        LineEnding::CrLf => normalized.replace('\n', "\r\n"),
    };
    let mut bytes = Vec::with_capacity(encoded.len() + usize::from(has_utf8_bom) * 3);
    if has_utf8_bom {
        bytes.extend_from_slice(b"\xEF\xBB\xBF");
    }
    bytes.extend_from_slice(encoded.as_bytes());
    bytes
}

fn raw_version(bytes: &[u8]) -> String {
    let mut version = String::with_capacity(71);
    version.push_str("sha256:");
    for byte in sha256(bytes) {
        write!(&mut version, "{byte:02x}").expect("writing to a String cannot fail");
    }
    version
}

fn verify_write_precondition(
    path: &Path,
    expected_version: Option<&str>,
    create_only: bool,
) -> Result<(), CoreError> {
    if create_only {
        if path.exists() {
            return Err(external_conflict("File already exists"));
        }
        return Ok(());
    }
    if let Some(expected) = expected_version {
        let current = fs::read(path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                external_conflict("File was deleted outside the editor")
            } else {
                CoreError::from(error)
            }
        })?;
        if raw_version(&current) != expected {
            return Err(external_conflict("File changed outside the editor"));
        }
    }
    Ok(())
}

fn external_conflict(message: &str) -> CoreError {
    CoreError::new(ErrorCode::ExternalConflict, message)
}

fn write_error(error: std::io::Error) -> CoreError {
    CoreError::new(ErrorCode::PermissionDenied, "Could not write file")
        .with_details(error.to_string())
}

static TEMPORARY_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct PendingFile {
    path: PathBuf,
    file: Option<File>,
    committed: bool,
}

impl PendingFile {
    fn create(parent: &Path) -> Result<Self, CoreError> {
        for _ in 0..100 {
            let sequence = TEMPORARY_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!(".lithe-save-{}-{sequence}.tmp", std::process::id()));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => {
                    return Ok(Self {
                        path,
                        file: Some(file),
                        committed: false,
                    })
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(write_error(error)),
            }
        }
        Err(CoreError::new(
            ErrorCode::Unknown,
            "Could not allocate a temporary save file",
        ))
    }

    fn close(&mut self) -> Result<(), CoreError> {
        if let Some(file) = self.file.take() {
            file.sync_all().map_err(write_error)?;
        }
        Ok(())
    }
}

impl Drop for PendingFile {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(windows)]
fn atomic_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;

    #[link(name = "Kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, replacement: *const u16, flags: u32) -> i32;
    }

    let existing = source
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let replacement = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let succeeded = unsafe {
        MoveFileExW(
            existing.as_ptr(),
            replacement.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if succeeded == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn atomic_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    const INITIAL: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    const ROUND: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    let bit_length = (bytes.len() as u64).wrapping_mul(8);
    let mut padded = bytes.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());

    let mut state = INITIAL;
    for chunk in padded.chunks_exact(64) {
        let mut words = [0u32; 64];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            let offset = index * 4;
            *word = u32::from_be_bytes(chunk[offset..offset + 4].try_into().unwrap());
        }
        for index in 16..64 {
            let s0 = words[index - 15].rotate_right(7)
                ^ words[index - 15].rotate_right(18)
                ^ (words[index - 15] >> 3);
            let s1 = words[index - 2].rotate_right(17)
                ^ words[index - 2].rotate_right(19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(s0)
                .wrapping_add(words[index - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for index in 0..64 {
            let sum1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ ((!e) & g);
            let first = h
                .wrapping_add(sum1)
                .wrapping_add(choice)
                .wrapping_add(ROUND[index])
                .wrapping_add(words[index]);
            let sum0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let second = sum0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(first);
            d = c;
            c = b;
            b = a;
            a = first.wrapping_add(second);
        }
        for (value, addition) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *value = value.wrapping_add(addition);
        }
    }

    let mut result = [0u8; 32];
    for (index, word) in state.iter().enumerate() {
        result[index * 4..index * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    result
}

struct VisibilityRules {
    hidden_directories: Vec<String>,
    hidden_file_patterns: Vec<String>,
}

impl VisibilityRules {
    fn new(hidden_directories: Vec<String>, hidden_files: Vec<String>) -> Self {
        let mut directories = BUILT_IN_HIDDEN_DIRECTORIES
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        directories.extend(hidden_directories);
        let mut files = BUILT_IN_HIDDEN_FILE_PATTERNS
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        files.extend(hidden_files);
        Self {
            hidden_directories: normalize(directories),
            hidden_file_patterns: normalize(files),
        }
    }

    fn is_hidden(&self, path: &str, is_directory: bool) -> bool {
        let components = path
            .split('/')
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>();
        if components.iter().any(|component| {
            self.hidden_directories
                .iter()
                .any(|hidden| hidden.eq_ignore_ascii_case(component))
        }) {
            return true;
        }
        if is_directory {
            return false;
        }
        let last = components.last().copied().unwrap_or_default();
        self.hidden_file_patterns
            .iter()
            .any(|pattern| glob_matches(pattern, last) || glob_matches(pattern, path))
    }
}

fn scan_node(
    path: &Path,
    root: &Path,
    rules: &VisibilityRules,
    files: &mut Vec<String>,
) -> Result<WorkspaceNode, CoreError> {
    crate::cancellation::check()?;
    let metadata = fs::symlink_metadata(path)?;
    let relative = relative_path(path, root);
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("Workspace")
        .to_string();
    if !metadata.is_dir() {
        files.push(relative.clone());
        return Ok(WorkspaceNode {
            path: relative,
            name,
            is_directory: false,
            children: None,
        });
    }

    let mut children = fs::read_dir(path)
        .map_err(CoreError::from)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let child_path = entry.path();
            let metadata = fs::symlink_metadata(&child_path).ok()?;
            if metadata.file_type().is_symlink() {
                return None;
            }
            let child_relative = relative_path(&child_path, root);
            if rules.is_hidden(&child_relative, metadata.is_dir()) {
                return None;
            }
            Some((child_path, metadata.is_dir()))
        })
        .collect::<Vec<_>>();
    children.sort_by(|left, right| {
        right.1.cmp(&left.1).then_with(|| {
            left.0
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
                .to_lowercase()
                .cmp(
                    &right
                        .0
                        .file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or_default()
                        .to_lowercase(),
                )
        })
    });

    let mut visible_children = Vec::new();
    for (child_path, _) in children {
        crate::cancellation::check()?;
        if let Ok(child) = scan_node(&child_path, root, rules, files) {
            visible_children.push(child);
        }
    }
    Ok(WorkspaceNode {
        path: relative,
        name,
        is_directory: true,
        children: Some(visible_children),
    })
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    let metadata = fs::metadata(&path)
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Workspace root must be a directory",
        ));
    }
    path.canonicalize().map_err(CoreError::from)
}

fn safe_relative_path(root: &Path, value: &str) -> Result<PathBuf, CoreError> {
    let relative = Path::new(value);
    if relative.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative to the workspace",
        ));
    }
    let path = root.join(relative);
    let canonical = path.canonicalize().map_err(CoreError::from)?;
    if !canonical.starts_with(root) {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Path is outside the workspace",
        ));
    }
    Ok(canonical)
}

fn writable_relative_path(root: &Path, value: &str) -> Result<PathBuf, CoreError> {
    let relative = Path::new(value);
    if relative.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative to the workspace",
        ));
    }
    let path = root.join(relative);
    if let Some(parent) = path.parent() {
        let mut existing_parent = parent;
        while !existing_parent.exists() {
            existing_parent = existing_parent.parent().ok_or_else(|| {
                CoreError::new(ErrorCode::PermissionDenied, "Path is outside the workspace")
            })?;
        }
        let canonical_parent = existing_parent.canonicalize().map_err(CoreError::from)?;
        if !canonical_parent.starts_with(root) {
            return Err(CoreError::new(
                ErrorCode::PermissionDenied,
                "Path is outside the workspace",
            ));
        }
    }
    if let Ok(metadata) = fs::symlink_metadata(&path) {
        if metadata.file_type().is_symlink() {
            return Err(CoreError::new(
                ErrorCode::PermissionDenied,
                "Path is outside the workspace",
            ));
        }
        let canonical = path.canonicalize().map_err(CoreError::from)?;
        if !canonical.starts_with(root) {
            return Err(CoreError::new(
                ErrorCode::PermissionDenied,
                "Path is outside the workspace",
            ));
        }
    }
    Ok(path)
}

fn relative_path(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
        .trim_matches('/')
        .to_string()
}

fn normalize(values: Vec<String>) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        let normalized = value.trim().to_string();
        if normalized.is_empty()
            || result
                .iter()
                .any(|existing: &String| existing.eq_ignore_ascii_case(&normalized))
        {
            continue;
        }
        result.push(normalized);
    }
    result
}

/// 按原命中文本的大小写形态改写替换串，对齐 IDEA 的 Preserve Case：
/// 全大写命中 -> 替换串全大写；首字母大写 -> 替换串首字母大写；
/// 其余形态（含 camelCase、混合大小写）照抄替换串。
fn apply_case_pattern(matched: &str, replacement: &str) -> String {
    let letters = matched.chars().filter(|value| value.is_alphabetic());
    let mut has_lower = false;
    let mut has_upper = false;
    for letter in letters {
        if letter.is_lowercase() {
            has_lower = true;
        } else if letter.is_uppercase() {
            has_upper = true;
        }
    }
    // 没有字母可参考时无从判断形态，照抄。
    if !has_lower && !has_upper {
        return replacement.to_string();
    }
    // 多于一个字母的全大写才算 SCREAMING_CASE，避免把单字母 "F" 误判。
    let letter_count = matched
        .chars()
        .filter(|value| value.is_alphabetic())
        .count();
    if has_upper && !has_lower && letter_count > 1 {
        return replacement.to_uppercase();
    }
    let first_is_upper = matched
        .chars()
        .find(|value| value.is_alphabetic())
        .is_some_and(char::is_uppercase);
    if first_is_upper {
        let mut characters = replacement.chars();
        return match characters.next() {
            Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
            None => String::new(),
        };
    }
    replacement.to_string()
}

/// 把 `*.java, *.kt` 这样的掩码串拆成一组模式；空串返回空表示不过滤。
fn parse_file_mask(mask: &str) -> Vec<String> {
    mask.split(',')
        .map(|part| part.trim())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_string())
        .collect()
}

/// 掩码只针对文件名比对，任一模式命中即通过。
fn file_mask_allows(masks: &[String], path: &str) -> bool {
    if masks.is_empty() {
        return true;
    }
    let name = path.rsplit('/').next().unwrap_or(path);
    masks.iter().any(|mask| glob_matches(mask, name))
}

fn glob_matches(pattern: &str, value: &str) -> bool {
    let pattern = pattern.to_lowercase().chars().collect::<Vec<_>>();
    let value = value.to_lowercase().chars().collect::<Vec<_>>();
    let mut pattern_index = 0;
    let mut value_index = 0;
    let mut star_index = None;
    let mut star_match = 0;
    while value_index < value.len() {
        if pattern_index < pattern.len()
            && (pattern[pattern_index] == value[value_index] || pattern[pattern_index] == '?')
        {
            pattern_index += 1;
            value_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == '*' {
            star_index = Some(pattern_index);
            star_match = value_index;
            pattern_index += 1;
        } else if let Some(star) = star_index {
            pattern_index = star + 1;
            star_match += 1;
            value_index = star_match;
        } else {
            return false;
        }
    }
    while pattern_index < pattern.len() && pattern[pattern_index] == '*' {
        pattern_index += 1;
    }
    pattern_index == pattern.len()
}

struct Matcher {
    plain_query: String,
    regex: Option<Regex>,
    case_sensitive: bool,
    whole_words: bool,
}

impl Matcher {
    fn new(
        query: &str,
        case_sensitive: bool,
        whole_words: bool,
        regular_expression: bool,
    ) -> Result<Self, CoreError> {
        if regular_expression {
            let pattern = query.to_string();
            let regex = RegexBuilder::new(&pattern)
                .case_insensitive(!case_sensitive)
                .build()
                .map_err(|error| {
                    CoreError::new(ErrorCode::ParseFailed, "Invalid search expression")
                        .with_details(error.to_string())
                })?;
            Ok(Self {
                plain_query: query.to_string(),
                regex: Some(regex),
                case_sensitive,
                whole_words: false,
            })
        } else {
            Ok(Self {
                plain_query: query.to_string(),
                regex: None,
                case_sensitive,
                whole_words,
            })
        }
    }

    fn matches(&self, text: &str) -> bool {
        if let Some(regex) = &self.regex {
            return regex.is_match(text);
        }
        let (haystack, needle) = if self.case_sensitive {
            (text.to_string(), self.plain_query.clone())
        } else {
            (text.to_lowercase(), self.plain_query.to_lowercase())
        };
        if !self.whole_words {
            return haystack.contains(&needle);
        }
        haystack.match_indices(&needle).any(|(start, _)| {
            let end = start + needle.len();
            let before = haystack[..start].chars().next_back();
            let after = haystack[end..].chars().next();
            !before.is_some_and(is_word_character) && !after.is_some_and(is_word_character)
        })
    }

    /// `preserve_case` 只作用于字面量替换；正则替换保持原样，
    /// 因为替换串里可能含 `$1` 之类的捕获引用，改写大小写会破坏语义。
    fn replace_with_options(
        &self,
        text: &str,
        replacement: &str,
        preserve_case: bool,
    ) -> (String, usize) {
        if let Some(regex) = &self.regex {
            let count = regex.find_iter(text).count();
            return (regex.replace_all(text, replacement).into_owned(), count);
        }
        let haystack = if self.case_sensitive {
            text.to_string()
        } else {
            text.to_lowercase()
        };
        let needle = if self.case_sensitive {
            self.plain_query.clone()
        } else {
            self.plain_query.to_lowercase()
        };
        if needle.is_empty() {
            return (text.to_string(), 0);
        }
        let ranges = haystack
            .match_indices(&needle)
            .filter_map(|(start, matched)| {
                let end = start + matched.len();
                if self.whole_words {
                    let before = haystack[..start].chars().next_back();
                    let after = haystack[end..].chars().next();
                    if before.is_some_and(is_word_character) || after.is_some_and(is_word_character)
                    {
                        return None;
                    }
                }
                Some((start, end))
            })
            .collect::<Vec<_>>();
        if ranges.is_empty() {
            return (text.to_string(), 0);
        }
        let mut result = String::with_capacity(text.len());
        let mut cursor = 0;
        for (start, end) in &ranges {
            result.push_str(&text[cursor..*start]);
            if preserve_case {
                result.push_str(&apply_case_pattern(&text[*start..*end], replacement));
            } else {
                result.push_str(replacement);
            }
            cursor = *end;
        }
        result.push_str(&text[cursor..]);
        (result, ranges.len())
    }
}

struct JavaSymbol {
    name: String,
    kind: String,
    line: usize,
    signature: String,
}

fn java_symbols(path: &str, source: &str) -> Vec<JavaSymbol> {
    if !path.to_lowercase().ends_with(".java") {
        return Vec::new();
    }
    let type_pattern = Regex::new(
        r"(?m)^[ \t]*(?:(?:public|protected|private|abstract|final|static|sealed|non-sealed)\s+)*(class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)",
    );
    let method_pattern = Regex::new(
        r"(?m)^[ \t]*(?:(?:public|protected|private|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>\n]+>\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+)+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;\n{}]*\)",
    );
    let mut symbols = Vec::new();
    if let Ok(expression) = type_pattern {
        for captures in expression.captures_iter(source) {
            let Some(name) = captures.get(2) else {
                continue;
            };
            let start = captures
                .get(0)
                .map(|value| value.start())
                .unwrap_or(name.start());
            symbols.push(JavaSymbol {
                name: name.as_str().to_string(),
                kind: "type".to_string(),
                line: line_number(source, start),
                signature: line_signature(source, start),
            });
        }
    }
    if let Ok(expression) = method_pattern {
        for captures in expression.captures_iter(source) {
            let Some(name) = captures.get(1) else {
                continue;
            };
            let start = captures
                .get(0)
                .map(|value| value.start())
                .unwrap_or(name.start());
            symbols.push(JavaSymbol {
                name: name.as_str().to_string(),
                kind: "symbol".to_string(),
                line: line_number(source, start),
                signature: line_signature(source, start),
            });
        }
    }
    symbols.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.name.cmp(&right.name))
    });
    symbols
}

fn line_number(source: &str, byte_offset: usize) -> usize {
    source[..byte_offset.min(source.len())]
        .bytes()
        .filter(|byte| *byte == b'\n')
        .count()
        + 1
}

fn line_signature(source: &str, byte_offset: usize) -> String {
    let start = source[..byte_offset.min(source.len())]
        .rfind('\n')
        .map(|index| index + 1)
        .unwrap_or(0);
    let end = source[byte_offset.min(source.len())..]
        .find('\n')
        .map(|index| byte_offset.min(source.len()) + index)
        .unwrap_or(source.len());
    source[start..end].trim().to_string()
}

fn safe_relative_path_string(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    if path.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative to the workspace",
        ));
    }
    Ok(value.replace('\\', "/").trim_matches('/').to_string())
}

fn read_searchable_text(path: &Path) -> Option<String> {
    if !is_readable_text_file(path) || fs::metadata(path).ok()?.len() > MAX_FILE_SIZE {
        return None;
    }
    fs::read_to_string(path).ok()
}

fn is_word_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_' || character == '$'
}

fn is_readable_text_file(path: &Path) -> bool {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_lowercase();
    matches!(
        extension.as_str(),
        "c" | "cc"
            | "cpp"
            | "css"
            | "go"
            | "h"
            | "hpp"
            | "html"
            | "java"
            | "js"
            | "json"
            | "jsx"
            | "kt"
            | "kts"
            | "md"
            | "m"
            | "mm"
            | "php"
            | "plist"
            | "properties"
            | "py"
            | "rb"
            | "rs"
            | "sh"
            | "sql"
            | "swift"
            | "toml"
            | "ts"
            | "tsx"
            | "txt"
            | "xml"
            | "yaml"
            | "yml"
    ) || extension.is_empty()
}
