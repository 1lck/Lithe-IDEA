# Agent 笔记：Windows Agent 中途补充、订阅额度与 Codex 登录

状态：已实现

## 先说结论

Windows 的中途补充直接复用 Rust host 的 ACP steering 协议；额度只保留一个圆环，细节放进悬停卡片；登录方式切换在忙碌时禁用。供应商配置按 Agent 独立保存，并提供命名列表与本机 CLI 联动；本机联动每次连接重新读取地址、模型和显式 API Key，读取失败时拒绝旧路由。CLI 文件始终只读，密钥只在连接内短暂存在或由用户明确保存到 Windows 凭据库。

## 问题

第 13 期完成后，Windows Agent 的呈现已接近 macOS，但还有三处行为差距：

- Rust host 已经实现 `steer` 与 `steeringResult`，前端却把回复中的再次发送当成“正在回复”直接拒绝，用户只能等整轮结束。
- 订阅额度用图标加多行文字 Tooltip，和 macOS 的单个圆环、分窗口进度条不一致，用户无法一眼看出哪个窗口最接近上限。
- Codex 订阅只藏在一个下拉框里，没有 macOS 的“启用订阅 / 改用 API Key”入口；切换后也没有可靠重连，容易继续使用旧配置。

## 决策

### 中途补充（steering）

- `AgentConnectionModel` 增加 `canSteer`（来自 host 的 `ready` 事件）、`pendingSteeringToken` 和补充消息的 `delivery` 状态。回复期间发送不再抛错，而是发出 `{ kind: "steer", token, sessionId, text, files }`。
- 补充消息立即以“正在发送…”出现在用户气泡下方。host 返回 `injected` 后改为“Agent 已接收”；`failed` 保留输入并显示原因。
- 受控续轮开始时复用原补充消息 ID，并把该消息移到原轮最终输出之后，作为新轮回复的边界；否则相邻 Agent 文本会跨轮拼接，两轮统计也会争用同一个结束消息。已完成原轮的输出和统计锚点保持不变，不新增重复用户气泡。
- `promptRequired` 表示这条输入不能被当前轮消费（典型是斜杠命令）。它进入 continuation 队列，等 `turnFinished` 后再以普通 `prompt` 发送一次；复用原消息 ID，因此不会出现第二个用户气泡。
- 停止或取消会撤销未消费的 continuation；断连会把所有未确认补充标为失败并清空 steering 能力，避免下一次连接复用旧 token。
- 回复期间的 `user_message_chunk` 直接忽略：本地已经显示用户输入，host 回显只会在历史回放时使用。
- Composer 在回复中同时显示 Stop 和 Send。Send 只有在 `canSteer` 为真时可用，避免“看起来能发、实际被拒绝”。

### 订阅额度

- 输入框上方只保留一个圆环：灰色轨道 + 按“已用最多的窗口”填充。没有文字，也不再使用 Gauge/Clock 图标。
- 颜色阈值与 macOS 一致：不超过 60% 绿色，超过 60% 黄色，超过 90% 红色；失败、过期或没有百分比时整体灰显。
- 悬停卡片按 5 小时、7 天、其他窗口排序，显示窗口名称、已用百分比、灰轨进度条和实际重置时间；账号变更提示重新连接。窗口没有上报百分比时只画灰轨，不伪造 0%。

### Codex 订阅与供应商默认值

