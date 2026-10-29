# Agent 笔记：macOS 编辑区 Agent 对话的大历史加载与 Claude Desktop 式布局

状态：已实现

## 先说结论

打开一个很大的历史对话，慢的不是上游 Agent，而是 Lithe 自己：回放每来一条消息就把整份对话复制一遍并通知界面，随后又一次性排版全部消息。现在回放期间的消息先放进不对外发布的缓冲区，回放结束时只发布一次；对话视图只构建最近 48 项，更早的内容点“显示更早的 N 项”再展开。同时，编辑区（对话作为编辑器标签打开时）的界面向 Claude Desktop 靠拢：历史列表有置顶与日期分组和“…”菜单，输入框变成圆角卡片，审批模式和模型移到卡片下方的状态行，右侧详情栏改成可折叠分区并新增“更改”。右侧工具窗口里的 Agent 样式不变。

## 问题

用户反馈大历史对话打开很慢，期望无论多大都在 2 秒内加载完成。先量化了每一段的耗时：

- 上游：直接对 Claude ACP 发 `session/load`，43 MB 的会话约 1 秒回放完；它只重放最近一段上下文，回放事件只有几百条。上游不是瓶颈。
- Lithe 接收：`AgentConnectionModel.conversations` 是 `@Published` 字典。对它做 `conversations[id]?.x = …` 会先整体读出、修改、再整体写回，数组写时复制，所以每个回放事件都复制已有的全部消息，总成本随历史长度平方增长。调试构建下 10 800 个事件耗时 27 秒。
- Lithe 排版：回放结束后 `LazyVStack` 仍要为底部跟随估算整个文档高度，300 轮的历史首次排版 12 秒，1 200 轮 31 秒。

## 决策

- 回放走专用缓冲区：`loadSession` 期间的 `append`/`upsertTool` 写入 `replayMessages` 和 `replayToolIndex`（普通存储属性，原地修改，工具更新 O(1)），`sessionLoaded` 时一次 `commitReplay` 发布。连接中断且没有旧副本时提交已收到的部分（与以前一致，仍不标记为完整历史）；加载失败且有旧副本时丢弃缓冲区并恢复旧副本。子 Agent 状态更新要改消息时直接作用于缓冲区。没有活动回合时不再调用 `refreshTurnClock`，因为它同样会触发整体复制。
- 对话视图窗口化：`AgentTranscriptWindow` 规定初始 48 项、每次展开 96 项。搜索时不窗口化；导航栏点到窗口之外的回合时先扩大窗口再滚动；展开更早内容后把滚动位置保持在原来的第一项。
- 历史列表一次计算快照（排序和筛选原来每次渲染重复约 8 次），按“收藏 → 今天 → 昨天 → 过去 7 天 → 过去 30 天 → 更早 → 时间未知”分组；筛选或搜索时不分组。每行用 Agent 图标磁贴、标题、消息数与会话 ID（保留复制）、相对时间和“…”菜单（收藏、重命名、导出、复制会话 ID、移出历史/恢复）。选择、归档、已移除筛选、导出等原有能力全部保留。
- 编辑区对话 UI：用户消息用中性灰圆角气泡；输入框改 16pt 圆角带轻阴影，卡片内只留“添加”和“发送”，审批模式在状态行左侧、模型在右侧，之后是订阅额度和上下文环。详情栏的上下文、更改、会话统计三个分区可单独折叠，状态保存在 `lithe.agent.editor.detailsCollapsed`；标题栏新增详情栏开关按钮，原菜单项保留。“更改”来自对话中的文件编辑记录，只显示已有数据。
- 历史列表滚动与刷新：页面观察整个 `AgentConnectionModel`，流式输出每几十毫秒发布一次。`AgentHistoryRowsCache` 分三层记忆：排序结果（会话、标注、搜索、筛选不变就不重排，O(n log n) 只在必要时执行）、行数据（当前会话、已加载对话的消息条数、分钟数不变就复用）、版本号（列表 `==` 只比较版本号，O(1)）。时间戳解析、本地化 `.lproj` 查找、`DateFormatter` 都做了缓存；`canExport` 改为打开菜单时对该行计算；行高固定为 56pt；行菜单只在悬停或当前行时挂载原生锚点。
- 编辑区右侧详情栏改为 `AgentEditorDetailsColumn`：每个分区一张圆角卡片，标题后有 ▾ 可折叠；上下文卡显示已用百分比、容量、彩色进度条和"彩色方块 + 名称 + token + 占比"图例（无分解数据时显示"—"）；更改卡显示总增删行数和文件列表（文件名 + 所在目录），超过 5 个折叠到"显示更多"。工具窗口输入框打开的会话详情弹窗仍是原来的 `AgentEditorDetailsPanel`，样式不变。
- 编辑区输入卡片左侧是 Agent、审批模式、模型，右侧是额度圆环（订阅时）与上下文圆环；回车发送，文件用拖入、粘贴或 @，回复进行中才显示停止按钮。上下文圆环始终显示，未上报时为空圈。审批模式的本地化规则见共享 Agent 对话 Note。
- 详情栏负责任务、子代理和文件审查。详情栏被关闭或编辑区宽度不足以放下它时，输入框上方恢复显示活动摘要，避免这些入口消失。
- Claude 订阅额度：Claude Code 在回复过程中产生 `rate_limit_event`，适配器以 `usage_update._meta["_claude/rateLimit"]` 转发，每条只描述一个窗口（`five_hour`、`seven_day`、`seven_day_opus`、`seven_day_sonnet`，`utilization` 为 0–1 比例，`resetsAt` 为 Unix 秒）。`AgentSubscriptionQuota` 按窗口类型累积，来源标为 `claude`：快照在窗口重置前一直有效（Codex 的“超过 2 分钟视为过期”只适用于主动轮询），悬停卡片显示“截至某时刻，仅在回复时更新”。不调用 Anthropic 接口、不轮询；overage 和未知窗口不显示。
- 这些改动只作用于 `isEditorLayout`；工具窗口的 Agent 面板（CC GUI 样式）没有改变。

