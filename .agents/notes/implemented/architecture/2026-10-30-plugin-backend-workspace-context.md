# Agent 笔记：插件后端的工作区上下文、激活与宿主服务分发

状态：已实现

## 先说结论

插件后端新增能力版本 `backend: 2`，同时函数协议升到 3。`backend: 1` 的含义一个字都没改：仍然是“网页第一次调用时才启动、整个应用一个进程”。`backend: 2` 可以在没有网页的情况下启动，触发条件是打开工作区（`onWorkspaceOpen`）或执行插件命令（`onCommand:<id>`）。它仍是每个插件一个进程，被所有窗口共用；每次调用都要带上“工作区上下文”（contextID 加 generation），后端靠它知道这次操作的是哪个工作区。

从协议 3 起，宿主再开放新能力（新服务、方法、通知、可选参数、结果字段、错误码）都在协议 3 内新增，后端用 `getCapabilities` 查到才使用，不再为它们升协议版本；只有会让已有后端读错的改动才出协议 4。

开发时记住三条。第一，宿主服务一律注册到 `PluginHostServiceDispatcher`，不要在 `MacPluginBackendSessions` 里按服务名加分支。第二，凡是涉及文件或进程的服务，遇到不支持的远程 authority 都要返回 `plugin.host.authorityUnsupported`，不能去读本机的空占位目录。第三，工作区信任暂不引入，后续单独立项；现在仍沿用按操作确认。

## 问题

M0 计划（`docs/development/macos-plugin-api-plan.md` 第 4 节）要求插件后端先有一个稳固的身份和工作区模型，后续的编辑器、文件、打开/通知等切片才能接上来。现状有四个缺口：

- `backend: 1` 只能由网页唤起。没有网页的插件（例如只提供命令或后台索引）根本启动不了。
- 后端不知道有哪些工作区打开，也不知道调用来自哪个窗口。如果靠“当前活动窗口”去猜，窗口切换后操作会落到错误的工作区。
- 宿主服务只有凭据一种，写死在 `PluginHostServices.answer` 里。三个并行切片没有统一的注册点，也没有统一的错误分类。
- 远程工作区在本机只有一个空的占位目录。如果服务把它当作真实路径，就会读到空目录，或者在本机执行本该在远端执行的操作。

## 决策

### 新能力版本，不悄悄改 `backend:1`

- `requires.backend: 2` 是新版本；宿主现在提供 `backend: [1, 2]`（`PluginTypes.swift` 的 hostCapabilities 与 Rust `capabilities.rs`）。
- 只认识 `[1]` 的旧宿主会以 `plugin.api.unsupported` 拒绝 v2 清单，因此旧宿主不会误把 v2 当 v1 运行。
- v2 至少要有一种启动方式：网页工具窗口、`ui.commands[]`，或 `onWorkspaceOpen`。三者都没有时清单无效。
- v2 可以是整个插件的全部内容，不需要同时声明语言或 UI。
- 函数协议在 Core 里协商出 `[1, 2, 3]`。版本 3 加入的内容：能力发现、订阅释放、工作区上下文、调用上下文、带错误码和 details 的宿主失败、宿主请求取消、宿主到后端的通知。backend 1 的插件也能协商到协议 3，网页调用的行为不变。

### 共享进程、隔离调用上下文，而不是每个工作区一个会话

我们选的是“共享进程 + 每次调用显式带上下文”：仍然每个插件一个进程，工作区不再是进程状态，而是每次调用参数里的 `{contextID, generation}`。

理由如下：

- 后端持有的东西（数据库连接、索引缓存、登录态）属于用户，不属于某个工程。按工作区拆进程，就要为每个窗口重复启动、重复认证，内存也会成倍增长。
- 同一个进程里，靠上下文参数隔离已经足够。宿主对每个请求都会核验上下文是否仍然有效，后端无法自己拼出一个上下文来越权。
- `${workspaceStateDir}` 在 v2 里继续拒绝，因为进程启动时没有“当前工作区”可言。每个工作区的状态目录改由上下文对象里的 `stateDirectory` 给出。

