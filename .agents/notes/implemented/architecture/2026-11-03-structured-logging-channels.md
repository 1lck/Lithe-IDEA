# Agent 笔记：结构化日志通道与事件目录

状态：已实现

## 先说结论

日志接入以共享事件目录声明事实，由生成的类型约束字段；Core 负责通道、单行格式、查询和保留计划，平台负责实际文件操作。PR2 已把 macOS 生产写入器（负责排队和写盘的组件）与宿主调用点接到 v2；Windows 继续使用 v1。macOS 升级前的 v1 文件不显示、不解析，只参与保留计划并按 30 天自然过期。PR3 已在 Core 实现角色通道、上游诊断、有界日志队列与插件目录，并接入 macOS 统一写入器和诊断开关。后续接入必须使用已校验的身份生成通道，不能把显示名称或用户输入变成目录。

## 问题

旧链路有五类问题：直接使用系统日志或标准错误输出会漏收；字符串调用没有共同的事件与字段规范；自由文本格式无法作为可靠解析契约；设置页时间线与语言服务内存日志是两个不同证据源；逐事件跨语言调用、过滤前编码及反复打开文件增加开销。

旧 Note 用固定分类加范围标签（scope，用来细分功能的字符串）限制目录数量，阻止任意调用方字符串进入路径。这保护了路径安全，却不能自然表达语言服务器、版本控制提供者和插件各自的日志，也无法给插件原生日志一个会话内的独立位置。

## 决策

### 取代范围与阶段边界

本 Note **部分取代** [双端模块日志与诊断快照](2026-10-20-modular-application-logging.md) 中固定分类目录、scope 作为主要细分方式和 v1 记录格式的设计决定。旧 Note 的脱敏、导出冻结、平台 I/O 所有权及未迁移的 Windows 行为继续有效；它没有被完全取代，不移入 archived。

PR1 已实现的是纯计算规则、共享事件目录、Swift 事件类型与 span、Rust 静态元数据、生成器、用法检查及存量基线。span 是同一次操作的计时记录，成功或失败只提交一个终态。四个 v2 命令是显式调用才生效的新入口；v1 公开项和 dispatcher 命令继续兼容。字段目录校验与通用批量编码是独立能力，不能因为编码器可接收标量就绕过事件目录。

macOS 的宿主调用点、类型化写入与诊断收集已落地。PR4 的日志窗口与导出决策见 [应用级日志窗口与诊断导出](../feature/2026-11-03-structured-logging-log-window.md)。组件验证不能替代真实产品工作流验收，Windows 未迁移。

### 宿主依赖与操作所有权

组合根创建一个进程拥有的 `MacLogStore`，通过 `AppServices.logSink`、服务构造器和 `ModuleContext.logSink` 传入相同的 `LogSink`。`LogScope` 保存同一操作的 `operationID` 和可信身份；生成事件仍决定通道，scope 不能改写路由。成对操作由一个调用方持有生成 span，开始使用单调时钟，成功或失败只提交一次终态。

不要新增全局可变日志单例：这会隐藏依赖、混淆测试与退出所有权，并让多个项目各自的生命周期影响进程日志。现有启动环境与进程适配器早于 writer 创建，最多保留八条类型化事实，之后由应用注入 sink 并排空；不把错误改成自由字符串，不为早期调用另建 writer。

正确做法：把 sink 作为构造器参数传入服务，在拥有恢复或告知用户决定的边界 emit。不要这样做：底层打印错误后抛出，再让每层重复打印；也不要把命令输出、环境变量值、源码或协议 detail 塞进 error/text。Core 在已有 log 事件的 error 组件中附加维护告警分类；LSP 的拥有者通过独立结构化回调传递 WARN/ERROR 的阶段、受控错误分类和进程退出码，不在组合根从自由文本猜错误。Git 命令与请求各自保留真实失败终态，Core 字符串错误码通过 LogFailure 保存为 error_code，并与进程退出码分别保存；更新下载保留已有失败枚举与 HTTP 状态。freeze 的失败和成功都保留相同计数、屏障状态及完成时 native revision，不记录正文。

### 入队、批量和资源上限

