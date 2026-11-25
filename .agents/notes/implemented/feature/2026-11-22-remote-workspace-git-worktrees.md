# Agent 笔记：远程工作区里打开和新建 Git 工作树

状态：已实现

## 先说结论

受信任的远程工作区里，Git 工具窗口“工作树”页签的打开和新建不再被拒绝。打开工作树就是打开主机上的另一个文件夹：Lithe 用打开这个工作区所用的完整连接再连一次，包括本机容器、SSH 主机上的容器和 WSL 发行版里的容器，在本窗口的新标签页里经一个新会话打开它；已有标签页通过活着的会话打开着它时，直接切过去，不再连接。新建对话框显示和接收主机路径，Core 的“放在仓库旁边”的建议也以主机路径显示，创建由主机上的 Git 完成。“在新窗口打开”和“在文件浏览器中显示”仍然拒绝：新客户端只打开本机文件夹（#2231 S10），文件夹也不在本机。

## 问题

工作树列表、锁定、解锁、删除在 #2283 已经走主机，但打开和新建被拒绝，原因有三：

- 工作树是主机上的另一个文件夹，打开它需要一个绑定到那个文件夹的会话；远程工作区的会话只绑定一个主机根目录（`RemoteWorkspace` 的 RemoteRoot），不能拿来打开别的文件夹。
- 新建对话框的建议路径由 Core 的 `git.worktreePreview` 按仓库路径推算。远程工作区的仓库路径是本机占位路径，建议出来的也是本机占位目录旁的路径，Core 再把它映射回主机时会落到错误的位置，Windows 上还会被当成本机路径。
- 用户在对话框里输入的是主机路径（POSIX），在 Windows 客户端上不是绝对路径，Core 会以“不是绝对路径”拒绝。

## 决策

### 打开工作树 = 用同一个连接打开另一个主机文件夹

- `openWorktree` 在远程工作区里改走 `openRemoteWorktree`：把列表里的占位路径换回主机路径（`remoteplaceholder.HostPath`），再交给 `openRemoteHostFolder`。换不回来说明列表过期，记为拒绝（`not_host_path`）并重新读取列表。
- `openRemoteHostFolder` 先按占位根 `Root(anchor, connectionID, folder)` 查找已有标签页，会话还活着就切过去。否则打开“远程开发”窗口并记下 `remoteReopen`（工作区身份、完整连接与显示名、主机文件夹）；窗口读完已保存的连接后，`connectRemoteReopen` 沿完整连接打开这个文件夹。连接步骤、OpenSSH 的提问、从未决定过的文件夹的信任询问都和手动打开一样出现在窗口里。
- 容器连接必须保留“从哪里进入容器”和“进入哪个容器”两部分。例如 SSH → Docker 的工作树仍经原 SSH 主机进入原容器；只保留已保存连接 ID 会丢掉容器，只保留容器身份会误连本机引擎。容器身份拼在工作区身份末尾，不是单独的已保存 SSH 条目；检查连接是否被删除时使用外层 SSH 条目的 ID。
- 连接已经在工作区打开之后被删除时，窗口说明原因（`desktop.remote.worktree.connectionRemoved`），记为拒绝（`connection_removed`），不连接。
- 新建对话框的“创建后打开”沿用同一条路径。

### 对话框里的主机路径都用“占位目录旁”的路径发给 Core

- `remoteplaceholder.HostNamedPath(root, host)` 把任何主机绝对路径映射为占位根旁 `.lithe-remote-host` 下的本机路径，Core 收到后按工作区绑定映射回主机。对话框发给 Core 的仓库路径、目标路径和上一次建议都用它（`worktreeHostNamed`），所以 Core 按“仓库路径”推出的建议也在 `.lithe-remote-host` 下，显示前再换回主机路径（`worktreeShown`）。Core 的建议规则和路径映射规则都不用改。
- 这样 Windows 和 WSL 上的主机路径也是本机绝对路径，不会被 Core 当作相对路径拒绝。
- 对话框在输入框下说明路径是主机上的文件夹（`desktop.remote.worktree.destination`）。

### 日志

只记 `git.worktree.open`、`remote.connect` 等动作和 `git_worktree_open` 的拒绝原因，不记主机、连接名、主机路径或用户输入的路径。

## 考虑过的备选方案

- **在当前会话里切换主机根目录**：一个窗口里同时会有两个文件夹的请求，绑定的 RemoteRoot 要随请求变化，监听、索引和信任都按根目录缓存，改动面大且容易串。没有采用；每个文件夹一个会话，和手动打开完全相同。
- **不经过连接窗口，后台直接连接**：OpenSSH 的提问、连接步骤和信任询问都在连接窗口里，后台连接要么另做一套界面，要么吞掉提问。没有采用。
- **让 Core 接收原始主机路径**：要给 `git.worktreePreview`、`git.createWorktree` 加一个“这是主机路径”的字段，且 Core 现有的路径映射只认本机路径。`HostNamedPath` 复用已有映射，不改协议。
- **仅用连接 ID 重新查找工作树的连接**：本机容器没有已保存连接，SSH 或 WSL 容器的身份也不是已保存条目的 ID，结果会被当作已删除连接或连接到容器外。保留当前工作区的完整连接，并继续检查外层 SSH 条目是否存在。
- **在新窗口打开远程工作树**：新客户端只接受本机文件夹（S10），要支持就得把连接和会话交给另一个进程。保持拒绝。

## 后果

- 收益：远程工作树和本机工作树的操作基本一致；不改 Core 协议；Windows 和 WSL 的路径问题一并解决。
- 代价：每打开一个工作树多一个 SSH 会话（同一连接复用 OpenSSH 的设置，但不复用会话）；打开时会出现连接窗口。
- 未完成：远程 Git 的 AskPass 转交（推送、拉取时的凭据询问）；“在新窗口打开”仍拒绝。

## 验证

- `desktop/internal/workbench/remote_worktree_test.go`：工作树在新标签页经自己的会话打开，再次打开时切到已有标签页；`TestRemoteWorktreePreservesContainerHops` 验证本机、SSH 和 WSL 容器保留完整连接，外层 SSH 条目被删除时不进入容器；不是主机路径的条目和已删除的连接都被拒绝并说明；新建对话框建议并接收主机路径，创建请求在工作区会话上发送 `HostNamedPath` 路径并选中新工作树；日志不含主机和路径。
- `desktop/internal/remoteplaceholder/remoteplaceholder_test.go` 的 `TestHostNamedPathNamesEveryHostPathBelowTheSibling`。
- `desktop/internal/workbench/remote_worktree_visual_test.go` 生成 `docs/assets/remote-worktrees/` 下的截图。

```bash
cd desktop && ../scripts/desktop/desktop-go.sh test ./internal/workbench ./internal/remoteplaceholder -run 'TestRemoteWorktree|TestHostNamed' -count=1
```

## 适用范围

`desktop/internal/workbench/remote_worktree.go`、`gitworktree.go` 中远程分支、`remote.go` 的 `reopen`、`desktop/internal/remoteplaceholder/`。以后其他“打开主机上另一个文件夹”的入口（例如 Dev Container 里的文件夹）都走 `openRemoteHostFolder`，不要另起连接流程。
