# Agent 笔记：插件宿主的编辑器打开、HTML 预览、外部浏览器与窗口消息服务

状态：已实现

## 先说结论

macOS 插件 API 计划里的 API-15（`editor.open/reveal`）、API-16（`preview.openHTML`、`browser.openExternal`）和 API-17 的最小部分（`window.showInformation/Warning/Error`）先在宿主里做成**内部服务**：一组 Swift 协议加实现，不对插件公开，也不碰插件契约。每次调用都必须显式带上“哪个插件、哪个窗口、哪个工作区（含代际）”，服务不会回退到“当前活动窗口”；资源用“根 ID + 工作区相对路径”表示，不收绝对路径。

三条最容易被改坏的规则：已经打开的文档，不管有没有未保存修改，都不会被磁盘内容替换；后台窗口的调用只在它自己的窗口里干活，不抢焦点；项目 HTML 和外部导航永远拿不到插件 bridge（页面与宿主通信的消息通道）。`editor.open` 用 `.select` 激活时，会像点击标签一样把文档切成前台标签，这是插件读选区、改文本前必须先做的一步。

后续 M0（激活与作用域协议）把这些服务接到插件调用分发和权限授予上；本篇不涉及授权，也不做错误码映射。

## 问题

计划里这几项能力都只写了“谁能调、该怎么限制”，没有写落在哪一层、什么情况下算越界。直接把 `AppModel`（一个项目窗口的总入口对象）暴露给插件调度有三个风险：

1. 插件调用拿到的是“此刻活动的窗口”。用户在调用过程中切换窗口或工作区，文件就会在错误的地方打开，或者消息弹到另一个项目里。
2. 打开文件的现成入口（`documentFeature.openFileAsync`）只负责加载，不负责“让标签到前台”，也不区分“已经打开且有未保存修改”的情况，需要在外面明确约定，不然插件会以为 `open` 之后文档就在前台。
3. 外部浏览器和 HTML 预览的边界不清楚：本地文件到底读磁盘还是读缓冲区、未保存时怎么告知、能不能传 `javascript:` 之类的地址，都没有定。

## 决策

### 1. 窗口端口加作用域闸门，服务只依赖协议

`PluginHostWindowPort`（一个窗口对宿主服务暴露的最小能力）由 `AppModel` 在 `AppModel+PluginHostWindow.swift` 里实现；`PluginHostWindowDirectory`（按窗口 ID 找窗口的目录）由 `ProjectSessionManager` 实现。服务只持有目录，每次调用先过 `PluginHostScopeGate`：

- 窗口不存在或没有工作区：`windowUnavailable`。
- 工作区是远程的：`remoteWorkspaceUnsupported`，在检查路径之前就拒绝，插件不会从错误信息里得知远端有哪些文件。
- 调用带的工作区路径或代际和窗口现状不一致：`workspaceChanged`。
- 所有会等待的步骤（加载文件、等编辑器回报输入、等用户回答）结束后再过一次闸门，窗口关了或工作区换了就失败，不再放置光标、不再启动浏览器。

闸门只弱引用目录，窗口关闭后服务不会让它残留。

### 2. 资源是“根 ID + 相对路径”，校验在规范化之后

`PluginHostResourceResolver` 先拒绝畸形路径（空、过长、以 `/` 开头或结尾、含控制字符、反斜杠、`.` 或 `..` 段），再按根 ID 找根目录，最后在符号链接解析后的路径上做“带尾部斜杠的前缀比较”。所以：

- `link/secret.txt` 指向工作区外，得到 `outsideWorkspace`。
- 兄弟目录 `/x/workspace-evil` 不会因为名字以 `/x/workspace` 开头而被放行。
- 返回给调用方的仍然是工作区自己的拼写（不是解析后的路径），这样已打开的缓冲区能按同一个路径匹配到。

### 3. `editor.open` 与前台标签

`PluginHostEditorService.open` 的顺序：闸门、选项检查（`tab == .preview` 当前不支持，明确拒绝，不降级成普通标签）、范围校验（行列从 1 开始，结束不早于开始）、解析资源、读打开状态、再过闸门、交给窗口打开、再过闸门、放置光标。

- 已打开的文档只会被激活，不会重新读盘。未保存的缓冲区保持原样，这是 API-15 的硬要求，对应测试 `anOpenDirtyBufferIsKeptAndNeverReloadedFromDisk`。
- `activation == .select`：加载（如需要）后调用 `selectEditorTab(.document(id))`，效果等同用户点击标签：跨编辑器分组、盖在 diff / 终端 / Agent 标签之上也会切到前台。结果里的 `document.isActive` 就是这个标签是否在前台。
- `activation == .background`：只保证文档已打开，不改前台标签，也不放光标。
- `reveal`：文件没打开时返回 `documentNotOpen`，不替插件加载文件。
- 范围只落到起点：编辑器的导航目标（`EditorNavigationTarget`）没有“结束位置”，所以插件传了范围也只放光标，结果用 `appliedSelection == .caret(起点)` 明说，不假装选中了。

