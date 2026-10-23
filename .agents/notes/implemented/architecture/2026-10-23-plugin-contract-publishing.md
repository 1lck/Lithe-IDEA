# Agent 笔记：插件契约在主仓库定义，完整副本、SDK 和开发者资料发布到 lithe-plugin-docs

状态：已实现

## 先说结论

插件契约（`shared/contracts/plugins/v1/`，规定 `plugin.json` 每个字段的含义、错误码和标准答案用例）仍然在主仓库定义，由 Rust Core 执行。公开仓库 `Lithe-IDEA/lithe-plugin-docs` 的 `contract/v1/` 保存这个目录的**完整逐字节副本**，另外放开发指南、从 Lithe Store 搬过来的两篇教程、两个官方 SDK（源码、发版和端到端测试）和示例插件列表。插件开发者只看 lithe-plugin-docs 就能开发，写插件、发布插件都不需要克隆主仓库，也不需要给主仓库提 PR。

日常开发要记住四件事：

1. 契约目录下任何文件合并后，都要到 lithe-plugin-docs 运行同步脚本。这条规则也写在根目录 `AGENTS.md`。
2. 契约 README 里指向目录外的链接必须用绝对 URL，因为副本只包含这个目录。
3. 契约 fixture（测试用的示例清单）按“演示什么能力”命名，不按真实插件命名。
4. 主仓库不再保存 SDK。SDK 的修改和发版都在 lithe-plugin-docs；改 Core 的插件后端协议时，合并前要用它的 `scripts/sdk-e2e.mjs` 跑一次 SDK 端到端测试。

## 问题

主仓库里有很多插件 JSON，看起来像是各个插件仓库的配置副本。逐个盘点后，它们分成三类：

1. **契约本身**：schema、README 和错误码。Rust Core 的测试用 `include_str!` 直接读取它们，Swift 测试也读取其中的 fixture，所以它们必须和执行它们的代码在同一个提交里修改。
2. **契约 fixture**：文件名是 `maven-build`、`php-support`、`cargo-build` 这类真实插件名，ID 也是 `dev.lithe.fixture.maven-build`。实际上它们只是借 Cargo、Go、Gradle、Maven 当真实输入，用来演示某种能力，例如“从命令输出解码项目模型”。名字让人误以为主仓库在维护这些插件的配置。
3. **确实属于插件仓库的副本**：例如 `rust/lithe-core/src/tests/fixtures/community_build_plugins/` 中 Maven、Gradle 插件的快照。这一类本次不处理，留作后续迁移。

除此之外，外部开发者需要的东西分散在主仓库和 Lithe Store：

- 字段语义、错误码和标准用例只在主仓库。
- schema 的 `$id` 是 `https://lithe.dev/...`，但这个域名不归我们所有，地址解析不到，编辑器没法用它。
- 两个 SDK 的源码在主仓库，Node SDK 也没有正式发布，只能从主仓库复制 `src/`。
- 教程在 Lithe Store，Store 还有一份已经过期的 schema 副本。没有一个“我要写插件，从哪里开始”的入口。

## 决策

### 契约在主仓库定义

契约和执行它的代码（Rust Core 的校验和标准答案测试）必须在同一个 PR 里修改。如果把契约的源头移到别的仓库，改一个字段就要两个 PR，中间还会出现“契约写的是 A、Core 做的是 B”的时间窗口。外部开发者只需要**读**契约、不需要**改**契约，读的需求由完整副本满足。

### lithe-plugin-docs 是开发者的唯一入口

