# Agent 笔记：插件后端的工作区上下文、激活与宿主服务分发

状态：已实现

## 先说结论

插件后端新增能力版本 `backend: 2`，同时函数协议升到 3。`backend: 1` 的含义一个字都没改：仍然是“网页第一次调用时才启动、整个应用一个进程”。`backend: 2` 可以在没有网页的情况下启动，触发条件是打开工作区（`onWorkspaceOpen`）或执行插件命令（`onCommand:<id>`）。它仍是每个插件一个进程，被所有窗口共用；每次调用都要带上“工作区上下文”（contextID 加 generation），后端靠它知道这次操作的是哪个工作区。

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
- 函数协议在 Core 里协商出 `[1, 2, 3]`。版本 3 加入的内容：能力发现、订阅释放、工作区上下文、调用上下文、带错误码的宿主失败、宿主请求取消。backend 1 的插件也能协商到协议 3，网页调用的行为不变。

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
| contextID | `PluginWorkspaceContexts`，形如 `w-<n>` | 窗口显示该工作区期间；同一窗口换工作区时 ID 不变 | 窗口关闭工作区、切到单文件或关窗即关闭 |
| generation | 同上，从 1 开始 | 文件夹或 authority 每变一次加 1 | 旧 generation 一律 `plugin.host.contextExpired`，后端需要重新获取 |
| rootID | `"r"` + 位置 SHA-256 的前 16 位十六进制 | 同一位置跨重启保持稳定 | 不含路径，不能当作授权凭证 |
| subscriptionID | `PluginHostSubscriptions`，形如 `s-<n>` | 直到被 dispose、上下文关闭或会话结束 | 未知 ID 的 dispose 也返回成功 |
| hostRequestID | Core | 一次宿主请求 | 后端用 `$/cancelRequest` 取消后，Core 立即以 `-32800` 回答；宿主停止工作，之后的回答会被 Core 拒收 |

宿主对每个请求再做一次核验：服务是否在该会话的授权里（隐式服务 `host`、`subscriptions` 除外），以及参数里的上下文是否仍是当前 generation。这一步和 Core 做的检查是重复的，属于纵深防御。

### Authority（工作区在哪台机器上）

- 上下文的 `authority` 只有两种：`local`，或 `remote`（带不透明的连接 ID）。
- 远程工作区的文件夹不带 `path`。本机目录只是占位，服务不能读它，也不能改在本机执行。
- 文件、搜索、进程类服务遇到自己没实现的 authority，返回 `plugin.host.authorityUnsupported`。
- 后端进程永远跑在运行 Lithe 的这台 Mac 上，远程工作区也一样。`getCapabilities.backendAuthority` 固定为 `"local"`。

### 存储范围与卸载策略

- 全局状态是 `${stateDir}`，即 `Application Support/Lithe/PluginState/<plugin>/backend`。
- 工作区状态是 `${stateDir}/workspaces/<digest>`。digest 对本地工作区取路径的 SHA-256，对远程工作区取 `remote:<连接ID>:<远端路径>` 的 SHA-256，目录名里不出现用户路径。
- 工作区状态目录在第一次 `getContext` 或 `listContexts` 时才创建。两种状态都在平台可写目录里，不在 app bundle 或插件包内，所以不影响代码签名和 Sparkle 增量包的基线。
- 禁用和更新插件时保留这些目录。卸载时随插件目录一起删除，沿用 `MacPluginStateDirectories.pluginDirectory` 的现有清理。

### 激活事件与启动预算

- `onWorkspaceOpen`：窗口打开工作区后，在下一个主线程任务里启动，不阻塞打开流程。多个插件按 ID 排序后串行启动，一次只启动一个。每个插件沿用 60 秒的 initialize 超时，超时或失败只记日志（`plugins.backend`），不会挡住工作区。
- `onCommand:<id>`：在 `performToolWindowContribution` 里，命令贡献的 `actionID` 就是命令 ID；只启动所属 UI 模块为 `<pluginID>.ui` 的那个插件。窗口照常打开，不等待后端。
- 不接受 `onStartupFinished` 和 `*`。“应用一启动就跑”的后端没有用户可感知的触发点，会拖慢所有用户的启动。
- 激活不以信任状态为前提。只要插件已安装、已启用、经过安装审查，激活事件就会生效。

### 拒绝递归调用

后端仍然不能通过宿主去调用函数或领域操作（`plugin.function.recursiveCall`）。新增的宿主方法都是只读查询或宿主本地动作，不会回调后端。因此一次网页调用不可能经由宿主等待它自己。

### 宿主服务分发扩展点

