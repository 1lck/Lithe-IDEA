# Agent 笔记：普通 TCP 调试连接与资源所有权

状态：已实现

## 先说结论

macOS 的普通 TCP 调试连接现在共用一个传输实现：语言服务器返回的本机端口，以及用户显式填写的外部 DAP（编辑器与调试适配器之间的协议）地址，都交给同一个有界连接生命周期管理。连接地址和被调试程序的地址是两件事；前者放在宿主配置的 `adapterEndpoint`，后者仍按适配器自己的启动或附加参数提供。

本次只实现直连，不创建代理、SSH、隧道或端口转发。未来网络通路通过可替换的连接工厂接入，不在 DAP 协议状态机里拼接网络命令。完整网络方案仍见[独立提案](../../proposed/architecture/2026-10-27-debug-network-paths-and-tcp-lifecycle.md)。

## 问题

原有语言服务器端口传输可以连接本机 Java Debug Server，但没有待发数据总量限制，也没有逐次写入完成后再发送的压力控制。简单放开回环地址限制既不能补齐这些生命周期问题，也会混淆两条不同连接的权限。

例如远端 JVM 的 JDWP（Java 调试线协议）端口是 Java 适配器访问的目标，不是 Lithe 应向其发送 DAP 的端口。默认 debugpy 的监听端口则可以是 DAP 地址，二者不能用“远程端口”这一个字段表示。

## 决策

- 复用 Apple Network 的 `NWConnection` 建立 TCP、解析主机并收发字节，不实现另一套 socket、DNS 或代理协议栈。Rust Core 仍负责已有的 DAP 帧、请求顺序与操作超时；平台只管理网络字节流。
- `MacTCPDebugAdapterTransport` 管理端点解析与建连的合计期限、单个在途写入的期限、待发字节和消息数量预算。不设置会话总时长或空闲读取期限：用户停在断点上不是网络失败。写入完成只表示本机网络栈接受数据，不能据此声称适配器已处理请求。
- 直连的默认准备和写入分别为 10 秒；语言服务器冷启动与项目导入的端点发现允许 120 秒。显式外部 DAP 另有包含建连的 10 秒初始化期限，避免误连到非 DAP 服务后永久停在初始化；这些期限都不限制已建立会话的空闲时间。待发队列含在途数据最多 8 MiB、1024 次写入。超限或超时结束该连接，不静默丢帧、不重连或重放。失联不承诺立即可知，DAP 请求仍受原有操作期限约束。
- 用户停止会话时，先把已有 DAP disconnect 帧按原顺序交给网络栈，再关闭连接，最多等 1 秒；这不是等待远端确认，不能保证远端必然收到。传输的显式 `stop()` 仍立即中止，EOF、读写失败和超时也立即清理；不会为排空而启动尚未建立的连接。排空期间拒绝新数据、不向已结束会话投影晚到消息，超时由有界计时器持有并回收 socket。
- 停止、EOF、读写失败和超时先撤销连接代次，再取消解析任务、计时器和 socket，清空回调与缓冲。旧连接回调以及旧写入完成不能影响新连接。显式停止由会话层投影结果，传输不重复发送终止通知。
- `DebugAdapterConnectionProviding` 是未来代理的替换点：返回尚未启动、可取消的连接，握手纳入已有启动期限；停止必须释放它自己拥有的资源。本次唯一实现为直连，不提前增加代理配置、密码或进程字段。
- `tcpLanguageServer` 仍只解析同插件语言服务器返回的回环端口。外部入口在 Debug 的更多操作中，由当前文件选择已安装的调试提供方，单独填写 DAP 地址、请求种类和适配器 JSON 参数；不猜测语言协议，不启动本地替代进程。Core 先校验地址，非回环端点每次连接前确认，明确警告裸 TCP 没有加密或认证；确认时间不计入网络建连期限。
- 外部服务只归用户所有。关闭 socket 不停止共享语言服务器、外部适配器、目标程序或用户隧道；DAP `attach` 的目标结束策略仍由现有协议层负责。配置不持久化，源码映射继续由适配器参数表达。

正确：把用户已配置的隧道最终地址填为 DAP 端点，Lithe 只连接它，停止时只关闭自己的连接。

不要：把远端 `gdbserver` 或 JVM JDWP 地址填成 DAP 地址，或在连接工厂中私自启动 `ssh -L`、停止用户已有隧道。

## 考虑过的备选方案

- **在旧端口传输上直接放开主机限制。** 缺少独立来源与确认，而且不能保护旧回环信任边界；改为保留端点来源并共用底层生命周期。
- **为外部 DAP 新写一个 TCP 传输。** 取消、缓冲和晚到回调会出现两套规则；改为端点解析与连接建立分开复用。
- **本轮同时实现代理或统一成 SSH。** 认证、身份校验、共享隧道和辅助进程归属还需要独立设计；没有 SSH 也可以直连或经过用户的 VPN，不把 SSH 当作必要前提。

## 后果

普通 TCP 连接可独立测试，stdio 原有路径不变，用户提供的外部地址与语言服务器端口遵守各自的信任边界。代价是外部连接需要用户了解其适配器参数，没有保存配置、通路自动建立或断线恢复；插件 `tcpPort`、`tcpAnnounced` 的托管进程模式也仍未实现。

此处代码实现不等于所有语言适配器都已验收。真实 JVM、debugpy、GDB 的兼容性仍需对应插件和端到端场景证明；Windows 只共享地址校验，尚无本次宿主 TCP 实现。

外部入口复用当前文件的调试提供方索引，该索引仍只选择支持文件启动的插件（Java 使用宿主提供方）。因此本次不支持单独发现仅附加进程、可执行文件或其他非文件型插件；不要把 TCP 字节流可用等同于这些插件的产品入口已经接通。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'TCPDebugAdapterTests|PluginDebugAdapterTests|DebugModuleTests'`：覆盖可控时钟、队列预算、取消与晚到回调、确认顺序、会话选路；临时回环监听器验证双向字节以及真实 Core 的 initialize/attach 帧往返，监听服务不随客户端停止。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core debug_adapter_endpoint` 和 `cargo test --manifest-path rust/Cargo.toml -p lithe-core dap_endpoint_contract`：共享 fixture 校验及 JSON dispatcher 边界。
- `./scripts/verify-shared-contracts.sh`、`./scripts/verify-runtime-bundle-immutability.sh`、`./scripts/verify-agent-notes.sh`。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Debug/`
- `macos/Sources/LitheDebugModule/Runtime/DebugAdapterSessionManager.swift`
- `macos/Sources/Lithe/Views/Debug/ExternalDebugAdapterView.swift`
- `rust/lithe-core/src/debug/endpoint.rs`
- `shared/fixtures/debug/adapter-endpoints-v1.json`
