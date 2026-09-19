# Agent 笔记：VS Code 扩展宿主复用 Theia 插件侧

状态：提议中

## 先说结论

为了让未经修改的 VS Code 扩展（首批是 `redhat.java` 和 `vscode-java-debug`）使用 Lithe 自己的编辑器、文件和命令能力，Lithe 新增一个独立的 Node 进程，叫扩展宿主（Extension Host，运行扩展代码的进程），代码在 `extension-host/`。宿主原样复用 Theia 的“插件侧”，也就是扩展看到的 `vscode.*` API 对象；Theia 的“主进程侧”（`*Main`，原本由 Theia 工作台实现）换成 Lithe 自己写的实现，两侧在同一个进程里用内存通道连接。Lithe 只通过 `shared/contracts/vscode-extension-host.md` 定义的 JSON 协议和宿主通信，Theia 的内部类型不会越过进程边界。这是 #737 的原型，产品暂未启动它。

## 问题

#692 说明，Java 的导入、构建、classpath、重复运行和取消，如果由 Lithe 拆开调用 JDT LS 命令后自己再拼起来，就要重新实现一遍工程语义。成熟的 Java 扩展已经把这些流程做完整了，但它们只能跑在实现了 VS Code API 的宿主里。

完整 Theia 的实验（见 #737）已经证明扩展能跑起来，但那样等于在 Lithe 里藏了第二套 IDE：两份工作台、两份文档状态，内存也很高。直接移除 Theia 的工作台模块又无法启动。所以真正要回答的问题是：能不能只拿走 Theia 实现 VS Code API 的那一半，另一半换成 Lithe。

## 提案

### 进程与分层

```text
未经修改的扩展 ─ vscode.* ─> Theia 插件侧（npm 包，原样使用）
                                  │ Theia 内部 RPC，仅在进程内
                             extension-host/src/main-side/*（Lithe 的 *Main 实现）
                                  │ stdin/stdout 上的 JSON，见 shared/contracts
                             Lithe 监管方（macOS / Windows 平台适配层）
```

- Theia 插件侧（`src/plugin/`，约 3 万行）几乎只依赖 `common`/`node` 代码，只有两处引用浏览器模块，而且都不在运行路径上，所以可以从 npm 原样使用，不 fork、不打补丁。Theia 自带的 `plugin-host-module` 在加载时就会创建进程 IPC 通道，因此 `src/theia/plugin-host-container.ts` 按相同的绑定复制了一份，只把通道换掉；升级 Theia 版本时要对照这份绑定。
- 主进程侧的 50 个 `*Main` 接口由 `src/main-side/` 实现。已经实现的：命令、文档（打开、编辑、保存）、消息、进度、日志、存储、环境、`workspace.fs`（`file:`）、`findFiles`、工作区信任。其余接口都会注册成“明确报错”的代理：扩展收到带接口名的错误，Lithe 收到一次 `lithe/unsupportedApi`。每个扩展的兼容清单就由这些上报累积出来，任何接口都不许返回假成功。
- 协议是 Lithe 自己定义的：URI 字符串、从 1 开始的行列号、稳定的错误码、双向请求、取消和截止时间。

### 状态归属

- **文档**：内容、版本、脏状态和保存都以 Lithe 为准。宿主只保存一份按版本校验的镜像，版本不递增的变更会被拒绝（`staleDocumentVersion`）。扩展调用 `applyEdit` 时由 Lithe 执行编辑，Lithe 必须先发出 `host/documentChanged` 再回复，这样扩展在 `await` 之后就能读到新内容。
- **激活**：宿主从不自行激活扩展，`*`、`onStartupFinished` 也由 Lithe 发出。这样安全模式、禁用和不可信工作区都能阻止扩展代码运行。
- **配置**：默认层从已加载扩展的 `contributes.configuration` 确定性地计算出来，上面依次叠加 Lithe 默认值、用户设置和工作区设置。JDK 等工具链由 Lithe 通过配置传入，例如 `java.configuration.runtimes`；扩展不去读系统环境。
- **进程**：宿主跟踪扩展创建的所有子进程；shutdown 时如果扩展停用超时，先发 SIGTERM，3 秒后再发 SIGKILL。监管方把宿主放进独立进程组（POSIX）或 Job Object（Windows），结束整棵进程树，以覆盖孙进程和宿主崩溃的情况。
- **Java 工程语义**：项目模型、classpath、构建和启动准备仍然由扩展和它自带的 JDT LS / Java Debug 负责，Lithe Core 不复制这些逻辑。

### 正确做法

- 扩展需要新的 API 时，在 `src/main-side/` 里实现对应的通用 `*Main` 方法，必要时增加协议消息，并同时更新契约文档和测试。
- 某项能力如果 Lithe 已经有权威实现，就把请求转发给 Lithe。例如 `findFiles` 交给 Lithe 的搜索（它负责排除规则和忽略文件），不在宿主里另写一套遍历磁盘的搜索。
- 用 `scripts/audit-extensions.ts` 加载真实扩展，拿 `lithe/unsupportedApi` 的清单来决定下一步补哪些接口。

### 不要这样做