- `README.md`：中文开发指南，讲插件结构、API 等级怎么选、编辑器校验、后端 SDK 和示例插件。
- `guides/`：从 Lithe Store 搬来的《LSP 插件完整生命周期》和《构建、运行与测试接入》。契约链接改为本仓库的 `contract/v1/`，发布相关链接指向 Store。
- `contract/v1/`：主仓库 `shared/contracts/plugins/v1/` 整个目录的逐字节副本，包括 README、两份 schema 和全部 fixture。
- `contract.lock.json`：记录来源仓库、来源目录、commit 和每个文件的 SHA-256，格式与 Cargo 插件的 `sdk.lock.json` 相同。
- `sdk/node`、`sdk/java`：两个官方 SDK 和各自的示例插件；`sdk/e2e`：两个示例共用的端到端场景（Rust 测试文件）。
- `scripts/contract.mjs` 提供四个命令：
  - `sync --revision <commit>`：按来源目录在该 commit 的 git tree 整体替换副本，新增、删除、修改的文件都跟上，然后重写锁文件。
  - `verify`：离线检查锁文件、哈希、schema `$id`、Markdown 相对链接和未锁定文件。
  - `verify --upstream`：用 GitHub API 取锁定 commit 的 tree，按 git blob ID 比较整个目录。
  - `drift`：检查主仓库 `preview` 分支上的契约是否已经变化。不用默认分支：主仓库的默认分支是稳定版 `main`，只在发版时追上 `preview`，拿它比较会让刚同步过的副本每周都报差异。

  docs 仓库的 CI 每次提交运行前两项检查和脚本测试，每周运行一次 `drift`。
- `scripts/sdk-e2e.mjs`：SDK 端到端测试，见下文“SDK 整体移到 lithe-plugin-docs”。

只复制 schema 不够：字段之间的约束、错误码和预期结果都写在契约 README 和 fixture 里，只有 schema 的话，开发者仍然要回主仓库查。

### Lithe Store 只管收录和上架

Store 保留 `publishing.md`、`versioning-and-updates.md`、`maintainers.md` 和 `CONTRIBUTING.md`，讲怎么提交收录、怎么追踪版本。两篇教程搬到 lithe-plugin-docs，Store 的 `schema/plugin-index.schema.json` 副本删除。

Store 的 `validate-index.mjs` 仍然实现索引规则。它的 CI 原来比较本地 schema 副本和主仓库 preview，现在改为检查 lithe-plugin-docs 上 `plugin-index.schema.json` 的 SHA-256 是否等于工作流里记录的值。不相等说明索引契约变了，Store 维护者更新校验脚本后再更新记录的哈希。

### Schema 地址固定为 docs 仓库的 raw 地址

两份 schema 的 `$id` 是它在 docs 仓库里的地址：
`https://raw.githubusercontent.com/Lithe-IDEA/lithe-plugin-docs/main/contract/v1/<文件名>`。

两边都对这个地址做严格检查：

- 主仓库的 `scripts/verify-shared-contracts.sh` 用常量 `published_plugin_schema_base` 要求 `$id` 完全相等。
- docs 仓库的 `contract.mjs` 要求每份 schema 的 `$id` 等于它自己的发布地址。

因此，如果主仓库改了地址而 docs 仓库没跟上，或者 docs 仓库里的文件不是从主仓库同步来的，CI 都会失败。

### 契约 README 的外链写绝对地址

副本只包含契约目录，`../` 开头的相对链接在 docs 仓库里会失效。所以契约 README 指向 `rust-core-api.md`、Agent Notes 的链接都写成 `https://github.com/1lck/Lithe-IDEA/blob/preview/...`，指向 SDK 的链接写成 lithe-plugin-docs 的地址。

两边都检查这条规则：

- 主仓库的 `verify-shared-contracts.sh` 拒绝离开目录或指向不存在文件的相对链接。
- docs 仓库的 `contract.mjs` 在同步和校验时也拒绝这类链接。

### `plugin.json` 里不能写 `$schema`

Core 解析清单时拒绝未知字段（serde `deny_unknown_fields`），schema 本身也是 `additionalProperties: false`。如果开发者按习惯加一行 `"$schema"`，插件会因为 `plugin.manifest.invalid` 装不上。所以指南要求在编辑器里按文件名关联 schema，例如 VS Code 的 `json.schemas`。是否在以后的契约版本里允许 `$schema` 另行决定：那需要提高能力版本，老版本 Lithe 会拒绝新格式。

