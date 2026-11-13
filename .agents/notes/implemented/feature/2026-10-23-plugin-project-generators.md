# Agent 笔记：插件注入的新建项目向导

状态：已实现

## 先说结论

「New Project」原来只是选一个文件夹再打开。现在它是参照 IDEA 的新建项目窗口：左栏分「新建项目」和「生成器」两组，右侧是所选条目的表单。窗口外框、名称、位置、「创建 Git 仓库」和「空项目」归宿主；其余条目由插件声明的**项目生成器**（Project Generator，插件声明的一种新建项目方式）注入。

契约上**没有升 `pluginAPIVersion`**，只在级别 3 新增能力 `projectGenerators: 1`。Java、Maven Archetype、Spring Boot 三个生成器**直接声明在 Java Support 里**，不另设模板插件：模板属于对应语言插件，用户不用多管一个插件。Java Support 停用时条目照样列出、变灰，并提示「启用」。

界面复用 #1395 设置窗口的原生 SwiftUI 组件。为此把设置侧栏行、插件字段控件和文件夹选择器抽成了共享组件，设置窗口和克隆仓库窗口改用它们。

后来（计划 API-33）新增 `projectGenerators: 2`，字段多了一种**工具字段**（`type: "tool"`）：生成器只写一个工具定义 ID 和最低版本，宿主用已有的工具解析列出本机安装，用户的选择写进新项目的工具 pin（项目自己记住“用哪个安装”的那份设置）。这样 Python、Node、JDK 等任何工具都能被生成器选择，宿主和 Core 里不出现任何语言名。版本 1 的 `runtime`（只能选 Java）保持原样，等 Java 逻辑迁出宿主后再移除。

## 问题

- **入口什么都没做。** 欢迎页和项目切换器的「New Project…」调用 `chooseProject(title: "New Project")`，与「打开」只差一个标题。
- **生态知识没有地方放。** Cargo、Spring Initializr、Maven Archetype 各有自己的脚手架。写进宿主会违反「宿主不按插件名分支」；写进 Core 会重演 `execution/detectors/` 写死生态表的问题。
- **基础环境要重复配置。** 建完 Java 项目后还得去设置里再选一次 JDK。
- **能力版本的副作用。** [按能力分版本](../architecture/2026-11-11-plugin-contract-single-baseline.md)要求 `requires` 恰好列出用到的能力，宿主缺任何一项就整个插件不可装。生成器放进语言插件后，不支持生成器的宿主连这一版语言支持一起看不到。Java Support 只在 macOS 分发、随同版本的 Lithe.app 内置，所以影响的只是「旧宿主拿不到新版 Java Support」；社区语言插件加生成器前要权衡这一点。

## 决策

### 1. 谁负责什么

| 部分 | 负责方 | 落点 |
| --- | --- | --- |
| 声明的校验、表单求值（派生默认值、显示条件、错误码）、生成计划、压缩包解压 | Rust Core | `rust/crates/project-generators/src/`，命令 `project.*` |
| 契约与标准答案 | 共享契约 | `Lithe-core-rust/shared/plugins/contract/v1/README.md` 的 Project generators 一节，`fixtures/project-generators/project-generator.plugin.json`、`fixtures/project-generators/project-plans.json` |
| 窗口、名称、位置、Git、空项目、启用插件提示 | macOS 宿主 | `NewProjectView`、`NewProjectFeatureModel` |
| 执行计划：临时目录、写文件、跑命令、下载、移动到位 | macOS 宿主 | `ProjectGenerationService`（编排）+ `MacProjectGenerationPlatform`（平台操作） |
| Java、Maven Archetype、Spring Boot 的字段、模板和步骤 | 插件 | 组织插件仓库 `Lithe-IDEA/lithe-plugin-java`（`java`、`spring-boot`）与 `Lithe-IDEA/lithe-plugin-maven`（Maven Archetype），各自 `plugin.json` 的 `projectGenerators`、`icons/`、`templates/`；2026-11 起本仓库不再内置任何插件（#1495） |

