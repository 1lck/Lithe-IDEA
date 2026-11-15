# Agent 笔记：工作区扫描默认跳过 Python 环境和字节码

状态：已实现

## 先说结论

Rust Core 的默认工作区规则排除 `.venv`、`venv`、`__pycache__` 和 `*.pyc`。Viva 桌面端的项目树、工作区搜索和快照都经由 Core，所以这套默认规则对所有平台生效。规则按名字匹配，其他名称的虚拟环境不会因此自动识别。

## 问题

- 一个典型的 Python 后端项目如果把虚拟环境和 `__pycache__` 也扫进来，会多出约 3.2 万个文件，其中约 2.7 万个不是用户写的代码。快速打开、全局搜索、Spring/MyBatis/Maven 索引都不需要它们。
- 打开项目时，工作区快照、索引和项目服务会各自请求一次快照，每次都重复扫描这几万个文件。
- 只需要文件清单的调用方如果同时构造整棵目录树并序列化，就会付出额外的内存和传输成本，而目录树并不被使用。

## 决策

### 正确做法

- `rust/crates/core-rules/src/visibility.rs` 的 `BUILT_IN_HIDDEN_DIRECTORIES` 包含 `.venv`、`venv`、`__pycache__`，`BUILT_IN_HIDDEN_FILE_PATTERNS` 包含 `*.pyc`。这份名单同时决定快照、目录列举、搜索索引、文件监听事件是否相关，以及 Git 仓库发现要不要进入某个目录，所以改一处就覆盖这些入口。Core 仓库的位置见 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/core-rules)。
- 只需要文件清单的调用方请求工作区快照时带 `includeTree: false`。
- 新增类似的“依赖或生成物”目录时，加到 Core 的内置名单，而不是每个调用方各自过滤。

### 不要这样做

- 不要只在前端过滤结果。目录已经被读完、序列化、传给界面之后再丢弃，扫描和内存的代价都已经付出了。
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

- 收益：快照、搜索索引、文件监听不再处理虚拟环境和字节码；Python 项目的文件数明显下降。
- 代价：名字不同的虚拟环境仍会被扫描，用户可以在隐藏路径设置里补一条规则。
- 项目树按目录列举时使用同一套规则，所以 `.venv` 不再显示，和 `node_modules` 一样。
- 打开“包含生成文件名”的搜索选项时，内置隐藏目录会被重新遍历，`.venv` 也在其中，这与 `node_modules` 现有行为一致。
- Rust 里已有同类名单：`vcs/roots.rs`（Git 仓库发现）和 `execution/workspace_scan.rs`（运行扫描）本来就包含 `.venv`、`venv`、`__pycache__`，工作区快照与它们保持一致。
- 需要重新评估的触发条件：出现不遵守常规命名的虚拟环境集中占用扫描，或者要在文件树里区分展示依赖库时。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run TestWorkspaceDirectoryAndSearchHidePythonEnvironments -count=3`：真实 Core 的目录列举和搜索均排除四类路径，并保留普通源码文件。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/files.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/files.rs)
- `desktop/internal/core/workspace.go`
- `desktop/internal/core/workspace_tree_test.go`
- `desktop/internal/workbench/filetree.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
