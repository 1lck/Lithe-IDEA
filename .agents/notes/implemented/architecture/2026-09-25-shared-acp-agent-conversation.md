# Agent 笔记：共享 ACP Agent 对话

状态：已实现

## 先说结论

Agent 对话默认关闭，打开某个项目的 Agent 面板时才启动本机 Agent。每个项目只有一个 Agent 进程，一个进程里可以有多个会话；会话历史由 Agent 自己保存，Lithe 只负责显示。第一阶段只支持用户自己的 API Key，不接任何官方账号登录。Agent 需要的 Node.js 由用户自己安装，Lithe 只负责检测；ACP 适配器由 Lithe 提供一键安装，安装时用的是用户本机的 npm。ACP（Agent Client Protocol，编辑器与 Agent 之间的对话协议）连接和进程管理写在同一个 Rust crate 里，Mac 与未来的 Windows 只各自实现界面。

## 问题

如果两端各写一套 ACP 连接、权限回复与进程清理，协议行为容易分叉。若在应用启动时就启动 Agent，不用这个功能的用户也要承担内存和进程开销。Agent 会请求执行工具，权限必须由用户确认。

实测还发现两个会直接影响用户的问题：

- codex-acp 1.13.1 在"刚发出消息就取消"时会丢掉这次取消。它此时已经拿到本轮 ID，但 Codex 还没把这一轮标记为进行中，于是中断请求返回"没有进行中的一轮"。结果是这条消息的请求永远不返回，本轮在后台继续跑完并消耗额度，下一条消息还会被塞进这一轮。
- 打开 codex-acp 的 `APP_SERVER_LOGS` 调试日志后，网关请求头（包括明文 API Key）会写进日志文件。

## 决策

- **共享实现**：`rust/lithe-agent-host` 使用官方 `agent-client-protocol` SDK。一个 `AgentHandle` 对应一个项目的 Agent 进程和 ACP 连接，负责初始化、网关登录、会话新建/列出/加载、消息、权限、取消和进程树清理。Mac 通过 Rust Core C ABI（`lithe_agent_open_json`、`lithe_agent_send_json`、`lithe_agent_close`）调用；Windows 以后直接依赖同一个 crate。命令和事件的 JSON 形状由 `shared/fixtures/agent/acp-events-v1.json` 固定。
- **按需启动，跟着项目走**：`LitheAgentConversationModule` 是内置可选模块，默认禁用。每个项目有自己的模块运行时，所以会话天然属于项目。切换标签或窗口不会结束任何会话，后台项目的这一轮会继续跑完；只有关闭项目、关闭功能或退出应用时才停止 Agent。后台项目的会话在等待权限时，项目标签上会显示提醒点。
- **只用 API Key 登录**：初始化时声明 `auth._meta.gateway = true`，然后只用 `gateway` 方式登录，把服务商地址和 `Authorization: Bearer <key>` 放进 `authenticate` 请求，经 stdio 传给 Agent。Key 不进命令行参数、环境变量或文件，Lithe 也不设置 `APP_SERVER_LOGS`。Agent 不提供 `gateway` 登录时直接报错，不会退而使用它的账号登录。第一阶段只支持 Responses 协议的服务商，也就是 codex-acp。
- **历史以 Agent 为准**：会话列表来自 `session/list`，打开旧会话用 `session/load`，由 Agent 回放历史。Lithe 不自己保存聊天记录。Agent 进程重启后，旧会话必须先加载才能继续发消息。回放可能在 `session/load` 返回之后才到达，界面按到达顺序追加即可。
- **取消与主流客户端一致**：参考了 Zed、Codeg、CodeCompanion、agent-shell 和 avante。取消时只发送一次 `session/cancel`，先把本轮的权限请求答复为 `cancelled`，然后立即报告本轮结束，界面马上恢复可输入；旧请求在后台继续等待，它的迟到回复直接丢弃。不重发取消，也不因取消而结束会话或进程。
- **Agent 管理（设置 › Agents）**：
  - **支持的 Agent 目录**：写在 `lithe-agent-host` 的 `catalog.rs`，Agent ID、npm 包名和固定版本都与 ACP 官方注册表一致。首批是 Codex（已用真实服务商验证）和 Claude（标为"未验证"）。只有重新验证过的版本才会提升。
  - **环境检测**：通过登录 shell 读取 `PATH`，所以 nvm、fnm 装的 Node 也能找到。检测 Node 和 npm 的版本，每个 Agent 各有最低 Node 版本（Codex 20、Claude 22），版本不够时只提示。
  - **一键安装**：用用户的 npm 把固定版本的适配器装到 `Application Support/Lithe/agents/<id>`。先装到临时目录，确认可执行文件存在后再替换旧目录，所以失败或取消不会破坏已经能用的旧版本。
  - **Rust Core 命令**：`agent.status`、`agent.install`、`agent.uninstall`，复用现有信封的取消和超时。
  - **Key 和模型的传法**：按 Agent 分别适配。Codex 的 Key 走网关登录，模型走 `CODEX_CONFIG`。Claude 的 SDK 只接受环境变量，所以 Key 和地址走 `ANTHROPIC_API_KEY`、`ANTHROPIC_BASE_URL`，模型走 `ANTHROPIC_MODEL`。服务商配置里的"模型"必须传给 Agent：实测某个网关禁用了 Codex 的默认模型，不传模型时 Agent 只会回复一条网关报错。
  - **设置页结构**：服务商在"AI Providers"页统一管理，每个 Agent 在"Agents"页选择自己用哪个服务商（只列出协议匹配的）。"正在编辑的服务商"和"提交信息使用的服务商"是两回事，在管理页上切换正在编辑的服务商，不会改动提交信息的设置。