- 每个切片实现 `@MainActor protocol PluginHostServiceHandling`（属性 `service`，方法 `answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError>`），在组合根 `MacServiceContainer` 里用 `hostDispatcher.register(_:)` 注册。
- `PluginHostServiceError.code` 用 `PluginHostErrorCode` 表示：未支持、未授权、上下文失效、authority 不支持、版本冲突、参数错误、超限、取消、超时、后端退出、其他失败。
- Core 只把白名单里的错误码透传给协议 3 的后端，其余一律变成 `plugin.host.failed`。

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
  - 宿主请求最多同时挂起 16 个（第 17 个返回 `limitExceeded`），单个结果不超过 1 MiB，错误消息不超过 1024 字节。这些上限通过 `getCapabilities.limits` 公布。
  - 后端可以取消自己的宿主请求。会话结束时，所有进行中的宿主任务都会被取消。
  - 订阅的创建方是服务，释放方是 dispatcher（dispose、上下文关闭、会话结束三条路径）。`listContexts.revision` 让后端判断工作区列表是否变了，需要重新获取快照。
- **4.4 编辑器一致性。** M0 不涉及文档内容。编辑器读取和带版本编辑由 API-09/10 切片通过同一扩展点接入，版本冲突用 `plugin.host.versionConflict`。

### 威胁模型

| 威胁 | 处理 |
| --- | --- |
| 后端伪造 contextID 或使用旧 generation，操作别的工作区 | 宿主按注册表核验，旧的或不存在的一律 `contextExpired`；ID 不是授权，授权仍看会话的 hostServices |
| 后端请求未授权的服务 | Core 按授权表拒绝；宿主 dispatcher 再查一次，返回 `permissionDenied` |
| 插件 A 读取插件 B 的状态或订阅 | 状态目录按插件 ID 分开，订阅按插件 ID 登记；凭据按插件 ID 隔离 |
| 远程工作区被当作本地读写 | 远程上下文不带路径；文件和进程服务必须返回 `authorityUnsupported` |
| 慢后端或恶意后端堆积宿主请求 | 最多 16 个挂起，可取消，会话结束时全部清理 |
| 路径从状态目录名或 rootID 泄露 | 两者都只用 SHA-256 摘要 |
| 后端退出后，宿主仍把结果送给新进程 | 新进程启动前先 `endSession`；旧任务被取消，不再回答 |
| 原生后端绕过宿主直接读盘或联网 | 不在本设计防护范围内；由安装审查和用户的 OS 权限承担 |

## 考虑过的备选方案

- **每个工作区一个后端会话。** 隔离最直观。被否的原因：连接和缓存都要按窗口重复建立；`backend:1` 已经是应用级进程，两套模型并存会让插件作者困惑；而且远程工作区也只能在本机跑后端，按工作区拆进程得不到任何隔离收益。
- **把 `backend:1` 直接扩展为带工作区。** 被否的原因：已经发布的插件会在不知情的情况下收到新的启动时机和参数，违背“未知能力明确拒绝、不靠升版本宣称全量可用”的原则。
- **用“当前活动窗口”推断工作区。** 被否的原因：后台调用和多窗口场景下会落到错误的工作区，计划 4.1 也明确禁止这样做。
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
- 每加一个新服务，都要同时更新 Core 的 `HOST_METHODS` 和契约 README。
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
  - 以及 `fixtures/invalid-manifests.json` 新增的 6 个拒绝用例
- `./scripts/macos/test/test-macos.sh --filter "PluginHostServiceDispatchTests|MacPluginBackendSessionsTests|PluginWebBridgeTests"`：上下文 generation、rootID、授权核验、本地与远程描述、过期与格式错误、订阅的三条释放路径、错误码透传。M0 提交时尚未在本机编译运行，合入前必须跑通。
- `zsh scripts/architecture/verify-shared-contracts.sh`：契约 schema、fixture 与 README。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`：运行时不向发行目录写入。
- 合入前，在 lithe-plugin-docs 运行 `node scripts/sdk-e2e.mjs --source <本仓库路径> --ref <分支>`，确认 Node 和 Java SDK 的示例后端在协议 3 下仍能跑通。

## 适用范围

适用于 macOS 宿主和 Rust Core 的插件后端：`backend` 2、函数协议 3、`workspace` 宿主服务，以及后续所有接入 `PluginHostServiceDispatcher` 的宿主服务（编辑器、文件、打开/预览/通知等切片）。Windows/Tauri 宿主目前不提供 `backend` 能力（`host_capabilities` 中没有该项），会以 `plugin.api.unsupported` 拒绝任何声明后端的清单；本次不改 Windows。
