//! 工作台欢迎页（Welcome Screen）。
//!
//! 复刻 Tauri 端 `features/layout/components/welcome-screen.tsx`：左侧 240px 导航栏
//! （Lithe 标识、Projects 高亮项、底部 Settings），右侧标题、搜索输入框与
//! Clone/Open 操作按钮、最近项目列表。所有交互只向外广播 [`WelcomeEvent`]，
//! 不接入真实的项目打开、克隆与设置流程。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AnyElement, App, Context, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

/// 欢迎页对外事件。
#[derive(Debug, Clone)]
pub enum WelcomeEvent {
    /// 打开文件夹（Open 按钮）。
    OpenFolder,
    /// 新建项目。
    #[allow(dead_code)]
    NewProject,
    /// 从远程克隆仓库（Clone 按钮）。
    CloneRepository,
    /// 打开指定路径的最近项目，携带项目路径。
    OpenProject(String),
    /// 打开设置。
    OpenSettings,
    /// 从最近列表移除某项目，携带项目路径。
    RemoveRecent(String),
}

#[allow(dead_code)]
impl WelcomeEvent {
    /// 供视图层在事件被消费前读取载荷，避免“字段未读”噪声。
    pub fn payload(&self) -> Option<&str> {
        match self {
            WelcomeEvent::OpenProject(path) | WelcomeEvent::RemoveRecent(path) => Some(path),
            _ => None,
        }
    }
}

/// 整屏欢迎页：左侧导航栏 + 右侧项目区。
///
/// 最近项目直接读 `settings::get(cx).recent_projects`（首位最新），展示时过滤
/// 不存在的路径；打开与删除都经 `settings::update` 落盘，与 `view.rs` 共用同一数组。
pub struct WelcomeScreenView {
    pub selected_index: usize,
    pub query: String,
    pub focus_handle: FocusHandle,
}

impl EventEmitter<WelcomeEvent> for WelcomeScreenView {}

