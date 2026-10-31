//! 应用设置模型与设置页视图。
//!
//! `AppSettings` 持久化到与 `lithe-platform::recent_projects` 相同的应用数据
//! 目录：Windows `%APPDATA%\Lithe`、macOS
//! `$HOME/Library/Application Support/Lithe`、Linux
//! `$XDG_CONFIG_HOME/lithe`（未设置时退回 `$HOME/.config/lithe`），文件名固定
//! 为 `settings.json`。
//!
//! 读取失败、内容损坏或字段越界时回退到安全的默认值；写入先写同目录临时文件
//! 再 rename，任何 I/O 失败都静默丢弃，不写日志也不 panic。设置页构造期不读
//! 写磁盘、不发起异步任务；只有用户修改设置时才调用 [`AppSettings::save`]。
//!
//! 设置页的导航结构与 macOS 对齐：7 个分组、19 个页面，其中 AI 分组下的
//! Library 是二级折叠分组。外部子系统（插件、完整 LSP、Provider / MCP /
//! Skills / Hooks）只显示真实状态或说明，不做假开关。
//!
//! 颜色全部来自 [`LitheTokens`]，字号与圆角优先使用 [`LitheMetrics`]；设置页
//! 特有的导航宽度、行高等尺寸收敛在本模块常量里。

use std::env;
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable as _, Icon, IconName, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, Context, Entity, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement, Render, SharedString,
    StatefulInteractiveElement as _, Styled, Subscription, Window, div, px,
};
use lithe_platform as platform;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens, icon};

use crate::maven::configuration::{self, MavenEffectiveSettings, MavenLocalSettings};

/// 设置文件名；目录约定与最近项目列表保持一致。
const STORE_FILE_NAME: &str = "settings.json";

/// 默认主题族与可选主题；第二列是展示名，所有展示名仍会经过 `tr`。
const DEFAULT_THEME: &str = "lithe";
const THEMES: [(&str, &str); 3] = [("lithe", "Lithe"), ("codex", "Codex"), ("linear", "Linear")];
const LANGUAGES: [(&str, &str); 2] = [("en-US", "English"), ("zh-CN", "中文")];
const DEFAULT_LANGUAGE: &str = "zh-CN";

const DEFAULT_UPDATE_CHANNEL: &str = "stable";
const UPDATE_CHANNELS: [(&str, &str); 2] = [("stable", "Stable"), ("preview", "Preview")];

const DEFAULT_EDITOR_FONT_SIZE: f32 = 13.0;
const MIN_EDITOR_FONT_SIZE: f32 = 9.0;
const MAX_EDITOR_FONT_SIZE: f32 = 32.0;

const DEFAULT_TERMINAL_FONT_SIZE: f32 = 13.0;
const DEFAULT_TERMINAL_SCROLLBACK: u32 = 5000;
const MIN_TERMINAL_SCROLLBACK: u32 = 100;
const MAX_TERMINAL_SCROLLBACK: u32 = 50_000;
/// 终端回滚行数的步进；与 macOS 设置页的 500 行一致。
const TERMINAL_SCROLLBACK_STEP: u32 = 500;

const DEFAULT_RUN_SERVICES_ON_EXIT: &str = "ask";
const RUN_SERVICE_OPTIONS: [(&str, &str); 2] = [
    ("ask", "Ask before stopping"),
    ("terminate", "Stop without asking"),
];

const DEFAULT_TERMINAL_ON_QUIT: &str = "ask";
const TERMINAL_QUIT_OPTIONS: [(&str, &str); 2] = [
    ("ask", "Ask for each terminal"),
    ("terminate", "End without asking"),
];

const DEFAULT_AGENT_TASKS: &str = "ask";
const AGENT_TASK_OPTIONS: [(&str, &str); 3] = [
    ("ask", "Ask for each task"),
    ("keep", "Keep running"),
    ("terminate", "End without asking"),
];

const DEFAULT_BACKGROUND_SERVICES: &str = "ask";
const BACKGROUND_SERVICE_OPTIONS: [(&str, &str); 3] = [
    ("ask", "Ask in one list"),
    ("keep", "Keep running"),
    ("terminate", "End all"),
];

const DEFAULT_GRACEFUL_STOP_SECONDS: u32 = 5;
const MIN_GRACEFUL_STOP_SECONDS: u32 = 1;
const MAX_GRACEFUL_STOP_SECONDS: u32 = 60;

const DEFAULT_AI_COMMIT_FORMAT: &str = "conventional";
const COMMIT_FORMATS: [(&str, &str); 3] = [
    ("conventional", "Conventional"),
    ("plain", "Plain"),
    ("gitmoji", "GitMoji"),
];

// 设置页专有布局刻度。通用字号/圆角来自 `LitheMetrics`，这里只放导航与行
// 布局需要而 metrics 尚未覆盖的尺寸。
//
// 与 macOS `SettingsView` 对齐：左侧导航固定 234
// （`categoryMinimumWidth`）、右侧内容最小 500（`contentMinimumWidth`）。
// macOS 的 480 是侧栏可拖动的**最大**宽度，GPUI 侧栏固定宽，不套用到内容区。
//
// 导航行采用 macOS 设置侧栏 `LitheTreeList` 的默认度量：
// `Tree.rowHeight = 24`、`VStack spacing = 0`、`horizontalInset = 12`、
// `indent = 19`。外层 4 + 行内 8 合计 12；每级缩进 19。
const SETTINGS_NAV_WIDTH: f32 = 234.0;
const SETTINGS_NAV_GROUP_HEIGHT: f32 = 24.0;
const SETTINGS_NAV_ROW_HEIGHT: f32 = 24.0;
const SETTINGS_NAV_GAP: f32 = 0.0;
const SETTINGS_NAV_ITEM_PADDING: f32 = 8.0;
/// Tauri General › Appearance › Appearance Mode。
const APPEARANCE_MODES: [(&str, &str); 3] =
    [("system", "System"), ("light", "Light"), ("dark", "Dark")];

/// Tauri Git › View › Default diff view。
const DIFF_VIEWS: [(&str, &str); 2] = [("unified", "Unified"), ("split", "Split")];
/// Tauri Git › Fetch defaults › Submodules。
const FETCH_SUBMODULES: [(&str, &str); 4] = [
    ("inherit", "Use Git configuration"),
    ("no", "Do not fetch submodules"),
    ("onDemand", "Fetch on demand"),
    ("yes", "Fetch all submodules"),
];
/// Tauri Git › Fetch defaults › Tags。
const FETCH_TAGS: [(&str, &str); 4] = [
    ("inherit", "Use Git configuration"),
    ("all", "Fetch all tags"),
    ("none", "Do not fetch tags"),
    (
        "prune",
        "Synchronize tags and delete local tags absent on remote",
    ),
];
/// Keymap presets。
const KEYMAP_PRESETS: [(&str, &str); 2] = [("default", "Default"), ("vim", "Vim")];

/// Tauri Editor › Indentation › Tab width。
const TAB_WIDTHS: [(&str, &str); 3] = [("2", "2"), ("4", "4"), ("8", "8")];

/// Tauri General › Projects › Open projects in。
const PROJECT_OPEN_DESTINATIONS: [(&str, &str); 4] = [
    ("ask", "Ask every time"),
    ("this-window", "This window"),
    ("new-window", "New window"),
    ("attach", "Attach"),
];

/// Tauri 的默认隐藏目录模式。
const DEFAULT_HIDDEN_DIRECTORY_PATTERNS: [&str; 10] = [
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

/// Tauri 的默认隐藏文件模式。
const DEFAULT_HIDDEN_FILE_PATTERNS: [&str; 8] = [
    "*.pyc",
    "*.pyo",
    "*.rbc",
    "*.yarb",
    "*~",
    ".DS_Store",
    "vssver.scc",
    "vssver2.scc",
];

const SETTINGS_CONTENT_MIN_WIDTH: f32 = 500.0;
const SETTINGS_SECTION_GAP: f32 = 16.0;

const SETTINGS_CONTROL_GAP: f32 = 6.0;
/// 设置页普通按钮的统一高度。
const SETTINGS_BUTTON_HEIGHT: f32 = 24.0;
/// 设置页按钮的统一圆角。
const SETTINGS_BUTTON_RADIUS: f32 = 6.0;
/// 同组互斥选项按钮的最小宽度。
const SETTINGS_OPTION_MIN_WIDTH: f32 = 72.0;
/// 步进器按钮宽度。
const SETTINGS_STEPPER_WIDTH: f32 = 28.0;

/// 应用级设置。
///
/// 字段保持公开，供工作台在切换主题或编辑器偏好时直接读取；写入磁盘前不需要
/// 额外的配置结构。`#[serde(default)]` 让旧版本或缺字段的 JSON 仍然可用。
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    // Appearance & Behavior
    /// 主题族：`"lithe"`、`"codex"` 或 `"linear"`。
    pub theme: String,
    /// 是否使用深色模式。
    pub dark: bool,
    /// 外观模式：`"system"`、`"light"` 或 `"dark"`。GPUI 暂无系统主题监听，
    /// `"system"` 只保留当前深浅色。
    pub appearance_mode: String,
    /// 打开另一个项目时的默认落点：`"ask"`、`"this-window"`、
    /// `"new-window"` 或 `"attach"`。
    pub project_open_destination: String,
    /// 保存后是否自动保存。当前 GPUI 编辑器尚未启用自动保存，只保存偏好。
    pub auto_save: bool,
    /// 隐藏目录的匹配模式，按行保存。
    pub hidden_directory_patterns: Vec<String>,
    /// 隐藏文件的匹配模式，按行保存。
    pub hidden_file_patterns: Vec<String>,
    // Git
    pub git_integration: bool,
    pub git_auto_refresh: bool,
    pub git_confirm_discard: bool,
    pub git_changes_folder_view: bool,
    pub git_show_untracked: bool,
    pub git_show_staged_first: bool,
    pub git_open_diff_on_click: bool,
    pub git_compact_badges: bool,
    pub git_collapse_empty: bool,
    pub git_inline_blame: bool,
    pub git_gutter: bool,
    pub git_default_diff_view: String,
    pub git_fetch_prune: bool,
    pub git_fetch_submodules: String,
    pub git_fetch_tags: String,
    // Keyboard
    pub keymap_preset: String,
    pub vim_mode: bool,
    // AI autocomplete
    pub ai_autocomplete: bool,
    /// 界面语言：`"en-US"` 或 `"zh-CN"`。
    pub language: String,
    /// 更新渠道：`"stable"` 或 `"preview"`。
    pub update_channel: String,
    /// 是否自动检查更新。本构建尚未接入自动更新，值只做持久化。
    pub auto_check_updates: bool,
    /// 编辑器字号，正常范围 9–32。
    pub editor_font_size: f32,
    /// 编辑器是否自动换行。
    pub editor_wrap: bool,
    /// 编辑器是否启用字体连字。
    pub editor_font_ligatures: bool,
    /// 编辑器是否显示 Code Lens。
    pub editor_code_lens: bool,
    /// 编辑器 Tab 宽度，允许 2 / 4 / 8。
    pub editor_tab_size: u32,
    /// 编辑器是否显示 minimap。
    pub editor_minimap: bool,
    /// 编辑器是否显示行号。
    pub editor_line_numbers: bool,
    /// 编辑器是否显示空白字符（空格与制表符）。
    pub editor_render_whitespace: bool,
    /// 编辑器是否允许滚动到最后一行之后。
    pub editor_scroll_beyond_last_line: bool,
    // Process termination policy（只存储，长期驻留服务落地后才强制执行）
    /// Run services：`"ask"` 或 `"terminate"`。
    pub run_services_on_exit: String,
    /// 终端：`"ask"` 或 `"terminate"`。
    pub terminal_on_quit: String,
    /// Agent 任务：`"ask"`、`"keep"` 或 `"terminate"`。
    pub agent_tasks: String,
    /// 后台服务：`"ask"`、`"keep"` 或 `"terminate"`。
    pub background_services: String,
    /// 优雅停止等待秒数，范围 1–60。
    pub graceful_stop_seconds: u32,
    // Terminal
    /// 终端字号，正常范围 9–32。
    pub terminal_font_size: f32,
    /// 终端回滚行数，范围 100–50000。
    pub terminal_scrollback: u32,
    // AI
    /// 是否启用 AI 提交信息生成。
    pub ai_commit_enabled: bool,
    /// 提交信息格式：`"conventional"`、`"plain"` 或 `"gitmoji"`。
    pub ai_commit_format: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            theme: DEFAULT_THEME.to_string(),
            // 与 `lithe_ui::install_theme` 的默认（Lithe 深色）保持一致。
            dark: true,
            appearance_mode: "dark".to_string(),
            project_open_destination: "ask".to_string(),
            auto_save: true,
            hidden_directory_patterns: DEFAULT_HIDDEN_DIRECTORY_PATTERNS
                .iter()
                .map(|pattern| (*pattern).to_string())
                .collect(),
            hidden_file_patterns: DEFAULT_HIDDEN_FILE_PATTERNS
                .iter()
                .map(|pattern| (*pattern).to_string())
                .collect(),
            git_integration: true,
            git_auto_refresh: true,
            git_confirm_discard: true,
            git_changes_folder_view: false,
            git_show_untracked: true,
            git_show_staged_first: true,
            git_open_diff_on_click: true,
            git_compact_badges: false,
            git_collapse_empty: false,
            git_inline_blame: true,
            git_gutter: true,
            git_default_diff_view: "unified".to_string(),
            git_fetch_prune: true,
            git_fetch_submodules: "inherit".to_string(),
            git_fetch_tags: "inherit".to_string(),
            keymap_preset: "default".to_string(),
            vim_mode: false,
            ai_autocomplete: false,
            language: DEFAULT_LANGUAGE.to_string(),
            update_channel: DEFAULT_UPDATE_CHANNEL.to_string(),
            auto_check_updates: true,
            editor_font_size: DEFAULT_EDITOR_FONT_SIZE,
            editor_wrap: false,
            editor_font_ligatures: false,
            editor_code_lens: false,
            editor_tab_size: 4,
            editor_minimap: false,
            editor_line_numbers: true,
            // 默认不显示空白字符：与常见编辑器的初始状态一致，避免打开文件就出现点线。
            editor_render_whitespace: false,
            editor_scroll_beyond_last_line: true,
            run_services_on_exit: DEFAULT_RUN_SERVICES_ON_EXIT.to_string(),
            terminal_on_quit: DEFAULT_TERMINAL_ON_QUIT.to_string(),
            agent_tasks: DEFAULT_AGENT_TASKS.to_string(),
            background_services: DEFAULT_BACKGROUND_SERVICES.to_string(),
            graceful_stop_seconds: DEFAULT_GRACEFUL_STOP_SECONDS,
            terminal_font_size: DEFAULT_TERMINAL_FONT_SIZE,
            terminal_scrollback: DEFAULT_TERMINAL_SCROLLBACK,
            ai_commit_enabled: false,
            ai_commit_format: DEFAULT_AI_COMMIT_FORMAT.to_string(),
        }
    }
}

