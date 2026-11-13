# Agent 笔记：提交历史按绝对时间处理作者时区

状态：已实现

## 先说结论

Git 返回的提交日期是作者当地的墙上时间，必须连同 UTC 偏移还原为一个绝对时间；不能直接把日期字符串当成本机时间。Core 为有效提交提供绝对秒数，两端按系统时区展示，macOS 筛选把本地日历边界传给 Core 比较。

## 问题

macOS 桥接曾丢弃 Core 已解析的偏移。同一个提交在另一时区可能显示到错误日期，也可能落入错误的今天或日期范围；原生绘制缓存只用日期字符串作键，不同时区的同名时间还会互相覆盖。

## 决策

- Core 将 Git 的作者墙上时间和偏移计算为 Unix 秒，同时保留原日期与偏移；异常或未知偏移不伪造绝对时间。macOS 的历史首页、分页、单提交和 Windows 的首页、分页都携带该值。
- 平台只用绝对时间和系统格式展示；macOS 缓存同时包含时间值与偏移。旧数据没有偏移时继续按原来的本地解析展示，不对无效的已知偏移伪造本机时间。
- `git.historyQuery` 逐批比较绝对时间，起始边界包含、结束边界排除。平台系统日历根据用户时区与当前时间提供真实的日界，包括夏令时跳变；Core 不以固定 24 小时推导日历日。无偏移的旧记录由平台提供本地解析回退。
- 正确做法是将同一瞬间的 `+0800` 和 `-0700` 记录映射为相同秒数；不要直接比较各自显示字符串，也不要在每一行同步调用 Core 或按显示文本缓存。

## 考虑过的备选方案

- 只在 Swift 拼回偏移：能修显示，但筛选规则仍留在单个平台，也会重复实现日期转换。
- 传当前固定时区偏移并按 24 小时划分日期：夏令时前后实际日期可能是 23 或 25 小时，会误判边界。
- 在 Core 自行读取系统时区：会把平台 I/O 放进共享规则；系统日历负责计算边界，Core 只消费明确的绝对值。

## 后果

Core 一次处理最多 4,096 条，macOS 在后台分批并丢弃过期结果。日期字符串无有效偏移时不能保证跨时区还原，因此只保留兼容回退；筛选失败保留旧结果并记录目录事件。日期格式仍由平台和应用语言决定，不改变 Git 历史排序。

## 验证

- `rust/lithe-core/src/tests/git.rs` 与 `Lithe-core-rust/rust/fixtures/git/history-date-query-v1.json`：东西时区同一瞬间、边界包含/排除、未知偏移回退、夏令时重复小时。
- ~~`macos/Tests/LitheTests/GitStatusObservationTests.swift`~~（已随 #1794 移除）、`GitLogDatePresetTests.swift` 与 `GitGraphInteractionTests.swift`：真实 Git 时间、功能模型筛选、23/25 小时日和缓存身份。
- ~~`windows/tauri/src/platform/core-result-adapter.history.test.ts`~~（已随 #1794 移除） 与 `windows/tauri/src/features/git/utils/git-log-date.test.ts`：历史首页、分页及日期显示使用 Core 的绝对时间。
- ~~./scripts/rust-core/verify-rust-core.sh~~（随旧客户端移除）、~~./scripts/architecture/verify-shared-contracts.sh~~（随旧客户端移除）、`./scripts/agent-notes/verify-agent-notes.sh` 和 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`；原生工作台与 Windows 系统格式实机验收仍 pending。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/history_query.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/history_query.rs)
- ~~`macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Views/Git/GitGraphView.swift`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/git/utils/git-log-date.ts`~~（已随 #1794 移除）
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
