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

### Build Provider 的传输基础（阶段 D，产品入口仍待迁移）

Windows 的 Build 后端继续复用已有 Core LSP 进程运行时，不另写 stdio、RPC 或进程树
管理器。原生 `plugin_host/build.rs` 只给已准入的插件展开公开启动计划，复用现有的包路径、
运行时版本和生命周期检查；会话按插件、构建系统和工作区隔离，不伪造 Java 文件来启动。
目前只接独立 Provider 进程，共享语言会话型 Provider 明确拒绝，能力声明仍保持关闭。

`WindowsBuildProviderSessions` 串行处理同一目标的启动解析与替换，任务请求可以独立并行。
包、设置、实际运行时或环境变化先停止旧进程；停止失败时禁止新请求，显式重试清理成功后
才恢复。解析前后都检查插件代次，工作区关闭会等待晚到的启动回复并销毁其进程。
单个请求取消只取消该操作，不能停止其他调用者共用的后端。原生解析未返回时，调用者可
立即结束等待，后台仍持有这次解析，避免取消后丢失晚到进程的清理归属。

Core 请求 ID 在发起 IPC 前登记，因此进度或回复先于 IPC 确认到达也能找到原操作。
回复原样交给领域解码器，不经过语言位置字段的转换；取消或完成后的迟到消息丢弃。
例如 Build 模型中的 `utf16Column` 属性应原样保留，不应因为复用了 LSP 运输层就改成
`character`。进度消费者失败会撤销自己的请求，不能让事件泵退出或启动旧 Maven fallback。

可写位置由平台存储分配为
`app_local_data_dir()/plugin-state/<pluginID>/build-systems/<buildSystemID>/<workspace 哈希>`，
与语言服务器状态分开，归插件安装和工作区会话所有；卸载时随所属插件状态清理。
目录没有可复用的版本/平台/架构/工具链身份，资源清单及排除路由拒绝跨工作树复制。
安装包、插件包和签名基线保持只读。此基础不代表 Maven 模型、任务、设置、报告和 Run
消费者已迁移，也不能据此删除仍在使用的共享 Core Maven 命令。

工作区领域编排（`WindowsBuildProviderWorkspace`）已补当前模型、逐工程依赖、普通任务和
随执行返回的测试报告，所有事实继续经过 Core 计划与解码。它只保存有界输出和操作记录，
保留非零退出码及失败报告；选项、工具、插件设置或包变化要求重新加载模型。调用方传入的
选项和参数先复制，插件代次变化后已发布模型立即不可用，取消后的进度与晚到解码不能恢复旧状态。
通用原生窗口的接线增量见下文；旧 Maven Store 仍未切换，能力声明仍关闭，不能据组件测试宣称 Windows 已迁移。

原生配置读取独立于模型就绪状态：损坏 POM 时仍可通过 Maven 获取真实来源与非敏感字段。
自动读取发现项目工具时，在发送任何 Provider 请求前返回需要显式动作的错误；只有产品的
“使用项目工具读取”动作才允许继续，不能因发现失败偷偷切回旧 Maven 配置服务。
配置的 Core 解码只接收结果本身，不向严格的配置契约塞入模型根或选项字段。选项/插件/工作区
失效和取消继续覆盖读取及解码；设置页草稿、确认保存及旧配置迁移仍待完成，文件写回
adapter 的后续增量见下文。

后续文件 adapter 已补准备与提交两阶段：Core 内部编辑直接节点，Windows 的
`lithe-project::native_configuration` 复用既有文档原子替换，不新写文件发布器。
原始 XML 从有界 UTF-8 文件读取后只留在原生内存，不能序列化或 Debug 输出；WebView
只拿到是否有修改及安全错误码。准备只读，提交重新核对源路径、安装保护目录、源字节、
包/设置/工具链输入。外部修改、并发创建和链接换向保留磁盘数据，冲突内容不得从既有
文档模块返回界面。未修改草稿不创建文件或父目录，缺失来源仅在提交时创建。

