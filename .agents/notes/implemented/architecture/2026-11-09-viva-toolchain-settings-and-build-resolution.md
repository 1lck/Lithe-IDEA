# Agent 笔记：Viva 的工具链设置与 Build/Run 解析

状态：已实现

## 先说结论

Viva 桌面端现在把插件声明的工具链接进了设置和构建执行：Core 仍是唯一决定“哪个安装生效”的地方，Go 只做声明式扫描、文件事实读取、有界版本探测和原子保存。设置页的 Build 页按插件声明的工具显示当前生效值与来源；用户选择只改草稿，明确 Save 才写 `.lithe/toolchains/local.json`，Cancel 不写。Build 命令任务、Build 模型和 Provider 应用的 `toolchain` 候选都复用同一次解析，启动时使用 Core 返回的可执行文件、导出环境和 PATH。

工具链提供方（`toolchainProviders`）在设置、运行或新建项目需要发现结果时，复用插件的共享后端。工作区与全局查询采用同一套文件事实校验和 Core 解析。原生窗口的完整流程仍待验收。

## 问题

旧 macOS 客户端已有工具链发现与解析，但 Viva 迁移时只剩 Build 候选里的一个占位错误：遇到 `toolchain` 候选直接报“缺少工具链”，没有设置页，也没有从插件声明发现安装。若把发现和优先级写进 Go，会出现第二份工具表、按工具名分支和界面与实际启动漂移。

## 决策

### Core 决定，平台只提供事实

- `desktop/internal/core/toolchain.go` 是 Core 工具链命令的类型化桥：注册表、发现计划、候选、解析、目录 pin 和版本检查。`registry` 输入始终是原始 `{plugins:[{manifest}]}`，由 Core 重新校验清单；宿主不保留自己的工具表。
- `desktop/internal/toolchain/` 只做 Core 不能做的原生 I/O：按 `discoveryPlan` 展开 `home`、`environment`、`absolute` 根的单层 glob，跟随符号链接并排除工作区内的 home；为声明的布局、导出和 PATH 目录收集 `stat`/`realpath` 事实；只探测 Core 从 `candidates` 返回的可执行文件，以及用户已保存 pin 或显式 fixed 对应的声明布局文件。
- 探测有数量（64）、并发（4）和单次 5 秒期限；进程复用既有 `buildprocess` 的有界进程树回收。取消后不发布部分探测结果。
- Core 返回的可执行路径可用正斜杠，Windows 原生扫描和 pin 可能使用反斜杠或不同大小写。执行探测前按原生路径身份合并别名，并把本机路径交给进程适配器；不把同一程序的多个拼写当作多份探测事实。Windows 回归已先复现同一程序被探测三次及 pin 解析因重复证据遭拒绝，修复保留 Core 的严格证据校验。
- 扫描不到安装、版本不满足或工具被两个插件争用时，界面显示 Core 的稳定原因，不伪造默认安装。争用工具不注册，宿主不按插件 ID 替用户选择。

### 按需发现提供方安装

共享插件后端在首次查询时启动，查询与函数调用都用 Core 的会话及取消入口。一个工作区查询带打开时的上下文 ID 和代次。工作区关闭或重开后，旧上下文不能继续发布结果。用户固定的运行目标可以独立解析。

查询使用注册表清单中的插件版本，缓存键也含同一份清单。升级后的首次查询先确认新版本仍是当前启用版本，再结束旧后端并启动新后端。旧版迟到查询不能替换现用会话。新建项目只对表单需要的工具运行发现与探测，未选工具的提供方故障不会阻断表单。

每个工具的同一轮回包共用一个代次。桌面收集声明布局、要求来源和观察路径的原生事实，Core 负责校验身份、路径范围、安装与版本要求。为设置和运行缓存的是有界原始回包，每次使用仍按当前文件事实校验。缺失的输入由最近的现存父目录负责观察，文件变化会使整轮重新查询，已有进程保持自己的启动参数。关闭项目、停用或重新加载插件时，释放观察器并结束相应会话。

例如用户创建原本缺失的版本要求文件时，下次解析应重新调用提供方并使用完整的新回包。仅重新探测上轮已发现的程序无法反映新文件。沿用原生目录事件避免空闲轮询，且让替换写不会留下指向旧文件的监听。

整轮提供方查询有独立的期限。到期时保留已完成的回包，并请 Core 为剩余提供方生成超时回包，以便同一次解析仍能使用本机候选；用户取消或工作区关闭则终止解析。用 `TestToolchainProviderRoundPreservesAnswersAtItsDeadline` 检查已收到的回包和未发出的查询。

### 读取真实来源，明确保存

