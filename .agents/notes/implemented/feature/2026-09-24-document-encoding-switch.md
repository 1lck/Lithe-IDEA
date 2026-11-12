# Agent 笔记：跨平台文本文件编码切换

状态：已实现

> Viva 迁移状态：下文的编码选择、转换和旧平台验证尚未迁移。当前编辑器把完整文件交给 Core 的借用字节接口判定；遇到不合法的 UTF-8 或二进制控制字符时拒绝打开并保留原始文件，外部变更无法解码时保留已打开的缓冲区。不同编码的字节可能恰好也是合法 UTF-8，单靠这项校验无法识别其真实编码，因此不能把它当作完整的编码检测。历史实现与验证入口见[迁移前笔记](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/feature/2026-09-24-document-encoding-switch.md)。

关联需求：[Issue #775](https://github.com/1lck/Lithe-IDEA/issues/775)。

## 先说结论

macOS 和 Windows 编辑器都在状态栏提供编码入口，并支持“以编码重新打开”和“以编码保存”。两端使用相同的编码目录、脏文件确认和外部修改保护语义；具体字节转换留在各自的原生文件适配器。读取编码和保存编码是两个独立状态，分别持久化。当前支持 UTF-8、UTF-8 with BOM、UTF-16 LE/BE（带或不带 BOM）、GBK、GB18030、Big5、Shift JIS、EUC-JP、EUC-KR、Windows-1250、Windows-1251、Windows-1252 和 KOI8-R。自动识别只覆盖 UTF-8、带 BOM 的编码和 GBK 系；其余编码的字节无法可靠区分，只能由用户显式选择。

## 问题

此前 macOS 和 Windows 本地文件默认按 UTF-8 读取，GBK 文件会出现乱码。仅在界面增加编码名称不能解决问题，因为异步打开、会话恢复、文件监视器和保存都必须使用同一个编码，并且编码转换不能覆盖编辑器在等待期间产生的新修改。

## 决策

- 原生文件适配器读取时先识别 UTF-8 BOM 与 UTF-16 LE/BE BOM（UTF-16 文本不会通过 UTF-8 校验，只有 BOM 能无猜测地识别它），再验证 UTF-8；无法按 UTF-8 解码时在 GBK 与 GB18030 之间选择无损结果。用户显式选择编码时关闭自动猜测，并用替换字符呈现不符合所选编码的字节，避免解码失败后继续显示旧缓冲区。
- 文件读取结果返回编码标签和原始字节的 SHA-256 指纹。保存以指纹做乐观并发校验，同时保留文本比较作为旧调用的兼容路径；成功结果返回新指纹。
- 文件监听先比较原始字节指纹，再按当前读取编码解码；这样保存编码改变后，延迟的自身写入通知不会被误判为外部修改。用户主动重新打开时仍然执行显式解码。
- 编辑器把编码和磁盘指纹放入文档状态与工作区会话。文件监视器、磁盘重载和会话恢复沿用当前编码，并在异步结果提交前检查路径、内容修订和编码是否仍匹配。
- Windows 在 `windows/tauri/crates/project` 使用 `encoding_rs`，macOS 在 `macos/Sources/Lithe/Platform/MacOS/FileSystem` 使用 Foundation/CoreFoundation 编码适配；应用层不复制平台转换实现。
- “以编码重新打开”由单独的应用服务执行，脏文件先选择保存、放弃或取消；读取完成后只允许替换捕获的同一个缓冲区。转换保存复用现有保存生命周期，干净文件会临时进入保存状态，写入成功后再恢复干净状态。
- 编码目录由稳定 ID、显示名称、别名、读写能力和 BOM 策略组成；新增编码必须同步更新共享契约、macOS 映射、Windows `encoding_rs` 映射、UI 目录和原始字节 fixture，具体步骤见 `docs/development/document-encoding.md`。

### 文本判定与编码转换的边界（#963）

编码转换完成后，macOS 和 Windows 都使用 Rust Core 原有的 Unicode 控制字符规则判定正文；中文和 emoji 的 UTF-8 续字节不再被计作二进制证据。macOS 通过借用 UTF-8 字节的 C 接口调用，避免大文档再复制成 JSON；Windows 通过 `document.classifyText` 调用同一函数。原生编码库仍是字节转换的唯一实现，Core 不重新猜编码。

正确流程是“原生读取和解码 → Core 判定正文 → 选择编辑器 → Monaco 高亮”。不要根据语言 ID 是否存在决定文件能否编辑，也不要因为 `.java` 已知而跳过正文检查。权限、文件大小和解码错误仍按原错误显示，不能伪装成二进制判定。

用户明确选择外部编辑器时，解码和大小限制由该编辑器处理，不先要求 Lithe 原生读取成功。Windows 内置编辑器首次打开与会话恢复复用 `loadFileContent`；点击已经在后台加载的标签必须等待该次读取和判定结束。共享 Monaco 层直接注册随 0.55.1 分发的 INI tokenizer，其上游扩展名包含 `.properties`，无需为这个问题新增 tree-sitter 语法或自写高亮器。原有原生编辑器高亮实现不参与 Monaco 路径。

`WorkspaceTextFilePolicy` 的 Swift 入口转发到 Core，不再维护第二份控制字符算法。因此 macOS 测试也必须链接真实 Core；~~scripts/macos/test/test-macos.sh~~（随旧客户端移除） 使用现有构建路径完成链接，不能用弱符号的不可用结果来验证正常文本。

## 考虑过的备选方案

- **所有文件固定按 UTF-8 读取**：不能打开 GBK 文件，也无法满足 Issue #775。
- **在界面层用 `TextDecoder` 猜测和转换**：浏览器编码实现与本地文件安全检查分散，无法复用原子写入和链接拒绝规则，因此保留原生文件适配器作为唯一磁盘编码边界。
- **只比较解码后的字符串**：不同原始字节可能解码成同一文本，且 BOM、非规范编码和外部等长修改会绕过冲突保护，因此改用字节指纹。
- **选择编码后立即修改缓冲区编码**：异步读写失败或期间用户切换标签时会污染新状态，因此将编码提交放在成功读写之后，并对异步结果做快照校验。

- **只把 properties 加入文本白名单**：会掩盖当前示例，未知扩展名的中文和已知扩展名下的控制字符仍会走不同规则，因此删除字节比例嗅探，并共享正文判定。
- **完整照搬 VS Code 文件服务**：其工作台、Node.js 编码服务与本项目原生存储边界不同；复用其职责分离思路与已经分发的 Monaco tokenizer，保留现有原生编解码器。

## 后果

用户可以在 VS Code 类似的状态栏入口中修复乱码或转换文件编码；GBK/GB18030 的中文文件不会再被静默按 UTF-8 保存。代价是本地文档读写增加一次 SHA-256 计算，并且远程、WSL、虚拟和只读缓冲区不会显示可执行的本地编码转换操作。

统一正文判定增加一次 Windows Core 调用；macOS 单元测试开始依赖 Rust 构建。PR #981 的 CI 冷构建中，Core 分别耗时 111 秒和 227 秒，Swift 主通道编译另耗时约 486 秒，原 660 秒总预算导致主通道测试中途和插件通道编译期间超时。因此三个 Swift 测试通道使用已有 Cargo 下载缓存，并把包含编译的总预算设为 960 秒、外层步骤设为 17 分钟；保留单测试预算与无输出看门狗，缓存未命中时也必须能完成冷构建。不会新增下载入口、缓存目录或安装包运行时写入；Monaco 产物仍走现有 editor 构建与完整性验证路径。

## 验证

旧客户端的编码转换与平台验证命令保留在上方迁移前笔记；Viva 需要在完整迁移后重新验证各编码、脏缓冲和外部修改。

- `scripts/desktop/desktop-go.sh test -race ./internal/core ./internal/workbench -run 'Test(DocumentTextClassificationUsesSharedFixtures|OpenRejectsUnsupportedEncodingWithoutChangingTheFile|ReadDocumentUsesWholeFileClassification|UnsupportedEncodingReasonFollowsLanguage|ExternalUnsupportedEncodingKeepsOpenBufferAndDiskBytes)' -count=3`：覆盖共享 Core fixture、非法字节、正常 UTF-8、提示语言与外部变化，不代表编码转换已实现。
- 本地热缓存的 16 MiB 中英文混合文件读取微基准：原来只检查前 8 KiB 时约 1.07 ms，接入 Core 完整判定后约 122.43 ms；两者均为 5 次分配、约 16 MiB。测量使用未优化的 Core debug 构建，校验在后台读取线程执行；这不是生产构建、冷磁盘、完整应用启动或 Windows 性能验收。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `shared/fixtures/editor/text-content-v1.json` 是 Core 正文判定夹具；当前判定不包含多编码识别与转换。

## 适用范围

- `desktop/internal/workbench/documents.go`
- `desktop/internal/workbench/documents_test.go`
- `desktop/internal/workbench/document_observation_test.go`
- `desktop/internal/core/document_text_test.go`
- `shared/platform-feature-matrix/features/editor-file-encoding-reopen.json`
- `shared/platform-feature-matrix/features/editor-file-encoding-save.json`
