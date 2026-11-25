# 日志接入

新增、迁移或审查日志事件、写入器、诊断采集、界面警告、用户操作入口，以及任何丢弃错误的代码时遵守本页。通用规则见
[Lithe 开发规范](../SKILL.md)；路径均相对于仓库根目录。

事件声明、通道模板、字段编码、限额、Core 事件队列和 Core 执行轨迹的规则来源是 Rust Core 的
`rust/logging/README.md`，以 `scripts/desktop/build-desktop-core.sh` 的 `PINNED_CORE_REVISION` 固定的修订为准；
本地读 `scripts/desktop/desktop-go.sh` 链接的 Core 检出（`LITHE_CORE_RUST_DIR`）里的同一文件。本页规定桌面端
（`desktop/`，Go）什么必须记录、怎样设计一条日志、执行轨迹怎样接入，以及豁免和审查动作；不另列一套会漂移的语法或参数表。

判断一次失败是否要记录，只问一个问题：**这次失败有没有丢掉数据、能力或清理结果。** 丢了就记录；什么也没丢、只是目标本来就不在了，就属于第二节的例外。

判断一次操作要不要留下轨迹，只问另一个问题：**维护者拿到诊断包时，能不能看出用户按了什么、Core 执行了哪些请求、启动了哪些外部命令、各自怎样结束。** 这三层由第七节的执行轨迹统一记录，业务代码不再逐处补写。

## 一、必须记录的情形

下表中的情形必须记录一条目录事件。失败类情形在处理边界记录；处理边界是决定重试、降级、回退、放弃或告知用户的那一层，不是返回错误的最底层。

| 情形 | 级别 | 要求 |
| --- | --- | --- |
| 用户从菜单、快捷键、命令面板、标题栏、按钮、右键菜单、通知、插件动作或拖放发起操作 | INFO | 最外层入口调用 `performed` 记录一次 `app.action.performed`，它开始的 op 贯穿后续的宿主记录、Core 请求和外部进程（第七节）。 |
| 每个 Core 请求、Core 启动的每个 Git 进程 | 用户来源成功为 INFO，其余成功或取消为 DEBUG，失败为 WARN | Core 在请求分发处和进程执行点各记录一条终态（第七节）；宿主不为同一请求或进程另记一条。 |
| 用户请求的操作或用户依赖的功能没有完成 | ERROR | 在拥有处理决定的边界用 `operationFailed` 记录一次 `app.notification.operation_failed`，与提示出自同一 op。 |
| 宿主在执行前拒绝了用户的操作并告知原因（对象已不在、结果已过期、不支持） | WARN | `operationRejected` 记录 `app.notification.operation_rejected`，`reason` 是固定 token。 |
| 窗口自己运行的后台工作失败，宿主降级、回退或使用缓存与默认值继续 | WARN | `backgroundFailed` 记录 `app.background.operation_failed`；不得用 `operationFailed` 把后台降级记成 ERROR。 |
| 显示给用户的错误和警告：通知、弹窗、行内错误、状态栏错误 | 按处理结果 ERROR 或 WARN | 与提示出自同一边界、同一 op。提示文案走 i18n，事件消息是目录里的英文事实，两者分开维护。只有界面提示、没有日志的警告和错误不得合入。 |
| 失败后自动恢复，或重试后成功 | WARN | 记录尝试次数和最终结果；不逐次记录每一次重试。 |
| 重试耗尽后放弃 | 用户受影响时 ERROR，否则 WARN | 一条终态，带尝试次数和最后一次错误。 |
| 清理、关闭、终止失败，留下了残留（文件、目录、仍在运行的进程、未释放的远端资源） | WARN | 记录阶段和稳定错误类别。超时后仍未退出的进程可能成为孤儿进程，必须记录。 |
| 丢弃错误的写法（`_ =`、`_, _ =`、只有 `return`/`continue`/`break` 的 `if err != nil`、只检查不使用的错误） | 按上面各行判断 | 记录事件，或者属于第二节的例外并写豁免标记。 |
| 上游组件报告的警告和错误（LSP `window/logMessage`、语言服务器 stderr、插件会话事件） | 按上游严重度映射 | 由 Core 映射为目录事实，宿主按 7.8 转发，不另建自由文本通道。 |
| 生命周期里程碑和有排障价值的操作终态 | INFO | 只记里程碑和终态，不记每个内部步骤。 |

“用户受影响”按处理后的结果判断：内部重试后成功记 WARN，最终没有完成用户请求记 ERROR。不得把上游的 ERROR 标签机械地升级成产品 ERROR，也不得用 INFO 掩盖真正的失败。Core 轨迹的失败固定为 WARN，原因见 7.6。

