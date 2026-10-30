//! 纯菜单数据层：把工作台状态快照映射成 `lithe_ui` 的声明式菜单描述。
//!
//! 本模块只做声明式数据组装：不持有实体、不做文件或网络 I/O、不 `spawn`
//! 异步任务，也不注册任何菜单动作的处理逻辑。调用方负责收集 [`MenuState`]、
//! 调用 [`build_menus`]，再把返回的 [`MenuSpec`] 交给 `lithe_ui` 的菜单栏。
//!
//! 菜单项的 checked / disabled 来自真实工作台状态（是否打开项目、是否有活动
//! 标签、dock 当前显示哪个工具窗），不是装饰性的占位勾选或永远可用的假动作。
//! 只有 `Workbench::run_menu_command` 已经接线的命令才允许可点击，未接线的
//! 条目一律禁用，宁可灰掉也不给用户假可用。
//!
//! 动态“最近项目”项把路径编码进 [`OPEN_RECENT_PREFIX`] 前缀的 command id，由
//! [`decode_open_recent`] 在派发时还原。
//!
//! 迁移说明（给工作台接线用）：[`MenuCommand`] 已移到
//! `lithe_ui::components::menu_bar`，这里只做 `pub(crate)` 再导出，避免
//! `workbench.rs` 的 `use crate::app_menu::MenuCommand` 断掉；同时
//! [`build_menus`] 的返回类型从 `gpui_kit` 的 `Menu` 变成 [`MenuSpec`]，
//! `install_menus` 需改为 `LitheMenuBar::set_menus`（不再走 `cx.set_menus`
//! 和 `AppMenuBar::reload`）。

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

use gpui_kit::SharedString;
use lithe_ui::components::menu_bar::{MenuItemSpec, MenuSpec};
use lithe_ui::i18n::tr;

/// 菜单派发的统一运行时命令。
///
/// 实现在 `lithe_ui::components::menu_bar`；这里保留再导出，工作台仍然可以
/// 通过 `crate::app_menu::MenuCommand` 引用同一个 action 类型。
pub(crate) use lithe_ui::components::menu_bar::MenuCommand;

/// 动态生成的“打开最近项目”菜单项的 command id 前缀。
///
/// 完整 id 形如 `file.openRecent:C:\path\to\project`；路径部分按
/// `Path::display()` 的原样拼入，保证菜单构建与派发两端一致。
pub(crate) const OPEN_RECENT_PREFIX: &str = "file.openRecent:";

/// 生成菜单所需的只读工作台状态快照。
///
/// 这里刻意只包含菜单外观会读取的字段，菜单构建不接触工作台实体本身。
pub(crate) struct MenuState {
    /// 是否已打开项目。
    pub(crate) has_project: bool,
    /// 当前是否存在活动编辑器标签。
    pub(crate) has_active_tab: bool,
    /// 最近打开的项目路径，按最近优先排序。
    pub(crate) recent_projects: Vec<PathBuf>,
    /// 左侧 dock 是否可见。
    pub(crate) left_visible: bool,
    /// 底部 dock 是否可见。
    pub(crate) bottom_visible: bool,
    /// 右侧 dock 是否可见。
    pub(crate) right_visible: bool,
    /// 左侧活动工具窗的稳定 id（`ToolWindow::id()`）。
    pub(crate) active_left: &'static str,
    /// 底部活动工具窗的稳定 id。
    pub(crate) active_bottom: Option<&'static str>,
    /// 右侧活动工具窗的稳定 id。
    pub(crate) active_right: Option<&'static str>,
    /// 当前是否暗色主题。
    pub(crate) dark: bool,
    /// 当前主题包 id：`lithe` / `codex` / `linear`，与设置里的主题名一致。
    pub(crate) theme: &'static str,
    /// 编辑器是否开启自动换行。
    pub(crate) wrap: bool,
    /// 编辑器是否显示 minimap。
    pub(crate) minimap: bool,
    /// 编辑器是否显示行号。
    pub(crate) line_numbers: bool,
    /// 编辑器是否渲染空白字符。
    pub(crate) render_whitespace: bool,
    /// 通知中心是否可见。
    pub(crate) notifications_visible: bool,
    /// 文件导航历史是否可后退。
    pub(crate) can_go_back: bool,
    /// 文件导航历史是否可前进。
    pub(crate) can_go_forward: bool,
    /// 是否有可恢复的已关闭文件。
    pub(crate) can_reopen_closed: bool,
    /// 菜单栏当前是否可见。
    pub(crate) menu_bar_visible: bool,
    /// 当前界面语言标识，来自 `lithe_ui::i18n::language()`。
    pub(crate) language: &'static str,
}

