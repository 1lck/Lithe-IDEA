# Agent 笔记：MCP 服务器资源库与项目级 Lithe 注册

状态：已实现

## 先说结论

设置页的 MCP 页面现在分成两部分：上方是 Codex 与 Claude Code 已注册服务器的统一资源库，下方是原有的“Lithe IDE 访问”项目授权。资源库按“名称 + 定义哈希”合并条目，允许按 Agent 独立开关、添加、编辑和删除服务器；写入只修改目标条目，保留原文件其余字节，并在覆盖前把旧内容备份到 Application Support。开启项目授权时，Lithe 还会把自己随包分发的 `lithe-mcp` 写进该项目的 Claude Code 与 Codex 配置，关闭授权或项目时按账本清理。首版只做 macOS，Windows 在能力矩阵中标记为平台专属。

## 问题

此前 MCP 设置页只管理 Lithe 自己暴露给连接 Agent 的项目授权，生成一段需要用户手动粘贴的 JSON。用户实际同时在 Codex 和 Claude Code 里注册了多个 MCP 服务器，却没有一个地方能看清两边分别注册了什么、参数是否一致，也没有办法让 Maven 相关工具自动出现在这两个 Agent 里：`lithe-mcp` 已经随包分发并暴露 `lithe_maven_*` 工具，但从未写入任何 Agent 配置。

直接让宿主“读写几个配置文件”看起来简单，真正困难的是不能破坏用户已有的配置。`~/.claude.json` 包含大量与 MCP 无关的状态，`~/.codex/config.toml` 可能带有注释、未知键和用户自己的表；任何“解析后整体重写”的做法都会丢失格式或覆盖用户条目。

## 决策

### 分工

