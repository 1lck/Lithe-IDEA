# Agent 笔记：推送目标与分支跟踪语义

状态：已实现

## 先说结论

Lithe 推送时不再让 Git 的全局配置决定“推到哪”。创建分支不继承 upstream（上游跟踪分支），异名 upstream 必须由用户显式选择目标后才推送，且**预览与推送共用同一个目标解析函数**：用户看到的 `本地分支 → 远端/分支`，就是推送实际校验和更新的那个分支。这次修复堵住了一个真实事故：从 `origin/main` 新建功能分支后推送，会直接把功能分支推到远端 `main`。

## 问题

从 `origin/main` 新建分支时，Git 默认配置 `branch.autoSetupMerge=true` 会把新分支的 upstream 设为 `refs/heads/main`。Lithe 的推送使用显式 refspec（`refs/heads/feature/topic:refs/heads/main`），绕过了 `push.default=simple` 对异名分支的保护，于是功能分支的提交被写进远端 `main`。

三处代码共同造成这个结果：创建分支时未控制跟踪；推送目标解析直接采用 upstream 的分支名；推送时用显式 refspec 拼装目标。同一个文件里的 worktree 创建路径早已用 `--track`/`--no-track` 显式冻结跟踪语义，`createBranch` 却漏了。

## 决策

- **创建分支显式 `--no-track`**：`createBranch` 不再让 Git 决定上游，结果独立于用户全局配置。“检出远端分支并跟踪”是另一条语义，走 `checkout` 路径，不受影响。两者必须保持分离——合并它们会重新引入隐式跟踪。
- **推送目标解析返回目标类型**：`resolve_push_target` 返回 `publish`（无 upstream，发布同名分支）、`tracking`（同名 upstream）、`divergent`（异名 upstream）三态。`divergent` 不作为默认推送目的地。
- **异名必须显式确认，且确认绑定到用户看到的那个分支**：`git.pushPreview` 与 `push` 都接受可选 `pushTarget`（`publish` 或 `upstream`），并用同一个 `resolve_push_target(root, reference, choice)` 解析。预览带着选择取回“该选择会更新的远端分支、跟踪 OID 和提交列表”，客户端再把这份预览的 `expectedPush` 与同一个 `pushTarget` 一起发回；`validate_push_expectation`、`--force-with-lease` 的 OID 与最终 refspec 都来自这个有效目标。未确认时 `push` 返回 `invalid_request`，错误信息写明可行的命令行替代做法。配置不会被静默改写：确认 `upstream` 时原配置保留，确认 `publish` 且推送成功后才改写。
- **提交并推送由 Core 在写任何提交之前提问**：`git.workspaceCommitPrepare` 对每个待推送的仓库用同一个解析函数检查是否异名，把需要回答的仓库放进 `pushTargetQuestions`（空时不序列化，保持旧客户端与共享 fixture 的线格式不变）。客户端带着 `pushTargets: { 仓库ID: { choice, remote, remoteBranch } }` 重新 prepare；回答必须与当前远端和分支一致才算有效，否则 Core 再问一次。回答按仓库 ID 分别保存在 `plan.pushTargets`，重试时由 Core 从上一次会话恢复并重新校验，客户端无需转发。轮到某个仓库执行时，只要它的异名目标还没有有效的回答，Core 就在写入该仓库的提交之前拒绝这一步，所以不会出现“已提交、却因目标未确认而无法推送”的残留提交，也保护了不处理这些问题的旧客户端。
- **新增可选字段必须兼容旧调用方**：`expectedPush` 的 `targetKind` 只在调用方提供时才比较。把可选字段做成严格比较，会让所有未升级的调用方被判成“预览已过期”——这是本次实现中真实踩到的回归。`pushTargetQuestions` 同理，空数组不出现在线格式里。
- **Windows 两个入口都使用 Core 的答案**：推送弹窗选择后用该选择重新取预览，并在重新取回的预览与第一次确认的目的地不一致时撤销选择；“提交并推送”不再在客户端先取预览，而是把请求直接交给工作流，由 Core 返回问题，面板用一个对话框一次回答所有仓库。
- **macOS 每次推送都先审阅，且推的就是审阅的内容**：分支的“推送”不再弹出只问“要推送吗”的确认框，而是打开 IDEA 式推送弹窗。弹窗先向 Core 取 `git.pushPreview`，顶部显示 `本地分支 → 远端/分支`（需要时注明“将在 origin 上创建新分支”或“将 origin/x 设为上游分支”），左侧列出将发送的提交，右侧显示所选提交改动的文件；用户点“推送”后，弹窗把**这份预览**的 `expectedPush` 与同一个 `pushTarget` 发回，Core 在仓库、目的地或跟踪提交已变化时按过期拒绝。取代的是原来每次都出现、却不告诉用户目的地的确认框，所以没有增加点击次数。
- **macOS 异名上游在弹窗内选择，选择绑定到当时看到的目的地**：`divergent` 时弹窗不提供默认目的地，“推送”保持禁用，直到用户在“发布到 `origin/<本地分支>`”和“推送到 `origin/<上游>`”中选一个；选择后用它重新取预览，使提交列表和目的地与最终远端一致。若重新取回的目的地与做出选择时看到的不同（上游被改指别处），选择作废并重新询问。没有新提交的“发布分支”仍允许推送，因为它会创建远端分支。
- **macOS “提交并推送”先出审阅单再提交**：只要请求带 `push`，就始终显示审阅单，列出每个仓库的目的地，而不再只在含子模块时才显示。异名仓库在审阅单里就地选择，选择通过 `pushTargets` 交给 Core 重新 prepare；Core 仍在提交之前再校验一次，答案与当前远端不符就重新提问。审阅单保留已提出过的问题，让用户在继续之前仍可改选；每次重建审阅单（切换父仓库引用、确认）都必须带上已有的 `pushTargets`，因为 Core 不会从 `reviewed` 计划继承它们——漏带会让已回答的仓库再被询问。原生层的 `GitWorkspaceCommitPlan` 也必须保留 `pushTargets` 字段，否则计划经原生层往返后答案丢失，推送步骤会被 Core 拒绝。

