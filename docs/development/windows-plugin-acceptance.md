# Windows 插件真实包验收矩阵（M10 准备）

状态：验收准备资料，不是验收记录。本文按
[Windows 插件功能对齐计划](windows-plugin-parity-plan.md) M10 的要求，固定真实 Windows 插件包的身份、来源与逐项可复现验收步骤，并区分第一阶段（M1–M6）与第二阶段（M7–M9）出口。**本轮没有执行任何一次完整验收，也没有任何一行可以据此宣告 M10 完成。**

数据核实：2026-10-24（首次）与 2026-10-25（能力声明/矩阵维度复核，并同步 preview `83017afa`），gh API（仓库元数据、release 资产、`Lithe-IDEA/Lithe-store/lithe-plugin-index.json`、`Lithe-IDEA/lithe-plugin-docs`）+ 主仓库基线 commit `1e78b59b6385fca6a881639b42048bf3bc587f4a` 的源码。索引与 release 会持续变化，每次执行验收前必须重新核实并把当时的 tag/版本/SHA-256 写进当次记录，不得沿用本文。

## 1. 通用验收流程（每个真实包逐项执行）

以下链条来自路线图 M10 与 Windows 声明式插件宿主 Note 的既有边界，每个包按适用子流程裁剪，但裁剪必须在记录里写明。

| # | 步骤 | 通过标准 | 记录要求 |
| --- | --- | --- | --- |
| 1 | 前置固定 | 宿主构建 SHA、包 tag/commit、版本、下载 SHA-256、架构、构建配置（Release）全部登记 | 命令与输出 |
| 2 | 安装 | 市场下载按索引 SHA-256 核对（`plugin.archive.checksumMismatch` 拒绝篡改）；磁盘导入走私有快照；staging→发布事务完成 | 安装来源字段与内容摘要 |
| 3 | 授权 | installReview 全量审批：权限 + 完整程序声明逐项可展开；社区包明示"未认证发布者"；新增程序（newPrograms）高亮 | 审批界面截图 + 审批记录持久化确认 |
| 4 | 启用与重启 | 启用后重启应用，启动扫描结果一致；停用状态持久化；bundled 包仍为最高版本 | 扫描前后 catalog 对比 |
| 5 | 真实工作流 | 打开目标项目 → 语言服务启动/构建模型 → 运行、测试 → 取消一次在途操作；操作在真实 UI 触发，非仅命令调用 | 每步入口（菜单/按钮）、预期/实际 |
| 6 | 升级失败 | 更新时篡改摘要或中断下载：旧版本与旧安装记录保持可用，本次 staging 被清理，无"新目录配旧记录" | 失败注入方式与恢复证据 |
| 7 | 回滚 | 回滚到上一版本：先停止读用旧包的会话与页面，再换目录；回滚包按自身审批记录复验 | 页面关闭与进程停止证据 |
| 8 | 卸载 | 包目录、安装记录、所属页面、相关进程全部消失；无半删目录 | 卸载后目录与进程列表 |
| 9 | 进程树清理 | 每步结束后按包入口路径核对进程列表：语言服务器、Provider、构建子进程、辅助探测进程为零残留（Job Object 语义，非仅杀父 PID） | 进程快照（启动前/每步后） |
| 10 | 发行资源哈希不变 | 安装目录（含 `resource_dir()/OfficialPlugins` 等 bundled 资源）在验收前后的文件清单与哈希完全一致；运行时状态只出现在平台可写目录 | 前后哈希清单 diff |
| 11 | 证据归档 | 按路线图 §5.4：版本三元组、入口、复现步骤、预期/实际、测试命令与单测计时、哈希清单、进程清理、已知范围；截图先脱敏 | 存放位置与索引 |

架构要求：`windows-x64` 与 `windows-arm64` 分别记录。没有 arm64 实机或可验证执行环境时保留 pending——**编译成功或 x64 仿真不替代 arm64 原生运行证据**。构建脚本已有 `aarch64-pc-windows-msvc` 目标标识（`scripts/build-windows.ps1`），但目前没有已发布的 arm64 工件与实机记录。

