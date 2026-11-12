# Agent 笔记：独立的插件高亮、编辑器动作与编辑器 Provider API

状态：已实现

> Viva 迁移状态：下文的 Monaco 注册、动作和 Provider 接线及 `languages:2` 描述属于旧客户端。当前锁定的 Core 契约使用 `languages:3` TextMate；Viva 只有静态语法解码桥接和共享样例验证，插件安装、编辑器注册及动作/Provider 宿主均未接入。旧版的权限隔离、版本检查与不透明链接限制仍是后续验收要求。

## 先说结论

普通工具插件可以独立提供文本高亮、编辑器配置、位置动作和编辑器语言功能（跳转、悬浮、补全、CodeLens、折叠、语义着色、文档链接），不要求实现 LSP（语言服务器协议）、构建、运行或调试提供者。静态资源使用 `languages:2`；位置动作与语言功能都通过函数协议 3 的独立宿主方法注册，再复用原有函数调用执行；没有 `runMarkers` 清单能力，也不修改 `commands/didRun`。语言功能只“补充”语言服务器：服务器先答，插件的答案只增加不替换。当前接线限 macOS，运行和界面验收以功能矩阵为准，不把静态校验当作产品验收。

## 问题

HTTP 工具插件需要高亮和请求旁的按钮。原方案把按钮建模成专用运行标记，并向通用命令通知加入 `runMarker`，扩大了无关领域的兼容面。用户确认[独立能力与领域边界](2026-10-31-plugin-capability-and-domain-boundaries.md)：宿主理解动作的有限展示结构，插件理解 HTTP/SQL 等业务，不能因为按钮像播放图标就归入 Run。

## 决策

### 静态高亮与后端业务分离

语法和注释/括号配置属于安装包内只读资源，通过独立编辑器模块启用；不要求语言服务器或后端。仅配置贡献也应用，编辑器模块不抢占已有语言的运行、调试和服务器所有权。纯静态资源可安装、停用和卸载即时生效，带后端的插件继续遵循既有启动登记规则。没有 UI 或领域模块的独立后端派生应用级启用模块，不能为通过 catalog 检查伪造网页；启动仍检查明确启用、安全模式和隔离状态。

复用已固定版本的 Monaco Monarch 引擎，不在 Core 重写词法分析。Core 校验资源大小、状态和规则，并拒绝 include 环及展开后超过预算的图；浏览器中的专用 worker 才编译和执行插件正则，主线程只接受 token。worker 超过本地执行期限时终止，该语言退为普通文本，不影响编辑与保存。现有 TextMate/Oniguruma 已打包，不以“需要新增 WASM”作为否决理由；首版选择 Monarch 是局部数据适配，不改变 Java 的 TextMate 工作流。

Monarch 的 `cases` 按声明顺序执行，不能把语法当成无序字典重建。Core 校验后返回原始 JSON 文本，Swift 和浏览器主线程只传递文本，worker 才解析并在缺少 `start` 时显式使用 `root`。仅贡献配置的 `properties`、`bash` 等语言保留独立文档身份，但借用既有 `ini`、`shell` tokenizer；撤回配置只释放借用登记，不销毁上游引擎。

### 编辑器动作是小型独立契约

后端先注册普通函数，再通过 `editor/registerActions` 注册上下文、文件选择器和收集函数。宿主返回既有 subscription，由会话、上下文或显式释放共同清理。注册时只记录绑定，下一事件轮才请求解析，避免后端等待宿主注册答复、宿主又等待同一后端的循环。

宿主向收集函数提供公开文档身份、内容版本和当前脏缓冲。返回范围、标题、受限图标和同插件函数绑定；Core 只校验结构和 UTF-16 边界，不解释请求、查询、框架或任务 ID。多个同一行动作进入同一菜单，不制造测试种类或覆盖为只剩一个动作。

正确做法：HTTP 的“发送请求”和 SQL 的“执行查询”都返回同一展示结构，分别绑定自己已有的普通函数。不要这样做：新增 `http`/`sql` 执行类型、把请求包成假 Build 任务，或者要求工具插件提供 LSP CodeLens。

