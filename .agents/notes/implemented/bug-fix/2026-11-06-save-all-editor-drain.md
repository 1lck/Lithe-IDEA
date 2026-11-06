# Agent 笔记：保存全部必须先读取编辑器最后一批输入

状态：已实现

## 先说结论

执行“保存全部”时，即使原生文档镜像当前显示为干净，只要编辑器仍需同步，就必须先等待编辑器交回最新内容。批次的选择规则属于 Rust Core；macOS 向 Core 提供真实同步状态，再由现有保存流程完成同步、取消检查和写入。

## 问题

原生镜像可能尚未收到浏览器编辑器的最后一批输入。旧的批次适配器把所有文档都标成已同步，Core 因而跳过看似干净的文档；用户保存或关闭时可能漏掉这些输入。

## 决策

批次请求中的 `contentSynchronized` 根据文档的 `needsEditorSynchronization` 生成。Core 继续决定哪些文档进入批次；真正的编辑器同步、磁盘写入和取消由现有宿主流程负责。取消或重置发生在同步期间时不得写出迟到内容。

正确做法是将仍需同步的文档交给 Core，即使它尚未标脏；不要把所有原生镜像都标记为已同步。

## 考虑过的备选方案

平台自行把所有打开文档加入保存批次可以避免漏读，但会复制 Core 的只读和成员选择规则，因此复用既有共享计划。

## 后果

干净但需要同步的编辑器会参加一次同步，真正没有改动时现有保存流程不会写磁盘。保存等待编辑器确认，失败或取消不能冒充成功。

## 验证

`cancellingSaveAllDuringRemoteDrainDoesNotWrite` 覆盖正常保存、取消和重置；`shared/fixtures/documents/save-batch-v1.json` 覆盖 Core 对未同步文档的选择。全量测试暴露了修复前不会进入同步回调的问题。

## 适用范围

- `macos/Sources/Lithe/Application/Features/DocumentSaveBatch.swift`
- `macos/Sources/Lithe/Application/Features/DocumentFeatureModel.swift`
- `rust/lithe-core/src/project/document_save_batch.rs`
- `macos/Tests/LitheTests/LitheCoreLogicTests.swift`
