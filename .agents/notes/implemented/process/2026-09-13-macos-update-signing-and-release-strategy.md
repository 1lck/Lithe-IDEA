# Agent 笔记：macOS 应用内更新的签名与发布策略

状态：已实现

## 先说结论

更新包和独立官方插件包的真实性分别由 Sparkle EdDSA 与 Lithe Ed25519 签名保证，Developer ID 签名是可选的分发能力，不是这两类内容信任的唯一依据。stable 和 preview 完全隔离，回滚和插件安装只接受内置公钥信任的内容，避免测试版本或伪造清单影响正式用户。

## 问题

macOS 应用需要在没有强制要求 Apple Developer 账号的前提下，安全地
分发全量更新和差分更新，同时支持 stable 和 preview 两条并行的发布
节奏，并在用户从 preview 主动回到 stable 时保证不会被伪造的更新
manifest 欺骗。这些约束需要在发布工作流和客户端安装器两侧做出明确
取舍，而不是照抄 Sparkle 文档默认值。

## 决策

使用 Sparkle 2.10.0 处理应用内更新。Sparkle 拥有计划检查、跳过版本、
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

### 独立官方插件包

PHP Support 作为独立 GitHub Release asset 发布，不再把“能否使用 Developer ID
证书”当成是否生成插件包的条件。构建阶段先完成原生 bundle 的代码签名，再由
`LithePluginPackageSigner` 使用 `LITHE_PLUGIN_PACKAGE_PRIVATE_KEY` 为包内每个文件
生成 SHA-256 清单和 Ed25519 签名；签名文档本身不进入被签名文件列表，避免验证时
出现自引用。Lithe 内置 `lithe-official-plugins-v1` 公钥，安装时先验证原生 bundle，
再验证完整包清单、插件 ID 和版本，任一文件被替换都会拒绝安装。

本分支的 stable 工作流仍需配置 repository secret
`LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`。它是与客户端内置公钥匹配的 base64 编码 32 字节
Ed25519 私钥；私钥只在构建 runner 的标准输入中使用，不能写入仓库、release
asset 或日志。公钥轮换需要先发布能识别新 key ID 的客户端，再更新 secret 并
重新生成包，不能只替换 GitHub secret。

Preview 应用工作流不构建或重签独立插件包，也不注入插件私钥。当前 `preview`
源码已把 PHP/Go 插件交给组织仓库独立发布，个人仓库的旧插件私钥与其 v2 公钥
不匹配；继续在应用发布中签插件会触发 `SignerError.untrustedPrivateKey`，阻止
本来已成功打包的应用发布。AutoBuild 只把已发布 ZIP 原字节镜像到应用 release，
先验证固定索引的 SHA-256，再附加 checksum sidecar。应用更新继续使用原有
Sparkle 密钥，不通过替换该密钥或放宽插件验签来恢复构建。

每天的定时任务从默认分支 `main` 读取工作流，再检出 `preview` 源码，因此
删除插件私钥检查、独立插件构建及其两处上传步骤的修复必须合入 `main`。
只修改 `preview` 工作流不能修复下一次定时任务；只删除构建而保留上传也会
因缺少插件包继续失败。手动运行时，`--ref` 选择工作流版本，`source_branch`
只选择源码。恢复后的发布应确认两个 macOS 架构、Windows 构建与 publish job 全部成功。

### 全量与差分双轨发布

stable 工作流继续发布 DMG + SHA-256 + `latest-macos.json` 供旧客户端
和 Homebrew 使用，同时按架构额外发布签名 zip、`appcast-<arch>.xml`
（含完整归档 enclosure 和可用 delta）与带架构后缀的 `.delta` 资源。
生成器从 GitHub Release 中按语义版本挑选最多三个较早的稳定版本作为
差分基线（排除 preview/draft/当前/更新版本）；缺少基线时只生成全量
feed，Sparkle 生成不出有效 patch 时也会省略该 delta 并回退到全量
归档。GitHub Release 的 zip 是差分基线的持久化来源，发布后必须保留。

