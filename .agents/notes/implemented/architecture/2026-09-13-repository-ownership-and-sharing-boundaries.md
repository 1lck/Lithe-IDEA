# Agent 笔记：仓库所有权与共享边界

状态：已实现

## 先说结论

macOS 和 Windows 是两套独立产品，共享的确定性行为放进 Rust Core，平台特有能力留在各自适配层。写代码时先按目录职责放置实现；如果一个行为会被两端共同使用，先确认共享契约和 Rust Core 是否应成为唯一实现。

## 问题

Lithe 包含两个彼此独立的平台产品，由少量共享契约连接起来。如果没有
明确的所有权边界，平台代码可能跨 macOS 和 Windows 泄漏，共享行为可能
被实现两次，界面层也可能绕过应用层和服务层直接调用底层能力。

仓库同时包含 Rust Core、Swift、TypeScript、原生适配器、插件、契约、
夹具和验证脚本。它们所在的目录不仅是组织方式，也是架构所有权信号。
变更必须保留这些信号，不得悄悄改变 JSON 命令名、Serde 字段名、错误码、
C 符号、模块 ID、能力 ID 或插件入口名称。

## 决策

macOS 是当前参考产品。Windows 是独立的 React/Tauri 实现，不得导入
Swift 源码，也不得依赖 macOS 类型。

仓库采用以下所有权边界：

| 路径 | 职责 |
| --- | --- |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit 表现层和视图内渲染 |
| `macos/Sources/Lithe/Models/` | 面向界面的模型和 `AppModel` 聚合模型 |
| `macos/Sources/Lithe/Application/` | 功能模型、状态转换和用户操作 |
| `macos/Sources/Lithe/Services/` | 按产品领域组织的工作流编排 |
| `macos/Sources/Lithe/Core/` | 平台无关端口和类型化 Rust 操作 |
| `macos/Sources/Lithe/Platform/MacOS/` | macOS 适配器和组合根 |
| `rust/lithe-core/` | 确定性的共享命令、模型、校验和 C ABI |
| `windows/` | React/Tauri Windows 产品和 Windows Rust 适配器 |
| `Plugins/mac/` | macOS 所有的插件包 |
| `Plugins/win/` | Windows 所有的插件包 |
| `shared/` | 跨平台契约和夹具，不放编译实现 |
| `infra/` | 仓库级开发和验证基础设施 |
| `third_party/` | 固定版本的上游清单和必要的局部源码补丁 |

应用层依赖方向如下：

```text
SwiftUI/AppKit → AppModel → Application 功能模型 → AppServices
                                      ├── Rust Core 操作
                                      └── macOS 端口和适配器
```

Windows 产品使用对应的 Web/native 分层：

```text
windows/tauri/src/           React 工作台、功能状态和表现层
windows/tauri/src/platform/  共享命令和原生命令的前端边界
windows/tauri/src-tauri/     Tauri 组合根和 Windows 专属 Rust 适配器
```

两个产品通过相同的 JSON 封装和命令名使用 `rust/lithe-core`。Windows
直接链接 Rust crate，macOS 使用 C ABI。共享行为必须放在
`shared/contracts/`，并且在第二个平台依赖它之前，先在
`shared/fixtures/` 中增加对应夹具。

Windows 产品是 `windows/tauri` 下的 React/Tauri 实现；此前的 Qt/C++
实现已经退役，Windows CI 和发布打包只构建 Tauri，不再安装或构建 Qt。
`core_execute`/`core_cancel` 对外暴露完整的共享 JSON 协议，
`windows/tauri/src/platform/tauri-core.ts` 是前端唯一的 invoke 边界。
仍在向共享契约对齐的 React 功能 API 可以暂时使用旧命令名，但旧名字
必须在 `windows/tauri/src-tauri/src/platform.rs` 这一个中央 dispatcher
里做翻译：翻译后的命令把 Core 成功的 `data` 值返回给前端，把 Core
错误信封转换成被拒绝的 invoke 调用；不得为每个共享 Core 操作单独新增
一个 Tauri command。没有共享实现的命令必须显式失败，不得在桌面构建
里塞入伪造的成功值。

