//! 应用文件日志与「日志与诊断」设置页的数据源。
//!
//! Tauri 版的日志由宿主进程通过 `queryLitheLogs` 等命令提供；GPUI 版没有这层
//! 宿主，所以在功能层内维护同一套语义：
//!
//! - 每次进程启动创建 `lithe-<时间戳>.log`，时间线按「当前 / 上一次 / 全部会话」
//!   选择文件；
//! - 日志行是 `时间戳 级别 [模块] 内容`，模块与最低级别过滤在读取时进行；
//! - 自定义位置保存的是**父目录**，实际写入 `<父目录>/Lithe/logs`，与 Tauri
//!   的提示文案一致；
//! - 详细诊断只对所选模块生效，15 分钟后按过期时间自动关闭；
//! - 诊断包是 zip，含筛选后的日志文件、`manifest.json` 和 `environment.json`，
//!   导出前把用户目录替换成 `~`。
//!
//! 所有函数都是阻塞 I/O，调用方在 UI 线程执行时只能处理小文件；查询上限
//! [`MAX_TIMELINE_BYTES`] 保证读取不会无限增长。

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, SecondsFormat, Utc};

/// 时间线最多返回的内容，与 Tauri 的 200_000 字节对齐。
const MAX_TIMELINE_BYTES: usize = 200_000;
/// 详细诊断的有效时长。
const DIAGNOSTIC_TTL: Duration = Duration::from_secs(15 * 60);
/// 日志文件前缀；清理时只删除这个前缀的文件。
const LOG_FILE_PREFIX: &str = "lithe-";
const LOG_FILE_SUFFIX: &str = ".log";
/// 日志设置文件名，与 `settings.json` 放在同一个应用数据目录。
const LOG_SETTINGS_FILE: &str = "log-settings.json";

/// 日志级别，顺序用于「最低级别」过滤。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    pub fn label(self) -> &'static str {
        match self {
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
        }
    }

    fn from_label(label: &str) -> Option<Self> {
        match label {
            "DEBUG" => Some(Level::Debug),
            "INFO" => Some(Level::Info),
            "WARN" => Some(Level::Warn),
            "ERROR" => Some(Level::Error),
            _ => None,
        }
    }
}

/// 页面上的时间线筛选条件。
#[derive(Clone, Debug)]
pub struct LogSelection {
    /// `None` 表示全部模块。
    pub category: Option<String>,
    /// `"current"`、`"previous"` 或 `"all"`。
    pub session: String,
    /// `"debug"`、`"info"`、`"warn"` 或 `"error"`。
    pub minimum_level: String,
    pub search: Option<String>,
    pub since: Option<String>,
    pub until: Option<String>,
}

impl Default for LogSelection {
    fn default() -> Self {
        Self {
            category: None,
            session: "current".to_string(),
            minimum_level: "info".to_string(),
            search: None,
            since: None,
            until: None,
        }
    }
}

impl LogSelection {
    fn minimum_level(&self) -> Level {
        match self.minimum_level.as_str() {
            "debug" => Level::Debug,
            "warn" => Level::Warn,
            "error" => Level::Error,
            _ => Level::Info,
        }
    }
}

/// 一次日志查询的结果。
#[derive(Clone, Debug, Default)]
pub struct LogTimeline {
    pub content: String,
    pub truncated: bool,
}

/// 日志设置快照，字段与 Tauri 的 `LogSettingsSnapshot` 对应。
#[derive(Clone, Debug, Default)]
pub struct LogSettingsSnapshot {
    pub configured_directory: Option<PathBuf>,
    pub default_path: PathBuf,
    pub effective_path: PathBuf,
    /// `"loggingUnavailable"`、`"notWritable"`、`"unavailable"` 或 `None`。
    pub fallback_reason: Option<&'static str>,
    pub diagnostic_enabled: bool,
    pub diagnostic_category: Option<String>,
    pub dropped_events: u64,
    pub write_failures: u64,
}

/// 诊断包中的一个文件。
#[derive(Clone, Debug)]
pub struct BundleEntry {
    pub relative_path: String,
    pub size_bytes: u64,
}

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct LogConfiguration {
    custom_directory: Option<String>,
    diagnostic_enabled: bool,
    diagnostic_category: Option<String>,
    /// Unix 秒；`None` 表示没有开启诊断。
    diagnostic_expires_at: Option<u64>,
}

impl LogConfiguration {
    fn is_diagnostic_active(&self) -> bool {
        if !self.diagnostic_enabled {
            return false;
        }
        match self.diagnostic_expires_at {
            Some(expires_at) => now_seconds() < expires_at,
            None => false,
        }
    }

