# Windows 交接记录

这份记录描述 Windows 实现当前的真实状态。它适用于新的 Codex 任务和新的
开发者工作区；完整路线仍以[Windows 开发计划](windows-development-plan.md)
为准。当前代码是进行中的实现，不应宣称已经达到 macOS parity。

## 先确认工作区

Windows 实现使用独立的 Git worktree 和分支。进入 Windows worktree 后先运行：

```sh
git branch --show-current
git status --short
```

分支应为 `codex/windows-parity-implementation`。主 worktree 继续承载
`main` 的 Swift/Rust 开发，不要在当前目录之间来回切换分支。

## 已经完成的基础工作

- 建立 `windows/core`、`windows/adapters`、`windows/app`、`windows/qt` 和
  `windows/tests` 的 CMake 分层。
- 增加固定线程归属的 `CoreWorkerPool`，调用点生成 `operationId`，并设置
  交互请求 5 秒、扫描和搜索 30 秒的超时。
- `CoreClient`、`CoreWorkerPool`、coordinator 和所有 feature model 已统一使用
  `CoreResult<T> = std::expected<T, CoreError>`；ABI 失败、JSON 解析失败和 Rust
  error envelope 会保留各自的 typed error，Windows CMake targets 统一使用 C++23。
- 增加无 Qt 的 JSON 解析、统一 JSON 序列化、Core envelope/error 解码，以及工作区、
  文件、搜索、history、Maven、Java、Git 全部线格式的响应 DTO。
- 增加 workspace、文件、搜索、history、Maven、Java、Git 全部已接入命令的结构化请求
  编码器；coordinator 不再由调用方拼 Core JSON。
- 完成阶段 1 的纯 C++ 算法和测试：diff、inline diff、Git graph/reference、
  文件可见性、终端 buffer、语法高亮、分词和 semver。
- 增加 `WorkspacePaths`、`RelativePath`、`GitRef`、`EditorPosition`，以及
  workspace、document、search 的应用层模型和持久化骨架。
- Qt 工作台骨架已经支持项目选择、目录树、文件读取/保存、搜索、刷新、Git status/diff
  状态、本地历史列表、Search Everywhere 浮层和 watcher 触发刷新。workspace、document、
  search、Git、history feature model 已接入，Qt 窗口只消费 feature state，不再直接解析
  Core envelope 或拼请求 JSON。
- Git feature 已覆盖 history、commit、commit files、comparison、stash、blame、write
  和 command；Maven/Java feature 已覆盖扫描、诊断、运行配置、code vision、定义和结构
  请求，并保留成功响应中的 `data: null`。
- `JavaRunService` 已接入 Current File、Spring Boot/Maven module 请求构造、JDK/Maven
  环境变量、参数分词、模块 classpath、工作目录和端口冲突检查；Qt 工作台已接入 Java
  运行/停止和 Maven 生命周期。
- `JavaLanguageServerClient` 已完成 LSP frame 解码、JSON-RPC 多路复用、JDT LS 启动、
  `workspace/configuration`、diagnostics、`didOpen`/`didChange`/`didClose`，并以
  300ms 防抖同步编辑器内容。Qt 工作台已接入 Java 文件打开、编辑同步和诊断列表。
- Windows 终端工具窗口已接入 ConPTY、cmd.exe 输入输出、停止和退出状态。
- Java 调试服务已接入 Windows Qt 工作台：Current File、Spring Boot/Maven、远程 JDWP
  attach、断点、继续/暂停、单步、线程/栈/变量、变量展开和表达式求值均走 jdb；自定义
  JDK 的 `JAVA_HOME` 会随 jdb 会话保留。
- Qt 工作台已接入 Git 200ms 防抖刷新、Stage All、提交/amend、AI 提交信息设置和生成，
  以及 GitHub Windows 更新检查、SHA-256 校验下载和安装器启动。
