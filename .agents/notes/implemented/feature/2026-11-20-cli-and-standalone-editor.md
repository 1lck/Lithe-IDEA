# Agent 笔记：可选 CLI 注册与单文件编辑

状态：已实现

## 先说结论

Lithe 默认不向用户的命令行环境注册命令。用户在设置的“通用 > CLI”卡片明确点击后，才创建用户级启动器并修改显示的配置来源。命令打开文件夹时沿用完整项目流程；打开文件时使用独立的文本编辑窗口，任何插件都不创建或激活，文件的父目录也不会因此成为工作区。

## 问题

将普通文件当成项目打开，会启动与临时编辑无关的插件、索引和 Git 观察。安装时自动修改 PATH 又会影响用户的 shell 配置；只保存一个“已注册”偏好无法判断实际配置有没有被删除、改写或指向旧安装。

## 决策

- Core（共享 Rust 规则层）解析启动参数、根据原生文件类型选择模式，并给出单文件模式允许的命令。桌面端只做路径观察、进程启动和界面呈现。单文件窗口借用既有文档与标签生命周期，不调用项目打开流程；父目录只是文件位置，不进行项目恢复、信任确认、递归搜索或插件上下文绑定。
- 单文件模式保留内置语法高亮、文本编辑、查找替换、保存、编码与换行选择和单个文档的外部变更观察。Markdown、SVG 和 HTML 文件与项目窗口一样显示预览页（编辑 / 编辑与预览 / 预览切换，#2324 后续扩展）：Markdown 渲染页只读当前文档文本和它引用的图片，SVG 支持图片缩放查看与交互模式切换，HTML 通过 `previewWorkspaceRoot()` 传入空的 `workspaceRoot`，让每个 HTML 文件只以自身所在目录为站点根进行隔离预览。项目侧栏、Git、运行、调试、测试不呈现；图片、PDF、十六进制等二进制查看器仍不打开。终端默认关闭，由用户点击后才创建，使用当前文件所在目录，复用现有终端标签、分隔条及进程清理；隐藏面板保留会话，关闭标签或窗口释放 shell。单文件窗口不恢复或改写项目面板布局。双 Shift 和查找动作只列出允许的动作，不读取父目录。关闭全部文件后仍保持单文件空态。
- 单文件 Markdown 和 HTML 都没有工作区；调用 Core 的引用解析（`markdown.resolveReference`）或站点解析（`htmlPreview.site`、`htmlPreview.resolveRequest`）时省略工作区根目录参数（`workspaceRoot`），让每个文档自己的目录决定资源读取范围和站点根。单文件会话记录的首个文件父目录（`p.root`）只是窗口起点，不能当成随后打开的子目录或其他目录文档的工作区。项目窗口继续传项目根。
- 顶栏显示当前文件名与“单文件模式”，通过 ⓘ 解释边界。“以项目打开所在文件夹”使用当前选中文件的父目录，在另一窗口进入正常的项目信任和插件流程，保留原编辑窗口。
- CLI 卡片直接读取默认 shell 配置与启动器内容。macOS zsh 使用 `.zshrc`（尊重 `ZDOTDIR`），bash 使用实际登录配置，fish 使用自身配置；Windows 编辑当前用户注册表 PATH，保留其原生字符串类型，并有界广播环境变更。已有终端需重新打开。
- 打开页面只读，注册、修复和移除都来自明确按钮。Unix 来源使用带标记的配置块，Windows 只编辑匹配目录项；保留其他内容。写入前核对文件内容、来源目录和符号链接目标；读取后被外部改写则拒绝覆盖。Windows 注册表核对与单值写入间仍受外部进程竞争限制，不宣称跨进程事务。
- 启动器只位于系统用户配置目录的 `Lithe/cli/bin`，指向应用当前可执行文件。它是用户运行状态，由 CLI 注册管理器持有，不进入 app bundle 或 Windows 安装目录，不影响签名和增量更新的源基线。应用移动后允许显式修复完整的 Lithe 启动器格式，不覆盖其他命令。移除注册后删除属于 Lithe 的启动器。

