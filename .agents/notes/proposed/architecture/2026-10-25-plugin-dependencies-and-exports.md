# Agent 笔记：插件依赖、导出与跨包授权的独立设计范围

状态：提议中

## 先说结论

插件之间复用运行时、JSON 声明和计算能力属于整个插件平台，不应由某个 Debug 格式顺带定义。本提案从 [Debug #1210](https://github.com/1lck/Lithe-IDEA/issues/1210) 拆出依赖、导出和授权，挂在[公共扩展契约](2026-10-13-public-extension-contract-and-provider-api.md)下；Debug 的 Registry 与第三方 DAP 接入不依赖它。

方向仍是插件好写、共享逻辑尽量复用，但安装闭包（某个插件及其全部间接依赖）、版本冲突和信任必须先有明确规则。其中**第一阶段已经落地**：两个已安装、已启用的插件之间，可以经 Rust Core 中转调用被明确导出的函数（见提案第 5 节）。其余仍只是待单独实施的决策边界：安装依赖、版本范围解析、依赖闭包、跨包资源租约和工作流字段都没有开放，`pluginDependencies` 也不存在。

## 问题

上一版 Debug 草案把依赖、导出、跨包函数和顺序工作流放进专用注册格式，却没有回答安装和卸载如何影响其他插件。仅校验引用存在不能处理菱形冲突（两个依赖分支要求同一个插件的不兼容版本），也不能证明社区调用方有权启动官方依赖里的程序。

现有市场已经负责平台、版本、来源、签名和安装确认，插件函数已经规定私有归属。新的复用机制必须扩展这些所有者，而不是增加第二个安装器、进程表或函数路由器。

## 提案

### 1. 先解决安装和失效，再开放导出调用

| 主题 | 拟采用的规则 |
| --- | --- |
| 插件身份与来源 | 依赖绑定插件 ID、允许版本范围及获准来源/发布者；不能仅按 ID 从任意市场寻找同名替代 |
| 安装解析 | 市场先按平台、宿主能力及信任策略过滤版本，再求整个依赖闭包；下载前展示统一计划，验证包内依赖与索引一致 |
| 单版本约束 | 同一插件 ID 只安装一个版本。多个范围取交集；交集为空就拒绝本次安装或更新，并显示两条冲突路径，不自动降级或替换其他已安装插件 |
| 固定结果 | 安装计划固定每个包的版本、来源和内容哈希；执行前重查目录快照。闭包全部准备、校验完成后一起发布，失败恢复旧闭包，不留下半安装状态 |
| 更新 | 显式更新重新计算所有受影响的反向依赖；旧约束不满足时整笔拒绝。用户可以另行批准一组兼容更新，不暗中更新无关插件 |
| 禁用与卸载 | 先算反向依赖闭包，提示受影响的插件。默认拒绝破坏仍启用的依赖方；用户确认后先停依赖方操作和资源，再禁用/卸载目标 |
| 启动时发现缺失 | 保留依赖方安装记录，标记阻塞及具体原因，不启动后端；恢复依赖后重新校验再允许激活 |
| 循环与预算 | 安装依赖和声明导出引用分别检查循环、深度及总量；具体上限、稳定错误码、并发安装锁与崩溃恢复日志是正式契约的前置验收 |

第一版先不加入弱依赖、可选依赖和并存多版本，避免不能证明的解析语义。运行时动态缺失不是静默选择其他依赖版本的理由。

### 2. 信任不沿依赖关系传递

每个包独立验证签名、哈希、来源和 namespace。社区插件依赖官方包不会因此变为官方插件，官方包的签名也不是对调用方的背书。安装确认展示闭包新增包、各自权限、来源以及哪些公开导出将被调用；不能把间接依赖藏在顶层插件的一行名称后面。

若未来导出可以执行程序，审查必须同时展示调用者、资源所有者和实际执行的包/命令。被依赖方拥有可执行资源与进程生命周期，宿主依据导出用途、本次用户动作、工作区信任和双方授权批准执行；依赖方不能通过传路径替资源所有者更换程序。依赖更新后的资源也要重做来源、签名、权限和计划代次检查。

权限不做简单并集，也不能简单取交集后假装已解释语义：每个导出必须定义可接受的调用上下文及所需操作授权。某个导出没有这种定义时，不允许跨包调用，即使两个包都已安装。

### 3. 导出是明确选择的契约，不是公开全部函数

复用对象可以是只读声明、运行时描述或有类型的操作，但不能直接公开依赖包的私有函数表。包版本回答“装哪版”，导出契约版本回答“交换什么输入和结果”；不可兼容的变更需要新导出契约。

若需要跨包资源引用，正式契约使用显式带标签的类型，例如专门的 backend/lease 变体；不靠普通参数恰好叫 `backendRef` 来识别。宿主签发的租约记录资源所有者、调用链、操作与失效代次，跨包只传受限引用；`${pluginDir}` 永远按声明资源的包解析。用户参数里的同名字符串和对象仍然只是数据。

跨包操作只能在已授权的导出边界调度到资源所属会话，不能将调用方 pluginID 写入目标会话。（第一阶段由 Rust Core 在导出边界中转，宿主只负责启动被调方后端；调用方 ID 只出现在 Core 填写的 `caller` 请求字段里。）后端回调宿主重新进入注册表的禁止规则保留；否则等待中的处理器可能等待自己。如何将新授权模型加入函数路由、如何区分私有与公开调用，需要单独版本化，不能删除旧 `wrongPlugin` 或 `recursiveCall` 检查来实现。

### 4. 不在此处偷改已实现决策

[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)仍是当前行为真源：函数默认私有，领域结果走类型化契约。第一阶段在它的决策 8 里增加了“明确导出的函数可经 Core 中转被另一个插件调用”，同一 PR 给出了输入/结果、错误优先级与兼容 fixtures；私有、递归和领域结果走类型化契约的规则没有改动。以后若采用函数传输领域结果，或让导出带上依赖闭包、资源租约，仍须先在实现 PR 中修订对应决策，再改 Core 和双端宿主。

新的字段属于统一 `plugin.json` 的能力演进；基础权限或身份语义变化需要新的基础 API。没有 Debug draftVersion，也不要求现有 Build/VCS/UI/语言插件迁移。现有 `backend: 1` 的全局、网页触发行为不变；新的进程共享方式另行版本化。

通用 workflow 尚无证明必要的真实输入，不在这个依赖提案里重新引入 steps 或取值语言。先通过实际导出契约完成复用，再判断是否有需要由宿主解释的公共流程。

### 5. 第一阶段已落地的部分

对应计划 API-35 的第一阶段，不新增 API 编号，决策正文写在[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)的决策 8，契约写在 `Lithe-core-rust/shared/plugins/contract/v1/README.md` 的 “Cross-plugin calls (protocol version 4)”。它只落地了本提案里不依赖安装解析的那一部分：

- 清单新能力键 `requires.pluginFunctions: 1` 与顶层 `pluginFunctions {exports, calls}`。导出是 `{id, version, context}`，`context` 是封闭集合，第一阶段只有 `"workspace"`，缺失或未知就拒绝整个清单：这兑现了第 2 节“没有定义可接受调用上下文的导出，不允许跨包调用”。调用方只声明 `{id, version}`，版本必须相等，不相等是 `plugin.function.versionMismatch`。
- 协议 `litheFunctions` 增加版本 4，只有协商到 4 的后端能用 `lithe/host/functions/providers` 与 `lithe/host/functions/invoke`。运行时发现被调方，清单里不写被调方的插件 ID。
- 所有检查在 Rust Core：声明、导出、双方启用、版本、调用链（拒绝 A→B→A 和自己调自己）、深度、每个调用方的并发、参数与结果大小、超时、沿链取消，远程工作区拒绝（API-40）。被调方未运行时 Core 只发 `functionProviderStartRequired`，宿主把它当作 I/O 去启动后端，超时即失败。
- 信任不传递：被调方用自己的权限运行，Core 不把调用方的插件 ID 写进被调方的会话身份，只在转发的请求里加一个由 Core 填写的 `caller: {pluginID}` 字段；契约要求导出函数不得接受调用方传来的可执行路径或命令。没有新增权限项，`calls` 声明加 `exports` 选择加入就是双方的同意。
- 安装、更新、卸载、启用、禁用即时更新发现结果，进行中的调用以明确的错误结束；带后端的插件在 macOS 上仍只在启动时注册，新安装或更新的后端插件要重启后才出现在发现结果里（属于 #1515 的后续工作）。
- 旧的 `plugin.function.wrongPlugin` 与 `plugin.function.recursiveCall` 检查一个都没有删除。

**没有落地**：安装时解析依赖、版本范围与冲突报告、依赖闭包和事务恢复、卸载或禁用时的反向依赖提示、启动时发现缺失依赖并标记阻塞、跨包资源租约和带标签的资源引用类型、会启动程序的导出、弱依赖和多版本并存。这些仍按本提案的待办和验收标准单独实施；第一阶段也不引入任何安装期的依赖声明，被调方是否已安装完全由运行时发现。

### 正确做法与反例

正确做法：两个插件依赖同一个运行时，安装器先求兼容版本并展示共同资源的来源与权限，宿主只对获准导出执行调用。

反例：社区插件依赖官方运行时后，自动继承官方身份和全部权限；或冲突时静默换掉另一个已安装插件的依赖。签名和版本检查都不能支持这种行为。

## 考虑过的备选方案

- 每个领域自己定义依赖和安装：短期好实现，但同一插件的版本、信任和卸载会出现多套答案，不采用。
- 同 ID 多版本并存：可缓解菱形冲突，但影响设置、存储、市场、UI 身份和进程共享，第一版不承担这一范围。
- 依赖即授权、所有函数自动导出：声明短，但让社区包借到依赖方权限，破坏现有私有契约，不采用。
- 只允许声明复用，不允许动态导出：更易验证，可作为第一阶段；是否增加动态操作须由真实插件证明，不为了“完整”预先开放。

## 验收标准

- 独立任务/PR 完成安装解析、版本冲突、来源固定、哈希校验、事务恢复及并发安装规则，之后才公布新能力。
- 有共同兼容版本与不兼容菱形两组标准用例，冲突报告带确定排序的两条依赖路径；失败不修改原安装闭包。
- 禁用/卸载、启动时依赖缺失、升级失效及恢复分别验证反向依赖与资源清理；任何失败不误停不相关插件。
- 社区依赖官方、同名包来自不同来源、签名变化和导出撤回均有拒绝输入；旧私有函数的归属和递归拒绝语义不变。（第一阶段已覆盖导出撤回、禁用与卸载的进行中调用，以及旧 `wrongPlugin`、`recursiveCall` 不变；来源与签名相关的输入属于安装解析，尚未覆盖。）
- 如涉及函数协议，合并前在 Core 仓库根运行 `node shared/plugins/scripts/sdk-e2e.mjs` 验证 Node、Java、Rust SDK；正式契约、API 总表和协议更新记录与 Core 在同一个 Core PR 里完成。
- #1210 的基础 Registry 和第三方 DAP 验收可以完全不安装依赖包而完成。

## 风险

依赖安装事务和信任会扩大影响面，必须单独评审，不能靠一个 Debug schema 推定已解决。单版本第一版会拒绝部分组合，但比静默替换可靠；多版本共存、导出目录及资源授权的完整 wire 形状仍待后续设计，不属于本次交付。

## 验证

第一阶段的跨插件调用由 Core 测试（`plugins::plugin_functions`、`lsp::interface::function_relay`、`lsp::interface::engine`）和 macOS 单测（`MacPluginBackendSessionsTests`、`PluginHostServiceDispatchTests`、`PluginPublicHostAPITests`）覆盖，细节见实现 Note 的“验证”。依赖解析器和安装期规则仍没有实现，不能声称安装、版本冲突或依赖授权用例通过。实施时使用 `write-stable-tests`、~~./scripts/rust-core/verify-rust-core.sh~~（随旧客户端移除），并分别验证两个宿主和函数 SDK（在 Core 仓库根运行 `node shared/plugins/scripts/sdk-e2e.mjs`，契约与指南改动再运行 `node shared/plugins/scripts/verify-docs.mjs`）；新增资源时遵守工作树复用与安装目录只读要求。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/plugin_function.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/plugin_function.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/function_relay.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/function_relay.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/`
- ~~`macos/Sources/Lithe/Platform/MacOS/`~~（已随 #1794 移除）
- ~~`windows/tauri/src-tauri/src/plugin_host/`~~（已随 #1794 移除）
- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins/sdk`
