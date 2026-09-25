//! 应用设置的持久化与运行时全局状态。
//!
//! 对齐 Tauri 端 `settings.json` 的键名与默认值，按平台落到配置目录
//! （Unix `~/.config/lithe/settings.json`，Windows `%APPDATA%\lithe\settings.json`）。
//! 视图通过 [`get`] / [`update`] 读取和修改，修改后写盘并刷新窗口。

use std::path::PathBuf;

use gpui_kit::{App, Global};
use serde::{Deserialize, Serialize};

use crate::theme::ThemePalette;

/// 活动栏默认项顺序，对应 Tauri `SIDEBAR_ACTIVITY_ITEM_IDS`。
pub const SIDEBAR_ACTIVITY_ITEM_IDS: &[&str] = &[
    "files",
    "git",
    "search",
    "maven",
    "run",
    "terminal",
    "diagnostics",
    "gitLog",
    "settings",
];

/// 活动栏底部固定组，对应 Tauri `SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS`。
pub const SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS: &[&str] = &[
    "maven",
    "run",
    "terminal",
    "diagnostics",
    "gitLog",
    "settings",
];

/// 状态栏左侧项顺序，对应 Tauri `FOOTER_LEADING_ITEM_IDS`。
pub const FOOTER_LEADING_ITEM_IDS: &[&str] = &["filePath", "branch"];

/// 最近项目上限，对齐 Tauri `MAX_RECENT_PROJECTS`（`recent-folders.ts`）。
pub const MAX_RECENT_PROJECTS: usize = 12;

/// 取路径末段目录名用于展示（兼容 `/` 与 `\` 分隔）。
pub fn project_dir_name(path: &str) -> &str {
    path.rsplit(&['/', '\\'][..])
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(path)
}

/// 状态栏右侧项顺序，对应 Tauri `FOOTER_TRAILING_ITEM_IDS`。
pub const FOOTER_TRAILING_ITEM_IDS: &[&str] = &[
    "cursor",
    "encoding",
    "indent",
    "readOnly",
    "memory",
    "gitChanges",
];

/// 功能开关，对应 Tauri `coreFeatures`。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CoreFeatures {
    pub git: bool,
    pub github: bool,
    pub remote: bool,
    pub terminal: bool,
    pub search: bool,
    pub diagnostics: bool,
    pub debugger: bool,
    pub docker: bool,
    pub outline: bool,
    pub ai_chat: bool,
    pub breadcrumbs: bool,
    pub persistent_commands: bool,
    pub web_viewer: bool,
}

impl Default for CoreFeatures {
    fn default() -> Self {
        Self {
            git: true,
            github: false,
            remote: false,
            terminal: true,
            search: true,
            diagnostics: true,
            debugger: false,
            docker: false,
            outline: true,
            ai_chat: false,
            breadcrumbs: true,
            persistent_commands: true,
            web_viewer: false,
        }
    }
}

/// Tauri 默认隐藏目录模式（`DEFAULT_HIDDEN_DIRECTORY_PATTERNS`）。
pub const DEFAULT_HIDDEN_DIRECTORY_PATTERNS: &[&str] = &[
    ".git",
    ".hg",
    ".idea",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".svn",
    "CVS",
    "__pycache__",
    "_svn",
];

/// Tauri 默认隐藏文件模式（`DEFAULT_HIDDEN_FILE_PATTERNS`）。
pub const DEFAULT_HIDDEN_FILE_PATTERNS: &[&str] = &[
    "*.pyc",
    "*.pyo",
    "*.rbc",
    "*.yarb",
    "*~",
    ".DS_Store",
    "vssver.scc",
    "vssver2.scc",
];

/// AI 提交信息生成设置，对应 Tauri `CommitAISettings` 的持久化子集。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AiCommitSettings {
    pub enabled: bool,
    pub language: String,
    pub format: String,
    pub include_body: bool,
    pub subject_max_length: usize,
    pub maximum_diff_characters: usize,
}

impl Default for AiCommitSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            language: "english".to_string(),
            format: "conventional".to_string(),
            include_body: false,
            subject_max_length: 72,
            maximum_diff_characters: 32000,
        }
    }
}

/// 将显示语言值规范化为设置下拉框使用的稳定标识。
pub fn normalized_display_language(value: &str) -> String {
    let value = value.trim().to_ascii_lowercase().replace('_', "-");
    if value.starts_with("zh") {
        "zh-CN".to_string()
    } else if value.starts_with("en") {
        "en-US".to_string()
    } else {
        "zh-CN".to_string()
    }
}

