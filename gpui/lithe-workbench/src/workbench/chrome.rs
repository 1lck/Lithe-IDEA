use gpui_kit::base::InteractiveElementExt as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, Hsla, InteractiveElement as _, IntoElement, MouseButton,
    ParentElement as _, RenderOnce as _, SharedString, StatefulInteractiveElement as _,
    Styled as _, WeakEntity, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use super::Workbench;
use super::dock::ToolWindow;
use super::overlays::PaletteMode;
use crate::layout;
use crate::top_bar::TopBar;

#[derive(Clone, Copy, Debug, Default)]
pub(super) struct TitleRowDragState {
    pub(super) should_move: bool,
}

impl Workbench {
    pub(super) fn render_title_row(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let drag_state = window.use_state(cx, |_, _| TitleRowDragState { should_move: false });

        div()
            .id("lithe-title-row")
            .flex()
            .items_center()
            .w_full()
            .h(px(LitheMetrics::TOP_BAR_HEIGHT))
            .flex_shrink_0()
            .on_mouse_up(
                MouseButton::Left,
                window.listener_for(&drag_state, |state, _, _, _| {
                    state.should_move = false;
                }),
            )
            .on_mouse_down(
                MouseButton::Left,
                window.listener_for(&drag_state, |state, _, _, _| {
                    state.should_move = true;
                }),
            )
            .on_mouse_move(window.listener_for(&drag_state, |state, _, window, _| {
                if state.should_move {
                    state.should_move = false;
                    window.start_window_move();
                }
            }))
            .on_double_click(|_, window, _| window.zoom_window())
            .child(self.render_top_bar(window, cx))
            .into_any_element()
    }

    pub(super) fn render_top_bar(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let menu_owner = owner.clone();
        let project_menu_owner = owner.clone();
        let branch_menu_owner = owner.clone();
        let settings_owner = owner.clone();
        let search_owner = owner.clone();
        let project_name = self.project_name();
        let compact_menu = self.menu_bar_visible.then(|| {
            div()
                .flex_1()
                .h_full()
                .min_w(px(0.))
                .child(self.menu_bar.clone())
                .into_any_element()
        });

        TopBar::new()
            .project_name(project_name)
            .project_root(self.project_root.clone())
            .branch(self.branch.clone())
            .compact_menu(compact_menu)
            .project_menu_open(self.project_menu_visible)
            .branch_menu_open(self.branch_menu_visible)
            .on_toggle_menu(move |window, cx| {
                let _ = menu_owner.update(cx, |this, cx| {
                    this.menu_bar_visible = true;
                    this.install_menus(cx);
                    this.menu_bar
                        .update(cx, |bar, bar_cx| bar.open_first(window, bar_cx));
                    cx.notify();
                });
            })
            .on_toggle_project_menu(move |window, cx| {
                let _ =
                    project_menu_owner.update(cx, |this, cx| this.toggle_project_menu(window, cx));
            })
            .on_toggle_branch_menu(move |window, cx| {
                let _ =
                    branch_menu_owner.update(cx, |this, cx| this.toggle_branch_menu(window, cx));
            })
            .on_settings(move |window, cx| {
                let _ = settings_owner.update(cx, |this, cx| this.toggle_settings(window, cx));
            })
            .on_search(move |window, cx| {
                let _ = search_owner.update(cx, |this, cx| {
                    this.show_tool(ToolWindow::Search, window, cx);
                });
            })
            .render(window, cx)
            .into_any_element()
    }

    /// 左侧 40pt 活动栏（完全对齐 Tauri 侧实现，见 `crate::activity_rail`）。
    pub(super) fn render_activity_rail(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let owner = cx.weak_entity();
        crate::activity_rail::render_activity_rail(
            self.left_visible,
            self.active_left,
            self.bottom_visible,
            self.active_bottom,
            tokens,
            owner,
        )
    }

    pub(super) fn render_right_activity_rail(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let owner = cx.weak_entity();
        // 未读徽标只统计非 success 的未读（对齐 Tauri NotificationsTrigger）。
        let has_unread = self.notification_unread_count() > 0;
        let tool_selected = |tool: ToolWindow| {
            !self.notifications_visible && self.right_visible && self.active_right == Some(tool)
        };

        let mut rail = div()
            .id("lithe-right-activity-rail")
            .flex()
            .flex_col()
            .items_center()
            .w(layout::RIGHT_ACTIVITY_RAIL_WIDTH)
            .h_full()
            .flex_shrink_0()
            .pt(layout::RIGHT_ACTIVITY_RAIL_PADDING_TOP)
            .gap(layout::RIGHT_ACTIVITY_RAIL_GAP)
            .bg(tokens.titlebar);

        rail = rail.child(right_rail_item(
            "extensions",
            icon(LitheIcon::Extensions),
            LitheMetrics::ACTIVITY_ICON_SIZE,
            tr("Extensions"),
            tool_selected(ToolWindow::Extensions),
            false,
            tokens,
            owner.clone(),
        ));
        rail = rail.child(right_rail_item(
            "notifications",
            icon(LitheIcon::Notifications),
            LitheMetrics::ACTIVITY_ICON_SIZE,
            tr("Notifications"),
            self.notifications_visible,
            has_unread,
            tokens,
            owner.clone(),
        ));
        rail = rail.child(right_rail_item(
            "agent",
            icon(LitheIcon::Agent),
            LitheMetrics::ACTIVITY_ICON_SIZE,
            tr("Agent"),
            tool_selected(ToolWindow::Agent),
            false,
            tokens,
            owner.clone(),
        ));
        rail = rail.child(right_rail_item(
            "maven",
            icon(LitheIcon::Maven),
            LitheMetrics::ACTIVITY_ICON_SIZE,
            tr("Maven"),
            tool_selected(ToolWindow::Maven),
            false,
            tokens,
            owner,
        ));

        rail.into_any_element()
    }