“前台标签”和“前台窗口”是两件事。`isActive` 看标签：当前窗口的活动文档、没有 diff 盖着、聚焦的编辑器分组也指向它。窗口是否在前台来自 `snapshot.isForeground`，只放在结果的 `windowIsForeground` 里。后台窗口的调用会在自己的窗口里把标签切到前台，但不会提升窗口、不会激活应用。已知限制：Monaco 的 `navigate` 会让网页里的编辑器拿到 DOM 焦点，但不会提升窗口。

### 4. `preview.openHTML`

内嵌预览是文件自己的编辑器标签里的一个面板，吃的是编辑器的当前缓冲区，所以未保存的修改会显示在预览里（结果的 `usesLiveBuffer` 永远是 `true`，用来和系统浏览器对照）。服务只做两件事：检查扩展名是 `.html` / `.htm`（不区分大小写，否则 `notHTMLDocument`），再走 `editor.open` 的 `.select` 路径。“只显示预览”（`.previewOnly`）当前是每个标签视图里的 `@State`，服务没法设置，所以明确拒绝为 `unsupportedOption`。

### 5. `browser.openExternal` 与未保存状态

- 网址：只收 `http` / `https`，必须有主机名，不能带用户名或密码，不能含空白或控制字符，长度不超过 4096 字节，协议名会转成小写。`file:`、`javascript:`、`data:`、`lithe-plugin:`、`mailto:` 等一律是 `unsupportedURL`。服务不往地址里追加任何内容，也不执行脚本。
- 本地文件：只收工作区里的 `.html` / `.htm`，系统浏览器读的是**磁盘上的文件**。
- 未保存状态：先问窗口取文档状态，且要求窗口先让编辑器把还没交出来的输入报上来（`flushingEditor: true`）。`hasUnsavedChanges = document.isDirty || !editorConfirmed`：缓冲区脏，或者编辑器在 2 秒内没确认交完输入，都算“可能比磁盘新”。调用方用 `unsaved` 选择：`.openSavedFile` 照样打开并在结果里写明 `savedFile(hasUnsavedChanges: true)`；`.requireSaved` 直接返回 `unsavedChanges`，让插件先保存。没打开的文件没有缓冲区，视为没有未保存修改。
- 启动由平台适配器 `MacHTMLBrowserOpener.openWeb` 做：它自己再检查一遍协议和主机名，只向 Launch Services（macOS 的应用启动服务）问“谁处理这个地址”，再用那个浏览器打开，不会借道其他应用。适配器的失败统一映射成 `browserUnavailable`；任务取消照原样抛出。

### 6. HTML 预览与外部导航没有插件 bridge（已核对）

插件 bridge 只存在于 `MacPluginWebPage`：消息处理器 `lithe` 注册在 `.page` 世界，自定义协议 `lithe-plugin` 也只在这里注册。内嵌 HTML 预览用的是全新的 `WKWebViewConfiguration`，它唯一的脚本消息处理器是 `litheScrollbarFrame`，注册在 `HTMLPreviewScrollbars.contentWorld`（应用自己的内容世界），项目页面的脚本世界里看不到任何 `window.webkit.messageHandlers.*`。`litheEditor` 只在 Monaco 的 `lithe-editor` 配置上。导航策略 `HTMLPreviewNavigationPolicy` 取消 `file:` 和未知协议；外部浏览器是另一个进程，天然没有 bridge。

结论是不需要修代码，只加回归测试：`HTMLPreviewBridgeIsolationTests` 在真实的预览 web view 里探测页面世界的三个处理器名都是 `undefined`，同时用应用世界里的 `object` 作为对照，证明探测方法本身有效；另一个用例断言预览配置里没有 `lithe-plugin` 的协议处理器。以后给预览配置新增脚本处理器或协议处理器，这两个测试会失败。

### 7. 窗口消息单独做一个模型和视图，原样显示

宿主的通知栈会翻译文案和键，而插件的文字和按钮必须原样显示，所以插件消息不走它：每个项目窗口有一个 `PluginHostMessageFeatureModel`（挂在 `AppModelFeatureGraph.pluginMessages`），`WorkbenchView` 左下角叠一个 `PluginHostMessageStack`。

- 同时最多显示 3 条，其余按顺序排队；用户点按钮返回 `selected(index:)`，关闭返回 `dismissed(.user)`；窗口关闭或工作区替换时，显示中和排队中的消息都以 `dismissed(.windowClosed / .workspaceChanged)` 结束；调用方任务被取消则以 `dismissed(.cancelled)` 结束，不留悬空的消息。每条消息恰好结束一次。
- 限额：同一个插件对同一个窗口，每 10 秒最多 5 条；同一个插件在同一个窗口最多 3 条在显示或排队；同一个窗口最多 10 条；文字最多 2000 个字符，按钮最多 3 个、每个最多 40 个字符；文字只允许换行和制表符这两种控制字符，按钮不允许任何控制字符。超出频率返回 `rateLimited`，同时向用户用宿主通知提示一次“某插件发送消息过快”（同一窗口同一时间窗内只提示一次，宿主文案走 `L10n.string` 和 `shared/i18n/`）；超出队列返回 `messageQueueFull`。
- 时间由调用方注入（`now`），限频逻辑 `PluginHostRateLimiter` 是纯值类型，测试不需要等待。