/// 应用设置真源，字段名与 Tauri `defaultSettings` 的 camelCase 键一一对应。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    // General
    pub auto_save: bool,
    pub quick_open_preview: bool,
    // Editor
    pub font_family: String,
    pub font_size: f32,
    pub editor_line_height: f32,
    pub tab_size: usize,
    pub word_wrap: bool,
    pub line_numbers: bool,
    pub render_whitespace: String,
    pub render_indent_guides: bool,
    pub highlight_occurrences: bool,
    pub show_minimap: bool,
    pub code_lens: bool,
    // Terminal
    pub terminal_font_size: f32,
    pub terminal_cursor_blink: bool,
    pub terminal_scrollback: usize,
    pub terminal_default_shell_id: String,
    // Run
    pub run_scroll_to_end: bool,
    // UI
    pub ui_font_size: f32,
    pub display_language: String,
    pub reduce_motion: bool,
    pub show_status_bar: bool,
    pub show_tab_icons: bool,
    pub tab_close_button_visibility: String,
    pub window_chrome_density: String,
    // Theme
    pub theme: String,
    pub icon_theme: String,
    pub sync_system_theme: bool,
    pub auto_theme_light: String,
    pub auto_theme_dark: String,
    pub compact_menu_bar: bool,
    // Layout
    pub sidebar_activity_items_order: Vec<String>,
    pub hidden_sidebar_activity_items: Vec<String>,
    pub footer_leading_items_order: Vec<String>,
    pub footer_trailing_items_order: Vec<String>,
    pub activity_rail_expanded: bool,
    pub activity_rail_width: f32,
    pub sidebar_width: f32,
    pub right_tool_window_width: f32,
    // Tabs
    pub max_open_tabs: usize,
    pub horizontal_tab_scroll: bool,
    // Keyboard
    pub keybinding_preset: String,
    pub vim_mode: bool,
    // Language
    pub format_on_save: bool,
    pub auto_completion: bool,
    pub parameter_hints: bool,
    pub semantic_tokens: bool,
    // Projects
    pub open_folders_in_new_window: bool,
    pub ask_where_to_open_projects: bool,
    /// 最近打开的项目绝对路径，首位最新。
    ///
    /// 对齐 Tauri `recent-folders.ts`：去重（已有移到首位）、按打开倒序、
    /// 过滤不存在的路径、上限 [`MAX_RECENT_PROJECTS`]（Linux 无 pin，只做倒序）。
    /// 结构体级 `#[serde(default)]` 已覆盖，兼容缺少该键的老配置。
    pub recent_projects: Vec<String>,
    // File tree
    pub hidden_file_patterns: Vec<String>,
    pub hidden_directory_patterns: Vec<String>,
    pub file_tree_sort_order: String,
    pub file_tree_indent_size: f32,
    pub compact_folders_in_file_tree: bool,
    pub hide_root_folder_in_file_tree: bool,
    pub auto_reveal_active_file_in_file_tree: bool,
    pub show_file_icons_in_file_tree: bool,
    pub show_indent_guides_in_file_tree: bool,
    pub confirm_before_file_delete: bool,
    pub show_hidden_files_in_file_tree: bool,
    pub show_gitignored_files_in_file_tree: bool,
    pub show_git_status_in_file_tree: bool,
    // Git
    pub auto_refresh_git_status: bool,
    pub show_untracked_files: bool,
    pub show_staged_first: bool,
    pub git_default_diff_view: String,
    pub open_diff_on_click: bool,
    pub git_changes_folder_view: bool,
    pub compact_git_status_badges: bool,
    pub collapse_empty_git_sections: bool,
    pub remember_last_git_panel_mode: bool,
    pub confirm_before_discard: bool,
    pub enable_inline_git_blame: bool,
    pub git_fetch_prune: bool,
    pub git_fetch_submodules: String,
    pub git_fetch_tags: String,
    pub git_executable: String,
    pub git_use_credential_helper: bool,
    // AI
    pub ai_provider_id: String,
    pub ai_model_id: String,
    pub ai_completion: bool,
    pub ai_commit: AiCommitSettings,
    // Logs
    pub custom_log_directory: String,
    // Advanced
    pub last_settings_tab: String,
    pub core_features: CoreFeatures,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            auto_save: true,
            quick_open_preview: true,
            font_family: "Geist Mono".to_string(),
            font_size: 14.0,
            editor_line_height: 1.4,
            tab_size: 2,
            word_wrap: false,
            line_numbers: true,
            render_whitespace: "none".to_string(),
            render_indent_guides: true,
            highlight_occurrences: true,
            show_minimap: true,
            code_lens: true,
            terminal_font_size: 14.0,
            terminal_cursor_blink: true,
            terminal_scrollback: 10000,
            terminal_default_shell_id: String::new(),
            run_scroll_to_end: true,
            ui_font_size: 13.0,
            display_language: normalized_display_language("zh-CN"),
            reduce_motion: false,
            show_status_bar: true,
            show_tab_icons: true,
            tab_close_button_visibility: "active".to_string(),
            window_chrome_density: "focused".to_string(),
            theme: "lithe-dark".to_string(),
            icon_theme: "idea-icons".to_string(),
            sync_system_theme: false,
            auto_theme_light: "lithe-light".to_string(),
            auto_theme_dark: "lithe-dark".to_string(),
            compact_menu_bar: true,
            sidebar_activity_items_order: SIDEBAR_ACTIVITY_ITEM_IDS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            hidden_sidebar_activity_items: Vec::new(),
            footer_leading_items_order: FOOTER_LEADING_ITEM_IDS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            footer_trailing_items_order: FOOTER_TRAILING_ITEM_IDS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            activity_rail_expanded: false,
            activity_rail_width: 180.0,
            sidebar_width: 320.0,
            right_tool_window_width: 400.0,
            max_open_tabs: 100,
            horizontal_tab_scroll: true,
            keybinding_preset: "none".to_string(),
            vim_mode: false,
            format_on_save: false,
            auto_completion: true,
            parameter_hints: true,
            semantic_tokens: true,
            open_folders_in_new_window: true,
            ask_where_to_open_projects: true,
            recent_projects: Vec::new(),
            hidden_file_patterns: DEFAULT_HIDDEN_FILE_PATTERNS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            hidden_directory_patterns: DEFAULT_HIDDEN_DIRECTORY_PATTERNS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            file_tree_sort_order: "folders-first".to_string(),
            file_tree_indent_size: 16.0,
            compact_folders_in_file_tree: true,
            hide_root_folder_in_file_tree: false,
            auto_reveal_active_file_in_file_tree: true,
            show_file_icons_in_file_tree: true,
            show_indent_guides_in_file_tree: true,
            confirm_before_file_delete: true,
            show_hidden_files_in_file_tree: true,
            show_gitignored_files_in_file_tree: true,
            show_git_status_in_file_tree: true,
            auto_refresh_git_status: true,
            show_untracked_files: true,
            show_staged_first: true,
            git_default_diff_view: "unified".to_string(),
            open_diff_on_click: true,
            git_changes_folder_view: true,
            compact_git_status_badges: false,
            collapse_empty_git_sections: false,
            remember_last_git_panel_mode: false,
            confirm_before_discard: true,
            enable_inline_git_blame: true,
            git_fetch_prune: true,
            git_fetch_submodules: "inherit".to_string(),
            git_fetch_tags: "inherit".to_string(),
            git_executable: String::new(),
            git_use_credential_helper: true,
            ai_provider_id: "anthropic".to_string(),
            ai_model_id: "claude-sonnet-4-6".to_string(),
            ai_completion: true,
            ai_commit: AiCommitSettings::default(),
            custom_log_directory: String::new(),
            last_settings_tab: "general".to_string(),
            core_features: CoreFeatures::default(),
        }
    }
}

