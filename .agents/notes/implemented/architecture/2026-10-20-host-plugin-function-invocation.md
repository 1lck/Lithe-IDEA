# Agent 笔记：宿主调用插件函数的入口与 `lithe/host/*` 暂缓

状态：已实现

## 先说结论

macOS 现在能调用插件函数了。入口只有一个：插件自己的网页窗口通过 `window.lithe` 调用 `functions.list`、`functions.invoke`、`functions.cancel`，宿主把请求交给**这个插件自己启动的构建 Provider 进程**。Rust Core 的 `lsp.functionRequest` 负责路由和结果。

为了让 Core 能协商函数，宿主启动构建 Provider 时会带上它所属插件的 `pluginId`。这是唯一的接线改动，宿主代码里没有任何按插件名的分支。

插件调用宿主能力（`lithe/host/*`，例如让插件后端请宿主跑一个进程）这次**不做**。理由见下文。

## 问题

[插件函数契约](2026-10-20-plugin-function-contract.md)只在 Core 里实现了协议，宿主还没有入口。macOS 启动构建 Provider 时也从不传 `pluginId`，所以 Core 永远不会和这些进程协商 `litheFunctions`，函数一个都不会出现。

接入时要回答四个问题：

1. 谁可以调用函数？
2. 函数跑在哪个进程里？
3. 进度、失败和取消怎么回到调用方？
4. 项目关闭或插件停用后，会不会留下进程？

## 决策

### 1. 只有插件自己的网页能调用，归属检查两层

网页桥接（`PluginWebBridge`，宿主给插件网页提供 `window.lithe` 的那一层）沿用 `build.*` 方法已有的 `entry()` 检查：页面只能指定自己插件的构建实例，不能指定别的插件的实例。

Core 再检查一次：`lsp.functionRequest` 里的 `pluginID` 必须和会话启动时的 `pluginId` 相同，否则返回 `plugin.function.wrongPlugin`。

两层检查都不认识任何插件名。宿主只是把“实例属于哪个插件”这个事实原样传下去。

### 2. 只有插件自己拥有的进程才提供函数

`MacBuildProviderSessions` 用 `startPluginLanguageServer(pluginID:…)` 启动 Provider，Core 因此能协商这个进程的函数。

如果 Provider 其实是一个共享语言服务器（清单里写的是 `languageServer`），宿主直接拒绝，错误码是 `plugin.function.unavailable`。共享语言服务器是宿主为一种语言的所有插件启动的，不属于任何一个插件，让它提供某个插件的函数会把归属弄乱。

宿主自己的语言服务器仍然不带 `pluginId`，行为不变。

### 3. 每次调用都要过同意和上限

- **同意**：`functions.list` 和每次 `functions.invoke` 都要经过宿主现有的进程启动同意（`PluginWebPages.confirmProcessStart`），和 `build.*` 是同一套工作区信任规则。同一插件在同一工作区同意过一次后，本次打开项目期间不再弹框；关闭并重新打开项目后会重新询问。
- **上限**：一个页面最多同时有 16 个调用，等待同意的调用也计入。调用在等待同意之前就占用名额并登记 `call` ID，因此并发请求不会同时通过旧计数，等待同意期间的 `functions.cancel` 也会让它在获准后不再启动。
- **`call` ID**：页面用过的 `call` ID 在页面生命周期内永久拒绝复用（结束或取消后也一样），旧调用迟到的进度不会被认成新调用；集合随页面关闭释放。
- **页面关闭**：取消该页面所有正在跑的调用。

### 4. 结果按 Core 的稳定码原样返回

| 情况 | 页面收到的结果 |
| --- | --- |
| 成功 | `{ value }` |
| 调用被拒或调用失败 | Core 的码原样返回：`plugin.function.*`、`requestCancelled`、`requestTimeout` |
| 插件后端自己报告的失败 | 额外带上 `pluginErrorCode`。宿主只透传这个码，从不按它分支 |
| 进度 | 发出 `functions.progress` 事件，只有调用时给了 `call` ID 才发，否则页面无法把进度对应到某一次调用 |
| 取消 | 宿主会调用 `lsp.cancelOperation` |
| Core 送不出去（例如写入已退出的后端） | 保留 Core 的传输码（如 `processFailed`），OS 诊断文字只进 `message`。只有 Core 的五个拒绝码（`invalidReference`、`invalidParams`、`unavailable`、`wrongPlugin`、`unknown`）会从 `details` 提升为页面的 `code` |

### 5. 不阻塞主线程

Core 的 `lsp.functionRequest` 和 `lithe/build/*` 请求是同步把消息写进后端 stdin 的。后端卡住、不再读 stdin 时，大参数会把管道写满，写入一直阻塞；Core 的 `stop` 和 `cancelOperation` 还要拿同一把写锁。所以：

