# Agent 笔记：脚本与程序运行由 Core 内置，运行配置存 YAML（内置）和 TOML（插件）

状态：已实现

## 先说结论

Shell 脚本、PowerShell 脚本、cmd 批处理（只能在 Windows 上运行）和可执行程序四种运行由 Core 自己提供，叫“内置运行”（provider 为 `process.*`）。它们的表单、校验和启动计划都在 Core，宿主只负责画表单、写文件和起进程，不经过任何构建插件，所以 Java 等插件缺失或出错时这四种运行照常可用。

运行配置在 IDEA 式的“运行/调试配置”对话框里新建和编辑：左侧是按类型分组的配置树，右侧是选中配置的编辑器，几处改动在“应用”或“确定”时一起保存。

用户保存的运行配置换成两种格式：内置运行存 `.lithe/run/configurations.yaml`（团队共享）和 `.lithe/run/local.yaml`（本机）；插件提供的运行按插件拆成 `.lithe/run/plugin/<插件 ID>.toml` 和 `<插件 ID>.local.toml`，文件头记录插件的作者、仓库和版本要求。Core 只计算文件改动，不写文件，宿主按哈希检查后一次性应用。

## 问题

- 运行平台自带的脚本和程序本来就不需要生态知识，却要装插件才能出现在 Run 列表里；插件坏了，连最基本的“跑一下脚本”都做不到（Issue #2100）。
- 旧的 `.lithe/run/configurations.json` 把所有提供者的配置混在一份 JSON 里。用户想把运行配置提交进仓库时，JSON 不便手改、合并冲突难读；插件的配置也看不出依赖哪个插件、哪个版本。
- 同名插件可能来自不同作者。配置只记插件 ID 时，换了来源的插件会悄悄接手旧配置。
- 以后表单上一定会多出按钮和参数框。如果字段写死在宿主里，每加一个字段都要同时改 Core、macOS 和 Windows。

## 决策

### 四种内置运行属于 Core

`process.shell`、`process.powershell`、`process.batch`、`process.executable` 的运行类型列表（`runConfig.configurationTypes`）、表单（`runConfig.editorForm`）、保存校验（`runConfig.saveConfiguration`）和启动计划（`runConfig.createLaunchPlan`）都在 Core 的 `execution/src/configuration/process.rs` 与 `form.rs`。默认解释器由 Core 决定：Shell 取脚本首行的 `#!`，没有时用 `/bin/sh`；PowerShell 用 `pwsh`（Windows 上 `powershell`）并默认带 `-ExecutionPolicy Bypass`，用户可以取消。

四种类型在所有平台都列出，都能新建、编辑和保存。本机不能运行的类型（目前只有 Windows 以外的 `process.batch`）带 `availability`，code 为 `unsupportedPlatform`：`runConfig.configurationTypes` 的类型项、`runConfig.editorForm` 的表单和 `resolve` 列出的每条配置都带，`runConfig.createLaunchPlan` 拒绝启动。这样和 Windows 同事共享的项目在 macOS、Linux 上打开时，批处理配置不会消失，也能照常修改。

宿主按 `availability` 提示，不自己判断平台：对话框的“+”菜单和空白页在类型旁注明“仅 Windows”；编辑器顶部显示原因；配置树和标题栏下拉的这一行带警告图标（下拉里仍可选中，注明“仅 Windows”）；对话框的“运行”和标题栏的运行按钮置灰；按下标题栏运行时只提示原因，不启动。

宿主（`desktop/internal/workbench/runconfig_process.go`）拿到启动计划后只做三件事：在 PATH 里找可执行文件，把“脚本文本”写到系统临时目录里的 `lithe-run-script-*` 目录、进程退出后删除，然后用 `buildprocess` 起进程，输出进 Run 窗口。宿主不判断脚本类型，也不拼解释器参数。

只内置平台本身就有的东西。Python、Node、Make 这类需要识别生态或工具链的运行，交给插件声明（见[运行配置的生成层只来自插件声明](2026-10-29-run-configuration-detection-in-memory.md)）。

### 内置运行不依赖插件和构建模型

列出、新建、编辑和启动内置运行时，不需要构建模型或生成层，也不需要插件宿主。还没加载构建模型的项目，`resolve` 照样返回内置运行；插件宿主不可用时，标题栏和构建窗口仍然列出并运行它们。插件配置文件写坏时，只把那一份文件标为“未读取”（诊断带 `path`，标题栏下拉列出该文件，点一下在编辑器中打开），其余配置照常读取。

### 两种文件格式各管一层

