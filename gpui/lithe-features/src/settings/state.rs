//! 设置数据模型与各页状态结构。
//!
//! 从原 `settings.rs` 等价拆出：[`AppSettings`] 的读写与归一化、设置页
//! 枚举/分组结构、各页面的本地状态（Run Configurations、Logs）。纯移动，
//! 行为不变；可见性按拆分后的模块边界放宽到 `pub(super)`/`pub(crate)`。

use std::env;
use std::fs;
use std::path::PathBuf;

use crate::logging;
use crate::run::model::{RunConfiguration, RunDiagnostic, RunEditorOptions, RunSaveScope, RunToolchainPaths};
use crate::run::toolchain::{DiscoveredToolchains, EffectiveToolchains};

/// 设置文件名；目录约定与最近项目列表保持一致。
pub(super) const STORE_FILE_NAME: &str = "settings.json";

/// 默认主题族与可选主题；第二列是展示名，所有展示名仍会经过 `tr`。
pub(super) const DEFAULT_THEME: &str = "lithe";
pub(super) const THEMES: [(&str, &str); 3] =
    [("lithe", "Lithe"), ("codex", "Codex"), ("linear", "Linear")];
pub(super) const LANGUAGES: [(&str, &str); 2] = [("en-US", "English"), ("zh-CN", "中文")];
pub(super) const DEFAULT_LANGUAGE: &str = "zh-CN";

pub(super) const DEFAULT_UPDATE_CHANNEL: &str = "stable";
/// Tauri `update-channel-selector.tsx` 只有 stable 与 autobuild 两档；旧版本的
/// "preview" 在读取时视为 stable（见 [`AppSettings::normalized`]）。
pub(super) const UPDATE_CHANNELS: [(&str, &str); 2] =
    [("stable", "Stable"), ("autobuild", "Auto Build")];

/// Tauri General › Git strategy：保存本地更改的方式（会话内记忆，不持久化）。
pub(super) const GIT_STRATEGIES: [(&str, &str); 3] = [
    ("ask", "Ask every time"),
    ("shelf", "Shelve changes"),
    ("stash", "Stash changes"),
];

/// Tauri Editor › Editor tabs 布局。
pub(super) const TAB_LAYOUTS: [(&str, &str); 2] =
    [("singleLine", "Single line"), ("multipleRows", "Multiple rows")];

pub(super) const DEFAULT_EDITOR_FONT_SIZE: f32 = 13.0;
pub(super) const MIN_EDITOR_FONT_SIZE: f32 = 9.0;
pub(super) const MAX_EDITOR_FONT_SIZE: f32 = 32.0;

pub(super) const DEFAULT_TERMINAL_FONT_SIZE: f32 = 13.0;
pub(super) const DEFAULT_TERMINAL_SCROLLBACK: u32 = 5000;
pub(super) const MIN_TERMINAL_SCROLLBACK: u32 = 100;
pub(super) const MAX_TERMINAL_SCROLLBACK: u32 = 50_000;
/// 终端回滚行数的步进；与 macOS 设置页的 500 行一致。
pub(super) const TERMINAL_SCROLLBACK_STEP: u32 = 500;

pub(super) const DEFAULT_RUN_SERVICES_ON_EXIT: &str = "ask";
pub(super) const RUN_SERVICE_OPTIONS: [(&str, &str); 2] = [
    ("ask", "Ask before stopping"),
    ("terminate", "Stop without asking"),
];

pub(super) const DEFAULT_TERMINAL_ON_QUIT: &str = "ask";
pub(super) const TERMINAL_QUIT_OPTIONS: [(&str, &str); 2] = [
    ("ask", "Ask for each terminal"),
    ("terminate", "End without asking"),
];

pub(super) const DEFAULT_AGENT_TASKS: &str = "ask";
pub(super) const AGENT_TASK_OPTIONS: [(&str, &str); 3] = [
    ("ask", "Ask for each task"),
    ("keep", "Keep running"),
    ("terminate", "End without asking"),
];

pub(super) const DEFAULT_BACKGROUND_SERVICES: &str = "ask";
pub(super) const BACKGROUND_SERVICE_OPTIONS: [(&str, &str); 3] = [
    ("ask", "Ask in one list"),
    ("keep", "Keep running"),
    ("terminate", "End all"),
];

pub(super) const DEFAULT_GRACEFUL_STOP_SECONDS: u32 = 5;
pub(super) const MIN_GRACEFUL_STOP_SECONDS: u32 = 1;
pub(super) const MAX_GRACEFUL_STOP_SECONDS: u32 = 60;

pub(super) const DEFAULT_AI_COMMIT_FORMAT: &str = "conventional";
pub(super) const COMMIT_FORMATS: [(&str, &str); 3] = [
    ("conventional", "Conventional"),
    ("plain", "Plain"),
    ("gitmoji", "GitMoji"),
];

