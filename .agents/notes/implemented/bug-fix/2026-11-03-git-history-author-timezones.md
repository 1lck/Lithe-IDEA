# Agent 笔记：提交历史按绝对时间处理作者时区

状态：已实现

## 先说结论

Git 返回的提交日期是作者当地的墙上时间，必须连同 UTC 偏移还原为一个绝对时间；不能直接把日期字符串当成本机时间。Core 为有效提交提供绝对秒数，桌面端按系统时区展示；按日期筛选时，本地日历边界以绝对秒数传给 Core 比较。

## 问题

宿主如果丢弃 Core 已解析的偏移，同一个提交在另一时区可能显示到错误日期，也可能落入错误的今天或日期范围；按日期字符串做的缓存还会让不同时区的同名时间互相覆盖。

## 决策

- **Core 计算绝对时间。** Core 把 Git 的作者墙上时间和偏移计算为 Unix 秒，同时保留原日期与偏移（`desktop/internal/core/gitlog.go` 的 `DateUnixSeconds` 与 `DateUTCOffsetMinutes`）。异常或未知偏移不伪造绝对时间，此时 `DateUnixSeconds` 为空。
- **展示只用绝对时间。** 桌面端用绝对时间和系统格式展示；缓存的键同时包含时间值与偏移。旧数据没有偏移时，继续按原来的本地解析展示，不对无效的偏移伪造本机时间。
- **筛选逐批比较绝对时间。** `git.historyQuery` 按绝对秒数比较，起始边界包含、结束边界排除。日界由系统日历根据用户时区与当前时间提供，包括夏令时跳变；Core 不以固定 24 小时推导日历日。无偏移的旧记录由平台提供本地解析回退。
- 正确做法是把同一瞬间的 `+0800` 和 `-0700` 记录映射为相同秒数；不要直接比较各自的显示字符串，也不要在每一行同步调用 Core 或按显示文本缓存。

## 考虑过的备选方案

- **只在界面层拼回偏移**：能修显示，但筛选规则仍留在单个平台，也会重复实现日期转换。
- **传当前固定时区偏移并按 24 小时划分日期**：夏令时前后实际日期可能是 23 或 25 小时，会误判边界。
- **在 Core 自行读取系统时区**：会把平台 I/O 放进共享规则；系统日历负责计算边界，Core 只消费明确的绝对值。

## 后果

Core 一次处理最多 4,096 条，平台在后台分批并丢弃过期结果。日期字符串无有效偏移时不能保证跨时区还原，因此只保留兼容回退；筛选失败时保留旧结果并记录日志。日期格式仍由平台和应用语言决定，不改变 Git 历史排序。

## 验证

- Core 仓库的 `rust/crates/core/src/tests/git.rs` 与 [`history-date-query-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/git/history-date-query-v1.json) 夹具：东西时区同一瞬间、边界包含与排除、未知偏移回退、夏令时重复小时。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/workbench/...`：宿主侧的 Git 历史与行历史使用绝对时间。
- `scripts/agent-notes/verify-agent-notes.sh` 和 `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`；系统日期格式的实机验收仍需在 macOS 与 Windows 上确认。

## 适用范围

- `desktop/internal/core/gitlog.go`
- `desktop/internal/core/git_blame.go`
- `desktop/internal/workbench/gitlinehistory_view.go`
- Core 仓库的 [`rust/crates/git/src/history_query.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/git/src/history_query.rs)