`emit` 只在短锁内按级别和详细诊断分类快照过滤、入队；默认关闭 DEBUG，详细诊断持续 15 分钟。队列最多 8000 条，普通级别最多使用 6000 条，剩余 2000 条留给 WARN/ERROR；过载累计 `log.dropped`，不在调用线程执行 I/O。每 100 ms 或达到 256 条时交给 Core 批量目录校验、脱敏和编码。

单一串行 I/O 队列拥有序号、会话文件、目录切换和保留执行。句柄最多 32 个，按最近使用次序淘汰；Core 以事件身份、字段、op 和通道的结构哈希合并相邻重复，跨批携带上一条输入，不逐条序列化判重。广播仅包含已编码证据，最近窗口上限为 2000 条或 2 MiB；最多 16 个订阅者，每个订阅缓存最多八批，窗口关闭必须取消订阅任务。

控制操作最多同时接纳四项，串行执行。每项持有包含取消状态和单调截止时间的操作令牌；开始前检查，查询、目录切换和发布控制结果前再次检查。已接纳日志的一次有界 drain（排空快照）由进程 I/O 队列拥有，独立于控制操作取消，必须写完该快照及丢弃汇总后才报告控制超时，不能让取消丢掉后缀。原生同步文件操作无法中途撤销，截止时间不是强制中断磁盘 I/O 的时限；调用方只在队列停止修改后恢复。退出使用独立接纳路径，先停止接纳，无论 drain 成功或失败都在队列上关闭句柄、结束订阅；任务取消或四个普通控制已占满不能跳过清理。

### 收集预算与文件替换恢复

原生枚举只提供路径、长度和修改时间，Core 先做分类和会话筛选，再分配 200 个文件、单文件 2 MiB、总计 10 MiB 的读取预算。相同会话先读所有活动文件，再读轮转 1、轮转 2；同层按修改时间从新到旧，最后按路径稳定排序。不能按文件名字倒序分配预算，否则 `z~2.log` 会挤掉仍在写入的 `a.log`。通道根到现有六类设置筛选的映射也由 Core 持有，update、remote、agent 继续出现在 Application，terminal 与 debug 进入 Run；详细诊断使用同一映射。

缓存句柄每次写入前比较原生设备号与 inode（文件在磁盘上的身份）、链接数及文件长度。路径被删除、原子替换或截断时，关闭旧句柄，重新建立文件头并打开活动路径；不可写时使用既有默认目录回退。不能只检查路径存在：原子替换后路径还在，旧句柄仍会悄悄写入失去路径的旧文件。

### macOS 只收集 v2

设置时间线和诊断导出只读取 `sessions/` 下的 v2 文件，未安装 collector 时仅导出系统快照。旧 `<category>/lithe.*.log` 和根目录 `lithe.log` 不显示、不解析、不改写，也不迁移到新会话。文件清单仍交给 Core 保留计划，旧文件只按年龄删除，不能因总量压力提前删除。Rust 的 v1 公开 API、旧 dispatcher 命令及共享只读兼容查询能力保持不变，供 Windows 等现有消费者使用。

### 按会话组织，以受控通道决定相对路径

会话是一次应用进程运行。Core 从宿主传入的开始时间和完整 UUID（会话唯一编号）生成 `sessions/YYYY-MM-DDTHH-MM-SS_<8位小写十六进制>/`，不读取时钟或文件系统。

通道是“固定根 + 已校验 ID 段”，不是自由路径。根的封闭集合及段语法以 `shared/logging/README.md` 和共享 Core 契约为准；通道支持根、非插件根/段及插件宿主的 `plugins/<id>/host`。Core 生成如 `app.log`、`vcs/git.log` 和 `plugins/<id>/host.log` 的会话相对路径。轮转文件使用 `git~1.log`，分隔符 `~` 不属于通道字符集，避免合法 ID `git.1` 的活动日志与 `git` 的轮转相互覆盖。段还拒绝末尾点号和 Windows 设备名，使同一身份在双端都能安全落盘。每会话接纳最多 128 个通道，新超额通道映射到会话根的 `_overflow.log`，已经接纳的通道保留路径。溢出文件的头使用 `_overflow`，轮转沿用相同规则，超额通道也受单文件预算约束。

