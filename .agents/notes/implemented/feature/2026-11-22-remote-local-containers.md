# Agent 笔记：远程开发窗口——自动识别容器环境、基础配置创建和进入容器

状态：已实现

## 先说结论

“远程开发”窗口在已保存的连接和 WSL 发行版之后，以“容器”分组列出本机 Docker 和 Podman 正在运行的容器。选中一个容器、可选地填写容器内用户，点“连接”后，Core 用本机的 `docker exec -i` 或 `podman exec -i`（在正在运行的容器里执行一条命令）启动和 SSH 相同的远端服务。之后的文件夹选择、信任询问、工作区、心跳和重连都与 SSH、WSL 共用同一流程。容器不写入已保存的连接，打开过的文件夹也不记住；列表每次打开窗口时向引擎重新读取。

“创建或打开 Dev Container…”先选环境和工作文件夹；已有配置时直接选择，没有配置时填写镜像或 Dockerfile、用户、端口等基础选项，确认后生成标准 `devcontainer.json`。JSON 继续作为 Agent 和官方 Dev Container CLI 的共同输入，人不需要先手写 JSON。构建仍由官方 CLI 执行，必须先信任文件夹；成功后直接连接并打开 CLI 给出的工作区。

环境来自本机 Docker contexts（Docker 保存的引擎连接环境）、Podman 和 Windows 用户 WSL 发行版中的引擎。Docker Desktop、OrbStack、Linux Docker 和 WSL Docker 使用各自真实的名称与可用状态；容器列表、构建和连接始终使用同一个环境，不切换用户的全局 Docker context。

连上 SSH 主机或 WSL 发行版后，文件夹选择页标题栏的“主机上的容器”在文件夹的位置列出那台主机上正在运行的 Docker 和 Podman 容器。“进入容器”结束浏览会话，重新连接主机并经主机上的引擎进入容器，再在容器里选择文件夹。主机上的容器同样不保存：工作区身份是“已保存连接或发行版的身份/引擎:[用户@]容器”，打开过的文件夹不记入已保存的连接。

## 问题

Issue #2231 要求兼容 Dev Container（按 `devcontainer.json` 规范构建并运行的开发容器）。不管容器是谁建起来的，第一步都是“进入一个正在运行的容器并在里面打开文件夹”：

- 容器的生命周期由 Docker、Podman 或 Dev Container CLI 管理，同名容器可以被删掉再建，内部 ID 会变；
- 进入容器不经过 OpenSSH，没有主机密钥、密码和 `ssh -G` 配置，SSH 的步骤、提示和“编辑连接”都不适用；
- 容器名、镜像名和容器内用户名都可能暴露项目信息，不能进日志；
- 测试会打开“远程开发”窗口，不能因此在开发者电脑上运行真的 `docker ps`（会唤起 OrbStack 等，慢且结果不确定）。

## 决策

### 容器进入规则在 Core，窗口只选择和展示

- Core #162 引入的 `remote.connect` 入口现在接受 `container: { engine, context?, container, user? }`，单独出现时在本机执行 `<engine> [--context 环境] exec -i [-u 用户] 容器 …`；跟在 `connection` 或 `wsl` 后面时先登录那台主机再进入它上面的容器。显式 Docker context 的会话身份为 `docker[context]:[用户@]容器`，省略 context 保持原身份；信任记录的键同样包含 context 和 WSL 发行版。
- Core 只进入正在运行的容器：不启动、不创建、不改动容器，不挂载目录，不提权；不填用户时使用镜像的默认用户（S32）。
- `remote.listContainers(engine, sessionId)` 在本机（`sessionId` 为空）或会话的主机上运行 `<engine> ps`，最多 15 秒、256 个容器；没有该引擎时返回 `available: false`，引擎报错时返回只用于显示的诊断。
- 桌面端的 `remoteHost` 由 SSH 连接或 WSL 发行版加可选的容器组成，三个判断各管一件事，不再让一个判断兼两种含义：
  - `overSSH()`：经 OpenSSH 登录（SSH 连接，或 SSH 主机上的容器），决定是否发送 SSH 偏好、显示读取配置和身份验证步骤；
  - `saved()`：就是一个已保存的 SSH 连接，决定是否提供“编辑连接”、记住打开过的文件夹；
  - `hosted()`：主机上的容器，决定失败说明和“重试”的目标。

