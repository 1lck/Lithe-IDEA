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

### 解释器路径从终端检测到的 shell 里选

Shell、PowerShell 和批处理表单的解释器字段（`kind: executable`）带 `shellFamily`，值是 `posix`、`powershell` 或 `cmd`，由 Core 的 `Kind::shell_family`（`process.rs`）给出；二进制程序的 `program` 字段不带。哪种运行用哪类 shell 是运行规则，放在 Core。本机装了哪些 shell、某个程序属于哪类，是平台层的事：宿主复用终端“新建终端”菜单的查找（`localshell.InstalledShells`）和分类（`shellkind.FromProgram`）。

宿主（`runconfig_shell_view.go`）把带 `shellFamily` 的字段画成和工具链设置一样的下拉：

- “自动（实际生效值）”：字段为空，Core 按自动值运行；
- 同类的已安装 shell，显示名字和路径，选中后字段写入该路径；WSL 发行版的登录 shell 没有能直接启动的程序路径，不列出；
- 字段里已有、但不在列表中的值，原样显示；
- “自定义…”：下面出现输入框和浏览按钮，可以填命令名（按 PATH 查找）或路径；改选其他项之前一直显示。

表单第一次画出时，宿主在后台重新查找一次 shell，所以刚装的 shell 也能列出；查找结束前，列表里只有自动、当前值和自定义。保存的值仍是命令名或路径，YAML、校验和启动计划都不变。宿主不认识的 `shellFamily` 按普通程序字段画。

### 在“运行/调试配置”对话框里新建和编辑

对话框参照 IDEA 的同名窗口（`runconfig_dialog.go`、`runconfig_dialog_view.go`），在应用窗口内以模态层显示，不开系统窗口。入口有三个：标题栏运行下拉的“新建运行配置…”和“编辑运行配置…”，以及构建窗口配置列表表头的“+”。列表里的编辑按钮也打开它，并选中那一条。

- 左侧工具栏依次是“+”（按类型新建）、“−”（删除）、复制、新建文件夹和“按字母顺序排序”开关。配置树按类型分组，类型下面先列文件夹，再列不在文件夹里的配置；分组和文件夹都可以折叠，折叠状态在再次打开时保留。
- 焦点在配置树上时，macOS 按 ⌫ 或 ⌦、其他平台按 Delete 删除选中的配置（选中文件夹时解散文件夹），和“−”一样只记进草稿。macOS 按 ⌃N、其他平台按 Alt+Insert 打开新建菜单；这两个快捷键只挂在左侧一列上，右侧编辑器里的文本框照常用 ⌃N 换行。
- 没有配置时和 IDEA 一样：左侧写“未添加运行配置。”和链接“添加新… ⌃N”，右侧是链接“添加新的运行配置…”和“或选择要编辑的运行配置”，两个链接都打开类型菜单。有配置但没选中时，右侧也是这一页。
- 每条被选中过的配置都有自己的草稿。新建、修改、复制、删除、文件夹和顺序都先记在草稿里：“应用”依次保存有改动的草稿、复制品，再删除，最后保存文件夹和顺序，完成后留在对话框；“确定”保存后关闭；“取消”丢弃全部改动；“运行”保存后关闭，并运行选中的配置。
- 新建的配置第一次保存后换成 Core 给的 `user:` ID；只有 `user:` 配置能删除。第一处失败就停下，选中出错的那条配置并在它的编辑器里显示原因，对话框不关闭；失败前已保存的部分照常生效。
- 构建插件提供的运行也在这个对话框里编辑，用的是 `runconfig_edit.go` 的编辑器；内置运行用 Core 描述的表单。
- 树的行在 Viva 的 `ui.Tree` 里没有自己的标识，挂悬停提示会直接 panic，所以不可运行的行只带警告图标，原因写在行的无障碍标签和右侧编辑器顶部。

### 文件夹、顺序和复制

文件夹参照 IDEA 的 `folderName`，存在配置本身的 `folder` 字段里：项目层的配置写进 `configurations.yaml`，跟团队共享；本机配置和插件生成的配置写进 `local.yaml`（生成的配置只写一条 `{id, folder}` 覆盖）。文件夹只属于一个类型，没有单独的文件夹列表：一个文件夹里的配置都移走或删掉以后，文件夹就没了；刚建的空文件夹只在对话框打开期间存在。

