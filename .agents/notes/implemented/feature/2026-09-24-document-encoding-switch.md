# Agent 笔记：跨平台文本文件编码切换

状态：已实现

> Viva 迁移状态：下文的编码选择、转换和平台验证尚未在 Viva 中完成迁移。当前编辑器把完整文件交给 Core 的借用字节接口判定；遇到不合法的 UTF-8 或二进制控制字符时拒绝打开并保留原始文件，外部变更无法解码时保留已打开的缓冲区。不同编码的字节可能恰好也是合法 UTF-8，单靠这项校验无法识别其真实编码，因此不能把它当作完整的编码检测。

关联需求：[Issue #775](https://github.com/1lck/Lithe-IDEA/issues/775)。

## 先说结论

编辑器状态栏提供编码入口，支持“以编码重新打开”和“以编码保存”。编码目录、脏文件确认和外部修改保护由共享规则决定；具体字节转换留在原生文件适配器。读取编码和保存编码是两个独立状态，分别持久化。当前目标支持 UTF-8、UTF-8 with BOM、UTF-16 LE/BE（带或不带 BOM）、GBK、GB18030、Big5、Shift JIS、EUC-JP、EUC-KR、Windows-1250、Windows-1251、Windows-1252 和 KOI8-R。自动识别只覆盖 UTF-8、带 BOM 的编码和 GBK 系；其余编码的字节无法可靠区分，只能由用户显式选择。

## 问题

本地文件如果一律按 UTF-8 读取，GBK 文件会出现乱码。仅在界面增加编码名称不能解决问题，因为异步打开、会话恢复、文件监视器和保存都必须使用同一个编码，并且编码转换不能覆盖编辑器在等待期间产生的新修改。

## 决策

- 原生文件适配器读取时先识别 UTF-8 BOM 与 UTF-16 LE/BE BOM（UTF-16 文本不会通过 UTF-8 校验，只有 BOM 能无猜测地识别它），再验证 UTF-8；无法按 UTF-8 解码时在 GBK 与 GB18030 之间选择无损结果。用户显式选择编码时关闭自动猜测，并用替换字符呈现不符合所选编码的字节。
- 文件读取结果返回编码标签和原始字节的 SHA-256 指纹。保存以指纹做乐观并发校验，成功结果返回新指纹。
- 文件监听先比较原始字节指纹，再按当前读取编码解码；这样保存编码改变后，延迟的自身写入通知不会被误判为外部修改。用户主动重新打开时仍然执行显式解码。
- 编辑器把编码和磁盘指纹放入文档状态与工作区会话。文件监视器、磁盘重载和会话恢复沿用当前编码，并在异步结果提交前检查路径、内容修订和编码是否仍匹配。
- 字节转换由原生文件适配器（`desktop/internal/documentio`）完成，应用层不复制平台转换实现。
- “以编码重新打开”由单独的应用服务执行：脏文件先选择保存、放弃或取消；读取完成后只允许替换捕获的同一个缓冲区。转换保存复用现有保存生命周期，写入成功后才恢复干净状态。
- 编码目录由稳定 ID、显示名称、别名、读写能力和 BOM 策略组成。新增编码必须同步更新共享契约、原生映射、界面目录和原始字节夹具。

### 文本判定与编码转换的边界

编码转换完成后，正文判定使用 Rust Core 原有的 Unicode 控制字符规则；中文和 emoji 的 UTF-8 续字节不再被计作二进制证据。原生编码库仍是字节转换的唯一实现，Core 不重新猜编码。

正确流程是“原生读取和解码 → Core 判定正文 → 选择编辑器”。不要根据语言 ID 是否存在决定文件能否编辑，也不要因为扩展名已知而跳过正文检查。权限、文件大小和解码错误仍按原错误显示，不能伪装成二进制判定。

用户明确选择外部编辑器时，解码和大小限制由该编辑器处理，不先要求 Lithe 原生读取成功。

## 考虑过的备选方案

- **所有文件固定按 UTF-8 读取**：不能打开 GBK 文件，也无法满足 Issue #775。
- **在界面层用浏览器的解码能力猜测和转换**：本地文件安全检查分散，无法复用原子写入和链接拒绝规则，因此保留原生文件适配器作为唯一磁盘编码边界。
- **只比较解码后的字符串**：不同原始字节可能解码成同一文本，且 BOM、非规范编码和外部等长修改会绕过冲突保护，因此改用字节指纹。
- **选择编码后立即修改缓冲区编码**：异步读写失败或期间用户切换标签时会污染新状态，因此将编码提交放在成功读写之后，并对异步结果做快照校验。
- **只把 properties 等扩展名加入文本白名单**：会掩盖当前示例，并让未知扩展名与已知扩展名走不同规则；因此删除字节比例嗅探，统一由正文判定完成。

## 后果

用户可以在状态栏修复乱码或转换文件编码；GBK/GB18030 的中文文件不会再被静默按 UTF-8 保存。代价是本地文档读写增加一次 SHA-256 计算，并且远程、WSL、虚拟和只读缓冲区不会显示可执行的本地编码转换操作。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core ./internal/workbench -run 'Test(DocumentTextClassificationUsesSharedFixtures|OpenRejectsUnsupportedEncodingWithoutChangingTheFile|ReadDocumentUsesWholeFileClassification|UnsupportedEncodingReasonFollowsLanguage|ExternalUnsupportedEncodingKeepsOpenBufferAndDiskBytes)' -count=3`：共享 Core 夹具、非法字节、正常 UTF-8、外部变化与提示语言。
- Core 仓库的 [`text-content-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/editor/text-content-v1.json) 是正文判定夹具；当前判定不包含多编码识别与转换。
- `node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs --check`

## 适用范围

- `desktop/internal/workbench/documents.go`
- `desktop/internal/workbench/documents_test.go`
- `desktop/internal/workbench/document_observation_test.go`
- `desktop/internal/core/document_text_test.go`
- `desktop/internal/documentio`
- `shared/platform-feature-matrix/features/editor-file-encoding-reopen.json`
- `shared/platform-feature-matrix/features/editor-file-encoding-save.json`
