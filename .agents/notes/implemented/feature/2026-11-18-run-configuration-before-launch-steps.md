# Agent 笔记：运行配置的启动前步骤

状态：已实现

## 先说结论

运行配置可以列出启动前步骤（#1616，对应 IntelliJ IDEA 的 “Before launch”）。步骤有两种：

- **运行另一个配置**：引用一个内置进程运行（`process.shell`、`process.powershell`、`process.batch`、`process.executable`），保存为 `{configuration: <id>}`。
- **插件任务**：插件在构建系统下声明的 `beforeLaunchTasks`（API-29），例如“运行 Go 命令”，保存为 `{task: {pluginID, buildSystemID, type, values}}`。

宿主不内置任何具体任务，也不按插件名字写分支：“添加任务”菜单（标题“添加新任务”，同 IDEA）第一项是“运行另一个配置”子菜单，后面逐项列出已启用插件声明的任务种类，名称、说明、图标和字段都来自插件清单和插件翻译。日常开发里，要加一种新的启动前任务，就去插件清单里声明，不要改宿主。

展开、校验、确认指纹和任务的命令计划都由 Core 完成；宿主只负责画列表、打开任务表单、按顺序启动进程，并把输出写进被启动配置的 Run 控制台。

## 问题

用户要在启动服务前先跑生成代码、编译前端、执行 `go generate` 之类的命令。原来只能手动先点一个配置、等它结束再点另一个；也没有地方表达“这个配置依赖哪些准备工作”。IDEA 用户习惯在运行配置里点“+”添加启动前任务，任务种类由各个插件提供。

同时，项目文件是仓库内容。打开别人的仓库后点运行就执行仓库指定的命令，等于让仓库不经确认就在用户机器上执行代码。

## 决策

**列表规则（Core）**

- 一个配置最多 16 项，展开嵌套步骤后最多 32 步。一层（项目文件或 `local.yaml`）写了 `beforeLaunch` 就整体替换下层的列表；`local.yaml` 写空列表可以关掉项目文件里的步骤。
- 宿主启动前调用 `runConfig.beforeLaunch`。Core 展开嵌套步骤（被引用的配置自己的步骤先运行）。引用不存在、不能作为步骤、在本机不可用（例如 macOS 上的 `process.batch`，Lithe-core-rust#87）、成环、过长、任务没有已启用插件声明（`taskNotDeclared`）、任务的值不再合法（`invalidTaskValues`）时，返回 `rejected` 和原因码，宿主把原因写进通知和控制台，不启动配置。
- 保存时 Core 用同一套规则检查（`check_edit`），成环在保存时报 `conflict`。

**确认（防止仓库替用户执行命令）**

- 只要展开过程中用到了项目文件写的列表，Core 就返回确认指纹：对列表和这些步骤启动的内容求 sha256。宿主第一次运行前弹框列出每一步的名称和摘要，用户点“运行步骤”后把指纹存进应用自己的存储 `run-before-launch-approvals.json`（按项目根目录，每个项目最多 64 个）。列表、命令或任务的值一改，指纹就变，会再问一次。
- 用户自己 `local.yaml` 里的列表不询问。确认记录放在应用存储而不是项目里，仓库不能替用户批准自己的步骤。

**插件任务（API-29）**

- 任务和运行配置类型一样由插件在 `buildSystems[]` 下声明：ID、名称、说明、图标、字段和参数模板，没有 `execution`、没有 `${userArguments}`，清单要求 `requires.beforeLaunchTasks`。宿主通过 `RunEditorForm` 请求携带的插件清单拿到 `beforeLaunch` 字段的 `tasks`（已经按界面语言翻译），并在后台线程读好任务图标再发布。
- 选中任务后，宿主用任务自己的字段打开一个表单弹窗（复用运行配置表单的字段控件）。点“确定”时宿主调用 `runConfig.checkBeforeLaunchTask`：值不对就把 Core 给的原因码显示在对应字段下，弹窗不关；值对了，Core 返回要保存的步骤（含名称和摘要），宿主把它放进列表并标记为未保存的修改。已有的任务步骤可以用铅笔按钮重新编辑。
- 运行时宿主调用 `build.beforeLaunchTaskPlan`，由 Core 用保存的值和配置的工作目录生成命令计划，再用该插件构建系统已检测到的实例对应的构建工具启动。项目里没有检测到这个构建系统时，任务不能运行，控制台写出“所选目标已不在构建模型中，请刷新构建系统。”（`desktop.build.targetMissing`）。

**执行**

- 步骤按顺序在被启动配置的 Run 控制台里运行，每一步前写一行暗色标题。某一步退出码不是 0，就写出步骤名和退出码，不启动配置。
- 步骤的进程用准备阶段的上下文启动（`op.bind`），停止配置时上下文取消，进程随之结束；每一步受 `runPreparationTimeout` 限制。
- 步骤失败的提示在窗口线程上直接写进控制台（`writeBuildOutputNow`），然后结束操作。用 `streamBuildOutput` 会异步投递，到达时操作已经结束，提示会被丢弃。

**编辑界面**

