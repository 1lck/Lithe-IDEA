# Agent 笔记：Viva 的工具链设置与 Build/Run 解析

状态：已实现

## 先说结论

Viva 桌面端现在把插件声明的工具链接进了设置和构建执行：Core 仍是唯一决定“哪个安装生效”的地方，Go 只做声明式扫描、文件事实读取、有界版本探测和原子保存。设置页的 Build 页按插件声明的工具显示当前生效值与来源；用户选择只改草稿，明确 Save 才写 `.lithe/toolchains/local.json`，Cancel 不写。Build 命令任务、Build 模型和 Provider 应用的 `toolchain` 候选都复用同一次解析，启动时使用 Core 返回的可执行文件、导出环境和 PATH。

这一批没有接入提供方后端查询（`toolchainProviders`），也没有因此声明该能力；Windows 原生保存与相关组件已在 Lithe-dev 验证，完整 GUI 流程仍未验收。

## 问题

旧 macOS 客户端已有工具链发现与解析，但 Viva 迁移时只剩 Build 候选里的一个占位错误：遇到 `toolchain` 候选直接报“缺少工具链”，没有设置页，也没有从插件声明发现安装。若把发现和优先级写进 Go，会出现第二份工具表、按工具名分支和界面与实际启动漂移。

## 决策

### Core 决定，平台只提供事实

- `desktop/internal/core/toolchain.go` 是 Core 工具链命令的类型化桥：注册表、发现计划、候选、解析、目录 pin 和版本检查。`registry` 输入始终是原始 `{plugins:[{manifest}]}`，由 Core 重新校验清单；宿主不保留自己的工具表。
- `desktop/internal/toolchain/` 只做 Core 不能做的原生 I/O：按 `discoveryPlan` 展开 `home`、`environment`、`absolute` 根的单层 glob，跟随符号链接并排除工作区内的 home；为声明的布局、导出和 PATH 目录收集 `stat`/`realpath` 事实；只探测 Core 从 `candidates` 返回的可执行文件，以及用户已保存 pin 或显式 fixed 对应的声明布局文件。
- 探测有数量（64）、并发（4）和单次 5 秒期限；进程复用既有 `buildprocess` 的有界进程树回收。取消后不发布部分探测结果。
- Core 返回的可执行路径可用正斜杠，Windows 原生扫描和 pin 可能使用反斜杠或不同大小写。执行探测前按原生路径身份合并别名，并把本机路径交给进程适配器；不把同一程序的多个拼写当作多份探测事实。Windows 回归已先复现同一程序被探测三次及 pin 解析因重复证据遭拒绝，修复保留 Core 的严格证据校验。
- 扫描不到安装、版本不满足或工具被两个插件争用时，界面显示 Core 的稳定原因，不伪造默认安装。争用工具不注册，宿主不按插件 ID 替用户选择。

### 读取真实来源，明确保存

工具链快照另保存从已打开目录句柄立即读取的工作区身份。保存前同时核对读取时来源和活动项目的身份，不能只比较两个当前路径；原路径被改名并重建时，即使本地文档仍缺失或字节相同，也要拒绝。Core 编辑期间和最终发布前再次核对，防止校验期间替换根目录。已有确认后切换到另一个项目仍只写捕获的原目录并回读原目录；这与替换原目录是不同情况。

