# Agent 笔记：调试适配器的可执行文件设置与默认发现

状态：已实现

## 先说结论

调试适配器要启动的程序（lldb 的 `program`）不再由插件把路径写死在 `plugin.json` 里，而是由插件声明一个“文件”类设置，宿主按“用户选的优先，否则按插件声明的候选路径依次找”的顺序解出真实路径，再交给适配器。设置页按[设置读取真实来源并确认写回](../architecture/2026-10-25-settings-native-configuration-editing.md)的约定回显：输入框占位符显示当前找到的程序，旁边的胶囊说明它是“自动找到”还是“你选的”；找不到时占位符显示“Not found”，ⓘ 里写清楚去哪里找、怎么编译。

开发者最需要记住三点：
1. **查什么由 Rust Core 决定，文件系统由宿主检查。** Core 根据设置和插件声明排出候选路径，从不访问文件系统；Swift 逐个检查“是不是可执行的普通文件”。
2. **用户配了就只认用户的。** 配置的路径不可执行时是终止性错误，不回落到候选路径；静默调试另一个文件会掩盖用户的配置错误。
3. **发现结果只用于回显和启动，永远不写回设置。** 打开设置页不写任何文件，发现到的路径也不存成用户值。

## 问题

lldb 社区插件把 `program` 写成 `/Users/.../lldb-demo/main`：

- 换一个项目、换一台机器就失效，用户只能改插件文件。
- 调试的程序随当前打开的源文件变化（`main.c` 编译成 `main`），写死的路径无法表达。
- 找不到程序时，lldb-dap 报的是一段它自己的错误，用户看不出该去哪里做什么。

## 决策

### 正确做法

- **契约：`debugAdapters[].configurations.launch.executable`。** 形如 `{ "setting": "program", "candidates": [...] }`。`setting` 必须指向本插件声明的 `file` 类型设置；`candidates` 至多 8 项、每项 1024 字符以内，必须以 `${workspaceFolder}/` 或 `${fileDirectory}/` 开头，可含 `${fileBasenameNoExtension}`，不得含 `..`。它必须和 `targetBindings.program: "target.executable"` 同时出现，缺一个安装校验就拒绝；只允许 `launch` 请求，`attach` 没有“要启动的程序”。
- **解析顺序固定。** 用户在设置里选的 `file` 值永远优先；没有就按 `candidates` 的声明顺序取第一个可执行的普通文件；都没有就报“没找到程序”。变量没有值的候选（例如没有打开文件时的 `${fileDirectory}`）被 Core 丢弃，不是报错。
- **分工。** `debug.adapters.executablePlan` 命令（Rust Core）返回 `{ setting, configured: {path, source} | null, candidates }`；`macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginDebugExecutableResolver.swift` 逐个检查文件系统（`isRunnableFile`：存在、不是目录、当前用户可执行）。检查函数可注入，测试不依赖磁盘。
- **启动时把结果作为 `target.executable` 事实交给 Core。** `debug.adapters.startArguments` 要求它是绝对路径，否则返回 `debug.target.invalid`，由 Core 把它绑定到适配器的 `program` 参数。宿主不拼适配器参数。
- **设置页回显。** `MacPluginManager` 为每个“被某个调试适配器声明为程序来源”的设置附一个发现结果（`DebugExecutableLookup`：`found(path, isConfigured)` / `configuredUnusable(path)` / `notFound(searched)`）；候选路径依赖正在编辑的源文件，所以用当前活动文件作为目标（`settingsActiveFileURL`）。输入框占位符是当前有效值，找不到时是“Not found”；胶囊区分“自动找到”和“你选的”；找不到或没有活动文件时，说明（ⓘ）里列出已检查的位置并教用户如何编译、如何安装工具链。
- **插件的 ⓘ 文案由插件写，宿主文案走 i18n。** 设置标题、说明、占位符是插件内容，原样显示；宿主的错误文案（找不到程序、配置的程序不可执行）和胶囊文字走 `shared/i18n/` 并用 `L10n.string`，中英词条同批添加。
- **找不到的错误要能执行。** 启动失败信息写出设置的标题和已检查的位置；没有可检查位置时提示“先打开要调试的文件，或自己在设置里选择程序”。

