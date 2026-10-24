# Agent 笔记：数据库拆成双端共用的独立插件

状态：已实现

## 先说结论

数据库连接功能已经从 Lithe 主仓库和主安装包中移出，成为组织仓库 `Lithe-IDEA/lithe-plugin-database` 中的官方插件 `dev.lithe.plugin.database`。只装 IDE 时没有任何数据库入口；从插件市场安装后才能使用。插件的界面是包内网页，后端用 Rust 编写，macOS 和 Windows 将共用同一份代码。

主仓库只保留通用的插件能力：不依附构建系统的插件后端、宿主凭据存储，以及一个过渡垫片——把旧版内置模块保存的连接、历史和密码迁入插件，并提示老用户安装。macOS 先上线；Windows 等插件宿主和插件市场就绪后，补一轮编译、适配和测试即可使用，插件本体不重写。

开发时记住一条：主仓库里不再为“数据库”写任何专属代码。SQL 判定、界面、驱动都只改插件仓库；主仓库只改通用的插件能力。

## 问题

### 体积：数据库在主包里占多少

2026-10-24 在本机 Lithe 0.6.0（arm64）上测量：

| 部分 | 大小 |
| --- | --- |
| 整个 `Lithe.app` | 557 MB |
| `Contents/Resources/LanguageServers` | 397 MB |
| `Contents/MacOS/Lithe`（主程序，含数据库界面代码） | 105 MB |
| `Contents/Helpers/lithe-db-sidecar` + `lithe-db-mcp` | 约 9.4 MB |

数据库的体积主要来自两个后端程序。不过，这次拆分的目的不只是体积：数据库还应该能单独安装、更新和卸载，并且两端共用一份实现。

### 现状：逻辑分布在哪里

| 层 | macOS | Windows | 是否共享 |
| --- | --- | --- | --- |
| 驱动与执行 | `rust/lithe-db-sidecar`，约 5400 行，支持 mysql、mariadb、postgresql、sqlite、sqlserver、mongodb、redis、nacos | `package-database-sidecars.ts` 要构建 `lithe-database` crate，仓库中没有这个 crate | 否 |
| 协议 | Swift 结构体（`DatabaseSidecarService.swift`）与 Rust serde 各自定义 | `features/database/types/` 里另一套 TS 类型 | 否，没有共享契约和测试样例（fixtures） |
| 领域规则 | `LitheDatabaseModule` 的 Models、Services，以及 `DatabaseFeatureModel` | TS store | 否 |
| 界面 | `Views/Database/`，约 6700 行 SwiftUI | `features/database/`，约 9400 行 React | 各写一套 |

### 已经出现的偏差

1. **Windows 从来没有能用的数据库功能。**
   - 前端调用 `connect_database`、`run_database_provider_command` 等 9 个 Tauri 命令，`windows/tauri/src-tauri/src/main.rs` 的命令注册表里一个都没有。
   - 这批前端代码在 2026-08-14 “React Tauri 替换 Qt 前端”时一次导入。仓库任何分支的历史里都没有对应后端，Qt 时期也没有数据库功能。
   - 用户能碰到这条坏路径：`file-utils.ts` 把 `.db`、`.sqlite`、`.duckdb` 文件交给数据库查看器，随后调用失败。
   - 功能矩阵把 Windows 的四项数据库能力标为 `implemented`；README 把数据库工作台列为核心功能，没有注明只支持 macOS。
2. **macOS 把领域规则写在了壳里。**
   - SQL 分析、语句拆分和格式化（`DatabaseSQLSupport.swift`）；
   - 结构对比、按方言生成 DDL（`DatabaseSchemaDiff.swift`）；
   - DBX 导入解密（`DatabaseDBXImportService.swift`）；
   - 字段遮罩、查询历史和定时备份。

   这些都写在 Swift 里，`DatabaseFeatureModel.swift` 有 2700 多行。
3. **同一条规则写了三份，并且已经不一致。**
   - “SQL 是什么类型、是否危险”分别由 Swift 的 `DatabaseSQLAnalyzer`（先去注释再按词判断）、sidecar 的 `is_dangerous_sql`（字符串匹配）和 mcp 的 `classify_sql`（另一套前缀匹配）判断。
   - 一个例子（由代码推导，未实机复现）：连接开启生产保护后，执行 `DELETE FROM users`，换行后再写 `WHERE id = 1`。Swift 判断不需要确认，sidecar 却因为找不到 `" WHERE "` 而拒绝执行。macOS 不处理它返回的 `confirmation_required`，用户只看到报错，没有确认入口。
   - 反过来，开头带一行注释或使用 `WITH … DELETE` 的语句，能绕过 sidecar 的判断。