    fn clear_diagnostic(&mut self) {
        self.diagnostic_enabled = false;
        self.diagnostic_category = None;
        self.diagnostic_expires_at = None;
    }
}

struct LoggerState {
    directory: PathBuf,
    session_path: PathBuf,
    fallback_reason: Option<&'static str>,
    dropped_events: u64,
    write_failures: u64,
    configuration: LogConfiguration,
}

static LOGGER: OnceLock<Mutex<LoggerState>> = OnceLock::new();

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn timestamp() -> String {
    let now: DateTime<Utc> = SystemTime::now().into();
    now.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// 当天日期（UTC），用于诊断包默认文件名。
pub fn today() -> String {
    let now: DateTime<Utc> = SystemTime::now().into();
    now.format("%Y-%m-%d").to_string()
}

/// 应用数据目录；与 `settings.rs` 的约定完全一致。
pub(crate) fn app_data_dir() -> Option<PathBuf> {
    crate::settings::app_data_dir()
}

fn default_log_directory() -> PathBuf {
    app_data_dir()
        .unwrap_or_else(|| std::env::temp_dir().join("Lithe"))
        .join("logs")
}

fn configuration_path() -> PathBuf {
    app_data_dir()
        .unwrap_or_else(|| std::env::temp_dir().join("Lithe"))
        .join(LOG_SETTINGS_FILE)
}

fn load_configuration() -> LogConfiguration {
    let path = configuration_path();
    let Ok(text) = fs::read_to_string(&path) else {
        return LogConfiguration::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn save_configuration(configuration: &LogConfiguration) {
    let path = configuration_path();
    let Some(parent) = path.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    let Ok(text) = serde_json::to_string_pretty(configuration) else {
        return;
    };
    let temporary = path.with_extension("json.tmp");
    if fs::write(&temporary, text).is_ok() {
        let _ = fs::rename(&temporary, &path);
    }
}

/// 自定义父目录 → 实际日志目录。
fn effective_directory_for(configuration: &LogConfiguration) -> PathBuf {
    match configuration
        .custom_directory
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(custom) => PathBuf::from(custom).join("Lithe").join("logs"),
        None => default_log_directory(),
    }
}

fn session_file_name() -> String {
    let now: DateTime<Utc> = SystemTime::now().into();
    format!(
        "{LOG_FILE_PREFIX}{}{LOG_FILE_SUFFIX}",
        now.format("%Y%m%d-%H%M%S")
    )
}

fn directory_is_writable(directory: &Path) -> bool {
    if fs::create_dir_all(directory).is_err() {
        return false;
    }
    let probe = directory.join(".lithe-log-write-probe");
    let writable = fs::write(&probe, b"probe").is_ok();
    let _ = fs::remove_file(&probe);
    writable
}

/// 进程启动时调用一次；重复调用直接返回。
///
/// 目录不可写时回退到默认位置并记录 `fallback_reason`，日志页会把原因显示在
/// 「当前日志位置」的说明里（与 Tauri 一致）。
pub fn init() {
    let mut configuration = load_configuration();
    if configuration.diagnostic_enabled && !configuration.is_diagnostic_active() {
        configuration.clear_diagnostic();
        save_configuration(&configuration);
    }

    let default_directory = default_log_directory();
    let mut fallback_reason = None;
    let mut directory = effective_directory_for(&configuration);
    if directory != default_directory && !directory_is_writable(&directory) {
        fallback_reason = Some("notWritable");
        directory = default_directory.clone();
    }
    if !directory_is_writable(&directory) {
        fallback_reason = Some("loggingUnavailable");
    }

    let session_path = if fallback_reason == Some("loggingUnavailable") {
        directory.join(session_file_name())
    } else {
        let path = directory.join(session_file_name());
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = OpenOptions::new().create(true).append(true).open(&path);
        path
    };

    let state = LoggerState {
        directory,
        session_path,
        fallback_reason,
        dropped_events: 0,
        write_failures: 0,
        configuration,
    };
    let _ = LOGGER.set(Mutex::new(state));
    if let Some(reason) = fallback_reason {
        log_event(Level::Warn, "app", format!("log directory fallback: {reason}"));
    }
    log_event(Level::Info, "app", "Lithe started");
}

fn with_state<T>(handler: impl FnOnce(&mut LoggerState) -> T) -> Option<T> {
    let mutex = LOGGER.get()?;
    let mut state = mutex.lock().ok()?;
    Some(handler(&mut state))
}

/// 追加一条日志。
///
/// `category` 使用页面上的模块 id：`app`、`language`、`run`、`git`、`plugins`
/// 或 `performance`。`DEBUG` 只在详细诊断覆盖该模块时写入。
pub fn log_event(level: Level, category: &str, message: impl AsRef<str>) {
    with_state(|state| {
        if level == Level::Debug {
            let configuration = &state.configuration;
            let covered = configuration.is_diagnostic_active()
                && configuration
                    .diagnostic_category
                    .as_deref()
                    .is_none_or(|selected| selected == category);
            if !covered {
                return;
            }
        }
        if state.fallback_reason == Some("loggingUnavailable") {
            state.write_failures = state.write_failures.saturating_add(1);
            return;
        }
        let line = format!(
            "{} {} [{}] {}\n",
            timestamp(),
            level.label(),
            category,
            message.as_ref()
        );
        let result = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&state.session_path)
            .and_then(|mut file| file.write_all(line.as_bytes()));
        if result.is_err() {
            state.write_failures = state.write_failures.saturating_add(1);
        }
    });
}

pub fn log_info(category: &str, message: impl AsRef<str>) {
    log_event(Level::Info, category, message);
}

/// 当前会话的日志文件。
pub fn current_log_file() -> Option<PathBuf> {
    with_state(|state| state.session_path.clone())
}

/// 日志目录下的全部会话文件，按文件名（时间戳）升序。
fn session_files(directory: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    name.starts_with(LOG_FILE_PREFIX) && name.ends_with(LOG_FILE_SUFFIX)
                })
        })
        .collect();
    files.sort();
    files
}