日志写入器自身的失败（写盘、轮转、句柄关闭、队列溢出）不能经过它自己记录。写入器把这类失败计入 `Stats()` 的丢弃和写入失败计数，导出诊断包时写进 `collection-status.txt`；不得为此另开 stderr、`log`/`slog` 或第二个写入器。

## 二、不记录的例外

只有以下四类可以不记录。例外是封闭清单，不得自行扩充；需要新类别时先修改本页并说明理由。

1. **用户取消。** `context.Canceled`、`app.ErrCanceled`（原生选择器被关闭）等由用户或调用方主动取消的结果不是失败；关闭项目、关闭窗口、新输入取代旧请求结束的 context 也属于取消。`context.DeadlineExceeded` 是超时，不是取消，必须记录。取消之后的清理如果失败，清理失败仍然按第一节判断。Core 轨迹把取消记成带 `cancelled` 的成功终态，不记成失败。
2. **预期的缺失。** 目标本来就不在，调用方按“没有”处理，并且这正是正常路径。包括两种情况：
   - 探测可选的文件、配置、缓存或功能时目标不存在（`fs.ErrNotExist`、`os.ErrNotExist`）。
   - 收尾时操作的对象已经不在：对端已经断开、子进程已经退出、连接已经关闭、要删除的文件已经不存在。典型错误是 `io.EOF`、`net.ErrClosed`、`os.ErrProcessDone`、`syscall.EPIPE`、`syscall.ECONNRESET`、`fs.ErrNotExist`。

   只有这些类别属于缺失。权限不足、格式损坏、读到一半失败、超时后对象仍然存在，都不属于缺失，必须记录。
3. **随输入实时重算的校验提示。** 表单里随键入即时更新、不阻断已经发生的操作、不反映系统状态的提示（例如“名称不能为空”）。提交后真正失败的操作仍然必须记录。
4. **同一次失败已经记录过。** 下层处理边界、同一 op 的 Core 请求或进程轨迹，或同一代码路径上导致这次收尾的那次失败已经记录过。不得再记录一次，见第六节。

按错误类别判断例外时，用 `errors.Is` 在一个辅助函数里集中过滤：只放过上面列出的类别，其余类别照常记录。不要在每个调用点复制一份判断，也不要因为“收尾失败通常无害”把整个调用点豁免掉。拿不到错误类别、确实无法区分正常收尾和异常时，才整体豁免，并在原因里写明为什么无法区分。

属于以上例外时，在同一行或紧邻的上一行写豁免标记，类别必须逐字取上面四类的名称，后面写具体原因：

```go
// log-exempt: 预期的缺失：缺失的配置文件是未覆盖的空来源。
if errors.Is(err, fs.ErrNotExist) {
	return nil, nil
}
```

```go
// log-exempt: 用户取消：关闭原生文件选择器不修改草稿。
if errors.Is(err, app.ErrCanceled) {
	return
}
```

原因要写清楚是什么已经不在了或者为什么不是失败。“不重要”“忽略”“暂时”“旧代码”不是原因。豁免标记只用于丢弃错误；绕过写入器的输出没有豁免方式（第十节）。

## 三、如何设计一条日志

按以下顺序设计，每一步的答案都要能写进事件声明或代码审查说明。

1. **先写下读者的问题。** 维护者拿到用户附在 Issue 里的诊断包时，要靠这条日志回答什么问题？例如“Git fetch 为什么失败、失败在哪个远程、用了多久”。回答不了具体问题的日志不要加。先查第七节的执行轨迹是否已经回答了这个问题；已经回答的不要再加。
2. **确定事实和终态。** 一条事件描述一个已经发生的事实，事件 ID 的结果词用过去时（`start_failed`、`operation_failed`）。一个操作只产生一条终态。
3. **确定 owner 和通道。** owner 是拥有这次操作结果的模块；通道由目录模板和已校验的身份决定（`lsp/{server}`、`vcs/{provider}`、`plugins/{plugin}/host`），不按显示名称、路径或用户输入分通道。宿主不传通道，Core 按模板推导。
4. **按处理后的影响选级别。** 用第一节的表，不按“看起来严重”选级别。
5. **选最窄的字段类型。** 计数、耗时、体积用数值；阶段和结果用受控 token；失败用 `core.LogErrorFields(err)` 保留稳定 code 和 domain。不把结构化信息拼进消息（第八节）。
6. **用 op 串起同一操作。** 用户入口由 `performed` 生成 op，宿主记录、Core 请求和外部进程沿用它。用户在日志窗口里按 op 过滤，能看到同一操作的全部记录及相对耗时；每层重新生成编号会切断这条链。
7. **控制频率。** 循环、逐按键、逐帧、逐连接路径不用 INFO 逐项记录；需要时用 DEBUG 或在发送侧有界汇总，并按目录声明 rate。高频 Core 方法列入 `is_hot`（7.3）。
8. **在日志窗口里验证。** 触发一次真实场景，在日志窗口（⇧⌘L）中按通道和事件过滤能找到这条记录，字段齐全、没有敏感内容，同一 op 的调用链完整。错误通知带“查看日志”时，点击能打开这个 op 的记录。

