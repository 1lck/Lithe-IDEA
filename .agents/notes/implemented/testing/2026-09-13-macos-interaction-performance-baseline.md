# Agent 笔记：macOS 交互性能基线

状态：已实现

## 问题

编辑器输入、分栏拖动、全局搜索、终端和运行输出等交互容易受到主线程
重绘、进程通信和后台任务调度影响。没有固定的场景、输入规模和统计口径，
性能回归只能依赖主观感受，难以比较不同提交或判断优化是否真实有效。

## 决策

Lithe 使用固定的 macOS 交互性能基线验证性能回归，不改变产品默认行为。
基线覆盖连续输入、打开大文件后空闲、多个分栏拖动、冷/暖启动的
Search Everywhere、终端输出和 Run/Tests 输出。

每个场景使用固定的 fixture 规模；需要重复运行的场景运行三次，并记录
常驻内存和交互事件的 count、p50、p95、max。交互事件使用
`LITHE_PERF_SIGNPOST` 写入捕获的进程日志，统一观察
`editor.input`、`appmodel.relay`、`split.drag` 和
`search.everywhere`。

性能基线模式关闭 `FrameRateMonitor`，避免每个 vsync 调度的 MainActor
任务污染交互测量。Instruments 可以用于系统级卡顿分析，但不能作为应用
交互基线唯一的数据来源。

## 考虑过的备选方案

### 只依靠人工体验

成本低、反馈直观，但无法稳定复现，也不能比较不同提交的变化，因此不作为
性能回归的主要依据。

### 只使用 Instruments 报告

适合深入定位系统级卡顿，但采集和导出成本高，难以作为每次性能验证的统一
入口，因此保留为补充工具。

### 只记录平均值

实现简单，但会掩盖长尾卡顿和偶发资源峰值，因此同时记录 p50、p95 和 max。

## 后果

- 性能结果有固定输入和统计口径，可以在不同提交之间比较。
- 交互日志能够关联具体事件，便于定位输入、分栏和搜索链路的回归。
- 基线验证成本低于完整 Instruments 分析，适合在性能改动后重复运行。
- 代价是需要维护固定 fixture、场景和 signpost 名称；修改测量脚本时必须
  同步检查历史结果的可比性。
- 基线不替代真实设备上的双架构、系统级卡顿和长时间稳定性验证。

## 验证

- `scripts/measure-macos-performance-baseline.sh --list`
- `scripts/measure-macos-performance-baseline.sh --scenario T --fixture 500KiB --runs 3`
- `./scripts/test-macos.sh`

具体场景、fixture 和交互操作步骤见
[`docs/performance/macos-interaction-baseline.md`](../../../../docs/performance/macos-interaction-baseline.md)。

## 适用范围

- `scripts/measure-macos-performance-baseline.sh`
- `docs/performance/macos-interaction-baseline.md`
- `macos/Sources/`
- `macos/Tests/`
