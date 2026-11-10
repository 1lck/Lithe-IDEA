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
- 远程工作区、语言服务器状态保留清理（`stateRetention`）、run/debug 处理器尚未实现；其余宿主服务见“第二批宿主服务”。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/pluginservice/... ./internal/pluginbackend/... ./internal/pluginhost/... -race -count=1`。
- 设置 `LITHE_JAVA_PLUGIN_MANIFEST` 指向 Java Support 的 `plugin.json` 时，`TestJavaSupportManifestOnlyLacksOtherLanesCapabilities` 用 Core 验证清单仅缺上述其他车道的能力。

- 设置 `LITHE_JAVA_PLUGIN_PACKAGE` 指向用插件仓库的 build-package 脚本（arm64）构建出的包目录时，`TestJavaSupportStartsJDTLSAndPublishesDiagnostics` 在 macOS 上安装包副本、启动后端、解析启动、启动 JDT LS 并收到含类型错误文件的诊断（约 15 秒，需要先下载 JDT LS 与 JDK）。

## 第二批宿主服务：凭据、文档与编辑器、窗口消息、浏览器、终端、内容提供者

决策与做法（Core 仍然只负责规则与校验，Go 只做 I/O 与窗口交互）：

- **窗口相关方法只在窗口接入时注册**。`Service.AttachWorkbench(Workbench)` 注册 documents、editor、window、browser 方法；窗口同时实现 `TerminalHost`、`VirtualDocumentHost` 时才注册 terminal 与内容提供者。没有窗口的会话（测试、无头）不会被授予没人能回答的方法，`getCapabilities` 因此保持真实。`Workbench` 的每个方法由 `pluginWorkbench` 通过 `onWindow` 交给窗口线程执行，调用方 context 结束即返回；已开始的编辑不回滚，与契约一致。
- **凭据**（`internal/credentials`）：service 为 `app.lithe.viva.plugin-credentials.<插件ID>`，账户是插件的 key，所以按插件隔离；契约里 `credentials/*` 不带 context，凭据不按工作区分，需要按项目区分的插件把项目放进 key。macOS 用 Security framework（cgo，`SecItemAdd/Update/CopyMatching/Delete`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），不用 `security` 命令行，避免密钥出现在 argv；Windows 与 Linux 用 `github.com/zalando/go-keyring`（MIT，Windows 走 Credential Manager，Linux 走 Secret Service/D-Bus，依赖 godbus BSD-2、wincred MIT）。不写日志、不落文件；错误只带状态码。Windows 凭据单项上限 2560 字节，超出返回 `limitExceeded`，和契约的 16 KiB 上限有差距。
- **旧凭据迁移**：新位置没有、旧 macOS 位置（`app.lithe.desktop.plugin-credentials.<插件ID>`，再试 `.dev`）有时，用不弹窗的只读查询（`kSecUseAuthenticationUIFail`）读旧值、复制到新位置并返回；读取失败一律当作没有，绝不弹钥匙串密码框。迁移成功后**保留旧项**：Viva 与旧客户端并行安装，删掉会让旧客户端丢失数据库密码。为避免已删除的值经迁移复活，`credentials/delete` 同时删除新旧两处。旧 Windows 客户端没有存过插件凭据（它的 backend 从未对外宣告），所以没有 Windows 旧位置。旧的 Keychain 项如果由不同签名的应用创建，读取可能被访问控制拒绝，此时同样视为没有。
- **编辑**：`editorview.View.ApplyEdits` 把一批互不重叠的编辑合成一次 rope 差异，只产生一步撤销和一次语言服务器同步事件；位置按 UTF-16 解析，越界、落在代理对中间、重叠都拒绝（`OffsetOf`，与 LSP 风格的 `ByteOffset` 钳制不同，过期范围不能被悄悄挪动）。版本号是 view 的修订号，`getSnapshot`、`getSelections` 和所有编辑使用同一个；只读、输入法组字、版本不符分别返回 `readOnly`、`busy`、`versionConflict`（带 `currentVersion`）。编辑器只有单选区，`getSelections` 返回一个选区；`editor/open|reveal` 只把范围起点放成光标。资源路径要求相对、`/` 分隔、无 `.`/`..`，并对最长已存在前缀解析符号链接后确认仍在根内。
- **窗口消息**：用现有 `sheet` 模态面板按到达顺序一次显示一个，限频 10 秒 5 条、每插件 3 条等待，其余返回 `rateLimited`（带 `retryAfterMilliseconds`）与 `busy`。面板用 Frame 引擎绘制，与旁边的插件审查面板一致，因为窗口主体还没迁到 Viva Page；迁移时与审查面板一起换。
- **浏览器**：`browser/openExternal` 只接受 http/https URL（无内嵌凭据），经 Viva 的 `app.OpenURL` 打开；`resource` 形式返回 `unsupportedOption`。**`preview/openHTML` 不注册**：Viva 有系统 Web 视图（`docs/web-views.md`），但编辑器区还没有能承载网页的标签与“编辑器加预览”布局，在无头环境里也无法验证原生视图。
- **终端**：用户同意（精确程序、argv、目录）后在 Terminal 工具窗口启动，与用户终端共用标签条、拖拽和分组。`termview.Config` 增加 `Args/Env/Unset/Prefill/Exited`，带 `Exited` 的视图不再靠 Enter 重启，由插件通过 `reopen` 决定；`localshell.Config.Unset` 支持移除变量（Unix 与 Windows 后端）；插件终端创建时立即启动，不等第一次绘制，因为 `show:false` 的终端不会被绘制。`close`、自然退出和关闭项目走同一条收尾路径，先取纯文本快照（`AppendRetainedText`，按预算在字符边界截断）再释放视图；自然退出后标签自动移除，退出事件只发一次。每个插件最多 8 个句柄，按会话和上下文归属，上下文关闭、会话结束、插件停用时关闭并忘记。`LITHE_` 前缀的环境变量不允许覆盖。
- **内容提供者**：绑定记录在 `contentProviders`（上下文加 scheme），不回调后端；`documents/registerContentProvider` 要求函数已在该会话注册，保留 scheme 与重复注册按契约拒绝。导航结果的 `FilePath` 为空且 URI 的 scheme 有提供者时，定义列表保留该目标，选中后向插件请求内容（30 秒），经 Core 的 `plugins.contentProviders.decode` 校验后以只读标签打开。虚拟文档的 `path` 就是 URI，不监视文件、不保存、不与语言服务器同步，关闭后宿主不留副本。
- **订阅与资源释放**：`hostResources` 统一登记订阅、内容提供者、终端句柄，归属 `(插件, 会话, 上下文)`；`subscriptions/dispose` 只释放调用方自己的 ID；会话结束与上下文关闭自动释放。
- **命令**：`commands/didRun` 的发送端 `Service.NotifyCommandRun` 已实现（运行中的后端直接收；已停止的只有清单声明 `onCommand:<id>` 才被启动），但 Viva 目前没有命令面板、编辑器右键菜单或插件命令贡献入口，没有调用方。

未接通（会被 Core 以 `plugin.host.unavailable` 拒绝）：`editor/registerActions`、`editor/registerProviders`（没有编辑器行首图标、命令入口与右键菜单，注册了用户也触发不了，所以不声明）、`preview/openHTML`、`workspace/readDirectory|stat|readFile|watch|findFiles|findText`、`run/*`、`debug/*`（后两者属其他车道）。凭据在插件卸载时的清理也未做：除 macOS 外平台存储不能按 service 枚举，需要后续由插件管理器记录已用的 key。

## 适用范围

- `desktop/internal/pluginservice/`（backendhost、contexts、hostmethods、backendlaunch、languagesession、activation）
- `desktop/internal/pluginbackend/pluginbackend.go`
- `desktop/internal/pluginhost/`
- `desktop/internal/workbench/pluginbackends.go`
- `desktop/internal/credentials/`
- `desktop/internal/pluginservice/`（hostdocuments、hostsurface、hostterminal、hostcontent、hostcommands、hostresources、hostcredentials）
- `desktop/internal/workbench/`（pluginworkbench、pluginprompt、pluginterminals、plugincontent）
- `desktop/internal/editorview/hostedit.go`、`desktop/internal/termview/`、`desktop/internal/localshell/`
