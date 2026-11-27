# Agent 笔记：Agent 原生调用官方 CLI，本地会话记录与搜索放在 Core

状态：提议中

## 先说结论

Lithe 重新做 Agent，但只调用用户自己安装、自己登录好的官方命令行工具（CLI）：Claude Code、Codex，以及先做但暂不开放的反重力（Antigravity，命令 `agy`）；不做 Gemini CLI。Lithe 不提供登录，不读凭据，不改模型请求的去向，也不冒充别的客户端。这四条是防封号的底线，能由 Core 在结构上保证的，就由 Core 强制，不靠插件自觉。

连接 CLI 有两种模式，**能原生就原生，实在不行才用 ACP**：

- **原生模式**：插件后端用 CLI 自己公开的结构化协议驱动它，例如 `claude -p` 的 stream-json、`codex app-server` 的 JSON-RPC，再翻译成 Lithe 自己的会话事件。
- **ACP 模式**：ACP（Agent Client Protocol，编辑器与 Agent 之间的开放协议）。插件只声明启动命令，Core 的通用 ACP 客户端直接连接。

两种模式下，CLI 进程都由 Core 启动、由 Core 回收。

调用记录、Token 统计、费用、速度和会话全文搜索，都从 CLI 自己写在本机的会话文件推导。解析会话文件的代码在各 Agent 插件的后端；Core 负责增量读取、SQLite 缓存、统计口径、全文搜索，并通过“IDE 连接”把会话搜索作为 MCP 工具提供出去。缓存里不存对话正文。

插件 API 编号为 API-45（2026-11-25 用户批准新增），新能力 `agents` 从版本 0 开始。

2026-11-28 用户要求在 Core 和契约之外，把宿主界面和三个插件也做出来：一个所有 Agent 通用的管理插件（会话、用量、额度、资源库、供应商），以及 Claude Code、Codex 两个插件。后两个插件通过跨插件函数（API-35）把各自的信息提供给管理插件。契约细节见第 9 节，管理插件和信息注入见第 10 节。

## 问题

**旧方案是半成品，已于 2026-11-12 删除。**

- 旧方案靠第三方 ACP 适配器（`claude-agent-acp`、`codex-acp`）接入 Agent。适配器装在 `Application Support` 里，Lithe 既不能安装或更新 Agent 本身，也不能更新适配器，用户只能手工处理。
- 适配器内部走 Agent SDK，用量也不计入 Claude Code、Codex 本身的额度。
- 每次模型调用的统计靠本机代理改写 `ANTHROPIC_BASE_URL` 和 Codex 的推理地址（2026-10-13 的“通过本机代理观测 Agent 的模型调用”，已随旧方案归档）。

删除记录见 [Viva 桌面端不做 Agent 对话](../../implemented/feature/2026-11-12-viva-agent-conversation-removed.md)。

**用户仍然需要三件事：**

1. 在 IDE 里和 Agent 对话。
2. 查询、搜索以前的本地会话，包括在自己终端里开的会话。
3. 看到每次调用的 Token、缓存命中率、费用和速度。

**封号风险来自第三方工具的四种做法：**

1. 拿订阅登录的令牌去调接口。
2. 把订阅流量转到别的地址。
3. 冒充官方客户端。
4. 批量自动调用。

新方案必须从结构上避开这四种做法，不能只靠写在文档里的约定。

**Core 不能内置任何 Agent 的知识。** Claude、Codex 的会话文件格式和协议随 CLI 版本变化。按[通用逻辑在 Core、工具内容在插件](../../implemented/architecture/2026-10-31-plugin-capability-and-domain-boundaries.md)的边界，这些知识只能放在插件里，Core 只做与具体 Agent 无关的部分。

## 提案

### 1. 防封号底线：谁来保证