### 按名字连接，不保存

- 列表行的键包含引擎、context、WSL 发行版和完整容器 ID；连接按同一环境中的容器名进行，所以按同一个名字重建的容器（Dev Container 重建后就是这样）仍能用同一个标题、信任记录和窗口计数接上。
- 容器不写入 `remote/connections.json`，打开过的文件夹不记入最近文件夹：容器随时会被删除，保存下来的条目大多会失效，而列表本来就每次从引擎读取。

### 按真实环境识别，一个失败不影响另一个

Core 读取 Docker context 的名称、描述和本地 socket，随后以只读 `info` 探测 daemon（实际管理容器的后台服务），也探测 Podman。Windows 再通过系统 `wsl.exe` 枚举用户发行版，在其中执行同样的探测；Docker Desktop 的内部发行版不作为用户环境。只提供 `unix://` 和 `npipe://` 本地端点，避免把本机目录交给另一台机器上的 daemon 挂载。

安装了但未就绪的环境仍在选择器里，显示实际诊断并阻止构建；可手动刷新。默认选择由 Core 给出，优先可用的本机当前 context，再取其他可用环境。最多 24 个目标、8 个发行版，探测有时间上限，部分失败返回已发现结果和诊断。完整限制属于 Core 契约，不在视图另设一套。

显式 context 只应用到本次子进程，并清除会覆盖它的继承 Docker 连接变量。WSL 命令参数独立传入，不插入用户 shell 文本。选择器刷新或切换环境后取消旧配置读取、清除旧信任和文件夹结果，再从新环境读取；保留用户的表单草稿。某个环境失败不影响其他环境，日志只记录失败阶段和类别，诊断原文只显示。

### 失败说明用引擎自己的话

连接失败时步骤从“进入容器”开始；容器已停止、暂停或引擎没有应答时说明这几种可能，找不到引擎命令行时说明需要安装哪个引擎；不显示 SSH 的排查提示。引擎原始输出只显示在步骤下方，不写日志。Core 拒绝用户或容器名时，按字段给出原因。

### 日志只记动作

日志只有 `remote.container.select`、`remote.connect`、`remote.workspace.open` 等动作和失败的操作名，不含容器名、镜像、状态或用户名。

### 基础表单创建标准配置，构建继续用官方 CLI