/// 全局设置持有者，注册到 GPUI 的 `Global` 存储。
pub struct AppSettings {
    pub settings: Settings,
}

impl Global for AppSettings {}

/// 当前设置（只读）。
pub fn get(cx: &App) -> &Settings {
    &cx.global::<AppSettings>().settings
}

/// 当前设置（可变），修改后需调用 [`persist`]。
pub fn get_mut(cx: &mut App) -> &mut Settings {
    &mut cx.global_mut::<AppSettings>().settings
}

/// 当前用户主目录。
///
/// Unix 读 `$HOME`；Windows 读 `$USERPROFILE`，再用 `$HOMEDRIVE$HOMEPATH`
/// 兼容没有 `USERPROFILE` 的会话。主目录是默认项目位置与配置回退的基点。
pub fn user_home_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        std::env::var_os("HOME").map(PathBuf::from)
    }
    #[cfg(windows)]
    {
        if let Some(profile) = std::env::var_os("USERPROFILE").filter(|v| !v.is_empty()) {
            return Some(PathBuf::from(profile));
        }
        let drive = std::env::var_os("HOMEDRIVE")?;
        let path = std::env::var_os("HOMEPATH")?;
        let mut home = PathBuf::from(drive);
        home.push(path);
        Some(home)
    }
}