macOS 可执行目标使用按所有权划分的目录：

```text
macos/Sources/Lithe/
├── Application/
│   ├── Composition/  # 应用服务图和模块资源所有者
│   ├── Features/     # 面向界面的状态转换和用户操作
│   └── Lifecycle/    # 应用级生命周期策略和错误
├── Core/
│   ├── Language/     # 语言提供者目录适配器
│   ├── Ports/        # 平台无关接口
│   └── Rust/         # 类型化 Rust JSON/C ABI 适配器
├── Models/
│   ├── AppModel/     # AppModel 聚合模型和专门扩展
│   ├── Bridges/      # 可执行目标的一致性桥接
│   └── <Domain>/     # 编辑器、Diff、Java、运行时、搜索和工作区模型
├── Services/<Domain>/ # 按产品领域组织的工作流
└── Views/<Feature>/   # 按用户功能组织的表现层
```

功能模块目标只使用自己需要的目录：

```text
macos/Sources/Lithe<Feature>Module/
├── Module/       # 模块入口和功能图
├── Application/  # 功能状态和面向界面的协调
├── Models/       # 领域模型和值类型
├── Ports/        # 功能所有的接口
├── Services/     # 工作流
├── Runtime/      # 进程、协议和会话实现
└── Providers/    # 提供者实现
```

官方语言支持插件另外使用 `Capabilities/`、`Plugin/` 和 `Support/`，
分别存放导出的语言能力、原生插件入口和共享标识符。新文件以主要类型
命名；`Type+Concern.swift` 只用于专门的扩展或可执行目标桥接。物理移动
源码时不得重命名模块 ID、能力 ID、JSON 字段、C 符号或插件入口名称。

插件包由平台分别负责。macOS 插件位于 `Plugins/mac/`，Windows 插件位于
`Plugins/win/`；任何平台都不得编译另一个平台插件目录中的源码。共享的
插件线协议和夹具继续放在 `shared/`。

Rust Core 按稳定的所有权边界组织：

```text
rust/lithe-core/src/
├── protocol/    # 命令名、线协议、响应、错误、事件和取消
├── runtime/     # JSON 分发器和 C ABI 导出
├── project/     # 文件/搜索、本地历史、Markdown、Maven 项目检查
├── execution/   # 运行配置、启动/工具链模型和项目探测器
├── languages/   # Java 等语言相关的源码检查
├── git/         # Git 校验、解析、状态和变更
├── lsp/         # 通用 LSP、轻量回退和提供者/Swift 适配器
└── tests/       # 按相同领域组织的命令级测试
```

Rust 的依赖方向是 `protocol <- domain packages <- runtime/FFI`。领域模块
可以使用协议契约，但不得依赖运行时分发器。`execution/types.rs` 是配置
和探测器共用的类型层。各包的 `mod.rs` 是兼容性门面；新的实现逻辑必须
放入明确归属的子模块。

共享 Rust Core 和平台适配器的职责如下：

| 共享 Rust Core | 平台所有的适配器 |
| --- | --- |
| 工作区遍历和搜索规则 | 根目录选择和目录监听 |
| UTF-8 文件命令校验和结果 | 原生文件 API、权限和持久化路径 |
| Git 模型、校验、解析和变更 | 可执行环境和凭据 |
| 历史元数据和快照规则 | 历史存储位置和文件移动 |
| 语言提供者目录、轻量能力、完整 LSP 运行时、Maven 和 Java 源码解析 | 语言服务器/JDK/Maven 探测，Maven/Debug 子进程 |
| 错误码、取消、截止时间和 JSON 封装 | PTY/ConPTY、信号、句柄和原生界面 |

界面只能依赖功能模型和共享模型，不得依赖具体适配器。Core 和 Services
必须保持不依赖 AppKit、SwiftUI、Tauri、WebView2、Win32、`Process` 以及
直接的平台文件 API。语言工具还遵循协议层与应用层分离的规则，具体说明
见[语言工具分层与 LSP Runtime 归属](2026-09-13-language-tooling-and-lsp-runtime-ownership.md)。

