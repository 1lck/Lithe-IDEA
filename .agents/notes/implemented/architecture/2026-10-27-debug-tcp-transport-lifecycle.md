# Agent 笔记：普通 TCP 调试连接与资源所有权

状态：已实现

## 先说结论

macOS 的普通 TCP 调试连接现在共用一个传输实现：语言服务器返回的本机端口，以及用户显式填写的外部 DAP（编辑器与调试适配器之间的协议）地址，都交给同一个有界连接生命周期管理。连接地址和被调试程序的地址是两件事；前者放在宿主配置的 `adapterEndpoint`，后者仍按适配器自己的启动或附加参数提供。

连接生命周期的规则由 Rust Core 的独立状态机持有，平台只做网络 I/O：Core 决定状态转换、取消规则、代次令牌与过期结果的拒绝、只结束一次、各段期限、待发队列预算和单个在途写入；平台适配器报告 socket、解析器和系统计时器观察到的事件，再按 Core 返回的步骤执行。这样 macOS 继续使用 `NWConnection`，Windows 可以用自己的网络层，两端共用同一套规则和生命周期测试。

本次只实现直连，不创建代理、SSH、隧道或端口转发。未来网络通路通过可替换的连接工厂接入，不在 DAP 协议状态机里拼接网络命令。完整网络方案仍见[独立提案](../../proposed/architecture/2026-10-27-debug-network-paths-and-tcp-lifecycle.md)。

## 问题

原有语言服务器端口传输可以连接本机 Java Debug Server，但没有待发数据总量限制，也没有逐次写入完成后再发送的压力控制。简单放开回环地址限制既不能补齐这些生命周期问题，也会混淆两条不同连接的权限。

例如远端 JVM 的 JDWP（Java 调试线协议）端口是 Java 适配器访问的目标，不是 Lithe 应向其发送 DAP 的端口。默认 debugpy 的监听端口则可以是 DAP 地址，二者不能用“远程端口”这一个字段表示。

## 决策

