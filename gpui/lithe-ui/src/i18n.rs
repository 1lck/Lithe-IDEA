//! GPUI 文案表。
//!
//! 英文是界面源码里的 key；中文表由 `gpui/scripts/generate-i18n-zh.py` 从
//! `shared/i18n/` 生成并补上 GPUI 专有词条。未知 key 原样返回。

use std::sync::atomic::{AtomicU8, Ordering};

/// 0 = English, 1 = 简体中文（默认对齐中文界面）。
static LANGUAGE: AtomicU8 = AtomicU8::new(1);

/// 设置页修改语言后调用；界面在下一帧重新取词。
pub fn set_language(language: &str) {
    let zh =
        language.eq_ignore_ascii_case("zh-CN") || language.to_ascii_lowercase().starts_with("zh");
    LANGUAGE.store(if zh { 1 } else { 0 }, Ordering::Relaxed);
}

/// 当前界面语言标识。
pub fn language() -> &'static str {
    if LANGUAGE.load(Ordering::Relaxed) == 1 {
        "zh-CN"
    } else {
        "en-US"
    }
}

pub fn tr(key: &'static str) -> &'static str {
    if LANGUAGE.load(Ordering::Relaxed) == 1 {
        if let Some(value) = crate::i18n_zh::zh_translate(key) {
            return value;
        }
    }
    en(key)
}

/// 英文原文也是所有调用点使用的 key。
fn en(key: &'static str) -> &'static str {
    match key {
        // 入口与工作台。
        "Welcome to Lithe" => "Welcome to Lithe",
        "Project" => "Project",
        "Open Project" => "Open Project",
        // 顶栏项目切换菜单的底部固定项；省略号表示会打开系统对话框。
        "Open Project…" => "Open Project…",
        "Recent Projects" => "Recent Projects",
        // 顶栏全局菜单触发器（汉堡）。
        "Menu" => "Menu",
        // 顶栏分支切换菜单。
        "Branches" => "Branches",
        "No branches" => "No branches",
        "Loading…" => "Loading…",
        "No file open" => "No file open",
        "Settings" => "Settings",
        "Search" => "Search",
        "Search Everywhere" => "Search Everywhere",
        // 设置页 General：外观、语言、项目、文件与隐藏路径。
        "Color Theme" => "Color Theme",
        "Appearance mode" => "Appearance mode",
        "Open projects in" => "Open projects in",
        "Save changed files automatically" => "Save changed files automatically",
        "Hidden paths" => "Hidden paths",
        "Directories" => "Directories",
        "File patterns" => "File patterns",
        "Apply" => "Apply",
        "System" => "System",
        "Ask every time" => "Ask every time",
        "This window" => "This window",
        "New window" => "New window",
        "Attach" => "Attach",
        // 设置页 Editor。
        "Font Ligatures" => "Font Ligatures",
        "Show usages and Git author" => "Show usages and Git author",
        "Tab width" => "Tab width",
        // 设置页 Git / Keyboard / Terminal / AI。
        "Git Integration" => "Git Integration",
        "Auto Refresh Git Status" => "Auto Refresh Git Status",
        "Confirm Before Discard" => "Confirm Before Discard",
        "Folder-Based Changes" => "Folder-Based Changes",
        "Show Untracked Files" => "Show Untracked Files",
        "Show Staged First" => "Show Staged First",
        "Open Diff On Click" => "Open Diff On Click",
        "Compact Git Status Badges" => "Compact Git Status Badges",
        "Collapse Empty Sections" => "Collapse Empty Sections",
        "Default Diff View" => "Default Diff View",
        "Enable Inline Blame" => "Enable Inline Blame",
        "Enable Git Gutter" => "Enable Git Gutter",
        "Prune stale remote-tracking references" => "Prune stale remote-tracking references",
        "Use Git configuration" => "Use Git configuration",
        "Do not fetch submodules" => "Do not fetch submodules",
        "Fetch on demand" => "Fetch on demand",
        "Fetch all submodules" => "Fetch all submodules",
        "Fetch all tags" => "Fetch all tags",
        "Do not fetch tags" => "Do not fetch tags",
        "Synchronize tags and delete local tags absent on remote" => {
            "Synchronize tags and delete local tags absent on remote"
        }
        "Keybinding Preset" => "Keybinding Preset",
        "Vim Mode" => "Vim Mode",
        "AI Autocomplete" => "AI Autocomplete",
        "Default shell" => "Default shell",
        "JDK" => "JDK",
        "Unified" => "Unified",
        "Split" => "Split",
        "Default" => "Default",
        "Vim" => "Vim",
        "Shell" => "Shell",

        // 活动栏与工具窗。
        "Changes" => "Changes",
        "Pull Requests" => "Pull Requests",
        "Git" => "Git",
        "Git Log" => "Git Log",
        "Local History" => "Local History",
        "Terminal" => "Terminal",
        "Agent" => "Agent",
        // Agent 底部面板的连接与输入动作。
        "Send" => "Send",
        "Stop" => "Stop",
        "Reconnect" => "Reconnect",
        "References" => "References",
        "Usages" => "Usages",
        "Problems" => "Problems",
        // Problems 视图左侧 View Options 菜单的严重级别过滤词条。
        "All severities" => "All severities",
        "Information" => "Information",
        "Hint" => "Hint",
        "Spring" => "Spring",
        "Spring Endpoints" => "Spring Endpoints",
        "Tests" => "Tests",
        "Build Output" => "Build Output",
        "Notifications" => "Notifications",
        // 右侧活动栏：Database / Background 是占位入口，Updates 走真实检查。
        "Database" => "Database",
        "Services" => "Services",
        "Background" => "Background",
        // 通知中心与状态栏内存项。
        "Mark all read" => "Mark all read",
        "Clear" => "Clear",
        "No notifications" => "No notifications",
        "RAM" => "RAM",

        // 动作。
        "Run" => "Run",
        "Debug" => "Debug",
        // Run 工具窗：标题、空状态与检测错误。命令本身来自项目配置，不翻译。
        "Run configuration" => "Run configuration",
        "No run configuration found" => "No run configuration found",
        "Could not read run configuration" => "Could not read run configuration",
        "Needs configuration" => "Needs configuration",
        "Refresh" => "Refresh",
        "Collapse" => "Collapse",
        "Close" => "Close",
        "Close Tab" => "Close Tab",
        "More" => "More",

        // 底部工具区（Git / Search）。
        "Commit" => "Commit",
        "Log" => "Log",
        "Search…" => "Search…",
        "No changes" => "No changes",
        "No results" => "No results",
        "No commits" => "No commits",
        "No Git command history" => "No Git command history",
        "Git commands report their result in the panel status line; this build keeps no execution journal, so no entries are listed here." => "Git commands report their result in the panel status line; this build keeps no execution journal, so no entries are listed here.",
        "Show file tree" => "Show file tree",
        "Show file list" => "Show file list",

        // 设置、主题与命令面板。
        "Appearance" => "Appearance",
        "Editor" => "Editor",
        "Preview" => "Preview",
        "About" => "About",
        "Theme" => "Theme",
        "Dark" => "Dark",
        "Light" => "Light",
        "Font size" => "Font size",
        "Wrap" => "Wrap",
        "Minimap" => "Minimap",
        "Command Palette" => "Command Palette",
        "Toggle Dark" => "Toggle Dark",
        "Toggle Wrap" => "Toggle Wrap",

        // 工作台与编辑器状态。
        "No Project" => "No Project",
        "No project open" => "No project open",
        "No recent projects" => "No recent projects",
        "Open a local folder to start working." => "Open a local folder to start working.",
        "Open a project first" => "Open a project first",
        "Project folder is not available" => "Project folder is not available",
        "File is outside the project" => "File is outside the project",
        "Cannot open this path" => "Cannot open this path",
        "Could not open file" => "Could not open file",
        // 外部文件修改：项目树/编辑器跟随磁盘变化。
        "Loaded file-system version" => "Loaded file-system version",
        "External edits conflict with unsaved changes" => {
            "External edits conflict with unsaved changes"
        }
        "This file changed outside Lithe while you had unsaved edits." => {
            "This file changed outside Lithe while you had unsaved edits."
        }
        "Save to overwrite the file, or use File > Revert to load the disk version." => {
            "Save to overwrite the file, or use File > Revert to load the disk version."
        }
        "File watching is unavailable for this project." => {
            "File watching is unavailable for this project."
        }
        "Could not reach the update server: {detail}" => {
            "Could not reach the update server: {detail}"
        }
        "Editor unavailable" => "Editor unavailable",
        "Not available yet" => "Not available yet",
        "Not checked yet" => "Not checked yet",
        "This tool window is not available in this GPUI build." => {
            "This tool window is not available in this GPUI build."
        }
        // 底部锚点占位工具窗的一句话说明；标题与 `Not available yet` 共用
        // 现有词条，不伪造数据。
        "References are not available in this GPUI build." => {
            "References are not available in this GPUI build."
        }
        "Problems are not available in this GPUI build." => {
            "Problems are not available in this GPUI build."
        }
        "Spring support is not available in this GPUI build." => {
            "Spring support is not available in this GPUI build."
        }
        "Tests are not available in this GPUI build." => {
            "Tests are not available in this GPUI build."
        }
        "The debugger is not available in this GPUI build." => {
            "The debugger is not available in this GPUI build."
        }
        "Build output is not available in this GPUI build." => {
            "Build output is not available in this GPUI build."
        }
        "Current File" => "Current File",
        "main" => "main",
        "Ln" => "Ln",
        "Col" => "Col",
        "Saved" => "Saved",
        "Save failed" => "Save failed",
        "Discard changes?" => "Discard changes?",
        // 未保存标签关闭确认：标题、正文提示和危险按钮。
        "Discard unsaved changes?" => "Discard unsaved changes?",
        "Discard" => "Discard",
        // 退出确认：有未保存标签时先询问再退出（对齐 Tauri
        // requestApplicationQuit 让每个窗口走 close guard 的语义）。
        "Quit Lithe?" => "Quit Lithe?",
        "{count} open files have unsaved changes." => "{count} open files have unsaved changes.",
        "Save All and Quit" => "Save All and Quit",
        "Discard and Quit" => "Discard and Quit",
        // 状态栏 Git 变更计数；数字与词条在调用处拼接。
        "changes" => "changes",
        "This action cannot be undone by Lithe." => "This action cannot be undone by Lithe.",
        // 项目树文件操作与右键菜单。
        "Move to Trash" => "Move to Trash",
        "File no longer exists" => "File no longer exists",
        "Copy Relative Path" => "Copy Relative Path",
        "Reveal in File Explorer" => "Reveal in File Explorer",
        "Cancel" => "Cancel",
        // 预览展示磁盘内容；有未保存修改时用它提示，避免把编辑器里的
        // 未保存文本误认为已经出现在预览里。
        "Preview shows saved content" => "Preview shows saved content",
        "UTF-8" => "UTF-8",
        "4 spaces" => "4 spaces",

        // 设置页导航（与 macOS 设置分类对齐）。
        "Appearance & Behavior" => "Appearance & Behavior",
        "General" => "General",
        "Updates" => "Updates",
        "Keymap" => "Keymap",
        "Process Termination" => "Process Termination",
        "Plugins" => "Plugins",
        "Version Control" => "Version Control",
        "Build, Execution, Deployment" => "Build, Execution, Deployment",
        "Project · JDK & Maven" => "Project · JDK & Maven",
        "Run Configurations" => "Run Configurations",
        "Languages & Frameworks" => "Languages & Frameworks",
        "LSP" => "LSP",
        "Tools" => "Tools",
        "Logs and Diagnostics" => "Logs and Diagnostics",
        "AI" => "AI",
        "AI Providers" => "AI Providers",
        "Agents" => "Agents",
        "Library" => "Library",
        "Instructions" => "Instructions",
        "Skills" => "Skills",
        "Hooks" => "Hooks",
        "MCP" => "MCP",
        "AI & Commit" => "AI & Commit",
        // 设置分组标题与说明。
        "Customize the workspace theme and dark mode." => {
            "Customize the workspace theme and dark mode."
        }
        "Configure the editor font size and display options." => {
            "Configure the editor font size and display options."
        }
        "Git settings will be available in a future update." => {
            "Git settings will be available in a future update."
        }
        "A lightweight, AI-native IDE." => "A lightweight, AI-native IDE.",
        "Version" => "Version",
        "Lithe" => "Lithe",
        // 外观与编辑器控件。
        "Dark mode" => "Dark mode",
        "Wrap lines" => "Wrap lines",
        "Show minimap" => "Show minimap",
        "Line numbers" => "Line numbers",
        "Scroll beyond last line" => "Scroll beyond last line",
        "On" => "On",
        "Off" => "Off",
        // 更新、进程终止与终端设置。
        "Update channel" => "Update channel",
        "Update available: {version}" => "Update available: {version}",
        "No published release is available yet." => "No published release is available yet.",
        "GitHub rejected the update request because a shared API limit was reached. Open the Release page or try again after the limit resets." => {
            "GitHub rejected the update request because a shared API limit was reached. Open the Release page or try again after the limit resets."
        }
        "Failed to check for updates: {detail}" => {
            "Failed to check for updates: {detail}"
        }
        "The update request timed out. Try again later." => {
            "The update request timed out. Try again later."
        }
        "The update server returned HTTP {status}." => {
            "The update server returned HTTP {status}."
        }
        "The update server returned an unexpected response." => {
            "The update server returned an unexpected response."
        }
        "Stable" => "Stable",
        "Auto check updates" => "Auto check updates",
        "Run services on exit" => "Run services on exit",
        "Terminal on quit" => "Terminal on quit",
        "Agent tasks" => "Agent tasks",
        "Background services" => "Background services",
        "Graceful stop (seconds)" => "Graceful stop (seconds)",
        "Ask" => "Ask",
        "Terminate" => "Terminate",
        "Keep" => "Keep",
        "Terminal font size" => "Terminal font size",
        "Scrollback" => "Scrollback",
        // AI 与提交。
        "AI commit" => "AI commit",
        "Enable AI commit" => "Enable AI commit",
        "Commit format" => "Commit format",
        "Conventional" => "Conventional",
        "Plain" => "Plain",
        "Gitmoji" => "Gitmoji",
        // 设置页展示的上下文与 Agent 状态。
        "Branch" => "Branch",
        "Memory" => "Memory",
        "Agent status" => "Agent status",
        "Connected" => "Connected",
        "Not connected" => "Not connected",
        "Connecting…" => "Connecting…",
        "Ready" => "Ready",
        "Error" => "Error",
        "No agent" => "No agent",
        "No agent installed" => "No agent installed",
        "No Agent installed" => "No Agent installed",
        "Open Run" => "Open Run",
        "Open Agent" => "Open Agent",

        // 设置页各分组的说明与只读状态文案。
        "Theme, dark mode, and interface language." => "Theme, dark mode, and interface language.",
        "Release channel, update checks, and the current build." => {
            "Release channel, update checks, and the current build."
        }
        "Font size and display options for the code editor." => {
            "Font size and display options for the code editor."
        }
        "Shortcuts registered by this GPUI build." => "Shortcuts registered by this GPUI build.",
        "What happens to programs started in Lithe when you quit." => {
            "What happens to programs started in Lithe when you quit."
        }
        "Plugin support is not available in this GPUI build." => {
            "Plugin support is not available in this GPUI build."
        }
        "Project and branch context for version control." => {
            "Project and branch context for version control."
        }
        "Project root, JDK, and Maven resolution." => "Project root, JDK, and Maven resolution.",
        "Run configurations detected from project files." => {
            "Run configurations detected from project files."
        }
        "Built-in language services and external LSP status." => {
            "Built-in language services and external LSP status."
        }
        "Terminal font size and scrollback." => "Terminal font size and scrollback.",
        "Memory, app data, and diagnostics availability." => {
            "Memory, app data, and diagnostics availability."
        }
        "AI provider configuration is owned by the Agent panel." => {
            "AI provider configuration is owned by the Agent panel."
        }
        "Agent status and management entry point." => "Agent status and management entry point.",
        "Project and global agent instructions." => "Project and global agent instructions.",
        "Skills available to the agent." => "Skills available to the agent.",
        "Agent lifecycle hooks." => "Agent lifecycle hooks.",
        "MCP servers used by the agent." => "MCP servers used by the agent.",
        "AI commit message generation." => "AI commit message generation.",
        // 设置页控件、只读说明与状态值。
        "UI language" => "UI language",
        "Language" => "Language",
        "Display" => "Display",
        "Current version" => "Current version",
        "Application version" => "Application version",
        "Auto check" => "Auto check",
        "Auto check for updates" => "Auto check for updates",
        "Automatic updates are not available in this build yet. The channel and auto-check choices are saved for a future update service." => {
            "Automatic updates are not available in this build yet. The channel and auto-check choices are saved for a future update service."
        }
        "Interface language switching is not wired up in this build; the UI stays in English." => {
            "Interface language switching is not wired up in this build; the UI stays in English."
        }
        "English" => "English",
        "Show line numbers" => "Show line numbers",
        "Current shortcuts" => "Current shortcuts",
        "Shortcut customization is not wired up in this build. These are the shortcuts registered by the GPUI workbench." => {
            "Shortcut customization is not wired up in this build. These are the shortcuts registered by the GPUI workbench."
        }
        "Save" => "Save",
        "Run services" => "Run services",
        "Terminals" => "Terminals",
        "Graceful stop seconds" => "Graceful stop seconds",
        "When quitting Lithe" => "When quitting Lithe",
        "These choices are stored now; they are enforced once long-lived run services, terminals, agent tasks, and background services land in the GPUI build." => {
            "These choices are stored now; they are enforced once long-lived run services, terminals, agent tasks, and background services land in the GPUI build."
        }
        "Plugin system is not available in the GPUI build yet." => {
            "Plugin system is not available in the GPUI build yet."
        }
        "Repository" => "Repository",
        "Project root" => "Project root",
        "Git configuration is read from the repository by Core (source-backed). This GPUI build only displays the current project context and does not edit Git settings." => {
            "Git configuration is read from the repository by Core (source-backed). This GPUI build only displays the current project context and does not edit Git settings."
        }
        "Not available" => "Not available",
        "Not reported" => "Not reported",
        "Run configurations are detected from project files. The Run panel shows what Lithe found for the open project." => {
            "Run configurations are detected from project files. The Run panel shows what Lithe found for the open project."
        }
        "Editing run configurations in this page is not wired up in the GPUI build; the Run panel is the source of truth." => {
            "Editing run configurations in this page is not wired up in the GPUI build; the Run panel is the source of truth."
        }
        "Open Run panel" => "Open Run panel",
        "Detected configurations" => "Detected configurations",
        "Built in" => "Built in",
        "Language services" => "Language services",
        "These lightweight language services are built into Lithe. Full LSP servers are not wired into the GPUI build yet." => {
            "These lightweight language services are built into Lithe. Full LSP servers are not wired into the GPUI build yet."
        }
        "New terminals use the system default shell. Shell selection is not wired up in this build." => {
            "New terminals use the system default shell. Shell selection is not wired up in this build."
        }
        "JDK and Maven are resolved by Lithe per project; this build does not store a separate JDK or Maven path." => {
            "JDK and Maven are resolved by Lithe per project; this build does not store a separate JDK or Maven path."
        }
        "Log viewing, log directory selection, and diagnostics export are not available in the GPUI build yet." => {
            "Log viewing, log directory selection, and diagnostics export are not available in the GPUI build yet."
        }
        "App data" => "App data",
        "AI providers are managed from the Agent panel. This page does not edit provider settings or API keys." => {
            "AI providers are managed from the Agent panel. This page does not edit provider settings or API keys."
        }
        "No agent is connected." => "No agent is connected.",
        "Agent instructions are edited from the Agent panel. This page does not edit project or global instruction files." => {
            "Agent instructions are edited from the Agent panel. This page does not edit project or global instruction files."
        }
        "Skills are discovered and managed by the Agent panel. This page does not install or edit skills." => {
            "Skills are discovered and managed by the Agent panel. This page does not install or edit skills."
        }
        "Agent lifecycle hooks are managed by the Agent panel. This page does not edit hook files." => {
            "Agent lifecycle hooks are managed by the Agent panel. This page does not edit hook files."
        }
        "MCP servers are configured from the Agent panel. This page does not edit MCP configuration." => {
            "MCP servers are configured from the Agent panel. This page does not edit MCP configuration."
        }
        "This page is read-only." => "This page is read-only.",
        "Commit messages" => "Commit messages",
        "AI commit messages" => "AI commit messages",
        "Format" => "Format",
        "Enable AI commit messages" => "Enable AI commit messages",
        "GitMoji" => "GitMoji",
        "The AI commit settings and format are stored here; message generation itself runs from the Agent panel." => {
            "The AI commit settings and format are stored here; message generation itself runs from the Agent panel."
        }
        "Providers" => "Providers",
        "Runtime" => "Runtime",
        "Status" => "Status",
        "Codex" => "Codex",
        "Linear" => "Linear",
        "Ask before stopping" => "Ask before stopping",
        "Stop without asking" => "Stop without asking",
        "Ask for each terminal" => "Ask for each terminal",
        "Ask for each task" => "Ask for each task",
        "Keep running" => "Keep running",
        "Ask in one list" => "Ask in one list",
        "End without asking" => "End without asking",
        "End all" => "End all",
        "Java" => "Java",
        "Markdown" => "Markdown",
        "XML" => "XML",
        "CSS" => "CSS",
        "HTML" => "HTML",

        // Run 工具窗。
        "All configurations" => "All configurations",
        "Applications" => "Applications",
        "Build tool goal" => "Build tool goal",
        "Category" => "Category",
        "Clear run output" => "Clear run output",
        "Configuration ID" => "Configuration ID",
        "Configuration details" => "Configuration details",
        "Console" => "Console",
        "Copy output" => "Copy output",
        "Could not find executable" => "Could not find executable",
        "Could not save run configuration" => "Could not save run configuration",
        "Could not scan the project" => "Could not scan the project",
        "Could not start configuration" => "Could not start configuration",
        "Could not stop run" => "Could not stop run",
        // 「进程输出」后面的运行方式标签。
        "Direct JVM" => "Direct JVM",
        "Docker Compose" => "Docker Compose",
        "Environment" => "Environment",
        "Go" => "Go",
        "Go language" => "Go",
        "Gradle" => "Gradle",
        "Groups" => "Groups",
        "Jump to latest" => "Jump to latest",
        "Just" => "Just",
        "Main class" => "Main class",
        "Make" => "Make",
        "Maven" => "Maven",
        "Maven goal" => "Maven goal",
        "Micronaut" => "Micronaut",
        "Module" => "Module",
        "No Java runtime was found. Set JAVA_HOME or install a JDK." => {
            "No Java runtime was found. Set JAVA_HOME or install a JDK."
        }
        "No configurations in this scope" => "No configurations in this scope",
        "Node.js" => "Node.js",
        "Open a project to discover run configurations" => {
            "Open a project to discover run configurations"
        }
        "Open service in browser" => "Open service in browser",
        "Pin configuration" => "Pin configuration",
        "Pinned" => "Pinned",
        "Procfile" => "Procfile",
        "Program arguments" => "Program arguments",
        "Provider" => "Provider",
        "Python" => "Python",
        "Quarkus" => "Quarkus",
        "Rescan services" => "Rescan services",
        "Restart" => "Restart",
        "Run a configuration to see process output." => "Run a configuration to see process output.",
        "Rust" => "Rust",
        "Select a run configuration to see its details." => {
            "Select a run configuration to see its details."
        }
        "Soft wrap" => "Soft wrap",
        "Source" => "Source",
        "Spring Boot" => "Spring Boot",
        "Stop run" => "Stop run",
        "Tasks" => "Tasks",
        "Type" => "Type",
        "Unpin configuration" => "Unpin configuration",
        "Working directory" => "Working directory",
        // Run 工具窗的启动准备阶段文案。
        "Application launched" => "Application launched",
        "Compiling and resolving dependencies (Maven)" => {
            "Compiling and resolving dependencies (Maven)"
        }
        "Dependencies are compiled and resolved with Maven before the application starts." => {
            "Dependencies are compiled and resolved with Maven before the application starts."
        }
        "Launch preparation failed" => "Launch preparation failed",
        "Launch preparation failed — view details" => {
            "Launch preparation failed — view details"
        }
        "Launch preparation stopped" => "Launch preparation stopped",
        "Launching application" => "Launching application",
        "Preparing launch" => "Preparing launch",
        "Preparing launch steps" => "Preparing launch steps",


        // --- settings (agent A) ---
        // 设置弹窗（阶段 0）新增词条；key = 英文原文，译文由 generate-i18n-zh.py 从 shared/i18n 与 MANUAL 合成。
        "+" => "+",
        "-" => "-",
        "A non-empty command without NUL is required." => "A non-empty command without NUL is required.",
        "API key" => "API key",
        "API key found in that configuration" => "API key found in that configuration",
        "API key is empty." => "API key is empty.",
        "API key removed." => "API key removed.",
        "API key stored" => "API key stored",
        "API key stored." => "API key stored.",
        "Add" => "Add",
        "All modules" => "All modules",
        "Allow insecure HTTP" => "Allow insecure HTTP",
        "Auto-detect (leave empty)" => "Auto-detect (leave empty)",
        "Automatic" => "Automatic",
        "Browse" => "Browse",
        "Catalog entry unavailable" => "Catalog entry unavailable",
        "Channel choices take effect once automatic updates are wired up; Auto Build is confirmed before it is saved." => "Channel choices take effect once automatic updates are wired up; Auto Build is confirmed before it is saved.",
        "Check for updates" => "Check for updates",
        "Checking for updates…" => "Checking for updates…",
        "Choose Where to Save the Diagnostic Bundle" => "Choose Where to Save the Diagnostic Bundle",
        "Choose node.exe, or leave empty to use the detected Node.js runtime." => "Choose node.exe, or leave empty to use the detected Node.js runtime.",
        "Choose the parent directory for Lithe logs" => "Choose the parent directory for Lithe logs",
        "Choose…" => "Choose…",
        "Clear Logs" => "Clear Logs",
        "Clear key" => "Clear key",
        "Command" => "Command",
        "Configuration" => "Configuration",
        "Configuration entries" => "Configuration entries",
        "Configuration file is too large." => "Configuration file is too large.",
        "Configuration overrides" => "Configuration overrides",
        "Configuration scope" => "Configuration scope",
        "Configure project JDK and Maven…" => "Configure project JDK and Maven…",
        "Copy Path" => "Copy Path",
        "Copy configuration" => "Copy configuration",
        "Could not determine the user home directory." => "Could not determine the user home directory.",
        "Could not read the configuration file." => "Could not read the configuration file.",
        "Current path" => "Current path",
        "Custom commit instructions" => "Custom commit instructions",
        "Custom instructions" => "Custom instructions",
        "Declared in this file" => "Declared in this file",
        "Default (built-in monospace)" => "Default (built-in monospace)",
        "Delete Logs" => "Delete Logs",
        "Deleted" => "Deleted",
        "Deleted log files:" => "Deleted log files:",
        "Description" => "Description",
        "Detailed diagnostics: Off" => "Detailed diagnostics: Off",
        "Detailed diagnostics: On" => "Detailed diagnostics: On",
        "Detect again" => "Detect again",
        "Detected" => "Detected",
        "Detecting Codex / Claude configurations…" => "Detecting Codex / Claude configurations…",
        "Detecting installed shells…" => "Detecting installed shells…",
        "Diagnostic bundle saved to" => "Diagnostic bundle saved to",
        "Diff limit" => "Diff limit",
        "Disable" => "Disable",
        "Disabled" => "Disabled",
        "Dropped:" => "Dropped:",
        "Earlier evidence was omitted by collection limits." => "Earlier evidence was omitted by collection limits.",
        "Edit" => "Edit",
        "Edit hook" => "Edit hook",
        "Edit in Run Configurations" => "Edit in Run Configurations",
        "Effective fetch options" => "Effective fetch options",
        "Effective source" => "Effective source",
        "Enable" => "Enable",
        "Endpoint (https://api.example.com/v1)" => "Endpoint (https://api.example.com/v1)",
        "Enter a Maven local repository path." => "Enter a Maven local repository path.",
        "Example" => "Example",
        "Export" => "Export",
        "Export Diagnostic Bundle?" => "Export Diagnostic Bundle?",
        "Fetch submodules" => "Fetch submodules",
        "Fetch tags" => "Fetch tags",
        "File" => "File",
        "Filter log messages" => "Filter log messages",
        "From (UTC ISO 8601)" => "From (UTC ISO 8601)",
        "Generated {count} runnable project entries." => "Generated {count} runnable project entries.",
        "Git configuration saved." => "Git configuration saved.",
        "Git executable not found" => "Git executable not found",
        "Git identity cleared." => "Git identity cleared.",
        "Git identity saved." => "Git identity saved.",
        "Hide advanced settings" => "Hide advanced settings",
        "Hook name (letters, numbers, _ or -)" => "Hook name (letters, numbers, _ or -)",
        "Hooks saved." => "Hooks saved.",
        "Identify Again" => "Identify Again",
        "Import" => "Import",
        "Imported from Claude; fields are managed by that configuration." => "Imported from Claude; fields are managed by that configuration.",
        "Imported from Codex; fields are managed by that configuration." => "Imported from Codex; fields are managed by that configuration.",
        "In effect" => "In effect",
        "Include commit body" => "Include commit body",
        "Inspecting installed agents…" => "Inspecting installed agents…",
        "Installed" => "Installed",
        "Installed version" => "Installed version",
        "JDK Home" => "JDK Home",
        "JVM arguments" => "JVM arguments",
        "KEY=VALUE" => "KEY=VALUE",
        "Keep Logs" => "Keep Logs",
        "Leave empty to inherit the agent timeout." => "Leave empty to inherit the agent timeout.",
        "Leave empty to use the project default." => "Leave empty to use the project default.",
        "Leave empty to use the project root." => "Leave empty to use the project root.",
        "Log path copied." => "Log path copied.",
        "MCP configuration" => "MCP configuration",
        "Maven executable" => "Maven executable",
        "Maven local repository" => "Maven local repository",
        "Maven tests" => "Maven tests",
        "Model" => "Model",
        "Name must use letters, numbers, _ or - (max 80)." => "Name must use letters, numbers, _ or - (max 80).",
        "Needs sync" => "Needs sync",
        "New hook" => "New hook",
        "No Codex or Claude configuration detected." => "No Codex or Claude configuration detected.",
        "No agent selected" => "No agent selected",
        "No key found in that configuration" => "No key found in that configuration",
        "No local repository declared; Maven uses its default location." => "No local repository declared; Maven uses its default location.",
        "No matching logs" => "No matching logs",
        "No profile yet" => "No profile yet",
        "No readable Git configuration entries." => "No readable Git configuration entries.",
        "No servers parsed yet. “Validate configuration” normalizes the source file." => "No servers parsed yet. “Validate configuration” normalizes the source file.",
        "No settings found" => "No settings found",
        "No shells were detected on this machine." => "No shells were detected on this machine.",
        "No shortcut matches this search." => "No shortcut matches this search.",
        "Node.js executable" => "Node.js executable",
        "None" => "None",
        "Not configured" => "Not configured",
        "Not configured in this scope" => "Not configured in this scope",
        "Not detected" => "Not detected",
        "Not found" => "Not found",
        "Not installed" => "Not installed",
        "One pattern per line" => "One pattern per line",
        "Only “All tools” is available for this event." => "Only “All tools” is available for this event.",
        "Open Current Log" => "Open Current Log",
        "Open Directory" => "Open Directory",
        "Open a project to configure its JDK and Maven." => "Open a project to configure its JDK and Maven.",
        "Open a project to edit the Git identity." => "Open a project to edit the Git identity.",
        "Open a project to inspect the Git executable and repository configuration." => "Open a project to inspect the Git executable and repository configuration.",
        "Open download page" => "Open download page",
        "Preview and Export…" => "Preview and Export…",
        "Profile name" => "Profile name",
        "Project defaults" => "Project defaults",
        "Project path is not valid UTF-8" => "Project path is not valid UTF-8",
        "Refresh logs" => "Refresh logs",
        "Reload" => "Reload",
        "Reload file" => "Reload file",
        "Removal pending" => "Removal pending",
        "Remove" => "Remove",
        "Repository preferences" => "Repository preferences",
        "Requires API key" => "Requires API key",
        "Rescan installed shells" => "Rescan installed shells",
        "Reset" => "Reset",
        "Reset Settings" => "Reset Settings",
        "Restore Default" => "Restore Default",
        "Restore Defaults" => "Restore Defaults",
        "Run configurations may be out of date" => "Run configurations may be out of date",
        "Run tests" => "Run tests",
        "Runs on" => "Runs on",
        "Save hook" => "Save hook",
        "Save key" => "Save key",
        "Save scope" => "Save scope",
        "Saved. Reload projects to pick up the new repository location." => "Saved. Reload projects to pick up the new repository location.",
        "Search settings" => "Search settings",
        "Search shortcuts" => "Search shortcuts",
        "Seconds (1–86400)" => "Seconds (1–86400)",
        "Select" => "Select",
        "Select a profile" => "Select a profile",
        "Select one or two agents." => "Select one or two agents.",
        "Show advanced settings" => "Show advanced settings",
        "Skip tests" => "Skip tests",
        "Subject limit" => "Subject limit",
        "Switch to Auto Build" => "Switch to Auto Build",
        "Switch to Auto Build channel?" => "Switch to Auto Build channel?",
        "System default" => "System default",
        "Temporary Git configuration" => "Temporary Git configuration",
        "That configuration could not be parsed." => "That configuration could not be parsed.",
        "The configuration file is empty or missing." => "The configuration file is empty or missing.",
        "The configuration text is empty." => "The configuration text is empty.",
        "The directory receiving logs in this session." => "The directory receiving logs in this session.",
        "The file is not a valid Maven settings.xml." => "The file is not a valid Maven settings.xml.",
        "The hook library is not loaded yet." => "The hook library is not loaded yet.",
        "The log directory changed immediately." => "The log directory changed immediately.",
        "The previous directory" => "The previous directory",
        "The previous log directory is already empty." => "The previous log directory is already empty.",
        "This computer" => "This computer",
        "Timeout must be 1–86400 seconds or empty." => "Timeout must be 1–86400 seconds or empty.",
        "Unable to export the diagnostic bundle:" => "Unable to export the diagnostic bundle:",
        "Unable to open the current log." => "Unable to open the current log.",
        "Unable to open the log directory." => "Unable to open the log directory.",
        "Unknown" => "Unknown",
        "Unnamed profile" => "Unnamed profile",
        "Unsaved changes" => "Unsaved changes",
        "Until (UTC ISO 8601)" => "Until (UTC ISO 8601)",
        "Up to date" => "Up to date",
        "Use project default" => "Use project default",
        "Use the selected channel’s release page to download and install. Build freshness has not been checked." => {
            "Use the selected channel’s release page to download and install. Build freshness has not been checked."
        }
        "Using the default location" => "Using the default location",
        "Validate configuration" => "Validate configuration",
        "Working…" => "Working…",
        "hooks" => "hooks",
        "log files, freed" => "log files, freed",
        "still contains about" => "still contains about",
        "target" => "target",
        "write failures:" => "write failures:",
        // 设置页通过常量表/变量传入的标签（en() 是这些 key 的声明处；
        // 生成脚本据此产出中文）。
        "After tool" => "After tool",
        "Agent connection" => "Agent connection",
        "Agent runtime" => "Agent runtime",
        "AI Commit" => "AI Commit",
        "All sessions" => "All sessions",
        "All tools" => "All tools",
        "Anthropic Messages" => "Anthropic Messages",
        "Application" => "Application",
        "Auto Build" => "Auto Build",
        "Auto completion" => "Auto completion",
        "Autocomplete" => "Autocomplete",
        "Automatically" => "Automatically",
        "Bearer" => "Bearer",
        "Before tool" => "Before tool",
        "Build, run and debug" => "Build, run and debug",
        "Chat Completions" => "Chat Completions",
        "Clear logs in the current directory" => "Clear logs in the current directory",
        "Commit rules" => "Commit rules",
        "Credential helper" => "Credential helper",
        "Current log location" => "Current log location",
        "Current session" => "Current session",
        "Custom log location" => "Custom log location",
        "Declarative Plugins" => "Declarative Plugins",
        "Default location" => "Default location",
        "Default log location" => "Default log location",
        "Detailed diagnostics" => "Detailed diagnostics",
        "Detected language servers" => "Detected language servers",
        "Diagnostic bundle" => "Diagnostic bundle",
        "Editor and language services" => "Editor and language services",
        "Editor tabs layout" => "Editor tabs layout",
        "Event" => "Event",
        "Export Diagnostic Bundle…" => "Export Diagnostic Bundle…",
        "Fetch defaults" => "Fetch defaults",
        "File edits" => "File edits",
        "Files" => "Files",
        "Font family" => "Font family",
        "Git executable" => "Git executable",
        "Git execution" => "Git execution",
        "Git identity" => "Git identity",
        "Git integration" => "Git integration",
        "Git Panel" => "Git Panel",
        "Git strategy" => "Git strategy",
        "Git version" => "Git version",
        "Host" => "Host",
        "Import Java projects on open" => "Import Java projects on open",
        "Inline" => "Inline",
        "Install, update and uninstall run from the Agent panel with its progress and preflight checks." => {
            "Install, update and uninstall run from the Agent panel with its progress and preflight checks."
        }
        "Installed agent runtimes are the providers available to this build." => {
            "Installed agent runtimes are the providers available to this build."
        }
        "Installed agents" => "Installed agents",
        "Log locations" => "Log locations",
        "Log timeline" => "Log timeline",
        "Manually" => "Manually",
        "Matcher" => "Matcher",
        "MCP servers are a user-level Codex / Claude configuration; sessions run through the Agent panel." => {
            "MCP servers are a user-level Codex / Claude configuration; sessions run through the Agent panel."
        }
        "Minimum level" => "Minimum level",
        "Multiple rows" => "Multiple rows",
        "Node runtime" => "Node runtime",
        "Open Settings…" => "Open Settings…",
        "Parameter hints" => "Parameter hints",
        "Performance" => "Performance",
        "Previous session" => "Previous session",
        "Projects" => "Projects",
        "Prompt submitted" => "Prompt submitted",
        "Render Whitespace" => "Render Whitespace",
        "Responses API" => "Responses API",
        "Retention and cleanup" => "Retention and cleanup",
        "Revision" => "Revision",
        "Rules define how generated messages look; generation runs from the Git panel AI button." => {
            "Rules define how generated messages look; generation runs from the Git panel AI button."
        }
        "Runtimes" => "Runtimes",
        "Scope" => "Scope",
        "Search Files…" => "Search Files…",
        "Semantic highlighting" => "Semantic highlighting",
        "Session" => "Session",
        "Session start" => "Session start",
        "Shell commands" => "Shell commands",
        "Shelve changes" => "Shelve changes",
        "Show Changelists" => "Show Changelists",
        "Single line" => "Single line",
        "Stop Build" => "Stop Build",
        "Storage" => "Storage",
        "The source changed since it was loaded. Reload and try again." => {
            "The source changed since it was loaded. Reload and try again."
        }
        "These shortcuts are registered by the GPUI workbench menus." => {
            "These shortcuts are registered by the GPUI workbench menus."
        }
        "This page matches Tauri's declarative-plugins section; management lands when the plugin host bridge arrives." => {
            "This page matches Tauri's declarative-plugins section; management lands when the plugin host bridge arrives."
        }
        "This repository" => "This repository",
        "Toggle Commit Panel" => "Toggle Commit Panel",
        "Toggle Sidebar" => "Toggle Sidebar",
        "Toolchain defaults" => "Toolchain defaults",
        "Turn end" => "Turn end",
        "User email" => "User email",
        "User name" => "User name",
        "User settings.xml" => "User settings.xml",
        "Zip Archives" => "Zip Archives",
        "max_tokens (legacy gateways)" => "max_tokens (legacy gateways)",

        // --- git (agent B) ---
        // 提交面板（阶段 1）新增词条；key = 英文原文，中文译文由
        // generate-i18n-zh.py 从 shared/i18n 与 MANUAL 合成，不手改 i18n_zh.rs。
        "Abort session" => "Abort session",
        "Add worktree" => "Add worktree",
        "Annotated message" => "Annotated message",
        "Auto stash local changes" => "Auto stash local changes",
        "Base:" => "Base:",
        "Branch: {branch}" => "Branch: {branch}",
        "Branch…" => "Branch…",
        "Choose the source for the diff view." => "Choose the source for the diff view.",
        "Copy patch" => "Copy patch",
        "Delete failed" => "Delete failed",
        "Delete file?" => "Delete file?",
        "Deleted files" => "Deleted files",
        "Discard all changes?" => "Discard all changes?",
        "Discarded {count} files" => "Discarded {count} files",
        "Force push" => "Force push",
        "Load from clipboard" => "Load from clipboard",
        "Lock" => "Lock",
        "Locked ({reason})" => "Locked ({reason})",
        "Name and URL are required" => "Name and URL are required",
        "No files" => "No files",
        "No local branches" => "No local branches",
        "Paste a patch below (or load it from the file input), preview it, then apply." => {
            "Paste a patch below (or load it from the file input), preview it, then apply."
        }
        "Paste patch here" => "Paste patch here",
        "Patch exported ({bytes} bytes)" => "Patch exported ({bytes} bytes)",
        "Patch is applicable." => "Patch is applicable.",
        "Patch is empty" => "Patch is empty",
        "Patch is not applicable" => "Patch is not applicable",
        "Push all tags" => "Push all tags",
        "Push no tags" => "Push no tags",
        "Push reachable tags" => "Push reachable tags",
        "Rebase is not available for the current history." => {
            "Rebase is not available for the current history."
        }
        "Rename remote" => "Rename remote",
        "Rename to…" => "Rename to…",
        "Staged Diff" => "Staged Diff",
        "Staged {count} files" => "Staged {count} files",
        "Stage" => "Stage",
        "Unstage" => "Unstage",
        "Stage failed" => "Stage failed",
        "Unstage failed" => "Unstage failed",
        "Start rebase" => "Start rebase",
        "Stash…" => "Stash…",
        "Unlock" => "Unlock",
        "Unstaged {count} files" => "Unstaged {count} files",
        "Update URL" => "Update URL",
        "Working Tree Diff" => "Working Tree Diff",
        "bare" => "bare",
        "detached" => "detached",
        // Pull 预检回显。
        "Upstream: {upstream}" => "Upstream: {upstream}",
        "No upstream is configured for this branch." => {
            "No upstream is configured for this branch."
        }
        "Behind {behind}, ahead {ahead}" => "Behind {behind}, ahead {ahead}",
        "The branches have diverged; fast-forward is not possible." => {
            "The branches have diverged; fast-forward is not possible."
        }
        "Local changes are not committed." => "Local changes are not committed.",
        "Checking the upstream branch…" => "Checking the upstream branch…",
        "Pull state is unavailable." => "Pull state is unavailable.",
        // Checkout 预检确认。
        "Switching to {branch} would overwrite local changes." => {
            "Switching to {branch} would overwrite local changes."
        }
        "and {count} more files" => "and {count} more files",
        "Checkout anyway" => "Checkout anyway",
        // Saved Changes（本地 shelf）。
        "Saved changes name" => "Saved changes name",
        "Changes saved" => "Changes saved",
        "Saved changes name is empty" => "Saved changes name is empty",
        "Saved changes are no longer available" => "Saved changes are no longer available",
        "Saved changes are not applicable" => "Saved changes are not applicable",
        "Changes restored" => "Changes restored",
        "Saved changes deleted" => "Saved changes deleted",
        "Saved Changes" => "Saved Changes",
        "Exports the current working tree as a local patch that can be restored later." => {
            "Exports the current working tree as a local patch that can be restored later."
        }

        // --- menus (agent C) ---
        // 菜单线（阶段 2）新增词条；key = 英文原文，中文译文由
        // generate-i18n-zh.py 从 shared/i18n 与 MANUAL 合成，不手改 i18n_zh.rs。
        "Maven Output" => "Maven Output",

        _ => key,
    }
}
