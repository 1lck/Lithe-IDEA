# Agent 笔记：LSP 插件构建与语言服务器资源归属

状态：已实现

## 先说结论

以后新增或修改带语言服务器（Language Server，负责通过 LSP 提供补全、诊断和跳转能力的进程）的插件，都必须沿用 PHP Support 的构建方式：插件声明固定版本和校验值，构建阶段下载、校验并把语言服务器放入插件包，插件包完成签名后再分发。主程序不再为插件维护第二套语言服务器路径，也不在运行时改写已安装的 app bundle。

插件拥有语言服务器的文件、启动入口和生命周期；Lithe 只负责插件包验证、插件启停、运行时发现和现有 LSP 会话编排。运行时资源写入用户级 Application Support、Caches 或临时目录，插件卸载、重装和回滚必须能够连同自己的语言服务器一起清理或替换。

本阶段把这条边界进一步落实到 Rust Core：`plugin.validateManifest`、
`plugin.validateLanguageServer` 和 `plugin.lifecycle` 现在是跨平台可执行的
JSON 契约。macOS 包管理器在加载带语言服务器的插件前调用这些命令；Swift
只负责读取文件、检查插件包内的可执行入口和把结果投影到安装流程。PHP
Support 是第一份实际接入，Windows 仍待迁移到同一组命令。

## 问题

语言服务器通常包含可执行入口、第三方归档、许可证和平台相关资源。把这些文件直接放进主程序，或者让主程序在运行时自行下载，会带来几个问题：不使用该语言的用户承担下载和索引成本；插件签名边界不完整；语言服务器可能写入安装目录，破坏 app bundle 的发布基线；插件卸载后还可能留下脱离插件的运行时。

PHP Support 已经验证了独立插件包、固定 Intelephense 版本和插件拥有的版本目录可以覆盖完整链路，因此后续 LSP 插件沿用同一所有权边界。

## 决策

### 1. 插件清单是构建输入

每个带 LSP 的插件在自己的源码目录提供 `language-server.json`。清单至少固定以下事实：服务器版本、HTTPS 下载地址、SHA-256、归档格式、归档根目录、启动脚本相对路径和许可证路径。清单只描述构建所需的上游输入，不保存机器路径、用户目录或运行时缓存路径。

当前 PHP 插件的示例是 `Plugins/mac/Official/PhpSupport/language-server.json`。如果另一个语言服务器使用 zip、单文件可执行程序或不同的启动方式，应扩展构建脚本支持的格式，并保持“固定来源、固定校验、构建后签名”的原则；不能跳过校验直接把网络下载物复制进插件。

Rust Core 同时校验插件目录的 `plugin.json`：schema/API、严格三段版本、
宿主兼容区间、entrypoint、模块排序和语言能力到模块的归属。安装包可以使用
完整 `modules` 声明，Core 也兼容共享 fixture 的 `moduleIDs` 形式；两者都不能
让一个语言能力引用另一个插件的模块。平台适配器不应重新增加一套接受条件。

### 2. 构建阶段完成下载、解压和组装

官方 macOS 插件统一通过 `scripts/build-official-plugins.sh` 构建。该脚本负责：

1. 从插件目录读取 `plugin.json` 和 `language-server.json`。
2. 编译插件自己的 Swift 模块。
3. 调用插件专属准备脚本下载并校验语言服务器归档。
4. 将启动器、上游运行文件、许可证和语言服务器清单放入 bundle 的资源目录。
5. 对完整 bundle 签名；签名完成后不得再修改其中内容。

PHP 的具体下载和组装逻辑位于 `scripts/prepare-php-language-server.sh`。后续插件可以复用相同的构建阶段和校验结构，但不能把某个语言的路径、版本或下载地址硬编码到宿主应用中。

### 3. 插件包是发布和安装单位

主程序默认分发清单不包含可选 LSP 插件。需要独立安装的插件使用与宿主兼容的签名构建，并作为单独的 release asset 发布。插件管理下载或导入包后，必须按以下顺序处理：

1. 校验插件 manifest、宿主兼容版本和代码签名。
2. 校验语言服务器清单和插件内的启动器。
3. 把整个插件版本放到用户级插件版本目录。
4. 在重启边界完成启用、替换或卸载，再让 LSP 控制中心显示可用状态。

macOS 当前的用户级目录是 `<app-support>/Lithe/Plugins/<plugin-id>/versions/<version>`。语言服务器必须位于该插件版本目录内，由插件版本目录拥有；不能另建一个由主程序长期管理的 PHP、JavaScript 或通用 `language-tools` 副本。

### 4. 运行时只发现已安装插件提供的入口

LSP 控制中心和语言工具发现沿用现有 Rust Core LSP 会话。插件启用后，组合根把该插件版本目录中的启动器根路径传给平台运行时；插件未安装、被禁用、隔离或等待重启时，不得重新启用宿主内置的旧路径或通用安装器。

