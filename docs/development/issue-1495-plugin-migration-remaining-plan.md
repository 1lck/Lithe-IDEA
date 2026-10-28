# #1495 剩余插件迁移：四个大任务

这是执行计划，不代表下面的迁移已经完成。总目标见 [#1495](https://github.com/1lck/Lithe-IDEA/issues/1495)，职责和取舍以 [Build Provider 决策笔记](../../.agents/notes/implemented/architecture/2026-10-26-build-provider-task-execution.md) 为准。每个大任务可以包含多个可验收 PR，不能只增加新接口而一直保留旧业务入口。

## 当前交付边界

- 阶段 A 清单在 [PR #1513](https://github.com/1lck/Lithe-IDEA/pull/1513)，独立分发在 [PR #1483](https://github.com/1lck/Lithe-IDEA/pull/1483)，保持原范围，不重复认领。
- 宿主/Core 的原生构建、测试发现/执行、运行/原生调试准备、保存的运行配置和只读模型共享在 [PR #1517](https://github.com/1lck/Lithe-IDEA/pull/1517)。配套实现为已合并的 [SDK PR #4](https://github.com/Lithe-IDEA/lithe-plugin-docs/pull/4) 和 [Maven Draft PR #7](https://github.com/Lithe-IDEA/lithe-plugin-maven/pull/7)。
- Maven 插件已完成本地原生执行切片：生命周期、插件目标、自定义目标和测试由工作区后端执行；模型仍来自现有 Maven 扩展。它尚未替换宿主全部 Maven 消费者。
- 这些是开发源码和本地验证；正式 SDK/插件发行、完整 macOS UI、Java/JDT 和 Windows 实机验收不能据此勾选完成。#1495 保持开放。

## 任务一：完成宿主、契约、SDK 与 Maven 插件的合并发布闭环

**目标：** 用户能从正常插件渠道安装一组明确兼容、校验通过的最新版本，不依赖本地 SDK JAR。

**范围与顺序：**

1. 完成 #1517 的评审和本地/CI 验证，合入 preview；确认原生 Provider 与只读模型共享的最终契约。
2. 在 `lithe-plugin-docs` 用合并后的 preview commit 运行 `node scripts/contract.mjs sync --revision <commit>`；不手改镜像或伪造锁定值。
3. Node/Java SDK 实现已于 2026-10-28 随 SDK #4 合并；在最终 Core 与 preview 上复验真实端到端场景，再按其发布流程发布实际的新版本。Node 20、Java 8 的既有源码 CI 证据见下表，不代替正式发行组合。
4. Maven 插件将 `sdk.lock.json` 和构建依赖更新到实际发布的版本、URL、SHA-256；用正式 `package.mjs` 验证，开发构建覆盖不能进入发行流程。
5. 验证最新宿主的安装、更新、能力拒绝提示和插件包只读。只有实际符合来源、签名和市场规则的工件才进入分发。

**退出条件：** 三仓 PR 和依赖顺序可追踪；契约副本逐字节一致；SDK 和 Maven 包都有真实发行地址与校验值；正式打包、最低支持运行时和当前平台流程通过。未实现的 Windows Provider 能力继续明确拒绝。这个任务不负责删除全部旧 Maven/Java 业务。

### 阶段 C 的验收记录与交付门槛

| 验收项 | 当前证据与剩余动作 |
| --- | --- |
| 无页面的工作区 Provider、执行与测试 | Core、生产 macOS 会话表与真实 Maven 后端已经完成多模块读取、模块编译、精确单方法执行和报告解码；集成测试显式选择开发包与工具，关闭后核对包清单不变。 |
| Run、原生 Debug 与适配器贡献 | 原生入口、保存配置、Agent 操作身份和类型化准备已经实现；真实 SDK 进程覆盖准备、失败、取消及另一工作区隔离。真实 LLDB 已通过 Provider 编译→Registry 启动→命中断点→读取栈帧→带参数继续执行→退出及清理，插件包保持只读；完整 UI/发行包流程仍需验收，Java/JDT 领域迁移属于任务三。 |
| 配置快照与跨插件协作 | 协议 6 的只读模型输入公开选定事实，配置/源码/模型/插件/工作区变化撤销旧输入；两个真实 SDK 后端经过 Core 交换公开投影。不能据此声称 Java 已消费 Maven 全部配置。 |
| 最低 SDK 运行时 | [显式宿主 CI](https://github.com/Lithe-IDEA/lithe-plugin-docs/actions/runs/40531099687) 的 Node 20、Java 8 原生端到端作业通过，宿主固定为 `58ca81cf66c5c6e281c7df73ac67adb3526174f3`。该整轮工作流的契约漂移检查仍失败，镜像等待主 PR 合并后同步。 |
| Maven 最低运行时 | [固定 SDK 提交的开发验证](https://github.com/Lithe-IDEA/lithe-plugin-maven/actions/runs/40533306865) 已通过 Java 8 后端及当前/3.6.3 Maven，每组 55 项计时检查（含 3 项打包）；不能代替旧 SDK 锁定下仍失败的正式打包检查。 |
| 正式合并、契约同步与发行 | 截至 2026-10-28，SDK #4 已合并；宿主 #1517 仍 OPEN/Ready，Maven #7 因正式 SDK 锁定依赖继续保持 Draft。必须在宿主合并后用实际 preview commit 同步契约、发布 SDK，再更新 Maven 的真实版本/URL/SHA-256 并完成正式包验收；不能先填预期校验值。 |

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

- 工作分支 `codex/issue-1495-maven-migration` 从 `upstream/preview@0beb43c936f61e68b983533805d6534a01fdf8b4` 建立，整合 #1517 的 `9f702e15deeeed2e9889d396fab50c706ee48c0a` 作为阶段 C 源码依赖；不修改 #1517。
- 首个完整流程为 Agent 查询插件 Build 实例/任务 → Provider 执行 → 输出/退出查询 → 按 ID 停止。新入口复用 Build 服务；同步删除旧 Maven 任务执行 API、进程和状态机。配置与加载旧路径尚未删除，不能标记任务二或阶段 D 完成。
- SDK #4 已于 2026-10-28 合并，后续发行状态按真实 GitHub 记录核对；上文“尚未合并”的 SDK 描述是旧记录，不能用它阻塞可独立实施的源码迁移。

当前删除/迁移账本（只记录本分支新增证据，不复用阶段 C 的通过数）：

| 流程 | 本分支状态 | 仍须处理 |
| --- | --- | --- |
| Agent 构建 → 输出/状态 → 停止 | 已实现并验证；`MavenService` 任务进程/API/状态机已删除；原生回归 159 项/6 组通过，真实 Agent + Maven 模块编译 4.787 秒通过 | Draft PR；不代替整阶段配置/加载/平台验收 |
| Maven 配置和项目运行设置 | 未迁移 | `.lithe/maven/config.json`、旧本机 Maven 文件、运行偏好与 Build 选项的唯一持有方；一次性迁移保留失败源；原生 XML 草稿/冲突/读回 |
| 项目加载、标签/搜索模块事实、运行配置 | 展示层已切通用 Build 模型；项目加载/运行配置未迁移 | 用 Provider 模型替代 POM scanner，删除旧 MavenProject 注入；Java 入口继续复用 JDT |
| 依赖树与依赖导航 | 已删除旧 macOS 依赖进程、Swift 文本树桥、临时 adapter 与坐标路径 fallback；Build 用 Provider，导航用 JDT；245 项受影响原生回归通过，真实 Agent 构建及 Provider 编译/精确测试 2 项通过 | 完整 UI/JDT 实机流程、Windows 现存共享命令仍待迁移 |
| Java 导入、运行/测试/调试准备 | 未迁移 Maven 协作边界 | 删除 `launchContext` fallback，全部消费同一配置代次；Java/JDT 全领域迁移留在阶段 E |
| 共享 Maven 命令 | 未删除 | Windows 当前仍直接使用 scanner/launch/dependency/report 命令；接替当前消费者后才能删 Core 命令/fixture |
| 发行包和双平台验收 | 未完成 | 最新正式 SDK/插件组合、macOS 完整 UI、Windows 实机、安装目录字节不变与进程清理 |

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
