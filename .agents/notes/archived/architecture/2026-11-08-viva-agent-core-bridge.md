# Agent 笔记：Viva 的 ACP Core 连接桥与最小会话面板

状态：已实现
归档日期：2026-11-12

## 归档原因

2026-11-12 用户决定 Viva 桌面端不做 Agent 对话，#1799 删除了本文描述的助手面板、Core ACP 连接桥（`desktop/internal/core/agent*.go`）、适配器安装和历史恢复。provider 发现和凭据定位器的规则保留下来，现在只供 AI 提交信息与行内编辑使用，见[Viva 桌面端不做 Agent 对话，只保留 AI 生成](../../implemented/feature/2026-11-12-viva-agent-conversation-removed.md)。Rust Core 的 Agent 宿主暂留。

## 先说结论

Viva 通过 Rust Core 的 C ABI 创建 ACP 连接、发送原始契约命令并接收事件，也可读取 Core 检测到的运行时和 Agent 管理状态。2026-11-09 起，工作台的 AI Assistant 面板接通了最小会话纵向切片：从本机 Codex/Claude 配置发现已有 provider、启动 Core 管理的 ACP 适配器、发送文本、增量显示回复、停止轮次、显示错误，并要求用户真实点选权限选项。

同日补齐了当前项目的会话历史列出/恢复、新建会话、按适配器声明的 select 选项选择模型/思考程度/权限模式，以及登录要求与连接丢失的准确呈现。历史由 Agent 拥有：Go 只转发 `listSessions`/`loadSession`，显示 Core 回放的事件，不读写适配器自己的 transcript 文件。

Agent 协议、进程树、会话生命周期和 provider 配置解析仍由 Core 负责；Go 只做类型化桥接、平台文件/环境读取和呈现。收藏/重命名/归档/导出历史、订阅登录、下一轮配置预选、CLI 安装与更新、附件、远程/MCP、计划/工具/用量展示和完整供应商管理仍不在本切片内。

## 问题

Core 桥已经存在，但 Viva 没有用户入口：助手工具窗口只有占位。若在 Go 里另写 ACP 或 provider 解析，会复制 Core 的状态机和协议；若在应用启动时预启动 Agent，不用这个功能的用户也要承担进程和内存开销；权限请求如果自动放行，Agent 可以在用户不知情时执行工具。

Viva 还没有自己的 AI provider 设置存储。用户已有的 provider 只存在于本机 Codex/Claude CLI 配置中，因此必须读取真实配置，不能显示虚构的默认 provider，也不能把密钥写入普通设置或日志。

## 决策

