---
name: develop-lithe
description: 在 Lithe 仓库进行实现、重构、审查、调试、测试、构建或文档工作时使用。遵循仓库架构、跨平台契约、编码与界面规则、硬编码限制及验证流程。
---

# Lithe 开发规范

本 Skill 是 Lithe 编码与验证规则的统一入口。以现有架构、相邻实现与测试、可执行验证脚本为依据，
不要套用与本仓库不符的通用框架惯例，也不要借局部任务引入无关架构。

路径除明确说明外均相对于仓库根目录；本 Skill 内的 Markdown 链接相对于当前文件。

## 一、开始前：确认范围与真源

先读改动附近的实现和测试，再按任务加载必要资料，不要默认加载全部参考文件。

| 任务 | 必须读取的资料 |
| --- | --- |
| 模块归属、依赖或架构边界调整 | `.agents/notes/implemented/architecture/` 中对应的已实现决策及平台边界文档 |
| 跨平台行为或共享接口 | `shared/contracts/application-boundary.md`、`shared/contracts/rust-core-api.md` 及相关 fixture |
| macOS 界面、控件或视觉交互 | [macOS 共享控件规范](references/macos-ui.md)，以及其中与本次改动相关的组件和 Agent Note |
| 分隔条、可调整面板、连续拖动、滚动等高频交互 | `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md`；连续列表另见本文件第四节 |
| 新增、修改或审查设置 | `.agents/notes/implemented/architecture/2026-10-25-settings-native-configuration-editing.md`，以及本文件第四节的真实配置规则 |
| 创建、迁移、更新、归档或审查 Agent 笔记 | `.agents/skills/agent-notes/SKILL.md`；架构决策与工程取舍以 `.agents/notes/` 的中文笔记为准 |
| 创建、修改或审查测试及测试基础设施 | `.agents/skills/write-stable-tests/SKILL.md`，按目标平台选择其参考资料与计时入口 |

发布、Issue、Windows 虚拟机诊断等专门任务继续按仓库 `AGENTS.md` 加载对应 Skill。

## 二、架构与职责

### 先复用成熟上游能力

重建成熟 IDE 基础设施属于需要论证的架构例外，不是普通开发捷径。
新增或扩展语言智能、项目导入、构建建模、依赖解析、编译、格式化、重构、测试发现、
运行/调试规划或 LSP/DAP 行为前：

- 盘点已打包上游工具的版本、现有能力、官方扩展点及兼容的成熟开源替代方案；
  先确认升级或启用已有能力能否解决问题，再考虑另写一套。
- 在许可、分发方式、资源开销和平台支持满足要求时，复用完整且一致的上游子系统；
  不要只借几个命令，却自行重建其项目状态、依赖图、生命周期或语义模型。
- 上游拥有的事实仍由上游引擎负责。例如所选 Java/项目后端已经提供的符号、源码根、模块归属、
  classpath、编译状态和调试目标，不得为了跨平台在 Core 里再维护第二份真源。
  Core 只做必要校验、规范化与编排契约。
- Lithe 聚焦产品编排：有界生命周期、取消、过期结果隔离、资源预算、稳定跨平台契约、界面呈现及端到端流程。
- 只有上游缺失能力、无法满足已证实需求、不能合法分发或违反实测产品约束时，才考虑自研。
  新建或扩展长期维护的子系统时，在所属 Agent Note 记录证据、被否复用方案、职责边界及移除/迁移路径。
- 不得超出许可逆向、复制、打包或围绕专有工具设计实现；只有条款允许时，才能依据公开行为或开放标准独立实现。

局部复用也必须保留上游子系统的正确性边界。验证完整的用户流程，
例如“保存 -> 同步项目状态 -> 构建 -> 解析运行路径 -> 启动”，不能只验证单条上游命令被调用。

### 目录归属