- Rust Core 的 `rust/lithe-core/src/mcp/` 只负责纯文本工作：解析 Claude JSON 与 Codex TOML、计算规范化定义哈希、生成保格式的修改计划。它不读文件、不读环境变量，也不决定路径。
- `Core/Ports/McpConfigurationStore.swift` 是端口，`Platform/MacOS/MCP/MacAgentMcpConfigurationStore.swift` 是 macOS 适配器。适配器负责 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`、项目路径解析，1 MiB 上限、UTF-8 校验、同目录临时文件与原子交换式条件替换、权限保留和备份。
- `Application/Features/McpServerLibraryFeatureModel.swift` 拥有合并、草稿、按 Agent 开关、保存/删除和账本。UI 只调用这个模型，不直接碰文件。

### 身份与合并

- 一个条目的身份是 `名称 + 规范化定义哈希`。同名但定义不同的条目会显示为两行并标记“Conflict”，编辑其中一行不会顺带改写另一行。哈希在计算时对 env/header 按键和值排序，因此写入路径与重新解析路径得到同一个哈希，不受 UI 排序方式影响；同时只包含当前传输方式实际会写入的字段（stdio 的 command/args/env、HTTP/SSE 的 url/headers），解析器能看到但写盘会丢弃的多余字段不参与哈希，否则刚写入的条目在刷新后就会失去所有权。页面保存时也按传输方式清空非活动字段，避免把编辑器里隐藏的旧参数带进新定义。
- 同一个定义同时出现在 Codex 和 Claude Code 中时合并成一行，两个 Agent 胶囊分别显示开关状态。
- 项目级条目只读展示。它们由“Lithe IDE 访问”生命周期管理，不在资源库里直接编辑，避免用户以为改的是全局配置。

### 所有权账本

- 账本按“Agent + 作用域 + 项目路径”记录 Lithe 写过的名称、定义哈希及完整来源哈希 `sourceHash`，存放在 `settings.mcpServerRegistrations`。定义哈希只用于跨 Agent 合并；完整来源哈希覆盖该 Agent 条目里的所有字段，包括界面未建模的认证、超时、非字符串变量及其他未知配置，忽略注释与排版。多个窗口共享同一个 store，因此每次读取都从共享账本取最新快照，写入时只替换当前文件对应的键，而不是把窗口初始化时的整份字典写回，避免一个窗口覆盖另一个窗口刚记录的条目。
- 只有磁盘上的完整来源哈希与账本一致时，Lithe 才会自动替换或删除该条目。重复注册即使可见字段未变，也必须先校验所有权，否则返回当前来源哈希并写入账本会静默接管外部修改。原始条目若因 command/URL 被移除而未出现在发现结果中，仍需按已有配置拒绝覆盖或清理，不能当成空位置。用户自己创建的条目返回 `ownedByUser`，在 Lithe 之外被改过的条目返回 `externallyModified`；两者都保留原文件，并在页面上说明原因。旧账本若只有定义哈希，不能证明未知配置仍未变化，必须重新接管所有权或打开最新条目进行显式编辑；禁止根据当前磁盘内容静默补全旧账本。
- 用户在 Lithe 里主动编辑并保存时，草稿会保留打开编辑器时每个 Agent 各自的完整来源哈希，作为独立的 `expectedHash` 前置条件发给 Core。刷新列表不会替旧草稿换成新版本，也不把旧版本追加为账本的另一条授权。Core 在判断“内容未变”或“账本有所有权”之前先检查这个前置条件，因此另一窗口保存了新版本、同时更新共享账本，也不能让旧草稿覆盖它。重命名时检查旧名称的来源版本，新名称若已存在则单独校验其所有权，不能借旧条目的授权覆盖无关条目。普通删除和关闭 Agent 开关仍需先接管所有权；保存时按共享账本的最新状态确认该条目仍归 Lithe，因此同一编辑器里刚接管的条目可以立即关闭对应 Agent，同时仍要求草稿捕获的完整来源哈希未变，不能用更新的账本条目给旧草稿授权。
- 例如，Codex 原条目的 `startup_timeout_sec` 被外部改动后，列表仍按可见定义合并，但自动删除和旧草稿保存都会拒绝；用户刷新并重新打开条目后可以修改 URL，保留该超时配置，再把写入结果的完整来源哈希记入账本。不要用只覆盖 URL 的定义哈希证明整个原始条目可被删除。
- 用户可以对一个外部条目执行“接管所有权”（Take ownership）：只写账本，不改文件。之后按 Agent 开关才能真正移除它。这个动作是显式的，因为“删除别人的配置”和“让 Lithe 以后管理这份配置”是两件事。

### 保格式编辑

- 参数编辑器保留原始参数数组；显示文本没有变化时直接使用原数组，因此只编辑环境变量不会丢掉空字符串、纯空白参数或参数内的换行。用户修改了文本后按 LF 分行，保留空行和空白行；把原本非空的文本清空表示删除全部参数。逐行编辑无法区分 `[]` 与 `[""]`，也无法区分参数内部换行和参数边界，所以不把重新拆分的文本当作未修改参数的真源。
- 读取、写入和失败恢复共用符号链接目标解析，针对目标普通文件做大小及 UTF-8 校验，保留原配置路径用于错误展示。写入和恢复修改链接目标并保留原链接，不把 dotfiles 链接替换成普通文件；读取阶段不能仅检查链接自身的文件类型。
- Claude JSON 使用基于字节偏移的插入/删除，只改动 `mcpServers.<name>` 或 `projects.<path>.mcpServers.<name>`，其余内容逐字节保留。删除条目时只删除该键到下一个键之间的字节，不扩展到行首，因此同一行有相邻条目、或条目的值跨多行且下一个键紧跟闭合括号时，都不会连带删除其他条目；删除最后一个条目时同时删除前导逗号，并在返回计划前重新解析结果，避免写出丢失条目的半截配置。带注释或非严格 JSON 的文件拒绝写入，而不是冒险整体重排；对象里出现重复键时同样拒绝编辑，因为 `serde_json` 取最后一个值而按偏移编辑会命中第一个，二者对“实际生效的定义”判断不一致。
- Codex TOML 使用 `toml_edit`，保留注释、表顺序和未知键。新增本地依赖 `toml_edit = "0.25"` 就是为此；原有的 `toml` 只能解析。更新已有服务器时只修改 Lithe 建模的 `command`、`args`、`env`、`url`、`http_headers`，替换值时不重建键值项，因此键上方注释、行尾注释和值装饰都保留；`args` 未变化时不重建数组，数组元素之间的注释也不会因为保存其他字段而丢失。`bearer_token_env_var`、`startup_timeout_sec`、`tool_timeout_sec` 等 Codex 专属字段原样保留。`env`/`http_headers` 中无法在本库表示的非字符串值不会因为一次编辑被删掉：即使 UI 里该 Agent 的变量列表为空，也只移除字符串键，保留非字符串值，避免删除用户从未看到的内容；只有整个容器不是对象/表（例如手写成数组）时，用户新增条目才会用新表替换该字段，因为这种形态对 Agent 本身无效，无法合并。`mcp_servers` 写成内联表时同样可以新增、编辑和删除条目；如果文本编辑实际没有改变内容，计划返回 `absent` 而不是 `removed`，防止账本忘记仍然存在的条目。重命名时先把原表整体迁移到新名称再应用建模字段，专属字段随条目一起移动；Claude JSON 重命名同样以旧条目为底稿覆盖建模键。
- 保存前会拒绝环境变量或 Header 的重复键：配置对象/表无法表示同名两项，先写一份哈希再写成另一份会导致刷新后失去所有权，因此在 Core 和页面校验两处都直接拒绝。
- 资源库保存和 Lithe 项目注册共用批量提交：先计算全部文件的计划并校验磁盘快照，再逐文件写入，全部成功后才更新所有权账本。即使外部 Agent 在预检之后、两次写入之间改了后续文件，后续写入的 `changedOnDisk` 也会触发对已写文件的逆序恢复；原先不存在的文件会删除，原先存在的文件会恢复原快照。不能在每次单文件成功后立即写账本，否则会留下半套注册。
- 恢复前也校验文件仍等于本次批量写入的内容；如果外部程序又改了已写文件，就保留该外部修改，继续尝试恢复其他文件，并明确报告未恢复路径，由用户刷新检查；聚合首次写入与恢复阶段的失败时，把两处保留副本的错误详情和隐藏路径一并带回，避免用户只看到原配置路径。删除本批次新建的文件时同样不能先比较再直接 `removeItem`：`MacFileStorage.removeData` 先把目标原子移开，再核对其内容是否仍是本批次输出，不匹配就把文件放回并保留外部写入。备份保留原始内容和尝试写入的内容；这是一种失败后恢复机制，不承诺跨文件的操作系统原子可见性或进程崩溃后的自动恢复。
- 每个被改写的文件都会先备份到 `Application Support/MCP Backups/<时间戳>/`，备份失败则中止写入。
- 快照预检和备份之后还有一次平台条件替换，最终发布不在 Swift 应用层直接覆盖文件：`MacFileStorage.replaceData` 把新内容写到目标同目录的临时文件，已有文件用原子交换（`renamex_np` 的 `RENAME_SWAP`）发布，并检查被换出的旧字节是否仍等于计划快照；不等且目标仍持有本次写入时换回并返回 `changedOnDisk`，若目标已被更新的外部保存替换则保留该外部保存；目标缺失、非常规或读取失败时同样不删除被换出的字节，换回失败时保留装着外部字节的临时文件，并让写入失败而不是静默覆盖。不支持 `RENAME_SWAP`/`RENAME_EXCL` 标志的卷直接返回不支持错误（fail closed），不退回无条件覆盖；用户需要把 Agent 配置放在 APFS 等支持条件交换的卷。回滚交换后还会核对被换出的字节确实是本次发布内容，若换出的是更新的外部保存就保留临时文件并报错，错误里给出保留路径而不是随临时文件删除；无法恢复时同样保留并报告。临时文件从创建起就是 `0600`，发布后再恢复目标原权限，避免含 token 的明文副本按默认权限暴露。写入失败（包括发布回滚失败）时把捕获到的原权限重新套回目标，避免含 token 的配置以默认权限残留。新文件用 `RENAME_EXCL` 发布，目标在预检后出现时拒绝创建。不要把最终写入退回为「比较后无条件 rename」：比较和 rename 之间仍可能落进其他程序的保存，把它静默覆盖。

### Lithe 自己的项目级注册

- 开启“Lithe IDE 访问”时，`IdeCapabilitiesFeatureModel` 把 host 返回的 `lithe` 服务器命令和参数转交给资源库。资源库写入：
  - Claude Code：`~/.claude.json` 的 `projects.<项目绝对路径>.mcpServers.lithe`；
  - Codex：`<项目>/.codex/config.toml` 的 `[mcp_servers.lithe]`。
- 只写项目级，不写全局。项目关闭或授权关闭时，按账本删除 Lithe 写入且哈希未变的条目。`WorkspaceSessionCoordinator` 会在关闭回调前清空会话 URL，因此资源库记录每个注册过的工作区，并在注销时清理全部记录加上当前工作区：项目切换期间新项目可能先注册、旧项目尚未清理，只保留一个 URL 会把旧项目的条目留在磁盘上。
- 如果 Codex 项目配置文件是 Lithe 新建的，会把 `.codex/config.toml` 追加到 `.git/info/exclude`，不修改被版本控制的 `.gitignore`；用户自己创建过该文件时不加排除规则。linked worktree 的排除文件位于公共 Git 目录，资源库读取 `commondir` 后写入那里，而不是写入 `worktrees/<name>/info/exclude`。追加排除规则时保留原始字节，不要求已有文件为 UTF-8；已有文件读取失败必须报错，禁止按空文件重建并丢掉本地规则。排除是整批配置写入成功之后的收尾步骤：失败只在页面上提示“已注册但未能排除”，不回滚账本，否则下次关闭项目时无法找到并清理已经写进去的条目。
- 外部改过的项目条目不会被删除，页面显示“需要处理”的原因，账本保留，以便下次仍能识别。关闭授权后项目注册行本身会隐藏，因此注销阶段产生的冲突还会写入资源库的 `error` 横幅，避免清理失败完全不可见。

### 密钥与健康检查

- env 和 header 值在编辑器中用 `SecureField` 遮蔽，但配置文件中仍是明文；页面明确写出这一点，不制造“已经加密”的错觉。列表摘要及其默认辅助功能文本不显示 stdio 参数，仅显示经过安全字符校验的可执行文件名；HTTP/SSE URL 会移除 userinfo、查询参数和 fragment，无效 URL 仅显示传输方式。例如 `--token=secret` 不能出现在摘要中，`https://user:secret@example.test/mcp?token=secret` 只能显示 `https://example.test/mcp`。
- 错误消息、日志和 Core 返回值都不回显配置内容。解析失败只报告文件路径和错误类型。
- 打开页面或展开工具区只读；只有点击“检测工具”才连接，stdio 还需确认执行通知。
  检测会运行配置的命令，可能下载包，因此不能在导入、保存或展开时自动触发。

