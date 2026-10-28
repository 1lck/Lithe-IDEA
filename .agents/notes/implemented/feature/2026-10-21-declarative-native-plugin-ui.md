# Agent 笔记：声明式原生插件树与动作

状态：已实现

## 先说结论

插件可以声明树、列表、输入框、下拉选择、复选框、工具栏按钮和右键菜单，由宿主使用 Lithe 公共控件显示；开发者只提供数据与函数，不必开发前端样式。macOS 已接入原生工作台，Windows 已接入保留准入门控的渲染器、类型化函数通道及左、下、右三侧面板，继续复用既有执行和清理机制。Windows 的 `ui:3` 准入仍关闭，位置覆盖仅保存在当前宿主窗口和工作区的内存中；完整产品、WebView2（Windows 网页视图运行时）及与 macOS 六组停靠的对齐仍未验收。

## 问题

文本窗口无法表达节点选择与业务动作；Web 页面则要求插件作者自己维护控件与样式。现有窗口注册、停靠、主题和函数调用已经具备基础能力，重复建设会带来两套状态和清理边界。

## 决策

在 ui 能力版本 3 下引入独立版本的原生声明，首版支持一棵树、一个列表或一个表单及其面板动作。共享 Core 同时负责初始声明与刷新数据的结构、所有权和预算校验（原生适配器不复制节点规则），应用功能模型负责选择、展开、数据替换和事件，视图只使用已有标题栏、工具栏按钮、菜单、行样式和滚动条。声明不能携带颜色、字体或脚本。树/列表的行容器在共享行背景外提供 Tree.horizontalInset 的左右留白，让悬停与选中保持同一外边界；文字内部仅保留层级缩进。键盘区域复用 litheFocusEffectHidden 关闭系统矩形焦点环，仍通过共享行的活动/非活动选中配色表达焦点，保留方向键和无障碍。

数据源和动作复用现有插件函数入口：它负责授权、工作区和插件范围、超时及取消。原生窗口使用与网页相同的会话登记表，插件停用、替换及关闭项目时同步取消请求。隐藏窗口也释放请求，重开从已有状态存储恢复选择和展开。发布包与插件包只读，macOS 状态使用平台提供的原有可写存储，Windows 面板草稿与位置覆盖只保存在内存中，不改变签名或 Sparkle 增量更新基线；没有新增可跨工作树复用的缓存资源。

正确做法：插件声明树和刷新动作，函数只返回稳定节点 ID 与标签。不要这样做：按插件名在工作台增加视图分支，或为了渲染树另建后端进程与生命周期。

## 考虑过的备选方案

- 要求所有插件提供 Web 页面：已有能力保留，但不满足免写样式的需求。
- 执行第三方 Swift 界面代码：增加二进制兼容、签名和隔离问题，不采用。
- 一次实现表单、任意组件组合与领域迁移：超出本轮范围，先验证最小完整路径。

## 后果

同一份树与动作声明可以直接使用 IDE 样式。代价是首版只允许每个面板匹配一个已检测构建实例，完整刷新最多 2000 个节点，尚无多实例选择器或按需加载子节点；这些限制在契约中明确，不能默默选择第一个实例。动作限定面板内，不能据此宣称全局独立命令或整个 #1209 已完成。

