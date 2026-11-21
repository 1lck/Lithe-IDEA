# Agent 笔记：远程开发连接窗口——已保存的连接与测试连接

状态：已实现

## 先说结论

欢迎页“更多”菜单和标题栏项目菜单里的“远程开发”会打开一个窗口：左边是保存的 SSH 连接，右边是选中连接的表单、“测试连接”和测试到的主机信息。连接列表由 Rust Core 定义格式和规则（`remote.connections`、`remote.editConnections`），桌面端只负责读文件、把 Core 生成的整份文档原子写回。窗口里不保存任何秘密：密码、私钥口令和主机指纹确认都由 OpenSSH 在测试时经 AskPass（Lithe 自己充当 `SSH_ASKPASS` 程序，把问题转回主程序）提出，和 Git 认证共用同一个提问框，答完即丢。

## 问题

Issue #2231 要求远程开发先能“告诉 Lithe 连哪台机器、怎么登录”，并在打开项目前确认这台机器能用。旧客户端做过一版（见已归档的 `archived/feature/2026-10-24-remote-ssh-connections.md`），但它把密码记进钥匙串、把整张列表当工作副本编辑，而且字段规则写在 Swift 里。Viva 桌面端重新实现时要解决：

- 字段规则（主机不能带 `user@`、端口范围、名称去重、最多 128 项）放在哪里，换 UI 壳子时不用重写；
- 保存时如果文件已被另一个窗口或手工改过，不能把别人的修改覆盖掉；
- 设计 S12 规定秘密只出现在 AskPass 的问题和答案里，S15 规定 Lithe 不读私钥内容。

## 决策

### 连接规则在 Core，文件读写在桌面端

- 字段的规范化、逐字段检查和文档格式都在 Core 的 `lithe_remote::client::connections`。Core 拒绝时返回 `{ field, reason }`，窗口把原因显示在对应字段下面，不弹通用错误框。
- `desktop/internal/remoteconn` 只做两件事：按 Core 给出的相对路径和大小上限，从平台偏好目录读取 `remote/connections.json`；把 Core 编辑后返回的整份文档，以“读取时的字节”为前提原子写回（`configfile`）。文件在读取之后被改过，写入就失败（`ErrConflict`），窗口提示重新读取，不会覆盖。
- 每次点“保存”或确认“删除”都立即写一次，并且写完重新读取文件来显示，不维护一份和磁盘不同的工作副本。打开窗口只读不写，没有文件时不会创建。

### 秘密不经过窗口

- 表单只有“认证方式”和私钥路径，没有密码框。私钥只保存路径，Lithe 不打开、不读取私钥文件，也不接受粘贴的私钥。
- “测试连接”调用 Core 的 `RemoteProbe`，Core 运行 PATH 里的 OpenSSH。OpenSSH 的每个问题（密码、口令、验证码、首次连接时的主机指纹确认）通过 AskPass 回到窗口，进入和 Git 认证相同的队列（`gitAuthState`），问题带 `Remote` 标记，只换标题、提示和回答用的 Core 方法（`RemoteAuthRespond`）。
- 取消提问、点“停止”或关闭窗口都会取消测试；被取消的测试不再追问，也不显示结果。

### 日志只记动作

窗口只记录 `remote.connections.open`、`remote.connection.new/select/save/remove/test/test.stop` 和 `remote.authentication.answer/retry/cancel` 等动作，以及 Core 的固定状态或错误码。主机、用户名、私钥路径、OpenSSH 输出、提问原文和答案都不进日志，`remote_test.go` 用 `loggedAny` 检查。

### 列表选中行跟着表单走

Viva 的 `ListState.Select` 只能选到列表上一帧已经声明过的行。保存一个新连接后，表单立刻编辑它，但列表这一帧还不认识新行，选中会被截到旧的最后一行。因此：行高亮直接按“表单正在编辑的连接”画；列表声明完行之后，再调用 `syncListSelection` 把键盘选中行同步过去。这是 Viva 的既定行为，不是缺陷，不在 Viva 侧改。

## 考虑过的备选方案

- **桌面端自己校验字段、自己定义 JSON 格式**：Go 里写一遍，将来换 UI 壳子还要再写一遍，和“通用逻辑进 Rust Core”的约定冲突。没有采用。
- **沿用旧客户端的“记住到钥匙串”**：用户少输一次密码，但秘密会离开 AskPass 的问答，违反 S12；而且记错的密码会被重复发送。没有采用。
- **把整张列表当工作副本编辑，关窗口时统一保存**：可以批量修改，但关窗口时要么丢修改，要么要再问一次；和“保存后重新读取显示真实来源”的设置规则也不一致。没有采用。
- **为远程连接单独做一个认证弹窗**：两个弹窗可能同时出现、互相遮挡。共用 Git 的队列后，同一时间只显示一个问题，按提出顺序逐个回答。

## 后果

- 收益：字段规则只有 Core 一份；Windows 和 macOS 用同一份 Go 代码；秘密只在 OpenSSH 和 AskPass 之间流动；并发修改不会互相覆盖。
- 代价：每次保存都是一次完整的读、改、写和重新读取；Core 没有返回字段的错误只能显示在窗口底部。
- Windows 上 OpenSSH 能否通过 GUI 子系统的 `lithe` 助手读到答案仍待实机验证；打开远程项目、文件夹选择和远端服务部署在后续阶段实现。

## 验证

- `desktop/internal/remoteconn/remoteconn_test.go`：读取不创建文件、冲突时不写入、损坏文件报 `ErrDamaged`。
- `desktop/internal/workbench/remote_test.go`：保存、改名、删除前确认；字段被拒绝时显示在字段下且不写文件；新保存的连接是列表选中行；测试时在窗口中回答密码并显示主机信息；停止和关窗口都会取消测试且不再追问；日志不含主机和用户名。
- `desktop/internal/workbench/remote_connections_visual_test.go` 生成 `docs/assets/remote-connections/` 下的截图。

```bash
scripts/desktop/desktop-go.sh test ./internal/remoteconn ./internal/workbench -run 'Remote|GitAuth' -count=1
```

## 适用范围

`desktop/internal/remoteconn/`、`desktop/internal/workbench/remote.go`、`desktop/internal/workbench/remote_view.go`，以及 `desktop/internal/workbench/git_auth.go` 中带 `Remote` 标记的提问。后续“打开远程工作区”“记住最近文件夹”都要通过同一个 `remoteconn` 和 Core 的 `remote.editConnections`，不要另存一份连接信息。
