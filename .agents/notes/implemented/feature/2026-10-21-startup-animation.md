# Agent 笔记：两端统一的启动阶段反馈（启动动画）

状态：已实现

## 先说结论

Lithe 启动期间会显示品牌 Logo、当前启动阶段的文案和进度百分比，阶段用同一份共享契约定义，Windows 和 macOS 用词一致。启动很快时这段动画完全不出现，也不给就绪时间增加任何额外耗时；就绪后动画淡出，失败时保留失败阶段和原因，直到用户确认。Windows 端用**独立的原生启动窗口**，这个窗口的页面不加载 React 和工作台打包产物，所以点击后立刻就能看到画面，同时主窗口在工作台就绪前不显示，原来的白屏也就没有了；macOS 端保留主窗口，用居中的圆角卡片覆盖层呈现同样的视觉结构。开关默认开启，用户可以在设置里关掉；关掉后既不显示动画，也不改变启动速度。

## 问题

Issue #1391 提出的现象是：主窗口已经出现，但内容区域长时间空白，没有任何加载提示。冷启动要做的事情很多——插件加载、语言服务初始化、工作区打开、恢复上次会话——磁盘慢、项目大或系统繁忙时等待更久，用户无法区分"正在启动"和"已经卡死"。两端表现还不一致：macOS 是窗口空白，Windows 是先白屏一次。

两端当时都没有可复用的启动阶段模型：macOS 的重活全部同步发生在 `LitheApp.init()` 里，窗口出现时插件扫描已经结束；Windows 已有 `StartupMilestone` 里程碑打点，但那是日志用的，不带用户可见文案，也和 macOS 没有对应关系。

## 决策