fn read_file_text(path: &Path) -> String {
    let mut text = String::new();
    if let Ok(mut file) = File::open(path) {
        let _ = file.read_to_string(&mut text);
    }
    text
}

fn category_matches(line: &str, selected: &str) -> bool {
    let Some(open) = line.find('[') else {
        return false;
    };
    let Some(close) = line[open..].find(']') else {
        return false;
    };
    let category = &line[open + 1..open + close];
    match selected {
        "application" => category == "app",
        other => category == other,
    }
}

fn line_matches(line: &str, selection: &LogSelection) -> bool {
    let lower = line.to_lowercase();
    if let Some(search) = selection
        .search
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if !lower.contains(&search.to_lowercase()) {
            return false;
        }
    }
    if let Some(category) = selection.category.as_deref() {
        if !category_matches(line, category) {
            return false;
        }
    }
    let mut parts = line.splitn(3, ' ');
    let timestamp = parts.next().unwrap_or_default();
    let level = parts.next().and_then(Level::from_label);
    if level.is_some_and(|level| level < selection.minimum_level()) {
        return false;
    }
    if let Some(since) = selection
        .since
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if timestamp < since {
            return false;
        }
    }
    if let Some(until) = selection
        .until
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if timestamp > until {
            return false;
        }
    }
    true
}

/// 把筛选后的文本收敛到 [`MAX_TIMELINE_BYTES`]；从尾部保留最近的记录。
fn truncate_content(mut content: String) -> (String, bool) {
    if content.len() <= MAX_TIMELINE_BYTES {
        return (content, false);
    }
    let mut start = content.len() - MAX_TIMELINE_BYTES;
    while start < content.len() && !content.is_char_boundary(start) {
        start += 1;
    }
    content.drain(..start);
    (content, true)
}

/// 按当前选择读取时间线。
pub fn query_logs(selection: &LogSelection) -> LogTimeline {
    let Some((directory, current)) = with_state(|state| {
        let configuration = &mut state.configuration;
        if configuration.diagnostic_enabled && !configuration.is_diagnostic_active() {
            configuration.clear_diagnostic();
            save_configuration(configuration);
        }
        (state.directory.clone(), state.session_path.clone())
    }) else {
        return LogTimeline::default();
    };

    let files = session_files(&directory);
    let selected: Vec<PathBuf> = match selection.session.as_str() {
        "previous" => files
            .iter()
            .filter(|path| **path != current)
            .next_back()
            .cloned()
            .into_iter()
            .collect(),
        "all" => files,
        _ => {
            if files.iter().any(|path| *path == current) {
                vec![current]
            } else {
                files.last().cloned().into_iter().collect()
            }
        }
    };

    let mut content = String::new();
    for path in selected {
        for line in read_file_text(&path).lines() {
            if line_matches(line, selection) {
                content.push_str(line);
                content.push('\n');
            }
        }
    }
    let (content, truncated) = truncate_content(content);
    LogTimeline { content, truncated }
}

