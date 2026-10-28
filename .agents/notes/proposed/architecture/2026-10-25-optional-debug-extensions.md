# Agent 笔记：可选调试扩展

状态：提议中

## 先说结论

除断点、线程与调用栈、变量这些必选能力外，调试功能都是**可选扩展**：寄存器、内存、反汇编、反编译源码、条件断点、子会话等。每个扩展都挂在[统一调试内核](2026-10-25-unified-debug-engine-and-adapter-registry.md)上，由三部分组成：内核请求处理器、它允许内核声明的客户端能力、平台界面入口。扩展各自排期、各自验收，都不是 #1210 的关闭条件。

某个功能是否可用，由三个条件同时决定：适配器在 DAP 协商中声明支持、本平台已注册对应扩展、操作已获授权。插件清单不逐项声明这些功能，最多用 `capabilities.disabled` 关掉一项。

## 问题

GDB、LLDB 可以调试 C、C++、Rust 和汇编，但二进制不一定有源码或行号；Java 调试器可以返回反编译源码；js-debug 会发起子会话。这些功能在 DAP 里都是可选的，不同适配器支持的组合各不相同。如果为了显示它们去改必选层的数据结构，或者按适配器名称写分支，每接一个调试器就要改一次宿主。

现在 Rust Core 已经实现 `setVariable`、各类断点（含数据断点）、`stepBack`、`runInTerminal`，以及原生调试分组里除 `writeMemory` 以外的全部请求（`readMemory`、`disassemble`、`setInstructionBreakpoints`、指令粒度单步，见“原生调试的落地”）；尚未实现 `writeMemory`、`modules` 和 `loadedSources`。`startDebugging` 子会话已在宿主与 Core 统一（见统一调试内核笔记）。

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

### 原生调试的落地（macOS）

寄存器、反汇编、只读内存、指令步进与指令断点按上面的顺序一次落地，`writeMemory` 保持关闭。边界如下：

- **内核**：`debug.inspect` 新增 `disassemble`、`readMemory` 两个 kind；`debug.execute` 新增可选 `granularity`；新增命令 `debug.setInstructionBreakpoints`。四项适配器能力 `supportsDisassembleRequest`、`supportsReadMemoryRequest`、`supportsSteppingGranularity`、`supportsInstructionBreakpoints` 都已注册为扩展，所以 `initialize` 现在声明 `supportsMemoryReferences`；能力快照里 `supported = 适配器 ∧ 已注册 ∧ 已授权` 不变。栈帧新增 `instructionPointerReference`，没有 `source` 也没有 `sourceReference` 的帧行号为 0，不再补成第 1 行。两个新 kind 都是引用型请求，受 `stopGeneration` 约束，继续执行后到达的旧回复按 `StaleReference` 丢弃。字段细节见 `shared/contracts/rust-core-api.md`。
- **地址不透明**：宿主任何一层都不把地址解析成整数，也不做加减。反汇编向前后翻页用 `instructionOffset` 加上当前首尾指令的地址；内存分页用相对 `memoryReference` 的字节偏移，行首标签显示偏移而不是算出的地址。判断两个地址写法是否同一个地址，只做文本规范化（小写、去 `0x`、去前导零），所以 `0x0000000100003f50` 与 `0x100003f50` 视为同一个地址，超过 2^53 的地址不会被舍入。
- **界面**：只有 `supportsDisassembleRequest` 为真才出现“反汇编”标签。选中的栈帧没有源码时标签自动打开，选中有源码的帧时自动关闭；用户自己打开的反汇编不会被自动关闭。标签下方是辅助区：变量、寄存器（只在适配器给出 `presentationHint: "registers"` 的 scope 时出现）、内存（只在 `supportsReadMemoryRequest` 为真时出现）。无源码栈帧的行内显示等宽的指令地址，右键菜单可复制地址、打开反汇编；变量右键可以按其值读取内存。
- **指令步进**：反汇编标签打开期间，单步（步过）和步入带 `granularity: "instruction"`；工具栏按钮的悬停提示同步变为“按指令单步跳过 / 按指令单步进入”，反汇编头部显示“按指令单步”，当前行随单步最小幅度滚动，不整列表跳动。步出仍按适配器默认处理，因为“跑完当前函数”没有指令粒度的含义。关闭标签后回到适配器默认的按行单步。适配器没有声明 `supportsSteppingGranularity` 时不带该字段，头部改为明确提示“该适配器不支持按指令单步，单步仍按源码行前进”：静默回退会让用户以为是反汇编视图的缺陷。
- **指令断点**：在反汇编地址栏点击设置或移除，只属于当前会话，不写入持久化，也不在新会话重放：同一段代码下次运行时位于另一个地址（ASLR）。适配器声明 `supportsInstructionBreakpoints` 才显示入口；适配器报告断点未生效时，圆点显示未验证状态，悬停提示是适配器的原文说明。
- **内存**：输入框接受 `0x…` 地址，或在选中栈帧里求值后得到地址的表达式（寄存器名、保存着指针的变量）。表达式的值不是地址时显示“该表达式的值不是地址”，适配器的错误原样显示。读取失败的尾部字节在界面上标为无法读取，不显示成 00。
- **内存的显示与定位**：输入地址后首次读取从目标地址前 64 字节开始（`offset: -64`），目标字节所在的十六进制格和 ASCII 字符同时高亮并滚入可见区；适配器不支持负偏移，或前面不是已映射区域（读取失败）时，退回从目标地址读起，不报错。首行标签是相对 `memoryReference` 的偏移，不是算出的地址。右侧的显示设置（进制、每格字节数 1/2/4/8、每行字节数、字节序、是否显示 ASCII）只改变展示，不改变读取请求，也不写入持久化。单步后的静默重读只标出相对上一页变化的字节，不改变滚动位置；翻页也不滚动到目标，只有用户主动读取才滚动到目标字节。
- **单步时的局部刷新**：`next`、`stepIn`、`stepOut`、`stepBack` 之后，线程、调用栈、变量、反汇编、内存和 JSON 视图保持原样并标为过期（只读，不能编辑变量或 Watch），新的停止到达后再原地替换：先后拉取线程、调用栈、同名作用域、变量，按名称路径恢复已展开的节点，变量树整体提交后才替换旧树，所以不会出现整块清空再重画。`continue`、`pause`、终止和失败仍按原来的方式整体清空；栈为空、没有可用线程或会话结束时放弃保留。选中另一个栈帧不属于单步，不走保留逻辑；此时 JSON 视图会短暂显示上一个快照再更新，这是接受的代价。反汇编列表只在当前指令不在已加载范围内时重新定位，快到列表末尾（剩余 ≤8 行）时向后补页。
- **取消和只读的时机**：开始保留画面时就冻结变量树，不能等新作用域返回才冻结，否则暂停事件与作用域返回之间会把旧引用恢复成可编辑。取消会同步调用失败回调，所以必须先推进反汇编、内存请求的代次，再取消会话里的请求；失败重试也必须检查代次，不能在切换会话后向旧会话补发请求。传输失败时清空所有保留画面，不把上一个暂停点的数据显示成当前值。内存行偏移相对请求的 `memoryReference`，表头必须显示这个引用，而不是适配器返回的页首 `address`。
- **仍然关闭**：`writeMemory`。读取能力不代表允许写入，写入需要独立的授权和确认用例，见上面的“写操作单独授权”。

