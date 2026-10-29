# Agent 笔记：子进程摄像头 / 麦克风隔离

状态：提议中

## 先说结论

一旦 Lithe 补上摄像头 / 麦克风的用途说明，使用者在网页弹窗里点一次“Allow”，系统记下的就是“Lithe 可以用摄像头”。Lithe 启动的子孙进程（插件后端、语言服务器、内置终端里的命令、Agent 的 shell 工具）会沿着责任进程规则继承这份授权，不经过任何弹窗，而网页那道默认拒绝门 `WebMediaCapture.decide` 管不到它们。提案是在所有启动子进程的入口统一套一份只禁摄像头 / 麦克风的沙盒 deny 策略，让用途说明和这层隔离在同一个 PR 里上线，并且隔离自检失败时网页门一律拒绝。

2026-10-22 维护者决定暂不做：摄像头 / 麦克风功能继续休眠，不改 Info.plist，不做真机验证，也不做子进程隔离。这篇 Note 是以后重启这条线时的依据，不是待办；评估的实测依据写在 `2026-10-22-html-preview-embedded-browser.md` 的“补用途说明之前必须知道的事”。

## 问题

HTML 预览和插件页已经有统一的默认拒绝门，但它只管网页。补上用途说明之后会发生这样的事：

1. 使用者在 HTML 预览的弹窗里点“Allow”，系统权限框也通过，系统记下“Lithe 可以用摄像头”。
2. 某个插件的后端进程（或者终端里的 `ffmpeg`、Agent 让 shell 执行的命令）去打开摄像头。macOS 把子进程的隐私请求算在责任进程（responsible process，系统决定这个请求算在哪个应用头上的那个进程）头上，而责任进程沿子孙链继承，所以请求被算在 Lithe 头上，授权已经存在，设备直接打开。
3. 整个过程没有经过 `decide`，没有 Lithe 的弹窗，也没有应用内的使用指示器。插件不需要任何网页就能偷听。

目前不存在这个口子：没有用途说明，系统会直接拒绝这些访问。也就是说，口子是补用途说明的那一刻才被引入的，修补必须在同一次改动里完成，不能“先补说明、以后再隔离”。

已经在 macOS 27.2 上实测的事实（细节和没验证的部分见上面那篇 Note）：

- 责任进程沿子孙链继承。
- 脱钩责任进程（disclaim，`posix_spawn` 的私有属性）能切断继承，但会同时切断 Lithe 的全部其它系统授权。
- 沙盒的摄像头 / 麦克风操作存在；加上 deny 之后 `sandbox_check` 的答案翻转并传给后代；但采集是否真的被拦住，没有在真实设备上验证。

### 哪些启动入口会受影响

| 类别 | 启动入口 | 隔离方式 |
| --- | --- | --- |
| 运行、构建、测试、调试采样、插件包解压、调试适配器 | Swift `MacManagedProcess.spawn`（唯一的 `posix_spawn` 入口） | 在这一处包装，一处覆盖全部 |
| 内置终端 | `MacTerminalTransport.startProcess`，经 SwiftTerm 启动 | SwiftTerm 自己创建伪终端并 `posix_spawn`，Lithe 拿不到 spawn 属性，只能改被启动的可执行文件 |
| 插件后端、所有语言服务器 | Rust Core 的 `SystemProcessLauncher`（`rust/lithe-core/src/lsp/interface/process.rs`） | Rust 侧一个公共函数；Swift 的语言服务器会话只是调用 Core 并登记 pid，不是它启动的 |
| Agent CLI 及其 shell 工具 | `rust/lithe-agent-host` | 同一个公共函数；模型自己决定跑什么命令，被提示注入时和“插件偷听”是同一类风险 |
| 其它固定二进制 | `lithe-git-host`、`lithe-db-sidecar`、`lithe-db-mcp`、`lithe-ide-host` 等 | 实现时重新盘点（`lithe-ide-host` 这次评估没有查），覆盖或登记豁免 |
| 必须豁免 | `MacProcessSupervisor`、`MacApplicationRelauncher`、`MacStableRollback` | 它们就是 Lithe 自己，要保持原来的责任进程 |

三套启动栈（Swift 的 `posix_spawn`、SwiftTerm、Rust 标准库）里任何一套漏掉，都是一个口子。

## 提案

### 开发者将来怎么用

只对 Lithe 启动的进程做隔离，调用方不用关心细节：

