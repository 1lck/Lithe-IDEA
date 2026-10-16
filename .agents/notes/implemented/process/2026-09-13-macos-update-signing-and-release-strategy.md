# Agent 笔记：macOS 应用内更新的签名与发布策略

状态：已实现

## 先说结论

更新包和独立官方插件包的真实性分别由 Sparkle EdDSA 与 Lithe Ed25519 签名保证，Developer ID 签名是可选的分发能力，不是这两类内容信任的唯一依据。正式版与旧共享身份客户端默认选择正式版，用户确认风险后才能选择从 preview 分支构建的 AutoBuild；独立安装的 `Lithe-Dev` 首次启动默认使用 AutoBuild。两个渠道跨版本安装和回滚不混用版本比较规则。AutoBuild 以统一 UTC 构建时间作为更新身份，界面显示“构建自”时间，回滚和插件安装仍只接受内置公钥信任的内容。

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
出现自引用。初始版本内置 `lithe-official-plugins-v1` 公钥；密钥重置后的版本改用 `lithe-official-plugins-v2`，安装时先验证原生 bundle，
再验证完整包清单、插件 ID 和版本，任一文件被替换都会拒绝安装。

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

客户端信任的是一张“key ID → 公钥”的表（`trustedPublisherKeysBase64`），
验签时按签名文档里的 `keyID` 选公钥，签名内容也绑定这个 `keyID`。这样以后轮换
密钥可以先把新 key ID 加进表里、让新旧客户端并存一段时间，而不是像
v1→v2 那次一样让旧包立刻失效。同一个 key ID 永远不能换成另一把公钥；签名工具
只会用表里存在的 key ID 签名。

### 本地开发包（只限 debug 构建）

插件作者在本地调试时拿不到发布私钥。为此 debug 构建允许“从磁盘安装”一个
**完全没有签名文档**的包，并在 `installation.json` 里把来源记为
`localDevelopment`，插件管理页会标出“未签名的开发包”。规则只有三条：

1. 只有 debug 构建（`#if DEBUG`）接受这种来源；release 构建读到它会明确报
   “只有开发版能加载”，不会加载代码。
2. 只有宿主信任策略要求发布签名（`publisherPackage`）的插件才可能是开发包。
   按团队签名信任的插件（`sameTeamAsHost`，随宿主 app 内置的插件）本来就不带签名文档，
   从磁盘安装时保持普通来源，不会被误标成开发包、也不会因此被 release 拒绝。
3. 包里只要存在 `lithe-plugin-signature.json`，无论安装来源和签名要求是什么都必须
   验签通过；`sameTeamAsHost` 包验签后仍要做原有的团队检查。开发来源不能用来
   绕过一个坏掉或伪造的签名。
4. 原生 bundle 的代码签名仍然必须有效（ad-hoc 签名即可）。

安装来源按**每个已安装版本**记录（`origin` 和 `previousOrigin`），回滚时用目标
版本自己的来源验证。例如先装开发包 0.3.0、再装正式签名的 0.3.1，回滚到 0.3.0
时按开发包规则验证，而不是误用 0.3.1 的“正式包”规则报缺少签名。

当前信任表只包含 `lithe-official-plugins-v2`：v1 私钥已无法找回，用旧客户端安装的
v1 包在新版本里仍会被拒绝，需要重新下载 v2 包。多 key 表是为以后的轮换准备的，
并没有恢复 v1 兼容性。

构建侧对应 `scripts/build-official-plugins.sh --development-unsigned`，只在 debug
配置下可用，用来在没有私钥时产出这种开发包；release 配置传入该参数会直接失败。

官方插件由组织仓库 `Lithe-IDEA/Lithe-IDEA` 的独立插件发布工作流使用
`LITHE_PLUGIN_PACKAGE_PRIVATE_KEY` 签名，该私钥必须匹配客户端内置 v2 公钥。
应用 stable/preview 工作流不再构建独立 PHP/Go 包，个人仓库不需要插件私钥即可
发布应用；个人仓库的插件发布和索引写入任务跳过，客户端仍从组织索引下载插件。
插件私钥不得写入仓库、release asset 或日志。公钥轮换需要先发布能识别新 key ID
的客户端，再更新 secret 并重新生成包，不能只替换 GitHub secret。

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

### 独立开发版身份与运行状态

