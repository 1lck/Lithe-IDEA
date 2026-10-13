# Agent 笔记：Windows Git Log 与 Project 滚轮过渡

状态：已实现

## 先说结论

Windows Git Log 的分支树、提交列表、Commit Files 文件树和 Project 文件树使用同一个滚轮动画入口，按 IntelliJ
Community 的 Windows 默认时长和曲线逐帧移动视口。连续滚动累积目标，反向滚动
从眼前位置重新开始；键盘定位、滑块操作和卸载可以取消未完成的动画。
开发者应通过共享滚轮绑定开启动画，不要在业务页面逐帧更新 React 状态。

## 问题

两处列表原先都通过 `bindScrollContainerWheel` 直接写入 `scrollTop`。
这个入口解决了浏览器把滚轮交给裁剪行的问题，却让每次滚轮直接跳到新位置，
缺少 IDEA 的惯性过渡。提交列表同样存在该问题。

## 决策

参考本地 Community 修订 `fb72b4df43aba102479eb0502d20b03586b9c5b8`：

- 分支树由 `plugins/git4idea/backend/src/ui/branch/dashboard/BranchesDashboardTreeComponent.kt`
  调用 `ScrollPaneFactory.createScrollPane`；提交表格由
  `platform/vcs-log/impl/src/com/intellij/vcs/log/util/VcsLogUiUtil.java` 调用同一入口。
  Commit Files 的 `VcsLogChangesBrowser.kt` 继承的 `ChangesBrowserBase.java`
  也通过 `ScrollPaneFactory.createScrollPane` 创建文件树滚动区。
- `platform/platform-api/src/com/intellij/ui/components/JBScrollPane.java` 将普通滚轮
  交给 `ui/scroll/MouseWheelSmoothScroll.java`。其惯性动画器在同方向输入时累积
  目标并延长过渡，反向时用当前可见位置重新开始。
- `platform/editor-ui-api/src/com/intellij/ide/ui/UISettingsState.kt` 的 Windows 默认值为
  200ms、曲线编码 1684366536，解码为 `(0.5, 0.505, 0.5, 1)`。
  Lithe 复用现有 `motion` 库计算三次贝塞尔曲线，不新增动画依赖。

`ui/wheel-scroll-animation.ts` 负责单方向的位置、目标和可取消帧，
`ui/scroll-container-wheel.ts` 负责真实视口的事件绑定、滚轮单位换算和生命周期。
分支、提交列表与 `FileExplorerViewport` 显式开启 `smooth`；Commit Files 通过
共享 `ScrollArea` 的 `smoothWheelScroll` 显式启用同一动画；其他既有滚动区
保持原有默认行为。Project 的行呈现继续使用原有可见区计算和滚动事件合并，
没有在动画器里增加另一份树状态。Commit Files 继续测量实际行宽并保留双向滚动。
启用动画的 `ScrollArea` 在根容器捕获输入，但始终移动真实视口；文件行与旁边
的滚动条共用一个动画器，滚动条按下也取消未完成帧。Base UI 的滚动条 wheel
处理器会直接修改视口，且不检查 `defaultPrevented`；因此根容器消费事件后
还要停止传播，避免内部处理器再次跳到目标。不要再给同一滚动区挂上
直接跳动的覆盖层处理器或第二个动画器。Shift 滚轮在这些入口横向移动，原有触控板
横向位移也消费同一动画。

每帧只写真实视口位置，提交表格继续使用已有虚拟列表按可见区呈现。
当目标已到边界而动画尚未结束时，继续消费向外的滚轮，避免浏览器提前跳到
边界；真正到达边界后才允许滚轮交给外层。目标始终限制在当前滚动范围内。
按键、指针按下、文档隐藏和卸载取消帧；外部定位改变位置时，下一帧停止，
不把列表拉回旧位置。系统减少动态效果偏好开启时使用直接滚动。

正确做法：滚轮绑定 → 共享动画器 → 更新视口 → 已有虚拟列表呈现可见行。
不要这样做：滚轮事件 → 整页状态更新 → 为全部提交创建过渡控件。

本次对齐普通滚轮的过渡，不复刻 Java 运行时的触摸设备识别、远程会话和省电模式，
也不把弹窗打开、分组展开或提交选中改成淡入或缩放动画。

## 考虑过的备选方案

- 每次调用浏览器 `scrollTo({ behavior: "smooth" })`：曲线和时长由浏览器决定，
  连续输入的目标重算也不同，不能证明与上述 Community 行为一致。
- 在分支和提交组件各自实现动画：会产生两份曲线、边界和清理逻辑，未采用。
- 为所有共享滚动区默认开启：扩大到本次没有核对的页面，未采用。

## 后果

Git Log 与 Project 的滚轮过渡一致，保留分页、图谱布局、选择、焦点和业务读取。
代价是共享绑定要维护可取消帧；WebView2（Windows 内嵌浏览器）中的真实设备
事件和主观手感仍需产品验收，模拟 DOM 测试不能证明原生设备体验。

## 验证

- `.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`
- `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
  可用 `-FrontendTestPath` 限定下面两组滚轮测试及 Git Log 组件目录。
- `windows/tauri/src/ui/wheel-scroll-animation.test.ts` 使用可手动推进的时钟和帧队列，
  检查中间位置、200ms 结束、累计、反向、边界、外部定位和清理。
- `windows/tauri/src/ui/scroll-container-wheel.integration.test.ts` 检查真实绑定消费事件、
  两方向位移、按键/指针取消、减少动态效果和卸载；覆盖视口外的滚动条区域
  共享动画目标，以及拖动该区域取消惯性。
- `scripts/build-windows.ps1 -Configuration Release`、Windows Tauri Cargo 测试、
  `scripts/verify-windows-boundaries.ps1`、`scripts/verify-runtime-bundle-immutability.sh`、
  `node scripts/verify-agent-notes.mjs`、`node scripts/generate-platform-feature-matrix.mjs --check`。
- 产品验收：在分支树、长提交列表、Commit Files 和 Project 文件树中连续向下/向上滚轮，核对过渡、反向、
  顶底边界、分页保持位置、Shift 横向滚动、键盘定位、滑块拖动和关闭工具窗。
  在明暗主题下与上述 Community 修订的 Windows 默认动画比较。

## 适用范围

- `windows/tauri/src/ui/wheel-scroll-animation.ts`
- `windows/tauri/src/ui/scroll-container-wheel.ts`
- `windows/tauri/src/features/git/components/log/git-reference-tree.tsx`
- `windows/tauri/src/features/git/components/log/git-commit-table.tsx`
- `windows/tauri/src/features/file-explorer/components/file-explorer-viewport.tsx`

- `windows/tauri/src/ui/scroll-area.tsx`
- `windows/tauri/src/features/git/components/log/git-commit-file-tree.tsx`
