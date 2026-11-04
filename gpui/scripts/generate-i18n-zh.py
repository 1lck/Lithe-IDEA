#!/usr/bin/env python3
"""Generate the GPUI Chinese translation table.

Key sources:

1. `tr("…")` 调用的字面量参数，以及 `item(…)` / `item_state(…)` 的标题参数。
   这里用括号配平扫描而不是单行正则，因此跨行的 `tr(\n "…",\n)` 也能收集到。
2. `lithe-ui/src/i18n.rs` 里 `en()` 声明、并且仍被其它 GPUI 源文件引用的 key。
   设置页标题、说明、行标签和选项名是以变量传给 `tr()` 的，字面量扫描看不到它们，
   `en()` 是这些 key 的声明处；已经没有任何调用点的历史 key 不再生成。

Translations for English strings that already exist in shared/i18n come from
the shared locale files. GPUI-only strings are listed in MANUAL below; every
key without a shared translation must appear there, otherwise generation fails.
"""
import glob
import json
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GPUI = os.path.join(ROOT, "gpui")
OUT = os.path.join(GPUI, "lithe-ui", "src", "i18n_zh.rs")
I18N = os.path.join(GPUI, "lithe-ui", "src", "i18n.rs")

# GPUI 专有文案：English -> 中文。键必须与“shared 里没有对应英文”的 key 完全一致，
# 多一个或少一个都会让生成失败，避免新增文案悄悄退回英文。
MANUAL = {
    "(No subject)": "（无主题）",
    "A file with this name already exists": "同名文件已存在",
    "Ask the agent…": "询问 Agent…",
    "Checking out": "正在切换",
    # 提交面板（阶段 1，agent B）的 gpui 专有词条；shared 的 git.* 覆盖其余。
    "Abort session": "中止会话",
    "Add worktree": "新建工作树",
    "Annotated message": "注解消息",
    "Auto stash local changes": "自动 stash 本地改动",
    "Base:": "基点：",
    "Branch: {branch}": "分支：{branch}",
    "Branch…": "分支…",
    "Choose the source for the diff view.": "选择差异视图的来源。",
    "Copy patch": "复制补丁",
    "Delete file?": "删除文件？",
    "Deleted files": "已删除文件",
    "Discard all changes?": "丢弃全部改动？",
    "Discarded {count} files": "已丢弃 {count} 个文件",
    "Force push": "强制推送",
    "Load from clipboard": "从剪贴板载入",
    "Lock": "锁定",
    "Locked ({reason})": "已锁定（{reason}）",
    "Name and URL are required": "需要填写名称和 URL",
    "No files": "没有文件",
    "No local branches": "没有本地分支",
    "Paste a patch below (or load it from the file input), preview it, then apply.": "在下方粘贴补丁（或用剪贴板载入），先检查再应用。",
    "Paste patch here": "在此粘贴补丁",
    "Patch exported ({bytes} bytes)": "补丁已导出（{bytes} 字节）",
    "Patch is applicable.": "补丁可应用。",
    "Patch is empty": "补丁为空",
    "Patch is not applicable": "补丁不可应用",
    "Push all tags": "推送全部标签",
    "Push no tags": "不推送标签",
    "Push reachable tags": "推送可达标签",
    "Rebase is not available for the current history.": "当前历史无法变基。",
    "Rename remote": "重命名远端",
    "Rename to…": "重命名为…",
    "Staged Diff": "已暂存差异",
    "Staged {count} files": "已暂存 {count} 个文件",
    "Start rebase": "开始变基",
    "Stash…": "Stash…",
    "Unlock": "解锁",
    "Unstaged {count} files": "已取消暂存 {count} 个文件",
    "Update URL": "更新 URL",
    "Working Tree Diff": "工作区差异",
    "bare": "裸仓库",
    "detached": "分离 HEAD",
    # Git Log 提交 diff 的空态（并行开发补录，保持生成器可运行）。
    "No textual changes": "无文本变更",
    # Git Log：引用过滤下拉、Log/Console 分段与提交文件树/列表切换。
    "No Git repository": "没有 Git 仓库",
    "Initialize a repository to browse its history.": "初始化仓库以浏览其历史。",
    "Scroll to load more commits": "滚动以加载更多提交",
    "No commits": "没有提交",
    "No Git command history": "暂无 Git 命令记录",
    "Commit diff is not available": "提交差异不可用",
    "Git commands report their result in the panel status line; this build keeps no execution journal, so no entries are listed here.": "Git 命令的执行结果会显示在面板状态行；当前构建没有执行流水记录，因此这里没有条目。",
    "Show file list": "以列表显示",
    "Show file tree": "以树状显示",
    "Filter files…": "筛选文件…",
    "Git actions": "Git 操作",
    "Read-Only Split": "只读分屏",
    "Save Failed": "保存失败",
    "Saved As": "已另存为",
    "Search Files": "在文件中搜索",
    "last commit": "上次提交",
    "Authenticate": "登录",
    "Changes unavailable": "变更不可用",
    "Col": "列",
    "Commit created": "提交已创建",
    "Commit failed": "提交失败",
    "Could not open file": "无法打开文件",
    "Could not read run configuration": "无法读取运行配置",
    "Detected": "检测到",
    "Discard changes?": "丢弃更改？",
    "Discard failed": "丢弃失败",
    "Discard unsaved changes?": "丢弃未保存的更改？",
    "Discarded": "已丢弃",
    "Enter sends · Shift+Enter for a new line": "Enter 发送 · Shift+Enter 换行",
    "File is outside the project": "文件不在项目内",
    "File no longer exists": "文件已不存在",
    "File operation failed": "文件操作失败",
    "File watching is unavailable for this project.": "此项目无法监视文件变化。",
    "Save to overwrite the file, or use File > Revert to load the disk version.": "保存将覆盖该文件，使用「文件 > 还原文件」可加载磁盘版本。",
    "Install an ACP adapter to start a conversation:": "安装 ACP 适配器后即可开始对话：",
    "Invalid name": "名称无效",
    "In effect": "当前生效",
    "Information": "信息",
    "Hint": "提示",
    "JDK": "JDK",
    "KEY=VALUE": "KEY=VALUE",
    "Ln": "行",
    "Loading changes…": "正在加载变更…",
    "Extensions are not available in this GPUI build.": "此 GPUI 构建未提供扩展页。",
    "No Agent installed": "未安装 Agent",
    "No agent": "无 Agent",
    "No agent installed": "未安装 Agent",
    "No branches": "没有分支",
    "No file open": "未打开文件",
    "No preview": "无预览",
    # Problems 工具窗：空状态、预览与过滤提示（对齐 macOS ProblemsView）。
    "No problems": "没有问题",
    "No problems in {file}": "{file} 中没有问题",
    "Select a problem to preview": "选择一条问题以预览",
    "This file is too large to preview": "文件过大，无法预览",
    "No project open": "未打开项目",
    "Not available yet": "暂不可用",
    "Open a Maven project to configure its settings.xml, local repository, Maven executable and JDK home.": "打开 Maven 项目后即可配置它的 settings.xml、本地仓库、Maven 可执行文件和 JDK Home。",
    "Open Agent": "打开 Agent",
    "Open a project first": "请先打开项目",
    "Path is outside the project": "路径不在项目内",
    "Plugin system is not available in the GPUI build yet.": "GPUI 构建尚未接入插件系统。",
    "Project folder is not available": "项目目录不可用",
    "Project path is not valid UTF-8": "项目路径不是合法 UTF-8",
    "Project paths must stay inside the workspace.": "项目路径必须位于工作区之内。",
    "RAM": "内存",
    "Reload Tab": "重新加载标签页",
    "Reveal in File Explorer": "在文件资源管理器中显示",
    "Save failed": "保存失败",
    "Search the workspace": "搜索工作区",
    "Send a message to start the conversation.": "发送消息开始对话。",
    "Stage all failed": "全部暂存失败",
    "Stage failed": "暂存失败",
    "Staged all changes": "已暂存全部变更",
    "Starting the agent…": "正在启动 Agent…",
    "Terminal closed": "终端已关闭",
    "The Java source for {name} could not be resolved.": "无法解析 {name} 的 Java 源码。",
    "The current file is unavailable for this launch.": "当前文件不可用于本次启动。",
    "Terminal unavailable": "终端不可用",
    "The Lithe data directory is unavailable.": "Lithe 数据目录不可用。",
    "The agent connection stopped.": "Agent 连接已停止。",
    "The agent did not return a session id.": "Agent 未返回会话 ID。",
    "The agent is not connected.": "Agent 未连接。",
    "The agent needs your permission to continue.": "Agent 需要你的授权才能继续。",
    "Thinking:": "思考：",
    "Toggle Dark": "切换深色",
    "Type to search the workspace": "输入以搜索工作区",
    # 搜索面板：`Replace all` 与「全部替换前先加载全部结果」是 GPUI 专有文案。
    "Replace all": "全部替换",
    "Load all search results before replacing all": "全部替换前请先加载全部搜索结果",
    "Unstage all failed": "全部取消暂存失败",
    "Unstage failed": "取消暂存失败",
    "Unstaged all changes": "已取消暂存全部变更",
    "Workspace path is not valid UTF-8": "工作区路径不是合法 UTF-8",
    "changes": "处变更",
    # Run 工具窗的 GPUI 专有文案。
    "Could not find executable": "找不到可执行文件",
    "Could not save run configuration": "无法保存运行配置",
    "Could not scan the project": "无法扫描项目",
    "Could not start configuration": "无法启动配置",
    "Could not stop run": "无法停止运行",
    # 「进程输出」后的运行方式标签。
    "Build tool goal": "构建工具目标",
    "Direct JVM": "JVM 直启",
    "Maven goal": "Maven 目标",
    "Go language": "Go",
    "Just": "Just",
    "Micronaut": "Micronaut",
    "Open a project to discover run configurations": "打开项目以发现运行配置",
    "Quarkus": "Quarkus",
    "Select a run configuration to see its details.": "选择一个运行配置以查看详情。",
    # 技术名称与占位符：显示名保持原样，只保证表里有对应项。
    "+": "+",
    "-": "-",
    "Gradle": "Gradle",
    "Java": "Java",
    "Make": "Make",
    "Node.js": "Node.js",
    "Python": "Python",
    "Rust": "Rust",
    "UTF-8": "UTF-8",
    "XML": "XML",
    "main": "main",
    # --- settings (agent A) ---：设置弹窗（阶段 0）补齐的 gpui 专有词条；
    # 覆盖设置各页与提交面板此前的未覆盖词（合并生成时一次补齐）。
    "(No message)": "（无消息）",
    "A non-empty command without NUL is required.": "命令不能为空，也不能包含 NUL 字符。",
    "API key found in that configuration": "该配置里有 API 密钥",
    "API key is empty.": "API 密钥为空。",
    "API key removed.": "已移除 API 密钥。",
    "API key stored": "API 密钥已存储",
    "API key stored.": "API 密钥已存储。",
    "Add a profile to configure an endpoint, model and API key, or import a Codex / Claude configuration below.": "先新增一个 Profile 配置端点、模型和 API 密钥，或在下方导入 Codex / Claude 配置。",
    "Add to .local exclude": "加入 .local exclude",
    "After choosing a parent directory, Lithe writes into its Lithe/logs subdirectory.": "选择父目录后，Lithe 会写入其 Lithe/logs 子目录。",
    "All settings will be reset to their default values. This action cannot be undone.": "全部设置将恢复为默认值。此操作无法撤销。",
    "Auto Build receives unstable builds as soon as they are produced. Updates may contain unfinished features.": "Auto Build 渠道会在构建产出的第一时间收到不稳定版本。更新可能包含未完成的功能。",
    "Automatic updates are not available in this build. Download the latest version from the release page.": "此构建不支持自动更新。请在发布页下载最新版本。",
    "Bun": "Bun",
    "Cargo": "Cargo",
    "Catalog entry unavailable": "目录条目不可用",
    "Changes fetched": "变更已拉取",
    "Changes stashed": "变更已贮藏",
    "Channel choices take effect once automatic updates are wired up; Auto Build is confirmed before it is saved.": "渠道选择在接入自动更新后生效；保存 Auto Build 之前会先确认。",
    "Check for updates": "检查更新",
    "Choose the parent directory for Lithe logs": "选择 Lithe 日志的父目录",
    "Clear key": "清除密钥",
    "Commit and push the listed repositories.": "提交并列出仓库并推送。",
    "Commit changes failed": "提交变更失败",
    "Commit result": "提交结果",
    "Commit selected": "提交选中",
    "Commit the listed repositories.": "提交列出的仓库。",
    "Configuration entries": "配置条目",
    "Configuration file is too large.": "配置文件过大。",
    "Copy configuration": "复制配置",
    "Could not determine the user home directory.": "无法确定用户主目录。",
    "Could not read the configuration file.": "无法读取配置文件。",
    "Custom commit instructions": "自定义提交说明",
    "Declarative plugins follow contract v1: packages are reviewed before install, run only host-launched processes, and can expose Web tool windows.": "声明式插件遵循契约 v1：安装前经过审查、只运行宿主拉起的进程，并可提供 Web 工具窗。",
    "Declared in this file": "本文件中声明的值",
    "Default (built-in monospace)": "默认（内置等宽字体）",
    "Delete {count} files": "删除 {count} 个文件",
    "Deleted log files:": "已删除的日志文件：",
    "Detailed diagnostics: On": "详细诊断：开",
    "Detecting Codex / Claude configurations…": "正在检测 Codex / Claude 配置…",
    "Detecting installed shells…": "正在检测已安装的 Shell…",
    "Diagnostic bundle saved to": "诊断包已保存到",
    "Diff limit": "Diff 上限",
    "Discarded all changes": "已丢弃全部变更",
    "Docker": "Docker",
    "Drop stash?": "删除贮藏？",
    "Dropped:": "已删除：",
    "Edit hook": "编辑钩子",
    "Edit in Run Configurations": "在 Run Configurations 中编辑",
    "Effective fetch options": "生效的 fetch 选项",
    "Enable switch, model-call observation, Codex subscription mode, custom agents and provider maintenance live in the Agent panel; wiring them to a global store lands with the agent session channel.": "启用开关、观察模型调用、Codex 订阅模式、自定义 Agent 与 Provider 维护都由 Agent 面板管理；接入全局存储将随 Agent 会话通道落地。",
    "Endpoint (https://api.example.com/v1)": "端点（https://api.example.com/v1）",
    "Enter a Maven local repository path.": "请填写 Maven 本地仓库路径。",
    "Generation itself runs from the Git panel AI button; this page only manages providers, keys and message rules.": "生成本身由 Git 面板的 AI 按钮发起；本页只管理服务商、密钥与信息规则。",
    "Git configuration saved.": "Git 配置已保存。",
    "Git executable not found": "未找到 Git 可执行文件",
    "Git identity cleared.": "Git 身份已清除。",
    "Git identity saved.": "Git 身份已保存。",
    "Hide advanced settings": "收起高级设置",
    "Hook name (letters, numbers, _ or -)": "钩子名称（字母、数字、_ 或 -）",
    "Hooks run native agent commands on lifecycle events. Lithe stores the library and syncs native Codex / Claude files on Save.": "钩子在生命周期事件上运行原生 Agent 命令。Lithe 保存这个库，并在保存时同步原生 Codex / Claude 文件。",
    "Hooks saved.": "钩子已保存。",
    "How local changes are kept before a checkout or rebase. The choice is remembered for this session only.": "切换分支或变基前如何保存本地更改。该选择只在本会话内记住。",
    "Imported from Claude; fields are managed by that configuration.": "从 Claude 导入；字段由该配置管理。",
    "Imported from Codex; fields are managed by that configuration.": "从 Codex 导入；字段由该配置管理。",
    "Importing a .zip package requires the host bridge (install review with version, permission and program declarations).": "导入 .zip 包需要宿主桥接（带版本、权限与程序声明的安装审查）。",
    "Include commit body": "包含提交正文",
    "Inspecting installed agents…": "正在检查已安装的 Agent…",
    "Inspecting installed agent runtimes…": "正在检查已安装的 Agent 运行时…",
    "No ACP adapter is installed. Install one from the Agent panel to use AI features.": "未安装 ACP 适配器。请从 Agent 面板安装后使用 AI 功能。",
    "Provider, model, API key, Ollama and ACP session options live in the Agent panel; clearing the agent history is done from the Agent panel in this build.": "服务商、模型、API Key、Ollama 与 ACP 会话选项都在 Agent 面板中管理；此构建需从 Agent 面板清空对话历史。",
    "Installed version": "已安装版本",
    "Leave empty to inherit the agent timeout.": "留空表示继承 Agent 自己的超时。",
    "MCP configuration": "MCP 配置",
    "MCP sessions are owned by the Agent panel; this page inspects and validates the underlying configuration files.": "MCP 会话由 Agent 面板拥有；本页用于检查与校验底层配置文件。",
    "Maven JDK Home is an override stored with the run toolchain; edit it in Run Configurations.": "Maven JDK Home 是随运行工具链存储的覆盖值；请在 Run Configurations 中编辑。",
    "Maven local repository": "Maven 本地仓库",
    "Move to Changelist": "移动到 Changelist",
    "Move to Changelist…": "移动到 Changelist…",
    "Name must use letters, numbers, _ or - (max 80).": "名称只能用字母、数字、_ 或 -（最多 80 个字符）。",
    "Needs sync": "待同步",
    "New hook": "新建钩子",
    "No Codex or Claude configuration detected.": "未检测到 Codex 或 Claude 配置。",
    "No agent selected": "未选择 Agent",
    "No hooks yet. Use “New hook” to add lifecycle commands for Codex or Claude.": "还没有钩子。使用「新建钩子」为 Codex 或 Claude 添加生命周期命令。",
    "No key found in that configuration": "该配置里没有 API 密钥",
    "No local repository declared; Maven uses its default location.": "文件未声明本地仓库；Maven 使用默认位置。",
    "No profile yet": "还没有 Profile",
    "No readable Git configuration entries.": "没有可读取的 Git 配置条目。",
    "No servers parsed yet. “Validate configuration” normalizes the source file.": "尚未解析出服务器。使用「校验配置」对来源文件做归一化。",
    "No shells were detected on this machine.": "本机没有检测到 Shell。",
    "No shortcut matches this search.": "没有匹配该搜索的快捷键。",
    "Not configured": "未配置",
    "Not configured in this scope": "此作用域内未配置",
    "One pattern per line": "每行一个模式",
    "Only Lithe-managed logs for all modules and sessions in the current directory are deleted. Filters do not limit cleanup; future events keep being recorded.": "只删除当前目录内 Lithe 自己写入的全部模块与会话日志。筛选条件不会限制清理范围；后续日志会继续记录。",
    "Only delete Lithe-managed log files in the current directory.": "只删除当前目录中 Lithe 自己写入的日志文件。",
    "Only “All tools” is available for this event.": "该事件只能选择「全部工具」。",
    "Open a project to edit the Git identity.": "打开项目后才能编辑 Git 身份。",
    "Open a project to inspect the Git executable and repository configuration.": "打开项目后才能查看 Git 可执行文件与仓库配置。",
    "Open download page": "打开下载页",
    "Per-command editing, JSON import/export and “Reset all” wait for the keymap override channel in this build.": "逐命令编辑、JSON 导入导出与「全部重置」需要本构建尚未接入的 keymap 覆盖通道。",
    "Preset coverage statistics unlock with the keymap registry channel; Default and Vim presets map the workbench menu bindings.": "预设覆盖率统计需要 keymap 注册表通道；Default 与 Vim 预设已映射工作台菜单快捷键。",
    "Profile name": "Profile 名称",
    "Profiles and API keys are stored in the application settings file. Keys are never shown again after saving.": "Profile 与 API 密钥保存在应用设置文件中；密钥保存后不会再显示。",
    "Publish": "发布",
    "Push target": "推送目标",
    "Resolving push target…": "正在解析推送目标…",
    "Creates the remote branch": "将创建远端分支",
    "{count} commits to push": "待推送 {count} 个提交",
    "Paste a patch to apply": "粘贴要应用的补丁",
    "Reload file": "重新读取文件",
    "Repository initialized": "仓库已初始化",
    "Repository preferences": "仓库偏好",
    "Requires API key": "需要 API 密钥",
    "Review commit": "审查提交",
    "Runs on": "运行于",
    "Save hook": "保存钩子",
    "Saved. Reload projects to pick up the new repository location.": "已保存。重新加载项目后才会使用新的仓库位置。",
    "Search stashes": "搜索贮藏",
    "Seconds (1–86400)": "秒数（1–86400）",
    "Select a profile": "选择一个 Profile",
    "Select one or two agents.": "选择一到两个 Agent。",
    "Shells detected on this machine. Unavailable entries are dimmed.": "本机检测到的 Shell。不可用的条目会置灰。",
    "Show advanced settings": "展开高级设置",
    "Stage selected": "暂存选中",
    "Stash action failed": "贮藏操作失败",
    "Stash applied": "贮藏已应用",
    "Stash dropped": "贮藏已删除",
    "Stash failed": "贮藏失败",
    "Stash popped": "贮藏已弹出",
    "Stash selected": "贮藏选中",
    "Stash changes": "贮藏更改",
    "Subject length 20–200, diff characters 8000–120000. Changes are committed when the value is valid.": "主题长度 20–200，diff 字符数 8000–120000。值合法时立即提交。",
    "Subject limit": "主题长度上限",
    "Switch to Auto Build": "切换到 Auto Build",
    "Switch to Auto Build channel?": "切换到 Auto Build 渠道？",
    "Temporary Git configuration": "临时 Git 配置",
    "That configuration could not be parsed.": "该配置无法解析。",
    "The commit author for this repository or your user account.": "该仓库或当前用户账号的提交署名。",
    "The configuration file is empty or missing.": "配置文件为空或不存在。",
    "The configuration text is empty.": "配置文本为空。",
    "The contract v1 host is part of the shared Core; the GPUI build has not wired the install and session bridge yet.": "契约 v1 宿主在共享 Core 内；GPUI 构建尚未接入安装与会话桥接。",
    "The file does not exist yet; saving creates a minimal Maven settings.xml.": "文件还不存在；保存时会创建最小化的 Maven settings.xml。",
    "The file is not a valid Maven settings.xml.": "该文件不是合法的 Maven settings.xml。",
    "The file is not a valid Maven settings.xml; fix it outside Lithe before editing here.": "该文件不是合法的 Maven settings.xml；请先在 Lithe 之外修复它。",
    "The hook library changed since it was loaded. Reload and try again.": "钩子库在加载后发生过变化。请重新加载后重试。",
    "The hook library is not loaded yet.": "钩子库尚未加载。",
    "The previous directory": "之前的目录",
    "The previous log directory is already empty.": "之前的日志目录已经是空的。",
    "The selection is saved as the default for new terminals; running terminals keep their current shell.": "该选择会保存为新终端的默认值；正在运行的终端保持当前 Shell。",
    "Timeout must be 1–86400 seconds or empty.": "超时必须是 1–86400 秒或留空。",
    "Unable to export the diagnostic bundle:": "无法导出诊断包：",
    "Unable to open the current log.": "无法打开当前日志。",
    "Unable to open the log directory.": "无法打开日志目录。",
    "Unnamed profile": "未命名 Profile",
    "Unstage selected": "取消暂存选中",
    "Up to date": "已是最新",
    "Use upstream": "使用上游",
    "Validate configuration": "校验配置",
    "Yarn": "Yarn",
    "exit code": "退出码",
    "hooks": "个钩子",
    "log files, freed": "个日志文件，已释放",
    "npm": "npm",
    "pnpm": "pnpm",
    "signal": "信号",
    "still contains about": "仍包含约",
    "target": "目标",
    "write failures:": "写入失败：",
}

