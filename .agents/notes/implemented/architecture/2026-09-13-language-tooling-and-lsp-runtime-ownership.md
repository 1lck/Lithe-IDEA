# Agent 笔记：语言工具分层与 LSP Runtime 归属

状态：已实现

## 先说结论

编辑器只依赖统一的语言能力接口，不直接绑定某一种语言服务器。LSP 子进程、协议状态机、文档版本、请求期限、诊断和优雅关闭统一由 Rust Core 持有；平台只负责可执行文件发现、UI 投影，以及由不透明操作 ID 标识的完成回调。以后新增语言服务，应接入这条公共路径，而不是在各个平台各写一套生命周期。

### 通用 Runtime 与 Java 领域适配的范围

通用 LSP 传输、会话、文档版本和取消边界仍然适用。Java/JDT 的启动参数、项目导入与虚拟源码语义已经迁到 Java 插件后端（[lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java)，#1495），Core 不再为 Java 保留领域分支，也不另建第二套通用 LSP Runtime。

## 问题

语言能力不等于"已经启动一个 LSP 进程"：轻量本地能力（关键字、当前文件符号）不需要外部进程，而真正的语言服务能力必须以服务器协商结果为准，不能按语言名称硬编码假设。

如果 LSP 状态同时保存在平台和 Core 两侧，文档生命周期、初始化、请求、传输、诊断和关闭都会出现重复且互相竞争的真值，同一个会话在两侧的判断可能不一致。新增语言服务器时，又要在两侧分别维护一份生命周期逻辑。

## 决策

### 状态栏只投影会话，日志不接管协议

LSP 入口始终保留，即使没有源文件或没有运行会话。服务器列表只能来自已接受、已注册且当前启用的插件所声明的语言服务器；宿主内置的语言目录、文件扩展名识别和工具候选不等于服务器注册，不能填充此列表。禁用、隔离或等待重启的插件不贡献行。

名称复用插件声明的可执行名字段，没有该字段时直接显示插件 ID，不回退到语言名或服务器自报名称。状态与版本由现有会话投影；代码诊断不改变服务器状态。空列表仍提供日志和设置入口，批量操作只针对已有会话，不因打开菜单启动服务器。

单个或全部服务器的停止与重启只影响当前会话，不改工作区启用偏好。停止使该提供方已排队的激活请求失效；下一次打开或编辑匹配文档仍可按需启动。重启先等待旧进程的终止事件和异步资源释放，再重新同步匹配的打开文档，不能把"重启"静默变成"停止"。停止等待有本地期限，超时返回失败并保留占位，不冒险与旧工作区目录锁重叠。

日志视图打开或聚焦编辑区的"LSP 日志"标签页，每个工作区窗口只有一个，切换服务器仍在同一标签页完成。标签页读取已脱敏的磁盘日志和实时广播，由 Core 解析通道，宿主不用 provider ID 拼通道名。"清空视图"只隐藏所选服务器已显示的记录，不删除持久诊断日志。

Core 当前没有原始协议跟踪（Server Trace、RPC Messages）采集；不要在平台再实现 JSON-RPC 抓包器，也不要把文本日志复制成假通道。将来确需采集时，应在 Core 协议所有者处设计显式启用、脱敏和预算，再扩展契约。

### 组件边界

```text
Editor / feature model
  -> LanguageToolingSessionManager（文档同步、provider 选择、结果降级与合并、诊断归属）
  -> LanguageFeatureProvider 路由
       -> BuiltinLanguageFeatureProvider（当前文件符号、轻量 hover 与导航、关键字）
       -> LanguageServerFeatureProvider（把协商后的服务器能力适配到统一接口）
            -> 语义命令调用、typed event 投影、不透明 operation ID 交付
                 -> Rust LSP runtime（子进程 + stdio + 状态机 + framing + JSON-RPC + 文档版本 + 请求期限 + 诊断 + 关闭/崩溃处理）
                      -> gopls / jdtls / rust-analyzer / ...
```

Core 的 LSP 实现位于 Core 仓库的 `rust/crates/lsp-transport/`、`rust/crates/lsp-client/`、`rust/crates/lsp-engine/` 与 `rust/crates/lsp-policy/`。平台 adapter 只负责可执行文件与运行环境发现。平台层不持有 LSP 请求 ID、原始 JSON、framing 缓冲区、子进程句柄或文档 open 状态的真值。

### Provider 路由

优先级由高到低为语言服务器（200）、预留的项目符号（100）、内置（0）。补全依次收集所有成功结果并按 `label` 去重；Hover、Definition、References、Implementation 返回第一个非空结果，LSP 不可用时降级到本地 provider。Rename、Formatting、Code Action、Resolve 与 Execute Command 目前仍是 LSP-only，未声明能力时返回明确的 capability 错误。单个 provider 抛错不会让路由提前结束。

### 补全列表状态

