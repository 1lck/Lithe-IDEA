# Agent 笔记：Git 图谱长边与未加载父提交箭头的定位跳转

状态：已实现

## 先说结论

Windows Git Log 图谱里“指向未加载父提交”的箭头（分页或过滤边界）过去只是
装饰：没有点击目标、没有悬停提示，点击会穿透到行本身。本次让这类箭头与
“目标已加载”的长边箭头同样可交互：悬停显示“定位父提交 xxx”，点击在
最多 5 页的预算内继续分页加载直到目标出现并跳转；预算用尽、历史耗尽或
目标被筛选隐藏时给出提示，永不静默失败。同时新增自动补齐：每一批新出现
的缺失父提交自动预加载（同样 5 页预算），让绝大多数箭头出现即可跳。

preview 把图布局下沉到 Rust Core 之后，本修复不再持有布局实现：Core 的
`git.graphProjection` 契约保持 missing 边 `targetHash` 为 `null`，Windows
在 `attachGitGraphCommits` 里从 `parentEdges` 解析出定位目标。共享契约、
共享 fixture 和 macOS 图谱都不需要改动。

## 问题

Core 的 `git.graphProjection` 把父提交不在已加载窗口的边标为 missing：
箭头照画（`hasArrow`），但契约规定 `targetHash` 为 `null`（不虚构已加载
端点）；真实父 hash 只在源行的 `parentEdges[].parentHash` 里。而
`GitGraphArrowTargets`（`git-graph-row.tsx`）只为 `targetHash !== null`
渲染透明按钮——missing 箭头因此零交互。这正是“太长的 graph”的高发场景：
Git Log 按日期序分页（`git.historyPage`），跨分支 merge 的父提交往往在
很远的页里。对照 IntelliJ：未加载边（`NOT_LOAD_COMMIT`）保留 `targetId`，
悬停有手型与 “Jump to commit {hash}” 提示，点击不可见时弹气球说明目标，
任何点击都有反馈（`VisibleGraphImpl.performArrowAction`、
`GraphCommitCellController`）。

IntelliJ 不存在“分页未加载”问题，因为它是全量 permanent graph + 可见性
投影；Lithe 的分页模型要在数据层补齐，才能对齐交互。

## 决策

- **目标解析**：`attachGitGraphCommits`（`git-graph-projection-api.ts`）
  汇总整个窗口的 `parentEdges`，按 print element id
  （`<edge id>:<direction>`）把 missing 边的 `targetHash` 补成对应的
  `parentHash`（`isMissing` 保持 true 区分语义）。必须跨行汇总：Core 把
  未加载父提交的箭头画在源行的下一行，那一行没有自己的 `parentEdges`。
  不改 `git.graphProjection` 契约，因为 macOS 也消费 `targetHash`，
  改契约要同步两端布局与共享 fixture。设计依据是 IntelliJ 的
  `NOT_LOAD_COMMIT` 边保留 `targetId`。
- **按钮**：missing 箭头渲染与长边箭头相同的命中按钮，标题为
  `git.log.locateParent`（“定位父提交 {hash}”）。
- **点击定位**（`git-commit-table.tsx` 的 `navigateToHash`）：目标在列表内
  直接跳；被文本筛选隐藏时提示 `arrowTargetFiltered`；`hasMore` 为 false
  时提示 `arrowTargetUnreachable`（浅克隆边界等）；其余情况在
  `GRAPH_LOCATE_PAGE_BUDGET`（5 页）内循环 `onLoadMore`，命中后由
  `pendingGraphNavigateRef` effect 在新行上选中、滚动并聚焦，预算或推进
  耗尽仍未见目标则提示 `arrowTargetUnreachable`。
- **自动补齐**：`hasMissingParents` 出现新一批时重置 5 页预算，在无筛选、
  `hasMore` 且空闲时主动加载下一页；预算用尽即停，等待用户滚动或显式
  点击。effect 依赖包含 `commits` 引用——只依赖布尔信号时，同步或已空闲
  的加载路径不会链接后续页。
