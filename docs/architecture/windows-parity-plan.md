# Windows 功能追平开发计划

目标：让 `windows/`（Qt Widgets + C++）实现与当前 macOS SwiftUI 版本一致的产品功能，
共享 `rust/lithe-core` 作为唯一应用运行时，并遵守 `shared/contracts/` 的契约。

## 一、现状盘点

### 代码量对比

| 层 | macOS (Swift) | Windows (C++) | 说明 |
| --- | --- | --- | --- |
| Rust core | 6,640 行（共享） | 6,640 行（共享） | 30 个命令，C ABI 已通 |
| 应用/服务/模型 | 约 12,700 行 | 0 | 需要在 C++ 重写的业务逻辑 |
| 视图 | 16,057 行 | 214 行 | Qt 重写 |
| 平台适配 | 2,436 行 | 1,251 行 | 端口已铺好一半 |
| 合计 | 34,928 行 | 1,465 行 | |

### 预留的服务能力层确实可用

三处预留是这次开发的地基，都能直接用：

- `rust/lithe-core` 的 C ABI（`lithe_core_version` / `execute_json` / `cancel` / `free_string`），
  头文件在 `rust/lithe-core/include/lithe_core.h`，crate 已声明 `staticlib` 与 `cdylib`。
- `windows/core/core_client.cpp` 已经封装好 JSON 信封与字符串所有权，Qt 侧可以直接
  用 `QJsonDocument` 解析。
- `windows/adapters/ports.h` 是 `Sources/Lithe/Core/Ports/` 的 C++ 镜像，7 个端口已有
  Win32 实现（进程、会话、ConPTY、目录监听、文件系统、运行时定位、键值存储）。

`scripts/verify-windows-boundaries.sh` 已经在防止 Windows 侧反向依赖 macOS 代码，
继续保留这条边界检查。

### Rust core 已覆盖（Windows 免费获得）

Git 是最大的红利：`Sources/Lithe/Core/RustGitOperations.swift` 的 40 个方法全部是薄封装，
`GitService.swift` 不含业务逻辑。Windows 侧只要发 JSON 就能得到状态、提交、分支、
diff、分块暂存、历史、blame、stash 的完整能力。

同样已覆盖：工作区快照/搜索/全局搜索/替换预览、文件读写、本地历史、Maven POM 解析与
编译诊断解析、Java 运行配置发现、code vision、类名解析、定义定位、Spring 端口解析、
Java 结构解析。

### Rust core 未覆盖（必须在 Windows 侧实现）

1. LSP / JDT LS 客户端 —— 全部在 Swift（约 800 行真实逻辑）
2. 调试 —— 驱动 `jdb` CLI 并解析英文文本输出（约 700 行）
3. Java/Maven/jdb/终端的进程编排（Rust 只在内部 spawn `git`）
4. JDK/Maven 运行时发现与环境变量构造（注意：`rust/lithe-core/src/runtime.rs` 是命令分发器，不是运行时发现）
5. 终端 ConPTY 与 ANSI/VT 解析
6. 全部 HTTP —— AI 提交信息、更新检查
7. AI 提供方配置、凭据存储、提示词构造、请求/响应编解码
8. 更新检查、下载、校验、安装
9. 设置与会话持久化
10. 语法高亮与 diff 分词（Swift 里是两套独立实现）
11. Diff 视图模型算法（配对、折叠、分栏布局、行内变更区间）
12. Git 提交图泳道布局、分支引用树构建、文件可见性规则
13. ZIP 条目读取、剪贴板、文件对话框、资源管理器定位、全局快捷键

## 二、先补端口，再谈功能

`ports.h` 只镜像了 12 个 Swift 端口中的 7 个。缺的 5 类是后续所有功能的前置依赖，
成本低，应该第一步做完：

| 待补端口 | 用途 | Windows 实现方向 |
| --- | --- | --- |
| `SecureStore` | 保存 AI 提供方密钥 | DPAPI 或凭据管理器 |
| `AIHTTPTransport` | AI 提交信息、更新检查 | `QNetworkAccessManager` 或 WinHTTP |
| `AIConfigurationSource` | 读取 Claude/Codex 本地配置 | `%USERPROFILE%` 下的同名文件 |
| `ArchiveEntryReader` | LSP 读取 `src.zip` 里的 JDK 源码 | `QuaZip` 或 minizip |
| `PlatformUI` + `ShortcutDetector` | 目录选择、资源管理器定位、剪贴板、双击 Shift | Qt 对话框 + 全局键钩子 |
| `FileStorage` 目录访问 | home / cache / appdata 三个目录 | `QStandardPaths` |

