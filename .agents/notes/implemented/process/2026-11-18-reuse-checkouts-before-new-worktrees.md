# Agent 笔记：先复用已有检出，再新建工作树

状态：已实现

## 先说结论

每个新检出（仓库的一份工作目录，包括主检出和 Git worktree，即工作树）都要从零编出自己的编译目录，本仓库约 5 GB，Lithe-core-rust（下称 Core）8–16 GB。2026-11-18 开发机磁盘被历史任务留下的检出和编译目录占满，所以改为：能在分支上做就不开工作树，主检出被占用时先复用空闲的已有工作树，都被占用才新建；不得在临时目录里克隆仓库或放编译目录。新建的 Core 工作树复制已有检出的 `rust/target`，再用 `cargo clean --workspace` 只清掉 Core 自己的 crate。

## 问题

2026-11-18 开发机数据卷 926 GB 已用 894 GB，只剩约 6 GB。占用来自三处：

- 后台任务的会话临时目录（`~/.claude/jobs/<任务>/tmp`）共 255 GB。其中 55 个 Cargo 编译目录约 228 GB，全部属于已结束、停止或失败的任务：Core 改动的任务在这里新建 Core 工作树，在里面直接运行 Cargo，每个工作树从零编出 8–16 GB 的 `rust/target`；还有任务把 `CARGO_TARGET_DIR` 指向 `tmp/target`、`tmp/target-1100` 这类目录。
- 这些临时目录里挂着 19 个 Core 工作树，另有 3 个在 Core 仓库的 `.claude/worktrees/` 下。它们对应的 PR 都已合入，提交都已在远端，但没有任务回来清理。
- 本仓库 `.claude/worktrees/` 下的 5 个工作树对应的 PR 都已合入，其中两个各占 27 GB。

问题不在单个编译目录太大，而在每个任务都新开一份，用完不复用，也没有人删。后续任务看不到临时目录里的编译产物，只能再从零编译一次，时间和磁盘都浪费掉。

## 决策

规则写在 `develop-lithe` Skill 第七节“检出与编译缓存复用”，AGENTS.md 只保留提醒。

1. 开始修改前按顺序选检出：主检出空闲就在主检出从最新 `origin/main` 切新分支；主检出不空闲就复用一个空闲的已有工作树，在其中切新分支；都不空闲才在 `.claude/worktrees/` 下新建工作树。本仓库和 Core 都照此执行。
2. “空闲”用两条可以直接检查的条件判定：`git status --porcelain` 没有输出；当前分支是 `main`，或分支的 PR 已合入或已关闭（分离 HEAD 时要求提交已在远端分支上）。正在进行的任务要么有未提交改动，要么在一个 PR 还没合入的分支上，所以不会被判为空闲。选中后立刻切出新分支，让它不再空闲。
3. Claude Code 后台任务只允许在 `.claude/worktrees/` 下修改，跳过主检出这一步，用 `EnterWorktree` 的 `path` 进入空闲的已有工作树，不用 `name` 新建。
4. 不得在系统临时目录或会话临时目录中克隆仓库、创建工作树或放 Cargo 编译目录，不得把 `CARGO_TARGET_DIR` 指向临时目录或另一个检出。验证别的 Rust 工具链、交叉编译目标或文档也用检出自己的编译目录，因为 Cargo 把编译器版本和目标写进产物哈希，不同产物可以并存。
5. 新建的 Core 工作树复制已有 Core 检出的 `rust/target`（`cp -cR`，APFS 克隆），第一次编译前运行 `cargo clean --manifest-path rust/Cargo.toml --workspace`。本仓库的 `.artifacts/desktop` 继续按 2026-11-16 的 Note 复制。
6. 移除工作树只用 `git worktree remove`，不用 `--force`，也不直接删目录；它在有未提交改动时拒绝执行，避免误删别人的工作。

为什么复制 `rust/target` 后必须先清工作区成员：Cargo 按成员在工作区内的相对路径计算哈希，按修改时间判断新旧（`scripts/desktop/build-desktop-core.sh` 的注释记录了同一问题）。复制过来的 Core crate 产物和新工作树的源码对应不上，可能被当成最新的。`cargo clean --workspace` 只删这 52 个 crate，第三方依赖的产物按版本和编译参数寻址，留着可以照常命中。

### 正确做法

