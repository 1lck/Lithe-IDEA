# Agent 笔记：Windows 本地终端的 ConPTY 编进程序、装到用户缓存

状态：已实现

## 先说结论

Windows 系统自带的 ConPTY（伪控制台，Windows 给终端程序提供的“假控制台”接口）会改写程序输出，导致颜色查询收不到回应、同步刷新撕裂、全屏程序拿不到鼠标。Lithe 因此随客户端携带 Microsoft 发布的新版 `conpty.dll` 与 `OpenConsole.exe`。这两个文件编译进 Windows 可执行文件，首次打开终端时写到用户缓存目录里按内容摘要命名的文件夹，再从那里加载；安装目录里不放任何 ConPTY 文件。加载失败时终端回落到系统 ConPTY 照常运行，并记一条 WARN 日志。

## 问题

系统 ConPTY 位于 kernel32，它会先自己解析程序的输出，再重新绘制一遍发给终端。用户能看到三类问题：

- 程序发出的 OSC 10/11（查询默认前景色、背景色）被系统 ConPTY 吃掉，Codex 等程序拿不到配色。
- 同步更新（DECSET 2026，程序声明“这一段一次画完”）结束后又被重绘一次，画面撕裂。
- 全屏程序开启的鼠标上报模式丢失，鼠标点击到不了程序；Windows 10 的系统 ConPTY 还会丢弃增强键盘序列，Shift+Enter 在 TUI 程序里变成提交。

Microsoft 在 NuGet 包 `Microsoft.Windows.Console.ConPTY` 中发布的 ConPTY 只转发程序的原始字节流，不再重绘。问题在于：这组文件放在哪里，才能既让终端加载到，又不改变发行安装目录（安装目录是签名和增量更新的基线，见仓库根 `AGENTS.md`“已发布程序包的运行时只读边界”）。

## 决策

