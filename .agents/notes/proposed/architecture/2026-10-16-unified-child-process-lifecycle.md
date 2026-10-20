# Agent 笔记：统一的子进程生命周期与退出清理

状态：提议中

## 先说结论

用户反馈：退出 Lithe 后，终端里启动的 Spring 服务、运行配置、LSP 和插件
进程有时仍在后台运行，继续占用端口和内存。原因是现在每类进程各管各的
停止逻辑，而且只覆盖“正常退出”，应用崩溃、被强制退出或更新超时后没有
任何兜底。

提案的核心是进程账本（Process Ledger，记录“谁启动了什么、退出时该怎么
处理”的登记表）。每条记录在启动时就带上退出策略：普通进程退出时自动结束；
守护进程、容器这类结束后会影响用户的资源，退出时弹出确认窗口，让用户逐项
选择“结束”或“保留”。只有能证明由当前 Lithe 实例启动的资源才会进入账本和
确认窗口，Lithe 之外启动的守护进程、容器一律不关心。有两类资源误关的代价
特别高，需要逐个确认、不提供批量结束：仍有程序在运行的终端，以及 Agent
启动的后台任务（可能正在执行迁移、部署等不可中断的操作）。Agent 后台任务
在崩溃兜底中也不会被自动结束。这些是默认值，用户可以在设置的“进程终止
策略”页面调整，每个选项旁的 ⓘ 图标会在鼠标悬停时解释它的含义。账本之外再加两层兜底：Windows 用 Job Object（作业对象，
内核在句柄关闭时连带结束其中所有进程），macOS 用随应用启动的监护进程；
下次启动时再清扫上次残留的进程。

对开发者的影响：不能再直接 `Process()` 或 `Command::new` 启动长期进程；
插件的每个进程和外部资源必须在 `plugin.json` 里声明退出策略，没有声明的
插件进程宿主不会启动。

## 问题

### 用户能观察到的现象

- 在内置终端里执行 `mvn spring-boot:run` 后退出 Lithe，8080 端口仍被占用，
  下次运行时提示端口冲突。
- 强制退出或崩溃后，`jdtls`、调试适配器、数据库 sidecar 继续运行。
- Sparkle 更新时清理超过时限，应用直接 `exit`，没来得及停止的进程变成孤儿
  进程（Orphan Process，父进程已退出、被系统 `launchd`/`System` 接管的进程）。
- 另一方面，Gradle Daemon、Docker 容器这类资源不能一刀切地结束：用户可能
  希望它们在 IDE 关闭后继续服务，但现在既不会结束它们，也不会告诉用户它们
  还在运行。

### 现有实现的缺口

macOS 侧：

