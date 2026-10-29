# Agent 笔记：调试控制台的命令输入行与插件补全

状态：已实现

## 先说结论

调试控制台（Debug Console，底部显示程序输出和调试器回显的面板）现在在输出下方有一条独立的**命令输入行**（`>` 提示符），调试器命令只在这一行输入；程序自己的标准输入仍然走输出末尾的行内输入，两者不混用。输入时用 DAP `completions` 请求（DAP，Debug Adapter Protocol：编辑器与调试后端之间的标准协议；该请求让调试器自己补全）向适配器要候选，同时合并插件在 `debugAdapters[].console.commands[]` 里声明的命令清单，用类似终端补全的弹层展示。

开发者最需要记住三点：补全是**纯数据**注入，插件只声明命令名和一句说明，宿主不按插件名写分支；适配器给出的补全优先，清单只补它没覆盖的命令；候选替换哪一段输入由一条固定规则决定（见“决策”），改规则要同时改 Swift 测试。

## 问题

用 lldb-dap 调试 C 程序时，用户在控制台输入 `ls` 得到的是一段看不懂的表达式错误，而且输入位置不明显：

- 旧界面把调试器命令和程序 stdin 共用输出末尾那一行，用户分不清这一行是在给调试器说话还是在给程序喂输入。
- 没有任何补全。lldb 有几百条命令，用户记不住 `frame variable`、`thread step-over` 这类多词命令。
- 控制台只在暂停时能执行调试器命令，但界面没有说明为什么不能输入。

## 决策

### 正确做法

- **输入行归宿主，补全内容归适配器和插件。** `DebugConsolePane`（`macos/Sources/Lithe/Views/Debug/DebugConsolePromptView.swift`）画输入行和弹层，不认识任何具体调试器。候选来自 `GenericDebugFeatureModel.requestConsoleCompletions`，只在会话处于 `paused` 时发请求，否则返回空列表。
- **补全请求走 Rust Core。** `debug.inspect` 的 `completions` 类型由 Core 校验并转成 DAP `completions`：适配器没有协商 `supportsCompletionsRequest` 时直接拒绝；`text` 不能为空；`column` 是 1 起算的 UTF-16 单位，越界会被拒绝。Swift 侧的光标是 0 起算，由 `CoreDebugAdapterProtocolSession` 统一加 1，其他地方不要再换算。
- **插件声明命令用 `debugAdapters[].console.commands[]`。** 每项只有 `name` 和可选 `description`，按名称排序、不重复、数量和长度有上限，违反时安装校验直接拒绝（`shared/contracts/plugins/v1/fixtures/debug-adapter-rejections.json` 有对应用例）。清单按“整行前缀”匹配，已经完整输入的命令不再提示。适配器会实时补全时（如 lldb-dap）清单只用来补它没覆盖的命令，同名候选只显示一次，适配器的顺序在前。
- **候选替换哪一段，规则固定。** 适配器给了 `start` / `length` 就照它的；没给（lldb-dap 就不给）时，替换“输入末尾与候选开头重合的最长一段”，忽略大小写；一点都不重合则在光标处插入。这条规则在 `DebugConsoleCompletion.swift`，有 10 条测试固定。改它要同时改 `DebugConsoleCompletionTests.swift`。
- **插件可以声明命令前缀，宿主只搬运不理解。** lldb-dap 在行首会把 C++ 关键字和类型（`long`、`int16_t`、`const`）和命令混在一起，这些词一执行就是 `evaluate` 失败；在行首加反引号它才只返回命令。这个差异属于适配器，所以由插件在 `debugAdapters[].console.commandPrefix` 里声明（1–8 个字符，不含空白和控制字符，可以和 `commands` 同时出现，两者至少有一个）。宿主只在发补全请求时把前缀拼到整行前面（行首已有就不拼），光标按前缀的 UTF-16 长度后移，适配器回来的 `start` / `length` 再减回去（`DebugConsoleCompletion.adapterRequest` / `restoring`）。用户看到和执行的行永远不带前缀。代价是行首位置拿不到变量名补全，`p to` 这类带命令的输入不受影响。
- **候选说明只取第一行。** lldb-dap 把整段帮助文字拼进标签，弹层一行放不下；`DebugConsoleCompletion` 取第一个非空行作为说明，完整文字不进弹层。
- **按键语义。** 输入时自动弹出；Tab 先把输入补到所有候选的公共前缀，没有可补的再填入高亮项；上下方向键在弹层打开时移动高亮，关闭时翻历史；Esc 关闭弹层；Enter 默认直接执行输入的整行，只有用户**自己移动过高亮**（方向键、Shift-Tab、点击）才改为填入高亮项再执行。这样用户输入完整命令后按 Enter 不会被一个排在第一位的候选劫持。
- **文案走统一 i18n。** 占位符、无障碍标签和弹层底部按键提示都在 `shared/i18n/` 里有中英词条；候选名称和说明是插件和适配器的内容，原样显示，不翻译。
- **新输入行的状态要说清楚。** 没有会话、会话未暂停、可以输入三种占位符分别提示原因；不能执行时按 Enter 会提示“暂停程序后才能执行调试器命令”，输入留在框里。

