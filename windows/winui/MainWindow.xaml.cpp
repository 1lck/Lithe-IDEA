#include "pch.h"
#include "MainWindow.xaml.h"

#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif

#include "fuzzy_match.h"
#include "gutter_hit_test.h"
#include "syntax_highlighter.h"
#include "text_diff.h"
#include "ui_dialogs.h"
#include "workbench_ui_state.h"

#include <microsoft.ui.xaml.window.h>

#include <cctype>
#include <cmath>
#include <ctime>
#include <iomanip>
#include <iterator>
#include <sstream>

namespace winrt::Lithe::implementation {
namespace {

using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Controls::Primitives;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
namespace Text = Microsoft::UI::Text;

std::string utf8(hstring const& value) {
    return to_string(value);
}

hstring text(std::string_view value) {
    return to_hstring(value);
}

std::string pathUtf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::filesystem::path pathFromUtf8(std::string_view value) {
    const auto* begin = reinterpret_cast<const char8_t*>(value.data());
    return std::filesystem::path(std::u8string(begin, begin + value.size()));
}

std::string fileName(std::string_view path) {
    const auto value = pathFromUtf8(path).filename().u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::string parentPath(std::string_view path) {
    const auto value = pathFromUtf8(path).parent_path().generic_u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::string joinValues(const std::vector<std::string>& values) {
    std::string result;
    for (const auto& value : values) {
        if (!result.empty()) result += ", ";
        result += value;
    }
    return result;
}

std::vector<std::string> splitValues(std::string value) {
    std::vector<std::string> result;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto end = value.find(',', start);
        auto item = value.substr(start, end == std::string::npos ? value.size() - start
                                                                 : end - start);
        const auto first = item.find_first_not_of(" \t\r\n");
        const auto last = item.find_last_not_of(" \t\r\n");
        if (first != std::string::npos) result.push_back(item.substr(first, last - first + 1));
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return result;
}

std::vector<std::string> lines(std::string_view value) {
    std::vector<std::string> result;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto end = value.find('\n', start);
        auto line = std::string(value.substr(
            start, end == std::string_view::npos ? value.size() - start : end - start));
        if (!line.empty() && line.back() == '\r') line.pop_back();
        result.push_back(std::move(line));
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return result;
}

std::uintptr_t objectKey(IInspectable const& value) {
    return reinterpret_cast<std::uintptr_t>(get_abi(value));
}

ListViewItem makeListItem(std::string label, std::string tag = {}) {
    ListViewItem item;
    item.Content(box_value(text(label)));
    if (!tag.empty()) item.Tag(box_value(text(tag)));
    item.HorizontalContentAlignment(HorizontalAlignment::Stretch);
    return item;
}

std::string itemTag(IInspectable const& item) {
    const auto listItem = item.try_as<ListViewItem>();
    if (!listItem || !listItem.Tag()) return {};
    return utf8(unbox_value<hstring>(listItem.Tag()));
}

Media::SolidColorBrush applicationBrush(wchar_t const* key) {
    return Application::Current().Resources()
        .Lookup(box_value(hstring(key))).try_as<Media::SolidColorBrush>();
}

Windows::UI::Color applicationColor(wchar_t const* key) {
    return unbox_value<Windows::UI::Color>(
        Application::Current().Resources().Lookup(box_value(hstring(key))));
}

TextBlock diffCell(std::string value, int column, bool muted = false) {
    TextBlock block;
    block.Text(text(value));
    block.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
    block.FontSize(12);
    block.Padding(Thickness{8, 3, 8, 3});
    block.TextTrimming(TextTrimming::CharacterEllipsis);
    if (muted) block.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    Grid::SetColumn(block, column);
    return block;
}

template <typename T>
T findDescendant(DependencyObject const& root) {
    const auto count = Media::VisualTreeHelper::GetChildrenCount(root);
    for (int32_t index = 0; index < count; ++index) {
        const auto child = Media::VisualTreeHelper::GetChild(root, index);
        if (const auto match = child.try_as<T>()) return match;
        if (const auto nested = findDescendant<T>(child)) return nested;
    }
    return nullptr;
}

std::vector<int32_t> utf16Offsets(std::string_view value) {
    std::vector<int32_t> offsets(value.size() + 1, 0);
    int32_t utf16 = 0;
    std::size_t index = 0;
    while (index < value.size()) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t length = first < 0x80 ? 1
            : first >= 0xc2 && first <= 0xdf ? 2
            : first >= 0xe0 && first <= 0xef ? 3
            : first >= 0xf0 && first <= 0xf4 ? 4 : 1;
        if (index + length > value.size() ||
            !std::all_of(value.begin() + static_cast<std::ptrdiff_t>(index + 1),
                         value.begin() + static_cast<std::ptrdiff_t>(index + length),
                         [](char character) {
                             return (static_cast<unsigned char>(character) & 0xc0) == 0x80;
                         })) {
            length = 1;
        }
        for (std::size_t byte = 1; byte < length; ++byte) offsets[index + byte] = utf16;
        utf16 += length == 4 ? 2 : 1;
        index += length;
        offsets[index] = utf16;
    }
    return offsets;
}

std::wstring lowercase(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](wchar_t character) { return std::towlower(character); });
    return value;
}

std::string dateText(std::int64_t timestamp) {
    if (timestamp <= 0) return "Working tree";
    const auto time = static_cast<std::time_t>(timestamp);
    std::tm local{};
    if (localtime_s(&local, &time) != 0) return {};
    std::ostringstream output;
    output << std::put_time(&local, "%Y/%m/%d");
    return output.str();
}

bool isJavaPath(std::string_view path) {
    if (path.size() < 5) return false;
    constexpr std::string_view extension = ".java";
    const auto suffix = path.substr(path.size() - extension.size());
    return std::equal(suffix.begin(), suffix.end(), extension.begin(), extension.end(),
                      [](char left, char right) {
                          return std::tolower(static_cast<unsigned char>(left)) == right;
                      });
}

bool containsIgnoreCase(std::string value, std::string query) {
    const auto lower = [](std::string& text) {
        std::transform(text.begin(), text.end(), text.begin(), [](char character) {
            return static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        });
    };
    lower(value);
    lower(query);
    return value.find(query) != std::string::npos;
}

constexpr std::pair<std::string_view, std::string_view> kSimplifiedChineseText[] = {
    {"AI AND COMMIT", "AI 与提交"},
    {"AI Commit Message Settings", "AI 提交信息设置"},
    {"AI Commit Settings...", "AI 提交设置..."},
    {"AI message failed: ", "AI 信息生成失败："},
    {"AI commit message ready", "AI 提交信息已就绪"},
    {"Allow a short commit body", "允许简短的提交正文"},
    {"Allow insecure HTTP", "允许不安全的 HTTP"},
    {"Amend", "修订提交"},
    {"Anthropic Messages", "Anthropic Messages"},
    {"API key", "API 密钥"},
    {"API key header", "API 密钥请求头"},
    {"Apply", "应用"},
    {"Attach", "连接"},
    {"Attach to JDWP", "连接到 JDWP"},
    {"Attach to JDWP...", "连接到 JDWP..."},
    {"Authentication", "身份验证"},
    {"Automatic: ComSpec or cmd.exe", "自动：ComSpec 或 cmd.exe"},
    {"Bearer", "Bearer"},
    {"Branch name", "分支名称"},
    {"Branch, tag, or commit", "分支、标签或提交"},
    {"Branch", "分支"},
    {"New branch name", "新分支名称"},
    {"Next", "下一步"},
    {"Rename Git Branch", "重命名 Git 分支"},
    {"Delete Git Branch", "删除 Git 分支"},
    {"Rename", "重命名"},
    {"Commit and Push", "提交并推送"},
    {"Git will refuse if the branch contains work that has not been merged.",
     "如果分支包含尚未合并的工作，Git 将拒绝删除。"},
    {"Local changes would be overwritten", "本地修改将被覆盖"},
    {"Smart Checkout", "智能签出"},
    {"Force Checkout", "强制签出"},
    {"Discard local changes and switch branches?", "丢弃本地修改并切换分支？"},
    {"The listed local changes will be permanently discarded. This cannot be undone by Lithe.",
     "列出的本地修改将被永久丢弃，且无法通过 Lithe 撤销。"},
    {"Branch renamed", "分支已重命名"},
    {"Branch deleted", "分支已删除"},
    {"Push current branch?", "推送当前分支？"},
    {"This sends the current branch to its configured remote.", "这会将当前分支推送到已配置的远程仓库。"},
    {"Merge reference", "合并引用"},
    {"Rebase onto reference", "变基到引用"},
    {"Pull (Fast-forward only)", "拉取（仅快进）"},
    {"Pull...", "拉取..."},
    {"Pull strategy", "拉取策略"},
    {"Choose how divergent history should be integrated.", "请选择如何整合分叉的提交历史。"},
    {"Fast-forward only", "仅快进"},
    {"Checking Git operation state...", "正在检查 Git 操作状态..."},
    {"This file changed outside Lithe while you have unsaved edits.",
     "文件在 Lithe 外部发生了修改，但当前仍有未保存编辑。"},
    {"Keep Editor", "保留编辑器版本"},
    {"Load Disk Version", "加载磁盘版本"},
    {"Cherry-pick Selected Commit...", "拣选所选提交..."},
    {"Revert Selected Commit...", "还原所选提交..."},
    {"Reset to Revision...", "重置到修订..."},
    {"Cherry-pick selected commit?", "拣选所选提交？"},
    {"Revert selected commit?", "还原所选提交？"},
    {"Select a commit from Git History first", "请先在 Git 历史中选择一个提交"},
    {"Reset current branch", "重置当前分支"},
    {"Revision", "修订"},
    {"Reset mode", "重置模式"},
    {"Soft - keep index and files", "Soft - 保留暂存区和文件"},
    {"Mixed - reset index, keep files", "Mixed - 重置暂存区并保留文件"},
    {"Hard - discard index and file changes", "Hard - 丢弃暂存区和文件更改"},
    {"Hard reset permanently discards staged and working-tree changes.",
     "Hard 重置会永久丢弃暂存区和工作区更改。"},
    {"Hard reset and discard local changes?", "执行 Hard 重置并丢弃本地更改？"},
    {"Reset Hard", "Hard 重置"},
    {"Build", "构建"},
    {"Call Stack", "调用栈"},
    {"Cancel", "取消"},
    {"Check for Updates", "检查更新"},
    {"Check for updates", "检查更新"},
    {"Changes", "更改"},
    {"CHANGES", "更改"},
    {"Clear", "清空"},
    {"Clean", "清理"},
    {"Clone", "克隆"},
    {"Clone Repository", "克隆仓库"},
    {"Clone Repository...", "克隆仓库..."},
    {"Close", "关闭"},
    {"Close Project", "关闭项目"},
    {"Close find", "关闭查找"},
    {"Closing Lithe to install the update", "正在关闭 Lithe 以安装更新"},
    {"COMMIT", "提交"},
    {"Commit", "提交"},
    {"Commit Changes", "提交更改"},
    {"Commit format", "提交格式"},
    {"Commit message", "提交信息"},
    {"Command Palette", "命令面板"},
    {"Command Palette...", "命令面板..."},
    {"Compare", "比较"},
    {"Compare Git Reference", "比较 Git 引用"},
    {"Compare Reference...", "比较引用..."},
    {"Concise", "简洁"},
    {"Continue", "继续"},
    {"Conventional", "约定式"},
    {"Configure AI commit messages...", "配置 AI 提交信息..."},
    {"Could not launch the Windows update helper", "无法启动 Windows 更新助手"},
    {"Could not locate the Windows update helper", "无法找到 Windows 更新助手"},
    {"Could not save AI settings: ", "无法保存 AI 设置："},
    {"Copied path", "路径已复制"},
    {"Copy Absolute Path", "复制绝对路径"},
    {"Copy Relative Path", "复制相对路径"},
    {"Create", "创建"},
    {"Create and switch", "创建并切换"},
    {"Create Git Branch", "创建 Git 分支"},
    {"Create Git Branch...", "创建 Git 分支..."},
    {"Create Git Stash", "创建 Git Stash"},
    {"Create Shelf", "创建 Shelf"},
    {"Create Stash...", "创建 Stash..."},
    {"Custom", "自定义"},
    {"Custom instructions", "自定义指令"},
    {"Data directory", "数据目录"},
    {"Debug", "调试"},
    {"Debugger", "调试器"},
    {"Debug Current Java File", "调试当前 Java 文件"},
    {"Debug Spring Boot", "调试 Spring Boot"},
    {"Delete", "删除"},
    {"Delete selected Shelf?", "删除选中的 Shelf？"},
    {"Descriptive", "描述式"},
    {"Diff", "差异"},
    {"Discard", "丢弃"},
    {"Discard hunk", "丢弃代码块"},
    {"Discard selected changes?", "丢弃所选更改？"},
    {"Discard selected hunk?", "丢弃所选代码块？"},
    {"Show blocked paths only", "仅显示阻塞路径"},
    {"Roll back blocked file", "回滚阻塞文件"},
    {"Roll back blocked file to HEAD?", "将阻塞文件回滚到 HEAD？"},
    {"Roll Back", "回滚"},
    {"Select one blocked path to roll back", "请选择一个要回滚的阻塞路径"},
    {"The selected path is not blocking a Git operation", "所选路径没有阻塞 Git 操作"},
    {"Could not roll back blocked path", "无法回滚阻塞路径"},
    {"Blocked path rolled back", "阻塞路径已回滚"},
    {"Staged and working-tree changes for this file will be discarded. The operation will be checked again before retrying.",
     "此文件的暂存区和工作区更改将被丢弃；重试前会再次检查整个操作。"},
    {"Don't save", "不保存"},
    {"Download", "下载"},
    {"Drop", "丢弃"},
    {"Drop selected stash?", "丢弃所选 Stash？"},
    {"Duplicate", "复制"},
    {"Duplicate...", "复制..."},
    {"Duplicate Workspace Item", "复制工作区项目"},
    {"EDITOR", "编辑器"},
    {"Editor font size", "编辑器字号"},
    {"Editor", "编辑器"},
    {"Preview", "预览"},
    {"Replace in Project", "在项目中替换"},
    {"Replace in Project...", "在项目中替换..."},
    {"Replace with", "替换为"},
    {"Match Case", "区分大小写"},
    {"Whole Words", "全词匹配"},
    {"Preserve Case", "保留大小写形式"},
    {"File mask", "文件掩码"},
    {"Replacement Preview", "替换预览"},
    {"Regex", "正则表达式"},
    {"Apply Selected", "应用所选"},
    {"Project Replace Incomplete", "项目替换未全部完成"},
    {"English", "英文"},
    {"Enter terminal command", "输入终端命令"},
    {"Enter a commit message", "请输入提交信息"},
    {"Endpoint", "端点"},
    {"Evaluate expression", "计算表达式"},
    {"EVIDENCE AND MODULES", "检测证据和模块"},
    {"File", "文件"},
    {"Find in File", "在文件中查找"},
    {"Find in file", "在文件中查找"},
    {"Find Java Usages", "查找 Java 用法"},
    {"Find Next", "查找下一个"},
    {"Find Previous", "查找上一个"},
    {"Files, symbols, and text", "文件、符号和文本"},
    {"Folder name", "文件夹名称"},
    {"GENERAL", "通用"},
    {"Generate AI Commit Message", "生成 AI 提交信息"},
    {"Generate AI commit message", "生成 AI 提交信息"},
    {"Git", "Git"},
    {"Git History", "Git 历史"},
    {"Git blame hidden", "Git Blame 已隐藏"},
    {"Git Shelves", "Git Shelf"},
    {"Git Stashes", "Git Stash"},
    {"Go to Java Definition", "跳转到 Java 定义"},
    {"Hidden directories (comma-separated)", "隐藏目录（逗号分隔）"},
    {"Hidden file patterns (comma-separated)", "隐藏文件模式（逗号分隔）"},
    {"History", "历史"},
    {"Host", "主机"},
    {"Imperative", "祈使式"},
    {"Include untracked files", "包含未跟踪文件"},
    {"Install", "安装"},
    {"Install now", "立即安装"},
    {"Installer ready", "安装程序已准备好"},
    {"Inspecting project...", "正在检测项目..."},
    {"Interface language", "界面语言"},
    {"Interrupt", "中断"},
    {"Later", "稍后"},
    {"JDT ready", "JDT 已就绪"},
    {"JDT starting", "JDT 正在启动"},
    {"Load Git history before switching references", "切换引用前请先加载 Git 历史"},
    {"Leave blank to keep the stored key", "留空以保留已存储的密钥"},
    {"Leave empty for the system default", "留空使用系统默认位置"},
    {"Local History", "本地历史"},
    {"Restore Snapshot", "恢复快照"},
    {"Restore Local History snapshot?", "恢复本地历史快照？"},
    {"The selected snapshot will replace the current editor content and be saved to disk.",
     "所选快照将替换当前编辑器内容并保存到磁盘。"},
    {"Restore", "恢复"},
    {"Select a Local History snapshot first", "请先选择一个本地历史快照"},
    {"Select a snapshot for the active file", "请选择当前文件的快照"},
    {"Open a workspace file before restoring history", "恢复历史前请先打开工作区文件"},
    {"Local History snapshot compared with the current editor", "本地历史快照已与当前编辑器比较"},
    {"Loading Git blame...", "正在加载 Git Blame..."},
    {"Loading workspace...", "正在加载工作区..."},
    {"Ln 1, Col 1", "行 1，列 1"},
    {"Match case", "区分大小写"},
    {"Maximum diff characters", "最大差异字符数"},
    {"Maximum subject length", "主题最大长度"},
    {"Maven Clean", "Maven 清理"},
    {"Maven", "Maven"},
    {"Maven Install", "Maven 安装"},
    {"Maven Package", "Maven 打包"},
    {"Maven Test", "Maven 测试"},
    {"Maven Verify", "Maven 验证"},
    {"Message", "信息"},
    {"Message language", "信息语言"},
    {"Missing", "缺失"},
    {"Mixed project", "混合项目"},
    {"Model", "模型"},
    {"Modified", "已修改"},
    {"Name", "名称"},
    {"Navigate", "导航"},
    {"New Branch...", "新建分支..."},
    {"Rename Branch...", "重命名分支..."},
    {"Delete Branch...", "删除分支..."},
    {"New Directory", "新建目录"},
    {"New Directory...", "新建目录..."},
    {"New File", "新建文件"},
    {"New File...", "新建文件..."},
    {"No matches", "无匹配项"},
    {"No AI commit-message provider configured.", "尚未配置 AI 提交信息提供方。"},
    {"No matching projects", "没有匹配的项目"},
    {"No recent projects", "没有最近项目"},
    {"No workspace open", "未打开工作区"},
    {" (missing)", "（路径不存在）"},
    {"NEW", "新版本"},
    {"OLD", "旧版本"},
    {"Open", "打开"},
    {"Open a Markdown file to preview it", "请先打开 Markdown 文件再预览"},
    {"Open a file before saving", "请先打开文件再保存"},
    {"Open a file to start editing", "打开文件以开始编辑"},
    {"Open a recent project, choose a folder, or clone a repository.",
     "打开最近项目、选择文件夹或克隆仓库。"},
    {"Open a workspace file before showing Git blame", "请先打开工作区文件再显示 Git Blame"},
    {"Open a workspace first", "请先打开工作区"},
    {"Open folder...", "打开文件夹..."},
    {"Open Project", "打开项目"},
    {"Open Project...", "打开项目..."},
    {"Open project", "打开项目"},
    {"Open selected", "打开所选项目"},
    {"Open Terminal", "打开终端"},
    {"Open terminal", "打开终端"},
    {"Opened read-only library source", "已打开只读库源码"},
    {"Original", "原始版本"},
    {"Parent folder", "父文件夹"},
    {"Package", "打包"},
    {"Pause", "暂停"},
    {"Pop", "弹出"},
    {"Port", "端口"},
    {"Plain Java", "普通 Java"},
    {"Preview Markdown", "预览 Markdown"},
    {"Previous match", "上一个匹配项"},
    {"Refresh Git", "刷新 Git"},
    {"Next match", "下一个匹配项"},
    {"Problems", "问题"},
    {"Provider", "提供方"},
    {"Project", "项目"},
    {"PROJECT", "项目"},
    {"Project kind", "项目类型"},
    {"Project open cancelled", "已取消打开项目"},
    {"Protocol", "协议"},
    {"Ready", "就绪"},
    {"Read only", "只读"},
    {"Reasoning effort", "推理强度"},
    {"Refresh", "刷新"},
    {"Refresh Changes", "刷新更改"},
    {"Refresh changes", "刷新更改"},
    {"Refresh Project", "刷新项目"},
    {"Refresh project", "刷新项目"},
    {"Release note", "发布说明"},
    {"Remove recent", "从最近项目中移除"},
    {"Rename", "重命名"},
    {"Rename...", "重命名..."},
    {"Rename Workspace Item", "重命名工作区项目"},
    {"Repository URL", "仓库地址"},
    {"Restart", "重新启动"},
    {"Restart Lithe to apply the interface language or data directory.",
     "重启 Lithe 后应用界面语言或数据目录。"},
    {"Restore", "恢复"},
    {"RESULTS", "结果"},
    {"Run", "运行"},
    {"Run configuration", "运行配置"},
    {"Run Current Java File", "运行当前 Java 文件"},
    {"Run current Java file", "运行当前 Java 文件"},
    {"Run Maven Test", "运行 Maven 测试"},
    {"Run Spring Boot", "运行 Spring Boot"},
    {"Save", "保存"},
    {"Save All", "全部保存"},
    {"Save Document", "保存文档"},
    {"Saved", "已保存"},
    {"Search", "搜索"},
    {"Search Everywhere", "全局搜索"},
    {"Search Everywhere...", "全局搜索..."},
    {"Search recent projects", "搜索最近项目"},
    {"Search Workspace", "搜索工作区"},
    {"Search workspace", "搜索工作区"},
    {"Select a Shelf first", "请先选择一个 Shelf"},
    {"Select a detected Java debug configuration", "请选择检测到的 Java 调试配置"},
    {"Select a detected Java run configuration", "请选择检测到的 Java 运行配置"},
    {"Select a diff hunk first", "请先选择一个差异代码块"},
    {"Select a stash first", "请先选择一个 Stash"},
    {"Select a workspace item to delete", "请选择要删除的工作区项目"},
    {"Select a workspace item to duplicate", "请选择要复制的工作区项目"},
    {"Select a workspace item to rename", "请选择要重命名的工作区项目"},
    {"Select one or more changes to discard", "请选择一个或多个要丢弃的更改"},
    {"Select one or more changes to stage", "请选择一个或多个要暂存的更改"},
    {"Select one or more changes to unstage", "请选择一个或多个要取消暂存的更改"},
    {"Settings", "设置"},
    {"Settings...", "设置..."},
    {"Shelf name", "Shelf 名称"},
    {"Shelves", "Shelf"},
    {"Show code vision and implementation markers", "显示代码视图和实现标记"},
    {"Show in Explorer", "在资源管理器中显示"},
    {"Show Java inlay hints", "显示 Java 内嵌提示"},
    {"Show Workspace in Explorer", "在资源管理器中显示工作区"},
    {"Simplified Chinese", "简体中文"},
    {"Stage", "暂存"},
    {"Stage all", "暂存全部"},
    {"Stage All", "暂存全部"},
    {"Stage All Changes", "暂存全部更改"},
    {"Stage hunk", "暂存代码块"},
    {"Start", "启动"},
    {"Stash", "保存 Stash"},
    {"Stashes", "Stash"},
    {"Step Into", "单步进入"},
    {"Step Out", "单步跳出"},
    {"Step Over", "单步跳过"},
    {"Stop", "停止"},
    {"Stop Build", "停止构建"},
    {"Stop Debugger", "停止调试器"},
    {"Stop Java", "停止 Java"},
    {"Stop Terminal", "停止终端"},
    {"Starting", "启动中"},
    {"Exited", "已退出"},
    {"Switch", "切换"},
    {"Switch Branch...", "切换分支..."},
    {"Switch Git Branch", "切换 Git 分支"},
    {"Switch Git Reference", "切换 Git 引用"},
    {"System default", "系统默认"},
    {"The selected folder is no longer available", "所选文件夹已不可用"},
    {"The SHA-256 and Authenticode verified installer is ready. Launch it now?",
     "SHA-256 与 Authenticode 验证通过的安装程序已准备好。现在启动吗？"},
    {"Test", "测试"},
    {"Terminal", "终端"},
    {"Running", "运行中"},
    {"Stopped", "已停止"},
    {"New Terminal", "新建终端"},
    {"Close Terminal", "关闭终端"},
    {"Markdown preview shown beside the editor", "Markdown 预览已显示在编辑器旁"},
    {"Terminal shell executable", "终端 Shell 可执行文件"},
    {"Shell executable", "Shell 可执行文件"},
    {"The saved patches will be permanently removed.", "保存的补丁将被永久删除。"},
    {"The stash entry will be permanently removed.", "该 Stash 条目将被永久删除。"},
    {"This operation cannot be undone by Lithe.", "此操作无法由 Lithe 撤销。"},
    {"Threads", "线程"},
    {"Toggle Blame", "切换 Blame"},
    {"Toggle Breakpoint", "切换断点"},
    {"Toggle Tool Window", "切换工具窗口"},
    {"Toggle tool window", "切换工具窗口"},
    {"Tools", "工具"},
    {"Type a command", "输入命令"},
    {"Unstage", "取消暂存"},
    {"Unstage hunk", "取消暂存代码块"},
    {"Unknown", "未知"},
    {"Unsaved changes will be lost if they are not saved.", "未保存的更改将会丢失。"},
    {"Variables", "变量"},
    {"Verified installer downloaded", "已下载并验证安装程序"},
    {"Verify", "验证"},
    {"Welcome / Switch Workspace", "欢迎页 / 切换工作区"},
    {"Welcome to Lithe", "欢迎使用 Lithe"},
    {"Search projects", "搜索项目"},
    {"Projects", "项目"},
    {"Check for Updates", "重试更新检查"},
    {"Windows", "Windows"},
    {"Open a local folder to start working.", "打开本地文件夹以开始工作。"},
    {"Windows releases are downloaded only after SHA-256 and Authenticode verification.",
     "Windows 版本仅在 SHA-256 与 Authenticode 验证通过后下载。"},
    {"Windows installer", "Windows 安装程序"},
    {"Windows update available", "有可用的 Windows 更新"},
    {"Update check failed: ", "更新检查失败："},
    {"Update download failed: ", "更新下载失败："},
    {"Workspace loaded with ", "工作区已加载，共 "},
    {"Stash restore has ", "Stash 恢复存在 "},
    {"Working tree snapshot", "工作区快照"},
    {"WORKSPACE", "工作区"},
    {"Workspace", "工作区"},
    {"UPDATES", "更新"},
    {"failed", "失败"},
    {"finished", "已结束"},
    {"idle", "空闲"},
    {"launching", "正在启动"},
    {"paused", "已暂停"},
    {"running", "正在运行"},
    {"AI commit generation is already running", "AI 提交信息正在生成"},
    {"AI commit settings saved", "AI 提交设置已保存"},
    {"An update operation is already running", "更新操作正在进行"},
    {"Build finished with exit code ", "构建已结束，退出码为 "},
    {"Build is running", "构建正在运行"},
    {"Checking for Windows updates...", "正在检查 Windows 更新..."},
    {"Checkout blocked by ", "检出被以下路径阻止："},
    {"Could not create item: ", "无法创建项目："},
    {"Could not delete item: ", "无法删除项目："},
    {"Could not duplicate item: ", "无法复制项目："},
    {"Could not rename item: ", "无法重命名项目："},
    {"Could not save settings: ", "无法保存设置："},
    {"Could not save workbench layout: ", "无法保存工作台布局："},
    {"Could not save workspace session: ", "无法保存工作区会话："},
    {"Could not update recent projects: ", "无法更新最近项目："},
    {"Created ", "已创建 "},
    {"Created branch ", "已创建分支 "},
    {"Deleted ", "已删除 "},
    {"Destination already exists", "目标已存在"},
    {"Downloading and verifying Windows installer...", "正在下载并验证 Windows 安装程序..."},
    {"Duplicated as ", "已复制为 "},
    {"Generating commit message...", "正在生成提交信息..."},
    {"Invalid workspace item name", "工作区项目名称无效"},
    {"Invalid workspace path", "工作区路径无效"},
    {"Java finished with exit code ", "Java 已结束，退出码为 "},
    {"Java is running", "Java 正在运行"},
    {"Java language server unavailable: ", "Java 语言服务器不可用："},
    {"Java run could not start", "无法启动 Java 运行"},
    {"Loading staged changes for AI commit generation", "正在读取已暂存更改以生成提交信息"},
    {"No Git changes to shelve", "没有可创建 Shelf 的 Git 更改"},
    {"No Java process is running", "没有正在运行的 Java 进程"},
    {"No Spring Boot run configuration was detected", "未检测到 Spring Boot 运行配置"},
    {"Open a Java file before adding a breakpoint", "请先打开 Java 文件再添加断点"},
    {"Open a Java file before debugging it", "请先打开 Java 文件再调试"},
    {"Open a Java file before running it", "请先打开 Java 文件再运行"},
    {"Open a workspace before generating a commit message", "请先打开工作区再生成提交信息"},
    {"Open a workspace before running Java", "请先打开工作区再运行 Java"},
    {"Recent project removed", "已从最近项目中移除"},
    {"Refresh Git status before generating a message", "生成提交信息前请先刷新 Git 状态"},
    {"Renamed to ", "已重命名为 "},
    {"Repository URL and a valid folder name are required", "必须填写仓库地址和有效的文件夹名称"},
    {"Rust Core ", "Rust 核心 "},
    {"Settings saved", "设置已保存"},
    {"Shelf created", "Shelf 已创建"},
    {"Shelf deleted", "Shelf 已删除"},
    {"Shelf restored", "Shelf 已恢复"},
    {"Starting Java", "正在启动 Java"},
    {"Starting build", "正在启动构建"},
    {"Stopping Java", "正在停止 Java"},
    {"Stopping build", "正在停止构建"},
    {"Terminal exited", "终端已退出"},
    {"Terminal started", "终端已启动"},
    {"The clone destination already exists", "克隆目标已存在"},
    {"The clone parent folder is unavailable", "克隆父文件夹不可用"},
    {"The selected Java debug configuration is unavailable", "所选 Java 调试配置不可用"},
    {"The selected Java file is outside the workspace", "所选 Java 文件不在工作区内"},
    {"The selected Java run configuration is unavailable", "所选 Java 运行配置不可用"},
    {"The selected diff hunk is no longer available", "所选差异代码块已不可用"},
    {"The selected workspace is unavailable", "所选工作区不可用"},
    {"The workspace root cannot be deleted", "不能删除工作区根目录"},
    {"There are no staged changes", "没有已暂存的更改"},
    {"Use Debug Current Java File for a current-file configuration", "当前文件配置请使用“调试当前 Java 文件”"},
    {"Commit diff request failed", "提交差异请求失败"},
    {"Commit failed", "提交失败"},
    {"Could not apply diff hunk", "无法应用差异代码块"},
    {"Could not apply stash", "无法应用 Stash"},
    {"Could not create Shelf", "无法创建 Shelf"},
    {"Could not create branch", "无法创建分支"},
    {"Could not create stash", "无法创建 Stash"},
    {"Could not delete Shelf", "无法删除 Shelf"},
    {"Could not drop stash", "无法丢弃 Stash"},
    {"Could not load Git blame", "无法加载 Git Blame"},
    {"Could not pop stash", "无法弹出 Stash"},
    {"Could not read Shelf", "无法读取 Shelf"},
    {"Could not restore Shelf index", "无法恢复 Shelf 暂存区"},
    {"Could not restore Shelf working tree", "无法恢复 Shelf 工作区"},
    {"Could not switch Git reference", "无法切换 Git 引用"},
    {"Diff request failed", "差异请求失败"},
    {"File request failed", "文件请求失败"},
    {"File save failed", "文件保存失败"},
    {"Git commit request failed", "Git 提交请求失败"},
    {"Git comparison failed", "Git 比较失败"},
    {"Git history failed", "Git 历史加载失败"},
    {"Git stashes failed", "Git Stash 加载失败"},
    {"Git status failed", "Git 状态加载失败"},
    {"Java code vision failed", "Java 代码视图加载失败"},
    {"Java structure analysis failed", "Java 结构分析失败"},
    {"Local History content failed", "本地历史内容加载失败"},
    {"Local History failed", "本地历史加载失败"},
    {"Maven could not start", "无法启动 Maven"},
    {"Project analysis failed", "项目分析失败"},
    {"Repository clone failed", "仓库克隆失败"},
    {"Search Everywhere failed", "全局搜索失败"},
    {"Search failed", "搜索失败"},
    {"Shelf patch request failed", "Shelf 补丁请求失败"},
    {"Shelf request failed", "Shelf 请求失败"},
    {"Workspace refresh failed", "工作区刷新失败"},
    {"Workspace request failed", "工作区请求失败"},
};

std::string localizedText(std::string_view source, bool simplifiedChinese) {
    if (!simplifiedChinese) return std::string(source);
    const auto found = std::find_if(std::begin(kSimplifiedChineseText),
                                    std::end(kSimplifiedChineseText),
                                    [source](const auto& entry) {
                                        return entry.first == source;
                                    });
    if (found != std::end(kSimplifiedChineseText)) return std::string(found->second);
    const std::pair<std::string_view, std::string_view>* prefix = nullptr;
    for (const auto& entry : kSimplifiedChineseText) {
        if (entry.first.empty() || entry.first.back() != ' ' ||
            !source.starts_with(entry.first)) continue;
        if (prefix == nullptr || entry.first.size() > prefix->first.size()) {
            prefix = &entry;
        }
    }
    if (prefix == nullptr) return std::string(source);
    return std::string(prefix->second) + std::string(source.substr(prefix->first.size()));
}

std::string projectKindLabel(lithe::windows::app::ProjectKind kind) {
    using lithe::windows::app::ProjectKind;
    switch (kind) {
    case ProjectKind::Maven: return "Maven";
    case ProjectKind::Gradle: return "Gradle";
    case ProjectKind::Eclipse: return "Eclipse";
    case ProjectKind::IntelliJ: return "IntelliJ";
    case ProjectKind::PlainJava: return "Plain Java";
    case ProjectKind::Mixed: return "Mixed project";
    case ProjectKind::Unknown: return "Unknown";
    }
    return "Unknown";
}

std::string readinessLabel(bool ready) {
    return ready ? "Ready" : "Missing";
}

std::string countLabel(std::size_t count,
                       std::string_view englishNoun,
                       std::string_view chineseNoun,
                       bool simplifiedChinese) {
    const auto value = std::to_string(count);
    return simplifiedChinese ? value + " 个" + std::string(chineseNoun)
                             : value + " " + std::string(englishNoun);
}

} // namespace

