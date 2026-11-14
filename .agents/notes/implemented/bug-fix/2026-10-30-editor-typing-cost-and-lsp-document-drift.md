# Agent 笔记：打字成本与语言服务文档漂移

状态：已实现

## 先说结论

语言服务的文档同步曾有一个真实缺陷：两次按键落进同一批时，Core 按“同时发生”重放它们，语言服务器看到的文本和编辑器不一致。现在 `lsp.syncDocument` 的 `contentChanges` 与 LSP 标准语义一致，按数组顺序应用，每个范围相对于前一个结果。桌面端只发送范围改动，超过上限时才发送全文，避免每次停顿都复制整个文档。

## 问题

**文档漂移。** 编辑器在防抖窗口内累积改动，这些改动是先后发生的，后一个的坐标依赖前一个的结果。Core 却按起始位置倒序重放，这只对“同一次编辑里的多个光标”成立。例如 `abcd` 先在第 2 列插入 `X`，再在第 3 列插入 `Y`，编辑器是 `abXYcd`，Core 重放成 `abXcYd`。诊断和补全基于错误的文本，而且不会自愈。

**全文复制。** 如果每次同步都带全文，一个 2 万行文件每次停顿都要跨进程复制约 650 KB。

## 决策

### 同步语义

`contentChanges` 与 LSP `didChange` 相同：按数组顺序应用，每个范围相对于前一个结果。桌面端的 `documentEdited`（`desktop/internal/workbench/pluginsync.go`）把每次编辑按发生顺序追加到待发送队列，因此数组天然满足这一条。

### 只发范围，超上限发全文

待发送队列达到 `maxPendingDocumentChanges` 时，直接标记为全量同步并发送全文，而不是继续累积。全文同步会替换 Core 中的文档并发送全量通知，所以任何漂移都能被纠正。

Core 收到无全文的范围时，要在已保存的文本上应用它；Core 从未收到过的文档返回 `documentNotSynchronized`，由平台重新开启文档。

### 文档版本与诊断

Core 持有语言服务器看到的文档版本。桌面端收到 `lsp.syncDocument` 返回的 `documentVersion` 后记录它（`desktop/internal/pluginlsp/pluginlsp.go`），诊断按这个版本判断是否过期。不要在前端自行从 1 开始递增：同一会话中的文档可能已经打开，或一次同步没有改变内容，前端计数会和实际版本分离，进而误删诊断或接受过期结果。文件关闭和重新关联仍由平台负责，旧关联的异步结果不得覆盖新关联。

正确做法：编辑产生的范围改动按发生顺序排队，同一文档同一时间最多一个同步在途，后续编辑留在队列里。

错误做法：把先后发生的改动按起始位置重新排序后再发送；在前端维护独立版本计数；在每次同步时都发送全文。

## 考虑过的备选方案

- **给请求加开关，保留旧的同时发生语义**：否决。两种语义并存，而所有调用方都在本仓库里，直接改成 LSP 语义更简单。
- **在前端维护独立版本计数**：否决。Core 可能复用文档或判断同步无变化，前端无法可靠推导实际版本。
- **在 Core 校验文本长度或哈希**：否决。长度抓不到内容错误，哈希要扫描全文；由发送方持有最后发出的文本做比较更简单也更强。

## 后果

- 插入大段文本时，超过上限会改为一次全文同步，这是有意的取舍。
- `lsp.syncDocument` 的语义要求所有调用方都按 LSP 顺序语义发送改动。
- 磁盘内容可能滞后于编辑器：自动保存有防抖，运行前保存走统一的保存入口，不受影响。

## 验证

```sh
scripts/desktop/desktop-go.sh test ./internal/pluginlsp/... ./internal/workbench/...
```

Core 侧的 `lsp.syncDocument` 契约测试位于 Core 仓库，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。

## 适用范围

- `desktop/internal/workbench/pluginsync.go`
- `desktop/internal/core/plugin_documents.go`
- `desktop/internal/pluginlsp/pluginlsp.go`
- `shared/platform-feature-matrix/features/lsp-diagnostics.json`
