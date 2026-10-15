# Agent 笔记：模块运行时边界与生命周期

状态：已实现

## 先说结论

模块的启动、停止、资源持有和故障恢复由统一运行时负责，模块本身只使用被授予的能力。禁用模块不能偷偷启动进程或 watcher；模块启动失败后，运行时必须能记录状态并支持后续恢复。

## 问题

功能模块不仅是隐藏的 UI 或源码目录，还必须决定什么时候构造、由谁持有
长生命周期资源、如何和其他模块通信，以及发生启动故障后如何恢复。如果
这些职责散落在 `AppModel`、服务字段和平台组合代码中，禁用模块仍可能
启动任务或进程，休眠也可能留下 watcher、连接、PTY 或子进程。

原生插件还需要在不加载模块代码的情况下完成版本、所有权和恢复判断。否则
一次未完成的激活或 Bundle 加载失败，会让下一次启动再次触发同一个故障。

## 决策

Lithe 使用 `LitheModuleAPI` 加 `LitheApplicationKernel` 作为统一的模块运行时
边界。模块生命周期、依赖、能力、资源和恢复状态由运行时持有，功能模块只
通过 `ModuleContext` 获得声明过的能力和资源接口。

```text
MacServiceContainer
    -> ModuleRegistry
        -> ModuleRuntime
            -> ModuleFactory
                -> LitheModule
```

### API 与运行时分层

- `LitheModuleAPI` 只定义平台无关的 `ModuleID`、manifest、依赖、能力、
  生命周期、事件、资源、lease、贡献和插件宿主协议。它不得依赖 UI、
  AppKit、具体平台适配器、Rust bridge 或功能实现。
- `LitheApplicationKernel` 中的 `ModuleRuntime` 负责注册、依赖图校验、
  能力提供者解析、按需构造、状态转换、资源回收、能力发布和关闭。
- `ModuleRegistry` 是组合根的声明式注册面：每个功能模块提供一个
  `ModuleFactory`，注册结果必须和已校验的静态插件 manifest 及贡献目录
  一致。
- macOS 的 `MacServiceContainer` 负责创建平台能力、读取模块配置和恢复
  元数据、注册内置模块与已加载插件。它不把全部功能实例提前构造到
  `AppServices`。

模块实现 target 只依赖 `LitheModuleAPI`、`LitheCoreContracts` 和自身需要
的工作流库；模块不能反向依赖 `Lithe` 可执行 target。应用侧通过能力、
事件和贡献目录使用模块，不通过另一个模块的具体 service 类型。

### 必须保持的生命周期不变量

1. 禁用、隔离或 Safe Mode 抑制的可选模块不会调用 factory，也不会启动
   task、timer、session、watcher、连接或子进程。
2. `onDemand` 模块只有在声明的能力被请求或被显式激活时才构造。依赖
   先于被依赖模块激活，依赖图必须无环，能力提供者不能发生静默覆盖。
3. 每个长期资源只能登记到一个模块的 `ModuleResourceScope`。注销活动
   资源会被拒绝，停止资源后才能释放登记。
4. `ModuleLease` 表示不可中断工作。存在活动 lease 时，休眠失败并发布
   可观察的阻塞原因；运行、测试、调试、终端、导入导出和事务等工作必须
   使用这个机制阻止后台回收。
5. 休眠依次准备模块、停止模块服务、停止登记资源、确认没有活动资源、
   移除能力和贡献，并释放实例。唤醒时重新构造实例，先激活依赖，再恢复
   能力。
6. 可选模块在调用 factory 前写入 pending activation 标记。启动时如果
   标记未清除，恢复存储会先把模块隔离，应用可以在不构造模块的情况下
   启动并允许用户重新启用它。
7. 官方插件是声明式包，不向进程加载代码；插件 manifest、插件 API 版本、
   模块所有权和语言支持在注册宿主模块前校验，Safe Mode、禁用和隔离由
   `ModuleRuntime` 照常处理。原来的进程级原生加载标记已移除，旧标记在
   启动时清除而不隔离模块，见
   [声明式语言插件](2026-10-12-declarative-language-plugins.md)。
8. 模块仍然运行在应用进程内。上述标记、隔离和 Safe Mode 是下一次启动
   的恢复机制，不等同于进程隔离，也不能宣称第三方模块崩溃不会终止应用。
9. 静态贡献目录可以被工作台读取而不构造模块；模块实例激活后才发布
   实际贡献，休眠、禁用或失败回滚时移除这些贡献。

### 同一模块的并发激活与关闭

一个模块可以贡献多个窗口；同时打开它们必须等待同一项构造任务。运行时持有
这项任务，UI 取消只取消自己的等待和显示意图，不能取消其他窗口的请求。
激活入口及每次等待休眠或关闭结束后都检查调用方取消状态，再创建或加入共享激活任务；已经取消的等待者不能在关闭结束后重新构造模块。这只撤回该调用方，不取消其他窗口共享的激活。
模块发布能力和贡献之前再次检查取消状态，构造失败或被关闭时清理已登记资源。
`module.activation-joined` 事件表示另一个请求正在等待相同构造，便于诊断。

同一模块的关闭请求也合并。禁用先撤回可用性，再取消和等待在途激活，确保晚到
的结果不能覆盖禁用状态；重新启用必须等待旧关闭完成。休眠也先取消未完成的
构造，并在取消构造前登记休眠任务；直到 prepareForSleep、sleep 和资源清理结束之前，新激活和启用操作必须等待这项任务，关闭也先等待休眠结束再清理。module.activation-waiting-for-transition 事件记录激活等待；任务完成时由任务自身移除等待屏障，避免完成的任务被反复等待。正常关闭仍按照已有资源清单验证清理结果；清理失败保留失败状态并返回
错误，不能把残留资源伪装成成功禁用。上述任务仍在主执行器上使用异步等待，
不阻塞线程、不新增插件代码加载能力。

### 数据库视图在模块释放后的刷新

退出应用或休眠数据库模块时，SwiftUI（macOS 的声明式界面框架）可能先刷新
已经存在的子视图，再移除父视图。父级检查“模块是否激活”不能保证子视图
刷新时能力缓存仍存在。#924 的退出崩溃堆栈落在数据库工作区渲染函数；
该函数原本会强制读取能力缓存，缓存已清空时会触发断言，与报告吻合。

工作台和编辑区入口通过可空的 `databaseFeatureIfActive` 获取当前状态对象，
再用 SwiftUI 环境传给数据库工作区、侧栏和弹窗。它们只读取、观察这次注入的
`DatabaseFeatureModel`，不再每次渲染或异步操作恢复时从 `AppModel` 强制取值。
例如，旧查询视图在模块释放后仍可完成最后一次刷新；模块重新激活时，新视图
会接收新实例，旧视图的晚到回调不会转而修改新实例。

视图持有状态对象不代表模块继续运行：`prepareForModuleRelease()` 仍在释放
流程中停止定时器、取消计划任务并使在途请求失效。旧对象只保留到最后一个
视图或回调放开引用，不把它永久缓存为 `AppModel` 的后备实例。不要通过
延迟清空能力缓存、只切换侧栏，或访问失败时临时构造模块来掩盖退出竞态；
这些做法分别依赖刷新时序或破坏按需激活边界。

代价是数据库视图入口必须传入状态对象，弹窗也必须继承同一环境。
`DatabaseWorkspaceLifecycleTests` 覆盖原生视图在会话关闭后再次渲染、弹窗
晚到刷新，以及模块休眠后资源清理、旧状态释放和唤醒的新实例隔离。

### 数据库右侧入口与编辑器标签

