# Agent 笔记：声明式语言插件与进程外执行

状态：已实现

## 先说结论

官方语言插件（Go、PHP）不再是"在 Lithe 进程里加载的 Swift Bundle"，而是声明式插件包：包里只有 `plugin.json` 和它声明的资源（例如打包好的 Intelephense）。Lithe 读取声明，由 Rust Core 校验并展开运行/测试命令，再由宿主自己启动语言服务器和运行进程。插件不在宿主进程内执行任何代码，所以插件包不再依赖宿主二进制，Lithe 每次发版也不用重新编译插件，之后可以把插件拆到独立仓库维护。Go 和 PHP 后来确实拆成了 Lithe Store 社区插件，见 [Go 与 PHP 改为 Lithe Store 社区插件](2026-10-20-go-php-community-plugins.md)。

对日常开发的直接影响：新增语言插件时写 `plugin.json`，不要写 Swift 入口类；声明格式和语义以 `shared/contracts/plugins/v1/` 为准，校验与命令模板展开只在 `rust/lithe-core/src/plugins/declarative.rs` 实现一次。

通用工作台 UI 已通过 API level 2 扩展，见 [宿主管理的工作台 UI 贡献](2026-10-12-workbench-ui-contributions.md)。语言插件的 API level 1 和进程归属保持兼容。

## 问题

原来的原生插件由 `scripts/build-official-plugins.sh` 用宿主当次构建产出的 `.swiftmodule` 编译，并用 `-undefined dynamic_lookup` 链接。`Package.swift` 没有开启 library evolution（库演进模式，保证二进制接口跨版本稳定的编译选项），所以插件与那一次宿主构建强绑定：宿主一改 `LitheModuleAPI` 或 `LitheCoreContracts`，旧插件在运行时就可能找不到符号甚至崩溃。插件一旦拆到独立仓库，就必须跟着每个 Lithe 版本重新编译和发布。

另外，现有 Go/PHP 插件实际只做四件事：声明语言和文件扩展名、启动 gopls/intelephense、生成运行命令、生成测试命令。这些都是数据，宿主本来就有通用的语言服务器模块和执行模块（Python、Rust 等内置语言在用），不需要插件代码。

原生加载还带来一条过严的恢复规则：`MacPluginRuntimeRecoveryCoordinator` 在进程存活期间保留 `lithe.plugins.pending-code-load` 标记，只要应用非正常退出，下次启动就隔离所有加载过的插件模块，哪怕崩溃与插件无关。

## 决策

### 1. 契约放在 shared，执行放在 Rust Core

- `shared/contracts/plugins/v1/` 定义 `plugin.json`（`schemaVersion: 2`）的字段、权限、激活事件、命令模板变量、错误码和状态语义，并提供合法样例、非法样例（附期望错误码）和命令展开的标准答案。schema 1 是已退役的 macOS 原生清单。
- 兼容性只看 `pluginAPIVersion`（声明式插件 API 级别），不再用写死的 `BuiltInPluginCatalog.hostVersion = 0.3.0` 冒充宿主版本。级别 3 起清单还按能力分版本，见[声明式插件按能力分版本](2026-10-17-plugin-capability-versions.md)。
- 校验和模板展开是两端共享的确定性逻辑，按仓库规则放进 Rust Core，通过 `plugins.declarative.validate`、`runPlan`、`discoverTests`、`testPlan` 四个命令暴露。命令是纯函数：宿主每次把清单和请求传进去，Core 不读包、不读工作区。清单内容问题以 `{status: "rejected", error: {code}}` 返回稳定的 `plugin.*` 错误码；只有请求格式错误才是 Core 失败。
- Windows 现有扩展清单暂未改造，契约 README 给出字段对照；Windows 接入时必须通过同一组 fixture。

### 2. macOS 宿主的加载流程