这里明确推翻“调用方字符串不进目录”的绝对限制，改成“只有来自已校验插件、provider、server 或内部连接身份的 ID 才能进入目录”。理由是这些身份有明确所有者、稳定格式和数量预算，可以同时表达证据来源与插件隔离；任意 scope、主机名、显示名称和用户文本仍不能进入目录。语法校验只证明字符安全，调用方还必须证明 ID 的真实来源。

正确做法：从已验证的 provider 身份得到 `vcs/git`，交给 Core 解析相对路径。不要这样做：把远程主机名、项目路径或命令行作为段名，即便它碰巧通过字符校验。

平台将相对路径连接到实际生效的可写日志根，负责防止原生路径和符号链接越界；不得连接到 app bundle 或安装目录。日志是用户运行状态，不参与签名和 Sparkle 增量基线，不得跨 worktree 复制。PR1 类型和生成物没有运行时文件操作。

### 单行格式是契约，重复身份放文件头

每个 v2 文件的第一行表示会话、进程、应用版本、通道和开始时间；记录行只保留每条变化的事实。例如：

```text
#lithe-log v2 session=12345678-1234-1234-1234-123456789abc pid=5123 app=0.42.0 channel=vcs/git started=2026-11-03T08:00:00.000Z
2026-11-03T08:00:01.123Z ERROR seq=42 event=vcs.git.command.failed op=7f3a msg="Git fetch failed" command=fetch duration_ms=311 error="fetch failed" error_code=128 error_domain=git provider=git
```

时间统一为 UTC 毫秒；级别封闭为 DEBUG、INFO、WARN、ERROR；顺序为时间、级别、`seq`、`event`、可选 `op`、`msg`，其余字段按键排序。`seq` 是宿主分配的会话内单调序号，不补零；无状态编码器不能证明跨批次单调性。`op` 是操作关联身份，不是事件字段或路径段。

编码器和查询复用结构化字段脱敏，先检查完整字段名（包括 `client_secret`、`auth_token` 等前缀形式），再处理文本；不能只把字段拼成字符串后依赖文本正则的单词边界。编码器负责转义与 8 KiB 单行预算，换行只作为转义值存在。超长优先缩短上下文字段，再缩短消息，并标记 `truncated=1`；身份与键开销仍无法容纳时返回错误，不能悄悄删键。重复聚合与队列丢弃采用普通 `log.repeated`、`log.dropped` 事件。精确语法、错误码及边界由 `shared/contracts/rust-core-api.md` 和 `shared/fixtures/diagnostics/logging-v2.json` 持有，不在 Note 中另建字段手册。

### 事件目录与生成类型约束接入

`shared/logging/events/` 是事件声明的唯一来源，声明真实来源、级别、通道、英文事实模板、字段含义、owner（维护模块）和限流元数据。无真实来源的根保持空目录，不预造事件。事件消息供诊断使用；面向用户的界面文案仍走共享 i18n。

生成器输出 `LogEvents.generated.swift` 和 `catalog_generated.rs`。Swift 事件输入尚未脱敏，不能自行序列化落盘；Rust 静态表提供事件查找和字段形状校验，不分配运行时目录缓存。macOS 宿主已连接目录校验、共享脱敏与编码，不能把“生成类型”误当作已经安全的文本。Core 对 error/text 原始输入先脱敏、去控制字符、按 UTF-8 边界截断至 1 KiB，再严格校验字段；不得在 Swift 重写隐私规则或放宽 validate_fields。日志身份转换不得影响插件资源是否加载；语言 ID 与通道段并非同一集合，c++ 及超长合法语言 ID 都必须继续加载。浏览器返回的语法加载失败同样始终记录插件事件，语言使用有界的可选 version 字段，不能因 LogSegment 拒绝它就丢掉整条失败。

新增或迁移调用先修改事件 JSON，再生成并使用类型化事件；不手写任意消息、级别或字段字典绕过目录。具体操作规范见 develop-lithe 的日志接入 reference，声明规则唯一来源为 `shared/logging/README.md`。