列表的顺序和“按字母排序”是这台机器上的选择，只存在 `local.yaml` 的 `arrangement` 里（`sortAlphabetically`、`order`），不进项目文件，避免团队成员互相改写。默认按名称排序（忽略大小写）。关掉排序后才能把配置拖到别的位置；重新打开排序时，保存的手动顺序保留，下次关掉还能恢复。`order` 里不再存在的 ID 跳过，没列进去的配置按名称排在后面。`runConfig.resolve` 按这个顺序返回配置，并带回 `sortAlphabetically`，所以标题栏下拉、构建窗口和对话框的顺序一致。这些规则都在 Core 的 `execution/src/configuration/arrangement.rs`，宿主用 `runConfig.arrange` 提交 `{folders, order, sortAlphabetically}`，拿回的仍是 `changes`。

复制分两种：

- 内置运行按表单当前显示的值复制，新草稿名为“<原名>（副本）”、留在原来的文件夹，保存位置跟着表单里的“存为项目文件”。
- 其他配置（包括构建插件生成的运行）在“应用”时由 Core 的 `runConfig.copyConfiguration` 复制，保留原配置保存的全部选择。复制品是用户配置，生成的运行复制后存进 `.lithe/run/plugin/<插件 ID>.local.toml`，原来那条照常列出、不被遮住。保存前复制品的编辑器只提示“按应用或确定后生成副本”，不能运行，也不能再复制。

### 正确做法（文件夹与顺序）

- 新的排列方式（比如按类型以外的维度分组）先在 Core 的 `Arrangement` 里定义和存储，再让宿主画；宿主不自己排序或记顺序。
- 只要改了名字或新建了配置，而列表又是手动顺序，就把配置树当前显示的顺序一起保存，否则新 ID 会掉到列表末尾。

### 插件声明的运行类型

插件在清单的 `buildSystems[].runConfigurationTypes` 里为自己的构建系统声明运行类型（能力 `runConfigurationTypes` 0，对应 API-29），例如 Go 插件的 Go Build、Go Test。每个类型带标题、说明、图标、字段（`choice`、`checkbox`、`text` 等）和参数模板（`${field:<id>}`、`${userArguments}`），文字由插件包里的翻译文件翻译。契约、校验、表单、保存和启动计划都在 Core（provider 为 `build.run-type`），宿主（`runconfig_types.go`）只做三件事：

- 读类型：把已启用插件的清单交给 Core，Core 返回全部类型和每个插件该读哪几份翻译文件；宿主只从已安装的插件包里读这些文件（包目录只读），再问一次。翻译读不到时退回下一份或清单原文，类型照常列出。打开对话框时重新读一次，所以刚装、刚停用的插件和切换后的界面语言都能反映出来。
- 画表单：插件字段的标题、选项名、占位符和说明直接用 Core 返回的翻译后文字，字段 ID 为 `field:<id>`；宿主仍只画它认识的字段类型。插件声明的类型排在内置类型之后，每个类型在配置树里单独一组。图标用插件指定的宿主图标；指定包内图片的暂时显示执行方式的图标。
- 起进程：Core 的 `build.runConfigurationPlan` 按配置的工作目录选出检测到的构建系统实例并给出参数，宿主用该实例解析出的构建工具起进程，和构建任务一样走 `buildprocess`。

存为项目文件的配置写进 `.lithe/run/plugin/<插件 ID>.toml`，本机配置写进 `<插件 ID>.local.toml`，和插件生成的运行同一套规则。项目里没检测到这个构建系统时，配置照常列出、可以编辑，但不能运行（`refusalNotReady`，提示找不到目标）。插件声明的类型没有调试器，调试启动返回 `refusalNotSupported`。

### 允许多个实例

所有运行配置（内置的和插件声明的）都有“允许多个实例”勾选项，字段 ID `allowMultipleInstances`，由 Core 描述、保存。不勾选时，按下运行会先停掉正在运行的那一个再重新启动（原来的行为）；勾选后，新实例在旁边另开一个 Run 标签，已有的继续运行。调试只允许一个：同一配置已在运行时再按调试，返回 `errRunRunning`。

### 从界面按下运行时打开 Run 窗口

从编辑对话框的“运行”、构建窗口的配置列表（按钮或双击）和 Run 窗口的再次运行启动时，都走 `runConfiguration`（`runconfig.go`）。它启动后打开 Run 窗口，并选中这次运行的控制台；构建插件提供的运行从列表启动时也一样。经 IDE API（`startRunConfiguration`）启动的运行不改变窗口布局，因为调用方不一定是用户。

### 正确做法

