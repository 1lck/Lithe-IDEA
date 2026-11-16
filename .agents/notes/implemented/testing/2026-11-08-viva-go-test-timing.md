# Agent 笔记：Viva 桌面测试的逐项计时

状态：已实现

## 先说结论

Viva 客户端的测试是 Go 测试。macOS 和 Windows 的桌面计时入口运行 `go test -json`，把每个实际执行的测试结果写入 JSON、HTML 和 JUnit，空匹配或未结束的测试不能算通过。它复用桌面构建脚本的 Core 构建，不为每个测试重新编译 Rust。

## 问题

旧计时入口调用已经随 Swift 和 Tauri 客户端删除的脚本，无法验证新的 Go 测试。普通 `go test` 的包级结果又不能告诉维护者哪一个测试超出预算。Windows 系统自带的 `bash.exe` 可能指向 WSL，不能当成 Git Bash；旧的进程清理代码还会在 `taskkill` 失败时错误地报告已清理。

## 决策

- macOS 入口使用 `desktop-go.sh`，Windows 入口使用 Git for Windows 自带 Bash 和 `cygpath`。测试按包及用例串行运行，禁用测试缓存，并使用 Go 报告的单项耗时；父测试已经包含子测试耗时，报告的行合计不是实际墙钟时间。
- 运行器限制总时长与输出量。超时会请求终止进程树；Windows 检查 `taskkill` 的执行结果和直接子进程是否退出，无法确认时报告失败，并尽力结束直接子进程。清理失败不会让计时入口无限等待，但也不能伪称所有后代都已结束。
- 正确做法：指定真实 Go 包和测试名，检查报告包含目标用例，再结合竞态测试和对应平台的原生验收。不要用零匹配报告、单独的无头测试或旧 Swift/Tauri 报告证明现有 Viva 工作流已通过。
- 静态稳定性扫描器当前仍只分析 Rust、Swift 和 TypeScript 测试，**尚不分析 Go**。Go 测试需要人工检查有界等待、同步和资源清理；计时报表不能替代静态扫描或正确性测试。

### 界面测试必须明确触发重绘

Viva 无头驱动的 `Pump()` 只消费已经请求的重绘，不会因测试修改了模型就主动绘制。
测试直接调用 `reduceChrome` 后再 `settle()`，可能只改了面板状态而没有声明面板内容。
终端输出等后台通知又可能碰巧请求一帧，令同一个测试有时通过、有时失败（#1907）。

验证用户交互时，应点击真实控件，让驱动走与原生窗口相同的输入和重绘路径；只需准备
布局时，使用已有的 `h.chromeAction`，它明确请求重绘。不要给每次 `settle()` 强制加一帧，
那会掩盖生产代码漏通知的问题，也不能用延时等待后台通知替测试完成刷新。
终端菜单用例先消费输出的待绘制帧，再点击终端侧栏按钮；其进程仍由测试清理流程关闭。

### Windows 工具链必须覆盖用户目录和 shell 来源

Windows 的工具发现和构建模型测试要保留两条真实本机边界：从 PATH（命令搜索目录）或环境变量找到可执行文件并读取版本，以及通过 `.cmd` 批处理脚本启动工具并解码模型。只注入查找结果或版本输出，无法检查 Windows 的路径和进程启动规则。

`path_windows_test.go` 把合成运行时放在含空格的安装目录，分别通过 PATH 和合成工具自己的环境变量提供；`HOME`、`USERPROFILE` 指向含空格或中文的临时用户目录，不依赖本机 JDK。查找、版本进程和 Core 候选规则均走生产入口，只把全局配置根放进测试私有目录。

`build_command_windows_test.go` 用现有工作台测试驱动打开同类临时项目，从 PATH 找到 `.cmd`，让脚本将带空格和中文的参数传给合成构建工具，再通过生产命令模型入口解码结果并检查终态记录。脚本从 Unicode 环境读取工具路径，不依赖机器当前的控制台代码页。正确做法是用合成清单和测试可执行文件走这些边界；不要读取某个真实插件的包，也不要因本机没装某个工具就跳过用例。

