# Agent 笔记：Windows Git Log 单文件差异预览

状态：已实现

## 先说结论

Windows 的 Commit Files 点击文件后使用独立页面，一次显示一个文件的差异。
页面保留当前比较的完整文件集合，左右箭头切换文件，上下箭头导航差异；
到当前文件最后一处后继续按下箭头，会进入下一文件的第一处差异。
标签跟随当前文件，采用 IDEA 的 `Repository Diff: 文件名`，提交标识显示在页面内。
源文件跳转必须使用预览所属仓库，不能因为活动项目不同而打开同名的另一份文件。

## 问题

原预览复用了多个文件纵向排列的页面，点击文件后只保留匹配路径的补丁。
它缺少差异导航和文件导航，也无法在同一预览中访问其他文件。
离散提交可以多次修改同一路径，因此路径本身不足以区分每份比较。

## 决策

Git 模块负责保存比较快照（一次读取所得的全部补丁和提交身份），
`commitFilePreview` 只区分前端页面，不改变共享 Core 的 Git 协议。
`CommitFileDiffPreview` 按文件 key 显示单个条目，导航只修改缓冲区里的当前 key。
例如 `C:a.ts` 和 `A:a.ts` 是两个可分别导航到的版本，不要按 `a.ts` 去重。
完整提交、工作区和其他多个文件的比较继续使用已有页面。

差异比较、对齐、查找、滚动和左右分隔条继续由 Monaco（已有的浏览器代码编辑器）负责。
工具栏调用其公开 `goToDiff`，使用其 `getLineChanges` 计算边界。
下箭头在文件末尾切换下一条目，等待 Monaco 完成比较后定位第一处差异；
整个文件集合末尾禁用，不循环回第一个文件。上箭头仍只导航当前文件内的差异。
首次定位意图由页面持有并绑定本次切换快照，只执行一次；左右箭头直接切文件不携带该意图。
更新模型或等待比较期间禁用差异和源跳转动作，避免连续点击跳过尚未加载的文件；
文件切换重建当前编辑器并清理旧监听器。
高频滚动和分隔条尺寸不进入全局缓冲区状态，重复的导航可用状态不触发页面更新。

页面外观优先使用现成组件与 Monaco 配置。专用 CSS 只作用于历史单文件预览，
采用 macOS Diff 与 IDEA Islands 的明暗背景、40px 工具栏、22px 图标按钮，
以及编辑器滚动条的透明度、边框和圆角。18px 滚动轨道和 12px 滑块通过 Monaco 配置，
拖动、滚轮、同步滚动与比例计算仍由 Monaco 负责，不新增滚动条控件。
两侧横向和纵向滚动条使用 Monaco 的 visible 配置，默认显示，不依赖鼠标悬停。
Monaco 差异概览自带的宽矩形视口指示与原生滑块重复，因此只取消其背景绘制；
保留概览差异色条和原生委托的点击、拖动、滚轮操作，不隐藏概览或改变几何尺寸。
历史只读页面关闭两侧代码编辑器自己的概览通道，避免其画布在滚动轨道下铺不透明底色；
轨道及残留的主题内联背景透明，代码可在滑块后显示，差异专用概览仍保留色条。
横向滚动条不额外增加内容高度，继续使用 Monaco 原生滑块及命中区域。
字体、字号和自定义行距继续使用用户设置；默认行距采用 22px 并按字号及缩放调整。
词级高亮复用共享 Diff 的 `highlightWords`，关闭后保留整行差异；
词级高亮与空白显示由预览页面持有，切换文件后保持选择。

左右版本标题复用现有锁图标，按条目保存真实父提交与目标提交：
单提交采用第一父提交，连续范围采用 baseRef/targetRef，离散选择保留各自版本身份。
`null` 父版本表示空树；缺少版本元数据的旧快照使用“上一版本”，不猜测 hash。
重命名分别显示旧、新路径，统一视图纵向显示两个标题。
分隔条布局事件只修改页面 CSS 列宽，标题跟随实际编辑器宽度，不发布 React 或缓冲区状态。
中央行号、曲线连接条和独立行流不在本次范围内，继续使用 Monaco 的默认并排布局。

