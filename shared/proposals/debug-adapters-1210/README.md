# 调试适配器声明评审草案（#1210）

本目录评审 #1210 中两份**跨端契约草案**：

1. 插件怎么声明调试适配器：放在现有 `plugin.json.debugAdapters`，不是独立注册文件；
2. 统一调试内核交给两个平台的会话投影 v2。

调试内核本身怎么重写、能力怎么分层，以 Agent Note 为准；本目录不重复这部分内容。

当前宿主不接受这些新增字段。本 PR 只提交计划，不改变正式契约或产品行为。

## 评审材料

- [统一调试内核与调试适配器 Registry](../../../.agents/notes/proposed/architecture/2026-10-25-unified-debug-engine-and-adapter-registry.md)：内核重写、必选 / 推荐 / 可选三层能力、P0–P5 迁移与验收。
- [可选调试扩展](../../../.agents/notes/proposed/architecture/2026-10-25-optional-debug-extensions.md)：寄存器、内存、反汇编、反编译源码、子会话等，各自单独验收。
- 能力块 schema 已并入正式契约 [plugin-manifest.schema.json](../../contracts/plugins/v1/plugin-manifest.schema.json)（`$defs.debugAdapter`）。
- [拒绝 fixtures](../../contracts/plugins/v1/fixtures/debug-adapter-rejections.json)：已由 Core 测试逐条执行（schema、coreManifest、corePlan、coreInstall 四层）。
- [会话投影 v2 schema](debug-session-projection.draft.schema.json) 与[样例](projection-v2-examples.draft.json)：可选的源码位置、字符串地址、`presentationHint` 透传、暂停代次与能力快照。

插件依赖、导出与跨包授权移到[独立平台提案](../../../.agents/notes/proposed/architecture/2026-10-25-plugin-dependencies-and-exports.md)，不是 #1210 的依赖或关闭条件。

插件声明只描述“怎么启动调试器”。断点、调用栈、变量等标准能力由新内核与适配器通过 DAP 协商，清单不逐项声明；寄存器、内存等扩展是宿主内核模块，不出现在清单里。

## 版本与清单位置

以下是本次选择的**拟定版本**，不是已分配、已实现的正式版本。落地前核对并行契约，若编号被占用，整体调整而非改变已发布版本的含义。

| 完整 `plugin.json` 中的位置 | 本提案的选择 |
| --- | --- |
| `schemaVersion`、`id`、`version`、`vendor` 等 | 沿用现有清单；不在 Debug 段重复插件身份 |
| `pluginAPIVersion` | 拟定 `4`：基础权限集合新增 Debug 授权；API 1/2/3 不接受新权限或 Debug 段 |
| `requires.debugAdapters` | 拟定 `1`：固定进程/传输声明与 Registry 接入 |
| `requires.serverProcess` | 普通进程为 `1`；使用 `runSelectedRuntime` 为拟定的 `2`。后者由共享进程契约拥有，不在版本 1 偷加 Python |
| `permissions` | 拟定 `debug.launch`：运行 DAP 适配器、控制本次 launch 目标；声明 attach 还需 `debug.attach` |
| `debugAdapters[]` | 本目录唯一 schema 评审的能力块 |
| `activationEvents` | 不新增事件。发现只读清单；用户选择并开始 Debug 时才启动适配器 |

没有 UI 或语言也可注册。`debug.launch` 不暗含 Build、测试、网络下载或其他插件的调用权限；attach 必须展示独立风险并获准。调试本身可能修改目标状态，安装审查必须如实说明，不把它包装成只读权限。未来内存写入等新操作另行评审。

`requires` 继续恰好列出所用能力。Core 校验、磁盘安装、市场过滤、安装确认和运行前检查使用同一能力表；宿主实际实现后才公布 `hostCapabilities`。本目录的 schema 不替代完整清单校验，特别是版本、权限、签名和 `requires` 的交叉检查。

拒绝顺序沿用能力版本规则：基础格式/API 支持范围 → `requires` 的能力及宿主支持 → Debug 段结构与语义 → 权限及包内资源 → 运行前目标与代次。API 3 携带 Debug 能力时，支持 API 4 的新 Core 在 `requires.debugAdapters` 拒绝；旧 Core 保留自身原来的拒绝位置和优先级，不为草案改写历史结果。