/// 当前日志设置快照。
pub fn settings_snapshot() -> LogSettingsSnapshot {
    let default_path = default_log_directory();
    with_state(|state| {
        let configuration = &mut state.configuration;
        if configuration.diagnostic_enabled && !configuration.is_diagnostic_active() {
            configuration.clear_diagnostic();
            save_configuration(configuration);
        }
        LogSettingsSnapshot {
            configured_directory: configuration
                .custom_directory
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(PathBuf::from),
            default_path: default_path.clone(),
            effective_path: state.directory.clone(),
            fallback_reason: state.fallback_reason,
            diagnostic_enabled: configuration.is_diagnostic_active(),
            diagnostic_category: configuration
                .diagnostic_category
                .clone()
                .filter(|_| configuration.is_diagnostic_active()),
            dropped_events: state.dropped_events,
            write_failures: state.write_failures,
        }
    })
    .unwrap_or_else(|| LogSettingsSnapshot {
        default_path: default_path.clone(),
        effective_path: default_path,
        fallback_reason: Some("loggingUnavailable"),
        ..LogSettingsSnapshot::default()
    })
}

/// 切换自定义日志父目录；`None` 恢复默认位置。
pub fn set_log_directory(parent: Option<&Path>) {
    let mut configuration = load_configuration();
    configuration.custom_directory = parent.map(|path| path.to_string_lossy().into_owned());
    save_configuration(&configuration);

    let default_directory = default_log_directory();
    let mut directory = effective_directory_for(&configuration);
    let mut fallback_reason = None;
    if directory != default_directory && !directory_is_writable(&directory) {
        fallback_reason = Some("notWritable");
        directory = default_directory;
    }
    if !directory_is_writable(&directory) {
        fallback_reason = Some("loggingUnavailable");
    }

    let session_name = with_state(|state| {
        state
            .session_path
            .file_name()
            .map(|name| name.to_owned())
            .unwrap_or_else(|| session_file_name().into())
    })
    .unwrap_or_else(|| session_file_name().into());

    with_state(|state| {
        if directory != state.directory {
            state.directory = directory.clone();
            state.session_path = directory.join(&session_name);
            if let Some(parent) = state.session_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let _ = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&state.session_path);
        }
        state.fallback_reason = fallback_reason;
        state.configuration = configuration.clone();
    });
    log_info("app", format!("log directory changed: {}", directory.display()));
}

/// 开启/关闭详细诊断；开启时以当前模块为准，15 分钟后自动关闭。
pub fn set_diagnostic_logging(enabled: bool, category: Option<&str>) {
    let mut configuration = load_configuration();
    if enabled {
        configuration.diagnostic_enabled = true;
        configuration.diagnostic_category = category.map(str::to_string);
        configuration.diagnostic_expires_at = Some(now_seconds() + DIAGNOSTIC_TTL.as_secs());
    } else {
        configuration.clear_diagnostic();
    }
    save_configuration(&configuration);
    with_state(|state| state.configuration = configuration);
}

/// 删除生效目录中由 Lithe 管理的日志文件，返回（文件数，释放字节数）。
pub fn clear_logs() -> (usize, u64) {
    let Some((directory, session_path)) = with_state(|state| {
        (state.directory.clone(), state.session_path.clone())
    }) else {
        return (0, 0);
    };
    let (deleted, freed) = clear_directory_logs(&directory);
    // 当前会话继续记录：清空后立即重建同名文件。
    if let Some(parent) = session_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&session_path);
    (deleted, freed)
}

/// 删除指定目录中由 Lithe 管理的日志文件；切换目录后清理旧位置时使用。
pub fn clear_directory_logs(directory: &Path) -> (usize, u64) {
    let mut deleted = 0;
    let mut freed = 0_u64;
    for path in session_files(directory) {
        let size = fs::metadata(&path).map(|metadata| metadata.len()).unwrap_or(0);
        if fs::remove_file(&path).is_ok() {
            deleted += 1;
            freed = freed.saturating_add(size);
        }
    }
    (deleted, freed)
}

/// 目录中由 Lithe 管理的日志总字节数。
pub fn directory_log_bytes(directory: &Path) -> u64 {
    session_files(directory)
        .iter()
        .filter_map(|path| fs::metadata(path).ok())
        .map(|metadata| metadata.len())
        .sum()
}

fn home_directory() -> Option<String> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(|value| value.to_string_lossy().into_owned())
}

fn redact(text: &str) -> String {
    match home_directory() {
        Some(home) if !home.is_empty() => text.replace(&home, "~"),
        _ => text.to_string(),
    }
}

