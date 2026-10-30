# Agent 笔记：用 GPUI 重建三端工作台

状态：提议中

## 先说结论

计划以当前 macOS 界面为原型，在既有 `lithe-core` 之上新建一套 Rust/GPUI 工作台，同一份界面代码适配 macOS、Windows 和 Linux。迁移期编辑器先用 WebView 承载现有 Monaco，再逐步换成 gpui-kit 原生编辑器；首批 Linux 只承诺 X11，不支持 Wayland。新工作台不依赖 Windows 现有的 React/Tauri 实现，也不改动 `lithe-core` 的公开命令面。

## 问题

Lithe 现在有两套各自实现的界面：

- macOS 使用 SwiftUI/AppKit，源码约 22.4 万行，其中视图 8.1 万行；编辑器是 WebView 里的 Monaco，终端是 SwiftTerm。
- Windows 使用 React/Tauri，TypeScript/TSX 约 34 万行；编辑器同样是 Monaco，终端是 xterm.js。
- 两端共享 `rust/lithe-core`（约 19.6 万行、约 240 个 JSON 命令）以及契约、fixture 和 i18n 词条。

两套界面的差距已经出现：`shared/platform-feature-matrix` 里的 212 项能力，macOS 实现 176 项，Windows 只有 149 项（31 项缺失、18 项不完整）。如果再为 Linux 写第三套界面，同一个产品行为会被实现三次，任何新功能都要重复排期，界面问题也会在三个地方以不同方式出现。

GPUI 是 Zed 编辑器使用的 Rust 原生界面框架，由 GPU 渲染。gpui-kit 在 GPUI 之上提供主题、布局、停靠面板、表格、树、Diff、Markdown、命令面板等桌面控件。两者结合后，界面可以用一套 Rust 代码覆盖三个平台，并直接调用同一个进程内的 `lithe-core`，不需要再经过 Tauri 或 C ABI。

本提案不回答“Windows 的 React 界面何时下线”，也不把 Tauri 作为依赖或迁移来源；那部分由其他工作同步。

## 提案

### 总体结构

新增一个独立 Cargo workspace，与现有 macOS/Windows 产品并存：

```text
Lithe-IDEA/
├── rust/                     # 既有业务核心，保持公开命令面不变
├── gpui/
│   ├── lithe-ui/             # 设计系统：token、主题、图标、字体、i18n、Lithe 通用控件
│   ├── lithe-workbench/      # 壳：窗口、顶栏、活动栏、Dock、标签、状态栏、命令面板
│   ├── lithe-features/       # 领域界面：editor、git、search、run、debug、agent、settings、plugins
│   ├── lithe-platform/       # 平台适配：对话框、剪贴板、通知、单实例、深链、菜单、存储
│   └── lithe-desktop/        # 可执行入口：启动、依赖注入、窗口、打包
├── shared/                   # 契约、i18n、功能矩阵，继续作为唯一来源
└── frontend/editor/          # Monaco，仅作为迁移期 WebView 内容
```

开发者写代码时按下面的边界放置：

- 界面只通过 `lithe-core-client`（新 crate）调用业务能力。该 crate 把现有 JSON 命令封装成 typed 异步接口和事件流，界面不拼 JSON、不解析错误字符串。
- 任何平台差异（文件对话框、剪贴板、通知、窗口状态、更新）放在 `lithe-platform` 的 trait 后面，三端各写一个实现；业务 crate 不出现 `cfg(target_os)`。
- 界面只依赖 `gpui-kit` 一个 UI crate，引用方式是 `use gpui_kit::*`，不直接依赖 GPUI。gpui-kit 固定版本，不跟随每周快照漂移。
- 状态归属遵守 gpui-kit 的编码规范：跨渲染保留的状态放 `Entity<T>`，一次性呈现用 `RenderOnce`，列表和重复元素使用业务 ID 生成的 `ElementId`，不用下标。
- 模块、贡献点、插件契约继续复用现有 manifest 和 fixture；把 Swift 的 `LitheModuleAPI` 协议映射成 Rust trait，不重新设计一套贡献模型。