### 紧凑编辑器与工具检测

配置弹窗参考 Magpie `ccbc7278180e513bf95461c62eeb15729fc7cae7` 的
`internal/gui/assets/plugins/library/client.js`；工具排除机制核对其
`internal/library/mcp_tools_off.go`，并核对 Codex 原生 `disabled_tools` 与 Claude
官方 permissions 文档。独立实现原生页面，不复制 Magpie 的网关和多 Agent 框架。
命令与参数投影成一行，Rust Core 的 shell-words 1.1.1 只解析/引用 argv，保留空参数、
内嵌换行和路径空格，不执行 Shell。Agent 用现有品牌图标的选择按钮，帮助仍放在 ⓘ。

检测复用仓库已有的官方 rmcp 3.5.0 SDK，初始化、会话、SSE 响应和分页相关语义留给
SDK；Agent Host 管理执行、取消和进程清理。只增加 client/streamable HTTP 能力，
沿用 reqwest 0.12 的 TLS/网络栈；自定义字节 adapter 在 JSON、错误和 SSE 解码前
限制 2 MiB，避免 SDK 默认 HTTP JSON 读取无上限。工具最多 1000 项、20 页，重复
游标拒绝；请求期限 30 秒并有有界清理，stdio 子进程/进程组在结束、失败、取消后回收。
不发送 tools/call，不处理 OAuth 登录、不读取其他 Agent 的登录令牌；不支持的旧式
SSE 检测明确报错，仍允许用户编辑原有 SSE 配置。成功只代表这次检测，不能当成现有
Agent 会话的连接保证。