工具链快照另保存从已打开目录句柄立即读取的工作区身份。保存前同时核对读取时来源和活动项目的身份，不能只比较两个当前路径；原路径被改名并重建时，即使本地文档仍缺失或字节相同，也要拒绝。Core 编辑期间和最终发布前再次核对，防止校验期间替换根目录。已有确认后切换到另一个项目仍只写捕获的原目录并回读原目录；这与替换原目录是不同情况。

- 设置页 Build 页显示每个工具的有效安装、版本、层级和 pin 来源；登录 Shell 的 home 候选单列显示，提供方安装进入同一安装列表。
- 选择只修改窗口草稿；Save 才把整批变化交给 Core。来源文件的路径、字节预算、缺失时默认值、完整 schema 与重复 JSON 键检查都由 Core 给出；没有已安装工具也必须校验 dormant pin。Go 使用已有 `configfile` 适配器按预算读取 UTF-8，不先解析或补默认文档。原生选项未指定平台时采用当前宿主，不能把空平台字符串交给 Core。
- `toolchains.editPinSources` 同时返回本地文档与忽略文件的编辑计划。没有语义变化时保留原字节和缺失状态；例如对不存在的 pin 执行重置，不能创建 `.lithe`。旧 `editPins` 的选择与合并规则继续复用，不重写内核。
- 忽略规则使用 Core 固定版本 `ignore` 的完整匹配器。只调用 `GitignoreBuilder` 的内存行解析和匹配，不启用目录遍历、全局规则发现或线程池；许可证为 MIT/Unlicense，资源开销仅发生在明确保存时。已经生效的通配规则保持原样；后续否定规则取消忽略时，在末尾追加明确规则，保留评论、已有行与换行风格。不在 Go 用“是否包含一行”代替 Git 规则。输入与输出都检查字节和行数预算，避免发布下次无法读取的来源。
- 自动生成的 `.lithe/.gitignore` 也属于本机维护文件。Core 在维护 pin 来源时同时保证它自身与 `toolchains/local.json` 被忽略，只补齐尚未生效的根锚定规则 `/.gitignore` 和 `/toolchains/local.json`。不用 `*`，避免隐藏团队配置；自忽略规则也不影响嵌套目录中的 `.gitignore`。用户原有内容、UTF-8 BOM 和换行保留，无语义变化的 Save 不因缺少自忽略规则而写文件。规则跟随固定 Core 修订，宿主不维护另一份文本追加逻辑。
- `configfile` 绑定私有字节快照和原生工作区身份，使用 `os.Root` 约束相对路径、保留原权限及 ACL，并在发布前重查来源。公开的 `Baseline` 只供显示或兼容调用方使用，不能作为设置草稿的授权基线。指向工作区外的符号链接或 Windows junction 无法让保存落到外部目录。
- 写入先发布忽略文件，再发布 pin 文档。前置步骤失败不改 pin；其后 pin 发布失败只可能留下无害的忽略规则。无变化保存也在 Core 返回后再次校验字节和工作区身份，不能因为没有写入而接受过期草稿。此检查是乐观并发保护，不承诺锁住不遵守同一协议的外部写入者。
- pin 已完成原子替换后，句柄清理或回读仍可能失败；这时返回要求重新加载的稳定状态，界面保留草稿但禁用再次保存，不能宣称“失败必然没有改文件”。正常成功则从确认的来源重新加载实际生效值。读取失败、冲突和无效来源走现有日志边界与共享 i18n。
- 文件只存在于用户选择的工作区，临时文件由原生适配器独占并清理。不往 app bundle、安装目录或插件包写入，因此不会改变代码签名或 Sparkle delta 的发行基线。Core 依赖变化通过固定源码修订及 Cargo.lock 参与现有编译缓存身份，不新增运行时下载或跨工作树共享资源。

### 保存绑定读取的项目

设置草稿携带读取来源的工作区，不能在点击保存时把相同字节基线套到当前新项目。保存前由原生文件接口比较读取根与当前根的目录身份，兼容 macOS 路径别名和 Windows 路径拼写；项目已关闭、来源消失或身份不同时返回冲突，保留草稿，不创建 `.lithe`。已经确认并开始的保存只写捕获的来源，回读也固定该来源，不因期间切换项目而展示新项目的基线。

例如读取 A 后切换 B，再保存旧页面必须拒绝；不能因为 A、B 都没有本地文档、字节基线同为 nil 就允许写 B。若用户确认保存 A 后才切换 B，该操作仍只发布并回读 A。加载和保存失败在适配器边界记录目录事件；文件或项目冲突在界面通过共享 i18n 提醒重新加载，不能把内部英文错误直接显示给中文用户。

