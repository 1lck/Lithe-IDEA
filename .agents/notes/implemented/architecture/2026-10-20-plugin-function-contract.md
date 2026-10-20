# Agent 笔记：插件函数契约与能力方向

状态：已实现

## 先说结论

插件后端进程（语言服务器或构建 Provider，插件自己启动、用 JSON-RPC 通信的进程）现在可以提供**插件函数**（Plugin Function）：只属于这个插件、参数和结果都可序列化的动作，例如插件自己窗口里一个按钮背后的步骤。协议名是 `litheFunctions` 版本 1，在 `initialize` 里协商，与 `litheBuild` 互不依赖；契约写在 `shared/contracts/plugins/v1/README.md` 的 “Plugin functions” 一节，标准答案在 `fixtures/function-protocol.json`。

这次同时定下了能力的三个方向：插件提供**领域能力**（构建模型、依赖树，契约归 Lithe）、插件提供**插件函数**（契约归插件）、插件调用**宿主能力**（契约归宿主）。领域操作仍走类型化的 `lithe/build/*`，插件函数不能代替它；后端也不能请宿主再派发领域操作或函数，避免处理器绕回自己。

Rust Core 负责校验、路由、协商和测试（`lsp/interface/plugin_function.rs`、`lsp.functionRequest`）。macOS 宿主的调用入口见[宿主调用插件函数的入口](2026-10-20-host-plugin-function-invocation.md)：只有插件自己的网页、只对插件自己的构建 Provider 进程。版本 1 不提供任何宿主能力。旧插件包和旧后端不受影响。

## 问题

Issue #1351 要把 Maven、Gradle 这类插件从“只给声明”推进到“插件自带逻辑”。动手前盘点了已有的几条通道，发现它们各自解决一部分，但没有一条同时具备回复、进度、取消和归属：

- **声明式 `buildSystems`**：Core 计划命令、解码输出。能力固定为模型、任务、测试、依赖等十个能力块，插件自己的一次性动作（刷新私有快照、准备安装）没有位置。
- **构建 Provider（`litheBuild`）**：LSP 基础协议进程，只回答 `lithe/build/model` 和 `lithe/build/dependencies`，回复由 Core 解码。它是领域协议，不适合放插件私有动作。
- **LSP 引擎**（`lsp/interface/engine.rs`）：已经有请求超时、`$/cancelRequest`、迟到回复丢弃和 `client/registerCapability`，是现成可复用的调用机制。
- **macOS `ModuleContracts.swift`**：有事件和贡献点，但没有回复、进度和取消。`MacPluginStartupLoader` 不加载插件代码。
- **macOS `PluginWebBridge`**：网页插件只能调用固定的 `build.*` 方法。
- **Windows `ui-extension-worker-runtime.ts`**：有 `hostCall`（数字 ID）和 `commands.register`，超时在 `ui-extension-host.ts`；它是 UI 扩展通道，跟后端进程无关。

如果不先定边界，后续很容易出现两种坏结果：一是给每个插件开一个“万能调用”通道，把构建协议也塞进去，宿主和其他平台就再也无法按类型理解结果；二是插件处理器调用宿主的“运行任务”，宿主又把任务路由回同一个插件，处理器等待自己，直到超时。

## 决策

### 1. 三个方向，各有一个契约所有者

| 方向 | 谁定义契约 | 谁实现 | 怎么传 |
| --- | --- | --- | --- |
| 插件提供领域能力 | Lithe | 插件（声明或后端） | 清单 `source`，Core 计划和解码，类型化的 `lithe/build/*` |
| 插件提供插件函数 | 插件 | 插件后端 | `lithe/function/invoke` |
| 插件调用宿主能力 | 宿主 | 宿主 | `lithe/host/*`，按协议版本逐个开放 |

开发者判断时只问一句：**结果要不要被 Lithe 理解？** 要被 IDE 工作流、展示层或另一个平台使用的，就是领域能力，必须有类型化契约；只给插件自己界面用的，才是插件函数。

### 2. 禁止回调自己

后端向宿主请求 `lithe/function/invoke` 或任何 `lithe/build/*`，Core 直接回 JSON-RPC `-32601`，`data.code` 是 `plugin.function.recursiveCall`。宿主能力只开放进程运行、输出、存储这类原语，不开放“再进入某个领域注册表”的入口：Maven 处理器需要跑 Maven，应当请求宿主的进程能力，而不是请求宿主“执行 Maven 任务”。版本 1 一个宿主能力都没有开放，`lithe/host/*` 一律是 `plugin.host.unavailable`；每个宿主能力加入时要和参数、权限、所属操作一起进入新的协议版本。

### 3. 引用、注册与撤回