// ---------------------------------------------------------------------------
// AI Commit（Tauri features/git/types/ai-commit.ts 的 gpui 对齐）
// ---------------------------------------------------------------------------

/// Profile 数量上限（对齐 Tauri `normalizeCommitAI` 的 30 上限）。
pub(super) const MAX_AI_COMMIT_PROFILES: usize = 30;

/// API 协议（responses / chatCompletions / anthropicMessages）。
pub(super) const AI_COMMIT_PROTOCOLS: [(&str, &str); 3] = [
    ("responses", "Responses API"),
    ("chatCompletions", "Chat Completions"),
    ("anthropicMessages", "Anthropic Messages"),
];

/// 认证方式（bearer / apiKey，后者即 x-api-key）。
pub(super) const AI_COMMIT_AUTHENTICATION: [(&str, &str); 2] =
    [("bearer", "Bearer"), ("apiKey", "x-api-key")];

/// chatCompletions 协议的 token 限额字段名。
pub(super) const AI_COMMIT_TOKEN_LIMIT_FIELDS: [(&str, &str); 2] = [
    ("max_completion_tokens", "max_completion_tokens"),
    ("max_tokens", "max_tokens (legacy gateways)"),
];

/// 提交信息语言。
pub(super) const AI_COMMIT_LANGUAGES: [(&str, &str); 2] =
    [("english", "English"), ("simplifiedChinese", "简体中文")];

/// 推理力度（anthropicMessages 协议下禁用）。
pub(super) const AI_COMMIT_EFFORTS: [(&str, &str); 8] = [
    ("default", "Default"),
    ("none", "none"),
    ("minimal", "minimal"),
    ("low", "low"),
    ("medium", "medium"),
    ("high", "high"),
    ("xhigh", "xhigh"),
    ("max", "max"),
];

/// AI Commit 的一个 Provider（对齐 Tauri `CommitProvider`；id 仅在本地生成，为
/// `imported-codex` / `imported-claude` 时是受管 Profile，字段只读）。
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiCommitProfile {
    pub id: String,
    pub name: String,
    /// `local` / `codex` / `claude`。
    pub source: String,
    /// `responses` / `chatCompletions` / `anthropicMessages`。
    pub api_protocol: String,
    /// `bearer` / `apiKey`。
    pub authentication: String,
    pub endpoint: String,
    pub model: String,
    pub requires_api_key: bool,
    pub allows_insecure_http: bool,
    /// `max_completion_tokens` / `max_tokens`。
    pub chat_token_limit_field: String,
    /// 仅保存在设置文件；界面从不回显，只显示“已存储”占位。
    #[serde(default)]
    pub api_key: String,
}

impl AiCommitProfile {
    pub(super) fn new_local(id: String) -> Self {
        Self {
            id,
            name: String::new(),
            source: String::from("local"),
            api_protocol: String::from("responses"),
            authentication: String::from("bearer"),
            endpoint: String::new(),
            model: String::new(),
            requires_api_key: true,
            allows_insecure_http: false,
            chat_token_limit_field: String::from("max_completion_tokens"),
            api_key: String::new(),
        }
    }

    /// 受管来源（codex / claude 导入）的元数据不可编辑。
    pub(super) fn managed(&self) -> bool {
        self.source != "local"
    }
}

/// 「日志与诊断」页的模块筛选；值必须与 `logging` 写入的模块 id 一致。
pub(super) const LOG_CATEGORY_OPTIONS: [(&str, &str); 7] = [
    ("all", "All modules"),
    ("application", "Application"),
    ("language", "Editor and language services"),
    ("run", "Build, run and debug"),
    ("git", "Git"),
    ("plugins", "Plugins"),
    ("performance", "Performance"),
];

pub(super) const LOG_SESSION_OPTIONS: [(&str, &str); 3] = [
    ("current", "Current session"),
    ("previous", "Previous session"),
    ("all", "All sessions"),
];