impl MenuState {
    /// 菜单标签、勾选和禁用状态所依赖的全部字段的哈希。
    ///
    /// 工作台缓存上一次的签名；签名变化（含语言切换、主题切换、最近项目变化）
    /// 时才重建菜单，避免每帧重复构造。
    pub(crate) fn signature(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        self.has_project.hash(&mut hasher);
        self.has_active_tab.hash(&mut hasher);
        self.recent_projects.hash(&mut hasher);
        self.left_visible.hash(&mut hasher);
        self.bottom_visible.hash(&mut hasher);
        self.right_visible.hash(&mut hasher);
        self.active_left.hash(&mut hasher);
        self.active_bottom.hash(&mut hasher);
        self.active_right.hash(&mut hasher);
        self.dark.hash(&mut hasher);
        self.theme.hash(&mut hasher);
        self.wrap.hash(&mut hasher);
        self.minimap.hash(&mut hasher);
        self.line_numbers.hash(&mut hasher);
        self.render_whitespace.hash(&mut hasher);
        self.notifications_visible.hash(&mut hasher);
        self.can_go_back.hash(&mut hasher);
        self.can_go_forward.hash(&mut hasher);
        self.can_reopen_closed.hash(&mut hasher);
        self.menu_bar_visible.hash(&mut hasher);
        self.language.hash(&mut hasher);
        hasher.finish()
    }
}

/// 按平台菜单顺序生成整棵应用菜单树。
pub(crate) fn build_menus(state: &MenuState) -> Vec<MenuSpec> {
    vec![
        file_menu(state),
        edit_menu(state),
        view_menu(state),
        go_menu(state),
        terminal_menu(state),
        run_menu(),
        tools_menu(),
        window_menu(state),
        help_menu(),
    ]
}

/// 从 `file.openRecent:` 命令中还原项目路径。
///
/// 前缀不匹配或路径部分为空时返回 `None`。
pub(crate) fn decode_open_recent(command: &str) -> Option<PathBuf> {
    let rest = command.strip_prefix(OPEN_RECENT_PREFIX)?;
    if rest.is_empty() {
        None
    } else {
        Some(PathBuf::from(rest))
    }
}

