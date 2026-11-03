# 结构化日志 v2 事件目录

`shared/logging/events/<root>.json` 是事件声明的唯一来源。此 PR 只增加目录、类型、编译期生成物和门禁，不接入写入器、不迁移现有调用，也不改变运行行为。日志消息是供诊断使用的英文事实，**不走 i18n**；界面上的错误、提示和操作名称仍须走共享 i18n。

## 声明与通道

固定根为 `app`、`editor`、`perf`、`lsp`、`vcs`、`run`、`debug`、`terminal`、`remote`、`agent`、`update`、`plugins`。每个根恰有一个 JSON 文件，没有实际调用的根保持空数组，不预造事件。事件 ID 是小写点分的稳定标识，如 `editor.document.save_failed`；结果词使用过去时。`owner` 标明维护模块。

通道由固定根和可选段组成。动态段只能来自插件、provider、server 或内部连接等已校验的 ID，格式为 `^[a-z0-9][a-z0-9._-]{0,63}$`，同时拒绝末尾点号和 Windows 设备名（如 `con`、`nul.txt`、`com1`）；禁止显示名称、任意目录、用户输入和命令行。占位符必须引用本事件必填的 `id` 字段。固定段也是目录声明的一部分。Core 与生成器都只接受根、非插件根/段及插件宿主三种形状。插件宿主通道统一为 `plugins/{plugin}/host`。活动文件使用 `<channel>.log`，轮转使用 `<channel>~1.log`；`~` 不在通道字符集中，因此 `vcs/git.1` 不会与 `vcs/git` 的轮转文件冲突。`_overflow` 使用同样的文件头和轮转规则。Swift 的 `LogSegment` 失败返回 `nil`，不得用未知输入强制解包。

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

Swift 的事件值是**未经脱敏的内存输入**，不能自行序列化落盘。Core 的 `catalog::validate_fields(id, fields)` 校验磁盘键展开后的字段类型、必填、未知字段、长度和错误组件完整性；它不替代隐私脱敏。`path` 上限 4096 字节；error/text 上限 1024 字节。跨边界适配器在后续 PR 中连接 Core 脱敏、格式化和写入路径，禁止另写 Swift 格式化或隐私策略。

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

## 用法门禁与存量

扫描生产 Swift 的 `NSLog`、stderr 写入、`os_log`、导入 `os.log` 后的 `Logger` 和 `.record(level:)`；扫描 Rust 的 `eprintln!`、`println!`、`dbg!`。词法遮蔽注释和字符串内容，排除 `Tests/`、`tests/`、`tests.rs` 及明确 `#[cfg(test)]` 项。此门禁检查已列出的直接写法，不试图跨文件追踪别名或动态调用。

`log-usage-baseline.json` 按文件、规则精确计数，原因固定为“待 PR2/PR3 迁移”。`log-usage-allowlist.json` 是永久例外，必须有具体的协议/架构理由和精确计数；当前为空，没有预先豁免日志调用。禁止把新违规追加到基线来通过检查。机器性能标记迁移时需同步其消费者，不能直接删除测试依赖的协议输出。

CI 的 Draft PR 只跑 Linux，ready PR 和 preview push 跑三平台。输入和已提交生成物均由 Git 持有，每个 worktree 本地重建、检查；没有跨工作树可复用 identity stamp，不复制其他工作树的生成物。这些类型无运行时 I/O、不写 app bundle、插件资源或安装目录，不影响签名与 Sparkle delta。
