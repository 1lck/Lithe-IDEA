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
    # Git Log 提交 diff 的空态（并行开发补录，保持生成器可运行）。
    "No textual changes": "无文本变更",
    "Filter files…": "筛选文件…",
    "Git actions": "Git 操作",
    "Read-Only Split": "只读分屏",
    "Save Failed": "保存失败",
    "Saved As": "已另存为",
    "Search Files": "在文件中搜索",
    "Stash is not available in this build yet": "此构建尚未支持贮藏",
    "last commit": "上次提交",
    "Authenticate": "登录",
    "Built in": "内置",
    "Changes unavailable": "变更不可用",
    "Col": "列",
    "Commit created": "提交已创建",
    "Commit failed": "提交失败",
    "Could not open file": "无法打开文件",
    "Could not read run configuration": "无法读取运行配置",
    "Delete?": "删除？",
    "Discard changes?": "丢弃更改？",
    "Discard failed": "丢弃失败",
    "Discard unsaved changes?": "丢弃未保存的更改？",
    "Discarded": "已丢弃",
    "Editor unavailable": "编辑器不可用",
    "Enter sends · Shift+Enter for a new line": "Enter 发送 · Shift+Enter 换行",
    "File is outside the project": "文件不在项目内",
    "File no longer exists": "文件已不存在",
    "File operation failed": "文件操作失败",
    "Install an ACP adapter to start a conversation:": "安装 ACP 适配器后即可开始对话：",
    "Invalid name": "名称无效",
    "Ln": "行",
    "Loading changes…": "正在加载变更…",
    "Extensions are not available in this GPUI build.": "此 GPUI 构建未提供扩展页。",
    "No Agent installed": "未安装 Agent",
    "No agent": "无 Agent",
    "No agent installed": "未安装 Agent",
    "No branches": "没有分支",
    "No file open": "未打开文件",
    "No preview": "无预览",
    "No project open": "未打开项目",
    "Not available yet": "暂不可用",
    "Open Agent": "打开 Agent",
    "Open Run panel": "打开运行面板",
    "Open a project first": "请先打开项目",
    "Path is outside the project": "路径不在项目内",
    "Plugin system is not available in the GPUI build yet.": "GPUI 构建尚未接入插件系统。",
    "Project folder is not available": "项目目录不可用",
    "Project path is not valid UTF-8": "项目路径不是合法 UTF-8",
    "RAM": "内存",
    "Save failed": "保存失败",
    "Search the workspace": "搜索工作区",
    "Send a message to start the conversation.": "发送消息开始对话。",
    "Stage all failed": "全部暂存失败",
    "Stage failed": "暂存失败",
    "Staged all changes": "已暂存全部变更",
    "Starting the agent…": "正在启动 Agent…",
    "Terminal closed": "终端已关闭",
    "Terminal exited": "终端已退出",
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
    "Go language": "Go",
    "Just": "Just",
    "Micronaut": "Micronaut",
    "Open a project to discover run configurations": "打开项目以发现运行配置",
    "Quarkus": "Quarkus",
    "Select a run configuration to see its details.": "选择一个运行配置以查看详情。",
    # 技术名称与占位符：显示名保持原样，只保证表里有对应项。
    "+": "+",
    "-": "-",
    "CSS": "CSS",
    "Gradle": "Gradle",
    "HTML": "HTML",
    "Java": "Java",
    "Make": "Make",
    "Node.js": "Node.js",
    "Python": "Python",
    "Rust": "Rust",
    "UTF-8": "UTF-8",
    "XML": "XML",
    "main": "main",
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