/// 命令是否已经被 `Workbench::run_menu_command` 接线。
///
/// 未接线时菜单项必须禁用：这里只承认工作台真正会处理的两类动态命令
/// （最近项目、已实现的工具窗）和下面显式列出的固定 id。
///
/// `view.tool.*` 不是整段放行：只有存在实际工具窗实现的 id 才算接线，其余
/// 仍由 [`item_state`] 统一禁用，避免未实现的工具窗在菜单里显示为可点击。
fn command_handled(command: &str) -> bool {
    if command.starts_with(OPEN_RECENT_PREFIX) {
        return true;
    }

    if let Some(tool) = command.strip_prefix("view.tool.") {
        return matches!(
            tool,
            "project"
                | "changes"
                | "search"
                | "git-log"
                | "terminal"
                | "agent"
                | "run"
                | "problems"
        );
    }

    matches!(
        command,
        // 编辑器命令：走 Monaco action 白名单。
        "edit.undo"
            | "edit.redo"
            | "edit.cut"
            | "edit.copy"
            | "edit.paste"
            | "edit.selectAll"
            | "edit.find"
            | "edit.replace"
            | "edit.findNext"
            | "edit.findPrevious"
            | "edit.toggleComment"
            | "edit.format"
            | "edit.formatSelection"
            | "edit.quickFix"
            | "edit.triggerParameterHints"
            | "edit.showHover"
            | "edit.duplicateLine"
            | "edit.deleteLine"
            | "edit.moveLineUp"
            | "edit.moveLineDown"
            | "edit.gotoLine"
            | "go.definition"
            | "go.implementation"
            | "go.typeDefinition"
            | "go.references"
            | "go.renameSymbol"
            | "go.nextTab"
            | "go.previousTab"
            // 项目、文件与设置。
            | "file.newTab"
            | "workbench.newTab"
            | "file.openProject"
            | "file.openFile"
            | "file.newFile"
            | "file.newFolder"
            | "file.newJavaType"
            | "file.newJavaPackage"
            | "file.newProject"
            | "file.newWindow"
            | "file.save"
            | "file.saveAs"
            | "file.closeFile"
            | "file.closeProject"
            | "file.closeAll"
            | "file.closeOthers"
            | "file.closeSaved"
            | "file.reopenClosed"
            | "file.saveAll"
            | "file.revert"
            | "file.localHistory"
            | "file.closeTabsToLeft"
            | "file.closeTabsToRight"
            | "file.settings"
            | "file.exit"
            // 布局、面板与焦点。
            | "view.dock.left"
            | "view.dock.bottom"
            | "view.dock.right"
            | "view.appearance.dark"
            | "view.wrap"
            | "view.commandPalette"
            | "view.searchEverywhere"
            | "view.notifications"
            | "view.theme.lithe"
            | "view.theme.codex"
            | "view.theme.linear"
            | "view.activityBar"
            | "view.secondarySidebar"
            | "view.globalSearch"
            | "view.fileExplorer"
            | "view.sourceControl"
            | "view.diagnostics"
            | "view.github"
            | "view.runAndDebug"
            | "view.minimap"
            | "view.lineNumbers"
            | "view.renderWhitespace"
            | "view.zoomIn"
            | "view.zoomOut"
            | "view.zoomReset"
            | "view.splitEditor"
            | "go.back"
            | "go.forward"
            | "window.toggleMenuBar"
            | "tools.keyboardShortcuts"
            | "help.keyboardShortcuts"
            | "help.whatsNew"
            | "help.changelog"
            | "help.reportBug"
            | "help.requestFeature"
            | "tools.commandPalette"
            | "tools.settings"
            // 搜索、终端与运行。
            | "go.quickOpen"
            | "go.findInFiles"
            | "go.replaceInFiles"
            | "terminal.new"
            | "terminal.clear"
            | "terminal.close"
            | "terminal.split"
            | "terminal.splitDown"
            | "run.run"
            | "run.debug"
            | "run.configurations"
            // 工具入口与窗口控制。
            | "tools.agent"
            | "tools.git"
            | "tools.database"
            | "tools.services"
            | "tools.webInspector"
            | "window.minimize"
            | "window.zoom"
            | "window.fullscreen"
            | "window.close"
            // 帮助菜单里已经有真实行为的条目。
            | "help.documentation"
            | "help.repository"
            | "help.checkUpdates"
            | "help.about"
    )
}

/// 一个普通动作菜单项；标签统一走 `tr`，快捷键是已格式化的 macOS 文案。
fn item(
    label: &'static str,
    command: &'static str,
    shortcut: Option<&'static str>,
) -> MenuItemSpec {
    item_state(label, command, shortcut, false, false)
}

/// 带勾选 / 额外禁用条件的菜单项。
///
/// 未接线的命令在这里统一兜底禁用，调用点只需要表达状态相关的禁用条件。
fn item_state(
    label: &'static str,
    command: &'static str,
    shortcut: Option<&'static str>,
    checked: bool,
    disabled: bool,
) -> MenuItemSpec {
    let mut spec = MenuItemSpec::action(tr(label), command)
        .checked(checked)
        .disabled(disabled || !command_handled(command));
    if let Some(shortcut) = shortcut {
        spec = spec.shortcut(lithe_ui::shortcut::display_shortcut(shortcut));
    }
    spec
}

