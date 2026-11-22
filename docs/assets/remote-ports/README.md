# 远程工作区“端口”工具窗口（#2231）无头测试截图

来自生产 Viva Page 的无头渲染，由 `TestVisualRemotePorts` 生成。主机由测试替换的内核模拟：主机上 `node` 同时在 `0.0.0.0:8080` 和 `[::]:8080` 监听，`postgres` 在 `127.0.0.1:5432` 监听，另有一个进程未知的 `10.0.0.5:9000`；本机的 8080 端口被另一个程序占用。测试不启动 OpenSSH，也不在本机真正监听端口。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- 打开工作区和窗口都不会自动转发任何端口：8080 和手动添加的网址是测试里点了“转发”之后才转发的；
- 远端端口列带上主机监听的 IP 地址：同一端口在多个地址监听时显示第一个地址和其余数量（`0.0.0.0:8080 +1`），悬停提示列出全部地址；
- 顶部输入框接受端口、主机:端口或网址；手动添加的 `http://localhost:5173/app` 按输入的样子显示，转发到主机上提供该端口的回环地址，“在浏览器中打开”把主机地址换成本机地址、保留路径；
- 列表列出远端端口、标签、本机地址、进程、来源（监听发现、手动添加）和状态；8080 的本机端口被占用，改用空闲端口 40001，本机地址用警告色显示；状态栏显示已转发的数量；
- 已转发行的右键菜单：在浏览器中打开、复制本机地址、更改本机端口…、停止转发；
- 转发 `10.0.0.5:9000` 这种主机回环地址以外的目标前先询问（S28）；
- “更改本机端口…”打开的对话框：说明转发到本机回环地址的哪个端口，端口被占用时改用空闲端口并在行里注明；
- “转发规则”一节：主机 `127.0.0.1:15432` 转到另一台服务器 `db.internal:5432`；`0.0.0.0:9200` 监听主机的全部网卡，监听地址用警告色；反向转发把主机回环地址上由主机选择的端口转回本机 `127.0.0.1:3000`（测试里已在设置中允许反向转发）；
- 标题栏“+”打开的“添加转发规则”对话框：方向、主机端口、目标各有标题，勾选“监听主机的全部网卡”时显示警告；
- 添加监听全部网卡的规则前的询问：每次都问，不记住；
- 右键“编辑标签…”打开的对话框：标签只记在本机、只属于这个工作区，留空即删除；
- 标签列：端口行和转发规则都能起名（Web UI、Database、DB tunnel）；
- 关闭工作区再打开后：标签还在，之前没停的两个本机转发自动重新转发（本机端口由测试替换的内核重新分配），三条转发规则只列出、不自动启动，状态是“未运行”，行尾有“启动”和“忘记”；原来监听全部网卡的 9200 规则按回环地址列出，全部网卡每次都要重新确认（S27）。

截图不代表 macOS/Windows 原生窗口验收，也不代表真实 SSH 主机上的整机验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 端口列表 | [浅色英文](remote-ports-list-light-en-US.png) | [深色中文](remote-ports-list-dark-zh-CN.png) |
| 已转发行的右键菜单 | [浅色英文](remote-ports-menu-light-en-US.png) | [深色中文](remote-ports-menu-dark-zh-CN.png) |
| 转发回环地址以外的目标前询问 | [浅色英文](remote-ports-confirm-light-en-US.png) | [深色中文](remote-ports-confirm-dark-zh-CN.png) |
| 选择本机端口 | [浅色英文](remote-ports-local-light-en-US.png) | [深色中文](remote-ports-local-dark-zh-CN.png) |
| 转发规则列表 | [浅色英文](remote-ports-rules-light-en-US.png) | [深色中文](remote-ports-rules-dark-zh-CN.png) |
| 添加转发规则 | [浅色英文](remote-ports-rule-light-en-US.png) | [深色中文](remote-ports-rule-dark-zh-CN.png) |
| 监听全部网卡前询问 | [浅色英文](remote-ports-rule-confirm-light-en-US.png) | [深色中文](remote-ports-rule-confirm-dark-zh-CN.png) |
| 编辑标签 | [浅色英文](remote-ports-label-light-en-US.png) | [深色中文](remote-ports-label-dark-zh-CN.png) |
| 标签列 | [浅色英文](remote-ports-labels-light-en-US.png) | [深色中文](remote-ports-labels-dark-zh-CN.png) |
| 重新打开后恢复的转发和记住的规则 | [浅色英文](remote-ports-remembered-light-en-US.png) | [深色中文](remote-ports-remembered-dark-zh-CN.png) |
