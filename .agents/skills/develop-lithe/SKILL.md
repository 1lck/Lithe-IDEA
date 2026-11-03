---
name: develop-lithe
description: 在 Lithe 仓库进行实现、重构、缺陷修复、审查、调试、测试、构建或文档工作时使用。规定产品核心要求（性能好、内存少）、逻辑归属（可共享逻辑必须放进 Rust Core）、架构边界、界面与文案规则、缺陷修复流程、无用代码处理和交付前验证。
---

# Lithe 开发规范

本 Skill 是 Lithe 编码与验证规则的唯一真源。规则背后的理由和历史取舍记录在 `.agents/notes/` 的 Agent Note 中，本文件只写规则。

## 用词约定

| 用词 | 含义 |
| --- | --- |
| 必须、不得 | 没有例外。无法满足时停下来告知用户，不得自行放宽。 |
| 默认 | 除非满足该条写明的例外条件，否则照做。采用例外时在 PR 说明中写明理由。 |
| 可以 | 允许，但不要求。 |
| Core | `rust/lithe-core/`。 |
| 平台层 | macOS 的 Swift 代码（`macos/`）和 Windows 的 React/Tauri 代码（`windows/`）。 |
| 原生适配器 | 直接调用操作系统 API 的代码：平台层中的 `macos/Sources/Lithe/Platform/MacOS/`、`windows/tauri/src-tauri/`，以及两端共用的进程执行 crate `rust/lithe-git-host/`。 |
| 共享契约 | `shared/contracts/` 下的接口文档与 schema，以及 `shared/fixtures/` 下的 fixture。 |
| 主线程 | macOS 的主线程（MainActor）和 Windows 的 WebView2 UI 线程。 |

路径除特别说明外都相对于仓库根目录；本文件中的 Markdown 链接相对于本文件。

## 一、核心要求

以下六条适用于所有改动，完整规则在括号内的章节。

1. **性能好、内存少**是产品的首要要求。多个方案都能满足功能时，选择常驻内存更少、主线程工作更少的方案。（第四节）
2. **可共享的逻辑必须放进 Rust Core。** 不依赖操作系统或界面框架 API 的逻辑一律在 Core 实现；平台层只做原生 I/O 和呈现。（第三节“逻辑归属”）
3. **修复缺陷不得引入回归。** 先复现、定位根因、写出修复前失败的回归测试，再修改代码。（第八节）
4. **难以理解的配置和功能必须用 ⓘ 解释。**（第五节“用 ⓘ 解释”）
5. **用户可修改的配置不得只显示“自动”**，必须显示为“自动（实际生效值）”。（第五节“显示实际生效值”）
6. **发现无用代码或可重构之处，提交 `refactor` Issue**，不在当前 PR 中顺手处理。（第九节）

## 二、开始前：按任务读取资料

先读改动位置附近的实现和测试，再按下表读取资料。表中没有列出的资料不必预先读取。

| 任务 | 必须读取 |
| --- | --- |
| 调整模块归属、依赖方向或架构边界 | `.agents/notes/implemented/architecture/` 中与该模块相关的 Note |
| 跨平台行为或共享接口 | `shared/contracts/application-boundary.md`、`shared/contracts/rust-core-api.md` 和相关 fixture |
| 新增插件 API，或把内置工具迁移为插件 | `.agents/notes/implemented/architecture/2026-10-31-plugin-capability-and-domain-boundaries.md` |
| macOS 界面、控件或视觉交互 | [macOS 共享控件规范](references/macos-ui.md)，以及其中与本次改动相关的 Note |
| 滚动列表、树、表格、日志、长文本或分页列表 | [滚动内容与连续列表](references/scrolling-content.md) |
| 分隔条、可调整面板、连续拖动等高频交互 | `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md` |
| 新增、修改或审查设置 | `.agents/notes/implemented/architecture/2026-10-25-settings-native-configuration-editing.md` 和本文件第五节 |
| 新增或移动 macOS 设置页 | `.agents/notes/implemented/feature/2026-10-15-macos-settings-hierarchy.md` |
| 修复缺陷 | 本文件第八节，以及 `.agents/notes/implemented/bug-fix/` 中涉及同一模块的 Note |
| 新增、迁移或审查日志事件、写入器和诊断采集 | [日志接入](references/logging.md)，声明规则以 `shared/logging/README.md` 为准 |
| 新增、移动或审查脚本 | [脚本放置与分类](references/scripts.md) |
| 创建、迁移、更新、归档或审查 Agent Note | `.agents/skills/agent-notes/SKILL.md` |
| 创建、修改或审查测试及测试基础设施 | `.agents/skills/write-stable-tests/SKILL.md` |

发布、提交 Issue、在 Windows 虚拟机中诊断等任务，按 `AGENTS.md` 加载对应 Skill。

## 三、架构与逻辑归属

### 目录归属