选择与展开按稳定 ID 保存；无效回复保留上一份有效节点并显示错误。入口必须保留稳定的非空宿主容器：不能依赖最初没有子视图的 Group 启动实际工作台中的出现回调。首次内容创建、后续重绘和清理均绑定容器，初始化失败必须显示原因，不能留下无标题的空白面板。
同一停靠槽会复用相同 SwiftUI 渲染类型；内部会话必须以 contribution.id 为身份边界，
不能只按工作区标识。否则切换两个插件面板会沿用前一个面板的 State，释放回调却拿到
后一个窗口 ID，遗留会话后再次打开就报重复登记。
仅增加窗口身份仍不够：隐藏、重开和父容器销毁时，不能依赖 onDisappear 回调再读取
可能已销毁的 State 存储。StateObject 会话所有者持有准确的 feature 与释放函数，
出现/消失时显式打开/关闭，销毁时在 MainActor 同步释放未结束的会话；登记表仍核对句柄身份，
旧释放不能关闭后来新建的会话。
外层分隔布局改变结构时，新分支的面板可能先挂载，旧分支才消失；仅靠视图身份与
销毁回调无法避免这个重叠。登记表允许同一插件同一窗口原子替换：先登记新句柄，
再关闭旧句柄，旧视图随后释放时仍按句柄身份检查。不同插件、网页句柄以及被停用的插件
不能借此覆盖登记。样式不是插件作者的责任：标题栏
复用已更新的公共 LitheToolWindowHeader（41pt/13pt Bold、纯文字、无图标和边框/底线），不由插件另画。完整挂载回归需要把插件视图嵌入父容器，不能只渲染已经创建好的内容面板。

已在真实 DEBUG 预览中通过磁盘安装的 Sample Build 和测试工作区验证：节点加载、展开、Inspect、右键点其他节点、方向键，以及隐藏重开恢复。真实产品浅深色、窗口失焦、停靠恢复和示例安装验收仍应独立记录，组件测试不代替原生产品验收。

真实 UI Lab 预览已验证：静态树、静态列表、空面板同时显示，左右面板分别隐藏重开，
动态树/列表与静态面板切换均正常，没有重复登记错误；标题均为纯文字，无标题图标、边框和底线。
本轮相关195项 macOS回归通过。桌面工作区曾在 FSEventStreamCreate 监控父目录时阻塞，
因此这轮面板验收使用含同一 marker 的本地临时工作区；没有把该目录监控问题记为已修复。

工具栏动作只显示图标，title 用作悬停提示和无障碍名称；复用现有 LitheToolWindowHoverAction，
鼠标进入整个面板时显露，离开隐藏，键盘/无障碍聚焦仍可操作。动作可用既有宿主图标声明
选择语义图标，原生动作不加载自定义包图片；未声明时 refresh 使用刷新，invoke 使用通用执行。
不能按插件或动作 ID 猜测业务图标，也不能退回文字按钮。
本轮52项宿主图标/悬停/原生面板回归与Core图标边界检查通过。实机已确认非悬停时工具栏隐藏；
鼠标坐标自动化返回 windowNotFoundAtPosition，未据此宣称实机进入/移出已通过，仍需用户验收。

### 表单只接声明，不复制已有公共控件

输入框复用 `litheSettingsTextField`，选择器复用 `LitheSettingsSelect`，复选框复用
`LitheSettingsCheckbox`，后者仅补充 literal 标题入口，样式不变。新的 `form` 内容容纳
至多32个字段和16个按钮，避免为了输入三个控件而引入任意布局/脚本/表单引擎。按钮外观仍使用已有公共 owner。
控件 ID、值类型、选项、动作引用与预算由 Core 校验；宿主恢复已保存字段时还要剔除
已删除字段、变更类型和失效选项，不能让旧状态绕过新声明。

输入每次编辑只存本地值；回车提交，选择器与复选框在改变后提交。onCommit 指向
已有的非选择 invoke 动作，所有当前值以 values 通过现有函数通道传递，之后来源
仍返回空 nodes。没有新后端接口；没有 onCommit 的字段仅本地保存。这样保留中文
输入法编辑过程，避免每个按键都启动插件函数并禁用输入。关闭、停用、替换继续使用
既有取消与晚到结果防护。树/列表旧函数不增加 values 参数，保留原参数形状。

本轮63项 macOS图标/原生面板/公共选择器/菜单覆盖回归通过（8.093s），新增实际
挂载表单检查耗时46ms；19项声明式Core测试与打包后Node示例测试通过。
已生成 NativeUILab 0.2.0，由用户手动导入；完整产品中的表单深浅色、输入法、
弹出选择、禁用与跨工作区人工验收仍 pending，不能由挂载测试代替。

### 表单栅格

