# Agent 笔记：Viva 的 ACP Core 连接桥

状态：已实现

## 先说结论

Viva 可通过 Rust Core 的 C ABI 创建 ACP 连接、发送原始契约命令并接收事件，也可读取 Core 检测到的运行时和 Agent 管理状态。桥接层只负责跨语言句柄和回调，不实现 ACP 协议；产品的 Agent 面板、供应商配置、权限界面和会话编排仍未接入。

## 问题

Core 回调期间持有自身回调锁，关闭连接又要撤销并等待回调结束。界面线程或回调里同步关闭会死锁或造成明显卡顿；无界缓存事件则可能耗尽内存或在事件丢失后显示错误的会话状态。

## 决策

通过整数身份关联 Go 事件队列，C 不持有 Go 指针。发送和关闭由同一把锁串行化，Core 返回关闭后才删除身份；关闭必须在界面线程以外执行。回调仅复制事件并尝试入队，不等待消费者，也不关闭连接。队列限制为 256 条、总计 16 MiB、单条 4 MiB；任一限制被触发时明确报告溢出，调用方必须关闭并丢弃连接，不能继续展示不完整会话。

启动配置可能包含凭据，桥接层不记录配置或命令。启动后异步失败由 Core 的事件报告，句柄创建成功不等于 Agent 已就绪。配置、权限和事件语义仍由 Core 及其契约决定；调用方不能把该桥当成已经完成的产品功能。

管理状态由 `agent.status` 读取；实际检测及版本判定由 Core 完成。适配器和 CLI 的更新结果用可空布尔值区分“没有更新”和“无法确认”，显示用的更新提示不得作为命令执行。检测可能启动只读版本探测，不能在 UI 线程调用，也不能因为读取状态自动安装或升级。安装、卸载和更新接口必须由用户明确操作触发；Core 决定目标、权限与实际结果，Viva 只转发进度。

通用请求事件经 `lithe_core_execute_json_with_events` 在请求线程同步交付，不把 Go 指针交给 C。观察者应立即返回，不等待界面；事件超过宿主大小限制或观察者发生 panic 时将观察失败与请求结果分开报告，因为操作可能已经成功或产生副作用。调用方不能因为进度观察失败自动重复安装，必须刷新实际状态。

Core 在同一进程内按请求编号查找取消目标，所以所有 `Client` 实例共用递增编号，不能按实例分别从一开始计数；否则不同实例的活动请求会重号并可能取消到另一请求，见 [#1803](https://github.com/1lck/Lithe-IDEA/issues/1803)。

请求编码结束后再次检查 context，避免编码期间已经取消的操作进入 Core；若取消先于 Core 注册请求，宿主重试取消查询直到注册成功或请求结束，见 [#1804](https://github.com/1lck/Lithe-IDEA/issues/1804)。Core 仍采用协作式取消：已经完成的请求保留真实结果，不能把取消当成必然回滚。

生产接线需要由平台存储适配器明确提供数据根目录，不能直接使用当前 Viva 偏好存储的 `Lithe Desktop` 目录并假设已有安装在那里：旧 macOS 正式版使用 Application Support 下的 `Lithe`，开发版还经过身份隔离；旧 Windows 客户端使用 Tauri 的应用数据目录。用户已有适配器的发现与迁移必须按平台及应用身份验证；读取设置页不应复制、删除或修改旧目录。该桥目前只接受调用方提供的目录，还没有实现迁移。

## 考虑过的备选方案

- 在 Go 中实现 ACP 和进程管理会复制 Core 的状态机，故直接调用已有 Core 接口。
- 队列满时静默丢弃消息会让回复、权限请求或结束事件丢失，故使连接进入明确失败状态。
- 在 Core 回调中关闭连接会与回调锁冲突，故由独立调用方处理关闭。

## 后果

调用方必须持续消费事件、处理溢出并在项目关闭或退出时关闭连接。安装 API 已接到 Core，但没有用户入口或真实安装验收；配置、凭据存储、权限操作和 UI 仍未完成。Windows 实机及真实供应商验收仍待完成。队列是内存中的临时状态，不创建缓存或写入发行包。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'TestAgent(SessionUsesCoreAndCleansUp|SessionsRemainIndependent|EventQueueOverflowIsExplicit|NextHonorsCancellation)' -count=3 -timeout=90s`：macOS 本地模拟 ACP 进程，验证连接、会话、流式事件、并发发送与关闭、独立连接、队列溢出、取消等待和子进程退出。
- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'Test(CoreRequestEventsStayScoped|CoreObserverPanicDoesNotHideRequestResult|Agent)' -count=3 -timeout=90s`：并发请求事件隔离、观察者 panic 与请求结果分离、共享管理 fixture、相对目录拒绝和调用前取消；用不存在的 Agent 验证真实 Core `preparing` 事件后拒绝安装且临时目录不变，不启动或修改用户 CLI，未执行真实安装。
- `scripts/desktop/desktop-go.sh test -race ./internal/core -run '^TestCoreRequestIDsUniqueAcrossClients$' -count=5 -timeout=90s`：两个客户端的请求同时活动时编号不同，取消一个请求不影响另一个。
- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'Test(ExecuteCancellationDuringEncodingStopsRequest|CancellationRetriesUntilCoreRegistersOrRequestFinishes)' -count=5 -timeout=90s`：编码期间取消不进入 Core；以可控重试信号验证注册后取消和请求结束后停止重试。
- 模拟进程不调用真实供应商；Windows 进程检查的测试文件已交叉编译，但桥接运行时验证仍待执行。

## 适用范围

- `desktop/internal/core/agent.go`
- `desktop/internal/core/agent_bridge.go`
- `desktop/internal/core/agent_management.go`
- `desktop/internal/core/events_bridge.go`
- `desktop/internal/core/agent_test.go`
- `shared/contracts/rust-core-api.md`