### 现有插件契约为什么装不下

- **网页界面只能操作构建系统。** 网页桥接对象（`window.lithe`）只能操作本插件声明的构建系统；插件函数在 macOS 上也只由构建 provider 的会话提供。数据库插件只能伪装成构建系统，违反[公共扩展契约](../../proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)的“不要伪造声明”。
- **插件拿不到宿主的凭据存储。** 插件调用宿主服务（`lithe/host/*`）在协议 v1 中全部被拒绝，没有地方安全地保存密码。
- **Agent 用不上数据库能力。** `lithe-db-mcp` 只被打包进 `Contents/Helpers`，没有任何代码启动或登记它，Agent 实际调用不到。Lithe 已有自己的 `lithe` MCP（`lithe-mcp` 加 IDE 宿主的能力目录和项目授权），插件能力应当从这里进入，而不是再起一个独立 MCP 进程。
- **Windows 还没有声明式插件宿主和插件市场。** 声明式插件宿主正在 #1424 中开发；插件市场目前只有 macOS 版。

## 决策

### 一、最终用户看到什么

- 只装 Lithe 时，没有数据库工具窗口、菜单或 Services 条目。
- 在插件市场安装“数据库”插件后，数据库工具窗口出现：连接树、SQL 控制台、数据表格、结构对比，以及 Redis 和 Nacos 视图，都在宿主管理的窗口里，以插件网页显示。
- 停用或卸载后，入口消失，插件拥有的进程全部结束。
- macOS 先提供；Windows 在插件宿主和插件市场就绪后提供，使用同一个插件版本。

### 二、代码归属

| 位置 | 内容 |
| --- | --- |
| 组织仓库 `Lithe-IDEA/lithe-plugin-database`（新建） | Rust 后端（从 `lithe-db-sidecar` 演进，吸收 `lithe-db-mcp` 的查询能力）、网页界面、`plugin.json`、数据库专属的测试样例和兼容性测试 |
| 主仓库 | 只保留通用能力：契约、Rust Core 校验、两端宿主实现、Rust 后端 SDK 的契约测试 |
| 主仓库最终删除 | `macos/Sources/LitheDatabaseModule/`、`macos/Sources/Lithe/Views/Database/`、`rust/lithe-db-sidecar/`、`rust/lithe-db-mcp/`、`windows/tauri/src/features/database/` 及打包脚本中的数据库部分 |

插件仓库只依赖公开契约：`lithe-plugin-docs` 中锁定的契约副本加官方 SDK，和 Cargo、SVN 插件的做法相同。主仓库不再按“数据库”写任何分支。

### 三、插件身份与分发

- 使用官方 ID（`dev.lithe.plugin.database`），带 Lithe 发布者签名。原因是插件会经手用户的数据库密码，不能使用不需要 Lithe 签名的社区插件身份。
- 签名在组织仓库的发布 CI 中完成：发布者私钥只作为插件仓库的 CI secret 存在，插件自己出包、签名、登记索引；主仓库的发布流程不参与插件出包。
- 每个版本按平台发布下载包（`darwin-arm64`、`darwin-x64`，Windows 就绪后再加 Windows 的包），在插件索引里登记。网页界面和清单在各平台通用，只有 Rust 可执行文件按平台编译。
- 构建阶段固定依赖并签名，规则沿用[LSP 插件构建与资源归属](2026-09-30-lsp-plugin-build-and-distribution.md)。安装目录只读，运行状态写进平台存储。

### 四、主仓库要新增的通用能力

每一项都先写进契约、Rust Core 和测试样例，再由 macOS 宿主实现；Windows 宿主（#1424）按同一份契约实现。

1. **插件后端（`backend` 1，已在契约中实现）。** 清单的 `backend` 字段只含 `serverProcess` 的启动字段，需要 `backend.launch` 权限和一个网页工具窗。设计取舍：
   - **每个插件一个进程，宿主全局，不按工作区划分。** 数据库连接属于用户而不是项目，按工作区起多份进程只会重复连接池；因此后端不能使用 `${workspaceStateDir}`，状态写在 `${stateDir}`，宿主以 `${stateDir}` 作为根目录和工作目录启动它。
   - **按需启动、随插件结束。** 本插件网页第一次调用 `functions.*` 时启动；插件停用、更新、卸载或宿主退出时结束。
   - **授权就是安装审查。** 后端在安装审查中以 `packagedBackend` 等条目列出，调用时不再按工作区弹同意框；带 `instance` 的构建 provider 调用仍沿用原来的同意规则。
   - **不承担领域契约。** 后端只回答插件函数，不回答 `lithe/build/*` 或 VCS 请求，避免再次“伪装成构建系统”。
   - 网页桥接 `functions.list` / `functions.invoke` 省略 `instance` 即调用本插件后端，复用现有[插件函数协议](2026-10-20-plugin-function-contract.md)的注册、调用、进度、取消和超时规则。
