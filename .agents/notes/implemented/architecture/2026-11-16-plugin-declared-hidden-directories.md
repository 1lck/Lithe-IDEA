# Agent 笔记：工具和生态的隐藏目录由插件声明

状态：已实现

## 先说结论

Core 自己只隐藏 `.git`、`.worktree`、`.worktrees` 三个目录，以及 `.DS_Store` 和 `.lithe`。构建产物、依赖、缓存和虚拟环境目录（`target`、`build`、`node_modules`、`.venv` 等）属于具体工具的知识，由提供该工具的插件在清单里声明。宿主读取插件语言时，把已启用插件的清单交给 Core 的 `workspace.configureVisibility`；Core 按这份名单统一决定项目树、搜索、文件事件、本地历史、构建探测和仓库发现跳过哪些目录。日常开发时，要隐藏一个新生态的目录，就去改它的插件，不改 Core 也不改宿主。

## 问题

- Core 里原来有 4 份各自维护的目录名单：可见性规则的 `BUILT_IN_HIDDEN_DIRECTORIES`、本地历史的 `BUILT_IN_IGNORED_DIRECTORY_NAMES`、VCS 根目录探测的 `PRUNED`，以及运行扫描的名单。桌面端的文件图标又写死了一份（`target`、`build`、`out`、`bin`、`dist`、`node_modules`、`.idea`）。同一个目录要不要跳过，在不同入口可能得到不同答案。
- 这些名字是 Cargo、Gradle、npm、Python 等工具的约定。Core 不允许对任何语言或工具做特判（Issue #1856），每支持一个新生态就要改 Core，也违背“工具内容由插件注入”的边界。
- 隐藏这些目录本身仍然必要：一个 Python 项目的虚拟环境和 `__pycache__` 就有约 3.2 万个文件，扫进来会拖慢快照、搜索和索引。问题不在“要不要隐藏”，而在“谁来说出名字”。

## 决策

### 正确做法

- 构建系统插件在 `buildSystems[].layout.hiddenDirectoryNames` 里列出要隐藏的目录名，例如 Cargo 插件写 `target`。VCS 提供者的目录标记（例如 `.svn`）本身就是元数据目录，插件启用期间同样隐藏。名称规则（单个路径片段、不区分 ASCII 大小写、不是通配符、最多 32 个）以 Core 的[插件契约 README](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/README.md) 为准。
- 宿主在 `desktop/internal/workbench/hidden_directories.go` 里把已启用的构建系统插件和 VCS 插件的清单交给 Core，每个插件只发一次。发送时机和插件语言重读相同：工作台启动时，以及安装、启用、禁用、卸载插件之后。
- 一轮重读先调用 `pluginservice.ReadInstalled`：Core 只选一次已启用版本，宿主对每个选中的 `manifest.json` 只做一次有大小上限的读取。语言、工具窗口、命令、VCS 和隐藏目录使用这份相同的字节；选择或读盘失败只在本轮的 `plugin_languages` 处理边界记录一次，其他插件继续提供贡献。各段解析产生的错误仍交给原来的功能边界。
- 快照只属于当前操作，不能保存在 `Service` 或 `App` 里。下一轮安装、更新、启用、禁用或卸载之后重新选择和读取。单独打开构建、调试、工具链或新项目窗口的入口仍建立新的快照；新项目的库存读取保留已禁用插件，其他贡献读取只接受已启用插件。
- Core 为整个进程保存一份名单，每次调用整份替换。名单变化后，宿主让每个打开的标签页重读已展开的目录；名单没变就什么都不做，所以一次插件变化里，后面几个标签页的调用不会重复刷新。
- 文件图标的“排除目录”样式也只认这份名单（`fileicons.SetHiddenDirectoryNames`），不再自己写死名字。
- 过滤放在 Core 里做，所有入口共用一份判断。

正确做法的小例子：

```text
Cargo 插件清单：buildSystems[0].layout.hiddenDirectoryNames = ["target"]
→ 宿主重读插件语言时发给 Core
→ 项目树、搜索、本地历史、仓库发现都跳过任意层级的 target/
```

### 不要这样做

- 不要把 `target`、`node_modules`、`.venv` 之类的名字加回 Core 或宿主的任何名单，也不要在宿主里按插件 ID 写分支。
- 不要在同一轮重读里为每种贡献各调用一次 `ReadInstalled`，也不要在安装或启停之后继续使用上一轮快照。例如工具窗口和隐藏目录必须从同一份清单取得声明；不能前者读到旧版本、后者读到新版本。
- 不要只在界面上过滤结果。目录已经被读完、序列化、传给界面之后再丢掉，扫描和内存的代价都已经付出了。
- 不要默认按 `.gitignore` 隐藏目录，原因见下面的备选方案。

## 考虑过的备选方案

### 在 Core 保留一份“中立”的默认名单

好处是没有安装插件的生态也能隐藏常见目录。没有采用的原因：`target`、`build`、`node_modules` 本身就是工具知识，换个名字叫“中立默认值”并不改变 Core 了解具体工具的事实。用户的决定是这些目录本来就该由插件探测和声明，没有对应插件的生态失去默认隐藏是可以接受的代价。

### 让每种贡献重新读清单，或者长期缓存清单