- 给 Shell 表单加一个参数框：在 Core 的 `form.rs` 描述字段、在 `process.rs` 解释它的值，再在 `shared/i18n/` 加标题词条。宿主已认识这种类型时，不用改任何宿主代码。
- 新增一种全新的字段类型：先在宿主实现它的绘制，再让 Core 开始返回它；旧宿主跳过新字段，配置照样能保存。
- 插件运行需要新的元数据：加进插件 TOML 的 `[plugin]` 头，由 Core 读写，宿主不解析 TOML。
- 插件要一种新的运行方式（例如 Go Test）：在插件清单的 `runConfigurationTypes` 里声明，翻译放进插件包的 `l10n/`。宿主和 Core 都不按插件或工具名加分支。
- 别的字段也要从本机已安装的工具里选：在 Core 的字段上标一个属性（像 `shellFamily`），宿主按属性复用平台层已有的查找，不按字段 ID 或运行类型分支。

### 不要这样做

- 不要在宿主里按扩展名判断脚本类型、补 `-ExecutionPolicy` 或拼 `cmd /c`。这些规则只在 Core，宿主重复一份就会和 Windows 端分叉。
- 不要在宿主或 Core 里直接写 `.lithe/run/` 下的文件，绕过 `changes` 和哈希检查会覆盖别人刚做的修改。
- 不要让内置运行等构建模型加载完、或等插件宿主就绪再出现，那正是这次要去掉的依赖。
- 不要把脚本文本写进项目目录或 app bundle。它是一次性的运行产物，只放系统临时目录。
- 不要在宿主里按运行类型（`process.shell` 等）决定列出哪类 shell，只读 `shellFamily`。
- 不要在宿主里解析插件清单或拼插件运行的参数，也不要把插件字段的文字写进 `shared/i18n/`。标题和选项名来自插件的翻译，参数来自 Core 的计划。
- 不要从插件包目录推导可写位置：启动计划需要的状态目录是插件在本工作区的状态目录（`buildStateDirectory`），不在插件包里。
- 不要用 `ui.C.After` 推迟 shell 查找：表单第一次画出的那一帧通常没有点击，这种帧会丢掉推迟的回调，列表就一直是空的。查找本身在后台运行，直接在绘制时发起即可。

## 考虑过的备选方案

### 把脚本和程序运行做成一个官方插件

和其他运行走同一条路，Core 不多一类提供者。没有采用：用户要求插件全坏时这几种运行也能用，放进插件就又依赖插件宿主、插件安装和插件版本。

### 在非 Windows 平台隐藏批处理

和平台能力一致，界面也更少。没有采用：项目里的批处理配置常由 Windows 同事提交，隐藏后 macOS、Linux 用户既看不到也改不了它们（Core 之前保留文本、只是不列出）。现在照常列出和编辑，只是不能运行。

### 标题栏用“新建运行配置 >”子菜单，每条配置单独弹编辑框

实现简单，点两下就能新建。没有采用：用户要求参照 IDEA，在一个窗口里同时看到全部配置、切换着编辑，改完一起应用；子菜单也放不下“仅 Windows”这类说明和以后更多的类型。

### 文件夹单独存一份列表，或连顺序一起存进项目文件

单独的文件夹列表能保留空文件夹，顺序进项目文件能让全队看到同样的列表。没有采用：IDEA 把文件夹记在配置上，顺序记在 workspace 里，用户要的就是这种行为；文件夹列表和配置分开存，会出现指向已删除配置的文件夹。顺序是个人习惯，放进项目文件后，每个人拖一下都会在版本控制里产生冲突。

### 复制插件生成的运行时只复制表单值

和内置运行的复制走同一条路。没有采用：插件运行没有 Core 描述的表单，宿主只拿得到界面上显示的部分，会丢掉插件保存的目标、执行方式等不透明字段。交给 Core 复制，才能保留全部选择，并按插件拆分的 TOML 规则落盘。

### 全部配置都用 YAML，或都用 TOML

一种格式更简单。没有采用：内置配置只有通用字段，YAML 适合手写和代码评审；插件配置要带一个“依赖哪个插件、哪个版本”的头，TOML 的 `[plugin]` 表把元数据和配置分得清楚。按插件拆文件后，卸载插件或插件出错只影响一份文件。

### 插件配置只记插件 ID

字段少，也不用改插件清单。没有采用：插件 ID 防不了不同作者用同一个名字。作者和仓库让 Core 能发现“已安装的插件不是保存配置时那一个”，并把配置标为不可用，而不是交给另一个插件运行。

### 表单字段写死在宿主

宿主可以完全控制布局。没有采用：每加一个字段都要同时改 Core 和两个桌面端，还要在宿主里重复 Core 的校验规则；以后 Windows 端还得再写一遍。

### Go 插件之类的运行类型由宿主内置