pub(super) const LOG_LEVEL_OPTIONS: [(&str, &str); 4] = [
    ("debug", "DEBUG"),
    ("info", "INFO"),
    ("warn", "WARN"),
    ("error", "ERROR"),
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
pub(super) const SETTINGS_NAV_WIDTH: f32 = 234.0;
pub(super) const SETTINGS_NAV_GROUP_HEIGHT: f32 = 24.0;
pub(super) const SETTINGS_NAV_ROW_HEIGHT: f32 = 24.0;
pub(super) const SETTINGS_NAV_GAP: f32 = 0.0;
pub(super) const SETTINGS_NAV_ITEM_PADDING: f32 = 8.0;
/// Tauri General › Appearance › Appearance Mode。
pub(super) const APPEARANCE_MODES: [(&str, &str); 3] =
    [("system", "System"), ("light", "Light"), ("dark", "Dark")];

/// Tauri Git › View › Default diff view。
pub(super) const DIFF_VIEWS: [(&str, &str); 2] = [("unified", "Unified"), ("split", "Split")];
/// Tauri Git › Fetch defaults › Submodules。
pub(super) const FETCH_SUBMODULES: [(&str, &str); 4] = [
    ("inherit", "Use Git configuration"),
    ("no", "Do not fetch submodules"),
    ("onDemand", "Fetch on demand"),
    ("yes", "Fetch all submodules"),
];
/// Tauri Git › Fetch defaults › Tags。
pub(super) const FETCH_TAGS: [(&str, &str); 4] = [
    ("inherit", "Use Git configuration"),
    ("all", "Fetch all tags"),
    ("none", "Do not fetch tags"),
    (
        "prune",
        "Synchronize tags and delete local tags absent on remote",
    ),
];
/// Keymap presets。
pub(super) const KEYMAP_PRESETS: [(&str, &str); 2] = [("default", "Default"), ("vim", "Vim")];

/// Tauri Editor › Indentation › Tab width。
pub(super) const TAB_WIDTHS: [(&str, &str); 3] = [("2", "2"), ("4", "4"), ("8", "8")];

/// Tauri General › Projects › Open projects in。
pub(super) const PROJECT_OPEN_DESTINATIONS: [(&str, &str); 4] = [
    ("ask", "Ask every time"),
    ("this-window", "This window"),
    ("new-window", "New window"),
    ("attach", "Attach"),
];

/// Tauri 的默认隐藏目录模式。
pub(super) const DEFAULT_HIDDEN_DIRECTORY_PATTERNS: [&str; 10] = [
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
pub(super) const DEFAULT_HIDDEN_FILE_PATTERNS: [&str; 8] = [
    "*.pyc",
    "*.pyo",
    "*.rbc",
    "*.yarb",
    "*~",
    ".DS_Store",
    "vssver.scc",
    "vssver2.scc",
];

pub(super) const SETTINGS_CONTENT_MIN_WIDTH: f32 = 500.0;
pub(super) const SETTINGS_SECTION_GAP: f32 = 16.0;

pub(super) const SETTINGS_CONTROL_GAP: f32 = 6.0;
/// 设置页普通按钮的统一高度。
pub(super) const SETTINGS_BUTTON_HEIGHT: f32 = 24.0;
/// 设置页按钮的统一圆角。
pub(super) const SETTINGS_BUTTON_RADIUS: f32 = 6.0;
/// 同组互斥选项按钮的最小宽度。
pub(super) const SETTINGS_OPTION_MIN_WIDTH: f32 = 72.0;
/// 步进器按钮宽度。
pub(super) const SETTINGS_STEPPER_WIDTH: f32 = 28.0;

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
    /// 是否在提交面板显示本地 changelist 分组（对齐 Tauri `showGitChangelists`，
    /// 同时是提交面板 changelist 栏的显示依据）。
    pub show_git_changelists: bool,
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
    /// 编辑器等宽字体族名；`None` / 空串使用内置等宽字体。
    pub editor_font_family: Option<String>,
    /// 编辑器标签布局：`"singleLine"` 或 `"multipleRows"`。
    ///
    /// 偏好随设置保存；标签栏按此铺排多行（消费点接线见 PR 报告遗留项）。
    pub editor_tab_layout: String,
    // Language services（对齐 Tauri LspPanel）
    /// 是否启用自动补全。
    pub auto_completion: bool,
    /// 是否启用参数提示。
    pub parameter_hints: bool,
    /// 是否启用语义高亮。
    pub semantic_tokens: bool,
    /// Java 项目打开时的导入方式：`"automatic"`、`"ask"` 或 `"manual"`。
    pub java_project_import_on_open: String,
    // Process termination policy（只存储，长期驻留服务落地后才强制执行）
    /// Run services：`"ask"` 或 `"terminate"`。
    pub run_services_on_exit: String,
    /// 选择「对此工作区始终继续」的项目根路径。
    ///
    /// 对齐 macOS `javaBuildFailurePolicy(.alwaysContinue)`：策略按工作区保存，
    /// 重启应用后仍然生效；写入路径时统一使用 `/` 分隔并忽略大小写。
    pub java_build_failure_always_continue: Vec<String>,
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
    /// 新终端默认使用的 shell id；`None` / 空串为系统默认。
    ///
    /// 与 Terminal 面板下拉的同一 detector（`lithe_terminal::get_shells`）对齐；
    /// 终端启动消费点接线后生效（PR 报告遗留项注明）。
    pub terminal_default_shell: Option<String>,
    // AI
    /// 是否启用 AI 提交信息生成。
    pub ai_commit_enabled: bool,
    /// 提交信息格式：`"conventional"`、`"plain"` 或 `"gitmoji"`。
    pub ai_commit_format: String,
    /// AI Commit 的 Provider 列表；上限 [`MAX_AI_COMMIT_PROFILES`]。
    pub ai_commit_profiles: Vec<AiCommitProfile>,
    /// 激活 Provider 的 id；无 Provider 或失配时回落到第一个。
    pub ai_commit_active_profile: Option<String>,
    /// 提交信息语言：`"english"` / `"simplifiedChinese"`。
    pub ai_commit_language: String,
    /// 推理力度；anthropicMessages 协议下界面禁用。
    pub ai_commit_reasoning_effort: String,
    /// 自定义提交说明（format 为 custom 时使用），4000 字上限。
    pub ai_commit_custom_instructions: String,
    /// 提交信息是否包含正文。
    pub ai_commit_include_body: bool,
    /// 主题行最大长度（20–200）。
    pub ai_commit_subject_max_length: u32,
    /// 送入模型的 diff 最大字符数（8000–120000）。
    pub ai_commit_max_diff_characters: u32,
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
            // Tauri 的 showGitChangelists 默认 true。
            show_git_changelists: true,
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
            editor_font_family: None,
            editor_tab_layout: "singleLine".to_string(),
            auto_completion: true,
            parameter_hints: true,
            semantic_tokens: true,
            java_project_import_on_open: "automatic".to_string(),
            run_services_on_exit: DEFAULT_RUN_SERVICES_ON_EXIT.to_string(),
            java_build_failure_always_continue: Vec::new(),
            terminal_on_quit: DEFAULT_TERMINAL_ON_QUIT.to_string(),
            agent_tasks: DEFAULT_AGENT_TASKS.to_string(),
            background_services: DEFAULT_BACKGROUND_SERVICES.to_string(),
            graceful_stop_seconds: DEFAULT_GRACEFUL_STOP_SECONDS,
            terminal_font_size: DEFAULT_TERMINAL_FONT_SIZE,
            terminal_scrollback: DEFAULT_TERMINAL_SCROLLBACK,
            terminal_default_shell: None,
            ai_commit_enabled: false,
            ai_commit_format: DEFAULT_AI_COMMIT_FORMAT.to_string(),
            ai_commit_profiles: Vec::new(),
            ai_commit_active_profile: None,
            ai_commit_language: "english".to_string(),
            ai_commit_reasoning_effort: "default".to_string(),
            ai_commit_custom_instructions: String::new(),
            ai_commit_include_body: false,
            ai_commit_subject_max_length: 72,
            ai_commit_max_diff_characters: 32_000,
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
        // 旧版本只保存过 "stable"/"preview"；渠道枚举改为 stable/autobuild 后，
        // 旧值按 Tauri 语义视为 stable。
        if self.update_channel.eq_ignore_ascii_case("preview") {
            self.update_channel = DEFAULT_UPDATE_CHANNEL.to_string();
        } else {
            self.update_channel = normalized_choice(
                &self.update_channel,
                &UPDATE_CHANNEL_IDS,
                DEFAULT_UPDATE_CHANNEL,
            );
        }
        self.editor_tab_layout = normalized_choice(
            &self.editor_tab_layout,
            &["singleLine", "multipleRows"],
            "singleLine",
        );
        self.editor_font_family = Some(
            self.editor_font_family
                .take()
                .unwrap_or_default()
                .trim()
                .to_string(),
        )
        .filter(|value| !value.is_empty());
        self.terminal_default_shell = Some(
            self.terminal_default_shell
                .take()
                .unwrap_or_default()
                .trim()
                .to_string(),
        )
        .filter(|value| !value.is_empty());
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
        // Tauri `settings-normalization.ts`：tags 选 prune 时 prune 必须为开。
        if self.git_fetch_tags == "prune" {
            self.git_fetch_prune = true;
        }
        self.normalize_ai_commit();
        // editor_render_whitespace 是布尔字段，反序列化本身不会产生越界值，
        // 缺字段时由 `#[serde(default)]` 补成 false，因此这里无需额外校验。
        self
    }

    /// AI Commit 字段的白名单归一化（对齐 Tauri `normalizeCommitAI`）：
    /// Profile 上限 30、id 形如 `[A-Za-z0-9-]{1,128}`、枚举值与数字范围。
    fn normalize_ai_commit(&mut self) {
        self.ai_commit_language = normalized_choice(
            &self.ai_commit_language,
            &["english", "simplifiedChinese"],
            "english",
        );
        self.ai_commit_reasoning_effort = normalized_choice(
            &self.ai_commit_reasoning_effort,
            &[
                "default", "none", "minimal", "low", "medium", "high", "xhigh", "max",
            ],
            "default",
        );
        self.ai_commit_custom_instructions.truncate(4_000);
        self.ai_commit_subject_max_length = self
            .ai_commit_subject_max_length
            .clamp(20, 200);
        self.ai_commit_max_diff_characters = self
            .ai_commit_max_diff_characters
            .clamp(8_000, 120_000);

        let valid_ids = normalized_ai_commit_profiles(&mut self.ai_commit_profiles);
        // 激活值只在指向存在的 Profile 时保留；否则回落到第一个（若有）。
        let active_valid = self
            .ai_commit_active_profile
            .as_deref()
            .map(|id| valid_ids.contains(id))
            .unwrap_or(false);
        if !active_valid {
            self.ai_commit_active_profile =
                self.ai_commit_profiles.first().map(|profile| profile.id.clone());
        }
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

    /// 按 `delta` 调整终端字号，规则与编辑器字号一致（Zoom In/Out 在终端
    /// 工具窗活跃时的目标，对齐 Tauri `zoomIn("terminal")`）。
    pub fn nudge_terminal_font_size(&mut self, delta: f32) -> bool {
        let next =
            normalized_font_size(self.terminal_font_size + delta, DEFAULT_TERMINAL_FONT_SIZE);
        if (next - self.terminal_font_size).abs() < f32::EPSILON {
            return false;
        }
        self.terminal_font_size = next;
        true
    }

    /// 把终端字号恢复为默认值；返回是否真的发生变化。
    pub fn reset_terminal_font_size(&mut self) -> bool {
        if (self.terminal_font_size - DEFAULT_TERMINAL_FONT_SIZE).abs() < f32::EPSILON {
            return false;
        }
        self.terminal_font_size = DEFAULT_TERMINAL_FONT_SIZE;
        true
    }
}

const THEME_IDS: [&str; 3] = ["lithe", "codex", "linear"];
const UPDATE_CHANNEL_IDS: [&str; 2] = ["stable", "autobuild"];

fn store_file_path() -> Option<PathBuf> {
    app_data_dir().map(|directory| directory.join(STORE_FILE_NAME))
}

/// macOS：`$HOME/Library/Application Support/Lithe`。
#[cfg(target_os = "macos")]
pub(crate) fn app_data_dir() -> Option<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support/Lithe"))
}