点击时浏览器只回传宿主生成的批次和动作键，不能提供函数或业务参数。宿主重新验证内容版本、上下文、注册租约与会话函数，再用已有 invocation 调用；插件收到文档身份、预期版本和自己的不透明数据，执行前核对当前文本。命令通知保持原样，命令面板可调用同一插件业务实现。

### 动作版本 2：同一行的多个图标、替代项与点击后展示位置

IDEA 里一行可以同时有“运行”、“调试”、“测试通过/失败”和“跳到父方法/实现”这类图标。版本 2 在不新增方法的前提下，让 `editor/registerActions` 表达它们：

- 图标来自宿主声明的图标表（`getCapabilities` 的 `services.editor.options.actionIcons`，macOS 目前是 `run`、`run-all`、`debug`、`test`、`test-passed`、`test-failed`、`test-skipped`、`navigate-super`、`navigate-implementations`）。插件不能提供自己的 SVG；表外的图标名由 Core 拒绝。表和网页里 `editorActionIcons` 的键必须一致，`scripts/architecture/verify-editor-boundaries.mjs` 会检查。
- 运行类图标画在行号右侧，导航类图标画在行号左侧，两条车道各自排列；同一行的多个动作仍进入同一个菜单。
- 一个标记可以带至多 4 个 `alternatives`（例如“运行 main”旁边的“调试 main”“测试此包”），各有自己的图标、标题和函数绑定。点击回传的仍然只是宿主生成的批次、动作键，外加备选项键。
- 动作函数的返回值可以带 `reveal`（1 到 100 个 LSP 位置），宿主把它展示出来（单个位置直接打开，多个位置用现有的导航列表）。返回值的其他成员属于插件自己，宿主不解释。这是“导航类图标点击后去哪里”的通用答案，宿主不需要知道 Spring 或 MyBatis。

测试标记与测试结果不新增任何测试专用契约：插件用 `test`、`test-passed`、`test-failed`、`test-skipped` 图标画状态和入口，点击后执行仍走 API-29（Maven/Gradle 等构建插件负责测试发现与运行，语言插件的点击函数调用 `lithe/build/*` 或 `lithe/host/run|debug/start`；插件之间互相调用函数要等 API-35）。图标只负责画状态，宿主不会因为一个图标自己启动任何东西；运行结果显示在宿主的运行/调试窗口和原生测试面板里，不由编辑器图标承载。

### 生命周期与兼容

动作刷新只确认已调度，不能等待插件返回后才结束编辑器桥接调用。整批收集共享八秒期限，各注册只拿剩余预算；失败不进入编辑、保存同步的致命错误路径。模块状态观察者弱引用运行时，避免事件源持有回调、回调又持有事件源，导致关闭项目后模块图不能释放。

编辑立即撤销旧动作，取消旧收集任务，防抖后再请求；关闭、替换和失效结果均不得恢复旧按钮。解析和用户执行分开管理，后者不因重新解析被误取消；撤销注册、关闭上下文或会话结束时取消所属执行，不自动重试 HTTP 等副作用。

新宿主方法在已支持增量能力发现的函数协议 3 内新增，不提高整套协议或新增领域版本。新增 `editor.actions` 权限由安装审查明确确认，旧宿主不认识时拒绝安装；不能一边要求新权限、一边宣称同一包能在旧宿主无条件降级。静态清单新增资源仍要求 `languages:2`；契约、fixture 与两个 SDK 的验证和合并后镜像同步不能省略。

第一版使用既有 `onWorkspaceOpen` 启动，接受其后台成本。不会通过尚未存在的注册信息发现一个未启动的后端，也不假称已支持按文件懒启动或后端热安装。

### 资源生命周期

grammar 从只读插件包有界读取，校验结果仅在本次进程内缓存；编译后的状态与文档 token 属于一个 worker，终止/停用时释放，不落盘。worker 代码复用本工作树生成的 `textmate-worker.js`，应用运行时只读；编辑器动作和租约也仅在内存。没有 bundle、安装资源或跨工作树缓存写入，不影响签名及 Sparkle 增量基线。