- **文件进 Git，只有一份来源。** `desktop/internal/localshell/conpty/` 存放未修改的二进制、`LICENSE.txt` 和 `NOTICE.md`。`NOTICE.md` 写明包版本、每个文件的 SHA-256 和来源路径；`TestTheConPTYFolderMatchesItsNotice` 核对哈希、PE 机器类型，并拒绝表中没有的文件。
- **编译进 Windows amd64 和 arm64 可执行文件。** `files_windows_amd64.go`、`files_windows_arm64.go` 用 `go:embed` 嵌入本架构的 `conpty.dll`，以及按内核架构选择的 `OpenConsole.exe`（x64 程序还要带 arm64 宿主，供 Windows on ARM 上运行的 x64 Lithe 使用）。其他平台和 386 不嵌入，`Install` 返回 `ErrUnavailable`。这不算降级，不记日志。
- **运行时写到用户缓存，不写安装目录。** `conpty.Install` 把整组文件写到 `%LocalAppData%\Lithe\conpty\<digest>\`。`<digest>` 由每个文件的路径、长度和内容算出，所以不同版本的文件组写进不同文件夹，互不覆盖。已经是正确字节的文件不重写；缺失或内容不对的文件经同目录临时文件再改名原子替换，DLL 加载位置上不会出现写了一半的文件。
- **加载失败就回落，并记录原因。** `localshell/conpty_windows.go` 用 `LoadLibraryEx` 只在 DLL 所在目录和 System32 中查找依赖。安装、加载或创建控制台任一步失败时，改用系统 ConPTY 启动 Shell，并通过 `Config.Degraded` 把原因交给 termview。日志事件为 `app.background.operation_failed`，`operation=terminal_conpty`，级别 WARN。回落时 Shell 照常运行，日志是唯一能看出“正在降级运行”的地方。
- **每个进程只安装一次。** `bundledConPTY` 用 `sync.Once` 包住安装和加载，之后的终端直接复用同一个已加载的 DLL。

### 正确做法

- 升级 ConPTY 时，替换文件并同时更新 `NOTICE.md` 的表格；新文件组得到新摘要文件夹，正在运行的旧版本客户端继续用自己的文件夹。
- Windows 测试通过 `conptyRootOverride` 指向系统临时目录下固定的 `lithe-localshell-test-conpty`，不写用户真实的 `%LocalAppData%`。测试用固定目录，是因为已加载的 DLL 无法删除，每个测试各建一个临时目录会越积越多。

### 不要这样做

- 不要把 `conpty.dll` 或 `OpenConsole.exe` 复制到可执行文件旁边或安装目录中，也不要从 `os.Executable()` 推导写入位置。这会改变发行基线，或者要求安装器、便携包、更新器各自多处理一组文件。
- 不要在启动时删除旧摘要文件夹。另一个正在运行的客户端可能已经加载了它，Windows 不允许删除，强行清理只会制造偶发失败。
- 不要因为回落到系统 ConPTY 就弹窗或中止终端。终端主体功能仍然可用，用户只会失去上面三类增强。

## 考虑过的备选方案

### 像 Motty 那样作为可执行文件旁的附带文件分发

Motty d61d1910 把这组文件放在程序旁边，再由安装器、便携 zip 和便携更新器各自携带（伴随 Viva 打包改动 `vivaui/viva@647c2069`）。它的好处是运行时不写任何文件，`LoadLibrary` 直接从程序目录加载。Lithe 没有采用，原因有三：需要升级 Viva 固定版本并改动 Windows 打包与更新流程；`go test`、`go run` 构建出的程序旁边没有这些文件，测试跑的就不是发行路径；文件组要在 Git、打包脚本、更新清单三处保持一致。

### 只在发行构建中用构建标签嵌入（类似内置字体）

内置字体（`.agents/notes/implemented/feature/2026-09-30-macos-bundled-ui-font.md`）只在发行构建中带 `lithe_bundled_fonts` 标签，因为字体约 25 MB。ConPTY 的文件组在 x64 上约 2.4 MB、在 arm64 上约 1.3 MB，而且它决定终端行为是否正确：开发构建和测试应当跑和发行版相同的终端。因此所有 Windows amd64/arm64 构建都嵌入它。

### 运行时从 NuGet 下载

可以让可执行文件不变大。没有采用：离线环境用不了，首次打开终端要等网络，还会多出一条运行时供应链，需要额外的签名和哈希校验。

### 每个进程写到一次性临时目录

实现最简单，不用处理并发安装。没有采用：已加载的 DLL 在进程结束前删不掉，崩溃后也不会清理，临时目录会不断积累。按摘要命名的缓存文件夹可以被所有进程复用。

### 继续只用系统 ConPTY

不增加任何文件。没有采用：上面三类问题会一直存在，而且无法在 Lithe 一侧绕过。

## 后果

- 收益：Windows 本地终端能收到颜色查询回应，同步更新只绘制一次，鼠标上报和增强键盘协议能送达程序；安装目录、代码签名和增量更新基线不变；测试和发行版走同一条加载路径。
- 代价：Windows amd64 可执行文件约增加 2.4 MB，arm64 约增加 1.3 MB。每个版本的文件组会在 `%LocalAppData%\Lithe\conpty\` 留下一个文件夹，旧文件夹不会自动清理，直到用户清理缓存。
- 风险：AppLocker 或 WDAC（Windows 的应用白名单策略）可能禁止从 `%LocalAppData%` 加载 DLL 或启动程序，这时终端会回落到系统 ConPTY，只能从 WARN 日志看出原因。首次安装要计算并比较约 2.4 MB 的内容，当前仍在调用 `localshell.Start` 的 UI 线程上执行（见 #1988）。
- 重新评估的触发条件：Windows 自带的 ConPTY 修复了上述行为；Viva 打包原生支持附带文件且 Lithe 已升级到包含该支持的固定版本；或者企业环境的回落日志明显增多。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/localshell/... ./internal/termview/ ./internal/workbench/ -count=1`：核对文件组清单、安装与修复、降级日志的转发。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认运行时没有写入发行目录。
- `node scripts/resources/test-reuse-worktree-resources.mjs`：确认 ConPTY 二进制登记为不可跨工作树复用的 Git 内资源。
- 在 Windows 上运行 `TestBundledConPTYDeliversColorQueriesAndKeepsSyncBlocksAtomic`、`TestBundledConPTYForwardsMouseReporting` 和 `TestAShellStartsOnTheInboxConPTYWhenTheBundledOneCannotBeInstalled`，它们只在 Windows 编译。

## 适用范围

- `desktop/internal/localshell/conpty/`
- `desktop/internal/localshell/conpty_windows.go`
- `desktop/internal/localshell/backend_windows.go`
- `desktop/internal/termview/session.go`