## 必需与可选

每个适配器只必填 `id`、`displayName`、`launch`；`launch` 只描述一个进程和一种传输。`process` 复用共享 `serverProcess` 的启动字段、模板、安装审查及校验，排除只适用于 LSP 的 `initializationOptions`。不要求后端、依赖、函数、流程或参数 schema。

| 可选项 | 省略时的含义 |
| --- | --- |
| `adapterID` | DAP initialize 使用局部 `id`；Registry 身份始终是插件 ID 加局部 ID |
| `requests` | 只允许 `launch`；attach 必须显式开启 |
| `selectors` | 仅供显式选择，不自动匹配全部目标 |
| `configurationTypes` | 不认领导入配置的 `type` 别名 |
| `configurations.launch/attach` | 不提供额外默认参数、目标映射或参数 schema |
| `capabilities.disabled` | 标准能力默认全部跟随 DAP 的默认值、initialize 与后续 capabilities 事件 |

局部适配器 ID 统一使用 `^[a-z][a-z0-9._-]{0,63}$`；插件 ID、语言 ID 沿用各自已有规则，它们不是同一种标识。身份、语言、DAP adapterID、导入 type、Run 配置 ID 和 sessionID 不相互替代。

## 固定启动声明，不引入工作流

`launch` 固定包含 `transport`，并在除 `tcpLanguageServer` 外的传输里包含 `process`：

- `stdio`：适配器进程的标准输入输出直接传 DAP，stderr 仅记录诊断。
- `tcpAnnounced`：从明确指定的 stdout/stderr 读取有界 UTF-8 行。字面量 `prefix` 后只接受端口或 `host:port`；IPv6 使用方括号，必须是 loopback。限制单行 4 KiB、总启动输出 1 MiB、连接准备 30 秒；未完整解出合法端点就不连接。没有 `jsDebugStandalone` 等按产品命名的解码档位。
- `tcpPort`：连接本次适配器进程的固定 loopback 端口；进程先启动，端口占用则失败，不悄悄改端口。它不是 DAP attach 参数里的被调试程序端口。若无法证明连接对应本次启动的进程，平台应拒绝该传输，不公布支持。

- `tcpLanguageServer`：适配器寄宿在同一插件已声明的语言服务器里，没有自己的进程，因此不写 `launch.process`（写了就拒绝，其他传输则必须写）。`endpoint` 只有 `languageID`（必须出现在同一插件的 `languageServers[]`）和 `command`（`workspace/executeCommand` 的命令 ID）。宿主先照常启动该语言服务器，再发送这个命令，服务器返回本次调试服务的 loopback 端口（整数或数字字符串，1...65535），宿主连接该端口。命令是安装与更新时用户审阅的内容的一部分，改命令会重新确认。它不是通用的“调用插件函数”：没有参数、没有返回值解释、不能指向其他插件的服务器。Java Debug Server 寄宿在 JDT LS 中，就是这种形式。

TCP 启动期限只约束端口发现与连接，不限制整个调试会话。关闭、失败、取消和禁用都会关闭连接、清理本次创建的进程；已有共享服务和外部 attach 目标不属于这条进程清理链。

普通 process 沿用 `packaged`、`systemCommand`、Java/Node `runtime`；`runSelectedRuntime` 是共享进程版本 2 的新增分支，先支持 Python、Java、Node，取得 **Run 对同一目标选中的运行时**，然后执行声明的参数。没有独立 Debug 解释器偏好、隐式安装或静默切到 PATH。没有显式选择时沿用 Run 自己的发现链。一个包只声明一个 `serverProcess` 版本：包含该分支时为 2，并继续接受该包内其他进程的旧启动形式；完全不用新形式仍声明 1，避免无谓过滤旧宿主。

已有 `${pluginDir}` 等启动模板保持原规则；此处永远指**声明该进程的当前包**。路径字段、模板展开及参数数组仍由共享解析器处理。`configuration.arguments` 是普通 JSON，不把其中的 `backendRef`、`$lease` 等同名字段解释为资源。此版没有资源引用输入、跨包租约或用户 JSON 中的隐藏句柄。