- 主检出干净、停在 `main`：`git fetch origin main && git switch -c fix/1234-xxx origin/main`，然后直接编译，`.artifacts/desktop` 原地增量复用。
- 后台任务：先找出 PR 已合入且没有改动的工作树，`EnterWorktree(path: …)` 进入，再从 `origin/main` 切新分支。
- 一定要新建 Core 工作树时：`git worktree add .claude/worktrees/<名字> origin/main`，`cp -cR <已有检出>/rust/target <新工作树>/rust/`，`cargo clean --manifest-path rust/Cargo.toml --workspace`，然后编译。

### 不要这样做

- `git worktree add $CLAUDE_JOB_DIR/tmp/core origin/main`，然后在里面运行 `cargo test`：任务结束后留下一份十几 GB、没人能复用也没人清理的编译目录。
- `CARGO_TARGET_DIR=$CLAUDE_JOB_DIR/tmp/target cargo test`：理由同上。
- 让两个检出共用一个 `CARGO_TARGET_DIR`：交替编译时会把另一个检出的代码当作本检出的产物。

## 考虑过的备选方案

### 继续每个任务新建工作树，另写清理脚本定期删除

隔离最彻底，任务之间互不影响。但每个任务仍要从零编译，时间省不下来；清理脚本要判断哪些检出可以删，判断条件和“空闲”完全一样，却多了一份要维护的脚本。直接复用空闲检出，同时省下编译和清理，因此没有采用。

### 所有检出共用一个全局 `CARGO_TARGET_DIR`

磁盘上只留一份编译目录，看起来最省。但 Cargo 判断工作区成员新旧只看修改时间，两个检出交替编译时会链接另一个检出编出的产物；多个任务同时编译还要抢同一把构建锁，互相等待。构建脚本已经为这个问题加了 built-from 记录，不能把它推广到所有检出，因此没有采用。

### 引入 sccache 之类的内容寻址编译缓存

缓存按内容寻址，跨检出共享是安全的。但它不缓存增量编译，而 Core 编译目录里最大的部分恰好是 Core 自己 crate 的增量和测试产物；还要在每台开发机和 CI 上安装、配置一个新工具。复制编译目录加 `cargo clean --workspace` 已经让第三方依赖全部命中，因此没有采用。

### 完全不用工作树，所有任务都在主检出切分支

最简单，磁盘上永远只有一份编译目录。但并行任务会在同一个检出里互相覆盖未提交的改动，Claude Code 后台任务也不允许在主检出修改，因此只作为第一选择，不作为唯一选择。

## 后果

- 磁盘占用和编译时间随并行任务的峰值数量增长，不再随任务总数增长。2026-11-18 清理已结束任务的编译目录和已合入的工作树后，可用空间从约 6 GB 回到 268 GB。
- 工作树不会自动减少。数量只在并行任务比以往都多时增加；需要释放磁盘时，用 `git worktree remove` 删除空闲的工作树，本地分支保留。
- 两个任务在几乎同一时刻检查同一个空闲工作树，可能都判定它空闲。“选中后立刻切分支”把这个窗口缩到几秒，没有另加锁。
- 复用的工作树里留着上一个任务的忽略文件（编译目录、`.artifacts` 下的报告）。构建脚本的身份检查负责重编，报告由各自的脚本重新生成，不需要手工清理。
- 规则依赖 Agent 按 Skill 执行，没有脚本拦截。出现新的临时目录编译目录或临时目录检出，说明有人没按规则执行，应当直接修正做法，而不是放宽规则。

## 验证

- 2026-11-18 Core 编译目录复制实验（Rust 1.100.0，darwin/arm64）：从 origin/main 新建 Core 工作树，用 `cp -cR` 克隆主检出约 46 GB（`du`）的 `rust/target`，耗时 34 秒，可用空间只减少约 0.07 GB；`cargo clean --workspace` 用 10 秒删除 194,060 个文件，剩下约 14 GB 第三方依赖产物；随后 `cargo build --workspace` 用 23 秒完成，重编的恰好是 `cargo metadata --no-deps` 列出的 52 个工作区成员，没有重编任何第三方 crate。实验工作树随后用 `git worktree remove --force` 删除（它只有被忽略的编译目录，是实验本身产生的）。
- 2026-11-18 清理时逐个检查了 Lithe 和 Core 的工作树：`git status --porcelain` 为空、对应 PR 已合入或提交已在远端的才移除；一个已合入但仍有未提交改动和未推送提交的工作树保留。
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `AGENTS.md`
- `.agents/skills/develop-lithe/SKILL.md`
- `docs/ci-builds.md`