| 文件 | 谁写 | 内容 |
| --- | --- | --- |
| `.lithe/run/configurations.yaml` | 用户勾选“存为项目文件” | 团队共享的内置配置 |
| `.lithe/run/local.yaml` | 默认 | 本机的内置配置、选项和工具偏好 |
| `.lithe/run/plugin/<插件 ID>.toml` | 插件运行存为项目文件 | 团队共享的插件配置 |
| `.lithe/run/plugin/<插件 ID>.local.toml` | 插件运行默认 | 本机的插件配置 |

插件 TOML 的 `[plugin]` 头记录 `id`、`name`、`author`、`repository`、`version`、`versionRequirement`（默认“`>=` 保存时的版本”）、`pluginAPIVersion` 和 `capabilities`。作者和仓库取自插件清单新增的可选字段 `repository`（`https://github.com/<作者>/<仓库>`）。插件没装、仓库不一致或版本不满足时，这些配置标为不可用并说明原因，不删除也不改写。

旧 JSON 只在对应的 YAML 不存在时读取。第一次编辑某一层时，Core 返回“写 YAML、删 JSON”两项改动。

### Core 计算改动，宿主应用改动

所有编辑命令都返回 `changes: [{path, baseSha256, content}]`，Core 自己不写文件。宿主的 `applyRunConfigChanges`（`desktop/internal/workbench/runconfig_changes.go`）只接受 `.lithe/` 下的路径。它先确认每个文件仍是 Core 计算时的字节，有一个不符就整体放弃并报冲突；写入先于删除，所以新 YAML 落盘后才删旧 JSON。中途失败时，它只还原自己改过、并且之后没被别人改动的文件。

### 表单字段由 Core 描述，宿主按类型画

`runConfig.editorForm` 返回字段列表（类型、是否必填、位置、自动值、可选项、`visibleWhen` 条件、说明）和当前值，`formVersion` 为 1。宿主（`runconfig_form.go`、`runconfig_form_view.go`）只画同时满足两个条件的字段：类型是它认识的，`shared/i18n` 里有这个字段 ID 的标题。其余字段跳过不画，值原样回传。Core 返回的 `formVersion` 比宿主新时，宿主不打开表单，提示升级。

### 在“运行/调试配置”对话框里新建和编辑

对话框参照 IDEA 的同名窗口（`runconfig_dialog.go`、`runconfig_dialog_view.go`），在应用窗口内以模态层显示，不开系统窗口。入口有三个：标题栏运行下拉的“新建运行配置…”和“编辑运行配置…”，以及构建窗口配置列表表头的“+”。列表里的编辑按钮也打开它，并选中那一条。

- 左侧工具栏是“+”（按类型新建）、“−”（删除）和复制。配置树按类型分组，分组可以折叠，折叠状态在再次打开时保留。
- 每条被选中过的配置都有自己的草稿。新建、修改和删除都先记在草稿里：“应用”先删除，再按配置树的顺序保存有改动的草稿，完成后留在对话框；“确定”保存后关闭；“取消”丢弃全部改动；“运行”保存后关闭，并运行选中的配置。
- 新建的配置第一次保存后换成 Core 给的 `user:` ID；只有 `user:` 配置能删除。第一处失败就停下，选中出错的那条配置并在它的编辑器里显示原因，对话框不关闭；失败前已保存的部分照常生效。
- 构建插件提供的运行也在这个对话框里编辑，用的是 `runconfig_edit.go` 的编辑器；内置运行用 Core 描述的表单。

### 从界面按下运行时打开 Run 窗口

从编辑对话框的“运行”、构建窗口的配置列表（按钮或双击）和 Run 窗口的再次运行启动时，都走 `runConfiguration`（`runconfig.go`）。它启动后打开 Run 窗口，并选中这次运行的控制台；构建插件提供的运行从列表启动时也一样。经 IDE API（`startRunConfiguration`）启动的运行不改变窗口布局，因为调用方不一定是用户。

### 正确做法

- 给 Shell 表单加一个参数框：在 Core 的 `form.rs` 描述字段、在 `process.rs` 解释它的值，再在 `shared/i18n/` 加标题词条。宿主已认识这种类型时，不用改任何宿主代码。
- 新增一种全新的字段类型：先在宿主实现它的绘制，再让 Core 开始返回它；旧宿主跳过新字段，配置照样能保存。
- 插件运行需要新的元数据：加进插件 TOML 的 `[plugin]` 头，由 Core 读写，宿主不解析 TOML。

### 不要这样做

- 不要在宿主里按扩展名判断脚本类型、补 `-ExecutionPolicy` 或拼 `cmd /c`。这些规则只在 Core，宿主重复一份就会和 Windows 端分叉。
- 不要在宿主或 Core 里直接写 `.lithe/run/` 下的文件，绕过 `changes` 和哈希检查会覆盖别人刚做的修改。
- 不要让内置运行等构建模型加载完、或等插件宿主就绪再出现，那正是这次要去掉的依赖。
- 不要把脚本文本写进项目目录或 app bundle。它是一次性的运行产物，只放系统临时目录。

