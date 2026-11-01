# Agent 笔记：思考摘要的消息边界与标题正文呈现

状态：已实现

## 先说结论

Codex 思考摘要不是普通回复。Lithe 必须保留上游消息身份，并将 Codex 的活动标题和 Markdown 正文作为不同的呈现内容处理，不能把几十个 `**标题**` 直接交给一般段落渲染器。Claude 和其他 Agent 的思考仍按原始 Markdown 正文显示，不套用 Codex 标题语义。
实时输出和历史回放使用同一个思考呈现模型；当前已完成的标题用于思考状态，工具、权限、重连和停止仍优先。原始文本、重复标题、消息顺序及用户历史文件保持不变。

## 问题

ACP（编辑器与 Agent 之间的对话协议）的 `messageId` 标识一条消息的所有流式片段。Rust SDK 已保留这个字段，但原 macOS 缓冲与追加、Windows 追加只按角色合并；不同思考消息、普通回复和子代理输出都可能错误粘连。

另一个独立缺口在固定 `codex-acp 2.2.2` 的 `createReasoningUpdates`：历史回放逐项发送原生 `summary` 或 `content`，没有段落分隔。检查 `v2.5.0` 后确认仍如此，单独升级不能修复；实时 `summaryPartAdded` 与完整消息完成路径已有分隔，不能向每个增量片段盲目插入换行。

用户第二张截图还暴露了呈现语义缺失。只读核对对应 Codex 0.166.0、`custom-gateway` 原生记录，首次快照的 94 条思考消息均只有一个摘要项，其中 74 条包含连续的 `****`；会话当时仍在增长，不能当作最终总量。这证明单靠 `messageId` 不够，但不能证明原始数据损坏，也不能定位为供应商、网关或 CLI 错误。一个字符串仍可表达多个活动标题。原始会话和供应商配置不进入仓库。

## 决策

### 依据公开 Codex 的职责划分，而不是修改通用 Markdown

