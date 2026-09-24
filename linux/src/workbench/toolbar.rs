//! 顶部标题栏/工具栏：复刻 Tauri `title-bar.tsx` + `window-menu-bar.tsx`。
//!
//! 结构从左到右：应用菜单栏（紧凑或九宫格）、品牌、项目胶囊、分支胶囊、
//! 居中全局搜索条、运行目标胶囊、运行/调试/停止、主题与设置、窗口控件。
//! 所有交互只通过 [`ToolbarEvent`] 向外广播，具体业务由 `view.rs` 订阅处理。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{h_flex, Icon, Selectable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Anchor, AnyElement, Context, EventEmitter, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::settings;
use crate::theme::ThemeColors;

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum ToolbarEvent {
    // ---- 旧事件（保留以兼容 view.rs 现有订阅） ----
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
    // ---- 新增：菜单项统一出口 ----
    /// 任意应用菜单项被点击，载荷为稳定 id（如 `file.new_file`）。
    MenuAction(String),
    /// 切换浅色/深色主题。
    ToggleTheme,
    WindowMinimize,
    WindowMaximize,
    WindowClose,
    // ---- 新增：项目胶囊动作 ----
    NewProject,
    OpenProject,
    CloneRepository,
    OpenRecent,
}

pub struct ToolbarView {
    pub workspace_name: String,
    pub git_branch: Option<String>,
    /// 紧凑菜单条是否展开（对齐 Tauri `isCompactMenuVisible`）。
    compact_menu_open: bool,
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
            compact_menu_open: false,
        }
    }

    pub fn set_git_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) {
        self.git_branch = branch;
        cx.notify();
    }
}

/// 单个菜单项：显示文本 + 稳定动作 id。
struct MenuEntry {
    label: &'static str,
    action: &'static str,
}

/// 便于在 `const` 菜单表中声明条目。
const fn entry(label: &'static str, action: &'static str) -> MenuEntry {
    MenuEntry { label, action }
}

/// 一个顶层应用菜单：标题 + 分组（分组之间渲染分隔线）。
struct AppMenu {
    title: &'static str,
    groups: &'static [&'static [MenuEntry]],
}

// ---- 九个应用菜单的静态定义，与 Tauri `window-menu-bar.tsx` 对齐 ----
const FILE_MENU: &[&[MenuEntry]] = &[
    &[
        entry("New File", "file.new_file"),
        entry("New Window", "file.new_window"),
    ],
    &[
        entry("Open File...", "file.open_file"),
        entry("Open Folder...", "file.open_folder"),
    ],
    &[
        entry("Save", "file.save"),
        entry("Save All", "file.save_all"),
    ],
    &[
        entry("Close Editor", "file.close_editor"),
        entry("Close Window", "file.close_window"),
    ],
    &[entry("Exit", "file.exit")],
];

const EDIT_MENU: &[&[MenuEntry]] = &[
    &[entry("Undo", "edit.undo"), entry("Redo", "edit.redo")],
    &[
        entry("Cut", "edit.cut"),
        entry("Copy", "edit.copy"),
        entry("Paste", "edit.paste"),
    ],
    &[entry("Find", "edit.find"), entry("Replace", "edit.replace")],
];

const VIEW_MENU: &[&[MenuEntry]] = &[
    &[
        entry("Toggle Sidebar", "view.toggle_sidebar"),
        entry("Toggle Bottom Panel", "view.toggle_bottom_panel"),
        entry("Toggle Status Bar", "view.toggle_status_bar"),
    ],
    &[
        entry("Command Palette", "view.command_palette"),
        entry("Quick Open", "view.quick_open"),
    ],
    &[
        entry("Zoom In", "view.zoom_in"),
        entry("Zoom Out", "view.zoom_out"),
        entry("Reset Zoom", "view.reset_zoom"),
    ],
];

const GO_MENU: &[&[MenuEntry]] = &[
    &[entry("Back", "go.back"), entry("Forward", "go.forward")],
    &[
        entry("Go to File", "go.go_to_file"),
        entry("Go to Symbol", "go.go_to_symbol"),
        entry("Go to Line", "go.go_to_line"),
    ],
];

