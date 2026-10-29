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

路径选择使用同一个 `invocation.executables` 数组。插件需要用户覆盖时，声明
`kind: "setting"`、`settingID`，引用全局 file 设置（reload 或 nextRun）；不需要
覆盖的插件保持原来的自动发现列表，不额外声明设置。该通用机制按
`executableResolution: 1` 协商，不要求所有构建插件升级。

Core 先校验完整候选集、排定顺序，再按平台过滤。数组从前到后是首选写法；
可选 priority 以较大值优先，同分按原序；insertBefore/insertAfter 使用同集合的稳定
id 建立相对顺序约束。插入约束优先，不能在同一候选混用 priority 或两个插入字段；
重复 id、未知锚点、自环与循环都拒绝。契约正文定义完整的确定性算法，供后续使用方复用。

macOS 的 `ExecutableCandidateResolver`（候选文件解析器）由宿主注入文件系统、
环境变量、Runtime 和工具发现服务，返回跳过、已解析或终止失败。设置值来自 Core
检查后的同一操作快照；空值跳过，非空无效值直接拒绝，不能经过普通设置解析的
“无效则回默认值”。普通设置的显示与配置容错不变。平台检查权限与版本，显式路径
失败时 Provider 不得独立发现另一安装。带空格路径保持完整参数，父目录进入 PATH。

共享源类型和排序在 `plugins::executables`；本次 Build 与自定义 Runtime Dependencies
使用共享解析器，已有 Build Provider 继续通过 ServerProcess 适配和 tool 提示复用。
Language Server、Execution Provider 等后续可接入相同机制，各自保留包内文件边界、
自动启动限制和工作区信任；当前不在这些清单位置开放新候选语法。
参考 xiaoyumuxi 的 #1318、#1356、#1382 以及 Maven 插件 #3，宿主仍只负责通用机制，
Provider 继续接受宿主选中的工具，不重新实现一套覆盖路径。

已发布预览 Cargo 0.1.1 使用旧 `executableSetting`（buildSystems 2）。保留只读的兼容
输入适配：转换为数组首位 setting 候选，后续只走共享解析器，不再返回
configuredExecutable。新插件必须用第五种候选和新能力；既有发行包不覆盖，迁移以新版本发布。

路径偏好仍写既有用户存储，候选计划只在操作内存活，没有额外缓存或安装目录写入，
不影响签名和 Sparkle delta。Core、Swift 与独立 Cargo CI 覆盖统一的选择和失败语义。

### 6. 宿主能力版本

macOS 的 `hostCapabilities` 声明 `settings: [1, 2]`、`languageServers: [1, 2]` 和 `buildSystems: [1, 2]`。Windows 还没有这些界面和推送，所以仍只声明 1，需要 v2 的插件在 Windows 上会被市场隐藏，而不是装上后行为不完整。

### 7. 路径选择按钮保留完整宽度

插件详情页比完整设置窗口窄。路径输入框若固定占用 220 点，同时右侧作用域和
生效标签保持完整，SwiftUI 会把“选择…”按钮压成没有文字的灰条。通用路径
控件因此固定按钮的自然宽度，让输入框随剩余空间缩短；共享设置行的标题列
以原来的 230 点为上限，窄面板时也允许缩短。宽面板仍保持原来的列宽。
缩放只调整布局，不替换输入框实例，以免丢失尚未提交的路径。

这与 IDEA Community 的文本框加浏览按钮采用相同的空间分配：检查的版本是
`c7f91397daa3a961b4e78bc634fe467a0a7d9ade`，源码为
`platform/platform-api/src/com/intellij/openapi/ui/TextFieldWithBrowseButton.java`
及 `ComponentWithBrowseButton.java`。后者把文本框放在 `BorderLayout.CENTER`，
把 `FixedSizeButton` 放在 `BorderLayout.EAST`，让输入部分承担宽度变化。
macOS 保留既有原生控件和主题，只在通用 owner 中修复压缩规则，不为 Cargo
增加专门的宽度或页面。

### 8. 插件详情不能越过分隔线

分隔容器分配了确定矩形，不代表子内容一定接受这个宽度。插件详情的表单
有自己的最小宽度；窗口缩小后，原来的根容器会按更宽的内容居中，导致名称、
页签和卡片跨进左侧列表，分隔线看起来穿过了详情。

详情根视图必须接受分隔容器给出的宽度，并在自己的边界内绘制。设置页的
原生表单在宽面板填满可用宽度；面板不足以容纳完整设置行时，使用同一个
滚动容器横向查看，保留输入框、选择器和右侧状态标签。只裁剪超出的表单会
让部分设置无法访问；提高整个设置窗口的最小宽度又会限制其他页面，因此
不采用这两种单独修补方式。

宽度只在详情正文的小容器里读取，用于分配可见区域。已构建的正文作为值
传入，不在几何回调里重新加载插件、重建列表或保存宽度。拖动和持久化仍由
既有 `LitheSplitPaneView` 负责，窄宽切换不替换表单实例。

