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
- **停止必须等上游确认**：只发送一次 `session/cancel`，撤销本轮权限请求，界面进入“正在停止”。收到原 prompt 的结束响应后才能发送下一轮。旧方案只屏蔽迟到的 prompt 响应，却不能阻止上游把新消息并入旧轮次，也不能识别没有轮次编号的迟到通知。因此改为十秒确认期限：超过期限则明确报错、停止该 Agent 的进程树，保留界面记录，用户重连后通过 `session/load` 恢复。正常取消不重启进程。这不是伪装成正常结束，用户会看到恢复原因；同一 Agent 进程里的其他会话也会断开，不能静默自动重试消息。
- **会话配置由上游提供**：面板连接完成后准备空会话，让用户发第一条消息前就能选择模型、权限模式、思考强度。选项、分组和当前值均来自 `session/new`、`session/load`、配置更新通知及 `session/set_config_option` 的响应；不硬编码模型列表。请求完成前禁止重复配置和发送，失败保留之前确认的值并显示错误。适配器没暴露的配置不画假控件，也不替用户改变网关地址或全局 CLI 配置。
- **工具证据与文档保护**：工具详情合并上游的部分更新，展示类型、输入、输出、文件位置和修改前后文本；权限卡复用已收到的工具证据，区分允许和拒绝。显示文本每段限制 32 Ki 字符，内容和位置各限制 100 条，避免大工具输出堵住界面；截断处标记 `[...]`。点击项目内文件交给现有编辑器导航，不在视图中直接读写文件。磁盘刷新、脏缓冲区保护和 Git diff 沿用文档/Git 模块。Agent 从项目目录启动，不需要先附加当前文件才能读写磁盘；未保存的编辑器快照是后续独立能力。
- **历史加载失败不清空记录**：回放时保留原会话快照，成功后使用上游回放，失败或连接退出时恢复之前记录并丢弃不完整的回放片段。旧连接事件任务被取消后不再消费缓冲事件。
- **并发权限与中断状态**：同一会话的多个权限申请按到达顺序排队，答复一个后展示下一个，取消时一起撤销。轮次或连接结束时，没有收到最终状态的工具标记为中断，不再无限显示运行中。
- **Agent 管理（Agent 面板内的设置）**：
  - **支持的 Agent 目录**：写在 `lithe-agent-host` 的 `catalog.rs`，Agent ID、npm 包名和固定版本都与 ACP 官方注册表一致。首批是 Codex（已用真实服务商验证）和 Claude（标为"未验证"）。只有重新验证过的版本才会提升。
  - **环境检测**：通过登录 shell 读取 `PATH`，所以 nvm、fnm 装的 Node 也能找到。检测 Node 和 npm 的版本，每个 Agent 各有最低 Node 版本（Codex 20、Claude 22），版本不够时只提示。
  - **一键安装**：用用户的 npm 把固定版本的适配器装到 `Application Support/Lithe/agents/<id>`。先装到临时目录，确认可执行文件存在后再替换旧目录，所以失败或取消不会破坏已经能用的旧版本。
  - **复用用户本机的 Agent CLI**：两个适配器都自带一份 Agent 的原生程序，都是可选依赖，单个平台约 200–370 MB，而用户本机本来就有。所以安装时加上 `--omit=optional`（Codex 装完约 18 MB）。启动时在登录 shell 的 PATH 里找到用户的 CLI 交给适配器：Codex 用 `CODEX_PATH`（最低 0.156.0），Claude Code 用 `CLAUDE_CODE_EXECUTABLE`（最低 2.1.280，对应 SDK 的 `claudeCodeVersion`）。CLI 找不到时可由 npm 安装；版本过旧时先确认当前 PATH 命令的安装来源，再通过原安装器更新。来源展示在预检项中，npm/Homebrew/原生安装可以按验证结果提供升级按钮，未知来源只给手动指引。所有安装与更新只在用户明确点击时运行，Node.js 和 npm 仍由用户自己安装。CLI 过旧不阻止安装适配器，只有 Node.js 或 npm 不可用才阻止。
  - **CLI 更新保留安装来源**：以 PATH 中实际命令及其真实文件为准，不能仅看到用户装了 npm 就把所有 CLI 交给 npm。Homebrew 通过自己报告的 Cellar/Caskroom 位置和已安装记录确认归属，保留 cask/formula 及 `claude-code@latest` 等渠道；npm 必须确认当前 global root、包名、bin 声明和链接都指向同一 CLI，另一套 Node 环境不能代更新；Claude 标准原生 launcher 使用上游 `claude update`。未知来源、损坏链接、缺少原安装器或安装记录时拒绝自动覆盖，明确提供手动指引。更新后重新读取登录 shell 的 PATH 并验证最低版本；更新命令退出成功但实际 CLI 仍过旧也应失败。安装器可能在首次下载失败后重试成功，却保留非零退出状态，因此正常结束的命令无论退出状态如何，都要检查实际版本。只有新安装或数字版本严格提升且达到最低要求时，才能把非零退出降为“已成功、带警告”，返回有界日志并在界面折叠展示；原本可用但版本没变、降级、仍过旧或找不到命令时继续报错。不能根据日志中的“successfully upgraded”字样猜测成功，也不能把取消、超时或启动失败改判成功。读取来源只使用有界的本地查询，不更新包管理器索引、不改变用户配置。Homebrew 和原生下载归原安装器拥有，仅显示“正在更新”与耗时，不伪造字节进度；它们的全局安装和缓存不注册成可复制的工作树构建资源，排除清单与测试同步维护。
  - **下载进度以 npm 的真实传输为准**：安装与 CLI 升级通过现有 Core 事件回调报告已接收软件包字节数、最近采样速度、耗时和等待时间。npm 没有提供整次安装的总量，且会继续发现依赖，所以不显示总体百分比。内嵌的 Node 观察模块只统计 HTTP 响应进入流缓冲区的字节，不添加消费数据的监听器，也不重写下载、代理、重试、校验或缓存行为。模块通过内存中的 data URL 加载，启动后先恢复用户原有 `NODE_OPTIONS`，防止 npm 子脚本继承观察器；不生成辅助文件或新的可复用缓存。正确做法是显示“已下载 25 MB、75 KB/秒、已用时 300 秒”；不要把 npm 静默时的日志时间或整个共享缓存大小当成下载进度。Core 事件只携带数字和阶段，界面按操作标识丢弃迟到事件，完成、失败或取消后清除进度。
  - **Rust Core 命令**：`agent.status`、`agent.install`、`agent.uninstall`、`agent.installCli`，复用现有信封的取消和超时。
  - **Key 和模型的传法**：所有适配器都通过 ACP `gateway` 登录，Key 经 stdio 传给 Agent，请求头按协议选择：Responses 协议用 `Authorization: Bearer`，Anthropic 协议用 `x-api-key`。模型按适配器分别传：Codex 用 `CODEX_CONFIG`，Claude 用 `ANTHROPIC_MODEL`。服务商配置里的"模型"必须传给 Agent：实测某个网关禁用了 Codex 的默认模型，不传模型时 Agent 只会回复一条网关报错。
  - **设置放在面板里，只有 Agent 管理一页**：Agent 的开关、预检清单（Node、npm、CLI、适配器、本机配置）、适配器和 CLI 的一键安装都在 Agent 面板右上角的设置视图里，不进全局设置窗口。布局仿照 Codeg 和 CC GUI：左侧图标栏，右侧标题加分段切换各个 Agent。
  - **跟随用户本机配置，不做服务商编辑**：每个 Agent 通过"一键获取本机配置"读取用户自己 CLI 的地址、模型和密钥（Codex 读 `~/.codex/config.toml` 和 `auth.json`，Claude 读 `~/.claude/settings.json` 和 `~/.claude.json`），生成的服务商配置绑定到该 Agent。密钥不复制进 Lithe，启动时从用户文件现读。这一步不会改动提交信息使用的服务商。用户要改地址或密钥时编辑自己的文件再重新获取。
  - **提示文案本地化**：Rust 返回的 `issues` 只决定能否安装；界面显示的原因由 Swift 按结构化状态（Node 版本、npm、CLI 版本）重新生成，这样中英文都能显示。
