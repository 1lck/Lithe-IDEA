# Agent 笔记：结构化日志通道与事件目录

状态：已实现

## 先说结论

日志的每一种事实都先在事件目录里声明，再由生成的类型约束字段。Core 负责通道、单行格式、脱敏、查询和保留计划；桌面端只负责实际文件操作（`desktop/internal/logstore/`）和日志窗口（`desktop/internal/logwindow/`）。排查问题时，维护者能顺着同一个 op（操作关联身份）看到三层轨迹：用户按了什么，Core 执行了哪个请求，以及 Git 命令带着哪些已脱敏参数、怎样结束。没有插件进程的声明式插件，由实际执行声明工作的宿主或 Core 按一张贡献映射表，代写与 SDK 插件相同的插件操作事实。

本笔记部分取代 [双端模块日志与诊断快照](2026-10-20-modular-application-logging.md) 中三项设计：固定分类目录、以 scope 作为主要细分方式，以及 v1 记录格式。脱敏、导出冻结、平台 I/O 所有权等决策继续有效。日志窗口与诊断导出的决策见 [应用级日志窗口与诊断导出](../feature/2026-11-03-structured-logging-log-window.md)。

## 问题

- 直接写系统日志或标准错误输出，日志会漏收。
- 字符串调用没有共同的事件与字段规范。
- 自由文本格式不能作为可靠的解析契约。
- 逐事件跨语言调用、在过滤之前编码，以及反复打开文件，都增加开销。
- Bug 报告里常见的“点了 Fetch 没反应”无法从日志定位：日志只记录了宿主认为值得记录的结果，看不到用户按了哪个按钮、背后调用了哪个 Core 请求，也看不到实际运行了哪条 Git 命令。

## 决策

### 事件目录与生成类型约束

事件的唯一来源是事件目录：它声明真实来源、级别、通道、英文事实模板、字段含义、owner（维护模块）和 rate 元数据。没有真实来源的根保持空目录，不预造事件。事件消息供诊断使用；面向用户的界面文案仍走共享 i18n。

Core 对 error 和 text 的原始输入先脱敏、去除控制字符、按 UTF-8 边界截断到 1 KiB，再严格校验字段。宿主传入的事件值是尚未脱敏的输入，不能自行序列化落盘，也不能放宽字段校验。

新增或迁移调用时，先修改事件目录，再使用生成的类型化事件；不手写任意的消息、级别或字段字典来绕过目录。`--check` 只读比较生成物，不能用重新生成来掩盖声明或生成器的错误。

### 执行轨迹分三层，由同一个 op 串起来

| 层 | 事件 | 记录位置 |
| --- | --- | --- |
| 用户操作 | `app.action.performed` | 最外层的用户入口 |
| Core 请求 | `app.core.request.*` | Core 请求分发处（`diagnostics/request_trace.rs`） |
| 外部进程 | `vcs.git.command.*` | Core 的 Git 进程执行点（`git/command_trace.rs`） |

- **用户操作。** 每个用户入口在最外层记录一条 INFO，并把操作 id、surface、op 和开始时间绑定到当前上下文。嵌套调用不记录也不重新绑定，外层 id 生效。id 是稳定的目录 token，不能使用本地化标题或用户内容。跨越分离任务时要显式携带操作上下文，否则请求会退化成后台来源。
- **Core 请求。** Core 在分发每个请求时，把 op 和来源放进线程局部上下文，并在请求结束时记录唯一的终态。op 依次取 `origin.operation`、请求的 `operationId` 和请求 `id`。领域代码不再为“请求开始”“请求完成”另加日志。按键、每帧、轮询和监听批次的方法列在 `request_trace::is_hot` 里，不记录；`diagnostics.*` 和 `core.ping` 永远不记录，日志系统不能记录自己的排空和查询。
- **外部进程。** Core 启动的每个 Git 进程在执行点记录一条终态。argv 只经过格式化函数进入日志：提交说明换成 `<message>`，凭据和个人身份类 `-c` 值换成 `<redacted>`，URL 用户信息被改写。stderr 只保留最后 8 个非空行，逐行脱敏。stdout、stdin 和环境变量永远不记录。退出码表示“回答”的情形（例如 `git diff --quiet` 的 1）不算失败。

**级别。** 用户来源的请求和用户来源的可见命令，成功或取消是 INFO。后台或未知来源的成功或取消，以及用户操作中内部读取的成功或取消，是 DEBUG，只在详细诊断开启时落盘。失败是 WARN。取消是一种结局，不是失败，记在成功终态上，并带 `cancelled`。

