# Agent 笔记：Build Provider 原生任务执行

状态：已实现

## 先说结论

构建插件现在可以在自己的工作区 Provider（提供构建能力的后端进程）里执行任务，而不是把每个任务都展开为宿主命令。原生 Build 窗口复用现有工作区会话、通用输出与诊断、取消和进程清理，不要求插件增加网页，也不调用插件的私有函数。这是 [#1495](https://github.com/1lck/Lithe-IDEA/issues/1495) 阶段 C 的第一项执行能力；Maven/Java 业务迁移、运行准备、测试与公共调试注册接入仍须另行完成。

## 问题

现有 `buildProviders: 1` 只承载模型和依赖。普通任务由 Core 展开参数、宿主启动 CLI（命令行工具），因此后端即使拥有工程快照，也不能从原生入口掌握构建执行。直接调用插件私有函数会让宿主猜测参数、结果和错误码；另建一种工作区后端则重复 Provider 已有的进程、权限、取消和生命周期。

## 决策

### 类型化执行进入现有 Provider

`buildProviders: 2` 增加任务的 `source: "provider"`，`litheBuild` 在进程初始化时协商版本 2。两者分别负责安装准入与进程实际协议，不可互相替代。只协商版本 1 的后端明确拒绝执行，不退回 CLI 或私有函数。

Core 继续校验工程/目标/模型任务选择、路径与生效选项，返回 Provider 计划。后端收到任务声明 ID、选择、选项、参数与可选工具路径后，自行解释并执行领域业务。显式无效的工具或运行时选择沿用现有解析器的终止失败，不许可后端换一套自动发现。普通声明式命令任务继续走原来的公共命令能力，这不是 Maven/Java 旧业务 fallback。

本次只支持有界任务；`application/service` 与测试发现不借执行 RPC（请求/回复调用）伪装接入。正式形状、限制和共享用例在 `shared/contracts/plugins/v1/`，不在本笔记重复字段全集。

### 每个操作只有一个持有方

原生入口 → `BuildSystemService` → `MacBuildProviderSessions` → `LanguageServerRuntimeSession` → Core `lsp.buildRequest` → 同一 Provider 进程。模型、依赖、执行及插件自己的函数可复用这个进程，但领域调用和私有函数继续有各自契约。

Core 用 JSON-RPC 请求 ID 作为后端看到的 `operationID`，进度按仍在等待的同一执行请求转换成宿主操作 ID。取消、超时、退出或回复后删除等待项；晚到回复与进度不能复活操作，宿主 ID 复用也不串用旧消息。超时最长一小时，取消走原来的 `$/cancelRequest`，卡住的写入继续使用既有逃生与后代进程清理路径。

结果区分工具的非零退出码、无效协议结果和后端拒绝。最终输出用于现有诊断解码；已流式显示的输出不重复追加。进度和结果都有限制，不能把无限后台服务放进单次任务。

### 工作区与配置失效

每个进程继续按插件、清单/包、构建系统及工作区隔离。`BuildSystemService` 在任务上绑定运行 ID、工作区代次、生效选项指纹、启动设置及被监听构建文件的配置代次。停用/移除插件、工作区关闭/替换、取消，以及同一构建系统选项或被监听配置文件变化，都停止或使对应操作失效；后端迟到输出不能进入替换运行或新工作区。

同一路径重开仍是新的服务代次。插件更新先停止旧 Provider 再替换包；配置变化后的下一次调用按现有规则重新建立会话。Windows 当前尚未接入 Build Provider 宿主，继续不声明此能力，不以 Core 支持版本 2 代替 Windows 实机实现。

### 资源与数据边界

本次没有新增下载入口、生成目录、缓存路径或用户数据迁移。执行复用既有 `workspaceStateDir` 和进程生命周期；插件包与发行目录只读，运行状态、日志、锁和输出仍由现有平台存储 adapter 提供位置。可变工作区状态不跨工作树共享，不影响代码签名或 Sparkle 增量更新的基线。

契约/协议变更合并前，用 `lithe-plugin-docs` 的 SDK 端到端工具验证当前源码；合并后按[契约发布规则](2026-10-23-plugin-contract-publishing.md)同步副本。已有 SDK 模型/依赖示例须继续协商版本 1 并正常工作；SDK 的新执行处理器与 Maven 插件接入属于后续独立交付，本次不宣称它们已迁移。

### 正确做法与反例

正确做法：插件将构建任务声明为 Provider 来源，用户在原生窗口点击任务，宿主发送类型化执行请求；取消后，由同一个会话停止请求，旧输出不能写回新运行。

不要这样做：宿主通过 `functions.invoke("maven.build")` 猜测 Maven 私有函数；Provider 超时后再启动旧 `MavenService`；为获取工作区进程而创建空网页。它们分别绕过领域契约、保留旧业务回退和错误绑定页面生命周期。

## 考虑过的备选方案

- **扩展独立页面 backend。** 它是全应用范围的私有服务；改为工作区服务需要重复已有 Provider 的作用域和清理。执行首先复用现有工作区机制。
- **只加入任意方法调用。** 代码较少，但 Core 无法判断允许的方法、结果及进度归属，容易成为通用 JSON-RPC 隧道；仅开放明确的构建执行方法。
- **继续要求所有任务返回 argv。** 对简单工具仍然合适，但拥有工程状态的后端不能控制执行与结果；作为并列来源保留，后端任务没有失败回退。
- **一次补齐全部 Run/Test/Debug。** 各领域有不同目标和状态要求；先交付可独立验证的执行路径，后续基于真实需求补类型化能力，复用 #1210 的调试契约。

## 后果

收益是无页面的原生入口可以调用工作区后端执行，复用现有进程和 UI，并通过同一套协议证明进度、失败和取消。代价是多一个明确的能力/协议版本；后端作者需要实现执行处理器，宿主不能自行把未知任务变成命令。Maven/Java 仍有旧生产调用，只有对应纵向迁移完成并删除旧实现，#1495 才能最终关闭。

## 验证

共享 fixture 覆盖声明准入、请求/结果与无效输入。Core 回归验证版本 1 拒绝、版本 2 执行、进度映射、取消与迟到结果隔离，以及注入时间的超时。macOS 回归覆盖真实 Core 计划解码、原生服务不启动命令、非零退出码、配置/停用/工作区失效、同工作区会话复用及不同工作区隔离，读取与执行前后包资源字节不变。脚本化运行时验证不等于真实安装包或 Maven/Java 工程验收。

```bash
./scripts/verify-agent-notes.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-runtime-bundle-immutability.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-windows-boundaries.sh
./scripts/verify-rust-core-comments.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'BuildSystemServiceTests|MacBuildProviderSessionsTests|RustBuildSystemOperationsTests|BuildToolProviderResolutionTests|PluginWebBridgeTests'
```

2026-10-26 本地验证：macOS 116 项与相关 Core/LSP/插件/构建 190 项通过，单项计时分别在 `macos-swift.json`、`core-provider-focused.json`；新增测试最长 74 毫秒。官方 SDK 工具对当前 Core 临时 Git 快照的 Node/Java/Rust 示例共 4 项端到端检查通过；这验证现有 SDK 的协议兼容，不代表 SDK 已有新执行处理器。i18n 35 项、共享契约、Rust 注释、Windows 边界、包只读静态检查和功能矩阵门禁均通过。

`verify-service-boundaries.sh` 仍报告本次未修改、基线已存在的 `macos/Sources/Lithe/Services/Java/RunLaunchEnvironment.swift:50` 硬编码系统路径，未放宽规则。真实发行包工作流与 Windows 实机验收未执行，矩阵继续保持 `pending`。契约副本合并后同步；新执行 SDK 与 Maven/Java 消费者继续单独迁移。

## 适用范围

- `rust/lithe-core/src/build/`、`rust/lithe-core/src/lsp/interface/`、`rust/lithe-core/src/plugins/`
- `macos/Sources/LitheCoreContracts/Execution/BuildSystemContracts.swift`
- `macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Runtime/LanguageServerSession.swift`
- `macos/Sources/Lithe/Platform/MacOS/Build/MacBuildProviderSessions.swift`
- `macos/Sources/Lithe/Core/Rust/RustBuildSystemOperations.swift`
- `shared/contracts/plugins/v1/`
- `shared/platform-feature-matrix/features/build-system-plugins.json`