- 插件会话的请求、取消和“有写入在途时的停止”都在后台任务里调用 Core，主线程只等结果。
- 有写入在途时，会话暂停轮询 Core 事件，保证回复不会先于操作登记到达；写入结束后照常轮询。
- **逃生路径**：写入超过调用自己的超时仍未返回，或调用被取消、Provider 被停止后 2 秒仍未返回，宿主立即结束这个后端（见决策 6 的标记）。写入随即失败，Core 把会话判为失败并释放写锁。
- Provider 正在启动时，每个调用各自等待共享的启动任务。取消一个调用只结束它自己的等待，不取消别的调用也在等的启动；启动失败由启动任务自己清理登记。

### 6. 不留进程

函数和 `lithe/build/*` 用的是同一个 Provider 会话，也走同一套进程表。下面这些已有的停止路径都会把它停掉：项目关闭（`retainProviders`）、插件停用或替换（`stopProviders(ofPlugin:)`）、设置变更引起的重启。本次没有新增缓存目录。

后端被强杀或崩溃时，SDK 来不及结束它启动的工具。这条边界由宿主的[统一子进程生命周期](../../proposed/architecture/2026-10-16-unified-child-process-lifecycle.md)负责：

- 每个 Provider 启动时，宿主在它的环境里放一个独有的 `LITHE_PLUGIN_BACKEND_SCOPE`（UUID）。它和 `LITHE_PROCESS_SCOPE` 一样被所有后代继承，`setsid` 或被重新挂到 `launchd` 后也还在；SDK 的 `runProcess` 在插件替换 `env` 时也强制带上这两个标记。
- 会话结束、交还给 Core 之后，宿主在本实例的 `LITHE_PROCESS_SCOPE` 里找出带这个标记的进程，按 PID 加启动时间的精确身份先 `SIGTERM`、过了设置里的优雅停止时间再 `SIGKILL`，全程不在主线程。
- 只覆盖插件后端，不覆盖 jdtls 等宿主自己的语言服务器。退出应用时的整体清理仍由统一生命周期的实例扫尾负责。
- Windows 没有插件后端宿主，暂无对应实现。

### 7. `lithe/host/*` 暂缓

这次只做了评估，没有设计宿主能力，原因如下：

- **没有真实需求**：Maven、Gradle 的第一批函数只需要读 Provider 已经算好的状态。真正需要“请宿主跑进程”的场景，要等 PR 4 把 Maven 插件迁过来才能确认参数形状。
- **权限还没定**：进程能力意味着插件后端能在用户机器上执行任意命令。这需要和安装审查、工作区信任、`executesProjectCode` 一起设计，不能只加一个方法名。
- **兼容成本低**：契约已经规定宿主能力要随新的协议版本逐个开放。现在不开放，以后加也不会破坏旧插件。

所以版本 1 继续对所有 `lithe/host/*` 请求返回 `plugin.host.unavailable`。

### 正确做法

```text
插件网页: lithe.request("functions.invoke", {instance, function: "snapshot.read", call: "c1"})
  → PluginWebBridge.entry() 确认实例属于本插件 → 同意框
  → BuildSystemService.invokePluginFunction → MacBuildProviderSessions（本插件的 Provider 会话）
  → Core lsp.functionRequest {function: {pluginID, functionID}}（Core 再校验 pluginID）
```

### 不要这样做

```text
if pluginID == "dev.lithe.maven" { 启动带函数的会话 }   // 宿主按插件名开特例
让共享 JDT LS 会话带上某个插件的 pluginId           // 一种语言的所有插件共用这个进程
在宿主的 Swift 原生界面里直接调别的插件的函数         // 绕过了“只有插件自己能调用”的边界
```

## 考虑过的备选方案

### 让宿主的原生界面也能调用函数

例如在构建工具窗口里给每个函数加一个按钮。没有采用，原因有两个：

- 函数是插件私有的，宿主不知道参数长什么样，也不知道结果怎么展示。
- 原生界面要展示什么，应该由类型化的领域能力决定，插件函数不能替代领域能力。

### 新增一个独立的插件后端进程类型来跑函数

没有采用。构建 Provider 已经是插件自己的 JSON-RPC 进程。再加一种进程，还得重新做一遍启动、同意、设置重启和清理。

### 现在就开放 `lithe/host/process.run`

没有采用，理由见决策 7。

## 后果

- **收益**：插件能在自己的网页里调用自己后端的私有动作，带进度、取消和插件错误码，宿主里没有插件特例。
- **收益**：协议没有新版本，旧插件包和旧后端都不受影响。
- **代价**：只有 macOS，并且只有“构建 Provider 由插件自己的进程实现”时才有函数。纯声明式插件和共享语言服务器都没有函数。
- **代价**：同意只在一次项目会话内记住（与 `build.*` 一致），每次重新打开项目都要再确认一次。以后可以随工作区信任设计统一的记忆规则。
- **代价**：插件后端还不能请宿主做任何事。
- **代价**：有写入在途时同一会话的其他事件会暂缓投递。正常写入只需毫秒；只有后端卡住时才会暂缓到逃生路径结束它。