数据库连接树通过已有模块入口注册到右侧停靠区，与 Maven、Agent 共用一个
位置；打开入口不替换左侧项目树，也不切换中央代码。搜索图标左侧的概览按钮
按需打开可关闭的 Database Overview 标签，保留连接数、已连接数、类型数、
快速开始、常用操作和最近八条 SQL 六个区域。统计、连接和历史直接读取现有
DatabaseFeatureModel，不复制会话；共享标题、分隔线、字体、表面与行悬停代替旧卡片样式。
概览的常用操作按钮取消 Spacer 撑满整行和零圆角悬停，复用共享 litheRowHover，背景只覆盖按钮内容及内边距，禁用动作不绘制悬停。
依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `ActionButtonLook.paintBackground`，悬停背景取控件本身尺寸并扣除 insets；`IdeaActionButtonLook` 使用圆角背景，Islands 主题为 ActionButton 提供 hoverBackground token。这里复用项目已批准的圆角/颜色，不把主工具栏按钮尺寸套到概览。
连接弹窗保留原生 DisclosureGroup 箭头和展开状态；Safety/Advanced network 的标签填满标题行，并在标签上切换同一状态，避免必须精确命中箭头。手势只作用于标签，不拦截展开内容的输入或开关。
概览连接弹窗删除 SwiftUI sheet，改用与侧栏一致的 LitheCenteredPopup：animationBehavior.none、原生有标题子窗口，无系统 sheet 遮罩和额外自绘外框。
概览和数据内容标签使用侧栏圆柱图标；每个连接保留一个数据标签，标题使用配置的数据库名（无数据库名时使用连接名）。没有连接的全局历史仍使用 SQL History。
右侧树切换表，不创建第二层表标签。Data/SQL/Structure/History 入口继续使用
16pt SVG 和共享 22pt 按钮；SQL 入口选中该连接已有控制台，New Query 则为
每个查询打开独立的顶层 console 标签。查询标签使用连接品牌图标，与数据标签
独立切换、拖动和关闭，不再在数据页面里嵌套 Query 标签与第二行工具栏。
单行标签栏在新增或选中数据库内容时滚动到活动标签，避免多个 console 把新标签挤出视口。

标签顺序持有连接 ID 与查询 ID；数据库模块仍只有一个状态对象与一套 Provider。
模块记住各连接最后的表、页面、SQL 草稿及选中查询；切回时复用既有请求加载表，
不缓存结果页或开启后台连接。SQL 查询结果和运行状态不跨连接带入。
关闭数据标签保留连接和草稿，关闭查询只移除所属连接的查询；最后一个内部查询
保持空草稿供下次打开复用。休眠、关闭项目和禁用模块移除全部数据与 console 标签，
同时释放连接位置缓存。切换 MySQL/MariaDB 数据库保留查询 ID 和 SQL 草稿，
清理旧表及查询结果，避免控制台标签失去内容或显示旧库结果。

查询控制台只有一行共享动作栏，编辑器始终填满中央面板；查询结果与 Output 放在底部 Services 工具窗口，复用 workbench 停靠布局、LitheToolWindowHeader、LitheToolWindowTabStyle 与 LitheSplitPaneView，拖动状态留在共享分隔容器。
原生 SQL 编辑器继续保留补全、格式化、执行选区、风险确认和历史恢复，复用
LineNumberGutterView 的行号、滚动、字体和明暗主题，不再写一套 SQL 专用行号。
MySQL/MariaDB 的数据库选择入口从侧栏品牌按钮移到控制台右侧的数据库菜单；当前数据库排在首项并以共享菜单选择色初始高亮，其他数据库放在 Non-Introspected 分组，原刷新动作保留在末尾。数据库名称不经过界面翻译；菜单继续由共享原生 presenter 处理键盘、关闭及屏幕边界。
其他类型显示当前数据库。该连接任一查询执行或风险确认期间禁用选择菜单。

Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 未公开 Database Tools 的
SQL 插件实现，不能把截图的完整专用工具栏宣称为 Community 源码。
这里核对通用 LanguageConsoleImpl.kt 的标准编辑器复用及 ActionButtonLook.java
的按钮状态，再结合 JetBrains Query consoles 官方文档与截图的布局；保留 Lithe
已有动作，不加入没有后端行为的事务、Playground 等占位按钮。

数据库标签的激活属于点击时的同步导航：`AppModel.selectDatabaseWorkspace` 复用
`DatabaseFeatureModel.activateProfile` 切换连接并立即打开标签，随后才刷新数据。
侧栏、概览、查询、历史恢复和表动作复用同步导航入口；页面与 SQL 草稿也在点击时配置。
正确做法是先选中 B 标签，再让 B 的请求更新数据；不要在 `await select/refresh` 后
重新打开标签，否则用户期间转到文件、Overview 或关闭 B，会被迟到结果抢回。
不额外维护导航令牌，因为数据完成回调不承担导航；旧数据仍由模块已有请求 ID
和代次检查丢弃。关闭标签后已开始的数据加载正常结束，避免留下永久 loading 状态。
`delayedConnectionLoadPreservesLaterNavigation` 使用已有 TestGate 控制成功/失败请求，
覆盖切到文件、概览、关闭单个/全部标签和请求开始前关闭，断言请求结束后不改变导航。

编辑器单独保存活动连接 ID；后台连接测试、保存连接与刷新不推导标签选择，也不切换当前连接。
后台保存仅更新自己的连接状态，不设置或清除当前页面的 Loading；连接弹窗以局部连接中状态控制进度和重复提交，不能借用表格加载锁。A 加载与 B 保存先后完成时，A 的加载状态始终由 A 的请求负责；`backgroundSavePreservesCurrentLoading` 用 TestGate 覆盖空闲、刷新、打开表、分页及后台保存成功/失败的两种完成顺序。
删除连接成功后由 AppModel 移除该连接的数据和查询标签，再按现有顺序回退；不能仅靠渲染过滤隐藏失效 ID。
表格提交期间，Feature 按连接 ID 记录在途写入，仅锁定当前连接的三类草稿写入口和编辑 UI，避免新增 A 提交后被改成 B 而重复 INSERT。切到其他连接时，其表列表、分页和编辑继续正常；模块资源判断仍包含后台连接的在途提交，不能仅检查当前页面的锁。
成功后先清理提交草稿再刷新；连接代次、表名和页面请求 ID 都未变化时才允许刷新。
例如 A 提交期间切到 B 或 A→B→A，旧提交只能完成写入，不能刷新新的页面或清掉新草稿。
这选择了短暂禁止编辑，而未引入按主键合并并发草稿的复杂状态；失败保留草稿供重试。
`delayedApplyLocksDraftsAndPreservesNavigation` 使用有界 TestGate 验证成功/失败及上述导航，
`backgroundConnectionManagementPreservesEditorSelection` 和
`removingConnectionClosesOwnedTabsAndFallsBack` 验证后台管理和删除回退。

侧栏点击和 AppModel 的同步选表都通过 `DatabaseFeatureModel.selectTable`，由 Feature 清理旧页并记录目标。当前连接正在提交时复用延后刷新集合，写入结束释放锁后才加载最后选择的表；不能先在 View 改 `selectedTable`，再依赖 `openTable` 对比旧表。`sidebarTableSelectionDuringApplyLoadsLastSelection` 覆盖真实 AppModel 入口的 A→B、A→B→A 和写入成功/失败，核对最终表名、页面内容和 Loading。延后刷新属于新的导航请求，不让旧提交的结果直接覆盖目标页。

