# Agent 笔记：Windows 工作台对齐 IntelliJ Islands 外观

状态：已实现

## 先说结论

Windows 版的工作台外观以 IntelliJ IDEA 的 Islands 主题（编辑器和工具窗口画成一块块圆角“岛”卡片的新外观）为参照。
Islands 的精确色值只写在 Lithe 主题 `lithe.json` 里，其他主题只继承布局和圆角，颜色由主题自身推导。
所有尺寸都从 IntelliJ 源码换算而来，注意 IntelliJ 主题里的 `arc` 是圆角的**直径**，换算成 CSS 要除以 2。
项目颜色渐变、失焦变淡、提交差异标签标题这三处都有刻意的范围限制，修改前先读“决策”一节。

## 问题

用户把 Lithe 和 IntelliJ 并排使用，任何偏差都会被直接看到：标签栏多出的前进/后退箭头、标签样式、配色、窗口失焦表现、项目颜色渐变都与 IntelliJ 不一致。
同时 Windows 版内置十几个第三方主题，如果把 IntelliJ 的颜色写成全局默认值，这些主题会被强行染成 Islands 蓝色，高对比主题的可辨识度也会下降。

## 决策

### 色值来源和主题范围

- Islands 的精确色值（窗口底色、卡片底色、选中色、编辑器标签 `editor-tab-*`、滚动条 `app-scrollbar-*`）只写在 `windows/tauri/src/extensions/themes/builtin/lithe.json`。主题注册时它们会写成根元素上的 CSS 变量，优先级高于 `theme.css`。
- `theme.css` 和 `scrollbars.css` 只放适用于所有主题的默认值，标签颜色用 `color-mix` 从主题的 `primary`、`foreground`、`border` 推导。
- 浅色滚动条取 IntelliJ 在 Islands 下强制使用的 Mac 风格滚动条颜色（`#00000033` / `#00000080`），深色取 `#80808059` / `#8080808C`。

### 尺寸换算

IntelliJ 用 Java2D 的 `arc`（圆角直径）描述圆角：卡片 `Island.arc 20` 对应 10px（变量 `--lithe-island-radius`），编辑器标签 `arc 12` 对应 6px，按钮和输入框 `Button.arc` / `Component.arc 8` 对应 4px。

### 编辑器标签

- 标签栏不提供前进/后退按钮，IntelliJ 新 UI 也没有。后退/前进只走 Navigate 菜单和 Ctrl+Alt+←/→。
- Web Viewer 标签上，后退/前进先走网页历史，网页历史到头后再回到代码跳转历史，并且不把网页记成跳转位置（`navigation-command-actions.ts`）。
- 选中标签是否置灰按“焦点是否在这个标签组内”判断，对应 IntelliJ `EditorTabbedContainer` 的 `isFocusAncestor`。不要改回“是否为激活分栏”，否则单个编辑组时永远不会置灰。
- 从提交面板打开的工作区差异会带上 `MultiFileDiff.commitPreview` 标记，标签标题显示“提交: 文件名”。编辑器 gutter（行号旁的改动标记栏）打开的是整文件差异，和 IntelliJ 的 “Diff for Range” 含义不同，所以不带这个标记，标题保持“未提交的更改”。重建差异数据（逐步加载、刷新）时必须沿用这个标记。

### 窗口失焦

只让外框变淡，透明度 0.56：标题栏、多项目标签栏、侧边按钮条和状态栏。编辑器和工具窗口内容保持不透明，与 IntelliJ 只对外框组件启用 `IslandsInactiveFrameGraphics2D` 的范围一致。
焦点状态来自 Tauri 的 `onFocusChanged`，启动时用 `isFocused()` 初始化。

### 项目颜色渐变

