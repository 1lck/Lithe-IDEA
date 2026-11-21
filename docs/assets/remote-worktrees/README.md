# 远程工作区的 Git 工作树（#2231）无头测试截图

来自生产 Viva Page 的无头渲染，由 `TestVisualRemoteWorktrees` 生成。主机由测试替换的内核模拟：受信任的远程工作区 `/home/dev/project` 是仓库的主工作树，主机上另有关联工作树 `/home/dev/project-feature`。测试不启动 OpenSSH。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- Git 工具窗口的“工作树”页签按主机路径列出工作树，选中关联工作树时详情显示主机路径；
- 新建工作树对话框把 Core 的建议（仓库旁的 `/home/dev/project-topic`）显示为主机路径，输入框下说明路径是主机上的文件夹、由主机上的 Git 创建；“创建后”只有留在当前工作区和打开（在本窗口的新标签页经新会话打开）。

截图不代表 macOS/Windows 原生窗口验收，也不代表真实 SSH 主机上的整机验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 工作树列表 | [浅色英文](remote-worktrees-list-light-en-US.png) | [深色中文](remote-worktrees-list-dark-zh-CN.png) |
| 新建工作树 | [浅色英文](remote-worktrees-create-light-en-US.png) | [深色中文](remote-worktrees-create-dark-zh-CN.png) |