- 引入“子进程启动策略”，默认值是“套摄像头 / 麦克风 deny 策略”。要豁免必须在启动点登记理由，例如“这是 Lithe 自己的监督进程”。
- Swift 在 `MacManagedProcess.spawn` 里把要启动的程序换成包装后的命令（`sandbox-exec` 带策略再接原命令，或随包的小 shim）；终端在 `startProcess` 里换被启动的可执行文件，并确认登录 shell 的 `argv[0]`、shell integration、前台作业识别不受影响；Rust 侧用一个公共函数同时包住 `SystemProcessLauncher` 和 agent-host 的启动点。
- 网页门联动：`WebMediaAccess.outcome` 增加“隔离自检通过”这个条件。自检用 `sandbox_check` 在一个受限子进程里确认 `device-camera` 和 `device-microphone` 都被拒；失败就像缺用途说明时一样返回 `.unavailable`，门直接拒绝，不触发系统授权框。`.unavailable(missing:)` 现在带的是缺用途说明的设备，自检失败时可以把被请求的设备全部放进去，也可以新增一种结果，实现时再定。
- 用途说明（`NSCameraUsageDescription`、`NSMicrophoneUsageDescription`）作为这个 PR 的最后一步补上；补之前仍要先告知维护者并等确认。

### 沙盒策略

策略只禁设备，不动其它权限（文件夹、完全磁盘访问、自动化等照旧继承）。下面这份在 macOS 27.2 上可以解析，`device-*` 操作和相机 Mach 服务的 deny 都用 `sandbox_check` 确认过生效，并且会传给后代；麦克风 IOKit 这一条只确认了能解析，没有单独验证效果：

```scheme
(version 1)
(allow default)
(deny device-camera)
(deny device-microphone)
(deny mach-lookup
  (global-name "com.apple.applecamerad"
               "com.apple.appleh13camerad"
               "com.apple.cmio.registerassistantservice"
               "com.apple.cmio.registerassistantservice.system-extensions"))
(deny iokit-open-user-client (iokit-connection "AppleHDAEngineInput"))
```

这组名字来自系统自己给沙盒应用做摄像头 / 麦克风开关的 `/System/Library/Sandbox/Profiles/appsandbox-common.sb`（里面的 `(camera)` 和 `(audio-input)`），所以 deny 在采集路径上起作用的可能性很高，但仍然只是“可能性很高”。音频输出需要的 `com.apple.audio.coreaudiod` 保持允许，子进程放声音不受影响。

### 动手前先做一次真机验证（需要使用者参与）

沙盒 deny 能不能真的拦住采集，只有真的打开设备才能证明。做法：

1. 做一个一次性、ad-hoc 签名的小 App，放 `.artifacts/`，不进 `/Applications`，带两个用途说明。
2. 它启动时请求摄像头和麦克风，由使用者点一次系统弹窗（摄像头会短暂亮起）。
3. 通过后它启动两个子进程：一个直接启动，一个套上面的策略。各自尝试打开设备约 0.5 秒，把成功或失败打印出来，不保存也不上传任何画面或声音。
4. 预期：直接启动的成功（证明继承），套策略的失败（证明隔离）。直接启动的如果也失败，说明继承的前提和评估时想的不一样，要先回到评估，同样有价值。
5. 内置摄像头、内置麦克风、USB 设备、蓝牙耳机麦克风各试一次，策略按结果补全。
6. 结束后退出并删除这个 App，用 `tccutil reset Camera <探针包名>` 和 `tccutil reset Microphone <探针包名>` 清掉它自己的两条授权。这两条命令只动探针自己的记录，由使用者确认后再运行。

验证不通过就退回“摄像头页面交给默认浏览器”。

### 正确做法

- 新增启动子进程的代码，走已有的隔离启动器；确实要豁免时登记理由，并让源码扫描测试知道。
- 想让某个插件合法使用摄像头，走网页路径（`decide` 逐次确认），或者以后另外设计带逐次确认的显式能力；不要为它放宽隔离。
- 如果 `2026-10-16-unified-child-process-lifecycle.md` 里的统一启动入口先落地，就把隔离放进那个唯一的入口，不要再造第二套包装。

### 不要这样做

- 不要单独补用途说明，也不要先补用途说明、以后再补隔离。
- 不要用 disclaim 代替沙盒 deny：它会同时切断文件夹、完全磁盘访问、自动化等所有授权，项目在 Documents / Desktop / Downloads 下时 `git`、`java`、`node`、`mvn` 都会逐个弹文件夹授权或被拒。
- 不要在宿主里按插件名或插件 ID 给隔离写特例。
- 不要在隔离自检失败时继续弹授权框。自检是“能证明隔离在生效才开门”的开关，失败就关门。

## 考虑过的备选方案

### 保持休眠（现状）

最有吸引力：零风险、零成本，今天就是这个状态。它不是被否决的方案，而是 2026-10-22 的决定；只要没有人要启用摄像头 / 麦克风，就不需要本提案。本提案描述的是“要启用时必须先做什么”。

### 脱钩责任进程（disclaim）

最有吸引力：已验证有效，Swift 的 `posix_spawn` 只要加一个属性；本机的 Claude 桌面应用启动 `claude` 命令行就是这么做的（用自带的 `Contents/Helpers/disclaimer`）。不采用的原因：它让子进程与 Lithe 的全部授权脱钩，对 IDE 是回归，`git`、`java`、`node`、`mvn` 在受保护目录下会逐个弹文件夹授权或被拒，给了 Lithe 完全磁盘访问的使用者则整体失效；Rust 标准库也没有对应接口，要额外写。

