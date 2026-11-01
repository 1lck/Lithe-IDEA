# Agent 笔记：Java 插件按来源校验与独立发布基础

状态：已实现

## 先说结论

Java Support 的同一份清单现在区分两种来源：随应用发行的副本可以依靠宿主签名，用户下载安装的副本必须有 Lithe 发布者签名。两种来源使用同一插件 ID，经过校验的用户安装版本替代内置版本，不重复登记 Java 语言服务。官方发布工具能记录 ARM64、Intel 两个归档及各自哈希，并从发布标签读取对应 API 和能力声明；迁移保留启用选择并提供按需安装入口；主包只在完整双架构官方下载进入索引后移除资源。自动上架仍暂停，真实发布包按[独立分发提案](../../proposed/architecture/2026-10-24-java-support-independent-distribution.md)继续验收。

## 问题

Java 已经是声明式插件，但 `sameTeamAsHost` 原来只接受应用签名封装内的文件。直接把目录放到用户插件目录会被拒绝；直接把策略改成 `publisherPackage` 又会要求普通应用构建持有插件发布私钥。

旧发布脚本把索引 API 写死为 1，且每版只有一个 ZIP。Java 使用 API 3，又携带不同架构的 JDK，必须保留真实 `requires`（宿主必须支持的能力版本）和两个归档。历史版本重试上架时，还不能拿当前清单描述旧归档。

## 决策

### 同一清单，来源决定是否使用宿主签名

新增通用能力 `packageTrust: 1`，只在清单声明 `vendor.bundledSignatureRequirement` 时使用。Rust Core 只允许官方命名空间、API 3、主签名为 `publisherPackage`，且内置策略只能是 `sameTeamAsHost`。

macOS 官方目录固定主签名和内置策略。包管理器先校验清单与官方目录一致，再根据解析后的实际路径和安装来源验证：只有来源为 `bundled` 且文件确实位于宿主 app 内的副本可以依靠宿主签名。外部目录伪造来源无效；安装记录、回滚版本和磁盘导入同样不能借用该例外。任何来源只要带了签名文档，就必须验证它，不能因副本在 app 内而忽略坏签名。

旧宿主没有 `packageTrust`，会在市场过滤和清单校验时拒绝这一版。Windows 生产宿主仍不声明该能力；仅测试作用域提供候选能力以验证来源边界，不能将 Core 或安装单测通过等同于正式包可执行。

Windows 官方 Java 同样固定 `publisherPackage` 主策略和 `sameTeamAsHost` 内置策略，但尚无资源封装验证器。EXE 或安装器的 Authenticode（Windows 文件签名）不会封住相邻目录，因此未签名 Java 即使确实位于 bundled 根内，也返回 `plugin.trust.hostSealRequired`。有签名的 bundled 副本仍检查真实根包含与完整发布者签名；安装记录、回滚记录不能自称 bundled，任何来源的坏签名均拒绝。

Windows 扫描由已安装来源占有同一 ID：安装版本被停用、隔离或清单损坏时仍抑制内置副本，避免状态变化偷偷启动另一份 Java。只有显式移除该安装来源，发现层才可能再次看到内置副本；这项发现语义不代替完整产品卸载与停用选择验收。

正确做法：下载新版后校验完整文件树的发布者签名，再把完整版本放到平台应用数据目录；重启读取同一 ID 时只选择一个生效来源。

不要这样做：外部目录沿用 `sameTeamAsHost`，或声称 `bundled` 就省略签名。也不能把官方 ID 的策略改成同时接受任意一种签名。

### 构建显式选择内置副本

应用打包继续使用 `--bundled-only`。只有显式走这条路径且清单声明内置策略时，构建脚本才省略发布者签名，最终由应用签名封住资源。普通单插件 release 构建要求发布者私钥；debug 的 `--development-unsigned` 只用于本地开发，正式宿主拒绝它。

