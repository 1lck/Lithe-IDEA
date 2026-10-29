# Agent 笔记：技能文件管理与原生 Agent 加载边界

状态：已实现

## 先说结论

技能设置按“全局技能 / 项目技能”组织，Codex 和 Claude 作为列表中的来源标签和筛选项。用户可以查看正文、打开文件、定位目录、新建、导入及启停技能；这些操作使用各 Agent 的原生目录和配置，不维护 Lithe 自己的技能副本或启用状态。技能文件出现在列表中，并不代表当前会话已经加载或执行了它。

## 问题

输入框的 `$` 和 `/` 补全只能显示当前会话上报的命令，不能回答技能保存在哪里、属于哪个项目、如何添加配套脚本。直接把文件清单当成会话能力，会误导用户；若另存一份技能或增加只影响 UI 的开关，还会出现页面“已关闭”但原生 Agent 仍然读取文件的情况。

## 决策

### 范围和页面

页面放在设置的 AI 分组，Agents 页提供管理入口。主要分类只分全局和项目；项目默认取打开设置的工作区，可选择其他已打开项目，选择动作不切换工作台或会话。新建和导入默认使用正在查看的分类，并明确选择适用 Agent 和显示实际目标目录。

「技能」和「指令」是同一 AI 分组中的两个独立页面，必须同时保留入口与各自的功能模型。新增全局指令编辑器不能替换技能设置；预览多个尚未合并的功能时，需要使用包含两者的工作区构建，不能把切到另一开发分支造成的入口缺失误判为原生技能未加载。

