# Git 冲突处理：与 IntelliJ IDEA 的对照及后续开发计划

本文对照 IntelliJ IDEA 社区版（`plugins/git4idea`）的实现，记录 Lithe 当前
Git 冲突处理能力的位置，并给出后续开发项的设计。

**读者**：接手实现的开发者。本文只做设计，不含已完成代码的说明——已完成部分
请直接读源码，本文只在需要对照时引用。

**代码位置**：已完成部分位于分支 `feat/git-conflict-handling`，共三个提交，
基线为 `2a4ad6f`。详见第 6 节。

**参考源码路径**：本文所有 `plugins/git4idea/...` 与 `platform/...` 路径均相对于
IntelliJ 社区版仓库根目录。行号基于撰写本文时的 master 快照，仅供定位，
可能随上游变动。

---

## 1. 一个必须先理解的前提：为什么我们不匹配 Git 的输出

这条决定了后面所有设计，接手的人**必须先读懂这一节**，否则很容易"顺手"写出
匹配错误文本的代码，在中文 Git 环境下静默失效。

### 1.1 IDEA 的做法

IDEA 大量依赖匹配 Git 的 stderr 英文文本。它维护了一张事件字符串表：

```java
// plugins/git4idea/backend/src/commands/GitSimpleEventDetector.java:20-35
public enum Event {
  CHERRY_PICK_CONFLICT("after resolving the conflicts", "CONFLICT (content): Merge conflict"),
  UNMERGED_PREVENTING_CHECKOUT("you need to resolve your current index first"),
  UNMERGED_PREVENTING_MERGE("is not possible because you have unmerged files"),
  BRANCH_NOT_FULLY_MERGED("is not fully merged"),
  MERGE_CONFLICT("Automatic merge failed; fix conflicts and then commit the result"),
  ALREADY_UP_TO_DATE("Already up-to-date", "Already up to date"),
  INVALID_REFERENCE("invalid reference:");
```

还有专门解析文件列表的正则：

```java
// plugins/git4idea/backend/src/commands/GitLocalChangesWouldBeOverwrittenDetector.java:43-48
public static final Event NEW_PATTERN = new Event(
  "LocalChangesDetector",
  List.of(Pattern.compile(".*Your local changes to the following files would be overwritten by.*")),
  ...
```

### 1.2 它凭什么敢这么做

因为它在每次调用 Git 前**强制了语言环境**：

```kotlin
// platform/vcs-impl/src/com/intellij/vcs/VcsLocaleHelper.kt:42-47
private fun createEnvForLocale(locale: String): Map<String, String> {
  val envMap = LinkedHashMap<String, String>()
  envMap["LANGUAGE"] = ""
  envMap["LC_ALL"] = locale   // 默认 en_US.UTF-8
  return envMap
}
```

由 `plugins/git4idea/backend/src/config/GitExecutable.kt:174` 应用到所有 Git 进程。
即 IDEA 不是没考虑本地化问题，而是**先消灭本地化，再放心匹配文本**。

### 1.3 我们的现状与约束

Lithe 目前**没有**设置任何语言环境（`rust/lithe-core/src/git.rs:425` 直接
`Command::new("git")`，未设 env）。开发机上的 Git 是中文输出。因此：

> **硬性约束**：在 `LC_ALL` 方案落地之前，任何新代码都不得依赖 Git 的
> stderr/stdout 自然语言文本做判断。只能使用退出码、porcelain 输出、
> `--name-only` 之类的机器可读输出，以及集合运算。

现有实现遵循了这条约束，靠"预检 + 集合求交"替代文本匹配。

### 1.4 待决策项：要不要也设 `LC_ALL`

这是一个**需要产品/技术负责人拍板**的问题，本文不替你决定，只列权衡。

