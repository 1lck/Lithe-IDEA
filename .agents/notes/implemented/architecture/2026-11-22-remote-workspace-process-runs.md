# Agent 笔记：远程工作区在主机上运行内置的程序和脚本运行配置

状态：已实现

## 先说结论

本笔记是 #2231 R1 的第一步（#43a）。远程工作区里，运行配置的读写、校验和启动计划由 Core 路由到主机（Core #161）：配置文件经 `lithe_workspace::fs` 存在主机的项目目录，计划按主机平台（Linux、macOS）生成，从不生成批处理或 PowerShell。桌面端拿到计划后，用 `remote.runProcess` 在主机上启动内置的程序和脚本运行（`process.*`），输出进 Run 窗口，标签页带“主机”徽标。

构建工具、插件提供的运行、调试和启动前步骤暂不在远程工作区运行，各自说明原因（`desktop.run.remote.*`），留给 #43b。

## 问题

- 远程工作区的项目只在主机上，本机的占位目录永远是空的。照本机方式起进程，会在空目录里跑，读不到项目文件。
- 运行配置本身存在项目目录里。不路由到主机，就会在占位目录里读到“没有配置”，写入时还会把文件写进占位目录。
- 主机上的程序输出可能很快、很多。Core 只缓存 1024 个未送出的事件，观察回调一旦阻塞，Core 会丢事件甚至结束请求。
- 程序输出里的路径是主机路径，本机打不开；工作区以外的主机文件也要能点开（与 Zed 一致）。

## 决策

### 只有内置运行在主机上启动

`startRunConfigurationWith` 在远程工作区只放行 `configuration.IsProcess()` 且不是调试的启动，其余以 `desktop.run.remote.unsupported` 拒绝。标题栏的“运行”放行选中的配置，“调试”和“当前文件”仍走 `refuseRemote`；选中的配置不是内置运行时，直接说明不支持，而不是报“构建目标缺失”。

`loadBuildSystems` 在远程工作区不探测构建系统：本机占位目录里没有项目，探测只会得到空结果。它把 `p.build.failed` 设成 `desktop.run.remote.buildTools`，运行配置菜单把这句话显示为不可点的说明；非空的 `failed` 也让生成层快照保持为空，所以不会往主机写生成层。

带启动前步骤的配置拒绝启动（`desktop.run.remote.beforeLaunch`）：步骤会运行插件任务或本机进程，而项目文件不在本机。需要通过工具链选择程序的计划（`executable.toolchain`）也拒绝（`desktop.run.remote.toolchain`），因为工具链解析读的是本机。

### 进程的启动、输出和结束

`desktop/internal/workbench/remote_run.go` 的 `launchRemoteProcessRun`：

1. 用 `remote.hostRequest` 的 `tempDirectory` 在主机临时目录建 `lithe-run-script-*`，把它作为脚本基名交给 `runConfig.createLaunchPlan`。脚本按计划写到这个目录（写入用“文件必须不存在”的预期版本），运行结束后不论成败、是否被停止都递归删除。连接断开或主机崩溃时留下的目录，由主机的临时目录清理负责。
2. 工作目录是项目相对的 `/` 路径，`remoteRunDirectory` 拼到主机根下，拒绝 `..` 和绝对路径。环境用主机的登录环境，叠加计划的 `environment` 和配置的 `env`。
3. 输出经 `remoteRunOutput` 交给控制台：观察回调只追加到缓冲区，从不等待；独立的泵按顺序送出。缓冲区上限 8 MiB，超出时丢弃最旧的未送出部分，并在控制台写一行提示（`desktop.run.remote.outputDropped`）。
4. “停止”先用 `process.kill`（force 为 false）给进程组发 SIGTERM，超过停止等待时间（`buildprocess.StopGrace`）仍未结束就取消请求，由 Core 强制结束。再按一次“停止”立即强制结束。
5. 进程以非零退出码结束时运行失败，被信号结束时说明信号编号；连接断开时说明“无法确定是否仍在主机上运行”，并交给窗口重新连接（断线后接回输出是 #43c）。

主机上的进程 id 不是本机的，`Pid()` 返回 0，所以 Run 窗口不采样它的端口、CPU 和内存。主机端口由端口工具窗口列出。

### 输出里的路径

`flushOutputLinks` 在远程工作区用主机根作为工作区根、按 `linux` 平台匹配路径。点击时用 `remote.stat` 找第一个主机上存在的文件，经 `remoteplaceholder.LocalPath` 换成占位路径交给编辑器打开；工作区以外的路径落在占位根旁的 `.lithe-remote-host` 下，与“工作区以外的远端文件按 Zed 方式打开”一致。需要插件解析的链接拒绝，因为插件读的是本机文件。

### 日志

日志只记命令和错误码，不记主机、路径、命令行或输出。早返回带 `// log-exempt:` 说明。

## 考虑过的备选方案

- **在本机用 ssh 直接起进程**：绕过 Core 的会话、认证和 S26 环境白名单，也拿不到 Core 的进程组管理和事件缓冲。
- **把脚本写到主机的项目目录**：会弄脏用户的工作区，可能被 Git 看到或被提交。
- **远程工作区也探测构建系统**：探测在本机占位目录里运行，结果永远为空，还会误导用户以为项目没有构建工具。

## 后果

- 远程工作区里能直接运行项目自带的程序和脚本配置，输出、停止和退出码与本机一致；Run 窗口的“主机”徽标说明它在哪里运行。
- 构建工具、插件运行、调试、启动前步骤和“当前文件”暂时不可用，各自给出说明，直到 #43b 把它们接到主机。
- 断线时运行结束为“无法确定是否仍在主机上运行”，主机上的进程可能还在；断线后接回输出由 #43c 负责。
- 主机临时目录里可能残留断线或崩溃时没删掉的 `lithe-run-script-*` 目录，由主机的临时目录清理回收。

## 验证

- `desktop/internal/workbench/remote_run_test.go`：主机上的启动参数、工作目录、环境、脚本写入和删除；退出码和信号；“停止”先发 SIGTERM；启动前步骤、工具链和调试的拒绝；输出缓冲丢弃最旧部分；输出链接的主机文件查找；不记主机和路径。
- `desktop/internal/core/remote_process_test.go`：`remote.runProcess` 事件的解析。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：运行时不写发行目录。

## 适用范围

适用于远程工作区（`project.remote` 非空）里运行配置的读取、启动、停止、输出和输出链接。本机工作区的运行流程不受影响；构建工具、插件运行、调试和启动前步骤在主机上的执行以 #43b 的笔记为准。
