# 结构化日志 v2 事件目录

`shared/logging/events/<root>.json` 是事件声明的唯一来源。macOS 使用生成的类型化事件，经 `MacLogStore` 写入 v2 会话文件；Windows 仍使用 v1。日志消息是供诊断使用的英文事实，**不走 i18n**；界面上的错误、提示和操作名称仍然走共享 i18n。

本文规定声明语法、通道、字段编码与隐私边界、级别与 span、执行轨迹事件、Core 事件队列、引擎宿主接入、辅助 crate、生成器和用法门禁。什么必须记录、怎样设计一条日志和审查清单见 `.agents/skills/develop-lithe/references/logging.md`；决策原因见 `.agents/notes/implemented/architecture/2026-11-03-structured-logging-channels.md`。

## 一、声明

- 固定根为 `app`、`editor`、`perf`、`lsp`、`vcs`、`run`、`debug`、`terminal`、`remote`、`agent`、`update`、`plugins`。每个根恰有一个 JSON 文件，形状为 `{ version, root, events }`；没有实际调用的根保持空 `events`，不预造事件。
- 事件 ID 是小写点分的稳定标识，如 `editor.document.save_failed`，结果词用过去时。`owner` 标明拥有这次操作结果的模块；由 Core 记录的事件 owner 必须是 `lithe-core`。
- `message` 是英文单行模板，只能引用本事件声明的必填字段，例如 `Git {command} failed`；可选字段不参与模板。
- 生成器拒绝未知属性、跨文件重名、生成类型名冲突、保留键和编码后的字段名冲突。`shared/logging/event-catalog.schema.json` 描述静态形状；生成器另外执行通道、引用、span 和磁盘键展开等跨字段语义校验。

## 二、通道

- 通道由固定根和可选段组成，只接受三种形状：单独的根；非插件根加固定段或动态段；插件宿主 `plugins/{plugin}/host`。固定段也是目录声明的一部分。
- 动态段只能来自插件、provider、server 或内部连接等已校验的 ID，格式为 `^[a-z0-9][a-z0-9._-]{0,63}$`，同时拒绝末尾点号和 Windows 设备名（如 `con`、`nul.txt`、`com1`）。禁止使用显示名称、任意目录、用户输入和命令行。占位符必须引用本事件必填的 `id` 字段。
- 活动文件名为 `<channel>.log`，轮转文件名为 `<channel>~1.log`。`~` 不在通道字符集中，因此 `vcs/git.1` 不会与 `vcs/git` 的轮转文件冲突。`_overflow` 使用同样的文件头和轮转规则。
- Swift 的 `LogSegment` 校验失败时返回 `nil`，不得对未知输入强制解包。
- 引擎按角色使用事件族：`lsp.*` 使用 `lsp/{server}`，`vcs.*` 的引擎事件使用 `vcs/{provider}`，`plugins.host.*` 使用 `plugins/{plugin}/host`。Core 依据显式 role 和目录身份字段选择事件，目录模板仍是通道的唯一来源，任何输入都不能改写普通事件的通道。非法段改用稳定的 SHA-256 前缀身份，不丢弃日志，也不影响插件启动。
- 引擎宿主的段通过 `diagnostics.resolveEngineLogSubject` 取得，与会话启动共用 `SessionLogIdentity::new`。宿主不得实现另一份哈希或身份规则。

## 三、字段与隐私

字段名为 `[a-z][a-z0-9_]{0,63}`，保留键为 `seq`、`event`、`op`、`msg`、`ts`、`level`。每个字段显式填写 `type`、`required` 和 `description`；只有 `text` 可以并且必须填写 `reason`，说明为什么结构化字段不能代替这段原文。

`description` 去除首尾空白后至少 16 个字符，说明该字段在本事件里的含义、来源或单位，并尽量给出典型值。生成器拒绝按类型填写的通用短语（例如 `Validated internal identifier`、`Structured failure`、`Count or numeric result`），也不提供按类型的默认描述。span 自动字段的说明绑定具体操作 ID 和终态。

