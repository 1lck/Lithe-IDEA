# 文本文件编码接入方案

Lithe 把“如何解码当前编辑器文本”和“下一次写入磁盘使用什么编码”视为两个独立选择：

- `readEncoding` 只影响读取、重新打开和外部文件重载；
- `saveEncoding` 只影响保存产生的字节；
- 原生文档模型还记录最近一次确认的磁盘编码，用于保存后的状态和并发保护。

因此，用户可以用 GBK 重新打开一个 UTF-8 文件来查看内容，而不因此改变下一次保存编码；也可以只把保存编码切换为 GB18030，而不改变当前文本的解码方式。成功保存后，保存编码和磁盘快照编码才会更新。旧版会话只有一个 `encoding` 字段时，会同时作为两种角色的初始值读取。

## 统一目录接口

两端都实现同一组目录字段：

| 字段 | 作用 |
| --- | --- |
| `stableId` | 跨平台稳定持久化 ID，不能使用本地化显示文本替代 |
| `id` | 兼容当前文件操作协议的编码标签 |
| `displayName` | 菜单和状态栏显示名称 |
| `aliases` | 兼容命令行、旧会话或文件关联中的名称 |
| `supportsRead` | 是否允许以该编码读取 |
| `supportsWrite` | 是否允许以该编码写入 |
| `bom` | BOM 策略；当前支持 `none` 和 `utf8` |

前端目录位于 `windows/tauri/src/platform/document-files.ts` 的 `DOCUMENT_ENCODING_CATALOG`，macOS 契约目录位于 `macos/Sources/LitheCoreContracts/Workspace/WorkspaceFileOperations.swift` 的 `DocumentEncoding.catalog`，Windows 原生目录位于 `windows/tauri/crates/project/src/document_file.rs` 的 `DocumentEncoding::CATALOG`。三个目录的 `stableId`、能力和 BOM 策略必须保持一致；真正的字节转换仍由平台适配器负责。

## 新增一种编码

1. 在三个目录中添加同一个 `stableId`、显示名、协议标签、别名、读写能力和 BOM 策略。
2. 在 macOS `MacDocumentEncoding.codec(_:)` 中添加 Foundation/CoreFoundation 映射。
3. 在 Windows `DocumentEncoding::codec` 和 `parse` 中添加 `encoding_rs` 映射及别名。
4. 按能力过滤读取和保存菜单；只读或只写编码不能出现在不支持的操作中。
5. 增加原始字节 fixture，覆盖严格读取、保存后字节、BOM 和不可表示字符错误。
6. 增加 macOS、Windows 的目录一致性测试，并更新 `docs/development/platform-parity-matrix.md` 的验证场景。
7. 如果编码会进入工作区会话，保持新旧字段的解码兼容；不要把读写状态重新合并成一个字段。

平台适配器不得把编码转换复制到 SwiftUI、React 或 Monaco 层。编辑器只处理 Unicode 文本和编码目录描述，原生适配器负责字节边界、大小限制、身份指纹和原子写入。文件监听先比较原始字节指纹，再使用当前读取编码解码；用户主动重新打开仍然必须执行显式解码。
