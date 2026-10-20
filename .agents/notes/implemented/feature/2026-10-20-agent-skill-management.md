# Agent 笔记：技能文件管理与原生 Agent 加载边界

状态：已实现

## 先说结论

技能设置按“全局技能 / 项目技能”组织，Codex 和 Claude 作为列表中的来源标签和筛选项。用户可以查看正文、打开文件、定位目录、新建、导入及启停技能；这些操作使用各 Agent 的原生目录和配置，不维护 Lithe 自己的技能副本或启用状态。技能文件出现在列表中，并不代表当前会话已经加载或执行了它。

## 问题

输入框的 `$` 和 `/` 补全只能显示当前会话上报的命令，不能回答技能保存在哪里、属于哪个项目、如何添加配套脚本。直接把文件清单当成会话能力，会误导用户；若另存一份技能或增加只影响 UI 的开关，还会出现页面“已关闭”但原生 Agent 仍然读取文件的情况。

## 决策

### 范围和页面

页面放在设置的 AI 分组，Agents 页提供管理入口。主要分类只分全局和项目；项目默认取打开设置的工作区，可选择其他已打开项目，选择动作不切换工作台或会话。新建和导入默认使用正在查看的分类，并明确选择适用 Agent 和显示实际目标目录。

信息结构参考 PI-Desktop `de57f05aa65b05c93a4113bf5d4db9723884b080` 的 [AgentSkillsPage](https://github.com/vastsa/PI-Desktop/blob/de57f05aa65b05c93a4113bf5d4db9723884b080/apps/desktop/src/components/settings/AgentSkillsPage.tsx) 和 [SkillEditorSheet](https://github.com/vastsa/PI-Desktop/blob/de57f05aa65b05c93a4113bf5d4db9723884b080/apps/desktop/src/components/settings/SkillEditorSheet.tsx)。只参考分类、搜索、紧凑列表与独立编辑面板的交互组织，不复制其代码、样式或状态存储。控件继续使用 Lithe 的设置分段、选择器、搜索框、按钮和菜单。主工作台、标题栏和项目标签不参与此变更。

### 发现事实仍由 Agent 拥有

Codex 复用已安装 CLI 的官方 `skills/list`，以所选工作区发出强制刷新，保留上游范围、启用状态和插件身份。本机 Codex 0.160.0 与固定适配器依赖的上游 rust-v0.156.1 公开协议均提供这些字段；不需要升级适配器，也不创建会话或发送提示词。生命周期复用既有 App Server 短进程及其有界读取、超时和进程树回收。

Claude 固定适配器把 SDK 的 `supportedCommands()` 转成 ACP 命令列表，但缺少可独立查询的完整技能文件路径和范围目录。因此设置页只列出所选项目 `.claude/skills` 和用户配置目录 `skills` 下的文件，并明确显示“目录清单”。用户配置目录服从 `CLAUDE_CONFIG_DIR`，未设置时使用 `~/.claude`。不仿制 Claude 的祖先目录、插件、策略与延迟加载规则；列表 enabled 只表示对应范围的本地配置可见性，不等于原生会话最终可用性。输入框继续仅使用会话实际上报的命令。

原生目录依据 [Codex 技能文档](https://developers.openai.com/codex/skills/) 与 [Claude 技能目录说明](https://code.claude.com/docs/en/skills#choose-where-skills-load)。正确示例：在项目分类为 Codex 创建技能，写到该项目 `.agents/skills/<name>/SKILL.md`。不要把 Claude 项目目录里的文件改名或移动到全局目录来模拟启停。

### 原生启停与配置作用范围

纯操作菜单通过共享呈现器保留设置窗口焦点，避免仍开启的原生开关仅因菜单打开而变灰；详见[共享下拉菜单焦点](../simplification/2026-09-30-macos-shared-dropdown-style.md)。每行用既有原生小开关表示已读取的配置状态，写入完成前保留旧值、显示进度并禁止重复操作；失败保留原状态并明确要求刷新核对。未能解析配置时显示“状态未知”，不能把读取失败当作默认启用。项目切换或页面离开会取消自有请求并拒绝迟到结果，不中断原有 Agent 对话。

Codex 使用官方 [skills/config/write](https://developers.openai.com/codex/app-server) 按 SKILL.md 路径设置 enabled。一次有界 App Server 交换先用所选工作区发现技能，拒绝未知路径，再写配置并强制读取列表验证最终状态。Codex 的此接口写入用户配置，因此项目技能的开关也影响所有使用相同路径的工作区；页面提示这一点，不将项目分类误称为独立项目开关。不直接重写 Codex 的 TOML 或插件文件。

Claude 使用官方 [skillOverrides](https://code.claude.com/docs/en/skills#override-skill-visibility-from-settings) 的 on/off；固定适配器对应的最低 CLI 2.1.280 已包含该能力，上游 CHANGELOG 从 2.1.129 明确支持。全局开关写 CLAUDE_CONFIG_DIR/settings.json，项目开关写所选项目 .claude/settings.local.json，不修改团队共享 settings.json 或 SKILL.md。该原生配置按名称生效，同名技能共享配置，项目及受管配置可以覆盖全局；界面帮助必须解释这些限制。全局行读取用户配置，项目行合并用户、该项目 settings.json、settings.local.json；这只是所列本地配置的视图，不声称复刻受管、祖先或已连接会话状态。name-only 和 user-invocable-only 仍显示开启，用户关闭再开启会明确改为 on；插件技能需使用 Claude 的插件管理，不通过改名搬目录实现开关。

Claude 配置仅合并目标 skillOverrides 键，保留其他 JSON 值与既有权限；无效 JSON、未知枚举、非普通文件、符号链接、超出 1 MiB 的配置均拒绝写入。配置目录内的持久锁文件用非阻塞文件锁串行化 Lithe 实例，写前重新比较原始字节以识别外部修改；临时文件同目录落盘并同步后原子替换，取消或失败回收临时文件。外部编辑器并不共享该锁，字节比较和替换间仍有极短的竞争窗口，不承诺跨所有编辑器的事务。锁与配置由用户目录/所选项目持有，不是可跨 worktree 复用的构建资源，不能写入 app bundle。

开关反馈只说明原生配置已保存。已经加载进会话的内容无法撤回，现有对话应重新连接以刷新命令和技能清单；不自动重连正在执行任务的 Agent。

### 文件写入和异步生命周期

共享 Core 只负责 `agent.skills` 的类型化分派、取消和错误信封；原生发现与文件操作在 `lithe-agent-host`。Swift 的服务桥离开主线程执行，功能模型保存列表和操作状态，视图只消费模型及显式的原生对话框/打开/定位动作。

导入保留完整目录中的脚本、模板和文件权限，源目录只读。名称、YAML 文件头、UTF-8、目录深度、文件数和大小都有边界；拒绝导入中的符号链接和特殊文件，以及通过链接的目标容器。先写随机隐藏暂存目录，再以不覆盖模式发布；已有空目录也算冲突。失败或取消回收暂存目录，不改已有技能。查看正文仅返回有界文本，不执行文件中的命令或指令。

刷新独立查询两个 Agent，单方不可用不遮住另一方结果；同一项目刷新失败保留旧列表，切项目先清除旧数据。请求与写入捕获项目，迟到结果须核对版本；页面离开时取消自有任务。原生探测的取消必须进入已有交换清理路径，初始化卡住时也先终止并回收子进程，再销毁短生命周期的 Tokio 运行时；不能只丢弃读取 future，把子进程回收留给已经退出的事件循环。保存后刷新列表，是否被运行中的会话发现继续由原生 Agent 决定，不停止会话，也不承诺一次导入会让所有 Agent 都可用。

这些文件是用户明确创建或导入的工作资料，不是构建产物、下载缓存或可跨工作树复用资源。它们的生命周期由用户和原生 Agent 管理，写入位置仅为原生用户或所选项目目录；不写应用包、已安装适配器、签名资源或发行目录，不改变代码签名和 Sparkle 增量更新基线。没有新增可复用的构建资源，因此工作树资源清单不登记用户技能。

## 考虑过的备选方案

- **统一扫描并重建完整 Agent 技能目录**：Codex 已有官方接口，另做一套发现会遗漏插件和策略；Claude 的清单不够完整时应明确说明，而不是复制它的整个解析器。
- **沿用 PI-Desktop 的独立启用状态和运行时合并**：PI 自己掌握执行器，Lithe 使用外部原生 Agent，自己的布尔值无法证明对方已停用。启停改为写原生配置，不保留独立开关状态；市场、删除或跨范围移动仍不提供。
- **把所有技能存入 Lithe 数据目录**：会增加原生 CLI 看不到的第二份事实，也让其他工具与 IDE 的结果不一致，因此使用原生技能包目录。

## 后果

用户能够直接分清全局和项目技能，并通过来源标签理解适用 Agent；管理文件不干扰对话。代价是 Claude 设置清单明确不完整，原生 CLI 不可用时 Codex 的发现会显示错误，技能生效时间仍取决于原生会话。

Windows 已能使用共享 Core 与 Host 操作，但设置页面和真实 Windows 文件系统、进程清理尚未验收；功能矩阵保持 partial/pending。组件和受控协议测试不代替真实会话验收。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AgentSkillsFeatureModelTests|AgentSkillsRustBridgeTests|AgentSkillsAppearanceTests|SettingsSidebarLayoutTests|SettingsSearchVocabularyTests'`
- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-agent-host --report .artifacts/test-stability/agent-skills-rust.json`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`

原生布局测试覆盖窄宽页面及深浅主题，检查菜单锚点落在可见宽度内；可通过 `LITHE_AGENT_SKILLS_SCREENSHOTS` 输出审查截图。夹具验证原生发现与目录清单的区别、原生启用状态、Claude 本地配置可见性、作用范围和插件身份；临时项目通过真实 Core 桥验证创建、查看和冲突。受控假 App Server 验证发现只读，启停只执行发现、原生配置写入和读取核对，拒绝未知路径，均不发送创建会话或提示词请求。临时配置验证全局/项目隔离、其他字段及文件权限保留、无效配置、锁冲突、符号链接和取消清理；功能模型验证失败不改值、写入串行和项目切换拒绝旧结果。

## 适用范围

- `rust/lithe-agent-host/src/skills.rs`
- `rust/lithe-agent-host/src/skills/files.rs`
- `rust/lithe-agent-host/src/skills/settings.rs`
- `rust/lithe-core/src/agent/mod.rs`
- `macos/Sources/LitheCoreContracts/Agent/AgentSkills.swift`
- `macos/Sources/Lithe/Application/Features/AgentSkillsFeatureModel.swift`
- `macos/Sources/Lithe/Views/Agent/AgentSkillsSettingsView.swift`
- `macos/Sources/Lithe/Views/Agent/AgentSkillSheets.swift`
- `shared/fixtures/agent/skills-management-v1.json`
