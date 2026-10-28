# Agent 笔记：插件热激活——后端准备好的插件装完即用，其余仍然重启

状态：已实现

## 先说结论

安装、更新、回退、卸载、启用、停用一个插件时，只有“它的每一项贡献在宿主里都有运行期实现”的插件才免重启生效。判断由宿主后端决定，写在 `PluginDescriptor.canActivateWithoutRestart`，不是 `plugin.json` 里的字段，所以插件契约没有变化，也不需要同步 lithe-plugin-docs。这条规则目前只落地了第一阶段：只有“纯调试适配器插件”（只贡献 `debugAdapters`，以及它声明的语言和设置，没有后端、没有其他模块）满足条件。

满足条件的插件不进模块图，而是登记在一个**内存实时注册表**（`MacLivePluginRegistry`）里。注册表用后台线程扫描已安装目录，主线程只读取扫描结果快照。其他插件的路径完全不变：仍然写成 `.updateStaged`，等重启才生效。

开发者的直接影响：新增一种可以热激活的贡献，必须先给它写运行期的“登记、撤回、查找”三件事，再把它加进 `canActivateWithoutRestart`；不要因为“某个插件看起来简单”就按名字放行，也不要在清单里加一个“免重启”字段。

## 问题

原来每次安装或更新插件，都要重启 Lithe 才生效。原因是插件的贡献在启动时被一次性装进 `ModuleRuntime` 和 `ModuleRegistry`（模块图），运行期没有“再登记一个模块”或“撤回一个模块”的路径。对 lldb 这类只给宿主多提供一个调试器的插件来说，重启显得多余：用户装完插件，马上想断点调试。

如果直接把所有插件都改成免重启，会出两个问题：

1. 语言服务器、构建系统、VCS、界面贡献等，在运行期还没有对应的登记和撤回代码。强行放行会得到“装上了但没有任何效果”或者“卸载后进程和界面还在”。
2. 模块图的生命周期和已打开的项目窗口绑定，每个项目窗口各有一套 `MacServiceContainer`。往模块图里热插一个模块，要同时改所有窗口的图。

## 决策

### 1. 由后端能力决定，不是清单字段

`canActivateWithoutRestart` 现在的定义是：有调试适配器、没有 `backend` 声明、模块列表恰好是 `[debugAdaptersExtension(<插件 id>)]`，且该模块没有其他贡献。

- 正确做法：新增一种贡献（例如语言服务器）的热激活时，先实现它的运行期登记和撤回，再在这个谓词里放行。
- 错误做法：在 `plugin.json` 里加 `restartRequired: false` 让插件作者声明。作者不了解宿主哪些贡献有运行期实现；声明错了，用户看到的是“装上了但没生效”。
- 错误做法：在宿主里写 `if pluginID == "..."`。这违反“插件专属逻辑不进宿主通用代码”。

### 2. 实时注册表放在内存里，后台扫描

`MacLivePluginRegistry` 持有一个不可变快照 `LivePluginSnapshot`（`entries`、`generation`、由 `entries` 派生的 `activePackages`、`languageSupports`、`debugAdapters`），主线程读取，后台线程生产：

- 触发扫描：`packagesDidChange()`（包文件变了）、`enablementDidChange()`（启用状态变了）。
- 扫描在 `Task.detached(priority: .utility)` 里进行，使用 `MacPluginPackageStore.makeScanStoreFactory()` 新建的只读 store，它有自己的 `FileManager`，不碰主线程的 store。扫描只读 `scanInstalledPlugins()`，不写任何文件。
- 多次触发被串行化（`pendingScan`），扫描失败时保留上一次的登记，不把一次磁盘读失败当成“全部卸载”。
- 结果回到主线程后，先经过 `MacPluginStartupLoader.accept(_:alongside:)`（同一套权限、API 等级、签名、与已登记插件冲突的检查），再生成新快照。`generation` 只在 `entries` 真正变化时加一。
- 只收 `status == .installed` 且 `canActivateWithoutRestart` 的包。`.updateStaged`（等重启的更新）不收。

### 3. 查找按“实时优先”

调试器的查找（`DebugAdapterSessionManager.providersSource`）、语言目录（`PluginLanguageProviderCatalogSource.liveLanguageSupports`）每次都读取注册表的当前快照，不缓存。“实时优先”是指：一个语言既有启动时装入的提供者、又有实时注册的调试适配器时，调试适配器只作为 `.debugAdapter` 能力加到那个语言上，不改语言的名字、语言标识和语言服务器。

