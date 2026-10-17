# Agent 笔记：删除 Windows 遗留 Codex 原生集成死代码

状态：已实现

## 先说结论

Windows 产品从来没有实现过原生 Codex 集成，但「设置 → 工具 → AI 聊天与编辑」
里一直显示「Codex 集成」区块，并把「后端未实现」显示成「安装 Codex CLI 以使用
此集成」，让已经装好 CLI 的用户以为还要再装一次（issue #1207）。
本次删除这段遗留前端：Codex 集成设置页、Codex 专用调用分支、相关中英文文案，
以及只服务这些调用的 `codex_` 能力判定。

对日常开发的直接影响：不要再为 Windows 补 `get_codex_status`、
`start_codex_integration`、`list_codex_*` 这类 Codex 专用命令；Windows 的 Agent
能力按共享路线走 `rust/lithe-agent-host`，界面各平台自己实现。

## 问题

`windows/tauri/src/features/ai/integrations/` 是 React/Tauri 迁移时带进来的历史
代码，它调用的 `get_codex_status`、`start_codex_integration`、`start_codex_thread`
等命令在 Windows 宿主里从未存在：`windows/tauri/src-tauri/src/main.rs` 没有注册
它们，`platform.rs` 只特判 `ai_commit_*`，其余点号命令透传给 Rust Core，而 Core
只有 `agent.status`、`agent.install` 这类 Agent 管理命令。Qt 时代的 Windows 产品
同样只有 `ai_commit_service`，所以这些命令不是「迁移时漏接」，而是从来没有过。

同时 `backend-capabilities.ts` 把 `agent` 设为不可用，`capabilityForCommand` 会把
`codex_*` 判定成 agent 能力并在 `invoke` 之前直接拒绝。设置页用空 `catch` 吞掉这次
拒绝，`status` 保持为 `null`，于是界面回退到 `codexSettings.installCliDescription`
（安装 Codex CLI 以使用此集成），「连接」按钮也一直是禁用状态。用户看到的是
「CLI 未安装」，真实原因是「这个集成没有后端」。

## 决策

删除这段不可能工作的入口，而不是把它翻译成更好的错误文案：

- 删除 `windows/tauri/src/features/ai/integrations/`（Codex 集成设置页、服务、
  动态工具和类型，以及只包含 Codex 一个条目的集成注册表）。
- AI 设置页不再渲染该区块；`use-agent-options.ts` 不再探测 Codex CLI 状态，
  `ai-chat-service.ts`、`ai-chat.tsx`、`ai-context-builder.ts` 不再保留 Codex
  分支，Agent 列表只由本机 Agent、终端 Agent 和 ACP 注册表组成。
- 删除中英文 `codexSettings.*` 文案与 `tauri-core.ts` 中已无调用方的 `codex_`
  能力判定；`agent` 能力开关继续保持关闭。
- 本机 API Key 供应商、行内编辑、自动补全和供应商设置使用的 provider/HTTP
  代码保持不动，它们在 Windows 上确实可以运行。

## 考虑过的备选方案

- 隔离到 legacy 目录：文件仍参与 typecheck 和前端测试，而且下一位贡献者很容易
  再把它当成可复用的地基；issue #440 已经判定这段代码不作为参考依据。
- 在后端补齐这些 Codex 专用命令：会让 Windows 出现第二套 Agent 栈，与
  [共享 ACP Agent 对话决策](../architecture/2026-09-25-shared-acp-agent-conversation.md)
  冲突——该决策规定 ACP 连接与进程管理只写在 `rust/lithe-agent-host`，
  Mac 与 Windows 只各自实现界面。
- 只把文案改成「待开发」并保留面板：入口仍然承诺一个不存在的集成，清理工作
  只是被推迟，用户依然点不动「连接」。

## 后果

用户不再被引导去重复安装 CLI，Windows 不再展示一个没有后端的集成入口，
仓库消失约 680 行死代码和 65 行 i18n 文案，`codex_` 能力判定也不再是死规则。

代价是如果将来要在 Windows 上提供 Codex 集成，只能走共享 host；本机
API Key 对话之外的 Agent 能力在 Windows 上仍然缺失。`windows/tauri/src/features/ai/`
中的 ACP 前端（`AcpStreamHandler`、`stores/ai-chat/acp-actions.ts` 等）依然是
没有后端的代码，等接入共享 host 时再处理。

## 验证

- `cd windows/tauri && bun run typecheck`。
- `cd windows/tauri && bun test src/features/ai src/platform`。
- `node scripts/verify-agent-notes.mjs`、`node scripts/generate-platform-feature-matrix.mjs --check`。
- 运行时收尾：启动 Windows 产品，打开「设置 → 工具 → AI 聊天与编辑」，
  确认不再出现 Codex 集成区块、CLI 状态和「安装 Codex CLI」提示；打开 Agent
  面板，确认下拉只列出本机 Agent 与终端 Agent，选中后不再出现 Codex 连接错误。
  类型检查和前端测试不能代替这组原生验收。

## 适用范围

- `windows/tauri/src/features/ai/hooks/use-agent-options.ts`
- `windows/tauri/src/features/settings/components/tabs/ai-settings.tsx`
- `windows/tauri/src/platform/tauri-core.ts`
- `windows/tauri/src/features/ai/services/ai-chat-service.ts`