- Codex 设置显示 macOS 同款订阅行：未启用时提供 Enable，启用后提供“Use API Key”返回 API Key 模式。
- 切换按钮在连接中、创建会话、回复中、加载历史、等待权限或配置确认时禁用。切换后 `reconnect` 从设置 store 读取刚保存的值再重连，避免闭包里的旧配置。
- 新增内置供应商默认模型：Codex 为 `gpt-6.1-sol`，Claude 为 `claude-fable-5-1`。切换适配器时只替换“空模型或上一适配器自己的默认值”，用户手填的模型保留；已持久化的空模型不会在读取时被回填。
- 命名供应商的密钥以 Agent ID 和供应商 ID 隔离，地址变化会产生新凭据所有者，不能继续把旧地址的密钥发送到新地址。删除须确认并先完成凭据删除；失败保留供应商。
- 配置文本通过共享 Core 解析元数据；Codex auth JSON 和 Claude settings JSON 的显式 API Key 在平台客户端短暂提取，不进入普通设置、错误详情或统计缓存。文本切回表单先解析，失败时保留原文和模式。
- 显式导入配置成功后切回表单，元数据与显式密钥一起留在未保存草稿中；随后保存使用这份草稿。不能继续留在已清空认证文本的模式下重新提取密钥，否则导入成功后直接保存会误报必填项缺失。取消编辑仍丢弃草稿。
- 关联本机 CLI 时，每次连接重新读取有 64 KiB 限制的配置与认证文件。订阅和自定义供应商不读取这些文件；缺失、Bearer、外部 helper 或云端认证不能回退到已保存的旧 API Key。

## 考虑过的备选方案

- 回复期间继续拒绝发送、等整轮结束：实现最少，但 Rust host 的 steering 能力等于白做，也无法对齐 macOS。
- 把补充消息排队到 `turnFinished` 再发送：不需要 delivery 状态，但用户看不到 host 是否接受，失败时也无法区分“没发”和“发了没被消费”。
- 继续用 Tooltip 文本展示额度：改动更小，但无法展示分窗口进度条与颜色，和 macOS 的悬停卡片差距明显。
- 始终复制本机密钥到普通供应商：实现更简单，但 CLI 轮换密钥后仍使用旧值，且用户难以识别来源，所以仅在明确粘贴保存时写入凭据库，本机联动使用临时快照。
- 将配置文本原样持久化：可完整保留 CLI 私有字段，却可能把凭据和无关执行配置带入普通设置，因此只持久化受支持的元数据；生成文本不包含已保存密钥。

## 后果

- 用户可以在 Agent 输出、工具执行或等待授权时继续补充；原轮次计时、权限请求和停止按钮保持有效。
- 斜杠命令在 steering 阶段不会执行，而是在当前轮结束后作为普通 prompt 响应；这避免同一个命令被执行两次。
- 断连后补充消息仍留在对话里并显示失败原因，用户可以复制后重发。
- 额度圆环不再显示文字，低视力用户依赖无障碍标签与悬停卡片；未知值不会被画成健康的 0%。
- 订阅切换会重启 Agent 进程，因此忙碌时按钮禁用；空闲切换后旧 API Key 不会带入订阅连接。
- 供应商列表有数量上限；原生保存通过比较并交换（CAS，即只接受预期修订仍有效的更新）拒绝跨窗口过期修改，并在同一次保存操作中提交元数据与凭据。配置文本只覆盖受支持的供应商元数据，不承诺保留任意 CLI 配置字段。

## 验证

- `windows/tauri`: `bun run typecheck` 通过；`bun run lint` 与 `bun run build` 通过。
- Agent 与 i18n 测试覆盖：steering 的 `injected`、`promptRequired` 单次续发、停止撤销、拒绝与断连，用户回显去重，供应商默认模型与空模型保留。
- `windows/tauri/tests/agent-provider-editor.test.tsx` 覆盖 Codex TOML/auth JSON 与 Claude settings JSON 的“文本导入 → 直接保存”，确认保存使用导入的模型、地址与密钥，普通设置不含密钥。
- 仓库门禁：功能矩阵 `--check`、矩阵变更门禁、`verify-agent-notes.mjs`、`verify-windows-boundaries.ps1`、测试稳定性检查与 Windows 插件隔离检查均通过。
- 真机验收仍需在 Windows 上执行：真实 Codex 订阅与 Claude API Key 的输出中补充、工具执行中补充、等待授权时补充、斜杠命令续发；额度圆环颜色与悬停卡片；登录、取消与 API Key 切换。

## 适用范围

Windows Tauri Agent 对话的 steering 状态机、Composer、订阅额度与登录入口，以及 `agent-settings-section.tsx`、`agent-launch.ts` 和本机 CLI 读取 adapter。ACP 协议、Rust host 的 steering 实现与 macOS 交互不受影响。
