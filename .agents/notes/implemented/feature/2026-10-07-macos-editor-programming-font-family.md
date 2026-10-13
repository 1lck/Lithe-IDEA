# Agent 笔记：macOS 代码编辑器可选择编程字体族

状态：已实现

## 先说结论

代码编辑器的编程字体族现在是用户设置：设置 → 编辑器 → 显示 → Font。默认值仍是随安装包
分发的 JetBrains Mono，所以没有改过设置的用户看到的渲染和旧版本完全一致。候选列表只列
等宽的已安装字体族；终端、Output 工具窗和提交信息输入框继续使用打包字体，与 IDEA 的
Editor font / Console font 分工一致。用户选的字体被卸载后，编辑器渲染和所有排版度量都
回退到打包字体，设置项仍保留用户原值。

## 问题

Issue #1090 的用户不喜欢默认的 JetBrains Mono。核对源码后确认 macOS 的
`设置 → 编辑器 → 显示` 当时只能改字号，字体族硬编码在主题字体的入口里。

这不是一个纯 macOS 缺口：Windows 产品早就有 `settings.editor.fontFamily`、字体选择器、
`validate_font` 校验和按族回退的解析逻辑。macOS 缺少同一项能力，等于跨平台行为不一致。

真正的难点不在“加一个下拉框”，而在于**字体会被三处不同的排版系统消费**：

1. SwiftUI/AppKit 通过 PostScript 字型名取字（`JetBrainsMono-Regular`）。
2. 内嵌 Monaco 编辑器运行在独立的 WebKit 进程里，只能通过 CSS **族名**取字，而且它
   无法使用 CoreText 的进程内注册，必须靠资源 adapter 的 `@font-face`。
3. 原生 Diff 用“单字符 advance × 最长行字符数”计算横向内容宽度和行号栏宽度。这套
   度量只有在等宽字体下才成立。

## 决策

### 只允许等宽字体族

候选列表由 `MacEditorFontCatalog.editorFamilies()` 生成，只包含等宽族，打包的
JetBrains Mono 固定排第一。判定顺序是先看字型是否声明 `monoSpace` 符号 trait，再实测
`i`、`W`、`0` 三个字形的 advance 是否相同——不少等宽字体不声明该 trait，只信 trait 会漏。

这条限制同时保护了上面第 3 点：因为所有可选字体都是等宽的，原生 Diff 现有的单字符
advance 度量不需要改成逐行测量。如果以后允许比例字体，必须先重做 Diff 的横向宽度与
行号栏度量，不能只放开列表。

### 存储只保存族名，可用性由平台层判断

- `AppSettings.editorFontFamily`（UserDefaults 键 `settings.editorFontFamily`）只保存一个
  族名，默认值是 `EditorFontDefaults.monospacedFamily`（`"JetBrains Mono"`）。
- `EditorFontResolution` 在 Models 层只做规范化：去空白、空值回落默认族。它**不查 AppKit**，
  因为 Models 层不应该依赖 Platform。
- `MacEditorFontCatalog` 在 Platform 层回答“这个族是否可用”“应该实际用哪个族”。所有渲染
  入口先调用 `resolvedFamily(_:)`，无法解析就回退打包族。

开发者新增一个编辑器字体消费者时，应该这样取字体：

```swift
// 正确：先解析族名，再按族取字；失效自动回退打包字体。
let family = MacEditorFontCatalog.resolvedFamily(settings.editorFontFamily)
textView.font = MacEditorFontCatalog.font(family: family, size: settings.editorFontSize)
```

```swift
// 不要：直接拼打包字型名，或把未解析的族名直接交给网页。
textView.font = NSFont(name: "JetBrainsMono-Regular", size: size)   // 用户选择会被忽略
call("configure", ["fontFamily": settings.editorFontFamily])        // 失效族名会静默变成系统字体
```

### 网页侧要传 CSS 族名，不传 PostScript 名

