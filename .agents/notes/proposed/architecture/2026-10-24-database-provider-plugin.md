# Agent 笔记：数据库拆成双端共用的独立插件

状态：提议中

## 先说结论

数据库连接功能将从 Lithe 主仓库和主安装包中移出，做成一个独立仓库的官方插件。用户只装 IDE 时，看不到数据库入口；从插件市场安装后才能使用。插件的界面是包内网页，后端用 Rust 编写，macOS 和 Windows 共用同一份代码。

主仓库不再保留任何数据库专属代码，只提供通用的插件能力：不依附构建系统的插件后端、宿主凭据存储、插件提供的 MCP 服务，以及按平台区分的可执行文件。macOS 先上线；Windows 等插件宿主和插件市场就绪后，补一轮编译、适配和测试即可使用，插件本体不重写。

这次评估还发现，数据库模块已经偏离“两套界面、一个核心”：同一条 SQL 安全规则写了三份并且不一致，Windows 界面从导入起就没有后端。插件化之后，这些规则只在插件后端保留一份。

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

- **网页界面只能操作构建系统。** 网页桥接对象（`window.lithe`）只能操作本插件声明的构建系统；插件函数在 macOS 上也只由构建 provider 的会话提供。数据库插件只能伪装成构建系统，违反[公共扩展契约](2026-10-13-public-extension-contract-and-provider-api.md)的“不要伪造声明”。
- **插件拿不到宿主的凭据存储。** 插件调用宿主服务（`lithe/host/*`）在协议 v1 中全部被拒绝，没有地方安全地保存密码。
- **Agent 找不到插件提供的 MCP 服务。** Agent 现在直接到 app 里查找 `lithe-db-mcp`，不会去已安装的插件里找。
- **跨平台可执行文件路径未定义。** `packaged` 启动方式只有一个固定路径，没有规定 Windows 可执行文件（`.exe`）怎么声明。
- **Windows 还没有声明式插件宿主和插件市场。** 声明式插件宿主正在 #1424 中开发；插件市场目前只有 macOS 版。

## 提案

### 一、最终用户看到什么

- 只装 Lithe 时，没有数据库工具窗口、菜单或 Services 条目。
- 在插件市场安装“数据库”插件后，数据库工具窗口出现：连接树、SQL 控制台、数据表格、结构对比，以及 Redis 和 Nacos 视图，都在宿主管理的窗口里，以插件网页显示。
- 停用或卸载后，入口消失，插件拥有的进程全部结束。
- macOS 先提供；Windows 在插件宿主和插件市场就绪后提供，使用同一个插件版本。

### 二、代码归属

| 位置 | 内容 |
| --- | --- |
| 组织仓库 `Lithe-IDEA/lithe-plugin-database`（新建） | Rust 后端（从 `lithe-db-sidecar` 演进）、MCP 服务（从 `lithe-db-mcp` 演进）、网页界面、`plugin.json`、数据库专属的测试样例和兼容性测试 |
| 主仓库 | 只保留通用能力：契约、Rust Core 校验、两端宿主实现、Rust 后端 SDK 的契约测试 |
| 主仓库最终删除 | `macos/Sources/LitheDatabaseModule/`、`macos/Sources/Lithe/Views/Database/`、`rust/lithe-db-sidecar/`、`rust/lithe-db-mcp/`、`windows/tauri/src/features/database/` 及打包脚本中的数据库部分 |

插件仓库只依赖公开契约：`lithe-plugin-docs` 中锁定的契约副本加官方 SDK，和 Cargo、SVN 插件的做法相同。主仓库不再按“数据库”写任何分支。

### 三、插件身份与分发

- 使用官方 ID（`dev.lithe.plugin.database`），带 Lithe 发布者签名。原因是插件会经手用户的数据库密码，不能使用不需要 Lithe 签名的社区插件身份。
- 签名在组织仓库的发布 CI 中完成：发布者私钥只作为插件仓库的 CI secret 存在，插件自己出包、签名、登记索引；主仓库的发布流程不参与插件出包。
- 每个版本按平台发布下载包（`darwin-arm64`、`darwin-x64`，Windows 就绪后再加 Windows 的包），在插件索引里登记。网页界面和清单在各平台通用，只有 Rust 可执行文件按平台编译。
- 构建阶段固定依赖并签名，规则沿用[LSP 插件构建与资源归属](../../implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md)。安装目录只读，运行状态写进平台存储。

