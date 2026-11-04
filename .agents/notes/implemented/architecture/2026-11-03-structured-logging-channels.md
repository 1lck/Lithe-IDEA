# Agent 笔记：结构化日志通道与事件目录

状态：已实现

## 先说结论

日志的每一种事实都先在共享事件目录里声明，再由生成的类型约束字段。Core 负责通道、单行格式、脱敏、查询和保留计划，平台只负责实际文件操作。macOS 全部写入 v2 会话文件，Windows 继续使用 v1。排查问题时，维护者能顺着同一个 op（操作关联身份）看到三层轨迹：用户按了什么，Core 执行了哪个请求，以及 Git 命令带着哪些已脱敏参数、怎样结束。没有插件进程的声明式插件，由实际执行声明工作的宿主或 Core 按一张贡献映射表，代写与 SDK 插件相同的插件操作事实。

## 问题

旧链路有五类问题：

- 直接使用系统日志或标准错误输出，日志会漏收。
- 字符串调用没有共同的事件与字段规范。
- 自由文本格式不能作为可靠的解析契约。
- 设置页时间线和语言服务内存日志是两个不同的证据源。
- 逐事件跨语言调用、在过滤之前编码，以及反复打开文件，都增加开销。

旧 Note 用固定分类加范围标签（scope，用来细分功能的字符串）限制目录数量，阻止任意调用方字符串进入路径。这保护了路径安全，但不能自然表达语言服务器、版本控制提供者和插件各自的日志，也无法给插件原生日志一个会话内的独立位置。

v2 第一版接入后还有一个缺口：日志只记录了宿主认为值得记录的结果，看不到用户按了哪个按钮、按钮背后调用了哪个 Core 请求、实际运行了哪条 Git 命令。Git 的生命周期日志写在 Swift 层，只覆盖部分操作，也不知道 Core 实际传给进程的参数和 stderr。Bug 报告里常见的“点了 Fetch 没反应”因此无法从日志定位。

## 决策

### 取代范围

本 Note **部分取代** [双端模块日志与诊断快照](2026-10-20-modular-application-logging.md) 中三项设计：固定分类目录、以 scope 作为主要细分方式，以及 v1 记录格式。旧 Note 中的脱敏、导出冻结、平台 I/O 所有权和 Windows 的现有行为继续有效。它没有被完全取代，因此不移入 archived。日志窗口与诊断导出的决策见 [应用级日志窗口与诊断导出](../feature/2026-11-03-structured-logging-log-window.md)。

Rust 的 v1 公开 API、旧 dispatcher 命令和共享的只读兼容查询继续保留，供 Windows 使用。v2 命令都要显式调用才生效。字段目录校验和通用批量编码是两项独立能力：编码器能接收标量，不等于可以绕过事件目录。

### 宿主依赖与操作所有权

组合根（负责组装依赖的地方）创建进程唯一的 `MacLogStore`，再通过 `AppServices.logSink`、服务构造器和 `ModuleContext.logSink` 传入同一个 `LogSink`。`LogScope` 保存同一操作的 `operationID` 和可信身份。生成的事件决定通道，scope 不能改写路由。成对的操作由一个调用方持有生成的 span（同一次操作的计时记录）：开始时取单调时钟，成功或失败只提交一次终态。

不要新增全局可变的日志单例。单例会隐藏依赖，混淆测试和退出时的所有权，还会让多个项目各自的生命周期影响进程日志。启动环境和进程适配器的创建早于 writer，它们最多先保留八条类型化事实，等应用注入 sink 后再交出。不要为此把错误改成自由字符串，也不要为早期调用另建 writer。

唯一的例外是 `UserActionTrace.applicationSink`。用户入口散布在菜单、命令面板和插件动作里，许多入口拿不到服务对象。组合根在创建 `MacLogStore` 时设置一次这个只在主线程访问的引用，测试可以给每次调用显式传入 sink。

正确做法：把 sink 作为构造器参数传入服务，在拥有恢复决定或告知用户的边界 emit。不要这样做：底层打印错误后抛出，每一层再重复打印；也不要把 stdout、环境变量值、源码或协议 detail 塞进 error 或 text 字段。

各类失败的结构化来源如下：

- Core 在已有 log 事件的 error 组件里附加维护告警分类。
- LSP 的拥有者通过独立的结构化回调传递 WARN 或 ERROR 的阶段、受控错误分类和进程退出码。组合根不从自由文本猜错误。
- Git 命令和 Core 请求的失败由 Core 轨迹记录：Core 错误码保存为 `error_code`，进程退出码保存为 `exit_code`，两者不合并。
- 更新下载保留已有的失败枚举和 HTTP 状态。
- freeze 无论成功或失败，都保留相同的计数、屏障状态和完成时的 native revision，不记录正文。

### 执行轨迹分三层，由同一个 op 串起来

| 层 | 事件 | 记录位置 |
| --- | --- | --- |
| 用户操作 | `app.action.performed` | 最外层 UI 入口的 `UserActionTrace` |
| Core 请求 | `app.core.request.*` | Core 请求分发处，实现在 `diagnostics/request_trace.rs` |
| 外部进程 | `vcs.git.command.*` | Core 的 Git 进程执行点，实现在 `git/command_trace.rs` |

**用户操作。** 每个用户入口在最外层调用 `UserActionTrace.run` 或 `UserActionTrace.action`。它记录一条 INFO，并把操作 id、surface、op 和开始时间绑定到 `UserActionContext.current`。嵌套调用不记录也不重新绑定，所以共用的模型方法可以再包一层，外层 id 生效。id 是稳定的 catalog token，例如 `workspace.remote.test`、`vcs.git.fetch`、`menu:<i18n 键的 slug>`，不能使用本地化标题或用户内容。