- `MacManagedProcess` 已用 `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 让每次运行
  拥有独立进程组（Process Group，可以一次性发信号的一组进程），`MacProcessGroup`
  先发 `SIGTERM` 再升级为 `SIGKILL`。这是正确基础，但进程组不是隔离边界：
  调用 `setsid`、`nohup`、双重 fork 的子孙进程会离开进程组。
- 终端走 SwiftTerm 的 `LocalProcess.terminate()`，它只对 shell 主进程发
  `SIGTERM`。交互式 shell 的每个作业（Job，shell 中一条前台或后台命令）
  都在自己的进程组里，它们能否被连带结束取决于 shell 是否转发 `SIGHUP`；
  `disown`、`nohup` 或忽略 `SIGHUP` 的程序会留下来。
- `LitheApp.applicationShouldTerminate` 通过 `ProjectSessionManager.stopAllSessions()`
  走模块休眠链路完成清理，只在 AppKit 正常退出时执行。更新路径到时限后
  调用 `Foundation.exit`，剩余进程不再处理。
- `MacPluginPackageDownloader`、`MacStableRollback` 仍直接使用 `Foundation.Process`，
  不在统一路径内。

Windows 侧：

- 运行配置结束用 `taskkill /F /T /PID`，它依赖父子 PID 链；中间进程已退出时，
  子孙进程无法被找到。
- 终端的 `TerminalConnection::kill` 只结束 ConPTY 的 shell 子进程，shell 启动的
  服务不在其中。
- `RunEvent::Exit` 只调用 `language_tools::shutdown()`、`debug::shutdown()` 和日志
  关闭，没有统一停止运行会话与终端会话；窗口销毁时也只取消预启动任务。
- 没有使用 Job Object，崩溃后所有子进程都会存活。

Agent 侧：

- `rust/lithe-agent-host` 的 `AgentHandle` 在关闭连接或被释放时，调用
  `terminate_tree`/`force_kill_tree` 结束整个 Agent 进程树；确认取消超时后
  也会停止进程树。Agent 通过自己的工具在后台启动的命令都是这棵树的子孙，
  会被不加确认地一起结束。
- 退出 Lithe 时，终端标签不论是否有程序在运行都直接关闭，用户没有机会
  确认终端里正在跑的东西。

### 不处理的后果

端口冲突、内存持续占用，用户只能去活动监视器或任务管理器手动结束进程。
随着插件和 LSP 变多，残留进程会越来越多，也会违反 `AGENTS.md` 中“测试结束
后确认没有 Lithe 进程残留”的要求，自动化测试也无法稳定断言。

## 提案

### 第一层：进程账本

#### 账本记录什么

账本登记的是“受管资源”，分两种：

- **进程**：由 Lithe 启动的子进程，以及后来被发现属于它的子孙进程。
- **外部资源**：不是 Lithe 的子进程、但由 Lithe 创建的东西，例如 Docker
  容器、Compose 项目。它们没有可以直接发信号的 PID，只能调用所有者提供的
  停止动作（例如 `docker stop <id>`）。

每条记录至少包含：

- 所有者（Owner）：窗口、项目会话、模块 ID 或插件 ID；
- 类型：`run`、`terminal`、`agentTask`、`languageServer`、`debugAdapter`、
  `pluginTool`、`sidecar`、`daemon`、`container`、`oneShot`；
- 退出策略（见下一节）和停止方式、宽限时间；
- 平台句柄：macOS 的进程组和会话 ID，Windows 的 Job 句柄；外部资源则是
  资源 ID 和停止动作；
- 进程身份：PID 加启动时间，避免 PID 被系统复用后误杀无关进程；
- 展示信息：名称、命令行摘要、监听端口、内存，供退出确认窗口使用。

账本是现有 `ModuleResourceScope` 的下层实现，不另起一套模块生命周期：模块
仍然通过资源 scope 登记资源，资源 scope 再向平台进程端口申请进程。账本的
记录结构、分类规则、停止阶段和结果报告是两个平台共享的确定性语义，放进
`rust/lithe-core/`，并在 `shared/contracts/` 增加契约与 fixture；发信号、
Job Object、监护进程等平台能力留在各自的 adapter。

#### 四种退出策略

| 策略 | 含义 | 典型例子 | 退出时 |
| --- | --- | --- | --- |
| `terminate` | 生命周期从属于 IDE | 运行配置、测试、LSP、调试适配器、空闲终端的 shell、数据库 sidecar | 自动结束，不打扰用户 |
| `confirmEach` | 误关代价高，必须逐个确认 | 仍有程序在运行的终端标签、Agent 启动的后台任务 | 默认逐个弹出确认，没有“全部结束”，可在设置中改为不询问；崩溃兜底对 Agent 后台任务不生效 |
| `askOnExit` | 结束会影响用户，需要用户决定 | Gradle/Kotlin Daemon、`mvnd`、终端中脱离会话的后台进程、Docker 容器、插件声明的常驻服务 | 列入退出确认窗口，可逐项或批量选择 |
| `external` | 不能证明由本实例启动（见下文“只管 Lithe 自己启动的东西”） | 用户在 Lithe 之外启动的 Docker 守护进程、容器、Gradle Daemon | 不登记、不处理、不展示 |

默认值是 `terminate`。没有被明确判定为其他类别的记录一律自动结束，这样
漏判的结果最多是“多结束了一个进程”，而不是“又留下一个进程”。唯一的例外
是 Agent 进程树：其中无法判定的子孙进程默认归为 `confirmEach`，因为误结束
Agent 任务比留下一个进程的后果更严重。

#### 怎么区分：分类在启动时决定，不在退出时猜

退出时再按进程名、命令行去猜类别不可靠，所以每条记录的策略来自以下四个
来源，优先级从高到低：

1. **用户设置**：“进程终止策略”页面中按分组设置的默认值，以及在退出确认
   窗口勾选“以后对这类资源都这样做”后记住的选择（按识别规则 ID 保存，
   同样在该页面列出）。见下文“设置：进程终止策略”。
2. **启动方声明**：宿主内置功能在调用进程端口时显式传入策略；插件进程的
   策略来自 `plugin.json`（见下文）。启动时就确定，不需要推断。
3. **识别规则（Recognizer）**：用于“插件或运行配置启动的进程，又自己派生出
   守护进程”的情况。例如 Gradle 插件声明：命令行主类为
   `org.gradle.launcher.daemon.bootstrap.GradleDaemon` 的进程属于 `daemon`、
   策略 `askOnExit`。识别规则只能由插件清单或宿主内置功能的清单提供，宿主
   通用代码里不按工具名写分支。
4. **脱离检测**：带有本实例标记、但已经离开原来的进程组或会话（调用了
   `setsid`，或被 `launchd`/`System` 接管）的进程，说明它有意变成后台常驻，
   且没有被任何识别规则认领，就归为 `askOnExit`，名称显示为“未识别的后台
   进程”。

外部资源（容器）没有进程标记可追踪，由对应插件作为资源提供者
（Resource Provider）在创建时登记，并附加 `lithe.instance=<实例 UUID>` 标签，
以后可以精确找回。

#### 只管 Lithe 自己启动的东西

账本和退出确认窗口只处理能证明由当前 Lithe 实例启动的资源。证明方式只有
三种：经过账本启动、带有本实例的 `LITHE_PROCESS_SCOPE` 环境标记、带有本实例
的 `lithe.instance` 标签。不满足的一律视为外部资源，不登记、不展示、不结束，
也不作为“建议项”出现在窗口里。

例如：

- 用户在 Lithe 之外启动的 Docker 守护进程、容器、Gradle Daemon，即使正在
  被 Lithe 使用，也不出现在退出窗口中。
- 用户在 Lithe 终端里执行 `docker run`：`docker` 命令行进程本身带有环境标记，
  按终端规则结束；但容器由 Docker 守护进程创建，不继承这个标记，目前无法
  证明归属，因此不列出。以后如果需要覆盖这种情况，必须先找到可靠的归属
  证据（例如改为通过 Docker 插件的动作创建，由插件打上标签），再纳入，不能按
  “本次会话期间创建”这类时间窗口去猜。

#### 终端：退出前逐个确认

终端里运行的程序通常是用户手动启动的服务或命令，结束它们之前必须让用户
逐个看过。退出 Lithe 时，在任何进程被停止之前：

- 账本按终端标签统计其 shell 会话（同一 `getsid` 或同一 Job）下的进程。
  只剩空闲 shell、没有其他进程的标签视为空闲，直接关闭，不弹确认。
- 仍有程序在运行的标签逐个确认。每次只显示一个标签：标签名、所属项目、
  工作目录、正在运行的命令及其子进程、监听端口、运行时长。
- 每个标签只有三个按钮：“结束此终端”“跳到此终端”“取消退出”。没有
  “全部结束”，也没有“记住选择”。选择“跳到此终端”或“取消退出”都会终止
  整个退出流程，已经确认过的标签也不会被结束，让用户先自己处理。
- 终端无法在 Lithe 退出后保留：PTY 随应用关闭，所以终端只有“结束”和
  “不退出”两种结果，不存在“保留”。
- 关闭单个终端标签时，如果标签里还有程序在运行，也弹出同样的确认。

#### Agent 后台任务：单独确认，崩溃时也不自动结束

Agent（经由 ACP 连接的 Claude Code、Codex 等）会用自己的工具在后台运行
命令，例如数据库迁移、部署脚本、长时间构建。这些任务由 Agent 发起、用户
可能并未逐条留意，中途被结束可能留下半完成的状态，后果比普通进程严重得多，
所以按 `confirmEach` 单独处理：

- **怎么识别**：Agent 进程树里，除 Agent 本体及其基础设施（ACP 适配器、
  CLI 本体、Agent 配置的 MCP 服务器）之外的子孙进程，都登记为 `agentTask`，
  并记录所属 Agent 和会话。基础设施清单由 Agent 集成声明，宿主不按进程名
  猜。如果上游 Agent 将来通过 ACP 公开结构化的后台任务列表，优先使用上游
  信息，进程树扫描只作补充。
- **怎么确认**：在终端确认之后，逐个弹出 Agent 任务确认：所属 Agent 与
  会话、完整命令行、工作目录、启动时间、运行时长。按钮为“结束此任务”
  “保留此任务”“打开所属会话”“取消退出”，同样没有批量操作和“记住选择”。
- **保留的效果**：选择保留的任务标记为 `retained`，Lithe 退出时只结束 Agent
  本体，不结束这些任务。为此保留任务必须事先与 Agent 本体分开管理：macOS 上
  它们不随 Agent 进程组一起被信号结束；Windows 上 Agent 进程树放在单独的
  Job 中，不设置 `KILL_ON_JOB_CLOSE`，结束 Agent 本体时逐个结束未保留的进程。
- **崩溃时不自动结束**：Lithe 或监护进程异常结束时，兜底层跳过所有
  `agentTask`，不论用户是否确认过。下次启动时在 Services 工具窗口中显示为
  “上次遗留的 Agent 任务”，仍然逐个确认。宁可留下一个进程，也不在用户
  不知情时打断 Agent 的操作。
- **断开 Agent 时也要确认**：关闭 Agent 连接、停止对话模块，或取消确认
  超时后停止 Agent 时，如果存在 `agentTask`，同样逐个确认，不能再直接
  `terminate_tree`。落地时需要同步修改
  [共享 ACP Agent 对话](../../implemented/architecture/2026-09-25-shared-acp-agent-conversation.md)
  中“停止该 Agent 的进程树”的描述。

#### 设置：进程终止策略

上面描述的是默认行为：终端和 Agent 后台任务默认逐个确认。用户可以在
设置中新增的“进程终止策略”（Process Termination Policy）页面改变默认值，
比如让某一类资源不再询问。

页面分组和选项：

| 分组 | 选项 | 默认值 |
| --- | --- | --- |
| 终端 | 退出 Lithe 时，运行中的终端：逐个确认 / 直接结束 | 逐个确认 |
| 终端 | 关闭单个终端标签时，有程序在运行就确认：开 / 关 | 开 |
| Agent 后台任务 | 退出 Lithe 或断开 Agent 时：逐个确认 / 总是保留 / 直接结束 | 逐个确认 |
| 守护进程与容器 | 退出 Lithe 时：询问 / 总是结束 / 总是保留 | 询问 |
| 守护进程与容器 | 已记住的选择：按识别规则列出，可单独修改或清除 | 空 |
| 普通进程 | 优雅停止的等待时间（运行配置、LSP、调试器等总是随 Lithe 结束，只能调整等待多久） | 5 秒 |
| 启动时清扫 | 上次遗留的进程：询问 / 自动结束 | 询问 |

几条固定规则不开放配置，页面上用说明图标讲清原因：

- 崩溃兜底永远不结束 Agent 后台任务，下次启动永远逐个确认它们。“直接结束”
  只对用户亲手执行的正常退出生效。
- 选择 Agent 任务“直接结束”时，选项下方常驻一行警告：“Agent 可能正在执行
  数据库迁移、部署等操作，直接结束可能留下半完成的状态。”
- Lithe 之外启动的进程和容器不出现在这个页面，也不受任何选项影响。

退出确认窗口里依然没有“全部结束”，终端和 Agent 任务的确认窗口里也没有
“记住选择”。想减少确认，只能来这个页面明确修改，避免用户在退出时随手点
错。`askOnExit` 窗口的“记住选择”会写入本页的“已记住的选择”列表，用户
随时能看到并撤销。

设置保存在用户设置存储中（Application Support / `%LOCALAPPDATA%`），不写入
安装目录。根据设置和账本记录算出最终策略属于确定性逻辑，放进
`rust/lithe-core/`：设置作为输入，两端用同一组 fixture 验证。页面关键词要
加入 `SettingsSearchVocabulary`，搜索“进程”“终止”“终端”“Agent”“守护进程”
都能找到这个页面。

#### 说明图标：用 ⓘ 讲清楚每个选项

很多用户不熟悉“守护进程”“进程组”这些概念，所以每个分组标题和每个不直观
的选项旁边都放一个说明图标（圆圈里一个 i，macOS 使用 SF Symbol
`info.circle`）：

- 鼠标悬停约 0.3 秒，在图标旁弹出说明气泡，移开后关闭。不使用原生
  `.help` 提示：它要停留约一秒才出现，而且只适合一行字。
- 点击图标或用键盘聚焦后按空格，也能打开同一个气泡，方便触控板用户和
  使用读屏软件的用户；读屏软件读出的内容与气泡一致。
- 说明文字放在 `Localizable.strings`（en、zh-Hans）中，不写死在视图里。
- 做成两端各一个的共享组件（macOS 放在 `Views` 的共享控件中，Windows 放在
  `windows/tauri/src/ui/`），设置页其他需要解释的选项以后也复用它，不各写
  一套气泡。

说明文字的写法：先说“这是什么”，再说“选了会怎样”，最后给一个例子；
不出现未解释的术语。草稿如下，实现时可以润色，但要保留这三层意思：

- **终端**：终端标签里你手动运行的程序，例如 `npm run dev`、
  `mvn spring-boot:run`。选“逐个确认”时，退出 Lithe 前会一个一个问你是否
  结束；选“直接结束”时不再询问，退出时全部关掉。没有程序在运行的终端
  总是直接关闭。
- **Agent 后台任务**：AI Agent 为完成你的请求而在后台运行的命令，例如
  执行数据库迁移、跑一次部署脚本。中途被打断可能留下做了一半的修改，
  所以默认逐个确认。“总是保留”会让任务在 Lithe 退出后继续运行。即使
  Lithe 意外崩溃，这些任务也不会被自动结束。
- **守护进程与容器**：一些工具为了加快速度，会在后台常驻一个进程，例如
  Gradle Daemon；容器指 Docker 容器。它们由 Lithe 启动，但关掉 Lithe 后你
  可能还想继续用。这里只包含在 Lithe 里启动的，你在 Lithe 外面启动的
  不会被列出，也不会被结束。
- **普通进程**：运行配置、测试、语言服务器、调试器等，它们只为 Lithe 服务，
  退出时总是结束。等待时间是先请它们自行收尾的时长，到时还没结束就强制
  关闭。
- **启动时清扫**：如果 Lithe 上次意外退出，可能有进程没来得及关掉。
  选“询问”会在下次启动时列出来让你决定；Agent 后台任务永远会单独询问。

#### 退出流程总顺序

1. 未保存文件确认（沿用现有流程）。
2. 终端逐个确认（设置为“直接结束”时跳过）。
3. Agent 后台任务逐个确认（设置为“总是保留”或“直接结束”时跳过，按设置处理）。
4. `askOnExit` 资源确认窗口（见下一节）。
5. 统一停止顺序（见后文）。

任何一步选择取消，整个退出都取消，此前的确认全部作废，不停止任何进程。
更新安装触发的退出也走这个顺序，清理时限只从第 5 步开始计算。

#### `askOnExit` 资源确认窗口

收集所有 `askOnExit` 记录：

- 没有这类记录，直接进入停止阶段，不弹窗。
- 有这类记录，按所有者分组展示：名称、类型、PID 或容器 ID、端口、内存、
  启动来源。每一行可以单独选择“结束”或“保留”。
- 窗口底部提供“全部结束并退出”“按选择退出”“取消退出”三个按钮，以及
  “记住对这类资源的选择”复选框。
- 窗口里只有能证明由本实例启动的资源，默认勾选“结束”。

用户选择“保留”的记录标记为 `retained`，写入 Application Support 的实例记录。
第二、三层兜底都会跳过它们，下次启动时在 Services 工具窗口中显示为
“上次保留的资源”，用户可以在那里继续结束它们。

#### 统一停止顺序

用户确认后，按以下阶段执行，总时限可配置（建议默认 5 秒）：

1. **冻结**：账本拒绝新的启动请求，防止清理过程中又冒出新进程。
2. **协议级优雅停止**（并行）：LSP 发送 `shutdown`/`exit`，DAP 发送
   `disconnect`，插件按清单声明的方式停止，容器调用提供者的停止动作。
3. **信号级优雅停止**（并行）：运行会话和终端发 `SIGTERM`/`SIGHUP`
   （Windows 发 `CTRL_BREAK_EVENT`）。Spring Boot 收到后会执行自己的优雅关闭。
4. **强制结束**：宽限到期后，macOS 对整个进程组和会话发 `SIGKILL`，
   Windows 调用 `TerminateJobObject`。
5. **核对**：确认除 `retained` 之外的记录都已结束。超过时限时，界面显示
   “仍在停止 N 个进程”，并提供“强制退出”按钮，不允许直接静默退出。

单个会话停止（关闭终端标签、停止运行配置、禁用插件）复用同一套阶段，只是
范围缩小到一个所有者，且不弹 `askOnExit` 确认窗口；但其中的 `confirmEach`
记录（运行中的终端、Agent 后台任务）仍然逐个确认。

### 如何保证以后新增的插件也会登记

靠“插件只能通过声明获得进程”的结构保证，而不是靠开发者记得调用某个 API：

1. **插件自身不能启动进程**。官方插件是声明式包，不在宿主进程里执行代码，
   语言服务器、运行命令都由宿主根据 `plugin.json` 启动（见
   [声明式语言插件](../../implemented/architecture/2026-10-12-declarative-language-plugins.md)）。
   宿主启动时一律经过账本，所以插件进程天然会被登记。
2. **清单必须声明生命周期**。`shared/contracts/plugins/v1/` 为每个语言服务器、
   常驻服务和资源提供者增加 `lifecycle` 字段；`plugins.declarative.validate`
   对缺少或非法的字段返回稳定的 `plugin.*` 错误码，插件直接无法安装。
   CI 中的 `ci-plugins.yml` 对所有官方插件跑同一组校验。
3. **识别规则也只能来自清单**。插件要让自己派生的守护进程进入 `askOnExit`，
   必须声明 `processRecognizers`；没有声明的派生进程会被脱离检测捕获，
   或者按默认 `terminate` 结束，不会静默残留。
4. **未登记进程有诊断**。监护进程如果发现带本实例标记、却不在账本里的进程，
   除了按规则处理，还会记录一条“未登记进程”诊断（包含所属插件），方便
   在开发阶段发现漏声明的情况。
5. **宿主代码的静态检查**。CI 禁止在平台进程 adapter 之外使用
   `Foundation.Process`、`posix_spawn`、`std::process::Command` 启动长期进程。

清单示例：

```json
"languageServers": [{
  "id": "gradle-ls",
  "lifecycle": { "exitPolicy": "terminate", "stop": "lspShutdown", "gracePeriodMs": 2000 }
}],
"processRecognizers": [{
  "id": "gradle-daemon",
  "kind": "daemon",
  "match": { "mainClass": "org.gradle.launcher.daemon.bootstrap.GradleDaemon" },
  "exitPolicy": "askOnExit",
  "displayName": "Gradle Daemon"
}],
"resourceProviders": [{
  "id": "docker-containers",
  "kind": "container",
  "exitPolicy": "askOnExit"
}]
```

字段名称在实现阶段以 `shared/contracts/plugins/v1/` 的 schema 为准，这里只说明
需要表达的信息。

### 第二层：操作系统级兜底

第一层只在应用还活着时有效，崩溃或被 `kill -9` 时需要第二层。

**Windows：Job Object。** 应用启动时创建一个顶层 Job，并设置
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`。每个会话再创建一个嵌套子 Job。子进程
通过 `PROC_THREAD_ATTRIBUTE_JOB_LIST` 在创建时直接加入 Job，避免“先启动、
再加入”之间的竞态；ConPTY 终端的 shell 也要用同样方式加入。应用进程因任何
原因结束、Job 句柄被内核关闭时，其中所有进程都会被结束。停止单个会话用
`TerminateJobObject` 代替 `taskkill /T`。