MainWindow::MainWindow() {
    InitializeComponent();
    dispatcher_ = Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread();
    configureWindow();
    configureSession();
    configureTimers();
    Closed([this](IInspectable const&, WindowEventArgs const&) { saveWorkbenchState(); });
    const auto recent = session_->recentProjects();
    const bool hasAvailableRecent = std::any_of(
        recent.begin(), recent.end(), [](const std::string& value) {
            std::error_code error;
            return std::filesystem::is_directory(pathFromUtf8(value), error);
        });
    session_->openMostRecentWorkspace();
    showWelcomeOnLoad_ = !hasAvailableRecent;
}

MainWindow::~MainWindow() {
    if (debugPollTimer_) {
        debugPollTimer_.Stop();
        if (debugPollToken_.value != 0) debugPollTimer_.Tick(debugPollToken_);
    }
    if (workbenchSaveTimer_) {
        workbenchSaveTimer_.Stop();
        if (workbenchSaveToken_.value != 0) workbenchSaveTimer_.Tick(workbenchSaveToken_);
    }
    if (markdownPreviewTimer_) {
        markdownPreviewTimer_.Stop();
        if (markdownPreviewToken_.value != 0) {
            markdownPreviewTimer_.Tick(markdownPreviewToken_);
        }
    }
    if (editorScrollViewer_ && editorScrollToken_.value != 0) {
        editorScrollViewer_.ViewChanged(editorScrollToken_);
    }
}

HWND MainWindow::windowHandle() {
    if (hwnd_ == nullptr) {
        const auto window = get_strong().as<IWindowNative>();
        check_hresult(window->get_WindowHandle(&hwnd_));
    }
    return hwnd_;
}

void MainWindow::configureWindow() {
    Title(L"Lithe");
    const auto hwnd = windowHandle();
    const auto dpi = GetDpiForWindow(hwnd);
    const auto scale = static_cast<double>(dpi) / 96.0;
    SetWindowPos(hwnd, nullptr, 0, 0,
                 static_cast<int>(1440 * scale), static_cast<int>(900 * scale),
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);

    const auto iconPath = std::filesystem::current_path() / L"Assets" / L"lithe.ico";
    const auto icon = LoadImageW(nullptr, iconPath.c_str(), IMAGE_ICON,
                                GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON),
                                LR_LOADFROMFILE | LR_SHARED);
    if (icon != nullptr) {
        SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
        SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
    }
}

void MainWindow::configureSession() {
    const auto weak = get_weak();
    const auto dispatcher = dispatcher_;
    lithe::windows::winui::WorkbenchCallbacks callbacks;
    callbacks.workspaceChanged = [weak, dispatcher](
        lithe::windows::app::WorkspaceFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderWorkspace(std::move(state));
        });
    };
    callbacks.filesChanged = [weak, dispatcher](
        std::vector<lithe::windows::DirectoryChangeSource::Change> changes) mutable {
        dispatcher.TryEnqueue([weak, changes = std::move(changes)]() mutable {
            if (const auto self = weak.get()) self->handleDirectoryChanges(std::move(changes));
        });
    };
    callbacks.documentChanged = [weak, dispatcher](
        lithe::windows::app::DocumentFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderDocument(std::move(state));
        });
    };
    callbacks.searchChanged = [weak, dispatcher](
        lithe::windows::app::SearchFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderSearch(std::move(state));
        });
    };
    callbacks.searchEverywhereChanged = [weak, dispatcher](
        lithe::windows::app::SearchEverywhereFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderSearchEverywhere(std::move(state));
        });
    };
    callbacks.replacementChanged = [weak, dispatcher](
        lithe::windows::app::ReplacementFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) {
                self->showProjectReplacementPreview(std::move(state));
            }
        });
    };
    callbacks.replacementApplied = [weak, dispatcher](
        lithe::windows::winui::ProjectReplacementApplyResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) {
                self->renderProjectReplacementApplied(std::move(result));
            }
        });
    };
    callbacks.markdownRendered = [weak, dispatcher](
        lithe::windows::winui::MarkdownRenderResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) {
                self->renderMarkdownHTML(std::move(result));
            }
        });
    };
    callbacks.gitChanged = [weak, dispatcher](
        lithe::windows::app::GitFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderGit(std::move(state));
        });
    };
    callbacks.checkoutBlocked = [weak, dispatcher](
        lithe::windows::app::GitPendingCheckout pending,
        std::vector<std::string> blockingPaths) mutable {
        dispatcher.TryEnqueue(
            [weak, pending = std::move(pending),
             blockingPaths = std::move(blockingPaths)]() mutable {
                if (const auto self = weak.get()) {
                    self->showCheckoutConflict(std::move(pending),
                                               std::move(blockingPaths));
                }
            });
    };
    callbacks.integrationBlocked = [weak, dispatcher](
        lithe::windows::app::GitPendingIntegration pending,
        std::vector<std::string> blockingPaths,
        bool blocksEntirely) mutable {
        dispatcher.TryEnqueue(
            [weak, pending = std::move(pending),
             blockingPaths = std::move(blockingPaths), blocksEntirely]() mutable {
                if (const auto self = weak.get()) {
                    self->showIntegrationConflict(
                        std::move(pending), std::move(blockingPaths), blocksEntirely);
                }
            });
    };
    callbacks.historyChanged = [weak, dispatcher](
        lithe::windows::app::HistoryFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderHistory(std::move(state));
        });
    };
    callbacks.shelfChanged = [weak, dispatcher](
        lithe::windows::app::ShelfFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderShelves(std::move(state));
        });
    };
    callbacks.analysisChanged = [weak, dispatcher](
        lithe::windows::app::MavenJavaFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderAnalysis(std::move(state));
        });
    };
    callbacks.terminalOutputChanged = [weak, dispatcher](std::string id) mutable {
        dispatcher.TryEnqueue([weak, id = std::move(id)]() mutable {
            if (const auto self = weak.get()) self->renderTerminalOutput(std::move(id));
        });
    };
    callbacks.terminalsChanged = [weak, dispatcher](
        lithe::windows::app::TerminalFeatureState state) mutable {
        dispatcher.TryEnqueue([weak, state = std::move(state)]() mutable {
            if (const auto self = weak.get()) self->renderTerminals(std::move(state));
        });
    };
    callbacks.buildOutput = [weak, dispatcher](std::string output) mutable {
        dispatcher.TryEnqueue([weak, output = std::move(output)]() mutable {
            if (const auto self = weak.get()) self->appendBuildOutput(std::move(output));
        });
    };
    callbacks.javaDebugChanged = [weak, dispatcher](
        lithe::windows::app::JavaDebugSnapshot snapshot) mutable {
        dispatcher.TryEnqueue([weak, snapshot = std::move(snapshot)]() mutable {
            if (const auto self = weak.get()) self->renderJavaDebug(std::move(snapshot));
        });
    };
    callbacks.languageServerChanged = [weak, dispatcher](
        bool ready, std::string message) mutable {
        dispatcher.TryEnqueue([weak, ready, message = std::move(message)]() mutable {
            if (const auto self = weak.get()) {
                self->renderLanguageServerState(ready, std::move(message));
            }
        });
    };
    callbacks.javaDiagnosticsChanged = [weak, dispatcher](
        lithe::windows::winui::JavaDiagnosticsResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) self->renderJavaDiagnostics(std::move(result));
        });
    };
    callbacks.javaNavigationChanged = [weak, dispatcher](
        lithe::windows::winui::JavaNavigationResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) self->renderJavaNavigation(std::move(result));
        });
    };
    callbacks.aiCommitFinished = [weak, dispatcher](
        lithe::windows::winui::AICommitGenerationResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) self->renderAICommitResult(std::move(result));
        });
    };
    callbacks.updateCheckFinished = [weak, dispatcher](
        lithe::windows::winui::WindowsUpdateCheckResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) self->renderUpdateCheck(std::move(result));
        });
    };
    callbacks.updateDownloadFinished = [weak, dispatcher](
        lithe::windows::winui::WindowsUpdateDownloadResult result) mutable {
        dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (const auto self = weak.get()) self->renderUpdateDownload(std::move(result));
        });
    };
    callbacks.statusChanged = [weak, dispatcher](std::string status) mutable {
        dispatcher.TryEnqueue([weak, status = std::move(status)]() mutable {
            if (const auto self = weak.get()) self->setStatus(std::move(status));
        });
    };
    session_ = std::make_unique<lithe::windows::winui::WorkbenchSession>(std::move(callbacks));
    EditorTextBox().FontSize(session_->settings().editorFontSize);
    LineNumbersText().FontSize(session_->settings().editorFontSize);
    GutterAnnotationsText().FontSize(session_->settings().editorFontSize);
    applyUiTranslations();
    MarkdownEditorModeButton().Content(box_value(ui("Editor")));
    MarkdownPreviewModeButton().Content(box_value(ui("Preview")));
    ExternalConflictKeepButton().Content(box_value(ui("Keep Editor")));
    ExternalConflictLoadButton().Content(box_value(ui("Load Disk Version")));
}

hstring MainWindow::ui(std::string_view source) const {
    return text(localizedText(source, simplifiedChinese_));
}

void MainWindow::applyUiTranslations() {
    const bool systemLocaleIsChinese =
        PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
    simplifiedChinese_ = lithe::windows::app::effectiveUiLanguage(
        session_->settings().uiLanguage, systemLocaleIsChinese) == "zh_CN";
    if (simplifiedChinese_) translateElement(RootGrid());
}

