# Agent 笔记：Windows 声明式插件宿主

状态：已实现

## 先说结论

Windows 新增一套契约 v1 声明式插件宿主，与现有 Worker 扩展模型长期并行：需要宿主代用户拉起进程的语言与构建插件走契约宿主，宿主内运行 UI 与服务行为的扩展（主题、AI provider 等）留在 Worker 模型。契约引擎不需要新写——`lithe-core` 已经编译进 Windows 宿主，经 `core_execute` 就能调用 `plugins.declarative.*` 与 `plugins.marketplace.*`。M1 已落地：包存储、启动扫描与隔离、语言服务器启动计划解析，以及共享 fixtures 的全量验收；M2 已补磁盘导入安装链、设置内独立管理页和 runtime 启动的 `minimumVersion` 探测；M3 已补声明式设置（`languageServers` 2 / `settings` 2 能力声明、双层存储、`immediate` 效果下推）、运行/测试计划命令与契约版 PHP bundled 包。能力声明开放 `languages:1`、`languageServers:[1,2]`、`serverProcess:1`、`settings:[1,2]`，其余能力（`executionProviders`、`buildProviders`、`buildSystems`、`ui`）仍由 Core 自动拒绝。

## 问题

- 功能矩阵 `declarative-plugin-contract`、`plugin-functions` 对 Windows 记为 missing（2026-10-22 矩阵对齐时确认）；[声明式语言插件](2026-10-12-declarative-language-plugins.md) 也写明"Windows 现有扩展清单暂未改造，接入时必须通过同一组 fixture"。
- Windows 当前插件生态是渲染进程内的 Worker 扩展：`Plugins/win/Official/PhpSupport` 是 Worker 包格式（`main: "plugin.js"`），与契约包不同，无法复用 Lithe Store 面向 macOS/契约发布的语言插件包。
- Windows 没有插件信任链与仓库源管理；`install_extension_from_url` 前端已调用但 Rust 宿主从未注册，非语言扩展的落盘安装链路实际不可用。
- 契约的确定性逻辑（清单校验、启动计划展开、安装审查）按仓库规则只在 `rust/lithe-core/src/plugins/` 实现一次，而 `windows/tauri/src-tauri` 已依赖 `lithe-core`——差的只是宿主侧接线，不是契约本身。

## 决策

### 双模型边界

判定句：扩展需要"宿主代表用户拉起进程"（语言服务器、构建系统、运行/测试提供方）就走契约宿主；扩展需要"在宿主内运行自己的代码来表达 UI 或服务行为"（颜色主题、图标主题、AI provider、数据库 sidecar、ACP agent）就留在 Worker 模型。

- 正确做法：新增 Go 语言支持时写契约 `plugin.json` 声明 `languageServers` 和 `executionProviders`，由 Core 展开启动与运行计划。
- 不要这样做：把主题扩展改写成契约包；为 Worker 扩展桥接一套函数通道冒充 litheFunctions；在宿主里按插件 ID 写 `if` 分支。

### 能力声明渐进开放

宿主在 `plugins.declarative.validate` 的 payload 里声明 `hostCapabilities = { languages:[1], languageServers:[1,2], serverProcess:[1], settings:[1,2] }`。Core 的 `capabilities.rs` 会拒绝声明了宿主未开放能力的插件，宿主不需要自己写拒绝逻辑。后续按里程碑提升：M3 增 `executionProviders:1`、`settings:1`，并把 `languageServers` 提到 2、`settings` 提到 2（注册设置页与 `workspaceConfiguration` 下推）；M4 增 `ui:[1,2]`。宿主不声明的能力，市场侧按不支持展示。

### 存储、信任与安装（v0）

- 安装根为 `app_local_data_dir()/plugins/<pluginID>/<version>/`，`installation.json` 记录版本与启用状态；记录缺失或损坏的包隔离展示，绝不静默加载。
- bundled 包从 `resource_dir()/OfficialPlugins` 只读加载，多版本目录取最高版本；运行时不写安装目录与资源目录，遵守发行基线只读边界。
- 每个插件的语言服务器状态目录在 `app_local_data_dir()/plugin-state/<pluginID>/<workspace 哈希>`，由宿主注入启动计划请求。
- 信任模型 v0：官方 ID 防冒用由 Core 校验兜底；bundled 包随安装器分发；磁盘导入（已落地）与市场下载（M3+）一律走 `plugins.marketplace.installReview` 全量审批（权限 + 完整程序清单），审批界面明示"未认证发布者"。publisher Ed25519 验签明确延后，这是 v0 的已知缺口，Windows 验签方案（Authenticode 还是包内 Ed25519）单独立项评估。
- 磁盘导入的私有快照、staging 重验、内容摘要复查与回滚语义照抄 macOS 侧规则（见声明式语言插件 Note 的磁盘安装节），Windows 不另造审查语义。

