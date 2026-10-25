# Agent 笔记：Windows 声明式构建执行模型与安全调度（M4 设计）

状态：提议中

## 先说结论

Windows 要接入插件 API 3 的声明式构建系统（`buildSystems`，即插件用纯 JSON 描述"怎样认出工程、用哪个可执行文件、有哪些任务和测试"），方案是把全部构建协调放进 Rust 宿主的一个新构建会话登记表，原生界面和插件网页两个通道都调用这同一份事实；Core 的 14 个 `build.*` 命令语义只在 `lithe-core` 实现一次，Windows 经 `core_execute` 调用，不在宿主重写任何清单解释、argv 展开或输出解码。执行前统一走一条授权链：M1 信任闸门 → 生命周期隔离租约 → 窗口与工作区代次 → 操作 ID 与冲突检查 → Core 生成的计划校验。能力版本 `buildSystems:[1,2]` 与 `executableResolution:[1]` 只在对应行为完整验收后才声明，此前保持关闭。本设计依赖同一统一 PR 中 M1 的信任与安装记录接口；后续实现须等 M1 修复复核后推进，并在该 PR 内累计提交，不另建阶段 PR。

## 问题

正式路线图 [Windows 插件功能对齐 macOS](../../../../docs/development/windows-plugin-parity-plan.md) 的 M4 要求接入 `build.detect`、`invocationPlan`、`checkToolVersion`、`resolveOptions`、模型/任务/测试/依赖计划与解码、`syncFingerprint`、`languageImport`，以及 `buildSystems:2` 兼容输入与 `executableResolution:1` 的候选解析。当前基线 `1e78b59b`（#1424 合入后）的状态是：

- 宿主 `host_capabilities` 只声明 `languages/languagesServers/serverProcess/settings/ui`（`windows/tauri/src-tauri/src/plugin_host/mod.rs:37`），Core 侧其实早已支持 `buildSystems [1,2]` 与 `executableResolution [1]`（`rust/lithe-core/src/plugins/capabilities.rs:55`），差的只是宿主接线。
- 网页桥 v0 把 `build.instances`、`build.refresh`、`build.runTask`、`build.runTests`、`build.cancel`、`build.dependencies`、`build.setOptions` 一律拒绝为 `plugin.web.unknownMethod`（`windows/tauri/src-tauri/src/plugin_host/web.rs:787`），等待构建能力接入。
- 现有 Maven 是宿主内置特例：`windows/tauri/src-tauri/src/maven.rs` 与 `windows/tauri/src/features/maven/` 按构建系统名字写死了配置、依赖输出与界面，社区插件无法复用；路线图要求它保留为回归基线，不在本轮删除。
- 不处理会造成两个后果：一是 API 3 构建插件在 Windows 不可安装不可运行；二是若原生界面和插件网页各自实现一套构建状态，主窗口与插件 WebView 会对同一工作区得出两份互相矛盾的构建事实（路线图 §2.2 明确禁止）。

## 提案

### 总体形态：Rust 端唯一构建会话登记表

新增 Rust 模块 `windows/tauri/src-tauri/src/plugin_host/build.rs`（首批可拆 `build_registry.rs` 与 `build_resolver.rs` 两个文件），作为唯一构建操作入口。它持有按 `(宿主窗口 label, 工作区 ID, 插件 ID, buildSystemID, 实例根)` 索引的构建会话，每个会话记录：实例列表、模型、选项生效值、同步指纹、忙碌/过期标记，以及每个在途操作的唯一 operation ID、工作区代次快照与取消状态。

前端新增 `windows/tauri/src/features/build-systems/` 统一 TS service，只维护展示状态（树、任务分组、选项输入、忙碌与错误提示），通过 Tauri 命令调用 Rust。命令命名沿用现有 `declarative_plugins_*` 前缀模式（参照 `run_plans.rs:30` 的 `declarative_plugins_run_plan`）：`declarative_plugins_build_instances / build_refresh / build_run_task / build_run_tests / build_cancel / build_dependencies / build_set_options`。注意 `windows/tauri/src/platform/tauri-core.ts:18` 的分发规则：点分共享 Core 操作走 `platform_invoke` 调度器且必须同步注册到 `main.rs`，所以这些命令一律按普通 Tauri 命令注册，不进入点分命名空间。