### 设计基线

不逐行翻译 SwiftUI 视图，而是保留 macOS 的信息架构、交互模型和尺寸体系，用 gpui-kit 的组件行为重新实现。

| macOS 现有 | GPUI 落点 |
| --- | --- |
| `LitheTheme.Palette` 的约 40 个 token，三套主题 × 明暗 | gpui-kit 主题 JSON + 应用层 `LitheTokens`；`Lithe`、`Codex`、`Linear` 各一份 |
| 顶栏 40pt、活动栏 40pt、状态栏 24pt、工具窗标题 41pt、编辑标签 34pt、树行 24/27pt | `LitheMetrics` 常量；由 Lithe 皮肤覆盖 gpui-kit 默认密度 |
| Inter（界面）与 JetBrains Mono（代码） | gpui-kit 主题字体；启动时注册打包字体，并显式声明 CJK 回退 |
| IDEA 原始 SVG（expui，16/20pt） | 自定义图标资产源；只有 IDEA 没有对应物时才用 Lucide |
| 左/右/底部工具窗，每组只显示一个，可拖拽换位、持久化 | gpui-kit 的 Dock（布局树、面板注册表、序列化）；标题栏和折叠条自绘 |
| 多行编辑器标签 | 自研，gpui-kit 的标签栏是单行滚动加溢出菜单 |
| 项目树、Git 列表、提交表格 | `Tree`、`List`、`DataTable`，行样式覆写成 IDEA 尺寸 |
| Diff 审查 | `Diff` 的 Split/Unified 模式、行号、语法高亮、hunk、注解和 gutter marker |
| 项目/分支下拉、右键菜单 | `PopupMenu` 加自绘触发器；系统菜单用 native menu |
| 设置窗口 | gpui-kit 的 Settings 加自研行组件（标签、控件、状态 badge、信息提示） |
| Search Everywhere、命令面板 | `Command` |
| Agent 会话 | 消息滚动器、消息、Markdown TextView、Shimmer、附件 |
| 终端 | 自研：PTY 加 VT 解析加 GPUI 元素 |
| Mermaid、HTML 预览、插件 Web 窗 | gpui-webview 作为独立内容岛 |

必须自研的四块是：多行编辑器标签、终端、编辑器适配层、Lithe 工具窗容器（41pt 标题、拖拽换位、布局持久化）。

#### 正确做法

- 新界面写颜色、字号、圆角、间距时，从 `LitheTokens`/`LitheMetrics` 取语义值。
- 新控件先确认 gpui-kit 是否已有等价行为；有就组合，没有才在 `lithe-ui` 里新建，并把外观和交互一起封装。
- 需要嵌 Monaco、Mermaid 或插件网页时，把它当成一个内容岛，周围顶栏、标签、状态栏仍是原生 GPUI。
- 平台差异先加 trait，再写三个实现；没有实现的平台在编译期显式失败，不静默降级。

#### 不要这样做

- 不要把 SwiftUI 的视图树一比一翻译成 GPUI 元素。AppKit 的控件语义、布局优先级和焦点模型在 GPUI 里不存在对应物，逐行翻译会把平台细节带进共享代码。
- 不要在业务视图里写十六进制颜色、魔法尺寸或 `cfg(target_os)`。
- 不要让界面代码直接调用 `lithe_core::execute_json` 再手工解析字段；这会绕过类型检查，并让契约变化在运行时才暴露。
- 不要把 WebView 当成长期编辑器方案。它会让 Monaco 成为第二套编辑器实现，并且 Linux Wayland 不可用。
- 不要在首批 Linux 支持里承诺 Wayland；gpui-webview 在 Wayland 下没有实现。

### 编辑器双轨

阶段一使用 gpui-webview 承载现有 Monaco，覆盖 macOS、Windows 和 Linux X11。这样迁移期可以复用 `frontend/editor` 的语法、LSP、Vim 和 Diff 行为，先把工作台跑通。

