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
- 安装记录 schema 2 是安装事务的一部分：`origin`、marketplace/disk provenance（全包内容摘要与批准程序的 canonical JSON）、上一版本的 provenance 都随版本发布一起写入；安装确认、staging 发布前、启动扫描、运行/测试计划入口与回滚都会重新校验完整文件集合和摘要（community 与 marketplace origin 都复检已批准摘要，签名只证明发布者、不豁免字节比对）。版本激活与记录提交是同一事务：记录先写入 temp、激活成功后才提交，提交失败恢复旧字节并保留旧记录，恢复失败如实报错。schema 1 旧记录没有 provenance，扫描直接隔离（`plugin.trust.provenanceMissing`）并要求重新安装，绝不凭 `enabled` 或清单摘要补造发布者身份和已批准字节。bundled 身份只能由可信资源发现器产生：installed 记录声明 `origin`/`previousOrigin=bundled` 一律隔离，`sameTeamAsHost` 在扫描、启动与回滚路径都校验真实资源根包含，记录声明与回滚候选同样拒绝。审批绑定 prepare 时的整包字节：prepare 冻结整包摘要、清单摘要与审查程序，confirm 与 staging 对同一审核身份校验，prepare 之后替换/新增/删除文件都被拒绝。磁盘渠道接受已验签的 `publisherPackage` 包（origin 保持真实 disk/community），声明 `sameTeamAsHost` 的磁盘包即使签名有效也拒绝。
- 磁盘导入的私有快照、staging 重验、内容摘要复查与回滚语义照抄 macOS 侧规则（见声明式语言插件 Note 的磁盘安装节），Windows 不另造审查语义。

### 启动接线（M1 落地形状）

- `plugin_host` 模块（`store.rs` 存储布局、`scan.rs` 扫描与校验、`launch.rs` 启动计划解析）是宿主侧唯一入口；校验与计划展开全部经 `lithe_core::execute_json` 调 Core 命令，宿主不复制任何清单语义。
- `packaged` 启动入口解析后必须是包内普通文件：拒绝 reparse point（符号链接与 junction）与规范化后的路径逃逸，这是宿主执行每个启动前的统一闸门。
- `runtime` 与 `systemCommand` 启动经 PATH 探测（复用 `language_tools` 的系统工具查找），并按 macOS 同一约定导出 `LITHE_<TOOL>_PATH`、把 packaged runtime 目录前置到 `PATH`；`minimumVersion` 探测随 M2 安装链一起接入。
- 语言服务器进程仍由共享 Core 的 `lsp.startServer` 拉起：前端 `resolve-editor-lsp-launch.ts` 在 Worker 扩展清单没有对应服务器时，回落到 `declarative_plugins_language_launch`（契约插件排在 Worker 之后，已由 Worker 声明的语言保持现状，直到 M3 包迁移）。
- 启动扫描在应用 bootstrap 的 "declarative plugins" 步骤执行一次；扫描结果缓存在 Tauri state，前端经 `declarative_plugins_state` 只读消费。

### 设置保存与作用域重载

设置值的校验、默认值、全局与项目覆盖、显式空值和继承重置仍由 Core 解释。Windows 的设置页面只保留草稿并显式保存，写回后重读字节身份；`immediate` 推送匹配语言会话的配置，`restart`、`nextRun` 等待后续启动或运行，`reload` 与 macOS 一样重新读取构建模型。保存不代表已经完成重载，用户须另行确认。

全局 reload 沿用插件级跨窗口停止屏障，先撤销贡献并等待全部旧使用者退出。项目 reload 只暂停当前产品窗口、工作区和目标插件的新调用，等待其旧构建操作、设置与网页函数、原生面板函数及 VCS 会话完成清理；其他插件和其他窗口继续有效，也不改持久启用状态。原生项目登记号与真实 Tauri 窗口资源的一次实例，连同保存后的设置字节身份、已接受包身份绑定重载；复用窗口标签或项目路径不能继承旧凭据。

设置验收驱动使用独立的 settings-only API3 受控包，避免用尚未开放的函数能力冒充设置验收。双窗口保存、项目级 CAS（比较设置修订后再写入）、reload、生命周期和发行资源哈希检查由同一驱动编排；reload 保存必须从注册的语言设置页进入，编辑器只在当前可见内容中定位。输入计划、隔离宿主和当前检出的源码必须具有相同提交身份，否则预检拒绝继续。正确做法是先生成当前源码的受控包与构建身份，再执行对应子集；不要拿旧构建、旧计划或仅有辅助测试的结果宣称完整包已验收。函数能力、真实签名完整包以及清理失败注入的缺口仍使完整预检非零退出，不能通过放开生产门控消除这些缺口。

局部检测仍把完整插件集合交给 Core 决定构建系统归属，然后只重读、合并目标插件的模型与诊断。其他插件和其他窗口的代次、模型修订及执行上下文保持有效；目标修订继续递增，旧操作不能因重读同一内容而重新获准发布。命令或 Provider 模型复用既有模型准备、代码执行审批、运行、取消及清理流程，每次开始和发布都复查保存凭据，不另建 Provider 运行时。

项目级屏障在原生 registry 锁内先推进该插件的私有设置修订并捕获原构建操作，清理只处理捕获的实例；屏障结束后仍保留修订，使旧 prepare、网页审批和 VCS 读取不能迟到复活。VCS 的修订查询不要求存在构建模型，纯 VCS 工作区保持可用。原生预检查和排空不可取消，界面保持忙碌；进入模型准备和审批后才提供取消，已经取消的调用不能再开始模型准备。

