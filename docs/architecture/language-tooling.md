# 语言工具与 LSP 架构

本文说明 Lithe 当前的语言能力分层、LSP 兼容边界，以及接入新语言服务器时必须遵守的约束。公开的 Rust JSON 命令仍以
[`rust-core-api.md`](../../shared/contracts/rust-core-api.md) 为准。

## 设计目标

语言能力不应等同于“已经启动一个 LSP 进程”。当前实现遵循以下规则：

1. 编辑器只依赖统一的 `LanguageFeatureProvider`，不直接依赖具体语言服务器。
2. 轻量本地能力无需外部进程，LSP 是按需启动的语义增强层。
3. 可调用的 LSP 功能以服务器 `initialize` 响应和动态注册结果为准，不能根据语言名称硬编码。
4. LSP 进程、stdio、JSON-RPC 状态机、deadline 和结果归一化属于 Rust Core；平台 adapter 只负责可执行文件与运行环境发现。
5. 单个 provider 失败、缺失或返回空结果时，不应阻断仍可工作的本地能力。

## 组件边界

```mermaid
flowchart LR
    UI["Editor / feature model"] --> MANAGER["LanguageToolingSessionManager"]
    MANAGER --> ROUTER["LanguageFeatureProvider routing"]
    ROUTER --> BUILTIN["Builtin provider<br/>keywords + current-file symbols"]
    ROUTER --> LSPPROVIDER["LSP provider<br/>server capabilities"]
    LSPPROVIDER --> SESSION["Swift semantic facade<br/>opaque operation IDs"]
    SESSION --> CORE["Rust LSP runtime<br/>process + state + deadlines + stdio"]
    CORE --> SERVER["gopls / jdtls / rust-analyzer / ..."]
```

| 层 | 职责 | 不负责 |
| --- | --- | --- |
| `LanguageToolingSessionManager` | 文档同步、provider 选择、结果降级/合并、诊断和会话归属 | JSON-RPC 编解码、直接启动 `Process` |
| `LanguageFeatureProvider` | 声明单项能力、优先级和统一结果类型 | 维护 UI 状态 |
| `BuiltinLanguageFeatureProvider` | 当前文件标识符、轻量 hover/导航、语言关键字 | 类型推断、跨文件索引 |
| `LanguageServerFeatureProvider` | 将已协商的服务器能力适配到统一 provider 接口 | 猜测服务器能力 |
| `StdioLanguageServerSession` | 调用语义命令、投影 typed event，并以不透明 operation ID 交付 UI 回调 | LSP 请求 ID、frame、文档版本、协议超时或子进程 |
| Rust Core | LSP 子进程与 stdio、session/document state、请求 ID、deadline、frame、UTF-16 位置、结果归一化、动态能力 | 可执行文件发现、UI provider 路由 |
| macOS adapter | 工具发现、环境变量和用户可执行文件覆盖 | LSP 子进程、语言功能路由和协议语义 |

Rust Core 的 LSP 实现统一收在 `rust/lithe-core/src/lsp/`，根模块只作为稳定 facade，command runtime 仍通过 `crate::lsp::*` 使用公开契约：

```text
lsp/
├── interface/           # 通用 LSP engine、协议 reducer、transport 与稳定 DTO
│   ├── types.rs
│   ├── client.rs
│   ├── transport.rs
│   ├── host.rs
│   └── engine.rs
├── lightweight/         # 不启动语言服务器的编辑、snippet 和当前文件符号能力
│   ├── edits.rs
│   ├── snippets.rs
│   └── symbols.rs
└── languages/           # provider catalog 与语言/宿主模型 adapter
    ├── catalog.rs
    ├── jdt.rs
    └── swift.rs
```

共享的 LSP position/range 与协议 DTO 只能定义在 `interface/types.rs`；对应用公开的 runtime command/event DTO 位于 `interface/engine.rs`。`lightweight` 可以依赖这些协议 DTO，但 `interface` 不依赖轻量实现。`languages/jdt.rs` 封装 JDTLS 启动参数、配置与虚拟源码语义，generic engine 不按 Java 硬编码 capability。provider catalog 位于 `languages`，因为它描述可动态加载的语言/provider 元数据，而不是 client 状态机的一部分。

## Provider 路由

当前优先级由高到低为 `languageServer (200)`、预留的 `projectSymbols (100)`、`builtin (0)`。每次请求先按文件和功能过滤 provider，再按优先级路由：

- **Completion**：依次收集所有成功结果，保持高优先级顺序，并按 `label` 去重。因此 LSP 可提供精确候选，本地关键字和当前文件符号仍能补足结果。
- **Hover**：返回第一个非空结果；LSP 无结果或失败时继续询问本地 provider。
- **Definition/References/Implementation**：返回第一个非空位置列表，并在 LSP 不可用时降级到当前文件文本级导航。
- **Rename/Formatting/Code Action/Resolve/Execute Command**：目前仍是 LSP-only；未运行或未声明相应能力时应返回明确的 capability 错误。