| 路径 | 职责 |
| --- | --- |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit 呈现及视图局部渲染 |
| `macos/Sources/Lithe/Models/` | 面向界面的模型及 `AppModel` 聚合 |
| `macos/Sources/Lithe/Application/` | 功能模型、状态转换与用户动作 |
| `macos/Sources/Lithe/Services/` | 产品工作流编排 |
| `macos/Sources/Lithe/Core/` | 平台无关端口及类型化 Rust 操作 |
| `macos/Sources/Lithe/Platform/MacOS/` | macOS 适配器与依赖组装 |
| `rust/lithe-core/` | 确定性的共享命令、模型、校验及 C ABI |
| `windows/` | 独立的 React/Tauri Windows 产品及 Rust 平台适配器 |
| `Plugins/mac/`、`Plugins/win/` | 对应平台拥有的插件包 |
| `frontend/editor/` | 共享 Monaco 呈现、词法着色及编辑器模型生命周期；不得调用平台 API |
| `shared/` | 跨平台契约及 fixture，不承载编译实现 |
| `scripts/`、`.github/` | 仓库级开发、验证脚本与 CI 工作流；脚本按作用分类，见“脚本放置与分类” |
| `third_party/` | 上游代码；除非任务明确针对它，否则不修改 |

macOS 是当前参考产品；Windows 是独立实现，不得导入 Swift 源码或依赖 macOS 类型。

### 脚本放置与分类

新增、移动或审查脚本时，遵守以下规则。

- 仓库级脚本（构建、打包、准备、验证、测试入口、发布、CI 辅助、诊断探针等）必须放在 `scripts/`
  下，不得散落在仓库根目录、`macos/`、`windows/`、`.github/` 或临时目录，也不得直接放在
  `scripts/` 根目录；必须进入下面某个分类子目录。
- 两类脚本不属于仓库级，随所属位置放置，不进 `scripts/`：Skill 自带的脚本放在该 Skill 的
  `scripts/`（例如 `.agents/skills/write-stable-tests/scripts/`）；单个包自己的构建脚本放在该包内
  （例如 `windows/tauri/scripts/`、插件包内的 `scripts/`）。
- 按脚本的作用语义分类，不按文件类型，也不按创建者分类。按下表从上到下选第一个匹配的目录：

| 目录 | 放什么 |
| --- | --- |
| `scripts/ci/common/` | 多个工作流共用的 CI 编排：变更分类、车道复用、复用校验、工作流门禁测试 |
| `scripts/ci/<工作流名>/` | 只为某一个工作流存在的脚本，目录名与工作流名对应（如 `cancel-closed-pr-runs`、`update-repo-charts`） |
| `scripts/release/{sparkle,macos,windows,autobuild,notes}/` | 发布流水线：Sparkle 更新与验签、更新清单、AutoBuild 发布、发布说明校验 |
| `scripts/macos/{build,package,prepare,test,verify,perf,probe}/` | 只服务 macOS 产品：构建、打包、依赖与资源准备、测试入口、门禁校验、性能基线、手动探针 |
| `scripts/windows/{build,package,prepare,test,verify,perf}/` | 只服务 Windows 产品，含义同上 |
| `scripts/rust-core/`、`architecture/`、`i18n/`、`agent-notes/`、`platform-feature-matrix/`、`plugins/`、`remote/`、`ide-mcp/`、`editor/`、`git-graph/`、`agent/`、`resources/` | 跨平台的领域脚本，目录名就是领域名 |

- 没有合适目录时，新建一个以领域或作用命名的目录，并在同一次改动里更新上表；不要新建
  `misc/`、`utils/`、`tools/` 这类不表达作用的目录。
- 例外：属于某个跨平台领域、但只在一个平台上运行的脚本，留在领域目录，文件名带平台名，不放进
  `scripts/macos/` 或 `scripts/windows/`（例如 `scripts/ide-mcp/build-windows-ide-mcp.mjs`、
  `scripts/ide-mcp/build-ide-mcp.sh`、`scripts/editor/package-macos-monaco.sh`）。这类脚本要在分类器和
  `plan-ci-lane-reuse.mjs` 里按完整路径登记，不要靠文件名里的平台子串匹配。