### 不要这样做

- **不要在宿主里读 `program` 之类的适配器参数名或按适配器名写分支。** 是否有可执行文件设置、绑定到哪个参数，都是插件声明的数据。
- **不要在配置的路径不可执行时回落到候选。** 用户明确选了一个文件，它坏了就应该看到错误，而不是悄悄调试另一个程序。
- **不要把发现到的路径写进设置。** 那会把“默认查找”变成一份会过期的影子配置；下次编译位置变了，设置页仍显示旧路径。
- **不要在打开设置页时创建或写任何文件。** 发现只读文件系统。
- **不要让 Core 访问文件系统。** Core 要保持纯函数，才能在 Windows 复用同一份规则，只由各平台自己检查文件。
- **不要给候选路径加 `..` 或绝对路径。** 候选只能落在工作区或当前文件所在目录，避免一份插件声明让宿主探测任意位置。

## 考虑过的备选方案

### 备选方案一：继续在 `arguments.program` 写默认路径

最简单。没有采用：路径写死就是本次要解决的问题；插件用户无法在不改插件的情况下调整，也无法随当前文件变化。

### 备选方案二：宿主按源文件名猜程序路径，不需要插件声明

不用新契约字段。没有采用：不同语言的产物位置不同（C 在文件旁，Rust 在 `target/debug`），猜测规则写进宿主就是按语言写分支；让插件声明候选，换语言只改插件。

### 备选方案三：发现到的路径写进设置

以后读取更省事。没有采用：见“不要这样做”；会过期，也让用户分不清哪些值是自己选的。

### 备选方案四：找不到程序时由宿主自动编译

体验最顺。没有采用：编译命令因项目而异，宿主不能猜；构建前确认弹窗是另一个单独的任务，不和程序发现混在一起。

## 后果

- 收益：lldb 插件不再带机器相关路径；换项目、换文件自动找到旁边的可执行文件；用户可以在设置里改成任何程序；找不到时界面直接说明去哪里、怎么做。
- 代价：契约多了 `executable` 对象和 `target.executable` 绑定（加在尚未发布的插件 API 4 `debugAdapters` v1 内）；设置页每次读取快照会做一次 Core 调用和至多 8 次文件检查，目前不缓存，避免用户刚编译完仍显示“Not found”，若出现卡顿再考虑按活动文件和修改时间缓存；`shared/contracts/plugins/v1/` 合并后要在 lithe-plugin-docs 运行 `node scripts/contract.mjs sync` 同步副本。
- 需要重新评估的触发条件：Windows 端接入同一契约；候选需要读取构建系统输出（如 `cargo metadata`）而不只是文件模板；需要让用户在多个候选间选择。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml debug_executable_plan`
- `cargo test --manifest-path rust/lithe-core/Cargo.toml debug_start_arguments`
- `cargo test --manifest-path rust/lithe-core/Cargo.toml debug_adapter`
- `./scripts/macos/test/test-macos.sh --filter DebugExecutableResolverTests`
- `./scripts/architecture/verify-shared-contracts.sh`
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `shared/contracts/plugins/v1/`（README、schema、`debug-adapter*.json` 夹具）
- `rust/lithe-core/src/debug/adapters.rs`、`rust/lithe-core/src/plugins/declarative.rs`、`rust/lithe-core/src/plugins/settings.rs`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginDebugExecutableResolver.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift`
- `macos/Sources/Lithe/Views/App/PluginSettingsSection.swift`
- `macos/Sources/Lithe/Services/Debug/DebugLaunchConfigurationResolver.swift`
