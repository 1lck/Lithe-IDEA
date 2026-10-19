# Agent 笔记：通过本机代理观测 Agent 的模型调用

状态：已实现

## 先说结论

ACP（Agent Client Protocol，Lithe 与 Agent 进程之间的协议）只上报整轮用量和上下文占用，没有“每次模型调用”的信息，所以拿不到调用次数、首 token 延迟（TTFT）、输出速度（TPS）和系统提示词/工具定义的占比。Lithe 因此在 Rust Agent Host 里提供一个**可关闭的本机回环代理**：API Key 或 Codex 订阅模式下，Host 把交给 Agent 的服务地址换成 `http://127.0.0.1:<端口>/lithe-<随机令牌>`，代理把请求原样转发到用户配置的真实地址，同时旁路解析请求结构和响应中的 usage，发出 `modelCall` 事件。

对日常开发的直接影响：需要“每次模型调用”的数据时，从 `modelCall` 事件取，不要从 ACP 用量或本地计时去推算；代理只观察、不改写，解析失败只能让统计缺字段，绝不能让转发失败。设置关闭（`settings.agentModelCallStatistics`）时没有这些数据，界面直接不显示，而不是估算。

## 问题

Issue #22 要求像 Claude 客户端那样展示上下文构成（系统提示词、工具定义、对话消息），1lck/Lithe-IDEA#1089 要求展示步骤数、TPS、缓存命中率和首字延迟，并标出非流式响应。

- ACP `usage_update` 只有 `used`/`size`（和可选费用），没有分类。
- ACP `PromptResponse.usage` 是整轮计数，统计口径由 Agent 决定。
- 整轮耗时包含工具执行和等待授权，用它除输出 token 得到的不是生成速度。
- Agent 内部调用了几次模型，ACP 完全不暴露。

这些事实只存在于 Agent 和模型服务商之间的 HTTP 请求里。cc-switch、Sub2API 这类工具正是在这一层用代理拿到的。

## 决策

### 1. 代理归 Rust Agent Host，生命周期等于一次 Agent 连接

- `rust/lithe-agent-host/src/model_proxy.rs`：在 `run_agent` 里、启动 Agent 进程之前，只绑定 `127.0.0.1` 的随机端口；路径前缀带每次启动随机生成的令牌，不带令牌的请求返回 404，避免本机其他进程把它当成开放转发。
- 只替换 `GatewaySignIn.base_url`，因此 Claude（会话选项里的 `ANTHROPIC_BASE_URL`）、Codex 网关登录和自定义 Agent 都走同一条路径；API Key 仍由 Agent 自己放在请求头里，代理只透传，不保存、不记录、不出现在事件里。
- 代理启动失败时保持原地址，Agent 正常启动；统计是可选能力，不能成为连接失败的新原因。
- Codex 订阅模式只在进程级 `CODEX_CONFIG.openai_base_url` 中配置代理推理地址，仍使用原生 OpenAI provider。路径保留 `/backend-api/codex` 后缀，避免破坏原生模型发现和后台能力判断；登录、续期、额度查询及用户的配置文件保持原路由。既有原生中继先检查 account/read 的官方工作区发现结果：只有 https://chatgpt.com 且 NO_CONSTRAINT 才允许观察；地区路由、其他后台、旧版不提供证明或读取失败都清空本机覆盖并保持原生直连。账户或登录状态变更通知立即清除已确认路由和未完成查询，旧响应即使邮箱相同也不能重新授权观察；只有通知后的新查询能确认新工作区。已有观察连接同时关闭，避免旧会话绕过新路由约束。
- 不写任何文件，不碰安装目录，满足运行时只读边界。

### 2. 转发保持透明，观察是旁路

