# Windows UI 视觉对齐 macOS 计划

## 目标

把 Windows Qt Workbench 的工作台外观对齐 macOS 截图中的信息层级和交互反馈：深色分层背景、带 IntelliJ 风格图标的项目树、编辑器语法着色、标签栏层级，以及一致的 hover/pressed/focus 状态。

本计划只调整 Windows 的 Qt Widgets 表现层和资源注册，不引入 SwiftUI/AppKit，不改变 Rust Core、JSON 协议、文件读写或业务状态机。

## 现状基线

| 区域 | 当前实现 | 与 macOS 的主要差异 |
| --- | --- | --- |
| 工作台布局 | `windows/qt/workbench_window.cpp` 使用水平/垂直 `QSplitter`，侧栏最小宽度 260 | 缺少 macOS 顶部标题/工具栏的视觉分层；面板边界和留白不统一 |
| 项目树 | `WorkbenchSidebar` + `QTreeWidget`，`appendTreeNode()` 只设置文本和状态数据 | 没有 `QIcon`；缩进、行高、根节点标题和选中态未对齐 |
| 图标资源 | `Resources/IDEAIcons` 已包含文件、目录、工具窗口 SVG | `windows/qt/lithe.qrc` 尚未注册 `IDEAIcons`，Windows 端无法复用这些资源 |
| 编辑器 | `WorkbenchCodeEditor` 已接入 `QSyntaxHighlighter` 和行号 gutter | token 颜色仍是偏亮背景的棕/蓝配色；缺少 macOS 的编辑区背景、当前行和选择色 |
| 交互反馈 | `ui_theme.cpp` 已有基本 `:hover/:pressed/:focus` | hover 只覆盖通用控件，树行/标签/图标按钮缺少精细状态和 tooltip |
| 测试 | 有主题、侧栏、编辑器和算法测试 | 没有图标映射、样式 token、hover 状态和截图回归测试 |

## 视觉规格（第一版 token）

以 `Sources/Lithe/Theme/LitheTheme.swift` 为参考，在 Qt 中集中定义同名语义 token，避免继续在控件中散落颜色字面量。

| Token | 建议值 | 用途 |
| --- | --- | --- |
| `window` | `#1B1D20` | 主窗口和非编辑器背景 |
| `titlebar` | `#25272B` | 顶部工具栏/标题栏 |
| `sidebar` | `#17191C` | 项目树背景 |
| `editor` | `#131518` | 编辑器正文背景 |
| `raised` | `#2A2D33` | 活跃 tab、按钮、浮层 |
| `selection` | `#2B4A7D` | 主选中态 |
| `subtleSelection` | `#343841` | 当前文件行/弱选中态 |
| `accent` | `#4F94FA` | tab 下划线、focus、关键操作 |
| `primaryText` | `#DCE0E8` | 正文 |
| `secondaryText` | `#858B98` | 次要信息、行号 |
| `divider` | `#30343B` | 面板和工具栏分隔线 |

编辑器 token 颜色沿用 macOS `SyntaxHighlighter`：keyword `#CC7AC4`、annotation `#DBB856`、type `#6BB8E6`、number `#A6C07D`、string `#8CC079`、comment `#64906B`；正文使用 `#CDD0D6`。所有普通文本和控件需保持 WCAG AA 对比度。

## 分阶段实施

### P0：资源和主题基础（1 个 PR）

- 新增 `windows/qt/ui_tokens.h/.cpp`，集中暴露颜色、尺寸、圆角和动画时长；`ui_theme.cpp` 只负责把 token 应用到 `QPalette`/QStyleSheet。
- 扩展 `windows/qt/lithe.qrc`，注册 `../Resources/IDEAIcons` 下的 SVG；在 `windows/CMakeLists.txt` 中确认 Qt RCC 的 Debug/Release 目标都包含该资源。
- 统一主窗口、侧栏、编辑区、tab、输入框、滚动条和 splitter 的背景层级：侧栏与编辑器必须可一眼区分，分隔线 1 px。
- 交互参数：普通按钮/树行 hover 120 ms ease-out；pressed 使用明显但不跳动的深色反馈；focus 使用 1 px `accent` 边框；支持 `prefers-reduced-motion` 等价的 Windows 无障碍设置（关闭过渡）。