# 动态传给 tr() 的标题（分组、页面、面包屑）不在字面量扫描里。
extra = {
    "Appearance & Behavior": "外观与行为",
    "Version Control": "版本控制",
    "Build, Execution, Deployment": "构建、执行、部署",
    "Languages & Frameworks": "语言与框架",
    "Tools": "工具",
    "AI": "AI",
    "General": "通用",
    "Updates": "更新",
    "Keymap": "快捷键",
    "Process Termination": "进程终止",
    "Plugins": "插件",
    "Project · JDK & Maven": "项目 · JDK 与 Maven",
    "Run Configurations": "运行配置",
    "LSP": "LSP",
    "Logs and Diagnostics": "日志与诊断",
    "AI Providers": "AI 服务商",
    "Agents": "Agents",
    "Library": "资源库",
    "Instructions": "指令",
    "Skills": "技能",
    "Hooks": "Hooks",
    "MCP": "MCP",
    "AI & Commit": "AI 与提交",
    "Appearance": "外观",
    "Theme": "主题",
    "Dark mode": "深色模式",
    "Language": "语言",
    "UI language": "界面语言",
    "English": "English",
    "On": "开启",
    "Off": "关闭",
    "Display": "显示",
    "Font size": "字号",
    "Wrap lines": "自动换行",
    "Minimap": "代码缩略图",
    "Line numbers": "行号",
    "Scroll beyond last line": "允许滚动越过末行",
    "Current version": "当前版本",
    "Update channel": "更新渠道",
    "Stable": "稳定版",
    "Preview": "预览版",
    "Auto check for updates": "自动检查更新",
    "Run services": "运行服务",
    "Terminals with running programs": "有程序运行的终端",
    "Agent tasks": "Agent 任务",
    "Background services": "后台服务",
    "Graceful stop seconds": "优雅退出等待秒数",
    "Scrollback": "回滚行数",
    "Memory usage": "内存占用",
    "Data directory": "数据目录",
    "Commit messages": "提交信息",
    "AI commit messages": "AI 提交信息",
    "Format": "格式",
    "Conventional": "Conventional",
    "Plain": "Plain",
    "GitMoji": "GitMoji",
    "Status": "状态",
    "Database": "数据库",
    "Background": "背景",
    "Updates are not available in this GPUI build.": "此 GPUI 构建尚未接入自动更新。",
    "References are not available in this GPUI build.": "此 GPUI 构建尚未接入引用查找。",
    "Problems are not available in this GPUI build.": "此 GPUI 构建尚未接入问题面板。",
    "Spring support is not available in this GPUI build.": "此 GPUI 构建尚未接入 Spring 支持。",
    "Tests are not available in this GPUI build.": "此 GPUI 构建尚未接入测试面板。",
    "The debugger is not available in this GPUI build.": "此 GPUI 构建尚未接入调试器。",
    "Build output is not available in this GPUI build.": "此 GPUI 构建尚未接入构建输出。",
    "This tool window is not available in this GPUI build.": "此工具窗在当前 GPUI 构建中尚不可用。",
    # 顶部菜单栏。顶层名称由上面的 overrides 处理。
    "Open File…": "打开文件…",
    "Open Recent": "最近打开",
    "No Recent Projects": "没有最近项目",
    "Quit Lithe": "退出 Lithe",
    "Find Next": "查找下一个",
    "Find Previous": "查找上一个",
    "Toggle Line Comment": "切换行注释",
    "Tool Windows": "工具窗口",
    "Docks": "停靠区",
    "Dark Mode": "深色模式",
    "Toggle Left Dock": "切换左侧停靠区",
    "Toggle Bottom Dock": "切换底部停靠区",
    "Toggle Right Dock": "切换右侧停靠区",
    "Next Problem": "下一个问题",
    "Previous Problem": "上一个问题",
    "Clear Terminal": "清空终端",
    "Close Terminal": "关闭终端",
    "Run Configurations…": "运行配置…",
    "AI Agent": "AI Agent",
    "Toggle Full Screen": "切换全屏",
    "Lithe Repository": "Lithe 仓库",
    "About Lithe": "关于 Lithe",
    "Command Palette…": "命令面板…",
    # 新建 Java 类型对话框的字段标签；该对话框尚未接入 GPUI，
    # 先把中文放进生成表，后续 tr("Class name") 可直接复用。
    "Class name": "类名",
    # 运行配置的语言分类标题。Java / Python / Rust / Go / Node.js / Maven 这类
    # 专有名词在 shared/i18n 里已有同名译文，其余的在这里补齐。
    ".NET": ".NET",
    "PHP": "PHP",
    "Ruby": "Ruby",
    "Swift": "Swift",
    # Git 日志与变更列表工具条：GPUI 的 git 面板尚未接入 shared 的这些词条 id，
    # 文案按 shared/i18n 里的中文逐条对齐，避免两端口径漂移。
    "Branch: All": "分支：全部",
    "Choose Diff Source": "选择差异来源",
    "Default Changelist": "默认变更列表",
    "Delete Changelist": "删除变更列表",
    "Delete branch": "删除分支",
    "Diff options": "差异选项",
    "Filter by text…": "按文本筛选…",
    "Filter my branches": "筛选我的分支",
    "Go to HEAD": "导航到所选分支 HEAD",
    "Group by Directory": "按目录分组",
    "Log: All": "日志：全部",
    "Mark branch": "标记分支",
    "More options": "更多选项",
    "New Changelist": "新建变更列表",
    "Rename Changelist": "重命名变更列表",
    "Unstage All Changes": "取消暂存全部更改",
    "Update Parent Repository References": "更新父仓库引用",
    "Update selected": "更新所选",
    # Run 面板里尚未进 shared/i18n 的短语，按 shared 的同义词条对齐。
    "Choose services": "选择服务",
    "Clear output": "清除输出",
    "Identify and generate": "识别并生成",
    "Java project model is ready": "Java 项目模型已就绪",
    # 终端工具条与配置菜单。GPUI 侧的措辞与 shared 的 terminal.* 词条不同，
    # 中文按 Tauri 同义词条对齐（选择终端配置文件 / 向右拆分终端）。
    "Choose terminal profile": "选择终端配置文件",
    "Default Terminal": "默认终端",
    "Rescan installed shells": "重新扫描已安装的 Shell",
    "Split Terminal": "向右拆分终端",
    # 提交记录（Git Log）。按 shared 的 git.log.* / git.log.toolbar.* 中文对齐。
    "All branches": "全部分支",
    "Select a commit to see its files.": "选择一个提交以查看其文件。",
    "files": "个文件",
    # 引用动作（右键菜单 / 动作条），中文对齐 shared 的 git.log.action.* 词条。
    "Rebase Current onto Selected": "将当前分支变基到此引用",
    "Merge Selected into Current": "将此引用合并到当前分支",
    "Pull (Rebase) into Current": "使用变基拉入远程分支",
    "Pull (Merge) into Current": "使用合并拉入远程分支",
    "Branch deleted": "分支已删除",
    "Tag deleted": "标签已删除",
    "Source": "来源",
    "Copy Branch Name": "复制分支名",
    # 提交动作（右键菜单）：对齐 shared 的 git.* / git.log.* 中文。
    "Undo Commit": "撤销提交",
    "Edit Commit Message": "编辑提交消息",
    "Delete Commit": "删除提交",
    "Squash Commits": "合并提交",
    "Reset to Commit": "重置到此处",
    "Cherry-pick Commit": "Cherry-pick 提交",
    "Revert Commit": "还原提交",
    "Open Commit Diff": "打开提交差异",
    "Compare with HEAD": "与 HEAD 比较",
    "Copy Commit Hash": "复制提交哈希",
    "Selected commits": "选中提交",
    "Affected commits": "连带改写",
    "History rewritten": "历史已改写",
    "Soft - keep staged": "软重置 - 保留暂存",
    "Mixed - keep files": "混合重置 - 保留文件",
    "Hard - discard changes": "硬重置 - 丢弃更改",
    "Commit message": "提交消息",
    "Save": "保存",
    # Git Log 提交表工具栏。中文对齐 shared 的 git.log.* 词条。
    "Filter scope": "筛选字段",
    "Branch filter": "分支筛选",
    "Show decorations": "显示分支和标签",
    "Author": "作者",
    "Branch": "分支",
    "Back": "返回",
    "Commit Diff": "提交差异",
    # Maven 工具窗（GPUI 侧尚未接入 shared 的 maven.* 词条 id，按 Tauri 中文对齐）。
    "Could not read Maven diagnostics": "无法读取 Maven 诊断",
    "Could not read Maven test results": "无法读取 Maven 测试结果",
    "Could not resolve Maven dependencies": "无法解析 Maven 依赖",
    "Could not start Maven task": "无法启动 Maven 任务",
    "Could not stop Maven task": "无法停止 Maven 任务",
    "Maven dependency resolution exited with code {code}.": "Maven 依赖解析以退出码 {code} 结束。",
    "Maven exited with code {code}.": "Maven 以退出码 {code} 结束。",
    "Maven task cancelled.": "Maven 任务已取消。",
    "No source roots": "没有源码根目录",
    # --- menus (agent C) ---：菜单线（阶段 2）新增的 gpui 专有词条。
    "Maven Output": "Maven 输出",
    # --- settings (agent A) ---：设置页常量表/变量传入的标签与说明。
    "After tool": "工具调用后",
    "Agent connection": "Agent 连接",
    "Agent runtime": "Agent 运行时",
    "AI Commit": "AI 提交",
    "All sessions": "所有会话",
    "All severities": "全部级别",
    "All tools": "所有工具",
    "Anthropic Messages": "Anthropic Messages",
    "Application": "应用",
    "Auto Build": "自动构建",
    "Auto completion": "自动补全",
    "Autocomplete": "自动补全",
    "Automatically": "自动",
    "Bearer": "Bearer",
    "Before tool": "工具调用前",
    "Build, run and debug": "构建、运行与调试",
    "Chat Completions": "Chat Completions",
    "Clear logs in the current directory": "清空当前目录中的日志",
    "Commit rules": "提交规则",
    "Credential helper": "凭据助手",
    "Current log location": "当前日志位置",
    "Current session": "当前会话",
    "Custom log location": "自定义日志位置",
    "Declarative Plugins": "声明式插件",
    "Default location": "默认位置",
    "Default log location": "默认日志位置",
    "Detailed diagnostics": "详细诊断",
    "Detected language servers": "检测到的语言服务器",
    "Diagnostic bundle": "诊断包",
    "Editor and language services": "编辑器与语言服务",
    "Editor tabs layout": "编辑器标签页布局",
    "Event": "事件",
    "Export Diagnostic Bundle…": "导出诊断包…",
    "Fetch defaults": "拉取默认值",
    "File edits": "文件编辑",
    "Files": "文件",
    "Font family": "字体族",
    "Git executable": "Git 可执行文件",
    "Git execution": "Git 执行",
    "Git identity": "Git 身份",
    "Git integration": "Git 集成",
    "Git Panel": "Git 面板",
    "Git strategy": "Git 策略",
    "Git version": "Git 版本",
    "Host": "宿主",
    "Import Java projects on open": "打开时导入 Java 项目",
    "Inline": "内联",
    "Install, update and uninstall run from the Agent panel with its progress and preflight checks.": "安装、更新与卸载在 Agent 面板中执行，并带有进度与预检。",
    "Installed agent runtimes are the providers available to this build.": "已安装的 Agent 运行时就是此构建可用的服务来源。",
    "Installed agents": "已安装的 Agent",
    "Log locations": "日志位置",
    "Log timeline": "日志时间线",
    "Manually": "手动",
    "Matcher": "匹配器",
    "MCP servers are a user-level Codex / Claude configuration; sessions run through the Agent panel.": "MCP 服务器是用户级的 Codex / Claude 配置；会话在 Agent 面板中运行。",
    "Minimum level": "最低级别",
    "Multiple rows": "多行",
    "Node runtime": "Node 运行时",
    "Open Settings…": "打开设置…",
    "Parameter hints": "参数提示",
    "Performance": "性能",
    "Previous session": "上个会话",
    "Projects": "项目",
    "Prompt submitted": "提示已提交",
    "Render Whitespace": "显示空白字符",
    "Responses API": "Responses API",
    "Retention and cleanup": "保留与清理",
    "Revision": "修订",
    "Rules define how generated messages look; generation runs from the Git panel AI button.": "规则决定生成消息的形态；生成动作从 Git 面板的 AI 按钮触发。",
    "Runtimes": "运行时",
    "Scope": "作用域",
    "Search Files…": "在文件中搜索…",
    "Semantic highlighting": "语义高亮",
    "Session": "会话",
    "Session start": "会话开始",
    "Shell commands": "Shell 命令",
    "Shelve changes": "搁置更改",
    "Show Changelists": "显示变更列表",
    "Single line": "单行",
    "Stop Build": "停止构建",
    "Storage": "存储",
    "The source changed since it was loaded. Reload and try again.": "来源在加载后已发生变化，请重新加载后再试。",
    "These shortcuts are registered by the GPUI workbench menus.": "这些快捷键由 GPUI 工作台菜单注册。",
    "This page matches Tauri's declarative-plugins section; management lands when the plugin host bridge arrives.": "此页对应 Tauri 的声明式插件分区；插件宿主桥接落地后即可管理。",
    "This repository": "当前仓库",
    "Toggle Commit Panel": "切换提交面板",
    "Toggle Sidebar": "切换侧栏",
    "Toolchain defaults": "工具链默认值",
    "Turn end": "回合结束",
    "User email": "用户邮箱",
    "User name": "用户名",
    "User settings.xml": "用户 settings.xml",
    "Zip Archives": "Zip 压缩包",
    "max_tokens (legacy gateways)": "max_tokens（旧版网关）",
    # --- 提交面板（代理 B 阶段 1/2 新增的拉取与快进提示）---
    "Behind {behind}, ahead {ahead}": "落后 {behind}，领先 {ahead}",
    "Checking the upstream branch…": "正在检查上游分支…",
    "Local changes are not committed.": "本地更改尚未提交。",
    "No upstream is configured for this branch.": "此分支未配置上游。",
    "Pull state is unavailable.": "拉取状态不可用。",
    "The branches have diverged; fast-forward is not possible.": "分支已分叉，无法快进。",
    "Upstream: {upstream}": "上游：{upstream}",
    # --- 提交面板（代理 B 的 checkout 覆盖确认）---
    "Checkout anyway": "仍然切换",
    "Switching to {branch} would overwrite local changes.": "切换到 {branch} 会覆盖本地更改。",
    "and {count} more files": "以及另外 {count} 个文件",
    # --- 提交面板（代理 B 的「已保存更改」本地补丁区）---
    "Saved Changes": "已保存的更改",
    "Saved changes name": "已保存更改的名称",
    "Changes saved": "更改已保存",
    "Saved changes name is empty": "已保存更改的名称不能为空",
    "Saved changes are no longer available": "已保存的更改已不存在",
    "Saved changes are not applicable": "已保存的更改不适用于当前工作区",
    "Changes restored": "更改已恢复",
    "Saved changes deleted": "已保存的更改已删除",
    "Exports the current working tree as a local patch that can be restored later.": "把当前工作区导出为可稍后恢复的本地补丁。",
}


