# Agent 笔记：远程工作区按根目录路由

状态：已实现

## 先说结论

远程文件夹以“本地占位根目录”的身份打开成工作区：根目录是 `Application Support/Lithe/RemoteWorkspaces/` 下的一个空目录，工作台照常拿到一个文件 URL；这个根目录下面的文件在远端。文件树与编辑器通过文件端口访问主机，Git、搜索和构建保留现有 Core 引擎、替换底层读写，终端把远端伪终端（PTY，负责交互进程与窗口尺寸）的字节交给本机渲染。JDK、Maven 和 Shell 的发现读取对应主机环境；通用插件部署与 stdio 已接入，远程 Java/SVN、Agent 执行位置选择与完整 SSH 工作流仍待完成和验收。

## 问题

工作台的所有功能都以“工作区根目录是一个本地文件 URL”为前提：窗口、会话恢复、项目设置、文件树、编辑器都按 URL 识别。如果为远程项目换一种 URL（例如自定义 scheme），几乎每个功能都要改；而一次性把所有功能都接到远端，改动面太大，也无法分步验证。

## 决策

- **远程实现只保留一个 crate**：`rust/lithe-remote/` 内部分为 `client`、`protocol`、`server` 三个模块，共用一个版本和依赖入口。协议类型始终可用，Cargo feature（构建时选择哪些代码和依赖）默认只启用 `client`；Core 的正常依赖明确只选客户端，Linux/macOS 的真实服务测试额外启用 `server`。打包必须用 `--no-default-features --features server --bin lithe-remote-server`，不能让工作区其他包的 feature 合并把客户端带入远端发布物。可执行文件仍叫 `lithe-remote-server`，安装路径、握手和协议版本不变；协议单独构建不需要 SHA-256 或主机适配依赖，客户端不引入 `trash` 或服务端平台代码。
- **占位根目录**：`MacRemoteWorkspaceRoots` 在 `Application Support/Lithe/RemoteWorkspaces/<连接 id>/<远程路径哈希>/<文件夹名>` 创建一个空目录，用它作为工作区根。目录名是远程文件夹名，所以项目名显示正确。它不在 app bundle 里，不影响签名和 Sparkle 增量包；里面没有用户数据，跨启动保留，让按根目录保存的项目状态得以延续。
- **注册表**：`RemoteWorkspaceRegistry` 记录每个占位根对应的连接、远程路径和 Core 会话 id。打开远程项目时登记，同一个根再次打开时，旧会话会被替换并断开。
- **路由**：组合根（`MacServiceContainer`，负责组装依赖的地方）把本地实现包进 `RemoteRoutingWorkspaceOperations` 和 `RemoteRoutingFileOperations`。路由层对端口里的**每个**方法都显式转发：如果只覆盖一部分，没覆盖的方法会悄悄走协议扩展里的默认实现，本地文件的行为就变了。
- **文档版本**：和本地一样，文档标识是读到的原始字节的 SHA-256。远端用大小和修改时间做冲突检测，所以路由层为每个读到的标识记住远端版本（最多 512 个），保存时把它作为 `expected` 传给 `remote.writeFile`；不认识的标识会先读当前内容比对哈希。文件变了就返回冲突，不覆盖。
- **文件树变更**：新文件只创建，不覆盖已存在文件；重命名、目录复制和删除都使用同一会话的主机文件协议，跨本机与远端或不同会话的移动和复制明确失败。复制先在目标父目录的私有暂存目录完成，再原子发布且拒绝覆盖，避免并发创建目标时丢失内容。界面的“移到废纸篓”复用 `trash` 上游库，在 Linux 使用 Freedesktop Trash、在远程 Mac 使用系统 Trash；不可用时失败，不改成永久删除。需要按内容标识保护的 `trashDocument` 仍待单独适配，不能假装普通 Trash 操作具有原子身份保护。
- **外部修改监听**：`RemoteDirectoryObservation` 在工作线程订阅主机原生 watcher，转换路径后交给已有文件树、Git、搜索索引和文档刷新流程。Git common directory 位于工作区外时使用同一绑定的外部路径命名空间并额外监听，订阅时还原主机路径，事件回来后投影回同一个本地身份。订阅先于创建，启动和溢出要求重新扫描，根目录移除结束订阅；取消先屏蔽旧 generation，再通过 Core 的资源所有者停止主机 watcher。打开的文档共用其工作区根的订阅，列表缓存随文档变更清空。
- **最近项目**：占位根目录不进“最近项目”，因为它离开连接就只是个空目录；重新打开要走“远程开发”窗口。
- **Core 请求的主机身份**：桥接层只读取请求结构里明确的工作区根字段，附上注册表中的会话与两侧根目录；同一次 Git 操作涉及不同主机或本机与远端混合时拒绝执行。Core 在请求范围内持有这份身份，长期历史游标继续持有原连接，不依赖“当前选中主机”的全局变量。远端出错时返回失败，不访问本机占位目录或本机 Git。
- **工作区外的主机路径仍带身份**：打开远端 `/srv/repo/src` 后，Git 发现的父仓库 `/srv/repo` 不能作为普通本地绝对路径返回，否则下一次状态或暂存会误操作本机。Core 把这类路径放进占位根的虚拟同级目录 `<根目录名>.lithe-remote-host/<主机绝对路径去掉开头斜杠>`；注册表识别为原绑定，后续请求仍传原来的会话和两侧根，Core 再还原真实路径。符号链接解析到工作区外也走同一规则。同级而非子目录避免和用户文件名冲突，不使用 `..` 越出根，也不凭原始 `/srv/repo` 猜测主机。这个命名空间不创建文件、不增加缓存或资源目录；只有原空占位根跨启动保留，绑定注销后两种身份一起移除。
- **Git 与搜索继续复用现有引擎**：Git 参数、状态解析、提交、历史和搜索索引仍由原 Core 模块负责。文件与进程适配器只把请求送到项目所在主机；Git 可执行文件与版本按连接缓存，设置来源由同一主机 Git 返回。创建或管理 worktree、克隆时，仅映射类型化请求中明确的目标目录字段；原始 Git 参数、仓库地址和用户文本保持原样。搜索缓存增加连接身份，避免同一个占位 URL 曾经生成的本机空索引污染远端结果。远端服务不引入 Core、JDK、LSP 或 Agent Host；Linux musl 二进制各保持 1.5 MiB 上限与 panic unwind（线程出错时保留其他会话）。
- **远端文件读写限制**：Core 一次装入内存的文件最多 32 MiB，分块读取还会核对版本、偏移与结束标记；流式快照哈希可读取更大的文件。原子写入沿用协议的 8 MiB 上限，超限在编码和发送前失败，不拆成会暴露半份内容的覆盖操作。文件或目录是否存在的查询必须保留权限、断线等失败，不能把它们当成“不存在”。临时目录清理失败记录错误类别，避免静默残留或把用户路径写入日志。
- **终端确认与清理**：交互终端默认使用远端账户的 Shell，显式菜单选择保留独立 argv；调试进程按工作区身份选择主机，即使调试器给出的工作目录已经是远端绝对路径。启动在收到远端确认后才发布就绪与 PID，等待中的启动也算模块活动资源。重启先等待上次传输清理，输入按顺序发送，待发送尺寸只保留最新值；写入与缩放复用 Core 的操作取消，退出释放远程渲染标记，不把远端 PID 交给本机进程监控。
- **运行时与 Shell 发现**：网络调用在平台工作线程运行，界面读取缓存；发现有数量、数据和时间限制，取消或切换工作区后丢弃旧结果，失败不发布部分结果或本机回退。Shell 从远端登录环境、`/etc/shells` 和文件权限发现，旧服务缺目标权限时再查询链接真实路径；本机终端设置里的可执行文件路径不作为远程默认值。
- **资源生命周期**：Git 临时索引和源文件快照在远端临时目录或 Git common directory，由单次操作清理；探测、可执行文件与搜索缓存保存在客户端内存并按连接隔离。服务的 socket、锁和日志身份同时包含会话键与二进制 SHA-256，版本号相同但内容变化时不复用旧常驻进程。以上资源在 `scripts/resources/worktree-resources.json` 中明确排除跨工作树复制，运行时不写安装资源，不改变签名和 Sparkle delta 基线。
- **构建与插件运行**：构建扫描、工具探测、构建进程和报告读取使用原工作区的主机身份，stdout/stderr 分别增量解码。插件只部署经过原安装来源复核的包，异平台变体必须同版本、同声明且不增加批准程序；复用市场校验和下载器，不向小型服务引入包管理或语言引擎。目标文件通过带 SHA-256 的分块上传原子发布，普通文件只读、可执行文件只读可执行，可写状态位于远端用户目录。快照清理捕获原连接，在 Core 销毁进程后执行。
- **完整运行目录由远端会话保管**：客户端先生成运行目录身份，再请求 `fs.createRunDirectory`，即使分配回复丢失也能用原身份释放。服务端只在远端用户的私有 `~/.lithe-server/plugin-runs/` 下新建目录，不接管已经存在的路径；释放仅按当前会话持有的身份查找，不接受任意删除路径，重复释放无害；删除失败保留登记供重试，即使释放正在等待创建者清理，也会收到真实错误而不是成功。已有父目录必须为当前用户所有、非符号链接且不向其他用户开放，不通过改权限接管共享目录。分配和释放沿用读取线程预登记与创建者清理规则。非驻留断线、会话关闭和空闲到期在结束进程、排空工作线程后回收完整目录，客户端崩溃不再依赖客户端补发删除。常驻会话仅断线时保留资源，供重连继续使用。远端服务被强制杀死后的回收尚未实现：尤其 macOS 可能留有进程，不能只用目录年龄或服务锁消失就删除运行输入。旧版客户端创建的未登记快照也不自动扫描删除。
- **上传不互相拖住**：上传表只登记和移除身份，不把文件打开、写入、同步、发布或删除放在全局锁里。每个文件独立同步，同一上传的并发操作返回 `BUSY`；断线、取消和到期先标记取消，由仍在执行的工作线程保管并最终删除暂存文件。一个慢文件不能阻止另一个文件完成，释放动作也不能等慢文件的锁。
- **stdio 与启动**：语言、构建和 VCS 提供者复用 Core 的协议引擎，远程通道保留有界输入输出与原连接。异步部署、工具探测和启动在工作线程进行，启动期间保留有界文档快照与文件变更，停止后到达的会话先销毁再删除包。仅映射协议定义的 URI 和 VCS 路径字段，参数、文本与插件自定义值保持原样。依赖本机原生集成的 Java 仍明确拒绝，不能伪装成通用 stdio 已支持。
- **启动中取消不能依赖空资源表**：服务端的连接读取线程先登记进程、终端和监听的启动身份，再交给工作线程。后续关闭先记录在这个身份上，由创建者在发布资源后执行清理；即使关闭请求因工作线程已满返回 `BUSY`、客户端停止等待或断线，清理责任也不消失。关闭等待最多 60 秒，但到期不会撤销已经记录的清理；不同资源仍可并行，注册表锁不覆盖磁盘、启动或结束进程树。无效参数不能触发取消，后到的普通结束请求不能降低已请求的强制结束。这样修复的是所有通用后端的生命周期，不需要引入 Java/JDT 等语言专属语义。
- **常驻服务启动只允许一个代理创建进程**：daemon 的存活锁只能防止同时服务，不能阻止竞争失败的启动进程在旧会话关闭后接管锁。代理在启动前先取得同一身份的 `.start` 文件锁，再检查 socket，已有服务就复用；锁覆盖创建进程至 socket 可连接，等待使用原有启动期限。`.start` 位于远端用户私有状态目录的 `run/`，进程关闭文件即释放锁，文件本身保留，避免删除后不同代理锁住不同 inode；它属于远端会话协调状态，不可跨工作树复用，不写安装包，不影响代码签名或 Sparkle delta。验证启动锁互斥、期限、释放及并发连接收到关闭确认后服务确实退出，不用延长测试超时掩盖残留进程。
- **断线与会话结束不同**：常驻会话仅断线时保留终端和进程供重连；非驻留连接断开、显式关闭会话或空闲到期时，迟到发布的资源必须由创建者清理。结束标记在清理现有资源表之前设置，否则慢启动可能在清理后才出现，尤其是常驻会话不能再把它当成“等待重连”的合法资源。