选中的基线下载失败不能当作“没有基线”跳过。`download-sparkle-baseline.mjs`
为每个归档最多尝试三次，每次 `gh` 下载限时 120 秒，重试前分别等待 2 秒和
4 秒；只重试超时、暂时性网络错误和 HTTP 408/429/5xx，永久错误或耗尽重试
都终止发布。每次尝试独占系统临时目录中 `archives/.baseline-<attempt>/`，
只有下载成功且非空才移入同次发布的归档输入；失败或取消先结束所属进程，
再删除 staging（未完成下载的暂存目录），外层脚本退出时清理整个临时目录。
这些资源绑定选定仓库、tag、渠道和架构，没有可靠的工作树复用身份 stamp，
任何阶段都不得跨工作树复制，也不写已安装 app。成功下载仍须通过原有
Sparkle 处理和发布校验，不改变签名、哈希或 appcast 的接受条件。

稳定版 macOS build job 总期限为 75 分钟，打包步骤为 35 分钟，Sparkle
步骤为 30 分钟，为双架构打包和有界下载重试留出预算。Preview 工作流的
期限不变；上述下载保护位于两个渠道共用的发布脚本内。

### Stable 与 Preview 完全隔离

AutoBuild 使用独立的 `LitheUpdateChannel=autobuild`（兼容读取旧 `preview`）、独立的
`appcast-preview-<architecture>.xml`、独立的 `SUDefaultsDomain`
后缀（`app.lithe.desktop.sparkle.stable` /
`.autobuild`）。两个渠道共用同一把 EdDSA key，但跳过版本和自动检查
偏好不跨渠道迁移，也不提供渠道选择器或自动切换——用户从 preview
返回 stable 是显式操作。Build 号使用 UTC `YYYYMMDD.HHMMSS`，例如
`20261015.124354`。prepare 只采样一次 UTC，同秒生成 compact build 与标准 ISO
时间 `2026-10-15T12:43:54Z`，全部平台共享。新发布必须严格晚于双架构已有
appcast 的 `pubDate` 且数值 build 递增；同秒重复或时钟倒退直接拒绝，不能补计数。
旧 `58.1` 只兼容作为历史基线，新发布不能再使用计数身份。部分发布失败后应
重跑全部 job 取得更晚身份；只重跑 publish 不会产生新的构建时间。

### AutoBuild 固定入口与最新资源清单

应用公开发布固定使用大小写精确的 `AutoBuild` tag；title 与正文均显式显示
`AutoBuild — 构建自 YYYY-MM-DD HH:mm:ss UTC`。公开渠道为 `autobuild`，基础设施
兼容旧 `preview` 开关与 appcast 文件名。保留原工作流文件，身份顺序完全来自 UTC
构建时间，与工作流计数无关。prepare 一次固定源码 SHA、版本、build 与时间；
macOS 双架构和 Windows 复用工作流共同消费这些输入。Windows 只产出 artifact，
没有独立定时任务或 release 写权限，publish 等待三个平台全部完成，并逐项检查
artifact identity（包括时间）及 build/ISO 精确对应，避免把不同源码或 build 的安装包混在同一个入口。

定时任务从 main 使用受审查的工作流；publish 按 `github.workflow_sha` 检出
helper，再从 prepare 的 preview SHA 用 `git fetch/show` 读取官方插件 registry
和 index，不能从 preview 工作树加载未受本次工作流审查的发布代码。按数值语义
版本选择每个注册可下载插件的最新版本，保留所有下载变体并去重；只接受固定索引
里 `Lithe-IDEA` 组织 GitHub Release 的 ZIP。当前 PHP/Go 为 1.0.0，内置 Java
不属于镜像。canonical URL 和索引不变，应用 release 只提供手动下载镜像。