- 只有生成请求的请求体会先读入（最多 32 MiB）以测量结构；超过就放弃测量、把已读部分和剩余部分接起来继续原样转发。其他请求（上传、模型列表等）直接流式透传，不缓冲、不设上限。响应按块流式回传，字节不变。
- 去掉逐跳头（hop-by-hop headers），代理自己不跟随重定向。对被观察的生成请求把 `Accept-Encoding` 改为 `identity`，保证 SSE 中的 usage 可读，内容不变。
- 重定向要改写：Agent 会相对代理地址解析 `Location`，而代理路径比上游多一段令牌前缀，所以 `/v2/responses` 这样的绝对路径和 `../../v2` 这样的相对路径都会逃出代理路由而 404。代理先按**实际上游请求 URL** 解析 `Location`，同源目标在配置路径下就映射回 `/lithe-<token>/...`，在配置路径外就走 `/lithe-<token>/~origin/...`；跨源目标原样交给 Agent 自己的客户端处理，凭据边界与不开代理时相同。
- 3xx 响应是传输跳转，不是一次模型生成：照常转发，但不上报 `modelCall`，也不占用回合等待；只有跟随后的最终响应计入。
- 上游不可达时返回 502，并使用 Anthropic/OpenAI 客户端都能读的 `{"error": {...}}` 外壳；错误文本来自 reqwest，只含 URL 和原因，不含请求头。

### 3. 只解析稳定、公开的字段

`rust/lithe-agent-host/src/model_calls.rs` 按路径后缀识别生成请求（`/messages`、`/responses`、`/chat/completions`），`count_tokens`、模型列表等辅助请求只转发不记录。

- 首 token：Anthropic 的 `content_block_delta`、Responses 任意 `*.delta`、Chat Completions 中带内容/推理/工具调用的 `delta`。
- 用量：Anthropic `message_start` + `message_delta`；Responses `response.completed`；Chat Completions 的 `usage`（含 DeepSeek 的 `prompt_cache_hit_tokens`，以及 OpenAI 兼容协议 `*_tokens_details` 里的 `cached_tokens` 和 `cache_write_tokens`）。统一换算成互不重叠的“未缓存输入 / 缓存读取 / 缓存写入 / 输出”，未缓存输入 = 输入 − 缓存读取 − 缓存写入，并夹在合法范围内。
- 上下文构成：按请求中 `system`/`instructions`、工具定义（`mcp__` 前缀单独归为 MCP 工具）、消息三部分的序列化大小，按服务商返回的输入 token 比例分配（最大余数法，总和精确）；没有用量时按每 4 字节 1 token 估算，并在事件里标明 `scaledToUsage`。
- 任何解析失败只会让对应字段缺失。单行 SSE 或非流式响应超过 32 MiB 时放弃观察，但继续转发。

### 4. 归属会话只认“唯一运行中的 prompt”

HTTP 请求不带 ACP 会话 ID。请求开始时，如果恰好只有一个未在取消中的 prompt，就归给它；否则 `sessionId` 缺省，macOS 直接丢弃，不猜。

代理在响应流结束时才上报调用，可能晚于 prompt 响应。Host 用 `CallsInFlight` 记录已归属但未上报的调用，在发出 `turnFinished` 前最多等 2 秒，保证每轮统计能收到本轮调用；超过这个上限仍未结束的流只计入会话统计，不会拖住回合结束：代理在请求开始时记下会话和 Host 的回合序号（generation），该回合发出 `turnFinished` 后才上报的调用带 `afterTurnFinished: true`，macOS 只把它记入会话，不会记到用户随后开始的下一轮。

### 5. macOS 只聚合、不保存明细

`AgentModelCallTotals` 对会话和每轮做有界聚合（次数、失败数、非流式数、带用量的次数、时长、首 token、生成时间、用量、最近一次主请求构成），会话再长内存也不增长。

- 主请求的识别：Agent 一旦发送过工具定义，就只有带工具的请求更新上下文构成，不带工具的（例如生成标题）视为辅助请求；从不发送工具的 Agent 每次请求都更新，避免构成停在第一次请求。
- 有调用缺少用量（流中断、服务商没给最终 usage）时，Token 合计只是下限，界面显示“≥”并说明缺了几次。

