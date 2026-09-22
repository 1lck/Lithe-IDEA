# Agent 笔记：Windows AI 提交信息设计

状态：已实现

## 先说结论

Windows 的 AI 提交信息参照 macOS，采用独立服务商配置和可配置生成规则，支持手动添加以及导入本机 Codex、Claude 配置。生成只修改提交草稿，最终提交仍由用户操作。Windows 保留“勾选文件的工作区完整内容”提交语义，因此生成依据也来自相同范围，不改成 macOS 的暂存区语义。

## 问题

原实现借用编辑器行内编辑服务，提交格式写死在组件中，无法配置语言和自定义提示词。设置页写入 `aiModelId`，Custom 服务商生成时却读取 `aiCustomModelId`，导致配置界面和实际请求不一致。

原流程最多抽取十个文件的差异；结果直接覆盖草稿。大量文件、请求期间切换项目、继续编辑草稿等场景，容易出现信息不完整或覆盖用户输入的问题。

## 决策

### 服务商和生成规则分别保存

`aiCommit` 是独立设置，保存服务商列表、当前服务商 ID、开关及提交规则。聊天和补全继续使用原来的配置。服务商包含地址、模型、协议和凭据来源；规则包含语言、六类格式、自定义提示词、正文、标题长度、差异预算和推理强度。

设置侧栏分别挂载“AI 聊天与编辑”和“AI 与提交”。前者复用已有通用 AI 设置组件，保留公司网关、模型和密钥的编辑入口；Git 提交区直接打开后者。不能用提交设置替换通用设置，因为聊天和行内编辑仍然读取各自原来的配置。

界面只保存凭据的引用，不把密钥写入设置、导出文件或共享夹具。手动密钥通过 Windows 凭据管理器保存；导入服务商在每次生成前重新读取来源配置。导入后的地址、协议、模型和认证字段不可编辑；“允许 HTTP”属于用户在 Lithe 中明确作出的选择，可以单独更改。

Codex 导入同时识别 provider 内的 `experimental_bearer_token`。它与环境变量和 auth JSON 中的 API 密钥一样，只在主机请求期间使用；识别结果仅向界面暴露“是否已有凭据”，不返回令牌。这样能复用本地自定义服务商配置，同时保留原来的凭据边界。

凭据来源必须绑定到当前服务商。声明 `env_key` 后，只读取该变量；变量缺失或为空时应提示缺少密钥，不能回退到其他账号。没有指定变量时可读取该服务商的内置令牌；只有内置 OpenAI 或显式声明 `requires_openai_auth=true` 的服务商才能读取 OpenAI 的 auth JSON 与全局 API key。自定义服务商默认不使用 OpenAI 认证，且没有声明凭据来源时允许免密连接。`requires_openai_auth` 不能直接当作“任意 API 是否需要密钥”的开关。

### 确定性规则与平台输入输出分开

Rust Core 的 `ai` 模块负责纯文本配置解析、输入校验、提示词、字符预算、协议请求计划和响应提取。这里的请求计划只是 URL 和 JSON 请求体，不读取磁盘、不访问网络、不存储凭据。

Windows 主机（Tauri 应用中的原生 Rust 层）负责用户目录、配置文件、环境变量、Windows 凭据管理器、HTTP 请求和取消。前端通过已有 `platform_invoke` 统一入口调用，不为每条共享规则创建一个 Tauri 命令。

正确示例：主机读取 `config.toml`，将文本交给 Core 解析；发请求前补上密钥，返回前丢弃密钥。

不要这样做：React 直接读取 `auth.json` 并把完整解析结果写到 Zustand 或普通设置。这样会让凭据混入前端状态和设置导出。

### 以真实提交范围生成草稿

Windows 的 `commitSelectedChanges` 提交勾选路径的工作区内容。生成复用同一套仓库相对路径和重命名映射，通过现有 `worktreeSnapshot` Git 差异接口读取，不临时修改真实 index，也不执行 `git commit`。

读取覆盖所有勾选文件，限制为同一仓库、最多 1000 个文件，同时最多四个 Git 读取。保留的提示文本有总预算；每个文件都保留边界，截断必须标识，二进制文件没有文本证据。读取失败时停止生成，不能把部分成功误报为完整范围。环境文件和常见凭据路径在发送前拒绝。