| | 设 `LC_ALL=C.UTF-8` | 维持现状（不设） |
|---|---|---|
| 能否兜底未知失败态 | 能，可像 IDEA 那样加 detector | 不能，只能靠退出码粗判 |
| 对 Git 版本升级的健壮性 | 差，上游改文案就失效 | 好，porcelain 有兼容承诺 |
| 对用户 alias / i18n 补丁 | 仍可能被 `~/.gitconfig` 干扰 | 不受影响 |
| 用户看到的报错语言 | 变成英文，中文用户体验下降 | 保持用户语言 |
| 改动成本 | 小（一处 env 设置） | 0 |

**建议**：折中——设 `LC_ALL` 但**只用于兜底日志和错误上报**，不用于控制流判断。
主判断逻辑继续走 porcelain。这样既保住健壮性，又在出现未知错误时能拿到
可搜索的英文原文。若采纳，需同时决定"给用户看的报错"用哪份文本。

---

## 2. 时序差异：预检 vs 先做再补救

两种模式都成立，记录在此是为了让接手者理解现有代码为何这样组织，
**不建议改成 IDEA 的模式**。

**IDEA**：直接执行 → 失败 → detector 抓错 → 弹窗 → 智能重试。

```java
// plugins/git4idea/backend/src/branch/GitMergeOperation.java:265-270
GitCommandResult result = myGit.merge(repository, ..., mergeConflict);
if (!result.success()) {
  if (mergeConflict.isDetected()) { ... }
```

**Lithe**：preflight 查工作区 → 有阻塞则弹窗 → 用户选 → 执行。

Lithe 模式多一次 Git 调用，但换来两个好处：动手前就把选择权交给用户；
失败时不会留下半成品状态。代价是 preflight 的规则必须自己维护正确——
下节即为此。

### 2.1 已实测确认的 Git 行为规则

以下规则**逐条对真实 Git 验证过**，是 `integration_preflight` 的设计依据。
后续若新增操作类型，必须同样实测，不要靠推断。

| 操作 | 拒绝条件 | 退出码 | 对应 `IntegrationShape` |
|---|---|---|---|
| `merge` | 仅当脏文件与"合并基点→目标"的差异集重叠 | 2 | `MergeBase` |
| `rebase` | 任何未提交改动，暂存与否、是否相关都拒绝 | 1 | `AnyDirty` |
| `cherry-pick` | 仅当脏文件与"该提交自身的差异集"重叠 | 128 | `SingleCommit` |
| `revert` | 同 cherry-pick | 128 | `SingleCommit` |
| `pull --ff-only`（已分叉） | 无法快进 | 128 | 走 `pull_preflight` |

注意 cherry-pick/revert 与 merge 的区别：规则同为"看重叠"，但重叠集来源不同。
前者重放**单个提交**，集合来自 `git diff-tree -r -m --root --name-only
--no-commit-id <ref>`；后者来自 merge-base 差异。

---

## 3. 差距清单与开发项

按建议实施顺序排列。每项含现状、IDEA 对照、设计方案、验收标准。

---

### 开发项 A：冲突文件列表支持查看 diff 与单文件回滚

**优先级：高**（投入产出比最高）

#### 现状

三个冲突对话框（`GitCheckoutConflictDialog`、`GitIntegrationConflictDialog`、
`GitPullStrategyDialog`）都只渲染一列纯文本路径：

```swift
// Sources/Lithe/Views/GitLogView.swift:1440-1451
ScrollView {
    VStack(alignment: .leading, spacing: 3) {
        ForEach(request.blockingPaths, id: \.self) { path in
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
            ...
```

用户看到"这 5 个文件挡住了你"，但想知道自己到底改了什么，必须关掉对话框、
去 Changes 面板逐个点开、再回来重新触发操作。

#### IDEA 对照

```java
// plugins/git4idea/backend/src/branch/GitSmartOperationDialog.java:79-81
JComponent fileBrowser = !changes.isEmpty()
                         ? new ChangesBrowserWithRollback(project, changes)
                         : new GitSimplePathsBrowser(project, paths);
```

