# Agent 笔记：ShowContent 同步宿主内容时不上报 OnEdit，防止 Diff 镜像反馈循环

状态：已实现

## 先说结论

`editorview.View.ShowContent` 用来把宿主提供的最新内容（例如 Diff 侧栏文本、问题预览或虚拟预览文本）直接展示到编辑器视图里，它不是用户编辑，也不保留撤销步骤。因此 `ShowContent` 不得调用 `OnEdit` 向宿主回传差异，否则“视图 → 文档 → 自动保存 → 重载 Diff → `ShowContent`”会形成反馈循环，在无任何编辑操作时持续改写用户文件。

## 问题

在工作区打开未跟踪文本文件的 Diff 页签时（Issue #2377；由 Viva 迁移提交 `0faecba49` / PR #1799 引入）：

1. 初始 `readDiff` 先用 `pane.text`（末行不含换行符）创建右侧 `diffEditor`，并绑定 `OnEdit` 回调 `diffEdited`。
2. 随后 `ensureTablessDocument` 在后台打开该文件的无标签文档（Tabless Document，在后台持有未单独打开页签的工作区文件文本与自动保存状态），并在加载完成后触发 `rebuildDiff` -> `diffSideEditor`。
3. `diffSideEditor` 复用已有右侧视图并调用 `e.view.ShowContent(doc.view.CopyContent())`。
4. 旧实现中 `ShowContent` 直接调用 `replaceFromDisk`，后者不仅压入撤销栈再清空，还调用 `diskEdit` 计算新旧文本差异并通过 `reportEdit` 触发 `OnEdit`。
5. `diffEdited` 收到这个只包含尾部换行符的 `Edit` 后，将其再次 `ApplyEdit` 到无标签文档上，使文档变成脏状态并触发自动保存；保存成功后 `reloadDiffsOfPath` 再次重载 Diff 并调用 `ShowContent`，每轮向文件末尾追加一个 LF 或 CRLF。

## 决策

- 在 `desktop/internal/editorview/view.go` 将 `replaceFromDisk` 拆为内部助手 `replaceContent(content Content, recordUndo, report bool)`：`Reload` 与 `ResolveWithDisk` 保持 `recordUndo=true, report=true`（磁盘外部变更仍保留撤销并通知语言服务器及镜像视图）。
- `desktop/internal/editorview/diffdecor.go` 的 `ShowContent` 改为调用 `v.replaceContent(content, false, false)`，直接清空 `undo`/`redo` 且不计算 `diskEdit`、不调用 `OnEdit`。
- 移除 `desktop/internal/workbench/source_preview.go` 中专程包在 `view.ShowContent` 外的冗余 `p.diffs.mirroring++`/`--` 护栏（保留 `ApplyEdit` 路径的 `mirroring` 计数，因为 `ApplyEdit` 仍按契约向 `OnEdit` 报告编辑）。

正确做法：宿主把文档或拼装好的文本推给从属视图展示时，使用 `ShowContent`，视图只更新显示文本且不回传 `OnEdit`。不要这样做：让 `ShowContent` 走 `replaceFromDisk` 并依赖各个调用方手工加 `mirroring` 计数去屏蔽它本不该发出的 `OnEdit`。

## 考虑过的备选方案

- 仅在 `desktop/internal/workbench/difftab.go` 的 `e.view.ShowContent(content)` 前后包裹 `p.diffs.mirroring++`/`--`：能止住 Diff 侧栏这一处循环，但留下 `ShowContent` 违反自身语义并逼迫其他调用方继续打补丁的根因，也白白在窗口线程做 `rope.Diff` 与撤销快照分配，拒绝。
- 在 `replaceFromDisk` 判断 `if !v.readOnly` 再上报 `OnEdit`：`diffSideEditor` 在调用 `ShowContent` 时对可编辑文档很快会 `SetReadOnly(false)`，一旦视图已处于可写态（例如保存后 `reloadDiffsOfPath` 重建 Diff、切换折行/空白模式）仍会误报，拒绝。

## 后果

所有 `ShowContent` 调用点（Diff 侧栏、问题预览、插件虚拟预览）都不再把宿主同步的展示内容误报为用户编辑，也省去了对应的 `rope.Diff` 与临时撤销快照开销。代价是如果未来有测试或调用方误把 `ShowContent` 当成“带语言服务器 `didChange` 同步的内容替换”，它不会再触发 `OnEdit`；确实需要向文档与语言服务器报告磁盘变化时，必须使用 `Reload` 或 `ResolveWithDisk`。

## 验证

- `desktop/internal/editorview/diffdecor_test.go`：`TestShowContentDoesNotReportEditOrMirrorBack` 验证修复前报出尾部 `\n` 编辑、修复后零上报且文档保持干净。
- `desktop/internal/workbench/difftab_test.go`：`TestDiffTabUntrackedFileDoesNotEditOrAutosaveOnOpenAndReload` 覆盖未跟踪 LF 与 CRLF 文件打开 Diff、无标签文档加载、多轮 `reloadDiffsOfPath` 及关闭页签；修复前首轮即脏且多出 `\n`，修复后全流程保持只读与字节不变。
- 运行 `./scripts/desktop/desktop-go.sh test -race ./internal/editorview/` 与 `./scripts/desktop/desktop-go.sh test -race ./internal/workbench/ -run 'TestDiff|TestDocument'`、`./scripts/desktop/desktop-go.sh test ./...`（`internal/localshell` 在并发负载下超时一次后单独复测通过）、`./scripts/desktop/perf/editor-bench.sh` 前后 `--count 6` 对比均无新引入超预算项。
- Windows 原生实机/虚拟机流程未在 macOS 本机运行，功能矩阵保持 `pending`。

## 适用范围

- `desktop/internal/editorview/view.go`
- `desktop/internal/editorview/diffdecor.go`
- `desktop/internal/editorview/diffdecor_test.go`
- `desktop/internal/workbench/difftab.go`
- `desktop/internal/workbench/difftab_test.go`
- `desktop/internal/workbench/source_preview.go`