阶段二并行开发原生编辑器（gpui-kit `Editor`：tree-sitter 高亮、LSP 补全/诊断/Code Action、查找替换、多光标、折叠）。原生编辑器需要补齐的 parity 清单至少包括：

- TextMate 语法迁移到 tree-sitter 后的着色一致性；
- 语义高亮；
- Vim 模式；
- 多光标；
- 查找替换；
- 代码折叠；
- Git gutter、blame、Diff 装饰；
- 大文件性能；
- 中文/日文/韩文输入法与候选框；
- 无障碍；
- 编码切换与光标历史。

退出条件：原生编辑器在日常 Java 编辑上达到 Monaco 现有能力的 80%，才允许把默认编辑器切过去；没有达到就继续双轨，但每季度复核一次，避免 WebView 变成永久方案。

### 其它技术决定

- **终端**：把 `windows/tauri/crates/terminal` 的 PTY 管理提升为 `rust/` 共享 crate，补上 VT 解析（如 alacritty_terminal）和 GPUI 渲染；现有 `terminal-profiles.md` 契约不变。
- **Agent**：`lithe-agent-host` 已是 Rust，直接复用；界面用聊天组件加 Markdown，思考过程、工具分组、子代理和权限条自绘。
- **i18n**：扩展 `scripts/i18n/generate-i18n.mjs`，在 Swift/TS 之外增加 Rust 目标；词条唯一来源仍是 `shared/i18n/`，界面不硬编码文案。
- **无障碍**：GPUI 的无障碍能力弱于 SwiftUI。树、编辑器、对话框和设置这四条关键路径必须建立语义并使用平台工具验证；缺口记录在功能矩阵，不假装通过。
- **更新与签名**：不属于界面迁移本身。macOS 的 Sparkle、Windows 的更新器和 Linux 包格式需要单独立项；界面层只暴露“检查/下载/应用”三个动作。
- **Linux 范围**：首批只支持 X11（含 XWayland）。Wayland 原生窗口不是验收条件；等编辑器、Markdown 和插件内容都原生化后，再单独评估。

### 分阶段

| 阶段 | 周期 | 交付物 | 退出标准 |
| --- | --- | --- | --- |
| 0. 技术验证 | 3 周 | 工作台骨架、真实项目打开、项目树、单文件编辑器、WebView 三端冒烟、编辑器 A/B 报告 | 中文输入可用；LSP 能跳转和补全；Dock 拖动稳定；启动低于 1.5 秒；内存低于 500MB；三端能编译运行 |
| 1. 只读 IDE | 8 周 | 欢迎页、项目打开/切换、项目树、编辑器读写、标签、主题、i18n、快捷键、命令面板 | 能用自己的 Java 项目日常阅读代码 |
| 2. 核心工作流 | 12 周 | Git（status/diff/log/branch/commit）、三种搜索、终端、运行、设置、通知、文件监听、内存监控 | 覆盖 macOS 现有工作流的 80%，功能矩阵逐项打勾 |
| 3. AI 与高级能力 | 12 周 | Agent、MCP、AI Commit、插件、Markdown 预览、数据库、调试 | macOS 功能矩阵 176 项中至少 90% 在 GPUI 可用 |
| 4. 平台化 | 8 周+ | 更新、签名、打包（dmg/msi/AppImage/deb）、性能门禁、灰度 | 三端可发布，旧界面保留一个版本可回退 |

### 验证方式

- 每个阶段用 gpui-kit 的 UI 集成测试（`#[gpui_kit::test]`）覆盖交互结果，不复刻实现细节。
- 业务行为继续由 `rust/` 里的现有测试和契约 fixture 保证；界面迁移不修改这些契约。
- 视觉回归按平台 × 主题 × 缩放比例出基线截图，复用现有 `docs/visual-qa` 的组织方式。
- 在 `shared/platform-feature-matrix` 增加 `gpui` 字段，记录实现状态、证据路径和验证方式；新增能力与界面改动同 PR 更新。
- 性能门禁：启动时间、空闲内存、Dock 拖动帧率、大文件滚动帧率。