停止失败时保留原生操作及其重试入口，重试先排空旧操作，再检查保存后的设置与包。原生 Provider 清理复用显式取消的初始化排空与最终清理流程，失败后重试确实再次清理原实例，不能只重复等待一个永远不会完成的标记。模型服务清理失败时，重载入口只保留旧操作 ID，并通过既有取消入口重试完整清理后继续；不能把收到取消请求视为清理完成。审批窗口卸载会拒绝未决审批，取消等待清理完成，迟到的响应不能恢复已关闭或同路径重新打开的项目。

正确做法：项目 A 保存 reload 设置后，只重读 A 中该插件的模型；若清理失败，保留通知并重试。不要用全局 deactivate/activate 实现项目 reload，也不要在前端过滤窗口后宣称已有原生隔离。该流程不增加运行时资源目录，继续使用既有平台存储位置，不写发行包、安装资源或共享工作树缓存。

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

### 网页函数、原生面板与只读 VCS 的增量边界

网页的 `functions.list/invoke/cancel` 复用设置动作已经使用的独立 Core 会话，不新建进程或 JSON-RPC 管理器。原生登记的页面、产品窗口、工作区、构建实例和完整包摘要共同决定可调用范围；页面传入的实例名只用于查找这组登记，不能授予执行程序或其他插件会话的权限。审批由产品窗口处理，但调用属于独立插件页面，确认时必须分别验证这两种身份。页面得到正式契约的 `{functions}` 或 `{value}`，设置动作仍消费已有快照，不把两种返回格式混在一起。

等待审批就占用调用名额。取消、导航、隐藏、关闭、停用和替包必须先撤销页面调用，旧确认与旧进度不能触发新页面。原生启动或销毁迟到时，原会话继续承担有界清理并保存成功证明；只有证明原进程已经结束，才能释放它的登记。正确做法是让迟到完成回收自己持有的原会话；不要用可复用的窗口标签删除一个后来创建的替代会话。设置动作的完成凭据绑定 Tauri 原生窗口资源的一次实例，最多保留 4096 条，窗口销毁时同步撤销该实例并释放其凭据，再异步清理捕获的原会话；新窗口即使复用标签也不能继承旧取消权限。拒绝审批和准备失败也必须结束页面请求，不能留下等到总超时的 Promise；取消与失败通过同一终态锁按先到事件决定结果。

网页审批结束后，清理失败的调用仍要保留在产品窗口可见的重试列表，不能只写控制台或要求用户停用插件。重试绑定原操作和原生窗口实例；成功释放后才移除记录，迟到的失败通知不能重新占有已释放调用。窗口关闭后的原生清理继续持有原会话，不能让复用标签的新窗口接管旧调用。

`native-ui/` 承载 `ui:3` schema 1 的树、列表、表单展示，会话的数据校验仍交 `plugins.nativeUI.validateData`。生产工具窗口把显式类型函数接口接到设置与网页已有的独立 Core 会话 owner（负责持有与回收进程的对象）。挂载先从原生 catalog 登记精确面板句柄，绑定包摘要、原生窗口实例、工作区代次和唯一检测到的同插件构建实例；函数名、Provider 和程序计划只读取可信声明。前端只交动作 ID、选择和表单值，准备前由 Core 校验全部当前字段，加载结果仍交 Core validateData。缺少唯一 dedicated Provider 或协议能力时明确不可用，ui:3 准入继续关闭。面板状态只放内存，按完整包、产品窗口、工作区和面板身份隔离，关闭或撤销时取消请求；同一插件、产品窗口和工作区的所有面板累计受 64 KiB 预算约束，不能每开一个面板就获得一份独立预算。长列表复用虚拟化。动作前先验证当前草稿，外部重载和重置提升会话版本，旧失焦回调不能恢复旧草稿；数据源短暂失败后允许重试，保留用户草稿和选择。这些状态不写插件包、安装资源或共享缓存，不影响签名与增量更新基线。等待原生准备和审批也占用面板唯一名额；确认、启动与交付结果前复验原登记和构建实例版本。隐藏重开、同槽替换及迟到释放只关闭其捕获的句柄，不按可复用窗口标签关闭新 owner。清理失败继续由全局函数提示持有原 receipt（完成凭据），保持 exact Window incarnation（原生窗口的这一次实例）与重试证明；已证明完成的旧释放不会清空下一次调用的占位。进度、错误和动作消息沿现有函数结果返回。

原生面板的打开请求在第一个异步步骤前取得顺序号；较早请求即使较晚完成，也不能覆盖同槽已经登记的新面板。构建模型或设置重载让成功登记的旧句柄失效后，用户重试必须先成功关闭该精确句柄，再重新登记；关闭失败仍保留旧句柄，不能通过新建会话跳过清理。

VCS 的历史、文件历史和基线比较只扩展已有短会话，继续使用 Core 的 `ownerOf`、请求和解码器，不自行运行客户端或解释版本控制元数据。游标和顺序由 Provider 决定；根映射、目录身份、包摘要或监听版本改变时，取消原查询并拒绝旧页发布。新增文件的基线和删除文件的当前内容允许为空，比较时分别作为空文本；重命名保留原路径。二进制内容明确提示不可比较。停止失败保留原操作和可见的重试停止入口，不能让禁用按钮把清理永久锁住。R11 只读范围之后，写操作按下节的精确确认边界接入；`vcsProviders` 继续关闭。