进程加入 Job 后不能再移出，所以“保留”这样实现：

- 在启动时就确定为 `askOnExit` 且用户记住了“保留”的进程，用
  `CREATE_BREAKAWAY_FROM_JOB` 启动在 Job 之外（顶层 Job 需要允许 breakaway）。
- 其他被用户选择保留的进程：正常退出时，先在第一层结束所有未保留的进程，
  再用 `SetInformationJobObject` 清除顶层 Job 的 `KILL_ON_JOB_CLOSE`，最后退出。
- 崩溃时来不及清除这个限制，会连同保留项一起结束。崩溃时用户没有做过选择，
  这是可以接受的结果。
- Agent 进程树例外：Agent 本体用 `CREATE_BREAKAWAY_FROM_JOB` 启动在应用 Job
  之外，放进单独的、不设置 `KILL_ON_JOB_CLOSE` 的 Agent Job。这样崩溃时 Agent
  后台任务不会被内核连带结束，由下次启动的清扫逐个确认。Agent 本体失去与
  Lithe 的 stdio 连接后应自行退出；不退出的同样在下次启动时列出。

**macOS：监护进程。** macOS 没有 Job Object，进程组和会话都能被 `setsid`
逃逸，所以由一个监护进程负责兜底：

- 监护进程使用同一个已签名的 Lithe 可执行文件，以 `--process-supervisor`
  参数启动，不新增二进制，也不向 app bundle 写入任何文件。
