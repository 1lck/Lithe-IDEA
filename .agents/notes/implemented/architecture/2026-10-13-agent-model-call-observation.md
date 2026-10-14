# Agent 笔记：通过本机代理观测 Agent 的模型调用

状态：已实现

## 先说结论

ACP（Agent Client Protocol，Lithe 与 Agent 进程之间的协议）只上报整轮用量和上下文占用，没有“每次模型调用”的信息，所以拿不到调用次数、首 token 延迟（TTFT）、输出速度（TPS）和系统提示词/工具定义的占比。Lithe 因此在 Rust Agent Host 里提供一个**可关闭的本机回环代理**：API Key 模式下，Host 把交给 Agent 的服务地址换成 `http://127.0.0.1:<端口>/lithe-<随机令牌>`，代理把请求原样转发到用户配置的真实地址，同时旁路解析请求结构和响应中的 usage，发出 `modelCall` 事件。

对日常开发的直接影响：需要“每次模型调用”的数据时，从 `modelCall` 事件取，不要从 ACP 用量或本地计时去推算；代理只观察、不改写，解析失败只能让统计缺字段，绝不能让转发失败。设置关闭（`settings.agentModelCallStatistics`）或订阅登录时没有这些数据，界面直接不显示，而不是估算。

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
- 订阅模式（Codex ChatGPT 登录）没有 Lithe 可替换的网关地址，不经过代理。
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

## 考虑过的备选方案

1. **只用 ACP 数据和本地计时估算**：改动最小，但调用次数、TTFT 和上下文分类都只能猜，与 issue 的诉求不符，也和“统计口径不清”的维护者意见冲突。保留为代理关闭时的降级展示（只显示 ACP 用量与本地计时的工具用时）。
2. **读取 Claude Code 的会话日志 `~/.claude/projects/*.jsonl`**：能拿到每次调用的用量，但只支持 Claude Code，拿不到系统提示词/工具定义拆分，且依赖私有文件格式。
3. **静默执行 `/context` 命令**：会写入对话历史，输出是给人看的文本，格式不稳定。
4. **用 TLS 中间人或系统代理拦截**：需要安装证书或改系统网络设置，侵入性和安全风险远高于替换 Lithe 自己下发的 base URL，否决。

## 后果

收益：

- 调用次数、TTFT、TPS、非流式标记、缓存命中和上下文构成都来自服务商返回的真实数据。
- 三种主流协议共用一套实现，Windows 以后接入时直接消费同一个 `modelCall` 事件。

代价与风险：

- 每次模型请求多一次本机转发；请求体需要先读完才转发（对生成请求影响可忽略，但大附件会有短暂内存占用）。
- 服务商若改动 SSE 事件名或 usage 字段，统计会缺字段，需要更新解析；转发本身不受影响。
- CLI 未来若不再遵守 base URL 或改走 WebSocket 等新传输，代理将看不到流量，界面退回“未开启”状态。
- 上游 TLS 由 reqwest + rustls（webpki 根证书）建立，与 Agent 自带的 Node/Rust 网络栈不同：依赖企业自签根证书的网络环境可能需要关闭此开关。
- 上下文构成是按字节比例分配的估算，界面必须标注“~”和估算说明。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-agent-host model_`：三种协议的 SSE/非流式解析、格式漂移降级、上下文分配、代理透传（含 API Key 头与响应字节不变）、令牌路径隔离、上游不可达，以及会话归属与 `modelCall` 事件形状。
- `./scripts/test-macos.sh --filter "AgentConversationFeatureModelTests|AgentConversationPresentationTests|WorkbenchHoverTooltipTests"`：模型调用聚合、未归属事件丢弃、工具与授权用时只计一次、ACP 用量的缓存口径判断，以及悬停卡片布局。
- `./scripts/verify-runtime-bundle-immutability.sh`：代理不向安装目录写入任何内容。

## 适用范围

- `rust/lithe-agent-host/src/model_proxy.rs`
- `rust/lithe-agent-host/src/model_calls.rs`
- `rust/lithe-agent-host/src/lib.rs`
- `shared/fixtures/agent/acp-events-v1.json`
- `shared/contracts/rust-core-api.md`
- `macos/Sources/LitheAgentConversationModule/Application/AgentModelCall.swift`
- `macos/Sources/LitheAgentConversationModule/Application/AgentSessionStatistics.swift`
- `macos/Sources/Lithe/Views/Agent/AgentSessionStatusView.swift`
