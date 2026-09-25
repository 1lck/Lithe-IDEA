//! 设置对话框：复刻 Tauri 端 `settings-dialog.tsx` 的 12 分类布局。
//!
//! 面板尺寸对齐 Tauri 的 820×620：header 44、footer 44、左侧导航 190、右侧内容
//! 滚动区。所有可持久化项都通过 [`crate::settings::update`] 写入 XDG JSON
//! (`$XDG_CONFIG_HOME/lithe/settings.json`)；主题相关项写入后额外调用
//! [`crate::settings::apply_theme`] 让工作台调色板立即生效。少量 Tauri 侧存在但
//! Linux `Settings` 尚未覆盖的项（Vim、Git 视图、日志级别等）只作为对话框本地
//! 占位状态，不落盘，待 `Settings` 补齐字段后再接入。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};
use gpui_kit::component::menu::DropdownMenu as _;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, AppContext as _, Context, Entity, EventEmitter, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::core::CoreClient;
use crate::settings::{self, Settings};
use crate::theme::ThemeColors;
use crate::workbench::run::{
    default_generated_configuration_id, list_java_sources, parse_resolved_configurations,
    read_toolchain_paths, write_generated_documents, write_toolchain_paths, ToolchainPaths,
};

/// 设置分类，顺序与 Tauri `categories` 数组一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SettingsCategory {
    #[default]
    General,
    Project,
    Run,
    Editor,
    Keyboard,
    Terminal,
    Lsp,
    Ai,
    AiCommit,
    Git,
    Logs,
    Updates,
}

impl SettingsCategory {
    /// 全部分类，供左侧导航按固定顺序渲染。
    pub const ALL: [SettingsCategory; 12] = [
        SettingsCategory::General,
        SettingsCategory::Project,
        SettingsCategory::Run,
        SettingsCategory::Editor,
        SettingsCategory::Keyboard,
        SettingsCategory::Terminal,
        SettingsCategory::Lsp,
        SettingsCategory::Ai,
        SettingsCategory::AiCommit,
        SettingsCategory::Git,
        SettingsCategory::Logs,
        SettingsCategory::Updates,
    ];

    /// 持久化用的 id，与 Tauri `MacSettingsCategory` 字符串对应。
    pub fn id(self) -> &'static str {
        match self {
            SettingsCategory::General => "general",
            SettingsCategory::Project => "project",
            SettingsCategory::Run => "run",
            SettingsCategory::Editor => "editor",
            SettingsCategory::Keyboard => "keyboard",
            SettingsCategory::Terminal => "terminal",
            SettingsCategory::Lsp => "lsp",
            SettingsCategory::Ai => "ai",
            SettingsCategory::AiCommit => "ai-commit",
            SettingsCategory::Git => "git",
            SettingsCategory::Logs => "logs",
            SettingsCategory::Updates => "updates",
        }
    }

    /// 分类 i18n 键，与 Tauri `settings-dialog.tsx` 各分类 `labelKey` 逐一对应。
    pub fn title_key(self) -> &'static str {
        match self {
            SettingsCategory::General => "settings.tabs.general",
            SettingsCategory::Project => "settings.project.title",
            SettingsCategory::Run => "settings.run.title",
            SettingsCategory::Editor => "settings.tabs.editor",
            SettingsCategory::Keyboard => "settings.tabs.keyboard",
            SettingsCategory::Terminal => "settings.tabs.terminal",
            SettingsCategory::Lsp => "settings.tabs.lsp",
            SettingsCategory::Ai => "settings.tabs.ai",
            SettingsCategory::AiCommit => "settings.tabs.aiCommit",
            SettingsCategory::Git => "settings.tabs.git",
            SettingsCategory::Logs => "settings.tabs.logs",
            SettingsCategory::Updates => "settings.tabs.updates",
        }
    }

    /// 导航图标；与 Tauri `settings-dialog.tsx` 各分类图标一一对应
    /// （GearSix→Settings、Gear→Cog、CodeBlock→Code、TerminalWindow→SquareTerminal、
    /// MagicWand→WandSparkles、ArrowClockwise→RotateCw）。
    pub fn icon(self) -> IconName {
        match self {
            SettingsCategory::General => IconName::Settings,
            SettingsCategory::Project => IconName::Folder,
            SettingsCategory::Run => IconName::Cog,
            SettingsCategory::Editor => IconName::Code,
            SettingsCategory::Keyboard => IconName::Keyboard,
            SettingsCategory::Terminal => IconName::SquareTerminal,
            SettingsCategory::Lsp => IconName::Database,
            SettingsCategory::Ai => IconName::WandSparkles,
            SettingsCategory::AiCommit => IconName::WandSparkles,
            SettingsCategory::Git => IconName::Code,
            SettingsCategory::Logs => IconName::FileText,
            SettingsCategory::Updates => IconName::RotateCw,
        }
    }

    /// 由持久化的 `lastSettingsTab` 反解分类；`language` 归到 LSP，未知值回退常规。
    pub fn from_id(id: &str) -> Self {
        match id {
            "general" => SettingsCategory::General,
            "project" => SettingsCategory::Project,
            "run" => SettingsCategory::Run,
            "editor" => SettingsCategory::Editor,
            "keyboard" => SettingsCategory::Keyboard,
            "terminal" => SettingsCategory::Terminal,
            "lsp" | "language" => SettingsCategory::Lsp,
            "ai" => SettingsCategory::Ai,
            "ai-commit" => SettingsCategory::AiCommit,
            "git" => SettingsCategory::Git,
            "logs" => SettingsCategory::Logs,
            "updates" => SettingsCategory::Updates,
            _ => SettingsCategory::General,
        }
    }
}

/// 对话框对外事件：关闭、普通设置变更，以及 Run 文档/工具链变更。
#[derive(Debug, Clone)]
pub enum SettingsEvent {
    Close,
    Changed,
    RunConfigurationChanged,
}

/// 居中设置面板（宽 820px，高 620px）。
pub struct SettingsDialog {
    /// 当前激活分类
    pub active_category: SettingsCategory,
    /// 当前工作区根路径，Project 分类只读展示
    workspace_root: String,
    /// Git 本地更改保护策略（对齐 Tauri `GeneralPanel` 的本地 `gitPolicy` state，暂不落盘）
    git_policy: String,
    /// 本次会话诊断日志开关（对齐 Tauri 日志面板的会话级状态，重启恢复默认）
    diagnostic_mode: bool,
    /// 隐藏目录/文件模式多行编辑器（General 分组，内容即设置值，应用时落盘）。
    hidden_dirs_input: Option<Entity<TextareaState>>,
    hidden_files_input: Option<Entity<TextareaState>>,
    /// 项目工具链单行输入（Project 分组，打开分类时由 local.json 回填）。
    project_jdk_input: Option<Entity<InputState>>,
    project_maven_input: Option<Entity<InputState>>,
    project_maven_jdk_input: Option<Entity<InputState>>,
    /// 已加载工具链的工作区（避免跨项目复用脏输入框）。
    project_loaded_for: String,
    /// 项目/运行/日志/更新分组的操作回执展示。
    project_status: String,
    run_configs: Vec<String>,
    run_status: String,
    run_load_seq: u64,
    client: CoreClient,
    /// AI 模型单行输入（provider 切换不重置，由用户显式修改）。
    ai_model_input: Option<Entity<InputState>>,
    /// Git 可执行路径单行输入。
    git_exe_input: Option<Entity<InputState>>,
    /// 日志自定义目录单行输入。
    log_dir_input: Option<Entity<InputState>>,
    logs_status: String,
    updates_status: String,
}

impl EventEmitter<SettingsEvent> for SettingsDialog {}

impl SettingsDialog {
    /// 从持久化设置读取上次打开的分类；同时缓存工作区路径供 Project 分类展示。
    pub fn new(cx: &mut Context<Self>) -> Self {
        let active_category = SettingsCategory::from_id(&settings::get(cx).last_settings_tab);
        let workspace_root = std::env::current_dir()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        Self {
            active_category,
            workspace_root,
            git_policy: "ask".to_string(),
            diagnostic_mode: false,
            hidden_dirs_input: None,
            hidden_files_input: None,
            project_jdk_input: None,
            project_maven_input: None,
            project_maven_jdk_input: None,
            project_loaded_for: String::new(),
            project_status: String::new(),
            run_configs: Vec::new(),
            run_status: String::new(),
            run_load_seq: 0,
            client: CoreClient::new(),
            ai_model_input: None,
            git_exe_input: None,
            log_dir_input: None,
            logs_status: String::new(),
            updates_status: String::new(),
        }
    }

    /// 切换工作区并使旧的 Run 配置加载结果失效。
    pub fn set_workspace_root(&mut self, root: String, cx: &mut Context<Self>) {
        if self.workspace_root == root {
            return;
        }
        self.workspace_root = root;
        self.run_load_seq += 1;
        self.run_configs.clear();
        self.run_status.clear();
        self.project_loaded_for.clear();
        self.project_status.clear();
        cx.notify();
    }

    /// 切换分类并把 `lastSettingsTab` 写回磁盘，保证下次打开停在同一页。
    pub fn set_category(&mut self, cat: SettingsCategory, cx: &mut Context<Self>) {
        self.active_category = cat;
        settings::update(cx, |s| s.last_settings_tab = cat.id().to_string());
        if cat == SettingsCategory::Run {
            self.refresh_run_configs(false, cx);
        }
        cx.notify();
    }

    /// 打开对话框时按持久化的 `lastSettingsTab` 重置分类。
    pub fn open(&mut self, cx: &mut Context<Self>) {
        self.active_category = SettingsCategory::from_id(&settings::get(cx).last_settings_tab);
        if self.active_category == SettingsCategory::Run {
            self.refresh_run_configs(false, cx);
        }
        cx.notify();
    }