另有两处签名需要补齐：

- `ProcessRequest` 缺 `standardInput` 与 `keepsStandardInputOpen`。JDT LS 与 jdb 都要求
  stdin 常开（对应 `JavaLanguageService.swift:284` 与 `JavaDebugService.swift:486`），
  不补这两个字段，Java 语言服务和调试都起不来。
- `RuntimeLocator` 在 `ports.h` 里只有 `discover()`，Swift 侧有 8 个方法；
  `win32_runtime_locator.cpp` 现在 57 行，不足以支撑 parity。

## 三、分阶段计划

### 阶段 0：工程化打通（1 周）

先让 Windows 能真正编译出可运行的东西，否则后面所有代码都无法验证。

- Rust core 交叉编译到 `x86_64-pc-windows-msvc`，产出 `staticlib` 供 CMake 链接，
  接到现有的 `LITHE_RUST_CORE_LIBRARY` 缓存变量上。
- 新增 `.github/workflows/ci-windows.yml`（`runs-on: windows-latest`）：构建 Rust core、
  构建 CMake 目标、跑契约与边界校验脚本。当前 CI 只有 `release-macos.yml`，
  Windows 侧没有任何自动验证。
- 把 `scripts/verify-windows-boundaries.sh` 的等价逻辑做成可在 Windows runner 上跑的版本
  （现在是 zsh + rg，依赖 macOS 环境）。
- 验证 `git.exe` 解析：Rust 内部用 `Command::new("git")`，Windows 上需要确认 PATH 查找
  与无 shell 传参的行为，`git.rs:1115` 已有一处 `#[cfg(windows)]`，需要覆盖测试。

产出判据：CI 绿灯，`lithe_windows_qt` 能启动并完成 `core.ping`。

### 阶段 1：纯算法移植（1.5 周）

这批代码没有 I/O，可以直接对着 `shared/fixtures/` 写单元测试，是风险最低、
收益最直接的部分，约 1,100 行。

移植清单：`DiffPairing`、`DiffCollapse`、`DiffSplitLayout`、行内变更区间
（`DiffReviewView.swift:1461` 的 `changedRange`）、`GitGraphLayoutService`（提交图泳道）、
`FileVisibilityRules`、`TerminalBuffer`（5 状态 VT 解析器）、两套分词器
（`CodeEditorView.swift:2132` 的正则高亮器 + `DiffReviewView.swift:1482` 的字符扫描器）、
语义化版本比较、shell 风格参数分词器、`GitLogView.swift:1003` 的分支引用树构建。

注意 `TerminalBuffer` 目前不解析 SGR，终端输出是单色的。Qt 侧可以照搬这个设计，
也可以顺手升级成带颜色的 VT 模拟器 —— 这是一个明确的产品选择点，建议先照搬保持一致。

### 阶段 2：工作区骨架补完（2 周）

`windows/qt/workbench_window.cpp` 现在 201 行，只有项目选择、树浏览、读写、搜索、刷新。
补到与 macOS 工作台同构：

- 欢迎窗口（最近项目、打开、克隆）
- 工作台窗口：标题栏、侧边栏导轨、编辑器区、工具窗口、可拖拽分隔条
- 编辑器标签页、查找栏、Markdown 预览
- 项目树的创建/重命名/复制/删除、定位、复制路径
- 设置对话框六个页签（项目、通用、编辑器、终端、AI 与提交、更新）
- 会话与布局持久化（`AppSettings`、`WorkspaceSessionStore`、`WorkbenchLayoutStore`、
  `RecentProjectsStore` 的 C++ 等价物，落到 `KeyValueStore`）

重要架构决定：**不要复制 `AppModel`**。它 1,838 行里约 450 行是纯转发属性，
只为满足 SwiftUI 单一绑定对象的约束而存在。Qt 应该让控件直接连到各个 feature model 的信号，
这 450 行不需要出现在 Windows 侧。`AppModel` 里真正要移植的约 500 行是：
`openProject`/`closeProject` 的会话恢复、AI 配置自动导入决策、提交信息暂存的
应用/丢弃、面板互斥规则、导航分发。

