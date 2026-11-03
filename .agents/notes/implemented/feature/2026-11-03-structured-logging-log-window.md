# Agent 笔记：应用级日志窗口与诊断导出

状态：已实现

## 先说结论

macOS 只保留一个看日志的地方：用 ⌘⇧L 打开的独立日志窗口，所有项目共用。窗口读取磁盘上已经由 Core 脱敏的 v2 日志，以及写入器的实时广播。过滤语法、重复折叠、事件分布、调用链和复制格式都由 Rust Core 计算，SwiftUI 只负责读文件、订阅和画表格。导出对话框和窗口使用同一套 Core 查询，导出的永远是脱敏版。语言服务的日志编辑器标签页、100 条内存日志和设置页里的日志时间线已经删除。Windows 仍然使用 v1 日志，没有迁移。

## 问题

改造前有三个问题：

1. 查看日志的入口有两个，证据来源也不同。设置页的时间线读磁盘，语言服务的日志标签页读一份 100 条的内存缓冲。用户无法回答“我导出的是不是我看到的”。
2. 用户看到错误提示后，找不到对应的那条日志。设置页时间线只是一个 180pt 高的文本框，不能跟随新日志，不能定位，也不能把同一次操作的记录串起来。
3. 如果在 Swift 里实现过滤和折叠，Windows 迁移时要用 TypeScript 再写一遍，两端的过滤结果会不一致。

## 决策

### 一个窗口，一个打开请求

日志窗口属于应用，不属于某个项目。所有入口都发出同一个 `LogWindowOpenRequest`（打开请求，可带通道前缀、过滤表达式和一条记录引用）：

- 工具栏齿轮菜单的“日志…”，位于“插件…”和“主题…”之间，前后各一条分隔线；
- 菜单栏的“日志”菜单项；
- 可改键的命令 `show-logs`，默认 ⌘⇧L；
- 语言服务状态里的“查看日志”；
- 设置页的“打开日志窗口”；
- 应用内提示上的“查看日志”。

窗口已经打开时，请求只套用过滤条件并把窗口提到前面，不会再开一个窗口。

记录引用 `LogRecordReference` 由通道、事件名和可选的 op（操作 ID）组成，不用 seq（写入器分配的序号）。原因是显示提示时这条记录可能还在写入队列里，seq 还没分配。窗口按引用定位到匹配的最新一条记录。

正确做法：提示和日志在同一个处理边界产生，提示携带由生成事件类型给出的引用。

不要这样做：为某个插件写专门的打开方法；在提示里手写事件名或通道字符串；在提示里保存 seq。

### Core 计算，宿主只做 I/O

日志窗口和导出需要的通用逻辑全部在 `rust/lithe-core/src/diagnostics/`：

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

这样做的原因：Windows 迁移时可以直接复用；行为可以用共享 fixture 测试；正则表达式的长度和内存上限只需要在一处保证。

Swift 只负责读日志文件尾部、订阅 `MacLogStore` 的实时批次、调用 Core、按 `foldKey` 相等把相邻行分组，以及画界面。

不要这样做：在 Swift 里解析 `level>=warn`、拼 JSON 或判断两条记录是否重复。

### 过滤语法和日志内容不翻译

窗口的按钮、提示、占位符和无障碍标签走共享 i18n。级别名（DEBUG/INFO/WARN/ERROR）、日志消息、事件名、通道名、字段名和值、过滤语法、复制出来的 JSON 都不翻译。这些是证据和技术格式：翻译后会和磁盘文件、Issue 里贴的内容对不上，过滤语法也会因语言不同而失效。

### 浏览与实时跟随

表格是用 `NSViewRepresentable` 包装的 view-based `NSTableView`：固定行高、复用单元格，每行的显示内容在进入模型时算一次。窗口内存里最多保留 20000 行，超出丢弃最旧的。仓库里没有现成的 SwiftUI 表格封装，`NSTableView` 直接提供列宽调整、列隐藏和固定行高复用。

实时跟随消费写入器已经编码好的广播，每个批次只调用一次 Core 查询、只发布一次状态，不会因为滚动重新读取全部日志。用户向上滚动时自动暂停跟随，并显示新日志的条数。

“清空显示”只记住当前最后一条记录的 seq，之后只显示更新的记录，绝不删除磁盘文件。删除磁盘日志只在设置页的“清理”里做。

