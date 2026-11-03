use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::{LitheMetrics, current_tokens};

use super::super::{OVERLAY_CONTEXT, Workbench};

impl Workbench {
    /// 设置覆盖层：全屏半透明背板 + 居中 900×700 面板。
    pub(crate) fn render_settings_overlay(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let header_close_owner = cx.weak_entity();
        let footer_close_owner = cx.weak_entity();
        let restore_owner = cx.weak_entity();
        let window_size = window.window_bounds().get_bounds().size;
        let panel_width = (window_size.width - px(32.)).min(px(900.)).max(px(600.));
        let panel_height = (window_size.height - px(32.)).min(px(700.)).max(px(400.));

        div()
            .id("lithe-settings-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .occlude()
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(cx.listener(Self::on_action_dismiss_overlay))
            .child(
                div()
                    .id("lithe-settings-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(gpui_kit::black().alpha(0.55))
                    .on_click(move |_event: &ClickEvent, _window, cx| {
                        let _ = backdrop_owner.update(cx, |this, cx| this.close_overlay(cx));
                    }),
            )
            .child(
                v_flex()
                    .id("lithe-settings-panel")
                    .occlude()
                    .w(panel_width)
                    .h(panel_height)
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.editor)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .child(
                        h_flex()
                            .w_full()
                            .h(px(32.))
                            .flex_shrink_0()
                            .items_center()
                            .gap(px(6.))
                            .px(px(12.))
                            .bg(tokens.editor)
                            .border_b(px(1.))
                            .border_color(tokens.divider)
                            .child(
                                icon(LitheIcon::Settings)
                                    .with_size(px(14.))
                                    .text_color(tokens.secondary_text),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(tokens.primary_text)
                                    .child(tr("Settings")),
                            )
                            .child(
                                Button::new("lithe-settings-close")
                                    .ghost()
                                    .size(px(24.))
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .child(icon(LitheIcon::Close).with_size(px(14.)))
                                    .tooltip(tr("Close"))
                                    .accessibility_label(tr("Close"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = header_close_owner
                                            .update(cx, |this, cx| this.close_overlay(cx));
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_h(px(0.))
                            .min_w(px(0.))
                            .when_some(self.settings_view.clone(), |this, view| this.child(view)),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .h(px(52.))
                            .flex_shrink_0()
                            .items_center()
                            .justify_between()
                            .px(px(16.))
                            .bg(tokens.editor)
                            .border_t(px(1.))
                            .border_color(tokens.divider)
                            .child(
                                Button::new("lithe-settings-restore-defaults")
                                    .small()
                                    .h(px(24.))
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .label(tr("Restore Defaults"))
                                    .on_click(move |_, window, cx| {
                                        let _ = restore_owner.update(cx, |this, cx| {
                                            this.restore_settings_defaults(window, cx)
                                        });
                                    }),
                            )
                            .child(
                                Button::new("lithe-settings-footer-close")
                                    .small()
                                    .h(px(24.))
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .min_w(px(72.))
                                    .label(tr("Close"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = footer_close_owner
                                            .update(cx, |this, cx| this.close_overlay(cx));
                                    }),
                            ),
                    ),
            )
            .into_any_element()
    }

    pub(crate) fn restore_settings_defaults(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(view) = self.settings_view.clone() else {
            return;
        };
        // 对齐 Tauri `settings-dialog.tsx`：恢复默认值先弹确认对话框，确认
        // 后才执行，避免一键丢掉全部个人设置。
        let owner = cx.weak_entity();
        window.open_alert_dialog(cx, move |alert, _window, _cx| {
            let owner = owner.clone();
            let view = view.clone();
            alert
                .title(tr("Reset Settings"))
                .description(tr(
                    "All settings will be reset to their default values. This action cannot be undone.",
                ))
                .confirm()
                .ok_text(tr("Reset"))
                .on_ok(move |_event, window, cx| {
                    let _ = owner.update(cx, |this, cx| {
                        view.update(cx, |view, view_cx| view.restore_defaults(window, view_cx));
                    });
                    true
                })
        });
    }

    pub(crate) fn toggle_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_visible {
            self.settings_visible = false;
            cx.notify();
            return;
        }

        self.palette_visible = false;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.pending_close_queue.clear();
        self.pending_quit = false;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.settings_visible = true;

        let settings = self.settings.clone();
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.set_settings(settings, view_cx));
        }
        self.sync_settings_context(cx);

        self.overlay_focus.focus(window, cx);
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「Project · JDK & Maven」页。Maven 工具窗用。
    pub(crate) fn open_project_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.open_project_page(view_cx));
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「AI 与提交」页。Git 提交区的 AI 入口用它。
    pub(crate) fn open_ai_commit_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.open_ai_commit_page(view_cx));
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「Run Configurations」页。Run 面板的编辑入口用它。
    pub(crate) fn open_run_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| {
                view.open_run_configurations_page(view_cx)
            });
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「Git」页。Git Log 标题栏的设置入口用它。
    pub(crate) fn open_git_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.open_git_page(view_cx));
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「LSP」页。Run 面板的语言服务入口用它。
    pub(crate) fn open_language_service_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| {
                view.open_language_service_page(view_cx)
            });
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「Logs and Diagnostics」页。Run 面板的查看日志入口用它。
    pub(crate) fn open_log_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.open_logs_page(view_cx));
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「Keymap」页。Tools / Help 菜单的
    /// Keyboard Shortcuts 入口用它（对齐 Tauri
    /// `workbench.openKeyboardShortcuts` → `openSettingsDialog("keyboard")`）。
    pub(crate) fn open_keymap_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.open_keymap_page(view_cx));
        }
        cx.notify();
    }

    /// 打开设置覆盖层并直接落在「Updates」页，同时推进检查更新状态机。
    /// Help > Check for Updates 与 Updates 页按钮共用同一入口。
    pub(crate) fn open_update_check_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.settings_visible {
            self.toggle_settings(window, cx);
        }
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.open_updates_page_with_check(view_cx));
        }
        cx.notify();
    }
}
