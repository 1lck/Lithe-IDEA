# Agent 笔记：MySQL 连接下的多数据库树

状态：已实现

## 先说结论

macOS 数据库侧栏保留混合类型的分组文件夹，在每个 MySQL/MariaDB 连接下展示账号可见的数据库，并允许同时展开多个库。展开目录只加载目录，不切换编辑区；打开表、查询或执行右键动作时才选择该节点所属的数据库。各库的加载状态相互独立，不能再用当前编辑区的表列表绘制所有节点。

## 问题

原侧栏只绘制当前连接的当前数据库。切换连接或数据库时，旧库的表列表被清空，因此即使保留展开箭头也不能真正同时显示多个库。同名表的右键操作如果只携带连接编号，还会使用编辑区当前的库。

## 决策

数据库功能模型 `DatabaseFeatureModel` 为每个连接保存账号返回的数据库名称，并为每个数据库保存独立的表、对象、加载状态和请求编号。只在展开时读取该库的元数据，重复展开使用内存结果，刷新才重新获取；不预先扫描所有库，也不缓存表数据或密码。连接配置变更、删除、断开和模块释放都使相应请求失效，迟到结果不能恢复已清理的节点。数据库列表刷新后删除不再可见的缓存条目，失败保留其他数据库内容并提供重试。

文件夹、连接、数据库（含非 MySQL 的默认库）和 Tables 等对象分组统一采用名称单击选择、名称双击切换展开和收缩、箭头单击独立切换。分组原先每次单击都切换，双击会切换两次回到原状；数据库原先点击总是展开，无法双击收缩。因此不能只修连接层，必须沿各层容器的入口一起修正。单击数据库目录不切换编辑器，打开表或执行操作才选择实际数据库；单击当前连接也不重复刷新。未放入文件夹的连接直接显示在树根层，删除额外的“未分组连接”分区标题；原标题承载的根层拖放入口改为树尾空白落点，全部连接都已分组时也能拖回根层，原“移回根目录”菜单继续保留。

表行也区分选择、展开和打开：单击表名只选择，展开箭头先更新展开集合并显示加载动画，双击表名才打开数据编辑器。树展开只取列、索引、外键，不读第一页数据，也不切换活动数据库。每个“连接＋库＋表”保存结构缓存和唯一的后台请求；编辑器需要同一结构时复用该请求，折叠不取消其他消费者正在等待的加载，迟到结果不能重新展开节点。配置变更、断开、删除和模块释放会使请求失效；显式刷新清理已完成的结构缓存，导航则复用缓存。

刷新按钮以树的选中节点为范围：表节点只读取该表的列、索引和外键；库或对象分组刷新所属库已加载的结构；连接刷新可见数据库名称和已加载的库、表结构，不重新查询表格记录，也不切换编辑器。连接右键的 Diagnostics → Force Refresh 先清除该连接的结构缓存和旧请求，再重新读取先前已加载的范围；不扫描所有可见库。普通刷新保留旧内容直至结果返回，移除已删除库、表的缓存。当前接口没有结构版本差异，因此不宣称实现 IDEA 的增量检测。

