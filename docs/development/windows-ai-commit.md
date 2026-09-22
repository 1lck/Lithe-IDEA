# Windows AI 提交信息：实现与配置说明

Windows 现已提供独立的“AI 与提交”配置，可手动管理多个服务商，也可识别本机 Codex 和 Claude 的 API 配置。生成结果先写入提交框，检查后再执行提交。

架构取舍见[设计文档](../../.agents/notes/implemented/feature/2026-09-22-windows-ai-commit-design.md)，字段与接口见[共享契约](../../shared/contracts/ai-commit.md)。本篇记录代码接线、使用方式和验证方法，不复制架构决策。

## 如何使用

1. 打开设置 → **AI 与提交**，或点击 Git 提交区域的设置按钮。
2. 点击**添加服务商**，填写名称、API 地址、模型和 API 协议。API 协议须与服务商支持的接口一致。
3. 填写密钥并点击**保存密钥**。普通设置会自动保存；数字字段在失去焦点或按 Enter 时校验并保存，避免输入中途被强制改写。密钥另存于 Windows 凭据管理器。
4. 选择输出语言、格式、推理强度、正文与长度配置。选择**自定义**格式后可以保存提示词，例如：“标题使用中文，以项目工单编号开头，仅描述 diff 能证明的改动。”
5. 在 Git 更改列表中勾选同一仓库的文件，点击 **AI**。已有提交草稿时会提示是否替换；也可在生成过程中取消。
6. 检查生成结果，按需编辑，然后点击提交。

手动配置示例仅使用虚构地址：`https://api.example.com/v1`、模型 `example-model`。Responses 会请求 `/responses`，Chat Completions 会请求 `/chat/completions`，Anthropic 会请求 `/v1/messages`；已填写完整接口地址时不会重复拼接。

## 本机配置导入

进入页面会自动识别，点击**重新加载识别**可刷新。

| 来源 | 默认位置与支持内容 |
| --- | --- |
| Codex | 用户目录 `.codex/config.toml`、`.codex/auth.json`；支持 `CODEX_HOME`、所选 profile、模型、provider 地址、wire_api、env_key、API Key |
| Claude | 用户目录 `.claude/settings.json`、`.claude/.credentials.json`、`.claude.json`；支持 `CLAUDE_CONFIG_DIR`、相关 ANTHROPIC 环境变量、常用模型别名 |

点击卡片中的导入按钮后，配置会出现在服务商列表。导入配置的地址、模型、协议和凭据只读；修改源配置后可刷新，实际生成前也会重新读取。Lithe 不修改原文件，不将导入密钥复制进设置。

仅安装或登录 Codex/Claude CLI 不保证拥有可直接调用服务商接口的 API 凭据。当前不支持 OAuth 令牌刷新、执行凭据助手或调用 CLI 代理生成；没有 API 密钥时会显示明确提示。

环境变量来自 Lithe 进程继承的环境，系统环境设置改变后通常需要重启 Lithe 才能看到。HTTP 地址默认禁止，使用可信本机服务时可勾选服务商的 HTTP 选项。

## 设置与兼容性

新设置保存在 `aiCommit` 中。旧的聊天、补全和通用 AI 设置保留，不自动迁移其密钥；使用此功能时选择本机导入或新建服务商。提交生成不再读取 `aiModelId` / `aiCustomModelId`，避免旧 Custom 字段不一致问题。

默认采用英文、Conventional Commits、低推理强度、不生成正文、标题 72 字符、Diff 32000 字符。推理强度取决于服务商和模型的支持范围；Anthropic Messages 当前不发送此选项。标题长度通过提示词控制，不强制截断标题。

Windows 按勾选文件的工作区内容生成，包括该文件尚未暂存的更改；这与 Windows 实际提交的范围一致。macOS 以暂存区为输入，两端差异是有意保留的产品行为。

本次不新增 PR 描述生成入口或无效的 PR 模板配置，也不改变实际 Git 提交与推送行为。

## 实现位置