debugpy、lldb-dap 可以走 stdio（宿主已不再内置 Python、Rust 调试，由对应语言插件提供），Delve、js-debug 这类适配器可按真实启动方式选择 TCP（宿主已不再内置 Go、Node 调试，由对应语言插件提供）；是否能完整调试仍要核对后端版本、端口输出和目标参数。Java 先由内置 Provider 接入 Registry，继续使用已有 JDT 集成，不把宿主服务暴露为第三方 JSON 字段。一个模型统一接入方式，不保证所有后端功能相同。

## 配置与能力

保留现有 `DebugLaunchConfiguration`、Run 配置 ID、三层覆盖和导入参数。处理顺序是：适配器默认参数 → 现有 Run/导入/用户覆盖链 → 只补缺失的目标字段 → 可选参数 schema → Core 规范化。schema 的 `default` 是文档提示，实际默认值由 Core 实现。

`targetBindings` 限定为 `program ← target.path`、`processId ← target.processID`、`cwd ← target.workingDirectory`，以及只用于 `attach` 的 `connection`；不允许把进程号当路径，也不引入任意表达式。如果所选目标缺少必需事实且显式参数也未提供，准备阶段失败，不启动进程。

`connection` 让适配器附加到另一台机器上的被调试程序（适配器仍在本机）。与前三项不同，它的值是**适配器参数里的目的地路径**，因为各适配器给主机和端口起的名字、嵌套都不同（`hostName`/`port`、`connect.host`/`connect.port`、一个 `host:port` 字符串）：`host` 与 `port` 成对，或 `address` 单个字符串；可选 `pathMappings` 有四种形状：`objects`（对象列表）、`first`（唯一一条映射写成两个字符串）、`dictionary`（以其中一侧为键的对象）、`pairs`（二元数组列表）；形状装不下用户给的全部映射时拒绝而不是丢弃。事实来源仍然封闭：`target.host`、`target.port`、`target.pathMappings`。目的地与其他目的地、`processId`/`cwd` 或同一配置的默认 `arguments` 冲突的清单，在声明期被拒绝，否则“默认值优先”会让适配器连到用户没有确认的地方。Core 只按字面量把 `localhost`、`127.0.0.0/8`、`::1` 判为本机，其余都返回 `remote: true` 交宿主确认。不新增权限，`debug.attach` 已覆盖。决策原因、被否方案和不做的内容见主 Note 的“远程 attach”。文件目标不会自动产生 `program`，插件需要选择映射或由现有 Run 配置提供参数；不能仅声明 selector 就声称能启动。

这里绑定的是适配器 → 被调试程序的端点，不是 IDE → 适配器的 DAP 地址。默认 debugpy `--listen` 启动的是远端 DAP 适配器，需要独立的 DAP 直连入口，不能只填嵌套参数就算支持。当前只推进复用 #1520 的普通 TCP 连接与生命周期；代理、隧道、端口转发和 SSH 远端执行另做方案，不新增相关清单字段，见[网络边界 Note](../../../.agents/notes/proposed/architecture/2026-10-27-debug-network-paths-and-tcp-lifecycle.md)。

路径身份和执行路径分开：工作区内源码的持久化身份仍为相对路径；Build/Run 可以提供用户已选择或授权的外部产物引用，平台在执行时解析为绝对路径。源码外构建和工作区外可执行文件无需伪造相对路径。本提案不新增 `workspacePath`、`configuration.id` 或 `target.configurationID` 的重复结构。

`capabilities.disabled` 只接受标准 DAP capability 名称或 `exceptionBreakpointFilters`，Core 按固定版本的 DAP 定义检查名称并映射到对应请求/数据。结构 schema 只检查名称形状，不能证明名称存在。completions、steppingGranularity、cancel 等随 DAP，而不是再维护一份静态支持列表。省略不隐藏功能，声明也不能让尚未实现该操作的宿主点亮按钮；会话取消和清理始终保留，不能用 suppression 关闭。

此版没有标准操作的 `source: function`，也没有公开扩展函数。Java 热替换保留现有类型化 `redefineClasses` 链路。将来只有先定义输入、输出、会话归属与错误语义的扩展才可能绑定函数，不能给任意标准能力填一个函数名。

## 动态 resolver 明确后置

