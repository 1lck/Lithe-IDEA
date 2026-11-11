# Agent 笔记：Viva 桌面端不做 Agent 对话，只保留 AI 生成

状态：已实现

## 先说结论

2026-11-12 用户决定 Viva 桌面端不做 Agent 对话。#1799 删除了助手工具窗口、会话与历史、Agent 安装与管理、自定义 Agent，以及 Agents、指令、技能、Hooks、MCP 配置五个设置页；功能矩阵里对应的 38 行改为 `missing`，理由写在 `docs/viva-migration.md` 的“放弃：Agent 对话”。

保留 AI 提交信息生成、编辑器行内 AI 编辑和创建 PR 时的 AI 描述。三者共用的 Codex/Claude provider 发现搬到 `desktop/internal/workbench/ai_provider.go`，只调用 Core 的 `ai.configuration.sources` 和 `ai.configuration.parse`，不再经过 Agent 状态。设置窗口的 AI 分组只剩“生成”和“IDE 连接”两页。

Rust Core 的 Agent 宿主（`lithe-agent-host` 和 C ABI 里的 Agent 入口）以及 `shared/fixtures/agent/`、`shared/fixtures/mcp/` 暂时保留，是否删除另行决定；桌面端不再调用它们。

## 问题

Agent 对话是迁移中剩余最大的一块：旧客户端的历史、订阅登录、附件、工具卡片、计划、用量和 MCP 管理都还没迁，Viva 又没有 WebView，回复只能用简化的 Markdown 视图。半成品面板会让用户以为功能可用，还要维护 ACP 适配器子进程的启动、退出清理和凭据传递。

同时，AI 提交信息和行内编辑依赖原来写在 Agent 代码里的 provider 发现（`agent_provider.go`）和 Agent 设置页里的“生成”选项。删 Agent 时如果连带删掉这些，两个日常在用的功能会失效；如果只删入口、留下代码，又会留下一套没有调用方的会话、权限和历史逻辑。

## 决策

- **删除范围。** 桌面端删除 `desktop/internal/workbench/agent*.go`、`settings_mcp.go`、`desktop/internal/core/agent*.go`、`mcp.go`、`desktop/internal/agentbrand/`、`desktop/internal/mcpconfig/`、`desktop/internal/settingswindow/` 里的 Agent/MCP/技能/Hooks 页面，以及 `desktop/internal/i18n/` 中只给这些界面用的消息。快捷键表删除“新建 Agent 对话”和 Agent 分组。工具窗口布局里原来放助手的位置不再有占位。
- **保留的 provider 发现只走 Core 的配置解析。** `discoverAIProviders` 先向 Core 要该来源的本机配置文件，再把文件文本交给 Core 解析；Go 只按 Core 返回的凭据定位器读取同一份 JSON 文本或进程环境。Key 只在内存里，不写设置、日志或错误信息。Codex `config.toml` 的内联 `experimental_bearer_token` 需要 TOML 路径解析，仍报“不支持”，不为这一条路径在 Go 里再写一份配置解析器。
- **生成选项归 AI 分组的“生成”页。** 原 Agent 设置里的生成来源、输出语言和自定义指令移到 `pageAIGeneration`（`desktop/internal/settingswindow/ai_generation*.go`）；设置文件里的 `aiGeneration` 字段不变，已保存的选择继续生效。设置文件中原有的 `agentContextLimits`、`customAgents` 等 Agent 字段读取时忽略。AI 分组在 `desktop/internal/settingswindow/model.go` 的 `parents` 表里只声明“生成”和“IDE 连接”；以后新增 AI 页面仍只加进这个分组。
- **文案只删桌面端。** `shared/i18n/` 中只被桌面端 Agent 界面用到的 474 条词条直接删除；490 条与旧客户端共享的词条只去掉 `desktop` 平台，词条本身保留给旧客户端历史代码和其他平台。
- **Core 不在这次删除。** Core 的 Agent 代码跟插件、Git 等宿主在同一个仓库，删除需要单独的 Core PR 并提升 `PINNED_CORE_REVISION`；桌面端先停止调用，Core 去留由用户决定。

## 考虑过的备选方案

- **只隐藏助手入口，保留代码**：没有调用方的会话、权限、历史和进程清理代码仍要随 Viva、Core 升级维护，测试也要继续跑，收益为零。
- **连 AI 提交信息和行内编辑一起删**：用户明确要保留这两个功能，它们只需要 provider 发现，不需要 ACP 会话。
- **同一个 PR 删除 Core 的 Agent 宿主**：Core 变更要单独评审和固定 commit，且用户还没决定 Core 是否保留给以后的插件化 Agent；先删桌面端不影响 Core 的去留。

## 后果

- Viva 没有 Agent 对话；需要对话的用户直接使用 Codex/Claude 的命令行或其他客户端。
- 之前装在 `Application Support/Lithe Desktop/agents` 的 ACP 适配器不再被读取，Lithe 也不主动删除它，用户可以手动清理。
- 进程信号测试 `TestCoreChildProcessesKeepGoSignalStack` 原来靠启动 Agent 子进程验证，现在改为多轮 Go 与 Core 的 `git status` 子进程，覆盖的仍是 Core 子进程不破坏 Go 的 `SA_ONSTACK` 信号处理。
- Core 静态库仍包含 Agent 代码，桌面端二进制体积要等 Core 删除后才会下降。

## 验证

- `scripts/desktop/desktop-go.sh build ./...`、`scripts/desktop/desktop-go.sh vet ./internal/... ./cmd/...`：删除后桌面端编译、静态检查通过（在 `desktop/` 下运行）。
- `scripts/desktop/desktop-go.sh test ./internal/workbench/ ./internal/settingswindow/ ./internal/core/ ./internal/shortcuts/ ./internal/i18n/ -count=1`：provider 发现用真实 Core 解析写入的配置文件、凭据定位器、AI 生成选项页、设置侧栏分组与搜索、工具窗口拖放和信号处理回归。
- `node scripts/i18n/generate-i18n.mjs --check`、`node scripts/i18n/verify-app-language-localization.mjs`：删除词条后生成结果一致、界面文案仍全部走 i18n。
- `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`：38 行改为 `missing` 后矩阵校验通过。
- `scripts/agent-notes/verify-agent-notes.sh`：归档旧 Note 后链接与适用范围有效。

## 适用范围

- `desktop/internal/workbench/ai_provider.go`
- `desktop/internal/workbench/ai_provider_test.go`
- `desktop/internal/workbench/ai_generation.go`
- `desktop/internal/settingswindow/ai_generation.go`
- `desktop/internal/settingswindow/ai_generation_view.go`
- `desktop/internal/settingswindow/model.go`
- `desktop/internal/core/ai_configuration.go`
- `desktop/internal/core/signal_guard_darwin_test.go`
- `docs/viva-migration.md`
- `shared/fixtures/ai/cli-configuration-v1.json`
- [删除前的桌面端 Agent 实现（历史版本）](https://github.com/1lck/Lithe-IDEA/tree/e2737bf7b48285a59191943d8af926ab5aa4df4a/desktop/internal/workbench)
