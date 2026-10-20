# Agent 笔记：Windows Agent Markdown、斜杠命令、轮次轨道与逐轮统计

状态：已实现

## 先说结论

第 13 期把 macOS Agent 对话的四项呈现接入 Windows：回复与思考的完整 Markdown、Agent 上报的斜杠命令补全、右侧轮次轨道与悬停预览、每轮回复下方的统计 footer。全部以 macOS 现有实现为参考，不新增 ACP 请求，也不改变 Rust host 的转发格式。

## 问题

第 12 期完成后，计划、思考与模式已经同步，但 Windows 仍与 macOS 有明显差距：

- 回复只做行内 Markdown，表格、标题、列表和代码块的呈现与 macOS 不一致，表格不能单独复制，文件链接不会在编辑器打开到指定行。
- Agent 通过 `available_commands_update` 上报的命令被直接丢弃，用户看不到 `/` 补全。
- 长对话没有轮次导航，只能靠滚动。
- 每轮只有耗时与输入/输出，缺少复制回复、用量胶囊和完成时间。

## 决策

- 复用 Windows 已有共享 `markdown-renderer.tsx`，不为 Agent 另写渲染器。新增 `utils/markdown-links.ts` 复刻 macOS `AgentMarkdownLink`：`http/https/mailto` 为网页，GitHub 主机为 GitHub，其余按文件路径处理并解析 `:行号`、`:行:列` 与 `#L行号`；Windows 盘符优先按路径判断，不会被误认成 URL scheme。
- Agent 回复与思考块都交给同一个渲染器；文件链接通过 `onOpenLink` 回调交给面板在编辑器中打开并定位，网页与 GitHub 链接仍走共享系统打开逻辑。表格悬停提供 MD/HTML 复制，Markdown 复制保留原始表格源文本，HTML 复制生成带对齐属性的表格。
- 命令列表按 macOS 的 `AgentCommand` 语义进入 `AgentConversation.availableCommands`：`/` 列全部命令，`$` 只列技能且仅在 Agent 确实上报技能时打开；`、` 等同 `/`，`¥`/`￥` 等同 `$`。前缀匹配排在前，其次包含匹配；最多 200 条，同名保留第一条。
- 补全只修改草稿，不直接发送：方向键移动高亮，Tab 或 Return 补全为 `/命令 ` 或 `$skill `，已经输入完整命令时 Return 直接发送；Esc 先关闭列表，回复中再次 Esc 才停止。原有的 `@` 文件选择器保持不变，两个列表互斥。
- 轮次轨道只做呈现索引：`agent-transcript-navigation.ts` 按用户消息切分轮次，工具与思考归入前一轮，仅用 Agent 正文生成预览（prompt 前 320 字符、reply 前 640 字符并去除首尾空白）。`IntersectionObserver` 只驱动轨道自身的可见标记，流式文本不会触发主对话重渲染。
- 每轮 footer 固定显示复制回复、用量胶囊（耗时 · token）与完成时间；完整 token 明细放在胶囊的悬停卡片中。`AgentTurnStatistics` 增加墙钟 `completedAt`，耗时仍使用调用方注入的单调时钟。

## 考虑过的备选方案

- 为 Agent 对话单独实现一套 Markdown 渲染：可以完全照抄 macOS 细节，但会与 AI Chat 的渲染分叉，链接、代码高亮和错误块需要长期双份维护。
- 用 `title` 或原生 tooltip 代替悬停卡片：实现更少，但无法容纳 input/output/推理/缓存多行明细，也与 macOS 的用量卡片不一致。
- 让命令补全直接发送命令：少一次按键，但 macOS 明确只填充草稿，由用户确认后发送，避免误触执行。
- 轮次轨道监听滚动事件并逐帧计算位置：能更精确，但流式输出期间会产生高频状态更新，破坏对话列表的渲染稳定性。
- 在第 13 期一并实现会话合计统计与模型调用统计：范围过大；本期只做逐轮 footer，矩阵保持 `partial`。

## 后果

- Agent 回复中的文件链接现在会打开编辑器；相对路径按工作区解析，绝对路径与 `file://` 也能定位行号。
- 命令列表完全由 Agent 上报驱动，未上报时不显示任何 Lithe 内置命令；断连后清空，重连以新进程上报为准。
- 轮次轨道只出现在有用户消息的对话中，搜索过滤时以过滤后的消息重新计算。
- 逐轮统计在失败、取消与断连后仍保留耗时；缺失 usage 时胶囊只显示耗时。会话合计与首字延迟、输出速度仍留待后续期次。

## 验证

- Markdown 链接解析测试显式加入 Windows Agent CI 套件，和 Agent/编辑区测试一起记录逐项计时；不能只在本机运行而遗漏工作流入口。

- `windows/tauri`: `bun run typecheck` 通过；`bun run lint` 通过，仅有既有警告。
- `src/features/agent`、`src/i18n` 与 `src/utils/markdown-links.test.ts` 共 131 条通过，覆盖链接分类、命令触发与按键状态机、命令解析去重、轮次切分与预览截断、footer 复制文本以及原有连接与统计套件。
- 仓库门禁：功能矩阵 `--check`、矩阵变更门禁、`verify-agent-notes.mjs`、`verify-windows-boundaries.ps1` 均通过。
- 真机验收仍需在 Windows 上执行：表格复制到文本编辑器与表格软件、文件链接定位、`/`、`$` 与中文输入法触发、方向键与 Tab、长列表滚动、轮次轨道悬停与跳转、深浅主题与窄宽面板。

## 适用范围

Windows Tauri Agent 对话的 Markdown 呈现、命令补全、轮次导航与逐轮统计。ACP 协议、Rust host、命令执行语义与 macOS 的 `AgentMarkdownMessage`/`AgentCommandCompletion` 未改动；macOS 继续作为交互参考。