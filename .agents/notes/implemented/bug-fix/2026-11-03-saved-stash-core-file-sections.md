# Agent 笔记：Stash 查看使用 Core 的逐文件差异

状态：已实现

## 先说结论

Stash、Shelf 和普通 Git 差异使用 Rust Core 的逐文件身份和展示行。每个文件保留原始补丁和 hunk；暂存层与工作区层独立读取。宿主不再解析补丁，也不再按文件名切分补丁。

## 问题

旧实现手工执行 `stash show`，在宿主里拆分文件，再逐文件启动 Git 识别路径并再次解析差异。文件多时 Git 进程数量随文件增长；文件名转义、前缀设置和各平台解析器还可能造成不同结果。旧差异解析器对每一行重复统计整份补丁的行数，大补丁的扫描成本呈平方增长。

## 决策

- **按不可变的提交身份读取。** `git.diff` 接受已有的 stash 提交身份，按需返回逐文件结构。桌面端的 `GitStashDiff`（`desktop/internal/core/git_review.go`）按这个身份读取。此模式只支持整个仓库，拒绝局部路径参数，避免误返回未选文件。
- **路径和统计由 Git 的 NUL 分隔输出解析。** Core 校验统计数量与补丁边界一致；每段原始 UTF-8 补丁和 Core 的行结果一起返回，不再传一份完整补丁。
- **强制标准前缀。** Core 固定 Git 使用标准前缀、关闭颜色和文本转换，不依赖用户的 `diff.noprefix` 设置，也不给 `stash show` 组合手写前缀参数：某些 Git 版本会因此输出不能由 `git apply` 识别的无前缀补丁。
- **大小和编码有界。** 补丁超过共享的 32 MiB 上限或无法一致配对时拒绝返回；保存记录拒绝无效 UTF-8。普通 Diff 可以显示替换字符，但必须标记解码损失并禁止块写入。解析逐行线性扫描。

正确做法：先固定选中 stash 的提交，再请求逐文件数据并直接使用返回的渲染行；不要在宿主按文件名切补丁、重新解释 Git 路径，或把同一份补丁按文件重复发送给 Git。

## 考虑过的备选方案

- **只把 `stash show` 换成 Core、保留宿主侧的分段和逐文件检查**：仍重复解析和启动 Git，没有解决规则分散的问题。
- **手工解析 `diff --git` 里的转义文件名**：Git 原生 NUL 分隔统计已经提供更可靠的路径语义，不再维护另一套转义规则。
- **把原始补丁和全部逐文件内容一起返回**：大补丁需要重复传输；逐文件模式将平铺结果留空。

## 后果

一份 Git Diff 使用同一次 Git 进程取得 NUL 分隔统计与补丁。每个文件保留展示行和原始 hunk；CRLF 和缺少末尾换行时仍保留原始 hunk。重命名块另提供只修改目标文件内容的补丁，避免取消暂存单块时反转整个重命名。固定提交身份可以避免列表位置变化后查看到其他 Stash。返回数据不是跨外部 Git 操作的事务。

## 验证

- Core 仓库的 `rust/crates/core/src/tests/git_patch_exchange.rs`：真实临时仓库覆盖重命名、中文名称、未跟踪文件、二进制、Git 前缀配置以及错误的请求模式。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/workbench/...`：`desktop/internal/core/git_review_test.go` 覆盖 Stash 差异的宿主侧读取。
- `scripts/agent-notes/verify-agent-notes.sh` 和 `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

## 适用范围

- `desktop/internal/core/git_review.go`
- `desktop/internal/core/git_review_test.go`
- Core 仓库的 [`rust/crates/git/src/patch_exchange.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/git/src/patch_exchange.rs)，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
- [Core API 契约](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md)
