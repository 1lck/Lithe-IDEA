# Agent 笔记：Windows 声明式插件宿主

状态：已实现

## 先说结论

Windows 新增一套契约 v1 声明式插件宿主，与现有 Worker 扩展模型长期并行：需要宿主代用户拉起进程的语言与构建插件走契约宿主，宿主内运行 UI 与服务行为的扩展（主题、AI provider 等）留在 Worker 模型。契约引擎不需要新写——`lithe-core` 已经编译进 Windows 宿主，经 `core_execute` 就能调用 `plugins.declarative.*` 与 `plugins.marketplace.*`。M1 已落地：包存储、启动扫描与隔离、语言服务器启动计划解析，以及共享 fixtures 的全量验收；M2 已补磁盘导入安装链、设置内独立管理页和 runtime 启动的 `minimumVersion` 探测；M3 已补声明式设置、运行/测试计划命令与契约版 PHP bundled 包；M4 已补 Web 工具窗口（`lithe-plugin://` scheme、CSP、`window.lithe` 桥 v0）。能力声明开放 `languages:1`、`languageServers:[1,2]`、`serverProcess:1`、`settings:[1,2]`、`ui:[1,2]`，其余能力（`executionProviders`、`buildProviders`、`buildSystems`）仍由 Core 自动拒绝。

## 问题

- 功能矩阵 `declarative-plugin-contract`、`plugin-functions` 对 Windows 记为 missing（2026-10-22 矩阵对齐时确认）；[声明式语言插件](2026-10-12-declarative-language-plugins.md) 也写明"Windows 现有扩展清单暂未改造，接入时必须通过同一组 fixture"。
- Windows 当前插件生态是渲染进程内的 Worker 扩展：`Plugins/win/Official/PhpSupport` 是 Worker 包格式（`main: "plugin.js"`），与契约包不同，无法复用 Lithe Store 面向 macOS/契约发布的语言插件包。
- Windows 没有插件信任链与仓库源管理；`install_extension_from_url` 前端已调用但 Rust 宿主从未注册，非语言扩展的落盘安装链路实际不可用。
- 契约的确定性逻辑（清单校验、启动计划展开、安装审查）按仓库规则只在 `rust/lithe-core/src/plugins/` 实现一次，而 `windows/tauri/src-tauri` 已依赖 `lithe-core`——差的只是宿主侧接线，不是契约本身。

## 决策

### 双模型边界

判定句：扩展需要"宿主代表用户拉起进程"（语言服务器、构建系统、运行/测试提供方）就走契约宿主；扩展需要"在宿主内运行自己的代码来表达 UI 或服务行为"（颜色主题、图标主题、AI provider、数据库 sidecar、ACP agent）就留在 Worker 模型。

- 正确做法：新增 Go 语言支持时写契约 `plugin.json` 声明 `languageServers` 和 `executionProviders`，由 Core 展开启动与运行计划。
- 不要这样做：把主题扩展改写成契约包；为 Worker 扩展桥接一套函数通道冒充 litheFunctions；在宿主里按插件 ID 写 `if` 分支。

### 能力声明渐进开放

宿主在 `plugins.declarative.validate` 的 payload 里声明 `hostCapabilities = { languages:[1], languageServers:[1,2], serverProcess:[1], settings:[1,2], ui:[1,2] }`。Core 的 `capabilities.rs` 会拒绝声明了宿主未开放能力的插件，宿主不需要自己写拒绝逻辑。M3 已把 `languageServers` 与 `settings` 提到 2，注册设置页并下推 `workspaceConfiguration`；M4 已增 `ui:[1,2]`。`executionProviders`、`buildProviders` 与 `buildSystems` 仍未开放，运行/测试计划命令的存在不代表这些插件能力可安装。宿主不声明的能力，市场侧按不支持展示。

### 存储、信任与安装（v0）