void MainWindow::translateElement(DependencyObject const& element) {
    if (!element || !simplifiedChinese_) return;

    const auto translateString = [this](hstring const& value) {
        return ui(utf8(value));
    };
    const auto translatedBox = [this](IInspectable const& value) -> IInspectable {
        if (!value) return value;
        const auto property = value.try_as<Windows::Foundation::IPropertyValue>();
        if (!property || property.Type() != Windows::Foundation::PropertyType::String) {
            return value;
        }
        return box_value(ui(utf8(property.GetString())));
    };

    if (const auto dialog = element.try_as<ContentDialog>()) {
        dialog.Title(translatedBox(dialog.Title()));
        dialog.PrimaryButtonText(translateString(dialog.PrimaryButtonText()));
        dialog.SecondaryButtonText(translateString(dialog.SecondaryButtonText()));
        dialog.CloseButtonText(translateString(dialog.CloseButtonText()));
    }
    if (const auto block = element.try_as<TextBlock>()) {
        block.Text(translateString(block.Text()));
    }
    if (const auto box = element.try_as<TextBox>()) {
        box.Header(translatedBox(box.Header()));
        box.PlaceholderText(translateString(box.PlaceholderText()));
    }
    if (const auto box = element.try_as<PasswordBox>()) {
        box.PlaceholderText(translateString(box.PlaceholderText()));
    }
    if (const auto box = element.try_as<NumberBox>()) {
        box.Header(translatedBox(box.Header()));
    }
    if (const auto box = element.try_as<ComboBox>()) {
        box.PlaceholderText(translateString(box.PlaceholderText()));
    }
    if (const auto toggle = element.try_as<ToggleSwitch>()) {
        toggle.Header(translatedBox(toggle.Header()));
    }
    if (const auto tab = element.try_as<TabViewItem>()) {
        tab.Header(translatedBox(tab.Header()));
    }
    if (const auto button = element.try_as<AppBarButton>()) {
        button.Label(translateString(button.Label()));
    }
    if (const auto item = element.try_as<MenuFlyoutItem>()) {
        item.Text(translateString(item.Text()));
    }
    if (const auto item = element.try_as<MenuFlyoutSubItem>()) {
        item.Text(translateString(item.Text()));
        for (const auto& child : item.Items()) {
            if (const auto dependency = child.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
    }
    if (const auto item = element.try_as<MenuBarItem>()) {
        item.Title(translateString(item.Title()));
        for (const auto& child : item.Items()) {
            if (const auto dependency = child.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
    }
    if (const auto menu = element.try_as<MenuBar>()) {
        for (const auto& item : menu.Items()) {
            if (const auto dependency = item.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
    }
    if (const auto flyout = element.try_as<MenuFlyout>()) {
        for (const auto& item : flyout.Items()) {
            if (const auto dependency = item.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
    }
    if (const auto commandBar = element.try_as<CommandBar>()) {
        for (const auto& command : commandBar.PrimaryCommands()) {
            if (const auto dependency = command.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
        for (const auto& command : commandBar.SecondaryCommands()) {
            if (const auto dependency = command.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
    }
    if (const auto tabs = element.try_as<TabView>()) {
        for (const auto& item : tabs.TabItems()) {
            if (const auto dependency = item.try_as<DependencyObject>()) {
                translateElement(dependency);
            }
        }
    }

    if (const auto framework = element.try_as<FrameworkElement>()) {
        const auto toolTip = ToolTipService::GetToolTip(framework);
        if (const auto property = toolTip.try_as<Windows::Foundation::IPropertyValue>();
            property && property.Type() == Windows::Foundation::PropertyType::String) {
            ToolTipService::SetToolTip(framework, box_value(translateString(property.GetString())));
        } else if (const auto dependency = toolTip.try_as<DependencyObject>()) {
            translateElement(dependency);
        }
        if (const auto contextMenu = framework.ContextFlyout().try_as<MenuFlyout>()) {
            translateElement(contextMenu);
        }
    }
    if (const auto panel = element.try_as<Panel>()) {
        for (const auto& child : panel.Children()) translateElement(child);
    }
    if (const auto items = element.try_as<ItemsControl>()) {
        for (std::uint32_t index = 0; index < items.Items().Size(); ++index) {
            const auto item = items.Items().GetAt(index);
            if (const auto dependency = item.try_as<DependencyObject>()) {
                translateElement(dependency);
            } else {
                items.Items().SetAt(index, translatedBox(item));
            }
        }
    }
    if (const auto content = element.try_as<ContentControl>()) {
        const auto value = content.Content();
        content.Content(translatedBox(value));
        if (const auto dependency = value.try_as<DependencyObject>()) {
            translateElement(dependency);
        }
    }
    if (const auto border = element.try_as<Border>()) {
        if (const auto child = border.Child()) translateElement(child);
    }
}

Windows::Foundation::IAsyncOperation<ContentDialogResult> MainWindow::showDialog(
    ContentDialog const& dialog) {
    translateElement(dialog.as<DependencyObject>());
    co_return co_await dialog.ShowAsync();
}

void MainWindow::configureTimers() {
    const auto weak = get_weak();
    debugPollTimer_ = dispatcher_.CreateTimer();
    debugPollTimer_.Interval(std::chrono::milliseconds(100));
    debugPollTimer_.IsRepeating(true);
    debugPollToken_ = debugPollTimer_.Tick([weak](auto&&, auto&&) {
        if (const auto self = weak.get()) self->session_->pollDebugger();
    });
    debugPollTimer_.Start();

    workbenchSaveTimer_ = dispatcher_.CreateTimer();
    workbenchSaveTimer_.Interval(std::chrono::milliseconds(350));
    workbenchSaveTimer_.IsRepeating(false);
    workbenchSaveToken_ = workbenchSaveTimer_.Tick([weak](auto&&, auto&&) {
        if (const auto self = weak.get()) self->saveWorkbenchState();
    });

    markdownPreviewTimer_ = dispatcher_.CreateTimer();
    markdownPreviewTimer_.Interval(std::chrono::milliseconds(180));
    markdownPreviewTimer_.IsRepeating(false);
    markdownPreviewToken_ = markdownPreviewTimer_.Tick([weak](auto&&, auto&&) {
        if (const auto self = weak.get(); self &&
            self->MarkdownPreviewPane().Visibility() == Visibility::Visible) {
            self->session_->renderMarkdown(self->pendingMarkdownSource_);
        }
    });
}

fire_and_forget MainWindow::ShowWelcomeClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    showWelcomeSurface();
    co_return;

    // Kept temporarily below while the remaining dialog-only actions are moved
    // to the full-window welcome surface.
    enum class WelcomeAction { None, Clone, Settings };
    WelcomeAction action = WelcomeAction::None;
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Welcome to Lithe"));
    dialog.PrimaryButtonText(L"Open selected");
    dialog.SecondaryButtonText(L"Open folder...");
    dialog.CloseButtonText(L"Close");
    dialog.DefaultButton(ContentDialogButton::Primary);

    StackPanel panel;
    panel.Spacing(10);
    TextBlock subtitle;
    subtitle.Text(L"Open a recent project, choose a folder, or clone a repository.");
    subtitle.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(subtitle);
    TextBox filter;
    filter.PlaceholderText(L"Search recent projects");
    panel.Children().Append(filter);
    ListView projects;
    projects.MinWidth(560);
    projects.MinHeight(280);
    auto recent = session_->recentProjects();
    const auto render = [this, projects, &recent](std::string query) {
        projects.Items().Clear();
        int32_t firstAvailable = -1;
        for (const auto& path : recent) {
            auto label = fileName(path);
            if (label.empty()) label = path;
            if (!query.empty() && !containsIgnoreCase(label + " " + path, query)) continue;
            std::error_code error;
            const bool available = std::filesystem::is_directory(pathFromUtf8(path), error);
            if (!available) label += localizedText(" (missing)", simplifiedChinese_);
            auto item = makeListItem(label + "\n" + path, path);
            item.IsEnabled(available);
            if (available && firstAvailable < 0) {
                firstAvailable = static_cast<int32_t>(projects.Items().Size());
            }
            projects.Items().Append(item);
        }
        if (projects.Items().Size() == 0) {
            auto empty = makeListItem(localizedText(
                query.empty() ? "No recent projects" : "No matching projects",
                simplifiedChinese_));
            empty.IsEnabled(false);
            projects.Items().Append(empty);
        }
        projects.SelectedIndex(firstAvailable);
    };
    const auto filterToken = filter.TextChanged(
        [render](IInspectable const& sender, TextChangedEventArgs const&) {
            render(utf8(sender.as<TextBox>().Text()));
        });
    panel.Children().Append(projects);

    CommandBar actions;
    actions.Background(nullptr);
    actions.DefaultLabelPosition(CommandBarDefaultLabelPosition::Right);
    AppBarButton clone;
    clone.Label(L"Clone");
    clone.Icon(FontIcon{});
    clone.Icon().as<FontIcon>().Glyph(L"\xE8B7");
    AppBarButton settings;
    settings.Label(L"Settings");
    settings.Icon(FontIcon{});
    settings.Icon().as<FontIcon>().Glyph(L"\xE713");
    AppBarButton reveal;
    reveal.Label(L"Show in Explorer");
    reveal.Icon(FontIcon{});
    reveal.Icon().as<FontIcon>().Glyph(L"\xE838");
    AppBarButton remove;
    remove.Label(L"Remove recent");
    remove.Icon(FontIcon{});
    remove.Icon().as<FontIcon>().Glyph(L"\xE74D");
    reveal.IsEnabled(false);
    remove.IsEnabled(false);
    actions.PrimaryCommands().Append(clone);
    actions.PrimaryCommands().Append(settings);
    actions.PrimaryCommands().Append(reveal);
    actions.PrimaryCommands().Append(remove);
    const auto selectionToken = projects.SelectionChanged(
        [reveal, remove](IInspectable const& sender, SelectionChangedEventArgs const&) {
            const auto list = sender.as<ListView>();
            const bool hasPath = !itemTag(list.SelectedItem()).empty();
            reveal.IsEnabled(hasPath);
            remove.IsEnabled(hasPath);
        });
    const auto cloneToken = clone.Click(
        [&dialog, &action](IInspectable const&, RoutedEventArgs const&) {
            action = WelcomeAction::Clone;
            dialog.Hide();
        });
    const auto settingsToken = settings.Click(
        [&dialog, &action](IInspectable const&, RoutedEventArgs const&) {
            action = WelcomeAction::Settings;
            dialog.Hide();
        });
    const auto weakProjects = make_weak(projects);
    const auto revealToken = reveal.Click(
        [this, weakProjects](IInspectable const&, RoutedEventArgs const&) {
            const auto projects = weakProjects.get();
            if (!projects) return;
            const auto path = itemTag(projects.SelectedItem());
            if (!path.empty()) revealPath(pathFromUtf8(path), false);
        });
    const auto removeToken = remove.Click(
        [this, weakProjects, filter, render, &recent](IInspectable const&,
                                                      RoutedEventArgs const&) {
            const auto projects = weakProjects.get();
            if (!projects) return;
            const auto path = itemTag(projects.SelectedItem());
            if (path.empty() || !session_->removeRecentProject(path)) return;
            recent.erase(std::remove(recent.begin(), recent.end(), path), recent.end());
            render(utf8(filter.Text()));
        });
    render({});
    panel.Children().Append(actions);
    dialog.Content(panel);

    const auto result = co_await showDialog(dialog);
    filter.TextChanged(filterToken);
    projects.SelectionChanged(selectionToken);
    clone.Click(cloneToken);
    settings.Click(settingsToken);
    reveal.Click(revealToken);
    remove.Click(removeToken);
    if (result == ContentDialogResult::Primary) {
        const auto path = itemTag(projects.SelectedItem());
        if (!path.empty()) {
            const auto weak = get_weak();
            continueAfterDirtyDocuments("Switch Project", [weak, path] {
                if (const auto self = weak.get()) {
                    self->saveWorkbenchState();
                    self->resetWorkspaceUI();
                    self->session_->openWorkspace(pathFromUtf8(path));
                }
            });
        }
        co_return;
    }
    if (result == ContentDialogResult::Secondary) {
        OpenWorkspaceClick(nullptr, RoutedEventArgs{});
        co_return;
    }
    if (action == WelcomeAction::Clone) {
        CloneRepositoryClick(nullptr, RoutedEventArgs{});
    } else if (action == WelcomeAction::Settings) {
        ShowSettingsClick(nullptr, RoutedEventArgs{});
    }
}

fire_and_forget MainWindow::OpenWorkspaceClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    Windows::Storage::Pickers::FolderPicker picker;
    picker.FileTypeFilter().Append(L"*");
    check_hresult(picker.as<IInitializeWithWindow>()->Initialize(windowHandle()));
    const auto folder = co_await picker.PickSingleFolderAsync();
    if (!folder) co_return;

    const auto root = std::filesystem::path(folder.Path().c_str());
    setStatus("Inspecting project...");
    apartment_context uiThread;
    co_await resume_background();
    auto inspection = session_->inspectProject(root);
    co_await uiThread;

    std::error_code pathError;
    if (!std::filesystem::is_directory(root, pathError)) {
        setStatus("The selected folder is no longer available");
        co_return;
    }

    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Open Project"));
    dialog.PrimaryButtonText(L"Open Project");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Primary);
    ScrollViewer scroll;
    scroll.MaxHeight(540);
    StackPanel panel;
    panel.MinWidth(600);
    panel.Spacing(8);
    TextBlock rootLabel;
    rootLabel.Text(folder.Path());
    rootLabel.TextTrimming(TextTrimming::CharacterEllipsis);
    rootLabel.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(rootLabel);

    const auto* candidate = inspection.detection.candidates.empty()
        ? nullptr : &inspection.detection.candidates.front();
    const auto candidateKind = projectKindLabel(
        candidate == nullptr ? lithe::windows::app::ProjectKind::Unknown : candidate->kind);
    TextBlock kind;
    kind.Text(text(localizedText("Project kind", simplifiedChinese_) + ": " +
                   localizedText(candidateKind, simplifiedChinese_)));
    kind.FontWeight(Text::FontWeights::SemiBold());
    panel.Children().Append(kind);
    TextBlock runtime;
    runtime.Text(text("JDK: " + localizedText(readinessLabel(inspection.jdkReady), simplifiedChinese_) +
                      "  |  Maven: " + localizedText(readinessLabel(inspection.mavenReady), simplifiedChinese_) +
                      "  |  Wrapper: " + localizedText(readinessLabel(inspection.wrapperReady), simplifiedChinese_)));
    runtime.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(runtime);

    TextBlock detailsHeading;
    detailsHeading.Text(L"EVIDENCE AND MODULES");
    detailsHeading.Margin(Thickness{0, 8, 0, 0});
    detailsHeading.Style(Application::Current().Resources()
                             .Lookup(box_value(L"LithePaneHeaderStyle")).as<Style>());
    panel.Children().Append(detailsHeading);
    ListView details;
    details.MinHeight(220);
    if (candidate != nullptr) {
        for (const auto& evidence : candidate->evidence) {
            details.Items().Append(makeListItem(
                "Evidence  |  " + evidence.relativePath + "  |  " + evidence.detail));
        }
        for (const auto& module : candidate->modules) {
            details.Items().Append(makeListItem(
                "Module  |  " + module.relativePath + "  |  " +
                projectKindLabel(module.kind)));
            for (const auto& evidence : module.evidence) {
                details.Items().Append(makeListItem(
                    "    " + evidence.relativePath + "  |  " + evidence.detail));
            }
        }
    }
    if (details.Items().Size() == 0) {
        auto empty = makeListItem("No project markers found. You can still open this folder.");
        empty.IsEnabled(false);
        details.Items().Append(empty);
    }
    panel.Children().Append(details);
    scroll.Content(panel);
    dialog.Content(scroll);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        const auto weak = get_weak();
        continueAfterDirtyDocuments("Open Project", [weak, root] {
            if (const auto self = weak.get()) {
                self->saveWorkbenchState();
                self->resetWorkspaceUI();
                self->session_->openWorkspace(root);
            }
        });
    } else {
        setStatus("Project open cancelled");
    }
}

fire_and_forget MainWindow::CloseWorkspaceClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (session_->workspaceRoot().empty()) {
        setStatus("No workspace open");
        co_return;
    }
    const auto weak = get_weak();
    continueAfterDirtyDocuments("Close Project", [weak] {
        if (const auto self = weak.get()) {
            self->saveWorkbenchState();
            self->session_->closeWorkspace();
            self->resetWorkspaceUI();
            self->ShowWelcomeClick(nullptr, RoutedEventArgs{});
        }
    });
}

fire_and_forget MainWindow::CloneRepositoryClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    Windows::Storage::Pickers::FolderPicker picker;
    picker.FileTypeFilter().Append(L"*");
    check_hresult(picker.as<IInitializeWithWindow>()->Initialize(windowHandle()));
    const auto parent = co_await picker.PickSingleFolderAsync();
    if (!parent) co_return;

    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Clone Repository"));
    dialog.PrimaryButtonText(L"Clone");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBlock parentLabel;
    parentLabel.Text(L"Parent folder");
    panel.Children().Append(parentLabel);
    TextBlock parentValue;
    parentValue.Text(parent.Path());
    parentValue.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    parentValue.TextTrimming(TextTrimming::CharacterEllipsis);
    panel.Children().Append(parentValue);
    TextBlock remoteLabel;
    remoteLabel.Text(L"Repository URL");
    panel.Children().Append(remoteLabel);
    TextBox remote;
    remote.PlaceholderText(L"https://github.com/example/project.git");
    panel.Children().Append(remote);
    TextBlock folderLabel;
    folderLabel.Text(L"Folder name");
    panel.Children().Append(folderLabel);
    TextBox folder;
    folder.PlaceholderText(L"project-name");
    panel.Children().Append(folder);
    dialog.Content(panel);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto remoteValue = utf8(remote.Text());
    const auto parentPath = std::filesystem::path(parent.Path().c_str());
    const auto folderName = utf8(folder.Text());
    const auto destination = parentPath / pathFromUtf8(folderName);
    const auto weak = get_weak();
    continueAfterDirtyDocuments("Clone Repository", [weak, remoteValue, parentPath,
                                                       folderName, destination] {
        const auto self = weak.get();
        if (!self) return;
        self->saveWorkbenchState();
        if (!self->session_->workspaceRoot().empty()) self->session_->closeWorkspace();
        self->resetWorkspaceUI();
        const auto dispatcher = self->dispatcher_;
        self->session_->cloneRepository(remoteValue, parentPath, folderName,
            [weak, dispatcher, destination](bool succeeded, std::string error) mutable {
                dispatcher.TryEnqueue([weak, destination, succeeded,
                                       error = std::move(error)]() mutable {
                    const auto self = weak.get();
                    if (!self) return;
                    if (succeeded) self->session_->openWorkspace(destination);
                    else self->setStatus(error.empty() ? "Repository clone failed" : error);
                });
            });
    });
}

fire_and_forget MainWindow::PreviewMarkdownClick(IInspectable const&, RoutedEventArgs const&) {
    if (activePath_.empty() ||
        !(activePath_.ends_with(".md") || activePath_.ends_with(".markdown"))) {
        setStatus("Open a Markdown file to preview it");
        co_return;
    }
    renderMarkdownPreview(editorText());
    MarkdownPreviewPane().Visibility(Visibility::Visible);
    EditorSurfaceColumn().Width(GridLength{1.0, GridUnitType::Star});
    MarkdownPreviewColumn().Width(GridLength{1.0, GridUnitType::Star});
    setStatus("Markdown preview shown beside the editor");
    co_return;
}

void MainWindow::renderMarkdownPreview(std::string_view source) {
    pendingMarkdownSource_ = source;
    MarkdownPreviewContent().Children().Clear();
    bool inCodeBlock = false;
    for (auto line : lines(source)) {
        if (line.starts_with("```")) {
            inCodeBlock = !inCodeBlock;
            continue;
        }
        TextBlock block;
        block.TextWrapping(TextWrapping::Wrap);
        if (inCodeBlock) {
            block.Text(text(line));
            block.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
            block.Padding(Thickness{8, 4, 8, 4});
        } else if (line.starts_with("### ")) {
            block.Text(text(line.substr(4)));
            block.FontSize(16);
            block.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        } else if (line.starts_with("## ")) {
            block.Text(text(line.substr(3)));
            block.FontSize(19);
            block.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        } else if (line.starts_with("# ")) {
            block.Text(text(line.substr(2)));
            block.FontSize(24);
            block.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        } else if (line.starts_with("- ") || line.starts_with("* ")) {
            block.Text(text("  -  " + line.substr(2)));
        } else {
            block.Text(text(line));
        }
        MarkdownPreviewContent().Children().Append(block);
    }
    if (MarkdownPreviewWebView().Visibility() != Visibility::Visible) {
        MarkdownPreviewFallback().Visibility(Visibility::Visible);
    }
    if (markdownPreviewTimer_) {
        markdownPreviewTimer_.Stop();
        markdownPreviewTimer_.Start();
    }
}

void MainWindow::renderMarkdownHTML(
    lithe::windows::winui::MarkdownRenderResult result) {
    if (MarkdownPreviewPane().Visibility() != Visibility::Visible) return;
    if (!result.error.empty() || result.html.empty()) {
        MarkdownPreviewWebView().Visibility(Visibility::Collapsed);
        MarkdownPreviewFallback().Visibility(Visibility::Visible);
        if (!result.error.empty()) setStatus(result.error);
        return;
    }
    const std::string page = R"HTML(<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; media-src data: https: http:; style-src 'unsafe-inline'">
<style>
:root{color-scheme:light dark;font-family:"Segoe UI",sans-serif;font-size:14px}
body{margin:0;padding:18px;color:#202124;background:#fff;line-height:1.55;overflow-wrap:anywhere}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.2em 0 .55em}h1{font-size:1.9em;border-bottom:1px solid #d8d8d8;padding-bottom:.25em}h2{font-size:1.5em;border-bottom:1px solid #e4e4e4;padding-bottom:.2em}
p,ul,ol,blockquote,pre,table{margin:.65em 0}a{color:#0969da;pointer-events:none}blockquote{margin-left:0;padding:.15em .9em;border-left:4px solid #8c959f;color:#59636e}
code,pre{font-family:"Cascadia Mono",Consolas,monospace}code{background:#eff1f3;border-radius:4px;padding:.12em .3em}pre{background:#f4f5f6;border-radius:6px;padding:12px;overflow:auto}pre code{background:transparent;padding:0}
table{border-collapse:collapse;width:max-content;max-width:100%}th,td{border:1px solid #d0d7de;padding:6px 10px;text-align:left}img{max-width:100%;height:auto}hr{border:0;border-top:1px solid #d8dee4}
.markdown-alert{padding:.55em .8em;border-left:4px solid #2f81f7;background:#f2f7ff}.task-list-item{list-style:none}
@media(prefers-color-scheme:dark){body{color:#e6edf3;background:#1e1e1e}a{color:#58a6ff}h1,h2{border-color:#3d444d}blockquote{color:#9da7b1;border-color:#6e7681}code{background:#2d333b}pre{background:#252a30}th,td{border-color:#444c56}.markdown-alert{background:#202d3d}}
</style></head><body>)HTML" + result.html + "</body></html>";
    try {
        MarkdownPreviewWebView().NavigateToString(text(page));
        MarkdownPreviewWebView().Visibility(Visibility::Visible);
        MarkdownPreviewFallback().Visibility(Visibility::Collapsed);
    } catch (const hresult_error& error) {
        MarkdownPreviewWebView().Visibility(Visibility::Collapsed);
        MarkdownPreviewFallback().Visibility(Visibility::Visible);
        setStatus("WebView2 Markdown preview unavailable: " + utf8(error.message()));
    }
}

void MainWindow::RefreshWorkspaceClick(IInspectable const&, RoutedEventArgs const&) {
    session_->refreshWorkspace();
}

void MainWindow::RevealWorkspaceClick(IInspectable const&, RoutedEventArgs const&) {
    if (session_->workspaceRoot().empty()) {
        setStatus("Open a workspace first");
        return;
    }
    revealPath(session_->workspaceRoot(), false);
}

void MainWindow::SaveDocumentClick(IInspectable const&, RoutedEventArgs const&) {
    if (activePath_.empty() || isExternalDocument(activePath_)) {
        setStatus("Open a file before saving");
        return;
    }
    cacheCurrentDocument();
    session_->saveDocument();
}

void MainWindow::MarkdownEditorModeClick(IInspectable const&, RoutedEventArgs const&) {
    MarkdownModePanel().Visibility(Visibility::Visible);
    MarkdownPreviewPane().Visibility(Visibility::Collapsed);
    MarkdownPreviewColumn().Width(GridLength{0.0, GridUnitType::Pixel});
    EditorTextBox().Focus(FocusState::Programmatic);
    setStatus("Markdown editor focused");
}

fire_and_forget MainWindow::MarkdownPreviewModeClick(
    IInspectable const&, RoutedEventArgs const&) {
    PreviewMarkdownClick(nullptr, RoutedEventArgs{});
    co_return;
}

void MainWindow::RefreshGitClick(IInspectable const&, RoutedEventArgs const&) {
    session_->refreshGit();
}

void MainWindow::FetchGitClick(IInspectable const&, RoutedEventArgs const&) {
    session_->fetch();
}

fire_and_forget MainWindow::PushGitClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (co_await lithe::windows::winui::UiDialogs::confirm(
            RootGrid().XamlRoot(), ui("Push current branch?"),
            ui("This sends the current branch to its configured remote."),
            ui("Push"), ui("Cancel"), true)) {
        session_->push();
    }
}

fire_and_forget MainWindow::PullGitClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Pull strategy")));
    dialog.PrimaryButtonText(ui("Pull"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBlock hint;
    hint.Text(ui("Choose how divergent history should be integrated."));
    hint.TextWrapping(TextWrapping::Wrap);
    panel.Children().Append(hint);
    ComboBox strategy;
    strategy.Items().Append(box_value(ui("Fast-forward only")));
    strategy.Items().Append(box_value(ui("Merge")));
    strategy.Items().Append(box_value(ui("Rebase")));
    strategy.SelectedIndex(0);
    panel.Children().Append(strategy);
    dialog.Content(panel);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto selected = strategy.SelectedIndex();
    session_->pull(selected == 1 ? "merge" : selected == 2 ? "rebase" : "ffOnly");
}

void MainWindow::ContinueGitOperationClick(IInspectable const&, RoutedEventArgs const&) {
    if (pendingIntegration_) {
        const auto pending = std::move(*pendingIntegration_);
        pendingIntegration_.reset();
        pendingIntegrationPaths_.clear();
        renderGitChanges();
        if (pending.operation == "merge" || pending.operation == "rebase") {
            session_->integrate(pending.reference, pending.operation);
        } else {
            session_->replayCommit(pending.reference, pending.operation);
        }
        return;
    }
    session_->resolveGitOperation("operationContinue");
}

void MainWindow::AbortGitOperationClick(IInspectable const&, RoutedEventArgs const&) {
    if (pendingIntegration_) {
        pendingIntegration_.reset();
        pendingIntegrationPaths_.clear();
        renderGitChanges();
        session_->cancelIntegrationConflict();
        return;
    }
    session_->resolveGitOperation("operationAbort");
}

void MainWindow::SkipGitOperationClick(IInspectable const&, RoutedEventArgs const&) {
    session_->resolveGitOperation("operationSkip");
}

fire_and_forget MainWindow::IntegrateGitClick(IInspectable const& sender, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto item = sender.try_as<MenuFlyoutItem>();
    const auto operation = item && item.Tag()
        ? utf8(unbox_value<hstring>(item.Tag())) : std::string{};
    if (operation != "merge" && operation != "rebase") co_return;
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui(operation == "merge" ? "Merge reference" : "Rebase onto reference")));
    dialog.PrimaryButtonText(ui(operation == "merge" ? "Merge" : "Rebase"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Primary);
    TextBox reference;
    reference.Header(box_value(ui("Branch, tag, or commit")));
    reference.PlaceholderText(L"feature/example");
    dialog.Content(reference);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary && !utf8(reference.Text()).empty()) {
        session_->integrate(utf8(reference.Text()), operation);
    }
}

fire_and_forget MainWindow::CherryPickSelectedCommitClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (selectedGitCommit_.empty()) {
        setStatus("Select a commit from Git History first");
        co_return;
    }
    if (co_await lithe::windows::winui::UiDialogs::confirm(
            RootGrid().XamlRoot(), ui("Cherry-pick selected commit?"),
            text(selectedGitCommit_), ui("Cherry-pick"), ui("Cancel"), true)) {
        session_->replayCommit(selectedGitCommit_, "cherryPick");
    }
}

fire_and_forget MainWindow::RevertSelectedCommitClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (selectedGitCommit_.empty()) {
        setStatus("Select a commit from Git History first");
        co_return;
    }
    if (co_await lithe::windows::winui::UiDialogs::confirm(
            RootGrid().XamlRoot(), ui("Revert selected commit?"),
            text(selectedGitCommit_), ui("Revert"), ui("Cancel"), true)) {
        session_->replayCommit(selectedGitCommit_, "revert");
    }
}

fire_and_forget MainWindow::ResetToRevisionClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Reset current branch")));
    dialog.PrimaryButtonText(ui("Continue"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Close);
    StackPanel panel;
    panel.Spacing(8);
    TextBox revision;
    revision.Header(box_value(ui("Revision")));
    revision.PlaceholderText(L"HEAD~1");
    revision.Text(text(selectedGitCommit_));
    panel.Children().Append(revision);
    ComboBox mode;
    mode.Header(box_value(ui("Reset mode")));
    mode.Items().Append(box_value(ui("Soft - keep index and files")));
    mode.Items().Append(box_value(ui("Mixed - reset index, keep files")));
    mode.Items().Append(box_value(ui("Hard - discard index and file changes")));
    mode.SelectedIndex(1);
    panel.Children().Append(mode);
    TextBlock warning;
    warning.Text(ui("Hard reset permanently discards staged and working-tree changes."));
    warning.TextWrapping(TextWrapping::Wrap);
    warning.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(warning);
    dialog.Content(panel);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto target = utf8(revision.Text());
    if (target.empty()) {
        setStatus("Enter a revision to reset to");
        co_return;
    }
    const auto selectedMode = mode.SelectedIndex();
    const std::string resetMode = selectedMode == 0 ? "--soft"
        : selectedMode == 2 ? "--hard" : "--mixed";
    if (resetMode == "--hard") {
        const bool confirmed = co_await lithe::windows::winui::UiDialogs::confirm(
            RootGrid().XamlRoot(), ui("Hard reset and discard local changes?"),
            ui("This action cannot be undone by Lithe."),
            ui("Reset Hard"), ui("Cancel"), true);
        if (!confirmed) co_return;
    }
    session_->resetToRevision(target, resetMode);
}

std::vector<std::string> MainWindow::selectedChangePaths() {
    std::vector<std::string> paths;
    for (const auto& selected : ChangesList().SelectedItems()) {
        auto path = itemTag(selected);
        if (!path.empty()) paths.push_back(std::move(path));
    }
    return paths;
}

void MainWindow::StageSelectedClick(IInspectable const&, RoutedEventArgs const&) {
    auto paths = selectedChangePaths();
    if (paths.empty()) {
        setStatus("Select one or more changes to stage");
        return;
    }
    session_->stage(std::move(paths));
}

void MainWindow::UnstageSelectedClick(IInspectable const&, RoutedEventArgs const&) {
    auto paths = selectedChangePaths();
    if (paths.empty()) {
        setStatus("Select one or more changes to unstage");
        return;
    }
    session_->unstage(std::move(paths));
}

fire_and_forget MainWindow::DiscardSelectedClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    auto paths = selectedChangePaths();
    if (paths.empty()) {
        setStatus("Select one or more changes to discard");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Discard selected changes?"));
    dialog.Content(box_value(L"This operation cannot be undone by Lithe."));
    dialog.PrimaryButtonText(L"Discard");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->discard(std::move(paths));
    }
}

fire_and_forget MainWindow::RollbackBlockedPathClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto paths = selectedChangePaths();
    if (paths.size() != 1) {
        setStatus(localizedText(
            "Select one blocked path to roll back", simplifiedChinese_));
        co_return;
    }
    std::unordered_set<std::string> blocked(
        gitConflictPaths_.begin(), gitConflictPaths_.end());
    blocked.insert(pendingIntegrationPaths_.begin(), pendingIntegrationPaths_.end());
    if (!blocked.contains(paths.front())) {
        setStatus(localizedText(
            "The selected path is not blocking a Git operation", simplifiedChinese_));
        co_return;
    }

    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Roll back blocked file to HEAD?")));
    dialog.Content(box_value(text(paths.front() + "\n\n" + localizedText(
        "Staged and working-tree changes for this file will be discarded. The operation will be checked again before retrying.",
        simplifiedChinese_))));
    dialog.PrimaryButtonText(ui("Roll Back"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;

    const auto weak = get_weak();
    const auto dispatcher = dispatcher_;
    session_->rollbackConflictPath(
        paths.front(), [weak, dispatcher](bool succeeded, std::string error) mutable {
            dispatcher.TryEnqueue([weak, succeeded, error = std::move(error)]() mutable {
                const auto self = weak.get();
                if (!self) return;
                if (!succeeded) {
                    self->setStatus(error.empty()
                        ? localizedText("Could not roll back blocked path",
                                        self->simplifiedChinese_)
                        : std::move(error));
                    return;
                }
                self->setStatus(localizedText(
                    "Blocked path rolled back", self->simplifiedChinese_));
                if (self->pendingIntegration_) {
                    const auto pending = *self->pendingIntegration_;
                    self->pendingIntegration_.reset();
                    self->pendingIntegrationPaths_.clear();
                    self->renderGitChanges();
                    if (pending.operation == "merge" || pending.operation == "rebase") {
                        self->session_->integrate(pending.reference, pending.operation);
                    } else {
                        self->session_->replayCommit(pending.reference, pending.operation);
                    }
                } else {
                    self->session_->refreshGit();
                }
            });
        });
}

void MainWindow::BlockedChangesFilterChanged(IInspectable const&, RoutedEventArgs const&) {
    renderGitChanges();
}

void MainWindow::StageAllClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stageAll();
}

void MainWindow::CommitClick(IInspectable const&, RoutedEventArgs const&) {
    const auto message = utf8(CommitMessageBox().Text());
    if (message.empty()) {
        setStatus("Enter a commit message");
        return;
    }
    const auto amend = AmendCommitCheckBox().IsChecked();
    session_->commit(message, amend && amend.Value());
}

void MainWindow::CommitAndPushClick(IInspectable const&, RoutedEventArgs const&) {
    const auto message = utf8(CommitMessageBox().Text());
    if (message.empty()) {
        setStatus("Enter a commit message");
        return;
    }
    const auto amend = AmendCommitCheckBox().IsChecked();
    session_->commitAndPush(message, amend && amend.Value());
}

void MainWindow::LoadGitHistoryClick(IInspectable const&, RoutedEventArgs const&) {
    GitModeTabs().SelectedIndex(0);
    showBottomTool(4);
    session_->loadGitHistory();
}

void MainWindow::LoadGitStashesClick(IInspectable const&, RoutedEventArgs const&) {
    GitModeTabs().SelectedIndex(1);
    showBottomTool(4);
    session_->loadGitStashes();
}

void MainWindow::LoadShelvesClick(IInspectable const&, RoutedEventArgs const&) {
    GitModeTabs().SelectedIndex(2);
    showBottomTool(4);
    session_->loadShelves();
}

void MainWindow::ToggleBlameClick(IInspectable const&, RoutedEventArgs const&) {
    if (activePath_.empty() || isExternalDocument(activePath_)) {
        setStatus("Open a workspace file before showing Git blame");
        return;
    }
    blameVisible_ = !blameVisible_;
    if (!blameVisible_) {
        blamePath_.clear();
        blame_.reset();
        updateLineNumbers();
        setStatus("Git blame hidden");
        return;
    }
    blamePath_ = activePath_;
    blame_.reset();
    session_->loadGitBlame(activePath_);
    updateLineNumbers();
    setStatus("Loading Git blame...");
}

fire_and_forget MainWindow::CompareReferenceClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Compare Git Reference"));
    dialog.PrimaryButtonText(L"Compare");
    dialog.CloseButtonText(L"Cancel");
    TextBox input;
    input.Header(box_value(L"Branch, tag, or commit"));
    input.Text(L"HEAD~1");
    dialog.Content(input);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->loadGitComparison(utf8(input.Text()));
        showBottomTool(4);
    }
}

fire_and_forget MainWindow::SwitchReferenceClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto state = session_->gitState();
    if (!state.history || state.history->references.empty()) {
        setStatus("Load Git history before switching references");
        session_->loadGitHistory();
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Switch Git Reference"));
    dialog.PrimaryButtonText(L"Switch");
    dialog.CloseButtonText(L"Cancel");
    ComboBox choices;
    choices.MinWidth(420);
    for (const auto& reference : state.history->references) {
        choices.Items().Append(makeListItem(
            reference.shortName + "  [" + reference.kind + "]", reference.fullName));
    }
    choices.SelectedIndex(0);
    dialog.Content(choices);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto index = choices.SelectedIndex();
    if (index < 0 || static_cast<std::size_t>(index) >= state.history->references.size()) co_return;
    const auto& reference = state.history->references[static_cast<std::size_t>(index)];
    session_->checkout(reference.fullName, reference.kind);
}

fire_and_forget MainWindow::showCheckoutConflict(
    lithe::windows::app::GitPendingCheckout pending,
    std::vector<std::string> blockingPaths) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Local changes would be overwritten")));
    dialog.PrimaryButtonText(ui("Smart Checkout"));
    dialog.SecondaryButtonText(ui("Force Checkout"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBlock explanation;
    explanation.Text(text(simplifiedChinese_
        ? "这些本地修改与 '" + pending.reference +
              "' 冲突。智能签出会临时保存修改，切换分支后再恢复；强制签出会永久丢弃修改。"
        : "These local changes conflict with '" + pending.reference +
              "'. Smart Checkout temporarily stashes them, switches branches, then restores them. "
              "Force Checkout permanently discards them."));
    explanation.TextWrapping(TextWrapping::Wrap);
    panel.Children().Append(explanation);
    ListView paths;
    paths.MaxHeight(180);
    paths.SelectionMode(ListViewSelectionMode::None);
    for (const auto& path : blockingPaths) {
        paths.Items().Append(makeListItem(path, path));
    }
    panel.Children().Append(paths);
    dialog.Content(panel);
    const auto result = co_await showDialog(dialog);
    if (result == ContentDialogResult::Primary) {
        session_->resolveCheckoutConflict("smart");
        co_return;
    }
    if (result != ContentDialogResult::Secondary) {
        session_->cancelCheckoutConflict();
        co_return;
    }
    ContentDialog confirmation;
    confirmation.XamlRoot(RootGrid().XamlRoot());
    confirmation.Title(box_value(ui("Discard local changes and switch branches?")));
    confirmation.Content(box_value(ui(
        "The listed local changes will be permanently discarded. This cannot be undone by Lithe.")));
    confirmation.PrimaryButtonText(ui("Force Checkout"));
    confirmation.CloseButtonText(ui("Cancel"));
    confirmation.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(confirmation) == ContentDialogResult::Primary) {
        session_->resolveCheckoutConflict("force");
    } else {
        session_->cancelCheckoutConflict();
    }
}

fire_and_forget MainWindow::showIntegrationConflict(
    lithe::windows::app::GitPendingIntegration pending,
    std::vector<std::string> blockingPaths,
    bool blocksEntirely) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    const auto operationTitle = pending.operation == "cherryPick" ? "cherry-pick"
        : pending.operation;
    dialog.Title(box_value(text(
        simplifiedChinese_ ? "本地修改阻止 Git " + operationTitle
                           : "Local changes block Git " + operationTitle)));
    dialog.PrimaryButtonText(ui("Continue"));
    dialog.SecondaryButtonText(ui("Review Changes"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBlock explanation;
    explanation.Text(text(simplifiedChinese_
        ? (blocksEntirely
            ? "此操作要求先处理全部本地修改。目标引用会保留，处理后可直接重试。"
            : "以下文件可能被操作覆盖。目标引用会保留，处理后可直接重试。")
        : (blocksEntirely
            ? "This operation requires a clean working tree. The target is retained so you can retry after resolving the changes."
            : "These files could be overwritten. The target is retained so you can retry after resolving the changes.")));
    explanation.TextWrapping(TextWrapping::Wrap);
    panel.Children().Append(explanation);
    TextBlock target;
    target.Text(text(pending.reference));
    target.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
    panel.Children().Append(target);
    ComboBox strategy;
    strategy.Header(box_value(ui("Local changes strategy")));
    strategy.Items().Append(box_value(ui("Git Stash")));
    strategy.Items().Append(box_value(ui("Lithe Shelf")));
    strategy.SelectedIndex(0);
    panel.Children().Append(strategy);
    ListView paths;
    paths.MaxHeight(180);
    paths.SelectionMode(ListViewSelectionMode::None);
    for (const auto& path : blockingPaths) paths.Items().Append(makeListItem(path, path));
    panel.Children().Append(paths);
    dialog.Content(panel);
    const auto result = co_await showDialog(dialog);
    if (result == ContentDialogResult::Primary) {
        pendingIntegrationPaths_.clear();
        if (strategy.SelectedIndex() == 1) session_->autoShelfIntegration();
        else session_->autoStashIntegration();
        co_return;
    }
    if (result != ContentDialogResult::Secondary) {
        pendingIntegrationPaths_.clear();
        session_->cancelIntegrationConflict();
        co_return;
    }
    pendingIntegration_ = std::move(pending);
    pendingIntegrationPaths_ = std::move(blockingPaths);
    renderGitChanges();
    SidebarTabs().SelectedIndex(1);
    showBottomTool(4);
    GitOperationText().Text(text(
        "Git " + pendingIntegration_->operation + " pending: " +
        pendingIntegration_->reference));
    ContinueGitOperationButton().Content(box_value(ui("Retry")));
    ContinueGitOperationButton().Visibility(Visibility::Visible);
    AbortGitOperationButton().Content(box_value(ui("Cancel")));
    AbortGitOperationButton().Visibility(Visibility::Visible);
    SkipGitOperationButton().Visibility(Visibility::Collapsed);
}

fire_and_forget MainWindow::CreateBranchClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto name = co_await lithe::windows::winui::UiDialogs::prompt(
        RootGrid().XamlRoot(), ui("Create Git Branch"), ui("Branch name"),
        ui("Create and switch"), ui("Cancel"));
    if (!name.empty()) session_->createBranch(utf8(name));
}

fire_and_forget MainWindow::RenameBranchClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto state = session_->gitState();
    if (!state.history || state.history->references.empty()) {
        setStatus("Load Git history before managing branches");
        session_->loadGitHistory();
        co_return;
    }
    std::vector<std::size_t> localReferences;
    ComboBox choices;
    choices.MinWidth(420);
    for (std::size_t index = 0; index < state.history->references.size(); ++index) {
        const auto& reference = state.history->references[index];
        if (reference.kind != "local") continue;
        localReferences.push_back(index);
        choices.Items().Append(makeListItem(
            reference.shortName + (reference.isCurrent ? "  [current]" : ""),
            reference.fullName));
    }
    if (localReferences.empty()) {
        setStatus("No local branches available");
        co_return;
    }
    choices.SelectedIndex(0);
    choices.Header(box_value(ui("Branch")));
    ContentDialog branchDialog;
    branchDialog.XamlRoot(RootGrid().XamlRoot());
    branchDialog.Title(box_value(ui("Rename Git Branch")));
    branchDialog.PrimaryButtonText(ui("Next"));
    branchDialog.CloseButtonText(ui("Cancel"));
    branchDialog.DefaultButton(ContentDialogButton::Primary);
    branchDialog.Content(choices);
    if (co_await showDialog(branchDialog) != ContentDialogResult::Primary) co_return;
    const auto selected = choices.SelectedIndex();
    if (selected < 0 || static_cast<std::size_t>(selected) >= localReferences.size()) co_return;
    const auto& reference = state.history->references[localReferences[selected]];
    const auto renamed = co_await lithe::windows::winui::UiDialogs::prompt(
        RootGrid().XamlRoot(), text("Rename '" + reference.shortName + "'"),
        ui("New branch name"), ui("Rename"), ui("Cancel"), text(reference.shortName));
    const auto newName = utf8(renamed);
    if (newName.empty() || newName == reference.shortName) {
        setStatus(newName.empty() ? "Enter a branch name" : "Branch name is unchanged");
        co_return;
    }
    session_->renameBranch(reference.fullName, newName);
}

fire_and_forget MainWindow::DeleteBranchClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto state = session_->gitState();
    if (!state.history || state.history->references.empty()) {
        setStatus("Load Git history before managing branches");
        session_->loadGitHistory();
        co_return;
    }
    std::vector<std::size_t> localReferences;
    ComboBox choices;
    choices.MinWidth(420);
    for (std::size_t index = 0; index < state.history->references.size(); ++index) {
        const auto& reference = state.history->references[index];
        if (reference.kind != "local" || reference.isCurrent) continue;
        localReferences.push_back(index);
        choices.Items().Append(makeListItem(reference.shortName, reference.fullName));
    }
    if (localReferences.empty()) {
        setStatus("No non-current local branch is available to delete");
        co_return;
    }
    choices.SelectedIndex(0);
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Delete Git Branch")));
    dialog.Content(choices);
    dialog.PrimaryButtonText(ui("Delete"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto selected = choices.SelectedIndex();
    if (selected < 0 || static_cast<std::size_t>(selected) >= localReferences.size()) co_return;
    const auto& reference = state.history->references[localReferences[selected]];
    if (co_await lithe::windows::winui::UiDialogs::confirm(
            RootGrid().XamlRoot(), text("Delete branch '" + reference.shortName + "'?"),
            ui("Git will refuse if the branch contains work that has not been merged."),
            ui("Delete"), ui("Cancel"), true)) {
        session_->deleteBranch(reference.fullName);
    }
}

fire_and_forget MainWindow::CreateStashClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Create Git Stash"));
    dialog.PrimaryButtonText(L"Stash");
    dialog.CloseButtonText(L"Cancel");
    StackPanel panel;
    panel.Spacing(8);
    TextBox message;
    message.Header(box_value(L"Message"));
    message.Text(L"Lithe work in progress");
    panel.Children().Append(message);
    CheckBox untracked;
    untracked.Content(box_value(L"Include untracked files"));
    panel.Children().Append(untracked);
    dialog.Content(panel);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        const auto includeUntracked = untracked.IsChecked();
        session_->stash(utf8(message.Text()),
                        includeUntracked && includeUntracked.Value());
    }
}

void MainWindow::ApplyStashClick(IInspectable const&, RoutedEventArgs const&) {
    if (selectedGitStash_.empty()) setStatus("Select a stash first");
    else session_->applyStash(selectedGitStash_);
}

void MainWindow::PopStashClick(IInspectable const&, RoutedEventArgs const&) {
    if (selectedGitStash_.empty()) setStatus("Select a stash first");
    else session_->popStash(selectedGitStash_);
}

fire_and_forget MainWindow::DropStashClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (selectedGitStash_.empty()) {
        setStatus("Select a stash first");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Drop selected stash?"));
    dialog.Content(box_value(L"The stash entry will be permanently removed."));
    dialog.PrimaryButtonText(L"Drop");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->dropStash(selectedGitStash_);
    }
}

fire_and_forget MainWindow::CreateShelfClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Create Shelf"));
    dialog.PrimaryButtonText(L"Create");
    dialog.CloseButtonText(L"Cancel");
    TextBox input;
    input.Header(box_value(L"Shelf name"));
    input.Text(L"Working tree snapshot");
    dialog.Content(input);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->createShelf(utf8(input.Text()));
    }
}

