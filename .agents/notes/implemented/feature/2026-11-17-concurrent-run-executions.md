# Agent 笔记：多个运行并行，构建任务仍然独占

状态：已实现

## 先说结论

工作台原来只有一个执行位 `buildState.operation`，构建任务和应用运行共用。启动一个 Spring Boot 服务后，第二个服务、甚至另一个配置都启动不了，和 IntelliJ IDEA 的行为不符（#2071、“可以同时运行多个服务”）。现在：

- 应用运行放进 `buildState.running`，每个运行有一个键：运行配置 `config:<id>`、构建目标 `target:<实例>/<目标>/<运行>`、命令入口 `entry:<实例>/<入口>`。不同键的运行并行。
- 同一个键再次运行时走 `startRun`：先停旧进程，旧运行结束（`endBuildOperation`）后再调用新的启动函数（`op.then`），两个进程不会同时占用端口或文件。这就是 IDEA 的“停止并重新运行”。
- 构建任务、模型加载、IDE API 的构建配置仍然只占 `buildState.operation`，一次一个，和运行互不阻塞。
- 调试仍是每个项目一个会话（用户明确不需要同时调试多个项目）。
- Run 标签在准备阶段显示转圈，进程启动后（`attachProcess` 设置 `runEntry.processRunning`）显示静态的绿色运行图标；常驻服务会运行几个小时，一直转圈说明不了它已经启动。

## 问题

`buildState.operation` 是唯一的执行位，`runConfiguration`、构建目标运行和命令入口都通过 `beginBuildOperation` 占用它，后续的输出、状态、停止和 IDE API 都用 `p.build.operation == op` 判断执行是否还在。于是一个服务在运行时，其他配置的运行按钮全部禁用；Run 标签只要进程还活着就一直转圈，看不出服务是否已经启动。

## 决策

运行和任务分开存放：运行按键放进 `buildState.running`，任务留在 `buildState.operation`。同一个键的运行先停后启，不同键并行；任务之间仍然互斥。下面是实现时必须遵守的规则。


- 判断“某个执行还属于窗口”一律用 `p.build.owns(op)`，不要再写 `p.build.operation == op`：运行不在 `operation` 里，这样写会让运行的输出、状态和停止全部失效。
- 停止某个执行用 `stopOperation(p, op)`。`stopBuildOperation(p)` 只停 `latest()`（任务优先，否则最新的运行），只给没有自己标签的控件用，例如 Build 窗口工具栏的停止；IDE API 按执行 ID 找到对应的执行再停止。
- 每个执行有自己的状态行 `op.status`，用 `setOperationStatus` 更新；`p.build.status` 只是最近一次的状态，不能拿来显示某个运行。
- 新增启动应用进程的路径时（内置进程运行 `startProcessRun` 就是这样做的），用 `beginRunOperation` 并给出键，通过 `startRun` 启动；不要用 `beginBuildOperation`，否则它会和构建任务互斥。
- `latest()` 先返回最新开始且仍在运行的执行（`buildState.newest`），所以启动后 `showBuildConsole` 显示的就是刚启动的那个，即使有任务在运行。
- 项目关闭（`stopBuildSessions`）时清掉所有 `then`，等待重启的运行不会在关闭后启动。
- IDE API 对正在运行的配置再次 `start` 返回 `BUSY`（`errRunRunning`）：外部调用方需要明确先停止，不替它决定重启。

## 考虑过的备选方案

- 同一配置允许多个实例（IDEA 的 “Allow multiple instances”）。服务大多监听固定端口，多实例默认会失败；先做默认的“停止并重新运行”，以后由 `runOptions` 扩展点加开关。
- 运行和构建任务全部并行。构建任务会写同一个输出目录，并行构建会互相破坏产物，保持独占。
- 同一键再次运行时直接拒绝。用户点运行就是想要新的进程，拒绝会让人以为按钮坏了。

## 后果

- 用户可以像 IDEA 一样同时开着前端、后端和工作进程，各自停止、各自重跑。
- 每个运行都占用自己的进程和端口，忘了停的服务会一直运行到用户停止或关闭项目。
- 依赖“窗口只有一个执行”的代码（IDE API 的停止、Build 窗口工具栏）改为按执行 ID 或 `latest()` 找目标；以后加控件时要先决定它作用于哪个执行。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/workbench/ -run 'TestRunsOfDifferentKeysRunTogether|TestStartRunReplacesTheRunOfItsKeyOnceItEnded|TestServiceRunShowsRunningAndRestartsInPlace' -count=1`
- `TestServiceRunShowsRunningAndRestartsInPlace` 用合成插件的真实服务进程：运行后状态为“正在运行”，再次运行时旧运行以“已停止”结束后新进程才启动，最后只剩一个运行。

## 适用范围

- `desktop/internal/workbench/build.go`
- `desktop/internal/workbench/runconfig.go`
- `desktop/internal/workbench/runconfig_view.go`
- `desktop/internal/workbench/run_view.go`
- `desktop/internal/workbench/runs.go`
- `desktop/internal/workbench/runconfig_process.go`
- `desktop/internal/workbench/build_connection_debug.go`
- `desktop/internal/workbench/ide_api_dispatch.go`
