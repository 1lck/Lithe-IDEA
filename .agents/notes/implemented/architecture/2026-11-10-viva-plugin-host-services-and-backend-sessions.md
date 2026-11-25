# Agent 笔记：Viva 插件后端按需激活、宿主服务注册与 backend 解析的 LSP 启动

状态：已实现

## 先说结论

Viva 客户端现在由 `pluginservice.BackendHost` 为每个插件保持至多一个后端会话，按需启动、有界停止，并在生产装配里注册宿主服务处理器。语言服务器的启动可以由插件后端回答（`serverProcess` 3），插件后端可以通过 `languageServer/*` 宿主方法驱动自己的服务器（`languageServers` 3）。Core 仍然负责协议、规则和执行；Go 只做进程、I/O 和调用方身份。

## 问题

生产装配只创建了空的宿主服务注册表，没有任何处理器；后端只被语言服务器和构建 Provider 启动，没有按需激活的独立会话；启动校验不接受由后端解析的命令行。结果是依赖 `backend` 2、`serverProcess` 3、`languageServers` 3 的插件（例如 Java Support）无法通过安装审查，也无法运行。

## 决策

- **激活**：后端在三种情况下启动：项目打开时清单声明了 `onWorkspaceOpen`（窗口显示后在后台逐个启动，失败不阻塞项目）；语言服务器需要启动答案；Core 发出 `functionProviderStartRequired`。项目关闭、插件停用或卸载时，会话先从 `BackendHost` 摘除（`Detach`），再有界停止，保证后台停止不会杀掉下一个项目启动的后端。停用和卸载走 `pluginservice.Service.Disable` / `Service.Uninstall`：卸载先停语言服务器和后端，再删包和状态目录（2026-11-13 前停用、卸载并不停后端，见[确认安装即启用与卸载清理](../bug-fix/2026-11-13-viva-plugin-install-enables-and-uninstall-cleans-state.md)）。
- **宿主服务注册**：`Services.Register` 注册方法，`GrantService` 注册服务级授权名（`workspace`、`functions`）。启动请求只授予计划列表与已注册项的交集，`getCapabilities` 因此只列真正有处理器的方法。后续 run、debug、terminal、editor、documents、credentials 在 `registerHostServices` 里按同样方式追加一行。处理器通过 `pluginhost.CallerFrom(ctx)` 取得调用方插件，不需要第二套按插件分隔的注册表。
- **并发应答**：`Runner.Serve` 对每个宿主请求开独立 goroutine（Core 已限制每会话 16 个未决请求），并响应 `hostRequestCancelled`。原因：`languageServer/request` 可能等待服务器很久，而后端自己的函数调用完成事件走同一个事件循环，串行应答会让它们互相阻塞。`languageServer/request` 用 `RegisterUserChoice` 注册，避免被 30 秒机器请求期限截断，期限由请求的 `timeoutMilliseconds` 与 Core 控制。
- **backend 解析的启动**：Core 规划第一步（`launch.kind: "backend"`）→ 宿主调用后端 `launch.function`（带 `resolveParams` 与工作区 context）→ Core `decodeLaunch` 校验 → 宿主按普通计划启动，计划里的 `sessionPolicy` 原样传给 `lsp.startServer`。
- **可写位置与只读边界**：状态目录 `<插件根>/.state/<id>/<版本>`、工作区状态 `<插件根>/.state/<id>/servers/<语言>/workspaces/<摘要>`、日志 `<插件根>/.state/<id>/logs`、上下文状态 `<插件根>/.state/<id>/backend/workspaces/<摘要>`，均在插件存储（Application Support 一类的用户目录）下，卸载插件时整个 `.state/<id>` 随之删除（`pluginpkg.RemoveState`），不在 app bundle、安装包目录或 `resource_dir()` 下，不影响代码签名和 Sparkle 增量；单次启动的临时目录在系统临时目录，服务器进程结束时删除。`host-secret` 保存在 `.state` 下，用于生成按插件隔离的 rootID。
- **上下文**：`WorkspaceContexts` 每个打开的项目一个 context，项目关闭即失效，重新打开得到新 ID；`listContexts` 不创建目录，只有 `getContext` 创建并返回状态目录。变化时发送 `didChangeContexts` 并向 Core 重新配置跨插件调用快照。
- **语言服务器会话**：`LanguageSession` 记录 context 与每次启动递增的 generation；`ServeLanguageSession` 在窗口观察者之前处理 `requestCompleted`（唤醒转发请求）、`stateChanged`（映射为 `didChangeState`）和 `pluginServerNotification`（转为 `didReceiveNotification`）。服务器停止时仍在等待的请求以 `languageServerUnavailable` 结束。