JDT LS、JDK、Lombok、Debug 和 Test 扩展保持当前锁定版本。资源先组装，原生签名等会改字节的步骤完成后才生成发布者签名，最终归档解压后再验证。运行时启动继续复用现有 `jdt` 集成；安装检查新增对运行时启动的计划校验，拒绝缺失目标架构的 JDK、包内入口和相关固定资源，不运行 JDK、不创建验证状态目录。

Windows 的 `Plugins/win/Official/JavaSupport/` 和 `assemble-windows-java-support.py` 独立组装候选，不调用 macOS 脚本。脚本只读取已锁定并校验哈希的 JDT/JDK 下载输入，检查 Windows configuration、完整 JDK 和所有 EXE/DLL 的 PE 架构；不联网、不执行 JVM、不签名。新目录原子发布，失败清理本次暂存；候选和 `windows-java-inputs.json` 均不可跨工作树复用，回执只证明输入和文件字节，不提供发布者或封装信任。

候选 JDT 启动保留现有 Java provider 和 Core 的完整 JDT 参数、Debug/Test 资源，额外传递真实 `pluginId` 供既有生命周期管理使用。候选能力开放后只接受唯一启用且已接受的 JDT 包，不能回退到旧宿主资源；能力关闭时旧资源路径仍是过渡实现，不算候选包验收。缓存写入平台 `plugin-state/<plugin-id>/jdtls`，不改插件资源。Windows 基础模板只含 plain、Maven、Gradle，不宣称 macOS archetype 或 Spring 能力已对齐。

### 安装切换保留用户选择

内置清单默认启用，下载清单默认禁用。安装成功后，包管理器把原内置模块的默认值保存为显式选择，再在重启时选择下载版；显式禁用不变，安装失败不修改选择。迁移只读取旧包已经拥有的模块，新模块保持清单默认值，避免把新模块或其他所有者的状态误当作旧选择。同一 ID 的插件设置继续使用原键，项目 JDK、运行配置和调试的 JDK 选择链不变，不复制或改写用户配置。

安装入口复用当前包管理器的统一安装流程。普通、市场和磁盘安装都在包校验与存储
成功后迁移旧选择，再刷新已安装列表；不能在读取候选清单时提前改设置，也不能
为了 Java 迁移把所有插件重新改成等待重启。Java 的宿主集成仍沿用重启边界；
已经支持运行中生效的插件继续按当前 Registry（实时能力目录）规则登记、撤回与通知
其他窗口。回归同时验证三种入口的默认启用/显式禁用迁移，以及现有实时插件安装流程。
官方签名离线包通过真实磁盘导入服务校验后仍走发布者签名安装路径；不能将它标为
社区来源来绕过签名要求。`installDiskPackage` 仅处理用户确认的社区包。

旧 `.removed-bundled-plugins.json`（用户卸载内置包的记录）持续抑制内置来源。用户明确重新安装后，该记录不能清理已安装版本的状态；删除已安装更新时也记录内置移除，避免重启又启用被遮住的副本。跳过过渡宿主直接升级时，无包就保持未安装，显式禁用仍保留；只有用户确认安装才创建新版本，不自动下载。

打开 Java 文件或含 Java、Maven、Gradle 文件的项目时，无插件则显示每窗口会话一次的安装提示，支持前往市场和“从磁盘安装”的离线路径。新建项目页在 Java 插件缺失时提供模板安装入口，已有但禁用的插件继续走启用流程。离线或取消不重置设置，下一次会话可以重试。

缺包判断必须同时读取包身份和安装状态。包管理器会保留已移除（`.removed`）的
内置副本快照，用于用户主动恢复；重启后这类快照不能抑制安装提示。已安装、等待更新
或等待卸载重启的副本仍走现有管理流程，即使用户禁用了模块，也不能显示缺包提示。
例如卸载并重启后打开 Java 文件应提示恢复；不要只收集快照 ID 来推断包仍然存在。

### 精简应用以已发布索引为前提