补全结果的 `isIncomplete` 是列表级标记，Core 必须保留，空列表也不能丢；平台合并本地候选时保留任一 provider 的未完整状态，并映射到编辑器的增量刷新机制。继续输入需要新候选时由编辑器重新请求，不在各平台各实现一套缓存刷新算法。仅把 `isIncomplete` 固定为 true 会增加不必要的服务器请求，因此保留服务器的实际值。

### 诊断与文档归属

诊断按"已打开文档的 URI"归属，但服务器不一定用同一种写法回报路径。JDT 等服务器会以解析符号链接之后的位置发布诊断，例如宿主以 `/tmp/...` 打开的文件，诊断发到 `/private/tmp/...`。逐字比较 URI 会丢掉整条诊断。因此 Rust 引擎在把 `publishDiagnostics` 交给客户端状态机之前，先看发布的 URI 是否对应某个已打开文档；对不上时比较两边解析后的真实文件，命中就把诊断改写到该文档自己的 URI 上（`diagnostics_addressed_to_open_document`）。平台拿到的诊断 URI 因此始终是打开文档时使用的那个，不需要各自再做路径折叠。该规则对所有语言生效。

Viva 的文档同步入口在 `desktop/internal/workbench/pluginsync.go`：文档打开后由 `pluginlsp.Tracker.Open` 按 Core 解析出的 URI 打开，编辑产生的范围经 `Tracker.Change` 发送，保存和关闭分别调用 `Tracker.Save` 和 `Tracker.Close`。服务器晚于文档启动时，宿主在会话注册后补开该语言所有已打开文档。项目关闭、服务器停止或重启会让每个文档的 `documentSync.generation` 失效，旧的后台结果不能写回新会话。

Viva 的语义入口在 `desktop/internal/workbench/pluginsemantics.go`：定义跳转、Hover 与显式补全都通过 `lsp.request` 提交，只消费 Core 规范化后的结果；接受补全时由 Core 计算最终文本，宿主不解析原始 LSP Location，也不自行排序或去重候选。请求只在文档同步完成且会话就绪后提交；光标、文档版本、标签页、服务器或项目变化会取消旧操作并丢弃迟到结果。

### 会话生命周期不变量

会话生命周期必须是单一判别状态；capability 协商单独表示为 `unknown` 或 `known`，不能由 `ready`、`featuresKnown`、`supportsFeature` 等多个布尔字段组合推导。跨边界失败必须保留稳定的 `code`、`stage`、退出码和诊断详情，不能通过错误文本猜测超时；面向用户的提示文案由各端本地化资源统一生成。

会话由 Rust engine 持有长生命周期的 `sessionID -> RuntimeSession` 注册表。`syncDocument` 由 Rust 决定发送 `didOpen`（版本 1）还是 `didChange`（递增版本）；服务器声明增量同步且请求携带范围时发送增量变化，否则发送全文。`initializeTimeoutMilliseconds` 只约束标准握手；JDT 的 ServiceReady 等待独立计时，平台不得再添加自己的固定就绪期限，最终就绪只认服务器的 `language/status: ServiceReady`。

启动顺序：平台提交 typed `startServer` → Rust 生成启动参数、engine 创建会话并发送 `initialize` → 保存 capability，发送 `initialized` → 服务器报告就绪后再发送项目配置 → manager 只在真实 `ready` 后发布 capability → Rust 以 LSP request ID 关联期限，用不透明 operation ID 投影终态结果。停止会话时先 `shutdown` 后 `exit`，服务器无响应则由超时路径强制停止，不直接用 `terminate()` 代替。

进程创建后启动失败时，进程必须在有界期限内确认退出才算清理完成，不能只发信号就丢弃会话。普通调用方拿不到会话 ID 时，Core 把未完成清理的会话记入内部待清理列表，下一次显式启动前最多重试一次有界释放，仍未完成就拒绝启动新进程，并保留原始启动错误。非 Windows 平台在期限内轮询根进程退出；Windows 等待整个进程树退出。

### 大型导入的等待策略

Java 导入的 45 秒观察阈值只用于记录带最后进度的日志警告，不作为失败条件。JDT 的 `ProgressReporterManager` 只在任务回调时发送进度，没有定时心跳，m2e 批次导入也不能保证每个批次在 45 秒内上报变化，因此"没有新进度"不能证明进程卡死。只有固定的总期限（10 分钟）、服务器明确报错或进程退出才使导入失败。就绪仍只认 `ServiceReady`，不从日志中的项目数量或百分比推算。

### 平台启动编排（Windows）

大型工作区的仓库扫描和语言服务导入会竞争磁盘与进程资源。Windows 的首次 Git 准备先发现工作区根目录中的所有仓库并等待各仓库状态查询；后台语言服务探测与编辑器恢复共用这次准备，启动解析必须在解析构建上下文之前等待它。准备任务按工作区实例和根目录集合复用，等待期间实例或根集合变化时丢弃旧结果；Git 失败保留日志并允许语言服务继续，沿用底层操作的有界超时。

### 目录与工具发现

