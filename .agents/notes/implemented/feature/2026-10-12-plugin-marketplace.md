# Agent 笔记：插件市场与插件仓库源

状态：已实现

## 先说结论

Lithe 的插件管理改成和 IntelliJ IDEA 一样的“插件市场 / 已安装”两个标签。插件从“插件仓库源”（一个 JSON 索引文件）里列出：默认源是主仓库的 `Plugins/marketplace/index.json`；另外预置一个社区源 Lithe Store（`Lithe-IDEA/Lithe-store` 仓库，默认开启、可删除）；用户还能添加第三方源（HTTPS 索引地址，或 GitHub 仓库地址，自动指向仓库根目录的 `lithe-plugin-index.json`）。

“官方”市场条目必须同时满足两点：来自默认源，并且带 Lithe 发布者签名。社区包也可以从磁盘 ZIP 或解包目录安装：先复制到本次操作的私有快照，再让用户确认权限和完整程序声明。市场索引校验值、本地快照摘要和发布者签名各自证明不同的事实，不能互相冒充；本地安装不会因市场出现同 ID 条目而自动变成市场管理的插件。

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

- 官方源只接受 `publisherPackage` 签名包；第三方源只接受 `signatureRequirement: "none"` 的包。Rust 拒绝官方命名空间（`dev.lithe`、`dev.lithe.*`）声明 `none`，宿主的 `OfficialPluginCatalog` 还固定已知官方 ID 的签名要求，包不能自行降级。磁盘入口不改变这些要求：有效签名仍需验证；未签名的 publisher 开发包只允许 DEBUG 的 `localDevelopment` 路径，release 拒绝；`sameTeamAsHost` 只认宿主 bundle 内的包。
- 市场社区包按“下载 → 与索引 SHA-256 比对（不匹配不解压）→ 声明和包校验 → Rust 安装审查 → 用户确认 → 安装”处理。磁盘包没有索引，按下文的私有快照流程处理；不能伪造来源仓库或显示“与仓库匹配”。
- 本地磁盘社区包每次都问：首次安装、升级和同版本替换，即使权限与程序完全相同，也要明确确认。市场入口保持已有规则：首次安装、缺少既有审批或 `newPrograms` 非空时确认，无新程序的市场更新可以沿用审批。两条入口复用 `plugins.marketplace.installReview`；需要确认时展示本次全部 `permissions` 和 `programs`，不能只展示差异，磁盘入口不能根据 `newPrograms` 为空跳过确认。“程序”包含启动和验证参数、运行/测试参数模板、运行时及构建声明等 Core 返回的完整内容，保存时使用 canonical JSON（字段顺序规范化的完整 JSON），不能只留下可执行文件名或摘要。比如 `node runner.js` 改成 `node -e …` 必须完整可见。已识别程序的可读说明另附原生“Full Program Declaration”展开项显示完整 canonical JSON；未知种类本就显示完整 JSON，不重复展示。
- 安装记录分别保存市场来源 `PluginMarketplaceProvenance` 和磁盘来源 `PluginDiskProvenance`；社区版本必须恰好有其中一种。两种来源都保存内容摘要（包内文件 SHA-256 的汇总）与完整 `approvedPrograms`。磁盘记录只保留所选文件/目录名称、可选的 ZIP 摘要和本地审批，不生成 `sourceID` 或仓库 URL；这些摘要绑定本次批准的字节，不认证发布者。
- 安装 staging（写入正式版本前的暂存副本）、每次已安装扫描和回滚都重验内容摘要；文件新增、删除或改动时拒绝接受该版本。当前版本与上一版本各自保存 origin 和来源（`disk` / `previousDisk`、`marketplace` / `previousMarketplace`），回滚使用被恢复版本自己的记录。同版本替换保留原有上一版本及其来源，不把被覆盖的同版本另记成可回滚版本。
- 同一插件出现在多个市场源时由用户选源；市场更新只走安装时记录的源。磁盘版本没有市场更新源，显示为市场外管理，不能因为同 ID 上架就自动提供市场更新或重装。