form 可声明1–12列及控件span，省略span占满一行，省略layout维持旧纵向布局。
按声明顺序排放，剩余列不足时换行；Core拒绝越界跨度、非表单布局及自定义间距。
宿主通过共享 `LitheFormGrid` 的原生 SwiftUI Layout 测量和放置，不发布逐控件几何
Preference，也不因为缩放重建不同的视图分支。12pt间距与640pt单列阈值由
LitheTheme.FormGrid持有，字段值和焦点继续由稳定ID和既有控件保存。
验收插件0.2.1按用户要求将所有字段各占6列，每行两个完整字段（标题＋控件）。

本轮24项macOS栅格/原生表单/公共选择器回归通过（0.918s），原生宽窄布局
高度测量检查耗时55ms；20项声明式Core校验及打包后Node示例检查通过。
0.2.1声明为每行两个字段，仍由用户手动导入验收；无layout的旧0.2.0声明
保留单列，不能把仅更新宿主当作测试插件已更新。

### 未聚焦输入框的光标

表单已复用公共 `litheSettingsTextField`，但原公共修饰器未接入搜索输入框已有的
`litheTextEditingCursor`，导致鼠标进入未聚焦字段时仍是箭头，点击后才由原生编辑器
显示I形光标。现在由公共输入框修饰器在完整控件区域安装已有光标语义；禁用时仍为
箭头，移出恢复箭头，不在插件或各页面补丁，也不改原生编辑、组合输入或提交行为。

本轮26项搜索输入/原生表单/选择器回归通过（2.483s），复用既有光标处理。
组件回归不等同于实机鼠标悬停验收，最终未聚焦/禁用字段的光标仍由用户在新预览核对。

### 公共组件验收插件0.3.0

以现有通用表单公共组件为本轮完整范围：输入、搜索、多行输入、下拉、分段选择、
复选框、数字步进器，配合标签信息提示、普通/主要按钮与栅格。搜索新增完整
`LitheSearchField` 入口，内部组合已有原生输入、光标、焦点、图标和清空动作；
其余字段直接复用既有owner，补充literal标题入口，避免宿主误翻译插件提供的文字。

info直接使用LitheInfoTip的延迟、固定、关闭、键盘与辅助功能行为，不额外写Tooltip。
按钮复用LitheActionButtonStyle；只增加内容宽度/填满容器的布局能力与宽度上限，
默认参数保留既有页面的尺寸与颜色，不向插件开放视觉参数。按钮与值字段分开声明，
不会成为State.values或函数参数里的假字段。执行仍使用现有action与provider桥接。
多行输入保留Enter换行，以表单按钮提交；其他字段保留回车/修改提交的语义。
Core对信息长度、字段类型、选项、数字范围、按钮引用、跨度及属性适用范围统一校验。

本轮验证：63项Swift公共控件/原生表单/栅格/选择器/样式覆盖回归通过（10.335s），
21项Core声明插件测试通过；源码及打包后Node验收通过。
Core全量初跑有8项历史测试依赖master，而本机系统Git默认main；仅为测试进程
设置init.defaultBranch=master后，1069项Core单测及Node/Java集成全通过（16.77s单测）。
Swift桥接校验通过；Java测试显式使用已安装OpenJDK21，避开系统java启动桩。用户当前运行另一按钮分支
预览，本轮保留其窗口；0.3.0插件需使用本分支新宿主导入，完整实机视觉验收仍待用户完成。

### 完整输入入口与0.3.1验收

原生表单、IDE设置和其他使用共享输入样式的页面，都通过完整LitheTextField /
LitheTextEditor调用，不再由调用方组合原生输入与样式修饰器。搜索框统一为
LitheSearchField，附加动作和外部焦点保留；公共标签与字段间距由LitheFormField负责。
字段和表单按钮仅禁用实际输入/动作，i说明可悬停、点击固定和键盘打开。
InfoTip同时处理已有页面禁用整个父区块的情形，不把例外补丁留给插件渲染器。
0.3.1给每种禁用字段和禁用按钮增加独立说明，方便逐项定位验收；协议不新增字段。
本轮78项macOS回归通过（10.456s），新增完整入口检查373ms、原生输入深浅色
两例126ms、实际声明式挂载和禁用提示打开131ms。源码和打包后Node验收均通过；
边界、契约、矩阵、笔记和bundle不可变静态检查通过。保留用户正在操作的预览，
0.3.1新插件由用户导入；完整人工视觉/键盘验收仍pending。

