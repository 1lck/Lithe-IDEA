# Agent 笔记：Viva 的插件构建与运行纵向切片

状态：已实现

## 先说结论

Viva 的 Build 工具窗口现在由插件声明的构建系统驱动：Core 负责检测实例、校验选择并生成命令计划或 provider 请求，Go 只负责解析 Core 给出的可执行候选、启动 provider 或宿主进程、呈现有界输出和停止进程。没有硬编码 Java、Maven、Gradle 或 Cargo 任务；command 和 provider 两种任务都来自 Core 校验过的清单与模型。

本次真实可用的验证对象是已发布的 Cargo 构建插件 0.1.0：安装、启用、检测、provider 模型加载和 `cargo build` 命令任务已在 macOS 上跑通。安装器现在同时接受契约的 `<plugin-id>/plugin.json` 布局和旧的无外层目录布局；原始 GitHub Release 包不再需要重打包，安装、启用、模型加载和构建都用未修改的发布包验证。内容根目录必须与清单 ID 一致，歧义或越出内容根的归档会被拒绝，而不是被 flatten 后继续安装。

## 问题

插件安装、授权、启用和语言服务器生命周期已经在 Viva 中存在，但 Build 工具窗口还是占位。Core 已经实现 `build.detect`、`build.invocationPlan`、`build.modelPlan`、`build.taskPlan`、`build.prepareRunPlan`、`build.decodeRunPreparation` 和 `lsp.buildRequest`，宿主却既没有调用它们，也没有声明 `buildSystems`、`buildProviders` 能力。结果是构建插件在安装审查阶段就被拒绝，用户看不到任何真实任务。

另一个容易误判的点是：Core 有接口不等于宿主已经接好。Provider 的启动计划、共享语言服务器会话、`litheBuild` 协议协商、请求进度与完成事件、取消后的终态、进程树清理，都必须由宿主实际执行；只在 Go 里复制一份“Model/Task”数据结构会制造第二份业务规则。

## 决策