- 函数引用是 `{pluginID, functionID}`。Core 先按插件路由：只有 `lsp.startServer` 时带同一个 `pluginId` 的会话才提供该插件的函数；宿主自己的语言服务器没有 `pluginId`，不发送或接受函数协议协商，不保留函数注册表，也不发布函数发现事件，增删请求一律以 `-32601` 拒绝。所以一个插件拿不到另一个插件的函数，也不需要在宿主里按插件名判断。
- 函数 ID 是点分的 lowerCamelCase 段（`snapshot.refresh`），最长 128 字节，每个会话最多 256 个。
- 后端在 `initialize` 回答里给出初始函数，之后用 `lithe/function/register`、`lithe/function/unregister` 增删。每个请求要么全部生效，要么整体拒绝（`plugin.function.invalidRegistration`），不会留下半个注册表；初始回答里有坏 ID 时整个协议不算协商成功，原因相同。插件会话成功完成 `initialize` 函数协议协商后发布一次 `functionsChanged`，带排序后的初始列表与空 `removed`，即使列表为空也发布；宿主因此只订阅事件就能发现初始函数，不必先尝试调用。
- 撤回一个正在执行的函数时，调用立即以 `plugin.function.revoked` 结束，Core 同时发 `$/cancelRequest`。

### 4. 调用、结果和错误码

宿主调用 `lsp.functionRequest`，返回 `operationId`；宿主取消、完成和进度始终使用这个 ID。Core 为每次后端调用分配唯一且不透明的 `operationID`，后端在进度中原样回显，Core 再转换为宿主 ID（包括 `requestProgress.result.operationID`）。宿主可以在一次调用终止后复用自己的 ID，后端的旧进度也不会落到新调用。Core 在写入进程之前按固定顺序检查：引用格式 → 参数是对象 → 会话归属插件 → 协议已协商 → 函数已注册，任一失败都同步拒绝，稳定码放在 `CoreError.details`。

结束时恰好一个 `requestCompleted`：结果包成 `{value}`，和构建回复一致；后端错误统一为 `plugin.function.failed`，并把后端 `error.data.code` 作为 `pluginErrorCode` 透传给插件自己的界面。Lithe 只按稳定码分支，**从不按 `pluginErrorCode` 分支**，否则插件私有的错误码就会变成宿主里的特例。

### 5. 进度、超时、取消、迟到结果

全部复用 LSP 引擎已有机制，不另起一套：超时默认取会话的请求超时，最多一小时；取消和超时都会发 `$/cancelRequest`；调用结束后，迟到的回复和进度都会被丢弃。进度用通知 `lithe/function/progress {operationID, message?, percentage?}`，Core 只在该后端 ID 仍对应当前待处理函数请求时发布 `requestProgress`。

函数名、宿主操作 ID 与 JSON-RPC 请求 ID 的关联只属于这次调用。成功、失败、取消、超时、撤回和会话结束都要移除关联；撤回还要核对当前待处理请求的方法与请求 ID。正确示例是：函数 A 取消后，宿主用同一个 ID 发构建请求，后端撤回 A 只更新注册表，不取消新构建。错误做法是只按宿主 ID 查函数关联，旧映射会把新构建误当成仍在执行的 A。

### 6. 声明式还是后端实现

- 每个领域操作在清单里**静态**选定一种实现（`source`），Core 只计划这一种。**没有运行时回退**：后端失败时退回模板，用户看到的结果可能悄悄变了含义。
- 后端实现领域操作时，走类型化方法加 Core 的计划和解码，不走插件函数。
- 插件函数不进清单，能回答什么完全靠协商，所以增删函数不提升 `pluginAPIVersion`，也不提升任何 `requires` 版本。
- 新的领域实现方式（例如任务执行由 Provider 实现）属于拥有它的能力的新版本（`buildProviders`），只有用到它的插件才会被旧宿主过滤。

### 7. 旧包兼容

- 所有 API 级别的旧插件包不变：函数没有新增清单字段。
- 不认识 `litheFunctions` 的后端照常服务语言和 `litheBuild`，不会收到函数调用；它发来的函数请求得到 `-32601`。
- 对方不能忽略的新字段或新宿主能力，只能放进新的协议版本，与旧版本一起提供。

### 正确做法

```text
Maven 插件窗口的“刷新快照”按钮
  → 宿主 lsp.functionRequest {function: {pluginID: "dev.lithe.maven", functionID: "snapshot.refresh"}}
  → 插件后端处理，需要跑 mvn 时（以后）请求宿主进程能力 lithe/host/process.run
构建模型
  → build.modelPlan 得到 provider.method = lithe/build/model → lsp.buildRequest → build.decodeModel
```

### 不要这样做

```text
插件函数 "model.load" 返回宿主要用的构建模型        // 领域结果绕过了类型化契约和 Core 解码
后端请求 lithe/build/model 或 lithe/function/invoke  // 宿主可能路由回自己，处理器等待自己
宿主 if pluginErrorCode == "maven.xxx" { ... }        // 插件私有码变成宿主特例
```

