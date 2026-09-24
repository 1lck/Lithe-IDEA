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
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, Context, EventEmitter, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::settings::{self, Settings};
use crate::theme::ThemeColors;

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

    /// 中文标题，展示在导航项与内容区标题。
    pub fn title(self) -> &'static str {
        match self {
            SettingsCategory::General => "通用",
            SettingsCategory::Project => "项目",
            SettingsCategory::Run => "运行",
            SettingsCategory::Editor => "编辑器",
            SettingsCategory::Keyboard => "快捷键",
            SettingsCategory::Terminal => "终端",
            SettingsCategory::Lsp => "语言服务",
            SettingsCategory::Ai => "AI 助手",
            SettingsCategory::AiCommit => "AI 提交",
            SettingsCategory::Git => "版本控制",
            SettingsCategory::Logs => "日志",
            SettingsCategory::Updates => "更新",
        }
    }

    /// 导航图标；只使用 `IconName` 中确定存在的变体。
    pub fn icon(self) -> IconName {
        match self {
            SettingsCategory::General => IconName::SlidersHorizontal,
            SettingsCategory::Project => IconName::Folder,
            SettingsCategory::Run => IconName::Play,
            SettingsCategory::Editor => IconName::Code,
            SettingsCategory::Keyboard => IconName::Keyboard,
            SettingsCategory::Terminal => IconName::Terminal,
            SettingsCategory::Lsp => IconName::Database,
            SettingsCategory::Ai => IconName::Bot,
            SettingsCategory::AiCommit => IconName::Bot,
            SettingsCategory::Git => IconName::GitBranch,
            SettingsCategory::Logs => IconName::FileText,
            SettingsCategory::Updates => IconName::RotateCw,
        }
    }

    /// 由持久化的 `lastSettingsTab` 反解分类；`language` 归到 LSP，未知值回退通用。
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

/// 对话框对外事件：关闭，以及设置已变更（宿主可据此同步其它视图）。
#[derive(Debug, Clone)]
pub enum SettingsEvent {
    Close,
    Changed,
}

/// 居中设置面板（宽 820px，高 620px）。
pub struct SettingsDialog {
    /// 当前激活分类
    pub active_category: SettingsCategory,
    /// 当前工作区根路径，Project 分类只读展示
    workspace_root: String,
    // 以下字段对应 Tauri 设置但 Linux `Settings` 尚未提供，暂作对话框本地占位。
    open_folders_in_new_window: bool,
    keybinding_preset: String,
    vim_mode: bool,
    vim_relative_line_numbers: bool,
    terminal_cursor_style: String,
    lsp_auto_completion: bool,
    lsp_parameter_hints: bool,
    auto_refresh_git_status: bool,
    show_untracked_files: bool,
    show_staged_first: bool,
    git_default_diff_view: String,
    enable_inline_git_blame: bool,
    log_level: String,
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
            open_folders_in_new_window: true,
            keybinding_preset: "none".to_string(),
            vim_mode: false,
            vim_relative_line_numbers: false,
            terminal_cursor_style: "bar".to_string(),
            lsp_auto_completion: true,
            lsp_parameter_hints: true,
            auto_refresh_git_status: true,
            show_untracked_files: true,
            show_staged_first: true,
            git_default_diff_view: "unified".to_string(),
            enable_inline_git_blame: true,
            log_level: "info".to_string(),
        }
    }

    /// 切换分类并把 `lastSettingsTab` 写回磁盘，保证下次打开停在同一页。
    pub fn set_category(&mut self, cat: SettingsCategory, cx: &mut Context<Self>) {
        self.active_category = cat;
        settings::update(cx, |s| s.last_settings_tab = cat.id().to_string());
        cx.notify();
    }

    /// 打开对话框时按持久化的 `lastSettingsTab` 重置分类。
    pub fn open(&mut self, cx: &mut Context<Self>) {
        self.active_category = SettingsCategory::from_id(&settings::get(cx).last_settings_tab);
        cx.notify();
    }

    /// 恢复占位项的本地默认值（不涉及持久化）。
    fn reset_placeholders(&mut self) {
        self.open_folders_in_new_window = true;
        self.keybinding_preset = "none".to_string();
        self.vim_mode = false;
        self.vim_relative_line_numbers = false;
        self.terminal_cursor_style = "bar".to_string();
        self.lsp_auto_completion = true;
        self.lsp_parameter_hints = true;
        self.auto_refresh_git_status = true;
        self.show_untracked_files = true;
        self.show_staged_first = true;
        self.git_default_diff_view = "unified".to_string();
        self.enable_inline_git_blame = true;
        self.log_level = "info".to_string();
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
}