### 2026-11-21：构建选项与配置文件观察

`build/getOptions` 仅用调用会话的已验证清单读取它声明的构建系统。桌面复用已有团队和本机偏好读取，Core 负责实例层级、默认值和校验。读取过程中不重新检测工程或启动构建。两项能力按独立权限协商，旧宿主仍可通过能力查询识别支持范围。

`build/watchConfiguration` 以工作区 context 和后端会话为所有者，只通知变更，不传路径或文件内容。原子保存从父目录发现，目录尚未出现时从最近的现存祖先跟踪创建；绑定完成后重新核对目标。观察使用现有工作区和用户设置目录，注册本身只占用内存和系统文件观察句柄，不生成文件或修改安装包、代码签名和 Sparkle 差分基线。关闭工作区、停用后端或主动取消时释放观察。宿主回归覆盖目录创建、原子替换、删除和 workspace 关闭。

### 2026-11-13：编辑器注册与首次调试的时序

插件注册编辑器动作或语言功能时，`context` 是宿主定位工作区的路由信息，不属于交给 Core 的动作/Provider 声明。宿主先检查调用方与工作区，再移除这层路由信息；不得放宽 Core 对未知字段的检查。回归必须经过真实 Core 解码，只有假宿主通过会漏掉这个问题。

动作注册和撤回后，窗口重新收集当前打开文档的动作；语言服务器就绪时同样刷新。窗口只排队刷新，不在注册请求里同步调用插件，否则注册应答和动作收集可能互相等待。正确做法是注册完成后发窗口事件；不要要求用户编辑一下文件才出现 Run/Debug 标记。

插件通过 `run/start` 发起调试时，适配器目录由宿主按需读取，完成后再进入既有启动或附加流程，并检查原请求是否已取消。不要要求用户先打开 Debug 工具窗口来触发目录加载。这些都是宿主的通用接线；JDT（Java 语言服务器）、Java 编译、classpath（运行时类路径）和 JDWP（Java 调试连接协议）的知识仍留在 Java 插件。

Run 自己启动的进程还必须随附加的调试会话释放。单独发送 DAP disconnect 只断开连接，上游可能把仍暂停的进程留下；因此原生 Run 适配器向调试会话传入有界停止回调，在后台关闭调试连接后回收所拥有的进程。手动附加到用户外部进程时没有该回调，不改变外部进程所有权。这个内部生命周期接线不增加插件 API，也不由插件猜测或杀死宿主进程。

真实 ZIP 集成测试覆盖含第三方依赖的 Maven 编译、补全、运行、断点变量、继续退出、再次调试后停止及编译错误拒绝旧 class；同时核对 Core 操作日志与包哈希不变。这是 macOS arm64 无头工作台的证据，原生窗口与其他平台仍需分别验收。

旧项目的实际运行时与源码级别必须分别验证。JDK 8 可以为 Java 5/7 源码生成旧 class，当前 ECJ（Eclipse 的 Java 编译器）却只接受 Java 8 及以上，运行前 JDT 构建因此失败。`TestJavaPluginLegacySourceBoundaries`（该测试已随插件归属规则从宿主删除，同类验证归插件仓库，见 [插件的测试、功能矩阵和翻译只在插件仓库](2026-11-14-plugin-owned-tests-matrix-i18n.md)）验证的是安全拒绝，不能当成 Java 5/7 Run/Debug 验收。不得恢复“编译失败也运行旧产物”，也不得由宿主改写用户 POM 升级源码级别；历史项目的临时 POM 改动只能发生在测试副本，并单独报告。

