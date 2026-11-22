# Agent 笔记：远程工作区在主机上运行内置的程序和脚本运行配置及其执行前步骤

状态：已实现

## 先说结论

本笔记覆盖 #2231 R1 的 #43a、#43b 和 #43c。远程工作区里，运行配置的读写、校验和启动计划由 Core 路由到主机（Core #161）：配置文件经 `lithe_workspace::fs` 存在主机的项目目录，计划按主机平台（Linux、macOS）生成，从不生成批处理或 PowerShell。桌面端拿到计划后，用 `remote.runProcess` 在主机上启动内置的程序和脚本运行（`process.*`），输出进 Run 窗口，标签页带“主机”徽标。

配置“执行前”列表里引用的其他内置运行配置（#43b）同样在主机上按顺序运行，输出进同一个控制台。运行中连接断开时（#43c），主机保留会话就不结束运行：Run 窗口等窗口重新连接，接上同一个主机会话后经 `remote.attachProcess`（Core #167）从丢失的位置接着接收输出；关闭时保留在主机上的进程，下次连接可在 Run 窗口里接回。插件提供的执行前任务、构建工具、插件提供的运行和调试要由本机插件后端计划主机上的进程，属于 #2231 的 R3/R4，本阶段不做，各自说明原因（`desktop.run.remote.*`）。

## 问题

- 远程工作区的项目只在主机上，本机的占位目录永远是空的。照本机方式起进程，会在空目录里跑，读不到项目文件。
- 运行配置本身存在项目目录里。不路由到主机，就会在占位目录里读到“没有配置”，写入时还会把文件写进占位目录。
- 主机上的程序输出可能很快、很多。Core 只缓存 1024 个未送出的事件，观察回调一旦阻塞，Core 会丢事件甚至结束请求。
- 程序输出里的路径是主机路径，本机打不开；工作区以外的主机文件也要能点开（与 Zed 一致）。

## 决策

### 只有内置运行在主机上启动

`startRunConfigurationWith` 在远程工作区只放行 `configuration.IsProcess()` 且不是调试的启动，其余以 `desktop.run.remote.unsupported` 拒绝。标题栏的“运行”放行选中的配置，“调试”和“当前文件”仍走 `refuseRemote`；选中的配置不是内置运行时，直接说明不支持，而不是报“构建目标缺失”。

`loadBuildSystems` 在远程工作区不探测构建系统：本机占位目录里没有项目，探测只会得到空结果。它把 `p.build.failed` 设成 `desktop.run.remote.buildTools`，运行配置菜单把这句话显示为不可点的说明；非空的 `failed` 也让生成层快照保持为空，所以不会往主机写生成层。

“执行前”列表里有插件任务的配置拒绝启动（`desktop.run.remote.beforeLaunch`）：任务由插件后端在本机计划，读不到主机上的项目文件（#2231 §2，R3）。只引用内置运行配置的列表照常运行，见下文。需要通过工具链选择程序的计划（`executable.toolchain`）也拒绝（`desktop.run.remote.toolchain`），因为工具链解析读的是本机。

### 进程的启动、输出和结束

`desktop/internal/workbench/remote_run.go` 的 `launchRemoteProcessRun`：

1. 用 `remote.hostRequest` 的 `tempDirectory` 在主机临时目录建 `lithe-run-script-*`，把它作为脚本基名交给 `runConfig.createLaunchPlan`。脚本按计划写到这个目录（写入用“文件必须不存在”的预期版本），运行结束后不论成败、是否被停止都递归删除。连接断开或主机崩溃时留下的目录，由主机的临时目录清理负责。
2. 工作目录是项目相对的 `/` 路径，`remoteRunDirectory` 拼到主机根下，拒绝 `..` 和绝对路径。环境用主机的登录环境，叠加计划的 `environment` 和配置的 `env`。
3. 输出经 `remoteRunOutput` 交给控制台：观察回调只追加到缓冲区，从不等待；独立的泵按顺序送出。缓冲区上限 8 MiB，超出时丢弃最旧的未送出部分，并在控制台写一行提示（`desktop.run.remote.outputDropped`）。
4. “停止”先用 `process.kill`（force 为 false）给进程组发 SIGTERM，超过停止等待时间（`buildprocess.StopGrace`）仍未结束就取消请求，由 Core 强制结束。再按一次“停止”立即强制结束。
5. 进程以非零退出码结束时运行失败，被信号结束时说明信号编号；连接断开时交给窗口重新连接：主机保留会话时运行继续，见下文“断线后接回（#43c）”；主机不保留会话，或断线时主机还没给出进程 id 时，说明“无法确定是否仍在主机上运行”。

