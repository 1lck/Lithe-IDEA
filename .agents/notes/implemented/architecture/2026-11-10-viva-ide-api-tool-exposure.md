# Agent 笔记：Viva 客户端的 IDE API 工具发布与 Build 分发

状态：已实现

## 先说结论

Viva 客户端的 IDE 连接在 `ideHost.control open` 时就声明它真正实现的工具列表（`toolExposure`），helper 的目录和 Core 的校验都只看到这份列表；没有实现的工具不发布，也不会假装成功。当前发布 7 个工具：`lithe_project_inspect`、`lithe_build_inspect`、`lithe_build_reload`、`lithe_build_execute`、`lithe_operations_list`、`lithe_operation_output`、`lithe_operation_stop`。Build 执行复用 Build 工具窗口的 `runBuildTask`，执行输出按行序列从同一个有界控制台读取。

## 问题

Core 的 `lithe-ide-host` 目录定义 16 个工具（环境、Maven、Build、Run、操作），但 Viva 客户端还没有运行配置面板、Maven 专属入口和构建选项编辑页。如果按默认方式 `open`（不传 `toolExposure`），Core 会发布完整目录，MCP 客户端就会看到并调用没有接线的工具；之前的实现用一个“NOT_AVAILABLE”兜底返回，但这仍然把不存在的能力宣传成工具，调用方无法在目录阶段判断。

另一个问题是线程归属：broker 的 poll/claim/dispatch 在后台 goroutine 上运行，而 Build 的实例、选择、输出和有界缓冲是 Viva 页面状态，只能在窗口线程读写。如果直接在 broker goroutine 上读这些字段，会与窗口绘制和用户操作并发。

## 决策

### 用 `toolExposure` 表达真实能力

- `ideAPIServedTools` 是唯一的发布列表，`ideAPIToolExposure()` 把它转成 Core 的 `toolExposure`；`open` 和每次 `validate` 用同一份列表，目录、参数校验和权限边界保持一致。
- 新增工具时先实现、测试，再加进 `ideAPIServedTools`；不要为了“看起来完整”先发布再返回错误。
- 工具结果里的失败使用共享形状 `{"error":{"code","message"}}`，code 稳定（`INVALID_ARGUMENTS`、`OPERATION_BUSY`、`BUILD_MODEL_NOT_LOADED`、`OPERATION_NOT_RUNNING`、`NO_PROJECT`、`CANCELLED`）。这些是协议数据，不走界面 i18n。

### 工具调用经窗口线程执行

- `ideAPIOnProject` 把工作投递到窗口线程并在调用上下文内等待结果；连接所属项目已关闭或换成另一个根目录时返回 `NO_PROJECT`，绝不操作“当前碰巧打开的项目”。
- `lithe_build_inspect` 只读：返回插件实例、声明的任务、已解码模型的项目/目标/任务和当前选择；模型未加载或加载失败时如实报告，不触发工具链。
- `lithe_build_reload` 清掉已解码模型后调用现有的 `loadBuildModel`，让插件重新产出模型。
- `lithe_build_execute` 先检查实例、任务和模型加载状态，再调用 `selectBuildInstance` 和 Build 窗口共用的 `runBuildTask`；`userArguments` 传给 Core 的 `BuildPlanRequest`，声明任务在提供参数后才允许运行。
- 操作的 ID、状态和起始输出序列记在项目状态里；Build 终止事件（成功、失败、取消）通过 `settleIDEOperations` 写回状态与退出码。`lithe_operation_output` 用行序列做 cursor，控制台裁剪时返回 `reset: true`，不会把别的执行当成同一个。

## 考虑过的备选方案

- **发布完整目录、在 dispatch 里逐个返回 NOT_AVAILABLE**：实现成本低，但违反工具目录的语义；MCP 客户端会把工具展示给用户，参数校验也按完整目录进行，调用方无法区分“没实现”和“暂时失败”。
- **在 broker goroutine 直接读 Build 状态**：会绕过 Viva 的窗口线程模型，产生数据竞争；加锁覆盖整个 Build 状态又会把绘制路径卷进锁竞争。
- **为 IDE API 复制一份 Build 执行器**：会与 Build 窗口在两个地方解释任务身份、参数和工具链解析，行为必然漂移；现有 `runBuildTask` 已经承担这些规则，只需把选择显式传入。
- **为每次执行单独保留一份输出缓冲**：更精确，但会复制 Build 控制台的裁剪、上限和行语义；当前用一个行序列在有界缓冲上定位，足以满足增量读取和 reset 检测。

## 后果

- 客户端只对外发布 7 个工具；环境、Maven 专属、Run 配置和 build_configure 在补齐对应 UI/写入路径前不可用。这是有意的能力缺口，由功能矩阵记录。
- `lithe_build_execute` 的模型任务要求模型已加载；客户端需先 `lithe_build_reload` 并轮询 `lithe_build_inspect` 的 `modelLoaded`。这样不会让工具调用隐式等待一个可能几分钟的模型构建。
- 操作记录保留到项目关闭；操作 ID 只在连接内唯一（`ide-build-N`），跨连接不保证一致。
- 输出是项目级 Build 控制台的一段序列；如果用户在 IDE 操作的同一时间从界面另起一次构建，`OPERATION_BUSY` 会阻止，两个执行不会共用同一段输出。

## 验证

- `cd desktop && ../scripts/desktop/desktop-go.sh test -race ./internal/workbench/ -run 'TestIDEAPI|TestIDEBuild|TestIDEOperation'` 覆盖工具发布列表、Build inspect 身份、未知实例/忙碌拒绝、输出 cursor/reset 和状态结算。
- `TestIDEAPIEnableAndDisable` 用真实 Core 打开连接，证明 `toolExposure` 的工具名能通过 Core 目录校验。
- 全量 `go test ./... -p 4`。
- 真机验收仍需在开启了 IDE 连接的客户端上，用 MCP 客户端完成一次 inspect → reload → wait loaded → execute → output → stop 流程。

## 适用范围

`desktop/internal/workbench/ide_api.go`、`ide_api_dispatch.go`、`build.go` 与 `shared/platform-feature-matrix/features/ide-api-*.json`。helper 本身的协议在 Lithe-core-rust 的 `lithe-ide-host`，不在本仓库修改；新增工具时两边一起验证。