2. **宿主凭据存储（插件函数协议 v2，已在契约中实现）。** v2 是第一个提供宿主服务的协议版本：`lithe/host/credentials/{get,set,delete}`，需要 `credentials.store` 权限（没有后端时声明即无效）。Core 在宿主看到请求前校验协议版本、授权和参数（key 只允许 `[A-Za-z0-9._:-]` 且不超过 128 字节，secret 不超过 16 KiB，拒绝未知字段以便后续版本扩展），通过 `hostRequest` 事件交给宿主，宿主用 `lsp.hostResponse` 应答；每个会话最多 16 个未应答请求。macOS 使用 Keychain，按插件 ID 划分命名空间；插件读不到别的插件或宿主自身的凭据。生命周期：停用和更新时保留，卸载时与 `${stateDir}` 一起删除。
3. **Agent 工具经由 `lithe` MCP（后续）。** 不新增“插件声明 MCP 服务”的契约，也不保留独立的 `lithe-db-mcp` 进程。之后由插件以插件函数的形式提供 Agent 工具，IDE 宿主把它们登记进现有 `lithe` MCP 的能力目录，沿用其项目授权；插件停用时工具随之消失。这一项在数据库插件上线后单独设计，不阻塞第 1 到第 5 期。
4. **按平台的可执行文件：不改契约。** 每个平台单独出下载包，可执行文件放在包内固定路径（例如 `bin/backend`），macOS 包可以是 universal 二进制。`${arch}` 本来就不能用于 `packaged` 路径，这样也不需要。Windows 的 `.exe` 等 Windows 宿主就绪时再定。
5. **Rust 后端 SDK。** 在 `lithe-plugin-docs` 中新增 `sdk/rust`，实现插件函数协议和宿主能力，并补端到端样例，和 Node、Java SDK 对齐。

### 五、规则只保留一份

- SQL 分析、语句拆分、标识符引用、DDL 生成和危险语句判定，全部只在插件的 Rust 后端里实现。界面要不要弹出确认框、执行时要不要拦截，都使用同一个分析结果。
- 插件仓库维护数据库专属的黄金样例。必须覆盖：换行或制表符分隔的 `WHERE`、开头的行注释和块注释、`WITH … DELETE`、多语句、无法识别的语句。
- 主仓库只维护通用能力的样例（`fixtures/backend.plugin.json`、`function-protocol.json` 的 `hostRequests`），不再维护数据库样例。

### 六、老用户迁移

- 迁移由宿主的过渡垫片 `MacDatabasePluginMigration` 完成。它挂在插件后端的启动路径上（`MacPluginBackendSessions` 的 `prepareState`），在数据库插件后端第一次启动、读取状态之前运行，所以插件永远不会先看到空状态。
- 迁移内容：偏好里的连接（`database.profiles.v1`）、文件夹（`database.connection-folders.v1`）和 SQL 历史（`database.sql-history.v1`）写进插件的 `${stateDir}`（`connections.json`、`sql-history.json`）；“永久”密码从旧 Keychain 服务移到插件凭据（key 为 `connection:<id>:password`）。旧的 `group` 字段变成顶层文件夹；历史只保留属于现存连接的最近 100 条，时间从 2001 年起算的秒换成 1970 年起算的毫秒。“直到重启”的密码本来就不落盘，不迁移。
- 顺序有讲究：先迁密码，再写历史，最后写 `connections.json`，然后才写迁移标记。这样任何一步失败，下次启动都会重试；`connections.json` 的存在表示插件已有自己的状态，之后永远不会被覆盖。迁不动的密码只记日志（不含密码本身），对应连接改为重新询问。
- 旧数据原样保留，旧版 Lithe 仍能读到。备份计划和恢复点没有迁移，因为旧模块里没有任何界面能列出或使用它们。
- 升级后，保存过连接、又没装插件的用户会看到一次通知“数据库已改为插件……”，带“打开插件市场”按钮（`DatabasePluginTransition`、`AppModel+DatabasePlugin`）。不自动在后台下载。通知按钮是通用能力：带动作的工作台通知会一直保留到用户处理。
- 垫片同时知道旧模块和插件的存储格式，这是有意为之的过渡代码；等所有受支持的 Lithe 版本都不再内置数据库模块后删除。