原生准备按实际窗口及操作 ID 持有，最多 8 项、60 秒后拒绝提交；窗口关闭递增代次，
阻止关闭前开始的准备在关闭后登记。插件变更先等待正在使用的原生操作退出，再释放
该插件的准备。前端在发起提交前重新检查读取回执、选项/包/工具身份，取消立即结束
调用方等待，但继续持有迟到的准备并释放令牌。写回完成才向 Maven 重新读取当前值，
不把草稿当作生效值，并撤销同构建系统各根的旧模型和其他在途操作。原子提交开始后
即使调用方取消，实际完成的写入仍必须撤销旧事实，不能继续显示或运行旧模型。
设置页确认/草稿呈现、
旧配置迁移和 Windows 原生整机验收仍待接线，产品能力声明继续关闭。

Windows 的相邻临时文件复用 `.lithe-document-<pid>-<sequence>.tmp`，归单次替换所有，
操作结束清理；原生内存令牌没有可复用身份。两者已登记为不可跨工作树复制的原生配置
状态，不写发行安装目录，不影响代码签名或 Sparkle delta。

原生工具解析复用 Run 注册表；`runConfig.projectToolchain` 只读 `.lithe/run/local.json`
的默认值和最近路径覆盖，并读取既有 runtime 选择。它不解析 POM、不创建 Run 文档，损坏
文件明确失败。被动自动 JDK 选择只读取有界的 `release` 元数据，经 Core 提取完整版本后
复用版本排序，缺失或损坏时不回退到运行 Java；项目程序及别名不参与机器 JDK 发现，显式
路径只检查存在。工具依赖按 Core 顺序解析，选中的 JAVA_HOME/PATH
与明确声明的环境输入才交给 Provider，Core 选项环境保持更高优先级。项目启动器，包括指向
外部程序的项目 Wrapper 别名，都标记为项目代码，不为发现版本执行它们。任务和模型必须
使用同一份已准入清单、工具和设置快照，不能在工具变化后继续消费旧模型。
工具发现本身不创建 Provider 状态目录；显式任务需要进程探针时才创建可写状态。
Windows 批处理启动器的版本校验复用 Run 既有的 cmd 引用规则，不直接把 `.cmd` 当 PE 程序启动。
Maven/JDK 以外的通用 toolchain 只消费已保存的 runtime 路径，缺失时明确要求选择；不调用
Run 的全量工具版本发现。Core 声明的 command、environment 等候选仍可做文件系统发现。

### Build 工作区与原生窗口接线（阶段 D，准入仍关闭）

团队 Build 文档复用 `.lithe/build/options.json`，只读 adapter 拒绝越界别名、损坏、
非普通文件和超过 2 MiB 的输入；缺失时不创建文件。结构校验交给 Core 的
`build.projectOptions`，检测直接使用 Core 返回的逐根选项，不重写继承或空值规则。
检测只读取当前已准入、启用且未被撤回的声明，不启动 Provider 或版本探针。

`BuildWorkspaceOwner` 按打开的项目持有目录、模型和操作，窗口隐藏或切换不会销毁任务。
关闭项目与替换项目共用同一异步清理入口，清理失败保留原所有者并阻止再次创建进程，
可显式重试。Build 停止与已有 Java/终端清理分别得到执行机会；插件停用或更新在原生
确认屏障前停止所有工作区的所属 Build 目标，即使重新检测已经清空了当前目录也不会
丢掉历史目标。重新启用后再检测，旧检测、旧操作或旧插件代次不能重新发布结果。

右侧通用 Build 窗口复用现有可调整面板，底部输出复用现有输出控件。当前增量提供
检测、显式加载 Provider 模型、模型任务和按操作 ID 停止；超过 200 个任务使用已有
虚拟列表。目录与模型只在自身变化时通知，进度在一次事件排空后合并通知，输出叶子
只复制当前操作，不让工作台复制整份输出历史。

