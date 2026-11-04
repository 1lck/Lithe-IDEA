# Agent 笔记：Windows 工作树外部变化与窗口激活的 Git 状态刷新

状态：已实现

## 先说结论

Windows 端过去只监听 `.git` 元数据目录：外部编辑器改了工作树文件后，Commit
面板不会出现变更；外部提交后回到窗口也不刷新，只能手动点刷新按钮。本次在
前端补了两条链路，把行为对齐 macOS：工作树文件变化转发为 Git 事件
（`GitWorkingTreeChangeHost`），以及窗口重新激活时做一次带冷却的兜底刷新
（`use-git-data-controller` 的 focus 监听）。没有新增任何原生监听。

## 问题

macOS 的 `MacDirectoryWatcher` 监听整个仓库工作区，任何 `repositoryRoot`
内的文件变化都会标记 `gitStateMayHaveChanged` 并调度 Git 刷新；应用重新
激活时 `resumeObservationAfterActivation`（WorkspaceFeatureModel.swift）还会
强制重建监听并立即读一次 Git 状态。Windows 端只有其中一半：

- Rust 侧 `GitMetadataWatcher` 只监听 `.git` 元数据目录和仓库根目录的
  `.gitignore`，工作树文件变化完全不产生事件；外部编辑器保存未暂存文件
  不改 `.git`，所以 Commit 面板收不到任何通知。
- `FileWatcher` 已经把整个工作区的文件变化以 `file-changed` 事件送到前端，
  但只有文件树消费它，Git 事件流（`emitGitChanged`）没有接入。
- `use-git-data-controller` 的激活刷新以 `isGitViewActive`（Git 侧栏面板
  是否激活）为触发沿，从外部应用切回 Lithe 窗口不产生 false→true 转变，
  永不触发；`window` 的 `focus` 事件只刷新 changelists 和索引，不读 Git。
- 元数据监听链路本身也存在断点（watch 安装失败无重试、notify 溢出丢批、
  WebView 后台定时器节流），且没有任何兜底路径能收敛状态。

设计根因记录在
`.agents/notes/proposed/bug-fix/2026-09-13-single-repository-git-status-observation.md`：
那份提案为 macOS 建立了“仓库路径变化必须收敛到一次 Git 刷新”的不变量，
但明确把 Windows 排除在范围外；Windows 后来只实现了元数据监听子集。

## 决策

两条前端改动，都不新增原生监听：

1. **工作树变化桥接**：`GitWorkingTreeChangeHost`
   （`windows/tauri/src/features/git/runtime/git-working-tree-change-host.tsx`，
   app 级挂载在 `workbench-app.tsx`）订阅已有的 `file-changed` 事件，把
   位于某个已知仓库内、且不在 `.git` 目录里的文件变化转发为
   `emitGitChanged({ scopes: ["working-tree"], source: "external-file-change" })`。
   这对齐 macOS `containsRepositoryPath → gitStateMayHaveChanged` 的语义。
   `rescan` 事件不转发（watcher 重建由激活兜底覆盖）。
2. **窗口激活兜底**：`use-git-data-controller` 监听 `window` 的 `focus`，
   在 `WINDOW_FOCUS_GIT_REFRESH_COOLDOWN_MS`（3 秒）冷却外做一次全量
   `refreshGitData(undefined, false, "background")`，对齐 macOS 的
   `resumeObservationAfterActivation`（Windows 侧 watcher 重建已有
   `GitMetadataWatchHost` 的 focus reconcile，无需重复）。这条同时兜住
   元数据链路的所有断点：即使原生事件丢失，回到窗口即收敛。

两个关键选择直接复用现有设计，不引入新机制：

- `source: "external-file-change"` 已在 `PASSIVE_GIT_CHANGE_SOURCES`
  （`git-events.ts`）中：`autoRefreshGitStatus` 关闭时消费端自动忽略、
  工作区索引消费端跳过，无需任何新条件，也避免索引重扫循环。
- 仓库判定用与 `isGitChangeRelevant` 相同归一化强度的本地路径包含检查
  （斜杠与结尾斜杠归一）；不要把 `isGitChangeRelevant({ filePath })`
  当作路径包含检查使用——它第三参 `filePath` 缺省时直接返回 `true`，
  那是文件级匹配语义，不是仓库归属语义。

## 考虑过的备选方案

- **Rust 侧让 `GitMetadataWatcher` 递归监听整个 `repository_root` 并把工作
  树事件分类进 `GitMetadataChange`**：与 `FileWatcher` 形成第二份完整
  工作区监听，防抖批次从“仅 `.git`”膨胀为全树事件流，还要扩展结构化
  payload。被否：重复监听、改动面大，且前端事件系统本就是既定的汇合点。
- **失焦期间后台周期轮询 Git 状态**（对应 IntelliJ 的 background sync）：
  WebView 后台定时器受浏览器节流约束不可靠，macOS 也未实现；激活兜底
  已保证“回到窗口即正确”。被否：收益低且有节流风险。
- **给 Rust watcher 加溢出恢复与安装重试**：修复的是诱因而非后果；激活
  兜底已覆盖后果。保留为后续项，等前端日志显示高频溢出再立项。

## 后果

- 外部修改工作树文件（无论是否在编辑器中打开）会在事件防抖后出现在
  Commit 面板；外部提交、切分支后回到窗口立即收敛，无需手动刷新。
- `autoRefreshGitStatus` 关闭时外部变化不自动刷新，行为与设置语义一致。
- 全量 status 仍是每次刷新的读取方式（一次进程调用）；大仓库若出现
  事件风暴导致的高频全量刷新，后续可参考 IntelliJ 脏范围做按路径增量。
- 已知边界：`FileWatcher` 只监听 workspace folders，打开了仓库子目录时，
  工作区外的仓库部分变化仍收不到事件（激活兜底会收敛状态）；macOS
  提案要求监听 `repositoryRoot`，这个差距保留。

## 验证

- `windows/tauri`：`bun test src/features/git/runtime/git-working-tree-change-host.test.tsx src/features/git/hooks/use-git-data-controller.integration.test.tsx`
- 平台矩阵门禁：`./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- 手动：外部编辑器改文件、外部 `git commit`、外部切分支后激活窗口；
  关闭“自动刷新 Git 状态”后外部变化不打扰。

## 适用范围

- `windows/tauri/src/features/git/runtime/git-working-tree-change-host.tsx`
- `windows/tauri/src/features/git/hooks/use-git-data-controller.ts`
- `windows/tauri/src/features/file-system/services/file-watcher-listener.ts`（仅导出类型）
- `windows/tauri/src/workbench-app.tsx`（挂载）
- `.agents/notes/proposed/bug-fix/2026-09-13-single-repository-git-status-observation.md`（macOS 侧不变量来源）