- 构建交给官方 Dev Container CLI，不自己实现规范：规范里的 features、生命周期命令、`docker compose`、变量替换和镜像元数据合并都由 CLI 处理，行为与 VS Code 一致，CLI 升级就跟着升级；Lithe 只是调用者。
- 空工作区显示基础表单；Core 的 `remote.devcontainerPrepare` 校验并生成标准文档，不做 I/O。镜像和 Dockerfile 二选一，Dockerfile、构建目录相对工作区解释，端口生成只监听本机回环地址的标准 `appPort`，不额外注入 CLI 参数。复杂配置和 Agent 继续编辑同一个标准文件。
- 只有“创建配置”写入工作区的 `.devcontainer/devcontainer.json`；打开页面、输入草稿、取消均不写文件。原生 `configfile` adapter（负责有根目录访问和原子替换的文件适配器）拒绝覆盖已有文件、越界符号链接和安装目录；创建成功后重新从 Core 读取配置，再沿用“信任并构建”。
- 该资源归用户工作区所有，生命周期随工作区，不属于构建缓存；不跨工作树复制。应用运行时只读安装包，配置不写 app bundle 或 Windows 安装目录，不改变代码签名或 Sparkle 增量更新的源基线。
- Windows WSL 环境使用发行版内安装的官方 CLI；接受 Windows 绝对路径或该发行版的 Linux 绝对路径，通过 `wslpath` 获取实际 Linux 路径和供桌面写入、信任使用的原生路径，不假设固定的 `/mnt/c`。构建、检查、连接都保留发行版和 context。SSH 远端构建仍不在这个入口范围。
- Core #162 引入的 `remote.devcontainerConfigs` 入口现在携带所选环境，只读文件夹，按规范的查找顺序列出 `.devcontainer/devcontainer.json`、`.devcontainer.json` 和 `.devcontainer` 下一层文件夹里的配置；本机读取可选 `name`，WSL 只列路径。`remote.devcontainerUp` 只传 `--workspace-folder`、选中的 `--config`，选 Podman 时加 `--docker-path podman`。挂载、端口和运行参数只来自 `devcontainer.json`，Lithe 不额外挂载目录、不加参数（S32）。
- `devcontainer up` 会在所选环境运行文件夹提供的代码，Core 要求请求带 `projectCodeAllowed`。桌面端先读工作区原生路径的信任：未受信任时按钮变成“信任并构建”，按与“以受信任项目打开”相同的方式写入信任记录后再构建，不另开一种“只为构建而信任”的状态。
- CLI 的输出经 Core 隐藏敏感信息后按行流式返回，页面最多保留最近 5000 行；输出、文件夹、配置名、容器名和用户都不写日志，失败只记 `remote_devcontainer_up` 和错误码。
- 构建期间左侧列表、配置、引擎和文件夹都不能改；“停止”“取消”和关闭窗口都会取消这次构建。已经启动的容器继续运行，页面保留日志并说明这一点：停止不等于删除，删除容器是用户在引擎里的决定。
- 成功后不新建一种连接：重新读取容器列表并选中 CLI 返回的容器，以它的 `remoteUser` 作为容器内用户，走同一个 `remote.connect` 的 `container` 参数，再直接打开 `remoteWorkspaceFolder`。重建后的容器同名，所以信任记录和窗口计数照常接上。

### SSH 主机和 WSL 上的容器：从文件夹选择页进入

- 入口放在已连接主机的文件夹选择页标题栏，而不是左侧列表：主机上的容器要先连上主机才能列出，列表本身属于这台主机。容器列表替换文件夹列表显示，“返回文件夹”回到原来的文件夹；容器里的浏览页不再提供这个入口（容器里不再嵌套容器）。
- 列表经浏览会话的 `remote.listContainers(engine, sessionId)` 依次读取 Docker 和 Podman，在远端服务的非登录环境里运行，所以列出来的容器就是这条连接能进入的。主机没有任何引擎命令行时说明没有找到 Docker 或 Podman；引擎报错时显示它的原始输出，不写日志，失败只记 `remote_host_containers_list` 和错误码。
- “进入容器”先结束浏览会话，再用同一个 `remote.connect` 发送 `connection`（或 `wsl`）加 `container`。不在已有会话里切换：会话的身份、信任记录和心跳都按“主机/容器”这一对建立，复用浏览会话会让信任键和窗口计数对不上。代价是 OpenSSH 会再问一次它要问的内容（密码、一次性验证码），步骤页照常显示这些问题。
- 主机上的容器不写入已保存的连接：不给已保存连接加子条目，打开过的文件夹也不记入它的最近文件夹，理由与本机容器相同（容器随时被删除重建）。工作区身份是 `已保存连接或发行版的身份/引擎:[用户@]容器`，窗口名为“容器名（主机名）”，地址显示为“主机 › 引擎:[用户@]容器”。
- 主机连不上和容器已停止、暂停或引擎没有应答，在 Core 看来都是连接失败，桌面端分不出来，所以用同一段说明并点名引擎，具体原因在诊断输出里；不显示 OpenSSH 的排查提示，也没有“编辑连接”。“重试”进入同一台主机上的同一个容器，而不是回到主机。
- SSH 主机不支持从这个入口构建；本机 Windows 的 WSL 环境已可从环境选择器构建，不需要先建立浏览会话。
- 日志只有 `remote.browse.containers`、`remote.browse.folders`、`remote.browse.container.enter`、`remote.connect` 等动作名，不含主机、容器名、镜像、用户或主机路径。