正确做法：隐藏窗口后再打开仍看到原任务，关闭工程后等待其 Provider 停止；一个
插件停止失败时，其他工作区仍必须完成自己的清理。不要把组件卸载当作工作区关闭，
也不要因为目录刷新清空了列表就忘记之前启动的进程。

代价是新增一层工作区所有者，必须保留失败清理状态，不能直接删除 Map 条目。
测试覆盖受控界面点击、取消、窗口重挂载、10,000 项仅挂载可见行、插件确认屏障、
清理失败及迟到检测。它们不替代 Windows/WebView2 实机。声明任务分组、依赖与报告
呈现、配置草稿/确认、文件观察、Run/Java/Agent 消费者和旧数据迁移尚未完成；旧 Maven
入口及共享命令继续保留，`buildSystems/buildProviders` 能力仍不开放。

### 存储、信任与安装（v0）

- 安装根为 `app_local_data_dir()/plugins/<pluginID>/<version>/`，`installation.json` 记录版本与启用状态；记录缺失或损坏的包隔离展示，绝不静默加载。
- bundled 包从 `resource_dir()/OfficialPlugins` 只读加载，多版本目录取最高版本；运行时不写安装目录与资源目录，遵守发行基线只读边界。
- 每个插件的语言服务器状态目录在 `app_local_data_dir()/plugin-state/<pluginID>/<workspace 哈希>`，由宿主注入启动计划请求。
- 信任模型 v0：官方 ID 防冒用由 Core 校验兜底；bundled 包随安装器分发；磁盘导入（已落地）与市场下载（M3+）一律走 `plugins.marketplace.installReview` 全量审批（权限 + 完整程序清单），审批界面明示"未认证发布者"。publisher Ed25519 验签明确延后，这是 v0 的已知缺口，Windows 验签方案（Authenticode 还是包内 Ed25519）单独立项评估。
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

M1 包存储 + 启动校验 + 语言注册 + LSP 启动（已落地）；M2 磁盘安装链路 + 管理界面 v1 + 死链处置（已落地）；M3 声明式设置 + 运行/测试计划 + PHP 契约包（已落地，Worker 版保留见上文）；M4 Web 工具窗口（已落地，桥 v0 只含 state/openFile/主题，build.* 与 functions.* 等 Windows 构建系统能力接入后开放）。每个里程碑独立 PR，矩阵条目随代码同 PR 更新。总体方向遵循[公共扩展契约与 Provider 接入方向](../../proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)，本 Note 只落地其中 Windows 契约宿主的第一阶段。

## 考虑过的备选方案

- 把 Worker 扩展模型整体改造成契约宿主：契约没有主题、AI provider 这些概念，改造成本高且无收益，不采用。
- 在 Tauri 侧另写一套清单校验：违反"校验只在 Core 实现一次"，共享 fixtures 无法复用，双端语义必然漂移，不采用。
- 把 Worker RPC 桥接成 litheFunctions：两者协议语义不同，会同时存在两套函数协议，等有真实插件需求时再按[插件函数契约](2026-10-20-plugin-function-contract.md)接入。
- 信任模型一步到位 publisher 签名：Windows 验签载体需要单独评估，v0 以 bundled 加全量审批兜底，签名延后是显式记录的缺口而不是遗漏。
- 在 `lsp_start` 一类原生命令里拉起插件服务器：现有 LSP 会话全部由 Core 统一管理（会话、取消、事件泵都在 Core），前端只解析可执行路径与参数；另建原生拉起路径会分裂会话所有权，不采用。

## 后果

