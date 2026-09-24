# Agent 笔记：跨平台文本文件编码切换

状态：已实现

关联需求：[Issue #775](https://github.com/1lck/Lithe-IDEA/issues/775)。

## 先说结论

macOS 和 Windows 编辑器都在状态栏提供编码入口，并支持“以编码重新打开”和“以编码保存”。两端使用相同的编码目录、脏文件确认和外部修改保护语义；具体字节转换留在各自的原生文件适配器。读取编码和保存编码是两个独立状态，分别持久化。当前支持 UTF-8、UTF-8 with BOM、GBK、GB18030、Shift JIS 和 Windows-1252。

## 问题

此前 macOS 和 Windows 本地文件默认按 UTF-8 读取，GBK 文件会出现乱码。仅在界面增加编码名称不能解决问题，因为异步打开、会话恢复、文件监视器和保存都必须使用同一个编码，并且编码转换不能覆盖编辑器在等待期间产生的新修改。

## 决策

- 原生文件适配器读取时先识别 UTF-8 BOM，再验证 UTF-8；无法按 UTF-8 解码时在 GBK 与 GB18030 之间选择无损结果。用户显式选择编码时关闭自动猜测并严格拒绝非法字节。
- 文件读取结果返回编码标签和原始字节的 SHA-256 指纹。保存以指纹做乐观并发校验，同时保留文本比较作为旧调用的兼容路径；成功结果返回新指纹。
- 编辑器把编码和磁盘指纹放入文档状态与工作区会话。文件监视器、磁盘重载和会话恢复沿用当前编码，并在异步结果提交前检查路径、内容修订和编码是否仍匹配。
- Windows 在 `windows/tauri/crates/project` 使用 `encoding_rs`，macOS 在 `macos/Sources/Lithe/Platform/MacOS/FileSystem` 使用 Foundation/CoreFoundation 编码适配；应用层不复制平台转换实现。
- “以编码重新打开”由单独的应用服务执行，脏文件先选择保存、放弃或取消；读取完成后只允许替换捕获的同一个缓冲区。转换保存复用现有保存生命周期，干净文件会临时进入保存状态，写入成功后再恢复干净状态。
- 编码目录由稳定 ID、显示名称、别名、读写能力和 BOM 策略组成；新增编码必须同步更新共享契约、macOS 映射、Windows `encoding_rs` 映射、UI 目录和原始字节 fixture，具体步骤见 `docs/development/document-encoding.md`。

## 考虑过的备选方案

- **所有文件固定按 UTF-8 读取**：不能打开 GBK 文件，也无法满足 Issue #775。
- **在界面层用 `TextDecoder` 猜测和转换**：浏览器编码实现与本地文件安全检查分散，无法复用原子写入和链接拒绝规则，因此保留原生文件适配器作为唯一磁盘编码边界。
- **只比较解码后的字符串**：不同原始字节可能解码成同一文本，且 BOM、非规范编码和外部等长修改会绕过冲突保护，因此改用字节指纹。
- **选择编码后立即修改缓冲区编码**：异步读写失败或期间用户切换标签时会污染新状态，因此将编码提交放在成功读写之后，并对异步结果做快照校验。

## 后果

用户可以在 VS Code 类似的状态栏入口中修复乱码或转换文件编码；GBK/GB18030 的中文文件不会再被静默按 UTF-8 保存。代价是本地文档读写增加一次 SHA-256 计算，并且远程、WSL、虚拟和只读缓冲区不会显示可执行的本地编码转换操作。

## 验证

- `./scripts/test-macos.sh --filter 'DocumentGuardedSaveTests'`
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml -p lithe-project document_file`
- `bunx tsc --noEmit -p windows/tauri/tsconfig.json`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- macOS 和 Windows 实机仍需按矩阵中的验证步骤运行编码读取、转换保存、脏文件选择和外部修改场景。

## 适用范围

- `macos/Sources/LitheCoreContracts/Workspace/WorkspaceFileOperations.swift`
- `macos/Sources/Lithe/Platform/MacOS/FileSystem/MacDocumentEncoding.swift`
- `macos/Sources/Lithe/Platform/MacOS/FileSystem/MacWorkspaceFileOperations.swift`
- `macos/Sources/Lithe/Application/Features/DocumentFeatureModel.swift`
- `macos/Sources/Lithe/Models/Editor/EditorDocument.swift`
- `windows/tauri/crates/project/src/document_file.rs`
- `windows/tauri/src/features/editor/services/document-encoding-workflow.ts`
- `windows/tauri/src/features/command-palette/components/encoding-picker.tsx`
- `windows/tauri/src/features/layout/components/footer/footer-editor-status.tsx`
