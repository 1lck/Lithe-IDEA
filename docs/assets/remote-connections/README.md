# 远程开发连接窗口（#2231）无头测试截图

截图来自生产 Viva Page 的无头渲染。连接列表由真实 Core 写入测试的临时偏好目录，颜色、分组和分组顺序都由 Core 保存并返回。下列内容都由测试直接给出固定值，不读取本机配置，也不启动 OpenSSH：

- “测试连接”的结果：由测试替换的内核返回固定的主机信息；
- `ssh -G` 解析出的生效设置；
- 空页面上 Motty 和 `~/.ssh/config` 的可导入数量；
- 导入页的 Motty 主机、逐项字段映射和 `~/.ssh/config` 的主机；
- 选文件夹页的远程目录；
- WSL 发行版列表和连接失败时 wsl.exe 的输出；
- Docker 和 Podman 容器列表和连接失败时容器引擎的输出；
- 已连接主机上正在运行的 Docker 和 Podman 容器；
- OpenSSH 的主机密钥和密码询问。

截图里的主机、用户、指纹和路径都是虚构的。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- **空页面：** 左侧只有搜索、导入、新建和“还没有保存的连接”。右侧是“通过 SSH 连接 Linux 主机”：
  - 一个 `user@host:22` 地址框，交给 Core 解析后填入新连接；
  - “从 Motty 导入”和“从 ~/.ssh/config 导入”两张卡片，各显示可导入的主机数；
  - “手动填写”。
- **列表与概览：** 连接按 Core 给出的分组列出，分组可以折叠。每行显示：
  - 左侧一条连接颜色的竖条，选中的行带选中底色；
  - 图标：测过的主机显示系统名的前两个字母（Ubuntu 显示“Ub”），没测过的显示名称首字母，都用连接的颜色；
  - 名称、地址，右侧是上次连接时间；已有窗口打开它、或正在为它选文件夹时，显示绿点和“已连接”。
- **概览页：** 选中连接后右侧显示：
  - 顶部：图标、颜色点、名称、分组标签，地址后跟跳板机；
  - 按钮：“编辑”、“⋯”和“打开文件夹…”；
  - 各区块：“最近打开的文件夹”、“主机信息”（主机名、系统、CPU、内存、磁盘，以及测试时间和“重新测试”）、“生效的 SSH 设置”。生效设置逐项列出 `ssh -G` 解析出的值和来源（本连接 / SSH 配置 / 默认值）。
- **编辑与新建：** 面包屑显示“编辑 <名称>”或“新建连接”。高级选项折叠在分隔线下，折叠时标题旁显示当前的连接超时和保活间隔，可以展开编辑。主机字段填了 `user@host` 时，Core 拒绝的原因显示在主机字段下方，连接不会写入列表。
- **测试结果：** 显示在表单最下方、高级选项之后：
  - 成功：绿色框，“已连接：<系统> <架构>，这台主机可以用于远程开发。”，下面一行小标签列出系统、主机名、核数、内存和磁盘；右侧“OpenSSH 输出”展开原始输出；
  - 失败：红色框，失败原因和该检查什么（例如身份验证失败时提示检查用户名、或改用“私钥文件”）；OpenSSH 的原始输出默认展开在框下方，右侧“收起”。
- **连接步骤：** 依次为读取配置、连接主机、身份验证、检查平台、安装服务端、启动会话：
  - OpenSSH 的主机密钥询问显示在“连接主机”下方，带密钥类型和指纹，按钮为“拒绝”和“信任并继续”；
  - 密码询问显示在“身份验证”下方。截图是主机拒绝了记住的密码之后：红字提示“主机没有接受记住的回答，请重新输入”，“记住密码”保持勾选，下方说明何时保存、何时自动填入；
  - 失败时标出失败的步骤并展开诊断。