1. `MacPluginPackageStore` 读取 `plugin.json`。schema 1 且入口为 `nativeBundle` 的包直接报 `legacyNativePackage`，绝不加载其代码。
2. 调用 `RustDeclarativePluginOperations.validate` 得到规范化声明，再在 Swift 侧合成 `PluginManifest`（入口类型 `.declarative`，模块由宿主按语言生成，模块 ID 与旧原生插件相同）。
3. 信任检查：宿主内置的 `OfficialPluginCatalog` 固定官方 ID 的签名要求，防止包自行降级；`publisherPackage` 必须通过 `PluginPackageSignature` 的整包 Ed25519 签名，只有 DEBUG 构建允许从磁盘安装本应要求 publisher 签名但未签名的 `localDevelopment` 包，release 拒绝；`sameTeamAsHost` 只认放在宿主 app bundle 内的包（由应用自身的代码签名封住）。`signatureRequirement: "none"` 的社区包可以由市场或磁盘确认流程安装，但不能冒用 `dev.lithe`、`dev.lithe.*` 或固定官方 ID；社区来源不能绕过现存签名文档的校验。因为没有宿主加载的原生代码，不再做 `SecStaticCode` 检查。
4. 每个 `packaged` 语言服务器入口必须是包内的普通可执行文件，不能是符号链接。
5. `MacPluginStartupLoader` 只做静态校验（与内置清单的所有权冲突、模块依赖图），不加载代码。被接受的包无论是否启用都注册宿主模块，启用状态只决定能否激活，所以启用、禁用即时生效，不需要重启；只有启动后才安装的包需要重启才能进入模块图。包的 UI 贡献能否绑定到宿主动作和渲染器，由组合根（`MacServiceContainer`）通过 `validateUI` 注入的检查决定，加载器本身不依赖 Views 层。
6. `MacServiceContainer.declarativePluginFactories` 用声明配置通用的 `BundledLanguageServerModule` 和 `BundledLanguageExecutionModule`。运行/测试计划由 `DeclarativeLanguageExecutionCapability` 交给 Rust Core 展开；进程仍由模块的资源范围持有，禁用时一并停止。
7. `packaged` 语言服务器固定为**本插件**已安装版本目录里的完整路径（`LanguageServerExtensionConfiguration.executableURL`），它就是唯一候选，不按文件名在 PATH 或其他插件里查找，升级前保存的自定义可执行路径也不会排到它前面或在它缺失时顶替：两个插件都打包 `bin/language-server` 时也不会互相启动对方的服务器，文件缺失时直接报不可用而不是换成同名工具；`systemCommand`（如 gopls）走普通工具发现。`runtimeDependencies` 声明的运行时（v1 支持 `node`、`go`）由宿主发现，导出为 `LITHE_<TOOL>_PATH`，并把所在目录放到语言服务器 `PATH` 最前面：Intelephense 的启动脚本读 `LITHE_NODE_PATH`，gopls 则自己调用 `go`。从 Dock 打开的应用不继承 shell 的 `PATH`（没有 `/opt/homebrew/bin`），不声明 `go` 时 gopls 能启动但每个请求都报 `no views`。项目目录里的同名工具永远不会被选中，因为语言服务器在打开文件时自动启动，不能执行仓库自带的程序。`launch.kind` 为 `runtime` 的服务器（如 `node`、`java`）即使没有写 `runtimeDependencies`，也会把自己启动用的那个运行时同样导出（`LITHE_<TOOL>_PATH`，所在目录放到 `PATH` 最前面），用的是宿主已选中的那个可执行文件，而不是 `PATH` 上排在前面的同名旧版本，这样服务器按命令名调用的辅助脚本（`/usr/bin/env node`）与它同一个运行时。宿主集成（如 `jdt`）自己管理环境，不套用这条。
8. 带 `validationArguments` 的语言服务器（如 `gopls version`）只有探测通过的候选才会被使用。插件在启动后才启用时，它的语言服务器错过了启动时的探测，所以 `AppModel` 在注册后发现尚未探测，会先探测再启动，而不是先报“找不到 gopls”再靠重试恢复。

### 磁盘安装沿用声明与审批边界

磁盘输入也交给 Rust 的 `plugins.marketplace.installReview` 生成权限和完整程序清单，不在 Swift 再写一套审查语义。macOS 先由 `MacPluginDiskPackageImporter` 读取 ZIP 或解包目录，复制到私有快照后才做包校验与审查；本地磁盘社区包每次首次安装、升级或同版本替换都要确认全部权限和完整 `programs`，即使 `newPrograms` 为空也不能免确认。市场更新保持已有的差异审批规则，无新程序时可沿用审批。审查与持久化必须保留 canonical program 的全部字段（包括参数、模板、验证探测、初始化选项及构建声明），不能只按命令名表示批准。

磁盘来源 `PluginDiskProvenance` 与市场来源 `PluginMarketplaceProvenance` 分开保存。ZIP 的可选归档摘要取自快照 `archive.zip`，解包目录没有归档摘要；两者都保存内容 digest 与完整 `approvedPrograms`，不声称经过远端仓库或发布者认证。store 在安装 staging、扫描和回滚时复验内容，当前/上一版本各自保留 origin 和来源记录；同版本替换沿用原有上一版本，而不是把被覆盖的同版本存成回滚副本。市场同 ID 条目不能自动成为磁盘包的更新或重装来源。