### 真实适配器验证（Xcode `lldb-dap`）

用 `-g` 编译的 C 程序和 Xcode 自带的 `lldb-dap` 实测，结论如下：

- `initialize` 声明了 `supportsDisassembleRequest`、`supportsReadMemoryRequest`、`supportsSteppingGranularity`、`supportsInstructionBreakpoints`，也声明了 `supportsWriteMemoryRequest`。适配器支持写内存不影响 Lithe 的边界：写入没有注册为扩展，客户端不开放，能力快照里它保持不可用。
- 在 `main.c:8` 设行断点停住后连续单步：`next` / `stepIn` 带 `granularity: "instruction"` 每次只前进一条指令（arm64 每次 PC +4，源码行仍是 8）；`granularity: "line"` 才会走到第 9 行。这说明“看起来还是代码级单步”是界面没有提示造成的，内核发送的粒度本来就对。
- 没有 `-g` 的二进制里，在函数或文件上设的断点不会绑定；这类程序在 `main` 之前没有可停的位置。要在反汇编里选定位置停下，用带调试信息的程序：先用行断点停住，再点击后面指令的断点栏，然后继续执行。指令断点只属于当前会话，下次运行地址会变（ASLR）。
- 地址有大小写和前导零的差异（`0x10000049C` 与 `0x10000049c`），所以比较地址只做文本规范化，不做数值运算。
- 直接 `swift build` 得到的是没有链接 Rust Core 的二进制，调试和打开文件都不可用；本地验证要用 `scripts/build-macos.sh --configuration debug --triple arm64-apple-macosx` 构建，把产物放进开发包并重新签名（开发包标识 `app.lithe.desktop.dev`，数据目录与正式版分开）。
- 两轴滚动里的文本如果不用 `fixedSize(horizontal: true, vertical: false)`，宽度会塌成 0，反汇编列表整行看起来是空的。
- JSON 视图顶部的空白条来自复制按钮单独占一行；改成浮在第一行右侧、各行右侧留出按钮宽度，并按键、字符串、数字、关键字分色。

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