**跨越异步边界。** `Task {}` 继承当前操作，`Task.detached` 和 GCD 不继承，因此用 `UserActionContext.detached` 和 `UserActionContext.mainAsync` 显式携带。桥接层的 `RustCoreBridge.RequestOrigin.resolve` 把当前操作转成请求的可选 `origin {source, trigger, operation}`。操作开始超过 60 秒后不再声称 `source: user`，但保留 `trigger` 和 `operation`。这样运行会话之类长期存在的后续请求仍能关联到最初的点击，又不会被当成用户正在等待的工作记成 INFO。

**Core 请求。** Core 在 `runtime/dispatcher.rs` 分发每个请求时，把 op 和来源放进线程局部上下文，并在请求结束时记录唯一的终态。op 依次取 `origin.operation`、请求的 `operationId` 和请求 `id`。领域代码不再为“请求开始”“请求完成”另加日志，因此工作区、插件、运行和构建按钮背后的调用都有记录，不需要逐个调用点接入。按键、每帧、轮询和监听批次的方法列在 `request_trace::is_hot` 里，不记录；`diagnostics.*` 和 `core.ping` 永远不记录，日志系统不能记录自己的排空和查询。

**外部进程。** Core 启动的每个 Git 进程在执行点记录一条终态，本地和远程工作区都经过同一处。argv 只经过 `format_arguments` 进入日志：提交说明换成 `<message>`，凭据和个人身份类 `-c` 值换成 `<redacted>`，URL 用户信息被改写。stderr 只保留最后 8 个非空行，逐行脱敏。stdout、stdin 和环境变量永远不记录。退出码表示“回答”的情形（例如 `git diff --quiet` 的 1）不算失败。可见命令指经 `execute_git` 执行、作为 invocation 返回给宿主并显示在 Git 控制台的命令；内部读取指 Core 经 `capture_git` 执行、自己解析输出的命令。来源不是用户的内部读取，非零退出由调用方判断含义；调用方据此返回错误时，由请求轨迹记录失败。

**级别。** 用户来源的请求和用户来源的可见命令，成功或取消是 INFO（`finished`）。后台或未知来源的成功或取消，以及用户操作中内部读取的成功或取消，是 DEBUG（`traced`），只在详细诊断开启时落盘。失败是 WARN（`failed`）。取消是一种结局，不是失败，所以记在成功终态上，并带 `cancelled`。

### 失败级别与宿主的边界

Core 轨迹的失败固定为 WARN，因为 Core 不知道宿主会重试、降级还是放弃。ERROR 留给知道最终结果的那一层。

宿主要告知用户的失败，如果事实已经全部在同一 op 的 Core 失败轨迹里，提示的“查看日志”就用 `LogRecordReference` 引用这条轨迹，宿主不再记录。Git 的规则在 `GitService.failureReference`：有进程以非零状态退出时引用 `vcs/git` 的 `vcs.git.command.failed`；没有这样的进程而请求失败（参数校验失败、仓库不可用）时引用 `app/core` 的 `app.core.request.failed`；进程全部以 0 退出、只是操作结果报告失败时，Core 没有失败轨迹，不返回引用，由调用方记录自己的终态。宿主只在掌握 Core 没有的事实时，才记录自己的终态：降级到了哪条路径、重试几次后放弃、留下了什么残留。最终没有完成用户请求时，这条终态是 ERROR。

由此产生的可见变化是：用户可见的 Git 失败以前由 Swift 记成 ERROR，现在是一条 WARN 级别的 Core 轨迹，由通知引用。原来的 `MacGitLifecycleLog` 已删除。

正确做法：`pendingNotificationReference = result.logReference`。不要这样做：为同一次失败另声明一个宿主事件，再记一次 ERROR。这样一次失败会有两条终态，而且宿主那条没有 argv 和 stderr。

### Core 事件队列、DEBUG 门与排空

现有的请求事件流只覆盖单个请求，覆盖不到执行轨迹、析构、后台清理和辅助 crate 的失败。因此 Core 有一个独立的有界交接队列 `diagnostics::core_events`（交给宿主写入的内存队列）：

- 只接纳 owner 为 `lithe-core` 的目录事实，入队前完成规范化和脱敏，最多 256 条。
- 队列满时，新事实只计入丢弃数。同一批次里事件、通道、字段和 op 都相同的事实只保留一条。
- 队列没有文件 writer、后台任务或独立持久化。宿主一次 drain 取走全部事实，同时重置计数，丢弃汇总转成 `app` 通道的 `log.dropped`。

DEBUG 在入队前过滤。`MacLogStore` 在详细诊断开关或通道根集合变化时，调用 `diagnostics.configureCoreEvents { debug, roots }`，默认关闭。被拒绝的 DEBUG 直接返回成功，不计入丢弃数。构造字段前先调用 `core_events::accepts`，使后台轨迹在正式使用时只花一次分支判断。只在宿主侧过滤是行不通的：一次后台刷新就会产生几十条 DEBUG，占满 256 条队列后，之后的 WARN 和 ERROR 都会被丢弃。

排空时机：

- 写入器在每次写入批次、flush 和退出时排空一次。
- 没有其他宿主活动时，由 Core 的唤醒回调安排排空。插件 `lithe/log` 事实、后台 Git 轨迹、析构和后台清理都可能在没有宿主事件时产生；只靠写入器自己的节奏，它们会一直留在内存里，既不落盘，也不推给日志窗口。