### 失败级别与宿主的边界

Core 轨迹的失败固定为 WARN，因为 Core 不知道宿主会重试、降级还是放弃。ERROR 留给知道最终结果的那一层。

宿主要告知用户的失败，如果事实已经全部在同一 op 的 Core 失败轨迹里，提示的“查看日志”就引用这条轨迹，宿主不再重复记录。宿主只在掌握 Core 没有的事实时，才记录自己的终态：降级到了哪条路径、重试几次后放弃、留下了什么残留。

正确做法：通知直接引用 Core 的轨迹。
不要这样做：为同一次失败另声明一个宿主事件，再记一次 ERROR。这样一次失败会有两条终态，而且宿主那条没有 argv 和 stderr。

### Core 事件队列、DEBUG 门与排空

现有的请求事件流只覆盖单个请求，覆盖不到执行轨迹、析构、后台清理和辅助 crate 的失败。因此 Core 有一个独立的有界交接队列（交给宿主写入的内存队列）：

- 只接纳 owner 为 `lithe-core` 的目录事实，入队前完成规范化和脱敏，最多 256 条。
- 队列满时，新事实只计入丢弃数。同一批次里事件、通道、字段和 op 都相同的事实只保留一条。
- 队列没有文件 writer、后台任务或独立持久化。宿主一次 drain 取走全部事实，同时重置计数，丢弃汇总转成 `log.dropped`。

DEBUG 在入队前过滤。只在宿主侧过滤是行不通的：一次后台刷新就会产生几十条 DEBUG，占满队列后，之后的 WARN 和 ERROR 都会被丢弃。

排空时机：写入器在每次写入批次、flush 和退出时排空一次；没有其他宿主活动时，由 Core 的唤醒回调安排排空。插件 `lithe/log` 事实、后台 Git 轨迹、析构和后台清理都可能在没有宿主事件时产生，只靠写入器自己的节奏，它们会一直留在内存里。

唤醒回调在 drain 之后的第一条事实或第一次丢弃计数时触发一次，同一个 drain 周期内的后续变化合并。回调不得重入 Core，只安排宿主已有的 drain。宿主拥有一个 writer，只有它安装回调；测试不安装，避免两个 writer 争抢同一个队列。

### 入队、批量和资源上限

`emit` 只在短锁内按级别和详细诊断快照过滤并入队。DEBUG 默认关闭，详细诊断持续 15 分钟。队列最多 8000 条，普通级别最多占用 6000 条，剩余 2000 条留给 WARN 和 ERROR。过载时累计 `log.dropped`，不在调用线程执行 I/O。写入器每 100 ms 或攒够 256 条时，交给 Core 批量做目录校验、脱敏和编码。

一个串行 I/O 队列拥有序号、会话文件、目录切换和保留执行，句柄最多 32 个，按最近使用淘汰。Core 用事件身份、字段、op 和通道的结构哈希合并相邻重复，并跨批次携带上一条输入。最近窗口上限为 2000 条或 2 MiB；最多 16 个订阅者，每个订阅最多缓存八批。

控制操作最多同时接纳四项，串行执行，并带取消状态和单调截止时间。已接纳日志的一次有界 drain 由进程 I/O 队列拥有，与控制操作的取消无关：必须写完这批快照和丢弃汇总，才报告控制超时。原生同步文件操作无法中途撤销，截止时间不是强制中断磁盘 I/O 的时限，调用方只在队列停止修改后恢复。退出走独立的接纳路径：先停止接纳，无论 drain 成功或失败，都在队列上关闭句柄、结束订阅。

### 收集预算与文件替换恢复

原生枚举只提供路径、长度和修改时间。收集先做分类和会话筛选，再分配读取预算：200 个文件、单文件 2 MiB、总计 10 MiB。同一会话先读所有活动文件，再读轮转文件；同一层按修改时间从新到旧，最后按路径稳定排序。不能按文件名倒序分配预算，否则 `z~2.log` 会挤掉仍在写入的 `a.log`。

缓存的句柄每次写入前，比较设备号和 inode（文件在磁盘上的身份）、链接数和文件长度。路径被删除、被原子替换或被截断时，关闭旧句柄，重新写文件头并打开活动路径。只检查路径是否存在是不够的：原子替换后路径还在，旧句柄却会悄悄写进已经失去路径的旧文件。