网页桥不新增第二套语义：`web.rs` 的 8 个 `build.*` 方法只做页面身份校验（复用 `web.rs:40` 的 `PageOwner`、`web.rs:80` 的 `with_page_owner` 代次检查、`web.rs:140` 的 `owned_label`），然后转发到同一个登记表函数。页面拿不到通用 IPC，也不能指定回复目标；结果只回原页面。

选择 Rust 而不是 TS 承担协调，是路线图 §2.2 预留的既定选项：现有接口不足以支持"网页 → 主窗口 TS 模型"的定向请求/回复通道（web 桥没有回复路由），而 Rust 已拥有信任、生命周期与进程能力；TS 若维护第二份构建事实必然漂移。

### Core 命令接线清单（14 条全部可复用，宿主侧全部缺失）

Core 命令注册在 `rust/lithe-core/src/build/commands.rs:91-246`，经 `plugin_host/scan.rs:190` 的 `core_execute` 调用（与现有 launch/run_plans 相同入口）：

| 命令 | Windows 接线 | 缺失接线 |
| --- | --- | --- |
| `build.detect` | bootstrap 扫描后 + 选项/插件变化后重新识别；static 与 hostIntegration 模型随识别返回 | 全部缺失 |
| `build.invocationPlan` | 解析器输入：候选顺序、环境变量白名单、版本探测参数 | 全部缺失 |
| `build.checkToolVersion` | 合并 stdout/stderr 交 Core 校验，复用 `launch.rs:430` 的有界探测执行器 | 全部缺失 |
| `build.resolveOptions` | 选项合并、`dropped` 处理、配置指纹 | 全部缺失 |
| `build.modelPlan` + `build.decodeModel` | static：识别时直读；command：用户点加载时执行模型命令、stdout 交 Core | 全部缺失 |
| `build.taskPlan` / `build.testPlan` | 工具窗口与节点菜单运行 | 全部缺失 |
| `build.dependencyPlan` + `build.decodeDependencies` | 依赖节点首次展开时加载 | 全部缺失 |
| `build.decodeDiagnostics` / `build.decodeTestResults` | 任务/测试输出解码，结果进 Build Output | 全部缺失 |
| `build.syncFingerprint` | 监听文件摘要，判断模型过期 | 全部缺失 |
| `build.languageImport` | Java 会话启动前归一化 Maven/Gradle 输入，转发给 LSP 启动配置 | 全部缺失 |

Core 错误语义保持不动：清单/声明问题返回 `{status:"rejected"}` 稳定错误码，请求本身格式错误才是 `invalid_request`；`plugin.build.invalidOutput/invalidSelection` 等错误码直接透传到界面。

### 三种模型的执行路径

- `static`：识别时 Core 直接读项目文件（如 Cargo.toml），零进程，打开项目即可展示。永远可用，不需要同意流程。
- `command`：模型命令是进程。用户点击"加载模型"或运行任务时，先 `build.invocationPlan` 拿候选，Windows 解析器（新 `build_resolver.rs`，对照 `macos/Sources/Lithe/Platform/MacOS/Build/MacBuildToolResolver.swift`）按候选顺序解析出可执行文件与受限环境，再启动进程：模型/依赖加载是一次性有界收集（stdout 单独捕获交 Core 解码、stderr 进 Build Output、每流上限、取消期限），复用 `launch.rs:430-468` 已验证的 `lithe_git_host::run` 执行器语义（Job Object 进程树、非阻塞管道、有界收集）。项目内 Wrapper（`projectFile` 候选）一律视为执行仓库代码，做版本探测和运行都按同一信任策略，不采信清单自报。
- `hostIntegration`：目前只有官方 Maven。经 Core 的 Maven 集成解析 reactor/依赖树/Surefire 结果，宿主只负责按计划启动 `mvn`。现有 Windows Maven 专用流程（`maven.rs`、`features/maven/`、`main.rs:281-290` 注册的命令）原样保留作回归基线，与声明式路径并存，去重规则与 macOS 相同：声明式插件接管后实例从空状态开始，不沿用专用流程缓存。
- `provider` 来源：M4 不接。`buildProviders` 能力继续关闭（宿主不声明，Core 在 validate 阶段就拒绝声明 Provider 的包），Provider 会话属 M5。`build.detect` 对 Provider 来源只报告不加载的语义由 Core 保证，宿主无须处理。

