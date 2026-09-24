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
use gpui_kit::component::menu::DropdownMenu as _;
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

    /// 中文标题，与 Tauri `settings-dialog.tsx` 各分类 `labelKey` 的中文翻译逐字对应。
    pub fn title(self) -> &'static str {
        match self {
            SettingsCategory::General => "常规",
            SettingsCategory::Project => "项目 · JDK 与 Maven",
            SettingsCategory::Run => "运行配置",
            SettingsCategory::Editor => "编辑器",
            SettingsCategory::Keyboard => "快捷键",
            SettingsCategory::Terminal => "终端",
            SettingsCategory::Lsp => "LSP",
            SettingsCategory::Ai => "AI 聊天与编辑",
            SettingsCategory::AiCommit => "AI 与提交",
            SettingsCategory::Git => "Git",
            SettingsCategory::Logs => "日志",
            SettingsCategory::Updates => "更新",
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
    /// Git 本地更改保护策略（对齐 Tauri `GeneralPanel` 的本地 `gitPolicy` state，暂不落盘）
    git_policy: String,
    /// 本次会话诊断日志开关（对齐 Tauri 日志面板的会话级状态，重启恢复默认）
    diagnostic_mode: bool,
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

    /// 恢复本地占位项的默认值（不涉及持久化）。
    fn reset_placeholders(&mut self) {
        self.git_policy = "ask".to_string();
        self.diagnostic_mode = false;
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
    /// `options` 为 (值, 展示文本) 对，按钮显示当前值对应的展示文本，选中项打勾。
    fn render_dropdown(
        &self,
        id: &'static str,
        current: String,
        width: f32,
        options: &'static [(&'static str, &'static str)],
        cx: &mut Context<Self>,
        on_select: impl Fn(&mut Self, &'static str, &mut Context<Self>) + 'static,
    ) -> impl IntoElement {
        let view = cx.entity();
        let on_select = std::rc::Rc::new(on_select);
        // 按钮展示当前值对应的展示文本（对齐原生 select 显示 label 的行为）。
        let current_label = options
            .iter()
            .find(|(value, _)| *value == current.as_str())
            .map(|(_, label)| label.to_string())
            .unwrap_or(current.clone());
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
                for (value, label) in options {
                    let v = view.clone();
                    let select = on_select.clone();
                    let selected = *value == current.as_str();
                    let item = gpui_kit::component::menu::PopupMenuItem::new(*label);
                    let item = if selected {
                        item.icon(IconName::Check)
                    } else {
                        item
                    };
                    menu = menu.item(item.on_click(move |_, _, cx| {
                        v.update(cx, |this, cx| select(this, *value, cx));
                    }));
                }
                menu
            })
    }

    /// 多行只读文本块：隐藏路径等模式列表展示用（编辑能力后续接入）。
    fn render_text_block(&self, text: String, min_height: f32) -> impl IntoElement {
        div()
            .w_full()
            .min_h(px(min_height))
            .p_2()
            .rounded_sm()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::background())
            .font_family("monospace")
            .text_xs()
            .text_color(ThemeColors::muted_foreground())
            .child(text)
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
    /// 常规：对齐 Tauri `GeneralPanel`（外观/语言/项目/文件/Git/隐藏路径）。
    fn render_general_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
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
                    "外观",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "配色主题".to_string(),
                            None,
                            self.render_dropdown(
                                "general-theme",
                                s.theme.clone(),
                                160.0,
                                &[("lithe-dark", "深色"), ("lithe-light", "浅色")],
                                cx,
                                |this, theme_id, cx| {
                                    // 跟随系统时写入对应的自动主题，否则直接切换主题。
                                    let sync = settings::get(cx).sync_system_theme;
                                    this.commit_theme(cx, |s| {
                                        if sync {
                                            if crate::theme::ThemePalette::is_light(theme_id) {
                                                s.auto_theme_light = theme_id.to_string();
                                            } else {
                                                s.auto_theme_dark = theme_id.to_string();
                                            }
                                        } else {
                                            s.theme = theme_id.to_string();
                                        }
                                    })
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "外观模式".to_string(),
                            Some("选择配色主题，并设置是否跟随系统外观。".to_string()),
                            self.render_dropdown(
                                "general-appearance-mode",
                                appearance_mode,
                                160.0,
                                &[("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")],
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
                        )),
                ),
            )
            .child(self.render_group(
                "语言",
                v_flex().w_full().gap_3().child(self.render_row(
                    "语言".to_string(),
                    Some("界面语言会立即生效。默认语言为英文。".to_string()),
                    self.render_dropdown(
                        "general-language",
                        s.display_language.clone(),
                        160.0,
                        &[("en-US", "English"), ("zh-CN", "简体中文")],
                        cx,
                        |this, lang, cx| this.commit(cx, |s| s.display_language = lang.to_string()),
                    ),
                )),
            ))
            .child(self.render_group(
                "项目",
                v_flex().w_full().gap_3().child(self.render_row(
                    "项目打开方式".to_string(),
                    Some(
                        "选择打开其他项目时是每次询问、保留在此窗口，还是创建新窗口。".to_string(),
                    ),
                    self.render_dropdown(
                        "general-project-placement",
                        placement,
                        160.0,
                        &[
                            ("ask", "每次询问"),
                            ("this-window", "此窗口"),
                            ("new-window", "新窗口"),
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
                )),
            ))
            .child(self.render_group(
                "文件",
                v_flex().w_full().gap_3().child(self.render_row(
                    "自动保存更改的文件".to_string(),
                    None,
                    self.render_toggle("general-auto-save", s.auto_save, cx, |this, cx| {
                        this.commit(cx, |s| s.auto_save = !s.auto_save)
                    }),
                )),
            ))
            .child(self.render_group(
                "Git",
                v_flex().w_full().gap_3().child(self.render_row(
                    "保存本地更改的方式".to_string(),
                    Some("选择执行 Git 操作前保护本地更改的方式。".to_string()),
                    self.render_dropdown(
                        "general-git-policy",
                        self.git_policy.clone(),
                        160.0,
                        &[
                            ("ask", "每次询问"),
                            ("shelf", "暂存架"),
                            ("stash", "Git 贮藏"),
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
                    "隐藏路径",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_note(
                            "每行一项。目录名称会隐藏匹配的文件夹；文件条目支持 * 和 ?。",
                        ))
                        .child(
                            v_flex().w_full().gap_1p5().child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::foreground())
                                    .child("目录"),
                            ),
                        )
                        .child(self.render_text_block(s.hidden_directory_patterns.join("\n"), 72.0))
                        .child(
                            div()
                                .text_xs()
                                .text_color(ThemeColors::foreground())
                                .child("文件模式"),
                        )
                        .child(self.render_text_block(s.hidden_file_patterns.join("\n"), 56.0))
                        .child(
                            h_flex().w_full().justify_end().child(
                                Button::new("general-apply-patterns")
                                    .small()
                                    .primary()
                                    .label("应用")
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        // 模式编辑器后续接入；当前落盘值即显示值。
                                        cx.notify();
                                    })),
                            ),
                        ),
                ),
            )
    }

    /// 项目 · JDK 与 Maven：对齐 `ProjectEnvironmentSettings` 的字段结构
    /// （工作区路径、作用域说明、三个工具链路径行、保存按钮）。
    /// 路径探测与保存尚未接入后端，输入框为只读占位。
    fn render_project_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                div()
                    .font_family("monospace")
                    .text_xs()
                    .text_color(ThemeColors::foreground())
                    .child(self.workspace_root.clone()),
            )
            .child(self.render_note(
                "仅保存在当前电脑，作用于当前项目。运行配置默认继承这些值，单独设置的覆盖值保持不变。路径留空时使用自动选择。",
            ))
            .child(
                self.render_group(
                    "工具链",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "JDK 主目录".to_string(),
                            Some("自动检测（留空）".to_string()),
                            self.render_value(String::new()),
                        ))
                        .child(self.render_row(
                            "Maven 主目录 / 可执行文件".to_string(),
                            Some("自动检测（留空）".to_string()),
                            self.render_value(String::new()),
                        ))
                        .child(self.render_row(
                            "Maven JDK 主目录".to_string(),
                            Some("使用项目 JDK".to_string()),
                            self.render_value(String::new()),
                        ))
                        .child(
                            h_flex().w_full().justify_end().child(
                                Button::new("project-save")
                                    .small()
                                    .primary()
                                    .label("保存")
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        // 工具链探测与保存尚未接入后端。
                                        cx.notify();
                                    })),
                            ),
                        ),
                ),
            )
    }

    /// 运行配置：对齐 `RunConfigurationSettings`（描述 + 生成按钮），后端未接入。
    fn render_run_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex().w_full().gap_4().child(
            self.render_group(
                "运行配置",
                v_flex()
                    .w_full()
                    .gap_3()
                    .child(self.render_note(
                        "选择服务或任务，配置启动参数、环境变量和项目环境覆盖项；点击保存后生效。",
                    ))
                    .child(
                        h_flex().w_full().justify_end().child(
                            Button::new("run-generate")
                                .small()
                                .primary()
                                .label("生成运行配置")
                                .on_click(cx.listener(|_this, _event, _window, cx| {
                                    // 运行配置生成尚未接入后端。
                                    cx.notify();
                                })),
                        ),
                    ),
            ),
        )
    }

    /// 编辑器：对齐 Tauri `EditorPanel`（显示/编辑器标签页/缩进）。
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
                            "字体大小".to_string(),
                            None,
                            self.render_stepper(
                                "font-dec",
                                "font-inc",
                                format!("{} px", s.font_size as i32),
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.font_size = (s.font_size - 1.0).max(10.0))
                                },
                                |this, cx| {
                                    this.commit(cx, |s| s.font_size = (s.font_size + 1.0).min(22.0))
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "显示用法与 Git 作者".to_string(),
                            None,
                            self.render_toggle("editor-code-lens", s.code_lens, cx, |this, cx| {
                                this.commit(cx, |s| s.code_lens = !s.code_lens)
                            }),
                        )),
                ),
            )
            .child(self.render_group(
                "编辑器标签页",
                v_flex().w_full().gap_3().child(self.render_row(
                    "缓冲区轮播".to_string(),
                    Some("在主视图中将打开的缓冲区显示为可横向滚动的轮播".to_string()),
                    self.render_toggle(
                        "editor-buffer-carousel",
                        s.horizontal_tab_scroll,
                        cx,
                        |this, cx| {
                            this.commit(cx, |s| s.horizontal_tab_scroll = !s.horizontal_tab_scroll)
                        },
                    ),
                )),
            ))
            .child(self.render_group(
                "缩进",
                v_flex().w_full().gap_3().child(self.render_row(
                    "制表符宽度".to_string(),
                    None,
                    self.render_dropdown(
                        "editor-tab-width",
                        s.tab_size.to_string(),
                        128.0,
                        &[("2", "2 个空格"), ("4", "4 个空格"), ("8", "8 个空格")],
                        cx,
                        |this, size, cx| {
                            this.commit(cx, |s| s.tab_size = size.parse().unwrap_or(2))
                        },
                    ),
                )),
            ))
    }

    /// 快捷键：对齐 Tauri `KeyboardPanel`（快捷键方案/键盘快捷键）。
    fn render_keyboard_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(self.render_group(
                "快捷键方案",
                v_flex().w_full().gap_3().child(self.render_row(
                    "预设".to_string(),
                    None,
                    self.render_dropdown(
                        "keymap-preset",
                        s.keybinding_preset.clone(),
                        176.0,
                        &[
                            ("none", "Lithe"),
                            ("vscode", "Visual Studio Code"),
                            ("jetbrains", "JetBrains"),
                            ("xcode", "Xcode"),
                        ],
                        cx,
                        |this, preset, cx| {
                            this.commit(cx, |s| s.keybinding_preset = preset.to_string())
                        },
                    ),
                )),
            ))
            .child(
                self.render_group(
                    "键盘快捷键",
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
                                        .child("搜索快捷键"),
                                ),
                        )
                        .child(
                            self.render_note(
                                "选择快捷键预设，然后使用命令面板查看和运行可用命令。",
                            ),
                        ),
                ),
            )
    }

    /// 终端：对齐 Tauri `TerminalPanel`（Shell / 默认 Shell）。
    fn render_terminal_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex().w_full().gap_4().child(self.render_group(
            "Shell",
            v_flex().w_full().gap_3().child(self.render_row(
                "默认 Shell".to_string(),
                Some("用于新的终端会话。".to_string()),
                self.render_dropdown(
                    "terminal-default-shell",
                    s.terminal_default_shell_id.clone(),
                    176.0,
                    &[
                        ("", "系统默认"),
                        ("powershell", "PowerShell"),
                        ("cmd", "命令提示符"),
                        ("wsl", "WSL"),
                    ],
                    cx,
                    |this, shell, cx| {
                        this.commit(cx, |s| s.terminal_default_shell_id = shell.to_string())
                    },
                ),
            )),
        ))
    }

    /// LSP：对齐 Tauri `LspPanel`（语言服务/已检测语言服务器）。
    fn render_lsp_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
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
                            "自动补全".to_string(),
                            Some("显示活动语言服务器提供的补全建议。".to_string()),
                            self.render_toggle(
                                "lsp-auto-completion",
                                s.auto_completion,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.auto_completion = !s.auto_completion)
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "参数提示".to_string(),
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
                        .child(self.render_row(
                            "语义高亮".to_string(),
                            None,
                            self.render_toggle(
                                "lsp-semantic-highlighting",
                                s.semantic_tokens,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.semantic_tokens = !s.semantic_tokens)
                                },
                            ),
                        )),
                ),
            )
            .child(self.render_group(
                "已检测语言服务器",
                self.render_note("语言服务器由已安装的语言扩展检测，并在打开受支持文件时启动。"),
            ))
    }

    /// AI 聊天与编辑：对齐 `AISettings` 的 Lithe Agent 分组结构
    /// （提供商/模型行），完整选择器尚未接入后端。
    fn render_ai_content(&self, _cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "Lithe Agent",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "提供商".to_string(),
                            Some("选择 Lithe Agent 使用的提供商".to_string()),
                            self.render_value("Anthropic".to_string()),
                        ))
                        .child(self.render_row(
                            "模型".to_string(),
                            Some("选择 Lithe Agent 使用的模型".to_string()),
                            self.render_value("claude-sonnet-4-6".to_string()),
                        )),
                ),
            )
            .child(self.render_group(
                "说明",
                self.render_note("完整提供商与模型选择尚未接入，后续版本提供。"),
            ))
    }

    /// AI 与提交：对齐 `AiCommitSettingsPanel` 的分组结构
    /// （配置文件/规则），完整配置尚未接入后端。
    fn render_ai_commit_content(&self, _cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "提交信息",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "配置文件".to_string(),
                            Some("用于生成提交信息的模型配置".to_string()),
                            self.render_value("默认".to_string()),
                        ))
                        .child(self.render_row(
                            "规则".to_string(),
                            Some("生成提交信息时遵循的规则".to_string()),
                            self.render_value("默认".to_string()),
                        )),
                ),
            )
            .child(self.render_group(
                "说明",
                self.render_note("AI 提交配置尚未接入，后续版本提供。"),
            ))
    }

    /// Git：对齐 Tauri `GitSettings` 的偏好区
    ///（Fetch 默认行为/集成/Git 视图/默认差异视图/编辑器）。
    fn render_git_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "Fetch 默认行为",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "清理失效的远程跟踪引用".to_string(),
                            Some("用于所有项目中的普通 Fetch。".to_string()),
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
                            "获取子模块".to_string(),
                            None,
                            self.render_dropdown(
                                "git-fetch-submodules",
                                s.git_fetch_submodules.clone(),
                                160.0,
                                &[
                                    ("inherit", "使用 Git 配置"),
                                    ("no", "不获取子模块"),
                                    ("onDemand", "按需获取"),
                                    ("yes", "获取全部子模块"),
                                ],
                                cx,
                                |this, value, cx| {
                                    this.commit(cx, |s| s.git_fetch_submodules = value.to_string())
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "获取标签".to_string(),
                            Some("凭据沿用现有 Git 凭据助手和 SSH 配置。".to_string()),
                            self.render_dropdown(
                                "git-fetch-tags",
                                s.git_fetch_tags.clone(),
                                160.0,
                                &[
                                    ("inherit", "使用 Git 配置"),
                                    ("all", "获取全部标签"),
                                    ("none", "不获取标签"),
                                    ("prune", "同步标签并删除远程已不存在的本地标签"),
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
                    "集成",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "Git 集成".to_string(),
                            Some("启用 Git 仓库的源代码管理功能".to_string()),
                            self.render_toggle(
                                "git-integration",
                                s.core_features.git,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.core_features.git = !s.core_features.git)
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "自动刷新 Git 状态".to_string(),
                            Some("相关文件或 Git 事件发生变化后自动刷新 Git 视图".to_string()),
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
                        ))
                        .child(self.render_row(
                            "丢弃前确认".to_string(),
                            Some("丢弃文件或仓库更改前显示确认提示".to_string()),
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
                        )),
                ),
            )
            .child(
                self.render_group(
                    "Git 视图",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "基于文件夹的更改".to_string(),
                            Some("以类似文件视图的文件夹树形式显示 Git 更改".to_string()),
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
                        ))
                        .child(self.render_row(
                            "显示未跟踪文件".to_string(),
                            Some("在 Git 状态面板中显示未跟踪文件".to_string()),
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
                        ))
                        .child(self.render_row(
                            "优先显示已暂存项".to_string(),
                            Some("在 Git 面板中将已暂存更改显示在未暂存更改之前".to_string()),
                            self.render_toggle(
                                "git-show-staged-first",
                                s.show_staged_first,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| s.show_staged_first = !s.show_staged_first)
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "单击打开差异".to_string(),
                            Some("单击已更改文件时打开差异，而不是直接打开文件".to_string()),
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
                        ))
                        .child(self.render_row(
                            "紧凑 Git 状态标记".to_string(),
                            Some("在 Git 面板中使用更紧凑的差异统计和暂存标签布局".to_string()),
                            self.render_toggle(
                                "git-compact-badges",
                                s.compact_git_status_badges,
                                cx,
                                |this, cx| {
                                    this.commit(cx, |s| {
                                        s.compact_git_status_badges = !s.compact_git_status_badges
                                    })
                                },
                            ),
                        ))
                        .child(self.render_row(
                            "折叠空分区".to_string(),
                            Some("没有项目时隐藏已暂存更改等空 Git 分区".to_string()),
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
                        ))
                        .child(self.render_row(
                            "记住上次 Git 面板模式".to_string(),
                            Some("重新打开 Git 视图时恢复上次打开的底部 Git 面板分区".to_string()),
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
                        )),
                ),
            )
            .child(self.render_group(
                "默认差异视图",
                v_flex().w_full().gap_3().child(self.render_row(
                    "默认差异视图".to_string(),
                    Some("选择 Git 差异的默认布局".to_string()),
                    self.render_dropdown(
                        "git-default-diff-view",
                        s.git_default_diff_view.clone(),
                        160.0,
                        &[("unified", "统一视图"), ("split", "拆分视图")],
                        cx,
                        |this, value, cx| {
                            this.commit(cx, |s| s.git_default_diff_view = value.to_string())
                        },
                    ),
                )),
            ))
            .child(self.render_group(
                "编辑器",
                v_flex().w_full().gap_3().child(self.render_row(
                    "启用行内 Blame".to_string(),
                    Some("在编辑器中显示当前行的 Git Blame 元数据".to_string()),
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
                )),
            ))
    }

    /// 日志：对齐 Tauri `LogSettingsPanel` 的分组结构
    /// （日志位置/诊断/保留策略/诊断包），目录操作尚未接入后端。
    fn render_logs_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let default_dir = default_log_dir();
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    "日志位置",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            "当前日志位置".to_string(),
                            Some("本次会话实际写入日志的目录。".to_string()),
                            self.render_value(default_dir.clone()),
                        ))
                        .child(self.render_row(
                            "默认日志位置".to_string(),
                            Some("Lithe 始终维护并清理这个应用自有目录。".to_string()),
                            self.render_value(default_dir),
                        ))
                        .child(self.render_row(
                            "自定义日志位置".to_string(),
                            Some("选择父目录后，Lithe 会写入其中的 Lithe/logs 子目录。".to_string()),
                            h_flex().gap_1p5().child(
                                Button::new("logs-choose-dir")
                                    .small()
                                    .ghost()
                                    .label("选择…")
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        // 目录选择尚未接入后端。
                                        cx.notify();
                                    })),
                            ),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "诊断",
                    v_flex().w_full().gap_3().child(self.render_row(
                        "本次会话启用诊断日志".to_string(),
                        Some(
                            "记录 DEBUG 事件和低频 FPS 心跳；Lithe 重启后自动恢复为 INFO。"
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
                    )),
                ),
            )
            .child(
                self.render_group(
                    "保留策略",
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_note(
                            "单个日志达到 10 MB 后轮转，每天保留最新五个常规日志，并在 Lithe 启动时删除超过 30 天的日志。",
                        ))
                        .child(self.render_row(
                            "清除当前目录日志".to_string(),
                            Some("只删除当前目录中由 Lithe 管理的日志文件。".to_string()),
                            Button::new("logs-clear")
                                .small()
                                .ghost()
                                .label("清除日志")
                                .on_click(cx.listener(|_this, _event, _window, cx| {
                                    // 日志清理尚未接入后端。
                                    cx.notify();
                                })),
                        )),
                ),
            )
            .child(
                self.render_group(
                    "诊断包",
                    v_flex().w_full().gap_3().child(self.render_row(
                        "导出诊断包…".to_string(),
                        None,
                        Button::new("logs-export-bundle")
                            .small()
                            .ghost()
                            .label("导出")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                // 诊断包导出尚未接入后端。
                                cx.notify();
                            })),
                    )),
                ),
            )
    }

    /// 更新：对齐 Tauri `UpdatesPanel`（软件更新/版本/检查按钮/状态文案）。
    fn render_updates_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex().w_full().gap_4().child(
            self.render_group(
                "软件更新",
                v_flex()
                    .w_full()
                    .gap_3()
                    .child(
                        self.render_row(
                            "Lithe".to_string(),
                            Some(format!("当前版本：{}", env!("CARGO_PKG_VERSION"))),
                            Button::new("check-updates")
                                .small()
                                .primary()
                                .label("检查更新")
                                .on_click(cx.listener(|_this, _event, _window, cx| {
                                    // 更新检查尚未接入后端。
                                    cx.notify();
                                })),
                        ),
                    )
                    .child(self.render_note("Lithe 可以检查新的预览版和稳定版。")),
            ),
        )
    }
}

/// 默认日志目录（`~/.local/share/lithe/logs`，对齐 XDG 状态目录）。
fn default_log_dir() -> String {
    std::env::var_os("XDG_DATA_HOME")
        .map(std::path::PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| {
            std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".local/share"))
        })
        .map(|base| {
            base.join("lithe")
                .join("logs")
                .to_string_lossy()
                .to_string()
        })
        .unwrap_or_else(|| "lithe/logs".to_string())
}
