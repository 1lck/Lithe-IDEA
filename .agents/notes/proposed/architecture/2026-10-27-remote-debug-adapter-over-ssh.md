# Agent 笔记：适配器运行在远端——经 SSH 的 stdio 调试

状态：提议中

## 先说结论

跨机器调试里很常见的一种情形是**适配器本身跑在远端**：例如 `ssh host gdb -i=dap`，DAP（Debug Adapter Protocol，编辑器和调试器之间的标准协议）照旧走标准输入输出，只是中间多了一个 ssh 进程。这种情形不需要 Lithe 自己的加密传输：认证、加密、主机指纹全部交给系统 `ssh`，Lithe 复用已有的传输链（`TransportChain`，见[远程开发 Note](2026-10-24-remote-development-workspace-host.md)）拼出命令，并在 Core 会话层做本地与远端路径的双向翻译。

三件事必须由 Lithe 做，不能交给插件或 ssh：**目的地由用户提供并每次确认**（插件只能声明“这个适配器可以在远端运行”以及要运行的命令，不能决定连到哪里）、**路径翻译**（远端适配器回来的全是远端路径）、**失败诊断**（把 ssh 的错误分类成用户能看懂的原因，原文照样显示）。

本 Note 只写设计，**不开始实现**。“需要你确认的默认选择”一节列出的四项没有确认之前，不动代码。上一轮的[远程 attach 契约](2026-10-25-unified-debug-engine-and-adapter-registry.md)（适配器在本机、被调试程序在远端）已经落地，两者互补，不互相替代。

## 问题

“远程调试”有两种情形，现有契约只覆盖第一种：

| | 被调试程序在远端（已做：`targetBindings.connection`） | 适配器在远端（本 Note） |
| --- | --- | --- |
| 适配器进程在哪 | 本机 | 远端，经 ssh 的 stdio |
| 典型场景 | JVM 开了 `-agentlib:jdwp`、debugpy `--listen`、Node `--inspect` | `ssh host gdb -i=dap`、远端的 lldb-dap、Python 虚拟环境只在远端 |
| 路径 | 适配器在本机，路径是本地的，最多靠适配器自己的 `pathMappings` | 适配器看到的是远端路径，回来的 `stackTrace`、断点事件也是远端路径 |
| 需要新东西 | 目的地参数绑定 | 命令怎么在远端执行、目的地由谁给、路径怎么翻译 |

不处理的后果：用户在编辑器里看不到远端 gdb 的栈帧源码（路径对不上）、断点设不到远端、或者为了绕开这些问题自己手写 `ssh host '…'` 脚本——这正是[远程开发 Note](2026-10-24-remote-development-workspace-host.md) 明确禁止在功能代码里出现的做法。

## 提案

### 两种模型，先做第二种，保持与第一种兼容

- **模型 A：完整远程工作区。** 项目和适配器都在远端，通过 `lithe-remote-server` 访问，路径从头到尾都是远端路径，不需要翻译。这是[远程开发 Note](2026-10-24-remote-development-workspace-host.md) 的 M4（“插件声明运行位置，LSP 和调试适配器在远端运行”），产品界面还没有接入。
- **模型 B：源码在本地，只有适配器和被调试程序在远端。** 用户已经有本地工程，想用一台远端机器（Linux 开发板、服务器、不同架构的机器）上的 gdb 调试，不想把整个项目搬过去。这是用户提到的 gdb 跨机器场景。需要路径翻译、需要用户提供的目的地，不需要在远端安装 `lithe-remote-server`。

本 Note 做模型 B。它**直接复用 `TransportChain::command`** 拼 ssh 命令，不再写第二套 ssh 参数构造，所以以后模型 A 落地时，同一个适配器声明、同一个确认流程、同一份路径翻译函数都可以沿用，只是翻译表变成空（路径本来就是远端的）。

数据流：