| 路径 | 职责 |
| --- | --- |
| `rust/lithe-core/` | 两端共享的确定性逻辑：命令、模型、解析、校验、状态规则、C ABI |
| `rust/lithe-git-host/` | 两端共用的原生子进程执行：管道、临时输入、进程树归属与有界清理 |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit 呈现，以及只属于视图自身的呈现状态 |
| `macos/Sources/Lithe/Models/` | 面向界面的模型和 `AppModel` 聚合 |
| `macos/Sources/Lithe/Application/` | 功能模型：持有界面状态、接收用户动作、调用服务 |
| `macos/Sources/Lithe/Services/` | 产品工作流编排 |
| `macos/Sources/Lithe/Core/` | Swift 侧的平台无关端口和类型化 Rust 调用 |
| `macos/Sources/Lithe/Platform/MacOS/` | macOS 原生适配器和依赖组装 |
| `windows/` | 独立的 React/Tauri Windows 产品及其 Rust 原生适配器 |
| `Plugins/mac/`、`Plugins/win/` | 各平台自己的插件包 |
| `frontend/editor/` | 两端共用的 Monaco 呈现、词法着色和编辑器模型生命周期；不得调用平台 API |
| `shared/` | 共享契约、fixture 和 i18n 词条；不放编译实现 |
| `scripts/`、`.github/` | 仓库级脚本和 CI 工作流；脚本按[脚本放置与分类](references/scripts.md)放置 |
| `third_party/` | 上游代码；除非任务明确针对它，否则不得修改 |

macOS 是当前参考产品。Windows 是独立实现：不得导入 Swift 源码，不得依赖 macOS 类型。

### 逻辑归属：可共享的逻辑必须放进 Rust Core

目的：平台层只负责呈现和原生 I/O。这样更换界面框架或新增平台时只需重写呈现层，两端行为由同一份实现保证一致。

按下表从上到下判断一段逻辑放在哪里，取第一个匹配的行：

| 逻辑 | 位置 |
| --- | --- |
| 成熟上游工具已经提供的事实（符号、源码根、模块归属、classpath、编译状态、调试目标等） | 上游工具。Core 只做校验、规范化和流程编排，不保存第二份。见“复用成熟上游” |
| 某个工具或运行时专属的知识（配置格式及其解析、版本别名、框架参数、工具专属的选择规则） | 该工具的插件。见“插件能力” |
| 必须调用操作系统或界面框架 API 的操作（文件系统、进程、终端、文件监听、凭据、持久化存储、窗口、渲染、手势、焦点、动画） | 平台层的原生适配器或视图 |
| 其余全部逻辑 | Core |

“其余全部逻辑”包括：解析、校验、规范化、匹配、过滤、排序、分组、去重；默认值、“自动”值和优先级的解析；状态机和状态转换规则；由业务状态决定的操作可用性（例如能否提交、能否运行）；错误码和诊断码；限额与预算；树和列表的投影、分页窗口计算、差异计算。无论这段逻辑目前只有一端使用还是两端都使用，都适用本规则。

平台层可以保留的逻辑只有三类：

1. 只存在于一个平台的系统概念，例如 macOS 应用菜单、Windows 注册表。
2. 视图自身的呈现状态：布局尺寸、动画、焦点、悬停、拖动中的临时值、逐帧滚动偏移。
3. 把 Core 返回的错误码、诊断码和参数转换成本地化文案。

平台层的职责限于：

1. 把用户输入转换成 Core 命令。
2. 执行 Core 要求的原生 I/O，并把原始结果交回 Core。需要读取外部数据时，由 Core 指定读什么、读多少；平台层不得先自行过滤或解释，再交给 Core。
3. 呈现 Core 返回的结构化结果。
4. 本地化 Core 返回的码和参数。

强制要求：

- 新功能的可共享逻辑必须先在 Core 实现，并补齐共享契约和 fixture，再接入平台层。即使功能只在一个平台上线，也不得先写在 Swift 或 TypeScript 中“以后再迁移”。
- 修改平台层中已有的可共享逻辑时，必须把被修改的部分迁入 Core。确有理由本次不迁移（例如紧急修复）时，在 PR 说明中写明理由并提交 `refactor` Issue（第九节）；不得在平台层继续扩大这段逻辑。
- 经过 Core 处理大数据时，跨边界传输按第四节只传增量、分页或可见窗口。

### 分层边界

- Views 只依赖 `AppModel` 或专用功能模型；不得调用 Rust C ABI，不得创建平台适配器，不得依赖具体的工作流服务。
- Application 功能模型持有界面状态、接收用户动作、调用服务；状态转换规则按“逻辑归属”放进 Core。平台初始化不得放进 `AppModel`。
- Services 通过端口编排工作流；不得直接创建 `Process`、`Pipe`、`FileManager`、`FileHandle`、文件监听、持久化存储或具体的 `Mac*` 适配器。
- `macos/Sources/Lithe/Core/` 和 Application 不得依赖 SwiftUI、AppKit、CoreServices、Tauri、WebView2、Win32 或任何具体平台实现。
- `MacServiceContainer` 是 macOS 唯一的依赖组装入口。
- Windows 功能代码只能通过 `@/platform/tauri-core` 调用宿主，不得直接导入 Tauri core API。共享操作经过 Core；Windows 专属的终端、文件监听、凭据、进程和 WebView 行为放在 `windows/tauri/src-tauri/` 或平台插件。

### 复用成熟上游

适用于新增或扩展以下能力：语言智能、项目导入、构建建模、依赖解析、编译、格式化、重构、测试发现、运行与调试规划、LSP/DAP 行为。

