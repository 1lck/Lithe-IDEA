# Agent 笔记：macOS 应用内更新的签名与发布策略

状态：已实现

## 先说结论

更新包的真实性由 Sparkle 的 EdDSA 签名保证，Developer ID 签名是可选的分发能力，不是更新信任的唯一依据。stable 和 preview 完全隔离，回滚只接受内置公钥信任的更新，避免测试版本或伪造清单影响正式用户。

## 问题

macOS 应用需要在没有强制要求 Apple Developer 账号的前提下，安全地
分发全量更新和差分更新，同时支持 stable 和 preview 两条并行的发布
节奏，并在用户从 preview 主动回到 stable 时保证不会被伪造的更新
manifest 欺骗。这些约束需要在发布工作流和客户端安装器两侧做出明确
取舍，而不是照抄 Sparkle 文档默认值。

## 决策

使用 Sparkle 2.9.6 处理应用内更新。Sparkle 拥有计划检查、跳过版本、
下载进度、取消、归档校验、安装和 relaunch；Lithe 只负责在 Sparkle
请求终止时确认未保存文档并限时关闭。

### 签名与账号要求解耦

更新真实性由 Sparkle 的 EdDSA 签名保证，不依赖 Apple Developer ID：
`SPARKLE_PUBLIC_KEY`/`SPARKLE_PRIVATE_KEY` 是必需的，三个 Developer
ID 签名设置（`MACOS_SIGNING_IDENTITY`/`_CERTIFICATE`/`_PASSWORD`）是
可选且必须一起配置。没有 Developer ID 证书时继续使用 ad-hoc 签名 +
EdDSA 验证更新来源；配置了 Developer ID 时该身份只在构建期导入临时
runner keychain，用后即删。Developer ID 签名不等于公证，也不保证
Gatekeeper 首次运行警告消失——这些是独立的发布关注点，更新器不自动
清除 quarantine。

### 全量与差分双轨发布

stable 工作流继续发布 DMG + SHA-256 + `latest-macos.json` 供旧客户端
和 Homebrew 使用，同时按架构额外发布签名 zip、`appcast-<arch>.xml`
（含完整归档 enclosure 和可用 delta）与带架构后缀的 `.delta` 资源。
生成器从 GitHub Release 中按语义版本挑选最多三个较早的稳定版本作为
差分基线（排除 preview/draft/当前/更新版本）；缺少基线时只生成全量
feed，Sparkle 生成不出有效 patch 时也会省略该 delta 并回退到全量
归档。GitHub Release 的 zip 是差分基线的持久化来源，发布后必须保留。

### Stable 与 Preview 完全隔离

Preview 使用独立的 `LitheUpdateChannel=preview`、独立的
`appcast-preview-<architecture>.xml`、独立的 `SUDefaultsDomain`
后缀（`app.lithe.desktop.sparkle.stable` /
`.preview`）。两个渠道共用同一把 EdDSA key，但跳过版本和自动检查
偏好不跨渠道迁移，也不提供渠道选择器或自动切换——用户从 preview
返回 stable 是显式操作。Build 号使用
`<workflow run number>.<run attempt>`，重跑失败的 run 会产生新的
身份，即使展示版本不变；只重跑发布 job 不受支持，必须重跑全部 job
才能分配新身份，防止一个陈旧或重复的 build 顶替 feed。

发布前清理会保留最近 30 个 build 身份（含失败尝试）、当前已发布和
即将发布 feed 引用的全部文件，以及每个架构最新三个 zip 基线，其余
Preview zip/delta 一律删除；不触碰 Windows 等无关资产。清理在任何
DMG/更新上传之前执行，且如果清理后剩余资产加新文件会超过 900（低于
GitHub 1000 资产上限留出余量）就拒绝本次发布，下载/解析失败会在
删除前终止清理。这把"缓存 feed 兼容性"的保证范围限定为最近 30 个
build，而不是按天数保证。

### 从 Preview 回到 Stable 只走全量、且不信任下载来源的 key

Preview 的 Return to Stable 路径永远下载完整 DMG，不请求 delta，
因为这条路径需要兼容 Sparkle 迁移之前发布的旧 stable 版本。stable
发布器会用 `SPARKLE_PRIVATE_KEY` 单独签名每个全量 DMG 并写入
`latest-macos.json` 的 `edSignature` 字段（schema-1 新增字段，旧
客户端会忽略）；回滚客户端要求这个签名存在，并且只用**自己内置的**
`SUPublicEDKey` 验证，绝不接受下载 manifest 中携带的 key。没有
`edSignature` 的历史 DMG 会被自动回滚拒绝，只提供手动安装入口，
不重签发布内容来"修补"旧版本。

