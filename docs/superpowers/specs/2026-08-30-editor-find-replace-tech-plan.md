# 编辑器内查找替换技术方案

依据 `docs/superpowers/specs/2026-08-29-editor-find-replace-design.md` 与 Issue #327。
范围仅限 macOS，不改动 Rust Core 与共享契约。

## 分层与文件变更清单

| 层 | 文件 | 变更 |
| --- | --- | --- |
| Models/Editor | `FindInFileMatcher.swift`（新增） | `FindInFileOptions` 与 `FindInFileMatcher` 纯 Foundation 值类型 |
| Models/Editor | `EditorChromeModel.swift` | 新增 `findOptions`、`isReplaceVisible`、`findReplaceText`；`resetFindBar` 保留选项与替换文本 |
| Models/AppModel | `AppModelSupportTypes.swift` | `FindNotificationKeys` 增加 `matchCase`/`wholeWords`/`regularExpression`/`replacement`；新增 `litheFindReplaceNext`、`litheFindReplaceAll` |
| Models/AppModel | `AppModel+FindInFile.swift`（新增） | 文件内查找/替换门面（访问器、`showFindBar`、`showReplaceBar`、`setFindOptions`、`replaceNextFindMatch`、`replaceAllFindMatches` 等），从 `AppModel.swift` 抽出以满足行数上限 |
| Models/AppModel | `AppModel.swift` | 既有文件内查找方法整体移至 `AppModel+FindInFile.swift`（净减行数） |
| Models/AppModel | `AppModel+FeatureState.swift` | `canPerformShortcutCommand` 将 `replace-in-file` 与 `find-in-file` 同等对待 |
| Models/Keymap | `LitheCommandCatalog.swift` | 新增 `replace-in-file`，默认绑定 Cmd+R |
| Models | `LitheAction.swift` | 注册 `replace-in-file` action |
| Views/Editor | `FindBarView.swift` | 选项菜单、替换行、非法正则错误色、焦点管理 |
| Views/Editor | `CodeEditorView.swift` | `CodeTextView` 选项化匹配、替换下一处/全部；`updateNSView` 与通知通路携带选项 |
| Views | `LitheApp.swift` | Navigate 菜单在 Find in File… 下方新增 Replace in File… |
| Resources | `zh-Hans.lproj/Localizable.strings` | 新增三条翻译（菜单标题、命令标题、命令副标题） |
| Tests | `FindInFileMatcherTests.swift`（新增）、`EditorChromeModelTests.swift`、`KeyboardShortcutTests.swift` | 见测试策略 |

## 匹配语义（FindInFileMatcher）

| 选项组合 | 实现 |
| --- | --- |
| 默认（全关） | `NSString.range(of:options:)` 扫描，`[.caseInsensitive, .diacriticInsensitive]`，保持现状 |
| Match Case | 同上，比较选项为空 |
| Whole Words（字面量） | 逐候选扫描 + 词边界校验；候选被拒后从下一字符继续，保证不漏掉重叠位置的合法匹配 |
| Regular Expression | `NSRegularExpression` 枚举，`matchCase` 为 false 时加 `.caseInsensitive` |
| Whole Words + Regex | 模式外包一层 `\b(?:…)\b`（非捕获，不影响分组编号） |

- 词字符：字母（Unicode `isAlphabetic`）、数字（`numericType != nil`）和下划线；串首串尾视为边界。
- 边界校验按 UTF-16 位置读取全文，并组合代理对后再分类，窗口扫描时也能看到真实相邻字符。
- 正则编译失败：`isValid == false`，不产生匹配，不抛错。
- 空查询返回空匹配；零宽度正则匹配（如 `a*`）跳过，不参与高亮与替换。
- 替换模板：正则模式按 `NSRegularExpression` 语义展开（`$0`–`$9` 数字分组引用）；
  字面量模式原样使用。注意：当前 SDK 的 `NSRegularExpression` 不会展开 `${name}` 命名分组模板，
  该类模板按平台行为原样返回。