### 8. 运行期不写发行包

这些服务只读磁盘元数据（`FileStorage.metadata`）、读写内存状态、向 Launch Services 查询并启动浏览器，不创建任何文件。浏览器打开的是用户工作区里的 HTML，不涉及 `Contents/Resources`、插件目录或安装目录，不影响代码签名与 Sparkle 增量更新的基线。因此不新增资源路径，也不需要新增 bundle 哈希验证；`scripts/macos/verify/verify-runtime-bundle-immutability.sh` 照常覆盖。

### 正确做法

- 新服务一律从 `PluginHostCallContext` 取窗口和工作区，进入时过一次 `PluginHostScopeGate`，每次 `await` 之后再过一次。
- 要让标签切到前台，调用 `.select`；要读选区或编辑前，先确认 `isActive`。
- 要给用户看插件的原话，走 `PluginHostMessageFeatureModel`；宿主自己的文案走 `L10n.string`。

### 不要这样做

- 不要在服务里读文件内容或用磁盘内容覆盖已打开的缓冲区。
- 不要在 `AppModel` 之外的层引用“当前活动窗口”。
- 不要把预览 web view 的配置和 `MacPluginWebPage` 的配置共用，也不要给预览加消息处理器。
- 不要因为某个插件的名字写分支；这些服务对所有插件一视同仁，差异只来自调用上下文和后续的授权。

## 考虑过的备选方案

### 备选方案一：直接让插件调度调用 `AppModel`

最省事，不用多写协议。没有采用，因为 `AppModel` 面太宽，无法保证每个调用都显式带窗口和代际；协议化以后，服务可以用假窗口测试所有“窗口在等待期间消失”的路径，这些路径靠真实 UI 很难稳定复现。

### 备选方案二：把插件消息放进宿主通知栈

少一个视图和模型。没有采用，因为通知栈会翻译文案、合并重复项并按宿主规则自动消失，而插件消息必须原样显示、带按钮、等用户回答，并且要按窗口和插件限额。

### 备选方案三：`.preview` 标签和 `.previewOnly` 先做近似实现

可以把 `.preview` 当普通标签、`.previewOnly` 当并排预览，插件调用不会失败。没有采用，因为近似实现会让插件以为得到了可替换标签或纯预览，之后一旦真实支持就是行为变更。现在明确返回 `unsupportedOption`，等编辑器有可替换标签和可设置的预览模式后再放开。

### 备选方案四：外部浏览器打开前强制保存

最不容易让用户困惑。没有采用，因为保存会改磁盘文件，不应由一次“打开浏览器”的调用静默触发；改为让调用方选择 `.openSavedFile`（明说未保存）或 `.requireSaved`（先保存再来）。

## 后果

- 收益：窗口和工作区在每个等待点都被复核；已打开文档的未保存修改不会丢；外部浏览器的可启动目标有明确的白名单；预览与插件 bridge 隔离有回归测试守着。
- 代价：多了一层协议和假对象；范围只落到光标；没有可替换的预览标签；消息堆叠在左下角，可能盖住左侧工具栏的一部分。
- 已知限制：路径检查和打开之间存在竞态（先检查再打开，之间文件可被替换成指向外部的链接）；大小写或 Unicode 规范化不同的路径别名可能产生第二个缓冲区；媒体和二进制文件返回 `openFailed`；`loadFile` 失败时可能在目标窗口弹出“无法打开”的通知。
- 需要重新评估的触发条件：编辑器支持范围选择或可替换预览标签；预览配置新增脚本处理器；窗口之外的文件根（多根工作区）进入 `PluginHostRoot` 列表。

## 验证

- `./scripts/agent-notes/verify-agent-notes.sh`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `node scripts/i18n/generate-i18n.mjs --check`
- `macos/Tests/LitheTests/` 下的 `PluginHostEditorServiceTests`、`PluginHostBrowserServiceTests`、`PluginHostMessageServiceTests`、`HTMLPreviewBridgeIsolationTests` 和 `HTMLBrowserOpenerTests`（需要在 Mac 上用 `xcodebuild test` 运行）。

## 适用范围

- `macos/Sources/Lithe/Application/Features/PluginHostScope.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostEditorService.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostPreviewService.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostBrowserService.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostMessageService.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostMessageFeatureModel.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostEditorFlush.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostWindowServices.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+PluginHostWindow.swift`
- `macos/Sources/Lithe/Models/Workspace/ProjectSessionManager+PluginHost.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacHTMLBrowserOpener.swift`
- `macos/Sources/Lithe/Views/Workbench/PluginHostMessageStack.swift`
- `macos/Tests/LitheTests/HTMLPreviewBridgeIsolationTests.swift`