正确做法是下载上游已签名 ZIP，验证索引 SHA-256，再生成 `.sha256` 并上传；
错误做法是在应用工作流重建插件、注入旧私钥或把索引 URL 改指向个人仓库。
镜像 staging 绑定源码 SHA、固定索引、release/tag/asset 和本次调用，位于
`<RUNNER_TEMP>/lithe-autobuild-<invocation>/{marketplace,plugins,baselines,verification}/`；
没有可复用 identity stamp，通用排除路由拒绝跨工作树复制。每个子进程限时
120 秒，暂时性故障最多三次尝试，重试前删除本次下载残片，`finally` 删除本次
创建的精确临时目录。baselines 是本次从 AutoBuild 下载的架构 appcast；初次迁移
尚无 AutoBuild 时读取旧 `preview-0.3.0` 的 appcast。它们只供严格时间排序校验；
不可跨工作树复用，已有 ZIP 却缺少 feed 或 feed 损坏都拒绝发布。
这里只处理发布期资源，不改运行时 app bundle、代码签名
或 Sparkle 差分基线。

完整目标清单只有最新 macOS DMG、Windows 安装包及 checksum、当前 build 的
完整 ZIP/目标 delta/feed、每个官方可下载插件的最新 ZIP 变体及 checksum。
发布器先验证本地输入、全部插件哈希和已有双架构 appcast 的时间顺序，再上传
所有数据，最后替换 XML。compact 历史 build 必须与 pubDate 一致，旧计数基线
仍验证 pubDate；缺少整个历史入口才允许首次发布。远端清单
必须逐个通过 asset SHA-256 digest 验证，缺失 digest 时有界下载并校验。之后
显式 force PATCH `git/refs/tags/AutoBuild` 指向源码 SHA，更新并复查 release
元数据，才按完整清单清理所有旧资产，包括旧版本 DMG、Windows 安装包和插件。
`gh release edit --target` 本身不会移动已存在 tag，不能用它替代 Git ref 更新。
下载、哈希、上传或清单校验失败均不清理旧资源，不能在上传前先清空 release。

GitHub 固定 tag 的多文件替换不是原子操作，失败可能留下部分新文件；不承诺
历史缓存 feed URL 一直有效。只有最新完整 ZIP 留作下次差分基线，旧客户端重新
检查后可使用全量包。AutoBuild 全部发布、校验和清理成功之后，才删除
`preview-0.3.0` release 与 tag；旧客户端需要手动重装一次，不保留第二兼容入口。
Stable 和组织插件 release 不受清理影响。release 风险说明使用中英双语，明确
普通用户应使用 Stable，自动构建可能包含缺陷或造成数据丢失。

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
  同一次 prepare 的 UTC 秒），只重跑发布 job 无法产生更晚构建时间，
  已替换 feed 后会被严格递增检查拒绝，因此重跑全部 job 才生成新身份。
- **保留工作流计数作为新身份权威或同秒追加计数**：会让构建展示时间和排序身份
  分裂，也不能表达用户需要的 UTC 时间顺序，因此只保留旧计数基线读取。
- **基线下载失败就发布不含该 delta 的全量 feed**：可提高表面成功率，
  但会把网络故障误判为基线不存在，悄悄减少可用差分更新；改用有界的
  暂时性错误重试，永久失败仍阻止发布。
- **回滚客户端信任下载 manifest 里携带的公钥**：实现更灵活，manifest
  format 升级时不需要客户端预置新 key。但这等于让一次网络请求决定
  信任锚点，一旦 manifest 分发被劫持就可以伪造回滚目标，因此回滚
  只信任客户端内置的 `SUPublicEDKey`。
- **更新器在安装后自动清除下载文件的 quarantine 属性**：能让用户
  少点一次 Gatekeeper 提示。但这本质上是绕过 macOS 的下载来源追踪
  机制，属于安全职责之外的东西，因此明确不做，交由既有的可信来源
  恢复步骤处理。
