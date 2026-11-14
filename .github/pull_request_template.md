<!--
提交前请读完这段注释，它不会显示在最终页面里。

1. 最前面先写关联的 Issue，再选 PR 类型（feat / fix / docs / release 四选一）。
2. 只保留所选类型的“类型专属”小节，删除另外三个。“范围检查”和“验证”保留。
3. 每个检查项都要给出结论，不得为了好看提前全部打勾：
   - 做了：勾选 `[x]`。
   - 整组都不适用：保留小节标题，删掉组内检查项，只写一行 `N/A：原因`。
   - 组内个别项不适用：把 `[ ]` 改成 `[N/A]`，在行尾写原因，不要直接删除。
4. 描述要让 code reviewer 马上看懂改了什么，细小改动也要列出。
5. 默认以 Draft 提交（`gh pr create --draft --body-file`），本地验证通过后再 `gh pr ready`。
   标记 ready 后把修改攒在一起再 push，每次 push 都会重新跑完整 CI。
6. 标题格式：`类型(范围): 摘要`，例如 `feat(plugin-api): …`、`fix(macos): …`、
   `docs(agents): …`、`release: prepare v0.7.0`。
7. 规则以 `.agents/skills/develop-lithe/SKILL.md` 为准，本模板只列检查项，不复制规则细节。
-->

## 关联 Issue / Linked issue

<!--
必填，放在最前面，每行一个。feat 和 fix 必须关联 Issue；docs 和 release 没有就写“无”。
`Closes #123` 表示完成，`Refs #123` 表示相关或只完成了一部分。只做了一部分时，
在下面“不在本 PR 范围内”里写明已完成和未完成的范围。
-->

- Closes #

## PR 类型 / Type

<!--
四选一，标题的类型前缀要与此一致。refactor、perf、test、ci、chore 没有单独类别：
- 用户能观察到的新增或改进（包括性能优化）选 feat。
- 修正错误行为、测试不稳、CI 失败、不改变行为的重构选 fix。没有可复现的缺陷时，
  在“复现与根因”里写“无用户可观察缺陷”和改动动机，并关联对应的 Issue
  （重构关联 `refactor` 标签的 Issue）。
- 只改文档、Agent Note、Skill、入口文件选 docs。
- 稳定版发布准备选 release。
-->

- [ ] feat：新功能或用户可见的改进
- [ ] fix：缺陷修复
- [ ] docs：文档、Agent Note、Skill 等规则文件
- [ ] release：稳定版发布准备

## 改动说明 / What changes

### 背景 / Why

<!-- 解决什么问题，为什么现在做。从用户视角写，先说问题，再说做法。 -->

### 改动 / Changes

<!-- 按功能点逐项列出，哪怕是很小的改动。需要时按文件或模块分组。 -->

-

### 不在本 PR 范围内 / Out of scope

<!-- 没做的部分和后续跟进的 Issue；没有写“无”。 -->

---

## 类型专属：feat

<!-- 选了 feat 才保留本节，否则整节删除。 -->

### 多平台对齐

Lithe 的目标是 macOS 与 Windows 能力对齐。必须选下面一项：

- [ ] **两端都具备**：合入后 macOS 与 Windows 都具备该能力（本 PR 同时实现，或本 PR 补齐另一端）
- [ ] **只实现了 macOS**：已为 Windows 提交跟进 Issue：#
- [ ] **只实现了 Windows**：已为 macOS 提交跟进 Issue：#
- [ ] **刻意只属于某个平台**（功能矩阵中另一端记为 `platform-specific`），理由：

<!--
单平台 feat 必须提交跟进 Issue，不能只在本 PR 里口头说明“以后补”。Issue 用“功能建议”模板，
“目标平台”选未实现的那一端，写清当前缺口和期望行为，流程见 `submit-lithe-issue` Skill。
可共享的逻辑即使只有一端上线，也必须先在 Rust Core 实现并补齐共享契约和 fixture，
不得先写在 Swift 或 TypeScript 里再“以后迁移”（见下方“逻辑归属”）。
-->

## 类型专属：fix

<!-- 选了 fix 才保留本节，否则整节删除。 -->

