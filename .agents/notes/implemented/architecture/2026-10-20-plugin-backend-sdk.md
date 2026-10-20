# Agent 笔记：官方插件后端 SDK（Node）

状态：已实现

## 先说结论

Lithe 现在有第一个官方插件后端 SDK：`sdk/node`（包名 `@lithe/plugin-sdk`）。插件作者用 Node 写后端时，只写处理器（handler，收到一次请求后执行的函数）；JSON-RPC 帧、`litheBuild` 和 `litheFunctions` 协商、取消、进程清理、错误映射都由 SDK 负责。

SDK 只**实现**契约，不**定义**契约。协议仍以 `shared/contracts/plugins/v1/README.md` 为准，SDK 不新增任何线上字段；不用 SDK 手写的后端同样合法。SDK 的价值是把“不能破坏 Lithe 统一管理”的规则变成默认行为：不发 `lithe/*` 回调、stdout 只走协议、状态只写宿主给的目录、调用结束时进程树一起结束。

示例插件 `sdk/node/examples/sample-build` 通过真实 Core 会话端到端验证（`rust/lithe-core/tests/plugin_sdk_node.rs`），已挂进 Rust Core CI lane。

## 问题

Issue #1351 的目标是给插件开发者开放官方 SDK，同时“保留创造性”又“不影响 Lithe 本身的功能和统一管理”。插件函数契约（见 [插件函数契约与能力方向](2026-10-20-plugin-function-contract.md)）已经落在 Core，但开发者要自己完成以下工作才能写出一个后端：

- 实现 `Content-Length` 分帧和 JSON-RPC 请求/回复配对。
- 在 `initialize` 中正确回答 `litheBuild`、`litheFunctions` 两个协商块，并遵守函数 ID、错误码和结果大小的限制。
- 处理 `$/cancelRequest`、`shutdown`、`exit`，并在取消时结束自己启动的子进程（含孙进程）。
- 找一个可写目录存状态，且不能写进只读的插件包。

每个插件都自己写一遍，最常见的坏结果是：往 stdout 打日志把协议帧弄坏；取消后子进程还在跑；状态写进插件包，破坏代码签名和 Sparkle 增量更新基线；异常信息带出本机路径；或者为了省事请求宿主 `lithe/build/*`，形成自己等自己的递归调用。

## 决策

### 1. 先做 Node，放在仓库根目录 `sdk/node`

Lithe 的 `runtime` 启动方式已支持 `node` 和 `java`。Node 无需编译、单文件即可分发、启动快，最适合作为第一个 SDK。目录放在根目录 `sdk/`，与 `shared/`（契约）、`Plugins/`（具体插件包）分开：`sdk/` 是可被插件复制使用的库代码，不属于任何一个平台，也不是契约本身。

### 2. 零依赖、复制进插件包使用

插件包安装后只读、没有 `npm install` 步骤、必须能离线运行。所以 SDK 不依赖任何 npm 包，插件作者把 `src/` 复制到包内用相对路径导入。`package.json` 标 `private: true`，暂不发布到 npm；等 API 稳定后再决定发布方式。

### 3. 规则变成默认行为，而不是文档里的建议

| 统一管理的规则 | SDK 怎么做 |
| --- | --- |
| 领域能力必须类型化 | `backend.build.model/dependencies` 单独入口，SDK 自动补 `format` 和 `version`；函数入口不能代替它 |
| 不能回调宿主派发 | `sendRequest`/`sendNotification` 拒绝任何 `lithe/*` 方法；`onRequest` 拒绝保留方法；`capabilities` 里不能自己写 `litheBuild`/`litheFunctions` |
| stdout 只给协议 | 用 stdio 服务时把 `console.log/info/debug` 改到 stderr |
| 插件包只读 | `openStateStore` 先解析真实路径，目录在插件包内就拒绝，且在创建目录之前拒绝 |
| 工作随调用结束 | `context.run` 绑定调用的取消信号；处理器返回或抛错时，该调用仍在运行的工具（未 await 的、`Promise.all` 失败后的兄弟）同样结束，不影响其他调用；POSIX 用进程组，先 SIGTERM，宽限期后 SIGKILL，工具正常退出时一并结束它留在组里的成员；Windows 用 `taskkill /T /F`；会话结束时结束全部进程 |
| 后端被强杀时不在 SDK 内兜底 | 后端被 SIGKILL 时 JS 不再执行，SDK 无法清理。这条边界由宿主的统一进程生命周期负责（`LITHE_PROCESS_SCOPE` 与每个后端独有的 `LITHE_PLUGIN_BACKEND_SCOPE` 标记，按精确身份结束进程），不在 SDK 里另起监督进程。`runProcess` 的 `env` 替换环境时仍强制带上这两个标记，插件既不能丢掉也不能伪造 |
| 错误可展示、不泄漏 | 只有 `PluginError` 能带 `pluginErrorCode`；其他异常一律回通用文案，细节写 stderr |