```text
编辑器（本地路径）
  ⇄ Core：DAP 客户端 + 路径翻译（断点库、重定位、投影都只见本地路径）
  ⇄ 本机 ssh 进程（stdin/stdout 管道）
  ⇄ 加密网络
  ⇄ 远端 sshd → 适配器（远端路径）→ 被调试程序
```

### 谁负责什么

| 事项 | 负责方 | 说明 |
| --- | --- | --- |
| 声明“这个适配器可以在远端运行”，以及远端要执行的命令 | 插件（清单数据） | 只有一个命令名加固定参数，不含目的地，不含任何用户输入 |
| 目的地 `[user@]host[:port]`（或 ssh 配置里的别名）、路径映射、远端程序路径 | 用户 | 在“在远程主机上调试”对话框里填；每次启动前确认 |
| 校验目的地与映射、通过传输链拼命令、路径翻译、ssh 失败分类、首帧前噪声丢弃 | Rust Core | 一份实现，macOS 和 Windows 共用 |
| 定位并拉起系统 `ssh`、显示确认弹窗、进程树清理、退出确认 | 平台 | 沿用现有 `MacProcessDebugAdapterTransport` 一类的进程所有权规则 |
| 认证、加密、主机指纹、跳板（ProxyJump）、`~/.ssh/config` | 系统 `ssh` | 与用户在终端里手动 ssh 的行为一致 |

### 清单怎么声明（草图，实现时再对照 schema 定稿）

适配器只多声明一个“允许在远端运行”的标记，命令仍是现有的 `systemCommand`，只是此时 `commands[]` 在**远端**的 `PATH` 上解析，而不是走本机的工具发现：

```json
"launch": {
  "process": {
    "launch": { "kind": "systemCommand", "commands": ["gdb"] },
    "arguments": ["-i=dap"]
  },
  "transport": "stdio",
  "remote": { "via": ["ssh"] }
}
```

声明期校验（违反则清单为 `plugin.manifest.invalid`，与[远程 attach 契约](2026-10-25-unified-debug-engine-and-adapter-registry.md)里“目的地冲突在声明期拒绝”同一思路）：

- `remote` 只允许和 `launch.transport: stdio` 同时出现；`tcpPort`、`tcpAnnounced`、`tcpLanguageServer` 的端点是本机回环，放到远端没有意义，直接拒绝。
- `launch.process.launch.kind` 只能是 `systemCommand`，且 `commands[]` 恰好一个裸命令名。`packaged`（包内可执行文件）、`runtime`、`runSelectedRuntime` 都是“本机解析出的路径”，对远端没有意义。
- `arguments[]` 只能由固定字符串组成，字符限于 `[A-Za-z0-9._/=:+@%,-]`，不允许 `${…}` 模板展开。这样用户输入永远不会进入远端命令行。
- 声明了 `remote` 的适配器不得声明 `process.environment`、`process.workingDirectory`：它们在远端没有明确含义，需要时由适配器协议内部的 `launch` 参数传递（走 DAP JSON，不走命令行）。
- 需要权限 `debug.remote`（见下），并且 `debug.launch`/`debug.attach` 照常需要。

`plan_descriptor` 增加 `remoteRun: {via: ["ssh"], pathMappings: bool}` 或 `null`，宿主据此决定是否显示“在远程主机上调试”，不按适配器名字判断。这与已有的 `remoteAttach` 并列，不合并：两者回答的问题不同。

### 命令怎么构造