`ChangesBrowserWithRollback` 提供：树形/列表切换、双击打开 diff、
选中文件就地回滚（回滚后该文件不再阻塞，可继续操作）。
注意 IDEA 有降级路径——拿不到 `Change` 对象时退回纯路径列表，
说明这个能力是"尽力而为"而非硬依赖。

#### 设计方案

分两个阶段，第一阶段即可显著改善体验。

**阶段 1：点击路径打开 diff**

- 在 `GitCheckoutConflictRequest` / `GitIntegrationConflictRequest` 中保持
  `blockingPaths: [String]` 不变，不改 Rust 层。
- 对话框中把 `Text(path)` 换成 `Button`，点击时调用现有的 diff 打开能力。
  需要接手者确认当前打开 diff 的入口——检索 `DiffReviewView` 的调起方，
  复用同一条路径，不要新建一套。
- 对话框是 `.sheet` 呈现，在 sheet 之上再开 diff 需要验证呈现方式：
  建议先 `dismiss()` 再打开 diff，并把当前请求暂存到
  `GitFeatureModel`，diff 关闭后重新弹回对话框。**这一点需要实现者
  先做交互验证**，如果体验割裂，改为在对话框内嵌一个只读 diff 预览区。

**阶段 2：单文件回滚**

- 在对话框中为每行增加"回滚此文件"操作（需二次确认，此操作不可撤销）。
- 回滚后必须**重新执行 preflight**，而不是简单地从列表里移除该行——
  因为回滚可能使阻塞集合完全清空，此时应直接关闭对话框并继续原操作。
- 复用现有 `service` 中的 revert/checkout 单文件能力；若不存在，
  需在 Rust 层新增 `git checkout -- <path>` 的封装，注意路径需校验。

#### 验收标准

- 冲突对话框中每个文件可点击，能看到该文件"我改了什么"的 diff。
- （阶段 2）回滚单个文件后，若阻塞集合清空，操作自动继续，无需用户重新触发。
- 纯路径降级路径保留：拿不到 diff 信息时不崩溃，退回当前的纯文本展示。

---

### 开发项 B：暂存恢复冲突走完整的冲突解决流程

**优先级：高**（当前是明确的死路）

#### 现状

Smart Checkout 的恢复冲突已能**识别**，但只是报错了事：

```rust
// rust/lithe-core/src/git.rs:1622-1629
// `git stash pop` exits 0 but keeps the entry when the restore conflicts, so confirm
// the entry is actually gone before reporting success.
if auto_stash_entry_exists(root)? {
    return Ok(failed_git_result(format!(
        "{}\nThe stashed changes conflict with the checked out branch and were kept in the stash.",
        restored.output.trim_end()
    )));
}
```

merge/rebase 路径同样：

```swift
// Sources/Lithe/Application/GitFeatureModel.swift（resolveIntegrationConflict 尾部）
if !restored.succeeded {
    notify?("Restoring your changes failed: \(trimmedMessage(restored))")
}
```

用户看到一句 toast，然后就卡住了——不知道哪些文件冲突、下一步该做什么、
自己的改动还在不在。**改动其实安全地躺在 stash 里，但用户不知道。**

#### IDEA 对照

IDEA 拉起完整的冲突解决器，并且做了一个关键处理——**把合并编辑器的
左右两栏对调**：

```kotlin
// plugins/git4idea/backend/src/util/GitPreservingProcess.kt:130-132
val params =
  GitConflictResolver.Params(project).setReverse(true).setMergeDialogCustomizer(mergeDialogCustomizer)
    .setErrorNotificationTitle(GitBundle.message("preserving.process.local.changes.not.restored.error.title"))
```

`setReverse(true)` 的原因：正常 merge 时"当前分支"在左、"传入内容"在右；
但恢复 stash 时，"传入的"其实是用户自己的改动，角色反了。若不调换，
用户会把自己的代码误认成别人的。

IDEA 还有专门的通知文案（`GitBundle.properties:449-452`）：

