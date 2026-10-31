# macOS 插件公共 API 与开发文档实施计划

状态：待实施计划。盘点日期：2026-10-28；2026-10-30 按 preview `e8c4e9fc9` 刷新（#1517、#1515 已合并）。

## 当前实现进度（PR #1595）

本轮已将原有三组宿主内部服务注册为协议 3 的公共方法；`ui:4` 提供不打开
工具窗口的命令。逐方法授权、上下文 lease、编辑器返回 documentID/version、
真实 HTML 呈现模式、后端初始化/退出/通知背压也已接入。正式参数和限制以
`shared/contracts/plugins/v1/README.md` 为准，历史盘点表不是当前能力表。

尚未交付的部分包括：官方 SDK 新 API 的类型封装与发布、通用原生 Tree 后端
数据源、精确全文搜索匹配范围、文件修改/保存事务、可替换预览标签和 Windows
适配。三个完整安装插件的 UI 验收尚未全部完成，不把分层集成测试等同于整机验收。

## API-01–44 完成度总表（PR #1595）

这是**实现范围**，不是发布或全平台验收结论。已公开表示已注册到 Core 白名单及 macOS
宿主分发、插件可按权限调用；仍需以 `getCapabilities` 判断当前宿主支持的方法。
既有能力是本次复用的基线，不计为本 PR 新增交付。部分完成逐项写明缺口；未做不代表
IDE 内部没有相关功能。官方 SDK 新 API 封装/发布和三个完整安装插件整机验收仍未全部完成。
Windows 不在本轮，平台矩阵的 partial/pending 保持真实。

| ID | 本轮状态 | 可用部分与明确缺口 |
| --- | --- | --- |
| API-01 | 已公开 | 能力发现、backend:2 激活、订阅 dispose；新装后端仍需重启 |
| API-02 | 部分完成 | ui:4 无工具窗口的声明命令与 didRun；动态 register/有结果的 execute 未做 |
| API-03 | 部分完成 | 既有命令 placements 可用；通用菜单、快捷键贡献、context.set/状态栏未做 |
| API-04 | 部分完成 | didChangeContexts 与 watch 事件；文档/选区/活动编辑器语义事件未做 |
| API-05 | 已公开 | listContexts/getContext/getFolders，context/generation 与 rootID |
| API-06 | 已公开 | readDirectory/stat/readFile；公共读上限 128 KiB，内部上限不冒充协议能力 |
| API-07 | 已公开 | watch + subscriptions/notify/dispose，context/session 回收与溢出重扫 |
| API-08 | 部分完成 | findFiles/findText 分页与取消；只搜磁盘，精确匹配范围尚为 null |
| API-09 | 已公开 | documents/list/getSnapshot、editor/getActive/getSelections，含 dirty/版本/编码/EOL |
| API-10 | 已公开 | applyEdits/replaceSelections/insertText；版本校验、IME/只读拒绝、一次 Undo |
| API-11 | 未做 | 公共 save/saveAs/close 与工作区文件变更接口未接入 |
| API-12 | 未做 | 公共多文件 edit、content provider、showDiff 未接入 |
| API-13 | 部分完成 | 既有 ui:3 原生 Tree/List/Form；通用独立后端数据源/懒加载未做 |
| API-14 | 部分完成 | 既有包内网页 bridge、状态/生命周期；通用双向页面消息未做 |
| API-15 | 部分完成 | editor/open/reveal 返回 documentID/version；range 只起点光标，替换预览标签未做 |
| API-16 | 已公开 | preview/openHTML 支持 split/previewOnly；browser/openExternal 支持 HTTP(S)/已保存 HTML |
| API-17 | 部分完成 | 三类窗口消息和按钮/取消；通用 QuickPick/InputBox/授权文件句柄未做 |
| API-18 | 未做 | 通用剪贴板与 revealInFinder API 未开放 |
| API-19 | 部分完成 | 已有声明式设置 1/2；通用 settings.get/inspect/update/events 未做 |
| API-20 | 部分完成 | global/backend/workspace 可写目录与网页状态；统一 KV/配额/session API 未做 |
| API-21 | 既有能力 | 协议 2 credentials/get/set/delete；权限与插件隔离不变 |
| API-22 | 部分完成 | 既有函数进度与取消；独立 output channel、通用 log/progress API 未做 |
| API-23 | 部分完成 | 已有进程声明与运行时解析；通用 toolchains/process 服务未开放 |
| API-24 | 未做 | 插件专属终端 create/sendText/onExit 未开放 |
| API-25 | 部分完成 | 既有语言/LSP 贡献；新增 `languages:2` 声明式语法（`grammar.kind` 先支持 monarch，不依赖 LSP，Mac 免重启）；语言语义 Provider 未做 |
| API-26 | 未做 | 公共诊断 collection/events API 未开放；既有 LSP 诊断不等于该 API |
| API-27 | 部分完成 | 新增 `runMarkers:1` 运行标记装饰（插件函数回答可运行行，编辑器画行号旁按钮）；通用主题、片段、其他装饰未做 |
| API-28 | 未做 | 公共 custom editor 文档 owner/保存/撤销/恢复未开放 |
| API-29 | 部分完成 | #1517 BuildProvider 1–6/model inputs；新增从运行标记运行（`commands/didRun` 带 `runMarker`，后端可按 `onLanguage:` 激活）；新指南未齐全 |
| API-30 | 既有能力 | 已有 debugAdapters 1/2 与 DAP 宿主；本 PR 不重建调试协议 |
| API-31 | 既有能力 | 已有 vcsProviders:1；不包含内置 Git 公共读取面 |
| API-32 | 未做 | 通用 ServiceProvider 仍为提案 |
| API-33 | 既有能力 | 已有 projectGenerators:1；新 hooks 不在本轮 |
| API-34 | 未做 | 插件公共 IDE/AI/MCP 授权面未开放；独立 broker 不能直接转授 |
| API-35 | 未做 | 跨插件依赖/导出、远程 Provider 剩余接续未完成 |
| API-36 | 未做 | WASM/WASI 非本轮前置，未引入运行时 |
| API-37 | 部分完成 | getCapabilities 提供协议/方法/预算/后端执行位置；语言包与环境/主题事件未做 |
| API-38 | 未做 | 通用受管 fetch/download 未开放 |
| API-39 | 未做 | 通用 authentication session/provider 未开放 |
| API-40 | 部分完成 | 上下文携带 local/remote；新文件/编辑器服务对 remote 明确拒绝，非远程执行实现 |
| API-41 | 部分完成 | onWorkspaceOpen/onCommand、后台两路、initialize 超时/有界通知；内容匹配与全局冷启预算未做 |
| API-42 | 未做 | 内置 Git 公共 SCM 只读快照/events 未开放 |
| API-43 | 未做 | 保存前事件/带超时编辑尚未开放 |
| API-44 | 未做 | 插件贡献 Skills/Hooks/MCP 候选及独立授权评审未完成 |

### 当前公共调用面汇总