快照目录为 `<file-storage-temp>/lithe-plugin-disk-<UUID>/`，由 `MacServiceContainer` 注入的 `fileStorage.temporaryDirectory()` 决定根目录。importer 持有复制阶段，失败/取消清理；成功准备后 service 持有，取消审批或安装成功/失败都 discard。插件页关闭时结束安装 session，清理已有及迟到返回的快照，避免关闭页面后继续安装。安装暂存与持久版本在平台 Application Support；快照、审批记录和安装状态不跨 worktree 复用（`plugin-disk-install-state`），其内容摘要不是构建身份标记。运行时不写发行 bundle 或 Windows 安装目录，不影响代码签名与 Sparkle delta。完整取舍与复验流程见[插件市场与插件仓库源](../feature/2026-10-12-plugin-marketplace.md)。Windows 目前仅共享 Core 校验和契约，尚未实现这条声明式磁盘安装链。

正确做法：先对平台临时目录里的私有快照审查，安装时重验 staging，并按恢复版本的来源校验回滚。不要这样做：审查原目录后重新读取原目录安装、给目录伪造 ZIP 摘要，或把本地摘要当作官方签名。

### 3. 去掉原生加载与过严的隔离

删除 `MacNativePluginLoader`、`MacPluginRuntimeRecoveryCoordinator`、`LithePluginEntrypoint`、`PluginHostContext` 以及 Go/PHP 的 Swift 源码和测试目标。声明式插件不在进程内运行代码，因此不再设置进程级加载标记；旧版本留下的标记在启动时直接清除，不再隔离任何模块。`ModuleRuntime` 对模块激活的 pending 标记保护不变。

### 4. 旧版原生 PHP 包的过渡

已安装 0.3.0 原生包的用户启动新版本后，插件管理把 PHP 显示为"需要更新"，并展示原因；旧包代码不会被加载。从插件市场安装或更新会用声明式包替换它（新包版本 1.0.0）。模块 ID 没变，用户原来的启用设置保留。回滚到旧原生包会被拒绝，避免回到不能用的版本。下载入口和发布流程已由插件市场接管：官方插件按自己的 `plugin-<名称>-v<版本>` 标签单独发布，客户端从官方索引按本机架构选包，详见 [插件市场与插件仓库源](../feature/2026-10-12-plugin-marketplace.md)。Lithe 版本 Release 不再附带 `Lithe-PHP-Support-<版本>-<架构>.zip`，只兼容 0.6.1 及之后的客户端。

### 5. Go 一并改造

Go Support 改为声明式后首次出现在插件管理页，默认禁用；用户启用后才会在打开 `.go` 文件时启动用户自己安装的 gopls。最初它随应用内置（`sameTeamAsHost`，不提供重装和卸载），后来改为和 PHP 一样从插件市场下载（`publisherPackage`，发布标签 `plugin-go-support-v<版本>`）：Go 的修复也不再依赖 Lithe 发版。包里仍只有 `plugin.json`，gopls 和 Go 继续由用户自己安装。`official-plugin-distribution.mjs` 的内置名单后来只包含 Java Support，见 [Java 语言服务器是一个声明式插件](2026-10-13-java-language-server-as-declarative-plugin.md)。改造前 Go 模块默认禁用且界面无入口，实际从未加载，所以这次没有退化风险。单文件测试改为运行该文件所在的包（根目录文件对应 `.`），比原来的 `./...` 更准确。

### 6. 跳转到工作区外的源码只读打开

gopls 把 `fmt.Println` 的定义指向 `GOROOT/src/fmt/print.go`，Intelephense 把内置函数指向插件包里的 stubs，这些都在项目目录外。原来 `DocumentFeatureModel` 一律拒绝打开工作区外的文件，提示“This file is outside the current workspace”，所以插件语言无法跳进依赖源码（Java 走 `jdt://` 虚拟文档，不受影响）。

现在只有语言服务器跳转（定义、实现、引用、导航历史）可以离开工作区，并且同时满足：

- 目标按“打开时使用的路径”和“解析符号链接后的真实路径”分别判断，两者都在工作区内才算工作区文件；其余一律走外部规则，所以工作区内指向外部的符号链接，以及外部指向工作区文件的符号链接，都不能绕过白名单或只读限制。
- 目标文件和它解析符号链接后的真实路径，都必须是**发起跳转的语言**的源码文件：从 Go 跳只能打开 `.go`，从 PHP 跳只能打开 `.php`/`.phtml`。判断由 `LanguageNavigationCoordinator.allowsExternalSource` 依据语言目录完成。语言目录里也有 `json`、`yaml`、`sh` 这类可能存放密钥的格式，所以不能放宽成“任意已知语言”。
- 导航历史的 Back/Forward 回放不保存来源语言（当前语言可能已切换），而是把该文件当作它自己语言的源码重新校验；条目只可能来自当初已被接受的跳转。
- 文档始终只读，`isFileWritable` 为 false，保存会被拒绝。普通打开（项目树、搜索、外部 URL）仍然拒绝工作区外路径。

