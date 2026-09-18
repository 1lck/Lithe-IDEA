# Agent 笔记：PHP 语言支持的插件归属与运行/测试计划

状态：已实现

## 先说结论

PHP 以前只是内置语言清单里的一条普通记录：只有一个语言服务器能力、启动参数是空的、也没有运行和测试能力。现在 PHP 升级成和 Go 一样的官方原生插件（native plugin，指带独立安装包、可单独禁用和启停的原生 Bundle）：macOS 打包 `PhpSupport.bundle`，同时提供语言服务器、运行和测试三个能力；Windows 的 PHP 扩展不再依赖 CDN 上的预编译二进制，改成和 TypeScript 一样从 bun 运行时取 intelephense。

开发者以后最需要记住三件事：不要往 `BundledLanguagePluginCatalog` 里加回 `php`；不要因为 `phpactor` 被删掉就直接加回来（见"考虑过的备选方案"）；不要为 PHP 发明 `project-php` 工具链，运行和测试固定用 `PATH` 上的 `php`。

## 问题

用户能观察到的现象有两个：macOS 上打开 `.php` 文件时，语言服务器要么起不来、要么起来了不提供补全和诊断；Windows 上 PHP 扩展默认不出现在扩展列表里。

背后是四个各自独立的原因：

1. 共享 provider catalog（[`rust/lithe-core/resources/lsp/language-providers.json`](../../../../rust/lithe-core/resources/lsp/language-providers.json)）里 `php` 的 `languageServerLaunch.arguments` 是空数组。macOS 把这份数组原样当作进程参数传给语言服务器，而 intelephense 的 CLI 需要显式 `--stdio` 才进入 LSP 模式。
2. `php` 的 `capabilities` 只有 `languageServer` 和 `formatting`，因此它拿不到运行入口文件和跑 PHPUnit 的能力；对比 `go` 有 `run`、`testing`。
3. Windows 的 `lithe.php` 把 intelephense 写成 CDN 上的预编译压缩包，而 `getFullExtensions()` 在没有 CDN 基址时会把整个扩展过滤掉，所以默认构建里没有 PHP；同时顶层 `installation.downloadUrl` 硬编码为 darwin-arm64 包，Windows 上即使装上也会拿错平台。
4. 运行和测试必须拥有自己的子进程生命周期：用户禁用或让模块休眠时，已经启动的 `php` 进程必须被终止。这份所有权只有原生插件模块能提供，见[模块运行时的边界与生命周期](2026-09-13-module-runtime-boundaries-and-lifecycle.md)。因此"把 PHP 留在内置清单里，只补个参数"解决不了第 2 点。

## 决策

### PHP 由官方原生插件承担，不再属于内置语言清单

- 插件包 ID 是 `dev.lithe.plugin.php-support`，Bundle 路径是 `PhpSupport.bundle`，入口类是 `LithePhpSupportPluginEntrypoint`。这三个值以及 `plugin.json`、`Info.plist`、`PhpSupportPluginEntrypoint`、`OfficialPluginCatalog` 里的声明必须逐字段相等，任一处不一致都会被 `LitheOfficialPluginVerifier` 拒绝。
- 插件声明两个模块：`dev.lithe.language.php.language-server`（只导出 `dev.lithe.capability.language.php.language-server`）和 `dev.lithe.language.php.execution`（同时导出 `...php.execution` 与 `...php.testing`）。两个模块都默认 `disabled`、按需激活、空闲 600 秒休眠，并且分别拥有自己的进程资源。
- `php` 必须从 `BundledLanguagePluginCatalog.specifications` 中移除。同一个语言 ID 不能同时出现在内置清单和官方插件里，否则 `ValidatedPluginCatalog` 会因重复的语言支持 ID 直接抛错；Go 早就遵循这条规则，现在 PHP 与它一致。

### 共享 catalog 里 PHP 的启动契约收敛为 intelephense