impl Render for SettingsDialog {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
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
                                            .child("Settings"),
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
                                            .child("搜索设置"),
                                    ),
                            )
                            .child(
                                Button::new("settings-close")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Close)
                                    .tooltip("Close")
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
                                                    .child(self.active_category.title()),
                                            )
                                            .child(match self.active_category {
                                                SettingsCategory::General => self
                                                    .render_general_content(cx)
                                                    .into_any_element(),
                                                SettingsCategory::Project => self
                                                    .render_project_content(cx)
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
                                                SettingsCategory::Ai => {
                                                    self.render_ai_content(cx).into_any_element()
                                                }
                                                SettingsCategory::AiCommit => self
                                                    .render_ai_commit_content(cx)
                                                    .into_any_element(),
                                                SettingsCategory::Git => {
                                                    self.render_git_content(cx).into_any_element()
                                                }
                                                SettingsCategory::Logs => {
                                                    self.render_logs_content(cx).into_any_element()
                                                }
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
                                    .label("Restore Defaults")
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
                                    .label("Done")
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(SettingsEvent::Close);
                                    })),
                            ),
                    ),
            )
    }
}

/// 通用渲染块：分组、行、控件与分类内容。
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
            .child(cat.title())
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.set_category(cat, cx);
            }))
    }

    /// 分组容器：标题条 + 内容区，对应 Tauri `SettingsGroup`。
    fn render_group(&self, title: &'static str, content: impl IntoElement) -> impl IntoElement {
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

    /// 设置行：左侧标签与描述，右侧控件。
    fn render_row(
        &self,
        label: &'static str,
        description: Option<&'static str>,
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

    /// 开关控件：可点击药丸，On/Off 两种状态。
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
            .child(if value { "On" } else { "Off" })
            .on_click(cx.listener(move |this, _event, _window, cx| toggle(this, cx)))
    }

    /// 单选项：分段药丸，选中态用 primary 背景。
    fn render_segment(
        &self,
        id: &'static str,
        label: &'static str,
        selected: bool,
        cx: &mut Context<Self>,
        on_select: impl Fn(&mut Self, &mut Context<Self>) + 'static,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .items_center()
            .justify_center()
            .px_2p5()
            .py_1()
            .rounded_sm()
            .border_1()
            .cursor_pointer()
            .text_xs()
            .when(selected, |el| {
                el.bg(ThemeColors::primary())
                    .border_color(ThemeColors::primary())
                    .text_color(ThemeColors::foreground())
                    .font_weight(FontWeight::MEDIUM)
            })
            .when(!selected, |el| {
                el.bg(ThemeColors::background())
                    .border_color(ThemeColors::border())
                    .text_color(ThemeColors::subtle_foreground())
                    .hover(|h| {
                        h.bg(ThemeColors::accent())
                            .text_color(ThemeColors::foreground())
                    })
            })
            .child(label)
            .on_click(cx.listener(move |this, _event, _window, cx| on_select(this, cx)))
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

    /// 键位徽标：Keyboard 分类展示用，点击不触发录制。
    fn render_key_badge(&self, label: &'static str) -> impl IntoElement {
        div()
            .px_2()
            .py_0p5()
            .rounded_sm()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::background())
            .text_xs()
            .text_color(ThemeColors::muted_foreground())
            .child(label)
    }

    /// 占位空态：图标 + 说明。
    fn render_empty_state(&self, icon: IconName, text: &'static str) -> impl IntoElement {
        v_flex()
            .w_full()
            .items_center()
            .justify_center()
            .gap_2()
            .py_8()
            .child(
                Icon::new(icon)
                    .size(px(28.0))
                    .text_color(ThemeColors::subtle_foreground()),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(ThemeColors::subtle_foreground())
                    .child(text),
            )
    }

    /// 分组内的说明文本。
    fn render_note(&self, text: &'static str) -> impl IntoElement {
        div()
            .text_xs()
            .text_color(ThemeColors::subtle_foreground())
            .child(text)
    }
}