1. 先查清已打包上游工具的版本、现有能力和官方扩展点，以及许可、分发方式、资源开销和平台支持都满足要求的开源替代。能通过升级或启用已有能力解决的，不得自行实现。
2. 复用上游时复用完整的子系统。不得只调用其中几个命令，再自行重建它的项目状态、依赖图、生命周期或语义模型。
3. 上游拥有的事实只以上游为准，Core 不得维护第二份。
4. 只有以下条件之一成立时才可以自研：上游缺少该能力；上游无法满足已证实的需求；许可不允许分发；实测违反产品约束（包括第四节的性能与内存要求）。自研或扩展需要长期维护的子系统时，必须在所属 Agent Note 中记录证据、被否决的复用方案、职责边界和以后的迁移路径。
5. 不得超出许可范围逆向、复制、打包专有工具或围绕它做设计。独立实现只能依据公开行为或开放标准，并以许可条款允许为前提。
6. 验证完整的用户流程（例如“保存 → 同步项目状态 → 构建 → 解析运行路径 → 启动”），不能只验证上游命令被调用。

Lithe 自己负责的是：有界生命周期、取消、过期结果隔离、资源预算、跨平台契约、界面呈现和端到端流程。

### 插件能力

新增插件 API 或把内置工具迁移为插件前，先读第二节列出的插件能力 Note。

1. 只有参与宿主原生的 Build、Run、Test、LSP 或 Debug 工作流时，插件才使用对应的领域契约。文本高亮、文档读写、编辑器动作和插件自有界面使用各自独立的扩展点。例如 HTTP 插件在请求旁显示的运行按钮是编辑器动作，不是 Run Provider。
2. 每个独立扩展点有自己的类型化契约、权限和生命周期，只包含宿主需要理解的字段；底层复用已有的函数调用、超时和取消机制。宿主需要理解的数据不得通过无类型的私有函数传递；宿主需要理解某项展示数据，也不构成把它放进 Build 或 LSP 契约的理由。
3. 新增插件 API 前先列出已有的公共 API。确有缺口时，按能力边界扩展，优先使用已发布协议中的能力发现和可选字段；向后兼容的新增字段不升级整套协议版本。任何公共 API 变化（包括可选字段）都必须同步更新契约文档、所有消费者和 SDK 端到端验证，并在 PR 说明中如实列出。
4. 工具或运行时专属的知识属于插件或成熟上游。宿主和 Core 不得新增以下分支：按工具名或运行时名判断；解析某个工具的私有配置格式；识别某个工具的私有错误码；依赖固定任务 ID 或约定函数名。通用模型中的 ID 不透明；能力之间的关联由插件显式声明，不按名称推断。把按名称的特判改写成封闭枚举（例如 `miseToml | toolVersions`），仍然是特判。
5. 检验扩展点是否通用：设想接入第二个语义不同的工具。如果必须修改宿主或 Core 才能接入，说明扩展点泄漏了第一个工具的语义，必须先修正扩展点。在宿主中为每种格式各加一个解析器不算通用。
6. 工具定义（可执行入口、探测方式、环境）、事实提供方（安装位置与作用域）和使用方（按工具 ID 引用）分属不同角色，不得混在一处。
7. 插件配置由插件负责格式和语义，宿主负责用户确认、版本冲突检测和原子写入。插件专属设置通过插件设置注入点显示，宿主不得为某个工具写固定表单。需要监听的文件由插件声明；宿主统一监听，在变化时让整份查询结果失效，但不得复制工具的配置发现或优先级规则。
8. 一次性兼容迁移代码必须标明适用版本、删除条件和跟踪 Issue；新的生产路径不得把它当作回退逻辑调用。

### 共享契约

- 进程之间、语言之间的边界使用 UTF-8 JSON。
- 标识符使用以 `/` 分隔的工作区相对路径；绝对路径只出现在平台拥有的诊断信息中。
- 行号从 1 开始；缺失的位置用 `null`；列表和序列化结果的顺序必须确定：相同输入得到相同顺序。
- 契约要求时，异步操作的状态显式区分 `idle`、`loading`、`ready`、`failed`。
- 失败返回稳定的错误码和面向用户的消息；平台专属细节放在契约的 `details` 字段。
- 新增 API 的每个数值错误码（例如 JSON-RPC 的 `error.code`）只对应一种错误，调用方只凭数值码就能分支。方法不存在、参数错误、取消等标准语义使用 JSON-RPC/LSP 标准码；其余错误各自占用服务端自定义区间内的独立码，并在契约文档和 fixture 中列出映射。已发布协议版本中的旧码保持不变，从新版本起区分。
- 进程型功能保留 `operationID`、取消、超时和过期结果丢弃语义。
- 新的 Core 命令或字段接入任一平台之前，必须先补充或更新共享 fixture。
- 以下内容是兼容面，修改时必须同步更新契约文档和所有消费者：命令名、JSON 字段、错误码、C ABI 符号；Core 的公开 Rust 类型、结构体字段和函数签名。后一组的原因是 `windows/tauri/src-tauri/` 和 `windows/tauri/crates/project/` 直接链接 Core crate，不经过 JSON：macOS 通过 JSON 调用时缺省字段按 `None` 处理，Windows 的结构体字面量却会因缺字段编译失败（给 `JavaSelectionRequest` 新增 `requirements` 曾导致 Windows 安装包构建报 E0063）。只改 Core 也必须修正这些调用点。

## 四、性能与内存

定义：