**资源上限。** SHA-256 只能证明下载物就是索引写的那个文件，第三方索引照样可以指向一个 ZIP 炸弹（压缩包很小、解压后极大）。所以下载时边收边计数，超过 512 MB 立即中止，不先落盘；解压前先读 ZIP 中央目录，检查声明的展开总大小（2 GB）和文件数（5 万）；解压过程中再定时实测已写出的大小和文件数，超限就终止 `ditto`。第二道实测不能省：`ditto` 按压缩数据解压，不理会中央目录里谎报的大小。

**磁盘快照。** `MacPluginDiskPackageImporter` 只读取用户选中的 ZIP 或解包目录，先复制到独占、权限为 `0700` 的 `<file-storage-temp>/lithe-plugin-disk-<UUID>/`，再校验和审查快照。ZIP 存为 `archive.zip` 后计算 `archiveSHA256` 并解压到 `package/`；目录只复制到 `package/`，`archiveSHA256` 为 `nil`，不能拿内容摘要填成归档摘要。检查根和后代的符号链接、Finder alias、特殊文件、复制期间源变化、隐藏目录及唯一 `plugin.json`；目录复制深度上限为 64，临时根不能落在所选源目录内。ZIP 在解压前同时检查中央目录和 local header 的路径与类型，拒绝重复/冲突路径，不执行所选包内代码。原始输入之后被替换，不应改变用户正在审查的快照。

**后台审查。** 整包摘要、Rust 安装审查和候选包复验在独立的原生工作队列执行，不能在 `MainActor` 上扫描最多 2 GB 的输入。工作线程使用自己的 Store 编解码器，只共享不可变的校验策略；页面关闭仍可取消任务。取消后先等正在读取快照的工作线程结束，再删除该目录，不能让清理与读取并发；各审查阶段之间检查取消，返回 UI 前再检查一次。

**存储与清理。** `MacServiceContainer` 通过 `fileStorage.temporaryDirectory()` 注入上述临时根，开发版随发行身份隔离；不从 bundle 推导可写目录。导入失败或取消由 importer 删除部分快照，准备完成后由市场 service 持有，取消审查、安装成功或安装失败都调用 discard 删除本次目录。插件页关闭时取消自己的磁盘导入任务并结束安装 session；已有待确认快照立即 discard，迟到的准备结果也只清理，不能在页面关闭后安装。安装 store 另行持有 `<app-support>/Lithe/Plugins/.staging/<transaction>/`，安装后只保留用户级版本目录及 `installation.json`；这些资源和审批记录没有可跨工作树复用的版本/平台/架构/工具链身份标记，任何复制阶段均不复用，注册表为 `plugin-disk-install-state`。

源列表写在 Application Support，索引缓存写在 Caches，网络下载和解压也只使用本次临时目录。app bundle 只读地附带官方索引，作为离线和首次启动兜底。运行时不写 macOS 发行 bundle 或 Windows 安装资源，不影响代码签名和 Sparkle delta 的发布基线；静态门禁之外，真实验收还需比较典型工作流前后的 bundle 文件清单和哈希。

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
5. **把磁盘包伪装成临时市场源，或只审查用户原目录后再复制。** 前者会虚构远端认证与更新来源，后者允许审查和安装的字节不同；改为先复制私有快照，再保存独立磁盘来源。正确做法是从快照计算 ZIP 摘要、展示完整审查并安装同一快照；不要用原 ZIP 的摘要替代快照摘要，也不要因为同版本或程序未变就跳过确认。

**预置社区源。** Lithe Store 是官方维护的社区插件索引，随 Lithe 预置，免得用户第一次打开插件市场时要先找源地址。它在信任上与用户手动添加的第三方源完全相同：插件显示为“社区”、不能用 `dev.lithe.*`、安装前必须确认。用户删除后，`sources.json` 的 `removedPresetSourceIDs` 记住这次删除，下次启动不会再加回来；用户停用只改变启用状态。

**预置源的 ID。** 已安装插件只记录来源 ID（`PluginMarketplaceProvenance.sourceID`），更新、重装和“来自其他源”判断都按 ID 匹配。因此 Lithe Store 的 ID 不用固定字符串，而用与手动添加相同的规则从索引 URL 派生（`PluginMarketplaceSource.id(forIndexURL:)`）：无论是预置的、在没有预置的旧版本里手动添加的，还是删除后重新添加的，ID 都一样，插件不会因此找不到来源。GitHub 的 owner/仓库名不区分大小写：重新添加时，大小写不同的同一索引地址会取回预置 ID；旧版本按其他大小写手动添加的记录则保留原 ID 和启用状态，并代替预置源，不再额外插入一份。