## 考虑过的备选方案

### 把脚本和程序运行做成一个官方插件

和其他运行走同一条路，Core 不多一类提供者。没有采用：用户要求插件全坏时这几种运行也能用，放进插件就又依赖插件宿主、插件安装和插件版本。

### 在非 Windows 平台隐藏批处理

和平台能力一致，界面也更少。没有采用：项目里的批处理配置常由 Windows 同事提交，隐藏后 macOS、Linux 用户既看不到也改不了它们（Core 之前保留文本、只是不列出）。现在照常列出和编辑，只是不能运行。

### 标题栏用“新建运行配置 >”子菜单，每条配置单独弹编辑框

实现简单，点两下就能新建。没有采用：用户要求参照 IDEA，在一个窗口里同时看到全部配置、切换着编辑，改完一起应用；子菜单也放不下“仅 Windows”这类说明和以后更多的类型。

### 全部配置都用 YAML，或都用 TOML

一种格式更简单。没有采用：内置配置只有通用字段，YAML 适合手写和代码评审；插件配置要带一个“依赖哪个插件、哪个版本”的头，TOML 的 `[plugin]` 表把元数据和配置分得清楚。按插件拆文件后，卸载插件或插件出错只影响一份文件。

### 插件配置只记插件 ID

字段少，也不用改插件清单。没有采用：插件 ID 防不了不同作者用同一个名字。作者和仓库让 Core 能发现“已安装的插件不是保存配置时那一个”，并把配置标为不可用，而不是交给另一个插件运行。

### 表单字段写死在宿主

宿主可以完全控制布局。没有采用：每加一个字段都要同时改 Core 和两个桌面端，还要在宿主里重复 Core 的校验规则；以后 Windows 端还得再写一遍。

### 迁移时立即把所有旧 JSON 转成 YAML

一次转完，代码里不用再读 JSON。没有采用：打开项目就改写用户文件，会在版本控制里产生用户没做过的改动。现在只在用户真正编辑某一层时才转换。代价是旧客户端读不到被转换的那一层。

## 后果

- 收益：不装插件也能运行脚本和程序；运行配置可以按团队和本机分开提交；插件配置能说明自己依赖哪个插件；以后加字段时，通常只需改 Core 和词条。
- 代价：多了一种文件格式和一套插件元数据要维护；脚本文本运行要在临时目录写文件，进程崩溃时留下的目录由系统清理；旧 macOS 客户端读不到 Viva 已转换的那一层配置。
- Windows 上裸写的 `bash` 可能解析到 WSL 的启动器，需要 Git Bash 时要在解释器路径里填完整路径。批处理的 `commandLine` 只按 cmd 的规则加引号，不转义 `%`。
- 需要重新评估：Windows 或 Linux 实机验收发现的解释器或引号问题；插件需要在 TOML 里放自定义字段时；`formVersion` 需要升到 2 时。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/buildprocess/... ./internal/workbench/...`：`runconfig_process_test.go` 用系统 shell 真实运行脚本，并断言 Run 窗口打开、输出进入控制台；`runconfig_dialog_test.go` 覆盖对话框的应用、取消、删除、复制、分组折叠，以及批处理在非 Windows 上能编辑、能保存、不能运行；`runconfig_browser_test.go`、`title_run_test.go`、`runconfig_edit_test.go` 覆盖列表、标题栏和插件运行的编辑。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench -run '^(TestVisualBuiltInProcessRuns|TestVisualTitleRunWithoutConfigurations)$'`：设置 `LITHE_VISUAL_OUTPUT_DIR` 后生成 `docs/assets/builtin-process-runs/` 和 `docs/assets/run-config-empty/` 的截图。
- Core 仓库的 `cargo test -p lithe-execution -p lithe-core`：覆盖表单、校验、启动计划、YAML/TOML 读写、旧 JSON 和插件可用性。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认运行不写发行目录。

## 适用范围

- `desktop/internal/workbench/runconfig_process.go`
- `desktop/internal/workbench/runconfig_changes.go`
- `desktop/internal/workbench/runconfig_form.go`
- `desktop/internal/workbench/runconfig_form_view.go`
- `desktop/internal/workbench/runconfig_dialog.go`
- `desktop/internal/workbench/runconfig_dialog_view.go`
- `desktop/internal/workbench/title_run_view.go`
- `desktop/internal/workbench/runconfig.go`
- `desktop/internal/core/run_process.go`
- `desktop/internal/buildprocess/`
- Core 仓库的内置运行与文件格式：[process.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/process.rs)、[storage.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/storage.rs)、[plugin_document.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/plugin_document.rs)
