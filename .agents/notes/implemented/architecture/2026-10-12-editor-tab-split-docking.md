# Agent 笔记：编辑器标签分屏与空状态提示

状态：已实现

## 先说结论

用户把标签拖到编辑区边缘后，工作台将该标签移入新的编辑分组；每组有自己的标签和选中内容。
文档、媒体和终端仍由原功能对象维护，分屏不复制文件或重新创建会话。
Git 的工作区、工作树、目录、分支、历史提交和 Stash/Shelf 比较各自使用独立的普通 Diff 标签，不再覆盖其他比较或绕过标签栏。
空编辑区只展示已接入的全局搜索、项目内查找及当前快捷键，不展示尚未实现的最近文件和导航栏操作。

## 问题

旧标签只能重排，右键分屏把两个文档塞进同一编辑器，无法提供独立标签组或底部分屏。
旧空状态面向外部 Diff 的文案出现在普通工作区，不能提示实际可用的操作。

## 决策

编辑分组的二叉布局树（每次把一组拆成两组）与标签位置、选中项由已有 `EditorTabOrderFeatureModel` 管理。
普通分组编辑器的 Monaco 原生容器按项目及文档复用；同一个文档在组间移动时重新挂载原 WebView，不重建其 Monaco 模型，保留撤销/重做栈和视图状态。SwiftUI 内容身份也按文档固定，避免切换标签时继续持有另一文档的 StateObject。移动文件前通过原文档的同步屏障排空输入，失败保留原布局，较旧的待处理落点不能覆盖新请求；解绑时检查同步所有者，不能清除另一组已接管的保存回调。
跨文件 Rename / Code Action 读取其他文档快照前，先调用目标文档原有同步屏障；注册编辑镜像只能观察文本变化，不能接管目标文档保存与关闭的同步回调。目标 WebView 继续通过已有 replace 的 pushEditOperations 接收修改，保留自身撤销栈。标签关闭菜单按所属组当前混合标签顺序计算 Other / Left / Right / All，仅关闭文档类型，忽略终端等其他类型。
文档容器只绑定自己的文档，旧挂载退出不能移除目标容器中的编辑器。后台光标事件及没有原生 first responder 的迟到焦点事件不能切换活动组。分组选择变化后通过公开 DOM blur 和 Monaco focus 同步正文焦点，避免不同 WebView 同时保留闪烁光标。
异步挂载与正文更新共用完整的活动文档判断：除文档 ID 外，还检查所属组的选中项，并排除活动终端、媒体、数据库和 Diff；挂载排队后选中终端，也不能由迟到回调抢回 first responder。右键分屏菜单与 drop 共用 canDrop 判断，当前组只有一个标签时禁用；文档与终端等混合多标签组仍可分屏。
关闭或移走最后一个标签后合并空组；新标签进入当前聚焦的组。文件和会话生命周期不交给布局树。
分隔器继续使用 `LitheSplitPaneView`，尺寸变化留在局部视图，只在释放后提交比例。
分组是当前项目会话状态，本次不增加重启恢复编辑分屏或跨窗口传输。
与数据库 PR #17 集成后，数据库标签继续使用其共享工作区和查询状态，统一保留在同一个编辑分组，只允许组内重排；不能直接开放跨组移动，否则两个分组会显示同一数据库上下文。数据库工具窗口及 Services 工具窗口仍支持停靠分组。

### Git Diff 也属于普通编辑标签

所有仓库比较入口通过 `AppModel` 的共享标签动作进入 `EditorTabItem.repositoryDiff(UUID)`。
同一个仓库、文件和版本组合再次打开时切回已有标签；不同文件、不同提交以及不同类型的比较可以并存。
工作区文件身份不包含暂存状态，暂存或后台刷新不会额外产生标签。仓库路径参与身份，避免嵌套仓库同名文件互相覆盖。