### 日志必须能定位到问题

验收看记录能否解释失败，不能只确认“有日志输出”。同一操作的事件及关联轨迹必须能回答：哪个 API 或用户操作、由哪个组件执行、失败在哪个阶段、已知的真实原因是什么，以及最终是拒绝、失败、降级还是恢复。原因尚不确定时，如实保留已经观测到的阶段和底层稳定错误类别，不得猜测根因；已经拿到具体原因时，不得仅记录“操作失败”“内部错误”“未知异常”或无上下文的 `failed`。

日志的具体性来自事件语义、受控字段及同一 op 的关联证据，不靠拼接大段异常或载荷。敏感信息按第八节使用 Core 的类型化字段和集中脱敏，保留允许记录的 API、阶段、错误类别、耗时和关联标识；不能因含有路径等敏感上下文就抹掉整个错误原因。源码、凭据、协议正文等禁止记录的内容仍不得落盘，不能以“已经脱敏”为由扩大记录范围。

插件的 `lithe/log` 仍只使用契约允许的字段；定位信息通过既有操作、稳定码和宿主关联轨迹表达，不能擅自添加 `message`、`stage`、任意 `details` 等字段。确有公共诊断缺口时，按插件 API 扩展规则补齐。验证时既检查真实失败能被定位，也检查脱敏后的落盘记录仍有这些线索，同一错误没有被重复记录。

反例与正例：

| 反例 | 问题 | 正例 |
| --- | --- | --- |
| `if err != nil { return nil }` | 失败被吞掉，诊断包里没有任何痕迹 | 在处理边界用 `backgroundFailed` 或领域事件记录，再返回降级值 |
| 通知显示“同步失败”，没有日志 | 用户报告问题时无从排查 | 同一边界、同一 op 记录 `operationFailed`；通知的“查看日志”打开这个 op，Core 的请求和 Git 进程轨迹一起出现 |
| `fmt.Sprintf("fetch %s failed: %v", remote, err)` 作为字段或消息 | 结构化信息拼进文本，未经字段脱敏 | 事件 ID 和消息来自目录，字段 `remote`（token）、`core.LogErrorFields(err)`、`<name>_ms` |
| `event := "app." + kind + ".failed"` 再传给 `emit` | 事件 ID 不是常量，目录测试读不出它，拼错的 ID 只在运行时被拒绝 | 每个分支写常量事件 ID；确实由上游在运行时选择事件的转发函数列入 `forwardedLogEvents`（第十节） |
| 适配器、服务和视图各记录一次同一个失败 | 一次失败出现三次，计数失真 | 下层返回带类别的错误，决定降级或告知用户的那一层记录一次 |
| 宿主在调用 Core 前后各记一条“开始执行 git fetch”“git fetch 失败” | 与 Core 的进程轨迹重复，且拿不到真实的 argv、退出码和 stderr | 不写；Core 在执行点记录 `vcs.git.command.*`，宿主只记自己掌握的结果 |
| 重试循环里每次失败都记 WARN | 噪声淹没真正的终态 | 一条终态带 `attempts` 和最后一次错误 |
| 关闭连接、终止子进程、取消请求时，所有失败一律记 WARN | 正常关闭每天都会触发，真正的残留反而看不见 | 辅助函数按错误类别过滤：对象已经不在的类别写豁免，权限不足、超时后仍在运行等类别记录 |
| 用户操作里直接 `go func() { … }()` 调 Core | 新 goroutine 不带操作上下文，Core 请求没有 `trigger` 和 op，结果也不在原操作下应用 | 用 `a.background(p, timeout, work)`；必须自己起 goroutine 时传 `a.operationContext(ctx)`，结果经 `a.post` 回窗口线程并由 `within` 恢复 op |
| 后台降级用 `operationFailed` | 把用户没有请求的工作记成 ERROR，用户可见失败的计数失真 | 用 `backgroundFailed` |

## 四、只使用目录里的事件