const TERMINAL_MENU: &[&[MenuEntry]] = &[&[
    entry("New Terminal", "terminal.new"),
    entry("Split Terminal", "terminal.split"),
    entry("Clear Terminal", "terminal.clear"),
]];

const RUN_MENU: &[&[MenuEntry]] = &[
    &[
        entry("Run", "run.run"),
        entry("Debug", "run.debug"),
        entry("Stop", "run.stop"),
    ],
    &[entry("Run Without Debugging", "run.run_without_debugging")],
];

const TOOLS_MENU: &[&[MenuEntry]] = &[
    &[
        entry("Settings", "tools.settings"),
        entry("Extensions", "tools.extensions"),
    ],
    &[
        entry("Database", "tools.database"),
        entry("Diagnostics", "tools.diagnostics"),
    ],
];

const WINDOW_MENU: &[&[MenuEntry]] = &[&[
    entry("Minimize", "window.minimize"),
    entry("Maximize", "window.maximize"),
    entry("Close", "window.close"),
]];

const HELP_MENU: &[&[MenuEntry]] = &[
    &[
        entry("Documentation", "help.documentation"),
        entry("Keyboard Shortcuts", "help.keyboard_shortcuts"),
    ],
    &[entry("About Lithe", "help.about")],
];

const APP_MENUS: &[AppMenu] = &[
    AppMenu {
        title: "File",
        groups: FILE_MENU,
    },
    AppMenu {
        title: "Edit",
        groups: EDIT_MENU,
    },
    AppMenu {
        title: "View",
        groups: VIEW_MENU,
    },
    AppMenu {
        title: "Go",
        groups: GO_MENU,
    },
    AppMenu {
        title: "Terminal",
        groups: TERMINAL_MENU,
    },
    AppMenu {
        title: "Run",
        groups: RUN_MENU,
    },
    AppMenu {
        title: "Tools",
        groups: TOOLS_MENU,
    },
    AppMenu {
        title: "Window",
        groups: WINDOW_MENU,
    },
    AppMenu {
        title: "Help",
        groups: HELP_MENU,
    },
];

/// 构造一个发出 `MenuAction(id)` 的菜单项。
fn menu_action_item(
    label: impl Into<SharedString>,
    action: &'static str,
    view: &gpui_kit::Entity<ToolbarView>,
) -> PopupMenuItem {
    let v = view.clone();
    PopupMenuItem::new(label).on_click(move |_, _, cx| {
        v.update(cx, |this, cx| {
            // 选中任意菜单项后收起紧凑菜单条，与 Tauri `onCompactClose` 一致。
            this.compact_menu_open = false;
            cx.emit(ToolbarEvent::MenuAction(action.to_string()));
        });
    })
}

/// 构造一个直接发出指定事件的菜单项（用于项目胶囊等固定动作）。
fn event_item(
    label: impl Into<SharedString>,
    make: fn() -> ToolbarEvent,
    view: &gpui_kit::Entity<ToolbarView>,
) -> PopupMenuItem {
    let v = view.clone();
    PopupMenuItem::new(label).on_click(move |_, _, cx| {
        let event = make();
        v.update(cx, |this, cx| {
            this.compact_menu_open = false;
            cx.emit(event);
        });
    })
}

/// 按分组把菜单项灌入 `PopupMenu`，分组之间自动插入分隔线。
fn build_menu(
    mut menu: PopupMenu,
    groups: &[&[MenuEntry]],
    view: &gpui_kit::Entity<ToolbarView>,
) -> PopupMenu {
    let mut first_group = true;
    for group in groups {
        if !first_group {
            menu = menu.separator();
        }
        first_group = false;
        for item in *group {
            menu = menu.item(menu_action_item(item.label, item.action, view));
        }
    }
    menu
}