### fixture 按能力命名

`shared/contracts/plugins/v1/fixtures/` 中的 fixture 改为按演示的能力命名，ID 同步改成 `dev.lithe.fixture.<新名字>`：

| 原名 | 新名 | 演示什么 |
| --- | --- | --- |
| `php-support` | `language-packaged-server` | 随包附带语言服务器 |
| `go-support` | `language-system-command` | 使用用户安装的命令作为语言服务器 |
| `java-support` | `language-host-integration` | 交给宿主集成的语言服务器 |
| `cargo-build` | `build-static-file` | 从项目文件读取构建模型 |
| `go-build` | `build-command-stdout` | 解码命令的标准输出 |
| `gradle-build` | `build-command-output-file` | 解码命令写出的文件 |
| `maven-build` | `build-host-integration` | 把构建模型交给宿主集成 |
| `gradle-provider` | `build-provider` | 构建后端 |
| `mix-provider` | `build-provider-language-server` | 与语言服务器共用进程的构建后端 |

fixture 的内容仍然用 Cargo、Go、Gradle、Maven 作为真实输入，契约 README 写明“它们不是这些插件”。macOS 测试中同 ID 的展示用副本（`macos/Tests/LitheTests/Fixtures/BuildSystems/`）一起改名。

`shared/fixtures/plugins/language-support-v1.json` 保留旧 ID `dev.lithe.fixture.go-support`。它是已退役的 schema 1 格式，只被 `rust/lithe-core/src/tests/plugins.rs` 的旧格式测试读取，与声明式契约无关。

### SDK 整体移到 lithe-plugin-docs

SDK 是给插件开发者用的库，不是契约。开发者要读它的 README、看示例、提问题、下载发布包，这些都应该在 lithe-plugin-docs 完成，所以 `sdk/`、SDK 端到端测试和两个发版工作流都从主仓库移走，主仓库只保留契约。

- **发版**：lithe-plugin-docs 打 `sdk-node-v<版本>` 或 `sdk-java-v<版本>` 标签，`release-node-sdk.yml`、`release-java-sdk.yml` 发布包和 `.sha256`。具体规则见 [官方插件后端 SDK](2026-10-20-plugin-backend-sdk.md)。Java SDK 0.1.0 是迁移前从主仓库发布的，那个 Release 保留，Maven 插件锁定的下载地址不变。
- **单元测试**：SDK 自己的测试读 `contract/v1/fixtures/function-protocol.json`，也就是契约副本，不再读主仓库。
- **端到端测试**：场景仍是 Rust 测试，要链接 Rust Core。`sdk-e2e.mjs` 把锁文件记录的主仓库 commit 稀疏检出到 `.artifacts/lithe`（只取 `rust/` 和 `shared/`），把 `sdk/e2e` 复制进它的 `rust/lithe-core/tests/`，再用 `cargo test --locked` 运行。`LITHE_PLUGIN_SDK_ROOT` 告诉测试示例插件在哪里。这和 Cargo 插件测 Core 的方式相同。
- **两个版本的 Core**：每次提交测契约副本锁定的那个 commit，保证 SDK、契约副本和 Core 是同一个版本；每周再用 `--ref preview` 测主仓库 `preview` 分支的最新 Core，提前发现 Core 的改动破坏了 SDK。

代价是主仓库的 PR 不再当场发现“Core 改动破坏 SDK”。改插件后端协议（`rust/lithe-core/src/lsp/interface/plugin_function.rs`、`litheBuild` 相关代码）时，合并前要在 lithe-plugin-docs 用 `--source <本地主仓库> --ref <分支>` 手动跑一次。

### 正确做法

