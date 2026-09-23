use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{h_flex, Sizable as _};
use gpui_kit::{
    div, px, Context, EventEmitter, InteractiveElement as _, IntoElement, ParentElement as _,
    Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

#[derive(Debug, Clone)]
pub enum ToolbarEvent {
    NewFile,
    Save,
    CloseTab,
    Run,
    Debug,
    #[allow(dead_code)]
    Stop,
    ToggleTerminal,
    ClearTerminal,
    ToggleSidebar,
    RefreshWorkspace,
    QuickOpen,
    About,
    Exit,
}

pub struct ToolbarView {
    pub workspace_name: String,
    pub git_branch: Option<String>,
}

impl EventEmitter<ToolbarEvent> for ToolbarView {}

impl ToolbarView {
    pub fn new(workspace_root: &str) -> Self {
        let name = workspace_root
            .rsplit_once('/')
            .map(|(_, n)| n.to_string())
            .unwrap_or_else(|| workspace_root.to_string());

        Self {
            workspace_name: name,
            git_branch: None,
        }
    }

    #[allow(dead_code)]
    pub fn set_git_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) {
        self.git_branch = branch;
        cx.notify();
    }
}

impl Render for ToolbarView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let branch = self.git_branch.clone().unwrap_or_else(|| "main".to_string());
        let view = cx.entity();

        h_flex()
            .h(px(40.0))
            .w_full()
            .bg(ThemeColors::bg_titlebar())
            .border_b_1()
            .border_color(ThemeColors::border())
            .items_center()
            .justify_between()
            .px_3()
            .child(
                // 1. 左侧：Logo + 菜单栏 + 项目名称选择器 + 分支
                h_flex()
                    .items_center()
                    .gap_1()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .pr_2()
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(ThemeColors::accent_blue())
                                    .child("⚡"),
                            )
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(ThemeColors::text_primary())
                                    .child("Lithe"),
                            ),
                    )
                    // File 菜单
                    .child({
                        let v = view.clone();
                        Button::new("menu-file")
                            .small()
                            .ghost()
                            .label("File")
                            .dropdown_menu(move |menu, _window, _cx| {
                                let v_new = v.clone();
                                let v_save = v.clone();
                                let v_close = v.clone();
                                let v_exit = v.clone();

                                menu.item(
                                    PopupMenuItem::new("New File (Ctrl+N)")
                                        .on_click(move |_, _, cx| {
                                            v_new.update(cx, |_, cx| cx.emit(ToolbarEvent::NewFile));
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Save (Ctrl+S)")
                                        .on_click(move |_, _, cx| {
                                            v_save.update(cx, |_, cx| cx.emit(ToolbarEvent::Save));
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Close Active Tab (Ctrl+W)")
                                        .on_click(move |_, _, cx| {
                                            v_close.update(cx, |_, cx| cx.emit(ToolbarEvent::CloseTab));
                                        }),
                                )
                                .separator()
                                .item(
                                    PopupMenuItem::new("Exit")
                                        .on_click(move |_, _, cx| {
                                            v_exit.update(cx, |_, cx| cx.emit(ToolbarEvent::Exit));
                                        }),
                                )
                            })
                    })
                    // Edit 菜单
                    .child(
                        Button::new("menu-edit")
                            .small()
                            .ghost()
                            .label("Edit")
                            .dropdown_menu(|menu, _window, _cx| {
                                menu.item(PopupMenuItem::new("Undo (Ctrl+Z)"))
                                    .item(PopupMenuItem::new("Redo (Ctrl+Y)"))
                                    .separator()
                                    .item(PopupMenuItem::new("Cut (Ctrl+X)"))
                                    .item(PopupMenuItem::new("Copy (Ctrl+C)"))
                                    .item(PopupMenuItem::new("Paste (Ctrl+V)"))
                            }),
                    )
                    // View 菜单
                    .child({
                        let v = view.clone();
                        Button::new("menu-view")
                            .small()
                            .ghost()
                            .label("View")
                            .dropdown_menu(move |menu, _window, _cx| {
                                let v_sidebar = v.clone();
                                let v_term = v.clone();
                                let v_refresh = v.clone();

                                menu.item(
                                    PopupMenuItem::new("Toggle Sidebar (Ctrl+B)")
                                        .on_click(move |_, _, cx| {
                                            v_sidebar.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::ToggleSidebar)
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Toggle Terminal (Ctrl+`)")
                                        .on_click(move |_, _, cx| {
                                            v_term.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::ToggleTerminal)
                                            });
                                        }),
                                )
                                .separator()
                                .item(
                                    PopupMenuItem::new("Refresh Workspace")
                                        .on_click(move |_, _, cx| {
                                            v_refresh.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::RefreshWorkspace)
                                            });
                                        }),
                                )
                            })
                    })
                    // Run 菜单
                    .child({
                        let v = view.clone();
                        Button::new("menu-run")
                            .small()
                            .ghost()
                            .label("Run")
                            .dropdown_menu(move |menu, _window, _cx| {
                                let v_run = v.clone();
                                let v_debug = v.clone();

                                menu.item(
                                    PopupMenuItem::new("Run Configuration (Shift+F10)")
                                        .on_click(move |_, _, cx| {
                                            v_run.update(cx, |_, cx| cx.emit(ToolbarEvent::Run));
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Debug Configuration (Shift+F9)")
                                        .on_click(move |_, _, cx| {
                                            v_debug.update(cx, |_, cx| cx.emit(ToolbarEvent::Debug));
                                        }),
                                )
                            })
                    })
                    // Terminal 菜单
                    .child({
                        let v = view.clone();
                        Button::new("menu-terminal")
                            .small()
                            .ghost()
                            .label("Terminal")
                            .dropdown_menu(move |menu, _window, _cx| {
                                let v_toggle = v.clone();
                                let v_clear = v.clone();

                                menu.item(
                                    PopupMenuItem::new("Toggle Terminal")
                                        .on_click(move |_, _, cx| {
                                            v_toggle.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::ToggleTerminal)
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Clear Output")
                                        .on_click(move |_, _, cx| {
                                            v_clear.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::ClearTerminal)
                                            });
                                        }),
                                )
                            })
                    })
                    // Help 菜单
                    .child({
                        let v = view.clone();
                        Button::new("menu-help")
                            .small()
                            .ghost()
                            .label("Help")
                            .dropdown_menu(move |menu, _window, _cx| {
                                let v_about = v.clone();

                                menu.item(
                                    PopupMenuItem::new("About Lithe")
                                        .on_click(move |_, _, cx| {
                                            v_about.update(cx, |_, cx| cx.emit(ToolbarEvent::About));
                                        }),
                                )
                            })
                    })
                    // 分隔竖线
                    .child(
                        div()
                            .h(px(14.0))
                            .w(px(1.0))
                            .bg(ThemeColors::border())
                            .mx_2(),
                    )
                    // 项目选择器外观
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .px_2()
                            .py(px(2.0))
                            .rounded_md()
                            .bg(ThemeColors::bg_tab_hover())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child("📂")
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_primary())
                                    .child(self.workspace_name.clone()),
                            ),
                    )
                    // Git 分支标识
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .px_2()
                            .py(px(2.0))
                            .rounded_md()
                            .bg(ThemeColors::bg_tab_hover())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child("⎇")
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::accent_green())
                                    .child(branch),
                            ),
                    ),
            )
            .child(
                // 2. 中间：全局搜索栏 (Search Everywhere)
                div()
                    .id("search-everywhere-bar")
                    .w(px(260.0))
                    .h(px(26.0))
                    .bg(ThemeColors::bg_tab_active())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_md()
                    .px_2()
                    .flex()
                    .items_center()
                    .justify_between()
                    .cursor_pointer()
                    .hover(|h| h.border_color(ThemeColors::accent_blue()))
                    .on_click(cx.listener(|_this, _event, _window, cx| {
                        cx.emit(ToolbarEvent::QuickOpen);
                    }))
                    .child(
                        h_flex()
                            .items_center()
                            .gap_2()
                            .child(div().text_xs().text_color(ThemeColors::text_muted()).child("🔍"))
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child("Search files, symbols..."),
                            ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .px_1()
                            .bg(ThemeColors::bg_titlebar())
                            .rounded_sm()
                            .child("Ctrl+P"),
                    ),
            )
            .child(
                // 3. 右侧：运行/调试配置按钮组
                h_flex()
                    .items_center()
                    .gap_2()
                    .child(
                        Button::new("tb-run")
                            .small()
                            .primary()
                            .label("▶ Run")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Run);
                            })),
                    )
                    .child(
                        Button::new("tb-debug")
                            .small()
                            .ghost()
                            .label("🐞 Debug")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Debug);
                            })),
                    )
                    .child(
                        Button::new("tb-save")
                            .small()
                            .ghost()
                            .label("💾 Save")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Save);
                            })),
                    ),
            )
    }
}
