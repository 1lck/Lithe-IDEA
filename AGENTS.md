# Lithe Agent 入口

在仓库中开始任何工作前，先加载并遵循 `.agents/skills/develop-lithe/SKILL.md` 中的 `develop-lithe` Skill。它是 AI 编码和验证规则的唯一真源，也包含 Rust Core 必须遵守的注释规范。

如果任务会创建、迁移、更新、归档或审查 Agent 笔记，或者会把架构决策内容从 `docs/` 移出，开始前还要加载 `.agents/skills/agent-notes/SKILL.md`。Agent 笔记是架构决策和工程取舍的中文真源。

如果任务会创建、修改或审查测试代码、测试基础设施，开始前还要加载 `.agents/skills/write-stable-tests/SKILL.md`。该 Skill 规定 macOS 和 Windows 测试必须遵守的有界等待、确定性时间、资源清理和单测试计时规则。

如果任务会准备、验证或发布 Lithe 稳定版，修改发布说明、版本元数据、标签或发布工作流前，还要加载 `.agents/skills/release-lithe/SKILL.md`。

如果任务涉及通过 Parallels 虚拟机来构建、运行、诊断 Windows 产品，或向 Windows 产品传输文件，开始前还要加载 `.agents/skills/debug-windows-on-parallels/SKILL.md`。

## 测试进程生命周期与清理

除非用户明确要求保留进程运行，否则本次构建、测试、调试、预览或验证启动的任何 Lithe 应用，都必须在任务或测试完成后关闭。清理所有子进程、辅助进程、临时应用实例和相关资源，然后确认没有 Lithe 进程残留，再把结果交还给用户。

重复检查时不要启动重复的 Lithe 实例，也不要让测试构建的应用留在用户的应用列表中。如果某个进程无法正常停止，必须明确报告，并在继续工作前进行有界的尽力清理。

## 特殊 UI 交互

处理可拖动分隔条、可调整面板、连续拖动、滚动或其他高频 UI 交互时，先阅读：

- `.agents/skills/develop-lithe/SKILL.md`
- `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md`

入口文件只保留这条提醒；具体决策原因、正确做法、反例和验证要求以 Agent Note 与 Skill 为准，避免三份规则长期漂移。

## 开发与协作
1. 每次进行功能开发或者 bug 修复都单独从最新的 preview 分支创建新分支，如果有对应的 issue 分支名最好与 issue 编号相关
2. 开发的时候如果涉及到 github 相关的操作麻烦使用 gh CLI 来进行操作而不是使用 Compute rUse 的 Skill。由于沙盒影响可能导致需要反复的 gh 授权，每次需要授权的时候麻烦先申请更高的权限去主环境中查看对应是否有 gh 的Token，如果有就直接复用，这个时候找不到才要求登录 gh
3. 开发完成提交 PR 的时候需要说清楚对应改动的功能点，哪怕是一些细小的改动也是需要包含在内的，需要确保 code reviewer 马上就可以理解这个改动是什么
4. 如果让你修复有关 CI 的流程，记得使用 gh 或者 curl 之类的去查看(优先 gh)而不是使用 Computer Use

## 工作树资源复用与文档维护

- Git worktree 之间不共享各自的 `.artifacts`。单独工作树进行本地编译时，优先
  通过 `scripts/reuse-worktree-resources.mjs --source <已有工作树>` 复用资源，不要
  手工搬运或直接共享整个 `.artifacts`。脚本必须保持源目录只读，通过目标临时
  目录完成校验，并在原子发布后再次校验。
- 新增或修改任何下载、解压、生成或缓存资源时，必须同步更新
  `scripts/worktree-resources.json`、`scripts/reuse-worktree-resources.mjs` 的校验路由、
  对应测试，以及 `docs/ci-builds.md` 的“独立工作树的本地编译”章节。更新内容
  至少包括资源路径、是否允许跨 worktree 复用、版本/平台/架构/工具链身份约束、
  校验来源、复制时机，以及不能共享时的隔离原因。
- PR 中如果增加新的资源目录、下载入口、缓存变量或校验逻辑，必须检查并更新
  资源复用清单和相关验证脚本；不能只把资源加入构建流程而遗漏 worktree 复用
  说明。生成资源没有可靠 identity stamp 时不得注册为可复用资源；可变构建状态
  和 LSP workspace 状态不得跨 worktree 共享。

## 跨平台功能同步

5. 每次新增用户可观察功能，或修改已有功能的跨平台行为时，必须在同一个 PR 中更新 `shared/platform-feature-matrix.json`。必须同时填写 macOS 和 Windows 的状态、证据路径、负责人和验证方式；即使功能只属于一个平台，也要登记为 `platform-specific`，不能省略。
6. 代码入口存在但还没有真实运行验证时，必须标记为 `needs-verification`，不能直接标记为 `implemented`。功能矩阵是功能 PR 的必需同步项，不是可选文档。
7. 矩阵每一行必须对应一个可以单独验收的用户能力或用户动作；`area` 和 `group` 只用于归类，不要把 Git、数据库、编辑器等总模块直接写成一行。
8. 修改矩阵源数据后必须运行 `node scripts/generate-platform-feature-matrix.mjs`，并将生成的 Markdown 和 CSV 视图一并更新；不要直接编辑生成文件。
9. 提交前必须运行 `./scripts/verify-platform-feature-matrix.sh`。若 PR 没有新增或改变用户可观察功能，也应在 PR 描述中说明不需要更新矩阵的原因。
