# Agent 笔记：远程端口窗口记住标签、转发和规则，重连或重新打开后恢复转发

状态：已实现

## 先说结论

远程工作区的“端口”窗口会把以下内容记在本机：用户手动添加的端口、选过的本机端口、行和规则的标签、没停的本机转发，以及在主机上启动过的转发规则。

- 本机转发（T1、T2）：每次接上会话（打开工作区、断线重连）时，由 Core 的 `remote.restoreForwards` 按记录重新转发，沿用当初的本机端口和对非回环目标的确认（S28）。
- 转发规则（T3、T4）：只记住，从不自动启动。行尾“启动”把规则填进“添加转发规则”，由用户再提交，所有询问都重新问一遍；“忘记”删除记录。
- 监听主机全部网卡从不记住（S27），再启动时按回环地址填入。

记录文件是本机偏好目录下的 `remote/ports.json`。路径和大小上限由 Core 给出，内容由 Core 校验，并按连接目标和主机上工作区的真实路径分组。所以另一台主机、另一个账户、容器或文件夹都看不到这份记录。

## 问题

Issue #2231 §8 要求端口窗口像 VS Code 的“端口”视图那样：用户转发过的端口在重连后接着用，标签不丢。

#46a 之前的端口窗口只在工作区打开期间记住这些内容。断线重连后所有转发都消失，用户要一条条重新转发。手动添加的网址和本机端口选择也要重新输入。

同时有两条安全约束：
- 不能因为“记住”而在用户不知情时让主机监听端口。规则在主机上监听，记住后自动启动就等于绕过 S27、S29 的逐次确认。
- 记录里有主机地址、端口和用户输入的标签。它们只能留在本机，不能写进日志、主机或应用包。

## 决策

### 存储归 Core，文件读写归桌面端

- Core #163 提供 `remote.portRecords`（读取并告诉桌面端存储位置）、`remote.editPortRecords`（对文本做一次编辑，返回新文本）、`remote.restoreForwards`（按文本重新转发）。Core 负责校验、分组和规范化：回环地址的各种写法记成同一行，网址的查询和片段不记（可能带令牌），空记录删除，标签最多 64 个字符且不含控制字符。
- 桌面端的 `desktop/internal/remoteconn/ports.go` 只做文件读写：先问 Core 存储位置，用 `configfile` 读出字节，交给 Core，再把 Core 返回的新文本整体原子替换回去。替换前确认文件还是读到时的字节，不是就返回 `ErrConflict`，由上层重读后重试，最多 3 次。
- 文件只在第一次修改时创建，读取不创建任何东西。它和远程偏好一样不写主机、工作区、应用包或安装目录，所以不影响代码签名和 Sparkle 增量更新，也不跨工作树复制。

### 窗口只写变化的部分

- 窗口在内存里保留当前状态（标签、本机端口、没停的转发、规则），`ports.written` 是 Core 上次报告的记录。
- `recordEdits()` 比较两者，每个不同的行或规则生成一条编辑。所以停止、移除、改标签、规则启停都只写变化的部分，不会覆盖另一个窗口同时写入的其他行。
- 同一时间只跑一次读写（`recordsBusy`）。结束时只有期间又改过（`recordsRevision` 变了）或接上了新会话才再同步一次。这样 Core 规范化后与窗口不同的内容不会引起循环写入。

### 每次接上会话都恢复

- 打开工作区和断线重连都会设置 `recordsAttach`。下一次同步先写出断线期间的修改，再读记录，最后调 `remote.restoreForwards`。
- 刚打开的工作区把读到的记录并入窗口（`merge`，只填窗口还没有的）；重连时窗口的内存状态优先。
- 某条转发没能重新开始时，这一行标为失败，显示 Core 的原因，并忘掉“没停”这个状态。窗口顶部说明有几条没能恢复。其余转发照常恢复。
- 会话在恢复期间断开就按断线处理，下一个会话接上时再恢复一次。

### 损坏的文件从不覆盖

Core 解不开的文件（`CodeParseFailed`、超出大小、编码不对）一律当作 `ErrDamaged`：
- 窗口说明文件无法读取；
- 之后的修改只留在内存里，`ports.written` 保持为空，所以不会生成任何编辑；
- 文件的字节保持原样，用户可以手动修好或删除。