impl AppSettings {
    /// 从应用数据目录读取设置。
    ///
    /// 文件不存在、不可读、不是 UTF-8、JSON 损坏或字段越界时返回默认值；
    /// 这些情况都不视为错误，也不会在这里重写磁盘。
    pub fn load() -> Self {
        let Some(path) = store_file_path() else {
            return Self::default();
        };
        let Ok(text) = fs::read_to_string(&path) else {
            return Self::default();
        };
        let Ok(settings) = serde_json::from_str::<Self>(&text) else {
            return Self::default();
        };
        settings.normalized()
    }

    /// 原子写入设置。
    ///
    /// 先写同目录临时文件再 rename；创建目录、序列化、写入或 rename 任一步
    /// 失败都静默放弃，内存中的设置仍然可用。
    pub fn save(&self) {
        let Some(directory) = app_data_dir() else {
            return;
        };
        if fs::create_dir_all(&directory).is_err() {
            return;
        }
        let Ok(payload) = serde_json::to_string_pretty(self) else {
            return;
        };

        let target = directory.join(STORE_FILE_NAME);
        // 临时文件带进程号，降低多个实例同时写入时互相踩踏的概率。
        let temporary = directory.join(format!(".{STORE_FILE_NAME}.{}.tmp", std::process::id()));

        if fs::write(&temporary, payload.as_bytes()).is_err() {
            let _ = fs::remove_file(&temporary);
            return;
        }

        // 同一目录内的 rename 是原子替换；失败时清理临时文件并保留旧设置。
        // Windows 上 std::fs::rename 会替换已存在的目标文件。
        if fs::rename(&temporary, &target).is_err() {
            let _ = fs::remove_file(&temporary);
        }
    }

    /// 修正从磁盘读到的未知枚举值与越界数字。
    fn normalized(mut self) -> Self {
        self.theme = normalized_choice(&self.theme, &THEME_IDS, DEFAULT_THEME);
        self.language = normalized_choice(&self.language, &["en-US", "zh-CN"], DEFAULT_LANGUAGE);
        self.update_channel = normalized_choice(
            &self.update_channel,
            &UPDATE_CHANNEL_IDS,
            DEFAULT_UPDATE_CHANNEL,
        );
        self.editor_font_size =
            normalized_font_size(self.editor_font_size, DEFAULT_EDITOR_FONT_SIZE);
        self.terminal_font_size =
            normalized_font_size(self.terminal_font_size, DEFAULT_TERMINAL_FONT_SIZE);
        self.terminal_scrollback = self
            .terminal_scrollback
            .clamp(MIN_TERMINAL_SCROLLBACK, MAX_TERMINAL_SCROLLBACK);
        self.run_services_on_exit = normalized_choice(
            &self.run_services_on_exit,
            &["ask", "terminate"],
            DEFAULT_RUN_SERVICES_ON_EXIT,
        );
        self.terminal_on_quit = normalized_choice(
            &self.terminal_on_quit,
            &["ask", "terminate"],
            DEFAULT_TERMINAL_ON_QUIT,
        );
        self.agent_tasks = normalized_choice(
            &self.agent_tasks,
            &["ask", "keep", "terminate"],
            DEFAULT_AGENT_TASKS,
        );
        self.background_services = normalized_choice(
            &self.background_services,
            &["ask", "keep", "terminate"],
            DEFAULT_BACKGROUND_SERVICES,
        );
        self.graceful_stop_seconds = self
            .graceful_stop_seconds
            .clamp(MIN_GRACEFUL_STOP_SECONDS, MAX_GRACEFUL_STOP_SECONDS);
        self.ai_commit_format = normalized_choice(
            &self.ai_commit_format,
            &["conventional", "plain", "gitmoji"],
            DEFAULT_AI_COMMIT_FORMAT,
        );
        // editor_render_whitespace 是布尔字段，反序列化本身不会产生越界值，
        // 缺字段时由 `#[serde(default)]` 补成 false，因此这里无需额外校验。
        self
    }

    /// 按 `delta` 调整编辑器字号，并沿用与反序列化一致的取整和夹紧规则。
    ///
    /// 返回是否真的发生变化，调用方可据此跳过无意义的写盘。
    pub fn nudge_editor_font_size(&mut self, delta: f32) -> bool {
        let next = normalized_font_size(self.editor_font_size + delta, DEFAULT_EDITOR_FONT_SIZE);
        if (next - self.editor_font_size).abs() < f32::EPSILON {
            return false;
        }
        self.editor_font_size = next;
        true
    }

    /// 把编辑器字号恢复为默认值；返回是否真的发生变化。
    pub fn reset_editor_font_size(&mut self) -> bool {
        if (self.editor_font_size - DEFAULT_EDITOR_FONT_SIZE).abs() < f32::EPSILON {
            return false;
        }
        self.editor_font_size = DEFAULT_EDITOR_FONT_SIZE;
        true
    }
}

const THEME_IDS: [&str; 3] = ["lithe", "codex", "linear"];
const UPDATE_CHANNEL_IDS: [&str; 2] = ["stable", "preview"];

fn store_file_path() -> Option<PathBuf> {
    app_data_dir().map(|directory| directory.join(STORE_FILE_NAME))
}

/// macOS：`$HOME/Library/Application Support/Lithe`。
#[cfg(target_os = "macos")]
fn app_data_dir() -> Option<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support/Lithe"))
}

/// Windows：`%APPDATA%\Lithe`。
#[cfg(target_os = "windows")]
fn app_data_dir() -> Option<PathBuf> {
    env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("Lithe"))
}

/// Linux：`$XDG_CONFIG_HOME/lithe`，否则 `$HOME/.config/lithe`。
#[cfg(target_os = "linux")]
fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

/// 未知平台：没有专属目录约定，退回 XDG，保证设置仍然可用。
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn xdg_config_lithe() -> Option<PathBuf> {
    // 空字符串在 XDG 规范里等价于未设置，需要忽略。
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")));
    base.map(|directory| directory.join("lithe"))
}

/// 把任意枚举字符串收敛到受支持的规范 id，未知值回退到默认值。
fn normalized_choice(value: &str, options: &[&str], fallback: &str) -> String {
    options
        .iter()
        .find(|option| value.eq_ignore_ascii_case(option))
        .map(|option| (*option).to_string())
        .unwrap_or_else(|| fallback.to_string())
}

/// 字号取整并限制在 9–32；非有限值回到默认。
fn normalized_font_size(size: f32, fallback: f32) -> f32 {
    if size.is_finite() {
        size.round()
            .clamp(MIN_EDITOR_FONT_SIZE, MAX_EDITOR_FONT_SIZE)
    } else {
        fallback
    }
}

// ---------------------------------------------------------------------------
// 侧栏导航结构
// ---------------------------------------------------------------------------

/// 设置页左侧的 7 个顶层分组。`Plugins` 是分组之间的独立页面，不在其中。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SettingsGroup {
    Appearance,
    VersionControl,
    Build,
    Languages,
    Tools,
    Ai,
}

impl SettingsGroup {
    fn index(self) -> usize {
        match self {
            SettingsGroup::Appearance => 0,
            SettingsGroup::VersionControl => 1,
            SettingsGroup::Build => 2,
            SettingsGroup::Languages => 3,
            SettingsGroup::Tools => 4,
            SettingsGroup::Ai => 5,
        }
    }

    fn id(self) -> &'static str {
        match self {
            SettingsGroup::Appearance => "lithe-settings:group:appearance",
            SettingsGroup::VersionControl => "lithe-settings:group:version-control",
            SettingsGroup::Build => "lithe-settings:group:build",
            SettingsGroup::Languages => "lithe-settings:group:languages",
            SettingsGroup::Tools => "lithe-settings:group:tools",
            SettingsGroup::Ai => "lithe-settings:group:ai",
        }
    }

    fn title(self) -> &'static str {
        match self {
            SettingsGroup::Appearance => "Appearance & Behavior",
            SettingsGroup::VersionControl => "Version Control",
            SettingsGroup::Build => "Build, Execution, Deployment",
            SettingsGroup::Languages => "Languages & Frameworks",
            SettingsGroup::Tools => "Tools",
            SettingsGroup::Ai => "AI",
        }
    }

    fn pages(self) -> &'static [SettingsPage] {
        match self {
            SettingsGroup::Appearance => &[
                SettingsPage::General,
                SettingsPage::Updates,
                SettingsPage::Editor,
                SettingsPage::Keymap,
                SettingsPage::ProcessTermination,
            ],
            SettingsGroup::VersionControl => &[SettingsPage::Git],
            SettingsGroup::Build => &[SettingsPage::Project, SettingsPage::RunConfigurations],
            SettingsGroup::Languages => &[SettingsPage::Lsp],
            SettingsGroup::Tools => &[SettingsPage::Terminal, SettingsPage::Diagnostics],
            // AI 的侧栏顺序由 `render_group` 单独处理，Library 是二级折叠。
            SettingsGroup::Ai => &[
                SettingsPage::AiProviders,
                SettingsPage::Agents,
                SettingsPage::Instructions,
                SettingsPage::Skills,
                SettingsPage::Hooks,
                SettingsPage::Mcp,
                SettingsPage::AiCommit,
            ],
        }
    }
}