- 复用 Apple Network 的 `NWConnection` 建立 TCP、解析主机并收发字节，不实现另一套 socket、DNS 或代理协议栈。Rust Core 仍负责已有的 DAP 帧、请求顺序与操作超时；平台只管理网络字节流。
- 生命周期状态机在 `rust/lithe-core/src/debug/transport_lifecycle.rs`，与 DAP 协议状态机相互独立，按 `transportId` 登记。平台通过 `debug.transport.handle` 发送事件（`start`、`send`、`stop`、`finishSendingAndStop`，以及带代次的 `endpointResolved`、`connectionReady`、`dataReceived`、`peerClosed`、`failed`、`writeCompleted`、`timerFired`），Core 更新状态并返回新代次、阶段、结果和有序的效果（发现端点、设置或取消计时器、连接、写入、投递数据、关闭、报告失败、通知终止）。`debug.transport.policy` 返回默认期限与预算以及会话初始化窗口，`debug.transport.release` 释放登记。
- Core 没有时钟：它只决定期限的长度和到期后的转换，宿主负责等待并回报“计时器已触发”。待发数据只以字节数越过 JSON 边界，真实字节、socket、计时器句柄留在平台；平台在 `send` 里先按顺序登记帧，`write` 效果按先进先出取出对应的一帧。代次令牌、计时器编号和写入编号在 Core 中唯一且不复用，晚到的回调因代次或编号不符而被忽略。
- `MacTCPDebugAdapterTransport` 只拥有 `NWConnection`（经 `DebugAdapterSocketConnection`）、端点发现任务、待发帧的字节、系统计时器句柄，并执行 Core 的效果。端点发现、建连（两段各自独立计时，发现用时不挤占建连预算）、单个在途写入的期限、待发字节和消息数量预算都由 Core 判定。不设置会话总时长或空闲读取期限：用户停在断点上不是网络失败。写入完成只表示本机网络栈接受数据，不能据此声称适配器已处理请求。
- 直连的默认端点发现、建连和写入各为 10 秒；语言服务器冷启动与项目导入的端点发现单独允许 120 秒，端点确定后建连仍只有 10 秒，所以冷启动不会拉长对死端口的等待。Network 框架会把被拒绝或不可达的连接停在 `.waiting` 并不断重试，不会进入 `.failed`；传输把“连接被拒绝、主机或网络不可达”视为确定失败并立即结束，附上系统给出的原因，其余 `.waiting`（如暂时没有路由）仍等建连期限。显式外部 DAP 的会话初始化期限为 10 秒建连加 10 秒握手，会话计时从传输启动开始，必须比建连预算更长，避免误连到非 DAP 服务后永久停在初始化，同时不能抢在建连期限前结束；这些期限都不限制已建立会话的空闲时间。待发队列含在途数据最多 8 MiB、1024 次写入。超限或超时结束该连接，不静默丢帧、不重连或重放。失联不承诺立即可知，DAP 请求仍受原有操作期限约束。
- 用户停止会话时，先把已有 DAP disconnect 帧按原顺序交给网络栈，再关闭连接，最多等 1 秒；这不是等待远端确认，不能保证远端必然收到。传输的显式 `stop()` 仍立即中止，EOF、读写失败和超时也立即清理；不会为排空而启动尚未建立的连接。排空期间拒绝新数据、不向已结束会话投影晚到消息，超时由有界计时器持有并回收 socket。
- 停止、EOF、读写失败和超时先由 Core 递增代次，再由 `close` 效果取消解析任务、全部剩余计时器和 socket，清空回调与缓冲。旧连接回调以及旧写入完成不能影响新连接。显式停止由会话层投影结果，传输不重复发送终止通知。失败时 Core 先给出 `close`、`reportFailure`、`notifyTermination`；宿主执行每个效果前核对代次，观察者在错误输出回调里重新 `start` 会使剩余的旧终止通知作废。已处于停止状态的传输再收到 `stop` 则被 Core 忽略，所以观察者在错误输出回调里调用 `stop()` 时终止通知仍然送达，且只送达一次；旧实现把这种情况也当作“生命周期已被替换”而吞掉通知，这个差异是有意接受的。
- 宿主若发现 Core 调用本身失败（桥接故障而不是生命周期结果，包含 `send`），在本地静默拆除 socket 与计时器、释放登记，并向所有者报告一次，不让资源在故障后残留。释放会重置 Core 内部的代次与计时器编号，重启前必须换用新的登记 ID，并在宿主回调入口同时核对登记 ID；不能只依赖重置后的代次。故障观察者重启后也不得再收到旧终止通知。
- `DebugAdapterConnectionProviding` 是未来代理的替换点：返回尚未启动、可取消的连接，握手纳入已有启动期限；停止必须释放它自己拥有的资源。本次唯一实现为直连，不提前增加代理配置、密码或进程字段。
- `tcpLanguageServer` 仍只解析同插件语言服务器返回的回环端口。外部入口在 Debug 的更多操作中，由当前文件选择已安装的调试提供方（当前文件没有提供方时菜单项不可用），单独填写 DAP 地址、请求种类和适配器 JSON 参数；不猜测语言协议，不启动本地替代进程。连接对话框在连接启动前保持打开：被拒绝的地址、未获批准的确认、已有活动会话、连接失败或初始化超时都留在对话框里显示原因，已填的主机、端口和参数不丢失，表单通过 Application 层的 `ExternalDebugAdapterConnection` 等待会话越过初始化阶段，而不是把同步 `start` 返回视为网络连接成功。用户取消或关闭表单会停止本次尝试的会话 ID，即使此时已选中另一会话也不会误停它；已有初始化期限负责等待上界，表单不再添加第二套网络超时。Core 先校验地址，非回环端点每次连接前确认，明确警告裸 TCP 没有加密或认证；确认时间不计入网络建连期限。
- 外部服务只归用户所有。关闭 socket 本身不停止共享语言服务器、外部适配器或用户隧道；目标程序的结束策略由 DAP 协议层负责，`attach` 断开使用 `terminateDebuggee=false`，`launch` 断开则可能结束该会话启动的程序。不要把字节流所有权等同于目标程序的 DAP 生命周期。配置不持久化，源码映射继续由适配器参数表达。

正确：把用户已配置的隧道最终地址填为 DAP 端点，Lithe 只连接它，停止时只关闭自己的连接。

不要：把远端 `gdbserver` 或 JVM JDWP 地址填成 DAP 地址，或在连接工厂中私自启动 `ssh -L`、停止用户已有隧道。