用法门禁按文件和规则核对旧调用的精确计数。基线只减不增，迁移后必须删除对应存量计数，不能换位置藏违规；永久例外另有明确架构理由与精确计数。该检查覆盖已列出的直接写法，不是跨文件别名分析，也不能代替人工审查。目录中的 rate 只是元数据，PR1 不执行运行时限流。

### PR3：由引擎声明身份，macOS 接入统一写入器

同一个引擎承载语言服务、版本控制、构建、工具链和插件后端，provider ID（提供者身份）可能含冒号，不能直接成为目录段。宿主显式传 `role` 和 VCS 的 `logSubject`，Core 校验身份并选择目录事件族：语言服务用 `lsp.*`，VCS 用 `vcs.*`，其他插件进程用 `plugins.host.*`。目录模板和必填身份字段仍唯一决定通道，不扩大 schema 允许任意 channel。旧宿主不传 role 时继续按语言服务处理。macOS 各启动者显式传角色和插件 ID，VCS 传真实 target.vcs；远程语言会话仍属于 language_server。启动响应返回 Core 生成的 channel，宿主用它登记详细诊断 I/O。

合法语言 ID 不等于合法路径段。遇到非法段或缺少身份时，Core 用原始身份的 SHA-256 前 32 位小写十六进制加 `invalid-` 前缀；缺值时哈希完整 provider ID。这样不会阻断进程启动或静默丢日志，也不把原文泄漏成目录。正确做法是 VCS 宿主从已注册目录传 `role:vcs, logSubject:git`；不要拆 `vcsProvider:<plugin>:<vcs>` 猜身份。

引擎在日志源头选择封闭的事实类型，既有英文 message/detail/error 留作 v1 兼容；v2 使用目录 ID 和标量字段，经过同一个 Core 目录规范化、脱敏与通道推导边界。stderr 的读取状态最多保留 4 KiB 半行，按 LF 切分、去末尾 CR、忽略空行并冲刷 EOF 残余；每单调秒接纳 200 行，后续读取跨窗或结束时汇总丢弃计数。测试直接传毫秒值，不装计时器、不等真实一秒。text 落盘前仍执行 1 KiB 规范化。

`window/logMessage` 与 `window/showMessage` 复用结果词为过去时的 `*.message.logged/shown`；其他通知只记录方法，不把协议正文变成 text。trace 默认关闭，显式开关与发往上游的 `$/setTrace` 共用有序写锁，成功写入后才改变采集状态；message 和 verbose 合并后限长并脱敏。macOS 已删除消息字符串匹配和重复 session 状态事实，按目录元数据取 v2 级别。带 Core 记录的 log 不再触发重复 onLogIssue，宿主自身启动/发现/请求失败仍走既有错误边界。

Core 拥有会话生命周期状态。`*.session.updated` 直接附到已有 `type:stateChanged` 事件，复用 `enqueue_runtime_event` 内同一个 `prepare_catalog_event` 校验，不额外推送 v1 log 行，也不改 type/state/message 等兼容字段。Swift 在 switch 前对任何带 coreLog 的事件转发一次，manager 清除 UI 身份后仍把退休会话的最终 Core 事实交给 sink，不套用 UI 过期回调检查；VCS、构建、工具链和后端会话同样收到生命周期事实。不要通过新增 log 行补证据，否则 Windows frontendTrace 与 macOS 100 条缓冲都会改变。

宿主只拥有启动编排阶段，在实际调用点发 `lsp.session.stage_changed`（requested/resolving/registered/stopping/cancelled）和 `lsp.cache.cleaned`（removed 计数），由 manager 的注入 LogSink 接收。两者选 DEBUG，因为描述内部阶段和维护信息；缓存清理不是 Core 配置键清理，不能复用 configuration.cleaned。ready/terminated 已由 Core protocol.initialized 与 session.updated 表达，宿主继续保留原 v1 行但不重复发 v2。

启动前的宿主事实也必须落到同一通道。正确做法是调用纯命令 `diagnostics.resolveEngineLogSubject`，Core 直接复用启动的 SessionLogIdentity；不要让 Swift 再实现哈希或自行用 providerID 构造段。manager 按 providerID 缓存成功或失败（最多 128 项，满时清空），阶段、缓存、degradation/issue 都使用该段；解析失败仅不发该宿主 v2 事件，保留既有启动与缓冲行为。参数错误沿用 invalid_request。