    fn refresh_run_configs(&mut self, generate: bool, cx: &mut Context<Self>) {
        self.run_load_seq += 1;
        let seq = self.run_load_seq;
        let root = self.workspace_root.clone();
        let client = self.client.clone();
        self.run_status = if generate {
            "生成中…".to_string()
        } else {
            "加载中…".to_string()
        };
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result: Result<Vec<String>, String> = async {
                if generate {
                    let generated = client
                        .execute::<serde_json::Value, serde_json::Value>(
                            &cx,
                            "runConfig.generate",
                            serde_json::json!({
                                "root": root,
                                "paths": list_java_sources(&root),
                                "modulePaths": []
                            }),
                        )
                        .await?;
                    if !this
                        .update(cx, |view, _cx| view.run_load_seq == seq)
                        .unwrap_or(false)
                    {
                        return Err("stale run configuration request".to_string());
                    }
                    let document = generated
                        .get("generated")
                        .cloned()
                        .unwrap_or_else(|| serde_json::json!({"version": 2, "configurations": []}));
                    let requirements = generated
                        .get("toolchainRequirements")
                        .cloned()
                        .unwrap_or_else(|| serde_json::json!({"version": 1, "toolchains": {}}));
                    write_generated_documents(
                        &root,
                        &document,
                        &requirements,
                        default_generated_configuration_id(&document).as_deref(),
                    )?;
                }
                let inspection = client
                    .execute::<serde_json::Value, serde_json::Value>(
                        &cx,
                        "runConfig.inspect",
                        serde_json::json!({ "root": root, "checkFingerprint": true }),
                    )
                    .await?;
                if inspection.get("status").and_then(serde_json::Value::as_str) != Some("ready") {
                    return Err("Run configuration has not been generated".to_string());
                }
                let resolved = client
                    .execute::<serde_json::Value, serde_json::Value>(
                        &cx,
                        "runConfig.resolve",
                        serde_json::json!({ "root": root, "toolchainCandidates": [] }),
                    )
                    .await?;
                let parsed = parse_resolved_configurations(&resolved)?;
                Ok(parsed
                    .configurations
                    .into_iter()
                    .map(|item| format!("{} ({})", item.name, item.provider))
                    .collect())
            }
            .await;
            let _ = this.update(cx, |view, cx| {
                if view.run_load_seq != seq {
                    return;
                }
                match result {
                    Ok(configs) => {
                        view.run_configs = configs;
                        view.run_status = if view.run_configs.is_empty() {
                            "暂无可运行配置".to_string()
                        } else {
                            String::new()
                        };
                        if generate {
                            cx.emit(SettingsEvent::RunConfigurationChanged);
                        }
                    }
                    Err(error) => view.run_status = error,
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 恢复本地占位项的默认值（不涉及持久化）。
    fn reset_placeholders(&mut self) {
        self.git_policy = "ask".to_string();
        self.diagnostic_mode = false;
        self.hidden_dirs_input = None;
        self.hidden_files_input = None;
        self.project_jdk_input = None;
        self.project_maven_input = None;
        self.project_maven_jdk_input = None;
        self.project_loaded_for = String::new();
        self.project_status = String::new();
        self.run_configs = Vec::new();
        self.run_status = String::new();
        self.run_load_seq = self.run_load_seq.saturating_add(1);
        self.ai_model_input = None;
        self.git_exe_input = None;
        self.log_dir_input = None;
        self.logs_status = String::new();
        self.updates_status = String::new();
    }

    /// 写入设置、广播 `Changed` 并刷新视图。
    fn commit(&self, cx: &mut Context<Self>, mutate: impl FnOnce(&mut Settings)) {
        settings::update(cx, mutate);
        cx.emit(SettingsEvent::Changed);
        cx.notify();
    }

    /// 写入主题相关设置后，立即把解析后的主题应用到工作台调色板。
    fn commit_theme(&self, cx: &mut Context<Self>, mutate: impl FnOnce(&mut Settings)) {
        settings::update(cx, mutate);
        let theme_id = settings::resolved_theme_id(settings::get(cx), false);
        settings::apply_theme(&theme_id);
        cx.emit(SettingsEvent::Changed);
        cx.notify();
    }

    /// 懒创建单行输入框（首次渲染时用初始值填充，后续渲染复用用户编辑态）。
    fn ensure_input(
        slot: &mut Option<Entity<InputState>>,
        initial: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(entity) = slot.clone() {
            return entity;
        }
        let initial = initial.to_string();
        let entity = cx.new(|cx| InputState::new(window, cx).default_value(initial));
        *slot = Some(entity.clone());
        entity
    }

    /// 懒创建多行输入框（隐藏路径模式编辑用）。
    fn ensure_textarea(
        slot: &mut Option<Entity<TextareaState>>,
        initial: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<TextareaState> {
        if let Some(entity) = slot.clone() {
            return entity;
        }
        let initial = initial.to_string();
        let entity = cx.new(|cx| TextareaState::new(window, cx).default_value(initial));
        *slot = Some(entity.clone());
        entity
    }

    /// 单行文本输入渲染（宽 220px，对齐 Tauri `Input` 控件）。
    fn render_text_input(entity: Entity<InputState>) -> impl IntoElement {
        div()
            .w(px(220.0))
            .child(Input::new(&entity).cleanable(true))
    }
}

impl Render for SettingsDialog {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 全屏半透明遮罩：点击遮罩关闭，点击卡片不冒泡。
        div()
            .id("settings-dialog-backdrop")
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(SettingsEvent::Close);
                }),
            )
            .child(
                v_flex()
                    .id("settings-dialog-card")
                    .w(px(820.0))
                    .h(px(620.0))
                    .bg(ThemeColors::surface())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            // 卡片内点击必须阻断冒泡，否则会触发遮罩的关闭逻辑。
                            cx.stop_propagation();
                        }),
                    )
                    // 1. 头部：标题、搜索占位、关闭按钮
                    .child(
                        h_flex()
                            .h(px(44.0))
                            .w_full()
                            .items_center()
                            .justify_between()
                            .gap_3()
                            .px_3()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::surface())
                            .child(
                                h_flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        Icon::new(IconName::Settings)
                                            .size(px(16.0))
                                            .text_color(ThemeColors::primary()),
                                    )
                                    .child(
                                        div()
                                            .text_sm()
                                            .font_weight(FontWeight::BOLD)
                                            .text_color(ThemeColors::foreground())
                                            .child(crate::i18n::menu_text(
                                                cx,
                                                "workbench.settings",
                                            )),
                                    ),
                            )
                            .child(
                                // 搜索输入框占位：仅展示，不接输入。
                                h_flex()
                                    .w(px(220.0))
                                    .h(px(28.0))
                                    .items_center()
                                    .gap_2()
                                    .px_2p5()
                                    .rounded_sm()
                                    .border_1()
                                    .border_color(ThemeColors::border())
                                    .bg(ThemeColors::background())
                                    .child(
                                        Icon::new(IconName::Search)
                                            .size(px(13.0))
                                            .text_color(ThemeColors::subtle_foreground()),
                                    )
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(ThemeColors::subtle_foreground())
                                            .child(
                                                crate::i18n::menu_text(cx, "settings.search")
                                                    .to_string(),
                                            ),
                                    ),
                            )
                            .child(
                                Button::new("settings-close")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Close)
                                    .tooltip(crate::i18n::menu_text(cx, "ui.close").to_string())
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(SettingsEvent::Close);
                                    })),
                            ),
                    )
                    // 2. 主体：左侧分类导航 + 右侧滚动内容
                    .child(
                        h_flex()
                            .flex_1()
                            .w_full()
                            .min_h_0()
                            .overflow_hidden()
                            .child(
                                v_flex()
                                    .w(px(190.0))
                                    .h_full()
                                    .flex_shrink_0()
                                    .gap_0p5()
                                    .p_2()
                                    .border_r_1()
                                    .border_color(ThemeColors::border())
                                    .bg(ThemeColors::surface())
                                    .children(
                                        SettingsCategory::ALL
                                            .iter()
                                            .map(|cat| self.render_nav_item(*cat, cx)),
                                    ),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .h_full()
                                    .min_w_0()
                                    .bg(ThemeColors::background())
                                    .p_4()
                                    .overflow_y_scrollbar()
                                    .child(
                                        v_flex()
                                            .w_full()
                                            .gap_4()
                                            .child(
                                                div()
                                                    .text_lg()
                                                    .font_weight(FontWeight::SEMIBOLD)
                                                    .text_color(ThemeColors::foreground())
                                                    .child(crate::i18n::menu_text(
                                                        cx,
                                                        self.active_category.title_key(),
                                                    )),
                                            )
                                            .child(match self.active_category {
                                                SettingsCategory::General => self
                                                    .render_general_content(window, cx)
                                                    .into_any_element(),
                                                SettingsCategory::Project => self
                                                    .render_project_content(window, cx)
                                                    .into_any_element(),
                                                SettingsCategory::Run => {
                                                    self.render_run_content(cx).into_any_element()
                                                }
                                                SettingsCategory::Editor => self
                                                    .render_editor_content(cx)
                                                    .into_any_element(),
                                                SettingsCategory::Keyboard => self
                                                    .render_keyboard_content(cx)
                                                    .into_any_element(),
                                                SettingsCategory::Terminal => self
                                                    .render_terminal_content(cx)
                                                    .into_any_element(),
                                                SettingsCategory::Lsp => {
                                                    self.render_lsp_content(cx).into_any_element()
                                                }
                                                SettingsCategory::Ai => self
                                                    .render_ai_content(window, cx)
                                                    .into_any_element(),
                                                SettingsCategory::AiCommit => self
                                                    .render_ai_commit_content(cx)
                                                    .into_any_element(),
                                                SettingsCategory::Git => self
                                                    .render_git_content(window, cx)
                                                    .into_any_element(),
                                                SettingsCategory::Logs => self
                                                    .render_logs_content(window, cx)
                                                    .into_any_element(),
                                                SettingsCategory::Updates => self
                                                    .render_updates_content(cx)
                                                    .into_any_element(),
                                            }),
                                    ),
                            ),
                    )
                    // 3. 底部：左侧恢复默认，右侧主按钮关闭
                    .child(
                        h_flex()
                            .h(px(44.0))
                            .w_full()
                            .items_center()
                            .justify_between()
                            .px_3()
                            .border_t_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::surface())
                            .child(
                                Button::new("settings-restore-defaults")
                                    .small()
                                    .ghost()
                                    .label(crate::i18n::menu_text(
                                        cx,
                                        "settings.mac.restoreDefaults",
                                    ))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        // 恢复默认：整体替换为 Settings::default 并落盘。
                                        settings::update(cx, |s| *s = Settings::default());
                                        let theme_id =
                                            settings::resolved_theme_id(settings::get(cx), false);
                                        settings::apply_theme(&theme_id);
                                        this.active_category = SettingsCategory::from_id(
                                            &settings::get(cx).last_settings_tab,
                                        );
                                        this.reset_placeholders();
                                        cx.emit(SettingsEvent::Changed);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("settings-done")
                                    .small()
                                    .primary()
                                    .label(
                                        crate::i18n::menu_text(cx, "settings.mac.done").to_string(),
                                    )
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(SettingsEvent::Close);
                                    })),
                            ),
                    ),
            )
    }
}