| 底线 | Core 在结构上怎么保证 | 插件和评审要做什么 |
| --- | --- | --- |
| 只运行用户装好、登录好的官方 CLI | Agent 命令只能是插件的工具定义（`toolDefinitions`），由宿主的工具发现找到，并经过版本探测。安装只走 `commandInstallers`，需要用户确认。安装审阅里列出命令。Lithe 没有“用 Claude 登录”这类入口。 | 工具定义只指向官方发布的命令。需要登录时，提示用户在终端里运行 CLI 自己的登录命令。 |
| 不读、不存、不转发凭据 | Core 只读取插件声明的会话目录，读取前要用户逐个 Agent 同意。宿主方法里没有任何读凭据的接口。 | 会话目录不得覆盖凭据文件（如 `~/.claude/.credentials.json`、`~/.codex/auth.json`），插件评审逐条核对。Codex 的 `account/chatgptAuthTokens/refresh` 这类要宿主提供令牌的请求，一律拒绝。 |
| 不改请求去向 | Agent 的启动结果不能带环境变量，带了 Core 就拒绝。Core 里没有代理，也不改写 CLI 的配置文件。 | 启动参数里不放改服务地址的设置（例如 `--settings` 里带 `env`）。帮用户配置自定义供应商，只能由用户在设置里主动修改 CLI 的真实配置。 |
| 不冒充别的客户端 | Core 把宿主的真实名称和版本交给插件，没有任何“自定义客户端身份”的字段。 | 握手时如实报告 Lithe（例如 Codex `initialize` 的 `clientInfo`），不设置冒充官方入口的变量或参数。 |
| 不做批量和后台自动调用 | 只有用户发起的请求（`origin.source = user`）才能开始会话或发出一轮提问，后台来源一律拒绝。每个 Agent 同时运行的会话数有上限。 | 插件不在后台自动发起提问。 |
| 每次发版复核各家条款 | —— | 发版时由 `release-lithe` Skill 提醒复核。条款变化时先关掉相应入口，再决定怎么改。 |