所有宿主请求以 `lithe/host/` 为前缀；这里的点号是阅读简写，正式方法使用 `/`。
精确参数、返回、权限、预算及失败语义见
[契约公共方法表](../../shared/contracts/plugins/v1/README.md#public-document-file-and-window-methods-protocol-version-3)。

| 分组 | 已开放请求 | 权限 |
| --- | --- | --- |
| 协商/释放 | getCapabilities、subscriptions.dispose | 隐式，仅本会话 |
| 工作区上下文 | workspace.listContexts/getContext/getFolders | workspace.metadata |
| 文件读取 | workspace.readDirectory/stat/readFile | workspace.files.read |
| 监听/搜索 | workspace.watch；workspace.findFiles/findText | workspace.files.watch；workspace.search |
| 文档/选区 | documents.list/getSnapshot；editor.getActive/getSelections | documents.read |
| 版本化编辑 | editor.applyEdits/replaceSelections/insertText | editor.edit |
| 打开/定位 | editor.open/reveal | editor.open |
| 预览/浏览器 | preview.openHTML；browser.openExternal | preview.open；browser.open |
| 窗口消息 | window.showInformation/showWarning/showError | window.messages |
| 本插件凭据 | credentials.get/set/delete | credentials.store |

宿主通知：workspace.didChangeContexts、subscriptions.notify、commands.didRun。
纯命令：ui:4 + backend:2，不再需要假窗口；didRun 不代表业务执行成功，也不伪装成
有结果的 commands.execute。完整工作流、旧协议降级、dirty/Unicode/Undo、资源清理的
实际验证证据见 PR 说明与 `.artifacts/test-stability/`，不要用这张表替代运行时验收。

## 1. 目标与范围

让第三方开发者不修改 Lithe 源码，就能完成“读取选区并转换文本”“显示工程文件树”“打开 HTML 预览”等完整工作流。优先把 Mac 已有功能接成有权限、版本、生命周期和文档的公共 API，而不是重写 IDE 或先换插件运行时。

本轮只规划 macOS。没有 Windows 实现任务、时间表或双端验收前置条件；共享数据协议仍不嵌入 SwiftUI/AppKit 类型。本 PR 不实现 API、不修改 schema/SDK，也不把未来能力记成已实现。

这是**主仓库内部执行计划和文档待办**，不是可直接使用的开发者 API 参考。下文所有“候选”方法、事件及文档路径都需要后续契约 PR 定义；不能直接写进现有 `plugin.json`。公开指南、API 参考、SDK 和示例最终交付到 [lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs)，不在本仓库维护第二套开发者手册。

架构选择由[公共扩展契约提案](../../.agents/notes/proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)持有；本文件负责能力盘点、任务拆分和验收。契约发布遵循[两仓库同步决策](../../.agents/notes/implemented/architecture/2026-10-23-plugin-contract-publishing.md)。

### 盘点基线

| 对象 | 固定版本与证据 | 使用限制 |
| --- | --- | --- |
| Lithe | [preview `e8c4e9fc933a`](https://github.com/1lck/Lithe-IDEA/tree/e8c4e9fc933a85f789d603371e77efd219214452) | 本文件的本地源码路径均相对此版本，已包含下面两个合并的 PR；源码存在不代表本次做过实机验收 |
| 插件文档/SDK | [main `be779d2000e3`](https://github.com/Lithe-IDEA/lithe-plugin-docs/tree/be779d2000e38415ea047fc2e2b2b7973e7d8e07) | 2026-10-30 复核仍是该 commit。`contract.lock.json` 锁定主仓库 `32021a86f0c6c4ad2964dbbe3c2bb7854d84ad67`，不能与本次 preview 基线混用；该锁之后 `shared/contracts/plugins/v1` 又有 4 个提交（含 #1517），副本尚未同步 |
| OpenIDEA | [`8ff8f229407d`](https://github.com/l0ng-ai/openidea/tree/8ff8f229407df73e722d0a933f8e0aebd48f516c) | 比较其公开源码，不推断全量功能成熟度或产品安全结论 |
| 原生 Provider 工作流 | [PR #1517](https://github.com/1lck/Lithe-IDEA/pull/1517)，合并提交 `659739011591`（2026-10-28 已合并） | 已在上面的 preview 中；Mac 已声明 `buildProviders:1–6`、`buildModelInputs:1`、`debugAdapters:1/2`，见 2.1 |
| 远程工作区适配 | [PR #1515](https://github.com/1lck/Lithe-IDEA/pull/1515)，合并提交 `823fe428384d`（2026-10-29 已合并，关联 #1507） | 已在上面的 preview 中，但 PR 自述为阶段性实现，功能矩阵保持 partial / pending；不得据此认定远程工作区已完整可用，范围与缺口见 API-40 |

后续认领任务时先刷新这些基线和 PR 状态，避免重做已合并能力。这里的“需补”表示在列出的公共入口中没有对应通用契约，不表示 IDE 内部完全没有该功能。

## 2. 结论：缺的是公共接入面，不是整台 IDE

### 2.1 已有能力与真正的缺口

| 表面 | 当前事实 | 仍需补齐 |
| --- | --- | --- |
| 清单与能力协商 | Mac 支持声明式 API level 1–4；`PluginManifest.hostCapabilities` 是宿主实际声明的版本表 [S1] | 每个新 API 同步完成 Core 校验、Mac 执行、权限、文档、旧版拒绝路径 |
| 原生插件界面 | `ui:3` 已有 Tree/List/Form、工具栏、右键和本地动作，不只是静态文本 [S3] | 动态数据源目前绑定自身 `buildSystemID` 和唯一匹配实例；需通用后端来源、懒加载和分页 |
| 命令 | `ui.commands` 打开自己的工具窗口；面板内动作可以调用函数 [S1/S3] | 不依赖窗口/构建系统的命令处理器，以及语义事件、上下文菜单、快捷键接入 |
| 自有网页 | 包内页面可走白名单 Web bridge [S4] | 不是完整文件/编辑器 API；新能力必须分别授权，不能开放 AppModel、DOM 或任意脚本入口 |
| 独立后端 | `backend:1` 是每插件一个应用级本机外部进程，只服务自己的网页；`${stateDir}` 可用，`${workspaceStateDir}` 被拒绝；后端会话未接入远程工作区注册表 [S2/S20] | 没有窗口的命令/事件插件不能直接复用该声明；需新版本上下文和激活模型，不能悄悄改 v1 的作用域 |
| 函数与宿主服务 | 私有函数已有注册、进度、取消、截止时间、撤回和失效结果处理；函数协议 v2 的宿主服务目前只有本插件凭据读写删除 [S2] | 编辑器、工作区、通知等宿主 API 尚需逐项开放；不能把私有函数当跨插件公共服务 |
| 领域插件 | Core 已允许没有 UI/语言的纯 Build、VCS、Debug、项目生成器插件；#1517 已合并，Mac 已声明 `buildProviders:1–6`、`buildModelInputs:1`、`debugAdapters:1/2` [S1/S11] | 纯命令插件仍是独立缺口；Build/Run/Test/Debug 缺的是文档、SDK 对齐和真实项目端到端验收，不从零另造 Provider；内置 Git 不在 VCS Provider 层 [S21] |
| IDE 自动化 | 已有单独授权的 IDE/MCP broker，含项目/环境、Maven、Run 和操作输出等 13 个工具 [S15] | 它不是声明式后端默认可用的 SDK；原生 `IDECapabilitiesProviding` 不等于公共插件授权 |
| 生命周期 | 外部进程、网页、原生面板已有自己的所有权和清理路径 [S2/S3/S4] | 不等于所有插件都能热加载；当前纯 Debug Adapter 的热激活范围不能扩大宣传 [S18] |
| 工作区 authority | 远程文件夹在本机是空的占位根目录，`RemoteWorkspaceRegistry` 按 URL 绑定会话和远程根；文件、工作区、终端、Build 以及 Build/VCS/语言 Provider 启动已路由到远程适配器 [S20] | 公共 API 还没有 authority 概念；`backend:1` 与 Web bridge 不识别远程绑定；远程 Java 原生集成、Agent 执行位置和 SSH 调试仍待完成 |
| 激活与信任 | `activationEvents` 与 Provider 一一对应并由 Core 校验（`plugin.activation.invalid`）；`onCommand` 只对应 `ui.commands` 的窗口命令 [S1] | 没有独立命令、工作区匹配等事件，也没有按激活事件统一限制并发数和冷启动时间的预算；应用没有工作区信任概念，只有逐操作的进程启动确认 [S4] |
| 内置 Git | Git 在 `LitheGitModule`，按 2026-10-22 评审不接入统一 VCS 层；IDE broker 的 13 个工具没有 Git 工具 [S15/S21] | API-31 只覆盖插件提供的 VCS，插件没有读取内置 Git 状态的公共入口 |
| Agent 侧 | Skills、Hooks、MCP 是用户管理的 Codex/Claude 原生配置，宿主只读取并编辑用户选定的来源 [S22] | 插件没有贡献来源；不能让插件绕过用户确认写入这些配置 |

Mac 当前声明的能力版本为：`backend:1`、`buildModelInputs:1`、`buildProviders:1–6`、`buildSystems:1/2`、`debugAdapters:1/2`、`executionProviders:1`、`executableResolution:1`、`languageServers:1/2`、`languages:1`、`packageTrust:1`、`projectGenerators:1`、`serverProcess:1`、`settings:1/2`、`ui:1/2/3`、`vcsProviders:1`。Core 能校验某版本不等于 Mac 会执行它：Core 的 `serverProcess` 声明 1/2，而 Mac 只声明 1，不能因此给 Mac 标记支持 `serverProcess:2`。以上以 `PluginTypes.swift` 的 `hostCapabilities` 为准，与 Core 的 `SUPPORTED_CAPABILITIES` 逐项比对过，唯一差异是 `serverProcess`。

当前 Web bridge 的方法白名单为 `build.instances/refresh/runTask/runTests/cancel/dependencies/setOptions`、`workspace.openFile`、`ui.getState/setState`、`functions.list/invoke/cancel`、`dialog.openFile/saveFile`。后两个选择文件方法已在 Mac bridge v2 实现；盘点不能只依据较早 README 的列表。网页调用权限也不自动转授给后端进程。

### 2.2 参考 OpenIDEA 和 VS Code 的哪些部分

| 参考对象 | 已核对的做法 | Lithe 应借鉴/不照搬的部分 |
| --- | --- | --- |
| OpenIDEA [WIT 接口](https://github.com/l0ng-ai/openidea/blob/8ff8f229407df73e722d0a933f8e0aebd48f516c/wit/plugin.wit) | v0.1 定义日志、命令注册、通知、工程根/当前文件、读文件、插入文本/替换选区、语言/主题注册，以及激活/停用/命令回调 | 借鉴“小而明确的宿主能力面”；不把这份短接口当完整 IDE SDK，也不直接复制全局隐式上下文或缺少版本参数的编辑设计 |
| OpenIDEA [运行时](https://github.com/l0ng-ai/openidea/blob/8ff8f229407df73e722d0a933f8e0aebd48f516c/crates/ide-plugin/src/runtime.rs) | 使用 Wasmtime Component、WASI、内存限制、fuel 与 epoch 截止时间 | WASM 由运行时和宿主适配提供，不是 Tauri 自动提供；Lithe 的 Rust/Mac 宿主也能接，但仍需同样的 API、权限、分发和清理工作 |
| VS Code [能力概览](https://code.visualstudio.com/api/extension-capabilities/overview)、[贡献点](https://code.visualstudio.com/api/references/contribution-points)、[API](https://code.visualstudio.com/api/references/vscode-api) | 声明贡献、可调用 API、事件与 Provider 分工；使用稳定资源和注册/释放模型 | 借鉴分层和文档组织，不承诺兼容 `vscode` 包、VSIX 或照搬全部接口 |
| VS Code [Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host)、[运行时安全](https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security) | 桌面扩展可在 Node.js 扩展宿主执行，Web 扩展使用受限浏览器运行环境；进程隔离不等于 OS 沙盒 | 继续让第三方执行逻辑位于外部宿主；权限代理只能约束代理通道，不能承诺限制任意原生后端的一切系统调用 |
| VS Code [Webview](https://code.visualstudio.com/api/extension-guides/webview)、[Custom Editor](https://code.visualstudio.com/api/extension-guides/custom-editors)、[WASM](https://code.visualstudio.com/blogs/2024/05/08/wasm) | 网页界面、文档编辑器和可移植运行时是不同扩展层 | 原生 Tree/Form 优先；复杂网页可选；WASM 不能代替编辑器保存/撤销、权限和生命周期协议 |

## 3. API 任务清单

记号：**H** = 插件调用宿主服务；**P** = 插件提供业务数据/行为，由宿主调用；**C** = 清单声明贡献；**E** = 宿主推送语义事件。一个 SDK 可以封装这四类，但不能把它们合成绕过权限的 `invokeAnything`。

阶段：**M0** 协商、作用域与 authority；**M1** 独立命令/只读编辑器；**M2** 安全文本修改；**M3** 文件树/面板/预览；**M4** 领域接续；**后续** = 有真实需求再立项，不阻塞首版。每行都有稳定任务 ID；正式签名、参数和数字预算在实现 PR 定稿。权限栏是评审分类，不是现有清单字段名。

### 3.1 激活、命令与事件

| ID / 方向 | 候选能力与现状/所有者 | 权限、作用域与验收 | 阶段 |
| --- | --- | --- | --- |
| API-01 H/C | `host.getCapabilities`、激活/停用、`subscriptions.dispose`；扩展已有协商和会话 [S1/S2] | 新版本才允许无网页后端；返回实际可用能力与预算，不以版本号推测权限。旧 `backend:1` 仍按应用级、页面入口工作 | M0 |
| API-02 C/P/H | `commands.register`、受限 `commands.execute`；复用命令目录/快捷键 [S8]，补独立 handler | 命令 ID 归插件；只允许自身命令及明确列出的宿主命令；后端回调不得绕回自身 Provider。无窗口无构建系统的命令能出现、调用并卸载 | M1 |
| API-03 C/H | `menus.contribute`、`keybindings.contribute`、`context.set`、状态栏项；已有内部入口 [S8] | 上下文键命名空间化、条件表达式有白名单；不截获任意按钮或系统快捷键。冲突可见，用户快捷键优先；菜单隐藏不是权限检查 | M1：命令入口；M3：其他贡献 |
| API-04 E | `workspace.onDidChange`、`documents.onDidOpen/Change/Save/Close`、`editor.onDidChangeActive/Selection`；内部观察不等于公开事件 [S5/S6] | 订阅前授权；事件带工作区/文档版本；高频事件合并、限流、有丢失后重取快照规则。切换/关闭项目及 dispose 后不再交付旧事件 | M1：活动编辑器/选区；M3：其余 |
| API-41 C/H | 激活事件与启动预算：独立命令、工作区内容匹配等候选事件；现有 `activationEvents` 只能对应已声明的 Provider/窗口命令（`validate_activation_events`）[S1] | 事件集合由宿主枚举，不接受任意表达式；每个事件有并发激活数、超时、失败退避和冷启动总预算，慢或崩溃的插件不拖慢打开窗口与输入。激活不绕过授权和逐操作确认；默认不提供“启动即激活”。是否引入工作区信任由 M0 决定，见 4.2 | M0：事件集合与预算；M1：命令事件 |

“监听按钮”的对外模型应当是“我贡献的命令被执行”“我的树节点被激活”“文档已保存”，而不是监听任意 SwiftUI 控件的 click。界面布局变化不应使插件失效，也不能借监听入口窃取其他插件输入。

### 3.2 工作区、文件、搜索与文档

| ID / 方向 | 候选能力与现状/所有者 | 权限、作用域与验收 | 阶段 |
| --- | --- | --- | --- |
| API-05 H/E | `workspace.getFolders/getContext`、工作区变更；复用工程模型 [S6]，远程工作区的本机占位根不能直接当资源标识 [S20] | 只读元数据授权；返回宿主签发的上下文和相对资源标识。即使 v1 仅一个根，也显式表达根 ID 和 authority（见 API-40）；无工程时明确为空 | M0/M1 |
| API-06 H | `workspace.readDirectory/stat/readFile`；已有文件端口 [S6] | 文件读取授权；目录分页、深度/字节限额、编码/二进制结果；隐藏/忽略规则和符号链接策略写入契约。不会整棵树一次读入或逃逸根目录 | M3 |
| API-07 H/E | `workspace.watch`；复用目录/文件观察端口 [S6] | watcher 归订阅与工作区，关闭/禁用后释放；溢出报告需重扫，事件不是每次 OS 变更的精确日志。旧工作区事件不能刷新新树 | M3 |
| API-08 H | `workspace.findFiles/findText`；已有搜索 owner [S7] | 读取授权、取消、分页/截断、忽略规则；明确搜索磁盘还是包含未保存缓冲区。复用索引，不让每个插件再扫描全盘 | M3 |
| API-09 H/E | `documents.list/getSnapshot`、`editor.getActive/getSelections`；已有文档和 Monaco 模型 [S5] | 编辑器读取与磁盘读取分开授权；返回文档 ID、版本、语言、只读/dirty、编码/EOL。选区读到未保存内容，而不是偷偷读盘 | M1 |
| API-10 H | `editor.applyEdits/replaceSelections/insertText`；已有编辑与 LSP WorkspaceEdit 链路 [S5] | 编辑授权、明确文档/预期版本；先做单文档完整校验再应用，形成一个撤销组。版本冲突、越界、重叠范围或输入法组合中安全拒绝/延后，不覆盖用户新输入 | M2 |
| API-11 H | `documents.save/saveAs/close`、`workspace.create/rename/copy/trash`；文件端口已有部分保护 [S5/S6] | 保存/文件变更单独授权；打开文档走文档 owner，校验磁盘身份及用户确认，不以直接写盘绕过 dirty/编码。首版不提供无确认永久删除 | M3：保存；后续：文件变更 |
| API-12 H/P | `workspace.applyEdit`、`documents.registerContentProvider`、`editor.showDiff`；已有虚拟文档和 diff [S5] | 多文件预览、逐项版本和只读校验；明确部分失败/恢复语义，不承诺现有 LSP 实现已具备跨文件原子回滚。只读虚拟资源先行 | M2：复用 diff 预览；后续：虚拟/多文件 |
| API-40 H/E | 工作区 authority：`workspace.getContext` 和资源标识携带 authority（本机或某个远程连接）。现状：远程文件夹是本机空占位根，文件、工作区、终端、Build 和 Build/VCS/语言 Provider 启动按 URL 路由到远程适配器；`backend:1` 与 Web bridge 只按本机 `workspaceURL` 工作，不识别远程绑定 [S20] | 首版只承诺 `local`；对未实现 authority 的任何新 API 必须返回稳定的“不支持”错误，不得把占位根或远程路径当本机路径读写，也不得静默在本机执行。占位根路径不是可持久化的资源 ID。远程 Java 原生集成、Agent、SSH 调试按远程 Note 推进，不借本项宣称完成。验收：本机与远程两个工作区同时打开时不串数据 | M0 |
| API-43 E/P | `documents.onWillSave`：保存前事件，可选返回编辑。现状：保存经 `DocumentFeatureModel` 的保存入口落盘，没有保存前钩子；编辑器只有手动格式化动作 [S5] | 依赖 API-10 的版本化编辑授权与 API-04 的文档事件；带保存原因（手动/全部保存/关闭前/自动保存）。保存前等待有严格截止时间，超时则放弃该插件结果并继续保存，不卡住保存与主线程；保存期间有新输入则丢弃旧结果；只读/大文件/自动保存的规则和多插件顺序、冲突在契约 PR 定义。不能用它读取磁盘或阻止保存 | M3，晚于 M2 |

文件树至少区分两件事：读取授权目录的数据，以及取得工作台 Project 视图的选中项。前者是文件 API，后者是受窗口约束的 UI 上下文；不把整套内部树模型或原生视图对象暴露出去。

### 3.3 原生 UI、网页与浏览器

| ID / 方向 | 候选能力与现状/所有者 | 权限、作用域与验收 | 阶段 |
| --- | --- | --- | --- |
| API-13 C/P/E | Tree/List/Form 通用数据源、`views.refresh/getChildren/reveal`、选择/激活/提交；已有 `ui:3` [S3] | UI 贡献权限；数据源不再被迫声明假构建系统。稳定节点 ID、懒加载、分页、错误保留旧数据；选中不等于执行，表单不逐按键调用后端 | M3 |
| API-14 C/H/E | 自有 Webview 的 `postMessage/onMessage`、显隐/销毁/状态；已有包内网页与 bridge [S4] | 只面向自己的页面；origin/主框架/页面 generation 验证、内容安全策略、消息/队列限额；关闭页面取消所属请求。不能控制编辑器 Webview 或别的插件页面 | M3 |
| API-15 H | `editor.open/reveal`；复用 `workspace.openFile` 与文档 owner [S4/S5] | 文件打开/编辑器访问权限，明确窗口、预览标签与定位范围；已打开 dirty 文档不被磁盘内容替换，后台窗口不抢焦点 | M1：已有打开入口接续；M3：统一选项 |
| API-16 H | `preview.openHTML`、`browser.openExternal`；已有内嵌 HTML 浏览器与系统打开 adapter [S9] | 分开授权本地预览和外部链接；内嵌可用当前缓冲区，外部本地文件读取磁盘，未保存时明确告知/请求保存。远程 URL 仅 http(s)，本地文件只接授权资源句柄，禁止任意 scheme/脚本注入 | M3 |
| API-17 H | `window.showInformation/Warning/Error`、`showQuickPick/showInputBox`、文件选择；已有平台 UI 和 bridge 文件对话框 [S4/S9] | 绑定窗口、频率/队列限额、取消结果；文件选择返回有范围/有效期的授权资源，不把选一次文件变成全盘读取许可 | M1：必要通知；M3：选择/输入 |
| API-18 H | `clipboard.readText/writeText`、`workspace.revealInFinder`；已有平台能力 [S9] | 剪贴板读写分别授权、敏感读取需用户触发；Finder 只显示授权目标。不得将系统剪贴板作为插件间隐式数据通道 | 后续 |

“用网页浏览器模式打开文件”不能混成一个万能 URL 接口：编辑器打开、内嵌 HTML 预览、自有包内 Webview、系统默认浏览器是四种安全边界。工程 HTML 和任意网页即使能执行 JavaScript，也不能获得插件 bridge 身份。

### 3.4 配置、状态、工具与语言能力

| ID / 方向 | 候选能力与现状/所有者 | 权限、作用域与验收 | 阶段 |
| --- | --- | --- | --- |
| API-19 H/C/E | `settings.get/inspect/update/onDidChange`；已有 settings 1/2 和注册表 [S10] | 只读/写入分权；区分 Lithe 偏好与工具真实配置，显示来源/作用域/有效值。工具配置显式 Apply、冲突保护、写后重读，不建立无效影子设置 | M3 |
| API-20 H | `storage.global/workspace/session`、包内只读资源；已有平台 state store [S2/S4] | 插件命名空间和配额；状态放平台可写位置，迁移/卸载策略明确。工作区状态不是 v1 应用级 `${stateDir}` 的别名，不写插件包/bundle | M0：作用域；M3：扩展接口 |
| API-21 H | `secrets.get/set/delete`；已有函数协议 v2 credentials 服务 [S2] | 保持本插件隔离和现有凭据授权；不得读取 IDE/Agent/其他插件密钥，不将 secret 放日志、普通配置或状态。先补 SDK/文档一致性，不另造密码库 | M1 |
| API-22 H/E | `output.createChannel/append/dispose`、`log`、`progress.withCancellation`；已有函数进度与输出生命周期 [S2/S11] | 插件/操作归属、日志脱敏与字节预算；取消/超时后不再更新 UI。只复用已有进度状态机，不把 stdout 协议流与业务日志混用 | M1：命令结果/进度；M3：独立输出 |
| API-23 H | `toolchains.resolve/list`、受管 `process.run/cancel`；已有 executable/runtime 解析与进程链路 [S1/S11] | 显式执行授权，executable/argv 分离，cwd/环境白名单、输出和超时上限、进程树清理；不提供任意 shell 字符串，也不自动下载运行时 | M4 |
| API-24 H/E | `terminal.create/show/sendText/onExit`；已有终端模块 [S12] | 创建与写终端都按执行授权处理；只控制自身终端，不能读用户其他会话或注入命令。禁用释放插件拥有资源，不停止用户独立终端 | 后续 |
| API-25 C/P | 语言/语法/LSP、补全/悬浮/定义/符号/格式化/重命名/Code Action；已有语言服务器贡献 [S1/S13] | 优先接成熟 LSP 的完整能力；自定义 Provider 仅补上游确实缺失项，按文档版本取消旧请求。避免让 SDK 成为第二套语言/工程引擎 | M4：已支持能力文档；`languages:2` 声明式语法已实现（见 Agent Note 2026-10-31-plugin-grammars-and-run-markers）；后续：新 Provider |
| API-26 H/P/E | `diagnostics.createCollection/set/delete/onDidChange`；已有 Problems/诊断 owner [S13] | 只能写本插件 collection，带文档版本和稳定范围；编辑/卸载后旧诊断可撤回。不能覆盖其他 LSP 结果或伪造宿主诊断身份 | M4 |
| API-27 C/H/P | 主题/图标/片段、只读装饰、CodeLens/Inlay；已有内部 theme/editor 能力 [S5/S16] | 数据贡献/资源路径校验、预算与卸载；图标/主题用宿主 token，不允许 CSS/原生视图注入。语言信息优先走 LSP，UI 资源不得执行脚本 | `runMarkers:1` 运行标记已实现（Mac；运行标记依赖后端，需要重启）；主题/片段/其他装饰后续 |
| API-28 C/P/H | `customEditors.register`、打开/保存/撤销/恢复；已有特殊文档视图不等于公开扩展点 [S5/S9] | 先说明唯一文档 owner 和 readonly/dirty/backup/undo 语义；可选 Webview 仅做视图。崩溃后可恢复且不丢未保存内容才可发布 | 后续 |

设置分类遵循[macOS 设置层级](../../.agents/notes/implemented/feature/2026-10-15-macos-settings-hierarchy.md)，原生配置编辑遵循[真实来源决策](../../.agents/notes/implemented/architecture/2026-10-25-settings-native-configuration-editing.md)。插件提供的文本/上游诊断不伪装成宿主翻译；宿主新增按钮、权限说明和错误必须走 `shared/i18n/`。

### 3.5 领域工作流与可选扩展

| ID / 方向 | 候选能力与现状/所有者 | 权限、作用域与验收 | 阶段 |
| --- | --- | --- | --- |
| API-29 P/C | Build/Task/Test/Run Preparation、只读工程模型输入；#1517 已合并，Mac 已声明 `buildProviders:1–6`、`buildModelInputs:1`、`debugAdapters:2` [S1/S11] | 本项只补文档、SDK 对齐和真实项目端到端验收，不重复定义协议。原生 Build/Test/Run 展示、准备、取消共用宿主；快照带源/版本，不能成为第二份 classpath/工程真相；远程工作区下的 Provider 启动限制见 API-40。从运行标记运行：点击按钮经 `lithe/host/commands/didRun` 把 `runMarker{id,languageID,path,line,version}` 交给插件命令 | M4；运行标记入口已实现（Mac） |
| API-30 P/C/E | Debug Adapter 注册、配置和会话事件；已有 DAP 宿主 [S14] | 进程/连接授权、launch 与 attach 所有权、终止和断开区别；复用断点/调试 UI。高级内存/反汇编按独立提案，不阻塞基础 API | M4 |
| API-31 P/C | VCS 仓库/状态/diff/提交等领域能力；已有 vcsProviders 1 [S14]，只覆盖插件提供的 VCS，内置 Git 见 API-42 | 读取与修改仓库分权；危险操作有明确确认，结果有仓库/操作身份。插件私有函数不能代替宿主可理解的 VCS 协议 | M4 |
| API-32 P/C/E | Services 的实例/状态/动作/日志；数据库已有自身路径，通用 ServiceProvider 仍为提案 [S17] | 插件拥有的连接/进程与用户外部服务分开；停用只清理前者，不默认停用户数据库/容器。服务接入现有 Services，不再画一套工作台 | 后续 |
| API-33 P/C | 项目生成器发现、参数、预览与生成；已有 projectGenerators 1 [S14] | 写目标目录需确认，禁止路径逃逸/无提示覆盖；只生成选择的项目，不下载未声明程序。先补现有文档，再评估新增 hooks | M4 |
| API-34 H/P | 受限 IDE/AI/MCP 能力；已有单独 IDE broker [S15] | 项目 opt-in 和 read/configure/execute 分权不变；不转交 broker token、全量 dispatcher 或 Agent 历史。是否开放、哪些调用方可用需独立威胁建模 | 后续 |
| API-35 H/P/C | 插件依赖、显式导出服务；远程 Provider 适配的剩余部分（原生 Java 集成、Agent、SSH 调试）[S17/S20] | 跨插件调用需要新授权/版本/循环依赖规则。远程 authority 基线已移到 API-40（M0），本项只在其上扩展；未实现的环境继续明确拒绝，不静默本地执行 | 后续 |
| API-36 运行时 | 可选 WASM Component/WASI 宿主；当前能力表无 WASM [S1] | 复用相同公共 API/权限；独立验证 WIT 版本、fuel/内存/时间预算、取消、沙盒可达性、签名、工具链和分发。不得预挂载整个 HOME/工作区或绕过主进程隔离 | 后续，非 M0–M4 前置 |
| API-42 H/E | 内置 Git 只读快照：`scm.getRepositories/getHead/getStatus/onDidChange` 一类候选。现状：Git 在 `LitheGitModule`（`GitFeatureModel`、`package` 级 `GitOperations`），不在统一 VCS 层；`VcsProvidersFeatureModel` 只用 Git 根判断归属，IDE broker 无 Git 工具 [S21] | 只读仓库元数据授权；经小型适配器返回仓库根 ID、当前分支/HEAD、ahead/behind 和有页大小上限的变更路径，不暴露 `GitOperations`/`GitChange` 等内部类型，不含 diff 内容、凭据或带令牌的远程 URL。暂存、提交、切分支等写操作不在本项，等统一 VCS 提案第 10 节的 Git 接入决策。事件合并限流；远程工作区按 API-40 的 authority 返回 | M3 |
| API-44 C | Agent 侧贡献：插件提供 Skill、Hook、MCP 服务器的候选清单。现状：Skills、Hooks、MCP 是用户管理的 Codex/Claude 原生配置，宿主只读取并编辑用户选定的来源，没有插件来源 [S22] | 插件只能提供可审阅的候选，不自动写入或启用；用户确认后才写入明确来源并重读结果。Hook 与 MCP 会执行命令，需单独授权、标注来源并可撤销；卸载插件不静默改动用户已导入的配置。不转交 IDE broker token 或 Agent 历史，与 API-34 一并做威胁建模 | 后续，独立安全评审 |

### 3.6 通用配套能力

| ID / 方向 | 候选能力与现状/所有者 | 权限、作用域与验收 | 阶段 |
| --- | --- | --- | --- |
| API-37 H/E | `environment.getInfo`、插件语言包/`l10n`、语言/主题变化；已有应用语言和主题 owner [S16/S19] | 只返回必要的产品/能力/界面语言信息，不导出进程环境、HOME 或账号；宿主文案走共享 i18n，插件文案用自己的包内语言资源并明确回退 | M1：最低能力信息；后续：完整语言包 |
| API-38 H | 可选受管 `network.fetch/download`；现有 HTTP adapter 服务具体业务，不是通用插件 API [S19] | 单独声明网络目标与授权；限制重定向、协议、内网目标、响应大小和超时，不转授宿主 cookie/代理凭据。下载只到平台可写临时目录，校验后显式交付，不能自动执行 | 后续 |
| API-39 H/P/E | 可选 `authentication.getSession/registerProvider` 与登录变化；已有 GitHub/Agent 专属账号流程 [S19] | 凭据存储不是“读取 IDE 账号”权限；须按插件、服务、账号、scope 显式授权，撤销和注销可见，复用系统浏览器/Keychain，不向任意插件提供宿主 GitHub 或 Agent token | 后续，独立安全评审 |

上述三项补齐常见 SDK 配套需求，不意味着为了首个文本插件就实现网络、账号平台或新的国际化引擎。原生后端自行联网与宿主代理联网是不同控制面，不能通过新增 `network` 权限假称已有后端被 OS 沙盒限制。

## 4. 每个实现 PR 必须回答的问题

以下为契约评审清单，不是新增的已生效协议。正式字段、错误码、权限项和 fixtures 与 Core 实现一起进入后续契约 PR；长期边界见公共扩展契约提案。

### 4.1 身份、调用方向与兼容性

- 谁能调用：包内网页、命令处理器、原生面板数据源和领域 Provider 分别列授权矩阵。声明能力不等于已授权，隐藏菜单不等于拒绝调用。
- 谁发起、操作哪里：插件 ID/包版本、后端 session、窗口、工作区及 generation、文档版本、调用/订阅 ID 由宿主核验。ID 不是可自行拼造的授权凭证；禁止缺少上下文时回退到“当前活动窗口”。
- 如何复用：扩展已有 JSON-RPC、函数注册、取消及进程管理。新无窗口激活入口与工作区能力单独协商；M0 在“按工作区会话”和“共享进程、隔离调用上下文”之间作出有测试依据的选择，明确身份与授权句柄寿命，不能把应用级 `backend:1` 悄悄解释为每工程一进程；同时规定 authority：`backend:1` 现在只在本机运行，远程工作区的新调用要显式拒绝（API-40）。
- 哪些回调会递归：初期 `commands.execute` 只覆盖明确允许的用户交互入口；不能让 Provider 后端借它回调 `lithe/build/*`、私有函数或完整 IDE dispatcher。现有递归拒绝规则保持有效，新调用方向先证明无循环等待。
- 哪些旧行为不变：API level、`requires` 能力版本、函数协议版本和 SDK 版本分别列出。未知/未实现能力明确拒绝；不靠更新 SDK 或提升一个大版本宣称全量可用。

### 4.2 权限和数据保护

- 分开评审工程元数据、磁盘读取、编辑器读取/修改、文件变更、执行、网络、外部打开、剪贴板和凭据。使用现有授权时明确复用关系，新增权限要解释用户如何理解、授予和撤销。
- 文件标识使用根 ID 与 `/` 分隔的工作区相对路径。平台 adapter 校验符号链接、大小写/Unicode 归一、路径穿越及检查后替换的竞态；不能仅用字符串前缀或一次 `realpath` 认定安全。
- 工作区外选择文件使用单独授权句柄；OS 绝对路径不作为可持久化公共资源 ID。远程/虚拟资源需要独立 scheme/authority 和访问策略；Mac 的远程工作区现在是本机空占位根加路由绑定，占位根路径不能当作资源 ID（API-40）。
- 工作区信任：应用现在没有工作区信任概念，只有逐操作确认（例如 Web bridge 启动进程前的确认）。M0 需决定是否引入信任状态；决定前，激活或命令入口不能借“已激活”绕过逐操作确认。契约 README 里“workspace trust”的措辞也要随决定校正。
- 进程分离、包签名和 capability grant 都不等于操作系统沙盒。原生后端本来可以使用自己的 OS 权限；文档必须区分“宿主代理拒绝访问”和“阻止恶意程序的一切文件/网络访问”。
- 发布 app、插件包及包内语言服务器只读。状态、日志、索引、锁和下载物走平台 storage/cache adapter；新增资源同时遵循 worktree 资源清单规则，不在此计划新增资源目录。

### 4.3 异步、事件与资源预算

- 复用已有 operation ID、取消、截止时间和迟到丢弃语义；请求进入终态后释放关联，旧结果不能落在复用的 ID 上。重试写操作前核对结果，不能默认跨崩溃“恰好执行一次”。
- 每个订阅、watcher、页面和进程写清创建者与释放者。关闭工作区、插件禁用/更新/卸载、崩溃和授权撤销都要走有界清理；插件自有任务与用户独立操作不能混淆。
- 事件写清顺序范围、合并、溢出和重取快照机制，不能宣称全局严格顺序或每次磁盘变化都送达。订阅与初始快照之间要用版本/游标避免静默漏变更。
- 每个接口确定可测试的页大小、总字节、并发数、队列深度、速率、超时及截断行为；数值由现有预算或测量支持。慢插件不能堵塞主线程、编辑输入或其他插件。
- 错误区分未支持、未授权、上下文失效、版本冲突、参数/范围错误、超限、取消、超时及后端退出。具体稳定码在契约 PR 定义，平台细节放 `details`，凭据和敏感内容不能泄漏。

### 4.4 编辑器一致性与上游复用

- 磁盘文件和未保存文档是不同数据源。读取、搜索、预览和保存都要声明使用哪个；文档 owner 是 dirty/版本/撤销的唯一协调者，禁止插件直接写盘替代编辑。
- 产品位置保持一基行号，列单位、范围端点、空选区和多选区排序必须明确；与 Monaco/LSP 的零基行号、UTF-16 列之间只在适配边界转换。用 emoji、组合字符、CRLF、中文输入法验证，而不是只测 ASCII。
- `LanguageWorkspaceEditService` 是现有接入点，不是任意第三方编辑已经安全的证据。M2 需补身份、版本、完整预校验和 undo 验收；多文件事务/失败恢复单独设计。
- 语言、构建、依赖、运行与调试事实继续来自成熟的 LSP/DAP/构建工具。先检查已有上游版本和扩展点；Lithe 提供权限、取消、稳定结果和原生展示，不复制 Maven/JDT 等工程语义。

## 5. SDK 与公开文档交付清单

### 5.1 先消除“源码支持 = 已发版 = 宿主可用”的误解

以下是固定 SDK commit 的源码盘点，不是本次运行 SDK 测试的结果。

| SDK | 源码已见能力 | 仍需核对/补齐 | 已核实发布物 |
| --- | --- | --- | --- |
| [Node 源码](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/be779d2000e38415ea047fc2e2b2b7973e7d8e07/sdk/node/src/backend.mjs) | Build、私有 Functions v1、VCS；开发中 Build 2–6 的执行、测试、发现、Run/Debug 准备、模型输入 | 通用 host API、Functions v2/credentials 等不能因 Rust SDK 有就宣称 Node 也有；宿主侧 Build 2–6 已随 #1517 合入 preview，但文档仓库的契约副本早于该合并，需先同步契约再对齐 SDK 与 fixtures | [sdk-node-v0.1.0](https://github.com/Lithe-IDEA/lithe-plugin-docs/releases/tag/sdk-node-v0.1.0)，2026-10-23；源码新功能不等于已在此包发布 |
| [Java 源码](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/be779d2000e38415ea047fc2e2b2b7973e7d8e07/sdk/java/plugin-sdk/src/main/java/io/github/litheidea/plugin/sdk/Backend.java) | Build、私有 Functions v1；开发中 Build 2–6 | 本次源码未见 VCS/credentials 实现，不能写成与 Node/Rust 全量对等 | [历史 sdk-java-v0.1.0](https://github.com/1lck/Lithe-IDEA/releases/tag/sdk-java-v0.1.0)，2026-10-20，JAR 与 SHA-256 |
| [Rust 说明](https://github.com/Lithe-IDEA/lithe-plugin-docs/blob/be779d2000e38415ea047fc2e2b2b7973e7d8e07/sdk/rust/README.md) | Functions v1/v2、credentials，独立后端示例 | 明确尚不实现 Build/VCS；文档描述 release 方案不等于该 tag 已发布 | 本次未核实到 Rust SDK 正式 release，不提供可用发布承诺 |

实施时优先把 Node/TypeScript 的类型和异步调用体验做完整，再以同一 fixtures 对齐 Java/Rust 的所选能力。**Node 优先不是把所有插件强制改成 JavaScript**；已有后端协议继续允许其他语言。每个 SDK 标注“源码实现/已发布版本/最低 Mac 能力/测试证据”，不以“官方 SDK”掩盖缺口。

### 5.2 需要编写或更新的文档

路径均相对 **lithe-plugin-docs**，是后续交付目标，不是本 PR 新建文件。已有指南优先更新，不重复写第二份。每个 API 任务完成时同步补相应文档与可运行示例，不等全部 API 完成后才写教程。

| 文档 ID | 拟交付页面/更新位置 | 必须讲清楚什么 | 对应任务/阶段 |
| --- | --- | --- | --- |
| DOC-01 | `README.md`、`guides/macos-plugin-quickstart.md` | 声明式/原生面板/网页/后端怎么选；安装、运行依赖、最小命令插件；Mac-only 支持范围 | API-01/02，M0–M1 |
| DOC-02 | `reference/capabilities-and-versions.md` | API level、requires、协议、SDK 与 release 四维矩阵；未知能力和兼容性错误；已支持/开发中分开；激活事件集合与版本 | 全部，M0 起 |
| DOC-03 | `guides/security-and-permissions.md` | 用户授权/撤销、工作区/窗口范围、路径与网络边界、原生进程非沙盒事实、密钥与日志 | 全部，M0 起 |
| DOC-04 | `reference/lifecycle-and-errors.md` | 激活条件与事件、启动预算、无窗口后端、dispose、取消/超时、失败、崩溃恢复、重试和错误表 | API-01/04/20/22/41，M0–M1 |
| DOC-05 | `reference/commands-and-events.md` | handler/贡献/事件区别；菜单、快捷键、上下文键；事件过滤、初始快照和背压 | API-02–04，M1/M3 |
| DOC-06 | `reference/workspace-and-files.md` | 目录分页/懒加载、读取/编码、watch、搜索、授权资源句柄、文件修改 | API-05–08/11，M3 |
| DOC-07 | `reference/documents-and-editor.md` | dirty 与磁盘、版本/范围/UTF-16、选区、单次 undo、安全保存、保存前事件与超时、diff/只读/多文件限制 | API-09–12/15/43，M1–M3 |
| DOC-08 | `guides/native-ui-and-webviews.md` | 原生 Tree/List/Form 与包内网页的选择；数据源、动作、页面消息、恢复/释放、限制 | API-13/14，M3 |
| DOC-09 | `guides/browser-and-preview.md` | 编辑器/内嵌 HTML/自有网页/外部浏览器四分法；未保存内容、网络及 bridge 隔离 | API-15/16，M3 |
| DOC-10 | `reference/settings-storage-and-secrets.md` | 真实工具配置与偏好区别、scope、Apply/冲突、状态迁移/卸载、凭据授权 | API-19–21，M1/M3 |
| DOC-11 | `reference/window-output-and-execution.md` | 通知/选择/进度/输出、剪贴板、toolchain/process/terminal 权限和所有权 | API-17/18/22–24，随对应阶段 |
| DOC-12 | 更新 `guides/lsp-plugin-lifecycle.md`、`guides/build-tool-integration.md`、`guides/native-build-workflows.md`、`guides/debug-adapter-plugin.md`；补 VCS/项目生成器参考 | 领域 Provider 接入原生工作流、已合并的 buildProviders 2–6/debugAdapters 2 协议最低版本、远程工作区下的启动限制、上游复用和端到端链路 | API-25/26/29–31/33，M4 |
| DOC-13 | `reference/optional-contributions.md` 与独立提案链接 | 主题/片段/装饰/自定义编辑器/Services/依赖/远程/AI/Agent 侧贡献/WASM；未实现项标为提案，不能混入稳定 API 表 | API-27/28/32/34–36/44，后续 |
| DOC-14 | 各 `sdk/*/README.md`、类型/API 文档、`guides/plugin-development-and-debugging.md` | 脚手架、打包校验、development 安装、日志/断点、错误定位、锁版本与 SHA-256、签名/上架、迁移/弃用 | 每个可交付切片 |
| DOC-15 | `examples/` 或现有各 SDK examples 目录 | 选区转换、文件树、HTML 预览三例；从干净目录仅靠已发布 SDK/文档即可构建，不能偷偷依赖主仓库源码 | M2–M3 |
| DOC-16 | `reference/environment-and-localization.md` | 必要环境信息、能力发现与插件语言资源、回退/切语言事件；禁止导出完整环境变量 | API-37，随对应阶段 |
| DOC-17 | `reference/network-and-authentication.md` | 受管联网/下载与原生进程边界，账号/权限 scope、用户同意、撤销、密钥不继承 | API-38/39，后续 |
| DOC-18 | `reference/workspace-authority-and-remote.md` | 工作区 authority 模型；远程占位根不是本机路径；未实现 authority 的拒绝错误；`backend:1` 与网页 bridge 的本机限定；已适配与未适配的远程范围 | API-35/40，M0 |
| DOC-19 | `reference/source-control-state.md` | 插件 VCS Provider 与内置 Git 只读快照的区别；字段、分页、事件合并；写操作不在范围 | API-31/42，M3–M4 |

每个正式 API 页统一包含：稳定 ID/方法签名，调用方向，参数/结果/示例，最低宿主能力与 SDK 发布版本，权限与授权方式，窗口/工作区/插件作用域，dirty/路径/编码/位置语义，取消与截止时间，事件/释放，限制/分页，稳定错误，安全注意事项，以及成功、拒绝、旧版本和失效结果的测试链接。没有实现与发布证据的候选名不得出现在“可用 API”导航中。

### 5.3 两仓库交付顺序

1. 主仓库同一实现 PR 修改 Core、`shared/contracts/plugins/v1/`、Mac adapter、fixtures 和真实能力表。API 计划文档不代替 schema/契约，也不先放开未实现字段。
2. 涉及后端协议变更，合并前在 lithe-plugin-docs 运行 `node scripts/sdk-e2e.mjs --source <本仓库路径> --ref <实现分支>`；覆盖 Node/Java 既有示例，修改 Rust SDK 时也覆盖 Rust 后端场景。
3. 主仓库合并后，在 lithe-plugin-docs 运行 `node scripts/contract.mjs sync --revision <合并后的 preview commit>`，提交逐字节副本与 lock；不手改 `contract/v1/`。
4. SDK、指南、示例和兼容性矩阵在文档仓库配套提交，锁定实际已支持宿主；正式 release 与哈希校验成功后再把该能力标成“已发布”。不能把正在开发的 main 当稳定 SDK 下载入口。
5. 主仓库不重新保存 SDK、不让 CI 隐式依赖文档仓库浮动 main。本次纯计划未改契约/协议，因此不触发契约副本同步或 SDK 发版。

## 6. 分阶段 PR 与交付门槛

阶段不是一个大 PR。每个切片都带契约/实现/测试/文档配套；M0 的最低可用协商先落地，不把所有未来能力塞进“基础设施”阻塞第一条工作流。

| 阶段 | 建议切片 | 最小交付与退出条件 |
| --- | --- | --- |
| M0 | 作用域/授权威胁模型、工作区 authority；无网页激活、激活事件和能力协商 | API-01/05/20/40/41 的必要部分；旧 backend/UI/Provider fixture 不变，新增调用方向和身份隔离有正反用例；未实现 authority（远程占位根、`backend:1`、bridge）对新 API 明确拒绝而非本机执行；已决定是否引入工作区信任；DOC-01–04/18 有可评审草稿 |
| M1 | 独立命令（含命令激活事件）；只读文档与选区；最小事件/通知/进度 | 一个不声明假窗口、假语言、假构建系统的插件能通过命令入口读取当前未保存选区并显示结果；换窗口/关闭工作区/撤权后旧上下文无效；Node SDK 有类型和示例 |
| M2 | 安全单文档编辑；预览与一次撤销 | 选区转换例完成“读取版本 → 计算 → 校验版本 → 编辑 → Undo”；用户同时输入时拒绝旧结果。无权限/只读/IME/多选区/Unicode 场景通过；不包含通用多文件事务 |
| M3a | 目录/搜索/watch；通用原生 Tree 数据源 | 分页文件浏览器不借 BuildProvider 启动；展开按需加载，刷新可取消，关闭/重开有明确状态规则；巨型树和符号链接边界有预算测试 |
| M3b | 打开/HTML 预览/系统浏览器；网页与对话框边界 | 三种打开行为按目标与 dirty 状态可预测，工程 HTML 无法调用插件桥；原有包内页面功能不回归 |
| M3c | 设置/状态/独立输出；菜单/表单/事件完善；内置 Git 只读快照、保存前事件 | 真实配置 Apply/冲突/重读可验收；订阅与页面反复启停无泄漏；公共 UI 保持 Mac 原生控件及可访问性；保存前事件超时不阻塞保存，Git 快照不泄漏凭据且不暴露内部类型（API-42/43 依赖 M2 的编辑与 M1 的事件） |
| M4 | 在 #1517 已合并的协议上，逐个完成 Build/Run/Test/Debug/VCS/语言/生成器文档与缺口 | 不重写已合并的 Provider 协议；真实项目完成 save → 同步模型 → build → run/test/debug → cancel/cleanup；远程工作区只承诺 #1515 已适配范围，其余按 API-40 明确拒绝 |
| 后续 | 主题/自定义编辑器/Services/终端/跨插件/远程剩余适配/AI/Agent 侧贡献/WASM、完整语言包/网络/账号各自立项 | 有实际插件需求、资源预算、许可/分发与风险证据后再进入实施；不是 M1–M3 发布门槛 |

#1517、#1515 已合并，M1–M3 与领域扩展可独立推进；若修改同一协议/入口，以 preview 当前代码为准协调，不能复制一份 Provider manager，也不能绕开 `RemoteWorkspaceRegistry` 的路由。领域迁移另由[Maven/Java 迁移提案](../../.agents/notes/proposed/architecture/2026-10-26-maven-java-domain-plugin-migration.md)跟踪，其特定版本匹配策略不能不加区分地变成整个公共 API 的兼容政策。

## 7. Mac 验收样例与发布检查

### 三个必须跑通的真实插件

1. **选区转换器**：只声明独立命令和所需权限；读取 dirty 文档与选区，异步处理后按版本应用；用户一次 Undo 恢复。没有假窗口/语言/构建系统，无权限时不读数据也不改文档。
2. **分页文件浏览器**：用目录/搜索 API 和原生 Tree 展示工程；展开加载子节点、取消搜索、刷新并定位编辑器。多窗口两个工程不会串数据，停用后 watcher/订阅/后端均按所有权清理。
3. **HTML 预览启动器**：从文件上下文命令分别在文本编辑器、内嵌预览、系统浏览器打开；未保存内容差异明确。恶意 HTML、外部导航、关闭后迟到消息均不能获得插件 host 权限。

### 每个切片的共用检查

- 契约与 Core：清单/协商/授权成功与拒绝、旧版本、未知字段、预算、取消/超时、重复/迟到消息、崩溃和重入；fixture 与实际调用结果一致。
- Mac 产品：多窗口/工程切换、无工程、dirty/只读/外部改盘、版本冲突、emoji/组合字符/CRLF/IME、深浅色与键盘/无障碍；组件测试不能代替实际安装插件的工作流。
- 安全和清理：路径穿越、符号链接切换竞态、越权跨插件/页面/窗口、消息洪泛、撤权/禁用/更新/卸载；有界等待，记录并清理本轮启动的进程及临时资源，不杀用户独立进程。
- 发布：app bundle 与已安装插件的文件清单/哈希在典型工作流前后不变；平台可写存储范围可核对，签名和 Sparkle 增量更新基线不受影响。
- SDK/文档：使用锁定发布物重建三个样例；记录 Mac、Core、契约 lock 和 SDK 版本。Node/Java/Rust 分别注明实际覆盖面，未测不填“通过”。

后续实现变更必须更新真实的平台功能矩阵并跑相应 change gate；本计划不改状态，不把 Mac 功能实施强行扩大成 Windows 任务。矩阵按仓库规则准确记录未实现/未验收状态即可。

本次计划 PR 的验证范围只有文档链接、Agent Notes、共享契约静态校验、i18n、bundle 只读静态检查和矩阵文档门禁；没有构建/启动应用，也不把以上未来验收记成已经通过。

## 8. 源码与决策索引

这些入口供后续认领任务时定位 owner，不表示可直接导出内部 Swift 类型。外部比较来源见 2.2；SDK 源码均以第 1 节锁定 commit 为准。

| 索引 | 所有者与证据 |
| --- | --- |
| S1 | [插件契约](../../shared/contracts/plugins/v1/README.md)、[Core 能力](../../rust/lithe-core/src/plugins/capabilities.rs)、[清单校验与激活事件](../../rust/lithe-core/src/plugins/declarative.rs)、[清单 schema](../../shared/contracts/plugins/v1/plugin-manifest.schema.json)、[Mac 能力表](../../macos/Sources/LitheModuleAPI/Plugins/PluginTypes.swift) |
| S2 | [backend 1](../../rust/lithe-core/src/plugins/backend.rs)、[函数协议](../../rust/lithe-core/src/lsp/interface/plugin_function.rs)、[Mac 后端会话](../../macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginBackendSessions.swift)、[宿主凭据服务](../../macos/Sources/Lithe/Application/Features/PluginHostServices.swift) |
| S3 | [原生 UI 功能](../../macos/Sources/Lithe/Application/Features/PluginNativeUIFeature.swift)、[Core UI 校验](../../rust/lithe-core/src/plugins/native_ui.rs)、[已实现原生 UI Note](../../.agents/notes/implemented/feature/2026-10-21-declarative-native-plugin-ui.md) |
| S4 | [Web bridge](../../macos/Sources/Lithe/Application/Features/PluginWebBridge.swift)、[包内内容](../../macos/Sources/Lithe/Platform/MacOS/Plugins/Web/MacPluginWebContent.swift)、[页面生命周期](../../macos/Sources/Lithe/Application/Features/PluginWebPageLifecycle.swift)、[状态存储](../../macos/Sources/Lithe/Platform/MacOS/Plugins/Web/MacPluginWebStateStore.swift) |
| S5 | [文档功能](../../macos/Sources/Lithe/Application/Features/DocumentFeatureModel.swift)、[LSP 编辑入口](../../macos/Sources/Lithe/Application/Features/LanguageWorkspaceEditService.swift)、[Monaco model](../../frontend/editor/src/model-source.ts)、[diff review](../../frontend/editor/src/diff-review.ts) |
| S6 | [文件端口](../../macos/Sources/LitheCoreContracts/Workspace/WorkspaceFileOperations.swift)、[Mac 文件适配](../../macos/Sources/Lithe/Platform/MacOS/FileSystem/MacWorkspaceFileOperations.swift)、[目录变更](../../macos/Sources/Lithe/Core/Ports/DirectoryChangeSource.swift)、[工程功能](../../macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift) |
| S7 | [搜索端口](../../macos/Sources/LitheSearchModule/Ports/SearchOperations.swift)、[搜索功能](../../macos/Sources/LitheSearchModule/Application/SearchFeatureModel.swift) |
| S8 | [命令目录](../../macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift)、[快捷键功能](../../macos/Sources/Lithe/Application/Features/KeyboardShortcutFeatureModel.swift) |
| S9 | [HTML 浏览器](../../macos/Sources/Lithe/Platform/MacOS/HTMLPreviewBrowser.swift)、[HTML 视图](../../macos/Sources/Lithe/Views/Editor/HTMLPreviewView.swift)、[平台 UI](../../macos/Sources/Lithe/Core/Ports/PlatformUI.swift)、[Mac UI adapter](../../macos/Sources/Lithe/Platform/MacOS/UI/MacPlatformUI.swift) |
| S10 | [插件设置注册](../../macos/Sources/Lithe/Application/Features/PluginSettingsRegistry.swift)、[源配置决策](../../.agents/notes/implemented/architecture/2026-10-25-settings-native-configuration-editing.md) |
| S11 | [Build 服务](../../macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift)、[Mac Provider 会话](../../macos/Sources/Lithe/Platform/MacOS/Build/MacBuildProviderSessions.swift)、[Run 服务](../../macos/Sources/LitheExecutionModule/Services/RunService.swift) |
| S12 | [终端端口](../../macos/Sources/LitheTerminalModule/Ports/TerminalTransport.swift)、[终端功能](../../macos/Sources/LitheTerminalModule/Application/TerminalFeatureModel.swift) |
| S13 | [语言 Provider 目录](../../macos/Sources/Lithe/Core/Language/PluginLanguageProviderCatalogSource.swift)、[LSP 资源归属](../../.agents/notes/implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md)、[诊断功能](../../macos/Sources/Lithe/Application/Features/DiagnosticsFeatureModel.swift) |
| S14 | [Debug 会话](../../macos/Sources/LitheDebugModule/Runtime/DebugAdapterSessionManager.swift)、[VCS 功能](../../macos/Sources/Lithe/Application/Features/VcsProvidersFeatureModel.swift)、[项目生成服务](../../macos/Sources/Lithe/Services/ProjectGeneration/ProjectGenerationService.swift) |
| S15 | [独立 IDE API](../../shared/contracts/ide-api/v1.md)、[原生模块接口](../../macos/Sources/LitheModuleAPI/Plugins/IDECapabilities.swift)、[授权功能](../../macos/Sources/Lithe/Application/Features/IdeCapabilitiesFeatureModel.swift)、[工具目录](../../rust/lithe-ide-host/src/catalog.rs) |
| S16 | [Mac 主题](../../macos/Sources/Lithe/Theme/LitheTheme.swift)、[图标入口](../../macos/Sources/Lithe/Theme/LitheIcons.swift) |
| S17 | [Services/公共扩展提案](../../.agents/notes/proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)、[数据库后端](../../.agents/notes/implemented/architecture/2026-10-24-database-provider-plugin.md)、[依赖与导出提案](../../.agents/notes/proposed/architecture/2026-10-25-plugin-dependencies-and-exports.md) |
| S18 | [有限热激活范围](../../.agents/notes/implemented/architecture/2026-10-26-plugin-live-activation.md)、[既有函数调用方向](../../.agents/notes/implemented/architecture/2026-10-20-plugin-function-contract.md) |
| S19 | [应用语言](../../macos/Sources/LitheModuleAPI/Localization/InterfaceLanguage.swift)、[GitHub HTTP adapter](../../macos/Sources/Lithe/Platform/MacOS/GitHub/MacGitHubHTTPTransport.swift)、[GitHub 服务](../../macos/Sources/Lithe/Services/GitHub/GitHubService.swift)、[Agent 登录端口](../../macos/Sources/Lithe/Core/Ports/AgentAccountSignIn.swift) |
| S20 | [远程工作区路由 Note](../../.agents/notes/implemented/architecture/2026-10-24-remote-workspace-routing.md)、[占位根](../../macos/Sources/Lithe/Platform/MacOS/Remote/MacRemoteWorkspaceRoots.swift)、[绑定与路由](../../macos/Sources/Lithe/Services/Remote/RemoteWorkspaceRouting.swift)、[远程插件启动](../../macos/Sources/Lithe/Platform/MacOS/Remote/MacRemotePluginLaunchPreparer.swift)、[远程主机提案](../../.agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md)、[SSH 调试提案](../../.agents/notes/proposed/architecture/2026-10-27-remote-debug-adapter-over-ssh.md) |
| S21 | [Git 功能](../../macos/Sources/LitheGitModule/Application/GitFeatureModel.swift)、[Git 服务端口](../../macos/Sources/LitheGitModule/Services/GitService.swift)、[统一 VCS 提案](../../.agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md) |
| S22 | [Skills](../../macos/Sources/Lithe/Application/Features/AgentSkillsFeatureModel.swift)、[Hooks](../../macos/Sources/Lithe/Application/Features/AgentHooksFeatureModel.swift)、[MCP 注册](../../macos/Sources/Lithe/Application/Features/McpRegistryFeatureModel.swift)、[MCP 服务器库](../../macos/Sources/Lithe/Application/Features/McpServerLibraryFeatureModel.swift)、[Skill 管理 Note](../../.agents/notes/implemented/feature/2026-10-20-agent-skill-management.md)、[Hooks Note](../../.agents/notes/implemented/feature/2026-10-24-agent-hooks.md)、[MCP 服务器库 Note](../../.agents/notes/implemented/feature/2026-10-17-mcp-server-library.md) |