- `executableNames` 只保留 `intelephense`，`arguments` 固定 `["--stdio"]`，`capabilities` 变成 `run`、`languageServer`、`formatting`、`testing`。
- macOS 插件导出的能力配置与这份 catalog 必须表示同一件事：同一个可执行名、同一组参数。catalog 是"设置界面的可尝试工具清单"，插件能力配置是真正启动时使用的配置，两边不一致会让用户在设置里看到的和实际启动的不是同一个东西。
- 插件的能力配置不得声明 `validationArguments`。主机在挑中一个可执行文件后，只要发现校验参数非空，就会带着这组参数先试跑一次，并且**只认退出码 0**；不合格的候选会被整体丢掉。而 intelephense 的 CLI 既不接受 `--version` 也不接受 `--help`，两个都会以 1 退出并把打包源码 dump 到 stderr，于是候选被清空，界面报出"intelephense was not found in the configured toolchain"。Rust 之所以能用 `--version` 校验，是因为 `rust-analyzer --version` 确实返回 0。

### macOS 的运行与测试计划使用 PATH 上的 `php`

- `PhpExecutionCapability.launchPlan` 返回 `.command("php")` 加 `[相对路径] + 用户参数`；`testPlan` 返回 `.command("php")` 加 `vendor/bin/phpunit`。
- 不能用 `.toolchain("project-php")`：`.toolchain(id)` 只解析 Rust Core 的 run 配置生成器产出的工具链注册表，而 PHP 不在那份生成器里，写一个未注册的 ID 会让运行直接失败。`.command(name)` 按 `PATH` 解析，是 Node 测试 provider 已经在用的形态。
- 单条测试的过滤器必须写成 `\b<方法名>\b`，不能照 Go 的 `^<名字>$` 写。PHPUnit 把 `--filter` 匹配到完整的 `<Class>::<method>` 测试 ID 上，所以带 `^` 锚定的裸方法名永远匹配不到任何用例，PHPUnit 会打印 `No tests executed!` 并以非零码退出——运行表现为"点了运行某个测试，什么都没跑"。用词边界而不是裸子串是因为裸子串会连带跑掉所有以该方法名为前缀的用例（夹具里同时放了 `testKeepsInsertionOrder` 和 `testKeepsInsertionOrderWithDuplicates` 来锁住这一点）。

### Windows 的 PHP 扩展改为通过运行时解析 intelephense

- `lithe.php` 的 `lsp` 改为 `{ name: "intelephense", runtime: "bun", package: "intelephense", server: { default: "intelephense" }, args: ["--stdio"] }`，与 TypeScript、Pyright 走同一条工具解析路径。
- `installation` 换成 `parserInstallation("php")`，即只声明树解析器；不再声明 CDN 上的语言服务器压缩包。
- 随之删除 `CDN_BASE_URL` 和 `getFullExtensions()` 中对 `lithe.php` 的门控：PHP 不再依赖 CDN，隐藏它反而让用户看不到一个可用的扩展。
- 运行与测试通过 run-action 发现提供：`composer.json` 的 `scripts` 变成 `composer run <name>` 动作，存在 `phpunit.xml` 或 `phpunit.xml.dist` 时补一个 `php vendor/bin/phpunit`。命令只要求 `php` 在 `PATH` 上，因此 cmd、PowerShell 和 POSIX shell 都能执行。

### 正确做法

- 新增一门语言的官方插件时，照 `Plugins/mac/Official/GoSupport/` 的目录结构放：`Capabilities/` 放导出的语言能力，`Module/` 放模块与进程资源，`Plugin/` 放入口，`Support/` 放共享标识符。
- 语言服务器候选只有一个时，直接把它需要的参数写进 `arguments`。
- Windows 增加语言工具时，优先复用 `runtime` + `package` 的既有工具解析路径，而不是新增 CDN 预编译包。

### 不要这样做