工具区按已注册的 Agent 独立切换。Codex 修改自身条目的 disabled_tools；Claude 修改
用户 settings.json 的 permissions.deny，只写精确 mcp__规则。外部精确/通配 deny、
Codex enabled_tools 以及名称规范化冲突保持不可放宽，页面显示只读限制；只移除本库
登记过的精确禁用项，文件过期时保留外部修改。规则与全局原生文件由现有写入 adapter
备份、条件替换，偏好只登记工具名所有权，不存令牌。Codex 更改规则会改变完整来源
哈希，页面只推进此前匹配的服务器所有权，不能把一次工具操作当成接管外部服务器。

工具规则按原生路径/服务器名保留，即使暂时关闭服务器也保留限制。Codex 删除条目前，
Core 提取原生允许/禁用名单，整批条件写入成功后才把这些工具名保存在原服务器账本的
`toolFilters` 中；保留记录没有 `sourceHash`，不能授权修改外部重新创建的条目。重新添加
缺失条目时恢复名单，并根据恢复后的完整内容登记新所有权。现存条目和重命名沿用原生
规则，不能被旧保留值覆盖；空允许名单仍表示不允许任何工具，格式错误则拒绝删除。
这份状态随用户资料保留，不保存命令、env、header 或令牌；新页面和应用重启都能恢复。
Codex 重命名还必须移动相同原生文件路径下、由 Lithe 登记的精确工具名所有权；只搬原生表会让原来可编辑的禁用项被误判为外部限制。迁移在整批文件条件写入成功后执行，失败或恢复不发布新名称所有权；清除旧名称记录，也不合并新名称处可能过期的记录。外部 deny 和 allow-list 不因此取得所有权，其他配置路径和 Agent 保持独立。
Claude 的规则引用
服务器名称，原生用户配置存在 MCP 限制时拒绝在本页重命名，避免旧限制未迁移而让
工具重新可用；用户需先在原生规则中处理。项目/受管规则仍由上游 Agent 决定，页面
不会显示为已解除全局之外的限制。生命周期退出会取消探测、丢弃迟到结果并释放内存
快照；这些状态登记在 mcp-tool-probe-state，没有工作树复用阶段或发行目录运行时写入。

