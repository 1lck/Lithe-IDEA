# Agent 笔记：共享 ACP Agent 对话

状态：已实现

## 先说结论

Agent 对话默认关闭，用户启用后才显示入口，发送第一条消息时才启动本机 Agent。ACP（Agent Client Protocol，编辑器与 Agent 之间的对话协议）连接和子进程由同一个 Rust crate 管理；Mac 与未来的 Windows 界面分别实现。

## 问题

如果两端各写一套 ACP 连接、权限回复与进程清理，协议行为容易分叉。若在应用启动时构造会话，未使用该功能的用户也会承担后台内存和进程开销。Agent 还会请求执行工具，权限必须经由用户确认。

## 决策

- `rust/lithe-agent-host` 使用官方 `agent-client-protocol` SDK，负责 ACP v1 初始化、会话、消息、工具权限、取消及子进程树清理。Rust Core 的 C ABI 供 Mac 调用；Windows 后续直接依赖同一 crate。
- `LitheAgentConversationModule` 是内置可选模块，默认禁用、按需激活；模块资源登记会话并在禁用或应用会话结束时停止。它不是需要独立安装的插件包。
- Mac 的 `MacACPAgentTransport` 只负责 C ABI 桥接。功能模型管理对话状态；SwiftUI 只负责显示消息和收集用户输入。工作区切换时模块图关闭，旧 Agent 必须退出。
- 项目标签或窗口焦点使项目会话失活时，也要立即从功能模型摘除旧 Agent 会话，并异步结束其进程。切回标签后新消息创建新会话，不能继续使用旧项目的运行中进程。
- ACP 事件字段使用 `shared/fixtures/agent/acp-events-v1.json` 的 camelCase 契约。取消当前轮时拒绝待处理权限；Agent 若在短暂宽限期内未结束，宿主停止整个会话，避免界面长期停留在取消状态。
- 用户自行安装 ACP Agent，并在设置里配置可执行文件与逐行参数。参数直接传给进程，不经 shell 展开。首版不自动下载 Agent，也不保存对话记录。

正确做法：新平台 UI 通过其平台适配器调用 `lithe-agent-host` 的同一会话能力，并把工具权限选择交给用户。不要在 Windows React 层重新实现 JSON-RPC 协议，也不要在仅打开 IDE 时启动 Agent。

## 考虑过的备选方案

### 两端各用平台语言实现 ACP

UI 开发起步较快，但会重复实现连接、取消、权限与进程树清理，长期维护成本高。

### 整体复用 Codeg

Codeg 提供可参考的 ACP 产品实现，但其工作台、状态与发布方式不适合直接嵌入 Lithe。采用官方 SDK 可复用协议实现，同时保留 Lithe 自身的模块生命周期。

### 将所有代码放进插件包

插件包仍需调用宿主的原生进程能力，且两端 UI 无法共用。内置模块已经提供默认禁用和资源清理所需的生命周期。

## 后果

两端以后共享协议和清理逻辑，关闭功能时不持有 Agent 进程。代价是 Rust C ABI 与模块目录成为兼容面；Mac 与 Windows 的 UI 仍需分别维护，且首版需用户自行安装兼容 Agent。

## 验证

- `cargo test -p lithe-agent-host --manifest-path rust/Cargo.toml`
- `shared/fixtures/agent/acp-events-v1.json` 同时由 Rust 序列化测试和 Swift 功能模型测试读取。
- `./scripts/verify-module-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- Mac 实机验证启用、消息流、权限选择、取消、禁用及切换工作区后的进程退出。

## 适用范围

`rust/lithe-agent-host/`、`rust/lithe-core/src/runtime/ffi.rs`、`macos/Sources/LitheAgentConversationModule/`、`macos/Sources/Lithe/Platform/MacOS/Agent/`、`shared/contracts/application-boundary.md`。