```properties
stash.unstash.unresolved.conflict.warning.notification.title=Local changes were restored with conflicts
stash.unstash.unresolved.conflict.warning.notification.message=Your uncommitted changes were saved to stash.<br/>Unstash is not complete...
stash.unstash.unresolved.conflict.warning.notification.show.stash.action=View saved changes…
stash.unstash.unresolved.conflict.warning.notification.resolve.conflicts.action=Resolve conflicts…
```

注意它给了**两个可点击动作**，而不只是一句话。

#### 设计方案

不依赖三方合并编辑器（那是开发项 E），本项只做"把用户从死路里领出来"。

1. **Rust 层**：恢复冲突时，除了报错，还需返回结构化信息——
   冲突文件列表（`git diff --name-only --diff-filter=U`）与 stash 引用。
   建议新增响应字段而非塞进错误文本，保持与第 1 节约束一致。

2. **状态**：`GitFeatureModel` 新增 `@Published var pendingStashRestoreConflict`，
   在 `reset()` 中清空（与现有 `pendingIntegrationConflict` 一致）。

3. **UI**：新增一个持久提示（不是转瞬即逝的 toast），提供三个动作：
   - **查看冲突文件** —— 跳到 Changes 面板并筛出冲突文件
   - **查看已保存的改动** —— 打开 stash 列表，定位到那条 entry
   - **稍后处理** —— 关闭提示，但状态保留

4. **文案要点**（必须让用户确信改动没丢）：
   > 你的本地改动已保存在 stash 中。恢复未完成，工作区存在未解决的冲突。
   > 解决冲突后请手动删除该 stash。

   注意最后一句：Lithe 不会自动 drop stash，必须明确告诉用户，
   否则会留下一条孤儿 stash。

5. **左右栏对调**：本项暂不涉及合并编辑器，但**若将来实现开发项 E，
   必须记得这个 reverse 语义**。已在本文档记录，避免遗漏。

#### 验收标准

- Smart Checkout 恢复冲突后，用户能从界面直接看到是哪些文件冲突。
- 用户能确认自己的改动仍在 stash 中，并能找到它。
- 提示不会因为切换面板而消失。
- 孤儿 stash 有明确的清理指引。

---

### 开发项 C：引入 Shelve（IDE 侧改动保存）

**优先级：中**

#### 现状

Smart Checkout 与 merge/rebase 的自动保存**只有 stash 一种实现**，写死在
Rust 层（`git.rs:1592` `checkout_with_auto_stash`）和 Swift 层
（`GitFeatureModel.resolveIntegrationConflict` 中的 `service.stash(...)`）。

#### IDEA 对照

IDEA 有 `GitSaveChangesPolicy` 枚举，用户可在设置中选择 stash 或 shelve，
且**对话框文案随之变化**：

```properties
# plugins/git4idea/shared/resources/messages/GitBundle.properties:426-429
smart.operation.dialog.north.panel.label.shelf.text=<html>Your local changes to the following files would be overwritten by {0}.<br/> {1} can shelve the changes, {0} and unshelve them after that.</html>
smart.operation.dialog.north.panel.label.stash.text=<html>...can stash the changes, {0} and unstash them after that.</html>
smart.operation.dialog.ok.action.shelf.description=Shelve local changes, {0}, unshelve
smart.operation.dialog.ok.action.stash.description=Stash local changes, {0}, unstash
```

选择通过 `saveMethod.selectBundleMessage(stashText, shelfText)` 分发。

**shelve 的价值**：改动存在 IDE 自己的存储中，不进 Git 对象库。
操作失败不会污染仓库、不会留下孤儿 stash、也不受 `git stash` 各种
边角行为（如 pop 冲突时退出码为 0）的影响。

#### 设计方案

这是三项中改动面最大的一项，建议**在 A、B 完成后再评估是否要做**。

- 需要新增一套 IDE 侧的改动存储：序列化 patch + 元数据，落盘到项目
  配置目录，附带版本号以便未来迁移。
