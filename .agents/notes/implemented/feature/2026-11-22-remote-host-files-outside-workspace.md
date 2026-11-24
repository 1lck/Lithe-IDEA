# Agent 笔记：远程工作区按路径打开主机上的文件——工作区外只读

状态：已实现

## 先说结论

远程工作区状态栏连接菜单里的“打开主机上的文件…”从窗口顶部弹出路径框（对标 Zed 的 Open File 提示），输入 `~/` 或 `/` 开头的主机路径，边输入边经 `remote.readDir` 列出那一层的文件夹和文件。工作区文件夹里的文件照常可以编辑；文件夹以外的文件以只读方式打开（设计 S25），不能切换为可编辑，保存和新建都被拒绝。文件夹以外的文件用 Core 已有的占位路径表示（占位根旁的 `.lithe-remote-host/<主机路径>`），桌面端不另造一套路径。

## 问题

Issue #2231 的 R0 要求能打开工作区文件夹以外的主机文件（例如 `~/.bashrc`、`/etc/hosts`），用户定为“对标 Zed”。需要回答：

- 从哪里打开：项目树只列工作区文件夹，Search Everywhere 只搜工作区；
- 这些文件在本机怎样表示：编辑器、标签页、状态栏都以本机路径为键，而远程工作区的本机根是一个不能读写的空占位目录；
- 能不能编辑：文件夹外的文件不在信任范围内，也不在主机监听范围内，改了别人看不到冲突。

## 决策

### 单独的路径弹窗，不挤进 Search Everywhere

- 入口是状态栏连接菜单的“打开主机上的文件…”，没有会话时不可用。弹窗挂在窗口顶部，和 Search Everywhere 的位置一致，路径框默认 `~/`。
- 列表显示路径最后一个“/”之前的文件夹，按其后的文字不分大小写筛选名称开头，文件夹在前；只有输入以“.”开头时才列隐藏条目。上下键移动，Tab 补全，回车进入文件夹或打开文件，没有匹配时回车按输入的路径打开，Esc 关闭。
- 不用 Search Everywhere 的原因：它的第一个字符 `/` 已经被“操作”页签占用，主机路径正好都以 `/` 开头，混在一起会让 `/etc` 变成搜操作。

### 文件夹外的文件用 Core 的占位路径，只读打开

- 本机路径一律由 `remoteplaceholder.LocalPath` 求出：工作区内的在占位根下，工作区外的在占位根旁的 `.lithe-remote-host` 下。Git 返回的工作区外路径本来就用这个规则（见 `remoteplaceholder.Outside`），文件打开沿用它，所以标签页、Git 差异里同一个主机文件只有一个本机键。
- `document.hostOutside` 标记文件夹外的文档：打开时 `SetReadOnly(true)`，“切换只读”被拒绝并提示原因；`remoteDocuments.save/create` 对这类路径返回 `errRemoteReadOnly`，不发任何写请求。这是 S25 的落地：信任只覆盖工作区文件夹，文件夹外的文件不该因为打开了工作区就能改。
- 路径位于工作区内也不能只靠客户端的字符串判断：编辑器每次写入都把主机工作区根传给服务器，服务器相对已打开的目录句柄定位写入位置，拒绝根以下父目录或文件条目的符号链接。旧服务不支持这项检查时拒绝保存，不能退回无根目录的通用主机写入。通用主机文件 API 仍可显式写工作区外的路径，编辑器不能借它扩大保存范围。
- 状态栏导航路径显示 `~` 开头的主机路径（不暴露占位目录），复制路径菜单不提供“复制相对路径”，因为它不在项目里。
- 主机监听只覆盖工作区文件夹，文件夹外的文件不会收到变化通知；它们和其他文档一样在重连和关闭前与主机比对，没有编辑时重新载入。

### 远程工作区不提供“在文件浏览器中显示”

占位路径在本机不存在，标签页右键、Search Everywhere 结果和 Git 变更里的“在 Finder/资源管理器中显示”在远程工作区里总是失败（ENOTDIR）。这是这次顺手修掉的既有问题：远程工作区里直接不显示这一项，而不是点了报错。

## 正确与错误示例

正确：新功能要用主机上工作区外的路径时，经 `remoteplaceholder.LocalPath(p.root, remoteRoot, host)` 换成本机键，再判断 `p.remoteOutsideDocument(path)` 决定能否写。

错误：在桌面端拼 `filepath.Join(os.TempDir(), host)` 之类的本机路径，或者从占位路径里截字符串还原主机路径——前者会让同一个主机文件出现两个键，后者在 Windows 上会把 `\` 和盘符混进主机路径。

## 考虑过的备选方案

- 在 Search Everywhere 里加“主机文件”页签：被否，`/` 前缀冲突，而且它按项目索引搜索，不适合逐层浏览。
- 文件夹外的文件也允许编辑并带版本保存：被否，S25 要求信任边界之外只读；以后真有需要，应当由用户把那个文件夹作为另一个远程工作区打开并单独信任。
- 打开文件夹外的文件时扩大主机监听：被否，监听整个主目录或根目录代价太大，比对已经能在重连和关闭前发现变化。

## 后果

- 收益：工作区外的主机文件和 Git 返回的工作区外路径共用同一个本机键；信任边界之外不会被写；不用为它扩大主机监听。
- 代价：工作区外的文件只能看不能改，确实要改时需要把那个文件夹另开为远程工作区；主机上对它的修改要等重连或关闭标签前比对才发现。
- 列出文件夹每次都是一次 `remote.readDir` 往返，深层路径边输入边列出，网络慢时列表会短暂显示“正在加载”。

## 验证

- `desktop/internal/workbench/remote_host_files_test.go` 的 `TestRemoteOpenFileOnHost`：列表筛选、隐藏条目、进入文件夹、Tab 补全、工作区内可编辑、工作区外只读且保存/新建被拒、状态栏主机路径、非绝对路径提示、日志不含主机和路径。
- `desktop/internal/remoteplaceholder` 的 `TestHostAndLocalPathsMapBothWays` 覆盖 `Outside`。
- `TestVisualRemoteWorkspace` 的 `host-file`、`host-file-readonly` 无头截图（`docs/assets/remote-workspace/`）。
- 真实 SSH 主机上的整机验收和 Windows 上的验证尚未完成。

```bash
scripts/desktop/desktop-go.sh test ./internal/remoteplaceholder ./internal/workbench -run 'TestRemoteOpenFileOnHost|TestHostAndLocalPathsMapBothWays' -count=1
```

## 适用范围

`desktop/internal/workbench/remote_host_files.go`、`remote_host_files_view.go`、`remote_documents.go` 中的 `writable`/`errRemoteReadOnly`、`documents.go` 的 `hostOutside`，以及 `desktop/internal/remoteplaceholder` 的 `Outside`。以后远程工作区里任何打开主机文件的入口（例如远程运行输出里的路径链接）都要经 `remoteplaceholder.LocalPath` 求本机键、按 `hostOutside` 决定只读，不要另开一条可写路径。
