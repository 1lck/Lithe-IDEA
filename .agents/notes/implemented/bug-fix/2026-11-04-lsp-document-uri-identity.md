# Agent 笔记：语言服务器文件 URI 与文档身份

状态：已实现

## 先说结论

文件名里的 `#`、`?` 和百分号是路径字符，不能被误当作 URI（统一资源标识）的片段或查询分隔符。
两端把路径放进已有语言服务器请求，由 Core 生成文件 URI；语言服务器提供的虚拟 URI 则原样保留。
诊断匹配也要保留编码字符和分隔符的区别，否则诊断可能显示在错误的文件上。

## 问题

Windows 原来使用 `encodeURI` 拼接路径，不能转义 `#` 和 `?`，也不能正确表达 UNC 网络共享。
Core 原来的诊断匹配先解码整个 URI，因此 `A%23B` 和带片段的 `A#B` 会被误认成同一个文档。

## 决策

Core 按显式路径类型处理 POSIX、Windows 盘符和 UNC 路径，处理扩展长度前缀、点段和目录末尾斜杠，再对路径编码。
平台继续负责原生路径和工作区身份；它们在现有的启动、文档同步、语义请求和文件变化消息内传递路径，
不要为每次输入增加一次独立的跨进程调用。上游返回的虚拟 URI 和不透明请求数据不改写。

Core 比较文档身份时规范化百分号转义的写法与 Windows 盘符，同时保留编码后的保留字符，
避免把文件名中的字符与 URI 结构混在一起。Windows 根据 Core 同步结果保存文档 URI 和版本，
该映射随文件附着关系销毁；重新附着后旧同步结果不能覆盖新文档。

## 考虑过的备选方案

- 在 Windows 修补 `encodeURI`：仍要维护两套路径和 URI 规则，UNC 与诊断匹配仍可能出错。
- 每次按键另发 URI 转换请求：会在高频编辑路径增加 IPC 与等待，故将转换合并进已有请求。
- 解码完整 URI 再比较：会把编码的 `#`、`?` 和 `/` 与结构分隔符混淆。

## 后果

路径转换不访问磁盘，合法长路径有明确上限。原有语言服务器文档请求兼容 URI 字符串，
原生路径使用新的类型化输入；同步响应增加实际使用的 URI。Windows 的附着关系保存少量版本映射，
关闭和替换文档时释放，不缓存文档内容。

## 验证

- `shared/fixtures/lsp/document-uri-v1.json` 覆盖保留字符、Unicode、盘符、UNC 和诊断身份。
- Core 模拟服务器检查真正发送的 `didOpen` URI；macOS 真实桥接与启动测试覆盖目录斜杠和 `#`。
- Windows 适配器测试覆盖现有请求内传路径、虚拟 URI 与旧附着结果；云服务器运行对应前端与 Core 测试。
- 两端真实产品中的语言服务器、远程工作区及 UNC 路径人工验收仍待完成。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/document_uri.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/document_uri.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/client.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/client.rs)
- ~~`macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift`~~（已随 #1794 移除）
- ~~`windows/tauri/src/platform/lsp-core-adapter.ts`~~（已随 #1794 移除）
