# Agent 笔记：插件契约与开发资料只在 Rust Core

状态：已实现

## 先说结论

插件契约、插件开发指南与参考、三个官方后端 SDK（Node、Java、Rust）和 SDK 端到端测试只有一份，放在 Rust Core 仓库的 [`shared/plugins/`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins)。本仓库删除了 `shared/contracts/plugins/` 副本，原 lithe-plugin-docs 仓库的内容整体并入 Core，该仓库停止维护。

对日常开发的直接影响：

- 改契约、能力版本或插件函数协议，在 Core 的同一个 PR 里同时改代码、契约、文档、SDK，并登记协议更新记录；不再有“合并后再同步到另一个仓库”这一步。
- 本仓库的桌面端测试通过 `desktop/internal/contractfixture` 读取正在链接的 Core 检出里的 fixture，路径由 `scripts/desktop/desktop-go.sh` 导出的 `LITHE_PLUGIN_CONTRACT_DIR` 给出。直接运行 `go test` 会因为没有这个变量而报错，这是有意的。
- 契约改了以后，把 `scripts/desktop/build-desktop-core.sh` 的 `PINNED_CORE_REVISION` 升到包含该改动的 Core commit，桌面端测试就会读到新契约。

## 问题

原来同一份契约有三份：

1. 本仓库 `shared/contracts/plugins/v1/`，桌面端测试读它。
2. Rust Core 仓库 `shared/plugins/contract/v1/`，执行契约的代码和它的测试读它。
3. lithe-plugin-docs 仓库的逐字节副本，插件开发者看它，SDK 的端到端测试也用它，靠 `scripts/contract.mjs sync --revision <commit>` 在合并后手动同步。

这套安排是在 Rust Core 还在本仓库里时定的（见已归档的 `.agents/notes/archived/architecture/2026-10-23-plugin-contract-publishing.md`）。当时它写明：“如果 Rust Core 拆成独立仓库，就重新考虑契约放在哪里。”Core 现在已经是独立仓库，于是出现了这些问题：

- 执行契约的代码在 Core，但本仓库还留着一份契约，两边哪份是真源要靠约定，改动要在两个仓库各提一个 PR。
- 文档仓库的副本永远落后于 Core 一次手动同步；漏同步时，插件开发者读到的是旧行为，SDK 端到端测试验证的也是旧契约。
- SDK 和它要遵守的协议不在同一个仓库，改协议的 PR 无法在合并前用同一个提交跑三个 SDK 的示例后端。

## 决策

### 1. Core 的 `shared/plugins/` 是唯一来源

| 内容 | 位置（相对 Core 仓库根） |
| --- | --- |
| 契约 README、schema、fixture | `shared/plugins/contract/v1/` |
| 开发指南 | `shared/plugins/guides/` |
| API 总表、协议更新记录等参考页 | `shared/plugins/reference/` |
| Node、Java、Rust 后端 SDK 与示例 | `shared/plugins/sdk/` |
| SDK 端到端场景 | `shared/plugins/sdk/e2e/` |
| 文档检查与端到端入口 | `shared/plugins/scripts/verify-docs.mjs`、`shared/plugins/scripts/sdk-e2e.mjs` |

Core 的 `shared/` 下只保留 `plugins/`。本仓库和 Lithe Store 都不再保存契约、SDK 或面向插件开发者的文档；需要引用时用指向 Core `main` 的绝对 URL。

之所以放在 Core 而不是放在本仓库，原因与旧笔记相同，只是现在指向了 Core：执行契约的代码在 Core，契约和代码必须能在同一个 PR 里改、同一个提交里测。

### 2. 同一个 Core PR 完成全部登记

改 `shared/plugins/contract/v1/`、`rust/crates/core/src/plugins/capabilities.rs` 或 `rust/crates/core/src/lsp/interface/plugin_function.rs` 的 Core PR，同时完成这些事：

- 更新 [插件协议更新记录](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/reference/protocol-changelog.md)，写明合入日期、PR、修改人和改了哪个协议或 API。
- 新增宿主方法时，在 [API 总表](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/reference/api-catalog.md) 的中英方法表和更新记录的“宿主方法（按 API 编号）”索引里各加一行。
- 改后端协议时，在 Core 仓库根运行 `node shared/plugins/scripts/sdk-e2e.mjs`，三个 SDK 的示例后端对同一个提交跑通后才能合并。