provider 抛错不会让路由提前结束。这个策略用于隔离第三方语言服务器故障，但也意味着新增 provider 时必须给出稳定优先级，并避免返回伪造的“成功但无意义”结果。

## 无进程能力

Rust Core 的 `lsp.builtinCompletions`、`lsp.builtinHover` 和
`lsp.builtinNavigation` 只读取当前文件文本。Swift 层另外为 Go、Swift、Rust、Python、JavaScript 和 TypeScript 提供关键字候选；即使 Rust Core 未链接，关键字补全仍可使用。

这些结果是可用性降级，不是类型系统：

- 不解析依赖，不启动构建工具，不访问网络；
- 不保证跨文件定义、重载解析或类型正确性；
- 位置统一使用零基行号和 UTF-16 列，确保可与 AppKit 和 LSP 结果合并。

## Catalog 与工具发现

内置 provider catalog 位于
[`rust/lithe-core/resources/lsp/language-providers.json`](../../rust/lithe-core/resources/lsp/language-providers.json)。项目可以通过 `.lithe/lsp/language-providers.json` 按 `id` 覆盖内置字段、添加 provider，或使用 `disabled: true` 禁用 provider。配置格式由 [`docs/reference/language-providers.schema.json`](../reference/language-providers.schema.json) 定义：

```json
{
  "$schema": "../../docs/reference/language-providers.schema.json",
  "version": 2,
  "providers": [
    {
      "id": "go",
      "languageServerLaunch": {
        "executableNames": ["gopls-custom", "gopls"],
        "arguments": [],
        "environment": {
          "GOTOOLCHAIN": "auto"
        },
        "initializationOptions": {}
      },
      "languageServerInstallation": {
        "homebrewFormula": "gopls",
        "officialDownloadURL": "https://go.dev/gopls/"
      }
    },
    {
      "id": "templ",
      "displayName": "Templ",
      "fileExtensions": ["templ"],
      "capabilities": ["languageServer", "formatting"],
      "activationPolicy": "onDemand",
      "languageId": "templ",
      "languageServerLaunch": {
        "executableNames": ["templ"],
        "arguments": ["lsp"]
      }
    }
  ]
}
```

`executableNames` 按顺序尝试，`environment` 覆盖 Lithe 进程环境中的同名键，`initializationOptions` 原样进入 LSP `initialize` 参数。可选的 `validationArguments` 会在候选进入 session 解析前直接执行，例如 Rust provider 使用 `["--version"]` 排除存在于 `PATH` 但缺少组件的 rustup proxy。探测结果按路径和参数缓存 30 秒，退出码非零或超时的候选不会被视为可用。catalog 更新后，session manager 会丢弃 descriptor 已变化的旧会话和 runtime，并由 runtime factory 根据新 descriptor 延迟创建 runtime；因此项目新增 provider 或覆盖启动命令不再受应用启动时的内置 runtime 列表限制。

macOS discovery 的查找顺序包括项目 `.lithe` 工具目录、`LITHE_<TOOL>_PATH`/`LITHE_TOOL_<TOOL>_PATH`、`PATH` 和常见系统目录；`gopls` 等 Go 工具还会检查 `GOBIN`、`GOPATH/bin`、`~/go/bin` 和 `~/.go/bin`。discovery 只查找，不自动安装软件。

正式 macOS 与 Windows 安装包包含 JDTLS。发布构建根据 `third_party/jdtls/manifest.json` 下载固定版本，同时校验 JDTLS 归档、EPL-2.0 许可证、Lombok agent 与 MIT 许可证的 SHA-256，再将产物放入应用资源目录的 `LanguageServers/jdtls`。包内启动器通过相对路径加载 Lombok `-javaagent`，确保 JDTLS 能解析注解生成的成员；agent 缺失时启动器会明确失败，而不会产生静默的错误诊断。平台 adapter 优先使用这个包内启动器；开发环境仍保留项目工具目录、显式覆盖和 `PATH` 等外部候选作为回退。下载只发生在构建阶段，应用运行时不会联网安装 JDTLS 或 Lombok；Java 语义功能仍要求系统提供 JDK 17 或更高版本。

JDTLS 使用独立于项目运行/调试配置的全局 JDK 偏好。空路径表示自动模式：平台探测本机 JDK，并只选择主版本 17 或更高的候选。用户也可以在语言服务器设置中选择单独的 JDK Home；平台会在保存时探测 `java -version`，并在每次启动 JDTLS 前再次校验路径和版本。这个偏好不会读取、覆盖或写回项目的 Java/Maven JDK 设置。

LSP 控制中心标题栏的工具设置会在用户偏好中保存每个 provider 的可执行文件覆盖路径。session 创建时先验证并使用该路径，路径失效时继续使用 catalog 候选进行自动探测。Homebrew formula 和官方兜底地址都来自 `languageServerInstallation`，Swift 不维护 provider ID 映射。安装仍由平台层以参数数组直接执行 `brew install`，不经过 shell；没有 Homebrew/formula 时只打开对应项目的 HTTPS 官方发布或安装页面，避免用一套不安全的通用解压逻辑处理不同项目的签名和包结构。