主机上的进程 id 不是本机的，`Pid()` 返回 0，所以 Run 窗口不采样它的端口、CPU 和内存。主机端口由端口工具窗口列出。

### 执行前步骤（#43b）

Core 只允许“执行前”列表引用内置进程运行（`process.*`），所以配置步骤在远程工作区一定能在主机上运行。`runBeforeLaunchSteps` 在远程工作区为这次启动建一个 `remoteRunHost`，每个配置步骤经 `remoteRunHost.runStep` 运行：与主运行一样在主机临时目录规划并写脚本、用 `remote.runProcess` 启动、输出经 `remoteRunOutput` 进同一个控制台，进程标签为步骤名；临时目录在下一步开始前删除。

步骤与本机步骤一样受准备时间（`runPreparationTimeout`）限制。请求本身不随准备上下文取消：准备上下文结束（“停止”或超时）时，先对已启动的进程调用 `remoteProcess.Stop`（SIGTERM，超过停止等待时间再取消请求），还没启动时直接取消请求。这样主机步骤的停止与本机 `buildprocess` 的先请求、后强杀一致。被要求结束后以 0 退出的步骤仍按停止或超时处理，不会接着启动配置。

`failBeforeLaunch` 按 `ExitCode() int` 读退出码，本机的 `*exec.ExitError` 和主机的 `remoteRunExit` 都能说明“以退出码 N 结束”。确认询问（按指纹记住）与本机共用，主机步骤不另加询问。

### 断线后接回（#43c）

Core #167 在连接断开后把会话里进程的事件停放在主机上，带 `resume` 的重新连接接回同一个会话（`resumed=true`）后，`remote.attachProcess` 从这次连接还没收到的第一个事件开始转发：先发 `process.attached`（`truncated` 表示停放的事件超过上限、丢了一部分），再发之后的输出和退出。错误码一一对应：`connection_closed`（连接断开）、`remote_process_gone`（主机上没有这个进程了）、`remote_process_attached`（另一个连接正在接收它）。

`remoteRunHost.follow` 负责一次运行跨断线的接收：

1. 请求因连接断开结束、主机已给出进程 id、会话有主机会话键（主机保留会话）时，不结束运行：控制台另起一行写 `desktop.run.remote.waiting`，经 `remoteRunRejoin` 把等待交给窗口线程，等工作区的下一个会话。窗口线程在 `rejoinRemoteRuns` 里把新会话交给所有等待者；等待用带缓冲的通道，窗口线程不等运行。
2. 新会话的主机会话键相同时，`remoteProcess.move` 把停止、强制结束改走新会话，再用 `remote.attachProcess` 接收；`process.attached` 到达时先写 `desktop.run.remote.resumed`，`truncated` 时再写 `desktop.run.remote.outputLost`，然后才是之后的输出。可以断线多次，每次重复这一步。
3. 新会话的主机会话键不同（主机开了新会话），说明 `desktop.run.remote.sessionEnded` 结束运行：旧会话的进程已无法接收。工作区关闭时等待被关闭，运行按 `connectionLost` 结束，主机上的程序由关闭确认决定结束还是保留。接回被拒时分别说明 `processGone` 和 `attachedElsewhere`。
4. 等待期间用户按“停止”或项目关闭时，主机还不知道这次停止：`remoteRunAbandon` 把（主机会话键，进程 id）交给窗口，`endAbandonedRuns` 在接上同一个主机会话后立即强制结束这些进程；主机会话已变时直接忘掉，因为进程随旧会话结束。