每种贡献分别读盘会让一次重读选五次版本、读取同一文件五次，更新期间还可能得到不同的内容。长期缓存虽然减少读取，却需要另建安装和启停失效规则。采用只属于当前操作的快照：原生读取集中到一个入口，操作结束即可释放，下一次操作自然读到新内容。

本次只改变文件读取和错误传递的安排。版本选择、清单校验和执行规划继续由 Core 负责；既有贡献段投影函数的字段、默认值和解析规则保持原样。Core 目前没有统一返回全部呈现目录的接口，迁移那些投影需要另外定义类型化返回结果，不能通过增加 Go 解析规则来扩展本次快照。

### 每次请求时由宿主带上目录名

好处是 Core 不用保存状态。没有采用的原因：项目树、搜索、文件事件、本地历史、构建探测、仓库发现都会读目录，每个调用点都要记得带上名单，漏掉一个就会出现两个入口结论不同。插件启用状态本来就是整个应用共用的，在 Core 里存一份进程级名单更不容易出错。

### 读取 `.gitignore` 来决定隐藏什么

好处是项目自己声明的忽略项都能覆盖。没有采用的原因：非 Git 项目和没写 `.gitignore` 的项目不受益；嵌套 `.gitignore`、`!` 否定规则和全局忽略文件都要单独求值；被 Git 忽略但仍想搜索的文件（例如本地配置）会搜不到。IntelliJ 也不自动排除，只在用户编辑忽略文件时提示是否标记为排除（`IgnoredToExcludedSynchronizer`）。

### 像 IntelliJ 那样把依赖目录登记为“库根”

IntelliJ 把 `.venv` 登记成外部库，保留补全和跳转，但不算项目内容。没有采用的原因：库根在 IntelliJ 里仍然会被索引，性能上不省。Lithe 的语言事实由语言服务器负责，Core 不应该再为依赖库维护第二份索引。

## 后果

- 收益：Core 和宿主里不再有任何工具目录名；新生态只改自己的插件；所有读目录的入口共用一份名单，结论一致。
- 代价：没有对应插件，或插件还没发布 `hiddenDirectoryNames` 的生态，`target`、`build`、`node_modules`、`.venv` 等目录会重新出现在项目树里，也会被搜索和本地历史记录。Cargo、Gradle、Maven 插件需要在包含本次接入的桌面端版本发布之后再发布声明。
- 代价：本地历史设置列出的默认规则现在全部是隐藏目录。Viva 桌面端没有“隐藏路径”设置，这些目录始终隐藏，所以删掉其中一行也不会开始记录；设置页的说明已经写明这一点。
- 代价：一轮操作会同时持有全部选中清单的字节，每个文件沿用 `MaxManifestBytes` 上限；已返回的窗口等贡献只共享这些只读字节，不为每个消费者再复制完整清单。快照不保留到下一轮，语法等附属文件仍按各自上限读取。
- 代价：名单是进程级的。单个标签页内按 `pluginReloadGeneration` 丢弃过期重读结果；跨标签页的两次插件重读如果几乎同时完成，后到的结果仍会覆盖先到的结果，下一次重读会纠正，目前没有观察到实际影响。
- 需要重新评估的触发条件：需要按目录内容（例如 `pyvenv.cfg`）而不是名字识别目录，或者桌面端要提供“隐藏路径”设置让用户放开默认隐藏目录时。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/pluginservice -run TestInstalledSnapshot -count=1`：同一轮清单被替换后各贡献仍读取同一份内容，下一轮读到新内容；保留版本、禁用状态、部分失败、取消和清单大小上限。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestPluginReload -count=1`：启用、禁用、重新启用各重读一次，只选择一次已安装版本，隐藏目录随该轮启用状态变化；同时验证过期重读乱序完成时不会覆盖新状态，并仍正常解除初始语言加载阻塞。
- `scripts/desktop/desktop-go.sh test ./internal/core -run TestWorkspaceVisibility -count=1`：真实 Core 隐藏插件声明的目录（任意层级、不区分大小写），被拒的清单不生效，清空后目录重新出现。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestPluginDeclaredFolders|TestHiddenFolders|TestLocalHistorySettingsReachCore' -count=1`：启用插件后项目树隐藏声明的目录，禁用后重新显示；名单变化才重读目录；每个打开的标签页都生效；本地历史的默认规则包含插件声明的目录。
- `scripts/desktop/desktop-go.sh test ./internal/fileicons -count=1`：排除目录图标只认当前名单。
- 本地历史默认规则的 ⓘ 说明截图和复验命令见 `docs/assets/hidden-directories/README.md`。

## 适用范围

- `desktop/internal/pluginservice/installed_snapshot.go`
- `desktop/internal/pluginservice/installed_snapshot_test.go`
- `desktop/internal/workbench/plugin_snapshot_test.go`
- `desktop/internal/workbench/hidden_directories.go`
- `desktop/internal/workbench/plugins.go`
- `desktop/internal/workbench/app.go`
- `desktop/internal/workbench/document_language.go`
- `desktop/internal/core/workspace_visibility.go`
- `desktop/internal/fileicons/fileicons.go`
- `desktop/internal/settingswindow/local_history_view.go`
- Core 实现：[Lithe-core-rust #72](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/72)
- 本文取代已归档的“工作区扫描默认跳过 Python 环境和字节码”（2026-10-29），其中仍有价值的理由已并入上文。
