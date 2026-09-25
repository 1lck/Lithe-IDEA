# Agent 笔记：Java 项目的构建与启动边界

状态：已实现

## 先说结论

Java 项目里的 Main 类，以及能确定 Java 入口源码的 Spring Boot 服务，不再通过
reactor-wide Maven goal 运行。Lithe 先让
JDT LS / Java Debug Server 找到精确源码目标、构建它所属的项目，并解析运行时
classpath/module-path；随后 Run 模块只启动一次项目 JDK。Maven 仍负责
描述项目，但不再充当 Java Main 的启动器。

其中“构建”这一步由 Rust Core 统一排队：同一个 Java 会话里一次只跑一个
构建；JDT 还在按 Maven Profile 更新项目时先等它结束；构建使用独立的长期限；
构建结果的“有编译错误 / 内部失败 / 被取消”分别报告，不再一律提示“修复源码”。

根本原则：**上游引擎的构建结论是证据，不是否决权。** Lithe 展示结论依据，
区分“构建器崩了”和“代码有错”，并为已经取得可用启动目标的终态结论保留一条
向前路径。取消、超时和未知结果没有得出代码结论，仍要求重试。

## 问题

把 Maven reactor 的“构建依赖”参数 `-am` 与 `exec:java` 放在同一条命令中，
会让 Exec goal 依次落到父工程和依赖模块。那些模块通常没有目标 Main 类，于是
在真正的应用模块启动前就报 `ClassNotFoundException`。单模块或结构碰巧简单的
项目可能成功，因此问题表现不一致。

## 决策

项目 Java Main 和已识别入口源码的 Spring Boot 服务，准备流程固定为：

1. `vscode.java.resolveMainClass` 按生成配置记录的精确源码路径选择目标；
2. `vscode.java.buildWorkspace` 请求构建拥有该目标的 Java 项目，并记录终态证据；
3. `vscode.java.resolveClasspath` 返回 runtime classpath 和 module-path；即使构建终态是
   `WITH_ERROR` 或 `FAILED`，只要路径可解析，也把目标和构建证据一起交给启动工作流；
4. Rust Core 接收结构化 `javaLaunch`，生成 `project-jdk` 直启计划；
5. macOS/Windows 宿主按各自路径分隔符拼接参数并启动一个 JVM。

Linux 第一阶段沿用同一条配置边界：`bottom_panel.rs` 只发 Core 命令和展示
状态，`workbench/run/config.rs` 持久化 Core 生成结果、解析工具链与启动计划，
`workbench/run/process.rs` 独占 session、子进程组和输出事件。Linux 不读取旧
`name/type/mainClass` 文档作为主路径，不再用源码正则补入口，也不在计划失败
后伪造 `mvn compile`。Maven 项目里的 `java.main` 仍因缺少 JDT 返回的
`javaLaunch` 明确失败，直到 Linux 接入同一 Java 项目准备能力。

Run 和 Debug 共用同一套 Java 项目准备逻辑。配置中的 Maven 信息仍用于 JDT LS
导入、Profile、settings.xml 和项目模型；Maven 工具窗口、框架 goal、测试与显式
Maven 任务仍走 Maven 启动计划。

Spring Boot 检测仍由 Maven 插件决定“它是不是服务”，不会把普通依赖模块误报成
服务。扫描到唯一的 `@SpringBootApplication` 源码后，配置同时记录入口类和源码；
此时 Run 走上述 JDT 直启流程。没有 Java 入口源码的特殊项目（例如入口不在可见
Java 源码中）仍可保留 Spring Boot Maven goal 兼容路径。
生成器 revision 随这项行为提升，旧工作区会自动重新生成配置，不要求用户删除
`.lithe/run/generated.json`。

`javaLaunch` 包含 JDT 确认的 `mainClass`、`classPaths`、`modulePaths`。缺少这些
项目元数据时直接提示等待或修复 Java 语言服务，不回退到 `exec:java`，避免把
原问题换成一次不确定的错误运行。JDT 对模块化项目返回的
`module/name.Type` 会转换为 JVM 需要的 `-m module/name.Type`。

### 构建协调（Issue #692 后续）

