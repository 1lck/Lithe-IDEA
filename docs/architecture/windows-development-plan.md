# Windows 端开发计划（UI 层 + 适配实现层）

本计划只在 `windows/` 目录内落地。

配套文档：
- [功能差距分析](windows-parity-plan.md) —— macOS 侧功能面与 Rust 覆盖度
- [适配层审计](windows-adapter-audit.md) —— 现有 1,521 行 C++ 的逐文件结论
- [运行时设计](windows-runtime-design.md) —— 线程、取消、路径、编码、错误映射
- [DTO 参考](windows-dto-reference.md) —— 30 个命令的线格式，编解码依据

## 一、范围与红线

### 只读，不得修改

| 路径 | 原因 |
| --- | --- |
| `Sources/Lithe/**` | macOS 应用，Windows 不依赖它，也不改它 |
| `rust/lithe-core/src/**` | 共享运行时，改动会影响 macOS 行为与测试 |
| `shared/contracts/**` | 双端共同基准 |
| `shared/fixtures/**` | Windows 单元测试的输入基准，只读 |
| `scripts/build-macos.sh`、`create-dmg.sh`、`package-app.sh` 等 | macOS 打包链路 |
| `.github/workflows/release-macos.yml` | macOS 发布流水线 |

Rust core 以**预编译库**形式消费：交叉编译产出 `staticlib`，
通过已有的 `LITHE_RUST_CORE_LIBRARY` 缓存变量链接。增加编译目标不算修改源码。

## 当前实现状态（2026-08-06）

本分支已经落地 Windows 专属的 Core/DTO、应用层、Win32 适配器、Java
运行与调试服务、Qt 工作台基础流程、AI 提交信息服务、更新校验服务以及
CI/NSIS 打包入口。历史记录中的平台无关 CTest 为 `12/12`，边界脚本也曾通过；这些记录
不计入本轮进度。

下列内容仍需在 Windows runner 或安装了 Qt 6 的 Windows 环境中验证，不能用
本机 macOS 的构建结果替代；按当前工作约束，本机不执行这些 Windows 专属验证：Qt 6 Widgets 编译和启动、Rust Windows staticlib
链接、WinHTTP、ConPTY、Job Object、注册表、DPAPI、目录 watcher、jdb、NSIS
安装和 Authenticode 签名。

欢迎窗口、查找栏和 Markdown 预览已经接入；剩余的用户界面缺口集中在 JDT 源码导航
兜底和更完整的 gutter 行为。Windows Qt 已接入语法高亮、Java code vision/inlay、
双列 diff、上下文折叠、跨列连接线、提交逐文件/逐行 diff 审阅、AI 提交信息设置/生成、
更新检查下载和退出替换助手；它们与无 Qt 服务和协议实现分开追踪。

### 允许新增或修改

`windows/**`（全部）、`.github/workflows/ci-windows.yml`（新增）、
`scripts/build-windows.ps1` 与 `scripts/verify-windows-boundaries.ps1`（新增，
不动现有 `.sh` 版本）、`docs/`。

### 遇到 Rust 缺口

不要直接改。记到第八节缺口表，走单独评审 —— 那会同时影响 macOS，
需按契约纪律先加 fixture。Windows 侧先在 C++ 实现绕过，用 fixture 锁定行为。

## 二、审计结论改变了阶段 0 的性质

原以为现有适配器只需"补齐"，实测是**三个必须重写、一个是 stub、两个需加固**：

| 适配器 | 处置 | 关键原因 |
| --- | --- | --- |
| `win32_terminal_transport` | 重写 | `#include <winconpty.h>` 不存在，此文件从未编译过；多处泄漏且不调退出回调 |
| `win32_process_session` | 重写 | 无 JobObject（杀 `mvn.cmd` 留下 `java.exe` 孤儿）；三类跨线程无锁读写；无 `closeInput()`；`environment` 字段声明但从不读取 |
| `win32_directory_watcher` | 重写 | 同步 IO，`stopEvent` 是死代码；`CancelSynchronousIo` use-after-free；**无防抖**（Maven 构建会产生数千次回调） |
| `win32_runtime_locator` | 重写 | 零注册表调用；`version` 永远为空，无法区分 JDK 8 与 21；最多返回一个候选 |
| `win32_file_system` | 加固 | 原子写做对了；但 `readUtf8` 按裸字节处理、`remove()` 对目录失败、错误文本是裸数字 |
| `win32_key_value_store` | 加固 | 非原子写；键名 sanitize 冲突；只有 string 类型 |
| `win32_process_runner` | 加固 | `condition.wait` 无超时 |