### executableResolution:1 与 buildSystems:2（冻结范围内，不是未来需求）

- 候选五种来源已在 Core 定型（`rust/lithe-core/src/plugins/executables.rs:82-103`）：`projectFile`（工程内 Wrapper）、`environment`（声明过的环境变量）、`command`（PATH）、`runtime`（java/node/go 等运行时）、`setting`（用户显式选择的全局文件偏好）；`uses_resolution()`（`executables.rs:115`）定义了需要 `executableResolution:1` 能力的声明形态（setting 来源或 priority/insertBefore/insertAfter 排序元数据）。fixture `build-tool-path.plugin.json` 同时要求 `buildSystems:1 + settings:2 + executableResolution:1`，是本项的验收输入。
- 解析语义照抄 macOS 侧 `macos/Sources/LitheCoreContracts/Execution/ExecutableResolution.swift:5-29` 与构建契约 Note 的"统一的候选解析扩展"一节：数组顺序是默认优先级；`setting` 来源为空字符串时跳过该候选、非空但无效时是终止失败（报错并停止本次模型/依赖加载，不得静默回退 PATH 或让 Provider 自行发现）；Runtime 候选把所选目录前置到候选自己的 PATH 再探测与执行，失败候选的 PATH 不传给下一个候选；Provider 的可选 tool 提示复用同一解析结果（M5 前不触发）。
- `buildSystems:2` 的增量是清单里 `invocation.executableSetting` 旧适配器：Core 在 `rust/lithe-core/src/build/manifest.rs:1368-1373` 要求版本 2 且存在 effect 为 reload/nextRun 的可执行全局设置，否则拒绝。Windows 声明 `[1,2]` 即可同时接受两种清单；不要为了让旧包可装而声明成只有 1。
- 用户显式选择的工具路径存进现有声明式设置存储（`windows/tauri/src-tauri/src/plugin_host/settings.rs:15` 的 `app_local_data_dir()/plugin-settings/<pluginID>.json`，项目覆盖在 `settings.rs:26`），不新建第二套工具偏好文件；Core 的 `resolveOptions` 与设置推送使用同一存储。

### tasks / tests / dependencies / languageImport / 运行入口

- 任务与测试：`build.taskPlan`/`testPlan` 生成精确 argv 后，走现有运行管线执行（`windows/tauri/src-tauri/src/run.rs:68` 的 `RunProcessManager`、`:675` 的 `run_resolve_launch`、`:200/265/308` 的按窗口进程清点与停止）。构建任务因此天然获得按窗口停止、进程树清理与关闭兜底，不必另写一套运行器；宿主只登记构建归属（插件、buildSystemID、实例根、operation ID），不把页面提交的 argv 交给通用 `run_start_process`。
- 依赖：`build.dependencyPlan`/`decodeDependencies` 在依赖节点首次展开时加载；Maven 依赖树输出的临时文件语义对照 macOS（宿主在插件状态目录分配输出文件，读完即删），不写安装目录。
- `languageImport`：`build.languageImport` 按返回的 `kind` 归一化为 `mavenContext`/`javaGradle`，在 Java 会话启动前转发给 LSP 启动配置（Windows 侧接线点在 Java 启动就绪链路，`windows/tauri/src/platform/java-launch-readiness.ts` 一线）。被动发现不执行 Wrapper、不做版本探测；找不到工具沿用 JDT 默认设置，不阻塞启动。
- 运行入口：构建模型 `run` 声明与旧 detector、Worker 动作、`executionProviders` 的去重优先规则在 M4 只登记归属（声明式构建来源的入口标注插件与实例），完整运行配置对接按路线图单独排期；macOS 同一路径也缺，列为共享缺口，不另造契约未定义的行为。