`vscode.java.buildWorkspace` 会构建 JDT 工作区里的全部 Java 项目。若依 Plus
这类 40 多个模块、带注解处理器的项目，首次构建要 30 秒以上。Windows 复现日志
显示了三个叠加的问题：

- 前端和 Core 都给这个构建套用 30 秒的普通请求期限，构建实际用了约 32 秒，
  启动准备在构建结束前就失败了。
- 取消只是“建议”（advisory，JDT 可以不理会）：超时发出 `$/cancelRequest` 后
  JDT 仍把那次构建跑完，但 Lithe 已经把请求记录删掉，下一次 Run 的构建可以
  与它重叠。
- Core 应用 Maven Profile 用的 `java.project.updateSettings` 很快返回，但它安排的
  JDT 后台任务“Update project …”又跑了约 110 秒，Run 的构建全程与它重叠。

因此 Core（`jdt_build.rs` 中的构建协调器，负责给构建排队的状态机）按下面的
规则处理这个命令，两个平台都不需要自己实现：

1. **先等项目配置稳定。** Maven Profile 任务仍在运行，或 JDT 通过
   work-done progress（`$/progress`，LSP 的后台任务进度通知）报告了项目配置
   任务（如 `Update project …`）而还没有 `end`，构建就先排队。某个配置任务
   120 秒没有任何进度时不再阻塞，防止 JDT 漏发 `end` 让构建永远等下去。
2. **同一会话一次只跑一个构建。** 正在运行的构建不与新请求共享，因为它可能
   开始于用户保存文件之前；排队中参数完全相同的请求共享下一次构建，所以
   连点几次 Run 只会多跑一次增量构建。
3. **取消以 JDT 的答复为准。** 调用方超时或取消后，只有当运行中和排队中都
   没人再需要构建时才发 `$/cancelRequest`；无论是否取消，构建都占着位置，
   直到 JDT 返回结果才放下一个构建出去。
4. **构建有自己的期限。** `javaBuildTimeoutMilliseconds` 默认 10 分钟，从进入
   队列开始计算，覆盖“等配置 + 等上一次构建 + 构建本身”。超时错误写明卡在
   哪个阶段（例如 `phase=waitingForProjectConfiguration`）。Windows 前端本地
   计时器只作兜底，比 Core 期限多 5 秒，不再与 Core 抢先超时。
5. **结果分类报告。** Core 按 JDT 的 `BuildWorkspaceStatus` 把非成功结果转成
   不同错误码：`javaBuildCompilationErrors`（确有编译错误）、`javaBuildFailed`
   （构建器内部失败，需要看语言服务日志）、`javaBuildCancelled`、
   `invalidServerResult`。成功时仍返回原来的 `{ value: 1 }`。
6. **报告事实，不替宿主作最终决定。** `WITH_ERROR` 和 `FAILED` 的错误附带
   `javaBuildReport`：请求的 marker 范围、同会话是否较早发生过构建器失败、本次耗时
   和建议恢复动作。`markerScope=launchTarget` 只是根据命令参数推导出“请求指定了
   项目”，Core 看不到 Java Debug Server 最终选中的工程；`elapsedMilliseconds` 也只
   是证据，不能用 7ms、50ms 等阈值判断 marker 是否可信。

后台重试构建和发送超时取消通知由每个会话的独立发送线程执行，监控线程不写
stdin（语言服务的标准输入管道），以免管道阻塞后超时检查也一起停止。后台写入
使用普通请求期限作为上限；超过后终止语言服务，释放写入并失败所有剩余请求。
构建排队期间只检查协调器状态，只有真正派发时才复制 LSP 客户端状态，避免每
10 毫秒复制已打开的文档和诊断。

开发者怎么做：新增任何“启动前要构建 Java 项目”的入口时，直接发
`vscode.java.buildWorkspace`，由 Core 负责排队和期限。不要在宿主里自己加锁、
自己重试或自己把超时改短；也不要在调用方被替换时主动取消构建，让 Core
按“还有没有人需要”来决定。

### 失败后的启动决策

Run 和 Debug 对 `javaBuildCompilationErrors`、`javaBuildFailed` 使用同一条决策路径：

