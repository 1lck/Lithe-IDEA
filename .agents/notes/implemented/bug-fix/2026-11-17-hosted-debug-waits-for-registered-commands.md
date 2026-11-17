# Agent 笔记：语言服务器里的调试适配器要等命令注册后再请求端口

状态：已实现

## 先说结论

有的调试适配器运行在插件的语言服务器里（`transport: tcpLanguageServer`，例如 Java Support 的 `java` 适配器跑在 JDT LS 里）。宿主通过 `workspace/executeCommand` 向语言服务器要调试端口。JDT LS 在“就绪”（初始化完成）之后，才用 `client/registerCapability` 动态注册它的命令；在注册之前，Core 会以 `not_supported`（“The language server did not advertise this capability.”）拒绝这个命令。现在宿主在语言服务器就绪之后，还要等它声明 `executeCommand` 能力，再请求端口。

## 问题

`discoverHostedPort` 以前只等语言服务器就绪（`waitReadyPluginServer`），就立即执行端点命令。如果语言服务器早已在运行，命令早就注册好了，不会出问题。但如果调试是第一个用到语言服务器的操作，例如打开项目后直接调试一个 Spring Boot 服务，那么服务器一就绪宿主就发出命令，这时注册还没到，Core 就会拒绝。用户看到的是调试启动失败，服务也随之被停止。

## 决策

- `discoverHostedPort` 在 `waitReadyPluginServer` 之后调用 `waitPluginServerFeature(ctx, server, "executeCommand", pluginServerStartTimeout)`。
- 能力以 Core 的 `featuresChanged` 事件为准。动态注册之后，Core 会重新发送这个事件，宿主把它记在 `pluginServer.features` 里。这个字段只在窗口线程读写，所以等待方每 50 ms 往窗口线程投递一次检查。
- 超时后返回 `errPluginServerFeatureMissing`，说明服务器从来没有提供这个能力，而不是一直等下去。

正确做法：等语言服务器提供某项能力时，以 `features` 为准。

不要这样做：把“就绪”当成“所有能力都已就位”；或者在命令返回 `not_supported` 时盲目重试。盲目重试分不清“还没注册”和“永远不会提供”。

## 考虑过的备选方案

- 在 Core 里把发给语言服务器的命令排队，等注册以后再发。所有宿主都能受益，但这样 Core 就要替动态注册猜测时序，和它“没有声明就拒绝”的现有规则冲突。另外宿主已经掌握做这个判断所需的事件。
- 在 Java Support 插件里改成静态声明命令。动态还是静态注册由 JDT LS 根据客户端能力自己决定，插件改不了；而且其他语言服务器也可能动态注册。
- 遇到 `not_supported` 时有界重试。能绕过问题，但每次重试都会产生一次失败的请求和日志，也无法提前判断服务器根本不提供该能力。

## 后果

- 调试作为第一个用到语言服务器的操作时也能启动；JDT LS 从冷启动到连上调试器，实测约 15 秒（包含 Maven 编译和服务启动）。
- 等待最长 `pluginServerStartTimeout`（2 分钟）。一个就绪但永远不注册命令的服务器，要等这么久才会失败。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/workbench/ -run TestHostedDebugWaitsForTheServerToOfferCommands -count=1`：服务器声明命令之前，等待不会结束；声明之后立刻返回；从不声明时，在时限内返回 `errPluginServerFeatureMissing`。
- 这个问题是在真实的 JDT LS 上发现的：修复前，调试冷启动的 Spring Boot 服务会失败，报 `lsp.request: The language server did not advertise this capability. (not_supported)`。宿主测试只使用合成插件，所以回归测试直接驱动 `features`，模拟这个时序。

## 适用范围

- `desktop/internal/workbench/debug_start.go`
- `desktop/internal/workbench/debug_tcp_test.go`
- `desktop/internal/workbench/editor_requests.go`
