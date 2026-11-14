# 日志接入

新增、迁移或审查日志事件、写入器、诊断采集、界面警告、用户操作入口，以及任何丢弃错误的代码时遵守本页。通用规则见
[Lithe 开发规范](../SKILL.md)；路径均相对于仓库根目录。

事件声明、字段编码、限额和 Core 事件队列以固定修订的 [Lithe-core-rust 日志目录说明](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/shared/logging/README.md) 为规则来源。本页规定什么必须记录、怎样设计一条日志、执行轨迹怎样接入，以及豁免和审查动作，不另列一套会漂移的语法或参数表。

> Viva 迁移状态：本仓库已移除旧 `shared/logging/`、Swift/Tauri 实现和 `scripts/logging/`；
> 事件目录现在位于固定 Core 仓库，Viva 经 `desktop/internal/core/logging.go` 和
> `desktop/internal/logstore/` 接线。下文旧客户端与旧脚本名称保留为历史约束，不能直接
> 作为当前命令或验收证据；等价生成及使用门禁未恢复前，相关检查必须标为未完成，
> 不得静默跳过。恢复 Viva 类型生成与使用门禁跟踪
> [#1802](https://github.com/1lck/Lithe-IDEA/issues/1802)。日志事实、隐私、失败处理和目录一致性的要求不变。

判断一次失败是否要记录，只问一个问题：**这次失败有没有丢掉数据、能力或清理结果。** 丢了就记录；什么也没丢、只是目标本来就不在了，就属于第二节的例外。

判断一次操作要不要留下轨迹，只问另一个问题：**维护者拿到诊断包时，能不能看出用户按了什么、Core 执行了哪些请求、启动了哪些外部命令、各自怎样结束。** 这三层由第七节的执行轨迹统一记录，业务代码不再逐处补写。

## 一、必须记录的情形

下表中的情形必须记录一条目录事件。失败类情形在处理边界记录；处理边界是决定重试、降级、回退、放弃或告知用户的那一层，不是抛出错误的最底层。

| 情形 | 级别 | 要求 |
| --- | --- | --- |
| 用户从菜单、快捷键、命令面板、工具栏、按钮、右键菜单、通知动作或插件动作发起操作 | INFO | 最外层入口用 `UserActionTrace` 记录一次 `app.action.performed`，它的 op 贯穿后续的 Core 请求和外部进程（第七节）。 |
| 每个 Core 请求、Core 启动的每个外部进程 | 用户来源成功为 INFO，其余成功或取消为 DEBUG，失败为 WARN | Core 在请求分发处和进程执行点各记录一条终态（第七节）；宿主和领域代码不再为同一请求或进程另记一条。 |
| 操作最终失败，用户的请求没有完成 | ERROR | 在拥有处理决定的边界记录一次；成对操作由 span 的 fail 记录。失败的全部事实已经在同一 op 的 Core 失败轨迹里时，不另记，界面提示引用那条轨迹（第七节）。 |
| 显示给用户的错误：横幅、弹窗、通知、行内错误、状态栏错误 | ERROR 或 WARN（按处理结果） | 与提示出自同一边界、同一 op；提示文案走 i18n，事件消息是英文事实，两者分开维护。提示的事实已在同一 op 的 Core 失败轨迹里时，提示引用那条轨迹。 |
| 显示给用户的警告 | WARN | 同上。只有界面提示、没有日志的警告不得合入。 |
| 功能降级、回退到备用路径、使用缓存或默认值代替失败的读取 | WARN | 记录降级原因的结构化分类和降级后的状态。 |
| 失败后自动恢复，或重试后成功 | WARN | 记录尝试次数和最终结果；不要逐次记录每一次重试。 |
| 重试耗尽后放弃 | 用户受影响时 ERROR，否则 WARN | 一条终态，带尝试次数和最后一次错误。 |
| 清理、关闭、终止失败，留下了残留（文件、目录、仍在运行的进程、未释放的远端资源） | WARN | 记录阶段和稳定错误类别。超时后仍未退出的进程可能成为孤儿进程，必须记录。 |
| 丢弃错误的写法（`try?`、只有 `return`/`break`/`continue` 的 `catch`、`.ok();`、`let _ =`） | 按上面各行判断 | 记录事件，或者属于第二节的例外并写豁免标记。 |
| 上游组件报告的警告和错误（LSP `window/logMessage`、插件宿主消息、子进程 stderr） | 按上游严重度映射 | 进入该组件已有的通道，不另建自由文本通道。 |
| 生命周期里程碑和有排障价值的操作终态 | INFO | 只记里程碑和终态，不记每个内部步骤。 |

“用户受影响”按处理后的结果判断：内部重试后成功记 WARN，最终没有完成用户请求记 ERROR。不得把上游的 ERROR 标签机械地升级成产品 ERROR，也不得用 INFO 掩盖真正的失败。Core 轨迹的失败固定为 WARN，原因见第七节。

日志写入器自身的失败（写盘、轮转、句柄关闭、队列溢出）不能经过它自己记录。写入器把这类失败计入自身的失败和丢弃计数，导出诊断包时写进 `collection-status.txt`；不得为此另开 NSLog、stderr 或第二个写入器。

## 二、不记录的例外

只有以下四类可以不记录。例外是封闭清单，不得自行扩充；需要新类别时先修改本页并说明理由。

1. **用户取消。** `CancellationError`、`CocoaError(.userCancelled)` 等由用户或调用方主动取消的结果不是失败。取消之后的清理如果失败，清理失败仍然按第一节判断。Core 轨迹把取消记成带 `cancelled` 的成功终态，不记成失败。
2. **预期的缺失。** 目标本来就不在，调用方按“没有”处理，并且这正是正常路径。包括两种情况：
   - 探测可选的文件、配置、缓存或功能时目标不存在。
   - 收尾时操作的对象已经不在：对端已经断开、子进程已经退出、连接已经关闭、要删除的文件已经不存在。典型错误类别是 `NotConnected`、`BrokenPipe`、`ConnectionReset`、`ConnectionAborted`、`UnexpectedEof`、`NotFound`，以及对已退出进程的 kill。

   只有这些类别属于缺失。权限不足、格式损坏、读到一半失败、超时后对象仍然存在，都不属于缺失，必须记录。
3. **随输入实时重算的校验提示。** 表单里随键入即时更新、不阻断已经发生的操作、不反映系统状态的提示（例如“名称不能为空”）。提交后真正失败的操作仍然必须记录。
4. **同一次失败已经记录过。** 下层处理边界、同一操作的 span fail、同一 op 的 Core 请求或进程轨迹，或同一代码路径上导致这次收尾的那次失败已经记录过。不得再记录一次，见第六节。

按错误类别判断例外时，在一个辅助函数里集中过滤：只放过上面列出的类别，其余类别照常记录。不要在每个调用点复制一份 match，也不要因为“收尾失败通常无害”把整个调用点豁免掉。拿不到错误类别、确实无法区分正常收尾和异常时，才整体豁免，并在原因里写明为什么无法区分。

门禁会标记的写法属于以上例外时，在同一行或紧邻的上一行写豁免标记，标记写明例外类别和具体原因：

```swift
// log-exempt: 预期的缺失：可选的项目级 .editorconfig 不存在时使用默认值
let override = try? fileStorage.read(projectRoot.appending(path: ".editorconfig"))
```

```rust
// log-exempt: 预期的缺失：对端已经断开，连接无需再关闭
let _ = stream.shutdown(Shutdown::Both);
```

原因要写清楚是什么已经不在了或者为什么不是失败。“不重要”“忽略”“暂时”“旧代码”不是原因。豁免标记只用于丢弃错误的规则，不能豁免 NSLog、stderr、`print` 等绕过统一入口的写法，那类永久例外写进 allowlist（第十节）。

## 三、如何设计一条日志

按以下顺序设计，每一步的答案都要能写进事件声明或代码审查说明。

1. **先写下读者的问题。** 维护者拿到用户附在 Issue 里的诊断包时，要靠这条日志回答什么问题？例如“Git fetch 为什么失败、失败在哪个远程、用了多久”。回答不了具体问题的日志不要加。先查第七节的执行轨迹是否已经回答了这个问题；已经回答的不要再加。
2. **确定事实和终态。** 一条事件描述一个已经发生的事实，事件 ID 的结果词用过去时（`fetch_failed`、`index_degraded`）。成对操作用 span，只产生一条带耗时的终态。
3. **确定 owner 和通道。** owner 是拥有这次操作结果的模块；通道由目录模板和已校验的身份决定（`lsp/{server}`、`vcs/{provider}`、`plugins/{plugin}/host`），不按显示名称、路径或用户输入分通道。
4. **按处理后的影响选级别。** 用第一节的表，不按“看起来严重”选级别。
5. **选最窄的字段类型。** 计数、耗时、体积用数值；阶段和结果用受控 token；失败用 `error` 保留稳定 code 和 domain。不把结构化信息拼进消息（第八节）。
6. **用 op 串起同一操作。** 用户入口由 `UserActionTrace` 生成 op，Core 请求和外部进程沿用它；其他有实际操作上下文的事件传同一个 `operationID`。用户在日志窗口里选中一行，能看到同一 op 的全部记录及相对耗时；每层重新生成编号会切断这条链。
7. **控制频率。** 循环、逐按键、逐帧、逐连接路径不用 INFO 逐项记录；需要时用 DEBUG 或在发送侧有界汇总，并按目录声明 rate。高频 Core 方法列入 `is_hot`（第七节）。
8. **在日志窗口里验证。** 触发一次真实场景，在日志窗口（⌘⇧L）中按通道和事件过滤能找到这条记录，字段齐全、没有敏感内容，同一 op 的调用链完整。界面提示带“查看日志”时，点击能定位到这条记录。

反例与正例：

| 反例 | 问题 | 正例 |
| --- | --- | --- |
| `catch { return nil }` | 失败被吞掉，诊断包里没有任何痕迹 | 在处理边界记录 `*.load_failed`（WARN，带 `error`），再返回降级值 |
| 横幅显示“同步失败”，没有日志 | 用户报告问题时无从排查 | 横幅的“查看日志”引用同一 op 的 `vcs.git.command.failed`；宿主有降级、放弃等额外事实时，再在同一边界记录自己的终态 |
| 消息 `"fetch origin failed: \(error)"` | 结构化信息拼进消息，未经字段脱敏 | 消息模板 `Fetch failed`，字段 `remote`（token）、`error`（error）、`duration` |
| 适配器、服务和视图各记录一次同一个失败 | 一次失败出现三次，计数失真 | 适配器返回结构化错误，服务决定降级时记录一次 |
| Swift 在调用 Core 前后各记一条“开始执行 git fetch”“git fetch 失败” | 与 Core 的进程轨迹重复，且拿不到真实的 argv、退出码和 stderr | 不写；Core 在执行点记录 `vcs.git.command.*`，宿主只引用 |
| 重试循环里每次失败都记 WARN | 噪声淹没真正的终态 | 一条终态带 `attempts` 和最后一次 `error` |
| 关闭连接、终止子进程、取消请求时，所有失败一律记 WARN | 正常关闭每天都会触发，日志窗口被假警告刷满，真正的残留反而看不见 | 辅助函数按错误类别过滤：对象已经不在的类别写豁免，权限不足、超时后仍在运行等类别记录 |
| 新增 `logSink: (any LogSink)? = nil` 参数，生产构造不传 | 代码看似记录了，生产环境里事件全部丢失 | 组合根把真实 sink 一路传到构造处，测试替身才使用 `nil` |
| 按钮回调里用 `Task.detached` 或 `DispatchQueue.main.async` 执行动作 | 丢掉用户操作上下文，Core 请求没有 `trigger` 和 op，看不出是哪个按钮触发的 | 用 `UserActionContext.detached` 或 `UserActionContext.mainAsync` |

## 四、只使用目录生成的事件

1. 先调查真实调用和消费者，确定 owner、通道身份与需要保留的事实；没有实际来源不预造事件。
2. 新增事件先修改固定 Core 修订中的 `rust/logging/events/<root>.json`，按共享 README 声明稳定 ID、通道模板、英文消息、级别和字段含义。字段说明必须解释本事件中的来源、语义和单位，不能用按类型的通用短语凑说明。
3. 旧 `scripts/logging/generate-log-events.mjs` 已移除；修改事件目录前须恢复等价生成与校验入口，审查 Rust 静态目录及 Viva 消费者。不得手改生成的目录以绕过声明。
4. 调用生成的事件类型与 span，把类型化输入交给统一日志入口；Rust 使用生成目录和共享边界。Viva 的等价类型生成及门禁尚待恢复，不能把旧 Swift 生成类型当作 Go 已接入。不得手写事件 ID、自由消息或字段字典来规避目录声明，不得自行实现序列化或脱敏。
5. 不再有调用点的事件，从目录声明中删除并重新生成，不保留空事件。

生成事件是尚未脱敏的内存输入。落盘必须经过 Core 的目录字段校验、共享脱敏和编码；只通过类型检查或通用编码器不能证明隐私安全。日志路径由平台可写存储适配器提供，不从 bundle、插件安装目录或 Windows 安装目录推导。

## 五、sink 注入

每个进程只有一个日志写入器。macOS 的写入器由组合根创建，Rust 侧的记录最终都交给这个写入器。各层通过以下途径拿到入口：

| 位置 | 获取方式 |
| --- | --- |
| macOS 服务、适配器、平台实现 | 构造参数，由 `MacServiceContainer` 或上层构造者传入 |
| macOS 应用服务集合 | `AppServices.logSink` |
| macOS 功能模块 | 激活时的 `ModuleContext.logSink` |
| SwiftUI 视图 | 环境值 `applicationLogSink` |
| 没有服务容器的用户操作入口（AppKit 菜单、通知动作） | `UserActionTrace.applicationSink`，启动时安装一次；测试传入自己的 sink |
| Swift 侧的 Rust Core 桥接 | `RustCoreBridge.coreLogSink` |
| Rust Core 的请求处理 | 请求事件流携带的目录事件 |
| Rust Core 的执行轨迹和没有请求上下文的代码（析构、后台清理） | `lithe_diagnostics::core_events` 进程级有界队列；宿主在写入批次、flush 和退出时排空，Core 唤醒回调再安排一次排空 |
| 链接进 Core 的辅助 crate（git-host、ide-host、lithe-remote 客户端） | 本 crate 的 `failure_log` 模块；sink 由 Core 的 `runtime::helper_failures::install()` 注入 |

规则：

- 给类型新增 `logSink` 参数时，同一次改动必须把真实 sink 传到每个生产构造处，包括默认参数里隐式构造的下层对象。`= nil` 默认值只为测试替身保留；生产路径依赖默认值等于没有记录。
- 不得新增全局可变日志单例，不得在下层自行创建写入器。辅助 crate 的 `failure_log` 和 `UserActionTrace.applicationSink` 是仅有的进程级入口：前者只保存 Core 注入的函数指针，后者只引用组合根创建的写入器，都不写文件。
- 辅助 crate 不依赖 Core（依赖方向相反，会形成循环），只通过 `failure_log` 交出事件 ID 和标量字段；事件仍在共享目录中以 `lithe-core` 为 owner 声明，由 Core 校验、脱敏后入队。
- sink 尚未注入时，辅助 crate 只累加未注入计数，不回退到 stderr 或其他输出。新增会调用辅助 crate 的 Core 入口（FFI 函数、独立进程入口）时，必须在入口处调用 `helper_failures::install()`，否则这条路径上的事件全部丢失。
- sink 注入前就可能失败的 macOS 代码（启动早期的设置解码、配置迁移）有界缓存类型化事件，注入后一次性补发；不得另建自由字符串通道，也不得无界缓存。
- `LogScope` 携带同一操作的 op 和可信身份，目录决定通道。路径传 URL，错误传 Error，不先拼成字符串。

macOS 的日志窗口和诊断包只读取 v2 会话文件；v1 文件只进入保留清单，按 30 天自然过期。Rust 的 v1 API 和旧命令继续供 Windows 使用，不得改变其输出。

## 六、一个操作、一条终态、一个错误处理边界

- 成对操作使用生成的 span，由一个调用方拥有。成功调用一次 finish，失败调用一次 fail，生成一条带耗时的终态；不要再手工补“结束”记录。begin 总会产生一条 DEBUG 级别的 started，是否落盘由写入端按级别和详细诊断通道过滤。
- 不复制 span 来产生多份生命周期，不用墙钟差值计算耗时。跨异步边界保留同一个操作所有者和单调计时上下文。
- 有实际操作上下文时传 `operationID`，持久化层用 `op` 关联跨模块证据。不得把 op 重新声明为普通字段，不得用用户内容作为操作编号。
- 错误只在处理它的边界记录一次。下层把错误和稳定分类返回；上层决定恢复、降级或告知用户时记录。不得“记录后再抛出”；span 的 fail 已经记录该操作失败时，不再额外写相同错误。
- 一次失败引发的后续收尾失败，属于第二节第 4 类，不再单独记录。
- Core 请求和外部进程的终态由 Core 记录，不属于任何宿主调用方。宿主只决定界面提示是否引用它，以及是否需要为自己掌握的额外事实记录一条终态（第七节）。

## 七、执行轨迹：用户操作、Core 请求与外部进程

执行轨迹回答“用户按了什么、Core 执行了什么、外部命令怎样结束”。它分三层，由同一个 op 串起来：

| 层 | 事件 | 由谁记录 | 级别 |
| --- | --- | --- | --- |
| 用户操作 | `app.action.performed`（通道 `app`） | 最外层 UI 入口的 `UserActionTrace` | INFO |
| Core 请求 | `app.core.request.finished` / `.traced` / `.failed`（通道 `app/core`） | Core 请求分发处 `rust/crates/core/src/runtime/dispatcher.rs`，实现在 `diagnostics/request_trace.rs` | 用户来源的成功或取消为 `finished`（INFO）；后台或未知来源的成功或取消为 `traced`（DEBUG）；失败为 `failed`（WARN） |
| 外部进程 | `vcs.git.command.finished` / `.traced` / `.failed`（通道 `vcs/git`） | Core 的 Git 进程执行点 `rust/crates/git/src/command_trace.rs`，本地和远程工作区都经过这里 | 来源为用户的可见命令（定义见 7.4），成功或取消为 `finished`（INFO）；其余成功或取消为 `traced`（DEBUG）；失败为 `failed`（WARN） |

### 7.1 用户操作入口

- 每个用户入口在最外层调用 `UserActionTrace.run(_:surface:sink:_:)`；SwiftUI 控件直接调用模型方法时用 `UserActionTrace.action(_:surface:_:)` 包装回调。它记录一条 `app.action.performed`，并把 `UserAction`（id、surface、op、开始时间）绑定到 `UserActionContext.current`，供后续请求继承。
- 嵌套调用既不记录也不重新绑定，外层 id 生效。因此在共用的模型方法上再包一层是安全的，但入口必须包在最外层：例如 `GitFeatureModel.withGitOperation` 为每个 Git 操作生成 `vcs.git.<方法名>`，菜单或按钮先包了自己的 id 时以菜单或按钮为准。
- id 是稳定的 catalog token：1 到 64 字节，字符为 ASCII 字母数字和 `._:/-$`，不合规时记为 `invalid`。不得使用本地化标题、文件名、分支名或任何用户内容。命名按 `<领域>.<对象>.<动作>`，例如 `workspace.remote.test`、`run.panel.stop`、`build.task.run`；主菜单用固定 id（`open-project`、`show-logs`）；右键和下拉菜单用 `menu:<i18n 键的 slug>`，标题来自用户内容的菜单项记在所属子菜单的 id 下，菜单项声明了 `actionID` 时用它；插件动作用 `plugin:<pluginID>/<actionID>`；通知动作用通知声明的动作 id。
- surface 取 `UserActionSurface` 的值：`menu`、`shortcut`、`palette`、`toolbar`、`button`、`context_menu`、`notification`、`plugin`，按用户实际点击的位置选。
- 只记录用户主动发起的入口。定时刷新、文件监听、窗口恢复等自动行为不调用 `UserActionTrace`，它们的 Core 请求按后台来源记录。

### 7.2 跨越异步边界

- `Task {}` 继承 `UserActionContext.current`；`Task.detached` 和 GCD 不继承。为用户操作服务的分离任务用 `UserActionContext.detached`，需要等菜单或弹窗收起后再执行的主线程工作用 `UserActionContext.mainAsync`。不得把 `UserAction` 存进属性留到以后使用。
- 桥接层用 `RustCoreBridge.RequestOrigin.resolve` 给每个请求附上可选的 `origin`：Git 执行来源是后台时记 `source: background`；当前操作开始不到 60 秒时记 `source: user`、`trigger` 和 `operation`；超过 60 秒只保留 `trigger` 和 `operation`，不再声称是用户工作（例如运行会话后续的长期请求）；没有当前操作时沿用已知的 Git 执行来源。
- Core 在请求开始时把 op 和来源放进线程局部上下文，同一请求里启动的 Git 进程自动继承。op 依次取 `origin.operation`、请求的 `operationId`、请求 `id`。在其他线程上结束的轨迹（例如流式历史）必须在离开请求线程前用 `request_trace::current()` 取快照。

### 7.3 Core 请求轨迹

- 每个 Core 请求在分发处记录一条终态，覆盖所有宿主、工作区、插件和按钮背后的调用。领域代码不得为“请求开始”“请求完成”另加日志。
- 字段：`method`；请求载荷里的 `operation` 选择器（如 `git.write` 的 `fetch`）；`source`；`trigger`；`path` 取载荷中第一个绝对路径的 `root`、`workspaceRoot`、`repositoryRoot`、`projectRoot`、`rootPath`、`directory` 或 `path`；`remote`；`duration`；取消时 `cancelled`，失败时 `error`（code 与 domain 为 `core`）。不记录载荷的其他内容。
- 按键、每帧、轮询和监听批次触发的方法列入 `request_trace::is_hot`，不记录。新增这类方法时必须在同一次改动里加入列表。`diagnostics.*` 和 `core.ping` 永远不记录：日志系统不得记录自己的排空、查询和编码调用。

### 7.4 外部进程轨迹

- Core 启动的每个 Git 进程在执行点记录一条终态，字段为 `command`、`arguments`、`repository`、`source`、`remote`、`exit_code`、`duration`，失败或非零退出时带 `stderr`，取消时带 `cancelled`，失败时带 `error`。
- 可见命令指经 `execute_git` 执行、作为 invocation 返回给宿主并显示在 Git 控制台的命令；内部读取指 Core 经 `capture_git` 执行、自己解析输出的命令。即使在用户操作中，内部读取的成功或取消也只记 `traced`。
- argv 只能经过 `command_trace::format_arguments` 进入日志：`-m`、`--message`、`-m…`、`--message=…` 的值换成 `<message>`；`-c` 后键名含凭据或个人身份标记（`credential`、`token`、`password`、`user.`、`author.` 等）的值换成 `<redacted>`；URL 中的用户信息和共享脱敏规则覆盖的路径与令牌被改写；结果超过 1 KiB 时在末尾截断并以 `…` 标记。不得在其他地方格式化 argv。
- stderr 只保留进程最后 16 KiB 输出中的最后 8 个非空行，逐行脱敏后用 ` | ` 连接，超过 1 KiB 时丢弃最早的内容并以 `…` 标记。stdout、stdin 和进程环境永远不记录。
- 结果分类：Core 返回取消错误为取消；返回其他错误为失败；退出码 0 为成功；退出码按文档表示“回答”而不是错误的（`exit_is_answer`，如 `git config --get` 的 1、`git diff --quiet` 的 1）为成功；来源不是用户的内部读取，非零退出视为成功，由调用方判断含义，调用方据此返回错误时由请求轨迹记录失败；其余为失败。Core 开始依赖某个命令的另一个文档化退出码时，在同一次改动里给 `exit_is_answer` 加一行。
- 将来为其他外部进程增加轨迹时，沿用同一模型：在执行点记录唯一终态，argv 只经过一个集中的脱敏格式化函数，stderr 只保留脱敏后的末尾几行。

### 7.5 失败级别与宿主边界

- Core 轨迹的失败固定为 WARN：Core 不知道宿主会重试、降级还是放弃，ERROR 留给知道结果的那一层。
- 宿主要告知用户的失败，如果事实已经全部在同一 op 的 Core 失败轨迹里，提示的“查看日志”引用这条轨迹，宿主不再记录。Git 的引用规则：有进程以非零状态退出时引用通道 `vcs/git` 的 `vcs.git.command.failed`；没有这样的进程而请求失败（参数校验、仓库不可用）时引用通道 `app/core` 的 `app.core.request.failed`；进程全部以 0 退出、只是操作结果报告失败时，Core 没有失败轨迹，不返回引用，由调用方记录自己的终态。op 都取 `GitExecutionContext.traceOperationID`。实现见 `GitService.failureReference`。
- 宿主只在掌握 Core 没有的事实时才记录自己的终态：降级到哪条路径、重试了几次后放弃、留下了什么残留。最终没有完成用户请求时这条终态为 ERROR。

正例与反例：

```swift
// 正例：GitService 把同一 op 的 Core 失败轨迹放进结果，提示直接引用它
LogRecordReference(channel: "vcs/git", event: VcsGitCommandFailed.id, op: execution.traceOperationID)
pendingNotificationReference = result.logReference

// 反例：为同一次失败另声明一个宿主事件，再记一次 ERROR
sink.emit(GitFetchNoticeFailed(remote: remote, error: error, operationID: op))
```

### 7.6 DEBUG 门与排空

- Core 在入队前丢弃宿主没有开启的 DEBUG 事实：宿主通过 `diagnostics.configureCoreEvents { debug, roots }` 告诉 Core 详细诊断是否开启、开启哪些通道根，默认关闭。`MacLogStore` 在详细诊断状态变化时调用它。只在宿主侧过滤会让后台 DEBUG 占满 256 条的 Core 队列；队列满时新事实只计入丢弃数，之后的 WARN 和 ERROR 会因此丢失。
- 构造字段前先调用 `core_events::accepts(level, root)`，被拒绝的事实只花一次分支判断。
- 只有应用写入器调用 `MacLogStore.observeCoreFacts()` 安装 Core 唤醒回调。记录事实或增加丢弃数后，Core 在两次排空之间最多回调一次；回调只安排 100 毫秒后的单次排空，不在回调里直接排空。结束会话先移除回调再做最后一次排空。不得为 Core 队列增加空闲轮询定时器，也不得在响应信封里再加待取标记。

## 八、字段选择与隐私

选择能表达事实的最窄类型，不把结构化信息拼进 message 或自由文本：

| 信息 | 选择原则 |
| --- | --- |
| 计数、开关、耗时、体积 | 使用 int、bool、duration、bytes，单位与编码依共享 README。 |
| 身份、阶段、版本 | 身份用 id；受控短词用 token；版本用 version。id 必须来自已验证的真实身份，字符合法不等于来源可信。 |
| 文件位置 | 使用 path，由共享边界脱敏，不自己拼用户绝对路径。 |
| 失败 | 使用 error，保留稳定 code/domain 等结构化类别，不传未清理的整段错误转储。 |
| 无法结构化的上游诊断和外部进程命令行 | 仅在必须保留 stderr 行、LSP logMessage 等上游原文，或经第七节集中格式化函数脱敏的 argv 时使用 text，并在声明中写 reason 说明结构化字段为什么不能代替；“方便调试”不是理由。 |

不得记录源码、编辑缓冲区、文件内容、提交说明正文、环境变量值、进程的 stdout 与 stdin、凭据、终端历史或协议正文，也不得把它们塞进 text、error、token、路径或消息模板绕过。外部进程只通过第七节的集中格式化函数记录 argv，只记录脱敏后的 stderr 末尾几行。处理凭据的代码路径记录失败时，只记阶段和错误类别，并用测试证明凭据不会出现在事件字段里。

每个动态通道段必须能追溯到已校验的插件、provider、server 或内部连接 ID，不得使用主机名、显示名称、项目路径和任意用户输入。

## 九、界面提示与日志的对应

- 每个显示给用户的警告和错误都对应一条事件：第一节的宿主事件，或者同一 op 的 Core 失败轨迹。提示和事件共用同一个 op。
- 提示需要“查看日志”时，携带日志记录引用（通道、事件，有 op 时带 op），打开日志窗口并定位到这条记录。打开日志窗口只走统一的打开请求，不为某个插件或 provider 写专门分支。
- 插件发给宿主的消息和警告由宿主记入 `plugins/{plugin}/host` 通道，再按插件声明显示；插件不能绕过宿主写日志文件。
- 日志消息、事件名、通道、字段、级别名和过滤语法不翻译；提示文案、按钮和日志窗口自身的界面文字走共享 i18n。

## 十、门禁与豁免

`node scripts/logging/verify-log-usage.mjs` 扫描 macOS、Rust Core 和链接进 Core 的辅助 crate 的生产代码。扫描的目录和排除范围以共享 README 为准；被排除的目录必须在 README 中写明原因和后续计划。门禁没有存量额度：引入门禁时的全部存量已经迁移完毕，任何违规都直接失败。规则分两类：

| 类别 | 规则 | 合法的例外方式 |
| --- | --- | --- |
| 绕过统一入口 | Swift 的 `NSLog`、stderr 写入、`os_log`/`Logger`、字符串 `record(level:)`、`print`/`debugPrint`；Rust 的 `eprintln!`、`println!`、`dbg!` | 只能写进 `scripts/logging/log-usage-allowlist.json`，给出具体的协议或架构理由和精确计数 |
| 丢弃错误 | Swift 语句级 `try?`、只有 `return`/`break`/`continue` 的 `catch`；Rust 语句级 `.ok();`、`let _ =` | 记录事件；属于第二节例外时写 `// log-exempt: <类别>：<原因>`。这类规则不能进 allowlist |

- allowlist 的计数必须等于实际出现次数。少于实际失败；多于实际同样失败，必须同步调低，防止空出来的名额被新写法占用。
- 不得利用别名、包装函数或动态调用逃避门禁，也不得为了通过门禁放宽扫描范围或规则。
- 迁移机器读取的性能标记等协议输出时，同步修改它的消费者，不得直接删除协议输出。
- 门禁无法静态识别以下问题，由第二、五、七、九节和审查清单保证：界面提示没有对应日志、生产构造没有传入 sink、收尾失败没有按错误类别区分、用户入口没有 `UserActionTrace`、异步跳转丢失操作上下文。

## 十一、验证

旧日志生成、使用扫描和对应测试脚本已从本仓库移除，恢复等价门禁后才能将其记为通过。
修改目录、生成器或门禁本身时，还须运行直接受影响的 Core、辅助 crate 和 Viva 宿主测试；
当前 Go 桥接和存储测试不能代替缺失的目录生成及使用扫描。只读核验不能改写生成物。

修改执行轨迹时运行对应测试：Core 请求轨迹在 `rust/crates/core/src/tests/core_request_traces.rs`，Git 进程轨迹、argv 脱敏和 `exit_is_answer` 在 `rust/crates/git/src/command_trace.rs` 的测试模块，宿主侧的入口与来源解析在 `macos/Tests/LitheTests/UserActionTraceTests.swift` 和 `macos/Tests/LitheTests/CoreRequestTraceTests.swift`。

按错误类别过滤的辅助函数必须有测试：对象已经不在的类别（例如 `NotConnected`、`BrokenPipe`）不发事件，意外类别（例如 `PermissionDenied`）发事件。

新增或修改用户可见的警告和错误、用户入口时，按第三节第 8 步在真实应用的日志窗口里确认记录存在、字段正确、同一 op 的链条完整、“查看日志”能定位；无法在本机验证时在 PR 说明中写明。

## 十二、审查清单

- 第一节的每种情形都有事件：界面警告和错误、降级、回退、自动恢复、重试耗尽、留下残留的清理失败、丢弃的错误。没有只出现在界面上的警告。
- 新增的用户入口在最外层用 `UserActionTrace`，id 是稳定 token 而不是本地化标题或用户内容，surface 与实际位置一致；异步跳转用 `UserActionContext.detached` 或 `UserActionContext.mainAsync`。
- 没有为 Core 请求或 Git 进程另写开始、完成或失败日志；新增的高频 Core 方法已列入 `is_hot`；Core 新依赖的文档化退出码已加入 `exit_is_answer`。
- 宿主提示的事实都在 Core 轨迹里时，提示引用 Core 轨迹而不是重复记录；宿主自己的终态只描述 Core 没有的事实。
- 豁免标记属于第二节的四类之一，写明类别和具体原因；绕过统一入口的例外只在 allowlist 里，计数精确。
- 收尾类失败按错误类别过滤：对象已经不在的类别豁免，其余类别记录；没有因为“通常无害”整体豁免，也没有把正常关闭记成 WARN。
- 事件有真实来源和 owner，级别按处理后的用户影响选择；高频路径没有 INFO 逐项输出。
- 声明先于调用，使用生成类型；没有手写 ID、消息、字段字典、第二套写入器或直接打印；没有残留无调用点的事件。
- 新增的 `logSink` 参数在每个生产构造处都传入真实 sink；`nil` 只出现在测试替身中。新增的 Core 入口如果会调用辅助 crate，已经调用 `helper_failures::install()`。
- 同一操作只有一个 span 所有者和一条终态；错误只在处理边界记录一次，op 贯穿调用链。
- 动态段来源可信并经过校验；字段类型最窄，description 具体，text 的 reason 说明不可替代性；argv 只经过集中格式化函数；没有禁止记录的内容。
- 生成物检查和用法门禁通过，门禁零违规。
- 写入、查询、保留和导出保持有界，文件位于平台可写存储；Core 队列没有新增轮询。

当前决策见 `.agents/notes/implemented/architecture/2026-11-03-structured-logging-channels.md`。