- 内置运行编辑器（字段类型 `beforeLaunch`，候选配置和任务种类都由 Core 给出）和构建提供者运行编辑器都在“运行/调试配置”窗口右侧（#2100），都可以添加、编辑、上移、下移、移除步骤。
- “添加任务”按钮始终可用。没有可选配置时，“运行另一个配置”子菜单里显示原因，而不是把整个按钮禁用；空列表显示“启动前没有要运行的任务”。
- 列表改动和其他字段一样算作未保存的修改：内置运行表单经 `runConfigFormEdited` 标脏，构建提供者编辑器把列表纳入 `fingerprint`，并且只有列表改动时才发送 `beforeLaunch`，不会把解析后的列表抄进本地层。“应用”“确定”“运行”会一并保存。

正确做法：插件要提供“运行 Go 命令”，就在清单的构建系统下声明一个 `beforeLaunchTasks` 项和它的字段、参数模板。

不要这样做：在宿主里判断插件 ID 或构建系统 ID，给 Go 项目单独加一个菜单项；或者在 `beforeLaunch` 里内联一段命令字符串。

## 考虑过的备选方案

- **宿主内置 IDEA 的任务类型**（Build、Run Maven Goal、Launch Web Browser 等）。否决：这些都依赖具体工具，内置进宿主就要按工具写分支，违反“插件专属逻辑不进宿主”。改为插件声明任务，宿主只提供通用菜单和表单。
- **用插件的 `runOptions` 扩展点追加启动前行为**（#2100 曾预留）。否决：`runOptions` 是给配置本身加选项，表达不了“启动前单独运行一个进程、单独出错、单独确认”，也没有自己的字段表单。API-29 的任务有独立的声明、校验和命令计划。
- **在 `beforeLaunch` 里内联命令**。否决：内联命令无法单独编辑和单独运行，也绕过了 Core 对命令定义的统一处理和指纹计算。
- **步骤并行运行**。依赖顺序是用户最常见的需求，并行会让失败原因和输出交错，先保持顺序执行。
- **每次运行都询问项目文件里的步骤**。会打断正常工作流，用户很快就会习惯性点确认；按指纹记住一次、内容改变时再问，兼顾安全和效率。

## 后果

- 用户可以在一个配置里串起准备命令和插件任务，一键运行。
- 打开不信任的仓库时，第一次运行会看到将要执行的步骤列表。
- 插件被禁用或卸载后，引用它任务的步骤仍然在列表里显示并保留，但运行时被拒绝（`taskNotDeclared`），用户能看到原因并自行移除。
- 以后新增步骤类型时，要在 Core 的 `before_launch.rs` 加类型并纳入指纹，在宿主 `runBeforeLaunchStep` 加执行方式；确认框必须能展示新类型会做什么。只是新增一种任务时，不需要改 Core 或宿主，在插件清单里声明即可。

## 验证

- Core：`cargo test -p lithe-core before_launch`（`core/src/tests/before_launch_steps.rs` 覆盖展开、确认指纹、拒绝原因、编辑校验和本地层清空；`core/src/tests/before_launch_tasks.rs` 覆盖任务种类列出、值校验、保存和命令计划）。
- 宿主：`./scripts/desktop/desktop-go.sh test ./internal/workbench/ -run 'BeforeLaunch|TestRunConfigFormKeepsTheStepList|TestRunConfigDialogSavesAnAddedStep|TestRunConfigEditorSavesTheLocalLayer' -count=1`，用真实 Core 和系统 shell/cmd 运行步骤，覆盖顺序、确认与记忆、改动后重新确认、取消、失败退出码和停止，以及在“运行/调试配置”窗口里添加的步骤算作修改并由“应用”保存。其中 `TestPluginDeclaredBeforeLaunchTaskIsAddedAndRunsFirst` 用测试插件覆盖插件任务的整条路径：菜单按中文名列出任务、任务表单显示插件翻译、空的必填值留在表单里、确定后加入列表、确认后任务先于配置运行、保存进插件的运行文档。
- 截图：`LITHE_VISUAL_OUTPUT_DIR=<目录> ./scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench/ -run 'TestVisualBeforeLaunchSteps|TestVisualPluginDeclaredRuns' -count=1`，其中 `declared-run-before-launch-menu-*.png` 和 `declared-run-task-form-*.png` 是“添加新任务”菜单和任务表单。

## 适用范围

- `desktop/internal/workbench/runconfig_steps.go`
- `desktop/internal/workbench/runconfig_before_launch.go`
- `desktop/internal/workbench/runconfig.go`
- `desktop/internal/workbench/runconfig_process.go`
- `desktop/internal/workbench/runconfig_form.go`
- `desktop/internal/workbench/runconfig_form_view.go`
- `desktop/internal/workbench/runconfig_edit.go`
- `desktop/internal/workbench/runconfig_view.go`
- `desktop/internal/workbench/runconfig_dialog.go`
- `desktop/internal/core/run_before_launch.go`
- Core：`rust/crates/execution/src/configuration/before_launch.rs`、`rust/crates/execution/src/configuration/declared.rs`
