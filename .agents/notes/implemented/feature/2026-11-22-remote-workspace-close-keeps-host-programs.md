# Agent 笔记：关闭远程工作区时确认远端进程，保留的会话下次接回

状态：已实现

## 先说结论

关闭远程工作区的窗口、标签、项目，退出 Lithe，或在同一窗口打开别的文件夹时，只要主机上还有 Lithe 为这个工作区启动的终端或进程，就先问用户：结束它们、保留在远端，还是取消。勾选“记住我的选择”后不再询问，只能在“设置 › 工具 › 远程工作区”的“关闭时的远端进程”改回。

选择保留时，主机上的会话继续运行；接回它所需的恢复凭据（会话键、令牌和经过核验的目标绑定）按连接存进系统密钥存储。下次连接时，Core 先核验本次实际连接的目标，匹配后才尝试接回，并列出上次保留的进程，让用户结束它们或继续运行。

开发者要记住三件事：
- 会话令牌只能进系统密钥存储，不能写进偏好文件或日志。
- 保留失败时一律按“结束”处理，并且要告诉用户。
- 进程名称和命令只在对话框里原样显示，不写进日志。

## 问题

Issue #2231 §9.1、§9.2 和 S33、S35 要求：关闭远程工作区不能悄悄结束用户在主机上跑着的程序（例如长时间的构建或 `npm run dev`），也不能悄悄留下用户找不到的程序。

原来的做法是“断开并关闭”直接结束主机会话。退出 Lithe 时也是关闭所有远程会话。这样用户的进程会被直接结束。

反过来，如果只是不结束进程，又会带来两个问题：
- 下次连接拿不到原来的会话，进程只能等主机的空闲超时结束；
- 用户也看不到哪些进程还在跑。

## 决策

### 什么时候问、问什么

- 询问放在本机的退出确认之后、拆掉项目之前。本机退出确认覆盖运行中的任务和忙碌的本机终端；拆项目会关闭工作区的终端，关掉终端就会挂断主机上的 shell。
- 先经 Core 的 `remote.runningPrograms` 读取主机进程。列表为空就直接结束；读取失败也照常结束，并记一次失败。不能因为读不到列表就把用户困在窗口里。
- 对话框原样列出每个进程的类型、名称、命令和已运行时长，不脱敏。这和本机退出确认弹窗的约定一致。
- 按钮依次是“取消”“保留在远端并关闭”“结束并关闭”，默认按钮是“结束并关闭”。“记住我的选择”旁有 ⓘ，说明在哪里改回。
- 记住的选择经 Core 的 `remote.editPreferences`（`closePrograms` 字段）写进同一份 `remote/preferences.json`，设置页读回同一个字段。这样不会有第二份影子配置。

### 保留怎么做

- 先停掉工作区自己的监听、Git 观察和端口转发，再从绑定上解开会话（`binding.Detach()`），让工作区不再向主机发任何请求。然后再拆项目，这样关闭终端不会挂断主机上的 shell。
- **先存凭据，再让主机保留。** 存不下或者主机没给令牌时，改为 `remote.disconnect` 带 `programs=end`，并通知用户“无法保留”。否则主机会保留一个以后谁也接不回的会话。
- 主机明确回答没有保留（`kept=false`）时忘掉这条凭据，并通知用户。主机没回答时凭据留着：主机可能已经保留了，下次连接发现主机上没有这个会话再忘掉。
- 连接在保留前已经断开时，按结束处理并提示。没人接回的会话会在主机的空闲超时（Core 的 `closing.idleTimeoutSeconds`，默认 10 分钟）后结束，设置页只读显示这个时长。

### 凭据的存储与生命周期

`desktop/internal/remoteconn/kept.go` 负责凭据存储：
- **命名空间：** `@host/remote-sessions`。
- **每个连接一项：** 账户名是连接 id 的 SHA-256 前 128 位，所以密钥存储的列表里看不出主机或发行版名。
- **内容：** 秘密是该连接保留会话的 JSON 列表，最新的排在最后。
- **上限：** 每个连接最多 8 条，整项不超过 Windows 凭据管理器的 2560 字节。保留第 9 个会话时忘掉最旧的一条，那条会话的进程就只能在主机上手动结束。