- 测试脚本与被测脚本放在同一目录，命名沿用 `test-*` 或 `*.test.*`。验收对象不是某个脚本的手动验收脚本
  （例如验收 Rust 代码的 `scripts/windows/test/test-windows-agent-recycle.ps1`）放在对应平台的 `test/`。
- 脚本引用同目录文件时，使用相对于脚本自身的位置（`$SCRIPT_DIR`、`import.meta.url`、`__dir__`、
  `$PSScriptRoot`），不要依赖当前工作目录。跨目录引用必须写完整的 `scripts/<分类>/<名字>`，
  Ruby 的 `require_relative` 和 Shell 的 `source` 也要带上相对目录，仅靠文件名搜索会漏掉它们。
- 用 `git mv` 移动脚本以保留历史。移动或新增后必须同步：
  - `.github/workflows/` 里的 `run:` 路径、`paths` 过滤器和循环（`*` 不跨 `/`，需要递归时用 `**`）。
  - `scripts/ci/common/classify-ci-changes.sh`（路径会先转小写，`case` 里的 `*` 可跨 `/`）和
    `scripts/ci/common/plan-ci-lane-reuse.mjs` 的基础设施规则。新路径必须被分类器识别；未知的
    `scripts/` 路径会按失败关闭处理并触发全量 CI。运行
    `./scripts/ci/common/test-classify-ci-changes.sh` 和
    `node --test scripts/ci/common/plan-ci-lane-reuse.test.mjs`。
  - 会把脚本复制进临时目录的测试夹具要保持相同的目录深度，被复制脚本通过相对路径依赖的文件也要一起复制。
  - 非脚本文件里写死的脚本路径，没有任何检查会替你发现遗漏，要逐个搜索确认：
    `windows/tauri/src-tauri/tauri.conf.json` 的 `beforeDevCommand`、`beforeBuildCommand`，
    `windows/tauri/package.json` 的 `scripts`，`Plugins/marketplace/official-plugins.json` 的 `inputPaths`。
    `inputPaths` 里的脚本被移动后，已有发布标签的插件会被
    `node scripts/plugins/official-plugin-releases.mjs check` 判为发布输入变化，需要按发布流程决定是否升版本。
  - 工作树资源注册表 `scripts/resources/worktree-resources.json` 和 `reuse-worktree-resources.mjs` 里的脚本路径，
    改完运行 `node --test scripts/resources/test-reuse-worktree-resources.mjs`。
  - 文档、Skill、Agent Note 和 `shared/platform-feature-matrix/` 中写明的路径。

### 分层边界

- Views 只接收 `AppModel` 或专用功能模型，不得调用 Rust C ABI、创建平台适配器或依赖具体工作流服务。
- Application 功能模型拥有界面状态转换并协调用户动作；平台初始化不得放进 `AppModel`。
- Services 通过端口编排，不得直接创建 `Process`、`Pipe`、`FileManager`、`FileHandle`、
  watcher、持久化存储或具体 `Mac*` 适配器。
- Core 与 Application 不得依赖 SwiftUI、AppKit、CoreServices、Tauri、WebView2、Win32 或具体平台实现。
- `MacServiceContainer` 是 macOS 依赖组装入口；平台能力放在 `macos/Sources/Lithe/Platform/MacOS/`。
- 两端共享的确定性行为放在 `rust/lithe-core/`；原生文件系统、进程、终端、运行时、安全、持久化和界面行为属于平台适配器。
- 跨平台本身不是复制成熟上游语义的理由；语言、构建、项目模型和调试事实继续由所选 provider 拥有。
- Windows 功能代码通过 `@/platform/tauri-core` 接入，禁止直接导入 Tauri core API。
  共享操作经 `lithe-core`；Windows 专属终端、watcher、凭据、进程和 WebView 行为留在 Tauri host 或平台插件。

### 共享契约