- **要求插件使用 Developer ID 或与宿主同 Team ID 签名**：能复用 Apple
  的代码签名身份，但会让没有证书的发布环境无法生成独立包，也无法表达“包由
  Lithe 发布者签发”的信任关系，因此改用包级 Ed25519 清单，同时保留 bundle
  的原生代码签名校验。

## 后果

- 贡献者不需要 Apple Developer 账号就能产出可验证来源的差分更新，
  Developer ID 签名和公证仍可作为独立环节按需加入。
- 暂时性基线下载故障可在本次运行恢复，代价是失败归档最多占用三次
  下载期限和两次退避等待；持续故障仍需修复或重跑，不能用超长等待掩盖。
- Stable 和 Preview 用户互不干扰对方的更新节奏和偏好，代价是用户
  从 Preview 切换回 Stable 需要一次显式操作，且可能需要重新设置
  更新检查偏好。
- 最新资源清单阻止安装包、插件和 Sparkle 历史无限累积；代价是旧缓存 feed
  可能引用已删除文件，旧客户端需重新检查并使用全量更新，迁移旧 tag 还需一次
  手动重装。固定 tag 多文件更新不具原子性，失败后必须修复并重跑全部构建。
- 回滚路径的安全性依赖客户端内置公钥永不改变；如果需要轮换
  `SPARKLE_PRIVATE_KEY`，替换 repository secret 本身不够，必须单独
  规划迁移（重签或双签过渡期），否则旧客户端会拒绝新签名的更新。
- 独立插件包的安装安全性同样依赖客户端内置的 publisher 公钥；没有匹配 secret
  的 release 构建会失败，普通 debug 构建会跳过需要 publisher 签名的 PHP 包，
  指定单个 PHP 包构建时也会失败。这样构建目录中不会留下缺少
  `lithe-plugin-signature.json` 的伪成功包；只有提供私钥的构建才会生成可交给
  包级验签路径的产物。
- 需要重新评估的触发条件：如果需要历史版本下载、缓存 feed 长期兼容或更多
  更新渠道，必须明确另建版本化存储与迁移方案，不能悄悄恢复 AutoBuild 历史积累。

## 验证

```bash
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'StableRollbackTests|UpdateCheckerTests|UpdateManifestTests'
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --max-seconds 60 -- --filter StableRollbackDiskImageIntegrationTests
./scripts/test-macos.sh
./scripts/verify-macos-package.sh
./scripts/verify-official-plugins.sh
sparkle_tools=$(zsh scripts/prepare-sparkle-tools.sh)
ruby scripts/test-sparkle-update.rb "$sparkle_tools"
node scripts/test-download-sparkle-baseline.mjs
node --test scripts/test-publish-autobuild.mjs
node scripts/test-reuse-worktree-resources.mjs
actionlint .github/workflows/release-macos.yml .github/workflows/release-preview-macos.yml .github/workflows/release-preview-windows.yml .github/workflows/ci-macos.yml
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
- `scripts/create-sparkle-update.sh`
- `scripts/publish-autobuild.mjs`
- `scripts/test-publish-autobuild.mjs`
- `scripts/worktree-resources.json`
- `scripts/reuse-worktree-resources.mjs`
- `scripts/download-sparkle-baseline.mjs`
- `scripts/test-download-sparkle-baseline.mjs`
- `scripts/verify-macos-package.sh`
- `scripts/test-sparkle-update.rb`
- `scripts/create-macos-update-manifest.rb`
- `.github/workflows/release-macos.yml`
- `.github/workflows/release-preview-macos.yml`
- `.github/workflows/release-preview-windows.yml`
- `scripts/build-official-plugins.sh`
- `macos/Sources/LithePluginPackageSigning/`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginPackageStore.swift`
- `docs/architecture/macos-updates.md`
