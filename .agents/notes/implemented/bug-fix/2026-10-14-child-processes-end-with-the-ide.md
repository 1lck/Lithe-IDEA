# Agent 笔记：Lithe 退出时结束它启动的全部子进程

状态：已实现

## 先说结论

macOS 上 Lithe 启动的运行、服务、预启动任务、测试、Maven 和插件进程，生命周期都绑定在 Lithe 上：项目会话关闭时由所属模块停掉自己的会话；应用退出前还有一道同步兜底，对所有仍存活的受管进程组先发 SIGTERM、限时后发 SIGKILL。正常退出和更新安装的强制退出两条路径都走这道兜底。

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

## 考虑过的备选方案

- **只修 `ExecutionFeatureGraph.stop()`。** 能解决 Spring Boot 这一例，但下一个漏停的所有者、以及异步升级被进程退出截断的问题仍在。
- **让子进程自己感知父进程死亡。** macOS 没有 Linux `PR_SET_PDEATHSIG` 那样的机制；通过管道或 kqueue 监视父进程需要在子进程里放代码，用户的 Java 程序做不到。

## 后果

正常退出和更新重启后不再留下运行、服务或测试进程。退出最多多等约 1.2 秒，且只在有子进程不肯退出时才会等满。

未覆盖的情况：

- **Lithe 崩溃或被强制杀死。** 兜底是进程内代码，这时不会执行，子进程仍会变成孤儿。
- **不经过 `MacManagedProcess` 的进程。** Rust Core 启动的语言服务器由 `languageToolingSessions.stopAll()` 停止，内置终端由终端自身管理，它们不在这张表里。
- **Windows。** 退出处理只关闭语言工具和调试会话，没有停止运行会话，运行进程也没有放进 Job Object，尚未对齐。

## 验证

- `macos/Tests/LitheTests/LitheCoreLogicTests.swift`：验证红色关闭按钮等待全部会话清理后保留欢迎窗口，取消与保存失败保留项目，重复点击不重复清理；同时覆盖 Cmd+W 和独立窗口隔离。

- `macos/Tests/LitheExecutionModuleTests/ExecutionModuleTests.swift`：`stoppingTheGraphStopsServiceSessions` 启动一个服务会话，确认它不算“当前运行”但让执行图保持活跃，`stop()` 之后进程停止、活跃状态清除。
- `macos/Tests/LitheTests/MacProcessRunnerTests.swift`：`applicationExitKillsEveryGroupItsOwnersLeftRunning` 启动一个忽略 SIGTERM 的进程和一个带忽略 SIGTERM 后代的进程，所有者丢弃引用后调用兜底，确认两个进程组在 2 秒内消失。
- 实际应用（2026-10-14，macOS）：运行 Spring Boot 配置，Java 进程监听 8080 后从菜单退出 Lithe，1 秒内 Lithe、语言服务器和 Spring Boot 进程全部消失，端口释放。修改前同样的操作会留下 Java 进程。未实测更新安装的强制退出路径。
- `./scripts/test-macos.sh --filter '(MacProcessRunnerTests|ExecutionModule)'`。

## 适用范围

- `macos/Sources/LitheExecutionModule/Module/ExecutionFeatureGraph.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacManagedProcess.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacProcessGroup.swift`
- `macos/Sources/Lithe/LitheApp.swift`
- `macos/Tests/LitheExecutionModuleTests/ExecutionModuleTests.swift`
- `macos/Tests/LitheTests/MacProcessRunnerTests.swift`
- `shared/platform-feature-matrix/features/run-processes-end-with-ide.json`
