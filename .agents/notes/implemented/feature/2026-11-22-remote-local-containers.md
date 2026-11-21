# Agent 笔记：远程开发窗口——进入本机容器，以及从 devcontainer.json 打开

状态：已实现

## 先说结论

“远程开发”窗口在已保存的连接和 WSL 发行版之后，以“容器”分组列出本机 Docker 和 Podman 正在运行的容器。选中一个容器、可选地填写容器内用户，点“连接”后，Core 用本机的 `docker exec -i` 或 `podman exec -i`（在正在运行的容器里执行一条命令）启动和 SSH 相同的远端服务。之后的文件夹选择、信任询问、工作区、心跳和重连都与 SSH、WSL 共用同一流程。容器不写入已保存的连接，打开过的文件夹也不记住；列表每次打开窗口时向引擎重新读取。

“从 devcontainer.json 打开…”选一个本机文件夹，经 Core 用官方 Dev Container CLI（`devcontainer up`）按它的 `devcontainer.json` 构建并启动容器，然后按上面的容器入口连接，直接打开 CLI 给出的工作区文件夹。构建会运行文件夹里的 Dockerfile、features 和命令，所以文件夹必须先受信任；CLI 的输出只显示在页面上，不写日志。

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

### 从 devcontainer.json 打开：用官方 CLI，Lithe 不加东西

- 构建交给官方 Dev Container CLI，不自己实现规范：规范里的 features、生命周期命令、`docker compose`、变量替换和镜像元数据合并都由 CLI 处理，行为与 VS Code 一致，CLI 升级就跟着升级；Lithe 只是调用者。
- Core #162 的 `remote.devcontainerConfigs(folder)` 只读文件夹，按规范的查找顺序列出 `.devcontainer/devcontainer.json`、`.devcontainer.json` 和 `.devcontainer` 下一层文件夹里的配置及其 `name`；`remote.devcontainerUp` 只传 `--workspace-folder`、选中的 `--config`，选 Podman 时加 `--docker-path podman`。挂载、端口和运行参数只来自 `devcontainer.json`，Lithe 不额外挂载目录、不加参数（S32）。
- `devcontainer up` 会在本机运行文件夹提供的代码，Core 要求请求带 `projectCodeAllowed`。桌面端先读本机信任：未受信任时按钮变成“信任并构建”，按与“以受信任项目打开”相同的方式写入信任记录后再构建，不另开一种“只为构建而信任”的状态。
- CLI 的输出经 Core 隐藏敏感信息后按行流式返回，页面最多保留最近 5000 行；输出、文件夹、配置名、容器名和用户都不写日志，失败只记 `remote_devcontainer_up` 和错误码。
- 构建期间左侧列表、配置、引擎和文件夹都不能改；“停止”“取消”和关闭窗口都会取消这次构建。已经启动的容器继续运行，页面保留日志并说明这一点：停止不等于删除，删除容器是用户在引擎里的决定。
- 成功后不新建一种连接：重新读取容器列表并选中 CLI 返回的容器，以它的 `remoteUser` 作为容器内用户，走同一个 `remote.connect` 的 `container` 参数，再直接打开 `remoteWorkspaceFolder`。重建后的容器同名，所以信任记录和窗口计数照常接上。

## 考虑过的备选方案

- **把容器当作一种可保存的连接**：可以给容器起名、分组。没有采用：容器随时会被删除和重建，保存的条目会大量失效；容器信息每次都能从引擎读到，保存只会多一份需要同步的状态。
- **按容器 ID 连接**：ID 唯一，但重建后会变，信任记录和标题都对不上；Dev Container 每次重建都会换 ID。名字只在同一个引擎里有效，所以列表键里带上引擎。
- **在桌面端直接运行 `docker ps` 和 `docker exec`**：Windows 和 macOS 都能用 Go 实现，但会在 Core 之外多一套参数转义、超时和输出上限规则，也无法复用 SSH 主机上的容器跳转。通用逻辑放在 Core。
- **自己实现 Dev Container 规范**：不依赖 Node 和 npm 包。没有采用：规范面很大（features 的安装顺序、生命周期命令、compose、镜像标签里的元数据合并），自己实现容易与 VS Code 的结果不一致，还要长期跟进规范；官方 CLI 就是规范的参考实现。缺少 CLI 时页面说明用 `npm install -g @devcontainers/cli` 安装。
- **构建前不要求信任，只在页面上提醒**：没有采用。构建等于运行文件夹提供的 Dockerfile 和命令，与打开受信任项目运行构建一样，必须由同一个信任记录决定。
- **本阶段同时支持 SSH 主机和 WSL 里的容器**：Core 已支持 `connection`/`wsl` 后接 `container`，但界面需要先连上主机才能列出它的容器，要改动连接后的页面结构，放到下一阶段单独做。

## 后果

- 收益：Dev Container、`docker compose` 或手工运行的容器都能直接打开，不需要在容器里装 SSH 服务；进入容器的安全边界只由 Core 一处决定；测试不碰本机引擎。
- 代价：打开窗口时多两次 `ps` 调用（各最多 15 秒，后台进行）；容器的用户不保存，每次需要重新填写；同名容器在两个引擎里各自打开时窗口计数按引擎区分。
- 从 devcontainer.json 打开需要本机装好 Dev Container CLI（Node.js 程序），构建可能很久（Core 最长等一小时）；停止构建不会删除已启动的容器。
- 尚未完成：SSH 主机和 WSL 中的容器入口与 devcontainer.json、装有 Dev Container CLI 的真实 Docker/Podman 与 Windows 上的整机验收。

## 验证

- `desktop/internal/workbench/remote_container_test.go`：列表分组、排序、选中页、用户填写后的身份、连接只发一次请求且不带 SSH 偏好、标题与状态栏、不写已保存连接、不记住文件夹、日志不含容器信息；停止的容器、被拒绝的用户、找不到引擎时的说明与步骤；搜索与折叠；一个引擎失败时另一个照常列出；没有引擎时不显示分组。
- `desktop/internal/core/remote_session_test.go`：`container` 单独发送、`remote.listContainers` 的请求与回应。
- `desktop/internal/workbench/remote_devcontainer_test.go`：读取文件夹的配置并默认选第一个、构建请求的字段、按 CLI 结果选中容器并打开工作区文件夹、日志里没有文件夹和容器信息；未受信任时先写信任再构建；找不到 CLI、CLI 报告失败、Core 以未受信任拒绝时的说明，且 CLI 输出不进日志；构建中“停止”后保留日志、列表不能切换；相对路径、不存在的文件夹和没有配置的文件夹。
- `desktop/internal/core/remote_devcontainer_test.go`：`remote.devcontainerConfigs` 的列出、`remote.devcontainerUp` 在运行 CLI 之前的拒绝、流式输出事件。
- `desktop/internal/workbench/remote_connections_visual_test.go` 生成 `docs/assets/remote-connections/` 下的容器和 devcontainer 截图。

```bash
scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench -run 'Remote|Container|Devcontainer' -count=1
```

## 适用范围

`desktop/internal/workbench/remote_container.go`、`desktop/internal/workbench/remote_wsl.go` 中的 `remoteHost`、`desktop/internal/core/remote_session.go` 中的 `ContainerConnection` 与 `RemoteListContainers`，`desktop/internal/workbench/remote_devcontainer.go` 与 `desktop/internal/core/remote_devcontainer.go`。之后的 Dev Container 和远端主机上的容器入口都复用同一个 `remoteHost{container}` 和 Core 的 `remote.connect`，不要在桌面端另写一套容器命令。