1. 宿主把用户填的目的地交给 Core。Core 用 `validate_ssh_destination` 同样的规则校验（非空、不以 `-` 开头、无空白与控制字符），再解析成 `SshHop { program, destination, port, options }`。
2. `program` 是平台定位到的系统 `ssh`（平台负责，因为 macOS 和 Windows 的位置与发现方式不同）。
3. `options` 固定加入：`BatchMode=yes`（见下“认证”）、`ConnectTimeout=10`、`ClearAllForwardings=yes`、`ForwardAgent=no`、`ForwardX11=no`。命令行里的 `-o` 优先于 `~/.ssh/config`，所以用户配置里的 `LocalForward`、`ForwardAgent` 不会被带进调试会话；`ProxyJump`、`ProxyCommand` 照常生效，与用户在终端里的行为一致。
4. 用 `TransportChain::command(&[command, arguments…])` 得到最终 argv。链已经负责：`-T`（不分配 PTY）、`-e none`、`ServerAliveInterval=15`/`ServerAliveCountMax=3`、`--` 后接目的地、对远端命令的 shell 引用与对 `'`、`\`、`!`、控制字符的拒绝。**Lithe 的调试代码里不写任何一行 shell 引用。**
5. 用户输入的远端程序路径（`launch.program`）和远端进程号只出现在 DAP JSON 里，不进入命令行。

### 路径翻译

翻译放在 **Core 会话层**，是一个纯字符串函数，不碰文件系统。授权（哪些本地目录可以被调试器读到）仍然是平台的职责，不因翻译而改变。

- **映射表**：用户在对话框里填，最多 16 条 `local ↔ remote`；本地根必须是绝对路径，远端根必须是 POSIX 绝对路径（第一版不支持 Windows 远端，见“不做”）。
- **匹配规则**：最长前缀优先，只在路径组件边界匹配（`/work/app` 不匹配 `/work/application`），区分大小写，规范化多余的 `/`，不解析符号链接（Core 不碰文件系统）。
- **出站**（本地 → 远端，仅在构造发给适配器的 DAP 帧时转换）：`setBreakpoints`/`setFunctionBreakpoints` 一类请求里的 `source.path`，以及由本地目标事实绑定出来的路径（`target.path`、`target.workingDirectory`）。用户**直接当作远端路径输入**的值（`executable` 目标的程序路径、远端进程号）不翻译。断点库、断点重定位、投影都只保存本地路径，不会因翻译而漂移。
- **入站**（远端 → 本地）：`stackTrace` 帧的 `source`、`stopped`/`breakpoint`/`loadedSource` 事件、`output.source`，在 `map_source` 之前先翻译，之后沿用现有“工作区相对路径 → 会话来源（`sourceReference`）→ 无源码”的回退顺序；匹配“已解析断点”也先翻译再比较。
- **映射不到本地就不猜。** 回退到现有的无源码或 `sourceReference` 行为，界面显示远端原路径。`modules` 里的二进制路径按原样显示。
- **与适配器自带映射的关系**：对 ssh 运行的适配器，Core 始终做翻译，**不**把编辑器与适配器之间的映射写进适配器自己的 `pathMappings` 绑定，否则会翻两次。那个绑定只在“适配器在本机、被调试程序在远端”（已做的远程 attach）时使用。
- 附加（`attach`）在 ssh 模式下，`connection` 的主机和端口按**远端机器的视角**解释：例如远端的 gdb 连同机的 `localhost:1234` 的 gdbserver。确认弹窗同时显示 ssh 目的地和这个端点。

### 认证、主机指纹与确认

- **第一版只支持密钥和 ssh-agent**，用 `BatchMode=yes`：任何需要交互输入（密码、口令、2FA）的情形直接失败并给出说明，不弹终端、不卡住。密码和口令通过 `SSH_ASKPASS` 回传到 Lithe 弹窗，等[远程开发 Note](2026-10-24-remote-development-workspace-host.md) M2 的 askpass 入口落地后再接，不在这里单独做一套。
- **不关闭主机指纹校验**：不传 `StrictHostKeyChecking=no`，也不传 `accept-new`。未知主机直接失败，错误里说明“请先在终端里 ssh 一次确认指纹”。理由：调试适配器会在这台机器上以用户身份执行命令，静默接受未知主机等于让中间人替用户执行命令。
- **新权限 `debug.remote`**：它不是“连一个端口”，而是“以你的身份在你选择的另一台机器上执行一个命令”，比 `debug.attach` 严重得多。安装审查里单独列出（“在你指定的远程主机上运行 `gdb -i=dap`”）；声明的命令变化，需要重新批准。声明 `remote` 的适配器必须同时有 `debug.launch`，用于 attach 时还需要 `debug.attach`。
- **每次启动都确认，默认不记住**：弹窗显示目的地、完整远端命令（原样，不脱敏，与退出确认弹窗一致）、映射表，以及 attach 时的端点。和摄像头/麦克风同一原则：插件可以请求，但每次请求都不默认有权限。以后若要“记住这个主机”，只能由用户主动选择并按“主机 + 命令”记录。
- 退出确认（正在调试时退出应用）显示的命令包含目的地，同样原样显示。

### 失败与诊断

适配器在远端时，“启动失败”可能出在很多层，用户看到一句笼统的“适配器启动失败”几乎无法排查。Core 捕获 ssh 的 stderr，按下面分类，**每一类都附上 ssh 的原文**（原文是上游诊断，不翻译，也不改写）：

| 现象 | 常见原因 | 提示 |
| --- | --- | --- |
| `Connection refused` | 目的地端口上没有进程监听（sshd 没起、端口写错），或有人主动拒绝（防火墙 REJECT、本机代理没启动）。收到的是 RST，**不是超时** | 检查主机、端口；ProxyJump 的跳板是否可达 |
| `Connection timed out` / `Operation timed out` | 报文被丢弃（防火墙 DROP、网络不通） | 检查网络、VPN |
| `Could not resolve hostname` | DNS 或 ssh 配置里的别名写错 | 检查主机名 |
| `Permission denied` | 没有可用的密钥或 agent 未加载 | 检查密钥与 `ssh-add`；第一版不支持密码 |
| `Host key verification failed` | 未知主机或指纹变了 | 先在终端里 ssh 一次确认；指纹变了要小心 |
| 远端退出码 127 / `command not found` | 非交互 shell 的 `PATH` 里没有适配器（`.bashrc` 里设置的 PATH 在非交互登录里不生效） | 把适配器路径放进 `~/.profile` 或 `~/.bash_profile`，或安装到系统 `PATH` |

**首帧前的噪声**：远端 shell 的启动脚本可能在适配器开始前往 stdout 打印横幅，而 `protocol.rs::parse_messages` 遇到没有 `Content-Length` 的头会报错。第三方适配器我们没法像 `lithe-remote-server` 那样先输出一行标记（见远程开发 Note “流前标记”），所以改为：在**第一个** DAP 帧之前，丢弃最多 64 KiB 的字节，直到出现行首的 `Content-Length:`；超出上限仍没有，则结束会话，把丢弃的输出作为诊断返回。丢弃只发生在首帧之前，一旦进入正常帧流，任何格式错误仍照旧报错，不静默跳过。

### 生命周期与清理

- ssh 进程归会话所有。会话结束：先发 DAP `disconnect`（`launch` 为 `terminateDebuggee: true`，`attach` 为 `false`，沿用“`attach` 默认只断开”的所有权规则），再关闭 stdin，有界等待适配器退出，仍未退出则终止、再强制结束本机 ssh。
- 对端消失（网线断了、主机重启）靠传输链已有的 `ServerAliveInterval=15`、`ServerAliveCountMax=3` 在约 45 秒内发现并结束会话，不会悬挂。
- 远端孤儿进程**无法完全避免**：不分配 PTY 时，ssh 断开后远端适配器会收到 stdin 的 EOF 或 SIGPIPE，常见适配器据此退出，但被它启动的被调试程序是否随之结束取决于适配器。这是已知风险，在对话框说明里提示，不承诺。
- 所有 Lithe 本机进程（包括测试里的假 ssh）在任务完成后必须关闭，沿用仓库的“测试进程生命周期与清理”规则。

### 不做

- Lithe 自己的加密 TCP 传输（跨网络直连适配器）。这是最初“要先设计认证和加密传输”的判断，在 ssh 方案下不再需要。
- 保存私钥、密码、口令；密码和键盘交互认证（等 askpass）。
- Windows 远端主机（路径风格、命令解析都不同）。Windows 本机作为客户端的宿主接入另议，Core 部分两个平台共用。
- 插件声明任意 ssh 包装命令或 launcher argv：这会让插件决定本机执行什么。
- 容器（`docker exec`）作为启动器：`ContainerHop` 已有，以后同一套流程可以接入，不在这一轮。
- 自动从 `~/.ssh/config` 列出主机建议：是否做、怎么做另议。
- 模型 A（完整远程工作区）：属于远程开发的 M4。
- 子会话的 TCP（`startDebugging` 反向请求）的远端化。

### 需要你确认的默认选择

没有确认之前不开始实现：

1. **使用系统 `ssh` 和用户已有的 ssh 配置**（经 `TransportChain`），不内置 SSH 库、不另做加密传输。
2. **路径翻译放在 Core 会话层**，授权仍在平台。
3. **新增 `debug.remote` 权限**，并且每次启动都确认、默认不记住。
4. **第一版只支持密钥和 agent（`BatchMode=yes`）**，不支持密码。

### 分阶段

1. Core：清单声明与 schema、declaration 校验与拒绝 fixture、`plan_descriptor.remoteRun`、目的地校验与命令构造、路径翻译函数与会话接入、首帧噪声丢弃、ssh 失败分类、测试。
2. 契约与文档：`shared/contracts/plugins/v1/` 的 README、schema、fixture；合并后同步 lithe-plugin-docs。
3. macOS 宿主：对话框、确认弹窗、进程所有权与清理、退出确认、`shared/i18n` 词条、假 ssh 集成测试。
4. 真机验收：一台 Linux 主机上的 `gdb -i=dap`，覆盖设断点、命中、看栈帧、单步、结束、断线。
5. Windows 宿主和模型 A 另议。

### 正确做法

- 远端命令只通过 `TransportChain::command` 构造；目的地和路径映射由用户通过对话框提供，进入 Core 前不拼进任何字符串。
- 翻译函数是纯函数，出站只在构造 DAP 帧时用，入站只在 `map_source` 之前用；本地的断点库和投影永远只见本地路径。
- 新增一类 ssh 失败原因时，加入分类表和 i18n 词条，同时保留 ssh 原文。
- 想在远端启动一个新适配器时，只改插件清单，不改宿主。

### 不要这样做

- 不要在宿主或 Core 里写 `ssh host 'gdb -i=dap'` 这样的字符串，也不要自己做 shell 引用。引用只属于传输链。
- 不要让用户输入（目的地之外的任何值）进入远端命令行；程序路径、进程号放进 DAP JSON。
- 不要加 `StrictHostKeyChecking=no` 或 `accept-new` 让“第一次能连上”。静默接受未知主机会让中间人替用户执行命令。
- 不要在翻译失败时猜测一个本地路径；找不到就显示远端路径或“无源码”。
- 不要按适配器名字（`gdb`、`lldb-dap`）在宿主里加分支；`remote` 声明与 `remoteRun` 描述符就是为避免这件事。
- 不要把确认记住为“永远允许”。

## 考虑过的备选方案

### Lithe 自己的加密 TCP 传输

最吸引人的地方是不依赖系统 ssh，Windows 上也一致，可以直连任何监听 TCP 的适配器。不采用的原因是：认证、加密、证书/密钥管理、主机指纹都要重新做，每一项都是安全敏感且已有成熟上游实现的工作；而 gdb 的 `-i=dap` 本来就是 stdio，经 ssh 天然可用。

### 用户自己建 SSH 隧道，再用已有的 attach 连 `127.0.0.1`

最吸引人的地方是不需要任何新代码，现在就能用。不采用的原因是：只适用于适配器自己监听 TCP 的情形；stdio-only 的适配器（gdb `-i=dap`）没法通过隧道连。它仍然是个可用的权宜之计，不被禁止。

### 插件声明固定的 ssh 包装命令（`ssh` 作为 `commands[0]`）

最吸引人的地方是不用改契约，今天的 `systemCommand` 就能写。不采用的原因是：目的地得由插件写死，用户没法选择；没有确认和路径翻译；插件还能借此决定本机执行什么（`ssh -o ProxyCommand=…`），把一个本来受限的声明变成任意命令执行。

### 内置 SSH 库

已在[远程开发 Note](2026-10-24-remote-development-workspace-host.md) 否决：用户的 ssh 配置、ProxyJump、硬件密钥、各种 agent 和公司的 Kerberos/证书方案要重新实现，“无缝兼容”反而做不到。

### 只做模型 A（完整远程工作区）

最吸引人的地方是路径从头到尾都是远端的，不需要翻译，体验最一致。不采用的原因是：它依赖远程工作区的产品界面和 M4，周期长；而“本地有工程、只想借远端的 gdb”是眼前就有的需求。模型 B 复用同一条传输链，不会和模型 A 冲突。

### 路径翻译放在平台，各平台各做一份

最吸引人的地方是平台最了解文件授权。不采用的原因是：翻译是纯字符串逻辑，两个平台各写一份会漂移；授权仍留在平台，翻译函数不访问文件系统，边界清楚。

## 验收标准

- 清单校验：`remote` 与非 `stdio` 传输、与 `packaged`/`runtime`/`runSelectedRuntime`、与 `environment`/`workingDirectory`、与含 `${…}` 或不安全字符的参数同时出现，都被拒绝；拒绝 fixture 覆盖每一种。
- 命令构造：通过 `TransportChain::command` 得到的 argv 含 `BatchMode=yes`、`ClearAllForwardings=yes`、`--`；目的地为空、以 `-` 开头、含空白或控制字符被拒绝；端口越界被拒绝；用户输入不出现在远端命令参数里。
- 路径翻译：最长前缀、组件边界（`/work/app` 与 `/work/application`）、往返一致、多余 `/`、未映射回退到无源码/`sourceReference`、已解析断点在入站翻译后能匹配。
- 首帧噪声：噪声后接正常帧能成功；超过 64 KiB 或没有 `Content-Length:` 时会话结束并返回被丢弃输出；进入帧流之后的格式错误仍然报错。
- ssh 失败分类：每一类用固定 stderr 样本测试，原文被保留。
- 平台集成测试使用**假 ssh 可执行文件**（有界等待），验证确认弹窗每次出现、结束后没有残留的 ssh 进程、断开时发送了正确的 `terminateDebuggee`。
- 契约、README、schema、fixture 更新；`shared/i18n/` 补齐中英词条并通过 `node scripts/generate-i18n.mjs --check`；功能矩阵 `plugin-debug-adapters` 增补说明；合并后同步 lithe-plugin-docs。
- 真机验收：一台 Linux 主机上的 `gdb -i=dap`（设断点、命中、栈帧对应本地源码、单步、结束、断线）。

## 风险

- 远端孤儿进程无法完全避免（见生命周期）。缓解：对话框提示、`ServerAlive` 超时、`terminateDebuggee`。
- `BatchMode=yes` 让依赖密码的用户第一版完全用不了。缓解：错误信息明确，askpass 落地后再接。
- 远端 `PATH` 问题是最常见的失败原因，却不是 Lithe 能修的。缓解：分类里单独给出提示。
- 路径映射需要用户手填，填错会得到“无源码”而不是错误。缓解：对话框预览映射；入站无法映射时在调试控制台提示一次，而不是静默。
- 用户的 ssh 配置被信任，包括 `ProxyCommand`。这与用户在终端里手动 ssh 的信任相同，不额外限制，但文档说明。
- 草图声明形态在实现前还会调整，契约是未发布的 API 4，允许修改。

## 适用范围

- `rust/lithe-core/src/debug/`
- `rust/lithe-remote-client/src/transport.rs`
- `shared/contracts/plugins/v1/`
- `macos/Sources/Lithe/Platform/MacOS/Debug/`
- `shared/i18n/`