AutoBuild 的安装产品名是 `Lithe-Dev`。macOS 在签名前将名称与 bundle identifier
（系统用于区分应用和偏好域的唯一标识）改为 `Lithe-Dev` 与 `app.lithe.desktop.dev`，
可执行文件仍为 `Lithe`；DMG 和 Sparkle ZIP 内使用 `Lithe-Dev.app`。Windows 的 Tauri
打包配置覆盖产品名与 `app.lithe.windows.dev` 标识，使安装器、WebView 存储和凭据分开。
公开下载资产继续使用原来的 `Lithe-*` 文件名，不改变工作流上传和下载协议。

macOS 运行时只按签名安装身份解析目录，不能按用户可变的更新渠道选择目录。
正式版保留历史设置域、`Application Support/Lithe`、`Caches/Lithe`、`Logs/Lithe`
与钥匙串服务；开发版在系统 Application Support、Caches、Logs 和临时根目录下
插入 `app.lithe.desktop.dev`，再由各服务追加原来的相对目录。数据库恢复文件、AI
凭据、插件及语言服务状态跟随平台存储适配器；绕过适配器的默认日志和本地凭据
也必须显式使用安装身份。Windows 常规目录及 Credential Manager（系统凭据管理器）
按 Tauri 标识解析；开发版降级日志及配置仍使用带安装标识的临时子目录，正式版
保留历史临时路径。

这些状态由当前用户和安装身份持有，不按源码工作树区分；缓存和临时文件可由系统
清理。同一用户显式指定的项目、工具仓库和自定义日志目录仍允许共享；首次迁移不
继承自定义日志目的地。工作树资源清单将运行状态和迁移暂存登记为不可复用资源，
构建复制阶段始终拒绝，避免将敏感状态当作带版本校验的下载缓存。应用首次复制
属于用户配置迁移，与工作树构建资源复用是不同生命周期。运行时可写目录始终在
发行资源外，不改变签名或后续增量更新的源字节。

正确示例是从开发版 bundle ID 解析隔离目录，再在里面写数据库恢复文件；错误示例
是读取“当前选择 AutoBuild”来改目录，因为切换选项会突然改变正式版的数据位置。
只改显示名称也不可行：相同 bundle ID 仍共享系统偏好，硬编码路径及钥匙串也仍冲突。
首次启动 `Lithe-Dev` 时，平台入口必须先完成配置准备，再构造设置、工作区及窗口。
没有开发版用户数据时自动复制正式版的设置和工作区记录，写入版本化成功标记；
已有开发版设置或文件时保持原样，不做覆盖合并。仅修改渠道选项不会立即改读另一
套配置；复制发生在用户安装并首次启动独立开发版时，之后两版各自写自己的数据。

macOS 的 `MacDevelopmentProfileMigration` 筛选 `settings.*`、`lithe.*` 用户偏好，
并显式纳入数据库持久配置及自定义背景图片访问记录；已有开发版数据判定必须使用
同一集合，否则可能把仅保存数据库配置的开发版误判为空。背景选择和图片访问记录
一起复制，避免首次加载因缺少访问记录而清空选择。排除渠道、旧自定义日志目录及
插件待激活状态；Sparkle 设置不在白名单。持久文件
只复制本地 AI 凭据、Maven 偏好和插件市场来源；不搬运缓存、索引或插件运行时。
暂存目录 `.lithe-dev-profile-import-<transaction>` 位于用户 Application Support，
目录权限 0700、文件 0600；整个目录发布到开发版根后才提交偏好。根内的
`.stable-profile-import-v1.plist` 保存本次偏好快照，偏好域中的
`lithe.developmentProfileImport.v1` 表示完成。若文件已发布而偏好尚未提交，下次
启动使用同一快照继续，避免读取后来变化的正式版数据，提交成功后删除快照。
空的开发版目录不视为已有用户配置，发布时仅原子移除空目录；并发产生文件则保留并报错。
正常失败清理暂存，崩溃前
尚未发布的临时快照可能残留，但不会被当作现有开发版配置或构建缓存复用。