Core 在队列旁保留一个唤醒回调槽位。drain 之后的第一条事实或第一次丢弃计数触发一次回调，同一个 drain 周期内的后续变化合并，不再回调。drain 在队列锁内清除请求标记，之后入队的事实一定会再次触发；安装回调时已有待取事实，也立即回调。回调在持有槽位锁时同步执行，移除也取这把锁，所以移除返回后 Core 不会再使用宿主的 context，宿主可以释放它。回调不得重入 Core，只安排宿主已有的 drain。这个槽位属于已有的进程队列，不是新的日志单例：它不写文件、不持有 sink，服务的日志依赖仍从构造器注入。

每个进程只有组合根创建的应用 writer 调用 `observeCoreFacts()` 安装回调。回调复用宿主事件已有的 100 ms 单次排空调度，已有调度时不重复安排，不增加空闲轮询或第二个 writer。测试和其他临时 `MacLogStore` 不安装，避免两个 writer 争抢同一个进程队列；只有在独立子进程里验证 Core 落盘的测试自己安装。`finishSession` 先停止接纳并移除回调，再做最后一次排空。

排空得到的 `CoreLogRecord` 只含标量，保留 event、目录级别、channel、op 和源 ts；`MacLogStore`、`LogScope` 和测试用的 `TypedLogRecorder` 都实现了它。同一个 writer 分配 seq，并以 `validateCatalog: true` 写入。相同的失败状态只记录一次 `app.logging.diagnostics_failed`，避免出现“drain → 失败日志 → drain”的循环；目标状态改变后允许重试。

### 入队、批量和资源上限

`emit` 只在短锁内按级别和详细诊断分类的快照过滤并入队。DEBUG 默认关闭，详细诊断持续 15 分钟。队列最多 8000 条，普通级别最多占用 6000 条，剩余 2000 条留给 WARN 和 ERROR。过载时累计 `log.dropped`，不在调用线程执行 I/O。写入器每 100 ms 或攒够 256 条时，交给 Core 批量做目录校验、脱敏和编码。

一个串行 I/O 队列拥有序号、会话文件、目录切换和保留执行，句柄最多 32 个，按最近使用淘汰。Core 用事件身份、字段、op 和通道的结构哈希合并相邻重复，并跨批次携带上一条输入，不逐条序列化判重。广播只包含已编码的证据，最近窗口上限为 2000 条或 2 MiB；最多 16 个订阅者，每个订阅最多缓存八批，窗口关闭时必须取消订阅任务。

控制操作最多同时接纳四项，串行执行。每项持有带取消状态和单调截止时间的操作令牌，在开始前、查询前、目录切换前和发布控制结果前检查。已接纳日志的一次有界 drain 由进程 I/O 队列拥有，与控制操作的取消无关：必须写完这批快照和丢弃汇总，才报告控制超时，不能因为取消而丢掉后半部分。原生同步文件操作无法中途撤销，截止时间不是强制中断磁盘 I/O 的时限，调用方只在队列停止修改后恢复。退出走独立的接纳路径：先停止接纳，无论 drain 成功或失败，都在队列上关闭句柄、结束订阅；任务取消或四个普通控制已占满，都不能跳过这一步。

### 收集预算与文件替换恢复

原生枚举只提供路径、长度和修改时间。Core 先做分类和会话筛选，再分配读取预算：200 个文件、单文件 2 MiB、总计 10 MiB。同一会话先读所有活动文件，再读轮转 1、轮转 2；同一层按修改时间从新到旧，最后按路径稳定排序。不能按文件名倒序分配预算，否则 `z~2.log` 会挤掉仍在写入的 `a.log`。通道根到现有六类设置筛选的映射也由 Core 持有：update、remote、agent 出现在 Application，terminal 和 debug 进入 Run，详细诊断使用同一映射。

缓存的句柄每次写入前，比较原生设备号和 inode（文件在磁盘上的身份）、链接数和文件长度。路径被删除、被原子替换或被截断时，关闭旧句柄，重新写文件头并打开活动路径；不可写时使用既有的默认目录回退。只检查路径是否存在是不够的：原子替换后路径还在，旧句柄却会悄悄写进已经失去路径的旧文件。

### macOS 只收集 v2

设置时间线和诊断导出只读取 `sessions/` 下的 v2 文件，没有安装 collector 时只导出系统快照。旧的 `<category>/lithe.*.log` 和根目录 `lithe.log` 不显示、不解析、不改写，也不迁移到新会话。它们仍出现在交给 Core 保留计划的文件清单里，只按年龄删除，不会因为总量压力被提前删除。

### 按会话组织，以受控通道决定相对路径

一个会话就是一次应用进程运行。Core 根据宿主传入的开始时间和完整 UUID（会话唯一编号）生成 `sessions/YYYY-MM-DDTHH-MM-SS_<8位小写十六进制>/`，自己不读取时钟或文件系统。

通道是“固定根 + 已校验的 ID 段”，不是自由路径。根的封闭集合和段的语法以 `shared/logging/README.md` 和共享 Core 契约为准。Core 生成 `app.log`、`vcs/git.log`、`plugins/<id>/host.log` 这样的会话相对路径；轮转文件为 `git~1.log`。分隔符 `~` 不属于通道字符集，因此合法 ID `git.1` 的活动日志不会和 `git` 的轮转文件互相覆盖。段还拒绝末尾点号和 Windows 设备名，同一身份在双端都能安全落盘。每个会话最多接纳 128 个通道，之后新增的通道映射到会话根的 `_overflow.log`，已接纳的通道保留原路径；溢出文件使用相同的文件头和轮转规则，也受单文件预算约束。

这里明确推翻“调用方字符串不进目录”的绝对限制，改为：只有来自已校验的插件、provider、server 或内部连接身份的 ID，才能进入目录。这些身份有明确的所有者、稳定的格式和数量预算，可以同时表达证据来源和插件隔离。任意 scope、主机名、显示名称和用户文本仍然不能进入目录。语法校验只证明字符安全，调用方还必须证明 ID 的真实来源。

