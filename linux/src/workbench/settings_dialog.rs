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
                    crate::i18n::menu_text(cx, "settings.mac.appearance").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "settings.mac.colorTheme").to_string(),
                            None,
                            self.render_dropdown(
                                "general-theme",
                                s.theme.clone(),
                                160.0,
                                vec![
                                        (
                                            "lithe-dark",
                                            crate::i18n::menu_text(cx, "settings.mac.dark")
                                                .to_string(),
                                        ),
                                        (
                                            "lithe-light",
                                            crate::i18n::menu_text(cx, "settings.mac.light")
                                                .to_string(),
                                        ),
                                    ],
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
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.mac.appearanceMode")
                                    .to_string()
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
                        .child(v_flex().w_full().gap_1p5().child(
                            div().text_xs().text_color(ThemeColors::foreground()).child(
                                crate::i18n::menu_text(cx, "settings.mac.directories").to_string(),
                            ),
                        ))
                        .child(self.render_text_block(s.hidden_directory_patterns.join("\n"), 72.0))
                        .child(div().text_xs().text_color(ThemeColors::foreground()).child(
                            crate::i18n::menu_text(cx, "settings.mac.filePatterns").to_string(),
                        ))
                        .child(self.render_text_block(s.hidden_file_patterns.join("\n"), 56.0))
                        .child(
                            h_flex().w_full().justify_end().child(
                                Button::new("general-apply-patterns")
                                    .small()
                                    .primary()
                                    .label(
                                        crate::i18n::menu_text(cx, "settings.mac.apply")
                                            .to_string(),
                                    )
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
            .child(
                self.render_note(crate::i18n::menu_text(cx, "settings.project.scope").to_string()),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.project.toolchain").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "run.jdkHome").to_string(),
                            Some(crate::i18n::menu_text(cx, "run.toolchainAuto").to_string()),
                            self.render_value(String::new()),
                        ))
                        .child(self.render_row(
                            crate::i18n::menu_text(cx, "run.mavenExecutable").to_string(),
                            Some(crate::i18n::menu_text(cx, "run.toolchainAuto").to_string()),
                            self.render_value(String::new()),
                        ))
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "run.mavenJdkHome").to_string(),
                                Some(
                                    crate::i18n::menu_text(cx, "settings.project.useProjectJdk")
                                        .to_string()
                                        .to_string(),
                                ),
                                self.render_value(String::new()),
                            ),
                        )
                        .child(
                            h_flex().w_full().justify_end().child(
                                Button::new("project-save")
                                    .small()
                                    .primary()
                                    .label(crate::i18n::menu_text(cx, "ui.save").to_string())
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
                crate::i18n::menu_text(cx, "settings.run.title").to_string(),
                v_flex()
                    .w_full()
                    .gap_3()
                    .child(self.render_note(
                        crate::i18n::menu_text(cx, "settings.run.description").to_string(),
                    ))
                    .child(
                        h_flex().w_full().justify_end().child(
                            Button::new("run-generate")
                                .small()
                                .primary()
                                .label(
                                    crate::i18n::menu_text(cx, "settings.run.generate").to_string(),
                                )
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
                            crate::i18n::menu_text(cx, "settings.mac.fontSize").to_string(),
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
    }

    /// 快捷键：对齐 Tauri `KeyboardPanel`（快捷键方案/键盘快捷键）。
    fn render_keyboard_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex()
            .w_full()
            .gap_4()
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.mac.keymapPreset").to_string(),
                v_flex().w_full().gap_3().child(self.render_row(
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
                            ("xcode", "Xcode".to_string()),
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

    /// 终端：对齐 Tauri `TerminalPanel`（Shell / 默认 Shell）。
    fn render_terminal_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let s = settings::get(cx).clone();
        v_flex().w_full().gap_4().child(self.render_group(
            crate::i18n::menu_text(cx, "settings.mac.shell").to_string(),
            v_flex().w_full().gap_3().child(self.render_row(
                crate::i18n::menu_text(cx, "settings.mac.defaultShell").to_string(),
                Some(
                    crate::i18n::menu_text(cx, "settings.mac.defaultShellDescription").to_string(),
                ),
                self.render_dropdown(
                    "terminal-default-shell",
                    s.terminal_default_shell_id.clone(),
                    176.0,
                    vec![
                                (
                                    "",
                                    crate::i18n::menu_text(cx, "settings.mac.systemDefault")
                                        .to_string(),
                                ),
                                (
                                    "powershell",
                                    crate::i18n::menu_text(cx, "settings.mac.shellPowerShell")
                                        .to_string(),
                                ),
                                (
                                    "cmd",
                                    crate::i18n::menu_text(cx, "settings.mac.shellCommandPrompt")
                                        .to_string(),
                                ),
                                (
                                    "wsl",
                                    crate::i18n::menu_text(cx, "settings.mac.shellWsl").to_string(),
                                ),
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
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.detectedServers").to_string(),
                    self.render_note(
                        crate::i18n::menu_text(cx, "settings.mac.detectedServersDescription")
                            .to_string(),
                    ),
                ),
            )
    }

    /// AI 聊天与编辑：对齐 `AISettings` 的 Lithe Agent 分组结构
    /// （提供商/模型行），完整选择器尚未接入后端。
    fn render_ai_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
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
                                self.render_value("Anthropic".to_string()),
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
                                self.render_value("claude-sonnet-4-6".to_string()),
                            ),
                        ),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.ai.noteTitle").to_string(),
                self.render_note(
                    crate::i18n::menu_text(cx, "settings.ai.providerNote").to_string(),
                ),
            ))
    }

    /// AI 与提交：对齐 `AiCommitSettingsPanel` 的分组结构
    /// （配置文件/规则），完整配置尚未接入后端。
    fn render_ai_commit_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_4()
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.mac.commitMessage").to_string(),
                    v_flex()
                        .w_full()
                        .gap_3()
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.ai.commitProfile").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.ai.commitProfileDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_value("默认".to_string()),
                            ),
                        )
                        .child(
                            self.render_row(
                                crate::i18n::menu_text(cx, "settings.ai.commitRules").to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "settings.ai.commitRulesDescription",
                                    )
                                    .to_string(),
                                ),
                                self.render_value("默认".to_string()),
                            ),
                        ),
                ),
            )
            .child(self.render_group(
                crate::i18n::menu_text(cx, "settings.ai.noteTitle").to_string(),
                self.render_note(crate::i18n::menu_text(cx, "settings.ai.commitNote").to_string()),
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

    /// 日志：对齐 Tauri `LogSettingsPanel` 的分组结构
    /// （日志位置/诊断/保留策略/诊断包），目录操作尚未接入后端。
    fn render_logs_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let default_dir = default_log_dir();
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
                                self.render_value(default_dir.clone()),
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
                                h_flex().gap_1p5().child(
                                    Button::new("logs-choose-dir")
                                        .small()
                                        .ghost()
                                        .label(
                                            crate::i18n::menu_text(cx, "settings.logs.choose")
                                                .to_string(),
                                        )
                                        .on_click(cx.listener(|_this, _event, _window, cx| {
                                            // 目录选择尚未接入后端。
                                            cx.notify();
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
                                        crate::i18n::menu_text(cx, "settings.logs.clearLogs")
                                            .to_string(),
                                    )
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        // 日志清理尚未接入后端。
                                        cx.notify();
                                    })),
                            ),
                        ),
                ),
            )
            .child(
                self.render_group(
                    crate::i18n::menu_text(cx, "settings.logs.diagnosticBundle").to_string(),
                    v_flex().w_full().gap_3().child(
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
                                .on_click(cx.listener(|_this, _event, _window, cx| {
                                    // 诊断包导出尚未接入后端。
                                    cx.notify();
                                })),
                        ),
                    ),
                ),
            )
    }

    /// 更新：对齐 Tauri `UpdatesPanel`（软件更新/版本/检查按钮/状态文案）。
    fn render_updates_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
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
                                .on_click(cx.listener(|_this, _event, _window, cx| {
                                    // 更新检查尚未接入后端。
                                    cx.notify();
                                })),
                        ),
                    )
                    .child(self.render_note(
                        crate::i18n::menu_text(cx, "settings.mac.updateHint").to_string(),
                    )),
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
