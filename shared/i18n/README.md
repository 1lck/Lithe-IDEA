# 维护共享翻译

应用自有的 macOS 和 Windows 翻译都在这里维护，再生成两端使用的资源。
macOS 的字符串表、Windows 的完整翻译字典，以及原先页面内的中英文文案都已迁入。
两端继续使用原来的翻译接口，不在运行时读取这里的 JSON，也不下载语言包。

## 修改文案并生成资源

- `manifest.json` 声明语言、自称名称、平台默认语言、macOS 资源标识和回退关系。
  共享 `zh-CN` 对应 macOS 已保存的 `zh-Hans`；不要改掉用户的持久化标识。
- `messages.json` 声明语义 key、用途、适用平台和参数。相同语义共用 key；
  平台专属内容保留独立 key。历史 Windows key 中的空格、连字符等通过 `windows.key`
  显式兼容，原生英文旧 key 通过 `macos.key` 显式兼容。
- `locales/<locale>.json` 保存对应语言的 `messages`。平台措辞确实不同时，使用
  `overrides.macos` 或 `overrides.windows`，同时填写 `value` 和 `reason`。

修改后运行：

```sh
node scripts/i18n/generate-i18n.mjs
node scripts/i18n/generate-i18n.mjs --check
node scripts/i18n/generate-i18n.mjs --coverage
node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs
```

提交共享源文件和生成结果。Windows `shared.generated.ts`、macOS
`AppLanguage.generated.swift` 和各语言的整个 `Localizable.strings` 都是生成物。
不要手工维护这些文件，不要在 Windows 再添加一份翻译字典，也不要在页面重新判断中英文。
开发、构建、打包与独立跨平台 CI 会检查结果是否最新；`--check` 只读，不写文件。
测试文件总预算为 60 秒；单项测试仍由源码中的独立超时控制，最长 15 秒，
打包子进程最长 5 秒，避免把整份顺序测试的耗时误算成单项超时。
生成文件由根目录 `.gitattributes` 固定使用 LF 换行，Windows 启用 Git 自动换行转换时
也应保持相同字节；不要通过重新生成或跳过校验掩盖检出格式差异。

## 使用正确的语义和平台范围

先查清词条用途，不要按英文相同就合并。已确认的通用动作共用词条，尚未证明相同语义的
既有内容继续使用显式平台范围，避免“Provider”等同名不同义的翻译串用。
平台范围仅决定资源生成，不表示功能已实现；功能能力继续由
[功能矩阵](../platform-feature-matrix) 记录。

macOS 生成器同时输出语义 key 和旧英文兼容别名，所以 `Text("Save")`、
`String(localized: "Save")` 与新语义 key 读取同一张表。需要明确选择语言时，通过
`AppLanguage.localizedString` 或 `localizedFormat` 读取已打包的原生资源。
视图之外构造的文案（错误、弹窗、状态、通知）统一用 `L10n.string("…")`
（`LitheModuleAPI`，语言由设置驱动）；运行时才确定的格式键用 `L10n.string(key:)`。
直接调用 `String(localized:)` 或 `NSLocalizedString` 会按系统语言选语言包，`locale:`
只影响数字和日期格式。`scripts/i18n/verify-app-language-localization.mjs`（由
`verify-service-boundaries.sh` 调用）会拒绝这类调用，调用方显式注入自己的语言包时除外；它还要求每个 `L10n.string` 的字面 key
都已在 `shared/i18n` 里声明，并拒绝 `errorDescription`、`NSAlert` 文本、按钮标题和
`NSLocalizedDescriptionKey` 里的裸英文字面量（模块与插件清单的注册一致性诊断除外）。
上游诊断、用户代码、字体覆盖样本、开发基准场景、搜索关键词和 AI 提交的目标输出语言属于各自的数据，
不要把这些内容当作界面翻译改写；已知的 Agent 选项说明在呈现处通过共享词条翻译。

## 声明参数和格式

普通参数写成 `{name}`，并在 `parameters` 中声明 `string`、`integer` 或
`unsignedInteger`。参数集合由源定义控制，翻译遗漏或拼错参数会失败。
某种语言不需要英文复数后缀时，用 `optionalParameters` 记录该参数及省略理由；
不能为了通过检查悄悄删掉参数。确实需要空译文的语言后缀必须声明 `allowEmptyTranslation`。

原生旧 key 还声明 `macos.arguments` 的调用顺序。默认字符串使用 `%@`、整数使用
`%lld`、无符号整数使用 `%llu`；历史 `%d` 等调用通过 `macos.formats` 显式保留 ABI
类型，不能随意改成 64 位格式。翻译调整顺序或重复参数时生成位置格式，普通百分号
转换成 `%%`。历史明确使用位置格式的译文用 override 的 `nativeFormat: positional`
保留原表格式。原生调用方仍须传入匹配的 `CVarArg` 类型。

`literalBraces` 只用于本来就显示代码花括号或双花括号的文本；声明后未知的花括号内容
保持原文，已声明参数仍必须完整。Windows 只替换一次参数，用户值中的 `{name}` 不会被
第二次解释。没有传入的参数保留占位符，未知 key 原样返回。当前不支持 ICU 复数语法
或任意 printf 指令；若有复杂复数需求，应独立评估成熟工具。

## 增加一种内置语言

1. 在清单中添加唯一的 `id`、`title`、`macos`、`swiftCase`、`fallback` 和 `coverage`。
2. 创建同名语言文件，例如 `locales/ja-JP.json`。
3. 翻译完整时用 `coverage: complete`；允许暂缺时用 `fallback`，并声明回退语言。
   所有回退链最终必须到达完整默认语言，不能成环。
4. 运行生成及校验，检查语言列表、切换、参数、缺词回退和两端打包。

语言选项、Swift 枚举、Windows 类型和原生打包列表都由清单驱动。
所有平台词条都在构建时展开回退，不存在另一个旧字典需要修改。
默认回退语言为英文；macOS 默认英文、Windows 默认中文，保留现有产品行为。
旧资源本来缺失的翻译使用英文回退；“资源覆盖完整”不代表所有句子都已人工翻译。
删除语言时还要移除生成的 `.lproj` 目录，并考虑用户已有设置的回退。

## 保持安装资源只读

生成只发生在当前源码工作树。macOS 打包复制资源并仅将目标副本转换成二进制 plist，
随后签名；运行时只读，不产生语言缓存，不影响签名和 Sparkle 增量更新的源基线。
源文件和生成物不通过 worktree 资源复用脚本复制，见
[独立工作树的本地编译](../../docs/ci-builds.md#独立工作树的本地编译)。
Windows 验证传输目录 `.artifacts/i18n-windows/` 是本次源码快照和验证工具的临时暂存区，
不能作为生成资源、下载缓存或跨工作树可复用文件；验证后清理传输包与工具。