def call_arguments(text, name):
    """返回 `name(...)` 每次调用括号内的原文（按括号配平，忽略字符串里的括号）。"""
    for match in re.finditer(r"\b" + name + r"\s*\(", text):
        index = match.end()
        depth = 1
        start = index
        while index < len(text) and depth:
            char = text[index]
            if char == '"':
                index += 1
                while index < len(text):
                    if text[index] == "\\":
                        index += 2
                        continue
                    if text[index] == '"':
                        break
                    index += 1
            elif char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        yield text[start:index]


def split_arguments(arguments):
    """按顶层逗号切分实参，返回去空白后的参数列表。"""
    parts = []
    current = ""
    depth = 0
    index = 0
    while index < len(arguments):
        char = arguments[index]
        if char == '"':
            current += char
            index += 1
            while index < len(arguments):
                current += arguments[index]
                if arguments[index] == "\\":
                    current += arguments[index + 1]
                    index += 2
                    continue
                if arguments[index] == '"':
                    index += 1
                    break
                index += 1
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += char
        index += 1
    if current.strip():
        parts.append(current.strip())
    return parts


def literal(argument):
    """把单个字符串字面量实参还原成原文；其它表达式返回 None。"""
    match = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', argument.strip(), re.S)
    return match.group(1) if match else None