## 考虑过的备选方案

- **把容器当作一种可保存的连接**：可以给容器起名、分组。没有采用：容器随时会被删除和重建，保存的条目会大量失效；容器信息每次都能从引擎读到，保存只会多一份需要同步的状态。
- **按容器 ID 连接**：ID 唯一，但重建后会变，信任记录和标题都对不上；Dev Container 每次重建都会换 ID。名字只在同一个环境里有效，所以列表键里也包含 context 和发行版。
- **在桌面端直接运行 `docker ps` 和 `docker exec`**：Windows 和 macOS 都能用 Go 实现，但会在 Core 之外多一套参数转义、超时和输出上限规则，也无法复用 SSH 主机上的容器跳转。通用逻辑放在 Core。
- **自己实现 Dev Container 规范**：不依赖 Node 和 npm 包。没有采用：规范面很大（features 的安装顺序、生命周期命令、compose、镜像标签里的元数据合并），自己实现容易与 VS Code 的结果不一致，还要长期跟进规范；官方 CLI 就是规范的参考实现。缺少 CLI 时页面说明用 `npm install -g @devcontainers/cli` 安装。
- **只提供 JSON 入口**：Agent 操作简单，但人创建普通镜像环境仍需查字段；改为基础表单生成标准 JSON，避免维护第二套私有配置。
- **探测 OrbStack、Docker Desktop 的应用安装路径并切全局 context**：安装位置不能证明 daemon 可用，切全局环境也会影响用户终端。读取上游 context、实际探测，并让每次操作携带选定环境。
- **构建前不要求信任，只在页面上提醒**：没有采用。构建等于运行文件夹提供的 Dockerfile 和命令，与打开受信任项目运行构建一样，必须由同一个信任记录决定。
- **主机上的容器放在左侧列表，挂在已保存连接下面**：一眼能看到。没有采用：列出它们要先连上主机，打开窗口时不能为此逐台登录；挂在连接下面也就等于把容器保存进连接。
- **在浏览会话里直接切进容器，不重新登录**：少问一次密码。没有采用：会话的身份、信任键和心跳都按“主机/容器”建立，原地切换需要 Core 为一个会话换身份，边界不清；重新连接沿用已有的同一条路径。
- **把主机连接失败和容器失败分开说明**：更准确。没有采用：Core 对二者返回同一个连接失败，桌面端只能猜；诊断输出已经给出原因。

## 后果

- 收益：Dev Container、`docker compose` 或手工运行的容器都能直接打开，不需要在容器里装 SSH 服务；进入容器的安全边界只由 Core 一处决定；测试不碰本机引擎。
- 代价：打开窗口时增加有界的环境探测及各可用环境的 `ps`，全部在后台执行；WSL 首次执行可能唤起发行版。结果在同一次窗口中复用，关闭页面或窗口取消所属任务；容器用户不保存。
- 从 devcontainer.json 打开需要所选环境装好 Dev Container CLI（Node.js 程序），构建可能很久（Core 最长等一小时）；停止构建不会删除已启动的容器。
- 进入主机上的容器要重新登录主机，OpenSSH 会再问一次密码或验证码。
- 尚未完成：SSH 远端构建、Windows Docker Desktop/WSL 和原生 Linux 的整机验收。本机已完成 OrbStack 的真实创建、生命周期命令、所选 context 连接和远端文件读取；Docker Desktop 只验证了已发现但未就绪状态，不能据此声称其构建验收通过。