- **适配器安装是显式用户动作。** 面板打开时只调用 `agent.status` 和 `ai.configuration.*`，绝不自动安装。未安装的适配器只在用户点击 Install 后调用 Core 的 `agent.install`；进度、取消、失败重试和成功后的状态重读都走同一个 Core 桥。安装目录只用 Viva 自己的 `Application Support/Lithe Desktop/agents`，不读、不写旧版 `Lithe` 或 Tauri 目录。
- **面板按需启动，跟着项目走。** AI Assistant 工具窗口第一次被绘制时才读取适配器状态和本机 provider；用户选择 provider 并点“开始对话”后才调用 `lithe_agent_open_json`。每个项目持有自己的 `agentState` 和连接；隐藏面板不结束会话，关闭项目、切换项目或关闭窗口时关闭连接并清理进程树。没有项目时不启动任何 Agent。
- **provider 发现复用 Core 的配置解析，按 Core 声明的协议匹配 Agent。** `agent.status` 决定哪些适配器实际安装；`ai.configuration.sources` 决定平台要读哪些本机文件；`ai.configuration.parse` 返回不含密钥的 provider 元数据和凭据定位器。provider 是否属于当前 Agent 由 `AgentCatalogStatus.Protocol` 与 `AIConfigurationProvider.APIProtocol` 的 Core 值匹配，不按 `codex-acp`/`claude-acp` 名称写分支。Go 只按定位器读取同一份文件文本或进程环境，并把 `baseUrl`、`apiProtocol`、`model` 和内存中的 API Key 放进启动 JSON。凭据不写设置、不写日志、不放进错误信息。Codex `config.toml` 的内联 `experimental_bearer_token` 需要 TOML 路径解析，本切片明确报“无法读取”，不为了这一条路径新增第二份配置解析器。Core 的 API Key 启动路径无条件要求非空 Key，即使 provider 元数据声明 `requiresApiKey: false`；因此没有凭据的 provider 会被标为 MissingKey 并在界面解释，而不是永久静默禁用 Start。
- **Go 不实现 ACP。** 连接、`newSession`、`prompt`、`cancel`、`permission` 命令和 `ready`、`sessionCreated`、`update`、`permission`、`turnFinished`、`requestFailed`、`stopped` 事件都按 `shared/fixtures/agent/acp-events-v1.json` 的固定形状转发。未知的增量事件忽略，不根据 Agent 名称或文本猜语义。核对固定 Core 后确认没有可复用的“已规范化 Agent 事件”命令：`lithe_agent_send_json` 是唯一 Agent 命令入口，`runtime/ffi.rs` 直接把 `lithe_agent_host::AgentEvent` 序列化成 JSON 回调；事件形状由 fixture 和契约固定。因此 Go 只解码这些契约字段，不新增按工具名分支。
- **权限必须由用户确认。** 收到 `permission` 后只显示上游工具标题和上游选项；不预设默认选项、不自动发送 `permission`、不在取消或超时时替用户放行。用户点选后发送 `{kind:"permission", requestId, optionId}`；上游没有选项时才显示明确的拒绝按钮。停止轮次会清除待处理权限卡。
- **生命周期有界。** 事件队列沿用 Core 桥的 256 条、16 MiB、单条 4 MiB 上限，溢出时关闭连接并丢弃不完整会话；面板自己的 transcript 限制 200 条、1 MiB、单条 64 KiB，超出时丢弃最旧消息；面板只绘制滚动视口及前后一条消息，用上一帧测得的行高和保守估计放置上下占位，不一次创建全部消息行。关闭 Core 会话在窗口线程之外执行，`App.wait` 等待这些关闭完成，避免退出后留下子进程。
- **错误走日志和界面。** 启动、检测、provider 发现、发送、取消、权限答复和事件流失败都记录现有 `app.notification.operation_failed` 目录事件，并在面板显示可操作错误；连接关闭和溢出有固定文案，不把上游 stderr 或凭据写进界面。
- **历史按项目连接隔离，不复制持久化。** 打开历史只发送一次只读 `listSessions`，分页先显示、最终快照替换并按会话 ID 去重，最多保留 200 条；选择会话发送 `loadSession`，只接受当前 token 的 `sessionLoaded`。历史列表、恢复中的会话和回放尾随更新都属于该项目的 `agentState`，切换或关闭项目时随连接一起丢弃，迟到事件不会写入新项目。`user_message_chunk`/`agent_message_chunk` 只在恢复或回放期间重建 transcript，实时轮次仍使用本地发送记录。
- **恢复是事务式的。** 回放先写入独立的有界缓冲；`sessionLoaded` 确认后才替换当前 transcript 和配置，`requestFailed` 则丢弃缓冲并保留原会话 ID、文本、字节数和已确认设置。新建会话失败同理不清除现有配置。
- **会话设置只呈现适配器声明项。** `sessionCreated`/`sessionLoaded`/`sessionConfigured` 的 `configOptions` 是唯一来源；只提供 Core 的 `setConfigOption` 能设置的 select 项，模型、思考程度和权限模式使用本地化类别标签，当前值和选项名称保留上游原文。未收到 `sessionConfigured` 前不把选择当作已生效；失败保留已确认值。响应期间改配置、下一轮预选和 boolean 选项不在本切片内。
- **认证与连接状态如实呈现。** `authenticationRequired` 显示“需要登录”并停止把连接当作就绪，`authenticating` 显示等待登录，`account`/`ready` 才清除登录要求；面板不读取或显示账户邮箱。事件流异常丢失使用独立文案，`stopped` 的请求停止与上游错误分开。

## 考虑过的备选方案