### 合并#1422后的文字按钮标准

声明式动作直接使用preview已合并的LitheActionButtonStyle，不携带本分支原来的
fillsWidth、maximumWidth或borderInset扩展。公共按钮独立拥有主按钮蓝色及
hover/按下/禁用状态、28pt高度、72pt最小宽、14pt水平内边距、字体和焦点外观。
动作组使用公共6pt间距，横排不足时纵排；字段栅格继续拥有字段布局，不拉伸文字按钮。

实验包0.3.0/0.3.1的buttons.width与buttons.span兼容读取，但不再影响动作组布局。
这样已有测试包能继续加载，同时不会把旧绘制规则带回公共按钮。新0.3.2示例省略
旧布局提示，以普通/主要按钮的短/长文案、禁用、提示及慢动作验证统一样式。
旧fixture保留fill提示，原生挂载回归验证实际按钮仍为28pt且不会填满栅格。

同步preview时保留新版设置分类/插件贡献页面、已安装插件启停分组/筛选，以及
Git未跟踪目录摘要和可见行缓存；这些界面仍使用完整公共树/列表和输入入口。

本次同步后的验证：macOS 323项/56套件通过（10.561s），覆盖公共按钮、实际声明式挂载、输入/树列表、设置、Git及HTML预览；Rust Core全量1106项通过。UI Lab源码及打包后的SDK检查通过。完整产品人工视觉验收仍pending。

### Windows 渲染、函数通道与三侧面板

Windows 的树、列表和表单复用已有公共控件与虚拟列表，由共享 Core 校验声明、字段草稿和返回节点。面板通过类型化函数接口 `NativeFunctionPort` 加载数据和执行动作，复用设置及网页已有的 Core 函数会话、审批和清理提示；前端不能自行挑选函数、程序或构建实例。原生登记由可信插件目录绑定包内容身份、面板、宿主窗口实例、工作区和唯一构建实例。渲染与函数接线已存在，但不因此开放 `ui:3`；正常插件准入仍保留门控。

左、下、右三侧显示接入既有 `MainLayout`、`BottomPane`、`TerminalDockLayout` 和 `ResizablePane`。声明位置是首次打开的默认值，入口右键菜单允许移动到另两侧；移动只关闭同一贡献原来的槽，其他工具的选择和可见状态不受影响。同一贡献只挂载一个面板，每个挂载实例持有准确的原生句柄；隐藏、移动、同槽替换和工作区切换均释放该句柄，晚到的旧登记不能释放后来的所有者。关闭按钮只有在包、工作区、选中贡献和位置仍匹配时才关闭，并把焦点还给对应入口；过期回调不能关闭新工作区的面板。

位置覆盖按当前宿主窗口和工作区保存在内存中，面板的选择、展开和字段草稿还按包内容身份隔离。隐藏重开、在三侧之间移动及返回同一工作区可以恢复现有草稿；包替换不能继承旧包草稿。位置覆盖可以跨同一窗口内的暂时移除保留，但不是重启恢复契约，也不写入插件包、发行目录或跨工作树缓存。

正确做法：把当前贡献从右侧移动到底部，复用现有分隔布局并释放原槽持有的句柄。不要这样做：为三个位置分别创建函数执行器，或让旧面板的关闭回调直接修改当前活动项目；前者会重复执行，后者会关闭无关工作区的工具。三侧接入也不代表已经具备 macOS 六组停靠、自由拖动、入口重排或持久布局。

R13 的 `native-docking.test.tsx` 在集成树独立进程中实跑 10 项、137 项断言通过（5.54s，最慢 218ms）。测试组合真实 `TerminalDockLayout`、`ResizablePane`、`BottomPane`、`NativeToolWindow` 和 `NativePanel`，覆盖三侧挂载与移动、精确释放、隐藏重开、关闭后焦点、工作区及包隔离、长树、窄窗口和组合输入；插件目录、UI 状态动作及原生宿主使用替身。该证据不能代替真实 `MainLayout` 产品、完整包、双窗口与 WebView2 的视觉、输入法及浅深色验收，Windows 状态继续保持 `partial` / `pending`。

