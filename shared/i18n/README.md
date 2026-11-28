# 维护共享翻译

Lithe 桌面端（Viva，`desktop/`）的界面文案在这里维护。`scripts/i18n/generate-i18n.mjs` 把标记 `desktop`
的词条生成 Go 字典 `desktop/internal/i18n/shared.generated.go`，随源码编译进可执行文件；运行时不读取这里的
JSON，也不下载语言包。

词库里还留着已在 #1799 删除的旧 macOS（Swift）和 Windows（Tauri）客户端的数据：只标记 `macos` 或 `windows`
的词条、`macos.key` 与 `windows.key` 兼容别名、`macos.arguments` 与 `macos.formats`、`overrides.macos` 与
`overrides.windows`，以及清单中每种语言的 `macos`、`swiftCase` 和顶层的 `platformDefaults`。生成器仍会校验这些
数据，但不再据此生成任何文件；清理由 [#1807](https://github.com/1lck/Lithe-IDEA/issues/1807) 跟踪。新词条只标记
`desktop`，不要再填写这些字段。

## 修改文案并生成

- `manifest.json` 声明语言 ID、自称名称、回退关系和覆盖程度。
- `messages.json` 声明语义 key、用途、适用平台和参数。相同语义共用 key；只在某处使用的内容保留独立 key。
- `locales/<locale>.json` 的 `messages` 保存该语言的译文。现在只有桌面端一个生成目标，措辞要改就直接改译文；
  `overrides` 中只剩旧客户端留下的条目。
- `features/<feature>.json` 可以把同一宿主功能的新增声明和译文放在一个小文件中，
  顶层只有 `schemaVersion: 1`、`messages` 和 `locales`。`messages` 使用同一声明格式；
  `locales` 按 manifest 中的语言 ID 保存该文件自有词条的 key → 译文映射，
  例如 `"locales": {"en-US": {"feature.status": "Ready"}, "zh-CN": {"feature.status": "就绪"}}`。
  不能重复基础词库或其他文件的声明、覆盖已有译文，或为别处声明的词条补译文。
  生成器按文件名稳定读取，再对合并后的词库执行相同的平台、别名、参数和完整翻译校验；
  调用检查器也读取这份合并契约。这里只拆分源码文件，不增加运行时加载或另一套字典。

修改后运行：

```sh
node scripts/i18n/generate-i18n.mjs
node scripts/i18n/generate-i18n.mjs --check
node scripts/i18n/generate-i18n.mjs --coverage
node scripts/i18n/verify-app-language-localization.mjs
node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs
```

提交共享源文件和生成结果。`shared.generated.go` 是唯一的生成物，不要手工修改，也不要把新词条手写进 `en.go`、
`zh.go` 等 Go 目录，或在页面里重新判断中英文。开发、构建与独立跨平台 CI 会检查结果是否最新；`--check`
只读，不写文件。测试文件总预算为 60 秒；单项测试由源码中的独立超时控制，最长 15 秒，避免把整份顺序测试的
耗时误算成单项超时。生成文件由根目录 `.gitattributes` 固定使用 LF 换行，Windows 启用 Git 自动换行转换时
也应保持相同字节；不要通过重新生成或跳过校验掩盖检出格式差异。

## 在代码中读取文案

Viva 用 `i18n.Shared(language, "key")` 读取词条；带参数的词条用
`i18n.SharedFormat(language, "key", map[string]string{"name": value})`，以字面量参数表提供声明的参数名。
参数只替换一次，传入值中的 `{name}` 不会被再次解释；没有传入的参数保留占位符。当前语言缺少的词条退回英文，
未知 key 返回空字符串，所以 key 必须是字面量，并已为 `desktop` 声明。

`scripts/i18n/verify-app-language-localization.mjs` 扫描 `desktop/internal` 的非测试 Go 源码，拒绝：

- 没有在 `shared/i18n` 为 `desktop` 声明的 key，以及不是字面量的 key；
- 带参数的词条用了 `Shared`，`SharedFormat` 的参数表不是字面量，或参数名与声明不一致；
- 设置窗口 `marketText("…")` 中未声明或带参数的 key；
- `desktop/internal/i18n` 的 `en.go`、`zh.go` 中手写的界面文案；
- `workbench`、`settingswindow`、`logwindow`、`editorview`、`termview` 中直接传给 `Text`、`Button`、`Label`、
  `Hint`、`Placeholder`、`Tooltip` 等界面接口的字面文字。

这些规则看不到复杂表达式和通过变量间接传递的文案，不能据此认定任意新增文案都已校验；补强同样由 #1807 跟踪。
上游诊断、用户代码、字体覆盖样本、开发基准场景、搜索关键词和 AI 提交的目标输出语言属于各自的数据，
不要把这些内容当作界面翻译改写；已知的 Agent 选项说明在呈现处通过共享词条翻译。

## 使用正确的语义和平台范围

先查清词条用途，不要按英文相同就合并。已确认的通用动作共用词条，尚未证明相同语义的
既有内容继续使用独立 key，避免“Provider”等同名不同义的翻译串用。
平台范围仅决定生成哪些词条，不表示功能已实现；功能能力继续由
[功能矩阵](../platform-feature-matrix) 记录。

## 声明参数和格式

普通参数写成 `{name}`，并在 `parameters` 中声明 `string`、`integer` 或
`unsignedInteger`。参数集合由源定义控制，翻译遗漏或拼错参数会失败。
某种语言不需要英文复数后缀时，用 `optionalParameters` 记录该参数及省略理由；
不能为了通过检查悄悄删掉参数。确实需要空译文的语言后缀必须声明 `allowEmptyTranslation`。

`literalBraces` 只用于本来就显示代码花括号或双花括号的文本；声明后未知的花括号内容
保持原文，已声明参数仍必须完整。当前不支持 ICU 复数语法或任意 printf 指令；若有复杂复数需求，
应独立评估成熟工具。

旧 macOS 词条的 `macos.arguments`、`macos.formats` 和 override 的 `nativeFormat` 只服务已删除的原生字符串表，
生成器仍校验，但不再生成任何文件；新词条不要填写。

## 增加一种内置语言

1. 在清单中添加唯一的 `id`、`title`、`fallback` 和 `coverage`。清单校验目前仍要求旧客户端的 `macos` 和
   `swiftCase`，按已有语言的格式填写；桌面端保存语言设置用的代码（`en`、`zh-Hans`）正是这里的 `macos` 值，见 #1807。
2. 创建同名语言文件，例如 `locales/ja-JP.json`。
3. 翻译完整时用 `coverage: complete`；允许暂缺时用 `fallback`，并声明回退语言。
   所有回退链最终必须到达完整默认语言，不能成环。
4. 在 `desktop/internal/i18n/i18n.go` 增加对应的 `Language`，补齐 `Languages`、`Code`、`Native`、`Parse`、
   `Detect` 和读取词库时的语言 ID。桌面端的语言列表写在这里，不由清单驱动，见 #1807。
5. 运行生成及校验，检查设置中的语言列表、切换、参数和缺词回退。

生成器在构建时展开回退，Go 字典包含清单中每种语言的完整词条。桌面端按系统首选语言选择，没有支持的语言时
默认英文；清单的 `platformDefaults` 是旧客户端的默认语言，桌面端不使用。旧资源本来缺失的翻译使用英文回退；
“资源覆盖完整”不代表所有句子都已人工翻译。删除语言时同步移除 `i18n.go` 中的对应项，并考虑用户已保存设置的回退。

## 保持安装资源只读

生成只发生在当前源码工作树。Go 字典编译进可执行文件，运行时不读取、不写入任何语言资源，也不产生语言缓存，
不影响签名和 Sparkle 增量更新的源基线。源文件和生成物不跨工作树复制，见
[独立工作树的本地编译](../../docs/ci-builds.md#独立工作树的本地编译)。