- **对话面板**：顶部可以切换 Agent，列出的是已经设置了服务商的 Agent。每个 Agent 第一次被选中时才建立连接；项目里所有 Agent 的权限提醒会合并显示到项目标签上。
- **进程与诊断**：启动时把 Agent 可执行文件所在目录放到 `PATH` 最前面。npm 把 `codex-acp` 和 `node` 装在同一个目录，而 Mac 图形应用拿不到登录 shell 的 `PATH`。关闭时先向整棵进程树发 SIGTERM，并记录树里的每个进程 ID，稍等后再对仍存活的进程发 SIGKILL，因为 codex-acp 的 app-server 会比外层进程晚几秒退出。Agent 意外退出时，报错里附上 stderr 最后 20 行，其中的 Key 会被替换掉。

正确做法：新平台的界面通过平台适配器把 fixture 里的命令交给 `lithe-agent-host`，并把工具权限选择交给用户。

不要这样做：在 Windows React 层重新实现 JSON-RPC 协议；在打开 IDE 时就启动 Agent；为了让取消看起来生效而在超时后结束整个会话；把 API Key 通过环境变量或命令行传给 Agent。

## 考虑过的备选方案

### 两端各用平台语言实现 ACP

界面开发起步更快，但连接、取消、权限和进程树清理都要写两遍，长期维护成本高。社区的 Swift SDK 也会带来第二套协议栈。

### 整体复用 Codeg

Codeg 是一个完整的 ACP 产品，可以参考，但它的工作台、状态和发布方式不适合嵌进 Lithe。直接用官方 SDK 可以复用协议实现，同时保留 Lithe 自己的模块生命周期。

### 项目失活时结束会话

这是上一版的做法，但点一下另一个窗口也会结束正在进行的对话。它不符合"会话属于项目"的使用习惯，已经撤回。

### Lithe 自带 Node.js，或用 `npx` 按需拉取适配器

Zed 就是这么做的。但会装 Agent 的用户本机通常已经有 Node。自带 Node 会让安装包变大，也多出一份需要维护更新的运行时。`npx` 会在第一次打开面板时悄悄联网下载，用户不知道装了什么。因此只检测 Node，不自带；适配器由用户点击后才安装，而且固定版本。

### 用户自己用 `npm -g` 装适配器

多数用户不知道"适配器"和 Agent 的命令行工具是两个东西，比如装了 `claude` 不等于装了 `claude-agent-acp`。全局安装还可能碰到权限问题，版本也不受控制。

### 取消超时后结束会话，或定时重发取消

上一版在 5 秒内没收到回复就结束整个会话，结果会丢掉上下文。定时重发取消能绕开 codex-acp 的这个问题，但调研的五个 ACP 客户端都没有这么做，而且它只针对单个 Agent 的缺陷。两者都没有采用。

### 环境变量传 Key、或把 `CODEX_HOME` 指到 Lithe 目录

`OPENAI_API_KEY` 这类环境变量只适用于官方地址，也更容易泄露。隔离 `CODEX_HOME` 会让 Agent 读不到用户自己的 MCP 服务器、Skills 和全局指令；而一旦设置了网关，请求本来就不会用到用户的账号登录，所以没有必要隔离。

## 后果

两端共享同一套协议和清理逻辑。功能关闭或没打开面板时，不会有 Agent 进程。一个项目只起一个进程，会话再多也一样。

代价：

- Rust C ABI 和 fixture 成为兼容面，两端界面仍要分别维护。
- 用户需要自己安装 codex-acp。
- 只要 codex-acp 没修复前面那个取消问题，"刚发出就取消"时它仍会在后台把这一轮跑完，下一条回复会变慢；界面本身不会卡住。

## 验证

- `cargo test -p lithe-agent-host --manifest-path rust/Cargo.toml`
- `cargo test -p lithe-core agent`（`agent.*` 命令与 `shared/fixtures/agent/agent-management-v1.json`）
- 真实 Agent 端到端测试默认忽略，需要设置 `LITHE_ACP_E2E_*` 环境变量后运行：`cargo test -p lithe-agent-host --test real_agent -- --ignored`。设置 `LITHE_ACP_E2E_DATA_DIR` 时，会先用 npm 安装适配器，再从 Lithe 数据目录启动。
- `shared/fixtures/agent/acp-events-v1.json` 同时由 Rust 序列化测试和 Swift 功能模型测试读取。
- `./scripts/verify-module-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- 在 Mac 上实测：连续对话、权限选择、刚发出就取消、切换项目标签后旧会话继续运行、打开历史会话、关闭项目后进程全部退出。

## 适用范围

`rust/lithe-agent-host/`、`rust/lithe-core/src/agent.rs`、`rust/lithe-core/src/runtime/ffi.rs`、`macos/Sources/Lithe/Views/App/AgentsSettingsView.swift`、`macos/Sources/LitheAgentConversationModule/`、`macos/Sources/Lithe/Platform/MacOS/Agent/`、`shared/contracts/rust-core-api.md`、`shared/contracts/application-boundary.md`。