正确的做法是：网页调用时，宿主从该网页所在窗口取上下文（`PluginWebBridgeHost.pluginWebWorkspaceContext`），再经 `lsp.functionRequest.context` 送到后端。不要这样做：后端在收不到上下文时，去取“最近打开的工作区”。

### 身份与授权句柄的寿命

| 句柄 | 谁发 | 寿命 | 失效后 |
| --- | --- | --- | --- |
| 插件 ID | 安装记录 | 安装期间 | 卸载即消失 |
| 后端会话与授权（hostServices） | Rust 启动计划 + `dispatcher.beginSession` | 一个进程 | 停止、禁用、替换包、崩溃后重启时 `endSession`，未完成的宿主请求不再回答，订阅全部释放 |
| contextID | `PluginWorkspaceContexts`，形如 `w-<n>` | 窗口显示同一个工作区期间；同一窗口切到另一个工作区（状态 digest 不同）时，旧上下文关闭、发新 ID | 窗口关闭工作区、切到单文件、换工作区或关窗即关闭 |
| generation | 同上，从 1 开始 | 同一工作区的文件夹或 authority 每变一次加 1 | 旧 generation 一律 `plugin.host.contextExpired`，后端需要重新获取 |
| rootID | `"r"` + HMAC-SHA256(宿主密钥, 插件 ID + `\0` + 位置) 的前 16 位十六进制 | 同一插件、同一位置跨重启保持稳定；不同插件看到的 ID 不同 | 不含路径，不能当作授权凭证；删除密钥文件只会让所有 rootID 换新 |
| subscriptionID | `PluginHostSubscriptions`，形如 `s-<n>` | 直到被 dispose、上下文关闭或会话结束 | 未知 ID 的 dispose 也返回成功 |
| hostRequestID | Core | 一次宿主请求 | 后端用 `$/cancelRequest` 取消后，Core 立即以 `-32800` 回答；宿主停止工作，之后的回答会被 Core 拒收 |

宿主对每个请求再做一次核验：服务是否在该会话的授权里（隐式服务 `host`、`subscriptions`、`commands` 除外），以及参数里的上下文是否仍是当前 generation。这一步和 Core 做的检查是重复的，属于纵深防御。

换工作区发新 contextID，而不是沿用 ID 只加 generation，是因为后端常按 contextID 缓存连接、索引和登录态。沿用 ID 会让后端把 A 工程的缓存带进 B 工程；generation 只表达“同一个工作区的形状变了”。

rootID 用按插件加密钥的 HMAC，而不是位置的普通哈希：普通哈希可以由猜到的路径直接算出，也能让两个插件通过协议互相对上同一个文件夹。密钥放在 `Application Support/Lithe/PluginHost/root-id.key`（`MacPluginRootIDSecret`），首次使用时以 0600 和 `O_EXCL` 创建、之后不再改写；它在平台可写目录里，不在 app bundle、插件包或任何插件的 `${stateDir}` 中，不影响代码签名和 Sparkle 增量包。目录不可写时只用本次启动的随机密钥，rootID 仍唯一，只是不跨重启稳定。后端以用户身份运行，能读用户文件的进程本来就能读到密钥，这一层只防“从协议推出路径或跨插件关联”。

### Authority（工作区在哪台机器上）

- 上下文的 `authority` 只有两种：`local`，或 `remote`（带不透明的连接 ID）。
- 远程工作区的文件夹不带 `path`。本机目录只是占位，服务不能读它，也不能改在本机执行。
- 文件、搜索、进程类服务遇到自己没实现的 authority，返回 `plugin.host.authorityUnsupported`。
- 后端进程永远跑在运行 Lithe 的这台 Mac 上，远程工作区也一样。`getCapabilities.backendAuthority` 固定为 `"local"`。

### 存储范围与卸载策略

