# Agent 笔记：Lithe 退出时结束它启动的全部子进程

状态：已实现

## 先说结论

macOS 上 Lithe 启动的运行、服务、预启动任务、测试、Maven 和插件进程，生命周期都绑定在 Lithe 上：项目会话关闭时由所属模块停掉自己的会话；应用退出前还有一道同步兜底，对所有仍存活的受管进程组先发 SIGTERM、限时后发 SIGKILL。正常退出和更新安装的强制退出两条路径都走这道兜底。

Windows（#1137）的运行会话、调试适配器和语言服务器现在各自放进一个 Job Object（作业对象，Windows 内核按句柄管理的一组进程）：停止时结束整组进程，Lithe 崩溃或被强制结束时内核也会连带结束它们。两端在关闭项目或窗口、退出 Lithe、安装更新而要停止运行服务时，都会先列出这些服务并询问；是否询问由同一条 Rust Core 规则和“退出时运行中的运行服务”设置决定。

## 问题

运行 Spring Boot 配置后退出 Lithe，Java 进程留在系统里继续占着 8080 端口，父进程变成 launchd。

两个原因叠加：

1. **服务会话没人停。** `RunService` 里“当前运行”和“服务会话”是两套状态。Spring Boot 这类配置属于服务会话，放在 `moduleProcesses` 等表里。退出时 `ExecutionFeatureGraph.stop()` 只调用了 `run.stop()`，它只管“当前运行”，服务会话一个信号都没收到。同理 `isActive` 也只看“当前运行”，有服务在跑时执行模块仍可能被判定为空闲而休眠。
2. **停止是异步的，进程退出不等它。** `MacStreamingProcess.stop()` 发出 SIGTERM 后把“超时再 SIGKILL”交给一个异步任务。应用马上就退出时，这个任务来不及执行；忽略 SIGTERM 或关闭较慢的子进程就会活下来。

## 决策

### 正确做法

1. **所属模块停自己的全部会话。** `ExecutionFeatureGraph.stop()` 依次停 Maven、当前运行、全部服务会话（`run.stopAllServices()`）和测试。`RunService.hasRunningServices` 汇总服务、语言执行会话和预启动进程，`isActive` 把它算进去，服务运行期间执行模块不会休眠。
2. **退出前有一道不依赖所有者的兜底。** `MacLiveProcessGroups` 记录每个已启动、尚未回收的 `MacManagedProcess` 进程组：`run()` 时登记，根进程被回收且后代清理完成后注销。`terminateAllAndWait` 同步执行：对全部进程组发 SIGTERM，等待宽限期（默认 0.2 秒），对仍存活的发 SIGKILL，再限时（默认 1 秒）等它们消失。
3. **两条退出路径都调用兜底。** `applicationWillTerminate` 开头调用一次；更新安装的强制退出路径用 `Foundation.exit` 结束进程，不会触发 `applicationWillTerminate`，所以在它之前也调用一次。
4. **记录表可注入。** 应用使用 `MacLiveProcessGroups.application`；测试传入私有实例，避免一个测试的“全部结束”杀掉并行测试的子进程。

### 主工作窗口关闭时清理全部项目

主工作窗口的红色关闭按钮通过 `LitheWindowCoordinator` 先同步并锁定本窗口全部编辑器，
再确认所有未保存文档，最后等待 `resetPrimaryWindowSessions()` 完成全部项目的模块清理。
没有其他项目窗口时保留主窗口及新的空会话，回到欢迎页；不再只调用当前项目的 `closeProject()`。
取消确认、保存失败或文档在确认期间变化时保留所有项目；清理期间重复点击不重复启动关闭流程。

如果独立项目窗口仍在运行，主窗口清理完成后沿用窗口关闭行为，不显示空白主窗口，
也不清理其他窗口的项目。该判断与主窗口标签数量无关。独立窗口和 Cmd+W 的原有语义保留；
项目标签的关闭按钮仍只关闭该项目。这里复用窗口关闭的异步清理，不调用应用退出兜底来误杀其他窗口的进程。