同一连接新增或移除 Agent 时，服务器行的名称和定义哈希不变，不能只按行 ID 保留旧策略。工具模型记录每行最新来源，来源改变时释放旧策略快照、按现有工具清单重读本地规则；探测尚未返回时也以最新来源读取策略。此刷新不重新连接第三方服务器，保留已检测工具；单个 Agent 的读取失败明确显示错误，其他 Agent 的可用策略保留。

检测的 macOS 适配器使用 8 MiB 栈的独立原生线程执行有界 C ABI 调用，避免阻塞 Swift 并发执行器，以及调试版 SDK/TLS 调用在小栈线程上溢出。取消与指令保存共用 `RustCoreCancellation`：Core 登记操作后、执行命令前同步回调，补传注册前到达的取消，不需要重试计时器；页面状态仍拒绝迟到结果。显式设置 `LITHE_MCP_PROBE_INTEGRATION=1` 可运行 Context7 的真实 HTTP 工具列表验证，普通测试不依赖公共网络。

### 发现市场与弹窗编辑

资源库和“发现 MCP 服务器”在同一页纵向排列，上方管理已添加服务器，下方搜索官方目录；项目级 Lithe 授权在页末。
添加或编辑使用平铺表单的原生弹窗，只有字段区域滚动，取消和保存固定在底部；资源库超过五项时提供名称与安全摘要搜索。
发现区标题右侧以灰色普通文字显示“精选，以及官方 MCP Registry”，作为目录来源标记，不提供 Registry 首页直达链接。
市场卡片直接显示发布者、版本和两行简介，这些是用于选择服务器的目录内容；设置行为和授权解释仍放在 ⓘ。卡片按窗口宽度自动排列为一列或多列。
标准 `mcpServers` JSON 经既有 Core 解析器生成预览，用户逐个选择条目检查后再保存。
导入只带入现有编辑器支持的字段，认证与客户端专有字段需另行配置；界面的 ⓘ 明确
说明这个边界。导入不读环境变量、不写文件，也不接管已有条目。

交互参考 Magpie 的 `86254d4049cb6be4a2ccdab02edf0bd59860c603`，目录行为另核对
`ec7e50b8287462efcb6153fde67308e66b5aaf51` 的 `internal/library/market.go`，尤其
`internal/gui/assets/plugins/library/client.js` 的发现卡片与编辑流程，以及
`internal/gui/library.go` 对目录失败的独立提示。只参考公开交互与 API 使用方式，
继续复用 Lithe 的原生控件、配置端口、格式保留与所有权模型，不搬入其 Web UI 或网关。

打开页面先展示随版本提供的精选目录，不发网络请求。Magpie 的 `MarketServers` 同样
先筛选内置 `featured`，只有搜索词非空时才请求 Registry，部分失败仍返回精选结果；
因此“打开时有卡片”不代表该机器已经连通官方目录。Lithe 的精选 JSON 由 Git 管理并
编译进 Core，`mcp.featuredRegistry` 复用公开目录的校验逻辑返回卡片。包版本从官方 npm
元数据核对后固定，远程地址按发布者文档核对；中文介绍随应用本地化。维护目录时
必须重新核对包版本、远程地址和文档，不复制 Magpie Image 等产品专属能力。