## 验证

- `scripts/test-macos.sh --filter "PluginWebBridgeTests|MacBuildProviderSessionsTests"`，覆盖以下场景：
  - 页面只能访问本插件的实例，并且必须同意。
  - 结果、进度和 `pluginErrorCode` 能到达页面。
  - 取消调用和关闭页面都会取消函数。
  - Provider 以插件会话启动，并带上 `pluginID`。
  - Core 拒绝时保留 `plugin.function.*` 码。
  - 取消会调用 Core 的 `cancelLanguageServerOperation`。
  - 停用插件会停止 Provider。
  - 写入被阻塞时主线程不被占用；调用取消或 Provider 停止后，宿主立即结束该后端，调用随之结束。
  - 传输失败保留 `processFailed`，OS 错误文字不会成为页面的 `code`。
  - Provider 初始化中取消调用会立刻结束该调用，启动继续并服务下一次调用；初始化中停止时迟到的 ready 不会触发请求。
  - 每个 Provider 带独有的 `LITHE_PLUGIN_BACKEND_SCOPE`，会话结束后宿主按该标记优雅结束遗留进程。
- `./scripts/verify-runtime-bundle-immutability.sh`：确认没有新增写入 bundle 的路径。
- macOS 原生验收（2026-10-20，PR #1366 合并 PR #1365 后的 debug 应用）：
  - 环境：`sdk/node/examples/sample-build` 加一个只用于验收的网页窗口，作为开发包从磁盘安装；另装一个带自己构建系统和网页窗口的验收插件；示例工作区含成功、失败（退出码 3）和长时间运行三个项目。页面把每一步结果写进 `ui.setState`，验收读取 Application Support 中的状态文件核对。
  - `functions.list` 返回 `snapshot.read`、`workspace.build`；一次成功构建后再列出，多了运行时注册的 `snapshot.clear`。
  - `functions.invoke` 带 `call` 时，页面依次收到 `Preparing`、`Building app`、`Done` 三个 `functions.progress`，结果作为 `{ value }` 到达；失败项目返回 `plugin.function.failed`，并带上插件自己的 `pluginErrorCode: sample.buildFailed`。
  - `functions.cancel` 后调用以 `requestCancelled` 结束；构建子进程在取消后立刻退出（采样中最后一次出现早于取消约 0.1 秒）。对已结束的 `call` 再取消返回 `{}`。未注册的函数返回 `plugin.function.unknown`，`params` 不是对象返回 `plugin.web.invalidRequest`。
  - 另一个插件的页面用 `sample:.` 调用 `functions.list` / `functions.invoke` 都得到 `plugin.web.forbidden`，并且在弹同意框之前就被拒绝；它调用自己实例上的 `snapshot.read` 得到 `plugin.function.unknown`，说明函数按进程隔离。
  - 进程清理：调用进行中关闭项目、或在设置里停用插件，Provider 及其构建子进程都会退出（`ps`/`pgrep` 确认）；从磁盘替换插件包时旧 Provider 也会停止；退出应用后没有任何 Lithe 或插件进程残留。重启应用后 `snapshot.read` 返回上次会话的快照。
  - 验收发现示例的路径检查在宿主 `rootUri` 带尾部斜杠时拒绝所有路径（macOS 传的是目录 URL 的 `absoluteString`），所有构建都报 `sample.config`。已在示例里用 `path.resolve` 规范化根目录，并让 `rust/lithe-core/tests/plugin_sdk_node.rs` 用带尾部斜杠的 `rootUri`；未修复时该测试失败，修复后通过。
- `./scripts/verify-platform-feature-matrix.sh`：`plugin-functions` 的 macOS 证据已更新。

## 适用范围

- `macos/Sources/Lithe/Application/Features/PluginWebBridge.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/Web/MacPluginWebPage.swift`
- `macos/Sources/Lithe/Platform/MacOS/Build/MacBuildProviderSessions.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacPluginBackendProcesses.swift`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacProcessScope.swift`
- `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift`
- `macos/Sources/Lithe/Core/Rust/RustLanguageServerRuntimeAdapter.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Runtime/LanguageServerSession.swift`
- `macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift`
- `macos/Sources/LitheCoreContracts/Language/LanguageServerRuntimeContracts.swift`
- `macos/Sources/LitheCoreContracts/Execution/BuildSystemContracts.swift`
- `shared/contracts/plugins/v1/README.md`