## 考虑过的备选方案

### 宿主为常见工具内置设置页

为 Java、Maven、Gradle 各写一个页面最快，也最接近 mockup。但每多一个工具，宿主就多一个按名字分支的页面，社区插件也无法获得同样的位置。这正是插件化要去掉的东西，所以不采用。

### 让插件用网页画设置页

插件已经可以声明网页 UI，理论上可以自己画设置页。但网页无法和宿主设置窗口的搜索、分组、项目/全局切换保持一致，用户偏好也是原生优先。网页 UI 仍可用于复杂的工具窗口，设置项本身走原生控件。

### 顶层增加可执行文件覆盖旁路

单独增加 executableSetting/configuredExecutable 会让 Build 的设置路径绕过候选顺序，
其它进程模块也不能复用。只为已发布预览包保留输入适配，新 API 使用统一候选与宿主能力注入。

### 宿主自己合并取值

Swift 和 Windows 各写一遍合并规则最直接，但两边一旦有细微差异，界面显示的值和实际启动使用的值就会不同。所以合并只在 Core 做，宿主只负责存储和显示。

## 后果

- 收益：新语言、新构建工具的设置不需要改宿主；社区插件和官方插件拿到同样的位置。
- 收益：团队可以通过 `.lithe/plugin-settings.json` 共享项目设置；“立即生效”的选项不再打断语言服务。
- 代价：宿主无法为某个工具做专门的交互（例如自定义排版）；需要更复杂的界面时，只能扩展通用控件类型，而不是写专用页面。
- 代价：项目设置文件会出现在用户仓库里，团队需要决定是否提交它。
- 现有的 Java/Maven 项目设置页（`ProjectRuntimeSettingsView`、`LSPControlCenterView` 中的 Maven 重试）仍是宿主代码，属于历史遗留，后续应迁移到 Java 插件的声明里，不能作为新增特判的先例。

Windows 设置验收使用独立 API3 受控插件，而不是删减正式包的 requires。受控包包含既有 LSP fixture，因此必须披露语言服务器权限和完整程序声明，并把获批声明及归档摘要与安装记录逐项比较。注册语言设置页与真实双窗口覆盖保存、空值、重置、字节冲突、项目及全局重载、升级停用卸载；这些受控检查不能替代正式发布包或插件函数验收。

验收观察器适配锁定 Tauri 的 Windows fetch IPC 与真实 callback Map，不改写被冻结的 invoke，不替换原生命令或回复。收尾先恢复 fetch，随后等待已接纳回调有界排空，再正常退出宿主，最后比较运行镜像和插件资源；未退出、未排空、丢失调用或资源变化都不能报告通过。postMessage 回退传输未覆盖，仍是待验范围。

公共搜索清空的产品验收从已开放的插件设置列表进入，保留明确选中的已安装包与原始行身份。通过浏览器输入通道发送 Enter/Space down/up，观察同一输入节点重新获得焦点、零匹配过滤恢复、原选中项和详情不变；不使用合成 DOM 键盘事件或补发 click。该操作应没有声明式插件 IPC。测试失败也保留部分快照、释放元素句柄，并继续执行观察器、原生进程及资源快照的收尾。CDP 输入不能证明物理键盘或真实输入法。

## 验证

- `cargo test -p lithe-core --lib settings_v2`：清单校验、分层合并与 `workspaceConfiguration` 展开。
- `cargo test -p lithe-core --lib plugin_configuration`：会话按 section 应答、更新推送、宿主会话拒绝更新。
- `./scripts/macos/test/test-macos.sh --filter PluginSettingsTests`：项目层存储、作用域规则、页面注册、配置展开。
- `./scripts/macos/test/test-macos.sh --filter SettingsSidebarLayoutTests`：静态页面仍各归一个分组。
- `./scripts/macos/test/test-macos.sh --filter PluginSettingsLayoutTests`：480、640、900 点宽的深浅主题下，路径输入框和完整选择按钮都在容器内，按钮可调用选择器并写入所选路径。
- `./scripts/macos/test/test-macos.sh --filter PluginDetailLayoutTests`：实际 Java 插件表单在深浅主题中往返缩放，详情边界始终跟随分隔条，窄面板下右侧设置可经原生横向滚动到达。
- 共享夹具：`shared/contracts/plugins/v1/fixtures/settings-v2.plugin.json`。

## 适用范围

- `rust/lithe-core/src/plugins/settings.rs`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `macos/Sources/Lithe/Application/Features/PluginSettingsRegistry.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+PluginSettings.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginSettingsStore.swift`
- `macos/Sources/Lithe/Views/App/PluginSettingsSection.swift`
- `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift`
- `macos/Sources/Lithe/Views/App/ContributedSettingsPageView.swift`
- `shared/contracts/plugins/v1/README.md`