- 设置页 Build 页显示每个工具的有效安装、版本、层级和 pin 来源；登录 Shell 的 home 候选单列显示，并说明提供方安装尚未查询。
- 选择只修改窗口草稿；Save 才把整批变化交给 Core。来源文件的路径、字节预算、缺失时默认值、完整 schema 与重复 JSON 键检查都由 Core 给出；没有已安装工具也必须校验 dormant pin。Go 使用已有 `configfile` 适配器按预算读取 UTF-8，不先解析或补默认文档。原生选项未指定平台时采用当前宿主，不能把空平台字符串交给 Core。
- `toolchains.editPinSources` 同时返回本地文档与忽略文件的编辑计划。没有语义变化时保留原字节和缺失状态；例如对不存在的 pin 执行重置，不能创建 `.lithe`。旧 `editPins` 的选择与合并规则继续复用，不重写内核。
- 忽略规则使用 Core 固定版本 `ignore` 的完整匹配器。只调用 `GitignoreBuilder` 的内存行解析和匹配，不启用目录遍历、全局规则发现或线程池；许可证为 MIT/Unlicense，资源开销仅发生在明确保存时。已经生效的通配规则保持原样；后续否定规则取消忽略时，在末尾追加明确规则，保留评论、已有行与换行风格。不在 Go 用“是否包含一行”代替 Git 规则。输入与输出都检查字节和行数预算，避免发布下次无法读取的来源。
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

## 考虑过的备选方案

- **在 Go 里扫描目录并维护 Maven/JDK 优先规则。** 能最快让界面有内容，但会重造 Core 已校验的四层选择和工具知识，第二个工具就要再改宿主，因此不采用。
- **只做设置页，不接 Build。** 页面可展示但用户仍无法使用所选路径；无法验证“探测结果与启动目标一致”，因此先接执行。
- **声明 `toolchainProviders` 后再补查询。** 会让市场允许带后端的工具链插件安装，但本客户端无法发 `toolchains/query`，首次使用才失败；所以本批不声明该能力。
- **用文件监听做实时刷新。** 会新增常驻监听和失效规则；本批在打开页面和显式 Reload 时读取，避免未验收的 watcher 生命周期。

## 后果

收益是设置显示与 Build/Run 启动共享同一份 Core 结果，新增工具只需插件声明，不需改宿主工具表。代价是提供方查询、目录树多来源合并、手动“添加安装”和输入文件监听仍未实现；保存的 JSON 编辑规则由 Core 持有，平台仅负责有冲突检查的原生写入。

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

`desktop/internal/toolchain/toolchain_test.go` 用真实 Core 和两个语义不同的虚构工具验证声明式发现、版本探测、生效环境、项目/子目录 pin、争用、保存冲突、未知顶层字段拒绝、页面批量保存；另外用可控 kernel 阻塞校验后取消，断言 `local.json` 与 `.gitignore` 字节均不变、无临时文件，并覆盖 ignore 写失败时文档不变。新增可控 kernel 在 Core 编辑期间写入外部修改，回归先失败、补齐二次基线检查后通过；Core 与 Go 桥接共同消费 `shared/fixtures/toolchain-pin-edit.json`。`settingswindow/toolchains_view_test.go` 验证草稿、显式保存和取消不写；`workbench/toolchains_test.go` 验证 Build 使用解析结果并在工具链不可用时按 Core 顺序回退。这些是组件与真实 Core 证据；Windows 相关组件也已在 Lithe-dev 逐项计时通过，不代替完整 GUI 或发行包验收。

`settings_toolchains_test.go` 的三个行为回归在修复前失败：切换项目写入错误来源、关闭项目误报成功、保存中切换后的回读来源错误；修复后与设置页冲突草稿保留用例通过逐项计时。

## 适用范围

- `desktop/internal/core/toolchain.go`
- `desktop/internal/toolchain/`
- `desktop/internal/settingswindow/toolchains_view.go`
- `desktop/internal/workbench/toolchains.go`、`settings_toolchains.go`、`build.go`
- `desktop/internal/pluginservice/toolchains.go`
- `shared/platform-feature-matrix/features/plugin-injected-toolchains.json`

原生存储回归位于 `toolchain/storage_test.go` 与 `configfile/configfile_test.go`：先复现外部链接写入和空重置创建状态，再验证有界读取、重复键/未知字段的 dormant 来源拒绝、后续否定规则、权限保留、私有基线与原生根身份。`core/toolchain_sources_test.go` 与 Core 同用 `shared/fixtures/toolchain-pin-storage.json`；设置页另外先复现保存后回读失败仍可重试，再验证草稿保留和强制 Reload。组件证据不等于原生 GUI 或发行包验收。
