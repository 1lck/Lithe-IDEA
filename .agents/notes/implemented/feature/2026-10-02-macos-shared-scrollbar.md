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
  rail 为 14pt 加 2pt gap、2pt 最小标记区，Diff 左 rail 镜像。
  `DiffDrawUtil.DiffStripeMarkerTextAttributes` 没有启用 thin：Diff 使用 14pt 宽标记，
  右侧 x=4、左侧 x=0；之前把它画成靠代码的 2pt 细条是错误的。
  标记对应末个修改行的 Y，不包含下一行；单行/空范围至少 2pt。
  overlay thumb 7→10pt 经 Buttonless 的扩展和 painter 内边距深色得到 9→12pt 胶囊；浅色 fill 与 border 相同，上游省略边框并 inset 2pt，得到 7→10pt。
  `IslandSchemeDark.xml` 覆盖滑块为 #FFFFFF26/#FFFFFF4D；不能套用普通滚动区的灰色。
- `LitheScrollViewChrome.CompactScroller` 绘制原生普通入口；
  `LitheScrollBarPaint` 是同一 owner 的绘制适配器，用于保留 Diff 横向拖动动作。
  双栏和单栏的 `DiffStripeScroller` 复用原生 knob 几何与共享绘制，先绘制标记再画滑块。
  用户要求 Diff 只保留右侧拖动滑块，左侧仍显示可点击的差异标记；这是 Lithe
  的选择，并非 IDEA 默认隐藏左侧滑块。可见轨道自己接收完整按下/拖动/松开事件，
  按原生 knobSlot 的有效行程映射正文位置。不能把按下转发给 alpha=0 的子 scroller，
  否则后续事件不属于该控件，出现滑块可见但拖不动。命中 thumb 优先开始拖动，
  其余区域再判断差异标记或翻页，保留无障碍滚动与轨道滚轮行为。
  底部横向滑块也使用原生命中视图，避免透明 SwiftUI 手势层被 NSTextView 截获；
  保留原有尺寸、两侧同步偏移、共享绘制和事件合并。两个方向都要验证真实窗口
  拖动导致正文位置变化，不能用直接调用滚动方法代替。
  标记遵循 `offsetsToYPositions`：短文件保留实际 Y 坐标，长文件才压缩到轨道长度，
  避免没有滚动溢出时将一行修改拉伸成很长的标记。宽标记在滑块下面绘制，
  滑块覆盖时颜色自然混合，不另加轮廓、间隔或圆角。
  hover 重绘仅在原生控件内，不发布滚动状态到父级，也不重建正文缓存。
  Diff 布局切换时由 `DiffScrollSynchronization.configure` 直接替换已挂载的左右轨道标记；
  同步对象身份不变时 SwiftUI 可能跳过 representable 更新，不能只靠该回调刷新标记。
  无差异布局同样清空旧标记，不通过重建整个 Diff 或重置滚动位置规避刷新。

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
自绘 Diff 轨道复用 AppKit 几何并自己跟踪事件，普通滚动条仍依赖原生跟踪；验证必须
通过真实窗口发送拖动事件并检查 NSScrollView 偏移，不能只调用绘制函数或滚动方法。

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