`rust/lithe-core/` 下的第一方生产模块必须以简短的英文 `//!` 模块边界
说明开头。这是 Rust 源码注释规范，不代表工程文档使用英文。导出的 API、
共享请求和响应类型、核心领域类型以及 C ABI 函数使用 `///`；不安全入口
必须记录指针所有权和 `# Safety` 要求。实现中的注释只解释兼容性、确定性、
排序、安全、性能或跨平台等不明显的约束。

不得提交 `.build/`、`.swiftpm/`、`dist/`、`DerivedData/`、夹具构建目录
和本地 IDE 配置等生成物。`third_party/` 不是通用的上游代码归档目录；
除非 Lithe 实际编译经过记录的局部补丁，否则应使用不可变清单、构建期校验
下载和产物级许可证说明。

## 考虑过的备选方案

### 两个平台共用一套实现

这样可以减少重复接线，也能形成一套统一的界面架构。但 macOS SwiftUI/
AppKit 与 Windows React/Tauri 具有不同的原生生命周期、进程、文件系统和
界面契约。强行共用实现会把平台细节泄漏到共享层，并增加原生行为的测试
难度，因此不采用。

### 在 Swift 和 TypeScript 中各自实现共享行为

这样可以让两个产品独立推进，并让实现靠近各自界面。但对于确定性命令、
解析、模型、校验、排序、取消和 JSON 行为，两份实现会逐渐产生差异。因此
这些行为统一放入 Rust Core，通过稳定边界供两个平台使用。

### 让界面直接调用适配器或 Rust ABI

这在局部实现上更直接，也能少经过应用模型和服务层。但它会让表现层绑定
平台初始化，使生命周期和错误处理不一致，也无法用一致的方式验证跨平台
工作流，因此不采用。

### 在 `docs/architecture/` 保留一份相同架构文档

这样便于人类查找，但会形成两个潜在事实来源。当前决策和理由统一保存在
本 Note 中；正式契约、源码、夹具和验证脚本分别作为各自表面的权威来源。
`docs/architecture/` 不再保留这篇架构决策的副本。

### 每个共享 Core 操作单独对应一个 Tauri command

这样前端调用点更直白，不需要一个中央 dispatcher 做名字翻译。但共享
Core 操作会随协议演进持续增加，逐个新增 Tauri command 会在
`src-tauri` 里重新长出一层与 `rust-core-api.md` 平行维护的命令清单，
且旧命令名和新契约名并存时容易遗漏某个入口的翻译。因此新旧命令名的
翻译统一收在 `platform.rs` 一个中央 dispatcher 里，不逐个新增。

## 后果

- 仓库对 macOS、Windows、Rust Core、共享契约、插件、脚本和基础设施建立
  了明确的所有权边界。
- Windows 命令面收敛在 `platform.rs` 一个 dispatcher 里做名字翻译，
  新增共享 Core 操作不需要在 `src-tauri` 里同步新增 command，但翻译
  遗漏会表现为"命令没有共享实现"的显式失败，而不是静默的假成功。
- 新增跨平台行为时，第二个平台依赖它之前必须先增加共享契约和夹具。
- 平台代码仍可独立测试，但跨越边界的变更需要同步检查 Rust Core、契约、
  适配器和消费者。
- Rust Core 承担确定性共享行为的中心职责，必须保持 JSON、C ABI、错误码
  和取消语义兼容。
- 目录布局成为架构的一部分。允许移动代码，但改变所有权或兼容性表面时
  必须形成明确的决策记录。
- 仅涉及当前事实的架构变化可以原地更新本 Note；如果决策本身被完全替代，
  必须创建新 Note 并归档本 Note。

## 验证

- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-rust-core-comments.sh`

仓库布局和所有权规则还需要通过受影响平台的构建和测试验证。契约变化
必须同时检查相关夹具和所有平台消费者。

## 适用范围

- `macos/Sources/Lithe/`
- `macos/Sources/Lithe*Module/`
- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheCoreContracts/`
- `macos/Sources/LitheRustCore/`
- `Plugins/mac/`
- `Plugins/win/`
- `rust/lithe-core/`
- `windows/`
- `shared/`
- `scripts/`
- `infra/`
- `third_party/`
