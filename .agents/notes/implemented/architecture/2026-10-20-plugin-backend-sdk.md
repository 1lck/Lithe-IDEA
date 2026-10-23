# Agent 笔记：官方插件后端 SDK（Node、Java）

状态：已实现

## 先说结论

Lithe 有两个官方插件后端 SDK：`sdk/node`（包名 `@lithe/plugin-sdk`）和 `sdk/java`（`lithe-plugin-sdk-java`，Java 8 起可用）。插件作者只写处理器（handler，收到一次请求后执行的函数）；JSON-RPC 帧、`litheBuild` 和 `litheFunctions` 协商、取消、进程清理、错误映射都由 SDK 负责。两个 SDK 的规则和错误语义相同。

SDK 只**实现**契约，不**定义**契约。协议仍以 `shared/contracts/plugins/v1/README.md` 为准，SDK 不新增任何线上字段；不用 SDK 手写的后端同样合法。SDK 的价值是把“不能破坏 Lithe 统一管理”的规则变成默认行为：不发 `lithe/*` 回调、stdout 只走协议、状态只写宿主给的目录、调用结束时进程树一起结束。

两个 SDK 各有一个示例插件（`sdk/*/examples/sample-build`），经真实 Core 会话跑**同一套**端到端场景（`sdk/e2e/plugin_sdk/mod.rs`）。所以任一 SDK 与契约或另一个 SDK 的行为出现分叉时，测试都会失败。

2026-10-23 起，两个 SDK 的源码、发版和端到端测试都在 [lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs) 的 `sdk/` 下，主仓库不再保存 SDK。插件开发者只看那个仓库就能拿到契约副本、SDK 和教程。迁移原因见 [插件契约、SDK 与开发者资料的发布](2026-10-23-plugin-contract-publishing.md)；下文出现的 `sdk/...` 路径都指 lithe-plugin-docs。

## 问题

Issue #1351 的目标是给插件开发者开放官方 SDK，同时“保留创造性”又“不影响 Lithe 本身的功能和统一管理”。插件函数契约（见 [插件函数契约与能力方向](2026-10-20-plugin-function-contract.md)）已经落在 Core，但开发者要自己完成以下工作才能写出一个后端：

- 实现 `Content-Length` 分帧和 JSON-RPC 请求/回复配对。
- 在 `initialize` 中正确回答 `litheBuild`、`litheFunctions` 两个协商块，并遵守函数 ID、错误码和结果大小的限制。
- 处理 `$/cancelRequest`、`shutdown`、`exit`，并在取消时结束自己启动的子进程（含孙进程）。
- 找一个可写目录存状态，且不能写进只读的插件包。

每个插件都自己写一遍，最常见的坏结果是：往 stdout 打日志把协议帧弄坏；取消后子进程还在跑；状态写进插件包，破坏代码签名和 Sparkle 增量更新基线；异常信息带出本机路径；或者为了省事请求宿主 `lithe/build/*`，形成自己等自己的递归调用。

## 决策

### 1. 先做 Node，SDK 单独成一个目录

Lithe 的 `runtime` 启动方式已支持 `node` 和 `java`。Node 无需编译、单文件即可分发、启动快，最适合作为第一个 SDK。SDK 与 `shared/`（契约）、`Plugins/`（具体插件包）分开：它是可被插件复制使用的库代码，不属于任何一个平台，也不是契约本身。最初放在主仓库根目录 `sdk/`，后来整体移到 lithe-plugin-docs 的 `sdk/`。

### 2. 零依赖、复制进插件包使用

插件包安装后只读、没有 `npm install` 步骤、必须能离线运行。所以 SDK 不依赖任何 npm 包，插件作者把 SDK 复制到包内用相对路径导入。

发布方式和 Java SDK 相同：lithe-plugin-docs 打 `sdk-node-v<版本>` 标签，它的 `.github/workflows/release-node-sdk.yml` 先在 Node 20 上跑 SDK 测试，再用 `npm pack` 生成 `lithe-plugin-sdk-node-<版本>.tgz` 和 `.sha256`，附在 GitHub Release 上。插件仓库在构建时按固定版本和 SHA-256 下载、校验并解开，把 `package/` 目录放进插件包；运行时不下载任何东西。这样外部开发者不用克隆主仓库，也不用给主仓库提 PR。`package.json` 仍标 `private: true`，`npm pack` 不受影响，但 SDK 不会被误发到 npm；等 API 稳定后再决定是否发布到 npm。

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

### 5. Java SDK：零依赖、Java 8、按 JAR + SHA-256 发布

Maven、Gradle 这类插件需要在后端里调用 JVM 生态的工具，并长期持有缓存（例如 Maven 插件的依赖快照），用 Java 写后端更自然。所以 Java SDK 按 Node SDK 的同一份契约和同一组端到端断言实现，并做了这些取舍：