发布登记中的 `bundledUntilPublishedVersion: 1.1.0` 表示安全退出内置分发的最低插件版本。构建读取本工作树的官方索引：至少一个达到版本门槛的版本，其仓库、API、能力要求与当前插件一致，两个架构的 URL、平台与 SHA-256 齐全且唯一，才不再组装内置 Java，也不预下载 JDT/JDK。索引缺项仍带过渡副本，索引读写格式损坏直接中止构建，不能当作“无需内置”。后续插件源码升版时，兼容的旧下载仍可满足门槛，不要求下载版本等于当前源码版本。

打包用同一份索引作判断并嵌入应用，运行时不联网决定是否删资源。`LITHE_OFFICIAL_PLUGIN_INDEX` 仅覆盖构建输入，传给插件构建的 `--marketplace-index`，默认读取仓库索引；测试用临时虚构下载项证明精简路径，不能将 fixture 发布为真实索引。预览的 `--bundled-only` 使用同一默认策略。公开下载前默认 app 仍内置 Java；公开包和索引独立验收合并后，下一次应用构建自然精简。

正确做法：先发布并验证签名双架构包，再合并真实索引；应用构建从该索引得出不再内置。不要这样做：因为发布配置写好了就先删资源，或运行时下载到 app bundle 中补回文件。

### 发布按标签固定全部输入

`official-plugins.json` 登记 Java 两种架构的归档和上游构建输入，`releaseEnabled: false` 保持暂停自动发布。先有包含新能力的宿主版本，再通过独立改动开放上架；本次不生成线上索引或发布标签。

发布计划携带清单的真实 API 和 `requires`，组装全部架构后再创建同一个 Release。索引同步从对应 Git tag 读取当时的发布配置和清单，下载所有归档并计算 SHA-256 后一次写入该版本；任一归档缺失或哈希无效都不写部分版本。已发布插件的目录或登记的上游输入发生变化，需要提高插件版本。

### Windows 签名准备复用现有实现

Windows 离线候选交接先调用 `check-windows-java-signing-inputs.py`，由既有组装器从固定缓存重建临时副本，再逐文件比较候选。不能只比较候选和它自己附带的 receipt（组装输入回执），因为两者可以同时被修改。组装器还在原子发布前复核源码、复制结果和缓存哈希，拒绝解压期间输入改变后仍生成带有旧来源说明的包。

签名前报告固定包内全部原文件、回执及现有签名/发布实现；签名后只允许新增签名文档。正确做法是冻结输入后使用现有 `LithePluginPackageSigner` 签名，并对原目录及最终归档的独立解压副本运行它的 `--verify`。不要修改回执为“已签名”，也不要在交接脚本复制 canonical payload（签名消息的固定字节格式）、公钥表或另一套密码学验证。

交接脚本只校验文件准备和前后不变，不判断密钥是否可信。无签名或测试密钥都不能从它获得生产准入；正式签名器和生产宿主才拥有信任判断。报告固定 `productionAdmission: false`，并标明签名验证未执行。收益是 Windows 候选能交给已有签名入口，代价是发布者必须另外完成正式密钥签名、独立归档验证和产品验收，不能把 helper 通过当成发布成功。

Windows 检查所用 `.signing-check-*` 临时副本仍位于已有 `.artifacts/windows-java-support/` 下，结束即删除；它和签名前后报告都由本次验证者持有，不具备跨工作树复用身份。运行时不读取这些交接报告，不写已安装插件或发行目录，不影响宿主代码签名与 Sparkle 增量更新的源基线。官方配置仍关闭 Java 发布；Windows 资产现由下面的独立路由处理，不能把 R33 的准备报告套进发布流程当作验签凭证。

### Windows 发布使用固定源码与现有签名器

发布计划为每个资产读取真正的 `packageDirectory`、清单、架构与平台，并固定 Git commit 和完整输入
SHA-256。Git blob 是版本库保存的原始文件字节；路由把这些字节导出到本次临时目录后才组装，所以
本机换行转换和后来的清单编辑不会改变旧 tag 的含义。macOS 继续用原来的原生组装与签名验证。
现有市场索引每个插件版本只有一组 API/requires；两平台不一致时必须拒绝，不能用并集或 macOS
清单掩盖 Windows 的实际能力。Windows x64 和 ARM64 缺任一项，完整发布及索引都拒绝。

