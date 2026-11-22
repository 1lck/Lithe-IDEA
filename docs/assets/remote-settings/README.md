# “设置 › 工具 › 远程工作区”页（#2231）无头测试截图

来自生产 Viva 设置窗口的无头渲染，由 `TestVisualRemoteWorkspace` 生成。页面经真实的 Core 客户端调用 `remote.preferences`，偏好目录和主目录都是测试里的虚构路径（`/Users/example`），打开页面和起草都不创建任何文件。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- “SSH 程序”默认显示“自动（Core 在 PATH 上找到的 ssh 路径）”，旁边的“选择…”选一个文件作为草稿；
- “SSH 配置文件”只读显示 Core 读取的 `~/.ssh/config` 路径，文件不存在时在路径后注明“不存在”，注明不随宽度截断；
- “自动重连时长”默认“自动（1 分钟）”，草稿状态选了 5 分钟；
- “端口转发”一节的“反向转发”默认“自动（不允许）”，ⓘ 说明主机上的所有用户都能连接反向转发的端口、每条规则仍会确认；
- “保存位置”显示偏好目录下的 `remote/preferences.json`，还没有文件时注明“修改后才创建”，路径过长时截断并在悬停提示里给出完整路径；
- 修改只是草稿：侧栏页名后有圆点，底部显示未应用的数量和写入目标，点“应用”或“好”才写入。

截图不代表 macOS/Windows 原生窗口验收，也不代表真实 SSH 主机上的整机验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 自动值 | [浅色英文](remote-settings-automatic-light-en-US.png) | [深色中文](remote-settings-automatic-dark-zh-CN.png) |
| 选择 SSH 程序和重连时长后的草稿 | [浅色英文](remote-settings-drafts-light-en-US.png) | [深色中文](remote-settings-drafts-dark-zh-CN.png) |