/// 应用配置目录（不含 `lithe` 子目录）。
///
/// Unix 遵循 XDG：`$XDG_CONFIG_HOME` 非空即用，否则 `<home>/.config`；
/// Windows 用 `%APPDATA%`（缺失时回退 `<home>\AppData\Roaming`）。
pub fn config_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|path| !path.as_os_str().is_empty())
            .or_else(|| user_home_dir().map(|home| home.join(".config")))
    }
    #[cfg(windows)]
    {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .filter(|path| !path.as_os_str().is_empty())
            .or_else(|| user_home_dir().map(|home| home.join("AppData").join("Roaming")))
    }
}

/// 应用数据目录（日志等持久数据）。
///
/// Unix 遵循 XDG：`$XDG_DATA_HOME` 非空即用，否则 `<home>/.local/share`；
/// Windows 用 `%LOCALAPPDATA%`（缺失时回退 `<home>\AppData\Local`）。
pub fn data_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|path| !path.as_os_str().is_empty())
            .or_else(|| user_home_dir().map(|home| home.join(".local/share")))
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .filter(|path| !path.as_os_str().is_empty())
            .or_else(|| user_home_dir().map(|home| home.join("AppData").join("Local")))
    }
}

/// 解析配置文件路径；配置目录与平台规则见 [`config_dir`]。
pub fn config_path() -> Option<PathBuf> {
    Some(config_dir()?.join("lithe").join("settings.json"))
}

/// 从磁盘加载设置；缺失或损坏时回退到默认值并补齐顺序字段。
pub fn load() -> Settings {
    let Some(path) = config_path() else {
        return Settings::default();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Settings::default();
    };
    let mut settings = serde_json::from_str::<Settings>(&text).unwrap_or_default();
    settings.display_language = normalized_display_language(&settings.display_language);
    settings
}

/// 将设置写回磁盘（临时文件 + 原子替换）。
pub fn persist(settings: &Settings) {
    let Some(path) = config_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
    }
    let Ok(text) = serde_json::to_string_pretty(settings) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, text).is_ok() {
        // Windows 的 `rename` 在目标存在时会失败，先移除旧文件再落盘；
        // 两次操作间目录里可能短暂无配置，但不会有半写内容。
        #[cfg(windows)]
        {
            let _ = std::fs::remove_file(&path);
        }
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// 初始化全局设置（应用启动时调用一次）。
pub fn init(cx: &mut App) {
    let settings = load();
    cx.set_global(AppSettings { settings });
}

/// 修改设置：写全局、落盘并刷新所有窗口。
pub fn update(cx: &mut App, f: impl FnOnce(&mut Settings)) {
    f(get_mut(cx));
    let settings = get_mut(cx);
    settings.display_language = normalized_display_language(&settings.display_language);
    let snapshot = get(cx).clone();
    persist(&snapshot);
    cx.refresh_windows();
}

/// 记录最近项目（对齐 Tauri upsert）：去重移到首位 → 过滤不存在 → 截断上限 → 落盘。
pub fn record_recent_project(cx: &mut App, path: &str) {
    update(cx, |s| {
        s.recent_projects.retain(|p| p != path);
        s.recent_projects.insert(0, path.to_string());
        s.recent_projects
            .retain(|p| std::path::Path::new(p).exists());
        s.recent_projects.truncate(MAX_RECENT_PROJECTS);
    });
}

/// 解析当前应生效的主题 id：跟随系统时按外观取 `autoTheme*`，否则取 `theme`。
pub fn resolved_theme_id(settings: &Settings, system_is_dark: bool) -> String {
    if settings.sync_system_theme {
        if system_is_dark {
            settings.auto_theme_dark.clone()
        } else {
            settings.auto_theme_light.clone()
        }
    } else {
        settings.theme.clone()
    }
}

/// 把主题 id 应用到工作台调色板；未知 id 回退深色。
pub fn apply_theme(theme_id: &str) {
    let palette = ThemePalette::for_theme_id(theme_id).unwrap_or_else(ThemePalette::dark);
    crate::theme::set_palette(palette);
}

#[cfg(test)]
mod tests {
    use super::normalized_display_language;

    #[test]
    fn display_language_aliases_match_settings_options() {
        assert_eq!(normalized_display_language("zh"), "zh-CN");
        assert_eq!(normalized_display_language("zh_CN"), "zh-CN");
        assert_eq!(normalized_display_language("en_US"), "en-US");
    }

    #[test]
    fn unknown_display_language_uses_product_default() {
        assert_eq!(normalized_display_language("fr-FR"), "zh-CN");
    }
}
