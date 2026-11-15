# Agent 笔记：Windows React/Tauri 产品对齐完成度

状态：已否决：Viva 工作台取代 React/Tauri 客户端，旧迁移路线不再适用。

## 先说结论

原提案要求继续完善 Windows React/Tauri 客户端；当前重构改为使用 Viva 工作台，因此不再按这份旧路线实施。用户能力与真实 Windows 验收仍然需要完成，当前状态以跨平台功能矩阵为准。下文保留当时的提案与取舍，不代表 Viva 已完成对应功能。

## 问题

Windows 已经完成从 Qt/C++ 到 React/Tauri 的地基迁移（工作台、编辑器、
终端、设置、Git、搜索、扩展、viewer 和 workspace 状态都在
`windows/tauri/src` 下，`core_execute`/`core_cancel` 暴露完整共享
协议，命令翻译收在 `platform.rs`），但产品功能还没有全部对齐共享
Core 契约，也还没有在真实 Windows 机器上跑过完整回归。继续把功能
迁过去之前，需要一份明确的、可核对的剩余工作清单，否则容易出现
"表面上迁移完成，实际上某个功能仍是硬编码或伪造成功值"的状态。

## 否决理由

本仓库已移除 React/Tauri 客户端，继续针对该客户端实现或运行旧检查无法验证 Viva 产品。原提案中的共享契约、真实 Windows 测试和不伪造成功等原则仍适用，应落实到当前桌面代码和 Core，而不是恢复已移除的客户端。

## 提案

按共享契约把以下功能对齐：

1. 让每个 Git 功能 API 对齐稳定的 `git.*` command DTO。
2. 把 workspace 搜索、Local History、非 Java 的剩余 LSP、Java/Maven
   和运行配置都路由进同一个 dispatcher。内置 Java LSP 已经能通过
   Windows host（`jdtls` + JDK discovery）和带 `providerId: "java"`
   的 `lsp.startServer` 启动；Spring 配置、`@Value` 和 bean 注入导航
   在回退到 LSP 之前先用 `spring.index`。
3. 在 Rust 中实现 Windows 专属的进程、调试、更新和安全存储流程，
   替换当前 UI 里还在用其他方式实现的部分。
4. 对尚无共享后端的未来功能面，先隐藏或做能力开关，不要展示一个
   连不上后端的入口。
5. 在真实 Windows 机器上跑完整的 UI、WebView2、ConPTY、安装器、
   签名和升级回归。

## 考虑过的备选方案

- **继续在 Windows UI 里为未对齐的功能保留独立的伪造/本地实现，
  等以后有空再迁移**：短期内功能看起来完整，不阻塞其他开发。但会
  重新引入两套并行行为（Windows 一套，macOS/共享契约一套），后续
  对齐时无法确定哪份是权威实现，且用户可能已经依赖了不受契约保证
  的行为，因此改为"没有共享实现就显式失败"而不是伪造成功。
- **不等 Rust 实现 Windows 专属的进程/调试/更新/安全存储，先用
  Tauri/Node 生态的第三方库垫上**：能更快让功能可用。但会绕开
  `Lithe-core-rust/rust/contracts/` 的错误码、取消、超时和陈旧结果语义，且这些
  库的行为很难和 macOS 对应能力保持一致，因此仍然要求这些流程落在
  Rust 里、复用共享契约的语义。
- **在真实 Windows 机器上的回归推迟到功能全部迁移完成后再一次性
  做**：能减少来回搭建 Windows 测试环境的次数。但 WebView2、ConPTY、
  安装器和签名这类平台细节的问题通常只能在真实 Windows 上暴露，
  一次性到最后才测会让问题定位和修复的反馈周期变得很长，因此要求
  完成度判定里包含这一项，不能只看跨平台边界检查通过。

## 验收标准

- `bun run typecheck` 和 `bun run build` 在 `windows/tauri` 下通过。
- Windows Tauri crate 能格式化、构建并通过测试。
- [旧版 Windows 边界检查脚本](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/scripts/windows/verify/verify-windows-boundaries.sh)
  和它的 PowerShell 对应版本
  [旧版 PowerShell 检查脚本](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/scripts/windows/verify/verify-windows-boundaries.ps1)
  通过。
- Windows CI 能构建出真实可执行文件，并同时测试 `lithe-core` 和
  Tauri host。
- 产品工作流按
  [`Lithe-core-rust/rust/contracts/application-boundary.md`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/application-boundary.md)
  的要求暴露错误、取消、超时和陈旧结果处理。
- 上述"提案"里的 5 项工作全部完成，且在真实 Windows 机器上跑过一轮
  完整回归。

## 风险

- Java/Maven、运行配置等功能涉及的共享契约本身也在演进，如果契约
  变化速度快于 Windows 对齐速度，这份清单需要跟着重新核对，而不是
  假设契约已经稳定。
- 只有 macOS/Linux 上能跑 `verify-windows-boundaries.sh`，真正的
  WebView2/ConPTY/安装器/签名回归依赖真实 Windows 机器；如果长期
  没有 Windows CI 或机器可用，"完成"状态可能只验证了跨平台边界，
  没有验证平台实现本身。
- "没有共享实现就显式失败"如果落地不彻底（某些路径悄悄保留了旧的
  伪造成功值），会让用户在 Windows 上得到和 macOS 不一致但看起来
  正常的结果，需要靠架构搜索或专项测试而不是人工审查发现。

## 适用范围

- `desktop/`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/application-boundary.md`
- `shared/platform-feature-matrix/`
- [旧 Windows 客户端（历史版本）](https://github.com/1lck/Lithe-IDEA/tree/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/windows/tauri)