凭据的生命周期如下：
1. 连接时取最新一条带绑定的记录作为 `resume` 发给 `remote.connect`；旧无绑定记录可以保留，但不自动外发。
2. 只有 Core 返回 `resumeConsumed=true` 才删除这条凭据。目标不匹配或无法核验时，Core 创建新会话且不发送旧令牌，原记录留给原目标；`resumed=false` 本身不能作为删除理由。
3. 接回后（`resumed=true`），打开文件夹时列出 `keptPrograms`。“结束这些进程”经 `remote.endPrograms` 只结束这些 ID，不动这次新开的。
4. 接回后没打开工作区就停止的连接，把会话再保留一次。这样进程不会在用户没选择的情况下结束。

### 日志

日志只记以下内容：
- 动作 `remote.close.cancel/keep/end` 和 `remote.kept.end/keep`；
- 失败的操作名，如 `remote_close_programs`、`remote_keep_programs`、`remote_kept_sessions`；
- Core 错误码。

日志不记连接名、主机、命令、进程名或令牌。

## 考虑过的备选方案

- **令牌写进 `remote/preferences.json` 或连接文件。** 被否：令牌是能接管主机会话的秘密，偏好文件可能被同步或备份。
- **只在内存里记住保留的会话。** 被否：退出 Lithe 再打开就找不到会话了，正好违背“下次连接列出保留的进程”。
- **先告诉主机保留，再存凭据。** 被否：存储失败时主机已经保留了一个没人能接回的会话，它的进程只能等空闲超时。
- **保留失败时保持窗口打开，让用户重选。** 被否：用户已经决定关闭。这时按结束处理并说明原因，比把窗口卡住更可预期；需要保留的用户可以修好密钥存储后再试。
- **记住的选择存在桌面端自己的设置里。** 被否：这样设置页和关闭逻辑会读两份配置；Core 的远程偏好已经是这些设置的唯一来源。

## 后果

- 收益：
  - 主机上的程序不会被悄悄结束，也不会被悄悄遗留；
  - 下次连接能看到并结束它们；
  - 令牌只在系统密钥存储里；
  - Windows 和 macOS 共用同一份 Go 代码。
- 代价：
  - 关闭远程工作区多一次 `remote.runningPrograms` 往返；
  - 每个连接只接回最新一条保留会话，更早的要依次连接才能接回；
  - 超过 8 条时最旧的会话无法从 Lithe 接回。
- 本次以本机真实 OpenSSH 验证同目标恢复、别名改绑、旧记录和 ProxyCommand 保守处理；有效第二账户、ProxyJump、Windows 与容器的完整工作流仍待验收。身份日志写入尚未有界，相关 PR 保持 Draft，不能据此宣称可发版。

## 验证

- `desktop/internal/workbench/remote_close_test.go`：
  - 主机没进程时不询问；
  - 有进程时询问，取消后保留窗口；
  - 保留后下次连接接回并列出进程，只结束列出的进程；
  - 接回但没打开工作区时再保留；
  - 记住选择后不再询问；
  - 凭据存不下时结束并提示；
  - 列表读取失败时照常关闭。
- `desktop/internal/remoteconn/kept_test.go`：最新一条优先、同键替换与忘掉、超过上限时忘掉最旧的、解不开的秘密读作空列表。
- `desktop/internal/settingswindow/remote_workspace_view_test.go` 的 `TestRemoteWorkspaceClosingChoiceIsAppliedAndRestored`：设置页写入并读回关闭选择。
- `remote_close_visual_test.go` 生成 `docs/assets/remote-close/` 的截图，`remote_workspace_visual_test.go` 生成 `docs/assets/remote-settings/` 的关闭卡片截图。

```bash
scripts/desktop/desktop-go.sh test ./internal/workbench ./internal/remoteconn ./internal/settingswindow -run 'RemoteClose|Kept|RemoteWorkspace' -count=1
```

## 适用范围

本 Note 覆盖以下代码：
- `desktop/internal/workbench/remote_close.go`；
- `desktop/internal/remoteconn/kept.go`；
- `desktop/internal/workbench/remote_browse.go` 和 `remote_workspace.go` 中接回会话的部分；
- 设置页“关闭工作区”卡片。

之后运行、构建等会在主机上启动进程的功能，也必须让 Core 把进程登记进 `remote.runningPrograms`，才会出现在关闭确认里。不要在桌面端另记一份进程列表。
