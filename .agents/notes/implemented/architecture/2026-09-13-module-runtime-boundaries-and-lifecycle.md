# Agent 笔记：模块运行时边界与生命周期

状态：已实现

## 先说结论

模块的启动、停止、资源持有和故障恢复由统一运行时负责，模块本身只使用被授予的能力。禁用模块不能偷偷启动进程或 watcher；模块启动失败后，运行时必须能记录状态并支持后续恢复。

## 问题

功能模块不仅是隐藏的 UI 或源码目录，还必须决定什么时候构造、由谁持有
长生命周期资源、如何和其他模块通信，以及发生启动故障后如何恢复。如果
这些职责散落在 `AppModel`、服务字段和平台组合代码中，禁用模块仍可能
启动任务或进程，休眠也可能留下 watcher、连接、PTY 或子进程。

原生插件还需要在不加载模块代码的情况下完成版本、所有权和恢复判断。否则
一次未完成的激活或 Bundle 加载失败，会让下一次启动再次触发同一个故障。

## 决策

Lithe 使用 `LitheModuleAPI` 加 `LitheApplicationKernel` 作为统一的模块运行时
边界。模块生命周期、依赖、能力、资源和恢复状态由运行时持有，功能模块只
通过 `ModuleContext` 获得声明过的能力和资源接口。

```text
MacServiceContainer
    -> ModuleRegistry
        -> ModuleRuntime
            -> ModuleFactory
                -> LitheModule
```

### API 与运行时分层

- `LitheModuleAPI` 只定义平台无关的 `ModuleID`、manifest、依赖、能力、
  生命周期、事件、资源、lease、贡献和插件宿主协议。它不得依赖 UI、
  AppKit、具体平台适配器、Rust bridge 或功能实现。
- `LitheApplicationKernel` 中的 `ModuleRuntime` 负责注册、依赖图校验、
  能力提供者解析、按需构造、状态转换、资源回收、能力发布和关闭。
- `ModuleRegistry` 是组合根的声明式注册面：每个功能模块提供一个
  `ModuleFactory`，注册结果必须和已校验的静态插件 manifest 及贡献目录
  一致。
- macOS 的 `MacServiceContainer` 负责创建平台能力、读取模块配置和恢复
  元数据、注册内置模块与已加载插件。它不把全部功能实例提前构造到
  `AppServices`。

模块实现 target 只依赖 `LitheModuleAPI`、`LitheCoreContracts` 和自身需要
的工作流库；模块不能反向依赖 `Lithe` 可执行 target。应用侧通过能力、
事件和贡献目录使用模块，不通过另一个模块的具体 service 类型。

### 必须保持的生命周期不变量

1. 禁用、隔离或 Safe Mode 抑制的可选模块不会调用 factory，也不会启动
   task、timer、session、watcher、连接或子进程。
2. `onDemand` 模块只有在声明的能力被请求或被显式激活时才构造。依赖
   先于被依赖模块激活，依赖图必须无环，能力提供者不能发生静默覆盖。
3. 每个长期资源只能登记到一个模块的 `ModuleResourceScope`。注销活动
   资源会被拒绝，停止资源后才能释放登记。
4. `ModuleLease` 表示不可中断工作。存在活动 lease 时，休眠失败并发布
   可观察的阻塞原因；运行、测试、调试、终端、导入导出和事务等工作必须
   使用这个机制阻止后台回收。
5. 休眠依次准备模块、停止模块服务、停止登记资源、确认没有活动资源、
   移除能力和贡献，并释放实例。唤醒时重新构造实例，先激活依赖，再恢复
   能力。
6. 可选模块在调用 factory 前写入 pending activation 标记。启动时如果
   标记未清除，恢复存储会先把模块隔离，应用可以在不构造模块的情况下
   启动并允许用户重新启用它。
