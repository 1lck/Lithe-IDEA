# Agent 笔记：超长 Java 启动命令与失败可见性

状态：已实现

## 先说结论

Java 项目现在由项目 JDK 直接启动，JDT 解析出的运行时 classpath 会原样出现在命令行上。
若依 Plus 这类几十模块的工程有几百个绝对 jar 路径，命令行长度超过 Windows 的
32767 字符上限，进程根本创建不出来。现在超限时由 Core 把路径列表搬进 JDK 参数文件
（argfile，`java @文件` 读取的选项文件），宿主按启动器原生编码写入并为每次执行独占管理文件；macOS 通过同一个
`execution.planLaunchCommand` JSON 命令自动采用该策略，不需要 Windows 专属配置。Windows 集成终端对
`cmd.exe` 和 PowerShell 的超长多行输入改用临时脚本调用，脚本执行后自删除，终端关闭时也会清理未执行文件；这不修改系统
Shell 配置。同时启动失败的真实原因必须能显示出来，不能再被兜底文案吞掉。
JDK 8 不认识 argfile，Windows 普通 Run 改用 classpath JAR（只含 `META-INF/MANIFEST.MF`
的临时 JAR，靠 manifest 的 `Class-Path` 列出全部条目）；Core 生成 manifest，宿主写入并沿用同一套临时文件生命周期（#955）。

## 问题

用户在 Windows 上运行若依 Plus，构建成功，运行面板打印出一条几万字符的
`java -cp <几百个 jar> org.dromara.DromaraApplication`，然后只显示一句
「Unable to start the run configuration.」。

这里其实是两个缺陷叠在一起：

1. **命令行超限**。`java.exe` 不是批处理文件，宿主直接走 `CreateProcessW`，
   它的命令行上限是 32767 个 UTF-16 字符，超过就失败（系统错误 206）。以前
   通过 Maven 启动时，这份 classpath 在 Maven 进程内部组装，不经过操作系统，
   所以同样的项目不会触发。改成直接启动 JDK 之后，长度问题才暴露出来。
2. **失败原因被吞掉**。Tauri 命令返回 `Result<(), String>`，失败时前端拿到的是
   **字符串**；而运行面板只在 `error instanceof Error` 时才取 `message`，否则
   显示兜底文案。这条路径也没有写日志，所以 6MB 的日志里关于这次失败一条记录
   都没有。无论根因是什么，用户看到的都是同一句没有信息量的话。

## 决策

### 正确做法

1. **Core 判断，宿主落盘。** 启动前调用
   `lithe_core::execution::plan_launch_command`：它估算命令行长度，超限时把
   `-cp`、`-classpath`、`--class-path`、`-p`、`--module-path` 这些「路径列表」
   选项搬进 argfile，返回文件内容和缩短后的参数。宿主只负责选临时路径、写文件、
   进程退出后删除。
2. **只搬路径列表。** JVM 选项、主类和程序参数留在命令行上；argfile 引用出现在
   原来第一个被搬走的选项位置。遇到主类、`-jar`、`-m` 或 `--module` 入口就停止
   搬运，后面的 `-p` 等参数属于应用程序，必须原样保留。非 Java 命令不使用此规则。
3. **转义由 Core 负责。** argfile 的引号字符串里反斜杠是转义符，Windows 路径的
   每个分隔符都要写成两个；带空格的路径靠引号保持为一个参数。平台编码后若
   多字节字符的尾字节为 `0x5c`，宿主也必须转义它，防止原生解析器将其当作反斜杠。
4. **版本和编码分别处理。** 只为确认是 Java/JDK 9+ 的启动生成参数文件；
   无法读取版本时保持原命令。JEP 400 不改变 Windows 启动器参数使用的系统代码页，
   不能因为 JDK 18+ 就写 UTF-8。Windows 宿主按实际 ANSI 代码页转换 Core 返回的
   Unicode 文本，并回转校验，不能表示的字符报错，不允许替换成问号。
   UTF-8 系统代码页才使用 UTF-8 字节；普通中文系统代码页使用对应的中文编码。
5. **JDK 8 用 classpath JAR，规则同样在 Core。** 已确认 JDK 版本低于 9 时，Windows 宿主调用
   `lithe_core::execution::plan_classpath_jar_launch`。它使用同一长度预算，只替换启动器
   最终生效的那个 `-cp`/`-classpath` 值（多次出现时最后一个生效），值换成临时 JAR 路径；
   JVM 选项、主类和程序参数不动。manifest 规则：
   - 每个条目先按工作目录转成绝对路径，因为 manifest 里的相对 URL 以 JAR 所在目录为基准，
     而命令行里的相对路径以工作目录为基准；空条目按启动器语义视为工作目录。
   - 绝对路径转成 `file:` URL：盘符写成 `file:/C:/...`，UNC 写成 `file:////host/share/...`；
     非 `[A-Za-z0-9-._~/:]` 的字节一律按 UTF-8 百分号编码（空格、中文、`#`、`%`、`+` 都包括在内）。
     所以 manifest 是纯 ASCII，和 Windows 系统代码页无关，比 argfile 更不容易因中文路径失败。
   - 目录条目必须以 `/` 结尾，否则类加载器把它当成 JAR 打开。目录判断是文件系统事实，
     由宿主通过回调回答，Core 不读磁盘。
   - 每行最多 72 字节，续行以一个空格开头，换行用 CRLF，最后用空行结束主段。
   - 不能等价表达的情况保持原命令：`lib/*` 通配符（只在命令行展开）、`C:lib` 这类依赖
     每盘当前目录的路径、`-jar` 启动（会忽略 `-cp`）、版本未知。
   JAR 只含一个不压缩的 manifest 条目，写在 `temp_dir()/lithe-run/launch-<pid>-<n>.classpath.jar`，
   和 argfile 共用 `create_new` 独占创建与 RAII 清理，绝不写进 JDK 或安装目录。
