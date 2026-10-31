# Agent 笔记：打字成本与语言服务文档漂移

状态：已实现

## 先说结论

Lithe 的 LSP 文档同步有一个真实缺陷：两次按键落进同一批时，Core 按“同时发生”重放它们，语言服务器看到的文本和编辑器不一致。现在 `lsp.syncDocument` 的 `contentChanges` 改成 LSP 标准语义，按顺序应用。修好之后 Windows 不再需要每次发送全文，2 万行文件的 IPC 从每键约 650 KB 降到约 17 KB。同时，TextMate 分词在规则状态收敛时停止，不再每次重做到文件末尾。

## 问题

**文档漂移。** 编辑器在防抖窗口（75 毫秒）内累积改动，这些改动是先后发生的，后一个的坐标依赖前一个的结果。Core 却按起始位置倒序重放，这只对“同一次编辑里的多个光标”成立。例如 `abcd` 先在第 2 列插入 `X`，再在第 3 列插入 `Y`，编辑器是 `abXYcd`，Core 是 `abXcYd`。宿主虽然也发了全文，但 Core 只在重放不安全时才看它，所以漂移不会自愈，诊断和补全基于错误的文本。macOS 和 Windows 都受影响。

**全文复制。** Windows 每次同步都带全文，而且 Java 运行标记等功能会在防抖之前再发一次全文，所以范围改动实际上从未走到。

**分词范围。** 分词 worker 每次编辑后从改动行重做到文件末尾，每 128 行回传一批，主线程逐 token 处理。一个文件后面的行只通过规则状态依赖前面的行，状态没变就不必重做。

## 决策

### 同步语义

`contentChanges` 与 LSP `didChange` 相同：按数组顺序应用，每个范围相对于前一个结果。宿主负责让数组满足这一点。macOS 的 `pendingLanguageServerChanges` 本来就是逐个累积的，Windows 的 `queueLspDocumentChanges` 把同一次编辑的范围按从后到前排列，这样它们互不影响。

`text` 变成校验手段：宿主给了全文且与重放结果不同，Core 用全文替换文档并发送全量通知，所以漂移能自愈。macOS 继续发全文，得到这个保护。

### Windows 只发范围

Windows 不发全文，否则每次停顿都要跨 IPC 复制整个文档。代价是 Core 无法校验，所以校验放在 `LspClient`：它记得最后发出的文本，发送前把范围重放到这份文本上，结果等于编辑器当前内容才只发范围，否则发全文。这覆盖了全文同步抢先、外部重载、改动已被保存流程发布等所有情况。范围被 Core 拒绝时也退回全文。超过 32 个改动的批次直接发全文。

Core 收到无全文的范围时，在未打开或未就绪的文档上也要能工作：把范围应用到已保存的文本。Core 从未收到过的文档返回 `documentNotSynchronized`。

`ensureDocumentSynchronized` 和保存前的同步先发送排队的范围，这样后面的全文同步通常发现内容相同，不再复制。

### 分词收敛

`frontend/editor/src/textmate-document.ts` 持有 worker 里的文档状态，可以脱离 worker 单测。重新分词到某行时，如果该行结束状态与之前相同且已越过改动范围，就直接跳过后面的行。

收敛只对主线程真正收到的行成立，这是这里最容易出错的地方。主线程会丢弃版本过期的结果，但 worker 的状态已经更新：输入 `/*` 后 worker 把后面的行都算成注释，结果被丢弃；下一次按键时状态“已经相同”，于是收敛，而编辑器里的颜色永远不更新。因此主线程丢弃结果时回报 `stale`，worker 把这些行标记为必须重发。

被打断的分词要能接着做：更早的编辑把游标拉回去时，`resume` 记住原来走到哪里，收敛后跳回那里，而不是直接跳到文件末尾。

### 其余按键路径成本

- 自动保存防抖从 150 毫秒改为 1 秒，失焦时立即写入。每次写入都让 JDT 重新加载文件，150 毫秒意味着每个单词间隙都写一次。
- Spring 和 MyBatis 索引的重建防抖同样改为 1 秒。每次重建都重新解析工程，并复制所有打开的文件。
- 行列位置由 `SourceText` 的片段树给出（对数复杂度），不再从文件头逐字符扫描。
- `isSparseLineArray` 不再用 `Object.keys` 枚举整个数组。

## 考虑过的备选方案

- 给请求加 `contentChangesSequential` 开关，保留旧语义：否决。两种语义并存，而所有宿主都在这个仓库里，直接改成 LSP 语义更简单。
- 在 Core 校验 Windows 的文本长度或哈希：否决。长度抓不到内容错误，哈希要在 JS 里扫描全文。前端已经持有最后发出的文本，重放比较更简单也更强。
- 分词时用 worker 自己的判断，不要主线程回报：否决。上面的注释例子说明没有回报就会漏更新。

## 后果

- 插入大段文本时，分词仍需重做到状态收敛，这是必要的工作。
- `lsp.syncDocument` 的语义变化需要所有宿主同时更新；两端都在本仓库，外部没有调用方。
- 打字时磁盘内容最多滞后 1 秒。运行前保存走 `handleSaveAll`，不受影响；终端等面板通过失焦写入覆盖。

## 验证

```sh
cd rust && cargo test -p lithe-core --lib lsp::
bun test frontend/editor/src/textmate-document.test.ts frontend/editor/src/source-text.test.ts
bun test windows/tauri/src/features/editor/lsp/lsp-client-document-change.test.ts
```

## 适用范围

适用于 `lsp.syncDocument`、Windows 的 LSP 文档同步和共享的 TextMate 分词。性能数字的测量方式见 [Windows 前端交互性能预算](../testing/2026-10-30-windows-frontend-performance-budgets.md)。