### 只收集 v2，按会话组织

桌面端的设置时间线和诊断导出只读取 `sessions/` 下的 v2 文件。旧的 v1 文件不显示、不解析、不改写，也不迁移到新会话；它们只按年龄由保留计划删除。

一个会话就是一次应用进程运行。Core 根据宿主传入的开始时间和完整 UUID 生成 `sessions/YYYY-MM-DDTHH-MM-SS_<8位小写十六进制>/`，自己不读取时钟或文件系统。

通道是“固定根 + 已校验的 ID 段”，不是自由路径。Core 生成 `app.log`、`vcs/git.log`、`plugins/<id>/host.log` 这样的会话相对路径；轮转文件为 `git~1.log`。分隔符 `~` 不属于通道字符集，因此合法 ID `git.1` 的活动日志不会和 `git` 的轮转文件互相覆盖。每个会话最多接纳 128 个通道，之后新增的通道映射到会话根的 `_overflow.log`。

只有来自已校验的插件、provider、server 或内部连接身份的 ID，才能进入目录。任意 scope、主机名、显示名称和用户文本仍然不能进入目录。语法校验只证明字符安全，调用方还必须证明 ID 的真实来源。

平台把相对路径连接到实际生效的可写日志根，负责防止原生路径和符号链接越界，不得连接到应用包或安装目录。日志属于用户运行状态，不参与签名和 Sparkle 增量基线。

### 单行格式是契约，重复身份放文件头

每个 v2 文件的第一行记录会话、进程、应用版本、通道和开始时间；记录行只保留每条变化的事实：

```text
#lithe-log v2 session=12345678-1234-1234-1234-123456789abc pid=5123 app=0.42.0 channel=vcs/git started=2026-11-03T08:00:00.000Z
2026-11-03T08:00:01.123Z WARN seq=42 event=vcs.git.command.failed op=7f3a msg="Git fetch failed" arguments="fetch --prune origin" command=fetch duration_ms=311 exit_code=128 repository=<HOME>/src/app source=user stderr="fatal: could not read from remote repository."
```

时间统一为 UTC 毫秒。级别封闭为 DEBUG、INFO、WARN、ERROR。字段顺序为时间、级别、`seq`、`event`、可选的 `op`、`msg`，其余字段按键排序。`seq` 是宿主分配的会话内单调序号。`op` 是操作关联身份，不是事件字段，也不是路径段。

编码器和查询复用结构化字段脱敏：先检查完整字段名（包括 `client_secret`、`auth_token` 这类前缀形式），再处理文本。编码器负责转义和 8 KiB 的单行预算，换行只作为转义值出现。超长时先缩短上下文字段，再缩短消息，并标记 `truncated=1`；身份和键的开销仍放不下时返回错误，不能悄悄删键。精确语法、错误码和边界由 Core 仓库的 [rust-core-api.md](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md) 与 [logging-v2.json](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/diagnostics/logging-v2.json) 持有，本笔记不另建字段手册。

### 引擎声明身份，不拆分 provider ID

同一个引擎承载语言服务、版本管理、构建、工具链和插件后端，provider ID 可能含冒号，不能直接成为目录段。宿主显式传 `role` 和 VCS 的 `logSubject`，Core 校验身份后选择事件族：语言服务用 `lsp.*`，VCS 用 `vcs.*`，其他插件进程用 `plugins.host.*`。目录模板和必填身份字段仍然唯一决定通道。

合法的语言 ID 不等于合法的路径段。遇到非法段或缺少身份时，Core 用原始身份的 SHA-256 前 32 位小写十六进制，加上 `invalid-` 前缀。这样既不阻断进程启动、不静默丢日志，也不把原文泄漏成目录名。

正确做法：VCS 宿主从已注册的目录传 `role:vcs, logSubject:git`。
不要这样做：拆开 `vcsProvider:<plugin>:<vcs>` 来猜身份。

启动之前的宿主事实也必须落到同一通道：宿主调用纯命令解析引擎日志身份，Core 复用启动时的身份计算，宿主不自行拼段。解析失败只是不发对应的宿主事件，不改变既有的启动和缓冲行为。

### stderr 与上游通知

`window/logMessage` 和 `window/showMessage` 按上游明确给出的严重度选择独立的目录事件：error 为 ERROR，warning 为 WARN，info 为 INFO，详细或未知类型为 DEBUG。未分类的 stderr 只是 DEBUG 级别的排障证据，不能因为输出在标准错误流就标成警告；进程或协议的最终失败在实际失败的边界记录 ERROR。其他通知只记录方法，不把协议正文变成 text。