`windows-java-release.py` 把显式联网的 `prepare` 与离线 `rehearse`、`package`、`verify` 分开。
组装和输入命名继续复用既有 assembler，九项固定输入来自同一清单，不另建下载或 JDT 模型。
演练只生成 unsigned ZIP 并独立解压比较；局部 x64 演练明确不完整。受控 macOS 发布 job 调用现有
`LithePluginPackageSigner`，先签名和验证原目录，再验证独立解压副本，并保证验签没有修改文件。
路由没有签名算法、canonical payload 或信任根；正式私钥只从既有变量送到 signer 的 stdin。

正确做法：索引重试从 tag 读取资产身份，重新组装并对下载 ZIP 调用现有 signer，检查真实 SHA 后
一次写入全部资产。远端先上传 Draft Release，核对全部资产名后才公开；没有新发布或待补索引时不启动 macOS 发布校验 job。不要这样做：信任 release 附带 JSON 中的“验证成功”，或者把 R33 固定
`productionAdmission: false` 的准备报告作为正式信任凭证。新路由即使完成发布者验签，仍不授予
Windows 产品准入；生产 packageTrust、实机 Java 工作流和开放 release 是另外的门槛。

代价是索引重试需要受控 macOS signer，并需重新读取固定缓存和构建完整 Windows 包；这样才能
拒绝签名正确但平台、revision、输入或清单身份不符的资产，而不只验证 ZIP 中某个目录能验签。

### 资源目录与生命周期

- `dist/packages/<arch>/` 是发布 job 的组装输出，`dist/verify/<arch>/` 是归档验证副本，ZIP 和校验文件属于同一次发布。job 结束回收，不跨工作树复制。
- `.artifacts/windows-java-support/.release-*/` 是冻结源码、离线组装与独立 ZIP 解压的临时副本，结束清理；完成的 `<run>/*.zip` 和 `windows-java-release.json` 由运行者保留作本次证据，禁止跨树复用。`prepare` 仅使用既有 JDT/JDK 缓存，`.release-download-*` 暂存结束清理，下载仍受原校验路由管理。
- 一个架构的包和独立解压库存核对后就释放展开副本，仅保留文件哈希和 ZIP，避免两份大型 JDK 同时重复占用磁盘。不要保留无后续用途的展开目录；全部架构及缓存复核仍完成后才一起原子发布，省空间不能改变完整资产集合和失败拒绝边界。
- `.artifacts/java-plugin-distribution/` 是本地验证输出，没有可转移的版本与工具链身份，验证者负责删除不用的临时副本；资源复用脚本明确拒绝。
- JDT/JDK 下载缓存仍只能经原有资源校验路由复用。每个工作树从固定上游输入重新组装插件，不共享已签名包或用户安装目录。
- 用户安装的插件版本是只读输入；索引、Equinox 配置、日志和锁仍由平台缓存和状态适配器持有。运行时不改 app bundle、插件安装资源或 Windows 发行目录，保持代码签名和 Sparkle 增量更新源基线。

### 中断发布恢复与缓存身份

发布中途失败后，已创建的草稿仍由原 target commit SHA（完整不可变提交号）拥有。受信任的 preview 规划步骤会发现未完成草稿；即使 GitHub 尚未建立 tag，也按原提交恢复构建。恢复工具来自当前工作流版本，构建输入仍来自原提交。PR 检查继续只读，不向不受信任代码授予草稿读取所需的写权限。

已有公开版本禁止上传覆盖；草稿只允许在 target SHA 和已存在 tag 都一致时续传。资产名集合与远端字节摘要全部一致后才能公开，不删除或移动 tag。认证或网络失败必须失败，不能解释成“没有同名 release”。例如上传失败后重跑可以补齐同一草稿；不能删除旧标签来重发相同版本。

