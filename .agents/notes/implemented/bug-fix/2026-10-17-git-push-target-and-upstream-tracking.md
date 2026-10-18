# Agent 笔记：推送目标与分支跟踪语义

状态：已实现

## 先说结论

Lithe 推送时不再让 Git 的全局配置决定“推到哪”。创建分支不继承 upstream（上游跟踪分支），异名 upstream 必须由用户显式选择目标后才推送，推送前界面展示完整方向 `本地分支 → 远端/分支`。这次修复堵住了一个真实事故：从 `origin/main` 新建功能分支后推送，会直接把功能分支推到远端 `main`。

## 问题

从 `origin/main` 新建分支时，Git 默认配置 `branch.autoSetupMerge=true` 会把新分支的 upstream 设为 `refs/heads/main`。Lithe 的推送使用显式 refspec（`refs/heads/feature/topic:refs/heads/main`），绕过了 `push.default=simple` 对异名分支的保护，于是功能分支的提交被写进远端 `main`。

三处代码共同造成这个结果：创建分支时未控制跟踪；推送目标解析直接采用 upstream 的分支名；推送时用显式 refspec 拼装目标。同一个文件里的 worktree 创建路径早已用 `--track`/`--no-track` 显式冻结跟踪语义，`createBranch` 却漏了。

## 决策

- **创建分支显式 `--no-track`**：`createBranch` 不再让 Git 决定上游，结果独立于用户全局配置。“检出远端分支并跟踪”是另一条语义，走 `checkout` 路径，不受影响。两者必须保持分离——合并它们会重新引入隐式跟踪。
- **推送目标解析返回目标类型**：`resolve_push_target` 返回 `publish`（无 upstream，发布同名分支）、`tracking`（同名 upstream）、`divergent`（异名 upstream）三态。`divergent` 不作为默认推送目的地。
- **异名必须显式确认**：推送请求携带可选 `pushTarget`，取 `publish`（发布到同名远端分支并回指 upstream）或 `upstream`（沿用异名上游）。未确认时 Core 返回 `invalid_request`。配置不会被静默改写：确认 `upstream` 时原配置保留，确认 `publish` 且推送成功后才改写。
- **新增可选字段必须兼容旧调用方**：`expectedPush` 的 `targetKind` 只在调用方提供时才比较。把可选字段做成严格比较，会让所有未升级的调用方被判成“预览已过期”——这是本次实现中真实踩到的回归。
- **Windows 两个入口都前置目标选择**：推送弹窗内联展示方向与选项；“提交并推送”在工作区提交计划里携带 `pushTarget`，并在提交前询问，避免先提交成功再推送失败。
- **macOS 只透传可选参数**：桥接层接受 `pushTarget` 但默认 `nil`。macOS 没有推送预览层，异名分支会得到明确错误而非静默更新远端分支；界面选择留给后续独立变更。

正确做法：新建分支后首次推送应发布到同名远端分支，远端 `main` 保持不变；异名场景先让用户看到“发布到 `origin/feature/topic`”和“推送到 `origin/main`”再决定。

错误做法：在推送路径上调用 `git push --set-upstream origin <name>` 之类的固定写法绕过目标解析（`publishBranch` 是 macOS PR 流程的专用入口，其 `origin` 在该语境下是正确的，不属于本条约束）；或在未确认时用 `--force` 或远端保护规则兜底。

## 考虑过的备选方案

- **设置仓库级 `branch.autoSetupMerge=false` 后恢复**：需要临时改用户配置，崩溃或中断会留下脏状态，且影响其他工具。改用命令级 `--no-track`。
- **在推送时把 `remote_branch` 直接改成同名分支**：会让“有意配置异名 upstream”的用户失去该能力，且预览展示的目标与实际不符。
- **用布尔 `isPublish` 表示目标**：表达能力不足，无法区分 `tracking`、`publish`、`divergent`，界面无法判断是否需要让用户选择。
- **为普通同名推送增加二次确认**：连续确认框会让用户机械点击，反而降低警觉性。只有异名目标需要决策。
- **修改 `publishBranch` 的远端解析**：它服务于 macOS 在分离 HEAD 下发布 PR 分支，硬编码 `origin` 在该语境正确，且 issue 未涉及，修改会带来无法在本机验证的 macOS 回归风险。

## 后果

收益：异名推送从“静默覆盖远端主干”变成“必须明确选择”；创建分支的行为不再随用户 Git 配置漂移；推送预览与实际目标一致。

代价：从远端新建的分支不再有 upstream，`pushPreview` 改走“排除远端可达提交”的计算路径；这曾有显示 0 个提交的风险，已用集成用例钉住。异名分支的存量仓库在推送时会出现一次选择交互，这是预期行为。macOS 侧暂时只有错误提示，没有选择界面。

## 验证

- `rust/lithe-core/tests/git_push.rs` 覆盖：新建分支无 upstream、检出远端分支仍建立跟踪、本地起点不产生 upstream、异名未确认被拒、确认 `publish` 与 `upstream` 各自的落点、旧调用方省略 `targetKind` 仍可推送、`targetKind` 给错仍被拒、无 upstream 分支的预览仍列出自身提交。
- `rust/lithe-core/src/tests/git_workspace_commit.rs` 覆盖提交并推送时 `pushTarget` 随计划传递，远端 `main` 不被改动。
- `windows/tauri/src/features/git/api/git-push-api.test.ts` 与 `windows/tauri/src/features/git/components/git-push-target-prompt.test.tsx` 覆盖同名推送不带 `pushTarget`、异名转发确认值、两项按钮文案写明落点。
- `shared/contracts/rust-core-api.md` 记录 `targetKind`、`createsRemoteBranch`、`pushTarget` 与异名确认规则。
- 运行 `scripts/verify-platform-feature-matrix.sh`、`scripts/verify-agent-notes.sh`、`cargo test --manifest-path rust/lithe-core/Cargo.toml --test git_push`。

## 适用范围

- `rust/lithe-core/src/git/mod.rs`：`createBranch`、`resolve_push_target`、`push`、`push_preview`、`validate_push_expectation`。
- `rust/lithe-core/src/git/workspace_commit.rs`：提交并推送的 `pushTarget` 传递。
- `rust/lithe-core/src/protocol/contracts.rs`：`GitPushTargetKind`、`GitPushPreviewResponse`。
- `windows/tauri/src/features/git/`：推送弹窗、目标提示、提交面板与推送 API。
- `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift`、`RustGitOperations.swift`、`macos/Sources/LitheGitModule/Services/GitService.swift`：仅透传可选参数。
- 不适用于 `publishBranch`（macOS PR 分支发布），其固定 `origin` 是该场景的正确行为。
