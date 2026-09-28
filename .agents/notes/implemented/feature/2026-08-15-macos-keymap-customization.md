# Agent 笔记：macOS 自定义快捷键集中目录与运行时覆盖

状态：已实现

## 先说结论

快捷键只有一个集中命令目录，菜单、搜索、设置和实际分发都从这个目录生成。用户可以在 macOS、IntelliJ IDEA Classic 和 Eclipse 三套预设间切换；每套预设的自定义修改分别保存。持久化使用稳定的命令 ID，显示文字或分组变化不能随意改变 ID；普通输入按键也不能被误识别成全局命令。

## 问题

macOS 的快捷键同时出现在菜单、Search Everywhere、双击 Shift 监听器和
设置界面中。如果设置页只保存用户选择，而其他入口仍各自维护默认值，
就会出现界面显示、实际触发和持久化状态不一致的问题。

还需要避免把普通文本输入按键变成全局命令，避免录制快捷键时触发正常命令，
并保证损坏的用户设置不会让整个快捷键系统失效。

## 决策

macOS 使用集中式 `LitheCommandCatalog` 作为命令目录。每个命令拥有稳定
ID、本地化标题、分组和默认绑定；菜单、Search Everywhere、设置页和实际
事件分发都从目录和当前有效绑定生成。命令 ID 是持久化兼容面，不能因为
显示文案或界面分组变化而修改。

快捷键使用类型化的 `KeyboardShortcutBinding` 表示。普通按键保存按键值和
修饰键，双击修饰键单独建模；持久化使用稳定的 `Codable` 结构，展示用的
`⌘`、`⌥` 等字符串只在渲染时生成。普通字符必须带有
Command、Control 或 Option 之一，功能键、方向键等特殊按键可以单独使用。

`AppSettings` 保存当前预设和按预设分开的版本化用户覆盖。旧版单套
`keyboardShortcutOverrides` 载荷只在首次迁移时归入 macOS 预设：

- 没有命令条目时使用目录默认值；
- 非空列表替换该命令的全部绑定；
- 空列表表示明确禁用该命令；
- 删除覆盖条目恢复该命令默认值；
- 未知命令、非法绑定和重复绑定被忽略；
- 整个载荷无法解码时回退到全部默认值。

预设只映射 Lithe 已有且与 IntelliJ Community 源码能对应的操作，未映射的
命令沿用 Lithe 默认绑定。切换预设时先切换预设身份，再发布该预设的覆盖值，
使设置页、菜单和原生监听器同时看到新绑定；录制中的操作在切换前取消。
应用级恢复默认清除所有预设的用户覆盖并返回 macOS，Keymap 页的恢复默认
只清除当前预设的覆盖。官方映射依据是 IntelliJ Community 的
[`$default.xml`](https://github.com/JetBrains/intellij-community/blob/master/platform/platform-resources/src/keymaps/%24default.xml)
和 [`Eclipse (Mac OS X).xml`](https://github.com/JetBrains/intellij-community/blob/master/plugins/keymaps/eclipse-keymap/resources/keymaps/Eclipse%20%28Mac%20OS%20X%29.xml)；
Eclipse 文件继承的 macOS 映射见 [`Mac OS X 10.5+.xml`](https://github.com/JetBrains/intellij-community/blob/master/platform/platform-resources/src/keymaps/Mac%20OS%20X%2010.5%2B.xml)。

`KeyboardShortcutFeatureModel` 负责合成有效值、录制状态、冲突检测、单项
恢复和全部恢复。相同绑定发生冲突时指出占用它的命令并拒绝保存，不自动
覆盖已有命令。`ShortcutSessionCoordinator` 将有效注册同步给 macOS
监听器；录制快捷键时暂停命令分发，非活动会话和已关闭会话不执行排队的
旧命令。

Search Everywhere 的 macOS 预设保留双击 Shift 和 `⇧⌘O` 两个默认入口。
该功能只属于 macOS，不把 Windows keymap 或新的跨平台
快捷键契约纳入本决策。

## 考虑过的备选方案

- **让菜单、搜索和监听器各自维护快捷键**：改动局部、实现简单，但设置
  修改后必然产生显示或触发行为漂移，因此采用集中目录。
- **持久化展示字符串**：可以直接显示和保存，但会受到本地化、符号格式和
  展示顺序变化影响，因此保存类型化值。
- **允许普通字母不带操作修饰键**：录制更自由，但会劫持编辑器输入，
  因此仅允许功能键或带 Command、Control、Option 的普通字符。
- **发生冲突时自动覆盖原命令**：用户不容易察觉原命令已失效，因此改为
  明确报告冲突并拒绝保存。
- **立即设计 Windows 与 macOS 共用 keymap 契约**：两端事件模型和原生
  编辑行为不同，当前收益不足以抵消跨平台兼容面，暂不扩展范围。
- **直接导入 IDEA 全量 keymap 文件**：Lithe 没有 IDEA 的全部命令和动作
  语义，全量导入会产生无法执行的配置；只映射现有对应操作。自定义 keymap
  文件导入、导出和云同步仍不在本次范围。

## 后果

快捷键的默认值、用户覆盖、设置展示和实际触发使用同一份有效状态，修改
后可以立即生效并跨应用重启保留。新增命令时必须同时进入命令目录，并由
现有动作注册、监听器和测试覆盖，减少遗漏入口的机会。

代价是命令 ID、绑定编码和目录语义成为需要长期维护的兼容面；快捷键录制、
原生编辑按键和 macOS 事件监听仍然是平台专属逻辑，不能把这套实现直接
当作 Windows 的实现。

## 验证

- `./scripts/test-macos.sh`
- `./scripts/verify-service-boundaries.sh`
- `macos/Tests/LitheTests/KeyboardShortcutTests.swift`
- `macos/Tests/LitheTests/AppLocalizationTests.swift`
- `./scripts/verify-agent-notes.sh`

测试覆盖命令目录唯一性和默认冲突、绑定编码往返、用户覆盖持久化、禁用和
恢复、损坏载荷回退、过滤、冲突拒绝、监听器更新以及录制期间暂停分发。

## 适用范围

- `macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift`
- `macos/Sources/Lithe/Models/Keymap/KeyboardShortcutModels.swift`
- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Sources/Lithe/Application/Features/KeyboardShortcutFeatureModel.swift`
- `macos/Sources/Lithe/Application/Features/ShortcutSessionCoordinator.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift`
- `macos/Sources/Lithe/Views/App/KeyboardShortcutSettingsView.swift`
- `macos/Tests/LitheTests/KeyboardShortcutTests.swift`
- `macos/Tests/LitheTests/AppLocalizationTests.swift`
