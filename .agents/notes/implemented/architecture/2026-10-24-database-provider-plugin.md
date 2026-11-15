# Agent 笔记：数据库拆成双端共用的独立插件

状态：已实现

> 2026-11-08 Viva 迁移：数据库插件仍由组织仓库和市场提供，但本文的旧客户端宿主、
> 安装、网页桥和数据迁移验收不能证明 Viva 已支持它。Viva 的可信安装及完整插件宿主
> 尚未接通；迁移时需重新验证插件实际支持的平台和功能，不得把市场索引存在视为可用。

## 先说结论

数据库连接功能已经从 Lithe 主仓库和主安装包中移出，成为组织仓库 `Lithe-IDEA/lithe-plugin-database` 中的社区插件 `io.github.lithe-idea.database`，在 Lithe Store 上架。只装 IDE 时没有任何数据库入口；从插件市场安装后才能使用。插件的界面是包内网页，后端用 Rust 编写，macOS 和 Windows 将共用同一份代码。

主仓库只保留通用的插件能力：不依附构建系统的插件后端、宿主凭据存储，以及一个过渡垫片——把旧版内置模块保存的连接、历史和密码迁入插件，并提示老用户安装。macOS 先上线；Windows 等插件宿主和插件市场就绪后，补一轮编译、适配和测试即可使用，插件本体不重写。

开发时记住一条：主仓库里不再为“数据库”写任何专属代码。SQL 判定、界面、驱动都只改插件仓库；主仓库只改通用的插件能力。

## 问题

### 现状：逻辑重复，Windows 没有可用的数据库功能

数据库的驱动、协议、领域规则和界面在旧 macOS 客户端与旧 Windows 前端中各写一份，互不共享。主程序因此随包携带两个数据库后端程序（约 9 MB）以及数千行只属于数据库的界面代码。Windows 前端调用的数据库命令从来没有对应的后端，用户打开数据库文件时只会遇到失败。同一条规则也出现了不一致：例如 SQL 的危险判定在界面、sidecar 和 MCP 中各有一套，换行分隔的 `WHERE` 会让界面与后端给出不同结论，界面也不处理后端返回的确认请求。

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

插件仓库只依赖公开契约：Core 仓库 `shared/plugins/contract/v1/` 的契约加官方 SDK（同在 Core 仓库的 `shared/plugins/sdk/`），和 Cargo、SVN 插件的做法相同。主仓库不再按“数据库”写任何分支。

### 三、插件身份与分发

- 先作为社区插件发布：ID 为 `io.github.lithe-idea.database`，`vendor.signatureRequirement` 为 `"none"`，和 Cargo、SVN 等 7 个插件一样在 Lithe Store 上架。宿主按索引固定的 SHA-256 校验下载包，安装确认列出权限和后端程序，加载时重新核对安装文件的内容摘要。
- 为什么暂不做官方签名：官方签名的完整路径（`lithe-official-plugins-v2` 公钥、`release-official-plugins.yml`、官方索引 `Plugins/marketplace/index.json`）从未发布过任何插件。v2 私钥在原组织主仓库的维护者手里，该仓库已改名归档，官方索引地址也还指向它。另配一把密钥是信任根变更，需要单独决定，所以先不走这条路。
- 插件仓库的发布工作流在 `v*` 标签上测试、打包 universal 后端、跑端到端检查，然后发布 GitHub Release（zip 与 SHA-256）；上架和升级是向 Lithe Store 提 PR 登记下载地址和 SHA-256。
- 网页界面和清单在各平台通用，只有 Rust 可执行文件按平台编译；macOS 发一个 universal 包，同时登记 `darwin-arm64` 和 `darwin-x64`，Windows 就绪后再加 Windows 的包。
- 构建阶段固定依赖，规则沿用[LSP 插件构建与资源归属](2026-09-30-lsp-plugin-build-and-distribution.md)。安装目录只读，运行状态写进平台存储。

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
5. **Rust 后端 SDK。** 新增 `sdk/rust`，实现插件函数协议和宿主能力，并补端到端样例，和 Node、Java SDK 对齐。它当时放在 lithe-plugin-docs，现在和另外两个 SDK 一起在 Core 仓库的 `shared/plugins/sdk/rust`。

### 五、规则只保留一份

- SQL 分析、语句拆分、标识符引用、DDL 生成和危险语句判定，全部只在插件的 Rust 后端里实现。界面要不要弹出确认框、执行时要不要拦截，都使用同一个分析结果。
- 插件仓库维护数据库专属的黄金样例。必须覆盖：换行或制表符分隔的 `WHERE`、开头的行注释和块注释、`WITH … DELETE`、多语句、无法识别的语句。
- 主仓库只维护通用能力的样例（`fixtures/backend/backend.plugin.json`、`function-protocol.json` 的 `hostRequests`），不再维护数据库样例。

### 六、老用户迁移

### 七、Windows

- 功能矩阵中 Windows 的数据库能力为 `missing`；`.db`、`.sqlite`、`.duckdb` 文件按普通文件打开。
- **暂不适配：** 这次改造不为 Windows 做任何插件侧适配，也不要求 #1424 现在对齐。等 Windows 插件宿主和插件市场改造完成后，再按当时的宿主能力小幅调整插件逻辑，补 Windows 构建、WebView2 回归测试和发布。
- 原有约 9400 行 Windows 数据库前端没有迁移，已随主仓库的数据库代码一起删除。暂不支持 DuckDB。

