# Agent 笔记：声明式插件按能力分版本

状态：已实现

## 先说结论

插件 API 级别 1 和 2 给整份 `plugin.json` 只有一个版本号：清单里任何一段改了，所有插件都得跟着升级，旧宿主也会把根本用不到那一段的插件一起挡在外面。从级别 3 起改成按能力（Capability，清单里一个可以独立演进的段，例如语言服务器、构建系统）分版本：`pluginAPIVersion: 3` 只表示“这是按能力分版本的清单”，清单在 `requires` 里写明自己用到的每个能力，以及各自按哪一版契约编写。

宿主用 `hostCapabilities` 告诉 Core 自己实际能运行哪些能力版本，插件市场按能力逐个判断一个插件能不能装。对日常开发的直接影响有两条：

- 给某个能力加字段时，只给这个能力加一个新版本，不用这个能力的插件不受影响。
- 清单只写启动进程前必须知道的事；进程启动后还能做什么，走它自己的协议协商，不往清单里加字段。

## 问题

- **无关模块被绑在一起。** 级别是线性的：级别 2 加了 UI，级别 3 加了构建系统。插件市场原来的判断是“级别 ≥ 2 只在 macOS 可装，级别 ≥ 3 哪里都不可装”。一个只用语言服务器的插件，只要按级别 3 编写，也会因为宿主还不能运行构建系统被隐藏。
- **插件只用一部分模块。** 构建系统的字段多、变化快；语言声明几乎不变。用同一个版本号描述它们，演进节奏快的模块会拖着所有插件一起升级。
- **旧宿主报不出缺什么。** 清单拒绝未知字段（`deny_unknown_fields`），这本身是对的：旧宿主不应该悄悄忽略可能影响执行的字段。但遇到新字段时，它只能报“未知字段”，用户不知道是哪项能力需要更新 Lithe。
- **清单越写越大。** 之前每加一种新能力，都在清单里加字段并升级级别，插件作者会觉得契约一直在变，社区插件很难跟上。

## 决策

### 1. 级别 3 是按能力分版本的清单

| 能力 | 覆盖的清单内容 |
| --- | --- |
| `languages` | `languages[]` |
| `languageServers` | `languageServers[]` 中启动字段以外的部分 |
| `serverProcess` | 语言服务器和自有进程 Provider 共用的启动字段（`launch`、`arguments`、`validationArguments`、`runtimeDependencies`、`initializationOptions`） |
| `executionProviders` | `executionProviders[]` |
| `settings` | `settings[]` |
| `ui` | `ui`；版本 `2` 增加工具窗口里的网页内容 |
| `buildSystems` | 声明式构建识别、模型和命令计划 |
| `buildProviders` | 任一 `buildSystems[].provider`，包括自有进程和共享语言服务器两种写法 |

规则：

- 每个能力的版本 `1` 含义等于该段在级别 2 下的含义。所以把级别 2 的清单改成级别 3，只需要加上 `requires`，其它字段不动。
- 第一个新增版本是 `ui` 2，它增加了 `ui.toolWindows[].web`（插件自带的网页，见[插件自带网页界面](2026-10-18-plugin-web-content-in-host-windows.md)）。只有文本窗口却声明 `ui` 2 会被拒绝：版本只增不改，多声明一个用不到的版本，只会让插件在只支持 `ui` 1 的宿主上无端消失。macOS 自网页宿主实现起发送 `ui: [1, 2]`；Windows 在实现之前继续只发送 `ui: [1]`。
- `requires` 在级别 3 必填，在级别 1、2 禁止出现。
- Core 在解码任何一段之前先检查 `requires`。不认识的能力或版本报 `plugin.api.unsupported`，`field` 是 `requires.<能力>`。即使清单里同时有一段 Core 不认识，也先报缺哪个能力，而不是报未知字段。
- `requires` 必须恰好列出清单用到的能力。少列，宿主可能装上运行不了的插件；多列，插件会在本来能运行的宿主上被隐藏。两种情况都是 `plugin.manifest.invalid`，报错信息会点名缺了哪个、多了哪个。
- 基础字段（`id`、`version`、`vendor`、`permissions`、`activationEvents` 和 `requires` 本身）只随 `pluginAPIVersion` 变化。

为什么要作者自己写，而不是让 Core 从清单推导：推导要先理解每一段。旧 Core 不认识新的一段，就推导不出它需要什么；作者写出来，旧 Core 不用理解那一段，也能准确拒绝。

