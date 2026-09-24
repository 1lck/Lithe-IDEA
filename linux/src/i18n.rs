//! 菜单文案国际化：键与 Tauri `menu.*` / `titleProject.*` 对齐，按设置取中英文。
//!
//! 真源对应关系：
//! - 键名与 [`menu_text`] 的中英文逐条抄自
//!   `windows/tauri/src/i18n/locale.ts`（英文 `menu.*`、中文 `menu.*`、
//!   `titleProject.*`），不臆造；键不存在返回 `""`。
//! - 中英文切换依据 `display_language`（`linux/src/settings.rs`），
//!   以 `zh` 开头取中文，否则取英文，与 Tauri 按语言取文案一致。

use gpui_kit::App;

use crate::settings;

/// 当前是否为中文（`display_language` 以 `zh` 开头即中文）。
pub fn is_zh(cx: &App) -> bool {
    settings::get(cx).display_language.starts_with("zh")
}

/// 取菜单文案：键与 Tauri `menu.*` / `titleProject.*` 对齐，不存在返回 `""`。
pub fn menu_text(cx: &App, key: &str) -> &'static str {
    let (zh, en) = match key {
        // ---- 顶层菜单标题 ----
        "menu.file" => ("文件", "File"),
        "menu.edit" => ("编辑", "Edit"),
        "menu.view" => ("视图", "View"),
        "menu.go" => ("转到", "Go"),
        "menu.terminal" => ("终端", "Terminal"),
        "menu.run" => ("运行", "Run"),
        "menu.tools" => ("工具", "Tools"),
        "menu.window" => ("窗口", "Window"),
        "menu.help" => ("帮助", "Help"),
        "menu.theme" => ("主题", "Theme"),
        // ---- File ----
        "menu.newTab" => ("新建标签页", "New Tab"),
        "menu.newWindow" => ("新建窗口", "New Window"),
        "menu.newFile" => ("新建文件", "New File"),
        "menu.openFolder" => ("打开文件夹", "Open Folder"),
        "menu.closeFolder" => ("关闭文件夹", "Close Folder"),
        "menu.save" => ("保存", "Save"),
        "menu.saveAs" => ("另存为...", "Save As..."),
        "menu.saveAll" => ("全部保存", "Save All"),
        "menu.revertFile" => ("还原文件", "Revert File"),
        "menu.showLocalHistory" => ("显示本地历史", "Show Local History"),
        "menu.closeTab" => ("关闭标签页", "Close Tab"),
        "menu.closeWindow" => ("关闭窗口", "Close Window"),
        "menu.closeAllTabs" => ("关闭所有标签页", "Close All Tabs"),
        "menu.closeOtherTabs" => ("关闭其他标签页", "Close Other Tabs"),
        "menu.closeSavedTabs" => ("关闭已保存标签页", "Close Saved Tabs"),
        "menu.closeTabsToLeft" => ("关闭左侧标签页", "Close Tabs to the Left"),
        "menu.closeTabsToRight" => ("关闭右侧标签页", "Close Tabs to the Right"),
        "menu.reopenClosedTab" => ("重新打开已关闭标签页", "Reopen Closed Tab"),
        "menu.quit" => ("退出", "Quit"),
        // ---- Edit ----
        "menu.undo" => ("撤销", "Undo"),
        "menu.redo" => ("重做", "Redo"),
        "menu.cut" => ("剪切", "Cut"),
        "menu.copy" => ("复制", "Copy"),
        "menu.paste" => ("粘贴", "Paste"),
        "menu.selectAll" => ("全选", "Select All"),
        "menu.find" => ("查找", "Find"),
        "menu.findAndReplace" => ("查找并替换", "Find and Replace"),
        "menu.toggleComment" => ("切换注释", "Toggle Comment"),
        "menu.quickFix" => ("快速修复...", "Quick Fix"),
        "menu.triggerParameterHints" => ("触发参数提示", "Trigger Parameter Hints"),
        "menu.showHover" => ("显示悬停信息", "Show Hover"),
        "menu.duplicateLine" => ("复制行", "Duplicate Line"),
        "menu.deleteLine" => ("删除行", "Delete Line"),
        "menu.moveLineUp" => ("上移行", "Move Line Up"),
        "menu.moveLineDown" => ("下移行", "Move Line Down"),
        "menu.formatDocument" => ("格式化文档", "Format Document"),
        "menu.formatSelection" => ("格式化所选内容", "Format Selection"),
        "menu.commandPalette" => ("命令面板", "Command Palette"),
        // ---- View ----
        "menu.toggleActivitySidebar" => ("切换活动侧栏", "Toggle Activity Sidebar"),
        "menu.toggleSecondarySidebar" => ("切换辅助侧栏", "Toggle Secondary Sidebar"),
        "menu.toggleTerminal" => ("切换终端", "Toggle Terminal"),
        "menu.globalSearch" => ("全局搜索", "Global Search"),
        "menu.diagnostics" => ("诊断", "Diagnostics"),
        "menu.fileExplorer" => ("文件资源管理器", "File Explorer"),
        "menu.sourceControl" => ("源代码管理", "Source Control"),
        "menu.github" => ("GitHub", "GitHub"),
        "menu.runAndDebug" => ("运行和调试", "Run and Debug"),
        "menu.splitEditor" => ("拆分编辑器", "Split Editor"),
        "menu.toggleMinimap" => ("切换缩略图", "Toggle Minimap"),
        "menu.toggleWordWrap" => ("切换自动换行", "Toggle Word Wrap"),
        "menu.toggleLineNumbers" => ("切换行号", "Toggle Line Numbers"),
        "menu.toggleRenderWhitespace" => ("切换空白字符显示", "Toggle Render Whitespace"),
        "menu.zoomIn" => ("放大", "Zoom In"),
        "menu.zoomOut" => ("缩小", "Zoom Out"),
        "menu.resetZoom" => ("重置缩放", "Reset Zoom"),
        // ---- Go ----
        "menu.quickOpen" => ("快速打开", "Quick Open"),
        "menu.goToLine" => ("转到行", "Go to Line"),
        "menu.goBack" => ("后退", "Go Back"),
        "menu.goForward" => ("前进", "Go Forward"),
        "menu.goToDefinition" => ("转到定义", "Go to Definition"),
        "menu.goToImplementation" => ("转到实现", "Go to Implementation"),
        "menu.goToTypeDefinition" => ("转到类型定义", "Go to Type Definition"),
        "menu.goToReferences" => ("转到引用", "Go to References"),
        "menu.renameSymbol" => ("重命名符号", "Rename Symbol"),
        "menu.nextTab" => ("下一个标签页", "Next Tab"),
        "menu.previousTab" => ("上一个标签页", "Previous Tab"),
        // ---- Terminal ----
        "menu.newTerminal" => ("新建终端", "New Terminal"),
        "menu.splitTerminalRight" => ("向右拆分终端", "Split Terminal Right"),
        "menu.splitTerminalDown" => ("向下拆分终端", "Split Terminal Down"),
        "menu.closeTerminal" => ("关闭终端", "Close Terminal"),
        // ---- Run ----
        "menu.startDebugging" => ("开始调试", "Start Debugging"),
        "menu.stopDebugging" => ("停止调试", "Stop Debugging"),
        "menu.toggleBreakpoint" => ("切换断点", "Toggle Breakpoint"),
        // ---- Tools ----
        "menu.databases" => ("数据库", "Databases"),
        "menu.webInspector" => ("Web 检查器", "Web Inspector"),
        "menu.preferences" => ("首选项", "Preferences"),
        "menu.keyboardShortcuts" => ("键盘快捷键", "Keyboard Shortcuts"),
        // ---- Window ----
        "menu.minimize" => ("最小化", "Minimize"),
        "menu.maximize" => ("最大化", "Maximize"),
        "menu.toggleFullscreen" => ("切换全屏", "Toggle Fullscreen"),
        // ---- Help ----
        "menu.documentation" => ("文档", "Documentation"),
        "menu.whatsNew" => ("新增功能", "What's New"),
        "menu.changelog" => ("更新日志", "Changelog"),
        "menu.reportBug" => ("报告 Bug", "Report a Bug"),
        "menu.requestFeature" => ("请求新功能", "Request a Feature"),
        "menu.checkForUpdates" => ("检查更新", "Check for Updates"),
        // ---- 项目胶囊（titleProject.*） ----
        "titleProject.newProject" => ("新建项目…", "New Project…"),
        "titleProject.open" => ("打开…", "Open…"),
        "titleProject.cloneRepository" => ("克隆仓库…", "Clone Repository…"),
        "titleProject.openProjects" => ("打开的项目", "Open Projects"),
        "titleProject.recentProjects" => ("最近项目", "Recent Projects"),
        _ => return "",
    };
    if is_zh(cx) {
        zh
    } else {
        en
    }
}
