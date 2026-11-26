# Agent 笔记：本地 bash/zsh 经 sh 小脚本启用 Shell 集成

状态：已实现

## 先说结论

本地终端里的默认 bash、zsh（以及 WSL 发行版里的 bash、zsh）现在都经一段 `/bin/sh` 小脚本（下称“垫片”，shim）启动。垫片先让 Shell 正常读完用户自己的启动文件，再挂上提示符钩子。Shell 因此会上报提示符、命令开始与结束和退出码，每条上报都带一个每次启动新生成的令牌（token）。终端只认这个令牌，并用这些上报做两件用户看得到的事：在提示符处调整大小时只留下一份提示符；单击正在输入的命令行时，把光标移到点击处。日常开发要注意三点：一是本地垫片写完启动文件后用 `exec` 变成用户 Shell，存放启动文件的临时目录由 Lithe 创建、在 Shell 结束后由 Lithe 删除，不要改回“sh 等待 Shell”；二是令牌只发给“用户自己的 Shell、没带参数”的启动；三是 cmd 没有“命令开始”标记，这两项功能对它不生效；PowerShell 经 PSReadLine 上报命令开始（#2008）。

## 问题

#1984 留下了一条没接通的链路：`localshell.Config.DirectoryToken`（现名 `PromptToken`）、`term.Terminal.SetPromptToken`、Windows 的 PowerShell/cmd 提示符脚本都有代码和测试，但生产代码没有任何调用方。

Motty 的两项终端改进依赖这条链路：

- **203857c9：调整大小只保留一份提示符。** Shell 的行编辑器（line editor，负责画提示符和正在输入的命令的那部分）收到窗口尺寸变化（SIGWINCH）后，会从它上次画的位置重画提示符。如果终端同时把提示符那几行按新宽度重新折行，重画就落在错位的文字旁边，留下重复或被截断的提示符。拖动窗口或分隔条时宽度变化比 Shell 重画快，问题更明显。
- **b2357d69：点击命令行移动光标。** 终端不能直接放置别的程序的光标，只能发送方向键。只有确定“现在读按键的是 Shell 的行编辑器、不是它运行的程序”时，这样做才安全。

两项都需要终端知道“提示符从哪里开始、输入从哪里开始、命令什么时候开始运行”，也就是 OSC 133（提示符/命令标记）。Motty 只在 SSH 会话里注入这些钩子（`internal/sshconn/integration.go`），本地 Shell 没有。

## 决策

### 谁拿到令牌

`termview.View.start` 只在 `args == nil` 时生成令牌（`crypto/rand` 的 `rand.Text()`，只含 A–Z 和 2–7，满足集成脚本对令牌字符的要求），然后同时交给屏幕（`SetPromptToken`）和 `localshell.Config.PromptToken`。`args` 先经过 `localshell.ArgsFor`：Windows 的 Git Bash 会得到 `--login -i`，所以拿不到令牌。插件终端总是传非 nil 的参数，也拿不到。每次重启 Shell 都换新令牌；屏幕换令牌时清掉旧 Shell 留下的提示符位置和命令标记，所以重启前旧 Shell 写了一半的序列不会被当成新 Shell 的提示符。

正确做法：新增一种“启动用户自己的 Shell”的入口时，保持 `Args` 为 nil，让 termview 决定是否集成。
不要这样做：给命令行工具或插件进程手动塞一个令牌。它打印的同样序列会被当成 Shell 的提示符，点击就会把方向键发给这个程序。

### 垫片怎么启动 Shell

Unix 后端（`localshell/backend_unix.go`）在 `args == nil`、令牌有效、Shell 是能识别的 bash/zsh 绝对路径时，先在 Shell 环境的 `TMPDIR`（没有时用 `/tmp`）下用 `os.MkdirTemp` 建一个只有本人可读的私有目录，再启动 `/bin/sh -c <脚本> sh <shell> "" <目录>`。脚本把启动文件写进这个目录（写入时 `umask 077`），然后 `exec` 用户 Shell。Shell 读完启动文件就删除目录（zsh 在 `.zlogin` 末尾，bash 在 rcfile 末尾）。建目录失败，或任一条件不满足时，Shell 照原样以 `-l` 启动，不集成也不报错。