impl WelcomeScreenView {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            selected_index: 0,
            query: String::new(),
            focus_handle: cx.focus_handle(),
        }
    }

    /// 当前查询过滤后的最近项目路径（首位最新，不存在的路径已滤除）。
    fn visible_projects(&self, cx: &App) -> Vec<String> {
        let q = self.query.trim().to_lowercase();
        crate::settings::get(cx)
            .recent_projects
            .iter()
            .filter(|p| std::path::Path::new(p).exists())
            .filter(|p| {
                q.is_empty() || {
                    let name = crate::settings::project_dir_name(p).to_lowercase();
                    name.contains(&q) || p.to_lowercase().contains(&q)
                }
            })
            .cloned()
            .collect()
    }

    /// 当前有效选中下标（对空列表安全）。
    fn current_index(&self, total: usize) -> usize {
        if total == 0 {
            0
        } else {
            self.selected_index.min(total - 1)
        }
    }

    /// 打开可见列表中第 `position` 个项目。
    fn open_at(&self, position: usize, cx: &mut Context<Self>) {
        let visible = self.visible_projects(cx);
        if let Some(path) = visible.get(position) {
            cx.emit(WelcomeEvent::OpenProject(path.clone()));
        }
    }

    /// 从最近列表移除指定路径（同步落盘），并夹紧选中下标。
    fn remove_recent(&mut self, path: &str, cx: &mut Context<Self>) {
        crate::settings::update(cx, |s| {
            s.recent_projects.retain(|p| p != path);
        });
        let total = crate::settings::get(cx)
            .recent_projects
            .iter()
            .filter(|p| std::path::Path::new(p).exists())
            .count();
        if self.selected_index >= total {
            self.selected_index = total.saturating_sub(1);
        }
        cx.emit(WelcomeEvent::RemoveRecent(path.to_string()));
        cx.notify();
    }

    /// 左侧导航栏：Lithe 标识、Projects 高亮项、底部 Settings。
    fn render_sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        v_flex()
            .w(px(240.0))
            .h_full()
            .flex_shrink_0()
            .bg(ThemeColors::surface())
            .border_r_1()
            .border_color(ThemeColors::border())
            .child(
                // 顶部标识区：Logo + 名称 + 版本
                h_flex()
                    .items_center()
                    .gap_2p5()
                    .px_4()
                    .pt_6()
                    .pb_4()
                    .child(
                        Icon::new(IconName::Zap)
                            .size(px(24.0))
                            .text_color(ThemeColors::primary()),
                    )
                    .child(
                        v_flex()
                            .child(
                                div()
                                    .text_lg()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(ThemeColors::foreground())
                                    .child("Lithe"),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::subtle_foreground())
                                    .child("0.1.0 · Linux"),
                            ),
                    ),
            )
            .child(
                // Projects 高亮项
                h_flex()
                    .id("welcome-projects")
                    .mx_2()
                    .h(px(36.0))
                    .items_center()
                    .gap_2p5()
                    .px_3()
                    .rounded_md()
                    .bg(ThemeColors::selected())
                    .cursor_pointer()
                    .child(
                        Icon::new(IconName::Folder)
                            .size(px(15.0))
                            .text_color(ThemeColors::primary()),
                    )
                    .child(
                        div()
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(ThemeColors::foreground())
                            .child(crate::i18n::menu_text(cx, "welcome.projects")),
                    ),
            )
            .child(div().flex_1())
            .child(
                // 底部 Settings 项
                h_flex()
                    .id("welcome-settings")
                    .mx_2()
                    .mb_2()
                    .h(px(36.0))
                    .items_center()
                    .gap_2p5()
                    .px_3()
                    .rounded_md()
                    .cursor_pointer()
                    .text_color(ThemeColors::subtle_foreground())
                    .hover(|h| h.bg(ThemeColors::accent()))
                    .child(
                        Icon::new(IconName::Settings)
                            .size(px(15.0))
                            .text_color(ThemeColors::subtle_foreground()),
                    )
                    .child(
                        div()
                            .text_sm()
                            .child(crate::i18n::menu_text(cx, "workbench.settings")),
                    )
                    .on_click(cx.listener(|_this, _event, _window, cx| {
                        cx.emit(WelcomeEvent::OpenSettings);
                    })),
            )
            .into_any_element()
    }

    /// 右侧项目区：标题、搜索与操作按钮、最近项目列表。
    fn render_main(&self, cx: &mut Context<Self>) -> AnyElement {
        let visible = self.visible_projects(cx);
        let current_index = self.current_index(visible.len());

        v_flex()
            .flex_1()
            .h_full()
            .min_w_0()
            .px_5()
            .pt_10()
            .child(
                // 大标题
                h_flex().w_full().justify_center().child(
                    div()
                        .text_xl()
                        .font_weight(FontWeight::BOLD)
                        .text_color(ThemeColors::foreground())
                        .child(crate::i18n::menu_text(cx, "welcome.title")),
                ),
            )
            .child(
                h_flex().w_full().justify_center().pt_2().child(
                    div()
                        .text_sm()
                        .text_color(ThemeColors::subtle_foreground())
                        .child(crate::i18n::menu_text(cx, "welcome.openFolderHint")),
                ),
            )
            .child(
                // 搜索输入框 + Clone / Open 按钮
                h_flex()
                    .w_full()
                    .items_center()
                    .gap_3()
                    .mt_8()
                    .pb_3()
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .child(
                        h_flex()
                            .w(px(360.0))
                            .h(px(36.0))
                            .items_center()
                            .gap_2()
                            .px_2p5()
                            .rounded_md()
                            .bg(ThemeColors::background())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::Search)
                                    .size(px(14.0))
                                    .text_color(ThemeColors::subtle_foreground()),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .text_sm()
                                    .text_color(if self.query.is_empty() {
                                        ThemeColors::subtle_foreground()
                                    } else {
                                        ThemeColors::foreground()
                                    })
                                    .child(if self.query.is_empty() {
                                        crate::i18n::menu_text(cx, "welcome.searchProjects")
                                            .to_string()
                                    } else {
                                        self.query.clone()
                                    }),
                            ),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("welcome-clone")
                            .small()
                            .icon(IconName::GitBranch)
                            .label(crate::i18n::menu_text(cx, "welcome.clone"))
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(WelcomeEvent::CloneRepository);
                            })),
                    )
                    .child(
                        Button::new("welcome-open")
                            .small()
                            .primary()
                            .icon(IconName::FolderOpen)
                            .label(crate::i18n::menu_text(cx, "welcome.open"))
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(WelcomeEvent::OpenFolder);
                            })),
                    ),
            )
            .child(
                // 最近项目分组头（对齐 Tauri `welcome.recentProjects`）
                div()
                    .w_full()
                    .pt_4()
                    .pb_1()
                    .text_sm()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(ThemeColors::foreground())
                    .child(crate::i18n::menu_text(cx, "welcome.recentProjects")),
            )
            .child(
                // 最近项目列表或空态
                div()
                    .flex_1()
                    .w_full()
                    .min_w_0()
                    .overflow_y_scrollbar()
                    .py_2()
                    .when(visible.is_empty(), |list| {
                        list.child(
                            v_flex()
                                .size_full()
                                .items_center()
                                .justify_center()
                                .gap_2()
                                .child(
                                    Icon::new(IconName::FolderOpen)
                                        .size(px(28.0))
                                        .text_color(ThemeColors::subtle_foreground()),
                                )
                                .child(
                                    div()
                                        .text_sm()
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(ThemeColors::foreground())
                                        .child(crate::i18n::menu_text(
                                            cx,
                                            "welcome.noRecentProjects",
                                        )),
                                )
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(ThemeColors::subtle_foreground())
                                        .child(crate::i18n::menu_text(
                                            cx,
                                            "welcome.openFolderHint",
                                        )),
                                ),
                        )
                    })
                    .children(visible.into_iter().enumerate().map(|(position, path)| {
                        let is_selected = position == current_index;
                        let name = crate::settings::project_dir_name(&path).to_string();
                        let remove_path = path.clone();
                        let badge = project_badge(&name, &path);
                        // 每行使用独立的 hover group，避免兄弟行共享 group 名互相影响
                        let group_name = format!("welcome-recent-group-{position}");

                        h_flex()
                            .id(("welcome-recent", position))
                            .group(group_name.clone())
                            .h(px(52.0))
                            .w_full()
                            .min_w_0()
                            .items_center()
                            .gap_3()
                            .px_2()
                            .rounded_md()
                            .cursor_pointer()
                            .when(is_selected, |row| row.bg(ThemeColors::selected()))
                            .when(!is_selected, |row| {
                                row.hover(|h| h.bg(ThemeColors::accent()))
                            })
                            .child(badge)
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .child(
                                        div()
                                            .text_sm()
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_color(ThemeColors::foreground())
                                            .child(name),
                                    )
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(ThemeColors::subtle_foreground())
                                            .child(path),
                                    ),
                            )
                            .child(
                                // 悬停时才显示的删除按钮
                                div()
                                    .opacity(0.0)
                                    .group_hover(group_name, |style| style.opacity(1.0))
                                    .child(
                                        Button::new(("welcome-remove", position))
                                            .xsmall()
                                            .ghost()
                                            .icon(IconName::Trash)
                                            .tooltip(
                                                crate::i18n::menu_text(cx, "welcome.removeRecent")
                                                    .replace(
                                                        "{name}",
                                                        crate::settings::project_dir_name(
                                                            &remove_path,
                                                        ),
                                                    ),
                                            )
                                            .on_click(cx.listener(
                                                move |this, _event, _window, cx| {
                                                    // 阻止冒泡到整行，避免删除时同时打开项目
                                                    cx.stop_propagation();
                                                    this.remove_recent(&remove_path, cx);
                                                },
                                            )),
                                    ),
                            )
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.open_at(position, cx);
                            }))
                            .into_any_element()
                    })),
            )
            .into_any_element()
    }
}