信息结构参考 PI-Desktop `de57f05aa65b05c93a4113bf5d4db9723884b080` 的 [AgentSkillsPage](https://github.com/vastsa/PI-Desktop/blob/de57f05aa65b05c93a4113bf5d4db9723884b080/apps/desktop/src/components/settings/AgentSkillsPage.tsx) 和 [SkillEditorSheet](https://github.com/vastsa/PI-Desktop/blob/de57f05aa65b05c93a4113bf5d4db9723884b080/apps/desktop/src/components/settings/SkillEditorSheet.tsx)。只参考分类、搜索、紧凑列表与独立编辑面板的交互组织，不复制其代码、样式或状态存储。控件继续使用 Lithe 的设置分段、选择器、搜索框、按钮和菜单。主工作台、标题栏和项目标签不参与此变更。

### 发现事实仍由 Agent 拥有

Codex 复用已安装 CLI 的官方 `skills/list`，以所选工作区发出强制刷新，保留上游范围、启用状态和插件身份。本机 Codex 0.160.0 与固定适配器依赖的上游 rust-v0.156.1 公开协议均提供这些字段；不需要升级适配器，也不创建会话或发送提示词。生命周期复用既有 App Server 短进程及其有界读取、超时和进程树回收。

Claude 固定适配器把 SDK 的 `supportedCommands()` 转成 ACP 命令列表，但缺少可独立查询的完整技能文件路径和范围目录。因此设置页只列出所选项目 `.claude/skills` 和用户配置目录 `skills` 下的文件，并明确显示“目录清单”。用户配置目录服从 `CLAUDE_CONFIG_DIR`，未设置时使用 `~/.claude`。不仿制 Claude 的祖先目录、插件、策略与延迟加载规则；列表 enabled 只表示对应范围的本地配置可见性，不等于原生会话最终可用性。输入框继续仅使用会话实际上报的命令。

原生目录依据 [Codex 技能文档](https://developers.openai.com/codex/skills/) 与 [Claude 技能目录说明](https://code.claude.com/docs/en/skills#choose-where-skills-load)。正确示例：在项目分类为 Codex 创建技能，写到该项目 `.agents/skills/<name>/SKILL.md`。不要把 Claude 项目目录里的文件改名或移动到全局目录来模拟启停。

### 原生启停与配置作用范围

纯操作菜单通过共享呈现器保留设置窗口焦点，避免仍开启的原生开关仅因菜单打开而变灰；详见[共享下拉菜单焦点](../simplification/2026-09-30-macos-shared-dropdown-style.md)。每行使用既有原生小开关。点击后立即显示用户选择的状态，后台写入并回读原生配置，不在开关旁增加加载转圈。仅等待确认的技能行禁止重复操作，其他技能保留原生开关的启用状态和颜色；点击其他行时立即显示其选择，并按点击顺序串行执行原生写入与回读，不能并发交换整份清单而覆盖较新的确认。单行失败回滚该行，后续已排队的操作继续执行，错误保留至下一批操作；项目切换或页面离开同时清除未执行队列。不要用页面级忙碌状态禁用全部开关，否则关闭一个技能会让所有仍开启的技能也变灰，误导用户以为它们一起被关闭。用户选择暂存在功能模型，不能提前替换已确认的原生清单或显示“已保存”。确认成功后采用回读结果；失败恢复已确认状态并显示错误，提示刷新核对。未能解析配置时显示“状态未知”，不能把读取失败当作默认启用。项目切换或页面离开会清除临时选择、取消自有请求并拒绝迟到结果，不中断原有 Agent 对话。

Codex 使用官方 [skills/config/write](https://developers.openai.com/codex/app-server) 按 SKILL.md 路径设置 enabled。一次有界 App Server 交换先用所选工作区发现技能，拒绝未知路径，再写配置并强制读取列表验证最终状态。Codex 的此接口写入用户配置，因此项目技能的开关也影响所有使用相同路径的工作区；页面提示这一点，不将项目分类误称为独立项目开关。不直接重写 Codex 的 TOML 或插件文件。

Claude 使用官方 [skillOverrides](https://code.claude.com/docs/en/skills#override-skill-visibility-from-settings) 的 on/off；固定适配器对应的最低 CLI 2.1.280 已包含该能力，上游 CHANGELOG 从 2.1.129 明确支持。全局开关写 CLAUDE_CONFIG_DIR/settings.json，项目开关写所选项目 .claude/settings.local.json，不修改团队共享 settings.json 或 SKILL.md。该原生配置按名称生效，同名技能共享配置，项目及受管配置可以覆盖全局；界面帮助必须解释这些限制。全局行读取用户配置，项目行合并用户、该项目 settings.json、settings.local.json；这只是所列本地配置的视图，不声称复刻受管、祖先或已连接会话状态。name-only 和 user-invocable-only 仍显示开启，用户关闭再开启会明确改为 on；插件技能需使用 Claude 的插件管理，不通过改名搬目录实现开关。

Claude 配置仅合并目标 skillOverrides 键，保留其他 JSON 值与既有权限；无效 JSON、未知枚举、非普通文件、符号链接、超出 1 MiB 的配置均拒绝写入。配置目录内的持久锁文件用非阻塞文件锁串行化 Lithe 实例，写前重新比较原始字节以识别外部修改；临时文件同目录落盘并同步后原子替换，取消或失败回收临时文件。外部编辑器并不共享该锁，字节比较和替换间仍有极短的竞争窗口，不承诺跨所有编辑器的事务。锁与配置由用户目录/所选项目持有，不是可跨 worktree 复用的构建资源，不能写入 app bundle。

开关反馈只说明原生配置已保存。成功提示始终预留文字所需的布局空间，仅在原生确认后可见；开始下一次保存时隐藏文字但保留空间，同时从辅助功能树隐藏。不要按保存状态插入或删除整行提示，否则首次保存及连续切换都会让下方技能列表上下跳动。已经加载进会话的内容无法撤回，现有对话应重新连接以刷新命令和技能清单；不自动重连正在执行任务的 Agent。

### 文件写入和异步生命周期

共享 Core 只负责 `agent.skills` 的类型化分派、取消和错误信封；原生发现与文件操作在 `lithe-agent-host`。Swift 的服务桥离开主线程执行，功能模型保存列表和操作状态，视图只消费模型及显式的原生对话框/打开/定位动作。

技能服务与指令服务共用 `RustCoreCancellation`：进入服务和启动后台工作前检查取消，Core 同步发出 `requestStarted` 后补传更早的取消，再分派文件操作。只在取消处理器中发一次 `core.cancel` 不够，因为尚未注册的操作会返回未找到，独立后台任务随后仍可能创建、导入或改配置。功能模型在调用写入服务前也检查取消；安装进度继续通过同一事件回调转发，注册事件不被误当成进度。`AgentSkillsCancellationTests` 在 MainActor 不让出执行权即取消真实桥接任务，并在编码边界触发取消，验证独立项目的技能目录、原生配置和暂存状态均不变，后续合法操作仍能成功。

导入保留完整目录中的脚本、模板和文件权限，源目录只读。名称、YAML 文件头、UTF-8、目录深度、文件数和大小都有边界；拒绝导入中的符号链接和特殊文件，以及通过链接的目标容器。先写随机隐藏暂存目录，再以不覆盖模式发布；已有空目录也算冲突。失败或取消回收暂存目录，不改已有技能。查看正文仅返回有界文本，不执行文件中的命令或指令。

最终发布必须由操作系统原子地拒绝已有目标，不能只在准备暂存前检查目录是否存在。
macOS 使用 `RENAME_EXCL`，Linux 使用 `RENAME_NOREPLACE`；Windows 使用
`windows-sys` 的 `MoveFileExW`，只启用 `MOVEFILE_WRITE_THROUGH`，不启用替换和跨卷复制。
UTF-16 路径保留 Unicode、空格和长路径前缀，内嵌 NUL 拒绝传入原生 API。
不能把 Windows 的 `std::fs::rename` 当成不覆盖操作：[Rust 官方文档](https://doc.rust-lang.org/std/fs/fn.rename.html)
说明支持 `FileRenameInfoEx` 的文件系统可替换已有空目录，而
[MoveFileExW 文档](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
提供显式控制替换的标志。Windows CI 曾在这个边界实际覆盖空目标，故回归必须保留失败
断言；正确做法是让最后一次移动失败并保留源包和已有目标，不是增加另一次易竞争的存在检查。
未实现排他发布的平台直接拒绝，不退回可能覆盖目标的普通重命名。

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
- Windows 在原生 CI 中运行相同 Host 测试，覆盖暂存后出现的空目录、普通文件和非空目录都不覆盖，缺失的 Unicode 目标完整发布，以及 NUL 路径不按截断名称发布。这些文件系统用例不等于 Windows 设置页或真实 Agent 会话验收。
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

原生布局测试覆盖窄宽页面及深浅主题，检查菜单锚点落在可见宽度内；开关测试分别阻塞两次原生写入，对比首次点击前、关闭保存中、关闭确认后、再次开启保存中和开启确认后的全部原生开关位置，确保提示变化不移动技能行。可通过 `LITHE_AGENT_SKILLS_SCREENSHOTS` 输出审查截图。夹具验证原生发现与目录清单的区别、原生启用状态、Claude 本地配置可见性、作用范围和插件身份；临时项目通过真实 Core 桥验证创建、查看和冲突。受控假 App Server 验证发现只读，启停只执行发现、原生配置写入和读取核对，拒绝未知路径，均不发送创建会话或提示词请求。临时配置验证全局/项目隔离、其他字段及文件权限保留、无效配置、锁冲突、符号链接和取消清理；功能模型验证点击立即反馈但不提前报告已保存、失败回滚到已确认状态、写入串行和项目切换拒绝旧结果；原生控件回归验证保存期间当前开关立即关闭且不增加加载转圈，其他开启行的原生状态、交互能力与像素外观不变；功能模型控制两次写入的释放次序，验证同一 Agent 的连续保存不丢确认、单项失败后队列继续、重复点击去重，以及切项目/退出时未执行请求不再启动。窗口失去焦点时保留 macOS 原生非活动外观，滑块位置和实际原生配置不随窗口焦点变化。

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