### 把采集放到独立的助手 App

最有吸引力：授权记在助手身上，Lithe 本体没有摄像头授权，彻底没有继承问题。不采用的原因：`WKWebView` 不能跨进程嵌入，页面要在助手里渲染，等于重做预览架构，代价过大。

### 摄像头页面交给默认浏览器

最有吸引力：最稳，Lithe 不需要任何摄像头授权，也就没有继承。代价是页内摄像头不可用，只能用“在系统浏览器中打开”。它是真机验证不通过时的退路，不是首选，因为首选要保留页内摄像头。

### 每次采集结束后 `tccutil reset`

最有吸引力：能缩短授权存在的时间。不采用的原因：窗口期内仍然无效，应用要去改使用者的隐私设置，每次采集多一个系统弹窗，而且有竞态。

## 验收标准

- 真机验证通过（见上）：直接启动的子进程成功、套策略的失败；各类设备都覆盖。
- 三套启动栈全覆盖：源码扫描测试（像 `WebMediaCaptureCoverageTests` 那样）要求每个启动点要么走隔离启动器，要么登记豁免理由，新增启动点不登记就失败。
- 自检有测试：`WebMediaAccess.outcome` 在自检通过时才可能询问，失败时返回 `.unavailable`；`sandbox_check` 的自检在受限子进程里运行。
- 行为不回归：被包装进程的 pid 与登记的一致，进程组、会话、信号转发和退出码不变；终端里登录 shell 的 `argv[0]`、shell integration、前台作业识别不变；项目在 Documents 下时 `git`、`java`、`node`、`mvn` 仍能用 Lithe 已有的文件夹授权；终端里 `afplay` 仍能出声。
- 终端里 `ffmpeg` 一类的采集命令失败（今天本来也失败，不算回归）。
- 豁免的三个进程（`MacProcessSupervisor`、`MacApplicationRelauncher`、`MacStableRollback`）不套策略，并且在源码扫描里有登记。
- 运行时只读边界：包装用到的任何随包文件都在构建阶段生成，`./scripts/macos/verify/verify-runtime-bundle-immutability.sh` 通过。
- 用途说明和隔离在同一个 PR 里；补用途说明前先告知维护者并等确认；功能矩阵标明仅 macOS。

## 风险

- `sandbox-exec` 的手册标为 DEPRECATED（已弃用），27.2 上仍可用；沙盒策略语言没有公开的稳定契约，以后的 macOS 可能改变或移除。回退：自检失败时网页门拒绝，功能退回休眠，不会放大风险；真机验证不通过则退到“摄像头页面交给默认浏览器”。
- 设备路径可能遗漏：Apple Silicon 内置麦克风是否确实走 `AppleHDAEngineInput` 没验证，USB 和蓝牙设备可能走别的路径。自检只能证明策略在生效，不能证明覆盖了所有设备路径，所以真机验证要逐类设备做。
- 不在 Lithe 子孙链上的进程（经 launchd、LaunchServices 的 `open` 或已经在运行的 XPC 服务做事的进程）策略管不到。按规则系统也不会把它们的隐私请求算在 Lithe 头上，但这一点没有逐项实测。
- 每次启动多约 5 毫秒（`sandbox-exec` 包一层，20 次平均从 1.8 毫秒到 6.7 毫秒）；启动大量短进程的构建流程要实测。
- 终端被包一层之后的行为（登录 shell、shell integration、前台作业识别）没有验证，是实现时最容易出细节问题的地方。
- ad-hoc 签名下，系统记录的授权是否随每次更新失效没有实测；这影响授权能存活多久，不影响隔离是否有效。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Process/MacManagedProcess.swift`（唯一的 `posix_spawn` 入口，Swift 侧的包装点）
- `macos/Sources/Lithe/Platform/MacOS/Process/MacProcessLifecycle.swift`（`MacProcessSupervisor`，必须豁免）
- `macos/Sources/Lithe/Platform/MacOS/MacApplicationRelauncher.swift`（必须豁免）
- `macos/Sources/Lithe/Platform/MacOS/Updates/MacStableRollback.swift`（必须豁免）
- `macos/Sources/Lithe/Platform/MacOS/Terminal/MacTerminalTransport.swift`（内置终端的启动入口）
- `macos/Sources/Lithe/Platform/MacOS/WebMediaCapture.swift`（网页门，隔离自检的联动点）
- `macos/Tests/LitheTests/WebMediaCaptureTests.swift`（源码扫描测试所在位置）
- `macos/Resources/Info.plist`（用途说明，最后一步才补）
- `rust/lithe-core/src/lsp/interface/process.rs`（插件后端和语言服务器的启动入口）
- `rust/lithe-agent-host/`
