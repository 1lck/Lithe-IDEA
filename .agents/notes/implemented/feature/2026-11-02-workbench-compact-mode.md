# Agent 笔记：工作台紧凑模式

状态：已实现

## 先说结论

紧凑模式通过缩小工具栏、工具窗口标题栏、编辑器标签和两侧活动栏，给代码留出更多空间。
它是 Lithe 的应用级外观偏好，默认关闭，切换后立即生效并保存；不改写代码字号、文件树行高或用户拖动保存的面板尺寸。
新增工作台控件应读取共享尺寸，不能各自判断紧凑模式后再写一套高度。

## 问题

Issue #1530 希望提供 IDEA 的紧凑界面。仅缩小某个侧栏、隐藏菜单或整体缩放网页，都不能稳定释放工作区空间；整体缩放还会影响代码阅读。
macOS 的工具面板有独立且保留的 SwiftUI 宿主，仅重绘主窗口不能保证所有面板立即更新。

## 决策

- 两端在“外观与行为”的常规外观设置中提供“紧凑模式”，说明放在信息提示中，使用共享中英文词条。
  偏好保存在现有应用设置存储中，不读写外部工具配置，不写安装资源，因此不影响代码签名或 Sparkle 增量更新。
- Windows 沿用根节点属性与 CSS 变量（层叠样式表的共享尺寸值），紧凑覆盖在已有聚焦/舒适密度之后。
  开关不改写原密度选择，关闭后恢复；扩展活动栏仍使用用户宽度，收起的活动栏才从 38px 缩至 32px。
- macOS 沿用 `AppThemeRuntime` 的线程安全快照，并通过 Combine（项目已有的状态变更通知框架）发布紧凑状态变化。
  读取共享尺寸的视图、按钮样式与标签修饰器用 `@ObservedObject` 直接订阅，独立保留的工具宿主同样收到通知；
  不重建编辑器、不按视图身份重置会话，重复赋相同值不发布通知。原生布局读取仍受锁保护。
  Terminal、Commit、Git Log、Run、Debug、Tests、Problems 和 VCS 的自有标签标题栏同样读取共享高度，不能继续保留固定 41pt。
- 保留平台差异：macOS 主工具栏 40→32pt、工具标题栏 41→32pt、标签条 36→28pt；Windows 主工具栏 40→32px、工具标题栏 36→28px、标签条随标题栏缩小。
  两端活动按钮 30→24、活动图标 20→16，原生菜单与普通 16pt 工具图标保留原资源，不改几何或描边。
  这些是 Lithe 的平台适配尺寸，不声称逐像素复制 IDEA。

上游行为参考 JetBrains 官方 [Appearance / Compact mode](https://www.jetbrains.com/help/idea/appearance.html)。
源码参考 Community `536da82a2cbce90820cbb0c158d91e78cda75d82` 的
[`platform/platform-resources/src/themes/expUI/expUI_dark.theme.json`](https://github.com/JetBrains/intellij-community/blob/536da82a2cbce90820cbb0c158d91e78cda75d82/platform/platform-resources/src/themes/expUI/expUI_dark.theme.json)，
其中主工具栏提供 `preferredSize.compact`；Lithe 根据现有原生窗口装饰保留自己的最小高度。

正确做法：工具窗口标题读取 `LitheTheme.Metrics` 或 `--lithe-pane-header-height`。
不要对整个工作台使用缩放，也不要切换时写回侧栏宽度、项目树行高或编辑器配置。

## 考虑过的备选方案

- 把 Windows 的聚焦密度直接改名：改变已有偏好的含义，且不能解决 macOS 和外侧活动栏，因此保留原设置。
- 全局缩放或减小字体：实现较短，但影响代码、终端、弹窗和原生命中区，不采用。
- 只在主窗口监听设置后重建所有工具面板：可能丢失输入、焦点和会话状态，因此由尺寸消费者直接订阅变更。
- 使用 `@Observable` 自动追踪读取：该框架从 macOS 14 起可用，而产品最低支持 macOS 13，
  会使 Swift 测试、插件验证与 Release 构建在编译阶段失败；因此复用已有 Combine，不提高最低系统要求或引入回移植依赖。

## 后果

工作台留白减少，关闭开关即可恢复原布局；既有用户没有默认视觉变化。
控件命中区更小，适合偏好信息密度的用户；新控件必须消费共享尺寸才能跟随切换。
文件树已有单独行高偏好，本功能不覆盖它；不是每一种业务表格都强制使用统一行高。

## 验证

- Windows：`./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/settings/lib/compact-mode.test.ts`，检查旧设置、非法值、保存重读、即时属性更新及其他偏好不变。
- macOS：`./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter CompactModeTests`，检查持久化、重置、变更通知去重、控件边界与关闭后的恢复；深浅主题下两个保留的原生标题宿主无需替换根视图即可更新高度。
- 真实产品在深浅主题、多个窗口、Project/Commit/Terminal/Agent 打开时反复切换；确认标题、标签、按钮和图标不裁切，窗口拖动、菜单、活动项、面板拖动、编辑器滚动与焦点正常。
- 重启确认设置保留；开启前后对照代码字号、文件树行高和自定义面板宽度；关闭后恢复原密度。
- 运行 `node scripts/i18n/generate-i18n.mjs --check`、`node scripts/i18n/verify-app-language-localization.mjs`、`./scripts/agent-notes/verify-agent-notes.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh` 和功能矩阵检查。平台运行时验证状态以功能矩阵为准。

## 适用范围

- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Views/Components/LitheToolWindowHeader.swift`
- `macos/Sources/Lithe/Views/Components/LitheToolWindowTabStyle.swift`
- `macos/Sources/Lithe/Views/Editor/EditorAreaView.swift`
- `macos/Sources/Lithe/Views/Terminal/TerminalView.swift`
- `macos/Sources/Lithe/Views/Git/ChangesSidebarView.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `macos/Sources/Lithe/Views/Run/RunView.swift`
- `macos/Sources/Lithe/Views/Debug/GenericDebugView.swift`
- `macos/Sources/Lithe/Views/Language/LanguageTestsView.swift`
- `macos/Sources/Lithe/Views/Language/JavaProblemsView.swift`
- `macos/Sources/Lithe/Views/Vcs/VcsProviderToolWindowView.swift`
- `macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`
- `windows/tauri/src/features/settings/`
- `windows/tauri/src/styles/theme.css`