- **面板始终显示完整布局**：功能关闭或没有配置 Agent 时，面板照样显示会话标题、消息区和输入框，用户可以输入；发送时先校验（功能是否开启、是否有已配置的 Agent、模块是否启动完成），不通过就在输入框上方给出提示并提供进入设置的按钮，不会启动任何进程。
- **对话面板**：停靠在编辑器右侧，与 Maven 共用右侧槽位。输入框下方可以切换 Agent，列出的是已经设置了服务商的 Agent；打开的会话以标签形式排列。每个 Agent 第一次被选中时才建立连接；项目里所有 Agent 的权限提醒会合并显示到项目标签上。
- **对话区的视觉与交互**：按 CC GUI 参考设计使用单行会话标题、居中的品牌标志、上下文栏和底部工具栏。只有多会话或用户主动展开时才显示标签条，避免空会话标题重复。空态不放进滚动列表，否则无法在剩余高度内居中。输入区复用 `LitheSplitPaneView`，尺寸约束跟随可用高度，拖动只更新局部容器。搜索只筛选当前已加载消息，不请求 Agent 或改动历史。品牌 SVG 来自参考项目锁定的 `@lobehub/icons` 5.8.0，以静态源资源随 SwiftPM bundle 打包并携带 MIT 许可，不新增运行时下载或可复用缓存。参考图中的权限模式、推理强度、速度和上下文百分比没有对应 ACP 数据时不显示虚假的状态。
- **进程与诊断**：启动时把 Agent 可执行文件所在目录放到 `PATH` 最前面。npm 把 `codex-acp` 和 `node` 装在同一个目录，而 Mac 图形应用拿不到登录 shell 的 `PATH`。关闭时先向整棵进程树发 SIGTERM，并记录树里的每个进程 ID，稍等后再对仍存活的进程发 SIGKILL，因为 codex-acp 的 app-server 会比外层进程晚几秒退出。Agent 意外退出时，报错里附上 stderr 最后 20 行，其中的 Key 会被替换掉。