### 反例

- 只在所有者的 `stop()` 里发信号就返回：所有者漏掉一类会话，或者进程在异步升级前退出，子进程都会变成孤儿。
- 兜底里用 `ManagedProcessRegistry`：它是内存监控的 PID 台账，`stop()` 一调用就注销，恰好漏掉“已请求停止但还没死”的进程。
- 退出时无限等待子进程：一个卡住的子进程会让应用退不出去。兜底必须有界。
- 在宿主里按插件或语言名字挑进程来杀：兜底针对的是进程组的所有权，与进程属于哪个插件无关。

### Windows：进程树归属和统一退出入口（#1137）

Windows 原来有五个漏洞，叠在一起导致“关闭 Lithe 后服务还在跑”：

1. 运行进程没有放进 Job Object，Lithe 一崩溃，所有子进程都成了孤儿。
2. 停止靠 `taskkill /F /T /PID`。它沿父进程 PID 链找后代，中间进程（例如 `mvn.cmd` 启动 Java 后自己退出）一断，后代就找不到了，而且失败被静默吞掉。
3. 窗口销毁只取消预启动任务，应用退出不停运行会话。
4. 菜单“退出”直接调用 `exit(0)`，跳过了窗口的关闭守卫，包括未保存文件的确认。
5. 更新器启动安装程序后调用 `std::process::exit(0)`，不触发 `RunEvent::Exit`，退出清理一行都不执行。

修复按“谁拥有进程树”来做，而不是给每个入口补一次 `taskkill`：

- **进程树。** `lithe-git-host` 新增 `ProcessTree`：子进程以挂起状态创建，先加入设置了 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job，再恢复主线程，所以它启动的任何后代都在 Job 里。停止用 `TerminateJobObject`，然后用 `JobObjectBasicAccountingInformation.ActiveProcesses` 确认整组已经清空；超时会报错，不会假装成功。句柄关闭（包括 Lithe 崩溃）时内核结束整组。运行会话、调试适配器（它启动的被调试程序也在同一组）和 Windows 上的语言服务器（批处理启动的 JVM 也在同一组）都用它。Unix 上 `ProcessTree` 是新的进程组，现有 macOS 路径不变。
- **允许主动脱离。** 运行会话的 Job 设置了 `JOB_OBJECT_LIMIT_BREAKAWAY_OK`：程序显式用 `CREATE_BREAKAWAY_FROM_JOB` 启动的进程可以离开，相当于 Unix 上自己 `setsid` 的守护进程。Git 进程树不允许脱离。
- **根进程退出即收尾。** 根进程退出后，Lithe 结束它留下的整组进程，再等输出管道读完，和 macOS `MacManagedProcess` 一致。否则残留的后代会一直占着管道，会话永远不结束。
- **停止失败可见。** 停止超时的会话放回表里，错误里写明服务名和 PID；窗口不会关闭，弹窗显示原因，可以重试或取消。
- **原生表是唯一来源。** 关闭前列出服务时读原生会话表（`run_list_owned_processes`），而不是前端 store：Maven 目标、已关闭项目留下的服务只在原生表里。Maven 依赖解析这类 Lithe 自己的后台任务标记为 `background`，随窗口结束但不出现在问题里。
- **一个退出入口。** 菜单“退出”改为通知每个窗口走自己的关闭守卫（未保存文件 → 运行服务），最后一个窗口关闭后应用自然退出。更新安装先下载，再确认并停止所有窗口的运行服务，然后调用原生 `app_prepare_update_install` 结束调试、Agent 和语言工具，最后才运行安装程序。

### 关闭和退出前询问运行服务

运行服务（运行配置、Maven 目标）的进程树和输出管道属于 Lithe，没法在 Lithe 关闭后继续保留，所以这里只有“停止全部”和“取消关闭”两个选项，不像后台服务那样可以逐项保留。