### 四、主仓库要新增的通用能力

每一项都先写进契约、Rust Core 和测试样例，再由 macOS 宿主实现；Windows 宿主（#1424）按同一份契约实现。

1. **插件后端（不依附构建系统）。** 新增一项能力：插件声明一个归属于自己的后端进程，宿主在插件的界面打开时按需启动它，会话按插件和工作区划分。网页桥接新增调用本插件后端函数的方法，复用现有[插件函数协议](../../implemented/architecture/2026-10-20-plugin-function-contract.md)的注册、调用、进度、取消和超时规则。网页原生面板的数据源也可以改为指向这个后端，不再强制要求 `buildSystemID`。
2. **宿主凭据存储。** 在插件函数协议的新版本中加入第一个宿主能力：插件私有的凭据读写。macOS 使用 Keychain，Windows 使用系统凭据管理器。插件需要声明专门的权限，安装审查会列出这项权限。凭据只按插件 ID 隔离，插件读不到别的插件或宿主自身的凭据。
3. **插件提供的 MCP 服务。** 插件声明 MCP 服务的入口；Agent 从已启用的插件中发现它。插件停用后，这些工具随之消失。
4. **按平台的可执行文件。** 契约规定 `packaged` 在不同平台上怎么定位可执行文件，例如允许按平台给出路径，或规定 Windows 自动补 `.exe` 后缀。具体方式在契约 PR 中确定。
5. **Rust 后端 SDK。** 在 `lithe-plugin-docs` 中新增 `sdk/rust`，实现插件函数协议和宿主能力，并补端到端样例，和 Node、Java SDK 对齐。

### 五、规则只保留一份

- SQL 分析、语句拆分、标识符引用、DDL 生成和危险语句判定，全部只在插件的 Rust 后端里实现。界面要不要弹出确认框、执行时要不要拦截，都使用同一个分析结果。
- 插件仓库维护数据库专属的黄金样例。必须覆盖：换行或制表符分隔的 `WHERE`、开头的行注释和块注释、`WITH … DELETE`、多语句、无法识别的语句。
- 主仓库只维护通用能力的样例（插件后端、凭据、MCP 声明），不再维护数据库样例。

### 六、老用户迁移

- 现有 macOS 用户的连接配置在宿主的偏好存储里，密码在 Keychain 里。插件首次启用时，宿主把这些数据迁入插件私有的存储和凭据范围，只迁移一次，并保留迁移记录。
- 升级到不再内置数据库的 Lithe 版本后，如果检测到已保存的连接，宿主提示一次：“数据库已改为插件，点击安装”。不自动在后台下载。
- 迁移只在插件版本和主程序版本都就绪后进行；在此之前，不从主包删除数据库功能。

### 七、Windows

- **现在就做：** 功能矩阵把 Windows 的数据库能力改为 `missing`；停止把 `.db`、`.sqlite`、`.duckdb` 文件交给数据库查看器；README 注明数据库目前只支持 macOS。
- **暂不适配：** 这次改造不为 Windows 做任何插件侧适配，也不要求 #1424 现在对齐。等 Windows 插件宿主和插件市场改造完成后，再按当时的宿主能力小幅调整插件逻辑，补 Windows 构建、WebView2 回归测试和发布。
- 现有 9400 行 Windows 数据库前端不迁移，跟随主仓库的数据库代码一起删除。暂不支持 DuckDB。

### 八、分期

