//! 顶部标题栏/工具栏：复刻 Tauri `title-bar.tsx` + `window-menu-bar.tsx`。
//!
//! 结构从左到右：应用菜单栏（紧凑或九宫格）、品牌、项目胶囊、分支胶囊、
//! 居中全局搜索条、运行目标胶囊、运行/调试/停止、主题与设置、窗口控件。
//! 所有交互只通过 [`ToolbarEvent`] 向外广播，具体业务由 `view.rs` 订阅处理。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Selectable as _, Sizable as _};
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
    /// 打开最近项目中的指定路径（项目胶囊“最近项目”分组条目）。
    OpenRecentProject(String),
    /// 打开分支管理器弹窗（分支徽标按钮，对齐 Tauri `GitBranchManager`）。
    OpenBranchManager,
}

/// 应用图标：与 Tauri 端 `public/logo.png` 同一文件，编译期嵌入。
const APP_LOGO_PNG: &[u8] = include_bytes!("../../assets/logo.png");

pub struct ToolbarView {
    pub workspace_root: String,
    pub workspace_name: String,
    pub git_branch: Option<String>,
    /// 紧凑菜单条是否展开（对齐 Tauri `isCompactMenuVisible`）。
    compact_menu_open: bool,
    /// 解码后的应用图标，项目菜单触发器左侧的徽标（对齐 Tauri 的 `logo.png`）。
    app_logo: std::sync::Arc<gpui_kit::Image>,
}

impl EventEmitter<ToolbarEvent> for ToolbarView {}

impl ToolbarView {
    pub fn new(workspace_root: &str) -> Self {
        Self {
            workspace_root: workspace_root.to_string(),
            workspace_name: workspace_dir_name(workspace_root),
            git_branch: None,
            compact_menu_open: false,
            app_logo: std::sync::Arc::new(gpui_kit::Image::from_bytes(
                gpui_kit::ImageFormat::Png,
                APP_LOGO_PNG.to_vec(),
            )),
        }
    }

    pub fn set_git_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) {
        self.git_branch = branch;
        cx.notify();
    }

    /// 同步当前 workspace：项目胶囊触发器名称与“打开的项目”行跟随切换。
    pub fn set_workspace_root(&mut self, root: String, cx: &mut Context<Self>) {
        self.workspace_root = root.clone();
        self.workspace_name = workspace_dir_name(&root);
        cx.notify();
    }
}

/// 取 workspace 目录名（项目胶囊触发器与当前项目行主行共用）。
fn workspace_dir_name(workspace_root: &str) -> String {
    workspace_root
        .rsplit_once('/')
        .map(|(_, n)| n.to_string())
        .unwrap_or_else(|| workspace_root.to_string())
}

/// 单个菜单项：i18n 键（`crate::i18n::menu_text`）+ 稳定动作 id + 快捷键展示文本。
///
/// 分组与条目顺序严格照抄 Tauri `window-menu-bar.tsx`，`action` 字符串与
/// `view.rs` 接入约定一致，不可改动；Linux 上 `mod` 展示为 `Ctrl`。
struct MenuEntry {
    key: &'static str,
    action: &'static str,
    shortcut: &'static str,
    disabled: bool,
}

/// 便于在 `const` 菜单表中声明条目。
const fn entry(key: &'static str, action: &'static str, shortcut: &'static str) -> MenuEntry {
    MenuEntry {
        key,
        action,
        shortcut,
        disabled: false,
    }
}

/// 禁用条目（如 Tools 首项 databases，后端能力缺失时不可点）。
const fn disabled_entry(
    key: &'static str,
    action: &'static str,
    shortcut: &'static str,
) -> MenuEntry {
    MenuEntry {
        key,
        action,
        shortcut,
        disabled: true,
    }
}

/// 一个顶层应用菜单：i18n 标题键 + 分组（分组之间渲染分隔线）。
struct AppMenu {
    key: &'static str,
    groups: &'static [&'static [MenuEntry]],
}