项目配置是可执行工具配置，只有打开受信任项目时才应启用。JSON 可以声明 executable name 和参数，但不能声明 shell、任意安装命令或关闭路径/URL 校验；进程创建、超时、可执行文件验证、Homebrew 调用方式和 HTTPS 限制仍属于平台安全边界。

## LSP 会话与兼容性

当前 transport 是 LSP 标准的 stdio `Content-Length` framing。一个 provider 在一个 workspace root 下复用一个 session；同一 provider 切换到另一个 root 时，manager 会停止旧 session 并创建新 session。

生产路径由 Rust engine 持有长生命周期 `sessionID -> RuntimeSession` registry。每个 runtime 同时拥有子进程、stdio、frame buffer、文档版本、pending request/deadline、capability 和 diagnostics；Swift 只保存不透明 `sessionID` 与 application-level `operationID`。`syncDocument` 由 Rust 决定发送 version 1 的 `didOpen` 或递增版本的 `didChange`，`pollEvents` 只返回 typed state/feature/diagnostic/result/error 事件。协议 reducer/host 只作为 engine 内部实现与纯函数测试 seam，不属于应用公开命令面。

启动顺序：

1. Swift 完成可执行文件和环境发现，向 Rust 提交 typed `startServer`；
2. Rust engine 创建 session、启动进程并安装 stdout/stderr reader，再发送 `initialize`；
3. 收到响应后，Rust 保存服务器 capability，发送 `initialized` 和 provider adapter 通知；
4. manager 发布实际 capability，随后通过 `didOpen`/全量 `didChange` 同步文档；
5. Rust 以 LSP request ID 关联 deadline，并用不透明 operation ID 把 terminal result 投影给 Swift。

服务端 capability 可以来自 initialize 响应，也可以通过 `client/registerCapability` 和
`client/unregisterCapability` 动态变化。客户端处理有文档/version 归属的 diagnostics、workspace configuration/folders、work-done progress 和 apply-edit 协议；未知的服务端 request 返回 JSON-RPC `Method not found`，未知 notification 作为 typed log/event 保留。

关闭文档时发送 `textDocument/didClose` 并清除该文档诊断。停止 session 时先请求 `shutdown`，收到响应后发送 `exit`；若服务器无响应，则由超时路径强制停止进程。不要直接以 `terminate()` 代替正常 LSP 关闭流程。

### 当前限制

- 只支持 stdio transport，尚无 socket/TCP 或服务器自定义握手 adapter。
- session 当前以 provider ID 和单个 workspace root 为单位，尚无 multi-root session。
- `workspace/applyEdit` 只提供协议确认和 normalized edit 数据，实际应用仍必须经过编辑器工作区安全校验。
- initialize 可协商 snippet、resolve、inlay hint、folding range、code lens 和 workspace symbol；UI 只启用已完整投影且服务器实际声明的能力。
- 文档同步当前发送全量文本，没有按服务器类型实现增量 diff。
- catalog 描述的是“可尝试启动的工具”；最终功能必须以运行时服务器 capability 为准。
- project config 是受信任的项目配置，只接受 schema 中的 typed 字段，不执行 shell 命令。

## 接入新 LSP 的检查清单

1. 在 catalog 中定义稳定 `id`、文件匹配规则、`languageId`、候选 executable 和参数；存在 shim/proxy 的工具应声明无副作用的 `validationArguments`。
2. 需要安装入口时定义 `languageServerInstallation`；不要在 Swift UI 中增加 provider ID 分支。
3. 确认服务器支持 stdio 和标准 `Content-Length` framing。
4. 不在 UI 或 manager 中按语言写分支；服务器差异应进入 descriptor 或独立 adapter。
5. 用 initialize 响应验证 capability，不把 catalog 的 `languageServer` 标记当成 feature 支持证明。
6. 至少测试 initialize timeout/error、didOpen/change/close、请求 timeout/late response、shutdown/exit、强制停止和异常退出。
7. 包含 malformed/partial/multiple frame、动态能力、stale diagnostics、UTF-16、带空格/非 ASCII 文件 URI，以及启动即输出的场景。

## 真实 gopls 验证

[`RealGoplsIntegrationTests.swift`](../../Tests/LitheTests/RealGoplsIntegrationTests.swift)
会穿过 manager、Swift semantic facade 和拥有进程的真实 Rust Core。测试默认不启动外部工具，需要显式开启：

```bash
scripts/build-rust-core.sh --debug --target aarch64-apple-darwin

LITHE_RUN_GOPLS_INTEGRATION=1 \
LITHE_GOPLS_PATH="$HOME/.go/bin/gopls" \
swift test --disable-sandbox --no-parallel \
  --triple arm64-apple-macosx \
  -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types \
  -Xlinker -force_load \
  -Xlinker "$(pwd)/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a" \
  --filter RealGoplsIntegrationTests
```

`-force_load` 是必要条件：测试包同时包含 C bridge 的 weak fallback；普通链接可能在没有加载 Rust archive 的情况下仍然成功。Intel macOS 需要把 target/triple 和库路径替换为对应的 `x86_64` 产物。