1. 只执行一次构建；
2. 继续解析当前目标的 classpath/module-path；
3. 暂停原始异步启动，展示 Core 消息与报告；
4. 用户可选“仍然运行”“在此工作区始终继续”“重建 Java 索引”或“取消”；
5. “仍然运行”直接恢复同一次启动，不重新构建；“始终继续”按规范化工作区身份持久化，
   状态详情提供“再次询问”以恢复默认；“重建 Java 索引”取消本次启动并只清当前工作区；
6. `javaBuildCancelled`、请求取消、超时、传输失败和未知状态不可覆盖，因为它们没有
   产生可供用户判断的代码结论。

构建器曾经失败时，文案明确说明 marker 可能是残留；否则也说明错误可能来自目标的
依赖工程或整个工作区，避免把“仍然运行”包装成无视错误。Run 与 Debug 共用等待中的
启动意图，用户选择后恢复原意图，因此 Debug 不会退化成 Run，也不会偷偷再构建一次。

### 导入后的准备状态展示

macOS 和 Windows 在状态栏及 Run 面板展示同一份 Java 准备状态。
Rust Core 从已有的语言服务生命周期、Maven Profile 同步结果和 JDT 构建协调器
生成快照，不另建依赖图或猜测索引完成时间。窗口恢复时，即使事件已被消费，
轮询响应仍带当前快照；前端按工作区和会话身份拒绝过期事件。
传输异常同样结束准备状态，保留失败提示直到重试或显式停止，避免清理事件
把错误覆盖为“仍在准备”或“已就绪”。

服务启动、项目导入、配置同步和构建期间，依赖 JDT 的 Java 启动需等待。
普通索引不阻塞。Profile 的局部失败仍展示错误，但不封锁其他模块：选中目标
是否可构建由 JDT 判断。就绪只说明准备结束，运行前仍必须构建和解析路径。
状态详情给出设置、重试和日志入口，不提供上游无法兑现的百分比或取消操作。
缺失 JDK、没有运行配置等问题继续使用既有工具链和 Run 诊断。

Core 的有界等待是启动准备门禁的唯一真源。宿主的准备状态只用于展示，不用它禁用
Run 控件，也不在 `java-run-launch` 或平台 adapter 再做一次 `blocksRun` 快照检查；
用户点击后可以在准备状态可见的同时排队等待 Core。否则快照更新时序会产生“面板
已就绪、启动仍被准备中拦截”的自相矛盾状态。

## 考虑过的备选方案

- 先执行 `mvn compile`，再手工猜 `target/classes` 与依赖：被否。自定义输出目录、
  generated sources、测试源码、模块路径和非 Maven Java 项目都会重新造一套模型。
- 在 Maven Exec 上继续调整 `-pl/-am`：被否。Exec goal 与 reactor 生命周期绑定，
  无法稳定表达“构建依赖，但只在目标模块执行一次 Main”。
- 引入完整 Maven Embedder：暂不采用。体积和维护成本较高，而产品已打包 JDT LS
  与 Java Debug Server，后者已经提供成熟的构建和 classpath 解析能力。

- 只把构建超时改长：被否。超时拉长后构建仍会与 Profile 触发的项目更新以及
  重复点击产生的构建重叠；日志中的构建器内部异常与这些重叠同时出现，虽然
  直接因果尚未复现证实，但只改期限无法排除它们。
- 在 Windows/macOS 宿主各自串行化构建：被否。两个平台会各写一份相同的状态机，
  而且宿主看不到 JDT 的 `$/progress` 与 Maven Profile 任务状态，只能猜。
- 新 Run 替换旧 Run 时立即取消旧构建：被否。新 Run 马上就需要构建，取消只会
  让 JDT 从头再来；而且日志中一次取消与 JDT 的
  `endRule ... does not match` 异常在时间上紧挨着（因果尚未证实），没有必要
  主动制造这种时机。
- 调用 JDT 命令让它“等所有后台任务结束”：JDT LS 1.38 没有提供这样的命令，
  只能以它发出的进度通知为准。
- 用构建耗时阈值判定陈旧 marker：被否。无改动的成功构建和真实存量错误都可能在
  数毫秒完成，耗时只能帮助用户理解发生了什么，不能承载门禁判断。
- 默认关闭 m2e 的注解处理：被否。新克隆且尚未执行 Maven 的工程会缺少生成源码，
  同时偏离 m2e/JDT 的上游默认，影响面远大于本问题。