脚本内容是 Motty 的 `integration.go`（0ae3ba59），去掉了 Lithe 不读的输出编码、主目录和当前目录（OSC 7）上报，保留 `;motty=` 后缀和 `MOTTY_*` 变量名，方便以后同步时直接对比差异。本地启动与 Motty 的差别只在开头和结尾：目录由调用方给出（`$3`），不用 `mktemp` 和 `trap`；最后一行用 `exec` 变成 Shell，不等待它（`startScript` 的 `owned` 参数）。

bash 部分另有两处与 Motty 不同，同步时不要改回：

- PS0 用提示符转义写命令开始标记（`PS0='\e]133;C…\a'${PS0-}`），不用 `$'…'`。`$'…'` 在赋值语句的文本里就展开成 ESC 和 BEL，用户的 DEBUG trap 回显 `BASH_COMMAND` 时会把一个带本会话令牌的 C 标记原样打到终端，终端把它当成一次命令开始。PS0 显示时和 PS1 一样解码 `\e`、`\a`。
- DEBUG trap 路径（Bash 4.4 之前没有 PS0）遇到数组形式的 `PROMPT_COMMAND`，同样在首尾加入 `__motty_disarm` 和 `__motty_arm`，和 PS0 路径对数组的处理一致。原来遇到数组就整段跳过，一次命令开始都不报。systemd 257 起的 `/etc/profile.d/80-systemd-osc-context.sh`（Ubuntu 26.04 默认带）会把 `PROMPT_COMMAND` 改成数组，并在 PS0 前放命令替换；集成先读 `/etc/profile`，所以用户和 CI 都会遇到。Bash 5.1 之前只执行数组的第 0 项，这种组合下仍不上报，和原来一样。
- 回归测试：`TestIntegratedBashReportsEachCommandLineOnce`、`TestIntegratedBashDebugTrapReportsEachCommandLineOnce` 的 `array prompt command` 用例在测试自己的 `.bash_profile` 里照 systemd 的写法设置，不依赖宿主的 `/etc/profile`。

### 临时目录归 Lithe 所有，sh 变成 Shell

- Lithe 在 `wait` 里、`cmd.Wait()` 返回后删除目录（`removeRuntime`），启动失败时也删除。无论 Shell 怎么结束，包括启动文件还没跑完就被关闭、忽略挂断后被强制结束，目录都不会留下。`Done()` 关闭前目录已经删除。
- 因为 `sh` 用 `exec` 变成了用户 Shell，终端启动的进程就是用户 Shell，进程层级和不集成时一样：关闭确认的忙碌判断（前台进程组是不是 Shell 自己）、挂断（只给 Shell 发 SIGHUP，由 Shell 转给它的任务）、0.5 秒后的强制结束、退出码和进程台账（`processledger`）都不需要为集成另写逻辑。
- 不写应用包、安装目录或工作区，所以不影响代码签名和 Sparkle 增量更新基线（见仓库根 `AGENTS.md`“已发布程序包的运行时只读边界”）。如果 Lithe 自己崩溃，最多在 `TMPDIR` 留下一个本人可读的小目录，由系统的临时目录清理回收。

WSL 发行版里的 Shell 由 `wsl.exe` 启动，Windows 一侧删不到发行版里的目录，所以 `wslIntegrationScript` 保留 Motty 的做法：`sh` 用 `mktemp` 建目录，等待 Shell，退出、收到 HUP 或 TERM 时删除。

### 只上报有消费方的内容（#1984）

