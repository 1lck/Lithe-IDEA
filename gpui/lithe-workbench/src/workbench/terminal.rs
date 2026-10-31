use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, AppContext as _, Context, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use lithe_features::TerminalPanel;
use lithe_ui::current_tokens;
use lithe_ui::i18n::tr;

use super::Workbench;
use super::dock::{DockAnchor, ToolWindow};

/// 终端标签条高度：对齐 Tauri `h-8`（32px）。
pub(super) const TERMINAL_TAB_BAR_HEIGHT: f32 = 32.0;
/// 终端标签高度：对齐 Tauri `h-6`（24px）。
pub(super) const TERMINAL_TAB_HEIGHT: f32 = 24.0;
/// 终端标签条右侧动作按钮：Tauri `size="icon-xs"`（24×24）。
pub(super) const TERMINAL_TAB_ACTION_SIZE: f32 = 24.0;

/// 终端分屏方向。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TerminalSplitAxis {
    Horizontal,
    Vertical,
}

impl Workbench {
    /// 终端面板的标签条，完全对齐 Tauri `TerminalTabBar`。
    pub(super) fn render_terminal_tab_bar(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let split_owner = cx.weak_entity();
        let hide_owner = cx.weak_entity();
        let has_split = self.terminal_secondary.is_some();
        let project_name = self.project_name().to_string();
        // 活动标签跟随焦点的那个终端；分屏时副终端获得焦点才算激活。
        let secondary_active = has_split && self.terminal_focus_secondary;

        // 每个真实终端会话一个标签：主终端始终存在，分屏终端在分屏后出现。
        // 点击标签切焦点，点击 ✕ 关闭该标签（只剩一个标签时收起整个面板）。
        let tab_count = if has_split { 2 } else { 1 };
        let mut tab_elements: Vec<AnyElement> = Vec::with_capacity(tab_count);
        for index in 0..tab_count {
            let active = if index == 0 {
                !secondary_active
            } else {
                secondary_active
            };
            let text_color = if active {
                tokens.tool_window_selected_text
            } else {
                tokens.secondary_text
            };

            let click_owner = cx.weak_entity();
            let close_owner = cx.weak_entity();
            let single_tab = tab_count == 1;

            tab_elements.push(
                h_flex()
                    .id(format!("lithe-terminal-tab:{index}"))
                    .h(px(TERMINAL_TAB_HEIGHT))
                    .items_center()
                    .gap(px(6.))
                    .pl(px(8.))
                    .pr(px(4.))
                    .rounded(px(4.))
                    .when(active, |this| this.bg(tokens.selection))
                    .when(!active, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .on_click(move |_, window, cx| {
                        let _ = click_owner.update(cx, |this, cx| {
                            this.focus_terminal_tab(index, window, cx);
                        });
                    })
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(text_color)
                            .child(project_name.clone()),
                    )
                    .child(
                        Button::new(format!("lithe-terminal:close-tab-{index}"))
                            .ghost()
                            .with_size(px(16.0))
                            .rounded(px(3.0))
                            .child(
                                Icon::new(IconName::X)
                                    .with_size(px(10.0))
                                    .text_color(text_color),
                            )
                            .tooltip(tr("Close"))
                            .on_click(move |_, _window, cx| {
                                let _ = close_owner.update(cx, |this, cx| {
                                    if single_tab {
                                        // 最后一个标签：收起整个终端面板。
                                        this.set_dock_visible(DockAnchor::Bottom, false, cx);
                                        return;
                                    }
                                    if index == 0 {
                                        // 主终端无法单独关闭（分屏依赖它），
                                        // 关闭主标签等价于收起整个面板并结束分屏。
                                        this.close_terminal_split(cx);
                                        this.set_dock_visible(DockAnchor::Bottom, false, cx);
                                    } else {
                                        // 关闭分屏标签：只收起右侧那一半。
                                        this.close_terminal_split(cx);
                                        this.terminal_focus_secondary = false;
                                        cx.notify();
                                    }
                                });
                            }),
                    )
                    .into_any_element(),
            );
        }

        // 新建终端按钮 [+] 与 [▾] Profile 下拉菜单
        // GPUI 构建的终端会话数上限是 2（主 + 分屏），因此 `+` 在未分屏时
        // 创建一个分屏终端；已分屏时保持禁用，不假装能开第三个会话。
        let new_owner = cx.weak_entity();
        let split_full = has_split;
        let new_button = Button::new("lithe-terminal:new")
            .ghost()
            .with_size(px(22.0))
            .rounded(px(4.0))
            .child(Icon::new(IconName::Plus).with_size(px(13.0)))
            .tooltip(tr("New Terminal"))
            .disabled(split_full)
            .on_click(move |_, window, cx| {
                let _ = new_owner.update(cx, |this, cx| {
                    if this.terminal_secondary.is_none() {
                        this.split_terminal(TerminalSplitAxis::Horizontal, window, cx);
                    }
                });
            });

        // Profile 下拉：列出本机**实际安装**的 shell（`installed_terminal_shells`
        // 已按可执行文件存在性过滤），选中后重建 PTY。菜单每次渲染都重新取，
        // 因此新装的 shell 不需要额外的“重扫”状态。
        let current_shell = self.terminal.read(cx).shell().map(str::to_string);
        let installed_shells = lithe_features::installed_terminal_shells();
        let profile_owner = cx.weak_entity();
        let profile_menu_owner = cx.weak_entity();

        let profile_dropdown = Button::new("lithe-terminal:profile-menu")
            .ghost()
            .with_size(px(22.0))
            .rounded(px(4.0))
            .child(Icon::new(IconName::ChevronDown).with_size(px(10.0)))
            .tooltip(tr("Choose terminal profile"))
            .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _window, _cx| {
                let mut menu = menu
                    .item(PopupMenuItem::new(tr("New Terminal")).disabled(true))
                    .separator();

                // 系统默认 shell（不指定 id）。
                let default_owner = profile_owner.clone();
                menu = menu.item(
                    PopupMenuItem::new(tr("Default Terminal"))
                        .icon(Icon::new(IconName::Terminal))
                        .checked(current_shell.is_none())
                        .on_click(move |_, window, cx| {
                            let _ = default_owner.update(cx, |this, cx| {
                                this.apply_terminal_shell(None, window, cx);
                            });
                        }),
                );

                for shell in installed_shells.iter() {
                    let shell_owner = profile_owner.clone();
                    let shell_id = shell.id.clone();
                    let checked = current_shell.as_deref() == Some(shell.id.as_str());
                    menu = menu.item(
                        PopupMenuItem::new(SharedString::from(shell.name.clone()))
                            .icon(Icon::new(IconName::Terminal))
                            .checked(checked)
                            .on_click(move |_, window, cx| {
                                let target = shell_id.clone();
                                let _ = shell_owner.update(cx, |this, cx| {
                                    this.apply_terminal_shell(Some(target), window, cx);
                                });
                            }),
                    );
                }

                let rescan_owner = profile_owner.clone();
                menu.separator()
                    .item(PopupMenuItem::new(tr("Rescan installed shells")).on_click(
                        move |_, _window, cx| {
                            let _ = rescan_owner.update(cx, |_this, cx| cx.notify());
                        },
                    ))
            })
            // 终端正文是原生 WebView，层级高于 GPUI 画布；菜单打开期间必须
            // 隐藏 WebView，否则下拉会被终端内容整块盖住。
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
            .items_center()
            .gap(px(1.0))
            .child(new_button)
            .child(profile_dropdown);