- 在点击“仍然运行”后重新调用完整准备流程：被否。既浪费大型工程的构建时间，又可能
  得到不同结论，无法保证继续的是用户刚刚审阅过证据的那次启动。

## 后果

- 多模块 Maven 的 Java Main 和已解析入口的 Spring Boot 服务只会启动一次，不再
  在父模块或依赖模块找主类。
- Maven 生成源码、测试源码 Main 和 JPMS module-path 使用同一项目模型。
- 点击运行可能需要等待 Java 语言服务 ready；构建失败会保留真实诊断，并在目标路径
  仍可解析时暂停等待用户决定，而不是永久阻止启动。
- 独立 Java 文件仍遵循“`javac` 编译再运行”的既有方案，不依赖语言服务。
- Linux Run 只把 Core 计划解析成 Linux 进程；Core 或配置失败会保留真实错误，
  不再退化为只执行 `compile`。Maven 项目里的 Java 入口在 JDT 准备完成前不会
  启动，Linux 也不会维护第二套源码扫描结果。
- 打开大型 Maven 项目后立即点击运行，可能要先等 JDT 的项目更新结束；等待原因
  会写入日志（`Java project build is waiting`），不会再因 30 秒期限而半路失败。
  Windows 运行面板在准备期间先显示一行“正在等待 Java 语言服务更新并构建项目”，
  启动成功后被启动命令替换，失败时错误信息接在它后面；这行提示不把会话标成
  运行中，避免与上一个进程迟到的退出事件相互覆盖。
- 构建门禁依赖 JDT 进度通知里的任务名（`Update project` 等英文前缀）。升级
  JDT LS 时要确认这些名字没有变化；如果变了，最坏情况退回到“构建不等待配置
  任务”的旧行为，而不会让构建卡死。
- JDT 在 Profile 命令返回之后才开始的配置任务，如果恰好晚于构建开始，
  仍可能与构建重叠；目前日志显示任务开始早于命令返回，这个窗口没有再加
  基于时间的等待。

## 验证

- Rust 构建协调：`cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib jdt_build`
  覆盖门禁、串行、合并、取消和超时阶段；engine 测试
  `java_builds_wait_for_project_updates_and_never_overlap`、
  `a_timed_out_java_build_keeps_its_slot_until_jdt_answers` 用脚本化 JDT 验证
  线上顺序。完整校验运行 `./scripts/verify-rust-core.sh`。
- Rust：Java Main 与已解析入口的 Spring Boot 服务启动计划必须是 `project-jdk`，
  参数不含 `-am`、Exec 插件或 Maven goal，并保留 JDT 返回的
  classpath/module-path。
- macOS：语言服务命令顺序为 resolve main → build workspace → resolve classpath；构建
  终态测试覆盖同一次启动继续、按工作区记忆选择和索引恢复。
- Windows：Run Store 把准备结果传入 Core，并分别用 `;` 拼 classpath/module-path；
  Run/Debug 共用的 Store 测试覆盖同一次启动继续、取消、记忆选择和索引恢复。
- Linux：`cargo test --manifest-path linux/Cargo.toml --lib --bins` 覆盖 Core
  process/Spring Boot 计划、`javac -> java`、POSIX classpath、工具链映射、
  pre-launch 失败门禁、过期 sequence 与完整进程组停止；测试不依赖本机
  Maven/JDK/网络。
- 共享契约：`shared/contracts/rust-core-api.md` 与
  `shared/contracts/application-boundary.md`，跨平台样例为
  `shared/fixtures/lsp/java-build-report-v1.json`。

## 适用范围

- Rust Core：`rust/lithe-core/src/execution/configuration.rs`
- Rust Core 构建协调：`rust/lithe-core/src/lsp/languages/jdt_build.rs`、
  `rust/lithe-core/src/lsp/interface/engine.rs`
- macOS：`LanguageToolingSessionManager`、`AppModel+RunConfiguration`、`RunService`
- Windows：`java-run-launch.ts`、`lsp-core-adapter.ts`、`run.store.ts`
- Linux：`linux/src/workbench/bottom_panel.rs`、`linux/src/workbench/run/`
- 相关笔记：
  `.agents/notes/implemented/feature/2026-09-17-standalone-java-compile-then-run.md`