正确做法：从已验证的 provider 身份得到 `vcs/git`，交给 Core 解析相对路径。不要这样做：把远程主机名、项目路径或命令行当作段名，即使它恰好通过了字符校验。

平台把相对路径连接到实际生效的可写日志根，负责防止原生路径和符号链接越界，不得连接到 app bundle 或安装目录。日志属于用户运行状态，不参与签名和 Sparkle 增量基线，不跨 worktree 复制。生成的类型和生成物没有运行时文件操作。

### 单行格式是契约，重复身份放文件头

每个 v2 文件的第一行记录会话、进程、应用版本、通道和开始时间；记录行只保留每条变化的事实。例如：

```text
#lithe-log v2 session=12345678-1234-1234-1234-123456789abc pid=5123 app=0.42.0 channel=vcs/git started=2026-11-03T08:00:00.000Z
2026-11-03T08:00:01.123Z WARN seq=42 event=vcs.git.command.failed op=7f3a msg="Git fetch failed" arguments="fetch --prune origin" command=fetch duration_ms=311 exit_code=128 repository=<HOME>/src/app source=user stderr="fatal: could not read from remote repository."
```

时间统一为 UTC 毫秒。级别封闭为 DEBUG、INFO、WARN、ERROR。字段顺序为时间、级别、`seq`、`event`、可选的 `op`、`msg`，其余字段按键排序。`seq` 是宿主分配的会话内单调序号，不补零；无状态的编码器无法证明跨批次单调。`op` 是操作关联身份，不是事件字段，也不是路径段。

编码器和查询复用结构化字段脱敏：先检查完整字段名（包括 `client_secret`、`auth_token` 这类前缀形式），再处理文本。不能把字段拼成字符串后，只依赖文本正则的单词边界。编码器负责转义和 8 KiB 的单行预算，换行只作为转义值出现。超长时先缩短上下文字段，再缩短消息，并标记 `truncated=1`；身份和键的开销仍放不下时返回错误，不能悄悄删键。重复聚合和队列丢弃使用普通的 `log.repeated`、`log.dropped` 事件。精确语法、错误码和边界由 `shared/contracts/rust-core-api.md` 和 `shared/fixtures/diagnostics/logging-v2.json` 持有，本 Note 不另建字段手册。

### 事件目录与生成类型约束接入

`shared/logging/events/` 是事件声明的唯一来源，声明真实来源、级别、通道、英文事实模板、字段含义、owner（维护模块）和 rate 元数据。没有真实来源的根保持空目录，不预造事件。事件消息供诊断使用；面向用户的界面文案仍走共享 i18n。

生成器输出 `LogEvents.generated.swift` 和 `catalog_generated.rs`。Swift 的事件值是尚未脱敏的输入，不能自行序列化落盘。Rust 静态表提供事件查找和字段形状校验，不分配运行时目录缓存。Core 对 error 和 text 的原始输入先脱敏、去除控制字符、按 UTF-8 边界截断到 1 KiB，再严格校验字段。不得在 Swift 重写隐私规则，也不得放宽 `validate_fields`。

日志身份转换不得影响插件资源是否加载。语言 ID 和通道段不是同一个集合，`c++` 和超长的合法语言 ID 都必须继续加载。浏览器返回的语法加载失败始终记录插件事件，语言放在有界的可选 version 字段里，不能因为 `LogSegment` 拒绝它就丢掉整条失败。

新增或迁移调用时，先修改事件 JSON，再生成并使用类型化事件；不手写任意的消息、级别或字段字典来绕过目录。操作规范见 develop-lithe 的日志参考页，声明规则的唯一来源是 `shared/logging/README.md`。

用法门禁没有存量额度，任何违规都直接失败。永久例外写进 allowlist，带架构理由和精确计数；计数少于或多于实际都失败，防止空出来的名额被新写法占用。门禁只覆盖列出的直接写法，不做跨文件的别名分析，也不能代替人工审查。目录中的 rate 只是元数据，写入器还不执行运行时限流；需要限流的高频失败在发送侧自行合并（见辅助 crate 一节）。

### 引擎声明身份，macOS 接入统一写入器

同一个引擎承载语言服务、版本控制、构建、工具链和插件后端，provider ID（提供者身份）可能含冒号，不能直接成为目录段。宿主显式传 `role` 和 VCS 的 `logSubject`，Core 校验身份后选择事件族：语言服务用 `lsp.*`，VCS 用 `vcs.*`，其他插件进程用 `plugins.host.*`。目录模板和必填身份字段仍然唯一决定通道，schema 不因此放开任意 channel。旧宿主不传 role 时继续按语言服务处理。macOS 的各个启动者显式传角色和插件 ID，VCS 传真实的 `target.vcs`；远程语言会话仍属于 language_server。启动响应返回 Core 生成的 channel，宿主用它登记详细诊断的 I/O。

合法的语言 ID 不等于合法的路径段。遇到非法段或缺少身份时，Core 用原始身份的 SHA-256 前 32 位小写十六进制，加上 `invalid-` 前缀；缺值时哈希完整的 provider ID。这样既不阻断进程启动、不静默丢日志，也不把原文泄漏成目录名。正确做法：VCS 宿主从已注册的目录传 `role:vcs, logSubject:git`。不要这样做：拆开 `vcsProvider:<plugin>:<vcs>` 来猜身份。

启动之前的宿主事实也必须落到同一通道。宿主调用纯命令 `diagnostics.resolveEngineLogSubject`，Core 复用启动时的 `SessionLogIdentity`；Swift 不再实现一份哈希，也不自行用 providerID 拼段。manager 按 providerID 缓存成功或失败的结果（最多 128 项，满时清空），阶段、缓存、degradation 和 issue 事件都使用这个段。解析失败只是不发对应的宿主 v2 事件，不改变既有的启动和缓冲行为；参数错误沿用 `invalid_request`。