完整细节见[适配层审计](windows-adapter-audit.md)。

## 三、目标目录结构

Rust 未覆盖的业务逻辑必须有地方放，塞进 Qt 窗口类会让它无法测试。

```
windows/
  core/          Rust C ABI 封装 + JSON 编解码
  adapters/      端口定义 + Win32 实现
  app/           应用层（新增）
    algorithms/    纯算法，无 I/O，对 fixture 测试
    features/      特性模型，持有状态
    services/      进程编排：LSP、jdb、Maven、运行、AI、更新
    persistence/   设置、会话、布局、最近项目
  qt/            Qt Widgets UI
  tests/         CTest 单元测试（新增）
  packaging/     安装包与更新助手（新增）
```

依赖方向严格单向：`qt` → `app` → `adapters` / `core`。
`app/algorithms/` 与 `app/services/` 不得包含 `<windows.h>` 或 Qt 头文件，
这样它们才能脱离 UI 被测试。

## 四、阶段计划

### 阶段 0：地基与适配层重写（2.5 周）

比原估的 1 周长，因为包含三个重写。没有这一步后面写的代码全都无法验证。

**编译与 CI**

- [x] Rust core 交叉编译到 `x86_64-pc-windows-msvc` 产出 `staticlib`，
      写 `scripts/build-windows.ps1`，不动 `build-rust-core.sh`
- [x] 新增 `.github/workflows/ci-windows.yml`：Rust 构建 → CMake → CTest → 边界校验
- [x] 新增 `scripts/verify-windows-boundaries.ps1`，沿用现有三条规则并加两条：
      `app/algorithms` 与 `app/services` 不得含 Qt 或 `<windows.h>`；
      `qt/**` 不得直接 include `core_client.h`（由 feature/coordinator 统一承接）
- [x] 建 `windows/app/`、`windows/tests/` 骨架并接入 CTest
- [ ] 验证 Rust 内部 `Command::new("git")` 在 Windows 上的 PATH 查找行为

**核心调用层**

- [x] 实现[运行时设计](windows-runtime-design.md)第一节的线程模型：
      GUI 线程 + 4 个**固定不迁移**的 CoreWorker 线程。
      Rust 的取消作用域是 `thread_local!`，绝不能用 `QtConcurrent::run`
      或任何会迁移任务的线程池 —— 这是硬约束，写错要全部重做
- [x] `operationId` 在**调用点**生成并回传，让取消真正可用
      （macOS 侧的 id 不可观测，取消是空转，不要照抄）
- [x] 设置 `timeoutMilliseconds`：交互命令 5s、扫描与搜索 30s、Git 历史 30s
- [x] `Generational<T>` 陈旧结果丢弃，stale 分支走**统一清理路径**：coordinator
      同时检查 workspace epoch 与各操作域 generation；工作区切换会重置 feature state，
      stale 回调不再覆盖新工作区的 loading 或结果状态
      （macOS 的 stale 分支漏清 loading 标志，转圈图标会挂死）
- [x] `CoreResult<T> = std::expected<T, CoreError>`，11 个错误码强类型化；CMake
      统一要求 C++23。ABI、JSON 解析失败和 Rust error envelope 会保持为不同的
      typed error 路径，feature model 不再把它们降级成通用 `Unknown`。
      macOS 侧通用路径用 `try?` 把错误吞成 `nil`，Windows 不照抄

**DTO 编解码**

- [x] 按 [DTO 参考](windows-dto-reference.md) 生成 30 个命令的结构体与编解码器
- [x] 特别注意：读 **`hunkId`** 而非 `hunkID`（契约文档写错了，
      macOS 因此分块暂存功能实际失效）；
      `history.record`、`maven.scan`、`java.sourceDefinition` 会返回
      **`ok: true` 但 `data: null`**，解码器必须容忍；
      `WorkspaceNode.children` 与 `GitDiffRow.right` 是**键会消失**而非值为 null
- [x] `EditorPosition` 单一位置类型，一基/零基转换只在解码边界发生，
      之后禁止裸算术（macOS 把减一散在七个文件，`AppModel.swift:980` 还会下溢）

**端口补齐**

- [x] `ProcessRequest` 补 `standardInput`、`keepsStandardInputOpen`
      （JDT LS 与 jdb 都要 stdin 常开），并补 `closeInput()`