多工作区关闭还暴露既有 `pluginbackend.Runner.Stop` 通过销毁失败循环等待终态的问题：进程最终退出，但正常关闭产生 Core WARN。它属于本次之前已有的共享状态职责债务，独立记录为 [#1860](https://github.com/1lck/Lithe-IDEA/issues/1860)，不混入 Java 接入修复。

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

- `scripts/desktop/desktop-go.sh test ./internal/pluginservice -run 'TestEditorActionRegistrationRefreshesOpenDocuments|TestEditorProviderRegistrationBindsEveryRoutedFunction' -count=1`：经过真实 Core 校验动作和 Provider 注册，并验证动作注册/撤回会刷新窗口。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestRunAttachLoadsAdaptersWithoutOpeningDebugPanel|TestRunLaunchTargetBindsTheRunsProcessIntoTheLaunch' -count=1`：不打开调试面板也能加载目录；适配器启动与参数绑定保持原有流程。

- `scripts/desktop/desktop-go.sh test ./internal/pluginservice/... ./internal/pluginbackend/... ./internal/pluginhost/... -race -count=1`。
- ~~设置 `LITHE_JAVA_PLUGIN_MANIFEST` 指向 Java Support 的 `plugin.json` 时，`TestJavaSupportManifestOnlyLacksOtherLanesCapabilities` 用 Core 验证清单仅缺上述其他车道的能力。~~（该测试已随插件归属规则从宿主删除，同类验证归插件仓库，见 [插件的测试、功能矩阵和翻译只在插件仓库](2026-11-14-plugin-owned-tests-matrix-i18n.md)）

- 设置 `LITHE_JAVA_PLUGIN_PACKAGE` 指向用插件仓库的 build-package 脚本（arm64）构建出的包目录时，`TestJavaSupportStartsJDTLSAndPublishesDiagnostics` 在 macOS 上安装包副本、启动后端、解析启动、启动 JDT LS 并收到含类型错误文件的诊断（约 15 秒，需要先下载 JDT LS 与 JDK）。

## 第二批宿主服务：凭据、文档与编辑器、窗口消息、浏览器、终端、内容提供者

决策与做法（Core 仍然只负责规则与校验，Go 只做 I/O 与窗口交互）：

- **窗口相关方法只在窗口接入时注册**。`Service.AttachWorkbench(Workbench)` 注册 documents、editor、window、browser 方法；窗口同时实现 `TerminalHost`、`VirtualDocumentHost` 时才注册 terminal 与内容提供者。没有窗口的会话（测试、无头）不会被授予没人能回答的方法，`getCapabilities` 因此保持真实。`Workbench` 的每个方法由 `pluginWorkbench` 通过 `onWindow` 交给窗口线程执行，调用方 context 结束即返回；已开始的编辑不回滚，与契约一致。
- **凭据**（`internal/credentials`）：service 为 `app.lithe.viva.plugin-credentials.<插件ID>`，账户是插件的 key，所以按插件隔离；契约里 `credentials/*` 不带 context，凭据不按工作区分，需要按项目区分的插件把项目放进 key。macOS 用 Security framework（cgo，`SecItemAdd/Update/CopyMatching/Delete`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），不用 `security` 命令行，避免密钥出现在 argv；Windows 与 Linux 用 `github.com/zalando/go-keyring`（MIT，Windows 走 Credential Manager，Linux 走 Secret Service/D-Bus，依赖 godbus BSD-2、wincred MIT）。不写日志、不落文件；错误只带状态码。Windows 凭据单项上限 2560 字节，超出返回 `limitExceeded`，和契约的 16 KiB 上限有差距。
- **旧凭据只在用户要求时导入**：Viva 是与旧 Lithe 并行安装的新产品，旧 Lithe 会一直使用到迁移完成，所以 Viva 平时**完全不碰**旧客户端的钥匙串项。`credentials/get` 只读 Viva 自己的位置，`credentials/delete` 只删 Viva 自己的项。
  - 入口：用户在设置齿轮菜单里选“从旧版 Lithe 导入插件凭据”，并在说明对话框里确认后，`Store.ImportLegacy` 才执行一次导入。
  - 列出：先用只取属性的查询（`kSecReturnAttributes` 加 `kSecUseAuthenticationUIFail`，不读密钥、不弹窗），列出旧 macOS 位置 `app.lithe.desktop.plugin-credentials.<插件ID>` 和 `.dev` 下的项。同一插件、同一 key 以稳定版为准。只有列出失败才算导入失败。
  - 读取：逐项读取，这一步允许系统弹出“允许访问”提示。用户拒绝或读取出错的项计为失败，不中断其余项。
  - 写入：Viva 已有值的项保留、不覆盖；等待提示期间插件新写入的值同样保留。旧项一律不改不删，否则旧客户端会丢失数据库密码等凭据。
  - 结果只报告导入、保留、失败的数量，日志只带状态码。旧 Windows 客户端没有存过插件凭据（它的 backend 从未对外宣告），所以 Windows 和 Linux 不显示这个菜单项。
  - 不要这样做：在 `get` 找不到时自动读旧位置。早先的版本这样做过，有两个问题：一是静默复制，用户不知道 Viva 拿到了旧密钥；二是为了防止已删除的值经迁移复活，`delete` 只好连旧项一起删，结果删掉了旧客户端仍在用的凭据。
- **编辑**：`editorview.View.ApplyEdits` 把一批互不重叠的编辑合成一次 rope 差异，只产生一步撤销和一次语言服务器同步事件；位置按 UTF-16 解析，越界、落在代理对中间、重叠都拒绝（`OffsetOf`，与 LSP 风格的 `ByteOffset` 钳制不同，过期范围不能被悄悄挪动）。版本号是 view 的修订号，`getSnapshot`、`getSelections` 和所有编辑使用同一个；只读、输入法组字、版本不符分别返回 `readOnly`、`busy`、`versionConflict`（带 `currentVersion`）。编辑器只有单选区，`getSelections` 返回一个选区；`editor/open|reveal` 只把范围起点放成光标。资源路径要求相对、`/` 分隔、无 `.`/`..`，并对最长已存在前缀解析符号链接后确认仍在根内。
- **窗口消息**：用现有 `sheet` 模态面板按到达顺序一次显示一个，限频 10 秒 5 条、每插件 3 条等待，其余返回 `rateLimited`（带 `retryAfterMilliseconds`）与 `busy`。面板用 Frame 引擎绘制，与旁边的插件审查面板一致，因为窗口主体还没迁到 Viva Page；迁移时与审查面板一起换。
- **浏览器与预览**：`browser/openExternal` 接受 http/https URL（无内嵌凭据）或已保存的 HTML 资源。资源默认要求没有未保存修改，只有显式选择 `openSavedFile` 才打开磁盘旧内容，宿主不自动保存。`preview/openMarkdown|openHTML` 注册后复用工作台预览，支持资源与只读内联文本；HTML 需要原生 WebView，不可用时在创建标签前拒绝。Core 先检查资源类型和默认模式，窗口不重复校验。
- **终端**：用户同意（精确程序、argv、目录）后在 Terminal 工具窗口启动，与用户终端共用标签条、拖拽和分组。`termview.Config` 增加 `Args/Env/Unset/Prefill/Exited`，带 `Exited` 的视图不再靠 Enter 重启，由插件通过 `reopen` 决定；`localshell.Config.Unset` 支持移除变量（Unix 与 Windows 后端）；插件终端创建时立即启动，不等第一次绘制，因为 `show:false` 的终端不会被绘制。`close`、自然退出和关闭项目走同一条收尾路径，先取纯文本快照（`AppendRetainedText`，按预算在字符边界截断）再释放视图；自然退出后标签自动移除，退出事件只发一次。每个插件最多 8 个句柄，按会话和上下文归属，上下文关闭、会话结束、插件停用时关闭并忘记。`LITHE_` 前缀的环境变量不允许覆盖。
- **内容提供者**：绑定记录在 `contentProviders`（上下文加 scheme），不回调后端；`documents/registerContentProvider` 要求函数已在该会话注册，保留 scheme 与重复注册按契约拒绝。导航结果的 `FilePath` 为空且 URI 的 scheme 有提供者时，定义列表保留该目标，选中后向插件请求内容（30 秒），经 Core 的 `plugins.contentProviders.decode` 校验后以只读标签打开。虚拟文档的 `path` 就是 URI，不监视文件、不保存、不与语言服务器同步，关闭后宿主不留副本。
- **订阅与资源释放**：`hostResources` 统一登记订阅、内容提供者、终端句柄，归属 `(插件, 会话, 上下文)`；`subscriptions/dispose` 只释放调用方自己的 ID；会话结束与上下文关闭自动释放。
- **命令**：`Service.NotifyCommandRun` 从命令面板、已有快捷键目录及状态项运行纯后端命令，不再要求命令绑定工具窗口。运行中的后端直接收；已停止的只有清单声明 `onCommand:<id>` 才被启动。状态项只能引用本插件清单中的命令，归属由 Core 检查。

本节记录宿主接线边界，不作为所有领域的完成清单；编辑器注册、运行和调试的现状分别由对应实现与功能矩阵维护。凭据在插件卸载时的跨平台清理不属于本次工作流 API 增量。

### API-06：先由 Core 提供磁盘读取，再接窗口

`workspace/readDirectory|stat|readFile` 的共享规则和执行命令由 Rust Core 提供，桌面只把经过授权的工作区根与相对路径交给 Core，并把返回路径封装为插件自己的资源标识。这样分页、字节预算、隐藏规则和错误分类在所有客户端保持一致。具体参数和限制只在 Core 插件契约中维护。

文件读取不复用打开文档的内容：例如编辑器里已把 `alpha` 改成未保存的 `ALPHA`，`readFile` 仍返回磁盘上的 `alpha`。逐段拒绝符号链接以及 Windows 的文件系统重解析点（reparse point，可把路径转到另一位置）；Unix 使用相对目录句柄，Windows 持有禁止写入和删除共享的祖先目录句柄，防止校验后路径被换成链接。代价是 Windows 读取期间无法重命名这些目录，遇到冲突的共享方式会拒绝读取，不降低保护后重试。

正确做法是宿主请求所在的后台任务调用 Core，窗口线程只确认本地项目仍然有效。不要先在 Go 里解析真实路径再读取：路径可能在两步之间被替换，也会复制一份 Core 的规则。请求取消或项目关闭会取消读取，发布前再次核对同一个项目和工作区上下文，避免关闭后重开同一路径接收旧结果。这里只读取文件，不产生缓存或写入安装目录，因此不会改变代码签名或 Sparkle 增量更新基线。

三个方法仅在窗口实现 `WorkspaceReadHost` 后注册。没有远程读取适配器时拒绝远程工作区，不读取本机占位目录。监听与搜索也按各自的可选宿主接口注册，遵循相同的上下文检查。

验证使用 `scripts/desktop/desktop-go.sh test ./internal/pluginservice ./internal/workbench -run 'TestWorkspaceReads|TestPluginWorkspaceReads' -count=1`。默认构建固定到 Core main `c6cef0b`，包含 [Core #190](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/190)、[#193](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/193)、[#194](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/194) 与 #187 增量更新；无需本地覆盖路径。测试读取真实临时文件，覆盖资源隔离、磁盘与未保存文档的区别及项目关闭取消；不依赖任何具体插件。Windows 的原生目录句柄行为须在 Windows 单独验证，本机 macOS 测试不能替代。

### API-07/08：Core 处理搜索与监听语义，Viva 只提供原生事件

文件名搜索与文本搜索复用 Core 已有的匹配器、编码识别、隐藏规则和工作区索引排除策略。插件磁盘入口要求逐段拒绝链接，现有搜索索引读取链路不能保证这一点，因此这里复用匹配和策略，以同一套 no-follow 句柄做有界遍历，不调用会在校验后重新按路径打开文件的索引读取。搜索不为每个插件保留整棵树或内容索引，只保留一页与一个额外候选；代价是每页重新遍历，查询可能在大工程上超时，当前不宣称具备索引查询的延迟。以后改用索引候选时，也必须保留句柄读取和当前范围限制。

正确做法是先由 Core 验证监听目标，再让 Viva 建立原生文件事件流，并在注册后核对根与目标身份。原生流覆盖工作区根，使目标的父目录被替换也能触发重扫；Core 决定哪些名字属于订阅、哪些隐藏、哪些情况丢失细节需要重扫。不要在 Go 中复制路径匹配、排序、隐藏规则，也不要使用空闲轮询。注册完成后先发一次重扫，事件丢失、根消失或替换时要求重新读取；根消失或替换后释放旧流，不把旧流用于新根。

监听在 `hostResources` 中归属插件、会话与上下文，复用原生注册限额。取消在途通知后再关闭原生句柄，通知与释放串行，因此 `dispose` 返回后不会继续发送；请求返回不结束长期订阅，关闭工作区、退出会话或停用插件才结束。旧订阅不能转移给同路径的新上下文。监听只保留有界名字批次，无文件内容缓存和磁盘写入，不影响发行包、代码签名或 Sparkle 更新基线。

验证读取 Core 的共享 fixture 和真实临时文件，macOS 使用 Viva 的原生文件事件覆盖递归创建、原子保存、删除、初始重扫、三种释放入口及根目录替换后的最终重扫与释放，并用可控通知验证释放会取消在途发送。`scripts/desktop/desktop-go.sh test ./internal/core ./internal/pluginservice ./internal/workbench -run 'TestWorkspace(Reads|Find|Search|Watch)|TestPluginWorkspace' -count=1` 与定向竞态检查覆盖桥接、资源封装、未保存缓冲区隔离和关闭取消；监听测试没有用定时睡眠同步。Windows 原生运行按本次任务范围不验收，不能据 macOS 结果标为 Windows 已验证。

### 通用工作流：先完成 Core 计划，再接原生呈现

输入、预览、对比、输出、进度、状态、剪贴板、文件管理器和 HTTP 共用 `plugins.workflow` 的严格计划。Core 拥有参数、默认值、权限、过滤排序、分页停止条件、输出增量和预算；Go 只连接原生 I/O、控件与会话生命周期。不要在窗口重新写过滤、扩展名检查或分页规则，这会使另一平台产生不同结果。

例如，同一插件会话与工作区内重复打开相同内联预览 ID，应更新原标签；另一个会话使用同 ID 则获得独立的只读标签。内联 Diff 使用与工作区文件无关的身份，不能因标题恰好等于真实文件名而获得保存能力。预览和输出不写磁盘缓存，不改变发行包、代码签名或 Sparkle 增量更新基线。

长期输出、进度和状态归属插件、会话与上下文。关闭上下文时先取消正在执行的原生调用，再排队移除窗口资源；不要在窗口关闭过程中同步等待窗口队列，否则可能死锁。HTTP 连接仅首次请求时创建并复用，没有 Cookie jar，也不自动跟随重定向。请求结束释放应答，工作区关闭后清理空闲连接；错误只保留安全分类，不把 URL、查询参数、头或正文交给日志。

视图刷新绑定当前显示的实例和会话。关闭先使旧回调失效，再停止观察，避免同路径重开视图接收旧刷新。树只保留已加载范围，用稳定 ID 保持选择和展开；Core 判断视口何时请求下一页，游标或范围不前进就停止。代价是桌面需维护原生控件的呈现状态，但不再维护一份共享规则。

未选择让插件用网页复制输入面板、输出台或状态栏：这会重复原生控件和权限生命周期。也未把 Cookie、身份验证或下载文件塞进通用 HTTP；这些需要各自的凭据和资源所有权契约。

验证：`scripts/desktop/desktop-go.sh test ./internal/workbench ./internal/pluginservice ./internal/pluginview -run 'Test(Workflow|BrowserOpensOnlyHTTP|SessionRefresh|WorkbenchDefaultLayout)' -count=1 -timeout=45s`；同范围逐测试计时与竞态检查。`TestVisualPluginWorkflow` 采集深浅主题、中英文的真实预览、输出、任务菜单、只读对比和快速选择截图，CI 上传 artifact。macOS 定向测试不替代原生 WebView、系统剪贴板、外部浏览器或 Windows 整机验收；整体矩阵保持 partial/pending。

## 适用范围

- `desktop/internal/pluginservice/`（backendhost、contexts、hostmethods、backendlaunch、languagesession、activation）
- `desktop/internal/pluginbackend/pluginbackend.go`
- `desktop/internal/pluginhost/`
- `desktop/internal/workbench/pluginbackends.go`
- `desktop/internal/credentials/`
- `desktop/internal/pluginservice/`（hostdocuments、hostsurface、hostterminal、hostcontent、hostcommands、hostresources、hostcredentials）
- `desktop/internal/workbench/`（pluginworkbench、pluginprompt、pluginterminals、plugincontent）
- `desktop/internal/core/workspace_read.go`、`desktop/internal/core/workspace_find_watch.go`、`desktop/internal/pluginservice/hostworkspaceread.go`、`desktop/internal/pluginservice/hostworkspacefind.go`、`desktop/internal/pluginservice/hostworkspacewatch.go`、`desktop/internal/workbench/pluginworkspaceread.go`
- `desktop/internal/editorview/hostedit.go`、`desktop/internal/termview/`、`desktop/internal/localshell/`
- `desktop/internal/core/plugin_workflow.go`、`desktop/internal/pluginservice/hostworkflow.go`、`desktop/internal/pluginservice/hostviewrefresh.go`、`desktop/internal/workbench/plugin_workflow.go`、`desktop/internal/pluginview/`