- 它通过 kqueue 的 `EVFILT_PROC`/`NOTE_EXIT` 监听主应用；主应用通过管道
  把账本变更（进程组、会话 ID、PID 加启动时间、退出策略、`retained` 标记）
  同步给它。
- 每个子进程的环境变量中注入 `LITHE_PROCESS_SCOPE=<实例 UUID>`。环境变量会被
  子孙进程继承，即使进程已经 `setsid` 并被 `launchd` 接管，也能通过
  `sysctl(KERN_PROCARGS2)` 读取同用户进程的环境变量把它找回来。识别规则和
  脱离检测也依赖这份进程快照。
- 主应用异常结束后，监护进程跳过 `retained` 记录，对其余已登记的会话、
  进程组和带有本实例标记的进程执行 `SIGTERM`、等待、`SIGKILL`，然后退出。
  `askOnExit` 记录和终端在没有用户选择时按“结束”处理，与 Windows 行为一致。
  `agentTask` 一律跳过，留给下次启动逐个确认；Agent 本体照常结束，但结束
  方式改为只对 Agent 本体的 PID 发信号，不对整个进程组发，避免连带任务。
- 主应用正常退出时，先完成第一层，再通知监护进程“已清理”，然后监护
  进程退出。

终端单独处理：停止终端时不再只调用 `LocalProcess.terminate()`，而是枚举
`getsid(pid) == shellPid` 的所有进程，对这些进程组逐一执行停止阶段。这样
shell 里每个作业所在的进程组都会被覆盖。

