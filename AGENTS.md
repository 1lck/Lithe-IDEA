# Lithe Agent 入口

在仓库中开始任何工作前，先加载并遵循 `.agents/skills/develop-lithe/SKILL.md` 中的 `develop-lithe` Skill。它是 AI 编码和验证规则的唯一真源，也包含 Rust Core 必须遵守的注释规范。

如果任务会创建、迁移、更新、归档或审查 Agent 笔记，或者会把架构决策内容从 `docs/` 移出，开始前还要加载 `.agents/skills/agent-notes/SKILL.md`。Agent 笔记是架构决策和工程取舍的中文真源。

如果任务会创建、修改或审查测试代码、测试基础设施，开始前还要加载 `.agents/skills/write-stable-tests/SKILL.md`。该 Skill 规定 macOS 和 Windows 测试必须遵守的有界等待、确定性时间、资源清理和单测试计时规则。

如果任务会准备、验证或发布 Lithe 稳定版，修改发布说明、版本元数据、标签或发布工作流前，还要加载 `.agents/skills/release-lithe/SKILL.md`。

如果任务会整理问题报告、提出功能建议、准备 Issue 草稿或提交 GitHub Issue，开始前还要加载 `.agents/skills/submit-lithe-issue/SKILL.md`。该 Skill 规定信息追问、诊断采集与脱敏、查重，以及严格遵循仓库 Issue 模板的提交流程；gh 不支持 YAML 表单时按表单字段逐项生成正文提交，不得提交空白或缺字段的正文，不得伪造表单来源标记。

如果任务涉及通过 Parallels 虚拟机来构建、运行、诊断 Windows 产品，或向 Windows 产品传输文件，开始前还要加载 `.agents/skills/debug-windows-on-parallels/SKILL.md`。

## 测试进程生命周期与清理

除非用户明确要求保留进程运行，否则本次构建、测试、调试、预览或验证启动的任何 Lithe 应用，都必须在任务或测试完成后关闭。清理所有子进程、辅助进程、临时应用实例和相关资源，然后确认没有 Lithe 进程残留，再把结果交还给用户。

重复检查时不要启动重复的 Lithe 实例，也不要让测试构建的应用留在用户的应用列表中。如果某个进程无法正常停止，必须明确报告，并在继续工作前进行有界的尽力清理。

## 已发布程序包的运行时只读边界

已安装或已发布的 macOS app bundle，以及 Windows 安装目录中的打包资源，都是发行基线的一部分，运行时必须视为只读。Sparkle differential update（增量更新）按发布包的精确字节和哈希生成 delta；启动后往 `Contents/Resources`、bundle 内的插件、语言服务器、Eclipse/OSGi 状态、下载解压目录、日志、锁文件或索引写入，都会改变下一次更新所需的源基线，导致增量包校验失败并回退到完整包。

新增或修改运行时资源时，必须遵守以下动作：

- 先区分构建/打包阶段和应用运行阶段。只有构建脚本可以生成或改写 bundle 内资源。
- 运行时缓存、索引、OSGi/Eclipse 状态、下载物、解压物、插件状态、日志和锁文件，必须通过平台存储/缓存 adapter 放到 Caches、Application Support、临时目录或用户工作区；不得从 `Bundle.main.resourceURL`、`resource_dir()` 或安装目录推导可写目标。
- 资源解析器可以从 bundle 读取固定输入，但写入前必须证明目标是平台可写目录；不要用“启动前清理 bundle”修复，因为进程崩溃、权限和并发更新都可能留下不同基线。
- 每个新增资源路径都要在代码或 Agent Note 中说明生命周期、所有权、可写位置、是否会影响代码签名和 Sparkle delta，并为典型启动/工作流增加 bundle 文件清单或哈希不变的验证。
- 代码审查和测试必须运行 `scripts/verify-runtime-bundle-immutability.sh`；macOS 生产路径和 Windows/Tauri 资源解析路径都要覆盖。发现运行时写入发行目录时，先迁移到平台存储 adapter，再继续功能开发。

## 界面文案必须走统一 i18n 接口

任何会显示给用户的文字（错误、警告、弹窗、按钮、状态、通知、占位符、提示、无障碍标签、菜单与窗口标题）
都必须通过共享 i18n 生成，不得在代码里硬编码，也不得绕过接口。词条的唯一来源是 `shared/i18n/`，
规则与操作见 `shared/i18n/README.md`，实现要求见 `develop-lithe` Skill 的“界面文案与 i18n”一节。

- macOS：视图里的字面量交给 SwiftUI（`Text("…")` 等）；视图之外（错误、`NSAlert`、通知、`errorDescription`、
  字符串参数）一律用 `L10n.string("…")`。禁止直接使用 `String(localized:)`、`NSLocalizedString`，
  禁止用 `locale:` 代替语言选择（它只影响数字和日期格式）。
- 新增文案时，同一次改动里在 `shared/i18n/` 补齐中英词条，运行 `node scripts/generate-i18n.mjs`，
  提交生成结果；不要手改 `Localizable.strings` 或 `*.generated.*`。
- 提交前必须运行 `node scripts/verify-app-language-localization.mjs` 和
  `node scripts/generate-i18n.mjs --check`。检查失败时补词条或改用 `L10n`，
  不得通过放宽脚本、扩大豁免名单或跳过检查来通过。