impl Render for ToolbarView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let branch = self
            .git_branch
            .clone()
            .unwrap_or_else(|| "main".to_string());
        let project_name = self.workspace_name.clone();

        // 读取渲染所需的设置快照，随后立刻释放对 cx 的只读借用。
        let compact_menu = settings::get(cx).compact_menu_bar;

        let view = cx.entity();

        // 应用菜单栏：紧凑模式为 Menu 图标触发一个横向浮出的菜单条（九个菜单名并排，
        // 各自下拉），对齐 Tauri `compactFloating` 的 `Menubar`；非紧凑模式平铺九个顶层菜单。
        let app_menu: AnyElement = if compact_menu {
            let v_menu = view.clone();
            // 触发点相对定位，浮层用 deferred+anchored 挂在其下方，避免撑开标题栏。
            let open = self.compact_menu_open;
            let trigger = div()
                .id("tb-app-menu")
                .relative()
                .child(
                    Button::new("tb-app-menu-btn")
                        .small()
                        .ghost()
                        .icon(IconName::List)
                        .tooltip("Menu")
                        .selected(open)
                        .on_click(cx.listener(
                            |this, _event: &gpui_kit::ClickEvent, _window, cx| {
                                this.compact_menu_open = !this.compact_menu_open;
                                cx.notify();
                            },
                        )),
                )
                .when(open, move |this| {
                    let v_out = v_menu.clone();
                    this.child(gpui_kit::deferred(
                        gpui_kit::anchored()
                            .anchor(Anchor::TopLeft)
                            .snap_to_window_with_margin(px(8.0))
                            .child(
                                h_flex()
                                    .id("tb-compact-menu-bar")
                                    .occlude()
                                    .flex_nowrap()
                                    .items_center()
                                    .gap_0p5()
                                    .px_1()
                                    .py_1()
                                    .top(px(4.0))
                                    .rounded_xl()
                                    .bg(ThemeColors::background())
                                    .border_1()
                                    .border_color(ThemeColors::border())
                                    .shadow_lg()
                                    // 点击菜单条以外区域时收起，对齐 Tauri 紧凑菜单的行为。
                                    .on_mouse_down_out(move |_, _, cx| {
                                        v_out.update(cx, |this, cx| {
                                            this.compact_menu_open = false;
                                            cx.notify();
                                        });
                                    })
                                    .children(APP_MENUS.iter().map(|app| {
                                        let v_item = v_menu.clone();
                                        Button::new(format!("tb-compact-menu-{}", app.title))
                                            .small()
                                            .ghost()
                                            .label(app.title)
                                            .dropdown_menu(move |menu, _window, _cx| {
                                                build_menu(menu, app.groups, &v_item)
                                            })
                                    })),
                            ),
                    ))
                });
            trigger.into_any_element()
        } else {
            h_flex()
                .items_center()
                .children(APP_MENUS.iter().map(|app| {
                    let v = view.clone();
                    Button::new(format!("tb-menu-{}", app.title))
                        .small()
                        .ghost()
                        .label(app.title)
                        .dropdown_menu(move |menu, _window, _cx| build_menu(menu, app.groups, &v))
                }))
                .into_any_element()
        };

        h_flex()
            .h(px(40.0))
            .w_full()
            .bg(ThemeColors::surface())
            .border_b_1()
            .border_color(ThemeColors::border())
            .items_center()
            .justify_between()
            .px_3()
            // 左侧：应用菜单 + 项目菜单 + 分支胶囊（对齐 Tauri `title-bar.tsx` 的左侧组）
            .child(
                h_flex()
                    .min_w_0()
                    .items_center()
                    .gap_2()
                    .child(app_menu)
                    .child({
                        // 项目菜单：logo + 项目名 + ChevronDown，点击展开项目列表
                        let v = view.clone();
                        let name = project_name.clone();
                        Button::new("tb-project-selector")
                            .small()
                            .ghost()
                            .child(
                                // 项目徽标：Tauri 用 public/logo.png，这里以同尺寸圆角方块承载品牌色。
                                div()
                                    .size(px(20.0))
                                    .flex_shrink_0()
                                    .rounded(px(6.0))
                                    .bg(ThemeColors::primary())
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .child(
                                        Icon::new(IconName::Zap)
                                            .size(px(12.0))
                                            .text_color(ThemeColors::background()),
                                    ),
                            )
                            .child(
                                div()
                                    .max_w(px(224.0))
                                    .truncate()
                                    .text_xs()
                                    .text_color(ThemeColors::foreground())
                                    .child(name.clone()),
                            )
                            .child(
                                Icon::new(IconName::ChevronDown)
                                    .size(px(14.0))
                                    .text_color(ThemeColors::subtle_foreground()),
                            )
                            .dropdown_menu(move |menu, _window, _cx| {
                                menu.item(event_item(
                                    "New Project",
                                    || ToolbarEvent::NewProject,
                                    &v,
                                ))
                                .item(event_item("Open", || ToolbarEvent::OpenProject, &v))
                                .item(event_item(
                                    "Clone Repository",
                                    || ToolbarEvent::CloneRepository,
                                    &v,
                                ))
                                .separator()
                                .item(event_item(
                                    "Open Projects",
                                    || ToolbarEvent::OpenProject,
                                    &v,
                                ))
                                .separator()
                                .item(event_item(
                                    "Open Recent",
                                    || ToolbarEvent::OpenRecent,
                                    &v,
                                ))
                            })
                    })
                    .child(
                        // 分支胶囊：只展示当前分支，不接真实切换
                        h_flex()
                            .items_center()
                            .gap_1p5()
                            .px_2()
                            .py(px(3.0))
                            .rounded_md()
                            .bg(ThemeColors::surface())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::GitBranch)
                                    .size(px(13.0))
                                    .text_color(ThemeColors::success()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::success())
                                    .child(branch),
                            )
                            .child(
                                Icon::new(IconName::ChevronDown)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::subtle_foreground()),
                            ),
                    ),
            )
            // 右侧：全局搜索图标按钮 + 窗口控件（对齐 Tauri `quickOpenAction` + `WindowControls`）
            .child(
                h_flex()
                    .items_center()
                    .flex_shrink_0()
                    .gap_1()
                    .child(
                        Button::new("tb-quick-open")
                            .small()
                            .ghost()
                            .icon(IconName::Search)
                            .tooltip("Search")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::QuickOpen);
                            })),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .flex_shrink_0()
                            .child(window_control(
                                "tb-window-minimize",
                                IconName::Minus,
                                false,
                                cx.listener(|_this, _event: &gpui_kit::ClickEvent, _window, cx| {
                                    cx.emit(ToolbarEvent::WindowMinimize);
                                }),
                            ))
                            .child(window_control(
                                "tb-window-maximize",
                                IconName::Square,
                                false,
                                cx.listener(|_this, _event: &gpui_kit::ClickEvent, _window, cx| {
                                    cx.emit(ToolbarEvent::WindowMaximize);
                                }),
                            ))
                            .child(window_control(
                                "tb-window-close",
                                IconName::Close,
                                true,
                                cx.listener(|_this, _event: &gpui_kit::ClickEvent, _window, cx| {
                                    cx.emit(ToolbarEvent::WindowClose);
                                }),
                            )),
                    ),
            )
    }
}

/// 构建一个窗口控件按钮：固定 46x40、直角，悬停高亮，Close 使用 destructive。
fn window_control(
    id: &'static str,
    icon: IconName,
    destructive: bool,
    on_click: impl Fn(&gpui_kit::ClickEvent, &mut Window, &mut gpui_kit::App) + 'static,
) -> impl IntoElement {
    let hover_bg = if destructive {
        ThemeColors::destructive()
    } else {
        ThemeColors::accent()
    };
    div()
        .id(id)
        .w(px(46.0))
        .h(px(40.0))
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .hover(move |h| h.bg(hover_bg))
        .on_click(on_click)
        .child(
            Icon::new(icon)
                .size(px(14.0))
                .text_color(ThemeColors::muted_foreground()),
        )
}