/// 各分类内容渲染。
impl SettingsDialog {
    fn render_general_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "外观",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                "主题",
                                Some("编辑器与工作台的配色方案"),
                                h_flex()
                                    .gap_1p5()
                                    .child(self.render_segment(
                                        "theme-dark",
                                        "深色",
                                        s.theme == "lithe-dark",
                                        cx,
                                        |this, cx| {
                                            this.commit_theme(cx, |s| {
                                                s.theme = "lithe-dark".to_string()
                                            })
                                        },
                                    ))
                                    .child(self.render_segment(
                                        "theme-light",
                                        "浅色",
                                        s.theme == "lithe-light",
                                        cx,
                                        |this, cx| {
                                            this.commit_theme(cx, |s| {
                                                s.theme = "lithe-light".to_string()
                                            })
                                        },
                                    )),
                            ),
                        )
                        .child(self.render_row(
                            "跟随系统主题",
                            Some("按系统外观在浅色与深色主题间自动切换"),
                            self.render_toggle(
                                "sync-system-theme",
                                s.sync_system_theme,
                                cx,
                                |this, cx| {
                                    this.commit_theme(cx, |s| {
                                        s.sync_system_theme = !s.sync_system_theme
                                    })
                                },
                            ),
                        ))
                        .child(
                            self.render_row(
                                "窗口密度",
                                Some("标题栏与工具栏的紧凑程度"),
                                h_flex()
                                    .gap_1p5()
                                    .child(self.render_segment(
                                        "chrome-focused",
                                        "聚焦",
                                        s.window_chrome_density == "focused",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.window_chrome_density = "focused".to_string()
                                            })
                                        },
                                    ))
                                    .child(self.render_segment(
                                        "chrome-comfortable",
                                        "舒适",
                                        s.window_chrome_density == "comfortable",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.window_chrome_density = "comfortable".to_string()
                                            })
                                        },
                                    )),
                            ),
                        )
                        .child(self.render_row(
                            "减少动画",
                            Some("关闭过渡与动画以降低干扰"),
                            self.render_toggle("reduce-motion", s.reduce_motion, cx, |this, cx| {
                                this.commit(cx, |s| s.reduce_motion = !s.reduce_motion)
                            }),
                        ))
                        .child(self.render_row(
                            "紧凑菜单栏",
                            None,
                            self.render_toggle(
                                "compact-menu-bar",
                                s.compact_menu_bar,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.compact_menu_bar = !s.compact_menu_bar)
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "显示状态栏",
                            None,
                            self.render_toggle(
                                "show-status-bar",
                                s.show_status_bar,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.show_status_bar = !s.show_status_bar)
                                },
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "文件与语言",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "自动保存",
                            Some("编辑停止后自动保存当前文件"),
                            self.render_toggle("auto-save", s.auto_save, cx, |this, cx| {
                                this.commit(cx, |s| s.auto_save = !s.auto_save)
                            }),
                        ))
                        .child(self.render_row(
                            "快速打开预览",
                            Some("快速打开时以预览方式打开文件"),
                            self.render_toggle(
                                "quick-open-preview",
                                s.quick_open_preview,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.quick_open_preview = !s.quick_open_preview
                                    })
                                },
                            ),
                        ))
                        .child(
                            self.render_row(
                                "显示语言",
                                None,
                                h_flex()
                                    .gap_1p5()
                                    .child(self.render_segment(
                                        "lang-en",
                                        "English",
                                        s.display_language == "en-US",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.display_language = "en-US".to_string()
                                            })
                                        },
                                    ))
                                    .child(self.render_segment(
                                        "lang-zh",
                                        "简体中文",
                                        s.display_language == "zh-CN",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.display_language = "zh-CN".to_string()
                                            })
                                        },
                                    )),
                            ),
                        ),
                ),
            )
    }

    fn render_project_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(self.render_group(
                "当前工作区",
                v_flex().w_full().gap_3().child(self.render_row(
                    "工作区路径",
                    Some("当前打开项目的根目录（只读）"),
                    self.render_value(self.workspace_root.clone()),
                )),
            ))
            .child(self.render_group(
                "项目打开方式",
                v_flex().w_full().gap_3().child(self.render_row(
                    "在新窗口打开文件夹",
                    Some("占位项：Linux Settings 尚未提供该字段，暂不落盘"),
                    self.render_toggle(
                        "open-folders-in-new-window",
                        self.open_folders_in_new_window,
                        cx,
                        |this, cx| {
                            this.open_folders_in_new_window = !this.open_folders_in_new_window;
                            cx.notify();
                        },
                    ),
                )),
            ))
    }

    fn render_run_content(&self, _cx: &mut Context<Self>) -> impl IntoElement {
        v_flex().w_full().gap_4().child(self.render_group(
            "运行配置",
            v_flex().w_full().gap_3().child(
                self.render_empty_state(IconName::Play, "暂无运行配置，创建后可在此管理启动项"),
            ),
        ))
    }

    fn render_editor_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "显示",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "字号",
                            Some("编辑器代码字号（11–20 px）"),
                            self.render_stepper(
                                "font-dec",
                                "font-inc",
                                format!("{} px", s.font_size as i32),
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.font_size = (s.font_size - 1.0).max(11.0))
                                },
                                |this, cx| {
                                    this.commit(cx, |s| s.font_size = (s.font_size + 1.0).min(20.0))
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "显示行号",
                            None,
                            self.render_toggle(
                                "editor-line-numbers",
                                s.line_numbers,
                                cx,
                                |this, cx| this.commit(cx, |s| s.line_numbers = !s.line_numbers),
                            ),
                        ))
                        .child(self.render_row(
                            "自动换行",
                            None,
                            self.render_toggle("editor-word-wrap", s.word_wrap, cx, |this, cx| {
                                this.commit(cx, |s| s.word_wrap = !s.word_wrap)
                            }),
                        ))
                        .child(self.render_row(
                            "显示缩略图",
                            None,
                            self.render_toggle("editor-minimap", s.show_minimap, cx, |this, cx| {
                                this.commit(cx, |s| s.show_minimap = !s.show_minimap)
                            }),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "标签页",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "显示标签图标",
                            None,
                            self.render_toggle(
                                "editor-tab-icons",
                                s.show_tab_icons,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.show_tab_icons = !s.show_tab_icons)
                                },
                            ),
                        ))
                        .child(
                            self.render_row(
                                "关闭按钮显示",
                                Some("标签页关闭按钮的显示时机"),
                                h_flex()
                                    .gap_1p5()
                                    .child(self.render_segment(
                                        "close-active",
                                        "活动时",
                                        s.tab_close_button_visibility == "active",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.tab_close_button_visibility = "active".to_string()
                                            })
                                        },
                                    ))
                                    .child(self.render_segment(
                                        "close-hover",
                                        "悬停时",
                                        s.tab_close_button_visibility == "hover",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.tab_close_button_visibility = "hover".to_string()
                                            })
                                        },
                                    ))
                                    .child(self.render_segment(
                                        "close-always",
                                        "始终",
                                        s.tab_close_button_visibility == "always",
                                        cx,
                                        |this, cx| {
                                            this.commit(cx, |s| {
                                                s.tab_close_button_visibility = "always".to_string()
                                            })
                                        },
                                    )),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    "缩进",
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            "Tab 宽度",
                            None,
                            h_flex()
                                .gap_1p5()
                                .child(self.render_segment(
                                    "tab-size-2",
                                    "2 空格",
                                    s.tab_size == 2,
                                    cx,
                                    |this, cx| this.commit(cx, |s| s.tab_size = 2),
                                ))
                                .child(self.render_segment(
                                    "tab-size-4",
                                    "4 空格",
                                    s.tab_size == 4,
                                    cx,
                                    |this, cx| this.commit(cx, |s| s.tab_size = 4),
                                ))
                                .child(self.render_segment(
                                    "tab-size-8",
                                    "8 空格",
                                    s.tab_size == 8,
                                    cx,
                                    |this, cx| this.commit(cx, |s| s.tab_size = 8),
                                )),
                        ),
                    ),
                ),
            )
    }

    fn render_keyboard_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "按键映射",
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            "预设",
                            Some("占位项：Linux Settings 尚未提供该字段，暂不落盘"),
                            h_flex()
                                .gap_1p5()
                                .child(self.render_segment(
                                    "keymap-none",
                                    "Lithe",
                                    self.keybinding_preset == "none",
                                    cx,
                                    |this, cx| {
                                        this.keybinding_preset = "none".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "keymap-vscode",
                                    "VS Code",
                                    self.keybinding_preset == "vscode",
                                    cx,
                                    |this, cx| {
                                        this.keybinding_preset = "vscode".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "keymap-intellij",
                                    "IntelliJ",
                                    self.keybinding_preset == "intellij",
                                    cx,
                                    |this, cx| {
                                        this.keybinding_preset = "intellij".to_string();
                                        cx.notify();
                                    },
                                )),
                        ),
                    ),
                ),
            )
            .child(
                self.render_group(
                    "Vim",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "启用 Vim 模式",
                            None,
                            self.render_toggle("vim-mode", self.vim_mode, cx, |this, cx| {
                                this.vim_mode = !this.vim_mode;
                                cx.notify();
                            }),
                        ))
                        .child(self.render_row(
                            "相对行号",
                            None,
                            self.render_toggle(
                                "vim-relative-line-numbers",
                                self.vim_relative_line_numbers,
                                cx,
                                |this, cx| {
                                    this.vim_relative_line_numbers =
                                        !this.vim_relative_line_numbers;
                                    cx.notify();
                                },
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "快捷键",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row("保存文件", None, self.render_key_badge("Ctrl S")))
                        .child(self.render_row("快速打开", None, self.render_key_badge("Ctrl P")))
                        .child(self.render_row(
                            "全局搜索",
                            None,
                            self.render_key_badge("Ctrl Shift F"),
                        ))
                        .child(self.render_row("打开设置", None, self.render_key_badge("Ctrl ,")))
                        .child(self.render_note("快捷键表为只读占位，暂不支持点击录制。")),
                ),
            )
    }

    fn render_terminal_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "回滚缓冲",
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            "缓冲行数",
                            Some("终端保留的最大输出行数"),
                            h_flex()
                                .gap_1p5()
                                .child(self.render_segment(
                                    "scrollback-1000",
                                    "1000",
                                    s.terminal_scrollback == 1000,
                                    cx,
                                    |this, cx| this.commit(cx, |s| s.terminal_scrollback = 1000),
                                ))
                                .child(self.render_segment(
                                    "scrollback-5000",
                                    "5000",
                                    s.terminal_scrollback == 5000,
                                    cx,
                                    |this, cx| this.commit(cx, |s| s.terminal_scrollback = 5000),
                                ))
                                .child(self.render_segment(
                                    "scrollback-10000",
                                    "10000",
                                    s.terminal_scrollback == 10000,
                                    cx,
                                    |this, cx| this.commit(cx, |s| s.terminal_scrollback = 10000),
                                )),
                        ),
                    ),
                ),
            )
            .child(
                self.render_group(
                    "光标",
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            "光标样式",
                            Some("占位项：Linux Settings 尚未提供该字段，暂不落盘"),
                            h_flex()
                                .gap_1p5()
                                .child(self.render_segment(
                                    "cursor-bar",
                                    "竖线",
                                    self.terminal_cursor_style == "bar",
                                    cx,
                                    |this, cx| {
                                        this.terminal_cursor_style = "bar".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "cursor-block",
                                    "方块",
                                    self.terminal_cursor_style == "block",
                                    cx,
                                    |this, cx| {
                                        this.terminal_cursor_style = "block".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "cursor-underline",
                                    "下划线",
                                    self.terminal_cursor_style == "underline",
                                    cx,
                                    |this, cx| {
                                        this.terminal_cursor_style = "underline".to_string();
                                        cx.notify();
                                    },
                                )),
                        ),
                    ),
                ),
            )
    }

    fn render_lsp_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "语言服务",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "自动补全",
                            Some("占位项：Linux Settings 尚未提供该字段，暂不落盘"),
                            self.render_toggle(
                                "lsp-auto-completion",
                                self.lsp_auto_completion,
                                cx,
                                |this, cx| {
                                    this.lsp_auto_completion = !this.lsp_auto_completion;
                                    cx.notify();
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "参数提示",
                            None,
                            self.render_toggle(
                                "lsp-parameter-hints",
                                self.lsp_parameter_hints,
                                cx,
                                |this, cx| {
                                    this.lsp_parameter_hints = !this.lsp_parameter_hints;
                                    cx.notify();
                                },
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "已检测到的服务器",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "Rust",
                            None,
                            self.render_value("rust-analyzer".to_string()),
                        ))
                        .child(self.render_row(
                            "TypeScript",
                            None,
                            self.render_value("typescript-language-server".to_string()),
                        ))
                        .child(self.render_row(
                            "Java",
                            None,
                            self.render_value("jdtls".to_string()),
                        )),
                ),
            )
    }

    fn render_ai_content(&self, _cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "模型",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "提供方",
                            Some("来自默认设置，占位展示"),
                            self.render_value("anthropic".to_string()),
                        ))
                        .child(self.render_row(
                            "模型",
                            None,
                            self.render_value("claude-sonnet-4-6".to_string()),
                        )),
                ),
            )
            .child(self.render_group("说明", self.render_note("AI 助手配置将在后续版本接入。")))
    }

    fn render_ai_commit_content(&self, _cx: &mut Context<Self>) -> impl IntoElement {
        v_flex().w_full().gap_4().child(self.render_group(
            "提交信息生成",
            v_flex().w_full().gap_3().child(
                self.render_empty_state(IconName::Bot, "AI 提交信息生成尚未接入，后续版本提供"),
            ),
        ))
    }

    fn render_git_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "状态",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "自动刷新状态",
                            Some("占位项：Linux Settings 尚未提供该字段，暂不落盘"),
                            self.render_toggle(
                                "git-auto-refresh",
                                self.auto_refresh_git_status,
                                cx,
                                |this, cx| {
                                    this.auto_refresh_git_status = !this.auto_refresh_git_status;
                                    cx.notify();
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "显示未跟踪文件",
                            None,
                            self.render_toggle(
                                "git-show-untracked",
                                self.show_untracked_files,
                                cx,
                                |this, cx| {
                                    this.show_untracked_files = !this.show_untracked_files;
                                    cx.notify();
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "暂存区优先",
                            None,
                            self.render_toggle(
                                "git-show-staged-first",
                                self.show_staged_first,
                                cx,
                                |this, cx| {
                                    this.show_staged_first = !this.show_staged_first;
                                    cx.notify();
                                },
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "差异视图",
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            "默认视图",
                            None,
                            h_flex()
                                .gap_1p5()
                                .child(self.render_segment(
                                    "diff-unified",
                                    "统一",
                                    self.git_default_diff_view == "unified",
                                    cx,
                                    |this, cx| {
                                        this.git_default_diff_view = "unified".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "diff-split",
                                    "分栏",
                                    self.git_default_diff_view == "split",
                                    cx,
                                    |this, cx| {
                                        this.git_default_diff_view = "split".to_string();
                                        cx.notify();
                                    },
                                )),
                        ),
                    ),
                ),
            )
            .child(self.render_group(
                "行内 Blame",
                v_flex().w_full().gap_3().child(self.render_row(
                    "启用行内 Blame",
                    None,
                    self.render_toggle(
                        "git-inline-blame",
                        self.enable_inline_git_blame,
                        cx,
                        |this, cx| {
                            this.enable_inline_git_blame = !this.enable_inline_git_blame;
                            cx.notify();
                        },
                    ),
                )),
            ))
    }

    fn render_logs_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "日志",
                    v_flex().w_full().gap_3().child(
                        self.render_row(
                            "日志级别",
                            Some("占位项：Linux Settings 尚未提供该字段，暂不落盘"),
                            h_flex()
                                .gap_1p5()
                                .child(self.render_segment(
                                    "log-trace",
                                    "TRACE",
                                    self.log_level == "trace",
                                    cx,
                                    |this, cx| {
                                        this.log_level = "trace".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "log-debug",
                                    "DEBUG",
                                    self.log_level == "debug",
                                    cx,
                                    |this, cx| {
                                        this.log_level = "debug".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "log-info",
                                    "INFO",
                                    self.log_level == "info",
                                    cx,
                                    |this, cx| {
                                        this.log_level = "info".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "log-warn",
                                    "WARN",
                                    self.log_level == "warn",
                                    cx,
                                    |this, cx| {
                                        this.log_level = "warn".to_string();
                                        cx.notify();
                                    },
                                ))
                                .child(self.render_segment(
                                    "log-error",
                                    "ERROR",
                                    self.log_level == "error",
                                    cx,
                                    |this, cx| {
                                        this.log_level = "error".to_string();
                                        cx.notify();
                                    },
                                )),
                        ),
                    ),
                ),
            )
            .child(self.render_group("输出", self.render_note("日志会同时输出到终端与日志文件。")))
    }

    fn render_updates_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex().w_full().gap_4().child(
            self.render_group(
                "软件更新",
                v_flex().w_full().gap_3().child(
                    self.render_row(
                        "Lithe",
                        Some("当前版本为占位展示，检查更新尚未接入"),
                        Button::new("check-updates")
                            .small()
                            .primary()
                            .label("检查更新")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                // 占位：仅刷新视图，不发起真实更新检查。
                                cx.notify();
                            })),
                    ),
                ),
            ),
        )
    }
}
