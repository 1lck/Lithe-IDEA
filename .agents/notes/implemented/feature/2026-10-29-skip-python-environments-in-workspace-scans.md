# Agent 笔记：工作区扫描默认跳过 Python 环境和字节码

状态：已实现

## 先说结论

打开一个 Python 项目时，Core 会把整个工作区扫一遍（快照，`workspace.snapshot`），而虚拟环境（`.venv`、`venv`）和字节码缓存（`__pycache__`、`*.pyc`）占了绝大多数文件。
现在这四项和 `node_modules` 一样，写进 Rust Core 的内置隐藏名单：扫描时整个目录不再被读取，也不会进入搜索索引。
同时 Windows 请求快照时只要文件清单，不再让 Core 顺带构造整棵目录树。
开发者要记住：名单按名字匹配，名字不同的虚拟环境不会被识别；Windows 文件树仍然读磁盘目录，所以这次没有让 `.venv` 从 Windows 文件树里消失。

## 问题

- 一个典型的 Python 后端项目按旧规则会被扫出约 3.2 万个文件，其中约 2.7 万个在虚拟环境和 `__pycache__` 里。
  这些文件不是用户写的代码，快速打开、全局搜索、Spring/MyBatis/Maven 索引都不需要它们。
- 打开项目时，Windows 会连续请求好几次快照（同步工作区、MyBatis、Spring、Maven 各一次，本地路径没有缓存），每次都重复扫描这几万个文件。
- Windows 请求快照时不传 `includeTree`，Core 默认还会构造并序列化整棵目录树。Windows 文件树按目录单独读取，从不使用这棵树，macOS 早在 #1245 就已经关掉它。

## 决策

### 正确做法

- `rust/lithe-core/src/project/files.rs` 的 `BUILT_IN_HIDDEN_DIRECTORIES` 增加 `.venv`、`venv`、`__pycache__`，`BUILT_IN_HIDDEN_FILE_PATTERNS` 增加 `*.pyc`。
  这份名单同时决定快照、目录列举、搜索索引、文件监听事件是否相关，以及 Git 仓库发现要不要进入某个目录，所以改一处就覆盖这些入口。
- macOS 的 `FileVisibilityRules.swift` 保留自己的一份内置名单（设置页会把它显示出来），同步增加同样的四项，避免页面显示和实际规则不一致。
- 只需要文件清单的调用方请求 `workspace.snapshot` 时带 `includeTree: false`。Windows 的 `fffListFiles`（Quick Open、全局搜索、Spring/MyBatis/Maven 索引经由它取文件）和 Lombok 导航都已这样做。
- 新增类似的“依赖或生成物”目录时，加到 Core 的内置名单，而不是每个调用方各自过滤。

### 不要这样做

- 不要只在前端过滤结果。目录已经被读完、序列化、传给 WebView 之后再丢弃，扫描和内存的代价都已经付出了。
- 不要按 `.gitignore` 默认排除。见下面的备选方案。

## 考虑过的备选方案

### 读取 `.gitignore` 来决定隐藏什么

好处是项目自己声明的忽略项都能覆盖，不用逐个加名字。
没有采用的原因：非 Git 项目和没有写 `.gitignore` 的项目不受益；嵌套的 `.gitignore`、否定规则（`!`）和全局忽略文件的求值成本和正确性都要单独处理；被 Git 忽略但仍想搜索的文件（例如本地配置）会搜不到。
IntelliJ 的做法也是不自动排除：它只在用户编辑忽略文件时提示“是否把被忽略的目录标记为排除”（`IgnoredToExcludedSynchronizer`），由用户确认。

### 用 `pyvenv.cfg` 识别任意名字的虚拟环境

好处是 `env`、`.tox` 之类非常规名字也能被识别，不会误伤同名的普通目录。
没有采用的原因：名单是纯名字匹配，识别需要读目录内容，要改 `VisibilityRules::is_hidden` 的结构。这次先覆盖最常见的两个名字，以后需要时再扩展。

### 像 IntelliJ 那样新增“库根”类别

IntelliJ 把 `.venv` 登记成外部库：保留补全和跳转，但不算项目内容（`WorkspaceFileKind.EXTERNAL`）。
没有采用的原因：库根在 IntelliJ 里是被索引的，性能上不省。Lithe 的语言事实由语言服务器负责，Core 不应该再为依赖库维护第二份索引。如果以后要在文件树里区分展示，应当只做展示，不让它重新进入快照。

## 后果

- 收益：快照、搜索索引、文件监听不再处理虚拟环境和字节码；Python 项目打开时每次快照的文件数约降到原来的七分之一。
- 代价：名字不同的虚拟环境仍会被扫描，用户可以在隐藏路径设置里补一条规则。
- macOS 文件树按目录列举时用同一套规则，所以 `.venv` 在 macOS 文件树里也不再显示，和现在的 `node_modules` 一样。
- Windows 文件树使用前端的 `hiddenDirectoryPatterns`（默认值里有 `__pycache__` 和 `*.pyc`，没有 `.venv`），所以仍能看到 `.venv`。是否也隐藏它是另一个决定，需要同时处理设置迁移。
- 打开“包含生成文件名”的 Search Everywhere 选项时，内置隐藏目录会被重新遍历，`.venv` 也在其中，这与 `node_modules` 现有行为一致。
- Rust 里已有同类名单：`vcs/roots.rs`（Git 仓库发现）和 `execution/workspace_scan.rs`（运行扫描）本来就包含 `.venv`、`venv`、`__pycache__`，这次只是让工作区快照与它们一致。
- 需要重新评估的触发条件：出现不遵守常规命名的虚拟环境集中占用扫描，或者要在文件树里区分展示依赖库时。

## 验证

- `cargo test --lib workspace_snapshot_skips_python_environments_and_bytecode_caches`（在 `rust/lithe-core` 下运行）
- `bun test src/features/file-search`（在 `windows/tauri` 下运行）
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `rust/lithe-core/src/project/files.rs`
- `macos/Sources/LitheCoreContracts/Workspace/FileVisibilityRules.swift`
- `windows/tauri/src/features/file-search/lib/file-search-api.ts`
- `shared/contracts/rust-core-api.md`