### 第三层：启动时清扫残留

两个兜底都失效时（例如主应用和监护进程同时被 `kill -9`、断电），下一次
启动时按实例标记扫描进程：

- 实例记录写在 Application Support（Windows 写在 `%LOCALAPPDATA%`），不得写入
  app bundle 或安装目录。
- 上次标记为 `retained` 的资源不算残留，显示为“上次保留的资源”。
- 上次遗留的 Agent 后台任务单独显示为“上次遗留的 Agent 任务”，逐个确认，
  不默认结束，也不提供批量结束。
- 其余残留在 Services 工具窗口提示“发现上次遗留的 N 个进程”，复用退出确认
  窗口的列表，默认全部勾选“结束”。

### 正确做法

```swift
// 宿主内置功能：通过平台进程端口申请，所有者和退出策略在启动时就确定
let handle = try processPort.launch(
    request,
    owner: .module(moduleID),
    policy: .init(exitPolicy: .terminate, stop: .lspShutdown, gracePeriod: .seconds(2))
)
resourceScope.register(handle)
```

```rust
// Windows：创建时直接加入会话 Job，而不是先启动再加入
let job = session_jobs.create_nested(&app_job)?;
spawn_with_job_list(command, &job)?;
```

### 不要这样做

- 不要在 Service 或插件里直接 `Process()`/`Command::new` 启动长期进程。
  账本不知道它的存在，退出和崩溃时都不会被清理。
- 不要在宿主通用代码里写 `if name == "gradle"` 来判断守护进程。识别规则要放进
  对应插件或内置功能的清单，否则每加一个工具都要改宿主。
- 不要对 Agent 的整个进程组或进程树直接发 `SIGKILL` 或调用 `terminate_tree`。
  Agent 后台任务也在这棵树里，必须先逐个确认。
- 不要给终端或 Agent 任务的确认窗口加“全部结束”或“记住选择”。逐个确认
  就是为了防止误关，批量按钮会让它失去意义；想少确认，只能去设置页明确修改。
- 不要让说明图标只用原生 `.help` 一行提示，也不要在每个设置页各写一套气泡。
  统一复用共享的说明组件。
- 不要在退出时才按进程名推断类别，也不要按进程名 `pkill java` 收尾。前者
  不可靠，后者会误杀用户在 Lithe 之外启动的进程。
- 不要用 `taskkill /T` 或按 PPID 递归重建进程树作为唯一手段。中间进程
  退出后进程树就断了。
- 不要把实例标记、账本快照、用户记住的选择写进 `Bundle.main.resourceURL`
  或安装目录。这会破坏 Sparkle 增量更新基线。

## 考虑过的备选方案

### 只补齐各模块的 `stop()` 逻辑

改动最小，可以逐个修复终端、Windows 运行会话的停止实现。但这只覆盖正常
退出，崩溃和强制退出仍然会残留；而且每新增一类进程都要重新写一遍，
下一个插件很可能再漏掉。所以只作为第一层的一部分，不能单独采用。

