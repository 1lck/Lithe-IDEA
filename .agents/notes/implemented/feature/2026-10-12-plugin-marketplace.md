# Agent 笔记：插件市场与插件仓库源

状态：已实现

## 先说结论

Lithe 的插件管理改成和 IntelliJ IDEA 一样的“插件市场 / 已安装”两个标签。插件从“插件仓库源”（一个 JSON 索引文件）里列出：默认源是主仓库的 `Plugins/marketplace/index.json`，用户还能添加第三方源（HTTPS 索引地址，或 GitHub 仓库地址，自动指向仓库根目录的 `lithe-plugin-index.json`）。

“官方”必须同时满足两点：来自默认源，并且带 Lithe 发布者签名。第三方源里的插件一律是“社区插件”：不签名，靠索引里固定的 SHA-256 和安装前的确认框保证用户知道自己装了什么。

对日常开发的直接影响：索引格式和校验规则只在 `shared/contracts/plugins/v1/` 与 `rust/lithe-core/src/plugins/marketplace.rs` 定义一次；官方插件不再跟随 Lithe 发版，而是每个插件按自己的标签单独发布。

## 问题

声明式插件（见 [声明式语言插件与进程外执行](../architecture/2026-10-12-declarative-language-plugins.md)）让插件不再依赖宿主二进制，但下载入口仍是写死的“PHP 从当前 Lithe 版本的 Release 下载”。这有三个问题：

1. 只有 PHP 能下载，新增插件就要改宿主代码。
2. 插件跟着 Lithe 版本号发布，插件没改也要重新发，插件改了却要等 Lithe 发版。
3. 社区开发者无法分发插件，用户也无法判断一个插件包是谁做的、会运行什么程序。

## 决策

**索引与校验。** 索引按“插件 → 版本 → 各平台下载包”组织，每个下载包写明适用平台（如 `darwin-arm64`）、下载地址和 SHA-256。Rust Core 负责全部判断：格式是否合法、第三方源是否冒用 `dev.lithe.*` 命名空间、当前平台有没有包、插件 API 版本是否兼容。不合法的条目被单独忽略，不会让整个源失效。下载地址必须是该插件自己仓库的 GitHub Release `.zip` 资产，这样“来源仓库”这一栏不能造假。

**语言。** 索引的 `description` 用英文写，作为默认文本；可选的 `localizedDescriptions` 按语言标签（如 `zh-Hans`）提供翻译。界面按 Lithe 设置里选的语言挑选，找不到就显示默认文本。这样界面切到英文时不会冒出中文描述，切到中文时也不会只剩英文。

界面文字要跟随 Lithe 内的语言设置，而不是系统语言：`NSLocalizedString` 只看系统语言，SwiftUI 的 sheet 也不会继承应用设置的 `locale`。所以插件市场的文字通过 `PluginMarketplacePresentation.localized` 按当前 `locale` 取翻译，每个 sheet 都要重新设置 `.environment(\.locale, …)`。

**平台。** 每个平台下载自己的包。当前平台没有包时，详情页显示“暂不支持 <平台> 平台”，不提供安装按钮。

**信任。**

- 官方源只接受 `publisherPackage` 签名包；第三方源只接受 `signatureRequirement: "none"` 的包。Rust 拒绝官方命名空间声明 `none`。
- 社区插件安装顺序：下载 → 校验 SHA-256（不匹配就不解压）→ 声明式校验 → 弹窗列出权限、要运行的程序和来源仓库 → 用户确认后安装。
- 安装时把内容摘要（包内每个文件的 SHA-256 汇总）、来源和已确认的程序写进安装记录。之后每次扫描都重新计算摘要，文件被改动就拒绝加载。这是未签名包唯一的完整性证明。
- 更新时如果新增了要运行的程序，必须重新确认。“程序”按实际执行内容比较，不只看可执行文件：语言服务器的启动参数和验证探测参数、运行和测试的参数模板都算在内。比如旧版运行 `node runner.js`、新版改成 `node -e …`，可执行文件都是 `node`，也必须重新确认；只看可执行文件就会让插件在用户不知情时改变行为。
- 同一插件出现在多个源时由用户选源；更新只走安装时记录的源，防止别的源用同名插件“劫持”更新。

**资源上限。** SHA-256 只能证明下载物就是索引写的那个文件，第三方索引照样可以指向一个 ZIP 炸弹（压缩包很小、解压后极大）。所以下载时边收边计数，超过 512 MB 立即中止，不先落盘；解压前先读 ZIP 中央目录，检查声明的展开总大小（2 GB）和文件数（5 万）；解压过程中再定时实测已写出的大小和文件数，超限就终止 `ditto`。第二道实测不能省：`ditto` 按压缩数据解压，不理会中央目录里谎报的大小。