- **SSH 密码询问（弹窗）：** 窗口上方弹出“SSH 身份验证”，提示原样显示。已保存的连接在输入框下有“记住密码”勾选框（口令为“记住口令”）；未勾选时说明回答只交给这次连接、Lithe 不保存。未保存的连接、验证码和主机指纹询问没有这个勾选框。
- **选文件夹：** 左侧连接列表保留，面包屑显示连接名称。右侧：
  - 顶部：系统图标、“选择 … 上的文件夹”、连接状态、地址和系统，右侧“断开”；
  - 路径输入框和“前往”，下方是“常用”位置和可点击的路径面包屑；
  - 目录列表：“上一级”，文件夹双击进入，文件灰显、不能选；含 `.git`（目录或工作树的文件）的子文件夹标“Git”。列表显示后，桌面端用 Core 已有的 `remote.stat` 查看前 64 个子文件夹，最多 8 个并行；
  - 底部按钮为“稍后再选”和“打开 <文件夹名>”。
- **信任文件夹：** 第一次打开远程文件夹时询问是否信任：
  - 标题下方用等宽字体显示 `主机 : 路径`，正文说明信任后会在远端运行哪些程序；
  - 两种打开方式的说明框：“信任并打开”是完整功能，“以安全模式打开”只浏览和编辑文件；
  - 可以勾选信任上级目录；底部注明信任记录只保存在本机。
- **从 Motty 导入：** 左侧连接列表保留，面包屑显示“从 Motty 导入”。
  - 顶部在 Motty 和 SSH 配置之间切换，旁边注明只读，ⓘ 说明读取的数据库、不打开密钥库；右侧“重新读取”；
  - 汇总行显示找到的主机数、分组数和数据格式，以及“保留分组”“保留颜色”；
  - 表格列出主机（颜色点、系统图标、名称和地址）、分组和结果（可导入 / 部分导入 / 已存在 / 非 SSH）。已保存的主机勾选后只补颜色和分组；
  - 展开一台主机后逐项列出 Motty 的设置、值、对应的 Lithe 设置，或不导入的原因；
  - 底部显示将导入的连接数和将新建的分组。
- **从 SSH 配置导入：** 表格列出 Host 别名、`ssh -G` 解析出的生效值和结果。被其他主机用作跳板的主机注明“作为 … 的 ProxyJump”；通配符 Host 跳过并说明原因。

- **WSL 发行版：** 已保存的连接之后是“WSL”分组，列出本机的发行版（截图里的发行版由测试给出，不运行 wsl.exe）：
  - 选中后右侧显示发行版名、“WSL”标签和 `wsl:用户@发行版` 地址，说明经本机 wsl.exe 打开、不保存任何信息，下方可填写 Linux 用户；
  - 连接失败时步骤从“启动发行版”开始，没有读取配置和身份验证；失败原因用 WSL 自己的说明，不显示 SSH 的排查提示，底部没有“编辑连接”。
- **容器：** WSL 之后是“容器”分组，列出本机 Docker 和 Podman 正在运行的容器（截图里的容器由测试给出，不运行 docker 或 podman）：
  - 每行显示容器名和“引擎 · 镜像”；选中后右侧显示容器名、引擎标签、`引擎:用户@容器` 地址和“镜像 … · 状态”，说明只进入正在运行的容器、不改动容器、不挂载目录、不保存任何信息，下方可填写容器内用户（ⓘ 说明可填写的格式，留空用镜像默认用户）；
  - 连接失败时步骤从“进入容器”开始，没有读取配置和身份验证；失败原因说明容器已停止、暂停或引擎没有应答，下方是引擎的原始输出，不显示 SSH 的排查提示，底部没有“编辑连接”。