集成脚本和 `term` 只保留 OSC 133 A/B/C/D：屏幕用它们判断提示符位置、调整大小、点击移动光标，以及在命令结束后收回被杀程序留下的输入模式（`ReclaimApplicationModes`）。#1984 删除了没有消费方的部分：`term` 的 `SetCwdChange`、`SetCwdReport`、`SetPromptReady`、`SetPromptStart`、`SetCommandStart`、`SetCommandFinished`、`SetInputEnvironment` 回调和 `Cwd`/`WorkingDirectory`，OSC 7 与 OSC 9;9 的目录解析，以及脚本里的目录上报（Unix 的 OSC 7，WSL、PowerShell、cmd 的 OSC 9;9）。`localshell.Config.DirectoryToken` 改名为 `PromptToken`，因为它现在只用于提示符标记。OSC 9;9 仍不会被当成通知（`osc9` 对数字开头的参数直接返回，`TestOSC9IsAMessageButConEmuCommandsAreNot`）。WSL 的起始目录（`MOTTY_WSL_CD`）不是上报，照常保留。

正确做法：要显示 Shell 当前目录（例如新终端继承目录、标签标题）时，先设计界面消费方，再从 Motty 的 `integration.go` 把 OSC 7 上报同步回来，并在同一次改动里加解析和测试。
不要这样做：只为“以后可能用到”保留解析和回调。没有调用方的代码照样要维护，还会让人误以为功能已经接通。

### 只认“命令开始”之后的提示符

屏幕只有在 Shell 至少上报过一次命令开始（OSC 133 C）之后，才把 OSC 133 A 当成提示符开始（`commandMarks`）。`AtPrompt()` 等于“提示符有效且不在备用屏”，`CommandReporting()` 就是 `commandMarks`。原因是：cmd 只上报 A 和 B，不上报 C，终端无从知道它什么时候开始运行程序。如果对它也启用这两项功能，运行中的程序会收到本该给行编辑器的方向键，或者在全屏程序运行时延迟告诉它尺寸。没有 PSReadLine 的 PowerShell 同样只有 A 和 B。

这和 Motty 一致，代价是 bash/zsh 刚打开、还没执行过任何命令时，第一个提示符上点击不会移动光标，调整大小也和以前一样立即发送。

### PowerShell 在 PSReadLine 交回命令行时上报命令开始（#2008）

PowerShell 主机经 `PSConsoleHostReadLine` 向 PSReadLine 要下一行输入，用户确认后函数返回，主机随即运行这一行。集成脚本在 PSReadLine 已加载（`Function:\PSConsoleHostReadLine` 存在）时包住这个函数：调原函数拿到行，用 `[Console]::Write` 写出带令牌的 OSC 133 C，再原样返回这一行。做法与 VS Code 的 PowerShell 集成相同。PSReadLine 开头读 `$?` 给错误提示符上色，所以包装函数沿用提示符包装的写法，先按 `$global:?` 重建失败状态再调原函数（`TestPowerShellReadLineIntegrationMarksTheCommandStart`）。历史记录、按键绑定和用户自定义的 `prompt` 都在 PSReadLine 和原提示符函数里，不受影响。

cmd 读完一行就直接运行，没有可挂钩的时机（`PROMPT` 只在画提示符时展开），所以 cmd 保持只上报 A 和 B。

正确做法：只在 `PSConsoleHostReadLine` 返回之后、返回行之前上报 C。
不要这样做：绑定 Enter 键（`Set-PSReadLineKeyHandler`）上报 C，那会覆盖用户自己的 Enter 绑定；或者用 `AddToHistoryHandler` 上报，用户常自定义它，而且不进历史的行也会运行。

### 调整大小：屏幕跟随每一步，Shell 只收到停下来的尺寸