## 考虑过的备选方案

### 把 SwiftUI 视图逐行翻译成 GPUI

表面上最“保真”，但 SwiftUI 的布局优先级、焦点、滚动和 AppKit 控件在 GPUI 中没有一一对应物。逐行翻译会把平台语义带进共享代码，最终既不像 macOS 原生，也无法在 Windows/Linux 正常使用。因此只保留信息架构和视觉规则，交互用 GPUI 重新实现。

### 三端统一用 Tauri 加 React

可以最快复用现有 Windows 界面和 Monaco，但需要为 macOS 重写一套 React 壳，且与本次 GPUI 目标不一致。本提案不把 Tauri 作为依赖；Windows 现有实现由其他人维护和同步。

### 只做 Windows+Linux，保留 macOS SwiftUI

风险最低，但维护成本仍然是两套界面，而且 macOS 是当前质量最高的原型，不参与迁移就无法验证三端一致性。用户已明确要求以 macOS 为原型适配三端。

### 全部内容都用 WebView

可以直接复用 Monaco、Markdown 和插件网页，但 Linux Wayland 不可用，Windows 上 WebView 会盖住 GPUI 浮层，而且每个区域都要维护两套渲染。因此只把 WebView 用于内容岛。

### 保留双原生界面，再为 Linux 写第三套

功能最稳，但三套实现会让功能矩阵和缺陷修复继续分叉，违背“一套代码三端”的目标。

## 验收标准

- macOS、Windows、Linux X11 三个平台能编译、启动，并打开同一个项目。
- Phase 0 的所有门槛通过，编辑器双轨方案有明确的切换结论。
- 工作台的信息架构、尺寸和交互与 macOS 原型一致：顶栏、活动栏、工具窗、编辑标签、状态栏的位置和行为可逐项对照。
- 主题支持 Lithe/Codex/Linear × 明暗，界面不出现散落的硬编码颜色。
- 所有用户可见文案来自 `shared/i18n/`，Rust 目标与 Swift/TS 目标同源。
- 功能矩阵新增 `gpui` 列，Phase 3 结束时 macOS 176 项能力中至少 90% 可用。
- 启动、内存、Dock 拖动和大文件滚动达到既定性能门禁。

## 风险

| 风险 | 说明 | 应对 |
| --- | --- | --- |
| gpui-kit 仍年轻 | 当前 0.8.1，WebView 标注实验性，GPUI 快照每周可能变化 | 固定版本；只用公开 API；自研组件封在 `lithe-ui`，便于替换 |
| 编辑器 parity 不足 | Monaco 的语法、Vim、语义高亮和大文件能力短期难补齐 | 双轨运行；设定 80% 门槛；每季度复核 |
| 中文输入法 | GPUI 的 IME 在三端成熟度不一致 | Phase 0 必须实机测试候选框、组合输入和焦点切换 |
| Linux Wayland | gpui-webview 不支持 Wayland | 首批只支持 X11；原生化后再评估 |
| 无障碍 | GPUI 支持弱于 SwiftUI | 四条关键路径专项建设；缺口进入功能矩阵 |
| 更新与签名 | 三个平台的更新机制完全不同 | 单独立项，不混入界面迁移 |
| 团队 Rust UI 经验 | SwiftUI/React 的开发习惯不能直接迁移 | Phase 0 结对开发，先定组件规范再铺量 |
| 双轨维护 | 迁移期两套界面同时存在 | 明确移植清单和新功能归属，不把 WebView 当永久方案 |

## 适用范围

- `rust/`
- `shared/contracts/`
- `shared/i18n/`
- `shared/platform-feature-matrix/`
- `scripts/i18n/`
- `macos/Sources/Lithe/Views/`
- `macos/Sources/Lithe/Theme/`
- `macos/Resources/IDEAIcons/`
- `frontend/editor/`
