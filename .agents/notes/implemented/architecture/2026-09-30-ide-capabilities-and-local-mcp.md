# Agent 笔记：项目环境和执行能力的统一 API 与本地 MCP

状态：已实现

## 先说结论

Lithe 对外开放项目环境、Maven、运行配置和执行输出，复用界面已经使用的操作。
模型上下文协议（MCP，用于 AI 客户端发现并调用工具）和插件使用同一能力清单、
参数校验和项目授权；文件编辑不属于本次开放范围。开发者新增能力时，应先补共享
契约，再接两端现有工作流，不能在 MCP 辅助程序里重建项目模型或拼另一套启动命令。

## 问题

外部 Agent 能改文件，但不知道当前 IDE 真正采用的工具链、Maven Profile、
项目准备状态和运行会话。仅公开 Rust Core 命令会绕开应用持有的状态；仅复制
按钮行为则会让两个平台、插件和 MCP 各自维护不同的执行链。

## 决策

- `lithe-ide-host` 是本机通信适配器，统一工具清单、验证、授权检查、连接文件、
  请求队列和输出游标。它不负责 Java/Maven 的语义、项目事实或进程启动。
- `lithe-mcp` 使用官方 Rust SDK `rmcp`，复用协议协商、标准输入输出传输和
  工具结果格式。它只转发到用户明确授权的本地 IDE 项目。
- 应用能力接口分别连接 macOS 的执行功能模型和 Windows 的工作区 store。
  运行前的准备、保存、语言服务同步以及原生进程生命周期仍由原有功能负责。
  macOS 的功能模型通过动作协议依赖应用，由 Composition 连接应用聚合模型。
- 插件复用公开能力而不是访问整个应用对象。macOS 使用宿主服务注册表的
  `.ideCapabilities`，Windows Integration Worker 通过 `permissions.ide` 声明和
  `api.ide` 调用绑定已有授权连接的应用接口。声明不能扩大项目授权，也不改变
  PHP 等本地语言包只贡献运行计划的限制。
- 用户从设置侧栏独立的“MCP 配置”入口开启连接，避免将 Agent 接入隐藏在
  JDK/Maven 环境设置内；未打开项目时显示提示，不创建授权。读取、配置和执行权限按项目处理。配置与执行
  默认关闭。项目关闭、窗口销毁和应用退出都关闭连接。禁用 MCP 后，已接受的
  执行仍归 IDE 管理，不能因为一个客户端断线误杀用户正在看的服务。
  Windows 从打开连接前就登记授权代际；撤销后迟到的原生连接必须关闭，旧轮询
  只能清理自身连接。项目关闭会等待正在打开的连接完成清理，不能只遍历已显示的配置。
  Windows 原生层为 `open` 注入当前窗口的 `ownerId`，覆盖调用方提供的所有者；
  该请求由严格 camelCase 结构解码。`closeOwner` 沿用独立的 `ownerID` 字段，
  不可对所有动作全局替换字段名，否则窗口销毁时无法撤销访问。
- 输出 ID 标识一次执行。旧 ID 不能停止占用同一输出槽的新进程。输出游标在
  Rust 中按 UTF-8 字节分页，前缀发生变化时显式返回 reset，避免截断后漏读。
  普通应用的主输出面板与服务标签均持有执行 ID；Windows 取消 Java 启动确认时
  同步清除准备中状态，关闭项目时先撤销 API，再清理已有运行资源。

macOS 的 Agent 构建已改为公共 Build 入口：先查询插件检测的实例、声明和模型 ID，
再用 `lithe_build_execute` 调用同一 `BuildSystemService` 与工作区 Provider。参数保留
独立数组，选择器从当前模型再次核对；模型过期时不能执行旧项目/目标/模型任务。
Maven 的目标语义、参数解释和执行由 Maven 插件负责，宿主不再保留该 Agent 路径的
`runCustomGoal`、命令拼接、专属进程和任务状态机。配置、项目加载、依赖与 Java
协作仍待阶段 D 的后续切片替换，本次删除不代表整个阶段完成。

Build 输出槽持有最近一次操作的快照，任务结束后仍保留 ID、状态、退出码和输出。
同控制台的模型/依赖日志不属于该任务，不进入 Agent 输出。新任务替换或同路径重开
会撤销旧 ID；停止只取消仍匹配的运行身份。快照只在内存里，不新增文件或镜像配置。
Windows 仍有旧 Maven 执行消费者，因此共享清单暂时保留其入口；Windows 对新的
Provider 入口明确返回不可用，不伪装已支持，也不因此让 macOS 回退旧执行路径。

正确示例：Agent 查询 `goal` 声明后把 `["clean", "verify"]` 作为参数数组交给 Maven
Provider，UI 与 Agent 使用同一份 Build 生效配置。不要在辅助程序里自行执行 `mvn`，
不要用旧操作 ID 停止一个已经替换的运行。