- Rust Core 的 `processLifecycle.resolve` 对 `kind: run`、`ownership: launched` 的记录，在 `quit` 和新的 `closeWorkspace` 场景下返回 `confirmStop`（设置为询问）或 `terminate`（设置为直接停止），原因是 `runServicesSetting`。`closeWorkspace` 场景下其他需要提问的记录一律 `defer`，留到退出时再决定。规则失败时两端都按“询问”处理。
- macOS 在三个位置询问：退出（排在终端、Agent 任务和后台服务之前）、关闭项目（在文档关闭流程之前，因为文档是逐个关闭的，之后再取消会留下没有文档的项目）、关闭项目窗口（在未保存文件确认之后、清理之前）。
- Windows 在窗口关闭守卫里询问，顺序是未保存文件在前、运行服务在后；更新安装时询问全部窗口的服务。
- 设置：macOS 在“进程终止策略”页，Windows 在“运行配置”页（不打开项目也显示），默认询问。

## 考虑过的备选方案

- **只修 `ExecutionFeatureGraph.stop()`。** 能解决 Spring Boot 这一例，但下一个漏停的所有者、以及异步升级被进程退出截断的问题仍在。
- **让子进程自己感知父进程死亡。** macOS 没有 Linux `PR_SET_PDEATHSIG` 那样的机制；通过管道或 kqueue 监视父进程需要在子进程里放代码，用户的 Java 程序做不到。
- **Windows 继续用 `taskkill /T`，只在退出路径多调用几次。** 中间进程退出后 PID 链断开的问题仍在，崩溃时也没有任何兜底，这就是 #1137 一直复现的原因。
- **Windows 只在前端列出服务（#1404 的第一版）。** 前端 store 只认识运行面板里的会话，Maven 目标和已关闭项目留下的服务不在其中，问题列表会漏项；改为读原生会话表。
- **给运行服务提供“保留”选项。** 运行服务的输出管道和进程树都归 Lithe，Lithe 退出后保留只会制造无人管理的孤儿，所以确认里只有停止和取消。

## 后果

正常退出和更新重启后不再留下运行、服务或测试进程。退出最多多等约 1.2 秒，且只在有子进程不肯退出时才会等满。

未覆盖的情况：

- **macOS 上 Lithe 崩溃或被强制杀死。** 本笔记的兜底是进程内代码，这时不会执行；崩溃由 [统一子进程生命周期](../../proposed/architecture/2026-10-16-unified-child-process-lifecycle.md) 中的监护进程处理。Windows 的运行、调试和语言服务器进程树由 Job Object 兜底。
- **不经过 `MacManagedProcess` 的进程。** Rust Core 启动的语言服务器由 `languageToolingSessions.stopAll()` 停止，内置终端由终端自身管理，它们不在这张表里。
- **Windows 终端和 Agent。** ConPTY 终端里启动的程序、Agent 进程树还没有放进 Job Object，Lithe 崩溃时仍可能残留；正常退出由各自的关闭流程处理。

## 验证

- `macos/Tests/LitheTests/LitheCoreLogicTests.swift`：验证红色关闭按钮等待全部会话清理后保留欢迎窗口，取消与保存失败保留项目，重复点击不重复清理；同时覆盖 Cmd+W 和独立窗口隔离。