- 启动阶段是一份**跨平台契约**，写在 `shared/contracts/startup-feedback-v1.md`，配套 `shared/contracts/startup-feedback-v1.schema.json` 与 `shared/fixtures/settings/startup-feedback-v1.json`。契约只放平台中立的阶段 ID、顺序、文案和时间常量，不放 UI 状态；`shared/contracts/application-boundary.md` 里补了 Startup Feedback Contract 章节作为总入口。
- 阶段固定为五个，顺序固定：`preparing`（准备）、`loadingPlugins`（加载插件）、`initializingLanguageServices`（初始化语言服务）、`openingWorkspace`（打开工作区）、`restoringSession`（恢复上次会话）。这是一个**产品级粗粒度步骤**，用来回答"现在卡在哪一步"。语言服务器内部的细粒度阶段继续用 `shared/fixtures/lsp/project-preparation-v1.json` 的词汇，两套词汇不要互相替代，也不要为启动动画再造第三套。
- 启动阶段状态只有四个：`idle`、`loading`、`ready`、`failed`，和 `shared/contracts/application-boundary.md` 里"每个异步操作都要暴露这四种结果"的规则一致。
- 时间常量也进契约：`minimumVisibleDurationMs` 为 400，`fadeOutDurationMs` 为 180。
- **进度百分比也进契约**：每个阶段带一个 `progress`（准备 10、加载插件 30、初始化语言服务 50、打开工作区 72、恢复上次会话 88），就绪时到 100。进度条必须显示契约里的真实数值，不要用"定时器慢慢往前爬"的假进度：假进度会给出"卡在某个百分比"的错觉，而且和真实阶段对不上，用户会认为产品坏了。
- **Windows 端用独立启动窗口**：setup 开头就创建这个窗口，页面是独立静态入口 `windows/tauri/startup-splash.html`，配套 `windows/tauri/src/startup-splash.ts`，**不引入 React，也不加载工作台打包产物**。这条是踩过坑之后定下来的：先前让启动窗口复用 `index.html` 和工作台代码，结果它要先下载并解析整个工作台 bundle，点击之后 1.75 秒才出现画面，比不显示还糟。窗口本身是透明无边框的，圆角卡片由前端 CSS 画出来，这样才有"独立卡片浮在桌面上"的观感；用不透明深色窗口加前端圆角会看到方形黑边。
- **启动快就完全跳过**：从**应用启动**开始计时，400 ms 内就绪则动画一次都不显示，也不留下任何定时器；超过 400 ms 仍未就绪，才显示动画。计时基准是应用启动而不是窗口出现的时刻，否则窗口晚出现时会被重新计一次等待。动画只是反馈层，永远不能推迟就绪时间。
- **窗口出现前到达的阶段结果必须被记住**：macOS 的工作区可能在窗口出现前就已经加载完成，"就绪"或"失败"这两个结果会早于动画开始到达。协调器要记住这类结果：动画开始时若已经就绪就直接跳过，若已经失败就直接展示失败，不能因为结果来得早就把动画卡在"加载中"不动。
- 就绪后动画进入淡出，180 ms 后移除。失败态不淡出，一直保留，直到用户点击"继续"。
- 失败必须指出**失败阶段和原因**，失败码固定四个：`pluginLoadFailed`、`languageServiceInitializationFailed`、`workspaceOpenFailed`、`sessionRestoreFailed`。失败提示盖在工作台之上，读到原因后点击"继续"即可回到工作台。
- **"就绪"和"失败"到达的时序两端不同**：Windows 在工作台首帧绘制完成时就上报就绪，而工作区恢复可能随后才失败，所以 Windows 的启动失败即使晚于"就绪"也会保留失败原因；macOS 的就绪上报放在工作区快照加载完成之后，工作区打开失败时根本走不到就绪，因此失败一定发生在加载阶段。语言服务失败只在启动阶段展示，运行期失败由语言服务自己负责，不要拿启动失败提示去覆盖运行期错误。
- 开关默认开启：macOS 是 `settings.startupAnimationEnabled`，Windows 是 `showStartupAnimation`。关掉之后既不显示动画，也不引入额外延迟——不要做成"关掉之后仍然等 400 ms 再进工作台"。
- **Windows 端消除白屏**：主窗口在 `tauri.windows.conf.json` 里设为 `visible: false`，工作台就绪后由新增的 `complete_startup` 命令关闭启动窗口并显示主窗口，Rust 侧保留 20 秒超时兜底，避免异常情况下启动窗口一直挂着。这里有一个必须记住的坑：`tauri-plugin-window-state` 会在窗口创建时恢复上次保存的状态，如果状态标志里带着 `VISIBLE`，它会直接把主窗口显示出来并抢焦点，所以 `window_state_flags()` 必须把 `StateFlags::VISIBLE` 去掉。
- **启动窗口的脚本不要依赖应用级 Provider**：独立页面里没有 React 树，`useTranslation` 之类的 Hook 一用就抛 `must be used inside LocaleProvider`，页面直接白屏。启动窗口要自己读 localStorage 里的引导缓存和 Tauri Store 里的语言设置，不要指望主应用的上下文。
- **macOS 端不改窗口创建流程**，而是在主窗口内叠加一个覆盖层。macOS 的插件扫描在 `LitheApp.init()` 里同步完成，早于窗口出现，所以 macOS 实际上观测不到 `loadingPlugins` 阶段；阶段覆盖范围两端因此并不完全相同，这一点在功能矩阵的备注里写明了。
- Windows 的首帧不再被 `begin_frontend_terminal_session` 阻塞：React 先渲染，终端会话初始化改为后台执行，真正需要终端会话的入口（新建终端）改为先等待该会话就绪。这样启动动画才能第一时间出现在屏幕上。
- 两端的文案必须逐字一致。macOS 用英文原文作为 `Localizable.strings` 的 key（中文文件写翻译），Windows 用 `src/i18n/locale.ts` 的 `en-US` 和 `zh-CN` 两段。`scripts/verify-startup-feedback-contract.mjs` 会校验契约自洽、两端阶段 ID 与顺序一致、时间常量一致、文案逐字一致、设置项存在；`scripts/verify-shared-contracts.sh` 在末尾调用它。
- 阶段来源：Windows 的 `loadingPlugins` 在扩展加载步骤上报，`initializingLanguageServices` 在新语言服务器会话建立后上报，`openingWorkspace` 在打开初始工作区前上报，`restoringSession` 在恢复上次会话前上报；macOS 的 `openingWorkspace` 在工作区重建前上报，`restoringSession` 在恢复会话闭包里上报，`initializingLanguageServices` 由语言服务的准备状态驱动。

### 正确做法

新增阶段时，先改共享契约里的 fixture，再在两端实现：

```json
{ "id": "openingWorkspace", "order": 4, "progress": 72, "labelKey": "startup.stage.openingWorkspace",
  "labels": { "en": "Opening workspace", "zhHans": "正在打开工作区" } }
```

然后在对应平台的阶段定义文件里补同序号的条目和对应的本地化文案。