- 安装根为 `app_local_data_dir()/plugins/<pluginID>/<version>/`，`installation.json` 记录版本与启用状态；记录缺失或损坏的包隔离展示，绝不静默加载。
- bundled 包从 `resource_dir()/OfficialPlugins` 只读加载，多版本目录取最高版本；运行时不写安装目录与资源目录，遵守发行基线只读边界。
- 每个插件的语言服务器状态目录在 `app_local_data_dir()/plugin-state/<pluginID>/<workspace 哈希>`，由宿主注入启动计划请求。
- 信任模型 v1（Windows 插件对齐路线图 M1，见 `docs/development/windows-plugin-parity-plan.md`）：发布者 Ed25519 验签已接入 `plugin_host/signature.rs`，与 macOS `PluginPackageSignature` 字节兼容（canonical payload、UTF-8 base64url token、按原始路径排序、每文件 SHA-256 与 contentDigest），采用成熟的 `ed25519-dalek`，固定官方公钥 `lithe-official-plugins-v2`；生产私钥不进入仓库。官方 ID 的信任策略由宿主固定（`php/java-support=sameTeamAsHost`、`go-support=publisherPackage`），覆盖包自声明；`sameTeamAsHost` 只信任宿主安装资源内的 bundled 包，磁盘/市场包不能凭目录名获得该身份。签名文档存在即必须验证，坏签名不会被忽略。磁盘导入与市场下载（M2+）仍走 `plugins.marketplace.installReview` 全量审批（权限 + 完整程序清单），审批界面明示"未认证发布者"。
- 安装记录 schema 2 是安装事务的一部分：`origin`、marketplace/disk provenance（全包内容摘要与批准程序的 canonical JSON）、上一版本的 provenance 都随版本发布一起写入；安装确认、staging 发布前、启动扫描、运行/测试计划入口与回滚都会重新校验完整文件集合和摘要。schema 1 旧记录没有 provenance，扫描直接隔离（`plugin.trust.provenanceMissing`）并要求重新安装，绝不凭 `enabled` 或清单摘要补造发布者身份和已批准字节。
- 磁盘导入的私有快照、staging 重验、内容摘要复查与回滚语义照抄 macOS 侧规则（见声明式语言插件 Note 的磁盘安装节），Windows 不另造审查语义。

### 启动接线（M1 落地形状）

- `plugin_host` 模块（`store.rs` 存储布局、`scan.rs` 扫描与校验、`launch.rs` 启动计划解析）是宿主侧唯一入口；校验与计划展开全部经 `lithe_core::execute_json` 调 Core 命令，宿主不复制任何清单语义。
- `packaged` 启动入口解析后必须是包内普通文件：拒绝 reparse point（符号链接与 junction）与规范化后的路径逃逸，这是宿主执行每个启动前的统一闸门。
- `runtime` 与 `systemCommand` 启动经 PATH 探测（复用 `language_tools` 的系统工具查找），并按 macOS 同一约定导出 `LITHE_<TOOL>_PATH`、把 packaged runtime 目录前置到 `PATH`；`minimumVersion` 探测随 M2 安装链一起接入。
- 语言服务器进程仍由共享 Core 的 `lsp.startServer` 拉起：前端 `resolve-editor-lsp-launch.ts` 在 Worker 扩展清单没有对应服务器时，回落到 `declarative_plugins_language_launch`（契约插件排在 Worker 之后，已由 Worker 声明的语言保持现状，直到 M3 包迁移）。
- 启动扫描在应用 bootstrap 的 "declarative plugins" 步骤执行一次；扫描结果缓存在 Tauri state，前端经 `declarative_plugins_state` 只读消费。

### 网页与版本探测的运行边界

Tauri 把插件自定义协议页面视为远端来源，空 capability 会在进入 Rust handler 前拒绝所有 IPC。宿主采用 Tauri 官方 inlined plugin（应用内命令插件）扩展点：`declarative-web` 命名空间只声明一个 `request` 权限，仅匹配 `plugin-web-*` 窗口和 `http://lithe-plugin.*/*` 来源；不授予 fs/http/event 等命令，也不启用会改变全部主窗口命令的 app ACL。编译后的 Tauri authority 回归验证这条边界，不能用只检查 handler 的测试代替。

插件网页的窗口标签只用于定位所属包，不能单独证明当前文档可信。`web.rs` 使用 Tauri 的导航、新窗口和下载拦截器，只允许本包来源；每次桥接请求还读取 WebView 当前 URL，再核对插件来源、启用状态和窗口声明。宿主脚本也只在本包主框架定义桥，窗口使用非持久浏览会话，避免外站文档继承桥或页面存储。例如本包的 `ui/next.html` 可以导航，`https://example.com`、另一个插件的来源、带用户信息或端口的地址会被拒绝；不要用 CSP 或窗口标签代替导航与请求来源检查。

