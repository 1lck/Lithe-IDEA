# AI 提交信息：实现与配置说明

AI 生成提交信息的配置可以手动管理多个服务商，也可以识别本机 Codex 和 Claude 的 API 配置。生成结果先写入提交框，检查后再执行提交。

架构取舍见[设计文档](../../.agents/notes/implemented/feature/2026-09-22-windows-ai-commit-design.md)，字段与接口见[共享契约](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/ai-commit.md)。本篇记录代码接线和验证方法，不复制架构决策。

## 实现位置

| 代码 | 职责 |
| --- | --- |
| Core 仓库的 [`rust/crates/ai`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/ai) | 解析 Codex TOML / Claude JSON 配置（凭据不序列化）、提示词、字符预算、三种协议的请求与响应 |
| `desktop/internal/ai/configuration.go` | Core 解析结果的 Go 类型；协议为 `responses`、`chatCompletions` 或 `anthropicMessages`，认证方式为 `bearer` 或 `apiKey` |
| `desktop/internal/ai/provider.go` | 发现本机 Codex 和 Claude 配置（来源为 `codex`、`claude`）、读取配置文件、按来源解析凭据 |
| `desktop/internal/ai/commit.go` | 提交上下文收集、提交选项（标题格式、长度、Diff 字符上限）、响应解码 |
| `desktop/internal/ai/http.go` | HTTP 请求构造，Anthropic 协议附带 `anthropic-version` 头 |
| `desktop/internal/workbench/ai_generation.go`、`desktop/internal/settingswindow/ai_generation_view.go` | 生成流程与设置界面 |

## 使用方式

1. 在设置中打开 AI 提交配置，添加服务商，填写 API 地址、模型和 API 协议。协议须与服务商支持的接口一致。
2. 填写密钥。密钥交由平台凭据后端保存，不写入普通设置文件。
3. 选择输出语言、提交格式和推理强度。推理强度选择服务商默认时，请求不会发送该参数。
4. 在 Git 更改中选择文件并生成提交信息，检查生成结果，按需编辑后提交。

手动配置示例仅使用虚构地址：`https://api.example.com/v1`、模型 `example-model`。Responses 请求 `/responses`，Chat Completions 请求 `/chat/completions`，Anthropic 请求 `/v1/messages`；已填写完整接口地址时不会重复拼接。

## 本机配置导入

Codex 来源读取用户目录下的 `.codex/config.toml` 与 `.codex/auth.json`，支持 `CODEX_HOME`、所选 profile、模型、provider 地址、`wire_api`、`env_key`、`experimental_bearer_token` 和 API Key。Claude 来源读取 `.claude/settings.json`、`.claude/.credentials.json` 与 `.claude.json`，支持 `CLAUDE_CONFIG_DIR` 和相关 ANTHROPIC 环境变量。

导入的地址、模型、协议和凭据只读；修改源配置后可以刷新，实际生成前也会重新读取。Lithe 不修改原文件，也不把导入的密钥复制进设置。

仅安装或登录 Codex/Claude CLI 不保证拥有可直接调用服务商接口的 API 凭据。当前不支持 OAuth 令牌刷新、执行凭据助手或调用 CLI 代理生成；需要认证的服务商缺少 API 密钥时会显示明确提示。

Codex 服务商声明了 `env_key` 时，只使用该变量，缺失或为空不会回退到其他账号。自定义免密服务商不会附带全局 OpenAI 凭据。

## 设置与兼容性

- 提交生成不读取旧的聊天、补全和通用 AI 设置中的模型字段，避免旧字段不一致的问题。
- 默认生成英文、Conventional Commits 格式的标题，标题长度上限为 72 字符，Diff 字符上限为 32000，推理强度为服务商默认。标题长度通过提示词控制，不强制截断。
- Chat Completions 的输出上限字段可以是 `max_completion_tokens`，也可以是旧参数 `max_tokens`（配置项 `chatTokenLimitField`）。
- 如果服务商报告输出额度耗尽，界面提示用户，不把截断的内容写入提交框。

## 验证

- 单元测试：`scripts/desktop/desktop-go.sh test ./internal/ai/...`，覆盖配置解析、提交上下文、协议请求与响应，以及 HTTP 请求构造。
- 设置与生成流程：`scripts/desktop/desktop-go.sh test ./internal/settingswindow/... ./internal/workbench/...`。
- Core 侧的协议与预算测试在 Lithe-core-rust 仓库中运行，参见 Core 仓库的 `AGENTS.md`。

单元测试不访问真实网络，也不读取个人 Codex 或 Claude 文件。真实服务商联调需要用户选定的服务和凭据，并在测试结束后移除测试密钥、临时配置和测试仓库。