### 不要这样做

- **不要在宿主里按适配器名添加命令表。** lldb 的命令清单属于 lldb 插件的 `plugin.json`；宿主里出现 `if adapter == "lldb"` 这类分支，换一个调试器就要改宿主；宿主只认声明的数据，能力版本规则见[插件能力版本](../architecture/2026-10-17-plugin-capability-versions.md)。
- **不要在宿主里把某个适配器的怪癖写成分支。** “行首先加反引号”是 lldb-dap 的行为，写在宿主里换一个适配器就是错的；它只能是插件声明的数据（`commandPrefix`），宿主不检查前缀内容的含义。
- **不要把补全请求发给没协商能力的适配器。** DAP 规定客户端只能发送适配器声明支持的请求，所以由 Core 在发送前按能力门控，而不是发出去等错误。
- **不要用行内 stdin 输入承载调试器命令。** 行内输入只属于被调试程序的标准输入，用户在这里输入的内容会进程序，不会进调试器。
- **不要在程序运行中把补全当成可用。** 程序运行时，调试器通常不能在当前栈帧上求值，`evaluate` 和 `completions` 没有可用的上下文；界面在非暂停状态直接禁用命令执行，不靠请求失败来告诉用户。

## 考虑过的备选方案

### 备选方案一：沿用输出末尾的行内输入，只加补全

改动最小，也和 IDEA 控制台的 `>>>` 提示符一致。没有采用：行内输入同时承载程序 stdin 和调试器命令，用户无法判断输入会去哪里，这正是旧界面“不明显”的原因。现在行内输入只保留给程序 stdin，调试器命令在底部输入行，结构上对齐 VS Code 的 Debug Console。

### 备选方案二：只靠适配器的 `completions`，不要插件清单

少一个契约字段，补全永远和调试器版本同步。没有采用：`completions` 是 DAP 的可选能力，不是每个适配器都实现；实现了的适配器返回的候选也不一定带说明文字（lldb-dap 把说明拼在标签里）。清单是可选的纯数据，实现 `completions` 的适配器可以不写。

### 备选方案三：补全清单做成插件脚本回调

候选可以随上下文动态变化。没有采用：会让宿主在输入的热路径上调用插件进程，补全延迟不可控；纯数据足够覆盖命令名补全，动态内容由适配器的 `completions` 提供。

### 备选方案四：新增 `debugAdapters` 的 v2 能力版本

字段增加算契约变化，版本号看似更严谨。没有采用：`console`（含 `commands` 和 `commandPrefix`）是可选字段，旧插件不受影响，且插件 API 4 尚未发布，直接在 `debugAdapters` v1 内增加；已发布的版本以后再改要走新的能力版本。

### 备选方案五：在宿主里过滤适配器返回的“非命令”候选

不需要新字段，宿主看到不像命令的候选就丢掉。没有采用：宿主无法可靠区分 `long` 是类型还是某个调试器的命令，只能靠按适配器名写规则，等于把 lldb 的行为固化进宿主；让适配器自己只返回命令（前缀）更准确，也不丢掉其他适配器的合法候选。

## 后果

- 收益：调试器命令和程序输入在界面上分开；插件只写数据就能让用户得到命令补全；Windows 以后复用同一个 Core 请求，只需要实现自己的输入行。
- 代价：契约多了 `console.commands[]` 和 `console.commandPrefix`，`shared/contracts/plugins/v1/` 合并后要在 lithe-plugin-docs 运行 `node scripts/contract.mjs sync` 同步副本；弹层是叠加在 AppKit 输出视图上的 SwiftUI 视图，绘制顺序依赖当前的叠加方式。
- 需要重新评估的触发条件：Windows 端要做同样的输入行；适配器开始返回带 `start` / `length` 的补全并和宿主规则冲突；候选数量超过 60 条仍需要滚动浏览。

## 验证

- `./scripts/macos/test/test-macos.sh --filter LitheDebugModuleTests`
- `./scripts/macos/test/test-macos.sh --filter 'DeclarativeDebugAdapterConsoleTests'`
- `cargo test --manifest-path rust/lithe-core/Cargo.toml console_completions`
- `./scripts/architecture/verify-shared-contracts.sh`
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `macos/Sources/Lithe/Views/Debug/DebugConsolePromptView.swift`
- `macos/Sources/LitheDebugModule/Application/DebugConsoleCompletion.swift`
- `macos/Sources/LitheDebugModule/Application/DebugConsolePromptModel.swift`
- `macos/Sources/LitheDebugModule/Application/GenericDebugFeatureModel.swift`
- `macos/Sources/LitheDebugModule/Runtime/CoreDebugAdapterProtocolSession.swift`
- `rust/lithe-core/src/debug/engine.rs`
- `shared/contracts/plugins/v1/`
