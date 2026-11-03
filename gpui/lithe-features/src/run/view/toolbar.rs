//! 工具条、标题栏、批量选择动作与 more 弹出菜单。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, IconName, Selectable as _, Sizable as _, h_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, DismissEvent, EventEmitter as _, Focusable as _, FontWeight,
    InteractiveElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window,
    anchored, deferred, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, icon};

use super::model::RunExecution;
use super::state::SessionState;
use super::{RunPanel, RunPanelEvent, TOOLBAR_HEIGHT};

impl RunPanel {
    /// 隐藏按钮：面板不改工作台布局，只发出请求，由工作台收起底部 dock 并持久化。
    fn hide_panel(&mut self, cx: &mut Context<Self>) {
        self.close_more_menu();
        cx.emit(RunPanelEvent::HideRequested);
        cx.notify();
    }

    /// 勾选状态取反。批量模式下点行内复选框只改勾选，不切换当前选中配置。
    pub(super) fn toggle_checked(&mut self, id: &str, cx: &mut Context<Self>) {
        if !self.checked.remove(id) {
            self.checked.insert(id.to_string());
        }
        cx.notify();
    }

    /// 退出批量模式并清空勾选，对齐 macOS “Clear selection”。
    fn clear_checked(&mut self, cx: &mut Context<Self>) {
        self.checked.clear();
        self.batch_selection = false;
        cx.notify();
    }

    /// 批量运行：只启动勾选里尚未运行的配置，已在运行的服务不被重启。
    fn run_checked(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<String> = self.checked.iter().cloned().collect();
        for id in ids {
            if self.sessions.get(&id).is_some_and(SessionState::is_active) {
                continue;
            }
            self.start_configuration(id, cx);
        }
    }

    /// 批量停止：只停勾选里正在运行的配置。
    fn stop_checked(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<String> = self
            .checked
            .iter()
            .filter(|id| self.sessions.get(*id).is_some_and(SessionState::is_active))
            .cloned()
            .collect();
        for id in ids {
            self.stop_configuration(&id, cx);
        }
    }

    /// 勾选里是否有正在运行的配置，决定批量 Stop 是否可用。
    fn checked_has_running(&self) -> bool {
        self.checked
            .iter()
            .any(|id| self.sessions.get(id).is_some_and(SessionState::is_active))
    }

    /// 关闭 more 菜单并释放订阅。
    fn close_more_menu(&mut self) {
        self.more_menu = None;
        self._more_menu_subscription = None;
    }

    /// 打开 / 关闭标题栏 more 菜单。条目与 macOS `RunView.runOptionsMenu` 一致。
    fn toggle_more_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.more_menu.is_some() {
            self.close_more_menu();
            cx.notify();
            return;
        }

        let owner = cx.weak_entity();
        let rescan = owner.clone();
        let wraps = owner.clone();
        let batch = owner.clone();
        let clear = owner.clone();
        // 勾选状态先取值再进闭包：闭包是 `move` 的，直接读 `self` 会把面板整体移走。
        let wraps_currently_on = self.wrap_output;
        let batch_currently_on = self.batch_selection;