Jump to Source 使用最后聚焦侧的光标，把补丁行号转换成新版本源行号。
删除的行定位到邻近保留行；整个文件已删除时禁用源跳转。
例如预览属于 `C:/parent/nested`，即使活动项目是 `C:/parent`，也要打开 nested 内的文件。
不要用显示行号直接打开源码，也不要从全局项目根目录猜测仓库位置。
历史版本和当前工作区之间没有额外的行号重映射；工作区后续修改或删除可使位置偏移或打开失败。
图片、二进制及无文本差异条目仍允许下箭头进入下一文件；没有文本光标时禁用源位置导航。

参考 IDEA Community `fb72b4df43aba102479eb0502d20b03586b9c5b8`：
`platform/vcs-log/impl/resources/messages/VcsLogBundle.properties` 的 Repository Diff 标题，
`VcsLogEditorDiffPreview.kt` 的文件名选择，以及
`platform/diff-impl/src/com/intellij/diff/impl/DiffRequestProcessor.java` 的
Previous/Next Difference、OpenInEditor、Prev/Next Change 动作顺序。
同一处理器的 `goToNextChangeImpl` 使用 `ScrollToPolicy.FIRST_CHANGE`，作为跨文件定位依据。
这些是页面交互依据，不表示移植 IDEA 的完整差异引擎。

## 考虑过的备选方案

- 在旧纵向页面加按钮：仍会同时渲染多个同路径提交区段，无法满足一次显示一个文件的需求。
- 切换文件时重新请求 Git：增加等待和迟到结果风险，丢失离散提交版本身份。
- 新写差异算法或拖动布局：Monaco 已有完整能力，会造成两套比较和滚动行为。
- 将跨文件后的初始差异位置写入持久缓冲区：会让重新打开或手动切换文件继承旧跳转意图。
- 自绘滚动条和另写行内比较：上游已有可配置滑块和词级高亮，增加一套实现会扩大维护与生命周期成本。

## 后果

一个固定预览标签可以浏览整个比较集合，也能保留同路径的多个提交版本。
代价是缓冲区保存完整集合，即使当前只显示一个文件；Git API 本来就返回完整集合。
历史预览继续采用现有补丁上下文范围，不在前端补造缺失的源码。
macOS 本次不修改，双端功能矩阵保持目标产品运行验收待验证的状态。

## 验证

- 用 Windows 前端计时工具运行 `multi-file-diff.test.ts`、
  `commit-file-diff-navigation.test.ts`、`diff-buffer-label.test.ts`、
  `use-commit-file-preview.test.tsx` 和 `commit-file-diff-toolbar.test.tsx`。
  `commit-file-diff-appearance.test.ts` 检查字号缩放与自定义行距。
- 真实浏览器加载生产页面组件和 Monaco，检查上下差异位置、左右文件切换、标题更新，
  连续下箭头经过多个文件、跨文件停在首处差异、等待比较时禁用以及集合末尾停止，
  删除/二进制禁用状态、左右侧源行映射，以及不同项目根目录下使用预览仓库。
  检查明暗背景、词级开关、重命名/空树/范围/离散选择版本标题；实际拖动 Monaco 分隔条
  和长文件滚动滑块，确认标题随宽度变化、滚动同步且编辑器及模型身份不变。
  平台源文件接口使用可控记录器，这项检查不替代完整 WebView2 产品验收。
- 运行 `scripts/build-windows.ps1 -Configuration Release`、Windows Rust 计时检查、
  `scripts/verify-runtime-bundle-immutability.sh`、`scripts/verify-agent-notes.sh` 和功能矩阵检查。
- 产品验收时分别点击单提交、连续提交范围、离散多选和重命名文件；确认预览复用、
  普通提交全量比较不受影响，取消选择/隐藏 Log/切换仓库后迟到请求不激活旧预览。

## 适用范围

`windows/tauri/src/features/git/components/diff/commit-file-diff-preview.tsx`、
`commit-file-diff-toolbar.tsx`、`monaco-git-diff.tsx`，以及
Git 模块的预览构造、文件导航、标签格式和异步预览 hook。