### 八、分期

| 期 | 内容 | 依赖 |
| --- | --- | --- |
| 1 | Windows 矩阵、`.db` 拦截、README 修正；修复 `WHERE` 误判，让 sidecar 与界面使用一致的词法判断，并让 macOS 处理 `confirmation_required` | 无 |
| 2 | 契约：插件后端、函数协议 v2 凭据宿主服务；Rust Core 校验与样例 | 无 |
| 3 | macOS 宿主实现第 2 期能力；新增 Rust SDK（`sdk/rust`） | 第 2 期 |
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

- 为了让数据库插件通过校验，把它声明成构建系统，或者造一个空语言。
- 让插件把密码写进自己的状态文件，或者写进插件安装目录。
- Windows 宿主为数据库插件单独做一套桥接方法。

## 考虑过的备选方案

### 界面留在宿主，两端各画一套原生界面，驱动做成插件

### 宿主提供通用的表格、SQL 编辑器组件，插件只提供数据

它最吸引人的地方是两端都能保持原生控件，组件也能给其他插件复用。暂不采用，因为两端都要实现带编辑的数据表格和 SQL 编辑器这类重组件，契约面很大，会拖慢数据库上线。以后可以先从数据库树这类简单结构开始，逐步改成宿主原生渲染。

### 带 Lithe 发布者签名的官方插件

它最吸引人的地方是信任最强：只有带 Lithe 签名的包才能用这个 ID，迁移密码时不必另外核对来源。最初就是这样设计的。暂不采用，因为官方签名路线从未真正发布过插件，v2 私钥不在当前维护者手中，官方索引也指向已归档的仓库；要用就得另配一把密钥并改信任表，这是信任根变更。改为社区插件后，冒充风险由“迁移只认 Lithe Store 来源和仓库地址”来堵。以后官方签名路线恢复时，可以再把插件迁成官方身份（参照 Go、PHP 的 `migratedToCommunity` 反向处理）。

### 只把两个程序改成按需下载

它最吸引人的地方是最快就能减小体积。不采用，因为它不解决规则多份和双端不一致的问题，Windows 也用不上，迟早要返工。

## 后果

- **发布顺序是硬约束：** 主程序删除数据库后，老用户只能从插件找回功能。所以插件的第一个版本必须先在插件仓库发布，并在 Lithe Store 的 `lithe-plugin-index.json` 登记，之后才能发布不含数据库的 Lithe。
- **信任边界：** 不带签名，信任来自 Lithe Store 的收录审查和索引固定的 SHA-256。如果用户移除了 Lithe Store 来源，或只从磁盘安装，旧连接和密码就不会迁入（旧数据仍保留）。Lithe Store 收录这个插件的更新时，维护者要像审查代码一样审查，因为它会拿到迁移过来的密码。
- **Windows 暂时没有数据库功能：** 第 6 期依赖 Windows 插件宿主和插件市场；在此之前 Windows 用户看不到数据库入口（以前的入口本来就不能用）。
- Agent 用的数据库工具暂时没有。以后由插件以插件函数提供，登记进现有 `lithe` MCP，不再单独起 MCP 进程。

## 验证

- 插件仓库的 `node scripts/e2e.mjs`：用 Core 启动打包好的插件后端，回答凭据请求，走完 SQLite 连接的全部页面函数，并确认安装包未被改写。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：运行时不向发行目录写入。
- `./scripts/agent-notes/verify-agent-notes.sh`。

## 已定决策

2026-10-24 与用户确认：

- 插件放在组织仓库，主仓库不保留数据库专属代码；
- 后端为长期运行的 Rust 插件后端；
- macOS 先上线，Windows 等宿主和插件市场就绪后跟上；
- 老用户提示一键安装，不自动下载；
- 现有 Windows 数据库前端不迁移；
- 暂不支持 DuckDB；
- 远程开发第一版只在本机运行数据库后端，远端数据库通过 SSH 隧道访问；
- Windows 这次不做插件侧适配，等 Windows 插件市场就绪后再小幅调整；
- 第 1 到第 5 期在同一个 PR 中分步提交，不拆成多个小 PR；
- 官方签名路线从未发布过插件、v2 私钥拿不到，因此数据库插件先当作社区插件，在 Lithe Store 上架，不作为官方插件。

按用户授权由实现方确定（2026-10-24）：

- 后端每个插件一个进程、宿主全局，不按工作区划分；授权由安装审查覆盖；
- 凭据停用和更新时保留，卸载时删除；
- 按平台可执行文件不改契约，各平台下载包使用固定路径；
- Agent 工具之后经由现有 `lithe` MCP 暴露，不单独起 MCP 进程；
- 网页界面全新编写（TypeScript，符合 CSP 的打包产物），参照 macOS 现有功能；
- 老用户迁移由宿主侧的过渡垫片完成，挂在插件后端启动路径上，只迁移一次；
- 社区插件下，迁移只认 Lithe Store 来源和插件仓库地址，不认插件 ID。

## 适用范围

- `desktop/internal/marketplace/`

- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/`
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/backend.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/backend.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/plugin_function.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/plugin_function.rs)
- `shared/platform-feature-matrix/features/`