### P1：项目树图标和行行为（1 个 PR）

- 新增 `windows/qt/workbench_icons.h/.cpp`，按文件名/扩展名/目录语义返回 `QIcon`，映射 macOS `LitheIconKind`：目录、source/resource/excluded/package、Java 类型、Swift/Kotlin/Rust/脚本、JSON/Markdown/XML、图片/二进制/未知文件。
- `appendTreeNode()` 为每个节点设置图标，并保留现有 `RelativePathRole`/`DirectoryRole`；Java 文件可在读取前 4 KB 后异步解析 class/interface/enum/annotation 图标，失败回退到通用 Java 图标。
- 项目树行高固定 25 px，缩进每级 14 px，图标 14 px，箭头保留 10 px 槽位；根节点使用 semibold，文件名中间省略。
- 增加 `QStyledItemDelegate` 或等价样式：整行 hover 使用 `hoverBackground`，当前文件使用 `subtleSelection`，按下使用 `pressedBackground`；右键菜单、双击打开和键盘导航行为保持不变。
- tab 使用同一套文件图标和状态槽位，避免 dirty/saving/error 图标导致 tab 宽度跳动。

### P2：编辑器视觉对齐（1 个 PR）

- 将 `workbench_code_editor.cpp` 的 token 色替换为 macOS 规格，并补齐 Markdown/HTML/JSON 常见标记；高亮算法仍放在 `windows/app/algorithms`，Qt 层只负责格式映射。
- 编辑器使用 13 px 等宽字体、无换行、正文 `#CDD0D6`；行号 gutter 使用 `secondaryText`，背景比编辑区高一层；当前行使用低透明度 `subtleSelection`，选区使用 `selection`。
- 保留现有 code vision、inlay、blame、breakpoint、折叠和 diff 逻辑；新增的绘制必须只更新可见区域，避免每帧全量扫描。
- 为编辑器 tab 增加 14x14 固定图标槽位和活动 tab 2 px `accent` 下划线，hover 只改变背景，不移动布局。

### P3：工具栏、浮层和细节反馈（1 个 PR）

- 对齐 macOS 顶部工具栏的高度（40 px）和图标按钮尺寸（28x28）；为刷新、搜索、设置、运行、Git、更多等图标补 `QToolTip`/accessible name。
- 统一菜单、find bar、状态 banner、搜索结果、Changes 列表的 raised/selection/error/success 状态；弹出菜单 150–250 ms，普通按钮 100–160 ms，全部支持取消/关闭反馈。
- splitter handle 默认 1 px，hover 扩展命中区域但不改变布局；滚动条仅在需要时显示，避免常驻粗滚动条破坏 macOS 参考图的密度。

## 文件变更清单

| 文件 | 变更 |
| --- | --- |
| `windows/qt/ui_tokens.h/.cpp` | 新增语义色、尺寸、动效常量 |
| `windows/qt/ui_theme.cpp` | 迁移到 token，补齐控件状态选择器 |
| `windows/qt/lithe.qrc` | 注册 `Resources/IDEAIcons` SVG |
| `windows/qt/workbench_icons.h/.cpp` | 新增图标分类、缓存和回退策略 |
| `windows/qt/workbench_window.cpp` | 树节点/tab 设置图标，保持业务连接不变 |
| `windows/qt/workbench_sidebar.cpp` | 行高、header、hover/selection 视觉结构 |
| `windows/qt/workbench_editor_area.cpp` | tab/find bar/status banner 的布局 token |
| `windows/qt/workbench_code_editor.cpp` | 语法色、gutter、当前行和选区绘制 |
| `windows/tests/ui_theme_test.cpp` | token 和关键选择器断言 |
| `windows/tests/workbench_sidebar_test.cpp` | 图标、行高、选中/hover 可访问对象断言 |
| `windows/tests/workbench_code_editor_test.cpp` | token 颜色、gutter 和 tab 槽位断言 |
| `windows/tests/workbench_icons_test.cpp` | 文件/目录/Java 类型映射和未知回退 |