### 退出时按进程特征统一判断类别

不需要改插件清单，退出时扫描进程，按命令行、端口等特征判断哪些是守护进程。
实现快，但特征表会集中在宿主里不断增长，违反“插件专属逻辑由插件声明”的
原则；判断错误时用户也无从得知原因。改为启动时声明、识别规则由清单提供，
脱离检测只作为兜底。

### 所有后台资源一律保留，只结束前台进程

对用户最“安全”，不会误结束容器或守护进程。但这正是现在残留问题的来源，
用户无法得知哪些资源仍在运行。改为列出来让用户决定。

### macOS 上使用 launchd 托管每个子进程

让 `launchd` 以临时 job 的形式托管子进程，可以借助系统来回收进程。但它需要
为每个进程生成 plist 或调用私有 API，标准输入输出和 PTY 难以接入，用户在终端里
启动的进程也无法纳入，复杂度和收益不成比例。

### macOS 上使用 `NOTE_TRACK` 跟踪 fork

kqueue 曾支持 `NOTE_TRACK`，可以自动跟踪子孙进程的 fork，但现代 macOS 已经不再
支持，不能依赖。

### 只依赖 PTY 关闭时的 `SIGHUP`

关闭 PTY 主端时，内核会向前台进程组发送 `SIGHUP`，实现最简单。但后台作业、
`nohup` 和主动忽略 `SIGHUP` 的进程都不受影响，无法满足“全部结束”。

### 监护进程使用单独的辅助二进制

职责更清晰，但要新增签名、公证、打包和 Windows 对应物。复用主可执行文件
加启动参数，同样能隔离职责，而且发行包结构不变。

## macOS 首批落地（2026-10-16）

Windows 尚未实现，所以本笔记仍放在 `proposed/`。macOS 首批已落地的部分
如下，其他内容仍按上文提案执行。

### 规则在 Rust Core，平台只采集事实、执行结果

为了让 Windows 迁移时只需写平台 adapter，所有确定性规则都放在
`rust/lithe-core`，两端共用同一套 fixture：

| 命令 | 负责什么 | fixture |
| --- | --- | --- |
| `processLifecycle.resolve` | 每条记录在给定场景（退出、关闭终端标签、断开 Agent、崩溃兜底、启动清扫）下的动作 | `exit-plan-v1.json` |
| `processLifecycle.inventory` | 把一份进程快照分成 Agent 任务、Agent 基础设施、后台服务、终端和其他，并可附带该场景的计划 | `inventory-v1.json` |
| `processLifecycle.settle` | 把用户的回答变成“结束 / 保留”清单，并写入记住的选择 | `settle-v1.json` |

平台侧只负责以下几类事：

- 读取 PID、启动时间、会话、控制终端、继承的环境变量和工作目录；
- 弹出确认窗口，并决定提问顺序：终端逐个问，然后 Agent 任务逐个问，最后是后台服务列表；
- 发送信号并等待进程退出；
- 写入实例记录和启动监护进程。

macOS 的对应位置：

- `MacProcessInventoryReader`：采集快照并调用 `inventory`；
- `ProcessExitCoordinator`：决定提问顺序，调用 `resolve` 和 `settle`；
- `MacProcessExitConfirmationPresenter`：负责弹窗；
- `MacProcessSupervisor` 和 `MacStartupProcessSweep`：崩溃兜底和启动清扫，都以 `inventory` 的 leftover 模式为输入。

Windows 实现时只需要提供同样的快照字段（`ProcessSnapshotEntry`）和弹窗，
分类和结算规则直接复用。

几条容易做错的约定：

- 清单条目的 `id` 就是生命周期记录 ID，平台不得再加前缀。`id` 中含有 PID 和启动时间，所以合并多个遗留实例时也不会重复。
- 结算失败时，退出流程按“取消退出”处理；其他场景按“全部保留”处理。宁可不结束，也不能结束用户刚刚选择保留的东西。
- 规则计算失败时，所有记录都需要询问，不能默认结束。

### Review 修正与已知边界

退出确认先暂存所有项目的选择，只有编辑器检查和更新回滚准备都通过、退出已不能取消时，
才同时写入保留身份并通知各 Agent host；随后才能启动模块清理和更新超时计时。
例如项目 A 的清理阻塞时，项目 B 被保留的任务也已经受到保护，不能等到 B 的模块关闭才登记。
取消退出只清除暂存选择，不修改持久化保留名单。

保留一个任务时，关闭连接仍按完整 inventory 结束未保留任务和 Agent 基础设施，
包括首次 prompt 前启动的适配器、MCP 进程；只结束任务列表会遗漏这些进程。
终端主动关闭采用设置中的优雅停止时间，最终 sweep 不能代替前一阶段的等待预算。

保留身份使用 PID 和启动时间配对，持续展开仍可观测的父子关系并写回实例记录；
已记录子进程即使后来被重父化，也继续受保护。`NOTE_FORK`、`NOTE_EXIT`、`NOTE_EXEC`
仅用于触发快照刷新；现代 macOS 不支持 `NOTE_TRACK`，fork 通知也不携带子 PID，
所以无法还原瞬时 double-fork 的准确任务血缘。退出确认之后，新发现且未获终止批准的
Agent 进程身份由 Core 返回延期，连接关闭时通知 host 跳过，最终清扫也不自动结束；
实例记录保持未完成，下次启动按独立任务树逐项确认。最终清理开始前先持久化交接
标记，监护进程看到标记后不得改用崩溃默认策略结束延期任务；Core 或信号失败也保留记录。
已批准的兄弟任务和已知基础设施
仍被清理；不能把整个 Agent 连接或 session 标为保留。终止批准同样绑定 PID 与启动时间，
只在同一次快照有完整父子证据时扩展，PID 复用不会继承批准。正确示例是保留的任务退出后
出现一个从未观测到血缘的孤儿：先延期，下次确认；错误做法是按 Agent scope 自动结束它，
或者把同 scope 的所有兄弟任务永久保留。准确关联原任务仍需可继承的独立任务标记。

