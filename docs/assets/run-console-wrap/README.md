# 运行控制台自动换行测试截图

来自生产 Viva Page 的无头渲染，使用隔离的临时项目和配置。控制台内容是测试注入的合成构建输出（make 与 cc 命令、
带颜色的警告和带链接的结尾行），不代表任何真实插件或构建系统的输出。深色使用中文、浅色使用英文。
截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 自动换行关闭（默认）：超出控制台宽度的行在右边缘以“…”结尾，被截掉的部分仍可选中和复制；右侧工具栏第一个按钮是“自动换行”开关 | [截图](run-console-cut-dark.png) | [截图](run-console-cut-light.png) |
| 点击“自动换行”后：开关保持按下的背景，长行在空格处折成多行，警告的颜色和链接颜色跨行保留 | [截图](run-console-wrapped-dark.png) | [截图](run-console-wrapped-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，通过 `scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualRunConsoleWrap$'
-count=1 -timeout 180s` 生成。