## 考虑过的备选方案

- 要求工具插件提供 LSP：标准化但无必要地强加语言服务生命周期，拒绝。
- 专用 `runMarkers` 和 `didRun.runMarker`：把展示和执行耦合，新增一种动作就扩张执行通知，拒绝。
- 函数名约定或插件名分支：宿主猜私有协议且无法安全撤回，拒绝。
- 首版做任意样式装饰/万能工具工作流：超出当前需求；仅开放范围、标题、图标与函数绑定。
- 直接在主线程运行语法：长度限额不能阻止病态回溯，采用可终止 worker。
- 让工具插件把 Provider 注册成一个语言服务器：强加服务器生命周期和文档同步，而且无法表达“只补充”，拒绝。
- 让插件的答案覆盖语言服务器：会让一个补充性的小插件破坏上游语言能力，拒绝；语义着色因此也只在服务器没有答案处生效。
- 把插件返回的 URL 或命令直接交给 Monaco：`command:` 链接会被 Monaco 执行，拒绝；页面只持有不透明键。
- 为测试标记新增测试专用契约：测试发现和运行已经是 API-29 的职责，编辑器只需要多种图标，拒绝。
- 允许插件提供自己的图标 SVG 或 CSS：等于向编辑器注入界面，拒绝；改为宿主声明图标表。
- 把诊断放进 Provider 通道：诊断是推送式集合，要有版本、撤回和合并语义，留给 API-26 单独设计。

## 后果

收益是工具插件不污染领域模型，执行复用现成函数基础设施。代价是增加一个明确授权的独立编辑器贡献契约，需要跨语言校验与生命周期接线。首版不支持远程、只读预览动作，也不承诺任意大型文档的插件高亮；Windows 产品接入和完整界面验收仍需后续完成。Provider 通道额外增加一个权限（`editor.providers`）、每次触发后的并发询问成本（由各类型的答题期限限制）和一套页面与宿主的不透明键协议；换来的是 Java 之外的工具（Spring、MyBatis 的跨文件能力，或 Go、`.http`）不必为了一个按钮或跳转实现整台语言服务器。早先 Java 专用的运行标记与宿主分支是这个通用契约要取代的对象，它们的删除不在本契约的改动里。

### API-25：Provider 通道补充语言服务器，不替代它

后端先注册普通函数，再调用 `editor/registerProviders`（权限 `editor.providers`，同时需要 `documents.read`），给一个文件选择器（语言、扩展名、文件名，三者任一命中即可）绑定若干类型的函数：`definition`、`hover`、`completion`、`codeLens`、`foldingRange`、`semanticTokens`、`documentLink`。和动作注册一样，注册时只记录绑定；询问发生在之后的事件轮，插件通过 `documents/getSnapshot` 读取预期版本的文本再回答。

**宿主与 Core 的分工。** 宿主不认识任何语言，也不解释插件的数据：

- Core 校验注册（选择器必须命中点什么、类型必须是宿主声明的、语义着色必须带 legend）并规范化每种答案的形状。补全只保留展示和编辑信息，丢弃 `data` 和 `command`，因此没有“解析补全”往返，也不会通过补全执行命令；CodeLens 只能带一个同插件的函数；文档链接目标必须是绝对 URL。
- 每种类型的答题期限由宿主决定，插件不能自带 `budgetMs`：悬浮和补全 400 毫秒，跳转 1500 毫秒，其余 2000 毫秒。超时、失败、形状不对、文档已经变化或注册已被撤回的答案一律安静丢弃，只写 `PluginsEditorProviderFailed` 日志。
- 同一个文件上所有匹配的注册并发询问；补全的触发字符只会问到声明过该字符的注册。

**合并规则（语言服务器优先）。**

