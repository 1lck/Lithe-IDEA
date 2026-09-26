# Agent 笔记：Windows 本机 AI 用量与订阅额度

状态：已实现

## 先说结论

Windows 版新增一个「AI 用量」右侧工具窗口，用本机 Claude Code 和 Codex CLI 自己写的会话日志统计 token、估算费用并列出每一次请求，不需要代理，也不需要登录任何账号。日志读取、增量续读和同一请求的去重都放在 Tauri 主机（应用里的原生 Rust 层，位于 `windows/tauri/src-tauri`），前端只接收合并好的每请求记录。订阅额度是另一条独立的数据通路，只调用官方只读接口，并且只认订阅登录的本机凭证；用 API key 或自定义中转地址读不到额度时，界面显示「不适用」，而不是当成故障。

## 问题

本机装了 Claude Code 和 Codex CLI 之后，用户看不到自己用了多少 token、花了多少钱、还剩多少订阅额度，只能等 CLI 自己在某个时刻提示。

这些数字理论上都能从本机拿到，但直接做会踩三个坑：

- 会话日志很大。重度使用会累积到 GB 级别的 JSONL，一次性全量读取和解析会让界面卡住。
- 同一次请求会在日志里被写多行。Claude Code 按消息内容块各写一行，同一个 `message.id` 会重复 2 到 4 次；如果调用方把日志行逐条相加，用量会被放大。
- 日志只记请求，不记订阅额度。额度需要另外访问服务商的只读接口，而接口只对订阅令牌有效。

## 决策

### 日志读取和去重留在主机层

主机的 `usage_collect` 命令负责定位用户目录、遍历会话文件、按偏移续读、按行解析，并把同一请求折叠成一条记录；前端只拿到精简后的记录、每个文件的读取状态和扫描耗时。

正确示例：前端传回上次的每文件状态，主机只读取新增字节，返回新的记录和新的状态。

不要这样做：在 React 里读取或解析日志文件，或者把上万条原始记录放进前端状态再聚合。首扫实测 408 个日志文件、24.9 秒、10092 条真实请求；如果不去重直接返回，IPC 载荷会从 3.3 MB 涨到 6.6 MB，增量续读后一次扫描约 163 毫秒。

### 同一请求只保留最完整的一条记录

折叠的键是「平台加去重键」（Claude 用 `message.id`，Codex 用 `response_id`），同键的多条记录只保留合计 token 最大的那一条，而不是最后出现的那一条。

实测 681 个出现多次的请求里，后面出现的行通常带更多字段；但也存在最后一行的合计为 0 的情况。保留「最完整」而不是「最后」，是为了让没有完整上报的记录不会把真实用量抹掉。代价是极少数情况下会选到较早但更完整的一行。

如果这条规则被改成「保留最后一条」，会话里出现半写完的累计行时用量会突然变小，而且没有别的依据可以纠正。

### 增量读取按文件偏移续读

每个文件记录上次读到的偏移量和当时的修改时间。偏移量超过文件长度说明文件被截断；偏移量正好等于长度但修改时间变了，说明内容被等长替换，两种情况都从头重读，不能续读。

只消费完整的行：文件末尾没写完的半行留在文件里，下次再读。这样 CLI 正在写日志时不会解析出半截 JSON。

### 额度是独立能力，失败要分类

额度探测整体留在主机层：读取本机凭证、发出只读请求、解析响应都在 `windows/tauri/src-tauri/src/quota.rs`，前端只调用一个 `usage_quota` 命令。这样 token 不跨进程边界，也不会进入前端状态。凭证只在本机读取、只在请求期间使用，不写入设置、不写日志；返回给前端的只有窗口数据或一个稳定的失败类别：`unsupported`（当前接入方式没有可查的额度接口）、`unavailable`（没有本机凭证）、`unauthorized`、`forbidden`、`rateLimited`、`timeout`、`network`、`unparsable`。

