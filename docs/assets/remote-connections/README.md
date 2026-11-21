# 远程开发连接窗口（#2231）无头测试截图

截图来自生产 Viva Page 的无头渲染。连接列表由真实 Core 写入测试的临时偏好目录，颜色、分组和分组顺序都由 Core 保存并返回。下列内容都由测试直接给出固定值，不读取本机配置，也不启动 OpenSSH：

- “测试连接”的结果：由测试替换的内核返回固定的主机信息；
- `ssh -G` 解析出的生效设置；
- 空页面上 Motty 和 `~/.ssh/config` 的可导入数量；
- 导入页的 Motty 主机；
- OpenSSH 的主机密钥和密码询问。

截图里的主机、用户、指纹和路径都是虚构的。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- **空页面：** 左侧只有搜索、导入、新建和“还没有保存的连接”。右侧是“通过 SSH 连接 Linux 主机”：
  - 一个 `user@host:22` 地址框，交给 Core 解析后填入新连接；
  - “从 Motty 导入”和“从 ~/.ssh/config 导入”两张卡片，各显示可导入的主机数；
  - “手动填写”。
- **列表与概览：** 连接按 Core 给出的分组列出，分组可以折叠。每行显示：
  - 图标：测过的主机显示系统名的前两个字母（Ubuntu 显示“Ub”），没测过的显示名称首字母，都用连接的颜色；
  - 名称、地址和上次连接时间。
- **概览页：** 选中连接后右侧显示：
  - 顶部：图标、颜色点、名称、分组标签，地址后跟跳板机；
  - 按钮：“编辑”、“⋯”和“打开文件夹…”；
  - 各区块：“最近打开的文件夹”、“主机信息”（主机名、系统、CPU、内存、磁盘，以及测试时间和“重新测试”）、“生效的 SSH 设置”。生效设置逐项列出 `ssh -G` 解析出的值和来源（本连接 / SSH 配置 / 默认值）。
- **编辑与新建：** 在表单中编辑连接，高级选项可以展开。主机字段填了 `user@host` 时，Core 拒绝的原因显示在主机字段下方，连接不会写入列表。测试失败时，结果显示在表单顶部，OpenSSH 的原始诊断默认展开。
- **连接步骤：** 依次为读取配置、连接主机、身份验证、检查平台、安装服务端、启动会话：
  - OpenSSH 的主机密钥询问显示在“连接主机”下方，带密钥类型和指纹，按钮为“拒绝”和“信任并继续”；
  - 密码询问显示在“身份验证”下方；
  - 失败时标出失败的步骤并展开诊断。
- **SSH 密码询问（弹窗）：** 窗口上方弹出“SSH 身份验证”，提示原样显示。
- **信任文件夹：** 第一次打开远程文件夹时询问是否信任，可以选择只信任这个文件夹或信任它的上级目录。
- **导入：** 页面右上角在 Motty 和 `~/.ssh/config` 之间切换，并显示数据来源路径。可以选择保留分组和保留颜色。每台主机标出状态（可导入 / 部分导入 / 已存在 / 非 SSH），不能导入的主机不能勾选。底部显示已选择的数量。

截图不能代替 macOS/Windows 原生窗口验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 空页面 | [浅色英文](remote-connections-empty-light-en-US.png) | [深色中文](remote-connections-empty-dark-zh-CN.png) |
| 已测试连接的概览 | [浅色英文](remote-connections-overview-light-en-US.png) | [深色中文](remote-connections-overview-dark-zh-CN.png) |
| 编辑已保存的连接（展开高级选项） | [浅色英文](remote-connections-edit-light-en-US.png) | [深色中文](remote-connections-edit-dark-zh-CN.png) |
| 新建连接：新分组，主机字段被拒绝 | [浅色英文](remote-connections-refused-light-en-US.png) | [深色中文](remote-connections-refused-dark-zh-CN.png) |
| SSH 密码询问（弹窗） | [浅色英文](remote-connections-password-light-en-US.png) | [深色中文](remote-connections-password-dark-zh-CN.png) |
| 测试失败，诊断展开 | [浅色英文](remote-connections-test-failed-light-en-US.png) | [深色中文](remote-connections-test-failed-dark-zh-CN.png) |
| 连接步骤：主机密钥询问 | [浅色英文](remote-connections-steps-host-key-light-en-US.png) | [深色中文](remote-connections-steps-host-key-dark-zh-CN.png) |
| 连接步骤：密码询问 | [浅色英文](remote-connections-steps-password-light-en-US.png) | [深色中文](remote-connections-steps-password-dark-zh-CN.png) |
| 连接步骤：失败 | [浅色英文](remote-connections-steps-failed-light-en-US.png) | [深色中文](remote-connections-steps-failed-dark-zh-CN.png) |
| 是否信任远程文件夹 | [浅色英文](remote-connections-trust-light-en-US.png) | [深色中文](remote-connections-trust-dark-zh-CN.png) |
| 从 Motty 导入 | [浅色英文](remote-connections-import-light-en-US.png) | [深色中文](remote-connections-import-dark-zh-CN.png) |

复验方法：在仓库根目录把 `LITHE_VISUAL_OUTPUT_DIR` 设为绝对路径 `"$(pwd)/docs/assets/remote-connections"`，然后在 `desktop/` 下运行
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteConnections$' -count=1 -timeout 300s`。