正确：会话卡片的“步”= 观测到的模型调用数；TPS = 流式调用的输出 token ÷（调用时长 − 首 token 时间）。

不要这样做：用整轮耗时除以 ACP 输出 token 得到 “TPS”；把工具调用次数叫作“步”；在没有代理数据时编造系统提示词占比。

### 6. 会话合计跨连接保存，加载历史后继续累加

`session/load` 只重放消息，没有耗时、工具用时和用量，以前重新打开历史会话时统计归零。现在每个会话保存一份累计记录（`AgentSessionStatisticsRecord`：轮次、工具调用数、工具用时、`AgentModelCallTotals` 聚合、最近一次 Agent 上报用量），加载时作为 `AgentConversation.statisticsBaseline`，界面显示“基线 + 本次连接的增量”。

- 写入时机：轮次结束（正常完成、请求失败、断连收尾）以及轮次结束后才到达的迟到调用；运行中的轮次只在结束后计入，记录与上次相同时不重复写。
- 不重复计数：`beginLoad` 本来就会丢弃内存里的轮次和调用重新开始，基线又已包含它们，所以同一会话反复加载不会叠加。保存失败或没有工作区时，退回只统计本次连接。
- 所有权与位置：存储端口 `AgentSessionStatisticsPersisting`（LitheCoreContracts），格式由对话模块拥有；macOS 适配器 `MacAgentSessionStatisticsPersistence` 存进平台偏好 `lithe.agent-statistics.v1.<SHA256(工作区路径+Agent ID)>`，和历史元数据同一处。每个工作区+Agent 一份文档，最多保留最近更新的 200 个会话，最旧的先淘汰；文档损坏时当作空，下次写入覆盖。
- 运行时只读边界：只写用户偏好，不写 app bundle、安装目录或 Agent 自己的文件，不影响代码签名和 Sparkle delta；它是用户状态，不是构建资源，不进 `scripts/worktree-resources.json`。
- 上下文占用：保存最近一次真实 `usage_update` 及确认的模型选项，不把累计计费量当占用。加载完成后只恢复模型一致的报告，界面不加来源后缀，内部仍记录历史来源；回放新报告优先，包括无效/未知报告。运行中的更新随轮次结束保存，空闲时迟到的报告立即保存；模型切换单独清除已保存快照，不提前保存运行中计数。零使用量是有效报告，未上报是未知，旧版记录仍可读取但不能补出占用。
- 不保存：每轮明细（逐轮耗时标签）只属于本次连接，历史回放不编造耗时。Lithe 之外创建、未曾收到并保存实际报告的会话没有本地上下文快照；固定 Codex 适配器可经原生恢复通知补齐，其他 Agent 仍等待自己的上报。该原生兼容路径不经过模型调用代理，也不依赖 API Key。
- Agent 没有提供删除会话的接口，Lithe 只能隐藏，因此记录靠数量上限回收，而不是随删除清理。

### 7. 统计按需展开，复用既有数据

工具窗口和编辑页只在发送按钮旁保留一个“会话详情”入口，点击后通过共享 `litheDropdown` 展示可滚动的上下文构成、会话统计和 Token 明细；输入框顶部不再重复显示信息按钮。收到上下文报告后入口显示用量圆环，未上报时在同一位置显示已有信息图标，避免把未知画成零占用，同时保证已有会话统计仍可访问。悬停保留简洁的用量或未知说明，弹窗标题保留关闭按钮；Esc、外部点击、会话切换或隐藏工具栏均关闭同一个弹窗。宽编辑页可另行显示复用同一内容的右侧详情栏。主界面不再常驻轮次、步数、TPS、Token 和缓存命中长文本；已恢复报告只展示用量数字。`modelCall` 与本地计时的数据口径不变，上下文快照复用第 6 节的存储。