安装阶段校验 manifest SHA-256、DMG Ed25519 签名、app 代码签名、
bundle identifier、展示版本、可执行文件架构、渠道和最低系统版本
之后才在目标卷暂存 app；Sparkle 不支持降级安装，所以这条回滚路径
使用独立的 helper 而不是 Sparkle 的安装器，helper 最多等待 120 秒
原进程退出且从不强杀，失败时把已重命名的原 app 恢复。

## 考虑过的备选方案

- **要求 Apple Developer ID 证书才能发布更新**：能让应用在首次运行
  时通过 Gatekeeper 而无需用户手动信任。但会把无法负担或暂未注册
  Developer 账号的贡献者挡在发布流程之外，因此改为 EdDSA 签名验证
  更新来源，Developer ID 签名作为可选的三项一起配置的设置，不阻塞
  发布。
- **preview 和 stable 共用同一个 Sparkle feed 和默认值域，只靠版本
  号区分**：实现更简单，不需要额外的 build 号方案或偏好域名后缀。
  但会导致 preview 的跳过版本/自动检查偏好污染 stable，且用户可能
  在不知情的情况下从 preview 收到 stable 更新或反之，因此两个渠道
  使用独立 appcast、独立更新域和显式的 Return to Stable 操作。
- **preview 发布只重跑发布 job 以节省 CI 时间**：能加快失败重试。
  但发布 job 需要一个和 build job 一致的身份（build 号绑定
  workflow run number/attempt），只重跑发布 job 会让身份和实际构建
  内容不一致，因此要求重跑全部 job 才分配新身份。
- **回滚客户端信任下载 manifest 里携带的公钥**：实现更灵活，manifest
  format 升级时不需要客户端预置新 key。但这等于让一次网络请求决定
  信任锚点，一旦 manifest 分发被劫持就可以伪造回滚目标，因此回滚
  只信任客户端内置的 `SUPublicEDKey`。
- **更新器在安装后自动清除下载文件的 quarantine 属性**：能让用户
  少点一次 Gatekeeper 提示。但这本质上是绕过 macOS 的下载来源追踪
  机制，属于安全职责之外的东西，因此明确不做，交由既有的可信来源
  恢复步骤处理。

## 后果

- 贡献者不需要 Apple Developer 账号就能产出可验证来源的差分更新，
  Developer ID 签名和公证仍可作为独立环节按需加入。
- Stable 和 Preview 用户互不干扰对方的更新节奏和偏好，代价是用户
  从 Preview 切换回 Stable 需要一次显式操作，且可能需要重新设置
  更新检查偏好。
- 资产保留策略把"能提供差分更新"的窗口从"发布以来的全部版本"收窄
  到"最近 30 个 build"，旧到超出窗口的 Preview 客户端会退回到全量
  下载而不是 delta，这是为了不撞到 GitHub 的资产数量上限。
- 回滚路径的安全性依赖客户端内置公钥永不改变；如果需要轮换
  `SPARKLE_PRIVATE_KEY`，替换 repository secret 本身不够，必须单独
  规划迁移（重签或双签过渡期），否则旧客户端会拒绝新签名的更新。
- 需要重新评估的触发条件：如果差分更新的资产数量随架构或渠道增多
  逼近 900 的清理阈值，或者需要支持两个以上的更新渠道，当前基于
  "30 个 build + 3 个 zip 基线"的保留规则需要重新设计。

## 验证

```bash
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'StableRollbackTests|UpdateCheckerTests|UpdateManifestTests'
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --max-seconds 60 -- --filter StableRollbackDiskImageIntegrationTests
./scripts/test-macos.sh
./scripts/verify-macos-package.sh
sparkle_tools=$(zsh scripts/prepare-sparkle-tools.sh)
ruby scripts/test-sparkle-update.rb "$sparkle_tools"
actionlint .github/workflows/release-macos.yml .github/workflows/release-preview-macos.yml .github/workflows/ci-macos.yml
```

本地 Sparkle 集成检查创建一次性 ad-hoc 签名 fixture，覆盖全量
bootstrap、连续版本差分生成、逐字节 patch 应用、代码签名完整性、
损坏后 EdDSA 拒绝、按架构区分的 delta 命名、签名 feed 和全量回退
metadata；不安装或启动 Lithe，也不使用生产凭据。正式发布前仍需要
在两个架构上实测真实签名版本：旧版 DMG 升级到首个 Sparkle 版本、
Sparkle 版本间升级、缺失/损坏的 delta、下载中断、权限不足、取消
授权，以及带未保存文档时取消终止；本地 fixture 检查不能替代这些
安装测试。配置步骤、发布工作流细节和逐步操作说明见
[`macos-updates.md`](../../../../docs/architecture/macos-updates.md)。

## 适用范围

- `scripts/prepare-sparkle-tools.sh`
- `scripts/verify-macos-package.sh`
- `scripts/test-sparkle-update.rb`
- `scripts/create-macos-update-manifest.rb`
- `.github/workflows/release-macos.yml`
- `.github/workflows/release-preview-macos.yml`
- `docs/architecture/macos-updates.md`