        let popup = PopupMenu::build(window, cx, move |menu, _window, _cx| {
            menu.min_w(px(220.0))
                .item(
                    PopupMenuItem::new(tr("Rescan services")).on_click(move |_, _window, cx| {
                        let _ = rescan.update(cx, |this, cx| this.reload(cx));
                    }),
                )
                .item(
                    PopupMenuItem::new(tr("Use soft wraps"))
                        .checked(wraps_currently_on)
                        .on_click(move |_, _window, cx| {
                            let _ = wraps.update(cx, |this, cx| {
                                this.wrap_output = !this.wrap_output;
                                cx.notify();
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Select configurations for batch actions"))
                        .checked(batch_currently_on)
                        .on_click(move |_, _window, cx| {
                            let _ = batch.update(cx, |this, cx| {
                                this.batch_selection = !this.batch_selection;
                                if !this.batch_selection {
                                    this.checked.clear();
                                }
                                cx.notify();
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Clear run output")).on_click(move |_, _window, cx| {
                        let _ = clear.update(cx, |this, cx| this.clear_output(cx));
                    }),
                )
        });

        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.close_more_menu();
                cx.notify();
            });

        // 菜单自己接管键盘：上下选择、回车执行、Esc 关闭。
        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }

        self.more_menu = Some((popup, position));
        self._more_menu_subscription = Some(subscription);
        cx.notify();
    }

    /// 36pt 动作工具条。按钮顺序对齐 macOS `RunView.runToolbar`：
    /// 批量勾选组 → Run/Restart → Stop → Rescan → 软换行 → 分隔线 →
    /// Console / 详情（图标 tab）→ 服务地址外链。
    fn render_toolbar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_running = self.selected_is_running();
        let selected_starting = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(|session| session.starting);
        let has_configurations = !self.configurations.is_empty();
        let checked_count = self.checked.len();
        let service_url = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .and_then(|session| session.service_url.clone());

        let mut toolbar = h_flex()
            .id("lithe-run-toolbar")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.0))
            .px(px(8.0))
            .h(px(TOOLBAR_HEIGHT))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider);

        // 批量组：勾选非空时出现，其余时候完全不占位，与 macOS 一致。
        if checked_count > 0 {
            toolbar = toolbar
                .child(
                    div()
                        .px(px(4.0))
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(format!("{checked_count} {}", tr("selected"))),
                )
                .child(
                    Button::new("lithe-run:run-checked")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Run))
                        .tooltip(tr(
                            "Run checked configurations without restarting running services",
                        ))
                        .disabled(!has_configurations || self.loading)
                        .on_click(cx.listener(move |this, _, _window, cx| this.run_checked(cx))),
                )
                .child(
                    Button::new("lithe-run:stop-checked")
                        .ghost()
                        .small()
                        .child(Icon::new(IconName::Square).with_size(px(14.0)))
                        .tooltip(tr("Stop selected"))
                        .disabled(!self.checked_has_running())
                        .on_click(cx.listener(move |this, _, _window, cx| this.stop_checked(cx))),
                )
                .child(
                    Button::new("lithe-run:clear-checked")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Close))
                        .tooltip(tr("Clear selection"))
                        .on_click(cx.listener(move |this, _, _window, cx| this.clear_checked(cx))),
                );
        }

        toolbar = toolbar
            .child(
                Button::new("lithe-run:run")
                    .ghost()
                    .small()
                    .icon(icon(if selected_running {
                        LitheIcon::Refresh
                    } else {
                        LitheIcon::Run
                    }))
                    .tooltip(tr(if selected_running { "Restart" } else { "Run" }))
                    .disabled(
                        !has_configurations || !self.can_start_selected() || selected_starting,
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        let id = this
                            .selected_id
                            .clone()
                            .or_else(|| this.default_id.clone())
                            .or_else(|| this.configurations.first().map(|item| item.id.clone()));
                        if let Some(id) = id {
                            if this.sessions.get(&id).is_some_and(SessionState::is_active) {
                                this.restart_configuration(id, cx);
                            } else {
                                this.start_configuration(id, cx);
                            }
                        } else {
                            this.run_selected(cx);
                        }
                    })),
            )
            .child(
                Button::new("lithe-run:stop")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Square).with_size(px(14.0)))
                    .tooltip(tr("Stop run"))
                    .disabled(!selected_running)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.stop_selected(cx);
                    })),
            )
            .child(
                Button::new("lithe-run:rescan")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::Refresh))
                    .tooltip(tr("Rescan services"))
                    .disabled(self.loading)
                    .on_click(cx.listener(move |this, _, _window, cx| this.reload(cx))),
            )
            .child(
                Button::new("lithe-run:wrap")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Menu).with_size(px(16.0)))
                    .tooltip(tr("Use soft wraps"))
                    .selected(self.wrap_output)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.wrap_output = !this.wrap_output;
                        this.emit(cx);
                        cx.notify();
                    })),
            )
            .child(div().flex_1());

        // 选中配置后出现 Console / 详情两个图标 tab；分隔线与 macOS 的
        // `ActionToolbar.separator` 对齐。
        if self.selected_configuration().is_some() {
            toolbar = toolbar
                .child(div().w(px(1.0)).h(px(20.0)).mx(px(6.0)).bg(tokens.divider))
                .child(
                    Button::new("lithe-run:console")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Terminal))
                        .tooltip(tr("Console"))
                        .selected(!self.show_details)
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.show_details = false;
                            cx.notify();
                        })),
                )
                .child(
                    Button::new("lithe-run:details")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Settings))
                        .tooltip(tr("Configuration details"))
                        .selected(self.show_details)
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.show_details = true;
                            cx.notify();
                        })),
                );
        }

        if let Some(url) = service_url {
            let label = SharedString::from(url.clone());
            toolbar = toolbar.child(
                Button::new("lithe-run:service-url")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::References))
                    .max_w(px(260.0))
                    .label(label)
                    .tooltip(tr("Open service in browser"))
                    .on_click(cx.listener(move |_, _, _window, _cx| {
                        let _ = lithe_platform::current().open_url(&url);
                    })),
            );
        }

        toolbar.into_any_element()
    }

    fn can_start_selected(&self) -> bool {
        self.selected_configuration()
            .is_some_and(|configuration| configuration.execution != RunExecution::Group)
            || self
                .configurations
                .iter()
                .any(|configuration| configuration.execution != RunExecution::Group)
    }

    /// 单层标题栏（完全对齐 Tauri `RunPane` Header：`▷ 运行 <项目名>` + 右侧操作按钮组）。
    pub(super) fn render_header(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_running = self.is_running();
        let project_name = self
            .root
            .as_ref()
            .and_then(|r| r.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let title_text = if project_name.is_empty() {
            tr("Run").to_string()
        } else {
            format!("{} {project_name}", tr("Run"))
        };

        h_flex()
            .id("lithe-run-header")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(4.0))
            .h(px(34.0))
            .pl(px(12.0))
            .pr(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                Icon::new(IconName::Play)
                    .with_size(px(14.0))
                    .text_color(tokens.success),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(title_text),
            )
            .child(div().flex_1())
            // 右侧操作图标组：运行/停止、重新扫描、滚动到底部、软换行、清空、收起
            .child(
                Button::new("lithe-run:play")
                    .ghost()
                    .small()
                    .child(
                        Icon::new(if is_running {
                            IconName::Square
                        } else {
                            IconName::Play
                        })
                        .with_size(px(13.0))
                        .text_color(if is_running {
                            tokens.warning
                        } else {
                            tokens.success
                        }),
                    )
                    .tooltip(tr(if is_running { "Stop run" } else { "Run" }))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if this.is_running() {
                            this.stop_selected(cx);
                        } else {
                            this.run_selected(cx);
                        }
                    })),
            )
            .child(
                Button::new("lithe-run:more-services")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Ellipsis).with_size(px(13.0)))
                    .tooltip(tr("Choose services"))
                    .on_click(cx.listener(|this, event: &ClickEvent, window, cx| {
                        // 点击处即菜单左上角；键盘触发的点击退回工具条右侧。
                        let position = match event {
                            ClickEvent::Mouse(mouse) => mouse.up.position,
                            _ => Default::default(),
                        };
                        this.toggle_more_menu(position, window, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:rescan")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::RotateCw).with_size(px(13.0)))
                    .tooltip(tr("Rescan services"))
                    .disabled(self.loading)
                    .on_click(cx.listener(|this, _, _window, cx| this.reload(cx))),
            )
            .child(
                Button::new("lithe-run:scroll-end")
                    .ghost()
                    .small()
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDownToLine).with_size(px(13.0)),
                    )
                    .tooltip(tr("Scroll to end"))
                    .on_click(cx.listener(move |this, _, _window, cx| this.scroll_to_latest(cx))),
            )
            .child(
                Button::new("lithe-run:wrap")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::WrapText))
                    .tooltip(tr("Use soft wraps"))
                    .selected(self.wrap_output)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.wrap_output = !this.wrap_output;
                        this.emit(cx);
                        cx.notify();
                    })),
            )
            .child(
                Button::new("lithe-run:clear")
                    .ghost()
                    .small()
                    .child(Icon::new(gpui_kit::assets::IconName::Trash).with_size(px(13.0)))
                    .tooltip(tr("Clear output"))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        let id = this.selected_id.clone().or_else(|| this.default_id.clone());
                        if let Some(id) = id {
                            if let Some(session) = this.sessions.get_mut(&id) {
                                session.clear();
                            }
                            this.console.reset();
                            this.console_follow_tail = true;
                            cx.notify();
                        }
                    })),
            )
            .child(
                Button::new("lithe-run:hide")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Minus).with_size(px(13.0)))
                    .tooltip(tr("Minimize"))
                    .on_click(cx.listener(|this, _, _window, cx| this.hide_panel(cx))),
            )
            .into_any_element()
    }

    /// 把「…」创建的 PopupMenu 渲染到窗口前景层。
    ///
    /// 之前菜单实体只创建不渲染，工具条菜单从未显示过。
    pub(super) fn with_floating_menu(
        &self,
        element: AnyElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some((popup, position)) = &self.more_menu else {
            return element;
        };
        deferred(
            anchored().position(*position).snap_to_window().child(
                div()
                    .occlude()
                    .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                        if this.more_menu.take().is_some() {
                            cx.notify();
                        }
                    }))
                    .child(popup.clone()),
            ),
        )
        .into_any_element()
    }
}