- 收益：Windows 用户开始能安装与运行契约 v1 语言插件，语言插件包与 macOS/Lithe Store 同格式；契约验收（同组 fixtures）成为 Windows 持续回归的一部分；后续里程碑只增不改这条链路。
- 代价：双模型并存是用户可见的复杂度，管理界面必须分组。`minimumVersion`、内容摘要复查与启动前校验已接入；发行者签名仍延后，不能把完整性检查当作发布者身份验证。
- 已知风险：签名延后意味着 v0 社区包信任完全依赖审批界面（M2），文案必须明示未认证状态；Windows 的 reparse point/junction 语义与 macOS symlink 不完全相同，包内路径逃逸判断已按 Windows 语义单独测试；WebView2 对自定义 scheme 与 CSP 的实现细节与 WKWebView 有差异，`ui:2` 网页链路已用 Windows Release/WebView2 实机验证，停靠、图标、动作状态及布局仍为 partial。
- M2–M4 里程碑：磁盘/市场安装链路 + 管理界面；声明式设置 + 运行/测试计划 + PHP 契约包替换；Web 工具窗口。每个里程碑独立 PR，能力声明与矩阵条目随代码同 PR 更新。

## 验证

- Windows 原生配置写回：10 项文件事务回归与 90 项受影响前端回归通过，逐项报告保留
  私有源保护、UTF-8 BOM/Unicode、磁盘冲突和晚到取消的证据。`lithe-project` 在 macOS
  的完整 45 项计时中 44 项通过，既有 `exact_nested_pom_watch_emits_reload_without_registration_event`
  在五秒等待内没有收到 POM 事件；隔离复制写回前的 69c4dab 源码也复现相同超时，未改动
  watcher 或放宽期限。这不是整个 Windows crate 或 Windows 原生整机通过的结论。