- `GitSaveChangesPolicy` 等价物应放在 Swift 层（属于产品策略，非 Git 语义），
  Rust 层保持只懂 stash。
- 所有当前硬编码 stash 的位置需改为经由策略分发，包括对话框文案——
  参考 IDEA 的 `selectBundleMessage` 模式，**不要**用字符串拼接，
  应准备两套完整文案，否则本地化会退化（本项目已有此教训：
  插值进 Swift `String` 的文本无法进入 strings 表）。

#### 待决策

是否真的需要 shelve？若目标用户主要是单人本地审查场景，stash 的
缺陷（孤儿条目、污染仓库）影响有限。**建议先做 A、B，观察实际使用中
stash 是否真的造成困扰，再决定 C 是否投入。**

---

### 开发项 D：多仓库（monorepo）支持

**优先级：低（取决于目标用户）**

#### 现状

Lithe 全链路是单仓库假设：`gitRepositoryRoot` 是单个 `URL?`。

#### IDEA 对照

IDEA 所有分支操作都基于 `Collection<GitRepository>`，并有完整的跨仓库
回滚协商：

```java
// plugins/git4idea/backend/src/branch/GitBranchOperation.java:194-198
protected final void showFatalErrorDialogWithRollback(...) {
  boolean rollback = myUiHandler.notifyErrorWithRollbackProposal(title, message, getRollbackProposal());
  if (rollback) {
    rollback();
```

即：3 个仓库中 2 个成功、1 个失败时，询问用户是否把已成功的也回滚，
避免仓库间状态不一致。

#### 设计方案

**本项不建议现在做。** 它会渗透进每一层（`gitRepositoryRoot` 的单值假设
遍布 model 层），成本远高于前三项，且只有 monorepo 用户受益。

若确定要做，建议独立立项，先从 `GitFeatureModel` 的仓库标识抽象开始，
而不是在现有冲突处理代码上打补丁。

---

### 开发项 E：三方合并编辑器

**优先级：低（体验缺口，非能力缺口）**

用户当前仍可通过外部工具或手工编辑解决冲突，Lithe 已能正确识别冲突状态、
提供 continue/abort、并阻止带冲突标记的提交。合并编辑器是体验优化。

若将来实现，**务必参考开发项 B 中记录的 `setReverse(true)` 语义**。

---

### 开发项 F：操作期间的文件系统冻结

**优先级：低**

IDEA 有 `GitFreezingProcess`（`GitPreservingProcess.kt:94` 调用），
在 Git 操作期间冻结 IDE 的文件系统同步，避免半路的中间状态被 IDE
其他部分观察到。

Lithe 没有这层保护，理论上文件监听的刷新时序可能与 Git 操作撞上。
**目前没有实测到具体故障**，列在此处备案。若测试中出现"操作过程中
Changes 面板闪烁异常内容"一类问题，从这里入手。

---

## 4. 实施顺序建议

```
A（冲突列表可点开 diff）
    ↓
B（暂存恢复冲突不再是死路）
    ↓
[评估] C 是否需要 shelve
    ↓
D / E / F 独立立项
```

A 和 B 都是**补完已有流程的最后一公里**，不引入新架构，风险低、收益直接。
C 起会引入新的存储或抽象层，建议先让 A、B 上线并收集反馈。

---

## 5. 给接手者的注意事项

1. **不要匹配 Git 的自然语言输出**，理由见第 1 节。若发现现有代码
   有此类匹配，视为缺陷上报。

2. **新增操作类型必须实测 Git 行为**，不要从 merge/rebase 的规则外推。
   第 2.1 节的表格每一行都是跑出来的，不是推出来的。

3. **本地化**：插值进 Swift `String` 的文本不会进入 strings 表。
   需要翻译的文案必须走 `Text` 插值、`LocalizedStringKey` 或
   `NSLocalizedString`。给译者的应当是完整句子，不是碎片。
   现有 `notify?()` toast 存在此问题（插值文本无法作为 key 解析），
   属于既有技术债，新代码不要沿用该模式。