WebView2 的 NavigationStarting 可以阻止外站文档提交，但实测外站服务器仍可能先收到 GET。因此 `web_network.rs` 使用微软的 WebResourceRequested 接口，在请求层把非本包、非 Tauri IPC 的网络请求完成为本地 403。窗口先创建为惰性空白页，五秒期限内安装过滤器成功后才导航到包页面；失败时销毁空白窗口，不能留下可运行但未受保护的页面。Wry 只在初次创建时转换自定义协议，延迟 navigate 必须显式使用同一 http://lithe-plugin.<插件 ID>/ 映射地址，否则页面会停在空白文档；这个地址构造和来源检查共用同一回归。注册跟随 WebView 的生命周期，不在页面每次加载时叠加。复用 Wry 已依赖的 webview2-com 0.38.2 API，独立声明同一固定版本，没有新增另一套浏览器或网络后端。

`workspace.openFile` 必须先经原生文件系统解析真实目标，再检查它仍在同样经过解析的工作区根内。前端把这个目标交给既有文件打开入口，保留行列位置，并在等待解析后复查工作区有没有切换。工作区内指向内部文件的链接可以打开，指向外部目录的 junction（Windows 的目录联接）不能借路径文本绕过检查。不能仅比较 `C:/work/link/file.txt` 的文本前缀。

网页的语言、浅色或深色状态、颜色和字体变量从已解析的 Windows 工作台主题取得。主窗口创建页面时传入初值，主题注册表与设置的订阅把后续变化送到原生页面；根元素的 `data-theme`、`--lithe-*` 变量和只读 `lithe.context` 随之更新，再发 `ui.themeChanged`。每个 HTML 响应会在插件脚本前加载一个保留路径下的宿主同源外部脚本，由原生协议 handler 按可信窗口标签读取最新快照；因此页面重载、同包导航和带 UTF-8 BOM 的页面在运行插件代码前也能取得当前主题，HTML parser 已创建根元素。宿主脚本插在真实 head 起始标签后；省略 head 时退到 html 后，两者都省略时放在文档声明之后。扫描仅处理 HTML 前导区，跳过注释并识别带引号的属性，保留原有根样式、head 属性、BOM 和文档模式。这种响应字节插入不改包文件，也不给 CSP 增加内联脚本例外。订阅随 bootstrap 清理，不在插件内复制另一套主题值。

版本探测复用 `lithe_git_host::run` 的原生进程执行器。虽然它位于 Git adapter crate，其进程树、非阻塞管道与清理能力不解释 Git 参数；探测只设置五秒取消期限和每条输出流 64 KiB 上限，解析仍交 Core。Windows 在进程运行第一条指令之前把它放入 Job Object（内核管理的进程组），因此父进程退出后仍占用 stdout 的后代也会被清理。不要只给 `try_wait` 加超时后无期限 `join` 读取线程，也不要靠退出后遍历父 PID 找后代。代价是异常进程退出后最多还需执行器自身的有界清理时间。

### 禁用、替换和卸载必须先收回使用权

插件包正在执行时直接删目录，会在 Windows 上遇到可执行文件被占用，并可能只删掉一部分文件。因此所有启停、安装替换、回滚和卸载先经过 `lifecycle.rs`：禁止新的原生启动计划和网页读取，等待已经开始的版本探测、校验进程、网页创建和资源读取退出，再关闭所有所属页面，并要求每个产品窗口确认其运行与 Core LSP 会话都已停止。原生使用计数和禁止新请求共用锁，避免刚检查完就漏进新的操作；等待原生使用者和窗口确认各有 45 秒上限。失败时保留包文件并继续禁止使用，用户重试管理操作后才能恢复。

前端在调用第一个异步操作前登记启动归属。停止操作必须覆盖已启动和正在等待 Core 响应的会话；晚到的会话先停止、再拒绝返回。停止失败的会话仍留在登记表中，后续管理操作必须继续等它，不能误报没有进程。包目录与扫描目录只有在变更和重新扫描都成功后才恢复使用。完整扫描从发现到提交缓存共用一把锁，避免不同插件并发管理时，旧扫描覆盖新目录。

正确做法：先收回新请求、等待所有使用者退出，再修改包；不要发一个不等待结果的停止事件就删除文件。每个窗口只能确认自己的操作，窗口消失算失败，不能假定它的 Core 子进程已经退出。探测与读取沿用既有 `plugin-state` 和包读取路径，没有新增可跨工作树复用的资源；校验命令在平台可写的插件状态目录执行，发行资源保持只读。