宿主可以直接画 Go Build、Go Test 的表单，不用多一份契约。没有采用：用户要求插件自己用 API 注入运行方式；宿主内置就得按工具名加分支，Core 对具体语言和工具也不再零依赖。

### 多实例只在运行开始时临时决定（例如按住修饰键）

不用多存一个字段。没有采用：IDEA 把它做成每个配置的选项，团队共享的配置（例如同时起两个服务实例）需要记住这个选择；临时修饰键也没法通过 IDE API 表达。

### 迁移时立即把所有旧 JSON 转成 YAML

一次转完，代码里不用再读 JSON。没有采用：打开项目就改写用户文件，会在版本控制里产生用户没做过的改动。现在只在用户真正编辑某一层时才转换。代价是旧客户端读不到被转换的那一层。

## 后果

- 收益：不装插件也能运行脚本和程序；运行配置可以按团队和本机分开提交；插件配置能说明自己依赖哪个插件；以后加字段时，通常只需改 Core 和词条。
- 代价：多了一种文件格式和一套插件元数据要维护；脚本文本运行要在临时目录写文件，进程崩溃时留下的目录由系统清理；旧 macOS 客户端读不到 Viva 已转换的那一层配置。
- Windows 上裸写的 `bash` 可能解析到 WSL 的启动器，需要 Git Bash 时从解释器下拉选终端检测到的 Git Bash，或在“自定义…”里填完整路径。批处理的 `commandLine` 只按 cmd 的规则加引号，不转义 `%`。
- 需要重新评估：Windows 或 Linux 实机验收发现的解释器或引号问题；插件需要在 TOML 里放自定义字段时；`formVersion` 需要升到 2 时。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/buildprocess/... ./internal/workbench/...`：`runconfig_process_test.go` 用系统 shell 真实运行脚本，并断言 Run 窗口打开、输出进入控制台；`runconfig_dialog_test.go` 覆盖对话框的应用、取消、删除（含 ⌫/Delete 键）、复制（含插件运行复制进 `<插件 ID>.local.toml`）、文件夹的新建、重命名和解散、手动顺序与排序开关、IDEA 式空白页和 ⌃N/Alt+Insert、分组折叠，以及批处理在非 Windows 上能编辑、能保存、不能运行；`runconfig_shell_test.go` 覆盖解释器下拉只列同类 shell、选中 shell 写入路径、“自定义…”输入、改回自动和保存；`runconfig_browser_test.go`、`title_run_test.go`、`runconfig_edit_test.go` 覆盖列表、标题栏和插件运行的编辑。
- `runconfig_types_test.go` 用合成插件 `dev.lithe.test.run-types`（带中文翻译）覆盖插件声明类型：翻译后的标题、字段和选项名，新建、保存到 `.lithe/run/plugin/<插件 ID>.toml`、运行并检查实际参数，调试被拒；勾选“允许多个实例”后同时运行两个实例；没检测到构建系统时配置列出但不能运行。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench -run '^(TestVisualBuiltInProcessRuns|TestVisualTitleRunWithoutConfigurations|TestVisualPluginDeclaredRuns)$'`：设置 `LITHE_VISUAL_OUTPUT_DIR` 后生成 `docs/assets/builtin-process-runs/`、`docs/assets/run-config-empty/` 和 `docs/assets/plugin-declared-runs/` 的截图。
- Core 仓库的 `cargo test -p lithe-execution -p lithe-core`：覆盖表单、校验、启动计划、YAML/TOML 读写、旧 JSON、插件可用性，以及 `run_configuration_arrangement.rs` 里文件夹写入哪一层、顺序只进本机、复制保留全部选择。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认运行不写发行目录。

## 适用范围

- `desktop/internal/workbench/runconfig_process.go`
- `desktop/internal/workbench/runconfig_changes.go`
- `desktop/internal/workbench/runconfig_form.go`
- `desktop/internal/workbench/runconfig_form_view.go`
- `desktop/internal/workbench/runconfig_shell_view.go`
- `desktop/internal/workbench/runconfig_types.go`
- `desktop/internal/workbench/runconfig_dialog.go`
- `desktop/internal/workbench/runconfig_dialog_view.go`
- `desktop/internal/workbench/title_run_view.go`
- `desktop/internal/workbench/runconfig.go`
- `desktop/internal/core/run_process.go`
- `desktop/internal/buildprocess/`
- Core 仓库的内置运行与文件格式：[process.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/process.rs)、[storage.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/storage.rs)、[plugin_document.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/plugin_document.rs)、[arrangement.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/arrangement.rs)