- `macos/Tests/LitheExecutionModuleTests/ExecutionModuleTests.swift`：`stoppingTheGraphStopsServiceSessions` 启动一个服务会话，确认它不算“当前运行”但让执行图保持活跃，`stop()` 之后进程停止、活跃状态清除。
- `macos/Tests/LitheTests/MacProcessRunnerTests.swift`：`applicationExitKillsEveryGroupItsOwnersLeftRunning` 启动一个忽略 SIGTERM 的进程和一个带忽略 SIGTERM 后代的进程，所有者丢弃引用后调用兜底，确认两个进程组在 2 秒内消失。
- 实际应用（2026-10-14，macOS）：运行 Spring Boot 配置，Java 进程监听 8080 后从菜单退出 Lithe，1 秒内 Lithe、语言服务器和 Spring Boot 进程全部消失，端口释放。修改前同样的操作会留下 Java 进程。未实测更新安装的强制退出路径。
- `./scripts/test-macos.sh --filter '(MacProcessRunnerTests|ExecutionModule)'`。
- `rust/lithe-git-host/tests/process.rs`：`process_tree_terminate_ends_the_root_and_its_descendants` 启动一个会再启动后代的进程，确认 `terminate` 返回时两者都已结束；Windows 上 `dropping_a_process_tree_ends_it_like_a_crashed_host` 只丢弃句柄，确认内核结束整组。
- `windows/tauri/src-tauri/src/run.rs` 测试（仅 Windows）：关闭一个窗口只结束它自己的进程树、丢弃会话等同 Lithe 崩溃、原生列表按启动顺序包含全部会话。
  - Windows CI 39919376382 在关闭窗口和丢弃会话两例中，根进程已退出，但立即读取的 `sysinfo` 快照仍包含后代 PID。测试改为停止前打开后代的只等待句柄，停止后分别在两秒内等待根进程和后代的退出信号；另一窗口的后代用零等待确认仍在运行。依据 [Windows 进程终止语义](https://learn.microsoft.com/en-us/windows/win32/procthread/terminating-a-process)，退出进程的对象可以因尚未关闭的句柄而继续存在，进程退出信号才是结束依据。保留原来的窗口隔离、重复关闭和崩溃清理断言，不改产品停止流程。夹具的首字节就绪信号有两秒期限，失败路径和断言展开时也按所属会话清理进程树、等待退出并释放管道和句柄；不依赖任意睡眠或 PID 重查。
- `rust/lithe-core/src/lsp/interface/process.rs` 测试（仅 Windows）：结束批处理启动的语言服务器时，脚本启动的子进程一起结束。
- `shared/fixtures/process-lifecycle/exit-plan-v1.json`、`settle-v1.json`：运行服务在退出、关闭项目、直接停止设置和崩溃恢复下的动作；macOS `ProcessLifecycleFixtureTests` 用 Swift 类型解码同一批 fixture，并覆盖提问顺序、取消和规则失败时仍询问。
- `windows/tauri/src/features/window/services/run-services-exit.test.ts`：询问、取消、停止失败后重试、直接停止、后台任务不询问、Core 不可用时询问。

## 适用范围

- `macos/Sources/LitheExecutionModule/Module/ExecutionFeatureGraph.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacManagedProcess.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacProcessGroup.swift`
- `macos/Sources/Lithe/LitheApp.swift`
- `macos/Tests/LitheExecutionModuleTests/ExecutionModuleTests.swift`
- `macos/Tests/LitheTests/MacProcessRunnerTests.swift`
- `shared/platform-feature-matrix/features/run-processes-end-with-ide.json`
- `rust/lithe-git-host/src/lib.rs`（`ProcessTree`）
- `rust/lithe-core/src/process/lifecycle.rs`、`rust/lithe-core/src/lsp/interface/process.rs`
- `shared/fixtures/process-lifecycle/`、`shared/contracts/rust-core-api.md`
- `macos/Sources/Lithe/Application/Features/ProcessExitCoordinator.swift`、`WorkspaceSessionCoordinator.swift`
- `macos/Sources/Lithe/Views/App/RootView.swift`、`ProcessTerminationSettingsView.swift`
- `windows/tauri/src-tauri/src/run.rs`、`debug.rs`、`owned_processes.rs`、`main.rs`
- `windows/tauri/src/features/window/`（关闭守卫、运行服务确认、退出入口）
- `windows/tauri/src/features/settings/stores/update.store.ts`
