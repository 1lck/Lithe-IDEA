# Agent 笔记：macOS Cargo 基础构建插件

状态：已实现

## 先说结论

Cargo 基础能力在 [独立社区仓库](https://github.com/Lithe-IDEA/lithe-plugin-cargo) 维护并发布，使用现有原生构建窗口，不给 Swift 宿主新增 Cargo 专用分支。
工程成员、自动目标和 Features 都询问 Cargo 自己；插件只把答案转换为 Lithe 构建模型。
主仓库只保留固定来源的清单与模型夹具用于 Core 回归，不构建、下载或发布 Cargo 插件。

## 问题

已有 Cargo fixture 是验证契约的静态示例，只读取单个清单，不能作为正式的多包 workspace 支持。
直接扩展自写 TOML 扫描器会重复 Cargo 的成员、继承和自动目标语义；把插件留在宿主仓库，又会让它的发布和 SDK 引用依赖主仓库布局。

## 决策

- 项目模型由 Cargo 的 metadata 命令提供。Provider（按宿主请求回答工程信息的独立进程）使用 Node SDK，优先使用宿主提供的 Cargo 路径。
- 模型只接受构建根以内的成员和源码，实际路径经过符号链接解析；打开子包而真实 workspace 根在上层时明确报错。Features 使用 package/feature，同名 binary/example 通过目标标签区分。
- Build、Check 和 Test 在 workspace 或所选 package 运行；binary 和 example 通过目标任务执行。Clean 不接收 Features 等不兼容参数。基础测试体验保留 Cargo 输出与退出码，不声称已有逐用例图形报告。
- 插件仓库包含自己的清单、后端、构建脚本、单元/真实 Cargo 集成测试和 CI。Node SDK 与测试辅助代码按上游 Git 提交及逐文件 SHA-256 固定在该仓库的锁文件中，打包前必须校验；无需相邻主仓库或运行时下载。
- 安装包放插件仓库的 GitHub Releases，插件市场索引放 Lithe Store。0.1.0 以预发布形式分发，原生界面验收状态保持 pending，不自动作为稳定版本推广。
- 主仓库的 Cargo compatibility snapshot（兼容性快照）和 Maven、Gradle 一样放在 community_build_plugins 夹具目录。快照记录独立仓库提交；更新时清单与真实 metadata 金样必须来自同一已审查版本。

正确做法：独立插件提供 Cargo 的工程事实，Core 用固定清单和模型验证生成的 binary/example 参数。
不要这样做：在主仓库测试里直接引用隔壁插件 checkout，或在 BuildSystemService 中按 cargo 名称拼命令。

### 文件生命周期与只读边界

插件仓库自己持有 dist 安装包、临时打包 staging 和测试报告，不作为主仓库的可复用下载缓存。
SDK 复制只发生在打包阶段，staging 在成功或失败后清理；发布 ZIP 和校验文件按版本保持不可变。
运行时后端不保存额外缓存，不写插件安装目录或 app bundle。Cargo 自己的用户缓存、Cargo.lock 和 target 仍放在用户配置或工作区指定的位置。
这不会改变应用代码签名和 Sparkle 增量更新基线；独立插件集成测试对执行前后插件完整文件清单与哈希作比较。

## 考虑过的备选方案

- 直接把静态 fixture 改名发行：依赖少，但不能正确描述常见 workspace 和自动目标，未采用。
- 把插件留在主仓库并引用主仓库 SDK、测试工具：初期验证方便，但独立 clone 无法构建和测试，发布仍依赖宿主源码，未采用。
- 在共享 Core 增加专用 Cargo 模型解析器：让插件工具知识重新进入宿主，重复上游事实，未采用。
- 附带 Rust 编译的 Provider：无需额外 Node，但需维护两种 macOS 架构产物、签名和构建链；基础版复用现成零依赖 Node SDK。

## 后果

插件可以独立测试、打包和发布，主仓库 CI 无需下载插件或编译其真实 Cargo fixture。
代价是加载模型需要 Node 20.3+ 和 Cargo 1.70+；宿主与插件快照需要在明确版本上同步。
当前 outermost 识别不会单独列出外层 Cargo 根下的独立嵌套 workspace；基础范围没有依赖树、调试器和逐用例图形报告，Windows 尚未接入构建插件宿主。

## 验证

- 独立插件 CI：SDK 哈希与未登记文件检查、Node 单元和包校验、真实 Cargo 双包 workspace、后端协议启动/退出及包文件字节不变。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib cargo_plugin`：固定清单与 Core 识别、计划、模型解码、安装审查。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib community_build_plugins`：与 Maven、Gradle 兼容性夹具一同回归。
- `./scripts/verify-runtime-bundle-immutability.sh`、`./scripts/verify-platform-feature-matrix.sh`、`./scripts/verify-agent-notes.sh`。
- 原生磁盘安装、窗口交互与进程关闭的验收状态由 cargo-build-plugin 功能记录单独维护。

## 适用范围

- `rust/lithe-core/src/tests/fixtures/community_build_plugins/cargo/`
- `rust/lithe-core/src/tests/community_build_plugins.rs`
- `Plugins/mac/README.md`
- `docs/ci-builds.md`
- `shared/platform-feature-matrix/features/cargo-build-plugin.json`
