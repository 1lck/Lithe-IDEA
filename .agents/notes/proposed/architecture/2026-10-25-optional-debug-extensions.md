# Agent 笔记：可选调试扩展

状态：提议中

## 先说结论

除断点、线程与调用栈、变量这些必选能力外，调试功能都是**可选扩展**：寄存器、内存、反汇编、反编译源码、条件断点、子会话等。每个扩展都挂在[统一调试内核](2026-10-25-unified-debug-engine-and-adapter-registry.md)上，由三部分组成：内核请求处理器、它允许内核声明的客户端能力、平台界面入口。扩展各自排期、各自验收，都不是 #1210 的关闭条件。

某个功能是否可用，由三个条件同时决定：适配器在 DAP 协商中声明支持、本平台已注册对应扩展、操作已获授权。插件清单不逐项声明这些功能，最多用 `capabilities.disabled` 关掉一项。

## 问题

GDB、LLDB 可以调试 C、C++、Rust 和汇编，但二进制不一定有源码或行号；Java 调试器可以返回反编译源码；js-debug 会发起子会话。这些功能在 DAP 里都是可选的，不同适配器支持的组合各不相同。如果为了显示它们去改必选层的数据结构，或者按适配器名称写分支，每接一个调试器就要改一次宿主。

现在 Rust Core 已经实现 `setVariable`、各类断点（含数据断点）、`stepBack`、`runInTerminal`；尚未实现 `readMemory`、`writeMemory`、`disassemble`、`setInstructionBreakpoints`、指令粒度单步、`modules`、`loadedSources` 和 `startDebugging`。macOS 的 Node 子会话目前在 Swift 会话里实现。

## 提案

### 扩展分组

| 分组 | DAP 请求与能力 | 内核允许声明的客户端能力 | 界面入口 |
| --- | --- | --- | --- |
| 断点增强 | 条件断点、命中次数、日志点（`supportsConditionalBreakpoints`、`supportsHitConditionalBreakpoints`、`supportsLogPoints`）；`setFunctionBreakpoints`；`setExceptionBreakpoints` 与过滤项；`dataBreakpointInfo` / `setDataBreakpoints` | — | 断点编辑、异常过滤、监视点 |
| 表达式与变量 | `setVariable`、`setExpression`、`completions`；变量的 `presentationHint`（只读、懒加载） | `supportsVariableType` | 变量编辑、控制台补全 |
| 执行控制增强 | `stepBack` / `reverseContinue`、`restart`、`restartFrame`、`gotoTargets` / `goto`、`stepInTargets` | — | 工具栏与栈帧菜单 |
| 无源码与生成代码 | `source`（`sourceReference`）；`loadedSources` | — | 只读源码标签页 |
| 原生调试 | 寄存器（scope 的 `presentationHint: "registers"`）；`readMemory` / `writeMemory`；`disassemble`；`setInstructionBreakpoints`；`granularity: "instruction"` 单步 | `supportsMemoryReferences`、`supportsInvalidatedEvent`、`supportsMemoryEvent` | 寄存器、内存、反汇编视图 |
| 进程与模块 | `modules`；`startDebugging` 子会话；`runInTerminal`；`attach` 到进程列表 | `supportsStartDebuggingRequest`、`supportsRunInTerminalRequest`、`supportsProgressReporting` | 模块列表、子会话树、终端 |
| 语言专属 | Java 热替换（`redefineClasses`）等非标准请求 | 由内置 Provider 描述列出 | 由对应扩展提供 |

### 反编译与反汇编是两件事

- **反编译**由适配器完成：例如 Java 调试器从 jar 里的 class 生成源码，通过 `sourceReference` 返回文本。宿主只用只读标签页显示它，不自己反编译。
- **反汇编**是 `disassemble` 请求，返回指令列表，属于原生调试分组。

两者使用不同的界面，也分别验收。

### 无源码位置

- 栈帧可以没有 `source`、`line`、`column`，只有名称和 `instructionPointerReference`。界面显示“无源码”，有反汇编扩展时可以跳到反汇编视图；不伪造文件，也不跳到第 1 行。
- 源码身份三选一：工作区相对路径、会话内 `sourceReference`、已授权的外部路径。会话结束后 `sourceReference` 失效，标签页转为只读快照或关闭。
- 地址和引用（`instructionPointerReference`、`memoryReference`、`address`）都是不透明字符串，宿主不做算术。确实需要偏移时，由内核按字符串解析为 128 位以内的整数，再生成新字符串。

### 寄存器