/// 常规渲染块：分组、行、控件与分类内容。
impl SettingsDialog {
    /// 左侧导航项：active 使用 accent 背景 + 左侧 primary 竖条 + 加粗前景。
    fn render_nav_item(&self, cat: SettingsCategory, cx: &mut Context<Self>) -> impl IntoElement {
        let is_active = self.active_category == cat;
        h_flex()
            .id(cat.id())
            .h(px(32.0))
            .w_full()
            .items_center()
            .gap_2p5()
            .px_2p5()
            .rounded_sm()
            .border_l_2()
            .cursor_pointer()
            .text_xs()
            .when(is_active, |row| {
                row.bg(ThemeColors::accent())
                    .border_color(ThemeColors::primary())
                    .text_color(ThemeColors::foreground())
                    .font_weight(FontWeight::BOLD)
            })
            .when(!is_active, |row| {
                row.border_color(rgba(0x00000000))
                    .text_color(ThemeColors::subtle_foreground())
                    .hover(|h| {
                        h.bg(ThemeColors::accent())
                            .text_color(ThemeColors::foreground())
                    })
            })
            .child(
                Icon::new(cat.icon())
                    .size(px(14.0))
                    .text_color(if is_active {
                        ThemeColors::foreground()
                    } else {
                        ThemeColors::subtle_foreground()
                    }),
            )
            .child(crate::i18n::menu_text(cx, cat.title_key()))
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.set_category(cat, cx);
            }))
    }

    /// 分组容器：标题条 + 内容区，对应 Tauri `SettingsGroup`。
    fn render_group(&self, title: String, content: impl IntoElement) -> impl IntoElement {
        v_flex()
            .w_full()
            .rounded_md()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::surface())
            .overflow_hidden()
            .child(
                div()
                    .px_3()
                    .py_2()
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .text_xs()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(ThemeColors::subtle_foreground())
                    .child(title),
            )
            .child(v_flex().w_full().gap_3().p_3().child(content))
    }

    /// 设置行：左侧标签与描述，右侧控件。标签与描述使用 owned 字符串，
    /// 以便展示动态值（主题名、路径、版本号等）。
    fn render_row(
        &self,
        label: String,
        description: Option<String>,
        control: impl IntoElement,
    ) -> impl IntoElement {
        let mut info = v_flex().flex_1().min_w_0().child(
            div()
                .text_xs()
                .text_color(ThemeColors::foreground())
                .child(label),
        );
        if let Some(desc) = description {
            info = info.child(
                div()
                    .mt_1()
                    .text_xs()
                    .text_color(ThemeColors::subtle_foreground())
                    .child(desc),
            );
        }
        h_flex()
            .w_full()
            .min_h(px(32.0))
            .items_center()
            .gap_4()
            .child(info)
            .child(div().flex_shrink_0().child(control))
    }

    /// 开关控件：可点击药丸，圆点指示开关状态（对齐 Tauri Switch 无文字）。
    fn render_toggle(
        &self,
        id: &'static str,
        value: bool,
        cx: &mut Context<Self>,
        toggle: impl Fn(&mut Self, &mut Context<Self>) + 'static,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .items_center()
            .gap_1p5()
            .px_2p5()
            .py_1()
            .rounded_sm()
            .border_1()
            .cursor_pointer()
            .text_xs()
            .when(value, |el| {
                el.bg(ThemeColors::primary())
                    .border_color(ThemeColors::primary())
                    .text_color(ThemeColors::foreground())
            })
            .when(!value, |el| {
                el.bg(ThemeColors::background())
                    .border_color(ThemeColors::border())
                    .text_color(ThemeColors::subtle_foreground())
                    .hover(|h| {
                        h.bg(ThemeColors::accent())
                            .text_color(ThemeColors::foreground())
                    })
            })
            .child(div().w(px(8.0)).h(px(8.0)).rounded_full().bg(if value {
                ThemeColors::foreground()
            } else {
                ThemeColors::subtle_foreground()
            }))
            .on_click(cx.listener(move |this, _event, _window, cx| toggle(this, cx)))
    }

    /// 数值步进器：减号 + 当前值 + 加号。
    fn render_stepper(
        &self,
        dec_id: &'static str,
        inc_id: &'static str,
        value: String,
        cx: &mut Context<Self>,
        on_dec: impl Fn(&mut Self, &mut Context<Self>) + 'static,
        on_inc: impl Fn(&mut Self, &mut Context<Self>) + 'static,
    ) -> impl IntoElement {
        h_flex()
            .items_center()
            .rounded_sm()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::background())
            .overflow_hidden()
            .child(
                Button::new(dec_id)
                    .small()
                    .ghost()
                    .icon(IconName::Minus)
                    .on_click(cx.listener(move |this, _event, _window, cx| on_dec(this, cx))),
            )
            .child(
                div()
                    .w(px(56.0))
                    .text_center()
                    .text_xs()
                    .text_color(ThemeColors::foreground())
                    .child(value),
            )
            .child(
                Button::new(inc_id)
                    .small()
                    .ghost()
                    .icon(IconName::Plus)
                    .on_click(cx.listener(move |this, _event, _window, cx| on_inc(this, cx))),
            )
    }

    /// 只读文本值。
    fn render_value(&self, value: String) -> impl IntoElement {
        div()
            .px_2p5()
            .py_1()
            .rounded_sm()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::background())
            .text_xs()
            .text_color(ThemeColors::muted_foreground())
            .child(value)
    }

    /// 下拉选择框：当前值按钮 + ChevronDown，点击展开选项列表。
    /// 对齐 Tauri 各面板的原生 `<select>`（`controlClassName` + `w-40/32/44`）。
    /// `options` 为 (值, 展示文本) 对，展示文本为 owned String（便于动态拼接如 "2 个空格"），
    /// 按钮显示当前值对应的展示文本，选中项打勾。
    fn render_dropdown(
        &self,
        id: &'static str,
        current: String,
        width: f32,
        options: Vec<(&'static str, String)>,
        cx: &mut Context<Self>,
        on_select: impl Fn(&mut Self, &'static str, &mut Context<Self>) + 'static,
    ) -> impl IntoElement {
        let view = cx.entity();
        let on_select = std::rc::Rc::new(on_select);
        let current_owned = current.clone();
        let options_for_label = options.clone();
        // 按钮展示当前值对应的展示文本（对齐原生 select 显示 label 的行为）。
        let current_label = options_for_label
            .iter()
            .find(|(value, _)| *value == current_owned.as_str())
            .map(|(_, label)| label.clone())
            .unwrap_or(current_owned.clone());
        Button::new(id)
            .small()
            .ghost()
            .rounded_md()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::background())
            .w(px(width))
            .child(
                div()
                    .flex_1()
                    .text_xs()
                    .text_color(ThemeColors::foreground())
                    .child(current_label),
            )
            .child(
                Icon::new(IconName::ChevronDown)
                    .size(px(13.0))
                    .text_color(ThemeColors::subtle_foreground()),
            )
            .dropdown_menu(move |menu, _window, _cx| {
                let mut menu = menu;
                for (value, label) in &options {
                    let v = view.clone();
                    let select = on_select.clone();
                    let value = *value;
                    let label = label.clone();
                    let selected = value == current.as_str();
                    let item = gpui_kit::component::menu::PopupMenuItem::new(label);
                    let item = if selected {
                        item.icon(IconName::Check)
                    } else {
                        item
                    };
                    menu = menu.item(item.on_click(move |_, _, cx| {
                        v.update(cx, |this, cx| select(this, value, cx));
                    }));
                }
                menu
            })
    }

    /// 分组内的说明文本。
    fn render_note(&self, text: String) -> impl IntoElement {
        div()
            .text_xs()
            .text_color(ThemeColors::subtle_foreground())
            .child(text)
    }
}