- 全局状态是 `${stateDir}`，即 `Application Support/Lithe/PluginState/<plugin>/backend`。
- 工作区状态是 `${stateDir}/workspaces/<digest>`。digest 对本地工作区取路径的 SHA-256，对远程工作区取 `remote:<连接ID>:<远端路径>` 的 SHA-256，目录名里不出现用户路径。
- 工作区状态目录只在 `getContext` 时创建，`stateDirectory` 也只出现在 `getContext` 的结果里；`listContexts` 的条目不带它、不建任何目录，避免后端列一次上下文就给每个打开的窗口都留下空目录。两种状态都在平台可写目录里，不在 app bundle 或插件包内，所以不影响代码签名和 Sparkle 增量包的基线。
- 禁用和更新插件时保留这些目录。卸载时随插件目录一起删除，沿用 `MacPluginStateDirectories.pluginDirectory` 的现有清理。

### 激活事件与启动预算

- `onWorkspaceOpen`：窗口打开工作区后，在下一个主线程任务里启动，不阻塞打开流程。多个插件按 ID 排序后串行启动，一次只启动一个。每个插件沿用 60 秒的 initialize 超时，超时或失败只记日志（`plugins.backend`），不会挡住工作区。
- `onCommand:<id>`：在 `performToolWindowContribution` 里，命令贡献的 `actionID` 就是命令 ID；只启动所属 UI 模块为 `<pluginID>.ui` 的那个插件。窗口照常打开，不等待后端。命令本身经 `lithe/host/commands/didRun { commandID, context? }` 送到 `backend: 2` 的后端：已就绪的后端立即按通知顺序收到；正在启动的排在启动之后；未运行的只有声明了该命令的 `onCommand:<id>` 才会被启动并在就绪后收到。`backend: 1` 不收命令通知。
- 热启用：`enable` 和 `register` 时如果已经有工作区打开，声明 `onWorkspaceOpen` 的插件立即启动，等同于工作区刚打开，不必等下一个窗口。新安装带后端的包仍需重启（`canActivateWithoutRestart`），这一点不在本次范围。
- 不接受 `onStartupFinished` 和 `*`。“应用一启动就跑”的后端没有用户可感知的触发点，会拖慢所有用户的启动。
- 激活不以信任状态为前提。只要插件已安装、已启用、经过安装审查，激活事件就会生效。

### 拒绝递归调用

后端仍然不能通过宿主去调用函数或领域操作（`plugin.function.recursiveCall`）。新增的宿主方法都是只读查询或宿主本地动作，不会回调后端。因此一次网页调用不可能经由宿主等待它自己。

### 宿主服务分发扩展点

- 每个切片实现 `@MainActor protocol PluginHostServiceHandling`（属性 `service`，方法 `answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError>`），在组合根 `MacServiceContainer` 里用 `hostDispatcher.register(_:)` 注册。
- `PluginHostServiceError.code` 用 `PluginHostErrorCode` 表示：未支持、未授权、上下文失效、authority 不支持、版本冲突、参数错误、超限、取消、超时、不存在（notFound）、只读（readOnly）、不支持的选项（unsupportedOption）、前置条件不满足（preconditionFailed）、忙（busy）、限流（rateLimited）、后端退出、其他失败。
- Core 只把白名单里的错误码透传给协议 3 的后端，每个码对应自己的 JSON-RPC 数值（`-32010` 起逐个加 1，一码一义），其余一律变成 `plugin.host.failed`。`-32000`～`-32009` 留给后端自己的失败，因为很多 JSON-RPC 库从 `-32000` 开始用。
- `PluginHostServiceError.details` 是可选的结构化对象（如 `currentVersion`、`retryAfterMilliseconds`），经 `lsp.hostResponse.error.details` 到 Core，序列化后不超过 4 KiB、且必须是对象才会以 `error.data.details` 送到协议 3 的后端，否则丢弃。
- 宿主只授予自己真正注册了 handler 的服务：启动时把清单的 `hostServices` 与 `hostDispatcher.registeredServices` 取交集，再交给 Core。这样 `getCapabilities` 列出的方法都有人回答，不会出现“列出来但调用失败”。