正确做法：新建分支后首次推送应发布到同名远端分支，远端 `main` 保持不变；异名场景先让用户看到“发布到 `origin/feature/topic`”和“推送到 `origin/main`”，用户选定后以该选择重新取预览，再推送。

错误做法：在推送路径上调用 `git push --set-upstream origin <name>` 之类的固定写法绕过目标解析（`publishBranch` 是 macOS PR 流程的专用入口，其 `origin` 在该语境下是正确的，不属于本条约束）；在未确认时用 `--force` 或远端保护规则兜底；让预览用一套目标、推送用另一套目标（第一版实现就因此出现“预览显示同名分支，确认 `upstream` 后实际更新 `main`，而校验仍通过”的缺口）；在客户端替 Core 预判“要不要问”，并在预判没有结果时直接中止（会让所有普通“提交并推送”静默失效）。

## 考虑过的备选方案

- **设置仓库级 `branch.autoSetupMerge=false` 后恢复**：需要临时改用户配置，崩溃或中断会留下脏状态，且影响其他工具。改用命令级 `--no-track`。
- **在推送时把 `remote_branch` 直接改成同名分支**：会让“有意配置异名 upstream”的用户失去该能力，且预览展示的目标与实际不符。
- **用布尔 `isPublish` 表示目标**：表达能力不足，无法区分 `tracking`、`publish`、`divergent`，界面无法判断是否需要让用户选择。
- **为普通同名推送增加二次确认**：连续确认框会让用户机械点击，反而降低警觉性。只有异名目标需要决策。macOS 的推送弹窗不属于这一类：它替换了原有的无信息确认框，承载的是“看到目的地和提交”这个信息，而不是多一次询问。
- **macOS 只在异名时才弹窗，普通推送沿用原确认框**：原确认框只说“推送所选本地分支到已配置的远程仓库”，用户无法在点击前看到真正的目的地，正是本次事故的盲区。改为每次都展示目的地与提交。
- **macOS 在客户端自己判断目的地**：与 Windows 的结论相同——判定与实际推送分属两套解析会让预览与推送不一致。弹窗与审阅单只展示 Core 解析的结果。
- **工作区提交计划里只存一个全局 `pushTarget`**：多个仓库可能各自跟踪不同的分支，一个选择会套用到所有仓库，既可能把答案用到没被问过的仓库，也无法逐个校验。改为按仓库 ID 的 `pushTargets`。
- **由客户端在提交前先取预览再决定是否询问**：判定与实际推送使用两套解析，预览失败时只能中止或放行，两者都不安全；并且每个客户端都要重写一遍。改由 Core 在 prepare 中统一提问。
- **修改 `publishBranch` 的远端解析**：它服务于 macOS 在分离 HEAD 下发布 PR 分支，硬编码 `origin` 在该语境正确，且 issue 未涉及，修改会带来无法在本机验证的 macOS 回归风险。

## 后果

收益：异名推送从“静默覆盖远端主干”变成“必须明确选择”；创建分支的行为不再随用户 Git 配置漂移；推送预览、过期校验、租约和最终更新的分支始终一致；没有任何路径会留下推不出去的提交。

代价：从远端新建的分支不再有 upstream，`pushPreview` 改走“排除远端可达提交”的计算路径；这曾有显示 0 个提交的风险，已用集成用例钉住。异名分支的存量仓库在推送时会出现一次选择交互，这是预期行为。

macOS 的界面（推送弹窗与提交并推送审阅单）已接入，但**尚未在真机界面上目视验证**：原生层与 Core 的衔接由真实 Core 的集成用例覆盖，SwiftUI 布局、明暗主题和窄窗口表现仍需要有人打开应用确认。

## 验证

