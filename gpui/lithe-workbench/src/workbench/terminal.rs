use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, AppContext as _, Context, DismissEvent, Entity, Focusable as _,
    FontWeight, InteractiveElement as _, IntoElement, MouseButton, MouseDownEvent,
    ParentElement as _, Pixels, Point, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, anchored, deferred, div, px,
};
use lithe_features::TerminalPanel;
use lithe_ui::components::prompt::PromptSpec;
use lithe_ui::i18n::tr;
use lithe_ui::current_tokens;

use super::Workbench;
use super::dock::{DockAnchor, ToolWindow};
use super::overlays::PromptAction;

/// 终端标签条高度。终端不使用 dock 的通用标题栏，这一行就是工具窗标题栏，
/// 因此高度对齐 macOS `TerminalView` toolbar 的 41pt。
pub(super) const TERMINAL_TAB_BAR_HEIGHT: f32 = 41.0;
/// 终端标签高度：对齐 macOS `TerminalView.swift` 的 28pt。
pub(super) const TERMINAL_TAB_HEIGHT: f32 = 28.0;
/// 终端标签条右侧动作按钮：与 macOS 工具栏图标按钮同一观感（24×24）。
pub(super) const TERMINAL_TAB_ACTION_SIZE: f32 = 24.0;
/// 终端会话上限。超过后 `+`、Profile 新建和 New Terminal 都禁用，
/// 避免无限开 PTY 拖垮进程。
pub(super) const MAX_TERMINAL_SESSIONS: usize = 16;

/// 终端分屏方向。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TerminalSplitAxis {
    Horizontal,
    Vertical,
}

/// 一个终端会话：稳定 id + 可重命名的显示标题 + 真正的 `TerminalPanel`。
///
/// `id` 形如 `terminal-1`，只递增不复用，避免关闭后新建的会话沿用旧标签
/// 的实体键（GPUI 元素 id、菜单目标）。`panel` 被 drop 时内部会关闭 PTY。
pub(crate) struct TerminalSession {
    pub id: SharedString,
    /// 用户重命名后的标题；未重命名时只作占位。
    pub title: SharedString,
    /// 未重命名时显示的基准标题（`Local` 或所选 shell 名）。
    ///
    /// 对齐 macOS `toolTabTitle`：同名会话按创建顺序追加 ` (2)`、` (3)`，
    /// 因此标题必须在渲染时按会话顺序计算，不能在建会话时固定死。
    pub base_title: SharedString,
    /// 是否被用户重命名；重命名后不再参与同名编号。
    pub custom_title: bool,
    pub panel: Entity<TerminalPanel>,
}

/// 计算某个会话在标签栏里的显示标题。
///
/// 与 macOS `TerminalFeatureModel.toolTabTitle` 一致：未重命名时用基准标题，
/// 之前已有同名会话时追加序号；重命名过的会话直接用用户标题。
fn terminal_tab_title(sessions: &[TerminalSession], index: usize) -> SharedString {
    let session = &sessions[index];
    if session.custom_title {
        return session.title.clone();
    }
    let prior_same = sessions[..index]
        .iter()
        .filter(|other| other.base_title == session.base_title)
        .count();
    SharedString::from(numbered_title(&session.base_title, prior_same))
}

/// 同名会话的序号后缀：第一个保持原名，之后追加 ` (2)`、` (3)`。
fn numbered_title(base: &str, prior_same: usize) -> String {
    if prior_same == 0 {
        base.to_string()
    } else {
        format!("{base} ({})", prior_same + 1)
    }
}

