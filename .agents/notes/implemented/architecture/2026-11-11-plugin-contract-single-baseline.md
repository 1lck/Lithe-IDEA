# Agent 笔记：插件契约从统一基线 0 开始

状态：已实现

## 先说结论

插件契约改为 `Lithe-core-rust/shared/plugins/contract/v1/`：`pluginAPIVersion` 只有 `0`，每个能力（Capability，清单里一个有自己段落、可以独立演进的部分）也都从版本 `0` 开始。版本 0 就是这个能力当前完整的功能，没有“低版本只能用一部分”的分支。

以后给某个能力加功能，只给这个能力加版本 `1`；清单段、宿主能力表和运行期协议跟着同一个数字一起变。对日常开发的直接影响：写插件只需要按契约写一份清单；改 Core 时不要再按版本号给同一个能力写多条分支。

## 问题

- **版本号叠得太多。** 原来有三条互不相关的版本线：整份清单的级别、每个能力的版本、每个运行期协议在 LSP `initialize` 里协商的版本。同一个功能（例如构建 Provider 的运行准备）要同时看清单版本和协议版本才能判断能不能用，Core 里到处是 `version < N` 分支。
- **有的“能力”没有自己的清单段。** 启动进程的规则（`serverProcess`）和可执行文件候选的写法（`executableResolution`）只是改写别的段，于是出现“声明了语言服务器却没声明启动进程”这种无意义的组合，以及“某版本必须配合某级别”的交叉约束。
- **宿主只能整版声明。** 能力版本是线性叠加的，宿主想支持第 11 版里的一个功能，就得先实现第 3 到第 10 版。正在迁移的 Viva 桌面端因此只能声明 `buildProviders {1,2}`，用到高版本的插件一律装不上。

## 决策

### 1. 统一基线

- `pluginAPIVersion` 只接受 `0`；`requires` 必填，并且必须正好列出清单用到的能力，每个值都是 `0`。
- 市场索引的 `schemaVersion`、原生界面文档的 `schemaVersion` 也是 `0`。
- 版本 0 的含义只有一种：该能力当前契约里的全部内容。Core 不保留任何按旧版本号判断的分支。

### 2. 一个能力对应一个清单段

`serverProcess` 和 `executableResolution` 不再是能力，并入基础契约：任何会启动进程的段都按同一套启动规则（打包程序、打包运行时、`requiresTools`、`{kind: "tool"}`、后端给出的启动命令），所有可执行文件候选都按同一套解析规则（设置来源、`id`、`priority`、`insertBefore`、`insertAfter`、严格选择）。清单在 `requires` 里写这两个名字时，按未知能力拒绝。

剩下的每个能力都只对应一个清单段，能力表、清单段、运行期协议和宿主承诺的对照表写在契约 README 里。

### 3. 协议版本就是能力版本

运行期协议不再单独编版本，版本号取所属能力的版本：

| 协议 | 所属能力 |
| --- | --- |
| `litheBuild` | `buildProviders` |
| `litheFunctions` | `backend` |
| `litheVcs` | `vcsProviders` |
| 工具链 Provider 协议 | `toolchainProviders` |
| 快捷键导入 Provider 协议 | `keymapImportProviders` |
| `litheLogging` | 基础契约（`pluginAPIVersion`） |

宿主仍在 `initialize` 里发 `{"versions": [...]}`，但列表来自所属能力在 Core 中支持的版本（`capabilities::versions`），不再有单独的常量。以后给 `buildProviders` 加版本 1，清单写法和 `litheBuild` 消息会一起变。

### 4. 宿主声明一个能力意味着什么

宿主在 `hostCapabilities` 里声明某个能力版本，承诺两件事：接受这个版本的所有清单写法，能讲它的协议。

- 插件**对外提供**的功能（构建 Provider 的测试、运行准备，只属于命令的界面入口等），宿主可以暂时不展示。不展示时不放按钮、菜单或窗口，而不是装上后点了才报错。插件不能依赖这些功能一定会被调用。
- 插件**需要宿主提供**的服务（宿主方法、通知），在运行期通过 `getCapabilities` 和权限查询，不靠能力表。

正确做法：Viva 声明 `buildProviders {0}`，暂不展示测试和运行准备，并在 `desktop/internal/pluginhost/pluginhost.go` 的 `Declared()` 注释里逐项列出没展示的部分。

不要这样做：宿主声明了 `buildProviders {0}`，却在插件调用 `run/start` 之类的宿主方法时才发现没注册而报错；宿主方法必须通过 `getCapabilities` 提前暴露是否可用。

## 考虑过的备选方案

- **保留旧版本号，只删低版本。** 能少改一些插件，但版本号从 11、4、3 这些数字起步，读者必须知道历史才能理解为什么从这里开始，并且协议和清单的版本线仍然各走各的。被否。
- **在 Core 里把 0 翻译回旧的最高版本号。** 改动最小，但会把“0 等于 11”这种对照永久留在代码里，新插件作者看文档也会遇到两套编号。被否。
- **把大能力拆成很多小能力（例如构建测试单独一个能力）。** 能让宿主精确声明，但插件 `requires` 会变长，而且大多数拆出来的功能是插件提供的，宿主不展示也不会出错。改用第 4 条的声明规则解决，被否。
- **去掉 `requires`，由 Core 根据清单段推断。** 现在每个能力都只有版本 0，推断确实可行；但以后有了版本 1，Core 无法从段落是否出现判断插件按哪一版编写，所以保留显式声明。被否。

## 后果

- 现有插件全部需要按基线 0 重新适配：`pluginAPIVersion` 改 `0`，`requires` 值改 `0`，去掉 `serverProcess` 和 `executableResolution`，协议协商回复版本 `0`。
- 插件 SDK（Node、Java、Rust）只协商版本 0。
- Viva 的能力表只有 `{0}` 一种取值；没有展示的子功能必须写进 `Declared()` 注释，并在实现时从注释里删除。
- 以后新增能力版本时，必须同时更新：`capabilities.rs` 的支持表、契约 README 的对照表、清单 schema、对应协议说明和宿主能力表。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core`（Core 仓库）覆盖清单校验、市场索引、协议协商和契约 fixture。
- `node shared/plugins/scripts/verify-docs.mjs`（Core 仓库）检查每份 schema 的 `$id` 和插件文档的相对链接。
- `scripts/desktop/desktop-go.sh test ./internal/pluginhost/... ./internal/core/... ./internal/marketplace/...` 用固定版本的 Core 及其契约 fixture 验证 Viva 能力表。

## 适用范围

适用于声明式插件清单、插件市场索引、原生界面文档、插件运行期协议协商，以及宿主的 `hostCapabilities` 表。不适用于插件自己给导出函数编的契约版本（`pluginFunctions` 里的 `contractVersion`），也不适用于 LSP 文档版本号、构建选项和工具链存储文件的格式版本。
