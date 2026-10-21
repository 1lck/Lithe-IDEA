# Agent 笔记：全局指令使用原生用户文件

状态：已实现

## 先说结论

macOS 设置的「AI → 指令」可以编辑 Codex、Claude Code 各自的全局指令。保存直接更新原生用户文件，新对话由上游 Agent 加载；Lithe 不额外拼接一份指令，也不改项目规则。页面显示实际路径，保存冲突或失败时保留草稿。

## 问题

Agent 已能继承用户的全局规则，但 Lithe 没有查看和编辑入口。只新增一个文本框并保存到 Lithe 偏好，会让界面显示与 Agent 实际收到的内容不一致；忽略 Codex override 文件，也会出现保存成功却不生效的问题。

## 决策

- 页面沿用设置分组、搜索、共享选择器和原生多行编辑框。Codex、Claude 分别保留内存草稿，切换页面或 Agent 不自动保存。明确选择重新加载并确认放弃草稿后，成功读取才替换草稿。
- 全局指令和技能管理的入口、功能模型、Core 命令分别保留，在同一 AI 分组中并列可用；预览构建必须包含两个功能后再交给用户。全局指令编辑器不负责加载、启停或复制技能。
- 原生文件路径由 Agent Host（负责原生文件和进程的 Rust 适配层）解析，使用 Agent 启动时继承的 `CODEX_HOME`、`CLAUDE_CONFIG_DIR` 或平台用户目录。Codex 选择首个非空的 `AGENTS.override.md` / `AGENTS.md`，Claude 选择 `CLAUDE.md`；不支持的自定义 Agent 不猜路径。
- Core 只分派带类型的请求和稳定错误；Swift 应用模型管理加载、保存、失败和草稿，视图不直接访问文件。原生路径仅作显示和保存校验，不成为跨平台持久标识。
- 保存比较原文件的路径与摘要（字节内容的 SHA-256 标识），防止覆盖读取后发生的外部修改。临时文件在目标目录内创建，写完同步后原子替换；保留已有权限，拒绝覆盖只读文件，Unix 新文件为 `0600`、新目录为 `0700`。同进程保存使用不等待的锁；其他程序不共享锁，检查与替换之间仍存在很小的外部竞争窗口，不声称提供系统级事务。
- 清空 override 后重新按原生规则读取，页面可能回到基础 `AGENTS.md`。正确做法是展示这个实际生效的来源；不要保留一个已被原生跳过的空 override 并声称已清空全部指令。
- 文件只接受至多 1 MiB 的 UTF-8 普通文件，符号链接拒绝编辑。限制用于保护设置页资源；Codex 自身的上下文截断预算仍由原生配置决定，Lithe 不修改它。
- 仅用户点击保存时写用户配置目录；不写发行 bundle、安装目录、代码签名资源或 Sparkle 增量更新基线。不新增下载、缓存或可跨工作树复用的生成资源，因此不注册到工作树资源清单。临时文件由单次保存拥有，成功和失败都清理，异常退出遗留只是一份随机命名临时文件，不会被 Agent 加载。

交互结构参考 [PI-Desktop 的全局指令页](https://github.com/vastsa/PI-Desktop/blob/a6f4ba121e524a167c42466c7b4debbb3cfd0744/apps/desktop/src/features/settings/agent-sections.tsx)：路径、文本编辑和显式保存。没有复制其源码或视觉样式。原生规则依据 [Codex AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md) 和 [Claude Code memory](https://code.claude.com/docs/en/memory)。

## 考虑过的备选方案

### 所有 Agent 共用一个 Lithe 指令副本

这需要维护额外的注入、去重和历史恢复语义，也会和用户 CLI 的全局文件产生两份来源。采用各自的原生文件，代价是用户希望同一规则用于两种 Agent 时需分别保存。

### 保存时停止并重连所有项目

会打断正在进行的任务，且不能撤回已进入模型上下文的旧内容。因此只提示新建对话，不自动停止或篡改现有会话。项目规则优先级继续由上游 Agent 决定，不在页面声称全局指令能覆盖所有规则。

## 后果

用户可以直接管理 CLI 也会读取的全局文件，冲突能保留草稿并显式恢复。代价是符号链接配置需先由用户自行处理，外部编辑不会实时推送到页面，更新也不会改写现有对话。Windows 已可通过共享 Core 调用文件能力，尚无对应设置页和 Windows 实机验证；矩阵保留部分实现、待验证状态。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AgentInstructionsFeatureModelTests|SettingsSidebarLayoutTests|SettingsSearchVocabularyTests|ContextMenuCoverageTests'`。
- Agent Host 计时测试覆盖原生优先级、读取不创建文件、保存和清空、外部修改与路径变化、UTF-8/大小限制、符号链接拒绝、权限保留和临时文件清理。
- Core 的 `global_instruction_contract_dispatches_and_rejects_unknown_agents_without_file_access` 验证共享 fixture 与严格请求边界。
- 隔离临时用户目录，通过同一 Core 命令保存，再捕获真实 Codex CLI 与 Claude CLI 发出的模型请求；Codex 的保存、更新、override 保存、清空 override、清空基础文件，以及 Claude 的保存、更新、清空共八项均确认新增指令出现、旧指令消失。Codex 五项同时确认项目规则继续存在。响应来自本地受控服务，不是在线模型推理；测试进程和临时目录均回收，不修改用户实际配置。
- `./scripts/verify-runtime-bundle-immutability.sh`、`./scripts/verify-service-boundaries.sh`、`./scripts/verify-shared-contracts.sh`、`./scripts/verify-agent-notes.sh`、`./scripts/verify-platform-feature-matrix.sh`。

## 适用范围

- `rust/lithe-agent-host/src/instructions.rs`
- `rust/lithe-core/src/agent/instructions.rs`
- `macos/Sources/Lithe/Application/Features/AgentInstructionsFeatureModel.swift`
- `macos/Sources/Lithe/Views/Agent/AgentInstructionsSettingsView.swift`
- `shared/fixtures/agent/agent-instructions-v1.json`
