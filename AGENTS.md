# Lithe Agent 入口

在仓库中开始任何工作前，先加载并遵循 `.agents/skills/develop-lithe/SKILL.md` 中的 `develop-lithe` Skill。它是 AI 编码和验证规则的唯一真源，也包含 Rust Core 必须遵守的注释规范。

如果任务会创建、迁移、更新、归档或审查 Agent 笔记，或者会把架构决策内容从 `docs/` 移出，开始前还要加载 `.agents/skills/agent-notes/SKILL.md`。Agent 笔记是架构决策和工程取舍的中文真源。

如果任务会创建、修改或审查测试代码、测试基础设施，开始前还要加载 `.agents/skills/write-stable-tests/SKILL.md`。该 Skill 规定 macOS 和 Windows 测试必须遵守的有界等待、确定性时间、资源清理和单测试计时规则。

如果任务会准备、验证或发布 Lithe 稳定版，修改发布说明、版本元数据、标签或发布工作流前，还要加载 `.agents/skills/release-lithe/SKILL.md`。

如果任务涉及通过 Parallels 虚拟机来构建、运行、诊断 Windows 产品，或向 Windows 产品传输文件，开始前还要加载 `.agents/skills/debug-windows-on-parallels/SKILL.md`。

## 工具链

Swift 6.3.3 / Xcode 26.6（见 `.swift-version`）、Rust stable、Bun 1.3.12、Node >= 22。
`Package.swift` 里的 `swift-tools-version: 6.2` 只是 manifest API 下限，不选择编译器版本。
macOS 应用目标刻意使用 Swift 5 语言模式，测试目标使用 Swift 6，不要顺手改。

## 常用命令

构建与运行：

| 目的 | 命令 |
| --- | --- |
| 开发运行（先构建并链接 Rust Core，再打包 `.app` 启动） | `./scripts/preview.sh` |
| 只校验 Swift 源码 | `swift run --disable-sandbox Lithe` |
| 构建 app bundle | `./scripts/package-app.sh` 然后 `open dist/Lithe.app` |
| 只构建 Rust Core 静态库 | `./scripts/build-rust-core.sh --debug --target aarch64-apple-darwin` |
| Windows Release 打包 | `./scripts/build-windows.ps1 -Configuration Release` |

测试：

| 目的 | 命令 |
| --- | --- |
| macOS 全量测试 | `./scripts/test-macos.sh` |
| 单个或一组 Swift 测试 | `./scripts/test-macos.sh --filter '<suite-or-test>'`（脚本把剩余参数透传给 `swift test`；`--filter` 接受正则，可用 `|` 组合多个） |
| 列出可用测试 | `swift test list` |
| 改动测试代码时的计时与稳定性 harness | `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter '<focused-test>'` |
| Rust Core 单测 | `cargo test --manifest-path rust/Cargo.toml -p lithe-core` |
| Windows 前端 | `cd windows/tauri && bun install --frozen-lockfile && bun run typecheck && bun run lint` |
| Windows Rust | `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml` |

格式与验证：Rust 用 `cargo fmt --manifest-path rust/Cargo.toml -p lithe-core`；前端用 `bun run format`。提交前按改动类型选择最小相关验证集合，矩阵见 `.agents/skills/develop-lithe/SKILL.md` 的 "Run validation that matches the change"；不要声称未执行的平台检查已通过。CI 的 macOS / Windows 工作流只是调用上述脚本，本地复现应使用同一批命令。

## 测试进程生命周期与清理

除非用户明确要求保留进程运行，否则本次构建、测试、调试、预览或验证启动的任何 Lithe 应用，都必须在任务或测试完成后关闭。清理所有子进程、辅助进程、临时应用实例和相关资源，然后确认没有 Lithe 进程残留，再把结果交还给用户。

重复检查时不要启动重复的 Lithe 实例，也不要让测试构建的应用留在用户的应用列表中。如果某个进程无法正常停止，必须明确报告，并在继续工作前进行有界的尽力清理。

## 特殊 UI 交互

处理可拖动分隔条、可调整面板、连续拖动、滚动或其他高频 UI 交互时，先阅读：

- `.agents/skills/develop-lithe/SKILL.md`
- `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md`

入口文件只保留这条提醒；具体决策原因、正确做法、反例和验证要求以 Agent Note 与 Skill 为准，避免三份规则长期漂移。

## 架构总览

Lithe 是面向 Java / Spring Boot 的低内存 IntelliJ IDEA 替代品。仓库里同时存在**两个独立产品**和**一份共享内核**。

### 两个产品，一份内核

macOS 是当前参考产品：Swift 6 / SwiftUI + AppKit 工作台，通过 **JSON C ABI**（`lithe_core_execute_json` 等导出符号）调用 Rust Core。Windows 是独立的 React 19 / Tauri 2 产品，通过**直接链接 Rust crate** 调用同一个 `rust/lithe-core`，并维护自己的 `platform.rs` 中央 dispatcher。两者不共享 UI 实现，只共享确定性行为。

确定性行为（命令名、JSON 字段、错误码、解析、排序、校验、取消语义、C ABI）**必须**放在 `rust/lithe-core/`；原生文件系统、进程、终端、凭据、持久化、WebView、更新安装留在各平台适配层。这是仓库最重要的一条边界：同一个行为不能在 Swift 和 TypeScript 里各写一遍。第二个平台依赖某个共享行为之前，先在 `shared/contracts/` 与 `shared/fixtures/` 落契约和夹具。

### macOS 的依赖方向