6. **失败必须可见。** 宿主的失败消息带上系统错误、可执行文件和命令长度；
   前端把非 `Error` 的拒绝值也转成可读文本，并通过 `frontendTrace` 写日志。
7. **macOS 复用同一份规划。** macOS 组合根把 `RustCoreBridge` 注入
   `LitheExecutionModule.RunService` 的 `JavaLaunchArgumentPreparing` 端口。适配器读取 JDK
   `release` 版本、调用 `execution.planLaunchCommand`、以 UTF-8 写入自己的临时文件，并把一个
   lease 保留到 Java 进程退出；RunService 不直接操作文件系统。
8. **终端只在 IDE 输入边界做短调用转换。** Windows `cmd.exe` 和 PowerShell 的单行输入有独立长度上限。
   终端连接收到超过 7000 个 UTF-16 单元且包含换行的文本时，在系统临时目录使用 `create_new` 创建 `.cmd` 或 `.ps1`，
   把原文本写入脚本，再向 PTY 写入短的 `call "路径"` 或 `& '路径'`。短文本、仍处于编辑状态的超长单行文本、二进制输入、
   WSL 和 Git Bash 不做转换，避免改变交互式 Shell 的解析语义。脚本自身负责正常执行后的删除，连接关闭或写入失败时由连接对象尽力删除剩余文件。

### 不要这样做

- 不要在 Windows 宿主里自己判断长度、自己拼 argfile。判断和转义是确定性逻辑，
  放 Core 才能被两个平台复用，也才能脱离 Tauri 单独测试。
- 不要无条件写 argfile。只有「不这样做就必定失败」时才写，避免给本来正常的
  启动引入额外的文件依赖。
- 不要在前端只用 `error instanceof Error` 取消息。Tauri 命令失败时给的是字符串，
  这样写等于丢掉全部诊断信息。
- 不要在 macOS RunService 或 SwiftUI 里复制命令长度、参数转义或 JDK 版本判断；这些规则属于
  Rust Core，macOS 适配器只负责临时文件和生命周期。

## 考虑过的备选方案

- **改用 `CLASSPATH` 环境变量**：被否。Windows 对单个环境变量和整个环境块同样有
  32767 的限制，只是把同一个上限换了个地方。
- **所有 JDK 都用 pathing jar**（classpath JAR）：被否。#955 出现 JDK 8 需求后，classpath JAR
  只用于 JDK 8。JDK 9+ 继续用 argfile，因为 argfile 还能搬 `--module-path`，
  也不会改变 `java.class.path` 系统属性（classpath JAR 下该属性只剩 JAR 本身，
  依赖它扫描类路径的少数框架行为会变）。
- **JDK 8 用 `CLASSPATH` 环境变量**：被否，理由同上，环境块同样受 32767 限制。
- **manifest 写相对 URL**：被否。临时 JAR 和项目通常不在同一盘符，相对 URL 无法表达；
  绝对 `file:` URL 对所有盘符和 UNC 路径都成立。
- **退回 Maven 启动**：被否。那会把
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
  里已经解决的 `ClassNotFoundException` 重新带回来。
- **只延长/忽略长度，靠用户手动缩短依赖**：被否。用户无法控制传递依赖的数量。
- **修改 PowerShell profile、注册表或全局环境变量**：被否。该问题只属于 Lithe 生成的输入，系统级修改会影响 IDE 之外的程序，
  也不能可靠消除不同 Shell 的长度和解析差异。

Windows 的目录探测、JDK release 读取、临时文件写入和进程创建在后台阻塞任务中执行，
不能让慢速 UNC 路径冻结 UI。每次启动先登记独立的准备请求，停止会取消该请求，
重新运行会替换它；准备完成后必须在与停止共用的锁内检查归属，再发布进程。
例如 A 准备期间启动 B，即使 A 最后才完成，也必须释放 A 的临时文件而不启动它。
不能只把同步命令改成后台执行而省略归属检查，否则停止后旧进程可能重新出现。

临时 argfile 与 classpath JAR 在 `scripts/worktree-resources.json` 的
`java-launch-temporaries` 中登记为不可复用资源，复用脚本直接拒绝。它们属于单次
执行，没有构建身份 stamp，任何阶段都不能跨工作树复制，也不写发行目录。

