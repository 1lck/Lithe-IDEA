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
  显示选项、深浅配色、斜体撤销、内容和撤销栈保留。
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
