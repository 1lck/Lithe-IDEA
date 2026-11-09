# Agent 笔记：插件自有原生终端与有界重开上下文

状态：已实现

## 先说结论

Docker 等工具插件可以请求 Lithe 在现有原生终端里启动程序，插件负责可执行程序和参数，宿主负责显示、伪终端（PTY，让命令像在普通终端里运行的系统接口）和进程清理。插件只能控制自己后端会话在指定工作区创建的终端。关闭后可用同一身份重新打开，保留插件指定长度的最近显示文本，但不重放输入，也不承诺恢复旧进程或 Shell 内存状态。

## 问题

Docker 插件需要一键进入容器，但公共 API 计划中的 API-24 只有候选名称，宿主没有对应服务。只加网页按钮不能完成工作流；把 xterm.js 和 Docker exec 流塞进插件又会重复宿主已有的终端渲染、输入、缩放、窗口和退出流程。

用户进一步要求关闭后重开时带上一部分上下文，长度由插件选择。这里的上下文必须说清楚：终端显示历史可以安全地作为历史展示，自动重放历史命令却可能重复删除、部署或数据写入；一个已经结束的进程也不能靠显示历史恢复变量和前台程序状态。

## 决策

### 复用原生终端，扩展现有宿主服务

- 以函数协议 3 的 `terminal` 宿主服务新增能力，通过 `getCapabilities` 发现，不升级协议版本。不另建通信系统，也不把交互客户端伪装成 Build/Run Provider。
- 新权限 `terminal.create` 展开成具体方法授权，要求 `backend:2`。Web 页面调用插件自己的函数，后端拿本次调用的工作区上下文请求宿主；不从全局焦点猜窗口。
- `PluginTerminalHostService` 负责句柄、权限之后的归属检查、参数预算和生命周期。`AppModel+PluginTerminal` 把请求适配到既有 `TerminalFeatureModel`；`MacTerminalTransport` 继续拥有实际 PTY 和渲染。
- 启动参数保持 executable/argv 分离，cwd 是工作区目录资源；原生层校验 canonical cwd 不越界。执行前显示可取消确认，等待期间切工作区、停用插件或取消都不能继续启动。
- 执行确认把完整程序、参数数组和工作目录放入只读的原生文本视口，支持滚动、选择与复制；用 JSON 转义区分参数边界和控制字符。不能把执行详情塞进限制八行的普通通知正文，否则长参数会遮住后续参数和目录。文本布局与可见字形绘制由 TextKit 负责，不随滚动重建全量控件。
- `show:false` 在创建与重开时都保留原有活动终端，不挂载标签、不显示面板或请求输入焦点；后续显式 show 才注册标签并选择新终端。否则仅有编辑器区域终端时，工具区域会把新标签当成默认显示项。终端模块创建入口显式接收选择选项，不依赖创建后再切回旧标签。
- 首版仅本机 macOS。远程 authority 显式拒绝，Windows 未注册 handler，也不宣传已经支持。SDK 的 Node、Java、Rust 封装保留能力发现与旧宿主不可用语义。

### 终端身份与资源寿命

每个句柄归属 pluginID、backend sessionID 和 context generation；操作其他插件、旧会话或其他工作区的句柄返回不存在。八个句柄的配额包括已经关闭但仍可重开的句柄，插件用 `dispose` 明确释放；不能无限累积历史和启动配置。

`close` 结束该进程会话并移除原生标签，保留启动配置及有限历史；`reopen` 先确认，再启动新的 PTY，沿用 terminalID 并增加进程 generation。退出订阅每个 generation 只发布一次，旧原生回调不能结束新进程；正在 close/reopen 时再次变更返回 busy。用户关闭标签或程序自然退出同样可以重开。

用户关闭标签与自然退出也要经过有界原生清理、按预算截取历史并释放整个终端会话和渲染缓冲区，不能只从界面移除标签。清理期间句柄保持 busy；清理结束后才发布该 generation 的退出通知，收到通知后可立即重开。`retainedContextBytes:0` 在这两条路径同样不保留显示历史；无需等待插件再调用 close 或 reopen 才释放。

用户关标签已发起 stop 后，退出收尾仍会调用 stopAndWait 等待其清理，所以子进程回收器必须按 PID 复用同一观察源。重复登记只追加完成回调；不要先创建一个 DispatchSource 再判断是否重复，未激活的重复源被释放时会让 libdispatch 直接终止应用。原生 PTY 的用户关标签回归覆盖这条真实重复调用链。

