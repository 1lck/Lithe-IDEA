# Agent 笔记：推送目标与分支跟踪语义

状态：已实现

## 先说结论

Lithe 推送时不让 Git 的全局配置决定“推到哪”。创建分支不继承 upstream（上游跟踪分支），异名 upstream 必须由用户显式选择目标后才推送，且**预览与推送共用同一个目标解析函数**：用户看到的 `本地分支 → 远端/分支`，就是推送实际校验和更新的那个分支。这堵住了一个真实事故：从 `origin/main` 新建功能分支后推送，会直接把功能分支推到远端 `main`。

## 问题

从 `origin/main` 新建分支时，Git 默认配置 `branch.autoSetupMerge=true` 会把新分支的 upstream 设为 `refs/heads/main`。Lithe 的推送使用显式 refspec（`refs/heads/feature/topic:refs/heads/main`），绕过了 `push.default=simple` 对异名分支的保护，于是功能分支的提交被写进远端 `main`。

三处代码共同造成这个结果：创建分支时未控制跟踪；推送目标解析直接采用 upstream 的分支名；推送时用显式 refspec 拼装目标。

## 决策

- **创建分支显式 `--no-track`**：创建分支不再让 Git 决定上游，结果独立于用户全局配置。“检出远端分支并跟踪”是另一条语义，走 checkout 路径，两者必须保持分离，合并它们会重新引入隐式跟踪。
- **推送目标解析返回目标类型**：`resolve_push_target` 返回 `publish`（无 upstream，发布同名分支）、`tracking`（同名 upstream）、`divergent`（异名 upstream）三态。`divergent` 不作为默认推送目的地。
- **异名必须显式确认，且确认绑定到用户看到的那个分支**：`git.pushPreview` 与 `push` 都接受可选 `pushTarget`（`publish` 或 `upstream`），并用同一个解析函数求值。预览返回该选择会更新的远端分支、跟踪 OID 和提交列表，客户端把这份预览的 `expectedPush` 与同一个 `pushTarget` 一起发回；校验、`--force-with-lease` 的 OID 与最终 refspec 都来自这个有效目标。未确认时 `push` 返回 `invalid_request`。配置不会被静默改写：确认 `upstream` 时原配置保留，确认 `publish` 且推送成功后才改写。
- **提交并推送由 Core 在写任何提交之前提问**：`git.workspaceCommitPrepare` 对每个待推送的仓库检查是否异名，把需要回答的仓库放进 `pushTargetQuestions`（空时不序列化，保持旧客户端的线格式不变）。客户端带着 `pushTargets: { 仓库ID: { choice, remote, remoteBranch } }` 重新 prepare；回答必须与当前远端和分支一致才有效，否则 Core 再问一次。轮到某个仓库执行时，只要它的异名目标还没有有效回答，Core 就在写入该仓库的提交之前拒绝这一步，不会留下“已提交、却无法推送”的残留提交。
- **新增可选字段必须兼容旧调用方**：`expectedPush` 的 `targetKind` 只在调用方提供时才比较。把可选字段做成严格比较，会让所有未升级的调用方被判成“预览已过期”，这是实现中真实踩到的回归。
- **Viva 的推送对话框和提交审阅单使用 Core 的答案**：推送对话框（`desktop/internal/workbench/gitreview_tools_view.go` 的 `drawPushDialog`）顶部显示目的地，异名时不提供默认目的地，“推送”保持禁用直到用户选择；选择后用它重新取预览，若重新取回的目的地与做出选择时看到的不同，选择作废并重新询问。提交并推送的审阅单（`desktop/internal/workbench/commit_view.go` 的 `drawCommitTarget`）逐仓库展示目的地，异名仓库就地选择，选择通过 `pushTargets` 交给 Core 重新 prepare。每次重建审阅单都必须带上已有的 `pushTargets`，否则已回答的仓库会被再次询问。
- **每次推送都先审阅，且推的就是审阅的内容**：推送弹窗展示 Core 解析的目的地和将发送的提交，用户确认时把这份预览的 `expectedPush` 发回，Core 在仓库、目的地或跟踪提交已变化时按过期拒绝。

正确做法：新建分支后首次推送应发布到同名远端分支，远端 `main` 保持不变；异名场景先让用户看到“发布到 `origin/feature/topic`”和“推送到 `origin/main`”，用户选定后以该选择重新取预览，再推送。

错误做法：在推送路径上用固定写法绕过目标解析（例如固定 `git push --set-upstream origin <name>`）；在未确认时用 `--force` 或远端保护规则兜底；让预览用一套目标、推送用另一套目标；在客户端替 Core 预判“要不要问”。

## 考虑过的备选方案

- **设置仓库级 `branch.autoSetupMerge=false` 后恢复**：需要临时改用户配置，崩溃或中断会留下脏状态，且影响其他工具。改用命令级 `--no-track`。
- **在推送时把远端分支直接改成同名分支**：会让“有意配置异名 upstream”的用户失去该能力，且预览展示的目标与实际不符。
- **用布尔值表示目标**：表达能力不足，无法区分 `tracking`、`publish`、`divergent`，界面无法判断是否需要让用户选择。
- **为普通同名推送增加二次确认**：连续确认框会让用户机械点击，反而降低警觉性。只有异名目标需要决策。
- **由客户端在提交前先取预览再决定是否询问**：判定与实际推送使用两套解析，预览失败时只能中止或放行，两者都不安全。改由 Core 在 prepare 中统一提问。
- **工作区提交计划里只存一个全局 `pushTarget`**：多个仓库可能各自跟踪不同分支，一个选择会套用到所有仓库。改为按仓库 ID 的 `pushTargets`。

## 后果

收益：异名推送从“静默覆盖远端主干”变成“必须明确选择”；创建分支的行为不再随用户 Git 配置漂移；推送预览、过期校验、租约和最终更新的分支始终一致；没有任何路径会留下推不出去的提交。

代价：从远端新建的分支不再有 upstream，`pushPreview` 改走“排除远端可达提交”的计算路径。异名分支的存量仓库在推送时会出现一次选择交互，这是预期行为。

## 验证

- Core 仓库的 [`rust/crates/core/tests/git_push.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/core/tests/git_push.rs)：新建分支无 upstream、检出远端分支仍建立跟踪、异名未确认被拒、确认 `publish` 与 `upstream` 各自的落点、旧调用方省略 `targetKind` 仍可推送、`--force-with-lease` 作用在所选 upstream 分支上。
- Core 仓库的 `rust/crates/core/src/tests/git_workspace_commit.rs`：异名分支在提交前被询问且不产生提交、多仓库逐个提问与确认、重试时恢复并重新校验确认值。
- 桌面端 `desktop/internal/core/git_push_test.go`、`desktop/internal/workbench/gitreview_test.go`（`TestPushDialogReviewsAndPushes`）与 `desktop/internal/workbench/commit_test.go`（`TestCommitAndPushShowsTheReviewFirst`）覆盖宿主侧的预览、审阅与选择回传。
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/core/git_push.go`
- `desktop/internal/core/gitcommit.go`
- `desktop/internal/workbench/gitreview_tools_view.go`
- `desktop/internal/workbench/commit_view.go`
- Core 仓库的 Git 推送与工作区提交实现（`git/mod.rs`、`git/workspace_commit.rs`、`protocol/contracts.rs`），以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