### 开发者怎么做

- 新工具只写 `toolDefinitions`：给出可执行布局、版本正则、发现位置和启动模板。不要因为它是“JDK”或“Maven”就在 Go 里加字段或分支。
- Build 需要工具时声明 `toolchain` 候选并让宿主解析；不要把目录拼成命令字符串，也不要自己探测版本。
- 设置页只展示 Core 返回的 `candidates`/`resolve` 结果；草稿选择不得直接写文件，Save 才调用 `SavePin`。

正确做法：插件声明 `homeLayouts` 与版本探测，宿主扫描、探测并把事实交 Core，Build 启动 Core 选中的可执行文件。错误做法：在 `build.go` 里判断 `toolchainID == "java"` 后改读 `JAVA_HOME`，或设置页把“自动”显示成固定路径。

### 执行与设置用同一解析入口

`desktop/internal/workbench/toolchains.go` 把启用插件清单交给 Core，Build 的 `toolchain` 候选按 Core 顺序解析；解析结果直接进入进程启动，导出变量只补消费者未显式设置的值，PATH 前置来自声明的 `pathPrepend`。Provider Run 的 `launch.executable.kind == "toolchain"` 走同一入口。设置页的检测值从不用作启动许可。

### Windows 回归测试覆盖用户目录和 shell 来源

Windows 的工具发现和构建模型测试要保留两条真实本机边界：从 PATH（命令搜索目录）或环境变量找到可执行文件并读取版本，以及通过 `.cmd` 批处理脚本启动工具并解码模型。只注入查找结果或版本输出，无法检查 Windows 的路径和进程启动规则。

`path_windows_test.go` 把合成运行时放在含空格的安装目录，分别通过 PATH 和合成工具自己的环境变量提供；`HOME`、`USERPROFILE` 指向含空格或中文的临时用户目录，不依赖本机装了什么工具。查找、版本进程和 Core 候选规则均走生产入口，只把全局配置根放进测试私有目录。

`build_command_windows_test.go` 用现有工作台测试驱动打开同类临时项目，从 PATH 找到 `.cmd`，让脚本将带空格和中文的参数传给合成构建工具，再通过生产命令模型入口解码结果并检查终态记录。脚本从 Unicode 环境读取工具路径，不依赖机器当前的控制台代码页。

正确做法是用合成清单和测试可执行文件走这些边界。不要读取某个真实插件的包，也不要因本机没装某个工具就跳过用例。

临时程序只链接或复制当前测试可执行文件，始终只读；进程由有截止时间的生产启动器回收，临时目录由 Go 测试清理。工作台驱动沿用项目关闭和后台任务清理。测试不改真实用户配置，也不创建可跨工作树复用的资源。现有 Windows CI 的 `check.sh` 已运行这些包，无需增加第二个 Windows 构建作业。

打包平台的通用覆盖诊断由 Core 提供，契约和检查命令只在 [Core 工具链契约](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/toolchains/README.md) 维护；宿主不复制校验逻辑，也不为某个插件补专属扫描规则。这项静态诊断不替代插件仓库自己的真实工具验收。

## 考虑过的备选方案

- **在 Go 里扫描目录并维护 Maven/JDK 优先规则。** 能最快让界面有内容，但会重造 Core 已校验的四层选择和工具知识，第二个工具就要再改宿主，因此不采用。
- **只做设置页，不接 Build。** 页面可展示但用户仍无法使用所选路径；无法验证“探测结果与启动目标一致”，因此先接执行。
- **单独为每次查询启动一份提供方进程。** 同一插件同时提供语言配置和工具链时，进程启动与初始化会重复。共享后端可在同一连接中区分操作，并由同一个插件生命周期释放。
- **每次都重新向提供方请求。** 工具选择会在设置和多个运行入口反复执行。采用短期有界缓存和原生观察，输入变动时重查，空闲时无需轮询。
- **在宿主 CI 下载真实插件和工具做 Windows 回归。** 会引入具体插件依赖、网络与安装布局，不能稳定控制失败形态；宿主只测试合成工具的通用流程，真实工具在插件仓库验收。
- **忽略整个 `.lithe/`，或在每次读取时补写 `.gitignore`。** 前者会隐藏应由团队共享的配置，后者破坏只读加载和无变化保存的约束。自忽略只在既有的来源维护计划中补齐，并由现有原子写入适配器执行。

## 后果

收益是设置显示与 Build/Run 启动共享同一份 Core 结果，新增工具只需插件声明，不需改宿主工具表。提供方查询需要临时后端和有限的观察器注册。达到观察范围上限后只保留当次结果；保存的 JSON 编辑规则由 Core 持有，平台负责有冲突检查的原生写入。

