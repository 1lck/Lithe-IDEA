//! Render 入口：整体布局、配置列表/输出分栏与空状态引导。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::resizable::{h_resizable, resizable_panel};
use gpui_kit::component::{Disableable as _, Icon, IconName, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, StatefulInteractiveElement as _, Styled as _, Window,
    div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use super::{
    CONFIGURATION_LIST_MAX_WIDTH, CONFIGURATION_LIST_MIN_WIDTH, OUTPUT_MIN_WIDTH, PANEL_PADDING,
    RunPanel, STATUS_LINE_HEIGHT,
};

impl RunPanel {
    /// 选中会话的状态文案，对齐 IDEA 的运行状态语义：
    /// 运行中、已结束、非零退出码如实显示、被用户停止不作为失败。
    /// 没有选中会话时不显示状态行。
    fn session_status_line(&self, tokens: LitheTokens) -> Option<(Hsla, SharedString)> {
        let session = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))?;
        let (color, text) = if session.starting {
            (tokens.warning, tr("Starting…").to_string())
        } else if session.running {
            (tokens.success, tr("Running").to_string())
        } else if session.stopped {
            (tokens.tertiary_text, tr("Stopped").to_string())
        } else if session.exit_code == Some(0) {
            (tokens.secondary_text, tr("Finished").to_string())
        } else if let Some(code) = session.exit_code {
            (
                tokens.error,
                format!("{} {code}", tr("Process finished with exit code")),
            )
        } else {
            (
                tokens.error,
                tr("Process finished with an unknown exit code").to_string(),
            )
        };
        Some((color, text.into()))
    }

    /// 未找到运行配置的空状态视图（完全对齐 Tauri 图一）。
    fn render_missing_configuration_view(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_loading = self.loading;
        v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .gap(px(10.0))
            .px(px(24.0))
            .bg(tokens.editor)
            .child(
                Icon::new(IconName::Play)
                    .with_size(px(36.0))
                    .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .text_size(px(15.0))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Project run configuration not found")),
            )
            .child(
                div()
                    .max_w(px(480.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Identify the project to enable Run. Existing project and local overrides will be preserved.")),
            )
            .child(
                div()
                    .pt(px(6.0))
                    .child(
                        Button::new("lithe-run:identify-btn")
                            .primary()
                            .disabled(is_loading)
                            .label(if is_loading {
                                tr("Identifying project…")
                            } else {
                                tr("Identify and generate")
                            })
                            .on_click(cx.listener(|this, _, _window, cx| {
                                this.reload(cx);
                            })),
                    ),
            )
            .into_any_element()
    }

    /// 主体：固定宽度的作用域图标条 + 可拖拽的「配置列表 / 输出」分栏。
    ///
    /// 宽度规则对齐 macOS `RunServicesSplitView`：配置列表 240..480，输出区
    /// 最小 320；可用宽度不足时整行横向滚动，而不是把两栏压到互相遮字。
    fn render_body(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let minimum_width = 100.0 + CONFIGURATION_LIST_MIN_WIDTH + OUTPUT_MIN_WIDTH;
        div()
            .id("lithe-run-body")
            .flex_1()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .overflow_x_scroll()
            .child(
                h_flex()
                    .h_full()
                    .min_w(px(minimum_width))
                    .child(self.render_language_rail(tokens, cx))
                    .child(self.render_split(tokens, cx)),
            )
            .into_any_element()
    }

    /// 配置列表 / 输出分栏。尺寸由 gpui-kit 的 `h_resizable` 维护，拖拽结束
    /// 回写 `configuration_width`，与 macOS 的 AppStorage 持久化语义一致。
    fn render_split(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let group = h_resizable("lithe-run-split")
            .with_state(&self.split_state)
            .on_resize(move |state, _window, cx| {
                let sizes = state.read(cx).sizes().clone();
                let _ = owner.update(cx, |this, cx| {
                    let Some(width) = sizes.first().copied() else {
                        return;
                    };
                    let width = width
                        .as_f32()
                        .clamp(CONFIGURATION_LIST_MIN_WIDTH, CONFIGURATION_LIST_MAX_WIDTH);
                    if (this.configuration_width - width).abs() > 0.5 {
                        this.configuration_width = width;
                        cx.notify();
                    }
                });
            })
            .child(
                resizable_panel()
                    .size(px(self.configuration_width))
                    .size_range(px(CONFIGURATION_LIST_MIN_WIDTH)..px(CONFIGURATION_LIST_MAX_WIDTH))
                    .child(self.render_configuration_list(tokens, cx)),
            )
            .child(
                resizable_panel()
                    .size_range(px(OUTPUT_MIN_WIDTH)..px(4096.0))
                    .child(self.render_content(tokens, cx)),
            );

        div()
            .flex_1()
            .h_full()
            .min_w(px(0.0))
            .child(group)
            .into_any_element()
    }
}

impl Render for RunPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.ensure_loaded(window, cx);
        // 输出行数变化在这里统一入账：列表只排版可视行，追加只改行数。
        self.sync_console_lines();
        self.console.sync_display();
        let tokens = current_tokens(cx);

        let mut panel = v_flex()
            .id("lithe-run-panel")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(self.render_preparation_status(tokens, cx))
            .child(self.render_header(tokens, cx));

        if let Some(error) = self.error.clone() {
            panel = panel.child(status_line(tokens.error, error));
        }
        if let Some((color, text)) = self.session_status_line(tokens) {
            panel = panel.child(status_line(color, text));
        }
        for banner in self.render_banners(tokens, cx) {
            panel = panel.child(banner);
        }

        // 当没有运行配置且没有进程运行时，对齐图一展示居中的未找到运行配置引导卡片；
        // 否则展示完整的运行控制台
        if self.configurations.is_empty() && !self.is_running() {
            panel = panel.child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_missing_configuration_view(tokens, cx)),
            );
        } else {
            panel = panel.child(self.render_body(tokens, cx));
        }

        self.with_floating_menu(panel.into_any_element(), cx)
    }
}

fn status_line(color: Hsla, message: SharedString) -> AnyElement {
    h_flex()
        .w_full()
        .flex_shrink_0()
        .h(px(STATUS_LINE_HEIGHT))
        .px(px(PANEL_PADDING))
        .child(
            div()
                .min_w(px(0.0))
                .flex_1()
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(color)
                .child(message),
        )
        .into_any_element()
}