### 插件身份、工作区和声明式界面

`pluginId` 是 Core 校验配置更新的插件身份，`providerId` 是语言服务实例的来源，两者必须分别传递和保存。设置的即时生效请求必须带插件 ID，并只发送到仍有效且属于该插件的会话；Java 和 Worker 启动继续使用自己的来源。

每个网页由创建它的产品窗口、工作区和插件共同持有，窗口标签使用无碰撞的编码。状态按这组归属隔离，关闭工作区或禁用插件时清理；工作区关闭会提升该工作区页面的版本，关闭前已发起但尚未注册的页面也不能复活。状态写入与文件打开的登记和撤销共用所有者锁，旧页面实例不能在重新打开后继续写状态；网页不能通过参数自行指定所属工作区。`workspace.openFile` 只发给所属窗口，并等待带操作 ID 的确认。目标窗口在真实路径解析前后都复核当前工作区，复核目标缓冲区确实存在且处于活动状态后才确认成功；共享文件打开函数在读取失败或请求过期时也可能正常返回，不能仅凭其 Promise 完成判断成功；工作区切换、窗口关闭和十秒确认超时都返回失败。待确认请求最多 128 个，避免插件无限积累请求。

启动前检查 Core 的 `requiredPackagePaths`、`runtimeRequirements` 和 `validationArguments`。包资源允许普通目录，但实际可执行入口必须是普通文件；路径逃逸和 reparse point 都拒绝。依赖与发现型启动运行时优先使用用户显式导出，再查系统 PATH；包内 `packagedRuntime` 则严格执行已审批的那个文件，不接受用户覆盖，满足最低版本才继续；校验命令即使输出文本，只要退出码非零仍失败。探测复用现有五秒、每条输出流 64 KiB 的原生执行器和进程树清理能力。

`ui:1` 的文本工具窗口由宿主生成转义后的 HTML，`ui.commands` 接入已有的命令、菜单和工具栏展示注册表，工具窗口也有活动栏入口。复用展示注册表不等于进入 Worker 执行模型。禁用时同步撤销入口，异步刷新按插件检查版本，避免撤销 B 时取消 A 的刷新，防止旧结果恢复入口。目前页面仍是独立 WebView 窗口；声明的停靠位置、图标、动作可用/勾选状态和布局持久化尚未与 macOS 对齐，因此矩阵继续记为 partial，不能称为完整的 ui 1/2 产品形态。

### 与 Worker 扩展模型共存（产品分工）

- 两套模型互不桥接：契约插件不进 Worker 宿主，Worker 扩展不冒充契约能力。
- PhpSupport 迁移（M3 调整）：契约版 PHP 包（`Plugins/win/Official/PhpSupportContract`，`sameTeamAsHost` bundled）随安装器分发并完成 validate/launch/runPlan 端到端测试，但 Worker 版**保留不移除**。原因：Worker 版提供 composer scripts 的动态运行动作发现（读取工作区 composer.json 生成动作列表），契约 v1 的 `executionProviders` 是静态声明，没有等价能力；删除 Worker 版会丢失用户可见功能。完整迁移等契约补齐动态运行动作后再做。两包并存时 Worker 版优先（Worker 扩展清单先解析），契约包不重复注册语言。
- `install_extension_from_url` 等 Worker 非语言市场命令（M2 已处置）：在 Rust 宿主注册为显式占位错误（`extensionStore.notAvailable`），调用方得到可诊断的结构化失败而不是"命令不存在"；完整落盘后端是独立工作项，不与契约宿主混淆。
- 管理界面按模型分组展示两类扩展并使用不同文案，避免用户把 Worker 扩展当成契约插件。

### 实施切分

M1 包存储 + 启动校验 + 语言注册 + LSP 启动（已落地）；M2 磁盘安装链路 + 管理界面 v1 + 死链处置（已落地）；M3 声明式设置 + 运行/测试计划 + PHP 契约包（已落地，Worker 版保留见上文）；M4 Web 工具窗口（已落地，桥 v0 只含 state/openFile/主题，build.* 与 functions.* 等 Windows 构建系统能力接入后开放）。路线图 M1（发布者签名 + 全包完整性 + 安装记录事务，`signature.rs` 与 schema 2 安装记录）已落地；本 Note 早期的 M1–M4 编号是宿主 PR 的内部切分，与路线图的 M0–M10 不是同一序列。每个里程碑独立 PR，矩阵条目随代码同 PR 更新。总体方向遵循[公共扩展契约与 Provider 接入方向](../../proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)，本 Note 只落地其中 Windows 契约宿主的第一阶段。