引擎在日志源头选择封闭的事实类型。既有的英文 message、detail、error 保留给 v1 兼容；v2 使用目录 ID 和标量字段，经过同一个 Core 边界完成规范化、脱敏和通道推导。v1 的 detail、message、level 必须保持原字节，例如 `projectCount=N`、navigation 的格式文本和通知的原始 JSON。`EngineLogInput` 另外携带源头字段，v2 不从 detail 反解。

stderr 是唯一的明确行为变化。读取状态最多保留 4 KiB 的半行，按 LF 切分、去掉末尾 CR、忽略空行，在 EOF 时冲刷残余；每个单调秒接纳 200 行，后续读取跨过窗口或结束时汇总丢弃计数。v1 detail 保留该行文本和行内空格，v2 再做脱敏和 1 KiB 限长。新增的丢弃事实只用 `count=N`，不以 JSON 冒充旧的结构化 detail。测试直接传毫秒值，不装计时器，也不等真实的一秒。

`window/logMessage` 和 `window/showMessage` 按上游明确给出的严重度选择独立的目录事件：error 为 ERROR，warning 为 WARN，info 为 INFO，详细或未知类型为 DEBUG。未分类的 stderr 只是 DEBUG 级别的排障证据，不能因为输出在标准错误流就标成警告；进程或协议的最终失败在实际失败的边界记录 ERROR。其他通知只记录方法，不把协议正文变成 text。上游 trace 默认关闭。显式开关和发往上游的 `$/setTrace` 共用一把有序写锁，成功写入后才改变采集状态。只接纳限长并脱敏的 message 摘要，排除可能含 RPC 原始载荷和源码的 verbose：凭据脱敏和截断无法把源码变成可以落盘的诊断。详细诊断已开启时，新会话的注册可能早于初始化响应。Core 此时只保存最新的开关值，等握手完成后把 `$/setTrace` 排在 `initialized` 之后；初始化前关闭会撤销待发送的启用。不要在注册时立即发通知，否则严格遵循 LSP 的服务器会丢弃它，宿主却以为已经开启。

详细诊断的分类不在宿主另写：会话通道根按 `diagnostics.resolveLogChannel` 返回的 category 归入当前开关（lsp → language、vcs → git、plugins → plugins），与持久化 DEBUG 的准入共用 `diagnosticRoots`。类别开关变化、新会话注册和 15 分钟的单次到期，都向活动会话发送 `setDetailedDiagnostics`，退出时关闭。

Core 拥有会话生命周期状态。`*.session.updated` 直接附到已有的 `type:stateChanged` 事件上，复用 `enqueue_runtime_event` 里的同一个 `prepare_catalog_event` 校验，不额外推送 v1 log 行，也不改 type、state、message 等兼容字段。Swift 在 switch 之前，把任何带 coreLog 的事件转发一次。manager 清除 UI 身份后，仍把退休会话的最终 Core 事实交给 sink，不套用 UI 过期回调的检查；VCS、构建、工具链和后端会话同样收到生命周期事实。不要用新增 log 行来补证据，否则 Windows 的 frontendTrace 会改变。

宿主只拥有启动编排的阶段，在实际调用点发 `lsp.session.stage_changed`（requested、resolving、registered、stopping、cancelled）和 `lsp.cache.cleaned`（removed 计数），由 manager 注入的 LogSink 接收。两者都是 DEBUG，因为它们描述内部阶段和维护信息。缓存清理不是 Core 的配置键清理，不能复用 `configuration.cleaned`。ready 和 terminated 已由 Core 的 `protocol.initialized` 和 `session.updated` 表达，宿主保留原有 v1 行，但不重复发 v2。macOS 已删除消息字符串匹配和重复的 session 状态事实，按目录元数据取 v2 级别。带 Core 记录的 log 不再触发重复的 onLogIssue；宿主自身的启动、发现和请求失败仍走既有的错误边界。

语言服务日志只有磁盘通道这一个来源。旧的语言服务日志视图曾保留 100 条 v1 内存缓冲，日志窗口替换该视图时已一并删除。

`${logDir}` 由启动上下文的绝对 `logDirectory` 展开，语言服务和后端的启动路径共用。宿主创建当前应用会话的插件 files 目录：Core 的 `plugin_files_path` 决定相对部分，`MacLogStore` 的存储器提供当前会话目录。平台用 `mkdirat`、`openat` 和 `O_NOFOLLOW` 逐段创建 0700 目录并拒绝符号链接，避免在检查和创建之间被换成越界链接。Core 只拼接文本，不创建目录，也不从插件安装位置推导可写位置。这些文件属于运行状态，不跨 worktree 复用，不改变签名或 Sparkle delta 的源基线。

存储不可用（包括目录适配器抛出真实 I/O 错误）时，宿主省略 `logDirectory`，由 Core 检查模板是否依赖 `${logDir}`，依赖时按既有的 `invalidRequest` 拒绝。不使用该变量的插件照常启动，可选的日志目录不能变成全部语言服务、构建、VCS、后端和调试器的前置条件。远程进程无法写本机日志目录，同样省略并拒绝该变量。安装阶段只用未创建的占位目录校验展开。

### 官方插件通过新的类型化协议交付事实

官方 Node、Java、Rust SDK 使用独立协商的 `litheLogging` 1，通过 `lithe/log` 把操作结果交给 Core。插件只提供注册过的操作、稳定类别、计数和单调耗时；Core 从已安装插件的身份选择通道和目录事件。成功终态为 INFO，实际失败为 ERROR，回退和真实恢复为 WARN。高频成功可以在注册时或当前调用上抑制，失败始终可见；取消不是失败。

