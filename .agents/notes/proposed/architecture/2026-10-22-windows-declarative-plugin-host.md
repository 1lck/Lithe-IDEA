# Agent 笔记：Windows 声明式插件宿主

状态：提议中

## 先说结论

Windows 新增一套契约 v1 声明式插件宿主，与现有 Worker 扩展模型长期并行：需要宿主代用户拉起进程的语言与构建插件走契约宿主，宿主内运行 UI 与服务行为的扩展（主题、AI provider 等）留在 Worker 模型。契约引擎不需要新写——`lithe-core` 已经编译进 Windows 宿主，经 `core_execute` 就能调用 `plugins.declarative.*` 与 `plugins.marketplace.*`；真正要建的是宿主侧的包存储、信任审批、启动接线和管理界面。v0 能力声明只开放 `languages:1`、`languageServers:1`、`serverProcess:1`，声明了更高能力的插件包由 Core 自动拒绝。

## 问题

- 功能矩阵 `declarative-plugin-contract`、`plugin-functions` 对 Windows 记为 missing（2026-10-22 矩阵对齐时确认）；[声明式语言插件](../../implemented/architecture/2026-10-12-declarative-language-plugins.md) 也写明"Windows 现有扩展清单暂未改造，接入时必须通过同一组 fixture"。
- Windows 当前插件生态是渲染进程内的 Worker 扩展：`Plugins/win/Official/PhpSupport` 是 Worker 包格式（`main: "plugin.js"`），与契约包不同，无法复用 Lithe Store 面向 macOS/契约发布的语言插件包。
- Windows 没有插件信任链与仓库源管理；`install_extension_from_url` 前端已调用但 Rust 宿主从未注册，非语言扩展的落盘安装链路实际不可用。
- 契约的确定性逻辑（清单校验、启动计划展开、安装审查）按仓库规则只在 `rust/lithe-core/src/plugins/` 实现一次，而 `windows/tauri/src-tauri` 已依赖 `lithe-core`——差的只是宿主侧接线，不是契约本身。

## 提案

### 双模型边界

判定句：扩展需要"宿主代表用户拉起进程"（语言服务器、构建系统、运行/测试提供方）就走契约宿主；扩展需要"在宿主内运行自己的代码来表达 UI 或服务行为"（颜色主题、图标主题、AI provider、数据库 sidecar、ACP agent）就留在 Worker 模型。

- 正确做法：新增 Go 语言支持时写契约 `plugin.json` 声明 `languageServers` 和 `executionProviders`，由 Core 展开启动与运行计划。
- 不要这样做：把主题扩展改写成契约包；为 Worker 扩展桥接一套函数通道冒充 litheFunctions；在宿主里按插件 ID 写 `if` 分支。

### 能力声明渐进开放

v0 宿主在 `plugins.declarative.validate` 的 payload 里声明 `hostCapabilities = { languages:[1], languageServers:[1], serverProcess:[1] }`。Core 的 `capabilities.rs` 会拒绝声明了宿主未开放能力的插件，宿主不需要自己写拒绝逻辑。后续按里程碑提升：M3 增 `executionProviders:1`、`settings:1`，并把 `languageServers` 提到 2、`settings` 提到 2（注册设置页与 `workspaceConfiguration` 下推）；M4 增 `ui:[1,2]`。宿主不声明的能力，市场侧按不支持展示。

### 存储、信任与安装（v0）

- 安装根为 `app_local_data_dir()/plugins/<pluginID>/<version>/`，每包一份 `installation.json` 记录来源、版本与内容摘要；文件损坏时拒写、不覆盖既有记录。
- bundled 包从 `resource_dir()` 只读加载；运行时不写安装目录与资源目录，遵守发行基线只读边界。
- 信任模型 v0：官方 ID 防冒用由 Core 校验兜底；bundled 包随安装器分发；磁盘导入与市场下载一律走 `plugins.marketplace.installReview` 全量审批（权限 + 完整程序清单），审批界面明示"未认证发布者"。publisher Ed25519 验签明确延后，这是 v0 的已知缺口，Windows 验签方案（Authenticode 还是包内 Ed25519）单独立项评估。
- 磁盘导入的私有快照、staging 重验、内容摘要复查与回滚语义照抄 macOS 侧规则（见声明式语言插件 Note 的磁盘安装节），Windows 不另造审查语义。

### 与 Worker 扩展模型共存