```text
SwiftUI/AppKit (Views) → AppModel (Models) → Application 功能模型 → AppServices
                                            ├── Rust Core 操作 (Core/Rust)
                                            └── 平台端口与适配器 (Platform/MacOS)
```

`macos/Sources/Lithe/` 是可执行目标，按所有权分目录：`Views/`、`Models/`（含 `AppModel/` 聚合）、`Application/`、`Services/`、`Core/`（平台无关端口 + 类型化 Rust 适配）、`Platform/MacOS/`。`MacServiceContainer` 是唯一的 macOS 组合根，平台能力只能出现在 `Platform/MacOS/`。

功能能力被拆成 `Lithe*Module` 库目标（Git、Search、Terminal、Database、Debug、Execution、AIAssistance、LanguageIntelligence、Workspace、LocalHistory、ModuleAPI、CoreContracts），每个模块只使用自己需要的 `Module/`、`Application/`、`Models/`、`Ports/`、`Services/`、`Runtime/`、`Providers/` 子目录。`LitheRustCore` 是 C ABI 的 Swift 侧薄封装。

### Windows 的依赖方向

```text
windows/tauri/src/          React 工作台、features 状态、ui 组件
        ↓
src/platform/tauri-core.ts  前端唯一的 invoke 边界
        ↓
src-tauri/  Tauri 组合根 + Windows 专属 Rust 适配器 + platform.rs 中央 dispatcher
```

前端**不得**直接 import `@tauri-apps/api/core`，一律走 `@/platform/tauri-core`。共享操作经 `core_execute`/`core_cancel` 走完整共享 JSON 协议；旧命令名只允许在 `platform.rs` 一个地方翻译，不能为每个共享 Core 操作新增 Tauri command。没有共享实现的命令必须显式失败，不能塞伪造的成功值。此前的 Qt/C++ 实现已退役，不要再引入。

### 共享编辑器与共享契约

`frontend/editor/`（`@lithe/editor`）是两端共用的 Monaco 表现层、分词和编辑器模型生命周期，不调用任何平台 API，由 macOS 的 WKWebView 适配器和 Windows 的 WebView2 适配器共同消费。文档持久化、关闭确认、外部文件冲突、语言进程仍归应用层与平台适配器。

`shared/` 只放契约、schema 和夹具，不放编译实现。当前行为契约见 `shared/contracts/application-boundary.md`，命令清单见 `shared/contracts/rust-core-api.md`，夹具在 `shared/fixtures/`。

### 其他所有权

`rust/lithe-git-host/` 只管 Git 子进程、管道、临时输入和有界清理，不决定 Git 参数策略；共享事件解码与凭据脱敏在 `rust/lithe-core/src/git/`。`rust/lithe-db-sidecar/`、`rust/lithe-db-mcp/` 是数据库辅助进程。`Plugins/mac/` 与 `Plugins/win/` 分属各自平台，任何平台都不得编译对方目录的源码。`third_party/` 是固定版本上游清单，不是通用归档目录——除非 Lithe 实际编译过经记录的局部补丁。

目录布局本身就是架构信号：移动代码可以，但改动所有权或兼容性表面（命令名、Serde 字段、错误码、C 符号、模块/能力 ID、插件入口）必须留下决策记录。

## 开发与协作
1. 每次进行功能开发或者 bug 修复都单独从最新的 preview 分支创建新分支，如果有对应的 issue 分支名最好与 issue 编号相关
2. 开发的时候如果涉及到 github 相关的操作麻烦使用 gh CLI 来进行操作而不是使用 Computer Use 的 Skill。由于沙盒影响可能导致需要反复的 gh 授权，每次需要授权的时候麻烦先申请更高的权限去主环境中查看对应是否有 gh 的Token，如果有就直接复用，这个时候找不到才要求登录 gh
3. 开发完成提交 PR 的时候需要说清楚对应改动的功能点，哪怕是一些细小的改动也是需要包含在内的，需要确保 code reviewer 马上就可以理解这个改动是什么
4. 如果让你修复有关 CI 的流程，记得使用 gh 或者 curl 之类的去查看(优先 gh)而不是使用 Computer Use
5. `CLAUDE.md` 只是 `@AGENTS.md` 的转发文件。改规则只改 `AGENTS.md`，不要在两处各写一份，否则会重新长出会漂移的第三份规则源。

## 工作树资源复用与文档维护

- Git worktree 之间不共享各自的 `.artifacts`。单独工作树进行本地编译时，优先
  通过 `scripts/reuse-worktree-resources.mjs --source <已有工作树>` 复用资源，不要
  手工搬运或直接共享整个 `.artifacts`。脚本必须保持源目录只读，通过目标临时
  目录完成校验，并在原子发布后再次校验。
- 新增或修改任何下载、解压、生成或缓存资源时，必须同步更新
  `scripts/worktree-resources.json`、`scripts/reuse-worktree-resources.mjs` 的校验路由、
  对应测试，以及 `docs/ci-builds.md` 的“独立工作树的本地编译”章节。更新内容
  至少包括资源路径、是否允许跨 worktree 复用、版本/平台/架构/工具链身份约束、
  校验来源、复制时机，以及不能共享时的隔离原因。
- PR 中如果增加新的资源目录、下载入口、缓存变量或校验逻辑，必须检查并更新
  资源复用清单和相关验证脚本；不能只把资源加入构建流程而遗漏 worktree 复用
  说明。生成资源没有可靠 identity stamp 时不得注册为可复用资源；可变构建状态
  和 LSP workspace 状态不得跨 worktree 共享。