// ---- File：对齐 tsx File 菜单四组（含分隔线位置） ----
const FILE_MENU: &[&[MenuEntry]] = &[
    &[
        entry("menu.newTab", "file.new_tab", "Ctrl+T"),
        entry("menu.newWindow", "file.new_window", "Ctrl+Shift+N"),
        entry("menu.newFile", "file.new_file", ""),
        entry("menu.openFolder", "file.open_folder", "Ctrl+O"),
        entry("menu.closeFolder", "file.close_folder", ""),
    ],
    &[
        entry("menu.save", "file.save", "Ctrl+S"),
        entry("menu.saveAs", "file.save_as", "Ctrl+Shift+S"),
        entry("menu.saveAll", "file.save_all", "Ctrl+Alt+S"),
        entry("menu.revertFile", "file.revert", ""),
        disabled_entry("menu.showLocalHistory", "file.local_history", ""),
    ],
    &[
        entry("menu.closeTab", "file.close_editor", "Ctrl+W"),
        entry("menu.closeWindow", "file.close_window", "Ctrl+Shift+W"),
        entry("menu.closeAllTabs", "file.close_all", ""),
        entry("menu.closeOtherTabs", "file.close_others", ""),
        entry("menu.closeSavedTabs", "file.close_saved", ""),
        entry("menu.closeTabsToLeft", "file.close_left", ""),
        entry("menu.closeTabsToRight", "file.close_right", ""),
        entry("menu.reopenClosedTab", "file.reopen_closed", "Ctrl+Shift+T"),
    ],
    &[entry("menu.quit", "file.exit", "Ctrl+Q")],
];

// ---- Edit：对齐 tsx Edit 菜单五组 ----
const EDIT_MENU: &[&[MenuEntry]] = &[
    &[
        entry("menu.undo", "edit.undo", "Ctrl+Z"),
        entry("menu.redo", "edit.redo", "Ctrl+Shift+Z"),
    ],
    &[
        entry("menu.cut", "edit.cut", "Ctrl+X"),
        entry("menu.copy", "edit.copy", "Ctrl+C"),
        entry("menu.paste", "edit.paste", "Ctrl+V"),
        entry("menu.selectAll", "edit.select_all", "Ctrl+A"),
    ],
    &[
        entry("menu.find", "edit.find", "Ctrl+F"),
        entry("menu.findAndReplace", "edit.find_replace", "Ctrl+Alt+F"),
        entry("menu.toggleComment", "edit.toggle_comment", "Ctrl+/"),
        disabled_entry("menu.quickFix", "edit.quick_fix", "Ctrl+."),
        disabled_entry(
            "menu.triggerParameterHints",
            "edit.param_hints",
            "Ctrl+Shift+Space",
        ),
        disabled_entry("menu.showHover", "edit.show_hover", "Ctrl+K Ctrl+I"),
    ],
    &[
        entry("menu.duplicateLine", "edit.duplicate_line", "Ctrl+D"),
        entry("menu.deleteLine", "edit.delete_line", "Ctrl+Shift+K"),
        entry("menu.moveLineUp", "edit.move_up", "Alt+Up"),
        entry("menu.moveLineDown", "edit.move_down", "Alt+Down"),
        disabled_entry("menu.formatDocument", "edit.format_doc", "Ctrl+Alt+L"),
        disabled_entry("menu.formatSelection", "edit.format_sel", "Ctrl+K Ctrl+F"),
    ],
    &[entry(
        "menu.commandPalette",
        "view.command_palette",
        "Ctrl+Shift+P",
    )],
];

// ---- View：对齐 tsx View 菜单六组（末尾 Theme 子菜单由 build_menu 追加） ----
const VIEW_MENU: &[&[MenuEntry]] = &[
    &[
        entry(
            "menu.toggleActivitySidebar",
            "view.toggle_activity_rail",
            "Ctrl+B",
        ),
        entry(
            "menu.toggleSecondarySidebar",
            "view.toggle_sidebar",
            "Ctrl+E",
        ),
        entry("menu.toggleTerminal", "view.toggle_bottom_panel", "Ctrl+J"),
    ],
    &[
        entry("menu.globalSearch", "view.global_search", "Ctrl+Shift+F"),
        entry("menu.diagnostics", "view.diagnostics", "Ctrl+Shift+J"),
    ],
    &[
        entry("menu.fileExplorer", "view.show_explorer", "Ctrl+Shift+E"),
        entry("menu.sourceControl", "view.show_git", "Ctrl+Shift+G"),
        entry("menu.github", "view.show_github", ""),
        entry("menu.runAndDebug", "view.show_debug", ""),
    ],
    &[
        disabled_entry("menu.splitEditor", "view.split_editor", ""),
        disabled_entry("menu.toggleMinimap", "view.toggle_minimap", ""),
        entry("menu.toggleWordWrap", "view.toggle_wrap", "Alt+Z"),
        entry("menu.toggleLineNumbers", "view.toggle_line_numbers", ""),
        entry("menu.toggleRenderWhitespace", "view.toggle_whitespace", ""),
    ],
    &[
        entry("menu.zoomIn", "view.zoom_in", "Ctrl+="),
        entry("menu.zoomOut", "view.zoom_out", "Ctrl+-"),
        entry("menu.resetZoom", "view.reset_zoom", "Ctrl+0"),
    ],
];