为什么 `serverProcess` 单独作为一个能力：启动字段由语言服务器和构建系统的自有 Provider 共用。以后新增一种启动方式时，只升级 `serverProcess`，`languageServers` 和 `buildSystems` 的其它字段不受牵连。共享写法的 Provider 复用插件里的语言服务器，所以不单独计入 `serverProcess`。两种 Provider 都必须声明 `buildProviders: 1`：能启动语言服务器或执行构建命令，并不代表能完成构建协议协商、请求和生命周期管理。纯模板构建插件不声明 `buildProviders`，否则会因多列能力被拒绝。

### 2. 宿主自己声明能运行什么

Core 能校验一个能力，不代表宿主能运行它。宿主在 `plugins.declarative.validate`、`plugins.marketplace.validateIndex` 和 `plugins.marketplace.installReview` 里发送 `hostCapabilities: {"<能力>": [版本…]}`，由 Core 判断：

- `validate` 和 `installReview`：发送了 `hostCapabilities` 时，级别 3 的清单只要需要一个宿主没有的能力版本，就报 `plugin.api.unsupported`。没有发送时，只检查 Core 自己是否支持。
- `validateIndex`：级别 3 的版本只有在宿主和 Core 都支持它 `requires` 里的每一项时才可安装。没有发送 `hostCapabilities` 时，一个级别 3 的版本都不列出，这是保守的默认值。宿主声称支持、但 Core 不认识的能力，同样不算支持。
- 级别 1、2 不受 `hostCapabilities` 影响，原有规则不变（级别 2 只在 macOS 可装）。

能力表放在宿主代码里，写在能力实现的旁边，Core 不再按平台去猜。原来按 `darwin-` 前缀和级别写死的判断，就是 Core 替宿主猜、又容易和宿主实现漂移的例子。

macOS 宿主接受级别 1 到 3（`supportedDeclarativeAPIVersions = [1, 2, 3]`），能力表是 `PluginManifest.hostCapabilities`，在校验、索引和安装审查时都发给 Core；其中的 `buildSystems: [1]` 随 macOS 的 Build 工具窗口一起加入，但 macOS 尚未实现 Provider，所以不声明 `buildProviders`；市场过滤、清单校验和安装审查都会拒绝需要它的插件，纯模板构建插件仍可用。Core 自己支持 `buildProviders: 1`，不传宿主表时仍可校验并生成 Provider 计划。Windows 还没有声明式插件宿主，不发送能力表，所以 Windows 不列出级别 3 的插件。宿主接入某个能力时，要做两件事：让宿主接受级别 3，并在宿主自己的能力表里加上这个能力的版本，而且只在宿主真正能运行它时才加。

### 3. 市场索引带上能力版本

- 索引里级别 3 的 `versions[].requires` 必填，内容就是包内清单的 `requires`；级别 1、2 禁止出现。宿主因此在下载之前就能判断装不装得了。
- 索引允许出现 Core 不认识的能力 ID。这样的版本只是不可安装，不会让整个条目被拒，较新的插件版本因此不会把较旧、可安装的版本一起拖下去。
- 输出的 `versions` 带上 `requires`，宿主可以向用户说明缺的是哪项能力。
- 安装审查带上 `hostCapabilities` 时，会按包内清单重新检查一次。即使索引写错，也装不上宿主运行不了的包。

### 4. 清单只放启动前必须知道的事，新能力走 Provider 协议协商

清单回答的问题只有三个：启动什么进程、需要哪些权限、对哪些文件和工程生效。进程启动以后能回答哪些请求、支持哪些可选数据，在 LSP `initialize` 里协商：

- 宿主发送 `capabilities.experimental.litheBuild: {"versions": [1]}`。
- Provider 从中选一个版本，回复 `{"version": 1}`。没有回复版本、或回复了宿主没提供的版本时，宿主不把它当作 Provider 使用。
- 双方都忽略协商对象、请求参数和结果里自己不认识的字段，所以同一个版本内可以继续增加可选数据。另一方不能忽略的改动，才需要新的协议版本。

正确做法：Provider 以后支持增量模型时，在协议里加一个可选方法或参数，在 `initialize` 里协商，清单不变。

不要这样做：在 `buildSystems[].provider` 里加 `supportsIncrementalModel: true` 这类字段。它描述的是运行中进程的能力，放进清单只会逼所有插件升级 `buildSystems` 的版本，而且宿主在进程启动前用不上它。

宿主向 Provider 发请求的部分还没有实现，见[构建系统 Provider 提案](../../proposed/architecture/2026-10-17-build-system-provider-api.md)；协商规则已经写进契约 README 的 Build providers 一节，宿主接入时按它实现。

## 考虑过的备选方案

### 继续用线性级别，每次加字段就升级 `pluginAPIVersion`

最有吸引力的地方：规则只有一条，实现最简单，级别 1、2 也是这样做的。不再采用，因为它让不相关的插件一起被挡在旧宿主外面，“问题”一节里只用语言服务器的插件就是例子。