## 考虑过的备选方案

- 把 Worker 扩展模型整体改造成契约宿主：契约没有主题、AI provider 这些概念，改造成本高且无收益，不采用。
- 在 Tauri 侧另写一套清单校验：违反"校验只在 Core 实现一次"，共享 fixtures 无法复用，双端语义必然漂移，不采用。
- 把 Worker RPC 桥接成 litheFunctions：两者协议语义不同，会同时存在两套函数协议，等有真实插件需求时再按[插件函数契约](2026-10-20-plugin-function-contract.md)接入。
- 信任模型一步到位 publisher 签名：v0 曾以 bundled 加全量审批兜底，签名延后是当时显式记录的缺口；路线图 M1 已选择与 macOS 相同的包内 Ed25519 文档签名（而非 Authenticode），因为它跨平台字节兼容、验证在安装事务内完成，且不依赖系统证书存储。
- 在 `lsp_start` 一类原生命令里拉起插件服务器：现有 LSP 会话全部由 Core 统一管理（会话、取消、事件泵都在 Core），前端只解析可执行路径与参数；另建原生拉起路径会分裂会话所有权，不采用。

## 后果

- 收益：Windows 用户开始能安装与运行契约 v1 语言插件，语言插件包与 macOS/Lithe Store 同格式；契约验收（同组 fixtures）成为 Windows 持续回归的一部分；后续里程碑只增不改这条链路。
- 代价：双模型并存是用户可见的复杂度，管理界面必须分组。`minimumVersion`、内容摘要复查与启动前校验已接入；发行者签名仍延后，不能把完整性检查当作发布者身份验证。
- 已知风险：签名延后意味着 v0 社区包信任完全依赖审批界面（M2），文案必须明示未认证状态；Windows 的 reparse point/junction 语义与 macOS symlink 不完全相同，包内路径逃逸判断已按 Windows 语义单独测试；WebView2 对自定义 scheme 与 CSP 的实现细节与 WKWebView 有差异，`ui:2` 网页链路已用 Windows Release/WebView2 实机验证，停靠、图标、动作状态及布局仍为 partial。
- M2–M4 里程碑：磁盘/市场安装链路 + 管理界面；声明式设置 + 运行/测试计划 + PHP 契约包替换；Web 工具窗口。每个里程碑独立 PR，能力声明与矩阵条目随代码同 PR 更新。

## 验证

- 多窗口事件投递必须显式指定当前产品窗口的 `Window` target。Tauri 默认 `Any` 监听也接收发给其他 label 的事件，原生 `emit_to(ownerLabel)` 本身不足以隔离接收者；文件请求与生命周期确认均绑定当前窗口，防止其他工作区误处理请求或重复确认。`plugin-lifecycle-listener.test.ts` 检查两类监听的目标。
- 2026-10-24 Windows Release 实机验收：Playwright/CDP 连接真实 WebView2，测试包安装、ui 1 文本渲染、工作区关闭重开、状态隔离、两个产品窗口归属、主题/语言与重载、过期工作区 openFile 拒绝、双窗口卸载关闭全部插件页均通过；无重复确认异常，外站 HTTP GET 为零，安装包及发行资源哈希不变，应用正常退出。该测试包不替代真实语言服务器的完整安装→启动→即时设置验收，也不覆盖停靠布局。
- 管理并发回归：`lifecycle.rs` 覆盖原生使用计数排空、禁止晚到获取、逐窗口确认、停止失败、窗口断开和有界超时；`lsp-core-adapter.test.ts` 用可控 Core 响应覆盖停止期间晚到的服务器，断言先停止再拒绝，且 `pluginId` 没有丢失。`plugin-lifecycle-listener.test.ts` 验证收到停用事件立即撤销入口、等待运行和 LSP 两方后才确认。
- 工作区与界面回归：`web.rs` 覆盖双工作区窗口/状态键隔离和文本转义；`plugin-lifecycle-listener.test.ts` 验证其他工作区请求、路径解析中切换工作区以及成功确认；`workspace-lifecycle.test.ts` 验证关闭工作区时清理网页。`declarative-plugin-ui.test.ts` 用 Hello Lithe fixture 验证文本窗口与命令面板、菜单、工具栏三处贡献及撤销，受控刷新同时覆盖相关与无关插件的撤销。CI 按文件分进程执行插件套件，避免原生命令和事件 mock 跨套件泄漏。
- 启动计划回归：`launch.rs` 验证必需资源缺失、运行时依赖缺失、目录资源与普通文件入口的区别，以及有输出但非零退出的校验命令。`tests.rs` 还覆盖完整扫描的有序发布，`web.rs` 用有界通道覆盖写入与撤销交错、旧页面实例和旧工作区版本拒绝。Windows Rust 最终计时运行记录 357 项，其中 354 通过、3 项夹具跳过；前端受影响测试分别在隔离进程中运行，报告保存在 `.artifacts/test-stability/`。这些测试不替代双工作区真实 WebView2、真实语言服务器与停靠界面的产品验收。

