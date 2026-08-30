# 编辑器内查找替换设计

## 背景

GitHub Issue [#327](https://github.com/1lck/Lithe-IDEA/issues/327) 要求补全编辑器内的查找替换。当前 `FindBarView` 只有查找字段，匹配逻辑在 `CodeEditorView` 的 `updateFindMatches` 中写死大小写不敏感，没有大小写、全词、正则选项，也没有文件内替换。项目级搜索（`SearchSidebarView`、`ProjectReplaceView`）已有完整的选项与替换能力，编辑器内外的体验不一致；macOS 上 Cmd+R 目前未绑定。

本设计只覆盖 macOS，不改动 Rust Core，也不引入新的跨平台契约。

## 目标

- 文件内查找支持 Match Case、Whole Words、Regular Expression 三个选项，与项目搜索语义一致。
- 查找栏可展开替换行，支持替换下一处和替换全部。
- Cmd+R 呼出替换行，命令进入 `LitheCommandCatalog`，可在 Keymap 设置中自定义。
- 替换走标准文本变更管线：整次替换全部是一个撤销步骤；诊断、行索引、Git 行标记、自动保存与手工编辑行为一致。
- 非法正则给出可见提示，不影响编辑器其他功能。

## 非目标

- 不改动项目级搜索与项目级替换。
- 不做多光标、查找历史持久化和查找结果面板。
- 查找选项与替换文本只在当前工作区会话内保留，不写入设置。
- 不改动 Diff 内搜索和共享契约。

## 功能范围

### 匹配选项

- 三个选项默认全部关闭，保持现有行为（大小写不敏感、音调不敏感）。
- Whole Words 按标准词边界判断：字母、数字和下划线算词字符，串首串尾视为边界。
- Regular Expression 使用 `NSRegularExpression` 语法；选项同时开启时模式外包一层 `\b(?:…)\b`。
- 零宽度正则匹配（如 `a*`）跳过，避免无意义的高亮和替换。

### 替换

- Replace：替换当前匹配并自动跳到下一处匹配；跳过替换文本中新产生的匹配，避免与替换结果死循环。
- Replace All：一次性替换全部匹配，整个操作只产生一个撤销步骤，撤销后恢复原文。
- 替换完成后匹配列表、计数和高亮立即按新文本刷新。
- 正则模式下替换模板按 `NSRegularExpression` 语义展开（`$1`、`${name}`）；字面量模式下替换文本原样使用。

### 入口与快捷键

- 查找栏内提供选项菜单和替换行开关。
- Cmd+F 打开查找（保持现状，隐藏替换行）；Cmd+R 打开带替换行的查找栏；再次 Cmd+R 在查找/替换间切换。
- Edit 菜单在 Find in File… 下方新增 Replace in File…。
- `replace-in-file` 命令加入命令目录，默认绑定 Cmd+R，可在 Keymap 中修改。

### 键盘行为

- 替换输入框内 Return = 替换下一处，Shift+Return = 替换全部。
- 查找框内 Return / Shift+Return 维持现状（下一个/上一个匹配）。
- Esc 关闭查找栏，行为不变。

## 界面设计

FindBar 保持现有单行结构和宽度上限，纵向扩展：

1. 第一行：选项菜单、查找框、n/m 计数、上/下一个、替换行开关、关闭。
2. 选项菜单复用项目搜索的 `slider.horizontal.3` 图标与 Toggle 菜单样式；任一选项开启时图标着色。
3. 替换行（可展开）：替换图标、替换输入框、Replace 与 Replace All 按钮；无匹配时按钮禁用。
4. 非法正则时查找图标显示错误色；修正查询后立即恢复。

## 应用分层与数据流

### Models

- 新增 `Models/Editor/FindInFileOptions` 与 `FindInFileMatcher`：纯 Foundation 值类型，负责匹配枚举（字面量扫描、全词边界校验、正则枚举）与替换模板展开。不依赖 AppKit，保证可确定性单测。
- `EditorChromeModel` 新增 `findOptions`、`isReplaceVisible`、`findReplaceText`；查找栏关闭再打开时选项保留。

### Application / AppModel

- `showFindBar` 保持现有语义并隐藏替换行；新增 `showReplaceBar`。
- 选项与替换文本 setter 直接更新 `EditorChromeModel`；查找栏现有通知通路扩展为同时携带查找选项。
- 新增 `litheFindReplaceNext`、`litheFindReplaceAll` 通知，与现有 `litheFindNavigate` 走同一模式。
- `canPerformShortcutCommand` 将 `replace-in-file` 与 `find-in-file` 同等对待（要求存在活动文档）。

### Views

- `FindBarView` 只渲染状态并调用 `AppModel` 操作。
- `CodeEditorView` 内的文本视图持有匹配列表：
  - `updateFindMatches`、`applyFindEdit` 改用 `FindInFileMatcher`；保留现有的按行增量重算优化，重算窗口向两侧各扩一个字符，使全词边界能看到真实相邻字符。
  - 替换下一处通过 `insertText(_:replacementRange:)` 进入标准输入管线（撤销、委托回调、装饰刷新全部一致），随后选中下一处匹配。
  - 替换全部通过 `shouldChangeText` + `NSTextStorage` 批量替换 + `didChangeText` 一步完成，形成单个撤销项，之后整篇重算匹配。
  - `updateNSView` 的查找同步条件扩展到查找选项，切换选项立即重算计数与高亮。

## 冲突与错误处理

- 非法正则不抛错、不产生匹配，仅在查找栏显示错误状态。
- 只读文档由现有 `isReadOnly` 守卫阻止变更，替换为无操作。
- 替换行展开后焦点移动到替换输入框。
- 替换全部的文本变更与一次全量编辑等价：诊断、Git 行标记、Local History、自动保存按现有管线自然触发。

## 测试策略

新增 `FindInFileMatcherTests`（Swift Testing，纯逻辑，无等待）：

- 字面量默认大小写不敏感（含音调不敏感回归）。
- Match Case 精确匹配。
- Whole Words 边界：下划线与数字算词字符、串首串尾边界、拒绝候选后继续向后扫描。
- 正则捕获组模板展开；字面量模式替换文本原样使用。
- 非法模式返回空匹配并报告无效。
- 空查询返回空匹配；零宽度匹配被跳过。

扩展 `EditorChromeModelTests`：选项与替换行状态变更、`resetFindBar` 保留查找选项。

### 仓库验证

```bash
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter FindInFileMatcher
./scripts/test-macos.sh
./scripts/verify-service-boundaries.sh
```

## 验收标准

1. Cmd+F 查找行为与现状一致；三个选项可在查找栏内切换并立即刷新 n/m 计数与高亮。
2. Cmd+R 打开替换行，按钮与 Return / Shift+Return 均可替换；替换全部只产生一个撤销步骤，撤销后完全恢复原文。
3. 替换当前处后自动跳到下一处匹配，不会立即命中替换文本本身。
4. 全词、正则、大小写选项与项目搜索语义一致；正则替换模板支持捕获组。
5. 非法正则显示错误状态，编辑器不崩溃、计数归零。
6. 替换后诊断、Git 行标记与自动保存行为与手工编辑一致。
7. Edit 菜单与 Keymap 中出现 Replace in File…，快捷键可自定义。
8. 上述验证脚本全部通过。