4. **stash 相关的两个坑**（已在现有代码中处理，改动时勿破坏）：
   - `git stash pop` 恢复冲突时**退出码仍为 0**，必须重读 `git stash list` 确认；
   - 不要假设自己的 stash 是 `stash@{0}`，操作本身可能产生新条目，
     必须按 message 查找。

5. **架构边界**由 `scripts/verify-service-boundaries.sh` 强制，
   Rust 核心由 `scripts/verify-rust-core.sh` 校验。两个脚本是
   `#!/bin/zsh`，用 bash 跑会报"未绑定的变量"。提交前都要跑。

6. **当前代码状态**：见第 6 节。

---

## 6. 已完成部分的代码状态

### 6.1 分支与提交

分支 `feat/git-conflict-handling`，基线 `2a4ad6f`，三个提交：

| 提交 | 层 | 内容 | 规模 |
|---|---|---|---|
| `7ba64ef` | Rust 核心 | 五个新命令 + smart checkout 写路径 | 5 文件 / +1535 |
| `f89aac4` | 桥接与服务 | 命令上抛至 `GitService`，新增模型类型 | 7 文件 / +457 |
| `740d7a1` | 应用与界面 | 三个对话框、进行中横幅、提交拦截、中文文案 | 7 文件 / +732 |

**按分层切分而非按功能切分**，原因如下——接手者若想重排提交，需先了解：

这五个功能（Smart Checkout、进行中检测、pull 策略、merge/rebase 预检、
cherry-pick/revert 预检）是迭代开发的，在同一批函数里互相交织：
`write()` 同时处理 pull 策略与 checkout autostash；`reset()` 一次清空所有
pending 状态；`GitLogView.swift` 中三个对话框位于**同一个 hunk**。
按功能垂直切分需要拆开单个 hunk，收益不足以抵消风险。

**三个提交均已验证可独立编译**（逐个 checkout 后 `swift build` 零错误），
因此二分查找（`git bisect`）可用。

### 6.2 一处跨层耦合

`GitChange` 新增 `.conflicted` 枚举值会使三处 `switch` 不再穷尽
（`ChangesSidebarView`、`DiffReviewView`、`GitCommitDiffReviewView`）。
这三行一行改动被**刻意放在 `f89aac4`**（模型层）而非界面层提交，
否则 `f89aac4` 自身无法编译。

若要 cherry-pick 或回退 `f89aac4`，注意它带着这三处视图修改。

### 6.3 验证程度

| 验证项 | 状态 |
|---|---|
| Rust 核心测试 | 32 项通过（驱动 `execute_json` 打真实 Git 仓库） |
| Swift 编译 | 三个提交各自零错误 |
| `verify-service-boundaries.sh` | 通过 |
| `verify-rust-core.sh` | 通过 |
| `plutil -lint` 中文文案 | 通过 |
| **应用打包运行** | **从未执行** |
| **UI 实际行为** | **未经人工验证** |

> 界面层（`740d7a1`）的所有交互——对话框弹出时机、横幅显示、
> toast 文案、sheet 呈现——**均未在运行中的应用里验证过**。
> 已知产品决策为交由专职测试人员手工测试。

### 6.4 未纳入提交的内容

工作区中以下未跟踪目录**未提交**，切分支前请确认是否需要处理：

- `.claude/` — 工具配置
- `assets/` — 未跟踪资源

另注意 stash 列表中存在一条**属于其他分支**的条目
（`codex/windows-parity-implementation`），与本次工作无关，请勿误删。

### 6.5 切分支提示

三个提交是线性的、各自可编译的，因此：

- 想只要核心能力不要 UI：取到 `f89aac4` 即可，界面层可另行实现
- 想整体挪到别的分支：`git cherry-pick 7ba64ef^..740d7a1`
- 想继续开发项 A/B：直接基于 `740d7a1` 建分支