R14 的 `native-main-layout.test.tsx` 补齐真实 `MainLayout` 组合链：插件目录刷新与撤回、生产活动入口、UI 状态动作、三个布局槽、原生面板和类型化函数通道均保持真实；原生调用、审批、校验、终端内容及无关功能仍使用替身。集成树独立计时实跑 9 项、161 项断言通过（Bun 2.29s，最慢 329ms），覆盖三侧同时显示、终端挂载身份不变、逆序登记与迟到释放、同槽替换、工作区及包隔离、关闭后焦点，以及重建后的字段和树状态。

重建测试保留当前进程的工作区存储，并使用内存会话仓库验证既有 UI 动作的保存与恢复；位置覆盖与草稿没有经历应用重启。切换宿主窗口标签后重建只证明模拟身份下草稿隔离与精确释放，没有同时启动两个真实窗口。这些组合证据仍不替代完整包、WebView2、真实输入法、浅深色和双窗口验收，也不开放 `ui:3` 或升级 `partial` / `pending`。

Windows 工具栏按 Core 批准的 15 个 host 图标 ID 显式映射到公共图标；未声明时保留 refresh/invoke 默认。补齐的 IDEA SVG 与仓库已批准的 macOS 原文件逐字节一致，保留浅深变体，不从插件包解析任意路径。这些 Git 跟踪的静态输入在构建时打包、运行时只读，没有新增下载、缓存或可复用生成目录，不改变签名及增量更新基线。

字段和动作说明统一调用公共 `ui/info-tip.tsx`，由既有 Button 与 Base UI Popover 管理 500ms 悬停、点击或按钮键盘激活后的固定、再次激活关闭、Escape/外点击及卸载清理。禁用字段和动作只禁用实际输入或执行，说明按钮保持可用；关闭时仍保留可访问的辅助说明。不要在每个 renderer 内复制悬停计时或弹层，也不要修改全站 Tooltip 语义来兼容一个调用方。

Windows 搜索统一使用公共 `SearchField`。非空时的本地化清空按钮只把值交回调用者并恢复输入焦点；原生表单仅保存空草稿，按 Enter 后才提交包括空字符串在内的当前值。禁用或只读字段不能清空，说明按钮仍独立可用。尾部按钮的定位由公共 `Input` 的 accessory 接口负责，不在原生 renderer 复制输入框布局。组件键盘测试显式补发 Happy DOM 缺少的原生按钮默认 click，不代替真实 WebView2、输入法或主题验收。

表单的 primary/normal 只选择公共 Button 的语义变体：primary 使用 accent，普通动作使用 default；渲染器不自定义颜色或重做按钮。真实 native-controls 夹具回归同时检查禁用、说明、草稿恢复与完整动作参数。已开放插件设置列表中的公共 SearchField 另有真实 WebView2/CDP Enter、Space 默认清空、同一输入焦点、过滤和选中恢复证据；这不等于原生 ui:3、物理键盘、输入法或主题视觉验收。

## 验证

- `./scripts/verify-shared-contracts.sh`
- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib native_ui_validates_version_ownership_actions_and_budgets`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'PluginNativeUI|PluginWeb|WorkbenchContributionHostTests'`
- `LITHE_PLUGIN_SDK_ROOT=<lithe-plugin-docs/sdk/node> node --test macos/Tests/Fixtures/native-ui-lab/native-ui-lab.test.mjs`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- Windows 组件测试分别在独立进程运行，避免模块替身互相污染：`bun test --timeout 15000 src/features/plugins/native-ui/native-panel-session.test.ts`、`bun test --timeout 15000 src/features/plugins/native-ui/native-panel.test.tsx`、`bun test --timeout 15000 src/features/plugins/native-ui/native-functions.test.ts`、`bun test --timeout 15000 src/features/plugins/native-ui/native-docking.test.tsx`（工作目录 `windows/tauri`）。
- Windows 原生登记与函数边界：运行 Tauri 宿主的 `plugin_host::native_ui` 和 `plugin_host::functions::native` 定向测试；组件结果不代替宿主或完整产品验收。
- Windows 真实工作台组合在独立进程运行 `bun test --timeout 15000 src/features/plugins/native-ui/native-main-layout.test.tsx`（工作目录 `windows/tauri`）；按前端计时 runner 生成每项 JUnit/HTML 报告，不与其他含模块替身的 suite 合并运行。