- 调试适配器声明的语言变成 `LanguageSupportDeclaration`，带 `debugModuleID`，`isDebugOnly == true`。`applying(languageSupports:)` 最后应用 debug-only 声明，且只在语言已存在时才并入能力。
- 目录校验（`ValidatedPluginCatalog`）按插件 id 排序遍历，所以 debug-only 声明先收集、最后才登记：插件 id 排在语言包之前（例如 `com.example.*` 排在 `dev.lithe.*` 前面）时，它也不会先占住语言、让后面的语言包被判成重复声明。没有任何其他插件拥有该语言时，按 id 顺序第一个调试插件暂代所有者。
- `languageIDs(requiringExtensionFor:)` 跳过 debug-only 声明，所以“这个语言缺少扩展”的宿主功能提示不会因为只装了调试器而消失或出现。
- 同一个语言有多个调试插件时，按插件 id 排序取第一个；`java` 永远保留给宿主自带的适配器（`PluginDebugAdapterEntry.index(of:)` 跳过它）。
- “把语言归给调试插件”和“选哪个适配器去启动文件”是两件事，用两份语言集合表示（`DeclarativeDebugAdapter`）：`languageIDs` 是所有 `selectors` 的并集，只用来给语言挂 `debugModuleID`、判断 `isDebugOnly`；`fileLaunchLanguageIDs` 只收“支持 launch 请求、且 `targetKinds` 覆盖 `file`（省略视为全部）”的 selector，是文件启动的唯一依据。选择器之间是“或”，同一个选择器内是“且”。只声明 `attach` 的适配器，或 `targetKinds` 只有 `process` 的适配器，仍然会让语言出现在语言目录里，但不会被选来启动当前文件。
- 宿主支持 `stdio` 和同一插件语言服务器承载的 `tcpLanguageServer` 适配器；后者需要语言服务器贡献，因此不属于第一阶段的免重启插件。调试入口会主动激活并登记该语言模块，不依赖先打开源码；端口请求可以单独取消，不停止共享服务器。声明 `tcpPort` / `tcpAnnounced` 的适配器会通过 Core 的校验（契约允许），但 `MacPluginLanguageServerLaunchResolver.resolveDebugAdapter` 在启动进程之前就以 `plugin.launch.unsupportedTransport` 拒绝，并给出本地化说明。这样不会先起进程、再因为没人连接而挂起。启动计划里的 `transport` 字段由 Core 给出，宿主不自己解析清单。

### 4. 运行中的会话和语言服务器怎么处理

- 插件包要被替换、移除，或被停用时，注册表在文件改变之前先调用 `willReplacePackage(of:)`，回调 `didWithdraw`，由 `debugAdapterSessionsBox.stopSessions(ofPlugin:)` 停掉该插件拥有的调试会话。会话在创建时记录所属插件 id（`DebugAdapterSessionsBox`），停止按所有者过滤（`DebugAdapterSessionManager.stopSessions(where:)`），不按语言 id，所以同一语言下别的插件的会话不受影响。
- 用户在模块设置里关掉这个插件的调试模块时，没有包文件变化，注册表也不会撤回；`MacServiceContainer` 通过 `moduleRuntime.observeEvents` 观察模块状态，模块变为不可用时同样停掉该插件的会话。这样“停用”和“卸载”的结果一致。
- 适配器清单里的 `capabilities.disabled` 随 `debug.createSession` 的 `disabled_capabilities` 传给 Core（Core 侧该字段 `#[serde(default)]`，旧宿主不传也能工作），由 Core 在会话能力里把这些能力关掉，宿主不自己过滤。
- 语言目录变化时，`LanguageToolingSessionManager.updateCatalog` 只在 `withoutDebugAdapter` 版本的描述变了才停语言服务器。也就是说，装一个调试器不会重启用户正在用的 rust-analyzer。
- 启用状态翻转同样触发 `didWithdraw`（没有运行中的会话时没有任何效果）。

### 5. 多个项目窗口之间用通知同步

每个项目窗口各有自己的注册表。任何一个窗口里扫描或改了登记，都会发 `Notification.Name.litheLivePluginsDidChange`（`object` 是发送的注册表），其他注册表收到后自己再扫描一次，忽略自己发的。测试注入自己的 `NotificationCenter`，不污染全局。

### 6. 管理器怎么走

`MacPluginManager` 通过 `appliesLive(_:)`（有注册表、插件满足谓词、且不在启动时已登记的插件里）判断本次操作是否走实时路径：

- 安装：`deferActivationUntilRestart: !isLive`。走实时路径时直接写 `.installed`，并安排一次扫描；首次安装按默认状态启用。不再设置“需要重启”标记。
- 回退（rollback）：实时路径原地回退；回退到的版本如果不再满足谓词，设置重启标记。
- 卸载：实时路径先清启用状态、撤回、再立刻 `store.uninstall`（内置插件用 `setBundledPluginRemoved`），不再写 `.uninstallPending`。
- 启用/停用：写模块配置后调用 `enablementDidChange()`，不设置重启标记。
- 一个已经在启动时登记的插件，如果被更新成“满足谓词”的版本，仍然走延迟路径（重启后才生效）：它的旧版本还在模块图里，实时路径无法撤回它。

