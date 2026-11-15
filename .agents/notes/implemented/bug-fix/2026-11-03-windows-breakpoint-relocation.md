# Agent 笔记：编辑后把断点位置写回唯一存储

状态：已实现

## 先说结论

编辑器中的断点位置必须通过 Core 的 `debug.relocateBreakpoints` 移动，并写回断点存储（界面和调试请求共用的状态来源）。界面不能把编辑器里临时移动的图标位置当作真源，启动调试时也不能使用点击按钮时捕获的旧列表。

## 问题

编辑器会临时移动行边的断点图标，但重新绘制或启动调试仍从旧存储读取行号。此外，编辑器同步原始换行时携带的替换范围会包含未变化的相邻字符；把这种范围直接交给断点定位，会把仍然存在的代码当成已删除，丢失断点的启用状态。

## 决策

- **精确编辑范围。** 宿主把编辑转换为 Core 能理解的编辑范围：位置单位是 UTF-16（编辑器的位置单位，emoji 通常占两个单位），不能直接使用编辑器已统一换行后的偏移。桌面端在 `desktop/internal/workbench/debug_relocate.go` 的 `relocateDocumentBreakpoints` 中完成这一转换。
- **位置和冲突合并交给 Core。** 位置投影、重复合并和删除规则全部由 Core 完成（`desktop/internal/core/debug.go` 的 `RelocateDebugBreakpoints`），支持 LF、CRLF、CR。宿主不自行按插入和删除的行数移动断点。
- **只在有断点时发送请求。** 没有断点的文件不发送请求；位置没有变化时不发布新的存储，避免每次输入都向调试器重新同步。
- **编辑前文本只保存一份。** 每次编辑都更新断点定位使用的文本快照；只迁移发生该编辑时已经存在的断点，之后新建的断点已经使用新的文档行号。
- **无法定位时不猜测。** 编辑范围与编辑前文本对不上时，断点保持原位，不移动到猜测的行。

正确做法：断点位置以存储为准，发送调试请求时从存储读取当前断点，并使用一基的 DAP（调试适配器协议）行号。
不要这样做：保存启动按钮闭包里的旧列表，或只读取界面图标移动后的位置作为真源。

## 考虑过的备选方案

- **让界面图标位置成为断点真源**：依赖视图是否存在，未打开的文件和重新启动无法保持一致。
- **宿主自行按插入和删除行数移动**：无法完整复用 Core 的字符锚点和碰撞处理，形成两套算法。
- **并行发送每次编辑并只取最后结果**：后一次请求可能从尚未更新的旧断点计算，丢掉连续编辑。

## 后果

编辑、持久化、重绘和发送调试请求使用一致的位置。Core 返回碰撞后保留下来的输入序号，桌面端据此保留断点身份。真正的调试适配器停住位置和完整界面验收仍需在各平台上确认。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench/... ./internal/core/...`：断点定位与调试请求的测试。
- Core 仓库的断点定位共享样例覆盖插入、删除、中文、emoji、CRLF、禁用断点和位置合并。
- `scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/workbench/debug_relocate.go`
- `desktop/internal/workbench/debug_breakpoints.go`
- `desktop/internal/workbench/documents.go`
- `desktop/internal/workbench/pluginsync.go`
- `desktop/internal/core/debug.go`