- 悬浮和补全：宿主在 Monaco 里把插件当作另一个 Provider，由 Monaco 自己合并多个来源的结果。宿主自己的悬浮、补全 Provider 也注册在 `*` 上；Monaco 对得分相同的 Provider 把后注册的排在前面，所以插件 Provider 必须先于宿主 Provider 注册，宿主的答案才排第一。
- 跳转：语言服务器先答，插件的位置追加在后；重复位置只保留一个；服务器只指回光标所在符号本身时让位给插件（区间终点不含）。这个规则在 Core 的 `mergeDefinitions` 里，Swift 只照着保留下标取值。修饰键点击、F12 和原生 Go to Definition 命令（菜单、命令面板、快捷键）走同一个查询和合并；文件没有语言服务器跳转时只展示插件的位置。
- 跳转结果在展示前再核对一次文档版本：查询结束和等待它的调用方恢复是两个事件轮，中间可能有编辑。版本变了就丢弃插件位置，语言服务器的答案照常展示。
- 修饰键悬停判断“是否可点”时，只有语言服务器说没有跳转才问插件；同一个窗口同时最多一组插件跳转查询在跑，新的悬停取消上一组，上一次悬停迟到的服务器答复也不能再发起查询。
- CodeLens、折叠、文档链接：直接追加。
- 语义着色：只在语言服务器没有语义着色的位置生效。Monaco 0.55.1 里 `*` 选择器的 Provider 得分低于具体语言的 Provider，因此插件的 `*` 注册不会盖过服务器。
- 只读预览不询问插件：页面 Provider 路由和原生跳转路由（`definitionHover`、`definition`）都按 `isReadOnlyPreview` 跳过插件，预览里只看语言服务器的跳转。

**页面不接触插件的目标。** 网页只收到宿主生成的批次和条目键（UUID），点击 CodeLens 或链接时回传这些键，宿主在自己的表里找到真正的函数、参数和目标。文档链接在 Monaco 里画成不透明的 `lithe-plugin-link:/<批次>/<键>`，并由页面登记的 opener 先于 Monaco 默认处理拦截：Monaco 的链接检测会以 `allowCommands: true` 打开 `command:` 链接，如果把插件给的 URL 直接交给它，插件就能让编辑器执行任意命令。宿主只打开 http/https 和工作区内的 `file:`。

**错误码。** 不认识的类型是 `plugin.host.unsupportedOption`（`details.option` 为 `providers.<类型>`，包括 `diagnostics`、`signatureHelp`），其余注册错误都是 `plugin.host.invalidParams`；重复 ID 是 `preconditionFailed`，每个插件最多 32 个注册（`limitExceeded`）。没有新增错误码。撤回某个函数会使该插件的全部注册失效，插件必须显式重新注册，复用的函数 ID 不会让旧绑定复活。

**不做什么。** 诊断是推送式集合，属于 API-26，不在 Provider 里；符号、格式化、重命名、Code Action、签名帮助、内联提示尚无绑定；运行期传入 JSON 注册高亮也没有。当前 worker 对超过 128 Ki UTF-16 单位或 10,000 行的文档保持普通文本，嵌入语言也按普通文本处理。

正确做法：一个“资源 key 在模板和 `.properties` 之间跳转”的插件注册 `definition`、`hover`、`completion` 三个函数，选择器写 `html` 和 `properties`；语言服务器照常提供模板的普通跳转，插件补上 key 的跳转。不要这样做：在宿主里按语言名加分支，或让插件返回 `command:` 链接让页面去执行。

## 验证

- 旧版 Core、Monaco 与 macOS 的测试覆盖静态资源及预算、动作和 Provider 注册与撤回、查询过期处理、不透明链接和语义着色合并；测试命令和原证据见[历史记录](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md)，不能作为 Viva 已通过的证据。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^TestPluginTextMateGrammarUsesPinnedCore$'`：当前共享语法样例经锁定 Core 解码；不证明插件安装和编辑器注册。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：发行路径只读静态边界。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/grammar.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/grammar.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/editor_actions.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/editor_actions.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/editor_providers.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/editor_providers.rs)
- `desktop/internal/core/plugin_session.go`
- `desktop/internal/core/plugin_session_test.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/README.md`
- `shared/platform-feature-matrix/features/plugin-editor-grammars.json`
- [旧版实现和原适用范围](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md)