- 不要为了恢复 `phpactor` 兜底而往 `arguments` 里塞两套参数，也不要让 Swift 侧按可执行文件名分支选参数——`arguments` 的语义是"对 `executableNames` 中任意命中项都相同"。
- 不要给 PHP 的能力配置加 `validationArguments`（比如顺手写个 `["--version"]` 当健康检查）。它不会给出"校验不通过"这类可读提示，只会让候选被静默丢光，最终报成"找不到 intelephense"，把排查方向引到 PATH 和安装上去。
- 不要把 PHP 的运行/测试计划接到 Java 的 Maven 回退路径上：那条路径假设存在 `pom.xml` 和 JDK，PHP 项目两者都没有，只会得到误导性的报错。
- 不要在 `getFullExtensions()` 里重新引入基于 URL 是否存在的过滤。扩展能不能用应该由工具解析结果决定，而不是由构建期是否注入了 CDN 基址决定。
- 不要把 PHPUnit 的 `--filter` 写成 `^方法名$`，也不要退化成裸子串：前者一个用例都跑不到，后者会连带跑掉同名前缀的用例。只改参数数组的断言不会发现前者，必须真的跑一次 PHPUnit。

## 考虑过的备选方案

### 备选方案一：给 `languageServerLaunch` 增加 `argumentsByExecutable` 映射

最吸引人的地方是能同时保留 `intelephense --stdio` 和 `phpactor language-server`，用户装了哪个都能用。没有采用的原因是改动面远超收益：Rust 的 `LspServerLaunchDescriptor` 带 `deny_unknown_fields`，新增字段必须同步改 Rust 结构体、[`docs/reference/language-providers.schema.json`](../../../../docs/reference/language-providers.schema.json)（该块是 `additionalProperties: false`）、Swift 的 `LanguageServerLaunchDescriptor`、catalog 解码层和运行时参数选择逻辑；漏改 Rust 结构体会让内嵌 JSON 整体解析失败，catalog 退化成空清单并连带打挂既有断言。而 Windows 侧的 intelephense 本来就只支持单一候选，为一个低配兜底候选引入一次兼容性表面变更并不划算。触发条件：如果以后有第二个"多候选且参数不同"的语言，再按映射表方案统一补。

### 备选方案二：把 PHP 运行/测试接入 Rust 的 run 配置生成器

这样 PHP 能出现在 Run 配置列表里，也能得到一个可配置路径的 `project-php` 工具链，与 Go、Python 的形态完全一致。没有采用的原因是那需要在 Rust Core 里为 PHP 新增项目探测、provider 生成和工具链需求声明，属于独立于"PHP 语言支持"的一条特性线；在只要求跑通语言服务器、运行和测试的前提下，`.command("php")` 用现有能力就能满足。代价是 PHP 暂时不会出现在 Run 配置下拉里，只能通过当前文件运行。

### 备选方案三：Windows 保留 CDN 预编译 intelephense，只修平台 URL 与门控

好处是 Windows 不依赖用户本机的 bun 与 npm 安装，下载即用。没有采用的原因有两个：两端会因此使用两份不同的 server 获取方式，与"同一个行为不要在两端各写一遍"的仓库边界相冲突；而且 macOS 早就是"探测用户已有的 intelephense"，Windows 改成运行时解析后两端语义才一致。

## 后果

- 收益：PHP 在两端都从"能识别文件"变成"能补全、能诊断、能运行、能跑测试"，并且运行和测试真的会随模块禁用/休眠终止子进程。
- 收益：PHP 不再依赖 CDN 上是否存在预编译包，开发构建里也能用。
- 代价：PHP 失去 `phpactor` 兜底，只装了 phpactor 的用户需要另外装 intelephense。
- 代价：PHP 的运行/测试固定使用 `PATH` 上的 `php` 和项目内的 `vendor/bin/phpunit`，没有可视化的工具路径配置入口。
- 代价：语言服务器不再有启动前校验。intelephense 如果装成了不兼容的版本，只能在真正连接、等到 initialize 超时之后才暴露，而不是在挑选阶段就被拦下。
- 代价：PHP 从内置清单移到官方插件后，用户要装上并启用插件才能获得语言支持；未安装插件的用户只剩文件识别。
- 需要重新评估的触发条件：如果多候选工具成为常态，改用备选方案一；如果用户需要图形化配置 PHP 解释器或 PHPUnit 路径，改用备选方案二；如果 intelephense 的 `--stdio` 参数语义发生变化，同步更新共享 catalog 与插件能力配置两处。