**存储。** 源列表写在 Application Support，索引缓存写在 Caches，下载和解压使用临时目录。app bundle 里只读地附带一份官方索引，作为离线和首次启动时的兜底，运行时从不写回 bundle。

**官方插件发布。** `Plugins/marketplace/official-plugins.json` 登记每个官方插件的标签前缀、包目录和资产名。`release-official-plugins.yml` 在 PR 上检查“插件内容变了但版本没升”，合入 preview 后只为版本有变化的插件新建 `plugin-<名称>-v<版本>` 标签和 Release。插件代码不变，它的标签就不动。

“发布”和“登记到索引”是两个独立的 job。登记 job 每次运行都重新找出“已打标签、但索引里没有”的版本（扫描整个标签系列），从已发布的 Release 下载资产计算 SHA-256，再开索引 PR；已有打开的索引 PR 就跳过。这样即使 Release 发出去后开 PR 失败，重跑工作流也能补上。如果像以前那样只在“标签不存在”时才处理，Release 一旦发出就再也不会被登记。

**展示的版本。** Core 会跳过当前平台或插件 API 不满足的新版本，选择能安装的旧版本。详情里的版本、发布日期和支持平台都描述“点安装会装的那个版本”；最新版本不同时，单独一行注明它在当前 Lithe 或这台 Mac 上无法使用。

正确做法：新增官方插件时登记到 `official-plugins.json`，改插件内容时同时升 `plugin.json` 的版本。

不要这样做：手工改 `index.json` 里的下载地址或 SHA-256，或者把插件包重新挂到 Lithe 的版本 Release 上。

## 考虑过的备选方案

1. **继续让官方插件随 Lithe 发版。** 插件和宿主已经解耦，再绑在一起只会让无关改动触发重新发布，所以放弃。
2. **社区插件也由 Lithe 签名（DBX 商店的做法）。** 需要审核流程和签名基础设施，现阶段负担过重。改为固定 SHA-256 + 安装确认 + 内容摘要复查。
3. **索引校验在 Swift 里实现。** Windows 以后也要用同一套规则，放在 Rust Core 可以只写一次。
4. **允许任意 HTTPS 下载地址。** 这样“来源仓库”无法与下载物对应，用户看到的仓库可能不是包的真正来源，所以限制为该仓库自己的 Release 资产。

## 后果

- 新插件只需要进入某个索引，宿主不用改代码。
- 首个 PHP 声明式包发布前，官方索引是空的；合入后工作流会立即发布 `plugin-php-support-v1.0.0` 并开 PR 填充索引，客户端刷新时从仓库 HEAD 读取。
- Lithe 版本 Release 里的 `Lithe-PHP-Support-<版本>-<架构>.zip` 只为旧客户端保留，之后可以移除。
- 社区插件不签名，安全性依赖用户确认；确认框必须完整列出程序，不能省略。
- Windows 目前只共享契约和 Rust 校验，还没有界面。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib marketplace_plugins`：索引校验、平台与 API 判断、命名空间、源地址解析、安装审查的标准答案。
- `./scripts/verify-shared-contracts.sh`：市场 fixture 与错误码登记。
- `node --test scripts/official-plugin-releases.test.mjs`：只为版本变化的插件生成标签，内容变化未升版本时失败；已发布未登记的版本会被重新登记。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'PluginMarketplace|MacPluginPackageDownloader|PluginManagementPresentation|PluginManager|PluginPackageStore'`：校验和先于解压、下载中途超限即止、解压前后的大小和文件数上限、源与签名的信任匹配、内容摘要复查、更新只走记录的源、新增程序重新确认。
- `./scripts/verify-runtime-bundle-immutability.sh`：刷新索引和安装插件不改写 app bundle。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/marketplace.rs`
- `Plugins/marketplace/`
- `scripts/official-plugin-releases.mjs`
- `.github/workflows/release-official-plugins.yml`
- `macos/Sources/LitheCoreContracts/Plugins/PluginMarketplaceContracts.swift`
- `macos/Sources/Lithe/Application/Features/PluginMarketplace.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/`
- `macos/Sources/Lithe/Views/App/PluginMarketplaceView.swift`
- `macos/Sources/Lithe/Views/App/PluginManagementView.swift`
