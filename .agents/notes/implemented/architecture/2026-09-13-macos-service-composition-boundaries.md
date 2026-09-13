# Agent 笔记：macOS 组合根、Coordinator 拆分与平台边界

状态：已实现

## 先说结论

macOS 界面只负责展示和收集用户操作，功能状态由应用层管理，服务层负责协调流程，平台适配器负责调用系统能力。这样新增功能时，应把代码放到它真正负责的层里，不要让 View 直接调用 Rust、文件系统或具体平台服务。

## 问题

macOS 应用需要在 SwiftUI/AppKit 呈现层、`AppModel`、功能状态、平台
适配器和 Rust Core 之间划出清晰边界，否则视图会直接依赖 Rust C ABI
或具体适配器，`AppModel` 也会因为承载全部功能状态和用户操作而变成
不可维护的单体聚合对象。此前已经出现过信号：部分 `AppModel` 扩展
文件涨到数百行才被拆分，部分视图曾经直接持有 `AppModel` 而不是精简
的 feature model。

这篇 Note 记录仓库顶层所有权之下、macOS 内部这一层的组合和边界决策，
补在 [`repository-ownership-and-sharing-boundaries.md`](2026-09-13-repository-ownership-and-sharing-boundaries.md)
之下。

## 决策

macOS 使用如下运行时依赖方向：

```text
SwiftUI / AppKit Views
          ↓
AppModel: UI 状态、导航、功能组合
          ↓
Application Feature Models
          ↓
AppServices + Swift Services
     ┌────┴───────────────┐
     ↓                    ↓
Rust operations       macOS ports/adapters
     ↓                    ↓
Rust Core + JSON C ABI  FileSystem / FSEvents / Process / PTY / UI
```

`MacServiceContainer` 是 macOS 组合根：创建 Rust Core 桥接、Rust 支持的
workspace/Git/history/Java 操作、Swift services 和 macOS 适配器，再注入
`AppServices`。未来的 Windows 组合根必须用 Windows 实现构造相同的
应用侧端口。

macOS 内部目录职责：

| 目录 | 职责 |
| --- | --- |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit 呈现、输入、导航目的地和视图内渲染 |
| `macos/Sources/Lithe/Models/` | 面向界面的模型和值类型；`AppModel` 是可观察聚合，不是平台组合根 |
| `macos/Sources/Lithe/Application/` | Workspace、Document、Git、Search、Java、Terminal、Project History 和 UI Feature Model，协调状态和用户操作 |
| `macos/Sources/Lithe/Services/` | 产品工作流编排；语言功能路由和 Maven/Run/Debug 生命周期仍是 Swift 工作流，LSP service 是 Rust runtime 之上的语义门面 |
| `macos/Sources/Lithe/Core/Ports/` | 进程、终端、存储、运行时发现、文件操作、watcher 和原生 UI 能力的平台无关接口 |
| `macos/Sources/Lithe/Core/Rust/` | 共享 Rust JSON 契约的类型化操作和模型转换 |
| `macos/Sources/Lithe/Platform/MacOS/` | FSEvents、文件操作、持久化、进程会话、PTY、运行时发现、原生 UI、快捷键和更新 |

### 组合根与 Coordinator 拆分

`AppCompositionBuilder` 构造功能图和 `AppModel` 外壳；`AppModelFeatureGraph`
持有单个项目会话的 eager 功能实例。新的状态转换要放进对应的 feature 或
coordinator，不要再加一个 `AppModel` 扩展。