## 验证

- `./scripts/verify-official-plugins.sh`：重新打包官方插件并逐包跑 `LitheOfficialPluginVerifier`，确认 `plugin.json`、Bundle、入口类和 factory 与 `OfficialPluginCatalog` 一致。
- `./scripts/verify-module-boundaries.sh`：确认官方插件仍然走 `Contents/Resources/OfficialPlugins` 资源根，没有被塞进 `Contents/PlugIns`。
- `./scripts/test-macos.sh --filter 'PhpSupportModuleTests'`：覆盖 LSP 与执行模块的独立启停、进程资源归属、休眠阻塞、运行计划与 PHPUnit 测试计划，以及插件导出的能力配置（可执行名与 `--stdio` 参数）。
- 插件 CI 的测试过滤表达式（[`.github/workflows/ci-plugins.yml`](../../../../.github/workflows/ci-plugins.yml)）必须显式列出 `LithePhpSupportModuleTests`。该表达式是正则，`[Pp]lugin` 匹配不到 `PhpSupportModuleTests` 这个名字——Go 当初也是同样原因才写了 `LitheGoSupportModuleTests` 字面量。漏掉的后果不是报错，而是这些用例在 CI 里静默跳过、检查依然全绿：实测旧表达式跑 43 个用例 11 个套件，补上字面量后是 51 个用例 12 个套件。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core builtin_catalog_describes_market_lsp_providers`：断言 PHP 的 capabilities、可执行名与 `--stdio` 参数。
- `bun test src/features/run-actions/utils/run-action-discovery.test.ts`（先 `cd windows/tauri`）：覆盖 composer 脚本排序、无脚本清单容错和 PHPUnit 动作发现。
- `LITHE_RUN_PHP_INTEGRATION=1 LITHE_INTELEPHENSE_PATH="$HOME/.bun/bin/intelephense" ./scripts/test-macos.sh --filter RealPhpIntegrationTests`：真实工具端到端。语言服务器部分从 Rust 内嵌 catalog 读出 php 的启动契约，断言 `executableNames` 与 `--stdio`，然后完成 initialize、补全、悬停并等到真实进程终止；测试执行部分把插件的单条测试计划交给真实 `MacLanguageExecutionHost`，在夹具项目里跑真实 PHPUnit，断言退出码 0、输出为 `OK (1 test`、以及模块禁用后不残留进程。
- 夹具项目在 `.artifacts/phpunit-project`（已被 `.gitignore` 忽略，不随仓库分发），首次需要 `composer install` 装 PHPUnit；路径可用 `LITHE_PHP_TEST_PROJECT` 覆盖。
- 说明：`--stdio` 的必要性已实测确认——带该参数时 initialize 在 0.3 秒内返回 12 项能力，不带参数时无任何响应且进程以 1 退出。这个缺陷（`--filter` 用 `^…$` 锚定）正是真实端到端跑起来后才暴露的，纯参数断言看不出来。
- `LITHE_RUN_GOPLS_INTEGRATION=1 LITHE_GOPLS_PATH="$HOME/go/bin/gopls" ./scripts/test-macos.sh --filter RealGoplsIntegrationTests`：参考实现，用来确认这条集成测试通道本身可用。

## 适用范围

- `Plugins/mac/Official/PhpSupport/`
- `macos/Sources/`
- `macos/Tests/LitheTests/PluginManagerTests.swift`
- `macos/Tests/LitheTests/RealPhpIntegrationTests.swift`
- `scripts/test-macos.sh`
- `rust/lithe-core/resources/lsp/language-providers.json`
- `rust/lithe-core/src/lsp/tests.rs`
- `windows/tauri/src/extensions/languages/full-extensions.ts`
- `windows/tauri/src/features/run-actions/`