// ---- Go：对齐 tsx Go 菜单四组 ----
const GO_MENU: &[&[MenuEntry]] = &[
    &[
        entry("menu.quickOpen", "view.quick_open", "Ctrl+P"),
        entry("menu.goToLine", "go.go_to_line", "Ctrl+G"),
    ],
    &[
        disabled_entry("menu.goBack", "go.back", "Ctrl+Alt+Left"),
        disabled_entry("menu.goForward", "go.forward", "Ctrl+Alt+Right"),
    ],
    &[
        disabled_entry("menu.goToDefinition", "go.definition", "F12"),
        disabled_entry("menu.goToImplementation", "go.implementation", "Ctrl+F12"),
        disabled_entry("menu.goToTypeDefinition", "go.type_definition", ""),
        disabled_entry("menu.goToReferences", "go.references", "Ctrl+B"),
        disabled_entry("menu.renameSymbol", "go.rename", "F2"),
    ],
    &[
        entry("menu.nextTab", "go.next_tab", "Ctrl+Alt+Right"),
        entry("menu.previousTab", "go.prev_tab", "Ctrl+Alt+Left"),
    ],
];

// ---- Terminal：对齐 tsx，单组无分隔线 ----
const TERMINAL_MENU: &[&[MenuEntry]] = &[&[
    entry("menu.newTerminal", "terminal.new", ""),
    disabled_entry("menu.splitTerminalRight", "terminal.split_right", "Ctrl+D"),
    disabled_entry(
        "menu.splitTerminalDown",
        "terminal.split_down",
        "Ctrl+Shift+D",
    ),
    entry("menu.closeTerminal", "terminal.close", ""),
]];

// ---- Run：对齐 tsx，单组无分隔线 ----
const RUN_MENU: &[&[MenuEntry]] = &[&[
    disabled_entry("menu.startDebugging", "run.debug_start", "F5"),
    disabled_entry("menu.stopDebugging", "run.debug_stop", "Shift+F5"),
    disabled_entry("menu.toggleBreakpoint", "run.breakpoint", "F9"),
]];

// ---- Tools：对齐 tsx 三组（首项 databases 禁用，对齐后端能力缺失） ----
const TOOLS_MENU: &[&[MenuEntry]] = &[
    &[disabled_entry("menu.databases", "tools.database", "")],
    &[disabled_entry(
        "menu.webInspector",
        "tools.inspector",
        "Ctrl+Alt+I",
    )],
    &[
        entry("menu.preferences", "tools.settings", ""),
        entry("menu.keyboardShortcuts", "tools.shortcuts", ""),
    ],
];

// ---- Window：对齐 tsx，Linux 下不要 toggleMenuBar 那一段，单组无分隔线 ----
const WINDOW_MENU: &[&[MenuEntry]] = &[&[
    entry("menu.minimize", "window.minimize", "Alt+F9"),
    entry("menu.maximize", "window.maximize", "Alt+F10"),
    entry("menu.toggleFullscreen", "window.fullscreen", "F11"),
]];

// ---- Help：对齐 tsx 三组 ----
const HELP_MENU: &[&[MenuEntry]] = &[
    &[
        entry("menu.documentation", "help.docs", ""),
        entry("menu.keyboardShortcuts", "help.shortcuts", ""),
        disabled_entry("menu.whatsNew", "help.whats_new", ""),
        entry("menu.changelog", "help.changelog", ""),
    ],
    &[
        entry("menu.reportBug", "help.report_bug", ""),
        entry("menu.requestFeature", "help.feature", ""),
    ],
    &[disabled_entry(
        "menu.checkForUpdates",
        "help.check_updates",
        "",
    )],
];