fn file_menu(state: &MenuState) -> MenuSpec {
    let has_tab = state.has_active_tab;

    let new_items = vec![
        item("New Tab", "file.newTab", Some("⌘N")),
        item("New Window", "file.newWindow", Some("⇧⌘N")),
        item("New Project…", "file.newProject", None),
        item_state(
            "New File",
            "file.newFile",
            None,
            false,
            !state.has_project,
        ),
        item_state(
            "New Folder",
            "file.newFolder",
            None,
            false,
            !state.has_project,
        ),
        MenuItemSpec::separator(),
        item_state(
            "Java Class…",
            "file.newJavaType",
            None,
            false,
            !state.has_project,
        ),
        item_state(
            "Java Package…",
            "file.newJavaPackage",
            None,
            false,
            !state.has_project,
        ),
    ];

    MenuSpec::new(tr("File")).items([
        MenuItemSpec::submenu(tr("New"), new_items),
        item("Open Folder", "file.openProject", Some("⌘O")),
        item_state(
            "Close Folder",
            "file.closeProject",
            None,
            false,
            !state.has_project,
        ),
        MenuItemSpec::separator(),
        item_state("Save", "file.save", Some("⌘S"), false, !has_tab),
        item_state("Save As...", "file.saveAs", Some("⇧⌘S"), false, !has_tab),
        item_state("Save All", "file.saveAll", Some("⌥⌘S"), false, !has_tab),
        item_state("Revert File", "file.revert", None, false, !has_tab),
        item_state(
            "Show Local History",
            "file.localHistory",
            None,
            false,
            !state.has_active_tab,
        ),
        MenuItemSpec::separator(),
        item_state("Close Tab", "file.closeFile", Some("⌘W"), false, !has_tab),
        // 与 Window > Close Window 是同一个窗口动作，复用同一 id。
        item("Close Window", "window.close", Some("⇧⌘W")),
        item_state("Close All Tabs", "file.closeAll", None, false, !has_tab),
        item_state("Close Other Tabs", "file.closeOthers", None, false, !has_tab),
        item_state("Close Saved Tabs", "file.closeSaved", None, false, !has_tab),
        item_state(
            "Close Tabs to the Left",
            "file.closeTabsToLeft",
            None,
            false,
            !has_tab,
        ),
        item_state(
            "Close Tabs to the Right",
            "file.closeTabsToRight",
            None,
            false,
            !has_tab,
        ),
        item_state(
            "Reopen Closed Tab",
            "file.reopenClosed",
            Some("⇧⌘T"),
            false,
            !state.can_reopen_closed,
        ),
        MenuItemSpec::separator(),
        // Tauri 的 Settings 入口只在 Tools > Preferences，File 菜单不再重复。
        item("Quit", "file.exit", Some("⌘Q")),
    ])
}

/// “最近项目”条目：最多 10 条，空列表时给出禁用提示项。
#[allow(dead_code)]
fn recent_items(state: &MenuState) -> Vec<MenuItemSpec> {
    if state.recent_projects.is_empty() {
        return vec![item_state(
            "No Recent Projects",
            "file.noop",
            None,
            false,
            true,
        )];
    }

    state
        .recent_projects
        .iter()
        .take(10)
        .map(|path| recent_item(path))
        .collect()
}

/// 单条最近项目项：标签取文件名，command id 携带完整路径。
#[allow(dead_code)]
fn recent_item(path: &Path) -> MenuItemSpec {
    let label = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string());
    let command = format!("{OPEN_RECENT_PREFIX}{}", path.display());
    MenuItemSpec::action(SharedString::from(label), command)
}