| 类型 | Swift 参数 | Core 编码与边界 |
| --- | --- | --- |
| `int` | `Int64` | 有符号整数 |
| `bool` | `Bool` | 布尔值 |
| `duration` | `Duration` | 非负整数毫秒，磁盘键为 `<name>_ms`；声明名不得自带 `_ms` |
| `bytes` | `UInt64` | 无符号字节数 |
| `id` | `LogSegment` | 校验后的不透明 ID，可用作通道段 |
| `token` | `String` | ≤64 字节的受控短词，字符为 ASCII 字母数字和 `._:/-$`，例如命令名、阶段或结果枚举 |
| `version` | `String` | ≤64 字节的组件版本，字符为 ASCII 字母数字和 `._+-` |
| `path` | `URL` | 落盘前改写为工作区相对路径或 `<HOME>`；无法归属的绝对路径不得直接落盘；上限 4096 字节 |
| `error` | `any Error` | 展开为 `<name>`、`<name>_code`、`<name>_domain`，字段名通常就是 `error`；消息脱敏并限长至 1 KiB，code 可以是整数或稳定 token |
| `text` | `String` | 只用于无法结构化的上游诊断（stderr 行、LSP logMessage）和经 Core 集中格式化函数脱敏的外部进程 argv；脱敏、去除控制字符、限长至 1 KiB |

源码、编辑缓冲区、文件内容、提交说明正文、环境变量值、进程的 stdout 与 stdin、凭据、终端历史和协议正文没有对应类型，不得塞进 `text`、`error`、token、路径字段或消息模板。外部进程的 argv 只经过 `rust/lithe-core/src/git/command_trace.rs` 的 `format_arguments`，stderr 只保留脱敏后的末尾几行（第五节）。迁移旧日志时拆开拼接消息，只保留结构化的时间、计数、受控结果词和错误类别。`text` 的理由不能写成“方便调试”。

Swift 的事件值是**未经脱敏的内存输入**，不能自行序列化落盘。Core 先对 `error`、`text` 输入脱敏、删除控制字符、按 UTF-8 字符边界截断到 1024 字节，再由 `catalog::validate_fields(id, fields)` 校验磁盘键展开后的类型、必填、未知字段、长度和错误组件完整性；这一步校验形状，不代替隐私脱敏。macOS 的跨边界适配器连接 Core 的脱敏、格式化和写入路径，不得另写 Swift 格式化或隐私策略。

可选身份字段超长时只省略该字段，不省略整条事件。例如 `plugins.grammar.load_failed` 的语言字段是可选 `version`，允许 `c++` 等合法语言 ID；语言 ID 超长时省略语言字段，插件失败事件照常记录。

## 四、级别、span 与 rate

- `debug`：性能数据、缓存、内部诊断和后台执行轨迹，只在详细诊断开启时落盘。
- `info`：正常生命周期和操作结果。
- `warn`：可恢复失败、功能降级、上游警告，以及 Core 执行轨迹的失败。
- `error`：宿主确认用户请求最终失败。不允许使用 `warning` 别名。

目录中的 `span: { "failureLevel": "error" }` 把基事件展开为 `.started`、`.finished`、`.failed`。started 固定为 debug，生成的 `begin` 总会发出它，由写入端在入队前按级别和详细诊断通道过滤，因此正式版开启详细诊断后也能看到。finished 使用声明的 `level`，failed 使用 `failureLevel`；两种终态自动增加逻辑字段 `duration`（磁盘键 `duration_ms`），failed 还自动增加结构化 `error`。不得声明与这些自动字段冲突的键。

生成的 span 由一个调用方值拥有；`finish`、`fail` 是 mutating，第一次终态生效，后续调用被忽略。不要复制 span 来产生多份生命周期。`LogSpanClock` 可注入单调时间，默认使用 `ContinuousClock`，不使用墙钟差值。`operationID` 独立于普通字段，传给持久化层成为 `op`，不得重新声明成目录字段。必填上下文在 begin 时提供，`exit_code`、`outcome` 等可选结果在终态时提供。

