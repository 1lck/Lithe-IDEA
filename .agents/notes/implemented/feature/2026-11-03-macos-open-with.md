# Agent 笔记：项目树的“打开于”与“打开方式”

状态：已实现

## 先说结论

项目树右键菜单底部有一个“打开于”二级菜单，里面是“打开方式”（只对文件）、“访达”（Windows 上是“资源管理器”）和“终端”。
“打开方式”和 Finder 的同名菜单一样：先列出系统为这个文件提供的应用，默认应用在最前并标“（默认）”，最后是“其他…”，用来选择任意应用。
应用列表直接向操作系统查询（macOS 的 LaunchServices，Windows 的 Shell 关联处理器），Lithe 不维护应用名单；查询和打开都在 `desktop/internal/fileapps`，菜单在 `filetree_openin.go`。
这里只选择这一次用哪个应用打开，不修改系统默认关联；文件只作为已保存的磁盘路径交给应用。

## 问题

IDE 无法直接展示的格式（DOCX、图片、设计稿等）仍需要外部应用。旧菜单在顶部放“用其他应用打开…”，每次都弹出应用选择器，要用户自己在 `/Applications` 里找；底部的“在访达中显示”又是另一条孤立入口。
用户期望的是 macOS 和 Windows 自带的“打开方式”：系统已经知道哪些应用能打开这个文件、哪个是默认的，菜单应该直接列出来。

## 决策

- 菜单结构：文件行和文件夹行的右键菜单底部都有“打开于 ›”，取代原来的“用其他应用打开…”和“在访达中显示”。
  - “打开方式 ›”只在文件行出现：默认应用、分隔线、其他应用、分隔线、“其他…”。
  - “访达/资源管理器”在系统文件管理器中显示该项，行为与原来的“在访达中显示”相同。
  - “终端”在 Lithe 内置终端中新开一个终端，起始目录是该文件夹，或文件所在的文件夹；随后打开终端工具窗口并把键盘焦点交给它。
- 应用列表的来源只有操作系统：
  - macOS 用 `NSWorkspace` 的 `URLForApplicationToOpenURL`（默认应用）和 `URLsForApplicationsToOpenURL`（全部应用），名称取 `displayNameAtPath`，按本地化名称排序。这是 Finder 自己用的数据。
  - Windows 用 `SHAssocEnumHandlers(ASSOC_FILTER_RECOMMENDED)`，即资源管理器“打开方式”中的推荐列表；默认项由 `AssocQueryStringW` 查出的程序或友好名称匹配后放到最前，其余保持系统给出的顺序。
  - 两个应用同名时（例如 `/Applications` 和 `~/Applications` 各有一份），名称后面带所在文件夹，用户才分得清。
  - Linux 不查询，只有“其他…”。
- 查询在后台进行。“打开于”子菜单一出现（鼠标停留展开或点击展开都算）就开始，在声明子菜单的那一帧里直接启动，不经过 `ui.C.After`：悬停展开的那一帧没有点击，推迟的回调会被丢弃，菜单就会一直停在“正在查找应用…”（见 [悬停打开“打开于”时也要查询应用](../bug-fix/2026-11-18-open-with-lookup-on-hover.md)）。
  - 这个文件还没有结果时显示“正在查找应用…”。
  - 每次重新打开菜单都重新查询，所以系统关联的修改会立即反映；查询期间先显示同一文件上一次的列表，查询完成后替换。换了文件时先清空旧列表，不会把别的文件的应用列给这个文件。
- 打开选中的应用：
  - macOS 交给 Viva 的 `app.OpenWith`（`/usr/bin/open -a`），它会等待命令结束，所以放在后台运行。
  - Windows 重新列出处理器，按名称找到同一个处理器后调用 `IAssocHandler::Invoke`。商店应用（打包应用）没有可执行文件路径，只能这样打开。系统已不再提供该处理器时，提示“已不能打开这类文件”。