    pub(super) fn handle_right_activity_select(
        &mut self,
        id: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match id {
            "notifications" => self.toggle_notifications(window, cx),
            "extensions" => self.toggle_tool(ToolWindow::Extensions, window, cx),
            "agent" => self.toggle_tool(ToolWindow::Agent, window, cx),
            "maven" => self.toggle_tool(ToolWindow::Maven, window, cx),
            other => self.show_placeholder(rail_label(other), cx),
        }
    }

    pub(crate) fn handle_activity_select(
        &mut self,
        id: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match id {
            "project" | "files" => self.toggle_tool(ToolWindow::Project, window, cx),
            "changes" | "git" => self.toggle_tool(ToolWindow::Changes, window, cx),
            "search" => self.toggle_tool(ToolWindow::Search, window, cx),
            "pull-requests" => self.toggle_tool(ToolWindow::PullRequests, window, cx),
            "git-log" | "gitLog" => self.toggle_tool(ToolWindow::GitLog, window, cx),
            "local-history" => {
                if self.palette_visible && self.palette_mode == PaletteMode::History {
                    self.close_palette(cx);
                } else if self.active_tab_path().is_none() {
                    self.status_message = Some(SharedString::from(tr("No file open")));
                    cx.notify();
                } else {
                    self.open_local_history(window, cx);
                }
            }
            "terminal" => self.toggle_tool(ToolWindow::Terminal, window, cx),
            "agent" => self.toggle_tool(ToolWindow::Agent, window, cx),
            "references" => self.toggle_tool(ToolWindow::References, window, cx),
            "problems" | "diagnostics" => self.toggle_tool(ToolWindow::Problems, window, cx),
            "spring" => self.toggle_tool(ToolWindow::Spring, window, cx),
            "run" => self.toggle_tool(ToolWindow::Run, window, cx),
            "tests" => self.toggle_tool(ToolWindow::Tests, window, cx),
            "debug" => self.toggle_tool(ToolWindow::Debug, window, cx),
            "build-output" => self.toggle_tool(ToolWindow::BuildOutput, window, cx),
            other => self.show_placeholder(rail_label(other), cx),
        }
    }

    pub(super) fn toggle_notifications(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.notifications_visible {
            self.notifications_visible = false;
            self.active_notification = None;
        } else {
            // 打开面板即全部已读（对齐 Tauri 打开时的 markAllRead）。
            for entry in &mut self.notifications {
                entry.read = true;
            }
            self.notifications_visible = true;
            self.active_notification = None;
            self.right_visible = false;
            // 打开时聚焦搜索框（对齐 Tauri focusNotificationSearch）。
            if let Some(input) = self.notification_input.clone() {
                cx.defer_in(window, move |_, window, cx| {
                    input.update(cx, |state, cx| state.focus(window, cx));
                });
            }
        }
        cx.notify();
    }
}

fn right_rail_item(
    id: &'static str,
    icon: Icon,
    icon_size: f32,
    label: &'static str,
    selected: bool,
    unread: bool,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> AnyElement {
    let foreground = rail_foreground(tokens, selected);
    let button = div()
        .id(format!("lithe-right-activity-rail:activity:{id}"))
        .relative()
        .size(px(LitheMetrics::ACTIVITY_BUTTON_SIZE))
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(LitheMetrics::ACTIVITY_BUTTON_RADIUS))
        .when(selected, |this| this.bg(tokens.selection))
        .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
        .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
        .on_click(move |_, window, cx| {
            let _ = owner.update(cx, |this, cx| {
                this.handle_right_activity_select(id, window, cx)
            });
        })
        .child(icon.with_size(px(icon_size)).text_color(foreground));

    if unread {
        button
            .child(
                div()
                    .absolute()
                    .top(px(LitheMetrics::ACTIVITY_BADGE_TOP_OFFSET))
                    .right(px(LitheMetrics::ACTIVITY_BADGE_TRAILING_OFFSET))
                    .size(px(LitheMetrics::ACTIVITY_BADGE_SIZE))
                    .rounded_full()
                    .bg(tokens.error)
                    .border_1()
                    .border_color(tokens.titlebar),
            )
            .into_any_element()
    } else {
        button.into_any_element()
    }
}

fn rail_foreground(tokens: LitheTokens, selected: bool) -> Hsla {
    if selected {
        tokens.tool_window_selected_text
    } else {
        tokens.tool_window_button_text
    }
}

pub(super) fn rail_label(id: &'static str) -> &'static str {
    match id {
        "changes" => tr("Changes"),
        "search" => tr("Search"),
        "pull-requests" => tr("Pull Requests"),
        "git-log" => tr("Git Log"),
        "terminal" => tr("Terminal"),
        "agent" => tr("Agent"),
        "references" => tr("Usages"),
        "problems" => tr("Problems"),
        "spring" => tr("Spring Endpoints"),
        "run" => tr("Run"),
        "tests" => tr("Tests"),
        "debug" => tr("Debug"),
        "build-output" => tr("Build Output"),
        "database" => tr("Database"),
        "services" => tr("Services"),
        "extensions" => tr("Extensions"),
        "maven" => tr("Maven"),
        _ => tr("Tool Window"),
    }
}
