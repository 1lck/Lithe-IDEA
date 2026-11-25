# 省略文字悬停显示全文的视觉证据

这些图片来自生产视图的 Viva 无头渲染。每张是同一场景在深色/浅色主题、中文/英文下的四张截图拼成的缩小拼图，都是指针停在省略文字上、超过提示延迟之后的画面。悬停前的画面由同一批测试生成，没有提交。

渲染用的是打了全文提示补丁的 Viva（fork PR Lithe-IDEA/Lithe-viva#61，上游 vivaui/viva#454），通过本地 modfile 接入；当前 `desktop/go.mod` 固定的 Viva 版本还没有这项能力。截图不代表 macOS、Windows 原生窗口验收。这些 PNG 只用于代码评审，产品不加载，也不进入发行包。

| 位置 | 场景 | 截图 | 测试 |
| --- | --- | --- | --- |
| 日志窗口 | 消息列被截断，悬停显示整条消息 | [截图](log-message-hover.png) | `TestVisualLogEllipsis` |
| 日志窗口 | 字段列里被截断的字段，悬停显示它完整的键和值 | [截图](log-field-hover.png) | `TestVisualLogEllipsis` |
| 设置 → 工具链 | 安装目录中间被省略，悬停显示完整路径 | [截图](toolchain-path-hover.png) | `TestVisualToolchainEllipsis` |
| 插件画布 | 自绘节点文字被截断，悬停显示全部文字 | [截图](canvas-text-hover.png) | `TestVisualCanvasEllipsis` |
| 状态栏导航路径 | 文件名被截断，悬停显示完整文件名 | [截图](status-path-filename-hover.png) | `TestVisualStatusPathEllipsis` |
| Git 日志 | 提交说明被截断，悬停显示完整说明 | [截图](gitlog-subject-hover.png) | `TestVisualGitLogEllipsis` |
| 信任对话框 | “信任上级目录”里的路径被截断，悬停显示完整位置 | [截图](trust-location-hover.png) | `TestVisualTrustEllipsis` |

日志、工具链和插件画布用的是测试里写死的 fixture；状态栏、Git 日志和信任对话框用真实的临时文件、临时仓库和临时目录。Git 日志和信任对话框按默认窗口尺寸 1280×800 截图。

测试命令（`desktop/` 下，`desktop.mod` 是把 Viva 替换成本地打补丁副本的临时 modfile，不提交）：

```sh
LITHE_VISUAL_OUTPUT_DIR="$PWD/../.artifacts/ellipsis-hover/screenshots" \
GOFLAGS="-modfile=$PWD/../.artifacts/ellipsis-hover/desktop.mod" \
  ../scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' -count=1 -p=1 \
  -run '^TestVisual(Log|Toolchain|Canvas|StatusPath|GitLog|Trust)Ellipsis$' \
  ./internal/logwindow ./internal/settingswindow ./internal/pluginview ./internal/workbench
```