临时程序只链接或复制当前测试可执行文件，始终只读；进程由有截止时间的生产启动器回收，临时目录由 Go 测试清理。工作台驱动沿用项目关闭和后台任务清理。测试不改真实用户配置，也不创建可跨工作树复用的资源。现有 Windows CI 的 `check.sh` 已运行这些包，无需增加第二个 Windows 构建作业。

打包平台的通用覆盖诊断由 Core 提供，契约和检查命令只在 [Core 工具链契约](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/toolchains/README.md) 维护；宿主不复制校验逻辑，也不为某个插件补专属扫描规则。这项静态诊断不替代插件仓库自己的真实工具验收。

## 考虑过的备选方案

- 将整包耗时平均分给测试：不能反映真实慢用例，也无法区分包编译和运行时间。
- 每个 Go 测试重新构建 Core 并单独运行：能隔离进程，但反复链接和冷编译成本过高。使用 Go 的测试事件和一个有界套件进程，保留局部测试自己的截止时间。
- 在宿主 CI 下载真实插件和工具：引入具体插件依赖、网络与安装布局，不能稳定控制失败形态。宿主只测试合成工具的通用流程，真实工具在插件仓库验收。
- 继续运行旧 Swift/Tauri 脚本：源码已经删除，旧报告无法验证 Viva；历史入口不应被伪装成当前通过的检查。

## 后果

维护者可以按测试和包定位失败、超时及慢用例，并从本地报告查看原始日志。单项预算在 Go 报告结果后检查；套件截止时间负责停止无响应的进程，因此单项测试仍必须拥有自己的有界等待。Windows 路径、清理及真实 Go 测试已在云主机的隔离夹具验证；这不等于 Windows 全量工作台或真实 Rust Core 已在新计时入口下验收。

## 验证

- Windows 运行 `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope DesktopGo -GoPackages ./internal/toolchain,./internal/workbench -GoTestPattern '^(TestToolchainCandidatesUseNativeShellPathsInUserProfiles|TestBuildModelLoadsFromPathOnlyBatchToolInUserProfiles)$'`：检查 PATH／环境变量两种来源、空格／中文两种用户目录、批处理模型和逐项报告。移除 `commandHomes` 传递或恢复普通 Windows 参数引用时，新用例必须失败；恢复修复后通过。此证据只覆盖合成工作流，功能矩阵的完整原生验收状态保持独立。

- `node --test --test-timeout=15000 .agents/skills/write-stable-tests/scripts/test-go-timing.mjs`：通过、失败、零匹配、损坏输出、超预算、超时和清理失败；Windows 额外覆盖 `taskkill` 失败。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --package ./internal/core --package ./internal/workbench -- --filter 'TestCoreAgentKeepsGoChildSignalStack|TestSignalGuardLeavesOtherSignalActionsUnchanged|TestGitCloneUsesCoreAndPreservesExistingDestination|TestWelcomeClonesRepositoryThroughRealCore|TestClone|TestClosingWindowCancelsClone|TestWelcomeMoreMenuClosesOnEscape'`：macOS 已生成 12 项真实结果及 HTML/JUnit。
- Windows 云主机在含空格的隔离路径运行了计时器自检和真实 `documentio` 文件读取测试；夹具的轻量桌面包装器直接调用 Go，未编译或验证 Core，也不代表 Windows 工作台验收。
- `TestTerminalMenuSelectsAllAndCopies` 在排空后台重绘后，旧的直接状态调用连续 5 次失败；改为真实按钮点击后连续 20 次通过。该证据是 macOS 无头交互，不代替原生窗口验收。

## 适用范围

- `.agents/skills/write-stable-tests/`
- `scripts/desktop/desktop-go.sh`
- `desktop/`
- `desktop/internal/toolchain/path_windows_test.go`
- `desktop/internal/workbench/build_command_windows_test.go`