### 精确状态确认后的 VCS 写操作

选中提交、更新、回滚、标记冲突已解决（resolve）、清理工作副本（cleanup）及添加/删除文件继续使用短会话与 Core 的正式类型操作，不运行客户端命令或解析输出。原生状态凭据只在内存中保存，绑定窗口、工作区 incarnation、注册代次、根目录原生 identity、插件和完整包摘要；每个窗口/根只保留最新凭据，总条数有界。确认界面展示根路径、全部目标、双端路径数量、提交原文和操作风险，取消确认不会启动会话。执行命令消耗一次性凭据，不能靠重按确认或重试停止再次提交。

确认后先重新读取 Provider 的完整状态，和确认使用的原始标准化结果及协商能力比较；状态有任何变化就拒绝本次写入。最终请求前再次验证实时包签名、安装审批、工作区注册、根目录和 Core 的最深归属。选中写入的每个端点必须能证明是普通文件；共享状态没有文件类型字段，因此消失的端点不能仅凭 missing/deleted 状态当作文件接受。提交或 resolve 选中子文件若处于 added/replaced/renamed/copied 状态的祖先下，也必须拒绝，避免 Provider 隐式扩大确认列表。提交和回滚的重命名必须同时验证两个端点，无法证明其中一个时保守拒绝。目录递归写入无法证明精确选择时拒绝；update 和 cleanup v1 都没有路径参数，因此只允许工作区等于整个根、根检测和状态完整且不存在嵌套或歧义根，再由 Core 确认整根归属，不把父工作副本的其它目录一起操作。

resolve 使用实际协商的 `conflicts` 能力，只接受状态为 conflicted 或带 treeConflict 标记的现存普通文件；目录、消失端点、路径别名及无法证明精确归属的目标均拒绝。确认逐项展示所选冲突路径，发送时只保留这些路径，不展开重命名的 oldPath；操作使用用户已经保存的内容并改变冲突元数据。cleanup 使用协商的 `cleanup` 能力，确认说明整根范围和锁等元数据影响，类型参数保持为空，不能附加路径或版本冒充局部清理。

添加和删除复用 Core 的 `fileOperation` 请求与协商的 `fileOperations` 能力。add 只支持根目录直属、状态为 unversioned 的现存普通文件；v1 不能证明未出现在状态列表的父目录已受版本控制，因此嵌套文件添加也保守拒绝。delete 必须展示全部端点，并说明磁盘删除由 Provider 执行、请求没有 keep-local 选项且宿主不备份；所选行及展开后有独立状态的端点都须在允许范围内，冲突、忽略、未受控、外部或子模块端点不能随重命名扩展混入。目录、缺失端点、隐式 scheduled 祖先和路径别名仍按原规则拒绝。

正确做法：用户选中已存在的普通文件 `after.txt`，确认展示全部请求端点，原生复核类型、祖先状态及同根归属后才发送一次 checkin。不要这样做：把已消失的目录当作一个文件回滚，隐式提交 added 祖先，或将工作区内部的 update 当作能限制范围的请求。缺失文件和常见重命名的写操作保留为后续能力，不能为扩大支持而猜测节点类型。

写入开始后的本地取消、丢失回复、非法回复或成功回复后的清理失败可能已有副作用，界面要求刷新核对；明确的认证失败、过期提交或写前拒绝保留失败状态，不混成未知结果。Core 在请求完成事件中交付的显式 Provider 失败也是确定失败，传输中断仍属于未知结果。此类确定失败即使同时遇到销毁失败，也保留原错误及其分类，后续停止重试成功后仍显示原失败；不能用清理错误覆盖写入是否发生的事实。停止重试只使用原操作的进程归属，不能重发 checkin/update/rollback/resolve/cleanup/add/delete。不同窗口对同一根的写操作互斥。原生进程树结束证明仍由既有 Core 会话清理提供，失败保留租约与原 owner。

写入自身会改变元数据。最终复验成功后，在原窗口、scope 和 generation 的 registry 条目中暂停监听失效，直到写后完整检测替换该条目；条目数量沿用工作区预算。这样进程 owner 已回收后才交付的旧元数据事件，也不能撤销成功结果。其它窗口继续独立失效，插件撤销和窗口关闭仍直接撤销 registry。完成后由原 scope 重读根、同根状态和原历史；新一代恢复普通监听，旧 scope 不发布结果。监听永远不确认或补发写操作。

文件移动不能沿用已存在双端点的校验后直接执行。正式 v1 的 `fileOperations:1` 只声明操作可用，不承诺原子地拒绝覆盖，也不保证缺失叶子不会被解释为后来出现的目录；最后一次目标不存在预检无法消除 Provider 调用期间的竞态。固定 Subversion Provider v0.1.0（commit `3a558be049f47a3ebe24ae770faf7999df883c29`，SDK `54598ae6e0b9fd71a07b77e1fea6917ba8897a6f`）把已跟踪移动交给 `svn move --parents`；没有 `--force` 不是并发安全证明。当前 Windows 不增加 move 菜单、未接线的计划器或磁盘 fallback。保证应由 Provider 与成熟 SVN 事务实现提供，契约如何表达该保证须先评审，不能按插件 ID 特判或重新解释既有 v1 能力。源码审查和当前控制器拒绝不证明真实 Provider、安全目标发布或固定 Windows 包已验收。