- **最低 Java 8。** 很多企业项目仍在 Java 8 上构建，后端最好能直接用项目那个 JDK 启动。代价是 SDK 只能用 Java 8 的 API。
- **零运行时依赖，自带最小 JSON 读写（`Json`）。** 插件要把 SDK shade（打进同一个 JAR）到自己的后端里。如果 SDK 依赖 Gson 或 lsp4j，就会和插件自己的同名依赖冲突，许可证审查范围也会变大。
- **发布方式：打 `sdk-java-v<版本>` 标签，Release 附带 JAR 和 `.sha256`。** 0.1.0 是从主仓库发布的，已锁定它的插件不用改；之后的版本由 lithe-plugin-docs 的 `.github/workflows/release-java-sdk.yml` 发布。暂不发到 Maven 仓库。插件仓库在构建时按固定版本和 SHA-256 下载并校验，再 shade 进后端 JAR，运行时不下载任何东西。
- **处理器各自跑在守护线程池上，读循环只负责分帧和派发。** 取消不打断（interrupt）线程，只置位取消令牌，并结束该调用启动的进程。这是因为中断会让处理器里正在进行的文件写入半途失败。
- **进程按调用清理，用进程组，与 Node SDK 一致。** 常驻后端不会因为一次调用结束而退出，宿主按 `LITHE_PLUGIN_BACKEND_SCOPE` 的清理要等会话结束才发生，所以 SDK 必须在调用结束或取消时自己结束工具留下的进程。Java 没有进程组 API，macOS 和 Linux 上 SDK 通过系统 `perl`（`setpgrp(0, 0)` 后 `exec` 成工具，PID 不变）让每个工具成为自己进程组的组长：取消时先给整组发 SIGTERM，宽限期后发 SIGKILL；工具正常退出后立即对整组发 SIGKILL，结束它留下的后台进程。信号经 `/bin/kill -- -<pgid>` 发出，因此 Java 8 和 Java 9+ 行为相同；只要组里还有成员，组 ID 就不会被复用，所以不会误伤其他并发调用。`PERL5OPT` 会让 perl 启动时加载模块，SDK 先从 perl 的环境里拿掉，再在 `exec` 前还给工具。启动失败时 launcher 以 127 退出并带固定前缀，SDK 仍抛 `IOException`，与 `ProcessBuilder` 一致。Windows 或没有 `perl` 时退回 `ProcessHandle.descendants()`（Java 9+，Windows 不会重挂父进程，工具退出后仍能找到子孙）；Java 8 只能结束直接子进程。用 `setsid` 脱离进程组的进程，以及退回路径够不到的进程，仍由宿主按后端标记在会话结束时兜底。
- **取消监听器互相隔离。** 一个 `onCancel` 回调抛异常只记录到 stderr，不影响其余回调；调用收尾放在 `finally` 里，保证请求一定回复，宿主不会只等到超时。
- **stdout 保护。** `listen()` 抓住真正的 stdout 只写协议帧，再把 `System.out` 指向 stderr，防止插件或第三方库 `println` 破坏帧。

实现时发现并修复了 Core 的一个问题：运行时版本探测原来对所有工具都用 `--version`，Java 8 不认这个参数，后端会被判定为不可用。现在启动计划复用构建运行时的探测参数（`crate::build::host_runtime_version_arguments`：java 用 `-version`，node 用 `--version`）。宿主把 stdout 和 stderr 合在一起读，`1.8.0` 规范化为 8。

正确做法：Maven 插件后端的依赖从 `pom.xml` 的 shade 配置进入后端 JAR，SDK JAR 的版本和哈希写在插件仓库的锁文件里。

不要这样做：后端启动时去 GitHub 下载 SDK 或依赖，或者在 `onInitialize` 里往插件包目录写缓存。前者离线不可用，后者破坏签名和更新基线，`StateStore.open` 也会直接拒绝。

## 考虑过的备选方案

### 只写协议文档，不提供 SDK

被否：上面列出的坏结果都来自“每个插件自己实现一遍”。文档无法阻止 stdout 打日志或子进程泄漏，SDK 可以把它们变成默认行为。

### 依赖 `vscode-languageserver` 等现成 npm 包

被否：插件包没有安装步骤，依赖必须一起打包，体积和许可证审查都变大；这些库也不知道 `litheFunctions`、只读插件包和进程树清理。分帧和 JSON-RPC 只需要几百行，自己维护成本更低。

### 先做 Java SDK

当时暂缓：Java 需要编译和打包 JAR，示例和测试链路都更重。所以先由 Node SDK 把规则和测试方式定下来，Java SDK 随后按同一份契约和同一组端到端断言实现（见决策 5）。