### 阶段 3：Git 与历史（1.5 周）

因为 Rust 已覆盖，这一阶段主要是 UI 与工作流编排：

- 变更侧边栏（暂存/未暂存、stash、提交框、amend 开关）
- Git Log 与提交图、分支切换气泡、分支比较
- Diff 审阅视图（分栏、缩略图、折叠带、分块暂存/取消暂存/丢弃）
- 本地历史（按文件、按项目）
- 克隆仓库对话框

要照抄的一处细节：`GitFeatureModel.swift:199` 的 `stagedCommitMessageInput()`
故意绕过工作树 diff，逐文件用 `staged: true` 重新查询，这样同时有暂存与未暂存修改的文件
才能被正确表示。这个很容易写错。

### 阶段 4：运行时与 Java 工具链（3.5 周）

这是最重的一段，且必须按顺序做。

1. **`ProjectRuntimeService` 的 C++ 版**（约 180 行逻辑）—— 阻塞后面所有 Java 功能。
   现有 Swift 实现的路径语义完全是 POSIX（`bin/java`、符号链接解析、`/` 开头判断），
   Windows 需要重写为 `bin\java.exe`、`mvn.cmd`，并从注册表读 `JAVA_HOME`。
   同时把 `win32_runtime_locator.cpp` 从 57 行补到能覆盖注册表、常见安装路径、
   `JAVA_HOME` 与 Chocolatey/Scoop 位置。
2. **Maven 服务编排**（约 120 行）—— 解析已在 Rust，Windows 侧只需 `-B -ntp` 基础参数、
   `-pl`/`-P` 组装、阶段到任务标题的映射、进程生命周期与输出缓冲。
3. **运行服务**（约 550 行）—— 多模块会话、全部运行/停止/重启、类路径解析、
   工作目录解析、端口冲突检测（扫 VM 参数、程序参数与 `application.properties`）。
4. **LSP 客户端**（约 800 行）—— 价值最高、工作量也最大。
   需要 `Content-Length` 帧编解码（含半包处理）、JSON-RPC 请求/通知/响应多路复用、
   jdtls 启动参数与按项目哈希的 data 目录、文档同步版本号、
   以及 JDK 源码解析路径（`jdt://` URI 重写、`src.zip` 两种条目命名、
   `java.decompile` 兜底、hover 抓取兜底）。
   Qt 的 `QString` 本身是 UTF-16，正好对上 Swift 侧基于 UTF-16 码元的标识符提取。
   要复现一个 JDT LS 的怪癖：`workspace/configuration` 需要对同一个 inlay hint 设置
   返回四种不同的嵌套形状（`JavaLanguageService.swift:469`）。
5. **问题面板与引用面板** —— 诊断聚合与导航结果状态。

### 阶段 5：调试（2 周，风险最高）

`JavaDebugService` 不走 JDWP，而是驱动 `jdb` CLI 并按英文字符串抓取输出。
两个必须保留的细节：jdb 启动参数里的 `-J-Duser.language=en -J-Duser.country=US`
是承重的（所有解析都依赖英文输出）；attach 竞态靠"看到 `Listening for transport`"触发，
5 秒定时器兜底（Maven 会缓冲那一行），随后延迟 900ms 再重放断点并 `run`。

建议在阶段 0 就先手工验证一次 Windows 上 jdb 的输出格式与管道行缓冲行为，
如果差异过大，就要评估改走 JDWP 协议 —— 那是一个明显更大的工作量，需要提前决策。

### 阶段 6：AI 提交信息（1 周）

好消息是这块在 Swift 侧已经完全抽象好了：`CommitMessageGenerationService` 是个
只依赖 `AIHTTPTransport` 与 `AIProviderCredentialResolver` 的 struct，不含任何
Foundation 网络代码。移植约 420 行逻辑：三种 API 协议（OpenAI Responses、
chat completions、Anthropic messages）各自的编解码、端点归一化、6 种格式模式的
提示词构造、按文件的 diff 字符预算分配、以及两道安全闸门
（拒绝非 `http://` 白名单、拒绝 `.env` 与证书私钥类文件进入提示词）。

依赖阶段 0 补齐的 `AIHTTPTransport` 与 `SecureStore` 端口。

### 阶段 7：分发与更新（1.5 周）