### 复现与根因

- 复现步骤、实际结果、期望结果：
- 根因（引入该行为的提交或 PR，用 `git log -S` 或 `git blame` 查）：
- 影响平台：

### 检查项

- [ ] 已先写回归测试，确认它在**修复前失败、修复后通过**；测试路径与修复前的失败输出：
- [ ] 无法自动化时，已写明手动复现与验证步骤：
- [ ] 已搜索被修改函数、类型、契约字段的全部调用方（含另一平台、插件、SDK、脚本和按字符串分发的调用）
- [ ] 已检查另一平台是否有同类缺陷（有则本 PR 一并修复，或已提交 Issue）：#
- [ ] 只改了修复所需的代码，没有夹带重构；修复过程中发现的其他问题已提交 Issue：#
- [ ] 修复改变了行为约束或容易复发，已在 `.agents/notes/implemented/bug-fix/` 记录

## 类型专属：docs

<!-- 选了 docs 才保留本节，否则整节删除。 -->

- [ ] 只改文档、Agent Note、Skill、入口文件等，没有产品代码的行为变化（有则改选 feat 或 fix）
- [ ] 长期决策、取舍和约束写在 `.agents/notes/`（中文），`docs/` 只保留操作说明、正式 schema、发布说明和验收材料；改了 Note 已运行 `./scripts/agent-notes/verify-agent-notes.sh`
- [ ] 规则只在真源（Skill、Note）里写一份，入口文件只留指针，没有复制出会漂移的第二份
- [ ] 文中的路径、命令、链接已核对真实存在
- [ ] 涉及插件契约或宿主方法的，已完成下方“插件契约”一组

## 类型专属：release

<!-- 选了 release 才保留本节，否则整节删除。发布规则见 `.agents/skills/release-lithe/SKILL.md`。 -->

- 版本号（`MAJOR.MINOR.PATCH`）：
- 上一个稳定版 tag：

- [ ] `docs/releases/v<version>.md` 已按 `docs/releases/TEMPLATE.md` 写好（中文在前、英文在后），并运行 `node scripts/release/notes/validate-stable-release-notes.mjs docs/releases/v<version>.md`
- [ ] 内容来自上一稳定版到目标 commit 之间的提交、PR、测试和已知限制，没有编造功能、兼容性、下载文件或修复
- [ ] 下载文件名与两个平台的打包工作流产物一致；修改了版本元数据的，两个平台保持一致
- [ ] 贡献者名单已按 GitHub 核验，不按邮箱推断身份
- [ ] 修改了 GitHub Actions 工作流的，已运行 `actionlint`
- [ ] 本 PR 不创建 tag、不触发发布工作流、不编辑线上 Release，这些动作等维护者明确要求后再执行

---

## 范围检查 / Scope checks

<!--
feat 和 fix 必填，docs 和 release 只处理确实涉及的组。每组的触发条件写在标题里，
不满足触发条件的整组写 `N/A：原因`。
-->

### 功能矩阵 / Feature matrix

<!-- 触发：新增宿主的用户可见能力，或改变了宿主的跨平台行为（见 `develop-lithe` 第十节）。具体插件提供的能力不在宿主矩阵建条目，由插件仓库维护。 -->

