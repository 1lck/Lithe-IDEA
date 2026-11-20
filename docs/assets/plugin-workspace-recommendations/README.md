# 工作区插件推荐无头测试截图

来自生产 Viva Page 的无头渲染。工作区由测试在临时目录中创建（含合成标记文件 `demo.toml` 与源码 `src/main.demo`），插件推荐由注入的合成测试市场索引与推荐目录驱动，不包含任何具体插件或真实插件市场依赖。截图覆盖深色与浅色主题、中文与英文界面，用于确认通知横幅和通知抽屉中主按钮与“不再提示”次级按钮的排版与可读性。截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色主题 | 浅色主题 |
| --- | --- | --- |
| 浮动通知横幅（英文 / 中文主操作按钮） | [深色中文 Toast](toast-dark-zh.png) | [浅色英文 Toast](toast-light-en.png) |
| 通知抽屉历史条目（中文：查看插件 + 不再提示） | [深色中文](notifications-popover-dark-zh.png) | [浅色中文](notifications-popover-light-zh.png) |
| 通知抽屉历史条目（英文：View Plugins + Don't Show Again） | [深色英文](notifications-popover-dark-en.png) | [浅色英文](notifications-popover-light-en.png) |

复验：从仓库根目录设置绝对路径 `LITHE_VISUAL_OUTPUT_DIR="$(pwd)/docs/assets/plugin-workspace-recommendations"`，通过
`scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualPluginWorkspaceRecommendations$' -count=1 -timeout 180s` 生成。