- 屏幕（`term/resize.go`）在提示符有效时，只重新折行提示符之前的内容，提示符那几行保持原样并另存一份；Shell 重画开始写入时（`clearStalePrompt`）再清掉旧行。
- termview（`session.go` 的 `resizeShell`/`settleShellResize`）在 Shell 停在提示符时，先不告诉它新尺寸，而是等尺寸在画布时钟上保持 100 毫秒（`shellResizeDelay`）再发一次；回到 Shell 已知的尺寸就不发。其余情况（命令运行中、全屏程序、没有标记的 Shell）立即发送。
- 画布没有时钟（`canvas.HasClock()` 为 false）时时间不会流逝，因此永远不等待，直接发送。

与 Motty 的差异：Motty 在鼠标按下期间也一直不发送尺寸。termview 看不到窗口和外层分隔条的拖动事件，所以只按“尺寸保持多久”判断。

### 点击移动光标

`termview/input_click.go`：主键单击（不带修饰键，或只带 Option/Alt），松开时没有形成拖选，Shell 正在运行、已上报过命令开始、不在备用屏，才计算位移。计算前先 `Pump()` 一次，把还没解析的输出（例如上一次方向键的回显）算进去，再按程序要求的光标键编码（普通或应用光标键模式）重复发送左右方向键。位移由 `term.Terminal.InputMove` 计算，宽字符和软换行按显示位置处理。点在提示符上、输入行以外时不发送。与 Motty 的差异：没有设置开关，始终启用。

## 考虑过的备选方案

### 沿用 Motty 的做法：sh 用 mktemp 建目录并等待 Shell

脚本可以和 Motty 完全一致。没有采用：`sh` 成了终端启动的进程，用户 Shell 是它的子进程，带来三个问题。一是关闭终端时的强制结束只杀掉 `sh`，`sh` 的清理来不及运行；用户 Shell 的启动文件超过 0.5 秒（本机常见的 zsh 配置约 0.6 秒）时，刚打开就关闭的终端会留下临时目录，Shell 还会多活一阵。工作台测试实际复现过这种残留。二是 `sh` 在等待前台子进程时会把挂断推迟到子进程结束，需要额外给前台进程组发挂断。三是忙碌判断要越过 `sh`，必须读进程的父进程（macOS 用 sysctl、Linux 读 `/proc`），读不到时只能放弃集成；关闭时的退出码也会变成 129。Motty 在 SSH 远端没有别人能清理目录，所以需要等待；本地由 Lithe 清理，就不需要。

### 直接改用户的 `.zshrc`、`.bashrc`，或用 `ZDOTDIR`/`--rcfile` 指向 Lithe 的文件

不用 `sh` 这一层。没有采用：改用户文件会留下痕迹，还可能和用户自己的配置冲突；只用 `--rcfile` 会让 bash 不再按登录 Shell 读 `.bash_profile`，和用户平时的启动结果不一致。垫片先按用户平时的方式读完启动文件，再追加钩子（`TestIntegratedBashStartupMatchesALoginShell`、`TestIntegratedZshHistorySurvivesSessions` 核对）。

### 不等命令开始标记，对 PowerShell/cmd 也启用

可以让 Windows 默认 Shell 不依赖集成脚本就有这两项功能。没有采用：没有 C 标记就无法知道什么时候轮到程序读按键，误把方向键发给程序比功能缺失更糟。PowerShell 已由 #2008 经 PSReadLine 上报 C；cmd 没有可挂钩的时机，保持不启用。

### 保留目录上报，等以后接界面

删掉的代码以后可能要加回来。没有采用：没有调用方的回调和解析一直没人验证，也会让人误以为功能已经接通；需要时从 Motty 同步，成本很低。

### 给点击移动加设置开关

Motty 有开关。没有采用：只在命令行输入区、单击且未拖动时生效，不影响选择和链接，暂不需要让用户关闭。

## 后果

