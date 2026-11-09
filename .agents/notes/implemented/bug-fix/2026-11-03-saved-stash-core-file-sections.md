# Agent 笔记：Stash 查看使用 Core 的逐文件差异

状态：已实现

## 先说结论

macOS 和 Windows 的 Stash、Shelf 及 Windows 普通 Git 差异使用 Rust Core 的逐文件身份和展示行。每个文件保留原始补丁和 hunk；暂存层与工作区层独立读取。宿主不再解析补丁。

## 问题

旧实现手工执行 `stash show`，在 Swift 里拆分文件，再逐文件启动 Git 识别路径并再次解析差异。文件多时 Git 进程数量随文件增长；文件名转义、前缀设置和平台解析器还可能造成不同结果。旧差异解析器对每一行重复统计整份补丁的行数，大补丁的扫描成本呈平方增长。

## 决策

- `git.diff` 接受已有的不可变 stash 提交身份，按需返回逐文件结构；此模式目前只支持整个仓库，拒绝局部路径参数，避免误返回未选文件。路径与重命名前路径交给 Git 的 NUL 分隔统计解析，Core 校验数量与补丁边界一致；每段原始 UTF-8 补丁和 Core 行结果一起返回，避免再传一份完整补丁。
- 强制 Git 使用标准前缀、关闭颜色和文本转换。不能依赖用户的 `diff.noprefix` 设置，也不要给 `stash show` 组合手写前缀参数：某些 Git 版本会因此输出不能由 `git apply` 识别的无前缀补丁。
- 补丁超过共享 32 MiB 上限或无法一致配对时拒绝返回；保存记录拒绝无效 UTF-8，普通 Diff 可以显示替换字符但必须标记解码损失并禁止块写入。解析逐行线性扫描，普通平铺 `git.diff` 响应保持兼容。
- 正确做法是先固定选中 stash 的提交，再请求逐文件数据并直接使用返回的渲染行；不要在宿主按文件名切补丁、重新解释 Git 路径或把一份补丁按文件重复发送给 Git。

## 考虑过的备选方案

- 只把 `stash show` 换成 Core、保留 Swift 分段和逐文件检查：仍重复解析和启动 Git，没有解决跨平台规则分散。
- 手工解析 `diff --git` 里的转义文件名：Git 原生 NUL 分隔统计已经提供更可靠的路径语义，不再维护另一套转义规则。
- 把原始补丁和全部逐文件内容一起返回：大补丁需要重复跨语言传输；逐文件模式将平铺结果留空。

## 后果

一份 Git Diff 使用同一次 Git 进程取得 NUL 分隔统计与补丁；Shelf 整层补丁以一次批量检查识别文件，重命名时补充反向检查。每个文件保留展示行和原始 hunk，Windows 检测解码损失后不允许将替换字符用于块写入；CRLF 和缺少末尾换行时仍保留原始 hunk。重命名块另提供只修改目标文件内容的补丁，避免取消暂存单块时反转整个重命名。返回数据不是跨外部 Git 操作的事务，但固定提交身份避免列表位置变化后查看到其他 Stash。

## 验证

- `rust/lithe-core/src/tests/git_patch_exchange.rs`：真实临时仓库覆盖重命名、中文名称、未跟踪文件、二进制、Git 前缀配置以及错误的请求模式。
- ~~`macos/Tests/LitheTests/GitStatusObservationTests.swift`~~（已随 #1794 移除）：真实 Swift 桥接、Core 和 Git 验证已跟踪、未跟踪与二进制 Stash 文件及展示行。
- ~~./scripts/rust-core/verify-rust-core.sh~~（随旧客户端移除）、~~./scripts/architecture/verify-shared-contracts.sh~~（随旧客户端移除）、`./scripts/agent-notes/verify-agent-notes.sh` 和 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。
- 大补丁解析与 UI 跨进程加载需分别测量；真实 Windows 原生界面和平台矩阵验收保持待验证。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/mod.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/mod.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/patch_exchange.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/patch_exchange.rs)
- ~~`macos/Sources/LitheGitModule/Services/GitService.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Core/Rust/RustGitOperations.swift`~~（已随 #1794 移除）
- ~~`windows/tauri/src/platform/core-result-adapter.ts`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/git/api/git-shelf-api.ts`~~（已随 #1794 移除）
- `shared/contracts/rust-core-api.md`