7. 原生插件 Bundle 加载使用独立的进程级恢复标记。插件 manifest、宿主
   版本、模块所有权、语言支持和入口信息在加载 Bundle 前校验；Safe Mode、
   禁用和隔离状态在触碰 Bundle 前过滤。
8. 模块仍然运行在应用进程内。上述标记、隔离和 Safe Mode 是下一次启动
   的恢复机制，不等同于进程隔离，也不能宣称第三方模块崩溃不会终止应用。
9. 静态贡献目录可以被工作台读取而不构造模块；模块实例激活后才发布
   实际贡献，休眠、禁用或失败回滚时移除这些贡献。

### 插件宿主边界

插件只能通过 `PluginHostContext` 按稳定 ID 获取宿主提供的窄协议，不得
导入应用 executable target，也不得自行构造 macOS adapter。插件的
manifest 负责声明模块、依赖、能力、语言支持和入口；运行时负责生命周期，
平台层负责进程、文件、PTY、密钥链和原生 UI 等具体能力。

语言服务器、语言包和 Rust LSP runtime 的具体归属遵循
[`语言工具分层与 LSP Runtime 归属`](2026-09-13-language-tooling-and-lsp-runtime-ownership.md)；
本 Note 只约束它们作为模块接入运行时的边界。

## 考虑过的备选方案

### 在 `AppModel` 或 `AppServices` 中直接持有全部功能实例

这样调用路径较短，但禁用和按需激活无法从构造阶段保证，功能资源也会
逃离统一的停止和休眠流程。模块运行时改为持有 factory、实例和资源 scope，
应用侧只持有组合入口和能力协调器。

### 应用启动时 eager 构造所有模块

实现最直接，但会启动用户未使用的后台资源，无法满足禁用模块零资源、
按需激活和故障隔离要求，因此只有 manifest 明确声明 `eager` 的必要模块
才在启动阶段激活。

### 每个模块都做成独立进程

可以隔离崩溃，但会引入跨进程协议、启动成本和状态同步复杂度，当前模块
API 也没有以此为前提。Lithe 先采用同进程模块边界和可恢复启动标记；只有
安全或稳定性要求明确达到进程隔离级别时，才重新评估此方向。

### 让模块直接导入其他模块的实现

局部接入更快，但会形成隐式依赖和能力提供者竞争，导致模块无法独立禁用、
休眠或替换。跨模块交互统一经过能力、不可变事件和声明式贡献。

## 后果

- 模块是否被构造、是否拥有资源、是否可以休眠和是否能恢复，都有单一的
  运行时归属，测试可以直接验证 factory、lease、resource 和 state。
- 工作台可以显示模块快照和静态贡献，而不必为了展示入口提前启动模块。
- 原生插件的 manifest 校验和恢复判断可以在加载代码前完成，插件故障不会
  阻止必要的应用壳启动。
- 代价是 `ModuleRuntime`、`ModuleRegistry` 和各模块的 manifest 必须保持
  一致，模块不能通过快捷的具体 service 引用绕过这层边界。
- 这套设计只提供同进程恢复，不提供第三方代码的运行时崩溃隔离；如果未来
  引入真正的跨进程插件，必须重新定义 `ModuleContext` 和能力传输协议。

## 验证

- `./scripts/verify-agent-notes.sh`
- `./scripts/verify-module-boundaries.sh`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/test-macos.sh`
- `macos/Tests/LitheApplicationKernelTests/ModuleRuntimeTests.swift`

这些检查覆盖禁用模块不调用 factory、依赖顺序、能力冲突、lease 阻塞
休眠、资源回收、唤醒重建、关闭清理、贡献目录、Safe Mode、隔离恢复和
内置 manifest 漂移。

## 适用范围

- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheApplicationKernel/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/LitheApplicationKernel/Registry/ModuleRegistry.swift`
- `macos/Sources/Lithe/`
- `macos/Sources/Lithe*Module/`
- `Plugins/mac/Official/`
- `macos/Tests/LitheApplicationKernelTests/`
- `scripts/verify-module-boundaries.sh`
