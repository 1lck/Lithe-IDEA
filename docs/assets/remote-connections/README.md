# 远程开发连接窗口（#2231）无头测试截图

来自生产 Viva Page 的无头渲染。连接列表由真实 Core 写入测试临时偏好目录，颜色、分组和分组顺序都由 Core 保存和给出；“测试连接”的结果由测试替换的内核直接返回固定的主机信息，不启动 OpenSSH，密码询问由测试直接放入提问队列。截图里的主机、用户和路径都是虚构的。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- 左侧列表按 Core 给出的分组列出连接，分组标题带数量，没有分组的连接排在最后的“未分组”下；每个连接左侧是它的颜色条；
- 选中已保存的连接时右侧显示概览：颜色图标、名称、分组标签、地址和跳板机，“主机信息”显示这次运行中最近一次测试得到的系统、CPU、内存和磁盘，“连接设置”逐项列出设置，未填写的项显示它的回退规则，例如“自动（SSH 配置，否则 22）”；
- 点“编辑”后右侧换成表单：名称与颜色、主机与端口、用户名、身份验证与私钥、分组各占一行，高级选项折叠在下方；
- 新建连接时可以选“新建分组…”并在旁边输入分组名；主机字段填了 `user@host` 时，Core 拒绝的原因显示在主机字段下方，没有写入列表；
- OpenSSH 询问密码时，窗口上方弹出“SSH 身份验证”，提示原文照搬，输入框为密码框，说明答案只交给这次连接、不会保存。

截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 已测试连接的概览 | [浅色英文](remote-connections-overview-light-en-US.png) | [深色中文](remote-connections-overview-dark-zh-CN.png) |
| 编辑已保存的连接（展开高级选项） | [浅色英文](remote-connections-edit-light-en-US.png) | [深色中文](remote-connections-edit-dark-zh-CN.png) |
| 新建连接：新分组，主机字段被拒绝 | [浅色英文](remote-connections-refused-light-en-US.png) | [深色中文](remote-connections-refused-dark-zh-CN.png) |
| SSH 密码询问 | [浅色英文](remote-connections-password-light-en-US.png) | [深色中文](remote-connections-password-dark-zh-CN.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/remote-connections"`，在 `desktop/` 下通过
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteConnections$' -count=1 -timeout 180s` 生成。