- 性能：用户操作到界面给出结果的延迟、主线程占用时间、启动时间。
- 内存：Lithe 进程及其启动的全部子进程（语言服务器、调试适配器、Agent、插件后端、WebView 进程）的常驻内存。

### 规则

**取舍**

1. 多个方案都能满足功能时，选择常驻内存更少、主线程工作更少的方案。选择资源消耗更大的方案时，必须在 PR 说明中写明理由并附实测数据。

**启动与空闲**

2. 功能、插件后端、语言服务器、WebView 和子进程在首次需要时才启动。“需要”指用户的操作已经要用到它的结果，例如打开对应语言的文件、打开对应面板。不得在应用启动或项目打开时，为用户尚未使用的功能预先启动。
3. 不得新增在应用空闲时持续运行的轮询或定时器。需要感知外部变化时使用文件监听或事件通知；确实只能轮询时，必须设置最小间隔，并在窗口失去焦点或不可见时暂停。

**上限与释放**

4. 缓存、队列、历史记录、日志缓冲、终端和运行输出缓冲必须有明确上限（条数或字节数）和淘汰策略。上限定义为命名常量或用户可配置项；不得无界增长。
5. 关闭项目、窗口、面板或编辑器标签时，必须释放它独占的子进程、文件监听、定时器、缓存和 WebView，不得保留到应用退出。
6. 支持内存上限参数的子进程（例如 JVM 的 `-Xmx`）必须显式设置上限。

**数据与线程**

7. 同一份大数据（文件内容、搜索结果、日志、Git 历史、项目树）只由一层持有完整副本；其他层只持有可见窗口、摘要或标识。
8. 跨 C ABI、Tauri IPC 和 WebView 消息边界时，只传输增量、分页结果或可见窗口，不得传输全量数据。
9. 主线程不得执行文件读写、目录遍历、进程启动或探测、大量数据的解析和排序。这些工作在后台执行，必须可以取消，过期结果必须丢弃。Windows 的写法见第六节“Windows、React 与 Tauri”。
10. 诊断、进度、日志、文件变化等高频事件在发送端按批合并：每批只跨边界发送一次，接收端每批只更新一次状态。

**呈现**

11. 滚动列表、树、表格、日志和长文本默认虚拟化：只创建视口及预取范围内的行，无论是 SwiftUI 视图还是 DOM 节点。细则和例外见[滚动内容与连续列表](references/scrolling-content.md)。
12. 拖动、滚动等高频交互中的逐帧状态留在视图本地，不得发布到 `AppModel` 或业务根状态。细则见第二节列出的高频交互 Note。

**依赖**

13. 新增运行时（JVM、Node.js、额外的 WebView 等）或大型依赖前，必须在 PR 说明中给出它对启动时间、常驻内存和安装包体积的影响。

### 验证

改动涉及启动、打开项目、输入、滚动、大文件、长输出或搜索时，在改动前后各运行一次对应平台的性能基线，并在 PR 说明中给出对比数据：

- macOS：`./scripts/macos/perf/measure-macos-performance-baseline.sh --scenario <场景> --fixture <规模>`（`--list` 列出场景和规模）。报告中的 `ready_rss_kib`、`stable_rss_kib` 是常驻内存。场景定义见 `.agents/notes/implemented/testing/2026-09-13-macos-interaction-performance-baseline.md`。
- Windows：`node scripts/windows/perf/run-windows-perf.mjs`，预算在 `scripts/windows/perf/budgets.json`。

已有基线没有覆盖本次场景时，在 PR 说明中写明测量方法和数据。不得通过上调预算、删减场景或缩小 fixture 让检查通过。

## 五、界面与交互

### 共享控件

macOS 界面改动前必须读 [macOS 共享控件规范](references/macos-ui.md)。业务视图只提供内容和动作；共享控件已经覆盖的样式和交互，不得在调用处另行定义。Windows 使用 `windows/tauri/src/ui/` 中已有的共享组件，不得在功能代码中另造同类控件。

### 用 ⓘ 解释难以理解的配置和功能

适用于设置项、设置分组、设置页、插件设置、对话框中的选项，以及面板、页面等有标题的功能区。以下任一条件成立时，必须提供 ⓘ 说明：

1. 名称是专业术语、缩写或工具专有名词，例如 “Prune tags”、“mvnd”。
2. 有名称没有体现的后果：写入文件、重启进程、访问网络、影响其他项目或丢弃数据。
3. 有多个取值，只凭取值名称无法区分它们的效果。
4. 有“自动”模式。ⓘ 中必须说明自动如何决定取值，例如按什么顺序查找。

ⓘ 的内容说明这一项做什么、对用户有什么影响，不得只重复标签文字。只有图标、没有标题的按钮无法放 ⓘ，改用悬停提示（macOS `.help("…")`，Windows `Tooltip`），提示写出动作名称，以及第 2 条中的后果。

呈现方式：

- macOS 使用 `LitheInfoTip`：设置行用 `LitheSettingsRow` 或 `LitheSettingsLabel` 的 `info:` 参数，分组用 `LitheSettingsSection` 的 accessory。插件设置的 `description` 和插件动作的 `summary` 也通过 ⓘ 或悬停提示显示。
- Windows 把 `@/ui/icons` 的 `InfoIcon` 放进 `@/ui/tooltip` 的 `Tooltip`，写法参照 `windows/tauri/src/features/settings/components/workspace-indexing-settings.tsx`。

