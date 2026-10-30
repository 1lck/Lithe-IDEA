# Lithe GPUI 工作台（Phase 0）

以 macOS 界面为原型的三端 GPUI 工作台。壳、核心链路和主要工具窗已经接通，调试尚未实现。

## 结构

```text
gpui/
├── lithe-ui/           设计系统：token、主题、字体、图标、活动栏、工具窗标题、多行标签、状态栏
├── lithe-core-client/  lithe-core 的 typed 阻塞客户端
├── lithe-platform/     文件对话框、打开 URL、最近项目
├── lithe-features/     项目树、WebView 编辑器、欢迎页
├── lithe-workbench/    顶栏、活动栏、分栏、标签、状态栏、打开项目/文件
└── lithe-desktop/      三端启动入口
```

依赖方向见 [`ARCHITECTURE.md`](./ARCHITECTURE.md)。

## 运行

Monaco 资源不随源码提交，首次运行前先生成：

```bash
npx -y bun@1.3.12 install
npx -y bun@1.3.12 gpui/editor/build.ts
```

然后：

```bash
cargo run -p lithe-desktop
```

启动时直接打开指定项目：

```bash
cargo run -p lithe-desktop -- --open-project <path>
```

`<path>` 是有效目录时首帧即进入该工作区；参数缺失或路径无效时静默忽略，回到欢迎页 / 最近项目。

首次运行前先做一次静态检查：

```bash
cargo check -p lithe-desktop
```

工作区固定使用 `1.97.1`（见 `rust-toolchain.toml`）；本机默认 stable 1.99.1 的
`rust-std` 文件缺失，会在基础 crate 报 `can't find crate for std`。

### 平台要求

- **macOS**：GPUI 使用 Metal；窗口使用 `TitleBar::window_options()` 的自绘标题栏。
- **Windows**：需要 WebView2 运行时；启动前设置 `GPUI_DISABLE_DIRECT_COMPOSITION=true`（入口已处理）。
- **Linux**：首批只支持 X11 / XWayland。需要 WebKitGTK、GTK3 与 X11 开发库；入口显式使用 `gpui_kit::platform::linux(WindowingModes::X11)`。Wayland 原生窗口不在本轮范围。

## 当前能力

| 状态 | 功能 |
| --- | --- |
| 已实现 | Quick Open、Save As、Local History、通用输入弹窗、终端分屏、编辑器只读分屏，以及下列既有能力 |
| 未实现 | 调试（Stop / Breakpoint）：`lithe-core` 已有 `debug.*` DAP 命令面，GPUI 宿主缺少 DAP 传输与调试 UI，菜单项保持禁用 |

- 打开最近项目、系统目录对话框、顶栏项目切换器（项目渐变头像）。
- 懒加载项目树：展开、刷新、右键新建/重命名/删除（删除二次确认）。
- macOS 锚点工具窗：左（Project/Changes/Search/PR）、底（Git Log/Terminal/Agent/References/Problems/Spring/Run/Tests/Debug/Build Output）、右（Database/Services）；每个工作区独立持久化布局与尺寸。
- 左右活动栏：工具入口、通知、更新/背景占位；底部工具窗横跨整行。
- 多行编辑器标签、重复文件去重、关闭后自动激活相邻标签、未保存关闭确认。
- Monaco 编辑器：Java/Markdown/XML/CSS/HTML 语法着色、编辑、`Ctrl/Cmd+S` 保存、脏标记、行列号。
- Markdown 预览（预览磁盘上的已保存内容）。
- 顶栏分支切换器、真实分支名、状态栏 Git 变更计数。
- Git 工具窗：Changes 分组、Unified/Split Diff、Commit/Amend、Log、Stage/Unstage/Discard（丢弃二次确认）。
- 搜索工具窗：300ms 去抖、按文件分组、点击打开。
- 运行入口：常见项目类型（Cargo/npm/Maven/Gradle/Go/Python/Make/Compose/Procfile）检测候选命令，在终端执行。
- 终端工具窗：xterm.js + portable-pty。
- Agent 工具窗：自动发现已安装 ACP adapter，基础对话、权限、停止/重连。
- Monaco 轻量语言能力：补全、悬停、跳转定义、查找引用（走 Core `lsp.builtin*`，不启动语言服务器）。
- 设置页：7 组 19 页，English / 中文即时切换。
- 命令面板与快捷键、通知中心、内存状态、三套主题。

## 已知限制

- Monaco 没有接完整 LSP 服务器、TextMate 语义高亮和自定义上下文菜单；只有基础语法着色和 Core 的轻量补全/悬停/导航。
- 关闭未保存标签只能丢弃或取消，没有“保存后关闭”。
- 外部文件修改不会自动重载；页面重载后回到最近一次打开/保存的快照。
- 大文件通过 `evaluate_script` 传文本，受 WebView 脚本长度限制。
- 终端和 Monaco 都依赖 WebView：Linux 仅 X11，Wayland 不支持。
- Git 只做整文件 Stage/Unstage，没有 hunk 级操作；没有自动文件监视。
- Run 只按根目录常见文件做启发式检测，不使用 Core 的构建插件模型；不持久化自定义运行配置。
- Agent 只做基础对话，未接会话历史、模型/配置选择、Markdown 渲染和安装向导。
- 编辑器分屏只提供只读副窗格（同一文件的第二个观察点），不支持两个可写窗格；多项目标签页、同一窗口多组编辑器尚未实现。
- Debug/References/Problems/Spring/Tests/Build Output、插件市场、GitHub PR、完整 LSP、Java/Maven/Spring、数据库、远程开发、自动更新尚未实现（工具窗显示真实占位说明）。
- 已在 Windows + Rust 1.97.1 上通过 `cargo check --workspace --all-targets`、`cargo test -p lithe-core-client`，并实机验证启动稳定；交互功能请按上文步骤手动验证。
- macOS/Linux 尚未实机启动验证；Linux 仅承诺 X11。

## 约定

- 颜色只从 `LitheTokens` 或 `cx.theme()` 取，不在调用点写十六进制。
- 用户可见文案先走 `lithe_ui::i18n::tr`，后续由 `shared/i18n` 生成 Rust 目标替换。
- Core 调用是阻塞的，必须放在 `cx.background_spawn` 或后台线程。
