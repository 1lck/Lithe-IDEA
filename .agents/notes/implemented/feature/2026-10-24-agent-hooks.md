# Agent 笔记：Hook 资源库与原生执行边界

状态：已实现

## 先说结论

用户在 AI > Hooks 中保存一份命令，再选择让 Codex、Claude Code 使用它。
Lithe 管理资源库并显式写入原生配置；何时运行、Shell、标准输入、超时和
命令信任都由原生 Agent 决定。写入成功不代表命令已被批准或执行，
尤其 Codex 仍需在原生 `/hooks` 中确认。

## 问题

通知、格式化等命令需要在 Agent 的特定事件运行。用户分别维护不同配置
容易出错，但在 Lithe 中再建一套命令执行器，会与 CLI 的事件、权限、
取消和会话恢复产生两份事实。修改已有配置还可能误删用户 Hook，或者
把 Codex 的索引信任状态移到另一个命令上。

## 决策

### 配置复用原生能力

交互参考 [Magpie Hook 管理](https://github.com/yetone/magpie/blob/dd1e8822d916f8aeb085db4db93fc3d79e2263ed/internal/library/hooks.go)：
命名、描述、事件、命令、可选超时和 Agent 选择，独立实现，不复制其代码。
首批仅实现两个已有 Agent 的五种共同事件，不给尚未支持的 Agent 放虚假开关。
工具筛选映射到各自的上游工具名，不通过猜测 ACP 显示文本触发命令。

原生语义核对 [Codex 0.160.0 Hook discovery](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/hooks/src/engine/discovery.rs)
与 [Claude Code Hooks](https://code.claude.com/docs/en/hooks)。Codex 写入
`CODEX_HOME/hooks.json`，Claude 写入 `CLAUDE_CONFIG_DIR/settings.json`，
未配置环境变量时沿用原生用户目录。Hook 名称和描述只保存在 Lithe 资源库。
不自动修改禁用 Hook 的用户开关、信任记录或当前对话，也不添加后台同步。

### 编辑器布局

按用户提供的新 Hook 参考页，macOS 与 Windows 编辑器采用左侧标签、右侧
表单的两列布局，标题和底部动作由分隔线独立出来。描述使用较大的多行
输入区，命令保留紧凑的多行代码输入，避免长命令或换行在界面调整中丢失。
创建与编辑分别显示「新 Hook」和「编辑 Hook」，主按钮也区分添加与保存。

Agent 使用带原有品牌标志的选择按钮及「全部」动作，只展示已支持的两个
Agent；全不选时仍由已有校验禁止保存。macOS 复用 MCP 资源库原有的选择
按钮外观，抽为 `AgentSelectionChip`，不再分别维护两套样式。说明继续遵守
macOS 设置的 ⓘ 规则，不复制参考页的控件下方说明段落。描述字段通过共享
文本编辑器显式选择正文字体，其他调用者继续使用原有等宽字体与控件样式。

### 所有权与失败恢复

所有权记录表示 Lithe 在哪个文件、事件、数组位置写入了什么完整条目。
只有该位置仍精确匹配记录，Lithe 才允许更新或移除它。外部编辑过的托管
条目会阻止同步，提示用户恢复或移除原生条目；不猜测删除范围或追加重复命令。
恰好相同的用户自有条目也不自动认领。

Codex 按组和处理器索引标识 Hook。删除后用空处理器组保留位置，新增命令
只追加，保持其他组索引不变，不替用户迁移信任。修改命令也不转移旧信任。
例如先有用户组 A、后有 Lithe 组 B，移除 B 只清空 B 的处理器，不移动 A。
不要把数组压缩当成无害整理：这会让后续组的 trust key 指向不同命令。

资源库先保存用户期望，再对每个目标单独同步。写原生文件前，先在资源库
记录旧、新两种条目的所有权；原生写入成功后才确认新版本。进程在任何
一步中断，下一次显式同步都能根据实际原生字节恢复，不丢失已写条目。
删除失败的 Hook 保留「等待移除」条目。两个目标不是多文件事务，
单项失败继续其他项并显示错误，不把失败目标显示为已同步。

### 存储与平台边界

平台 storage adapter 提供 Application Support 中的 `Lithe/AgentHooks/`；
Windows 使用平台 app-data 根目录下的 `AgentHooks/`。该目录拥有资源库、
写入前所有权日志和空 `.sync.lock`。它们都是用户状态，没有可复用的构建
身份，禁止跨 worktree 复制。读取页面不创建目录；只有显式操作才写入。
共用 instruction 文件 adapter 提供 1 MiB 有界 UTF-8 读取、普通文件校验、
摘要和路径冲突保护、原子替换及暂存清理。非阻塞 OS 文件锁协调多进程。

原生 JSON 的未知字段和已有条目保留语义值，写入时规范化格式；非法 JSON、
重复键或非对象配置拒绝覆盖。原生配置内容可能含密钥，不进入公开快照、
日志或设置页响应。Hook 库本身包含用户命令，不能作为构建产物发布。
运行时不写 bundle 或安装目录，不改变签名与 Sparkle delta 源基线。

Swift 功能模型负责草稿与 UI 状态，Rust Core 负责严格命令分派，Agent Host
负责原生文件。Windows 通过现有 `platform_invoke` 使用同一个共享命令，
不增加平台专属 Hook 执行器。

## 考虑过的备选方案

- 监听 Lithe 的 ACP 事件后自己启动 Shell：无法完整复刻上游工具和信任
  语义，会漏掉 CLI 外的会话或重复执行，因此保留原生执行所有权。
- 直接编辑两份 JSON，不保留资源库：无法共享描述、暂停后恢复命令，
  也无法在部分失败和中断后可靠判断哪些条目归 Lithe 所有。
- 删除组后重新编号并迁移 Codex trust：需要修改另一个敏感配置文件，
  增加跨文件中断窗口，因此使用保留数组位置的空组。

## 后果

用户可以统一管理两个 Agent 的原生 Hook，并明确看到部分失败、待同步和
等待移除状态。代价是 Codex 的原生信任步骤仍需用户完成；空组会保留在
原生配置中，外部编辑过的托管条目需要先在原生文件中处理。Windows
设置页已实现，目标平台运行验收仍须单独完成。

## 验证

- Host Hook 测试使用独立临时目录，覆盖读不创建、事件/筛选/超时、保留
  自有条目、trust 索引不变、只读/符号链接、冲突、部分失败、取消与日志恢复。
- Core `hook_contract_dispatch_is_strict_before_accessing_native_files` 校验
  严格请求；Swift 与 TypeScript 读取同一个跨平台 fixture。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AgentHooks|SettingsSidebarLayoutTests|SettingsSearchVocabularyTests|ContextMenuCoverageTests'`。
- `./scripts/verify-runtime-bundle-immutability.sh`、`./scripts/verify-service-boundaries.sh`、
  `./scripts/verify-shared-contracts.sh`、`./scripts/verify-agent-notes.sh`、
  `./scripts/verify-platform-feature-matrix.sh`。
- `node --test scripts/test-reuse-worktree-resources.mjs`。
- `./scripts/verify-rust-core.sh` 全量通过，含 1,157 项 Core 单元测试、C ABI、
  链接符号和 Git/Swift 桥接；更新后的实际 macOS 开发预览已确认 AI > Hooks 入口。
- 本机隔离用户目录 smoke：Codex 0.160.0 通过原生 `hooks/list` 识别生成
  的配置，初始保持未信任，临时目录中显式设置原生信任后首轮触发
  SessionStart；Claude Code 2.1.310 同样触发 SessionStart，均确认 JSON
  标准输入和会话目录正确。删除后的空组通过 Codex 原生解析。
- 上述流程前后比较已运行预览 bundle 的 1,382 个文件，SHA-256 全部不变；
  临时 CLI 进程树和配置目录已回收，结果保存在本次
  `.artifacts/test-stability/hooks-native-smoke.json`，不发布为构建资源。
- macOS 真实端到端验收：在原生设置页创建、搜索、编辑、停用、重新启用和
  删除 Hook，再用 Codex 0.160.0、Claude Code 2.1.310 以及 Lithe 已安装的
  Codex ACP 1.13.1、Claude ACP 0.81.2 完成真实模型对话和文件修改。
  四条运行路径均实际触发五种事件，Shell/文件编辑筛选、JSON 标准输入和
  工作目录正确；修改只执行新命令，停用与删除后不再执行，重新启用后恢复。
  两种原生客户端的 1 秒超时均终止 3 秒测试命令，模型回合继续正常完成。
- 共 10 个原生 CLI 会话、4 个 ACP 会话，捕获 86 次事件执行。还实际验证
  Claude 改写设置后，页面显示冲突，重新加载并重试恢复同步。ACP、删除与
  超时流程前后的 1,382 个 bundle 文件哈希不变。测试命令、临时凭据副本、
  工作区和进程已清理，保留普通开发预览；结果与脱敏输入样本在本次
  `.artifacts/test-stability/hooks-real-e2e.json` 和
  `.artifacts/test-stability/hooks-real-payload-samples.json`，不提交生成物。
- 本机 51 项 Swift 设置/外观/导航测试及 9 项 Bun 契约/界面测试通过；
  Windows 重新加载请求不会携带仅供写入使用的快照字段，回归测试同时
  确认保存请求仍保留用户看过的资源库与原生文件快照。
  Host 计时 lane 为 231 通过、39 项 opt-in 跳过，其中新增 Hook 用例 14 项。
  Windows 实机运行验收仍待完成，不能用 macOS、配置文件或组件测试替代
  Windows 的运行证据。
- 参考页布局调整后，78 项 Swift 计时测试覆盖编辑器列对齐、多行描述与
  命令输入、MCP 资源库及共享设置控件，中英文深浅色截图已检查；9 项
  前端计时测试与类型检查通过，包含 Agent 全不选禁用保存、全部恢复、
  创建/编辑标题和取消草稿。实际开发预览验证了空白表单、名称初始焦点、
  多行描述、Agent 选择和工具事件筛选；测试草稿取消后未写入原生配置。

## 适用范围

- `rust/lithe-agent-host/src/hooks.rs`
- `rust/lithe-agent-host/src/hooks/storage.rs`
- `rust/lithe-core/src/agent/hooks.rs`
- `macos/Sources/Lithe/Views/Agent/AgentHooksSettingsView.swift`
- `macos/Sources/Lithe/Application/Features/AgentHooksFeatureModel.swift`
- `windows/tauri/src/features/settings/components/tabs/agent-hooks-settings.tsx`
- `shared/fixtures/agent/hooks-management-v1.json`