Windows x64 对上述固定 Provider 源码和历史 SDK 的直接 stdio 诊断，使用 VisualSVN 官方签名的 Apache Subversion 1.15.0 复现了这个边界。事件门位于真实 status 完成及 handler 进入之后、最终 SVN 启动之前；诊断 wrapper 原样转发参数与输出，不属于发布包，Provider 已跟踪 move 分支本身没有目标预检。目标始终缺失时，源移到精确叶子；目标随后出现文件时返回 E155033，字节和文件身份未变，但 `--parents` 已把目标调度为 added；目标随后出现目录时返回成功，源实际移入 `target.txt/source.txt`。因此失败也不能假定工作副本无副作用，成功也不能假定目标是精确叶子。三例只证明诊断设备完成并给出反例，不证明生产宿主或正式包验收；当前一次性脚本还缺少长期 CI 所需的外层 watchdog 和异常清理，不能直接注册为长期回归。

新增状态全部在内存中；Provider 可写目录仍由现有平台存储 adapter 提供，没有新下载、生成或缓存路径，安装包和发行资源保持只读。`ui:3` 与 `vcsProviders` 继续关闭；文件 move、缺失节点类型证明与 gutter/Annotate 未扩展。resolve/cleanup 已接入不代表真实 SVN 客户端、生产插件包、原生进程树或 WebView2 人工验收通过，这些验证继续 pending。

### 与 Worker 扩展模型共存（产品分工）

- 两套模型互不桥接：契约插件不进 Worker 宿主，Worker 扩展不冒充契约能力。
- PhpSupport 迁移（M3 调整）：契约版 PHP 包（`Plugins/win/Official/PhpSupportContract`，`sameTeamAsHost` bundled）随安装器分发并完成 validate/launch/runPlan 端到端测试，但 Worker 版**保留不移除**。原因：Worker 版提供 composer scripts 的动态运行动作发现（读取工作区 composer.json 生成动作列表），契约 v1 的 `executionProviders` 是静态声明，没有等价能力；删除 Worker 版会丢失用户可见功能。完整迁移等契约补齐动态运行动作后再做。两包并存时 Worker 版优先（Worker 扩展清单先解析），契约包不重复注册语言。
- `install_extension_from_url` 等 Worker 非语言市场命令（M2 已处置）：在 Rust 宿主注册为显式占位错误（`extensionStore.notAvailable`），调用方得到可诊断的结构化失败而不是"命令不存在"；完整落盘后端是独立工作项，不与契约宿主混淆。
- 管理界面按模型分组展示两类扩展并使用不同文案，避免用户把 Worker 扩展当成契约插件。

### Windows 构建依赖的来源与代理边界

根 Bun 工作区的显式 tarball 来源改用 npm 官方仓库，保留全部精确版本、依赖声明和
SRI（压缩包的完整性摘要）。来源迁移必须机器比较完整 lock 图；只传 `--registry`
不能证明显式 URL 已改变。Bun 缓存仍以工具版本、lock 原字节和文件清单封存，来源
变化会使旧 seal 失效；安装目录、临时目录和 GitHub lifecycle 二进制不能跨树复制。
工具版本固定为 Bun 1.3.14：该版本官方说明明确修复安装时 TLS 握手停滞、下载 HTTP
错误及 isolated linker 摘要失败后的挂起；1.3.12 实测停在 GitHub 归档路径，而
1.3.14 同一归档能进入原生构建。此处升级的是安装工具，不升级产品依赖图。

tree-sitter-cli 的两个上游 `install.js` 保持原样。Windows worker 只为该包加载
`windows-tree-sitter-proxy.cjs`：有 HTTPS 代理时，把连接管理交给 Node 原生
`https.Agent({proxyEnv})`，并仅在当前 lifecycle 中移除上游手动 CONNECT 分支读取的
环境变量；TLS 校验、重定向、响应解压和可执行文件落盘仍由 Node 与上游实现。
正确做法是验证完整响应体、gzip 解压及 `--version` 后再运行 frozen 全量安装；
不要因响应头为 200、增加超时或手工放置 EXE 就宣称修复。代理适配要求支持该能力的
Node 22.21+ 或 24.5+，不新增下载器和长期二进制缓存。代价是代理安装的 Node 最低版本
更明确；收益是复用上游原生连接管理，避免维护第二套 CONNECT/TLS 实现。
源码清单先解析模块的真实路径，再相对已解析的仓库根生成键；SUBST 导入路径和物理
路径必须得到同一清单，不能因开发者用短路径避开 Windows 编译路径上限而拒绝构建。

### 实施切分

M1 包存储 + 启动校验 + 语言注册 + LSP 启动（已落地）；M2 磁盘安装链路 + 管理界面 v1 + 死链处置（已落地）；M3 声明式设置 + 运行/测试计划 + PHP 契约包（已落地，Worker 版保留见上文）；M4 Web 工具窗口（已落地，桥 v0 只含 state/openFile/主题，build.* 与 functions.* 等 Windows 构建系统能力接入后开放）。路线图 M1（发布者签名 + 全包完整性 + 安装记录事务，`signature.rs` 与 schema 2 安装记录）已落地；本 Note 早期的 M1–M4 编号是宿主 PR 的内部切分，与路线图的 M0–M10 不是同一序列。每个里程碑独立 PR，矩阵条目随代码同 PR 更新。总体方向遵循[公共扩展契约与 Provider 接入方向](../../proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)，本 Note 只落地其中 Windows 契约宿主的第一阶段。

