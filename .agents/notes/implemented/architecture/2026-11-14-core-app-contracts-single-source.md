# Agent 笔记：应用契约与 fixture 只在 Rust Core

状态：已实现

## 先说结论

Core 命令的契约文档、schema 和 fixture 只有一份，放在 Lithe-core-rust 仓库的 `rust/contracts/` 与 `rust/fixtures/`。本仓库删除了 `shared/contracts/` 和 `shared/fixtures/` 两个目录，`shared/` 下只剩 `i18n/` 和 `platform-feature-matrix/`。插件契约早已按同样的方式只放在 Core，见 [插件契约与开发资料只在 Rust Core](2026-11-11-plugin-contract-single-source-in-core.md)。

对日常开发的直接影响：

- 新增或修改 Core 命令的契约和 fixture，只在 Core 的 PR 里改，和命令代码一起合入。本仓库没有要同步的副本。
- 桌面测试用 `contractfixture.CoreFixture("<相对 rust/fixtures 的路径>")` 读取 fixture。目录由 `scripts/desktop/desktop-go.sh` 导出的 `LITHE_CORE_FIXTURE_DIR` 给出，和本次链接的 Core 是同一份检出。直接运行 `go test` 会因为没有这个变量而报错，这是有意的。
- Core 改了 fixture 以后，把 `scripts/desktop/build-desktop-core.sh` 的 `PINNED_CORE_REVISION` 升到包含该改动的 commit，桌面测试就会读到新版本。本地联调时用 `LITHE_CORE_RUST_DIR` 指向自己的 Core 检出。
- i18n 生成器的格式样例（`format-v1.json`、`native-abi-v1.json`）只给本仓库的 `scripts/i18n/test-i18n.mjs` 使用，Core 不读取它们，所以移到了 `shared/i18n/fixtures/`。

## 问题

Rust Core 拆成独立仓库后，应用契约和 fixture 在两个仓库各有一份：

1. Core 的 `rust/contracts/`、`rust/fixtures/`，由执行契约的 Core 代码和它的测试读取。
2. 本仓库的 `shared/contracts/`、`shared/fixtures/`，由桌面端 Go 测试按 `../../../shared/fixtures/...` 这样的相对路径读取。

两份之间没有同步机制，已经分叉（#1853）：

- Lithe-core-rust#19 把契约迁进 Core 时，`rust-core-api.md` 少了命令总表和 AI configuration 章节，本仓库的副本里还在。
- Lithe-core-rust#18、#19、#23 删除 Agent、MCP 和 Java/Maven/JDT 专属命令时，Core 删掉了对应的 fixture，本仓库还留着 `shared/fixtures/agent/`、`shared/fixtures/lsp/java-*.json`、`shared/fixtures/maven/`、`shared/fixtures/phpunit-project` 等没有读者的副本。
- 桌面测试读本仓库的副本，链接的却是 Core 的代码。fixture 和代码可能来自不同的时间点，测试仍然会通过，验证不到真实的契约。

## 决策

### 1. Core 的 `rust/contracts/` 和 `rust/fixtures/` 是唯一来源

| 内容 | 位置 |
| --- | --- |
| Core 命令契约、接口说明和 schema | Lithe-core-rust 的 `rust/contracts/` |
| Core 命令 fixture | Lithe-core-rust 的 `rust/fixtures/` |
| 插件契约、插件开发资料和 SDK | Lithe-core-rust 的 `shared/plugins/` |
| i18n 生成器格式样例 | 本仓库的 `shared/i18n/fixtures/` |
| 跨平台功能矩阵 | 本仓库的 `shared/platform-feature-matrix/` |

删除副本之前，Lithe-core-rust#24 先补齐了 Core 一侧：补回命令总表和 AI configuration 章节，并新增测试 `api_command_table_lists_exactly_the_parsed_commands`，命令表和 `CoreCommand::parse` 不一致时直接失败。

### 2. 桌面测试读所链接的 Core 检出

`scripts/desktop/desktop-go.sh` 从同一份 Core 检出导出两个目录：设置了 `LITHE_CORE_RUST_DIR` 时用该目录，否则用 `build-desktop-core.sh` 按 `PINNED_CORE_REVISION` 克隆的检出。