fn edit_menu(state: &MenuState) -> MenuSpec {
    let disabled = !state.has_active_tab;

    MenuSpec::new(tr("Edit")).items([
        item_state("Undo", "edit.undo", Some("⌘Z"), false, disabled),
        item_state("Redo", "edit.redo", Some("⇧⌘Z"), false, disabled),
        MenuItemSpec::separator(),
        item_state("Cut", "edit.cut", Some("⌘X"), false, disabled),
        item_state("Copy", "edit.copy", Some("⌘C"), false, disabled),
        item_state("Paste", "edit.paste", Some("⌘V"), false, disabled),
        item_state("Select All", "edit.selectAll", Some("⌘A"), false, disabled),
        MenuItemSpec::separator(),
        item_state("Find", "edit.find", Some("⌘F"), false, disabled),
        item_state(
            "Find and Replace",
            "edit.replace",
            Some("⌥⌘F"),
            false,
            disabled,
        ),
        item_state(
            "Toggle Comment",
            "edit.toggleComment",
            Some("⌘/"),
            false,
            disabled,
        ),
        item_state("Quick Fix", "edit.quickFix", Some("⌘."), false, disabled),
        item_state(
            "Trigger Parameter Hints",
            "edit.triggerParameterHints",
            Some("⇧⌘Space"),
            false,
            disabled,
        ),
        item_state(
            "Show Hover",
            "edit.showHover",
            Some("⌘K ⌘I"),
            false,
            disabled,
        ),
        MenuItemSpec::separator(),
        item_state(
            "Duplicate Line",
            "edit.duplicateLine",
            Some("⌘D"),
            false,
            disabled,
        ),
        item_state(
            "Delete Line",
            "edit.deleteLine",
            Some("⇧⌘K"),
            false,
            disabled,
        ),
        item_state(
            "Move Line Up",
            "edit.moveLineUp",
            Some("⌥↑"),
            false,
            disabled,
        ),
        item_state(
            "Move Line Down",
            "edit.moveLineDown",
            Some("⌥↓"),
            false,
            disabled,
        ),
        item_state(
            "Format Document",
            "edit.format",
            Some("⌥⌘L"),
            false,
            disabled,
        ),
        item_state(
            "Format Selection",
            "edit.formatSelection",
            Some("⌘K ⌘F"),
            false,
            disabled,
        ),
        MenuItemSpec::separator(),
        item_state(
            "Command Palette",
            "view.commandPalette",
            Some("⇧⌘P"),
            false,
            disabled,
        ),
    ])
}

