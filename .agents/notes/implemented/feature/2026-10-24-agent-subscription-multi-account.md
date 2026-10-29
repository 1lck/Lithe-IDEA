# Agent 笔记：Claude 与 Codex 官方订阅多账号与手动切换

状态：已实现

## 先说结论

Claude 与 Codex 的官方订阅都可以保存多个账号。每个账号对应官方 CLI 的一个独立配置目录，
启动适配器时通过环境变量指向它：Claude 用 `CLAUDE_CONFIG_DIR`，Codex 用 `CODEX_HOME`；
登录、令牌保存和刷新都由官方 `claude auth login --claudeai` / `codex login` 完成。Lithe 只保存「显示名 + 目录路径 + 是否首选」，
以及适配器最近一次推送的邮箱、套餐和用量，不读取、复制、导入或刷新任何凭据。
切换账号只能由用户手动触发，额度耗尽时不会自动换号。

## 问题

用户有工作和个人两个 Claude 订阅时，只能在终端 `/logout` 再 `/login`，再回到 Lithe 重连；
两个账号的会话历史混在一起，也看不到各自的用量。搬运或改写凭据文件最容易触发账号风控，
所以不能让 Lithe 代替 CLI 管理登录。

## 决策

- **目录即账号。** 新账号的空目录建在 Application Support 的 `AgentAccounts/<agentID>/<UUID>`，
  不在 app bundle 或安装目录内，不影响 Sparkle 增量更新。默认账号不创建目录，沿用 CLI 自己的
  默认位置，已有用户无需迁移。
- **Host 只透传目录。** `AgentLaunch.claude_config_dir` 仅在 Claude 订阅模式下生效，
  `codex_home` 仅在 Codex 订阅模式下生效，都必须是绝对路径；相对路径会按适配器工作目录解析，
  可能悄悄选中另一个账号，所以直接报错。Codex 的额度查询和已归档历史会各启动一个 App Server，
  它们同样带上这个目录，否则会读到默认账号。
- **登录在后台运行，不弹终端。** 「添加另一个账号」创建目录后，通过进程运行器在登录 shell 里执行官方登录命令，
  环境里只多一个目录变量；浏览器由 CLI 自己打开。卡片显示「正在等待浏览器登录…」和取消按钮，
  取消或关闭设置页会终止命令，5 分钟未完成按超时处理。使用登录 shell 是为了拿到用户自己的 PATH，
  不去猜 CLI 安装位置。最初的方案是在内置终端里运行，但会打断用户当前的工作区，所以改为后台。
- **切换即重启。** 设为首选会停止当前项目的 Claude 连接，再用新目录启动。正在回复、新建会话、
  等待授权或有待处理的权限请求时拒绝切换，行为与切换供应商一致。
- **邮箱与套餐来自适配器。** 适配器初始化时推送 `_auth/status_update`，Host 在确认已登录后把其中的
  账号转成 `account` 事件。此前该事件只给 Codex 使用，Claude 的邮箱和套餐没有送到界面。Codex 的用量
  仍由 Host 已有的额度查询提供。
- **用量只是快照。** 账号卡片显示 5 小时和 7 天窗口的已用比例、重置时间、配速，以及
  「截至 <时间>，本次未主动刷新」。数据来自 `usage_update._meta["_claude/rateLimit"]`，Lithe 不调用
  Anthropic 接口，也不轮询。配速等于已用百分点减去窗口已过去的百分点：正值表示消耗快于匀速。
  窗口已重置后的旧数据不再显示重置时间和配速，也不会显示成健康的绿色。
- **标注按账号分开。** 收藏、重命名和隐藏的存储身份由 Agent id 扩展为 `<agentID>#<账号 UUID>`，
  默认账号保持原身份，原有标注原样可用。切换账号后重新读取标注。
- **移除只忘记。** 移除账号只删除 Lithe 里的记录，不删除目录：那里面是官方 CLI 的登录状态，
  Lithe 不应该删除或检查。

## 考虑过的备选方案

- **导入凭据文件或读取钥匙串：** 搬运凭据，风控风险最高，也超出原生支持。拒绝。
- **改写默认 `~/.claude` 的登录态来「始终登录首选账号」：** 需要改写 CLI 默认凭据，不是原生行为。拒绝。
- **Lithe 自己请求用量接口：** 需要读取 OAuth 令牌。拒绝；只显示适配器推送的快照。
- **额度耗尽时自动轮换账号：** 可能被视为绕过限额。拒绝，只允许手动切换。
- **「整窗 ≈ tokens / 金额」和曲线图：** 需要统计 `~/.claude` 下的会话记录，不属于官方推送的数据。本次不做。

## 后果

多账号完全依赖官方 CLI 的目录隔离。macOS 上不同 `CLAUDE_CONFIG_DIR` 的登录是否在钥匙串中互不覆盖，
需要用临时目录登录第二个账号后，只用 `claude auth status`（Codex 用 `codex login status`）确认原账号仍然登录，不读取凭据；
这一项尚未在真机验证，功能矩阵保持「待验证」。Windows 的 Host 已接受 `claudeConfigDir` 和 `codexHome`，
设置页和登录入口尚未接入。第三方产品提供 claude.ai 登录需要 Anthropic 事先批准，本功能只启动用户自己
安装并登录的官方 Claude Code，是否对外宣传由维护者决定。

## 验证

- `cargo test -p lithe-agent-host --lib`：目录透传、相对路径拒绝、已登录账号随事件发出。
- `AgentAccountTests`：配速计算、账号仅保存路径、观察值按账号保留、每个 Agent 只收到自己的账号目录。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`、`node scripts/i18n/generate-i18n.mjs --check`。

## 适用范围

- `rust/lithe-agent-host/src/claude_subscription.rs`
- `rust/lithe-agent-host/src/subscription.rs`
- `rust/lithe-agent-host/src/codex_history.rs`
- `macos/Sources/Lithe/Models/Settings/AgentAccounts.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+AgentAccounts.swift`
- `macos/Sources/Lithe/Views/Agent/AgentAccountsSection.swift`
- `macos/Sources/Lithe/Platform/MacOS/Agent/MacAgentAccountSignIn.swift`
- `macos/Sources/LitheAgentConversationModule/Application/AgentHistoryFeatureModel.swift`