- “其他…”保留原来的做法：经平台的应用选择器选出应用，再用 `app.OpenWith` 打开（`filetree_open.go`）。取消选择器不打开任何文件；失败时显示系统给出的原因。
- 文件只作为磁盘路径交给应用，不读取内容、不自动保存编辑器草稿。不修改系统默认关联，不写入安装目录、发行包或任何缓存。

正确做法：需要知道“谁能打开这个文件”时，调用 `fileapps.List`；选中后调用 `fileapps.Open`。
不要这样做：在界面里写死 WPS、VS Code 之类的应用名单，按扩展名猜应用，或固定扫描 `/Applications`。

## 考虑过的备选方案

- 只保留应用选择器（本 Note 之前的决策）：每次都要手动找应用，系统已知的默认和推荐用不上。已被本决策取代，选择器降为“其他…”。
- 嵌入 Finder 或资源管理器自带的整个子菜单：没有公开的可嵌入接口，Viva 的菜单也不是系统原生菜单，不调用私有 API。
- 维护扩展名与应用的名单：会漏掉用户安装的应用和用户修改过的关联，不采用。
- 把查询接口加进 Viva 工具包：适合以后迁移，但 Viva 的固定版本由用户团队维护，这次改动不应等待 fork 合入和升级固定版本。系统查询是平台适配代码，没有可以共享的业务规则，所以也不放进 Rust Core。`fileapps` 包只依赖操作系统接口，以后迁到 Viva 时整个包搬走即可。
- “终端”打开系统的“终端”应用：IDE 用户更常用内置终端，而且 IntelliJ IDEA 的“Open In › Terminal”也是打开内置终端，所以不跳出 Lithe。
- 在菜单中显示应用图标：需要提取并缓存每个应用的图标，Viva 菜单项目前也没有从文件取图标的接口，这次不做。

## 后果

用户可以像在 Finder 里一样，从右键菜单直接选系统推荐的应用打开项目中的文件；需要别的应用时仍有“其他…”。
代价是每次打开“打开于”都要查询一次系统（通常在几十毫秒内），第一次查询期间会短暂显示“正在查找应用…”。
Finder 和资源管理器对列表排序没有公开的一致性保证，Lithe 不能声称与系统菜单逐项相同。
Windows 上“其他…”仍是选择 `.exe`，不会列出商店应用。
应用列表不落盘，查询和打开不产生缓存或下载，不改变代码签名或 Sparkle 增量更新的源字节。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/fileapps ./internal/workbench -run 'TestList|TestLabels|TestMarkDefault|TestProjectTreeOpen' -count=1 -v`（在 `desktop/` 下运行）：`fileapps` 的测试查询本机真实数据库并在日志里列出应用；`TestProjectTreeOpen*` 用替换的应用列表覆盖菜单结构、选择应用、失败提示、文件夹行、“终端”的起始目录，以及用鼠标停留（而不是点击）打开两级子菜单时也会查询并列出应用。
- `scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualProjectTreeOpenIn$' -count=1`（在 `desktop/` 下设置 `LITHE_VISUAL_OUTPUT_DIR` 后运行）：生成 `docs/assets/project-tree-open-in/` 中的截图。
- 真实产品需要在 macOS 和 Windows 上分别对 DOCX、图片、Markdown、无扩展名文件右键，与 Finder、资源管理器的“打开方式”对照，并检查中英文、深浅主题、“其他…”的选择和取消、打开失败的提示。完成前功能矩阵 `file-open-with` 保持 pending。

## 适用范围

- `desktop/internal/fileapps/`
- `desktop/internal/workbench/filetree_openin.go`
- `desktop/internal/workbench/filetree_open.go`
- `desktop/internal/workbench/filetree_menu.go`
- 项目树中的“打开于”菜单；不改变双击、“打开”、编辑器标签菜单或系统默认应用关联。
