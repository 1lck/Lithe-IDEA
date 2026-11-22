# 关闭远程工作区时确认远端进程（#2231）无头测试截图

来自生产 Viva 工作台的无头渲染，由 `desktop/internal/workbench/remote_close_visual_test.go` 的 `TestVisualRemoteClose` 生成。主机是测试里的假内核：连接名 “Build box”，主机上为这个工作区运行着一个命名终端（`/bin/bash -l`，已运行 2 小时 5 分钟）和一个未命名进程（`npm run dev`，不到 1 分钟）。截图用于确认：

- 关闭窗口时，只要主机上还有 Lithe 启动的进程就先问：标题“关闭远程工作区？”，正文列出每个进程的类型、名称、命令（原样显示，不脱敏）和已运行时长；按钮依次是“取消”“保留在远端并关闭”“结束并关闭”（默认）；“记住我的选择”旁的 ⓘ 说明之后不再询问、可在 设置 › 工具 › 远程工作区 中修改；
- 选“保留在远端并关闭”后，欢迎页通知“N 个进程保留在 <连接名> 上”；
- 下次连接同一主机并打开文件夹时，接上被保留的会话，列出上次保留的进程，可以“结束这些进程”（只结束它们，不动这次新开的）、“在运行窗口中接回”或“继续运行”；列表里有终端时说明终端无法接回；
- 选“在运行窗口中接回”后，每个保留的进程在 Run 窗口里各开一个带“主机”徽标的标签页，显示接回后的输出，进程继续运行。

截图不代表 macOS/Windows 原生窗口验收，也不代表真实 SSH 主机上的整机验收。

复验：在仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR`，运行
`scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual -run 'TestVisualRemoteClose$' ./internal/workbench/`。

| 场景 | 浅色英文 | 深色中文 |
| --- | --- | --- |
| 关闭时询问 | [浅色英文](remote-close-question-light-en-US.png) | [深色中文](remote-close-question-dark-zh-CN.png) |
| 保留后的通知 | [浅色英文](remote-close-kept-light-en-US.png) | [深色中文](remote-close-kept-dark-zh-CN.png) |
| 下次连接列出保留的进程 | [浅色英文](remote-close-offer-light-en-US.png) | [深色中文](remote-close-offer-dark-zh-CN.png) |
| 在运行窗口中接回 | [浅色英文](remote-close-attached-light-en-US.png) | [深色中文](remote-close-attached-dark-zh-CN.png) |
