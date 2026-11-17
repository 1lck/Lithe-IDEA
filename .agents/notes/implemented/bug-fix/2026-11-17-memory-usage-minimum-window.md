# Agent 笔记：内存详情的 CPU/GPU 占用至少按 1 秒计算

状态：已实现

## 先说结论

状态栏内存详情的 CPU 和 GPU 占用率，是两次读取进程表之间累计时间的差除以间隔。以前只要间隔大于 0 就计算，刚打开详情时两次读取只差几十毫秒，主进程 CPU 会显示到 160% 以上，几秒后才恢复。现在由 Core 的 `processMemory.summarize` 保证：相隔不足 1 秒的两张表不做比较。宿主照常把上次返回的基线原样发回，不需要自己判断间隔。

## 问题

打开详情时，工作台立即读一次进程表（读数 A）。插件名称在后台读完后，会再清空采样时间，紧接着读第二次（读数 B）。A 和 B 只差几十毫秒，这段时间里主要是面板打开和读取本身的开销（每次读取约 3 ms 单核 CPU）。Core 用 B 减 A 的累计时间除以几十毫秒，得出的就是瞬时峰值，而不是持续占用。GPU 也一样：打开详情后才开始读取 GPU，第二次读取就出现约 28% 的瞬时值。

## 决策

规则放在 Core，因为两个平台的宿主共用同一份计算：

- 常量 `MIN_USAGE_WINDOW` 为 1,000,000 微秒。
- 读数距上一个基线至少 1 秒：按基线计算，并开始新基线；新基线把上一个基线的计数（`sampledAt` 和 `processes`）带在 `earlier` 字段里。
- 读数距基线不足 1 秒：改用基线的 `earlier` 计算，`earlier` 也必须早于读数至少 1 秒，否则不给占用率；返回的基线原样不变，下一次读数仍和同一组计数比较。
- 读数早于基线（时钟回退）：不给占用率，重新开始一个不带 `earlier` 的基线。

宿主（`desktop/internal/core/process_memory.go`）的 `MemoryBaseline` 增加 `Earlier` 字段，只负责原样传回；工作台的采样节奏和名称读取不变。

正确做法：宿主把 `summary.Baseline` 原样作为下一次的 `Previous`。

不要这样做：宿主自己比较两次读取的时间、丢弃间隔短的读数，或把多次结果合并。这样两个平台会各写一份规则，以后容易不一致。

## 考虑过的备选方案

- 只在工作台里去掉名称读完后的那次重读。可以避开这一次峰值，但任何让两次读取靠得很近的新路径（例如以后加的手动刷新）都会再次出问题，规则也没有落到 Core。
- 间隔不足 1 秒时只返回空占用率，不带 `earlier`。实现更简单，但面板里的 CPU/GPU 列会在打开时消失再出现，界面闪动。
- 宿主保存上一次的有效结果，读数过近时继续显示旧值。需要宿主合并数据，不同平台各写一份，违背通用逻辑进 Core 的规则。

## 后果

- 打开详情时 CPU 不再出现瞬时高值；关闭状态下每 10 秒一次的读数留下的基线，让打开那一刻的 CPU 直接按至少 1 秒的窗口计算。
- GPU 只在详情打开时读取，所以要等打开后至少 1 秒的下一次采样才有数值，比以前晚一点出现。
- 基线多带一组计数，请求和响应的体积大约翻倍；进程数量在几十到几百之间，影响可以忽略。
- `earlier` 是可选字段，契约 fixture 的 `schemaVersion` 保持 1。

## 验证

- `cargo test -p lithe-process --lib memory::`：在 Lithe-core-rust 的 `rust/` 下运行，回归测试 `a_table_read_too_soon_after_the_baseline_keeps_it_and_has_no_percentages` 在修复前得到 100%，修复后通过；共享 fixture 的新增用例覆盖按 `earlier` 计算和没有 `earlier` 两种情况。
- `./scripts/desktop/desktop-go.sh test ./internal/core -run TestProcessMemorySummarizeFollowsTheContractFixture`：宿主经链接的 Core 回放共享 fixture，请求里的 `earlier` 能原样编码。
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run TestMemoryDetailsShowTheSummaryOfTheWholeInstance`：工作台把返回的基线原样发回。

## 适用范围

- Lithe-core-rust 的 `rust/crates/process/src/memory.rs`、`rust/contracts/rust-core-api.md`、`rust/fixtures/process-lifecycle/memory-summary-v1.json`
- `desktop/internal/core/process_memory.go`
- `desktop/internal/workbench/memory_monitor.go`
- `shared/platform-feature-matrix/features/memory-monitor.json`