精选包含 Context7、Playwright、Chrome DevTools、Microsoft Learn、GitHub、DeepWiki、
Exa、Filesystem、Fetch 和 Memory。2026-10-22 核对发布者文档与 npm/PyPI 元数据，
Filesystem/Memory 固定为 2.0.0（需要 Node.js 24+），Fetch 固定为 2026.10.19
（需要 uv 和 Python 3.10+）；GitHub、DeepWiki、Exa 使用发布者的 HTTPS 入口。
GitHub 的令牌和 Filesystem 的允许目录不能猜测，因此只有版本内的精选可声明
`setup`，让编辑器显示说明并阻止缺少必填内容的保存。GitHub 预置空 Authorization
请求头，用户填写 Bearer 令牌；Filesystem 必须在包参数后逐行填写至少一个绝对目录，
路径中的空格保留。公开 Registry 不能声明这一可信模板类型，原有复杂输入限制不变。

卡片图标使用发布者的品牌标记，不再让所有远程服务都显示地球、所有命令都显示终端。
图标源文件与来源、审核日期、SHA-256 清单位于 `Resources/McpIcons`，Playwright 的
Apache-2.0 许可一同保留。它们是 Git 跟踪、SwiftPM 打包的固定输入；运行时只从资源
bundle 读取并在内存缓存，不访问图片服务器、不下载头像、不写 bundle，因而不改变
代码签名或 Sparkle delta。三个参考服务器共用 MCP 标记，未认识的条目保留传输方式
图标。只按可信精选的完整 ID 选择有限文件名，公开条目即便伪装成同名也不使用品牌图标。
深色页面的品牌标记放在白色小底板上，保留原始颜色和几何；不是工具栏动作图标。

搜索时使用官方 `registry.modelcontextprotocol.io/v0.1/servers`，按名称搜索、只查最新
版本，并使用返回的 opaque cursor（必须原样传回的分页标记）。这是一份目录，不是
Lithe 的托管服务器或插件市场，也不把收录标成安全审核。Core 的 `mcp.parseRegistry`
把公开元数据转换为可显示的卡片；静态远程地址和没有额外输入的固定版本 npm/PyPI
入口才能生成配置草稿；自定义包源、非默认 runner、npm 可变标签和主/次版本范围都只保留文档。需要密钥、动态地址或复杂参数的记录保留文档入口，不猜命令。
草稿不默认选择 Agent，用户确认后走原来的保存流程；不会下载、安装或运行服务器。

macOS adapter 使用无持久缓存、无 Cookie 和无凭据存储的 URLSession，限制响应为
1 MiB，请求/总资源期限分别为 15/20 秒。搜索任务归 SwiftUI 页面拥有，离开页面取消；
请求身份防止旧响应覆盖新搜索，分页合并按名称去重，相同 cursor 不再反复加载。
在线匹配列表不再要求点击“加载更多”：共享 `LitheScrollLoadTrigger` 在原生滚动视口
接近列表尾部时请求下一页，几何信息只留在控件内，不向整个设置页发布每像素滚动状态。
不能把普通 `VStack` 尾部的 `onAppear` 当成可见性：它可以在离屏时挂载，导致自动拉完整个目录。
该探针也被通用 VCS 历史复用，但不替换 Git 自己已有的原生行渲染器。
模型以已提交的查询与代理路由续页，不读取用户尚未提交的新输入；同一页仅允许一个在途请求。
无新增结果、重复或循环 cursor 均停止续载。失败保留已加载匹配并暂停自动请求，用户显式重试时
沿用失败页的 cursor；显式改用直连时重新搜索，不能把系统代理的 cursor 带到另一条路由。
精选与在线条目按 ID 和不含名称的连接定义去重。连接失败保留已匹配条目，明确区分
安全连接、超时和网络不可达，并保留手动添加入口，不把失败伪装成“没有服务器”。
请求默认遵循 macOS 系统代理；只有用户点击“直连重试”才为此页面的公开目录请求
选择空代理字典的独立 URLSession，继续校验证书，并允许切回系统代理。路由不持久化，
不修改系统、Agent 或实际 MCP 服务器的网络配置，也不自动绕过用户的代理。

公开元数据
的在线响应只保存在进程内存；精选目录属于只读编译输入。两者均无发行目录运行时写入，不影响签名及 Sparkle delta；资源复用 exclusion
将其登记为 `mcp-registry-metadata`，不存在可复制阶段。

## 考虑过的备选方案

### 保留正常加载更多按钮，或一次读取所有在线结果

目录是连续列表，手动逐页点击会打断浏览；一次读取全部结果则浪费网络并可能无限追逐异常 cursor。
因此只在视口接近尾部时使用现有有界分页，保留失败后的显式重试，不把自动续页误写成自动重试。