stderr 读取状态最多保留 4 KiB 的半行，按 LF 切分，去掉末尾 CR，忽略空行，在 EOF 时冲刷残余；每个单调秒接纳 200 行，之后的行汇总为丢弃计数。上游 trace 默认关闭，只接纳限长并脱敏的摘要，排除可能含 RPC 原始载荷和源码的 verbose。详细诊断开启时，握手完成后才发送 `$/setTrace`；不要在注册时立即发通知，否则严格遵循 LSP 的服务器会丢弃它。

### 生命周期事实

会话生命周期状态由 Core 持有：`*.session.updated` 直接附到已有的状态变化事件上，复用同一套目录校验，不额外推送旧格式的日志行。宿主只拥有启动编排的阶段（requested、resolving、registered、stopping、cancelled）和缓存清理（removed 计数），两者都是 DEBUG，因为它们描述内部阶段和维护信息。ready 和 terminated 由 Core 的事件表达，宿主不重复记录。

### DAP：记录状态与失败，保留程序内容边界

调试适配器协议（DAP，调试器与宿主交换控制消息的协议）的共享状态由 Core 持有，因此会话开始、初始化完成、结束和操作失败都由调试引擎在真实转换点记录。通道使用校验后的适配器身份；不适合路径的身份使用稳定 SHA-256 摘要，不能让项目路径或显示名称进入通道。

生命周期关键里程碑为 INFO，暂停、运行等内部状态为 DEBUG，超时与适配器拒绝为 ERROR。取消和过期引用仅为 DEBUG，不把正常取消写成产品故障。

正确做法是 Core 根据错误码记录稳定分类；不要把 adapter stderr、DAP 响应 message、调试变量、内存、源码或被调试程序输出塞入 text 或 error。

### 辅助 crate 经注入的函数指针进入 Core 队列

git-host、ide-host 和 lithe-remote 的客户端链接进 Core。Core 依赖它们，它们不能反过来依赖 Core 的事件队列，否则形成循环依赖。因此每个辅助 crate 只带一个 `failure_log` 模块，公开本 crate 用到的事件 ID 列表和一个安装函数。Core 在启动时把三个指针都指向同一个转换函数，转换函数把字段交给事件队列。

未安装时辅助 crate 只累加未注入计数，不回退到 stderr：askpass 等入口的标准输出和错误输出本身是协议或用户可见输出，回退会污染它们。

收尾失败按错误类别区分。对端已断开、进程已退出这类“对象已经不在”的情况属于预期的缺失，不记录。权限不足、超时后进程仍在运行、清理目录失败等真正留下残留的情况记录 WARN。处理凭据的 askpass 写回失败只记录阶段和错误类别，写入后把凭据字节清零。

### 声明式插件：由执行方代记同一组操作事实

声明式插件（只在清单里声明语言服务器、调试适配器或构建命令，没有自己的后端进程）无法发送 `lithe/log`。如果不处理，这类插件出错时，`plugins/<id>/host` 通道里什么都没有。因此谁真正执行声明的工作，谁就替插件写那一条终态事实：事件仍是 `plugins.operation.finished|failed`，通道仍是 `plugins/<id>/host`，和 SDK 插件写出的事实在同一处、同一格式。

Core 有一个通用结构（插件 ID、贡献、失败阶段、耗时、可选 op），差异只在一张贡献映射表里：每一行给出操作名和生命周期（常驻进程启动，或一次性命令）。生命周期持有“阶段到 `host.*` 码”的表，同一个码在所有共享该生命周期的贡献中只有一个含义；某个生命周期到不了的阶段直接拒绝，不会被猜成别的码。新增声明式契约时，开发者加一行映射，并在实际执行它的地方开始和结束一次 attempt，不新增事件、通道或错误码。

一次 attempt 只有第一次终态生效。取消、停止、被新请求取代的过期结果都不记录，因为它们不是插件故障；错误码只来自阶段，从不解析本地化错误文本，也不带插件输出、路径或命令行。

正确做法：在真正调用启动之前推进阶段，失败时以阶段结束。
不要这样做：在 catch 里按本地化的错误文本判断是哪一步失败，或在宿主里按插件名写分支。

### 保留以完整会话为主，Core 只计算删除计划

