# GPUI Monaco 编辑器协议（Phase 1）

本轮把只读 `<pre>` 换成可编辑的 Monaco，并打通保存。核心约束是**不要照搬
原生/WebView 的同步调用方式**：GPUI 的主线程、实体构造和 WebView IPC 回调
都有借用与重入限制。

## 分层

```text
Monaco（WebView）
  │  window.ipc.postMessage(JSON)          JS → Rust
  │  window.lithe.resolve / open / ...     Rust → JS（evaluate_script）
  ▼
lithe-features::EditorSurface
  │  async-channel 接收消息，首帧后启动 pump
  ▼
lithe-workbench（订阅 EditorEvent 更新标签/状态栏）
```

## JS → Rust 消息

统一信封：

```json
{ "requestId": "12", "payload": { "type": "...", ... } }
```

`requestId` 为空字符串表示不需要回复；非空时 Rust 必须调用
`window.lithe.resolve("<requestId>", <json>)`，否则前端会 10 秒超时。

| type | 字段 | 回复 |
| --- | --- | --- |
| `ready` | — | 无 |
| `edit` | `id`, `baseRevision` | `{ "revision": baseRevision + 1 }` |
| `dirty` | `id`, `dirty` | 无 |
| `save` | `id`, `text` | `{ "saved": true }` 或 `{ "saved": false, "error": "..." }` |
| `saveAs` | `id`, `text`, `path` | `{ "saved": true }` 或 `{ "saved": false, "error": "..." }` |
| `focus` | `id`, `line`, `column` | 无 |
| `cursor` | `id`, `line`, `column` | 无 |
| `failure` | `message` | 无 |
| `diagnostics` | `items` | 无 |

### 轻量 LSP 请求

| type | 字段 | 回复 |
| --- | --- | --- |
| `lsp` | `method` (`completion`/`hover`/`definition`/`references`), `id`, `filename`, `text`, `line`, `character` | Core 的 `data`，例如 `{items}` / `{hover}` / `{locations}`；失败回复 `null` |

- `line`/`character` 为 0-based UTF-16；`text` 是当前完整文档内容（请求时随消息发送）。
- Rust 映射到 `lsp.builtinCompletions`（`filePath`, `text`, `position {line, utf16Column}`）、
  `lsp.builtinHover`、`lsp.builtinNavigation`（`method` 为 `textDocument/definition` 或 `textDocument/references`）。
- Rust 在后台执行 Core 命令，完成后回主线程用 `window.lithe.resolve` 回复。
- 前端只在当前文件内导航；跨文件位置本轮忽略（不伪造打开逻辑）。

### 诊断（markers）

前端监听 `monaco.editor.onDidChangeMarkers`，**去抖 250ms** 后把当前所有已打开
模型的 markers 汇总成一份全量快照，通过 `diagnostics` 消息上报：

```json
{
  "type": "diagnostics",
  "items": [
    {
      "path": "/abs/path/Foo.java",
      "severity": 8,
      "message": "cannot find symbol",
      "line": 12,
      "column": 9,
      "source": "java"
    }
  ]
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `path` | string | 绝对路径。模型是 `inmemory://` URI，路径来自 `open` 时的 `filename`；取不到时整条跳过 |
| `severity` | number | Monaco `MarkerSeverity` 原值：1=Hint, 2=Info, 4=Warning, 8=Error |
| `message` | string | marker 文本，空字符串的条目不上报 |
| `line` / `column` | number | 1 起算，取自 `startLineNumber` / `startColumn` |
| `source` | string? | marker 的 owner，例如语言服务名；为空时省略字段 |

- 只上报 `entries` 里的模型（即 `open` 过的文件），外部或语言服务自建的模型一律
  跳过；关闭模型时 Monaco 触发的 markers 变化同样会重新汇总。
- 上报的是**全量**列表且按 `path → line → column → severity → message` 排序：
  Rust 用整份列表做相等比较，没变化就不发事件。列表为空（或 `items` 缺失）表示
  当前没有任何诊断。
- `diagnostics` 不需要回复，`requestId` 为空字符串。


所有消息都必须快速处理；Rust 的 IPC handler 只把消息放进 `async-channel`，
不能在里面调用 GPUI 实体、不能写文件、不能 `evaluate_script`。

## Rust → JS API