## 考虑过的备选方案

1. **所有插件默认热激活，插件显式声明才重启**：被否。语言服务器、构建系统、界面贡献等在运行期没有登记和撤回实现，放行等于让用户看到“装上了但没效果”。这个方案要等每类贡献都有运行期实现之后才成立，所以改成逐类放行。
2. **在 `plugin.json` 里加免重启字段**：被否，理由见决策 1。字段会进入公开契约，还要同步 lithe-plugin-docs，且作者无法判断宿主后端是否支持。
3. **把热插件登记进 `ModuleRuntime` / `ModuleRegistry`**：被否。模块图和项目窗口的生命周期绑定，每个窗口一套，运行期没有撤回路径；先做模块图的动态登记才能支持语言服务器等贡献，那是后续阶段的工作，不应该让第一类热插件等它。
4. **启动时清理或改写 bundle 来省去扫描**：被否。已发布的 app bundle 是只读基线，写入会破坏 Sparkle 增量更新校验。

## 后果

### 生命周期、所有权和可写位置

- 实时注册表的内容完全在内存里，不持久化。每次启动由启动加载器（`MacPluginStartupLoader`）读一次已安装目录得到初始快照，之后只靠扫描维护。
- 插件包的所有权没有变：安装、卸载、回退仍然只经过 `MacPluginPackageStore`，写入位置是 Application Support 下的插件目录。
- 扫描是只读的，不创建、不改写任何文件，不从 `Bundle.main.resourceURL` 或安装目录推导可写目标。内置插件包（bundle 里的 `bundledRootURL`）只被读取；“卸载内置插件”仍然记录在 Application Support 的状态里（`setBundledPluginRemoved`）。
- 对代码签名和 Sparkle 增量更新（delta）没有影响：运行期没有写入 `.app` 或 Windows 安装目录。验证见 `scripts/verify-runtime-bundle-immutability.sh`（`scripts/test-macos.sh` 开头会运行）。

### 已知边界（有意保留）

1. 对热激活插件做“非热”的暂存更新（例如用旧版本管理器安装的 `.updateStaged`），它的实时适配器会被撤回，直到重启。
2. 正在运行的调试会话在它的插件包变化、被停用时会被停止。
3. 其他项目窗口里的插件管理列表不会实时刷新（这是原有行为）；它们的注册表会靠通知重新扫描，调试器和语言目录是对的。
4. 回退到一个不满足谓词的旧版本会设置“需要重启”标记。
5. 传给 Core 的 `registrationGeneration` 是准备调试适配器时注册表的 `generation`，Core 只比较是否相等，不解释数值。
6. `stopSessions(ofPlugin:)` 只停该插件拥有的会话。会话记录的所有者是创建时选中的插件；同一个语言下另一个插件的会话继续运行。
7. debug-only 声明里的文件扩展名会并入语言；扩展名集合变化会让该语言的服务器按原有规则重启。
8. 目前仍然需要重启的贡献：语言服务器、运行/测试、构建系统、VCS、项目生成器、界面贡献、`backend`、网页窗口。后续阶段按“先有运行期登记和撤回，再放进谓词”的顺序逐类加入，每类单独验证。

## 验证

- `macos/Tests/LitheTests/PluginLiveActivationTests.swift`：谓词的正反例（含契约 fixture）、debug-only 语言与插件 id 排序无关、注册表的收录/代数/启用/撤回/按 id 取第一个、后台扫描不在主线程、扫描失败保留旧登记、另一窗口的通知触发重扫、管理器的安装/更新/回退/启用/卸载流程。等待事件使用带本地期限的 `ChangeLatch`，不用真实 sleep。
- `LanguageProviderCatalogSourceTests`（debug-only 声明不抢语言、顺序无关、不触发扩展提示、每次 load 读取实时声明）、`DebugModuleTests`（`providersSource` 每次调用都查）、`LanguageIntelligenceModuleTests`（出现调试器不会停正在运行的语言服务器）。
- `scripts/verify-runtime-bundle-immutability.sh` 和 `./scripts/verify-agent-notes.sh`。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacLivePluginRegistry.swift`
- `macos/Sources/LitheCoreContracts/Plugins/DeclarativePluginContracts.swift`（`canActivateWithoutRestart`）
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift`（`appliesLive`、`rescanLivePlugins`）
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`（组装、启用判断、撤回回调）
- `macos/Sources/Lithe/Core/Language/PluginLanguageProviderCatalogSource.swift`（语言目录合并实时声明）