六处非 LSP 直接打印改为进程级 Core 队列：只接纳 owner 为 lithe-core 的目录事实，入队前规范化，最多 256 条，重复待取事实与超额计数，由宿主一次 drain 取走并重置。队列没有文件 writer、后台任务或独立持久化；遍历只记相对路径和稳定错误类别，远程清理只记类别，不记录地址、scratch 名称或输出。现有请求事件流只覆盖单个请求，无法覆盖析构和后台清理，因此选择独立有界 handoff（交给宿主写入的内存队列）。

`${logDir}` 从启动上下文的绝对 `logDirectory` 展开，共用语言服务与后端启动路径；宿主创建当前应用会话的插件 files 目录。Core 只拼接文本，不创建目录，不从插件安装位置推导可写位置。这些文件属于运行状态，不跨 worktree 复用，不改变签名或 Sparkle delta 源基线。macOS 当前日志会话目录由统一存储器提供，Core plugin_files_path 决定相对部分。平台以 mkdirat/openat/O_NOFOLLOW 逐段创建 0700 目录并拒绝符号链接，避免检查与创建之间被换成越界链接。存储不可用时省略路径；使用变量的模板由 Core 按既有 invalidRequest 拒绝。远程进程无法写本机日志目录，同样省略并拒绝该变量。安装阶段只用未创建的占位目录校验展开。静态只读边界验证与组件测试不等于真实应用 bundle hash smoke。

### 保留以完整会话为主，Core 只计算删除计划

年龄和总量策略按完整会话删除，先过期再从最老会话释放空间。当前会话及其所有文件始终受保护，预算可能暂时无法满足。单通道轮转以 10 MiB 为阈值，共保留三段（含活动文件）；Core 用 `~N.log` 生成轮转名，例如 `vcs/git~1.log`、`vcs/git~2.log`，活动文件仍为 `vcs/git.log`。`~` 不属于任何合法通道段，因此 `lsp/foo.1.log` 永远是 `lsp/foo.1` 的活动文件；查询和性能保留分类同时使用新命名，不能再剥掉点号数字后缀。实际轮转由平台执行。

保留计划的默认值是 30 天、总量 100 MiB、性能 20 MiB、每插件每会话 files 20 MiB。性能预算可删除非活动会话内的性能文件；插件超额返回告警，只有启动清理允许删除非活动会话中最老的插件文件。这两项是完整会话删除之外的明确例外；告警去重由后续宿主负责。

旧 `<category>/lithe.*.log` 不迁移、不改写。共享查询 API 保留 v1 只读能力，但 macOS 不向它提供 v1 输入；旧文件计入总量但仅按年龄删除，不因总量压力提前清理。Core 接收平台采集的文件清单和显式时间，返回相对路径计划；平台执行并报告真实 I/O 结果，不能把计划当成删除成功。

### PR3 的兼容输入与 macOS I/O

v1 的 detail/message/level 是兼容边界，必须保持原字节：例如 projectCount=N、navigation 的 format 文本和通知的原 JSON。EngineLogInput 另外携带源头字段，fact 不再解析 detail。stderr 是唯一明确行为变化：按 LF 切行、去尾部 CR，v1 detail 保留该行文本及空格；v2 再脱敏与限长。新增 dropped 只用 count=N，不以 JSON 冒充旧结构化 detail。

Core 的目录遍历和 scratch 清理复用 PR1 已声明的 app.search.directory_skipped、app.workspace.directory_skipped 和 app.workspace.scratch_cleanup_failed；error 只含固定消息、稳定类别与固定 domain，不含绝对路径、scratch 名或远程地址。删除重复 app.project.directory_skipped、remote.scratch.cleanup_failed。remote process/upload 按 ClientError 变体映射 timeout、closed、transport、spawn、protocol 或 remote_<协议码>，不保留正文。