### 多构建系统项目的选择

一个工作区同时识别出多个实例（不同构建系统或同系统多实例根）时：每个已启用插件的每个 `buildSystemID` 固定一个工具窗口（登记进现有工具窗口贡献注册表，ID 模式 `<pluginID>.build-systems:<buildSystemID>`，对照 macOS `BuildSystemToolWindowRegistration.swift`）；窗口内用实例根选择器切换，候选与生效值必须来自所选实例，不允许取首实例代表全部。插件已启用但未检测到工程时窗口显示空状态，入口不消失；停用/卸载插件后窗口与命令同步撤销（复用 `declarative-plugin-ui.ts` 的撤销模式）。

### 安全调度：每个操作的授权链

所有构建执行（原生与网页、加载与运行）在启动前依次通过：

1. **M1 信任闸门**：包当前处于已安装、已接受、已启用状态，版本字节与安装记录一致。M4 只定义调用点与失败码，闸门实现与持久化 schema 属 M1（见下节接口清单），M4 不并行定义第二套安装记录。
2. **生命周期隔离**：进程存续期间持有 `lifecycle.rs:37` 的 `NativeLease`（`acquire(plugin_id)`），停用/替换/卸载时 `lifecycle.rs:27` 的 `blocked` 立即拒绝新操作，等待既有使用者退出后再动包。
3. **调用者身份**：原生调用校验 `(宿主窗口 label, 工作区 ID)` 及当前工作区代次；网页调用经 `with_page_owner` 校验页面归属、页面代次与工作区代次（`web.rs:80-98`），页面必须属于同一插件。
4. **操作登记**：唯一 operation ID；同槽并发是忙碌冲突（返回可诊断错误，不排队覆盖）；跨窗口互不可见、互不可取消。
5. **参数与 cwd 校验**：cwd 是工作区内解析后的实例根（拒绝 junction/reparse point 逃逸，沿用 `launch.rs` 包路径闸门语义）；只执行 Core 计划产出的可执行文件与 argv；环境变量只放行声明过的 `environmentInputs`、运行时管理的 PATH 前置与既有 `LITHE_<TOOL>_PATH` 约定，不做任意透传。
6. **最终启动复检**：启动前再查一次槽位仍有效、代次未变、插件未被 `blocked`、扫描缓存中包版本未变。任一失败按过期处理，不启动。

取消与迟到结果的语义照抄 macOS 已验证的规则（构建契约 Note §10"取消后谁能写回"）：完成回调同时校验工作区代次、槽位 operation ID 与取消状态，只有仍持有槽的任务能写回模型/依赖/诊断；取消后仍在排空的输出在追加前检查归属；每个旧任务负责清理自己的临时输出文件。停止（用户点停止、窗口关闭、工作区切换、插件停用）必须等待子进程树（Job Object 兜底）与运行管线登记项全部结束，只从列表移除不算完成。`processJobTree` 与共享 Core 生命周期全部保留，不新增绕过 Job Object 的执行路径。

### 网页桥 build.* 语义

`web.rs` 现有拒绝列表（`:787`）替换为转发实现：`build.instances/setOptions/dependencies` 是读与选项写，走登记表；`build.refresh/runTask/runTests` 是执行，与原生同一条授权链，网页不获得任何额外信任；`build.cancel` 只能取消本页面发起（或本页面归属窗口发起）的操作。等待同意也占用并发名额，取消先于许可到达时操作不得再启动。页面关闭、同包导航、工作区切换、插件停用时，该页面的在途构建操作全部取消并丢弃迟到回复（复用现有页面撤销机制）。

### 正确做法