/// 各分类内容渲染。
impl SettingsDialog {
    /// 常规：对齐 Tauri `GeneralPanel`（外观/语言/项目/文件/Git/隐藏路径）。
    fn render_general_content(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let s = settings::get(cx).clone();
        // 隐藏路径编辑器先创建（避免 render_group 的 &self 借用冲突）。
        let dirs_entity = Self::ensure_textarea(
            &mut self.hidden_dirs_input,
            &s.hidden_directory_patterns.join("\n"),
            window,
            cx,
        );
        let files_entity = Self::ensure_textarea(
            &mut self.hidden_files_input,
            &s.hidden_file_patterns.join("\n"),
            window,
            cx,
        );
        // 外观模式由 syncSystemTheme + theme 派生，与 Tauri `appearanceMode` 一致。
        let appearance_mode = if s.sync_system_theme {
            "system"
        } else if s.theme.contains("light") {
            "light"
        } else {
            "dark"
        }
        .to_string();
        // 项目打开方式同样派生自两个字段（`getProjectOpenPreference`）。
        let placement = if s.ask_where_to_open_projects {
            "ask"
        } else if s.open_folders_in_new_window {
            "new-window"
        } else {
            "this-window"
        }
        .to_string();

        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.appearance").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.mac.appearanceMode")
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.mac.appearanceDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_dropdown(
                                    "general-appearance-mode",
                                    appearance_mode,
                                    160.0,
                                    vec![
                                        (
                                            "system",
                                            crate::i18n::menu_text(cx, "settings.mac.followSystem")
                                                .to_string(),
                                        ),
                                        (
                                            "light",
                                            crate::i18n::menu_text(cx, "settings.mac.light")
                                                .to_string(),
                                        ),
                                        (
                                            "dark",
                                            crate::i18n::menu_text(cx, "settings.mac.dark")
                                                .to_string(),
                                        ),
                                    ],
                                    cx,
                                    |this, mode, cx| {
                                        this.commit_theme(cx, |s| {
                                            if mode == "system" {
                                                s.sync_system_theme = true;
                                            } else {
                                                s.sync_system_theme = false;
                                                s.theme = if mode == "light" {
                                                    "lithe-light".to_string()
                                                } else {
                                                    "lithe-dark".to_string()
                                                };
                                            }
                                        })
                                    },
                                ),
                            ),
                        ),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.mac.language").to_string(),
                v_flex().w_full().gap_3().child(self.render_row(
                    crate::i18n::menu_text(cx, "settings.mac.language").to_string(),
                    Some(
                        crate::i18n::menu_text(cx, "settings.mac.languageDescription").to_string(),
                    ),
                    self.render_dropdown(
                        "general-language",
                        s.display_language.clone(),
                        160.0,
                        vec![
                            ("en-US", "English".to_string()),
                            ("zh-CN", "简体中文".to_string()),
                        ],
                        cx,
                        |this, lang, cx| this.commit(cx, |s| s.display_language = lang.to_string()),
                    ),
                )),
            ))
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.projects").to_string(),
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.openProjectsIn").to_string(),
                            Some(
                                crate::i18n::menu_text(cx, "settings.mac.openProjectsDescription")
                                    .to_string()
                                    .to_string(),
                            ),
                            self.render_dropdown(
                                "general-project-placement",
                                placement,
                                160.0,
                                vec![
                                    (
                                        "ask",
                                        crate::i18n::menu_text(cx, "settings.mac.askEveryTime")
                                            .to_string(),
                                    ),
                                    (
                                        "this-window",
                                        crate::i18n::menu_text(cx, "settings.mac.thisWindow")
                                            .to_string(),
                                    ),
                                    (
                                        "new-window",
                                        crate::i18n::menu_text(cx, "settings.mac.newWindow")
                                            .to_string(),
                                    ),
                                ],
                                cx,
                                |this, mode, cx| {
                                    this.commit(cx, |s| match mode {
                                        "ask" => s.ask_where_to_open_projects = true,
                                        "this-window" => {
                                            s.ask_where_to_open_projects = false;
                                            s.open_folders_in_new_window = false;
                                        }
                                        _ => {
                                            s.ask_where_to_open_projects = false;
                                            s.open_folders_in_new_window = true;
                                        }
                                    })
                                },
                            ),
                        ),
                    ),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.mac.files").to_string(),
                v_flex().w_full().gap_3().child(self.render_row(
                    crate::i18n::menu_text(cx, "settings.mac.autoSave").to_string(),
                    None,
                    self.render_toggle("general-auto-save", s.auto_save, cx, |this, cx| {
                        this.commit(cx, |s| s.auto_save = !s.auto_save)
                    }),
                )),
            ))
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.tabs.git").to_string(),
                v_flex().w_full().gap_3().child(self.render_row(
                    crate::i18n::menu_text(cx, "settings.mac.saveLocalChangesWith").to_string(),
                    Some(
                        crate::i18n::menu_text(cx, "settings.mac.gitPolicyDescription").to_string(),
                    ),
                    self.render_dropdown(
                        "general-git-policy",
                        self.git_policy.clone(),
                        160.0,
                        vec![
                            (
                                "ask",
                                crate::i18n::menu_text(cx, "settings.mac.askEveryTime").to_string(),
                            ),
                            (
                                "shelf",
                                crate::i18n::menu_text(cx, "settings.mac.shelf").to_string(),
                            ),
                            (
                                "stash",
                                crate::i18n::menu_text(cx, "settings.mac.gitStash").to_string(),
                            ),
                        ],
                        cx,
                        |this, policy, cx| {
                            this.git_policy = policy.to_string();
                            cx.notify();
                        },
                    ),
                )),
            ))
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.hiddenPaths").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_note(
                                crate::i18n::menu_text(cx, "settings.mac.hiddenPathsDescription")
                                    .to_string(),
                            ),
                        )
                        .child(div().text_xs().text_color(ThemeColors::foreground()).child(
                            crate::i18n::menu_text(cx, "settings.mac.directories").to_string(),
                        ))
                        .child(
                            Textarea::new(&dirs_entity)
                                .bordered(true)
                                .w_full()
                                .h(px(120.0)),
                        )
                        .child(div().text_xs().text_color(ThemeColors::foreground()).child(
                            crate::i18n::menu_text(cx, "settings.mac.filePatterns").to_string(),
                        ))
                        .child(
                            Textarea::new(&files_entity)
                                .bordered(true)
                                .w_full()
                                .h(px(96.0)),
                        )
                        .child(
                            h_flex().w_full().justify_end().child(
                                Button::new("general-apply-patterns")
                                    .small()
                                    .primary()
                                    .label(
                                        crate::i18n::menu_text(cx, "settings.mac.apply")
                                            .to_string(),
                                    )
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        // 每行一个 glob：trim + 去空后落盘，即时影响文件树。
                                        let dirs = this
                                            .hidden_dirs_input
                                            .as_ref()
                                            .map(|e| e.read(cx).value().to_string())
                                            .unwrap_or_default();
                                        let files = this
                                            .hidden_files_input
                                            .as_ref()
                                            .map(|e| e.read(cx).value().to_string())
                                            .unwrap_or_default();
                                        let split = |text: String| {
                                            text.lines()
                                                .map(str::trim)
                                                .filter(|l| !l.is_empty())
                                                .map(str::to_string)
                                                .collect::<Vec<_>>()
                                        };
                                        this.commit(cx, |s| {
                                            s.hidden_directory_patterns = split(dirs);
                                            s.hidden_file_patterns = split(files);
                                        })
                                    })),
                            ),
                        ),
                ),
            )
    }

    /// 项目 · JDK 与 Maven：对齐 `ProjectEnvironmentSettings`（工作区路径、
    /// 工具链三行、保存按钮）。值来自 `<workspace>/.lithe/run/local.json`
    ///（对齐 Mac 本机配置），缺失时回退 `which java/mvn` 探测；保存写回该文件。
    fn render_project_content(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let root = self.workspace_root.clone();
        // 切项目时重新回填输入框，避免复用上个项目的脏值。
        if self.project_loaded_for != root {
            let (jdk, maven, maven_jdk) = read_local_toolchain(&root);
            let mut fill = |slot: &mut Option<Entity<InputState>>, value: String| {
                if let Some(entity) = slot.clone() {
                    entity.update(cx, |state, cx| {
                        state.set_value(value, window, cx);
                    });
                } else {
                    *slot = Some(cx.new(|cx| InputState::new(window, cx).default_value(value)));
                }
            };
            fill(
                &mut self.project_jdk_input,
                if jdk.is_empty() {
                    which_java_home().unwrap_or_default()
                } else {
                    jdk
                },
            );
            fill(
                &mut self.project_maven_input,
                if maven.is_empty() {
                    which("mvn").unwrap_or_default()
                } else {
                    maven
                },
            );
            fill(&mut self.project_maven_jdk_input, maven_jdk);
            self.project_loaded_for = root.clone();
            self.project_status = String::new();
        }
        let jdk_entity = Self::ensure_input(&mut self.project_jdk_input, "", window, cx);
        let maven_entity = Self::ensure_input(&mut self.project_maven_input, "", window, cx);
        let maven_jdk_entity =
            Self::ensure_input(&mut self.project_maven_jdk_input, "", window, cx);
        let status = self.project_status.clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                div()
                    .font_family("monospace")
                    .text_xs()
                    .text_color(ThemeColors::foreground())
                    .child(root),
            )
            .child(
                self.render_note(crate::i18n::menu_text(cx, "settings.project.scope").to_string()),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.project.toolchain").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "run.jdkHome").to_string(),
                                Some(crate::i18n::menu_text(cx, "run.toolchainAuto").to_string()),
                                h_flex()
                                    .gap_1p5()
                                    .child(Self::render_text_input(jdk_entity))
                                    .child(
                                        Button::new("project-jdk-browse")
                                            .small()
                                            .ghost()
                                            .label("…".to_string())
                                            .on_click(cx.listener(|this, _event, _window, cx| {
                                                if let Some(dir) =
                                                super::project_dialog::ProjectDialog::pick_folder(
                                                    None,
                                                )
                                            {
                                                if let Some(e) = this.project_jdk_input.clone() {
                                                    e.update(cx, |st, cx| {
                                                        st.set_value(
                                                            dir,
                                                            _window,
                                                            cx,
                                                        );
                                                    });
                                                }
                                            }
                                            })),
                                    ),
                            ),
                        )
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "run.mavenExecutable").to_string(),
                            Some(crate::i18n::menu_text(cx, "run.toolchainAuto").to_string()),
                            Self::render_text_input(maven_entity),
                        ))
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "run.mavenJdkHome").to_string(),
                                Some(
                                    crate::i18n::menu_text(cx, "settings.project.useProjectJdk")
                                        .to_string()
                                        .to_string(),
                                ),
                                Self::render_text_input(maven_jdk_entity),
                            ),
                        )
                        .child(
                            h_flex()
                                .w_full()
                                .items_center()
                                .justify_between()
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(ThemeColors::subtle_foreground())
                                        .child(status),
                                )
                                .child(
                                    Button::new("project-save")
                                        .small()
                                        .primary()
                                        .label(crate::i18n::menu_text(cx, "ui.save").to_string())
                                        .on_click(cx.listener(|this, _event, _window, cx| {
                                            let get = |slot: &Option<Entity<InputState>>| {
                                                slot.as_ref()
                                                    .map(|e| {
                                                        e.read(cx)
                                                            .value()
                                                            .to_string()
                                                            .trim()
                                                            .to_string()
                                                    })
                                                    .unwrap_or_default()
                                            };
                                            let jdk = get(&this.project_jdk_input);
                                            let maven = get(&this.project_maven_input);
                                            let maven_jdk = get(&this.project_maven_jdk_input);
                                            let ok = write_local_toolchain(
                                                &this.workspace_root.clone(),
                                                &jdk,
                                                &maven,
                                                &maven_jdk,
                                            );
                                            this.project_status = if ok {
                                                "已保存到 .lithe/run/local.json".to_string()
                                            } else {
                                                "保存失败".to_string()
                                            };
                                            cx.emit(SettingsEvent::Changed);
                                            if ok {
                                                cx.emit(SettingsEvent::RunConfigurationChanged);
                                            }
                                            cx.notify();
                                        })),
                                ),
                        ),
                ),
            )
    }

    /// 运行配置：通过 Core inspect/resolve 读取，生成按钮走 Core generate。
    fn render_run_content(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let configs = self.run_configs.clone();
        let status = self.run_status.clone();
        let list = if configs.is_empty() {
            self.render_note(crate::i18n::menu_text(cx, "settings.run.empty").to_string())
                .into_any_element()
        } else {
            v_flex()
                .w_full()
                .gap_1p5()
                .children(configs.iter().map(|name| {
                    div()
                        .w_full()
                        .px_2p5()
                        .py_1()
                        .rounded_sm()
                        .border_1()
                        .border_color(ThemeColors::border())
                        .bg(ThemeColors::background())
                        .font_family("monospace")
                        .text_xs()
                        .text_color(ThemeColors::foreground())
                        .child(name.clone())
                }))
                .into_any_element()
        };
        v_flex().w_full().gap_4().child(
            self.render_group(
                crate::i18n::menu_text(cx, "settings.run.title").to_string(),
                v_flex()
                    .w_full()
                    .gap_3()
                    .child(self.render_note(
                        crate::i18n::menu_text(cx, "settings.run.description").to_string(),
                    ))
                    .child(list)
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::subtle_foreground())
                                    .child(status),
                            )
                            .child(
                                Button::new("run-generate")
                                    .small()
                                    .primary()
                                    .label(
                                        crate::i18n::menu_text(cx, "settings.run.generate")
                                            .to_string(),
                                    )
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.refresh_run_configs(true, cx);
                                    })),
                            ),
                    ),
            ),
        )
    }

    /// 编辑器：对齐 Tauri `EditorPanel`（显示/编辑器标签页/缩进）。
    fn render_editor_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        let spaces = crate::i18n::menu_text(cx, "settings.mac.spaces").to_string();
        let tab_options = [
            ("2", format!("2 {spaces}")),
            ("4", format!("4 {spaces}")),
            ("8", format!("8 {spaces}")),
        ];
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.display").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.fontFamily").to_string(),
                            None,
                            self.render_dropdown(
                                "editor-font-family",
                                s.font_family.clone(),
                                176.0,
                                vec![
                                    ("Geist Mono", "Geist Mono".to_string()),
                                    ("DejaVu Sans Mono", "DejaVu Sans Mono".to_string()),
                                    ("Noto Sans Mono", "Noto Sans Mono".to_string()),
                                    ("monospace", "monospace".to_string()),
                                ],
                                cx,
                                |this, family, cx| {
                                    this.commit(cx, |s| s.font_family = family.to_string())
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.fontSize").to_string(),
                            None,
                            self.render_stepper(
                                "font-dec",
                                "font-inc",
                                format!("{} px", s.font_size as i32),
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.font_size = (s.font_size - 1.0).max(8.0))
                                },
                                |this, cx| {
                                    this.commit(cx, |s| s.font_size = (s.font_size + 1.0).min(32.0))
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.lineHeight").to_string(),
                            None,
                            self.render_stepper(
                                "line-height-dec",
                                "line-height-inc",
                                format!("{:.1}", s.editor_line_height),
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.editor_line_height = (s.editor_line_height - 0.1).max(1.0)
                                    })
                                },
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.editor_line_height = (s.editor_line_height + 0.1).min(2.0)
                                    })
                                },
                            ),
                        ))
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.editor.renderWhitespace")
                                    .to_string(),
                                None,
                                self.render_dropdown(
                                    "editor-render-whitespace",
                                    s.render_whitespace.clone(),
                                    160.0,
                                    vec![
                                        (
                                            "none",
                                            crate::i18n::menu_text(
                                                cx,
                                                "settings.editor.whitespaceNone",
                                            )
                                            .to_string(),
                                        ),
                                        (
                                            "boundary",
                                            crate::i18n::menu_text(
                                                cx,
                                                "settings.editor.whitespaceBoundary",
                                            )
                                            .to_string(),
                                        ),
                                        (
                                            "trailing",
                                            crate::i18n::menu_text(
                                                cx,
                                                "settings.editor.whitespaceTrailing",
                                            )
                                            .to_string(),
                                        ),
                                        (
                                            "all",
                                            crate::i18n::menu_text(
                                                cx,
                                                "settings.editor.whitespaceAll",
                                            )
                                            .to_string(),
                                        ),
                                    ],
                                    cx,
                                    |this, value, cx| {
                                        this.commit(cx, |s| s.render_whitespace = value.to_string())
                                    },
                                ),
                            ),
                        )
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.showCodeVision").to_string(),
                            None,
                            self.render_toggle("editor-code-lens", s.code_lens, cx, |this, cx| {
                                this.commit(cx, |s| s.code_lens = !s.code_lens)
                            }),
                        )),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.editorTabs").to_string(),
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.bufferCarousel")
                                .to_string()
                                .to_string(),
                            Some(
                                crate::i18n::menu_text(
                                    cx,
                                    "settings.editor.bufferCarouselDescription",
                                )
                                .to_string(),
                            ),
                            self.render_toggle(
                                "editor-buffer-carousel",
                                s.horizontal_tab_scroll,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.horizontal_tab_scroll = !s.horizontal_tab_scroll
                                    })
                                },
                            ),
                        ),
                    ),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.mac.indentation").to_string(),
                v_flex().w_full().gap_3().child(self.render_row(
                    crate::i18n::menu_text(cx, "settings.mac.tabWidth").to_string(),
                    None,
                    self.render_dropdown(
                        "editor-tab-width",
                        s.tab_size.to_string(),
                        128.0,
                        vec![
                            ("2", tab_options[0].1.clone()),
                            ("4", tab_options[1].1.clone()),
                            ("8", tab_options[2].1.clone()),
                        ],
                        cx,
                        |this, size, cx| {
                            this.commit(cx, |s| s.tab_size = size.parse().unwrap_or(2))
                        },
                    ),
                )),
            ))
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.editor.behavior").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.wordWrap").to_string(),
                            None,
                            self.render_toggle("editor-word-wrap", s.word_wrap, cx, |this, cx| {
                                this.commit(cx, |s| s.word_wrap = !s.word_wrap)
                            }),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.vimMode").to_string(),
                            None,
                            self.render_toggle("editor-vim-mode", s.vim_mode, cx, |this, cx| {
                                this.commit(cx, |s| s.vim_mode = !s.vim_mode)
                            }),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.formatOnSave").to_string(),
                            None,
                            self.render_toggle(
                                "editor-format-on-save",
                                s.format_on_save,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.format_on_save = !s.format_on_save)
                                },
                            ),
                        )),
                ),
            )
    }

    /// 快捷键：对齐 Tauri `KeyboardPanel`（快捷键方案/键盘快捷键）。
    fn render_keyboard_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.keymapPreset").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.preset").to_string(),
                            None,
                            self.render_dropdown(
                                "keymap-preset",
                                s.keybinding_preset.clone(),
                                176.0,
                                vec![
                                    ("none", "Lithe".to_string()),
                                    ("vscode", "Visual Studio Code".to_string()),
                                    ("jetbrains", "JetBrains".to_string()),
                                    ("sublime", "Sublime Text".to_string()),
                                    ("xcode", "Xcode".to_string()),
                                    ("atom", "Atom".to_string()),
                                    ("emacs", "Emacs".to_string()),
                                    ("zed", "Zed".to_string()),
                                ],
                                cx,
                                |this, preset, cx| {
                                    this.commit(cx, |s| s.keybinding_preset = preset.to_string())
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.vimMode").to_string(),
                            None,
                            self.render_toggle("keymap-vim-mode", s.vim_mode, cx, |this, cx| {
                                this.commit(cx, |s| s.vim_mode = !s.vim_mode)
                            }),
                        )),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.shortcuts").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            h_flex()
                                .h(px(32.0))
                                .w_full()
                                .items_center()
                                .gap_2()
                                .px_2p5()
                                .rounded_sm()
                                .border_1()
                                .border_color(ThemeColors::border())
                                .bg(ThemeColors::background())
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(ThemeColors::subtle_foreground())
                                        .child("⌕"),
                                )
                                .child(
                                    div()
                                        .flex_1()
                                        .text_xs()
                                        .text_color(ThemeColors::subtle_foreground())
                                        .child(crate::i18n::menu_text(
                                            cx,
                                            "settings.mac.searchShortcuts",
                                        )),
                                ),
                        )
                        .child(
                            self.render_note(
                                crate::i18n::menu_text(cx, "settings.mac.shortcutsDescription")
                                    .to_string(),
                            ),
                        ),
                ),
            )
    }

    /// 终端：对齐 Tauri `TerminalPanel`（启动/默认 Shell/排版/滚动/光标）。
    /// 只收录当前平台真实存在的系统 shell；Windows 下列表为空，保留系统默认项。
    fn render_terminal_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        // 固定候选集转静态引用（避免每次渲染泄漏内存）。
        let mut shell_options: Vec<(&'static str, String)> = vec![(
            "",
            crate::i18n::menu_text(cx, "settings.mac.systemDefault").to_string(),
        )];
        for name in detect_available_shells() {
            let value: &'static str = match name.as_str() {
                "bash" => "bash",
                "zsh" => "zsh",
                "fish" => "fish",
                "sh" => "sh",
                "dash" => "dash",
                _ => continue,
            };
            shell_options.push((value, name));
        }
        v_flex().w_full().gap_4().child(
            self.render_group(
                crate::i18n::menu_text(cx, "settings.mac.shell").to_string(),
                v_flex()
                    .w_full()
                    .gap_3()
                    .child(
                        self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.defaultShell").to_string(),
                            Some(
                                crate::i18n::menu_text(cx, "settings.mac.defaultShellDescription")
                                    .to_string(),
                            ),
                            self.render_dropdown(
                                "terminal-default-shell",
                                s.terminal_default_shell_id.clone(),
                                176.0,
                                shell_options,
                                cx,
                                |this, shell, cx| {
                                    this.commit(cx, |s| {
                                        s.terminal_default_shell_id = shell.to_string()
                                    })
                                },
                            ),
                        ),
                    )
                    .child(self.render_row(
                        crate::i18n::menu_text(cx, "settings.terminal.fontSize").to_string(),
                        None,
                        self.render_stepper(
                            "terminal-font-dec",
                            "terminal-font-inc",
                            format!("{} px", s.terminal_font_size as i32),
                            cx,
                            |this, cx| {
                                this.commit(cx, |s| {
                                    s.terminal_font_size = (s.terminal_font_size - 1.0).max(8.0)
                                })
                            },
                            |this, cx| {
                                this.commit(cx, |s| {
                                    s.terminal_font_size = (s.terminal_font_size + 1.0).min(32.0)
                                })
                            },
                        ),
                    ))
                    .child(self.render_row(
                        crate::i18n::menu_text(cx, "settings.terminal.scrollback").to_string(),
                        None,
                        self.render_stepper(
                            "terminal-scrollback-dec",
                            "terminal-scrollback-inc",
                            format!("{}", s.terminal_scrollback),
                            cx,
                            |this, cx| {
                                this.commit(cx, |s| {
                                    s.terminal_scrollback =
                                        s.terminal_scrollback.saturating_sub(1000).max(1000)
                                })
                            },
                            |this, cx| {
                                this.commit(cx, |s| {
                                    s.terminal_scrollback =
                                        (s.terminal_scrollback + 1000).min(100000)
                                })
                            },
                        ),
                    ))
                    .child(self.render_row(
                        crate::i18n::menu_text(cx, "settings.terminal.cursorBlink").to_string(),
                        None,
                        self.render_toggle(
                            "terminal-cursor-blink",
                            s.terminal_cursor_blink,
                            cx,
                            |this, cx| {
                                this.commit(cx, |s| {
                                    s.terminal_cursor_blink = !s.terminal_cursor_blink
                                })
                            },
                        ),
                    )),
            ),
        )
    }

    /// LSP：对齐 Tauri `LspPanel`（语言服务/已检测语言服务器）。
    fn render_lsp_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.languageServices").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.mac.autoCompletion")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.mac.autoCompletionDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "lsp-auto-completion",
                                    s.auto_completion,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| s.auto_completion = !s.auto_completion)
                                    },
                                ),
                            ),
                        )
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.parameterHints").to_string(),
                            None,
                            self.render_toggle(
                                "lsp-parameter-hints",
                                s.parameter_hints,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.parameter_hints = !s.parameter_hints)
                                },
                            ),
                        ))
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.mac.semanticHighlighting")
                                    .to_string()
                                    .to_string(),
                                None,
                                self.render_toggle(
                                    "lsp-semantic-highlighting",
                                    s.semantic_tokens,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| s.semantic_tokens = !s.semantic_tokens)
                                    },
                                ),
                            ),
                        )
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.editor.formatOnSave").to_string(),
                            None,
                            self.render_toggle(
                                "lsp-format-on-save",
                                s.format_on_save,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.format_on_save = !s.format_on_save)
                                },
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.detectedServers").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_note(
                                crate::i18n::menu_text(
                                    cx,
                                    "settings.mac.detectedServersDescription",
                                )
                                .to_string(),
                            ),
                        )
                        .children(Self::detected_language_servers().into_iter().map(
                            |(name, path)| {
                                self.render_row(
                                    name.to_string(),
                                    None,
                                    self.render_value(path.unwrap_or_else(|| "未安装".to_string())),
                                )
                            },
                        ))
                        .child(self.render_note(Self::lsp_status_note())),
                ),
            )
    }

    /// PATH 中探测语言服务器可执行文件，`OnceLock` 缓存避免每次渲染重复遍历。
    /// 只做存在性展示，不触发任何启动。
    fn detected_language_servers() -> Vec<(&'static str, Option<String>)> {
        static CACHE: std::sync::OnceLock<Vec<(&'static str, Option<String>)>> =
            std::sync::OnceLock::new();
        CACHE
            .get_or_init(|| {
                ["jdtls", "clangd", "rust-analyzer", "pyright"]
                    .into_iter()
                    .map(|name| (name, Self::find_in_path(name)))
                    .collect()
            })
            .clone()
    }

    /// 在 `PATH` 中查找可执行文件，返回完整路径。
    ///
    /// Windows 上按 `PATHEXT` 补全扩展名；Unix 要求执行位。
    fn find_in_path(name: &str) -> Option<String> {
        let path = std::env::var_os("PATH")?;
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join(name);
            if !candidate.is_file() {
                continue;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                let executable = std::fs::metadata(&candidate)
                    .map(|m| m.permissions().mode() & 0o111 != 0)
                    .unwrap_or(false);
                if !executable {
                    continue;
                }
            }
            return Some(candidate.to_string_lossy().into_owned());
        }
        None
    }

    /// 诚实状态说明：JDTLS 缺失则不伪造启动，仅说明缺失项。
    fn lsp_status_note() -> String {
        let servers = Self::detected_language_servers();
        let jdtls_missing = servers
            .iter()
            .any(|(name, path)| *name == "jdtls" && path.is_none());
        if jdtls_missing {
            "JDTLS 未安装：lsp.startServer 要求 executablePath/rootUri/workingDirectory，\
            Java 还需 jdtlsLaunchResources（launcher jar/配置目录/lombok），本机均缺失，\
            故不启动；编辑器暂无诊断/悬停/补全接入。"
                .to_string()
        } else {
            "已检测到服务器但尚未接入：编辑器暂无诊断/悬停/补全客户端，未自动启动。".to_string()
        }
    }

    /// AI 聊天与编辑：提供商/模型/自动补全开关，全部落盘
    ///（对齐 Tauri `AISettings` 的 Lithe Agent 分组）。
    fn render_ai_content(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let s = settings::get(cx).clone();
        let model_entity = Self::ensure_input(&mut self.ai_model_input, &s.ai_model_id, window, cx);
        let model_for_save = model_entity.clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "Lithe Agent".to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "aiSettings.provider").to_string(),
                                Some(
                                    crate::i18n::menu_text(cx, "aiSettings.providerDescription")
                                        .to_string()
                                        .to_string(),
                                ),
                                self.render_dropdown(
                                    "ai-provider",
                                    s.ai_provider_id.clone(),
                                    176.0,
                                    vec![
                                        ("anthropic", "Anthropic".to_string()),
                                        ("openai", "OpenAI".to_string()),
                                        ("openrouter", "OpenRouter".to_string()),
                                        ("ollama", "Ollama".to_string()),
                                        ("custom", "Custom".to_string()),
                                    ],
                                    cx,
                                    |this, provider, cx| {
                                        this.commit(cx, |s| s.ai_provider_id = provider.to_string())
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "aiSettings.model").to_string(),
                                Some(
                                    crate::i18n::menu_text(cx, "aiSettings.modelDescription")
                                        .to_string()
                                        .to_string(),
                                ),
                                h_flex()
                                    .gap_1p5()
                                    .child(Self::render_text_input(model_entity))
                                    .child(
                                        Button::new("ai-model-apply")
                                            .small()
                                            .primary()
                                            .label(
                                                crate::i18n::menu_text(cx, "settings.mac.apply")
                                                    .to_string(),
                                            )
                                            .on_click(cx.listener(move |this, _e, _w, cx| {
                                                let model = model_for_save
                                                    .read(cx)
                                                    .value()
                                                    .to_string()
                                                    .trim()
                                                    .to_string();
                                                this.commit(cx, |s| s.ai_model_id = model);
                                            })),
                                    ),
                            ),
                        )
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "aiSettings.completion").to_string(),
                            None,
                            self.render_toggle("ai-completion", s.ai_completion, cx, |this, cx| {
                                this.commit(cx, |s| s.ai_completion = !s.ai_completion)
                            }),
                        )),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.ai.noteTitle").to_string(),
                self.render_note(
                    crate::i18n::menu_text(cx, "settings.ai.providerNote").to_string(),
                ),
            ))
    }

    /// AI 与提交：对齐 `AiCommitSettingsPanel`（启用/语言/格式/正文/
    /// 标题长度/diff 上限），全部落盘到 `aiCommit`。
    fn render_ai_commit_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        let ai = s.ai_commit.clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.commitMessage").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.aiCommit.enabled").to_string(),
                            None,
                            self.render_toggle("ai-commit-enabled", ai.enabled, cx, |this, cx| {
                                this.commit(cx, |s| s.ai_commit.enabled = !s.ai_commit.enabled)
                            }),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.aiCommit.language").to_string(),
                            None,
                            self.render_dropdown(
                                "ai-commit-language",
                                ai.language.clone(),
                                176.0,
                                vec![
                                    ("english", "English".to_string()),
                                    ("simplifiedChinese", "简体中文".to_string()),
                                ],
                                cx,
                                |this, value, cx| {
                                    this.commit(cx, |s| s.ai_commit.language = value.to_string())
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.aiCommit.format").to_string(),
                            None,
                            self.render_dropdown(
                                "ai-commit-format",
                                ai.format.clone(),
                                176.0,
                                vec![
                                    ("conventional", "Conventional".to_string()),
                                    ("concise", "Concise".to_string()),
                                    ("imperative", "Imperative".to_string()),
                                    ("descriptive", "Descriptive".to_string()),
                                    ("releaseNote", "Release Note".to_string()),
                                    ("custom", "Custom".to_string()),
                                ],
                                cx,
                                |this, value, cx| {
                                    this.commit(cx, |s| s.ai_commit.format = value.to_string())
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.aiCommit.includeBody").to_string(),
                            None,
                            self.render_toggle(
                                "ai-commit-include-body",
                                ai.include_body,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.ai_commit.include_body = !s.ai_commit.include_body
                                    })
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.aiCommit.subjectMax").to_string(),
                            None,
                            self.render_stepper(
                                "ai-commit-subject-dec",
                                "ai-commit-subject-inc",
                                format!("{}", ai.subject_max_length),
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.ai_commit.subject_max_length =
                                            s.ai_commit.subject_max_length.saturating_sub(4).max(40)
                                    })
                                },
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.ai_commit.subject_max_length =
                                            (s.ai_commit.subject_max_length + 4).min(120)
                                    })
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.aiCommit.diffLimit").to_string(),
                            None,
                            self.render_stepper(
                                "ai-commit-difflimit-dec",
                                "ai-commit-difflimit-inc",
                                format!("{}", ai.maximum_diff_characters),
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.ai_commit.maximum_diff_characters = s
                                            .ai_commit
                                            .maximum_diff_characters
                                            .saturating_sub(4000)
                                            .max(8000)
                                    })
                                },
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.ai_commit.maximum_diff_characters =
                                            (s.ai_commit.maximum_diff_characters + 4000).min(120000)
                                    })
                                },
                            ),
                        )),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.ai.noteTitle").to_string(),
                self.render_note(crate::i18n::menu_text(cx, "settings.ai.commitNote").to_string()),
            ))
    }

    /// Git：对齐 Tauri `GitSettings` 的偏好区
    ///（Fetch 默认行为/执行/集成/Git 视图/默认差异视图/编辑器）。
    fn render_git_content(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let s = settings::get(cx).clone();
        let exe_entity = Self::ensure_input(&mut self.git_exe_input, &s.git_executable, window, cx);
        let exe_for_detect = exe_entity.clone();
        let exe_for_clear = exe_entity.clone();
        let exe_for_save = exe_entity.clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "git.fetch.defaults").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "git.fetch.prune").to_string(),
                            Some(crate::i18n::menu_text(cx, "git.fetch.scope").to_string()),
                            self.render_toggle(
                                "git-fetch-prune",
                                s.git_fetch_prune,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.git_fetch_prune = !s.git_fetch_prune)
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "git.fetch.submodules").to_string(),
                            None,
                            self.render_dropdown(
                                "git-fetch-submodules",
                                s.git_fetch_submodules.clone(),
                                160.0,
                                vec![
                                        (
                                            "inherit",
                                            crate::i18n::menu_text(
                                                cx,
                                                "git.fetch.submodules.inherit",
                                            )
                                            .to_string(),
                                        ),
                                        (
                                            "no",
                                            crate::i18n::menu_text(cx, "git.fetch.submodules.no")
                                                .to_string(),
                                        ),
                                        (
                                            "onDemand",
                                            crate::i18n::menu_text(
                                                cx,
                                                "git.fetch.submodules.onDemand",
                                            )
                                            .to_string(),
                                        ),
                                        (
                                            "yes",
                                            crate::i18n::menu_text(cx, "git.fetch.submodules.yes")
                                                .to_string(),
                                        ),
                                    ],
                                cx,
                                |this, value, cx| {
                                    this.commit(cx, |s| s.git_fetch_submodules = value.to_string())
                                },
                            ),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "git.fetch.tags").to_string(),
                            Some(crate::i18n::menu_text(cx, "git.fetch.credentials").to_string()),
                            self.render_dropdown(
                                "git-fetch-tags",
                                s.git_fetch_tags.clone(),
                                160.0,
                                vec![
                                        (
                                            "inherit",
                                            crate::i18n::menu_text(cx, "git.fetch.tags.inherit")
                                                .to_string(),
                                        ),
                                        (
                                            "all",
                                            crate::i18n::menu_text(cx, "git.fetch.tags.all")
                                                .to_string(),
                                        ),
                                        (
                                            "none",
                                            crate::i18n::menu_text(cx, "git.fetch.tags.none")
                                                .to_string(),
                                        ),
                                        (
                                            "prune",
                                            crate::i18n::menu_text(cx, "git.fetch.tags.prune")
                                                .to_string(),
                                        ),
                                    ],
                                cx,
                                |this, value, cx| {
                                    this.commit(cx, |s| s.git_fetch_tags = value.to_string())
                                },
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.git.execution").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.executable").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.executableDescription",
                                    )
                                    .to_string(),
                                ),
                                h_flex()
                                    .gap_1p5()
                                    .child(Self::render_text_input(exe_entity))
                                    .child(
                                        Button::new("git-exe-detect")
                                            .small()
                                            .ghost()
                                            .label(
                                                crate::i18n::menu_text(cx, "settings.git.detect")
                                                    .to_string(),
                                            )
                                            .on_click(cx.listener(move |_this, _e, window, cx| {
                                                if let Some(found) = which("git") {
                                                    exe_for_detect.update(cx, |st, cx| {
                                                        st.set_value(found, window, cx);
                                                    });
                                                }
                                            })),
                                    )
                                    .child(
                                        Button::new("git-exe-clear")
                                            .small()
                                            .ghost()
                                            .icon(IconName::Close)
                                            .on_click(cx.listener(move |_this, _e, window, cx| {
                                                exe_for_clear.update(cx, |st, cx| {
                                                    st.set_value("", window, cx);
                                                });
                                            })),
                                    )
                                    .child(
                                        Button::new("git-exe-apply")
                                            .small()
                                            .primary()
                                            .label(
                                                crate::i18n::menu_text(cx, "settings.mac.apply")
                                                    .to_string(),
                                            )
                                            .on_click(cx.listener(move |this, _e, _w, cx| {
                                                let value = exe_for_save
                                                    .read(cx)
                                                    .value()
                                                    .to_string()
                                                    .trim()
                                                    .to_string();
                                                this.commit(cx, |s| s.git_executable = value);
                                            })),
                                    ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.useCredentialHelper")
                                    .to_string(),
                                None,
                                self.render_toggle(
                                    "git-use-credential-helper",
                                    s.git_use_credential_helper,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.git_use_credential_helper =
                                                !s.git_use_credential_helper
                                        })
                                    },
                                ),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.git.integration").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.gitIntegration")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.gitIntegrationDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-integration",
                                    s.core_features.git,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.core_features.git = !s.core_features.git
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.autoRefresh").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.autoRefreshDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-auto-refresh",
                                    s.auto_refresh_git_status,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.auto_refresh_git_status = !s.auto_refresh_git_status
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.confirmDiscard")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.confirmDiscardDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-confirm-discard",
                                    s.confirm_before_discard,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.confirm_before_discard = !s.confirm_before_discard
                                        })
                                    },
                                ),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.git.view").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.folderChanges")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.folderChangesDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-folder-changes",
                                    s.git_changes_folder_view,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.git_changes_folder_view = !s.git_changes_folder_view
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.untracked").to_string(),
                                Some(
                                    crate::i18n::menu_text(cx, "settings.git.untrackedDescription")
                                        .to_string()
                                        .to_string(),
                                ),
                                self.render_toggle(
                                    "git-show-untracked",
                                    s.show_untracked_files,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.show_untracked_files = !s.show_untracked_files
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.stagedFirst").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.stagedFirstDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-show-staged-first",
                                    s.show_staged_first,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.show_staged_first = !s.show_staged_first
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.openDiff").to_string(),
                                Some(
                                    crate::i18n::menu_text(cx, "settings.git.openDiffDescription")
                                        .to_string()
                                        .to_string(),
                                ),
                                self.render_toggle(
                                    "git-open-diff-on-click",
                                    s.open_diff_on_click,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.open_diff_on_click = !s.open_diff_on_click
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.compactBadges")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.compactBadgesDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-compact-badges",
                                    s.compact_git_status_badges,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.compact_git_status_badges =
                                                !s.compact_git_status_badges
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.collapseEmpty")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.collapseEmptyDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-collapse-empty",
                                    s.collapse_empty_git_sections,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.collapse_empty_git_sections =
                                                !s.collapse_empty_git_sections
                                        })
                                    },
                                ),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.git.rememberPanel")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.git.rememberPanelDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_toggle(
                                    "git-remember-panel",
                                    s.remember_last_git_panel_mode,
                                    cx,
                                    |this, cx| {
                                        this.commit(cx, |s| {
                                            s.remember_last_git_panel_mode =
                                                !s.remember_last_git_panel_mode
                                        })
                                    },
                                ),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.git.defaultDiff").to_string(),
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            crate::i18n::menu_text(cx, "settings.git.defaultDiff").to_string(),
                            Some(
                                crate::i18n::menu_text(cx, "settings.git.defaultDiffDescription")
                                    .to_string()
                                    .to_string(),
                            ),
                            self.render_dropdown(
                                "git-default-diff-view",
                                s.git_default_diff_view.clone(),
                                160.0,
                                vec![
                                    (
                                        "unified",
                                        crate::i18n::menu_text(cx, "settings.git.unified")
                                            .to_string(),
                                    ),
                                    (
                                        "split",
                                        crate::i18n::menu_text(cx, "settings.git.split")
                                            .to_string(),
                                    ),
                                ],
                                cx,
                                |this, value, cx| {
                                    this.commit(cx, |s| s.git_default_diff_view = value.to_string())
                                },
                            ),
                        ),
                    ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.git.editor").to_string(),
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            crate::i18n::menu_text(cx, "settings.git.inlineBlame").to_string(),
                            Some(
                                crate::i18n::menu_text(cx, "settings.git.inlineBlameDescription")
                                    .to_string()
                                    .to_string(),
                            ),
                            self.render_toggle(
                                "git-inline-blame",
                                s.enable_inline_git_blame,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.enable_inline_git_blame = !s.enable_inline_git_blame
                                    })
                                },
                            ),
                        ),
                    ),
                ),
            )
    }

    /// 日志：对齐 Tauri `LogSettingsPanel`（日志位置/诊断/保留策略/诊断包）。
    /// 自定义目录落盘；清理删除目录下 `*.log`；导出写 `diagnostic-bundle.json`。
    fn render_logs_content(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let s = settings::get(cx).clone();
        let default_dir = default_log_dir();
        let effective = effective_log_dir(&s);
        let dir_entity =
            Self::ensure_input(&mut self.log_dir_input, &s.custom_log_directory, window, cx);
        let dir_for_choose = dir_entity.clone();
        let dir_for_clear = dir_entity.clone();
        let dir_for_save = dir_entity.clone();
        let status = self.logs_status.clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.logs.locations").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.logs.effectivePath")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.logs.effectivePathDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_value(effective),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.logs.defaultPath").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.logs.defaultPathDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_value(default_dir),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.logs.customPath").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.logs.customPathDescription",
                                    )
                                    .to_string(),
                                ),
                                h_flex()
                                    .gap_1p5()
                                    .child(Self::render_text_input(dir_entity))
                                    .child(
                                        Button::new("logs-choose-dir")
                                            .small()
                                            .ghost()
                                            .label(
                                                crate::i18n::menu_text(cx, "settings.logs.choose")
                                                    .to_string(),
                                            )
                                            .on_click(cx.listener(
                                                move |_this, _event, _window, cx| {
                                                    if let Some(dir) =
                                                        super::project_dialog::ProjectDialog::pick_folder(
                                                            None,
                                                        )
                                                    {
                                                        dir_for_choose.update(cx, |st, cx| {
                                                            st.set_value(dir, _window, cx);
                                                        });
                                                    }
                                                },
                                            )),
                                    )
                                    .child(
                                        Button::new("logs-dir-apply")
                                            .small()
                                            .primary()
                                            .label(
                                                crate::i18n::menu_text(cx, "settings.mac.apply")
                                                    .to_string(),
                                            )
                                            .on_click(cx.listener(move |this, _e, _w, cx| {
                                                let value = dir_for_save
                                                    .read(cx)
                                                    .value()
                                                    .to_string()
                                                    .trim()
                                                    .to_string();
                                                this.commit(cx, |s| s.custom_log_directory = value);
                                            })),
                                    ),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.logs.diagnostics").to_string(),
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            crate::i18n::menu_text(cx, "settings.logs.diagnosticMode").to_string(),
                            Some(
                                crate::i18n::menu_text(
                                    cx,
                                    "settings.logs.diagnosticModeDescription",
                                )
                                .to_string(),
                            ),
                            self.render_toggle(
                                "logs-diagnostic-mode",
                                self.diagnostic_mode,
                                cx,
                                |this, cx| {
                                    this.diagnostic_mode = !this.diagnostic_mode;
                                    cx.notify();
                                },
                            ),
                        ),
                    ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.logs.retention").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_note(
                                crate::i18n::menu_text(cx, "settings.logs.retentionDescription")
                                    .to_string(),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.logs.clearCurrent")
                                    .to_string()
                                    .to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.logs.clearCurrentDescription",
                                    )
                                    .to_string(),
                                ),
                                Button::new("logs-clear")
                                    .small()
                                    .ghost()
                                    .label(
                                        crate::i18n::menu_text(cx, "settings.logs.clear")
                                            .to_string(),
                                    )
                                    .on_click(cx.listener(move |this, _e, _w, cx| {
                                        let dir = dir_for_clear
                                            .read(cx)
                                            .value()
                                            .to_string()
                                            .trim()
                                            .to_string();
                                        let dir =
                                            if dir.is_empty() { default_log_dir() } else { dir };
                                        let removed = std::fs::read_dir(&dir)
                                            .map(|entries| {
                                                entries
                                                    .filter_map(|e| e.ok())
                                                    .filter(|e| {
                                                        e.path()
                                                            .extension()
                                                            .is_some_and(|ext| ext == "log")
                                                    })
                                                    .filter(|e| std::fs::remove_file(e.path()).is_ok())
                                                    .count()
                                            })
                                            .unwrap_or(0);
                                        this.logs_status =
                                            format!("已清理 {removed} 个日志文件");
                                        cx.notify();
                                    })),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.logs.diagnosticBundle").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.logs.exportBundle").to_string(),
                                None,
                                Button::new("logs-export-bundle")
                                    .small()
                                    .ghost()
                                    .label(crate::i18n::menu_text(
                                        cx,
                                        "settings.logs.exportBundleConfirm",
                                    ))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        let settings_text =
                                            serde_json::to_string_pretty(settings::get(cx))
                                                .unwrap_or_else(|_| "{}".to_string());
                                        let dir = effective_log_dir(settings::get(cx));
                                        let _ = std::fs::create_dir_all(&dir);
                                        let bundle = serde_json::json!({
                                            "exportedAt": std::time::SystemTime::now()
                                                .duration_since(std::time::UNIX_EPOCH)
                                                .map(|d| d.as_secs())
                                                .unwrap_or(0),
                                            "version": env!("CARGO_PKG_VERSION"),
                                            "settings": serde_json::from_str::<serde_json::Value>(
                                                &settings_text,
                                            )
                                            .unwrap_or(serde_json::Value::Null),
                                        });
                                        let path = std::path::Path::new(&dir)
                                            .join("diagnostic-bundle.json");
                                        let ok = serde_json::to_string_pretty(&bundle)
                                            .ok()
                                            .and_then(|text| {
                                                std::fs::write(&path, text).ok()
                                            })
                                            .is_some();
                                        this.logs_status = if ok {
                                            format!(
                                                "已导出到 {}",
                                                path.to_string_lossy()
                                            )
                                        } else {
                                            "导出失败".to_string()
                                        };
                                        cx.notify();
                                    })),
                            ),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(ThemeColors::subtle_foreground())
                                .child(status),
                        ),
                ),
            )
    }

    /// 更新：对齐 Tauri `UpdatesPanel`（软件更新/版本/检查按钮/状态文案）。
    /// Linux 无内置更新器：检查按钮读取当前版本并报告已是最新。
    fn render_updates_content(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let status = self.updates_status.clone();
        v_flex().w_full().gap_4().child(
            self.render_group(
                crate::i18n::menu_text(cx, "settings.mac.softwareUpdate").to_string(),
                v_flex()
                    .w_full()
                    .gap_3()
                    .child(
                        self.render_row(
                            "Lithe".to_string(),
                            Some(
                                crate::i18n::menu_text(cx, "settings.mac.currentVersion")
                                    .to_string()
                                    .replace("{version}", env!("CARGO_PKG_VERSION")),
                            ),
                            Button::new("check-updates")
                                .small()
                                .primary()
                                .label(
                                    crate::i18n::menu_text(cx, "settings.mac.checkForUpdates")
                                        .to_string(),
                                )
                                .on_click(cx.listener(|this, _event, _window, cx| {
                                    this.updates_status = format!(
                                        "{} v{}",
                                        crate::i18n::menu_text(cx, "settings.mac.upToDate"),
                                        env!("CARGO_PKG_VERSION"),
                                    );
                                    cx.notify();
                                })),
                        ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::subtle_foreground())
                            .child(if status.is_empty() {
                                crate::i18n::menu_text(cx, "settings.mac.updateHint").to_string()
                            } else {
                                status
                            }),
                    ),
            ),
        )
    }
}

