# 编辑器基础能力测试截图

来自生产 Viva Page 的无头渲染，使用隔离的临时项目、配置和公开演示内容。
深色使用中文、浅色使用英文。截图不代表 macOS/Windows 原生窗口验收。

| 能力 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 文件内查找替换 | [截图](find-replace-dark.png) | [截图](find-replace-light.png) |
| 恢复后的磁盘冲突 | [截图](recovery-conflict-dark.png) | [截图](recovery-conflict-light.png) |
| 最近编辑 | [截图](recent-edits-dark.png) | [截图](recent-edits-light.png) |
| Scratch 编辑 | [截图](scratch-editor-dark.png) | [截图](scratch-editor-light.png) |
| 持久草稿列表 | [截图](scratch-list-dark.png) | [截图](scratch-list-light.png) |
| 编辑器设置 | [截图](editor-settings-dark.png) | [截图](editor-settings-light.png) |
| 命名快捷键方案 | [截图](keymap-schemes-dark.png) | [截图](keymap-schemes-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，通过 `scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench ./internal/settingswindow
-run '^TestVisualEditorEssentials' -count=1 -timeout 120s` 生成。
生产路径使用固定 Core 修订；开发中可用 `LITHE_CORE_RUST_DIR` 指向包含本功能的 Core 检出。