/// 顶层侧栏布局：分组与独立页面交替。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SidebarEntry {
    Group(SettingsGroup),
    Page(SettingsPage),
}

const SIDEBAR_LAYOUT: [SidebarEntry; 7] = [
    SidebarEntry::Group(SettingsGroup::Appearance),
    SidebarEntry::Page(SettingsPage::Plugins),
    SidebarEntry::Group(SettingsGroup::VersionControl),
    SidebarEntry::Group(SettingsGroup::Build),
    SidebarEntry::Group(SettingsGroup::Languages),
    SidebarEntry::Group(SettingsGroup::Tools),
    SidebarEntry::Group(SettingsGroup::Ai),
];

/// AI › Library 下的二级页面。
const LIBRARY_PAGES: [SettingsPage; 4] = [
    SettingsPage::Instructions,
    SettingsPage::Skills,
    SettingsPage::Hooks,
    SettingsPage::Mcp,
];

/// 设置页的 19 个页面。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SettingsPage {
    General,
    Updates,
    Editor,
    Keymap,
    ProcessTermination,
    Plugins,
    Git,
    Project,
    RunConfigurations,
    Lsp,
    Terminal,
    Diagnostics,
    AiProviders,
    Agents,
    Instructions,
    Skills,
    Hooks,
    Mcp,
    AiCommit,
}

impl SettingsPage {
    fn id(self) -> &'static str {
        match self {
            SettingsPage::General => "lithe-settings:page:general",
            SettingsPage::Updates => "lithe-settings:page:updates",
            SettingsPage::Editor => "lithe-settings:page:editor",
            SettingsPage::Keymap => "lithe-settings:page:keymap",
            SettingsPage::ProcessTermination => "lithe-settings:page:process-termination",
            SettingsPage::Plugins => "lithe-settings:page:plugins",
            SettingsPage::Git => "lithe-settings:page:git",
            SettingsPage::Project => "lithe-settings:page:project",
            SettingsPage::RunConfigurations => "lithe-settings:page:run-configurations",
            SettingsPage::Lsp => "lithe-settings:page:lsp",
            SettingsPage::Terminal => "lithe-settings:page:terminal",
            SettingsPage::Diagnostics => "lithe-settings:page:diagnostics",
            SettingsPage::AiProviders => "lithe-settings:page:ai-providers",
            SettingsPage::Agents => "lithe-settings:page:agents",
            SettingsPage::Instructions => "lithe-settings:page:instructions",
            SettingsPage::Skills => "lithe-settings:page:skills",
            SettingsPage::Hooks => "lithe-settings:page:hooks",
            SettingsPage::Mcp => "lithe-settings:page:mcp",
            SettingsPage::AiCommit => "lithe-settings:page:ai-commit",
        }
    }

    fn title(self) -> &'static str {
        match self {
            SettingsPage::General => "General",
            SettingsPage::Updates => "Updates",
            SettingsPage::Editor => "Editor",
            SettingsPage::Keymap => "Keymap",
            SettingsPage::ProcessTermination => "Process Termination",
            SettingsPage::Plugins => "Plugins",
            SettingsPage::Git => "Git",
            SettingsPage::Project => "Project · JDK & Maven",
            SettingsPage::RunConfigurations => "Run Configurations",
            SettingsPage::Lsp => "LSP",
            SettingsPage::Terminal => "Terminal",
            SettingsPage::Diagnostics => "Logs and Diagnostics",
            SettingsPage::AiProviders => "AI Providers",
            SettingsPage::Agents => "Agents",
            SettingsPage::Instructions => "Instructions",
            SettingsPage::Skills => "Skills",
            SettingsPage::Hooks => "Hooks",
            SettingsPage::Mcp => "MCP",
            SettingsPage::AiCommit => "AI & Commit",
        }
    }

    /// Plugins 是分组之外的独立页面，因此返回 `None`。
    fn group(self) -> Option<SettingsGroup> {
        match self {
            SettingsPage::General
            | SettingsPage::Updates
            | SettingsPage::Editor
            | SettingsPage::Keymap
            | SettingsPage::ProcessTermination => Some(SettingsGroup::Appearance),
            SettingsPage::Plugins => None,
            SettingsPage::Git => Some(SettingsGroup::VersionControl),
            SettingsPage::Project | SettingsPage::RunConfigurations => Some(SettingsGroup::Build),
            SettingsPage::Lsp => Some(SettingsGroup::Languages),
            SettingsPage::Terminal | SettingsPage::Diagnostics => Some(SettingsGroup::Tools),
            SettingsPage::AiProviders
            | SettingsPage::Agents
            | SettingsPage::Instructions
            | SettingsPage::Skills
            | SettingsPage::Hooks
            | SettingsPage::Mcp
            | SettingsPage::AiCommit => Some(SettingsGroup::Ai),
        }
    }
}

// ---------------------------------------------------------------------------
// 设置页上下文与视图
// ---------------------------------------------------------------------------

/// 设置页展示的只读工作台上下文。
#[derive(Clone, Debug, Default)]
pub struct SettingsContext {
    pub project_root: Option<PathBuf>,
    pub branch: String,
    pub memory: String,
    pub agent_status: String,
}

type ChangeHandler = Rc<dyn Fn(&AppSettings, &mut Window, &mut App) + 'static>;
type OpenHandler = Rc<dyn Fn(&mut Window, &mut App) + 'static>;

/// 互斥按钮行对应的设置写入动作。用枚举而不是捕获函数指针，避免把
/// `Context` 生命周期写进类型别名。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChoiceAction {
    Theme,
    AppearanceMode,
    ProjectOpenDestination,
    EditorTabSize,
    GitDiffView,
    GitFetchSubmodules,
    GitFetchTags,
    KeymapPreset,
    Language,
    UpdateChannel,
    RunServices,
    TerminalOnQuit,
    AgentTasks,
    BackgroundServices,
    CommitFormat,
}

/// Git / Keymap / AI 的布尔开关写入动作。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ToggleAction {
    GitIntegration,
    GitAutoRefresh,
    GitConfirmDiscard,
    GitFolderView,
    GitUntracked,
    GitStagedFirst,
    GitOpenDiff,
    GitCompactBadges,
    GitCollapseEmpty,
    GitInlineBlame,
    GitGutter,
    GitFetchPrune,
    VimMode,
    AiAutocomplete,
}

/// 步进器对应的设置写入动作。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StepperAction {
    EditorFontSize,
    TerminalFontSize,
    TerminalScrollback,
    GracefulStop,
}

/// 设置页视图。
///
/// 左侧是可滚动的分组导航，右侧按选中页面渲染内容。所有可编辑控件立即写入
/// `self.settings`、调用 `on_change`、持久化并重绘，没有“应用/取消”暂存。
/// 只读页面不会写盘。
pub struct SettingsView {
    settings: AppSettings,
    context: SettingsContext,
    page: SettingsPage,
    /// 每个顶层分组是否展开；默认全部展开，导航自身可滚动。
    expanded_groups: [bool; 6],
    /// AI › Library 二级分组是否展开。
    library_expanded: bool,
    /// 侧栏搜索框。输入变化只触发本视图重绘，导航按标题过滤。
    search: Entity<InputState>,
    /// 搜索框的变更订阅，与设置页同生命周期。
    _search_subscription: Subscription,
    /// General › Hidden Paths 的两个模式输入框。
    hidden_directories: Entity<InputState>,
    hidden_files: Entity<InputState>,
    on_change: Option<ChangeHandler>,
    on_open_run: Option<OpenHandler>,
    on_open_agent: Option<OpenHandler>,
    /// Maven 项目配置：已保存值与 4 个字段草稿（对齐 Tauri MavenSettingsForm）。
    maven_saved: MavenLocalSettings,
    maven_effective: Option<MavenEffectiveSettings>,
    maven_inputs: [Entity<InputState>; 4],
    maven_error: Option<String>,
    /// 项目切换后待写入草稿输入框的值；输入框 API 需要 Window，
    /// 推迟到 Render 顶部应用。
    maven_pending_inputs: Option<[String; 4]>,
    /// Maven 项目的 reactor 路径；聚合根固定 "."。
    maven_reactor: String,
}