没有用户偏好目录（`ErrUnavailable`）时，记录只留在内存里，和远程偏好一样不记日志。

### 日志

日志只记以下内容：
- 动作 `remote.ports.label`、`remote.ports.ruleStart`、`remote.ports.ruleForget`；
- 失败的操作名 `remote_port_records`、`remote_port_restore`，以及 Core 错误码；
- 标签对话框拒绝时的 `remote_port_label` 和 `invalid_label`。

日志不记主机、标签、端口、网址或转发地址（S30）。测试用 `loggedAny` 检查这几项都不在日志里。

## 考虑过的备选方案

- **规则也在重连后自动启动。** 被否：规则让主机监听端口，S27、S29 要求每次都确认，自动启动等于跳过确认。VS Code 也只自动恢复本机转发。
- **把记录写进 `remote/preferences.json`。** 被否：偏好是用户在设置页改的少量配置，端口记录按工作区分组、改动频繁，混在一起会让两边的写入互相冲突，也让偏好文件变大。
- **记录存在主机上（工作区或主机的配置目录）。** 被否：多个用户可能共用同一个主机账户或工作区，标签和本机端口是这台电脑的用户自己的选择；而且容器重建后主机侧的文件会消失。
- **每次修改都把整份记录写一遍。** 被否：两个窗口打开同一个工作区时，后写的会覆盖先写的其他行。按差异逐条编辑，再加读到字节的比较，冲突时只重做自己的那几条。
- **损坏时用空记录覆盖重建。** 被否：用户手改坏的文件里可能还有其他工作区的记录，覆盖等于静默删除。

## 后果

- 收益：
  - 断线重连和重新打开后，用户的转发自动回来，标签和规则也还在；
  - 规则仍然每次都确认，安全约束不变；
  - Windows 和 macOS 共用同一份 Go 代码，记录格式和校验由 Core 统一。
- 代价：
  - 每次接上会话多一次读文件和 `remote.restoreForwards` 往返；
  - 没能恢复的转发会被忘掉，用户要重新转发一次；
  - 记录按工作区的真实路径分组，主机上移动或重命名文件夹后旧记录不再生效（也不会被清理）。
- 真实 SSH 主机、Windows 和 WSL 上的整机验收在后续阶段完成。

## 验证

- `desktop/internal/workbench/remote_port_records_test.go`：
  - 标签、没停的转发和规则写进文件，关闭再打开后标签还在、转发自动恢复、规则列为未运行；“启动”只填对话框不直接启动；含制表符的标签在对话框里被拒；空标签删除；日志不含主机、标签和端口；
  - 重连后没能恢复的转发标为失败、显示 Core 的原因并被忘掉；
  - 损坏的文件从不覆盖，修改只留在内存。
- `desktop/internal/workbench/remote_ports_test.go` 的 `TestRemotePortsStartTheForwardsLeftRunningAgainAfterAReconnect`，以及 `remote_port_rules_test.go` 中停止后忘记、重连后不自动启动规则的断言。
- `desktop/internal/remoteconn/ports_test.go`：读取不创建文件，只写记录文件，没变化的编辑不写，读到后被改过的文件返回冲突，损坏、断线和没有偏好目录各自报告。
- `desktop/internal/core/remote_session_test.go`：三个新命令对未知会话返回 `connection_closed`。
- `remote_ports_visual_test.go` 生成 `docs/assets/remote-ports/` 的编辑标签、标签列和重新打开后的截图。

```bash
scripts/desktop/desktop-go.sh test -count=1 -run 'TestRemote|TestPortRecords|TestDamagedPortRecords' ./internal/workbench ./internal/remoteconn ./internal/core
```

## 适用范围

本 Note 覆盖以下代码：
- `desktop/internal/core/remote_port_records.go`；
- `desktop/internal/remoteconn/ports.go`；
- `desktop/internal/workbench/remote_port_records.go`；
- `desktop/internal/workbench/remote_ports.go`、`desktop/internal/workbench/remote_ports_view.go`、`desktop/internal/workbench/remote_port_rules.go`、`desktop/internal/workbench/remote_port_rules_view.go` 中标签列、标签对话框、记住的规则和会话接上时恢复的部分。

以后端口窗口新增需要跨会话保留的内容时，先在 Core 的端口记录里加字段，再让桌面端通过 `recordEdits()` 写差异。不要在桌面端另存一份文件。
