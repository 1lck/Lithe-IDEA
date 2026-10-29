# Agent 笔记：共享翻译来源与双端构建时生成

状态：已实现

## 先说结论

macOS 和 Windows 的全部自有翻译资源改为在 `shared/i18n/` 维护，再在构建前生成各自的
资源文件。开发者修改一次翻译即可更新两端，现有页面仍使用各自的翻译接口。
原生字符串表、Windows 原字典及页面内的中英文文案已完整迁入；上游消息、用户数据和搜索同义词仍由各自所有者维护，不增加在线语言包。

## 问题

两端原来各自维护中英文，macOS 多用英文原文作 key，Windows 使用语义标识；参数还
分别使用 `%@` / `%lld` 和 `{name}`。直接合并会丢失语境与参数类型，也会把 Finder
和 File Explorer 等合理差异抹掉。语言选项、Swift 枚举和原生打包列表原本也固定为两项。

## 决策

共享语言清单声明语言标识、自称名称、回退语言和各平台默认值。生成器输出语言选项、
Swift 枚举、Windows 类型及字典；macOS 打包从同一清单读取列表。保留用户已经保存的
`en` / `zh-Hans` 与 `en-US` / `zh-CN`，也保留 macOS 默认英文、Windows 默认中文。
增加内置语言只需扩充清单和语言文件，再生成资源，不用修改语言选择控件。

词条使用描述用途的语义 key。相同英文并不自动表示相同语义，平台适用范围也不代表
功能已经实现；能力对齐继续由功能矩阵记录。平台覆盖（override，即单个平台需要
不同措辞）必须说明原因，第一批覆盖保留现有文案，包括文件管理器名称。

macOS 继续复用 Foundation 的原生字符串表与格式化能力，Windows 保留现有翻译接口。
生成器不实现运行时语言引擎：它把共享词条放进既有 `Localizable.strings` 的生成区域，
同时输出语义 key 和旧英文 key 的兼容别名。新旧页面因此读取同一张表，不用一次替换
全部 SwiftUI 隐式本地化调用。Windows 仅使用生成字典，原独立字典已删除；所有词条在生成时展开显式回退链。页面不再用中英文分支保存翻译，明确语言的呈现经由 AppLanguage 原生资源接口。

正确做法：修改 `locales/zh-CN.json` 的 `ui.save`，重新生成，提交源文件和生成结果。
不要在 macOS 生成区或 Windows 旧字典里再写一个 Save；校验会拒绝双重维护。
当两个用途需要不同翻译时建立两个语义 key，不能让同一旧别名归属于两个 key。
同步其他功能分支时，先把新加入的原生旧 key 和 Windows 字典词条迁入共享源，
保留已有译文、参数宽度和位置格式，再重新生成。不要把两套字符串表拼接到生成区域；
以同步分支的实际资源逐 key 比对生成结果，确认没有丢词或改写平台措辞。

参数必须声明为字符串或整数。macOS 别名还声明旧调用方传参顺序，生成器转换成
对应的原生格式；历史 `%d` / `%llu` 的 ABI 类型由显式 formats 保留，不能改变传参宽度。翻译调整顺序或重复参数时使用带位置的格式，并转义普通百分号。
Windows 只替换一轮占位符，避免把用户传入的 `{name}` 当成另一个参数展开。
当前不支持复杂复数、任意 printf 指令或 ICU 模板；不在缺少实际需求时自建这些能力。

语言文件的覆盖率统计全部共享词条。完整语言缺词会失败；明确允许回退的语言可缺词，
但回退链必须到达完整默认语言。生成器还拒绝重复 key、未知字段、非法平台、越界覆盖、
参数不匹配、原生位置格式越界或混用、Swift 关键字及生成成员重名、双重定义和过期产物。
检查模式只读；所有输入及生成计划验证完成后才写文件。
生成文件通过 `.gitattributes` 固定为 LF 换行，避免 Windows Git 自动转换换行后误报
产物过期；集成测试在临时仓库中开启 `core.autocrlf`，实际检出后比较生成文件字节。

