# 标题栏调试、搜索、设置按钮可放到左右工具条测试截图

来自生产 Viva Page 的无头渲染，窗口 1100×680，使用隔离的临时项目和配置。深色使用中文、浅色使用英文。
默认布局和改动前的 `main` 相同（三个按钮都在标题栏右上角），所以只有 `after/`。截图不代表
macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 默认布局：运行配置、运行、调试、搜索、设置都在标题栏右上角 | [截图](after/title-default-dark.png) | [截图](after/title-default-light.png) |
| 按住标题栏的设置按钮拖到右侧栏上方组末尾，还没松开：标题栏原位置变暗，工具条显示落点 | [截图](after/settings-dragging-dark.png) | [截图](after/settings-dragging-light.png) |
| 调试、搜索放到左侧栏上方组末尾，设置放到右侧栏上方组末尾：按工具条按钮排列，标题栏只剩运行配置和运行 | [截图](after/buttons-on-stripes-dark.png) | [截图](after/buttons-on-stripes-light.png) |
| 点工具条上的设置按钮：按钮呈打开状态，设置菜单在按钮内侧（左边）弹出，菜单项与标题栏里相同 | [截图](after/settings-menu-on-stripe-dark.png) | [截图](after/settings-menu-on-stripe-light.png) |
| 指针停在工具条上的搜索按钮：提示在内侧，仍带“搜索 + 快捷键” | [截图](after/search-tip-on-stripe-dark.png) | [截图](after/search-tip-on-stripe-light.png) |
| 右键工具条上的调试按钮：有“移到标题栏”“移动到”“前移/后移”，没有“隐藏” | [截图](after/debug-stripe-menu-dark.png) | [截图](after/debug-stripe-menu-light.png) |
| 右键标题栏的设置按钮，展开“移动到”：可移到六个工具条区 | [截图](after/settings-title-menu-dark.png) | [截图](after/settings-title-menu-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，在 `desktop/` 下通过 `../scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualTitleButtonsOnStripes$'
-count=1 -timeout 300s` 生成 `after/`。