| 代码 | 职责 |
| --- | --- |
| `rust/lithe-core/src/ai/configuration.rs` | Codex TOML / Claude JSON 解析，凭据不序列化 |
| `rust/lithe-core/src/ai/generation.rs` | 配置校验、提示词、字符预算、三种协议请求与响应 |
| `windows/tauri/src-tauri/src/ai_commit.rs` | 有界文件读取、凭据管理器、HTTP、超时与取消 |
| `windows/tauri/src-tauri/src/platform.rs` | 统一前后端命令入口 |
| `windows/tauri/src/features/git/types/ai-commit.ts` | 设置类型、默认值、持久化字段白名单 |
| `windows/tauri/src/features/settings/components/ai-commit-settings-panel.tsx` | 服务商管理、导入、密钥与生成规则界面 |
| `windows/tauri/src/features/git/services/ai-commit-context.ts` | 勾选路径读取、并发限制、内容指纹 |
| `windows/tauri/src/features/git/services/ai-commit-service.ts` | 平台调用与错误翻译 |
| `windows/tauri/src/features/git/services/ai-commit-workflow.ts` | 草稿替换确认、过期结果和输入保护 |
| `windows/tauri/src/features/git/components/git-commit-panel.tsx` | AI、取消和设置入口 |

## 回归验证

自动测试覆盖多服务商配置归一化、旧设置默认值、凭据字段剔除、Codex profile/env_key、Claude 模型别名、三种响应解析、Unicode 截断、敏感路径拒绝、空响应、草稿确认、工作区变化、同名文件内容变化和取消。

运行命令：

```powershell
./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/git/services/ai-commit-workflow.test.ts,src/features/git/services/ai-commit-context.test.ts,src/features/git/types/ai-commit.test.ts
cargo test --manifest-path rust/lithe-core/Cargo.toml ai::tests --lib
./scripts/build-windows.ps1 -Configuration Release
cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
node scripts/verify-agent-notes.mjs
```

计时报告写入 `.artifacts/test-stability/`。真实服务商联调需使用用户选定的服务和凭据，单元测试不会访问真实网络，也不会读取个人 Codex/Claude 文件。

## 本次验证记录（2026-09-22）

- 前端定向计时测试：23 项通过，包含提交流程、差异收集、设置归一化及原设置回归；最慢相关用例为截断外内容指纹检查，约 5 ms。
- Rust Core AI 测试：6 项通过，最终修改后已重跑；全量计时报告中这 6 项各耗时 31–54 ms。
- Windows 宿主回归：153 项通过。
- Windows Release 整机构建通过，已完成原生程序和运行资源准备。其后仅调整的数字输入交互，另经包含实际设置组件的前端生产打包、类型检查及浏览器验证；该小改动尚未重新打入 Release 可执行文件。
- 设置页使用模拟 IPC 和虚构凭据完成浏览器交互检查：导入、只读来源字段、手动服务商、保存后清空密钥输入、自定义提示词、语言、正文选项及数字逐字输入均通过，设置对象不包含密钥；已检查深色主题截图。检查过程中修正了下拉框和文本域的标签关联。
- 前端类型检查、修改区域 lint、Rustdoc 严格文档检查、测试稳定性静态检查、Agent Note 校验及 `git diff --check` 通过。

验证限制：

- SharedRust 全量计时执行到 452 项时，原有 `tests::git::git_write_deletes_a_local_commit_and_preserves_a_later_empty_commit` 返回 `Operation was cancelled`，耗时 16.494 秒；该项独立重跑通过，耗时 15.18 秒。本次未改动此用例，也不将这一轮全量测试记为通过。独立的 Git host 6 项通过。
- 当前 Windows 环境缺少 Ruby / zsh，无法完成依赖它们的共享契约、服务边界和 Core 注释脚本；Rustdoc 严格检查已通过。Windows 边界脚本还会命中本机已有、未跟踪的旧 CMake 产物，并受 Windows 路径分隔符影响；已核对跟踪文件未新增 C++，前端使用统一平台入口。
- 尚未使用真实服务商和个人密钥发起请求；浏览器模拟验证不替代 Windows 凭据管理器及真实 API 的端到端联调。
