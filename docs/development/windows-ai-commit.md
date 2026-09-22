# Windows AI 提交信息：实现与配置说明

Windows 现已提供独立的“AI 与提交”配置，可手动管理多个服务商，也可识别本机 Codex 和 Claude 的 API 配置。生成结果先写入提交框，检查后再执行提交。

架构取舍见[设计文档](../../.agents/notes/implemented/feature/2026-09-22-windows-ai-commit-design.md)，字段与接口见[共享契约](../../shared/contracts/ai-commit.md)。本篇记录代码接线、使用方式和验证方法，不复制架构决策。

## 如何使用

1. 打开设置 → **AI 与提交**，或点击 Git 提交区域的设置按钮。
2. 点击**添加服务商**，填写名称、API 地址、模型和 API 协议。API 协议须与服务商支持的接口一致。
   Chat Completions 默认使用 `max_completion_tokens`；仅支持旧参数的网关可选择 `max_tokens`。推理强度选择“服务商默认”会省略该参数。
3. 填写密钥并点击**保存密钥**。普通设置会自动保存；数字字段在失去焦点或按 Enter 时校验并保存，避免输入中途被强制改写。密钥另存于 Windows 凭据管理器。
4. 选择输出语言、格式、推理强度、正文与长度配置。选择**自定义**格式后可以保存提示词，例如：“标题使用中文，以项目工单编号开头，仅描述 diff 能证明的改动。”
5. 在 Git 更改列表中勾选同一仓库的文件，点击 **AI**。已有提交草稿时会提示是否替换；也可在生成过程中取消。
6. 检查生成结果，按需编辑，然后点击提交。

手动配置示例仅使用虚构地址：`https://api.example.com/v1`、模型 `example-model`。Responses 会请求 `/responses`，Chat Completions 会请求 `/chat/completions`，Anthropic 会请求 `/v1/messages`；已填写完整接口地址时不会重复拼接。

## 本机配置导入

进入页面会自动识别，点击**重新加载识别**可刷新。

| 来源 | 默认位置与支持内容 |
| --- | --- |
| Codex | 用户目录 `.codex/config.toml`、`.codex/auth.json`；支持 `CODEX_HOME`、所选 profile、模型、provider 地址、wire_api、env_key、experimental_bearer_token、API Key |
| Claude | 用户目录 `.claude/settings.json`、`.claude/.credentials.json`、`.claude.json`；支持 `CLAUDE_CONFIG_DIR`、相关 ANTHROPIC 环境变量、常用模型别名 |

点击卡片中的导入按钮后，配置会出现在服务商列表。导入配置的地址、模型、协议和凭据只读；修改源配置后可刷新，实际生成前也会重新读取。Lithe 不修改原文件，不将导入密钥复制进设置。

仅安装或登录 Codex/Claude CLI 不保证拥有可直接调用服务商接口的 API 凭据。当前不支持 OAuth 令牌刷新、执行凭据助手或调用 CLI 代理生成；需要认证的服务商缺少 API 密钥时会显示明确提示。

环境变量来自 Lithe 进程继承的环境，系统环境设置改变后通常需要重启 Lithe 才能看到。HTTP 地址默认禁止，使用可信本机服务时可勾选服务商的 HTTP 选项。

Codex 服务商声明了 `env_key` 时，Lithe 只使用该变量，缺失或为空不会回退到其他账号。仅使用 OpenAI 认证的服务商可以读取 OpenAI auth JSON 或全局 API key。自定义免密服务商不需要额外填写 `requires_openai_auth=false`，也不会附带全局 OpenAI 凭据。

## 设置与兼容性

新设置保存在 `aiCommit` 中。旧的聊天、补全和通用 AI 设置保留，不自动迁移其密钥；使用此功能时选择本机导入或新建服务商。提交生成不再读取 `aiModelId` / `aiCustomModelId`，避免旧 Custom 字段不一致问题。

通用配置通过设置 → **AI 聊天与编辑**访问，提交配置通过 **AI 与提交**访问。两页独立保存，Git 提交区的设置按钮直接打开提交配置。

默认采用英文、Conventional Commits、服务商默认推理强度、不生成正文、标题 72 字符、Diff 32000 字符。已保存的显式推理强度保持不变；推理强度取决于服务商和模型的支持范围，Anthropic Messages 当前不发送此选项。标题长度通过提示词控制，不强制截断标题。

请求为模型推理与最终文本合计预留 4096 个输出 token。仅生成标题时也保留这部分额度，避免推理耗尽原先的 512 token 后没有正文。如果服务商报告输出额度耗尽，界面提示降低推理强度或减少 Diff 字符限制，不把截断内容写入提交框。

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

自动测试覆盖多服务商配置归一化、旧设置默认值、凭据字段剔除、Codex profile/env_key/内置令牌、Claude 模型别名、三种响应解析、输出额度耗尽、Unicode 截断、敏感路径拒绝、空响应、草稿确认、工作区变化、同名文件内容变化和取消。Review 修复补充凭据来源绑定、免密配置、现代与旧版 Token 参数、默认推理参数省略，以及两个 AI 设置页独立可达的回归测试。

运行命令：

