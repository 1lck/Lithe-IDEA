# Agent 笔记：Go 与 PHP 改为 Lithe Store 社区插件

状态：已实现

## 先说结论

macOS 的 Go Support 和 PHP Support 不再是 Lithe 官方插件。它们搬到各自的社区仓库（`Lithe-IDEA/lithe-plugin-go`、`Lithe-IDEA/lithe-plugin-php`），用新 ID `io.github.lithe-idea.go-support` 和 `io.github.lithe-idea.php-support` 发布，并列在 Lithe Store 社区源里，版本从 0.1.0 开始。主仓库不再构建或发布这两个包，官方索引目前是空的。

已经装了旧官方包的用户不会被悄悄切换。插件管理会提示“已迁移到社区插件”，引导用户先卸载旧包，再从插件市场安装社区版。旧 ID 仍然按原来的官方签名要求校验，所以没人能用旧 ID 冒充官方包。

社区版 PHP 插件不再打包 Intelephense（PHP 语言服务器）。Intelephense 的许可证禁止再分发，所以改成由用户自己安装（`npm install -g intelephense`），插件按命令名 `intelephense` 启动它。

## 问题

Go 和 PHP 已经是声明式插件：包里只有 `plugin.json`（PHP 另有 Intelephense），不含宿主要加载的代码，见 [声明式语言插件](2026-10-12-declarative-language-plugins.md)。它们和 Lithe 本体没有编译关系，但仍然放在主仓库里：

- 每次改插件都要走主仓库的 PR、CI 和官方签名发布流程，和 Lithe 本体的发版节奏绑在一起。
- 官方插件要用 Lithe 的 publisher 私钥签名，维护成本集中在主仓库维护者身上。
- PHP 官方包把 Intelephense 打进包里再分发，而 Intelephense 许可证第 5(c) 条不允许再分发，这在法律上站不住。

## 决策

### 1. 插件进入独立社区仓库

两个插件各自一个仓库，结构与已有的 `lithe-plugin-lua` 相同：`<plugin-id>/plugin.json`、`scripts/package.mjs`、按 `v<版本>` 标签发布 GitHub Release 的工作流。包名为 `<go|php>-support-<版本>-darwin.zip`，Lithe Store 的 `lithe-plugin-index.json` 记录下载地址和 SHA-256。

社区 ID 使用 `io.github.lithe-idea.*` 命名空间，`vendor.signatureRequirement` 为 `none`。插件市场对社区插件按 SHA-256 和安装确认框管理信任，不需要 Lithe 私钥。

### 2. 旧官方 ID 保留在宿主目录里，但没有官方来源

`OfficialPluginCatalog`（宿主内置的官方插件目录，`BuiltInModuleCatalog.swift`）继续列出 `dev.lithe.plugin.go-support` 和 `dev.lithe.plugin.php-support`，签名要求仍是 `publisherPackage`。条目多了 `communityReplacementID`，记录替代它的社区 ID：

- `publishedEntries` 过滤掉已迁移条目。LSP 控制中心等“官方插件入口”只看这个列表，所以不会再引导用户安装旧包。
- `PluginMarketplace` 对已迁移 ID 不返回官方来源，也不列出它，即使客户端缓存里还有旧的官方索引。这样旧包不会出现“有更新”，卸载按钮照常可用。
- `PluginManagementView` 给已迁移的旧包显示迁移提示，写明新的社区 ID。

正确做法：保留旧 ID 的签名要求，只去掉它的来源。

不要这样做：直接从 `OfficialPluginCatalog` 删除旧 ID。删除后旧 ID 变成普通社区 ID，第三方源就可以发布一个不签名的 `dev.lithe.plugin.php-support` 冒充升级。（市场本身也会忽略第三方源里的 `dev.lithe.*`，但签名要求是最后一道防线。）

### 3. 用户手动迁移，不自动替换

新旧包声明同一个语言（`go` / `php`），也复用同样的语言模块 ID。同一语言只能有一个拥有者，而卸载要到下次启动才真正删除旧包：在那之前，旧包的模块仍然注册在当前进程里，社区包即使装上也会因语言冲突被拒绝。所以迁移顺序固定为“卸载旧包 → 重启 → 安装社区版 → 重启”：

- 插件市场在旧包还在磁盘上时，把社区版显示为“需先卸载旧版”，不允许安装（`blockedByRetiredPlugin`）；旧包已标记卸载时，直接给出“重启 Lithe”按钮。
- 插件管理页顶部在本次会话有待重启生效的插件变更时显示横幅和“重启 Lithe”按钮，效果和 IntelliJ IDEA 的“Restart IDE”一样。重启走正常退出流程：未保存文件和运行中进程照常确认，任何一步取消都不会重启。真正重新打开应用的是一个分离的辅助进程，它等待旧进程退出（最多 30 秒），然后用 `open` 打开同一个 app bundle；如果旧进程到时还没退出，`open` 只会激活它，不会再开第二个 Lithe。
- 卸载会停掉正在运行的模块，但这不等于用户关闭了它。卸载时只保留用户明确关闭过的模块（存储里是 `false`），其余模块的启用记录被清除，下一次确认安装（包括替代它的社区版）就会按“首次安装默认启用”的规则启用。否则旧版启用 → 卸载 → 安装社区版之后，社区版会继承卸载时写入的 `false`，装好了却是禁用的。