/// Windows：`%APPDATA%\Lithe`。
#[cfg(target_os = "windows")]
pub(crate) fn app_data_dir() -> Option<PathBuf> {
    env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("Lithe"))
}

/// Linux：`$XDG_CONFIG_HOME/lithe`，否则 `$HOME/.config/lithe`。
#[cfg(target_os = "linux")]
pub(crate) fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

/// 未知平台：没有专属目录约定，退回 XDG，保证设置仍然可用。
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
pub(crate) fn app_data_dir() -> Option<PathBuf> {
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
pub(super) fn normalized_choice(value: &str, options: &[&str], fallback: &str) -> String {
    options
        .iter()
        .find(|option| value.eq_ignore_ascii_case(option))
        .map(|option| (*option).to_string())
        .unwrap_or_else(|| fallback.to_string())
}

/// 就地把 Profile 列表归一化并返回有效 id 集合。
fn normalized_ai_commit_profiles(profiles: &mut Vec<AiCommitProfile>) -> std::collections::HashSet<String> {
    let mut seen = std::collections::HashSet::new();
    profiles.retain(|profile| {
        let id_ok = profile.id.len() >= 1
            && profile.id.len() <= 128
            && profile
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-');
        if !id_ok || seen.contains(&profile.id) {
            return false;
        }
        seen.insert(profile.id.clone());
        true
    });
    profiles.truncate(MAX_AI_COMMIT_PROFILES);
    // 字段的字符串上限（对齐 Tauri `text()` 辅助）。
    for profile in profiles.iter_mut() {
        profile.name.truncate(128);
        profile.endpoint.truncate(2_048);
        profile.model.truncate(512);
        profile.api_key.truncate(4_096);
        profile.source = normalized_choice(&profile.source, &["local", "codex", "claude"], "local");
        profile.api_protocol = normalized_choice(
            &profile.api_protocol,
            &["responses", "chatCompletions", "anthropicMessages"],
            "responses",
        );
        profile.authentication =
            normalized_choice(&profile.authentication, &["bearer", "apiKey"], "bearer");
        profile.chat_token_limit_field = normalized_choice(
            &profile.chat_token_limit_field,
            &["max_completion_tokens", "max_tokens"],
            "max_completion_tokens",
        );
    }
    profiles.iter().map(|p| p.id.clone()).collect()
}

/// 字号取整并限制在 9–32；非有限值回到默认。
pub(super) fn normalized_font_size(size: f32, fallback: f32) -> f32 {
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
pub(super) enum SettingsGroup {
    Appearance,
    VersionControl,
    Build,
    Languages,
    Tools,
    Ai,
}

impl SettingsGroup {
    pub(super) fn index(self) -> usize {
        match self {
            SettingsGroup::Appearance => 0,
            SettingsGroup::VersionControl => 1,
            SettingsGroup::Build => 2,
            SettingsGroup::Languages => 3,
            SettingsGroup::Tools => 4,
            SettingsGroup::Ai => 5,
        }
    }

    pub(super) fn id(self) -> &'static str {
        match self {
            SettingsGroup::Appearance => "lithe-settings:group:appearance",
            SettingsGroup::VersionControl => "lithe-settings:group:version-control",
            SettingsGroup::Build => "lithe-settings:group:build",
            SettingsGroup::Languages => "lithe-settings:group:languages",
            SettingsGroup::Tools => "lithe-settings:group:tools",
            SettingsGroup::Ai => "lithe-settings:group:ai",
        }
    }

    pub(super) fn title(self) -> &'static str {
        match self {
            SettingsGroup::Appearance => "Appearance & Behavior",
            SettingsGroup::VersionControl => "Version Control",
            SettingsGroup::Build => "Build, Execution, Deployment",
            SettingsGroup::Languages => "Languages & Frameworks",
            SettingsGroup::Tools => "Tools",
            SettingsGroup::Ai => "AI",
        }
    }

    pub(super) fn pages(self) -> &'static [SettingsPage] {
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
pub(super) enum SidebarEntry {
    Group(SettingsGroup),
    Page(SettingsPage),
}

pub(super) const SIDEBAR_LAYOUT: [SidebarEntry; 8] = [
    SidebarEntry::Group(SettingsGroup::Appearance),
    SidebarEntry::Page(SettingsPage::Plugins),
    SidebarEntry::Page(SettingsPage::DeclarativePlugins),
    SidebarEntry::Group(SettingsGroup::VersionControl),
    SidebarEntry::Group(SettingsGroup::Build),
    SidebarEntry::Group(SettingsGroup::Languages),
    SidebarEntry::Group(SettingsGroup::Tools),
    SidebarEntry::Group(SettingsGroup::Ai),
];

/// AI › Library 下的二级页面。
pub(super) const LIBRARY_PAGES: [SettingsPage; 4] = [
    SettingsPage::Instructions,
    SettingsPage::Skills,
    SettingsPage::Hooks,
    SettingsPage::Mcp,
];

/// 设置页的 20 个页面（Plugins 与 DeclarativePlugins 是独立一级页，对齐
/// Tauri `settings-navigation.ts:54-70`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SettingsPage {
    General,
    Updates,
    Editor,
    Keymap,
    ProcessTermination,
    Plugins,
    DeclarativePlugins,
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
    pub(super) fn id(self) -> &'static str {
        match self {
            SettingsPage::General => "lithe-settings:page:general",
            SettingsPage::Updates => "lithe-settings:page:updates",
            SettingsPage::Editor => "lithe-settings:page:editor",
            SettingsPage::Keymap => "lithe-settings:page:keymap",
            SettingsPage::ProcessTermination => "lithe-settings:page:process-termination",
            SettingsPage::Plugins => "lithe-settings:page:plugins",
            SettingsPage::DeclarativePlugins => "lithe-settings:page:declarative-plugins",
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

    pub(super) fn title(self) -> &'static str {
        match self {
            SettingsPage::General => "General",
            SettingsPage::Updates => "Updates",
            SettingsPage::Editor => "Editor",
            SettingsPage::Keymap => "Keymap",
            SettingsPage::ProcessTermination => "Process Termination",
            SettingsPage::Plugins => "Plugins",
            SettingsPage::DeclarativePlugins => "Declarative Plugins",
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
    pub(super) fn group(self) -> Option<SettingsGroup> {
        match self {
            SettingsPage::General
            | SettingsPage::Updates
            | SettingsPage::Editor
            | SettingsPage::Keymap
            | SettingsPage::ProcessTermination => Some(SettingsGroup::Appearance),
            SettingsPage::DeclarativePlugins => None,
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

    /// 搜索关键词（英文，小写匹配由调用方完成）。对齐 Tauri
    /// `settings-navigation.ts` 的 `terms`：除页面标题外，设置项的常用
    /// 别名也参与搜索，这样搜“font”“shell”“api key”能落到对应页面。
    pub(super) fn search_terms(self) -> &'static [&'static str] {
        match self {
            SettingsPage::General => &[
                "theme", "dark", "light", "language", "autosave", "hidden", "projects",
            ],
            SettingsPage::Updates => &["channel", "autobuild", "check for updates", "version"],
            SettingsPage::Editor => &[
                "font", "font size", "ligatures", "minimap", "wrap", "tab", "indent",
                "code lens", "whitespace", "line numbers", "tabs layout",
            ],
            SettingsPage::Keymap => &["keymap", "shortcut", "keybinding", "vim", "preset"],
            SettingsPage::ProcessTermination => &[
                "process", "terminate", "quit", "graceful", "services", "terminals", "tasks",
            ],
            SettingsPage::Plugins => &["plugin", "extension", "marketplace"],
            SettingsPage::DeclarativePlugins => &[
                "declarative", "plugin", "contract", "install", "review", "web", "settings",
            ],
            SettingsPage::Git => &[
                "git", "commit", "fetch", "prune", "tags", "submodules", "blame", "gutter",
                "diff", "identity", "user.name", "user.email", "credential", "executable",
                "changelists",
            ],
            SettingsPage::Project => &[
                "jdk", "java home", "maven", "settings.xml", "local repository",
                "toolchain", "environment",
            ],
            SettingsPage::RunConfigurations => &[
                "run", "configuration", "arguments", "environment", "working directory",
                "node",
            ],
            SettingsPage::Lsp => &[
                "lsp", "language server", "completion", "parameter hints", "semantic",
                "java import",
            ],
            SettingsPage::Terminal => &[
                "terminal", "shell", "bash", "powershell", "wsl", "scrollback", "font",
            ],
            SettingsPage::Diagnostics => &[
                "logs", "diagnostics", "timeline", "bundle", "log directory",
            ],
            SettingsPage::AiProviders => &[
                "ai", "provider", "model", "api key", "ollama", "autocomplete",
            ],
            SettingsPage::Agents => &[
                "agent", "codex", "claude", "cli", "install", "provider",
            ],
            SettingsPage::Instructions => &["instructions", "agent", "prompt"],
            SettingsPage::Skills => &["skills", "agent"],
            SettingsPage::Hooks => &["hooks", "agent", "automation", "lifecycle"],
            SettingsPage::Mcp => &[
                "mcp", "model context protocol", "server", "permission",
            ],
            SettingsPage::AiCommit => &[
                "ai commit", "commit message", "profile", "api key", "conventional",
                "gitmoji",
            ],
        }
    }
}

// ---------------------------------------------------------------------------
// 设置页上下文与动作枚举
// ---------------------------------------------------------------------------

/// 设置页展示的只读工作台上下文。
#[derive(Clone, Debug, Default)]
pub struct SettingsContext {
    pub project_root: Option<PathBuf>,
    pub branch: String,
    pub memory: String,
    pub agent_status: String,
}

/// 互斥按钮行对应的设置写入动作。用枚举而不是捕获函数指针，避免把
/// `Context` 生命周期写进类型别名。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ChoiceAction {
    Theme,
    AppearanceMode,
    ProjectOpenDestination,
    EditorTabSize,
    EditorTabLayout,
    GitDiffView,
    AiCommitLanguage,
    GitFetchSubmodules,
    GitFetchTags,
    KeymapPreset,
    Language,
    JavaProjectImport,
    UpdateChannel,
    RunServices,
    TerminalOnQuit,
    AgentTasks,
    BackgroundServices,
    CommitFormat,
}

/// Git / Keymap / AI 的布尔开关写入动作。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ToggleAction {
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
    GitChangelists,
    VimMode,
    AiAutocomplete,
    AiCommitEnabled,
    AutoCompletion,
    ParameterHints,
    SemanticTokens,
}

/// 步进器对应的设置写入动作。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StepperAction {
    EditorFontSize,
    TerminalFontSize,
    TerminalScrollback,
    GracefulStop,
}