## 考虑过的备选方案

### 一个无类型的通用调用代替构建协议

让所有插件逻辑都走 `invoke(name, params)`，构建模型也是一个函数。被否：宿主和 Windows 无法按类型理解结果，Core 的解码、路径校验和运行入口推导会被绕过，而且每个宿主都要各自猜结果形状。插件函数只用于插件私有动作。

### 在清单里声明函数

在 `plugin.json` 加 `functions[]`，安装审查时展示。被否：函数是后端运行时才知道的事实，声明和进程回答会不一致；新增清单字段还要提升 API 级别，让旧宿主过滤掉本来能用的插件。函数不扩大权限，进程本身的权限已经在安装审查里确认过。

### 让后端请求宿主执行领域操作

例如 Provider 在处理器里请宿主“跑 Maven 任务”。被否：宿主可能把请求路由回同一个插件，形成递归等待；改为只开放进程、输出、存储这类原语，且在版本 1 里一个都不开放，等真正需要时随权限一起设计。

### 声明式失败时自动回退到后端，或反过来

被否：两种实现可能对同一份工程给出不同结果，回退会隐藏真正的失败，用户也不知道自己看到的是哪种结果。

### 新建一种插件进程或单独的 RPC 通道

被否：语言服务器和构建 Provider 已经是 JSON-RPC 进程，引擎里已有超时、取消、迟到丢弃和注册能力。再造一条通道会重复这些状态机。函数协议只是同一会话上的另一组方法。

### 让后端直接使用宿主操作 ID，或永久禁止复用

后端直接回显宿主 ID 虽少一次映射，但函数 A 已结束、宿主用同一 ID 调用函数 B 时，A 的迟到进度仍会被误认成 B。永久保存已用 ID 并拒绝复用也能隔离，却会引入随会话历史增长的墓碑集合，并改变宿主调用习惯。采用每次调用唯一的后端 ID：只保留正在执行的关联，后端原样回显，宿主接口继续允许在终止后复用 ID；代价是 Core 必须在全部终止路径删除关联并在事件出口转换 ID。

### 复用 LSP 的 `workspace/executeCommand`

被否：它没有插件归属、没有稳定错误码和进度约定，命令名也和语言服务器自己的命令混在一起；JDT LS 这类共享进程会收到本不属于它的调用。

## 后果

- 收益：插件私有动作有了带回复、进度、超时、取消和归属的统一通道，宿主不需要知道任何插件名；领域能力、插件函数和宿主能力的边界写进契约，后续 PR 2–4 可以直接按方向加东西。
- 收益：旧插件包、旧后端和 `litheBuild` 版本 1 都不变，不需要发新 API 级别。
- 代价：函数不进清单，安装审查看不到插件会提供哪些函数；如果以后函数需要额外权限，必须随新协议版本补审查。
- 代价：本 Note 只覆盖 Core 一侧；宿主入口另见[宿主调用插件函数的入口](2026-10-20-host-plugin-function-invocation.md)，宿主能力仍未开放。
- 后续：后端一侧的官方实现见 [官方插件后端 SDK（Node）](2026-10-20-plugin-backend-sdk.md)，它只实现本契约，不新增线上字段。
- 代价：没有操作系统级沙盒，隔离仍只到进程和通信通道。

## 验证

- `cargo test -p lithe-core --lib plugin_function`：`function-protocol.json` 的协商、注册、调用、结果、进度和后端请求全部标准答案，以及消息截断、超大结果和注册上限。
- `cargo test -p lithe-core --lib lsp::interface::engine`：用脚本化后端覆盖路由与结果、失败与插件错误码、初始函数列表（包括空列表）只靠事件发现、取消/超时/成功/失败/撤回后复用宿主 ID 的迟到进度隔离、函数结束后复用 ID 发构建请求不受旧函数撤回影响、会话停止/失败后清空注册表且迟到注册不能恢复能力、自身超时、只支持 `litheBuild` 的旧后端照常工作、宿主自有会话不提供函数、后端请求回调自己被拒绝。
- `./scripts/verify-shared-contracts.sh`：`function-protocol.json` 的 schema 版本、协议名、用例名唯一、错误码都在 README 里有文档、不含机器路径。
- `./scripts/verify-rust-core.sh` 与 `./scripts/verify-rust-core-comments.sh`：Core 编译、测试和注释规范。

## 适用范围

- `rust/lithe-core/src/lsp/interface/plugin_function.rs`
- `rust/lithe-core/src/lsp/interface/client.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `rust/lithe-core/src/protocol/command.rs`
- `rust/lithe-core/src/runtime/dispatcher.rs`
- `shared/contracts/plugins/v1/README.md`
- `shared/contracts/plugins/v1/fixtures/function-protocol.json`
- `shared/contracts/rust-core-api.md`
- `scripts/verify-shared-contracts.sh`
