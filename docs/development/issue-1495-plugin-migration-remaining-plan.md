# #1495 剩余插件迁移：四个大任务

这是执行计划，不代表下面的迁移已经完成。总目标见 [#1495](https://github.com/1lck/Lithe-IDEA/issues/1495)，职责和取舍以 [Build Provider 决策笔记](../../.agents/notes/implemented/architecture/2026-10-26-build-provider-task-execution.md) 为准。每个大任务可以包含多个可验收 PR，不能只增加新接口而一直保留旧业务入口。

## 当前交付边界

- 阶段 A 清单 [PR #1513](https://github.com/1lck/Lithe-IDEA/pull/1513) 与独立分发 [PR #1483](https://github.com/1lck/Lithe-IDEA/pull/1483) 已合并，保持原范围，不重复认领。
- 已合并的宿主/Core 原生构建、测试发现/执行、运行/原生调试准备、保存的运行配置和只读模型共享见 [PR #1517](https://github.com/1lck/Lithe-IDEA/pull/1517)。配套实现为已合并的 [SDK PR #4](https://github.com/Lithe-IDEA/lithe-plugin-docs/pull/4) 和 [Maven Draft PR #7](https://github.com/Lithe-IDEA/lithe-plugin-maven/pull/7)；SDK 源码合并不代表新版已经正式发布。
- Maven 插件已完成本地原生执行切片：生命周期、插件目标、自定义目标和测试由工作区后端执行；模型仍来自现有 Maven 扩展。它尚未替换宿主全部 Maven 消费者。
- 这些是开发源码和本地验证；正式 SDK/插件发行、完整 macOS UI、Java/JDT 和 Windows 实机验收不能据此勾选完成。#1495 保持开放。

## 任务一：完成宿主、契约、SDK 与 Maven 插件的合并发布闭环

**目标：** 用户能从正常插件渠道安装一组明确兼容、校验通过的最新版本，不依赖本地 SDK JAR。

**范围与顺序：**

1. #1517 已于 2026-10-29 核实合入 preview（`659739011`）；以合并提交核对最终契约，阶段 D 增量仍需各自验证。
2. 在 `lithe-plugin-docs` 用合并后的 preview commit 运行 `node scripts/contract.mjs sync --revision <commit>`；不手改镜像或伪造锁定值。
3. 已合并的 Node/Java SDK 实现按最终契约重新验证，在锁定 Core 与当前 preview 上运行真实端到端场景；补齐 Node 20、Java 8 运行证据后，按其发布流程发布实际的新版本。
4. Maven 插件将 `sdk.lock.json` 和构建依赖更新到实际发布的版本、URL、SHA-256；用正式 `package.mjs` 验证，开发构建覆盖不能进入发行流程。
5. 验证最新宿主的安装、更新、能力拒绝提示和插件包只读。只有实际符合来源、签名和市场规则的工件才进入分发。

**退出条件：** 三仓 PR 和依赖顺序可追踪；契约副本逐字节一致；SDK 和 Maven 包都有真实发行地址与校验值；正式打包、最低支持运行时和当前平台流程通过。未实现的 Windows Provider 能力继续明确拒绝。这个任务不负责删除全部旧 Maven/Java 业务。

### 阶段 C 的验收记录与交付门槛

| 验收项 | 当前证据与剩余动作 |
| --- | --- |
| 无页面的工作区 Provider、执行与测试 | Core、生产 macOS 会话表与真实 Maven 后端已经完成多模块读取、模块编译、精确单方法执行和报告解码；集成测试显式选择开发包与工具，关闭后核对包清单不变。 |
| Run、原生 Debug 与适配器贡献 | 原生入口、保存配置、Agent 操作身份和类型化准备已经实现；真实 SDK 进程覆盖准备、失败、取消及另一工作区隔离。真实 LLDB 已通过 Provider 编译→Registry 启动→命中断点→读取栈帧→带参数继续执行→退出及清理，插件包保持只读；完整 UI/发行包流程仍需验收，Java/JDT 领域迁移属于任务三。 |
| 配置快照与跨插件协作 | 协议 6 的只读模型输入公开选定事实，配置/源码/模型/插件/工作区变化撤销旧输入；两个真实 SDK 后端经过 Core 交换公开投影。不能据此声称 Java 已消费 Maven 全部配置。 |
| 最低 SDK 运行时 | 历史[显式宿主 CI](https://github.com/Lithe-IDEA/lithe-plugin-docs/actions/runs/40531099687) 的 Node 20、Java 8 原生端到端作业通过，宿主固定为 `58ca81cf66c5c6e281c7df73ac67adb3526174f3`。该轮契约漂移检查失败；SDK #4 后续已合并且 main CI 通过，镜像仍需在 #1517 合并后按最终宿主提交同步。 |
| Maven 最低运行时 | [固定 SDK 提交的开发验证](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40533306865) 已通过 Java 8 后端及当前/3.6.3 Maven，每组 55 项计时检查（含 3 项打包）；不能代替旧 SDK 锁定下仍失败的正式打包检查。 |
| 正式合并、契约同步与发行 | SDK #4 已合并；宿主 #1517 已于 2026-10-29 核实合并（preview `659739011`），Maven #7 因正式 SDK 锁定依赖继续保持 Draft。最终契约同步与新版发行尚未完成。使用最终 preview commit 同步契约、发布 SDK，再更新 Maven 的真实版本/URL/SHA-256 和完成正式包验收；不能先填预期校验值。 |

阶段 C 不能仅凭接口存在或本地开发包通过就勾选完成。下面的任务二至四不阻塞通用接口继续评审，但不会代替上表中尚未完成的验收与发行条件。

## 任务二：完成 Maven 全部生产入口、配置和用户数据迁移

**依赖：** 任务一可安装的宿主/SDK/插件组合；复用 [#818](https://github.com/1lck/Lithe-IDEA/issues/818)、[#1493](https://github.com/1lck/Lithe-IDEA/issues/1493) 的真实配置来源与存储规则。

**目标：** Maven 工程、依赖、配置与任务只有插件后端这一份领域持有方，UI 和 Agent 消费同一份生效配置。

**范围：**

- 切换原生 Build、Agent Maven 能力、项目加载、项目设置、依赖导航、运行配置生成及 Java 导入配置等全部当前调用链；不能仅迁工具窗口。
- 处理 Profiles、Skip Tests、settings、仓库与工具路径的真实来源、优先级、草稿确认、冲突保护、保存后读回和一次性旧配置迁移。失败保留源数据，不增加影子配置或双写。
- 运行、测试、调试消费当前工程/配置快照；Maven 事实继续来自 Maven 上游，不再由宿主另解析一份 POM、模块图或依赖模型。
- 每条新路径成立后删除对应 `MavenService`、`MavenFeatureModel`、POM 专属加载、旧存储及 fallback。移除共享 Maven 命令前，同时迁移其当前 Windows 消费者；不能为了删除行数破坏另一平台。

**退出条件：** 多模块工程从打开、配置读写、同步、构建，到 UI/Agent 触发相关操作使用一致配置；重开、失败、取消、配置 ABA 与工作区切换可验收；旧 macOS Maven 服务、配置副本和 fallback 已删除。共享命令的现有 Windows 调用也完成切换，迁移证据和删除清单可逐项对照。

### 阶段 D 的实施记录（尚未完成）

- 工作分支 `codex/issue-1495-maven-migration` 从 `upstream/preview@0beb43c936f61e68b983533805d6534a01fdf8b4` 建立，整合 #1517 的 `9f702e15deeeed2e9889d396fab50c706ee48c0a` 作为阶段 C 源码依赖；随后整合已合并 #1517 的最新 preview `f0957b7f0`，保留其后续修正。
- 首个完整流程为 Agent 查询插件 Build 实例/任务 → Provider 执行 → 输出/退出查询 → 按 ID 停止。新入口复用 Build 服务；同步删除旧 Maven 任务执行 API、进程和状态机。macOS 旧配置与项目加载服务随后已删除；剩余启动规划和平台/发行验收仍阻止阶段 D 完成；精确测试已切入同一 Provider，并通过当前本机组合验证。
- SDK #4 已于 2026-10-28 合并；阶段 D 配套增量为 [SDK Draft #5](https://github.com/Lithe-IDEA/lithe-plugin-docs/pull/5) 与叠在 #7 上的 [Maven Draft #8](https://github.com/Lithe-IDEA/lithe-plugin-maven/pull/8)。它们尚未发行，不修改任务一的正式发布门槛。

当前删除/迁移账本（只记录本分支新增证据，不复用阶段 C 的通过数）：

| 流程 | 本分支状态 | 仍须处理 |
| --- | --- | --- |
| Agent 构建 → 输出/状态 → 停止 | 已实现并验证；`MavenService` 任务进程/API/状态机已删除；原生回归 159 项/6 组通过，真实 Agent + Maven 模块编译 4.787 秒通过 | Draft PR；不代替整阶段配置/加载/平台验收 |
| Maven 配置和项目运行设置 | 项目默认和按根工具路径已切 Run local.json；Build 选项按实例保留团队默认及本机差异；协议 7 原生 XML 读取、确认保存、冲突保护和回读已经接通通用插件设置页及真实 Maven。旧设置表单 XML 读取与配置存储已删除；迁移器已接官方插件被动检测，验证后清理源并重新检测，315 项原生回归通过 | 正式包与完整 UI 验收 |
| 项目加载、标签/搜索模块事实、运行配置 | 已删除 MavenService/FeatureModel 和 POM 专属加载；Run 工程路径、源码根、候选来自当前 Provider 模型，无 MavenProject 注入 | Java 入口生成的模块/reactor/源码角色已改为当前 Provider 归属，损坏 POM 共享 fixture、独立 reactor 同名类及真实 Swift bridge 通过；框架识别已改用 Maven 生效插件模型（含 Profile/继承），保留既有服务 ID；编译要求已改用 Maven 实际 execution/参数模型；Wrapper 元数据也已切入 Provider；协议 10 已接框架/模块 Provider 准备及原生 Run/Start All；Java 入口继续复用 JDT。剩余 Core/Windows 旧规划和框架 Debug 边界仍须核对 |
| 依赖树与依赖导航 | 已删除旧 macOS 依赖进程、Swift 文本树桥、临时 adapter 与坐标路径 fallback；Build 用 Provider，导航用 JDT；245 项受影响原生回归通过，真实 Agent 构建及 Provider 编译/精确测试 2 项通过 | 完整 UI/JDT 实机流程、Windows 现存共享命令仍待迁移 |
| Java 导入、运行/测试/调试准备 | Java 导入和 Run Maven 上下文已停用旧服务回退，按 reactor 根读取同一代 Build 输入；315 项受影响原生测试通过；Debug 已等待 Build 输入并检查 ABA 代次；旧 Maven 工程模型已从生产加载删除 | Java 主程序/Debug 的资源准备已接公开 Provider 项目任务（主资源/主加测试资源），Core 仅给未携带当前回执的旧消费者保留资源规划；协议 10 已接框架/模块运行准备、保存引用、Agent 操作身份和 Stop；框架 Debug 的旧 Core 路径仍须核对。协议 9 的 JDT 原样标识、报告精确重跑及工程隔离通过 350 项 macOS 回归、1368 项 Core/集成计时和 Maven 实测；删除宿主 Maven CLI/报告 adapter，测试 Debug 准备补配置 ABA；完整 Java/JDT 后端迁移留在阶段 E |
| Maven 执行中的测试报告 | 协议 8 随操作返回规范报告，Maven 后端用实际配置的 Surefire/Failsafe Mojo 目录和 Apache parser；删除插件内旧固定目录测试选择报告读取器；真实 Core/macOS/Maven 和两个 SDK 通过，Maven 3.6.3 兼容通过 | Java 精确测试宿主路径已切换并删除旧 adapter；Windows 旧共享命令仍未迁移；[固定提交 Java 8 CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40792694290) 在两种 Maven 各 72 项通过；正式包验证仍依赖 SDK 发行 |
| 共享 Maven 命令 | 未删除 | Windows 当前仍直接使用 scanner/launch/dependency/report 命令；接替当前消费者后才能删 Core 命令/fixture |
| 发行包和双平台验收 | 未完成 | 最新正式 SDK/插件组合、macOS 完整 UI、Windows 实机、安装目录字节不变与进程清理 |

本轮新增验证（2026-10-29）：两个真实 SDK 后端及旧兼容场景、Node 65／Java 47 单测、TypeScript 编译通过；Maven 3.9.16／JDK 26 的受控后端和真实 Core reactor 各 15 项通过，涵盖 Unicode、参数化、精确包名、依赖模块跳过、失败报告与包字节不变。协议 9 的[固定 SDK/Core Java 8 CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40824700153) 已通过当前和 3.6.3 Maven；资源准备增量的[固定提交 Java 8 CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40859505864) 也已通过当前和 3.6.3 Maven，包括真实 Core；正式 SDK 锁定与发行门槛仍未完成。

已核对 #818 和 #1493：安装工具/JDK 的项目选择仍是合法的 Lithe 覆盖；
不能用“原生配置”名义改写系统环境或安装目录。原生 Maven XML 的读取与受保护编辑
归插件后端，UI 必须分别表达原生来源值、最终生效值和 Lithe 项目覆盖；不能在打开
页面时把发现的默认值写成覆盖。旧 UserDefaults、旧 Maven 本机文件的清理只能在
目标实际写入并读回验证后进行。

## 任务三：完成 Java/JDT 领域后端及 Run/Test/Debug/框架迁移

**依赖：** 任务二的 Maven 配置所有权；复用 [#1210](https://github.com/1lck/Lithe-IDEA/issues/1210) 的 DebugAdapter Registry 与当前通用 LSP/DAP，不另建调试器或项目引擎。

**目标：** Java 插件真正拥有 Java 领域逻辑，宿主与 Core 保留通用交互、校验和生命周期。

**范围与里程碑：**

1. 盘点当前 JDT LS、Java Debug Server、测试扩展及 Maven/JDT 协作的公开能力；优先复用完整上游子系统。确定 Java 消费工程配置和调试准备所需的最小公共契约，先落共享 fixture，再接生产入口；当前只读模型输入并不等于全部 Java 协作能力已经具备。
2. 把 JDT 启动、资源解析、工作区状态和 Java 专属协调移入插件后端；运行期状态经平台可写目录提供，完整语言服务器资源在构建阶段固定来源、校验并签入插件包。
3. 迁移入口发现、保存后同步/构建、类路径与模块路径解析、Run、精确 Test、Debug、JDT 调试端口、Spring/MyBatis，以及现有长期 Java 应用所需的生命周期。由真实迁移需求决定必要的通用服务能力，不顺带重建一个无限范围的 Services 平台。
4. 把 AppModel、FeatureModel、平台 JDT host integration 和 Rust LSP engine 中相应特例切换到公共接口，再删除被替代的 Java/Maven 领域分支。SDK、契约和当前 Windows 消费者随具体接口同步迁移。

**退出条件：** 当前 macOS Java 工程清单逐项有新路径；保存→同步/构建→解析运行路径→启动的完整流程通过；测试、调试和框架行为保持；停用插件正确撤销能力且不会唤起旧实现；宿主/Core 不再保留仅供官方 Java 插件使用的领域特例。真实 JDT/DAP 和发行插件的运行证据齐全。

## 任务四：完成跨平台与迁移收尾，验收后关闭总任务

**依赖：** 前三项的代码与发行工件；Windows 同步修改随前面接口迁移推进，不等到最后才发现当前消费者已断开。

**范围：**

- 复核 Windows 当前共享命令、Provider 会话、平台 adapter 与发行资源；执行真实 Windows 构建及产品流程，不用 macOS 静态边界检查代替运行验收，也不顺带删除 Windows 独有历史功能。
- 清理被替代命令、fixture、旧测试、资源打包入口及过时文档，每项有现存调用证据、新能力及删除条件。
- 单独复核数据库过渡入口：连接、历史与凭据先完成必要迁移；失败保留源数据。公共图标契约等仍被使用的通用资源不随过渡代码删除。
- 更新决策笔记、共享契约、功能矩阵与资源复用清单；新下载/打包资源有版本/平台/架构身份，运行状态与可变索引不跨工作树共享。
- 用正式包验证安装/升级/停用/关闭、并行工作区、崩溃/取消、无进程残留和 bundle/插件文件清单不变，核对代码签名与增量更新基线。

**退出条件：** #1495 的 macOS 能力和数据清单逐项验收；所有改变过的当前 Windows 消费者有独立验证；旧业务、旧存储和 fallback 已删除；用户数据迁移可追溯。独立分发、基础 API 或某个插件 PR 合并都不能单独作为关闭 #1495 的依据。

## 执行纪律

默认顺序为任务一→任务二→任务三→任务四。每项按完整用户流程组织里程碑与 PR，报告新增行为、删除范围、实测证据和未验证平台；PR 默认 Draft，满足本地与依赖门禁后再 ready。不要提前发布版本、放松校验或把待实施计划写成已完成。

资源准备增量（2026-10-29）：真实 Maven 受控后端及 Core reactor 各 16 项通过，涵盖自定义资源根、过滤、Profile、主/测试资源区分、拒绝附加目标。合并 preview `35b84dad4` 后原生计时 344 项通过；Run 原始点击到保存、Build 和 JDT 等待由现有协调器持有，新请求替换、Stop 与工作区重置都能撤销准备。Windows `cargo check --bin lithe-windows` 与 preview 基线同为 `project_window_registry.rs` 的两项 macOS 平台错误，未出现新增 Rust 类型调用错误；不代表 Windows 实机通过。

真实 Java 协作增量（2026-10-29）：新增显式工具集成，将 Maven Provider 资源任务、JDT 项目构建/运行路径和真实 JVM 串联；嵌套 reactor、依赖模块、非标准主/测试源码根以及导入后修改的过滤资源均验证真实输出，关闭会话后比较插件包与 JDT 安装目录 SHA-256。宿主源码角色选择限制在当前工程，并统一比较链接工作区与 JDT 的规范路径。新增后 Core/集成 1395 项、Swift 130 项计时通过；新增真实链路 35.983 秒，链接路径与角色/撤销回归分别为 3/15 毫秒。此处直接提供同一份 Profile 导入输入，尚不能证明每个 Run 专属 Profile 都已同步进 JDT；运行配置生成、框架/模块规划、Windows Provider 消费者及正式发行仍是阶段 D 的剩余项。

Run Profile/JDT 一致性增量（2026-10-30）：生产宿主在单次资源准备操作内按临时选项/工具读取 Provider 模型，使用同一模型的源码角色选择资源任务，并返回原样 languageImport；Run/Debug 将这份输入用于 JDT 冷启动/热更新，默认发现恢复当前 Build 输入。配置变化/ABA/会话替换撤销旧发现、构建、运行路径和用户错误决策。Core 的入口发现等待 Profile 和项目配置屏障，队列、期限、取消和关闭均有界；异步语义命令取消只影响本操作。真实 JDT 从无入口源码根热切换后首次查询得到两个入口、实际 JVM 读取新资源通过；315 项 Swift 计时通过（参数组汇总 318）。这项输入传递已接通，但整个 Run 生成与框架/模块规划、Windows 消费者和正式发行门槛仍未完成。

2026-10-30 补充验证：Core/集成逐项计时 1398 项全部通过，真实 Profile 热切换→JDT→JVM 场景 14.249 秒；生产 macOS BuildSystemService 与真实 Maven Provider 验证临时 Profile 改变源码角色，宿主确实选择测试资源任务，返回同一导入值，默认模型/选项不变、进程释放且插件包 SHA-256 不变，2.763 秒通过。

运行生成归属增量（2026-10-30）：macOS 等待当前 Build 模型/导入，将规范项目路径、reactor 根和源码角色投影给 Core。Java 归属不再由祖先 POM、旧 modulePaths 或目录名称补齐；两个独立 reactor 都有 app/Main 时保留两项配置，单 reactor 的旧 ID 保持。明确空模型不会恢复旧推断，过期/未准备/截断模型不能用于生成。Windows 省略新输入保持兼容。共享损坏 POM fixture 覆盖同名类、源码角色、空模型和非法边界。Maven 框架检测、部分工具链推断和旧启动规划仍待迁移，阶段 D 未完成。

归属生成最新验证：1399 项 Core/集成、285 项 Swift 计时通过，新的 Core 共享 fixture 用例 17 毫秒；当前工作树源码的 SDK E2E 6 项通过。Windows Cargo 检查与 preview 基线同为两项 macOS 平台错误，无新增公开类型调用错误；不代表 Windows 原生通过。

生成归属补充验收：生产 macOS Provider 集成 4 项全部通过，临时 Profile 的当前模型/归属/导入一致、双 reactor 隔离、真实配置读回和构建测试均覆盖；最慢 5.252 秒。全 Rust crates 与真实 bridge 检查通过。该记录不替代完整 UI 和 Windows 原生验收。

框架识别补充验收（2026-10-30）：Maven 生效模型发布框架选择和模型版本；宿主拒绝
旧插件元数据，Core 关闭 POM 框架检测，保留同 reactor 既有 ID、重名模块和独立
reactor。1399 项普通 Core 计时、286 项 Swift、4 项生产 Provider 集成及 17 项
真实 Core→Maven 集成通过，Profile/继承/仅插件管理与损坏 POM 场景 2.127 秒。
这轮未重跑真实 JDT；既有专用集成记录保留。旧启动规划、工具链推断及发行/双平台
完整验收仍未完成。

编译要求补充验收（2026-10-30）：Provider 通过 Maven 自己的编译执行计划与参数
解析器发布 Java 版本下限，覆盖 Profile/继承、测试版本、自定义 execution、缺失
表达式和非法值；Core 停用此路径的 POM 正则，本机版本偏好不能降低已知下限。
1399 项含真实 JDT 的 Core/集成、286 项 Swift、4 项生产 Provider、18 项真实
Core→Maven 和 Maven 常规集成通过，包清单不变。上一轮固定组合 CI 暴露旧模型
全等断言漏列新增字段，已更新断言并在本地完整常规集成通过；修正后的 [最低运行时 CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40983512456) 已在 Java 8、当前 Maven 和 3.6.3 通过（Core b70929c、SDK 19fbda5、Maven 072960c）。Wrapper 来源也已迁入后端；旧启动规划、Windows 及正式发行仍待完成。

生成结果的模型身份已接通：持久层记录当前工程投影摘要，列表及启动比较当前
Provider 输入；文件指纹、语义摘要与异步操作代次分别处理文件变化、配置变化和
ABA 迟到结果。289 项 Swift、4 项生产 macOS Provider 与 1399 项普通 Core
计时通过，另显式执行 3 项真实 JDT。POM 未变的默认 Profile A→B→A 使生成
过期/恢复，7.496 秒；后台检查串行且只留一次最新待办，100 次通知不会积压。
主 Run、服务单项/批量、Agent 共用入口和 Debug 准备拒绝过期事实，视图复用既有
警告与重新识别动作。旧框架/模块启动规划、Windows Provider/旧消费者和正式
发行/完整平台验收仍未完成。

Wrapper 补充验收（2026-10-30）：原生 properties/脚本元数据、脚本/配置缓存撤销、
宿主同步观察、单根相对路径与独立 reactor 隔离均接通。指纹对脚本和其他文件使用
有单文件 64 MiB 上限的流式哈希。1399 项含真实 JDT 的 Core、286 项 Swift、
4 项生产 Provider、19 项真实 Core→Maven、17 项缓存、16 项受控原生与 16 项
常规 Maven 检查通过；最终开发包再次通过 3 项真实 JDT（16.199/8.056/6.940 秒，
含 Cargo 启动），关闭后包/JDT 清单不变且无进程残留。

Wrapper 固定提交组合的 [Java 8 / 两种 Maven CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40990047639) 已通过（Core 25ef13d、SDK afcc133、Maven 00208cd）；后续生成身份增量不沿用此提交证据。

生成身份收尾：当前 SDK 源码 6 项 E2E、完整 Rust crates、Core/契约边界和最终
24 项 Swift bridge 通过。关闭图时先撤销订阅，避免停止 Provider 的通知排入新
检查；后续 4 项生命周期复验通过。首次早期 AskPass 触发 5 秒连接期限，串行
复验在相同期限内 4.359 秒通过；未放宽超时。


运行选项和框架启动增量（2026-10-30）：协议 10 传递执行类型、独立参数数组、环境、
入口和显式 cwd。Maven 后端用真实生效模型校验目标，使用同一 reactor 的 Maven
执行计划/执行器编译依赖并只启动所选模块，不再让宿主生成框架目标 argv。
原生 Run/Start All 的服务准备彼此独立，Stop、重置和晚到进程回调按操作身份隔离；
Build 树按服务/任务声明发送类型化选项。插件停用/包更新同时撤销准备和运行进程。
macOS 旧 scan/launch/diagnostics/report Swift 桥和旧工程模型类型已删除。
Windows 共享 Maven 命令、Core 旧规划及完整 UI/正式发行验收仍未完成，不能关闭阶段 D。
真实 Core→Maven 的 20 项集成再次通过，包括未安装兄弟模块、Spring Boot 精确 argv、
工作目录和插件包清单不变；当前增量的原生和 SDK 验证结果以本次报告为准。


本增量收尾验证（2026-10-30）：Swift 6.3.3 下 345 项测试通过（344 条计时记录），
其中包含 Provider 服务的 Agent 启动→准备→输出→Stop 身份回归；Core 1403 条逐项
计时通过。生产 macOS Provider 四项显式场景通过，新增 Profile/保存任务准备场景
11.567 秒，另一次真实构建/测试为 6.753 秒；Node SDK 24 项、Java SDK 48 项和
SDK 真实进程 E2E 六项通过。Core→Maven 20 项通过，包括实际 Spring Boot 启动和
插件包字节不变。报告分别在 `.artifacts/test-stability/stage-d-framework-final-swift.html`、
`stage-d-framework-final-core.html`、`stage-d-framework-native-swift.html` 和
`stage-d-framework-native-workflow.html`；它们属于当前开发组合，不是正式发行证明。
保存后的 service/task 分类和参数通过原子写回/读回，重新启动仍按当前插件声明
与模型校验；没有为迁移增加包内可写状态或可跨工作树共享的缓存。


整合最新 preview `f3ee7114f`：保留 #1580 的进程内检测层、缓存和自动识别行为，
Provider 模型摘要、工具要求和类型化准备改从同一检测层读取。合并前固定提交组合
Core `1e66735` / SDK `af13e3c` / Maven `b426f42` 的
[Java 8 + 当前 Maven/3.6.3 CI](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/41017667643)
已通过；合并后的验证另行记录，不能复用这项通过数。


最新基线整合验证：346 项 Swift 回归通过（345 条计时记录），Core 两轮各 1414 条
计时通过，其中一轮显式开启三项真实 JDT/JVM（43.535/14.328/10.980 秒）。五项
生产 macOS Provider 场景均通过并低于原有单项预算；Profile 和已保存任务各自拥有
独立模型加载/清理，不能依赖另一场景先行准备。两个同名构建系统插件的进程按完整
包身份撤销，保留未停用插件的会话。SDK E2E 六项、真实 Core→Maven 20 项、资源复用
30 项、i18n 35 项以及 C ABI/链接/Git 25 项 Swift bridge 通过。Windows Cargo 检查
仍只出现 preview 基线的 project_window_registry.rs 两项 macOS 平台 API 错误，
没有新类型/签名调用错误；这不代表 Windows 原生验收。
报告前缀为 `.artifacts/test-stability/stage-d-preview-*`，保留完整 HTML/JUnit。


团队文档和 Windows 原生窗口接线（2026-10-31）：`build.projectOptions` 统一存储语法校验，
macOS/Windows 复用共享 fixture；`build.detect` 直接返回按作用域与实例根合并的保存选项，
保留空选择。Core 1,436 项、macOS 144 项计时通过。Windows 工作区所有者已接入项目
关闭/替换及插件停用确认，目录刷新不丢失历史目标，失败清理保留所有者以供重试。通用
Build 窗口复用现有侧栏/底部输出、模型任务虚拟列表；受控点击覆盖加载、执行、Stop、
隐藏后恢复和迟到输出隔离。原生项目库 49 项中 48 项通过，唯一 POM watcher 超时
已在改动前基线复现，新增团队文档与原生配置测试均通过；不能声称该 crate 全绿。
报告前缀为 `.artifacts/test-stability/stage-d-build-document-*` 与 `stage-d-windows-build-*`。
Windows 配置 UI/迁移、声明任务/依赖/报告呈现、文件观察、Run/Java/Agent 与实机验收
仍未完成；不开放 Build 能力，不删除仍有消费者的旧 Maven 命令，不据此关闭阶段 D。

此增量最终本地复验：Windows 前端 111 项及隔离插件生命周期 6 项全部通过，
`bun run build` 和 TypeScript 检查通过；Rust crates、C ABI、链接符号、Git/Swift
bridge 25 项通过。原生团队文档 4 项分别为 10/10/6/6 毫秒，完整项目库仍保留
同一项基线 watcher 超时。Windows Cargo 仅有既有 `std::os::windows` 与
`same_file::Handle::as_raw_handle` 两项 macOS API 错误；未进行 Windows 原生验收。


Windows 原生配置设置接线（2026-10-31）：插件设置详情根据已准入声明显示真实来源，
工作区持有草稿，隐藏/重开不丢修改。继承值预填、显式覆盖、取消、逐来源保存及
保存后回读已接通；保存一个来源不丢另一个来源草稿，失败重载/回读后禁止用旧基线
继续保存，外部冲突保留草稿。默认项目工具不运行，明确读取才继续；迟到文件选择
不能覆盖重载后的状态。Windows CI 增加对应有界 Build 回归，仍不开放产品能力。
旧数据迁移、其他 UI/Run/Java/Agent 和 Windows 实机/正式发行仍是剩余项。

本地计时：受影响前端 120 项、与新增 CI Build 车道完全相同的 59 项、隔离插件
生命周期 6 项通过，含 9 项原生配置编辑器/控制器回归；类型检查与前端构建通过。
共享词条 9681 个、i18n 35 项和相关边界通过。`ci-workflow-gates.test.mjs` 在本机
系统 Bash 3.2 下有 21 项失败，隔离的 b43202184 改动前同样复现 21 项；最小
`[[ false ]]`/`-e` 组合也不退出，与新 Build 测试登记无关，未改动门禁。
报告为 `.artifacts/test-stability/stage-d-windows-native-settings-*`。

使用临时构建的 Bash 5.2.37 按 Linux CI 语义复验：113 项门禁、分类器全部用例
及 19 项复用规划测试通过。临时工具链和源码均已清理，产品未新增下载或缓存目录。
原先系统 Bash 3.2 的失败只记录为环境诊断，最终等价检查以上述现代 Bash 结果为准。


Windows 任务与依赖呈现后续增量（2026-10-31）：通用窗口按工作区/模块显示公共声明
和模型任务，按分类排列，显式参数确认保留 argv 项边界，取消不执行。依赖只展示
上游/Core 节点并虚拟化，不从坐标推导本机路径；最多四份内存快照，模型/配置失效
和取消后丢弃迟到结果。设置保存导致的模型撤销现在有独立低频通知，旧任务立即消失，
输出进度不会重绘模型树或重复检查配置草稿。目标任务、报告/测试呈现、文件观察、
Run/Java/Agent、旧数据迁移及完整 Windows/正式发行仍待完成；产品准入继续关闭。

任务/依赖增量最终计时：受影响前端 127 项、CI Build 同范围 66 项通过；生产前端
构建、TypeScript、i18n 35 项/9697 词条、共享/服务/Windows 边界及 bundle 只读检查
通过。新增回归验证模块/工作区选择、明确参数确认、分类顺序、依赖展开、四份缓存
预算和模型失效即时呈现；没有新资源目录或持久状态。报告前缀为
`.artifacts/test-stability/stage-d-windows-task-presentation-*`。

Windows 报告与文件失效后续增量（2026-10-31）：使用 Core 的规范诊断、测试汇总、
用例和发现选择器，展示失败详情并导航源码；保留精确工程/目标身份，不按测试名称
猜测模块。报告和发现各保留最近四份快照，大报告虚拟化，进度通知不会复制旧报告。
取消中的解码和普通完成后的迟到进度均不能重新发布结果。

模型加载前后检查根输入，保存 Core 的完整 watch 清单；每次执行前重新核对完整
指纹。源码事件清除发现清单并取消首次模型/发现准备，命中 watch 撤销模型/依赖/
报告。团队文档立即撤销旧目录并合并只读检测；路由覆盖全部已有工作区，不依赖
当前文件树的异步目录查询。没有新增持久状态、资源目录或后台进程。

该增量仍未完成外部原生配置文件观察、目标 Run/Debug、Java/Agent、旧数据迁移与
真实 Windows/正式发行验收；产品准入继续关闭，阶段 D 不关闭。

本地 149 项受影响前端、CI Build 同范围 81 项通过，含万级报告虚拟化、输出不复制
报告、精确用例/源码跳转、源码与 watch 失效、首次准备取消、漏事件指纹检查和
旧检测拒绝发布。TypeScript、生产 bundle、i18n 35 项/9711 词条、共享/服务/Windows
边界、172 Notes、222 矩阵、测试稳定性和 bundle 只读检查通过。该批未改 Rust/Swift，
未重算之前的原生通过数。报告前缀为 `stage-d-build-reports-watch-*`。
新增行的 Windows 稳定性门禁通过；另行全量扫描报告四个未改文件的 22 项旧 sleep/
timer，逐文件与本批前 HEAD 对照完全一致，未改动或放宽这些既有规则。

Windows 外部原生来源观察增量（2026-10-31）：模型读取同时获取已声明的来源投影，
发布和执行前核对原生版本；只返回一致性和路径，不向 WebView 传 XML 或凭据。
来源和符号链接目标复用窗口文档 watcher，保持编辑器租约；缺失父目录观察现存
祖先，目录创建后更新观察，不创建 `.m2` 或用户文件。通知合并、迟到原生读取、
失效与保存/回读分别持有；插件撤销等待来源检查清理完成。

本地受影响前端 175 项通过；原生项目 53 项中 49 项通过，新增来源检查三项及真实
缺失父目录观察一项全部通过（4–39ms）。同一环境用本批前 `bfcd4690d` 的隔离源码
复验 49 项，45 项通过，完全相同的四项 Git/root/POM watcher 五秒超时；保留失败
证据，未修改或放宽这些旧用例。临时源码已清理。macOS 上的 Windows host check
仍仅两个既有 Windows API 错误，没有新增类型错误。报告前缀
`stage-d-build-native-watch-*`。Run/Debug、Java/Agent、旧数据迁移、正式发行与真实
Windows 验收仍待完成，能力准入继续关闭，阶段 D 不关闭。

该批 CI Build 同范围 91 项、TypeScript 与生产 bundle、共享/服务/Windows 边界、
172 Notes、222 矩阵、9711 词条一致性、测试稳定性及 bundle 只读门禁通过。
来源监听与检查只持有内存租约，关闭/插件撤销后排空，临时比较源码已删除；没有
新增运行时资源目录、持久状态或跨 worktree 共享项。

Windows 已保存 Provider Run 增量（2026-10-31）：Core 的公共 Run 选项、精确工程/
目标选择器和准备结果交给既有 Native Run；所选 Maven/JDK 来自公共语言导入与
工具上下文，不再让这条路径依赖旧 Maven store。默认模型由并发服务共同等待，
各自取消；准备输出直接追加现有 Run 面板。启动前重查保存选项、工具、工程指纹
和原生来源版本，插件/工作区所有者等待迟到启动确认并按执行 ID 清理。原生输出/
退出携带执行 ID，旧事件不能结束替换会话，清理失败保留所有者供重试。

真实 Windows TypeScript→Core→Maven Provider 的集成补上只读来源检查，九项均
通过，新增模块 Run 规划 137ms；默认模型/选项和开发包文件清单保持不变，后端已
清理。报告在 `.artifacts/test-stability/stage-d-windows-real-run/`；测试运行于 macOS，
不代表 Windows 原生启动验收。该批当时仅覆盖已保存引用的默认模型；后续临时模型增量见下。目标树 Run/Debug、
旧配置/Java/Agent 迁移与正式发行仍未完成，能力准入继续关闭。

本批 Windows Build/共享进程所有者 100 项、完整 Run 335 项计时通过，覆盖共享模型
取消、原生启动迟到、失败清理重试、参数编辑后拒绝旧计划和会话替换事件隔离。
TypeScript、生产 bundle、共享/服务/Windows 边界、172 Notes、222 矩阵、测试稳定性
和 bundle 只读检查通过。报告为 `stage-d-build-run-final`、`stage-d-windows-run-final`
及 `stage-d-build-run-*`；Windows host check 仍只含两项既有 macOS 平台 API 错误。

Windows 临时运行模型增量（2026-10-31）：已保存引用和准入后的已有框架/模块配置
都从 Core 的当前输入准备，保持已有服务 ID。每个 Run 使用自己的有效模型、Profiles
和 reactor 工具选择，再应用运行配置明确保存的 Maven/JDK 路径。Core 复用原有配置
合并，空路径继承 reactor；不把全局默认误当成单项覆盖。单项模型直接加载，不再
依赖默认模型及默认工具可用，原生来源观察独立释放；后端会话继续由工作区拥有，关闭
一个临时模型不会停止其他服务。启动前只读重新检测，未变化目录保留身份，漏文件
通知也能发现新的团队选项。Native exit 早于启动确认时仍等待清理，失败保留所有者；
同一次 Stop 不自动重试失败清理。原生能力表保持关闭，旧框架生产入口继续原路线。

共享保存引用 fixture 增加旧应用参数通道约束，macOS/Windows 都保留协议 4 的
原始参数；实际新版 JVM/环境/cwd/入口/Debug 选项仍由 Core 拒绝不兼容后端。
验证报告以 `stage-d-private-run-final`、`stage-d-private-run-core-final`、
`stage-d-windows-private-run-final/` 和 `stage-d-private-run-swift-regressions` 为准；
受影响前端 427 项、Core/集成 1437 项、Swift 292 项及最终桥接 19 项通过；
真实 Core→Maven 11 项通过，临时 Profiles 1.669 秒，
配置选择另一 Maven 入口并继续使用共享后端 1.921 秒，默认模型/选项和包字节不变。
每项运行的工具覆盖、空值继承、团队合并及来源只读由新增共享 fixture 验证。
未进行原生 Windows 验收。

目标树 Run/Debug、同一临时输入的 JDT/资源准备、Agent、旧偏好迁移和其余生产消费者
替换仍未完成；正式 SDK/插件发行及完整两端验收仍是退出条件，阶段 D 不关闭。