/// 默认日志目录：配置数据目录下的 `lithe/logs`。
///
/// 数据目录的平台规则（XDG / `%LOCALAPPDATA%`）见 `settings::data_dir`。
fn default_log_dir() -> String {
    crate::settings::data_dir()
        .map(|base| {
            base.join("lithe")
                .join("logs")
                .to_string_lossy()
                .to_string()
        })
        .unwrap_or_else(|| "lithe/logs".to_string())
}

/// 生效日志目录：自定义目录非空即用，否则默认目录。
fn effective_log_dir(settings: &Settings) -> String {
    if settings.custom_log_directory.trim().is_empty() {
        default_log_dir()
    } else {
        settings.custom_log_directory.clone()
    }
}

/// `PATH` 中查找可执行文件，返回首个命中绝对路径（对齐 Mac `which` 探测思路）。
///
/// Windows 上同名程序带扩展名（`java` -> `java.exe`），因此按 `PATHEXT`
/// 补全候选；Unix 要求执行位。两平台都只返回存在的绝对路径。
fn which(exe: &str) -> Option<String> {
    let paths = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&paths) {
        for candidate in executable_candidates(&dir, exe) {
            if !candidate.is_file() {
                continue;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                if let Ok(meta) = std::fs::metadata(&candidate) {
                    if meta.permissions().mode() & 0o111 != 0 {
                        return Some(candidate.to_string_lossy().to_string());
                    }
                }
            }
            #[cfg(not(unix))]
            {
                return Some(candidate.to_string_lossy().to_string());
            }
        }
    }
    None
}

