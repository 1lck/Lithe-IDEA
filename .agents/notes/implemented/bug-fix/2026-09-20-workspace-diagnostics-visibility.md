# Agent 笔记：未打开文件的诊断必须可见

状态：已实现

## 先说结论

以前 Windows 端只保留"编辑器里已经打开的文件"的诊断，语言服务报给其他文件的
错误一律丢弃。结果是：Java 项目因为编译错误而无法启动时，Lithe 提示"请修复
报告的错误"，但用户在界面上根本看不到任何错误——错误在没打开的模块里，已经
被丢掉了。

现在改为：诊断所属文件只要落在某个已打开工作区（workspace root，即用户打开的
项目根目录）内就保留，工作区之外的（JDK 源码、依赖 jar、反编译的 class）继续
丢弃。为防止超大仓库把状态撑爆，未打开文件的诊断最多跟踪 2000 个文件。

开发者以后要注意：**不要再以"文件有没有打开"作为诊断的过滤条件**。判断依据是
"在不在工作区内"。

## 问题

若依 Plus（RuoYi-Vue-Plus，一个 40 多模块的 Maven 项目）在 Windows 上点运行会
失败。日志里的终点是：

```text
Java project build finished outcome=CompilationErrors
run.launch launchFailed reason="The Java project has compilation errors. Fix the reported errors and try again."
```

这条提示本身是准确的。Java Debug Server 的 `Compile.compile` 会构建工作区里
全部 Java 工程，但**只**用目标工程以及它 classpath 上的依赖工程的 error marker
（Eclipse 对某个文件记录的错误标记）来判定 `WITH_ERROR`。也就是说，确实是
ruoyi-admin 自己或它的某个依赖模块有真实编译错误。

问题出在用户拿不到任何可操作信息。`lsp-client.ts` 收到
`textDocument/publishDiagnostics`（语言服务推送诊断的通知）后，用
`resolvePublishedDiagnosticsFilePath` 把路径匹配到已打开的 buffer；匹配不上就
直接 return，并只写一行 `logger.debug`。

那份复现日志里用户只打开了 `DromaraApplication.java`，而错误在别的模块里。
于是：语言服务把错误发过来了，Lithe 自己扔了，然后又提示用户"去修复那些错误"。

这个过滤是有意写的，`diagnostics-file-path.test.ts` 里还有一条
`rejects closed documents` 的用例保护它。所以这不是疏漏，是一个需要被推翻的
旧决策。

## 决策

`resolvePublishedDiagnosticsFilePath` 增加第四个参数 `workspaceRoots`，解析顺序为：

1. 能匹配到已知 buffer 或已跟踪文档 → 返回那个文件**原本的路径拼写**。这样
   同一个文件来自 LSP 和 linter 的诊断仍然合并在同一条记录下。
2. 否则，路径落在任一 workspace root 内 → 返回归一化后的发布路径。
3. 否则 → 返回 `null`，丢弃。

不传 `workspaceRoots` 时行为与改动前完全一致，所以其他调用方不受影响。

workspace root 取自 `LspClient` 已有的 `activeLanguageServers`（serverKey 形如
`<workspacePath>:<languageId>`），不引入对 project store 的新依赖——诊断本来就
由某个语言服务推送，它的工作区就是最准确的判断依据。

### 为什么需要"保留 / 清除 / 忽略"三种结果

语言服务用**空诊断数组**来撤回某个文件的错误。如果照单全收，工作区里每个干净
文件都会在状态里占一行。所以未打开文件的处理拆成三种结果，逻辑放在
`diagnostics-retention.ts` 的 `decideWorkspaceDiagnostics` 里：

- `store`：有诊断，保留。
- `clear`：这个文件之前有诊断、现在空了 → 删掉记录，并把名额还回去。
- `ignore`：这个文件本来就没记录、现在也是空的 → 什么都不做。

**已打开的文件永远是 `store`，不受上限约束**，否则编辑器可能显示不出自己的错误。

到达上限后，**已经在跟踪的文件仍然继续更新**，只拒绝新文件。否则已跟踪文件会
卡在一份过期的错误上，比看不到错误更容易误导人。

正确做法：

```ts
// 判断依据是"在不在工作区内"
resolvePublishedDiagnosticsFilePath(published, buffers, openDocs, this.activeWorkspaceRoots());
```

不要这样做：

```ts
// 以"有没有打开"做过滤，未打开模块的错误会消失
if (!isDocumentOpen(published)) return;
```