| 期 | 内容 | 依赖 |
| --- | --- | --- |
| 1 | Windows 矩阵、`.db` 拦截、README 修正；修复 `WHERE` 误判，让 sidecar 与界面使用一致的词法判断，并让 macOS 处理 `confirmation_required` | 无 |
| 2 | 契约：插件后端、凭据宿主能力、MCP 声明、按平台可执行文件；Rust Core 校验与样例 | 无 |
| 3 | macOS 宿主实现第 2 期能力；`lithe-plugin-docs` 新增 Rust SDK | 第 2 期 |
| 4 | 新建 `lithe-plugin-database`：Rust 后端、MCP、网页界面、样例；先在 macOS 上以本地开发包验证 | 第 3 期 |
| 5 | macOS 发布插件，加入迁移提示，从主仓库删除数据库代码 | 第 4 期 |
| 6 | Windows 插件宿主和插件市场就绪后，按当时的宿主能力小幅调整插件，补 Windows 构建后发布 | Windows 插件市场 |

第 1 到第 5 期不需要等待 Windows，全部在同一个 PR 中分步提交。第 6 期只做小幅调整和 Windows 构建，插件本体不重写。

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

## 验收标准

- 只安装 Lithe 时没有任何数据库入口；`Lithe.app` 中不含数据库程序和界面代码；主仓库中搜不到数据库专属模块。
- 从插件市场安装后，现有连接、查询、编辑、导入导出、结构对比、Redis 和 Nacos 功能可用。老用户的连接和密码完成迁移。
- 停用或卸载后，入口消失，插件进程结束；重新安装后，凭据和连接仍在。
- 插件仓库中只有一份 SQL 危险判定。换行写的 `DELETE … WHERE` 可以直接执行，不带 `WHERE` 的删除会弹出确认框。
- 插件后端、凭据和 MCP 声明的通用样例在 Rust Core 测试中通过；Windows 宿主实现后，同一批样例在 Windows 上也通过。
- `scripts/verify-runtime-bundle-immutability.sh` 覆盖插件安装和典型数据库工作流，发行目录哈希不变。
- Windows 宿主就绪后，同一插件版本只增加 Windows 下载包即可安装使用。

## 风险

- **Windows 进度：** 第 6 期依赖 Windows 插件宿主和插件市场。插件只依赖公开契约，届时按 Windows 宿主的实际能力调整，不预先适配。
- **网页界面体验：** macOS 上不再是原生 SwiftUI。要使用宿主注入的主题和语言上下文，尽量贴近宿主风格；数据表格和 SQL 编辑器要在插件里自带组件，包体积和性能需要实测。
- **凭据能力的安全边界：** 宿主凭据是第一项宿主能力，权限、隔离和审查必须先写进契约和样例，不能先实现后补。
- **签名私钥：** 私钥放在组织仓库 CI secret 中，泄露面扩大到插件仓库的 CI。只允许发布工作流在受保护分支和标签上读取它，PR 构建不能接触私钥。
- **升级断档：** 第 5 期必须同时具备插件、迁移和提示；任何一项没有完成，都不能从主包删除数据库。

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

## 待确认

- `packaged` 按平台定位可执行文件的具体方式，在契约提交中确定。

## 适用范围

- `rust/lithe-db-sidecar/`
- `rust/lithe-db-mcp/`
- `macos/Sources/LitheDatabaseModule/`
- `macos/Sources/Lithe/Views/Database/`
- `macos/Sources/Lithe/Platform/MacOS/Process/MacDatabaseSidecarLocator.swift`
- `macos/Sources/LitheModuleAPI/Catalog/BuiltInModuleCatalog.swift`
- `macos/Sources/LitheModuleAPI/Plugins/PluginTypes.swift`
- `windows/tauri/src/features/database/`
- `windows/tauri/src/extensions/tooling/package-database-sidecars.ts`
- `windows/tauri/src/features/file-system/controllers/file-utils.ts`
- `shared/contracts/plugins/v1/`
- `shared/platform-feature-matrix/features/`
- `scripts/package-app.sh`

相关 Note：[统一 VCS 模型与 Provider 接入](2026-10-22-unified-vcs-provider-model.md)（同类 provider 做法）、[模块运行时抽取路线](2026-09-13-module-runtime-extraction-roadmap.md)（数据库被列为适合插件化）、[插件自带网页界面](../../implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md)、[插件市场](../../implemented/feature/2026-10-12-plugin-marketplace.md)、[MySQL 连接下的多数据库树](../../implemented/feature/2026-10-22-database-multi-schema-tree.md)。