impl SettingsView {
    /// 构造设置页。这里只保存状态，不读写磁盘、不 spawn 任务。
    pub fn new(settings: AppSettings, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("Search settings"))
                .clean_on_escape()
        });
        let hidden_directories_value = settings.hidden_directory_patterns.join(", ");
        let hidden_files_value = settings.hidden_file_patterns.join(", ");
        let hidden_directories =
            cx.new(|cx| InputState::new(window, cx).default_value(hidden_directories_value));
        let hidden_files =
            cx.new(|cx| InputState::new(window, cx).default_value(hidden_files_value));
        let _search_subscription = cx.subscribe(&search, |this, state, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                // 搜索词变化可能让当前页不可见，切到第一个匹配页。
                let query = state.read(cx).value();
                if !query.trim().is_empty() && !this.page_matches(this.page, &query) {
                    if let Some(first) = this.first_matching_page(&query) {
                        this.page = first;
                    }
                }
                cx.notify();
            }
        });

        Self {
            settings,
            context: SettingsContext::default(),
            page: SettingsPage::General,
            expanded_groups: [true; 6],
            library_expanded: true,
            search,
            _search_subscription,
            hidden_directories,
            hidden_files,
            on_change: None,
            on_open_run: None,
            on_open_agent: None,
            maven_saved: MavenLocalSettings::default(),
            maven_effective: None,
            maven_inputs: [
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
            ],
            maven_error: None,
            maven_pending_inputs: None,
            maven_reactor: String::from("."),
        }
    }

    /// 把全部设置恢复为默认值并提交。Tauri 的 “Restore Defaults” 行为。
    pub fn restore_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings = AppSettings::default();
        self.commit(window, cx);
    }

    /// 页面标题是否命中当前搜索词。
    fn page_matches(&self, page: SettingsPage, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        query.is_empty() || tr(page.title()).to_lowercase().contains(&query)
    }

    /// 搜索时按侧栏顺序找到第一个命中的页面。
    fn first_matching_page(&self, query: &str) -> Option<SettingsPage> {
        for entry in SIDEBAR_LAYOUT {
            match entry {
                SidebarEntry::Page(page) => {
                    if self.page_matches(page, query) {
                        return Some(page);
                    }
                }
                SidebarEntry::Group(group) => {
                    for page in group.pages() {
                        if self.page_matches(*page, query) {
                            return Some(*page);
                        }
                    }
                }
            }
        }
        None
    }

    /// 用外部状态替换当前设置并重绘。不会触发 `on_change` 或写盘。
    pub fn set_settings(&mut self, settings: AppSettings, cx: &mut Context<Self>) {
        self.settings = settings;
        cx.notify();
    }

    /// 切到「AI 与提交」页。供 Git 提交区的 AI 入口直接跳转。
    pub fn open_ai_commit_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::AiCommit;
        cx.notify();
    }

    /// 直接落到「Project · JDK & Maven」页。Maven 工具窗的设置入口使用。
    pub fn open_project_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Project;
        cx.notify();
    }

    /// 直接落到「Git」页。Git Log 标题栏的设置入口使用（对齐 Tauri
    /// `openSettingsDialog("git")`）。
    pub fn open_git_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Git;
        cx.notify();
    }

    /// 更新只读工作台上下文并重绘。上下文变化不是设置修改，不写盘。
    pub fn set_context(&mut self, context: SettingsContext, cx: &mut Context<Self>) {
        let project_changed = self.context.project_root != context.project_root;
        self.context = context;
        if project_changed {
            self.reload_maven_configuration(cx);
        }
        cx.notify();
    }

    /// 重新读取 Maven 项目配置并解析生效值（Source-backed：打开页面只读，
    /// 草稿在输入框里，应用确认后才写回）。
    fn reload_maven_configuration(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            self.maven_saved = MavenLocalSettings::default();
            self.maven_effective = None;
            self.maven_pending_inputs = Some(Default::default());
            return;
        };
        let saved = configuration::load_local(&root, &self.maven_reactor);
        self.maven_pending_inputs = Some([
            saved.settings_path.clone().unwrap_or_default(),
            saved.local_repository_path.clone().unwrap_or_default(),
            saved.maven_executable_path.clone().unwrap_or_default(),
            saved.java_home_path.clone().unwrap_or_default(),
        ]);
        self.maven_saved = saved;
        self.maven_error = None;
        cx.notify();

        // 生效解析做文件探测，放后台；JAVA_HOME 检测值取本机环境变量
        // （与启动解析的默认来源一致；项目级覆盖解析由 resolve_effective 处理）。
        let java_home = std::env::var("JAVA_HOME")
            .ok()
            .filter(|value| !value.is_empty());
        let saved_for_resolve = self.maven_saved.clone();
        cx.spawn(async move |this, cx| {
            let effective = cx
                .background_spawn(async move {
                    configuration::resolve_effective(&root, ".", &saved_for_resolve, java_home)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.maven_effective = Some(effective);
                cx.notify();
            });
        })
        .detach();
    }

    /// 四个字段的标签与选择模式（文件 / 目录）。
    const MAVEN_FIELDS: [(&'static str, bool); 4] = [
        ("settings.xml", false),
        ("Maven local repository", true),
        ("Maven executable", true),
        ("JDK Home", true),
    ];

    /// 当前草稿与已保存值是否不同；不同才允许应用。
    fn maven_dirty(&self, cx: &Context<Self>) -> bool {
        let values = self.maven_draft_values(cx);
        values
            .iter()
            .zip([
                self.maven_saved.settings_path.as_deref(),
                self.maven_saved.local_repository_path.as_deref(),
                self.maven_saved.maven_executable_path.as_deref(),
                self.maven_saved.java_home_path.as_deref(),
            ])
            .any(|(draft, saved)| draft.trim() != saved.unwrap_or(""))
    }

    fn maven_draft_values(&self, cx: &Context<Self>) -> [String; 4] {
        [
            self.maven_inputs[0].read(cx).value().to_string(),
            self.maven_inputs[1].read(cx).value().to_string(),
            self.maven_inputs[2].read(cx).value().to_string(),
            self.maven_inputs[3].read(cx).value().to_string(),
        ]
    }

    /// 应用草稿：写回项目 Maven 配置（双写 Tauri/gpui 数据目录），成功后
    /// 重新解析生效值展示。
    fn apply_maven_configuration(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            return;
        };
        let values = self.maven_draft_values(cx);
        let saved = MavenLocalSettings {
            settings_path: Some(values[0].clone()).filter(|value| !value.trim().is_empty()),
            local_repository_path: Some(values[1].clone()).filter(|value| !value.trim().is_empty()),
            maven_executable_path: Some(values[2].clone()).filter(|value| !value.trim().is_empty()),
            java_home_path: Some(values[3].clone()).filter(|value| !value.trim().is_empty()),
        };
        match configuration::save_local(&root, &self.maven_reactor, &saved) {
            Ok(()) => {
                self.maven_error = None;
                self.maven_saved = saved;
                // 保存后重新解析生效配置，让「当前生效」提示反映新值。
                let java_home = std::env::var("JAVA_HOME")
                    .ok()
                    .filter(|value| !value.is_empty());
                let saved_for_resolve = self.maven_saved.clone();
                cx.spawn(async move |this, cx| {
                    let effective = cx
                        .background_spawn(async move {
                            configuration::resolve_effective(
                                &root,
                                ".",
                                &saved_for_resolve,
                                java_home,
                            )
                        })
                        .await;
                    let _ = this.update(cx, |this, cx| {
                        this.maven_effective = Some(effective);
                        cx.notify();
                    });
                })
                .detach();
                cx.notify();
            }
            Err(error) => {
                self.maven_error = Some(error);
                cx.notify();
            }
        }
    }

    /// 打开目录/文件选择器并回填对应草稿输入框。
    fn browse_maven_field(&mut self, index: usize, cx: &mut Context<Self>) {
        let (label, is_directory) = Self::MAVEN_FIELDS[index];
        let title = tr(label).to_string();
        let platform = platform::current();
        cx.spawn(async move |this, cx| {
            let picked = if is_directory {
                platform.pick_folder(title).await
            } else {
                platform
                    .pick_file(
                        title,
                        vec![platform::FileFilter {
                            name: String::from("XML"),
                            extensions: vec![String::from("xml")],
                        }],
                    )
                    .await
            };
            if let Some(path) = picked {
                let _ = this.update(cx, |this, cx| {
                    let text = path.to_string_lossy().into_owned();
                    let mut pending = this
                        .maven_pending_inputs
                        .take()
                        .unwrap_or_else(|| this.maven_draft_values(cx));
                    pending[index] = text;
                    this.maven_pending_inputs = Some(pending);
                    cx.notify();
                });
            }
        })
        .detach();
    }

    /// 当前设置的只读引用。
    pub fn settings(&self) -> &AppSettings {
        &self.settings
    }

    /// 注册设置变化回调。回调在字段更新之后、写盘之前调用，参数是更新后的
    /// 设置；同一时间只保留最后一个回调。
    pub fn on_change(&mut self, handler: impl Fn(&AppSettings, &mut Window, &mut App) + 'static) {
        self.on_change = Some(Rc::new(handler));
    }

    /// 注册“打开 Run 面板”回调；同一时间只保留最后一个回调。
    pub fn on_open_run(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_run = Some(Rc::new(handler));
    }

    /// 注册“打开 Agent 面板”回调；同一时间只保留最后一个回调。
    pub fn on_open_agent(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_agent = Some(Rc::new(handler));
    }

    /// 设置已更新的统一收尾：回调、写盘、重绘。
    fn commit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_change.as_ref() {
            handler(&self.settings, window, cx);
        }
        self.settings.save();
        cx.notify();
    }

    fn select_page(&mut self, page: SettingsPage, cx: &mut Context<Self>) {
        if self.page == page {
            return;
        }
        self.page = page;
        cx.notify();
    }

    fn toggle_group(&mut self, group: SettingsGroup, cx: &mut Context<Self>) {
        let index = group.index();
        self.expanded_groups[index] = !self.expanded_groups[index];
        cx.notify();
    }

    fn toggle_library(&mut self, cx: &mut Context<Self>) {
        self.library_expanded = !self.library_expanded;
        cx.notify();
    }

    fn invoke_open_run(&self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_open_run.as_ref() {
            handler(window, cx);
        }
    }

    fn invoke_open_agent(&self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_open_agent.as_ref() {
            handler(window, cx);
        }
    }

    // -----------------------------------------------------------------
    // 设置修改
    // -----------------------------------------------------------------

    fn set_theme(&mut self, theme: &'static str, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.theme.eq_ignore_ascii_case(theme) {
            return;
        }
        self.settings.theme = theme.to_string();
        self.commit(window, cx);
    }

    fn set_language(
        &mut self,
        language: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.language.eq_ignore_ascii_case(language) {
            return;
        }
        self.settings.language = language.to_string();
        // 先切全局语言，下一次渲染就会取到新词条。
        lithe_ui::i18n::set_language(language);
        self.commit(window, cx);
    }

    /// 外观模式：`system` 暂不监听系统主题，保留当前深浅色。
    fn set_appearance_mode(
        &mut self,
        mode: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.appearance_mode == mode {
            return;
        }
        self.settings.appearance_mode = mode.to_string();
        match mode {
            "dark" => self.settings.dark = true,
            "light" => self.settings.dark = false,
            _ => {}
        }
        self.commit(window, cx);
    }

    /// 打开项目时的默认落点。GPUI 目前按 `this-window` 打开；其余值先持久化。
    fn set_project_open_destination(
        &mut self,
        destination: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.project_open_destination == destination {
            return;
        }
        self.settings.project_open_destination = destination.to_string();
        self.commit(window, cx);
    }

    fn set_auto_save(&mut self, checked: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.auto_save == checked {
            return;
        }
        self.settings.auto_save = checked;
        self.commit(window, cx);
    }

    /// 保存隐藏路径模式：按行或逗号切分，空项丢弃。
    fn apply_hidden_patterns(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let parse = |value: String| -> Vec<String> {
            value
                .split(['\n', ','])
                .map(str::trim)
                .filter(|entry| !entry.is_empty())
                .map(str::to_string)
                .collect()
        };

        let directories = parse(self.hidden_directories.read(cx).value().to_string());
        let files = parse(self.hidden_files.read(cx).value().to_string());
        if self.settings.hidden_directory_patterns == directories
            && self.settings.hidden_file_patterns == files
        {
            return;
        }
        self.settings.hidden_directory_patterns = directories;
        self.settings.hidden_file_patterns = files;
        self.commit(window, cx);
    }

    fn set_update_channel(
        &mut self,
        channel: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.update_channel.eq_ignore_ascii_case(channel) {
            return;
        }
        self.settings.update_channel = channel.to_string();
        self.commit(window, cx);
    }

    fn set_auto_check_updates(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.auto_check_updates == enabled {
            return;
        }
        self.settings.auto_check_updates = enabled;
        self.commit(window, cx);
    }

    fn adjust_editor_font_size(&mut self, delta: i32, window: &mut Window, cx: &mut Context<Self>) {
        let next = normalized_font_size(
            self.settings.editor_font_size + delta as f32,
            DEFAULT_EDITOR_FONT_SIZE,
        );
        if (next - self.settings.editor_font_size).abs() < f32::EPSILON {
            return;
        }
        self.settings.editor_font_size = next;
        self.commit(window, cx);
    }

    fn set_editor_wrap(&mut self, wrap: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.editor_wrap == wrap {
            return;
        }
        self.settings.editor_wrap = wrap;
        self.commit(window, cx);
    }

    fn set_editor_minimap(&mut self, minimap: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.editor_minimap == minimap {
            return;
        }
        self.settings.editor_minimap = minimap;
        self.commit(window, cx);
    }

    fn set_editor_font_ligatures(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_font_ligatures == enabled {
            return;
        }
        self.settings.editor_font_ligatures = enabled;
        self.commit(window, cx);
    }

    fn set_editor_code_lens(&mut self, enabled: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.editor_code_lens == enabled {
            return;
        }
        self.settings.editor_code_lens = enabled;
        self.commit(window, cx);
    }

    fn set_editor_tab_size(
        &mut self,
        size: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Ok(size) = size.parse::<u32>() else {
            return;
        };
        if self.settings.editor_tab_size == size {
            return;
        }
        self.settings.editor_tab_size = size;
        self.commit(window, cx);
    }

    fn set_editor_line_numbers(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_line_numbers == enabled {
            return;
        }
        self.settings.editor_line_numbers = enabled;
        self.commit(window, cx);
    }

    fn set_editor_render_whitespace(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_render_whitespace == enabled {
            return;
        }
        self.settings.editor_render_whitespace = enabled;
        self.commit(window, cx);
    }

    fn set_editor_scroll_beyond_last_line(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_scroll_beyond_last_line == enabled {
            return;
        }
        self.settings.editor_scroll_beyond_last_line = enabled;
        self.commit(window, cx);
    }

    fn set_run_services_on_exit(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .settings
            .run_services_on_exit
            .eq_ignore_ascii_case(policy)
        {
            return;
        }
        self.settings.run_services_on_exit = policy.to_string();
        self.commit(window, cx);
    }

    fn set_terminal_on_quit(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.terminal_on_quit.eq_ignore_ascii_case(policy) {
            return;
        }
        self.settings.terminal_on_quit = policy.to_string();
        self.commit(window, cx);
    }

    fn set_agent_tasks(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.agent_tasks.eq_ignore_ascii_case(policy) {
            return;
        }
        self.settings.agent_tasks = policy.to_string();
        self.commit(window, cx);
    }

    fn set_background_services(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .settings
            .background_services
            .eq_ignore_ascii_case(policy)
        {
            return;
        }
        self.settings.background_services = policy.to_string();
        self.commit(window, cx);
    }

    fn adjust_graceful_stop(&mut self, delta: i32, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.settings.graceful_stop_seconds as i32;
        let next = (current + delta).clamp(
            MIN_GRACEFUL_STOP_SECONDS as i32,
            MAX_GRACEFUL_STOP_SECONDS as i32,
        ) as u32;
        if next == self.settings.graceful_stop_seconds {
            return;
        }
        self.settings.graceful_stop_seconds = next;
        self.commit(window, cx);
    }

    fn adjust_terminal_font_size(
        &mut self,
        delta: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let next = normalized_font_size(
            self.settings.terminal_font_size + delta as f32,
            DEFAULT_TERMINAL_FONT_SIZE,
        );
        if (next - self.settings.terminal_font_size).abs() < f32::EPSILON {
            return;
        }
        self.settings.terminal_font_size = next;
        self.commit(window, cx);
    }

    /// 终端回滚行数按 500 行为一档调整；磁盘里的任意值都能正确显示和继续调整。
    fn adjust_terminal_scrollback(
        &mut self,
        step: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let delta = step as i64 * TERMINAL_SCROLLBACK_STEP as i64;
        let next = (self.settings.terminal_scrollback as i64 + delta).clamp(
            MIN_TERMINAL_SCROLLBACK as i64,
            MAX_TERMINAL_SCROLLBACK as i64,
        ) as u32;
        if next == self.settings.terminal_scrollback {
            return;
        }
        self.settings.terminal_scrollback = next;
        self.commit(window, cx);
    }

    fn set_ai_commit_enabled(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.ai_commit_enabled == enabled {
            return;
        }
        self.settings.ai_commit_enabled = enabled;
        self.commit(window, cx);
    }

    fn set_ai_commit_format(
        &mut self,
        format: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.ai_commit_format.eq_ignore_ascii_case(format) {
            return;
        }
        self.settings.ai_commit_format = format.to_string();
        self.commit(window, cx);
    }

    /// 互斥按钮行的统一入口。
    fn apply_choice(
        &mut self,
        action: ChoiceAction,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            ChoiceAction::Theme => self.set_theme(value, window, cx),
            ChoiceAction::AppearanceMode => self.set_appearance_mode(value, window, cx),
            ChoiceAction::ProjectOpenDestination => {
                self.set_project_open_destination(value, window, cx)
            }
            ChoiceAction::EditorTabSize => self.set_editor_tab_size(value, window, cx),
            ChoiceAction::GitDiffView => self.set_git_default_diff_view(value, window, cx),
            ChoiceAction::GitFetchSubmodules => self.set_git_fetch_submodules(value, window, cx),
            ChoiceAction::GitFetchTags => self.set_git_fetch_tags(value, window, cx),
            ChoiceAction::KeymapPreset => self.set_keymap_preset(value, window, cx),
            ChoiceAction::Language => self.set_language(value, window, cx),
            ChoiceAction::UpdateChannel => self.set_update_channel(value, window, cx),
            ChoiceAction::RunServices => self.set_run_services_on_exit(value, window, cx),
            ChoiceAction::TerminalOnQuit => self.set_terminal_on_quit(value, window, cx),
            ChoiceAction::AgentTasks => self.set_agent_tasks(value, window, cx),
            ChoiceAction::BackgroundServices => self.set_background_services(value, window, cx),
            ChoiceAction::CommitFormat => self.set_ai_commit_format(value, window, cx),
        }
    }

    /// Git / Keymap / AI 布尔开关的统一入口。
    fn apply_toggle(
        &mut self,
        action: ToggleAction,
        checked: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let target = match action {
            ToggleAction::GitIntegration => &mut self.settings.git_integration,
            ToggleAction::GitAutoRefresh => &mut self.settings.git_auto_refresh,
            ToggleAction::GitConfirmDiscard => &mut self.settings.git_confirm_discard,
            ToggleAction::GitFolderView => &mut self.settings.git_changes_folder_view,
            ToggleAction::GitUntracked => &mut self.settings.git_show_untracked,
            ToggleAction::GitStagedFirst => &mut self.settings.git_show_staged_first,
            ToggleAction::GitOpenDiff => &mut self.settings.git_open_diff_on_click,
            ToggleAction::GitCompactBadges => &mut self.settings.git_compact_badges,
            ToggleAction::GitCollapseEmpty => &mut self.settings.git_collapse_empty,
            ToggleAction::GitInlineBlame => &mut self.settings.git_inline_blame,
            ToggleAction::GitGutter => &mut self.settings.git_gutter,
            ToggleAction::GitFetchPrune => &mut self.settings.git_fetch_prune,
            ToggleAction::VimMode => &mut self.settings.vim_mode,
            ToggleAction::AiAutocomplete => &mut self.settings.ai_autocomplete,
        };
        if *target == checked {
            return;
        }
        *target = checked;
        self.commit(window, cx);
    }

    fn set_git_default_diff_view(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.git_default_diff_view == value {
            return;
        }
        self.settings.git_default_diff_view = value.to_string();
        self.commit(window, cx);
    }

    fn set_git_fetch_submodules(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.git_fetch_submodules == value {
            return;
        }
        self.settings.git_fetch_submodules = value.to_string();
        self.commit(window, cx);
    }

    fn set_git_fetch_tags(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.git_fetch_tags == value {
            return;
        }
        self.settings.git_fetch_tags = value.to_string();
        self.commit(window, cx);
    }

    fn set_keymap_preset(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.keymap_preset == value {
            return;
        }
        self.settings.keymap_preset = value.to_string();
        self.commit(window, cx);
    }

    /// 步进器的统一入口。
    fn apply_step(
        &mut self,
        action: StepperAction,
        delta: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            StepperAction::EditorFontSize => self.adjust_editor_font_size(delta, window, cx),
            StepperAction::TerminalFontSize => self.adjust_terminal_font_size(delta, window, cx),
            StepperAction::TerminalScrollback => self.adjust_terminal_scrollback(delta, window, cx),
            StepperAction::GracefulStop => self.adjust_graceful_stop(delta, window, cx),
        }
    }

    /// 步进器“恢复默认”的统一入口；值本来就在默认值时直接返回，不写盘。
    fn apply_reset(&mut self, action: StepperAction, window: &mut Window, cx: &mut Context<Self>) {
        let changed = match action {
            StepperAction::EditorFontSize => self.settings.reset_editor_font_size(),
            StepperAction::TerminalFontSize => {
                if (self.settings.terminal_font_size - DEFAULT_TERMINAL_FONT_SIZE).abs()
                    < f32::EPSILON
                {
                    false
                } else {
                    self.settings.terminal_font_size = DEFAULT_TERMINAL_FONT_SIZE;
                    true
                }
            }
            StepperAction::TerminalScrollback => {
                if self.settings.terminal_scrollback == DEFAULT_TERMINAL_SCROLLBACK {
                    false
                } else {
                    self.settings.terminal_scrollback = DEFAULT_TERMINAL_SCROLLBACK;
                    true
                }
            }
            StepperAction::GracefulStop => {
                if self.settings.graceful_stop_seconds == DEFAULT_GRACEFUL_STOP_SECONDS {
                    false
                } else {
                    self.settings.graceful_stop_seconds = DEFAULT_GRACEFUL_STOP_SECONDS;
                    true
                }
            }
        };

        if changed {
            self.commit(window, cx);
        }
    }

    // -----------------------------------------------------------------
    // 导航
    // -----------------------------------------------------------------

    fn render_nav(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let query = self.search.read(cx).value();
        let searching = !query.trim().is_empty();
        let mut any_visible = false;
        let mut items = div().flex().flex_col();

        for entry in SIDEBAR_LAYOUT {
            match entry {
                SidebarEntry::Group(group) => {
                    if self.group_visible(group, &query) {
                        any_visible = true;
                        items = items.child(self.render_group(group, tokens, cx));
                    }
                }
                SidebarEntry::Page(page) => {
                    if self.page_matches(page, &query) {
                        any_visible = true;
                        items = items.child(self.render_page_item(page, 0, tokens, cx));
                    }
                }
            }
        }

        div()
            .id("lithe-settings:nav")
            .w(px(SETTINGS_NAV_WIDTH))
            .h_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .bg(tokens.sidebar)
            // Tauri：搜索框距顶部 12、左右 8、底部 12。
            .child(
                div().px(px(8.0)).pt(px(12.0)).pb(px(12.0)).child(
                    Input::new(&self.search).small().prefix(
                        Icon::new(IconName::Search)
                            .with_size(px(14.0))
                            .text_color(tokens.tertiary_text),
                    ),
                ),
            )
            .child(
                div()
                    .id("lithe-settings:nav-scroll")
                    .flex_1()
                    .min_h(px(0.0))
                    .pb(px(12.0))
                    .overflow_y_scroll()
                    .when(searching && !any_visible, |this| {
                        this.child(
                            div()
                                .px(px(12.0))
                                .py(px(8.0))
                                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(tr("No settings found")),
                        )
                    })
                    .child(items),
            )
            .into_any_element()
    }

    /// 分组标题或任一子页面命中搜索词时显示该分组。
    fn group_visible(&self, group: SettingsGroup, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        query.is_empty()
            || tr(group.title()).to_lowercase().contains(&query)
            || group
                .pages()
                .iter()
                .any(|page| self.page_matches(*page, &query))
    }

    fn render_group(
        &self,
        group: SettingsGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let mut column = div()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_NAV_GAP))
            .child(self.render_group_header(group, tokens, cx));

        if self.expanded_groups[group.index()] || searching {
            if group == SettingsGroup::Ai {
                // AI 的条目顺序与 macOS 一致：Providers / Agents / Library / AI & Commit。
                column = column
                    .child(self.render_page_item(SettingsPage::AiProviders, 1, tokens, cx))
                    .child(self.render_page_item(SettingsPage::Agents, 1, tokens, cx));

                let query = self.search.read(cx).value();
                let library_visible = !searching
                    || LIBRARY_PAGES
                        .iter()
                        .any(|page| self.page_matches(*page, &query));
                if library_visible {
                    column = column.child(self.render_library_header(tokens, cx));
                    if self.library_expanded || searching {
                        for page in LIBRARY_PAGES {
                            column = column.child(self.render_page_item(page, 2, tokens, cx));
                        }
                    }
                }

                column = column.child(self.render_page_item(SettingsPage::AiCommit, 1, tokens, cx));
            } else {
                for page in group.pages() {
                    column = column.child(self.render_page_item(*page, 1, tokens, cx));
                }
            }
        }

        column.into_any_element()
    }

    fn render_group_header(
        &self,
        group: SettingsGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let expanded = self.expanded_groups[group.index()] || searching;
        let contains_selection = self.page.group() == Some(group);

        div()
            .id(group.id())
            .w_full()
            .h(px(SETTINGS_NAV_GROUP_HEIGHT))
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(4.0))
            .px(px(SETTINGS_NAV_ITEM_PADDING))
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(if contains_selection {
                tokens.primary_text
            } else {
                tokens.secondary_text
            })
            .child(
                // Tauri 用 CaretDown/CaretRight 图标（size-3），不是文本箭头。
                icon(if expanded {
                    LitheIcon::ChevronDown
                } else {
                    LitheIcon::ChevronRight
                })
                .with_size(px(12.0))
                .flex_shrink_0()
                .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .truncate()
                    .child(tr(group.title())),
            )
            .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                this.toggle_group(group, cx);
            }))
            .into_any_element()
    }

    fn render_library_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let expanded = self.library_expanded || searching;

        div()
            .id("lithe-settings:nav:library")
            .w_full()
            .h(px(SETTINGS_NAV_GROUP_HEIGHT))
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(4.0))
            .pl(px(40.0))
            .pr(px(SETTINGS_NAV_ITEM_PADDING))
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(tokens.secondary_text)
            .child(
                icon(if expanded {
                    LitheIcon::ChevronDown
                } else {
                    LitheIcon::ChevronRight
                })
                .with_size(px(12.0))
                .flex_shrink_0()
                .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .truncate()
                    .child(tr("Library")),
            )
            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                this.toggle_library(cx);
            }))
            .into_any_element()
    }

    fn render_page_item(
        &self,
        page: SettingsPage,
        depth: usize,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let query = self.search.read(cx).value();
        if !self.page_matches(page, &query) {
            return div().into_any_element();
        }

        let selected = self.page == page;
        // Tauri：顶层页面 pl-6（24），分组内页面 pl-10（40），Library 二级
        // 页面再缩进一级（56）。
        let padding_left = match depth {
            0 => 24.0,
            1 => 40.0,
            _ => 56.0,
        };

        div()
            .id(page.id())
            .w_full()
            .h(px(SETTINGS_NAV_ROW_HEIGHT))
            .flex_shrink_0()
            .flex()
            .items_center()
            .pl(px(padding_left))
            .pr(px(SETTINGS_NAV_ITEM_PADDING))
            .cursor_pointer()
            // Tauri 选中态：`bg-primary/15`，方角，全宽。
            .when(selected, |this| this.bg(tokens.selection.alpha(0.15)))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(if depth == 0 {
                FontWeight::SEMIBOLD
            } else {
                FontWeight::NORMAL
            })
            .text_color(if selected {
                tokens.primary_text
            } else {
                tokens.secondary_text
            })
            .child(tr(page.title()))
            .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                this.select_page(page, cx);
            }))
            .into_any_element()
    }

    // -----------------------------------------------------------------
    // 内容区
    // -----------------------------------------------------------------

    fn render_content(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let page = self.page;
        let body = match page {
            SettingsPage::General => self.render_general(tokens, cx),
            SettingsPage::Updates => self.render_updates(tokens, cx),
            SettingsPage::Editor => self.render_editor(tokens, cx),
            SettingsPage::Keymap => self.render_keymap(tokens, cx),
            SettingsPage::ProcessTermination => self.render_process_termination(tokens, cx),
            SettingsPage::Plugins => self.render_plugins(tokens),
            SettingsPage::Git => self.render_git(tokens, cx),
            SettingsPage::Project => self.render_project(tokens, cx),
            SettingsPage::RunConfigurations => self.render_run_configurations(tokens, cx),
            SettingsPage::Lsp => self.render_lsp(tokens),
            SettingsPage::Terminal => self.render_terminal(tokens, cx),
            SettingsPage::Diagnostics => self.render_diagnostics(tokens),
            SettingsPage::AiProviders => self.render_ai_providers(tokens, cx),
            SettingsPage::Agents => self.render_agents(tokens, cx),
            SettingsPage::Instructions
            | SettingsPage::Skills
            | SettingsPage::Hooks
            | SettingsPage::Mcp => self.render_agent_library_page(page, tokens, cx),
            SettingsPage::AiCommit => self.render_ai_commit(tokens, cx),
        };

        div()
            .id("lithe-settings:content")
            .flex_1()
            .min_w(px(SETTINGS_CONTENT_MIN_WIDTH))
            .min_h(px(0.0))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            // Tauri：px-4 pt-4 pb-5。
            .px(px(16.0))
            .pt(px(16.0))
            .pb(px(20.0))
            .bg(tokens.editor)
            .child(body)
            .into_any_element()
    }

    /// 内容区顶部固定 48pt 面包屑：分组 › 页面。
    fn render_breadcrumb(&self, tokens: LitheTokens) -> AnyElement {
        let page = self.page;
        let mut row = div().flex().items_center().gap(px(6.0)).child(
            div()
                .flex_shrink_0()
                .child(tr(page.title()))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE)),
        );

        if page != SettingsPage::Plugins {
            if let Some(group) = page.group() {
                let mut trail = div()
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .text_color(tokens.secondary_text)
                    .child(tr(group.title()))
                    .child(
                        icon(LitheIcon::ChevronRight)
                            .with_size(px(12.0))
                            .text_color(tokens.tertiary_text),
                    );

                // Library 是 AI 下的二级分组，面包屑保持三级。
                if LIBRARY_PAGES.contains(&page) {
                    trail = trail.child(tr("Library")).child(
                        icon(LitheIcon::ChevronRight)
                            .with_size(px(12.0))
                            .text_color(tokens.tertiary_text),
                    );
                }

                row = trail.child(
                    div()
                        .text_color(tokens.primary_text)
                        .child(tr(page.title())),
                );
            }
        }

        div()
            .w_full()
            .h(px(48.0))
            .flex_shrink_0()
            .flex()
            .items_center()
            .px(px(16.0))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(tokens.primary_text)
            .child(row)
            .into_any_element()
    }

    fn render_general(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // Tauri General › Appearance：颜色主题 + 外观模式。
        let appearance = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Color Theme",
                "lithe-settings:theme",
                &THEMES,
                &self.settings.theme,
                ChoiceAction::Theme,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Appearance mode",
                "lithe-settings:appearance-mode",
                &APPEARANCE_MODES,
                &self.settings.appearance_mode,
                ChoiceAction::AppearanceMode,
                cx,
                tokens,
            ));

        let language = div().w_full().flex().flex_col().child(choice_row(
            "Language",
            "lithe-settings:language",
            &LANGUAGES,
            &self.settings.language,
            ChoiceAction::Language,
            cx,
            tokens,
        ));

        // Tauri General › Projects：打开另一个项目时的默认落点。
        let projects = div().w_full().flex().flex_col().child(choice_row(
            "Open projects in",
            "lithe-settings:project-open-destination",
            &PROJECT_OPEN_DESTINATIONS,
            &self.settings.project_open_destination,
            ChoiceAction::ProjectOpenDestination,
            cx,
            tokens,
        ));

        // Tauri General › Files：保存后自动保存。
        let files = div().w_full().flex().flex_col().child(setting_row(
            "Save changed files automatically",
            switch_control(
                "lithe-settings:auto-save",
                self.settings.auto_save,
                "Save changed files automatically",
                cx.listener(|this, checked: &bool, window, cx| {
                    this.set_auto_save(*checked, window, cx);
                }),
            ),
            on_off(self.settings.auto_save),
            tokens,
        ));

        // Tauri General › Hidden paths：目录与文件模式 + Apply。
        let hidden_paths = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(10.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "One entry per line. Directory names hide matching folders; file entries support * and ?.",
                    )),
            )
            .child(pattern_field("Directories", &self.hidden_directories, tokens))
            .child(pattern_field("File patterns", &self.hidden_files, tokens))
            .child(
                div().w_full().flex().justify_end().child(
                    Button::new("lithe-settings:hidden-paths:apply")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(tr("Apply"))
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.apply_hidden_patterns(window, cx);
                        })),
                ),
            );

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Appearance",
                None,
                appearance.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Language",
                None,
                language.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Projects",
                None,
                projects.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Files",
                None,
                files.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Hidden paths",
                None,
                hidden_paths.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    fn render_updates(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let version = SharedString::from(format!("{} (GPUI build)", env!("CARGO_PKG_VERSION")));

        let version_card = div().w_full().flex().flex_col().child(readonly_row(
            "Current version",
            version,
            tokens,
        ));

        let channel_card = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Update channel",
                "lithe-settings:update-channel",
                &UPDATE_CHANNELS,
                &self.settings.update_channel,
                ChoiceAction::UpdateChannel,
                cx,
                tokens,
            ))
            .child(setting_row(
                "Auto check",
                switch_control(
                    "lithe-settings:auto-check-updates",
                    self.settings.auto_check_updates,
                    "Auto check for updates",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_auto_check_updates(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.auto_check_updates),
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Application version",
                None,
                version_card.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Update channel",
                None,
                channel_card.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "Automatic updates are not available in this build yet. The channel and auto-check choices are saved for a future update service.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_editor(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let display = div()
            .w_full()
            .flex()
            .flex_col()
            .child(stepper_row(
                "Font size",
                "lithe-settings:editor-font-size",
                self.settings.editor_font_size,
                MIN_EDITOR_FONT_SIZE,
                MAX_EDITOR_FONT_SIZE,
                DEFAULT_EDITOR_FONT_SIZE,
                StepperAction::EditorFontSize,
                SharedString::from(format!(
                    "{} pt",
                    self.settings.editor_font_size.round() as i32
                )),
                cx,
                tokens,
            ))
            .child(setting_row(
                "Font Ligatures",
                switch_control(
                    "lithe-settings:editor-font-ligatures",
                    self.settings.editor_font_ligatures,
                    "Font Ligatures",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_font_ligatures(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_font_ligatures),
                tokens,
            ))
            .child(font_preview(self.settings.editor_font_ligatures, tokens))
            .child(setting_row(
                "Show usages and Git author",
                switch_control(
                    "lithe-settings:editor-code-lens",
                    self.settings.editor_code_lens,
                    "Show usages and Git author",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_code_lens(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_code_lens),
                tokens,
            ))
            .child(setting_row(
                "Wrap lines",
                switch_control(
                    "lithe-settings:editor-wrap",
                    self.settings.editor_wrap,
                    "Wrap lines",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_wrap(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_wrap),
                tokens,
            ))
            .child(setting_row(
                "Minimap",
                switch_control(
                    "lithe-settings:editor-minimap",
                    self.settings.editor_minimap,
                    "Show minimap",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_minimap(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_minimap),
                tokens,
            ))
            .child(setting_row(
                "Line numbers",
                switch_control(
                    "lithe-settings:editor-line-numbers",
                    self.settings.editor_line_numbers,
                    "Show line numbers",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_line_numbers(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_line_numbers),
                tokens,
            ))
            .child(setting_row(
                "Render Whitespace",
                switch_control(
                    "lithe-settings:editor-render-whitespace",
                    self.settings.editor_render_whitespace,
                    "Render Whitespace",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_render_whitespace(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_render_whitespace),
                tokens,
            ))
            .child(setting_row(
                "Scroll beyond last line",
                switch_control(
                    "lithe-settings:editor-scroll-beyond",
                    self.settings.editor_scroll_beyond_last_line,
                    "Scroll beyond last line",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_scroll_beyond_last_line(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_scroll_beyond_last_line),
                tokens,
            ));

        // Tauri Editor › Indentation：Tab 宽度。
        let indentation = div().w_full().flex().flex_col().child(choice_row(
            "Tab width",
            "lithe-settings:editor-tab-size",
            &TAB_WIDTHS,
            &self.settings.editor_tab_size.to_string(),
            ChoiceAction::EditorTabSize,
            cx,
            tokens,
        ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Display",
                None,
                display.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Indentation",
                None,
                indentation.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    fn render_keymap(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        const SHORTCUTS: [(&str, &str); 6] = [
            ("Open Project", "Ctrl/Cmd+O"),
            ("Settings", "Ctrl/Cmd+,"),
            ("Search", "Ctrl/Cmd+Shift+F"),
            ("Git", "Ctrl/Cmd+Shift+G"),
            ("Command Palette", "Ctrl/Cmd+Shift+P"),
            ("Save", "Ctrl/Cmd+S"),
        ];

        let mut rows = div().w_full().flex().flex_col();
        for (action, shortcut) in SHORTCUTS {
            rows = rows.child(readonly_row(action, SharedString::from(shortcut), tokens));
        }

        // Tauri Keyboard：预设 + Vim 模式，然后是当前快捷键列表。
        let presets = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Keybinding Preset",
                "lithe-settings:keymap-preset",
                &KEYMAP_PRESETS,
                &self.settings.keymap_preset,
                ChoiceAction::KeymapPreset,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Vim Mode",
                "lithe-settings:vim-mode",
                self.settings.vim_mode,
                ToggleAction::VimMode,
                cx,
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card("Keymap", None, presets.into_any_element(), tokens))
            .child(section_card(
                "Current shortcuts",
                None,
                rows.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "Shortcut customization is not wired up in this build. These are the shortcuts registered by the GPUI workbench.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_process_termination(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let policies = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Run services",
                "lithe-settings:run-services",
                &RUN_SERVICE_OPTIONS,
                &self.settings.run_services_on_exit,
                ChoiceAction::RunServices,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Terminals",
                "lithe-settings:terminal-on-quit",
                &TERMINAL_QUIT_OPTIONS,
                &self.settings.terminal_on_quit,
                ChoiceAction::TerminalOnQuit,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Agent tasks",
                "lithe-settings:agent-tasks",
                &AGENT_TASK_OPTIONS,
                &self.settings.agent_tasks,
                ChoiceAction::AgentTasks,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Background services",
                "lithe-settings:background-services",
                &BACKGROUND_SERVICE_OPTIONS,
                &self.settings.background_services,
                ChoiceAction::BackgroundServices,
                cx,
                tokens,
            ))
            .child(stepper_row(
                "Graceful stop seconds",
                "lithe-settings:graceful-stop",
                self.settings.graceful_stop_seconds as f32,
                MIN_GRACEFUL_STOP_SECONDS as f32,
                MAX_GRACEFUL_STOP_SECONDS as f32,
                DEFAULT_GRACEFUL_STOP_SECONDS as f32,
                StepperAction::GracefulStop,
                SharedString::from(format!("{} s", self.settings.graceful_stop_seconds)),
                cx,
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "When quitting Lithe",
                None,
                policies.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "These choices are stored now; they are enforced once long-lived run services, terminals, agent tasks, and background services land in the GPUI build.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_plugins(&self, tokens: LitheTokens) -> AnyElement {
        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(status_card(
                SharedString::from(tr("Plugin system is not available in the GPUI build yet.")),
                tokens,
            ))
            .into_any_element()
    }

    fn render_git(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let context = div()
            .w_full()
            .flex()
            .flex_col()
            .child(readonly_row(
                "Project",
                project_root_label(self.context.project_root.as_ref()),
                tokens,
            ))
            .child(readonly_row(
                "Branch",
                string_or_placeholder(&self.context.branch, "Not available"),
                tokens,
            ));

        let integration = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Git Integration",
                "lithe-settings:git-integration",
                self.settings.git_integration,
                ToggleAction::GitIntegration,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Auto Refresh Git Status",
                "lithe-settings:git-auto-refresh",
                self.settings.git_auto_refresh,
                ToggleAction::GitAutoRefresh,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Confirm Before Discard",
                "lithe-settings:git-confirm-discard",
                self.settings.git_confirm_discard,
                ToggleAction::GitConfirmDiscard,
                cx,
                tokens,
            ));

        let view = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Folder-Based Changes",
                "lithe-settings:git-folder-view",
                self.settings.git_changes_folder_view,
                ToggleAction::GitFolderView,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Show Untracked Files",
                "lithe-settings:git-untracked",
                self.settings.git_show_untracked,
                ToggleAction::GitUntracked,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Show Staged First",
                "lithe-settings:git-staged-first",
                self.settings.git_show_staged_first,
                ToggleAction::GitStagedFirst,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Open Diff On Click",
                "lithe-settings:git-open-diff",
                self.settings.git_open_diff_on_click,
                ToggleAction::GitOpenDiff,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Compact Git Status Badges",
                "lithe-settings:git-compact-badges",
                self.settings.git_compact_badges,
                ToggleAction::GitCompactBadges,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Collapse Empty Sections",
                "lithe-settings:git-collapse-empty",
                self.settings.git_collapse_empty,
                ToggleAction::GitCollapseEmpty,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Default Diff View",
                "lithe-settings:git-diff-view",
                &DIFF_VIEWS,
                &self.settings.git_default_diff_view,
                ChoiceAction::GitDiffView,
                cx,
                tokens,
            ));

        let inline = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Enable Inline Blame",
                "lithe-settings:git-inline-blame",
                self.settings.git_inline_blame,
                ToggleAction::GitInlineBlame,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Enable Git Gutter",
                "lithe-settings:git-gutter",
                self.settings.git_gutter,
                ToggleAction::GitGutter,
                cx,
                tokens,
            ));

        let fetch = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Prune stale remote-tracking references",
                "lithe-settings:git-fetch-prune",
                self.settings.git_fetch_prune,
                ToggleAction::GitFetchPrune,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Fetch submodules",
                "lithe-settings:git-fetch-submodules",
                &FETCH_SUBMODULES,
                &self.settings.git_fetch_submodules,
                ChoiceAction::GitFetchSubmodules,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Fetch tags",
                "lithe-settings:git-fetch-tags",
                &FETCH_TAGS,
                &self.settings.git_fetch_tags,
                ChoiceAction::GitFetchTags,
                cx,
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Repository",
                None,
                context.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Git integration",
                None,
                integration.into_any_element(),
                tokens,
            ))
            .child(section_card("View", None, view.into_any_element(), tokens))
            .child(section_card(
                "Inline",
                None,
                inline.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Fetch defaults",
                None,
                fetch.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    fn render_project(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let project_root_row = readonly_row(
            "Project root",
            project_root_label(self.context.project_root.as_ref()),
            tokens,
        );

        // Maven 设置表单：无项目时展示说明；有项目时四个字段的草稿编辑 +
        // 检测值提示 + 应用按钮（对齐 Tauri `MavenSettingsForm`）。
        let Some(root) = self.context.project_root.clone() else {
            return div()
                .w_full()
                .flex()
                .flex_col()
                .gap(px(SETTINGS_SECTION_GAP))
                .child(section_card(
                    "Project",
                    None,
                    project_root_row.into_any_element(),
                    tokens,
                ))
                .child(note_card(
                    SharedString::from(tr(
                        "Open a Maven project to configure its settings.xml, local repository, Maven executable and JDK home.",
                    )),
                    tokens,
                ))
                .into_any_element();
        };
        let _ = root;

        let mut fields = v_flex().w_full().gap(px(SETTINGS_SECTION_GAP));
        let resolutions = [
            self.maven_effective.as_ref().map(|e| &e.settings_path),
            self.maven_effective
                .as_ref()
                .map(|e| &e.local_repository_path),
            self.maven_effective
                .as_ref()
                .map(|e| &e.maven_executable_path),
            self.maven_effective.as_ref().map(|e| &e.java_home_path),
        ];
        for (index, (label, _directory)) in Self::MAVEN_FIELDS.iter().enumerate() {
            let resolution = resolutions[index];
            let mut row = v_flex()
                .w_full()
                .gap(px(4.0))
                .child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(tr(label)),
                )
                .child(
                    h_flex()
                        .w_full()
                        .gap(px(6.0))
                        .child(
                            Input::new(&self.maven_inputs[index])
                                .small()
                                .w_full()
                                .font_family(MONO_FONT_FAMILY),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "lithe-settings:maven-clear:{index}"
                            )))
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::Close))
                            .tooltip(tr("Clear"))
                            .on_click(cx.listener(
                                move |this, _: &ClickEvent, _window, cx| {
                                    let mut pending = this
                                        .maven_pending_inputs
                                        .take()
                                        .unwrap_or_else(|| this.maven_draft_values(cx));
                                    pending[index] = String::new();
                                    this.maven_pending_inputs = Some(pending);
                                    cx.notify();
                                },
                            )),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "lithe-settings:maven-browse:{index}"
                            )))
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::Folder))
                            .tooltip(tr("Browse"))
                            .on_click(cx.listener(
                                move |this, _: &ClickEvent, _window, cx| {
                                    this.browse_maven_field(index, cx);
                                },
                            )),
                        ),
                );

            // 检测值 / 生效值提示（对齐 Tauri `MavenDetectedValue`）。
            if let Some(resolution) = resolution {
                let effective = resolution.effective.clone().unwrap_or_default();
                let detected = resolution.detected.clone().unwrap_or_default();
                let hint: SharedString = if effective.is_empty() {
                    tr("Not detected").into()
                } else if detected.is_empty() || detected == effective {
                    SharedString::from(format!("{} · {}", tr("In effect"), effective))
                } else {
                    SharedString::from(format!(
                        "{} · {}\n{}: {}",
                        tr("In effect"),
                        effective,
                        tr("Detected"),
                        detected
                    ))
                };
                row = row.child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(hint),
                );
            }
            fields = fields.child(row);
        }

        let dirty = self.maven_dirty(cx);
        let mut card = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(fields);
        if let Some(error) = self.maven_error.clone() {
            card = card.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }
        card = card.child(
            h_flex().w_full().justify_end().child(
                Button::new("lithe-settings:maven-apply")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .primary()
                    .label(tr("Apply"))
                    .disabled(!dirty)
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.apply_maven_configuration(cx);
                    })),
            ),
        );

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card("Maven", None, card.into_any_element(), tokens))
            .into_any_element()
    }

    fn render_run_configurations(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let card = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "Run configurations are detected from project files. The Run panel shows what Lithe found for the open project.",
                    )),
            )
            .child(
                Button::new("lithe-settings:open-run")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .secondary()
                    .label(tr("Open Run panel"))
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.invoke_open_run(window, cx);
                    })),
            );

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Detected configurations",
                None,
                card.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "Editing run configurations in this page is not wired up in the GPUI build; the Run panel is the source of truth.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_lsp(&self, tokens: LitheTokens) -> AnyElement {
        const SERVICES: [&str; 5] = ["Java", "Markdown", "XML", "CSS", "HTML"];

        let mut rows = div().w_full().flex().flex_col();
        for service in SERVICES {
            rows = rows.child(readonly_row(
                service,
                SharedString::from(tr("Built in")),
                tokens,
            ));
        }

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Language services",
                None,
                rows.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "These lightweight language services are built into Lithe. Full LSP servers are not wired into the GPUI build yet.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_terminal(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let display = div().w_full().flex().flex_col().child(stepper_row(
            "Font size",
            "lithe-settings:terminal-font-size",
            self.settings.terminal_font_size,
            MIN_EDITOR_FONT_SIZE,
            MAX_EDITOR_FONT_SIZE,
            DEFAULT_TERMINAL_FONT_SIZE,
            StepperAction::TerminalFontSize,
            SharedString::from(format!(
                "{} pt",
                self.settings.terminal_font_size.round() as i32
            )),
            cx,
            tokens,
        ));

        // 回滚行数用步进器而不是固定档位：磁盘上可能保存着 3000 这类
        // 非预设值，固定按钮会显示成“无选中”，重新打开时回显错误。
        let scrollback = div().w_full().flex().flex_col().child(stepper_row(
            "Scrollback",
            "lithe-settings:terminal-scrollback",
            self.settings.terminal_scrollback as f32,
            MIN_TERMINAL_SCROLLBACK as f32,
            MAX_TERMINAL_SCROLLBACK as f32,
            DEFAULT_TERMINAL_SCROLLBACK as f32,
            StepperAction::TerminalScrollback,
            SharedString::from(self.settings.terminal_scrollback.to_string()),
            cx,
            tokens,
        ));

        // Tauri Terminal › Shell：显示当前实际使用的系统默认 shell。
        let default_shell = std::env::var("COMSPEC")
            .or_else(|_| std::env::var("SHELL"))
            .unwrap_or_default();
        let shell = div().w_full().flex().flex_col().child(readonly_row(
            "Default shell",
            string_or_placeholder(&default_shell, "System default"),
            tokens,
        ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card("Shell", None, shell.into_any_element(), tokens))
            .child(section_card(
                "Display",
                None,
                display.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Scrollback",
                None,
                scrollback.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "New terminals use the system default shell. Shell selection is not wired up in this build.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_diagnostics(&self, tokens: LitheTokens) -> AnyElement {
        let app_data = app_data_dir()
            .map(|path| path.display().to_string())
            .filter(|path| !path.is_empty())
            .unwrap_or_else(|| tr("Not available").to_string());

        let details = div()
            .w_full()
            .flex()
            .flex_col()
            .child(readonly_row(
                "Memory",
                string_or_placeholder(&self.context.memory, "Not reported"),
                tokens,
            ))
            .child(readonly_row(
                "App data",
                SharedString::from(app_data),
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Runtime",
                None,
                details.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "Log viewing, log directory selection, and diagnostics export are not available in the GPUI build yet.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn render_ai_providers(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let card = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "AI providers are managed from the Agent panel. This page does not edit provider settings or API keys.",
                    )),
            )
            .child(self.open_agent_button("lithe-settings:open-agent-providers", cx));
        // Tauri AI：自动补全开关。
        let autocomplete = div().w_full().flex().flex_col().child(toggle_row(
            "AI Autocomplete",
            "lithe-settings:ai-autocomplete",
            self.settings.ai_autocomplete,
            ToggleAction::AiAutocomplete,
            cx,
            tokens,
        ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Providers",
                None,
                card.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Autocomplete",
                None,
                autocomplete.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    fn render_agents(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let card = div()
            .w_full()
            .flex()
            .flex_col()
            .child(readonly_row(
                "Status",
                string_or_placeholder(&self.context.agent_status, "No agent is connected."),
                tokens,
            ))
            .child(
                div()
                    .pt(px(SETTINGS_CONTROL_GAP))
                    .child(self.open_agent_button("lithe-settings:open-agent-agents", cx)),
            );

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card("Agent", None, card.into_any_element(), tokens))
            .into_any_element()
    }

    fn render_agent_library_page(
        &self,
        page: SettingsPage,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let explanation = match page {
            SettingsPage::Instructions => {
                "Agent instructions are edited from the Agent panel. This page does not edit project or global instruction files."
            }
            SettingsPage::Skills => {
                "Skills are discovered and managed by the Agent panel. This page does not install or edit skills."
            }
            SettingsPage::Hooks => {
                "Agent lifecycle hooks are managed by the Agent panel. This page does not edit hook files."
            }
            SettingsPage::Mcp => {
                "MCP servers are configured from the Agent panel. This page does not edit MCP configuration."
            }
            _ => "This page is read-only.",
        };

        let card = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(explanation)),
            )
            .child(self.open_agent_button("lithe-settings:open-agent-library", cx));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                page.title(),
                None,
                card.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    fn render_ai_commit(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let settings = div()
            .w_full()
            .flex()
            .flex_col()
            .child(setting_row(
                "AI commit messages",
                switch_control(
                    "lithe-settings:ai-commit-enabled",
                    self.settings.ai_commit_enabled,
                    "Enable AI commit messages",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_ai_commit_enabled(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.ai_commit_enabled),
                tokens,
            ))
            .child(choice_row(
                "Format",
                "lithe-settings:ai-commit-format",
                &COMMIT_FORMATS,
                &self.settings.ai_commit_format,
                ChoiceAction::CommitFormat,
                cx,
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Commit messages",
                None,
                settings.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "The AI commit settings and format are stored here; message generation itself runs from the Agent panel.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    fn open_agent_button(&self, id: &'static str, cx: &mut Context<Self>) -> AnyElement {
        Button::new(id)
            .small()
            .h(px(SETTINGS_BUTTON_HEIGHT))
            .rounded(px(SETTINGS_BUTTON_RADIUS))
            .secondary()
            .label(tr("Open Agent"))
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                this.invoke_open_agent(window, cx);
            }))
            .into_any_element()
    }
}

impl Render for SettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 项目切换后把 Maven 字段的已保存值写进草稿输入框；输入框 API
        // 需要 Window，统一在拿到 Window 的渲染帧应用。
        if let Some(values) = self.maven_pending_inputs.take() {
            for (input, text) in self.maven_inputs.iter().zip(values) {
                input.update(cx, |state, cx| state.set_value(text, window, cx));
            }
        }
        let tokens = current_tokens(cx);
        div()
            .id("lithe-settings")
            .size_full()
            .flex()
            .flex_row()
            .bg(tokens.window)
            .text_color(tokens.primary_text)
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .child(self.render_nav(tokens, cx))
            .child(div().w(px(1.0)).h_full().flex_shrink_0().bg(tokens.divider))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .h_full()
                    .flex()
                    .flex_col()
                    .bg(tokens.editor)
                    .child(self.render_breadcrumb(tokens))
                    .child(self.render_content(tokens, cx)),
            )
    }
}