- `matchRanges(in:range:)` 支持子范围枚举，供按行增量重算复用；`enumerateMatches` 以全文为底、仅限制范围，
  使 `\b` 与边界校验始终基于真实上下文。

## 数据流与通知

- 查找栏关闭再打开：`findOptions`、`findReplaceText` 在会话内保留；`resetFindBar` 只重置可见性、查询与匹配计数，同时收起替换行。
- `litheFindQueryChanged` 扩展为携带 `query` + 三个选项；`setFindBarQuery` 与 `setFindOptions` 都通过同一私有方法发送。
- `CodeTextView` 的两个入口同步扩展：
  - `updateNSView`：Coordinator 追踪 `lastFindOptions`，变化时走 `syncFindState(isVisible:query:options:)`；
  - `handleFindQueryChanged`：从 `userInfo` 重建 `FindInFileOptions`。
- `CodeTextView` 持有当前 `findMatcher`（查询 + 选项），`applyFindEdit` 与替换操作复用；查询与已存值不一致时按传入查询重建。
- `litheFindReplaceNext` / `litheFindReplaceAll` 携带替换文本，`CodeTextView` 观察后执行替换，模式与 `litheFindNavigate` 一致。

## 编辑器替换管线

- 替换下一处：`insertText(_:replacementRange:)` 进入标准输入管线（撤销、`shouldChangeText` 委托、装饰刷新一致）；
  完成后选中替换区之后的第一个匹配，跳过替换文本自身新产生的匹配；没有更靠后的匹配时从文档开头回绕，
  仍跳过与替换区重叠的匹配。
- 替换全部：先基于当前匹配列表按模板展开重建全文，再 `shouldChangeText` + `NSTextStorage.replaceCharacters` +
  `didChangeText` 一步提交，形成单个撤销步骤；随后整篇重算匹配并校正选区。
- 匹配高亮、n/m 计数经由既有 `reportFindState` → `scheduleFindStateUpdate` 通路刷新。
- 只读文档：文本视图 `isEditable == false`，两个替换入口先检查 `isEditable`，`shouldChangeText` 返回 false，替换为无操作。
- 诊断、Git 行标记、Local History、自动保存由 `textDidChange` 既有管线自然触发，与手工编辑等价。

## 按行增量重算窗口

`applyFindEdit` 保留按行增量优化，重算窗口在编辑所在行基础上向两侧各扩一个字符（夹取到文档边界），
并移除所有与窗口相交的旧匹配后重新枚举。扩一个字符的原因：行首/行尾匹配的全词边界落在相邻行，
编辑相邻行的首尾字符会改变其合法性，只有窗口覆盖到该字符才能移除并重算。

## 命令与菜单

- `replace-in-file` 加入 `LitheCommandCatalog`（Navigation 组，默认 Cmd+R），可在 Keymap 设置中自定义；
  Cmd+R 与现有 `run`（Ctrl+R）、`replace-in-project`（Shift+Cmd+R）无冲突。
- `LitheActionRegistry`、`performShortcutCommand`/`canPerformShortcutCommand`、Navigate 菜单同步注册；
  `KeyboardShortcutTests` 中命令总数断言 31 → 32。
- `AppLocalizationTests` 要求命令标题/副标题有 zh-Hans 翻译，补齐三条词条。

## 测试策略

新增 `FindInFileMatcherTests`（Swift Testing，纯同步逻辑，无等待）：
字面量默认大小写/音调不敏感回归、Match Case 精确匹配、Whole Words 边界（下划线与数字、串首串尾、
拒绝候选后继续扫描）、正则捕获组模板展开、字面量替换原样、非法模式 `isValid == false` 且空匹配、
空查询、零宽度跳过、子范围枚举与 `\b` 包裹组合。

扩展 `EditorChromeModelTests`：`findOptions`/`isReplaceVisible`/`findReplaceText` 仅在变化时发布；
`resetFindBar` 保留选项与替换文本、收起替换行。

## 验证

```bash
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter FindInFileMatcher
./scripts/test-macos.sh
./scripts/verify-service-boundaries.sh
```