控制台里窗口自己的说明用暗色另起一行（`remoteRunNotice`、`remoteRunLine`），不和进程没换行的输出接在一起。

### 保留进程的接回（#43c，设计 §9.2、S35）

关闭确认保留在主机上的进程，下次连接接回会话后列出（见关闭确认的笔记）。列表里有进程时，对话框除“结束这些进程”“继续运行”外还有“在运行窗口中接回”；列表里同时有终端时说明终端无法接回（终端没有可回放的输出）。选它时 `attachKeptPrograms` 为每个进程建一个运行，键为 `remote-attach:<进程 id>`（已有同键运行就跳过，所以重复选择不会开两个标签页），用 `launchRemoteAttachRun` 在 Run 窗口里接收，最后打开 Run 窗口。标签页带“主机”徽标，控制台先写 `desktop.run.remote.attachedKept`；“停止”与普通运行一样先发 SIGTERM。之后的断线同样按上一节接回。

### 输出里的路径

`flushOutputLinks` 在远程工作区用主机根作为工作区根、按 `linux` 平台匹配路径。点击时用 `remote.stat` 找第一个主机上存在的文件，经 `remoteplaceholder.LocalPath` 换成占位路径交给编辑器打开；工作区以外的路径落在占位根旁的 `.lithe-remote-host` 下，与“工作区以外的远端文件按 Zed 方式打开”一致。需要插件解析的链接拒绝，因为插件读的是本机文件。接回的进程（#43c）用同一个控制台，输出里的主机路径同样可点击。

设计 §7.3 还要求测试报告和构建诊断里的主机路径映射成工作区文件。这两者都由插件提供的构建系统产生：测试结果经 `DecodeBuildTestResults` 按插件的清单和构建系统解码，构建诊断来自构建工具的输出。远程工作区在 R3 之前不探测构建系统，不运行插件任务，所以 R1 里没有测试报告和构建诊断。它们的路径映射随 R3 插件按主机路径计划进程一起做，由 Core 在报告解码时完成，桌面端不另写一份。

### 日志

日志只记命令和错误码，不记主机、路径、命令行或输出。早返回带 `// log-exempt:` 说明。

## 考虑过的备选方案

- **在本机用 ssh 直接起进程**：绕过 Core 的会话、认证和 S26 环境白名单，也拿不到 Core 的进程组管理和事件缓冲。
- **把脚本写到主机的项目目录**：会弄脏用户的工作区，可能被 Git 看到或被提交。
- **远程工作区也探测构建系统**：探测在本机占位目录里运行，结果永远为空，还会误导用户以为项目没有构建工具。
- **远程工作区拒绝所有执行前步骤**（#43a 的做法）：配置步骤只是另一个内置运行，主机已经能运行它；一起拒绝会让常见的“先编译再运行”脚本链用不了。
- **把主机步骤的请求直接挂在准备上下文上**：停止时 Core 立即强杀，主机程序没有机会清理，与本机步骤的停止行为不一致。
- **断线时结束运行，让用户重新运行**：主机上的程序还在跑，重新运行会起第二份进程，端口和文件可能冲突；设计 §9.3 要求从上次的位置接着输出。
- **断线等待期间的“停止”只在本机结束运行**：主机上的进程会一直留在会话里，只能在下次关闭时才被发现；所以接上同一个主机会话后立即强制结束。
- **接回保留进程时自动打开所有标签页**：用户可能只想结束或让它们继续运行，接回由用户在对话框里选择。

## 后果

