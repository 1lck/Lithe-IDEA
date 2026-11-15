# Agent 笔记：应用级日志窗口与诊断导出

状态：已实现

> Viva 迁移状态：当前桌面端已有日志存储（`desktop/internal/logstore/`）、独立日志窗口（`desktop/internal/logwindow/`）、Core 查询和导出接线；语言服务器日志入口尚未接入，旧平台的事件目录与使用检查尚无完整等价门禁（[#1802](https://github.com/1lck/Lithe-IDEA/issues/1802)）。旧平台的实现细节和验收记录不能直接当作 Viva 验收。

## 先说结论

Viva 桌面端的应用日志只在一个地方看：独立的日志窗口，所有项目共用。窗口读取磁盘上已经由 Core 脱敏的 v2 日志，以及写入器的实时广播。过滤语法、重复折叠、事件分布、调用链和复制格式都由 Rust Core 计算，桌面端只负责读文件、订阅和画界面。导出与窗口使用同一套 Core 查询，导出的永远是脱敏版。

## 问题

1. 查看日志的入口如果有多个、证据来源不同，用户就无法回答“我导出的是不是我看到的”。
2. 用户看到错误提示后，找不到对应的那条日志。只读的文本时间线不能跟随新日志，不能定位，也不能把同一次操作的记录串起来。
3. 如果在界面层实现过滤和折叠，之后迁移或另一个界面再写一遍，两端的过滤结果会不一致。

## 决策

### 一个窗口，一个打开请求

日志窗口属于应用，不属于某个项目。所有入口都发出同一个打开请求（可带通道前缀、过滤表达式和一条记录引用）：菜单中的“日志与诊断”、可改键的命令、应用内提示上的“查看日志”，以及导出诊断包的入口（打开窗口后直接弹出导出对话框）。窗口已经打开时，请求只套用过滤条件并把窗口提到前面，不会再开一个窗口。

### 设置里没有日志页

日志与诊断是独立界面，不和设置共用。窗口工具栏的“⋯”菜单提供日志目录（可以更改或恢复默认目录，只在用户确认后写回）和“清理日志…”（显示占用大小，并要求确认）。导出只有窗口里这一个对话框。

### 记录引用

记录引用由通道、事件名和可选的 op（操作 ID）组成，不用 seq（写入器分配的序号）。原因是显示提示时这条记录可能还在写入队列里，seq 还没分配。窗口按引用定位到匹配的最新一条记录。提示和日志在同一个处理边界产生，提示携带由生成事件类型给出的引用；日志里不复制本地化的提示正文。

不要这样做：在提示里手写事件名或通道字符串；在提示里保存 seq。

### Core 计算，宿主只做 I/O

日志窗口和导出需要的通用逻辑全部在 Core 的诊断模块（Core 仓库的 `rust/lithe-core/src/diagnostics/`）中：

| 能力 | Core 入口 |
| --- | --- |
| 过滤表达式解析、错误位置、加词项 | `queryLogsV2` 的 `expression`、`diagnostics.parseLogFilter`、`diagnostics.composeLogFilter` |
| 重复记录折叠 | 每条记录的 `foldKey` 和响应里的 `foldMinimumRun` |
| 事件分布条 | `histogramBuckets` 与 `histogram` |
| 调用链 | 带 `op` 查询时的 `opSummary` 和每条记录的 `opOffsetMs` |
| 通道侧栏的计数 | 不受过滤影响的 `channels` |
| 复制为 JSON / Markdown | `diagnostics.formatLogRecords` |
| 导出范围和大小估计 | `planLogCollection` 的 `recentSessions`、`since`、`estimatedBytes`、`sessions` |
| 导出清单 | `diagnostics.buildManifest` 的 `redaction: "core-v2"` |

界面只负责读取日志文件尾部、订阅实时批次、调用 Core、按 `foldKey` 相等把相邻行分组，以及画界面。

不要这样做：在界面代码里解析 `level>=warn`、拼 JSON 或判断两条记录是否重复。

### 过滤语法和日志内容不翻译

窗口的按钮、提示、占位符和无障碍标签走共享 i18n。级别名（DEBUG/INFO/WARN/ERROR）、日志消息、事件名、通道名、字段名和值、过滤语法、复制出来的 JSON 都不翻译。这些是证据和技术格式：翻译后会和磁盘文件、Issue 里贴的内容对不上，过滤语法也会因语言不同而失效。

### 浏览与实时跟随

窗口内存里最多保留 20000 行，超出丢弃最旧的。实时跟随消费写入器已经编码好的广播，每个批次只调用一次 Core 查询、只发布一次状态，不会因为滚动重新读取全部日志。用户向上滚动时自动暂停跟随，并显示新日志的条数。

“清空显示”只记住当前最后一条记录的 seq，之后只显示更新的记录，绝不删除磁盘文件。删除磁盘日志只在“清理日志…”里做，而且必须先确认。

序号只在所属会话内递增，清空水位必须按会话保存。Core 返回每个已读取会话在过滤前的最大序号，并在历史查询和实时批次中使用同一份水位；不能把上一会话的高序号当成当前会话的门槛。水位只属于当前窗口生命周期，不写进偏好或书签。清空时同时废弃在途查询，避免旧结果恢复已清空的行。

时间框选对历史查询和实时批次都生效。导出“当前过滤结果”时，窗口时间范围与导出范围在 Core 按真实时间取交集；交集为空就导出空证据，不扩大范围。从应用的错误提示打开引用时，显式选择当前会话并清除旧过滤和水位，保证用户能够定位刚发生的失败。

实时查询或订阅失败后，窗口停止显示正在跟随，记录一次失败并提供显式“重试”；不自动循环重连。旧订阅的迟到结果由独立的订阅版本拒绝，关闭窗口仍取消全部任务。

### 隐私：只有脱敏版

磁盘上只存 Core 脱敏后的日志，所以窗口和导出都不可能显示原文，导出对话框也没有“包含原文”的选项。`manifest.json` 记录 `redaction: core-v2`，让读包的人知道用的是哪一版脱敏规则。Core 的脱敏占位符是 `<redacted>`，窗口灰色显示、不可点击。

导出范围包含多个会话时，附带本应用在所选时间内的崩溃报告。崩溃报告不经过日志写入器，所以导出前逐份经过 Core 的 `diagnostics.redactText` 脱敏，并限制份数和大小。导出只写到用户在保存面板里选的位置，从不自动上传。

导出对话框打开时冻结日志窗口当前的通道前缀、级别集合和过滤表达式。所有文件在用户确认之前就完成收集和脱敏，确认后不再读取日志源，所以确认的内容就是写进压缩包的内容。

### 警告和错误必须进日志

日志窗口只有在“出了问题就一定有记录”时才有用。显示给用户的警告和错误、功能降级、回退、自动恢复、重试耗尽和被丢弃的错误，都必须在处理边界记录一条目录事件。

批量操作汇总记录：批量清理只累计失败次数和第一个错误类别，结束时发一条 WARN，不逐个文件刷屏。临时文件尚未创建或已被删除时的“不存在”属于预期的缺失。

只记稳定字段：Git 历史和远程清理的错误只保留固定消息、稳定的 code/domain 和受控阶段，不复制 stderr、对端正文、路径或地址。

写入器自己的失败（打开、写入、关闭句柄失败）不能再写日志，否则会递归。写入器把这些失败计入计数器，导出时写进 `collection-status.txt` 的 `write_failures`。

## 考虑过的备选方案

- 保留两套浏览入口：来源和生命周期继续不同，无法回答“导出的是否就是看到的”。
- 设置里保留一个只放日志目录、保留与清理和详细诊断开关的“日志存储”页：日志功能又会分散在两个地方。窗口工具栏的“⋯”菜单已经能放下这几项。
- 在界面层实现过滤、折叠和复制格式：开发更快，但之后迁移或新界面要重写，两端行为会漂移。
- 提示里保存 seq 定位记录：显示提示时记录可能还没写盘，seq 未分配；改用通道、事件和 op 组成的引用。
- 导出提供“包含原文”选项：磁盘上根本没有原文。要支持就得另存一份未脱敏日志，扩大隐私面。
- 每个事件单独调用 Core、每次打开文件：实现简单，但跨语言调用和磁盘开销随日志量线性增长；选择按批查询和读取尾部。

## 后果

收益：应用日志只有一个查看入口，看到的、复制的和导出的是同一份脱敏证据；错误提示可以一键跳到对应记录；过滤和折叠在 Core 里，有 fixture 覆盖，新界面可以复用。

代价：Core 的诊断 API 变大，每个新字段都要同步契约、fixture 和界面调用。实时跟随每个批次都要调用一次 Core 查询；高吞吐下的成本还需要整机测量，如果不可接受，应扩展 Core 的增量摘要接口，而不是在界面里复制统计规则。

## Viva 实现写法

日志窗口用 `ui.NewPage` 和 `func (w *window) view(c ui.C)` 声明，不持有窗口级的按键、滚动和指针分发。

- 记录表是 `ui.List`：只声明可见行，多选和键盘导航由列表给出，表头是单独一行并用 `ScrollWith` 跟随。列表按记录的稳定 key（`Model.keyBase` 加下标，永不复用）持有选中状态，Model 的 `selection`（按记录 id）仍是详情和复制读取的真源。
- 日志查询是页面的 `ui.Effect`，以 `Model.queryKey` 为 key：新的过滤条件取消上一次查询，清屏只让在途结果过期、不重新查询。实时订阅是推送流，仍走 Model 的邮箱（`post`、`drain`），在 `OnWake` 里应用。
- 菜单、时间范围编辑器、确认框和导出面板分别用 `ui.Menu`、`ui.Popover`、`ui.Modal`；详情的上下分隔用 `ui.Splitter`。直方图是 `ui.Control` 加 `Draw`，调用链是第二个 `ui.List`。
- 详情 JSON 所在区域是 `ui.Scroll(...).Sideways().Scrollbars()`，长行横向滚动并显示滚动条。
- 被放弃的做法：把表头做成 `ListState.Header` 的第 0 行（记录下标整体错位，选择和 key 要处处减一）；把整个查询邮箱改成 Effect（实时流没有“一个 key 一个结果”的形状）。

## 验证

真实应用的整机验收（Java 项目、失败的 Git fetch、中英文、深浅色、长列表滚动）没有完成前保持 pending：

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/logstore ./internal/logwindow`（`page_test.go` 用无头驱动覆盖选择、键盘、菜单、导出面板、直方图和查询取消；`bench_test.go` 量表格滚动与按键的耗时和分配）
- `scripts/desktop/desktop-go.sh --exec go run github.com/vivaui/viva/cmd/viva vet ./internal/logwindow/...`
- `scripts/desktop/desktop-go.sh test -race ./internal/logwindow ./internal/workbench -run 'Test(Log|Welcome)'`
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`
- 旧版日志生成、使用检查和共享契约检查已移除；等价门禁恢复前不能记作通过。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/diagnostics/](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/diagnostics)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/diagnostics/logging-v2.json`
- `desktop/internal/logstore/`
- `desktop/internal/logwindow/`
- `desktop/internal/core/logging.go`