- 两套模型互不桥接：契约插件不进 Worker 宿主，Worker 扩展不冒充契约能力。
- PhpSupport 迁移：M3 用契约包替换 Worker 包，保留用户启用状态后移除 Worker 版本。
- M2 一并处理 `install_extension_from_url` 死链：补注册命令或删除前端死调用，二选一在 PR 描述里说明。
- 管理界面按模型分组展示两类扩展并使用不同文案，避免用户把 Worker 扩展当成契约插件。

### 实施切分

M1 包存储 + 启动校验 + 语言注册 + LSP 启动；M2 磁盘/市场安装链路 + 管理界面 v1；M3 声明式设置 + 运行/测试计划 + PHP 契约包替换；M4 Web 工具窗口（`ui` 2，WebView2 自定义 scheme）。每个里程碑独立 PR，矩阵条目随代码同 PR 更新。总体方向遵循[公共扩展契约与 Provider 接入方向](2026-10-13-public-extension-contract-and-provider-api.md)，本 Note 只落地其中 Windows 契约宿主的第一阶段。

## 考虑过的备选方案

- 把 Worker 扩展模型整体改造成契约宿主：契约没有主题、AI provider 这些概念，改造成本高且无收益，不采用。
- 在 Tauri 侧另写一套清单校验：违反"校验只在 Core 实现一次"，共享 fixtures 无法复用，双端语义必然漂移，不采用。
- 把 Worker RPC 桥接成 litheFunctions：两者协议语义不同，会同时存在两套函数协议，等有真实插件需求时再按[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)接入。
- 信任模型一步到位 publisher 签名：Windows 验签载体需要单独评估，v0 以 bundled 加全量审批兜底，签名延后是显式记录的缺口而不是遗漏。

## 验收标准

- M1：`shared/contracts/plugins/v1/fixtures/` 全量经 `plugins.declarative.validate` 验收，`invalid-manifests.json` 的每类错误码逐一断言；合法样例包被启动扫描注册并在语言清单中出现；`languageServerLaunchPlan` 的结果能拉起真实进程。`cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml`、`scripts/build-windows.ps1`、`./scripts/verify-windows-boundaries.sh` 通过；`declarative-plugin-contract.json` Windows 状态随代码更新为 partial。
- M2：磁盘导入完成快照、全量审批、staging 重验、回滚与损坏 `installation.json` 拒写；管理界面按模型分组；`install_extension_from_url` 死链有明确处置。
- M3：PHP 契约包完成安装、启用、打开 `.php` 文件、Intelephense 启动的全链路；声明设置值代入启动模板；Worker 版 PhpSupport 移除且启用状态迁移。
- M4：`ui` 2 样例页面在 WebView2 中显示，CSP 拒绝联网与 eval，禁用、更新、卸载和窗口关闭同步销毁页面。
- 每个里程碑：`./scripts/verify-platform-feature-matrix-change.sh <base> HEAD` 通过；实机验收完成前对应矩阵条目的 `verificationStatus` 保持 pending。

## 风险

- `lsp.rs` 现以 JDTLS 专用路径为主，启动计划的挂接形状需要开工时先通读探底，可能影响 M1 工作量估计。
- Windows 的 reparse point/junction 语义与 macOS symlink 不完全相同，包内路径逃逸判断需要单独测试，不能照搬 macOS 用例。
- 签名延后意味着 v0 社区包的信任完全依赖审批界面，文案必须明示未认证状态，否则用户可能把审批当成签名背书。
- 双模型并存对用户可见，管理界面若不清晰分组会造成"为什么有两类扩展"的困惑。
- WebView2 对自定义 scheme 与 CSP 的实现细节与 WKWebView 有差异，M4 需要实机验证后再声明 `ui:2`。

## 适用范围

- `windows/tauri/src-tauri/src/`（M1 在此新增 `plugin_host/` 模块：存储、扫描、启动接线）
- `windows/tauri/src-tauri/src/lsp.rs`、`language_tools.rs`、`main.rs`（接线与命令注册）
- `windows/tauri/src/extensions/languages/`（契约插件语言来源）
- `windows/tauri/src/features/settings/`（契约插件管理区块）
- `shared/platform-feature-matrix/features/declarative-plugin-contract.json`、`plugin-marketplace.json`、`plugin-extension-management.json`、`declarative-plugin-settings.json`、`php-optional-plugin.json`、`plugin-web-tool-windows.json`
