# Agent 笔记：运行配置的启动前步骤

状态：已实现

## 先说结论

运行配置可以列出启动前步骤（#1616，对应 IntelliJ IDEA 的 “Before launch: Run Another Configuration”）：

- 配置文件里写 `beforeLaunch: [{configuration: <id>}]`，最多 16 项。每一项只能引用内置进程运行（`process.shell`、`process.powershell`、`process.batch`、`process.executable`），不能引用自己。
- 一层（项目文件或 `local.yaml`）写了 `beforeLaunch` 就整体替换下层的列表；`local.yaml` 写空列表可以关掉项目文件里的步骤。
- 宿主启动前调用 Core 的 `runConfig.beforeLaunch`。Core 展开嵌套步骤（被引用的配置自己的步骤先运行），展开后最多 32 步；引用不存在、不能作为步骤、在本机不可用、成环、过长时返回 `rejected` 和原因码。
- 只要展开过程中用到了项目文件写的列表，Core 就返回确认指纹：对列表和这些步骤启动的命令定义求 sha256。宿主第一次运行前弹框列出步骤和命令，用户点“运行步骤”后把指纹存进应用自己的存储 `run-before-launch-approvals.json`（按项目根目录，每个项目最多 64 个）。命令或列表一改，指纹就变，会再问一次。
- 步骤按顺序在被启动配置的 Run 控制台里运行，每一步前写一行暗色标题。某一步退出码不是 0，就写出步骤名和退出码，不启动配置。停止配置会结束正在运行的步骤。
- 内置运行编辑器（Core 描述的表单，字段类型 `beforeLaunch`，候选列表由 Core 给出）和构建提供者运行编辑器都可以添加、上移、下移、移除步骤。构建提供者编辑器只有列表改动时才发送 `beforeLaunch`，不会把解析后的列表抄进本地层。

## 问题

用户要在启动服务前先跑生成代码、编译前端、拉起依赖等命令。原来只能手动先点一个配置、等它结束再点另一个；也没有地方表达“这个配置依赖那几个命令”。IDEA 用户习惯在运行配置里配置启动前任务。

同时，项目文件是仓库内容，打开别人的仓库后点运行就执行仓库指定的任意命令，等于让仓库在用户机器上执行代码而不经确认。

## 决策

- 步骤只引用已经存在的内置进程运行，不在 `beforeLaunch` 里内联命令。这样每个步骤都能单独编辑、单独运行，展开、校验和命令定义都由 Core 统一处理，宿主只负责按顺序启动进程。
- 校验、展开和指纹都放在 Core：三端行为一致，宿主不需要知道层级合并规则。保存时 Core 也用同一套规则检查（`check_edit`），成环在保存时报 `conflict`。
- 确认记录放在应用存储而不是项目里，仓库不能替用户批准自己的步骤。指纹包含命令定义，所以仓库更新步骤命令后会重新询问。用户自己 `local.yaml` 里的列表不询问。
- 步骤的进程用准备阶段的上下文启动（`op.bind`），停止配置时上下文取消，进程随之结束；每一步受 `runPreparationTimeout` 限制。
- 步骤失败的提示在窗口线程上直接写进控制台（`writeBuildOutputNow`），然后结束操作。用 `streamBuildOutput` 会异步投递，到达时操作已经结束，提示会被丢弃。

## 考虑过的备选方案

- 支持 IDEA 的全部启动前任务类型（Build、Run Maven Goal、Launch Web Browser 等）。先做“运行另一个配置”，其他类型由插件的 `runOptions` 扩展点以后补充（#2100 中尚未实现的部分）。
- 步骤并行运行。依赖顺序是用户最常见的需求，并行会让失败原因和输出交错，先保持顺序执行。
- 每次运行都询问项目文件里的步骤。会打断正常工作流，用户很快就会习惯性点确认；按指纹记住一次，命令改变时再问，兼顾安全和效率。

## 后果

- 用户可以在一个配置里串起准备命令，一键运行。
- 打开不信任的仓库时，第一次运行会看到将要执行的命令列表。
- 以后新增步骤类型时，要在 Core 的 `before_launch.rs` 加类型并纳入指纹，在宿主 `runBeforeLaunchStep` 加执行方式；确认框必须能展示新类型会做什么。

## 验证

- Core：`cargo test -p lithe-core before_launch`（`core/src/tests/before_launch_steps.rs` 覆盖展开、确认指纹、拒绝原因、编辑校验和本地层清空）。
- 宿主：`./scripts/desktop/desktop-go.sh test ./internal/workbench/ -run 'BeforeLaunch|TestRunConfigFormKeepsTheStepList' -count=1`，用真实 Core 和系统 shell/cmd 运行步骤，覆盖顺序、确认与记忆、改动后重新确认、取消、失败退出码和停止。

## 适用范围

- `desktop/internal/workbench/runconfig_before_launch.go`
- `desktop/internal/workbench/runconfig.go`
- `desktop/internal/workbench/runconfig_process.go`
- `desktop/internal/workbench/runconfig_form.go`
- `desktop/internal/workbench/runconfig_form_view.go`
- `desktop/internal/workbench/runconfig_edit.go`
- `desktop/internal/workbench/runconfig_view.go`
- `desktop/internal/core/run_before_launch.go`
- Core：`rust/crates/execution/src/configuration/before_launch.rs`
