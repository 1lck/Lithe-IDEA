# 远程工作区（#2231）无头测试截图

来自生产 Viva Page 的无头渲染。主机由测试替换的内核模拟：连接直接成功，主目录 `/home/dev` 下有 `linked`、`project`、`.cache` 三个文件夹和一个无法读取的条目，项目树的目录列表、心跳、主机上的 `README.md`、`NOTES.md` 和主目录里的 `notes.txt`、终端的输出和搜索索引也由它返回。测试不启动 OpenSSH，也不上传远端服务。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- 连接后“远程开发”窗口改为主机的文件夹选择：顶部是连接名和 `用户@主机`，路径框可以输入 `~` 或 `/` 开头的路径，无法读取的条目在列表下方说明数量，底部显示将打开的主机路径；
- “打开”从未决定过的文件夹时先询问是否信任：显示连接名和主机文件夹，说明安全模式只读取文件夹，底部是“返回”“以安全模式打开”“信任并打开”；
- “以安全模式打开”后远程工作区在新标签页打开：项目树列出主机目录，编辑器上方说明工作区处于安全模式、可以浏览、编辑、保存和搜索主机上的文件，信任文件夹后才能用 Git，右侧是“信任项目…”，空白编辑区提示 Search Everywhere 和 Find in Files，状态栏前端显示 `SSH: 连接名 · 往返时间`；
- 点状态栏的连接项弹出菜单：主机位置、“打开主机上的文件…”、“断开并关闭”和“远程开发…”；
- 在项目树打开 `README.md`：编辑器显示主机上的内容，Markdown 预览照常；
- 主机上的文件被别人改过后再保存：保存被拒绝，通知说明文件在外部被修改，编辑器上方出现“保留编辑器版本 / 加载磁盘版本”，主机上的内容不被覆盖；
- 打开终端工具窗口：终端在主机的文件夹里运行主机的登录 shell，标签页以连接名命名，没有本机 Shell 选择菜单；截图里的命令输出由测试内核返回；
- Find in Files 搜索 `host`：结果来自主机上的 `NOTES.md` 和 `README.md`，带行列号和匹配数；
- Search Everywhere 搜索 `notes`：所有页签都可用（不再只有“操作”），列出主机上的文件名 `NOTES.md` 和它里面匹配的一行；
- “打开主机上的文件…”从窗口顶部弹出路径框，默认 `~/`，列出主目录里的文件夹和文件（文件夹在前、隐藏条目不列），无法读取的条目说明数量，底部说明工作区文件夹以外的文件只读；
- 打开工作区文件夹以外的 `~/notes.txt`：编辑器只读（状态栏是锁），没有预览和编辑按钮，状态栏导航路径显示主机路径 `~/notes.txt`；
- 信任文件夹后 Git 在主机上运行；文件夹位于从上级目录开始的仓库内时，提交工具窗口不显示变更，说明要打开仓库的顶层文件夹。

截图不代表 macOS/Windows 原生窗口验收，也不代表真实 SSH 主机上的整机验收。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 选择主机文件夹 | [浅色英文](remote-workspace-browse-light-en-US.png) | [深色中文](remote-workspace-browse-dark-zh-CN.png) |
| 是否信任主机文件夹 | [浅色英文](remote-workspace-trust-light-en-US.png) | [深色中文](remote-workspace-trust-dark-zh-CN.png) |
| 以安全模式打开的远程工作区 | [浅色英文](remote-workspace-opened-light-en-US.png) | [深色中文](remote-workspace-opened-dark-zh-CN.png) |
| 状态栏连接菜单 | [浅色英文](remote-workspace-menu-light-en-US.png) | [深色中文](remote-workspace-menu-dark-zh-CN.png) |
| 打开主机上的文件 | [浅色英文](remote-workspace-file-light-en-US.png) | [深色中文](remote-workspace-file-dark-zh-CN.png) |
| 保存时主机上的文件已被修改 | [浅色英文](remote-workspace-conflict-light-en-US.png) | [深色中文](remote-workspace-conflict-dark-zh-CN.png) |
| 主机上的终端 | [浅色英文](remote-workspace-terminal-light-en-US.png) | [深色中文](remote-workspace-terminal-dark-zh-CN.png) |
| 在主机的文件夹里搜索 | [浅色英文](remote-workspace-search-light-en-US.png) | [深色中文](remote-workspace-search-dark-zh-CN.png) |
| Search Everywhere 搜索主机 | [浅色英文](remote-workspace-everywhere-light-en-US.png) | [深色中文](remote-workspace-everywhere-dark-zh-CN.png) |
| 按路径打开主机上的文件 | [浅色英文](remote-workspace-host-file-light-en-US.png) | [深色中文](remote-workspace-host-file-dark-zh-CN.png) |
| 工作区以外的文件只读 | [浅色英文](remote-workspace-host-file-readonly-light-en-US.png) | [深色中文](remote-workspace-host-file-readonly-dark-zh-CN.png) |
| 仓库从上级目录开始 | [浅色英文](remote-workspace-git-above-light-en-US.png) | [深色中文](remote-workspace-git-above-dark-zh-CN.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/remote-workspace"`，在 `desktop/` 下通过
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteWorkspace$' -count=1 -timeout 180s` 生成。