Java Debug/Test 下载缓存接受 `.zip` 与 `.vsix` 后缀，但包内输入回执固定使用 `.vsix` 逻辑名称。缓存只是物理位置，同一上游 SHA 的字节不能因缓存命名改变签名包身份。完整文件库存和签名验证仍保留；代价是旧实现生成的候选需要按原冻结版本验证或重新生成。

Windows 组装还读取 JDK 自带的版本与平台说明（`release`），与固定平台的归档根版本、CPU、
Windows、供应商及 JDK 类型逐项比较。清单顶层版本不能覆盖 ARM64 的独立补丁版本；否则回执
可能把 x64 的版本号误当作两端共同事实。正确做法是保留每个平台实际版本和 release 文件哈希；
不要只检查所有原生文件的 PE 架构就声称版本也正确。新增 `runtimeIdentity` 仍是本次构建证据，
不能替代签名或跨工作树复用标记。检查不执行目标架构 JVM，ARM64 运行验收仍需要真实机器；
代价是旧候选须按冻结组装器验证或重建，新候选的完整签名输入也随回执增加而变化。

固定 JDT LS 1.61.0 归档仅提供 Windows 的 `config_win`，其 `bin/jdtls.py`
也对所有 Windows CPU 选择此目录。曾声明的 `config_win_arm` 不存在，合成夹具虚构该目录
掩盖了 ARM64 实物组包失败。现在直接复用上游共享配置，包内仍按目标架构隔离路径；
不生成新配置、不删除上游架构 fragment，也不将组包成功当作 ARM64 JVM/OSGi 运行证据。
夹具只提供真实上游的 Windows 配置目录，防止再次用测试独有输入制造通过。

## 考虑过的备选方案

- 对 Java 官方 ID 全局放宽签名：实现简单，但外部文件会获得内置包才有的信任，拒绝。
- 应用构建也要求插件发布私钥：统一使用包签名，但普通开发和应用 PR 构建不应该依赖发布私钥，拒绝。
- 生成两份不同来源清单：减少清单字段，但会造成同一插件版本有不同清单和能力要求，使用同一声明按来源验证。
- 为旧宿主新增最低应用版本字段：当前能力协商已能拒绝未知语义，不额外引入另一套版本比较。
- 索引重试使用最新清单：容易实现，但旧归档会被描述为具有后来新增的能力，改为从不可变标签读取。
- Windows 交接另写签名算法，或只相信候选自身的回执：前者会与现有信任实现漂移，后者不能发现包和回执同时被替换；选择复用组装器重建，正式认证继续由已有签名器和宿主完成。

- Windows 发布另建签名工具或信任下载报告：会产生第二套信任实现或让报告本身冒充签名；复用现有 signer，并在索引重试独立验签和重建。

## 后果

收益是应用打包仍能独立完成，外部安装具有完整签名检查，Java 资源可以按架构独立发布。代价是首次下载版要求新宿主能力，签名策略不能只看一个枚举，还要核对官方目录、来源和真实路径。

代码覆盖可信安装、启用/卸载选择迁移、缺包引导和以发布索引为门槛的主包精简。当前索引未上架，所以主包仍含 Java；正式签名发布、真实市场下载及完整 Java 产品工作流尚未验收，提案保持 `proposed`，不能把测试 fixture 当作上线证据。

## 验证

- `node --test --test-timeout=15000 scripts/plugins/official-plugin-releases.test.mjs`：创建后上传/公开失败重跑、无 tag/有 tag 草稿、旧版本冻结输入、身份与远端字节错误拒绝。
- 离线组装回归比较 ZIP→VSIX→ZIP 的完整库存；发布路由用注入 signer 验证更换缓存别名后仍能独立重建。该替身不代表正式发布者签名成功。

