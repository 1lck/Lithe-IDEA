# 欢迎页四个开始按钮测试截图

来自生产 Viva Page 的无头渲染，窗口高 600，宽度为默认的 1280 和窗口允许的最小宽度 900，使用隔离的临时配置。
深色使用中文、浅色使用英文。截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 改动前（`main`），宽 1280：新建项目、打开、更多，克隆仓库和远程开发收在“更多”菜单里 | [截图](before/welcome-1280-dark.png) | [截图](before/welcome-1280-light.png) |
| 改动后，宽 1280：新建项目、打开、克隆仓库、远程开发四个按钮并排 | [截图](after/welcome-1280-dark.png) | [截图](after/welcome-1280-light.png) |
| 改动后，最小宽度 900：四个按钮仍完整显示，由搜索框让出宽度 | [截图](after/welcome-900-dark.png) | [截图](after/welcome-900-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，在 `desktop/` 下通过 `../scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualWelcomeStartButtons$'
-count=1 -timeout 300s` 生成 `after/`；把该测试文件复制到 `main` 的检出里运行，生成 `before/`。
