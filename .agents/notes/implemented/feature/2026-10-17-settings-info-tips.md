# Agent 笔记：设置页说明收进悬停信息图标并压缩排版

状态：已实现

## 先说结论

设置页不再把每项功能的解释作为常驻小字堆在控件下面。说明文字收进设置标签后面的 ⓘ 图标：默认只显示一个符号，指针停留半秒、点击图标或用键盘打开时才显示解释。行级说明使用 `LitheSettingsLabel` 和 `LitheInfoTip`，分组级说明使用 `LitheSettingsSection` 的 accessory。控件统一靠右对齐，分组间距收紧，编辑器字体页增加实时预览和切换前后的短暂对比。错误、警告、保存结果、空态和动态状态仍然直接显示。

## 问题

Issue #1316 的截图里，通用、Git 和 Agent 管理页在几乎每个控件下面都有一段说明。说明本身有价值，但常驻显示让页面看起来密密麻麻，用户只想改一个开关时也要先扫过大量文字。用户提出的目标模式是“默认只有一个符号跟在设置后面，鼠标悬停约半秒再显示具体含义”；进程终止策略页此前已经用 ⓘ 做到了这一点，但其它设置页仍在复制常驻说明。

## 决策

- 纯解释性文案放进 `LitheInfoTip`。它已经有 500 ms 悬停延迟、点击固定、键盘 Space/Return 打开和 VoiceOver 读取 `accessibilityHint` 的能力，不在各页面重复实现。
- 行内设置标签用 `LitheSettingsLabel(title, info:)`，把标题和 ⓘ 放在同一个 `HStack` 里；分组标题用 `LitheSettingsSection(title:accessory:)`，把说明图标放在分组线左侧。
- 常驻显示只保留用户需要立刻看到的内容：错误、警告、保存成功/失败、空态、加载状态和当前生效值。例如“Agent 任务会被直接结束”这类风险提示、“No remembered choices” 和 Git 配置的当前生效值都不收起。
- 说明文本继续使用原有的英文 key 和 `Localizable.strings` 翻译。新增文案必须同时补中英文，不能在 `Text` 和提示里各写一份不同的说法。
- 设置搜索仍由 `SettingsSearchVocabulary` 负责，不依赖页面上是否渲染了说明文字。
- 行内控件靠右对齐：`SettingsView.row` 用 `LitheSettingsLabel`、`Spacer(minLength: 16)`、控件的顺序，让下拉框和步进器落在内容区右缘，避免右侧整片空白。标签和控件之间仍保留至少 16 pt，窗口变窄时先压缩空白，不压缩控件。
- 分组节奏只保留一处大间距：`LitheSettingsSection` 的分组标题 -> 内容间距 8 pt，分组上方 10 pt；页面级 `VStack` 间距 10 pt。不要在页面里再叠加说明文字留下的空行。
- 插件声明的设置摘要也使用 `LitheInfoTip`，与宿主设置的行模式一致。
- 编辑器字体页提供实时预览：示例代码使用当前选中字体和字号渲染；切换字体后旧字体保留约 2.5 秒，和新字体上下并列，随后淡出，方便比较字形。`accessibilityReduceMotion` 开启时取消动画。
- Git 行为配置行用 `ViewThatFits` 优先排成一行：设置名、当前生效值、下拉框、重置和应用按钮并排；`LitheSettingsSelect` 的触发宽度按该字段最长选项文案在 150–240 pt 内取值，避免短选项占着 220 pt 的空白框，长选项仍由 `expandsToFitOptions` 撑开弹层。窗口过窄时回退到第二行显示当前生效值，按钮保持完整。
- 运行时的生效值不再用一整行等宽文本：`EffectiveRuntimeLabel` 用卡片展示模式徽标、来源、运行时名称和可选择复制的路径，警告与错误使用同一卡片形状和警示色。
- Git 标签继承回显只消费 Core 的规范化布尔值：Core 用 Git 自己的 `--type=bool --get` 解释 `fetch.pruneTags` 与远程覆盖，识别 `yes/on/1`、无值和假值等写法；远程显式假值仍优先于全局真值。选中文件的原始编辑值不变，避免保存时因规范化导致误报冲突。所有远程模式下 Fetch 会跳过 `remote.<name>.skipFetchAll` 为真的远程，标签回显也必须排除它们；Core 同样用 Git 布尔解析归一化该键，显式选中某个远程时不受 skipFetchAll 影响。不要在 Swift 再写一份布尔解析器，否则界面会与真实 fetch 行为漂移。
- Git 身份输入框回显当前生效值（包括继承值），保存按钮只在草稿与显示值不同时启用；清除覆盖后输入框回到继承的生效值。这样用户看到的就是 Git 实际会使用的值，不需要从下方的小字里对照。
- Maven 的 `settings.xml` 与 `Local Repository` 输入框在未设置覆盖时，用有效路径作为占位文本：先看已配置值，再看 `~/.m2/settings.xml`、Maven 安装的 `conf/settings.xml` 和 `~/.m2/repository`；都不存在时显示“Not found”，不再显示无信息量的“Automatic”。
- Agent 预检把版本、路径和安装来源拆成结构化 `Detail`，用带分隔线的内嵌小表展示；`message` 保留为纯文本诊断源，测试和错误文案不受影响。状态从裸 `PASS` 文本改成带图标的胶囊徽标。
- MCP 页面改成“标题/状态徽标 + 状态卡 + 项目权限 + Agent 配置”的短序列，安全说明收进 header 的 ⓘ；启用/关闭与复制配置在状态卡完成，配置 JSON 放在独立代码块里。
- 运行配置编辑对话框沿用同一套语言：标题栏用运行时图标和类型/生效来源胶囊取代“配置”区里的纯文本行；保存范围、项目环境继承、覆盖说明和环境变量格式都收进 ⓘ；分区标题、分段控件、复选框和输入框复用设置页共享控件，底部按钮使用共享主/次按钮样式。项目环境改为可点击的整行入口，运行目录输入框和选择按钮保持一行。
- `LitheInfoTip` 的悬停计时器改成引用类型，悬停进入/离开不再触发页面重新求值；下拉弹层只在 `isPresented` 时安装锚点，避免设置页上几十个常驻 `NSViewRepresentable` 增加布局开销。 延迟创建的锚点首次更新可能尚未进入窗口，不能仅在 `updateNSView` 中尝试显示，否则图标变蓝但说明缺失；共享 `LitheDropdownPopover` 在锚点进入窗口后检查当前打开状态并重新请求显示，移除时仍取消待显示请求并关闭弹层。