SQL 的在途执行按连接 ID 和查询标签 ID 独立记录，不能从当前可见标签的 `isRunning` 推断后台是否结束。切换连接仅清除呈现结果，保留运行状态；执行函数在真实 Provider 返回或准备阶段退出后统一释放锁，并同步可见标签和保存的标签状态。模块忙闲判断检查全部连接的在途 SQL，返回 A 后重复 Run 必须被拒绝。代次检查仍丢弃迟到结果、停止批次的后续语句，不承诺撤销已发送的写入；关闭标签或强制模块释放也不能伪造后台请求已结束。`sqlExecutionLockSurvivesConnectionNavigation` 用有界 TestGate 覆盖写入/查询、成功/失败，以及完成前/后返回 A，核对只发送一次请求、后台占用与最终解锁。

显式分页、筛选、排序和刷新由模型在接纳结果时清理所属草稿，连接代次、表名和页面请求 ID 必须仍匹配；视图只在发起操作时清理局部选择与焦点。不要在视图的 await 后无条件调用 discard：A 的分页尚未完成时切到 B 并编辑，旧回调会误删 B 的共享草稿。`delayedPageOnlyClearsItsOwnCurrentDrafts` 以有界 TestGate 覆盖成功/失败、切表、切连接和被更新分页替代的时序。

不采用每张表独立标签、每个标签复制一个模块或永久缓存完整结果集：它们分别带来
重复导航、重复资源生命周期和额外内存占用。代价是返回连接时会重新加载表，
同表重选也可能移除原过滤/排序并改变行索引。`reloadTable` 与 `loadPage` 一样，必须先核对连接代次、表名和请求 ID，再在接纳新页面或清空失败页面时同步废弃旧草稿；不能把旧行索引草稿映射到新 `sourceRows` 的主键。`reselectingFilteredTableDiscardsDraftsBeforeReplacingKeys` 覆盖过滤/排序、同表重选成功/失败以及后续 Apply 不发送旧草稿。

SQL 的持久历史、执行事件和审计属于原连接的实际操作，必须独立于当前 UI 的代次检查。已发送语句即使在切换连接后结束，也记录成功或失败与已知影响行数；仅当前标签结果回填、可见语句装饰及表刷新受代次保护。导航使批次剩余语句不再发送时，用既有 cancelled 状态记录“已完成 N / 总 M”，保留先前副作用，不伪装成整批成功或已回滚。`sqlExecutionLockSurvivesConnectionNavigation` 从持久存储重读 History、Execution Events 和 Audit，覆盖后台完成与批次部分执行。

未提交的数据单元格编辑、新增行、删除标记及提交失败状态由现有 DatabaseFeatureModel 持有；Data、Console、Overview 和文件之间切换不随视图销毁清空草稿。更换连接或表仍清理所属草稿，避免应用到另一张表。存在待提交修改时，后台表列表刷新保留原始行与主键快照，不能让基于行位置的草稿错位；明确刷新在接纳当前请求结果时清理草稿，撤销立即清理，成功提交再重新加载行。

工具栏分隔线参考 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`ActionToolbarImpl.kt` / `MySeparator`、`JBUI.CurrentTheme.Toolbar.SEPARATOR_COLOR`
及 `ManyIslands{Dark,Light}.theme.json`：`ToolBar.separatorColor` 解析到
`toolbar-border` / `core-border-transparent`，深色 `#FFFFFF21`、浅色 `#00000020`。
共享 `LitheTheme.ActionToolbar.separator` 持有这个独立颜色，不改通用面板分隔线；
分隔项保留 7pt 槽位与 1pt 线，删除数据工具栏使用通用 divider 的做法。
Structure 图标使用同版 `platform/icons/src/expui/toolwindows/structure{,_dark}.svg`，
Data/SQL/History 复用已经导入的 table/shell/history 资源，不新增数据库功能。