## 后果

- 大型多模块 Maven 项目在 Windows 上可以启动，命令行只剩下一个 `@文件` 引用。
- macOS 的大型 Java 项目也会自动在同一长度预算下切换到 `@argfile`，用户不需要维护 Windows
  专属设置；普通长度的启动仍保持原参数。
- 启动失败时用户和日志都能看到系统给出的真实原因，排查不再依赖猜测。
- 每次执行用 `create_new` 独占创建一个参数文件，不按窗口或会话名复用。文件由
  RAII 所有者管理（离开作用域时自动清理）：写入或启动失败时删除，成功后交给
  该进程的退出线程删除；旧执行的清理不能影响替代它的新执行。
  `@argfile` 在 JVM 启动时读取；classpath JAR 可能在后续类加载时仍被访问，
  因此两者统一保留到进程退出，后续执行创建新文件。
- `@argfile` 需要 JDK 9 以上。JDK 8 的普通 Run 现在由 classpath JAR 覆盖。代价：
  JDK 8 缩短后 `System.getProperty("java.class.path")` 只返回临时 JAR 路径；
  只依赖类加载器的代码不受影响。JDK 8 的 `--module-path` 不存在，所以不需要处理。
  macOS 的 `ARG_MAX` 远大于 Windows 上限，JDK 8 直接启动不会超限，因此 macOS 不调用
  这条规划，也没有 JSON 命令。
- JDK 8 缩短不覆盖：Java 测试调试（Java Debug Server 自己拉起 JVM）、Maven 目标、
  集成终端里手动执行的命令。它们都不经过 `run_start_process`。
- 参数文件使用 Windows 实际系统代码页，JDK 9-17 的中文路径也可在能够无损表示
  它们的系统代码页下使用。不支持该字符的系统代码页仍会明确失败；JDK 9+ 是否也改用
  classpath JAR 规避代码页问题，需要先权衡 `java.class.path` 语义变化，本次未做。不能把更改 `file.encoding` 当作启动器编码的修复。
- Windows 集成终端只为 `cmd.exe` 和 PowerShell 的超长多行文本创建一次性脚本；WSL、Git Bash 和普通交互输入保留原始写入。
  这解决 IDE 生成命令的 Shell 输入上限，不改变系统 Shell 的全局限制。
- Java **测试**的调试仍由 Java Debug Server 自己拉起 JVM，它的
  `shortenCommandLine` 默认是 `none`，因此大工程调试测试时仍可能超限。修它需要
  在启动请求里传 `argfile` 或 `jarmanifest`，本次未做。

## 验证

- Rust Core：`cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib launch_command`
  覆盖长度判断、argfile 生成与顺序、反斜杠和空格转义、无可搬运选项时不改写、
  以及可配置上限；`execution.planLaunchCommand` 复用同一规划器。
- macOS Swift：`swift build --target Lithe` 覆盖模块边界和组合根注入；临时文件 lease
  在启动失败、停止和正常退出路径释放。
- Rust Core：`cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib classpath_jar`
  覆盖 JDK 8 触发、JDK 9+/未知版本/短命令保持直接启动、空格中文和保留字符的百分号编码、
  目录结尾 `/`、相对/UNC/空条目、72 字节折行、只替换生效的 `-cp`，以及通配符和 `-jar` 不改写。
- Windows 宿主：`cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml run::`
  覆盖写入并删除 argfile、普通启动不写文件、失败消息包含系统原因；JDK 8 生成只含 manifest 的
  临时 JAR、目录条目带 `/`、所有者释放后删除，JDK 9+ 仍走 argfile，版本未知不写文件。该 crate 需要
  Windows 或具备 GTK 依赖的环境才能编译。
- Windows 终端 crate：`cargo test --manifest-path windows/tauri/crates/terminal/Cargo.toml` 覆盖短输入和单行输入不转换、
  `cmd.exe`/PowerShell 脚本内容与自删除命令；`cargo check --target x86_64-pc-windows-msvc` 检查 Windows 条件编译。
  Windows 实机仍需按矩阵验证 ConPTY、cmd.exe、Windows PowerShell 5.1 和 PowerShell 7 的实际执行及清理。
- Windows 前端：`bun test src/features/run` 覆盖字符串拒绝值的显示与兜底文案。

## 适用范围

- Rust Core：`rust/lithe-core/src/execution/launch_command.rs`、
  `rust/lithe-core/src/execution/classpath_jar.rs`
- Windows：`windows/tauri/src-tauri/src/run.rs`、
  `windows/tauri/src-tauri/src/run/launch_arguments.rs`、
  `windows/tauri/src/features/run/stores/run.store.ts`、
  `windows/tauri/crates/terminal/src/connection.rs`、
  `windows/tauri/src-tauri/src/terminal.rs`
- 共享契约：`shared/contracts/rust-core-api.md`
- macOS：`macos/Sources/Lithe/Platform/MacOS/RunConfiguration/MacJavaLaunchArgumentPreparer.swift`、
  `macos/Sources/LitheExecutionModule/Services/JavaLaunchArguments.swift`、
  `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