## 适用范围

- `shared/contracts/plugins/v1/native-ui.schema.json`
- `rust/lithe-core/src/plugins/native_ui.rs`
- `macos/Sources/LitheModuleAPI/Plugins/PluginNativeUI.swift`
- `macos/Sources/Lithe/Application/Features/PluginNativeUIFeature.swift`
- `macos/Sources/Lithe/Views/Workbench/PluginNativeToolWindowView.swift`
- `macos/Tests/Fixtures/native-ui-lab/`（宿主验收 fixture，打包使用外部官方 SDK）
- `windows/tauri/src/features/plugins/native-ui/`
- `windows/tauri/src/features/layout/components/main-layout.tsx`
- `windows/tauri/src/features/layout/components/bottom-pane/bottom-pane.tsx`
- `windows/tauri/src-tauri/src/plugin_host/native_ui/`
- `windows/tauri/src-tauri/src/plugin_host/functions/native.rs`

## 2026-10-23 SDK 迁移后的验收归属

遵循 #1442，主仓库不恢复 SDK 及其端到端测试。UI Lab 作为 macOS 宿主的回归与人工验收 fixture 保留在 `macos/Tests/Fixtures/native-ui-lab/`；Core 继续验证其完整清单。打包和 Node 验收显式通过 `LITHE_PLUGIN_SDK_ROOT` 使用外部 lithe-plugin-docs 的官方 Node SDK，复制结果仅进入忽略的 `.artifacts/native-ui-lab/`，不写入已安装包或应用 bundle。插件开发者说明与 SDK 发版继续归 lithe-plugin-docs。

## 与 MCP 和 Agent 设置的公共输入入口兼容

MCP 命令行的新编辑行为继续由 MCP 功能层解析并校验引号，公共 `LitheTextField(axis: .vertical)` 仅负责允许换行和共享外观，调用方可限制可见行数。默认单行输入及密码框高度保持原规则。Agent 指令编辑器把外部布尔焦点传入完整公共编辑器，使 Command-S 仍对应当前编辑区；不在外层容器重装焦点或旧样式 modifier。新增的技能、指令和 MCP 页面都使用同一搜索、输入和多行编辑入口，避免上游合并后重新出现并行样式。

VCS Provider 的变更分组与文件行也通过 `LitheTreeList` 呈现，使用分组/文件两类稳定 ID 映射原有路径选择；包含勾选仍由业务控制，公共入口负责展开、选择、菜单、键盘及默认无障碍激活。新增文件激活回归应验证最终打开文件，而非仅改变选中状态。

## 公共树的外部改选与键盘导航

选择绑定是调用方发布当前选中的唯一入口。公共控件记录自身发起的选择，只有外部改选才重置键盘游标和范围锚点，避免画面已到新行而 Return 仍操作旧行；Shift 扩选与缩选保留原锚点，并直接处理 AppKit 的范围选择命令。普通不可选标题不进入上下键遍历，可展开分组仍保留键盘焦点和左右键语义。原生挂载回归验证外部 a→c 后 Return/方向键及 Shift 的最终对象，并在真实 Problems 视图检查 A 诊断→Down→Return 最终打开 B 文件的行列。

同步 preview 的会话历史时保留排序/行模型缓存和 Equatable 列表边界，公共树仅接管平铺可见行与交互；新建项目复用已抽出的 PluginFieldControls，侧栏与 Settings 共用公共树，不恢复旧样式 modifier。