`MonacoWorkbenchEditor` 把解析后的**族名**放进 `window.lithe.configure` 的 `fontFamily`
载荷。Monaco 会把它写成编辑器节点的内联 `font-family`，优先级高于 `EditorFrontend/index.html`
里写死的 `"JetBrains Mono", monospace`，因此不需要为换字体改网页 CSS。用户安装的系统字体
对 WebKit 的 WebContent 进程是全局可见的，这是它和打包字体（进程内注册，必须走 `@font-face`）
的关键区别。

### 作用范围刻意排除终端与输出窗口

`LitheTheme.editorFont(size:weight:)` 没有被改成“读设置”，它仍然表示**打包字体**。终端、
Output 工具窗、提交信息输入框，以及搜索结果里的 Before/After 小片段继续调用它。只有这样
才保住 IDEA 的 Editor font / Console font 分工；将来要做 Console font，是独立的一项设置。

要区分两种“搜索预览”，它们不是同一件事：

- 搜索结果列表里的 **Before/After 小片段**是结果行的固定排版，用打包字体的 12pt，不跟随
  字体族设置。
- 点开的**完整源码预览**是一个真正的编辑器：它经 `SourcePreviewEditorContent.monaco`
  构造 `MonacoWorkbenchEditor`，因此跟随用户选择的族。

所以不要用“搜索替换预览用打包字体”一句话概括两者；这会把已经正确接线的完整预览说成
未接线，也会让后来的人误以为搜索结果片段需要单独接线。

### 原生 Diff 用带默认值的参数传递族名，不注入新的环境对象

Diff 的渲染字体和度量字体必须来自同一个族，否则行号栏宽度、横向滚动范围和实际字形会
不一致。族名通过带默认值的参数（默认 `EditorFontDefaults.monospacedFamily`）沿着
`DiffReviewView` / `GitCommitDiffReviewView` / `DiffPaneView` → `DiffSplitPaneView` /
`DiffUnifiedPaneView` → `DiffNativeCodeColumn` 传下去。

**不要**给这些视图加 `@EnvironmentObject AppSettings`。这条规则来自一次真实的 CI 失败：
最初给四个 Diff 入口加了 `@EnvironmentObject AppSettings`，其中 `AgentFileDiffView` 的宿主
`AgentActivitySummaryBar` 是刻意不依赖环境的（`AgentActivityPresentationTests` 只注入
`colorScheme` 就把它放进独立 `NSHostingView`），于是测试在运行时直接
`Fatal error: No ObservableObject of type AppSettings found`，整个 Swift lane 中断。
`DiffSplitPaneView`、`DiffPaneView`、`GitCommitDiffReviewView`、`DiffUnifiedLayout`、
`LocalHistoryView`、`BranchComparisonView` 同样会被独立宿主构造。

所以统一这样做：

- 叶子 Diff/预览视图只接受 **带默认值的 `fontFamily` 参数**，默认 `EditorFontDefaults.monospacedFamily`。
- 族名由**已经持有 `AppSettings` 或 `AppModel` 的宿主**显式传入：`EditorAreaView` 用
  `settings.editorFontFamily`，`RootView` 的历史 Diff 用 `session.settings.editorFontFamily`。
  `AppModel` 已经持有 `settings`，不需要新增环境对象。
- 确实拿不到宿主的表面就保留打包字体，并在代码里写明原因，而不是给它加一个必需环境对象。
  当前唯一这样的表面是 Agent 上报 Diff 弹窗：`AgentActivitySummaryBar` 不依赖环境，事件流
  树上也没有 `AppModel`，接进去要在五层视图里加参数，收益不抵风险。

### 字体枚举只读、只缓存内存

`MacEditorFontCatalog` 只查询系统字体库和本进程已注册的字型，枚举与等宽探测结果缓存在
进程内静态值里，不做任何持久化。因此打开设置、切换字体都不会往已签名安装包里写东西，
Sparkle 的增量更新基线不受影响。如果以后要把字体列表持久化到磁盘，必须走平台存储
adapter 写到 Caches/Application Support，不能写安装目录。

### 字族缺字时回退到打包字体，并在设置里提示