截图不能代替 macOS/Windows 原生窗口验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 空页面 | [浅色英文](remote-connections-empty-light-en-US.png) | [深色中文](remote-connections-empty-dark-zh-CN.png) |
| 已测试连接的概览 | [浅色英文](remote-connections-overview-light-en-US.png) | [深色中文](remote-connections-overview-dark-zh-CN.png) |
| 编辑已保存的连接（展开高级选项） | [浅色英文](remote-connections-edit-light-en-US.png) | [深色中文](remote-connections-edit-dark-zh-CN.png) |
| 新建连接：新分组，主机字段被拒绝 | [浅色英文](remote-connections-refused-light-en-US.png) | [深色中文](remote-connections-refused-dark-zh-CN.png) |
| SSH 密码询问（弹窗） | [浅色英文](remote-connections-password-light-en-US.png) | [深色中文](remote-connections-password-dark-zh-CN.png) |
| 测试失败，诊断展开 | [浅色英文](remote-connections-test-failed-light-en-US.png) | [深色中文](remote-connections-test-failed-dark-zh-CN.png) |
| 测试成功，主机信息标签 | [浅色英文](remote-connections-test-ok-light-en-US.png) | [深色中文](remote-connections-test-ok-dark-zh-CN.png) |
| 连接步骤：主机密钥询问 | [浅色英文](remote-connections-steps-host-key-light-en-US.png) | [深色中文](remote-connections-steps-host-key-dark-zh-CN.png) |
| 连接步骤：密码询问 | [浅色英文](remote-connections-steps-password-light-en-US.png) | [深色中文](remote-connections-steps-password-dark-zh-CN.png) |
| 连接步骤：失败 | [浅色英文](remote-connections-steps-failed-light-en-US.png) | [深色中文](remote-connections-steps-failed-dark-zh-CN.png) |
| 是否信任远程文件夹 | [浅色英文](remote-connections-trust-light-en-US.png) | [深色中文](remote-connections-trust-dark-zh-CN.png) |
| 从 Motty 导入（展开字段映射） | [浅色英文](remote-connections-import-light-en-US.png) | [深色中文](remote-connections-import-dark-zh-CN.png) |
| 从 SSH 配置导入 | [浅色英文](remote-connections-import-ssh-light-en-US.png) | [深色中文](remote-connections-import-ssh-dark-zh-CN.png) |
| 选择远程文件夹 | [浅色英文](remote-connections-folder-light-en-US.png) | [深色中文](remote-connections-folder-dark-zh-CN.png) |
| 主机上的容器（选中一个、填写容器内用户） | [浅色英文](remote-connections-host-containers-light-en-US.png) | [深色中文](remote-connections-host-containers-dark-zh-CN.png) |
| WSL 发行版页（填写 Linux 用户） | [浅色英文](remote-connections-wsl-light-en-US.png) | [深色中文](remote-connections-wsl-dark-zh-CN.png) |
| 连接 WSL 发行版失败 | [浅色英文](remote-connections-wsl-failed-light-en-US.png) | [深色中文](remote-connections-wsl-failed-dark-zh-CN.png) |
| 容器页（填写容器内用户） | [浅色英文](remote-connections-container-light-en-US.png) | [深色中文](remote-connections-container-dark-zh-CN.png) |
| 进入已停止的容器失败 | [浅色英文](remote-connections-container-failed-light-en-US.png) | [深色中文](remote-connections-container-failed-dark-zh-CN.png) |
| 从 devcontainer.json 打开：文件夹未受信任 | [浅色英文](remote-connections-devcontainer-light-en-US.png) | [深色中文](remote-connections-devcontainer-dark-zh-CN.png) |
| 从 devcontainer.json 打开：构建中的 CLI 日志 | [浅色英文](remote-connections-devcontainer-building-light-en-US.png) | [深色中文](remote-connections-devcontainer-building-dark-zh-CN.png) |

复验方法：在仓库根目录把 `LITHE_VISUAL_OUTPUT_DIR` 设为绝对路径 `"$(pwd)/docs/assets/remote-connections"`，然后在 `desktop/` 下运行
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteConnections$' -count=1 -timeout 300s`。