Windows 的 `profile_migration` 在 Tauri（原生窗口与 WebView 容器）创建任何窗口
之前准备数据。只复制 `settings.json`、`maven/*.json` 和 WebView2 的
`EBWebView/Default/Local Storage/leveldb` 持久存储，不复制整个浏览器资料夹。
复制时独占打开源数据库 `LOCK` 和存在的浏览器 `lockfile`；占用则提示关闭正式版
后重启开发版，不杀进程、不将失败当成完成。LevelDB（WebView 的键值数据库）的小写
`*.log` 是持久预写日志，必须复制；大写 `LOG` 是诊断输出，连同锁文件一起排除。
开发版 Local AppData 内 `.stable-profile-import-v1` 记录 pending/imported/existing/fresh；
同目录暂存保留完整快照，先完成复制再安装两类数据，中断后从快照继续。只有建立新
快照时才检查正式版源目录；已有开发版数据、完成标记或完整冻结快照时，不再访问
正式版目录。因此正式版目录后来不可访问或被迁移到目录联接，不应阻止开发版启动
或快照恢复；实际复制时仍拒绝源目录的重解析点。首次文档
脚本在前端模块加载前清除正式版渠道和跳过版本记录，以 localStorage 内独立标记
确保后续窗口及重启不清除用户在开发版新选的渠道。

复制错误会终止设置和窗口初始化，保留正式版原始数据且不写成功标记，使下次可重试。
没有正式版数据则标记为新配置，避免用户后来建立正式版配置时意外导入。系统钥匙串
及 Windows Credential Manager 不批量导出，相关登录可能需要重新认证。相比让用户
从空白手工重配，这个方案保留日常设置和工作区；相比两版共用文件或每次读正式版，
一次独立复制不会让开发版后续修改污染正式版，也避免读取运行中的 WebView 数据库。

已有共享正式版 ID 的旧 AutoBuild 第一次进入新身份必须单独安装，不能把跨身份
变化当作原地 Sparkle 更新。发布器校验下载基线的应用名和 bundle ID，仅对同身份
ZIP 生成增量；不兼容身份跳过，损坏归档仍失败。新开发版之间继续验签并生成差分。
独立开发版“回到正式版”打开正式版下载页，两者并存；只有旧共享身份的预览版继续
使用原签名全量回退，不放宽安装器对目标 ID 的校验。

可复验入口是 `MacAppIdentityTests`（历史路径、独立设置及凭据文件）、
`MacDevelopmentProfileMigrationTests`、Windows 的 `profile_migration_tests.rs` 与
`profile-migration.test.ts`（首次复制、已有数据保护、失败重试及快照恢复）、
`AppUpdateChannelTests` 与 Windows 的 `update-channel.test.ts`（首次默认及显式选择）、
`scripts/test-sparkle-update.rb`（六种渠道/架构元数据、同身份基线与差分验签、
损坏 ZIP/缺失或非法元数据必须返回 1，只有验证后身份不兼容才返回 3，发布链必须停止）、
`scripts/test-reuse-worktree-resources.mjs`（运行状态拒绝复用）及
`scripts/verify-runtime-bundle-immutability.sh`（发行目录只读规则）。真实 Windows
双安装器并存和原生 WebView，以及真实双架构签名升级，仍须在对应平台复验，不能
用前端测试替代。

### 正式版与 AutoBuild 的选择和时间身份

更新设置只接受 `stable|autobuild`。正式版和旧共享身份的预览版缺省回到正式版；
独立安装开发版表示用户已选择开发发行，首次缺省使用 AutoBuild。已保存的显式选择
始终优先，损坏偏好回到正式版。设置页把正式版标为推荐项；选择 AutoBuild 先确认风险，
并持续提示每晚构建可能包含未完成功能、严重缺陷和其他异常，普通用户建议使用正式版。
已安装渠道由签名包内的 `LitheUpdateChannel` 决定；兼容读取旧 `preview`，新包写
`autobuild`。偏好写平台用户存储，时间元数据只读，应用运行不改写发行 bundle。

macOS 同渠道保留 Sparkle（负责签名更新的框架）的检查、下载和安装能力；独立的
`SUDefaultsDomain` 使用 `.stable` / `.autobuild` 后缀。切换渠道必须全量安装，不能
把正式版语义版本与滚动时间身份直接比较。切换时先终止旧更新提示，活动检查、下载、
安装或另一次切换未结束时不接受新选择；旧共享身份预览版回到正式版仍提供签名全量回退，独立开发版则打开正式版下载页。
Windows 的 AutoBuild 和跨渠道路径明确打开安装器发布页，因为当前滚动发布没有
Tauri 签名更新清单，不伪造更新版本、下载进度或“已是最新版”；定时检查不弹浏览器。