数据编辑区和结构页未选择表时复用 `LitheToolWindowStatusText`，只显示操作提示，删除大图标与重复标题。依据 JetBrains 官方 [Empty State](https://plugins.jetbrains.com/docs/intellij/empty-state.html) 的详情区说明及既有 Community StatusText 共享样式；不把专有数据库插件的界面猜作源码基线。

同步的钥匙串读取和数据库元数据请求都放在后台，先向界面发布 loading 状态。展开后的加载提示使用现有 `ProgressView` 与树行 token；单个表失败在原节点显示 Retry，不覆盖另一张表的数据编辑器错误。

这种拆分依据 Community `platform/ui.tree/src/com/intellij/ui/tree/AsyncTreeModel.java`：`promiseChildren` 先使用缓存，没有缓存时放置 `LoadingNode`，后台读取后再更新界面，并用节点队列和过期检查保护结果。官方表编辑器说明将双击表名定义为打开数据编辑器；通用 `LoadingNodeRenderer` 提供加载文字占位，Lithe 按产品需求使用已有加载动画，并不复制专有数据库插件实现。

节点操作必须先通过 `selectDatabaseContext` 选择节点所属的数据库，再进入已有编辑区、导入导出和危险操作确认流程。例如 alpha/shared 与 beta/shared 是不同节点：点击 beta/shared 后的查询、导出或删除必须使用 beta，不能继续使用 alpha。展开 beta 的箭头则不应改变当前查询目标。

布局、行高、缩进、图标尺寸、明暗主题、悬停与活动/非活动选中状态复用 `LitheTheme.Tree`、`litheTreeRow`、`LitheIDEAIcon`，右键菜单复用 `litheContextMenu`。不增加独立颜色或另一套树组件。树的单选节点由侧栏独立保存，不能从活动连接、活动数据库和活动表分别推导高亮；点击数据库或表后，其祖先连接不得同时高亮。展开连接和数据库的箭头只改变展开状态。

交互依据是 JetBrains 官方 [数据源分组说明](https://www.jetbrains.com/help/idea/managing-data-sources.html) 和 [数据库工具窗口说明](https://www.jetbrains.com/help/idea/database-tool-window.html)。通用树行为核对 Community revision `d8c6714c7a3c110c56994d6b0f10814f902100e7` 的 `platform/platform-impl/src/com/intellij/ide/ui/laf/darcula/ui/DarculaTreeUI.java` 与 `platform/util/ui/src/com/intellij/util/ui/tree/WideSelectionTreeUI.java`；后者处理整行选中及展开控制的选中/焦点状态。数据库插件的专有实现不作为可复制源码；外观继续采用仓库已经批准的共享树 token 和已有 SVG。

连接和文件夹的右键使用 Move → To Folder… / To Top Level。Move 用于组织连接配置与分组，不能对 MySQL 实体库执行本地分组移动。没有分组时 To Folder 直接打开名称输入；已有分组时展示目标路径列表，也可新建后移入。名称支持 `/` 嵌套，已有中间层复用，末级重名、空路径段、过期目标及文件夹自身/后代循环均在功能模型拒绝；失败不发布半成品目录。创建后移动连接时，存储先完成两份 JSON 编码，再写原有组织配置键，不改凭据键。

新建与重命名分组共用项目区的 `LitheNamePopup`：从现有新建文件/目录内容提取，保留无标题栏、plain 名称框、Enter 提交和 Esc 取消，不新增独立表单样式。目的地列表通过 `LitheDropdownPopover` 的居中菜单入口复用 `LitheContextMenuPresenter`，包含原有键盘导航、选中、滚动和屏幕边界处理；路径仅用于本地组织，不发送给数据库服务。

连接旁的 `N of M` 是已选可见库数与账号可访问库总数，不是展开数、序号或已加载元数据数。计数必须原样显示，不能使用全局 `%lld of %lld` 本地化键；该键在中文中表示“第几个，共几个”，语义不同。2026-10-23 直接核对本机 IDEA 2026.2.1（262.9437.185）后，选择器改为无标题、无 Apply/Cancel 的复选列表，底部提示按 Enter 或点击列表外应用；Esc 丢弃草稿。搜索在输入时出现，继续使用原生输入法和共享弹层焦点路由。范围提交仍由功能模型验证，不在页面另存状态。官方语义见[数据库选择说明](https://www.jetbrains.com/help/idea/introspection.html#select-schemas-and-databases-for-introspection)。

徽标绘制依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `platform/platform-api/src/com/intellij/ui/SimpleColoredComponent.java`（`drawClickableFrag`）以及同 revision 的 `UIUtil.java`、`ManyIslandsDark/Light.theme.json`：24pt 行内上下内缩 2pt、左右内缩 1pt，圆角直径 6pt，普通描边，悬停且非活动选中行时填充；small 字号为 max(普通字号−2, 11)。颜色复用已存在的 `toolbarHoverBackground`，其深浅值分别为白色 23/255 和黑色 18/255，文字使用共享 Tree 次要文字。连接名称后保留 en space 的间隔。徽标显式使用共享 `lithePointer` 呈现可点击的小手，但没有悬停文字；退出和卸载时由同一 modifier 恢复光标，不修改整棵树的光标策略。选择弹框通过局部环境关闭小手，树行与工具栏均保持普通箭头。弹层外框、搜索框和工具栏优先使用 Lithe 共享控件。范围列表是复选树，不是普通菜单，不能用 `LitheSettingsCheckbox` 加 `LitheDropdownRowStyle` 替代。原 Git 树复选框提升为 `LitheTreeCheckbox`，Git 原调用与数据库共用同一套 24pt SVG（内部绘制 16pt 方框），资源已包含深浅、焦点、禁用及三态变体，不重画勾选符号。列表使用 `litheTreeRow` 的 13pt 文字、24pt 行高、树选择/悬停色；保留 12pt 树边距与 19pt 根节点控制占位，复选框标题旁单行省略，行内空白也能点击。

同 revision 的 `CheckboxTreeBase.kt` 通过 `ThreeStateCheckBox` 与 `ColoredTreeCellRenderer` 组成行；`CheckboxTreeHelper.kt` 隐藏根节点但保留根控制，`PopupChooserBuilder.java` 不对树套用普通列表边距。`ManyIslandsDark/Light.theme.json` 的 Tree 继承通用工具窗口背景，故正文使用已有 `sidebar` 色，只有底部说明区使用 `popupBackground`。说明文字采用 Popup.Advertiser 的 UI 字号减 1pt（12pt）、垂直 8pt/水平 12pt 边距；列表采用已有 480pt 高列表视口，少量条目也保留空白，弹层宿主负责屏幕边界。外观依据是公开的通用控件及实际界面，不复制专有数据库插件代码；模式匹配、动态默认 schema 仍不属于当前范围存储模型。

连接行的名称与徽标右侧空白必须保持相同的单击选择、双击展开/折叠行为。引入独立范围徽标时不能把名称按钮缩短后留下不响应事件的 Spacer；空白命中区域复用同一连接动作，徽标与展开箭头仍独立处理，避免整行手势使它们重复切换。零选库不等于连接无法展开：展开后使用共享树的次要文字色与 11pt small 字号显示“未选择架构”，缩进对齐下一层图标，不放省略号按钮。

显示范围保存在现有连接配置的可选字段 `visibleDatabases`：缺省或 null 表示全部可访问库（新出现的库自动加入），空数组表示一个也不显示，非空数组是固定选择。旧配置没有这个字段时保持之前全部显示的行为。这里不能复用 `database` 字段，因为它属于编辑器当前查询目标；隐藏 beta 后仍可继续编辑 beta 中已打开的表。切换范围只写配置，不读取密码、不测试连接、不查询记录；数据库选择器保存前校验账号当前可见的名称，连接或权限发生变化时拒绝过期选择。连接级刷新跳过隐藏的库，即使该库曾被编辑器加载过。隐藏操作清理相应结构缓存和请求标记，迟到结果不能恢复隐藏节点。元数据仍按展开延迟读取，没有增加全库预扫描。

工具栏“＋”与侧栏右键 New 共用 `LitheMenu` / `LitheContextMenuItem` 的新建菜单：查询控制台、数据源类型子菜单、分组、DBX 导入。类型来自已有 `DatabaseKind.allCases`，选择后将默认引擎传入原连接编辑器；新建初始化与切换引擎复用同一默认值函数，编辑现有连接不重置参数。云数据源、模板、驱动管理等未实现能力不添加空动作。右下角角标来自 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `platform/icons/src/expui/general/dropdown{,_dark}.svg`（16pt 画布右下角 4pt 直角三角形）；`ActionButton.java` 判断 popup group 后由 `ActionButtonLook.paintDownArrow` 将角标相对主图标偏移 (1, 1)。只补齐现有 IDEAIcons 源资源，不引入下载脚本或运行时写入。菜单外框、字体、选中颜色、子菜单及键盘导航继续由 Lithe 共享菜单拥有。连接编辑器保留共享弹窗尺寸支持，最新分页布局使用稳定内容尺寸，避免切页跳动。新建菜单的数据源入口按用户后续明确要求，复用右侧数据库工具窗口的 `database/expui/dbms@20x20` 圆柱图标，以现有相同资源统一显示；其 DatabaseTools 来源和 Apache-2.0 声明保留在 IDEAIcons/NOTICE，不声称来自 Community。其余菜单图标使用 Community 资源，七种数据库保留现有同 revision 的 `providers` 原图。查询、数据源、分组三行连续使用共享 24pt 行高，仅导入前保留分隔组，避免每项后叠加 11pt 分组留白。Community 无 Nacos 专属图标，因此共享品牌控件改用该 revision 的通用 `expui/general/settings` 原图（本地命名 nacos），删除原 DBX PNG；缺失资源时的备用图标也使用 Community dataTables，取消 SF Symbols 分支。

侧栏空白区（包含尚未建立连接的空状态）复用 `litheContextMenu`，提供 New → 连接/分组、DBX 导入、按所选节点刷新和全部折叠。根层空白拖放区域填满视口剩余高度，因此右键不再只有树末的一行能命中；节点菜单保持独立。

## 考虑过的备选方案

- 每展开一个数据库就切换当前连接配置：代码更短，但多个库仍共享同一份内容，展开也会打断查询，因此不采用。
- 为每个数据库复制一份连接：会重复保存服务器地址与凭据，改变现有连接和分组语义，因此不采用。
- 展开连接时读取所有库的所有元数据：首次加载开销随服务器规模增加，且一个无权限对象可能拖累整棵树，因此按库延迟加载。

## 后果

同一连接的多个库及多个连接能独立展开，分组与混合类型连接继续保留。代价是元数据在模块内存中保存到刷新、配置变更、断开或模块释放；外部数据库结构变化需要刷新，已有进程端口的超时仍负责限制单次数据库调用。当前编辑区仍只有一个活动数据库，树的并行展开不表示为每个库新增独立编辑会话。Windows 的树没有在此次 macOS 界面修改中同步。

## 连接编辑器排版与草稿检测

连接编辑器保留原有字段和保存流程，名称固定在顶部；常规页承载引擎及连接参数，SSH / TLS 页承载原有网络选项，安全与标记页承载分组、颜色、只读和保护选项。使用现有输入框、选择器、工具窗口分页及操作按钮样式，固定 760×580 内容区，长内容在页内滚动。

用户另行授权测试连接：操作栏左侧复用 `LitheBannerActionStyle`，可选颜色仅覆盖本按钮为主题 accent，默认调用者不变；文字及 hover 下划线同色。检测只调用已有 sidecar 接口，不保存连接或密码、不改当前工作区和连接状态。修改有效草稿、密码或关闭弹窗取消 UI 任务，迟到结果不能覆盖新草稿。macOS 同步进程运行器会观察任务取消并沿现有进程组终止路径清理测试 sidecar；30 秒请求超时仍是兜底。编辑连接的空密码沿用已保存密码；新连接为空则使用空密码。成功后自动打开位于测试链接上方的共享 `LitheDropdownPopover`。纠正结果卡片误用菜单表面：仅该调用选择 contentProvidesSurface，复用宿主定位、关闭和事件生命周期，内容自行提供结果气泡表面。底栏保留 Community greenCheckmark 与引擎名称，可重开/收起结果；浮层使用绿色成功标题、主题色复制链接和可选择正文。现有 sidecar 仅返回 connected，因此只展示已知引擎与单调时钟测得的端到端检测耗时，不能把它称为网络 Ping，也不虚构服务端/驱动版本、大小写规则或实际协商的 TLS 状态。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'DatabaseWorkspaceLifecycleTests/databaseTree|LitheTreeRowStyleTests'`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`

回归使用现有数据库进程端口的可控替身，覆盖 MySQL/MariaDB、混合分组、无默认库、同名表上下文、权限失败重试、刷新移除库以及数据库和表结构在断开/删除/释放后的迟到结果。受控慢请求还验证结构加载期间立即展开并显示进度、折叠不重开、重复展开命中缓存，编辑器与树共享结构请求且展开不查询表数据。深浅主题宿主测试通过原生辅助功能操作展开和折叠，并验证两个库的表同时出现；这些检查不替代完整工作区的真实连接验收。另用临时 MySQL 8.4.11 实例验证数据库列表的权限过滤，以及两个库中同名表的查询结果和全部对象分组查询；受限账号看不到未授权的第三个库。临时实例及数据在检查后清理。

## 适用范围

- `macos/Sources/LitheDatabaseModule/Application/DatabaseFeatureModel.swift`
- `macos/Sources/Lithe/Views/Database/DatabaseSidebarView.swift`
- `macos/Tests/LitheTests/DatabaseWorkspaceLifecycleTests.swift`
- `shared/platform-feature-matrix/features/database-connections.json`

## 成功气泡源码核对（2026-10-23）

上游统一固定为 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：

- `platform/platform-impl/src/com/intellij/ide/ui/laf/LafManagerImpl.kt`：`INTER_SIZE=13`、`Font.PLAIN`；`shouldFallbackToSystemFont` 对 zh/ja/ko 为真，macOS `installMacOSXFonts` 使用 Helvetica Neue 13。结果正文和 Copy 随 locale 使用该分支，成功标题按用户截图单独加粗，不再让菜单动作样式覆盖字体。
- `platform/platform-impl/src/com/intellij/ui/BalloonImpl.java`：非 dialog 模式 ARC=4，上下方向 pointer width=14、length=10。移植四角和连续底边指针路径，1pt 描边使用 Shaper 的整数坐标和 size - 1 远端边缘（原先错误内收半点已纠正），不能先画完整矩形再叠加三角形而留下内部横线。
- `platform/platform-resources/src/themes/islands/ManyIslandsDark.theme.json` 及 Light：沿 parent 和颜色别名解析 dialog-bg、popup-border、text-default、Label.successForeground。深色 #191A1C/#33353B/#D1D3D9/#6DB083；浅色 #F7F8F9/#DDDFE4/#000000/#338555。结果卡片采用 dialog surface，不继承菜单 popup-bg，也不直接使用 ToolTip 的反馈灰底。
- Community plugins 目录无 Database Tools 实现，公开 `DataSourceTestConnectionManager` 堆栈也不能证明私有结果面板的构造参数。因此上述字体、气泡默认几何和主题 token 是可核对的 Community 规则；选择非 dialog 气泡、dialog-bg/popup-border 组合、标题粗体、16pt 内容留白、12pt 标题间距以及跟随本地 760pt 表单减去两侧留白的宽度，是按用户截图进行的独立布局适配，不声称拿到了私有面板源码或其全部规则。

验证应覆盖真实资源深浅主题、中文字体回退、正文常规/标题粗体、边框与底部透明区域及指针、重新打开和取消清理；保持其他共享菜单表面不变。不增加服务器版本或驱动元数据请求。

### 输入框与原生浮层外沿纠正

连接编辑器改用项目已有 `litheSettingsTextField`（共享 28pt 高度、4pt 圆角），Commit 对话框输入样式也按用户后续要求复用共享 4pt 圆角 chrome；所有使用该 modifier 的 Git 和数据库表单一并生效，保留原焦点绑定与 1/2pt 边框宽度。用户名和密码保留与 Host 相同的端口区占位，端口标签按当前语言自然测量，隐藏占位不进入辅助功能树。检测耗时与按钮统一取视图 locale，避免 AppLanguage 英文与系统中文混用。自带表面的结果气泡关闭 AppKit 原生窗口阴影附带的外沿，保留既有独立描边；普通菜单仍使用原生阴影。

### 成功浮层淡入

Community 同一 revision 的 `BalloonImpl.runAnimation` 按帧提高 alpha，`BalloonPopupBuilderImpl.myAnimationCycle` 默认 500ms；Database Tools 私有调用是否覆盖时长不可确认。结果浮层采用原生 NSWindow 500ms 线性淡入，仅首次展示/重新打开执行，布局更新不重新播放；关闭仍立即移除，不留下延迟回调重开窗口。尊重 macOS 减少动态效果设置，其他菜单默认无淡入。

### 两种密码保存范围与复制结果

按用户确认仅支持 Until restart / Forever，不展示未实现的 Never / For session 或 IDE 密码设置入口。`DatabaseProfile.passwordPersistence` 为可选解码字段，旧数据回退 Forever。前者由 DatabaseConnectionStore 进程级加锁内存字典持有，跨模块重载仍有效、退出进程自然释放，不写偏好或凭据存储；后者沿用已有安全存储。切换到临时模式先成功删除持久化凭据再发布内存值，切换永久模式先成功写入再清内存；保存配置失败时恢复原密码及原范围。复制连接保留保存范围，删除连接清理两种存储。下次启动临时密码为空，仍通过已有编辑连接入口重新填写，不增加自动凭据弹窗。

新建连接用户名留空，不再默认 root/postgres/sa。成功浮层 Copy 使用手形光标，复制后收起，点击结果入口可重新打开；测试恢复用户完整剪贴板内容。

### 新连接默认名称

按用户提供的 IDEA 界面形式，Name 默认显示 `数据库@主机`，未填写数据库为 `@主机`。新草稿在未手动改名前随 Host/数据库/引擎更新；手动改名或编辑已有连接后保持用户名称。SQLite 使用文件名，未选择文件时使用引擎名称。MongoDB URI 仅提取 host，禁止把账号、密码或 query 拼入名称。当前默认 Host 仍为 127.0.0.1，不为显示名称改变网络连接地址。公开文档不提供完整私有自动命名实现，此处是与截图命名形式一致的本地适配。