- 进程与语言边界使用 UTF-8 JSON；标识符使用 `/` 分隔的工作区相对路径，绝对路径仅用于平台拥有的诊断。
- 行号从 1 开始；缺失位置用 `null`；列表及序列化结果保持确定性顺序。
- 应用契约要求时，异步操作显式区分 `idle`、`loading`、`ready`、`failed`。
- 返回稳定错误码与面向用户的消息；平台专属细节放入契约的 `details` 字段。
- 新增 API 的返回码、错误码必须与错误类型一一对应：一个数值码（如 JSON-RPC `error.code`）不得同时代表
  多种错误，调用方应能只凭数值码分支。标准语义（方法不存在、参数错误、取消）沿用 JSON-RPC/LSP 标准码，
  其余各占服务端自定义区间的独立码，并在契约文档和 fixture 中列出映射；已发布协议版本的旧码保持不变，
  从新版本起区分。
- 进程型功能保留 `operationID`、取消、超时和过期结果语义。
- 第二个平台依赖新共享行为前，先补充或更新共享 fixture。
- 命令名、JSON 字段、错误码和 C ABI 都是兼容面；变更时同步更新契约文档及所有消费者。
- `lithe-core` 的公开 Rust 类型、结构体字段和函数签名也是兼容面：`windows/tauri/src-tauri` 与
  `windows/tauri/crates/project` 把它当 Rust 库直接链接，不经过 JSON/C ABI。macOS 通过 JSON 调用时缺省字段按
  `None` 处理，Windows 的结构体字面量却会因缺字段而编译失败（例如给 `JavaSelectionRequest` 新增
  `requirements` 曾让 Windows 安装包构建 E0063）。只改 Core 也要同时修正这些调用点。

## 三、语言与编码约定

遵循相邻代码风格；命名清晰，类型与函数职责集中，所有权明确，控制流直接。
不要夹带无关清理、推测性抽象或现有技术栈无需的新依赖。

### Swift 与 macOS

- 使用 `.swift-version` 固定的 Swift 6.3.3 工具链（Xcode 26.6）。
  应用 target 使用 Swift 5 语言模式，测试使用 Swift 6；不得顺手调整。
- 分层按第二节执行，不让平台类型泄漏到共享或应用接口。
- 测试沿用 `macos/Tests/LitheTests/` 的 Swift Testing 模式；稳定性、资源清理与逐项计时遵循 `write-stable-tests`。

### Rust

- 运行 `cargo fmt`，遵循所属 crate 与模块约定。
- 保持共享结果确定性、JSON envelope 和 C ABI 兼容；跨边界返回结构化失败，
  不把不稳定的 Rust 实现细节暴露为契约错误码。
- 命令、解析、校验、排序、取消或序列化变化，在所属 crate 增加测试。

#### Rust Core 注释仍使用英文

以下要求只适用于 `rust/lithe-core/` 的第一方代码，不扩展到其他 helper crate、
Windows/Tauri Rust crate、生成代码或第三方源码。本 Skill 中文化不改变注释语言要求。

- 注释使用英文，并随行为更新。
- 每个生产模块以简短 `//!` 说明职责或架构边界。
- 导出 API、共享请求/响应类型、核心领域类型及 C ABI 函数使用 `///`；说明所有权，
  unsafe 入口补充 `# Safety`；错误契约不明显时说明错误。
- 枚举、结构体、变体和字段的名称不足以说明语义、允许值、单位、所有权或协议角色时，
  必须补文档；内部类型同样适用。
- 实现内部用 `//` 解释不明显的兼容性、确定性、顺序、安全、性能或跨平台约束。
- 测试名和断言不足以说明意图时，补充场景、回归风险或保护边界。
- 不为覆盖率复述赋值、声明、名称，也不给简单访问器或直接控制流机械加注释。
- 较慢的 Rust Core 检查前先运行 `./scripts/rust-core/verify-rust-core-comments.sh`。
  脚本检查模块说明、导出 Rustdoc、英文注释及 unsafe 安全说明；
  它不要求每个内部 helper 都有文档，也不能替代对内部类型语义的人工检查。

