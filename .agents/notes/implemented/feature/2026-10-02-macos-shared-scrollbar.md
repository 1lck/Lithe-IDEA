# Agent 笔记：macOS 共享滚动条与 Diff 编辑器覆盖

状态：已实现

## 先说结论

macOS 已使用 `litheScrollViewChrome` 的滚动区默认共用 IDEA 滚动条绘制。
全局 owner 是 `LitheScrollBarStyle`，位于 `LitheScrollViewChrome.swift`。
普通滚动区与 Diff 共用入口，编辑器用途保留 IDEA 专用的滑块颜色、镜像位置和变更标记；
页面只提供位置、比例和原有动作。Windows 与网页滚动条不在本次范围内。

## 问题

旧 compact 滑块使用局部 5pt 宽度和 #434343，Diff 又将缩略标记画在滑块上。
横向滑块另取通用 divider、secondaryText 和蓝色拖动态，无法随共享 owner 修正。

## 决策

依据 IDEA Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：

- `ScrollBarPainter.java` 和 `MacScrollBarUI.kt` 是全局绘制与 macOS 几何入口。
  胶囊端部、1pt 内侧边框、Mac 灰色透明度及透明轨道 hover 取它们的 token。
  保留原有 AppKit 滚动、自动隐藏、页点击和辅助功能；没有替换滚动机制。
- `JBScrollPane.getThumbPainter` 在 Mac 选择 opaque thumb token；浅色使用黑色
  #00000033/#00000080，深色普通区为 #80808059/#8080808C。
  持久轨道的普通/hover 底色透明，浮层轨道 hover 为 #8080801A；底层表面归宿主所有。
- `EditorMarkupModelImpl.MyErrorPanel` 覆盖编辑器轨道绘制，保留编辑器背景。
  rail 为 14pt 加 2pt gap、2pt 最小标记区；Diff 左 rail 镜像，2pt 变更标记在靠代码一侧。
  overlay thumb 7→10pt 经 Buttonless 的扩展和 painter 内边距深色得到 9→12pt 胶囊；浅色 fill 与 border 相同，上游省略边框并 inset 2pt，得到 7→10pt。
  `IslandSchemeDark.xml` 覆盖滑块为 #FFFFFF26/#FFFFFF4D；不能套用普通滚动区的灰色。
- `LitheScrollViewChrome.CompactScroller` 绘制原生普通入口；
  `LitheScrollBarPaint` 是同一 owner 的绘制适配器，用于保留 Diff 横向拖动动作。
  双栏和单栏的 `DiffStripeScroller` 保留原生 knob 跟踪，先绘制标记再画滑块。
  标记遵循 `offsetsToYPositions`：短文件保留实际 Y 坐标，长文件才压缩到轨道长度，
  避免没有滚动溢出时将一行修改拉伸成很长的标记。
  hover 重绘仅在原生控件内，不发布滚动状态到父级，也不重建正文缓存。

共享调用者包括 Project/Dependencies 树、Settings、Keyboard Shortcuts、Project Runtime、
LSP Control Center/Language Server Setup、Git Log/Console/Worktrees，以及 Diff 单栏/双栏。
未来原生页面复用 `litheScrollViewChrome`；不要在页面再选择滑块颜色或拖动高亮。
无需缩略标记的页面不引入 Diff 的标记区域。

## 考虑过的备选方案

- 各页面按截图重画：会继续产生互不一致的轨道、透明度和交互状态，未采用。
- 修改系统 NSScroller 全局 appearance 或强制所有编辑器采用普通区配色：会覆盖
  用户滚动设置或丢失编辑器主题覆盖，未采用。
- 将每次 hover/scroll 发送给 SwiftUI 父视图：增加连续滚动期间的布局重算，未采用。

## 后果

共享入口修正会影响列出的调用者，颜色不再依赖各页面的文字或分隔线 token。
代价是需要维护 product/editor 两种用途；它们来自上游的实际覆盖，不能合成一个颜色。
自绘轨道仍依赖 AppKit 原生跟踪，验证必须捕获实际 NSScrollView 而不只调用绘制函数。

## 验证

运行 `test-stability-macos.sh` 的 `LitheScrollBarStyleTests`、`LitheScrollWheelRoutingTests`、
`DiffAppearanceTests` 与 `DiffScrollSynchronizationTests`。深浅色真实 NSScrollView 捕获
验证共享滑块颜色、rail 宽度、hover 不改变位置；检查左右镜像和标记点击。
Diff 替换多一行/反向删除用例检查同一个配对范围、源行号和原文，已有 1,200 行组件
回归继续检查连续尺寸变化不重建文本。组件通过不能当作完整应用视觉或流畅度验收。

## 适用范围

- `macos/Sources/Lithe/Views/Components/LitheScrollViewChrome.swift`
- `macos/Sources/Lithe/Views/Diff/DiffScrollSynchronization.swift`
- `macos/Sources/Lithe/Views/Diff/DiffHorizontalScrollSupport.swift`
- `macos/Tests/LitheTests/LitheScrollBarStyleTests.swift`