### 不要这样做

- 不要在某一端自己定义一套阶段名或改写文案。两端词汇漂移后，用户在同一个产品里会看到两套说法，`scripts/verify-startup-feedback-contract.mjs` 会直接拦下来。
- 不要用启动动画去"补偿"慢启动，也不要在关闭开关后仍然保留等待。反馈层不能延后就绪时间。
- 不要把启动阶段和语言服务器的细粒度准备阶段合并成一套词。前者回答"产品现在到哪一步了"，后者回答"语言服务内部在做什么"。
- 不要在 Windows 端重新引入 `StateFlags::VISIBLE`，也不要用前端 `core:window:allow-show` 去显示主窗口——`capabilities/main.json` 的 `core:window:default` 没有授予 show/hide，显隐由 Rust 命令统一负责。
- 不要让启动窗口复用主应用的工作台页面或工作台 bundle。启动画面的价值全在"第一时间出现"，一旦它也要等 bundle 下载和挂载，它就变成了白屏的另一种形式。
- 不要在启动画面里用定时器模拟进度。进度必须来自契约里的阶段百分比，否则百分比和真实阶段对不上。
- 不要在启动画面里使用主应用的 React 上下文（Provider、Hook、主题 Hook）。独立页面没有那棵 React 组件树，用了就会抛错并让画面变成白屏。
- 不要在 macOS 端为了显示启动动画去重排 `LitheApp.init()` 的同步启动流程。这次刻意没有重构启动编排。

## 考虑过的备选方案

### macOS 用独立启动窗口（splash 窗口）

独立窗口可以在 `LitheApp.init()` 之前就显示，能覆盖到插件扫描这段最早的重活。但它会引入一个新的窗口生命周期：关闭行为、焦点、与 `applicationShouldTerminateAfterLastWindowClosed` 返回 `true` 的关系都要重新处理，而且工作台窗口会出现"先开启动窗、再开主窗"两次窗口切换。macOS 端最终选择主窗口内覆盖层，代价是 macOS 观测不到最早的插件扫描阶段。

Windows 端后来改成了独立启动窗口，说明这条路本身是可行的。macOS 端要跟进同样形态时，需要额外处理主窗口在启动期间先隐藏、就绪后再显示的顺序问题，这属于窗口编排改动，代价和风险都比覆盖层大，因此本次没有一起做。

### 用定时器让进度条慢慢往前爬

实现起来最省事，但进度和真实阶段对不上：用户看到 37% 却不知道在做什么，阶段真正切换时百分比又跳变。这条被明确否掉，进度改为来自契约的阶段百分比。

### 把两端的同步启动重活拆成异步分阶段

这才是"阶段文案完全反映真实进度"的前提，但它要改动 `LitheApp.init()`、模块注册、插件加载和 Rust 语言服务目录加载的调用顺序，属于启动编排的整体重构，风险远超一个启动反馈能力。Issue 的诉求是"有反馈"，不是"重构启动"，所以本次没有做。

### 复用 `project-preparation` 的阶段作为启动阶段

那份 fixture 描述的是语言服务器准备流程（`starting`/`importing`/`configuring`/`building`/`ready`/`stopped`），粒度更细、归属也不同。启动阶段是产品级步骤，两者语义不同，共用会让"打开工作区"这类非语言服务步骤无处安放。

### 开关默认关闭

默认关闭最保守，但意味着大多数用户永远看不到这个能力，Issue 的诉求仍然存在。默认开启加 400 ms 跳过阈值，让用户只在真正需要时看到它。

### 只做 Windows 或只做 macOS

Issue 明确要求"双端同一套动画与阶段文案"，分两次做会先产生一段两端不一致的时间。同一 PR 交付虽然改动更大，但契约、校验脚本和两端实现可以一次对齐。

## 后果