- [x] `ProcessSession` / `TerminalTransport` / `DirectoryChangeSource`
      全部补错误回调通道（现在 `start()` 失败静默返回）
- [x] 新增 7 个端口：`SecureStore`（DPAPI）、`HTTPTransport`、
      `AIConfigurationSource`、`ArchiveEntryReader`、`PlatformUI`、
      `ShortcutDetector`、`FileStorage`。`HTTPTransport` 与 `PlatformUI`
      用 Qt 实现（`QNetworkAccessManager`、`QFileDialog`、`QStandardPaths`）
- [x] `KeyValueStore` 类型化（Double/Int/Bool/stringArray/data），
      一键一 JSON 文件，写入走原子路径，键名十六进制转义避免冲突

**适配层重写**

- [x] `win32_process_session` 重写：JobObject 进程树终止、
      所有共享状态加锁、`closeInput()`、读取并传递 `environment`、
      修超时循环的双 `Stopping` 事件
- [x] `win32_terminal_transport` 重写：正确的 ConPTY 头文件、
      修全部泄漏路径、失败时调退出回调
- [x] `win32_directory_watcher` 重写：重叠 IO、350ms 防抖 + 路径合并、
      区分 `FILE_ACTION_*`、处理 `ERROR_NOTIFY_ENUM_DIR` 溢出重同步、
      路径归一化为 `/` 分隔
- [x] `win32_runtime_locator` 重写：注册表（`HKLM\SOFTWARE\JavaSoft`、
      Adoptium/Temurin、WOW6432Node）、常见安装目录、
      跑 `java -version` 填充 `version`、返回全部候选