def source_paths():
    for path in glob.glob(os.path.join(GPUI, "**", "*.rs"), recursive=True):
        if "target" in path or "i18n_zh.rs" in path:
            continue
        yield path


def literal_keys():
    """界面里字面量传给 tr()/item()/item_state() 的文案。"""
    keys = set()
    for path in source_paths():
        text = open(path, encoding="utf-8").read()
        for name in ("tr", "item", "item_state"):
            for arguments in call_arguments(text, name):
                parts = split_arguments(arguments)
                if not parts:
                    continue
                key = literal(parts[0])
                if key is not None:
                    keys.add(key)
    return keys


def declared_keys():
    """`en()` 声明且仍有调用点的 key：以变量传入 tr() 的标题、标签和选项名。"""
    text = open(I18N, encoding="utf-8").read()
    start = text.index("fn en(")
    end = text.index("\n    }\n", start)
    declared = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*=>', text[start:end], re.M)
    others = ""
    for path in source_paths():
        if os.path.abspath(path) == os.path.abspath(I18N):
            continue
        others += open(path, encoding="utf-8").read()
    return {key for key in declared if f'"{key}"' in others}


def main():
    # 菜单顶层名称需要 IDE 习惯叫法，优先于 shared/i18n 的同名通用词条
    # （例如 shared 把 "View" 译成“查看”，菜单里应为“视图”）。
    overrides = {
        "File": "文件",
        "Edit": "编辑",
        "View": "视图",
        "Go": "转到",
        "Terminal": "终端",
        "Run": "运行",
        "Tools": "工具",
        "Window": "窗口",
        "Help": "帮助",
        # 菜单文案优先用 IDE 习惯叫法，避免命中 shared 里同值的通用词条
        # （例如 shared 的 "Database" 是“数据库连接”，菜单应为“数据库”）。
        "Database": "数据库",
        "Clear Terminal": "清空终端",
        # 通知中心「全部清除」：shared 里同值的 aiSettings.clearAll 是「全部清空」，
        # 这里对齐 Tauri 通知中心的 notifications.clearAll（「全部清除」）。
        "Clear All": "全部清除",
        # 设置页里这两个词是分区名与运行时名称，shared 的同值词条分别是
        # “供应商管理”和“运行时长”，与这里的含义不同。
        "Providers": "服务商",
        "Runtime": "运行时",
        # Run 工具窗里这些词的含义与 shared 的通用词条不同。
        "Groups": "分组",
        "Provider": "提供者",
        "Pin configuration": "固定配置",
        "Unpin configuration": "取消固定配置",
        # shared 的 native.moveToTrash 是 macOS 语义（移到废纸篓）；GPUI 三端统一
        # 用「回收站」，覆盖优先于 shared 词条，也不放进 MANUAL（否则会被判为过期）。
        "Move to Trash": "移到回收站",
    }

    keys = literal_keys() | declared_keys()

    en = json.load(open(os.path.join(ROOT, "shared/i18n/locales/en-US.json"), encoding="utf-8"))["messages"]
    zh = json.load(open(os.path.join(ROOT, "shared/i18n/locales/zh-CN.json"), encoding="utf-8"))["messages"]

    shared = {}
    for key, value in en.items():
        if isinstance(value, str) and isinstance(zh.get(key), str):
            shared.setdefault(value, zh[key])

    missing = sorted(key for key in keys if key not in shared and key not in extra)
    uncovered = [key for key in missing if key not in MANUAL]
    stale = sorted(key for key in MANUAL if key not in missing)
    if uncovered or stale:
        for key in uncovered:
            print("untranslated key:", json.dumps(key, ensure_ascii=False))
        for key in stale:
            print("stale MANUAL entry:", json.dumps(key, ensure_ascii=False))
        raise SystemExit(
            f"MANUAL must cover exactly the {len(missing)} keys without a shared translation"
        )

    lines = [
        "// 由 gpui/scripts/generate-i18n-zh.py 生成，不要手改。",
        "// shared/i18n 已有词条直接复用；GPUI 专有文案来自脚本里的 MANUAL。",
        "pub(crate) fn zh_translate(key: &str) -> Option<&'static str> {",
        "    Some(match key {",
    ]
    for key in sorted(keys | set(extra)):
        value = overrides.get(key) or shared.get(key) or MANUAL.get(key) or extra.get(key)
        if value is None:
            continue
        lines.append(f"        {json.dumps(key, ensure_ascii=False)} => {json.dumps(value, ensure_ascii=False)},")
    lines += ["        _ => return None,", "    })", "}", ""]
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print(
        f"wrote {OUT}: {len(keys)} keys "
        f"({len(missing)} from MANUAL, {len(extra)} dynamic titles)"
    )


if __name__ == "__main__":
    main()
