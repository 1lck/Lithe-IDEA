# Agent 笔记：远程开发窗口——进入本机正在运行的容器

状态：已实现

## 先说结论

“远程开发”窗口在已保存的连接和 WSL 发行版之后，以“容器”分组列出本机 Docker 和 Podman 正在运行的容器。选中一个容器、可选地填写容器内用户，点“连接”后，Core 用本机的 `docker exec -i` 或 `podman exec -i`（在正在运行的容器里执行一条命令）启动和 SSH 相同的远端服务。之后的文件夹选择、信任询问、工作区、心跳和重连都与 SSH、WSL 共用同一流程。容器不写入已保存的连接，打开过的文件夹也不记住；列表每次打开窗口时向引擎重新读取。

## 问题

Issue #2231 要求兼容 Dev Container（按 `devcontainer.json` 规范构建并运行的开发容器）。不管容器是谁建起来的，第一步都是“进入一个正在运行的容器并在里面打开文件夹”：

- 容器的生命周期由 Docker、Podman 或 Dev Container CLI 管理，同名容器可以被删掉再建，内部 ID 会变；
- 进入容器不经过 OpenSSH，没有主机密钥、密码和 `ssh -G` 配置，SSH 的步骤、提示和“编辑连接”都不适用；
- 容器名、镜像名和容器内用户名都可能暴露项目信息，不能进日志；
- 测试会打开“远程开发”窗口，不能因此在开发者电脑上运行真的 `docker ps`（会唤起 OrbStack 等，慢且结果不确定）。

## 决策

### 容器进入规则在 Core，窗口只选择和展示

- Core #162 给 `remote.connect` 增加 `container: { engine, container, user? }`，单独出现时在本机执行 `<engine> exec -i [-u 用户] 容器 …`；跟在 `connection` 或 `wsl` 后面时先登录那台主机再进入它上面的容器。会话身份为 `engine:[用户@]容器`，信任记录的键包含容器。
- Core 只进入正在运行的容器：不启动、不创建、不改动容器，不挂载目录，不提权；不填用户时使用镜像的默认用户（S32）。
- `remote.listContainers(engine, sessionId)` 在本机（`sessionId` 为空）或会话的主机上运行 `<engine> ps`，最多 15 秒、256 个容器；没有该引擎时返回 `available: false`，引擎报错时返回只用于显示的诊断。
- 桌面端的 `remoteHost` 现在在 SSH 连接、WSL 发行版和容器三者中取一个。只有经 SSH 的连接才发送 SSH 偏好、显示读取配置和身份验证步骤、提供“编辑连接”、记住打开过的文件夹，统一由 `remoteHost.overSSH()` 判断。

### 按名字连接，不保存

- 列表行的键是 `engine:完整 ID`，用于区分两个引擎里的同名容器；连接请求只发容器名，所以按同一个名字重建的容器（Dev Container 重建后就是这样）仍能用同一个标题、信任记录和窗口计数接上。
- 容器不写入 `remote/connections.json`，打开过的文件夹不记入最近文件夹：容器随时会被删除，保存下来的条目大多会失效，而列表本来就每次从引擎读取。

### 一个引擎失败不影响另一个

窗口打开时在一个后台任务里依次列出 Docker 和 Podman。某个引擎超时或报错就跳过它，日志记一次 `remote_containers_list` 失败（只有命令名和错误码），另一个引擎的容器照常列出；两个引擎都没有时不显示“容器”分组。

### 失败说明用引擎自己的话

连接失败时步骤从“进入容器”开始；容器已停止、暂停或引擎没有应答时说明这几种可能，找不到引擎命令行时说明需要安装哪个引擎；不显示 SSH 的排查提示。引擎原始输出只显示在步骤下方，不写日志。Core 拒绝用户或容器名时，按字段给出原因。

### 日志只记动作

日志只有 `remote.container.select`、`remote.connect`、`remote.workspace.open` 等动作和失败的操作名，不含容器名、镜像、状态或用户名。

## 考虑过的备选方案

- **把容器当作一种可保存的连接**：可以给容器起名、分组。没有采用：容器随时会被删除和重建，保存的条目会大量失效；容器信息每次都能从引擎读到，保存只会多一份需要同步的状态。
- **按容器 ID 连接**：ID 唯一，但重建后会变，信任记录和标题都对不上；Dev Container 每次重建都会换 ID。名字只在同一个引擎里有效，所以列表键里带上引擎。
- **在桌面端直接运行 `docker ps` 和 `docker exec`**：Windows 和 macOS 都能用 Go 实现，但会在 Core 之外多一套参数转义、超时和输出上限规则，也无法复用 SSH 主机上的容器跳转。通用逻辑放在 Core。
- **本阶段同时支持 SSH 主机和 WSL 里的容器**：Core 已支持 `connection`/`wsl` 后接 `container`，但界面需要先连上主机才能列出它的容器，要改动连接后的页面结构，放到下一阶段单独做。

## 后果

- 收益：Dev Container、`docker compose` 或手工运行的容器都能直接打开，不需要在容器里装 SSH 服务；进入容器的安全边界只由 Core 一处决定；测试不碰本机引擎。
- 代价：打开窗口时多两次 `ps` 调用（各最多 15 秒，后台进行）；容器的用户不保存，每次需要重新填写；同名容器在两个引擎里各自打开时窗口计数按引擎区分。
- 尚未完成：`devcontainer.json` 的构建与启动、SSH 主机和 WSL 中的容器入口、真实 Docker/Podman 与 Windows 上的整机验收。

## 验证

- `desktop/internal/workbench/remote_container_test.go`：列表分组、排序、选中页、用户填写后的身份、连接只发一次请求且不带 SSH 偏好、标题与状态栏、不写已保存连接、不记住文件夹、日志不含容器信息；停止的容器、被拒绝的用户、找不到引擎时的说明与步骤；搜索与折叠；一个引擎失败时另一个照常列出；没有引擎时不显示分组。
- `desktop/internal/core/remote_session_test.go`：`container` 单独发送、`remote.listContainers` 的请求与回应。
- `desktop/internal/workbench/remote_connections_visual_test.go` 生成 `docs/assets/remote-connections/` 下的容器截图。

```bash
scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench -run 'Remote|Container' -count=1
```

## 适用范围

`desktop/internal/workbench/remote_container.go`、`desktop/internal/workbench/remote_wsl.go` 中的 `remoteHost`、`desktop/internal/core/remote_session.go` 中的 `ContainerConnection` 与 `RemoteListContainers`。之后的 Dev Container 和远端主机上的容器入口都复用同一个 `remoteHost{container}` 和 Core 的 `remote.connect`，不要在桌面端另写一套容器命令。