每个标签由 `GitRepositoryDiffSession` 单独拥有比较内容、加载状态、文件列表、空白符选项和请求代次。
`GitFeatureModel` 仍共享 Git 服务、监听和写入工作流，不为标签复制整套功能模型。
异步读取只回写捕获的会话，关闭一个标签只使该会话失效，不取消其他标签，也不在结果到达时抢焦点。
Git Log 的当前提交选择与已打开的历史比较分开，上一文件/下一文件使用比较会话自己的提交文件快照。

状态刷新对已打开的工作区比较遵守三条规则。第一，只有本次刷新真正读取过状态的仓库才能证明文件已干净：
链接工作树的标签不在工作区快照里，它的缺席什么也说明不了，标签保留内容，由该工作树自己的状态读取
（`refreshWorktreeChanges`）决定是否关闭。第二，内容没变就不触碰会话：每次给 `@Published` 属性赋值都会
重绘并丢掉滚动位置，所以改用 `GitRepositoryDiffSession.updateDocument` 比较后再发布；与 HEAD 的比较只有
行、没有补丁文本，不能只比较补丁。第三，目录比较刷新就地更新，保留已有行直到新行不同，不清空也不闪现加载态。
保存更改（Stash/Shelf）比较在打开标签前就校验快照属于当前仓库并包含该版本与文件，无效请求不留下空标签。

编辑分组按标签 ID 呈现自己的会话，不读取全局当前比较来绘制另一个分组。
同组切换时保留仍打开的 Diff 内容宿主，保留搜索、显示方式及原生滚动状态；隐藏宿主不接受点击或辅助功能访问。
标签移动、重排和分屏继续走普通编辑分组；关闭时释放会话、缓冲区与内容宿主，工作区退出关闭全部比较。
整文件和块级写入显式使用当前显示的更改对象，不能在非活动分组操作时误写全局选中的另一文件。
关闭按钮、设置菜单和关闭当前项共用按 ID 的关闭动作，后台 Diff 不截获普通文件的关闭命令。

正确做法：打开 A.swift 的工作区 Diff，再打开 B.swift 和 A.swift 的历史提交 Diff，三个标签同时保留；把两个标签分屏后分别浏览。
不要这样做：只给标签分配 UUID，却让它们都读写 `GitFeatureModel.diffRows`，或为每个标签创建新的 Git 监听和仓库服务。

依据 IDEA Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：

- `platform/platform-api/src/com/intellij/ui/tabs/TabsUtil.java` 使用边缘梯形检测，`platform/util/resources/misc/registry.properties` 的 `ide.tabbedPane.dragToSplitRatio` 默认值为 0.2。左右、上下落点覆盖对应半区；标签栏继续处理重排。
- `platform/platform-impl/src/com/intellij/openapi/fileEditor/impl/DockableEditorTabbedContainer.kt` 在松开时按方向创建分屏，`MyDropAreaPainter` 只填充 `DragAndDrop.areaBackground`，不画截图标注的红框。
- `platform/platform-api/src/com/intellij/ui/tabs/impl/JBTabsImpl.kt` 的 `startDropOver` 为浮动预览创建图标和标题副本；`platform/platform-impl/src/com/intellij/ui/docking/impl/DockManagerImpl.kt` 使用非激活浮动窗口及 90% 不透明度。Lithe 单独绘制灰色浮动标签，不截取活动蓝底或关闭按钮；图标复用来源已解析的 IDEA 资源。
- `platform/platform-impl/src/com/intellij/openapi/fileEditor/impl/EditorEmptyTextPainter.java` 使用 16pt 普通字号、1.8 倍字体行距，首行基线位于高度的 37.5%；`Label.infoForeground` 在 Islands 全局覆盖中解析为 #73767C，`Shortcut.foreground` 深/浅为 #9FA2A8 / #5F6269。
- `ManyIslandsDark.theme.json` 将编辑拖放区域设为 #FFFFFF10；浅色继承 #3D7DCC33。工具窗口的蓝色停靠区域是另一套 token，不能混用。