## 考虑过的备选方案

- 仅扩大安装预算、反复冷装或自建 tree-sitter 二进制缓存：不能消除实际 TLS 路径差异，
  npm SRI 也不认证另行下载的 GitHub 二进制；尤其官方摘要为 null 时不能建立可靠复用身份。
  采用官方 npm 来源与 Node 原生 Agent 的最小适配，保留上游生命周期。

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

显式 SVN move 诊断通过 vcs_move_diagnostic.py 接收固定源码、SDK、SVN 和 gate 的绝对输入，先解析真实路径并拒绝输出与输入树重叠（含 junction 别名），再创建独立临时 runtime/repo/WC/profile。每个工作进程先归属 Windows Job 再释放启动，case/suite 有硬 deadline，退出核实零成员后才允许恢复快照；清理无证明时记录 unknown、隔离保留临时树，禁止继续 SVN 读取或删除。最终固定输入/runtime 字节变化或读取失败必须写入失败报告，不能仅让 CLI 非零却留下绿色 JUnit。离线回归验证这些边界，真实三例仅记录诊断匹配且 safetyPass 始终 false；不启用生产 move，不把 wrapper gate 当作 Provider 内部预检。临时状态及证据通过既有 plugin-host-acceptance-state 排除路由拒绝跨工作树复用。

ui:2 网页桥的回退验收保持生产 transport（传输入口）原样：受控静态 unsigned 包仅声明 ui.contribute/ui.web，从真实安装审查和插件窗口入口进入私有 WebView2。故障只在该页 CDP（浏览器调试协议）session 中令一个精确匹配 ui.setState nonce 的 custom-protocol POST 失败；随后原 Promise 经真实 postMessage 成功，保持拦截时 ui.getState 读回 nonce 且 POST 总数仍为一次，证明该文档后续请求沿用回退路径。观察固定 Tauri warning、冻结入口描述符/函数摘要和真实 callback Map 排空；不得替换 fetch/invoke/ipc、伪造 callback 或补回包。失败也释放 paused 请求、关闭 CDP 和产品、按进程句柄清理隔离 profile，最后核对发行镜像、安装包与 ZIP 字节。这只证明 Windows x64 下受控网络故障的 ui:2 状态桥；不证明物理网络故障、其他能力、arm64 或正式签名完整包，M10 仍 partial/pending。

Apache Subversion 1.15.0 官方源码（commit e49d66ef91dd33409c7d78f82160d2976a939120，SVN r1938480）的 move7 在单源、父目录命名空间稳定且四项布尔参数均为 FALSE 时，保留请求目标路径并关闭移入已有目录的重试；这只约束路径解释，不保证目标身份或禁止替换。目标检查先于工作副本写锁，写锁只约束遵守 SVN 协议的重叠写入，不能阻止普通文件系统外部写入。目标元数据复制、磁盘重命名、源元数据删除分阶段执行；WIN32 最终直接调用带 MOVEFILE_REPLACE_EXISTING 的 MoveFileExW，因而目标可能被替换，失败或取消也可能已有磁盘/元数据副作用。APR rename 不在该最终路径上，无需猜测 APR 版本；官方源码静态分析不证明 VisualSVN 二进制身份或真实竞态，不能作为 Windows move 准入依据。引用提取必须按 LF 物理行计数，不能把 C 源码中的换页符当作新行。

ui:1 字面文本安全验收使用一次调用生成的完整 unsigned API3 包，仅声明 ui.contribute；计数服务先绑定 loopback 端口并做正向控制，再生成 ZIP 和绑定当前源码身份的 plan。正式入口必须冻结构建前后源码清单并绑定可执行文件、配置和提交，不能给旧二进制补造当前 identity。打开私有页面前订阅浏览器请求，用原始 Document 和桥脚本两条请求防止空迹通过；比较文本、DOM、CSP、冻结 transport、回调排空及包和发行镜像字节。浏览器请求观察只能证明其可见的网络请求，不能把未观察到请求或空回调 Map 写成精确零 postMessage IPC。辅助测试仅验证失败边界。R20 正式入口在资源校验前缺 native Bun PATH，依赖恢复经历 TLS 失败；完成依赖/helper/frontend 后，短命进程检查竞态又中断构建，最后耗尽 90 分钟总预算，未产出验收 EXE。九个真实运行时步骤均未执行。R21 已补构建前 native bun.exe 定位与固定版本检查，安装局部预算由验收入口经 build 传到 installer（每次 1～1200 秒、默认 300 秒）；短命进程仅在原进程退出或句柄已触发等正向证明下忽略，仍在运行却无法检查时失败。Tauri 结束后通过同一个独占文件句柄比较 Cargo.toml：原字节不写，只有精确 CRLF→LF 结果才恢复；语义编辑、占用或删除均保留现状并拒绝 identity，构建原错和检查错同时保留。13 项准备回归及进程 owner 回归通过；这只修复工具，未运行本轮 Cargo/Release/产品，仍须下一轮一次正式构建和九阶段验收。R22 唯一正式入口因 PATH 前置 MSYS 而选中 GNU tar，在 JDTLS 解压阶段中断，未进入 Cargo、未产出 EXE，九个真实步骤全部未执行。准备脚本现从平台 SystemDirectory 定位原生 tar，不依赖 PATH；缺失在缓存/输出变更前失败，解压非零保留原生错误并停止后续复制。16 项离线准备回归通过，涵盖绝对盘符/空格路径的小 tar.gz/VSIX、假 PATH tar、坏归档及提前缺失；这仍只证明工具边界，必须另做一次正式产品验收。真实安装、文本页、隐藏重开和退出仍 pending，不能据此升级 M10。