正确做法：Maven 插件的函数处理器用 `context.run('mvn', [...])` 跑命令，用户取消时 Maven 进程树会一起结束。

不要这样做：处理器里 `backend.sendRequest('lithe/build/model', …)` 让宿主“帮我算模型”——SDK 直接抛错，Core 侧也会回 `plugin.function.recursiveCall`。

### 4. 初始化钩子里也能注册函数

端到端测试发现：插件常常要在 `initialize` 时读状态，再决定提供哪些函数（示例里“有快照才提供 `snapshot.clear`”）。此时还没回复 `initialize`，宿主也还没协商，发 `lithe/function/register` 会失败。SDK 规定：回复 `initialize` 之前调用 `registerFunction`/`unregisterFunction`，直接修改初始函数列表；之后才走注册请求，并按顺序排队。

## 考虑过的备选方案

### 只写协议文档，不提供 SDK

被否：上面列出的坏结果都来自“每个插件自己实现一遍”。文档无法阻止 stdout 打日志或子进程泄漏，SDK 可以把它们变成默认行为。

### 依赖 `vscode-languageserver` 等现成 npm 包

被否：插件包没有安装步骤，依赖必须一起打包，体积和许可证审查都变大；这些库也不知道 `litheFunctions`、只读插件包和进程树清理。分帧和 JSON-RPC 只需要几百行，自己维护成本更低。

### 先做 Java SDK

暂缓：Maven、Gradle 插件最终可能更适合 Java，但 Java 需要编译和打包 jar，示例和测试链路都更重。Node SDK 先把规则和测试方式定下来，Java SDK 以后按同一份契约和同一组端到端断言实现。

### 让 SDK 增加便利字段（如函数描述、参数 schema）

被否：SDK 不能定义协议。需要的字段应先进入 `shared/contracts/plugins/` 的新协议版本，再由 SDK 实现，否则用 SDK 的插件和手写后端的行为会分叉。

## 后果

- 收益：插件作者只写处理器；取消、清理、错误映射和状态存储默认正确，Lithe 的统一管理规则不依赖作者自觉。
- 收益：示例插件经过真实 Core 会话验证，契约改动若破坏 SDK，Rust Core lane 会直接失败。
- 代价：SDK 以复制源码方式分发，插件里的副本不会自动升级；修复安全问题时需要插件重新发布。
- 代价：仓库新增一个顶层目录和一条 CI 测试，`sdk/*` 改动会触发 Rust Core lane。
- 代价：宿主还没有调用函数的界面入口，也没有宿主能力（`lithe/host/*`）；Windows 没有插件后端宿主。SDK 目前对用户不可见，只给开发者和后续 PR 使用。

## 验证

- `node --test sdk/node/test/*.test.mjs`：协商、ID 规则（对照 `function-protocol.json`）、保留方法、调用/进度/错误/取消、运行时注册、构建结果、生命周期和退出码、分帧、进程树取消、状态存储与只读包拒绝、类型声明与运行时导出一致。
- `LITHE_PLUGIN_SDK_NODE="$(command -v node)" cargo test --manifest-path rust/Cargo.toml -p lithe-core --test plugin_sdk_node`：示例插件经 Core 校验、启动计划、版本检查、构建模型/依赖、函数结果/进度/失败/取消、重启后状态恢复，最后确认插件包文件清单不变。
- `./scripts/verify-rust-core-crates.sh`：CI 中同时运行以上两项。
- `bash scripts/test-classify-ci-changes.sh`：`sdk/*` 改动被分到 Rust Core lane。

## 适用范围

- `sdk/node/`
- `rust/lithe-core/tests/plugin_sdk_node.rs`
- `scripts/verify-rust-core-crates.sh`
- `scripts/classify-ci-changes.sh`
- `shared/contracts/plugins/v1/README.md`