`rate` 声明每个事件、每个通道每分钟的条数上限，取值 1 到 60000，默认 60。执行轨迹（Git 命令、Core 请求、用户操作）为 600，LSP 为 120，辅助 crate 的转发 accept 与 bridge 失败为 12。rate 目前只是目录元数据，写入器还不执行它；以后执行时在发送侧合并高频记录，用有界状态维护丢弃计数，不通过绕过日志系统补写。

## 五、执行轨迹事件

执行轨迹由三族事件组成，用同一个 op 串起来：

| 事件 | 通道 | 级别 | 字段 |
| --- | --- | --- | --- |
| `app.action.performed` | `app` | info | `action`、`surface` |
| `app.core.request.finished` / `.traced` / `.failed` | `app/core` | info / debug / warn | `method`、`source`，可选 `operation`、`trigger`、`path`、`remote`，`duration`；finished 与 traced 可带 `cancelled`，failed 带 `error`（domain 为 `core`） |
| `vcs.git.command.finished` / `.traced` / `.failed` | `vcs/git` | info / debug / warn | `command`、`arguments`、`source`，可选 `repository`、`remote`、`exit_code`、`stderr`，`duration`；finished 与 traced 可带 `cancelled`，failed 可带 `error` |

- `app.action.performed` 由 `UserActionTrace` 在最外层用户入口记录，owner 为 `LitheModuleAPI`。`action` 是稳定的操作 id，`surface` 是 `UserActionSurface` 的取值。它的 op 绑定到 `UserActionContext.current`，桥接层据此给 Core 请求附上 `origin`。
- Core 请求轨迹在 `rust/lithe-core/src/runtime/dispatcher.rs` 的请求分发处记录，实现在 `rust/lithe-core/src/diagnostics/request_trace.rs`。用户来源的成功或取消记 finished，后台或未知来源的成功或取消记 traced，失败记 failed。`request_trace::is_hot` 列出的按键、每帧、轮询和监听批次方法，以及全部 `diagnostics.*` 和 `core.ping`，不记录。
- Git 进程轨迹在 `rust/lithe-core/src/git/command_trace.rs` 的执行点记录，本地与远程工作区都经过这里。可见命令指经 `execute_git` 执行、作为 invocation 返回给宿主并显示在 Git 控制台的命令；内部读取指 Core 经 `capture_git` 执行、自己解析输出的命令。来源为用户的可见命令，成功或取消记 finished；其余成功或取消记 traced，包括用户操作中的内部读取；失败记 failed。退出码表示“回答”的情形（`exit_is_answer`），以及来源不是用户的内部读取的非零退出，不算失败；后者由调用方判断含义，调用方返回错误时由请求轨迹记录失败。
- `arguments` 由 `format_arguments` 生成：提交说明值换成 `<message>`，`-c` 中凭据和个人身份键的值换成 `<redacted>`，URL 用户信息和共享脱敏规则覆盖的内容被改写，超过 1 KiB 时在末尾截断并以 `…` 标记。
- `stderr` 只在失败或非零退出时出现：取进程最后 16 KiB 输出中最后 8 个非空行，逐行脱敏后用 ` | ` 连接，超过 1 KiB 时丢弃最早的内容并以 `…` 标记。
- Core 轨迹的失败固定为 WARN，因为 Core 不知道宿主会重试、降级还是放弃。宿主提示的事实都在同一 op 的 Core 失败轨迹里时，提示用 `LogRecordReference(channel:event:op:)` 引用它，宿主不再记录；宿主只为降级、放弃、重试耗尽、残留等 Core 不掌握的事实记录自己的终态。

## 六、Core 事件队列与宿主写入

