# 侧栏“…”按钮可移动、删除“更新”入口测试截图

来自生产 Viva Page 的无头渲染，窗口 1100×680，使用隔离的临时项目和配置；测试隐藏“提交”入口让“…”按钮出现。
深色使用中文、浅色使用英文。`before/` 由改动前的 `main` 生成，`after/` 由本分支生成。截图不代表
macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 改动前，没有隐藏入口：右侧栏下方组有“更新”（刷新图标）和“背景”两个入口，“更新”只打开占位面板 | [截图](before/stripes-default-dark.png) | [截图](before/stripes-default-light.png) |
| 改动后，没有隐藏入口：右侧栏下方组只剩“背景”，“…”按钮不显示 | [截图](after/stripes-default-dark.png) | [截图](after/stripes-default-light.png) |
| 改动前，隐藏“提交”后点开“…”：按钮固定画在左侧栏上方组下面，不能拖动，右键菜单也没有移动项 | [截图](before/ellipsis-left-list-dark.png) | [截图](before/ellipsis-left-list-light.png) |
| 改动后，隐藏“提交”后点开“…”：按钮默认仍在左侧栏上方组末尾，列表在侧栏内侧（右边）向下展开 | [截图](after/ellipsis-left-list-dark.png) | [截图](after/ellipsis-left-list-light.png) |
| 改动后，按住“…”拖到右侧栏末尾还没松开：原位置变暗，目标位置显示落点 | [截图](after/ellipsis-dragging-dark.png) | [截图](after/ellipsis-dragging-light.png) |
| 改动后，“…”放到右侧栏下方组末尾再点开：列表在侧栏内侧（左边）、从按钮向上展开 | [截图](after/ellipsis-right-bottom-list-dark.png) | [截图](after/ellipsis-right-bottom-list-light.png) |
| 改动后，“…”移到右侧栏上方组（右键“移动到”效果相同）再点开：列表在左边、从按钮向下展开 | [截图](after/ellipsis-right-top-list-dark.png) | [截图](after/ellipsis-right-top-list-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，在 `desktop/` 下通过 `../scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualStripeEllipsis$'
-count=1 -timeout 300s` 生成 `after/`。`before/` 用同一测试在改动前的 `main` 上只跑
`stripes-default` 和 `ellipsis-left-list` 两个场景生成（`main` 上“…”不能拖动，也没有 `itemToolWindows`）。