| Owner | 职责 |
| --- | --- |
| `WorkbenchFeatureModel` | 侧边栏选择、设置展示、互斥的底部工具窗口 |
| `CommitDraftFeatureModel` | 提交文案、amend 选择、生成状态、生成消息替换确认 |
| `WorkspaceSessionCoordinator` | Workspace 与独立文件会话状态、最近项目、原生访问租约、关闭请求、workspace 重建任务归属、workspace 功能重置 |
| `EditorSessionCoordinator` | Document/媒体标签归属、编辑器选择协调、恢复已保存的文档顺序与选择、重置编辑器内容 |
| `ShortcutSessionCoordinator` | 原生快捷键监听、注册与录制订阅、活跃会话门控、最终关闭 |
| `DocumentLanguageCoordinator` | 文档触发的语言激活与清理，以及按文档的 hint 刷新任务合并与取消 |
| `DocumentFeatureComposition` | 把文档和语言功能端口接到 session、settings、通知和可选模块动作 |
| `WorkspaceProjectionComposition` | 把 workspace projection 回调接到 document、workbench、editor-session 等归属方 |
| `AppModelObservationBinder` | 给仍在观察聚合对象的调用方提供兼容性变更通知 |
| `ModuleCapabilityStore` | 缓存的可选模块能力及其观察清理 |
| `ModuleSessionCoordinator` | 模块事件订阅、release 驱动的绑定清理、database 侧边栏回退、合并后的 runtime 关闭 |
| `SearchSessionFeatureModel` | 临时搜索、everywhere-search 和项目替换的展示状态 |
| `SearchModuleCoordinator` | 搜索能力激活、观察、缓存、初始索引预热 |
| `SearchWorkflowCoordinator` | 项目和 everywhere 搜索执行、过期结果校验、搜索模块空闲策略 |
| `ProjectReplacementCoordinator` | 项目替换预览/应用与替换会话清理；document/history 工作是注入的 |
| `DatabaseModuleCoordinator` | Database 能力激活、观察、缓存、挂起 |
| `HistoryModuleCoordinator` | Local history 能力激活、workspace 配置、观察、缓存、功能重置 |
| `ExecutionModuleCoordinator` | Execution 能力激活、关闭顺序、缓存、功能观察、功能访问装配、Maven/Run/language-test 生命周期的停止/重置 |
| `RunWorkflowCoordinator` | Run 项目快照就绪性、过期打开检查、延迟运行动作（含恢复）的归属 |
| `JavaTestWorkflowState` | 可取消的 Java 测试发现/调试任务归属、操作身份校验、Java 测试结果服务器清理 |
| `JavaTestDebugWorkflowCoordinator` | Java 测试调试启动任务编排、过期操作清理、结果服务器交接、启动失败上报；不持有通用 Debug 会话 |
| `LanguageNavigationCoordinator` | 进行中导航请求状态、丢弃过期结果的操作身份校验、语言服务器位置到应用导航/编辑器位置的投影 |
| `LanguageEditingCoordinator` | 共享的语言编辑请求值归一化、确定性补全合并、语言服务器结果处理 |
| `LanguageWorkspaceEditService` | Workspace 编辑校验、应用与回滚；文档变更和 UI 通知是注入的 |
| `DebugLaunchPreparationCoordinator` | 通用 Debug 启动预检和启动配置解析；不持有 Debug 会话生命周期或 UI 展示 |
| `DebugSessionCleanupCoordinator` | Debug adapter 状态转换：工具窗口展示、暂停时的应用激活、每会话的 terminal 和 Java 结果服务器拆卸 |
| `DebugModuleCoordinator` | Debug 能力激活、关闭顺序、缓存、会话状态观察、功能访问装配、功能停止/重置 |
| `TerminalModuleCoordinator` | Terminal 能力激活、观察、会话重试、terminal 会话关闭 |
| `GitModuleCoordinator` | Git 能力激活、观察、回调组合、缓存、功能重置 |
| `LanguageIntelligenceModuleCoordinator` | 语言智能能力激活、缓存查找、绑定交接、语言服务器停止/诊断清理、workspace 状态重置 |

Coordinator 不依赖 `AppModel`。组合代码可以为尚未迁移到最终归属的
应用动作弱持有它；workspace composition 目前仍用这些兼容动作做模块
激活、导航和项目服务加载，还不是完全独立的应用图。

Coordinator 持有自己需要的依赖，而不是按调用接收闭包——插件目录、
模块运行时、通知通道这些在构造时就可用的值是构造参数。重新进入应用
入口要经过 `Application/Features/WorkflowActionPorts.swift` 里的协议，
聚合对象实现它，coordinator 通过 `connect(actions:)` 弱持有。这样
coordinator 可以用 spy 测试而不必依赖应用外壳，`verify-service-boundaries.sh`
会拒绝重新引入被移除的回调参数。

决定一个工作流的状态属于拥有该工作流的 coordinator，不属于聚合对象：
`RunWorkflowCoordinator` 拥有 `pendingRunAction`，`LanguageNavigationCoordinator`
拥有导航状态；聚合对象只为仍在观察它的视图暴露只读转发。

### AppModel 扩展范围

每个 `AppModel` 扩展只覆盖一个工具窗口或一个领域（`+RunConfiguration`、
`+Debugging`、`+LanguageTests`、`+CodeNavigation`、`+LanguageEditing`）。
文件超过约 600 行说明又在聚合不相关的功能，会被 `verify-service-boundaries.sh`
拒绝；应该新增一个领域文件，而不是继续扩展已有文件。

### 平台边界

Core 和 Application 代码不得 import SwiftUI、AppKit、CoreServices 或具体
`Mac*` 类型，不得直接构造 `Process`、`Pipe`、`FileManager`、`UserDefaults`
或 `FileHandle`。Service 必须通过端口接收这些能力；Service 可以持有工作流
状态机（例如语言 provider 路由或 Maven/Debug 生命周期），但不能决定操作
系统如何启动、监听、存储或终止底层资源——Rust LSP runtime 是其子进程、
stdio、JSON-RPC 状态、文档版本、请求 deadline、诊断和消息归一化的唯一
所有者。

View 只接收 `AppModel` 或专门的 UI Feature Model，不得接收具体的
workflow service、直接调用 Rust C ABI 或构造平台适配器。