void MainWindow::RestoreShelfClick(IInspectable const&, RoutedEventArgs const&) {
    if (selectedShelf_.empty()) setStatus("Select a Shelf first");
    else session_->restoreShelf(selectedShelf_);
}

fire_and_forget MainWindow::DeleteShelfClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (selectedShelf_.empty()) {
        setStatus("Select a Shelf first");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Delete selected Shelf?"));
    dialog.Content(box_value(L"The saved patches will be permanently removed."));
    dialog.PrimaryButtonText(L"Delete");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->deleteShelf(selectedShelf_);
    }
}

void MainWindow::StageHunkClick(IInspectable const&, RoutedEventArgs const&) {
    session_->applyHunk(selectedHunk_, "stage");
}

void MainWindow::UnstageHunkClick(IInspectable const&, RoutedEventArgs const&) {
    session_->applyHunk(selectedHunk_, "unstage");
}

fire_and_forget MainWindow::DiscardHunkClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (selectedHunk_.empty()) {
        setStatus("Select a diff hunk first");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Discard selected hunk?"));
    dialog.Content(box_value(L"This operation cannot be undone by Lithe."));
    dialog.PrimaryButtonText(L"Discard");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->applyHunk(selectedHunk_, "discard");
    }
}

void MainWindow::StartTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(0);
    if (activeTerminalID_.empty()) {
        NewTerminalClick(nullptr, RoutedEventArgs{});
    } else {
        session_->startTerminal(activeTerminalID_);
    }
    TerminalInputBox().Focus(FocusState::Programmatic);
}

void MainWindow::NewTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(0);
    const auto id = session_->createTerminal();
    if (id.empty()) {
        setStatus("Open a workspace before starting a terminal");
        return;
    }
    TerminalInputBox().Focus(FocusState::Programmatic);
}

void MainWindow::CloseTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    if (activeTerminalID_.empty()) return;
    session_->closeTerminal(activeTerminalID_);
}

void MainWindow::StopTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    if (!activeTerminalID_.empty()) session_->stopTerminal(activeTerminalID_);
}

void MainWindow::InterruptTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    if (!activeTerminalID_.empty()) session_->interruptTerminal(activeTerminalID_);
}

void MainWindow::RestartTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    if (activeTerminalID_.empty()) {
        NewTerminalClick(nullptr, RoutedEventArgs{});
        return;
    }
    session_->stopTerminal(activeTerminalID_);
    session_->startTerminal(activeTerminalID_);
}

void MainWindow::ClearTerminalClick(IInspectable const&, RoutedEventArgs const&) {
    if (!activeTerminalID_.empty()) session_->clearTerminal(activeTerminalID_);
}

void MainWindow::TerminalSessionSelectionChanged(
    IInspectable const&, SelectionChangedEventArgs const&) {
    if (terminalUiUpdating_) return;
    const auto id = itemTag(TerminalSessionsBox().SelectedItem());
    if (!id.empty()) session_->selectTerminal(id);
}

void MainWindow::TerminalShellSelectionChanged(
    IInspectable const&, SelectionChangedEventArgs const&) {
    if (terminalUiUpdating_ || activeTerminalID_.empty()) return;
    auto shell = utf8(TerminalShellBox().Text());
    if (shell.empty()) {
        if (const auto selected = TerminalShellBox().SelectedItem().try_as<ComboBoxItem>()) {
            if (const auto content = selected.Content().try_as<Windows::Foundation::IPropertyValue>();
                content && content.Type() == Windows::Foundation::PropertyType::String) {
                shell = utf8(content.GetString());
            }
        }
    }
    if (!shell.empty()) session_->setTerminalShell(activeTerminalID_, shell);
}

void MainWindow::TerminalShellLostFocus(IInspectable const&, RoutedEventArgs const&) {
    if (terminalUiUpdating_ || activeTerminalID_.empty()) return;
    session_->setTerminalShell(activeTerminalID_, utf8(TerminalShellBox().Text()));
}

void MainWindow::RunMavenCleanClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runMaven("clean");
}

void MainWindow::RunMavenTestClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runMaven("test");
}

void MainWindow::RunMavenPackageClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runMaven("package");
}

void MainWindow::RunMavenVerifyClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runMaven("verify");
}

void MainWindow::RunMavenInstallClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runMaven("install");
}

void MainWindow::StopProcessClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stopBuild();
}

void MainWindow::RunCurrentJavaClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runCurrentJava(isExternalDocument(activePath_) ? std::string{} : activePath_);
}

void MainWindow::RunSpringBootClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    session_->runSpringBoot(isExternalDocument(activePath_) ? std::string{} : activePath_);
}

void MainWindow::RunSelectedConfigurationClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(1);
    const auto id = itemTag(RunConfigurationBox().SelectedItem());
    if (id.empty()) {
        setStatus("Select a detected Java run configuration");
        return;
    }
    session_->runJavaConfiguration(
        id, isExternalDocument(activePath_) ? std::string{} : activePath_);
}

void MainWindow::StopJavaClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stopJava();
}

void MainWindow::DebugCurrentJavaClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(3);
    session_->debugCurrentJava(
        isExternalDocument(activePath_) ? std::string{} : activePath_, editorText());
}

void MainWindow::DebugSpringBootClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(3);
    session_->debugSpringBoot();
}

void MainWindow::DebugSelectedConfigurationClick(IInspectable const&, RoutedEventArgs const&) {
    showBottomTool(3);
    const auto id = itemTag(RunConfigurationBox().SelectedItem());
    if (id.empty()) {
        setStatus("Select a detected Java debug configuration");
        return;
    }
    session_->debugJavaConfiguration(id);
}

fire_and_forget MainWindow::AttachDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Attach to JDWP"));
    dialog.PrimaryButtonText(L"Attach");
    dialog.CloseButtonText(L"Cancel");
    StackPanel panel;
    panel.Spacing(8);
    TextBox host;
    host.Header(box_value(L"Host"));
    host.Text(L"127.0.0.1");
    panel.Children().Append(host);
    NumberBox port;
    port.Header(box_value(L"Port"));
    port.Minimum(1);
    port.Maximum(65535);
    port.Value(5005);
    panel.Children().Append(port);
    dialog.Content(panel);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        showBottomTool(3);
        session_->attachDebugger(
            utf8(host.Text()), static_cast<std::uint16_t>(port.Value()));
    }
}

void MainWindow::ToggleBreakpointClick(IInspectable const&, RoutedEventArgs const&) {
    const auto [line, column] = editorPosition();
    (void)column;
    session_->toggleBreakpoint(
        isExternalDocument(activePath_) ? std::string{} : activePath_, editorText(), line);
}

void MainWindow::ContinueDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    session_->continueDebugger();
}

void MainWindow::PauseDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    session_->pauseDebugger();
}

void MainWindow::StepIntoDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stepIntoDebugger();
}

void MainWindow::StepOverDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stepOverDebugger();
}

void MainWindow::StepOutDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stepOutDebugger();
}

void MainWindow::StopDebuggerClick(IInspectable const&, RoutedEventArgs const&) {
    session_->stopDebugger();
}

void MainWindow::InspectDebuggerThreadsClick(IInspectable const&, RoutedEventArgs const&) {
    session_->inspectDebuggerThreads();
}

void MainWindow::InspectDebuggerStackClick(IInspectable const&, RoutedEventArgs const&) {
    session_->inspectDebuggerStack();
}

void MainWindow::InspectDebuggerVariablesClick(IInspectable const&, RoutedEventArgs const&) {
    session_->inspectDebuggerVariables();
}

void MainWindow::GoToDefinitionClick(IInspectable const&, RoutedEventArgs const&) {
    const auto [line, column] = editorPosition();
    session_->goToJavaDefinition(
        isExternalDocument(activePath_) ? std::string{} : activePath_,
        editorText(), line, column);
}

void MainWindow::FindUsagesClick(IInspectable const&, RoutedEventArgs const&) {
    const auto [line, column] = editorPosition();
    session_->findJavaUsages(
        isExternalDocument(activePath_) ? std::string{} : activePath_,
        editorText(), line, column);
}

void MainWindow::ToggleBottomPanelClick(IInspectable const&, RoutedEventArgs const&) {
    bottomPanelVisible_ = !bottomPanelVisible_;
    BottomToolPanel().Visibility(bottomPanelVisible_ ? Visibility::Visible : Visibility::Collapsed);
    BottomPanelRow().Height(GridLength{
        bottomPanelVisible_ ? bottomPanelHeight_ : 0.0, GridUnitType::Pixel});
    scheduleWorkbenchStateSave();
}

fire_and_forget MainWindow::OpenSearchEverywhereClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Search Everywhere"));
    dialog.PrimaryButtonText(L"Open");
    dialog.CloseButtonText(L"Close");
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBox query;
    query.PlaceholderText(L"Files, symbols, and text");
    panel.Children().Append(query);
    ListView results;
    results.MinWidth(680);
    results.MinHeight(360);
    panel.Children().Append(results);
    dialog.Content(panel);
    searchEverywhereDialogResults_ = results;
    const auto weak = get_weak();
    query.TextChanged([weak](IInspectable const& sender, TextChangedEventArgs const&) {
        if (const auto self = weak.get()) {
            const auto value = utf8(sender.as<TextBox>().Text());
            if (!value.empty()) self->session_->searchEverywhere(value);
        }
    });
    query.Focus(FocusState::Programmatic);
    const auto result = co_await showDialog(dialog);
    if (result == ContentDialogResult::Primary && results.SelectedItem()) {
        const auto key = objectKey(results.SelectedItem());
        if (const auto found = navigationTargets_.find(key); found != navigationTargets_.end()) {
            openDocument(found->second.relativePath, found->second.line,
                         found->second.utf16Column);
        }
    }
    clearNavigationList(results);
    searchEverywhereDialogResults_ = nullptr;
}

fire_and_forget MainWindow::OpenProjectReplaceClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (session_->workspaceRoot().empty()) {
        setStatus("Open a workspace first");
        co_return;
    }
    cacheCurrentDocument();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Replace in Project")));
    dialog.PrimaryButtonText(ui("Preview"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBox query;
    query.Header(box_value(ui("Find")));
    panel.Children().Append(query);
    TextBox replacement;
    replacement.Header(box_value(ui("Replace with")));
    panel.Children().Append(replacement);
    StackPanel options;
    options.Orientation(Orientation::Horizontal);
    options.Spacing(12);
    CheckBox matchCase;
    matchCase.Content(box_value(ui("Match Case")));
    options.Children().Append(matchCase);
    CheckBox wholeWords;
    wholeWords.Content(box_value(ui("Whole Words")));
    options.Children().Append(wholeWords);
    CheckBox regex;
    regex.Content(box_value(ui("Regex")));
    options.Children().Append(regex);
    CheckBox preserveCase;
    preserveCase.Content(box_value(ui("Preserve Case")));
    options.Children().Append(preserveCase);
    panel.Children().Append(options);
    TextBox fileMask;
    fileMask.Header(box_value(ui("File mask")));
    fileMask.PlaceholderText(L"*.java, *.kt");
    panel.Children().Append(fileMask);
    dialog.Content(panel);
    query.Focus(FocusState::Programmatic);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto queryText = utf8(query.Text());
    if (queryText.empty()) {
        setStatus("Enter text to replace");
        co_return;
    }
    lithe::windows::ReplacementPreviewRequestDto request;
    request.query = queryText;
    request.replacement = utf8(replacement.Text());
    const auto checked = [](CheckBox const& box) {
        const auto value = box.IsChecked();
        return value && value.Value();
    };
    request.caseSensitive = checked(matchCase);
    request.wholeWords = checked(wholeWords);
    request.regularExpression = checked(regex);
    request.preserveCase = checked(preserveCase) && !request.caseSensitive;
    request.fileMask = utf8(fileMask.Text());
    request.hiddenDirectoryNames = session_->settings().hiddenDirectoryNames;
    request.hiddenFilePatterns = session_->settings().hiddenFilePatterns;
    for (const auto& path : dirtyPaths_) {
        if (const auto found = openDocuments_.find(path); found != openDocuments_.end()) {
            request.textOverrides.emplace(path, found->second);
        }
    }
    setStatus("Building replacement preview...");
    session_->previewProjectReplacement(std::move(request));
}

fire_and_forget MainWindow::showProjectReplacementPreview(
    lithe::windows::app::ReplacementFeatureState state) {
    const auto lifetime = get_strong();
    if (state.error || state.isLoading || !state.preview) co_return;
    if (state.preview->files.empty()) {
        setStatus("No replacement matches");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Replacement Preview")));
    dialog.PrimaryButtonText(ui("Apply Selected"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Close);
    ScrollViewer scroll;
    scroll.MinWidth(700);
    scroll.MaxHeight(520);
    StackPanel content;
    content.Spacing(5);
    std::vector<CheckBox> selections;
    selections.reserve(state.preview->files.size());
    for (const auto& file : state.preview->files) {
        std::uint64_t count = 0;
        for (const auto& match : file.matches) count += match.occurrenceCount;
        StackPanel detail;
        TextBlock title;
        title.Text(text(file.path + "  (" + std::to_string(count) + " matches)"));
        title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        detail.Children().Append(title);
        for (std::size_t index = 0; index < std::min<std::size_t>(file.matches.size(), 3); ++index) {
            const auto& match = file.matches[index];
            TextBlock line;
            line.Text(text("Line " + std::to_string(match.line) + ": " +
                           match.before + "  ->  " + match.after));
            line.TextTrimming(TextTrimming::CharacterEllipsis);
            line.Foreground(applicationBrush(L"LitheMutedTextBrush"));
            detail.Children().Append(line);
        }
        CheckBox selected;
        selected.IsChecked(true);
        selected.Content(detail);
        selections.push_back(selected);
        content.Children().Append(selected);
    }
    scroll.Content(content);
    dialog.Content(scroll);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    std::vector<lithe::windows::ReplacementFileDto> selectedFiles;
    for (std::size_t index = 0; index < selections.size(); ++index) {
        const auto checked = selections[index].IsChecked();
        if (checked && checked.Value()) selectedFiles.push_back(state.preview->files[index]);
    }
    if (selectedFiles.empty()) {
        setStatus("Select one or more files to replace");
        co_return;
    }
    cacheCurrentDocument();
    std::unordered_map<std::string, std::string> dirtyTexts;
    for (const auto& path : dirtyPaths_) {
        if (const auto found = openDocuments_.find(path); found != openDocuments_.end()) {
            dirtyTexts.emplace(path, found->second);
        }
    }
    session_->applyProjectReplacements(std::move(selectedFiles), std::move(dirtyTexts));
}

fire_and_forget MainWindow::renderProjectReplacementApplied(
    lithe::windows::winui::ProjectReplacementApplyResult result) {
    const auto lifetime = get_strong();
    bool activeChanged = false;
    for (const auto& file : result.appliedFiles) {
        if (openDocuments_.contains(file.path)) openDocuments_[file.path] = file.replacementText;
        dirtyPaths_.erase(file.path);
        updateTabHeader(file.path);
        activeChanged = activeChanged || file.path == activePath_;
    }
    if (activeChanged) session_->openDocument(activePath_);
    if (result.changedSincePreview.empty() && result.failedPaths.empty()) co_return;
    std::string message;
    if (!result.changedSincePreview.empty()) {
        message += countLabel(result.changedSincePreview.size(),
            "file(s) changed after Preview and were skipped", "个文件在预览后发生变化，已跳过",
            simplifiedChinese_);
    }
    if (!result.failedPaths.empty()) {
        if (!message.empty()) message += "\n";
        message += countLabel(result.failedPaths.size(),
            "file(s) could not be updated", "个文件无法更新", simplifiedChinese_);
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Project Replace Incomplete")));
    dialog.Content(box_value(text(message)));
    dialog.CloseButtonText(ui("Close"));
    co_await showDialog(dialog);
}

void MainWindow::FocusFindClick(IInspectable const&, RoutedEventArgs const&) {
    FindBar().Height(38);
    FindBar().Visibility(Visibility::Visible);
    FindTextBox().Focus(FocusState::Programmatic);
    FindTextBox().SelectAll();
    rebuildFindMatches();
}

void MainWindow::CloseFindClick(IInspectable const&, RoutedEventArgs const&) {
    FindBar().Height(0);
    FindBar().Visibility(Visibility::Collapsed);
    EditorTextBox().Focus(FocusState::Programmatic);
}

void MainWindow::FindNextClick(IInspectable const&, RoutedEventArgs const&) {
    selectFindMatch(true);
}

void MainWindow::FindPreviousClick(IInspectable const&, RoutedEventArgs const&) {
    selectFindMatch(false);
}

void MainWindow::FindOptionChanged(IInspectable const&, RoutedEventArgs const&) {
    rebuildFindMatches();
}

fire_and_forget MainWindow::ShowCommandPaletteClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    struct CommandEntry {
        std::string id;
        std::string label;
    };
    static const std::vector<CommandEntry> commands{
        {"project.open", "Open Project..."},
        {"project.close", "Close Project"},
        {"project.welcome", "Welcome / Switch Workspace"},
        {"project.clone", "Clone Repository..."},
        {"project.refresh", "Refresh Project"},
        {"project.reveal", "Show Workspace in Explorer"},
        {"file.save", "Save Document"},
        {"file.find", "Find in File"},
        {"file.reveal", "Show in Explorer"},
        {"file.new", "New File"},
        {"directory.new", "New Directory"},
        {"markdown.preview", "Preview Markdown"},
        {"search.everywhere", "Search Everywhere"},
        {"search.workspace", "Search Workspace"},
        {"replace.project", "Replace in Project..."},
        {"history.local", "Local History"},
        {"git.refresh", "Refresh Git"},
        {"git.history", "Git History"},
        {"git.stashes", "Git Stashes"},
        {"git.shelves", "Git Shelves"},
        {"git.compare", "Compare Git Reference"},
        {"git.switch", "Switch Git Branch"},
        {"git.create", "Create Git Branch"},
        {"git.blame", "Toggle Git Blame"},
        {"git.stage-all", "Stage All Changes"},
        {"git.commit", "Commit Changes"},
        {"git.generate-message", "Generate AI Commit Message"},
        {"java.run", "Run Current Java File"},
        {"java.spring", "Run Spring Boot"},
        {"java.stop", "Stop Java"},
        {"java.debug", "Debug Current Java File"},
        {"debug.stop", "Stop Debugger"},
        {"terminal.open", "Open Terminal"},
        {"terminal.new", "New Terminal"},
        {"terminal.stop", "Stop Terminal"},
        {"maven.test", "Run Maven Test"},
        {"tool.toggle", "Toggle Tool Window"},
        {"settings.open", "Settings..."},
        {"updates.check", "Check for Updates"},
    };
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Command Palette"));
    dialog.PrimaryButtonText(L"Run");
    dialog.CloseButtonText(L"Close");
    dialog.DefaultButton(ContentDialogButton::Primary);
    StackPanel panel;
    panel.Spacing(8);
    TextBox query;
    query.PlaceholderText(L"Type a command");
    panel.Children().Append(query);
    ListView list;
    list.MinWidth(520);
    list.MinHeight(320);
    panel.Children().Append(list);
    const auto render = [this, list](std::string filter) {
        list.Items().Clear();
        for (const auto& command : commands) {
            const auto label = localizedText(command.label, simplifiedChinese_);
            if (!lithe::windows::algorithms::fuzzySubsequenceMatch(command.label, filter) &&
                !lithe::windows::algorithms::fuzzySubsequenceMatch(label, filter)) continue;
            list.Items().Append(makeListItem(label, command.id));
        }
        list.SelectedIndex(list.Items().Size() > 0 ? 0 : -1);
    };
    query.TextChanged([render](IInspectable const& sender, TextChangedEventArgs const&) {
        render(utf8(sender.as<TextBox>().Text()));
    });
    render({});
    dialog.Content(panel);
    query.Focus(FocusState::Programmatic);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto command = itemTag(list.SelectedItem());
    if (command == "project.open") OpenWorkspaceClick(nullptr, RoutedEventArgs{});
    else if (command == "project.close") CloseWorkspaceClick(nullptr, RoutedEventArgs{});
    else if (command == "project.welcome") ShowWelcomeClick(nullptr, RoutedEventArgs{});
    else if (command == "project.clone") CloneRepositoryClick(nullptr, RoutedEventArgs{});
    else if (command == "project.refresh") RefreshWorkspaceClick(nullptr, RoutedEventArgs{});
    else if (command == "project.reveal") RevealWorkspaceClick(nullptr, RoutedEventArgs{});
    else if (command == "file.save") SaveDocumentClick(nullptr, RoutedEventArgs{});
    else if (command == "file.find") FocusFindClick(nullptr, RoutedEventArgs{});
    else if (command == "file.reveal") {
        if (selectedTreePath().empty()) RevealWorkspaceClick(nullptr, RoutedEventArgs{});
        else RevealSelectedItemClick(nullptr, RoutedEventArgs{});
    } else if (command == "file.new") NewFileClick(nullptr, RoutedEventArgs{});
    else if (command == "directory.new") NewDirectoryClick(nullptr, RoutedEventArgs{});
    else if (command == "markdown.preview") PreviewMarkdownClick(nullptr, RoutedEventArgs{});
    else if (command == "search.everywhere") OpenSearchEverywhereClick(nullptr, RoutedEventArgs{});
    else if (command == "search.workspace") {
        SidebarTabs().SelectedIndex(2);
        WorkspaceSearchBox().Focus(FocusState::Programmatic);
        WorkspaceSearchBox().SelectAll();
    } else if (command == "replace.project") OpenProjectReplaceClick(nullptr, RoutedEventArgs{});
    else if (command == "history.local") {
        GitModeTabs().SelectedIndex(3);
        showBottomTool(4);
        session_->loadHistory(activePath_.empty() || isExternalDocument(activePath_)
            ? std::nullopt : std::optional<std::string>(activePath_));
    } else if (command == "git.refresh") RefreshGitClick(nullptr, RoutedEventArgs{});
    else if (command == "git.history") LoadGitHistoryClick(nullptr, RoutedEventArgs{});
    else if (command == "git.stashes") LoadGitStashesClick(nullptr, RoutedEventArgs{});
    else if (command == "git.shelves") LoadShelvesClick(nullptr, RoutedEventArgs{});
    else if (command == "git.compare") CompareReferenceClick(nullptr, RoutedEventArgs{});
    else if (command == "git.switch") SwitchReferenceClick(nullptr, RoutedEventArgs{});
    else if (command == "git.create") CreateBranchClick(nullptr, RoutedEventArgs{});
    else if (command == "git.blame") ToggleBlameClick(nullptr, RoutedEventArgs{});
    else if (command == "git.stage-all") StageAllClick(nullptr, RoutedEventArgs{});
    else if (command == "git.commit") CommitClick(nullptr, RoutedEventArgs{});
    else if (command == "git.generate-message") GenerateAICommitClick(nullptr, RoutedEventArgs{});
    else if (command == "java.run") RunCurrentJavaClick(nullptr, RoutedEventArgs{});
    else if (command == "java.spring") RunSpringBootClick(nullptr, RoutedEventArgs{});
    else if (command == "java.stop") StopJavaClick(nullptr, RoutedEventArgs{});
    else if (command == "java.debug") DebugCurrentJavaClick(nullptr, RoutedEventArgs{});
    else if (command == "debug.stop") StopDebuggerClick(nullptr, RoutedEventArgs{});
    else if (command == "terminal.open") StartTerminalClick(nullptr, RoutedEventArgs{});
    else if (command == "terminal.new") NewTerminalClick(nullptr, RoutedEventArgs{});
    else if (command == "terminal.stop") StopTerminalClick(nullptr, RoutedEventArgs{});
    else if (command == "maven.test") RunMavenTestClick(nullptr, RoutedEventArgs{});
    else if (command == "tool.toggle") ToggleBottomPanelClick(nullptr, RoutedEventArgs{});
    else if (command == "settings.open") ShowSettingsClick(nullptr, RoutedEventArgs{});
    else if (command == "updates.check") CheckForUpdatesClick(nullptr, RoutedEventArgs{});
}

fire_and_forget MainWindow::ShowSettingsClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    enum class SettingsAction { None, ConfigureAI, CheckUpdates };
    SettingsAction action = SettingsAction::None;
    const auto current = session_->settings();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Settings"));
    dialog.PrimaryButtonText(L"Save");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Primary);
    ScrollViewer scroll;
    scroll.MaxHeight(580);
    StackPanel panel;
    panel.MinWidth(600);
    panel.Spacing(8);

    TextBlock editorHeading;
    editorHeading.Text(L"EDITOR");
    editorHeading.Style(Application::Current().Resources()
                            .Lookup(box_value(L"LithePaneHeaderStyle")).as<Style>());
    panel.Children().Append(editorHeading);
    NumberBox fontSize;
    fontSize.Header(box_value(L"Editor font size"));
    fontSize.Minimum(9);
    fontSize.Maximum(32);
    fontSize.SmallChange(0.5);
    fontSize.Value(current.editorFontSize);
    panel.Children().Append(fontSize);
    ToggleSwitch codeVision;
    codeVision.Header(box_value(L"Show code vision and implementation markers"));
    codeVision.IsOn(current.showCodeVision);
    panel.Children().Append(codeVision);
    ToggleSwitch inlayHints;
    inlayHints.Header(box_value(L"Show Java inlay hints"));
    inlayHints.IsOn(current.showInlayHints);
    panel.Children().Append(inlayHints);

    TextBlock projectHeading;
    projectHeading.Text(L"PROJECT");
    projectHeading.Margin(Thickness{0, 10, 0, 0});
    projectHeading.Style(editorHeading.Style());
    panel.Children().Append(projectHeading);
    TextBox hiddenDirectories;
    hiddenDirectories.Header(box_value(L"Hidden directories (comma-separated)"));
    hiddenDirectories.Text(text(joinValues(current.hiddenDirectoryNames)));
    panel.Children().Append(hiddenDirectories);
    TextBox hiddenFiles;
    hiddenFiles.Header(box_value(L"Hidden file patterns (comma-separated)"));
    hiddenFiles.Text(text(joinValues(current.hiddenFilePatterns)));
    panel.Children().Append(hiddenFiles);

    TextBlock generalHeading;
    generalHeading.Text(L"GENERAL");
    generalHeading.Margin(Thickness{0, 10, 0, 0});
    generalHeading.Style(editorHeading.Style());
    panel.Children().Append(generalHeading);
    TextBlock workspaceInfo;
    workspaceInfo.Text(text(localizedText("Workspace", simplifiedChinese_) + ": " +
        (session_->workspaceRoot().empty()
            ? localizedText("No workspace open", simplifiedChinese_)
            : pathUtf8(session_->workspaceRoot()))));
    workspaceInfo.TextTrimming(TextTrimming::CharacterEllipsis);
    panel.Children().Append(workspaceInfo);
    TextBlock coreInfo;
    coreInfo.Text(text("Rust Core: " + session_->coreVersion()));
    coreInfo.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(coreInfo);
    ComboBox language;
    language.Header(box_value(L"Interface language"));
    language.Items().Append(box_value(L"System default"));
    language.Items().Append(box_value(L"English"));
    language.Items().Append(box_value(L"Simplified Chinese"));
    language.SelectedIndex(current.uiLanguage == "en" ? 1 : current.uiLanguage == "zh_CN" ? 2 : 0);
    panel.Children().Append(language);
    TextBox dataDirectory;
    dataDirectory.Header(box_value(L"Data directory"));
    dataDirectory.PlaceholderText(L"Leave empty for the system default");
    dataDirectory.Text(text(current.dataDirectory));
    panel.Children().Append(dataDirectory);
    TextBox shell;
    shell.Header(box_value(L"Terminal shell executable"));
    shell.PlaceholderText(L"Automatic: ComSpec or cmd.exe");
    shell.Text(text(current.terminalShellPath));
    panel.Children().Append(shell);

    TextBlock aiHeading;
    aiHeading.Text(L"AI AND COMMIT");
    aiHeading.Margin(Thickness{0, 10, 0, 0});
    aiHeading.Style(editorHeading.Style());
    panel.Children().Append(aiHeading);
    const auto aiSettings = session_->loadAICommitSettings();
    TextBlock aiStatus;
    if (aiSettings.providers.empty()) {
        aiStatus.Text(L"No AI commit-message provider configured.");
    } else {
        aiStatus.Text(text(localizedText("Provider", simplifiedChinese_) + ": " +
                           aiSettings.providers.front().name + "  " +
                           localizedText("Model", simplifiedChinese_) + ": " +
                           aiSettings.providers.front().model));
    }
    aiStatus.TextWrapping(TextWrapping::Wrap);
    aiStatus.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(aiStatus);
    Button configureAI;
    configureAI.Content(box_value(L"Configure AI commit messages..."));
    configureAI.HorizontalAlignment(HorizontalAlignment::Left);
    configureAI.Click([&dialog, &action](IInspectable const&, RoutedEventArgs const&) {
        action = SettingsAction::ConfigureAI;
        dialog.Hide();
    });
    panel.Children().Append(configureAI);

    TextBlock updatesHeading;
    updatesHeading.Text(L"UPDATES");
    updatesHeading.Margin(Thickness{0, 10, 0, 0});
    updatesHeading.Style(editorHeading.Style());
    panel.Children().Append(updatesHeading);
    TextBlock updatesInfo;
    updatesInfo.Text(L"Windows releases are downloaded only after SHA-256 and Authenticode verification.");
    updatesInfo.TextWrapping(TextWrapping::Wrap);
    updatesInfo.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    panel.Children().Append(updatesInfo);
    Button checkUpdates;
    checkUpdates.Content(box_value(L"Check for updates"));
    checkUpdates.HorizontalAlignment(HorizontalAlignment::Left);
    checkUpdates.Click([&dialog, &action](IInspectable const&, RoutedEventArgs const&) {
        action = SettingsAction::CheckUpdates;
        dialog.Hide();
    });
    panel.Children().Append(checkUpdates);
    scroll.Content(panel);
    dialog.Content(scroll);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) {
        if (action == SettingsAction::ConfigureAI) {
            ConfigureAICommitClick(nullptr, RoutedEventArgs{});
        } else if (action == SettingsAction::CheckUpdates) {
            CheckForUpdatesClick(nullptr, RoutedEventArgs{});
        }
        co_return;
    }

    auto settings = current;
    settings.editorFontSize = fontSize.Value();
    settings.showCodeVision = codeVision.IsOn();
    settings.showInlayHints = inlayHints.IsOn();
    settings.uiLanguage = language.SelectedIndex() == 1 ? "en"
        : language.SelectedIndex() == 2 ? "zh_CN" : "system";
    settings.dataDirectory = utf8(dataDirectory.Text());
    settings.terminalShellPath = utf8(shell.Text());
    settings.hiddenDirectoryNames = splitValues(utf8(hiddenDirectories.Text()));
    settings.hiddenFilePatterns = splitValues(utf8(hiddenFiles.Text()));
    const bool languageChanged =
        lithe::windows::app::normalizeUiLanguage(settings.uiLanguage) !=
        lithe::windows::app::normalizeUiLanguage(current.uiLanguage);
    const bool dataDirectoryChanged =
        lithe::windows::app::normalizeDataDirectory(settings.dataDirectory) !=
        lithe::windows::app::normalizeDataDirectory(current.dataDirectory);
    if (session_->saveSettings(std::move(settings))) {
        EditorTextBox().FontSize(session_->settings().editorFontSize);
        LineNumbersText().FontSize(session_->settings().editorFontSize);
        GutterAnnotationsText().FontSize(session_->settings().editorFontSize);
        updateEditorPresentation();
        if (languageChanged || dataDirectoryChanged) {
            setStatus("Restart Lithe to apply the interface language or data directory.");
        }
    }
}