寄存器直接使用适配器给的 scope：按 `presentationHint: "registers"` 筛选，适配器没给提示时按普通 scope 显示。宿主不内置任何 CPU 的寄存器表，也不按架构名写分支。

### 写操作单独授权

`writeMemory`、`setVariable`、`setExpression`、热替换都会修改被调试程序。读取能力不代表允许写入：写入类扩展各有独立的授权与确认规则，且只有对应的用例通过后才开放。具体权限名在实施时按能力版本规则申请。

### 引用失效

栈帧、变量、内存、反汇编结果都绑定会话 ID 和暂停代次。继续执行、单步、重启后，界面重新获取；收到 `invalidated` 或 `memory` 事件时，只刷新受影响的区域。晚到的旧结果直接丢弃。

### 实现顺序建议

1. 断点增强、表达式与变量：Rust Core 已有实现，迁到新内核后补界面即可。
2. 无源码与生成代码：Java 反编译源码和 Node eval 代码依赖这一组，同时也是原生调试的前提。
3. 进程与模块：`startDebugging` 要先于删除 Swift 会话完成，否则 Node 子会话会回退。
4. 原生调试：寄存器 → 反汇编 → 只读内存 → 指令断点与单步 → 写内存。

第 3 项实际上是 P5 删除旧路径的前置条件：Node 子会话迁到新内核之前，不能删 Swift 会话。

### 正确做法

- 新增反汇编：内核注册 `disassemble` 处理器，两端增加视图，入口只看能力快照里的 `supportsDisassembleRequest`。GDB、LLDB 自动获得，插件不改。
- 断在没有符号的函数里：调用栈显示函数名和地址，编辑器保持原位；打开反汇编视图后定位到当前指令。

### 不要这样做

- 为了让旧解码器能用，给无源码帧填一个假路径和第 1 行。
- 在宿主里内置 x86 / ARM 寄存器表，或者按 `adapterID` 判断是否显示内存视图。
- 已经能读内存，就顺带允许写内存。
- 适配器没有声明支持时仍显示入口，等用户点了再报错。

## 考虑过的备选方案

- **把原生调试放回 #1210：** 会把 Registry 接入和新界面、权限、多架构验证绑在一起，拖慢必选层落地。已拆出。
- **插件用函数实现扩展：** 插件函数不能实现领域操作，而且会让同一个 DAP 请求出现两条执行路径。扩展只做宿主内核模块。
- **自研反汇编器或内存解析：** 重复上游已有的能力，并且受架构限制。只显示适配器返回的结果。

## 验收标准

- 每个分组单独验收，至少用一个声明支持的真实适配器在两个平台各跑一次；不支持的适配器上，界面入口隐藏，或明确显示为不可用。
- 未注册扩展时，initialize 不声明对应的客户端能力，适配器也不会发来相关引用。
- 无源码帧、超过 2^53 的地址、`sourceReference` 会话结束后失效、继续执行后引用失效、未知 `presentationHint`，都有共享 fixtures，三端解码一致；不出现假跳转。
- 写入类操作有独立的授权和确认用例，拒绝时不发出请求。
- 进程与模块分组通过 Node 子会话的现有基线后，才允许删除 Swift 会话。

## 风险

- GDB 是否带 DAP 取决于版本和构建方式；系统调试授权（macOS 的调试权限、Windows 的进程访问权限）和指令集差异会限制原生调试，未验证的组合保持不可用。
- 适配器声明了能力但实现不完整时，要按请求失败显示错误，不能让会话卡住；所有扩展请求都有期限，并且可以取消。

## 验证

本次只修改文档，运行 `./scripts/verify-agent-notes.sh`，不提供运行时证据。实施时加载 `write-stable-tests`，增加 `shared/fixtures/debug/*-v2.json`，运行 `./scripts/verify-shared-contracts.sh`、`./scripts/verify-rust-core.sh` 和对应平台测试；更新功能矩阵，真实调试流程结束后清理本次启动的进程和资源。

## 适用范围

- `rust/lithe-core/src/debug/`
- `shared/fixtures/debug/`
- `shared/proposals/debug-adapters-1210/`
- `macos/Sources/LitheCoreContracts/Debug/`
- `macos/Sources/LitheDebugModule/`
- `windows/tauri/src/features/debugger/`

## 依据

- [统一调试内核与调试适配器 Registry](2026-10-25-unified-debug-engine-and-adapter-registry.md)
- [DAP 规范](https://microsoft.github.io/debug-adapter-protocol/specification)、[GDB DAP](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html)、[LLDB DAP](https://lldb.llvm.org/use/lldbdap.html)