### Windows、React 与 Tauri

- 前端脚本使用 Bun，Windows host 使用 Tauri 2。
  功能代码在 `windows/tauri/src/features`，共享界面在 `windows/tauri/src/ui`，
  invoke 边界在 `windows/tauri/src/platform`，原生 Rust 行为在 `windows/tauri/src-tauri`。
- 不恢复平行的 C++/Qt 应用层，也不为每个共享 Core 操作新增一个 Tauri command；
  兼容命令名通过中央 dispatcher 转换。
- 同步的 `#[tauri::command] fn` 在派发 IPC 的线程上内联执行，Windows 上就是 WebView2 UI 线程：
  它运行期间窗口停止绘制、输入排队，其他 invoke 也全部等待。凡是读写文件、遍历或删除目录、
  启动或探测进程（`java -version`、`mvn -version`、Shell、Agent）、注册原生监听的命令，
  必须写成 `async fn`，并把主体交给 `crate::blocking::run_blocking`；
  同步命令只用于读写内存状态、不碰磁盘和进程的轻量操作。
- 前端高频事件（诊断、进度、日志）不要逐条 `emit`：每次 `emit` 都是一次完整 IPC 往返，
  并且会广播到所有窗口。在一次 drain 内按 key 合并，然后整批发送，store 也一次更新完。
- 产品行为补前端测试，Rust 行为在所属 crate 测试；WebView2、ConPTY、安装、签名和更新行为必须在 Windows 验证。

## 四、界面与交互

### 共享控件入口

macOS 界面改动必须先读 [macOS 共享控件规范](references/macos-ui.md)。
该参考页维护菜单、输入、图标、标题栏、列表、选择、字体和滚动条的入口及验证要求；
业务视图只提供内容与动作，不得在调用处另造样式或交互配方。

### 连续列表随滚动自动加载

Git 历史、反汇编等连续浏览的分页列表必须像 IDEA 一样，在接近视口边缘时预取；
正常浏览不得要求反复点击“加载更多”或“上一页/下一页”。反汇编向上下两端扩展，Git 历史追加更早提交。
内存转储等离散页面仍可显式翻页，不把这一模式套给所有分页内容。

- 复用有界后端分页和现有原生/虚拟化渲染器，不得一次拉取全量或创建所有行来伪装无限滚动。
  逐像素滚动状态留在局部视口；现有惰性 SwiftUI 列表复用 `LitheScrollLoadTrigger`。
  非惰性页脚的 `onAppear` 不能证明页脚进入了可见视口；原生渲染器保留自身视口所有权。
- 前插或追加时保留选择及可见行的像素偏移。定位指令只做必要的纵向滚动，
  不得把代码横向居中或重置用户手动调整的横向位置。
- 后台状态/watcher 刷新不得把已加载窗口缩回第一页，也不得短暂移除分页页脚。
  原子刷新已加载窗口；结果未变时保留呈现身份。顶部插入新行时，用行身份加像素偏移锚定视口，
  不以选中行代替视口锚点；显式上下文切换或导航可重新定位。
- 对在途请求和返回身份去重，上下文变化后拒绝过期结果；数据耗尽或分页无进展时停止。
  失败后暂停自动请求并提供本地化的显式重试，不得因边缘仍可见就持续重试。
- 调试器可能拒绝跨越未映射地址的整页请求，而不是返回空页。
  此时用有界请求序列缩小反汇编窗口；只有最近邻也失败、且适配器仍能读取已知边缘时，才停止该方向。
  保留真实传输/超时错误，忽略无效填充，不猜测 CPU 指令大小，不对适配器的不透明地址做算术。
- 验证真实视口滚动、前插/追加锚定、缩放、短内容与溢出内容、失败/重试、耗尽和取消。
  宣称产品两端一致前，先检查另一平台实际行为。

### 设置说明收进信息提示