const APP_MENUS: &[AppMenu] = &[
    AppMenu {
        key: "menu.file",
        groups: FILE_MENU,
    },
    AppMenu {
        key: "menu.edit",
        groups: EDIT_MENU,
    },
    AppMenu {
        key: "menu.view",
        groups: VIEW_MENU,
    },
    AppMenu {
        key: "menu.go",
        groups: GO_MENU,
    },
    AppMenu {
        key: "menu.terminal",
        groups: TERMINAL_MENU,
    },
    AppMenu {
        key: "menu.run",
        groups: RUN_MENU,
    },
    AppMenu {
        key: "menu.tools",
        groups: TOOLS_MENU,
    },
    AppMenu {
        key: "menu.window",
        groups: WINDOW_MENU,
    },
    AppMenu {
        key: "menu.help",
        groups: HELP_MENU,
    },
];

/// 构造一个发出 `MenuAction(id)` 的菜单项。
///
/// 用 `PopupMenuItem::element` 自定义行：左侧标签占满（`text_xs`），右侧快捷键
/// （`text_xs` + 弱化色，无快捷键不渲染），对齐 Tauri `MenubarItem` 左右结构；
/// `ElementItem` 同样享受 hover 高亮。
fn menu_action_item(
    label: String,
    shortcut: String,
    action: &'static str,
    disabled: bool,
    view: &gpui_kit::Entity<ToolbarView>,
) -> PopupMenuItem {
    let v = view.clone();
    // element 闭包只有 `&mut Window, &mut App`，翻译好的 owned 文案 move 进来。
    PopupMenuItem::element(move |_window, _cx| {
        let label = label.clone();
        let shortcut = shortcut.clone();
        let mut row = h_flex().w_full().items_center().gap_2().child(
            div()
                .flex_1()
                .text_xs()
                .text_color(ThemeColors::foreground())
                .child(label),
        );
        if !shortcut.is_empty() {
            row = row.child(
                div()
                    .text_xs()
                    .text_color(ThemeColors::subtle_foreground())
                    .child(shortcut),
            );
        }
        row
    })
    .disabled(disabled)
    .on_click(move |_, _, cx| {
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

/// 最近项目条目：目录名主行 + 全路径副行，对齐 Tauri `ProjectMenuRow`。
fn recent_project_item(
    name: String,
    path: String,
    view: &gpui_kit::Entity<ToolbarView>,
) -> PopupMenuItem {
    let v = view.clone();
    let open_path = path.clone();
    // element 闭包是 Fn，多次调用时 clone 使用。
    PopupMenuItem::element(move |_window, _cx| {
        let name = name.clone();
        let path = path.clone();
        v_flex()
            .w_full()
            .min_w_0()
            .child(
                div()
                    .w_full()
                    .truncate()
                    .text_xs()
                    .text_color(ThemeColors::foreground())
                    .child(name),
            )
            .child(
                div()
                    .w_full()
                    .truncate()
                    .text_xs()
                    .text_color(ThemeColors::subtle_foreground())
                    .child(path),
            )
    })
    .on_click(move |_, _, cx| {
        let path = open_path.clone();
        v.update(cx, |this, cx| {
            this.compact_menu_open = false;
            cx.emit(ToolbarEvent::OpenRecentProject(path));
        });
    })
}

/// 当前项目行：复用最近项目条目的两行样式，右侧加 Check，不可点。
///
/// 单根架构下“打开的项目”分组只渲染当前 workspace 这一行，对齐 Tauri
/// `ProjectMenuRow` 当前项（`if (project.isActive) return`，点击无动作）。
fn current_project_item(name: String, path: String) -> PopupMenuItem {
    PopupMenuItem::element(move |_window, _cx| {
        let name = name.clone();
        let path = path.clone();
        h_flex()
            .w_full()
            .items_center()
            .gap_2()
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .w_full()
                            .truncate()
                            .text_xs()
                            .text_color(ThemeColors::foreground())
                            .child(name),
                    )
                    .child(
                        div()
                            .w_full()
                            .truncate()
                            .text_xs()
                            .text_color(ThemeColors::subtle_foreground())
                            .child(path),
                    ),
            )
            .child(
                Icon::new(IconName::Check)
                    .size(px(14.0))
                    .text_color(ThemeColors::primary()),
            )
    })
    .disabled(true)
}

/// 按分组把菜单项灌入 `PopupMenu`，分组之间自动插入分隔线。
///
/// 文案在 builder 内用 `cx`（`&mut Context<PopupMenu>`）实时解析；
/// View 菜单末尾追加 Theme 子菜单（Lithe Dark / Lithe Light），对齐 tsx 的
/// `MenubarSub`（主题列表在 Linux 端固定两项）。
fn build_menu(
    mut menu: PopupMenu,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
    app_key: &'static str,
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
            let label = crate::i18n::menu_text(cx, item.key).to_string();
            menu = menu.item(menu_action_item(
                label,
                item.shortcut.to_string(),
                item.action,
                item.disabled,
                view,
            ));
        }
    }
    if app_key == "menu.view" {
        let theme_label = crate::i18n::menu_text(cx, "menu.theme").to_string();
        let v = view.clone();
        // submenu 闭包要求 'static，view 需 clone 成 owned 再 move。
        menu = menu
            .separator()
            .submenu(theme_label, window, cx, move |sub, _w, _cx| {
                sub.item(menu_action_item(
                    "Lithe Dark".to_string(),
                    String::new(),
                    "menu.theme.lithe-dark",
                    false,
                    &v,
                ))
                .item(menu_action_item(
                    "Lithe Light".to_string(),
                    String::new(),
                    "menu.theme.lithe-light",
                    false,
                    &v,
                ))
            });
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

        // 项目胶囊下拉文案：翻译在 render 内用 cx 解析成 owned String 再 move 进闭包
        //（dropdown_menu 的 builder 闭包是 Fn，多次调用时 clone 使用）。
        // 必须放在紧凑菜单 `.when(open, move ...)` 之前，避免 cx 被 move 后再借用。
        let t_new_project = crate::i18n::menu_text(cx, "titleProject.newProject").to_string();
        let t_open = crate::i18n::menu_text(cx, "titleProject.open").to_string();
        let t_clone = crate::i18n::menu_text(cx, "titleProject.cloneRepository").to_string();
        let t_open_projects = crate::i18n::menu_text(cx, "titleProject.openProjects").to_string();
        let t_recent = crate::i18n::menu_text(cx, "titleProject.recentProjects").to_string();
        let t_no_recent = crate::i18n::menu_text(cx, "titleProject.noRecentProjects").to_string();
        // 当前 workspace：打开的项目分组只渲染这一行（单根架构，对齐 Tauri 当前项打 Check）。
        let current_root = self.workspace_root.clone();
        // 最近项目（首位最新，过滤不存在的路径与当前已打开路径，上限与持久化数组一致）。
        let recents: Vec<(String, String)> = settings::get(cx)
            .recent_projects
            .iter()
            .filter(|p| p.as_str() != current_root && std::path::Path::new(p).exists())
            .take(settings::MAX_RECENT_PROJECTS)
            .map(|p| (settings::project_dir_name(p).to_string(), p.clone()))
            .collect();

        // 九个顶层菜单标题：render 入口处一次性翻译成 owned String，
        // 后续 move 闭包只搬运字符串，不再借用 cx（避免 cx 被 move 后再借用）。
        let menu_titles: Vec<String> = APP_MENUS
            .iter()
            .map(|app| crate::i18n::menu_text(cx, app.key).to_string())
            .collect();

        // 应用菜单栏：紧凑模式为 Menu 图标触发一个横向浮出的菜单条（九个菜单名并排，
        // 各自下拉），对齐 Tauri `compactFloating` 的 `Menubar`；非紧凑模式平铺九个顶层菜单。
        // 顶层标题用 i18n 翻译，不再用英文常量。
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
                        .selected(open)
                        .on_click(cx.listener(
                            |this, _event: &gpui_kit::ClickEvent, _window, cx| {
                                this.compact_menu_open = !this.compact_menu_open;
                                cx.notify();
                            },
                        )),
                )
                .when(open, move |this| {
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
                                    // 紧凑菜单条不挂 `on_mouse_down_out`：下拉弹窗渲染在
                                    // overlay 层，点击弹窗项会被判为“条外”而在 click
                                    // 完成前销毁弹窗，导致所有菜单项无法触发。
                                    // 收起由汉堡按钮切换与菜单项自身处理。
                                    .children(APP_MENUS.iter().enumerate().map(|(ix, app)| {
                                        let v_item = v_menu.clone();
                                        let key = app.key;
                                        let groups = app.groups;
                                        let title = menu_titles[ix].clone();
                                        Button::new(format!("tb-compact-menu-{key}"))
                                            .small()
                                            .ghost()
                                            .label(title)
                                            .dropdown_menu(move |menu, window, cx| {
                                                build_menu(menu, window, cx, key, groups, &v_item)
                                            })
                                    })),
                            ),
                    ))
                });
            trigger.into_any_element()
        } else {
            h_flex()
                .items_center()
                .children(APP_MENUS.iter().enumerate().map(|(ix, app)| {
                    let v = view.clone();
                    let key = app.key;
                    let groups = app.groups;
                    let title = menu_titles[ix].clone();
                    Button::new(format!("tb-menu-{key}"))
                        .small()
                        .ghost()
                        .label(title)
                        .dropdown_menu(move |menu, window, cx| {
                            build_menu(menu, window, cx, key, groups, &v)
                        })
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
                        // 项目菜单：应用图标 + 项目名 + ChevronDown，点击展开项目列表
                        let v = view.clone();
                        let name = project_name.clone();
                        let current_name = project_name.clone();
                        let current_root = current_root.clone();
                        let logo = self.app_logo.clone();
                        Button::new("tb-project-selector")
                            .small()
                            .ghost()
                            .child(
                                // 项目徽标：Tauri 用 public/logo.png（size-5 圆角），保持一致。
                                div()
                                    .size(px(20.0))
                                    .flex_shrink_0()
                                    .rounded(px(6.0))
                                    .overflow_hidden()
                                    .child(
                                        gpui_kit::img(gpui_kit::ImageSource::Image(logo))
                                            .size_full(),
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
                            .dropdown_menu(move |mut menu, _window, _cx| {
                                menu = menu
                                    .item(event_item(
                                        t_new_project.clone(),
                                        || ToolbarEvent::NewProject,
                                        &v,
                                    ))
                                    .item(event_item(
                                        t_open.clone(),
                                        || ToolbarEvent::OpenProject,
                                        &v,
                                    ))
                                    .item(event_item(
                                        t_clone.clone(),
                                        || ToolbarEvent::CloneRepository,
                                        &v,
                                    ))
                                    .separator()
                                    // 打开的项目分组标签：只展示，不可点；下方单根只渲染当前项目行。
                                    .item(PopupMenuItem::label(t_open_projects.clone()))
                                    .item(current_project_item(
                                        current_name.clone(),
                                        current_root.clone(),
                                    ))
                                    .separator()
                                    .item(PopupMenuItem::label(t_recent.clone()));
                                if recents.is_empty() {
                                    menu = menu.item(PopupMenuItem::label(t_no_recent.clone()));
                                } else {
                                    for (name, path) in &recents {
                                        menu = menu.item(recent_project_item(
                                            name.clone(),
                                            path.clone(),
                                            &v,
                                        ));
                                    }
                                }
                                menu
                            })
                    })
                    .child({
                        // 分支徽标：普通按钮，点击打开分支管理器弹窗
                        //（对齐 Tauri `GitBranchManager`）；无仓库时禁用。
                        let has_repo = self.git_branch.is_some();
                        Button::new("tb-branch-selector")
                            .small()
                            .ghost()
                            .disabled(!has_repo)
                            .child(
                                Icon::new(IconName::GitBranch)
                                    .size(px(13.0))
                                    .text_color(ThemeColors::success()),
                            )
                            .child(
                                div()
                                    .max_w(px(160.0))
                                    .truncate()
                                    .text_xs()
                                    .text_color(ThemeColors::success())
                                    .child(branch.clone()),
                            )
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::OpenBranchManager);
                            }))
                    }),
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
                            .tooltip(crate::i18n::menu_text(cx, "menu.quickOpen"))
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
