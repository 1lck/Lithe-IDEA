# 项目树右键“打开于”测试截图

来自生产 Viva Page 的无头渲染，窗口 1100×680，使用隔离的临时项目和配置。深色使用中文、浅色使用英文。
“打开方式”里的应用由测试替换的应用列表给出（TextEdit 为默认，Lithe 有两份同名副本），不读本机的启动服务数据库；
真实列表由 `desktop/internal/fileapps` 向系统查询，见该包测试的日志输出。`before/` 由改动前的 `main`
生成，`after/` 由本分支生成。截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 改动前，文件行右键：顶部有“用其他应用打开…”（直接弹选择应用对话框），底部有“在访达中显示” | [截图](before/file-menu-dark.png) | [截图](before/file-menu-light.png) |
| 改动后，文件行右键：两项都去掉，底部换成“打开于 ›” | [截图](after/file-menu-dark.png) | [截图](after/file-menu-light.png) |
| 改动后，展开“打开于”：打开方式 ›、访达、终端 | [截图](after/file-open-in-dark.png) | [截图](after/file-open-in-light.png) |
| 改动后，展开“打开方式”：默认应用在最前并标“（默认）”，分隔线，其他关联应用（同名的两份 Lithe 后面带所在文件夹），分隔线，“其他…”（原来的选择应用对话框） | [截图](after/file-open-with-dark.png) | [截图](after/file-open-with-light.png) |
| 改动后，文件夹行展开“打开于”：没有“打开方式”，只有访达和终端 | [截图](after/folder-open-in-dark.png) | [截图](after/folder-open-in-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，在 `desktop/` 下通过 `../scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualProjectTreeOpenIn$' -count=1
-timeout 300s` 生成 `after/`。`before/` 用同一测试在改动前的 `filetree_menu.go` 和 i18n 词条上只跑
`file-menu` 场景生成（`main` 上没有“打开于”子菜单）。