- 插件网页选择自己已加载模型中的任务 → 桥校验页面归属 → 登记表校验代次与同意 → `build.taskPlan` 生成 argv → 运行管线启动 → 输出回该页面与 Build Output。
- 用户把 Maven settings 路径选到不存在文件 → `executableResolution` 的 setting 来源报终止失败，模型/依赖加载停止并给出可诊断错误，不回退 PATH。
- 停用插件 → `blocked` 拒绝新操作 → 已注册 `NativeLease` 的构建进程等待退出 → 重新扫描 → 工具窗口撤销。

### 不要这样做

- 在 `build.rs`、resolver 或 TS service 里写 `if buildSystemID == "maven"`、`== "gradle"`；生态知识只在 Core。
- 让网页把 `executable`、任意工作区路径或 argv 交给通用进程启动命令，即使页面已通过 CSP 与来源检查。
- 在能力未完整验收前把 `buildSystems` 加进 `host_capabilities`，或把 `build-system-plugins` 矩阵改成 implemented；partial 与 pending 如实记录。
- 为构建另写一套安装记录、信任状态或 `host_capabilities` 数据源。

## M1 提供的输入接口（M4 只消费，不定义）

M1（PR #1476，head `3408f781`，主审中）独占签名、安装记录 schema、`plugin_host` 的 store/scan/install/launch 生产路径、Cargo 依赖、`declarative-plugin-contract` 矩阵与 Windows 宿主 owning Note。M4 依赖以下接口，实现 PR 必须等 M1 合入后基于最终形态接线：

| M1 接口 | M4 用途 | 消费方式 |
| --- | --- | --- |
| 扫描缓存中的包状态（现有 `CatalogEntry.status/enabled`，M1 扩展验证记录） | 执行前信任闸门：已安装、已接受、已启用、当前版本字节一致 | 只读查询，不缓存跨操作副本 |
| 发布者验签与全包摘要结果（M1 安装事务产物） | 闸门判断"通过 M1 验证"；web 桥与原生同源 | 只读 |
| 安装审查的已批准程序/权限记录（含 command 模型命令、任务/测试命令、打包运行时） | `projectFile`/`command` 执行的同意来源 | 只读；不通过审查的程序不执行 |
| `lifecycle.rs` 隔离 API（`blocked/acquire/NativeLease`） | 构建进程注册为原生使用者 | 直接调用，等待语义以 M1 最终版为准 |
| `host_capabilities`（`mod.rs:37`）与 `declarative-plugin-contract` 矩阵 | M4 最后一 PR 声明 `buildSystems:[1,2]`、`executableResolution:[1]` | 同一时间只允许一个 PR 修改；在 M1 矩阵 PR 之后串行 |

签名与安装事务的任何并行变更都在 M1 的 PR 里进行；M4 出现"需要 M1 新增接口"的情况时，先在本 Note 的验收标准里补依赖记录，再由 M1 落地，不在 M4 PR 里改 store/install。

## 分批 PR 范围与验收

按路线图"模型/解析；任务测试/统一桥"切三批，每批一个聚焦 PR，都默认 Draft：

**PR-A 只读检测与展示（static 线）**
- 新增 `plugin_host/build.rs`（登记表 + detect + static 模型 + `resolveOptions` + `syncFingerprint` 监听 + 选项持久化）与 `features/build-systems/` TS service、工具窗口注册、空状态。
- 验收：build-static-file fixture 经真实 Core 识别并展示；选项修改经 Core 校验后持久化且 `dropped` 改存生效值；指纹变化后窗口显示"需要重新加载"；重新打开工作区选项保留。能力保持关闭，用宿主测试直接带 `hostCapabilities` payload 调 Core 验证。
- 有界测试：登记表并发用受控假执行器（无真实 sleep）；resolver 暂不涉及。