- 设置、分组、页面和插件选项的解释放进信息提示 `LitheInfoTip`：使用 `LitheSettingsRow`、
  `LitheSettingsLabel` 的 `info:` 或 `LitheSettingsSection` 的 accessory。
  插件设置的 `description`、动作的 `summary` 同样通过信息提示或悬停帮助显示，不在页面平铺。
- 禁止控件下说明段落、说明性 caption，或把描述塞进行的 badge 列。
  每行保持紧凑的“标签、控件、动态值 badge”；badge 仅显示有效值、作用域、来源、生效情况等状态。
- 允许持续显示需要用户处理的实时状态：错误、警告、需要重启、空状态及系统读取值。
  新增解释时，同次改动补齐信息提示及共享中文词条，生成流程见本节 i18n 规则。

### 读取并编辑工具真实配置（Source-backed settings）

新增、修改或审查设置前，先读第一节列出的原生配置决策。非敏感工具配置默认遵循：

1. 按工具支持的优先级，通过平台适配器发现实际来源；打开页面只读。
   区分文件缺失、上游默认值、读取失败与本地覆盖，不编造当前值。
2. 控件回显可编辑的非敏感当前值，不只给占位符；用紧凑 badge 标明来源和作用域，解释放进信息提示。
   继承生效值与显式保存的覆盖值必须可区分。
3. 编辑只产生草稿。替换原生配置前，要求明确的保存/应用确认，说明目标和作用域。
   不得在按键、失焦、离页或开页时写入；取消不写入，未修改不创建覆盖。
4. 写入已确认的原生来源，不维护实际上无效的平行应用配置。
   保留无关内容、权限、格式支持的注释与秘密字段；使用带冲突保护的原子替换，拒绝覆盖过期快照。
5. 成功后重新读取原生/有效配置再显示，说明更高优先级覆盖或重新连接要求。
   失败保留草稿且不报成功；外部重载与恢复默认值不得被过期的失焦/离页提交覆盖。
6. 密码、token、私钥、凭据字段不进入普通输入、日志、预览或 fixture，也不得把脱敏标记重新保存为秘密。
   打包资源只读；继承/只读来源需要明确选择可写覆盖位置，不静默提权写入。

优先复用上游配置读写器或现有适配器，不另造优先级模型。
真正由 Lithe 拥有的偏好可留在应用存储，但须说明作用域，不伪装成工具原生配置。
不要因为规则更新就批量迁移无关页面。

验证“发现 -> 回显 -> 编辑 -> 确认/取消 -> 冲突保护写入 -> 回读 -> 重开”，
并覆盖秘密、冲突、读取失败和重置生命周期。平台矩阵记录真实实现证据；
规则更新不代表现有页面已经全部迁移或通过运行时验证。

### 界面文案与 i18n

所有用户可见文案必须走共享 i18n，词条唯一来源是 `shared/i18n/`；
具体格式见 `shared/i18n/README.md`。硬编码会在系统语言与应用语言不一致时漏出错误语言。

- 视图字面量交给 SwiftUI（`Text("…")`、`Button("…")`、`.help("…")` 等）按环境语言查表；
  字面量必须有共享词条，否则所有语言都会显示英文。
- 视图之外的错误（含 `errorDescription`）、`NSAlert` 标题与按钮、`NSLocalizedDescriptionKey`、通知、状态文本及
  以 `String` 传入的 `title:`/`help:`/`message:` 等，统一用 `L10n.string("…")`（`LitheModuleAPI`）；
  运行时格式键用 `L10n.string(key:)`。
- 禁止直接调用 `String(localized:)`、`NSLocalizedString`，或只传 `locale:` 冒充应用语言选择；
  禁止在 Service/Core/Platform 拼接英文后直接显示，也不得拆句拼接翻译，应用带参数词条。
  调用方显式注入测试或 Agent 自有语言包是仅有的例外。