impl Workbench {
    /// 终端面板的标签条，完全对齐 Tauri `TerminalTabBar`。
    pub(super) fn render_terminal_tab_bar(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let has_split = self.terminal_split_secondary.is_some();
        let at_capacity = self.terminal_sessions.len() >= MAX_TERMINAL_SESSIONS;
        // shell 自行退出后移除对应标签页，对齐 macOS `handleTerminalSessionEnded`：
        // 退出事件只更新面板状态，标签归属由工作台在渲染期统一收尾。关闭是
        // 幂等的，重复 defer 不会重复删除。
        let exited: Vec<SharedString> = self
            .terminal_sessions
            .iter()
            .filter(|session| session.panel.read(cx).has_exited())
            .map(|session| session.id.clone())
            .collect();
        if !exited.is_empty() {
            cx.defer_in(window, move |this, window, cx| {
                for id in exited {
                    this.close_terminal_session(&id, window, cx);
                }
            });
        }
        // 高亮跟随键盘焦点：分屏时焦点可能在副 pane，而 `active_terminal`
        // 始终指向内容区的第一个 pane（见 `split_terminal` 的说明）。
        let highlighted = if self.terminal_focus_secondary {
            self.terminal_split_secondary
                .clone()
                .or_else(|| self.active_terminal.clone())
        } else {
            self.active_terminal.clone()
        };

        let mut tab_elements: Vec<AnyElement> =
            Vec::with_capacity(self.terminal_sessions.len());
        for (index, session) in self.terminal_sessions.iter().enumerate() {
            let active = highlighted.as_ref() == Some(&session.id);
            let display_title = terminal_tab_title(&self.terminal_sessions, index);
            let text_color = if active {
                tokens.tool_window_selected_text
            } else {
                tokens.secondary_text
            };

            let select_owner = cx.weak_entity();
            let select_id = session.id.clone();
            let context_owner = cx.weak_entity();
            let context_id = session.id.clone();
            let dots_owner = cx.weak_entity();
            let dots_id = session.id.clone();
            let close_owner = cx.weak_entity();
            let close_id = session.id.clone();

            tab_elements.push(
                h_flex()
                    .id(format!("lithe-terminal-tab:{}", session.id))
                    .flex_shrink_0()
                    .h(px(TERMINAL_TAB_HEIGHT))
                    .items_center()
                    .gap(px(6.))
                    .pl(px(8.))
                    .pr(px(3.))
                    .rounded(px(6.))
                    .when(active, |this| this.bg(tokens.selection))
                    .when(!active, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .on_click(move |_, window, cx| {
                        let _ = select_owner.update(cx, |this, cx| {
                            this.focus_terminal_tab(&select_id, window, cx);
                        });
                    })
                    .on_mouse_down(
                        MouseButton::Right,
                        move |event: &MouseDownEvent, window, cx| {
                            let _ = context_owner.update(cx, |this, cx| {
                                this.open_terminal_menu(
                                    context_id.clone(),
                                    event.position,
                                    window,
                                    cx,
                                );
                            });
                        },
                    )
                    .child(
                        div()
                            .text_size(px(13.0))
                            .text_color(text_color)
                            .max_w(px(180.0))
                            .truncate()
                            .child(display_title),
                    )
                    // `⋯`：与右键同一份会话菜单。用 div 而不是 Button，是为了
                    // 拿到按下位置给 `anchored` 定位（Button 的 on_click 没有坐标）。
                    .child(
                        div()
                            .id(format!("lithe-terminal-tab-menu:{}", session.id))
                            .flex()
                            .items_center()
                            .justify_center()
                            .w(px(16.0))
                            .h(px(16.0))
                            .rounded(px(3.0))
                            .cursor_pointer()
                            .hover(|s| s.bg(tokens.hover))
                            .on_mouse_down(
                                MouseButton::Left,
                                move |event: &MouseDownEvent, window, cx| {
                                    let _ = dots_owner.update(cx, |this, cx| {
                                        this.open_terminal_menu(
                                            dots_id.clone(),
                                            event.position,
                                            window,
                                            cx,
                                        );
                                    });
                                },
                            )
                            .child(
                                Icon::new(IconName::Ellipsis)
                                    .with_size(px(12.0))
                                    .text_color(text_color),
                            ),
                    )
                    .child(
                        Button::new(format!("lithe-terminal:close-tab:{}", session.id))
                            .ghost()
                            .with_size(px(16.0))
                            .rounded(px(3.0))
                            .child(
                                Icon::new(IconName::X)
                                    .with_size(px(10.0))
                                    .text_color(text_color),
                            )
                            .tooltip(tr("Close"))
                            .on_click(move |_, window, cx| {
                                let _ = close_owner.update(cx, |this, cx| {
                                    this.close_terminal_session(&close_id, window, cx);
                                });
                            }),
                    )
                    .into_any_element(),
            );
        }
        // 新建终端按钮 [+] 与 [▾] Profile 下拉菜单
        let new_owner = cx.weak_entity();
        let new_button = Button::new("lithe-terminal:new")
            .ghost()
            .with_size(px(24.0))
            .rounded(px(4.0))
            .child(Icon::new(IconName::Plus).with_size(px(16.0)))
            .tooltip(tr("New Terminal"))
            .disabled(at_capacity)
            .on_click(move |_, window, cx| {
                let _ = new_owner.update(cx, |this, cx| this.new_terminal(window, cx));
            });

        // Profile 下拉：列出本机**实际安装**的 shell（`installed_terminal_shells`
        // 已按可执行文件存在性过滤）。选中项是“用该 shell 新建一个会话”，
        // 与 macOS `shellMenuItems` / Tauri profile 新建语义一致，而不是把
        // 所有已存在会话的 shell 全部热切换。
        //
        // 探测壳层要逐个 `is_file` 扫 PATH，开销只能落在“菜单真正打开”这一刻：
        // 放在下面的 builder 里，每次展开扫一次；放在渲染路径上会变成每帧扫描。
        // 菜单项点击后弹层自动关闭，所以“Rescan installed shells”只需 notify，
        // 下次展开就会重新扫描。
        let profile_owner = cx.weak_entity();
        let profile_menu_owner = cx.weak_entity();

        let profile_dropdown = Button::new("lithe-terminal:profile-menu")
            .ghost()
            .with_size(px(24.0))
            .rounded(px(4.0))
            .child(Icon::new(IconName::ChevronDown).with_size(px(12.0)))
            .tooltip(tr("Choose terminal profile"))
            .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _window, _cx| {
                let installed_shells = lithe_features::installed_terminal_shells();
                // Popover 的展开由触发器外层的鼠标处理驱动，`Button::disabled`
                // 挡不住展开，所以上限禁用必须落在菜单项上，避免“点了没反应”。
                let mut menu = menu;

                // 系统默认 shell（不指定 id）。与 macOS 一致：未指定 shell 时
                // 标签基准标题是 `Local`，不会带上具体 shell 名。
                let default_owner = profile_owner.clone();
                menu = menu.item(
                    PopupMenuItem::new(tr("Default Terminal"))
                        .icon(Icon::new(IconName::Terminal))
                        .disabled(at_capacity)
                        .on_click(move |_, window, cx| {
                            let _ = default_owner.update(cx, |this, cx| {
                                this.new_terminal_with_shell(
                                    None,
                                    SharedString::from("Local"),
                                    window,
                                    cx,
                                );
                            });
                        }),
                );

                menu = menu.separator();

                for shell in installed_shells.iter() {
                    let shell_owner = profile_owner.clone();
                    let shell_id = shell.id.clone();
                    let shell_name = SharedString::from(shell.name.clone());
                    menu = menu.item(
                        PopupMenuItem::new(shell_name.clone())
                            .icon(Icon::new(IconName::Terminal))
                            .disabled(at_capacity)
                            .on_click(move |_, window, cx| {
                                let target = shell_id.clone();
                                let title = shell_name.clone();
                                let _ = shell_owner.update(cx, |this, cx| {
                                    this.new_terminal_with_shell(
                                        Some(target),
                                        title,
                                        window,
                                        cx,
                                    );
                                });
                            }),
                    );
                }

                let rescan_owner = profile_owner.clone();
                menu = menu.separator().item(
                    PopupMenuItem::new(tr("Rescan installed shells")).on_click(
                        move |_, _window, cx| {
                            let _ = rescan_owner.update(cx, |_this, cx| cx.notify());
                        },
                    ),
                );

                // 一个 shell 都没探测到时，对齐 macOS `shellDiscoveryError`
                // 给出一行禁用说明，而不是让菜单只剩“重新检测”。
                if installed_shells.is_empty() {
                    menu = menu.item(
                        PopupMenuItem::new(tr("No shells were detected on this machine."))
                            .disabled(true),
                    );
                }
                menu
            })
            // 弹出菜单需要记录打开状态：其它覆盖层（命令面板等）共用这个
            // 判定，保持与工作台既有菜单一致。
            .on_open_change({
                let menu_owner = profile_menu_owner;
                move |open, _window, cx| {
                    let open = *open;
                    let _ = menu_owner.update(cx, |this, cx| {
                        if this.terminal_profile_menu_open != open {
                            this.terminal_profile_menu_open = open;
                            cx.notify();
                        }
                    });
                }
            });

        let new_terminal_actions = h_flex()
            .flex_shrink_0()
            .items_center()
            .gap(px(1.0))
            .child(new_button)
            .child(profile_dropdown);

        // 右侧动作组，对齐 macOS 终端工具栏：一个「…」动作菜单 + 收起按钮。
        // 分屏是 GPUI 构建保留的额外能力（macOS 终端没有分屏），入口收进
        // 动作菜单，避免工具栏与 macOS 出现两套按钮。
        let can_split = has_split || !at_capacity;
        let active_id = self.active_terminal.clone();

        let actions_owner = cx.weak_entity();
        let actions_id = active_id.clone();
        let actions_menu = Button::new("lithe-terminal:actions")
            .ghost()
            .with_size(px(TERMINAL_TAB_ACTION_SIZE))
            .rounded(px(4.0))
            .icon(Icon::new(IconName::Ellipsis).with_size(px(16.0)))
            .tooltip(tr("Terminal actions"))
            .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _window, _cx| {
                let mut menu = menu;
                let Some(id) = actions_id.clone() else {
                    return menu.item(PopupMenuItem::new(tr("No terminals")).disabled(true));
                };

                let interrupt_owner = actions_owner.clone();
                let interrupt_id = id.clone();
                menu = menu.item(
                    // macOS 的 Interrupt 在会话存在时始终可点（退出即关标签），
                    // 这里不做额外禁用，避免与 macOS 出现两种可用性规则。
                    PopupMenuItem::new(tr("Interrupt")).on_click(move |_, _window, cx| {
                        let _ = interrupt_owner.update(cx, |this, cx| {
                            this.interrupt_terminal_session(&interrupt_id, cx);
                        });
                    }),
                );

                let restart_owner = actions_owner.clone();
                let restart_id = id.clone();
                menu = menu.item(PopupMenuItem::new(tr("Restart")).on_click(
                    move |_, window, cx| {
                        let _ = restart_owner.update(cx, |this, cx| {
                            this.restart_terminal_session(&restart_id, window, cx);
                        });
                    },
                ));

                let clear_owner = actions_owner.clone();
                let clear_id = id.clone();
                menu = menu.item(PopupMenuItem::new(tr("Clear")).on_click(
                    move |_, _window, cx| {
                        let _ = clear_owner.update(cx, |this, cx| {
                            this.clear_terminal_session(&clear_id, cx);
                        });
                    },
                ));

                menu = menu.separator();

                let split_right_owner = actions_owner.clone();
                menu = menu.item(
                    PopupMenuItem::new(tr("Split Terminal Right"))
                        .disabled(!can_split)
                        .on_click(move |_, window, cx| {
                            let _ = split_right_owner.update(cx, |this, cx| {
                                this.split_terminal(
                                    TerminalSplitAxis::Horizontal,
                                    window,
                                    cx,
                                );
                            });
                        }),
                );

                let split_down_owner = actions_owner.clone();
                menu = menu.item(
                    PopupMenuItem::new(tr("Split Terminal Down"))
                        .disabled(!can_split)
                        .on_click(move |_, window, cx| {
                            let _ = split_down_owner.update(cx, |this, cx| {
                                this.split_terminal(TerminalSplitAxis::Vertical, window, cx);
                            });
                        }),
                );

                if has_split {
                    let close_split_owner = actions_owner.clone();
                    menu = menu.item(PopupMenuItem::new(tr("Close Split")).on_click(
                        move |_, window, cx| {
                            let _ = close_split_owner.update(cx, |this, cx| {
                                this.close_terminal_split(window, cx);
                            });
                        },
                    ));
                }

                menu = menu.separator();

                let close_owner = actions_owner.clone();
                let close_id = id;
                menu.item(PopupMenuItem::new(tr("Close Terminal")).on_click(
                    move |_, window, cx| {
                        let _ = close_owner.update(cx, |this, cx| {
                            this.close_terminal_session(&close_id, window, cx);
                        });
                    },
                ))
            });