fn view_menu(state: &MenuState) -> MenuSpec {
    let left_active = |id: &str| state.left_visible && state.active_left == id;
    let bottom_active =
        |id: &str| state.bottom_visible && state.active_bottom.is_some_and(|active| active == id);
    let right_active =
        |id: &str| state.right_visible && state.active_right.is_some_and(|active| active == id);
    // 工具窗内容都来自当前项目，没有项目时禁用。
    let tools_disabled = !state.has_project;

    let tool_windows = vec![
        item_state(
            "Project",
            "view.tool.project",
            None,
            left_active("project"),
            tools_disabled,
        ),
        item_state(
            "Changes",
            "view.tool.changes",
            None,
            left_active("changes"),
            tools_disabled,
        ),
        item_state(
            "Search",
            "view.tool.search",
            None,
            left_active("search"),
            tools_disabled,
        ),
        item_state(
            "Pull Requests",
            "view.tool.pull-requests",
            None,
            left_active("pull-requests"),
            tools_disabled,
        ),
        MenuItemSpec::separator(),
        item_state(
            "Git Log",
            "view.tool.git-log",
            None,
            bottom_active("git-log"),
            tools_disabled,
        ),
        item_state(
            "Terminal",
            "view.tool.terminal",
            None,
            bottom_active("terminal"),
            tools_disabled,
        ),
        item_state(
            "Agent",
            "view.tool.agent",
            None,
            bottom_active("agent"),
            tools_disabled,
        ),
        item_state(
            "Run",
            "view.tool.run",
            None,
            bottom_active("run"),
            tools_disabled,
        ),
        item_state(
            "Debug",
            "view.tool.debug",
            None,
            bottom_active("debug"),
            tools_disabled,
        ),
        item_state(
            "Problems",
            "view.tool.problems",
            None,
            bottom_active("problems"),
            tools_disabled,
        ),
        item_state(
            "References",
            "view.tool.references",
            None,
            bottom_active("references"),
            tools_disabled,
        ),
        item_state(
            "Tests",
            "view.tool.tests",
            None,
            bottom_active("tests"),
            tools_disabled,
        ),
        item_state(
            "Build Output",
            "view.tool.build-output",
            None,
            bottom_active("build-output"),
            tools_disabled,
        ),
        item_state(
            "Spring",
            "view.tool.spring",
            None,
            bottom_active("spring"),
            tools_disabled,
        ),
        MenuItemSpec::separator(),
        item_state(
            "Database",
            "view.tool.database",
            None,
            right_active("database"),
            tools_disabled,
        ),
        item_state(
            "Services",
            "view.tool.services",
            None,
            right_active("services"),
            tools_disabled,
        ),
    ];

    let docks = vec![
        item_state(
            "Toggle Left Dock",
            "view.dock.left",
            None,
            state.left_visible,
            false,
        ),
        item_state(
            "Toggle Bottom Dock",
            "view.dock.bottom",
            None,
            state.bottom_visible,
            false,
        ),
        item_state(
            "Toggle Right Dock",
            "view.dock.right",
            None,
            state.right_visible,
            false,
        ),
    ];

    // 主题子菜单：id 与设置里的主题名一致，当前主题打勾。
    let themes = vec![
        item_state(
            "Lithe",
            "view.theme.lithe",
            None,
            state.theme == "lithe",
            false,
        ),
        item_state(
            "Codex",
            "view.theme.codex",
            None,
            state.theme == "codex",
            false,
        ),
        item_state(
            "Linear",
            "view.theme.linear",
            None,
            state.theme == "linear",
            false,
        ),
    ];

    let appearance = vec![
        item_state("Dark Mode", "view.appearance.dark", None, state.dark, false),
        item_state("Toggle Wrap", "view.wrap", Some("⌥Z"), state.wrap, false),
        MenuItemSpec::separator(),
        MenuItemSpec::submenu(tr("Theme"), themes),
    ];

    MenuSpec::new(tr("View")).items([
        item("Toggle Activity Sidebar", "view.activityBar", Some("⌘B")),
        item("Toggle Secondary Sidebar", "view.secondarySidebar", Some("⌘E")),
        item_state(
            "Toggle Terminal",
            "view.tool.terminal",
            Some("⌘J"),
            bottom_active("terminal"),
            tools_disabled,
        ),
        MenuItemSpec::separator(),
        item("Global Search", "view.globalSearch", Some("⇧⌘F")),
        item("Diagnostics", "view.diagnostics", Some("⇧⌘J")),
        MenuItemSpec::separator(),
        item("File Explorer", "view.fileExplorer", Some("⇧⌘E")),
        item("Source Control", "view.sourceControl", Some("⇧⌘G")),
        item("GitHub", "view.github", None),
        item("Run and Debug", "view.runAndDebug", None),
        MenuItemSpec::separator(),
        item("Split Editor", "view.splitEditor", None),
        item_state(
            "Toggle Minimap",
            "view.minimap",
            None,
            state.minimap,
            false,
        ),
        item_state(
            "Toggle Word Wrap",
            "view.wrap",
            Some("⌥Z"),
            state.wrap,
            false,
        ),
        item_state(
            "Toggle Line Numbers",
            "view.lineNumbers",
            None,
            state.line_numbers,
            false,
        ),
        item_state(
            "Toggle Render Whitespace",
            "view.renderWhitespace",
            None,
            state.render_whitespace,
            false,
        ),
        MenuItemSpec::separator(),
        item("Zoom In", "view.zoomIn", Some("⌘=")),
        item("Zoom Out", "view.zoomOut", Some("⌘-")),
        item("Reset Zoom", "view.zoomReset", Some("⌘0")),
        MenuItemSpec::separator(),
        MenuItemSpec::submenu(tr("Tool Windows"), tool_windows),
        MenuItemSpec::submenu(tr("Docks"), docks),
        MenuItemSpec::submenu(tr("Appearance"), appearance),
        MenuItemSpec::separator(),
        item("Command Palette", "view.commandPalette", Some("⇧⌘P")),
        item("Search Everywhere…", "view.searchEverywhere", None),
        item_state(
            "Notifications",
            "view.notifications",
            None,
            state.notifications_visible,
            false,
        ),
    ])
}

