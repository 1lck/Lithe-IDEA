# Agent 笔记：构建设置剩余的契约缺口

状态：提议中

## 先说结论

「构建、执行、部署」的目录页、工具链页、调试器页和插件页文件夹已经实现，见[构建、执行、部署设置页在大量插件注入时的结构](../../implemented/feature/2026-11-18-build-execution-settings-at-scale.md)。剩下的是需要先改插件契约的几项：调试设置额外聚合到调试器下、插件页引用工具、插件页搜索关键词，以及按 5,000 个插件放宽 Core 上限。它们都要先在 Lithe-core-rust 的契约 PR 里补字段。和已实现的部分一样，这些都是额外的聚合入口，插件自己的设置位置（插件详情的「设置」标签和插件声明的页面）保持不变。

## 问题

- 插件的调试设置现在只在插件自己的设置位置，不能同时聚合到「调试器」页的对应调试器下。
- 插件页需要 JDK、Maven 时只能自己放选择框，同一个工具会在几个页面各选各的。
- 侧栏搜索命中不了插件页里的内容。
- Core 的注册表上限是 128 个插件、512 个工具定义、256 个提供者，单个插件的 `toolDefinitions` 最多 32 个，撑不住几千个插件。

## 提案

下面的字段名都是示意。

| 缺口 | 编号 | 用途 |
| --- | --- | --- |
| `settingPage` 加 `debugAdapterID` | API-19、API-30 | 插件的调试设置额外聚合到「调试器」页的对应调试器下，插件详情里照常保留；现有字段只有 `languageID`、`buildSystemID`、`compilerID` |
| 界面树加工具引用节点 | API-13，沿用 API-33 的 `type:"tool"` | 插件页按工具 ID 引用工具链，点击跳到「工具链」并选中那一行 |
| 页面加 `keywords` | API-19，文字按 API-37 本地化 | 侧栏搜索命中插件页 |
| 注册表上限按 5,000 个插件定 | —（Core 内部上限，不是插件 API） | 放宽插件、工具定义和提供者数量上限 |

另外两项不改契约，等上面的字段落地后在宿主补：

- 插件自用运行时（`audience` 不是用户的工具）默认折叠成一组，出了问题照样计入「需要处理」。
- 工具未找到时，如果插件声明了 `commandInstallers`（API-23），在工具详情里就地给出安装按钮。

## 考虑过的备选方案

### 插件页自己放工具选择框

不用改契约。但同一个 JDK 会在几个插件页各选一次，用户不知道哪个生效。不采用，插件页只引用「工具链」里的工具。

### 宿主按插件 ID 把调试设置聚合到调试器页

不用改契约。但这是按插件名写的分支，违反宿主零依赖。不采用，由插件声明 `debugAdapterID`。

## 验收标准

- lldb 插件声明 `debugAdapterID` 后，它的调试设置同时出现在「调试器」页 lldb-dap 下和插件详情的「设置」标签，两处是同一份草稿。
- Gradle 插件页里的 JDK 显示为工具引用，点击跳到「工具链」并选中 JDK 行。
- 侧栏搜索能命中插件页声明的关键词。
- 插件数量从 10 增加到 5,000 时，加载和投影计算的耗时有测量记录。
- 宿主代码里没有按插件 ID 或工具 ID 写的分支。

## 风险

- 放宽上限前要先测插件加载、工具发现和投影计算的耗时；工具发现应按需、按可见行做，不在打开页面时探测全部工具。
- 关键词本地化依赖 API-37 的包内语言文件，插件没有提供时只能用默认语言匹配。

## 适用范围

- Lithe-core-rust 的 `shared/plugins/contract/v1/plugin-manifest.schema.json`（`settingPage`、`toolDefinitions`）
- `desktop/internal/settingswindow/stepping_view.go`
- `desktop/internal/settingswindow/build_search.go`
- `desktop/internal/settingswindow/toolchains_view.go`