Windows::Foundation::IAsyncOperation<bool> MainWindow::configureAICommitSettings() {
    auto settings = session_->loadAICommitSettings();
    lithe::windows::app::AICommitProvider provider;
    if (!settings.providers.empty()) provider = settings.providers.front();
    if (provider.endpoint.empty()) provider.endpoint = "https://api.openai.com/v1";
    if (provider.model.empty()) provider.model = "gpt-4.1-mini";
    provider.id = "default";
    provider.name = "Default";
    provider.apiKeyIdentifier = "lithe/ai/default/api-key";

    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"AI Commit Message Settings"));
    dialog.PrimaryButtonText(L"Save");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Primary);
    ScrollViewer scroll;
    scroll.MaxHeight(600);
    StackPanel panel;
    panel.MinWidth(590);
    panel.Spacing(8);
    TextBox endpoint;
    endpoint.Header(box_value(L"Endpoint"));
    endpoint.Text(text(provider.endpoint));
    panel.Children().Append(endpoint);
    TextBox model;
    model.Header(box_value(L"Model"));
    model.Text(text(provider.model));
    panel.Children().Append(model);
    PasswordBox apiKey;
    apiKey.Header(box_value(L"API key"));
    apiKey.PlaceholderText(L"Leave blank to keep the stored key");
    panel.Children().Append(apiKey);
    ComboBox protocol;
    protocol.Header(box_value(L"Protocol"));
    protocol.Items().Append(box_value(L"OpenAI Responses"));
    protocol.Items().Append(box_value(L"OpenAI Chat Completions"));
    protocol.Items().Append(box_value(L"Anthropic Messages"));
    protocol.SelectedIndex(static_cast<int32_t>(provider.protocol));
    panel.Children().Append(protocol);
    ComboBox authentication;
    authentication.Header(box_value(L"Authentication"));
    authentication.Items().Append(box_value(L"Bearer"));
    authentication.Items().Append(box_value(L"API key header"));
    authentication.SelectedIndex(static_cast<int32_t>(provider.authentication));
    panel.Children().Append(authentication);
    ComboBox language;
    language.Header(box_value(L"Message language"));
    language.Items().Append(box_value(L"English"));
    language.Items().Append(box_value(L"Simplified Chinese"));
    language.SelectedIndex(static_cast<int32_t>(settings.language));
    panel.Children().Append(language);
    ComboBox format;
    format.Header(box_value(L"Commit format"));
    for (const auto* value : {L"Conventional", L"Concise", L"Imperative",
                              L"Descriptive", L"Release note", L"Custom"}) {
        format.Items().Append(box_value(hstring(value)));
    }
    format.SelectedIndex(static_cast<int32_t>(settings.format));
    panel.Children().Append(format);
    TextBox custom;
    custom.Header(box_value(L"Custom instructions"));
    custom.Text(text(settings.customInstructions));
    panel.Children().Append(custom);
    ComboBox reasoning;
    reasoning.Header(box_value(L"Reasoning effort"));
    reasoning.Items().Append(box_value(L"low"));
    reasoning.Items().Append(box_value(L"medium"));
    reasoning.Items().Append(box_value(L"high"));
    reasoning.SelectedIndex(settings.reasoningEffort == "high" ? 2
        : settings.reasoningEffort == "medium" ? 1 : 0);
    panel.Children().Append(reasoning);
    NumberBox subjectLength;
    subjectLength.Header(box_value(L"Maximum subject length"));
    subjectLength.Minimum(20);
    subjectLength.Maximum(200);
    subjectLength.Value(static_cast<double>(settings.subjectMaximumLength));
    panel.Children().Append(subjectLength);
    NumberBox diffLimit;
    diffLimit.Header(box_value(L"Maximum diff characters"));
    diffLimit.Minimum(8000);
    diffLimit.Maximum(200000);
    diffLimit.Value(static_cast<double>(settings.maximumDiffCharacters));
    panel.Children().Append(diffLimit);
    ToggleSwitch includeBody;
    includeBody.Header(box_value(L"Allow a short commit body"));
    includeBody.IsOn(settings.includeBody);
    panel.Children().Append(includeBody);
    ToggleSwitch insecure;
    insecure.Header(box_value(L"Allow insecure HTTP"));
    insecure.IsOn(provider.allowsInsecureHTTP);
    panel.Children().Append(insecure);
    scroll.Content(panel);
    dialog.Content(scroll);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return false;

    provider.endpoint = utf8(endpoint.Text());
    provider.model = utf8(model.Text());
    provider.protocol = static_cast<lithe::windows::app::AICommitAPIProtocol>(
        std::max(0, protocol.SelectedIndex()));
    provider.authentication = static_cast<lithe::windows::app::AICommitAuthentication>(
        std::max(0, authentication.SelectedIndex()));
    provider.allowsInsecureHTTP = insecure.IsOn();
    settings.providers = {provider};
    settings.activeProviderID = provider.id;
    settings.language = static_cast<lithe::windows::app::AICommitLanguage>(
        std::max(0, language.SelectedIndex()));
    settings.format = static_cast<lithe::windows::app::AICommitFormat>(
        std::max(0, format.SelectedIndex()));
    settings.customInstructions = utf8(custom.Text());
    settings.reasoningEffort = reasoning.SelectedIndex() == 2 ? "high"
        : reasoning.SelectedIndex() == 1 ? "medium" : "low";
    settings.subjectMaximumLength = static_cast<std::size_t>(subjectLength.Value());
    settings.maximumDiffCharacters = static_cast<std::size_t>(diffLimit.Value());
    settings.includeBody = includeBody.IsOn();
    std::string error;
    if (!session_->saveAICommitSettings(settings, utf8(apiKey.Password()), error)) {
        setStatus("Could not save AI settings: " + error);
        co_return false;
    }
    co_return true;
}

fire_and_forget MainWindow::GenerateAICommitClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    auto settings = session_->loadAICommitSettings();
    if (settings.providers.empty()) {
        if (!(co_await configureAICommitSettings())) co_return;
        settings = session_->loadAICommitSettings();
    }
    showBottomTool(4);
    session_->generateAICommitMessage(std::move(settings));
}

fire_and_forget MainWindow::ConfigureAICommitClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    co_await configureAICommitSettings();
}

void MainWindow::CheckForUpdatesClick(IInspectable const&, RoutedEventArgs const&) {
#if defined(_M_ARM64)
    session_->checkForUpdates("arm64");
#elif defined(_M_X64)
    session_->checkForUpdates("x64");
#else
    session_->checkForUpdates("x86");
#endif
}

void MainWindow::ProjectItemInvoked(
    TreeView const&, TreeViewItemInvokedEventArgs const& event) {
    const auto node = event.InvokedItem().try_as<TreeViewNode>();
    if (!node) return;
    const auto found = treePaths_.find(objectKey(node));
    if (found == treePaths_.end()) return;
    if (directoryPaths_.contains(found->second)) {
        node.IsExpanded(!node.IsExpanded());
        return;
    }
    openDocument(found->second);
}

void MainWindow::ProjectTreeRightTapped(
    IInspectable const&, Input::RightTappedRoutedEventArgs const&) {
    if (!ProjectTree().SelectedNode() && ProjectTree().RootNodes().Size() > 0) {
        ProjectTree().SelectedNode(ProjectTree().RootNodes().GetAt(0));
    }
}

std::string MainWindow::selectedTreePath() {
    const auto node = ProjectTree().SelectedNode();
    if (!node) return {};
    const auto found = treePaths_.find(objectKey(node));
    return found == treePaths_.end() ? std::string{} : found->second;
}

std::string MainWindow::selectedTreeParentPath() {
    const auto selected = selectedTreePath();
    if (selected.empty() || directoryPaths_.contains(selected)) return selected;
    return parentPath(selected);
}

fire_and_forget MainWindow::NewFileClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"New File"));
    dialog.PrimaryButtonText(L"Create");
    dialog.CloseButtonText(L"Cancel");
    TextBox name;
    name.Header(box_value(L"Name"));
    dialog.Content(name);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->createWorkspaceItem(selectedTreeParentPath(), utf8(name.Text()), false);
    }
}

fire_and_forget MainWindow::NewDirectoryClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"New Directory"));
    dialog.PrimaryButtonText(L"Create");
    dialog.CloseButtonText(L"Cancel");
    TextBox name;
    name.Header(box_value(L"Name"));
    dialog.Content(name);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->createWorkspaceItem(selectedTreeParentPath(), utf8(name.Text()), true);
    }
}

fire_and_forget MainWindow::RenameWorkspaceItemClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto selected = selectedTreePath();
    if (selected.empty()) {
        setStatus("Select a workspace item to rename");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Rename Workspace Item"));
    dialog.PrimaryButtonText(L"Rename");
    dialog.CloseButtonText(L"Cancel");
    TextBox name;
    name.Header(box_value(L"Name"));
    name.Text(text(fileName(selected)));
    dialog.Content(name);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        const auto newName = utf8(name.Text());
        const auto parent = parentPath(selected);
        const auto destination = parent.empty() ? newName : parent + "/" + newName;
        const auto weak = get_weak();
        const auto dispatcher = dispatcher_;
        session_->renameWorkspaceItem(selected, newName,
            [weak, dispatcher, selected, destination](bool succeeded, std::string error) mutable {
                dispatcher.TryEnqueue(
                    [weak, selected, destination, succeeded,
                     error = std::move(error)]() mutable {
                        const auto self = weak.get();
                        if (!self) return;
                        if (succeeded) self->remapEditorPaths(selected, destination);
                        if (!error.empty()) self->setStatus(std::move(error));
                    });
            });
    }
}

fire_and_forget MainWindow::DuplicateWorkspaceItemClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto selected = selectedTreePath();
    if (selected.empty()) {
        setStatus("Select a workspace item to duplicate");
        co_return;
    }
    const auto sourceName = fileName(selected);
    const auto sourcePath = pathFromUtf8(sourceName);
    const auto stem = pathUtf8(sourcePath.stem());
    const auto extension = pathUtf8(sourcePath.extension());
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Duplicate Workspace Item"));
    dialog.PrimaryButtonText(L"Duplicate");
    dialog.CloseButtonText(L"Cancel");
    TextBox name;
    name.Header(box_value(L"Name"));
    name.Text(text(stem + " copy" + extension));
    dialog.Content(name);
    if (co_await showDialog(dialog) == ContentDialogResult::Primary) {
        session_->duplicateWorkspaceItem(selected, utf8(name.Text()));
    }
}

fire_and_forget MainWindow::DeleteWorkspaceItemClick(IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    const auto selected = selectedTreePath();
    if (selected.empty()) {
        setStatus("Select a workspace item to delete");
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(text("Delete " + fileName(selected) + "?")));
    const auto containsSelected = [&selected](const std::string& path) {
        return path == selected || path.starts_with(selected + "/");
    };
    const auto dirtyCount = std::count_if(
        dirtyPaths_.begin(), dirtyPaths_.end(), containsSelected);
    auto warning = localizedText("This operation cannot be undone by Lithe.", simplifiedChinese_);
    if (dirtyCount > 0) {
        warning += "\n" + countLabel(dirtyCount,
            "open file(s) contain unsaved changes and will be closed",
            "个打开的文件包含未保存更改，并将被关闭", simplifiedChinese_);
    }
    dialog.Content(box_value(text(warning)));
    dialog.PrimaryButtonText(L"Delete");
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;
    const auto weak = get_weak();
    const auto dispatcher = dispatcher_;
    session_->deleteWorkspaceItem(selected,
        [weak, dispatcher, selected](bool succeeded, std::string error) mutable {
            dispatcher.TryEnqueue([weak, selected, succeeded,
                                   error = std::move(error)]() mutable {
                const auto self = weak.get();
                if (!self) return;
                if (!succeeded) {
                    if (!error.empty()) self->setStatus(std::move(error));
                    return;
                }
                for (uint32_t index = 0;
                     index < self->EditorTabs().TabItems().Size();) {
                    const auto tab = self->EditorTabs().TabItems().GetAt(index)
                        .try_as<TabViewItem>();
                    const auto path = tab && tab.Tag()
                        ? utf8(unbox_value<hstring>(tab.Tag())) : std::string{};
                    if (path == selected || path.starts_with(selected + "/")) {
                        self->removeEditorTab(tab);
                    } else {
                        ++index;
                    }
                }
            });
        });
}

void MainWindow::CopyRelativePathClick(IInspectable const&, RoutedEventArgs const&) {
    const auto selected = selectedTreePath();
    if (!selected.empty()) copyText(selected);
}

void MainWindow::CopyAbsolutePathClick(IInspectable const&, RoutedEventArgs const&) {
    const auto absolute = session_->absoluteWorkspacePath(selectedTreePath());
    if (absolute) copyText(pathUtf8(*absolute));
}

void MainWindow::RevealSelectedItemClick(IInspectable const&, RoutedEventArgs const&) {
    const auto relative = selectedTreePath();
    const auto absolute = session_->absoluteWorkspacePath(relative);
    if (absolute) revealPath(*absolute, !directoryPaths_.contains(relative));
}

void MainWindow::ChangeItemClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto path = itemTag(event.ClickedItem());
    if (path.empty()) return;
    openDocument(path);
    session_->loadDiff({path});
}

void MainWindow::SearchResultClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto found = navigationTargets_.find(objectKey(event.ClickedItem()));
    if (found == navigationTargets_.end()) return;
    if (!found->second.relativePath.empty()) {
        openDocument(found->second.relativePath,
                     found->second.line, found->second.utf16Column);
    } else if (found->second.absolutePath) {
        openExternalDocument(*found->second.absolutePath,
                             found->second.line, found->second.utf16Column);
    }
}

void MainWindow::NavigationItemClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto found = navigationTargets_.find(objectKey(event.ClickedItem()));
    if (found == navigationTargets_.end()) return;
    if (!found->second.relativePath.empty()) {
        openDocument(found->second.relativePath, found->second.line,
                     found->second.utf16Column);
    } else if (found->second.absolutePath) {
        openExternalDocument(*found->second.absolutePath, found->second.line,
                             found->second.utf16Column);
    }
}

void MainWindow::GitHistoryItemClick(IInspectable const&, ItemClickEventArgs const& event) {
    selectedGitCommit_ = itemTag(event.ClickedItem());
    if (!selectedGitCommit_.empty()) session_->loadGitCommit(selectedGitCommit_);
}

void MainWindow::CommitFileClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto path = itemTag(event.ClickedItem());
    if (!path.empty() && !selectedGitCommit_.empty()) {
        session_->loadGitCommitDiff(selectedGitCommit_, path);
    }
}

void MainWindow::HistoryItemClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto contentPath = itemTag(event.ClickedItem());
    selectedHistoryContentPath_ = contentPath;
    const auto found = historyPaths_.find(objectKey(event.ClickedItem()));
    selectedHistoryPath_ = found == historyPaths_.end() ? std::string{} : found->second;
    loadedHistoryContent_.reset();
    pendingHistoryContentPath_.clear();
    if (contentPath.empty()) return;
    if (!selectedHistoryPath_.empty() && selectedHistoryPath_ != activePath_) {
        pendingHistoryContentPath_ = contentPath;
        openDocument(selectedHistoryPath_);
        return;
    }
    session_->loadHistoryContent(contentPath);
}

fire_and_forget MainWindow::RestoreHistoryClick(
    IInspectable const&, RoutedEventArgs const&) {
    const auto lifetime = get_strong();
    if (activePath_.empty() || isExternalDocument(activePath_)) {
        setStatus(localizedText(
            "Open a workspace file before restoring history", simplifiedChinese_));
        co_return;
    }
    if (selectedHistoryContentPath_.empty() || !loadedHistoryContent_) {
        setStatus(localizedText(
            "Select a Local History snapshot first", simplifiedChinese_));
        co_return;
    }
    if (!selectedHistoryPath_.empty() && selectedHistoryPath_ != activePath_) {
        setStatus(localizedText(
            "Select a snapshot for the active file", simplifiedChinese_));
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(ui("Restore Local History snapshot?")));
    dialog.Content(box_value(ui(
        "The selected snapshot will replace the current editor content and be saved to disk.")));
    dialog.PrimaryButtonText(ui("Restore"));
    dialog.CloseButtonText(L"Cancel");
    dialog.DefaultButton(ContentDialogButton::Close);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;

    const auto path = activePath_;
    const auto content = *loadedHistoryContent_;
    const auto current = editorText();
    const auto weak = get_weak();
    const auto dispatcher = dispatcher_;
    session_->restoreHistorySnapshot(path, content, current,
        [weak, dispatcher, path](bool succeeded, std::string error) mutable {
            dispatcher.TryEnqueue([weak, path, succeeded, error = std::move(error)]() mutable {
                const auto self = weak.get();
                if (!self) return;
                if (!succeeded) {
                    self->setStatus(error.empty() ? "History restore failed" : error);
                    return;
                }
                self->dirtyPaths_.erase(path);
                self->session_->openDocument(path);
                self->setStatus("Local History snapshot restored");
            });
        });
}

void MainWindow::DebugVariableClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto found = debugVariableIDs_.find(objectKey(event.ClickedItem()));
    if (found != debugVariableIDs_.end()) session_->toggleDebuggerVariable(found->second);
}

void MainWindow::GitStashSelectionChanged(IInspectable const&, SelectionChangedEventArgs const&) {
    selectedGitStash_ = itemTag(GitStashesList().SelectedItem());
}

void MainWindow::ShelfSelectionChanged(IInspectable const&, SelectionChangedEventArgs const&) {
    selectedShelf_ = itemTag(GitShelvesList().SelectedItem());
}

void MainWindow::DiffOverviewSelectionChanged(IInspectable const&, SelectionChangedEventArgs const&) {
    selectedHunk_ = itemTag(DiffOverviewList().SelectedItem());
}