```powershell
./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/settings/components/ai-settings-routing.test.tsx,src/features/git/services/ai-commit-workflow.test.ts,src/features/git/services/ai-commit-context.test.ts,src/features/git/types/ai-commit.test.ts,src/features/settings/lib/settings-normalization.test.ts
cargo test --manifest-path rust/lithe-core/Cargo.toml ai::tests --lib
./scripts/build-windows.ps1 -Configuration Release
cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
node scripts/verify-agent-notes.mjs
```

计时报告写入 `.artifacts/test-stability/`。真实服务商联调需使用用户选定的服务和凭据，单元测试不会访问真实网络，也不会读取个人 Codex/Claude 文件。

## PR 初始验证记录（2026-09-22，Review 修复前）

- 前端定向计时测试：23 项通过，包含提交流程、差异收集、设置归一化及原设置回归；本轮最慢相关用例为读取勾选路径，31 ms，截断外内容指纹检查为 16 ms。
- Rust Core AI 测试：最终 8 项通过，每项 27–35 ms；新增的 Codex 内置令牌测试为 29 ms，输出预算与不完整响应测试为 35 ms。通过现有 Rust 计时 runner 限定枚举 `ai::tests::` 执行，HTML/JUnit 记录在 `.artifacts/test-stability/ai-commit-final.*`。
- Windows 宿主回归：修复后重新执行 153 项，全部通过；报告为 `.artifacts/test-stability/windows-rust-runtime.*`。
- 最终 Windows Release 整机构建通过，包含数字输入、Codex 内置令牌及输出预算修复。实测使用该可执行文件，在真实 Windows Tauri / WebView2 中通过 Playwright CDP 操作界面，调用真实原生 IPC、Git、Windows 凭据管理器和服务商 API。
- 设置实测：Codex、Claude 自动识别与导入、来源字段只读、自定义中文提示词、数字逐字输入，以及重启后的配置恢复通过。手动测试密钥保存后输入框清空，重启后仍能读取凭据状态；普通设置文件未包含该密钥。测试后通过原生命令移除，并再次查询确认凭据不存在。
- 生成实测：导入 Codex 和 Claude 后分别成功生成 `TEST:` 开头的中文标题；HTTP 默认拒绝及按服务商开启后的请求也通过。界面取消和原生请求取消均通过；取消或拒绝替换时保留手写草稿。确认替换前修改真实文件，界面拒绝应用过期结果并保留草稿。
- 完整提交实测：临时 Git 仓库中的 `greeting.py` 增加姓名去空白及空名默认值，Claude 生成“TEST: 姓名去空白且空名默认为 Guest”；通过应用提交后，Git 日志与生成标题一致，仓库无未提交更改。请求只使用临时示例代码。
- 实测修复两处问题：补充 Codex provider 内 `experimental_bearer_token` 的识别；将输出预算从标题模式的 512 token 提高到 4096，并拒绝服务商标记为额度耗尽的不完整结果。真实服务在 512 token 下曾只返回推理内容，调整后返回完整标题。
- 测试结束后关闭原生应用及 WebView 子进程，确认调试端口不再监听；恢复原设置，移除测试密钥、临时可执行文件及隔离 WebView 配置目录。
- 前端类型检查、修改区域 lint、Rustdoc 严格文档检查、测试稳定性静态检查、Agent Note 校验及 `git diff --check` 通过。

验证限制：

- SharedRust 全量计时完成 651 项，650 项通过；原有 `tests::git_patch_exchange::patch_exchange_detects_index_flags_and_hidden_destination_edits` 的断言通过，但进程总耗时 15.328 秒，超过 15 秒预算。无并行构建时单独复跑为 10.412 秒，通过；保留原全量失败记录，不将其改记为通过。该全量轮次在最后的输出预算修改前编译，最终 AI 8 项已另行重跑。独立的 Git host 6 项通过。
- 当前 Windows 环境缺少 Ruby / zsh，无法完成依赖它们的共享契约、服务边界和 Core 注释脚本；Rustdoc 严格检查已通过。Windows 边界脚本还会命中本机已有、未跟踪的旧 CMake 产物，并受 Windows 路径分隔符影响；已核对跟踪文件未新增 C++，前端使用统一平台入口。
- 真实网络验证覆盖本机已配置的 Responses 和 Anthropic 服务商；Chat Completions 由确定性协议测试覆盖。未验证其他服务商、OAuth 登录刷新或 macOS 运行行为。

## Review 修复验证（2026-09-22）

- 前端定向计时测试 25 项通过，包含新的两个 AI 设置页切换回归；Core AI 定向计时测试 13 项通过，所有新增用例均在 40 ms 内完成。
- Windows Release 整机构建通过，生成 `windows/tauri/src-tauri/target/x86_64-pc-windows-msvc/release/lithe-windows.exe`。Windows Rust 宿主计时测试全部通过：项目 11 项、终端 30 项、宿主 153 项。
- 严格 Rustdoc、类型检查、修改区域 lint、测试稳定性检查、Agent Note 校验和 `git diff --check` 通过。构建和测试过程中没有启动并遗留 Lithe 应用进程。
- 当前环境缺少 Ruby / zsh，依赖它们的共享契约、服务边界和 Core 注释脚本仍未执行；未进行真实服务商网络联调或 macOS 运行验证。