通过 `webview.raw().evaluate_script(js)` 调用，只在 GPUI 主线程调用：

```js
window.lithe.open({ id, filename, language?, text, readonly })
window.lithe.close(id)
window.lithe.clear()
window.lithe.configure({ dark, background, foreground, fontFamily, fontSize, wrap, minimap, lineNumbers, scrollBeyondLastLine, renderWhitespace })
window.lithe.save()
window.lithe.saveAll()
window.lithe.saveAs(path)
window.lithe.command(name)
window.lithe.focus()
window.lithe.resolve(requestId, value)
window.lithe.setSaved(id, saved)
window.lithe.setReadonly(readonly)
```

`save` / `saveAll` / `saveAs` / `command` / `focus` 是宿主菜单和命令面板的入口。
其中 `saveAs` 使用新增的 `saveAs` 消息，其余入口不新增 JS → Rust 消息：

- `save()`：保存活动模型，与 Ctrl/Cmd+S 走同一条 `save` 消息。
- `saveAll()`：遍历前端认为脏的模型，逐个走 `save()` 同一条 `save` 消息；
  Rust 的 `dirty` 只跟踪当前文档，不能作为“哪些文档要保存”的依据。
- `saveAs(path)`：把活动模型写进宿主选定的绝对路径（原生保存对话框给出）。
  前端不碰文件系统，只发一条 `saveAs` 消息；成功后 Rust 更新文档路径并发送
  `SavedAs` 事件，标签迁移由工作台完成。没有活动文档时 Rust 不发送该调用。
- `command(name)`：执行一个 Monaco action。Rust 只转发白名单内的 action id
  （撤销/重做、剪贴板、全选、查找替换、注释、格式化、跳转行、定义/引用、悬停），
  菜单文案不会变成任意 JS；没有活动文档时 Rust 不发送该调用。
- `focus()`：把键盘焦点交还编辑器，命令面板或菜单关闭后调用。
- `setReadonly(readonly)`：切换当前 WebView 的只读模式，供 Split Editor 的副窗格
  使用，避免同一文件出现两个可写缓冲。它只改 Monaco 的 `readOnly` 选项，不新增
  JS → Rust 消息，也不改变保存与命令入口；前端会记住该值，后续 `configure`
  重设外观或切换标签时必须保留，不能覆盖回可写。

`configure` 的字段（camelCase，缺省字段保持当前值）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `fontSize` / `wrap` / `minimap` / `lineNumbers` / `scrollBeyondLastLine` | number / boolean / string | 编辑器外观 |
| `renderWhitespace` | boolean | 控制空白字符可见性，前端转成 Monaco 的 `"all"` / `"none"`，默认 `false` |

“重新载入文件”没有新增前端 API：Rust 先 `close(id)` 释放模型，再对同一路径
`open(...)`，前端因此会新建模型而不是复用旧文本。

前端在收到 `ready` 之前也要定义好 `window.lithe`：如果此时收到 `open`，
先把 payload 暂存，编辑器建好后再应用。

## 前端行为

- 同一 `id` 的模型只创建一次。再次 `open` 只激活已有模型并恢复 view state，
  **不要用传入的 text 覆盖**，否则切换标签会丢掉未保存修改。
- `edit`：模型内容变化时发送，标题/保存按钮不需要每次变化都发。
- `dirty`：内容变化后发送 `true`；保存成功后 Rust 会回发 `setSaved(id, true)`，
  前端不需要自己清 Rust 侧的脏标记（前端另存一份本地标记，只用于筛选 Save All
  要提交哪些模型）。
- `save`：Ctrl/Cmd+S 时发送 `{id, text}`，`text` 是 `model.getValue()`。
  不要依赖 Rust 侧应用增量。
- `saveAs`：宿主触发另存为时发送 `{id, text, path}`，字段含义与 `save` 相同，
  `path` 是目标绝对路径。成功后 Rust 会发 `SavedAs { from, to }`，工作台据此
  关闭旧标签并打开新路径；前端只需清本地脏标记。
- `cursor`：光标移动时发送；Rust 更新状态栏。
- 只加载 Monaco 基础语言（至少 Java、Markdown、Plain Text），不要接 LSP。

## Rust 侧要求

- `EditorSurface` 增加 `EditorEvent`：

