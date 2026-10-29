# Agent 笔记：macOS 隐藏标题栏窗口的原生全屏能力守卫

状态：已实现

## 先说结论

SwiftUI 的 `.windowStyle(.hiddenTitleBar)` 窗口在当前 macOS 工具链下默认被系统标记为
`fullScreenNone`（禁止原生全屏）。表现为：点击绿色交通灯按钮不会进入独立全屏
Space，而是在主桌面直接最大化；程序调用 `toggleFullScreen(_:)` 也会被静默拒绝。

修复位于 `macos/Sources/Lithe/Views/App/RootView.swift` 的
`WindowFullScreenCapabilityGuard`（NSViewRepresentable）与
`WindowFullScreenCapabilityView`（宿主 NSView）。它们挂在 `RootView` 的
background 上，因此欢迎页、项目工作台和独立文件三类主窗口都被覆盖。开发者新增
隐藏标题栏主窗口时不需要额外操作；如果将来绿色按钮又表现为"最大化"，先检查该
守卫是否仍然挂在窗口根视图上。

## 问题

用户报告：从 GitHub 下载的 v0.6.3 在项目工作台窗口点击绿色按钮后，窗口只在主
桌面最大化，无法进入 macOS 标准的独立全屏桌面（Space）。本地从源码构建的
debug 版本同样复现。

进程内探针确认了三个事实：

1. 窗口的 `collectionBehavior` 含 `fullScreenNone`（原始值 0x10200 =
   `FullScreenNone | Primary`），而全仓库源码从未设置过该标志，它来自
   SwiftUI 对 hiddenTitleBar 窗口的默认行为。
2. 绿色按钮的 target/action 在窗口创建时就被 AppKit 固化为私有的
   `_setNeedsZoom:`（最大化），而不是全屏窗口应有的 `toggleFullScreen:`。
3. 只要 `fullScreenNone` 还在，`toggleFullScreen(_:)` 会被静默拒绝。

一次性剥离 `fullScreenNone` 不够：SwiftUI 会在后续场景更新中反复重新设置该
标志。

## 决策

`WindowFullScreenCapabilityView` 挂在 `RootView` 的 background 上，承担三件事：

1. `viewDidMoveToWindow` 时订阅宿主窗口的
   `NSWindow.didUpdateNotification`。
2. 每个窗口 update 周期检查一次 `collectionBehavior`：若含 `fullScreenNone`
   则移除之，并补上 `fullScreenPrimary`。SwiftUI 反复设置，守卫就反复剥离；
   用户点击的瞬间标志位是干净的。
3. 剥离的同时把绿色按钮重接到
   `zoomButtonClicked(_:)`（先剥离再调用 `toggleFullScreen(_:)`），消除
   "按钮 action 已固化为最大化"与"点击瞬间标志位又被设置"两种竞争。

`viewDidMoveToWindow` 与 `NSWindow.didUpdateNotification` 的组合是刻意的：
不使用轮询，也不阻塞主线程；`contains(_:)` 位检查在每次窗口 update 中的开销
可以忽略。

进入原生全屏后 macOS 会隐藏红绿灯按钮，但工作台顶栏仍按普通窗口预留 83pt
（`WorkbenchTopBarMetrics.leadingInset`）的按钮空位，左上角出现一段空白。
`WindowFullScreenStateReader` 用同一套 `didUpdateNotification` 机制把窗口的
全屏状态同步到 SwiftUI（`@State isWindowFullScreen`），顶栏的全屏态下将
leading padding 降为 0，退出全屏后自动恢复预留，行为对齐 IDEA。

## 考虑过的备选方案

- 在 `LitheWindowCoordinator.attach` 中做一次性归一化：已否决。实测 SwiftUI
  会反复重设标志，一次性剥离无效；而且欢迎页窗口没有活跃 session，根本不会
  创建 coordinator。
- 剥离标志但不重接绿色按钮：已否决。按钮的 target/action 是窗口创建时由
  AppKit 配置并缓存的，`collectionBehavior` 变化不会触发重新求值，点击仍然是
  最大化。
- 放弃 `.windowStyle(.hiddenTitleBar)` 改用普通标题栏：已否决。会破坏整套
  IDEA 风格的窗口视觉与自定义顶栏布局，代价远大于收益。

## 后果

收益：主窗口恢复 macOS 标准全屏体验（独立 Space、菜单栏/Dock 自动隐藏），
行为对齐 IntelliJ IDEA；对系统未来行为变化保持钝感——若 SwiftUI 不再设置
`fullScreenNone`，守卫的 `contains` 检查自然变成空操作。

代价与风险：绿色按钮的 target/action 被接管为
`WindowFullScreenCapabilityView.zoomButtonClicked(_:)`。视图与按钮共享窗口的
生命周期，非零引用的 `NSButton.target` 不会悬垂；option 点击绿色按钮的窗口
缩放行为仍由按钮子类在 mouseDown 中处理，不受影响。

## 验证

- 单元测试 `macos/Tests/LitheTests/WindowFullScreenCapabilityGuardTests.swift`
  覆盖：安装即剥离、按钮重接、SwiftUI 重设后再次剥离（通过
  `NSWindow.didUpdateNotification` 同步触发，无轮询、无实时等待）。
- 手工验证：启动应用，点击主窗口绿色按钮，确认进入独立全屏 Space（窗口
  `styleMask` 出现 `.fullScreen`、frame 覆盖整屏），再次点击或按 Esc 退出后
  窗口回到原位置。
- 回归检查：`./scripts/macos/test/test-macos.sh`（CI 执行）；本地受 Swift 6.2.4 工具链
  类型检查超时限制无法完整编译时，以 CI 结果为准。

## 适用范围

- `macos/Sources/Lithe/Views/App/RootView.swift`
- `macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`（工作台顶栏的全屏态留白）
- `macos/Tests/LitheTests/WindowFullScreenCapabilityGuardTests.swift`
- 仅覆盖经由 `RootView` 呈现的主窗口（欢迎页、项目工作台、独立文件窗口）。
  设置窗口与软件更新窗口不经过 `RootView`，不受本守卫影响。