- 网页隔离与上下文回归：`web.rs` 覆盖同包和外站 URL 的导航/桥接共用检查、真实路径与内部/外部目录链接；Windows 用无需提权的 junction，Unix 用目录符号链接。`plugin-web-appearance.test.ts` 执行原生宿主桥脚本，验证语言、主题、根变量、主题事件与外站不暴露桥；前端文件测试验证原生真实目标传递与拒绝传播。
- 版本探测回归：`runtime_probe_collects_output_and_rejects_overflow`、`runtime_probe_reclaims_inherited_pipes_after_parent_exit` 使用当前测试二进制作为固定夹具；后者让父进程退出、后代保留管道，断言调用有界结束且后代已退出。测试环境变量仅附加到子进程，不改测试运行器的全局环境。运行 WindowsRust 与 Frontend 计时 harness，检查 `.artifacts/test-stability/index.html`；真实 WebView2 验证还要由本机 HTTP 计数器确认外站 GET 为零，同时检查导航、弹窗/下载、动态主题、包文件和发行目录哈希不变；单凭页面 URL 没变不能证明请求未外发。

- 路线图 M1 信任链：`plugin_host/signature.rs` 用 RFC 8032 测试密钥锚定 Ed25519 原语；共享公开向量 `shared/contracts/plugins/v1/fixtures/signature-vectors.json`（含非 ASCII 文件名、canonical payload 字节、确定性签名与 contentDigest）由 `shared_fixture_verifies_end_to_end` 断言，Swift 端 `PluginSignatureVectorTests` 消费同一文件（macOS 实机运行待 CI）。`install_tests` 覆盖 staged 字节绑定批准摘要、同版本替换拒绝改动字节、staging 失败保留现行版本、回滚候选按其自身 provenance 验证；`tests.rs` 覆盖重启扫描隔离篡改/增删文件、官方 ID 拒绝无签名社区安装、社区包中存在的签名文档必须验证。`declarative_plugins_confirm_disk_install` 与回滚保持 #1424 的逐窗口停止屏障，失败时旧版本与旧记录保持可用。
- M4 Web 工具窗口：`plugin_host/web.rs` 测试覆盖包路径规范化（`..`、编码分隔符、空段拒绝）、CSP 内容断言（default-src none、无 wasm-unsafe-eval、frame-ancestors none）、桥脚本冻结与作用域、状态键隔离；web-panel fixture 随 `ui:[1,2]` 声明提升转为被宿主接受（能力门控测试同步）。桥 v0 的 build.*/functions.* 返回 `plugin.web.unknownMethod`，等构建系统能力接入。


- M3 设置链路：`settings_tests`（`plugin_host/tests.rs`）覆盖项目覆盖往返、其他插件条目保留、损坏 store 报错不重置；能力门控测试随声明提升更新（settings-v2 fixture 被接受）。设置编辑 UI（`declarative-plugin-settings-editor.tsx`）按声明的 scope/effect 渲染并显示值来源徽标。
- M3 运行计划：契约 PHP 包端到端测试（`bundled_php_contract_package_expands_plans`）走真实 Core 命令验证 validate、runPlan（`${file}`/`${userArguments}` 展开）、testPlan（workspace scope + 项目标记）、resolveSettings。