### 正确做法

新增一种需要读写工作区文件的能力时，通过这两个端口访问文件，远程工作区就会自动可用。
例如搜索使用已有索引语义，通过主机文件适配器读取内容；终端接收 `started` 确认后再把远端 PID 返回给调试器。新增功能仍需逐个检查调用链，文件端口本身不能让本机进程自动变成远端进程。

### 不要这样做

- 不要在功能代码里用 `FileManager` 直接读工作区下的文件：在远程工作区里它只会看到空目录。
- 不要从占位根目录推导“这是远程项目”再写特殊分支，应该询问 `RemoteWorkspaceRegistry`。
- 不要把本机签名插件包内的 macOS 可执行文件路径直接传给 Linux；包的目标平台、资源部署和可写状态目录尚未适配时，必须保留失败状态，不宣称插件可用。

## 考虑过的备选方案

### 保留三个 crate，或合并后默认编译全部模块

三者总是随同一份协议一起维护，没有独立发布需求，保留三个包只会增加依赖入口和路径维护。全部默认编译又会把只适用于 Linux/macOS 的服务端带进 Windows 客户端。采用单包加可选 feature，减少顶层模块而保留平台和依赖边界；代价是验证必须覆盖纯协议、纯客户端、纯服务端和两端一起启用四种组合，并继续检查远端二进制大小。

