use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{h_flex, Icon, Sizable as _};
use gpui_kit::{
    div, px, Context, EventEmitter, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum ToolbarEvent {
    NewFile,
    Save,
    CloseTab,
    Run,
    Debug,
    Stop,
    ToggleTerminal,
    ClearTerminal,
    ToggleSidebar,
    RefreshWorkspace,
    QuickOpen,
    OpenSettings,
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
                // 1. 左侧：Lithe Logo + 项目选择器胶囊 + 分支选择器胶囊
                h_flex()
                    .items_center()
                    .gap_3()
                    .child(
                        // Lithe Logo + 品牌名
                        h_flex()
                            .items_center()
                            .gap_1p5()
                            .pr_1()
                            .child(
                                Icon::new(IconName::Zap)
                                    .size(px(16.0))
                                    .text_color(ThemeColors::accent_blue()),
                            )
                            .child(
                                div()
                                    .font_weight(FontWeight::BOLD)
                                    .text_sm()
                                    .text_color(ThemeColors::text_primary())
                                    .child("Lithe"),
                            ),
                    )
                    // 项目选择器胶囊（点击可展开项目切换下拉菜单）
                    .child({
                        let v = view.clone();
                        Button::new("tb-project-selector")
                            .small()
                            .ghost()
                            .icon(IconName::Folder)
                            .label(self.workspace_name.clone())
                            .bg(ThemeColors::bg_tab_hover())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .rounded_md()
                            .dropdown_menu(move |menu, _window, _cx| {
                                let v_refresh = v.clone();
                                let v_new_file = v.clone();
                                let v_save = v.clone();
                                let v_close = v.clone();
                                let v_sidebar = v.clone();
                                let v_terminal = v.clone();
                                let v_settings = v.clone();
                                let v_about = v.clone();
                                let v_exit = v.clone();

                                menu.item(
                                    PopupMenuItem::new("New File (Ctrl+N)")
                                        .on_click(move |_, _, cx| {
                                            v_new_file.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::NewFile)
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Save (Ctrl+S)")
                                        .on_click(move |_, _, cx| {
                                            v_save.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::Save)
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Close Active Tab (Ctrl+W)")
                                        .on_click(move |_, _, cx| {
                                            v_close.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::CloseTab)
                                            });
                                        }),
                                )
                                .separator()
                                .item(
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
                                            v_terminal.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::ToggleTerminal)
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Refresh Workspace")
                                        .on_click(move |_, _, cx| {
                                            v_refresh.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::RefreshWorkspace)
                                            });
                                        }),
                                )
                                .separator()
                                .item(
                                    PopupMenuItem::new("Settings")
                                        .on_click(move |_, _, cx| {
                                            v_settings.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::OpenSettings)
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("About Lithe")
                                        .on_click(move |_, _, cx| {
                                            v_about.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::About)
                                            });
                                        }),
                                )
                                .separator()
                                .item(
                                    PopupMenuItem::new("Exit")
                                        .on_click(move |_, _, cx| {
                                            v_exit.update(cx, |_, cx| {
                                                cx.emit(ToolbarEvent::Exit)
                                            });
                                        }),
                                )
                            })
                    })
                    // 分支选择器胶囊：带 GitBranch 图标、分支名和 ChevronDown
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1p5()
                            .px_2()
                            .py(px(3.0))
                            .rounded_md()
                            .bg(ThemeColors::bg_tab_hover())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::GitBranch)
                                    .size(px(13.0))
                                    .text_color(ThemeColors::accent_green()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::accent_green())
                                    .child(branch),
                            )
                            .child(
                                Icon::new(IconName::ChevronDown)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::text_muted()),
                            ),
                    ),
            )
            .child(
                // 2. 中间：全局搜索栏 (Search Everywhere)
                div()
                    .id("search-everywhere-bar")
                    .w(px(280.0))
                    .h(px(28.0))
                    .bg(ThemeColors::bg_tab_active())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded(px(6.0))
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
                            .child(
                                Icon::new(IconName::Search)
                                    .size(px(13.0))
                                    .text_color(ThemeColors::text_muted()),
                            )
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
                            .px_1p5()
                            .py(px(1.0))
                            .bg(ThemeColors::bg_titlebar())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .rounded(px(4.0))
                            .child("Ctrl+P"),
                    ),
            )
            .child(
                // 3. 右侧：运行目标胶囊 + 运行/调试/停止/设置控制组
                h_flex()
                    .items_center()
                    .gap_2()
                    .child(
                        // 运行目标胶囊
                        h_flex()
                            .items_center()
                            .gap_1p5()
                            .px_2()
                            .py(px(3.0))
                            .rounded_md()
                            .bg(ThemeColors::bg_tab_hover())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_primary())
                                    .child("[Project] Default"),
                            )
                            .child(
                                Icon::new(IconName::ChevronDown)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::text_muted()),
                            ),
                    )
                    .child(
                        Button::new("tb-run")
                            .small()
                            .primary()
                            .icon(IconName::Play)
                            .label("Run")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Run);
                            })),
                    )
                    .child(
                        Button::new("tb-debug")
                            .small()
                            .ghost()
                            .icon(IconName::Bug)
                            .label("Debug")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Debug);
                            })),
                    )
                    .child(
                        Button::new("tb-stop")
                            .small()
                            .ghost()
                            .icon(IconName::Square)
                            .tooltip("Stop")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Stop);
                            })),
                    )
                    .child(
                        Button::new("tb-settings")
                            .small()
                            .ghost()
                            .icon(IconName::Settings)
                            .tooltip("Settings")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::OpenSettings);
                            })),
                    ),
            )
    }
}