### 去掉 `deny_unknown_fields`，让旧宿主忽略不认识的字段

最有吸引力的地方：新增可选字段时，完全不用版本号。不采用，因为旧宿主会悄悄忽略可能影响执行或安全的字段（新的启动参数、新的权限），用户看到的行为和插件作者预期的不一样，而且没有任何报错。

### Core 按平台写死每个宿主支持的能力

最有吸引力的地方：只在一个地方维护，宿主什么都不用发。不采用，因为 Core 需要知道每个宿主实现了什么，宿主一改就容易漂移。原来 availability 里按平台写死的判断就是这种漂移的来源。

### 能力版本用 `1.2` 这样的语义化版本

最有吸引力的地方：可以区分“只加字段”和“改含义”，支持 `1.2` 的宿主自动接受 `1.0`。不采用，因为宿主本来就要一直支持旧版本，列出整数版本的集合也能表达同样的事情，而且更简单。

### 让 `buildSystems` 同时代表 Provider 能力

最有吸引力的地方：少维护一个能力 ID，Provider 的启动字段也已经由 `serverProcess` 校验。不采用，因为只实现构建命令的宿主会允许安装 Provider 插件，直到加载模型才暴露不能发送构建请求；共享语言服务器的写法同样存在这个缺口。按插件名或平台过滤又会在 Core 里复制宿主实现进度，所以两种 Provider 都要求独立的 `buildProviders`。

### 加一个旧宿主可以忽略的展示用字段容器（`hints`）

最有吸引力的地方：只影响展示的字段（图标、分组提示）可以不升级任何版本，新宿主用，旧宿主忽略。暂不加入：目前没有真实插件需要这类字段，而按能力分版本之后，不用新字段的插件已经不受影响。等出现真实需求再加，加的时候限定它不能影响启动计划、权限和安装审查。

## 后果

收益：

- 不用构建系统的插件不再依赖构建系统契约；构建系统升级版本时，语言插件照常安装。
- 旧宿主遇到新能力时，报错会点名缺哪个能力，市场可以在下载前就判断能不能装。
- 能力表由宿主声明，Core 不必知道每个平台的实现进度。
- 新能力优先走 Provider 协议协商，清单字段的增长速度变慢。

代价：

- 插件作者要多写一个 `requires`，并保持它和清单里用到的段一致。Core 的报错会点名缺了或多了哪个能力。
- 每个能力出了新版本，Core 都要按版本分支校验，并且一直支持旧版本。
- `serverProcess` 是一个额外的概念，用语言服务器的插件都要写上它。
- 宿主要维护自己的能力表，并在三个命令里发送。漏发时市场不会列出级别 3 的插件，这是保守的方向，但仍可能让人困惑。
- 市场索引的条目仍然拒绝未知字段，索引格式本身的变化仍然要靠索引的 `schemaVersion`。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib declarative_plugins`：`invalid-manifests.json` 中关于 `requires` 的用例（级别 3 缺少 `requires`、低级别出现 `requires`、空表、非正整数版本、格式错误的 ID、未知能力、未知能力先于未知段被报出、未知版本、少列、多列、自有 Provider 缺少 `serverProcess`）；`level_3_manifests_list_exactly_the_capabilities_they_use` 检查报错字段、规范化输出里的 `requires`，以及 `hostCapabilities` 对级别 3 和低级别的不同效果；`build_providers_require_their_own_host_capability` 覆盖自有与共享 Provider 在缺少或不支持 `buildProviders` 版本时被拒绝、完整支持时通过，以及不传宿主表时 Core 仍能校验并生成启动计划。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib marketplace_plugins`：`index-cases.json` 验证只有 `buildSystems` 的宿主保留语言服务器版本；`build_provider_versions_require_host_support_before_download` 覆盖自有与共享 Provider 的版本筛选；`install-reviews.json` 覆盖两种 Provider 的能力缺失、版本不支持、完整支持和不传宿主表的审查，纯模板插件只需 `buildSystems`；`invalid-index-entries.json` 中三个 `requires` 用例；`level_3_versions_list_their_capabilities` 和 `host_capabilities_do_not_change_legacy_levels`。
- `./scripts/verify-shared-contracts.sh`：schema 与 fixture 一致，新增的拒绝码都有文档。
- `./scripts/verify-rust-core-comments.sh`：`plugins/capabilities.rs` 的注释规范。

## 适用范围

- `rust/lithe-core/src/plugins/capabilities.rs`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/plugins/marketplace.rs`
- `shared/contracts/plugins/v1/`
- `shared/contracts/rust-core-api.md`
