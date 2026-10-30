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
| 项目加载、标签/搜索模块事实、运行配置 | 已删除 MavenService/FeatureModel 和 POM 专属加载；Run 工程路径、源码根、候选来自当前 Provider 模型，无 MavenProject 注入 | Java 入口生成的模块/reactor/源码角色已改为当前 Provider 归属，损坏 POM 共享 fixture、独立 reactor 同名类及真实 Swift bridge 通过；框架识别已改用 Maven 生效插件模型（含 Profile/继承），保留既有服务 ID；编译要求已改用 Maven 实际 execution/参数模型；Wrapper 元数据也已切入 Provider；框架/模块启动规划仍需迁移，Java 入口继续复用 JDT |
| 依赖树与依赖导航 | 已删除旧 macOS 依赖进程、Swift 文本树桥、临时 adapter 与坐标路径 fallback；Build 用 Provider，导航用 JDT；245 项受影响原生回归通过，真实 Agent 构建及 Provider 编译/精确测试 2 项通过 | 完整 UI/JDT 实机流程、Windows 现存共享命令仍待迁移 |
| Java 导入、运行/测试/调试准备 | Java 导入和 Run Maven 上下文已停用旧服务回退，按 reactor 根读取同一代 Build 输入；315 项受影响原生测试通过；Debug 已等待 Build 输入并检查 ABA 代次；旧 Maven 工程模型已从生产加载删除 | Java 主程序/Debug 的资源准备已接公开 Provider 项目任务（主资源/主加测试资源），Core 仅给未携带当前回执的旧消费者保留资源规划；框架/模块启动规划仍待迁移。协议 9 的 JDT 原样标识、报告精确重跑及工程隔离通过 350 项 macOS 回归、1368 项 Core/集成计时和 Maven 实测；删除宿主 Maven CLI/报告 adapter，测试 Debug 准备补配置 ABA；完整 Java/JDT 后端迁移留在阶段 E |
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