截至 R19 采样，官方 v0.1.0 prerelease 仅列出完整 Darwin 源码插件包及校验和，未列出 Windows 包。ZIP 的完整 14 文件、tag 字节和 7 个 SDK 锁哈希已核对；这不证明与当前宿主动态兼容。完整 manifest 要求 serverProcess:1、vcsProviders:1，固定 Windows 宿主尚未声明后者。该包为 unsigned Community 来源，需用户明确批准；Marketplace 不接受 unsigned，GitHub 来源与校验和不能代替发布者签名。R20 在 ignored 的固定上游 main 717d23cd417f796d8487b3b7cbc8150a8356b512 上应用本地打包补丁，Windows x64 使用系统 bsdtar 3.8.9 顺序组装 darwin、windows-x86_64 目标：两 ZIP 各 14 个普通文件、CRC、7 个 SDK 锁哈希与 24 条静态导入闭包核对通过，payload 相同。manifest 仍为 0.1.0，完整 requires 未删减；这是本地非官方 unsigned 候选，Darwin 只是分发标签，未在 Darwin 执行。R21 的 ignored 上游补丁改为未发布 0.1.1 候选，已迁移 CI/release 的显式 platform/tag/output、四资产集合及 existing-release 严格校验，并在写入前拒绝输出与源码的真实路径/junction 交叠。两 ZIP 各 14 文件、7 SDK 锁哈希、24 导入边、CRC/SHA 与相同 payload 重验通过，12 项离线打包/发布分支检查通过。R22 以私有 staging 的 exclusive 新文件和 rename 替换 checksum 目录项，修复硬链接截断输入；README、锁定 SDK 和同 hash 硬链接回归及发布失败边界通过，五个真实 release shell 离线 gh 分支已纳入可携带的上游测试。15 项本地检查及双 ZIP 全量审计通过，11 文件完整补丁往返逐字节一致。审查另发现 P1：新增测试进程封装在 Popen 后才归属 Windows Job，快速子孙可能在分配前逃逸；当前 Job active=0 不能证明逃逸成员退出。需先归属再释放目标及确定性短命 root/失败回收回归，修复前上游补丁仍 pending，不作为可发布方案、不纳入主仓产品源码。未运行 Provider、产品、SVN、签名或发布；Windows 正式安装、依赖探测、initialize 和界面仍 pending，保持 partial/pending 与现有门控。

R23 正式入口已通过原生 tar 的 JDTLS 准备，随后依赖安装先耗尽 1200 秒局部预算，既有的一次 clean retry 又在 tree-sitter-cli 的 GitHub 二进制下载遇到 TLS ECONNRESET。尚未进入 Cargo，没有 EXE 或构建 identity，ui:1 九阶段仍为 0/9，不能用准备回归或旧 Release 补足。该下载由 npm 包的 install.js 另行发起，npm tgz 的 SRI 不证明 GitHub 二进制；修复应先核实当前 Node 与子进程实际采用的代理/重定向路径，保持 TLS 校验，再在同一任务内完成完整安装、冻结源码、构建和一次正式验收。

R23 的 ignored 上游打包补丁已修复上述先启动目标、后归属 Job 的竞态：先配置关闭即终止成员的非 breakaway Job，启动仅等待未触发事件的可信 Python bootstrap，归属成功后才释放目标。目标及子孙由内核继承 Job；清理使用保留的进程句柄和成员计数，不用历史 PID 猜测所有权。配置失败不得启动进程，归属失败不得启动目标；原始错误和清理错误同时保留。6 项 owner、9 项打包以及 zsh/bash 各 5 项真实 release shell 离线分支共 25 项通过，双 ZIP 全量审计及 12 文件完整补丁往返逐字节一致。复审未发现阻塞缺陷；这仍是未发布 unsigned 0.1.1 本地候选，POSIX 进程组清理没有在 Linux/macOS 内核实测，不作为跨平台运行、Provider/SVN 或正式发布证据，既有能力门控保持关闭。

R24 的真实 Node 24.15 子进程已验证两个 tree-sitter-cli 版本的 CONNECT、受系统信任的 TLS 以及 302/200 响应头，但探针随即停止读取；响应头不能证明完整下载、gzip 或 lifecycle 安装成功。本轮安装还观察到 tree-sitter-c-sharp 与 @xterm/xterm 的 npm tarball SRI 完整性错误，随后主动取消；不能把两条错误分别记为首次及内部重试。降低并发后的另一次安装达到 1200 秒期限，日志不足以定位停在何处。因此未进入正式构建，ui:1 九阶段继续 0/9 pending。下一步先对比 lock 固定镜像与 npm 官方源的完整字节/SRI，再验证两个真实 install.js 的完整下载；不得只凭 HTTP 200、重设相同代理或扩大期限宣称已修复。v0.23.2 官方资产摘要仍为 null，未建立二进制复用路径，45 项离线/helper 通过只证明辅助边界。