宿主里没有任何生成器 ID 分支。项目打开后由已有的 `build.detect` 按 markers 识别 Maven、Gradle，生成器不声明「按什么导入」。

### 2. 清单：`projectGenerators` 1

每个生成器只声明：展示（`displayName`、`section`、`icon`、`order`）、字段（`fields`）、需要的语言或构建系统（`requirements`）、步骤（`steps`）、创建后打开的文件（`openFiles`）。字段类型沿用插件设置的命名（`text`、`enum`、`boolean`、`multiSelect`），另加 `runtime`（宿主发现的 JDK）。字段只能读在它之前声明的字段，所以默认值一次求完，显示条件不会成环。跨字段的版本约束也按这个顺序声明：`text`、`enum` 字段的 `maximumVersion` 是读取前面字段的模板，Spring Boot 的目标 Java 写 `${field.jdk.major}`，Core 在表单和计划阶段都拒绝高于所选 JDK 的组合（`versionTooHigh`），宿主不用为生成器写分支。

步骤三种，按顺序在临时目录里执行：

- `files`：复制包内模板目录。
- `command`：调用脚手架（例如 `mvn archetype:generate`），可用 `collect` 把工具生成的子目录内容上移到项目根。
- `archive`：拼 HTTPS 地址下载 zip 并解压（Spring Initializr）。

需要 `project.generate` 权限；`command` 必须写 `mayUseNetwork`，`archive` 一律算联网。每条 `command` 步骤整体（命令、参数模板、环境、`when`、`collect`、超时、联网标记）是安装确认里的一条 `projectGenerator` 程序；插件更新新增命令或改了其中任何一项，都会作为新程序要求用户重新确认。`files` 和 `archive` 不启动进程，由权限覆盖。

### 3. 模板语法

清单字符串用 `${…}`，与其他插件模板一致。**模板文件用 `{{ … }}`**，因为 POM、Gradle 脚本、properties 本身就含 `${project.version}` 这类文本，必须原样进入项目。文件里只有 `{{` 后紧跟 `project.` 或 `field.` 才算变量。

修饰符 `path`、`package`、`lower` 用 `|` 串接，例如 `${field.groupId|package|path}`。路径段以 `dot-` 开头会变成点文件（`dot-gitignore` → `.gitignore`），因为插件包扫描会跳过隐藏文件。

**带变量的路径写在步骤的 `target` 里，不要写进模板文件名**：仓库要在 Windows 上检出，文件名里的 `|` 在 Windows 上非法。

### 4. 生成过程

1. Core 用 `project.generationPlan` 校验表单，展开所有文件、argv 和 URL。
2. 宿主在目标父目录下建 `.<name>.lithe-creating-<随机>` 临时目录，按步骤执行。压缩包由 Core 的 `project.extractArchive` 解压：拒绝目录外路径、符号链接、覆盖已有文件，并限制实际写出的字节数。
3. 全部成功才原子移动到最终位置；目标已存在就拒绝。失败或取消时删除临时目录。
4. 所选 JDK（版本 1 的 `runtime` 字段）通过 `ProjectRuntimeService.presetJavaHome` 写成新项目的 JDK；声明了 `pinAs` 的工具字段按计划里的 `toolPins` 写成新项目的工具 pin（见下文第 7 节）；勾选 Git 时用 `git.initialize` 建仓库；`openFiles` 写进新项目的工作区会话，项目在哪个窗口打开都会恢复这些标签。

压缩包边下载边计数，超过 256 MiB 立即取消，不先占满磁盘；服务器拒绝请求时最多读 64 KiB 的错误说明。

插件包、app bundle 只读；写入只发生在用户选的目录和一个临时下载文件里，不影响代码签名和 Sparkle delta。

### 5. 启用状态与插件提示