- [x] `win32_file_system` 加固：BOM 与编码探测、`remove()` 支持目录与只读、
      `move()` 补 `MOVEFILE_REPLACE_EXISTING`、`FormatMessageW` 错误文本、
      长路径 `\\?\`、读取上限与核心的 2 MiB 对齐
- [x] `IncrementalUtf8Decoder` 与行/帧切分放进适配层
      （macOS 按块 `String(decoding:)`，跨边界的多字节序列会损坏）
- [x] `win32_process_runner` 改 `wait_for` 并有明确超时错误

**风险前置验证**

- [ ] **手工验证 Windows 上 jdb 的输出格式与管道行缓冲行为。**
      调试功能靠抓英文文本工作，如果差异大到不可靠就要改走 JDWP
      —— 那是明显更大的工作量，必须现在知道，不能等到阶段 5

**验收**：CI 绿灯；`core.ping` 成功；stdin 常开的 echo 进程往返通过；
杀掉一个 `mvn.cmd` 后 `java.exe` 确实一起消失；
Maven 构建期间 watcher 回调次数在个位数量级；jdb 可行性有明确结论。

### 阶段 1：纯算法（1.5 周）

约 1,100 行无 I/O 逻辑，直接对 `shared/fixtures/` 写断言。
性价比最高，也给 `windows/tests/` 打基础。放进 `app/algorithms/`：

- [x] `diff_pairing` / `diff_collapse` / `diff_split_layout`
- [x] `inline_diff` —— 行内变更区间
- [x] `git_graph_layout` —— 提交图泳道
- [x] `git_reference_tree` —— 分支引用树
- [x] `file_visibility_rules`
- [x] `terminal_buffer` —— 5 状态 VT 解析器
- [x] `syntax_highlighter` —— 6 正则高亮器
- [x] `diff_tokenizer` —— 字符扫描分词器
- [x] `semver` —— 版本比较
- [x] `argument_tokenizer` —— shell 风格分词（Swift 侧重复两份，这里只写一份）

`terminal_buffer` 目前不解析 SGR，硬编码 240 列换行、2000 行回滚，照搬保持一致。

**验收**：每个算法都有对 fixture 或 macOS 已知输出的测试，CTest 全绿。

### 阶段 2：工作区骨架与应用层（2 周）

先重构再加功能。

- [x] `CoreClient` 已由 coordinator/worker pool 承接，UI 不再直接发 JSON
- [x] 建各特性模型（workspace、document、search、git、java、run、debug、
      maven、terminal、history、runtime）。
      **不要复制 `AppModel`** —— 它 1,838 行里约 450 行是纯转发属性，
      只为满足 SwiftUI 单一绑定对象的约束，Qt 让控件直连特性模型即可
- [x] `WorkspacePaths` 单一归一化入口（macOS 把这个转换复制了五遍，
      还有一份语义不同的）；类型上区分 `RelativePath` 与 `GitRef`
      —— 两者都用 `/` 但含义不同，混用迟早出错
- [x] 绝对路径判断用 `is_absolute()`，不看首字符
      （macOS 的 `hasPrefix("/")` 在 `C:\...` 上会把绝对路径当相对路径拼接）
- [x] `app/features/workbench_coordinator` 承接 `AppModel` 真正有价值的约 500 行：
      `openProject`/`closeProject` 会话恢复与过期路径过滤、面板互斥规则、
      导航分发、提交信息暂存的应用与丢弃、AI 配置自动导入决策
- [x] `app/persistence/`：设置、会话、布局、最近项目
- [x] 文件监听消费逻辑：按 `ChangeKind` 区分结构性变更与纯内容修改；新增、删除、
      重命名和 watcher 溢出会重取 workspace snapshot，普通文件修改只触发 Git
      防抖刷新；当前打开文件在干净状态下才从磁盘重读，并保护未保存缓冲区。

UI 部分：

- [x] 欢迎窗口（最近项目、打开目录、克隆、设置、资源管理器定位）和工作台窗口
      （标题栏、项目树、编辑器区、工具窗口、可拖拽分隔条）基础流程
- [x] 编辑器基础栏 + `QPlainTextEdit` + `QSyntaxHighlighter`，包含行号、断点、Blame、
      code vision、inlay hints 和多文件编辑器标签页
- [x] 项目树：创建/重命名/复制/删除、复制绝对与相对路径、资源管理器定位
- [x] 编辑器查找栏（全部匹配高亮、前后查找、循环定位）和 Markdown 预览
- [x] 设置对话框六个页签（General、Editor、Project、Terminal、AI & Commit、Updates）
- [x] Search Everywhere 基础浮层：接入 `searchEverywhere` 结果合并、文件/类型/符号/内容
      展示和双击定位；支持 `Ctrl+Shift+E`、模糊子序列匹配和 Windows 双击 Shift 唤出
- [x] 命令面板 25 项工作台动作

图标复用 `Resources/IDEAIcons/`（Apache-2.0，`QIcon` 可读），
`LitheTheme.swift` 颜色常量值转成 QSS 变量。两处只读取，不修改。

**验收**：打开项目、浏览编辑保存、搜索、切换面板、改设置并持久化；
重开能恢复会话；Maven 构建期间 UI 不卡顿。

### 阶段 3：Git 与历史（1.5 周）

Rust 已覆盖全部 Git 能力，这阶段是 UI 与工作流编排。

- [x] `git_feature`：快照刷新按 hash 保留选中项、提交后校验暂存非空、
      检测游离 HEAD、分页历史（起始 300，每次 +300）、克隆前置校验
- [x] **加 200ms Git 刷新防抖** —— Windows Qt 侧使用 single-shot timer 合并 watcher
      与工作流触发的刷新
- [x] staged AI commit input：故意绕过工作树 diff，
      逐文件用 `staged: true` 重新查询，这样同时有暂存与未暂存修改的文件
      才能正确表示。很容易写错
- [x] 变更侧边栏、Git Log + 提交图基础版、分支切换、分支比较
- [x] Diff 审阅基础版：双列、行号、变更着色、上下文折叠、
      分块暂存/取消暂存/丢弃（`git.apply` 三种 mode，按 `hunkId` 分组）
- [x] Diff 审阅缩略栏；双列共用 Qt 表格 viewport，横向滚动保持同步
- [x] Diff 审阅跨列连接线：按连续变更行绘制 addition/removal/changed 连接带
- [x] 本地历史（按文件与按项目）、克隆对话框
- [x] 提交 diff 审阅：提交详情展示变更文件，双击文件加载对应逐行双列 diff

**验收**：暂存、分块暂存、提交、amend、切分支、比较、历史、blame、stash 全通；
**分块暂存必须真的生效**（macOS 因 `hunkID` 拼写问题此功能是死的，
这是验证 C++ 实现正确性的好指标）。

### 阶段 4：运行时与 Java 工具链（3.5 周）

最重的一段，必须按序。

- [x] **运行时服务**（约 180 行）—— 阻塞后面全部 Java 功能。
      路径语义全部重写：`bin\java.exe`、`mvn.cmd`、注册表读 `JAVA_HOME`。
      注意 `.java` 与 `.maven` 两种上下文的 JAVA_HOME 分开构造
- [x] **Maven 服务**（约 120 行）—— 解析在 Rust，C++ 只需 `-B -ntp` 基础参数、
      `-pl`/`-P` 组装、阶段到标题映射、进程生命周期、输出缓冲
- [x] **运行服务**（约 550 行）—— 多模块会话、类路径解析、
      工作目录解析（`~` 展开与项目相对回退）、
      端口冲突检测（VM 参数 + 程序参数 + `application.properties`）
- [x] **LSP 客户端基础链路**：
      - `Content-Length` 帧编解码，半包处理在适配层
      - JSON-RPC 请求/通知/响应多路复用
      - jdtls 启动参数与按项目哈希的 data 目录
      - **加 300ms `didChange` 防抖** —— macOS 每次按键同步发全文，
        且还在 450ms 睡眠之前调用，JDT LS 每个字符收一次完整缓冲区
      - **复现 JDT LS 怪癖**：`workspace/configuration` 要对同一个 inlay hint
        设置返回四种不同嵌套形状
- [x] LSP 项目根上溯（`pom.xml` / `build.gradle` / `build.gradle.kts` / `.git`）
- [x] LSP 高级导航：`jdt://` JDK 源码解析、Windows `tar.exe` 读取 `src.zip`、
      `java.decompile`/`java.getFullyQualifiedName` 兜底、hover 解析，以及 UTF-16
      光标和缓存 Java 源码物化