CoreLogRecord 只接受标量，保留 event、目录 level、channel、op 和源 ts。LogSink 的 MacLogStore、LogScope 和测试 TypedLogRecorder 三个实现均支持它。MacLogStore 在原 drain/flush/finishSession 节奏批量调用一次 drainCoreEvents，由同一个 writer 分配 seq 并 validateCatalog:true；丢弃汇总转为 app 的 log.dropped，不增加空闲轮询或独立 writer。

详细诊断不在宿主另写分类：会话通道根按 Core `diagnostics.resolveLogChannel` 返回的 category 归入当前开关（lsp→language、vcs→git、plugins→plugins），与持久化 DEBUG 的准入共用 `diagnosticRoots`。当前类别开关、新会话注册和 15 分钟单次到期向活动会话发送 setDetailedDiagnostics，退出时关闭。相同失败状态只记录一次 app.logging.diagnostics_failed，避免 drain→失败日志→drain 循环；改变目标状态允许重试。

Core 记录直接进入磁盘通道。PR3 曾为旧的语言服务日志视图保留 100 条 v1 内存缓冲，PR4 用日志窗口替换该视图时已一并删除；现在语言服务日志只有磁盘通道这一个来源。

## 考虑过的备选方案

- JSON Lines：通用解析方便，但每行重复键名和身份信息、手工阅读噪声较多。采用有严格语法与 fixture 的单行文本，代价是维护专门编解码器。
- 平铺文件加 scope：不能同时自然表达会话保留和插件证据边界；继续允许自由 scope 还会保留字符串接入问题。
- 手写字符串 API：字段、级别和事件身份只能靠约定，编译器不能发现漂移，因此改用共享声明和生成类型。
- 每插件自带宿主 writer：线程、队列、脱敏和预算会分裂。插件原生文件只能进入宿主管理的独立 files 区。
- 在编辑器标签页查看日志：会将应用级证据绑定到项目，并延续语言服务内存与磁盘两份来源；PR4 改为应用级日志窗口。
- 现在删除 v1：会破坏仍直接使用旧 Rust API 的 Windows。保留兼容入口，迁移完成后再单独评估删除。

## 后果

收益是路径、格式、查询和删除选择可独立验证，事件身份与字段可以在生成阶段审查；新能力为批量跨语言调用与统一证据源提供基础。代价是需要维护生成器、专用语法和迁移基线，macOS 通过提前过滤、批量调用与句柄复用减少边界和磁盘开销；真实应用性能仍需要独立工作流证据。平台仍需承担有界队列、时间和序号、文件句柄、真实 I/O 失败、告警去重以及导出冻结的责任。

## 验证

阶段 C 的 Rust 回归用例 `lifecycle_catalog_identity_preserves_v1_event_without_extra_log` 在修复前因额外 log 行失败，修复后覆盖五角色身份与 v1 wire 字段不变；`diagnostics_resolve_engine_subject_matches_startup_and_rejects_invalid_arguments` 覆盖非法段与通用参数错误。Swift 用 TypedLogRecorder 验证阶段各一次、不重复 ready/terminated、失败缓存和真实 Core 的 c++ 通道；本轮按任务要求只编译生产与测试目标，测试执行交由沙箱外。

以下是复验入口，不是整机验收通过的声明：

- `node scripts/logging/generate-log-events.mjs --check`
- `node scripts/logging/verify-log-usage.mjs`
- `node --test --test-timeout=60000 scripts/logging/test-log-events.mjs`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core diagnostics`
- `./scripts/rust-core/verify-rust-core-comments.sh`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/windows/verify/verify-windows-boundaries.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

fixture 覆盖往返、转义、非法输入、路径段、轮转与保留、共享旧日志兼容、macOS 排除 v1 与按龄清理、查询不完整性。`--check` 只读比较生成物，不能用重新生成掩盖声明或生成器错误；Windows 边界脚本通过也不能代替 Windows Rust 编译。

## 适用范围

- `rust/lithe-core/src/diagnostics/`
- `shared/logging/`
- `scripts/logging/`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/diagnostics/logging-v2.json`
- `macos/Sources/LitheModuleAPI/Logging/`
- `macos/Sources/Lithe/Platform/MacOS/Logging/`
- `macos/Tests/LitheTests/MacLogStoreTests.swift`