Windows 已运行真实 Core 的工具链与工作台组件测试，并以受保护的用户专属访问控制列表验证原子保存保留原权限。原生程序识别与权限发布的取舍见 `../bug-fix/2026-11-09-viva-windows-native-file-validation.md`；路径大小写的完整工作流、GUI 和发行包验收仍待补。

## 验证

```bash
./scripts/desktop/desktop-go.sh test ./internal/toolchain ./internal/pluginhost ./internal/settingswindow ./internal/pluginservice
./scripts/desktop/desktop-go.sh test ./internal/workbench
./scripts/desktop/desktop-go.sh vet ./internal/toolchain ./internal/core ./internal/settingswindow ./internal/workbench ./internal/pluginhost ./internal/pluginservice
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
node scripts/i18n/verify-app-language-localization.mjs
node scripts/i18n/generate-i18n.mjs --check
./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh
./scripts/agent-notes/verify-agent-notes.sh
```

`desktop/internal/toolchain/toolchain_test.go` 用真实 Core 和两个语义不同的虚构工具验证声明式发现、版本探测、生效环境、项目/子目录 pin、争用、保存冲突、未知顶层字段拒绝、页面批量保存；另外用可控 kernel 阻塞校验后取消，断言 `local.json` 与 `.gitignore` 字节均不变、无临时文件，并覆盖 ignore 写失败时文档不变。新增可控 kernel 在 Core 编辑期间写入外部修改，回归先失败、补齐二次基线检查后通过；Core 与 Go 桥接共同消费 `Lithe-core-rust/rust/fixtures/toolchain-pin-edit.json`。`settingswindow/toolchains_view_test.go` 验证草稿、显式保存和取消不写；`workbench/toolchains_test.go` 验证 Build 使用解析结果并在工具链不可用时按 Core 顺序回退。这些是组件与真实 Core 证据；Windows 相关组件也已在 Lithe-dev 逐项计时通过，不代替完整 GUI 或发行包验收。

`settings_toolchains_test.go` 的三个行为回归在修复前失败：切换项目写入错误来源、关闭项目误报成功、保存中切换后的回读来源错误；修复后与设置页冲突草稿保留用例通过逐项计时。

Windows 运行 `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope DesktopGo -GoPackages ./internal/toolchain,./internal/workbench -GoTestPattern '^(TestToolchainCandidatesUseNativeShellPathsInUserProfiles|TestBuildModelLoadsFromPathOnlyBatchToolInUserProfiles)$'`：检查 PATH／环境变量两种来源、空格／中文两种用户目录、批处理模型和逐项报告。移除 `commandHomes` 传递或恢复普通 Windows 参数引用时，新用例必须失败；恢复修复后通过。此证据只覆盖合成工作流，功能矩阵的完整原生验收状态保持独立。

## 适用范围

- `desktop/internal/core/toolchain.go`
- `desktop/internal/toolchain/`
- `desktop/internal/pluginservice/toolchain_provider.go`
- `desktop/internal/settingswindow/toolchains_view.go`
- `desktop/internal/workbench/toolchains.go`、`settings_toolchains.go`、`build.go`
- `desktop/internal/toolchain/path_windows_test.go`、`desktop/internal/workbench/build_command_windows_test.go`
- `desktop/internal/pluginservice/toolchains.go`
- `shared/platform-feature-matrix/features/plugin-injected-toolchains.json`

原生存储回归位于 `toolchain/storage_test.go` 与 `configfile/configfile_test.go`：先复现外部链接写入和空重置创建状态，再验证有界读取、重复键/未知字段的 dormant 来源拒绝、后续否定规则、权限保留、私有基线与原生根身份。`core/toolchain_sources_test.go` 与 Core 同用 `Lithe-core-rust/rust/fixtures/toolchain-pin-storage.json`；设置页另外先复现保存后回读失败仍可重试，再验证草稿保留和强制 Reload。组件证据不等于原生 GUI 或发行包验收。

`TestSavePinIgnoresGeneratedFileWithoutHidingSharedFiles` 从真实 Core 与 `SavePin` 写出文件，再让隔离配置的本机 Git 判断忽略结果：`.lithe/.gitignore` 和本机 pin 被忽略，团队配置与嵌套 `.gitignore` 保持可提交。Git 命令只执行空模板初始化和本地 `check-ignore`，有独立期限与管道回收上限；不读取全局 Git 规则或运行 hooks。该集成用例明确依赖 Git，缺少 Git 时不把它记作已通过。