关闭工作区时，`stop()` 调用 `clearWorkspaceDiagnostics` 清掉该工作区下所有
未打开文件的诊断。否则项目关掉了，它的错误还留在面板上。

## 考虑过的备选方案

- **只在启动失败时抓一次快照**：仅在 `javaBuildCompilationErrors` 发生时收集
  目标工程及其依赖的 error marker，展示在 Run 面板，不动全局诊断管线。改动
  范围最小，也保留了原有过滤。被否：Problems 面板只显示已打开文件，本身就不
  符合用户对 IDE 的预期；而且这条路要为"启动失败"单独造一套诊断收集，和已有的
  `diagnostics.store` 形成第二份真源。
- **完全不限制，收下全部发布的诊断**：被否。JDK 源码、依赖 jar 里的类、反编译
  出来的 class file 都会进面板，噪音压过真正要看的错误。
- **只把被丢弃的诊断补进日志，不改行为**：改动最小，也能让这次排查继续。被否：
  它只服务于这一次排查，用户界面上依然看不到错误，下一个人遇到同样问题还是
  只能看日志。
- **在 `diagnostics.store` 里统一加上限**：被否。store 同时服务 LSP 和 linter，
  在那里加限制会把"已打开文件的诊断"也一起限制掉。上限属于"未打开文件"这个
  新增来源，应该由引入它的边界负责。

## 后果

收益：

- 构建失败阻止启动时，用户能在诊断面板里直接看到是哪个模块、哪个文件、哪一行。
  #692 这类问题重跑一次就能自证病因。
- 诊断面板从"当前打开文件的错误列表"变成真正的工作区问题列表。

代价和例外：

- 大型项目首次构建后，诊断状态会比以前大。上限 2000 个未打开文件是拍出来的
  经验值，不是测出来的；若依 Plus 量级（1186 个文件）远达不到。触顶时会打一条
  `logger.warn`，每次触顶只报一次。
- 上限触顶后新文件的错误会被静默丢弃。这是刻意的取舍：面板在几千条错误时
  本来就已经失去意义。
- 本次改动**没有**触碰启动门禁本身。构建报编译错误时 Lithe 仍然拒绝启动，
  且不提供"仍然运行"的选项——VS Code 在同样情况下会弹窗让用户选择继续。
  是否要加这个放行路径是独立决策，见
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`。

## 验证

- 前端单测：`cd windows/tauri && bun test src/features/editor/lsp`
  （`diagnostics-file-path.test.ts` 覆盖工作区内保留、已知 buffer 优先、工作区外
  丢弃、同名前缀目录不算包含、分隔符归一、POSIX 大小写敏感；
  `diagnostics-retention.test.ts` 覆盖三种结果、上限行为和"已打开文件不受限"）。
- 边界校验：`./scripts/verify-windows-boundaries.sh`
- 测试稳定性门禁：`./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- 类型检查：`cd windows/tauri && bun run typecheck`
- 未在本次执行：Windows 实机验证。需要在 Windows 上打开若依 Plus，点运行，
  确认失败后诊断面板列出具体错误。

## 适用范围

- Windows：`windows/tauri/src/features/editor/lsp/diagnostics-file-path.ts`、
  `windows/tauri/src/features/editor/lsp/diagnostics-retention.ts`、
  `windows/tauri/src/features/editor/lsp/lsp-client.ts`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`


## macOS 的 File 展示范围与空状态（2026-10-14）

macOS Problems 的 File 页跟随当前选中的文本编辑器文件，Project Errors 页继续展示
工作区已收到的全部问题。File 只是展示过滤，不能据此删除其他文件的诊断，也不能
把“诊断最多的文件”或项目树选中项当成当前文件。选择终端、数据库、图片或差异视图
时不沿用旧文本文件；关闭或切换文件后由编辑器现有状态直接更新。

依据 Community revision `373dcfbaea24c627febb7e4916125fed3e5b4bc3`：

- `platform/problemsView/ui/src/com/intellij/analysis/problemsView/toolWindow/HighlightingPanel.kt`
  的 `findSelectedFile` 读取 `FileEditorManager.selectedEditor`，并要求同时获得文件和文本
  document。无文件时提示打开文件；文件无问题时显示 `No problems in {0}`；隐藏严重程度
  时追加 `Problems could be filtered out`。
- `platform/platform-api/src/com/intellij/util/ui/StatusText.java` 使用普通标签字体和
  `GRAYED_ATTRIBUTES`，文字顶部位于剩余高度的三分之一。没有大图标或额外引导段落。
- `platform/util/ui/src/com/intellij/util/ui/NamedColorUtil.java` 的灰色文字追到
  `Component.infoForeground`；`platform/platform-resources/src/themes/islands/ManyIslandsDark.theme.json`
  与 `ManyIslandsLight.theme.json` 的 `*.infoForeground` 均为 `text-secondary` → `gray-80` →
  `#73767C`。Lithe 复用 `LitheTheme.Tree.secondaryText`、普通 13pt `uiFont`，标签页复用
  `LitheToolWindowTabStyle`，不另加颜色和字体体系。