## 2. 真实包矩阵

"当前可得"列描述在本轮核实时点的可安装性。全部社区包当前只有 `darwin-*` 工件；**没有任何 windows-\* 工件存在**，这是第二列之外最大的统一 pending。

| 包 | 来源与版本（核实于 2026-10-24） | 许可 | Windows 入口（x64/arm64） | 外部 runtime | 当前可得 / 缺失 | 负责阶段 |
| --- | --- | --- | --- | --- | --- | --- |
| PhpSupportContract（bundled 契约包） | 主仓库 `Plugins/win/Official/PhpSupportContract`，版本 1.0.0，api2，`sameTeamAsHost`（基线 1e78b59b） | 仓库内 Lithe 资源；`intelephense.js` 为 65 字节占位入口 | runtime launch：node 启动 `language-server/bin/intelephense.js`；无 `${arch}` 路径，两架构同入口 | Node.js（宿主发现）；`php` CLI（运行/测试 executable） | 已随宿主安装链验收（validate/launch/runPlan/testPlan/resolveSettings 端到端测试 `tests.rs:433`）；真实 Intelephense 替换 pending——其许可禁止再分发（见 `2026-10-20-go-php-community-plugins` Note），Windows 分发方式需另行决定 | M10 第一阶段（完整实机链） |
| io.github.lithe-idea.php-support | [lithe-plugin-php](https://github.com/Lithe-IDEA/lithe-plugin-php) tag `v0.1.0`，api1 | Apache-2.0（仓库 license） | systemCommand `intelephense --stdio`；工具架构随用户安装 | Node.js（runtimeDependencies）+ 用户自装 intelephense（npm，许可禁止打包） | macOS 可装；**windows 工件 pending**；官方索引/商店均未列 windows 平台 | M2（市场安装链）→ M10 第一阶段 |
| io.github.lithe-idea.go-support | [lithe-plugin-go](https://github.com/Lithe-IDEA/lithe-plugin-go) tag `v0.1.0`，api1 | Apache-2.0 | systemCommand `gopls`；go 工具链架构随系统 | Go 工具链（runtimeDependencies，宿主发现） | macOS 可装；**windows 工件 pending** | M2 → M10 第一阶段 |
| io.github.lithe-idea.lua-support | [lithe-plugin-lua](https://github.com/Lithe-IDEA/lithe-plugin-lua) tag `v0.3.0`（另有 0.1.0/0.2.0），api1 | Apache-2.0 | packaged `bin/lithe-lua-language-server`——**架构相关二进制**，Windows 需按 x64/arm64 分别出工件 | 无（服务器自带） | macOS 可装（0.3.0 起分 darwin-arm64/darwin-x64 两个资产）；**windows 工件 pending** | M2 → M10 第一阶段 |
| io.github.lithe-idea.gradle-build | [lithe-plugin-gradle](https://github.com/Lithe-IDEA/lithe-plugin-gradle) tag `v0.1.1`，api3，`requires {buildSystems:1}`，模型源 command | Apache-2.0 | 声明式构建工具窗口 + 命令计划；入口依赖构建工具（Gradle wrapper/gradle） | Gradle（项目 wrapper 或 PATH） | macOS 可装；Windows 当前 `apiUnsupported`（宿主未声明 buildSystems）；**windows 工件 pending** | M4 开放能力 → M10 第一阶段 |
| io.github.lithe-idea.maven-build | [lithe-plugin-maven](https://github.com/Lithe-IDEA/lithe-plugin-maven) tag `v0.1.1`，api3，`requires {buildProviders:1, buildSystems:1, serverProcess:1}`，模型源 provider | Apache-2.0 | Provider 进程（自有 launch）+ Core litheBuild 协商 | JDK（provider 进程与 Maven 工具链） | macOS 可装：宿主能力表声明 `buildProviders:[1]`、`buildSystems:[1,2]`、`serverProcess:[1]`（`PluginTypes.swift:492-503`），Core `SUPPORTED_CAPABILITIES` 同表；矩阵 `build-provider-refresh-and-tool` 记 macOS implemented/验证 pending（`MacBuildProviderSessionsTests` 覆盖会话自动化）——implemented 不等于已验证；Windows `apiUnsupported`（能力未开放）；**windows 工件 pending** | Windows 侧 M5 开放能力 → M10 第一阶段（Provider/函数线）；macOS 侧验证对照随 M10 第一阶段 |
| io.github.lithe-idea.cargo-build | [lithe-plugin-cargo](https://github.com/Lithe-IDEA/lithe-plugin-cargo) tag `v0.1.1`，api3，`requires {buildProviders:1, buildSystems:2, serverProcess:1, settings:2}`，模型源 provider；0.1.0 为 `{buildSystems:1, buildProviders:1}` | Apache-2.0 | Provider 进程；cargo 工具链 | Rust/Cargo 工具链 | 0.1.1 的 `buildSystems:2` 由 Core（`capabilities.rs` `SUPPORTED_CAPABILITIES`）与 macOS 宿主能力表（`buildSystems:[1,2]`）共同支持，macOS 可装（矩阵 `cargo-build-plugin` 记 macOS implemented/验证 pending）；Windows `apiUnsupported`（buildSystems/buildProviders 未声明）；**windows 工件 pending** | Windows 侧 M4/M5 开放能力（路线图 M4 明确含 `buildSystems:2` 兼容输入解析）→ M10 第一阶段 |
| io.github.lithe-idea.svn-support | [lithe-plugin-svn](https://github.com/Lithe-IDEA/lithe-plugin-svn) tag `v0.1.0`，api3，`requires {vcsProviders:1, serverProcess:1}`，vcsTool svn | Apache-2.0 | VCS Provider 进程会话 | svn 命令行客户端（用户提供） | macOS 可装：宿主已声明 `vcsProviders:[1]`（`PluginTypes.swift:502`），Core 支持；矩阵 `vcs-subversion-and-plugin-providers` 记 macOS partial/验证 pending（`VcsProviderHostTests` 覆盖根识别、元数据监听与生命周期自动化；svn 解析与错误码由其插件仓库 CI 经 Core 桥接在 file:// 仓库验证）；Windows `apiUnsupported`；**windows 工件 pending** | M9 → M10 第二阶段 |
| Java Support（dev.lithe.plugin.java-support） | macOS bundled 官方包；JDT LS 上游固定 [v1.61.0](https://github.com/eclipse-jdtls/eclipse.jdt.ls/tree/v1.61.0)；包内含 `LICENSE-EPL-2.0.txt`（组装脚本 `assemble-package.sh` 随包携带） | JDT LS 及 Eclipse 扩展为 EPL-2.0（随包 LICENSE 文件）；icons 目录 Apache-2.0 | Windows 无分发：路线图 M8 明确必须满足其整份 `requires`，不得复用 macOS ZIP（含 macOS 架构 JDK/runtime） | 打包 JDK（packagedRuntime，`${arch}` 路径） | macOS bundled 可用；**Windows 分发 pending（构建/打包决策未做）** | M8（生成器/分发）+ M10 第一阶段（语言链验收） |
| 官方可下载插件渠道 | `Plugins/marketplace/index.json` 与 `official-plugins.json` 均为空；发布管线 `release-official-plugins.yml` 存在（macos-26 runner 构建、tag 系列 `<tagPrefix><version>`） | 按未来包而定 | 官方索引当前无条目，无可验收的官方 Windows 包 | — | 渠道就绪但**无条目 → pending**；第一个官方包发布后按 §1 全链验收 | M2（索引/下载）→ M10 第一阶段 |
| 原生 UI 真实示例（ui:3） | 未选定外部示例仓库与版本 | 待选型 | native schema 树/列表/表单渲染 | 待选型 | **pending 选型**；路线图要求"固定版本的外部示例" | M7 → M10 第二阶段 |
| 项目生成器真实包（projectGenerators） | 未选定（`project-generator` fixture 仅覆盖 Core 语义；JavaSupport 模板为 macOS 分发） | 待选型 | 新建项目窗口 + files/command/archive 步骤 | 待选型 | **pending 选型** | M8 → M10 第二阶段 |

补充说明：

- 商店索引当前 8 个插件、13 个版本全部只列 `darwin-arm64`/`darwin-x64` 下载（gh 复核 2026-10-25，`lithe-plugin-index.json`）。Windows 可用性在这些包发布 windows-\* 工件并更新索引之前，一律按 `plugin.index.platformUnsupported` 展示——这是契约定义的诚实状态，不能通过放宽校验绕过。
- 索引新增的 `io.github.lithe-idea.database 0.1.0` 声明 `requires {backend:1, serverProcess:1, ui:2}`：本审计基线 `1e78b59b` 的 Core 未定义 `backend` capability；preview 已在 `8471b998`（#1470 数据库插件线）新增 `backend:[1]` 且 macOS 宿主能力表已声明（`PluginTypes.swift:493`），Windows 宿主对 backend 零引用。本 PR 已同步 preview，`fixtures/backend.plugin.json` 已随同步登记进覆盖清单。该插件属于本轮 M0–M10 冻结范围之外的新能力，这里只记录事实，不列为验收项。
- 宿主能力与 Core 支持版本的事实来源：`macos/Sources/LitheModuleAPI/Plugins/PluginTypes.swift:492-504`（`PluginManifest.hostCapabilities`：backend:[1]、buildProviders:[1]、buildSystems:[1,2]、executableResolution:[1]、executionProviders:[1]、projectGenerators:[1]、serverProcess:[1]、settings:[1,2]、ui:[1,2,3]、vcsProviders:[1]、languages:[1]、languageServers:[1,2]）与 `rust/lithe-core/src/plugins/capabilities.rs`（`SUPPORTED_CAPABILITIES`）。注意 `shared/contracts/plugins/v1/README.md` 能力一节仍写 macOS 不声明 buildProviders/vcsProviders（preview 上也保留），已落后于代码，以代码与功能矩阵为准（过时描述已记录在 fixture 覆盖审计 §5）。

## 3. 分包类验收步骤（§1 通用链的裁剪点）

### 3.1 语言插件（php-support / go-support / lua-support / Java Support）

- 前置：目标 runtime 可被发现（Node/Go/JDK）或用户自装工具存在（intelephense/gopls）；缺失时 LSP 状态显示缺少工具而不是崩溃。
- 安装 → 审批（重点核对 systemCommand 程序声明的 `commands/arguments/validationArguments`）→ 启用 → 打开匹配扩展名的文件 → 语言服务器启动、补全/诊断可用 → 停用后进程退出、入口撤销 → 更新/回滚/卸载全链。
- lua 的 packaged 二进制：额外核对拒绝包内 reparse point/路径逃逸、`${stateDir}` 状态目录不写包内。
- Windows 特有：`LITHE_NODE_PATH`/`LITHE_GO_PATH` 导出与 PATH 前置在从开始菜单启动（非 shell）时生效。

### 3.2 构建插件（gradle-build / maven-build / cargo-build）

- 前置：宿主能力声明已含 `buildSystems`/`buildProviders`（M4/M5 之后），市场侧展示可安装而不是不支持。
- 检测（marker/nesting/priority）→ 工具窗口按声明注册 → 模型/依赖加载（command 或 provider）→ 选项修改与 `resolveOptions` → 任务/运行/测试执行与取消 → sync 文件变更触发过期提示。
- maven/cargo 的 provider 模型：核对 litheBuild 协商失败可诊断、崩溃重启、`refresh` 语义；两个项目窗口互不串会话。
- Windows 特有：Maven 原有专用流程不得退化；Worker/声明式的拥有者优先规则按计划 M0 审计结论执行。

### 3.3 Provider 函数与设置页（随 maven-build/cargo-build）

- 网页 `functions.list/invoke/cancel` 走本插件 Provider；`settingActions` 按钮与网页同链路；`restart/immediate/reload/nextRun` 四种 effect 在真实进程上观察。
- 关闭页面/项目、停用、更新时无残留调用与旧进度。

### 3.4 原生 UI 示例（M7 后）

- 树/列表/表单/工具栏/右键动作渲染；中文输入、键盘导航、浅深主题、窄面板回退、状态恢复、并发动作；停用后入口与窗口撤销。
- 更新 `declarative-native-plugin-ui` 矩阵前，上述全部为验收项而非演示项。

### 3.5 项目生成器（M8 后）

- 欢迎页/菜单进入通用新建项目窗口 → 插件生成器字段与步骤 → 目标旁临时 staging → 成功后移动，失败/取消删除 → Git 初始化与 JDK 设置 → 打开后进入语言导入与构建识别。
- 目标目录已存在或被并发创建时拒绝覆盖；失败无半成品；成功不写安装目录。

### 3.6 VCS Provider（M9 后）

- 根识别 → 状态/提交/更新/回滚入口按协商能力显示 → 关闭项目窗口停止 Provider 会话 → 嵌套根归属最深 → 缺少 svn 客户端、凭据/网络失败按稳定码展示。
- Git 主流程不回归是并行退出条件。

## 4. 阶段出口核对单

第一阶段出口（M1–M6 完成后执行）：

- [ ] 至少一个真实市场包完成 §1 全链（1–11）并归档证据。
- [ ] 语言（php/go/lua 之一）、构建（gradle/maven 之一）、Provider+函数与设置页各有真实包行完成。
- [ ] Windows bundled PhpSupportContract 用真实 Intelephense（或明确的分发决定）完成完整实机链。
- [ ] windows-x64 每行有记录；windows-arm64 的 pending 逐行显式列出。
- [ ] 每行发行资源哈希不变 + 进程树零残留核对通过。
- [ ] `plugin-functions`、`plugin-registered-settings-pages`、网页桥相关矩阵按实际范围更新（归属相应里程碑 PR，不在本文）。

第二阶段出口（M7–M9 完成后执行）：

- [ ] 原生 UI 示例、项目生成器包、VCS Provider 包各自完成适用子流程。
- [ ] 生成器"生成 → 打开 → 语言服务 → 构建/运行"链有真实包证据。
- [ ] arm64 pending 重新评估；仍缺实机则继续显式 pending。
- [ ] 哈希/进程清理要求同第一阶段。

## 5. 数据来源与更新规则

- 仓库元数据/release/索引：gh API（`repos/Lithe-IDEA/*`、`repos/Lithe-IDEA/Lithe-store/contents/lithe-plugin-index.json`）；许可取仓库 license 字段与包内 LICENSE 文件。
- 契约语义与宿主边界：`shared/contracts/plugins/v1/README.md`、[Windows 声明式插件宿主 Note](../../.agents/notes/implemented/architecture/2026-10-22-windows-declarative-plugin-host.md)、[Go/PHP 社区化 Note](../../.agents/notes/implemented/architecture/2026-10-20-go-php-community-plugins.md)、[Java 语言服务器插件 Note](../../.agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md)。
- 更新规则：本文只固定"验收输入的身份与步骤"。每次执行验收时重新 fetch 来源，把当时的 tag、版本、SHA-256、架构、宿主 SHA 写入当次验收记录；本文矩阵行与当次记录冲突时，以当次记录为准并回写本文。不得在本文新增下载物、私钥或无版本生成资源；不把模拟测试或单测当作实机交付。