正确做法：Store 的收录、校验、版本追踪规则写在 Lithe-store 仓库的 `docs/`，主仓库只保存源地址常量。

不要这样做：把 Lithe Store 当成官方源，或者为了“推荐”而给它的插件更高的信任。

## 后果

- 新插件只需要进入某个索引，宿主不用改代码。
- Go 和 PHP 后来迁到 Lithe Store 社区源，官方索引重新变为空，旧官方 ID 只保留签名要求、不再有官方来源，见 [Go 与 PHP 改为 Lithe Store 社区插件](../architecture/2026-10-20-go-php-community-plugins.md)。
- 首个 PHP 声明式包发布前，官方索引是空的；合入后工作流会立即发布 `plugin-php-support-v1.0.0` 并开 PR 填充索引，客户端刷新时从仓库 HEAD 读取。
- Lithe 版本 Release 不再附带 `Lithe-PHP-Support-<版本>-<架构>.zip`。发版时只需要兼容 0.6.1 及之后的客户端，它们从官方索引下载插件；0.6.0 及更早的客户端不再从 Lithe Release 获得 PHP 包。
- 社区插件的内容摘要只能检测批准后的包内容变化，不能证明作者身份；磁盘每次确认增加一次交互和快照复制成本，确认框必须完整列出程序，不能省略。
- 磁盘包可以离线安装，但没有仓库更新来源；替换需要用户重新选择包并确认，审批记录不可作为工作树缓存搬运。
- Windows 在本能力中仍为 `partial`，只共享索引契约与 Rust 校验；尚无插件市场 UI、声明式 ZIP/目录磁盘快照或本地来源审批链，不能用现有 Windows worker 插件导入代替此能力。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib marketplace_plugins`：索引校验、平台与 API 判断、命名空间、源地址解析、安装审查的标准答案。
- `./scripts/verify-shared-contracts.sh`：市场 fixture 与错误码登记。
- `node --test scripts/official-plugin-releases.test.mjs`：只为版本变化的插件生成标签，内容变化未升版本时失败；已发布未登记的版本会被重新登记。
- `node scripts/test-reuse-worktree-resources.mjs`：磁盘快照、安装 staging、版本和审批记录不出现在可复用列表，显式选择时在访问工作树或复制前拒绝。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'PluginMarketplace|PluginDiskInstallation|MacPluginDiskPackageImporter|MacPluginPackageDownloader|PluginManagementPresentation|PluginManager|PluginPackageStore'`：校验和先于解压、下载和展开上限、磁盘快照隔离、源与签名要求、完整程序审查、安装 staging/扫描/回滚摘要复查、来源保留及同 ID 不自动接管。过滤器只是运行入口，必须核对报告确实包含 `MacPluginDiskPackageImporterTests`、`PluginDiskInstallationTests` 和磁盘 FeatureModel 场景，不能以零匹配当作通过。
- `./scripts/verify-runtime-bundle-immutability.sh`：静态检查 macOS 与 Windows 资源解析路径；它本身不启动产品，也不替代工作流前后的文件清单/哈希比较。

可复验的产品流程：分别选择社区 ZIP 和解包目录，确认本地提示、文件名、内容摘要及 ZIP 可选归档摘要；取消后无安装及快照残留，再确认安装。继续用相同程序的新版、同版本原包、同版本改过脚本的包逐一替换，每次均应显示全部权限与完整程序并要求确认。审查等待期间改动原输入，安装结果应仍与私有快照一致；改动准备好的快照或已安装/上一版本内容，应分别在安装 staging、扫描或回滚时被拒绝。市场刷新出现同 ID 时，应无市场自动更新/重装接管。导入和待确认期间关闭插件页，确认已有及迟到返回的快照都清理且不会安装。对成功、取消、非法包和资源超限检查临时目录清理，比较前后发行 bundle 清单/哈希并关闭本次应用与子进程。

功能矩阵 `shared/platform-feature-matrix/features/plugin-marketplace.json` 的 macOS 验证保持 `pending`，上述步骤是验收方法，不是已完成证据。静态或 Node 资源测试通过不能证明磁盘每次确认、完整 canonical 程序展开项或实际清理行为。

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