void MainWindow::SidebarTabSelectionChanged(IInspectable const&, SelectionChangedEventArgs const&) {
    if (!restoringWorkbench_) scheduleWorkbenchStateSave();
}

void MainWindow::BottomToolSelectionChanged(IInspectable const&, SelectionChangedEventArgs const&) {
    if (!restoringWorkbench_) scheduleWorkbenchStateSave();
}

void MainWindow::WorkspaceSearchKeyDown(
    IInspectable const&, Input::KeyRoutedEventArgs const& event) {
    if (event.Key() != Windows::System::VirtualKey::Enter) return;
    const auto query = utf8(WorkspaceSearchBox().Text());
    if (!query.empty()) session_->search(query);
    event.Handled(true);
}

void MainWindow::FindBoxKeyDown(IInspectable const&, Input::KeyRoutedEventArgs const& event) {
    if (event.Key() == Windows::System::VirtualKey::Enter) {
        selectFindMatch(true);
        event.Handled(true);
    } else if (event.Key() == Windows::System::VirtualKey::Escape) {
        CloseFindClick(nullptr, RoutedEventArgs{});
        event.Handled(true);
    }
}

void MainWindow::TerminalInputKeyDown(
    IInspectable const&, Input::KeyRoutedEventArgs const& event) {
    if (event.Key() != Windows::System::VirtualKey::Enter) return;
    const auto input = utf8(TerminalInputBox().Text());
    if (!input.empty() && !activeTerminalID_.empty()) {
        session_->sendTerminal(activeTerminalID_, input);
    }
    TerminalInputBox().Text(L"");
    event.Handled(true);
}

void MainWindow::DebugExpressionKeyDown(
    IInspectable const&, Input::KeyRoutedEventArgs const& event) {
    if (event.Key() != Windows::System::VirtualKey::Enter) return;
    const auto expression = utf8(DebugExpressionBox().Text());
    if (!expression.empty()) {
        session_->evaluateDebugger(expression);
        DebugExpressionBox().Text(L"");
    }
    event.Handled(true);
}

void MainWindow::RootKeyDown(IInspectable const&, Input::KeyRoutedEventArgs const& event) {
    if (event.Key() != Windows::System::VirtualKey::Shift) return;
    const auto now = std::chrono::steady_clock::now();
    if (lastShiftPress_.time_since_epoch().count() != 0 &&
        now - lastShiftPress_ < std::chrono::milliseconds(500)) {
        lastShiftPress_ = {};
        OpenSearchEverywhereClick(nullptr, RoutedEventArgs{});
        event.Handled(true);
    } else {
        lastShiftPress_ = now;
    }
}

void MainWindow::EditorTextChanged(IInspectable const&, RoutedEventArgs const&) {
    if (editorUpdating_ || editorFormatting_ || activePath_.empty() ||
        isExternalDocument(activePath_)) return;
    openDocuments_[activePath_] = editorText();
    dirtyPaths_.insert(activePath_);
    session_->setDocumentText(openDocuments_[activePath_]);
    if (isJavaPath(activePath_)) {
        session_->changeJavaDocument(activePath_, openDocuments_[activePath_]);
    }
    if (MarkdownPreviewPane().Visibility() == Visibility::Visible) {
        renderMarkdownPreview(openDocuments_[activePath_]);
    }
    updateTabHeader(activePath_);
    updateEditorPresentation();
}

void MainWindow::EditorSelectionChanged(IInspectable const&, RoutedEventArgs const&) {
    updateCursorPosition();
}

void MainWindow::EditorLoaded(IInspectable const&, RoutedEventArgs const&) {
    configureEditorScroll();
}

void MainWindow::EditorGutterPointerPressed(
    IInspectable const&, Input::PointerRoutedEventArgs const& event) {
    if (activePath_.empty()) return;
    const auto point = event.GetCurrentPoint(EditorGutter()).Position();
    const auto source = editorText();
    const auto lineCount = static_cast<std::size_t>(
        1 + std::count(source.begin(), source.end(), '\n'));
    const auto scrollOffset = editorScrollViewer_
        ? editorScrollViewer_.VerticalOffset() : 0.0;
    const auto hit = lithe::windows::algorithms::hitTestGutter(
        point.X, point.Y, scrollOffset, EditorGutter().ActualWidth(), lineCount);
    if (!hit) return;
    if (hit->zone == lithe::windows::algorithms::GutterHitZone::LineNumber) {
        navigateEditor(hit->line, 0);
        session_->toggleBreakpoint(
            isExternalDocument(activePath_) ? std::string{} : activePath_,
            source, hit->line);
    } else {
        invokeGutterAnnotation(hit->line, point.X);
    }
    event.Handled(true);
}

void MainWindow::KeepExternalEditorVersionClick(IInspectable const&, RoutedEventArgs const&) {
    session_->keepDocumentEditorVersion();
    externalConflictVisible_ = false;
    ExternalConflictBanner().Visibility(Visibility::Collapsed);
    setStatus("Keeping the editor version");
}

void MainWindow::LoadExternalDiskVersionClick(IInspectable const&, RoutedEventArgs const&) {
    if (activePath_.empty() || isExternalDocument(activePath_)) return;
    externalConflictVisible_ = false;
    ExternalConflictBanner().Visibility(Visibility::Collapsed);
    dirtyPaths_.erase(activePath_);
    updateTabHeader(activePath_);
    session_->openDocument(activePath_);
    setStatus("Loading the disk version");
}

void MainWindow::handleDirectoryChanges(
    std::vector<lithe::windows::DirectoryChangeSource::Change> changes) {
    if (!session_ || changes.empty()) return;
    bool activeFileModified = false;
    bool activeFileRemoved = false;
    for (const auto& change : changes) {
        const auto relative = pathFromUtf8(change.path).generic_u8string();
        const std::string path(reinterpret_cast<const char*>(relative.data()), relative.size());
        if (path != activePath_) continue;
        if (change.kind == lithe::windows::DirectoryChangeSource::ChangeKind::Modified) {
            activeFileModified = true;
        } else if (change.kind == lithe::windows::DirectoryChangeSource::ChangeKind::Removed ||
                   change.kind == lithe::windows::DirectoryChangeSource::ChangeKind::RenamedOldName) {
            activeFileRemoved = true;
        }
    }
    if (activeFileRemoved) {
        externalConflictVisible_ = false;
        ExternalConflictBanner().Visibility(Visibility::Collapsed);
        setStatus(dirtyPaths_.contains(activePath_)
            ? "The open file was removed; unsaved changes were kept"
            : "The open file was removed");
        return;
    }
    if (!activeFileModified || activePath_.empty() || isExternalDocument(activePath_)) return;
    if (dirtyPaths_.contains(activePath_)) {
        session_->markDocumentExternalConflict(activePath_);
        externalConflictVisible_ = true;
        ExternalConflictBanner().Visibility(Visibility::Visible);
        setStatus("The file changed outside Lithe; choose which version to keep");
        return;
    }
    session_->openDocument(activePath_);
    setStatus("File changed outside Lithe; reloading");
}

void MainWindow::FindTextChanged(IInspectable const&, TextChangedEventArgs const&) {
    rebuildFindMatches();
}

void MainWindow::EditorTabSelectionChanged(IInspectable const&, SelectionChangedEventArgs const&) {
    if (restoringWorkbench_) return;
    const auto selected = EditorTabs().SelectedItem().try_as<TabViewItem>();
    if (!selected || !selected.Tag()) return;
    const auto path = utf8(unbox_value<hstring>(selected.Tag()));
    if (path.empty() || path == activePath_) return;
    cacheCurrentDocument();
    if (isExternalDocument(path)) openExternalDocument(externalDocumentPath(path));
    else openDocument(path);
}

void MainWindow::CloseActiveEditorClick(
    IInspectable const&, Input::KeyboardAcceleratorInvokedEventArgs const& event) {
    const auto selected = EditorTabs().SelectedItem().try_as<TabViewItem>();
    if (selected) closeEditorTab(selected);
    event.Handled(true);
}

fire_and_forget MainWindow::EditorTabCloseRequested(
    TabView const&, TabViewTabCloseRequestedEventArgs const& event) {
    const auto tab = event.Tab().try_as<TabViewItem>();
    if (tab) closeEditorTab(tab);
    co_return;
}

fire_and_forget MainWindow::closeEditorTab(TabViewItem const& tab) {
    const auto lifetime = get_strong();
    if (!tab || !tab.Tag()) co_return;
    const auto path = utf8(unbox_value<hstring>(tab.Tag()));
    if (dirtyPaths_.contains(path)) {
        ContentDialog dialog;
        dialog.XamlRoot(RootGrid().XamlRoot());
        dialog.Title(box_value(text("Save changes to " + fileName(path) + "?")));
        dialog.Content(box_value(L"Unsaved changes will be lost if they are not saved."));
        dialog.PrimaryButtonText(L"Save");
        dialog.SecondaryButtonText(L"Don't save");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(ContentDialogButton::Primary);
        const auto result = co_await showDialog(dialog);
        if (result == ContentDialogResult::None) co_return;
        if (result == ContentDialogResult::Primary) {
            if (path == activePath_) cacheCurrentDocument();
            const auto found = openDocuments_.find(path);
            if (found == openDocuments_.end()) co_return;
            const auto weak = get_weak();
            const auto dispatcher = dispatcher_;
            session_->saveDocument(path, found->second,
                [weak, dispatcher, path](bool succeeded, std::string error) mutable {
                    dispatcher.TryEnqueue(
                        [weak, path, succeeded, error = std::move(error)]() mutable {
                            const auto self = weak.get();
                            if (!self) return;
                            if (!succeeded) {
                                self->setStatus(error.empty() ? "File save failed" : error);
                                return;
                            }
                            for (uint32_t index = 0;
                                 index < self->EditorTabs().TabItems().Size(); ++index) {
                                const auto candidate = self->EditorTabs().TabItems().GetAt(index)
                                    .try_as<TabViewItem>();
                                if (candidate && candidate.Tag() &&
                                    utf8(unbox_value<hstring>(candidate.Tag())) == path) {
                                    self->removeEditorTab(candidate);
                                    break;
                                }
                            }
                        });
                });
            co_return;
        }
    }
    removeEditorTab(tab);
}

void MainWindow::configureEditorTabContextMenu(TabViewItem const& tab, std::string path) {
    if (!tab || path.empty()) return;
    const auto weak = get_weak();
    MenuFlyout flyout;

    MenuFlyoutItem close;
    close.Text(ui("Close"));
    close.Click([weak, path](IInspectable const&, RoutedEventArgs const&) {
        if (const auto self = weak.get()) {
            for (uint32_t index = 0; index < self->EditorTabs().TabItems().Size(); ++index) {
                const auto candidate = self->EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
                if (candidate && candidate.Tag() &&
                    utf8(unbox_value<hstring>(candidate.Tag())) == path) {
                    self->closeEditorTab(candidate);
                    break;
                }
            }
        }
    });
    flyout.Items().Append(close);

    MenuFlyoutItem closeOthers;
    closeOthers.Text(ui("Close Other Unmodified Tabs"));
    closeOthers.Click([weak, path](IInspectable const&, RoutedEventArgs const&) {
        const auto self = weak.get();
        if (!self) return;
        for (uint32_t index = 0; index < self->EditorTabs().TabItems().Size();) {
            const auto candidate = self->EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
            const auto candidatePath = candidate && candidate.Tag()
                ? utf8(unbox_value<hstring>(candidate.Tag())) : std::string{};
            if (candidate && candidatePath != path && !self->dirtyPaths_.contains(candidatePath)) {
                self->removeEditorTab(candidate);
            } else {
                ++index;
            }
        }
        self->setStatus("Closed other unmodified tabs");
    });
    flyout.Items().Append(closeOthers);

    MenuFlyoutItem closeUnmodified;
    closeUnmodified.Text(ui("Close All Unmodified Tabs"));
    closeUnmodified.Click([weak](IInspectable const&, RoutedEventArgs const&) {
        const auto self = weak.get();
        if (!self) return;
        for (uint32_t index = 0; index < self->EditorTabs().TabItems().Size();) {
            const auto candidate = self->EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
            const auto candidatePath = candidate && candidate.Tag()
                ? utf8(unbox_value<hstring>(candidate.Tag())) : std::string{};
            if (candidate && !self->dirtyPaths_.contains(candidatePath)) {
                self->removeEditorTab(candidate);
            } else {
                ++index;
            }
        }
        self->setStatus("Closed unmodified tabs");
    });
    flyout.Items().Append(closeUnmodified);
    MenuFlyoutSeparator separator;
    flyout.Items().Append(separator);

    MenuFlyoutItem copyPath;
    copyPath.Text(ui("Copy Path"));
    copyPath.Click([weak, path](IInspectable const&, RoutedEventArgs const&) {
        if (const auto self = weak.get()) {
            if (isExternalDocument(path)) {
                self->copyText(pathUtf8(externalDocumentPath(path)));
            } else if (const auto absolute = self->session_->absoluteWorkspacePath(path)) {
                self->copyText(pathUtf8(*absolute));
            }
        }
    });
    flyout.Items().Append(copyPath);

    MenuFlyoutItem copyRelative;
    copyRelative.Text(ui("Copy Relative Path"));
    copyRelative.Click([weak, path](IInspectable const&, RoutedEventArgs const&) {
        if (const auto self = weak.get(); self && !isExternalDocument(path)) self->copyText(path);
    });
    flyout.Items().Append(copyRelative);

    MenuFlyoutItem reveal;
    reveal.Text(ui("Show in Explorer"));
    reveal.Click([weak, path](IInspectable const&, RoutedEventArgs const&) {
        if (const auto self = weak.get()) {
            const auto absolute = isExternalDocument(path)
                ? std::optional<std::filesystem::path>(externalDocumentPath(path))
                : self->session_->absoluteWorkspacePath(path);
            if (absolute) self->revealPath(*absolute, true);
        }
    });
    flyout.Items().Append(reveal);

    MenuFlyoutItem history;
    history.Text(ui("Local History"));
    history.Click([weak, path](IInspectable const&, RoutedEventArgs const&) {
        if (const auto self = weak.get(); self && !isExternalDocument(path)) {
            self->showBottomTool(4);
            self->GitModeTabs().SelectedIndex(3);
            self->session_->loadHistory(path);
        }
    });
    flyout.Items().Append(history);

    tab.ContextFlyout(flyout);
}

void MainWindow::SidebarSplitterDragDelta(IInspectable const&, DragDeltaEventArgs const& event) {
    const auto width = std::clamp(SidebarColumn().ActualWidth() + event.HorizontalChange(),
                                  220.0, 520.0);
    SidebarColumn().Width(GridLength{width, GridUnitType::Pixel});
    scheduleWorkbenchStateSave();
}

void MainWindow::BottomSplitterDragDelta(IInspectable const&, DragDeltaEventArgs const& event) {
    if (!bottomPanelVisible_) return;
    const auto available = RootGrid().ActualHeight();
    const auto height = std::clamp(BottomPanelRow().ActualHeight() - event.VerticalChange(),
                                   180.0, std::max(180.0, available - 300.0));
    bottomPanelHeight_ = height;
    BottomPanelRow().Height(GridLength{height, GridUnitType::Pixel});
    scheduleWorkbenchStateSave();
}

void MainWindow::RootSizeChanged(IInspectable const&, SizeChangedEventArgs const&) {
    updateLineNumbers();
    if (!restoringWorkbench_ && !session_->workspaceRoot().empty()) {
        scheduleWorkbenchStateSave();
    }
}

void MainWindow::RootLoaded(IInspectable const&, RoutedEventArgs const&) {
    if (showWelcomeOnLoad_) {
        showWelcomeOnLoad_ = false;
        showWelcomeSurface();
    } else {
        showWorkbenchSurface();
    }
}

void MainWindow::showWelcomeSurface() {
    renderWelcomeProjects(WelcomeSearchBox() ? utf8(WelcomeSearchBox().Text()) : std::string{});
    TopBar().Visibility(Visibility::Collapsed);
    WorkbenchSurface().Visibility(Visibility::Collapsed);
    StatusBar().Visibility(Visibility::Collapsed);
    WelcomeSurface().Visibility(Visibility::Visible);
}

void MainWindow::showWorkbenchSurface() {
    WelcomeSurface().Visibility(Visibility::Collapsed);
    TopBar().Visibility(Visibility::Visible);
    WorkbenchSurface().Visibility(Visibility::Visible);
    StatusBar().Visibility(Visibility::Visible);
}

void MainWindow::renderWelcomeProjects(std::string query) {
    WelcomeProjectsList().Items().Clear();
    std::size_t visibleCount = 0;
    for (const auto& path : session_->recentProjects()) {
        auto name = fileName(path);
        if (name.empty()) name = path;
        if (!query.empty() && !containsIgnoreCase(name + " " + path, query)) continue;

        std::error_code error;
        const bool available = std::filesystem::is_directory(pathFromUtf8(path), error);
        ListViewItem item;
        item.Tag(box_value(text(path)));
        item.Height(58);
        item.Opacity(available ? 1.0 : 0.34);
        item.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        item.Padding(Thickness{12, 0, 12, 0});

        Grid row;
        row.ColumnDefinitions().Append(ColumnDefinition{});
        row.ColumnDefinitions().Append(ColumnDefinition{});
        row.ColumnDefinitions().GetAt(0).Width(GridLength{38, GridUnitType::Pixel});
        row.ColumnDefinitions().GetAt(1).Width(GridLength{1, GridUnitType::Star});
        row.ColumnSpacing(12);

        Border badge;
        badge.Width(38);
        badge.Height(38);
        badge.CornerRadius(CornerRadius{8});
        static constexpr std::array<wchar_t const*, 5> palette{
            L"LitheProjectOrangeBrush", L"LitheProjectTealBrush",
            L"LitheProjectBlueBrush", L"LitheProjectGreenBrush",
            L"LitheProjectGoldBrush"};
        std::uint64_t hash = 1469598103934665603ULL;
        for (const auto byte : name) {
            hash ^= static_cast<unsigned char>(byte);
            hash *= 1099511628211ULL;
        }
        badge.Background(available ? applicationBrush(palette[hash % palette.size()])
                                   : applicationBrush(L"LitheRaisedBrush"));
        TextBlock initial;
        initial.Text(text(name.empty() ? "LI" : std::string(1, static_cast<char>(std::toupper(
            static_cast<unsigned char>(name.front()))))));
        initial.FontSize(12);
        initial.FontWeight(Windows::UI::Text::FontWeights::Bold());
        initial.Foreground(applicationBrush(L"LitheTextBrush"));
        initial.HorizontalAlignment(HorizontalAlignment::Center);
        initial.VerticalAlignment(VerticalAlignment::Center);
        badge.Child(initial);
        row.Children().Append(badge);

        StackPanel labels;
        labels.Spacing(3);
        labels.VerticalAlignment(VerticalAlignment::Center);
        TextBlock title;
        title.Text(text(name));
        title.FontSize(13.5);
        title.FontWeight(Windows::UI::Text::FontWeights::Medium());
        TextBlock location;
        location.Text(text(path));
        location.FontSize(11.5);
        location.Foreground(applicationBrush(L"LitheMutedTextBrush"));
        location.TextTrimming(TextTrimming::CharacterEllipsis);
        labels.Children().Append(title);
        labels.Children().Append(location);
        Grid::SetColumn(labels, 1);
        row.Children().Append(labels);
        item.Content(row);
        WelcomeProjectsList().Items().Append(item);
        ++visibleCount;
    }
    WelcomeProjectsList().Visibility(visibleCount == 0 ? Visibility::Collapsed : Visibility::Visible);
    WelcomeEmptyState().Visibility(visibleCount == 0 ? Visibility::Visible : Visibility::Collapsed);
    WelcomeEmptyTitle().Text(ui(query.empty() ? "No recent projects" : "No matching projects"));
}

void MainWindow::WelcomeSearchTextChanged(IInspectable const&, TextChangedEventArgs const&) {
    if (session_) renderWelcomeProjects(utf8(WelcomeSearchBox().Text()));
}

void MainWindow::WelcomeProjectClick(IInspectable const&, ItemClickEventArgs const& event) {
    const auto path = itemTag(event.ClickedItem());
    if (path.empty()) return;
    std::error_code error;
    if (!std::filesystem::is_directory(pathFromUtf8(path), error)) return;
    const auto weak = get_weak();
    continueAfterDirtyDocuments("Switch Project", [weak, path] {
        if (const auto self = weak.get()) {
            self->saveWorkbenchState();
            self->resetWorkspaceUI();
            self->session_->openWorkspace(pathFromUtf8(path));
        }
    });
}

void MainWindow::setStatus(std::string message) {
    StatusText().Text(ui(message.empty() ? "Ready" : message));
}

void MainWindow::showBottomTool(std::uint32_t index) {
    if (!bottomPanelVisible_) {
        bottomPanelVisible_ = true;
        BottomToolPanel().Visibility(Visibility::Visible);
        BottomPanelRow().Height(GridLength{bottomPanelHeight_, GridUnitType::Pixel});
    }
    BottomToolTabs().SelectedIndex(static_cast<int32_t>(index));
}

void MainWindow::cacheCurrentDocument() {
    if (activePath_.empty() || editorUpdating_) return;
    openDocuments_[activePath_] = editorText();
}

fire_and_forget MainWindow::continueAfterDirtyDocuments(
    std::string actionTitle, std::function<void()> completion) {
    const auto lifetime = get_strong();
    cacheCurrentDocument();
    if (dirtyPaths_.empty()) {
        if (completion) completion();
        co_return;
    }

    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(text(actionTitle + "?")));
    dialog.Content(box_value(text(countLabel(
        dirtyPaths_.size(), "open file(s) have unsaved changes",
        "个打开的文件包含未保存更改", simplifiedChinese_))));
    dialog.PrimaryButtonText(ui("Save All"));
    dialog.SecondaryButtonText(ui("Don't save"));
    dialog.CloseButtonText(ui("Cancel"));
    dialog.DefaultButton(ContentDialogButton::Primary);
    const auto result = co_await showDialog(dialog);
    if (result == ContentDialogResult::None) co_return;
    if (result == ContentDialogResult::Secondary) {
        if (completion) completion();
        co_return;
    }

    auto state = std::make_shared<DirtyDocumentSaveSequence>();
    state->completion = std::move(completion);
    std::vector<std::string> paths(dirtyPaths_.begin(), dirtyPaths_.end());
    std::sort(paths.begin(), paths.end());
    state->documents.reserve(paths.size());
    for (const auto& path : paths) {
        const auto found = openDocuments_.find(path);
        if (found != openDocuments_.end() && !isExternalDocument(path)) {
            state->documents.emplace_back(path, found->second);
        }
    }
    saveNextDirtyDocument(std::move(state));
}

void MainWindow::saveNextDirtyDocument(std::shared_ptr<DirtyDocumentSaveSequence> state) {
    if (state->index >= state->documents.size()) {
        if (state->completion) state->completion();
        return;
    }
    const auto [path, source] = state->documents[state->index++];
    const auto weak = get_weak();
    const auto dispatcher = dispatcher_;
    session_->saveDocument(path, source,
        [weak, dispatcher, path, state = std::move(state)](
            bool succeeded, std::string error) mutable {
            dispatcher.TryEnqueue([weak, path, succeeded, error = std::move(error),
                                   state = std::move(state)]() mutable {
                const auto self = weak.get();
                if (!self) return;
                if (!succeeded) {
                    self->setStatus(error.empty()
                        ? "Could not save " + path : std::move(error));
                    return;
                }
                self->dirtyPaths_.erase(path);
                self->updateTabHeader(path);
                self->saveNextDirtyDocument(std::move(state));
            });
        });
}

void MainWindow::resetWorkspaceUI() {
    if (markdownPreviewTimer_) markdownPreviewTimer_.Stop();
    ProjectTree().RootNodes().Clear();
    treePaths_.clear();
    directoryPaths_.clear();
    EditorTabs().TabItems().Clear();
    openDocuments_.clear();
    dirtyPaths_.clear();
    activePath_.clear();
    pendingNavigationLine_.reset();
    pendingNavigationColumn_.reset();
    pendingHistoryContentPath_.clear();
    pendingIntegration_.reset();
    pendingIntegrationPaths_.clear();
    gitConflictPaths_.clear();
    gitStatus_.reset();
    selectedHistoryContentPath_.clear();
    selectedHistoryPath_.clear();
    loadedHistoryContent_.reset();
    WorkspaceTitleText().Text(L"");
    BreadcrumbText().Text(L"");
    DocumentStateText().Text(L"");
    GitBranchText().Text(L"");
    GitStatusText().Text(L"");
    GitOperationText().Text(L"");
    ContinueGitOperationButton().Content(box_value(ui("Continue")));
    ContinueGitOperationButton().Visibility(Visibility::Collapsed);
    AbortGitOperationButton().Content(box_value(ui("Abort")));
    AbortGitOperationButton().Visibility(Visibility::Collapsed);
    SkipGitOperationButton().Visibility(Visibility::Collapsed);
    ChangesList().Items().Clear();
    BlockedChangesFilterButton().IsChecked(false);
    GitHistoryList().Items().Clear();
    GitStashesList().Items().Clear();
    GitShelvesList().Items().Clear();
    LocalHistoryList().Items().Clear();
    activeTerminalID_.clear();
    terminalUiUpdating_ = true;
    TerminalSessionsBox().Items().Clear();
    TerminalShellBox().Text(L"");
    TerminalOutputBox().Text(L"");
    terminalUiUpdating_ = false;
    DiffRowsPanel().Children().Clear();
    DiffOverviewList().Items().Clear();
    clearNavigationList(SearchResultsList());
    editorUpdating_ = true;
    EditorTextBox().IsReadOnly(false);
    setEditorText({});
    editorUpdating_ = false;
    EditorEmptyState().Visibility(Visibility::Visible);
    MarkdownModePanel().Visibility(Visibility::Collapsed);
    MarkdownPreviewPane().Visibility(Visibility::Collapsed);
    MarkdownPreviewColumn().Width(GridLength{0.0, GridUnitType::Pixel});
    blamePath_.clear();
    blame_.reset();
    codeVision_.reset();
    javaStructure_.reset();
    updateLineNumbers();
}

void MainWindow::openDocument(
    std::string path,
    std::optional<std::uint64_t> line,
    std::optional<std::uint64_t> utf16Column) {
    if (path.empty()) return;
    cacheCurrentDocument();
    activePath_ = std::move(path);
    blame_.reset();
    codeVision_.reset();
    javaStructure_.reset();
    pendingNavigationLine_ = line;
    pendingNavigationColumn_ = utf16Column;
    ensureEditorTab(activePath_);
    EditorEmptyState().Visibility(Visibility::Collapsed);
    EditorProgress().Visibility(Visibility::Visible);
    EditorProgress().IsActive(true);
    updateLineNumbers();
    session_->openDocument(activePath_);
}

void MainWindow::openExternalDocument(
    const std::filesystem::path& path,
    std::optional<std::uint64_t> line,
    std::optional<std::uint64_t> utf16Column) {
    std::string error;
    const auto source = session_->readExternalDocument(path, error);
    if (!source) {
        setStatus(error.empty() ? "Could not open navigation target" : error);
        return;
    }
    cacheCurrentDocument();
    session_->closeJavaDocument();
    activePath_ = externalDocumentKey(path);
    MarkdownModePanel().Visibility(Visibility::Collapsed);
    MarkdownPreviewPane().Visibility(Visibility::Collapsed);
    MarkdownPreviewColumn().Width(GridLength{0.0, GridUnitType::Pixel});
    blamePath_.clear();
    blame_.reset();
    codeVision_.reset();
    javaStructure_.reset();
    openDocuments_[activePath_] = *source;
    ensureEditorTab(activePath_);
    editorUpdating_ = true;
    EditorTextBox().IsReadOnly(true);
    setEditorText(*source);
    editorUpdating_ = false;
    EditorEmptyState().Visibility(Visibility::Collapsed);
    EditorProgress().IsActive(false);
    EditorProgress().Visibility(Visibility::Collapsed);
    BreadcrumbText().Text(text(pathUtf8(path)));
    DocumentStateText().Text(L"Read only");
    updateEditorPresentation();
    if (line) navigateEditor(*line, utf16Column.value_or(0));
    setStatus("Opened read-only library source");
}

