# Agent 笔记：运行进程不受准备阶段的时限约束

状态：已实现

## 先说结论

工作台启动一个运行（构建插件准备的运行，或命令型运行）时，以前把整段后台任务放在 30 分钟的请求时限（`buildRequestTimeout`）下，进程也用这个上下文启动。`buildprocess.Start` 在上下文结束时会杀掉进程，所以 Spring Boot 这类常驻服务运行满 30 分钟就被结束。现在只有“准备”阶段受时限约束（`runPreparationTimeout`），进程本身一直运行到自己退出、用户停止或项目关闭。以后新增启动长时间进程的路径，进程不能用带时限的上下文启动。

## 问题

`a.background(p, timeout, work)` 给 `work` 的上下文带着 `timeout`。运行路径在同一个 `work` 里先做准备（Core 计划、解析工具、请求构建插件的 `lithe/build/prepareRun`），再用同一个上下文调用 `buildprocess.Start`。准备需要时限，防止插件或工具卡住时永远等下去；进程不需要，它的结束由用户的停止、项目关闭或进程自己决定。两者共用一个上下文，进程就继承了本该只给准备用的 30 分钟。

调试会把这个问题放大：断点停住时服务看起来空闲，用户调试半小时左右，服务和调试会话会一起消失，没有任何提示原因。

## 决策

- 运行路径（`runBuildTargetWith`、`runBuildEntry`）的后台任务不再带时限，上下文仍然在项目关闭时结束。
- 在任务内部用 `context.WithTimeout(ctx, runPreparationTimeout)` 派生出准备阶段的上下文，再交给 `op.bind`（用户停止时也结束）。计划、工具解析和构建插件请求都用这个上下文。
- `buildprocess.Start` 和等待调试端口用不带时限的上下文。

正确做法：

```go
a.background(p, 0, func(ctx context.Context) func(*App) {
	bounded, cancel := context.WithTimeout(ctx, runPreparationTimeout)
	defer cancel()
	prepare, release := op.bind(bounded)
	defer release()
	// 用 prepare 做准备；用 ctx 启动进程
})
```

不要这样做：`a.background(p, buildRequestTimeout, ...)` 里直接 `buildprocess.Start(ctx, ...)` 启动用户会长期运行的进程。

## 考虑过的备选方案

- 把 `buildRequestTimeout` 调大（例如 24 小时）。服务仍然会在某个时刻被无故结束，只是更难发现；准备阶段的保护也随之失效。
- 进程用 `context.Background()` 启动。项目关闭时进程不再随上下文结束，只能依赖其他清理路径，容易留下孤儿进程。
- 构建任务（`runBuildTask`）也一起改。任务是有终点的构建，30 分钟时限能防止卡死的构建一直占着唯一的操作位；这次没有改，任务时限是否合适另行判断。

## 后果

- 常驻服务和调试中的服务可以一直运行；停止仍然走 `stopBuildOperation`，项目关闭仍然结束进程。
- 准备阶段的时限变成包级变量 `runPreparationTimeout`（默认仍是 30 分钟），测试可以缩短它。
- 进程的生命周期不再有兜底时限：一个忘了停的服务会一直占用资源，直到用户停止或关闭项目，这和 IDEA 的行为一致。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/workbench/ -run TestServiceRunOutlivesItsPreparationBound -count=1`：把准备时限缩短到 5 秒，服务运行 6 秒后写出标记文件。修复前服务在第 5 秒被结束（`signal: killed`），修复后通过。

## 适用范围

- `desktop/internal/workbench/build.go`
- `desktop/internal/workbench/build_connection_debug_test.go`