生成完成后重新读取差异并比较完整可用 patch 的 SHA-256 摘要（内容指纹），防止文件名相同但内容已经改变。工作区、分支、勾选范围变化或取消后不应用结果。已有草稿须确认替换；确认期间继续修改的内容仍优先保留。

### 请求边界与失败行为

支持 Responses、Chat Completions 和 Anthropic Messages。网络请求限制 45 秒，响应最多 2 MiB；每个配置文件最多 1 MiB。取消会使主机丢弃正在等待的 HTTP 请求。已开始的 Git 读取沿用 Core 的有界执行，停止发起后续读取，并等待在途读取结束。

Chat Completions 默认使用 `max_completion_tokens`，使预算包含 o 系列模型的推理输出；手动服务商可以明确选择旧网关的 `max_tokens`。不按模型名称猜测网关能力，也不在失败后自动换字段重复请求。推理强度新增“服务商默认”，此时完全省略参数；显式 `none` 仍按协议发送，避免把不支持推理字段的普通模型也强行带上该字段。

输出预算同时包含模型推理和最终文本，不能按短标题长度直接设成 512 token。真实服务联调中，该额度曾只返回推理内容；因此统一预留 4096 token，并识别三种协议的输出额度耗尽状态。即使已经返回部分文本，也应提示重试，不能把未完成的标题当作成功结果。代价是单次请求允许更高的输出上限，实际用量仍取决于模型。

默认仅允许 HTTPS；HTTP 需要服务商级开关。禁止 URL 内嵌账号密码、查询参数和片段，禁止 HTTP 自动重定向，避免将认证信息带到未选择的地址。错误通过稳定代码转为中英文提示，不直接展示服务商响应正文或含凭据的网络错误。

## 考虑过的备选方案

- **继续复用行内编辑接口**：能减少接线，但提交输入、配置与草稿生命周期都不是编辑器修改语义，继续使用会让两个功能互相牵制。因此只复用成熟的 Git、HTTP、凭据能力，建立独立提交服务。
- **把 Swift 实现翻译成 React 内的提示词逻辑**：交付快，但纯解析和协议语义会再出现一份平台副本。因此新规则放在 Rust Core，macOS 本次保持现有实现，迁移范围写在共享契约里。
- **Windows 也只读取暂存区**：表面更像 macOS，但与当前 Windows 勾选路径提交行为不一致，会生成另一组内容的说明，因此不采用。
- **复制导入密钥到 Lithe 设置**：实现简单，但密钥轮换不会自动生效且容易进入设置导出，因此采用来源引用和请求时重读。
- **自动提交生成结果**：节省一步操作，却取消了用户检查和编辑机会，因此 AI 入口始终只生成草稿。

## 后果

用户可以独立控制提交信息的服务商和格式，也能复用本机 API 配置。通用 AI 的模型字段不再影响提交生成，从调用结构上消除了原字段不一致问题。

代价是生成前后各读取一次差异，以换取更可靠的过期结果判断。字符预算会省略部分大文件内容，因此提示词明确禁止推断省略部分；Core Git 自身输出上限之外的变化无法由当前可用 patch 证明。

Codex/Claude 的 OAuth 登录不等同于可用 API 密钥，本次不实现 CLI 登录令牌刷新或代理 CLI 调用。macOS 的 PR 描述生成有独立入口，本次聚焦 Git 提交草稿，不向 Windows 设置添加尚未接入的 PR 模板选项。

标题长度作为模型指令，不强制切断生成的标题。推理强度由服务商决定是否支持，Anthropic Messages 当前不发送此字段。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml ai::tests --lib`：配置解析、凭据不序列化、协议映射、截断和错误边界。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`：测试稳定性静态检查。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`：前端行为和单测试计时。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope SharedRust`：共享 Rust 的计时验证。
- `./scripts/build-windows.ps1 -Configuration Release`：Windows 完整构建。
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml`：宿主适配器回归。
- `node scripts/verify-agent-notes.mjs`：设计笔记格式和链接。

具体执行结果与使用步骤记录在[实现文档](../../../../docs/development/windows-ai-commit.md)。

## 适用范围

- `rust/lithe-core/src/ai/`
- `windows/tauri/src-tauri/src/ai_commit.rs`
- `windows/tauri/src/features/git/`
- `windows/tauri/src/features/settings/components/ai-commit-settings-panel.tsx`
- `shared/contracts/ai-commit.md`
- `shared/fixtures/ai/commit-generation-v1.json`