核对 [官方 App Server 协议](https://developers.openai.com/codex/app-server)：`summaryTextDelta.summaryIndex` 标识摘要段，`summaryPartAdded` 显式标记分段，`item/completed` 提供权威完整项。ACP 已把明确分段转换为文本空行时，客户端应保留；不重新定义原生协议。

核对与用户 CLI 一致的公开 `rust-v0.166.0`，标签对象 `593389380740f7b4762771573c447ccfdc59742f`，以及固定 revision `231c8abd2f4f7e3e14aa3e54bcf8136435e6f2f3` 的以下入口：

- `codex-rs/tui/src/chatwidget/streaming.rs`：思考状态与正文独立；未闭合加粗标题不替换可用标题，工具与授权等状态优先；原生分段有单独生命周期。
- `codex-rs/tui/src/history_cell/messages.rs`：`ReasoningSummaryCell` 与 `split_reasoning_summary_parts` 区分活动标题和正文，展开的思考使用专门呈现，不等同普通回复。
- `codex-rs/tui/src/chatwidget/tests/reasoning_status_tests.rs`：分别验证实时与回放、分片标题、工具后恢复以及迟到事件。

这些公开源码可复核客户端职责，但不是桌面 Codex 私有界面的实现证据。桌面界面读取被工具安全边界拒绝，未绕过限制，不逆向安装包，也不把 CLI 行为声称为桌面逐像素对照。Lithe 保留自己的现有披露交互与原始内容；不照搬 CLI 特有的摘要省略或占位符删除策略。

### 接收层保留消息身份

macOS 和 Windows 使用独立 `upstreamMessageID`，不替换本地行 ID。缓冲和追加都要求角色、上游 ID 与子代理所有者一致；没有 ID 的连续片段沿用旧行为。已知与未知身份切换时分开，避免未知文字归入已知消息。

现有 Codex 兼容入口只对带 `thread.turns[].items[]` 的响应，将思考的多个字符串项用空行合成一个。实时事件、工具、普通回复、加密内容和磁盘历史不变。兼容固定适配器 2.2.2；升级时复验，上游回放保留分段后移除此补偿。

### 呈现层独立处理标题和正文

两端思考解析都返回有序 `Section`，包含可选标题、原样 Markdown 正文和标题是否闭合。段落开头的普通 `**标题**` 作为标题；紧接的多个标题也各自成节。标题由原生 Text/React 文本节点呈现，正文继续走已有 Markdown owner，不把标题重新拼为 Markdown，也不修改消息存储。

正确示例：`**检查分组****选择键值**\n读取 **README**。` 呈现两个标题，最后一个标题下保留加粗正文；重复标题不去重。不要这样做：删除所有 `****`、按英文大小写猜步骤，或把普通回复也送进摘要解析。

未闭合的流式标题可以作为当前节的草稿显示，但不能替换状态栏最后一个已完成标题；非流式未闭合文本保持正文。代码围栏、缩进代码、行内代码、链接、实体和转义不解释为活动标题。当前标题只在已有思考状态显示，不覆盖授权、重连、停止、工具或普通回复；内容按上游原文显示，不走产品翻译。

主过程区、独立思考行和子代理复用同一标题/正文视图。搜索、复制、导出和统计仍基于原始消息；不把当前标题当新消息，不新增轮次、工具、计划或子代理。

### Claude 不启用 Codex 标题规则

本机固定 `claude-agent-acp 0.95.0` 的 `acp-agent.js` 把 `thinking`/`thinking_delta` 原文转为 `agent_thought_chunk`，通过 `applyMessageId` 保留消息身份；它没有声明 Codex 活动摘要语义。因此仅所属连接的 Agent ID 为 `codex-acp` 时，在消息内存模型记录 `usesThoughtSummaryHeadings`。实时、历史、主会话和子代理都保留该选择，默认 false；Claude 的加粗开头仍是行内 Markdown，不变成独立标题，也不替换通用思考状态。连接身份决定规则，不按文本、模型名或供应商地址猜。

消息 ID 的通用合并修复仍适用于 Claude；Codex 临时 relay 不在 Claude 启动路径内。测试把同一组正文和每个共享样例以关闭标题模式再解析，断言正文逐字节不变；两端连接回归覆盖 Codex/Claude 与实时/历史的四种组合，React 断言 Claude 加粗保持在正文且没有活动标题节点。这不等于执行了新的 Claude 模型请求。

## 考虑过的备选方案

- 只删除星号或对整段插入空行：前者丢格式，后者仍混淆标题与正文；第一轮的纯标题串补偿已被独立呈现模型替代。
- 只修 `messageId` 或升级适配器：无法解释同一摘要字符串内的多个标题，不能作为完整修复。
- 从原生记录粘连推断上游损坏：没有端到端事件证据，否决该结论。
- 修改安装的适配器、用户历史或观测代理：破坏来源、更新边界或逐字节转发，不采用。
- 原样复制 CLI 的全部显示策略：CLI 有自己的状态与折叠需求，不等于桌面要求；只复用公开的职责边界，Lithe 仍完整保留可见内容。

## 后果

标题不再堆成普通段落，实时与历史使用相同节模型；流式标题分片不会让状态栏露出星号，正文格式仍由原有 Markdown 实现负责。有歧义的文字保留正文，不能承诺任意格式都能恢复作者意图；摘要解析属于明确的思考呈现规则，不声称恢复缺失事件。

不新增下载、缓存或资源目录。现有 helper 所有者、临时位置和进程树清理不变；呈现只在内存执行，不写 macOS bundle 或 Windows 安装目录，不影响签名和 Sparkle delta。

## 验证

- `node --test --test-timeout=10000 scripts/agent/test-codex-config-relay.mjs`：两种认证下结构化历史分段及实时事件不变。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AgentConversationFeatureModelTests|AgentMarkdownTests|AgentThoughtTranscriptTests|AgentConversationPresentationTests|AgentLargeHistoryLoadTests'`：消息身份、长历史、节模型、每个流式前缀及状态优先级，逐项记录计时。
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs -- src/features/agent/services/agent-thought-presentation.test.ts src/features/agent/components/agent-transcript.process.test.tsx`：同一 fixture 和真实 React 呈现，断言标题为独立文本、正文保留 Markdown、工具状态不被覆盖。
- `LITHE_THOUGHT_REPLAY_PATH` 显式提供本机原生历史时，`AgentThoughtTranscriptTests.nativeHistoryRendersDistinctTitlesAndBodiesWithoutChangingSource` 读取真实最长摘要，在 360/720pt 深浅主题渲染，验证源文件字节不变；`LITHE_THOUGHT_SCREENSHOTS` 可输出本地检查图片。默认不依赖个人历史，图片与原文不提交。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`：两平台发行目录只读扫描。受控组件与只读历史验收不是新的模型调用或 Windows 实机验收，平台矩阵保持 pending。

2026-11-02 本地结果：174 项 Swift 计时测试、103 项前端计时测试和 21 项 relay 测试通过。真实历史只读渲染的最长摘要有 22 个标题；已人工查看浅色 360pt 与深色 720pt 图片，顺序正确且无粘连。最终该项约 0.16 秒；流式前缀回归约 0.001 秒，React 标题/正文及状态回归约 0.023 秒。Swift 使用指定 6.3.3 与已有 macOS 26.5 SDK，未改项目工具链；全量 TypeScript 检查仍只有两处既有 `diff` 声明缺失，无新增错误。没有执行新模型请求、Windows 实机或桌面 Codex 直接 UI 对照。

提交前 Claude 隔离复验：174 项 Swift（消息边界用例现含 Codex/Claude 与实时/历史四组合，约 9 毫秒）及 106 项前端测试通过，Claude 加粗正文 UI 回归约 3 毫秒。直接导入本机安装的 `claude-agent-acp 0.95.0`，调用其纯 `toAcpNotifications` 转换并断言思考原文和 `messageId` 保留；没有启动 Claude CLI、创建会话或访问模型服务。默认关闭标题规则的共享样例与子代理路径也已通过；不把这些回归声称为真实 Claude 模型端到端验收。

## 适用范围

- `macos/Sources/LitheAgentConversationModule/Application/AgentConnectionModel.swift`
- `macos/Sources/LitheAgentConversationModule/Application/AgentThoughtPresentation.swift`
- `macos/Sources/Lithe/Views/Agent/AgentSessionGuidanceViews.swift`
- `macos/Sources/Lithe/Views/Agent/AgentProcessGroupView.swift`
- `rust/lithe-agent-host/src/codex-config-relay.cjs`
- `windows/tauri/src/features/agent/`
- `shared/fixtures/agent/thought-presentation-v1.json`