不得在控件下方常驻说明段落或说明性小字，不得把说明写进状态标签。每行保持“标签、ⓘ、控件、状态标签”的紧凑结构；状态标签只显示生效值、作用域、来源、是否生效等状态。

需要用户处理或立即知道的信息可以常驻显示：错误、警告、需要重启、空状态、加载中、当前生效值。

ⓘ 文案按本节“界面文案与 i18n”在同一次改动中补齐中英文词条。

### 显示实际生效值，不只写“自动”

适用于用户可以修改的配置项：在用户没有显式设置、取值由自动检测、继承或默认值决定时，界面如何显示当前值。不适用于名称本身含“自动”的功能开关（例如“自动保存”“自动换行”），也不适用于用户不能修改的只读状态。

1. 不得只显示“自动”“默认”或“继承”。必须在括号中写出实际生效值，例如 `自动（JDK 21）`、`自动（项目 mvnw）`、`继承（main）`；英文为 `Automatic (JDK 21)`。控件当前值、下拉选项文本和状态标签都适用。
2. 没有生效值时，括号中写明原因：`自动（未找到）`、`自动（检测中）`、`自动（读取失败）`。读取失败时同时显示错误。
3. 括号中的值必须来自运行时实际使用的同一个解析结果（Core 返回的生效值）。界面不得另写一套推测逻辑，否则显示会与实际行为不一致。
4. 生效值变化（检测完成、来源文件被修改）后，显示必须随之更新。
5. 使用带参数的 i18n 词条（例如中文 `自动（{value}）`、英文 `Automatic ({value})`），不得拼接字符串。

### 读取并编辑工具的真实配置（Source-backed settings）

适用于非敏感的工具配置，即工具自己的配置文件或配置命令可以读写的值（例如 Git、Maven、JDK 的配置）。

1. 打开设置页只读取，不得写入。通过原生适配器按工具自身的优先级找到实际来源；区分“文件不存在”“使用上游默认值”“读取失败”“本地覆盖”四种情况，不得编造当前值。
2. 控件显示可编辑的当前值，不得只显示占位符。来源和作用域用状态标签显示，说明放进 ⓘ。继承来的生效值和显式保存的覆盖值必须能区分；未覆盖时按“显示实际生效值”规则显示。
3. 编辑只修改草稿。写回原生配置前，必须有用户明确的保存或应用操作，并显示写入目标和作用域。不得在按键、失去焦点、离开页面或打开页面时写入；取消时不写入；没有修改时不创建覆盖。
4. 只写入用户确认的原生来源，不得维护一份工具实际不读取的平行配置。写入时保留无关内容、文件权限、格式支持的注释和秘密字段；使用原子替换并检查冲突：来源在读取之后被修改过时拒绝写入。
5. 写入成功后，重新读取原生配置和生效值再显示；存在更高优先级的覆盖或需要重新连接时，明确提示。写入失败时保留草稿，不得提示成功。外部重新加载和恢复默认值不得被过期的失焦或离页提交覆盖。
6. 密码、token、私钥和凭据不得出现在普通输入框、日志、预览或 fixture 中；不得把脱敏占位符当作秘密写回。打包资源只读；来源是继承或只读时，必须让用户明确选择可写的覆盖位置，不得静默提权写入。

优先复用上游的配置读写实现或已有适配器，不另建优先级模型。真正属于 Lithe 自身的偏好可以存放在应用存储中，但必须标明作用域，不得伪装成工具的原生配置。本规则不要求批量迁移与当前任务无关的页面。

验证完整流程：发现 → 回显 → 编辑 → 确认或取消 → 带冲突检查的写入 → 回读 → 重新打开；覆盖秘密字段、写入冲突、读取失败和恢复默认值。平台功能矩阵只记录真实的实现和验证证据。

### 界面文案与 i18n

所有用户可见文案必须通过共享 i18n 生成。词条的唯一来源是 `shared/i18n/`，格式规则以 `shared/i18n/README.md` 为准。硬编码文案会在系统语言与应用语言不一致时显示错误的语言。

macOS：

- SwiftUI 视图中的字面量（`Text("…")`、`Button("…")`、`.help("…")` 等）由 SwiftUI 按应用语言查表。每个字面量都必须有共享词条，否则所有语言都显示英文。
- 视图之外的文案用 `LitheModuleAPI` 的 `L10n.string("…")`，包括：错误和 `errorDescription`、`NSAlert` 的标题和按钮、`NSLocalizedDescriptionKey`、通知、状态文本、以 `String` 类型传入的 `title:`、`help:`、`message:` 等参数。运行时才确定的键用 `L10n.string(key:)`。
- 不得直接调用 `String(localized:)` 或 `NSLocalizedString`；不得用 `locale:` 参数代替应用语言选择，它只影响数字和日期格式。

Windows 使用 `windows/tauri/src/i18n/` 的接口。

两端共同的规则：

