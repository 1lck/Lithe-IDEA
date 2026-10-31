# Agent 笔记：插件语法高亮与运行标记

状态：已实现

## 先说结论

这次给插件新增两个能力，对应 #1548 计划里的 API-25、API-27 和 API-29，起因是 #570 的 `.http` HTTP 客户端插件。

- `languages: 2`（API-25）：插件给自己声明的语言附上一份语法文件和一份编辑器配置（括号、注释、自动配对），只靠配置文件高亮，不需要语言服务器、后端或激活事件。`grammar.kind` 用来指定渲染引擎，目前只定义 `monarch`；以后要换 TextMate 或 tree-sitter 时加新的 kind，不改已有插件。
- `runMarkers: 1`（API-27 运行标记装饰，加上 API-29 从标记运行）：一个通用的 Provider 回答“这份文档哪些行能运行”。插件声明 `{languageID, function, command}`，编辑器在文档变化后调用 `backend: 2` 的函数，把它返回的行画成行号旁的运行按钮；用户点击后宿主执行插件命令，通过 `lithe/host/commands/didRun` 把 `runMarker{id, languageID, path, line, version}` 交给后端。

开发时记住三点。第一，语法和运行标记的输出都由 Rust Core 校验（`plugins.declarative.decodeGrammar`、`plugins.declarative.decodeRunMarkers`），宿主和编辑器只消费校验后的结果，不自己解析插件的 JSON。第二，纯语法插件免重启，带运行标记的插件需要重启，因为运行标记依赖后端，后端目前只在启动时登记。第三，宿主不按插件名或语言名加分支，所有插件都走同一条路径。

## 问题

#570 要做一个类似 IDEA HTTP Client 的插件：`.http` 文件要有高亮，每个请求旁边要有运行按钮。现有插件能力做不到：

- 语言贡献（`languages: 1`）只能声明 ID、扩展名和 LSP。没有语言服务器的格式只能显示纯文本，为了高亮去写一个 LSP 成本太高。
- 运行按钮只有内置的 Java 运行标记，位置由宿主自己的识别逻辑决定，插件无法提供。
- 用户希望 API 尽量少：不能为“测试函数”“main 函数”“HTTP 请求”各开一个识别 API，要一个通用接口覆盖任意语言、类、函数，以及自定义格式里的可执行块。
- 插件可以写任意正则，必须防止病态语法拖垮编辑器，也不能让语法文件从包外读内容。

## 决策

### 语法是声明式配置，引擎由 `kind` 决定

- 清单写法是 `languages[].grammar: {kind: "monarch", path}` 和可选的 `languages[].configuration`。`path` 相对插件包，不能离开包。
- 选 Monarch 先做，是因为编辑器本来就是 Monaco：不需要额外的 WASM 引擎，正则用浏览器自带的引擎，内存只多出每个语言一份状态机定义。TextMate 语法表达力更强，但要加载 oniguruma WASM，每个打开的文档都要保留行状态，内存明显更多，留到以后加新的 `kind`。
- Core 的 `grammar.rs` 负责校验：文件最大 256 KiB，最多 256 个状态、4096 条规则，每个正则最长 2048 字节，动作嵌套最多 8 层；`next`、`switchTo`、`include` 必须指向语法里存在的状态，日志字段之类的调试动作一律拒绝。校验失败返回 `plugin.grammar.invalid` 并带上失败字段，该语言照常注册，只是没有高亮；插件没有为该语言声明语法时返回 `plugin.grammar.unavailable`。
- 宿主（`MacPluginEditorLanguages`）只读插件包：解析符号链接后确认文件仍在包内，限制 256 KiB 并要求 UTF-8，按路径、大小、修改时间和语言缓存解码结果，被拒的语法只记一次日志。
- 编辑器（`frontend/editor/src/plugin-languages.ts`）收到的是完整语言列表，用 `setMonarchTokensProvider` 和 `setLanguageConfiguration` 注册；某个语言注册失败时回报给宿主记日志，不影响其他语言。已打开的文件在语言列表变化后重新判定语言。

### 语法高亮免重启

- 语法通过一个只承载启用状态的模块 `<插件 id>.grammars`（`grammarsExtension`）参与插件生命周期。`canActivateWithoutRestart` 扩展为：没有 `backend`，模块列表非空，且每个模块都是 `debugAdaptersExtension` 或 `grammarsExtension`，没有其他贡献。规则见 [插件免重启激活](2026-10-26-plugin-live-activation.md)。
- 实时安装的插件来自 `MacLivePluginRegistry`；启动时登记的插件跟随模块状态（停用、隔离、安全模式）变化。两者任何变化都会触发编辑器重新收到完整列表，撤回某个插件就是从列表里拿掉它。