上下文区复用同一个 `AgentContextPanel`：标题与大号一位小数使用率、真实已用/总容量、按窗口容量绘制的多色条，以及系统提示词、工具定义、对话消息、MCP 工具四行图例。工具数保留在对应图例，估算 Token 与估算口径说明可悬停查看；有分项数据后底部不再常驻估算说明和对应分隔线，比例前仍保留“~”。独立弹层的标题提供关闭按钮。MCP 信息并入分项，不再重复一整块启用说明，会话统计继续保留。会话详情移除更改区、Git 分支、工作树变更文件数以及 Agent 编辑文件和行数汇总，避免把整个工作区的修改误当作当前对话的修改；弹窗与右侧详情栏共用这一布局，也不再为详情遍历消息生成文件汇总或观察 Git 模块。文件活动栏和回撤继续由原入口提供，代价是详情面板不再提供更改概览。详情栏的左侧边界显式绘制为 1pt 竖向线；overlay 中的 Divider 没有堆栈方向，默认会画成横穿面板中间的横线，不能用 leading 对齐代替方向设置。会话与 Token 卡片正常的标题分隔继续保留。两张卡片不再常驻显示本机观测和服务商计数来源说明；缺失统计的启用指引、缺失用量的下界提示和 Agent 原生计数口径仍按对应状态显示。只有请求大小而没有窗口容量时，比例显示未知，不能把请求本身归一化为占满窗口；没有分项时显示破折号与一条说明。当前观测没有单独的技能或子智能体分类，不能照截图补造这些数值。

### 8. Codex 订阅 WebSocket 只观察副本，连续请求按完整上下文计算

官方 Codex CLI 0.160.0 的 App Server（原生应用协议服务）通过 `thread/tokenUsage/updated` 提供整轮用量，但没有系统提示词、工具和消息的分类。检查官方仓库 `rust-v0.160.0` 的 `core/src/client.rs`、`model-provider-info/src/lib.rs` 和 `codex-api/src/endpoint/responses_websocket.rs` 后，使用既有服务地址覆盖能力接入本机代理；不接管登录或重写 Codex 的请求和重试逻辑。

原生请求可以通过 WebSocket（持久双向连接）传输，且使用压缩、消息分片和增量上下文。`model_proxy/websocket.rs` 原样转发升级头和后续字节，用成熟的 tungstenite 解析器和 flate2 解压器读取副本。双方的压缩字典生命周期各自遵守协商结果，不重组转发帧，不改变掩码、控制帧或关闭帧。单帧、合并消息和解压结果各限制 32 MiB，超限或协议不认识时仅停止统计，业务转发继续。

`generate=false` 是连接预热，不是一次模型生成，不能计入调用次数。`previous_response_id` 指向当前连接已确认的前序结果时，保留的输入大小加上前序输出和新输入构成完整上下文；instructions 和 tools 按请求继承或替换，不能重复累加。只保存数字大小、最多 256 字节的一个结果 ID 和最多 1024 项输出大小，不保留原文；没有匹配前序 ID 就省略构成，真实 usage 仍照常采集。连接拥有全部升级 socket 和任务，关闭 Agent 连接时一并清理，无新增运行时目录或可复用资源。

正确：连续第二轮只有工具结果增量时，按已确认的前序完整上下文计算四类大小，再用服务商实际输入 token 校准。

不要这样做：把第二轮的工具结果当作全部上下文，或者为了看到分类而禁用原生压缩、改写协议和记录完整请求日志。旧订阅历史只有原生总量时继续显示未知分项，开启统计、重连并产生新请求后才补充真实观察。

## 考虑过的备选方案

1. **只用 ACP 数据和本地计时估算**：改动最小，但调用次数、TTFT 和上下文分类都只能猜，与 issue 的诉求不符，也和“统计口径不清”的维护者意见冲突。保留为代理关闭时的降级展示（只显示 ACP 用量与本地计时的工具用时）。
2. **读取 Claude Code 的会话日志 `~/.claude/projects/*.jsonl`**：能拿到每次调用的用量，但只支持 Claude Code，拿不到系统提示词/工具定义拆分，且依赖私有文件格式。
3. **静默执行 `/context` 命令**：会写入对话历史，输出是给人看的文本，格式不稳定。
4. **用 TLS 中间人或系统代理拦截**：需要安装证书或改系统网络设置，侵入性和安全风险远高于替换 Lithe 自己下发的 base URL，否决。