连接信息存入平台应用数据目录，锁文件按项目排他持有。目录由平台 adapter
决定，关闭连接时删除凭据文件，崩溃后的陈旧文件在重新授权时覆盖。辅助程序
随安装包发布且运行时只读，因此不会改变代码签名或 Sparkle 差分更新的源字节。
连接目录、锁、构建输出均不可跨 worktree 复制；共享清单明确排除 `ide-mcp`。

## 考虑过的备选方案

1. **只公开磁盘操作**：不能观察 IDE 实际生效的设置和运行会话，收益有限。
2. **辅助程序自己启动 Maven/Java**：会绕开已有工作流、模块资源和项目准备，
   两端出现两套项目状态，因此不采用。
3. **直接公开 Core dispatcher**：内部命令不是授权边界，还包含文件与凭据等
   不属于首期的能力。因此只允许共享能力清单里的命名操作。
4. **将 MCP 协议写两遍**：增加版本兼容和测试成本。使用官方 SDK 并保留平台
   应用动作接线，避免为了共享而迁移整个原生工作台。

## 后果

用户复制一次客户端配置后，可以通过 AI 使用 IDE 的环境、Maven 和运行操作。
插件获得同一套能力入口。代价是各平台仍须接入自己的应用状态；不能假设类型化
Rust 命令可以直接替代当前窗口或工作区的状态所有权。

连接只面向本机。内部 HTTP 桥不是公开的 MCP HTTP 服务。默认读取也可能包含
项目日志中的敏感信息，授权界面明确说明。原生进程内插件并没有因此获得新的
沙盒隔离能力。配置文件跨存储写入沿用现有部分失败语义，调用者应检查返回错误
并重新读取实际值；API 不承诺安装工具链或静默处理 Java 构建失败确认。

通用 `lithe_build_configure` 与原生 Build 的实例选项编辑共用 Core 校验和同一存储。
Agent 先 inspect 取得选项 ID、类型、当前值与候选，再提交一个值或 null 重置；非法值在
写入前拒绝，并读回确认。它不会编辑原生 XML，也不创建未声明的偏好。清空多选保留
已有实例清空标记和兄弟实例选择，配置变化撤销旧模型、语言导入与原生配置草稿。
Windows 尚未运行 Build Provider 时明确返回不可用；旧 Maven 专属配置入口的剩余
消费者继续列在阶段 D 待删清单，不能因新 API 可用而宣称整个迁移完成。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-ide-host` 验证授权、路径、
  模块参数、输出游标、连接互斥、请求路由和打包输入不变。
- `node --test scripts/test-ide-mcp.mjs` 在先构建辅助程序后验证真实 stdio
  握手、工具发现、结构化结果和可见工具错误。
- `./scripts/verify-shared-contracts.sh`、`./scripts/verify-windows-boundaries.sh`、
  `./scripts/verify-runtime-bundle-immutability.sh` 验证契约和平台边界。
- Windows 的 `ide-capabilities.test.ts` 验证旧执行 ID、撤销期间的设置写入、
  设置补丁和共享权限拒绝；macOS 的 `IdeCapabilitiesTests.swift` 验证授权与
  工作区代际、模块不被错误激活以及执行身份。
- `mcp-lifecycle.test.ts` 用可控原生响应和手动调度器验证打开期间关闭项目、
  全局退出和旧轮询失败不会恢复授权或撤销新连接；测试完成后必须清理所有计时器。
- Worker 宿主测试验证未声明权限时不能发现或调用项目、显式工作区不被当前焦点
  替换以及应用层拒绝原样返回。Maven 的 API 保存等待真实写入结果；失败进程的
  输出读取不能被 Windows Git 兼容层误判为 IPC 失败。
- 阶段 D 的 Agent 构建切片在 macOS 的固定 Swift 6.3.3 下通过 159 项/6 组回归；
  新增的 Provider/Agent 成功与失败两个参数用例合计 108 毫秒。显式开发包经真实
  Agent 调用、生产 macOS Provider 会话与 Maven 多模块工程完成模型加载和模块编译，
  完成后查询输出并关闭后端、核对插件包文件清单，耗时 4.787 秒。开发包来自 Maven
  插件 `a72ee3e8ee2d32412281c746ea7cc2d76a3cda6a` 与显式 SDK JAR，不冒充发行包。
  本地逐测试报告为 `.artifacts/test-stability/stage-d-agent.{json,html,junit.xml}`、
  `stage-d-agent-real-maven.{json,html,junit.xml}`；IDE broker 6 项和 Windows 前端逻辑
  在 macOS 上的 Bun 9 项计时通过。后者不是 Windows 实机证据。
- 双端原生打包运行的验证状态以功能矩阵为准。Linux 的协议与前端测试不能
  证明 macOS Swift 编译、Windows 安装与原生运行通过。

## 适用范围

- `rust/lithe-ide-host/`
- `shared/contracts/ide-api/v1.md`
- `macos/Sources/Lithe/Application/Features/IdeCapabilitiesFeatureModel.swift`
- `macos/Sources/LitheModuleAPI/Plugins/IDECapabilities.swift`
- `windows/tauri/src/features/host-api/`
- `scripts/worktree-resources.json`