### 隐私：只有脱敏版

磁盘上只存 Core 脱敏后的日志，所以窗口和导出都不可能显示原文，导出对话框也没有“包含原文”的选项。`manifest.json` 记录 `redaction: core-v2`，让读包的人知道用的是哪一版脱敏规则。

导出范围包含多个会话时，附带本应用在所选时间内的崩溃报告。崩溃报告不经过日志写入器，所以导出前逐份经过 Core `diagnostics.redactText` 脱敏，并限制份数和大小。导出只写到用户在保存面板里选的位置，从不自动上传。

### 快捷键选 ⌘⇧L

⌘L 已经是“跳到行”。原提案里的 ⌥⌘L 是 IntelliJ 系列默认的“格式化代码”，从 IDEA 迁移过来的用户会误触。命令可以在快捷键设置里改键。

### 警告和错误必须进日志

日志窗口只有在“出了问题就一定有记录”时才有用。所以显示给用户的警告和错误、功能降级、回退、自动恢复、重试耗尽和被丢弃的错误，都必须在处理边界记录一条目录事件。具体规则写在 `develop-lithe` Skill 的日志参考页里。

`scripts/logging/verify-log-usage.mjs` 把其中能静态发现的部分变成门禁：丢弃结果的 `try?`、只退出不记录的 `catch`、生产代码里的 `print`、Rust 里丢弃结果的 `.ok();` 和 `let _ =`。确属例外时在同一行或上一行写 `// log-exempt: <原因>`，原因必须属于封闭的四类例外。存量写在 `scripts/logging/log-usage-baseline.json`，数量只能减少：超过基线失败，低于基线也失败并要求更新基线，防止基线变成新违规的额度。

只在界面显示、没有日志的警告无法静态发现，靠 Skill 规则和评审清单把关。

## 考虑过的备选方案

- 保留编辑器标签页和设置页时间线两套浏览：来源和生命周期继续不同，无法回答“导出的是否就是看到的”。
- 在 Swift 里实现过滤、折叠和复制格式：开发更快，但 Windows 迁移要重写，两端行为会漂移。
- 提示里保存 seq 定位记录：显示提示时记录可能还没写盘，seq 未分配；改用通道、事件和 op 组成的引用。
- 导出提供“包含原文”选项：磁盘上根本没有原文。要支持就得另存一份未脱敏日志，扩大隐私面。
- 每个事件单独调用 Core、每次打开文件：实现简单，但跨语言调用和磁盘开销随日志量线性增长；选择按批查询和读取尾部。
- 两端一次迁移：扩大验证范围并阻塞 macOS；Windows 保留 v1 兼容，以后单独迁移。

## 后果

收益：用户只有一个查看入口，看到的、复制的和导出的是同一份脱敏证据；错误提示可以一键跳到对应记录；过滤和折叠在 Core 里，有 fixture 覆盖，Windows 可以复用。

代价：Core 的诊断 API 变大，每个新字段都要同步契约、fixture 和 Swift 桥接。实时跟随每个批次都要调用一次 Core 查询。日志用法门禁的基线需要随修改持续减少，修改一个函数时要顺手处理它里面被标记的旧写法。

## 验证

以下是复验入口；真实应用的整机验收（Java 项目、失败的 Git fetch、中英文、深浅色、长列表滚动）记录在平台功能矩阵中，没有完成前保持 pending：

- `node scripts/logging/generate-log-events.mjs --check`
- `node scripts/logging/verify-log-usage.mjs`
- `node --test --test-timeout=60000 scripts/logging/test-log-events.mjs`
- `cargo test --manifest-path rust/lithe-core/Cargo.toml diagnostics`
- `./scripts/macos/test/test-macos.sh --filter DiagnosticsWorkflowTests`
- `./scripts/macos/probe/probe-macos-logging-ui.sh --skip-build`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/windows/verify/verify-windows-boundaries.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `rust/lithe-core/src/diagnostics/`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/diagnostics/logging-v2.json`
- `scripts/logging/`
- `macos/Sources/Lithe/Views/Diagnostics/`
- `macos/Sources/Lithe/Services/Diagnostics/`
- `macos/Sources/Lithe/Platform/MacOS/Logging/`
- `macos/Sources/LitheModuleAPI/Logging/`
