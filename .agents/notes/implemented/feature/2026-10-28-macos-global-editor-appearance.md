# Agent 笔记：macOS 全局源码编辑器样式

状态：已实现

## 先说结论

所有项目的源码编辑器现在共享一组可持久化的样式偏好，包括已有字体、字号，以及新增的
行间距、配色、行号、空白符、光标和常用显示开关。修改时更新现有编辑器的选项，不重建
文档，因此光标、内容和撤销历史能够保留。设置不涉及 VS Code 或 IDEA 的检测与导入。

## 问题

此前 macOS 只暴露部分编辑器选项，高亮使用固定色表。将来接收其他 IDE 的配置前，产品
需要先能保存和应用相应偏好；仅在设置页增加控件会遗漏分栏和完整源码预览。

## 决策

- 复用 `AppSettings` 和既有 `KeyValueStore`。字体、字号、软换行、缩略图继续使用原键，
  新选项由 `EditorAppearanceSettings` 保存为一份属性字典。每个字段独立校验和回退，
  一个未知枚举值不会清空其他有效设置。字号限制为 6–72，行间距用字号倍数 1–3；
  0 表示沿用 Monaco 的自动行高，不用新的默认值改变老用户排版。
- 设置使用现有原生控件与共享 i18n 词条，说明进入信息提示；这些是 Lithe 自有的全局偏好，
  所有值即时保存，不引入第二个“应用”阶段。保留新版的编辑器软换行菜单与按平台确定的行号栏宽度。
- `MonacoWorkbenchDisplayConfiguration` 的值比较包含全部新选项；将配置传入当前及
  后续创建的编辑器。正确做法是调用 `updateOptions`；不要为了换主题重新创建模型，
  否则会丢失撤销栈，也可能破坏多个视图共享同一文档的关系。Git 作者栏使用自定义行号
  渲染器；配置更新后要重新安装作者栏，关闭作者栏或切换标签时恢复用户选择的行号模式，
  不能硬编码回绝对行号。相对行号继续由 Monaco 在光标换行时重新绘制，不增加轮询。
- macOS 隐藏行号时只隐藏数字，继续保留现有断点栏与鼠标操作区域。Monaco 的 `off`
  会连同行号层的断点装饰一起关闭，因此原生行号优先布局改用返回零宽字符的行号渲染器，
  让没有断点的行也保留可点击元素；不增加第二个断点栏。这个渲染器与 Git 作者栏的渲染器
  分开识别，不能再把所有自定义行号函数都当成作者栏而禁用断点操作。Windows 继续使用
  原有独立图标栏；持久化设置仍为 `off`，内部转换仅发生在编辑器适配层。
- 高亮方案与工作台主题独立，提供 Lithe、GitHub、One、VS Code、IntelliJ IDEA，按当前深浅外观选对应色表。
  GitHub 与 One 直接复用原 Windows JSON，移到 `frontend/editor/themes/`，Windows
  只改变导入路径。共享主题生成器同时处理词法和语义角色别名，避免 Java 字段、方法等
  仍沿用旧颜色。注释斜体可单独设置，取消时显式清除样式。
- VS Code 使用官方 `b6bfa95ebee8b183d65dee4997c0527eadfe5384` 的 Dark/Light 2026
  及其 Modern/Plus/VS 继承链；相同作用域取后定义，具体作用域优先。IDEA 使用 Community
  `74dbd42b7a8787b0707437cb857c68e78199f611` 的 Islands Dark 与 Light 编辑器色表。
  `themes/vscode.json` 与 `themes/idea.json` 保存固定来源链接；仅映射现有词法/语义角色，
  不承诺完整复现两种 IDE 的语言分析或所有 TextMate scope。注释斜体仍由用户设置决定。
  MIT/Apache 许可证及 JetBrains NOTICE 随编辑器资源打包，运行时不新增下载或可写目录。
- 彩色括号由配色方案决定：IDEA 关闭，其余当前内置方案启用；语法高亮分组显示只读状态，
  不提供单独开关。历史 `bracketPairColorization` 值不再读取或写出，避免旧偏好覆盖方案。
