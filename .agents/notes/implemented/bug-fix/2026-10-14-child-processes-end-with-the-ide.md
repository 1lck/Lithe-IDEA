# Agent 笔记：Lithe 退出时结束它启动的全部子进程

状态：已实现

## 先说结论

Lithe 启动的运行、服务、预启动任务、测试、构建和插件进程，生命周期都绑定在 Lithe 上：关闭项目或退出时，由 Core 的进程生命周期规则决定哪些进程需要询问，再由所属模块停止自己的会话。Windows 上构建进程放进 Job Object，Lithe 崩溃时内核也会连带结束整组进程。进程账本在 macOS 和 Windows 上都登记，崩溃后的残留在下一次启动时清扫；Windows 的账本只通过进程句柄调用系统接口，不启动任何外部程序。忙碌终端和运行服务在关闭前统一询问，用户可以选择停止或取消。

## 问题

运行 Spring Boot 配置后退出 Lithe，Java 进程留在系统里继续占着 8080 端口，父进程变成系统的 launchd（macOS）或失去所有者。

两个原因叠加：

1. **服务会话没人停。** 运行服务里“当前运行”和“服务会话”是两套状态。Spring Boot 这类配置属于服务会话，只调用“停止当前运行”时，服务会话收不到任何信号。
2. **停止是异步的，进程退出不等它。** 发出 SIGTERM 后把“超时再 SIGKILL”交给异步任务；应用马上退出时这个任务来不及执行，忽略 SIGTERM 或关闭较慢的子进程就会活下来。

## 决策

### 正确做法

1. **所属模块停自己的全部会话。** 停止执行模块时，要同时停止当前运行、全部服务会话和测试；服务运行期间，执行模块不能被判定为空闲。
2. **退出前有一道不依赖所有者的兜底。** 进程在 Viva 的进程账本（`desktop/internal/processledger/processledger.go`）里登记，记录 PID、启动时间和命令名；只结束账本里自己写入的、身份仍匹配的进程，不按名字搜索进程。兜底必须有界：先请求停止，等待宽限期，仍存活的再强制结束，不能无限等待。
3. **询问规则由 Core 决定。** Core 的 `processLifecycle.resolve` 对运行服务在 `quit`、`closeWorkspace`、`closeTerminalTab` 场景返回 `confirmStop`（设置为询问）或 `terminate`（设置为直接停止）。规则失败时按“询问”处理。宿主只负责列出当前有什么、判断终端是否忙碌，不自行决定要不要问（`desktop/internal/core/process_lifecycle.go`）。
4. **Windows 按进程树归属停止。** 构建进程用 Job Object 管理（`desktop/internal/buildprocess/process_windows.go`），停止时结束整组进程，而不是只按父 PID 链查找后代（`taskkill /T` 在中间进程先退出后会漏掉后代）。Job 的 kill-on-close 语义保证 Lithe 崩溃时内核也会结束整组。
5. **一个退出入口。** 退出、关闭窗口和关闭项目都走同一套确认流程（`desktop/internal/workbench/process_exit.go`），未保存文件确认在前，运行服务询问在后；更新安装前也要先停止运行服务。

### Viva：运行会话与忙碌终端的确认

Viva 客户端（`desktop/internal/workbench/process_exit.go`）把关闭时要问的东西交给同一条 Core 规则，自己只负责“现在有什么”和“它是否在忙”。