### Java SDK 依赖 lsp4j 或 Gson

被否：shade 进插件后会和插件自己的同名依赖冲突。lsp4j 也不认识 `litheFunctions`、只读插件包和进程清理规则，SDK 仍要在它外面再包一层。

### Java SDK 从 Java 11 起步，统一用 `ProcessHandle`

被否：Java 8 项目的后端就要单独装一个新 JDK。而且 `ProcessHandle` 只能找到仍挂在工具下面的子孙，工具正常退出后被重挂到 init/launchd 的后台进程照样漏掉，升级版本也补不上这个缺口。

### 只靠宿主的后端进程标记兜底调用级清理

被否：宿主按 `LITHE_PLUGIN_BACKEND_SCOPE` 清理只在后端进程结束或会话释放时发生，常驻后端里一次调用遗留的进程会一直运行并继续改工作区。宿主标记只作为最后一道防线。

### 每次调用设独立环境标记，结束时扫描进程环境

被否：macOS 的 `ps -E` 已不显示其他进程的环境，读取需要 `KERN_PROCARGS2` 这类原生调用，纯 Java 做不到；只在 Linux 上用 `/proc` 扫描会让两个平台行为不一致。进程组方案只依赖系统自带的 `perl` 和 `kill`。

### 让 SDK 增加便利字段（如函数描述、参数 schema）

被否：SDK 不能定义协议。需要的字段应先进入 `shared/contracts/plugins/` 的新协议版本，再由 SDK 实现，否则用 SDK 的插件和手写后端的行为会分叉。

## 后果

- 收益：插件作者只写处理器；取消、清理、错误映射和状态存储默认正确，Lithe 的统一管理规则不依赖作者自觉。
- 收益：示例插件经过真实 Core 会话验证。lithe-plugin-docs 每次提交都用契约副本锁定的那个主仓库 commit 跑端到端测试，每周再用主仓库 `preview` 分支的最新 Core 跑一次，Core 改动破坏 SDK 时会在这里失败。
- 代价：Node SDK 以复制源码方式分发，Java SDK 被 shade 进插件 JAR，插件里的副本都不会自动升级；修复安全问题时需要插件重新发布。
- 代价：SDK 移出主仓库后，主仓库的 PR 不再当场发现“Core 改动破坏 SDK”，最晚由 lithe-plugin-docs 的每周检查发现。改 Core 的插件后端协议时，应在合并前用 lithe-plugin-docs 的 `node scripts/sdk-e2e.mjs --source <本地主仓库> --ref <分支>` 手动跑一次。
- 代价：lithe-plugin-docs 的端到端测试需要 Rust、Node、JDK 和 Maven，每次都要编译一遍 Core；CI 用 Java 8 运行时跑 Java SDK 测试和示例后端，用 JDK 21 编译。
- 代价：宿主还没有调用函数的界面入口，也没有宿主能力（`lithe/host/*`）；Windows 没有插件后端宿主。SDK 目前对用户不可见，只给开发者和后续 PR 使用。

## 验证

以下命令都在 lithe-plugin-docs 中运行：

- `node --test sdk/node/test/*.test.mjs`：协商、ID 规则（对照 `contract/v1/fixtures/function-protocol.json`）、保留方法、调用/进度/错误/取消、运行时注册、构建结果、生命周期和退出码、分帧、进程树取消、状态存储与只读包拒绝、类型声明与运行时导出一致。
- `mvn -B -f sdk/java/pom.xml verify [-Djvm=<java8>]`：Java SDK 的 JUnit 测试，覆盖与 Node 测试相同的协议场景，另含 JSON、分帧、进程树取消和状态存储。
- `node scripts/sdk-e2e.mjs`：把 `sdk/e2e` 复制进锁定版本主仓库的 `rust/lithe-core/tests/`，运行 `plugin_sdk_node` 和 `plugin_sdk_java`。Node 示例经 Core 校验、启动计划、版本检查、构建模型/依赖、函数结果/进度/失败/取消、重启后状态恢复，最后确认插件包文件清单不变；Java 示例按插件实际打包方式（`plugin.json` + shade 后的 JAR）装进临时包目录，跑同一套场景。设置 `LITHE_PLUGIN_SDK_JAVA_RUNTIME` 时，Java 示例在该运行时（CI 为 Java 8）上运行。
- `node scripts/sdk-e2e.mjs --ref preview`：同上，换成主仓库 `preview` 分支的最新 Core；CI 每周运行。

## 适用范围

- `https://github.com/Lithe-IDEA/lithe-plugin-docs`
- `rust/lithe-core/src/plugins/declarative.rs`（运行时启动计划的版本探测参数）
- `shared/contracts/plugins/v1/README.md`
