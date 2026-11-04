//! 标题栏、动作工具条、批量选择动作与 more 弹出菜单。
//!
//! 逐项对齐 macOS `RunView`：
//! - `toolWindowHeader`：`Run` 标题 + more 菜单 + 隐藏按钮，41pt；
//! - `runToolbar`：批量组 → Run/Restart → Stop → Rescan → 软换行 →
//!   分隔线 → Console / Configuration details → 服务地址，36pt；
//! - `runOptionsMenu`：Rescan services / Use soft wraps /
//!   Select configurations for batch actions / Clear run output。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::{h_flex, Disableable as _, Icon, Selectable as _, Sizable as _};
use gpui_kit::{
    anchored, deferred, div, px, AnyElement, ClickEvent, Context, DismissEvent,
    Focusable as _, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, Styled as _, Window,
};
use lithe_ui::i18n::tr;
use lithe_ui::{icon, LitheIcon, LitheMetrics, LitheTokens};

use super::state::SessionState;
use super::{RunPanel, RunPanelEvent, HEADER_HEIGHT, TOOLBAR_HEIGHT};

/// 标题栏与工具条图标按钮的点击区域。对齐 macOS `toolbarIconButtonSize`。
const HEADER_BUTTON_SIZE: f32 = 26.0;
const TOOLBAR_ICON_SIZE: f32 = 16.0;

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
        let clear_enabled = self.selected_has_output();

        let popup = PopupMenu::build(window, cx, move |menu, _window, _cx| {
            menu.min_w(px(240.0))
                .item(
                    PopupMenuItem::new(tr("Rescan services")).on_click(move |_, _window, cx| {
                        let _ = rescan.update(cx, |this, cx| this.rescan(cx));
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
                    PopupMenuItem::new(tr("Clear run output"))
                        .disabled(!clear_enabled)
                        .on_click(move |_, _window, cx| {
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

    /// 41pt 标题栏：`Run` + more 菜单 + 隐藏按钮。
    ///
    /// 对齐 macOS `RunView.toolWindowHeader`；运行控制全部在下方工具条，
    /// 标题栏不再重复放置播放/停止按钮。
    pub(super) fn render_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        h_flex()
            .id("lithe-run-header")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(8.0))
            .h(px(HEADER_HEIGHT))
            .pl(px(12.0))
            .pr(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(13.0))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Run")),
            )
            .child(div().flex_1())
            .child(
                Button::new("lithe-run:more")
                    .ghost()
                    .with_size(px(HEADER_BUTTON_SIZE))
                    .child(
                        Icon::new(IconName::EllipsisVertical)
                            .with_size(px(TOOLBAR_ICON_SIZE))
                            .text_color(tokens.tool_window_button_text),
                    )
                    .tooltip(tr("More Run actions"))
                    .accessibility_label(tr("More Run actions"))
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        let position = match event {
                            ClickEvent::Mouse(mouse) => mouse.up.position,
                            _ => Default::default(),
                        };
                        this.toggle_more_menu(position, window, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:hide")
                    .ghost()
                    .with_size(px(HEADER_BUTTON_SIZE))
                    .child(
                        Icon::new(IconName::Minus)
                            .with_size(px(TOOLBAR_ICON_SIZE))
                            .text_color(tokens.tool_window_button_text),
                    )
                    .tooltip(tr("Hide Run tool window"))
                    .accessibility_label(tr("Hide Run tool window"))
                    .on_click(cx.listener(|this, _, _window, cx| this.hide_panel(cx))),
            )
            .into_any_element()
    }

    /// 36pt 动作工具条。按钮顺序与可用性对齐 macOS `RunView.runToolbar`。
    pub(super) fn render_toolbar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_running = self.selected_is_running();
        let selected_starting = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(|session| session.starting);
        let has_configurations = self.has_runnable_configurations();
        let checked_count = self.checked.len();
        let selected_runnable = self.selected_runnable_configuration().is_some();
        let service_url = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .filter(|session| session.running)
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
                            .or_else(|| {
                                this.runnable_configurations()
                                    .first()
                                    .map(|item| item.id.clone())
                            });
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
                    .on_click(cx.listener(move |this, _, _window, cx| this.rescan(cx))),
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
            );

        // 选中可运行配置后出现 Console / Configuration details 两个 tab；
        // 分隔线与 macOS 的 `ActionToolbar.separator` 对齐。
        if selected_runnable {
            toolbar = toolbar
                .child(div().w(px(1.0)).h(px(20.0)).mx(px(6.0)).bg(tokens.divider))
                .child(
                    Button::new("lithe-run:console")
                        .ghost()
                        .small()
                        .h(px(28.0))
                        .icon(icon(LitheIcon::Terminal))
                        .label(tr("Console"))
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
                        .h(px(28.0))
                        .icon(icon(LitheIcon::Settings))
                        .label(tr("Configuration details"))
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
                    .with_size(px(HEADER_BUTTON_SIZE))
                    .child(
                        Icon::new(IconName::SquareArrowOutUpRight)
                            .with_size(px(TOOLBAR_ICON_SIZE))
                            .text_color(tokens.tool_window_button_text),
                    )
                    .tooltip(label)
                    .on_click(cx.listener(move |_, _, _window, _cx| {
                        let _ = lithe_platform::current().open_url(&url);
                    })),
            );
        }

        toolbar.into_any_element()
    }

    fn can_start_selected(&self) -> bool {
        self.selected_configuration().is_some_and(|configuration| {
            configuration.execution != super::model::RunExecution::Group
        }) || self.has_runnable_configurations()
    }

    /// 把「…」创建的 PopupMenu 渲染到窗口前景层。
    ///
    /// 菜单必须叠加在面板之上，而不是替换面板：之前这里直接返回菜单的
    /// `deferred` 元素，打开菜单时整个 Run 面板会从布局中消失（表现为
    /// 点击「更多」后下半区塌陷），关闭菜单后才重新出现。
    pub(super) fn with_floating_menu(
        &self,
        element: AnyElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some((popup, position)) = &self.more_menu else {
            return element;
        };
        div()
            .relative()
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .child(element)
            .child(deferred(
                anchored().position(*position).snap_to_window().child(
                    div()
                        .occlude()
                        .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                            if this.more_menu.is_some() {
                                this.close_more_menu();
                                cx.notify();
                            }
                        }))
                        .child(popup.clone()),
                ),
            ))
            .into_any_element()
    }
}