- 新增或修改文案时，同次改动完成：
  1. 在 `shared/i18n/messages.json` 声明词条、macOS 原生 key、参数和类型；`Int32` 用 `macos.formats` 声明 `d`。
     在 `locales/en-US.json`、`locales/zh-CN.json` 补齐译文；参数用 `{argN}`，不要重排。
  2. 运行 `node scripts/i18n/generate-i18n.mjs`，将生成结果纳入同次改动，不手改生成表。
  3. 运行第七节列出的三项 i18n 验证。
- 检查失败应修代码或补词条，不得放宽 `scripts/i18n/verify-app-language-localization.mjs`、扩大豁免、
  把文案藏进变量或改用 `Text(verbatim:)` 绕过检查。产品名、示例值、标识符等确实不翻译的内容才可豁免，且须在 PR 说明。
- 上游诊断、用户代码、Agent 返回内容和日志标识不属于界面翻译，保持原文。
- Windows 同样不得硬编码文案，使用 `windows/tauri/src/i18n` 接口并补齐共享词条。

## 五、安全、资源与失败处理

### 禁止硬编码环境细节

- 不得提交凭据、token、私有端点、签名材料或个人数据。
- 应用逻辑不得嵌入开发机路径、工作区根、用户主目录、临时目录或工具安装路径；
  可执行文件、存储位置、平台默认值经适配器或配置机制解析。
- 稳定产品常量集中命名，不在平台间重复魔法字符串或数字。
- 测试 fixture 可使用明显虚构的值，但不能含真实秘密或机器专属路径。

### 已安装程序包运行时只读

macOS app bundle 与 Windows 安装目录是发行基线；Sparkle delta 依赖精确字节，
运行时写入会改变基线，导致下次增量校验失败并回退完整下载。

- 缓存、索引、Eclipse/OSGi 状态、下载、解压、日志和锁文件经平台存储适配器放进缓存、
  Application Support、临时目录或工作区。禁止从 `Bundle.main.resourceURL`、`resource_dir()` 或安装目录推导写入位置。
- Equinox 等会向自身旁边写入的工具，必须在可写缓存使用输入副本；
  `-configuration` 示例见 `rust/lithe-core/src/lsp/languages/jdt_configuration.rs`。
- 新打包运行时增加典型流程前后的安装文件清单比较测试，并保持 `scripts/macos/verify/verify-runtime-bundle-immutability.sh` 通过。

决策与完整生命周期规则见
`.agents/notes/implemented/bug-fix/2026-09-25-runtime-bundle-immutability-and-update-delta.md`
及仓库 `AGENTS.md`，不通过“启动前清理 bundle”修补。

### 显式处理失败

- 不静默吞错；在有足够上下文的层返回、翻译或记录错误。
- 跨 Rust、Swift、TypeScript、Tauri 或进程边界时保留稳定契约错误分类。
- 面向用户的失败须可行动，不泄漏凭据、环境内容或不必要的内部细节。
- 注释解释不明显的约束与取舍，不复述代码执行过程。

## 六、跨平台功能矩阵

每次新增用户可见能力或改变跨平台行为，都在同一 PR 更新
`shared/platform-feature-matrix/features/<id>.json`。

- 每个文件对应一项可独立验证的用户能力，包含两端的 `implementationStatus`、`verificationStatus`、
  证据路径、owner 和具体验证动作。单平台能力也必须为另一端记录 `implementationStatus: platform-specific`。
- 实现状态与验证状态独立。仅有代码而无运行时证据时，验证保持 `pending`；
  只有在目标平台完成验证流程后才标为 `verified`。JSON 中状态标签、图标与说明是生成器唯一状态真源。
- 公共状态定义放在 `shared/platform-feature-matrix/metadata.json`；只改日期或 metadata 不能满足能力更新门禁。
- 更新源数据后运行 `node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs`，检查
  `.artifacts/platform-feature-matrix/` 的 HTML/Markdown/CSV/JSON，不提交生成视图。
  公共视图随 Agent Notes 看板发布，PR CI 上传对应 revision 的产物。

### 完成与提 PR 前的强制门禁

