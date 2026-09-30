# Agent 笔记：Linux Git 面板部分引入 rgitui 引擎（仅 diff 呈现层）

状态：已实现

## 先说结论

Linux 的 Git 面板**只引入 rgitui 的 diff 呈现层**（vendored 到
`third_party/rgitui/`），用来渲染文件差异；**仓库数据仍然全部来自 macOS/Windows
共用的 `lithe-core` `git.*` 契约**，不使用 rgitui 的 git2 数据层。开发者要记住三
件事：**不要让 rgitui 的 git2 代码参与取数**（它只提供 `FileDiff` 等普通数据类型）；
**diff 数据由 `workbench/git_panel.rs` 把 `git.diff` 的结构化行/块适配成
`rgitui_git::FileDiff`**；**对上游的改动保持“最小、追加式”**（目前只有一处：工作区
根把 `gpui` 从 Zed git rev 改指到 `gpui-pre`）。

## 问题

Linux 的 Git 面板此前只有变更文件列表和提交框，没有 diff 视图；而 Windows 用
Monaco DiffEditor、macOS 用自研 SwiftUI 双栏 diff，两端都有完整的差异审阅体验。
自研一个 GPUI 的 diff 视图（配对、高亮、滚动、折叠）成本高，且与其它端重复。

评估过整包引入 rgitui：它是**仅 bin 的完整 GPUI 应用**（11 个 crate、约 12.4 万
行），钉在另一个 Zed gpui rev 上，且数据层用 **git2/libgit2** —— 整体嵌入不可行，
也与“三端共用 lithe-core 契约”的架构冲突。

## 决策

### 只引入呈现层闭包

vendored 范围：`rgitui_diff`（diff 视图）、`rgitui_ui`（其控件）、`rgitui_theme`
（其外观状态）、`rgitui_git`（**只取普通数据类型**）、`rgitui_settings`。app crate
与 graph/AI/perf/test-support 不引入。

可行性依据（实测）：`rgitui_diff` 直接对着 `gpui-pre 0.3.6` 编译，**0 error /
0 warning**——它用到的 57 个 gpui API 在 `gpui-pre` 中全部存在（上游钉的 Zed rev
与 `gpui-pre` 的快照足够接近）。

### 上游适配只有一处

上游把 `gpui`/`gpui_platform`/`http_client` 钉在 Zed git 仓库；Cargo 把 git 依赖和
registry 依赖当作不同的包身份，类型无法互通。因此 vendored 工作区根把 `gpui` 改指
Lithe 的 `gpui-pre`（lib 名同为 `gpui`），并删除成员未使用的 `rgitui_perf` /
`rgitui_test_support` 可选依赖与 `perf` 特性（代码里的 `#[cfg(feature = "perf")]`
通过声明 `perf = []` 保持已知且关闭）。成员源码除注释外未改，清单见
`third_party/rgitui/README.md`。

### 数据层仍走共享 core

`workbench/git_panel.rs` 调 `git.status` 拉变更列表、`git.diff`（`root` +
`pathspecs` + `staged`）拉单个文件的差异，再把响应适配成
`rgitui_git::FileDiff{ hunks: Vec<DiffHunk{ lines: Vec<DiffLine> }>, additions,
deletions, kind }` 喂给 `DiffViewer::set_diff`。行映射：`context→Context`、
`addition→Addition`、`removal→Deletion`、`changed→Deletion(左)+Addition(右)`、
`information→跳过`；行号来自每个 hunk 的 `@@` 头。

### 正确做法

- 新增 Git 面板能力时，数据一律走 `lithe-core` 的 `git.*`；不要调用 `rgitui_git`
  里基于 git2 的 `Project` 模型或读取函数。
- 面板 UI 复用 `branch_manager` 的 overlay 模式（实体 + `show_*` 标志 + 事件关闭），
  不要另起一套窗口机制。
- 主题切换后调用 `theme::sync_git_engine_theme(cx)`（启动与两处切换路径均已接），
  让引擎的语法高亮跟随应用深浅色。

### 不要这样做

- 不要把 vendored 范围扩到 `rgitui_workspace` / `rgitui` app / 它的 theme JSON
  体系之外再引入第二套设置或键位。
- 不要用 `rgitui_git` 的 git2 代码读仓库；它是被编译进来的传递依赖，不是数据源。
- 不要试图把 rgitui 整包嵌进来：它是仅 bin 的独立应用，无嵌入 API。

## 考虑过的备选方案

### 备选方案一：整体 vendored 并移植整个 rgitui

约 12.4 万行、64 个 gpui API、自带主题/设置/键位/UI kit，且需要同时适配
`gpui_platform`/`http_client`（Zed git）。工作量与风险都不可控，且会引入第二套
Git 语义（git2 数据层）。不采用。

### 备选方案二：纯自研 GPUI diff 视图

与 Windows（Monaco）/macOS（自研 SwiftUI）不一致，且配对、高亮、滚动都需重写。
rgitui 的呈现层已提供这些能力（MIT），复用更省。不采用。

### 备选方案三：裁掉 vendored `rgitui_git` 的 git2 依赖

`rgitui_git/src/types.rs` 中 `git2::Oid` 等类型需替换为自有类型，`rgitui_diff`
又依赖其中的合并快照类型。裁剪会显著偏离上游、提高后续同步成本，且 libgit2 只是
被编译、不参与取数。故保留 libgit2（用户已确认）。

## 后果

- 收益：Linux 获得与上游同级的 diff 审阅视图（统一/分栏、语法高亮、行选择），
  宿主无需自研 diff 渲染；数据层与 Win/mac 保持同一 `lithe-core` 契约。
- 收益：引入面收敛到 5 个 crate（约 4.4 万行）与一处工作区级 gpui 重指向。
- 代价：Linux 构建新增 libgit2（C 编译，来自 `rgitui_git`），它不被用于取数。
- 代价：面板的暂存/取消暂存等操作尚未接入（`git.apply` 可直接支持，属于后续增量）。
- 注意：vendored 副本升级上游时，按 `third_party/rgitui/README.md` 重新应用唯一的
  工作区级适配。

## 验证

- `cargo check -p rgitui_diff`（vendored 工作区，gpui 重指向后）0 error / 0 warning。
- `bash scripts/build-linux.sh` 通过，产物 `target/debug/lithe-linux`。
- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib` 通过。
- 运行应用：侧边栏 Changes 单击变更项打开 Git 面板，diff 与文件切换可用。
- `./scripts/verify-agent-notes.sh` 通过。

## 适用范围

- `third_party/rgitui/`：vendored 的 rgitui diff 呈现层子集与工作区级适配。
- `linux/src/workbench/git_panel.rs`：`git.*` → `FileDiff` 的适配层与面板视图。
- `linux/src/workbench/sidebar.rs`：变更项单击打开面板（双击仍打开源文件）。
- `linux/src/workbench/view.rs`：面板实体的承载、开关与事件订阅。
- `linux/src/theme.rs`：`sync_git_engine_theme`（深浅外观同步）。
- 不适用于 macOS/Windows；两端的 Git UI 由各自前端承担，数据契约不变。