### 正确做法

```swift
row("Language", info: "The interface language changes immediately. English is the default.") {
    LitheSettingsSelect(selection: $settings.language, ...)
}
```

### 不要这样做

- 不要为每个页面另写一个悬停计时器或自制 tooltip；延迟、固定和键盘行为应只由 `LitheInfoTip` 拥有。
- 不要把安全警告、失败信息或当前状态塞进 ⓘ；用户不悬停也必须能看到它们。
- 不要在收起说明后留下一个空的分组或丢失可检索词；设置仍要能被搜索到。

## 考虑过的备选方案

### 保留说明但降低字号和对比度

仍然是常驻文字，只是更淡；页面密度没有下降，而且会进一步削弱可读性，所以没有采用。

### 使用系统 `.help()` tooltip

`help(_:)` 的延迟、外观和关闭行为由 macOS 决定，无法点击固定，也无法和设置页的鼠标反馈保持一致；已有的 `LitheInfoTip` 更符合产品要求。

### 只改截图中的三个页面

Issue 举的是通用、Git 和 Agent 管理三个页面，但同类常驻说明还出现在终端、Git 配置项、Agent 供应商、AI 提交、更新和插件设置页面。只改三个页面会让同一设置窗口出现两套说明方式，所以同一批只收起纯解释性文案，状态信息保持原样。

### 只收紧说明间距，不改控件对齐

删掉说明后只缩小页面间距仍会在右侧留下整片空白，因为控件按内容宽度紧跟在标签后面。采用“标签靠左、控件靠右”的两列行布局才能把内容区的宽度用起来；代价是窗口非常宽时标签和控件距离较远，所以设置窗口仍保留现有的最小宽度和可调分栏。

## 后果