impl Render for WelcomeScreenView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 请求聚焦以接收键盘上下移动
        window.focus(&self.focus_handle, cx);

        div()
            .id("welcome-screen")
            .track_focus(&self.focus_handle)
            .size_full()
            .bg(ThemeColors::background())
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                match key {
                    "up" | "arrowup" => {
                        if this.selected_index > 0 {
                            this.selected_index -= 1;
                            cx.notify();
                        }
                    }
                    "down" | "arrowdown" => {
                        let total = this.visible_projects(cx).len();
                        if total > 0 && this.selected_index + 1 < total {
                            this.selected_index += 1;
                            cx.notify();
                        }
                    }
                    "enter" => {
                        let total = this.visible_projects(cx).len();
                        let idx = this.current_index(total);
                        this.open_at(idx, cx);
                    }
                    "backspace" => {
                        this.query.pop();
                        this.selected_index = 0;
                        cx.notify();
                    }
                    "space" => {
                        this.query.push(' ');
                        this.selected_index = 0;
                        cx.notify();
                    }
                    _ => {
                        // 无修饰键时把可打印字符追加到搜索框
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            if let Some(ch) = &event.keystroke.key_char {
                                this.query.push_str(ch);
                                this.selected_index = 0;
                                cx.notify();
                            } else if key.chars().count() == 1 {
                                this.query.push_str(key);
                                this.selected_index = 0;
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .child(
                h_flex()
                    .size_full()
                    .child(self.render_sidebar(cx))
                    .child(self.render_main(cx)),
            )
    }
}

/// 按名称首字母从语义色板中取色，生成圆角首字母徽标。
fn project_badge(name: &str, path: &str) -> AnyElement {
    let initial = name
        .chars()
        .find(|c| c.is_alphanumeric())
        .map(|c| c.to_uppercase().to_string())
        .unwrap_or_else(|| "L".to_string());

    // 用路径字符和做稳定散列，保证同一项目每次渲染颜色一致
    let hash: u32 = path.chars().map(|c| c as u32).sum();
    let color = match hash % 5 {
        0 => ThemeColors::primary(),
        1 => ThemeColors::success(),
        2 => ThemeColors::warning(),
        3 => ThemeColors::destructive(),
        _ => ThemeColors::info(),
    };

    h_flex()
        .size(px(34.0))
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .rounded_lg()
        .bg(color)
        .child(
            div()
                .text_sm()
                .font_weight(FontWeight::BOLD)
                .text_color(ThemeColors::background())
                .child(initial),
        )
        .into_any_element()
}