- 修改契约：在同一个 PR 里改 `shared/contracts/plugins/v1/`、Core 和测试。合并后，在 lithe-plugin-docs 运行 `node scripts/contract.mjs sync --revision <合并后的 preview commit>`，然后提交。
- 改了 `plugin-index.schema.json`：同步 docs 仓库之后，Lithe Store 的 CI 会失败，按 Store 的 `docs/maintainers.md` 更新索引校验和记录的哈希。
- 在契约 README 里引用目录外的文件：写 `https://github.com/1lck/Lithe-IDEA/blob/preview/<路径>`。
- 新增 fixture：按演示的能力命名，例如 `build-command-stdout.plugin.json`，ID 使用 `dev.lithe.fixture.` 前缀。
- 新增面向插件开发者的说明：写进 lithe-plugin-docs 的 README 或 `guides/`。
- 修改或发布 SDK：在 lithe-plugin-docs 提 PR、打标签。
- 修改插件后端协议：合并前在 lithe-plugin-docs 运行 `node scripts/sdk-e2e.mjs --source <本地主仓库> --ref <分支>`。

### 不要这样做

- 在 lithe-plugin-docs 里直接编辑 `contract/` 下的文件，或者让主仓库 schema 的 `$id` 指向别的地址。两边的 CI 都会失败。
- 在契约 README 里写 `../` 开头的相对链接。
- 用真实插件名命名 fixture，例如 `maven-build.plugin.json`。读者会以为主仓库在维护那个插件的配置。
- 在指南或示例里让开发者往 `plugin.json` 写 `$schema`。
- 把插件开发教程写回 Lithe Store 或主仓库的 `Plugins/`。
- 在主仓库重新加 `sdk/` 目录，或者让主仓库 CI 检出 lithe-plugin-docs 跑 SDK 测试。依赖方向是 docs 仓库依赖主仓库，反过来会让主仓库的结果取决于另一个仓库的 `main`。

## 考虑过的备选方案

### 把契约的源头移出主仓库

开发者只看一个仓库，这个目标现在由完整副本实现。真正把源头移走有两种做法，都没有采用：

- **git submodule（子模块）**：主仓库测试读取子模块里的文件。每次改契约都要先在契约仓库合并，再在主仓库更新子模块指针；所有克隆和 CI 都要多一步初始化子模块。
- **测试时按锁文件下载契约**：主仓库只保存锁文件，构建前下载。Rust 测试用 `include_str!` 在编译期读取 fixture，离线构建和每个 worktree 都要先准备下载物，还要纳入 worktree 资源复用清单。

两种做法都让“改契约、改 Core、改测试”变成跨仓库的多步操作，复杂度高于每次合并后同步一次副本。

### 只发布两份 schema 副本

这是最初的方案，docs 仓库只放 schema。没有采用，因为字段语义、错误码和标准用例都在契约 README 和 fixture 里，开发者遇到 schema 表达不了的规则时仍然要回主仓库。

### 把 schema 放到主仓库的 GitHub Pages 或主仓库 raw 地址

这样不用多建一个仓库。但 Pages 目前用来发布 Agent Notes 看板，自定义域名 `notes.lithe.top` 还没有 HTTPS 证书。如果用主仓库 raw 地址，开发者的入口仍然是主仓库，而且主仓库调整目录结构就会改变公开地址。

### 教程和契约副本都放在 Lithe Store

Store 原来已经有教程和一份 `schema/plugin-index.schema.json`。没有采用，是因为 Store 负责收录和上架，它的 schema 副本已经和主仓库不一致（`$id` 还是 `lithe.dev`）。把“怎么写插件”和“怎么上架”分开，Store 的收录规则可以保持单一职责。

### SDK 留在主仓库，只单独发版