TabViewItem MainWindow::ensureEditorTab(const std::string& path) {
    for (uint32_t index = 0; index < EditorTabs().TabItems().Size(); ++index) {
        const auto tab = EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
        if (tab && tab.Tag() && utf8(unbox_value<hstring>(tab.Tag())) == path) {
            EditorTabs().SelectedItem(tab);
            return tab;
        }
    }
    TabViewItem tab;
    const auto label = isExternalDocument(path)
        ? fileName(pathUtf8(externalDocumentPath(path))) : fileName(path);
    tab.Header(box_value(text(label)));
    tab.Tag(box_value(text(path)));
    tab.IsClosable(true);
    configureEditorTabContextMenu(tab, path);
    EditorTabs().TabItems().Append(tab);
    EditorTabs().SelectedItem(tab);
    return tab;
}

void MainWindow::remapEditorPaths(std::string_view oldPath, std::string_view newPath) {
    const auto remapped = [&](std::string_view path) -> std::optional<std::string> {
        if (path == oldPath) return std::string(newPath);
        if (path.size() > oldPath.size() && path.starts_with(oldPath) &&
            path[oldPath.size()] == '/') {
            return std::string(newPath) + std::string(path.substr(oldPath.size()));
        }
        return std::nullopt;
    };
    std::vector<std::pair<std::string, std::string>> moves;
    for (const auto& [path, source] : openDocuments_) {
        if (const auto destination = remapped(path)) moves.emplace_back(path, *destination);
    }
    for (const auto& [source, destination] : moves) {
        openDocuments_[destination] = std::move(openDocuments_[source]);
        openDocuments_.erase(source);
        if (dirtyPaths_.erase(source) > 0) dirtyPaths_.insert(destination);
    }
    for (uint32_t index = 0; index < EditorTabs().TabItems().Size(); ++index) {
        const auto tab = EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
        if (!tab || !tab.Tag()) continue;
        const auto source = utf8(unbox_value<hstring>(tab.Tag()));
        const auto destination = remapped(source);
        if (!destination) continue;
        tab.Tag(box_value(text(*destination)));
        tab.Header(box_value(text(
            (dirtyPaths_.contains(*destination) ? "* " : "") + fileName(*destination))));
        configureEditorTabContextMenu(tab, *destination);
    }
    if (const auto destination = remapped(activePath_)) {
        activePath_ = *destination;
        BreadcrumbText().Text(text(activePath_));
        if (isJavaPath(activePath_)) {
            session_->activateJavaDocument(activePath_, editorText());
            session_->analyzeJavaDocument(activePath_, editorText());
        }
    }
    scheduleWorkbenchStateSave();
}

void MainWindow::updateTabHeader(const std::string& path) {
    for (uint32_t index = 0; index < EditorTabs().TabItems().Size(); ++index) {
        const auto tab = EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
        if (!tab || !tab.Tag() || utf8(unbox_value<hstring>(tab.Tag())) != path) continue;
        tab.Header(box_value(text((dirtyPaths_.contains(path) ? "* " : "") + fileName(path))));
        return;
    }
}

void MainWindow::removeEditorTab(TabViewItem const& tab) {
    if (!tab || !tab.Tag()) return;
    const auto path = utf8(unbox_value<hstring>(tab.Tag()));
    uint32_t index = 0;
    if (EditorTabs().TabItems().IndexOf(tab, index)) EditorTabs().TabItems().RemoveAt(index);
    openDocuments_.erase(path);
    dirtyPaths_.erase(path);
    if (path != activePath_) return;
    if (!isExternalDocument(path)) session_->closeJavaDocument();
        activePath_.clear();
        MarkdownModePanel().Visibility(Visibility::Collapsed);
        MarkdownPreviewPane().Visibility(Visibility::Collapsed);
        MarkdownPreviewColumn().Width(GridLength{0.0, GridUnitType::Pixel});
    const auto selected = EditorTabs().SelectedItem().try_as<TabViewItem>();
    if (selected && selected.Tag()) {
        const auto selectedPath = utf8(unbox_value<hstring>(selected.Tag()));
        if (isExternalDocument(selectedPath)) {
            openExternalDocument(externalDocumentPath(selectedPath));
        } else {
            openDocument(selectedPath);
        }
    } else {
        editorUpdating_ = true;
        EditorTextBox().IsReadOnly(false);
        setEditorText({});
        editorUpdating_ = false;
        BreadcrumbText().Text(L"");
        DocumentStateText().Text(L"");
        EditorEmptyState().Visibility(Visibility::Visible);
        blamePath_.clear();
        blame_.reset();
        codeVision_.reset();
        javaStructure_.reset();
        updateLineNumbers();
    }
}

void MainWindow::saveWorkbenchState() {
    if (!session_ || session_->workspaceRoot().empty()) return;
    session_->saveLayout(currentLayout());
    auto state = session_->loadWorkspaceSession();
    state.openPaths.clear();
    state.expandedPaths.clear();
    for (uint32_t index = 0; index < EditorTabs().TabItems().Size(); ++index) {
        const auto tab = EditorTabs().TabItems().GetAt(index).try_as<TabViewItem>();
        if (!tab || !tab.Tag()) continue;
        const auto path = utf8(unbox_value<hstring>(tab.Tag()));
        if (!isExternalDocument(path)) state.openPaths.push_back(path);
    }
    state.activePath = isExternalDocument(activePath_) ? std::string{} : activePath_;
    std::function<void(TreeViewNode const&)> collect = [&](TreeViewNode const& node) {
        const auto found = treePaths_.find(objectKey(node));
        if (node.IsExpanded() && found != treePaths_.end() && directoryPaths_.contains(found->second)) {
            state.expandedPaths.push_back(found->second);
        }
        for (const auto& child : node.Children()) collect(child);
    };
    for (const auto& root : ProjectTree().RootNodes()) collect(root);
    session_->saveWorkspaceSession(state);
}

void MainWindow::scheduleWorkbenchStateSave() {
    if (restoringWorkbench_ || !workbenchSaveTimer_ ||
        !session_ || session_->workspaceRoot().empty()) {
        return;
    }
    workbenchSaveTimer_.Stop();
    workbenchSaveTimer_.Start();
}

bool MainWindow::isExternalDocument(std::string_view key) {
    return key.starts_with("@external:");
}

std::string MainWindow::externalDocumentKey(const std::filesystem::path& path) {
    return "@external:" + pathUtf8(path);
}

std::filesystem::path MainWindow::externalDocumentPath(std::string_view key) {
    constexpr std::string_view prefix = "@external:";
    return pathFromUtf8(key.starts_with(prefix) ? key.substr(prefix.size()) : key);
}

void MainWindow::restoreWorkbenchState() {
    restoringWorkbench_ = true;
    applyLayout(session_->loadLayout(
        static_cast<int>(std::max(1.0, RootGrid().ActualWidth())),
        static_cast<int>(std::max(1.0, RootGrid().ActualHeight() - 68.0))));
    const auto state = session_->loadWorkspaceSession();
    std::unordered_set<std::string> expanded(state.expandedPaths.begin(), state.expandedPaths.end());
    std::function<void(TreeViewNode const&)> expand = [&](TreeViewNode const& node) {
        const auto found = treePaths_.find(objectKey(node));
        if (found != treePaths_.end() && expanded.contains(found->second)) node.IsExpanded(true);
        for (const auto& child : node.Children()) expand(child);
    };
    for (const auto& root : ProjectTree().RootNodes()) expand(root);
    for (const auto& path : state.openPaths) ensureEditorTab(path);
    restoringWorkbench_ = false;
    if (!state.activePath.empty()) openDocument(state.activePath);
    else if (!state.openPaths.empty()) openDocument(state.openPaths.front());
}

void MainWindow::applyLayout(const lithe::windows::WorkbenchLayoutState& state) {
    restoringWorkbench_ = true;
    SidebarColumn().Width(GridLength{static_cast<double>(state.sidebarWidth), GridUnitType::Pixel});
    switch (state.sidebarDestination) {
    case lithe::windows::SidebarDestination::Project: SidebarTabs().SelectedIndex(0); break;
    case lithe::windows::SidebarDestination::Search: SidebarTabs().SelectedIndex(2); break;
    case lithe::windows::SidebarDestination::Git: SidebarTabs().SelectedIndex(1); break;
    }
    BottomToolTabs().SelectedIndex(static_cast<int32_t>(state.bottomToolKind));
    bottomPanelVisible_ = state.bottomVisible;
    const auto available = std::max(400.0, RootGrid().ActualHeight() - 68.0);
    bottomPanelHeight_ = std::max(180.0, available - state.editorTopHeight);
    BottomToolPanel().Visibility(state.bottomVisible ? Visibility::Visible : Visibility::Collapsed);
    BottomPanelRow().Height(GridLength{
        state.bottomVisible ? bottomPanelHeight_ : 0.0, GridUnitType::Pixel});
    restoringWorkbench_ = false;
}

lithe::windows::WorkbenchLayoutState MainWindow::currentLayout() {
    lithe::windows::WorkbenchLayoutState state;
    state.sidebarWidth = static_cast<int>(std::round(SidebarColumn().ActualWidth()));
    state.editorTopHeight = static_cast<int>(std::round(
        std::max(1.0, RootGrid().ActualHeight() - 68.0 -
                           (bottomPanelVisible_ ? BottomPanelRow().ActualHeight() : 0.0))));
    switch (SidebarTabs().SelectedIndex()) {
    case 1: state.sidebarDestination = lithe::windows::SidebarDestination::Git; break;
    case 2: state.sidebarDestination = lithe::windows::SidebarDestination::Search; break;
    default: state.sidebarDestination = lithe::windows::SidebarDestination::Project; break;
    }
    const auto tool = std::clamp(BottomToolTabs().SelectedIndex(), 0, 5);
    state.bottomToolKind = static_cast<lithe::windows::BottomToolKind>(tool);
    state.bottomVisible = bottomPanelVisible_;
    return state;
}

std::string MainWindow::editorText() {
    hstring value;
    EditorTextBox().Document().GetText(Text::TextGetOptions::None, value);
    auto result = utf8(value);
    if (!result.empty() && result.back() == '\r') result.pop_back();
    return result;
}

void MainWindow::setEditorText(std::string_view value) {
    EditorTextBox().Document().SetText(Text::TextSetOptions::None, text(value));
}

void MainWindow::configureEditorScroll() {
    if (editorScrollViewer_) return;
    editorScrollViewer_ = findDescendant<ScrollViewer>(EditorTextBox());
    if (!editorScrollViewer_) return;
    const auto weak = get_weak();
    editorScrollToken_ = editorScrollViewer_.ViewChanged(
        [weak](IInspectable const& sender, ScrollViewerViewChangedEventArgs const&) {
            if (const auto self = weak.get()) {
                self->LineNumbersTransform().Y(-sender.as<ScrollViewer>().VerticalOffset());
                self->GutterAnnotationsTransform().Y(
                    -sender.as<ScrollViewer>().VerticalOffset());
            }
        });
}

void MainWindow::updateEditorPresentation() {
    updateLineNumbers();
    applySyntaxHighlighting();
    updateCursorPosition();
    if (FindBar().Visibility() == Visibility::Visible) rebuildFindMatches();
}

void MainWindow::updateLineNumbers() {
    const auto source = editorText();
    std::size_t count = 1;
    for (const char character : source) if (character == '\n') ++count;
    std::string labels;
    std::string annotations;
    labels.reserve(count * 7);
    annotations.reserve(count * 24);
    std::vector<std::string> annotationLines(count);
    gutterActions_.clear();
    const auto appendAnnotation = [this, &annotationLines](
        std::uint64_t line,
        std::string value,
        GutterActionKind kind,
        std::uint64_t utf16Column,
        std::string actionValue = {}) {
        if (line >= annotationLines.size() || value.empty()) return;
        auto& target = annotationLines[line];
        if (!target.empty()) target += "  |  ";
        const auto start = target.size();
        target += std::move(value);
        gutterActions_.push_back({
            kind, line, utf16Column, start, target.size(), std::move(actionValue)});
    };
    std::unordered_set<std::uint64_t> breakpointLines;
    if (!isExternalDocument(activePath_)) {
        if (const auto activeFile = session_->absoluteWorkspacePath(activePath_)) {
            const auto normalizedActive = lowercase(activeFile->lexically_normal().wstring());
            for (const auto& breakpoint : debugSnapshot_.breakpoints) {
                if (breakpoint.line > 0 &&
                    lowercase(pathFromUtf8(breakpoint.filePath).lexically_normal().wstring()) ==
                        normalizedActive) {
                    breakpointLines.insert(static_cast<std::uint64_t>(breakpoint.line));
                }
            }
        }
    }

    if (blameVisible_ && blame_ && blamePath_ == activePath_) {
        for (const auto& entry : blame_->lines) {
            if (entry.line == 0 || entry.line > count) continue;
            auto value = dateText(entry.authorTime);
            if (!entry.authorName.empty()) value += "  " + entry.authorName;
            appendAnnotation(entry.line - 1, std::move(value),
                             GutterActionKind::BlameCommit, 0, entry.commitHash);
        }
    } else if (isJavaPath(activePath_) && !isExternalDocument(activePath_)) {
        const auto& settings = session_->settings();
        if (settings.showCodeVision && codeVision_) {
            for (const auto& hint : codeVision_->hints) {
                if (hint.line >= count) continue;
                appendAnnotation(
                    hint.line,
                    std::to_string(hint.usageCount) + " usages  " + hint.symbol,
                    GutterActionKind::Usages, hint.utf16Column, hint.symbol);
            }
        }
        if (javaStructure_) {
            if (settings.showCodeVision) {
                for (const auto& marker : javaStructure_->implementationMarkers) {
                    if (marker.line >= count) continue;
                    appendAnnotation(
                        marker.line,
                        std::to_string(marker.implementationCount) + " implementations (" +
                            (marker.direction == "up" ? "up" : "down") + ")",
                        GutterActionKind::Implementations, marker.utf16Column);
                }
            }
            if (settings.showInlayHints) {
                for (const auto& hint : javaStructure_->inlayHints) {
                    if (hint.line >= count) continue;
                    appendAnnotation(
                        hint.line,
                        "<" + hint.label + "> @" + std::to_string(hint.utf16Column + 1),
                        GutterActionKind::InlayPosition, hint.utf16Column, hint.label);
                }
            }
        }
    }

    const auto hasAnnotations = std::any_of(
        annotationLines.begin(), annotationLines.end(),
        [](const std::string& value) { return !value.empty(); });
    const double gutterWidth = blameVisible_ ? 232.0 : hasAnnotations ? 280.0 : 50.0;
    EditorGutterColumn().Width(GridLength{gutterWidth, GridUnitType::Pixel});
    EditorGutterClip().Rect(Windows::Foundation::Rect{
        0.0f, 0.0f, static_cast<float>(gutterWidth), 1'000'000.0f});
    const auto annotationWidth = std::max(0.0, gutterWidth - 58.0);
    GutterAnnotationsText().Width(annotationWidth);
    GutterAnnotationsText().Visibility(
        annotationWidth > 0.0 ? Visibility::Visible : Visibility::Collapsed);
    Canvas::SetLeft(LineNumbersText(), gutterWidth - 50.0);
    for (std::size_t line = 1; line <= count; ++line) {
        labels += breakpointLines.contains(line) ? ">" : " ";
        labels += std::to_string(line);
        annotations += annotationLines[line - 1].empty() ? " " : annotationLines[line - 1];
        if (line != count) {
            labels += '\n';
            annotations += '\n';
        }
    }
    LineNumbersText().Text(text(labels));
    GutterAnnotationsText().Text(text(annotations));
}

void MainWindow::invokeGutterAnnotation(std::uint64_t line, double x) {
    const auto characterWidth = std::max(1.0, GutterAnnotationsText().FontSize() * 0.6);
    const auto column = static_cast<std::size_t>(
        std::max(0.0, std::floor((x - 6.0) / characterWidth)));
    const auto found = std::find_if(
        gutterActions_.begin(), gutterActions_.end(),
        [line, column](const GutterAction& action) {
            return action.line == line && column >= action.startColumn &&
                   column < action.endColumn;
        });
    if (found == gutterActions_.end()) return;
    const auto action = *found;
    switch (action.kind) {
    case GutterActionKind::BlameCommit:
        if (!action.value.empty()) {
            GitModeTabs().SelectedIndex(0);
            showBottomTool(4);
            session_->loadGitCommit(action.value);
            setStatus("Loading commit " + action.value);
        }
        break;
    case GutterActionKind::Usages:
        navigateEditor(action.line, action.utf16Column);
        session_->findJavaUsages(
            activePath_, editorText(), action.line, action.utf16Column);
        break;
    case GutterActionKind::Implementations:
        navigateEditor(action.line, action.utf16Column);
        session_->findJavaImplementations(
            activePath_, editorText(), action.line, action.utf16Column);
        break;
    case GutterActionKind::InlayPosition:
        navigateEditor(action.line, action.utf16Column);
        setStatus(action.value.empty() ? "Inlay position" : action.value);
        break;
    }
}

void MainWindow::applySyntaxHighlighting() {
    if (editorFormatting_ || activePath_.empty()) return;
    const auto source = editorText();
    if (source.size() > 2'000'000) return;
    editorFormatting_ = true;
    const auto selection = EditorTextBox().Document().Selection();
    const auto selectionStart = selection.StartPosition();
    const auto selectionEnd = selection.EndPosition();
    const auto offsets = utf16Offsets(source);
    const auto entire = EditorTextBox().Document().GetRange(0, offsets.back());
    entire.CharacterFormat().ForegroundColor(applicationColor(L"LitheCodeTextColor"));
    for (const auto& span : lithe::windows::algorithms::highlightSyntax(source)) {
        if (span.start >= offsets.size() || span.end >= offsets.size()) continue;
        const auto start = offsets[span.start];
        const auto end = offsets[span.end];
        auto range = EditorTextBox().Document().GetRange(start, end);
        const wchar_t* color = L"LitheCodeKeywordColor";
        switch (span.kind) {
        case lithe::windows::algorithms::SyntaxHighlightKind::Keyword:
            color = L"LitheCodeKeywordColor"; break;
        case lithe::windows::algorithms::SyntaxHighlightKind::Annotation:
            color = L"LitheCodeAnnotationColor"; break;
        case lithe::windows::algorithms::SyntaxHighlightKind::Type:
            color = L"LitheCodeTypeColor"; break;
        case lithe::windows::algorithms::SyntaxHighlightKind::Number:
            color = L"LitheCodeNumberColor"; break;
        case lithe::windows::algorithms::SyntaxHighlightKind::String:
            color = L"LitheCodeStringColor"; break;
        case lithe::windows::algorithms::SyntaxHighlightKind::Comment:
            color = L"LitheCodeCommentColor"; break;
        }
        range.CharacterFormat().ForegroundColor(applicationColor(color));
    }
    selection.SetRange(selectionStart, selectionEnd);
    editorFormatting_ = false;
}

void MainWindow::updateCursorPosition() {
    const auto [line, column] = editorPosition();
    if (simplifiedChinese_) {
        CursorPositionText().Text(text("行 " + std::to_string(line + 1) +
                                       "，列 " + std::to_string(column + 1)));
    } else {
        CursorPositionText().Text(text("Ln " + std::to_string(line + 1) +
                                       ", Col " + std::to_string(column + 1)));
    }
}

std::pair<std::uint64_t, std::uint64_t> MainWindow::editorPosition() {
    const auto position = std::max(0, EditorTextBox().Document().Selection().StartPosition());
    hstring prefix;
    EditorTextBox().Document().GetRange(0, position).GetText(Text::TextGetOptions::None, prefix);
    const auto value = std::wstring_view(prefix);
    std::uint64_t line = 0;
    std::uint64_t column = 0;
    for (const wchar_t character : value) {
        if (character == L'\r' || character == L'\n') {
            if (character == L'\n') continue;
            ++line;
            column = 0;
        } else {
            ++column;
        }
    }
    return {line, column};
}

void MainWindow::navigateEditor(std::uint64_t line, std::uint64_t utf16Column) {
    hstring value;
    EditorTextBox().Document().GetText(Text::TextGetOptions::None, value);
    const auto source = std::wstring_view(value);
    std::size_t position = 0;
    std::uint64_t currentLine = 0;
    while (position < source.size() && currentLine < line) {
        if (source[position] == L'\r') {
            ++currentLine;
            if (position + 1 < source.size() && source[position + 1] == L'\n') ++position;
        }
        ++position;
    }
    position = std::min(position + static_cast<std::size_t>(utf16Column), source.size());
    auto selection = EditorTextBox().Document().Selection();
    selection.SetRange(static_cast<int32_t>(position), static_cast<int32_t>(position));
    selection.ScrollIntoView(Text::PointOptions::None);
    EditorTextBox().Focus(FocusState::Programmatic);
}

void MainWindow::rebuildFindMatches() {
    findMatches_.clear();
    findMatchIndex_ = 0;
    if (FindBar().Visibility() != Visibility::Visible) return;
    const auto queryValue = FindTextBox().Text();
    auto query = std::wstring(queryValue.c_str(), queryValue.size());
    const auto sourceValue = text(editorText());
    auto source = std::wstring(sourceValue.c_str(), sourceValue.size());
    if (query.empty()) {
        FindStatusText().Text(L"");
        return;
    }
    const auto matchCase = FindMatchCaseButton().IsChecked();
    if (!(matchCase && matchCase.Value())) {
        query = lowercase(std::move(query));
        source = lowercase(std::move(source));
    }
    std::size_t offset = 0;
    while (offset <= source.size()) {
        const auto found = source.find(query, offset);
        if (found == std::wstring::npos) break;
        findMatches_.push_back({static_cast<int32_t>(found), static_cast<int32_t>(query.size())});
        offset = found + std::max<std::size_t>(1, query.size());
    }
    if (findMatches_.empty()) {
        FindStatusText().Text(L"No matches");
        return;
    }
    FindStatusText().Text(text("1 of " + std::to_string(findMatches_.size())));
}

void MainWindow::selectFindMatch(bool forward) {
    if (FindBar().Visibility() != Visibility::Visible) {
        FocusFindClick(nullptr, RoutedEventArgs{});
        return;
    }
    if (findMatches_.empty()) rebuildFindMatches();
    if (findMatches_.empty()) return;
    if (forward) findMatchIndex_ = (findMatchIndex_ + 1) % findMatches_.size();
    else findMatchIndex_ = (findMatchIndex_ + findMatches_.size() - 1) % findMatches_.size();
    const auto [start, length] = findMatches_[findMatchIndex_];
    auto selection = EditorTextBox().Document().Selection();
    selection.SetRange(start, start + length);
    selection.ScrollIntoView(Text::PointOptions::None);
    EditorTextBox().Focus(FocusState::Programmatic);
    FindStatusText().Text(text(std::to_string(findMatchIndex_ + 1) + " of " +
                               std::to_string(findMatches_.size())));
}

void MainWindow::copyText(std::string_view value) {
    Windows::ApplicationModel::DataTransfer::DataPackage package;
    package.SetText(text(value));
    Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
    setStatus("Copied path");
}

