# Agent 笔记：对话中的图片缩略图、放大查看与后台任务通知

状态：已实现

## 先说结论

工具读取或截取图片时，对应的工具行（以及整组工具的标题行）右侧显示缩略图：
最多三张，其余用 `+N` 表示，悬停出大图预览，点击进入统一的放大查看器。用户消息里附带的图片也用同一套缩略图和查看器。
Claude Code 发出的 `<task-notification>` 不再原样显示为用户气泡，而是一行状态文字。
图片数据只在内存中以受限大小保存，原图由视图层按需异步解码。

## 问题

ACP（Agent Client Protocol，Agent 与客户端之间的协议）的工具结果可以携带 `image` 内容块，
但原先解析时只保留了类型名，图片本身被丢弃，用户看不到 Agent 读到的截图。
用户发送的图片附件只以 `📎 路径` 文字出现，无法预览。Claude Code 的后台任务完成通知是协议标记，
却被当成用户输入显示。

## 决策

- `AgentToolDetails.images` 与 `AgentConversationMessage.images` 保存 `AgentImage`。内联图片解码后
  不超过 10 MB、每条消息最多 24 张，超限直接丢弃，不进入会话状态。
  `AgentImage` 按内容指纹（SHA-256，硬件加速）或路径判等，转录行的相等比较不会去比较像素。
  同一条消息、同一组工具里 id 相同的图片用 `uniquedByID` 去重，`ForEach` 和查看器翻页都要求 id 唯一。
  内联数据必须能被 ImageIO 识别，否则不生成缩略图，工具输出里对应条目退回文字显示。
- 只提供文件路径的 `read` 工具调用（例如读取 `.png`）直接显示该文件，且文件必须存在。其他类型的工具不会因为位置是图片就当作“查看”。
- 一次更新如果没有图片，不会清掉之前已收到的图片，避免最终状态更新把缩略图抹掉。
- 缩略图在视图层用 ImageIO 在后台线程按需生成并放入 `NSCache`（限制总像素成本和数量，文件缓存键含修改时间，行滚出后解码任务随之取消，解码失败显示占位图标）；历史回放只保存数据，不解码。
  悬停预览复用 `workbenchHoverCard`，放大查看器是转录区域上的覆盖层，状态放在
  `AgentImageViewerState`，行只持有引用，打开或关闭不会重绘全部行。
- 放大查看器仍是转录区域上的覆盖层，在其上补充捏合缩放（相对适应窗口 25%–800%）、拖动、双击、
  百分比和 ⌘+/⌘−/⌘0，拖动范围限制在画面边缘内；←/→ 翻页只在查看器持有焦点时生效，不抢输入框的光标键；侧栏很窄时可放大查看。曾试过改用独立窗口复用编辑器的 `MediaViewerView`，
  因为偏离了既有交互而放弃。
- 折叠的“思考过程”标题行也显示图片缩略图，否则默认折叠时用户看不到工具返回的图片。
- 用户消息里的 `[@名字](file:///路径)`、裸 `file://` 地址、`📎 路径` 和 Claude Code 的
  `[Image: source: …]` 指向图片文件时显示为缩略图；`[Image: original …]` 尺寸说明丢弃。缩略图按引用在原文中的位置排序；超过 24 张的引用从文字中移除并显示 `+N`。
  用户消息的解析结果按消息缓存，悬停和流式刷新不会重复扫描全文。
- Claude Code 写进用户消息的特殊格式由 `AgentClaudeCodeMarkup` 识别：斜杠命令、本地命令输出、
  Shell 转义、中断提示、压缩续接摘要、技能展开和宿主上下文显示为状态行或折叠块；
  `<system-reminder>`、`<local-command-caveat>` 等只给模型看的块只在消息开头或结尾时移除（Claude Code 就是加在那里），
  夹在用户文字中间的同名标签原样保留。只有整条消息都是这些标记时才整体替换，用户自己输入的相似文字不会被吞掉。
  格式清单来自对本机真实会话的标记名称统计，新增格式在这里补充。
- `<task-notification>` 只有在整条用户消息完全由通知块组成时才解析，用户自己输入的相同文字不会被吞掉。
  这是协议标记的呈现，不按 Agent 名称在宿主里分支。

### 后台任务通知并入后续过程

后台命令的完成通知会唤醒 Agent 再跑一轮。连续几次后台命令会让对话里反复出现“通知行 + 思考过程”。
现在成功的通知（`AgentTranscriptItem.isQuietNotification`）不单独成行，而是进入随后一轮的折叠过程区，展开后按原顺序显示。
失败、被终止的通知，以及后面没有任何思考或工具的通知，仍作为状态行保留，避免用户错过。
Claude Code 为 shell 任务生成的英文摘要（`Background command "…" completed (exit code 0)`）按界面语言显示。

### 恢复会话时补全压缩前的历史