- 收益：本地 bash/zsh、WSL 和带 PSReadLine 的 PowerShell 里，提示符处调整大小不再留下重复提示符；单击命令行可以移动光标。Windows PowerShell/cmd 的提示符上报首次真正启用。
- 代价：每次启动本地 bash/zsh 多运行一次 `sh`（随即变成 Shell，不常驻）；`TMPDIR` 下会短暂出现一个私有目录；第一个提示符上点击不生效。
- 关闭集成终端时等 Shell 回到提示符再挂断（#2005、[#2054](https://github.com/1lck/Lithe-IDEA/issues/2054)）。Bash 运行 `PROMPT_COMMAND` 时可能无法把挂断转给后台任务。提示符钩子也能启动前台程序，所以前台进程组无法区分正在运行的用户命令和提示符钩子。显示过提示符的 Shell 如还未打出下一个 B 标记，就继续读取并丢弃输出，最多等原有的 1 秒宽限再发送 SIGHUP。未经集成或还没有提示符的 Shell 立即挂断。
- 伪终端主端（PTY master）留到 Shell 退出并完成有界输出排空。Unix 上关闭主端会让 Shell 的读端看到 EOF 或 EIO，与 Bash 处理 SIGHUP 的顺序产生竞争。保留主端使 Bash 有机会把信号转给自己的任务。Linux 并发复现显示，Bash 打出 B 标记后仍可能错过 SIGHUP；即使在输入循环附近补发，信号、Readline 清场和 Shell 退出仍是时序竞争。集成 Bash 因此在提示符处改用受控关闭：后端用终端属性确认 Readline 已把终端切到非 canonical、无回显的输入模式，先发送一次终端中断，放弃包括多行续行在内的未完成输入；看到这次中断产生的新主提示符后，再写入两组很不可能由用户输入的键序列。第一组经 `bind -x` 同步运行集成启动文件里的 `__motty_close`，它按 `jobs -p` 给仍登记的任务进程组发 HUP 和 CONT，并把 Readline 当前行换成 `builtin exit 0`；第二组触发 `accept-line`，让 Bash 以成功状态正常退出。键序列不是命令文本，不会和用户留下的一半输入拼接；未输完的多行命令也不会被当成命令执行。受控关闭后 100 毫秒仍补一次普通 SIGHUP，覆盖老 Bash 没有 `bind -x`、用户覆盖按键绑定等情况；最终仍由强制结束兜底。
- 不要这样做：给会话里所有进程组都发挂断。用户完全 `disown` 掉的任务会被一起结束；`__motty_close` 只处理 `jobs -p` 仍列出的任务，完全移出任务表的任务得以保留。其他终端（如 Ghostty）也只挂断 Shell 自己的进程组。也不要把 `exit` 当普通输入直接写入终端：它会接到用户未完成的命令后面，多行输入还可能被拼接执行。
- 仍然存在的限制：Bash 不把 `disown -h` 的内部标记暴露给 `jobs`，而这些任务仍列在 `jobs -p` 中；受控关闭无法把它们和普通任务区分开，会一并结束。要完整保留这个语义，必须让 Bash 自己走原生 SIGHUP 转发路径，但已验证该路径在关闭时序中不可靠。没有集成、但用户自己配了 `PROMPT_COMMAND` 的 bash 不变。zsh 只有在后台任务刚 fork、还没 exec 的约 1 毫秒里被挂断时才会留下任务，这个窗口没有标记可以等，不处理。一直不回提示符的 Shell（例如在 `PROMPT_COMMAND` 里死循环）在 1 秒后照常挂断。
- 没有消费方的回调和目录上报已由 #1984 删除，见“只上报有消费方的内容”。
- Windows：PowerShell 的 `-NoExit -EncodedCommand` 启动和 cmd 的 `PROMPT` 环境变量由 termview 首次启用，实机运行验收还没做，见 #2008。
- 重新评估的触发条件：cmd 有了能上报命令开始的方式；termview 能拿到外层拖动的按下/松开事件；或者用户反馈需要关闭点击移动。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/localshell/... ./internal/term/... ./internal/termview/... -count=1`：真实 bash/zsh 经垫片启动并上报提示符和命令，第一个提示符出现时启动目录已删除；挂断能结束 Shell 和后台任务；命令刚结束、bash 还在运行 `PROMPT_COMMAND`（包括慢的 `PROMPT_COMMAND`）时关闭，后台任务也会结束（`TestClosingAnIntegratedShellRightAfterACommandHangsUpItsJobs`，关掉推迟后 bash 的三个用例都会失败）；一直不回提示符的 Shell 在宽限期后结束（`TestClosingAnIntegratedShellThatNeverPromptsStillEndsIt`）；标记识别跨分片、只认本会话令牌（`TestPromptMarks*`、`TestPromptMarksAcrossEverySplit`）；命令结束只在退出码有效时收回输入模式（`TestACommandEndReclaimsOnlyWithAValidStatus`）；WSL 脚本在起始目录启动登录 Shell（`TestWSLScriptStartsTheLoginShellInTheStartFolder`）；启动文件还在运行时关闭，Shell 被结束、目录被删除（`TestClosingAShellDuringItsStartupRemovesItsPrivateDirectory`）；令牌每次启动更换；提示符处尺寸保持后只发一次；点击按条件发送方向键。
- `TestCloseLetsTheShellHandleHangupBeforeReleasingThePTY` 用可控后端验证关闭顺序。即使提示符钩子占用前台进程组，也先等 B 标记，发出挂断后再等 Shell 退出，最后关闭主端。`TestClosingAnIntegratedBashHangsUpTheWholeJob` 覆盖管道任务的整个进程组；`TestClosingAnIntegratedBashHangsUpAStoppedJob` 覆盖停止任务会被 CONT 后继续处理 HUP；`TestClosingAnIntegratedBashWithUnfinishedInputHangsUpItsJobs` 覆盖未输完的多行命令；`TestClosingAnIntegratedViBashHangsUpItsJobs` 覆盖 vi 插入和命令键位映射；`TestClosingAnIntegratedBashLeavesDisownedJobs` 覆盖完全 `disown` 的任务不被结束；`TestHangupWaitsForTheBashInputModeBeforeForcingExit` 覆盖输入模式、受控关闭、普通挂断补发和强制结束的顺序。高负载下重复运行 `TestClosingAnIntegratedShellHangsUpTheShellAndItsJobs` 和 `TestClosingAnIntegratedShellRightAfterACommandHangsUpItsJobs`，确认不再有后台任务残留。
- 运行 `./internal/workbench/` 测试前后统计 `TMPDIR` 下的 `motty-shell.*` 目录，数量不变。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认运行时没有写入发行目录。
- 在 Windows 上运行 `TestWindowsShellsMarkTheirPromptsUnderTheToken`（PowerShell 在下一个提示符前标记命令开始、屏幕开启两项功能，cmd 不标记）、`TestPowerShellReadLineIntegrationMarksTheCommandStart`、`TestPowerShellPromptIntegrationPreservesCustomPromptAndExitStatus`，它们只在 Windows 编译。

## 适用范围

- `desktop/internal/localshell/integration_scripts.go`
- `desktop/internal/localshell/backend_unix.go`
- `desktop/internal/localshell/shell.go`
- `desktop/internal/localshell/input_mode_linux.go`
- `desktop/internal/localshell/input_mode_darwin.go`
- `desktop/internal/localshell/input_mode_other.go`
- `desktop/internal/localshell/prompt_marks.go`
- `desktop/internal/localshell/wsl.go`
- `desktop/internal/localshell/integration_windows.go`
- `desktop/internal/term/terminal.go`
- `desktop/internal/term/parser.go`
- `desktop/internal/term/resize.go`
- `desktop/internal/termview/session.go`
- `desktop/internal/termview/input_click.go`
