# Agent 笔记：检出 GitHub 拉取请求时保留本地分支

状态：已实现

## 先说结论

检出拉取请求前，Core 先给出要获取的内容、本地分支名和分支冲突，界面显示计划并让用户确认。已有同名分支时不能继续；执行时重新检查工作区和分支，使用只创建新分支的 Git 操作，不能重置已有分支。

## 问题

旧 macOS 适配器自行拼出 `checkout -B`。当 `pr/42-feature-42` 已指向用户自己的提交时，这个命令会把分支移到拉取请求的提交，原来的分支引用不再保留。只在界面检查一次也挡不住用户确认后、Git 操作开始前发生的变化。

## 决策

Core 生成安全的本地名称并检查同名、父级及子级引用；预览同时记录当前提交、当前分支和实际 origin 地址的进程内加盐摘要，核对 origin 是否仍属于界面显示的 GitHub 仓库。摘要不暴露可能含凭据的地址，进程重启后旧预览也不能复用。用户确认后，在 Git 写入租约内复查这些事实，再获取拉取请求；网络请求结束后还要再次复查，然后用 `checkout -b` 创建分支。即使外部 Git 在最后一次检查之后新建同名分支，Git 也会拒绝创建，不会覆盖它。

正确做法：分支冲突时展示错误并保留现有引用，由用户先处理冲突。不要先重置分支、只依靠旧的界面预览，或把带 `-B` 的命令交给平台层拼装。已有请求的确认只适用于原工作区和原拉取请求；切换工作区或选中其他请求后需要重新预览。

## 考虑过的备选方案

继续使用 `-B` 并添加覆盖确认，会要求用户理解引用丢失的风险，且确认后仍存在竞争。自动选一个新名字会让用户看不到实际创建的分支，也不能满足事先审阅；因此当前要求解决冲突后重试。

## 后果

该流程增加一次显式确认和数次只读 Git 检查；它不会自动更新已存在的拉取请求分支。Lithe 的写入租约不能阻止其他 Git 客户端并发修改工作区，Git 自身的 checkout 和创建分支检查仍是最后一道保护。

## 验证

`GitHubServiceTests/checkoutDoesNotResetExistingBranch` 在临时仓库复现旧实现重置分支，并检查冲突、过期预览和正常检出。Core 的 `github_pr_checkout` 测试还验证 origin 变更和地址脱敏。`Lithe-core-rust/rust/fixtures/github/pr-checkout-plan-v1.json` 由 Core 和 Swift 桥接测试共同验证。

## 适用范围

`rust/crates/git/src/github_checkout.rs`、`rust/crates/github/src/lib.rs`、`macos/Sources/Lithe/Platform/MacOS/GitHub/MacGitHubGitOperations.swift` 和 GitHub 拉取请求界面。Windows GitHub 产品入口尚未启用；启用时也应使用同一计划和安全执行入口。
