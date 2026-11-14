# Agent 笔记：保存全部必须先读取编辑器最后一批输入

状态：已实现

## 先说结论

执行“保存全部”时，编辑器仍在组合输入（例如输入法尚未确认的文字）的文档，必须先等待编辑器交回最新内容，才能进入保存。批次的选择规则属于 Rust Core；宿主向 Core 提供真实的同步状态，再由既有保存流程完成同步、取消检查和写入。

## 问题

宿主的文档镜像可能尚未收到编辑器的最后一批输入。如果把所有文档都标成已同步，Core 会跳过看似干净的文档，用户保存或关闭时就可能漏掉这些输入。

## 决策

保存批次中的 `contentSynchronized` 由宿主根据编辑器状态生成：输入法正在组合文字的文档标记为未同步（`desktop/internal/workbench/documents.go` 组装 `core.SaveBatchDocument` 的位置，类型定义在 `desktop/internal/core/documents.go`）。Core 继续决定哪些文档进入批次。真正的编辑器同步、磁盘写入和取消由既有宿主流程负责；取消或重置发生在同步期间时，不得写出迟到的内容。

正确做法是把仍需同步的文档交给 Core，即使它尚未标记为脏；不要把所有文档都标记为已同步。

## 考虑过的备选方案

宿主自行把所有打开的文档加入保存批次可以避免漏读，但会复制 Core 的只读和成员选择规则，因此复用既有的共享计划。

## 后果

有未交回输入的编辑器会参加一次同步，真正没有改动时既有保存流程不会写磁盘。保存等待编辑器确认，失败或取消不能冒充成功。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench/... ./internal/core/...`：保存全部的取消与重置路径。
- Core 仓库的 [`save-batch-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/documents/save-batch-v1.json) 夹具覆盖 Core 对未同步文档的选择。

## 适用范围

- `desktop/internal/workbench/documents.go`
- `desktop/internal/core/documents.go`
- Core 仓库的文档保存批次实现（project/document_save_batch.rs），以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