- Java 方法颜色不能只看通用 function：IDEA 的方法调用继承正文色，普通声明使用声明色，
  Darcula 父方案的 `STATIC_METHOD_ATTRIBUTES` 没有前景色，因此静态方法使用正文色。
  依据为同一上游提交的 `DefaultColorSchemesManager.xml` 与 `JavaHighlightingColors.java`，
  并核对了本机 Islands Dark 配置。共享语义编码保留 declaration/static（在既有修饰符末尾
  追加，保留原 bit 位置）；词法 `function.java` 在 IDEA 中先用正文色，由语义信息细分。
  不能把所有方法都改成蓝色，也不能为了截图把其他方案的 function 颜色一并改掉。
- IDEA 的 YAML 不能直接复用通用 `type/string/number` 颜色。按同一固定上游提交的
  `plugins/yaml/src/YAMLHighlighter.java` 与 `YAMLSyntaxHighlighter.java`，键名映射关键字色，
  普通标量、数字、布尔值和块文本映射正文色，单/双引号字符串保留字符串色，注释映射文档注释色。
  Light 的 `YAML_ANCHOR` 显式覆盖为 `#0000e6`，不得只读 fallback 而遗漏方案覆盖。
  复用 Monaco 0.55.1 的 YAML 状态机并复制规则，只细分普通字符串 token；新增的
  `string.yaml.plain` 继承原 `string.yaml`，因此其他方案（包括内置浅色特例）保持原样。
  插件提供的 grammar 仍优先；不修改 node_modules，不引入自研 YAML 解析器。
  这次适配不等于复刻 IDEA 的完整 YAML 词法器：上游 Monaco 对多行引号、复杂块缩进等
  边界的能力仍须逐项验收，也不包含 IDEA 的语义检查、链接、注入语言和其他语言的完整规则。
- SQL 必须覆盖 Monaco 自带的 `string.sql`、`operator.sql` 和 `predefined.sql` 特例，
  否则 IDEA 通用色表会被红色字符串、灰色逻辑运算词、紫色预定义词覆盖。
  复用 Monaco 0.55.1 状态机，逻辑运算词细分为 `operator.sql.word`；`COLLATE`
  同时出现在上游关键字与内置函数列表中，细分为 `predefined.sql.keyword`。
  IDEA 中这些词使用关键字色，普通运算符、括号与未分类内置函数使用正文色。
  其他方案继续继承原 token 样式。通用细分入口为 `language-token-roles.ts`，
  不复制整份 SQL/YAML grammar，不根据截图重新绘制文字，不宣称等价于 IDEA 数据库插件的方言语义分析。
  工作台收到显式高亮方案时同步设置括号着色，避免遗留 appearance 值或新视图默认值
  在 IDEA 方案中重新打开彩色括号。
- IDEA 词法规则不能继续继承 VS 专属前景色。保留 Monaco 界面默认值，在主题生成入口将
  `vs/vs-dark` 的每条前景色规则按最近的 IDEA 父 token 重新解析；仍保留 Monaco 的 invalid
  错误标识。这样统一覆盖 JS/TS 流程关键字、CSS/SCSS 数值单位、Swift 运算符等差异，
  不逐个复制上游默认主题，也不改变其他四套方案。
- 在同一固定 Community revision 的 `XmlHighlighterColors.java`、`PyHighlighter.java`、
  `MarkdownHighlighterColors.java`、`TomlColors.kt`、`DefaultLanguageHighlighterColors.java`
  与 `DefaultColorSchemesManager.xml` 中核对父属性后，将语言特有颜色放入已有 `idea.json`
  的 syntax 表，来源链接保存在该文件。XML/HTML 标签名、标签边界、属性与实体不能共用
  通用注解颜色；Light 标签名继承关键字，而标签边界继承正文。
  Python 引号在 Monaco 中误用 string.escape 角色，显示时恢复字符串色；真实反斜杠转义
  在不重写状态机的前提下增加子角色。Markdown 标题正文与标记、链接文字与目标、
  代码与普通字符串分别映射；TOML 使用独立 token 后缀，键与布尔值分别继承 KEYWORD
  和 PREDEFINED_SYMBOL。Java TextMate 显式保留文档注释、字符转义和注解角色。
- Protocol Buffers 使用 Monaco 已注册的 `proto` ID，Lithe 的 `protobuf` 经过语言映射转换。
  不再向不存在的 `protobuf` 注册项设置配置。这个修复属于共享映射，两个宿主均受益，
  当前仅在 macOS WebKit 实测。
