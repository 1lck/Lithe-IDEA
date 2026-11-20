# 安全模式不启动项目代码（#2208）无头测试截图

来自生产 Viva Page 的无头渲染。工作区由测试在临时目录中创建，语言服务器条目由测试直接写入“安全模式未启动”的状态，Commit 窗口在不受信任的工作区中打开，不调用真实 Git、语言服务器或插件。截图覆盖深色与浅色主题、中文与英文界面，用于确认：

- 状态栏语言服务器菜单把被安全模式拦下的服务器显示为锁图标和“LSP 安全模式”，子菜单标题完整显示，并提供“查看日志”和“信任项目…”，没有“重启”；
- Commit 窗口用一段可换行的说明代替更改列表，并提供“信任项目…”。

截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色主题 | 浅色主题 |
| --- | --- | --- |
| 语言服务器菜单（中文） | [深色中文](safe-mode-lsp-dark-zh-Hans.png) | [浅色中文](safe-mode-lsp-light-zh-Hans.png) |
| 语言服务器菜单（英文） | [深色英文](safe-mode-lsp-dark-en.png) | [浅色英文](safe-mode-lsp-light-en.png) |
| Commit 窗口（中文） | [深色中文](safe-mode-commit-dark-zh-Hans.png) | [浅色中文](safe-mode-commit-light-zh-Hans.png) |
| Commit 窗口（英文） | [深色英文](safe-mode-commit-dark-en.png) | [浅色英文](safe-mode-commit-light-en.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/workspace-safe-mode"`，通过
`scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualSafeModeHoldsBackProjectCode$' -count=1 -timeout 180s` 生成。