- `./scripts/rust-core/verify-rust-core-comments.sh`、`./scripts/architecture/verify-shared-contracts.sh`：契约、注释和共享输入一致。
- Rust 的 `declarative_plugins` 与 `marketplace_plugins`：来源策略必须声明能力、非法组合拒绝、旧宿主在下载前拒绝。
- `PluginBundledPublisherTrustTests`：真实 Core、生产包管理器及注入测试公钥验证签名安装、单一来源、包篡改、伪造来源和缺失运行时，比较安装资源内容。
- 同一套包存储回归覆盖卸载后重新启动扫描得到 `.removed` 快照时的提示，状态矩阵保留禁用、暂存更新和待重启副本的管理流程；`PluginInstallationGuidancePresentationTests` 用真实原生视图核对深浅主题的缺包通知、模板入口及主动打开市场的按钮，不执行安装或工具。
- `./scripts/macos/verify/verify-macos-package.sh --slim`：以临时完整索引构建精简 universal app，拒绝 JDT/JDK 下载输入，检查资源缺失、签名和 DMG；默认模式检查保留过渡包。
- `node --test scripts/plugins/test-official-plugin-distribution.mjs`：完整与部分上架、来源/能力不匹配和后续版本门槛。
- `node --test scripts/plugins/official-plugin-releases.test.mjs`：双架构索引、部分归档拒绝、历史标签元数据以及上游输入变更约束。
- `node scripts/resources/test-reuse-worktree-resources.mjs`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh`：生成资源拒绝复用、发行目录只读边界。
- `python scripts/plugins/test-assemble-windows-java-support.py`：合成 Windows x64/ARM64 输入、完整能力要求、固定来源/身份、缓存篡改、PE 架构、恶意归档、输出边界与清理；不执行 JVM，也不证明 ARM64 实机可运行。
- `python scripts/plugins/test-check-windows-java-signing-inputs.py`：固定上游重建、伪造回执、六项能力和来源降级、签名前后内容/工具变化、无效签名不授予准入及临时副本清理；不执行签名或认证。
- Windows `signature_trust_tests`、`publisher_bundled_fixture_installs_replaces_and_rechecks_rollback` 和 `lsp_plugin_tests`：使用完整共享 fixture 或 Windows 清单、测试密钥与仅测试能力，验证来源策略、实际安装事务及 Core JDT 计划；正式签名完整包与真实 JDT 生命周期仍待验收。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 和 macOS 计时入口：相关测试必须有单项时长与 HTML/JUnit 结果。
- `.github/workflows/release-official-plugins.yml` 用 actionlint 校验；本地组装两种架构资源，验证 JDK 原生签名和发布归档的完整性。

上述验证不能替代正式发布者私钥签名、真实市场下载、Intel 真机及全部 Java 产品工作流。上线前继续按独立分发提案的退出条件执行，不能靠测试公钥通过就开放发布。

- `python scripts/plugins/test-windows-java-release.py`：双架构无发布演练、不可变 tag 输入、缺架构、输入替换、签名器错误/写入、ZIP 变化、部分包及清理；注入 signer 只验证调用顺序，不代表真实密钥验签。

## 适用范围

- `Plugins/mac/Official/JavaSupport/`
- `Plugins/win/Official/JavaSupport/`
- `scripts/plugins/windows-java-release.py`
- `scripts/plugins/test-windows-java-release.py`
- `scripts/plugins/assemble-windows-java-support.py`
- `scripts/plugins/test-assemble-windows-java-support.py`
- `scripts/plugins/check-windows-java-signing-inputs.py`
- `scripts/plugins/test-check-windows-java-signing-inputs.py`
- `windows/tauri/src-tauri/src/plugin_host/`
- `windows/tauri/src-tauri/src/lsp.rs`
- `Plugins/marketplace/official-plugins.json`
- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/`
- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheCoreContracts/Plugins/DeclarativePluginContracts.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginPackageStore.swift`
- `macos/Tests/LitheTests/PluginBundledPublisherTrustTests.swift`
- `macos/Tests/LitheOfficialPluginVerifier/OfficialPluginVerifier.swift`
- `scripts/plugins/build-official-plugins.sh`
- `scripts/plugins/official-plugin-releases.mjs`
- `.github/workflows/release-official-plugins.yml`
- `scripts/resources/worktree-resources.json`
- `scripts/resources/reuse-worktree-resources.mjs`
- `docs/ci-builds.md`
