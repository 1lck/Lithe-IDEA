# 远程工作区在主机上运行（#2231 R1，#43a）无头测试截图

来自生产 Viva Page 的无头渲染。连接、主机和运行配置都由测试替身提供，不连接真实主机、不启动真实进程。截图覆盖深色中文和浅色英文界面，用于确认：

- 远程工作区里内置的运行配置在主机上运行后，Run 窗口的标签页带“主机”徽标，控制台显示主机进程的输出和退出码；
- 标题栏的运行配置菜单列出内置配置，并用一行不可点的说明告诉用户构建工具和插件运行暂不在远程工作区里工作。

截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| Run 窗口 | [深色中文](remote-run-console-dark-zh-CN.png) | [浅色英文](remote-run-console-light-en-US.png) |
| 运行配置菜单 | [深色中文](remote-run-menu-dark-zh-CN.png) | [浅色英文](remote-run-menu-light-en-US.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/remote-run"`，在 `desktop/` 下通过
`../scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRemoteRun$' -count=1 -timeout 300s` 生成。