采用新协议，是因为 stderr 无法可靠表达处理后的结果、原操作身份和字段边界。给自由消息加 `[ERROR]` 解决不了这个问题，还会把错误正文和用户内容带进日志。正确做法：SDK 在结果边界发送一条类型化终态，处理函数只补它真正拥有的降级。不要这样做：先记录错误再返回同一次错误，或把 SQL、HTTP 正文、构建输出写进诊断。

Core 只接纳协商成功、字段符合封闭契约的事实，每个进程会话每分钟最多 600 条，使用现有的 256 条队列和单一宿主写入器。非法输入每个会话只告警一次，不回显被拒内容；超出限额只计丢弃数。SDK 在初始化阶段最多缓存八条类型化事实，capability 响应后再交出；正常终态在 RPC 响应之前发出，使 Core 能把 wire 请求编号映射到真实的宿主 op。协议和 fixture 以共享插件契约为准，不再维护自由文本日志 API。

### 辅助 crate 经注入的函数指针进入 Core 队列

agent-host、git-host、ide-host 和 lithe-remote 的客户端链接进 Core。Core 依赖它们，它们不能反过来依赖 `core_events`，否则形成循环依赖。因此每个辅助 crate 只带一个 `failure_log` 模块：公开本 crate 用到的事件 ID 列表和一个安装函数，内部只保存一个先装先得的函数指针，调用点只交出事件 ID 和标量字段。Core 的 `diagnostics::helper_failures::install()` 用一次性初始化把四个指针都指向同一个转换函数，转换函数把字段交给 `core_events::record`，失败时计入丢弃。这些事件在共享目录里以 `lithe-core` 为 owner 声明，校验、脱敏和通道推导与 Core 自己的事件完全相同。

安装点是所有会进入辅助 crate 的 Core 入口：请求分发、Agent 打开的 FFI、IDE 请求分发器挂接和 Git askpass 的独立入口。新增这类入口时必须同时调用 `install()`。未安装时辅助 crate 只累加未注入计数，不回退到 stderr：askpass 等入口的标准输出和错误输出本身是协议或用户可见输出，回退会污染它们，也会重新引入门禁禁止的直接打印。

收尾失败按错误类别区分。对端已断开、进程已退出、连接已关闭这类“对象已经不在”的情况属于预期的缺失，不记录。权限不足、超时后进程仍在运行、清理目录失败（目录不存在除外）等真正留下残留的情况记录 WARN。端口转发的接受和连接失败可能逐连接发生，`client/forward.rs` 在发送侧让每一族失败在进程内每 5 秒最多记录一条，与目录的 rate=12 一致。处理凭据的 askpass 写回失败只记录阶段和错误类别，写入后把凭据字节清零，测试证明凭据不出现在事件字段里。

Core 的目录遍历和 scratch 清理使用 `app.search.directory_skipped`、`app.workspace.directory_skipped` 和 `app.workspace.scratch_cleanup_failed`；error 只含固定消息、稳定类别和固定 domain，不含绝对路径、scratch 名或远程地址。远程进程和上传按 `ClientError` 的变体映射为 timeout、closed、transport、spawn、protocol 或 `remote_<协议码>`，不保留正文。

日志门禁覆盖这四个 crate。运行在远端主机上的 `lithe-remote-server`（`rust/lithe-remote/src/server/`、`src/bin/`）和 ide-host 的独立可执行文件不链接进本机 Core，没有可注入的 sink，暂时排除在门禁外；远端服务端日志回传和 Monaco 控制台转发在 Issue #1680 中跟踪。

### DAP：记录状态与失败，保留程序内容边界

调试适配器协议（DAP，调试器与宿主交换控制消息的协议）的共享状态由 Core 持有，
因此会话开始、初始化完成、结束和操作失败都由 `debug/engine.rs` 在真实转换点记录。
通道使用校验后的适配器身份；不适合路径的身份使用稳定 SHA-256 摘要，不能让项目路径或显示名称进入通道。
生命周期关键里程碑为 INFO，暂停、运行等内部状态为 DEBUG，超时与适配器拒绝为 ERROR。
取消和过期引用仅为 DEBUG，不把正常取消写成产品故障；已有失败操作记录时，随后会话 Failed 不重复记录。

原生宿主只补自己拥有的启动失败、初始化超时和异常进程退出，以固定阶段与退出码传给生成事件。
正确做法是 Core 根据 `OperationFailed.code` 记录稳定分类；不要把 adapter stderr、DAP 响应 message、
调试变量、内存、源码或被调试程序输出塞入 text/error。原始 stderr 继续属于调试控制台，不代表持久化。
共享 Core 队列复用宿主既有 drain 和队列唤醒回调，不创建第二个 writer、轮询或应用退出后仍持有的缓存。

### 保留以完整会话为主，Core 只计算删除计划

年龄和总量策略按完整会话删除：先删过期的，再从最老的会话开始释放空间。当前会话的所有文件始终受保护，预算可能暂时无法满足。单通道以 10 MiB 为轮转阈值，共保留三段（含活动文件）：活动文件为 `vcs/git.log`，轮转文件为 `vcs/git~1.log`、`vcs/git~2.log`。`lsp/foo.1.log` 永远是 `lsp/foo.1` 的活动文件，查询和性能保留分类都使用这套命名，不能再剥掉“点号加数字”的后缀。实际轮转由平台执行。