### 宿主到后端的通知

Core 新增命令 `lsp.hostNotify { sessionId, method, params }`，返回 `{ delivered }`。只允许三种方法，Core 按白名单、授权和参数格式检查，协议低于 3 的会话返回 `delivered: false` 不发送：

- `lithe/host/workspace/didChangeContexts { revision }`：需要 `workspace` 授权。`PluginWorkspaceContexts.observeRevision` 在每次打开、变化、关闭时触发一次，`MacPluginBackendSessions` 推给所有已授权的运行中后端；后端自己再调 `listContexts`。
- `lithe/host/subscriptions/notify { subscriptionID, sequence, event }`：`PluginHostSubscriptions.notify` 为每个订阅单独递增 `sequence`（从 1 起），已释放的订阅不再发送。服务通过 dispatcher 的 `subscriptions` 发事件，不直接找会话。
- `lithe/host/commands/didRun { commandID, context? }`：见上面的 `onCommand`。

宿主按插件串行发送通知（每个运行中会话一个 Task 链），停止会话时取消未发出的通知，保证同一后端收到的顺序与宿主发出的顺序一致。参数序列化后不超过 1 MiB（`limits.notificationBytes`）。

### 协议 3 内只增不改

原来的规则是“每个宿主能力加入时都进入新的协议版本”（见[插件函数契约](2026-10-20-plugin-function-contract.md)）。协议 3 有了 `getCapabilities` 之后，这条规则改为：

- 宿主能力在协议 3 内新增，不升版本。可以新增的有：服务及其方法和通知（配一个新的清单权限）、已有服务的方法或通知、可选参数（叫作“选项”，不传时行为与以前相同）、结果/通知/`details`/`limits` 里的字段、错误码（从 `-32022` 起按顺序取号，号码永不改义）。
- 只有已有后端会读错的改动才需要协议 4：删除或改名方法、通知、字段，改字段含义或类型，把选项变成必填，改错误码的号码，削弱已写明的顺序或生命周期保证。
- 后端的义务：只调用 `getCapabilities.services` 列出的方法；忽略不认识的字段和 `lithe/host/*` 通知；遇到不认识的 JSON-RPC 号码按宿主失败处理，认识 `error.data.code` 时按它分支。
- Core 的义务：协议 3 会话的请求里出现方法没有定义的字段时，回 `-32018` `plugin.host.unsupportedOption`，`details.option` 写明是哪个字段，后端可以去掉它重试。协议 2 仍回 `invalidParams`，行为不变。参数由服务自己校验的方法（`HostParams::Object`）由服务按同样方式回答。
- 新服务的权限仍要在清单里声明。不认识该权限的旧宿主在安装时以 `plugin.permission.unknown` 拒绝整个包，不会悄悄授予或忽略权限。

这样改的原因：插件后端调用宿主属于运行时能力，本来就靠协商和发现判断能不能用（[按能力分版本](2026-10-17-plugin-capability-versions.md)：“进程启动后还能做什么，走它自己的协议协商”）。如果每加一批服务都升一次版本，SDK 和插件要同时维护很多个版本分支，而版本号能表达的信息 `getCapabilities` 已经全部给出。用户在 PR #1595 评审时确认了这个取舍。

### 工作区信任

工作区信任暂不引入，后续单独立项。现阶段沿用按操作确认，例如网页启动进程前的 `pluginWebConfirmProcessStart`。契约 README 里原来写着“workspace trust”的地方，已经改成如实描述：按操作确认，目前没有工作区信任状态。

### 对计划第 4 节的回答

- **4.1 谁能调用。**
  - 网页调用：由窗口的上下文决定。
  - 命令激活：只启动所属插件。
  - 宿主请求：只针对发出请求的那个插件的会话。
  - 协议版本：协议 3、`backend` 2、`workspace.metadata` 权限各自独立协商，`backend:1` 不变。
  - 递归：仍然拒绝。