- 远程工作区里能直接运行项目自带的程序和脚本配置，输出、停止和退出码与本机一致；Run 窗口的“主机”徽标说明它在哪里运行。
- “执行前”列表里的内置运行配置在主机上按顺序运行，失败、停止和超时与本机一致。
- 插件提供的执行前任务、构建工具、插件运行、调试和“当前文件”暂时不可用，各自给出说明；它们依赖 #2231 的 R3（插件按主机路径计划进程）和 R4（远程调试），本阶段不做。
- 主机保留会话时，断线不结束运行；重新连接到同一个主机会话后接着输出，丢了部分输出时明确说明。主机开了新会话时，旧会话里的进程无法接收，运行结束并说明原因。
- 关闭时保留的进程可以在下次连接时接回 Run 窗口，终端不能接回。
- 主机临时目录里可能残留断线或崩溃时没删掉的 `lithe-run-script-*` 目录，由主机的临时目录清理回收。

## 验证

- `desktop/internal/workbench/remote_run_test.go`：主机上的启动参数、工作目录、环境、脚本写入和删除；退出码和信号；“停止”先发 SIGTERM；执行前的配置步骤在主机上依次运行、失败时不启动配置、停止时先发 SIGTERM；插件任务步骤、工具链和调试的拒绝；输出缓冲丢弃最旧部分；输出链接的主机文件查找；不记主机和路径；断线后等待、接上同一个主机会话后接着输出并说明丢失（`TestRemoteWorkspaceRunFollowsItsProcessAcrossAReconnection`）；新会话、进程已不在、被别处接收时结束（`TestRemoteWorkspaceRunEndsWhenItsProcessCannotBeReceivedAgain`）；等待期间停止的运行在重连后强制结束主机进程（`TestRemoteWorkspaceRunStoppedWhileDisconnectedEndsOnceReconnected`）。
- `desktop/internal/workbench/remote_close_test.go`：“在运行窗口中接回”为每个保留的进程开 Run 标签页并打开 Run 窗口。
- `TestVisualRemoteRun`、`TestVisualRemoteClose`：断线等待、重连后接着输出、接回保留进程的无头截图（`docs/assets/remote-run/`、`docs/assets/remote-close/`）。
- `desktop/internal/core/remote_process_test.go`：`remote.runProcess`、`remote.attachProcess` 事件的解析。
- `desktop/internal/core/remote_acceptance_test.go`：对真实主机的验收，只在环境变量指定主机时运行，CI 跳过（变量见文件开头，经 `scripts/desktop/desktop-go.sh` 运行以读取暂存的服务端）。它杀掉 OpenSSH 或 wsl.exe 子进程模拟断线，检查运行以 `connection_closed` 结束、带 `resume` 的重连接回同一个主机会话、`remote.attachProcess` 先收到断线期间的输出再收到之后的输出并以 0 退出；再用“保留”关闭会话，重连后进程列在 `keptPrograms` 里并同样接回。WSL 里未安装的发行版是 `unreachable`，不存在的用户是 `failed`，两者的 `diagnostics` 都带 wsl.exe 的消息和错误码（`WSL_E_DISTRO_NOT_FOUND`、`WSL_E_USER_NOT_FOUND`）。2026-11-22 在 macOS（OrbStack 的 Alpine aarch64 机器，经 OpenSSH）和 Windows（WSL Ubuntu x86_64）上通过。
- Windows 验收发现 wsl.exe 把失败消息写在标准输出而不是标准错误（不设 `WSL_UTF8` 时是不带 BOM 的 UTF-16LE），中文消息又以汉字开头、第二个字节不是 NUL，Core 原来只读标准错误，未安装的发行版因此报成 `failed`、诊断只有退出码。Core [#169](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/169) 让探测在流结束时保留读到的标准输出，并按“标准输出在前、标准错误在后”解码诊断；桌面端固定到它之后才通过。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：运行时不写发行目录。

## 适用范围

适用于远程工作区（`project.remote` 非空）里运行配置的读取、启动、停止、输出和输出链接。本机工作区的运行流程不受影响；插件任务步骤、构建工具、插件运行和调试在主机上的执行以 #2231 R3/R4 的笔记为准。