- **拓扑保证与上限理由**：`--date-order` 下父提交一定出现在子提交之后的
  某页，定位总能成功；但大 merge 的旁支父提交可能数千提交之远，浅克隆
  边界的父对象根本不在本地，因此自动与点击定位都必须有界，
  `hasMore=false` 后的缺失箭头视为不可达并说明原因。
- **测试替身**：`git-graph-projection-stub.ts` 的 `missingParents` 选项
  只在分页交互测试中生成 Core 形状的 missing 边，不承担布局规则；
  真实规则仍以共享 fixture 和 Core 为准。

## 考虑过的备选方案

- **对齐 IntelliJ 的全量 permanent graph**：一次性消除所有 missing 边，
  但要放弃现有游标分页并常驻全图内存，是独立的架构工作，不作为本修复
  的前置。
- **在 Core 里直接给 missing 边填 `targetHash = parentHash`**：语义最集中，
  但要改 `rust-core-api.md`、共享 fixture 中十几处规则和 macOS 的 Swift
  消费者，超出本次 Windows 缺陷修复的范围；由宿主解析可得到相同交互且
  不动跨平台契约。
- **Core 按 hash 直达**（`git.historyPage` 的 reference 传父 hash，Core 的
  `validate_reference` 已接受）：一次请求拿到目标祖先链，但与现有游标
  序的合并、去重与排序稳定是新的数据层工作，留作后续优化替换翻页循环。
- **missing 箭头仅提示不可跳**：实现最小，但“箭头出现即可跳”的体验缺口
  仍在；点击定位的翻页成本可控（每页一次进程调用，5 页上限），故不采用。

## 后果

- 绝大多数 missing 箭头在自动补齐后变为普通可跳箭头；远的箭头点击即定位。
- 自动补齐在最坏情况下每批多加载 5 页（每页 50 条）；`MAX_COMMITS` 5000
  上限仍然生效。列表增长后 Core 的 `git.graphProjection` 对整个窗口重算，
  耗时若在真实仓库中可感知，增量布局是独立的性能立项。
- 文本筛选激活时不自动补齐（目标被隐藏，加载无意义），点击提示被隐藏；
  这是 IntelliJ 的同款语义，不强制清除用户的筛选。
- Windows 前端把 Core 的两个字段关联成 UI 目标，属于呈现层职责；若以后
  macOS 也要同样的箭头定位，应优先在共享契约里统一 `targetHash` 语义，
  而不是让两端各写一份解析。
- macOS 图谱是独立实现（Swift 侧），同样的分页缺口需另行确认；本笔记
  只覆盖 Windows。

## 验证

- `windows/tauri`：`bun test src/features/git/api/git-graph-projection-api.test.ts src/test-utils/git-graph-projection-stub.test.ts src/features/git/components/log`
- `windows/tauri`：`bun run typecheck`
- 仓库根目录：`node scripts/i18n/generate-i18n.mjs --check`、
  `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`、
  `./scripts/agent-notes/verify-agent-notes.sh`
- 手动：分页边界 merge 的旁支箭头悬停/点击定位；筛选激活时点击提示；
  浅克隆仓库 `hasMore=false` 后点击提示不可达；普通长边箭头跳转无回归。

## 适用范围

- `windows/tauri/src/features/git/api/git-graph-projection-api.ts`
- `windows/tauri/src/test-utils/git-graph-projection-stub.ts`
- `windows/tauri/src/features/git/components/log/git-graph-row.tsx`
- `windows/tauri/src/features/git/components/log/git-commit-table.tsx`
- `windows/tauri/src/features/git/components/log/git-log-tool-window.tsx`
- `.agents/notes/implemented/feature/2026-09-25-windows-git-graph-branch-colors.md`（图谱对齐系列的既有决策）