- 上游诊断、用户内容、Agent 返回内容不是界面翻译，不要改写（见 `shared/i18n/README.md`）。

## 特殊 UI 交互

处理可拖动分隔条、可调整面板、连续拖动、滚动或其他高频 UI 交互时，先阅读：

- `.agents/skills/develop-lithe/SKILL.md`
- `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md`

入口文件只保留这条提醒；具体决策原因、正确做法、反例和验证要求以 Agent Note 与 Skill 为准，避免三份规则长期漂移。

## 设置页分类

新增或移动 macOS 设置页前，先阅读
`.agents/notes/implemented/feature/2026-10-15-macos-settings-hierarchy.md`。
它规定每个设置页归属哪个侧栏分组，以及插件带来的设置默认放在哪里；入口文件只保留这条提醒，规则以 Note 为准。

## 设置必须反映工具的真实配置

新增、修改或审查设置时，遵循 `develop-lithe` 的“Source-backed settings”规则，并先阅读
`.agents/notes/implemented/architecture/2026-10-25-settings-native-configuration-editing.md`。
对非敏感配置，默认发现并读取工具的实际来源，回显可编辑的当前值；用户修改并确认后才写回明确的来源，再重新读取显示结果。不要只放默认值占位符、维护不生效的影子配置，或在打开页面时写文件；敏感字段不得明文回显。具体优先级、冲突保护、恢复默认值和验证要求以 Skill 与 Note 为准。

## 开发与协作
1. 每次进行功能开发或者 bug 修复都单独从最新的 preview 分支创建新分支，如果有对应的 issue 分支名最好与 issue 编号相关
2. 开发的时候如果涉及到 github 相关的操作麻烦使用 gh CLI 来进行操作而不是使用 Compute rUse 的 Skill。由于沙盒影响可能导致需要反复的 gh 授权，每次需要授权的时候麻烦先申请更高的权限去主环境中查看对应是否有 gh 的Token，如果有就直接复用，这个时候找不到才要求登录 gh
3. 开发完成提交 PR 的时候需要说清楚对应改动的功能点，哪怕是一些细小的改动也是需要包含在内的，需要确保 code reviewer 马上就可以理解这个改动是什么
4. 如果让你修复有关 CI 的流程，记得使用 gh 或者 curl 之类的去查看(优先 gh)而不是使用 Computer Use
5. 提交 PR 时默认创建 Draft PR（`gh pr create --draft`）。Draft PR 只运行 Linux 检查，不占用 macOS 和 Windows runner。开发完成、本地验证通过、可以评审时，再用 `gh pr ready` 标记为 ready，这时才会运行完整 CI。标记为 ready 之后，把修改攒在一起再 push：每次 push 都会重新运行完整 CI，并取消上一轮还没跑完的 CI。仓库曾因 Actions 用量过高被 GitHub 判定为滥用，所以不要为了看 CI 结果而反复 push；能在本地验证的先在本地验证。

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

### LSP 插件构建入口

新增或修改语言服务器插件前，先阅读
[LSP 插件构建与语言服务器资源归属](.agents/notes/implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md)。
所有 LSP 插件都必须在构建阶段固定来源并校验语言服务器，把完整资源放入插件包后签名；运行时只能从已安装插件发现入口，不能把下载物、解压物或插件状态写入 app bundle、安装目录或跨工作树共享缓存。

## 插件契约的两仓库同步

插件契约在本仓库的 `shared/contracts/plugins/v1/` 定义，和执行它的 Rust Core 一起修改。
公开仓库 [Lithe-IDEA/lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs)
的 `contract/v1/` 保存这个目录的逐字节副本，连同开发指南、教程和两个官方插件后端 SDK（Node、Java）的
源码、发版和端到端测试。插件开发者只看 lithe-plugin-docs 就能开发，不需要克隆本仓库，所以两个仓库的契约
必须保持一致：

- 修改 `shared/contracts/plugins/v1/` 下任何文件（README、schema、fixture）的 PR 合并后，在
  lithe-plugin-docs 运行 `node scripts/contract.mjs sync --revision <合并后的 preview commit>`
  并提交。不要在 lithe-plugin-docs 里直接改副本。
- 契约 README 里指向该目录以外的链接必须写成绝对 URL；`scripts/verify-shared-contracts.sh`
  会拒绝离开该目录的相对链接。
- 面向插件开发者的新说明写进 lithe-plugin-docs，不写进本仓库或 Lithe Store。
- 本仓库不保存 SDK。修改插件后端协议（例如 `rust/lithe-core/src/lsp/interface/plugin_function.rs`）时，
  合并前在 lithe-plugin-docs 运行 `node scripts/sdk-e2e.mjs --source <本仓库路径> --ref <分支>`，确认两个
  SDK 的示例后端仍能跑通。

决策原因、同步工具和被否方案见
[插件契约、SDK 与开发者资料的发布](.agents/notes/implemented/architecture/2026-10-23-plugin-contract-publishing.md)。

## 跨平台功能同步

跨平台功能矩阵的字段、状态语义、更新流程和 CI 例外规则以
`.agents/skills/develop-lithe/SKILL.md` 为准。开始涉及用户可观察功能或跨平台行为时，先读取该 Skill；不要在本文件复制一份会漂移的规则。