平台实现改动未经本地等价 CI 门禁，不得声明完成、以可评审状态提交、推送或创建/更新 PR。
先检查相对 PR 基线的实际平台改动：

```bash
git diff --name-only origin/preview...HEAD
```

第二节所列平台实现路径发生变化时，运行：

```bash
./scripts/platform-feature-matrix/verify-platform-feature-matrix-change.sh origin/preview HEAD
./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh
```

已知 PR 精确 base/head SHA 时用它们替换示例引用。门禁报告缺少实质能力记录变更时，
先补相关 JSON 再继续。交付前也必须运行 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

`matrix-exempt` 仅允许 reviewer 用于已审查且没有用户可观察变化的重构，并在 PR 说明；
不得用来绕过功能变更。准备 PR 时，用户要求跳过可选测试也不豁免契约门禁。

## 七、验证与交付

### 按改动选择验证

迭代时先跑最小相关检查，交付前覆盖完整受影响范围；不要因为整理文档就重跑无关平台全量构建。

| 改动 | 最低相关验证 |
| --- | --- |
| 用户可见文案 | `node scripts/i18n/verify-app-language-localization.mjs`、`node scripts/i18n/generate-i18n.mjs --check`、`node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs` |
| Agent Notes 或架构决策迁移 | `./scripts/agent-notes/verify-agent-notes.sh` |
| 测试代码或基础设施 | `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`，再运行该 Skill 对应平台的逐项计时入口 |
| Swift 应用或测试 | `./scripts/macos/test/test-macos.sh` |
| Core、Services、Views 或依赖组装边界 | `./scripts/architecture/verify-service-boundaries.sh` |
| 共享应用行为或 JSON fixture | `./scripts/architecture/verify-shared-contracts.sh` |
| Rust Core、JSON C ABI 或 Swift bridge | 先 `./scripts/rust-core/verify-rust-core-comments.sh`，再 `./scripts/rust-core/verify-rust-core.sh` |
| Core 功能行为 | `./scripts/architecture/verify-core.sh` |
| Git graph 行为 | `./scripts/git-graph/verify-git-graph.sh` |
| 运行时资源与发行目录只读边界 | `./scripts/macos/verify/verify-runtime-bundle-immutability.sh` |
| 从 macOS/Linux 验证 Windows 边界 | `./scripts/windows/verify/verify-windows-boundaries.sh` |
| `lithe-core` 公开 Rust 类型或函数签名 | `rg '<类型或函数名>' windows/` 找 Windows 调用点；再在 `windows/tauri/src-tauri` 运行 `cargo check --bin lithe-windows`，与改动前对照，确认没有新增错误。macOS 上 Windows 专有 API 会有既有报错，交叉编译 `x86_64-pc-windows-msvc` 会被 `ring` 的 C 构建脚本卡住；边界脚本不跑 `cargo`，抓不到这类问题 |
| Windows 实现在 Windows 上验证 | `./scripts/windows/build/build-windows.ps1 -Configuration Release`，再 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml` |

同时运行直接受影响 crate/target 的测试。当前机器不能执行的平台检查须明确报告，不得声称未执行的检查通过。

### 保持改动可审查

- 保留已有未提交工作，不修改无关文件，不夹带大范围格式化或依赖升级。
- 不提交 `.build/`、`.swiftpm/`、`target/`、`dist/`、`DerivedData/`、fixture 构建目录或本地 IDE 设置等产物。
- 未经任务明确要求，不执行破坏性 Git 命令、创建提交、推送分支或修改发布元数据。
- 行为、职责或兼容面发生变化时，更新所属 Agent Note；仅实现重构且既有决策未变时，不重写笔记。
- 本次启动的构建、测试、调试或预览应用按 `AGENTS.md` 清理；不误关用户已有实例。

交付前确认职责层次正确、相关验证已执行、共享消费者已检查且无机器专属硬编码。
最终说明改了什么、验证了什么、尚有哪些平台或测试限制；组件测试不替代整机工作流验收。