- 不要按扩展身份写分支，例如 `if (extension.id === 'redhat.java')`。确实需要专属补丁时，必须记录原因、适用版本和移除条件。
- 不要把 Theia 的 RPC 或 msgpack 格式暴露给 Swift/Rust；Lithe 侧只认 JSON 协议。
- 不要为了让激活继续下去，给未实现的接口返回空成功，那会掩盖兼容缺口。

## 考虑过的备选方案

### 嵌入或隐藏完整 Theia 工作台

优点是现成可运行，兼容性也最好。但它会在 Lithe 里形成第二套 IDE：两份文档和编辑器状态，Chromium 进程约 1.6 GiB，与 #737 的目标冲突，因此不采用。

### Fork Theia，修改它的主进程侧

优点是可以沿用 Theia 已写好的 41 个 `*MainImpl`（约 1 万行）。但这些实现深度依赖 Theia 前端、Monaco 和 inversify 服务，改完仍然是 Theia 的状态模型；fork 还要长期跟随上游升级，修改过的 EPL 文件也要公开源码。重写主进程侧反而更小，而且状态归属清晰。

### 让 Swift/Rust 直接实现 Theia 的 RPC

优点是少一层进程内转换。但 Theia 的 RPC 使用 msgpack 自定义扩展和内部接口名，版本之间会变化；这样做等于把 Theia 内部格式变成 Lithe 的跨平台契约，因此不采用。

### 复用 Code-OSS 的 extHost

它是 VS Code API 的参考实现，兼容度最高。但它与 VS Code 的构建和启动流程耦合更紧，单独拆出来的成本更高，也没有以 npm 包形式发布。可以作为 Theia 兼容度不够时的后备方案。

## 验收标准

- `extension-host/` 的测试通过（`bun run typecheck`、`bun test test`），覆盖以下场景：初始化、隐式激活事件、命令双向调用、取消后迟到的结果被丢弃、Lithe 持有文档的编辑与保存闭环、版本校验、`workspace.fs`、`findFiles`、配置分层、工作区信任、未实现 API 的上报、`process.exit` 被忽略，以及 shutdown 能结束残留子进程（包括升级到 SIGKILL）。
- 2026-09-19 在 Linux x64 上用 `scripts/audit-extensions.ts` 实测（Open VSX 包，校验和已核对）：`redhat.java` 1.56.0 和 `vscode-java-debug` 0.58.1 原样加载后都激活成功。`redhat.java` 自己启动了 JDT LS，并报告了 “Opening Java Projects” 进度；shutdown 后宿主结束了 1 个仍在运行的 JDT LS，没有进程残留。这次实测**没有**验证 ServiceReady、诊断和语言功能，因为下面这些接口都还没实现。
- 同一次实测触发的未实现接口共 41 个，也就是 M2/M3 的输入：
  - 语言功能：`LanguagesMain.$register*`（补全、悬停、定义、引用、重命名、格式化、语义高亮、CodeLens 等 22 项）、`$changeDiagnostics`、`$clearDiagnostics`、`$unregister`。这部分需要在 Lithe 编辑器的 provider 路由里新增“扩展宿主”来源，并与 Rust Core 里现有的 JDT 会话二选一，同一工作区不能出现两个 Java provider。
  - 调试：`DebugMain.$registerDebuggerContribution`、`$registerDebugConfigurationProvider`、`$unregisterDebugConfigurationProvider`。
  - 文件监听：`FileSystemEventServiceMain.$watch` 和 `$unwatch`。
  - 虚拟文档：`WorkspaceMain.$registerTextDocumentContentProvider`（`jdt://` 类文件）和 `CustomEditorsMain.*`（反编译视图）。
  - 界面：状态栏 `$setMessage`/`$dispose`、`OutputChannelRegistryMain.$append`、`TerminalMain.$registerTerminalLinkProvider`。
  - 内置命令：`_setContext`（VS Code 的 `setContext`）目前落到 `lithe/executeCommand`，Lithe 需要提供它，或者明确声明不支持。
- 后续里程碑按 #737 的 M1–M5 推进。其中“由 Lithe 平台适配层启动和监管宿主”这一步尚未完成，需要在 macOS 和 Windows 上分别实现并实测。

## 风险

- **Theia 升级**：插件侧从 npm 原样使用，但 `plugin-host-container.ts` 里的绑定和 `main.ts` 里的 msgpack 标签 `4`（`VsCodeUri`）都依赖 1.75.0 的实现。升级 Theia 时必须重跑测试和审计脚本。
- **API 兼容度**：Theia 报告的 API 版本是 1.134.0，但个别行为与 VS Code 不同（#737 已记录 `noDebug` 和添加断点的问题）。遇到时修通用层，并把修复提交给 Theia 上游。
- **资源成本**：宿主、Node 运行时和扩展自带的 JRE 会增加安装体积和内存，尚未测量；`redhat.java` 的平台包还和 Lithe 已打包的 Temurin JDK 重复。
- **授权**：只能使用 Open VSX 或其他允许在 VS Code 之外使用的来源；Theia 是 EPL-2.0，目前没有修改任何 Theia 文件。
- **回退**：原型没有接入产品。如果评估结论是不采用，删除 `extension-host/`、契约和 CI 工作流即可，现有的 Rust LSP 与 Java 运行链路不受影响。

## 适用范围

- `extension-host/`
- `shared/contracts/vscode-extension-host.md`
- `.github/workflows/ci-extension-host.yml`
- `scripts/classify-ci-changes.sh`