保留计划的默认值为 30 天、总量 100 MiB、性能 20 MiB、每插件每会话 files 20 MiB。性能预算可以删除非活动会话里的性能文件。插件超额时返回告警，只有启动清理允许删除非活动会话中最老的插件文件。这两项是完整会话删除之外的明确例外；告警去重由宿主负责。Core 接收平台采集的文件清单和显式时间，返回相对路径计划；平台执行删除并报告真实的 I/O 结果，不能把计划当成删除成功。

### 声明式插件：由执行方代记同一组操作事实

声明式插件（只在 manifest 里声明语言服务器、调试适配器或构建命令，没有自己的后端进程）无法发送 `lithe/log`。
如果不处理，Go、PHP、LLDB、Gradle 这类插件出错时，`plugins/<id>/host` 通道里什么都没有，日志窗口里它们和
SDK 插件不统一。因此谁真正执行声明的工作，谁就替插件写那一条终态事实：事件仍是
`plugins.operation.finished|failed`，通道仍是 `plugins/<id>/host`，和 SDK 插件写出的事实在同一处、同一格式。

所有贡献共用一个通用结构：Core 的 `DeclarativeOperation`（插件 ID、贡献、失败阶段、耗时、可选 op），
Swift 侧对应 `PluginOperationAttempt`。差异只在 `plugin_operations.rs` 的 `CONTRIBUTIONS` 映射表里：每一行给出
操作名和生命周期（`ProcessStart` 常驻进程启动，或 `CommandRun` 一次性命令）。生命周期持有“阶段 → `host.*` 码”的表，
同一个码在所有共享该生命周期的贡献中只有一个含义；某个生命周期到不了的阶段直接拒绝（-32064），不会被猜成别的码。
以后新增声明式契约时，开发者加一行映射，并在实际执行它的地方开始和结束一次 attempt，不新增事件、通道或错误码。
构建命令沿用 SDK 的请求名（`lithe/build/model` 等），所以同一工作不论由声明还是后端提供，日志里都叫同一个名字。

所有权按“谁执行，谁记录”划分：

- 调试适配器启动和构建命令由 macOS 宿主执行，宿主在解析、启动、初始化、超时、退出和解码的真实边界推进阶段，
  通过 `diagnostics.recordPluginOperation` 写入。
- 语言服务器由宿主解析启动方案、由 Core 拉起和握手。宿主只记录启动前的失败；进入启动后用
  `startupOperation:{operationId,elapsedMs}` 把 attempt 交给 Core。Core 在 spawn 失败、提前退出、握手失败、
  初始化超时或初始化成功时记录唯一结果，耗时为宿主已用时间加 Core 计时。
- 构建计划实际由插件后端提供时，宿主取消自己的 attempt，由 SDK 记录，避免同一次工作出现两条事实。

一次 attempt 只有第一次终态生效。取消、停止、被新请求取代的过期结果都不记录，因为它们不是插件故障；
错误码只来自阶段，从不解析本地化错误文本，也不带插件输出、路径或命令行。
正确做法：`attempt.advance(to: .launch)` 放在真正调用 `start` 之前，失败时 `attempt.end(throwing:)`。
不要这样做：在 catch 里按 `error.localizedDescription` 判断是哪一步失败，或在宿主里按插件名写分支。

## 考虑过的备选方案

- **JSON Lines**：通用解析方便，但每行都重复键名和身份信息，手工阅读噪声多。采用有严格语法和 fixture 的单行文本，代价是维护专门的编解码器。
- **平铺文件加 scope**：不能同时自然表达会话保留和插件证据边界；继续允许自由 scope，也会保留字符串接入问题。
- **手写字符串 API**：字段、级别和事件身份只能靠约定，编译器发现不了漂移，因此改用共享声明和生成类型。
- **每个插件自带宿主 writer**：线程、队列、脱敏和预算会分裂。插件原生文件只能进入宿主管理的独立 files 区。
- **在编辑器标签页查看日志**：会把应用级证据绑定到项目，并延续语言服务内存和磁盘两份来源，因此改为应用级日志窗口。
- **现在删除 v1**：会破坏仍直接使用旧 Rust API 的 Windows。保留兼容入口，迁移完成后再单独评估删除。
- **辅助 crate 依赖 Core 直接记录**：会形成循环依赖。把事件队列拆成第三个公共 crate 可以解开循环，但目录校验和脱敏都在 Core，拆出去要么复制规则，要么只搬走一个空壳队列，不如注入一个函数指针简单。
- **辅助 crate 未注入时回退到 stderr**：askpass 等入口的输出是协议的一部分，回退会污染协议，门禁也不得不为每个 crate 开 allowlist。
- **继续在 Swift 记录 Git 生命周期**：Swift 不知道 Core 最终传给进程的参数、退出码和 stderr，只能覆盖经过它的那部分操作，远程工作区和 Core 内部发起的 Git 调用都会漏掉。在执行点记录只需一处，所有调用方自动覆盖。
- **只记录失败**：失败日志无法回答“用户点了之后到底执行了什么”。成功轨迹按来源分级：用户操作的成功是 INFO，后台的成功是 DEBUG，平时不落盘。
- **在 Swift 的每个 Core 调用点记录请求**：需要逐个改调用点，新调用点很容易漏掉，而且同一请求在 Swift 和 Core 各有一份时间和结果。改为在 Core 分发处记录一次，宿主只传 `origin`。
- **宿主定时轮询 Core 队列**：应用空闲时也持续唤醒，落盘延迟取决于轮询周期。改为 Core 有事实时合并唤醒宿主。
- **在每个响应信封里标记待取事实**：只在有请求返回时生效，插件 `lithe/log`、析构和后台线程留下的事实要等下一次无关请求才落盘。唤醒回调覆盖所有来源，因此响应里不再携带标记。
- **每条事实回调一次，或在回调里直接 drain**：突发事实会产生大量跨语言调用；在记录线程里 drain 会把磁盘 I/O 带到 Core 调用方的线程，还要重入 Core。回调只安排宿主已有的单次排空。
- **只在宿主侧过滤 DEBUG**：后台 DEBUG 会先占满 256 条的 Core 队列，之后的 WARN 和 ERROR 被丢弃，因此必须在入队前过滤。
- **Core 轨迹的失败直接记 ERROR**：Core 不知道宿主会不会重试或降级，ERROR 会把可恢复的失败误报成用户请求失败；同一次失败再由宿主记录还会产生两条终态。
- **为声明式插件单独起一个监听服务进程**：它看不到宿主和 Core 内部的真实阶段边界，只能事后解析输出或状态，还多一个需要管理生命周期的进程。由执行方在边界处直接记录更准确，也不增加进程。
- **每种贡献一个专用事件或一个封闭的大枚举**：新契约要改事件目录、生成类型和所有平台代码，码的含义也会在各贡献间漂移。改为通用结构加映射表。
- **解析错误消息判断失败阶段**：消息是本地化文本，也可能带路径和插件输出，翻译或措辞一改分类就错。阶段由代码路径显式推进。