正确示例：接入方式是中转地址（用户自建或第三方代理）时直接返回 `unsupported`，界面说明「该接入方式查不到订阅额度」。

不要这样做：把中转地址或 API key 当成订阅令牌去请求，然后把 401 当成「额度查询失败」展示。接口语义上就不适用，报错会让人以为功能坏了。

### 本次只统计本机 CLI 日志

数据来源限定为 Claude Code 的 `~/.claude/projects` 和 Codex 的 `~/.codex/sessions`。Lithe 自己发起的 AI 对话不在统计范围内，因为它没有对应的日志源，也不该为了统计去复制一份请求记录。

## 考虑过的备选方案

- **把纯解析放进 `rust/lithe-core`**：`lithe-core` 承载跨平台确定性行为，理论上解析 JSONL 属于这一类。但本次只有 Windows 消费这份数据，而采集必须和用户目录、文件偏移、扫描状态放在同一层，拆开会让一次扫描跨两个进程边界。如果 macOS 以后也要这个能力，再把与文件无关的解析部分下沉到 `lithe-core`，主机只保留路径发现和增量读取。
- **在前端直接读凭证、发请求**：实现更短，也能复用已有的 provider 请求封装。但这两个文件（`~/.claude/.credentials.json`、`~/.codex/auth.json`）装的是订阅登录令牌，AI 提交那条链路已经定过边界：凭证由主机读取、只在请求期间使用，前端只拿到「有没有凭据」。让同一批文件在另一条链路上把令牌送进 WebView，两个功能会给出互相矛盾的做法，所以额度探测照同一规则放进主机。代价是响应解析要在 Rust 里再实现一份，前端不再有这一层可测的解析代码。
- **通过代理或中间人抓请求统计**：能拿到最精确的数据，但要求用户改 CLI 配置并让流量经过 Lithe，为了一个展示面板改变用户的网络路径，代价过高。
- **只做额度、不做日志统计**：额度依赖订阅登录，本机没有订阅令牌时整个功能都是空的；日志统计不依赖账号，先落地它才保证功能在 API key 和中转环境下也有内容。
- **同时移植原型的灵动岛和托盘面板**：能提高可见性，但会引入常驻浮层和托盘生命周期，与本次「右侧工具窗口加状态栏胶囊」的落点重叠，所以不移植。

## 后果

用户可以不开代理就看到本机 CLI 的 token 用量、估算费用和请求列表，也能在订阅登录下直接看到 5 小时和 7 天窗口的额度占用。费用来自本地价格表，没有公开价格的模型显示 `—`，不做猜测。

代价有三点：统计范围只覆盖 CLI 写入日志的请求，Lithe 内部对话不计入；价格表需要随模型更新维护；额度展示依赖接入方式，中转和 API key 下必然为空，这是环境事实而不是缺陷。

## 验证

- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml usage`：日志解析、去重折叠、增量状态和重扫判定。
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml quota`：额度窗口解析、连接判定、HTTP 状态到失败类别的映射和凭证优先级。
- `bun test src/features/usage`：聚合、定价、格式化、额度窗口选择和工具窗口开关行为。
- `bun run typecheck`：前端类型检查。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`：测试稳定性静态检查。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope WindowsRust`：Rust 单测试计时。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/usage`：本特性的前端单测试计时，与 CI 中的同名步骤一致。
- `node scripts/verify-agent-notes.mjs`：本笔记的格式、链接和路径校验。

## 适用范围

- `windows/tauri/src-tauri/src/usage.rs`
- `windows/tauri/src-tauri/src/quota.rs`
- `windows/tauri/src/features/usage/`
- `windows/tauri/src/platform/tauri-core.ts`
- `windows/tauri/src/features/layout/components/plugin-activity-rail.tsx`
- `windows/tauri/src/features/layout/config/item-order.ts`
- `windows/tauri/src/i18n/locale.ts`