Lithe 没有 Community daemon 的逐文件分析完成、暂停和省电状态信号，所以不复制其
200ms 状态轮询，也不从空诊断列表推断正在分析。语言服务、分析进度协议和诊断保留
策略不在本次展示调整范围内。

组件验证：`./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter ProblemsPanelPresentationTests`。
覆盖同名不同路径、文件切换、无当前文件、工作区诊断保留，以及深浅主题和窄宽度下的
空状态颜色、水平居中与三分之一高度。完整工作区中的编辑器切换仍需应用交互验收。

适用源码：`macos/Sources/Lithe/Views/Language/JavaProblemsView.swift`。


## macOS Problems 源码预览与左侧工具栏（2026-10-14）

左侧 View Options 复用已有严重程度筛选；Show Editor Preview 在列表右侧打开源码，
默认各占一半，通过 `LitheSplitPaneView` 调整宽度。开启时单击和上下键改变预览，双击
与 Enter 仍在主编辑器定位；没有问题时禁用预览按钮。灯泡快速修复属于独立动作，
本次工具栏只承接已有筛选和用户指定的源码预览。

同一 Community revision 的
`platform/problemsView/ui/resources/intellij.platform.problemView.ui.xml` 定义动作顺序，
`platform/icons/src/PlatformIconMappings.json` 把 `Actions.GroupBy` 与 `Actions.PreviewDetails`
映射到 `expui/general/show.svg` 与 `previewVertically.svg`。复用 Lithe 已导入的明暗图标、
16pt 图标与共享 22pt 按钮；选中开关仍用 `LitheIconButtonStyle`。`ProblemsViewPanel.java`
使用水平 `OnePixelSplitter` 和默认 0.5 比例；`JBUI.java` 的新 UI 竖向工具栏默认 insets
为上下 5、左右 7，Islands 主题没有覆盖这项。

`platform/lang-impl/src/com/intellij/ui/preview/DescriptorPreview.kt` 复用文档并让预览定位
跟随问题。Lithe 继续使用现有 Monaco，而不是引入另一套编辑器；通过
`DocumentFeatureModel.previewDocument` 取得已打开或临时文档，读取失败时显示失败文字，
切换文件或关闭面板会取消该视图的加载结果交付。干净的临时文档仍由既有工作区预览缓存
拥有，跟随现有 `discardPreviewDocuments` 与工作区关闭清理，不在工具窗口中自行删文档。

IDEA 的该预览可编辑；此次 Lithe 提供只读源码预览。独立预览会话键包含 presentation ID，
与主编辑器共享实时文档内容，但不移动主编辑器 WebView、不获取文档同步/保存/关闭屏障，
也不修改文档本身的只读属性。预览关闭即可释放其会话。不能直接复用主编辑器会话键，
否则 WebView 会从主区域搬入预览；也不能让第二个可编辑会话接管同步屏障，造成输入、
撤销或保存归属竞争。将来若要编辑，先复用支持跨视图共享模型和撤销的编辑器宿主。

`window.lithe.navigate` 的可选 `focus: false` 只移动预览位置，默认调用仍保留原先获得焦点
的行为。独立只读预览不消费主编辑器导航事件，也不把 cursor/focus 事件写回主编辑器。
原生桥同时拒绝预览编辑、保存与会执行修改的语言操作，不能只依赖 Web 前端的 readonly。

验证入口：会话生命周期与保存归属使用 `MonacoWorkbenchSessionLifetimeTests`，
分栏使用 `LitheSplitPaneGeometryTests` / `LitheSplitPaneCollapseTests`，真实 WebKit 使用
`./scripts/probe-macos-monaco.sh --workbench-tests`。测试工具栏开关、分栏拖动和完整工作区
焦点流时，仍须进行应用级交互验收。