- Services、Core 和原生适配器不得拼接英文后直接显示；不得把一句话拆成几段分别翻译再拼接，必须使用带参数的词条。唯一的例外是调用方为测试或 Agent 显式注入自有语言包。
- 新增或修改文案时，在同一次改动中完成：
  1. 在 `shared/i18n/messages.json` 声明词条、macOS 原生 key 和参数。参数写成 `{name}` 并声明类型；macOS 原生调用传 32 位整数时，用 `macos.formats` 声明 `d`。
  2. 在 `shared/i18n/locales/en-US.json` 和 `shared/i18n/locales/zh-CN.json` 补齐译文。
  3. 运行 `node scripts/i18n/generate-i18n.mjs`，把生成结果一起提交；不得手改生成文件（`Localizable.strings`、`*.generated.*`）。
  4. 运行第十一节列出的三项 i18n 检查。
- 检查失败时修改代码或补词条。不得放宽 `scripts/i18n/verify-app-language-localization.mjs`、扩大豁免名单、把文案藏进变量或改用 `Text(verbatim:)` 绕过检查。只有产品名、示例值、标识符等确实不翻译的内容可以豁免，并在 PR 说明中列出。
- 上游诊断、用户代码、Agent 返回内容和日志标识不属于界面文案，保持原文，不得翻译或改写。

### 滚动内容与连续列表

- 滚动内容默认虚拟化，规则见第四节第 11 条。
- Git 历史、反汇编等连续浏览的分页列表，在滚动接近视口边缘时自动加载下一页，不得要求用户反复点击“加载更多”。内存查看器等离散页面仍可显式翻页。
- 两条的细则、例外和验证要求见[滚动内容与连续列表](references/scrolling-content.md)。

## 六、语言与编码约定

遵循相邻代码的风格：命名清晰，类型和函数职责单一，所有权明确，控制流直接。不得夹带无关的清理、推测性的抽象，或现有技术栈不需要的新依赖。

### Swift 与 macOS

- 使用 `.swift-version` 固定的 Swift 6.3.3 工具链（Xcode 26.6）。应用 target 使用 Swift 5 语言模式，测试 target 使用 Swift 6；不得更改。
- 测试沿用 `macos/Tests/LitheTests/` 的 Swift Testing 写法；稳定性、资源清理和逐项计时遵循 `write-stable-tests` Skill。

### Rust

- 运行 `cargo fmt`，遵循所属 crate 和模块的约定。
- 保持共享结果的确定性、JSON envelope 和 C ABI 兼容。跨边界返回结构化失败，不得把不稳定的 Rust 实现细节暴露成契约错误码。
- 命令、解析、校验、排序、取消或序列化行为变化时，在所属 crate 增加测试。

#### Rust Core 注释规范

只适用于 `rust/lithe-core/` 中的第一方代码，不适用于其他 helper crate、Windows/Tauri 的 Rust crate、生成代码和第三方源码。

- 注释使用英文，并随行为更新。
- 每个生产模块以简短的 `//!` 说明职责或架构边界开头。
- 导出 API、共享请求和响应类型、核心领域类型和 C ABI 函数使用 `///`，说明所有权；`unsafe` 入口补充 `# Safety`；错误契约不明显时说明错误。
- 枚举、结构体、变体和字段的名称不足以说明语义、允许值、单位、所有权或协议角色时，必须写文档注释；内部类型同样适用。
- 实现内部用 `//` 解释不明显的兼容性、确定性、顺序、安全、性能或跨平台约束。
- 测试名和断言不足以说明意图时，补充场景、回归风险或保护的边界。
- 不得为凑覆盖率复述赋值、声明或名称，也不得给简单访问器和直接的控制流机械地加注释。
- 运行较慢的 Rust Core 检查前，先运行 `./scripts/rust-core/verify-rust-core-comments.sh`。它检查模块说明、导出项的 Rustdoc、英文注释和 `unsafe` 的安全说明；它不检查内部 helper 是否都有文档，也不能替代对内部类型语义的人工检查。

### Windows、React 与 Tauri

- 前端脚本使用 Bun，宿主使用 Tauri 2。功能代码在 `windows/tauri/src/features/`，共享界面在 `windows/tauri/src/ui/`，invoke 边界在 `windows/tauri/src/platform/`，原生 Rust 行为在 `windows/tauri/src-tauri/`。
- 不得恢复平行的 C++/Qt 应用层；不得为每个共享 Core 操作新增一个 Tauri command，旧命令名统一在中央 dispatcher（`windows/tauri/src-tauri/src/platform.rs`）中转换。
- 同步的 `#[tauri::command] fn` 在派发 IPC 的线程上执行，在 Windows 上就是 WebView2 UI 线程：它运行期间窗口停止绘制、输入排队、其他 invoke 全部等待。凡是读写文件、遍历或删除目录、启动或探测进程（例如 `java -version`、`mvn -version`、Shell、Agent）、注册原生监听的命令，必须写成 `async fn`，并把主体交给 `crate::blocking::run_blocking`。同步命令只用于不碰磁盘和进程、只读写内存状态的轻量操作。
- 诊断、进度、日志等高频事件不得逐条 `emit`：每次 `emit` 都是一次完整的 IPC 往返，并且会广播到所有窗口。在一次 drain 内按 key 合并后整批发送，store 也一次更新完。
- 产品行为补前端测试，Rust 行为在所属 crate 中测试。WebView2、ConPTY、安装、签名和更新行为必须在 Windows 上验证。

## 七、安全、资源与失败处理

### 不得硬编码环境细节