### 只复制一段 Lithe 配置，不做资源库

这是原页面已经有的能力，但用户真正缺的是“看清两个 Agent 各自注册了什么”和“改参数不用手改 dotfile”。只做复制无法解决重复和漂移。

### 解析后整体重写 JSON/TOML

实现最简单，但会丢失注释、键顺序和未知字段，`~/.claude.json` 还会被重排成巨大的单行或统一缩进。MCP 配置属于用户文件，不能接受这种副作用。

### 把第三方服务器也自动注册给 Agent

自动把全局服务器复制到项目会改变 Agent 的行为范围，还可能在用户不知情时启动不需要的服务器。首版只自动注册 Lithe 自己的、与当前项目授权绑定的 `lithe` 条目；第三方服务器由用户显式开关。

### 删除用户自己创建的条目

从资源库里看起来“关闭开关”就应该删除，但 Lithe 不是该条目的作者。直接删除会让用户在另一个工具里的配置无声消失，所以采用账本 + 接管所有权，而不是按名称盲删。

### 用定义哈希或最新共享账本替代草稿版本

定义哈希有意忽略 Codex 专属字段，适合合并列表，却无法证明完整配置未被外部改动。最新共享账本只能证明当前版本曾由 Lithe 写入，不能证明用户打开编辑器时看到的也是当前版本；若把草稿旧哈希和最新账本放在同一组备选授权里，只需任意一个匹配就会放过过期编辑。因此使用两类哈希，并把草稿版本作为必须满足的独立前置条件；代价是旧账本需要显式重新接管，不能无提示升级。

### 把项目排除写进 `.gitignore`

`.gitignore` 是被团队共享和版本控制的文件，Lithe 不应替项目做提交决策。`.git/info/exclude` 是仓库本地配置，只影响当前克隆。

### 首版同时做 Windows

Windows 的 Agent 配置路径和 Tauri 侧文件访问模型不同，同步实现会拉长验证周期。用户确认 macOS 先行，Windows 先在能力矩阵中标记为平台专属。

## 后果

- 收益：两个 Agent 的 MCP 配置有了单一可读视图；编辑只改目标条目并留有备份；Lithe 的 Maven 工具在项目授权开启时自动可用；所有破坏性操作都以账本为前提。
- 代价：资源库依赖 Core 的编辑能力，新增 Agent 格式需要在 Core、端口、适配器和 UI 四处接入；项目级条目在资源库中只读，用户需要理解两段页面的分工；每次保存都会生成一份配置文件备份，需要后续考虑清理策略。
- 约束：运行时仍然不能向 app bundle、安装目录写入任何内容。备份、临时文件和锁只在 Application Support 或项目工作区中创建。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter "McpRegistryTests|ScrollLoadTriggerTests"`：原生视口与实际 SwiftUI 宿主覆盖离屏不请求、接近尾部预取、短内容、尺寸变化、偏移保持、同页去重和卸载；模型覆盖失败后停止、显式同 cursor 重试、循环/空页停止、在途去重以及查询/路由隔离。普通测试不访问网络，不能代替目标网络环境下的官方目录验收。

- `LITHE_MCP_PROBE_INTEGRATION=1 ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --max-seconds 45 -- --filter McpArgumentRoundTripTests`（显式联网验收 Context7 的真实工具列表、原生大栈线程、取消前启动保护、精确参数、独立工具规则和过期文件保护；普通测试不依赖公网）
- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-agent-host --report .artifacts/test-stability/mcp-tools-host.json`（本地 stdio、HTTP JSON/SSE 响应、分页、超大响应拒绝、虚拟超时及取消后进程回收）