### 运行标记是一个通用 Provider

- 清单写法是 `runMarkers[]: {languageID, function, command}`，每种语言最多一个 Provider。需要 `backend: 2`、`documents.read` 权限（函数会收到文档全文）和 `onLanguage:<languageID>` 激活事件；`command` 必须是插件自己的 `ui.commands[]`。
- 编辑器在文档变化后发 `pluginRunMarkers`，宿主把 `{languageID, path（工作区相对路径）, version, text}` 交给插件函数，超时 10 秒。超过 4 MiB 的文档和不在工作区内的文件不请求。
- 函数返回 `{markers: [{id, line, endLine?, kind, title}]}`，行号从 1 开始；`kind` 是 `run`、`test` 或 `testSuite`。Core 的 `run_markers.rs` 校验：结果最大 1 MiB，最多 1000 个，ID 最长 256 字节且不重复，标题最长 200 字符，行号不能超出文档，同一行不能有两个。任一项不合格就拒绝整个结果（`plugin.runMarkers.invalidOutput`），不画一部分；插件没有为该语言声明 Provider 时返回 `plugin.runMarkers.unavailable`。
- 返回时如果文档已经变了、Provider 已经撤回，宿主回 `cancelled`，编辑器丢弃结果。
- 点击按钮时宿主重新核对版本和 Provider，再用通用的 `runCommand` 执行插件命令，参数里带 `runMarker`。后端用 `version` 核对文档是否已被修改。只读的编辑器视图不允许点击运行。
- “智能识别”放在插件里：插件用自己熟悉的方式（正则、解析器、调用 LSP）找出可运行的位置，宿主只负责画按钮和转发点击。这样一个 API 就能覆盖任意语言的函数、类、测试，以及 `.http` 这类自定义格式。

## 考虑过的备选方案

- 让插件写 LSP 提供语义高亮：能用，但一个简单格式也要写语言服务器并随包分发，成本太高，用户明确不要依赖 LSP。
- 直接上 TextMate：表达力强、生态大，但需要 WASM 引擎和每文档行状态，内存更多；先做 Monarch，引擎靠 `kind` 字段保留切换余地。
- 宿主内置 HTTP 请求识别，或为测试、main 函数分别开识别 API：会在宿主里写插件专属逻辑，API 数量也会膨胀，因此改成一个通用 Provider。
- 用 CodeLens 表示运行入口：CodeLens 会占用行高，也和 Java 已有的行号旁运行按钮不一致，因此沿用运行标记的样式。
- 运行标记也做免重启：需要后端支持实时登记，属于后续的“后端热激活”，本次不做。

## 后果

- 插件可以只靠一份 JSON 配置给新格式加上高亮，安装、更新、停用、卸载都不需要重启。
- Monaco 不能注销已注册的语言。插件卸载后，它的语法不再更新，相关文件按纯文本显示；重启后语言消失。
- 插件声明内置语言 ID 时沿用已有的语言目录规则，同一语言有多个插件语法时按插件 ID 排序取第一个。
- 带 `runMarkers` 的插件安装后需要重启。
- Windows/Tauri 还没有插件后端和插件语法的宿主，这两项能力在 Windows 上标为缺失。
- `commands/didRun` 多了可选的 `runMarker` 参数。合并后要在 lithe-plugin-docs 同步契约，并跑一次两个 SDK 的端到端测试。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core plugin_grammars_run_markers`：语法限额、未知 kind、坏正则、越界路径，运行标记的重复行、越界行和数量上限。
- `scripts/architecture/verify-shared-contracts.sh`：契约 fixture，包括 `language-grammar.plugin.json`、`run-markers.plugin.json` 和无效清单。
- 在 `frontend/editor` 运行 `bun test`：`plugin-languages.test.ts` 和 `run-markers.test.ts`。
- `scripts/macos/test/test-macos.sh --filter "PluginEditorLanguagesTests|PluginLiveActivationTests|MacPluginBackendSessionsTests"`：免重启判定、实时语法的出现和消失、模块状态跟随、包外和超限语法、`runMarker` 参数。
- `scripts/macos/verify/verify-runtime-bundle-immutability.sh`：只从插件包读取语法，不向发行目录写入。

## 适用范围

适用于插件提供的语言语法、编辑器语言配置和编辑器运行标记。内置语言的高亮和 Java 的运行标记不受影响。以后加新的语法引擎、做后端热激活或在 Windows 上实现这两项能力时，先更新这份笔记。
