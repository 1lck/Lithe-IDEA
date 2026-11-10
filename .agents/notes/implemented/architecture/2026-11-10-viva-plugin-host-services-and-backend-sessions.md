# Agent 笔记：Viva 插件后端按需激活、宿主服务注册与 backend 解析的 LSP 启动

状态：已实现

## 先说结论

Viva 客户端现在由 `pluginservice.BackendHost` 为每个插件保持至多一个后端会话，按需启动、有界停止，并在生产装配里注册宿主服务处理器。语言服务器的启动可以由插件后端回答（`serverProcess` 3），插件后端可以通过 `languageServer/*` 宿主方法驱动自己的服务器（`languageServers` 3）。Core 仍然负责协议、规则和执行；Go 只做进程、I/O 和调用方身份。

## 问题

生产装配只创建了空的宿主服务注册表，没有任何处理器；后端只被语言服务器和构建 Provider 启动，没有按需激活的独立会话；启动校验不接受由后端解析的命令行。结果是依赖 `backend` 2、`serverProcess` 3、`languageServers` 3 的插件（例如 Java Support）无法通过安装审查，也无法运行。

## 决策

- **激活**：后端在三种情况下启动：项目打开时清单声明了 `onWorkspaceOpen`（窗口显示后在后台逐个启动，失败不阻塞项目）；语言服务器需要启动答案；Core 发出 `functionProviderStartRequired`。项目关闭、插件停用或卸载时，会话先从 `BackendHost` 摘除（`Detach`），再有界停止，保证后台停止不会杀掉下一个项目启动的后端。
- **宿主服务注册**：`Services.Register` 注册方法，`GrantService` 注册服务级授权名（`workspace`、`functions`）。启动请求只授予计划列表与已注册项的交集，`getCapabilities` 因此只列真正有处理器的方法。后续 run、debug、terminal、editor、documents、credentials 在 `registerHostServices` 里按同样方式追加一行。处理器通过 `pluginhost.CallerFrom(ctx)` 取得调用方插件，不需要第二套按插件分隔的注册表。
- **并发应答**：`Runner.Serve` 对每个宿主请求开独立 goroutine（Core 已限制每会话 16 个未决请求），并响应 `hostRequestCancelled`。原因：`languageServer/request` 可能等待服务器很久，而后端自己的函数调用完成事件走同一个事件循环，串行应答会让它们互相阻塞。`languageServer/request` 用 `RegisterUserChoice` 注册，避免被 30 秒机器请求期限截断，期限由请求的 `timeoutMilliseconds` 与 Core 控制。
- **backend 解析的启动**：Core 规划第一步（`launch.kind: "backend"`）→ 宿主调用后端 `launch.function`（带 `resolveParams` 与工作区 context）→ Core `decodeLaunch` 校验 → 宿主按普通计划启动，计划里的 `sessionPolicy` 原样传给 `lsp.startServer`。
- **可写位置与只读边界**：状态目录 `<插件根>/.state/<id>/<版本>`、工作区状态 `<插件根>/.state/<id>/servers/<语言>/workspaces/<摘要>`、日志 `<插件根>/.state/<id>/logs`、上下文状态 `<插件根>/.state/<id>/backend/workspaces/<摘要>`，均在插件存储（Application Support 一类的用户目录）下，不在 app bundle、安装包目录或 `resource_dir()` 下，不影响代码签名和 Sparkle 增量；单次启动的临时目录在系统临时目录，服务器进程结束时删除。`host-secret` 保存在 `.state` 下，用于生成按插件隔离的 rootID。
- **上下文**：`WorkspaceContexts` 每个打开的项目一个 context，项目关闭即失效，重新打开得到新 ID；`listContexts` 不创建目录，只有 `getContext` 创建并返回状态目录。变化时发送 `didChangeContexts` 并向 Core 重新配置跨插件调用快照。
- **语言服务器会话**：`LanguageSession` 记录 context 与每次启动递增的 generation；`ServeLanguageSession` 在窗口观察者之前处理 `requestCompleted`（唤醒转发请求）、`stateChanged`（映射为 `didChangeState`）和 `pluginServerNotification`（转为 `didReceiveNotification`）。服务器停止时仍在等待的请求以 `languageServerUnavailable` 结束。

## 考虑过的备选方案

- 在 `Handler` 签名里加调用方参数：改动所有处理器；用 context 携带身份同样隐含在 Core 的会话归属里，改动更小。
- 在 Go 里重做跨插件调用的链路检查：违背 Core 算规则的原则；宿主只给快照、启动被调用的后端。
- 项目关闭时只停止语言服务器、不停后端：契约要求项目关闭有界停止，后端又可能持有已失效的 context。

## 后果

插件后端现在有了生产路径，但宿主服务只覆盖上下文、订阅释放、语言服务器与跨插件调用；其余服务仍会被 Core 以 `plugin.host.unavailable` 拒绝，插件需要先读 `getCapabilities`。

## 已知缺口

- `{kind: "tool"}` 启动答复（`serverProcess` 4 的工具引用）暂未接入工具链解析，会被明确拒绝；Java Support 默认答复打包的运行时，不受影响。
- `Declared()` 仍缺 Java Support 要求的 `debugAdapters` 3、`outputLinkMatchers` 1、`projectGenerators` 1、`settings` 2，属其他车道。
- 远程工作区、语言服务器状态保留清理（`stateRetention`）、`subscriptions` 创建方、run/debug/terminal/editor/documents/credentials 处理器尚未实现。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/pluginservice/... ./internal/pluginbackend/... ./internal/pluginhost/... -race -count=1`。
- 设置 `LITHE_JAVA_PLUGIN_MANIFEST` 指向 Java Support 的 `plugin.json` 时，`TestJavaSupportManifestOnlyLacksOtherLanesCapabilities` 用 Core 验证清单仅缺上述其他车道的能力。

- 设置 `LITHE_JAVA_PLUGIN_PACKAGE` 指向用插件仓库的 build-package 脚本（arm64）构建出的包目录时，`TestJavaSupportStartsJDTLSAndPublishesDiagnostics` 在 macOS 上安装包副本、启动后端、解析启动、启动 JDT LS 并收到含类型错误文件的诊断（约 15 秒，需要先下载 JDT LS 与 JDK）。

## 适用范围

- `desktop/internal/pluginservice/`（backendhost、contexts、hostmethods、backendlaunch、languagesession、activation）
- `desktop/internal/pluginbackend/pluginbackend.go`
- `desktop/internal/pluginhost/`
- `desktop/internal/workbench/pluginbackends.go`