`UpdateChecker` 的 608 行几乎全是 macOS 专有（DMG 挂载、bundle 替换助手），
应当**重新设计而不是移植**。可复用的只有语义化版本比较（约 35 行）、
自动检查节流判断，以及状态机（idle/checking/available/downloading/installing/
upToDate/noRelease/failed）。

Windows 侧需要：MSI 或 NSIS 安装包、Authenticode 签名与验签、自己的资产选择规则、
以及一个退出后替换可执行文件的助手进程。保留 macOS 那条硬性规则：
校验和缺失或不匹配都必须是硬错误。

同时新增 `release-windows.yml`，与现有 `release-macos.yml` 对齐。

## 四、时间与顺序

| 阶段 | 内容 | 工期 | 前置 |
| --- | --- | --- | --- |
| 0 | 端口补齐 + CI + Rust 交叉编译 | 1 周 | — |
| 1 | 纯算法移植 | 1.5 周 | 0 |
| 2 | 工作区骨架补完 | 2 周 | 0, 1 |
| 3 | Git 与历史 | 1.5 周 | 2 |
| 4 | 运行时与 Java 工具链 | 3.5 周 | 2 |
| 5 | 调试 | 2 周 | 4 |
| 6 | AI 提交信息 | 1 周 | 0, 3 |
| 7 | 分发与更新 | 1.5 周 | 2 |

串行约 14 周。阶段 3/4 可并行，阶段 6/7 可与 4/5 并行，
两人分工的话大致 9–10 周可达 parity。

## 五、需要提前决策的三个点

1. **jdb 还是 JDWP**：如果 Windows 上 jdb 的输出格式与行缓冲差异过大，
   文本抓取方案会不稳。阶段 0 就手工验证，别等到阶段 5。
2. **终端是否上色**：现在 macOS 侧不解析 SGR，输出是单色的。
   Windows 照搬能保证一致，但 Windows 用户对彩色终端的预期更高。
3. **编辑器控件**：macOS 侧是 TextKit 1 的自定义对象图（`CodeEditorView.swift:1395` 起），
   Qt 没有对应物。建议用 `QPlainTextEdit` + `QSyntaxHighlighter`，
   接受行号、缩进参考线、blame 栏、inlay hints 的呈现细节会有差异。

## 六、契约纪律

- 新增行为先在 `shared/fixtures/` 加 fixture，再写第二个平台实现。
- 响应结构变更必须同步 `shared/contracts/rust-core-api.md`，协议版本当前为 `1`。
- 能下沉到 Rust 的逻辑就下沉 —— 阶段 1 那 1,100 行算法如果搬进 Rust core，
  两端都能省。但这会扩大 C ABI 表面，建议先在 C++ 实现并用 fixture 锁定行为，
  确认稳定后再评估下沉。
- Windows 侧不得引用 macOS 代码，`ports.h` 等公开头文件不得暴露 Win32 句柄类型。

## 七、可见功能对照清单

命令面板 21 项（来自 `Sources/Lithe/Models/LitheAction.swift`）：
运行、调试、停止运行、停止调试、打开项目、关闭项目、设置、在文件管理器中显示、
切换终端、切换问题、切换 Maven、切换 Git Log、切换运行、切换调试、
在文件中查找、在文件中替换、在当前文件查找、跳转到用法、查找用法、
本地历史、项目本地历史。

Search Everywhere 用模糊子序列匹配（`LitheAction.matches`），
合并动作命中与 `workspace.searchEverywhere` 的文件/符号命中，双击 Shift 唤出。

窗口与对话框：欢迎窗口、工作台窗口、设置、克隆仓库、Search Everywhere 浮层、
运行配置编辑器、项目切换气泡、分支切换气泡。

侧边栏：项目树、变更、搜索、项目替换。

工具窗口：终端（多会话）、运行（多模块）、调试（线程/栈/变量/求值/断点）、
问题、Maven、Git Log 与提交图、引用。

编辑器：标签页、语法高亮、行号、缩进参考线、code vision、inlay hints、
blame 栏、Ctrl 点击导航、断点栏、查找栏、Markdown 预览。

Diff 与审阅：分栏 diff、缩略图、折叠带、横向滚动同步、提交 diff 审阅、分支比较。

图标资源 `Resources/IDEAIcons/` 是 Apache-2.0，Qt 可直接用 `QIcon` 复用；
`LitheTheme.swift` 的颜色常量值可以机械转成 Qt 调色板或 QSS 变量。