用户选的字体不保证覆盖全部字符：为 GBK 写的旧字体经常缺标点、符号或界面自己用到的中文字形。
这里分两件事处理，**显示优先于提示**：

1. **保证能显示。** 打包字族始终是所选字族之后的第一回退，两条渲染路径都要设置：
   - 网页侧：`MacEditorFontCatalog.editorFontStack(_:)` 产出
     `"所选族", "JetBrains Mono", monospace`，而不是只发一个族名。只发族名时 Monaco 会补它自己的
     `monospace`，回退到哪台机器都不一样；显式带上打包字族后，网页和原生界面用同一套回退。
   - 原生侧：`MacEditorFontCatalog.font(family:size:weight:)` 给非打包字族加上以打包字体描述符
     开头的 `cascadeList`。AppKit 本身只走系统级联，不加这一步时缺字会落到任意系统字形。
   - 打包字族自己不再叠加级联（它就是回退目标），所选字族本身就是打包字族时网页栈也不重复。
   - 打包字体同样没有的中文等字形继续走系统级联，这是原有行为，不视为缺陷。

2. **告诉用户，但不阻塞选择。** 设置 → 编辑器 → 显示 → Font 行下方在缺字时显示提示，
   形如「Fira Code 不包含中文字符；Lithe 会用 JetBrains Mono 和系统字体显示这些字符。」

   - 探测用 `MacEditorFontCatalog.coverage(family:requirements:)`：对每个字符单独调用
     `CTFontGetGlyphsForCharacters`，glyph 为 0（`.notdef`）也算缺失，避免批量结果掩盖单个缺字。
   - 要求集由界面语言决定（`EditorFontRequirements.forLanguage(_:)`）：基本拉丁字母与界面标点
     **始终**要求；中文只在中英文界面为中文时要求。日文、韩文、希腊文、西里尔文不列入要求，
     否则一个正常的中英文字体也会被报成缺字。
   - **打包默认字族豁免提示**：它就是基线和回退目标，提示用户「随包字体缺中文」没有任何可执行
     动作。只有用户换成别的字族后才可能出现提示。
   - 字族已卸载时不显示缺字提示，那时由控件的不可用样式负责表达。

### 可搜索的设置选值控件复用同一个所有者

字体族有数百项，必须能搜索。实现方式是给已有的 `LitheSettingsSelect` 增加可选的
`searchPrompt`/`searchText`，而不是新建第二个设置选值控件：

- 搜索框复用 `LitheSettingsSearchField`（因此它的高度被提为 `height` 常量供弹层预留）。
- 过滤规则抽成 `LitheSettingsSelectSearch.matches(_:query:)`，可被单元测试直接覆盖。
- 弹层高度按可见行数收缩；面板本身仍是 `LitheSettingsSelectPopupPresenter`，所以
  ↑/↓、Return、Esc、点击空白关闭等既有键盘行为不变。
- 输入法组合期间（`hasMarkedText`）不拦截导航键，否则中文拼音会被 Return 提前确认。
- 交互层由 `SearchableSettingsSelectTests` 用真实窗口与真实按键覆盖：过滤后弹层收缩、Return 应用
  过滤后高亮的那一行、↑/↓ 在过滤结果内移动、清空搜索恢复全部行、无结果时弹层收缩且 Return 不
  改变选择、Esc 关闭且不应用、组合输入期间 Return 不提交。
- 无结果提示的**可见文案不写成断言**：SwiftUI 的 `Text` 不通过 `NSView` 暴露字符串，视图树检索
  只会测到框架内部实现。该文案属于能力矩阵里的实机视觉验收。

## 考虑过的备选方案

### 直接把 `LitheTheme.editorFont` 改成读设置

改动最小：一个入口改完，所有消费者自动跟随。没有采用的原因是终端、Output 工具窗和提交
信息输入框也会一起换字体，既偏离 IDEA 的 Editor/Console 分工，也让用户无法只改代码字体。

### 使用系统的 `NSFontPanel` 字体面板