/// 列出在 `dir` 下应该尝试的可执行文件名。
///
/// Windows 上按 `PATHEXT`（缺省 ` .COM;.EXE;.BAT;.CMD`）补全；名字已带
/// 扩展名或非 Windows 平台时只尝试原名。
fn executable_candidates(dir: &std::path::Path, name: &str) -> Vec<std::path::PathBuf> {
    #[cfg(windows)]
    {
        let mut candidates = vec![dir.join(name)];
        if std::path::Path::new(name).extension().is_none() {
            let pathext = std::env::var("PATHEXT")
                .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
            for extension in pathext.split(';').filter(|value| !value.is_empty()) {
                candidates.push(dir.join(format!("{name}{extension}")));
            }
        }
        candidates
    }
    #[cfg(not(windows))]
    {
        vec![dir.join(name)]
    }
}

fn which_java_home() -> Option<String> {
    let executable = which("java")?;
    let path = std::fs::canonicalize(&executable)
        .unwrap_or_else(|_| std::path::PathBuf::from(&executable));
    path.parent()
        .and_then(std::path::Path::parent)
        .map(|home| home.to_string_lossy().into_owned())
}

/// 当前可用 shell 探测：仅收录真实存在的系统 shell。
///
/// Unix 检查常见路径或 `PATH`；Windows 上没有 bash/zsh/fish，默认 shell 由
/// 系统决定（PowerShell/cmd），因此返回空列表，让上层保留“系统默认”选项。
fn detect_available_shells() -> Vec<String> {
    #[cfg(unix)]
    {
        let mut shells = Vec::new();
        for name in ["bash", "zsh", "fish", "sh", "dash"] {
            let found = ["/bin", "/usr/bin"]
                .iter()
                .any(|dir| std::path::Path::new(dir).join(name).is_file());
            if found || which(name).is_some() {
                shells.push(name.to_string());
            }
        }
        shells
    }
    #[cfg(not(unix))]
    {
        Vec::new()
    }
}

/// 读项目工具链；canonical 键优先，兼容历史 Linux 扁平键。
fn read_local_toolchain(workspace_root: &str) -> (String, String, String) {
    let paths = read_toolchain_paths(workspace_root);
    (
        paths.java_home_path,
        paths.maven_executable_path,
        paths.maven_java_home_path,
    )
}

/// 写项目工具链；使用 canonical 键并保留 local.json 其它配置。
fn write_local_toolchain(workspace_root: &str, jdk: &str, maven: &str, maven_jdk: &str) -> bool {
    write_toolchain_paths(
        workspace_root,
        &ToolchainPaths {
            java_home_path: jdk.to_string(),
            maven_executable_path: maven.to_string(),
            maven_java_home_path: maven_jdk.to_string(),
            ..ToolchainPaths::default()
        },
    )
    .is_ok()
}