数据库停靠入口使用 IDEA `IU-262.9437.185` 的 `DatabaseIconMappings.json` 所指定的 `icons/expui/dbms@20x20{,_dark}.svg` 描边圆柱；本机发行包 `intellij.database.jar` 中两份 SVG 均明确标注 Apache-2.0 授权，保留原始字节及 NOTICE 来源，不将其误称为 Community 资源。删除此前误用的调试器数据库对象图标。Maven 按 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `MavenIconMappings.json` 使用 `images/expui/toolwindow/maven@20x20{,_dark}.svg`，不放大旧 16pt 图标；Maven 面板标题移除左侧图标，保留标题及项目副标题。两处继续使用共享停靠按钮尺寸和模板配色。
数据库连接树复用共享 litheTreeRow/Tree 的 24pt 行高、13pt 常规文字、16pt 图标与 19pt 层级缩进；展开箭头使用现有 IDEA SVG，移除连接颜色竖线、对象数胶囊和空表卡片，避免数据库单独定义一套树样式。连接品牌、状态、只读和保护语义保留；按用户要求，连接行删除只读锁图标，只显示保存的连接名称，不追加数据库类型。演示名称中人为添加的类型后缀仅在仓库外临时数据中清理，不对真实连接名称做自动裁剪。成功/失败状态显示在品牌图标右下角（绿/红点），未连接不加点，连接中保留进度提示，删除行尾重复类型与状态符号。Provider 改用 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `platform/icons/src/providers` 原始 16×16 SVG 及可用明暗变体，Nacos 保持现有资源；删除对应 DBX 大画布资源，避免图形实际占用过小。共享品牌图标缓存区分主题。状态点依据同版 `platform/icons/src/modifiers/dot.svg` 的 5pt 直径，按用户要求对现有主题语义色轻微提高饱和度，不修改全局配色。树容器使用共享左右 12pt、上下 4pt 留白；文件夹和连接行只追加层级缩进，删除首层额外的 7pt/4pt 留白，避免与容器内边距叠加；连接和表的选择色由共享活动区域观察器及窗口 key 状态共同决定，获得焦点时使用主题蓝色，点击树外或切换窗口后恢复非活动灰色，避免选择状态与焦点状态混淆。
数据库 Data/SQL/Structure/History 导航使用共享工具栏图标按钮，删除原文字页签和原生分段按钮；数据空状态复用 LitheUnavailableView，删除蓝色装饰卡片。模块协调器在激活时观察操作错误并交给现有全局通知入口，重复激活不重复注册；休眠由能力 store 取消观察，侧栏隐藏不影响错误通知。连接树不调用手形光标修饰器，保留默认箭头。
四个工作区页面删除独立查询/表页签底色和下划线、工具栏组合框与 WHERE/ORDER BY 装饰边框、History/Structure 原生 inset List；复用共享页签、标题分隔线、滚动条、按钮尺寸与常规字体。SQL 编辑器保留原生编辑/选择/补全，但字体和颜色来自 LitheTheme。概览 Quick Start 和 Recent SQL 与 Common Actions 一致，在内容及内边距上绘制共享圆角 hover，外留白在 hover 外布局，状态和时间继续右对齐，禁用动作不绘制 hover。参考 Community c7f91397daa3a961b4e78bc634fe467a0a7d9ade 的 platform/platform-impl/src/com/intellij/openapi/wm/impl/content/ContentTabLabel.java 与 platform/platform-impl/src/com/intellij/openapi/actionSystem/ex/ActionButtonLook.java，沿用已有共享 owner，不复制上游未实现的功能。
数据库工具栏中的搜索、筛选和排序直接复用 `litheToolbarIconButton` / `LitheIconButtonStyle`：
16pt 原始图标放入 22pt 点击区域，不用 SF Symbols 字重模拟，也不在筛选/排序外层
再画边框。搜索默认仅显示图标，点击后仅展开共享输入，点击输入框后才聚焦；关闭搜索时清空查询，
避免隐藏筛选条件。工具栏图标的用途提示复用 `workbenchHoverHelp` 和面板局部 `workbenchHoverTooltipScope`，包括禁用动作，不依赖原生 `.help` 的延迟提示。筛选和排序固定在工具栏右侧，左侧动作可横向滚动。空状态仅保留 13pt 常规灰色提示，不显示大图标、说明段落或重复的新建按钮；添加连接沿用工具栏加号。提示脱离连接树滚动内容，按 IDEA Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `platform/platform-api/src/com/intellij/util/ui/StatusText.java` 在内容区横向居中、纵向约三分之一处显示，颜色沿 `SimpleTextAttributes.GRAYED_ATTRIBUTES` → `NamedColorUtil.getInactiveTextColor()` 对应 `Component.infoForeground`，复用已有 `LitheTheme.searchFieldPlaceholder` 同源 token。
连接新建/编辑、文件夹和 DBX 导入复用 `LitheCenteredPopup` 原生居中标题框，
输入框和确认/取消按钮复用 `LitheCommitDialogInputStyle` / `LitheCommitDialogButtonStyle`。
连接和文件夹表单使用无分组背景的滚动容器，保留展开后的滚动空间；共享输入
固定为 28pt 居中，并复用搜索输入的 I-beam 悬停处理，密码字段同样适用。
连接表单用原生 `Grid` 统一标签列和输入列；Host/Port 同行，开关和提示文字
跟随输入列。窗口按常规、SQLite、Nacos 和展开状态收缩/扩展高度，保留滚动。
这里只复用 IDEA 的表单排版规则，不引入驱动管理、认证类型等新业务控件。
弹窗继承模块环境与语言；DBX 关闭由显式绑定驱动并清空导入数据，保留连接验证、
凭据存储和原生文件选择流程，不修改共享弹窗本身。
图标来自 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/icons/src/expui`；`PlatformIconMappings.json` 提供 NewFolder、Console
映射，`ActionButton.java` 的图标/按钮尺寸分离方式与现有共享样式一致。新增原始
明暗资源记录在 `macos/Resources/IDEAIcons/NOTICE.txt`；这些是通用开源图标，
不是专有数据库插件的动作资源。安装时作为静态资源打包，运行时只读，不生成缓存。

验证由 `WorkbenchModuleUIRegistryTests` 和 `DatabaseWorkspaceLifecycleTests`
覆盖停靠位置、重复打开、独立关闭与模块释放，完整工作台仍须实机核对。

### 插件宿主边界

插件只能通过 `PluginHostContext` 按稳定 ID 获取宿主提供的窄协议，不得
导入应用 executable target，也不得自行构造 macOS adapter。插件的
manifest 负责声明模块、依赖、能力、语言支持和入口；运行时负责生命周期，
平台层负责进程、文件、PTY、密钥链和原生 UI 等具体能力。

### 内部功能与插件市场的界线

插件市场只管理用户可以单独启用、关闭，并由插件运行时停止其资源的功能。
静态外观资源和应用自身的工作区能力不因代码曾经使用插件 manifest 就继续显示为插件。

macOS 的 Database 是内部工作区模块，默认可用，但仍按需构造并在空闲后休眠；
旧版在插件市场留下的禁用状态会在组合根迁移，避免数据库工作区永久不可用。
Windows 的预装图标和配色由外观设置持有。图标目录只加载当前选中的主题，
不向扩展注册表登记四个伪扩展；SQLite 是应用内部的数据库能力，也不生成市场卡片。

真正需要独立生命周期的官方插件放在 `Plugins/mac/` 或 `Plugins/win/` 的平台目录。
例如语言插件关闭后要释放语言服务器和监听器，因此应保留插件身份；
图标主题切换只替换静态资源，不需要通过插件启停来实现。

语言服务器、语言包和 Rust LSP runtime 的具体归属遵循
[`语言工具分层与 LSP Runtime 归属`](2026-09-13-language-tooling-and-lsp-runtime-ownership.md)；
本 Note 只约束它们作为模块接入运行时的边界。

## 考虑过的备选方案

### 在 `AppModel` 或 `AppServices` 中直接持有全部功能实例

这样调用路径较短，但禁用和按需激活无法从构造阶段保证，功能资源也会
逃离统一的停止和休眠流程。模块运行时改为持有 factory、实例和资源 scope，
应用侧只持有组合入口和能力协调器。

### 应用启动时 eager 构造所有模块

实现最直接，但会启动用户未使用的后台资源，无法满足禁用模块零资源、
按需激活和故障隔离要求，因此只有 manifest 明确声明 `eager` 的必要模块
才在启动阶段激活。

### 每个模块都做成独立进程

可以隔离崩溃，但会引入跨进程协议、启动成本和状态同步复杂度，当前模块
API 也没有以此为前提。Lithe 先采用同进程模块边界和可恢复启动标记；只有
安全或稳定性要求明确达到进程隔离级别时，才重新评估此方向。

### 让模块直接导入其他模块的实现

局部接入更快，但会形成隐式依赖和能力提供者竞争，导致模块无法独立禁用、
休眠或替换。跨模块交互统一经过能力、不可变事件和声明式贡献。

## 后果

- 模块是否被构造、是否拥有资源、是否可以休眠和是否能恢复，都有单一的
  运行时归属，测试可以直接验证 factory、lease、resource 和 state。
- 工作台可以显示模块快照和静态贡献，而不必为了展示入口提前启动模块。
- 插件 manifest 校验在注册模块前完成，插件故障不会阻止必要的应用壳启动。
- 代价是 `ModuleRuntime`、`ModuleRegistry` 和各模块的 manifest 必须保持
  一致，模块不能通过快捷的具体 service 引用绕过这层边界。
- 这套设计只提供同进程恢复，不提供第三方代码的运行时崩溃隔离；如果未来
  引入真正的跨进程插件，必须重新定义 `ModuleContext` 和能力传输协议。

本轮查询呈现继续使用 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：历史窗口参考 `ConsoleHistoryController.BrowseAction` 与 `ContentChooser`，标题包含连接名，原生标题与 Output 格式文本沿 DatabaseLocalization 解析应用语言，左右分栏比例 0.3、编辑器只读、Close/Paste 复用已有居中弹窗和按钮。Paste 替换当前查询选区，Cancel/Escape 不修改查询；失败执行也进入历史。结果呈现按 JetBrains 官方 Query results 文档放在 Services，当前批次每个结果集独立页签，Output 使用已有 OutputTextView（13pt 配置），SQL 片段复用同一 SQLSyntaxHighlighter；引用标识符保留普通文字色，字符串含前缀、转义与美元引用保持完整，数字含小数与指数取 DEFAULT_NUMBER，注释使用 DEFAULT_LINE_COMMENT 深/浅 #7A7E85/#8C8C8C。参考图要求的 SQL 运算符（含 *）复用已核实 DEFAULT_KEYWORD 色；同版 Community 没有公开 SQL_OPERATOR 的插件专用覆盖，不能将这个 Lithe 映射称为已核实的插件实现。保留共享日志滚动、复制和软换行；包含真实 SQL、时间戳、单条耗时、行数与错误，不伪造 sidecar 未提供的执行/取数分段时间。

语句执行记录仅驻留 console 运行时，最多保留 100 条小日志；新批次释放旧结果页，当前批次结果仍受已有 10,000 行上限约束。清空 Output 仅推进日志可见起点，不删除结果页或语句标记。范围定位复用已有 SQLAnalyzer 拆句后在原稿中依次匹配，选区使用原生 UTF-16 范围；重复 SQL、引号内分号与 Unicode 不猜位置。编辑时按单个 UTF-16 修改范围移动未改语句的装饰位置，编辑语句本身或将字符粘连到其边界时移除旧状态；这同时保护执行完成后与请求在途两条路径。Rendering sourceSQL/sourceRange 随编辑移动，实际执行的 sql、时间与 Output 不变；不创建第二套 SQL 解析器，也不在后端缺少错误位置时假造词级诊断。

语句框使用 Islands Dark 的 `CONSOLE_RANGE_TO_EXECUTE.EFFECT_COLOR` #3D7A49 和 Community `EffectType.BOXED`；`EditorPainter.paintBorderEffect` 的 BOXED margin 为 0，AppKit 的居中 1pt 描边在左裁剪边缘向内对齐半点，避免首列语句的左边框消失，不改文字与行号布局。原生像素回归检查首列左描边的实际绿色，用同窗 NSBox 色块校准 HDR 颜色映射，同时独立核对 #3D7A49 色值，不放宽像素色差。执行前格式化后，末尾光标和结束于末尾的选区跟随新 EOF，避免历史粘贴落入旧的字符位置；浅色未找到同版明确覆盖，Lithe 暂沿用已核实绿色，不声称与专有 SQL 插件逐像素一致。耗时取 `INLAY_TEXT_WITHOUT_BACKGROUND` 深/浅 #727782/#7A7A7A，成功/失败 gutter 使用原始 greenCheckmark/error 16pt SVG。底部错误条取 `EditorNotificationPanel.Status.Error` 到 Islands `Banner` 的映射，并沿 Darcula 父主题 `Editor.Notification.WithoutStatus.borderInsets.compact` 使用垂直 6pt、水平 16pt：深/浅背景 #56272B/#FFF6F5，边框 #80383E/#FFC4C5；关闭只隐藏提示，保留 Output 中的错误。

查询按用户确认使用 SQL 子句格式化换行，复用 DatabaseSQLFormatter，在执行前处理整条查询；有可信原生选区时只替换所选片段并保留边缘空白，没有范围的字符串选区不猜替换位置。输入期间不重排，保留输入法与原生编辑；默认关闭视口软换行，Output 的软换行开关独立。SQL 查询版式按官方 Code Style 文档的 SELECT elements/New line、保留 Word Case 与默认 4 空格缩进设置实现：`select * from t;` 输出 `select` 与缩进的 `* from t;` 两行，FROM 保留在投影末行；这对应用户参考图，不宣称是所有 IDEA 配置的默认值。同版 Community plugins 树没有公开 SQL 格式化器。现有格式化器只处理顶层常见子句，保留复合运算符、小数、引用、嵌套注释及字面量前缀，美元引用脚本原样保留；不宣称完整方言语法格式化，Provider 提供成熟格式化入口后替换这段有限规则。Community EditorSettingsExternalizable 的主编辑器默认开启软换行，但文件掩码默认只列 md/txt/rst/adoc；截图中 SELECT 和 FROM 的物理换行并不是这条软换行规则，不宣称 Community 提供公开的完整 SQL 格式化实现。历史只读预览在共享行号栏中不保留执行标记区域，宽度按既有数字右边界加分隔线留白计算。语句轮廓排除换行符的视口宽度 advance，并沿同版 EditorPainter.paintBorderEffect 的多行 BOXED 绘制：首行与中间行沿最大文本宽度，最后一行在其起点高度收窄到实际终点，底边仅覆盖最后一行；不能把所有行 union 后画一个矩形。保留 1pt 描边与零外扩，范围包含的空行不改 SQL。原生检查覆盖缩放后的空白命中、逻辑行号、Unicode 选区、语句框与明暗主题；Services 与历史窗口的实际应用验收单独记录。

SQL 执行状态栏沿同版 `EditorMarkupModelImpl` 的共享几何：右侧 14pt 标记区加 2pt+2pt 留白，最小高度 2pt；短文档不拉伸，长文档按可见轨道压缩，标记对应语句末尾所在位置，点击回到语句起点。成功/失败行号标记使用已有 16pt greenCheckmark/error 原始 SVG，最新同范围执行覆盖旧状态；不同失败与成功压缩到同处时错误优先。成功条复用该 SVG 的深/浅 #57965C/#369650，错误条取 ERRORS_ATTRIBUTES.ERROR_STRIPE_COLOR 深/浅 #D64D5B/#CF5B56；Community 未公开数据库插件的专用成功条映射，不能将该适配称为逐像素复刻。透明状态覆盖层独立 layer 合成，hitTest 将父视图坐标转换到本地后判定标记；与既有 CompactScroller 共用右侧区域，滚动条拖动命中优先，不引入第二套滚动或事件观察器。

共享 OutputTextView 的 Copy 按钮使用已有 litheToolbarIconButton 的 22pt 高度、共享圆角及启用/hover/按下反馈，默认透明且无独立边框；删除 Capsule、常驻 raised 底色、手形光标和重复禁用透明度，复用原始 copy.svg，保留纯文本复制动作。Copy 现在由 OutputCopyButtonHost（原生 NSHostingView）作为滚动视图内不随正文滚动的真实前景子视图承载，内部仍使用同一个 SwiftUI 共享按钮。仅设置 hover、pointerStyle 或增加 hitTest 返回 nil 的布局锚点不足以取得原生光标所有权；后者让事件继续落到 NSTextView。OutputNativeScrollView 优先命中按钮宿主，宿主注册箭头与移动事件；OutputNativeTextView 排除宿主范围的所有光标矩形，并保护落在按钮上的旧 cursorUpdate、mouseMoved、mouseEntered 事件。按共享按钮实际 fittingSize 定位，窗口布局后失效旧文本光标矩形，不增加全局鼠标监听。不修改输出正文的文本选择光标。这同时应用于 Run、Debug、测试、Maven 与 SQL 输出消费者，不修改其他悬浮动作。

## 验证

- `./scripts/verify-agent-notes.sh`
- `./scripts/verify-module-boundaries.sh`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/test-macos.sh`
- `macos/Tests/LitheApplicationKernelTests/ModuleRuntimeTests.swift`
- `macos/Tests/LitheTests/DatabaseWorkspaceLifecycleTests.swift`