- **能力声明只写已经接通的版本。** `pluginhost.Declared()` 声明 `buildSystems:1` 和 `buildProviders:1/2`。版本 1 覆盖 command 模型/任务和 shared/own provider 的基础协议，版本 2 覆盖 provider 任务执行。运行准备（4）、测试、Debug、`executableResolution` 和插件设置没有声明，需要它们的插件仍会被安装审查拒绝。
- **Core 是唯一计划来源。** `desktop/internal/core/build.go` 只做 JSON 边界：检测、可执行候选、版本检查、模型/任务/运行计划、解码和 `lsp.buildRequest`。项目、目标、任务、参数和候选顺序来自 Core，Go 不推导构建工具语义。
- **Command 与 provider 都是真实入口。** Command 任务先经 `build.invocationPlan` 取得有序候选，按 Core 的顺序检查工程 wrapper、环境变量、设置路径和 PATH 命令，再用 `build.checkToolVersion` 验证最低版本；不会在 Go 里写一份工具清单。Provider 任务经 `lsp.buildRequest` 发送 `lithe/build/execute`。
- **Provider 进程由 `buildprovider` 独占。** 它通过 `pluginbackend` 以 `role: build` 启动 Core 计划出的进程，等待真实 `ready` 事件，把 `requestProgress` 与 `requestCompleted` 按 operation ID 关联，并在工作区关闭时停止会话。共享语言服务器 Provider 会附着到同插件、同语言的现有会话；没有会话时由宿主启动并登记，后续编辑器请求复用同一进程。共享会话的 ready 由语言服务器的真实 `stateChanged: ready` 事件唯一拥有：`pluginServer` 在同一把锁下记录 ready 与客户端集合，已有 ready 才能直接标记，新会话必须等 `Serve` 把真实事件送到客户端；退出后的会话不能再附着，也不会假报 ready。
- **构建与编辑器共用项目归属。** 构建先启动语言服务器时，也记录所属项目并在窗口线程为已打开的文档启动同步；注册表由同一把锁保护，关闭项目或停用插件后拒绝迟到的注册与附着。根 URI 由 Core 的文档 URI 接口生成。`TestClangdBuildStartedSessionSynchronizesEditor` 使用真实 clangd 验证构建先启动、文档同步、诊断及项目关闭；去掉项目归属时该测试失败。
- **宿主进程由 `buildprocess` 独占。** 它用显式的 `os.Pipe` 而不是 `exec.Cmd.StdoutPipe`，把“根进程退出”和“输出管道 EOF”分开。等待顺序固定为：`command.Wait()` 回收根进程 → 结束同组/同 Job 的后台子进程 → 在有界时间内排空 stdout/stderr → `platform.release()`。根进程正常退出但后台子进程继承管道时，不会卡住 `Wait`；根进程退出前写入的大块输出也不会被提前关闭读端截断。Unix 用独立进程组；Windows 用 Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）在子进程运行前接管整棵树。Job 句柄和“是否仍拥有进程树”由互斥锁保护，`Stop` 与正常退出/`release` 串行化；进程树释放后再次 `Stop` 直接返回，不会向复用的 PID 或句柄发信号。Core 的 `lithe-git-host::ProcessTree` 已经实现同一套 Windows 语义，但它的 C ABI 没有暴露给 Go；本树暂时镜像了这层原生适配，精确复用接口记在“后果”中。
- **有界呈现。** 输出只保留 4000 行且不超过 4 MiB；窗口只绘制最后 200 行。进度是建议信息，最终结果仍以 Core 的完成事件和进程退出状态为准。
- **操作终态只有一个所有者。** `Operation` 在自己的互斥锁内统一关闭 `progress` 和 `done`；所有 progress 投递先检查终态，因此 `failAll`/`Close` 与事件流不再出现 send-on-closed 或重复 close。`Execute` 注册 pending 后若 `RequestBuild` 失败，与并发 `failAll` 共用同一个终态入口，不会二次关闭；`Close` 会先终止所有 pending 操作，再等待会话停止。
- **生命周期跟随项目。** 关闭项目时先取消当前请求并停止进程，再有界停止 provider 会话；可写状态放在插件根目录的 `.state` 下，不写入安装包或 app bundle。
- **归档根与内容根分开，但只认契约允许的一种嵌套。** `pluginpkg.Extract` 先扫描并校验全部 ZIP 条目，再定位唯一的 `plugin.json`：位于归档根时内容根就是归档根，位于唯一顶层目录时该目录是内容根，其他位置或出现第二个清单都拒绝。写盘时去掉内容根这一层，`Package.Files` 和内容摘要描述的是安装包本身，不是下载到的 ZIP 结构。`plugininstall` 在 Core 规范化清单后要求内容根目录名等于插件 ID；内容根和清单身份不一致时安装失败。路径遍历、符号链接、大小写冲突、配额和原子 rename 仍由同一套检查负责，确认与审批流程没有跳过。
- **不按插件 ID 或来源特判布局。** 安装器只认“根目录”和“单层内容根”两种结构，Cargo、Maven 和未来任何插件走同一条路径；官方 Cargo 包不因为 ID 特殊而放宽检查。

## 考虑过的备选方案

- **在 Go 中读取 `pom.xml`、`build.gradle` 或猜任务名。** 放弃。那会把 Maven/Gradle 规则复制到平台层，两个平台会再次漂移，而且违背“共享逻辑必须在 Core”的边界。
- **按插件 ID 或构建系统 ID 写允许列表。** 放弃。能力声明已经足够表达宿主能做什么，按名称拒绝会把插件市场变成宿主代码的一部分，也会掩盖共享 Provider 或工具链的真实缺口。
- **把 `build.*` 暴露成插件后端可随便调用的 host 方法。** 放弃。契约明确后端请求 `lithe/build/*` 返回 `recursiveCall`；构建插件自己就是 provider，不应绕过 Core 的计划与选择校验。
- **直接运行 `build.prepareRunPlan` 返回的 `toolchain` 值。** 放弃。`project-jdk`、`project-maven` 这类值是插件声明的工具链引用，必须由宿主的工具链层解析；把它们当命令执行会启动错误程序。
- **先做一个只显示任务名的静态面板。** 放弃。它无法启动、取消或展示真实结果，会让用户以为功能已经可用。
- **按 Cargo 的 ID 或文件名特判发布包。** 放弃。那会把某个插件的打包方式写进宿主，其他按同一契约发布的插件仍装不上，也无法用通用测试保护。
- **在安装前把任意 ZIP 的顶层目录全部 flatten。** 放弃。无差别 flatten 会同时接受两个内容根、内容根外的文件和第二份清单，把“选择哪个清单审批”变成隐式规则；安装器必须明确拒绝歧义归档。
- **让安装器忽略内容根目录名，只信清单 ID。** 放弃。契约把 `<plugin-id>/` 写进包布局，目录名与清单 ID 不一致说明归档不是按契约生成；静默接受会让后续升级、摘要和人工排查失去可核对的结构。

## 后果

