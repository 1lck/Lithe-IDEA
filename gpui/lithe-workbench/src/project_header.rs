//! 项目工具窗标题栏（完全对齐 Tauri 侧 SidebarHeader 实现）。
//!
//! 包含：
//! - 左侧：项目视图下拉切换（`项目 ▾` / `依赖`）
//! - 右侧 5 个操作按钮（完全对齐 Tauri 视觉图）：
//!   1. `MousePointerClick`：定位当前活动文件
//!   2. `RefreshCw`：刷新文件树
//!   3. `Minus`：折叠/收起侧栏面板
//!   4. `Search`：树内就地搜索展开
//!   5. `SlidersHorizontal`：偏好设置选项浮动级联下拉菜单（完全对齐 Tauri DropdownMenu）

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu, PopupMenu, PopupMenuItem};
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, Context, IntoElement, ParentElement as _, SharedString, Styled as _,
    WeakEntity, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{current_tokens, LitheMetrics, LitheTokens};

use crate::workbench::{DockAnchor, ToolWindow, Workbench};

const HEADER_BUTTON_SIZE: f32 = 22.0;
const HEADER_BUTTON_RADIUS: f32 = 5.0;
const HEADER_ICON_SIZE: f32 = 14.0;

/// 渲染项目工具窗专用标题栏（含左侧切换下拉与右侧 5 个操作按钮）。
pub(crate) fn render_project_tool_header(
    tool: ToolWindow,
    search_open: bool,
    search_query: &str,
    _options_open: bool,
    show_hidden: bool,
    show_ignored: bool,
    view_mode_dependencies: bool,
    _window: &mut Window,
    cx: &mut Context<Workbench>,
) -> AnyElement {
    let tokens = current_tokens(cx);
    let owner = cx.weak_entity();
    let current_view_label = if view_mode_dependencies {
        tr("Dependencies")
    } else {
        tr("Project")
    };

    // 左侧：项目视图下拉切换按钮 (项目 ▾)
    let owner_toggle_view = owner.clone();
    let title_dropdown = Button::new("lithe-project-view-select")
        .ghost()
        .h(px(24.))
        .px(px(4.))
        .rounded(px(4.))
        .child(
            h_flex()
                .items_center()
                .gap(px(2.))
                .child(
                    div()
                        .font_weight(gpui_kit::FontWeight::BOLD)
                        .text_size(px(LitheMetrics::TOOL_WINDOW_TITLE_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(current_view_label),
                )
                .child(
                    Icon::new(IconName::ChevronDown)
                        .with_size(px(12.))
                        .text_color(tokens.secondary_text),
                ),
        )
        .dropdown_menu({
            let owner = owner_toggle_view;
            move |menu, _, _| {
                let owner_proj = owner.clone();
                let owner_dep = owner.clone();
                menu.item(
                    PopupMenuItem::new(tr("Project"))
                        .checked(!view_mode_dependencies)
                        .on_click(move |_, _, cx| {
                            let _ = owner_proj.update(cx, |this, cx| {
                                this.set_project_view_dependencies(false, cx);
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Dependencies"))
                        .checked(view_mode_dependencies)
                        .on_click(move |_, _, cx| {
                            let _ = owner_dep.update(cx, |this, cx| {
                                this.set_project_view_dependencies(true, cx);
                            });
                        }),
                )
            }
        })
        .on_open_change({
            let owner = owner.clone();
            move |open, _window, cx| {
                let _ = owner.update(cx, |this, cx| {
                    this.set_menu_open(*open, cx);
                });
            }
        });

    // 1. 定位当前文件按钮 (MousePointerClick)
    let btn_locate = render_header_icon_button(
        "project-action:locate",
        IconName::MousePointerClick,
        tr("Select Opened File"),
        false,
        owner.clone(),
        |this, window, cx| {
            this.reveal_active_file_in_tree(window, cx);
        },
        tokens,
    );

    // 2. 刷新按钮 (RefreshCw)
    let btn_refresh = render_header_icon_button(
        "project-action:refresh",
        IconName::RefreshCw,
        tr("Refresh"),
        false,
        owner.clone(),
        move |this, window, cx| {
            this.refresh_tool(tool, window, cx);
        },
        tokens,
    );

    // 3. 收起侧栏按钮 (Minus)
    let btn_collapse = render_header_icon_button(
        "project-action:collapse",
        IconName::Minus,
        tr("Collapse"),
        false,
        owner.clone(),
        move |this, _window, cx| {
            this.set_dock_visible(DockAnchor::Left, false, cx);
        },
        tokens,
    );

    // 4. 树内搜索按钮 (Search)
    let btn_search = render_header_icon_button(
        "project-action:search",
        IconName::Search,
        tr("Search Files"),
        search_open,
        owner.clone(),
        |this, _window, cx| {
            this.toggle_project_tree_search(cx);
        },
        tokens,
    );

    // 5. 选项/偏好设置按钮 (SlidersHorizontal) -> 真正的浮动级联下拉菜单，完全对齐 Tauri
    let owner_options = owner.clone();
    let btn_options = Button::new("project-action:options")
        .ghost()
        .with_size(px(HEADER_BUTTON_SIZE))
        .rounded(px(HEADER_BUTTON_RADIUS))
        .icon(
            Icon::new(IconName::SlidersHorizontal)
                .with_size(px(HEADER_ICON_SIZE))
                .text_color(tokens.tool_window_button_text),
        )
        .tooltip(tr("Options"))
        .accessibility_label(tr("Options"))
        .dropdown_menu_with_anchor(Anchor::TopRight, {
            let owner = owner_options;
            move |menu, window, cx| {
                let owner_hidden = owner.clone();
                let owner_ignored = owner.clone();

                // 子菜单 1：可见性
                let visibility_menu = PopupMenu::build(window, cx, move |menu, _, _| {
                    let owner_h = owner_hidden.clone();
                    let owner_i = owner_ignored.clone();
                    menu.item(
                        PopupMenuItem::new("隐藏文件")
                            .checked(show_hidden)
                            .on_click(move |_, _, cx| {
                                let _ = owner_h.update(cx, |this, cx| {
                                    this.toggle_show_hidden_files(cx);
                                });
                            }),
                    )
                    .item(
                        PopupMenuItem::new("被 Git 忽略的文件")
                            .checked(show_ignored)
                            .on_click(move |_, _, cx| {
                                let _ = owner_i.update(cx, |this, cx| {
                                    this.toggle_show_ignored_files(cx);
                                });
                            }),
                    )
                    .item(PopupMenuItem::new("Git 状态标记").checked(true))
                });

                // 子菜单 2：外观
                let appearance_menu = PopupMenu::build(window, cx, |menu, _, _| {
                    menu.item(PopupMenuItem::new("文件图标").checked(true))
                        .item(PopupMenuItem::new("缩进参考线").checked(true))
                        .item(PopupMenuItem::new("紧凑文件夹").checked(true))
                        .item(PopupMenuItem::new("隐藏根文件夹").checked(false))
                });

                // 子菜单 3：排序顺序
                let sort_menu = PopupMenu::build(window, cx, |menu, _, _| {
                    menu.item(PopupMenuItem::new("文件夹置顶").checked(true))
                        .item(PopupMenuItem::new("按名称").checked(false))
                });

                // 子菜单 4：缩进
                let indent_menu = PopupMenu::build(window, cx, |menu, _, _| {
                    menu.item(PopupMenuItem::new("紧凑 (12px)").checked(false))
                        .item(PopupMenuItem::new("默认 (16px)").checked(true))
                        .item(PopupMenuItem::new("宽松 (20px)").checked(false))
                });

                menu.item(
                    PopupMenuItem::submenu("可见性", visibility_menu)
                        .icon(Icon::new(IconName::Eye)),
                )
                .item(
                    PopupMenuItem::submenu("外观", appearance_menu)
                        .icon(Icon::new(IconName::Palette)),
                )
                .item(
                    PopupMenuItem::submenu("排序顺序", sort_menu)
                        .icon(Icon::new(IconName::List)),
                )
                .item(
                    PopupMenuItem::submenu("缩进", indent_menu)
                        .icon(Icon::new(IconName::ListIndentIncrease)),
                )
                .item(PopupMenuItem::separator())
                .item(
                    PopupMenuItem::new("删除前确认")
                        .icon(Icon::new(IconName::Trash))
                        .checked(true),
                )
            }
        })
        .on_open_change({
            let owner = owner.clone();
            move |open, _window, cx| {
                let _ = owner.update(cx, |this, cx| {
                    this.set_menu_open(*open, cx);
                });
            }
        });

    let actions = h_flex()
        .items_center()
        .gap(px(LitheMetrics::TOOL_WINDOW_ACTION_GAP))
        .child(btn_locate)
        .child(btn_refresh)
        .child(btn_collapse)
        .child(btn_search)
        .child(btn_options);

    let main_header = h_flex()
        .w_full()
        .h(px(LitheMetrics::TOOL_WINDOW_HEADER_HEIGHT))
        .items_center()
        .justify_between()
        .pl(px(LitheMetrics::TOOL_WINDOW_HEADER_LEADING))
        .pr(px(LitheMetrics::TOOL_WINDOW_HEADER_TRAILING))
        .child(title_dropdown)
        .child(actions);

    let mut container = v_flex().w_full().child(main_header);

    // 树内搜索展开条
    if search_open {
        let owner_clear = owner.clone();
        let is_empty = search_query.is_empty();
        let display_text: SharedString = if is_empty {
            tr("Filter files…").into()
        } else {
            search_query.to_string().into()
        };
        let search_bar = h_flex()
            .w_full()
            .px(px(8.))
            .pb(px(6.))
            .items_center()
            .gap(px(4.))
            .child(
                div()
                    .flex_1()
                    .h(px(24.))
                    .px(px(6.))
                    .rounded(px(4.))
                    .bg(tokens.sidebar)
                    .border_1()
                    .border_color(tokens.divider)
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .child(
                        Icon::new(IconName::Search)
                            .with_size(px(12.))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.))
                            .text_color(if is_empty {
                                tokens.secondary_text
                            } else {
                                tokens.primary_text
                            })
                            .child(display_text),
                    ),
            )
            .when(!is_empty, |this| {
                this.child(
                    Button::new("clear-project-search")
                        .ghost()
                        .with_size(px(20.))
                        .rounded(px(4.))
                        .icon(Icon::new(IconName::X).with_size(px(12.)))
                        .on_click(move |_, _window, cx| {
                            let _ = owner_clear.update(cx, |this, cx| {
                                this.clear_project_tree_search(cx);
                            });
                        }),
                )
            });

        container = container.child(search_bar);
    }

    container.into_any_element()
}

fn render_header_icon_button(
    id: &'static str,
    icon_name: IconName,
    tooltip: &'static str,
    active: bool,
    owner: WeakEntity<Workbench>,
    action: impl Fn(&mut Workbench, &mut Window, &mut Context<Workbench>) + 'static,
    tokens: LitheTokens,
) -> AnyElement {
    Button::new(id)
        .ghost()
        .with_size(px(HEADER_BUTTON_SIZE))
        .rounded(px(HEADER_BUTTON_RADIUS))
        .when(active, |this| this.bg(tokens.selection))
        .icon(
            Icon::new(icon_name)
                .with_size(px(HEADER_ICON_SIZE))
                .text_color(if active {
                    tokens.tool_window_selected_text
                } else {
                    tokens.tool_window_button_text
                }),
        )
        .tooltip(tooltip)
        .accessibility_label(tooltip)
        .on_click(move |_, window, cx| {
            let _ = owner.update(cx, |this, cx| {
                action(this, window, cx);
            });
        })
        .into_any_element()
}
