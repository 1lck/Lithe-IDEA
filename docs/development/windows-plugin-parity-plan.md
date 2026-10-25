# Windows 插件功能对齐 macOS：详细实施计划

状态：待实施。本文只规划后续工作，不表示能力已交付。

编写日期：2026-10-24。

## 目标与完成边界

沿用共享 Rust Core 的插件契约和现有 Windows 声明式宿主，逐项补齐 macOS 已提供的插件安装、市场、构建、设置、网页桥、原生界面和项目生成能力。Windows 使用自己的 React/Tauri 界面与平台适配器，插件声明的含义、权限、结果和生命周期保持一致。

分两阶段交付：第一阶段完成 M1–M6 的插件基础工作流；第二阶段完成 M7–M9 的原生界面、项目生成器和已有 VCS Provider 工作流。M10 是贯穿实施、在两阶段末分别执行的真实包验收，不是最后才开始的测试阶段。M0 先解决基线和验收材料问题。

“对齐”以本计划冻结的 macOS 已有行为为目标。macOS 自己仍未完成的构建 Provider 执行协议、VCS gutter/Annotate 等不自动变成 Windows 本轮需求。实现程度和运行验证分别记录；不能为了收尾，把所有矩阵条目都改成 `implemented` 或 `verified`。

本文是执行计划。长期架构决策仍以对应 Agent Note 为准，字段和错误码仍以共享契约为准，功能当前状态仍以功能矩阵为准。旧 ZCode 六阶段草案保留作历史参考，后续执行使用本文的阶段编号与退出条件。

## 1. 基线、事实与前置条件

### 1.1 已核对的版本

