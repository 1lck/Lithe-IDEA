# Agent 笔记：声明式插件设置

状态：已实现

## 先说结论

声明式插件现在可以在 `plugin.json` 里声明“用户可调的选项”（`settings`），比如 Java Support 的 JDT LS 最大堆内存和日志级别。宿主在“设置 › 插件”页里把它们画成输入框、下拉框或勾选框，把用户的值按插件保存一份，下次启动语言服务器时由 Rust Core 把值代入启动模板（`${setting:<id>}`）。

对日常开发的直接影响：给某个插件加选项，只改它的 `plugin.json`，不用动宿主的通用代码；不要为了某个语言服务器在宿主里加“堆内存”之类的专用设置页。

## 问题

JDT LS 这类语言服务器有很多启动参数，最常见的是堆内存上限。迁移成插件之前这些值写死在宿主的 Rust 适配层里（`-Xmx2048m`、`-Dlog.level=ALL`），迁移之后插件包是只读且签过名的，用户没有任何办法改它们：大型多模块项目遇到 OOM 只能改代码重新发版。

## 决策

### 1. 选项由插件声明，值由宿主保存

- 清单里的 `settings` 只允许三种类型：`integer`（必须给 `minimum` 和 `maximum`）、`enum`（给出固定的选项列表）、`boolean`。没有自由文本类型。
- 值是每个插件一份，对所有工作区生效（用户在提问时选择了这个范围）。保存位置是宿主的偏好存储，键为 `lithe.plugins.<id>.settings`，只记录用户改过的值。
- 用户选回默认值，或点“恢复默认值”，就删除这条记录；以后插件更新了默认值，没改过的用户会自动跟上。

### 2. 展开与回退都在 Rust Core

`plugins.declarative.languageServerLaunchPlan` 的请求多一个 `settings`（选项 ID 到值）。Core 对每个声明过的选项取“存储值若仍被声明接受，否则取默认值”，所以：

- 插件更新收窄了范围，旧的存储值不再合法，启动不会失败，而是悄悄用默认值；
- 存储里有未声明的 ID 会被忽略；
- 宿主 Swift 和 Windows 不需要各写一份回退逻辑，只传存储值。

模板里整段恰好是 `${setting:<id>}` 时保留值的 JSON 类型（`initializationOptions` 能收到数字或布尔），出现在更长的文本里则按文本代入。

### 3. 为什么选项不会变成注入点

- 选项值只可能是整数、布尔或声明过的枚举值；枚举值只允许字母、数字和 `.`、`_`、`-`，所以不可能带进空格或 `--inspect` 之类的额外参数。
- 选项不能出现在包内路径里（`${pluginDir}/…/${setting:x}`），所以用户设置改变不了“启动包里的哪个文件”。
- 校验探测（`validationArguments`）在宿主读取设置之前运行，所以不允许引用选项。
- 选项的存在不改变安装审查要显示的“会运行什么”，因为参数模板本来就在审查清单里，选项只能在模板划定的位置里变化。

### 4. JDT 适配层让出两个参数

直接启动 JDT 时，宿主以前会丢弃插件传来的 `-Xmx` 和 `-Dlog.level=`，再塞自己的默认值。现在这两个参数改为“插件的最后一个合法值优先，没有就用宿主默认值（`-Xmx2048m`、`-Dlog.level=ALL`，即以前的行为）”。合法性很窄：堆大小必须是数字加可选的 `k`/`m`/`g`，并且必须大于 1536 MiB（JDT LS 在不超过 1.5 GB 时会改走“分批导入”，模块坐标重复会让整个 Java 服务失败，见 `2026-10-09-jdtls-heap-ceiling-and-duplicate-maven-coordinates.md`）；日志级别必须是字母数字；不合法的值被丢弃而不是传给 JVM。Java Support 的清单因此把 `heapMaxMB` 的下限和默认值都设为 2048。`-Xms`、`--add-*`、Eclipse 产品属性、元数据位置和 Lombok 仍归宿主所有。

这个读取是幂等的：宿主把自己产出的参数再喂回适配层，得到相同的结果，已有的稳定性测试继续成立。

### 5. 页面怎么交互

输入框在值合法时立即保存，不合法时标出提示并保留上一个合法值；保存后不自动重启，因为输入数字时每一位都会触发保存。页面显示“下次启动语言服务器时生效”和一个“重启语言服务器”按钮，由用户决定何时重启。

## 考虑过的备选方案

- **只给官方插件开放，或只在宿主里写 Java 设置页**：这是用户明确否决的。宿主里按语言加专用设置会重复 [Java 语言服务器是一个声明式插件](../architecture/2026-10-13-java-language-server-as-declarative-plugin.md) 想消除的特判，其他插件也得各自再造一套。
- **自由文本类型（让用户直接填 JVM 参数）**：最灵活，但用户的文本会进入进程参数，能改变加载的代码（`-javaagent`、`-cp`），把“签名插件只运行自己的文件”的承诺整个打破。需要时应当把具体参数建模成新选项。
- **按工作区保存**：对“这个大项目要更多内存”更精确，但需要工作区级的保存位置、覆盖规则和界面。当前选择全局一份，如果以后需要，可以在不改契约的情况下让宿主在 `settings` 里叠加工作区层。
- **改选项后自动重启**：简单，但输入过程中会反复重启，并且会打断正在进行的 Java 导入。

## 后果

收益：任何声明式插件都能暴露有边界的选项；校验、回退和展开只有一份实现；Java 用户可以调大堆内存。

代价：

- 选项的显示文字来自插件清单，官方插件靠宿主的 `Localizable.strings` 以英文原文为键翻译，第三方插件的文字不会被翻译。
- 当前只覆盖“语言服务器启动”这一处用法，运行和测试模板不能引用选项。
- 选项值不会跟着卸载一起删除，重装后会找回；这是有意的，数据量很小。

## 验证

```bash
cargo test --manifest-path rust/lithe-core/Cargo.toml declarative
cargo test --manifest-path rust/lithe-core/Cargo.toml jdt
./scripts/verify-shared-contracts.sh
./scripts/test-macos.sh --filter PluginSettingsTests
./scripts/test-macos.sh --filter PluginLanguageServerLaunchResolverTests
```

契约夹具：`shared/contracts/plugins/v1/fixtures/node-runtime.plugin.json` 声明了三种类型的选项；`command-plans.json` 覆盖默认值、存储值、不合法存储值的回退和布尔类型保持；`invalid-manifests.json` 覆盖选项声明与引用的拒绝情形。

## 适用范围

- `rust/lithe-core/src/plugins/declarative.rs`：声明校验、`effective_settings`、模板代入。
- `rust/lithe-core/src/lsp/languages/jdt.rs`：`-Xmx`、`-Dlog.level=` 的插件优先规则。
- `macos/Sources/LitheCoreContracts/Plugins/DeclarativePluginContracts.swift`：`DeclarativePluginSetting`、`PluginSettingsStoring`。
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginSettingsStore.swift`：保存。
- `macos/Sources/Lithe/Views/App/PluginSettingsSection.swift`：插件页上的控件。
- `Plugins/mac/Official/JavaSupport/plugin.json`：首批选项 `heapMaxMB`、`logLevel`。
- `shared/contracts/plugins/v1/README.md`：对外契约。