## 验收标准

1. 在 1280x800、1920x1080、125%/150% Windows 缩放下，项目树、tab、gutter 和 splitter 不发生文字或图标重叠，树行高度稳定为 25 px。
2. 项目树中的目录、`.gitignore`、`Package.swift`、`README.md`、C++/Java/JSON 等节点都有可辨识图标；未知扩展名有统一 unknown 图标。
3. 打开示例 Markdown/Java 文件时，keyword、type、annotation、number、string、comment 均呈现与 macOS 参考图相同的语义色；选区和当前行仍清晰可读。
4. 鼠标移入树行、tab、按钮、菜单项和 splitter 时有即时 hover；按下、选中、focus 有独立状态；键盘操作结果与鼠标一致。
5. Qt offscreen 测试通过，真实 Windows 构建通过 CTest；至少保存三张固定尺寸截图（空工作区、项目树+编辑器、弹出菜单）用于人工像素/布局回归。
6. 不修改 Rust/Core 行为，不新增 Electron/Node 运行时，不把 macOS 专属代码作为 Windows 依赖。

## 风险与决策

## 功能页结构对齐（截图二次走查）

| macOS 参考区域 | Windows 修复目标 | 状态 |
| --- | --- | --- |
| 单层顶部工作区栏 | 隐藏传统菜单栏，将命令收进顶部 `...` 菜单；工具栏固定 40 px，并保留 Open/Refresh/Save 快捷操作 | 已完成 |
| 左侧 46 px 工具 rail | Project、Changes、Search 使用图标按钮切换，具备 hover、checked 和 tooltip 状态 | 已完成 |
| 项目面板 | 保留项目标题/目的地选择器、文件类型图标、25 px 树行和整行 hover/selection | 已完成 |
| 编辑器标签与正文连续表面 | 移除编辑器区域 8 px 外围留白，让标签栏、正文和右侧边缘连续衔接 | 已完成 |
| Git 分支选择器 | 复用现有 Git reference 切换逻辑，显示真实当前分支，禁止静态占位 | 已完成 |
| Run configuration 选择器 | 复用现有 Java/Spring Boot 检测与运行逻辑，显示真实配置并触发现有运行逻辑 | 已完成 |
| Activity bar 底部工具 | 终端、Git、Problems、Maven、Debug、Settings 绑定现有 Qt 槽函数 | 已完成 |
| 右侧编辑器视图按钮 | 为编辑/分栏/预览提供固定 28 px 图标按钮及 tooltip；仅在对应功能可用时启用 | 待实现 |
| 底部状态栏 | 对齐行列、编码、缩进、锁定、内存和 Git 状态的信息顺序；没有真实数据的字段不展示 | 待实现 |

验收时以用户提供的 macOS 截图为视觉基线，在 1600x1037 和 2048x1229 比例下逐区核对。Windows 系统按钮保持平台原生位置，但颜色、边框和内容区层级必须与 macOS 参考一致。


- IntelliJ SVG 资源已随仓库提供，优先复用并在许可证/NOTICE 中保留归属，不重新绘制一套近似图标。
- Qt 样式表对原生 Windows 高 DPI 的细节控制有限；若 125% 以上出现裁切，使用 `QProxyStyle` 调整像素度量，而不是继续堆叠样式表覆盖。
- 颜色对齐不等于功能对齐；本计划不把 macOS 尚未存在的 Windows 功能（例如额外工具窗口）混入本轮视觉 PR。
- 当前工作树的用户改动（`LICENSE`、`README.md`、`a.txt`、`b.txt`）与本计划无关，实施时不应覆盖。