- **什么叫忙碌终端。** 终端里的 shell 正在运行别的程序（比如 `npm run dev`），而不是停在提示符。macOS/Linux 读 pty 的前台进程组（`TIOCGPGRP`）：前台组不是 shell 自己就是忙。Windows 的控制台没有前台组的概念，改看 shell 进程有没有子进程。判断放在 `localshell.Shell.Busy()`，读不出来时一律算空闲。
- **在哪里问。** 退出用 `quit` 场景；关闭项目时终端随项目一起结束，终端记录按 `closeTerminalTab` 场景交给 Core，运行会话按 `closeWorkspace`。两组结果里 `confirmStop`（运行会话）和 `confirm`（忙碌终端）合并成一次“全部结束或取消”的确认；关闭单个忙碌终端标签页时单独问一次。空闲终端 Core 返回 `terminate`，直接关闭。
- **探测不在窗口线程上跑。** 窗口线程只取出每个终端的探测函数（`termview.View.BusyProbe`），真正的系统调用（Windows 上是一次进程快照）在后台任务里执行，避免关闭时界面卡住。
- **不要这样做：** 不要在工作台里自己判断“忙碌终端要不要问”，也不要把 `confirm` 当成可以忽略的动作；这两件事由 Core 的规则和用户设置决定。也不要把 shell 有输出当作忙碌的依据：提示符本身也是输出。

### Windows：账本不启动外部程序

2026-11-25 修复：Windows 上每次构建、运行、测试、调试时都会闪出一个立刻关闭的控制台窗口。

- **原因。** 账本核对进程身份时运行 `ps -o lstart= -o comm= -p <pid>`，结束进程时运行 `kill`，不分平台。Lithe 是没有控制台的图形程序，它不加隐藏标志启动的控制台程序会自己开一个控制台窗口。Windows 本来没有 `ps`，但 Git for Windows 的 `usr\bin`、MSYS2、Cygwin 等工具链会把它们的 `ps.exe` 放进 PATH；这些 `ps` 不认识 `-o`，打开窗口后马上报错退出，看起来就是一闪而过。找不到 `ps` 或 `ps` 报错时身份读不出来，所以账本在 Windows 上实际从来没有登记成功过。
- **做法。** 平台差异放在 `processledger_unix.go` 和 `processledger_windows.go`，账本的记录、核对和清扫逻辑仍只有 `processledger.go` 一份。Windows 用 `OpenProcess`（`PROCESS_QUERY_LIMITED_INFORMATION`）打开进程，`GetProcessTimes` 的创建时间（100 纳秒精度的十进制数）作为启动时间，`QueryFullProcessImageName` 的完整路径作为命令名；已退出但仍有句柄未关闭的进程也能打开，所以先用 `WaitForSingleObject(handle, 0)` 确认它还在运行。结束用 `TerminateProcess`：Windows 没有可以发给任意进程的停止请求（与 `buildprocess.StopsGracefully` 为 false 一致），所以请求停止和强制结束都直接结束进程，不等宽限期。
- **覆盖面。** 经 `buildprocess` 启动的构建、运行、测试、调试、项目生成和工具安装进程，插件发起的运行（`pluginservice/runs.go`）和终端 shell（`localshell/backend_windows.go`）都在 Windows 上登记。构建类进程本来就在 kill-on-close 的 Job Object 里，账本是第二道保险；ConPTY 终端不在 Job Object 里，崩溃后的残留只能靠账本在下次启动时清扫。
- **不要这样做：** 不要在客户端里启动 `ps`、`kill`、`tasklist`、`taskkill` 之类的控制台程序来查询或结束进程：Windows 上它们会弹出控制台窗口，PATH 上同名的程序也不一定是你以为的那个（`ps`、`kill` 在 Windows 上来自第三方工具链，参数和输出格式都不一样）。也不要为了不闪窗口而在 Windows 上关掉账本：账本是崩溃后清扫残留的唯一依据。

### 反例

- 只在所有者的停止函数里发信号就返回：所有者漏掉一类会话，或者进程在异步升级前退出，子进程都会变成孤儿。
- 兜底只查进程名：同名进程可能属于别的程序，账本必须按 PID、启动时间和命令名共同确认。
- 退出时无限等待子进程：一个卡住的子进程会让应用退不出去。兜底必须有界。
- 在宿主里按插件或语言名字挑进程来杀：兜底针对的是进程的所有权，与进程属于哪个插件无关。

## 考虑过的备选方案