- **4.2 权限和数据保护。**
  - `workspace.metadata` 只暴露工作区名、根目录、rootID、authority 和状态目录，不读取任何文件内容。
  - 路径只对 local 给出。
  - 凭据服务的规则不变。
  - 进程分离不等于沙盒：原生后端本来就拥有用户的 OS 权限，宿主能做的只是拒绝代理越权的请求。
- **4.3 异步与预算。**
  - 宿主请求最多同时挂起 16 个（第 17 个返回 `limitExceeded`），单个结果不超过 1 MiB，错误消息不超过 1024 字节，错误 details 不超过 4 KiB，通知参数不超过 1 MiB。这些上限通过 `getCapabilities.limits`（`pendingHostRequests`、`functionResultBytes`、`errorMessageBytes`、`errorDetailsBytes`、`notificationBytes`）公布；`messageBytes` 改名为 `errorMessageBytes`，避免被误解为整条消息的上限。
  - 后端可以取消自己的宿主请求。会话结束时，所有进行中的宿主任务都会被取消。
  - 订阅的创建方是服务，释放方是 dispatcher（dispose、上下文关闭、会话结束三条路径）。`listContexts.revision` 让后端判断工作区列表是否变了，需要重新获取快照；`didChangeContexts` 在变化时主动通知，后端不必轮询。
- **4.4 编辑器一致性。** M0 不涉及文档内容。编辑器读取和带版本编辑由 API-09/10 切片通过同一扩展点接入，版本冲突用 `plugin.host.versionConflict`。

### 威胁模型

| 威胁 | 处理 |
| --- | --- |
| 后端伪造 contextID 或使用旧 generation，操作别的工作区 | 宿主按注册表核验，旧的或不存在的一律 `contextExpired`；ID 不是授权，授权仍看会话的 hostServices |
| 后端请求未授权的服务 | Core 按授权表拒绝；宿主 dispatcher 再查一次，返回 `permissionDenied` |
| 插件 A 读取插件 B 的状态或订阅 | 状态目录按插件 ID 分开，订阅按插件 ID 登记；凭据按插件 ID 隔离 |
| 远程工作区被当作本地读写 | 远程上下文不带路径；文件和进程服务必须返回 `authorityUnsupported` |
| 慢后端或恶意后端堆积宿主请求 | 最多 16 个挂起，可取消，会话结束时全部清理 |
| 路径从状态目录名或 rootID 泄露 | 状态目录名只用 SHA-256 摘要；rootID 用按插件加宿主密钥的 HMAC，既推不出路径，也不能跨插件对上同一文件夹 |
| 换工作区后后端把旧工作区的缓存用到新工作区 | 换工作区即换 contextID，旧 ID 立即 `contextExpired` |
| 后端退出后，宿主仍把结果送给新进程 | 新进程启动前先 `endSession`；旧任务被取消，不再回答 |
| 原生后端绕过宿主直接读盘或联网 | 不在本设计防护范围内；由安装审查和用户的 OS 权限承担 |

## 考虑过的备选方案

- **每个工作区一个后端会话。** 隔离最直观。被否的原因：连接和缓存都要按窗口重复建立；`backend:1` 已经是应用级进程，两套模型并存会让插件作者困惑；而且远程工作区也只能在本机跑后端，按工作区拆进程得不到任何隔离收益。
- **把 `backend:1` 直接扩展为带工作区。** 被否的原因：已经发布的插件会在不知情的情况下收到新的启动时机和参数，违背“未知能力明确拒绝、不靠升版本宣称全量可用”的原则。
- **用“当前活动窗口”推断工作区。** 被否的原因：后台调用和多窗口场景下会落到错误的工作区，计划 4.1 也明确禁止这样做。
- **继续“每个宿主能力升一个协议版本”。** 版本号能直接说明有哪些能力，但文件、编辑器、窗口等服务会分多次开放，协议号会一直往上涨，SDK 每次都要跟着加版本分支。`getCapabilities` 已经按会话列出实际可用的方法，版本号成了重复信息。被否，改为协议 3 内只增不改。
- **把未知参数静默忽略。** 宿主不升版本时最省事，但后端会以为某个选项生效了，结果宿主没照做，例如以为排除了隐藏文件实际没有。被否，改为明确回 `unsupportedOption` 并写明字段。
- **在 M0 引入工作区信任状态，并以它作为激活前提。** 用户决定暂不引入；先沿用按操作确认，信任模型以后单独立项。
- **把 `${workspaceStateDir}` 开放给 v2 的启动参数。** 被否的原因：进程不属于某个工作区，启动时没有正确的值可填。

