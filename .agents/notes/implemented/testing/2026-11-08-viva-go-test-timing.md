# Agent 笔记：Viva 桌面测试的逐项计时

状态：已实现

## 先说结论

Viva 客户端的测试是 Go 测试。macOS 和 Windows 的桌面计时入口运行 `go test -json`，把每个实际执行的测试结果写入 JSON、HTML 和 JUnit，空匹配或未结束的测试不能算通过。它复用桌面构建脚本的 Core 构建，不为每个测试重新编译 Rust。

## 问题

旧计时入口调用已经随 Swift 和 Tauri 客户端删除的脚本，无法验证新的 Go 测试。普通 `go test` 的包级结果又不能告诉维护者哪一个测试超出预算。Windows 系统自带的 `bash.exe` 可能指向 WSL，不能当成 Git Bash；旧的进程清理代码还会在 `taskkill` 失败时错误地报告已清理。

## 决策

- macOS 入口使用 `desktop-go.sh`，Windows 入口使用 Git for Windows 自带 Bash 和 `cygpath`。测试按包及用例串行运行，禁用测试缓存，并使用 Go 报告的单项耗时；父测试已经包含子测试耗时，报告的行合计不是实际墙钟时间。
- Windows 入口只接受 `DesktopGo`；旧 `All`、`Frontend`、`WindowsRust`、`SharedRust*` 和对应前端路径、Core 分片参数在参数绑定时拒绝。`All` 不映射到部分覆盖，旧入口也不再尝试下载 Bun、进入已删除目录或重建旧 Cargo 缓存。实际桌面源码缺失时，在运行检查前给出明确错误；Core 验证由正在链接的外部 Core 仓库负责。
- 运行器限制总时长与输出量。超时会请求终止进程树；Windows 检查 `taskkill` 的执行结果和直接子进程是否退出，无法确认时报告失败，并尽力结束直接子进程。清理失败不会让计时入口无限等待，但也不能伪称所有后代都已结束。
- 正确做法：指定真实 Go 包和测试名，检查报告包含目标用例，再结合竞态测试和对应平台的原生验收。不要用零匹配报告、单独的无头测试或旧 Swift/Tauri 报告证明现有 Viva 工作流已通过。
- 删除随客户端退役的 Swift/Bun 计时器及 Bun 专用 JUnit 读取器；保留共用的进程控制、Rust 计时与报告格式。归档 Note 和历史报告继续作为历史资料，不重新提供旧客户端执行路径。
- 静态稳定性扫描器保留 Rust 规则，移除旧 Swift/TypeScript 规则与旧客户端路径分类，**尚不分析 Go**。当前 `desktop/` 的 Go 测试会明确列为未覆盖，没有适用 Rust 来源时输出 `N/A`，不能把零违规当成 Go 通过。Go 测试仍需人工检查有界等待、同步和资源清理，再运行逐项计时与竞态检查；不以少量字符串规则冒充 Go 并发安全分析。

### 界面测试必须明确触发重绘

Viva 无头驱动的 `Pump()` 只消费已经请求的重绘，不会因测试修改了模型就主动绘制。
测试直接调用 `reduceChrome` 后再 `settle()`，可能只改了面板状态而没有声明面板内容。
终端输出等后台通知又可能碰巧请求一帧，令同一个测试有时通过、有时失败（#1907）。

验证用户交互时，应点击真实控件，让驱动走与原生窗口相同的输入和重绘路径；只需准备
布局时，使用已有的 `h.chromeAction`，它明确请求重绘。不要给每次 `settle()` 强制加一帧，
那会掩盖生产代码漏通知的问题，也不能用延时等待后台通知替测试完成刷新。
终端菜单用例先消费输出的待绘制帧，再点击终端侧栏按钮；其进程仍由测试清理流程关闭。

### 测试夹具只依赖被测边界