AutoBuild 使用独立的 `LitheUpdateChannel=autobuild`（兼容读取旧 `preview`）、独立的
`appcast-preview-<architecture>.xml`、独立的 `SUDefaultsDomain`
后缀（`app.lithe.desktop.sparkle.stable` /
`.autobuild`）。两个渠道共用同一把 EdDSA key，但跳过版本和自动检查
偏好不跨渠道迁移；用户切换渠道必须显式确认并全量安装。Build 号使用 UTC `YYYYMMDD.HHMMSS`，例如
`20261015.124354`。prepare 只采样一次 UTC，同秒生成 compact build 与标准 ISO
时间 `2026-10-15T12:43:54Z`，全部平台共享。新发布必须严格晚于双架构已有
appcast 的 `pubDate` 且数值 build 递增；新发布同秒或时钟倒退直接拒绝，不能补计数。
旧 `58.1` 只兼容作为历史基线，新发布不能再使用计数身份。部分发布失败后，
保留原 artifacts 重跑 publish，由下面的发布检查点证明这是同一次发布；
不能只凭相同时间或 tag SHA 跳过时间排序，也不能给旧字节贴新时间。

### AutoBuild 固定入口与最新资源清单

应用公开发布固定使用大小写精确的 `AutoBuild` tag；title 与正文均显式显示
`AutoBuild — 构建自 YYYY-MM-DD HH:mm:ss UTC`。公开渠道为 `autobuild`，基础设施
兼容旧 `preview` 开关与 appcast 文件名。保留原工作流文件，身份顺序完全来自 UTC
构建时间，与工作流计数无关。prepare 一次固定源码 SHA、版本、build 与时间；
macOS 双架构和 Windows 复用工作流共同消费这些输入。Windows 只产出 artifact，
没有独立定时任务或 release 写权限，publish 等待三个平台全部完成，并逐项检查
artifact identity（包括时间）及 build/ISO 精确对应，避免把不同源码或 build 的安装包混在同一个入口。

发布检查点是记录这次发布完整目标的 `autobuild-publication.json`。发布器先验证
本地输入、插件和两个历史 feed，再上传包含源码、版本、共享时间及全部目标文件
大小与 SHA-256 的确定性清单，之后才写数据和 feed。重跑时，只有远端检查点
与本地逐字节相同，才允许完成同一次发布：相同字节的当前 feed 按身份验证，
较旧 feed 仍按严格时间顺序验证，被 clobber 删除或留下空 `starter` 的 feed 可补齐。
同时间但源码或任何目标字节变化、较旧构建遇到较新检查点、相同时间却不同字节的
远端 feed 都拒绝，检查点也纳入最终资产校验和保留清单。

例如 arm64 feed 已发布而 Intel 上传失败，应使用原 artifacts 重跑 publish；
不要在重跑前重新打包、重签或改时间。直接允许所有相同 build 的 feed 虽然更简单，
却无法证明两架构和安装包来自同一份内容；要求每次失败都重新构建则无法原样完成
已提交的发布。因此采用先记录完整目标、再恢复相同目标的办法。

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
创建的精确临时目录。根目录生成目标检查点，`baselines/AutoBuild/` 下载当前入口的
旧检查点和架构 appcast；只要旧 `preview-0.3.0` release 仍存在，其架构 appcast 就下载到
`baselines/preview-0.3.0/` 并继续严格排序。不能因为 AutoBuild 已创建但为空、或只留下
未完成的检查点而跳过旧基线；检查点的精确恢复权限只适用于 AutoBuild。
例如创建 release 后、上传检查点前中断，重跑必须继续拒绝比旧 preview 更早或同秒的快照。
这些文件只供本次排序和精确恢复校验，不可跨工作树复用。没有匹配检查点时，已有 ZIP 却缺少 feed 或 feed
损坏都拒绝发布；存在检查点也不能接受损坏的已上传 feed。
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

共享场景位于 `shared/fixtures/updates/channel-selection-v1.json` 和
`shared/fixtures/updates/build-time-v1.json`，两个客户端分别验证渠道路径和严格时间格式。

### 从 Preview 回到 Stable 只走全量、且不信任下载来源的 key