// ---------------------------------------------------------------------------
// 可复用的行、卡片与控件
// ---------------------------------------------------------------------------

/// 分组标题 + 可选说明 + 设置行。
///
/// 对齐 Tauri `Section`：没有卡片背景和圆角，标题右侧是一条细分隔线，行与行
/// 之间靠间距分开，而不是每行画一条底线。
fn section_card(
    title: &'static str,
    note: Option<&'static str>,
    body: AnyElement,
    tokens: LitheTokens,
) -> AnyElement {
    let mut section = div().w_full().flex().flex_col().gap(px(10.0)).child(
        div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(8.0))
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(tr(title)),
            )
            .child(div().flex_1().h(px(1.0)).bg(tokens.divider)),
    );

    if let Some(note) = note {
        section = section.child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(note)),
        );
    }

    section.child(body).into_any_element()
}

/// 只读说明。用于诚实标出本构建尚未接入的能力。
fn note_card(text: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(tokens.secondary_text)
        .child(text)
        .into_any_element()
}

/// 由外部子系统拥有、当前不可编辑的状态块。
fn status_card(text: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(SETTINGS_CONTROL_GAP))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(tr("Status")),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(text),
        )
        .into_any_element()
}

/// “标签 + 控件”行。
///
/// 对齐 Tauri `SettingRow`：标签和控件在同一行、从左排布，空间不足时换行；
/// 不再使用固定标签列、右侧 badge 或每行分隔线。
fn setting_row(
    label: &'static str,
    control: AnyElement,
    _value: SharedString,
    tokens: LitheTokens,
) -> AnyElement {
    div()
        .w_full()
        .min_h(px(28.0))
        .flex()
        .flex_wrap()
        .items_center()
        .gap_x(px(8.0))
        .gap_y(px(4.0))
        .child(
            div()
                .min_w(px(0.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(div().min_w(px(0.0)).flex().items_center().child(control))
        .into_any_element()
}

/// 只读的“标签 + 值”行，排版与 [`setting_row`] 一致。
fn readonly_row(label: &'static str, value: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .min_h(px(28.0))
        .flex()
        .flex_wrap()
        .items_center()
        .gap_x(px(8.0))
        .gap_y(px(4.0))
        .child(
            div()
                .min_w(px(0.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(
            div()
                .min_w(px(0.0))
                .truncate()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(value),
        )
        .into_any_element()
}

/// 一组互斥选项按钮。值不变时 `commit` 不会触发，因此点击不会多余写盘。
fn choice_row(
    label: &'static str,
    id_prefix: &'static str,
    options: &'static [(&'static str, &'static str)],
    selected: &str,
    action: ChoiceAction,
    cx: &mut Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    let mut controls = div()
        .flex()
        .flex_row()
        .items_center()
        .flex_wrap()
        .gap(px(SETTINGS_CONTROL_GAP));

    for &(value, title) in options {
        let is_selected = selected.eq_ignore_ascii_case(value);
        controls = controls.child(
            Button::new(format!("{id_prefix}:{value}"))
                .small()
                // 同一组选项统一高度、圆角和最小宽度。
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .min_w(px(SETTINGS_OPTION_MIN_WIDTH))
                .when(is_selected, |button| button.primary())
                .when(!is_selected, |button| button.secondary())
                .label(tr(title))
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_choice(action, value, window, cx);
                })),
        );
    }

    setting_row(
        label,
        controls.into_any_element(),
        SharedString::default(),
        tokens,
    )
}

/// 编辑器字体预览：固定示例文本，跟随代码字体与编辑区底色。
fn font_preview(_ligatures: bool, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .rounded(px(LitheMetrics::CONTROL_RADIUS))
        .bg(tokens.raised)
        .p(px(12.0))
        .font_family(MONO_FONT_FAMILY)
        .text_size(px(LitheMetrics::CODE_FONT_SIZE))
        .text_color(tokens.primary_text)
        .child("const ready = a != b && count <= 10;\n(a, b) => a === b   中文字体预览 0123456789")
        .into_any_element()
}

/// 布尔开关行：标签、勾选态与写入动作。
fn toggle_row(
    label: &'static str,
    id: &'static str,
    checked: bool,
    action: ToggleAction,
    cx: &mut Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    setting_row(
        label,
        switch_control(
            id,
            checked,
            label,
            cx.listener(move |this, checked: &bool, window, cx| {
                this.apply_toggle(action, *checked, window, cx);
            }),
        ),
        on_off(checked),
        tokens,
    )
}

/// 带标题的单行输入框；隐藏路径模式在 GPUI 侧用逗号分隔。
fn pattern_field(
    label: &'static str,
    state: &Entity<InputState>,
    tokens: LitheTokens,
) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(Input::new(state).small())
        .into_any_element()
}

/// “- 值 +”数值步进器，末尾附带恢复默认值的按钮。
fn stepper_row(
    label: &'static str,
    id_prefix: &'static str,
    current: f32,
    min: f32,
    max: f32,
    default: f32,
    action: StepperAction,
    value: SharedString,
    cx: &mut Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    let controls = div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(SETTINGS_CONTROL_GAP))
        .child(
            Button::new(format!("{id_prefix}:decrease"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .w(px(SETTINGS_STEPPER_WIDTH))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(tr("-"))
                .disabled(current <= min)
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_step(action, -1, window, cx);
                })),
        )
        .child(
            Button::new(format!("{id_prefix}:increase"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .w(px(SETTINGS_STEPPER_WIDTH))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(tr("+"))
                .disabled(current >= max)
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_step(action, 1, window, cx);
                })),
        )
        // “↺”是语言无关符号，避免为设置页新增未翻译的英文按钮。
        .child(
            Button::new(format!("{id_prefix}:reset"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .w(px(SETTINGS_STEPPER_WIDTH))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label("↺")
                .disabled((current - default).abs() < 0.5)
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_reset(action, window, cx);
                })),
        );

    setting_row(label, controls.into_any_element(), value, tokens)
}

/// 统一构造一个小号受控 Switch。
fn switch_control(
    id: &'static str,
    checked: bool,
    label: &'static str,
    handler: impl Fn(&bool, &mut Window, &mut App) + 'static,
) -> AnyElement {
    Switch::new(id)
        .small()
        .checked(checked)
        .accessibility_label(tr(label))
        .on_change(handler)
        .into_any_element()
}

/// 开关当前值的 badge 文案。
fn on_off(checked: bool) -> SharedString {
    SharedString::from(if checked { tr("On") } else { tr("Off") })
}

fn project_root_label(root: Option<&PathBuf>) -> SharedString {
    match root {
        Some(path) => SharedString::from(path.display().to_string()),
        None => SharedString::from(tr("No project open")),
    }
}

fn string_or_placeholder(value: &str, placeholder: &'static str) -> SharedString {
    if value.trim().is_empty() {
        SharedString::from(tr(placeholder))
    } else {
        SharedString::from(value.to_string())
    }
}