正确做法：`lithe notes.go` 只打开该文件，随后用户明确点击“以项目打开所在文件夹”才在新窗口创建项目服务。不要因为已知文件父目录而调用项目初始化，再在界面上隐藏面板；那样仍然付出了插件和目录观察的开销。

## 考虑过的备选方案

- 安装或首次启动时自动写 PATH：违背默认不注册的要求，也无法让用户审阅修改目标。
- 在单文件窗口创建项目并禁用部分插件：项目管线仍会创建目录观察和恢复状态，无法保证任何插件都不激活。
- 把首个单文件的父目录当成所有文档的工作区：打开子目录文档时会允许它读取父目录图片，并把 `/image.png` 指向首个文件的目录。按文档传正确上下文，复用 Core 的既有解析及授权规则；首目录外的文档原本已由 Core 回退到自身目录，继续保持该行为。
- 只注册全局系统目录中的符号链接：Windows 与 Unix 所需权限不同，还可能要求管理员权限。用户级启动器可以保持显式注册且不修改安装资源。
- 在当前窗口将单文件直接升级为项目：会混合两种服务生命周期，产生插件初始化与未保存文档处理的隐含转换。使用正常项目新窗口复用已有完整流程，代价是多一个窗口。

## 后果

临时文件不再启动项目服务；命令可移除、可回读，并能发现外部改动。单文件模式没有插件语言智能，也没有图片、PDF 等二进制查看器；需要这些功能时必须明确打开所在文件夹。Markdown、SVG 和 HTML 预览在有系统网页引擎时会在打开文件时创建一个网页视图，常驻内存与项目窗口打开同一文件相同；切到“编辑”只隐藏它，关闭标签或窗口才释放。每次 CLI 调用会短暂启动一个只处理参数和路径的父进程，再脱离终端创建 GUI（图形界面）子进程，不保留 shell 管道或后台 shell。

## 验证

- `scripts/desktop/desktop-go.sh test ./cmd/lithe ./internal/cli ./internal/core ./internal/workbench -run 'TestCLI|TestStandalone|TestDesktopStartupMakesInstalledPluginSettingsReachable' -count=1 -timeout=90s`：链接同一 Core 检出，验证真实文件类型、共享 fixture、真实临时 shell 配置的注册/修复/移除/冲突保护和独立编辑保存。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/settingswindow ./internal/workbench -run 'TestVisualCLISettings|TestVisualStandalone' -count=1 -timeout=90s`：生成明暗主题、中英文的真实渲染截图。通过 `LITHE_VISUAL_OUTPUT_DIR` 指定本工作树的输出目录。
- `TestStandaloneMarkdownImagesUseEachDocumentsFolder`、`TestStandaloneMarkdownWebPreviewKeepsScopeAndLifecycle`、`TestStandaloneHTMLShowsPageAndIsolatesEachFilesFolder`、`TestStandaloneSVGShowsPictureAndInteractiveMode`、`TestProjectMarkdownKeepsWorkspaceRootForNestedDocuments` 与 `TestPreviewWorkspaceRootReturnsEmptyOnlyForNilOrStandalone` 验证后续子目录及无关目录文档的本地图片、`/` 引用、符号链接与父目录越界图片、HTML 站点隔离、SVG 缩放与交互模式、链接跟随及项目模式对照；网页视图替身只证明宿主接线，不替代 WKWebView/WebView2 原生验收。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：检查两个桌面平台的发行目录只读边界。
- Windows 规则可以在 macOS 上以平台参数验证；注册表写入、环境广播与 cmd/PowerShell 调用仍需 Windows 原生环境验收，交叉编译不替代该验收。

## 适用范围

- `desktop/cmd/lithe/`
- `desktop/internal/cli/`
- `desktop/internal/core/cli.go`
- `desktop/internal/workbench/standalone.go`
- `desktop/internal/workbench/preview_pages.go`
- `desktop/internal/workbench/standalone_markdown_references_test.go`
- `desktop/internal/settingswindow/cli_view.go`
- `shared/platform-feature-matrix/features/cli-single-file-mode.json`
