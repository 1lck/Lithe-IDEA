# Agent 笔记：Windows 原生面板函数借用工作区 Provider 会话

状态：已实现

## 先说结论

原生插件面板的函数调用现在借用工作区已经持有的 Provider 会话，即负责提供构建模型的后端进程。
一次函数结束或取消只释放自己的请求，后端状态持续到工作区关闭、插件失效或既有 Provider 清理路径完成。
这修复了“修改树节点后刷新又恢复原值”的生命周期错误。实现改动不代表生产准入：
`buildSystems`、`buildProviders` 和 `ui:3` 仍须按完整版本验收，不能用单个控件或受控对端测试开放。

## 问题

Windows 原生面板之前沿用一次性设置动作的调用路径，每次函数都新建并销毁进程。
参考 Mac UI Lab 的重命名、添加、反转等动作把当前节点保存在后端会话中；动作后紧接的数据刷新
如果启动另一个进程，就只能读到初始值。另建一份宿主节点模型会产生第二个数据真源，也无法推广到其他插件。

## 决策

原生面板登记仍绑定实际窗口、工作区代次、插件包完整身份及声明的构建实例。准备调用时复用 Provider
现有的只读程序审查，核对它与函数确认框展示的启动计划和已解析程序完全一致，取消确认会丢弃该审查。
同意后才确认或启动 Provider；函数结果、进度和注册表继续由 Rust Core 解释，宿主不增加私有协议解析器。

后端进程由 Provider 注册表持有。调用方只持有本次请求的等待器，取消通过已有请求 guard 撤回
精确的 operation ID，不停止其他面板、模型或构建请求。唯一事件读取者继续是 Provider 的事件泵；
它按会话和 operation ID 转发进度，插件停用、替换及工作区关闭仍经过原有租约和进程清理屏障。
共享语言服务器仍须由 Core 显式协商并登记函数，不能仅凭共享进程推断函数存在；
网页函数仍只接受独立 Provider。原生面板与明确选择共享语言 Provider 的设置动作，
现在可借用已经由构建模型审批授权的编辑器语言会话；这属于候选实现，生产能力门控继续关闭。
借用前核对同一窗口、工作区代次、插件完整身份、构建实例、语言入口和完整启动计划。
没有匹配的现存编辑器所有者时明确失败，函数入口不另启语言进程，也不接管其他编辑器会话。

正确做法：`tree.rename` 和后续 `tree.nodes` 使用同一工作区 Provider，取消 rename 不取消另一条构建请求。
不要这样做：为了刷新节点重新启动后端，或者把后端私有节点状态复制到宿主的另一份长期模型。

受控完整包由 `native_workflow_fixture.py` 生成，复用固定 Mac UI Lab 的全部原生声明，提供独立协议对端、
构建/测试输入及设置动作。完整 requirements 和正常社区确认保留；它明确是 unsigned 验收输入，
不能冒充外部正式签名包或 SDK 验收。驱动复用既有 Windows Job 与 AppSession，源码/EXE 身份、
发行镜像、安装包和 ZIP 各自验证。真实 IME、原生焦点与尚未执行的完整版本行为保留独立 pending。

## 考虑过的备选方案

- 每次函数重新启动进程：会丢失插件会话状态，拒绝。
- 为原生面板再建一套长期后端表和事件读取器：会与构建 Provider 争抢事件并复制退出屏障，拒绝。
- 让宿主维护一份插件节点状态：违背数据由 Provider 提供的边界，不能保证其他函数语义，拒绝。

## 后果

同一工作区的原生动作与刷新保留后端状态，取消边界变小，继续复用成熟 Core 路由和原有进程所有者。
代价是函数结束后后端不立即退出，资源由工作区与插件生命周期收回；调用方必须保留失效检查，
不能把调用结束误当成后端停止证明。新增的 fixture、工作区、审查记录和报告都是单次验收状态，
没有可复用构建印记，不允许跨 worktree 共享；可写状态经平台存储 adapter 或受控工作区，
发行安装目录保持只读，不改变代码签名或更新源基线。

目录与函数登记必须比较同一种声明表示。实际产品曾把目录中的原始图标
`{"host":"refresh"}` 与设置快照中 Core 补全的 `mode: template` 比较，导致合法面板总被判为
上下文过期。目录现在从已复验的包字节取得 Core 归一化声明；包摘要、租约与登记前后身份检查
继续独立执行。不要通过忽略声明差异或跳过包完整性来消除这个错误。