### 为远程文件使用自定义 URL scheme

语义最清楚，但工作台里几乎所有地方都假定是文件 URL，第一步就要改全部功能。

### 把远程目录同步到本地再打开

现有功能全都能直接用，但大项目同步慢、两边会不一致，构建和运行也会发生在本地而不是项目所在的机器上，和整体远程开发设计（构建、LSP 都在远端运行）相冲突。

### 丢弃工作区外的仓库，或把父路径拼成 `../`

丢弃父仓库可以避免错误路由，但打开仓库子目录时 Git 会完全不可用，符号链接根也有同样问题。`../` 会被 URL 标准化消掉，不再位于已登记的占位根下。采用可逆的同级虚拟命名空间，让完整的“发现仓库 → 查询状态 → 暂存”保留主机身份，而不扩大原占位根对应的主机目录。

### 客户端取消时只重试关闭，或等待启动确认后才允许取消

只重试关闭仍可能在资源登记前用尽客户端的两秒清理期限；无限等待启动确认又会拖住关闭窗口和模块停用。也不能把慢启动改成连接读取线程上的同步工作，那会阻塞其他会话。采用服务端先记住取消、创建者随后清理的方式，让客户端保持有界等待，同时不丢失最终清理责任。

## 后果

- 远程工作区第一版：文件树按需列目录、打开和保存 UTF-8 文件（含 BOM）、保存时检测冲突。
- 新增适配覆盖：远端 PTY、按主机探测环境、Git 文件与进程 I/O、搜索索引与 Shift+Shift 的文件及内容查询。真实服务 fixture 已覆盖状态、暂存、分页历史、设置来源、worktree 创建和管理、克隆、保留无关暂存的选择文件提交，以及未保存缓冲区的行历史；不能据此把完整真实 SSH 产品流程标为已验收。
- 父仓库与符号链接根的服务 fixture 经过发现、状态、暂存三次独立请求，并在返回的虚拟 URL 放置本机 Git 哨兵，核对本机索引和文件未变；Swift 路由 fixture 检查原绑定恢复、同路径不同主机隔离及混合根拒绝。外部 Git 元数据 watcher 的事件也采用相同投影；这些仍不替代真实 SSH 验收。
- 文件树新建、复制、重命名、移到主机废纸篓和普通删除已接入；外部修改监听覆盖文件树与文档，真实 SSH 的原生 watcher 仍需产品验收。
- 构建 I/O、工具与状态目录适配，以及通用插件部署和 stdio 提供者接入已有实现与 fixture；真实 SSH 的完整构建、插件启动与取消链路仍待验收。
- 仍待完成：远程 Java 原生集成、SVN 的兼容目标包与完整 VCS 流程、Agent 执行位置选择、远端服务强制终止后的快照回收，以及 stdio 断线、顺序、背压与取消的真实主机覆盖。Java 和 Agent 不在本轮通用能力续作范围；不能把桌面客户端崩溃后的会话到期清理当成远端服务崩溃回收。不关闭 #1507。
- 连接在工作区关闭后仍保留，直到 App 退出。
- 代价：主机调用增加往返时间，远端无有效工具或连接中断时必须明确失败；缓存与长期资源都需要保留原连接身份，不能复用本机路径命中的结果。
- 当前限制：Git 原子写入仍保留 8 MiB 上限；新分块上传仅用于已批准插件文件，不代表 Git 大文件临时内容已经接入。