系统面板已经提供完整字体浏览、等宽过滤和预览，实现量几乎为零。没有采用的原因是它的
外观与产品共享下拉体系不一致，无法只列等宽族，也拿不到“族名 + 字重降级”的确定性结果。

### 允许全部字体，另加“只显示等宽字体”开关

IDEA 的编辑器字体组合框确实有这个开关，功能上更完整。本次没有采用，因为放开比例字体
会让原生 Diff 依赖的单字符 advance 度量失效，需要先重做 Diff 的横向宽度和行号栏测量，
属于独立改动。等宽限定是当前实现能保持排版正确的前提。

### 新建一个专门的可搜索字体下拉组件

改动更内聚，不必碰 `LitheSettingsSelect`。没有采用的原因是设置里的“选值下拉”已经由
`LitheSettingsSelect` 拥有，再建一个就会形成第二套触发器和第二套弹层行为，正是共享控件
规则要避免的漂移。

## 后果

- 收益：macOS 与 Windows 的编辑器字体能力对齐；默认行为不变，属于纯增量；原生 Diff 与
  主编辑器使用同一字体族。
- 代价：只支持等宽字体；用户字体缺少对应字重时按 `NSFontManager` 最接近的字重降级，
  不会合成八个字重；原生 Diff 的度量现在依赖“可选字体都是等宽”这个前提。
- 代价：字体目录是**进程级静态缓存**（`MacEditorFontCatalog.index` 只在进程内构建一次，
  之后不再失效）。因此新安装或重新安装的字体必须**重启应用**才会出现在候选列表里；
  重开设置窗口不会重新枚举。验收和文档都按“重启后生效”描述，不能把重开设置窗口当作
  缓存失效。
- 代价：首次构建字体列表要枚举系统字体族并逐族实测等宽，实测约 0.27 秒
  （`EditorFontFamilyTests` 里 `bundledFamilyIsAlwaysOfferedAndResolvable` 的 0.268 秒）。
  它只在进程内做一次，由设置页的 `.task` 在页面出现后触发，不阻塞窗口首帧；首次打开
  编辑器设置页时有一次性停顿。要消除这次停顿应把枚举移到后台队列再回主线程发布结果，
  而不是把列表持久化到磁盘。
- 需要重新评估的触发条件：要支持比例字体、要给终端/Output 增加独立的 Console font 设置、
  或者要把字体列表持久化到磁盘。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter EditorFontFamilyTests`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter SettingsSearchVocabularyTests`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter SearchableSettingsSelectTests`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter AgentActivityPresentationTests`
- `./scripts/test-macos.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-agent-notes.sh`

关于缺字回退与提示，`EditorFontFamilyTests` 覆盖：网页字体栈把打包字族放在所选字族之后且以
`monospace` 结尾、打包字族自身不重复；原生用户字族带以打包字体描述符开头的级联表、打包字族不带；
探测结果与打包字体实际覆盖一致（覆盖拉丁字母与界面符号、缺中文）；要求集随界面语言变化；
缺字描述在单个脚本时点名、多个脚本时收敛为通用措辞。

## 适用范围

- `macos/Sources/Lithe/Models/Settings/EditorFontDefaults.swift`
- `macos/Sources/Lithe/Models/Settings/EditorFontCoverage.swift`
- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacEditorFontCatalog.swift`
- `macos/Sources/Lithe/Platform/MacOS/MonacoWorkbenchEditor.swift`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
- `macos/Sources/Lithe/Views/App/SettingsSearchVocabulary.swift`
- `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift`
- `macos/Sources/Lithe/Views/Diff/`
- `macos/Sources/Lithe/Views/History/`
- `macos/Sources/Lithe/Views/Git/BranchComparisonView.swift`
- `macos/Sources/Lithe/Views/Agent/AgentFileDiffView.swift`
- `macos/Tests/LitheTests/EditorFontFamilyTests.swift`
- `macos/Tests/LitheTests/SettingsSearchVocabularyTests.swift`
- `macos/Tests/LitheTests/SearchableSettingsSelectTests.swift`
- `shared/platform-feature-matrix/features/editor-font-family.json`