### 启动接线（M1 落地形状）

- `plugin_host` 模块（`store.rs` 存储布局、`scan.rs` 扫描与校验、`launch.rs` 启动计划解析）是宿主侧唯一入口；校验与计划展开全部经 `lithe_core::execute_json` 调 Core 命令，宿主不复制任何清单语义。
- `packaged` 启动入口解析后必须是包内普通文件：拒绝 reparse point（符号链接与 junction）与规范化后的路径逃逸，这是宿主执行每个启动前的统一闸门。
- `runtime` 与 `systemCommand` 启动经 PATH 探测（复用 `language_tools` 的系统工具查找），并按 macOS 同一约定导出 `LITHE_<TOOL>_PATH`、把 packaged runtime 目录前置到 `PATH`；`minimumVersion` 探测随 M2 安装链一起接入。
- 语言服务器进程仍由共享 Core 的 `lsp.startServer` 拉起：前端 `resolve-editor-lsp-launch.ts` 在 Worker 扩展清单没有对应服务器时，回落到 `declarative_plugins_language_launch`（契约插件排在 Worker 之后，已由 Worker 声明的语言保持现状，直到 M3 包迁移）。
- 启动扫描在应用 bootstrap 的 "declarative plugins" 步骤执行一次；扫描结果缓存在 Tauri state，前端经 `declarative_plugins_state` 只读消费。

### 与 Worker 扩展模型共存

- 两套模型互不桥接：契约插件不进 Worker 宿主，Worker 扩展不冒充契约能力。
- PhpSupport 迁移（M3 调整）：契约版 PHP 包（`Plugins/win/Official/PhpSupportContract`，`sameTeamAsHost` bundled）随安装器分发并完成 validate/launch/runPlan 端到端测试，但 Worker 版**保留不移除**。原因：Worker 版提供 composer scripts 的动态运行动作发现（读取工作区 composer.json 生成动作列表），契约 v1 的 `executionProviders` 是静态声明，没有等价能力；删除 Worker 版会丢失用户可见功能。完整迁移等契约补齐动态运行动作后再做。两包并存时 Worker 版优先（Worker 扩展清单先解析），契约包不重复注册语言。
- `install_extension_from_url` 等 Worker 非语言市场命令（M2 已处置）：在 Rust 宿主注册为显式占位错误（`extensionStore.notAvailable`），调用方得到可诊断的结构化失败而不是"命令不存在"；完整落盘后端是独立工作项，不与契约宿主混淆。
- 管理界面按模型分组展示两类扩展并使用不同文案，避免用户把 Worker 扩展当成契约插件。

### 实施切分

M1 包存储 + 启动校验 + 语言注册 + LSP 启动（已落地）；M2 磁盘安装链路 + 管理界面 v1 + 死链处置（已落地）；M3 声明式设置 + 运行/测试计划 + PHP 契约包（已落地，Worker 版保留见上文）；M4 Web 工具窗口（`ui` 2，WebView2 自定义 scheme）。每个里程碑独立 PR，矩阵条目随代码同 PR 更新。总体方向遵循[公共扩展契约与 Provider 接入方向](../../proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)，本 Note 只落地其中 Windows 契约宿主的第一阶段。

## 考虑过的备选方案

- 把 Worker 扩展模型整体改造成契约宿主：契约没有主题、AI provider 这些概念，改造成本高且无收益，不采用。
- 在 Tauri 侧另写一套清单校验：违反"校验只在 Core 实现一次"，共享 fixtures 无法复用，双端语义必然漂移，不采用。
- 把 Worker RPC 桥接成 litheFunctions：两者协议语义不同，会同时存在两套函数协议，等有真实插件需求时再按[插件函数契约](2026-10-20-plugin-function-contract.md)接入。
- 信任模型一步到位 publisher 签名：Windows 验签载体需要单独评估，v0 以 bundled 加全量审批兜底，签名延后是显式记录的缺口而不是遗漏。
- 在 `lsp_start` 一类原生命令里拉起插件服务器：现有 LSP 会话全部由 Core 统一管理（会话、取消、事件泵都在 Core），前端只解析可执行路径与参数；另建原生拉起路径会分裂会话所有权，不采用。

## 后果

- 收益：Windows 用户开始能安装与运行契约 v1 语言插件，语言插件包与 macOS/Lithe Store 同格式；契约验收（同组 fixtures）成为 Windows 持续回归的一部分；后续里程碑只增不改这条链路。
- 代价：双模型并存是用户可见的复杂度，M2 管理界面必须分组；`minimumVersion` 探测与内容摘要复查尚未接入（分别随 M2 安装链接入），此前被篡改的包只能靠清单校验与路径闸门拦截。
- 已知风险：签名延后意味着 v0 社区包信任完全依赖审批界面（M2），文案必须明示未认证状态；Windows 的 reparse point/junction 语义与 macOS symlink 不完全相同，包内路径逃逸判断已按 Windows 语义单独测试；WebView2 对自定义 scheme 与 CSP 的实现细节与 WKWebView 有差异，M4 需要实机验证后再声明 `ui:2`。
- M2–M4 里程碑：磁盘/市场安装链路 + 管理界面；声明式设置 + 运行/测试计划 + PHP 契约包替换；Web 工具窗口。每个里程碑独立 PR，能力声明与矩阵条目随代码同 PR 更新。