| 对象 | 2026-10-24 核对结果 | 对实施的影响 |
| --- | --- | --- |
| `origin/preview` | `53f7052a463eaf1a4c548663aca4afd1e381224a` | 本计划文档的起始版本；实施时重新 fetch 并记录实际 SHA |
| Windows 声明式宿主 [PR #1424](https://github.com/1lck/Lithe-IDEA/pull/1424) | OPEN，head 为 `ce0ef4dfa24002c29ced37ec5f6b345d83cffd2e`，目标 preview | 尚不能把在审宿主当作 preview 已有能力 |
| macOS 能力表 | `macos/Sources/LitheModuleAPI/Plugins/PluginTypes.swift` 的 `PluginManifest.hostCapabilities` | 作为能力盘点入口，还要核对实际产品入口与矩阵限制 |
| Windows 在审能力表 | PR #1424 的 `plugin_host/mod.rs::host_capabilities` | 只说明宿主接受哪些版本，不证明全部语义已验收 |
| 公共 SDK 与开发文档 | 已迁至 [lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs) | 不再使用主仓库旧 `sdk/node`、`sdk/java` 路径；测试固定外部提交与校验身份 |

每个实施 PR 都从当时最新 preview 创建 `codex/` 分支。优先等前置 PR 合入后再开始依赖它的实现；必须提前验证时，可在隔离工作树试验并记录依赖，待前置合入后重新整理为可独立评审的差异。不要把别的工作树未提交文件当作依赖，也不要复制整个 `.artifacts`。

### 1.2 能力覆盖表

下表是冻结版本的规划映射，不替代实时矩阵。Windows 的“已有”均指 #1424 在审实现；M0 要在最终合并版本上重验。

| 能力/工作流 | macOS 参考范围 | Windows 在审基础与缺口 | 交付阶段 |
| --- | --- | --- | --- |
| `languages:1`、`languageServers:1/2`、`serverProcess:1` | 语言注册、启动计划、配置推送 | 已有接线；需验证真实包、停用、替换及 Worker 优先规则 | M0、M10 |
| 签名、全包完整性、安装审批 | 发布者签名、磁盘快照、来源和回滚 | 有磁盘安装骨架，发布者验签和持久完整性不足 | M1 |
| 多源市场 | 默认源、Lithe Store、自定义源、平台筛选、安装与更新 | 共享索引命令可用，声明式市场宿主待接 | M2 |
| 插件五页签详情 | 概览、功能、设置、权限与程序、版本与来源 | 管理页已有，详情和可信来源信息待补 | M3 |
| `buildSystems:1/2`、`executableResolution:1` | 检测、模型、任务、测试、选项、工具路径、导入 | 未声明，Maven 专用流程可作为行为对照 | M4 |
| `buildProviders:1` | 自有进程与共享语言服务器两种来源 | Core 有会话引擎，Windows 宿主管理待补 | M5 |
| `executionProviders:1` | 文件运行、工作区/文件/用例测试 | 有部分旧 API 运行/测试入口，API 3 能力仍未开放 | M5 |
| 插件私有函数 | 本插件 Provider、结果、进度、取消、设置按钮 | 网页桥仍拒绝函数方法 | M6 |
| `settings:1/2` | 分组注册页、作用域、生效方式、`settingActions` | 已声明 1/2，注册页与动作等完整语义尚需补齐 | M0 审计、M4/M6 补齐 |
| `ui:1/2` | 声明式贡献、网页、宿主主题与工作区隔离 | 已有文本/网页基础，构建与函数桥待接，实机验收待补 | M0、M4–M6、M10 |
| `ui:3` | 原生树、列表、表单、动作与状态恢复 | 未声明，不能用 Web 页面替代这项能力 | M7 |
| `projectGenerators:1` | 新建项目表单、模板/命令/归档步骤、失败清理 | 未声明 | M8 |
| `vcsProviders:1` | macOS 已有的根、状态、提交、更新、回滚等宿主入口 | 未声明；macOS 整体也仍为 partial | M9，按已有子能力对齐 |
| Worker 主题、AI provider 等 | 不属于声明式插件的当前共同能力 | 保持 Windows 现有分工 | 全程回归，不迁移 |

**兼容性注意：** `hostCapabilities` 对 API 1/2 清单不起门控作用，不能仅靠“没有声明 executionProviders”判断旧包不会运行。API 3 的 `requires` 要完整满足；一个插件新增生成器或原生界面，可能让整个新版本在 Windows 上不可安装。M0 和 M10 必须同时检查宿主版本与实际包版本。

## 2. 架构与执行边界

### 2.1 复用现有能力

| 层 | 继续复用 | 本计划补充 |
| --- | --- | --- |
| 共享 Core | 清单校验、市场校验、`build.*`、`project.*`、`vcs.*`，LSP 基础协议上的 Provider/函数会话 | 只在真实跨平台缺口出现时补确定性语义及双端消费者，不复制已有解释器 |
| Windows Rust 宿主 | `plugin_host`、现有 LSP 接口、`run.rs`、`lithe_git_host::ProcessTree`、平台存储与工具发现 | 签名适配、安装事务、Provider 归属、可信执行入口、工作区与窗口生命周期 |
| Windows 前端 | `@/platform/tauri-core`、`lithe-core-client`、运行会话、布局、Maven 与设置公共控件 | 构建功能模型、管理界面、声明式原生渲染、新建项目和 VCS 展示 |
| 上游与插件 | JDT LS/Buildship、插件提供的构建工具、脚手架和 VCS 客户端 | 使用其正式入口；不在宿主重新实现 Java 工程模型、Gradle 图或 SVN XML 解释器 |

构建功能模型可以在 TypeScript 中协调界面状态与用户动作。文件操作、启动许可、原生进程、可信包校验与最终执行检查留在 Rust。Provider 传输、初始化协商、请求、取消和事件继续使用 Core 会话引擎，不另写 JSON-RPC 客户端。

### 2.2 多窗口与网页桥的接线

M4 开始就建立唯一构建操作入口，供原生按钮和插件网页共同使用：

1. 原生宿主从调用窗口取得项目与工作区身份，不信任页面自报的根目录、插件 ID 或可执行文件。
2. Rust 检查包仍已接受、已启用、版本未变，以及页面来源和构建实例归属。
3. 若需要主窗口的 TS 功能模型，使用按宿主窗口定向的内部请求/回复通道；通道不得向插件页面暴露通用 IPC。请求带唯一操作 ID、工作区代次和截止时间，页面不能选择回复目标。
4. TS 协调选择和展示；最终启动前 Rust 再核对当前归属、许可、代次和运行冲突。通过 Core 生成计划，不能执行页面提交的任意 argv。
5. 结果和事件只回原始调用者。页面关闭、工作区切换或插件变化后，取消在途操作并丢弃迟到回复。

实施时若现有接口不足以可靠支持该通道，就把需要两类调用者共享的操作协调器放在 Rust，TS 只维护展示状态；不要在主窗口和插件 WebView 各维护一套构建事实。此选择在 M4 的 owning Agent Note 中记录。

### 2.3 从第一个可执行入口就落实的规则

- 安装时的程序审批、发布者验签和执行仓库代码的工作区同意分别处理；一种通过不能替代另一种。
- `static` 模型可被动读取；命令模型、Wrapper、构建 Provider 请求只在现有信任策略允许时执行。项目内 Wrapper 一律视为仓库代码，不依赖清单自报的风险标记。
- 明确区分安装来源、用户审批的字节、当前运行包的字节。停用、更新、回滚或卸载先撤销页面与运行许可、停止相关进程，再变更包与记录。
- 操作归属至少包含宿主窗口、工作区及其代次、插件与包版本；构建请求另带构建系统和实例根。不能只用一个全局 `pluginID` 或页面 `call` ID 作为所有权。
- Provider 会话按宿主窗口/工作区、插件、构建系统隔离；实例根随请求传递。共享语言服务器只复用契约允许的同插件会话，不给宿主公共语言服务器冒挂其他插件身份。
- 每种进程都有取消、期限、输出上限、崩溃和关闭清理路径。复用 Windows Job Object 管理进程树；不能仅杀父 PID。

正确示例：插件页面选择自己已有模型中的任务 → 宿主校验归属和同意 → Core 重建计划 → 原生执行器启动 → 输出回该页面和所属 Build Output。

错误示例：页面把 `executable`、任意工作区路径和 argv 交给通用 `run_start_process`。这会绕过声明、归属和审批，即使页面已通过 CSP 检查也不允许。

## 3. 里程碑与 PR 顺序

### M0：冻结实施基线与验收清单

**前置：** 开始任何功能实现之前。**规模：** 小；阻塞项来自依赖 PR 和基线问题。

交付内容：

- 确认 #1424 的最终状态、合并 SHA、工作区干净起点及最新 preview SHA，核对其 review 问题已关闭；未合入时不宣称后续 PR 可以独立落地。
- 重验安装、设置推送、运行/测试菜单、网页 openFile、导航隔离与进程清理的真实接线；“函数已定义”不算产品入口已接入。
- 建立 fixture 覆盖清单：合法清单、非法修改案例、命令计划、构建解码、市场、函数、原生 UI、项目生成、VCS，各自列出 Core 测试与宿主测试入口。
- 修正把“合法样例固定数组”称为“目录自动全量验收”的假设。可以做显式覆盖注册及遗漏检测，也可以按文件类型枚举；未知样例必须报出待分类，不能静默跳过。非法清单案例循环不能代替宿主行为测试。
- 检查已声明 `settings:2`、`ui:2` 的实现缺口和旧门控断言，区分历史债务与本轮回归；不能为了测试通过而关闭原有能力。
- 固定外部 SDK/示例的提交、取得方式与许可证。fixture 使用现有能力名称，如 `build-host-integration`、`build-provider`，不依赖已移走的旧生态命名。

退出条件：基线可构建；每项已有能力至少找到一个真实入口及对应验证；所有后续依赖、现存失败和未验证项已列明。基线问题以聚焦修复 PR 处理，不混入市场或 UI 的大 PR。

### M1：签名、全包完整性与安装记录

**依赖：** M0。**规模：** 中；包含安装、扫描与回滚，不是一个验签函数。

交付内容：

- 在 Windows 平台包适配层实现 Ed25519 发布者验签，复用成熟密码库；公钥/keyID 的来源、更新与双端一致性明确，私钥不进入源码和测试。
- 与 `PluginPackageSignature` 字节兼容：文件路径、插件 ID/版本的 UTF-8 base64url token、排序、换行、完整文件集合和每文件 SHA-256 都按现有规范处理。`contentDigest` 使用 token 后的路径行，不把原始路径拼接当作等价实现。
- 以宿主的官方 ID 信任策略覆盖包自声明；`sameTeamAsHost` 只用于可信安装资源中的 bundled 包，磁盘/市场包不能凭相同目录名获得该身份。签名文件存在时必须验证，不能忽略坏签名。
- 在安装前、staging 发布前、启动扫描和回滚时校验应有的签名或社区内容摘要。拒绝多文件/缺文件、路径逃逸、reparse point、冲突文件名和不安全 ZIP 条目；预算覆盖压缩与解压后的内容。
- 将来源、全包摘要、已批准权限/完整程序声明及当前/上一版本验证记录纳入安装事务。来源字段的实际 schema 以现有 macOS provenance 类型为对照，M1 定好持久化骨架，M2 写入市场来源；不拖到 M3 的展示工作再补。
- 旧安装记录迁移保留用户数据，但不凭旧 `enabled` 或清单摘要补造发布者身份和已批准字节；无法证明信任的包隔离或要求重新审批。
- 失败保持旧 active 版本和旧记录可用；取消、重装、回滚失败都清理本次 staging，不能出现新目录配旧记录或反向情况。

验收：

- 使用同一组公开测试密钥、固定包字节、签名、canonical payload 和摘要，在 Swift/Rust 两端给出相同答案；Rust 自签自验只作为补充。
- 篡改普通文件/脚本、增加或删除文件、损坏签名、未知 keyID、官方 ID 降级均被拒绝；含非 ASCII 文件名的测试覆盖编码与排序边界。
- 旧记录迁移、扫描重启、同版本替换、失败恢复及回滚均经生产安装路径测试。

落点：PR #1424 的 `plugin_host/{store,scan,install,launch}`，新增签名适配模块和共享签名验收数据。只有验证了对应子能力，才关闭 `declarative-plugin-contract` 的该项缺口。

### M2：多仓库市场与下载安装

**依赖：** M1。**规模：** 大；必要时分源管理、下载事务两个 PR。

交付内容：

- 源列表、启用状态和用户移除预置源的记录持久化；默认官方源和 Lithe Store 的重建/删除规则与 macOS 一致。稳定源 ID 用同一规范化 URL 与 FNV 算法，并用共享标准答案校验。
- URL 解析、索引合法性、平台/API/能力可用性和安装程序审查分别调用 Core `resolveSource`、`validateIndex`、`installReview`；刷新、缓存及 UI 不另写索引语义。
- 下载有取消、期限、字节预算和 SHA-256 校验；重定向后的目标继续遵守 Core 给出的来源约束。失败不覆盖最近可用索引或当前插件。
- 安装复用 M1 的私有快照、审批、staging、最终复验与发布事务，保存下载包摘要和市场来源。索引合法不等于 ZIP 内容已验证。
- 区分可安装、已安装、可更新、来自其他源、平台/宿主不支持及索引失败；磁盘安装包不会因市场出现同 ID 条目自动变成市场管理。
- “官方”同时要求默认官方源和有效发布者签名；社区来源不能冒充官方。审批界面显示权限、完整程序、新增授权和真实来源，不用绿勾代替用户判断。
- 语言、主题、无障碍、刷新和失败重试接入已有 Windows 设置与公共控件；保留 Worker 市场的独立边界。

验收：本地受控服务器覆盖刷新、缓存、断流、超限、取消、坏摘要、无 Windows 工件、新增程序审批、跨源同 ID 与磁盘来源。单测不依赖 GitHub 在线可用性，真实源安装放在明确的集成验收中。

落点：`plugin_host` 的市场/下载适配、前端声明式管理页、安装记录与 `plugin-marketplace` 矩阵。

### M3：五页签详情与可解释的状态

**依赖：** M2 的来源与安装数据。**规模：** 中。

交付内容：

- 插件详情提供“概览 / 功能 / 设置 / 权限与程序 / 版本与来源”，常驻名称、信任状态和启停/卸载/回滚操作。
- 功能页按已校验声明展示语言、服务器、运行/测试、构建、UI 等贡献；不把“声明存在”画成“宿主已经可运行”。
- 版本页展示当前/上一版本、磁盘或市场来源、归档与内容摘要、已验证签名状态和隔离原因。签名标记来自验证结果，不能从 `signatureRequirement` 字段推断。
- 设置页复用现有设置控件；M6 再补完整注册页与函数按钮。权限页展示人类可读说明和可展开的完整程序声明。
- 列表筛选覆盖语言服务、构建、更新、社区、停用；Worker 与契约模型的分组和文案明确，搜索不丢失选中项。

验收：bundled、已签名市场包、社区市场包、磁盘包、隔离包、更新和回滚各有真实数据；验证窄窗口、中文/英文、浅深主题、键盘和错误操作反馈。外观遵循 Windows 公共组件，并对齐信息与行为，不复制 SwiftUI 控件。

落点：声明式插件管理/详情前端、公共设置控件及 `plugin-detail-tabs`。M3 不再创建独立来源数据库。

### M4：声明式构建、工具解析与统一执行入口

**依赖：** M0、M1；可与 M2/M3 的展示开发交错，冲突文件须明确归属。**规模：** 大，按模型/解析、任务/测试与网页桥拆成聚焦 PR。

交付内容：

- 接入 `build.detect`、`invocationPlan`、`checkToolVersion`、`resolveOptions`；static、command、hostIntegration 三种模型来源统一进入按插件声明生成的工具窗口。
- 复用现有 Maven 后端与 Core hostIntegration，保留已有功能作为回归基线；树、任务、选项和依赖展示使用通用模型，不在新服务中按 Maven/Gradle/Cargo ID 写分支。
- 完成 `build.modelPlan/decodeModel`、`dependencyPlan/decodeDependencies`、`taskPlan`、`testPlan/decodeTestResults`、`decodeDiagnostics`、`syncFingerprint`，覆盖输出、诊断跳转、测试结果、监听和模型过期提示。
- 工具窗口按已启用插件的声明注册，不能因暂未检测到工程就丢失入口；实例根、项目、目标及完整 tags 参与唯一选择。无匹配工程显示空状态。
- 解析 `buildSystems:2` 兼容输入与 `executableResolution:1` 的候选顺序、setting、runtime 和 environment。显式配置路径无效为终止失败，不能静默回退到 PATH 或 Provider 自行发现；空值与重置的语义分别保留。
- 全部加载、运行与网页 `build.*` 入口从本阶段开始使用第 2 节的归属、同意、取消、busy 冲突和最终启动检查，不能把安全接线留到 M6。
- 选项按工作区/实例根正确持久化，Core 解析后的值与指纹用于模型、argv 和语言导入；切换工作区、选项或包版本后丢弃旧结果。
- `build.languageImport` 的结果在 Java 会话启动前准备；Maven 热更新与 Gradle 下次启动的差异按现有契约执行。被动发现不执行 Wrapper 或版本探测。
- 模型中的运行入口接入现有运行配置流程，定义与旧 detector、Worker 动作及 `executionProviders` 的去重/优先规则。若 macOS 同一路径仍缺失，单列共享缺口，不另造未经契约定义的行为。

验收：`build-static-file`、`build-command-stdout`、`build-command-output-file`、`build-host-integration`、`build-tool-path` 和 `build-plans.json` 都有宿主行为覆盖。至少用一个真实声明式构建插件完成保存、同步、模型、运行/测试、停止和重新打开；Maven 原流程不退化。取消加载、等待同意时切项目、同名不同 tags、配置路径带空格和失效值必须覆盖。

能力开放：完整实现后声明相应版本；纯 Provider 包仍由 `buildProviders` 门控。`build-system-plugins` 可先保持 partial，不能因能检测工程就改为完整实现。

### M5：Provider 会话与完整运行/测试提供方

**依赖：** M4。**规模：** 大。

交付内容：

- 自有 Provider 经现有启动计划和 Core `lsp.startServer` 会话启动，携带正确插件归属；Core 完成 `litheBuild` 协商后再发送 `lsp.buildRequest`，结果交回 `build.decode*`。
- 支持 `build-provider` 与 `build-provider-language-server` 两种清单。共享写法只复用允许的语言会话，不启动第二个服务器；会话未就绪或未协商时返回可诊断失败。
- 会话缓存只合并同一所有者的初始化；取消一个等待者不取消其他等待者。停止初始化中的会话后，迟到 ready 不得重新登记进程或发请求。
- 处理请求取消、超时、阻塞 stdin、崩溃重启、设置变化的下一次请求重启；所有 Core 阻塞调用走已有后台边界，界面线程不等待管道写入。
- 关闭项目/窗口、退出、插件停用/更新/卸载/回滚时回收已运行和初始化中的 Provider、子进程与所有等待者。重启不能使用旧包或旧工作区许可。
- 补齐 `plugins.declarative.discoverTests/testPlan` 的工作区、文件、用例作用域和产品测试入口；保留已有 `runPlan`、保存工作区、输出及进程 owner 链路。
- 明确构建测试与语言测试的展示/去重方式，保留精确 suite/case 选择；不支持的选择应报错，不能扩大成整个工程运行。

验收：自有 Provider 模型/依赖、共享语言会话、未协商、崩溃、初始化中取消/停用、两个项目窗口和插件更新均走真实 Core 会话；测试断言最终进程树结束，而非仅从前端列表移除。真实 Gradle/其他 Provider 包再做原生验收。

能力开放：通过对应测试后增加 `buildProviders:1`、`executionProviders:1`。这只补齐 API 3 能力声明，不追溯声称 API 1/2 旧入口此前不存在。

### M6：插件函数与完整注册设置页

**依赖：** M5；详情设置展示依赖 M3。**规模：** 中到大。

交付内容：

- 网页 `functions.list/invoke/cancel` 经所属构建实例进入同一 Provider 和 Core `lsp.functionRequest`，处理初始化注册、动态撤回、结果、进度、超时、取消及 `pluginErrorCode`。
- 私有函数只能访问本插件自己拥有的 Provider；共享语言服务器不因复用而获得该插件的私有函数身份。保持 `lithe/host/*` 暂不开放的现有边界。
- 页面 `call` ID 在该页面生命周期内不复用，Core 操作 ID 另行生成；等待同意也占用并发名额，取消先于许可到达时不能在之后启动。上限沿用当前契约和宿主参考常量。
- 页面关闭、同包导航导致会话替换、项目关闭与插件变化时取消原调用；旧进度不能污染新页面、新工作区或复用业务 ID 的新调用。
- 按设置的 `page.languageID/buildSystemID` 注册页面，按 `section` 分组；不要把 `page` 误写成 `section.languageID`。没有 page 的选项保留在插件详情。
- `settingActions` 在插件详情和注册页都能调用本插件函数；支持 `confirm`、执行中状态、失败、取消与项目缺失提示。不能只移动页面却漏掉按钮。
- 完整执行 `restart/immediate/reload/nextRun`，全局与项目覆盖、显式清空与重置一致；由 Core 合并取值，不在 React 再实现一份规则。

验收：两个插件交叉调用被拒；真实示例能发现、调用、观察进度、取消和返回插件错误；设置按钮与网页走同一生产链。关闭页面、关闭项目、停用和更新时无残留。确认已声明的 settings 2 所有适用语义都有对应入口。

第一阶段退出：M1–M6 各自退出条件满足，M10 的第一阶段真实包验收完成；`plugin-functions`、`plugin-registered-settings-pages` 和网页桥状态按实际范围更新。

### M7：`ui:3` 声明式原生界面

**依赖：** M6，复用窗口贡献/布局与函数入口。**规模：** 大；树/列表与表单可分 PR，但不能提前开放未完整支持的 ui 3。

交付内容：

- 用 Windows 公共控件渲染 native schema 1 的树、列表、表单、工具栏、右键动作、说明和禁用状态；不在清单中加入 CSS、脚本或任意宿主命令。
- 覆盖 input/search/select/segmented/editor/stepper/checkbox、按钮、列布局与窄面板回退；选择、字段值和展开状态按插件/窗口/工作区隔离恢复。
- 输入编辑与提交分别处理，按契约传递全部当前字段值；异步加载、动作失败、超限结果、重复节点 ID 与非法类型由既有契约验证。
- 动态数据与动作复用 M6 的函数入口；忙碌、取消、隐藏/重开、同槽切换、关闭与替换不能交叉占有会话或覆盖新结果。
- 高频滚动、拖动和布局使用 Windows 既有公共实现，保持虚拟化和更新频率边界；新增持久状态说明生命周期，不写插件包。

验收：`native-panel`、`native-form`、`native-controls` 和固定版本的外部示例覆盖长列表、键盘、中文输入、焦点、浅深主题、窄窗口、恢复、并发动作和停用。复用原生 UI Note 的验收动作，转换成 Windows 的真实操作证据。

能力开放：只有该版本可声明内容的必需行为都完成后增加 `ui:3`；部分 renderer 完成仍保持门控，不能装入后静默不画控件。更新 `declarative-native-plugin-ui`。

### M8：插件注入的新建项目

**依赖：** M2 的缺失插件跳转、M4 的构建识别与公共工具解析；复用设置字段控件，不强依赖 M7 的原生面板 renderer。**规模：** 大。

交付内容：

- 欢迎页/项目菜单进入通用新建项目窗口；宿主管理名称、位置、空项目和 Git 选项，插件提供生成器字段与步骤。
- 复用 Core `project.generatorCatalog`、表单求值、`generationPlan` 和归档解压，不按生成器 ID 拼字段、URL、argv 或包名规则。
- 接入 files、command、archive 三种步骤；在目标旁的本次临时目录执行，全部成功后移动到最终位置，目标已存在或被并发创建时拒绝覆盖。
- 下载、命令、解压、取消与失败均有预算和清理；文件模板、路径、所选运行时、条件、派生默认值和版本约束遵循共享标准答案。
- 生成器所属插件停用时显示禁用及启用入口；requirements 缺失显示市场/启用提示，但按现有契约不把 requirements 自动变成创建硬阻塞。
- 完成 Git 初始化、所选 JDK 设置和 `openFiles` 恢复，随后进入现有工程打开、语言导入与构建识别流程。

验收：`project-generator`、`project-plans.json` 与固定版本的真实生成器包，覆盖纯模板、命令、归档、无运行时、已存在目录、服务器失败、取消及工作区切换。完成“生成 → 打开 → 语言服务 → 构建/运行”，确认失败无半成品、成功不写安装目录。

能力开放：实际创建链完成后增加 `projectGenerators:1`，更新 `plugin-project-generators`。Java Support 的 Windows 分发必须同时满足其整份 `requires`，不能因模板 JSON 跨平台就直接复用 macOS ZIP。

### M9：对齐 macOS 已有的 VCS Provider 子能力

**依赖：** M0、M1 及 Core 会话生命周期；可复用 M5 形成的进程适配经验。**规模：** 大，作为独立领域工作，不混入函数桥 PR。

交付内容：

- 按 [VCS Provider 契约](../../shared/contracts/vcs-provider-v1.md) 使用 `vcs.detectRoots/ownerOf`、`lsp.vcsRequest`、`vcs.decodeReply`，共用 Core 会话和现有进程树管理，不复制 SVN 命令与输出解析。
- 对齐冻结版本 macOS 已接入的根识别、状态、基线比较、选中提交、更新、回滚、解决/清理、历史及文件操作跟踪；入口按 Provider 协商能力显示，不按 svn ID 分支。
- 保留 Git 专属提交、分支、Log、Worktree 等流程；嵌套根按最深归属处理，跨根移动不得误交给单个 Provider。
- 识别工作副本可先进行无进程检测；识别后读取状态的启动时机遵循 VCS 契约和安装授权，不能套用“所有 Provider 只能点击后启动”的构建规则。
- 监听每个根的元数据目录，包含工作区位于工作副本内部的情况；找不到客户端、凭据/网络失败和冲突按稳定码展示。
- 从独立插件仓库固定一版真实 VCS Provider 作为验收输入；不把其生态解析实现搬回主仓库。

验收：受控本地 SVN 仓库、纯 Git、Git 与 SVN 共存、嵌套根、文件移动、关闭项目和缺少客户端；验证提交/回滚目标准确且有既有确认流程。macOS 未完成的 gutter/Annotate 等明确留在原功能矩阵的共享后续范围，不假称本轮已覆盖。

能力开放：必需协商和当前参考入口完成后增加 `vcsProviders:1`。整体矩阵可仍为 partial；在 notes 中列清已对齐子能力和双方共同缺口。

### M10：真实 Windows 包、打包与分阶段验收

**执行时机：** M1 起准备；M6 和 M7–M9 完成后分别验收。**规模：** 持续工作，包迁移必要时独立 PR。

- 为语言、构建、Provider/函数、原生 UI、生成器、VCS 分别选定真实包，记录插件提交/版本、宿主 SHA、SDK SHA、架构、下载摘要、运行时和许可证。
- 平台资源逐项核对：`.exe/.cmd`、Wrapper、路径/参数、打包 JDK/Node、文件名和架构。共享声明语义不表示 macOS 归档可在 Windows 运行。
- 官方包继续固定上游版本与摘要、在构建阶段组装校验后签名；社区包和系统命令插件遵守各自来源与许可证，不把受限服务器重新分发。签名及正式发布另按相应插件仓库流程执行。
- Java/JDT LS、Go、PHP 和首批构建插件分别走实际产品入口，确认 Worker 与声明式宿主的拥有者优先规则。PHP 的动态 Composer 动作没有等价能力前保留 Worker，不能以包迁移丢失既有功能。
- 至少一个可运行包完成“市场安装 → 审查 → 启用 → 打开项目 → 模型/语言服务 → 运行/测试 → 取消 → 更新 → 回滚 → 停用 → 卸载”。其他样例按适用子流程验收。
- `windows-x64` 和 `windows-arm64` 分别记录结果。缺少某架构实机或可验证执行环境时，保留该项 pending；不能用编译成功或 x64 仿真替代 arm64 原生运行证据。
- 每次验收比较安装资源、只读插件包的文件清单和哈希；结束后关闭本次启动的 Lithe、Provider、构建子进程与辅助服务器，并核对无本次实例残留。

## 4. 依赖、切分与完成状态

建议顺序：M0 → M1；随后推进市场线 M2 → M3，以及构建线 M4 → M5；两线汇合后完成 M6 与第一阶段 M10。第二阶段推进 M7、M8、M9，再执行相应 M10。M8 不必等待 M7，M9 不必等待生成器；实际 PR 仍遵守前置合入和最新 preview 分支规则。

| 阶段 | 建议 PR 边界 | 可见交付与退出证据 |
| --- | --- | --- |
| M0 | 基线修复/覆盖清单，按问题拆分 | #1424 最终基线、真实接线与未验证项 |
| M1 | 签名与摘要；安装事务/迁移可另一个 | 可信安装、扫描、重启和回滚，不依赖 UI 补数据 |
| M2 | 源管理；下载/安装工作流 | 至少一个真实 Windows 市场包安装成功 |
| M3 | 五页签与筛选 | 各类来源和状态可解释，窄窗口/键盘证据 |
| M4 | 模型/解析；任务测试/统一桥 | 三种非 Provider 模型、精确 argv、信任与取消 |
| M5 | 会话/共享来源；运行测试接入 | 真实 Core Provider 与进程树清理 |
| M6 | 函数；注册设置页/动作 | 网页与设置动作共享生产入口 |
| M7 | 树列表；表单与完整版本开放 | ui 3 的原生控件及生命周期证据 |
| M8 | 生成协调器；向导与创建后集成 | 失败无残留，成功能打开并构建 |
| M9 | VCS 会话/根；现有子能力入口 | Git 不回归，本地 VCS 插件完整适用流程 |
| M10 | 包迁移、打包修复按资源归属拆分 | 每个架构、包版本与宿主版本的验收记录 |

同一时间只让一个 PR 负责 `host_capabilities`、安装记录 schema 或同一功能矩阵条目的最终修改。两条开发线可以交错推进，但不能把“可并行”理解为互不依赖或同时重写 `mod.rs/store.rs/web.rs`。

规模是相对复杂度，不是日期承诺。先完成 M0、M1 并取得首个真实包结果，再据实际改动量和验证耗时排日期；原草案“每阶段几百行”和“M1 只是单模块”的估计不作为预算。

## 5. 验证、资源与提交要求

### 5.1 每个功能 PR 的共同验收

1. 记录基线、受影响入口、最终触发组件/菜单、输入输出和未完成范围。错误码、取消、超时及迟到结果检查覆盖生产路径。
2. 新增/修改测试先遵循 `write-stable-tests`：可控制时序、局部期限、失败清理；网络用受控服务，进程用固定夹具。不要靠真实 sleep、反复重跑或关闭断言解决失败。
3. 本地先跑最小相关范围，再执行受影响的正式检查。跨平台改动分别保留目标平台证据；Windows 通过不能代替 macOS 回归。
4. 同 PR 更新对应矩阵 JSON 的真实实现、验证状态、证据与具体操作；生成阅读视图但不提交 `.artifacts`。代码存在可记 implemented/pending，未跑目标平台不能记 verified。
5. 决策、所有权或兼容面变化时更新 owning Agent Note，执行 `verify-agent-notes`；不把本文整段复制成另一份长期规则。
6. 默认 Draft PR；本地验证完整且可评审后 ready。ready 后积累必要改动再 push，避免反复占用完整平台 CI。每个 PR 的描述列出所有用户可观察改动。

### 5.2 按变更选择的命令

Windows 可执行入口（从仓库根运行，typecheck 在前端目录运行）：

```powershell
node scripts/verify-agent-notes.mjs
node scripts/generate-platform-feature-matrix.mjs --check
node scripts/verify-platform-feature-matrix-change.mjs <base-sha> <head-sha>
./scripts/verify-windows-boundaries.ps1
./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope WindowsRust
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope SharedRust
./scripts/build-windows.ps1 -Configuration Release
cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
```

```powershell
# 工作目录：windows/tauri
bun run typecheck
```

这些命令是按受影响范围选择的检查集合，不要求每个纯文档 PR 重建所有平台。矩阵 change gate 使用真实 PR base/head SHA；实现期间仍要在提交前按 Skill 检查实际改动范围。Rust 改动另执行相应 manifest 的 `cargo fmt --check`，涉及 Core 时先执行 Core 注释门禁。

macOS/具备 zsh 的正式验证环境按相应 Skill 执行 `scripts/verify-shared-contracts.sh`、`scripts/verify-rust-core.sh`、`scripts/verify-runtime-bundle-immutability.sh` 和相关 Swift 测试/计时 harness。`verify-agent-notes.sh` 只包装 Node 校验，可在 Windows 原样运行其 Node 入口；共享契约脚本包含多项语义检查，不能以“所有 JSON 能解析”冒充全脚本通过。安装资源的静态不可变检查也不能代替真实工作流前后的文件哈希比较。

### 5.3 资源生命周期

| 资源 | 所有者与可写位置 | 清理与复用 |
| --- | --- | --- |
| 已安装主程序与 bundled 资源 | 构建/安装阶段拥有，运行时只读 | 不写缓存、下载、日志和索引；保持发行签名基线及 macOS Sparkle 增量更新所需字节 |
| 用户安装的插件版本包 | 插件安装事务拥有，发布完成后只读 | 更新/回滚前停止读用它的会话；卸载按安装记录清理，不跨工作树复用 |
| 源列表、索引缓存与安装记录 | Windows 平台存储 adapter 解析的用户数据/缓存目录 | 源移除与缓存失效按功能规则处理；内容摘要不意味着可复用构建缓存 |
| 下载、快照、staging | 本次安装操作私有的临时/用户数据目录 | 成功、失败、取消均释放；不共享用户审批或市场来源 |
| Provider/LSP/UI 状态 | 插件、工作区及窗口语义拥有的平台可写目录 | 关闭会话释放进程/锁；持久数据按所属功能保留/卸载清理，包内不写 |
| 新建项目 staging | 目标项目旁的本次私有目录 | 成功移动到最终位置，失败/取消删除，绝不覆盖已存在目录 |

新增或调整下载、解压、生成、缓存路径时，同 PR 检查并更新 `scripts/worktree-resources.json`、`reuse-worktree-resources.mjs` 校验路由、对应测试和 `docs/ci-builds.md`。没有可靠身份 stamp 的资源不得注册为可复用；运行时状态不跨工作树共享。不要把临时方案写进发行目录，随后依赖“启动前清理”。

### 5.4 验收证据格式

每个里程碑的交付记录至少包含：宿主/插件/SDK 的精确版本、平台与架构、入口及复现步骤、预期与实际结果、测试命令和单测试计时报告、安装资源前后清单/哈希、进程清理结果、已知范围与待验证项。日志和截图先脱敏；截图可以证明界面，不能独自证明签名、权限或进程清理。

## 6. 持续同步与范围变更

每次 macOS 增加能力或宿主行为，先检查 Core/契约/fixture、macOS 入口、Windows 入口、发布工件和矩阵五部分。共享 Core 只自动共享同一版本的确定性算法，不自动实现另一平台的 UI、存储、生命周期、审批或可执行工件。

差距的持久记录放在对应功能矩阵的 notes 和 owning Note，至少说明：能力与版本、Windows 现状、产品入口、下一阶段、依赖、验证动作及实际关闭证据。本文的表只作冻结路线图，不再维护第二份实时状态。

新能力进入本轮前，明确它是冻结范围内的遗漏、当前阶段回归，还是冻结后的新增需求。前两者纳入原阶段；新增需求单列后续阶段并说明依赖，不不断扩张正在评审的 PR。现有契约 README、Note 和能力表有冲突时，先查代码和验收证据修正记载，不以旧文档覆盖现状。

## 7. 不纳入本轮及风险处理

- 不把 Worker RPC 改名成插件函数，不迁移主题、AI provider 等没有共同契约的能力；已有用户流程保持可用。
- 不为 Windows 另造插件清单、构建输出解析、语言语义或 Provider 协议，不引入操作系统沙盒或新的插件任意宿主命令协议。
- `lithe/build/execute`、动态项目生成器后端、macOS 尚未完成的 VCS 入口保持原提案范围；需要时另开阶段，不借“全量”一次引入。
- 构建模型的旧 detector、Maven 专用路径与 Worker 可能重复：先规定拥有者和去重，再逐项迁移；无等价行为时保留原入口并记录缺口。
- 多窗口与同版本替换最容易产生旧许可和旧结果：M1、M4、M5、M6 均把它们作为阶段退出条件，不能只在最后做一次 happy path。
- 包的整个 `requires` 可能超过第一阶段宿主：市场必须显示不支持，不能删字段、放宽校验或修改已发布归档绕过。需要兼容包时通过插件新版本/正确平台工件解决。
- 正式工件、外部 SDK 或某架构验收暂不可用时，保留清晰的 pending 和依赖，不把模拟测试当作实机交付。单阶段通过后仍按其范围完成，后续阶段不凭文档自动关闭。

## 8. 开始实施前的阅读入口

- [跨平台功能同步规则](platform-parity.md)。
- [应用边界](../../shared/contracts/application-boundary.md)与 [Rust Core API](../../shared/contracts/rust-core-api.md)。
- [插件契约与 fixtures](../../shared/contracts/plugins/v1/README.md)。
- [插件市场与来源](../../.agents/notes/implemented/feature/2026-10-12-plugin-marketplace.md)。
- [构建系统契约](../../.agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md)。
- [插件设置注册面](../../.agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md)。
- [插件原生界面](../../.agents/notes/implemented/feature/2026-10-21-declarative-native-plugin-ui.md)。
- [项目生成器](../../.agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md)。
- [VCS 分阶段提案](../../.agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md)。
- [LSP 插件资源分发](../../.agents/notes/implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md)。
- [高频 UI 性能边界](../../.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md)。
- Windows 声明式宿主 Note 随 #1424 引入，实施时在其最终基线上读取；本计划不复制该 Note 作为 preview 已有文件。
