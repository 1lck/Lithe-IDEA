# 文本文件编码接入方案

Lithe 把“如何解码当前编辑器文本”和“下一次写入磁盘使用什么编码”视为两个独立选择：

- `readEncoding` 只影响读取、重新打开和外部文件重载；
- `saveEncoding` 只影响保存产生的字节；
- 原生文档模型还记录最近一次确认的磁盘编码，用于保存后的状态和并发保护。

因此，用户可以用 GBK 重新打开一个 UTF-8 文件来查看实际解码结果，而不因此改变下一次保存编码；如果所选编码不匹配，编辑器会显示替换字符而不是保留旧文本。也可以只把保存编码切换为 GB18030，而不改变当前文本的解码方式。成功保存后，保存编码和磁盘快照编码才会更新。旧版会话只有一个 `encoding` 字段时，会同时作为两种角色的初始值读取。

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
| `bom` | BOM 策略；当前支持 `none`、`utf8`、`utf16le` 和 `utf16be` |

前端目录位于 `windows/tauri/src/platform/document-files.ts` 的 `DOCUMENT_ENCODING_CATALOG`，macOS 契约目录位于 `macos/Sources/LitheCoreContracts/Workspace/WorkspaceFileOperations.swift` 的 `DocumentEncoding.catalog`，Windows 原生目录位于 `windows/tauri/crates/project/src/document_file.rs` 的 `DocumentEncoding::CATALOG`。三个目录的 `stableId`、能力和 BOM 策略必须保持一致；真正的字节转换仍由平台适配器负责。

当前目录共 16 种编码：UTF-8、UTF-8 with BOM、UTF-16 LE/BE with BOM、UTF-16 LE/BE（无 BOM）、GBK、GB18030、Big5、Shift JIS、EUC-JP、EUC-KR、Windows-1250、Windows-1251、Windows-1252 和 KOI8-R。`Windows-1252` 同时接受 `ISO-8859-1`/`latin1` 别名（与 WHATWG 一致）；`EUC-KR` 实际是 CP949 超集，macOS 对应 `dosKorean`，`Big5` 在两端都含 HKSCS 扩展。

自动识别只覆盖 UTF-8、带 BOM 的编码和 GBK 系：其余单字节和多字节编码的字节互相重叠，无法可靠猜测，因此只能由用户显式选择编码重新打开，不会因为“看起来像”而被自动选中。无 BOM 的 UTF-16 同理；UTF-32 LE 的 BOM（`FF FE 00 00`）以 `FF FE` 开头，自动识别会明确排除它，避免被当成 UTF-16 LE 打开并改写。UTF-32 目前不在目录内。

## 新增一种编码

1. 在三个目录中添加同一个 `stableId`、显示名、协议标签、别名、读写能力和 BOM 策略。
2. 在 macOS `MacDocumentEncoding.codec(_:)` 中添加 Foundation/CoreFoundation 映射。
3. 在 Windows `DocumentEncoding::codec` 和 `parse` 中添加 `encoding_rs` 映射及别名。
4. 按能力过滤读取和保存菜单；只读或只写编码不能出现在不支持的操作中。
5. 增加原始字节 fixture（见 `shared/fixtures/documents/encoding-explicit-reopen-v1.json`），覆盖显式错码读取、保存后字节、BOM 和不可表示字符错误。
6. 增加 macOS、Windows 的目录一致性测试，并更新 `shared/platform-feature-matrix/features/` 中对应能力的验证场景。
7. 如果编码会进入工作区会话，保持新旧字段的解码兼容；不要把读写状态重新合并成一个字段。

平台适配器不得把编码转换复制到 SwiftUI、React 或 Monaco 层。编辑器只处理 Unicode 文本和编码目录描述，原生适配器负责字节边界、大小限制、身份指纹和原子写入。自动识别仍然严格拒绝无法验证的字节，避免把 GBK 误判成 UTF-8；文件监听先比较原始字节指纹，再使用当前读取编码解码；用户主动重新打开必须执行显式解码，并允许替换字符表达选错编码的结果。