5. **使用 Codex OpenTelemetry 指标或 rawResponse 通知**：可提供整体 token 和耗时，但没有完整请求结构，无法补齐四类分项。
6. **开启 CODEX_ROLLOUT_TRACE_ROOT 诊断包**：原生可记录完整请求，但会把原始提示词、工具和响应长期写入磁盘，也没有适合常驻产品统计的有界生命周期，因此不采用。
7. **终止并重新建立 WebSocket 或关闭压缩**：可简化观察代码，却改变原生传输和兼容性边界，选择原始字节透传与被动解析副本。

## 后果

收益：

- 调用次数、TTFT、TPS、非流式标记、缓存命中和上下文构成都来自服务商返回的真实数据。
- 三种主流协议共用一套实现，Windows 以后接入时直接消费同一个 `modelCall` 事件。

代价与风险：

- 每次模型请求多一次本机转发；请求体需要先读完才转发（对生成请求影响可忽略，但大附件会有短暂内存占用）。
- 服务商若改动 SSE 事件名或 usage 字段，统计会缺字段，需要更新解析；转发本身不受影响。
- CLI 未来若不再遵守 base URL 或改走未支持的新传输，代理将看不到流量，界面退回“未开启”状态。
- 上游 TLS 由 reqwest + rustls（webpki 根证书）建立，与 Agent 自带的 Node/Rust 网络栈不同：依赖企业自签根证书的网络环境可能需要关闭此开关。
- 上下文构成是按字节比例分配的估算，界面保留“~”标记，估算说明放在分项悬停提示中，不常驻占用面板空间。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-agent-host model_`：压缩/分片与字节级透传、预热不计数、完整/增量上下文、未知前序降级、超限及连接清理；三种协议的 SSE/非流式解析、格式漂移降级、上下文分配、代理透传（含 API Key 头与响应字节不变）、令牌路径隔离、上游不可达，以及会话归属与 `modelCall` 事件形状。
- `./scripts/test-macos.sh --filter "AgentConversationFeatureModelTests|AgentConversationPresentationTests|AgentSessionSelectorLayoutTests|WorkbenchHoverTooltipTests"`：模型调用聚合、未归属事件丢弃、工具与授权用时只计一次、重新加载后按已保存合计继续累加且不重复计数、损坏文档与 200 条上限、ACP 用量的缓存口径判断，以及悬停卡片布局。
- `node --test scripts/test-codex-config-relay.mjs`：订阅路由证明、未知/受限/失败/迟到账户结果不得开启观察，账户变更关闭连接。
- 原生订阅集成测试（显式设置 LITHE_CODEX_OBSERVATION_CLI 后运行忽略测试）：隔离 CODEX_HOME、假凭据、本地假账户与模型服务，经过真实原生中继完成两轮 WebSocket 请求，确认预热排除、用量与上下文构成；不调用真实模型。
- `./scripts/verify-runtime-bundle-immutability.sh`：代理不向安装目录写入任何内容。

## 适用范围

- `rust/lithe-agent-host/src/model_proxy.rs`
- `rust/lithe-agent-host/src/model_proxy/websocket.rs`
- `rust/lithe-agent-host/src/model_proxy/websocket/tests.rs`
- `rust/lithe-agent-host/src/subscription.rs`
- `rust/lithe-agent-host/src/model_calls.rs`
- `rust/lithe-agent-host/src/lib.rs`
- `shared/fixtures/agent/acp-events-v1.json`
- `shared/contracts/rust-core-api.md`
- `macos/Sources/LitheAgentConversationModule/Application/AgentModelCall.swift`
- `macos/Sources/LitheAgentConversationModule/Application/AgentSessionStatistics.swift`
- `macos/Sources/Lithe/Views/Agent/AgentSessionStatusView.swift`