Claude Agent SDK 的 `getSessionMessages` 只返回当前 parent 链；压缩边界（`compact_boundary`）没有 parent，
因此适配器回放从最后一个边界开始，更早的记录虽然还在 `<配置目录>/projects/*/<会话 id>.jsonl`，却不会到达客户端，
对话里看起来像“前文丢了”。Rust 宿主（`claude_earlier_history.rs`）在 `session/load` 之前只读取该文件中最后一个边界之前的行，
转成与回放一致的 ACP 更新（用户、回复、思考、工具调用和结果），先于适配器的回放发出，
所以每次压缩的摘要也会在原位置显示为“对话已从摘要继续”。

这是对“宿主不读取转录文件”约定的有限例外，边界如下：

- 只读，只打开 `projects/*/<会话 id>.jsonl`；账号目录里的登录信息和其他文件不触碰；会话 id 只接受字母、数字、`-`、`_`。
- 配置目录按所选 Claude 账号解析（账号目录、`CLAUDE_CONFIG_DIR`、`~/.claude`），不写入任何文件，不缓存。
- 超过 128 MiB 的记录文件不读取；最多发出 30000 条更新；工具输入输出每段截断到 4000 字符；子代理侧链和 `isMeta` 行跳过，图片不回放。
- 文件格式由 Claude Code 拥有。解析失败或格式变化时只是不显示更早的历史，不影响适配器自身的回放。
- Codex 的历史仍由其官方 App Server 提供，不受此例外影响。

不要这样做：不要把前文合并进适配器已回放的片段，也不要改写或重新压缩 Claude 自己的记录文件。

任务进行中排队发送的提示（含后台任务通知）在记录文件里只存成 `attachment` 行（`queued_command`），
没有对应的用户行，所以前文转换把它当作用户消息回放，并用该行的 `uuid` 区分相邻消息。

### 兼容 Claude Desktop 开始的会话

Claude Desktop 给 Claude Code 挂了自己的 `ccd_turn` MCP 服务，模型在那里几乎不直接输出文字，
而是用 `mcp__ccd_turn__wrap_up` 工具交出每轮的总结（`recap`）和提问（`ask`），由 Desktop 渲染成卡片。
在 Lithe 里恢复这类会话时，整段对话只剩折叠的工具调用，看起来像历史没有回放。

宿主（`claude_desktop.rs`）把 `wrap_up` 的工具调用改写成一条 Agent 回复（总结与提问各一段），
并吞掉该调用后续的 `tool_call_update`；建议回复按钮不显示，因为用户点过的那条会作为下一条用户消息出现。
改写同时作用于适配器的回放和上面的前文转换，Windows 共用同一宿主。Lithe 自己不提供 `ccd_turn` 工具，
所以只影响从 Desktop 带过来的历史。

`update_plan` 有整表（`items`）和增量（`done`/`start`/`advance`）两种写法。宿主按会话记住当前列表，
把每次调用改写成一条完整的 ACP `plan` 更新；增量调用之前没有整表时原样保留为工具调用。
Swift 在加载历史期间把每份计划快照记成一条不带文字的 Agent 消息，转录里在两段折叠过程之间显示成清单，
导出 Markdown 时写成任务列表，不计入消息数。折叠的过程标题后面附上工具摘要（如“运行了 3 条命令”），
没有文字回复的段落也能看出做了什么。

不要这样做：不要在 Swift 或 Windows 前端按工具名再做一份改写，也不要读取或模拟 Desktop 的 MCP 服务。

### 不要这样做

- 不要把图片 `Data` 放进 `Equatable` 的逐字节比较，也不要在主线程解码原图。
- 不要为放大查看另起一套弹窗样式或使用 `.popover`；悬停预览与查看器共用本 Note 中的入口。

## 考虑过的备选方案

### 把图片写到缓存目录再引用路径

好处是内存占用更小。但应用层不能直接做文件系统写入，需要新增平台存储适配；在单张和总量都有上限的前提下，
先在内存中保留，需要时再评估。

### 保留“复制”按钮并在工具行内渲染

issue #1462 指出的多余复制按钮来自不属于最终回复的过程文字。#1464 已把这类文字收进默认折叠的过程区，
空白回复也不再生成行，因此本次没有再改动复制按钮的显示规则。

## 后果

- 收益：Agent 看过的图片可以直接在对话里确认；用户附件可点击放大。
- 代价：长会话里的内联图片占用内存，最坏情况每条消息 24 × 10 MB。
- 需要重新评估：出现明显内存压力，或需要 Windows 端对齐时。

## 验证

- `./scripts/test-macos.sh --filter AgentImageTests`
- `cargo test -p lithe-agent-host claude_earlier_history`
- `cargo test -p lithe-agent-host claude_desktop`
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `macos/Sources/LitheAgentConversationModule/Application/AgentImage.swift`
- `macos/Sources/Lithe/Views/Agent/AgentImageViews.swift`
- `macos/Sources/Lithe/Views/Agent/AgentToolGroupView.swift`
- `rust/lithe-agent-host/src/claude_earlier_history.rs`