fn environment_report() -> String {
    let mut lines = vec![
        "app=Lithe GPUI".to_string(),
        format!("version={}", env!("CARGO_PKG_VERSION")),
        format!("os={}", std::env::consts::OS),
        format!("arch={}", std::env::consts::ARCH),
        format!("generated={}", timestamp()),
    ];
    let snapshot = settings_snapshot();
    lines.push(format!("log_directory={}", snapshot.effective_path.display()));
    lines.push(format!(
        "log_fallback={}",
        snapshot.fallback_reason.unwrap_or("none")
    ));
    let text = lines.join("\n");
    redact(&text)
}

/// 诊断包会包含的文件清单（预览用）。
pub fn preview_bundle(selection: &LogSelection) -> Vec<BundleEntry> {
    let files = selected_files_for(selection);
    let mut entries: Vec<BundleEntry> = files
        .iter()
        .map(|path| BundleEntry {
            relative_path: path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "lithe.log".to_string()),
            size_bytes: fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0),
        })
        .collect();
    entries.push(BundleEntry {
        relative_path: "manifest.json".to_string(),
        size_bytes: manifest_text(&files).len() as u64,
    });
    entries.push(BundleEntry {
        relative_path: "environment.json".to_string(),
        size_bytes: environment_report().len() as u64,
    });
    entries
}

fn manifest_text(files: &[PathBuf]) -> String {
    let manifest = serde_json::json!({
        "generatedAt": timestamp(),
        "files": files
            .iter()
            .map(|path| serde_json::json!({
                "relativePath": path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
                "sizeBytes": fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0),
            }))
            .collect::<Vec<_>>(),
    });
    serde_json::to_string_pretty(&manifest).unwrap_or_else(|_| "{}".to_string())
}

fn selected_files_for(selection: &LogSelection) -> Vec<PathBuf> {
    let Some((directory, current)) = with_state(|state| {
        (state.directory.clone(), state.session_path.clone())
    }) else {
        return Vec::new();
    };
    let files = session_files(&directory);
    match selection.session.as_str() {
        "previous" => files
            .iter()
            .filter(|path| **path != current)
            .next_back()
            .cloned()
            .into_iter()
            .collect(),
        "all" => files,
        _ => {
            if files.iter().any(|path| *path == current) {
                vec![current]
            } else {
                files.last().cloned().into_iter().collect()
            }
        }
    }
}

/// 导出诊断包到 `destination`，返回实际写入的文件数。
pub fn export_bundle(destination: &Path, selection: &LogSelection) -> Result<usize, String> {
    let files = selected_files_for(selection);
    let manifest = manifest_text(&files);

    let file = File::create(destination).map_err(|error| error.to_string())?;
    let mut writer = zip::ZipWriter::new(file);
    // `default-features = false` 关闭了压缩后端，只能写不压缩条目。
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored);
    let mut written = 0;

    for path in files {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        writer
            .start_file(name.to_string(), options)
            .map_err(|error| error.to_string())?;
        let text = redact(&read_file_text(&path));
        writer
            .write_all(text.as_bytes())
            .map_err(|error| error.to_string())?;
        written += 1;
    }

    writer
        .start_file("manifest.json", options)
        .map_err(|error| error.to_string())?;
    writer
        .write_all(manifest.as_bytes())
        .map_err(|error| error.to_string())?;
    writer
        .start_file("environment.json", options)
        .map_err(|error| error.to_string())?;
    writer
        .write_all(environment_report().as_bytes())
        .map_err(|error| error.to_string())?;
    writer.finish().map_err(|error| error.to_string())?;
    Ok(written + 2)
}

/// 用系统默认程序打开日志文件。
pub fn open_log_file(path: &Path) -> bool {
    let text = path.to_string_lossy();
    #[cfg(target_os = "windows")]
    let target = format!("file:///{}", text.replace('\\', "/"));
    #[cfg(not(target_os = "windows"))]
    let target = text.into_owned();
    lithe_platform::current().open_url(&target)
}

/// 在系统文件管理器中定位日志文件。
pub fn reveal_in_file_manager(path: &Path) -> bool {
    lithe_platform::current().reveal_path(path)
}

/// 人类可读的字节数，与 Tauri 的 `formatBytes` 一致。
pub fn format_bytes(bytes: u64) -> String {
    if bytes < 1_024 {
        format!("{bytes} B")
    } else if bytes < 1_024 * 1_024 {
        format!("{:.1} KB", bytes as f64 / 1_024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1_024.0 * 1_024.0))
    }
}
