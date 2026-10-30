//! 欢迎页。
//!
//! 对齐 macOS `WelcomeView` 的层级：左侧导航收在 `lithe-workbench`，这里只
//! 渲染一个标题、一个主操作按钮和最近项目列表。行内显示项目名与完整路径，
//! 不使用卡片和阴影，保持 IDEA 欢迎页的平面观感。
//!
//! 最近项目来自平台层；`pick_folder` 依赖原生对话框，必须在 UI 线程调用，
//! 因此只在按钮点击回调里同步执行。打开项目后先写入最近列表，再触发上层
//! 回调，保证欢迎页返回时顺序已经刷新。

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement, Render, StatefulInteractiveElement as _, Styled, Window, div, px,
};
use lithe_platform::PlatformServices;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, current_tokens, icon};

/// 欢迎页的排版刻度。`lithe-ui` 的 metrics 没有欢迎页专用字号，集中在这里。
const WELCOME_TITLE_FONT_SIZE: f32 = 24.0;
const WELCOME_HORIZONTAL_PADDING: f32 = 32.0;
const WELCOME_VERTICAL_PADDING: f32 = 28.0;
const WELCOME_SECTION_GAP: f32 = 18.0;
const WELCOME_ROW_HEIGHT: f32 = 46.0;
const WELCOME_ICON_SIZE: f32 = 18.0;

type OpenProjectHandler = Rc<dyn Fn(PathBuf, &mut Window, &mut App) + 'static>;

/// 欢迎页视图。
pub struct WelcomeView {
    platform: Arc<dyn PlatformServices>,
    recent: Vec<PathBuf>,
    on_open_project: Option<OpenProjectHandler>,
}

impl WelcomeView {
    pub fn new(platform: Arc<dyn PlatformServices>, _cx: &mut Context<Self>) -> Self {
        // 最近项目是本地小 JSON，读取失败会被平台层降级为空列表；在构造时
        // 读一次能让首帧直接显示正确内容，不需要先闪一下空状态。
        let recent = platform.recent_projects();
        Self {
            platform,
            recent,
            on_open_project: None,
        }
    }

    pub fn on_open_project(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static) {
        self.on_open_project = Some(Rc::new(handler));
    }

    /// 重新读取最近项目。用于返回欢迎页或外部打开项目之后。
    pub fn refresh_recent(&mut self, cx: &mut Context<Self>) {
        self.recent = self.platform.recent_projects();
        cx.notify();
    }

    fn open_project_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // 不能在点击回调里同步打开原生模态框：Windows 对话框消息循环会
        // 重入 GPUI 窗口借用并 abort。用异步对话框，await 后回主线程更新。
        let platform = self.platform.clone();
        let title = tr("Open Project").to_string();
        cx.spawn_in(window, async move |this, cx| {
            let path = platform.pick_folder(title).await;
            let Some(path) = path else {
                // 用户取消或平台不支持对话框：不是错误，保持当前页面。
                return;
            };

            let _ = this.update_in(cx, move |this, window, cx| {
                this.platform.remember_project(&path);
                this.recent = this.platform.recent_projects();

                let handler = this.on_open_project.clone();
                if let Some(handler) = handler {
                    handler(path, window, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn activate_recent(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_open_project.as_ref() {
            handler(path, window, cx);
        }
    }
}

impl Render for WelcomeView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let recents = self.recent.clone();

        let mut content = div()
            .size_full()
            .flex()
            .flex_col()
            .bg(tokens.window)
            .text_color(tokens.primary_text)
            .px(px(WELCOME_HORIZONTAL_PADDING))
            .py(px(WELCOME_VERTICAL_PADDING))
            .gap(px(WELCOME_SECTION_GAP))
            .child(render_header(tokens, cx))
            .child(div().w_full().h(px(1.0)).flex_shrink_0().bg(tokens.divider));

        if recents.is_empty() {
            content = content.child(empty_state(tokens));
        } else {
            let mut list = div().w_full().flex().flex_col().gap(px(2.0));
            for path in recents {
                list = list.child(recent_row(path, tokens, cx));
            }
            content = content.child(
                div()
                    .id("welcome:recent-scroll")
                    .w_full()
                    .flex_1()
                    .overflow_y_scroll()
                    .child(list),
            );
        }

        content
    }
}

fn render_header(tokens: LitheTokens, cx: &mut Context<WelcomeView>) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_row()
        .items_center()
        .justify_between()
        .gap(px(16.0))
        .child(
            div()
                .flex_1()
                .min_w(px(0.0))
                .flex()
                .flex_col()
                .gap(px(6.0))
                .child(
                    div()
                        .text_size(px(WELCOME_TITLE_FONT_SIZE))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(tokens.primary_text)
                        .child(tr("Welcome to Lithe")),
                )
                .child(
                    div()
                        .text_size(px(LitheMetrics::UI_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(tr("Open a local folder to start working.")),
                ),
        )
        .child(
            Button::new("welcome:open-project")
                .primary()
                .label(tr("Open Project"))
                .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                    this.open_project_picker(window, cx);
                })),
        )
        .into_any_element()
}

fn recent_row(path: PathBuf, tokens: LitheTokens, cx: &mut Context<WelcomeView>) -> AnyElement {
    let name = project_name(&path);
    let full_path = path.display().to_string();
    let click_path = path;

    div()
        .id(format!("welcome:recent:{}", full_path))
        .w_full()
        .h(px(WELCOME_ROW_HEIGHT))
        .flex_shrink_0()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(10.0))
        .px(px(10.0))
        .rounded(px(LitheMetrics::CONTROL_RADIUS))
        .hover(|style| style.bg(tokens.hover))
        .cursor_pointer()
        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
            this.activate_recent(click_path.clone(), window, cx);
        }))
        .child(
            icon(LitheIcon::Project)
                .with_size(px(WELCOME_ICON_SIZE))
                .text_color(tokens.secondary_text),
        )
        .child(
            div()
                .flex_1()
                .min_w(px(0.0))
                .flex()
                .flex_col()
                .gap(px(1.0))
                .child(
                    div()
                        .truncate()
                        .text_size(px(LitheMetrics::UI_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(name),
                )
                .child(
                    div()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(full_path),
                ),
        )
        .into_any_element()
}

fn empty_state(tokens: LitheTokens) -> impl IntoElement {
    div()
        .w_full()
        .flex_1()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap(px(8.0))
        .child(
            icon(LitheIcon::Project)
                .with_size(px(30.0))
                .text_color(tokens.tertiary_text),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::UI_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr("No recent projects")),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr("Open a local folder to start working.")),
        )
}

fn project_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| path.display().to_string())
}