### 3. 本仓库的测试读链接的 Core 检出

`scripts/desktop/desktop-go.sh` 已经知道本次链接的是哪份 Core 检出：设置了 `LITHE_CORE_RUST_DIR` 时用该目录，否则用 `build-desktop-core.sh` 按 `PINNED_CORE_REVISION` 克隆的 `.artifacts/desktop/lithe-core-rust/source`。脚本把这份检出里的 `shared/plugins/contract/v1` 导出为 `LITHE_PLUGIN_CONTRACT_DIR`，测试通过 `contractfixture.Path("<相对路径>")` 读取 fixture。

这样，测试读到的契约和链接进来的 Core 代码一定来自同一个 commit，不会出现“代码是新的、fixture 是旧的”。

### 4. SDK 从 Core 发版

SDK 发版改为在 Core 打 `sdk-node-v*`、`sdk-java-v*`、`sdk-rust-v*` 标签，由 Core 的 `plugins-release-*-sdk.yml` 工作流发布。0.4.x 及更早的版本发布于已停止维护的 lithe-plugin-docs，旧标签和旧包继续可用。

## 考虑过的备选方案

- **保留本仓库的契约副本，加一致性检查。** 能让本仓库不依赖 Core 检出就跑测试，但仍然是两份真源，每次契约改动都要在两个仓库各提一个 PR，检查只能在事后发现不一致。被否。
- **用 git submodule 把 Core 的 `shared/plugins` 挂进本仓库。** 引用的 commit 与 `PINNED_CORE_REVISION` 会变成两处需要一起升的版本号，克隆和 CI 也要多处理一层 submodule。`desktop-go.sh` 本来就会准备 Core 检出，直接复用它更简单。被否。
- **把 fixture 复制进本仓库的测试目录。** 只复制测试用到的几份 fixture，看起来改动小，但本质上仍是副本，Core 改了 fixture 而本仓库没跟上时，测试会验证旧契约并且照样通过。被否。
- **保留 lithe-plugin-docs，只把同步改成自动化。** 能保留一个面向开发者的独立仓库入口，但 SDK 和协议依然不在同一个提交里验证，自动同步还要额外的令牌、工作流和失败处理。插件开发者直接看 Core 的 `shared/plugins/` 即可，不需要克隆其他仓库。被否。

## 后果

- 本仓库桌面端测试必须通过 `scripts/desktop/desktop-go.sh` 运行；裸跑 `go test` 时 `contractfixture.Path` 会直接报出需要设置的变量。
- 升级 `PINNED_CORE_REVISION` 同时升级了桌面端测试读到的契约；Core 契约变化导致本仓库测试失败时，在升级固定版本的同一个 PR 里修宿主。
- lithe-plugin-docs 仓库需要归档，并在 README 指向 Core 的 `shared/plugins/`；这个操作对外可见，由维护者执行。
- Lithe Store 的 CI 目前用 lithe-plugin-docs 的 URL 读取 `plugin-index.schema.json` 并核对 SHA，需要改成 Core 的 URL，同样由维护者在 Lithe Store 仓库处理。
- 历史笔记、PR 和 CI 链接里出现的 lithe-plugin-docs 地址保留原样，作为历史记录；新写的引用一律指向 Core。

## 验证

- `node shared/plugins/scripts/verify-docs.mjs`（Core 仓库根）检查每份 schema 的 `$id` 和插件文档的相对链接。
- `node shared/plugins/scripts/sdk-e2e.mjs`（Core 仓库根）用当前提交的 Core 跑三个 SDK 的示例后端。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/marketplace/... ./internal/pluginweb/... ./internal/workbench/... ./internal/pluginservice/...` 用链接的 Core 检出里的契约 fixture 运行桌面端测试。

## 适用范围

- `AGENTS.md`
- `.github/pull_request_template.md`
- `desktop/internal/contractfixture/contractfixture.go`
- `scripts/desktop/desktop-go.sh`
- `scripts/desktop/build-desktop-core.sh`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins`