这是本次最初的做法：端到端测试留在 Rust Core lane，改 Core 时当场发现 SDK 被破坏。没有采用，因为开发者仍然要到主仓库读 SDK 的 README、看示例、提 issue，改 SDK 也要给主仓库提 PR，和“开发者只看 lithe-plugin-docs”的目标冲突。端到端测试改成按锁文件检出 Core 以后，跨仓库固定 Core 版本的成本可以接受。

### 主仓库 CI 检出 lithe-plugin-docs 跑 SDK 端到端测试

这样改 Core 时仍能当场发现问题。没有采用：主仓库的测试结果会取决于另一个仓库 `main` 分支的状态，docs 仓库合并一个坏提交就会让主仓库所有 PR 失败；同时形成两个仓库互相依赖。

### 把 Node SDK 发布到 npm

npm 是 Node 开发者最熟悉的方式。但插件包安装后没有 `npm install` 步骤，开发者最终还是要把 SDK 文件复制进插件包。发布到 npm 还要管理组织和令牌，目前没有必要。

## 后果

- 收益：外部开发者只需要 lithe-plugin-docs；schema 地址可以真正解析，编辑器能直接提示；fixture 名字不再误导；两个 SDK 的源码、发版和问题都在同一个仓库，Node SDK 也有带哈希的正式下载。
- 代价：契约变更后要多做一次同步。同步之前，docs 仓库的副本会落后于主仓库，每周的 `drift` 检查会失败提醒。
- 代价：Core 改动破坏 SDK 时，主仓库 PR 不会失败，最晚由 docs 仓库的每周检查发现；docs 仓库的端到端测试每次都要编译一遍 Core。
- 代价：契约 README 不能用相对链接引用主仓库的其他文件，这些绝对链接指向 `preview`，会随主仓库调整目录而失效。
- 代价：schema `$id` 绑定了 docs 仓库 `main` 分支的 raw 地址。仓库改名或换默认分支都会改变公开地址，必须同时改两边的检查。
- 后续工作：
  - `community_build_plugins` 中 Maven、Gradle 快照迁回插件仓库。
  - Lua、Gradle、Maven 插件 README 里指向 Store 教程和主仓库契约的链接，改为指向 lithe-plugin-docs。
  - Windows PhpSupport 插件迁移。
  - 其他共享 schema 仍然使用 `lithe.dev` 作为 `$id`。
- 重新评估的条件：如果契约开始需要外部贡献者直接修改，或者 Rust Core 拆成独立仓库，就重新考虑契约放在哪里。

## 验证

- `./scripts/verify-shared-contracts.sh`：两份 schema 的 `$id` 必须等于 docs 仓库的发布地址；契约 README 的相对链接不能离开目录；fixture ID 必须以 `dev.lithe.fixture.` 开头。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib -- declarative_plugins build_systems marketplace_plugins build_runtime_versions`：改名后的 fixture 仍然得到相同的标准答案。
- `bash scripts/test-classify-ci-changes.sh`：主仓库的 CI 分类不再有 `sdk/` 路由。
- 在 lithe-plugin-docs 运行 `node --test scripts/*.test.mjs` 和 `node scripts/contract.mjs verify --upstream`：同步脚本的测试通过，副本与锁定 commit 的契约目录完全一致。
- 在 lithe-plugin-docs 运行 `node --test sdk/node/test/*.test.mjs`、`mvn -B -f sdk/java/pom.xml verify` 和 `node scripts/sdk-e2e.mjs`：两个 SDK 的单元测试读契约副本通过，两个示例后端在锁定版本的 Core 上跑完端到端场景。

## 适用范围

- `AGENTS.md`
- `shared/contracts/plugins/v1/`
- `scripts/verify-shared-contracts.sh`
- `scripts/verify-rust-core-crates.sh`
- `scripts/classify-ci-changes.sh`
- `.github/workflows/ci-macos.yml`
- `Plugins/README.md`
- `https://github.com/Lithe-IDEA/lithe-plugin-docs`
- `macos/Tests/LitheTests/Fixtures/BuildSystems/`