- `./scripts/macos/test/test-macos.sh --filter "McpRegistryTests|McpServerLibraryTests"`：离线首页零网络请求、失败保留精选、显式选择路由和路由间分页隔离、精选与在线连接去重，Registry 桥接、分页、取消、旧请求淘汰，JSON 预览不写文件也不取得所有权；原生卡片浅色/深色下在 420 与 780 点宽度重排，截图写入 `.artifacts/mcp-discovery/` 供人工检查。
- `LITHE_RUN_MCP_REGISTRY_INTEGRATION=1 ./scripts/macos/test/test-macos.sh --filter McpRegistryIntegrationTests`：可选联网集成，通过生产 adapter 显式直连官方目录并分页；普通单元测试不依赖公网。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core mcp::registry::`：精选目录无需网络且草稿固定版本，元数据夹具、失效记录、动态输入、危险链接和大小上限。
- `node --test scripts/resources/test-reuse-worktree-resources.mjs`：进程内目录元数据不得跨 worktree 复用。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core mcp::`（覆盖删除首项/中间项/末项、同行相邻项、值跨多行且下一个键同行的布局、单行与混合换行布局，JSON 输出重新解析，重复 JSON 键拒绝编辑；Codex 更新保留 `bearer_token_env_var`、`startup_timeout_sec`、未知键、建模键与值的注释、未变化的 args 数组内注释和非字符串 env 值，变量列表清空时也保留非字符串值；内联 `mcp_servers` 表可删除、可编辑；拒绝重复变量键；哈希忽略当前传输不写入的 command/args/env/url/headers 且与重解析一致；重命名保留专属字段）
- `./scripts/macos/test/test-macos.sh --filter McpServerLibraryTests`（覆盖计划后磁盘变化拒绝写入、文件在计划后出现拒绝创建、linked worktree 公共排除文件、关闭会话后仍能清理项目注册、项目切换后清理两个项目的注册、Git 排除失败不回滚账本、注销冲突写入错误横幅、重复变量键校验、重命名外部条目、按 Agent 开启时忽略传输不写入的字段、切换传输方式丢弃隐藏字段后仍保持所有权、重命名保留 Codex 字段、自然排序条目的所有权、两个窗口合并账本）
- `./scripts/macos/test/test-macos.sh --filter "McpWriteProtectionTests|FileStorageReplacementTests|McpFeatureBatchFailureTests"`（备份完成后外部保存被保留并返回 `changedOnDisk`，预检后出现的新文件不被覆盖；`MacFileStorage.replaceData` 拒绝过期快照、按匹配快照原子发布、拒绝覆盖已存在文件；`removeData` 只删除匹配快照的文件；失败/成功路径都不遗留临时文件；临时文件从创建起为 `0600`；回滚换出更新保存或无法恢复时保留并报告路径；不支持交换的卷拒绝写入和删除）
- `./scripts/macos/test/test-macos.sh --filter "McpBatchTransactionTests|McpServerSummaryTests|McpExcludePreservationTests"`（用第二次写入前的同步故障注入覆盖已有文件恢复、新文件删除、回滚保留外部修改与路径提示、失败保存和注册不发布账本；摘要不含 args 或 URL 凭据；exclude 原始非 UTF-8 字节保留、LF/CRLF 幂等及已有文件读取失败保护）
- `./scripts/macos/test/test-macos.sh --filter "McpArgumentRoundTripTests|McpSymlinkConfigurationTests"`（Codex 与 Claude 只改 env 时保留空参数、空白参数和嵌入换行；修改参数文本保留空行；相对及绝对符号链接可读取、生成计划、保存和备份，后续写入失败恢复链接目标，目标外部修改不覆盖，错误展示原路径并保留大小上限）
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter "McpServerLibraryTests|McpSymlinkConfigurationTests|McpWriteProtectionTests|FileStorageReplacementTests|McpFeatureBatchFailureTests"`（双窗口顺序保存，分别覆盖旧编辑器未刷新和刷新后可见字段恰好等于新版本的情况；认证或超时字段外部变化后阻止旧草稿保存、重命名、关闭开关、删除与关闭项目清理；双 Agent 合并条目使用各自的来源版本；旧账本重新接管前拒绝自动删除；同一编辑器内接管后关闭对应 Agent 可以保存；重复注册不接管外部新增的超时配置，保留原账本）
- `./scripts/macos/test/test-macos.sh --filter IdeCapabilitiesTests`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`
- 实机：无项目时打开设置 → MCP，确认 Codex/Claude 已有服务器被列出；编辑 env 并保存，确认原文件注释和未知键保留、备份生成；按 Agent 关闭外部创建的条目会被拒绝，接管所有权后可移除。
- 实机：打开项目并启用 MCP，确认 `~/.claude.json` 项目条目和 `<项目>/.codex/config.toml` 写入，`.git/info/exclude` 包含 `.codex/config.toml`；禁用后条目清理，外部改过的条目保留并提示。

## 适用范围

- 适用于 macOS 设置页、Codex/Claude Code 的全局与项目级 MCP 配置，以及未来新增 Agent 的同类接入。
- 不适用于 Lithe 自身 MCP host 的权限模型，也不改变 `lithe-mcp` 暴露的工具集合。
- Windows 待实现；在实现前不要复用 macOS 的路径解析假设。