/// Run Configurations 页的编辑器字段。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RunToolchainField {
    JavaHome,
    MavenExecutable,
    MavenJavaHome,
    Node,
}

/// 可以打开文件/目录选择器的路径字段。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RunPathField {
    JavaHome,
    MavenExecutable,
    MavenJavaHome,
    Node,
    WorkingDirectory,
}

/// 编辑器输入框的一次性回填值；输入框 API 需要 `Window`，渲染帧里应用。
#[derive(Clone, Debug, Default)]
pub(super) struct RunEditorInputs {
    pub(super) arguments: String,
    pub(super) vm_arguments: String,
    pub(super) working_directory: String,
    pub(super) environment: String,
}

/// Run Configurations 页的全部数据与草稿状态。
///
/// 项目切换、重新识别或保存成功后都整体替换；异步任务用 `generation` 丢弃
/// 过期结果，避免旧项目的结果写进新项目。
pub(super) struct RunConfigurationsState {
    pub(super) root: Option<PathBuf>,
    pub(super) generation: u64,
    pub(super) loading: bool,
    pub(super) generating: bool,
    pub(super) ready: bool,
    pub(super) requires_generation: bool,
    pub(super) configurations: Vec<RunConfiguration>,
    pub(super) diagnostics: Vec<RunDiagnostic>,
    pub(super) discovered: DiscoveredToolchains,
    pub(super) global_toolchain: RunToolchainPaths,
    pub(super) maven_executable_path: String,
    pub(super) maven_java_home_path: String,
    pub(super) error: Option<String>,
    pub(super) save_error: Option<String>,
    pub(super) generation_notice: Option<String>,
    pub(super) editing_id: Option<String>,
    pub(super) pending_edit: Option<String>,
    pub(super) draft: RunEditorOptions,
    pub(super) toolchain_draft: RunToolchainPaths,
    pub(super) scope: RunSaveScope,
    pub(super) saving: bool,
    pub(super) effective: EffectiveToolchains,
    pub(super) resolve_generation: u64,
}