- macOS 的插件启用状态来自它的模块。只有生成器的插件原本没有模块，会永远显示为停用。所以描述符为生成器合成一个 `ModuleID.projectGeneratorsExtension(pluginID)` 模块：应用级、不启动任何东西，只控制条目是否可用。
- `project.generatorCatalog` 接收全部已安装插件和启用状态，为每个 requirement 列出提供它的插件。宿主据此提示：有提供者但已停用，显示「启用」；没有提供者，显示「在插件市场中查找」。requirement 从不阻止创建。
- 生成器自己的插件停用时，条目照样列出但变灰，必须先启用才能创建。
- requirement 的提供者就是生成器自己的插件时（Java Support 的 Java 模板需要 Java 语言），不再单独提示：上一条的「启用」已经覆盖它，避免同一个插件出现两次。

### 6. 界面复用

| 共享组件 | 来源 | 使用方 |
| --- | --- | --- |
| `LitheSidebarRow`、`LitheSidebarHeading` | 设置窗口侧栏 | 设置窗口、新建项目 |
| `PluginMultiSelectField`（支持分组标题）、`PluginTextSettingField`、`PluginFieldOption` | `PluginSettingsSection` 的私有控件 | 插件设置、新建项目 |
| `LitheDirectoryPicker` | 克隆仓库窗口 | 克隆仓库、新建项目 |
| `LitheSettingsSelect`、`LitheSettingsSegmentedControl`、`LitheSettingsCheckbox`、`LitheInfoTip` | 原本就共享 | 新建项目 |

左栏固定宽度，不用每帧 `GeometryReader`，符合[可调整面板性能边界](../architecture/2026-09-13-resizable-ui-performance-boundaries.md)。插件提供的标题和说明走 `LocalizedStringKey`，与插件设置一样可以在宿主的 `Localizable.strings` 里翻译。

### 7. 工具字段（`projectGenerators` 2）

字段写法：`{"id": "sdk", "type": "tool", "tool": "python", "minimumVersion": "3.11", "pinAs": "project"}`。`tool` 是工具定义 ID（已验证的官方定义用短 ID，其余是 `<插件 id>:<定义 id>`），没有封闭列表；没人声明的工具就是没有安装可选。

谁做什么：

| 部分 | 负责方 | 做什么 |
| --- | --- | --- |
| 字段校验、默认选择、版本比较、`${field.<id>}` 与 `${field.<id>.executable}` 展开、`toolPins` | Rust Core | 在已有的 `project.generatorForm` 和 `project.generationPlan` 里；选择规则：用户的选择还在候选里就保留，否则取版本最新的，同版本保持宿主给的顺序；没有候选报 `required`（可选字段除外），低于 `minimumVersion` 报 `toolTooOld`。版本按“发行号”比较，末尾的 0 不算（`3.11`、`3.11.0`、`3.11.0.0` 相同），和工具链解析一致。可选字段没有够新的候选时保持为空、不写 pin，和“完全没装”一样，机器上有旧版本不会反而挡住创建；用户明确选了旧版本仍报 `toolTooOld` |
| 列出候选安装 | macOS 宿主（I/O） | `MacProjectToolInstallations` 复用设置页的工具发现；新建项目没有工作区，所以在一个空的临时目录里发现，用完删除。临时目录建不出来时记日志并抛错，窗口显示“无法查找已安装的工具”和“重试”，而不是“没有安装”；删不掉只记日志，列出的结果照常使用 |
| 保存 pin | macOS 宿主（I/O） | `MacProjectToolPins` 通过设置页同一个 `ToolchainPreferencesStoring` 写 `.lithe/run/local.json`，不新增存储 |
| 找不到工具时的提示 | Core 给出提供它的插件，宿主按已有方式显示 | 有定义但插件停用显示“启用”，没有定义显示“在插件市场中查找” |

