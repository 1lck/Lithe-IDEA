# Agent 笔记：插件设置的通用注册面与生效方式

状态：已实现

## 先说结论

macOS 设置窗口现在可以由插件“注册”页面：插件在 `plugin.json` 里声明设置项放在哪个语言页或构建系统页（`page`）、属于哪个分组（`section`）、能否按项目覆盖（`scope`）、改完何时生效（`effect`），以及页面上的按钮（`settingActions`）。宿主只提供通用的页面、分组、控件、项目/全局切换、状态卡片和按钮，**不写任何针对某个语言、构建工具或插件的设置页和按钮**。

“立即生效”的设置通过 LSP 的 `workspace/configuration` 推给正在运行的语言服务器，不需要重启。项目级的值写进项目里的 `.lithe/plugin-settings.json`，团队可以通过版本控制共享。

日常开发的直接影响：想给某个语言或构建工具加设置或按钮，改插件清单，不要改宿主。

## 问题

按设置界面 mockup（[docs/design/plugin-settings.html](../../../../docs/design/plugin-settings.html)）改造时，最直接的写法是在宿主里加“Java 页”“Maven 页”“重新导入 Maven 按钮”。这会让宿主重新长出按名字分支的特判，和插件化要消除的 `descriptor.id == "java"` 是同一类问题，只是从语言服务挪到了设置界面。

原来的插件设置（`settings` 1）也不够用：

1. 设置只能出现在插件自己的详情页，用户在“语言与框架”下找不到。
2. 只有一层全局值，团队无法让某个项目固定使用某个值。
3. 所有改动都要重启语言服务器，连“开关一个检查项”也要重启。
4. 只有整数、枚举、开关三种类型，路径和文本无法表达。

## 决策

### 1. 宿主只认“注册点”，内容全部来自清单

`PluginSettingsRegistry`（`macos/Sources/Lithe/Application/Features/PluginSettingsRegistry.swift`）从插件快照推导出侧栏页面：

- 已启用插件为某语言提供语言服务器，或把设置/按钮放到 `{"languageID": …}`，就出现“语言与框架 › <语言>”页。
- 设置/按钮放到 `{"buildSystemID": …}`，就出现“构建、执行、部署 › <构建系统>”页。
- 没有 `page` 的设置只留在插件详情的“设置”标签页。

页面由 `ContributedSettingsPageView` 统一绘制：语言页先显示通用的语言服务状态卡（状态、按项目开关、重启），然后按插件列出它放到这一页的设置和按钮。控件由 `PluginSettingsSection` 根据设置类型选择，按 `section` 分组。

正确做法：Elixir 插件想在 Elixir 页加“重建 PLT”按钮，就在清单里声明 `settingActions`，指向自己的插件函数。

不要这样做：在 `SettingsView` 里加 `case .elixir`，或在宿主里判断 `pluginID == "…"` 来画按钮。

### 2. 按钮 = 调用插件自己的函数

`settingActions` 的每个按钮调用同一插件的[插件函数](2026-10-20-plugin-function-contract.md)，参数为空对象。宿主走和插件网页相同的路径：在当前项目里找到该插件的构建实例，经它自己的 Provider 进程调用（`AppModel.runPluginSettingAction`）。宿主不知道函数做什么；`confirm: true` 时先弹确认。

没有打开项目、或项目里没有该插件的构建实例时，按钮给出“不可用”的提示，不会启动别的进程。按钮由用户在宿主绘制的界面上主动点击，所以不再像网页调用那样额外询问“是否启动 Provider”。

### 3. 三层取值，由 Rust Core 合并

取值顺序是：项目值（仅 `scope: "project"`）→ 全局值 → 默认值。存储分两处：

- 全局值：应用偏好，`lithe.plugins.<id>.settings`。
- 项目值：`<项目>/.lithe/plugin-settings.json`，按插件 ID 分组；文档为空时删除文件，`.lithe` 是指向项目外的符号链接时拒绝写入。

宿主把两层原样交给 Core（`plugins.declarative.resolveSettings`、启动计划的 `projectSettings`），由 Core 合并。Swift 侧的 `PluginSettingState.resolve` 只用于界面即时显示，规则与 Core 一致；文本和路径的 `maxLength` 按 Unicode scalar 计数，避免组合字符在宿主接受后被 Core 回退默认值。

这两个位置都不在 app bundle 内，不影响代码签名和 Sparkle 增量更新。

### 4. 生效方式由清单声明，宿主照做

| `effect` | 宿主改完后做什么 |
| --- | --- |
| `restart`（默认） | 有该插件的语言服务器在运行时，页面提示并提供“重启语言服务器” |
| `immediate` | 让 Core 展开 `workspaceConfiguration`，用 `lsp.updateWorkspaceConfiguration` 推给该插件正在运行的服务器；清单校验会拒绝没有被任何 `workspaceConfiguration` 引用的 immediate 设置。连续编辑时，已被新值淘汰的旧发送静默结束，只有真实发送失败才提示重启。 |
| `reload` | 重新加载该插件的构建模型 |
| `nextRun` | 不做任何事，下次运行或构建读取 |