- Rust 侧没有请求事件流可用的事实（执行轨迹、析构、后台清理、辅助 crate 失败）进入 `diagnostics::core_events` 的进程级有界队列，最多 256 条。`record` 校验 owner、规范化并脱敏字段后入队，不做文件 I/O。队列满时新事实只计入丢弃数；同一批次里事件、通道、字段和 op 都相同的事实只保留一条，其余计入丢弃数。
- DEBUG 事实在入队前过滤：宿主通过 `diagnostics.configureCoreEvents { debug, roots }` 告诉 Core 详细诊断是否开启、开启哪些通道根，`roots` 省略表示全部根，默认关闭。未开启的 DEBUG 事实直接返回成功，不入队、不计入丢弃数。构造字段前先调用 `core_events::accepts(level, root)`，被拒绝的事实只花一次分支判断。
- `MacLogStore` 在详细诊断状态变化时调用 `configureCoreEvents`，只在开关或通道根集合变化时发送；调用失败时记录一次 `app.logging.diagnostics_failed`。
- 写入器在每次写入批次、flush 和退出时排空一次。没有其他宿主活动时，由 Core 的唤醒回调安排排空：drain 之后的第一条事实或第一次丢弃计数触发一次回调，同一个 drain 周期内的后续变化合并。只有组合根创建的应用写入器调用 `MacLogStore.observeCoreFacts()` 安装回调，回调复用宿主事件已有的 100 毫秒单次排空调度；`finishSession` 先移除回调，再做最后一次排空。回调不得重入 Core。不得为 Core 队列增加空闲轮询或独立写入器。
- 排空得到的 `CoreLogRecord` 原样交给统一的 `LogSink`：保留 `ts` 和 `op`，由写入器分配 `seq`，继续以 `validateCatalog: true` 写入。

## 七、引擎宿主

