# 结构化日志 v2 事件目录

`shared/logging/events/<root>.json` 是事件声明的唯一来源。macOS 已使用类型化事件和 MacLogStore 写入 v2 会话文件，Windows 仍使用 v1。日志消息是供诊断使用的英文事实，**不走 i18n**；界面上的错误、提示和操作名称仍须走共享 i18n。

## 声明与通道

固定根为 `app`、`editor`、`perf`、`lsp`、`vcs`、`run`、`debug`、`terminal`、`remote`、`agent`、`update`、`plugins`。每个根恰有一个 JSON 文件，没有实际调用的根保持空数组，不预造事件。事件 ID 是小写点分的稳定标识，如 `editor.document.save_failed`；结果词使用过去时。`owner` 标明维护模块。

通道由固定根和可选段组成。动态段只能来自插件、provider、server 或内部连接等已校验的 ID，格式为 `^[a-z0-9][a-z0-9._-]{0,63}$`，同时拒绝末尾点号和 Windows 设备名（如 `con`、`nul.txt`、`com1`）；禁止显示名称、任意目录、用户输入和命令行。占位符必须引用本事件必填的 `id` 字段。固定段也是目录声明的一部分。Core 与生成器都只接受根、非插件根/段及插件宿主三种形状。插件宿主通道统一为 `plugins/{plugin}/host`。活动文件使用 `<channel>.log`，轮转使用 `<channel>~1.log`；`~` 不在通道字符集中，因此 `vcs/git.1` 不会与 `vcs/git` 的轮转文件冲突。`_overflow` 使用同样的文件头和轮转规则。Swift 的 `LogSegment` 失败返回 `nil`，不得用未知输入强制解包。 引擎宿主的段通过 `diagnostics.resolveEngineLogSubject` 取得，与启动复用 `SessionLogIdentity::new`；宿主不得实现另一份哈希或身份规则。

`message` 是英文单行模板，只能引用本事件声明的必填字段，例如 `Operation {command} finished`；可选字段不参与模板。生成器拒绝未知属性、跨文件重名、生成类型名冲突、保留键和编码后的字段名冲突。JSON Schema 描述静态形状；生成器还执行通道、引用、span 和磁盘键展开等跨字段语义校验。

## 字段与隐私

字段名为 `[a-z][a-z0-9_]{0,63}`，保留键为 `seq/event/op/msg/ts/level`。每个字段显式填写 `type`、`required` 和描述语义、单位的 `description`；只有 `text` 可以且必须填写 `reason`，解释为什么结构化字段不能替代上游原文。

`description` 去除首尾空白后至少 16 个字符，必须说明该字段在本事件里的含义、来源或单位，并尽量给出典型值；生成器拒绝按类型填写的通用短语（例如 `Validated internal identifier`、`Structured failure`、`Count or numeric result`）。目录字段必须由作者显式说明，不提供按类型的默认描述；span 自动字段说明绑定具体操作 ID 和终态。

| 类型 | Swift 参数 | Core 编码与边界 |
| --- | --- | --- |
| `int` | `Int64` | 有符号整数 |
| `bool` | `Bool` | 布尔值 |
| `duration` | `Duration` | 非负整数毫秒，键为 `<name>_ms`；声明名不得自带 `_ms` |
| `bytes` | `UInt64` | 无符号字节数 |
| `id` | `LogSegment` | 校验后的不透明 ID，可用于通道段 |
| `token` | `String` | ≤64 字节的受控短词，字符为 ASCII 字母数字和 `._:/-$`；例如命令名、阶段或结果枚举，禁止完整命令行 |
| `version` | `String` | ≤64 字节的组件版本，字符为 ASCII 字母数字和 `._+-` |
| `path` | `URL` | 落盘前改写为工作区相对路径或 `<HOME>`；无法归属的绝对路径不得直接落盘 |
| `error` | `any Error` | 展开为 `<name>`、`<name>_code`、`<name>_domain`；通常字段名就是 `error`，消息须脱敏并限长至 1 KiB，code 可以是整数或稳定 token |
| `text` | `String` | 仅保留不可结构化的上游诊断（stderr、LSP logMessage 等）；脱敏、限长至 1 KiB，不保留控制字符 |

源码、环境变量值、命令输出和凭据没有对应类型。不得把这些内容塞进 `text`、`error`、token 或路径字段。迁移时拆开现有拼接消息，只保留结构化的时间、计数、受控结果词和错误类别；stderr 是明确的上游诊断例外，仍须经过脱敏和截断。自由文本的理由不能写成“方便调试”。