- 默认安装目录发现测试使用已有注册表替身，排除开发机安装；注册表优先级由专门用例验证（#2431）。不得修改开发机注册表来使测试通过。
- 跨 Core 边界的 Windows 可执行路径与运行时目录按 `filepath.Clean` 后的路径比较，命令参数仍严格按顺序比较。失败诊断逐字段输出，不转储含完整环境的启动计划（#2432）。
- 项目树展开上限测试保留 514 个目录与 512 个展开上限；根列表及未知路径由真实 Core 读取，已知子目录由可控夹具返回固定内容。验证全部展开目录已加载、各自文件存在、读取批次不超过 64，未展开目录未被请求。真实小树的展开、折叠和目录读取继续由相邻集成测试覆盖。不要让上限测试依赖 512 次原生 Git/ignore 查询能在通用八秒监听期限内完成，也不通过加长期限掩盖夹具成本（#2433）。
- 同插件运行聚合后，通过执行树里的会话节点切换控制台，并核对实际选中的会话与独立样本；不要沿用聚合前的顶部会话标签名来寻找控件。重新打开后的键盘展开与持久化断言继续保留（#2434）。

## 考虑过的备选方案

- 将整包耗时平均分给测试：不能反映真实慢用例，也无法区分包编译和运行时间。
- 每个 Go 测试重新构建 Core 并单独运行：能隔离进程，但反复链接和冷编译成本过高。使用 Go 的测试事件和一个有界套件进程，保留局部测试自己的截止时间。
- 继续运行旧 Swift/Tauri 脚本：源码已经删除，旧报告无法验证 Viva；历史入口不应被伪装成当前通过的检查。
- 保留旧 scope 并返回专门的退役分支：仍会在可选值中列出已无来源的测试。移除参数值让 PowerShell 的帮助、自动补全和绑定错误都指向唯一有效的 `DesktopGo`，历史命令明确失败，不维持第二套无效调度。
- 只因当前没有可扫描的源就打印静态检查通过：会误导调用方，以为当前 Go 测试已经经过等待与清理规则检查。显式报告覆盖缺口，仍保留适用的 Rust 规则和豁免理由校验，不放宽规则来制造通过结果。

## 后果

维护者可以按测试和包定位失败、超时及慢用例，并从本地报告查看原始日志。单项预算在 Go 报告结果后检查；套件截止时间负责停止无响应的进程，因此单项测试仍必须拥有自己的有界等待。Windows 路径、清理及真实 Go 测试已在云主机的隔离夹具验证；这不等于 Windows 全量工作台或真实 Rust Core 已在新计时入口下验收。

## 验证

- `node --test --test-timeout=15000 .agents/skills/write-stable-tests/scripts/test-go-timing.mjs`：通过、失败、零匹配、损坏输出、超预算、超时和清理失败；Windows 额外覆盖 `taskkill` 失败。
- `node --test --test-concurrency=1 .agents/skills/write-stable-tests/scripts/test-windows-timing.mjs`：以真实 PowerShell 入口和 Node 计时器验证 scope、缺失来源、参数透传、失败状态和超时后代清理；只替换 Git 工具发现与 Go 事件来源。Linux PowerShell 的通过结果不代表 Windows PowerShell 5、Git Bash 或原生 Windows 清理已经验收，Windows 仍需执行同一用例及真实桌面测试。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --package ./internal/core --package ./internal/workbench -- --filter 'TestCoreAgentKeepsGoChildSignalStack|TestSignalGuardLeavesOtherSignalActionsUnchanged|TestGitCloneUsesCoreAndPreservesExistingDestination|TestWelcomeClonesRepositoryThroughRealCore|TestClone|TestClosingWindowCancelsClone|TestWelcomeMoreMenuClosesOnEscape'`：macOS 已生成 12 项真实结果及 HTML/JUnit。
- Windows 云主机在含空格的隔离路径运行了计时器自检和真实 `documentio` 文件读取测试；夹具的轻量桌面包装器直接调用 Go，未编译或验证 Core，也不代表 Windows 工作台验收。
- `TestTerminalMenuSelectsAllAndCopies` 在排空后台重绘后，旧的直接状态调用连续 5 次失败；改为真实按钮点击后连续 20 次通过。该证据是 macOS 无头交互，不代替原生窗口验收。

## 适用范围

- `.agents/skills/write-stable-tests/`
- `scripts/desktop/desktop-go.sh`
- `desktop/`