impl RunConfigurationsState {
    pub(super) fn new() -> Self {
        Self {
            root: None,
            generation: 0,
            loading: false,
            generating: false,
            ready: false,
            requires_generation: false,
            configurations: Vec::new(),
            diagnostics: Vec::new(),
            discovered: DiscoveredToolchains::default(),
            global_toolchain: RunToolchainPaths::default(),
            maven_executable_path: String::new(),
            maven_java_home_path: String::new(),
            error: None,
            save_error: None,
            generation_notice: None,
            editing_id: None,
            pending_edit: None,
            draft: RunEditorOptions::default(),
            toolchain_draft: RunToolchainPaths::default(),
            scope: RunSaveScope::Local,
            saving: false,
            effective: EffectiveToolchains::detecting(),
            resolve_generation: 0,
        }
    }
}

/// 「日志与诊断」页的本地状态。
///
/// 日志快照与时间线都是磁盘读取结果，进入页面时懒加载；筛选条件保存在
/// 视图里，与 Tauri 的 `LogSelection` 一一对应。
pub(super) struct LogsState {
    pub(super) loaded: bool,
    pub(super) snapshot: logging::LogSettingsSnapshot,
    pub(super) timeline: Option<logging::LogTimeline>,
    /// `"all"` 或 [logging] 的模块 id。
    pub(super) category: String,
    /// `"current"`、`"previous"`、`"all"`。
    pub(super) session: String,
    /// 小写级别 id：`"debug"` 到 `"error"`。
    pub(super) level: String,
    pub(super) search: String,
    pub(super) since: String,
    pub(super) until: String,
    pub(super) busy: bool,
    pub(super) notice: Option<String>,
    pub(super) error: Option<String>,
    /// 清空日志的二次确认。
    pub(super) pending_clear: bool,
    /// 诊断包预览文件清单；`Some` 表示确认区域可见。
    pub(super) bundle_preview: Option<Vec<logging::BundleEntry>>,
    /// 目录切换后待清理的旧自定义目录与字节数。
    pub(super) previous_cleanup: Option<(PathBuf, u64)>,
}