        let hide_owner = cx.weak_entity();
        let right_actions = h_flex()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.0))
            .child(actions_menu)
            .child(
                Button::new("lithe-terminal:hide")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(IconName::Minus).with_size(px(16.0)))
                    .tooltip(tr("Minimize Terminal"))
                    .on_click(move |_, _window, cx| {
                        let _ = hide_owner.update(cx, |this, cx| {
                            this.set_dock_visible(DockAnchor::Bottom, false, cx);
                        });
                    }),
            );

        h_flex()
            .id("lithe-terminal-tab-bar")
            .w_full()
            .h(px(TERMINAL_TAB_BAR_HEIGHT))
            .flex_shrink_0()
            .items_center()
            .justify_between()
            .pl(px(12.))
            .pr(px(8.))
            // 与通用工具窗标题栏同底色（macOS 终端 toolbar 用 toolHeader）。
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            // 工具窗标题，对齐 macOS 终端工具栏左侧的 "Terminal" 标签。
            .child(
                div()
                    .flex_shrink_0()
                    .pr(px(16.))
                    .text_size(px(13.))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Terminal")),
            )
            .child(
                h_flex()
                    .flex_1()
                    .min_w(px(0.))
                    .items_center()
                    // 标签过多时横向滚动，不挤压右侧动作按钮。
                    .child(
                        div()
                            .id("lithe-terminal-tab-scroll")
                            .flex_1()
                            .min_w(px(0.))
                            .overflow_x_scroll()
                            // 与 macOS 一致：`+` 和 shell 下拉跟在标签列表末尾，
                            // 随标签一起滚动，而不是固定在最右侧。
                            .child(
                                h_flex()
                                    .items_center()
                                    .gap(px(4.))
                                    .children(tab_elements)
                                    .child(new_terminal_actions),
                            ),
                    ),
            )
            .child(right_actions)
            .into_any_element()
    }

    /// 终端内容视图：单 pane、分屏双 pane 或空状态。
    pub(super) fn render_terminal_content(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(primary) = self.active_terminal_panel() else {
            return self.render_terminal_empty_state(cx);
        };

        // 分屏 pane 必须和主 pane 是不同的会话；`active_terminal` 被关闭后
        // 可能短暂指向 secondary，此时按单 pane 渲染，避免同一会话画两遍。
        let secondary = self
            .terminal_split_secondary
            .clone()
            .filter(|id| Some(id) != self.active_terminal.as_ref())
            .and_then(|id| {
                self.terminal_sessions
                    .iter()
                    .find(|session| session.id == id)
                    .map(|session| session.panel.clone())
            });

        let Some(secondary) = secondary else {
            // 工具窗正文容器是普通 `div`（不是 flex），这里必须用 `size_full`
            // 才能把高度确定的剩余空间交给 `TerminalPanel` 的 100% 高度。
            return div()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary)
                .into_any_element();
        };

        let tokens = current_tokens(cx);
        let primary_pane = div()
            .flex_1()
            .min_w(px(0.))
            .min_h(px(0.))
            .child(primary);
        let secondary_pane = div()
            .flex_1()
            .min_w(px(0.))
            .min_h(px(0.))
            .child(secondary);

        match self.terminal_split_axis {
            TerminalSplitAxis::Horizontal => h_flex()
                .items_stretch()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary_pane)
                .child(div().flex_shrink_0().w(px(1.)).bg(tokens.divider))
                .child(secondary_pane)
                .into_any_element(),
            TerminalSplitAxis::Vertical => v_flex()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary_pane)
                .child(div().flex_shrink_0().h(px(1.)).bg(tokens.divider))
                .child(secondary_pane)
                .into_any_element(),
        }
    }

    /// 没有任何会话时的空状态：提示 + New Terminal。
    fn render_terminal_empty_state(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let new_owner = cx.weak_entity();
        v_flex()
            .size_full()
            .min_w(px(0.))
            .min_h(px(0.))
            .items_center()
            .justify_center()
            .gap(px(8.))
            .child(
                Icon::new(IconName::Terminal)
                    .with_size(px(34.0))
                    .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(tr("No terminals")),
            )
            .child(
                Button::new("lithe-terminal:empty-new")
                    .ghost()
                    .rounded(px(4.0))
                    .label(tr("New Terminal"))
                    .on_click(move |_, window, cx| {
                        let _ = new_owner.update(cx, |this, cx| this.new_terminal(window, cx));
                    }),
            )
            .into_any_element()
    }

    /// 会话右键/`⋯` 菜单。挂在工作台根节点，避免被工具窗的 overflow 裁切。
    pub(super) fn render_terminal_menu(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (_, position) = self.terminal_menu.as_ref()?;
        let popup = self.terminal_menu_popup.clone()?;
        let position = *position;
        Some(
            deferred(
                anchored().position(position).snap_to_window().child(
                    div()
                        .occlude()
                        .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                            this.close_terminal_menu(cx);
                        }))
                        .child(popup),
                ),
            )
            .into_any_element(),
        )
    }

    /// 打开某个会话的动作菜单（右键与 `⋯` 共用）。
    fn open_terminal_menu(
        &mut self,
        id: SharedString,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(panel) = self
            .terminal_sessions
            .iter()
            .find(|session| session.id == id)
            .map(|session| session.panel.clone())
        else {
            return;
        };
        // 菜单项可用性在打开时取值：`running` 只用来决定 Interrupt 是否可用
        // （Restart 在会话退出后仍要通过它复活，见下方注释）。
        let running = panel.read(cx).is_running();
        // 重命名输入框回显的是标签上当前显示的标题（含同名序号），
        // 与用户看到的文字一致。
        let title = self
            .terminal_sessions
            .iter()
            .position(|session| session.id == id)
            .map(|index| terminal_tab_title(&self.terminal_sessions, index))
            .unwrap_or_default();

        let owner = cx.weak_entity();
        let target = id.clone();
        let popup = PopupMenu::build(window, cx, move |mut menu, _window, _cx| {
            let rename_owner = owner.clone();
            let rename_id = target.clone();
            let rename_title = title.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Rename Terminal")).on_click(move |_, window, cx| {
                    let _ = rename_owner.update(cx, |this, cx| {
                        this.terminal_rename_target = Some(rename_id.clone());
                        this.open_prompt(
                            PromptSpec::new(tr("Rename Terminal"), tr("Terminal name"))
                                .initial(rename_title.clone())
                                .confirm_label(tr("Rename")),
                            PromptAction::RenameTerminal,
                            window,
                            cx,
                        );
                    });
                }),
            );

            // Restart 不按 `running` 禁用：会话退出后（`terminal_id` 已清空）
            // 它是唯一能让该标签重新拉起 shell 的入口。
            let restart_owner = owner.clone();
            let restart_id = target.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Restart")).on_click(move |_, window, cx| {
                    let _ = restart_owner.update(cx, |this, cx| {
                        this.restart_terminal_session(&restart_id, window, cx);
                    });
                }),
            );

            let interrupt_owner = owner.clone();
            let interrupt_id = target.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Interrupt"))
                    .disabled(!running)
                    .on_click(move |_, _window, cx| {
                        let _ = interrupt_owner.update(cx, |this, cx| {
                            this.interrupt_terminal_session(&interrupt_id, cx);
                        });
                    }),
            );

            let clear_owner = owner.clone();
            let clear_id = target.clone();
            menu = menu.item(PopupMenuItem::new(tr("Clear")).on_click(
                move |_, _window, cx| {
                    let _ = clear_owner.update(cx, |this, cx| {
                        this.clear_terminal_session(&clear_id, cx);
                    });
                },
            ));

            menu = menu.separator();

            let close_owner = owner.clone();
            let close_id = target.clone();
            menu.item(PopupMenuItem::new(tr("Close Terminal")).on_click(
                move |_, window, cx| {
                    let _ = close_owner.update(cx, |this, cx| {
                        this.close_terminal_session(&close_id, window, cx);
                    });
                },
            ))
        });

        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }

        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.close_terminal_menu(cx);
            });

        self.terminal_menu = Some((id, position));
        self.terminal_menu_popup = Some(popup);
        self._terminal_menu_subscription = Some(subscription);
        cx.notify();
    }

    fn close_terminal_menu(&mut self, cx: &mut Context<Self>) {
        if self.terminal_menu.take().is_some() {
            self.terminal_menu_popup = None;
            self._terminal_menu_subscription = None;
            cx.notify();
        }
    }

    /// 创建一个新的终端会话并设为 `active`。达到上限时返回当前 active id。
    ///
    /// `base_title` 是重命名前的标签标题，与 macOS 一致：默认新建会话为
    /// `Local`，从 shell 菜单显式选择时用 shell 名；同名会话在渲染时自动
    /// 追加序号，所以这里不写死 `Terminal N`。
    pub(super) fn new_terminal_session(
        &mut self,
        shell: Option<String>,
        base_title: SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> SharedString {
        if self.terminal_sessions.len() >= MAX_TERMINAL_SESSIONS {
            return self.active_terminal.clone().unwrap_or_default();
        }

        let index = self.terminal_next_id;
        self.terminal_next_id += 1;
        let id = SharedString::from(format!("terminal-{index}"));

        let root = self.project_root.clone().unwrap_or_default();
        let panel = cx.new(|panel_cx| TerminalPanel::new(root, window, panel_cx));
        let font_size = self.settings.terminal_font_size;
        let scrollback = self.settings.terminal_scrollback;
        let shell = shell.or_else(|| self.settings.terminal_default_shell.clone());
        // 关闭回调：标签菜单和画布右键菜单的 Close Terminal 都回到工作台
        // 唯一的关闭路径（移除会话、修正 active、最后一个会话时收起工具窗）。
        let close_owner = cx.weak_entity();
        let close_id = id.clone();
        panel.update(cx, |panel, panel_cx| {
            panel.set_preferences(font_size, scrollback, window, panel_cx);
            if shell.is_some() {
                // PTY 还没启动，这里只是记下 shell，首次渲染时按它创建。
                panel.set_shell(shell, window, panel_cx);
            }
            panel.set_close_handler(std::rc::Rc::new(move |window, cx| {
                let _ = close_owner.update(cx, |this, cx| {
                    this.close_terminal_session(&close_id, window, cx);
                });
            }));
        });

        let title = base_title.clone();
        self.terminal_sessions.push(TerminalSession {
            id: id.clone(),
            title,
            base_title,
            custom_title: false,
            panel,
        });
        self.active_terminal = Some(id.clone());
        self.terminal_focus_secondary = false;
        cx.notify();
        id
    }

    /// 关闭一个会话：drop panel 会结束 PTY；同时修正 active 与分屏状态。
    pub(super) fn close_terminal_session(
        &mut self,
        id: &SharedString,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(index) = self
            .terminal_sessions
            .iter()
            .position(|session| &session.id == id)
        else {
            return;
        };

        // 与 macOS `TerminalFeatureModel.closeSession` 一致：关闭当前标签后
        // 优先激活紧邻的下一个，没有则退回上一个。分屏时跳过 secondary，
        // 否则内容区会把同一个会话画成两个 pane。
        let secondary = self.terminal_split_secondary.clone();
        let is_usable = |session: &TerminalSession| Some(&session.id) != secondary.as_ref();
        let fallback = self.terminal_sessions[(index + 1)..]
            .iter()
            .find(|session| is_usable(session))
            .or_else(|| {
                index
                    .checked_sub(1)
                    .and_then(|previous| self.terminal_sessions.get(previous))
                    .filter(|session| is_usable(session))
            })
            .or_else(|| {
                self.terminal_sessions
                    .iter()
                    .find(|session| is_usable(session))
            })
            .map(|session| session.id.clone());

        self.terminal_sessions.remove(index);

        if self.terminal_split_secondary.as_ref() == Some(id) {
            self.terminal_split_secondary = None;
            self.terminal_focus_secondary = false;
        }

        if self.active_terminal.as_ref() == Some(id) {
            self.active_terminal = fallback;
            self.terminal_focus_secondary = false;
        }

        // 只剩一个会话时没有可分的另一半，直接清掉分屏状态。
        if self.terminal_sessions.len() <= 1 {
            self.terminal_split_secondary = None;
            self.terminal_focus_secondary = false;
        }

        if self.terminal_rename_target.as_ref() == Some(id) {
            self.terminal_rename_target = None;
        }

        if self.terminal_sessions.is_empty() {
            self.active_terminal = None;
            self.terminal_split_secondary = None;
            self.terminal_focus_secondary = false;
            // 最后一个终端关闭时收起整个工具窗（对齐 macOS/Tauri）。
            self.set_dock_visible(DockAnchor::Bottom, false, cx);
        }

        cx.notify();
    }

    /// 重命名会话的显示标题。调用方负责 `cx.notify()`。
    ///
    /// 重命名后不再参与「同名会话追加序号」的计算，避免用户改过的标题被
    /// 后续新建的同名会话挤成 `xxx (2)`。
    pub(super) fn rename_terminal_session(&mut self, id: &SharedString, title: SharedString) {
        if let Some(session) = self
            .terminal_sessions
            .iter_mut()
            .find(|session| &session.id == id)
        {
            session.title = title;
            session.custom_title = true;
        }
    }

    pub(super) fn restart_terminal_session(
        &mut self,
        id: &SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(panel) = self
            .terminal_sessions
            .iter()
            .find(|session| &session.id == id)
            .map(|session| session.panel.clone())
        {
            panel.update(cx, |panel, panel_cx| panel.restart(window, panel_cx));
        }
    }

    pub(super) fn interrupt_terminal_session(
        &mut self,
        id: &SharedString,
        cx: &mut Context<Self>,
    ) {
        if let Some(panel) = self
            .terminal_sessions
            .iter()
            .find(|session| &session.id == id)
            .map(|session| session.panel.clone())
        {
            panel.update(cx, |panel, panel_cx| panel.interrupt(panel_cx));
        }
    }

    pub(super) fn clear_terminal_session(&mut self, id: &SharedString, cx: &mut Context<Self>) {
        if let Some(panel) = self
            .terminal_sessions
            .iter()
            .find(|session| &session.id == id)
            .map(|session| session.panel.clone())
        {
            panel.update(cx, |panel, panel_cx| panel.clear(panel_cx));
        }
    }

    /// 切换标签：主 pane 的标签会改写 `active_terminal`；分屏 pane 的标签
    /// 只移动键盘焦点（`active_terminal` 仍是内容区第一个 pane）。
    pub(super) fn focus_terminal_tab(
        &mut self,
        id: &SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(panel) = self
            .terminal_sessions
            .iter()
            .find(|session| &session.id == id)
            .map(|session| session.panel.clone())
        else {
            return;
        };

        if self.terminal_split_secondary.as_ref() == Some(id) {
            self.terminal_focus_secondary = true;
        } else {
            self.active_terminal = Some(id.clone());
            self.terminal_focus_secondary = false;
        }

        panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        cx.notify();
    }

    /// 分屏：保留当前 active 作为主 pane，新会话作为第二个 pane。
    pub(super) fn split_terminal(
        &mut self,
        axis: TerminalSplitAxis,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_tool(ToolWindow::Terminal, window, cx);
        self.terminal_split_axis = axis;

        // 已有分屏时先关掉旧的，避免“再分一次”变成三个会话。
        if self.terminal_split_secondary.is_some() {
            self.close_terminal_split(window, cx);
        }
        if self.terminal_sessions.len() >= MAX_TERMINAL_SESSIONS {
            return;
        }

        let primary = self.active_terminal.clone();
        let new_id = self.new_terminal_session(None, SharedString::from("Local"), window, cx);
        let Some(primary) = primary else {
            // 理论上 `show_tool` 已保证至少一个会话；这里只做兜底。
            self.terminal_split_secondary = None;
            self.terminal_focus_secondary = false;
            cx.notify();
            return;
        };

        // `new_terminal_session` 会把 active 指向新会话，这里恢复主 pane。
        self.active_terminal = Some(primary);
        self.terminal_split_secondary = Some(new_id.clone());
        self.terminal_focus_secondary = true;
        if let Some(panel) = self
            .terminal_sessions
            .iter()
            .find(|session| session.id == new_id)
            .map(|session| session.panel.clone())
        {
            panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        }
        cx.notify();
    }

    pub(super) fn close_terminal_split(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.terminal_split_secondary.clone() else {
            return;
        };
        self.terminal_split_secondary = None;
        self.terminal_focus_secondary = false;
        self.close_terminal_session(&id, window, cx);
        cx.notify();
    }

    /// 保证至少有一个会话：打开 Terminal 工具窗时调用。
    pub(super) fn ensure_terminal_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.terminal_sessions.is_empty() {
            self.new_terminal_session(None, SharedString::from("Local"), window, cx);
        }
    }

    pub(super) fn active_terminal_panel(&self) -> Option<Entity<TerminalPanel>> {
        self.primary_terminal_session()
            .map(|session| session.panel.clone())
    }

    /// 内容区第一个 pane 对应的会话。
    pub(super) fn primary_terminal_session(&self) -> Option<&TerminalSession> {
        let id = self.active_terminal.as_ref()?;
        self.terminal_sessions
            .iter()
            .find(|session| &session.id == id)
    }

    /// Terminal > New Terminal：新建一个会话（不是分屏）。
    pub(super) fn new_terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // `show_tool` 在没有会话时已经补建了一个并聚焦它；此时再新建会多出
        // 一个空标签，所以只在原本已有会话时追加。
        let had_sessions = !self.terminal_sessions.is_empty();
        self.show_tool(ToolWindow::Terminal, window, cx);
        if had_sessions {
            self.new_terminal_with_shell(None, SharedString::from("Local"), window, cx);
        }
    }

    /// 新建会话并把键盘焦点交给它。
    ///
    /// Profile 下拉也走这里：菜单项点击后弹层会把焦点还给触发器，若新建后
    /// 不主动聚焦，用户下一键输入会落不到终端里。`split_terminal` 不走这条
    /// 路径，它自己决定聚焦新分屏 pane。
    fn new_terminal_with_shell(
        &mut self,
        shell: Option<String>,
        base_title: SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.terminal_sessions.len() >= MAX_TERMINAL_SESSIONS {
            return;
        }
        let id = self.new_terminal_session(shell, base_title, window, cx);
        self.focus_terminal_tab(&id, window, cx);
    }

    /// Zoom 系列的目标判定：底部终端工具窗当前可见且活跃时缩放终端字号
    /// （对齐 Tauri `zoomIn` 按焦点目标分发到 editor/terminal 的语义），
    /// 否则缩放编辑器字号。
    pub(super) fn zoom_prefers_terminal(&self) -> bool {
        self.bottom_visible && self.active_bottom == Some(ToolWindow::Terminal)
    }

    /// 按 `delta` 调整终端字号（Zoom In/Out 在终端工具窗活跃时的目标，
    /// 对齐 Tauri `zoomIn("terminal")`）。
    pub(super) fn nudge_terminal_zoom(
        &mut self,
        delta: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.nudge_terminal_font_size(delta) {
            self.save_settings(cx);
            self.apply_terminal_preferences(window, cx);
        }
    }

    /// 重置终端字号（Zoom Reset 在终端工具窗活跃时的目标）。
    pub(super) fn reset_terminal_zoom(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.reset_terminal_font_size() {
            self.save_settings(cx);
            self.apply_terminal_preferences(window, cx);
        }
    }

    /// 把字号与回滚行数同步到所有会话。
    pub(super) fn apply_terminal_preferences(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let font_size = self.settings.terminal_font_size;
        let scrollback = self.settings.terminal_scrollback;
        for session in &self.terminal_sessions {
            session.panel.update(cx, |panel, panel_cx| {
                panel.set_preferences(font_size, scrollback, window, panel_cx);
            });
        }
        cx.notify();
    }

    /// 把所有会话切换到指定 shell（会重建 PTY）。
    ///
    /// 新的 Profile 下拉改为“新建会话”，这条入口保留给需要统一换 shell
    /// 的场景；`set_shell` 对相同值 no-op，不会误杀运行中的会话。
    #[allow(dead_code)]
    pub(super) fn apply_terminal_shell(
        &mut self,
        shell: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        for session in &self.terminal_sessions {
            let shell = shell.clone();
            session.panel.update(cx, |panel, panel_cx| {
                panel.set_shell(shell, window, panel_cx);
            });
        }
        cx.notify();
    }

    /// 把工作区根目录同步到所有会话（切换项目时重建 PTY 的工作目录）。
    pub(super) fn sync_terminal_roots(
        &mut self,
        root: std::path::PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        for session in &self.terminal_sessions {
            let root = root.clone();
            session.panel.update(cx, |panel, panel_cx| {
                panel.set_root(root, window, panel_cx);
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::numbered_title;

    #[test]
    fn terminal_titles_append_index_for_repeated_base() {
        // 对齐 macOS `toolTabTitle`：第一个不加后缀，第二个起追加序号。
        assert_eq!(numbered_title("Local", 0), "Local");
        assert_eq!(numbered_title("Local", 1), "Local (2)");
        assert_eq!(numbered_title("zsh", 2), "zsh (3)");
    }
}