- 多窗口事件投递必须显式指定当前产品窗口的 `Window` target。Tauri 默认 `Any` 监听也接收发给其他 label 的事件，原生 `emit_to(ownerLabel)` 本身不足以隔离接收者；文件请求与生命周期确认均绑定当前窗口，防止其他工作区误处理请求或重复确认。`plugin-lifecycle-listener.test.ts` 检查两类监听的目标。
- 2026-10-24 Windows Release 实机验收：Playwright/CDP 连接真实 WebView2，测试包安装、ui 1 文本渲染、工作区关闭重开、状态隔离、两个产品窗口归属、主题/语言与重载、过期工作区 openFile 拒绝、双窗口卸载关闭全部插件页均通过；无重复确认异常，外站 HTTP GET 为零，安装包及发行资源哈希不变，应用正常退出。该测试包不替代真实语言服务器的完整安装→启动→即时设置验收，也不覆盖停靠布局。
- 管理并发回归：`lifecycle.rs` 覆盖原生使用计数排空、禁止晚到获取、逐窗口确认、停止失败、窗口断开和有界超时；`lsp-core-adapter.test.ts` 用可控 Core 响应覆盖停止期间晚到的服务器，断言先停止再拒绝，且 `pluginId` 没有丢失。`plugin-lifecycle-listener.test.ts` 验证收到停用事件立即撤销入口、等待运行和 LSP 两方后才确认。
- Build 传输基础：`build-provider-sessions.test.ts` 和 `lsp-core-adapter.test.ts` 覆盖包/设置/运行时变化、逐目标停止、停止失败后阻止新请求、解析中取消、插件代次和工作区关闭、早于 IPC 确认的进度与回复，以及原始字段与稳定错误码。新增回归在 macOS 的 Bun 逐项计时入口通过；这不代表 Windows 原生进程、共享语言会话或产品 Maven 工作流已验收。资源复用回归明确拒绝复制新的 Windows Provider 状态。
- 领域编排：`build-provider-workspace.test.ts`、`build-core-api.test.ts` 覆盖模型到任务/依赖/报告、模型目标、原始 Java 选择器、工具及插件代次失效、参数快照、取消和晚到回复、逐目标清理失败、有界输出与历史。Maven 独立仓库的[集成脚本](https://github.com/Lithe-IDEA/lithe-plugin-maven/blob/codex/issue-1495-maven-domain/scripts/test-windows-workspace.mjs)使用宿主生产 TypeScript、当前 Core 和真实 Maven reactor，8 个步骤增加损坏 POM 下的配置读取、来源字节和探针状态清理，验证普通及模型任务、单方法、成功及失败报告和包字节不变；此 macOS/Linux lane 不等于 Windows 原生或产品 UI 验收。固定宿主 ed10dc4 / SDK 4886c90 / Maven 8c85347 的[开发 CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/41068473354)已通过当时的 7 步工作区及 Java 8 两种 Maven、Java 17 框架调试，新增配置读取是后续本地验证，不混作该组合的 CI 证据。共享工具选择 fixture 与 Core 全量逐项计时 1434 项通过，Windows Cargo 在 macOS 仅遇到项目窗口注册表既有的两个 Windows API 错误，原生测试尚未运行。
- 工作区与界面回归：`web.rs` 覆盖双工作区窗口/状态键隔离和文本转义；`plugin-lifecycle-listener.test.ts` 验证其他工作区请求、路径解析中切换工作区以及成功确认；`workspace-lifecycle.test.ts` 验证关闭工作区时清理网页。`declarative-plugin-ui.test.ts` 用 Hello Lithe fixture 验证文本窗口与命令面板、菜单、工具栏三处贡献及撤销，受控刷新同时覆盖相关与无关插件的撤销。CI 按文件分进程执行插件套件，避免原生命令和事件 mock 跨套件泄漏。
- 启动计划回归：`launch.rs` 验证必需资源缺失、运行时依赖缺失、目录资源与普通文件入口的区别，以及有输出但非零退出的校验命令。`tests.rs` 还覆盖完整扫描的有序发布，`web.rs` 用有界通道覆盖写入与撤销交错、旧页面实例和旧工作区版本拒绝。Windows Rust 最终计时运行记录 357 项，其中 354 通过、3 项夹具跳过；前端受影响测试分别在隔离进程中运行，报告保存在 `.artifacts/test-stability/`。这些测试不替代双工作区真实 WebView2、真实语言服务器与停靠界面的产品验收。

- 网页隔离与上下文回归：`web.rs` 覆盖同包和外站 URL 的导航/桥接共用检查、真实路径与内部/外部目录链接；Windows 用无需提权的 junction，Unix 用目录符号链接。`plugin-web-appearance.test.ts` 执行原生宿主桥脚本，验证语言、主题、根变量、主题事件与外站不暴露桥；前端文件测试验证原生真实目标传递与拒绝传播。
- 版本探测回归：`runtime_probe_collects_output_and_rejects_overflow`、`runtime_probe_reclaims_inherited_pipes_after_parent_exit` 使用当前测试二进制作为固定夹具；后者让父进程退出、后代保留管道，断言调用有界结束且后代已退出。测试环境变量仅附加到子进程，不改测试运行器的全局环境。运行 WindowsRust 与 Frontend 计时 harness，检查 `.artifacts/test-stability/index.html`；真实 WebView2 验证还要由本机 HTTP 计数器确认外站 GET 为零，同时检查导航、弹窗/下载、动态主题、包文件和发行目录哈希不变；单凭页面 URL 没变不能证明请求未外发。

- M4 Web 工具窗口：`plugin_host/web.rs` 测试覆盖包路径规范化（`..`、编码分隔符、空段拒绝）、CSP 内容断言（default-src none、无 wasm-unsafe-eval、frame-ancestors none）、桥脚本冻结与作用域、状态键隔离；web-panel fixture 随 `ui:[1,2]` 声明提升转为被宿主接受（能力门控测试同步）。桥 v0 的 build.*/functions.* 返回 `plugin.web.unknownMethod`，等构建系统能力接入。


- M3 设置链路：`settings_tests`（`plugin_host/tests.rs`）覆盖项目覆盖往返、其他插件条目保留、损坏 store 报错不重置；能力门控测试随声明提升更新（settings-v2 fixture 被接受）。设置编辑 UI（`declarative-plugin-settings-editor.tsx`）按声明的 scope/effect 渲染并显示值来源徽标。
- M3 运行计划：契约 PHP 包端到端测试（`bundled_php_contract_package_expands_plans`）走真实 Core 命令验证 validate、runPlan（`${file}`/`${userArguments}` 展开）、testPlan（workspace scope + 项目标记）、resolveSettings。


- M2 磁盘导入链测试（`windows/tauri/src-tauri/src/plugin_host/install_tests.rs`）：目录快照隔离（symlink 拒绝）、ZIP 解包与恶意路径（`../` 逃逸条目）拒绝、staging 安装（坏包失败保留现行版本且清空 staging）、回滚版本选择；runtime 启动的版本探测输出解析（node/java/go 真实输出格式）在 `launch.rs` 测试覆盖。
- 管理界面（`declarative-plugins-section.tsx`）挂在设置的独立一级页，`settings-hierarchy.test.tsx` 的布局断言随导航更新；i18n 提供 en-US 与 zh-CN 全套文案。


- 共享 fixtures 全量验收在 Windows 二进制内完成：`invalid-manifests.json` 全部 154 个用例经宿主校验路径断言同一稳定错误码（不带 hostCapabilities 的契约等价模式），合法样例在不带与带 v0 能力声明两种模式下分别断言通过与 `plugin.api.unsupported` 门控。测试入口：`windows/tauri/src-tauri/src/plugin_host/tests.rs`，运行 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml plugin_host`。
- 存储与启动的单测覆盖安装记录缺失/损坏隔离、bundled 最高版本选择、版本比较（含 prerelease）、扩展与文件名匹配（大小写与前导点）、packaged 路径逃逸拒绝、runtime 的 `LITHE_<TOOL>_PATH` 导出与 `PATH` 前置。
- 前端回落链路测试：`windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.test.ts` 断言契约插件启动映射与无归属文件返回 null；启动扫描步骤在 bootstrap 中执行。
- M1 尚属静态与进程内验证：真实插件包安装→启用→语言服务器拉起的全链路实机验收随 M2/M3 完成，期间矩阵 `verificationStatus` 保持 pending。`./scripts/windows/verify/verify-windows-boundaries.sh`、`./scripts/platform-feature-matrix/verify-platform-feature-matrix-change.sh <base> HEAD` 随 PR 通过。

团队文档及窗口接线的 2026-10-31 本地证据：Core 1,436 项、macOS 144 项、
Windows 前端 111 项及隔离生命周期 6 项通过；前端构建、类型检查、Rust crates 和
真实 bridge 25 项通过。团队文档四项为 6～10 毫秒。项目库共 49 项，48 项通过，
唯一 POM watcher 超时已在改动前基线复现；不将其描述成全绿。Windows Cargo
与基线相同，仅有两项 macOS 上不可用的 Windows API 错误，没有新增类型调用错误。
报告位于 `.artifacts/test-stability/stage-d-build-document-*`、`stage-d-windows-build-*`
及 `stage-d-build-lifecycle-listener.*`，这些不代替 Windows 原生验收。

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
- `Plugins/win/Official/PhpSupportContract/`（契约版 PHP bundled 包）
- `windows/tauri/src/features/plugins/declarative-plugins-section.tsx`（设置内管理页）
- `windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.ts`（契约插件回落来源）
- `windows/tauri/src/features/bootstrap/bootstrap-async.ts`（启动扫描步骤）
- `shared/platform-feature-matrix/features/declarative-plugin-contract.json`、`plugin-marketplace.json`、`plugin-extension-management.json`、`declarative-plugin-settings.json`、`php-optional-plugin.json`、`plugin-web-tool-windows.json`