收益：用户安装一个不需要设置项、且不依赖工具链解析的 provider 构建插件后，能看到真实实例、项目、目标、任务和运行入口；Command 任务和 provider 任务都能启动，输出进入窗口，停止按钮结束当前请求或进程，关闭项目回收会话。macOS 已用 Cargo 插件 0.1.0 跑通真实安装和 `cargo build`。

代价：需要 `settings`、`executableResolution`、运行准备、测试或 Debug 的插件仍不可安装；工具链引用不会被执行；共享 Provider 只有在同一插件的语言服务器可用时才能复用；安装器只支持契约允许的两种归档结构，包含两个 `plugin.json`、内容根外的文件或更深层清单的归档会被拒绝，需要发布方重新打包；Windows 的 Job Object 代码已交叉编译但没有实机验证，仍为 pending。

为了删除 Windows 适配的重复实现，Core 应把 `lithe-git-host::ProcessTree` 暴露成窄 C ABI：`adopt(pid, allow_breakaway) -> handle`（进程由宿主以 `CREATE_SUSPENDED` 启动，Core 负责创建 Job Object、分配并恢复主线程）、`terminate(handle)`、`release(handle)`。在这组接口存在前，Go 版本保持同一语义，不新增自有的进程跟踪清单。

## 验证

- `./scripts/desktop/desktop-go.sh test ./...`
- `./scripts/desktop/desktop-go.sh test ./internal/pluginpkg ./internal/plugininstall -count=1 -v`（覆盖契约目录布局、flat 布局、歧义清单、内容根外条目、符号链接/冲突/配额回归）
- `LITHE_RAW_CARGO_PLUGIN_ARCHIVE=<未修改的 cargo-build-0.1.0-darwin.zip> ./scripts/desktop/desktop-go.sh test ./internal/workbench -run TestOfficialCargoReleasePluginBuildsAWorkspace -v`
- `LITHE_REPACKED_CARGO_PLUGIN_ARCHIVE=<cargo-build-0.1.0-darwin.zip 的根目录重打包> ./scripts/desktop/desktop-go.sh test ./internal/workbench -run TestRepackedOfficialCargoPluginBuildsAWorkspace -v`
- `./scripts/desktop/desktop-go.sh test ./internal/buildprovider -run TestProviderModelTaskAndCancellation -v`
- `./scripts/desktop/desktop-go.sh test ./internal/buildprocess -v`
- `./scripts/desktop/desktop-go.sh test -race ./internal/buildprovider ./internal/workbench -count=1 -timeout=120s`
- `./scripts/desktop/desktop-go.sh test ./internal/buildprovider -run 'TestAttach|TestOperation|TestProgress|TestClose|TestRequestFailureRacesFailAll' -count=1 -v`
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestPluginServerBuildReadiness|TestPluginServerAttachAfterExit' -count=1 -v`
- `./scripts/desktop/desktop-go.sh test -race ./internal/buildprocess -v`
- `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -c ./internal/buildprocess`（只证明可编译，不冒充 Windows 验证）
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/agent-notes/verify-agent-notes.sh`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`

Windows 没有运行本切片；真实执行证据是 macOS 上用未修改的官方 Cargo 0.1.0 Release 包完成安装、启用、provider 模型加载和 `cargo build`，flat 重打包版本作为兼容回归仍然通过。修复前的证据是同一份原始包在 `Prepare` 阶段返回 `plugin package has no plugin.json at its root`，新的 `TestOfficialCargoReleasePluginBuildsAWorkspace` 在修改提取器前以该错误失败。原始包没有发布者签名，清单声明 `signatureRequirement: none`，测试因此要求磁盘来源仍然弹出审批；布局修复没有把“无签名”变成可信来源。Maven 0.1.1 因清单中的 `languageImport` 字段与固定 Core 不兼容，未能安装；这是插件/Core 版本匹配缺口，不是本切片伪造的成功。

## 适用范围

- `desktop/internal/core/build.go`
- `desktop/internal/buildprovider/`
- `desktop/internal/buildprocess/`
- `desktop/internal/workbench/build.go`
- `desktop/internal/workbench/build_view.go`
- `desktop/internal/pluginservice/builds.go`
- `desktop/internal/pluginhost/pluginhost.go`
- `desktop/internal/pluginpkg/`
- `desktop/internal/plugininstall/`
- `desktop/internal/workbench/official_cargo_test.go`

共享协议和 Rust Core 的构建模型仍以 `Lithe-core-rust/rust/contracts/` 和固定 Core 修订为准；本笔记不定义新的插件协议。