内置 provider 目录随 Core 发布；项目可通过 `.lithe/lsp/language-providers.json` 按 `id` 覆盖字段、新增或用 `disabled: true` 禁用，格式以 Core 的契约为准。`executableNames` 按顺序尝试，`validationArguments` 会在候选进入会话前执行（例如排除缺组件的 rustup proxy），探测结果按路径和参数缓存 30 秒。

发现只按固定顺序查找可执行文件（项目 `.lithe` 工具目录、`LITHE_<TOOL>_PATH`、`PATH`、常见系统目录、语言专属环境变量），不自动安装软件。项目级配置只能声明类型化字段（可执行名、参数），不能声明 shell、任意安装命令或关闭路径/URL 校验。发现不到工具时只提示用户安装，不做自动下载。

语言服务使用的运行时由插件声明或平台固定选择，不依赖用户 `PATH` 上碰巧存在的同名程序；项目目录中的同名工具永远不会被选中，因为服务器会在打开文件时自动启动，不能执行仓库自带的程序。

### 当前限制

只支持 stdio transport；会话以 provider ID 加单个工作区根为单位，没有多根会话；`workspace/applyEdit` 只提供协议确认和规范化的编辑数据，实际应用仍须经过编辑器的工作区安全校验；目录描述的是"可尝试启动的工具"，最终功能以运行时服务器的 capability 为准。

## 考虑过的备选方案

- **只把导入超时改成更大的空闲超时**：仍把可选进度当作心跳，不能消除误杀。
- **把任意 JDT 日志都当作进展**：重复日志可能掩盖真正停滞；就绪信号和总期限分别负责正确性与资源上限。
- **维持平台与 Core 两侧各自持有 LSP 生命周期状态**：改动成本最低，但文档生命周期、初始化、请求、传输、诊断和关闭六个关注点会重复且互相竞争，因此收敛为 Core 单一持有。
- **会话和 capability 用多个独立布尔字段表示**：布尔组合会产生无法枚举的中间态，因此改为单一判别状态加独立的 `unknown`/`known` 标记。
- **把 catalog 的 `languageServer` 标记当作功能支持的证明**：catalog 只是"可尝试启动的工具"清单，功能是否支持只能由 `initialize` 响应和动态注册结果决定。
- **发现不到工具时自动下载或安装**：项目配置属于受信任的可执行工具配置，一旦允许任意安装命令或跳过路径/URL 校验，会把不安全的通用安装逻辑暴露给项目文件；因此发现只查找，安装需要用户自行完成。
- **依赖系统 `JAVA_HOME` 运行 JDT**：语言服务的 JDK 版本与项目运行的 JDK 经常不一致，读取系统环境会引入不可控的版本漂移，因此语言服务使用随插件声明的固定 JDK。

## 后果

- 无进度但仍在工作的导入可以使用完整的准备时间；真正停滞但未报错的导入会等到总期限，用户仍可关闭工作区或重启语言服务。不能用任意日志不断延长总期限。
- 新语言服务器接入只需要在 Core 一侧实现生命周期，平台只做工具发现和 UI 投影，不需要在各端维护状态机。
- 单个 provider 的失败、缺失或空结果不会阻断仍可工作的本地能力，故障隔离在路由层完成。
- 代价：Core 承担了更大的状态面（会话注册表、每会话的文档版本、期限和诊断），跨语言服务器的行为差异必须进入 provider 适配器或描述符，不能在 UI 或 manager 里按语言分支，这对新增语言服务器提出了更高的前期设计要求。
- 需要重新评估的触发条件：需要 socket/TCP transport 或多根会话时，当前单 provider、单根的假设需要重新设计。

## 验证

- Core 侧：共享 fixture 覆盖 LSP 状态与协议（未初始化进程不能变为 ready；initialize 出错不能变为 ready；两次同步分别产生版本 1 的 open 与版本 2 的 change；请求期限会移除 pending 请求；超时后的迟到响应被忽略；关闭文档会清除诊断状态；畸形 `Content-Length` 产生 transport failure）。运行 `scripts/desktop/desktop-go.sh test ./internal/workbench/...` 与 `./internal/pluginlsp/...` 验证桌面侧适配。
- 真实语言服务端到端：`desktop/internal/workbench/pluginsync_e2e_test.go` 与 `pluginsemantics_e2e_test.go` 使用真实语言服务器覆盖打开、增量编辑、诊断到达、保存、关闭和项目切换；这类用例依赖本机工具，不能替代 Windows 实机验收。
- 路径归属：`scripts/desktop/verify/verify-runtime-bundle-immutability.sh` 确认语言服务器相关的运行时资源不写入发行目录。
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- Core 仓库的 [`rust/crates/lsp-engine/`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/lsp-engine) 与 [`rust/crates/lsp-transport/`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/lsp-transport)
- `desktop/internal/pluginlsp/`
- `desktop/internal/workbench/pluginsync.go`
- `desktop/internal/workbench/pluginsemantics.go`
- `desktop/internal/editorview/`