插件状态由 Rust Core 的生命周期 reducer 定义：`discovered`、`installing`、
`installed`、`enabling`、`enabled`、`disabling`、`disabled`、`uninstalling`、
`uninstalled` 和 `failed`。LSP session、语言服务器进程、测试运行和其他插件
资源使用不透明 ID 绑定到该状态；Core 在资源仍存在时拒绝 `disable`、
`uninstall`、失败和重置。当前 macOS PHP 切片已由 `ModuleRuntime` 将插件模块的
启用/禁用接到真实 Intelephense session；Rust reducer 仍是无状态 JSON 契约，尚未
替换 macOS/Windows 的完整 package store 和 session registry。下一阶段必须让
这些宿主状态提交和资源绑定统一消费该 reducer，而不是把 reducer 的存在误报为
全产品生命周期迁移完成。UI 的“保留语言服务器”只能保留经过版本/校验确认的
插件资源记录，不能把进程或下载物转移到宿主共享目录。

语言符号、诊断、补全和类型分析继续由上游语言服务器负责。Lithe 只拥有会话生命周期、取消、超时、旧结果保护、资源预算和稳定的跨平台适配契约，不在 Core、Swift 和 Windows 前端各自实现第二套语言语义。

### 5. 运行时资源必须离开安装目录

构建脚本可以写入待签名的 bundle；已安装 app bundle 和 Windows 安装目录在运行时视为只读。下载临时文件、解压目录、插件状态、日志、锁和语言服务器工作区状态必须使用平台存储适配器放到 Application Support、Caches、临时目录或用户工作区。

正确做法：构建阶段把校验后的语言服务器放进待签名插件包，安装后复制整个版本包到用户级插件目录，运行时只读取启动器。

错误做法：启动时从 `Bundle.main.resourceURL` 解压语言服务器、在插件 bundle 内创建索引，或卸载插件时只删 `plugin.json` 而保留语言服务器目录。

### 6. 跨平台实现保持相同边界

macOS 使用原生 bundle 和 Developer ID 签名；Windows 使用自己的 Tauri 插件包和平台签名、缓存适配器。Windows 不得导入 Swift 插件实现，也不得因为跨平台而把 macOS 的目录或构建脚本复制到 Windows。两端都必须满足：插件自有资源、构建时校验、运行时只读安装目录、禁用和卸载可清理自有资源。

## 考虑过的备选方案

1. 把所有语言服务器随主程序打包：启动简单，但增加主程序体积和每个用户的维护成本，也无法实现按需安装。
2. 只在主程序中记录可执行文件名，交给用户自行安装：减少构建工作，但插件无法保证版本、校验值和安装后的生命周期，重装与卸载也无法清理自己的资源。
3. 运行时由主程序直接下载到共享语言工具目录：可以快速接入，却会形成主程序与插件的双重所有权，容易留下跨插件污染和不可验证的缓存。
4. 为每种语言重新实现 LSP 进程和语义分析：已有 Rust Core 会话和上游语言服务器已经提供这些能力，重复实现会产生协议、项目状态和资源清理的第二个真源。

## 后果

用户只为安装的语言承担下载和索引成本，插件包可以独立发布、验证、重装和卸载。构建过程需要访问固定的上游归档，发布环境必须准备对应架构和签名身份；Node.js 等外部运行时仍由平台能力检查，不由插件偷偷写入安装目录。

插件包、解压结果、语言服务器下载缓存和运行时语言工具没有可靠的跨工作树身份标记，继续在 `scripts/worktree-resources.json` 中作为隔离资源处理，不能通过工作树复用脚本复制。

## 验证

- `cargo test -p lithe-core tests::plugins --no-fail-fast`：验证 PHP 清单、语言服务器清单、dispatcher 命令和资源阻塞的生命周期；生命周期 wire fixture 位于 `shared/fixtures/plugins/lifecycle-v1.json`。
- `scripts/test-macos.sh --filter 'PluginPackageStoreTests|RealPhpIntegrationTests'`：验证 macOS 包管理器通过 Rust Core 校验，并在有 Intelephense 时执行真实 PHP LSP 全流程。
- `./scripts/verify-official-plugins.sh`：检查官方插件构建、语言服务器清单、启动器和代码签名。
- `./scripts/verify-runtime-bundle-immutability.sh`：确认典型启动和插件工作流不会改写已安装 bundle。
- `node scripts/test-reuse-worktree-resources.mjs`：确认语言服务器下载和插件包不能跨工作树复用。
- `./scripts/verify-agent-notes.sh`：确认本笔记格式、路径和验证命令有效。
- 相关 macOS 测试：`MacPluginPackageDownloaderTests`、`MacRuntimeToolDiscoveryTests` 和 `PluginPackageStoreTests`。
- 新增插件还必须验证下载失败、校验失败、取消、等待重启、重装、回滚、禁用和卸载后的进程与文件清理。

## 适用范围

- `Plugins/mac/Official/*/language-server.json`
- `Plugins/mac/Official/PhpSupport/`
- `scripts/build-official-plugins.sh`
- `scripts/prepare-php-language-server.sh`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/`
- `macos/Sources/Lithe/Platform/MacOS/Runtime/MacRuntimeToolDiscovery.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/`
- `windows/tauri/src/extensions/`
- `windows/tauri/src-tauri/src/language_tools.rs`
- `scripts/worktree-resources.json`
- `docs/ci-builds.md`