## 考虑过的备选方案

- **在旧端口传输上直接放开主机限制。** 缺少独立来源与确认，而且不能保护旧回环信任边界；改为保留端点来源并共用底层生命周期。
- **为外部 DAP 新写一个 TCP 传输。** 取消、缓冲和晚到回调会出现两套规则；改为端点解析与连接建立分开复用。
- **把生命周期规则继续留在 Swift，只加测试。** 初版就是这样：期限、预算、代次和只结束一次都写在 macOS 传输里，Windows 要重新实现并重新证明同一套规则。改为 Core 持有规则、平台持有 I/O。
- **让 Core 持有 socket、DNS 或时钟。** 这会把平台网络栈与系统计时器搬进跨平台内核，并强迫 Core 依赖运行时和真实时间，测试不再确定。改为 Core 只返回下一步，宿主执行并回报。
- **让待发字节穿过 JSON 边界。** 帧最大可达数 MiB，复制和编码代价无谓，且 Core 只需要字节数做预算。改为只传字节数，帧留在宿主。
- **本轮同时实现代理或统一成 SSH。** 认证、身份校验、共享隧道和辅助进程归属还需要独立设计；没有 SSH 也可以直连或经过用户的 VPN，不把 SSH 当作必要前提。

## 后果

普通 TCP 连接可独立测试，stdio 原有路径不变，用户提供的外部地址与语言服务器端口遵守各自的信任边界。代价是外部连接需要用户了解其适配器参数，没有保存配置、通路自动建立或断线恢复；插件 `tcpPort`、`tcpAnnounced` 的托管进程模式也仍未实现。

此处代码实现不等于所有语言适配器都已验收。真实 JVM、debugpy、GDB 的兼容性仍需对应插件和端到端场景证明；Windows 共享地址校验与这套生命周期状态机，但尚无宿主 TCP 实现，接入时只需实现 socket、解析和计时器这些 I/O 并执行 Core 返回的效果，状态机本身不需要再写一遍。

外部入口复用当前文件的调试提供方索引，该索引仍只选择支持文件启动的插件（Java 使用宿主提供方）。因此本次不支持单独发现仅附加进程、可执行文件或其他非文件型插件；不要把 TCP 字节流可用等同于这些插件的产品入口已经接通。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'TCPDebugAdapterTests|PluginDebugAdapterTests|DebugModuleTests'`：覆盖可控时钟、队列预算、取消与晚到回调、确认顺序、会话选路、外部表单初始化成功/失败/超时与按会话取消、桥接故障的立即清理和重新登记后的旧回调隔离；临时回环监听器验证双向字节以及真实 Core 的 initialize/attach 帧往返，监听服务不随客户端停止；真实连接到已释放的回环端口必须在远小于建连期限的时间内以系统原因结束，发现与建连的两段期限由可控时钟分别断言。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core debug_adapter_endpoint` 和 `cargo test --manifest-path rust/Cargo.toml -p lithe-core dap_endpoint_contract`：共享 fixture 校验及 JSON dispatcher 边界。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core transport_lifecycle`：状态机单元测试，并逐步回放 `shared/fixtures/debug/transport-lifecycle-v1.json` 中的场景（启动与取消、过期代次、只结束一次、各段期限、预算超限、单个在途写入、排空）。新平台实现同一份 fixture 即可证明规则一致；`protocol` 测试覆盖 `debug.transport.*` 命令的 JSON 边界。
- `./scripts/architecture/verify-shared-contracts.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh`、`./scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Debug/`
- `macos/Sources/LitheDebugModule/Runtime/DebugAdapterSessionManager.swift`
- `macos/Sources/Lithe/Views/Debug/ExternalDebugAdapterView.swift`
- `macos/Sources/Lithe/Application/Features/ExternalDebugAdapterConnection.swift`
- `macos/Sources/Lithe/Core/Rust/RustDebugTransportCore.swift`
- `rust/lithe-core/src/debug/endpoint.rs`
- `rust/lithe-core/src/debug/transport_lifecycle.rs`
- `shared/fixtures/debug/adapter-endpoints-v1.json`
- `shared/fixtures/debug/transport-lifecycle-v1.json`
- `shared/contracts/rust-core-api.md`