**PR-B 进程执行与 Maven 对照**
- 新增 `build_resolver.rs`（五种候选来源解析、`checkToolVersion`、终止失败语义）；command/hostIntegration 模型加载；task/test 经运行管线执行；依赖加载；`decodeDiagnostics/decodeTestResults` 进 Build Output；取消/期限/输出上限/进程树等待；`languageImport` 接 Java 启动链。
- 验收：build-command-stdout、build-command-output-file、build-host-integration fixture 的宿主行为覆盖；Maven 专用流程回归不退化；取消加载与等待同意时切项目的场景通过；配置路径带空格、失效 setting 值为终止失败。
- 有界测试：进程用固定夹具可执行文件与可控完成顺序；迟到输出与旧代次写回拒绝；Job Object 树结束断言进程不存在而非仅列表移除。

**PR-C executableResolution、统一桥与能力开放**
- `executableResolution:1` 完整语义 + `buildSystems:2` 的 `executableSetting` 接受；`web.rs` 8 个 `build.*` 方法经登记表实现；跨窗口、页面关闭、过期代次、权限变化（停用/更新/回滚/卸载期间）场景收口；`host_capabilities` 增加 `buildSystems:[1,2]`、`executableResolution:[1]`；矩阵与契约文档同 PR 更新（`declarative-plugin-contract` 归 M1，先协调再动）。
- 验收：build-tool-path fixture 端到端（含 setting 显式无效终止失败）；至少一个真实声明式构建插件完成保存、同步、模型、运行/测试、停止、重新打开；网页与原生走同一生产链（同一实例状态、同一忙碌冲突、同一取消）；矩阵更新后 `verify-platform-feature-matrix-change` 通过。
- 有界测试：桥的跨 owner/过期代次/取消竞态；能力门控测试随声明更新（参照 settings-v2 fixture 被接受的现有模式）。

## 场景覆盖要求（不允许只写 happy path）

每个实现 PR 的测试与验收必须包含：执行失败（可执行文件缺失、非零退出、输出超限、解码失败）；取消（用户取消、窗口关闭、工作区切换、插件停用）及取消后迟到输出不写入新状态；跨窗口互不干扰与各自的忙碌冲突；过期结果（代次变化后的迟到完成只标过期）；权限变化（M1 停用/更新/回滚/卸载期间 `blocked`、包字节替换后旧操作不得重启）；升级/卸载后工具窗口撤销、登记表清理、进程树确认结束。

## 考虑过的备选方案

### 构建协调放在主窗口 TS service，网页走定向请求/回复通道

最有吸引力的地方：与现有 React 功能模型分层一致，调试直观。不采用：web 桥当前没有可信任的定向回复路由（页面不能选择回复目标），需要新发明一套窗口间协议；而 Rust 已有信任、生命周期与进程能力，路线图 §2.2 明确允许这种情况下把协调器放 Rust。

### 每个 `build.*` 桥方法在 web.rs 独立实现授权与取消

最有吸引力的地方：改动局部、互不影响。不采用：会出现两套授权链和取消语义，最终启动复检很容易漏掉其中一套，这正是 M4 要消灭的分裂。

### 提前声明 buildSystems 能力，用真实包做端到端验证

最有吸引力的地方：真实包驱动开发，验收早。不采用：违反路线图"完整实现后声明相应版本"；capability 一旦声明，市场就会列出仅部分可用的插件。分批期间用 fixture 驱动的宿主测试（带显式 `hostCapabilities` payload 调 Core），能力开放集中在 PR-C。

### 构建任务绕过运行管线，在 build.rs 自建执行器

最有吸引力的地方：参数可控，少一层归属映射。不采用：重复实现停止、进程树清理、按窗口清点与关闭兜底；运行管线已有 `WindowRunProcess` 与 Job Object 语义，构建任务复用它只登记归属即可。

### 保留现有 Maven 专用流程作为构建系统的展示前端

最有吸引力的地方：Maven 界面已存在，直接把声明式数据喂进去最快。不采用：`features/maven/` 的类型与界面按 Maven 语义写死，通用模型（多实例、通用选项、任意任务分组）塞不进去；它保留为独立回归基线，声明式界面按通用模型新建。

## 验收标准

