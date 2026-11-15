# Agent 笔记：Cargo 基础构建插件

状态：已实现

## 先说结论

Cargo 支持在独立的社区插件仓库 [Lithe-IDEA/lithe-plugin-cargo](https://github.com/Lithe-IDEA/lithe-plugin-cargo) 中维护和发布，使用宿主已有的构建插件接口。宿主不为 Cargo 增加专用分支；工程成员、自动目标和 Features 都由 Cargo 自己回答，插件只把答案转换为 Lithe 的构建模型。主仓库只保留通用的插件契约回归，不构建、下载或发布 Cargo 插件。

## 问题

直接扩展一个手写的 TOML 扫描器会重复 Cargo 的成员、继承和自动目标规则。把插件留在宿主仓库，又会让它的发布和 SDK 依赖主仓库布局，独立 clone 无法构建和测试。

## 决策

- **项目模型由 `cargo metadata` 提供。** 插件的 Provider（按宿主请求回答工程信息的独立进程）使用 Node SDK，优先使用宿主提供的 Cargo 路径。
- **只接受构建根以内的成员与源码。** 实际路径经过符号链接解析。打开子包而真实的 workspace 根在上层时明确报错。同名的 binary 与 example 通过目标标签区分。
- **Clean 不接收与 Build 不兼容的参数。** Build、Check 与 Test 在 workspace 或所选 package 上运行。
- **插件仓库持有自己的清单、后端、构建脚本、测试与 CI。** SDK 与测试辅助代码按上游提交和逐文件 SHA-256 固定在锁文件中，打包前必须校验。
- **插件 CI 使用固定的宿主修订。** 通过宿主公开的 JSON 命令接口执行清单、安装审查、能力拒绝、模型解码、任务与测试计划的验证；桥接程序只转发公开接口，不复制宿主实现。
- **Cargo 专属断言留在插件仓库。** 主仓库不保存社区 Cargo 快照，也不引用隔壁插件的 checkout。
- **0.1.0 以预发布形式分发。** 安装包放在插件仓库的 GitHub Release，插件索引放在 Lithe Store；原生界面验收仍为待验证状态。

## 考虑过的备选方案

- **直接把静态 fixture 当作正式支持。** 未采用。它只读取单个清单，不能正确描述常见的 workspace 与自动目标。
- **在宿主 Core 中增加专用 Cargo 模型解析器。** 未采用。会让插件工具知识重新进入宿主，并重复上游的事实。
- **在主仓库中保存社区 Cargo 快照并做兼容性测试。** 未采用。会让独立插件的维护同时修改宿主仓库。
- **附带 Rust 编译的 Provider。** 未采用。需要维护两种 macOS 架构的产物、签名和构建链；基础版复用零依赖的 Node SDK。

## 后果

- 插件可以独立测试、打包和发布，主仓库 CI 不需要下载插件或编译其真实 Cargo 工程。
- 加载模型需要 Node 20.3+ 与 Cargo 1.70+；插件 CI 需要编译宿主，首次验证要下载源码与依赖。
- 固定宿主修订使结果可复验，但不会自动发现未来 main 的回归，升级支持基线时必须更新锁文件并运行完整插件 CI。
- 当前不单独列出外层 Cargo 根下的独立嵌套 workspace；Windows 尚未接入构建插件宿主。

## 验证

- 主仓库：`scripts/desktop/desktop-go.sh test ./internal/core -count=1` 运行宿主侧的通用插件测试，不依赖社区 Cargo 清单。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`、`scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 与 `scripts/agent-notes/verify-agent-notes.sh`。
- 插件仓库的 CI 负责真实 Cargo 集成测试，验证内容见插件仓库的 README。

## 适用范围

- `docs/ci-builds.md`
- 插件实现与测试：[Lithe-IDEA/lithe-plugin-cargo](https://github.com/Lithe-IDEA/lithe-plugin-cargo)