- 全语言清单以 `MONACO_HIGHLIGHT_LANGUAGE_IDS` 为准，当前 47 个基础语言均有实际模型的
  深浅色字符串验收样例；清单增加时测试要求同步补样例。该检查证明 tokenizer 能加载、
  基础着色可用，不证明所有语法构造和 IDEA 语义规则相同。JSON/JSONC 的键、字符串、
  常量已有对应角色，本次复核并回归；Shell、Go、Rust、C/C++、Kotlin 等继续使用成熟
  Monaco 状态机与共享角色，未另造语言分析器。

### 当前语言兼容边界

- Java 的方法声明/调用依赖语言服务，其他语言的同名标识符也不能靠颜色表推断语义。
  IDEA 专有插件的 SQL 方言、JS/TS/CSS 语义能力不属于开源色表，不能宣称已复制其实现。
- Vue、Svelte、Angular 当前沿用 HTML，TSX 沿用 TypeScript，ReScript 沿用 JavaScript；
  模板、JSX 与嵌入语言仍受对应上游 tokenizer 限制。`.properties` 当前沿用 INI、
  `.env` 沿用 Shell，复杂转义、续行、插值不能因为基础样例着色成功而算完整适配。
- TOML、Git ignore/attributes、Nix、Elm、OCaml、Elisp、lockfile 仍使用已有轻量规则，
  没有伪称存在一套官方 IDEA 标准方案；插件可通过既有 grammar 扩展点替换。
  TLA/SystemRDL 当前明确映射 plaintext，不计入 47 个已有着色语言。
- 不把以上解析缺口用更多关键词正则掩盖；将来需要完整语法时优先接入成熟公开 grammar
  或语言插件，保留本次颜色角色边界。字体、字重、注释斜体偏好、语义 token 和完整产品
  视觉效果需分别验收，基础色表一致不等于像素一致。

### 排版与应用范围

- 字体枚举和字体缺失回退继续遵循现有
  [编程字体决策](2026-10-07-macos-editor-programming-font-family.md)。
- 作用范围是主源码编辑器、分栏、独立文件窗口与完整源码预览。原生 Git Diff、SQL
  控制台、终端、输出窗口和结果行片段保留各自的排版规则；不把所有等宽文字绑定到同一
  组编辑器选项。界面提示明确说明应用于所有项目的源码编辑器。

## 考虑过的备选方案

- 复制 Windows 色表到 macOS：会产生两个需要同步的版本，改为移动原文件并共享读取。
- 将整个工作台主题与源码配色绑定：不能表达用户保留界面主题、只更换代码颜色的需求。
- 导入外部配置后再补设置：导入结果缺少可见且可修改的落点。本次先完成设置本身，
  不提前引入外部格式解析或插件兼容层。

## 后果

新增偏好在原有应用设置存储中保存，生命周期和所有权均不变。色表属于构建输入，随
编辑器资源打包；运行时只读，不下载字体或主题，不产生新的缓存目录，不改变签名包
字节，也不影响 Sparkle 增量更新基线。

方案只覆盖当前列出的预设与选项，尚不等价于完整的 VS Code/IDEA 主题和配置格式。
将来增加导入时必须转换单位、颜色角色与配置作用域，不能直接透传外部编辑器选项对象。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AppSettingsTests|MonacoWorkbenchThemeTests|SettingsSearchVocabularyTests|ContextMenuCoverageTests|EditorFontFamilyTests'`
- `./scripts/macos/probe/probe-macos-monaco.sh --workbench-tests`：真实 WebKit 验证新旧分栏、字号和行高、
  显示选项、深浅配色、斜体撤销、内容和撤销栈保留；隐藏行号后的断点图标、已有断点与空白行的鼠标点击、恢复相对行号。
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `node scripts/architecture/verify-editor-boundaries.mjs`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`

自动化不替代完整产品的设置布局、键盘操作、多项目与重启验收；矩阵单独记录待验证状态。

## 适用范围

- `macos/Sources/Lithe/Models/Settings/EditorAppearanceSettings.swift`
- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
- `macos/Sources/Lithe/Platform/MacOS/MonacoWorkbenchEditor.swift`
- `frontend/editor/src/theme.ts`
- `frontend/editor/src/workbench.ts`
- `frontend/editor/themes/`
- `windows/tauri/src/extensions/themes/theme-loader.ts`