## 验证

```bash
./scripts/macos/test/test-macos.sh --filter RemoteConnections
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'RemoteWorkspaceRoutingTests|RemoteDirectoryObservationTests'
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'RemoteRuntimeDiscoveryTests|RemoteShellDiscoveryTests|RemoteTerminalTransportTests|TerminalModuleTests'
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'RemotePluginDeploymentTests|RemotePluginLaunchPreparerTests|RemoteBuildExecutionTests|MacBuildProviderSessionsTests|MacVcsProviderSessionsTests'
./scripts/remote/verify-remote-workspace.sh
node scripts/resources/test-reuse-worktree-resources.mjs
./scripts/macos/verify/verify-runtime-bundle-immutability.sh
./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh
./scripts/architecture/verify-service-boundaries.sh
```

## 适用范围

- `rust/lithe-remote/`
- `scripts/remote/build-remote-servers.sh`
- `scripts/remote/verify-remote-workspace.sh`
- `macos/Sources/Lithe/Services/Remote/RemoteWorkspaceRouting.swift`
- `macos/Sources/Lithe/Platform/MacOS/Remote/MacRemoteWorkspaceRoots.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+RemoteConnections.swift`
- `macos/Sources/Lithe/Platform/MacOS/Remote/MacRemoteTerminalTransport.swift`
- `macos/Sources/Lithe/Platform/MacOS/Remote/MacRemoteRuntimeLocator.swift`
- `macos/Sources/Lithe/Platform/MacOS/Remote/MacRemoteShellDiscovery.swift`
- `rust/lithe-core/src/remote/workspace.rs`
- `rust/lithe-core/src/remote/workspace_host.rs`
- `rust/lithe-core/src/remote/workspace_io.rs`