本次**不开放 `resolver`、`backendRef`、`hostIntegration`、`preparation` 字段**。复杂内置适配器通过同一个内部 Provider 契约返回计划，不等于第三方可凭 JSON 调用 JDT。

本包私有 resolver 比跨插件调用范围小，但仍改变了“领域结果不走插件函数”的已落地决策。它是独立的后续 `debugAdapters` 版本：先修订函数决策、定义固定的 Debug 输入/结果及本包授权，再复用 `lithe/function/invoke`。旧 `backend: 1` 仍是全局、网页触发的进程，不能为了 Debug 改成工作区后端或要求空网页。

如需重新准备，后续结果只能引用宿主已解析的 Build/Run action 身份及版本，不接受任意字符串、脚本或再次进入 Registry 的命令。宿主执行成功后最多重入解析一次，第二次要求准备即拒绝；项目事实随后重新从拥有它的引擎读取。这个后续门槛不阻塞固定声明的 P3–P4（见主 Note 的分阶段交付）。

## Schema 与 Core 校验分界

`debug-adapter-rejections.json` 以一个合成基线加 `set`/`remove` 描述单个拒绝输入，沿用已有 `invalid-manifests.json` 的 JSON Pointer fixture 约定，不新建编辑语法；路径只用于构造测试数据，**不是插件工作流语法**。每条记录标注校验层和预期稳定错误码，权限缺失沿用已有 `plugin.permission.undeclared`，新增 Debug 错误码仍为拟定；`expected.field` 是标准化后的错误位置，重复 ID 固定指向第二个条目。Core 计划也须验证输入目标快照与字段类型；无法从参数 schema 推断的后端必需字段，仍由 DAP 返回明确错误。无关基础清单字段按正式契约补足，不假装这些投影能安装。

| 规则 | 必须拒绝的情况 | Fixture |
| --- | --- | --- |
| S01 关闭新字段集合 | 旧依赖/导出/steps、resolver 或 hostIntegration 回流 | `removed-platform-fields`、`removed-resolver`、`removed-host-integration`、`removed-workflow` |
| S02 已知映射及实现 | program 绑定进程号，或标准能力绑定函数 | `program-from-process-id`、`function-for-step-back` |
| C01 版本入口 | API 3 使用 Debug 或新权限；Core/宿主不支持所需版本 | `old-api-debug`、`missing-host-capability` |
| C02 requires 精确匹配 | 少列 Debug/进程能力，或普通进程虚报版本 2 | `missing-debug-requirement`、`missing-process-requirement`、`unused-process-v2` |
| C03 身份唯一 | 同一插件重复 adapter id | `duplicate-adapter-id` |
| C04 请求与授权一致 | 缺 debug.launch、attach 缺授权、配置声明不支持的请求 | `missing-launch-permission`、`attach-without-permission`、`unsupported-request-config` |
| C05 运行时契约 | runSelectedRuntime 却声明 serverProcess 1，或选择结果失效 | `selected-runtime-v1`、`stale-selected-runtime` |
| C06 名称存在 | 拼写形似 DAP，但不是固定定义里的能力 | `unknown-dap-capability` |
| C07 目标事实完整 | program 映射缺路径，且合并后也无显式 program | `missing-target-path` |
| C08 包内资源归属 | 参数 schema 的符号链接逃出包 | `escaping-parameters-schema` |
| C09 运行前再确认 | 插件注册代次或计划已过期 | `stale-registration` |

移除后的跨依赖和 step 引用不再进入语义解释器，直接因未知字段被拒绝；并不代表实现了依赖图或流程引用检查。

**验证口径：**离线检查只能证明本草案 schema 合法，且结构层 fixture 有预期结果。C01–C09 的输入已列出，但没有对应新增 Core 实现或执行证据；不得把它们计为“已通过的 Core 拒绝用例”。正式落地时把这些 fixtures 迁到正式契约并接上 Core 测试，每条校验错误码、字段、优先级及无副作用；双端运行验证另外提供。

本次没有启动应用、后端或调试程序。契约与 Core 同批落地后，按仓库规则同步 `lithe-plugin-docs`；教程、SDK、示例只在该仓库维护，主仓库保留正式契约和回归 fixtures。
