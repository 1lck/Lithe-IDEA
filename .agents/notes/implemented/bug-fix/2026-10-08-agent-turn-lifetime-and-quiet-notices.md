# Agent 笔记：长任务持续执行与静默提醒

状态：已实现

## 先说结论

编码任务可能持续运行几十分钟，工具执行和模型思考也可能暂时没有输出。
正常任务与用户授权不设整轮时限；连续五分钟没有新进度时只显示提醒，任务继续执行。
用户可以继续等待或主动停止，明确故障、停止确认和连接清理仍有各自的处理边界。

## 问题

原先共享 Agent Host（管理 Agent 连接的 Rust 组件）对每轮请求设置十分钟绝对上限，
包含工具执行和授权等待，中途的进度也不能延长。真实任务在服务已启动、测试已完成后
仍可能被中断，提示却说 Agent 没有响应。授权五分钟自动取消和 Windows 旧前端的
二十秒首条消息失败同样把正常等待当成故障。

## 决策

使用 Agent Client Protocol（ACP，编辑器与 Agent 之间的公开协议）报告的回复、
思考、计划和工具进度更新静默计时。提醒只发一次，新进度清除提醒并重新计时。
继续等待只关闭当前提醒，不能释放会话、重新提交请求或重复执行已有工具。
静默不能证明任务卡死，所以不自动停止，也不凭空显示重连或推理。

授权等待暂停静默提醒。全部待处理授权答复后才重新计时，避免并行授权提前恢复提醒。
请求注册保持消息顺序，但等待用户的工作通过 SDK（上游协议库）拥有的任务执行；
不能在按顺序分发消息的回调里无限等待，否则后续进度、更多授权以及连接关闭都被堵住。
取消、轮次结束和连接关闭负责答复及清理全部待处理授权。

初始化、会话与配置短请求、尚无实际工作的故障重连和取消确认继续保留独立期限。
正常轮次结束由上游结果、明确故障、用户停止或会话关闭决定；具体工具和模型请求的
预算由执行它们的上游 Agent 拥有。停止后等待原请求的终态，再释放会话；十秒没有确认
则停止连接及其进程树，保留对话和修改，重连后加载历史。不能保证上游已持久化最后片段。

Codex 已有回复、推理、计划、工具或授权进度后，后续断流交给原生引擎恢复。
上游公开错误通知仍表示 `willRetry: true`（还会继续尝试）时，Host 保持同一忙碌轮次，
不重新设置二十秒截止时间，也不以自己的五次计数提前取消。原生请求仍有已配置的
四次流恢复预算，未开启无限重试；明确终止失败、永久错误、连接退出和用户停止仍有效。
尚无工作时的二十秒窗口与五次共享预算继续保留，避免首次连接失败长期等待。

恢复等待从第一条警告开始单独计时，五分钟后提示“连接恢复等待较久，Agent 仍在重试”，
后续警告不能推迟提醒。恢复后的实际进度清除提醒。`turnRetrying`（重连状态事件）
仅在尚无工作时携带 `maxAttempts`；原生恢复省略上限，界面只显示“正在重连”，
不能把观察到的通知次数当成另一个调用预算。继续等待只关闭提醒，停止仍等待确认。
最终恢复失败保留已经完成的工具、消息和修改，用户可在原会话明确要求核对已完成工作
并继续剩余步骤；断连时先加载原生历史，不自动重发原任务。

正确示例：构建静默五分钟后显示“暂未收到新的进度，任务仍在进行”，用户继续等待，
构建完成后同一轮继续写 README。不要这样做：十分钟到期停止，随后自动重发原请求，
导致启动第二个服务或重复修改文件。

macOS 使用共享 Host 的 `turnActivity` 提醒；Windows 旧 ACP 前端使用手动调度器可测的
本地提醒器，移除首条消息强制失败。两者的阈值取自固定源码
`shared/contracts/agent-turn-policy.json`，它在构建阶段嵌入，不是运行时可写资源。
提醒状态和计时器只属于当前连接/轮次，不新增下载、缓存、索引或日志目录，
不写发行包、不影响代码签名和 Sparkle 增量更新；不需要注册 worktree 可复用资源。
Windows 共享 Host 完整对话接入仍是已有的待完成能力，不能因本地前端测试通过改为已验证。

## 考虑过的备选方案

- 延长总时限到三十或六十分钟：仍会中断更长的正常任务。
- 静默超过阈值自动停止：模型思考和无输出工具都可能被误判。
- 轮询私有日志或给所有 ACP Agent 增加心跳：协议没有统一保证，也会侵犯上游运行状态的所有权。
- 完全去掉生命周期管理：停止不确认和断连仍需有界清理，不能释放会话后让旧请求继续运行。
- 把原生恢复上限从二十秒改为六十秒：仍会抢先中断上游允许的恢复，不能解决所有权冲突。
- 失败后自动重发整条任务：无法证明工具没有外部副作用，会重复启动服务或修改文件。

## 后果

正常长任务和较晚的授权答复能够继续，静默提醒与错误状态分开。
代价是一个仍然存活但没有输出的 Agent 可以持续等待，用户需要主动停止；
进程存活本身不代表任务有进展。没有新增可配置费用或任务总预算设置。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-agent-host`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AgentConversationFeatureModelTests|AgentConversationPresentationTests|AgentHistoryTests|AgentNextTurnConfigurationTests|AgentActivityTests'`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs -- src/features/ai/lib/acp-activity-monitor.test.ts src/i18n/locale.test.ts`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`

Rust 通过虚拟时间和内存协议连接验证超过一小时的静默、超过十分钟的工具进度、
多个授权答复、停止确认及首次连接的重连预算；已有工作后的恢复超过二十秒并收到
超过五次通知仍可由原生结束，同一轮没有第二条 prompt；恢复提醒不被新警告延后。
Swift 通过注入事件验证忙碌、计时、继续等待、终止后保留工作与明确继续、
会话隔离和停止优先级。Windows 前端用手动调度器验证提醒与清理，不依赖真实睡眠。
本次恢复策略修复在 macOS 通过一百零五项 Host 单元测试和一百零六项 Swift 测试；
恢复提醒在深浅主题、窄宽面板中验证布局。Windows 前端提醒保持前次手动调度器验证证据。
供应商与真实 Agent 的三十三项集成测试未启用；Windows 原生构建与端到端验证未执行。
全量共享契约校验被 preview 已有的 Windows 浅色文本颜色不一致阻挡，
Windows 类型检查也被已有的 `diff` 模块声明缺失阻挡；未把这些结果记为通过。

## 适用范围

- `rust/lithe-agent-host/src/lib.rs`
- `rust/lithe-agent-host/src/prompt_retry.rs`
- `macos/Sources/LitheAgentConversationModule/Application/AgentConnectionModel.swift`
- `macos/Sources/Lithe/Views/Agent/AgentTurnStatisticsView.swift`
- `windows/tauri/src/features/ai/lib/acp-activity-monitor.ts`
- `windows/tauri/src/features/ai/services/acp-stream-handler.ts`
- `shared/contracts/rust-core-api.md`