根编辑区使用稳定的局部状态持有落点几何；不能在每次父视图重建时重新创建被观察对象，否则几何未改变时不会再发布偏好，真实预览会丢失落点。
每个标签组只安装一个原生鼠标监听，完整处理标签按下、拖动和松开，避免 SwiftUI 进入局部鼠标跟踪后漏接跨原生编辑器的快速拖动。
关闭按钮、Control 点击和终端原生拖放仍交给原控件；普通点击、辅助功能动作和原右键菜单继续走现有选择动作。
鼠标监听按原生 `visibleRect`（经祖先与滚动视口裁剪后的可见区域）命中，隐藏标签不能截获相邻分组点击。分组记录实际标签栏矩形，完整排除第二、第三行再检测正文边缘，不能假设单行 36pt 高度。正文焦点进入时调用完整文档选择动作，清除终端/数据库活动标志；保留的文档 ID 不能代替当前活动项判断。
预览几何在拖动开始冻结，鼠标移动只移动原生面板；目标改变才发布临时半区。
Esc、来源卸载和取消均清理面板；无效落点不改布局。焦点进入另一组文件时，菜单命令同步作用于该文件。

正确做法：拖动第二个文件到右侧后，第一组仍显示第一个文件，第二组显示原第二个文档对象。
不要这样做：为新组重新打开文件，或只把同一个全局活动文档重复画两次。

## 考虑过的备选方案

- 继续使用旧 `secondaryDocument` 右键分栏：无法提供每组标签、底部分屏和组间移动，因此替换这一呈现入口。
- 直接引入 IDEA Swing 停靠容器：与 SwiftUI/AppKit 技术栈不同。本次复用其检测、预览及释放提交规则，原生布局仍走现有容器。
- 用 SwiftUI 位移移动整张标签：会受标签栏裁剪且参与连续布局；保留现有原生浮动预览。
- 一个可复用的 Diff 预览标签：不能同时对照多个文件与版本，用户明确要求多标签，因此拆分比较会话而不是复用一个缓冲区。
- 每标签复制整个 Git 功能模型：会重复仓库监听、服务和写入状态；只拆分比较内容和加载生命周期。

## 后果

收益是编辑区可以独立选择不同文件，并连续拆分或把标签移回另一组。
代价是打开的 Diff 保留各自缓冲区和原生内容宿主，资源随打开标签数增长，关闭即释放；活动文件与每组显示内容必须区分；当前树不承担跨窗口传输或重启恢复。
代价是每个已访问且仍打开的文档保留一个 WebView，资源随此类文档数量增长；关闭文档后随文档持有的同步回调一起释放，缓存只持弱引用。当前不序列化 Monaco 私有撤销栈，也不制造另一套撤销模型；大量标签的资源预算若不足，后续应采用共享 Monaco 工作台编辑器网格。视口变小时滚动位置允许 Monaco 按可见范围正常限制。
Windows 的既有分栏实现不受此次 macOS 呈现改动影响，完整两端视觉验收仍在矩阵中保留 pending。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter EditorTabOrderFeatureModelTests`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- 原生事件检查右侧、底部半区、释放提交、Esc 取消、重排、关闭与焦点；实机预览另检查真实字体资源、代码输入、灰色浮动标签及分隔器调整。
- `EditorTabOrderFeatureModelTests` 对工作区、目录、分支/引用、历史、保存更改、冲突与行标记入口在深浅主题下挂载原生编辑分组，检查普通标签、切换保留、分屏与共享关闭；`GitModuleTests` 检查独立会话并发加载、关闭一个会话、刷新及迟到结果隔离。组件验证不替代完整产品与 Windows 实机验收。

## 适用范围

- `macos/Sources/Lithe/Application/Features/EditorTabOrderFeatureModel.swift`
- `macos/Sources/Lithe/Application/Features/EditorGroupLayout.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+EditorGroups.swift`
- `macos/Sources/Lithe/Views/Editor/EditorAreaView.swift`
- `macos/Sources/Lithe/Views/Editor/EditorGroupContainer.swift`
- `macos/Sources/Lithe/Views/Editor/EditorTabFrameStore.swift`
- `macos/Tests/LitheTests/EditorTabOrderFeatureModelTests.swift`
- `macos/Tests/LitheTests/MonacoWorkbenchSessionLifetimeTests.swift`