正确做法：新平台的界面通过平台适配器把 fixture 里的命令交给 `lithe-agent-host`，并把工具权限选择交给用户。

不要这样做：在 Windows React 层重新实现 JSON-RPC 协议；在打开 IDE 时就启动 Agent；取消尚未确认就解锁发送；把取消超时伪装成成功而不提示用户重连；把 API Key 通过环境变量或命令行传给 Agent；替用户下载一份他本机已有的 Agent CLI。

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

定时重发取消针对单个适配器缺陷，不能成为通用协议策略，因此不采用。单纯超时结束并清空会话会丢上下文，也不采用。当前选择保留记录、显式报错并重连加载的有界恢复：代价是重启连接，但能保证下一轮不与未结束的旧轮混在一起。

### 环境变量传 Key、或把 `CODEX_HOME` 指到 Lithe 目录

`OPENAI_API_KEY` 这类环境变量只适用于官方地址，也更容易泄露。隔离 `CODEX_HOME` 会让 Agent 读不到用户自己的 MCP 服务器、Skills 和全局指令；而一旦设置了网关，请求本来就不会用到用户的账号登录，所以没有必要隔离。

### 用 npm 日志或另写下载器提供进度

npm 的进度选项只面向终端，HTTP 日志通常在请求完成后才输出，无法解释长时间下载；轮询用户共享缓存也会把其他 npm 进程的写入误算进来。另写下载器会重复 npm 的代理、重试和缓存边界。因此采用一个只观察实际流字节的 Node 模块，保留 npm 完整安装行为；代价是必须用本地 HTTP 测试保护 Node 观察点和流的背压（消费者来不及处理时暂停接收）语义。

### 不识别来源，失败后给 npm 加 `--force`

这会覆盖 Homebrew 等安装器管理的命令链接，留下两个安装器争用同一文件，也可能让更新的是一份 CLI、PATH 运行的是另一份。统一迁移到 npm 还会改变用户的发布渠道。当前采用文件身份与原安装器记录确认后再更新：查询开销稍大，但能够保留安装方式；未识别的来源宁可显示手动步骤，也不猜测和覆盖。识别规则采用上游公开目录/命令，目录或包管理器输出变化时应补充契约与本地 fixture 测试。

## 后果

两端共享同一套协议和清理逻辑。功能关闭或没打开面板时，不会有 Agent 进程。一个项目只起一个进程，会话再多也一样。

代价：

- Rust C ABI 和 fixture 成为兼容面，两端界面仍要分别维护。
- 用户需要自行安装 Node.js，适配器可以在面板内安装。
- codex-acp 丢失取消时，最多等待十秒后需要用户重连；同一进程的其他会话也会断开。上游未持久化的最后片段可能无法完整回放，界面保留旧记录用于诊断，不能保证 Agent 保存了未完成轮次。

## 验证

- `cargo test -p lithe-agent-host --manifest-path rust/Cargo.toml`
- `cargo test -p lithe-core agent`（`agent.*` 命令与 `shared/fixtures/agent/agent-management-v1.json`）
- 真实 Agent 端到端测试默认忽略，需要设置 `LITHE_ACP_E2E_*` 环境变量后运行：`cargo test -p lithe-agent-host --test real_agent -- --ignored`。设置 `LITHE_ACP_E2E_DATA_DIR` 时，会先用 npm 安装适配器，再从 Lithe 数据目录启动。
- `shared/fixtures/agent/acp-events-v1.json` 同时由 Rust 序列化测试和 Swift 功能模型测试读取。
- 配置选项与确认、部分工具更新、停止期间拒绝新消息、虚拟时钟驱动的取消超时、加载失败恢复记录均有回归测试。真实 Agent 集成测试在自动清理的临时项目执行“读取、修改、运行 Node 测试、继续追问”，另验证配置切换、取消恢复及进程重启后历史加载；不操作用户项目代码。
- CLI 来源测试覆盖 Homebrew 与 npm 共存、formula/cask/渠道、npm bin 身份、另一套 Node 环境、Claude 原生、未知与坏链接、查询取消/超时、非零退出但实际升级成功、可用旧版本未变化、降级、数字等价版本和更新后 PATH 仍过旧；不执行用户级安装或外部网络下载。
- `node --test scripts/test-reuse-worktree-resources.mjs`（拒绝复制用户级 CLI 安装与缓存）
- `node --test rust/lithe-agent-host/tests/npm-progress.test.mjs`（本地 HTTP 响应不被观察器消费，归档字节计数准确，元数据与重定向不计入）
- `./scripts/verify-module-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- 在 Mac 上实测：连续对话、权限选择、刚发出就取消、切换项目标签后旧会话继续运行、打开历史会话、关闭项目后进程全部退出。

## 适用范围

`rust/lithe-agent-host/`、`rust/lithe-core/src/agent/`、`rust/lithe-core/src/runtime/ffi.rs`、`macos/Sources/Lithe/Views/Agent/`、`macos/Sources/LitheAgentConversationModule/`、`macos/Sources/Lithe/Platform/MacOS/Agent/`、`shared/contracts/rust-core-api.md`、`shared/contracts/application-boundary.md`。
