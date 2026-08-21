use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, Theme, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_opener::OpenerExt;

static WINDOW_ID: AtomicU64 = AtomicU64::new(1);

// Windows 11 taskbar downscales a 256-only ICO into an empty pill. Use the 32px
// asset after window creation so frameless windows keep a readable app icon.
const WINDOW_TASKBAR_ICON: tauri::image::Image<'_> = tauri::include_image!("./icons/32x32.png");

pub fn apply_window_taskbar_icon(window: &WebviewWindow) {
    if let Err(error) = window.set_icon(WINDOW_TASKBAR_ICON.clone()) {
        eprintln!("[host] failed to set window icon: {error}");
    }
}

#[derive(Debug, Serialize)]
pub struct FontInfo {
    name: String,
    family: String,
    style: String,
    is_monospace: bool,
}

#[derive(Debug, Serialize)]
pub struct SymlinkInfo {
    is_symlink: bool,
    target: Option<String>,
    is_dir: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoundedFileRead {
    bytes: Vec<u8>,
    truncated: bool,
}

pub struct PendingCliOpenRequests(Mutex<Vec<Value>>);

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ClipboardEntry {
    path: PathBuf,
    is_dir: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ClipboardOperation {
    Copy,
    Cut,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct FileClipboardState {
    entries: Vec<ClipboardEntry>,
    operation: ClipboardOperation,
}

#[derive(Default)]
pub struct FileClipboard(Mutex<Option<FileClipboardState>>);

#[derive(Debug, Serialize)]
pub struct PastedEntry {
    source_path: PathBuf,
    destination_path: PathBuf,
    is_dir: bool,
}

impl PendingCliOpenRequests {
    pub fn from_arguments(arguments: impl IntoIterator<Item = String>) -> Self {
        Self(Mutex::new(cli_payloads(arguments)))
    }
}

pub fn enqueue_cli_arguments(app: &AppHandle, arguments: Vec<String>) {
    let state = app.state::<PendingCliOpenRequests>();
    if let Ok(mut pending) = state.0.lock() {
        pending.extend(cli_payloads(arguments.into_iter().skip(1)));
    };
}

#[tauri::command]
pub fn take_pending_cli_open_requests(
    state: tauri::State<'_, PendingCliOpenRequests>,
) -> Vec<Value> {
    state
        .0
        .lock()
        .map(|mut pending| pending.drain(..).collect())
        .unwrap_or_default()
}

fn cli_payloads(arguments: impl IntoIterator<Item = String>) -> Vec<Value> {
    arguments
        .into_iter()
        .filter(|argument| !argument.starts_with('-'))
        .map(|argument| {
            if argument.starts_with("http://") || argument.starts_with("https://") {
                serde_json::json!({ "kind": "web", "url": argument })
            } else {
                let path = PathBuf::from(&argument);
                serde_json::json!({
                    "kind": "path",
                    "path": argument,
                    "is_directory": path.is_dir()
                })
            }
        })
        .collect()
}

#[tauri::command]
pub fn clipboard_set(
    app: AppHandle,
    state: tauri::State<'_, FileClipboard>,
    entries: Vec<ClipboardEntry>,
    operation: ClipboardOperation,
) -> Result<(), String> {
    if entries.is_empty() {
        return Err("File clipboard requires at least one entry".into());
    }
    for entry in &entries {
        if !entry.path.exists() {
            return Err(format!(
                "Clipboard source does not exist: {}",
                entry.path.display()
            ));
        }
    }
    let clipboard = FileClipboardState { entries, operation };
    *state
        .0
        .lock()
        .map_err(|_| "File clipboard lock was poisoned")? = Some(clipboard.clone());
    app.emit("file-clipboard-changed", clipboard)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn clipboard_get(
    state: tauri::State<'_, FileClipboard>,
) -> Result<Option<FileClipboardState>, String> {
    state
        .0
        .lock()
        .map(|value| value.clone())
        .map_err(|_| "File clipboard lock was poisoned".into())
}

#[tauri::command]
pub fn clipboard_clear(
    app: AppHandle,
    state: tauri::State<'_, FileClipboard>,
) -> Result<(), String> {
    *state
        .0
        .lock()
        .map_err(|_| "File clipboard lock was poisoned")? = None;
    app.emit("file-clipboard-cleared", ())
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn clipboard_paste(
    app: AppHandle,
    state: tauri::State<'_, FileClipboard>,
    target_directory: PathBuf,
) -> Result<Vec<PastedEntry>, String> {
    if !target_directory.is_dir() {
        return Err("Clipboard target must be an existing directory".into());
    }
    let clipboard = state
        .0
        .lock()
        .map_err(|_| "File clipboard lock was poisoned")?
        .clone()
        .ok_or_else(|| "File clipboard is empty".to_string())?;
    let mut pasted = Vec::new();
    for entry in &clipboard.entries {
        let name = entry
            .path
            .file_name()
            .ok_or_else(|| "Clipboard source requires a file name".to_string())?;
        let destination = unique_destination(target_directory.join(name));
        match clipboard.operation {
            ClipboardOperation::Copy => copy_path(&entry.path, &destination)?,
            ClipboardOperation::Cut => {
                fs::rename(&entry.path, &destination).map_err(|error| error.to_string())?
            }
        }
        pasted.push(PastedEntry {
            source_path: entry.path.clone(),
            destination_path: destination,
            is_dir: entry.is_dir,
        });
    }
    if matches!(clipboard.operation, ClipboardOperation::Cut) {
        *state
            .0
            .lock()
            .map_err(|_| "File clipboard lock was poisoned")? = None;
        app.emit("file-clipboard-cleared", ())
            .map_err(|error| error.to_string())?;
    }
    Ok(pasted)
}

fn unique_destination(path: PathBuf) -> PathBuf {
    if !path.exists() {
        return path;
    }
    let parent = path.parent().unwrap_or_else(|| std::path::Path::new(""));
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("copy");
    let extension = path.extension().and_then(|value| value.to_str());
    for index in 1.. {
        let suffix = if index == 1 {
            " copy".into()
        } else {
            format!(" copy {index}")
        };
        let mut name = format!("{stem}{suffix}");
        if let Some(extension) = extension {
            name.push('.');
            name.push_str(extension);
        }
        let candidate = parent.join(name);
        if !candidate.exists() {
            return candidate;
        }
    }
    unreachable!()
}

fn copy_path(source: &std::path::Path, destination: &std::path::Path) -> Result<(), String> {
    if source.is_dir() {
        fs::create_dir(destination).map_err(|error| error.to_string())?;
        for entry in fs::read_dir(source).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            copy_path(&entry.path(), &destination.join(entry.file_name()))?;
        }
    } else {
        fs::copy(source, destination).map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn create_app_window(app: AppHandle, request: Option<Value>) -> Result<String, String> {
    let label = format!("workspace-{}", WINDOW_ID.fetch_add(1, Ordering::Relaxed));
    let mut query = url::form_urlencoded::Serializer::new(String::new());
    if let Some(request) = request.and_then(|value| value.as_object().cloned()) {
        query.append_pair("target", "open");
        if let Some(value) = request.get("type").and_then(Value::as_str) {
            query.append_pair("type", value);
        }
        for (source, target) in [
            ("path", "path"),
            ("remoteConnectionId", "connectionId"),
            ("remoteConnectionName", "name"),
            ("url", "url"),
            ("command", "command"),
            ("workingDirectory", "cwd"),
        ] {
            if let Some(value) = request.get(source).and_then(Value::as_str) {
                query.append_pair(target, value);
            }
        }
        if request.get("isDirectory").and_then(Value::as_bool) == Some(true) {
            query.append_pair("type", "directory");
        }
        if let Some(value) = request.get("line").and_then(Value::as_u64) {
            query.append_pair("line", &value.to_string());
        }
        if let Some(value) = request.get("column").and_then(Value::as_u64) {
            query.append_pair("column", &value.to_string());
        }
    }
    let query = query.finish();
    let path = if query.is_empty() {
        "index.html".to_string()
    } else {
        format!("index.html?{query}")
    };
    let window = WebviewWindowBuilder::new(&app, &label, WebviewUrl::App(path.into()))
        .title("Lithe")
        .decorations(false)
        .inner_size(1280.0, 800.0)
        .min_inner_size(720.0, 480.0)
        .icon(WINDOW_TASKBAR_ICON)
        .map_err(|error| error.to_string())?
        .build()
        .map_err(|error| error.to_string())?;
    apply_window_taskbar_icon(&window);
    Ok(label)
}

#[cfg(test)]
mod tests {
    use super::{
        cli_payloads, copy_path, create_app_window, read_bounded, read_local_file_bounded,
        unique_destination, WINDOW_TASKBAR_ICON,
    };
    use std::fs;
    use std::future::Future;
    use std::io::Read;
    use std::path::PathBuf;

    struct CountingReader {
        bytes_read: usize,
        bytes_remaining: usize,
    }

    impl Read for CountingReader {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let count = buffer.len().min(self.bytes_remaining);
            buffer[..count].fill(b'x');
            self.bytes_read += count;
            self.bytes_remaining -= count;
            Ok(count)
        }
    }

    fn assert_async_window_command<F, Fut>(_command: F)
    where
        F: Fn(tauri::AppHandle, Option<serde_json::Value>) -> Fut,
        Fut: Future<Output = Result<String, String>>,
    {
    }

    #[test]
    fn creates_app_windows_outside_the_synchronous_ipc_handler() {
        assert_async_window_command(create_app_window);
    }

    #[test]
    fn parses_path_and_web_cli_arguments() {
        let payloads = cli_payloads([
            "--flag".to_string(),
            "C:/project".to_string(),
            "https://example.invalid".to_string(),
        ]);
        assert_eq!(payloads.len(), 2);
        assert_eq!(payloads[0]["kind"], "path");
        assert_eq!(payloads[1]["kind"], "web");
    }

    #[test]
    fn copies_directories_and_chooses_non_destructive_destination() {
        let root = std::env::temp_dir().join(format!(
            "lithe-host-copy-{}-{}",
            std::process::id(),
            super::WINDOW_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let source = root.join("source");
        let target = root.join("target");
        fs::create_dir_all(source.join("nested")).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(source.join("nested/file.txt"), "content").unwrap();

        let destination = target.join("source");
        copy_path(&source, &destination).unwrap();
        assert_eq!(
            fs::read_to_string(destination.join("nested/file.txt")).unwrap(),
            "content"
        );
        assert_eq!(unique_destination(destination), target.join("source copy"));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_reader_consumes_only_one_sentinel_byte_beyond_the_payload_limit() {
        let limit = 16;
        let mut reader = CountingReader {
            bytes_read: 0,
            bytes_remaining: limit + 32,
        };

        let result = read_bounded(&mut reader, limit).unwrap();

        assert!(result.truncated);
        assert_eq!(reader.bytes_read, limit + 1);
        assert_eq!(result.bytes.len(), limit);
    }

    #[test]
    fn bounded_local_file_omits_oversized_content_from_the_ipc_payload() {
        let limit = 16;
        let path = std::env::temp_dir().join(format!(
            "lithe-host-bounded-read-{}-{}",
            std::process::id(),
            super::WINDOW_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::write(&path, vec![b'x'; limit + 32]).unwrap();

        let result = read_local_file_bounded(path.clone(), limit).unwrap();
        let payload = serde_json::to_value(&result).unwrap();

        assert!(result.truncated);
        assert!(result.bytes.is_empty());
        assert!(payload["bytes"].as_array().unwrap().len() <= limit);

        fs::remove_file(path).unwrap();
    }

    #[test]
    fn bundled_windows_icon_includes_taskbar_sizes() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("icons/icon.ico");
        let data = fs::read(path).unwrap();
        assert!(data.len() >= 6);
        let count = u16::from_le_bytes(data[4..6].try_into().unwrap()) as usize;
        let mut widths = Vec::new();
        let mut offset = 6usize;
        for _ in 0..count {
            let width = match data[offset] {
                0 => 256,
                value => u32::from(value),
            };
            widths.push(width);
            offset += 16;
        }
        assert!(widths.contains(&16), "{widths:?}");
        assert!(widths.contains(&32), "{widths:?}");
        assert!(widths.contains(&256), "{widths:?}");
    }

    #[test]
    fn taskbar_icon_fills_available_canvas() {
        let width = WINDOW_TASKBAR_ICON.width();
        let height = WINDOW_TASKBAR_ICON.height();
        assert_eq!((width, height), (32, 32));

        let mut min_x = width;
        let mut min_y = height;
        let mut max_x = 0;
        let mut max_y = 0;
        for (index, pixel) in WINDOW_TASKBAR_ICON.rgba().chunks_exact(4).enumerate() {
            if pixel[3] < 128 {
                continue;
            }

            let x = index as u32 % width;
            let y = index as u32 / width;
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x);
            max_y = max_y.max(y);
        }

        let visible_width = max_x.saturating_sub(min_x) + 1;
        let visible_height = max_y.saturating_sub(min_y) + 1;
        assert!(visible_width >= 26, "visible width: {visible_width}");
        assert!(visible_height >= 26, "visible height: {visible_height}");
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn background_font_queries_do_not_create_windows_console() {
        assert_eq!(super::font_query_process_creation_flags(), 0x0800_0000);
    }
}

#[tauri::command]
pub fn get_system_theme(window: WebviewWindow) -> String {
    match window.theme() {
        Ok(Theme::Light) => "light".into(),
        _ => "dark".into(),
    }
}

#[tauri::command]
pub fn set_native_window_appearance(
    window: WebviewWindow,
    theme_type: String,
) -> Result<(), String> {
    let theme = match theme_type.as_str() {
        "light" => Theme::Light,
        "dark" => Theme::Dark,
        _ => return Err("Window theme must be light or dark".into()),
    };
    window
        .set_theme(Some(theme))
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn get_system_fonts() -> Vec<FontInfo> {
    platform_fonts()
}

#[tauri::command]
pub fn get_monospace_fonts() -> Vec<FontInfo> {
    platform_fonts()
        .into_iter()
        .filter(|font| font.is_monospace)
        .collect()
}

#[tauri::command]
pub fn validate_font(font_family: String) -> bool {
    platform_fonts()
        .iter()
        .any(|font| font.family.eq_ignore_ascii_case(font_family.trim()))
}

#[cfg(target_os = "windows")]
fn platform_fonts() -> Vec<FontInfo> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    let mut command = Command::new("reg.exe");
    command
        .args([
            "query",
            r"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
        ])
        .creation_flags(font_query_process_creation_flags());
    let output = command.output();
    let text = output
        .ok()
        .filter(|value| value.status.success())
        .map(|value| String::from_utf8_lossy(&value.stdout).into_owned())
        .unwrap_or_default();
    let mut families = text
        .lines()
        .filter_map(|line| line.split("    REG_").next())
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("HKEY_"))
        .map(|name| {
            name.trim_end_matches(" (TrueType)")
                .trim_end_matches(" (OpenType)")
        })
        .map(str::to_string)
        .collect::<Vec<_>>();
    families.extend(["Geist Sans".into(), "Geist Mono".into()]);
    families.sort_by_key(|name| name.to_lowercase());
    families.dedup_by(|left, right| left.eq_ignore_ascii_case(right));
    families
        .into_iter()
        .map(|family| FontInfo {
            is_monospace: is_probably_monospace(&family),
            name: family.clone(),
            family,
            style: "Regular".into(),
        })
        .collect()
}

#[cfg(target_os = "windows")]
fn font_query_process_creation_flags() -> u32 {
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    CREATE_NO_WINDOW
}

#[cfg(not(target_os = "windows"))]
fn platform_fonts() -> Vec<FontInfo> {
    [
        ("Geist Sans", false),
        ("Geist Mono", true),
        ("Menlo", true),
        ("SF Mono", true),
    ]
    .into_iter()
    .map(|(family, is_monospace)| FontInfo {
        name: family.into(),
        family: family.into(),
        style: "Regular".into(),
        is_monospace,
    })
    .collect()
}

#[cfg(target_os = "windows")]
fn is_probably_monospace(name: &str) -> bool {
    let lower = name.to_lowercase();
    ["mono", "code", "console", "courier", "fixed", "terminal"]
        .iter()
        .any(|token| lower.contains(token))
}

#[tauri::command]
pub fn get_bundled_extensions_path(app: AppHandle) -> Result<String, String> {
    app.path()
        .resource_dir()
        .map(|path| {
            path.join("extensions/bundled")
                .to_string_lossy()
                .into_owned()
        })
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn read_local_file(path: PathBuf) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|error| error.to_string())
}

fn read_bounded(reader: &mut impl Read, max_bytes: usize) -> io::Result<BoundedFileRead> {
    let sentinel_limit = max_bytes
        .checked_add(1)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Byte limit is too large"))?;
    let read_limit = u64::try_from(sentinel_limit)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Byte limit is too large"))?;
    let mut bytes = Vec::new();
    reader.take(read_limit).read_to_end(&mut bytes)?;
    let truncated = bytes.len() > max_bytes;
    bytes.truncate(max_bytes);
    Ok(BoundedFileRead { bytes, truncated })
}

fn read_local_file_bounded_from_path(path: &Path, max_bytes: usize) -> io::Result<BoundedFileRead> {
    let mut file = File::open(path)?;
    let max_bytes_u64 = u64::try_from(max_bytes).unwrap_or(u64::MAX);
    // Metadata avoids reading known oversized files; the sentinel byte below covers later growth.
    if file.metadata()?.len() > max_bytes_u64 {
        return Ok(BoundedFileRead {
            bytes: Vec::new(),
            truncated: true,
        });
    }
    read_bounded(&mut file, max_bytes)
}

#[tauri::command]
pub fn read_local_file_bounded(path: PathBuf, max_bytes: usize) -> Result<BoundedFileRead, String> {
    read_local_file_bounded_from_path(&path, max_bytes).map_err(|error| error.to_string())
}

#[tauri::command]
pub fn read_file_custom(path: PathBuf) -> Result<String, String> {
    fs::read_to_string(path).map_err(|error| error.to_string())
}

#[tauri::command]
pub fn write_file(path: PathBuf, contents: String) -> Result<(), String> {
    fs::write(path, contents).map_err(|error| error.to_string())
}

#[tauri::command]
pub fn move_file(source_path: PathBuf, target_path: PathBuf) -> Result<(), String> {
    fs::rename(source_path, target_path).map_err(|error| error.to_string())
}

#[tauri::command]
pub fn rename_file(source_path: PathBuf, target_path: PathBuf) -> Result<(), String> {
    fs::rename(source_path, target_path).map_err(|error| error.to_string())
}

#[tauri::command]
pub fn get_symlink_info(path: PathBuf) -> Result<SymlinkInfo, String> {
    let metadata = fs::symlink_metadata(&path).map_err(|error| error.to_string())?;
    let is_symlink = metadata.file_type().is_symlink();
    let target = if is_symlink {
        Some(
            fs::read_link(&path)
                .map_err(|error| error.to_string())?
                .to_string_lossy()
                .into_owned(),
        )
    } else {
        None
    };
    Ok(SymlinkInfo {
        is_symlink,
        target,
        is_dir: metadata.is_dir(),
    })
}

#[tauri::command]
pub fn open_file_external(app: AppHandle, path: String) -> Result<(), String> {
    app.opener()
        .open_path(path, None::<&str>)
        .map_err(|error| error.to_string())
}