fn go_menu(state: &MenuState) -> MenuSpec {
    let disabled = !state.has_active_tab;

    MenuSpec::new(tr("Go")).items([
        item_state(
            "Quick Open",
            "go.quickOpen",
            Some("⌘P"),
            false,
            !state.has_project,
        ),
        // Go to Line 复用编辑器命令，菜单里的两处入口行为一致。
        item_state("Go to Line", "edit.gotoLine", Some("⌘G"), false, disabled),
        MenuItemSpec::separator(),
        item_state(
            "Go Back",
            "go.back",
            Some("⌃⌥←"),
            false,
            !state.can_go_back,
        ),
        item_state(
            "Go Forward",
            "go.forward",
            Some("⌃⌥→"),
            false,
            !state.can_go_forward,
        ),
        MenuItemSpec::separator(),
        item_state(
            "Go to Definition",
            "go.definition",
            Some("F12"),
            false,
            disabled,
        ),
        item_state(
            "Go to Implementation",
            "go.implementation",
            Some("⌘F12"),
            false,
            disabled,
        ),
        item_state(
            "Go to Type Definition",
            "go.typeDefinition",
            None,
            false,
            disabled,
        ),
        item_state(
            "Go to References",
            "go.references",
            Some("⌘B"),
            false,
            disabled,
        ),
        item_state(
            "Rename Symbol",
            "go.renameSymbol",
            Some("F2"),
            false,
            disabled,
        ),
        MenuItemSpec::separator(),
        item("Next Tab", "go.nextTab", Some("⌥⌘→")),
        item("Previous Tab", "go.previousTab", Some("⌥⌘←")),
        MenuItemSpec::separator(),
        item_state(
            "Find in Files…",
            "go.findInFiles",
            None,
            false,
            !state.has_project,
        ),
        item_state(
            "Replace in Files…",
            "go.replaceInFiles",
            None,
            false,
            !state.has_project,
        ),
    ])
}

fn terminal_menu(state: &MenuState) -> MenuSpec {
    let terminal_active = state.bottom_visible && state.active_bottom == Some("terminal");

    MenuSpec::new(tr("Terminal")).items([
        item("New Terminal", "terminal.new", None),
        item("Split Terminal Right", "terminal.split", Some("⌘D")),
        item("Split Terminal Down", "terminal.splitDown", Some("⇧⌘D")),
        item_state(
            "Clear Terminal",
            "terminal.clear",
            None,
            false,
            !terminal_active,
        ),
        item_state(
            "Close Terminal",
            "terminal.close",
            None,
            false,
            !terminal_active,
        ),
    ])
}

fn run_menu() -> MenuSpec {
    MenuSpec::new(tr("Run")).items([
        item("Start Debugging", "run.debug", None),
        item("Stop Debugging", "run.stop", Some("⇧F5")),
        item("Toggle Breakpoint", "run.toggleBreakpoint", Some("F9")),
        MenuItemSpec::separator(),
        item("Run", "run.run", Some("F5")),
        item("Run Configurations…", "run.configurations", None),
    ])
}

fn tools_menu() -> MenuSpec {
    MenuSpec::new(tr("Tools")).items([
        item("AI Agent", "tools.agent", None),
        item("Git", "tools.git", None),
        item("Database", "tools.database", None),
        item("Services", "tools.services", None),
        MenuItemSpec::separator(),
        item("Web Inspector", "tools.webInspector", Some("⌥⌘I")),
        MenuItemSpec::separator(),
        item("Command Palette", "view.commandPalette", Some("⇧⌘P")),
        item("Keyboard Shortcuts", "tools.keyboardShortcuts", None),
        item("Preferences", "tools.settings", None),
    ])
}

fn window_menu(state: &MenuState) -> MenuSpec {
    MenuSpec::new(tr("Window")).items([
        item("Minimize", "window.minimize", Some("⌥F9")),
        item("Maximize", "window.zoom", Some("⌥F10")),
        item("Toggle Fullscreen", "window.fullscreen", Some("F11")),
        item_state(
            "Toggle Menu Bar",
            "window.toggleMenuBar",
            Some("⌥M"),
            state.menu_bar_visible,
            false,
        ),
        MenuItemSpec::separator(),
        item("Close Window", "window.close", None),
    ])
}