宿主不判断“这是哪种语言”，也不判断版本够不够：它把发现的安装交给 Core，按 Core 返回的 `installations[].meetsMinimum` 画下拉：太旧的仍然列出（让用户看到为什么没用它），但灰掉且不能选；Core 把可选字段留空时，下拉第一项显示“无”。

pin 写失败不会让项目创建失败：项目已经生成并移动到位，回滚没有意义。创建结果带一个 `toolPinWarning`，窗口提示“项目已创建，但无法保存你选择的工具”，用户可以到设置的工具页再选一次。

**热激活。** 只含生成器、或只含工具定义的插件原来要重启才生效。生成器清单和工具定义都是宿主每次用到时才读的数据，所以它们加入了 `canActivateWithoutRestart`（见[插件热激活](../architecture/2026-10-26-plugin-live-activation.md)）。新建项目窗口监听插件变化，自动重新列出条目和工具候选；窗口打开时安装工具定义插件，下拉随即多出新的安装。插件变化会丢掉所有条目已列出的工具候选，不只是当前条目的：之后切到别的条目会重新查找，不会沿用已停用定义找到的安装；工具重新列出之前“创建”不可用。含语言服务器、构建、界面等其他贡献的插件（例如 Java Support）仍然要重启。

#### 正确做法

- Python 生成器想让用户选解释器：写 `{"type": "tool", "tool": "python", "minimumVersion": "3.11", "pinAs": "project"}`，步骤里用 `${field.sdk.executable}` 调 `venv`。
- 生成器只需要路径、不想改项目的工具设置：不写 `pinAs`，选择只用于步骤。

#### 不要这样做

- 在生成器里自带发现命令或固定路径。发现归工具定义和 provider，生成器只引用工具 ID。
- 在宿主里按工具名判断版本、默认值或提示。这些是 Core 的职责，宿主只执行 I/O 和画界面。
- 在同一个生成器里同时用 `runtime` 和 `tool`：Core 拒绝这样的清单。`runtime` 只属于版本 1。

### 正确做法

- 新增一个 Cargo 生成器：在 Cargo 插件里声明一条 `command` 步骤调用 `cargo init --vcs none`，`requirements` 写 `{"buildSystemID": "cargo"}`，`requires` 加 `projectGenerators: 1`。宿主不用改。
- 需要按包名放文件：模板目录里放 `Main.java`，步骤写 `"target": "src/main/java/${field.groupId|package|path}"`。

### 不要这样做

- 在宿主里写 `if generator.id == "spring-boot"` 拼下载地址。生态知识必须留在插件声明里，否则社区插件无法参与。
- 在 POM 模板里写 `${field.groupId}`：文件里的 `${…}` 会原样保留，应写 `{{ field.groupId }}`。
- 直接在用户选的目录里跑脚手架。失败会留下半个项目，还可能改到已有文件。
- 在 `projectGenerators` 里加描述运行中进程的字段（例如「支持依赖搜索」）。这属于以后 Provider 协议协商的内容。

## 考虑过的备选方案

### 独立的内置模板插件 Java Project Templates

最有吸引力的地方：停用 Java Support 不影响模板，`requires` 不用让语言插件多依赖一个能力。最初按这个方案实现，后来没有采用：用户把模板看作 Java 支持的一部分，多一个只有模板的内置插件反而难以理解，打包、校验脚本和资源清单也要多维护一份。停用后条目变灰并提示启用，已经能解决「停用后向导无从提示」的顾虑；契约仍允许只有生成器的插件，社区插件可以这样做，宿主为它合成模块。

### 引入「可选能力」

最有吸引力的地方：语言插件加生成器后，旧宿主仍能装它，只是不显示条目。没有采用：`requires` 属于基础字段，改它要升 `pluginAPIVersion`；Java Support 与宿主同版本发行，暂时不需要。

### 生成器只用后端进程