## 考虑过的备选方案

- 本地缓存转录快照，再次打开时先显示缓存：能把二次打开压到几十毫秒，但会让 Lithe 在磁盘上持有一份 Agent 对话内容，并需要失效策略。实测上游只要约 1 秒，Lithe 侧修复后总耗时不到 1 秒，所以没有引入。如果以后上游回放变慢，再单独评估。
- 把回放解析移到后台线程：事件很少时收益不大，而且需要把 `[String: Any]` 越过 actor 边界；平方复制消除后主线程的接收成本已经可以忽略。
- 对话视图改成真正的虚拟列表：改动面太大，会牵动底部跟随、导航锚点和文本选择；窗口化用最小代价把首次排版量与历史长度脱钩。
- 在历史列表里加“固定”之外的新概念（置顶）：Lithe 已有“收藏”，沿用收藏并把它显示在列表最前，避免两个相似概念。

## 后果

- 调试构建下，1 200 轮（10 800 个事件）的接收从 27 秒降到约 0.45 秒，首次排版从 31 秒降到约 0.3 秒；加上上游约 1 秒，仍在 2 秒内。
- 代价：窗口之外的旧消息不会在首屏构建，滚到最顶部需要点一次“显示更早的 N 项”。回放期间看不到逐步出现的消息（原来也是等回放结束才显示）。
- “消息数”只对已加载过的会话显示；Claude Desktop 的“N 条消息”需要上游列表提供计数，目前没有。
- “分叉会话”和“归档会话”没有对应的上游能力，菜单里不放占位项。

## 验证

- 历史滚动基准（200 条会话，程序化逐帧滚动，调试构建）：纯滚动 p95 从 8.6ms 降到 1.4ms；流式输出期间刷新 p50 从 14ms（25% 帧超过 16.7ms）降到 1.7ms（0 掉帧）；标题变化 p95 从 34ms 降到 10ms。排序与分组在 200 / 2,000 / 20,000 条会话下每行成本分别为 14.9 / 5.5 / 4.2µs，确认没有平方级路径。

- `AgentLargeHistoryLoadTests`：1 200 轮回放整体只发布少量次数、顺序和工具合并正确；中断保留部分回放但不标记完整；失败恢复旧副本；窗口扩大规则；历史分组。
- `./scripts/macos/test/test-macos.sh --filter AgentHistoryTests`、`AgentConversationSelectionTests`、`AgentTranscriptScrollTests`、`ContextMenuCoverageTests` 等 Agent 相关套件。
- 对 Claude ACP 的 `session/load` 探测方法：直接起 `claude-agent-acp`，发 `initialize` 与 `session/load`，统计事件数量和耗时。

## 适用范围

- `macos/Sources/LitheAgentConversationModule/Application/AgentConnectionModel.swift`
- `macos/Sources/Lithe/Views/Agent/AgentTranscriptView.swift`
- `macos/Sources/Lithe/Views/Agent/AgentHistoryView.swift`
- `macos/Sources/Lithe/Views/Agent/AgentComposerView.swift`
- `macos/Sources/Lithe/Views/Agent/AgentEditorConversationChrome.swift`

Windows 的编辑区对话仍使用自己的布局，见 [Windows Agent 对话在编辑区标签与工具窗口之间的放置](2026-10-18-windows-agent-conversation-editor-placement.md)。