关闭单个 Agent 连接时，Core 请求必须显式限定目标 Agent scope；目标没有任务也不能
退回整实例扫描。实例退出才扫描所有连接，避免关闭 A 时误结束 B 的任务或基础设施。

实例记录在监护进程创建独立会话前保存应用原始 session ID（会话标识）；崩溃和下次启动
均用这个值判定脱离，不能使用执行清理进程自己的会话。旧记录缺失原始标识时，不推断
后台服务，也不执行无人值守清理；下次启动询问带实例标记的遗留进程。终端只在原始
shell 身份和当前可执行文件都吻合时算空闲；同 PID 的 exec 替换、同进程组子程序或无法
读取可执行文件均仍需确认。完整 GUI 退出、更新和崩溃验收仍待完成。

后台服务按有效的非应用 session 分组，不再要求 session 首进程仍存活；组内有控制终端
时不归为后台服务。首进程已退出的 daemon 仍需询问用户，不能落入普通进程直接结束。
共享 fixture 覆盖首进程缺失、输入顺序变化、终端 session 和应用 session 孤儿的区分。

最终清扫对后台服务与 Agent 任务同样要求精确身份批准。退出确认中被选择结束、或因设置
/记住的选择而直接结束的服务，在退出不可取消后才写入终止批准；确认快照之后才出现的
接替进程（例如保留的服务派生后代后自己退出）既没有被保留也没有被批准，按“询问”设置
延期到下次启动确认。设置或记住的选择为“结束”/“保留”时视为用户已预先回答，照常执行。
错误做法是因为它是实例内的后台服务就直接结束：用户看到并保留的是旧身份，不是接替者。

终端 session ID 只在 shell 首进程存活时可作归属证明。首进程退出后，会话最后一个成员
消失即可被系统复用，新会话成员的启动时间也晚于原首进程，启动时间下界挡不住。因此
首进程退出被观测到时（或开始终止时）先固定当时的成员身份，此后只认这些身份及其可观测
后代；没有成员就清除该标签的会话记录。首进程已退出时不再按进程组 ID 群发信号，只向
已固定的身份逐个发送。仍存在的窗口是首进程退出到终端回调之间的毫秒级间隙。

### 与提案的差异，以及推迟的部分

- **识别规则和 Docker 容器**：推迟。插件清单还没有识别规则和资源提供者字段，所以后台服务目前只靠“脱离检测”识别（有效的非应用会话且整组没有控制终端，即使会话首进程已退出），显示名取进程名。设置页的“已记住的选择”和弹窗里的“记住选择”已接好，有识别规则后才会出现。按“插件专属逻辑不进宿主通用代码”的约束，宿主不按 Gradle、Docker 等工具名写分支。
- **Agent 任务弹窗的“打开所属会话”按钮**：首批未实现。弹窗显示 Agent 名称、工作区、命令和启动时间。
  弹窗不用 `NSAlert` 的纯文本，而是 `AgentTaskExitConfirmationView` 卡片布局：状态、工作区、
  已运行时长各占一张卡片，命令放在固定最大高度的命令框里，超出后上下滚动，不会把窗口撑出屏幕。
  Rust Core 只给出用空格拼接的命令行，参数边界已经丢失，所以 `CommandLineDisplayFormatter`
  只在展示层恢复可读性：`--` 长选项另起一行；能完整通过 JSON 校验的对象或数组参数（例如 Agent
  CLI 的 `--settings {...}`）按原有键顺序和转义缩进排版，看起来像 JSON 但校验失败的文本原样显示。
  其余文本保留原有的换行、缩进和连续空白，`python3 -c` 一类内联脚本按实际运行的样子显示；
  只有空格分隔的长选项会被换成换行。括号扫描和 JSON 缩进各有总预算，深而宽的 JSON 超出预算时
  原样显示，避免退出时的模态弹窗卡住主线程。
  “复制”按钮复制原始命令行，不复制排版结果。
- **保留的 Agent 任务**：Agent 本体结束后，如果任务还在向 Agent 的管道写输出，可能被 `SIGPIPE` 结束。这是首批的已知限制，需要 Agent host 在保留前把任务的标准输出转到 `/dev/null`，作为后续工作。
- **插件清单的 `lifecycle` 字段和禁止直接启动进程的静态检查**：首批未做，仍按提案执行。
- **插件后端的遗留进程**（2026-10-20）：每个插件构建 Provider 启动时带独有的 `LITHE_PLUGIN_BACKEND_SCOPE`，和 `LITHE_AGENT_SCOPE` 一样随后代继承，`activate()` 会清掉从父 Lithe 继承来的值。会话结束后宿主在本实例作用域内按该标记和精确身份优雅结束遗留进程（`MacPluginBackendProcesses`）。只覆盖插件后端，不含宿主自己的语言服务器；详见[宿主调用插件函数](../../implemented/architecture/2026-10-20-host-plugin-function-invocation.md)决策 6。

## 验收标准

- 新增跨平台进程生命周期测试夹具：启动一个包含普通子进程、`setsid` 逃逸进程、
  `nohup` 后台作业、双重 fork 守护进程和监听端口的 Spring 风格 JVM 的进程树，
  分别覆盖以下四种退出方式，结束后断言除 `retained` 之外没有带本实例标记的
  进程存活、端口已释放：
  1. 正常退出；
  2. 更新安装退出（超过清理时限）；
  3. 对主应用执行 `kill -9`（Windows 用 `TerminateProcess`）；
  4. 主应用和监护进程同时被强制结束后再次启动（验证第三层清扫）。
- 分类 fixture 覆盖：宿主声明、插件清单声明、识别规则命中、脱离检测、用户
  记住的选择五种来源的优先级；未被任何来源判定的记录得到 `terminate`。
- 退出确认窗口：没有 `askOnExit` 记录时不弹出；选择“保留”的进程在退出后
  仍存活，且下次启动显示为“上次保留的资源”；选择“取消退出”后不停止任何进程。
- 终端确认：只有空闲 shell 的标签不弹确认；有程序运行的标签逐个确认，
  任一标签选择“跳到此终端”或“取消退出”后，所有终端和进程都保持运行。