Swift 的事件值是**未经脱敏的内存输入**，不能自行序列化落盘。Core 在目录校验前对 error/text 输入先脱敏、删除控制字符、按 UTF-8 字符边界截断至 1024 字节，再由严格的 `catalog::validate_fields(id, fields)` 校验磁盘键展开后的字段类型、必填、未知字段、长度和错误组件完整性；它不替代隐私脱敏。`plugins.grammar.load_failed` 的语言字段是可选 `version`，允许 `c++` 等合法语言 ID；超长身份只省略语言字段，不省略插件失败事件。`path` 上限 4096 字节；error/text 上限 1024 字节。macOS 跨边界适配器连接 Core 脱敏、格式化和写入路径，禁止另写 Swift 格式化或隐私策略。

## 级别、span 与限流

- `debug`：性能数据、缓存和内部诊断，正常运行可关闭。
- `info`：正常生命周期和操作结果。
- `warn`：可恢复失败、功能降级或上游警告。
- `error`：操作失败。禁止 `warning` 别名。

目录中的 `span: { "failureLevel": "error" }` 将基事件展开为 `.started`、`.finished`、`.failed`。started 固定为 debug；生成的 `begin` 总是发出它，由写入端在入队前按级别和详细诊断通道过滤，正式版开启详细诊断后也能看到。finished 使用声明的 level，failed 使用 failureLevel；两种终态自动增加逻辑 `duration`（磁盘为 `duration_ms`），failed 自动增加结构化 `error`。不允许声明与这些自动字段冲突的键。

生成的 span 由一个调用方值所有；`finish` / `fail` 是 mutating，第一次终态生效，后续调用忽略。不要复制 span 以产生多份生命周期。`LogSpanClock` 可注入单调时间，默认使用 `ContinuousClock`；不使用墙钟差值。`operationID` 独立于普通字段，传给持久化层的 `op`，不得重新定义成目录字段。必填上下文在 begin 提供；exit_code、outcome 等可选结果在终态提供。

默认每事件、每通道每分钟 **60 条**，可显式声明 1…60000 的 `rate`；Git 高频生命周期为 600，LSP 为 120。rate 目前是元数据，由后续写入器执行；本 PR 不安装定时器、不增加后台任务、不改变运行限流。后续应在发送侧合并高频记录，使用有界状态维护被丢弃计数，不通过绕过日志系统补写。

## 新增与迁移

1. 先调查真实调用，选择根和 owner；无实际来源不新增事件。
2. 在对应 JSON 中声明稳定 ID、通道模板、英文事实、级别和字段；成对操作优先 span。检查隐私和动态段来源。
3. 运行生成器，核对 Swift 参数、Rust 字段表；禁止手改生成文件。
4. 接入迁移时使用类型化事件，删除相同文件/规则已修复的基线计数。用法门禁既拒绝增量，也拒绝过大的旧基线。
5. 运行下列检查。生成稳定排序和 LF，不读取运行时 JSON。

```sh
node scripts/logging/generate-log-events.mjs
node scripts/logging/generate-log-events.mjs --check
node --test scripts/logging/test-log-events.mjs
node scripts/logging/verify-log-usage.mjs
```

`--check` 只读比较，不修复漂移，缺失或不同即非零退出；生成器先完成所有目录校验和输出规划，再第一次写文件。Swift target 自动发现 `Logging/` 源目录，无需 Package.swift 显式列举。

Swift API 示例（`typedSink` 由迁移 PR 提供；参数按字段名排序）：

```swift
let provider = LogSegment("git")!
var span = VcsGitCommandSpan.begin(command: "fetch", provider: provider, emit: typedSink)
span.finish(exitCode: 0)
// 失败：span.fail(error, exitCode: 128)
```

Rust 通过静态 `EVENTS`（按 ID 排序）和二分查找 `event_by_id` 暴露元数据，不分配运行时目录缓存。生成表使用路径子模块载入：Rust `include!` 无法接受仓库注释门禁要求的首行 `//!`，子模块兼容该门禁，无需豁免或放宽检查。

## 用法门禁