- [x] 编辑器接 LSP：code vision、inlay hints；定义/引用已接入基础跳转
- [x] blame 栏和编辑器断点栏基础交互；提交详情点击和更完整 gutter 行为仍待补齐
- [x] 问题面板、引用面板基础版；诊断和引用结果列表已接入并支持双击定位

**验收**：打开 `Fixtures/lithe-spring-boot-git-graph` 能看诊断、
跳转 JDK 源码、跑 Maven 与主类、端口冲突有提示；
连续输入时 JDT LS 请求次数明显低于击键次数。

上述实现已完成代码接入；按当前任务约束，本机 Mac 不执行 Windows/Qt 构建、运行或
平台专属验收，最终结果仍需在 Windows runner 或 Windows Qt 环境确认。

### 阶段 5：调试（2 周，风险最高）

阶段 0 已给出 jdb 可行性结论。若走 jdb 路线：

- [x] 双进程编排：被调试进程带
      `-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:<port>`，
      端口 `49152...60000` 随机
- [x] jdb 必须带 `-J-Duser.language=en -J-Duser.country=US`
      —— 承重参数，下面所有解析依赖英文输出
- [x] attach 竞态：主触发是看到 `Listening for transport`，
      5 秒定时器兜底（Maven 会缓冲那一行），随后 900ms 再重放断点并 `run`
- [x] 命令集与输出解析（约 200 行）：变量与 dump 子项、线程两种格式、
      栈帧、可展开性启发式、异常检测
- [x] 暂停检测：`Breakpoint hit:` / `Step completed:` / `Method entered:` / 异常
- [x] 变量树递归查找更新，子表达式按 `parent.name` 或 `parent[i]` 构造
- [x] Spring Boot 调试路径和调试面板已完成；编辑器断点栏已接入基础交互

**验收**：下断点、命中、单步、看变量与栈、求值、捕获异常；
Spring Boot 与普通主类两条路径都通；停止调试后无孤儿 `java.exe`。

### 阶段 6：AI 提交信息（1 周）

Swift 侧已完全抽象好，只依赖 `HTTPTransport` 与凭据解析器，移植路径干净。约 420 行。

- [x] 三种 API 协议编解码：OpenAI Responses、chat completions、
      Anthropic messages（后者带 `anthropic-version: 2023-06-01`，
      认证按配置走 `x-api-key` 或 `Authorization: Bearer`）
- [x] 端点归一化：幂等后缀拼接，Anthropic 分支处理裸 base / `…/v1` / `…/messages`
- [x] 提示词构造：6 种格式模式、语言开关、正文开关、主题长度上限，
      注入防御措辞照搬
- [x] 按文件 diff 字符预算：`剩余字符 / 剩余文件数`，超出给截断提示，下限 8000
- [x] **两道安全闸门必须保留**：非 HTTPS 端点除显式允许否则拒绝；
      暂存文件含 `.env` / `.env.*` / `*.pem` / `*.key` / `*.p12` / `*.pfx` 时拒绝生成