资源生命周期由 Git 和本次构建管理，不创建下载、运行时缓存或可跨工作树复用的生成物。
原生打包只在目标副本转换二进制 plist，随后签名；运行时不写 bundle 或 Windows 安装
资源，所以不改变代码签名及 Sparkle 增量更新基线。资源复用清单明确拒绝复制这类文件，
每个工作树根据自己的源版本重新生成。

## 考虑过的备选方案

- 两端运行时读取共享 JSON：需要新增原生加载与回退路径，破坏现有 SwiftUI 字符串表
  查找方式，增加启动和语言切换状态，当前没有收益足以承担这个代价。
- 一次替换全部词条：会混淆同名不同义文案，改动面大，回归难定位。先迁移通用操作和
  少量设置标签验证架构，再完整迁入原有字典并比对每个原 key 的值，保证迁移不改变现有文案。
- 为每个平台保留独立共享表：容易使 SwiftUI 的默认表和显式查找得到不同结果，因此
  在同一个默认表中划出可检查的生成区域。
- 使用新的多语言运行时库：当前已有原生表和简单命名插值，复用其完整调用边界即可。
  复杂复数或第三方包出现实际需求后再评估成熟工具，不提前设计下载与热加载协议。

## 后果

已迁移词条有一个编辑来源，新增语言能贯通选择、生成和打包；平台差异和旧设置值保留。
代价是提交中包含可复验的生成产物，并需要同时提交共享源与生成结果。macOS 旧英文 key 的语义
歧义仍存在，新用途应使用独立语义 key；原资源缺少的译文以英文回退，不声称这些句子都已人工翻译。
现有词条生成检查通过不等于两端整机语言切换验收完成。

## 验证

- `node scripts/i18n/generate-i18n.mjs --check`：清单、参数、覆盖和产物一致性；只读。
- `node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs`：非法输入、生成物所有权、新增语言、
  平台覆盖、回退链和 macOS 二进制打包；比较打包前后源文件字节。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`：稳定性静态规则。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'SharedI18nTests|AppLocalizationTests|LocalizationPackagingTests|GitLocalizationTests'`：原生资源查找、兼容 key、实际参数格式化、切换及原有行为。
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs -- src/i18n/locale.test.ts src/i18n/shared-i18n.test.ts src/features/settings/lib/settings-normalization.test.ts`：Windows 前端资源与设置；宿主平台必须在报告中注明。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`：同时检查 macOS 与 Windows 运行时资源路径。
- `node --test --test-timeout=15000 scripts/resources/test-reuse-worktree-resources.mjs`：拒绝跨工作树资源复制。
- `./scripts/architecture/verify-shared-contracts.sh`、`./scripts/windows/verify/verify-windows-boundaries.sh` 和
  `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`：共享边界与能力记录。

生成器测试与原生测试共同消费 `shared/fixtures/i18n/format-v1.json` 和 `native-abi-v1.json`，覆盖32位有符号、64位无符号参数及参数重排、重复、
大整数、零、Unicode 和用户值中的格式符。独立 CI 在 Linux、macOS、Windows 执行生成器
测试并输出单项计时；Draft PR 只运行 Linux，转为 ready 后再触发三系统校验，
同一 PR 的旧 i18n 校验会取消。macOS 才运行原生打包用例。完整产品在中英文设置中切换、关闭重开并
检查保存值和其他模块页面；Windows WebView2 整机验收仍须在 Windows 上执行。

Node 22 会把命令行超时同时应用到整份文件。词条增加后，macOS CI 在第 32 项之后
触及原 15 秒文件预算，单项没有断言失败。文件预算因此为 60 秒；源码中单项最长
15 秒、打包子进程 5 秒和 CI 步骤两分钟的边界都保留，不能通过扩大单项预算处理套件成本。

## 适用范围

- `shared/i18n/`
- `shared/fixtures/i18n/format-v1.json`
- `scripts/i18n/generate-i18n.mjs`
- `scripts/macos/package/package-macos-localizations.sh`
- `windows/tauri/src/i18n/`
- `macos/Resources/en.lproj/Localizable.strings`
- `macos/Resources/zh-Hans.lproj/Localizable.strings`
- `macos/Sources/Lithe/Models/Settings/AppLanguage.generated.swift`
- `.github/workflows/verify-i18n.yml`