- 只在 Lithe 主题、设置项 `differentiateProjects` 开启（默认开启）、并且关闭窗口透明时绘制，IntelliJ 也只在 Islands 主题下画。
- 渐变用 `background-attachment: fixed`（背景固定在窗口坐标上），挂在所有使用窗口底色的容器上，让它们共用同一个窗口级渐变；卡片本身不透明，盖在上面。
- 颜色序号用项目路径的 64 位 FNV-1a 哈希对 9 取模，和 macOS `ProjectIdentityAppearance.colorIndex` 使用同一种算法。
- 项目头像（标题栏、项目菜单、欢迎页）统一使用 `ProjectAvatar` 组件，样式照 IntelliJ `AvatarIcon` 实现：用同一颜色序号的 `Avatar.Start/End` 渐变，左下角为 End、右上角为 Start；圆角半径为边长的 20%（`arcRatio 0.4` 是直径占比）；白色 JetBrains Mono 半粗体，字号为边长的 13/20；首字母规则照搬 `AvatarUtils.initials`。头像颜色和渐变颜色必须取自同一个序号函数，不要再为头像另起一套配色。
- 两端深色项目色相同。浅色有差异：Windows 用 Islands Light（`ManyIslandsLight.theme.json` 的 `RecentProject.ColorN.MainToolbarGradientStart`），macOS 仍是旧版 New UI 浅色主题（`expUI_light_with_light_header.theme.json`）的取值。这次刻意没有改 macOS，两端要统一时，改 macOS 的 `palette` 常量即可。

### 正确做法

- 想调整 Lithe 主题下的标签颜色：改 `lithe.json` 的 `editor-tab-*`。
- 新增一个使用窗口底色的外框容器：给它加类名，并加入 `project-gradient.css` 和 `base.css` 的选择器列表。

### 不要这样做

- 不要在 `theme.css` 里写死 Islands 的十六进制颜色，否则所有第三方主题都会被染色。
- 不要对 `#root` 整体设置透明度来实现失焦变淡，这会让正在对照阅读的代码一起变淡。
- 不要给 `.lithe-layout-shell` 或 `.lithe-resizable-pane` 设置带 `!important` 的 `background` 简写，它会清掉渐变图层，侧栏和编辑区之间的缝隙就看不到渐变了。

## 考虑过的备选方案

### 按 IntelliJ 的做法轮流分配项目颜色并持久化

这样最贴近 IntelliJ，而且以后可以让用户手动选颜色。但需要新增项目级存储，而 macOS 端已经选择用路径哈希、不额外存储（见 `ProjectIdentityAppearance.swift` 的注释）。两端保持同一方案更容易对齐，以后支持自定义颜色时再一起迁移。

### 用 Canvas 或单独的遮罩层绘制渐变

可以逐像素复刻 IntelliJ 的抖动渐变。但要和面板布局同步层级与尺寸，拖动面板时还要重绘，违背可调整面板的性能约束。CSS 固定背景不需要额外的渲染路径，代价是没有抖动处理，大面积浅色渐变可能出现轻微色带。

### 把 Islands 颜色设为全局默认

改动最少，所有主题立即得到 Islands 外观。但它会覆盖第三方主题的设计意图，高对比主题原本依赖的主色下划线也会消失，因此放弃。

## 后果

- 收益：Lithe 主题下的视觉和 IntelliJ Islands 基本一致，渐变和失焦行为可以对照 IntelliJ 源码逐项验证。
- 代价：第三方主题只获得推导出来的近似颜色；失焦变淡是对整个元素设透明度，和 IntelliJ 逐次绘制乘透明度的效果略有差异；Web Viewer 原生子窗口不参与变淡。
- 需要重新评估的情况：IntelliJ 调整 Islands 色板或渐变尺寸；Lithe 支持用户自定义项目颜色；macOS 端补齐失焦变淡或渐变开关。

## 验证

- `scripts/verify-platform-feature-matrix.sh`
- `scripts/verify-agent-notes.sh`
- 在 `windows/tauri` 下运行 `bun test src/features/window/utils/project-gradient.test.ts src/features/git/utils/diff-buffer-label.test.ts src/features/tabs/utils/tab-chrome-buffer.test.ts src/features/keymaps/commands/navigation-command-actions.web-viewer.test.ts`
- 按 `shared/platform-feature-matrix/features/workbench-islands-appearance.json` 和 `workbench-project-color-gradient.json` 的验证步骤在 Windows 实机确认。

## 适用范围

- `windows/tauri/src/extensions/themes/builtin/lithe.json`
- `windows/tauri/src/styles/`
- `windows/tauri/src/ui/tab-bar.tsx`
- `windows/tauri/src/features/tabs/`
- `windows/tauri/src/features/window/`
- `windows/tauri/src/features/git/utils/diff-buffer-label.ts`
- `macos/Sources/Lithe/Views/Workspace/ProjectIdentityAppearance.swift`（只作为颜色算法的对照，本次未修改）
