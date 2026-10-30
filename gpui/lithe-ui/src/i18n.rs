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
        "Spring" => "Spring",
        "Spring Endpoints" => "Spring Endpoints",
        "Tests" => "Tests",
        "Build Output" => "Build Output",
        "Notifications" => "Notifications",
        // 右侧活动栏：Database / Background 是占位入口，Updates 只说明当前
        // GPUI 构建没有更新流程。
        "Database" => "Database",
        "Services" => "Services",
        "Background" => "Background",
        "Updates are not available in this GPUI build." => {
            "Updates are not available in this GPUI build."
        }
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
        "Editor unavailable" => "Editor unavailable",
        "Not available yet" => "Not available yet",
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
        // 状态栏 Git 变更计数；数字与词条在调用处拼接。
        "changes" => "changes",
        "This action cannot be undone by Lithe." => "This action cannot be undone by Lithe.",
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

        _ => key,
    }
}