年龄和总量策略按完整会话删除：先删过期的，再从最老的会话开始释放空间。当前会话的所有文件始终受保护，预算可能暂时无法满足。单通道以 10 MiB 为轮转阈值，共保留三段（含活动文件）。

保留计划的默认值为 30 天、总量 100 MiB、性能 20 MiB、每插件每会话 files 20 MiB。Core 接收平台采集的文件清单和显式时间，返回相对路径计划；平台执行删除并报告真实的 I/O 结果，不能把计划当成删除成功。

## 考虑过的备选方案

- **JSON Lines**：通用解析方便，但每行都重复键名和身份信息，手工阅读噪声多。采用有严格语法和 fixture 的单行文本。
- **平铺文件加 scope**：不能同时自然表达会话保留和插件证据边界。
- **手写字符串 API**：字段、级别和事件身份只能靠约定，编译器发现不了漂移，因此改用共享声明和生成类型。
- **每个插件自带宿主 writer**：线程、队列、脱敏和预算会分裂。插件原生文件只能进入宿主管理的独立 files 区。
- **在编辑器标签页查看日志**：会把应用级证据绑定到项目，因此改为应用级日志窗口。
- **辅助 crate 依赖 Core 直接记录**：会形成循环依赖。把事件队列拆成第三个公共 crate 可以解开循环，但目录校验和脱敏都在 Core，拆出去要么复制规则，要么只搬走一个空壳队列，不如注入一个函数指针简单。
- **辅助 crate 未注入时回退到 stderr**：askpass 等入口的输出是协议的一部分，回退会污染协议。
- **只记录失败**：失败日志无法回答“用户点了之后到底执行了什么”。成功轨迹按来源分级：用户操作的成功是 INFO，后台的成功是 DEBUG。
- **在宿主的每个 Core 调用点记录请求**：需要逐个改调用点，新调用点很容易漏掉。改为在 Core 分发处记录一次，宿主只传 `origin`。
- **只在宿主侧过滤 DEBUG**：后台 DEBUG 会先占满 Core 队列，之后的 WARN 和 ERROR 被丢弃，因此必须在入队前过滤。
- **为声明式插件单独起一个监听服务进程**：它看不到真实的阶段边界，只能事后解析输出。由执行方在边界处直接记录更准确。
- **解析错误消息判断失败阶段**：消息是本地化文本，也可能带路径和插件输出，阶段必须由代码路径显式推进。

## 后果

收益：

- 路径、格式、查询和删除选择都可以独立验证。
- 事件身份和字段在生成阶段就能审查。
- 一次 Bug 报告的日志能顺着同一个 op 看到用户操作、Core 请求和 Git 命令的参数、退出码和 stderr。
- 新增的 Core 请求和 Git 调用不需要逐个接入日志。

代价：

- 需要维护生成器、单行编解码器和用法门禁的例外名单。
- 每个用户入口都要选一个稳定 id 并包在最外层。
- 新增按键、每帧或轮询类 Core 方法时，必须同步更新 `request_trace::is_hot`，否则每次按键都会产生一条记录。
- Core 开始依赖某个 Git 命令新的文档化退出码时，必须同步更新 `exit_is_answer`，否则成功的回答会被记成 WARN。
- 平台仍要承担有界队列、时间和序号、文件句柄、真实 I/O 失败和导出冻结的责任。

## 验证

桌面端：

- `scripts/desktop/desktop-go.sh test ./internal/logstore/ ./internal/logwindow/`：写入器、收集、查询、保留与日志窗口的操作视图。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：日志文件不写入发行目录。
- `scripts/agent-notes/verify-agent-notes.sh`

Core 仓库根运行（当前 Core 的测试入口）：

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core diagnostics`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core core_request_traces`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core command_trace`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core plugin_operations`

fixture 覆盖往返、转义、非法输入、路径段、轮转与保留、查询的不完整性。“整机验收通过”不能由上述命令推定，应以功能矩阵记录的真实证据为准。

## 适用范围

- `desktop/internal/logstore/`
- `desktop/internal/logwindow/`
- Core 仓库的诊断与轨迹实现：[diagnostics/](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/diagnostics)、[git/command_trace.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/command_trace.rs)、[runtime/dispatcher.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/runtime/dispatcher.rs)、[debug/engine.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/debug/engine.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/diagnostics/logging-v2.json`
- `shared/platform-feature-matrix/features/lsp-status-logs.json`
- `shared/platform-feature-matrix/features/diagnostics-export.json`