不做自动迁移，是因为社区包的信任模型不同（没有 Lithe 签名，需要用户在确认框里看过权限和程序），宿主不能替用户点这个确认。

LSP 控制中心对已迁移的语言单独给出引导：没装插件时提示从 Lithe Store 安装，旧包还在时提示先卸载并重启，有待重启的变更时附带“重启 Lithe”按钮。

### 4. PHP 插件改用用户安装的 Intelephense

社区版 PHP 的语言服务器是 `launch.kind: systemCommand`，命令为 `intelephense --stdio`，并声明 `runtimeDependencies: node`。宿主照常发现 Node 并导出 `LITHE_NODE_PATH`，再把 Node 所在目录放到 PATH 最前面，这样从 Dock 启动时 npm 全局安装的 `intelephense` 脚本也能找到 `node`。没有安装时，LSP 状态显示缺少工具，而不是崩溃。

### 5. 主仓库的残留

- `Plugins/mac/Official/` 只剩随应用发行的 Java Support。Go/PHP 最后一版官方 `plugin.json` 移到 `macos/Tests/LitheTests/Fixtures/RetiredOfficialPlugins/`，只给宿主测试使用。
- `Plugins/marketplace/official-plugins.json` 和 `index.json` 为空。官方插件发布流程（`build-official-plugins.sh`、`official-plugin-releases.mjs`、`release-official-plugins.yml`）保留给以后的官方插件，测试改用合成的样例插件。
- `scripts/prepare-php-language-server.sh` 和 `php-language-server-downloads` 工作树资源一并删除。
- Windows 的 `Plugins/win/Official/PhpSupport` 是另一套 Worker 包格式，这次不动。

## 考虑过的备选方案

1. 继续作为官方插件，只把源码搬到独立仓库：仍需要 Lithe 私钥签名和官方索引，维护负担没有减轻，也没有解决 Intelephense 再分发的问题。
2. 沿用旧 ID `dev.lithe.plugin.*-support` 发布社区版：用户无需迁移，但 `dev.lithe.*` 是官方保留命名空间，社区源里的这类条目会被市场忽略；放开限制等于允许任何源冒充官方插件。
3. 启动时自动卸载旧包并安装社区包：省去用户操作，但跳过了社区插件必须由用户确认的权限和程序审查，也会在后台下载代码。
4. 社区版继续打包 Intelephense：开箱即用，但违反其许可证。也考虑过换用可再分发的 phpactor，它的启动参数和运行依赖不同，需要单独验证，留给以后。

## 后果

Go/PHP 插件可以独立迭代和发布，不占用主仓库 CI，也不需要 Lithe 私钥。主仓库少了语言服务器下载和组装脚本。

代价：

- 已安装旧官方包的用户需要手动卸载再安装一次；旧包不会再收到更新。
- PHP 用户必须自己安装 Intelephense 和 Node.js，首次使用多一步。
- 社区包没有 Lithe 签名，信任来自 Lithe Store 的审核、SHA-256 和安装确认框。
- 旧 ID 要一直保留在 `OfficialPluginCatalog` 里，直到确认没有用户再装着旧包。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'PluginMarketplace|PluginManager|PluginManagementPresentation|PluginPackageStore|ApplicationRelauncher'`：已迁移 ID 不出现在官方列表、没有官方来源和更新、可以卸载，旧 ID 仍要求 publisher 签名；旧包未删除前社区版不可安装；启用的旧包卸载、重启后安装替代包会启用，用户关闭过的保持关闭；重启辅助进程的等待有上限且不会多开实例。
- `node --test scripts/official-plugin-releases.test.mjs`：官方插件配置为空时发布计划为空，发布流程用合成插件继续可测。
- `node scripts/test-official-plugin-distribution.mjs`：应用内置名单只含 Java Support。
- `node scripts/test-reuse-worktree-resources.mjs`：已删除的 PHP 下载资源不再出现在复用清单里。
- `./scripts/verify-platform-feature-matrix.sh`：Go/PHP 功能矩阵的证据路径指向迁移后的文件。
- `./scripts/verify-agent-notes.sh`：本笔记格式和路径有效。
- 社区仓库各自的 CI 打包并校验 `plugin.json`；Lithe Store 仓库的索引校验脚本（`validate-index.mjs --verify-archives`）校验索引条目和下载包哈希。

## 适用范围

- `macos/Sources/LitheModuleAPI/Catalog/BuiltInModuleCatalog.swift`
- `macos/Sources/Lithe/Application/Features/PluginMarketplace.swift`
- `macos/Sources/Lithe/Views/App/PluginManagementView.swift`
- `macos/Sources/Lithe/Views/Language/LSPControlCenterView.swift`
- `macos/Sources/Lithe/Views/App/ApplicationRestartAction.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacApplicationRelauncher.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift`
- `macos/Tests/LitheTests/Fixtures/RetiredOfficialPlugins/`
- `Plugins/mac/README.md`
- `Plugins/marketplace/`
- `scripts/official-plugin-releases.mjs`
- `scripts/build-official-plugins.sh`