- 收益：设置页默认只保留控件和标签，用户修改设置时不必先阅读整段说明；需要解释时仍能通过悬停、点击或键盘获得完整文案；控件靠右后右侧不再是大片空白，分组间距也更紧凑。
- 代价：说明不再一眼可见，首次使用者需要主动发现 ⓘ；读屏用户依赖 `accessibilityHint`，实机验收必须覆盖 VoiceOver。字体预览会在切换后短暂多出一行，属于有意的对比效果。
- 后续新增设置时，纯说明应直接放进 `info`，不要重新引入常驻小字；错误和状态文案仍要常驻。

## 验证

- `./scripts/test-macos.sh --filter ContextMenuCoverageTests`：深浅主题下，已请求打开的弹层先在窗口外创建，再挂载锚点，必须自动显示；移除锚点必须关闭。

- `./scripts/test-macos.sh --filter GitSettingsPresentationTests` 与 `cargo test --manifest-path rust/Cargo.toml -p lithe-core git::configuration::`（Git 布尔等价写法、无值/空值、原始编辑值不变、远程覆盖以及 prune/all/none/reachable 回显）
- `./scripts/test-macos.sh --filter SettingsSearchVocabularyTests`
- `./scripts/test-macos.sh --filter SettingsSidebarLayoutTests`
- `./scripts/verify-agent-notes.sh`
- 实机打开设置通用、Git 和 Agents 页：默认只显示标签和 ⓘ；悬停约半秒出现说明，移开关闭；点击图标固定；用 Tab 聚焦后 Space/Return 打开；错误、警告和空态仍然直接可见。
- 实机打开编辑器页：下拉框和步进器贴内容区右缘；切换字体后旧字体和新字体并列显示约 2.5 秒再淡出；调整字号时预览同步变化。
- 实机打开 Git 行为与配置：设置名、当前生效值、下拉框和重置/应用按钮在同一行，短选项下拉框宽度收窄；缩窄窗口后当前生效值换行但按钮不被裁切。
- 实机打开 Git 身份页：没有仓库覆盖时输入框回显当前生效的姓名和邮箱，保存按钮保持禁用；修改后保存、再清除覆盖，输入框回到继承值。
- 实机打开项目 JDK 与 Maven：生效运行时显示为卡片，长路径可选中并通过悬停查看完整路径；子项目页同样显示继承关系。
- 实机打开 Agents 详情：勾选 Node.js、npm 或 CLI 检查后显示版本/路径/安装来源小表，PASS/WARN/FAIL 为带图标胶囊；失败说明仍直接可见。
- 实机打开 MCP 配置：状态卡、项目权限和 Agent 配置分区清楚，开启后出现配置代码块，关闭后按钮回到 Enable。
- 实机打开运行配置编辑对话框：标题栏显示运行时图标、类型/来源胶囊和完整配置名；保存范围与 Maven 测试选项使用共享分段控件；项目环境入口整行可点击；说明默认收起为 ⓘ；路径输入、环境变量编辑器和底部保存/取消按钮与设置页样式一致。
- 实机反复在多组 ⓘ 之间移动指针：不出现页面跳动或明显掉帧；悬停约半秒才打开说明。
- 实机打开插件详情的设置区：说明默认收起为 ⓘ，数值和下拉控件保持可编辑。

## 适用范围

- `macos/Sources/Lithe/Views/Components/LitheInfoTip.swift`
- `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
- `macos/Sources/Lithe/Views/App/GitExecutionSettingsView.swift`
- `macos/Sources/Lithe/Views/App/GitFetchSettingsView.swift`
- `macos/Sources/Lithe/Views/App/GitIdentitySettingsView.swift`
- `macos/Sources/Lithe/Views/App/PluginSettingsSection.swift`
- `macos/Sources/Lithe/Views/App/EffectiveRuntimeLabel.swift`
- `macos/Sources/Lithe/Views/App/McpSettingsView.swift`
- `macos/Sources/Lithe/Application/Features/AgentSetupDiagnostics.swift`
- `macos/Sources/LitheGitModule/Application/GitRepositorySetupFeatureModel.swift`
- `macos/Sources/Lithe/Views/Agent/AgentPanelSettingsView.swift`
- `macos/Sources/Lithe/Views/Agent/AgentProviderConfigurationView.swift`
- `macos/Sources/Lithe/Views/Run/JavaRunConfigurationEditorView.swift`
- `macos/Resources/en.lproj/Localizable.strings`
- `macos/Resources/zh-Hans.lproj/Localizable.strings`