依赖树（把 GOROOT、模块缓存、`vendor/` 显示到依赖面板）不在这次范围，另行设计。

### 正确与错误示例

正确：为新语言写 `plugin.json`，声明 `languageServers` 和 `executionProviders`，在契约 fixture 中补一个命令展开样例，并在 Rust 测试中验证。

错误：在插件包里放 Swift 或任何 Mach-O 代码；在 Swift 宿主里按语言 ID 写 `switch` 生成命令；在宿主里写死某个插件的工具路径或 ID 来查找语言服务器。

## 考虑过的备选方案

1. 保留原生 Bundle，开启 library evolution：能缓解二进制兼容，但要冻结大量 Swift 接口，插件仍在宿主进程内运行，崩溃会带垮应用，过严的隔离规则也去不掉。
2. 先拆仓库再改形态：每次 Lithe 发版都要同步重编插件，发布链路更脆弱，没有解决根因。
3. 在 Swift 里实现模板展开、只把 fixture 放进 shared：改动更小，但仓库规则要求两端共用的确定性逻辑放 Rust Core，否则 Windows 接入时会出现第二份实现。用户选择直接放 Rust Core。
4. 继续加载已安装的旧原生 PHP 包并提示更新：更新前还能用，但新宿主已删除 PHP 的 Swift 模块，旧包有运行时崩溃风险，因此选择不加载、提示重装。
5. 引入完整的第三方插件进程协议（例如 Worker/扩展宿主）：本次只需要语言声明和命令模板，已有通用模块足够；将来需要插件自定义逻辑时再单独设计。
6. 让磁盘安装绕过 Rust 审查，或复用市场 provenance：会产生第二套权限语义，且把本地字节误当作有仓库校验来源；改为共用 installReview、保存独立来源，付出私有快照复制和每次显式确认的成本。

## 后果

插件与宿主二进制解耦，可以独立发布和拆仓库；同一份声明可供两端使用；启用、禁用不再需要重启；崩溃后不再误隔离插件。宿主侧原来散落的 PHP 特判（工具目录、包校验器、LSP 中心提示）改为由声明驱动。

代价：声明只能表达契约里定义的能力，需要新能力（新模板变量、新运行时依赖、新权限）时，级别 1、2 必须升级 `pluginAPIVersion`，级别 3 起只升级对应能力的版本，两种情况都要同时更新 Rust 实现、schema、fixture 和两端宿主；旧原生 PHP 用户需要手动点一次重新安装；本机真实 PHPUnit 集成测试依赖 PHP 与 Composer，未安装时只能运行 Intelephense 那一半。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib declarative_plugins`：合法样例、非法样例错误码、命令展开标准答案，以及仓库里的官方 `plugin.json`。
- `./scripts/verify-shared-contracts.sh`：契约目录自洽（schema、fixture 引用、错误码均已在 README 中登记）。
- `./scripts/verify-official-plugins.sh`：组装官方包并用 `LitheOfficialPluginVerifier` 检查信任策略、打包入口和"包内无 Mach-O"。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'Plugin|LanguageExtensionProcessLifecycleTests|LanguageServerToolServiceTests|LanguageNavigationCoordinatorTests|ExternalNavigationTests'`：包校验、旧包过渡、签名、启停与进程清理、打包入口固定、跨工作区跳转边界。
- `LITHE_RUN_PHP_INTEGRATION=1 ./scripts/test-macos.sh --filter RealPhpIntegrationTests`：真实 Intelephense 与 PHPUnit。
- `node scripts/test-reuse-worktree-resources.mjs`：磁盘快照、安装状态和审批记录禁止跨工作树复制。
- `./scripts/verify-runtime-bundle-immutability.sh`：静态检查两端发行资源写入边界；磁盘安装、取消、失败、扫描与回滚的产品验收还需比较前后 bundle 文件清单/哈希，不能用静态通过替代真实验证。磁盘每次确认与两入口完整程序展示的行为验收见插件市场 Note；功能矩阵继续保持 `pending`。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/declarative.rs`
- `macos/Sources/Lithe/Core/Rust/RustDeclarativePluginOperations.swift`
- `macos/Sources/LitheCoreContracts/Plugins/DeclarativePluginContracts.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/Lithe/Application/Features/LanguageNavigationCoordinator.swift`
- `macos/Sources/Lithe/Application/Features/DocumentFeatureModel.swift`
- `macos/Sources/LitheExecutionModule/Modules/BundledLanguageExecutionModule.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Modules/BundledLanguageServerModule.swift`
- `Plugins/mac/Official/`
- `scripts/build-official-plugins.sh`
