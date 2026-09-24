//! 应用设置的 XDG 持久化与运行时全局状态。
//!
//! 对齐 Tauri 端 `settings.json` 的键名与默认值，落到
//! `$XDG_CONFIG_HOME/lithe/settings.json`（缺省 `~/.config/lithe/settings.json`）。
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

/// 应用设置真源，字段名与 Tauri `defaultSettings` 的 camelCase 键一一对应。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    // General
    pub auto_save: bool,
    pub quick_open_preview: bool,
    // Editor
    pub font_size: f32,
    pub tab_size: usize,
    pub word_wrap: bool,
    pub line_numbers: bool,
    pub show_minimap: bool,
    pub code_lens: bool,
    // Terminal
    pub terminal_scrollback: usize,
    pub terminal_default_shell_id: String,
    // UI
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
    // Language
    pub auto_completion: bool,
    pub parameter_hints: bool,
    pub semantic_tokens: bool,
    // Projects
    pub open_folders_in_new_window: bool,
    pub ask_where_to_open_projects: bool,
    // File tree
    pub hidden_file_patterns: Vec<String>,
    pub hidden_directory_patterns: Vec<String>,
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
    // Advanced
    pub last_settings_tab: String,
    pub core_features: CoreFeatures,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            auto_save: true,
            quick_open_preview: true,
            font_size: 13.0,
            tab_size: 2,
            word_wrap: false,
            line_numbers: true,
            show_minimap: true,
            code_lens: true,
            terminal_scrollback: 10000,
            terminal_default_shell_id: String::new(),
            display_language: "zh-CN".to_string(),
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
            auto_completion: true,
            parameter_hints: true,
            semantic_tokens: true,
            open_folders_in_new_window: true,
            ask_where_to_open_projects: true,
            hidden_file_patterns: DEFAULT_HIDDEN_FILE_PATTERNS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            hidden_directory_patterns: DEFAULT_HIDDEN_DIRECTORY_PATTERNS
                .iter()
                .map(|s| s.to_string())
                .collect(),
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

/// 解析配置文件路径；优先 `XDG_CONFIG_HOME`，否则 `~/.config`。
pub fn config_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("lithe").join("settings.json"))
}

/// 从磁盘加载设置；缺失或损坏时回退到默认值并补齐顺序字段。
pub fn load() -> Settings {
    let Some(path) = config_path() else {
        return Settings::default();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Settings::default();
    };
    serde_json::from_str::<Settings>(&text).unwrap_or_default()
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
    let snapshot = get(cx).clone();
    persist(&snapshot);
    cx.refresh_windows();
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