Rust Core 拥有确定性的跨平台行为：workspace 快照、UTF-8 文件读写、搜索
和替换预览；Git status/Diff/History/Blame/Stash/分支操作/远程同步/Clone/
Commit/补丁应用；Local History 元数据和快照操作；Maven 描述符和诊断
解析；Java 源码结构、code vision、类名和运行配置解析；轻量语言功能和
完整 LSP runtime（进程、stdio/framing、生命周期、文档、deadline、能力、
诊断、provider 适配器、归一化的功能结果）；以及请求封装、取消、deadline、
错误码、校验和稳定的 JSON 排序。

macOS 拥有这些能力的平台侧：workspace 选择、FSEvents、原子/原生文件
操作、权限、持久化位置和 Finder 集成；语言服务器/JDK/Maven 发现和平台
环境解析；Java/Maven/Debug 进程传输、terminal PTY、shell、信号和原生
句柄（LSP 进程传输属于 Rust）；原生窗口、菜单、剪贴板、快捷键、安装器
和更新行为。

应用内更新通过 macOS 更新适配器使用 Sparkle，签名、差分包、旧客户端
兼容性和发布校验见 [`macos-updates.md`](../../../../docs/architecture/macos-updates.md)。
macOS Git 提交图投影和原生长边导航遵循
[`2026-09-13-macos-git-graph-intellij-layout.md`](../feature/2026-09-13-macos-git-graph-intellij-layout.md)
钉住的 IntelliJ 规则。语言工具分层见
[`2026-09-13-language-tooling-and-lsp-runtime-ownership.md`](2026-09-13-language-tooling-and-lsp-runtime-ownership.md)。

## 考虑过的备选方案

### 让 AppModel 直接承载全部功能状态

这样调用链最短，视图直接读一个对象就够了。但功能状态和用户操作全部
挤进同一个聚合对象后，扩展文件会无限增长（此前已出现数百行的扩展），
也难以脱离应用外壳单独测试某个工作流，因此拆成按领域归属的
coordinator，聚合对象只保留只读转发。

### 视图直接持有具体 Service 或调用 Rust C ABI

这样能减少一层间接，局部实现更直接。但会让呈现层绑定平台初始化和
生命周期细节，使错误处理不一致，也无法用一致方式对工作流做单元测试，
因此不采用；`verify-service-boundaries.sh` 会拒绝这种依赖。

### Coordinator 按调用接收闭包，而不是持有构造参数 + 协议 re-entry

闭包参数改起来更快，不需要新增协议类型。但会重新把应用入口的耦合
带回每个调用点，且难以用 spy 隔离测试，因此改为构造时注入依赖，
re-entry 统一走 `WorkflowActionPorts.swift` 协议。

## 后果

- Coordinator 拆分让每个工作流的状态和转换有唯一归属，`AppModel` 收窄
  为只读转发和尚未迁移完的兼容动作载体。
- 平台边界规则由 `verify-service-boundaries.sh` 机械校验（禁止的 import、
  具体适配器引用、View 的直接依赖、聚合对象的反向引用、超过约 600 行
  的 UI 聚合扩展）。
- 代价：workspace composition 仍然通过兼容动作弱持有 `AppModel` 做模块
  激活、导航和项目服务加载，还不是完全独立的应用图；这部分收窄需要
  单独的后续工作，不在本决策范围内。
- 需要重新评估的触发条件：以下工作流仍留在 Swift 平台层而非 Rust Core，
  如果决定把它们统一迁移进 Rust（沿用 Git/History 已经走过的路径），
  需要回来更新本 Note——Maven root/module 菜单的 lifecycle/Test/Package/
  自定义 goal 路由；Maven POM watcher 触发的 Reload 合并任务和 revision
  推进；Java import 的进度感知就绪 deadline 与安全上限；Debug 启动预检
  与原生 Java 目标解析、adapter、terminal 生命周期。当前边界可用且被
  强制执行，但不代表这些工作流已经全部搬进 Rust。

## 验证

- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-rust-core.sh`

`verify-service-boundaries.sh` 会拒绝 Core/Services 中的平台 import 和
具体适配器引用、View 对 workflow service 的直接依赖、`AppModel` 中的
平台组合、feature 实现代码和限定 Git 视图（log、comparison、commit
diff、working-tree diff、worktrees、branch switcher）对聚合对象的反向
引用，以及超尺寸的 UI 聚合扩展。

## 适用范围

- `macos/Sources/Lithe/Views/`
- `macos/Sources/Lithe/Models/`
- `macos/Sources/Lithe/Application/`
- `macos/Sources/Lithe/Services/`
- `macos/Sources/Lithe/Core/Ports/`
- `macos/Sources/Lithe/Core/Rust/`
- `macos/Sources/Lithe/Platform/MacOS/`
- `scripts/verify-service-boundaries.sh`