- [x] 响应归一化：去 ``` 围栏、去 `Commit message:` 与 `提交信息：` 前缀、CRLF→LF
- [x] 本地配置读取（`%USERPROFILE%` 下 Claude 与 Codex）与环境变量合并
- [x] 密钥存 DPAPI，接上 Windows Qt 设置对话框

`CommitMessageModels.swift`（484 行）几乎全是枚举元数据，机械移植，中文文案复用。

**验收**：配好提供方后能生成提交信息；含 `.env` 的暂存被拒绝；HTTP 端点被拒绝。

### 阶段 7：分发与更新（1.5 周）

`UpdateChecker` 608 行几乎全是 macOS 专有，**重新设计而非移植**。
可复用的只有 semver 比较（阶段 1 已做）、节流判断、状态机与进度模型。

- [x] GitHub Releases 查询 + Windows 资产选择规则
- [x] 下载 + **SHA-256 校验**。保留硬性规则：校验和缺失与不匹配都是硬错误
- [x] Authenticode 验签（Windows 更新下载后通过 `WinVerifyTrust`）
- [x] NSIS 安装脚本
- [x] 退出后启动安装包的 Windows helper 进程
- [x] `packaging/` 脚本
- [x] 新增 `.github/workflows/release-windows.yml`，结构与 macOS 版对齐但独立成文件

**验收**：能检测新版本、校验通过后安装成功；校验失败明确报错且不安装。

## 五、排期

| 阶段 | 内容 | 工期 | 前置 |
| --- | --- | --- | --- |
| 0 | 地基 + 适配层重写 + 风险验证 | 2.5 周 | — |
| 1 | 纯算法移植 | 1.5 周 | 0 |
| 2 | 工作区骨架 + 应用层 | 2 周 | 0, 1 |
| 3 | Git 与历史 | 1.5 周 | 2 |
| 4 | 运行时与 Java 工具链 | 3.5 周 | 2 |
| 5 | 调试 | 2 周 | 4 |
| 6 | AI 提交信息 | 1 周 | 0, 3 |
| 7 | 分发与更新 | 1.5 周 | 2 |

串行 15.5 周。可并行：3 与 4、6 与 4/5、7 与 4/5。
两人分工约 10–11 周达 parity。阶段 0 比初版长 1.5 周，
但那是把返工风险最高的部分前置，不是净增成本。

## 六、需要提前拍板

1. **jdb 还是 JDWP** —— 阶段 0 手工验证后决定
2. **终端是否上色** —— macOS 不解析 SGR，输出单色。照搬保证一致，
   但 Windows 用户对彩色终端预期更高。若要上色，
   阶段 1 的 `terminal_buffer` 要留属性位
3. **编辑器控件** —— 建议 `QPlainTextEdit` + `QSyntaxHighlighter`，
   接受行号、缩进参考线、blame 栏、inlay hints 的呈现细节差异
4. **`features/` 通知机制** —— Qt 信号（简单，`app/features` 会依赖 Qt）
   还是自定义观察者（可测试性更好，多写样板）

## 七、验证策略

每阶段都要有可执行的验证，不靠人眼看：

- **算法层**：CTest 对 `shared/fixtures/` 断言，与 macOS 输出逐字节比对
- **DTO 层**：用 fixture JSON 往返编解码，字段名拼写错误必须让测试失败
  （`hunkId` 那类问题就是这么漏过去的）
- **适配层**：进程树终止、stdin 常开、watcher 防抖次数、
  跨边界多字节 UTF-8 解码都要有针对性测试
- **边界层**：`verify-windows-boundaries.ps1` 进 CI，分层依赖违规直接失败
- **契约层**：`verify-shared-contracts.sh` 的等价校验

## 八、Rust core 缺口登记表

发现需要 Rust 侧配合时记这里，不直接改 `rust/lithe-core/src/`。
每条走单独评审：先加 fixture，再改双端。

| 日期 | 需求 | Windows 侧临时方案 | 状态 |
| --- | --- | --- | --- |
| 2026-08-05 | 契约文档写 `hunkID`，线上实际是 `hunkId`；macOS Swift 侧因此分块暂存失效 | C++ 读 `hunkId`，行为正确 | 待 macOS 侧决定修法（加 `CodingKeys` 或改属性名） |

已知候选（暂不动）：阶段 1 那约 1,100 行算法若下沉进 Rust 两端都能省，
但会扩大 C ABI 表面且影响 macOS，等 Windows 侧行为稳定后再评估。