## Problems 文案跟随应用语言（2026-10-15）

File / Project Errors 和空状态在视图中保留 `LocalizedStringKey`，由 SwiftUI 的
`locale` 环境解析。不要先用 `String(localized:)` 生成字符串；它会先按进程的 bundle
语言选取翻译，造成英文应用环境仍显示中文，且外层 `Text(String)` 无法重新翻译。
文件名用本地化插值，预览加载失败和筛选提示沿用同一路径。

`ProblemsPanelPresentationTests.problemsTextFollowsInterfaceLocale` 同时加载真实 en 与
zh-Hans 资源，分别渲染两种应用语言，并与目标语言的参考文字逐像素比较，覆盖标签、
无文件、带文件名的空状态、筛选与预览失败。不能只检查 strings 文件里是否存在翻译。


## 列表焦点与独立演示（2026-10-15）

Problems 列表仍需 `.focusable()` 接收方向键；SwiftUI 默认焦点效果会在整个列表外画蓝框。
沿用 Git Log 已使用的 `litheFocusEffectHidden()`，只隐藏外框，保留键盘选择和行选中样式。
只读源码预览只执行定位，不打开主编辑器的查找浮层，避免空查找框抢走焦点。

Debug 构建通过 `./scripts/preview.sh --problems-demo` 打开真实 ProblemsView 演示，
包含错误、警告、信息、提示、未知级别，以及废弃、未使用、关联信息、多行长文和 Unicode。
演示使用独立设置域和临时工作区，不启动语言服务器；退出时关闭工作区并清理临时数据，
5 秒截止机制防止关闭流程挂起。演示文件只写入系统临时目录，不写 app bundle；
没有新增可复用下载或生成缓存资源。发布构建不包含这个入口。

实际检查独立演示程序的选中、方向键与源码切换：没有外围蓝框，源码跟随选择且没有查找浮层。
运行前后比较 app bundle 的 609 个文件哈希，内容未变；退出后演示进程和所属临时目录均清理。
`ProblemsPanelPresentationTests` 验证演示数据覆盖全部级别、标签及有效文件位置。


## Problems 文件图标与启动角标（2026-10-15）

文件行复用项目树的 `JavaFileIconResolver` 判断 Java 类型，不能仅按扩展名选择咖啡杯。
启动标记消费已有 Java 启动配置的 `sourcePath` / `mainClass`；没有已发现的入口时不猜测
源码是否可运行，也不为绘制图标启动语言服务。Debug 演示显式提供 Main.java 的已知入口。
这保留了 JDT 对启动入口的所有权，代价是入口尚未发现时不会显示启动角标。

Community revision `373dcfbaea24c627febb7e4916125fed3e5b4bc3` 的 `FileNode.kt`
通过文件语义取得图标，`JavaFileIconPatcher.kt` 优先使用同名类型的图标。
`YAMLFileType.java` 返回 `AllIcons.FileTypes.Yaml`，application.yml 不单独换图标。
类、YAML 和 runnableMark 均使用该 revision 的明暗 SVG。启动角标保持 16×16 画布
自带的右上角位置，不缩放或平移成另一种装饰。

问题行的错误与警告使用 `HighlightDisplayLevel` 对应的 inspections 蒙版，沿用共享
诊断颜色；它们与右上角统计的 status 图标具有不同的内部留白，不能只比较外框尺寸。
列表选中背景不依赖源码预览开关，方向键切换时滚动到所选问题，避免选择移出可视区域。

`ProblemsPanelPresentationTests.fileIconsHaveDistinctThemeVariantsAtNativeSize` 加载真实
类、YAML 和启动角标资源，检查明暗变体都可读取、画布为 16×16 且实际渲染不同。


## 审核后的交互边界补充（2026-10-15）

File 的当前文件解析同时排除 Agent Conversation 编辑器标签。该标签保留上一次
activeDocument，不能仅用文档是否存在判断用户正看的内容；切回文本标签后恢复文件范围。

Problems 只读预览的原生桥拒绝 javaRunMarkerAction。共享 Monaco 在文档为只读时
不请求 Run Marker，清除角标和 Run/Debug 动作，并在执行回调时再次检查只读状态，
防止切换前已经保存的菜单动作启动进程。编辑器正常可写时保留原有 Run/Debug 行为。
验证分别覆盖文本→Agent→文本、原生消息策略，以及真实 WebKit 的动作移除和过期回调。