1. 先调查真实调用和消费者，确定 owner、通道身份与需要保留的事实；没有实际来源不预造事件。
2. 新增或修改事件在 Rust Core 仓库修改 `rust/logging/events/<root>.json`，按 Core README 声明稳定 ID、通道模板、英文消息、级别和字段含义。字段说明必须解释本事件中的来源、语义和单位，不能用按类型的通用短语凑说明。
3. 在 Core 仓库根运行 `node scripts/logging/generate-log-events.mjs` 重新生成 `catalog_generated.rs`，并用 `--check` 确认生成物一致；不得手改生成物。Core 改动合入后，把 `PINNED_CORE_REVISION` 升到包含它的 main commit，桌面端调用点与固定的目录同一个 PR 生效。
4. 桌面端调用时，事件 ID、级别和字段键必须是常量或在源码里可读出的值，由目录测试逐条交给链接的 Core 校验（第十节）。Go 还没有按目录生成的事件类型，恢复跟踪 [#1802](https://github.com/1lck/Lithe-IDEA/issues/1802)。不得手写第二份目录、自由消息或私有序列化与脱敏。
5. 不再有调用点的事件，从目录声明中删除并重新生成，不保留空事件。

宿主传入的事件是尚未脱敏的内存输入。落盘必须经过写入器调用的 `diagnostics.encodeLogBatch`（`validateCatalog: true`）完成目录校验、共享脱敏和编码；只通过 Go 的类型检查或 JSON 编码不能证明隐私安全。日志目录由平台可写存储提供，不从 app bundle、插件安装目录或 Windows 安装目录推导。

## 五、写入器与记录入口

每个进程只有一个日志写入器 `desktop/internal/logstore.Store`。`cmd/lithe/main.go` 用 `logstore.Open` 创建它，调用 `ObserveCoreFacts` 安装 Core 唤醒回调、`CaptureCrashes` 接住致命崩溃，再经 `workbench.DesktopOptions.Logs` 交给窗口；退出时 `Close` 删除本会话的崩溃文件，排空并写完队列。写入器打不开时客户端照常启动，没有日志窗口，“查看日志”只提示日志不可用。

| 位置 | 记录方式 |
| --- | --- |
| 窗口线程上的工作台代码 | `a.emit(level, event, fields)`，op 取当前用户操作 `a.op` |
| 其他 goroutine 上为某个操作工作的代码（设置窗口、后台任务） | `a.emitIn(ctx, …)`，op 取 `core.OriginOf(ctx).Operation` |
| 已知 op 的代码 | `a.emitAs(op, …)`；op 为空表示不属于任何操作 |
| 用户可见失败、拒绝、后台降级 | `operationFailed`/`operationFailedIn`、`operationRejected`/`operationRejectedIn`、`backgroundFailed`/`backgroundFailedIn` |
| 不持有写入器的包（`webpreview`、`pluginweb`、`termview`、`pluginservice`） | 把失败交给工作台提供的回调（`Log func(stage string, err error)`、`Failed func(Failure)`、`RecordFailed`），由工作台在处理边界记录；包自己不写日志、不回退到 stderr |
| 日志窗口自己的失败（导出等） | `logwindow.Source.Emit`，即同一个写入器 |
| Core 引擎随插件会话事件带来的目录事实 | `recordEngineFact`（7.8） |
| Core 请求处理、执行轨迹和没有请求上下文的 Core 代码 | Core 的进程级有界事件队列；写入器在每次写入批次、flush 和关闭时排空，唤醒回调再安排一次排空（7.7） |
| 链接进 Core 的辅助 crate | 本 crate 的 `failure_log` 模块，sink 由 Core 的 `runtime::helper_failures::install()` 注入；规则见 Core README |
| 被恢复的 panic：Viva 回调、Core 调进 Go 的回调（唤醒、请求的事件观察者） | `Store.RecordPanic` 记 `app.runtime.panic_interrupted`，边界写成 `viva:<位置>` 或 `core:<回调>`。它不加锁，可在任何线程、关闭途中调用：Viva 经工作台安装的 `app.SetFaultHandler`，Core 回调经 `WatchCoreEvents` 的 `recovered` |
| 没有被恢复的致命崩溃、被强制退出的会话 | `CaptureCrashes` 让 Go runtime 把崩溃报告写进本会话的崩溃文件；下次启动记 `app.session.previous_interrupted` 或 `app.session.close_missing` |

规则：

- 新增 `recover()` 边界时，把恢复的值和栈交给上表的 panic 入口，不得只恢复不记录；记录路径自身的 panic 属于写入器自身的失败，只能丢弃。
- 不得新增全局可变日志单例，不得在下层自行创建写入器，不得用 `log`、`slog`、`fmt.Fprint(os.Stderr, …)` 或 `println` 输出诊断。
- 新增构造参数、回调或接口字段用于记录失败时，同一次改动把真实实现接到每个生产构造处。`nil` 只能出现在测试里；生产路径留空等于没有记录。
- 写入器同时实现 `logwindow.Source`：日志窗口和诊断包只读取 v2 会话文件，没有 v1 缓冲。
- 被目录拒绝的事件不会落盘：写入器按事件和错误码计入 `Rejections()`，日志窗口显示被拒事件，诊断包的 `collection-status.txt` 写出 `rejected event=… code=… count=…`。出现被拒事件就是调用点和目录不一致，必须修调用点或目录。

## 六、一个操作、一条终态、一个错误处理边界

- 一个操作只有一条终态。不要在开始时记一条、结束时再记一条；需要耗时时在目录里给终态声明 `duration` 字段，宿主传磁盘键 `<name>_ms`，用单调时钟（`time.Since`）计算，不用墙钟差值。
- 目录里的 span 事件（`app.shell.environment`、`editor.sync.freeze`、`run.process.execution`）在 Go 里还没有 span 辅助，桌面端不得手工拼 begin/finish 两条记录来模拟 span；采用方式由单独的 Issue 决定。
- 有实际操作上下文时用同一个 op，持久化层用 `op` 关联跨模块证据。不得把 op 重新声明为普通字段，不得用用户内容作为操作编号。
- 错误只在处理它的边界记录一次。下层把错误和稳定分类返回；上层决定恢复、降级或告知用户时记录。不得“记录后再返回”。
- 一次失败引发的后续收尾失败，属于第二节第 4 类，不再单独记录。
- Core 请求和外部进程的终态由 Core 记录，不属于任何宿主调用方。宿主只为自己掌握的结果记录终态（7.6）。

## 七、执行轨迹：用户操作、Core 请求与外部进程

执行轨迹回答“用户按了什么、Core 执行了什么、外部命令怎样结束”。它分三层，由同一个 op 串起来：

| 层 | 事件 | 由谁记录 | 级别 |
| --- | --- | --- | --- |
| 用户操作 | `app.action.performed`（通道 `app`） | 最外层 UI 入口的 `performed` 或 `performedIn` | INFO |
| Core 请求 | `app.core.request.finished` / `.traced` / `.failed`（通道 `app/core`） | Core 请求分发处 `rust/crates/core/src/runtime/dispatcher.rs`，实现在 `rust/crates/core/src/runtime/request_trace.rs` | 用户来源的成功或取消为 `finished`（INFO）；后台或未知来源的成功或取消为 `traced`（DEBUG）；失败为 `failed`（WARN） |
| 外部进程 | `vcs.git.command.finished` / `.traced` / `.failed`（通道 `vcs/git`） | Core 的 Git 进程执行点 `rust/crates/git/src/command_trace.rs`，本地和远程工作区都经过这里 | 来源为用户的可见命令（定义见 7.4），成功或取消为 `finished`（INFO）；其余成功或取消为 `traced`（DEBUG）；失败为 `failed`（WARN） |

### 7.1 用户操作入口

- 每个用户入口在最外层调用 `a.performed(action, surface)`（`desktop/internal/workbench/app.go`）。它生成新的 op（`core.NewOperation()`），记录一条 `app.action.performed { action, surface }`，并把操作设为窗口线程的当前操作 `a.op`。窗口回调返回时 `operating` 结束这次操作，它不会漏进下一次绘制或刷新。
- `performed` 会覆盖当前操作，没有嵌套保护：入口只调用一次，共用的模型方法里不再调用。命令统一在 `startCommand` 记录 `command.<命令 id>`，命令的实现不再另记。
- 在窗口线程之外由用户发起的操作（例如设置窗口）用 `ctx = a.performedIn(ctx, action, surface)`：它不碰窗口线程的 `a.op`，op 放进返回的 context，后续用 `emitIn(ctx, …)` 记录，用这个 ctx 发 Core 请求。
- action 是稳定的 catalog token：1 到 64 字节，字符为 ASCII 字母数字和 `._:/-$`。不得使用本地化标题、文件名、分支名或任何用户内容。命名按 `<领域>.<对象>.<动作>`，例如 `build.task.run`、`debug.breakpoint.remove`、`logs.openOperation`。
- surface 只能取 `actionSurface` 常量：`surfaceMenu`、`surfaceShortcut`、`surfacePalette`、`surfaceToolbar`、`surfaceButton`、`surfaceContextMenu`、`surfaceNotification`、`surfacePlugin`、`surfaceDragDrop`，按用户实际操作的位置选。新增 surface 先在 Core 目录的 `surface` 字段加 token。
- 只记录用户主动发起的入口。定时刷新、文件监听、窗口恢复等自动行为不调用 `performed`，它们的 Core 请求按后台来源记录。

### 7.2 跨越异步边界

- `a.background(p, timeout, work)`（`tasks.go`）是为操作启动后台工作的唯一方式：work 的 context 携带当前操作（`operationContext`），返回的结果函数回到窗口线程后由 `within` 在原操作下应用，结果里的失败因此记在引起它的操作下。p 不为空时 context 随项目关闭结束，项目关闭或替换后到达的结果被丢弃。
- 必须自己管理 goroutine 时（流式读取、长期会话），在离开窗口线程前用 `a.operationContext(ctx)` 取上下文，goroutine 里用 `emitIn(ctx, …)` 记录，结果经 `a.post` 回窗口线程。不得把 `a.op` 存进字段留到以后使用，也不得在 goroutine 里读 `a.op`。
- 桌面客户端为每个 Core 请求附上可选的 `origin`（`desktop/internal/core/origin.go` 的 `requestOriginOf`）：ctx 不带操作且不是自动刷新时不附带；`core.AutomaticRefresh(ctx)` 标记的 Git 自动刷新记 `source: "background"`，即使由操作触发也一样，Core 因此不把它的内部查询记成用户工作；其余带操作的请求记 `source: "user"`、`trigger` 和 `operation`。
- Core 在请求开始时把 op 和来源放进线程局部上下文，同一请求里启动的 Git 进程自动继承。op 依次取 `origin.operation`、请求的 `operationId`、请求 `id`。

### 7.3 Core 请求轨迹

- 每个 Core 请求在分发处记录一条终态，覆盖所有宿主、工作区、插件和按钮背后的调用。宿主和领域代码不得为“请求开始”“请求完成”另加日志。
- 记录的字段、`path` 的取法和不记录载荷其他内容的规则以 Core README“执行轨迹事件”一节为准。
- 按键、每帧、轮询和监听批次触发的方法列入 `request_trace::is_hot`，不记录。新增这类 Core 方法时必须在同一个 Core 改动里加入列表。`diagnostics.*` 和 `core.ping` 永远不记录：日志系统不得记录自己的排空、查询和编码调用。

### 7.4 外部进程轨迹

- Core 启动的每个 Git 进程在执行点记录一条终态。可见命令指作为 invocation 返回给宿主、显示在 Git 控制台的命令；内部读取指 Core 自己解析输出的命令，即使在用户操作中，内部读取的成功或取消也只记 `traced`。
- argv 只能经过 `command_trace::format_arguments` 进入日志，stderr 只保留脱敏后的末尾几行，stdout、stdin 和进程环境永远不记录；具体的脱敏、截断和行数规则以 Core README 为准。
- 退出码按文档表示“回答”而不是错误的（`exit_is_answer`，如 `git config --get` 的 1）为成功。Core 开始依赖某个命令的另一个文档化退出码时，在同一次改动里给 `exit_is_answer` 加一行。
- 将来为其他外部进程增加轨迹时，沿用同一模型：在执行点记录唯一终态，argv 只经过一个集中的脱敏格式化函数，stderr 只保留脱敏后的末尾几行。

### 7.5 插件声明式贡献的代记

插件声明、由宿主启动的贡献（`languageServer/start`、`debugAdapter/start`、`lithe/build/model`、`lithe/build/dependencies`），启动结果由宿主代插件记录，规则见 Core 的 `rust/contracts/rust-core-api.md`。桌面端的做法固定为：

- 开始时 `attempt := core.StartPluginAttempt(pluginID, operation, core.OriginOf(ctx).Operation)`，结果记在操作的 op 下；没有合法 op 时自动生成一个。
- 结束时调 `pluginservice.Service.EndAttempt(ctx, attempt, stage, err)`，stage 取 `plan`、`resolve`、`launch`、`initialize`、`timeout`、`exit`、`decode` 中失败所在的阶段；`err == nil` 记为完成。一次尝试最多产生一条结果，用户取消不记录，截止时间到达记为 `timeout`。
- 语言服务器交给 Core 启动时，用 `attempt.HandOff()` 生成 `lsp.startServer` 的 `startupOperation`，之后的结果由 Core 记录，宿主不再记录。
- Core 拒绝这条代记时，宿主用 `backgroundFailedIn(ctx, "plugin_operation_record", err)` 记录。插件经 provider 请求自己完成的操作由插件自己记录，宿主不代记。

### 7.6 失败级别与宿主边界

- Core 轨迹的失败固定为 WARN：Core 不知道宿主会重试、降级还是放弃，ERROR 留给知道结果的那一层。
- 宿主的 ERROR（`app.notification.operation_failed`）记录的是宿主自己的结果：用户的哪个操作没有完成。它和 Core 的失败轨迹共用 op，因此不重复 argv、退出码、stderr 这些 Core 已经记下的事实；`operation` 字段写宿主的操作 token，错误字段来自 `core.LogErrorFields(err)`。
- 宿主只在掌握 Core 没有的事实时才多记：降级到哪条路径、重试了几次后放弃、留下了什么残留。

### 7.7 DEBUG 门、唤醒与详细诊断

- Core 在入队前丢弃宿主没有开启的 DEBUG 事实。写入器只在详细诊断状态变化时调用 `diagnostics.configureCoreEvents { debug, roots }`；调用失败时记录一次 `app.logging.diagnostics_failed`，状态再次变化后才重试。只在宿主侧过滤会让后台 DEBUG 占满 Core 的有界队列，之后的 WARN 和 ERROR 会因此丢失。
- Core 代码构造字段前先调用 `core_events::accepts(level, root)`，被拒绝的事实只花一次分支判断。
- 只有应用写入器调用 `ObserveCoreFacts` 安装 Core 唤醒回调。回调只唤醒写入器，写入器合并 100 毫秒内的唤醒做一次排空；关闭时先移除回调再做最后一次排空。不得为 Core 队列增加空闲轮询定时器，也不得在响应里再加待取标记。
- 同一个详细诊断开关经 `WatchDiagnostics` 驱动插件会话的 `lsp.setDetailedDiagnostics`：正在运行的会话和开启期间新启动的会话都跟随，15 分钟后自动关闭。拒绝切换的会话每次选择只记录一次 `app.logging.diagnostics_failed`（`traceFailed`），不论有几个会话拒绝；期间已经结束的会话不算失败。

### 7.8 引擎事实与插件日志目录

- Core 在插件会话的运行时事件上附带的目录事实（`event`、`catalogLevel`、`fields`：语言服务器的 stderr 行和 logMessage、provider 生命周期、会话退出和停止），在按事件类型分支之前由 `recordEngineFact` 原样转发一次，不属于任何用户操作。Core 已经按目录校验和脱敏，宿主不增删字段。
- 插件进程自己的日志文件写在 `PluginFilesDirectory(ctx, pluginID)` 给出的目录：写入器在本次会话目录下创建 0700 的插件目录，逐段拒绝 `.`、`..`、符号链接和特殊文件。本地语言服务器和后端启动时把它作为 `request.logDirectory` 传给 Core，插件以 `${logDir}` 引用；目录不可用时宿主记录 `app.background.operation_failed` 并省略它，远程请求不传。

## 八、字段选择与隐私

选择能表达事实的最窄类型，不把结构化信息拼进消息或自由文本。宿主传入的是磁盘键和 JSON 值，单位与编码以 Core README 为准：

| 信息 | 选择原则 |
| --- | --- |
| 计数、开关、耗时、体积 | 整数、布尔值；耗时用 `<name>_ms` 的整数毫秒，体积用字节数。 |
| 身份、阶段、版本 | 身份用 id；受控短词用 token；版本用 version。id 必须来自已验证的真实身份，字符合法不等于来源可信。 |
| 文件位置 | 传原始路径，由 Core 按目录脱敏，不自己拼或改写用户绝对路径。 |
| 失败 | 用 `core.LogErrorFields(err)` 得到 `error`、`error_code`、`error_domain`，不传未清理的整段错误转储。 |
| 无法结构化的上游诊断和外部进程命令行 | 仅在必须保留 stderr 行、LSP logMessage 等上游原文，或经第七节集中格式化函数脱敏的 argv 时使用 text，并在声明中写 reason 说明结构化字段为什么不能代替；“方便调试”不是理由。 |

不得记录源码、编辑缓冲区、文件内容、提交说明正文、环境变量值、进程的 stdout 与 stdin、凭据、终端历史或协议正文，也不得把它们塞进 text、error、token、路径或消息绕过。处理凭据的代码路径记录失败时，只记阶段和错误类别，并用测试证明凭据不会出现在事件字段里。

每个动态通道段必须能追溯到已校验的插件、provider、server 或内部连接 ID，不得使用主机名、显示名称、项目路径和任意用户输入。

## 九、界面提示与日志的对应

- 每个显示给用户的警告和错误都对应一条事件，出自同一边界、同一 op。
- 用户操作期间显示的错误通知记下当前 op，带“查看日志”按钮；点击记录 `logs.openOperation`（`surfaceNotification`），日志窗口打开并按这个 op 过滤，同一操作的宿主记录、Core 请求和 Git 进程轨迹一起出现。打开日志窗口只走 `showLogs(op)`，不为某个插件或 provider 写专门分支。
- 插件发给宿主的消息和警告由宿主记入 `plugins/{plugin}/host` 通道，再按插件声明显示；插件不能绕过宿主写应用日志。
- 日志消息、事件名、通道、字段、级别名和过滤语法不翻译；提示文案、按钮和日志窗口自身的界面文字走共享 i18n。

## 十、门禁与豁免

桌面端现有的自动门禁是目录测试 `TestEveryLoggedEventIsAcceptedByTheKernel`（`desktop/internal/core/log_sites_test.go`）：

- 它扫描生产代码里所有最终到达写入器 `Emit` 的调用。级别、事件 ID 和字段键必须是常量或在源码里可读出的值，否则测试失败（“the level is not a constant”“the event id is not a constant”“the field keys cannot be read from the source”“the call chain is too deep to follow”）。
- 每个调用点按读出的事件、级别和字段键构造一条事件，交给链接的 Core 用 `diagnostics.encodeLogBatch`（`validateCatalog: true`）校验；目录里不存在的事件、级别不符或字段不符都会失败。
- `surface` 只能取 `actionSurface` 常量，并且必须在目录的 token 列表里（`checkActionSurfaces`）。
- 在运行时选择事件的转发函数必须列入 `forwardedLogEvents`，并写明它会转发哪些事件；不再转发的条目也会让测试失败。

目录测试只保证调用点与目录一致。它识别不了以下问题，由审查保证，等价的用法门禁恢复跟踪 [#1802](https://github.com/1lck/Lithe-IDEA/issues/1802)：

- 绕过写入器的输出（`log`、`slog`、`fmt.Fprint(os.Stderr, …)`、`println`）。唯一的例外是 `cmd/lithe/main.go`：写入器打不开时和启动失败退出前写 stderr，这两处此时没有写入器可用。
- 丢弃的错误没有记录也没有豁免标记，豁免标记的类别不属于第二节的四类。
- 界面提示没有对应日志、用户入口没有 `performed`、异步跳转丢失操作上下文、收尾失败没有按错误类别区分。

不得利用包装函数、动态拼接或反射逃避目录测试，也不得为了通过测试放宽扫描范围或规则。

## 十一、验证

- 修改桌面端的日志调用：从 `desktop/` 运行 `../scripts/desktop/desktop-go.sh test ./internal/core -run TestEveryLoggedEventIsAcceptedByTheKernel`，以及改动所在包的测试。
- 修改 Core 的目录、编码或执行轨迹：在 Core 仓库运行 `node scripts/logging/generate-log-events.mjs --check` 和受影响 crate 的测试；执行轨迹的测试在 `rust/crates/core/src/tests/core_request_traces.rs` 和 `rust/crates/git/src/command_trace.rs` 的测试模块。再用 `LITHE_CORE_RUST_DIR` 指向这份 Core 检出运行桌面端的目录测试，确认桌面端调用点仍被接受。
- 修改写入器：运行 `desktop/internal/logstore` 和 `desktop/internal/logwindow` 的测试，包括 `-race`。
- 按错误类别过滤的辅助函数必须有测试：对象已经不在的类别（例如 `net.ErrClosed`、`syscall.EPIPE`）不发事件，意外类别（例如权限不足）发事件。
- 新增或修改用户可见的警告和错误、用户入口时，按第三节第 8 步在真实应用的日志窗口里确认记录存在、字段正确、同一 op 的链条完整、“查看日志”能打开这个 op；无法在本机验证时在 PR 说明中写明。

## 十二、审查清单

- 第一节的每种情形都有事件：界面警告和错误、拒绝、降级、回退、自动恢复、重试耗尽、留下残留的清理失败、丢弃的错误。没有只出现在界面上的警告。
- 用户可见失败用 `operationFailed`，后台降级用 `backgroundFailed`，执行前拒绝用 `operationRejected`，级别没有混用。
- 新增的用户入口在最外层调用一次 `performed`，action 是稳定 token 而不是本地化标题或用户内容，surface 是与实际位置一致的 `actionSurface` 常量；窗口线程之外的入口用 `performedIn`。
- 为操作启动的后台工作经 `background` 或 `operationContext` 携带操作，goroutine 里用 `emitIn`，没有裸 `go func()` 丢掉 op，也没有在 goroutine 里读 `a.op`。
- 没有为 Core 请求或 Git 进程另写开始、完成或失败日志；新增的高频 Core 方法已列入 `is_hot`；Core 新依赖的文档化退出码已加入 `exit_is_answer`。
- 插件声明式贡献的启动经 `StartPluginAttempt`/`EndAttempt` 代记，阶段正确，交给 Core 的启动用了 `HandOff`。
- 豁免标记属于第二节的四类之一，类别名逐字一致并写明具体原因；收尾类失败按错误类别过滤，`context.DeadlineExceeded` 没有被当成取消。
- 事件有真实来源和 owner，级别按处理后的用户影响选择；高频路径没有 INFO 逐项输出。
- 事件先在 Core 目录声明，`PINNED_CORE_REVISION` 指向包含它的修订；事件 ID、级别、字段键是常量；没有第二套写入器、`log`/`slog` 或直接打印；没有残留无调用点的事件。
- 新增的记录回调或接口字段在每个生产构造处都接上真实实现；`nil` 只出现在测试中。
- 同一操作只有一条终态；错误只在处理边界记录一次，op 贯穿调用链。
- 动态段来源可信并经过校验；字段类型最窄，错误用 `core.LogErrorFields`，没有用 `fmt.Sprintf` 拼出的消息或字段；没有禁止记录的内容。
- 目录测试通过，日志窗口里没有被拒事件。
- 写入、查询、保留和导出保持有界，文件位于平台可写存储；Core 队列没有新增轮询。

当前决策见 `.agents/notes/implemented/architecture/2026-11-03-structured-logging-channels.md`。