这些检查覆盖禁用模块不调用 factory、依赖顺序、能力冲突、lease 阻塞
休眠、资源回收、唤醒重建、关闭清理、贡献目录、Safe Mode、隔离恢复和
内置 manifest 漂移。

## 适用范围

- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheApplicationKernel/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/LitheApplicationKernel/Registry/ModuleRegistry.swift`
- `macos/Sources/Lithe/`
- `macos/Sources/Lithe*Module/`
- `Plugins/mac/Official/`
- `macos/Tests/LitheApplicationKernelTests/`
- `scripts/verify-module-boundaries.sh`

Redis Key Browser 的标题栏、DB 标识、SCAN 搜索/刷新与空状态接入现有共享控件；移除红色图标底板、胶囊及局部错误条，错误统一由已有协调器通知，不重复显示。Estimate size 是布尔选项，沿用 Community `c7f91397` 的 `DarculaCheckBoxUI` 复选框语义，macOS 复用原生常规 checkbox 而非另写 Java 绘制器；刷新/搜索沿用同版原始 SVG 和共享 22pt 工具栏按钮。空浏览区填充可用高度，搜索保持顶部，避免空状态固有高度把整列垂直居中。此调整仅覆盖 Redis 截图指定区域，Nacos 和 Redis 有值编辑表单保持现有实现。

工具栏置于 WHERE/ORDER BY 分栏上方，删除无动作的 All rows 胶囊；行号列替代复选框外观，原点击选行及 # 全选保留。单元格以原生焦点确定选中位置，以共享活动区域及 key-window 状态选择蓝/灰底色，切换表清理焦点，数字右对齐。树节点与表头 schema/objectGroup/table/column 的原始 16pt SVG 来自本机 IDEA IU-262.9437.185 的 DatabaseTools `lib/modules/intellij.database.jar`，每个资源明确 Apache-2.0 授权；它们不是 Community 来源，保留版权与 NOTICE，不复制数据库插件实现。

Data 表格的实际基准为 Community c7f91397 的 `grid/impl`，不是通用 JBTable：GridColorSchemeUtil 读取编辑器 INDENT_GUIDE/SELECTION_BACKGROUND；SelectionColorLayer 经 DataGridUIUtil.softHighlightOf 对表头背景每个 RGB 通道加/减 16。删除原 toolHeader/toolWindowBorder 作为数据网格颜色的用法，专用共享 DatabaseGrid token 不改变侧栏与其他工具窗口。CellRenderingUtils 表头左内边距 4pt、DefaultTextRendererFactory 单元格左右 3pt，TableResultView 行高按字体行高乘共享编辑器行距后加 1pt 行间隔和 4pt 留白；排序使用 getSortOrderIcon 指向的原始 arrowSplitCenterV/arrowUp/arrowDown。筛选保留既有弹出动作，删除整块列表悬停背景，不增加截图中 Lithe 尚未实现的数据库功能。

行号列对照同 revision 的 `grid/impl/src/run/ui/table/TableResultRowHeader.java`：文字由表格的 PLAIN 字体绘制并居中，Lithe 使用与数据相同的 13pt JetBrains Mono Regular，避免继承普通按钮字重。按用户参考启用 `SelectionColorLayer` 的透明行号栏规则：普通行号没有独立表头底板，取编辑器 LINE_NUMBERS_COLOR（Islands Dark #4B5059、Light.xml #ADADAD）；当前行号取 LINE_NUMBER_ON_CARET_ROW_COLOR（深色 #A1A3AB，浅色该 token 未定义，按源码回退到 LINE_NUMBERS_COLOR）。当前行和当前列标题都取 GRID_CURRENT_ROW / CARET_ROW_COLOR（深/浅 #1F2024/#FCFAED）；当前行未选中单元格显示行背景，真正选中单元格仍覆盖蓝/灰选中色，已有变更色仍通过 softHighlightOf 保留。行号背景透明与边线是否显示是两件事。GridRowHeader.paintComponent 在横线启用时按 rowMargin 和 table.getGridColor() 画横线；TableResultRowHeader.MyRowHeaderCellRenderer 用 CustomLineBorder 保留朝向数据区的 1 个逻辑像素竖线。Lithe 因此让 1pt 表头底线和行底线贯穿序号列，并为序号列补回单侧右边线，取同一 INDENT_GUIDE_COLOR 深/浅 #323438/#E6E6E6，不增加单元格间距或背景底板。行号选择、# 全选、删除禁用和右键动作不变；相同规则覆盖已有行与新增草稿行。

Data 网格全选之后，已有行和新增行的普通单元格点击都必须清除 selectedRows，再设置单元格焦点；否则全行背景层仍覆盖原选择，使逐个点击看起来没有效果。行号点击继续切换单行，# 继续全选/取消全选。只读连接继续禁止进入编辑；演示可编辑设置须作用于用户实际运行实例的同一条临时 SQLite 连接，不能只改变独立预览偏好。Tables/Collections 是可展开的分类节点，标题使用共享 Tree.text，数量使用 Tree.secondaryText，避免普通可点击文字被画成禁用样式。验证覆盖全选→逐行取消→单元格单选及编辑，并核对取消草稿不写入演示库。

新增行与已有行必须在同一个 ForEach 中使用全表唯一行号，避免 LazyVStack 合并两个从 0 开始的标识后遗漏草稿行。对照同 revision 的 AddRowAction / GridUtil.newInsertOrCloneRowRequestSource，新增后滚动到末行并选中第一个单元格；单击只选中、双击再出现无框编辑器。行号延续已有数据，待提交整行复用 MutationsColorLayer → CellColors.INSERT → TableDiffColors.TDIFF_INSERTED 对应的共享 Diff.inserted 配色；空值取 GRID_NULL_VALUE 的 DEFAULT_LINE_COMMENT 色。尚未填写的列仍从插入字典中省略以保留数据库默认值，显式 Set NULL 才发送 null。提交使用 Community AllIcons.Actions.Upload 原始 SVG，撤销使用 intellij.grid.impl.xml 的 RevertSelected 所指定的 General.Reset；不仿造 Community 中未提供的数据库专用提交动作图标。新增在加载、无列和只读状态禁用；提交失败保留草稿，成功刷新后才清理。新增/连续新增/撤销在外部演示库中通过原生预览核对；DatabaseGridClickTests 继续保护共享单元格的即时点击回调，DatabaseToolbarAppearanceTests 核对新增的原始资源。

筛选/排序弹出区域复用 LitheCommitDialogButtonStyle/InputStyle 与 LitheSettingsSegmentedControl，保留条件和查询动作。列宽移除等分视口策略，参考同版 DefaultGridColumnLayout 的内容测量、40pt 下限、黄金分割 preferred 上限；按用户要求分配面板剩余空间，不使用 full×1.2 上限；当前只采样前 100 条已加载数据，不支持冻结列/持久化拖动宽度。单击聚焦普通文本单元格，双击可写连接进入原 TextField 草稿编辑，失焦退出编辑；只读连接始终只显示文本，保留原行选择与菜单。

数据库表头根据已有 primaryKeyColumns 元数据选择主键列图标，普通列保留 column.svg；主键列使用同版 IDEA DatabaseTools 明确 Apache-2.0 授权的 columnGoldKey.svg 原始 16pt 明暗变体，不拼接或重绘钥匙，也不把所有名为 id 的字段推定为主键。

SQLite PRAGMA 的列声明类型可能为 NULL，实际返回值却是整数；sidecar 的共享 row_json 必须按 ValueRef 的实际类型解码，避免 pk/cid/notnull 被降为 unsupported。这同时影响主键图标和主键编辑约束，修复在共享解码处，不在 UI 按字段名猜主键。

按用户要求，数据网格列少时也铺满当前面板：仍测量内容并按内容比例分配空余宽度，但不再保留 Community DefaultGridColumnLayout 的 full×1.2 上限；宽列总量超过面板时仍横向滚动。单击单元格保留整格选中色和键盘焦点，复用 Git Log 已有的 macOS 14+ 隐藏系统焦点效果入口，提取到共享 Theme；不再在文字周围重复画系统焦点框，macOS 13 保留兼容行为。

数据表删除独立路径/属性工具栏，保留单行共享 30pt 工具栏和 16pt 原始 SVG、22pt 按钮，参考 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 ActionButton/ActionButtonLook 与既有工具窗口共享基线。刷新和编辑动作在左，TSV/分页固定在右；跳转列、行详情及原导入/导出/批量操作收进 Data Tools，删除仅供旧工具栏使用的标签绘制函数，数据库顶层标签显示数据库名，内层表标签已删除。没有增加 IDEA 专有动作。

工具栏禁用反馈由共享 `LitheIconButtonStyle` 读取环境中的 `isEnabled`，覆盖直接禁用、父组禁用和 helper 参数三条入口，避免每个调用者补透明度或重复变暗。沿 Community 同 revision 的 `platform/platform-impl/src/com/intellij/openapi/actionSystem/impl/ActionButton.java` 的 `getIcon`/`getPopState` 核对禁用图标及只有可用按钮进入 hover 的语义；保留原始 SVG，macOS 使用共享透明度降低原始灰色图标的亮度，透明度沿用既有 0.45，不声称复刻 Java 的像素滤镜。TSV 触发器复用同一按钮样式，只让文字标签保留固有宽度，删除局部 row-hover；分页继续复用同一图标样式。

普通单元格的两个 SwiftUI TapGesture 会等待双击判定，不能承担即时选择。复用共享右键捕获视图的原生命中筛选模式，数据表局部 NSView 在左键 mouseDown 同步传递 clickCount：第一下选择，第二下可写连接编辑；Control-click/右键不截获，滚轮不命中，编辑中的 TextField 移除捕获层以保留原生插入点和输入。没有全局事件监视器或定时器，视图卸载即释放回调；保留原键盘焦点。DatabaseGridClickTests 在没有鼠标松开/定时器推进前断言首次回调，同时覆盖双击与菜单事件。

单元格编辑状态依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `grid/impl/src/run/ui/grid/editors/GridCellEditorTextField.java`、`platform/platform-impl/src/com/intellij/ide/ui/laf/darcula/DarculaUIUtil.java` 和同版 Islands 深浅主题：编辑器使用网格原背景，焦点边框是内侧 2pt 矩形，颜色由 `Component.focusColor → control-brand-border → blue-80` 解析为 #3871E1；不是文字外面的原生圆角输入框。已有行与新增草稿行共用 DatabaseGrid token，焦点边框不拦截输入和右键，失焦时移除。与上游 GridTableCellEditor 默认行为一致，单击立即显示整格选中色，双击可写单元格才进入编辑并显示矩形焦点边框；只读和已标记删除的行不进入编辑。点击行号或 # 结束当前编辑视图，保留已有草稿；取消仍通过 Discard，未提交不写数据库。原生深浅主题预览已核对单击没有原生字段、双击出现编辑器、全选后单击和新增草稿行；文本输入与撤销通过，未提交演示数据。本次 43 项 macOS 定向测试通过。

数据库变更背景继续沿 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `grid/impl/src/datagrid/color/MutationsColorLayer.java` → `GridUtil.getMutationCellAttributes` → `CellColors` → `TableDiffColors` 解析：修改复用 Diff.modified（Islands 深/浅 #385570/#C2D8F2），新增复用 Diff.inserted（#294436/#BEE6BE），删除复用 Diff.deleted（#484A4A/#D6D6D6），不再使用半透明警告黄或降低整行透明度。红色在该源码中来自提交失败覆盖：MessageType.ERROR → Notification.errorBackground → feedback-error-bg，Islands 深/浅为 #56272B/#FFF6F5；只对仍未提交的变更显示，撤销或成功提交清除；异步提交固定草稿快照，仅在同一连接/表且草稿未被取消或改写时更新本地状态，避免迟到结果改变新的草稿。与 SelectionColorLayer / DataGridUIUtil.softHighlightOf 一致，当前行或行高亮保留变更色并对深/浅 RGB 各增加/减少 0x10，通道钳制在 0…255 且保留透明度；取消整行选择后若当前单元格仍在该行，高亮色仍有依据。真正选中的单元格覆盖为网格选中色。普通、修改、新增、删除、失败状态均保留同一网格线。TableResultView 启用横/竖线时预留 1 个逻辑像素，GridColorSchemeUtil 使用 INDENT_GUIDE_COLOR（Islands 深/浅 #323438/#E6E6E6）；Lithe 用无额外间距的相邻行列和内侧 1pt 单边绘制，不叠加两条边框。DatabaseGridAppearanceTests 保护跨主题动态解析、通道钳制、未高亮颜色及透明度保留。

本轮原生预览在隔离 SQLite 演示库中覆盖修改蓝色、新增绿色、重复主键提交失败后的两种红色、全选再取消、删除标记和撤销；深浅主题均核对，失败事务前后 customers/orders 内容一致。捕获用于完整界面的视觉核对，不把带显示器 ICC 与有损压缩的屏幕图像当作精确色值或物理像素测量；色值与线宽依据固定版本的源码和专用 token，动态高亮算法由原生颜色解析测试保护。


Console 编辑区继续对照同版 Community 的 `LanguageConsoleImpl` 与 `FontPreferences`：前者复用标准 Editor，后者在 JetBrains Runtime 默认使用 JetBrains Mono、13pt、Regular 和 1.2 倍行距。Lithe 使用已有字体注册、实际字型及 `editorFontSize` 设置；浅色主题注释使用真实 Italic 字型，其他 SQL token 保持 Regular，配色沿 IslandsDark / IntelliJLight 继承链。高亮仅为现有轻量词法着色，不代替 SQL Provider、解析器或语义补全。字符串中的注释标记与关键字不再误着色。空白文档最小高度随原生滚动视口变化，整个可见编辑区由 NSTextView 接收输入并显示 I-beam，避免只有首个 240pt 可编辑；与 CodeTextView 一样显式建立 TextKit 1 对象图，避免 NSTextView 懒创建 TextKit 2 后被行号/当前行装饰切换而首次未绘制文字；当前行与行号颜色单独使用 DatabaseGrid token，普通代码编辑器不改变。

只读 SQL 结果复用 Data 的内容测量与面板剩余宽度分配、13pt 等宽字体、透明行号栏、1pt 单边网格线及当前行/列状态；选择与复制仍只读，不开放结果集写回。筛选/排序、结构编辑、批量修改/替换和行详情复用现有共享按钮、输入、选择器及全局居中弹窗。居中弹窗的取消回调显式关闭所属绑定，不能依赖只对 sheet 有效的 Environment.dismiss；Esc、标题关闭与取消不提交草稿。Redis/Nacos 的既有搜索、刷新、删除和输入继续复用共享控件，不新增动作。系统确认、警告和文件选择仍使用原生窗口；没有入口的诊断、结构比较和定时备份视图不因此新增入口。Community 不包含完整专有 Database Tools 控制台/表单实现；仅复用可核实的通用开源控件与配色，新增数据库 goldKey/blueKey/collection SVG 按既有明确 Apache-2.0 的 IU 资源来源保留 NOTICE，不复制插件实现。

原生回归覆盖明暗主题、空白视口与窗口扩大后的编辑命中范围、I-beam、真实字体/行距、文字修改回传和引号内注释标记；字体和 SVG 检查通过不等于各远端 Provider 均已完成服务集成验收。验证命令沿用 `test-stability-macos.sh` 的 Database、BundledUIFontTests、EditorGutterLayoutTests、ContextMenuCoverageTests 与 SettingsSelectPopupGeometryTests 定向组合；无可用 Redis/Nacos 等服务时必须报告运行验证边界。

Console gutter 的默认背景与编辑区一致，当前行高亮使用同一个 TextKit 行矩形覆盖整个行号宽度；空查询、末尾空行及滚动后保持连续，普通代码编辑器样式不变。查询结果列以位置区分，宽度字典允许重名，防止合法的重名结果列触发 Dictionary 断言；不改变既有 SQL Provider 或 JSON 行模型。

Console 指针行为继续对照同版 `EditorImpl.java` 的 `getDefaultCursor` / `validateMousePointer`：普通编辑区默认 TEXT_CURSOR。SQLTextView 在整个可见原生视口注册 tracking area，进入、移动和 cursorUpdate 直接设置 I-beam，离开恢复箭头，不把高频 hover 写入 SwiftUI 状态。当前窗口未聚焦时第一次点击可编辑区仍接收编辑动作。点击和拖选继续交给 NSTextView：其原生命中测试把最后一行下方的位置限制到 EOF，不创建额外行；首次点击允许直接聚焦，鼠标处理结束后恢复 I-beam。保留 Shift/修饰键、多击、拖选及输入法组词，不另写鼠标选择状态机。不能仅测试主动调用 cursorUpdate 就宣称 hover 已覆盖，必须核对 tracking area 和无焦点时的进入/移动/离开，以及缩放后空白区域的命中与输入。数据库选择保留共享菜单、当前库初始选中和实际切库动作，并向辅助功能暴露当前数据库值。


Console 的文字起点继续对照同一 Community revision 的 `EditorComponentImpl.java` / `view/EditorView.java`：绘制和坐标映射以内容区原点及其 insets 为准，不叠加 Lithe 普通代码编辑器的两层水平留白。Console 去除 NSTextView 的容器 inset 和行片段 padding，保留共享 gutter 自己绘制的分隔线；字体字形自身的侧边距仍由真实字体决定。`EditorGutterComponentImpl.java` 按行起点加编辑器统一 ascent（字体基线高度）绘制行号，而不会因为这一行没有字符就切换排版。Lithe 的末尾空行片段高度不含 1.2 倍段落行距，因此空查询、末尾空行及当前行装饰统一使用 Console 字体行高；有文字行继续读取 TextKit 的实际行矩形。明暗主题原生回归比较输入前后的行号区图像，覆盖首次输入和末尾空行，避免只断言字体配置却漏掉基线跳动。


Console 行号水平位置对照同版 `EditorGutterLayout.createNewUILayout`、`JBUI.CurrentTheme.Editor.Gutter` 和 `PlatformIconMappings.json`：Islands 及父主题未覆盖的空注释区和前置间距各为 4pt，New UI 的 breakpoint SVG 占位宽度为 14pt；行号以实际 Console 字体测量宽度右对齐。普通编辑器的最小 28pt 行号范围及 3pt 末端 padding 不再决定 Console 行号位置，避免单个数字离左边过远；多位行号仍按真实文字宽度扩展，字号和字体变化重新测量。只修改 Console 绘制位置，不改其他代码编辑器的标记、断点和折叠命中区域。

Console 单击切换当前行时，NSTextView 在 stillSelecting 为 true 的鼠标跟踪阶段暂不发送选区通知，因此只在 delegate 通知中刷新背景会晚于原生插入光标。与 CodeTextView 的原生选区入口一致，Console 在单个及多个选区设置后同步更新行号和当前行装饰，保留原生选择通知作为粘贴等内部选区变化的补充入口，共用同一方法，仅重绘旧、新两行；同一行矩形去重、行号栏弱引用，不新增闪烁计时器或鼠标选择状态机；设置选区之前捕获旧行实际矩形，避免粘贴/字体重排后使用过时位置而遗漏旧行。执行选区仍由原生完成选择通知回传，避免将鼠标高频跟踪写入 SwiftUI。明暗主题回归在 stillSelecting 为 true、尚未完成选择时断言当前行号与背景一致，覆盖两种原生选区入口，再结束选择并保留原有输入与空行基线检查。

Console 左侧细小间隔来自同版 `EditorGutterComponentImpl.getWhitespaceSeparatorOffset` 的 New UI 分隔线位置 `width - JBUI.scale(3)`，而不是文字容器 padding。分隔线右侧延续编辑器背景。Lithe 仅将 Console 的 1pt 分隔线从右边缘前 1pt 移至前 3pt，留下 2pt 背景区，文字布局原点仍为 0；字形自身留白不通过负 inset 抵消。普通编辑器分隔线保持原位置，明暗主题原生像素回归分别核对分隔线及右侧背景颜色。

数据库结构背景统一复用 `LitheTheme.editor` 的动态全局调色板，Data 和只读结果通过 `DatabaseGrid.background` 获取同一来源；Console 文本视图、滚动视口、容器及行号栏复用普通 CodeEditorView 的透明背景方式，由已有 SwiftUI 工作区表面绘制底色。避免 AppKit 底色与 SwiftUI 父面板在重绘、颜色转换或壁纸显示时形成两套背景层；当前行、文字选择和分隔线仍由原生视图绘制。此前给该 token 单独复制 Islands 的 #191A1C，使数据库内容与 Lithe 项目区使用的背景略有差异；页面重建或改工具栏不能通过覆盖全局 editor/sidebar 色值来补偿。背景相等回归覆盖所有 Lithe 配色和深浅外观，Console 检查原生背景层关闭，并在同一窗口比较最终合成像素与侧栏背景完全一致；表头、当前行、选择和变更背景仍保留各自语义。WHERE / ORDER BY 沿 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `GridEditorPanelBase.updateEditorPrefix`：空条件取 INLINE_PARAMETER_HINT.foreground，Islands Dark 为 #858A94，Islands Light 使用 Light.xml 并继承 Default 的 #7A7A7A；非空条件前缀取 KEYWORD（深/浅 #CF8E6D/#0033B3）。两种子句沿同一控件入口取色，其他按钮、提示、搜索占位色不改变。

Console 数据库选择器始终复用 `LitheMenu`、共享 22pt 工具栏按钮及原始 16pt schema/chevronDown SVG，避免非 MySQL 连接退化为不能点击的静态文字。按 Community 同版 `ActionButtonWithText` 的图标/文字/箭头 2pt 间隔及左右 4pt margin 排版，hover、按下、禁用及菜单外框仍由共享 owner 绘制。菜单初始选中当前库并显示真实库名，其他库按已有 Non-Introspected 分组；只列当前连接，不列其他保存的连接。SQLite 文件连接只显示当前库；MySQL/MariaDB 复用已有列库、刷新和切库入口，保留查询 ID、草稿和异步保护；不将 PostgreSQL sidecar 返回的 schema 名冒充可切换的数据库，也不为单库连接制造无效选项。验证当前库单项展开/关闭、MySQL 切库回归及运行查询时禁用。

本轮审查修复：执行边界格式化遇到反斜杠时保留整段原文，因为普通字符串与 E 字符串、MySQL 会话模式的转义规则不同，当前 formatter 没有足够上下文；Provider 方言格式化可替换此保守边界。Console 模型替换按 UTF-16 修改范围映射原生选区两端：整段格式化仅修改空白时线性扫描每处空白编辑，分别映射中间语句及 EOF，不用一个首尾包络把多条语句选在一起；非空白的普通模型替换暂用单个包络，后续不连续的 token 修改应使用 Provider 的编辑范围；切换 Console 同时清空选区文本和范围，历史窗口打开时固定目标范围，避免只读预览或切换标签改变 Paste 位置。表格提交锁记录所属连接 generation；切回仍在提交的连接时合并延后刷新，锁释放后仅补刷仍被选中的连接，原请求不会清理新页面草稿。

SQL History 列表与只读 SQL 预览之间的分隔条复用 LitheSplitPaneView 的 highlightsOnHover=false。该共享选项同时关闭 hover 和拖动亮色，保留常态分隔线、原生命中范围、调整光标和局部宽度更新；不修改其他面板的高亮策略。

SQL 格式化、语句拆分及关键词排除使用 Unicode scalar（Unicode 标量）作为词法分隔边界，避免引号和后面的组合音标合成一个 Swift Character 后漏认引号、改动字面量或拆开其中的分号。反斜杠与会话模式的保守边界保持原有处理。原生正文、Copy 宿主和 Console 共用从 CodeTextView 提取的实际命中检查，只在当前窗口命中自身或后代时处理指针；Copy 上的旧正文事件仍恢复箭头，指向其他控件的旧事件直接忽略。命中检查传入父视图坐标，覆盖翻转的 NSHostingView；Console 离开事件不再强制写箭头，避免覆盖分隔条刚设置的调整光标。
