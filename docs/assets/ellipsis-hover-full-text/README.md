# 省略文字悬停显示全文的视觉证据

这些图片来自生产视图的 Viva 无头渲染，都是指针停在省略文字上、过了提示延迟之后的画面。大多数图把同一场景的四张截图缩小后拼在一起：上排深色、下排浅色，左列中文、右列英文。设置侧栏只有英文会截断内置页面名，所以只拼了深色和浅色两张英文截图。悬停前的画面由同一批测试生成，没有提交。

渲染用的是 `desktop/go.mod` 当前固定的 Viva：fork PR Lithe-IDEA/Lithe-viva#64 的 head `600e6846`，即上游 vivaui/viva#454 同步进 fork 的版本。它提供页面级开关 `PageConfig.EllipsisTooltips` 和按区域指定方向的 `EllipsisTooltipOn`。截图不能代替 macOS、Windows 原生窗口验收。这些 PNG 只用于代码评审，产品不加载，也不进入发行包。

## 提示框开在哪一侧

全文提示朝向内容、不压住同一列表里相邻的行。只有下表列出的区域指定了方向，其他地方都默认开在文字下方；指定的一侧放不下时，Viva 会翻到对侧。

| 区域 | 方向 | 原因 |
| --- | --- | --- |
| 左侧工具窗口 | 右 | 朝向编辑器，不压住下面的行 |
| 右侧工具窗口 | 左 | 朝向编辑器 |
| 底部工具窗口 | 上 | 朝向编辑器；不指定时，上面几行开在下方，靠近窗口底边的行才翻到上方 |
| 状态栏 | 上 | 状态栏贴着窗口底边；不指定时也会翻到上方，指定后省掉翻转 |
| 设置窗口侧栏 | 右 | 开在右侧页面上，不压住下面的页面名 |
| 日志窗口通道侧栏 | 右 | 开在右侧表格上，不压住下面的通道 |

### 改动前后对照

“改动前”的图用同一批截图测试生成：临时把工具窗口、设置侧栏和日志侧栏的方向改回默认的 `ui.TooltipBottom`，截完后恢复代码。这和改动前的 main 一样，所有提示都开在下方。状态栏改动前就会翻到上方，没有对照图。

| 区域 | 改动前（开在下方） | 改动后 |
| --- | --- | --- |
| 提交工具窗口（左侧） | [截图](commit-left-path-hover-before.png)：开在文件行下方，有更多改动时会盖住后面的文件 | [截图](commit-left-path-hover.png)：开向右侧编辑器 |
| 提交工具窗口（右侧） | [截图](commit-right-path-hover-before.png)：同上 | [截图](commit-right-path-hover.png)：开向左侧编辑器 |
| 提交工具窗口（底部） | [截图](commit-bottom-path-hover-before.png)：盖住“修订”和提交说明 | [截图](commit-bottom-path-hover.png)：开向上方编辑器 |
| 设置窗口侧栏 | [截图](settings-sidebar-hover-before.png)：盖住下一项 “Languages & Frameworks” | [截图](settings-sidebar-hover.png)：开在右侧页面上 |
| 日志窗口通道侧栏 | [截图](log-sidebar-hover-before.png)：开在侧栏下方，越过侧栏边界 | [截图](log-sidebar-hover.png)：开在右侧表格上 |

## 截图

| 位置 | 场景 | 截图 | 测试 |
| --- | --- | --- | --- |
| 日志窗口 | 消息列被截断，悬停显示整条消息 | [截图](log-message-hover.png) | `TestVisualLogEllipsis` |
| 日志窗口 | 字段列里被截断的字段，悬停显示它完整的键和值 | [截图](log-field-hover.png) | `TestVisualLogEllipsis` |
| 日志窗口通道侧栏 | 插件的长通道名被截断，全文开在右侧表格上 | [截图](log-sidebar-hover.png) | `TestVisualLogSidebarEllipsis` |
| 设置 → 工具链 | 安装目录中间被省略，悬停显示完整路径 | [截图](toolchain-path-hover.png) | `TestVisualToolchainEllipsis` |
| 设置窗口侧栏 | “Build, Execution, Deployment”被截断，全文开在右侧页面上 | [截图](settings-sidebar-hover.png) | `TestVisualSidebarEllipsis` |
| 插件画布 | 自绘节点文字被截断，悬停显示全部文字 | [截图](canvas-text-hover.png) | `TestVisualCanvasEllipsis` |
| 状态栏导航路径 | 文件名被截断，全文开在上方 | [截图](status-path-filename-hover.png) | `TestVisualStatusPathEllipsis` |
| Git 日志 | 提交说明被截断，悬停显示完整说明 | [截图](gitlog-subject-hover.png) | `TestVisualGitLogEllipsis` |
| 提交工具窗口（左侧） | 改动文件的长目录被截断，全文开在右侧编辑器上 | [截图](commit-left-path-hover.png) | `TestVisualCommitEllipsisSides` |
| 提交工具窗口（右侧） | 同上，全文开在左侧编辑器上 | [截图](commit-right-path-hover.png) | `TestVisualCommitEllipsisSides` |
| 提交工具窗口（底部） | 同上，全文开在上方编辑器上 | [截图](commit-bottom-path-hover.png) | `TestVisualCommitEllipsisSides` |
| 信任对话框 | “信任上级目录”里的路径被截断，悬停显示完整位置 | [截图](trust-location-hover.png) | `TestVisualTrustEllipsis` |

日志、工具链、插件画布和设置侧栏用测试里写死的 fixture。状态栏、Git 日志、提交工具窗口和信任对话框用真实的临时文件、临时仓库和临时目录。Git 日志、提交工具窗口和信任对话框按默认窗口尺寸 1280×800 截图。

测试命令（在 `desktop/` 下运行）：

```sh
LITHE_VISUAL_OUTPUT_DIR="$PWD/../.artifacts/ellipsis-hover/screenshots" \
  ../scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' -count=1 -p=1 \
  -run '^TestVisual((Log|LogSidebar|Sidebar|Toolchain|Canvas|StatusPath|GitLog|Trust)Ellipsis|CommitEllipsisSides)$' \
  ./internal/logwindow ./internal/settingswindow ./internal/pluginview ./internal/workbench
```