按钮专用表单也没有可编辑控件。Core 会省略空的 `controls`，宿主须把缺省数组作为空集合来
核对空 `values`，不能因此拒绝合法面板；任何未声明字段仍拒绝。这个边界只用于已验证的原生声明，
不允许渲染器补写控件或选择调用目标。

选择独立 Provider 的一次性设置动作仍拥有独立进程，但必须等待 Core 确认关闭。`stopServer` 发起异步关闭后，
直接调用 `destroyServer` 会因会话仍在运行而失败，即使后端随后正常退出。现在由原有清理 worker
在八秒期限内读取该会话的终止事件，再请求销毁；如果另一条调用已取走终止事件，仍以 Core
成功销毁作为唯一清理凭据。超时、销毁失败和未知 worker 结果继续保留租约及原始 join handle，
不把“已发送退出”当成“已清理”，也不重复派发结果未知的销毁。

函数启动与调用协调器会并行检查同一个构建登记表。普通读取占用互斥锁时，`try_lock` 失败只表示
锁被占用，不能据此断言设置或工作区已过期。R35 的确定性回归保持一个读取不结束，同时查询同一
函数作用域，旧实现错误返回 `plugin.function.staleContext`；登记表现在使用读写锁，读取共享同一个
数据真源，修改仍独占。取得读取后仍核对工作区代次、待刷新、执行暂停及插件设置修订号；等待写入
结束不能跳过这些条件，也不能恢复重载前的审查。不要用忽略锁失败、返回缓存修订号或自动重试替代。

这修复了已证明的锁竞争误拒绝。R34 首次产品失败只保留了 IPC 和后端记录，没有锁级轨迹，不能把
它的历史原因追认为已唯一证实；同一镜像的成功复跑也不是这个证明。产品验收应保留 prepare、confirm、
终态与取消的精确 operation ID 和快照身份，遇到真实失败立即记录，禁止由“没有错误”推定成功。

目录索引策略也可能在语言服务器进程启动后撤销本次启动。尚未交给原生宿主的会话，必须先在
Core 内确认进程树已退出才能从登记表删除；清理失败则交出失败会话的身份，让既有原生租约继续
等待可重试的销毁。身份已经交出的会话即使启动随后取消，也必须保留到 `destroyServer` 成功。
不要把“已发送终止”或“会话查不到了”当作正向清理凭据，否则插件替换可能早于进程树退出。

普通 `lsp.startServer` 没有原生登记回调。失败后仍需清理的会话由 Core 内部 backlog 保留，
首次尝试销毁后继续返回原启动错误；用户再次明确启动时，先重试一个会话的有界销毁，
清理未完成就拒绝派生替代进程。清理成功才删除登记与 backlog。不得用空回调吞掉身份后
放弃回收责任，也不另起没有可达重试责任的后台回收线程。

设置保存与运行时生效是两个结果。磁盘保存成功而即时配置推送失败时，页面保留已回读的保存值，
显示错误与显式重试入口。重试先读取设置及包身份，只有与保存凭据完全一致才重做生效动作；
它不再次写盘。重试期间合并重复点击，页面退出或代次失效后不发布迟到结果。
不要把失败副作用伪装成未保存草稿，否则再次保存可能重复写入，或把外部的新值推回旧会话。

受控工作流同时提供独立 Provider 和共享语言 Provider 两个完整版本，通过正常升级切换。
函数撤回与恢复经真实协议请求并等待 Core 回执；未收到回执不能宣称登记成功。
卸载会删除可写插件状态，因此驱动在升级、重载和卸载前保存后端记录，保留阶段及进程身份，
不能在卸载后用空日志证明没有请求。新增阶段只扩大整套验收的有界总预算，每次等待仍保持局部期限。

共享语言会话的即时配置是可变状态，不能一直拿启动时的配置与新审查比较，否则保存成功后的下一次
原生函数仍会被误拒绝。原生 Core 入口现在串行执行同一会话的配置更新，仅在 Core 成功且所有者仍有效时
记录新配置；新的函数审查仍精确匹配程序、参数、环境、初始化选项和已成功接收的配置。
不要忽略整个启动计划差异，也不要在通知失败时提前更新身份。原始启动证据保持不变，配置记录随会话销毁。

