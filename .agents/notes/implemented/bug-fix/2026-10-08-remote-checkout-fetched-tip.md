# Agent 笔记：远程 Checkout 更新到已 Fetch 的节点

状态：已实现

## 先说结论

用户 Fetch 后再 Checkout 远程分支时，已有同名本地分支必须更新到所选远程节点；当前已经处于该本地分支时也需要更新。更新只允许快进，即推进分支且保留全部已有提交。本地存在远程未包含的提交时拒绝操作，用户需先处理这些提交。

## 问题

Fetch 只更新远程跟踪引用，即本机记录的远程分支位置。原实现发现同名本地分支后只执行 `git switch`，切换成功但本地分支仍停在旧节点；已经处于本地分支时还会提前报错。

IntelliJ Community `fb72b4df43aba102479eb0502d20b03586b9c5b8` 的 `GitRemoteBranchesUtil.kt`、`GitBranchCheckoutOperation.kt` 和 `GitImpl.java` 会检查本地独有提交，安全时把本地分支对齐远程。本地有额外提交时，IDEA 提供 Rebase、丢弃提交和取消。Lithe 本次仅自动执行保留全部提交的快进，其他情况明确拒绝，不新增历史重写选择界面。

## 决策

- 普通远程 Checkout 在 Rust Core 中统一处理，两端沿用 `git.write/checkout`，不在界面里追加 Pull 或第二次 Fetch。
- 更新已有分支前固定本地与远程提交的对象标识，确认本地提交是远程提交的祖先。当前已检出的目标分支也执行同一检查；没有本地分支时继续从远程创建并设置跟踪。
- 切换前按最终远程文件内容检查本地修改。更新复用 Git 的 `merge --ff-only`，只推进分支，不生成合并提交；切换后再次检查当前分支与提交，避免继续更新已被钩子或外部客户端改变的分支。
- 本地独有提交必须在自动 stash（暂存本地未提交修改）之前被拒绝。Force Checkout 只授权丢弃未提交修改，不能授权丢弃本地提交。其他工作树占用仍由 Git 拒绝。
- 普通本地 Checkout 与 Checkout and Rebase 保持原有含义，后者是把目标分支变基到原当前分支，不暗中改成远程更新。
- 两端在成功和失败后都刷新真实仓库状态：切换、快进与恢复暂存修改是组合操作，后续失败不能被解释成仓库完全没有变化。
- Windows Git Log 的 Checkout 成功提示由界面用现有本地化文案生成，包含所选引用名称。Checkout API 的成功 `message` 为空，直接把它作为 toast 文案会只剩成功图标；不能依赖 Git 输出作为产品成功提示。失败继续展示实际错误信息。

例如本地 `preview` 在 A、已 Fetch 的 `upstream/preview` 在后继 B，从其他分支 Checkout 远程后应得到 `HEAD = preview = B`；已在 `preview` 时也得到 B。不要只切到 A，也不要未经检查直接 `switch -C` 强制覆盖本地提交。

## 考虑过的备选方案

- 切换后自动 Pull：会重新访问网络，并可能受到合并策略影响而生成合并提交，不能保证对齐用户刚选择的已 Fetch 节点。
- 检查一次祖先关系后用 `switch -C`：检查和强制重置之间若有外部提交，可能覆盖新提交。快进操作由 Git 继续保护已有历史。
- 完整复制 IDEA 的分叉选择界面：需要两端新增历史重写确认和恢复流程，超出本次“远程 Checkout 更新旧本地分支”的修复范围。

## 后果

更新位置由共享 Core 决定，Windows 和 macOS 不再各自补充网络或合并操作。代价是增加本地 Git 检查；本地有独有提交时需要用户先处理，不能强制落到远程节点。写租约只串行化 Lithe 写入，分支复查缩小外部客户端竞争窗口，不构成外部 Git 的跨进程锁。

## 验证

- 共享场景 `shared/fixtures/git/remote-checkout-v1.json` 由真实 Git 集成测试驱动，覆盖当前／其他分支、缺失本地分支、工作区／暂存区／未跟踪文件、Force、Smart Checkout、本地独有提交和其他工作树占用。
- `rust/lithe-core/src/tests/git_remote_checkout.rs` 验证真实 Fetch 后 HEAD、本地引用、跟踪关系与文件内容一致，并验证失败保留引用、文件、暂存区和 stash；另覆盖旧请求格式、普通本地 Checkout 与 Checkout and Rebase。
- `windows/tauri/src/features/git/components/log/git-log-branch-actions.test.tsx` 使用实际 API 的空成功 `message`，验证本地／远程 Checkout 在中英文下仍显示完整成功文案与所选引用名称，并刷新 Git Log。
- 运行 `.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1` 和共享 Rust 的单测试计时工具；运行 `scripts/verify-rust-core-comments.sh`、`scripts/verify-agent-notes.sh`、`scripts/verify-platform-feature-matrix.sh`、`scripts/verify-runtime-bundle-immutability.sh`。
- 用户于 2026-10-08 确认本次 Windows 改动的本地测试没有问题，作为远程 Checkout 更新与成功提示恢复的用户验收依据。macOS 编译／原生界面及其他矩阵验收场景仍需单独验证；不要把本次反馈扩大为整项能力的全平台验收。

## 适用范围

- `rust/lithe-core/src/git/mod.rs`
- `rust/lithe-core/src/tests/git_remote_checkout.rs`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/git/remote-checkout-v1.json`
- `windows/tauri/src/features/git/api/git-branches-api.ts`
- `windows/tauri/src/features/git/components/log/git-log-tool-window.tsx`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