- 启动者显式声明 role、真实 `pluginId` 和 VCS `logSubject`；宿主不解析 providerID。
- stderr 读取器限制每行 4 KiB、每秒 200 行，之后再走 `text` 的 1 KiB 脱敏规范化。与 v1 相比唯一的兼容变化是从任意 trim 的读取块改为逐行文本：保留行内空格，移除 LF 和末尾 CR，并应用已声明的长度上限和限流。
- 上游明确给出的严重度通过独立的目录事件保留：`window/logMessage` 和 `window/showMessage` 的 type 1/2/3/4 分别为 ERROR/WARN/INFO/DEBUG，未知类型为 DEBUG。未分类的 stderr 是 DEBUG 排障证据，流名称不表示警告；实际的进程或协议失败由 `*.session.failed` 记录 ERROR，正常关闭仍是生命周期状态。
- 插件自身使用独立协商的 `litheLogging` 1 和 `lithe/log`，由 Core 把四种受控事实映射到插件目录事件，不能再用 stderr 或任意自由消息代替。协议字段、op、限额和 fixture 以 [插件契约](../contracts/plugins/v1/README.md#structured-plugin-diagnostics-logging-protocol-1) 为准。
- 上游 trace 默认关闭。宿主通过 `lsp.setDetailedDiagnostics` 对活动会话和新会话显式开启，15 分钟后单次到期关闭。详细诊断类别与通道根的对应为 `lsp` → language、`vcs` → git、`plugins` → plugins。
- 详细诊断只接纳 `$/logTrace.message` 摘要；`verbose` 可能包含原始 RPC 载荷和文档源码，禁止进入 v2 `text`。凭据脱敏和 1 KiB 限长不代表源码可以落盘。`initialized` 之前收到的开关只保存目标状态，Core 在 `initialized` 之后发送通知。
- v1 的 detail、message、level 保持兼容原文；v2 字段通过独立的 `EngineLogInput` 传递，禁止从 detail 反解。原始通知 JSON、`projectCount=N` 和 navigation 格式不变。macOS 日志窗口统一读取 v2 会话文件和写入器的实时批次，不写 v1 文件。
- Core 的生命周期事实挂在原有 `type: stateChanged` 运行时事件上，复用 `prepare_catalog_event` 校验，不额外增加 v1 日志行。Swift 在事件分支之前转发任何携带 `coreLog` 的事件一次，语言服务、VCS、构建、工具链和后端都适用。`*.session.updated` 的 state 指 Core 会话生命周期，owner 是 `lithe-core`，宿主不再重复发同一状态事实。
- 宿主在实际调用点发 `lsp.session.stage_changed`，阶段闭集为 requested、resolving、registered、stopping、cancelled；缓存清理成功发 `lsp.cache.cleaned(removed)`，它与 Core 配置键清理的 `configuration.cleaned` 是不同事实。两者为 DEBUG，因为它们解释内部启动编排和缓存维护，不需要常态落盘。ready 和 terminated 由 Core 的 `protocol.initialized` 和 `session.updated` 表达。阶段、缓存、degradation 和 issue 事件统一使用 Core 计算的段；manager 按 providerID 缓存成功或失败结果，最多 128 项，满时清空；失败只跳过对应的宿主 v2 事件，不改变原有行为。
- 本地启动前，`MacLogStore` 用 Core 的 `plugin_files_path` 创建当前会话的 `sessions/<session>/plugins/<id>/files/`，目录权限 0700，用相对描述符和 no-follow 遍历防止符号链接越界。该目录只属于当前日志会话，不注册为跨工作树可复用的构建资源，不写 bundle 或安装目录。存储不可用时不传 `logDirectory`，使用 `${logDir}` 的模板按现有 `invalidRequest` 失败。远程进程不能写本机日志目录，因此同样不传 `logDirectory` 并拒绝该变量。安装验证只用未创建的占位目录校验展开，不启动进程也不写入。

## 八、辅助 crate

- `rust/lithe-agent-host`、`rust/lithe-git-host`、`rust/lithe-ide-host` 和 `rust/lithe-remote` 的客户端链接进 Core，各自通过 `failure_log` 模块交出失败事实，依赖方向保持不变。sink 未注入时只增加原子计数，不写 stderr。
- Core 的 `diagnostics/helper_failures` 是唯一的安装处。JSON dispatcher、独立 ACP FFI open、直接 IDE dispatcher 和 AskPass 入口在调用辅助 crate 前都经过它的 `Once`。sink 只转换标量字段，之后走相同的目录校验、脱敏和 256 条 Core 队列。这些事件的 owner 都是 `lithe-core`，错误只保留固定摘要和类别。
- 辅助 crate 的收尾只记录丢失数据、能力或清理结果的意外错误。已断开的连接、已退出的进程，以及远程关闭或取消时的 Disconnected、Timeout，在类型化辅助函数里豁免；ACP Cancel 的 InternalError 无法区分正常断连与序列化失败，按预期缺失豁免。转发 accept 与 bridge 失败可能逐连接发生，目录 rate 为 12；`rust/lithe-remote/src/client/forward.rs` 在发送侧让每一族失败在进程内每 5 秒最多记录一条，并发转发连接也共用这个限制，正常断连不占日志配额。强制终止后进程仍未退出的最终超时保留 WARN。

## 九、目录遍历与清理事件

- 跳过无法访问的目录分别记录为 `app.search.directory_skipped` 和 `app.workspace.directory_skipped`；scratch 目录清理失败记录为 `app.workspace.scratch_cleanup_failed`。`error` 只含固定消息和稳定类别。
- 不再声明项目级或远程级的重复变体。远程清理只记录 `ClientError` 的稳定分类，不复制错误正文。

## 十、新增与迁移

1. 先调查真实调用，选择根和 owner；没有实际来源不新增事件。
2. 在对应 JSON 中声明稳定 ID、通道模板、英文事实、级别和字段；成对操作优先使用 span。检查隐私和动态段来源。
3. 运行生成器，核对 Swift 参数和 Rust 字段表；不得手改生成文件。
4. 接入时使用类型化事件。不再有调用点的事件从目录删除并重新生成。
5. 运行下列检查。生成结果稳定排序、使用 LF，不读取运行时 JSON。

```sh
node scripts/logging/generate-log-events.mjs
node scripts/logging/generate-log-events.mjs --check
node --test --test-timeout=60000 scripts/logging/test-log-events.mjs
node scripts/logging/verify-log-usage.mjs
```

`--check` 只读比较，不修复漂移，有缺失或差异即以非零状态退出。生成器先完成全部目录校验和输出规划，再写第一个文件。Swift target 自动发现 `Logging/` 源目录，不需要在 `Package.swift` 中逐个列出。

## 十一、API 示例

Swift 的用户入口用 `UserActionTrace` 包装；生成事件的初始化参数按字段名排序：

```swift
// 菜单项：记录 app.action.performed，并把操作上下文交给后续的 Core 请求
UserActionTrace.run("open-project", surface: .menu, sink: UserActionTrace.applicationSink) {
    model.openProject()
}

// SwiftUI 按钮：包装回调，surface 默认为 .button
Button(action: UserActionTrace.action("workspace.remote.test") { model.testConnection() }) {
    Text("Test")
}

// 宿主自己的事实：在同一 op 下记录，并取得可以交给界面提示的引用
let scope = LogScope(sink: sink, operationID: operationID)
let reference = scope.emitReferenced(AppLoggingDiagnosticsFailed(error: failure))
```

Rust 通过静态 `EVENTS`（按 ID 排序）和二分查找的 `event_by_id` 暴露元数据，不分配运行时目录缓存。生成表通过路径子模块载入：Rust 的 `include!` 不能接受仓库注释门禁要求的首行 `//!`，子模块能满足该门禁，不需要豁免或放宽检查。

## 十二、用法门禁

`scripts/logging/verify-log-usage.mjs` 扫描 `macos/Sources`、`rust/lithe-core/src`、`rust/lithe-agent-host/src`、`rust/lithe-git-host/src`、`rust/lithe-ide-host/src` 和 `rust/lithe-remote/src`。排除 `rust/lithe-remote/src/server/`、`rust/lithe-remote/src/bin/` 和 `rust/lithe-ide-host/src/bin/`：它们在远端主机或独立进程中运行，stderr 由宿主进程处理，以后单独迁移。

门禁只扫描生产代码：词法上遮蔽注释和字符串内容，排除 `Tests/`、`tests/`、`tests.rs`、文件名以 `_tests.rs` 结尾的 Rust 文件，以及明确标注 `#[cfg(test)]` 或 `#[cfg(all(test, …))]` 的项。它只检查列出的直接写法，不跨文件追踪别名或动态调用。规则分两类：

- **绕过日志**：Swift 的 `NSLog`、stderr 写入、`os_log`、导入 `os.log` 后的 `Logger`、`.record(level:)`、`print`/`debugPrint`；Rust 的 `eprintln!`、`println!`、`dbg!`。这些写法不经过目录和脱敏，只能改成生成事件；确属机器协议的永久例外写进 `scripts/logging/log-usage-allowlist.json`，给出具体的协议或架构理由和精确计数。
- **丢弃失败**：Swift 语句级 `try?`（含 `_ = try?`）、块体只有 `return`/`break`/`continue` 的 `catch`；Rust 语句级 `.ok();` 和 `let _ = …;`。失败要么处理并记录事件，要么在同一行或上一行写 `// log-exempt: <原因>`。原因至少 3 个非空白字符，必须属于日志参考页的四类封闭例外；空原因本身报错。标记只对这四条规则生效，不能豁免绕过日志的写法，这类规则也不能进 allowlist。

门禁没有存量额度，任何违规都直接失败。allowlist 的计数必须等于实际出现次数，少于或多于实际都失败，防止空出来的名额被新写法占用。当前 allowlist 为空。迁移机器读取的性能标记时同步修改它的消费者，不能直接删除测试依赖的协议输出。

## 十三、CI、工作树与发行包

- Draft PR 只运行 Linux 检查；ready PR 和 preview push 运行三平台检查。
- 目录输入和已提交的生成物都由 Git 管理，每个 worktree 在本地重建和检查；它们没有跨工作树可复用的 identity stamp，不复制其他工作树的生成物。
- 生成的类型没有运行时 I/O，不写 app bundle、插件资源或安装目录，不影响代码签名和 Sparkle delta。日志文件位于平台可写存储适配器提供的目录。
