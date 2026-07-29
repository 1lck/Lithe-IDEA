# IntelliJ IDEA UI 源码参考

这份索引用于研究 IntelliJ IDEA 的页面布局、工具窗口组织和交互行为。它不是要求 Lithe-IDEA 继续使用 IntelliJ Platform，也不是把 Swing/JVM UI 直接搬进最终产品。

## 主要工作台结构

| IDEA 页面/能力 | 参考源码 | 研究重点 |
|---|---|---|
| 主 IDE 窗口 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/wm/impl/IdeFrameImpl.kt` | 主窗口区域、内容区、状态栏和生命周期 |
| macOS/自定义标题栏 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/wm/impl/customFrameDecorations/header/MainFrameCustomHeader.kt` | 顶部标题栏、窗口控制和工具栏关系 |
| 工具窗口管理 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/wm/impl/ToolWindowManagerImpl.kt` | 左/右/底部 ToolWindow、显示隐藏、停靠和布局状态 |
| Project 面板 | `intellij-community-master/platform/lang-impl/src/com/intellij/ide/projectView/impl/ProjectViewImpl.java` | 文件树、节点刷新、选择状态和异步更新 |
| Project 面板视图 | `intellij-community-master/platform/lang-impl/src/com/intellij/ide/projectView/impl/ProjectViewPane.java` | Project 工具窗口与树视图的组装 |
| 编辑器分屏 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/fileEditor/impl/EditorsSplitters.kt` | 中央编辑区、分屏和编辑器容器 |
| 编辑器标签页 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/fileEditor/impl/EditorTabbedContainer.kt` | 标签页、选中状态、关闭和拖动 |
| 编辑器窗口 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/fileEditor/impl/EditorWindow.kt` | 文件编辑器生命周期和激活逻辑 |
| 底部状态栏 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/wm/impl/status/StatusBarUI.java` | 状态项、分隔、诊断和光标信息 |
| Welcome Screen | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/wm/impl/welcomeScreen/NewWelcomeScreen.java` | 启动页、项目列表、New/Open/Clone 入口 |
| Welcome 窗口 | `intellij-community-master/platform/platform-impl/src/com/intellij/openapi/wm/impl/welcomeScreen/WelcomeFrame.kt` | 启动窗口尺寸和页面承载 |

## 重点交互

### ToolWindow

IDEA 的关键不是简单的三栏布局，而是 ToolWindow 的状态系统：

- 每个面板可以停靠在左、右、底部
- 可以隐藏、展开、浮动和最大化
- 面板布局可以保存和恢复
- 面板内容懒加载
- 工具窗口之间共享统一的标题栏和操作区

Lithe-IDEA 的轻量实现应保留这些交互语义，但不需要复刻 IntelliJ 的 `ToolWindowManager` 类层次。

### Editor

编辑区需要区分三层：

```text
Editor workspace
├── Splitter / 编辑器分屏
├── Tabbed container / 标签页容器
└── Editor / 具体文件编辑器
```

这比把编辑器当成一个普通居中的文本框更接近 IDEA 的实际体验。

### Project View

Project 面板的关键体验来自：

- 文件夹/模块树的层级缩进
- 文件类型图标
- 当前文件高亮
- 异步加载和刷新
- 右键菜单上下文
- 目录排除和折叠状态

首版只保留展示、选择、展开折叠和刷新，不实现所有右键操作。

## UI 参考与最终实现的边界

```text
IntelliJ IDEA 源码
    ↓ 研究布局、尺寸、交互和状态组织
Lithe-IDEA UI 规范
    ↓ 用轻量技术重新实现
Lithe-IDEA 页面与底层服务
```

不直接复制：

- JetBrains 名称、Logo 和专有品牌资源
- Swing 组件层级
- IntelliJ Platform 的服务容器和插件依赖
- 与 PSI、索引和项目模型强耦合的 UI 代码

保留并重新实现：

- Project / Editor / ToolWindow 的空间关系
- 顶部工具栏、底部面板和状态栏的信息层级
- 标签页、分屏、停靠、隐藏和恢复等操作习惯
- Git Changes、Run、Debug 和 Problems 的页面结构