- `rust/lithe-core/tests/git_push.rs` 覆盖：新建分支无 upstream、检出远端分支仍建立跟踪、本地起点不产生 upstream、异名未确认被拒、确认 `publish` 与 `upstream` 各自的落点、旧调用方省略 `targetKind` 仍可推送、`targetKind` 给错仍被拒、无 upstream 分支的预览仍列出自身提交；以及按选择预览的目标分支、跟踪 OID 与 `createsRemoteBranch`、确认后 upstream 被改指另一分支时已审阅的推送被判过期、选择与预览不一致被判过期、`--force-with-lease` 作用在所选 upstream 分支及其 OID 上、对非异名分支忽略 `pushTarget`。
- `rust/lithe-core/src/tests/git_workspace_commit.rs` 覆盖：异名分支在提交前被询问且不产生提交、确认值随计划传递并在 `/` 分隔的 upstream 上保持原配置、多仓库逐个提问与确认、重试时恢复并重新校验确认值、upstream 在确认后移动会再次提问。
- `windows/tauri` 的 `git-push-api.test.ts`、`git-push-target-prompt.test.tsx`、`git-workspace-commit-workflow.test.ts`、`git-commit-panel.test.tsx`、`git-commit-panel-push-target.test.tsx` 覆盖：预览携带 `pushTarget`、普通“提交并推送”直接到达工作流、提问先于审阅与提交、答案累加与取消、逐仓库回答并绑定远端分支。
- `shared/contracts/rust-core-api.md` 记录 `targetKind`、`createsRemoteBranch`、预览与推送的 `pushTarget`、`pushTargetQuestions` 与 `pushTargets`。
- `macos/Tests/LitheTests/GitPushReviewBridgeTests.swift` 用真实 Core 和本地裸远端覆盖：异名上游的预览为 `divergent`；选 `publish` 后目的地是同名远端分支并创建它、远端 `main` 不变；选 `upstream` 只更新异名分支；预览之后仓库又有新提交时推送被拒绝并带 Core 的“预览已过期”信息（Core 把拒绝放在 `operationError` 而不是退出码里，原生层必须检查它）；“提交并推送”先返回问题、带 `pushTargets` 重新 prepare 后问题消失，逐步执行后只更新所选分支。
- `macos/Tests/LitheTests/GitPushDialogPresentationTests.swift` 覆盖弹窗状态：异名上游在选择前不可推送、选择绑定到看到的目的地并在目的地变化时作废、推送发出的恰是审阅的预览与选择、被拒绝后重新加载并显示原因、没有新提交的发布分支仍可推送、无内容时不可推送、选中提交会加载其改动文件。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift` 覆盖：预览与审阅后的推送经服务层透传，推送失败显示原因并清除忙碌状态；“提交并推送”在 Core 不要求确认时也先停在审阅单、不执行任何步骤；异名问题阻止继续、答案随请求与后续确认一起发给 Core、问题被再次提出时旧答案作废；`pushTargets` 与 `pushTargetQuestions` 的线格式往返。
- `AppLocalizationTests.pushDestinationUsesTheRequestedLanguage` 覆盖弹窗新增文案的中英文。
- 运行 `scripts/verify-platform-feature-matrix.sh`、`scripts/verify-agent-notes.sh`、`cargo test --manifest-path rust/lithe-core/Cargo.toml --test git_push` 与 `--lib git`。macOS 通过 `scripts/test-macos.sh --no-parallel --filter` 运行了上述相关套件（Rust Core 已链接）；完整套件在本机并行运行时有与本变更无关的超时类用例失败，未作为通过依据。Windows 真机界面未在本次变更中运行。

## 适用范围

- `rust/lithe-core/src/git/mod.rs`：`createBranch`、`resolve_push_target`、`divergent_push_destination`、`push`、`push_preview`、`validate_push_expectation`。
- `rust/lithe-core/src/git/workspace_commit.rs`：`pushTargetQuestions`、`pushTargets`、按仓库的确认与重试时的恢复。
- `rust/lithe-core/src/protocol/contracts.rs`：`GitPushTargetKind`、`GitPushPreviewResponse`。
- `windows/tauri/src/features/git/`：推送弹窗、目标提示、提交面板、工作区提交工作流与推送 API。
- `macos/Sources/Lithe/Core/Rust/RustCoreBridge+GitPush.swift`、`macos/Sources/LitheGitModule/Services/GitService.swift`、`GitFeatureModel.swift`、`GitFeatureModel+WorkspaceCommit.swift`、`macos/Sources/LitheGitModule/Models/GitPushModels.swift`、`GitWorkspaceCommitModels.swift`：推送预览、审阅后的推送、`pushTargets` 与 `pushTargetQuestions` 的原生承载；只转发 Core 的解析结果。
- `macos/Sources/Lithe/Views/Git/GitPushDialog.swift`、`GitLogView.swift`、`WorkbenchView.swift`、`CommitAreaView.swift`：推送弹窗（分支列表、顶栏分支弹窗）与提交并推送审阅单。
- 不适用于 `publishBranch`（macOS PR 分支发布），其固定 `origin` 是该场景的正确行为。