        // 右侧操作图标组：分屏视图、全屏、最小化收起
        let mut right_actions = h_flex().items_center().gap(px(2.0));

        if has_split {
            right_actions = right_actions.child(
                Button::new("lithe-terminal:close-split")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(IconName::X).with_size(px(13.0)))
                    .tooltip(tr("Close Split"))
                    .on_click(move |_, _window, cx| {
                        let _ = split_owner.update(cx, |this, cx| this.close_terminal_split(cx));
                    }),
            );
        } else {
            right_actions = right_actions.child(
                Button::new("lithe-terminal:split")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(IconName::PanelRight).with_size(px(13.0)))
                    .tooltip(tr("Split Terminal"))
                    .on_click(move |_, window, cx| {
                        let _ = split_owner.update(cx, |this, cx| {
                            this.split_terminal(TerminalSplitAxis::Horizontal, window, cx);
                        });
                    }),
            );
        }

        right_actions = right_actions
            .child(
                Button::new("lithe-terminal:find")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(IconName::Search).with_size(px(13.0)))
                    .tooltip(tr("Find in Terminal")),
            )
            .child(
                Button::new("lithe-terminal:hide")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(IconName::Minus).with_size(px(13.0)))
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
            .px(px(8.))
            .bg(tokens.editor)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                h_flex()
                    .items_center()
                    .gap(px(2.))
                    .children(tab_elements)
                    .child(new_terminal_actions),
            )
            .child(right_actions)
            .into_any_element()
    }

    /// 终端内容视图。
    pub(super) fn render_terminal_content(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(secondary) = self.terminal_secondary.clone() else {
            return self.terminal.clone().into_any_element();
        };

        let tokens = current_tokens(cx);
        let primary = div()
            .flex_1()
            .min_w(px(0.))
            .min_h(px(0.))
            .child(self.terminal.clone());
        let secondary_pane = div().flex_1().min_w(px(0.)).min_h(px(0.)).child(secondary);

        match self.terminal_split_axis {
            TerminalSplitAxis::Horizontal => h_flex()
                .items_stretch()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary)
                .child(div().flex_shrink_0().w(px(1.)).bg(tokens.divider))
                .child(secondary_pane)
                .into_any_element(),
            TerminalSplitAxis::Vertical => v_flex()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary)
                .child(div().flex_shrink_0().h(px(1.)).bg(tokens.divider))
                .child(secondary_pane)
                .into_any_element(),
        }
    }

    /// 点击标签时把键盘焦点切到对应终端，标签高亮随焦点移动。
    fn focus_terminal_tab(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if index == 0 {
            self.terminal_focus_secondary = false;
            self.terminal
                .update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        } else if let Some(panel) = self.terminal_secondary.clone() {
            self.terminal_focus_secondary = true;
            panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        }
        cx.notify();
    }

    /// 切换终端使用的 shell 并重建 PTY。
    ///
    /// 应用到主终端与（若存在）分屏终端，避免两半用不同 shell 造成困惑。
    /// PTY 无法热切换，`set_shell` 内部会关闭旧会话并由下一帧重新创建；
    /// 正在运行的进程随之结束，与在 IDE 里换 shell 一致。
    pub(super) fn apply_terminal_shell(
        &mut self,
        shell: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let shell = shell;
        self.terminal.update(cx, |panel, panel_cx| {
            panel.set_shell(shell.clone(), window, panel_cx);
        });
        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |panel, panel_cx| {
                panel.set_shell(shell, window, panel_cx);
            });
        }
        cx.notify();
    }

    pub(super) fn split_terminal(
        &mut self,
        axis: TerminalSplitAxis,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_tool(ToolWindow::Terminal, window, cx);
        self.terminal_split_axis = axis;
        self.terminal_focus_secondary = true;

        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
            cx.notify();
            return;
        }

        let root = self.project_root.clone().unwrap_or_default();
        let panel = cx.new(|panel_cx| TerminalPanel::new(root, window, panel_cx));
        let font_size = self.settings.terminal_font_size;
        let scrollback = self.settings.terminal_scrollback;
        panel.update(cx, |panel, panel_cx| {
            panel.set_preferences(font_size, scrollback, window, panel_cx);
        });
        panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        self.terminal_secondary = Some(panel);
        self.terminal_secondary_webview_visible = None;
        cx.notify();
    }

    pub(super) fn close_terminal_split(&mut self, cx: &mut Context<Self>) {
        let Some(panel) = self.terminal_secondary.take() else {
            return;
        };
        panel.update(cx, |panel, panel_cx| {
            panel.set_webview_visible(false, panel_cx);
        });
        self.terminal_secondary_webview_visible = None;
        self.terminal_focus_secondary = false;
        cx.notify();
    }

    pub(super) fn apply_terminal_preferences(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let font_size = self.settings.terminal_font_size;
        let scrollback = self.settings.terminal_scrollback;
        self.terminal.update(cx, |panel, panel_cx| {
            panel.set_preferences(font_size, scrollback, window, panel_cx);
        });
        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |panel, panel_cx| {
                panel.set_preferences(font_size, scrollback, window, panel_cx);
            });
        }
    }
}