- [ ] 已更新 `shared/platform-feature-matrix/features/<id>.json`：两端的实现状态和验证状态、证据路径、owner、验证动作都如实填写；没有运行验证的保持 `pending`
- [ ] 已运行 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`；改了平台实现路径的，还运行了 `./scripts/platform-feature-matrix/verify-platform-feature-matrix-change.sh origin/preview HEAD`
- [ ] 没有提交 `.artifacts/` 下生成的矩阵视图
- [ ] 没有更新矩阵的，理由（`matrix-exempt` 标签只能由 reviewer 给已审查、且没有用户可观察变化的重构添加，作者不要自行声明）：

### 插件归属 / Plugin ownership

<!--
触发：任何改动都要检查。插件的代码、测试（包括端到端测试）、功能矩阵、翻译和构建资源说明只在插件仓库；
宿主和 Core 对具体插件零依赖。规则见 `develop-lithe` 第三节“插件归属与宿主零依赖”，违反时审查按 P1 阻塞。
-->

- [ ] 已在仓库根目录运行 `develop-lithe` 第三节“插件归属与宿主零依赖”的自查命令，结果为空
- [ ] 新增或修改的测试只使用测试内联的合成插件、Core 契约 fixture 或插件市场索引快照；没有读取具体插件的插件包、仓库检出、构建产物或清单，没有使用真实插件 ID，没有“缺少插件时跳过”的测试
- [ ] 没有为具体插件提供的能力新建或更新宿主功能矩阵条目；宿主条目的证据和验证动作不引用插件的测试、插件包或插件仓库
- [ ] 插件文案没有写进 `shared/i18n/`；插件的构建步骤、资源路径和补丁没有写进 `scripts/resources/`、`docs/ci-builds.md`、Agent Note 或 Skill
- [ ] 修改了通用扩展点、可能影响已发布插件的，已在受影响插件的仓库运行它的测试，插件仓库与结果：

### 统一日志系统 / Structured logging

<!--
触发：新增或改动了生命周期里程碑、用户操作的终态、功能降级、自动恢复或失败路径。
规则见 `.agents/skills/develop-lithe/references/logging.md` 和固定 Core 修订的 `rust/logging/README.md`。
Windows 目前仍使用 v1 日志，Windows 改动沿用现有写法，并在此注明。
-->

- [ ] 已接入统一日志系统：事件先在固定 Core 修订的 `rust/logging/events/<root>.json` 声明，再用生成的事件类型和 span 记录；没有 `NSLog`、`os_log`/`Logger`、直接写 stderr、`print` 或手写事件 ID
- [ ] 一个操作只有一条终态，错误只在处理它的边界记录一次；高频路径没有用 INFO 逐项输出
- [ ] 没有记录源码、编辑内容、环境变量值、命令输出、凭据；路径用 `path`、错误用 `error` 类型，动态通道段来自已校验的 ID
- [ ] 旧日志生成和使用校验脚本（`scripts/logging/`）已移除，等价检查恢复前在“验证”一节写明日志门禁未完成，不记为通过

### 界面文案 / i18n

<!-- 触发：任何会显示给用户的文字（错误、弹窗、按钮、状态、通知、占位符、提示、无障碍标签、菜单与窗口标题）。 -->

- [ ] 宿主文案都走共享 i18n：在 `shared/i18n/` 补齐中英词条，运行 `node scripts/i18n/generate-i18n.mjs` 并提交生成结果，没有手改生成文件；Viva 代码通过 `desktop/internal/i18n/` 的接口读取
- [ ] 插件提供的文字（清单标题和说明、插件界面、插件后端消息）由插件自己翻译，没有写进 `shared/i18n/`
- [ ] 已运行 `node scripts/i18n/verify-app-language-localization.mjs` 和 `node scripts/i18n/generate-i18n.mjs --check`，没有放宽脚本或扩大豁免名单

### 逻辑归属 / Logic placement

<!-- 触发：新增或修改了任何业务逻辑（见 `develop-lithe` 第三节）。 -->

- [ ] 可共享的逻辑（解析、校验、默认值和“自动”值的解析、状态规则、错误码等）在 Rust Core，并且共享契约和 fixture 先于平台接入；平台层只做原生 I/O 和呈现
- [ ] 修改平台层已有的可共享逻辑时已迁入 Core；本次确有理由不迁的，理由与 `refactor` Issue：
- [ ] 工具或运行时专属的知识放在插件或成熟上游，宿主和 Core 没有按工具名加分支

### 性能与内存 / Performance and memory

<!-- 触发：新增后台功能、子进程、缓存、定时器、依赖，或改动了启动、打开项目、输入、滚动、大文件、长输出、搜索（见 `develop-lithe` 第四节）。 -->

- [ ] 功能、子进程、语言服务器、WebView 首次需要才启动；没有新增空闲轮询；缓存和缓冲有上限；关闭项目、窗口、面板、标签时释放独占资源
- [ ] 主线程没有文件读写、目录遍历、进程启动；跨 C ABI、web view 只传增量或可见窗口
- [ ] 涉及启动、打开项目、输入、滚动、大文件、长输出或搜索的，已附改动前后的性能基线数据；新增运行时或大型依赖的，已写明对启动时间、常驻内存和安装包体积的影响：

### 设置 / Settings

<!-- 触发：新增或修改设置项、设置页、对话框选项或有标题的功能区（见 `develop-lithe` 第五节）。 -->

- [ ] 难以理解的项有 ⓘ；用户可修改的配置在自动、默认、继承时显示为“自动（实际生效值）”，括号里的值来自 Core 返回的同一个解析结果
- [ ] 非敏感的工具配置读取并回显工具的真实来源，用户确认后才写回并回读；打开页面不写文件；敏感字段不明文回显
- [ ] 新增或移动 macOS 设置页的，归属已按设置页分类 Note 确定

### 插件契约 / Plugin contract

<!--
触发：依赖 Rust Core 里插件契约（`shared/plugins/contract/v1/`）、能力版本或插件函数协议的改动，
或新增、修改宿主方法与通知。契约只在 Rust Core，规则见 `AGENTS.md` 的“插件契约只在 Rust Core”。
-->

- [ ] 契约改动已在 Rust Core PR 里随执行它的代码一起提交，同一个 Core PR 已登记插件协议更新记录（合入日期、PR、修改人、协议或 API）；链接：
- [ ] `scripts/desktop/build-desktop-core.sh` 的 `PINNED_CORE_REVISION` 已升到包含该契约的 Core commit，桌面端测试经 `scripts/desktop/desktop-go.sh` 读到的就是这份契约
- [ ] 修改插件后端协议的，已在 Core 仓库运行 `node shared/plugins/scripts/sdk-e2e.mjs`，三个 SDK 示例后端仍能跑通
- [ ] 新增或修改宿主方法、宿主通知的，已在下表逐个列出，原计划编号只用 API-01 到 API-44，不属于任何编号的写 —

| 原计划编号 | 方法 | 用途 |
| --- | --- | --- |
|  |  |  |

### 发行包与资源 / Bundle and resources

<!-- 触发：新增或修改运行时资源、缓存、下载物、解压物、日志或锁文件，或任何下载、解压、生成资源的构建步骤。 -->

- [ ] 运行时不向已安装的 app bundle 或 Windows 安装目录写入；新增的资源路径已说明生命周期、所有权和可写位置，并运行 `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- [ ] 新增或修改宿主自身的下载、解压、生成或缓存资源的，已同步 `scripts/resources/worktree-resources.json`、`scripts/resources/reuse-worktree-resources.mjs` 的校验路由、对应测试和 `docs/ci-builds.md`“独立工作树的本地编译”一节