## 验证

- M3 设置链路：`settings_tests`（`plugin_host/tests.rs`）覆盖项目覆盖往返、其他插件条目保留、损坏 store 报错不重置；能力门控测试随声明提升更新（settings-v2 fixture 被接受）。设置编辑 UI（`declarative-plugin-settings-editor.tsx`）按声明的 scope/effect 渲染并显示值来源徽标。
- M3 运行计划：契约 PHP 包端到端测试（`bundled_php_contract_package_expands_plans`）走真实 Core 命令验证 validate、runPlan（`${file}`/`${userArguments}` 展开）、testPlan（workspace scope + 项目标记）、resolveSettings。


- M2 磁盘导入链测试（`windows/tauri/src-tauri/src/plugin_host/install_tests.rs`）：目录快照隔离（symlink 拒绝）、ZIP 解包与恶意路径（`../` 逃逸条目）拒绝、staging 安装（坏包失败保留现行版本且清空 staging）、回滚版本选择；runtime 启动的版本探测输出解析（node/java/go 真实输出格式）在 `launch.rs` 测试覆盖。
- 管理界面（`declarative-plugins-section.tsx`）挂在设置的独立一级页，`settings-hierarchy.test.tsx` 的布局断言随导航更新；i18n 提供 en-US 与 zh-CN 全套文案。


- 共享 fixtures 全量验收在 Windows 二进制内完成：`invalid-manifests.json` 全部 154 个用例经宿主校验路径断言同一稳定错误码（不带 hostCapabilities 的契约等价模式），合法样例在不带与带 v0 能力声明两种模式下分别断言通过与 `plugin.api.unsupported` 门控。测试入口：`windows/tauri/src-tauri/src/plugin_host/tests.rs`，运行 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml plugin_host`。
- 存储与启动的单测覆盖安装记录缺失/损坏隔离、bundled 最高版本选择、版本比较（含 prerelease）、扩展与文件名匹配（大小写与前导点）、packaged 路径逃逸拒绝、runtime 的 `LITHE_<TOOL>_PATH` 导出与 `PATH` 前置。
- 前端回落链路测试：`windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.test.ts` 断言契约插件启动映射与无归属文件返回 null；启动扫描步骤在 bootstrap 中执行。
- M1 尚属静态与进程内验证：真实插件包安装→启用→语言服务器拉起的全链路实机验收随 M2/M3 完成，期间矩阵 `verificationStatus` 保持 pending。`./scripts/verify-windows-boundaries.sh`、`./scripts/verify-platform-feature-matrix-change.sh <base> HEAD` 随 PR 通过。

## 适用范围

- `windows/tauri/src-tauri/src/plugin_host/`（存储、扫描、启动接线与 fixtures 验收测试）
- `windows/tauri/src-tauri/src/main.rs`（模块注册与命令注册）
- `windows/tauri/src-tauri/src/language_tools.rs`（复用的系统工具查找）
- `windows/tauri/src-tauri/src/plugin_host/install.rs`（磁盘导入、卸载、回滚、启停）
- `windows/tauri/src-tauri/src/extension_store_placeholder.rs`（Worker 扩展落盘命令的显式占位）
- `windows/tauri/src/features/plugins/declarative-plugin-launch.ts`（前端宿主 API）
- `windows/tauri/src-tauri/src/plugin_host/settings.rs`（设置双层存储与命令）
- `windows/tauri/src-tauri/src/plugin_host/run_plans.rs`（运行/测试计划命令）
- `windows/tauri/src/features/plugins/declarative-plugin-settings-editor.tsx`（设置编辑）
- `windows/tauri/src/features/plugins/declarative-plugin-run.ts`（契约插件运行入口）
- `Plugins/win/Official/PhpSupportContract/`（契约版 PHP bundled 包）
- `windows/tauri/src/features/plugins/declarative-plugins-section.tsx`（设置内管理页）
- `windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.ts`（契约插件回落来源）
- `windows/tauri/src/features/bootstrap/bootstrap-async.ts`（启动扫描步骤）
- `shared/platform-feature-matrix/features/declarative-plugin-contract.json`、`plugin-marketplace.json`、`plugin-extension-management.json`、`declarative-plugin-settings.json`、`php-optional-plugin.json`、`plugin-web-tool-windows.json`