- 不得提交凭据、token、私有端点、签名材料或个人数据。
- 应用逻辑不得写死开发机路径、工作区根目录、用户主目录、临时目录或工具安装路径；可执行文件、存储位置和平台默认值通过适配器或配置机制解析。
- 稳定的产品常量集中命名，不得在两个平台中重复同一个魔法字符串或数字。
- 测试 fixture 可以使用明显虚构的值，但不得包含真实秘密或某台机器专属的路径。

### 已安装程序包运行时只读

macOS app bundle 和 Windows 安装目录是发行基线。Sparkle 增量更新按发布包的精确字节生成；运行时写入会改变基线，导致下次增量校验失败、回退到完整下载。

- 缓存、索引、Eclipse/OSGi 状态、下载物、解压物、日志和锁文件，通过平台存储适配器放到缓存目录、Application Support、临时目录或用户工作区。不得从 `Bundle.main.resourceURL`、`resource_dir()` 或安装目录推导写入位置。
- Equinox 等会向自身所在目录写入的工具，必须在可写的缓存目录中使用输入副本；`-configuration` 的做法见 `rust/lithe-core/src/lsp/languages/jdt_configuration.rs`。
- 新的打包运行时必须增加“典型流程前后比较安装目录文件清单”的测试，并保持 `./scripts/macos/verify/verify-runtime-bundle-immutability.sh` 通过。
- 不得用“启动前清理 bundle”来修复运行时写入问题。

决策和完整生命周期规则见 `.agents/notes/implemented/bug-fix/2026-09-25-runtime-bundle-immutability-and-update-delta.md` 和 `AGENTS.md`。

### 显式处理失败

- 不得静默吞掉错误。在有足够上下文的层返回、转换或记录错误。
- 跨 Rust、Swift、TypeScript、Tauri 或进程边界时，保留稳定的契约错误分类。
- 面向用户的失败信息必须告诉用户可以怎么做，不得泄漏凭据、环境变量内容或不必要的内部细节。
- 注释解释不明显的约束和取舍，不复述代码的执行过程。

## 八、修复缺陷

目标：缺陷被修复，且原本正常的行为不变。

1. **复现。** 写明复现步骤、实际结果和期望结果。无法复现时，在 PR 说明中写明修复依据（日志、堆栈、代码推理）和无法复现的原因。
2. **定位根因。** 修改导致错误的代码，不得在症状出现的位置加特判掩盖问题。用 `git log -S`、`git blame` 找到引入该行为的提交和相关 PR，并检查 `.agents/notes/implemented/bug-fix/` 中同一模块的 Note，确认原设计意图，不得破坏以前的修复。
3. **先写回归测试。** 在能复现缺陷的最低层级（优先 Core 的单元测试）新增测试。确认它在修复前失败、修复后通过。无法自动化时（例如必须真机交互），在 PR 说明中写出手动复现和验证步骤。
4. **检查影响面。** 搜索被修改的函数、类型和契约字段的全部调用方，范围包括另一平台、插件、SDK、脚本，以及通过命令名或字符串动态分发的调用；逐一确认它们在新行为下仍然正确。
5. **只改修复所需的代码。** 不得在同一改动中重构、改名或调整无关行为。修复过程中发现的其他问题按第九节提交 Issue。
6. **检查同类问题。** 在其他位置（尤其另一平台的同类实现）查找相同的错误模式。两个平台各有一份实现导致缺陷时，按第三节“逻辑归属”把这段逻辑迁入 Core。
7. **运行验证。** 运行被修改模块已有的测试和第十一节对应的检查。修复前就失败的测试必须在 PR 说明中列出，并证明它在改动前同样失败。性能或内存缺陷用第四节的基线给出修复前后的数据。
8. **记录。** 修复改变了行为约束，或该问题容易复发时，按 `agent-notes` Skill 在 `.agents/notes/implemented/bug-fix/` 记录。

## 九、发现无用代码或可重构之处

开发或准备 PR 时（包括自审），如果发现以下情况，提交 Issue 交给维护者清理或重构：

- 无用代码：没有任何调用方的函数、类型、文件、配置项或脚本；已经退役但仍保留的兼容路径或开关；被新实现完全替代的旧实现。
- 可重构之处：重复实现（包括两个平台各写一份、应按第三节迁入 Core 的逻辑）、职责放错层次、可以合并的相似代码。

规则：

1. 本次改动导致变成无用的代码，必须在本次改动中删除，不提交 Issue。本次改动之前就已存在的无用代码和可重构之处，不得在当前 PR 中处理，必须提交 Issue。
2. 判定“无用”必须有可验证的证据：全仓库搜索结果，范围包括另一平台、插件、脚本、CI 工作流，以及通过命令名或字符串动态分发的调用。不得仅凭推测提交。
3. 按 `submit-lithe-issue` Skill 的流程提交（查重、使用功能建议模板、核验结果），并加 `refactor` 标签。“要解决的问题”写明代码位置（路径和符号名）、判定依据和保留它的代价；“建议方案”写明清理或重构的做法和风险；优先级按实际影响选择。
4. 同一原因导致的多处问题合并为一个 Issue；原因不同的分开提交。
5. 在 PR 说明中列出本次提交的 Issue 链接。

本条是提交此类 Issue 的授权，不需要另行征求用户同意。仓库中不存在 `refactor` 标签时，不得自行创建，告知用户。

## 十、跨平台功能矩阵与提交门禁

新增用户可见能力或改变跨平台行为时，在同一个 PR 中更新 `shared/platform-feature-matrix/features/<id>.json`。