impl LogsState {
    pub(super) fn new() -> Self {
        Self {
            loaded: false,
            snapshot: logging::LogSettingsSnapshot::default(),
            timeline: None,
            category: "all".to_string(),
            session: "current".to_string(),
            level: "info".to_string(),
            search: String::new(),
            since: String::new(),
            until: String::new(),
            busy: false,
            notice: None,
            error: None,
            pending_clear: false,
            bundle_preview: None,
            previous_cleanup: None,
        }
    }

    pub(super) fn selection(&self) -> logging::LogSelection {
        logging::LogSelection {
            category: (self.category != "all").then(|| self.category.clone()),
            session: self.session.clone(),
            minimum_level: self.level.clone(),
            search: Some(self.search.clone()).filter(|value| !value.trim().is_empty()),
            since: Some(self.since.clone()).filter(|value| !value.trim().is_empty()),
            until: Some(self.until.clone()).filter(|value| !value.trim().is_empty()),
        }
    }

    /// 重新读取设置快照并刷新时间线。
    pub(super) fn refresh(&mut self) {
        self.snapshot = logging::settings_snapshot();
        self.timeline = Some(logging::query_logs(&self.selection()));
        self.loaded = true;
    }

    pub(super) fn reload_timeline(&mut self) {
        self.snapshot = logging::settings_snapshot();
        self.timeline = Some(logging::query_logs(&self.selection()));
    }
}