## 后果

收益：

- 没有网页的插件也能运行后端。
- 三个切片只需要实现一个协议并注册一次，不改契约，也不改 Core 的能力表。
- 后端能明确知道每次调用属于哪个工作区，并在工作区过期时得到提示。
- 远程工作区不会被误读。

代价：

- 后端必须自己处理 `contextExpired`，重新获取上下文后再试。
- 在 v2 里 `${workspaceStateDir}` 不可用，插件作者需要从上下文对象里取状态目录。
- 每加一个新服务，都要同时更新 Core 的 `HOST_METHODS`（以及有通知时的 `HOST_NOTIFICATIONS`）和契约 README。新增的服务、选项和错误码都留在协议 3 内，不能顺手改已有方法或字段的含义，否则就要出协议 4。
- 同为协议 3，不同宿主能用的方法可能不同，后端和 SDK 必须按 `getCapabilities` 判断，不能只看版本号。
- 后端拿到 `listContexts` 后，要用 `getContext` 才能得到某个工作区的 `stateDirectory`。
- `onWorkspaceOpen` 后端串行启动。插件多的时候，最后一个插件就绪得较晚，但这不影响工作区本身。

## 验证

- `cargo test -p lithe-core`（覆盖下列 Rust 用例）：
  - `capability_discovery_is_answered_by_core`
  - `typed_host_failures_reach_a_version_3_backend`
  - `a_backend_can_cancel_its_host_request`
  - `invocations_carry_the_workspace_context_from_version_3`
  - `invocation_contexts_follow_the_fixture`
  - `host_failures_follow_the_fixture`
  - `capabilities_list_only_granted_services`
  - `grantable_services_have_methods`
  - `workspace_backend_is_planned_with_its_version_and_workspace_service`
  - `host_notifications_follow_the_fixture`、`host_notifications_are_bounded`、`host_notifications_reach_a_version_3_backend`、`host_notifications_skip_a_version_2_backend`
  - `host_failure_details_are_a_bounded_object`、`host_failure_details_reach_a_version_3_backend`
  - 以及 `fixtures/invalid-manifests.json` 新增的 6 个拒绝用例
- `./scripts/macos/test/test-macos.sh --filter "PluginHostServiceDispatchTests|MacPluginBackendSessionsTests|PluginWebBridgeTests"`：上下文 generation 与换工作区发新 ID、按插件的 rootID 与密钥文件、`listContexts` 不建目录、授权核验、本地与远程描述、过期与格式错误、订阅的三条释放路径与 sequence、错误码与 details 透传、命令和订阅通知按顺序送达运行中的后端、`backend: 1` 与未运行的后端不收命令。
- `zsh scripts/architecture/verify-shared-contracts.sh`：契约 schema、fixture 与 README。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`：运行时不向发行目录写入。
- 合入前，在 lithe-plugin-docs 运行 `node scripts/sdk-e2e.mjs --source <本仓库路径> --ref <分支>`，确认 Node 和 Java SDK 的示例后端在协议 3 下仍能跑通。

## 适用范围

适用于 macOS 宿主和 Rust Core 的插件后端：`backend` 2、函数协议 3、`workspace` 宿主服务，以及后续所有接入 `PluginHostServiceDispatcher` 的宿主服务（编辑器、文件、打开/预览/通知等切片）。Windows/Tauri 宿主目前不提供 `backend` 能力（`host_capabilities` 中没有该项），会以 `plugin.api.unsupported` 拒绝任何声明后端的清单；本次不改 Windows。