设置保存后，原生面板原有登记仍绑定保存前的设置摘要。首次调用必须拒绝旧摘要，用户点击 Retry 后，
先关闭旧句柄，再以新的设置与包身份登记并重新审查；即时通知成功不能自动放行旧登记。
产品验收要显式经过这个重试入口，并确认拒绝阶段没有 confirm，后续函数仍借用同一个语言进程。
观察器保存脱敏后的结构化原生错误码，同时原样转交回调；不能把 `[object Object]` 当作可核验的失败原因。
项目设置重载先完成原生清理和检测，再通过提示条发起正常的模型审查；验收必须批准该审查并核对同一
reload receipt 与 operation ID 的加载结果，不能等待提示条自动消失，也不能另点一次模型加载代替它。
项目 reload 只重载模型，不替用户重启共享语言服务器。先保存改变启动参数的 restart 设置，
再要求旧语言进程满足新计划，会被精确身份校验拒绝；不能因此放宽匹配。验收应先证明模型重载
保留共享语言进程，再单独保存 restart 设置，并经明确停用、启用与正常模型审批证明新进程读取保存值。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest windows/tauri/src-tauri/Cargo.toml --report .artifacts/test-stability/native-provider.json`：检查会话注册/进度隔离、动作后刷新、函数取消与其他构建等待器共存。
- `build::tests::function_scope_readers_do_not_revoke_each_other` 与 `function_scope_keeps_refresh_suspension_reload_and_workspace_revocation` 覆盖读取竞争、真实失效及重载完成后旧 revision 不复活。
- 同一 Rust 入口还覆盖设置动作的延迟关闭、其他会话终止事件隔离、关闭期限、事件已取走但销毁失败后的租约保留与重试。
- Core 的 `indexing_startup_cancels_when_policy_changes_during_process_launch` 与 `native_owner_retains_indexing_cancellation_after_registration` 分别控制身份交出前后的策略撤销，验证清理失败保留身份、解除阻塞后才允许销毁。
- Frontend 逐项计时入口运行 `declarative-settings-effect-retry.test.ts`，覆盖只重做副作用、重复点击合并、外部设置/包冲突及退出后的迟到结果隔离。共享模型取消测试等待真实初始化信号，不假定固定微任务次数能够完成动态模块加载。
- Provider 回归覆盖即时配置后新审查的精确匹配，以及失败、其他窗口和已撤销会话不能改变身份。产品驱动在即时配置后立即执行树函数和设置动作，并核对仍是同一个语言进程。
- 源码绑定 x64 镜像的连续受控原生工作流已通过13个阶段：即时配置后的旧摘要拒绝和显式 Retry、同一语言进程的模型重载、明确停用/启用后的新进程读取 restart 值，以及正常退出后的资源哈希不变。它使用 unsigned 受控协议对端，五项完整版本/人工视觉/外部包/其他架构边界仍跳过；不能据此开放生产能力或认证先保存 restart 再仅 reload 模型的组合。
- `python -B scripts/plugins/host-acceptance/native_workflow_acceptance_test.py --report .artifacts/test-stability/native-workflow-helpers.json`：离线检查固定输入、篡改拒绝、门控报告及真实受控对端状态；不是产品验收。
- `python -B scripts/plugins/host-acceptance/native_workflow_fixture.py --output .artifacts/plugin-host-acceptance/native-workflow-fixture-current` 生成本树输入；`native_workflow_acceptance.py --fixture-root .artifacts/plugin-host-acceptance/native-workflow-fixture-current --report .artifacts/test-stability/native-workflow-preflight.json --preflight` 只做预检。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh` 与 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 验证边界；完整原生运行还须提供源码绑定的隔离构建与独立 profile，由同一个驱动持有至清理完成。

## 适用范围

`windows/tauri/src-tauri/src/plugin_host/functions/native.rs`、
`windows/tauri/src-tauri/src/plugin_host/functions/runtime.rs`、
`windows/tauri/src-tauri/src/plugin_host/functions/provider.rs`、
`windows/tauri/src-tauri/src/plugin_host/provider/`、
`windows/tauri/src/features/plugins/declarative-settings-session.ts`、
`scripts/plugins/host-acceptance/native_workflow_acceptance.py`。
不改变 Core 函数协议、Mac 参考产品、Java 专属接线、签名与正式分发要求。