针对失败包的四次完整传输补证表明，官方源的 tree-sitter-c-sharp@0.23.5（3,685,327 字节）和 @xterm/xterm@6.0.0（1,418,562 字节）均匹配当前 lock SRI，包内精确版本及依赖声明也一致，无需因此修改版本或这两个节点的依赖。镜像 C# 包在本地 60 秒截止前未完成，不能把截止触发的 reset 当作远端主动重置；xterm 两源完整字节相同。xterm 官方 metadata 的 TLS 请求失败，只有 C# 另获官方 metadata integrity/shasum；这些证据支持验证官方来源方案，尚未证明 Bun 能覆盖 lock 显式 URL、全量安装或 GitHub lifecycle 下载成功。

上游打包候选的 R24 完整 12 文件补丁已经完成 Windows 本地源码交付，25 项去重回归、干净 clone 应用往返、四资产和双 ZIP 全字节验证通过，复审未发现阻塞缺陷。Linux 正常退出、超时与短命 root 后代清理三项回归已接入同一正式测试入口，CI/release 先运行并传播失败，报告以 always 条件上传；本机 Linux 环境缺工具，三项没有动态执行。MSYS zsh/bash 属 Windows 内核证据，不能填补 Linux/macOS 验收；维护者仍需应用候选并运行 Ubuntu CI、完成签名/安装及 Windows Provider 与宿主动态兼容验证。此结论不开放 vcsProviders/ui:3，也不代表已发布 0.1.1。

## 验证

- 设置作用域回归：`declarative-plugin-settings-editor.test.tsx` 使用真实生产控件验证继承、全局项锁定、空值、保存/取消、重置与冲突；`declarative-plugin-reload-project.test.ts` 使用真实模型服务验证保存凭据、审批、不可取消预检与可取消模型阶段、清理失败重试和同路径重开拒绝迟到结果。`build_tests.rs`、`build/tests.rs` 和 `settings/snapshot/tests.rs` 覆盖目标窗口隔离、持久设置修订、真实窗口资源实例、精确原操作清理重试与 Core 归属。集成窗口已通过原生逐项计时测试；前端使用原生端口替身，真实双窗口 Provider 与发行目录哈希验收仍须另行完成。
- 原生面板函数回归：`functions/native/tests.rs`、`functions/runtime/tests.rs` 和网页函数测试覆盖倒序打开、旧凭据清理、作用域隔离、晚审批和失败清理重试；`native-functions.test.ts` 与三个共享原生 fixture 的组件回归验证生产控件到 typed port 的完整调用。受影响 Rust 与 Frontend 计时测试、完整 TypeScript、格式和静态门禁已通过；这些证据不代替真实包、停靠布局和 WebView2 人工验收。
- VCS 写入回归：`vcs_actions_tests.rs` 使用真实 Core decoder/ownerOf 覆盖普通文件、消失和双端移动端点拒绝、隐式父目录扩展、Windows 路径别名、跨根与歧义；`vcs_session_tests.rs` 的受控 runtime 检查 typed Core request、真实 reply decoder、最终复验拒绝、未知结果与精确作用域清理。R12 原生与前端计时回归已通过。R13 新增 resolve 的冲突能力/精确端点、cleanup 的完整整根范围，以及确定失败/未知结果经过清理重试后不变且不重发的回归；集成树 `vcs-resolve-cleanup.test.ts` 与 `vcs-actions-panel.test.tsx` 聚焦计时 13 项通过。新增原生回归已随最终宿主计时测试通过；`vcs_session_core_tests.rs` 的真实 Core stdio 夹具由 `node scripts/test-windows-plugin-vcs-core.mjs` 显式执行并通过。R14 将同一夹具扩展为 resolve/cleanup/add/delete 四个操作，单操作请求与清理各有 5 秒和 13 秒上限，入口为唯一用例设置 90 秒预算、绝对 `LITHE_VCS_TEST_NODE` 和 `--ignored`，四操作已显式运行并通过（1304ms），结束要求恰好一个通过结果；普通宿主测试中的 ignored 不能作为验证。正式 Provider、系统 SVN 客户端、生产包与进程树验收另行完成。