## 验证

- `desktop/internal/workbench/remote_container_test.go`：列表分组、排序、选中页、用户填写后的身份、连接只发一次请求且不带 SSH 偏好、标题与状态栏、不写已保存连接、不记住文件夹、日志不含容器信息；停止的容器、被拒绝的用户、找不到引擎时的说明与步骤；搜索与折叠；一个引擎失败时另一个照常列出；没有引擎时不显示分组。
- `desktop/internal/core/remote_session_test.go`：`container` 单独发送、`remote.listContainers` 的请求与回应。
- `desktop/internal/workbench/remote_devcontainer_test.go`：读取文件夹的配置并默认选第一个、构建请求的字段、按 CLI 结果选中容器并打开工作区文件夹、日志里没有文件夹和容器信息；未受信任时先写信任再构建；找不到 CLI、CLI 报告失败、Core 以未受信任拒绝时的说明，且 CLI 输出不进日志；构建中“停止”后保留日志、列表不能切换；相对路径、不存在的文件夹和没有配置的文件夹。
- `desktop/internal/core/remote_devcontainer_test.go`：`remote.devcontainerConfigs` 的列出、`remote.devcontainerUp` 在运行 CLI 之前的拒绝、流式输出事件。
- `desktop/internal/workbench/remote_host_containers_test.go`：经浏览会话列出两个引擎、未选中时“进入容器”不可用、进入时结束浏览会话并按填写的用户在同一台主机上连接、工作区身份与窗口名、不记住文件夹、动作顺序与日志不含主机和容器信息；容器已不在时的说明、没有“编辑连接”、地址带主机、“重试”进入同一台主机上的同一个容器、“返回文件夹”；`remoteHost` 的 `hosted`/`overSSH`/`saved` 与请求字段。
- `desktop/internal/workbench/remote_connections_visual_test.go` 生成 `docs/assets/remote-connections/` 下的容器、主机上的容器和 devcontainer 截图。
- `desktop/internal/workbench/remote_devcontainer_form_test.go`：真实 Core 生成后原子保存并重新读取、草稿与取消不写、已有文件不覆盖、安装包清单与哈希不变、环境刷新使旧信任失效并保留草稿。共享示例只有 Core 的 `rust/fixtures/remote/devcontainer-configuration-v1.json` 一份，Go 桥接测试读取链接的检出。
- `desktop/internal/workbench/remote_devcontainer_integration_test.go`：显式开启后使用真实官方 CLI 和指定环境，校验创建后命令通过工作区挂载写文件、校验服务端上传、进入相同 context 并读取该文件；清理本次唯一工作区标签下的容器，不动已有容器或镜像。2026-11-26 在 OrbStack / Alpine 3.21 通过。
- `desktop/internal/workbench/remote_devcontainer_runtime_visual_test.go`：显式开启后读取本机真实环境，采集基础表单、Dockerfile、选择器与滚动区域的明暗主题及中英文截图；不替换环境数据。2026-11-26 已生成并检查。

```bash
scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench -run 'Remote|Container|Devcontainer' -count=1
```

## 适用范围

`desktop/internal/workbench/remote_container.go`、`desktop/internal/workbench/remote_host_containers.go`、`desktop/internal/workbench/remote_wsl.go` 中的 `remoteHost`、`desktop/internal/core/remote_session.go` 中的 `ContainerConnection` 与 `RemoteListContainers`，`desktop/internal/workbench/remote_devcontainer.go`、`desktop/internal/workbench/remote_devcontainer_form.go` 与 `desktop/internal/core/remote_devcontainer.go`。环境探测、校验和配置生成位于 Rust Core 的 workspace crate。之后的 Dev Container 和远端主机上的容器入口都复用同一个 `remoteHost{container}` 和 Core 的 `remote.connect`，不要在桌面端另写一套容器命令。