门禁扫描 `macos/Sources`、`rust/lithe-core/src`、`rust/lithe-agent-host/src`、`rust/lithe-git-host/src`、`rust/lithe-ide-host/src` 和 `rust/lithe-remote/src`。排除 `rust/lithe-remote/src/server/`、`rust/lithe-remote/src/bin/` 和 `rust/lithe-ide-host/src/bin/`：它们在远端主机或独立进程运行，stderr 由宿主进程处理，后续单独迁移。

门禁分两类规则，都只扫描生产代码：词法遮蔽注释和字符串内容，排除 `Tests/`、`tests/`、`tests.rs`、文件名以 `_tests.rs` 结尾的 Rust 文件及明确 `#[cfg(test)]` 或 `#[cfg(all(test, …))]` 项；只检查列出的直接写法，不跨文件追踪别名或动态调用。

- 绕过日志：Swift 的 `NSLog`、stderr 写入、`os_log`、导入 `os.log` 后的 `Logger`、`.record(level:)`、`print`/`debugPrint`；Rust 的 `eprintln!`、`println!`、`dbg!`。这些写法不经过目录和脱敏，只能改成生成事件；确属机器协议时进 `log-usage-allowlist.json`。这类写法没有存量；Rust 的非 LSP 事实通过 256 条的 Core 队列交给宿主。
- 吞掉失败：Swift 语句级 `try?`（含 `_ = try?`）、块体只有 `return`/`break`/`continue` 的 `catch`；Rust 语句级 `.ok();` 和 `let _ = …;`。失败要么处理并记录事件，要么在同一行或上一行写 `// log-exempt: <原因>`。原因至少 3 个非空白字符，必须属于日志参考页的四类封闭例外；空原因本身报错。标记只对这四条规则生效，不能豁免绕过日志的写法。

没有存量额度：门禁引入时的全部存量已经迁移完毕，任何不在 allowlist 里的违规都直接失败，必须改成记录事件，或者在属于四类例外时写豁免标记。`log-usage-allowlist.json` 只接受绕过日志的规则，用于确属机器协议的永久例外，必须有具体的协议或架构理由和精确计数；丢弃失败的规则不能进 allowlist。计数低于实际出现次数时同样失败，防止空出来的名额被新写法占用。当前 allowlist 为空。机器性能标记迁移时需同步其消费者，不能直接删除测试依赖的协议输出。

CI 的 Draft PR 只跑 Linux，ready PR 和 preview push 跑三平台。输入和已提交生成物均由 Git 持有，每个 worktree 本地重建、检查；没有跨工作树可复用 identity stamp，不复制其他工作树的生成物。这些类型无运行时 I/O、不写 app bundle、插件资源或安装目录，不影响签名与 Sparkle delta。

PR3 引擎采用按角色事件族：`lsp.*` 使用 `lsp/{server}`，`vcs.*` 使用 `vcs/{provider}`，`plugins.host.*` 使用 `plugins/{plugin}/host`。Core 从显式 role 与 catalog 身份字段选事件，目录模板仍是通道唯一来源；不允许任意输入 channel 改写普通事件。非法段使用稳定的 SHA-256 前缀身份，不丢弃日志或影响插件启动。stderr 的 reader 限制为每行 4 KiB、每秒 200 行，再走目录 text 的 1 KiB 脱敏规范化。trace 默认关闭，宿主通过 `lsp.setDetailedDiagnostics` 显式启用；`lsp.session.updated` 的 owner 已转交 Core，宿主不再重复发同一状态事实。

