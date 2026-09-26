# Agent 笔记：Linux 分支管理器弹窗对齐 Windows 的三分区行为

状态：已实现

## 先说结论

Linux 工作台里，点击项目后面/工具栏上的分支徽标会打开一个弹窗，顶部有三个分区：
**仓库 / 分支 / 工作树**。以前这个弹窗只是 Windows 版本的一个极简子集：只能
列分支、搜索框是自绘的假输入（打不了中文、粘不进去）、工作树分区因为命令名
写错而永远为空、没有键盘上下选择、没有创建工作树、没有仓库列表。现在它的
**可见行为**与 Windows 的 `GitBranchManager`（以及 macOS 分支弹窗的共同部分）
对齐：排序、过滤、标签、建名规则、键盘导航、三个分区的列表与底部动作都按同一
套语义实现。

开发者要记住：**这个弹窗的行为只能以
`windows/tauri/src/features/git/components/git-branch-manager.tsx` 为准**，
不要在 Linux 里另立一套排序或过滤规则。

## 问题

对照 Windows 真源，Linux 侧原来的 `linux/src/workbench/branch_manager.rs` 有几处
明确差距：

- **工作树分区始终为空**：拉取时调用的是 core 命令 `"worktrees"`，而 core 只
  识别 `"git.worktrees"`（`CoreCommand::GitWorktrees`），请求直接失败。
- **搜索框是假的**：用普通 `div` + `on_key_down` 手动拼接 `key_char`，没有
  注册 GPUI 的 input handler，因此中文 IME 与 `Ctrl+V` 都无效（与文件树过滤
  行同样的坑，见 `2026-09-26-linux-explorer-tree-search-parity.md`）。
- **排序/过滤不对**：分支只做字母序、不把当前分支置顶；工作树不过滤 bare /
  prunable；仓库分区形同虚设。
- **没有键盘导航**：Windows 用 `useCommandListNavigation` 支持上下键移动、
  回车执行；Linux 不支持。
- **缺少工作树建行与底部动作**：Windows 在工作树分区可一键 `createWorktree`，
  三分区底部各有 新建 / 刷新 / 添加 动作。

## 决策

### 纯逻辑单独成模块，可单测

新增 `linux/src/workbench/branch_manager_logic.rs`，逐条复刻 Windows 的纯函数：

- `filtered_branches` ← `getFilteredBranches`：当前分支置顶，其余按名称排序，
  再按规范化查询过滤。
- `create_branch_name` ← `getCreateBranchName`：查询非空、不等于当前分支、且
  不存在同名分支时，返回建分支名。
- `filtered_worktrees` / `is_openable_worktree` / `worktree_label` ←
  `getFilteredWorktrees` / `isOpenableGitWorktree` / `getBranchLabel`：过滤
  bare / prunable，当前工作树置顶，无分支时显示 detached / no branch。
- `create_worktree_path` ← `getCreateWorktreePath`：查询非空且不重复时返回建路径。
- `filtered_repositories` ← `getFilteredRepositoryPaths`：当前仓库置顶，按目录名
  排序并过滤。
- `matches_search_query` ← `utils/search-match.ts`：规范化（大小写、非字母数字
  折叠为空格）后按“包含”或“压缩包含”（去空格）匹配。
- `clamp_index` / `move_index` ← `clampCommandListIndex` / `moveCommandListIndex`：
  上下移动**夹紧不循环**。

该模块不依赖 gpui、不做 IO，行为由单测锁定。

### 渲染层只做接线

- 搜索框换成真实 `Input`（`appearance(false)` 关闭自带背景/边框/焦点环，
  保持与原卡片样式一致），`InputEvent::Change` 同步查询、`PressEnter` 执行
  选中项。
- 上下键与 Esc 由弹窗外层 `on_key_down` 处理；字符输入交给 `Input`。
- 三个分区各自的空态、计数、列表行与底部动作按 Windows 结构实现。

### core 命令名以真源为准

工作树拉取从 `"worktrees"` 改为 `"git.worktrees"`；仓库发现使用
`workspace.repositories`。这两条命令都在 core 的 `CoreCommand` 中注册。

### 平台无关

弹窗代码只用 gpui 官方跨平台 API（`InputState`、`cx.spawn`、`CoreClient`、
`cx.emit`），不写任何平台专属路径或系统绑定，保证后续可编译到其它平台。

## 考虑过的备选方案

### 备选方案一：只修 `"worktrees"` → `"git.worktrees"` 这个 bug

这是最小改动，能让工作树分区显示出来。但它不解决排序、过滤、中文输入、
键盘导航和创建工作树，Linux 与 Windows 仍是两套能力。用户要求「对齐另外两个
平台」，因此不采用。

### 备选方案二：整段移植 Windows 的 React 组件

不可行。Windows 是约 1050 行 React/TS，依赖 zustand store、toast、
`showConfirmDialog`、`GitCommandSurface`、`CommandList` 等前端基础设施；
Linux 是 GPUI/Rust，没有 DOM、没有这些 store。可行做法是复用**可见行为与
纯逻辑语义**，而不是复用前端框架代码。

### 备选方案三：把分支/工作树的排序过滤写在渲染函数里

改动看似更小，但会把规则散落在渲染路径上，无法用确定性单测覆盖，后续两端
漂移时也难发现。因此把规则集中进纯逻辑模块。

## 后果

- 收益：三个分区的排序、过滤、标签、建名、键盘导航与 Windows 一致；工作树
  分区从「永远为空」变为真正可用；搜索框支持中文与粘贴。
- 收益：规则集中在纯逻辑模块，11 项单测锁定行为，后续调整只改纯函数。
- 代价：暂未实现 Windows 的分支删除 / 合并 / 变基、工作树删除、确认对话框与
  toast 提示，也不持久化「手动添加的仓库」。这些依赖 Linux 侧尚不存在的
  通用对话框/toast 基础设施，留待后续单独决策。
- 代价：仓库分区在 core 返回为空时回退展示当前仓库（单仓库场景），与 Windows
  依赖 repository store 的多仓库发现不完全等价。

## 验证

- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib`：95 通过，
  其中 `workbench::branch_manager_logic` 11 项覆盖分支置顶与过滤、建分支名
  规则、工作树可打开性与标签、工作树排序与多字段过滤、建工作树路径、仓库
  排序与过滤、路径与目录名工具、命令下标夹紧与移动。
- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux` 通过，无警告。
- 手工验证待做：打开弹窗确认三分区可切换、工作树非空、搜索框可输入中文与
  粘贴、上下键移动选中、回车检出/打开，底部动作可用。

## 适用范围

- `linux/src/workbench/branch_manager.rs`：弹窗状态、core 调用与渲染接线。
- `linux/src/workbench/branch_manager_logic.rs`：排序/过滤/标签/建名纯逻辑。
- `linux/src/i18n.rs`：补齐 `git.*` 文案键（文案抄自 Tauri `locale.ts`）。
- `linux/src/workbench/view.rs`：`BranchManagerView::new(window)`、
  `SelectRepository` 事件接线、打开时设置工作区根。
- 不适用于 Windows 产品；Windows 侧真源是
  `windows/tauri/src/features/git/components/git-branch-manager.tsx` 与
  `windows/tauri/src/features/git/utils/git-worktree-open.ts`。
- macOS 分支弹窗是另一套 UI（`BranchSwitcherPopover`），本决策只对齐共同可见
  行为，不复制 macOS 的动作型布局。