最有吸引力的地方：一种机制覆盖所有情况，Spring Initializr 一开始就能拿到动态的版本和依赖列表。没有采用：多数生成器只是一条命令或几个模板，让作者写后端进程门槛太高；宿主的后端调用目前只服务构建 Provider，进程生命周期和临时目录权限都要另外设计。动态数据留给以后的 `projectGeneratorProviders` 能力，在 `initialize` 里协商 `litheProject` 协议。

### 用插件网页（`ui` 2）画表单

最有吸引力的地方：宿主几乎不用改。没有采用：插件界面原生优先，网页只作为可选方式；名称、位置、校验和提交需要宿主统一控制。

### 给 `runtime` 字段继续增加取值（`python`、`node` ……）

最有吸引力的地方：改动最小，Java 已经这样做。没有采用：`runtime` 取值是 Core 里的封闭列表，每支持一种工具都要改 Core 和宿主，社区插件无法自己带新工具；Core 和宿主里会出现一份又一份语言词汇。工具字段直接引用工具定义 ID，工具的发现和版本规则本来就在工具定义里。

### 生成器自带发现命令

最有吸引力的地方：生成器作者完全自主。没有采用：发现一个工具的方式（PATH、版本管理器、固定目录）已经由工具定义和 provider 描述并被设置页使用；生成器再写一份会让新建项目看到的安装和设置页不一致，选了也无法写成项目的工具 pin。

### 宿主自己解压（`ditto`）

最有吸引力的地方：少一个 Core 命令。没有采用：压缩包来自用户可修改的服务器，属于不可信输入；放在 Core 里，路径穿越、符号链接、覆盖和大小上限的检查只写一次，Windows 接入时直接复用。

## 后果

- 收益：社区插件只靠声明就能加新建项目条目；表单规则和计划在 Core，两个平台给出同样的答案；失败不留残留。
- 收益：设置窗口、克隆窗口和向导共用侧栏行、字段控件和文件夹选择器，样式不会各自漂移。
- 代价：Spring Boot 的版本和依赖列表写在插件里，会随时间过时，要靠插件发版更新；动态列表要等 Provider 能力。
- 代价：Java Support 的 `requires` 多了 `projectGenerators: 1`，不支持生成器的宿主装不了这一版；停用 Java Support 时模板一起停用。
- 收益：任何带工具定义的工具都能被生成器选择，新增工具不需要改 Core 和宿主；选择直接成为项目的工具 pin，建完就能用同一个安装构建运行。
- 代价：使用工具字段的生成器要求 `projectGenerators: 2`，不支持它的宿主装不了这个插件；版本 1 的 `runtime` 字段和 Java 专用路径还在，等 Java 逻辑迁出宿主后再删。
- 代价：只含生成器或工具定义的插件热激活后，已打开的工具链设置页要重读整份快照（和工作区版本文件变化走同一条合并重载路径），而不是只增删变化的那个工具。
- 暂不支持：JavaFX、Quarkus、Micronaut、Jakarta EE 等其他 Java 生成器；Windows 宿主（不声明 `projectGenerators`，需要它的插件在 Windows 市场中隐藏）。

## 验证

```bash
cargo test --manifest-path rust/Cargo.toml -p lithe-core project_generators
./scripts/architecture/verify-shared-contracts.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'ProjectGenerationTests|ProjectToolAdaptersTests|PluginManagerTests|PluginLiveActivationTests'
./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh
```

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project_generators/](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project_generators)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/declarative.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/declarative.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/capabilities.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/capabilities.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/`
- ~~`macos/Sources/Lithe/Views/Workspace/NewProjectView.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Application/Features/NewProjectFeatureModel.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Services/ProjectGeneration/`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Platform/MacOS/ProjectGeneration/`~~（已随 #1794 移除）（含 `MacProjectToolInstallations.swift`、`MacProjectToolPins.swift`）
- ~~`macos/Sources/Lithe/Views/Components/LitheSidebarList.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Views/Components/PluginFieldControls.swift`~~（已随 #1794 移除）