- Agent 后台任务：Agent 后台启动的长时间命令在退出时单独逐个确认；选择保留
  后 Lithe 退出，任务仍存活且 Agent 本体已结束；对主应用执行 `kill -9` 后任务
  仍存活，下次启动列为“上次遗留的 Agent 任务”。关闭 Agent 连接时有任务也会
  弹出确认，不再直接结束进程树。
- 进程终止策略设置：每个选项的默认值与上表一致；修改后退出流程按设置跳过或
  执行对应确认；“已记住的选择”可查看、修改和清除；崩溃兜底在任何设置下都
  不结束 Agent 后台任务。策略计算有 Rust Core fixture，两端共用。
- 说明图标：每个分组和不直观的选项都有 ⓘ；悬停约 0.3 秒出现说明，点击或
  键盘聚焦也能打开，读屏软件能读出同样内容；中英文文案齐全；设置搜索能找到
  该页面（`SettingsSearchVocabulary` 测试覆盖）。
- 归属边界：测试前在 Lithe 之外启动的守护进程和容器，以及另一个 Lithe 实例
  启动的进程，在退出窗口、兜底和启动清扫中都不出现，且退出后仍存活。
- 缺少 `lifecycle` 字段的插件清单被 `plugins.declarative.validate` 拒绝，并返回
  稳定错误码；官方插件全部通过 `ci-plugins.yml` 校验。
- 关闭单个终端标签时，该 shell 会话中所有作业都被结束，其他终端和运行会话
  不受影响。
- 静态检查禁止在 platform adapter 之外直接使用 `Foundation.Process`、
  `posix_spawn` 和 `std::process::Command` 启动长期进程，`MacPluginPackageDownloader`
  和 `MacStableRollback` 迁移到统一端口。
- 测试遵守 `write-stable-tests` 的有界等待、资源清理规则，单测试有计时上限。
- `scripts/verify-runtime-bundle-immutability.sh` 在启动、运行、退出的完整流程后
  仍然通过。
- `shared/platform-feature-matrix/features/` 增加“退出时结束或确认全部子进程”
  能力行，两个平台分别记录实现和验证状态。

## 风险

- **误杀用户进程**：环境变量标记可能被继承到用户有意脱离的进程。缓解：
  以 PID 加启动时间核对身份；脱离会话的进程归为 `askOnExit`，交给用户确认，
  而不是直接结束。
- **退出窗口打扰用户**：每次退出都弹窗会让人厌烦。缓解：空闲终端和空闲
  Agent 不弹确认；`askOnExit` 支持“记住选择”；嫌麻烦的用户可以在“进程
  终止策略”页面关闭某类确认。确认窗口本身不提供批量和记住选择，是有意
  保留的摩擦。
- **用户看不懂选项而误配置**：比如把 Agent 任务设为“直接结束”。缓解：每个
  选项都有 ⓘ 说明，危险选项常驻警告，崩溃兜底不受该设置影响。
- **Agent 任务识别不全或误识别**：Agent 基础设施清单不完整时，MCP 服务器等
  可能被当成任务要求确认；反之，Agent 本体内部线程化的工作无法看作进程。
  缓解：基础设施由 Agent 集成声明，误识别只会多一次确认，不会误结束；上游
  提供结构化任务列表后改用上游信息。
- **崩溃后 Agent 任务残留**：这是有意的取舍，换来不在用户不知情时打断任务；
  靠下次启动的逐个确认收尾。
- **终端里创建的容器会留下**：用户在 Lithe 终端里手动 `docker run` 的容器
  无法证明归属，按“只管 Lithe 自己启动的东西”不会被列出或结束。这是有意的
  取舍，需要在用户文档中说明；需要随 IDE 管理的容器应通过 Docker 插件创建。
- **读取其他进程环境变量的权限**：`KERN_PROCARGS2` 只能读取同用户进程，
  被 sudo 提权的进程无法读取。本机验证还发现受 SIP 保护的系统可执行文件可能只返回 argv、
  隐藏环境变量；不能把这种空环境当作“实例内没有遗留进程”的证明。测试使用 Xcode
  工具链 Python、就绪握手和真实 fork，先确认标记可读取再验证清扫；不把该夹具结果
  扩大为对所有系统可执行文件的覆盖。这类进程只能依靠第一层和进程组处理，需要在
  文档中说明。
- **Job Object 限制**：嵌套 Job 需要 Windows 8 以上版本，产品已满足。第三方
  程序如果自己创建了不允许嵌套的 Job，加入时会失败，此时退回到 `taskkill /T`
  并记录诊断。崩溃时 Windows 的保留项也会被结束，见第二层说明。
- **退出变慢**：优雅停止会延长退出时间。缓解：各阶段并行执行，总时限可配置，
  超时后由用户选择“强制退出”。
- **回退方式**：账本、退出确认窗口、兜底、启动清扫分别加开关，独立落地。
  监护进程出现问题时可以关闭第二层，退回到只有第一层的状态，不影响正常
  退出路径。

## 适用范围

- `macos/Sources/Lithe/LitheApp.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/`
- `macos/Sources/Lithe/Platform/MacOS/Terminal/MacTerminalTransport.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/`
- `macos/Sources/LitheTerminalModule/`
- `windows/tauri/src-tauri/src/main.rs`
- `windows/tauri/src-tauri/src/run.rs`
- `windows/tauri/crates/terminal/src/`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
- `macos/Sources/Lithe/Views/App/SettingsSearchVocabulary.swift`
- `windows/tauri/src/ui/`
- `macos/Sources/LitheAgentConversationModule/`
- `rust/lithe-agent-host/`
- `rust/lithe-core/`
- `shared/contracts/`
- `shared/fixtures/process-lifecycle/`
- `macos/Sources/Lithe/Application/Features/ProcessExitCoordinator.swift`
- `macos/Sources/Lithe/Platform/MacOS/Agent/MacAgentProcessRegistry.swift`
- `shared/contracts/plugins/v1/`
- 相关决策：[模块运行时边界与生命周期](../../implemented/architecture/2026-09-13-module-runtime-boundaries-and-lifecycle.md)
