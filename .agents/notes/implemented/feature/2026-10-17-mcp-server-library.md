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
- `Core/Ports/McpConfigurationStore.swift` 是端口，`Platform/MacOS/MCP/MacAgentMcpConfigurationStore.swift` 是 macOS 适配器。适配器负责 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`、项目路径解析，1 MiB 上限、UTF-8 校验、原子替换、权限保留和备份。
- `Application/Features/McpServerLibraryFeatureModel.swift` 拥有合并、草稿、按 Agent 开关、保存/删除和账本。UI 只调用这个模型，不直接碰文件。

### 身份与合并

- 一个条目的身份是 `名称 + 规范化定义哈希`。同名但定义不同的条目会显示为两行并标记“Conflict”，编辑其中一行不会顺带改写另一行。哈希在计算时对 env/header 按键和值排序，因此写入路径与重新解析路径得到同一个哈希，不受 UI 排序方式影响。
- 同一个定义同时出现在 Codex 和 Claude Code 中时合并成一行，两个 Agent 胶囊分别显示开关状态。
- 项目级条目只读展示。它们由“Lithe IDE 访问”生命周期管理，不在资源库里直接编辑，避免用户以为改的是全局配置。

### 所有权账本

- 账本按“Agent + 作用域 + 项目路径”记录 Lithe 写过的 `名称 -> 定义哈希`，存放在 `settings.mcpServerRegistrations`。多个窗口共享同一个 store，因此每次读取都从共享账本取最新快照，写入时只替换当前文件对应的键，而不是把窗口初始化时的整份字典写回，避免一个窗口覆盖另一个窗口刚记录的条目。
- 只有磁盘上的哈希与账本一致时，Lithe 才会自动替换或删除该条目。用户自己创建的条目返回 `ownedByUser`，在 Lithe 之外被改过的条目返回 `externallyModified`；两者都保留原文件，并在页面上说明原因。
- 用户在 Lithe 里主动编辑并保存时，资源库会把页面上展示的那份定义哈希作为一次性的 `expectedHash` 并入校验；只有磁盘定义仍与展示一致才允许写入。这样“点进去改参数”不会被 `ownedByUser` 拒绝，同时外部改动仍会被检测到。删除和关闭 Agent 开关不走这个例外，必须先接管所有权，因为那是删除别人的配置，而不是修改它。
- 用户可以对一个外部条目执行“接管所有权”（Take ownership）：只写账本，不改文件。之后按 Agent 开关才能真正移除它。这个动作是显式的，因为“删除别人的配置”和“让 Lithe 以后管理这份配置”是两件事。

### 保格式编辑

- Claude JSON 使用基于字节偏移的插入/删除，只改动 `mcpServers.<name>` 或 `projects.<path>.mcpServers.<name>`，其余内容逐字节保留。删除条目时只有目标键前缀全为空白才扩展到行首，避免连带删除同一行的相邻条目；删除最后一个条目时同时删除前导逗号，并在返回计划前重新解析结果，避免写出丢失条目的半截配置。带注释或非严格 JSON 的文件拒绝写入，而不是冒险整体重排。
- Codex TOML 使用 `toml_edit`，保留注释、表顺序和未知键。新增本地依赖 `toml_edit = "0.25"` 就是为此；原有的 `toml` 只能解析。更新已有服务器时只修改 Lithe 建模的 `command`、`args`、`env`、`url`、`http_headers`，`bearer_token_env_var`、`startup_timeout_sec`、`tool_timeout_sec` 等 Codex 专属字段和注释原样保留；`env`/`http_headers` 中无法在本库表示的非字符串值也不会因为一次编辑被删掉。重命名时先把原表整体迁移到新名称再应用建模字段，专属字段随条目一起移动；Claude JSON 重命名同样以旧条目为底稿覆盖建模键。
- 一次保存会先把每个目标文件的计划全部算完，再统一写盘。第二个 Agent 的冲突不会让第一个 Agent 留下半套修改。写盘前会携带计划所依据的磁盘快照重新读取并比对；其他 Agent、编辑器或另一 Lithe 实例在此期间保存过配置时，整个提交以 `changedOnDisk` 拒绝，而不是用旧计划覆盖新内容。
- 每个被改写的文件都会先备份到 `Application Support/MCP Backups/<时间戳>/`，备份失败则中止写入。

### Lithe 自己的项目级注册

- 开启“Lithe IDE 访问”时，`IdeCapabilitiesFeatureModel` 把 host 返回的 `lithe` 服务器命令和参数转交给资源库。资源库写入：
  - Claude Code：`~/.claude.json` 的 `projects.<项目绝对路径>.mcpServers.lithe`；
  - Codex：`<项目>/.codex/config.toml` 的 `[mcp_servers.lithe]`。
- 只写项目级，不写全局。项目关闭或授权关闭时，按账本删除 Lithe 写入且哈希未变的条目。`WorkspaceSessionCoordinator` 会在关闭回调前清空会话 URL，因此资源库在注册时记住工作区，并在注销时使用该身份，避免项目已关闭却找不到要清理的配置。
- 如果 Codex 项目配置文件是 Lithe 新建的，会把 `.codex/config.toml` 追加到 `.git/info/exclude`，不修改被版本控制的 `.gitignore`；用户自己创建过该文件时不加排除规则。linked worktree 的排除文件位于公共 Git 目录，资源库读取 `commondir` 后写入那里，而不是写入 `worktrees/<name>/info/exclude`。
- 外部改过的项目条目不会被删除，页面显示“需要处理”的原因，账本保留，以便下次仍能识别。

### 密钥与健康检查

- env 和 header 值在 UI 中用 `SecureField` 遮蔽，但配置文件中仍是明文；页面明确写出这一点，不制造“已经加密”的错觉。
- 错误消息、日志和 Core 返回值都不回显配置内容。解析失败只报告文件路径和错误类型。
- 首版不自动启动 MCP 服务器做健康检查。启动服务器会执行用户配置的命令，资源库只负责配置，不在用户没有要求时执行项目代码。

## 考虑过的备选方案

### 只复制一段 Lithe 配置，不做资源库

这是原页面已经有的能力，但用户真正缺的是“看清两个 Agent 各自注册了什么”和“改参数不用手改 dotfile”。只做复制无法解决重复和漂移。

### 解析后整体重写 JSON/TOML

实现最简单，但会丢失注释、键顺序和未知字段，`~/.claude.json` 还会被重排成巨大的单行或统一缩进。MCP 配置属于用户文件，不能接受这种副作用。

### 把第三方服务器也自动注册给 Agent

自动把全局服务器复制到项目会改变 Agent 的行为范围，还可能在用户不知情时启动不需要的服务器。首版只自动注册 Lithe 自己的、与当前项目授权绑定的 `lithe` 条目；第三方服务器由用户显式开关。

### 删除用户自己创建的条目

从资源库里看起来“关闭开关”就应该删除，但 Lithe 不是该条目的作者。直接删除会让用户在另一个工具里的配置无声消失，所以采用账本 + 接管所有权，而不是按名称盲删。

### 把项目排除写进 `.gitignore`

`.gitignore` 是被团队共享和版本控制的文件，Lithe 不应替项目做提交决策。`.git/info/exclude` 是仓库本地配置，只影响当前克隆。

### 首版同时做 Windows

Windows 的 Agent 配置路径和 Tauri 侧文件访问模型不同，同步实现会拉长验证周期。用户确认 macOS 先行，Windows 先在能力矩阵中标记为平台专属。

## 后果

- 收益：两个 Agent 的 MCP 配置有了单一可读视图；编辑只改目标条目并留有备份；Lithe 的 Maven 工具在项目授权开启时自动可用；所有破坏性操作都以账本为前提。
- 代价：资源库依赖 Core 的编辑能力，新增 Agent 格式需要在 Core、端口、适配器和 UI 四处接入；项目级条目在资源库中只读，用户需要理解两段页面的分工；每次保存都会生成一份配置文件备份，需要后续考虑清理策略。
- 约束：运行时仍然不能向 app bundle、安装目录写入任何内容。备份、临时文件和锁只在 Application Support 或项目工作区中创建。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core mcp::`（覆盖删除首项/中间项/末项、同行相邻项、单行与混合换行布局，JSON 输出重新解析；Codex 更新保留 `bearer_token_env_var`、`startup_timeout_sec`、未知键、注释和非字符串 env 值；重命名保留专属字段；写入哈希与重新解析哈希一致）
- `./scripts/test-macos.sh --filter McpServerLibraryTests`（覆盖计划后磁盘变化拒绝写入、文件在计划后出现拒绝创建、linked worktree 公共排除文件、关闭会话后仍能清理项目注册、重命名保留 Codex 字段、自然排序条目的所有权、两个窗口合并账本）
- `./scripts/test-macos.sh --filter IdeCapabilitiesTests`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-agent-notes.sh`
- 实机：无项目时打开设置 → MCP，确认 Codex/Claude 已有服务器被列出；编辑 env 并保存，确认原文件注释和未知键保留、备份生成；按 Agent 关闭外部创建的条目会被拒绝，接管所有权后可移除。
- 实机：打开项目并启用 MCP，确认 `~/.claude.json` 项目条目和 `<项目>/.codex/config.toml` 写入，`.git/info/exclude` 包含 `.codex/config.toml`；禁用后条目清理，外部改过的条目保留并提示。

## 适用范围

- 适用于 macOS 设置页、Codex/Claude Code 的全局与项目级 MCP 配置，以及未来新增 Agent 的同类接入。
- 不适用于 Lithe 自身 MCP host 的权限模型，也不改变 `lithe-mcp` 暴露的工具集合。
- Windows 待实现；在实现前不要复用 macOS 的路径解析假设。
