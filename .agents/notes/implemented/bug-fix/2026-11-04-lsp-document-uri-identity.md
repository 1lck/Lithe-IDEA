# Agent 笔记：语言服务器文件 URI 与文档身份

状态：已实现

## 先说结论

文件名里的 `#`、`?` 和百分号是路径字符，不能被误当作 URI（统一资源标识）的片段或查询分隔符。宿主把路径交给 Core，由 Core 生成文件 URI；语言服务器提供的虚拟 URI 则原样保留。诊断匹配也要保留编码字符和分隔符的区别，否则诊断可能显示在错误的文件上。

## 问题

宿主如果用简单的编码函数拼接路径，不能转义 `#` 和 `?`，也不能正确表达 UNC 网络共享。Core 的诊断匹配如果先解码整个 URI，`A%23B` 和带片段的 `A#B` 会被误认成同一个文档。

## 决策

- **路径类型由 Core 判断。** Core 按显式路径类型处理 POSIX、Windows 盘符和 UNC 路径，处理扩展长度前缀、点段和目录末尾斜杠，再对路径编码（`desktop/internal/core/plugin_documents.go` 的 `PluginDocumentURI` 调用 `lsp.documentUri`）。
- **不增加跨进程调用。** 路径在现有的启动、文档同步、语义请求和文件变化消息中传递，不为每次输入增加一次独立的转换请求。
- **上游数据不改写。** 语言服务器返回的虚拟 URI 和不透明请求数据原样保留。
- **身份比较保留编码。** Core 比较文档身份时规范化百分号转义的写法与 Windows 盘符，同时保留编码后的保留字符，避免把文件名中的字符与 URI 结构混在一起。
- **同步结果的版本随文档生命周期。** 宿主根据 Core 的同步结果保存文档 URI 和版本，该映射随文档关闭或替换而销毁；重新打开后旧同步结果不能覆盖新文档。

## 考虑过的备选方案

- **在宿主修补编码函数**：仍要维护两套路径和 URI 规则，UNC 与诊断匹配仍可能出错。
- **解码完整 URI 再比较**：会把编码的 `#`、`?` 和 `/` 与结构分隔符混淆。

## 后果

路径转换不访问磁盘，合法长路径有明确上限。原有语言服务器文档请求兼容 URI 字符串；同步响应增加实际使用的 URI。宿主保存的文档 URI 和版本映射很少，在关闭和替换文档时释放，不缓存文档内容。

## 验证

- Core 仓库的 [`document-uri-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/lsp/document-uri-v1.json) 夹具覆盖保留字符、Unicode、盘符、UNC 和诊断身份。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/pluginlsp/...`：宿主侧的文档同步与版本映射。
- 真实产品中的语言服务器、远程工作区及 UNC 路径仍需人工验收。

## 适用范围

- `desktop/internal/core/plugin_documents.go`
- `desktop/internal/pluginlsp/pluginlsp.go`
- Core 仓库的 LSP 文档 URI 实现，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