fn help_menu() -> MenuSpec {
    MenuSpec::new(tr("Help")).items([
        item("Documentation", "help.documentation", None),
        item("Lithe Repository", "help.repository", None),
        item("Keyboard Shortcuts", "help.keyboardShortcuts", None),
        item("What's New", "help.whatsNew", None),
        item("Changelog", "help.changelog", None),
        MenuItemSpec::separator(),
        item("Report a Bug", "help.reportBug", None),
        item("Request a Feature", "help.requestFeature", None),
        MenuItemSpec::separator(),
        item("Check for Updates", "help.checkUpdates", None),
        item("About Lithe", "help.about", None),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> MenuState {
        MenuState {
            has_project: false,
            has_active_tab: false,
            recent_projects: Vec::new(),
            left_visible: true,
            bottom_visible: false,
            right_visible: false,
            active_left: "project",
            active_bottom: None,
            active_right: None,
            dark: true,
            theme: "lithe",
            wrap: false,
            minimap: false,
            line_numbers: true,
            render_whitespace: false,
            notifications_visible: false,
            can_go_back: false,
            can_go_forward: false,
            can_reopen_closed: false,
            menu_bar_visible: true,
            language: "en-US",
        }
    }

    fn action<'a>(menu: &'a MenuSpec, command: &str) -> Option<&'a MenuItemSpec> {
        menu.items.iter().find(|item| match item {
            MenuItemSpec::Action { command: id, .. } => id.as_ref() == command,
            _ => false,
        })
    }

    fn is_disabled(item: &MenuItemSpec) -> bool {
        matches!(item, MenuItemSpec::Action { disabled: true, .. })
    }

    #[test]
    fn builds_nine_top_level_menus_in_prototype_order() {
        let menus = build_menus(&state());
        let labels: Vec<&str> = menus.iter().map(|menu| menu.label.as_ref()).collect();

        assert_eq!(
            labels,
            [
                "File", "Edit", "View", "Go", "Terminal", "Run", "Tools", "Window", "Help"
            ]
        );
    }

    #[test]
    fn tab_actions_are_disabled_without_active_tab() {
        let menus = build_menus(&state());
        let file = &menus[0];
        let edit = &menus[1];

        assert!(is_disabled(action(file, "file.save").expect("save item")));
        assert!(is_disabled(action(edit, "edit.undo").expect("undo item")));
        assert!(is_disabled(action(edit, "edit.find").expect("find item")));
    }

    #[test]
    fn unchecked_wrap_state_is_reported_as_checked_false() {
        let menus = build_menus(&state());
        let wrap = action(&menus[2], "view.wrap").expect("wrap item");

        assert!(matches!(wrap, MenuItemSpec::Action { checked: false, .. }));
    }

    #[test]
    fn unimplemented_tool_windows_stay_disabled() {
        let mut state = state();
        state.has_project = true;

        let menus = build_menus(&state);
        let tool_windows = menus[2]
            .items
            .iter()
            .find_map(|item| match item {
                MenuItemSpec::Submenu { label, items } if label.as_ref() == "Tool Windows" => {
                    Some(items)
                }
                _ => None,
            })
            .expect("tool windows submenu");

        let tool_window = |command: &str| {
            tool_windows
                .iter()
                .find(|item| match item {
                    MenuItemSpec::Action { command: id, .. } => id.as_ref() == command,
                    _ => false,
                })
                .expect("tool window item")
        };

        // 已实现的工具窗保持可用；未实现的只靠白名单变灰。
        assert!(!is_disabled(tool_window("view.tool.project")));
        assert!(!is_disabled(tool_window("view.tool.terminal")));
        assert!(is_disabled(tool_window("view.tool.pull-requests")));
        assert!(is_disabled(tool_window("view.tool.tests")));
        assert!(is_disabled(tool_window("view.tool.services")));
    }

    #[test]
    fn recent_projects_encode_their_path_in_the_command() {
        let path = PathBuf::from("/tmp/demo-project");
        let item = recent_item(&path);
        let command = match item {
            MenuItemSpec::Action { command, .. } => command,
            _ => panic!("expected an action item"),
        };
        assert_eq!(
            decode_open_recent(&command),
            Some(PathBuf::from("/tmp/demo-project"))
        );
    }

    #[test]
    fn file_menu_matches_tauri_specification() {
        let menus = build_menus(&state());
        let file = &menus[0];
        let commands: Vec<&str> = file
            .items
            .iter()
            .filter_map(|item| match item {
                MenuItemSpec::Action { command, .. } => Some(command.as_ref()),
                _ => None,
            })
            .collect();

        assert_eq!(
            commands,
            [
                "file.openProject",
                "file.closeProject",
                "file.save",
                "file.saveAs",
                "file.saveAll",
                "file.revert",
                "file.localHistory",
                "file.closeFile",
                "window.close",
                "file.closeAll",
                "file.closeOthers",
                "file.closeSaved",
                "file.closeTabsToLeft",
                "file.closeTabsToRight",
                "file.reopenClosed",
                "file.exit",
            ]
        );
    }
}