```rust
#[derive(Clone, Debug)]
pub enum EditorEvent {
    DirtyChanged { path: PathBuf, dirty: bool },
    Saved { path: PathBuf },
    SaveFailed { path: PathBuf, message: String },
    /// 另存为成功。`from` 是写盘前的当前路径，`to` 是新的绝对路径。
    SavedAs { from: PathBuf, to: PathBuf },
    CursorChanged { line: u32, column: u32 },
    /// Monaco 汇总的全部已打开模型的 markers 快照；全量替换语义。
    Diagnostics { items: Vec<DiagnosticItem> },
}
impl gpui::EventEmitter<EditorEvent> for EditorSurface {}
```

- `DiagnosticItem { path, severity, message, line, column, source }`：`severity` 是
  Monaco 的原始位值（`u8`），行列 1 起算，`source` 缺失时为 `None`。
- Rust 解析 `diagnostics` 时丢弃空路径、空消息、缺坐标（或坐标 < 1）的条目；
  只有整份列表与上一次不同才 `cx.emit(EditorEvent::Diagnostics { .. })`。
  诊断不参与编辑区渲染，因此不发 `cx.notify()`。
- `clear()` 会丢弃已缓存的诊断快照，但**不**在这里发事件（该方法由工作台在自身
  更新过程中调用，同步 emit 会重入）；切换项目时清空 Problems 由工作台负责。
- 工作台的 `handle_editor_event` 是穷尽 match，新增 `Diagnostics` 变体后必须补一个
  分支（即使这一轮只是把 `items` 存进状态），否则工作台无法编译。

- 新增 `save_as(target, cx)`：只发 `window.lithe.saveAs(...)`，不读前端内容；
  写盘成功后先更新文档的 `absolute_path` 与脏状态，再发 `SavedAs`。
  事件发出时旧标签仍存在；即使该文档的 `absolute_path` 已换成 `to`，
  按 `from` 调 `close_file` 仍会通过相对 id 回退命中旧文档，随后按 `to`
  调 `open_file` 即可完成标签迁移。

- 新增 `close_file(&mut self, path: PathBuf, window, cx)`，供关闭标签时释放 Monaco 模型。
- 新增 `save_all(cx)`、`reload_current(root, path, text, window, cx)` 与
  `set_render_whitespace(visible, cx)`；重载由先 `close_file` 再 `open_file`
  完成，不新增前端 API。
- 新增 `set_readonly(readonly, cx)`：只发 `window.lithe.setReadonly(...)`，
  没有 WebView 时静默返回；不改保存、命令等其他入口。
- 保持 `new` / `open_file` / `clear` / `current_path` / `mark_dirty` 签名不变。
- 在 `new` 里不能 `cx.spawn`：IPC pump 必须在首帧 `Render` 里用
  `cx.defer_in` 启动（参考 `ProjectTree` 的 `pending_initial_load`）。
- 保存用 `cx.background_spawn` 调 `CoreClient::write_file`，完成后
  `update_in` 回主线程发事件和 `resolve`。`saveAs` 不走 Core，直接用
  `std::fs::write` 写目标绝对路径（父目录不存在时先 `create_dir_all`），
  失败按 `SaveFailed` 语义回复 `{saved:false, error}`。
- 资源目录：`LITHE_GPUI_EDITOR_DIR` 环境变量优先，否则
  `CARGO_MANIFEST_DIR/../editor/dist`；缺少 `index.html` 时显示明确错误，
  不要把失败变成 panic。
- WebView 只创建一次；`load_url` 只在 `new` 里调用一次。
- Windows 上自定义协议 URL 是 `http://lithe-gpui.localhost/index.html`；
  macOS/Linux 是 `lithe-gpui://localhost/index.html`。

## 构建产物

`gpui/editor/build.ts` 复用 `frontend/editor/build.ts`，输出
`gpui/editor/dist`：

```bash
npx -y bun@1.3.12 install
npx -y bun@1.3.12 gpui/editor/build.ts
```

## 本轮文件归属

| 范围 | 负责人 |
| --- | --- |
| `gpui/editor/**` | 前端 agent |
| `gpui/lithe-features/src/editor.rs`、`gpui/lithe-features/Cargo.toml` | Rust 桥 agent |
| `gpui/lithe-workbench/src/workbench.rs`、`top_bar.rs`、`i18n.rs` | 工作台 agent |