- Qt 工作台已接入欢迎窗口、最近项目、目录打开、克隆入口、六页 Windows 设置和 25 项
  命令面板动作；设置会持久化编辑器字号、
  Java 标注开关、终端 shell 和工作区隐藏规则，首次打开工作区也会应用这些规则。
- 终端会优先使用设置中的 shell，未配置时回退到 `ComSpec`/`cmd.exe`；Java code vision、
  implementation markers 和 inlay hints 均尊重设置开关。
- AI 提交信息生成会按 Git status 的 staged 文件逐个读取 index diff，避免同一文件同时有
  staged/unstaged 修改时误用工作树内容。
- 编辑器已接入查找栏、全部匹配高亮、前后循环定位，以及基于当前缓冲区的 Markdown 预览。
- 欢迎窗口已接入最近项目过滤、目录打开、设置、资源管理器定位和克隆仓库；克隆完成后
  会以显式目标目录打开新工作区，不依赖已有工作区。
- Qt 编辑器已接入 Windows 语法高亮、Java code vision/inlay 基础呈现、独立行号栏、断点栏
  和 Git blame 栏；Git diff 已升级为双列行号审阅、变更着色和上下文折叠。
- AI 提交信息服务已加入三种协议（Responses、Chat Completions、Anthropic Messages），
  包含端点归一化、DPAPI 密钥端口、安全文件过滤、HTTP/HTTPS 闸门和响应清洗；WinHTTP
  适配器已支持 GET/POST。
- Windows 更新服务已加入 GitHub Release 检查、x64 NSIS 资产选择、SHA-256 校验和下载，
  下载后还会通过 `WinVerifyTrust` 验证 Authenticode，并由独立的
  `lithe_windows_update_helper.exe` 等待主进程退出后启动安装包；同时提供
  `scripts/package-windows.ps1`、`windows/packaging/lithe.nsi` 和独立的
  `release-windows.yml`。
- Win32 适配层已经加入进程树终止、ConPTY、目录 watcher、防抖、文件系统、运行时
  发现、DPAPI 和类型化持久化的实现骨架；进程会话和 ConPTY 在根进程退出后会先
  结束 Job/释放 ConPTY，再等待输出读取线程，避免子进程继承管道导致退出挂起。
- 新增无 Qt 的 `ProjectRuntimeService` 和 `MavenBuildService`：支持项目/环境 JDK
  优先级、`.cmd` Maven Wrapper、custom/system Maven、`JAVA_HOME`/`PATH` 构造，以及
  `-B -ntp`、`-pl`、排序后的 `-P` 和 phase 参数。服务由 CTest fake ports 覆盖。
- coordinator 已用 workspace epoch + 操作域 generation 丢弃陈旧结果；工作区切换会统一
  重置 feature state 和 loading 标志。AI staged diff/生成回调也带工作区 epoch，切换工作区
  后会静默取消旧任务，避免旧结果或错误提示污染新工作区。
- Java LSP 高级导航已接入：`jdt://` 外部位置归一化、JDK `src.zip` 的 Windows
  `tar.exe` 读取、缓存 Java 源码只读预览，以及 `java.decompile`、
  `java.getFullyQualifiedName` 和 hover 兜底；源码位置按 LSP UTF-16 列处理。

## 已知限制和风险

按优先级继续处理：

- Git status/diff/apply 和完整 Git 响应 feature model 已建立；当前 Qt 工作台已支持
  按 `hunkId` 选择并执行 stage/unstage/discard，且已加入 200ms 防抖；缩略图、横向
  滚动同步、跨列连接带和提交 diff 逐文件/逐行审阅均已通过共享表格 viewport 接入。
- 30 个命令的 DTO、结构化请求和 coordinator 已覆盖；Maven 状态、基础构建生命周期、
  Java 运行、LSP 基础、调试和终端工具窗口已接入 Qt。Java 定义/引用的基础跳转、code
  vision/inlay、blame 栏和编辑器断点栏已接入基础交互。