## 后果

收益：

- 路径、格式、查询和删除选择都可以独立验证。
- 事件身份和字段在生成阶段就能审查。
- 一次 Bug 报告的日志能顺着同一个 op 看到用户操作、Core 请求和 Git 命令的参数、退出码和 stderr。
- 新增的 Core 请求和 Git 调用不需要逐个接入日志。

代价：

- 需要维护生成器、专用语法、编解码器和 allowlist。
- 每个用户入口都要选一个稳定 id 并包在最外层。跨越分离任务时要显式携带操作上下文，否则请求会退化成后台来源。
- 新增按键、每帧或轮询类 Core 方法时，必须同步更新 `request_trace::is_hot`，否则每次按键都会产生一条记录。
- Core 开始依赖某个 Git 命令新的文档化退出码时，必须同步更新 `exit_is_answer`，否则成功的回答会被记成 WARN。
- 用户可见的 Git 失败从 ERROR 变为 WARN 的 Core 轨迹，按 ERROR 筛选的人需要改为通过通知引用定位。
- macOS 通过提前过滤、批量调用和句柄复用减少跨边界和磁盘开销，真实应用的性能仍需要独立的工作流证据。
- 平台仍要承担有界队列、时间和序号、文件句柄、真实 I/O 失败、告警去重和导出冻结的责任。

## 验证

关键回归用例：

- `lifecycle_catalog_identity_preserves_v1_event_without_extra_log`：五种角色的身份正确，v1 wire 字段不变，没有额外的 log 行。
- `diagnostics_resolve_engine_subject_matches_startup_and_rejects_invalid_arguments`：非法段和通用参数错误。
- `rust/lithe-core/src/tests/core_request_traces.rs`：真实 Git 仓库上的用户命令在操作 op 下记录脱敏后的 argv；失败命令记 WARN，带退出码和 stderr 末尾；后台读取只在详细诊断开启时记录。
- `command_trace.rs` 和 `request_trace.rs` 的单元测试：argv 脱敏与截断、文档化的回答退出码、结果分类、stderr 末尾、热点方法、来源优先级和取消。
- `macos/Tests/LitheTests/UserActionTraceTests.swift`：嵌套调用只记录外层、分离任务和主线程延后执行仍携带操作、60 秒后不再声称用户来源。
- `macos/Tests/LitheTests/CoreRequestTraceTests.swift`：通过真实 Core 确认用户 Git 命令在操作 op 下落盘，后台读取等待详细诊断。
- Swift 的 `TypedLogRecorder` 测试：阶段各发一次、不重复 ready 和 terminated、失败缓存，以及真实 Core 下的 `c++` 通道。

以下是复验入口，不是整机验收通过的声明：

- `node scripts/logging/generate-log-events.mjs --check`
- `node scripts/logging/verify-log-usage.mjs`
- `node --test --test-timeout=60000 scripts/logging/test-log-events.mjs`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core diagnostics`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core core_request_traces`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core command_trace`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --test core_log_waker`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core plugin_operations`
- `./scripts/rust-core/verify-rust-core-comments.sh`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/windows/verify/verify-windows-boundaries.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

fixture 覆盖往返、转义、非法输入、路径段、轮转与保留、共享旧日志兼容、macOS 排除 v1 与按年龄清理，以及查询的不完整性。`--check` 只读比较生成物，不能用重新生成来掩盖声明或生成器的错误。Windows 边界脚本通过也不能代替 Windows Rust 编译。

## 适用范围

- `rust/lithe-core/src/diagnostics/`
- `rust/lithe-core/src/git/command_trace.rs`
- `rust/lithe-core/src/runtime/dispatcher.rs`
- `rust/lithe-core/src/tests/core_request_traces.rs`
- `rust/lithe-core/src/debug/engine.rs`
- `macos/Sources/LitheModuleAPI/Logging/PluginOperationReporter.swift`
- `rust/lithe-agent-host/src/failure_log.rs`
- `rust/lithe-git-host/src/failure_log.rs`
- `rust/lithe-ide-host/src/failure_log.rs`
- `rust/lithe-remote/src/failure_log.rs`
- `shared/logging/`
- `scripts/logging/`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/diagnostics/logging-v2.json`
- `macos/Sources/LitheModuleAPI/Logging/`
- `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift`
- `macos/Sources/Lithe/Platform/MacOS/Logging/`
- `macos/Tests/LitheTests/MacLogStoreTests.swift`
- `macos/Tests/LitheTests/UserActionTraceTests.swift`
- `macos/Tests/LitheTests/CoreRequestTraceTests.swift`