- 每个文件对应一项可以独立验证的用户能力，包含两个平台的 `implementationStatus`、`verificationStatus`、证据路径、owner 和具体验证动作。只在一个平台存在的能力，另一平台记录 `implementationStatus: platform-specific`。
- 实现状态和验证状态相互独立。只有代码、没有运行时证据时，验证状态保持 `pending`；在目标平台完成验证流程后才能标为 `verified`。JSON 中的状态标签、图标和说明是生成器的唯一状态来源。
- 公共状态定义在 `shared/platform-feature-matrix/metadata.json`。只改日期或 metadata 不满足能力更新门禁。
- 更新源数据后运行 `node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs`，检查 `.artifacts/platform-feature-matrix/` 下的 HTML、Markdown、CSV 和 JSON；不得提交生成的视图。

平台实现改动没有通过本地门禁之前，不得声称完成，不得标记为可评审，不得推送或创建、更新 PR。先列出相对 PR 基线的改动：

```bash
git diff --name-only origin/preview...HEAD
```

第三节“目录归属”中的平台实现路径有变化时，运行：

```bash
./scripts/platform-feature-matrix/verify-platform-feature-matrix-change.sh origin/preview HEAD
./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh
```

已知 PR 的精确 base/head SHA 时，用它们替换上面的引用。门禁报告缺少实质的能力记录变更时，先补相关 JSON 再继续。交付前必须运行 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

`matrix-exempt` 标签只能由 reviewer 用于已审查、且没有用户可观察变化的重构，并在 PR 说明中注明；不得用它绕过功能变更。用户要求跳过可选测试，不等于豁免契约门禁。

## 十一、验证与交付

### 按改动选择验证

迭代时先运行最小的相关检查，交付前覆盖全部受影响范围。只改文档时，不运行无关平台的全量构建。

| 改动 | 最低验证 |
| --- | --- |
| 用户可见文案 | `node scripts/i18n/verify-app-language-localization.mjs`、`node scripts/i18n/generate-i18n.mjs --check`、`node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs` |
| 缺陷修复 | 第八节的回归测试（修复前失败、修复后通过），以及下面对应行的检查 |
| 启动、打开项目、输入、滚动、大文件、长输出或搜索 | 第四节“验证”中对应平台的性能基线，改动前后对比 |
| Agent Note 或架构决策迁移 | `./scripts/agent-notes/verify-agent-notes.sh` |
| 测试代码或测试基础设施 | `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`，再运行该 Skill 中对应平台的逐项计时入口 |
| Swift 应用或测试 | `./scripts/macos/test/test-macos.sh` |
| `macos/Sources/Lithe/` 的 Core、Services、Views 或依赖组装边界 | `./scripts/architecture/verify-service-boundaries.sh` |
| 共享应用行为或 JSON fixture | `./scripts/architecture/verify-shared-contracts.sh` |
| Rust Core、JSON C ABI 或 Swift bridge | 先 `./scripts/rust-core/verify-rust-core-comments.sh`，再 `./scripts/rust-core/verify-rust-core.sh` |
| Core 功能行为 | `./scripts/architecture/verify-core.sh` |
| Git graph 行为 | `./scripts/git-graph/verify-git-graph.sh` |
| 运行时资源或发行目录只读边界 | `./scripts/macos/verify/verify-runtime-bundle-immutability.sh` |
| 在 macOS/Linux 上验证 Windows 边界 | `./scripts/windows/verify/verify-windows-boundaries.sh` |
| Core 的公开 Rust 类型或函数签名 | 用 `rg '<类型或函数名>' windows/` 找到 Windows 调用点；在 `windows/tauri/src-tauri` 运行 `cargo check --bin lithe-windows`，与改动前的结果对比，确认没有新增错误。macOS 上存在 Windows 专有 API 的既有报错；交叉编译 `x86_64-pc-windows-msvc` 会卡在 `ring` 的 C 构建脚本；边界脚本不运行 `cargo`，发现不了这类问题 |
| 在 Windows 上验证 Windows 实现 | `./scripts/windows/build/build-windows.ps1 -Configuration Release`，再 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml` |

同时运行直接受影响的 crate 或 target 的测试。当前机器无法执行的平台检查必须明确报告；不得声称未执行的检查已经通过。

### 保持改动可审查

- 保留已有的未提交工作；不得修改无关文件，不得夹带大范围格式化或依赖升级。
- 不得提交 `.build/`、`.swiftpm/`、`target/`、`dist/`、`DerivedData/`、fixture 构建目录或本地 IDE 设置等产物。
- 未经任务明确要求，不得执行破坏性 Git 命令、创建提交、推送分支或修改发布元数据。
- 行为、职责或兼容面发生变化时，更新所属的 Agent Note；只是重构实现、既有决策不变时，不改写 Note。
- 本次启动的构建、测试、调试或预览应用，按 `AGENTS.md` 在结束后关闭；不得误关用户已有的实例。

### 交付说明

交付前确认：逻辑放在了正确的层（第三节），性能与内存影响已评估（第四节），相关验证已经执行，共享契约的消费者已经检查，没有写死机器专属的值。

最终说明写清：改了什么、验证了什么、提交了哪些 `refactor` Issue、还有哪些平台或测试限制。组件测试通过不等于整机工作流验收通过。
