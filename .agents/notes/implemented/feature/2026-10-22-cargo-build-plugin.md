# Agent 笔记：macOS Cargo 基础构建插件

状态：已实现

## 先说结论

Cargo 基础能力在 [独立社区仓库](https://github.com/Lithe-IDEA/lithe-plugin-cargo) 维护并发布，使用现有原生构建窗口，不给 Swift 宿主新增 Cargo 专用分支。
工程成员、自动目标和 Features 都询问 Cargo 自己；插件只把答案转换为 Lithe 构建模型。
Cargo 专属测试、清单与模型金样全部由插件仓库维护；其 CI（自动检查流程）调用固定版本 Core 的公开 JSON 接口验证兼容性。
主仓库保留通用插件契约回归，不构建、下载或发布 Cargo 插件。

## 问题

已有 Cargo fixture 是验证契约的静态示例，只读取单个清单，不能作为正式的多包 workspace 支持。
直接扩展自写 TOML 扫描器会重复 Cargo 的成员、继承和自动目标语义；把插件留在宿主仓库，又会让它的发布和 SDK 引用依赖主仓库布局。

## 决策

- 项目模型由 Cargo 的 metadata 命令提供。Provider（按宿主请求回答工程信息的独立进程）使用 Node SDK，优先使用宿主提供的 Cargo 路径。
- 模型只接受构建根以内的成员和源码，实际路径经过符号链接解析；打开子包而真实 workspace 根在上层时明确报错。Features 使用 package/feature，同名 binary/example 通过目标标签区分。
- Build、Check 和 Test 在 workspace 或所选 package 运行；binary 和 example 通过目标任务执行。Clean 不接收 Features 等不兼容参数。基础测试体验保留 Cargo 输出与退出码，不声称已有逐用例图形报告。
- 插件仓库包含自己的清单、后端、构建脚本、单元/真实 Cargo 集成测试和 CI。Node SDK 与测试辅助代码按上游 Git 提交及逐文件 SHA-256 固定在该仓库的锁文件中，打包前必须校验；无需相邻主仓库或运行时下载。
- 安装包放插件仓库的 GitHub Releases，插件市场索引放 Lithe Store。0.1.0 以预发布形式分发，原生界面验收状态保持 pending，不自动作为稳定版本推广。
- 插件 CI 按 `sdk.lock.json` 的同一宿主提交检出独立 Core 源码，通过 `execute_json`（宿主公开的 JSON 命令接口）执行清单、安装审查、能力拒绝、识别、模型解码、任务和测试计划验证。桥接程序只转发公开接口，不复制 Core 实现或重新实现模板展开。
- Cargo 专属断言、发布清单和真实 metadata 金样留在插件仓库。集成测试把真实 Provider 回复交给 Core 解码，再执行 Core 根据实际清单生成的命令，并验证编译错误的诊断解码；主仓库不保留另一份社区 Cargo 快照。

正确做法：插件 CI 用已固定的真实 Core 和当前插件清单生成 binary/example 参数，再在临时 Cargo workspace 执行。
不要这样做：在主仓库测试里直接引用隔壁插件 checkout，或在插件测试里手写一套命令代替宿主计划。

### 文件生命周期与只读边界

插件仓库自己持有 dist 安装包、临时打包 staging 和测试报告，不作为主仓库的可复用下载缓存。
兼容性验证的宿主源码在插件 checkout 的 `.artifacts/lithe-core`，可变编译结果在 `.artifacts/core-target`；首次构建按宿主 Cargo.lock 下载依赖，测试工程本身离线执行。
准备脚本拒绝来源、提交或已跟踪文件被改写的 checkout，用 `--locked` 构建，并记录桥接源码和二进制哈希；这些目录不跨工作树共享、不进入插件 ZIP。
SDK 复制只发生在打包阶段，staging 在成功或失败后清理；发布 ZIP 和校验文件按版本保持不可变。
运行时后端不保存额外缓存，不写插件安装目录或 app bundle。Cargo 自己的用户缓存、Cargo.lock 和 target 仍放在用户配置或工作区指定的位置。
这不会改变应用代码签名和 Sparkle 增量更新基线；独立插件集成测试对执行前后插件完整文件清单与哈希作比较。

## 考虑过的备选方案

- 直接把静态 fixture 改名发行：依赖少，但不能正确描述常见 workspace 和自动目标，未采用。
- 把插件留在主仓库并引用主仓库 SDK、测试工具：初期验证方便，但独立 clone 无法构建和测试，发布仍依赖宿主源码，未采用。
- 在共享 Core 增加专用 Cargo 模型解析器：让插件工具知识重新进入宿主，重复上游事实，未采用。
- 在主仓库保存社区 Cargo 快照和专用兼容性测试：能随 Core 修改及时发现回归，但会让独立插件维护同时修改宿主仓库；本次改为插件 CI 主动调用固定 Core，主仓库继续持有通用插件契约测试。
- 只删主仓库测试并依赖现有手写 Cargo 命令：不能验证清单经宿主展开后的参数是否有效，会丢失覆盖，未采用。
- 附带 Rust 编译的 Provider：无需额外 Node，但需维护两种 macOS 架构产物、签名和构建链；基础版复用现成零依赖 Node SDK。

## 后果

插件可以独立测试、打包和发布，主仓库 CI 无需下载插件或编译其真实 Cargo fixture。
代价是加载模型需要 Node 20.3+ 和 Cargo 1.70+；插件 CI 还要编译 Core，首次验证需要下载源码和 Rust 依赖。
固定宿主提交让结果可复验，但不会自动发现未来 preview 的回归；升级支持基线时必须主动更新锁文件并运行完整插件 CI。
当前 outermost 识别不会单独列出外层 Cargo 根下的独立嵌套 workspace；基础范围没有依赖树、调试器和逐用例图形报告，Windows 尚未接入构建插件宿主。

## 验证

- 独立插件 CI：`node scripts/prepare-core.mjs` 构建固定宿主公开接口桥接；`LITHE_CARGO_INTEGRATION=1 node scripts/test.mjs` 执行 SDK 哈希、Node 单元、包校验、3 项 Core 兼容性回归及真实 Cargo 双包 workspace。
- 集成验证覆盖真实模型解码、Core 生成的 Build/Check/Test/Clean 与 binary/example 运行、选项与精确用例选择、失败诊断、后端退出及包文件字节不变；插件仓库上传逐测试 HTML、JUnit 与日志。
- 主仓库现有 `build_systems` 和 `community_build_plugins` 回归继续验证通用宿主行为，不依赖社区 Cargo 发布清单或外部 checkout。
- `./scripts/verify-runtime-bundle-immutability.sh`、`./scripts/verify-platform-feature-matrix.sh`、`./scripts/verify-agent-notes.sh`。
- 原生磁盘安装、窗口交互与进程关闭的验收状态由 cargo-build-plugin 功能记录单独维护。

## 适用范围

- [Cargo 插件仓库](https://github.com/Lithe-IDEA/lithe-plugin-cargo) 的 `test/`、`scripts/`、`sdk.lock.json` 与 `.github/workflows/`
- `Plugins/mac/README.md`
- `docs/ci-builds.md`
- `shared/platform-feature-matrix/features/cargo-build-plugin.json`