- 14 个 `build.*` 命令在 Windows 宿主全部有真实接线，Core 语义零复制（评审对照 `commands.rs` 与 `build.rs` 调用点）。
- 三种非 Provider 模型（static/command/hostIntegration）各有 fixture 级宿主行为验收；`build-tool-path` 覆盖 `executableResolution:1`，`executableSetting` 覆盖 `buildSystems:2`。
- 原生与网页两通道经同一登记表，授权链六步齐全；本 Note 场景清单全部有测试或验收证据。
- `build-system-plugins` 矩阵 Windows 侧在 PR-C 后如实更新（implemented + pending，验证完成前不得记 verified）；`plugin-web-tool-windows` 的 build 方法部分同步；`declarative-plugin-contract` 由 M1 归属协调。
- 本 Note 状态在 M4 三批 PR 全部合入并验收后，按 agent-notes 规范迁移为 implemented，并把"构建协调在 Rust"的决策并入 Windows 宿主 owning Note 或在其 owning Note 增补链接。

## 风险

- M1 主审中且有信任链/事务问题待修复：M4 的 PR-A/B 可以在独立分支准备代码与测试（不依赖新接口的部分），但接线 PR 与能力开放必须等 M1 合入后的最终形态，避免基于未合入实现假设。
- 运行管线复用需要把构建归属映射进 `RunProcessManager` 的现有所有权模型（按窗口 + 源），若其停止语义与构建槽位冲突，需要在 PR-B 内聚焦调整，不外溢到无关运行功能。
- WebView2 网页通道的取消时机依赖页面生命周期回调，跨窗口场景需要真实双窗口验收；单测只能覆盖状态机。
- Maven 双路径并存期间，用户可见两个 Maven 入口（专用流程与声明式窗口），需在 PR-B 的界面文案与管理页分组中明确区分，遵循现有双模型分组模式。

## 验证

本轮是设计文档，仅运行：

```bash
node scripts/verify-agent-notes.mjs
```

实现 PR 各自的验证范围（本 Note 只规定，不代跑）：

```powershell
cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml plugin_host
# 工作目录 windows/tauri
bun run test -- features/build-systems
./scripts/verify-windows-boundaries.ps1
node scripts/generate-platform-feature-matrix.mjs --check
node scripts/verify-platform-feature-matrix-change.mjs <base-sha> <head-sha>
```

本轮未运行 Windows 构建或应用实例（与 M1 任务避免资源争抢），未修改任何产品代码、共享契约、矩阵或宿主模块；上述结论的源码定位均在基线 `1e78b59b` 核对。

## 适用范围

本 Note 为 M4 设计真源；下列文件为设计指向的落点（本轮全部未修改）：

- 拟新增：`windows/tauri/src-tauri/src/plugin_host/build.rs`、`build_registry.rs`、`build_resolver.rs`；`windows/tauri/src/features/build-systems/`
- 拟修改（M4 PR 内）：`windows/tauri/src-tauri/src/plugin_host/mod.rs`（`host_capabilities`）、`web.rs`（build.* 转发）、`main.rs`（命令注册）、`plugin_host/settings.rs`（只读复用）、`run.rs`（归属登记）
- 参考实现：`macos/Sources/Lithe/Core/Rust/RustBuildSystemOperations.swift`、`macos/Sources/Lithe/Platform/MacOS/Build/`、`macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift`、`macos/Sources/Lithe/Views/Workbench/BuildSystemToolWindowRegistration.swift`
- 契约与依赖：`rust/lithe-core/src/build/commands.rs`、`rust/lithe-core/src/plugins/{capabilities,executables}.rs`、`rust/lithe-core/src/build/manifest.rs`、`shared/contracts/plugins/v1/`（fixtures `build-static-file`、`build-command-stdout`、`build-command-output-file`、`build-host-integration`、`build-tool-path`、`build-plans.json`）、[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)、[Windows 声明式插件宿主](../../implemented/architecture/2026-10-22-windows-declarative-plugin-host.md)、[Windows 插件路线图](../../../../docs/development/windows-plugin-parity-plan.md)