### 无用代码与重构 / Dead code and refactoring

<!-- 触发：任何代码改动。 -->

- [ ] 本次改动导致变成无用的代码已在本 PR 删除
- [ ] 本次之前就存在的无用代码或可重构之处，已提交带 `refactor` 标签的 Issue，没有在本 PR 顺手处理：#

---

## 验证 / Verification

<!--
列出实际运行过的命令和结果，对应 `develop-lithe` 第十一节的“按改动选择验证”。
当前机器无法执行的平台检查（例如在 macOS 上验证 Windows）必须如实写明，不得声称未执行的检查已经通过。
组件测试通过不等于整机工作流验收通过。界面改动请附截图或录屏（明暗主题、中英文）。
-->

| 命令或操作 | 平台 | 结果 |
| --- | --- | --- |
|  |  |  |

**未能执行的检查和原因：**

## 提交前确认 / Final checks

- [ ] 分支从最新的 `preview` 创建；目标分支：feat、fix、docs 为 `preview`，release 以发布流程要求为准
- [ ] 以 Draft 提交，本地验证通过后才标记 ready
- [ ] 没有无关改动，没有提交 `.build/`、`target/`、`dist/`、`.artifacts/` 等产物，没有凭据、个人路径和未脱敏的日志或截图
- [ ] 本次构建、测试或预览启动的 Lithe 应用和子进程已全部关闭，没有进程残留