- M2 磁盘导入链测试（`windows/tauri/src-tauri/src/plugin_host/install_tests.rs`）：目录快照隔离（symlink 拒绝）、ZIP 解包与恶意路径（`../` 逃逸条目）拒绝、staging 安装（坏包失败保留现行版本且清空 staging）、回滚版本选择；runtime 启动的版本探测输出解析（node/java/go 真实输出格式）在 `launch.rs` 测试覆盖。
- 管理界面（`declarative-plugins-section.tsx`）挂在设置的独立一级页，`settings-hierarchy.test.tsx` 的布局断言随导航更新；i18n 提供 en-US 与 zh-CN 全套文案。


- 共享 fixtures 全量验收在 Windows 二进制内完成：`invalid-manifests.json` 全部 154 个用例经宿主校验路径断言同一稳定错误码（不带 hostCapabilities 的契约等价模式），合法样例在不带与带 v0 能力声明两种模式下分别断言通过与 `plugin.api.unsupported` 门控。测试入口：`windows/tauri/src-tauri/src/plugin_host/tests.rs`，运行 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml plugin_host`。
- 存储与启动的单测覆盖安装记录缺失/损坏隔离、bundled 最高版本选择、版本比较（含 prerelease）、扩展与文件名匹配（大小写与前导点）、packaged 路径逃逸拒绝、runtime 的 `LITHE_<TOOL>_PATH` 导出与 `PATH` 前置。
- 前端回落链路测试：`windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.test.ts` 断言契约插件启动映射与无归属文件返回 null；启动扫描步骤在 bootstrap 中执行。
- M1 尚属静态与进程内验证：真实插件包安装→启用→语言服务器拉起的全链路实机验收随 M2/M3 完成，期间矩阵 `verificationStatus` 保持 pending。`./scripts/verify-windows-boundaries.sh`、`./scripts/verify-platform-feature-matrix-change.sh <base> HEAD` 随 PR 通过。

## 适用范围

- `windows/tauri/src-tauri/build.rs`、`capabilities/plugin-web.json` 与 `permissions/declarative-web/bridge.toml`（应用内桥插件及最小来源权限）

- `windows/tauri/src-tauri/src/plugin_host/`（存储、扫描、启动接线与 fixtures 验收测试）
- `windows/tauri/src-tauri/src/main.rs`（模块注册与命令注册）
- `windows/tauri/src-tauri/src/language_tools.rs`（复用的系统工具查找）
- `windows/tauri/src-tauri/src/plugin_host/install.rs`（磁盘导入、卸载、回滚、启停）
- `windows/tauri/src-tauri/src/extension_store_placeholder.rs`（Worker 扩展落盘命令的显式占位）
- `windows/tauri/src/features/plugins/declarative-plugin-launch.ts`（前端宿主 API）
- `windows/tauri/src-tauri/src/plugin_host/settings.rs`（设置双层存储与命令）
- `windows/tauri/src-tauri/src/plugin_host/run_plans.rs`（运行/测试计划命令）
- `windows/tauri/src/features/plugins/declarative-plugin-settings-editor.tsx`（设置编辑）
- `windows/tauri/src/features/plugins/declarative-plugin-run.ts`（契约插件运行入口）
- `windows/tauri/src-tauri/src/plugin_host/web.rs`（Web 工具窗口 scheme、桥与状态）
- `windows/tauri/src-tauri/src/plugin_host/signature.rs`（发布者验签、contentDigest、官方 ID 固定信任策略；依赖 `ed25519-dalek`）
- `shared/contracts/plugins/v1/fixtures/signature-vectors.json`（双端共享签名测试向量；macOS 消费方为 `macos/Tests/LitheTests/PluginSignatureVectorTests.swift`）
- `Plugins/win/Official/PhpSupportContract/`（契约版 PHP bundled 包）
- `windows/tauri/src/features/plugins/declarative-plugins-section.tsx`（设置内管理页）
- `windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.ts`（契约插件回落来源）
- `windows/tauri/src/features/bootstrap/bootstrap-async.ts`（启动扫描步骤）
- `shared/platform-feature-matrix/features/declarative-plugin-contract.json`、`plugin-marketplace.json`、`plugin-extension-management.json`、`declarative-plugin-settings.json`、`php-optional-plugin.json`、`plugin-web-tool-windows.json`
