# 远程开发连接窗口（#2231）无头测试截图

来自生产 Viva Page 的无头渲染。连接列表由真实 Core 写入测试临时偏好目录；“测试连接”的结果由测试替换的内核直接返回固定的主机信息，不启动 OpenSSH，密码询问由测试直接放入提问队列。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- 保存第二个连接后，列表高亮的是表单正在编辑的连接；测试成功后显示主机名、系统、CPU 数、内存和主目录磁盘；
- 主机字段填了 `user@host` 时，Core 拒绝的原因显示在主机字段下方，没有写入列表；
- OpenSSH 询问密码时，窗口上方弹出“SSH 身份验证”，提示原文照搬，输入框为密码框，说明答案只交给这次连接、不会保存。

截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 测试连接成功 | [浅色英文](remote-connections-tested-light-en-US.png) | [深色中文](remote-connections-tested-dark-zh-CN.png) |
| 主机字段被拒绝 | [浅色英文](remote-connections-refused-light-en-US.png) | [深色中文](remote-connections-refused-dark-zh-CN.png) |
| SSH 密码询问 | [浅色英文](remote-connections-password-light-en-US.png) | [深色中文](remote-connections-password-dark-zh-CN.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/remote-connections"`，在 `desktop/` 下通过
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteConnections$' -count=1 -timeout 180s` 生成。
