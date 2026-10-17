# Agent 笔记：发布签名密钥重置

状态：已实现

## 先说结论

原发布仓库的私钥无法找回，因此新仓库生成并配置了一套新的 Sparkle、Windows 更新器和官方插件包签名密钥。新密钥只保存在受保护的本机备份和 GitHub Actions Secrets 中，公钥分别作为构建变量或客户端信任锚点使用。

这次操作会切换信任根：使用旧公钥构建的客户端不会自动接受新密钥签名的更新或官方插件包。`v0.6.0` 的正式构建必须使用包含新插件公钥的源码，并在发布前明确接受旧客户端无法自动更新的限制。

## 问题

原仓库的 `SPARKLE_PRIVATE_KEY`、`TAURI_SIGNING_PRIVATE_KEY` 和 `LITHE_PLUGIN_PACKAGE_PRIVATE_KEY` 无法从 GitHub 读取，也没有在本机环境中找到备份。GitHub Secrets 是只写不可读的，随机占位值无法生成可被客户端验证的发布物。

## 决策

- 使用 Sparkle 2.10.0 的固定工具生成新的 Sparkle Ed25519 密钥，并把私钥配置为 `SPARKLE_PRIVATE_KEY`，公钥配置为 `SPARKLE_PUBLIC_KEY`。
- 使用 Tauri signer 生成新的密码保护更新器密钥，并把私钥及密码配置为 `TAURI_SIGNING_PRIVATE_KEY` 和 `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`，公钥配置为 `TAURI_UPDATER_PUBLIC_KEY`。
- 使用 CryptoKit 生成新的官方插件包 Ed25519 密钥。私钥配置为 `LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`，源码内置信任公钥改为 `lithe-official-plugins-v2`。
- 发布账号通过仓库变量 `LITHE_RELEASE_ACTOR` 明确配置，不再依赖组织名与执行账号必须相同；初次轮换时为 `xiaoyumuxi`，本次经授权的 0.6.0 重建发布使用有仓库管理权限的 `Mucheen`。自 0.6.1 起该变量是逗号分隔、不带空格的账号名单（例如 `Mucheen,xiaoyumuxi`），工作流按完整账号名匹配，名单内任一账号都可以触发发布；单个账号的旧写法仍然有效。
- 组织仓库密钥轮换只适用于组织发布的应用与插件。个人仓库恢复后，应用发布、更新、回退稳定版和 Homebrew 使用 `1lck/Lithe-IDEA`，继续读取个人仓库原有 Sparkle/Tauri Secrets 和公钥变量；不能把组织公钥或私钥覆盖过去，否则既有个人版客户端无法验证更新。
- 插件市场、官方插件下载与插件 v2 公钥继续使用组织仓库。`release-official-plugins.yml` 的发布和索引写入任务只允许在 `Lithe-IDEA/Lithe-IDEA` 运行，个人仓库保留 PR 校验，不重复发布插件或依赖个人仓库的插件私钥。
- Homebrew 从应用发布仓库的默认分支更新，下载 URL、版本和 SHA-256 必须来自同一仓库。更新脚本同时改 URL 和校验值，不能把个人包校验值配上组织包地址。正确做法是个人预发布版回退到个人签名的稳定版；不能下载组织稳定版再用个人公钥验签。
- 两条正式发布工作流支持 `publish=false` 的完整预检。先完成打包、客户端公钥验签和临时目录内安装启动验证，再合并准备 PR、重建标签并发布；预检不得写 GitHub Release 或 Homebrew 分支。
- Sparkle 使用 Node 的 Ed25519 加密实现验证 DMG 和 appcast 中的每个归档；Tauri 使用上游 minisign 验证更新器签名。插件仍由既有签名工具按内置 v2 公钥验证，不能只检查签名文件存在。
- Developer ID 和 Authenticode 证书没有伪造配置；它们仍是独立的可选签名材料。

私钥不得提交到仓库、写入 release asset、输出到日志或发送到聊天。新密钥的本机备份位于受保护目录，正式发布前必须再复制到离线密码管理器或加密备份。

## 考虑过的备选方案

- **写入随机字符串作为 Secrets**：否决。字符串不能与客户端内置公钥配对，工作流即使越过空值检查，更新器和插件验签仍会失败。
- **从 GitHub 读取旧 Secrets**：不可行。GitHub 不提供 Secrets 原值导出；只能从维护者备份或原运行环境恢复。
- **只替换 GitHub Secrets，不修改客户端公钥**：否决。新签名会被旧客户端拒绝，插件包的 `keyID` 也无法表达密钥轮换。
- **继续复用 `lithe-official-plugins-v1` 的 key ID**：否决。新公钥使用 `lithe-official-plugins-v2`，避免把不同信任根伪装成同一发布者密钥。

## 后果

新构建的 macOS 更新、Windows 更新器和官方插件包使用新的信任根。旧版本客户端不会自动接受这些内容；在没有双签或迁移版本的情况下，用户需要手动安装新版本。这个代价已被当前“旧密钥完全丢失”的事实接受，不能把新版本宣传为对旧客户端透明的普通更新。

`v0.6.0` 既有 tag 指向密钥重置前的源码，不能直接用新的插件私钥重跑而不更新源码。发布前必须使用包含 `lithe-official-plugins-v2` 的 release ref，并重新验证 release notes、插件验签、Sparkle manifest 和 Windows `latest.json`。

## 验证

- 用 `gh secret list --repo Lithe-IDEA/Lithe-IDEA` 仅确认 Secret 名称存在，不读取 Secret 值。
- 用 `gh variable list --repo Lithe-IDEA/Lithe-IDEA` 确认公钥变量和发布账号变量存在。
- 运行 `./scripts/verify-agent-notes.sh`。
- 运行 `node --test scripts/verify-release-signature.test.mjs`，确认篡改文件、错误公钥和截断签名被拒绝。
- 发布工作流安装到独立临时目录，验证版本、公钥、启动及安装目录 SHA-256 清单不变，并有界终止自身应用进程、卸载或删除临时安装。
- 发布前运行 `./scripts/verify-official-plugins.sh`、`./scripts/verify-macos-package.sh` 和 Windows 更新器对应测试。
- 在真实发布前完成旧版本到新版本的安装、Sparkle 验签、Tauri 更新器验签和官方插件安装验证；普通 CI 成功不能替代这些检查。

## 适用范围

- `macos/Sources/LithePluginPackageSigning/PluginPackageSignature.swift`
- `.github/workflows/release-macos.yml`
- `.github/workflows/release-windows.yml`
- `docs/architecture/macos-updates.md`
- `docs/releases/windows-updater.md`
- `Plugins/mac/README.md`