- session/recent-project restoration 已有基础实现；watcher 已使用重叠 I/O、防抖、结构性
  变更分流、通知记录边界校验和串行启停，当前打开且无未保存修改的文件支持安全外部
  重读；进程、ConPTY 和 watcher 的启停也已串行化；diff 审阅的高级交互已补齐。
- Java LSP 已按当前 Java 文件向上查找 `pom.xml`、Gradle 构建文件或 `.git` 作为项目根，
  并已接入 `jdt://` 源码物化、`src.zip` 读取、`java.decompile`、全限定名和 hover
  兜底。`tar.exe` 不可用时会继续尝试 JDT decompile；两者都不可用时保留原始外部位置。
- 按当前任务约束，本机不执行 Windows/Qt 编译、运行或平台专属验证；`lithe_windows_qt`
  需要在 Windows runner 或 Windows Qt 环境中编译。真实 Windows 的
  Qt、WinHTTP、ConPTY、Job Object、注册表、DPAPI、watcher、运行时发现和 NSIS 打包
  测试也尚未执行；发布 workflow 需要配置 `WINDOWS_SIGNING_CERTIFICATE_BASE64`、
  `WINDOWS_SIGNING_CERTIFICATE_PASSWORD` 和时间戳服务 secret。
- Windows CI 已增加 Qt 6 Widgets 构建；仍需确认 Windows runner 上 Rust static library、
  Qt、ConPTY 和窗口启动的完整运行结果。

## 不要破坏的契约

- 不修改 `Sources/Lithe/**`、`rust/lithe-core/src/**`、`shared/**` 或 macOS
  构建/发布脚本来填 Windows 缺口。Rust 缺口登记在开发计划第八节。
- Rust core 调用必须在固定 worker 上完整执行，不能换成可迁移的 Qt 或通用线程池。
- Qt 不直接 include `core_client.h`，不直接拼 Core 请求 JSON；请求由应用层协调器负责。
- 工作区路径统一 `/`，但必须用类型区分 `RelativePath` 和 `GitRef`。
- Git diff 分块字段是 `hunkId`，不是 `hunkID`。
- `data: null` 和键缺失是两种不同情况，DTO 解码不能把它们合并。

## 接手后的第一批动作

1. 在 Qt/Windows 环境编译并启动工作台，验证 ConPTY、JDT LS、DPAPI、注册表和
   watcher 的真实行为。
2. 完善问题面板跳转和 Java 多模块会话，并在 Windows runner 验证已有 LSP/editor 交互，
   包括 JDK `src.zip`、`tar.exe` 缺失时的 decompile 兜底和只读源码预览。
3. 在 Windows CI 上验证 Qt、WinHTTP、jdb、NSIS 及签名/安装流程。

## 既有验证记录（不计入本轮进度）

历史上在当前 worktree 中记录过以下检查：

- CMake 配置和平台无关 C++ 构建。
- CTest：`12/12` 通过，未包含需要 Rust Windows static library 的 `core.ping`；包含
  generation、DTO、请求编码器、Git feature、Java 运行、调试、LSP、AI 提交和更新校验回归。
- `scripts/verify-windows-boundaries.sh`。
- `git diff --check`。

根据本轮工作约束，之后不在本机 Mac 重跑这些检查；本轮进度百分比不包含这些历史记录，
也不把它们当作 Windows 平台验收。

这不是 Windows 平台验收。Qt 6、Rust Windows static library 和真实 Win32 运行环境
仍需在对应环境中验证。

## 验证入口

平台无关的构建和测试：

```sh
cmake -S windows -B windows/build
cmake --build windows/build
ctest --test-dir windows/build --output-on-failure
```

边界检查：

```sh
./scripts/verify-windows-boundaries.sh
```

Windows CI 还会运行 `scripts/build-windows.ps1`，并用真实 Rust static library
执行 `core.ping`。本地没有 Rust Windows static library 或 Qt 6 时，不要把本地
缺少这些环境误判成协议或适配器已经通过验证。