- 多窗口事件投递必须显式指定当前产品窗口的 `Window` target。Tauri 默认 `Any` 监听也接收发给其他 label 的事件，原生 `emit_to(ownerLabel)` 本身不足以隔离接收者；文件请求与生命周期确认均绑定当前窗口，防止其他工作区误处理请求或重复确认。`plugin-lifecycle-listener.test.ts` 检查两类监听的目标。
- 2026-10-24 Windows Release 实机验收：Playwright/CDP 连接真实 WebView2，测试包安装、ui 1 文本渲染、工作区关闭重开、状态隔离、两个产品窗口归属、主题/语言与重载、过期工作区 openFile 拒绝、双窗口卸载关闭全部插件页均通过；无重复确认异常，外站 HTTP GET 为零，安装包及发行资源哈希不变，应用正常退出。该测试包不替代真实语言服务器的完整安装→启动→即时设置验收，也不覆盖停靠布局。
- 管理并发回归：`lifecycle.rs` 覆盖原生使用计数排空、禁止晚到获取、逐窗口确认、停止失败、窗口断开和有界超时；`lsp-core-adapter.test.ts` 用可控 Core 响应覆盖停止期间晚到的服务器，断言先停止再拒绝，且 `pluginId` 没有丢失。`plugin-lifecycle-listener.test.ts` 验证收到停用事件立即撤销入口、等待运行和 LSP 两方后才确认。
- 工作区与界面回归：`web.rs` 覆盖双工作区窗口/状态键隔离和文本转义；`plugin-lifecycle-listener.test.ts` 验证其他工作区请求、路径解析中切换工作区以及成功确认；`workspace-lifecycle.test.ts` 验证关闭工作区时清理网页。`declarative-plugin-ui.test.ts` 用 Hello Lithe fixture 验证文本窗口与命令面板、菜单、工具栏三处贡献及撤销，受控刷新同时覆盖相关与无关插件的撤销。CI 按文件分进程执行插件套件，避免原生命令和事件 mock 跨套件泄漏。
- 启动计划回归：`launch.rs` 验证必需资源缺失、运行时依赖缺失、目录资源与普通文件入口的区别，以及有输出但非零退出的校验命令。`tests.rs` 还覆盖完整扫描的有序发布，`web.rs` 用有界通道覆盖写入与撤销交错、旧页面实例和旧工作区版本拒绝。Windows Rust 最终计时运行记录 357 项，其中 354 通过、3 项夹具跳过；前端受影响测试分别在隔离进程中运行，报告保存在 `.artifacts/test-stability/`。这些测试不替代双工作区真实 WebView2、真实语言服务器与停靠界面的产品验收。

- 网页隔离与上下文回归：`web.rs` 覆盖同包和外站 URL 的导航/桥接共用检查、真实路径与内部/外部目录链接；Windows 用无需提权的 junction，Unix 用目录符号链接。`plugin-web-appearance.test.ts` 执行原生宿主桥脚本，验证语言、主题、根变量、主题事件与外站不暴露桥；前端文件测试验证原生真实目标传递与拒绝传播。
- 版本探测回归：`runtime_probe_collects_output_and_rejects_overflow`、`runtime_probe_reclaims_inherited_pipes_after_parent_exit` 使用当前测试二进制作为固定夹具；后者让父进程退出、后代保留管道，断言调用有界结束且后代已退出。测试环境变量仅附加到子进程，不改测试运行器的全局环境。运行 WindowsRust 与 Frontend 计时 harness，检查 `.artifacts/test-stability/index.html`；真实 WebView2 验证还要由本机 HTTP 计数器确认外站 GET 为零，同时检查导航、弹窗/下载、动态主题、包文件和发行目录哈希不变；单凭页面 URL 没变不能证明请求未外发。

- 路线图 M1 信任链：`plugin_host/signature.rs` 用 RFC 8032 测试密钥锚定 Ed25519 原语；共享公开向量 `shared/contracts/plugins/v1/fixtures/signature-vectors.json`（含非 ASCII 文件名、canonical payload 字节、确定性签名与 contentDigest）由 `shared_fixture_verifies_end_to_end` 断言，Swift 端 `PluginSignatureVectorTests` 消费同一文件（macOS 实机运行待 CI）。`install_tests` 走真实 prepare→review→confirm→publish→scan 路径（测试密钥经 cfg(test) 注入，生产不可达）：记录提交失败恢复旧字节与旧记录并可重试、首次安装记录失败不留字节、staged 字节绑定批准摘要、同版本替换拒绝改动字节、已签名磁盘包安装与加载、未知 key/坏签名/sameTeam 磁盘包拒绝、prepare 后替换/增删文件拒绝、回滚候选按其自身 provenance 验证且 bundled 声明拒绝；`tests.rs` 覆盖重启扫描隔离篡改/增删文件、installed 记录伪造 bundled 来源隔离、官方 ID 拒绝无签名社区安装（seal 错误）、社区包中存在的签名文档必须验证；`signature.rs` 单测覆盖真实资源根包含检查。`declarative_plugins_confirm_disk_install` 与回滚保持 #1424 的逐窗口停止屏障，失败时旧版本与旧记录保持可用。确认编排里，会话身份只解析一次且位于统一清理块内，其值既作为真实 `lifecycle::begin` 的屏障键、也显式传入共享编排作为发布前身份校验的期望值——helper 不重读身份，发布前拒绝身份漂移（屏障期间会话换成其他插件时，任何字节都不在错误屏障下发布）；安装记录的读取与回滚链构造同样在屏障内完成。屏障拒绝与校验拒绝（含身份解析失败）都释放快照与会话记录。事务中断遗留的 `*.previous-tmp` 恢复备份（完整版本名命名，相邻补丁版本不碰撞）在下一次发布前按 durable record 当前批准的摘要判定：备份即批准字节则恢复、批准字节已在他处完整存在则清理备份、无法证明则拒绝歧义状态并完整保留数据，跨版本的孤儿备份在其批准字节可证时先归位自身版本目录，恢复失败保留备份并如实报错，绝不盲删。恢复前还校验记录的插件身份与单段版本路径，损坏记录不能把备份移到其他插件或用户目录。清理失败的回归从真实发布事务留下备份后再触发下一次记录提交失败，避免只手工创建预期路径而漏掉实际备份命名错误；测试文件锁与临时目录均用作用域清理。
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
