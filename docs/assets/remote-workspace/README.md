# 远程工作区（#2231）无头测试截图

来自生产 Viva Page 的无头渲染。主机由测试替换的内核模拟：连接直接成功，主目录 `/home/dev` 下有 `linked`、`project`、`.cache` 三个文件夹和一个无法读取的条目，项目树的目录列表、心跳和主机上的 `README.md` 也由它返回。测试不启动 OpenSSH，也不上传远端服务。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- 连接后“远程开发”窗口改为主机的文件夹选择：顶部是连接名和 `用户@主机`，路径框可以输入 `~` 或 `/` 开头的路径，无法读取的条目在列表下方说明数量，底部显示将打开的主机路径；
- “打开”后远程工作区在新标签页打开：项目树列出主机目录，编辑器上方说明主机上的文件可以打开、编辑和保存，终端、搜索、Git 和运行暂不可用，空白编辑区只提示 Search Everywhere（只有“操作”页），状态栏前端显示 `SSH: 连接名 · 往返时间`；
- 点状态栏的连接项弹出菜单：主机位置、“断开并关闭”和“远程开发…”；
- 在项目树打开 `README.md`：编辑器显示主机上的内容，Markdown 预览照常；
- 主机上的文件被别人改过后再保存：保存被拒绝，通知说明文件在外部被修改，编辑器上方出现“保留编辑器版本 / 加载磁盘版本”，主机上的内容不被覆盖。

截图不代表 macOS/Windows 原生窗口验收，也不代表真实 SSH 主机上的整机验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 选择主机文件夹 | [浅色英文](remote-workspace-browse-light-en-US.png) | [深色中文](remote-workspace-browse-dark-zh-CN.png) |
| 打开的远程工作区 | [浅色英文](remote-workspace-opened-light-en-US.png) | [深色中文](remote-workspace-opened-dark-zh-CN.png) |
| 状态栏连接菜单 | [浅色英文](remote-workspace-menu-light-en-US.png) | [深色中文](remote-workspace-menu-dark-zh-CN.png) |
| 打开主机上的文件 | [浅色英文](remote-workspace-file-light-en-US.png) | [深色中文](remote-workspace-file-dark-zh-CN.png) |
| 保存时主机上的文件已被修改 | [浅色英文](remote-workspace-conflict-light-en-US.png) | [深色中文](remote-workspace-conflict-dark-zh-CN.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/remote-workspace"`，在 `desktop/` 下通过
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteWorkspace$' -count=1 -timeout 180s` 生成。