- **在 Go 中实现 ACP 和进程管理**：会复制 Core 的协议、取消和进程树规则，故直接调用已有 Core 接口。
- **先做完整供应商设置页**：会超出最小会话切片，且需要凭据安全存储、导入/编辑/删除和多窗口冲突处理；本次先只读发现本机已有 provider，完整管理继续留在 `agent-provider-configuration` 能力行。
- **没有 provider 时显示一个默认配置**：会让用户以为 Agent 已配置，实际启动必然失败；故显示“未找到 provider”并保留真实错误。
- **权限请求默认选择第一个允许项或自动拒绝**：都替用户做了决定；故只显示上游选项，等待用户点击。
- **关闭面板就结束连接**：会让后台轮次中断，与旧客户端“关闭项目才停止”的行为不一致；故只在项目或窗口退出时关闭。

## 后果

收益是 Viva 有了真实可用的最小 Agent 闭环，且协议和配置解析没有第二份实现。代价是：

- 本切片只支持已安装的 `codex-acp` / `claude-acp` 和本机已有 API provider；适配器 Install 只覆盖 ACP 适配器本身，CLI 安装/更新、卸载、Node/npm 预检、订阅登录、收藏/重命名/归档/导出历史、下一轮配置预选、文件附件、工具/计划/用量展示、远程/MCP、子代理和导出仍未接入。
- 数据目录暂用 Viva 的 Application Support/Lithe Desktop，尚未迁移旧 macOS `Lithe` 或 Windows Tauri 目录；旧目录里的适配器不会自动出现。
- 真实供应商端到端、Windows 原生窗口和 macOS 原生窗口验收仍为 pending；本地测试使用脚本化 ACP 连接和 Core 的固定 ACP fixture，不能替代真实模型调用。
- transcript 只做纯文本增量显示，不解析 Markdown、工具或计划；这是有意的最小呈现。历史回放也只重建用户与助手文本，不重建工具卡片或计划。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'TestAIConfiguration|TestAgent' -count=3 -timeout=120s`：Core 配置来源/解析、凭据定位器不泄露密钥、ACP 连接、会话、流式事件、并发关闭、独立连接、队列溢出、取消等待和子进程退出。
- `scripts/desktop/desktop-go.sh test -race ./internal/workbench -run 'TestAgent' -count=1 -timeout=240s`：provider 发现与选择、显式适配器安装及进度/取消/重试/状态重读、启动 JSON、发送、增量回复、权限不自动答复、取消等待 `turnFinished`、请求失败/断连显示、transcript 上限与 List 虚拟窗口、凭据不进入日志/UI、项目关闭/替换清理，以及历史列出→恢复→继续、迟到 token/项目切换拒绝、配置确认/失败、认证状态。
- `scripts/desktop/desktop-go.sh test -race ./internal/workbench -count=1 -timeout=300s`：工作台回归。
- `node scripts/i18n/generate-i18n.mjs --check`、`node scripts/i18n/verify-app-language-localization.mjs`、`node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs`：面板文案走共享 i18n。
- 真实端到端仍需在 macOS 和 Windows 原生窗口用已安装的 Codex/Claude 和真实 provider 执行发送、权限、停止和退出清理；未执行前功能矩阵保持 `pending`。

## 适用范围

- `desktop/internal/workbench/agent.go`
- `desktop/internal/workbench/agent_provider.go`
- `desktop/internal/workbench/agent_view.go`
- `desktop/internal/workbench/agent_history.go`
- `desktop/internal/workbench/agent_config.go`
- `desktop/internal/workbench/agent_toolbar.go`
- `desktop/internal/workbench/agent_test.go`
- `desktop/internal/workbench/agent_history_test.go`
- `desktop/internal/core/agent.go`
- `desktop/internal/core/agent_bridge.go`
- `desktop/internal/core/agent_management.go`
- `desktop/internal/core/ai_configuration.go`
- `desktop/internal/core/ai_configuration_test.go`
- `desktop/internal/i18n/agent_messages.go`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/agent/acp-events-v1.json`
- `shared/fixtures/ai/cli-configuration-v1.json`
- `shared/platform-feature-matrix/features/agent-minimal-conversation.json`