### 七、Windows

- 功能矩阵中 Windows 的数据库能力为 `missing`；`.db`、`.sqlite`、`.duckdb` 文件按普通文件打开。
- **暂不适配：** 这次改造不为 Windows 做任何插件侧适配，也不要求 #1424 现在对齐。等 Windows 插件宿主和插件市场改造完成后，再按当时的宿主能力小幅调整插件逻辑，补 Windows 构建、WebView2 回归测试和发布。
- 原有约 9400 行 Windows 数据库前端没有迁移，已随主仓库的数据库代码一起删除。暂不支持 DuckDB。

### 八、分期

| 期 | 内容 | 依赖 |
| --- | --- | --- |
| 1 | Windows 矩阵、`.db` 拦截、README 修正；修复 `WHERE` 误判，让 sidecar 与界面使用一致的词法判断，并让 macOS 处理 `confirmation_required` | 无 |
| 2 | 契约：插件后端、函数协议 v2 凭据宿主服务；Rust Core 校验与样例 | 无 |
| 3 | macOS 宿主实现第 2 期能力；`lithe-plugin-docs` 新增 Rust SDK | 第 2 期 |
| 4 | 新建 `lithe-plugin-database`：Rust 后端、网页界面、样例；先在 macOS 上以本地开发包验证 | 第 3 期 |
| 5 | macOS 发布插件，加入迁移提示，从主仓库删除数据库代码 | 第 4 期 |
| 6 | Windows 插件宿主和插件市场就绪后，按当时的宿主能力小幅调整插件，补 Windows 构建后发布 | Windows 插件市场 |

第 1 到第 5 期不需要等待 Windows，已在同一个 PR（#1470）中分步提交。第 6 期只做小幅调整和 Windows 构建，插件本体不重写。

### 九、远程开发

第一版数据库后端只在本机运行，连接从本机发起；需要访问远端网络中的数据库时，使用连接自带的 SSH 隧道。是否让后端随远程开发会话运行在远端，等远程开发的插件运行模型确定后再评估。

### 正确做法

- 新增“执行前检查是否含 DROP”：在插件后端的 SQL 分析中加规则和黄金样例，网页界面根据返回结果显示提示。两端自动一致。
- 新增一种数据库：只改插件后端和样例。主仓库不改一行代码。

### 不要这样做

- 在主仓库的 Swift 或 TS 中，为数据库再写判断逻辑或专属界面。
- 为了让数据库插件通过校验，把它声明成构建系统，或者造一个空语言。
- 让插件把密码写进自己的状态文件，或者写进插件安装目录。
- Windows 宿主为数据库插件单独做一套桥接方法。

## 考虑过的备选方案

### 界面留在宿主，两端各画一套原生界面，驱动做成插件

它最吸引人的地方是 macOS 保持 SwiftUI 原生体验，宿主侧改动小。不采用，因为主仓库仍要保留数据库专属界面，两端还是各写一套；“代码移出主仓库、双端一份”的目标达不到。

### 宿主提供通用的表格、SQL 编辑器组件，插件只提供数据

它最吸引人的地方是两端都能保持原生控件，组件也能给其他插件复用。暂不采用，因为两端都要实现带编辑的数据表格和 SQL 编辑器这类重组件，契约面很大，会拖慢数据库上线。以后可以先从数据库树这类简单结构开始，逐步改成宿主原生渲染。

### 做成社区插件，不要求 Lithe 签名

它最吸引人的地方是发布流程最简单，和现有 7 个社区插件完全一样。不采用，因为插件会经手用户的数据库密码。不需要 Lithe 签名的包可以被替换或冒充，信任边界不够。

### 只把两个程序改成按需下载

它最吸引人的地方是最快就能减小体积。不采用，因为它不解决规则多份和双端不一致的问题，Windows 也用不上，迟早要返工。

## 后果