为了保证“立即生效”真的不需要新进程，Core 在校验时拒绝把 `immediate` 设置用在命令行参数或 `initializationOptions` 里。

### 5. 构建工具的可执行文件路径

只声明一个 file 设置不会改变构建进程。`buildSystems` 2 增加通用的
`invocation.executableSetting`，引用全局 file 设置，生效方式为 reload 或
nextRun。Core 负责校验引用和解析值；macOS 每次计划时读取该插件的全局值，
由平台 adapter 检查文件权限和版本，并把同一个路径用于模型 Provider 与构建、
测试、运行。留空恢复自动发现。已指定路径失效时必须报错，不能回退到 PATH
中的另一份工具，否则模型与执行可能使用不同安装。工具父目录也放到进程
PATH 前，供工具启动同目录的辅助程序。

路径只允许全局作用域，避免共享项目配置静默选择本机可执行文件。不要在
Cargo 或其他插件 ID 下写宿主分支。插件只需声明 file 字段和引用；版本 1
宿主通过能力协商拒绝安装，避免出现可保存但不生效的设置。

该设置写入既有用户偏好存储，没有新缓存或安装目录写入，不影响包签名和
Sparkle delta。通用夹具 `build-tool-path.plugin.json`、Core 校验、Swift
路径解析与 Provider 失败回归覆盖这条边界。Cargo 专属真实执行回归仍由独立
插件仓库维护；独立仓库的发布宿主 pin 必须在宿主变更提交后同步更新。

### 6. 宿主能力版本

macOS 的 `hostCapabilities` 声明 `settings: [1, 2]`、`languageServers: [1, 2]` 和 `buildSystems: [1, 2]`。Windows 还没有这些界面和推送，所以仍只声明 1，需要 v2 的插件在 Windows 上会被市场隐藏，而不是装上后行为不完整。

## 考虑过的备选方案

### 宿主为常见工具内置设置页

为 Java、Maven、Gradle 各写一个页面最快，也最接近 mockup。但每多一个工具，宿主就多一个按名字分支的页面，社区插件也无法获得同样的位置。这正是插件化要去掉的东西，所以不采用。

### 让插件用网页画设置页

插件已经可以声明网页 UI，理论上可以自己画设置页。但网页无法和宿主设置窗口的搜索、分组、项目/全局切换保持一致，用户偏好也是原生优先。网页 UI 仍可用于复杂的工具窗口，设置项本身走原生控件。

### 宿主自己合并取值

Swift 和 Windows 各写一遍合并规则最直接，但两边一旦有细微差异，界面显示的值和实际启动使用的值就会不同。所以合并只在 Core 做，宿主只负责存储和显示。

## 后果

- 收益：新语言、新构建工具的设置不需要改宿主；社区插件和官方插件拿到同样的位置。
- 收益：团队可以通过 `.lithe/plugin-settings.json` 共享项目设置；“立即生效”的选项不再打断语言服务。
- 代价：宿主无法为某个工具做专门的交互（例如自定义排版）；需要更复杂的界面时，只能扩展通用控件类型，而不是写专用页面。
- 代价：项目设置文件会出现在用户仓库里，团队需要决定是否提交它。
- 现有的 Java/Maven 项目设置页（`ProjectRuntimeSettingsView`、`LSPControlCenterView` 中的 Maven 重试）仍是宿主代码，属于历史遗留，后续应迁移到 Java 插件的声明里，不能作为新增特判的先例。

## 验证

- `cargo test -p lithe-core --lib settings_v2`：清单校验、分层合并与 `workspaceConfiguration` 展开。
- `cargo test -p lithe-core --lib plugin_configuration`：会话按 section 应答、更新推送、宿主会话拒绝更新。
- `./scripts/test-macos.sh --filter PluginSettingsTests`：项目层存储、作用域规则、页面注册、配置展开。
- `./scripts/test-macos.sh --filter SettingsSidebarLayoutTests`：静态页面仍各归一个分组。
- 共享夹具：`shared/contracts/plugins/v1/fixtures/settings-v2.plugin.json`。

## 适用范围

- `rust/lithe-core/src/plugins/settings.rs`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `macos/Sources/Lithe/Application/Features/PluginSettingsRegistry.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+PluginSettings.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginSettingsStore.swift`
- `macos/Sources/Lithe/Views/App/PluginSettingsSection.swift`
- `macos/Sources/Lithe/Views/App/ContributedSettingsPageView.swift`
- `shared/contracts/plugins/v1/README.md`