| 变量 | 目录 | 读取接口 |
| --- | --- | --- |
| `LITHE_PLUGIN_CONTRACT_DIR` | `shared/plugins/contract/v1` | `contractfixture.Path` |
| `LITHE_CORE_FIXTURE_DIR` | `rust/fixtures` | `contractfixture.CoreFixture` |

变量没有设置时两个接口都 panic，避免测试什么都没读到却照样通过。这样测试读到的 fixture 和链接进来的 Core 代码一定来自同一个 commit。

### 3. 文档和功能矩阵的引用方式

- Agent Note 的 `## 适用范围` 和 Markdown 链接使用 Core 的绝对 URL，例如 `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`；正文写成 `Lithe-core-rust/rust/contracts/rust-core-api.md`。
- 已经从 Core 删除的文件，适用范围和链接固定到删除前的 Core commit，正文保留原路径作为历史记录。Java/Maven/JDT 相关 Note 的归档由 #1787 跟踪。
- 功能矩阵的当前证据必须是本仓库里存在的路径，所以删除了指向 `shared/contracts`、`shared/fixtures` 的证据条目；需要说明 Core 一侧的验证时，写进 `verification` 文字。`legacy` 证据固定在旧修订，保持原样。

### 4. 副本不再进入 git

`.gitignore` 忽略 `/shared/*`，只放行 `shared/i18n/` 和 `shared/platform-feature-matrix/`。从旧分支切过来时留在磁盘上的 `shared/contracts/`、`shared/fixtures/` 不会出现在 `git status` 里，也不会被误提交。

## 考虑过的备选方案

- **保留本仓库的副本，加一致性检查。** 不需要 Core 检出就能跑测试，但仍然是两份真源。每次改契约都要在两个仓库各提一个 PR，检查只能在事后发现不一致。被否。
- **以本仓库为真源，让 Core 读本仓库。** 执行契约的代码在 Core，Core 的测试会依赖另一个仓库的检出，方向与插件契约的决策相反。被否。
- **只把桌面测试用到的 fixture 复制到 `desktop/` 的测试目录。** 改动看起来小，本质上仍是副本。Core 改了 fixture 而本仓库没跟上时，测试会验证旧契约并且照样通过。被否。
- **用 git submodule 挂载 Core 的 `rust/`。** 引用的 commit 和 `PINNED_CORE_REVISION` 会变成两处要一起升的版本号。`desktop-go.sh` 本来就会准备 Core 检出，直接复用更简单。被否。

## 后果

- 桌面测试必须通过 `scripts/desktop/desktop-go.sh` 运行；插件契约测试本来就有这个要求。
- 升级 `PINNED_CORE_REVISION` 时，桌面测试读到的 fixture 也一起升级。Core fixture 变化导致本仓库测试失败时，在升级固定版本的同一个 PR 里修宿主。
- 功能矩阵不能再用本地路径把 Core fixture 列为证据。
- 历史 Note 和迁移文档正文里的 `shared/contracts/...`、`shared/fixtures/...` 路径保留原样，作为当时的记录；新写的引用一律指向 Core。

## 验证

- `scripts/desktop/desktop-go.sh test ./...` 用链接的 Core 检出里的 fixture 运行桌面测试。
- `./scripts/agent-notes/verify-agent-notes.sh` 检查 Note 的适用范围和相对链接。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 和 `node scripts/platform-feature-matrix/test-platform-feature-matrix.mjs` 检查功能矩阵证据。
- `node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs` 读取 `shared/i18n/fixtures/` 的格式样例。
- `node --test scripts/resources/test-reuse-worktree-resources.mjs` 检查删除 PHPUnit 夹具后的资源复用清单。

## 适用范围

- `desktop/internal/contractfixture/contractfixture.go`
- `scripts/desktop/desktop-go.sh`
- `scripts/desktop/build-desktop-core.sh`
- `.gitignore`
- `shared/i18n/fixtures/`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/contracts`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/fixtures`