- 收益：启动期间用户能看到 Lithe 标志、当前阶段和进度百分比，不再面对空白或白屏；Windows 点击后立刻出现启动画面，不再有 1.75 秒的空窗；主窗口在工作台就绪前不显示，白屏消失；两端文案一致；启动很快时没有任何额外延迟。
- 代价：Windows 端新增了一个原生启动窗口、一条 `complete_startup` 命令和 20 秒兜底线程，多出一个前端静态入口 `startup-splash.html` 与对应脚本；`tauri-plugin-window-state` 的 `StateFlags::VISIBLE` 被移除意味着主窗口可见性不再随上次会话恢复；macOS 端新增一个覆盖层视图和一套状态协调器；两端各多一个设置项。
- Windows 的启动窗口是独立页面，主题、语言和开关都靠 localStorage 引导缓存和 Tauri Store 自己解析，绕开了主应用的初始化链；后续如果主应用的设置结构变了，这两处读取要同步维护。
- macOS 的 `loadingPlugins` 阶段不可观测，阶段覆盖范围与 Windows 不完全一致。如果将来要补齐，需要先重构 macOS 的启动编排。
- 失败提示现在会明确显示"哪个阶段失败、为什么失败"。如果新的启动步骤需要失败反馈，必须在契约的 `failureCodes` 里加码并同步两端。

## 验证

- `node scripts/verify-startup-feedback-contract.mjs`：校验共享 fixture 自洽、两端阶段 ID 与顺序一致、每阶段进度百分比一致、时间常量一致、中英文案逐字一致、两个设置项存在。
- `./scripts/verify-shared-contracts.sh`：共享契约整体校验，末尾会调用上面的启动反馈校验。
- `./scripts/test-macos.sh --filter StartupFeedbackTests`：快速跳过、慢启动显示并淡出、失败常驻直到确认、关闭开关不显示也不延迟、阶段只在加载中推进、就绪后不再重放、就绪早于动画开始时直接跳过、失败早于动画开始时直接展示失败、跳过阈值从应用启动计算、与共享契约一致、中文本地化覆盖、设置项默认开启并持久化。
- `bun test src/features/bootstrap/startup-animation`：Windows 侧同样的行为用例，用注入的假时钟驱动，不依赖真实等待；覆盖快速跳过、慢启动显示并淡出、失败常驻直到确认、关闭开关不显示也不延迟、阶段只在加载中推进、就绪早于动画开始时直接跳过、失败早于动画开始时直接展示失败、就绪之后到达的失败仍保留原因；另有一个用例读取共享 fixture 比对阶段与时间常量。
- `./scripts/verify-platform-feature-matrix.sh` 与 `./scripts/verify-platform-feature-matrix-change.sh origin/preview HEAD`：功能矩阵记录已更新且与平台实现改动匹配。
- `./scripts/verify-agent-notes.sh`
- 实机冷启动一个工作区较大的项目：确认启动期间显示 Logo、阶段文案和进度百分比，阶段随加载插件、初始化语言服务、打开工作区、恢复上次会话推进，百分比与契约数值一致；启动很快时确认完全跳过；就绪后确认淡出进入工作台。
- 实机在深色与浅色外观下核对标志与文案可读；关闭设置中的启动动画开关后重启，确认不显示动画且启动速度无变化。
- Windows 实机确认：点击后启动窗口立即出现（不等工作台 bundle）、画面是圆角卡片而不是方形黑边、进度百分比随阶段推进、就绪后启动窗口关闭并显示主窗口、异常情况下 20 秒兜底会关掉启动窗口。macOS 实机确认覆盖层卡片不阻塞工作台操作、失败态持续显示直到点击"继续"。

## 适用范围

- `shared/contracts/startup-feedback-v1.md`
- `shared/contracts/startup-feedback-v1.schema.json`
- `shared/fixtures/settings/startup-feedback-v1.json`
- `scripts/verify-startup-feedback-contract.mjs`
- `macos/Sources/Lithe/Application/Lifecycle/StartupFeedback`
- `macos/Sources/Lithe/Views/App/StartupAnimationView.swift`
- `macos/Sources/Lithe/Views/App/RootView.swift`
- `macos/Sources/Lithe/Application/Features/WorkspaceSessionCoordinator.swift`
- `macos/Sources/Lithe/Application/Composition/WorkspaceProjectionComposition.swift`
- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Tests/LitheTests/StartupFeedbackTests.swift`
- `windows/tauri/src/features/bootstrap/startup-animation`
- `windows/tauri/startup-splash.html`
- `windows/tauri/src/startup-splash.ts`
- `windows/tauri/src/features/bootstrap/bootstrap-async.ts`
- `windows/tauri/src/features/layout/components/main-layout.tsx`
- `windows/tauri/src/features/settings`
- `windows/tauri/src-tauri/src/host.rs`
- `windows/tauri/src-tauri/src/main.rs`
- `windows/tauri/src-tauri/tauri.windows.conf.json`