上游明确严重度通过独立目录事件保留：`window/logMessage` 和 `window/showMessage` 的 type 1/2/3/4 分别为 ERROR/WARN/INFO/DEBUG，未知类型为 DEBUG。未分类 stderr 是 DEBUG 排障证据，流名称不表示警告；实际进程或协议失败由 `*.session.failed` 记录 ERROR，正常关闭仍是生命周期状态。插件自身使用独立协商的 `litheLogging` 1 与 `lithe/log`，由 Core 把四种受控事实映射到插件目录事件，不能再用 stderr 或任意自由消息代替。协议字段、op、限额与 fixture 以 [插件契约](../contracts/plugins/v1/README.md#structured-plugin-diagnostics-logging-protocol-1) 为准。

详细诊断只接纳 `$/logTrace.message` 摘要；`verbose` 可能包含原始 RPC 载荷和文档源码，禁止进入 v2 text。凭据脱敏和 1 KiB 限长不代表源码可以落盘。初始化完成前的开关只保存目标状态，Core 在 `initialized` 之后发送通知。

PR3 macOS 将 CoreLogRecord 原样交给统一 LogSink/MacLogStore，按现有 drain、flush 和退出节奏一次排空 Core 队列，保留 ts/op、分配 seq，并继续 validateCatalog:true；不新增空闲轮询或独立 writer。启动者显式声明 role、真实 pluginId 与 VCS logSubject；宿主不解析 providerID。详细诊断类别沿用 lsp→language、vcs→git、plugins→plugins，对活动和新会话发送 lsp.setDetailedDiagnostics，15 分钟单次到期关闭，失败以 app.logging.diagnostics_failed 记录一次。

v1 detail/message/level 保持兼容原文，v2 字段通过独立 EngineLogInput 传递，禁止从 detail 反解。stderr 唯一兼容变化是从任意 trim 的读取块改为逐行文本；保留行内空格、移除 LF/末尾 CR，并应用已声明的有界长度和限流。原始通知 JSON、projectCount=N 和 navigation 格式不变。PR4 已删除 LanguageToolingSessionManager 的 100 条 v1 内存缓冲和旧语言服务日志标签页；macOS 日志窗口统一读取 v2 会话文件与写入器的实时批次，不写 v1 文件。

本地启动前由 MacLogStore 用 Core plugin_files_path 创建当前 sessions/<session>/plugins/<id>/files/，目录 0700，描述符相对 no-follow 遍历防止符号链接越界；只属于当前日志会话，不注册为跨工作树可复用构建资源，不写 bundle 或安装目录。存储不可用时不传 logDirectory，使用 ${logDir} 的模板按现有 invalidRequest 失败。远程进程不能写本机日志目录，因此同样不传并拒绝该变量。安装验证只使用未创建的占位目录校验展开，不启动或写入。

目录遍历与 scratch 清理复用 PR1 预留 app.search.directory_skipped、app.workspace.directory_skipped、app.workspace.scratch_cleanup_failed，error 仅固定消息和稳定类别；删除重复 app.project.directory_skipped、remote.scratch.cleanup_failed。远程 cleanup 仅记录 ClientError 稳定分类，不复制错误正文。

PR3 审查修补：Core 生命周期事实挂在原有 `type:stateChanged` 运行时事件上，复用日志事实的 `prepare_catalog_event` 校验，不额外增加 v1 log 行。Swift 在事件分支前转发任何携带 coreLog 的事件一次，语言服务、VCS、构建、工具链和后端均适用。`*.session.updated` 的 state 指 Core 会话生命周期，owner 仍是 lithe-core。

宿主在实际调用点发 `lsp.session.stage_changed`，阶段闭集为 requested/resolving/registered/stopping/cancelled；缓存清理成功发 `lsp.cache.cleaned(removed)`，与 Core 配置键清理的 configuration.cleaned 是不同事实。两者选 DEBUG，因为它们解释内部启动编排和缓存维护，不需要常态落盘。ready/terminated 由 Core 的 protocol.initialized 和 session.updated 表达，宿主仅保留原 v1 缓冲行。阶段、缓存、degradation/issue 事件统一使用 Core 计算的段；manager 按 providerID 缓存成功或失败结果，最多 128 项，满时清空缓存，失败仅跳过对应宿主 v2 事件，不改变原行为。

四个链接进 Core 的辅助库通过各自的 `failure_log` 注入函数指针交付失败事实，依赖方向保持不变；未注入时只增加原子计数，不写 stderr。Core 的 `diagnostics/helper_failures` 是唯一安装处，JSON dispatcher、独立 ACP FFI open、直接 IDE dispatcher 和 AskPass 入口在调用 helper 前统一经过该 `Once`。sink 仅转换标量字段，随后走相同目录校验、脱敏和 256 条 Core 队列。新增事件 owner 均为 `lithe-core`，错误只保留固定摘要和类别。转发 accept/bridge 失败的目录 rate 为每分钟 12 条。

辅助库收尾只记录丢失数据、能力或清理结果的意外错误。已断开的连接、已退出进程和远程关闭/取消的 Disconnected 或 Timeout 在类型化 helper 中豁免；ACP Cancel 的 InternalError 无法区分正常断连与序列化失败，按预期缺失豁免。转发 accept/bridge 的 rate=12 只限制仍需记录的失败，正常断连不占日志配额；强制终止后进程仍未退出的最终超时保留 WARN。