另外有一条：`claude -p` 会跳过 Claude 自己的“信任此工作区”确认。所以 Agent 一律视为“会执行项目代码”，只能在 Lithe 判定为可信的工作区里启动，规则与[构建的工作区信任](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/README.md#workspace-trust)相同。远程工作区在 v0 中明确拒绝，按 API-40 的规定返回“不支持”。

### 2. Lithe 自己的会话模型

Core 定义一套与具体 Agent 无关的会话事件，两种模式都翻译成它，桌面端只认这一套。名称尽量和 ACP 一致，ACP 模式就能逐项对应；ACP 表达不了的信息作为可选字段补上。

| 事件 | 内容 |
| --- | --- |
| 会话 | 会话 ID（CLI 自己的 ID）、工作目录、模型、推理强度、是否续接。 |
| 一轮 | 用户消息、开始与结束、结束原因：完成、取消、达到上限、拒答、出错。 |
| 回复与思考 | 文本，支持增量。 |
| 工具调用 | 类型（读、改、执行、搜索、联网、其他）、状态、标题、涉及的文件位置、diff、命令输出。 |
| 计划 | 步骤和状态。 |
| 权限请求 | 选项和用户的选择。 |
| 用量 | 原生模式可以细到每次模型调用。 |
| 只有原生模式有 | 额度和限流状态、模型改派、子 Agent 归属、hook 事件、上下文压缩。 |

拿不到的字段就不出现，不估算、不编造。例如 ACP 只给整轮用量，界面就只显示整轮用量。

### 3. 两种模式

**原生模式（优先）。**

插件在清单的 `agents[]` 里声明 `native: {function}`。每次开始会话时，Core 调用这个插件函数，拿到命令行：可执行文件（只能是工具定义）和参数（不能带环境变量）。Core 按自己的进程边界启动 CLI，持有它的标准输入输出。

- CLI 输出的每一行，Core 按批转给插件后端。
- 插件后端用宿主方法把要写给 CLI 的行交回 Core，用宿主通知上报翻译好的会话事件。
- 权限请求由插件后端发给宿主，用户回答后再由插件回复 CLI。
- 取消、关闭和插件停用由 Core 通知后端，并结束进程树。

插件后端只负责“翻译”，不自己启动 CLI。下面是目前确认可用的原生协议，具体参数由插件决定：

| CLI | 原生协议 |
| --- | --- |
| Claude Code | `claude -p --input-format stream-json --output-format stream-json`，`--permission-prompts host` 把权限确认交给宿主，`--resume` 续接 |
| Codex | `codex app-server`：`thread/start`、`turn/start`、`turn/interrupt`；审批由服务端发请求；`thread/tokenUsage/updated`、`account/rateLimits/read` 提供用量和额度。schema 用 `codex app-server generate-json-schema` 导出，插件在构建时固定 |
| 反重力 | `agy -p --input-format stream-json --output-format stream-json` |

**ACP 模式（兜底）。**

插件在 `agents[]` 里声明 `acp: {tool, arguments}`，例如 `agy acp`。Core 的通用 ACP 客户端用 stdio 连接它，完成 `initialize`、`session/new` / `session/load` / `session/resume`、`session/prompt`、`session/cancel` 和权限请求，并翻译成同一套会话事件。v0 不向 Agent 提供 ACP 的文件系统和终端能力，Agent 用它自己的工具。ACP 是开放标准，和 LSP、DAP 一样属于通用协议，放进 Core 不算针对具体工具。

**选择规则。**

- 两种都声明时，用原生模式。
- 原生模式不可用时才用 ACP。插件后端会报告已装 CLI 的版本是否在支持范围内，后端启动失败也算不可用。
- 都不可用时，返回带原因的“不可用”。
- 会话进行中不切换模式。选中的模式写进日志。

**两种界面形态。**

- “对话”：上面两种模式。
- “终端”：在 Lithe 的终端里运行 CLI 的交互界面，Lithe 通过会话文件跟进状态。

契约允许插件同时声明两种形态。Claude 默认用哪一种，是界面阶段的决定，本 Note 不定。

### 4. 安装、版本和更新

- **发现和版本**：复用工具定义。插件为 CLI 写一个工具定义，由宿主的工具发现找到可执行文件，并用定义里的版本探测得到版本。
- **安装**：复用 `commandInstallers`，例如用 npm 安装 Codex。
- **更新**：新增 `agents[].update`，内容是对该工具运行的参数（例如 `claude update`、`agy update`），或者指向一个安装器、用它重新安装。更新前需要用户确认，输出显示在运行窗口，结束后重新探测版本。

这样就补上了旧方案“不能在 Lithe 里更新 Agent”的缺口，而且不必在 Core 里写任何 CLI 的名字。

### 5. 本地会话记录：调用、统计、搜索

**会话目录由插件声明，读取需要用户同意。** `agents[].sessionSources[]` 声明根目录候选、包含的文件模式和格式。

- 根目录可以用 `${userHome}`，也可以取某个环境变量的值（例如 `CODEX_HOME`）再加默认值。这两个模板变量只在这里可用。
- v0 只支持 `jsonLines` 格式：每行一个 JSON。
- 用户逐个 Agent 同意，默认关闭。同意对话框列出要读的目录。
- 撤销同意后，删除这个 Agent 在缓存里的全部记录。

**Core 读，插件解析。**

- Core 为每个文件记一个游标：路径、大小、修改时间、文件开头的摘要、已读到的偏移。追加的内容只读新增部分；文件被截断或重写（开头摘要变了）时从头重读。
- Core 按行切成有上限的块，调用插件后端的 `scan` 函数，传入文件、上次的解析状态和新行。
- 插件返回四样东西：会话元数据、调用记录、用来建索引的文本片段（带原文件的字节范围），以及新的解析状态。
- 显示对话内容时，Core 按字节范围重读原文件，再调用插件的 `read` 函数取得可显示的消息。

插件只能读到自己声明的目录，不同插件之间不互通，符合 API-34“不转交 Agent 历史”的要求。

**调用记录字段。**

- 时间、Agent、会话、线程。
- 请求的模型、实际的模型。上下文窗口单独存，例如把 `claude-opus-5[1m]` 拆成模型和 `context_window`。
- 推理强度。
- Token：输入、输出、缓存读取、缓存写入（区分 5 分钟和 1 小时）、推理。
- 首 token 延迟、耗时、是否是压缩调用。
- 请求 ID、出错类别、原文件的字节范围。

供应商和账号只在本地元数据能明确识别时才记录，不推断。

**统计口径只在 Core 写一份。**

- **缓存命中率** = 缓存读取 ÷（输入 + 缓存读取 + 缓存写入）。不报告缓存数据的供应商不参与计算。
- **费用**：用 models.dev 的价格表。Core 构建时打包一份快照，运行时每天最多刷新一次，存进平台的 Caches 目录。订阅用户看到的标注是“按 API 价格折算”。
- **速度**：有首 token 时间时，用首 token 之后的输出窗口计算。没有时只给下限，显示为“≥ 输出 ÷ 耗时”，并且只在输出不少于 1000 token、耗时不少于 1 秒时显示；上限按每秒 10000 token 截断。
- **速度排行**：用中位数，输出少于 100 token 的回复不参与。
- **聚合维度**：日、Agent、模型、会话、工作目录。

**SQLite 缓存。**

- Core 新增 `rusqlite`（打包 SQLite 源码的版本）作为正式依赖。数据库是平台 Caches 目录里的一个文件，文件名带结构版本号；版本变了就删掉重建。
- 表有三类：文件游标、调用元数据、全文索引。
- 全文索引用不存正文的 FTS5 表（`content=''`、`contentless_delete=1`、`detail='none'`）。中文按相邻两个字符切分；搜索结果只指向“哪个文件的哪个字节范围”，摘要从原文件重读。
- 缓存可以随时删除，并完全从会话文件重建。Lithe 从不写 Agent 的会话文件。
- Lithe 自己的标注（置顶、自定义标题）不是缓存，存在 Application Support，和缓存分开。
- 所有写入都在平台可写目录，不碰程序包，符合运行时只读边界。

**MCP 会话搜索。** 在[“IDE 连接”](../../implemented/architecture/2026-09-30-ide-capabilities-and-local-mcp.md)（`ide-host`）里增加两个只读工具：会话搜索和会话读取（候选名 `lithe_sessions_search`、`lithe_sessions_read`）。

- 只有同时满足三个条件时才提供：用户打开了 IDE 连接、打开了单独的“允许 MCP 客户端搜索本地会话”开关、并且同意读取该 Agent 的会话。
- 结果条数和字节数都有上限。
- 日志只记工具名、结果条数和耗时，不记查询词。

### 6. 日志

事件写在 Core 的 `rust/logging/events/agent.json`（现在 `agent` 根还没有事件），只记 Lithe 自己做的事。

| 事件 | 字段 |
| --- | --- |
| `agent.session.*` 终态 | Agent、模式（原生或 ACP）、会话 ID、模型、`context_window`、推理强度、是否续接、耗时 |
| `agent.prompt.*` 终态 | 会话 ID、结束原因、Token 计数、工具调用次数、权限请求次数、耗时 |
| `agent.permission.decided` | 工具类型、选择 |
| `agent.cli.update.*` 终态 | Agent、更新前后的版本、退出类别 |
| `agent.sessions.index.*` 终态 | Agent、扫描的文件数和字节数、新增调用数、耗时 |

不记录对话正文、提示词、工具参数和输出、CLI 的标准输出、账号、邮箱和凭据。从会话文件推导出的调用不逐条写进日志，它们已经在缓存里。

### 7. 代码落点（实现时以契约 PR 为准）

**Rust Core（Lithe-core-rust）：**

| 位置 | 内容 |
| --- | --- |
| `rust/crates/plugin-model/src/capabilities.rs` | 新增 `agents`，版本 `[0]` |
| `rust/crates/plugin-manifest/` | 校验 `agents[]` |
| 新 crate `plugin-agents` | 启动方案解码、会话策略，参照 `plugin-language-servers` |
| 新 crate `agent-model` | 会话事件类型 |
| 新 crate `agent-acp` | ACP 客户端与事件翻译 |
| 新 crate `agent-runtime` | CLI 进程、原生转发、会话事件队列、`agents/*` 宿主方法的回答 |
| `rust/crates/lsp-engine/` | Core 内部调用插件函数的等待器；把 `agents` 宿主服务交给 `agent-runtime`；后端会话结束时通知它 |
| 新 crate `agent-sessions` | SQLite 缓存、增量读取、统计、搜索、价格表 |
| `rust/crates/ide-host/` | 两个 MCP 工具 |
| `rust/crates/core/` | 新增 `agents.*`、`agentSessions.*` 两组命令和 `rust/fixtures/` |

**契约和插件开发资料（Core 的 `shared/plugins/`）：**

- 契约 README、schema、fixture。
- 四种官方 SDK（Rust、Go、Node、Java）。
- 协议更新记录和 API 总表（按 API-45 登记）。

**桌面端：** Agent 工具窗口（对话、会话列表与搜索）、设置页（逐个 Agent 同意读取会话、MCP 会话搜索开关、CLI 安装与更新）、终端形态入口。桌面端只调用第 9 节的命令，不解析任何 Agent 的协议或文件。

| 位置 | 内容 |
| --- | --- |
| `desktop/internal/agents/` | `agents.*`、`agentSessions.*` 命令的客户端；把会话事件合并成有上限的对话记录；按清单和用户同意算出授予的权限；会话目录用到的环境变量 |
| `desktop/internal/pluginservice/agents.go`、`hostmethods.go` | 从已安装插件读出 `agents[]` 和权限；按需启动 Agent 的插件后端；把 `agents/*` 宿主方法交给 Core |
| `desktop/internal/workbench/agents.go`、`agents_view.go` | 右侧 Agent 工具窗口：对话与历史两个页签、多会话、权限请求、计划、用量状态行、终端打开、CLI 更新确认；远程工作区不显示，安全模式先请求信任 |
| `desktop/internal/workbench/settings_agents.go`、`desktop/internal/settingswindow/agents_*.go` | 设置 › AI › Agent：逐个插件同意读取本机会话记录；撤销同意时清掉已缓存的记录 |

配置有先后：插件重新加载和设置里改同意都会重新配置 Core。每次配置在窗口线程领一个序号，后台执行时如果更新的配置已经送到 Core，旧的就不再发送，避免旧授权盖住新授权。

### 8. 分期

1. **Core 会话记录**：SQLite 缓存、增量读取、统计、搜索、MCP 工具和日志。用合成测试插件 `dev.lithe.test.agent-sessions` 提供解析函数。
2. **API-45 契约**：`agents[]` 清单、原生模式的启动与转发、ACP 客户端、四种 SDK。
3. **桌面端界面**。
4. **插件**：通用管理插件 `lithe-plugin-agent-hub`、Claude Code `lithe-plugin-claude-code`（原生 `-p` 加终端形态）、Codex `lithe-plugin-codex`（`app-server`）。反重力（原生或 ACP，不开放）以后再做。

进度（2026-11-28）：第 1 期已合入 Core；第 2 期在 Core Draft PR Lithe-IDEA/Lithe-core-rust#216；第 3 期在桌面端 Draft PR，固定 #216 的 Core 提交。桌面端还没做的：对话文字的选择与复制（Viva 的 `ui` 门面没有可选择文本）、MCP 会话搜索开关、CLI 安装入口（现在只有更新）。

### 9. 契约细节（v0）

**清单。** 插件声明 `"requires": {"agents": 0, "backend": 0}`，顶层 `agents[]` 每项：

| 字段 | 含义 |
| --- | --- |
| `id`、`displayName`、`icon?` | Agent 的标识、名称和图标 |
| `tool` | 本插件 `toolDefinitions` 里的工具 ID，CLI 只能是它 |
| `native?: {function, timeoutMilliseconds?}` | 原生模式的启动函数 |
| `acp?: {arguments}` | ACP 模式：对 `tool` 运行的参数 |
| `terminal?: {arguments}` | 终端形态：对 `tool` 运行的参数 |
| `update?: {arguments}` 或 `{installer}` | 更新：对 `tool` 运行的参数，或本插件的某个 `commandInstallers` |
| `sessionSources[]: {id, roots, include, format, scan, read}` | 会话目录。`roots` 是候选路径，只能用 `${userHome}` 和 `${env:NAME}`，取第一个能解析的；`format` 只能是 `jsonLines` |

`native`、`acp`、`terminal` 至少声明一种。激活事件是 `onAgent:<id>`。权限：

| 权限 | 允许 |
| --- | --- |
| `agents.native` | 使用 `lithe/host/agents/write`、`lithe/host/agents/report`，并接收下面的 `didStart` 等通知，只针对本插件声明的 Agent 的会话 |
| `agents.usage.read` | 使用 `lithe/host/agents/usage`：读取已同意 Agent 的用量和额度汇总，只有数字和模型名，没有正文、标题和路径 |

**原生会话的转发。** CLI 进程由 Core 的 `agent-runtime` 持有，插件后端只做翻译：

| 方向 | 方法 | 内容 |
| --- | --- | --- |
| Core → 后端 | `lithe/host/agents/didStart` | `{session, agentID, cwd, resume?}`，进程已启动，后端可以写握手行 |
| Core → 后端 | `lithe/host/agents/didOutput` | `{session, lines}`，CLI 标准输出的完整行，按顺序、按批 |
| Core → 后端 | `lithe/host/agents/didPrompt` | `{session, turn, text}`，用户发出的一轮提问 |
| Core → 后端 | `lithe/host/agents/didCancel` | `{session, turn}` |
| Core → 后端 | `lithe/host/agents/didDecidePermission` | `{session, permission, option}`，用户的选择 |
| Core → 后端 | `lithe/host/agents/didExit` | `{session, exitCode?, signal?}` |
| 后端 → Core | `lithe/host/agents/write` | `{session, lines}`，写进 CLI 标准输入，每行补换行 |
| 后端 → Core | `lithe/host/agents/report` | `{session, events}`，第 2 节的会话事件 |

- 这两个宿主方法由 Core 自己回答，不转给桌面端；Core 只接受本插件后端为本插件 Agent 开的会话。
- 写入走每个会话自己的写线程和有上限的队列，后端的读线程不会等 CLI 的标准输入，避免两个进程互相等待。
- 输出按会话的顺序队列发给后端；后端会话结束时，Core 结束它名下的全部 CLI 进程树。
- `turn` 由 Core 分配；后端上报的事件必须属于正在进行的一轮。权限请求的选项由后端列出，用户只能从中选一个，Core 检查后再通知后端。

**Core 内部调用插件函数。** 启动函数、`scan` 和 `read` 由 Core 直接调用插件后端，操作 ID 用 Core 保留的前缀，结果不进入桌面端的事件队列。这和跨插件调用的 relay 是同一种做法，桌面端不需要逐跳搬运。

**命令（桌面端调用）。**

| 命令 | 作用 |
| --- | --- |
| `agents.catalog` | 从已安装清单列出 Agent、可用的模式和形态、更新方式 |
| `agents.start` | 检查来源（只接受 `user`）、工作区可信、非远程、并发上限；调用启动函数，检查结果（只能是本 Agent 的 `tool`、不能带环境变量），启动进程 |
| `agents.prompt`、`agents.cancel`、`agents.respondPermission`、`agents.close` | 一轮提问、取消、回答权限请求、结束会话 |
| `agents.waitEvents` | 有上限地等待会话事件 |
| `agentSessions.configure` | 宿主传入 Caches 和 Application Support 里的绝对路径 |
| `agentSessions.sync`、`agentSessions.forget` | 增量同步一个已同意的 Agent；撤销同意时删除它的缓存 |
| `agentSessions.list`、`agentSessions.search`、`agentSessions.read`、`agentSessions.stats` | 会话列表、全文搜索、按字节范围读取、统计 |

**额度。** 额度和限流状态也是与具体 Agent 无关的数据：插件的 `scan` 可以返回额度快照，原生会话的 `rateLimits` 事件也由 Core 记下。Core 只保留每个 Agent 每个额度窗口的最新一条，供 `agentSessions.stats` 和 `lithe/host/agents/usage` 使用。

### 10. 管理插件与信息注入

**管理插件只写一次通用部分。** `lithe-plugin-agent-hub`（插件 ID `io.github.lithe-idea.agent-hub`）用插件视图提供“Agent Hub”工具窗口：

- **用量**：按日、Agent、模型汇总 Token、缓存命中率、按 API 价格折算的费用和速度，数据来自 `lithe/host/agents/usage`。
- **额度**：每个 Agent 各额度窗口的已用比例和重置时间，同样来自 Core。
- **资源库**：指令、记忆、MCP 服务器、技能、Hooks、环境变量、子代理、斜杠命令、规则九类。
- **模型与供应商**。

会话的对话内容只在宿主的 Agent 工具窗口里显示，管理插件拿不到正文和标题，符合 API-34。

**Agent 插件通过 API-35 注入自己的信息。** 管理插件在 `pluginFunctions.calls` 里声明下面三个函数，Claude Code、Codex 插件在 `exports` 里提供（上下文 `workspace`）。管理插件用 `lithe/host/functions/providers` 找到所有提供者，再逐个调用：

| 函数 | 版本 | 返回 |
| --- | --- | --- |
| `agentHub.describe` | 1 | 插件里有哪些 Agent：`agentID` 和显示名称 |
| `agentHub.resources` | 1 | 每个 Agent 九个类别的全部条目：名称、类别、范围（用户、项目、本机、管理员下发、插件）、位置、一行摘要、是否停用。环境变量和任何密钥只给名字，不给值 |
| `agentHub.providers` | 1 | 每个 Agent 当前的模型、模型来源、当前供应商，配置里的供应商（地址、存放密钥的环境变量名）和配置档，来自 CLI 的真实配置 |

字段、上限和提供者规则以管理插件仓库的 `docs/agent-hub-functions.md` 为准，本节只记取舍：

- 三个函数的 `params` 都是 `{}`，一次回答全部类别。按类别分次调用，每个插件要多 8 次往返；管理插件最多同时问 4 个插件，以免超过 Core 每个调用方 8 个转发中调用的上限，往返越多刷新越慢。回答本身很小，一次放得下（上限 256 KiB）。
- 登录状态不进管理插件：登录提示需要账号信息或运行 CLI，既碰凭据又不是“名称和位置”，留给 Agent 工具窗口在会话报错时提示。
- 资源位置只给“第几个项目文件夹 + 文件夹名 + 相对路径”，不给 Root ID：Root ID 每个插件各不相同，管理插件自己按位置找到文件夹，名字对不上就不打开。项目以外的文件只显示 `~/...`，不打开。
- 清单里一个函数 ID 只能导出一个版本，Core 只转发版本相同的调用，所以管理插件只调用导出版本 1 的提供者。版本 1 内只加可选字段；不兼容的改动发版本 2，管理插件和提供者一起升级。
- 资源条目的来源都是 CLI 自己的真实配置文件，项目里的文件双击打开来源文件，符合“设置必须反映工具的真实配置”。不维护影子配置，不在打开页面时写文件。
- 提供者不读凭据文件，也不运行调用方指定的可执行文件或读调用方指定的路径；要区分调用方时读 Core 写入的顶层 `caller.pluginID`。
- 以后新增一个 Agent 插件，只要实现这三个函数，管理插件不用改。

### 正确做法

- Codex 插件的后端收到 Core 转来的 `thread/tokenUsage/updated` 行，翻译成用量事件，上报给宿主。界面显示本轮用量，但不把这一份写进调用记录。调用记录只从 `~/.codex/sessions/` 下的文件推导，这样不管是在 Lithe 里开的会话还是在终端里开的会话，口径都一样，也不会重复计数。
- Claude 插件的启动函数返回 `{executable: {kind: "tool", tool: "claude"}, arguments: ["-p", "--input-format", "stream-json", …]}`，进程由 Core 启动。

### 不要这样做

- 在 Core 里写 `if agent == "claude"`，或把 `~/.claude/projects` 写进 Core。目录和格式只能来自插件声明。
- 启动结果里带 `ANTHROPIC_BASE_URL`，或在 Core 里起本机代理来“统计每次调用”。前者 Core 会拒绝，后者违反“不改请求去向”。
- 插件后端自己启动 CLI，再把结果报给宿主。这样 Core 无法回收进程，也无法检查启动内容。
- 把对话正文写进 SQLite 或日志，以便“搜索更快”。

## 考虑过的备选方案

### 全部走 ACP，Claude、Codex 用第三方适配器

只需要一种协议，Core 最简单。不采用，原因有三：

- 适配器内部走 Agent SDK，有订阅合规风险。
- 适配器跟不上 CLI 的版本。
- ACP 表达不了每次调用的用量、额度和 hooks。

这正是 2026-11-12 删掉的旧方案。

### 插件把原生协议桥接成 ACP，Core 只说 ACP

这是 2026-11-25 上午的方案：Core 内部只有一种格式。用户否决了，原因有三：

- 要翻译两次（CLI 协议 → ACP → Lithe）。
- ACP 表达不了的信息在中间就丢了。
- 每个插件都得实现一个 ACP 服务端。

改为 Lithe 自己的会话模型，ACP 只是两种输入之一。

### 插件后端自己启动 CLI 进程

插件代码最简单，少一层转发。不采用：Core 就无法保证进程回收、工作区信任检查、“不带环境变量”这条规则，也无法在安装审阅里展示要运行的命令；防封号的结构性保证会全部落空。

### 用本机代理观测每次模型调用

数据最精确，旧方案用过。不采用：它要改写服务地址，正好违反“不改请求去向”。会话文件已经记有每次调用的用量和请求 ID。

### 在终端里运行交互界面，并向 CLI 注入预加载脚本来读取回复

能按交互方式计费，回复也能拿到。不采用：向官方程序注入代码，属于篡改客户端。

### 把 Claude、Codex 的解析器写在 Core 里

上手最快。不采用：违反 Core 零特判。会话格式随 CLI 版本变化，放在插件里也能更快发版跟进。

### 把正文存进 SQLite

搜索摘要和打开会话更快。不采用：这会在 Lithe 的缓存里复制一份私密内容，删除时还要同步两份。改为“不存正文的索引 + 重读原文件”。

### 把解析和统计放在 Go 桌面端

不用改 Core。不采用：统计和搜索是与界面无关的通用逻辑，按规则放在 Core，以后换界面层也能复用。

## 验收标准

- Core 的代码、契约和 fixture 里没有任何 Agent 的名称、目录或格式。全部来自合成测试插件，或插件仓库自己的测试。
- 合成插件声明一个会话目录。用户同意后：
  - 追加写入只增量读取；
  - 截断或重写后从头重读；
  - 撤销同意后，该 Agent 的缓存清空。
  - 缓存文件里搜不到测试对话的正文。
- 统计结果对 fixture 精确：缓存命中率、费用（带“按 API 价格折算”标记）、速度下限的显示门槛、中位数排行、请求重复时只算一次。
- 中文和英文都能搜到；搜索结果的摘要来自重读原文件。
- 删除缓存数据库后可以完整重建，结果相同。
- 启动结果带环境变量时，Core 拒绝。后台来源的请求不能开始会话。不可信工作区和远程工作区拒绝启动。
- 原生模式和 ACP 模式产生同一套会话事件；ACP 给不了的字段不出现。
- MCP 工具在三个条件中任意一个不满足时不可见或拒绝调用；日志里没有查询词。
- 新增事件全部写在 `agent.json` 目录里，并通过日志门禁；新增错误码一码一义。
- 运行时没有任何写入落到程序包或安装目录。

## 风险

- **CLI 协议变化**：`codex app-server` 标为实验性，Claude 的 stream-json 字段也会变。插件固定已测试的版本范围，并在启动前探测；超出范围时退回 ACP 或报告“不可用”。Core 不受影响。
- **厂商条款变化**：例如 Anthropic 改变对 `-p` 的计费或许可。每次发版复核；必要时只保留终端形态，或关闭某个 Agent。
- **会话文件很大**：单个 Claude 会话可达上百 MB。按块和行设上限，增量读取；超长的行跳过并记录。
- **中文搜索质量**：两字切分会有噪声，但比按空格分词好得多；以后可以换成更好的分词器。
- **SQLite 让 Core 静态库变大**：约 1–2 MB，可以接受。
- **反重力的会话格式未知**：可能不是每行一个 JSON。v0 只支持 `jsonLines`，反重力暂不开放，等确认格式后再扩展格式类型。

## 适用范围

- `docs/development/macos-plugin-api-plan.md`
- `.agents/notes/implemented/feature/2026-11-12-viva-agent-conversation-removed.md`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/README.md`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/plugin-model/src/capabilities.rs`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/ide-host/src/lib.rs`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/logging/events/agent.json`
