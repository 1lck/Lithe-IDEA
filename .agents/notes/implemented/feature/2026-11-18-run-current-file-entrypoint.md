# Agent 笔记：当前文件的运行与调试

状态：已实现

## 先说结论

标题栏选“当前文件”后点运行或调试，可以使用构建提供者按需发现的入口，无须预先创建运行配置（#2104、#2074）：

- 插件在构建系统里声明入口运行 `{"id": "main", "source": "provider", "entrypoints": true}`，需要 `requires.buildProviders: 1`。入口运行不对应构建目标，不出现在构建树和运行配置列表里，只在用户运行某个文件时才产生配置。
- 宿主把当前文件（工作区相对路径）交给根目录包含它的构建实例（内层优先）。Core 用 `build.runEntrypointsPlan` 规划 `lithe/build/runEntrypoints` 请求，插件按文件回答入口，Core 用 `build.decodeRunEntrypoints` 校验：运行必须是入口运行、名称和入口长度受限、项目在实例根目录内，答案不合法时整份拒绝。
- 宿主取第一个入口，按项目路径找到模型里的项目，用 `runConfig.createUserConfiguration` 保存本机配置：名称取入口名（类名），引用的 `targetID` 为空，入口存为 `extensions.build-run.entrypoint`，入口是配置身份的一部分。同一入口再次运行复用已保存的配置。
- 保存后重新读取配置、在标题栏选中并运行。准备运行时请求不带 `target`，入口通过 `launchOptions.entrypoint` 交给插件。之后用户可以像编辑其他构建提供者运行一样修改参数、环境变量和工作目录。
- 没有打开文件、没有可回答的构建实例或文件里没有入口时，提示“当前文件没有可运行的入口”。
- 提供者声明 `buildSystems: 2` 后，可以给应用入口加 `debug.configurationType`。调试只在声明该类型的入口中查找，保存或复用同一份配置，然后使用已注册的适配器连接暂停的进程。没有匹配入口或调试查找失败时，继续尝试编辑器提供的操作。

## 问题

插件读取模型时不编译，也不会把每个 main 类都列成运行配置，否则下拉会被工具类淹没。于是 POM 里没写主类的 main 类没有运行配置，选“当前文件”也只能提示“需要运行配置”，用户只能去改 POM。

## 决策

- 由插件按文件回答入口，而不是宿主按语言判断：宿主和 Core 不认识 Java，任何构建插件都能用同一机制提供“运行这个文件”。
- 入口运行不绑定目标，配置引用只到项目。这样构建树不需要为每个可能的入口建目标，入口也能来自模型没有列出的类。
- 能力版本：`buildProviders` 和 `litheBuild` 都升到 1。旧宿主不声明 1，不会安装需要入口运行的插件版本；SDK 按宿主提供的版本协商最新的一个。
- 入口作为配置身份的一部分，同一模块里不同类各存一条配置，同一个类不会重复保存。
- 一个文件有多个入口时先运行第一个；选择菜单以后需要时再加。

- 构建提供者按磁盘内容查找入口，因此先通过编辑器原有的流程保存修改并处理冲突。查找期间切换文件或修改内容时，丢弃这次查找结果。
- 调试查找失败时记录失败原因，当前文档仍可使用自己的 Debug 动作。没有可用的编辑器动作时显示查找错误。

## 考虑过的备选方案

- 模型读取时扫描源码把所有 main 类列成目标：读取变慢、工具类和测试辅助类会淹没下拉（#2074 已否决）。
- 行号旁运行图标：需要编辑器按语言识别 main 方法或额外的插件协议；标题栏“当前文件”已有入口，先复用它。
- 为源码入口增加独立调试协议：现有注册适配器和回环连接已能表达启动方式，应用入口复用同一机制。

## 后果

- 插件可以按文件提供可运行的入口；新增语言或构建工具时只需在插件里回答 `lithe/build/runEntrypoints`。
- 使用入口运行的插件版本需要支持 `buildProviders` 1 的宿主，插件应和支持它的桌面版本一起发布。
- 仅声明运行的入口仍可正常运行。调试依赖相应适配器可用，旧插件仍可通过编辑器动作启动调试。

## 验证

- Core：`cargo test -p lithe-core provider_run_entrypoints_are_found_by_file_and_start_without_a_target entrypoint_runs_are_saved_per_entrypoint_without_a_target`。
- 宿主：`./scripts/desktop/desktop-go.sh test ./internal/workbench/ -run TestRunOnCurrentFile -count=1`（合成构建提供者回答入口、准备运行）；截图 `TestVisualRunOnCurrentFile`。
- 宿主：`TestCurrentFileDebugSavesAndAttachesToTheDiscoveredEntrypoint` 验证首次调试保存入口，并让已注册的适配器连接该入口的回环端口。

- 宿主：`TestCurrentFileDebugSavesEditsBeforeDiscoveringAnEntrypoint` 验证从缓冲区删除入口时，提供者读取的是保存后的文件。`TestCurrentFileDebugFallsBackWhenProviderDiscoveryFails` 验证提供者失败后仍能启动当前文档的 Debug 动作。

## 适用范围

- `desktop/internal/workbench/title_run_entrypoints.go`
- `desktop/internal/workbench/title_run.go`
- `desktop/internal/workbench/build.go`（`runBuildTargetWith` 接受没有目标的运行）
- `desktop/internal/core/build_entrypoints.go`
- `desktop/internal/pluginservice/builds.go`（`EntrypointRuns`）
- `desktop/internal/pluginhost/pluginhost.go`（`buildProviders` 声明 `[0, 1]`）
- Core：`rust/crates/build/src/run_entrypoints.rs`、`rust/crates/execution/src/configuration/editing.rs`
- `desktop/internal/workbench/build_connection_debug.go`（使用注册适配器连接暂停的进程）