- **只修执行模块的停止函数。** 能解决 Spring Boot 这一例，但下一个漏停的所有者、以及异步升级被进程退出截断的问题仍在。
- **让子进程自己感知父进程死亡。** macOS 没有 Linux `PR_SET_PDEATHSIG` 那样的机制；用户的 Java 程序也不可能放入这类代码。
- **Windows 继续用 `taskkill /T`。** 中间进程退出后 PID 链断开的问题仍在，崩溃时也没有任何兜底。
- **给运行服务提供“保留”选项。** 运行服务的输出管道和进程树都归 Lithe，Lithe 退出后保留只会制造无人管理的孤儿，所以确认里只有停止和取消。

## 后果

正常退出和更新重启后不再留下运行、服务或测试进程。退出时只在有子进程不肯退出时才会等满宽限期，等待有上限。

未覆盖的情况：

- **Lithe 崩溃或被强制结束。** 进程内兜底不会执行，崩溃后的残留由进程账本在下一次启动时清理（`startupSweep` 场景），macOS 和 Windows 相同；两个平台都还没有监护进程，崩溃当下不清理。
- **不经过宿主进程管理的进程。** 语言服务器由 Core 的语言工具会话停止，内置终端由终端自身管理。
- **Windows 终端里启动的程序。** ConPTY 终端的 shell 已登记在账本中，但它启动的程序既不在 Job Object 里，也不在账本里；Lithe 崩溃后 shell 自己会在下次启动时被清扫，已脱离 shell 的程序仍可能残留。正常退出由终端的关闭流程处理。
- **已知差异。** shell 被 `exec` 替换（如 `exec vim`）后进程号不变，会读作空闲；Windows 上 WSL 终端里的程序不是 Windows 进程，始终读作空闲。

## 验证

- `desktop/internal/localshell/shell_unix_test.go` 的 `TestShellIsBusyWhileAForegroundCommandRuns`（提示符空闲、`sleep` 忙、Ctrl+C 后空闲、结束后不忙）与 `desktop/internal/localshell/shell_windows_test.go` 的对应用例。
- `desktop/internal/workbench/process_exit_test.go` 用 Core 规则验证关闭忙碌标签页先问、取消保留、确认关闭，空闲终端直接关闭，以及关闭项目时只列出忙碌终端。
- `desktop/internal/core/plugin_session_test.go` 覆盖插件会话的启动与停止路径。
- `desktop/internal/processledger/processledger_unix_test.go` 覆盖账本的身份匹配与只结束自己记录的进程。
- `desktop/internal/processledger/processledger_windows_test.go` 在 PATH 最前面放记录调用的 `ps.bat`、`kill.bat`，覆盖 Windows 上登记创建时间和路径、取消登记、启动清扫立即结束残留、保留时只删记录、创建时间不符（PID 被复用）时不结束、已退出但句柄未关的进程不算残留，并断言账本从未调用这两个程序。
- `desktop/internal/localshell/shell_windows_test.go` 的 `TestConPTYShellIsRecordedWhileItRuns` 覆盖 ConPTY 终端的 shell 运行期间在账本中、退出后记录被删除。
- Core 的 `rust/fixtures/process-lifecycle/`（[链接](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/fixtures/process-lifecycle/)）：运行服务在退出、关闭项目、直接停止设置和崩溃恢复下的动作。
- 实际应用（2026-10-14，macOS）：运行 Spring Boot 配置，Java 进程监听 8080 后从菜单退出 Lithe，1 秒内 Lithe、语言服务器和 Spring Boot 进程全部消失，端口释放。

## 适用范围

- `desktop/internal/core/plugin_session.go`
- `desktop/internal/core/plugin_session_test.go`
- `desktop/internal/workbench/process_exit.go`
- `desktop/internal/processledger/processledger.go`
- `desktop/internal/processledger/processledger_unix.go`
- `desktop/internal/processledger/processledger_windows.go`
- `desktop/internal/localshell/backend_windows.go`
- `desktop/internal/buildprocess/process_windows.go`
- `shared/platform-feature-matrix/features/run-processes-end-with-ide.json`
- Core 仓库的进程生命周期规则与进程树（Job Object）实现，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