- `Lithe.app` 不再包含 `lithe-db-sidecar`、`lithe-db-mcp`、数据库图标和数据库界面代码；主仓库删除了 `LitheDatabaseModule`、`Views/Database/`、两个 Rust crate、Windows 的 `features/database/`、数据库 CI 工作流与分流、打包脚本中的数据库部分和对应测试。
- **发布顺序是硬约束：** 主程序删除数据库后，老用户只能从插件找回功能。所以插件的第一个版本必须先在插件仓库发布，并在 `Plugins/marketplace/index.json` 登记，之后才能发布不含数据库的 Lithe。
- **签名私钥：** 私钥放在插件仓库 `release` 环境的受保护 secret 中，只有 `v*` 标签触发并经审批的发布工作流能读取，PR 构建接触不到。泄露面因此扩大到插件仓库的发布流程，需要维护者审批来兜底。
- **网页界面体验：** macOS 上不再是原生 SwiftUI。插件使用宿主注入的主题变量和语言上下文贴近宿主风格；数据表格和 SQL 编辑器由插件自带，包体积和性能需要随版本实测。
- **Windows 暂时没有数据库功能：** 第 6 期依赖 Windows 插件宿主和插件市场；在此之前 Windows 用户看不到数据库入口（以前的入口本来就不能用）。
- Agent 用的数据库工具暂时没有。以后由插件以插件函数提供，登记进现有 `lithe` MCP，不再单独起 MCP 进程。

## 验证

- `./scripts/test-macos.sh --filter "MacDatabasePluginMigrationTests|MacPluginBackendSessionsTests|WorkbenchNotificationTests|PluginManagerTests"`：迁移的内容、格式、只执行一次、不覆盖插件自有状态、密码迁移失败的处理；迁移先于后端启动；带动作的通知和一次性安装提示；目录中的官方插件条目。
- `./scripts/verify-module-boundaries.sh` 与 `./scripts/verify-shared-contracts.sh`：内置模块列表和共享模块样例中不再有数据库模块。
- `bash scripts/test-classify-ci-changes.sh` 与 `node --test scripts/ci-workflow-gates.test.mjs`：CI 分流不再有数据库通道。
- `./scripts/verify-runtime-bundle-immutability.sh`：运行时不向发行目录写入。
- 插件仓库的 `node scripts/e2e.mjs`：用 Lithe 的 Rust Core 启动打包好的插件后端，回答凭据请求，走完 SQLite 连接的全部页面函数，并确认安装包未被改写、状态目录只有 `connections.json` 和 `sql-history.json`。

## 已定决策

2026-10-24 与用户确认：

- 界面使用插件网页，不保留 SwiftUI 原生数据库界面；
- 插件放在组织仓库，主仓库不保留数据库专属代码；
- 使用带 Lithe 签名的官方身份；
- 后端为长期运行的 Rust 插件后端；
- macOS 先上线，Windows 等宿主和插件市场就绪后跟上；
- 老用户提示一键安装，不自动下载；
- 现有 Windows 数据库前端不迁移；
- 暂不支持 DuckDB；
- 签名在组织仓库 CI 中完成，私钥是插件仓库的受保护 secret；
- 远程开发第一版只在本机运行数据库后端，远端数据库通过 SSH 隧道访问；
- Windows 这次不做插件侧适配，等 Windows 插件市场就绪后再小幅调整；
- 第 1 到第 5 期在同一个 PR 中分步提交，不拆成多个小 PR。

按用户授权由实现方确定（2026-10-24）：

- 后端每个插件一个进程、宿主全局，不按工作区划分；授权由安装审查覆盖；
- 凭据停用和更新时保留，卸载时删除；
- 按平台可执行文件不改契约，各平台下载包使用固定路径；
- Agent 工具之后经由现有 `lithe` MCP 暴露，不单独起 MCP 进程；
- 网页界面全新编写（TypeScript，符合 CSP 的打包产物），参照 macOS 现有功能；
- 老用户迁移由宿主侧的过渡垫片完成，挂在插件后端启动路径上，只迁移一次。

## 适用范围

- `macos/Sources/LitheModuleAPI/Catalog/BuiltInModuleCatalog.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacDatabasePluginMigration.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginBackendSessions.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginCredentialStore.swift`
- `macos/Sources/Lithe/Application/Features/DatabasePluginTransition.swift`
- `macos/Sources/Lithe/Application/Features/PluginHostServices.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+DatabasePlugin.swift`
- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/backend.rs`
- `rust/lithe-core/src/lsp/interface/plugin_function.rs`
- `shared/platform-feature-matrix/features/`
- `Plugins/marketplace/index.json`

相关 Note：[统一 VCS 模型与 Provider 接入](../../proposed/architecture/2026-10-22-unified-vcs-provider-model.md)（同类 provider 做法）、[模块运行时抽取路线](../../proposed/architecture/2026-09-13-module-runtime-extraction-roadmap.md)（数据库被列为适合插件化）、[插件自带网页界面](2026-10-18-plugin-web-content-in-host-windows.md)、[插件市场](../feature/2026-10-12-plugin-marketplace.md)。
