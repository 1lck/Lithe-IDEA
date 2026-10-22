# Agent 笔记：Windows Agent 中途补充、订阅额度与 Codex 登录

状态：已实现

## 先说结论

第 14 期把 macOS Agent 的“回复过程中继续补充”“订阅额度圆环”和“Codex 订阅登录入口”接到 Windows。补充消息直接复用 Rust host 已经实现的 ACP steering 协议，不再等整轮结束；额度只保留一个圆环，细节放进悬停卡片；登录方式切换沿用 macOS 的订阅行，并在忙碌时拒绝切换。供应商仍保持 Windows 的单 active agent + 单 provider 形态，本机 CLI 配置自动读取与多供应商列表留到后续期次。

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

## 考虑过的备选方案

- 回复期间继续拒绝发送、等整轮结束：实现最少，但 Rust host 的 steering 能力等于白做，也无法对齐 macOS。
- 把补充消息排队到 `turnFinished` 再发送：不需要 delivery 状态，但用户看不到 host 是否接受，失败时也无法区分“没发”和“发了没被消费”。
- 继续用 Tooltip 文本展示额度：改动更小，但无法展示分窗口进度条与颜色，和 macOS 的悬停卡片差距明显。
- 引入完整的多供应商列表与本机 CLI 配置自动读取：更接近 macOS，但需要把 Windows 设置从扁平单 provider 改成按 agent 保存的 profile map，并新增平台文件读取；范围超过本期，先保持单 active agent + 单 provider。
- 让表单与配置文本双向同步：需要为 Codex TOML 与 Claude JSON 各写序列化器，本期只保留已有的“粘贴配置导入”，避免生成错误格式覆盖用户配置。

## 后果

- 用户可以在 Agent 输出、工具执行或等待授权时继续补充；原轮次计时、权限请求和停止按钮保持有效。
- 斜杠命令在 steering 阶段不会执行，而是在当前轮结束后作为普通 prompt 响应；这避免同一个命令被执行两次。
- 断连后补充消息仍留在对话里并显示失败原因，用户可以复制后重发。
- 额度圆环不再显示文字，低视力用户依赖无障碍标签与悬停卡片；未知值不会被画成健康的 0%。
- 订阅切换会重启 Agent 进程，因此忙碌时按钮禁用；空闲切换后旧 API Key 不会带入订阅连接。
- 供应商配置仍只有当前 agent 的一份 provider；本机 CLI 配置自动读取、多供应商列表和配置文本双向切换仍需后续实现。

## 验证

- `windows/tauri`: `bun run typecheck` 通过；`bun run lint` 与 `bun run build` 通过。
- Agent 与 i18n 测试覆盖：steering 的 `injected`、`promptRequired` 单次续发、停止撤销、拒绝与断连，用户回显去重，供应商默认模型与空模型保留。
- 仓库门禁：功能矩阵 `--check`、矩阵变更门禁、`verify-agent-notes.mjs`、`verify-windows-boundaries.ps1`、测试稳定性检查与 Windows 插件隔离检查均通过。
- 真机验收仍需在 Windows 上执行：真实 Codex 订阅与 Claude API Key 的输出中补充、工具执行中补充、等待授权时补充、斜杠命令续发；额度圆环颜色与悬停卡片；登录、取消与 API Key 切换。

## 适用范围

Windows Tauri Agent 对话的 steering 状态机、Composer 发送/停止、Transcript delivery 展示、订阅额度圆环与 Codex 订阅入口。ACP 协议、Rust host 的 steering 实现、macOS 交互和供应商单 profile 设置形态未改动。