后端结束、插件禁用/更新和工作区关闭，释放所属句柄并通过既有有界原生清理结束其进程。独立用户终端不参与这张表。网页关闭只取消在途调用，不结束已经交付给用户的终端。

### 上下文只恢复显示，不恢复执行

- 插件以 UTF-8 字节数配置 `retainedContextBytes`，默认 16 KiB，上限 256 KiB，0 表示不保留；close 可覆盖创建时的选择。总上限受八个句柄配额约束。
- 只在关闭/重开边界从成熟 SwiftTerm 渲染缓冲区取后缀，不在每个输出字节上维护第二份日志。先二分定位缓冲区末端，只翻译满足字节预算的末尾行，避免为少量上下文测量整篇历史。
- 历史变成去控制字符的纯显示文本，按 Unicode scalar 边界截断；启动前喂给显示器，不能写新 PTY 的 stdin。颜色、TUI 控制状态和进程内变量不恢复。
- 历史和启动环境只放当前宿主内存，不写 bundle、插件目录、缓存或持久状态，不影响代码签名和 Sparkle delta 基线。已由程序显示/回显的秘密可能仍在快照中，插件可选择 0；宿主不读取其他终端。

正确做法：Docker 插件声明明确连接和容器 ID，调用通用终端服务启动 CLI；关闭后重开显示最近输出，再获得一个新容器 Shell。另一个插件启动数据库交互客户端也用相同接口。

不要这样做：宿主判断工具名为 docker 时拼参数、往用户正在编辑的终端输入命令，或重开时自动执行保留输出里的命令文本。

## 考虑过的备选方案

- 插件内嵌 xterm.js 与私有 exec 传输：会重复原生终端和生命周期，且用户明确要求使用 Lithe 终端，拒绝。
- 创建普通 Shell 后 sendText：增加 Shell quoting、提示符准备竞态及忙碌终端误注入风险，首版只直接 argv 启动。
- 把 close 当隐藏、让进程继续运行：与终端关闭含义不符，也让插件禁用后的资源处理含糊，拒绝；如未来需要 detach，必须单独定义能力。
- 保留原始 ANSI 流并回放：可能触发 OSC 标题/链接及设备查询，还要维护第二份输出缓存，采用成熟终端缓冲区的纯文本后缀。
- 持久化所有历史并跨重启恢复：带来秘密持久化与进程身份恢复问题，首版限定当前后端会话和工作区内存寿命。

## 后果

工具插件能复用 Lithe 的完整原生终端，跨工具无特判，并通过 close/reopen 少做手动 Shell 操作。代价是首版没有读取终端输出、注入输入或恢复旧进程状态的公共 API；重开会重新执行原始启动 argv，必须再次确认，插件应为交互会话提供适合重复启动的入口。SDK 封装在独立仓库维护，契约副本仍须在主仓库合并后由同步工具导出，不能手改镜像。

## 验证

- ~~scripts/macos/test/test-macos.sh --filter 'PluginTerminalHostServiceTests|PluginTerminalNativeTests|TerminalModuleTests'~~（随旧客户端移除）：隔离、未知字段、remote 拒绝、关闭工作区期间的在途创建、退出去重、generation、历史后缀及真实 PTY 输入不重放；后台创建/重开保留已有选择，用户关标签和自然退出按 0/8 字节预算释放原生缓冲区，长参数完整进入原生可选择视口且取消不启动进程。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib plugin_function` 和 `--lib terminal_permission`：逐方法授权与旧协议拒绝。
- ~~scripts/architecture/verify-service-boundaries.sh~~（脚本已随旧客户端移除）、~~scripts/architecture/verify-shared-contracts.sh~~（随旧客户端移除）、`scripts/macos/verify/verify-runtime-bundle-immutability.sh`。
- `scripts/agent-notes/verify-agent-notes.sh`、`scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

原生 PTY 集成测试不替代用户在安装插件中的完整点击、滚动、窗口焦点和退出验收；功能矩阵的待验收状态按真实证据维护。

## 适用范围

- ~~`macos/Sources/Lithe/Application/Features/PluginTerminalHostService.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Models/AppModel/AppModel+PluginTerminal.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/LitheTerminalModule/`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Platform/MacOS/Terminal/MacTerminalTransport.swift`~~（已随 #1794 移除）
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/plugin_function.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/plugin_function.rs)
- `shared/contracts/plugins/v1/`
- `docs/development/macos-plugin-api-plan.md`