void MainWindow::revealPath(const std::filesystem::path& path, bool selectFile) {
    const auto native = path.wstring();
    if (selectFile) {
        const auto arguments = L"/select,\"" + native + L"\"";
        ShellExecuteW(windowHandle(), L"open", L"explorer.exe", arguments.c_str(),
                      nullptr, SW_SHOWNORMAL);
    } else {
        ShellExecuteW(windowHandle(), L"open", native.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }
}

void MainWindow::clearNavigationList(ListView const& list) {
    for (const auto& item : list.Items()) navigationTargets_.erase(objectKey(item));
    list.Items().Clear();
}

void MainWindow::renderWorkspace(lithe::windows::app::WorkspaceFeatureState state) {
    if (state.isLoading) {
        setStatus("Loading workspace...");
        return;
    }
    if (state.error || !state.snapshot) return;
    showWorkbenchSurface();
    treePaths_.clear();
    directoryPaths_.clear();
    ProjectTree().RootNodes().Clear();
    appendWorkspaceNode(nullptr, state.snapshot->root, true);
    const auto root = state.root.value_or(std::filesystem::path{});
    const auto rootName = root.empty() ? std::string{} : fileName(pathUtf8(root));
    WorkspaceTitleText().Text(rootName.empty() ? L"" : text("- " + rootName));
    GitStatusText().Text(L"");
    restoreWorkbenchState();
    setStatus(localizedText("Workspace loaded with ", simplifiedChinese_) +
              countLabel(state.snapshot->files.size(), "files", "文件", simplifiedChinese_));
}

void MainWindow::appendWorkspaceNode(
    TreeViewNode const& parent, const lithe::windows::WorkspaceNodeDto& item, bool isRoot) {
    TreeViewNode node;
    StackPanel label;
    label.Orientation(Orientation::Horizontal);
    label.Spacing(7);
    FontIcon icon;
    icon.Glyph(item.isDirectory ? L"\xE8B7" : L"\xE8A5");
    icon.FontSize(12);
    icon.Foreground(applicationBrush(L"LitheMutedTextBrush"));
    label.Children().Append(icon);
    TextBlock name;
    name.Text(text(item.name.empty() ? item.path : item.name));
    name.TextTrimming(TextTrimming::CharacterEllipsis);
    label.Children().Append(name);
    node.Content(label);
    node.IsExpanded(isRoot);
    treePaths_[objectKey(node)] = item.path;
    if (item.isDirectory) directoryPaths_.insert(item.path);
    if (parent) parent.Children().Append(node);
    else ProjectTree().RootNodes().Append(node);
    for (const auto& child : item.children) appendWorkspaceNode(node, child);
}

void MainWindow::renderDocument(lithe::windows::app::DocumentFeatureState state) {
    EditorProgress().IsActive(state.isLoading || state.isSaving);
    EditorProgress().Visibility(
        state.isLoading || state.isSaving ? Visibility::Visible : Visibility::Collapsed);
    if (state.error || state.isLoading || state.relativePath.empty()) return;
    if (!activePath_.empty() && state.relativePath != activePath_) return;
    activePath_ = state.relativePath;
    externalConflictVisible_ = state.hasExternalConflict;
    ExternalConflictBanner().Visibility(
        state.hasExternalConflict ? Visibility::Visible : Visibility::Collapsed);
    const bool markdown = activePath_.ends_with(".md") || activePath_.ends_with(".markdown");
    MarkdownModePanel().Visibility(markdown ? Visibility::Visible : Visibility::Collapsed);
    if (!markdown) {
        MarkdownPreviewPane().Visibility(Visibility::Collapsed);
        MarkdownPreviewColumn().Width(GridLength{0.0, GridUnitType::Pixel});
    }
    ensureEditorTab(activePath_);
    EditorTextBox().IsReadOnly(false);
    auto found = openDocuments_.find(activePath_);
    if (found == openDocuments_.end() || !dirtyPaths_.contains(activePath_)) {
        openDocuments_[activePath_] = state.text;
        found = openDocuments_.find(activePath_);
    } else {
        session_->setDocumentText(found->second);
    }
    editorUpdating_ = true;
    setEditorText(found->second);
    editorUpdating_ = false;
    if (markdown && MarkdownPreviewPane().Visibility() == Visibility::Visible) {
        renderMarkdownPreview(found->second);
    }
    EditorEmptyState().Visibility(Visibility::Collapsed);
    BreadcrumbText().Text(text(activePath_));
    if (!state.isDirty && !state.isSaving) {
        dirtyPaths_.erase(activePath_);
        updateTabHeader(activePath_);
        DocumentStateText().Text(ui("Saved"));
    } else {
        DocumentStateText().Text(ui("Modified"));
    }
    codeVision_.reset();
    javaStructure_.reset();
    if (blameVisible_) {
        blamePath_ = activePath_;
        blame_.reset();
        session_->loadGitBlame(activePath_);
    } else {
        blamePath_.clear();
        blame_.reset();
    }
    updateEditorPresentation();
    if (isJavaPath(activePath_)) {
        session_->activateJavaDocument(activePath_, found->second);
        session_->analyzeJavaDocument(activePath_, found->second);
    } else {
        session_->closeJavaDocument();
    }
    if (pendingNavigationLine_) {
        navigateEditor(*pendingNavigationLine_, pendingNavigationColumn_.value_or(0));
        pendingNavigationLine_.reset();
        pendingNavigationColumn_.reset();
    }
    if (!pendingHistoryContentPath_.empty() && activePath_ == selectedHistoryPath_) {
        auto contentPath = std::move(pendingHistoryContentPath_);
        pendingHistoryContentPath_.clear();
        session_->loadHistoryContent(std::move(contentPath));
    }
    setStatus(state.isSaving ? "Saving " + activePath_ : activePath_);
}

void MainWindow::renderSearch(lithe::windows::app::SearchFeatureState state) {
    if (state.isLoading || state.error) return;
    clearNavigationList(SearchResultsList());
    for (const auto& match : state.matches) {
        const auto line = match.line ? std::to_string(*match.line) : "-";
        auto item = makeListItem(match.path + ":" + line + "  " + match.preview);
        navigationTargets_[objectKey(item)] = NavigationTarget{
            match.path, std::nullopt, match.line && *match.line > 0 ? *match.line - 1 : 0, 0};
        SearchResultsList().Items().Append(item);
    }
    SearchSummaryText().Text(text(countLabel(
        state.matches.size(), "RESULTS", "结果", simplifiedChinese_)));
    SidebarTabs().SelectedIndex(2);
    setStatus(countLabel(
        state.matches.size(), "search results", "搜索结果", simplifiedChinese_));
}

void MainWindow::renderSearchEverywhere(
    lithe::windows::app::SearchEverywhereFeatureState state) {
    if (state.isLoading || state.error) return;
    auto targetList = searchEverywhereDialogResults_;
    if (!targetList) {
        targetList = SearchResultsList();
        SidebarTabs().SelectedIndex(2);
    }
    clearNavigationList(targetList);
    for (const auto& match : state.matches) {
        const auto line = match.line ? std::to_string(*match.line) : "-";
        const auto detail = match.symbolName.value_or(match.preview);
        auto item = makeListItem(
            "[" + match.kind + "] " + match.path + ":" + line + "  " + detail);
        navigationTargets_[objectKey(item)] = NavigationTarget{
            match.path, std::nullopt, match.line && *match.line > 0 ? *match.line - 1 : 0, 0};
        targetList.Items().Append(item);
    }
    if (targetList.Items().Size() > 0) targetList.SelectedIndex(0);
    setStatus(countLabel(state.matches.size(), "Search Everywhere results",
                         "全局搜索结果", simplifiedChinese_));
}

void MainWindow::renderGitChanges() {
    if (!gitStatus_) return;
    std::vector<std::string> blockingPaths = gitConflictPaths_;
    blockingPaths.insert(blockingPaths.end(),
                         pendingIntegrationPaths_.begin(),
                         pendingIntegrationPaths_.end());
    const auto checked = BlockedChangesFilterButton().IsChecked();
    const bool blockingOnly = checked && checked.Value();
    const auto rows = lithe::windows::buildGitChangeRows(
        *gitStatus_, blockingPaths, blockingOnly);
    ChangesList().Items().Clear();
    const auto branch = gitStatus_->branch.value_or("Detached HEAD");
    GitBranchText().Text(text(branch));
    GitStatusText().Text(text(branch));
    for (const auto& row : rows) {
        ChangesList().Items().Append(makeListItem(row.label, row.path));
    }
}

void MainWindow::renderGit(lithe::windows::app::GitFeatureState state) {
    gitConflictPaths_ = state.conflictFilterPaths;
    if (state.status && !state.isLoadingStatus) gitStatus_ = *state.status;
    if (state.isLoadingOperationState) {
        GitOperationText().Text(ui("Checking Git operation state..."));
    } else if (state.operationState) {
        pendingIntegration_.reset();
        pendingIntegrationPaths_.clear();
        const auto& operation = *state.operationState;
        std::string summary = "Git " + operation.kind + " is in progress";
        if (operation.step && operation.total) {
            summary += " (" + std::to_string(*operation.step) + "/" +
                std::to_string(*operation.total) + ")";
        }
        if (!operation.conflictedPaths.empty()) {
            summary += " - " + std::to_string(operation.conflictedPaths.size()) +
                " conflicted path(s)";
        }
        GitOperationText().Text(ui(summary));
        ContinueGitOperationButton().Content(box_value(ui("Continue")));
        ContinueGitOperationButton().Visibility(Visibility::Visible);
        AbortGitOperationButton().Content(box_value(ui("Abort")));
        AbortGitOperationButton().Visibility(Visibility::Visible);
        SkipGitOperationButton().Visibility(
            operation.kind == "rebase" ? Visibility::Visible : Visibility::Collapsed);
    } else if (pendingIntegration_) {
        GitOperationText().Text(text(
            "Git " + pendingIntegration_->operation + " pending: " +
            pendingIntegration_->reference));
        ContinueGitOperationButton().Content(box_value(ui("Retry")));
        ContinueGitOperationButton().Visibility(Visibility::Visible);
        AbortGitOperationButton().Content(box_value(ui("Cancel")));
        AbortGitOperationButton().Visibility(Visibility::Visible);
        SkipGitOperationButton().Visibility(Visibility::Collapsed);
    } else {
        GitOperationText().Text(L"");
        ContinueGitOperationButton().Content(box_value(ui("Continue")));
        ContinueGitOperationButton().Visibility(Visibility::Collapsed);
        AbortGitOperationButton().Content(box_value(ui("Abort")));
        AbortGitOperationButton().Visibility(Visibility::Collapsed);
        SkipGitOperationButton().Visibility(Visibility::Collapsed);
    }
    renderGitChanges();
    if (state.diff && !state.isLoadingDiff) renderDiff(*state.diff);
    if (state.history && !state.isLoadingHistory) {
        GitHistoryList().Items().Clear();
        for (const auto& commit : state.history->commits) {
            const auto decoration = commit.decorations.empty() ? "" : "  " + commit.decorations;
            GitHistoryList().Items().Append(makeListItem(
                commit.shortHash + "  " + commit.subject + decoration + "\n" +
                    commit.authorName + "  " + commit.date,
                commit.hash));
        }
    }
    if (state.stashes && !state.isLoadingStashes) {
        GitStashesList().Items().Clear();
        for (const auto& stash : state.stashes->stashes) {
            GitStashesList().Items().Append(makeListItem(
                stash.reference + "  " + stash.message + "\n" + stash.date,
                stash.reference));
        }
    }
    if (state.commit && !state.isLoadingCommit) {
        const auto& commit = state.commit->commit;
        GitDetailsText().Text(text(
            commit.shortHash + "  " + commit.subject + "\n" +
            commit.authorName + " <" + commit.authorEmail + ">  " + commit.date));
    }
    if (state.commitFiles && !state.isLoadingCommitFiles) {
        GitCommitFilesList().Items().Clear();
        for (const auto& file : state.commitFiles->files) {
            GitCommitFilesList().Items().Append(
                makeListItem(file.status + "  " + file.path, file.path));
        }
    }
    if (state.comparison && !state.isLoadingComparison) {
        GitDetailsText().Text(text(countLabel(
            state.comparison->files.size(), "files differ", "差异文件", simplifiedChinese_)));
        GitCommitFilesList().Items().Clear();
        for (const auto& file : state.comparison->files) {
            GitCommitFilesList().Items().Append(
                makeListItem(file.status + "  " + file.path, file.path));
        }
    }
    if (state.operationState && !state.isLoadingOperationState) {
        setStatus(simplifiedChinese_
            ? "Git " + state.operationState->kind + " 正在进行"
            : "Git " + state.operationState->kind + " in progress");
    }
    if (state.stashRestoreConflict) {
        if (state.stashRestoreConflict->deferred) {
            setStatus(simplifiedChinese_
                ? "本地修改已安全暂存，将在当前 Git 操作结束后恢复"
                : "Local changes are safely stashed until the current Git operation finishes");
        } else {
            setStatus(localizedText("Stash restore has ", simplifiedChinese_) +
                      countLabel(state.stashRestoreConflict->conflictedPaths.size(),
                                 "conflicted path(s)", "冲突路径", simplifiedChinese_));
        }
    }
    if (state.blame && !state.isLoadingBlame && blameVisible_ &&
        blamePath_ == activePath_) {
        blame_ = std::move(state.blame);
        updateLineNumbers();
        setStatus(countLabel(
            blame_->lines.size(), "Git blame lines", "Git Blame 行", simplifiedChinese_));
    }
}

void MainWindow::renderDiff(const lithe::windows::GitDiffDto& diff) {
    DiffRowsPanel().Children().Clear();
    DiffOverviewList().Items().Clear();
    selectedHunk_.clear();
    std::unordered_set<std::string> seenHunks;
    const auto weak = get_weak();
    for (const auto& row : diff.rows) {
        Grid line;
        line.MinHeight(24);
        line.ColumnDefinitions().Append(ColumnDefinition());
        line.ColumnDefinitions().Append(ColumnDefinition());
        line.ColumnDefinitions().Append(ColumnDefinition());
        line.ColumnDefinitions().Append(ColumnDefinition());
        line.ColumnDefinitions().GetAt(0).Width(GridLength{54, GridUnitType::Pixel});
        line.ColumnDefinitions().GetAt(1).Width(GridLength{1, GridUnitType::Star});
        line.ColumnDefinitions().GetAt(2).Width(GridLength{54, GridUnitType::Pixel});
        line.ColumnDefinitions().GetAt(3).Width(GridLength{1, GridUnitType::Star});
        if (row.kind == "addition") line.Background(applicationBrush(L"LitheAddedBrush"));
        else if (row.kind == "removal") line.Background(applicationBrush(L"LitheRemovedBrush"));
        else if (row.kind == "changed") line.Background(applicationBrush(L"LitheChangedBrush"));
        const auto oldLine = row.oldLine ? std::to_string(*row.oldLine) : "";
        const auto newLine = row.newLine ? std::to_string(*row.newLine) : "";
        line.Children().Append(diffCell(oldLine, 0, true));
        line.Children().Append(diffCell(row.left.value_or(""), 1));
        line.Children().Append(diffCell(newLine, 2, true));
        line.Children().Append(diffCell(row.right.value_or(""), 3));
        if (row.hunkId) {
            line.Tag(box_value(text(*row.hunkId)));
            line.Tapped([weak](IInspectable const& sender, Input::TappedRoutedEventArgs const&) {
                if (const auto self = weak.get()) {
                    const auto tag = sender.as<Grid>().Tag();
                    if (tag) self->selectedHunk_ = utf8(unbox_value<hstring>(tag));
                }
            });
            if (seenHunks.insert(*row.hunkId).second) {
                DiffOverviewList().Items().Append(makeListItem(
                    (simplifiedChinese_ ? "代码块 " : "Hunk ") +
                        std::to_string(seenHunks.size()),
                    *row.hunkId));
            }
        }
        DiffRowsPanel().Children().Append(line);
    }
    if (DiffOverviewList().Items().Size() > 0) {
        DiffOverviewList().SelectedIndex(0);
        selectedHunk_ = itemTag(DiffOverviewList().SelectedItem());
    }
    showBottomTool(5);
    setStatus(countLabel(diff.hunks.size(), "diff hunks", "差异代码块", simplifiedChinese_));
}

void MainWindow::renderHistory(lithe::windows::app::HistoryFeatureState state) {
    if (state.entries && !state.isLoadingEntries) {
        LocalHistoryList().Items().Clear();
        historyPaths_.clear();
        for (const auto& entry : state.entries->entries) {
            auto item = makeListItem(
                entry.relativePath + "  " + entry.reason + "  " +
                    std::to_string(entry.timestamp),
                entry.contentPath);
            historyPaths_[objectKey(item)] = entry.relativePath;
            LocalHistoryList().Items().Append(item);
        }
        AnalysisStatusText().Text(text(countLabel(
            state.entries->entries.size(), "history", "历史记录", simplifiedChinese_)));
    }
    if (state.content && !state.isLoadingContent) {
        if (!selectedHistoryPath_.empty() && selectedHistoryPath_ != activePath_) {
            loadedHistoryContent_.reset();
            setStatus("Open the snapshot file before comparing Local History");
            return;
        }
        loadedHistoryContent_ = state.content->text;
        const auto current = activePath_.empty() ? std::string{} : editorText();
        const auto alignedRows = lithe::windows::algorithms::diffTextLines(
            lines(state.content->text), lines(current));
        lithe::windows::GitDiffDto snapshotDiff;
        snapshotDiff.rows.reserve(alignedRows.size());
        bool hasChanges = false;
        for (const auto& aligned : alignedRows) {
            lithe::windows::GitDiffRowDto row;
            if (aligned.oldLine) row.oldLine = *aligned.oldLine;
            if (aligned.newLine) row.newLine = *aligned.newLine;
            row.left = aligned.left;
            row.hasRight = aligned.right.has_value();
            row.right = aligned.right;
            switch (aligned.kind) {
            case lithe::windows::algorithms::DiffRowKind::Context:
                row.kind = "context";
                break;
            case lithe::windows::algorithms::DiffRowKind::Changed:
                row.kind = "changed";
                hasChanges = true;
                break;
            case lithe::windows::algorithms::DiffRowKind::Addition:
                row.kind = "addition";
                hasChanges = true;
                break;
            case lithe::windows::algorithms::DiffRowKind::Removal:
                row.kind = "removal";
                hasChanges = true;
                break;
            case lithe::windows::algorithms::DiffRowKind::Information:
                row.kind = "information";
                break;
            }
            if (!aligned.hunkId.empty()) row.hunkId = aligned.hunkId;
            snapshotDiff.rows.push_back(std::move(row));
        }
        if (hasChanges) snapshotDiff.hunks.push_back(
            {"history-snapshot", "@@ Local History @@", {}});
        renderDiff(snapshotDiff);
        setStatus("Local History snapshot compared with the current editor");
    }
}

void MainWindow::renderShelves(lithe::windows::app::ShelfFeatureState state) {
    if (!state.shelves || state.isLoading) return;
    GitShelvesList().Items().Clear();
    for (const auto& shelf : state.shelves->shelves) {
        const auto sizes = simplifiedChinese_
            ? "\n已暂存 " + std::to_string(shelf.stagedByteCount) +
                  " B  工作区 " + std::to_string(shelf.workingTreeByteCount) + " B"
            : "\nStaged " + std::to_string(shelf.stagedByteCount) +
                  " B  Worktree " + std::to_string(shelf.workingTreeByteCount) + " B";
        GitShelvesList().Items().Append(makeListItem(shelf.label + sizes, shelf.id));
    }
    setStatus(countLabel(
        state.shelves->shelves.size(), "Shelves", "Shelf", simplifiedChinese_));
}

void MainWindow::renderAnalysis(lithe::windows::app::MavenJavaFeatureState state) {
    std::vector<std::string> summary;
    if (state.diagnostics && !state.isLoadingDiagnostics) {
        clearNavigationList(ProblemsList());
        for (const auto& issue : state.diagnostics->issues) {
            auto item = makeListItem(
                issue.severity + "  " + issue.path + ":" + std::to_string(issue.line) +
                "  " + issue.message);
            navigationTargets_[objectKey(item)] = NavigationTarget{
                issue.path, std::nullopt, issue.line > 0 ? issue.line - 1 : 0,
                issue.column && *issue.column > 0 ? *issue.column - 1 : 0};
            ProblemsList().Items().Append(item);
        }
        summary.push_back(countLabel(
            state.diagnostics->issues.size(), "problems", "问题", simplifiedChinese_));
    }
    if (state.maven && !state.isLoadingMaven && state.maven->scan) {
        const auto& scan = *state.maven->scan;
        summary.push_back("Maven " + scan.artifactId);
    }
    if (state.runConfigurations && !state.isLoadingRunConfigurations) {
        RunConfigurationBox().Items().Clear();
        for (const auto& configuration : state.runConfigurations->configurations) {
            RunConfigurationBox().Items().Append(
                makeListItem(configuration.name + "  [" + configuration.kind + "]",
                             configuration.id));
        }
        if (RunConfigurationBox().Items().Size() > 0) RunConfigurationBox().SelectedIndex(0);
        summary.push_back(countLabel(state.runConfigurations->configurations.size(),
                                     "run configs", "运行配置", simplifiedChinese_));
    }
    bool annotationsChanged = false;
    if (isJavaPath(activePath_) && !isExternalDocument(activePath_)) {
        if (state.codeVision && !state.isLoadingCodeVision) {
            codeVision_ = state.codeVision;
            annotationsChanged = true;
            summary.push_back(countLabel(
                codeVision_->hints.size(), "code hints", "代码提示", simplifiedChinese_));
        }
        if (state.structure && !state.isLoadingStructure) {
            javaStructure_ = state.structure;
            annotationsChanged = true;
            summary.push_back(countLabel(javaStructure_->foldRegions.size(),
                                         "fold regions", "折叠区域", simplifiedChinese_));
        }
    } else if (codeVision_ || javaStructure_) {
        codeVision_.reset();
        javaStructure_.reset();
        annotationsChanged = true;
    }
    if (annotationsChanged) updateLineNumbers();
    if (!summary.empty()) AnalysisStatusText().Text(text(joinValues(summary)));
}

void MainWindow::appendDebugVariable(
    const lithe::windows::app::JavaDebugVariable& variable, int depth) {
    const auto marker = variable.canExpand()
        ? (variable.isExpanded ? "- " : "+ ") : "  ";
    auto item = makeListItem(
        std::string(static_cast<std::size_t>(std::max(0, depth)) * 2, ' ') +
        marker + variable.name + " = " + variable.value);
    debugVariableIDs_[objectKey(item)] = variable.id;
    DebugVariablesList().Items().Append(item);
    for (const auto& child : variable.children) appendDebugVariable(child, depth + 1);
}

void MainWindow::renderJavaDebug(lithe::windows::app::JavaDebugSnapshot snapshot) {
    debugSnapshot_ = snapshot;
    debugVariableIDs_.clear();
    DebugVariablesList().Items().Clear();
    DebugThreadsList().Items().Clear();
    DebugStackList().Items().Clear();
    for (const auto& variable : snapshot.variables) appendDebugVariable(variable, 0);
    for (const auto& thread : snapshot.threads) {
        DebugThreadsList().Items().Append(makeListItem(
            std::string(thread.isCurrent ? "* " : "") + thread.name + "  " + thread.status,
            thread.id));
    }
    for (const auto& frame : snapshot.callStack) {
        DebugStackList().Items().Append(makeListItem(
            "[" + std::to_string(frame.level) + "] " + frame.description));
    }
    std::string output = snapshot.output;
    if (snapshot.inspectionTitle && !snapshot.inspectionOutput.empty()) {
        output += "\n--- " + *snapshot.inspectionTitle + " ---\n" +
            snapshot.inspectionOutput;
    }
    DebugOutputBox().Text(text(output));
    DebugOutputBox().Select(static_cast<int32_t>(DebugOutputBox().Text().size()), 0);
    updateLineNumbers();
    const char* state = "idle";
    switch (snapshot.state) {
    case lithe::windows::app::JavaDebugSessionState::Idle: state = "idle"; break;
    case lithe::windows::app::JavaDebugSessionState::Launching: state = "launching"; break;
    case lithe::windows::app::JavaDebugSessionState::Running: state = "running"; break;
    case lithe::windows::app::JavaDebugSessionState::Paused: state = "paused"; break;
    case lithe::windows::app::JavaDebugSessionState::Finished: state = "finished"; break;
    case lithe::windows::app::JavaDebugSessionState::Failed: state = "failed"; break;
    }
    const auto title = snapshot.runningTargetTitle.empty()
        ? std::string("Debugger") : snapshot.runningTargetTitle;
    if (snapshot.exceptionMessage) {
        setStatus(title + ": " + *snapshot.exceptionMessage);
    } else {
        setStatus(localizedText(title, simplifiedChinese_) + ": " +
                  localizedText(state, simplifiedChinese_) + " (" +
                  countLabel(snapshot.breakpoints.size(), "breakpoints", "断点",
                             simplifiedChinese_) + ")");
    }
}

void MainWindow::renderLanguageServerState(bool ready, std::string message) {
    AnalysisStatusText().Text(ui(ready ? "JDT ready" : "JDT starting"));
    if (!message.empty()) setStatus(std::move(message));
}

void MainWindow::renderJavaDiagnostics(
    lithe::windows::winui::JavaDiagnosticsResult result) {
    clearNavigationList(ProblemsList());
    for (const auto& issue : result.items) {
        auto item = makeListItem(
            issue.severity + "  " + result.relativePath + ":" +
            std::to_string(issue.line + 1) + ":" +
            std::to_string(issue.utf16Column + 1) + "  " + issue.message);
        navigationTargets_[objectKey(item)] = NavigationTarget{
            result.relativePath, std::nullopt, issue.line, issue.utf16Column};
        ProblemsList().Items().Append(item);
    }
    AnalysisStatusText().Text(text(countLabel(
        result.items.size(), "Java diagnostics", "Java 诊断", simplifiedChinese_)));
}

void MainWindow::renderJavaNavigation(
    lithe::windows::winui::JavaNavigationResult result) {
    if (!result.error.empty()) {
        setStatus(result.title + ": " + result.error);
        return;
    }
    clearNavigationList(SearchResultsList());
    for (const auto& location : result.locations) {
        auto item = makeListItem(
            location.displayPath + ":" + std::to_string(location.line + 1) + ":" +
            std::to_string(location.utf16Column + 1));
        navigationTargets_[objectKey(item)] = NavigationTarget{
            location.relativePath, location.absolutePath,
            location.line, location.utf16Column};
        SearchResultsList().Items().Append(item);
    }
    SearchSummaryText().Text(text(
        localizedText(result.title, simplifiedChinese_) + " - " +
        countLabel(result.locations.size(), "RESULTS", "结果", simplifiedChinese_)));
    SidebarTabs().SelectedIndex(2);
    setStatus(localizedText(result.title, simplifiedChinese_) + ": " + countLabel(
        result.locations.size(), "results", "结果", simplifiedChinese_));
}

void MainWindow::renderAICommitResult(
    lithe::windows::winui::AICommitGenerationResult result) {
    if (!result.error.empty()) {
        setStatus("AI message failed: " + result.error);
        return;
    }
    CommitMessageBox().Text(text(result.message));
    showBottomTool(4);
    CommitMessageBox().Focus(FocusState::Programmatic);
    setStatus("AI commit message ready");
}

fire_and_forget MainWindow::renderUpdateCheck(
    lithe::windows::winui::WindowsUpdateCheckResult result) {
    const auto lifetime = get_strong();
    if (result.upToDate) {
        setStatus("Lithe is up to date");
        co_return;
    }
    if (!result.release || !result.asset) {
        setStatus("Update check failed: " +
                  (result.error.empty() ? std::string("Unknown error") : result.error));
        co_return;
    }
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Windows update available"));
    dialog.Content(box_value(text(
        "Lithe " + result.release->version +
        " is available. Download the verified installer?")));
    dialog.PrimaryButtonText(L"Download");
    dialog.CloseButtonText(L"Later");
    dialog.DefaultButton(ContentDialogButton::Primary);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;

    Windows::Storage::Pickers::FileSavePicker picker;
    check_hresult(picker.as<IInitializeWithWindow>()->Initialize(windowHandle()));
    const auto assetPath = pathFromUtf8(result.asset->name);
    auto extension = pathUtf8(assetPath.extension());
    if (extension.empty()) extension = ".exe";
    auto extensions = single_threaded_vector<hstring>();
    extensions.Append(text(extension));
    picker.FileTypeChoices().Insert(L"Windows installer", extensions);
    picker.SuggestedFileName(text(pathUtf8(assetPath.stem())));
    const auto file = co_await picker.PickSaveFileAsync();
    if (!file) co_return;
    session_->downloadUpdate(*result.asset, std::filesystem::path(file.Path().c_str()));
}

fire_and_forget MainWindow::renderUpdateDownload(
    lithe::windows::winui::WindowsUpdateDownloadResult result) {
    const auto lifetime = get_strong();
    if (!result.succeeded) {
        setStatus("Update download failed: " +
                  (result.error.empty() ? std::string("Unknown error") : result.error));
        co_return;
    }
    setStatus("Verified installer downloaded");
    ContentDialog dialog;
    dialog.XamlRoot(RootGrid().XamlRoot());
    dialog.Title(box_value(L"Installer ready"));
    dialog.Content(box_value(
        L"The SHA-256 and Authenticode verified installer is ready. Launch it now?"));
    dialog.PrimaryButtonText(L"Install now");
    dialog.CloseButtonText(L"Later");
    dialog.DefaultButton(ContentDialogButton::Primary);
    if (co_await showDialog(dialog) != ContentDialogResult::Primary) co_return;

    std::wstring executable(32768, L'\0');
    const auto length = GetModuleFileNameW(
        nullptr, executable.data(), static_cast<DWORD>(executable.size()));
    if (length == 0 || length >= executable.size()) {
        setStatus("Could not locate the Windows update helper");
        co_return;
    }
    executable.resize(length);
    const auto helper = std::filesystem::path(executable).parent_path() /
        L"lithe_windows_update_helper.exe";
    if (!std::filesystem::is_regular_file(helper)) {
        setStatus("Could not locate the Windows update helper");
        co_return;
    }
    const auto arguments = L"--pid " + std::to_wstring(GetCurrentProcessId()) +
        L" --installer \"" + result.destination.wstring() + L"\"";
    const auto launched = reinterpret_cast<INT_PTR>(ShellExecuteW(
        windowHandle(), L"open", helper.c_str(), arguments.c_str(),
        helper.parent_path().c_str(), SW_SHOWNORMAL));
    if (launched <= 32) {
        setStatus("Could not launch the Windows update helper");
        co_return;
    }
    setStatus("Closing Lithe to install the update");
    PostMessageW(windowHandle(), WM_CLOSE, 0, 0);
}

void MainWindow::renderTerminalOutput(std::string id) {
    if (id != activeTerminalID_) return;
    TerminalOutputBox().Text(text(session_->terminalOutput(id)));
    TerminalOutputBox().Select(
        static_cast<int32_t>(TerminalOutputBox().Text().size()), 0);
}

void MainWindow::renderTerminals(lithe::windows::app::TerminalFeatureState state) {
    if (state.revision < terminalRevision_) return;
    terminalRevision_ = state.revision;
    terminalUiUpdating_ = true;
    activeTerminalID_ = state.activeSessionID.value_or(std::string{});
    TerminalSessionsBox().Items().Clear();
    int32_t selectedIndex = -1;
    for (const auto& terminal : state.sessions) {
        std::string status;
        switch (terminal.status) {
        case lithe::windows::app::TerminalSessionStatus::Starting: status = "Starting"; break;
        case lithe::windows::app::TerminalSessionStatus::Running: status = "Running"; break;
        case lithe::windows::app::TerminalSessionStatus::Exited: status = "Exited"; break;
        case lithe::windows::app::TerminalSessionStatus::Stopped: status = "Stopped"; break;
        }
        auto title = terminal.title;
        constexpr std::string_view prefix = "Terminal ";
        if (title.starts_with(prefix)) {
            title = localizedText("Terminal", simplifiedChinese_) +
                title.substr(prefix.size() - 1);
        }
        TerminalSessionsBox().Items().Append(makeListItem(
            title + "  [" + localizedText(status, simplifiedChinese_) + "]", terminal.id));
        if (terminal.id == activeTerminalID_) {
            selectedIndex = static_cast<int32_t>(TerminalSessionsBox().Items().Size()) - 1;
            TerminalShellBox().Text(text(terminal.shellPath));
        }
    }
    TerminalSessionsBox().SelectedIndex(selectedIndex);
    if (selectedIndex < 0) TerminalShellBox().Text(L"");
    terminalUiUpdating_ = false;
    renderTerminalOutput(activeTerminalID_);
}

void MainWindow::appendBuildOutput(std::string output) {
    auto current = utf8(BuildOutputBox().Text());
    current += output;
    constexpr std::size_t maximum = 500000;
    if (current.size() > maximum) current.erase(0, current.size() - maximum);
    BuildOutputBox().Text(text(current));
    BuildOutputBox().Select(static_cast<int32_t>(BuildOutputBox().Text().size()), 0);
}

void MainWindow::RefreshAnalysisClick(IInspectable const&, RoutedEventArgs const&) {
    session_->scanProject();
    if (isJavaPath(activePath_) && !isExternalDocument(activePath_)) {
        session_->analyzeJavaDocument(activePath_, editorText());
    }
    showBottomTool(2);
}

void MainWindow::ClearProblemsClick(IInspectable const&, RoutedEventArgs const&) {
    clearNavigationList(ProblemsList());
}

} // namespace winrt::Lithe::implementation