旧共享正式版身份 Preview 的 Return to Stable 路径永远下载完整 DMG，不请求 delta，
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
- **使用 workflow run number/attempt 作为滚动版本**：可以区分重跑，但用户无法从
  序号识别构建时间，也使工作流身份影响版本先后，因此改用一次采样的 UTC 时间。
  只重跑发布 job 必须继续使用产物原时间，不允许为旧字节重新贴新时间。
- **保留 30 个 build 与三个历史 ZIP**：可以延长缓存兼容窗口，但不满足仅保留最新
  应用及插件的要求，因此改为发布完整验证之后清理，仅保留当前快照。
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
- **像 DBX 那样在任何构建里都允许勾选“安装未签名包”**：DBX 的插件运行在独立
  进程和 webview 里，放行未签名包的风险可控；Lithe 的插件是直接加载进主进程
  的原生代码，所以只在 debug 构建开放，release 构建保持强制验签。
- **给 debug 构建内置一把测试公钥、让开发包也走签名**：需要把测试私钥分发给
  所有插件作者，等于没有私钥保护；“没有签名文档 + 开发构建”更容易审计。

## 后果

- 贡献者不需要 Apple Developer 账号就能产出可验证来源的差分更新，
  Developer ID 签名和公证仍可作为独立环节按需加入。
- 暂时性基线下载故障可在本次运行恢复，代价是失败归档最多占用三次
  下载期限和两次退避等待；持续故障仍需修复或重跑，不能用超长等待掩盖。
- 正式版和 AutoBuild 的更新偏好与安装身份分别记录；默认推荐正式版，代价是
  旧共享身份客户端首次迁移须单独安装开发版，且开发版需要重新配置独立偏好。
- 最新资源清单阻止安装包、插件和 Sparkle 历史无限累积；代价是旧缓存 feed
  可能引用已删除文件，旧客户端需重新检查并使用全量更新，迁移旧 tag 还需一次
  手动重装。固定 tag 多文件更新不具原子性；精确检查点让原 artifacts 可重跑完成，
  代价是额外保留并校验一个清单资产，且同秒重打包或重签后的不同字节不能冒充恢复。
- 时间身份让用户能直接识别构建时间，代价是需要可信的 UTC 时钟；时间倒退或同秒
  的新发布必须失败，只有检查点和目标字节完全相同的发布恢复可复用原时间。
- 回滚路径的安全性依赖客户端内置公钥永不改变；如果需要轮换
  `SPARKLE_PRIVATE_KEY`，替换 repository secret 本身不够，必须单独
  规划迁移（重签或双签过渡期），否则旧客户端会拒绝新签名的更新。
- 独立插件包的安装安全性同样依赖客户端内置的 publisher 公钥；没有匹配 secret
  的 release 构建会失败，普通 debug 构建会跳过需要 publisher 签名的 PHP 包，
  指定单个 PHP 包构建时也会失败。这样构建目录中不会留下缺少
  `lithe-plugin-signature.json` 的伪成功包；只有提供私钥的构建才会生成可交给
  包级验签路径的产物。需要在本地验证插件时，显式使用 `--development-unsigned`
  生成开发包，并通过 debug 构建的“从磁盘安装”导入；这条路径永远不会进入
  发布产物。
- 如果需要增加渠道或恢复历史兼容窗口，必须一起调整快照清单、清理验证和用户提示，
  不能单独放宽旧资产保留或伪造时间身份。

## 验证

```bash
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AppUpdateChannelTests|StableRollbackTests|UpdateCheckerTests|UpdateManifestTests'
# 在仓库根目录运行；Bun 包装器自动选择 windows/tauri 作为工作目录。
node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --report .artifacts/test-stability/windows-updater.json -- src/features/settings/lib/update-channel.test.ts src/features/settings/stores/update.store.test.ts src/features/settings/components/update-channel-selector.test.tsx src/features/layout/components/installed-build-label.test.tsx
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --max-seconds 60 -- --filter StableRollbackDiskImageIntegrationTests
./scripts/test-macos.sh
./scripts/verify-macos-package.sh
./scripts/verify-official-plugins.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'PluginLocalDevelopmentTests|PluginPackageSignatureTests|PluginPackageStoreTests'
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
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift`
- `macos/Tools/LithePluginPackageSigner/`
- `docs/architecture/macos-updates.md`
