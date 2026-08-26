# macOS 自定义快捷键实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为 macOS Settings 增加 Keymap 页面，让 27 个工作区命令的快捷键可搜索、录制、禁用、恢复并跨重启持久化。

**架构：** Foundation-only 的命令目录与快捷键值类型提供稳定默认值，`AppSettings` 只保存用户覆盖，`KeyboardShortcutFeatureModel` 合成有效 keymap 并处理冲突与录制状态。macOS 适配器把 `NSEvent` 映射为快捷键并分发稳定命令 ID，SwiftUI 菜单、Search Everywhere 与设置页从同一功能模型读取显示值。

**技术栈：** Swift 5 应用代码、Swift 6 测试、SwiftUI、AppKit、Combine、Swift Testing、现有 `KeyValueStore`。

---

## 文件结构

### 新建文件

- `macos/Sources/Lithe/Models/Keymap/KeyboardShortcutModels.swift`：快捷键值、修饰键、触发类型、显示文本和 Codable 兼容格式。
- `macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift`：27 个稳定命令 ID、分组、标题、说明和默认绑定。
- `macos/Sources/Lithe/Application/Features/KeyboardShortcutFeatureModel.swift`：默认值与覆盖值合成、过滤、冲突、录制、重置。
- `macos/Sources/Lithe/Views/App/KeyboardShortcutSettingsView.swift`：Keymap 页面、分组命令行、空状态和恢复操作。
- `macos/Sources/Lithe/Views/App/KeyboardShortcutRecorderView.swift`：AppKit 按键录制控件，只捕获输入并返回候选绑定。
- `macos/Sources/Lithe/Views/App/KeyboardShortcut+SwiftUI.swift`：有效快捷键到 SwiftUI `KeyEquivalent` 与 `EventModifiers` 的显示桥接。
- `macos/Tests/LitheTests/KeyboardShortcutTests.swift`：目录、值模型、覆盖合成、冲突、持久化和过滤单元测试。
- `macos/Tests/LitheTests/MacKeyboardShortcutTests.swift`：AppKit 事件映射和匹配单元测试。

### 修改文件

- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`：加载、保存和恢复快捷键覆盖值。
- `macos/Sources/Lithe/Core/Ports/PlatformUI.swift`：把双击 Shift 专用检测接口扩展为可更新的快捷键检测接口。
- `macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift`：统一处理普通按键、双击修饰键、挂起和动态注册。
- `macos/Sources/Lithe/Application/Composition/AppServices.swift`：保留平台检测器工厂依赖并使用新接口。
- `macos/Sources/Lithe/Models/AppModel/AppModel.swift`：持有功能模型、监听设置变化并更新检测器。
- `macos/Sources/Lithe/Models/AppModel/AppModel+FeatureState.swift`：按稳定命令 ID 路由 27 个操作。
- `macos/Sources/Lithe/Models/LitheAction.swift`：从命令目录生成元数据，并展示当前有效快捷键。
- `macos/Sources/Lithe/LitheApp.swift`：菜单使用当前主按键，而非硬编码组合。
- `macos/Sources/Lithe/Views/App/SettingsView.swift`：新增 Keymap 分类并嵌入专用页面。
- `macos/Tests/LitheTests/AppLocalizationTests.swift`：验证新增简体中文资源完整。
- `macos/Resources/zh-Hans.lproj/Localizable.strings`：新增 Keymap 页面中文文案。

---

### 任务 1：快捷键值模型与稳定命令目录

**文件：**

- 创建：`macos/Tests/LitheTests/KeyboardShortcutTests.swift`
- 创建：`macos/Sources/Lithe/Models/Keymap/KeyboardShortcutModels.swift`
- 创建：`macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift`

- [ ] **步骤 1：编写目录和显示格式的失败测试**

```swift
import Foundation
import Testing
@testable import Lithe

@Suite("Keyboard shortcuts")
@MainActor
struct KeyboardShortcutTests {
    @Test
    func catalogHasStableUniqueCommandsAndConflictFreeDefaults() throws {
        let commands = LitheCommandCatalog.commands
        #expect(commands.count == 27)
        #expect(Set(commands.map(\.id)).count == commands.count)

        let owners = commands.flatMap { command in
            command.defaultBindings.map { (binding: $0, commandID: command.id) }
        }
        for (index, owner) in owners.enumerated() {
            #expect(!owners.dropFirst(index + 1).contains {
                $0.binding == owner.binding && $0.commandID != owner.commandID
            })
        }
    }

    @Test
    func bindingsUseCanonicalDisplayOrderAndRoundTripThroughJSON() throws {
        let binding = KeyboardShortcutBinding.keyPress(
            key: "u",
            modifiers: [.control, .option, .shift, .command]
        )
        #expect(binding.displayText == "⌃⌥⇧⌘U")
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(KeyboardShortcutBinding.self, from: data) == binding)
        #expect(KeyboardShortcutBinding.doubleTap(.shift).displayText == "⇧ ⇧")
    }

    @Test
    func plainTextKeysRequireANonShiftModifier() {
        #expect(!KeyboardShortcutBinding.keyPress(key: "a", modifiers: []).isAssignable)
        #expect(!KeyboardShortcutBinding.keyPress(key: "a", modifiers: [.shift]).isAssignable)
        #expect(KeyboardShortcutBinding.keyPress(key: "a", modifiers: [.command]).isAssignable)
        #expect(KeyboardShortcutBinding.keyPress(key: "f5", modifiers: []).isAssignable)
    }
}
```

- [ ] **步骤 2：运行测试并确认因类型缺失而失败**

运行：

```bash
./scripts/test-macos.sh --filter KeyboardShortcutTests
```

预期：FAIL，编译器报告找不到 `LitheCommandCatalog` 和 `KeyboardShortcutBinding`。

- [ ] **步骤 3：实现最小快捷键值类型**

在 `KeyboardShortcutModels.swift` 中实现：

```swift
import Foundation

struct KeyboardShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

enum KeyboardModifier: String, Codable, Hashable, Sendable {
    case shift
}

enum KeyboardShortcutBinding: Codable, Hashable, Sendable {
    case keyPress(key: String, modifiers: KeyboardShortcutModifiers)
    case doubleTap(KeyboardModifier)

    var displayText: String {
        switch self {
        case let .keyPress(key, modifiers):
            let prefix = [
                modifiers.contains(.control) ? "⌃" : "",
                modifiers.contains(.option) ? "⌥" : "",
                modifiers.contains(.shift) ? "⇧" : "",
                modifiers.contains(.command) ? "⌘" : ""
            ].joined()
            return prefix + Self.displayName(for: key)
        case .doubleTap(.shift):
            return "⇧ ⇧"
        }
    }

    var isAssignable: Bool {
        switch self {
        case let .keyPress(key, modifiers):
            let isTextKey = key.count == 1
            return !isTextKey || !modifiers.intersection([.command, .control, .option]).isEmpty
        case .doubleTap:
            return true
        }
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "delete": "⌫"
        default: key.uppercased()
        }
    }
}
```

使用显式 Codable discriminator（`kind`、`key`、`modifiers`、`modifier`）替代编译器合成格式，保证 JSON 兼容面稳定。键值统一为小写 token；允许 `a`–`z`、`0`–`9`、常用标点、`f1`–`f20`、方向键、Return、Tab、Space 和 Delete。

- [ ] **步骤 4：实现 27 个命令的确定性目录**

在 `LitheCommandCatalog.swift` 中定义 `LitheCommandDefinition` 与静态目录。保留现有 22 个 `LitheAction.id`，新增 `save`、`search-everywhere`、`find-next`、`find-previous` 和 `go-to-implementation`。默认值严格复制当前行为：

```swift
static let commands: [LitheCommandDefinition] = [
    .init(id: "run", title: "Run", subtitle: "Run selected configuration", group: .run,
          defaultBindings: [.keyPress(key: "r", modifiers: [.control])]),
    .init(id: "debug", title: "Debug", subtitle: "Start debugging", group: .run,
          defaultBindings: [.keyPress(key: "d", modifiers: [.control])]),
    .init(id: "save", title: "Save", subtitle: "Save the active document", group: .project,
          defaultBindings: [.keyPress(key: "s", modifiers: [.command])]),
    .init(id: "search-everywhere", title: "Search Everywhere", subtitle: "Find files and actions", group: .navigation,
          defaultBindings: [.doubleTap(.shift), .keyPress(key: "o", modifiers: [.shift, .command])])
]
```

其余默认值按设计规格逐项迁移；无默认值使用空数组。初始化时加入断言，拒绝重复命令 ID、非法默认绑定和跨命令冲突。

- [ ] **步骤 5：运行定向测试并确认通过**

运行：`./scripts/test-macos.sh --filter KeyboardShortcutTests`

预期：PASS，3 个测试通过。

- [ ] **步骤 6：提交模型与目录**

```bash
git add macos/Tests/LitheTests/KeyboardShortcutTests.swift macos/Sources/Lithe/Models/Keymap/KeyboardShortcutModels.swift macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift
git commit -m "feat(macOS): 添加快捷键命令目录"
```

---

### 任务 2：用户覆盖持久化与有效 keymap

**文件：**

- 修改：`macos/Tests/LitheTests/KeyboardShortcutTests.swift`
- 修改：`macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- 创建：`macos/Sources/Lithe/Application/Features/KeyboardShortcutFeatureModel.swift`

- [ ] **步骤 1：编写持久化、禁用、恢复和冲突的失败测试**

```swift
@Test
func overridesPersistDisableAndResetWithoutChangingOtherSettings() throws {
    let store = KeyboardShortcutTestStore()
    let settings = AppSettings(store: store)
    let feature = KeyboardShortcutFeatureModel(settings: settings)
    let replacement = KeyboardShortcutBinding.keyPress(key: "k", modifiers: [.command, .option])

    try feature.replaceBindings(for: "run", with: [replacement])
    #expect(feature.effectiveBindings(for: "run") == [replacement])
    #expect(AppSettings(store: store).keyboardShortcutOverrides["run"] == [replacement])

    try feature.replaceBindings(for: "run", with: [])
    #expect(feature.effectiveBindings(for: "run").isEmpty)

    feature.resetCommand("run")
    #expect(feature.effectiveBindings(for: "run") == LitheCommandCatalog.command(id: "run")?.defaultBindings)

    settings.editorFontSize = 17
    try feature.replaceBindings(for: "debug", with: [replacement])
    feature.resetAll()
    #expect(settings.editorFontSize == 17)
    #expect(settings.keyboardShortcutOverrides.isEmpty)
}

@Test
func conflictReportsTheOwningCommandAndDoesNotPersist() throws {
    let settings = AppSettings(store: KeyboardShortcutTestStore())
    let feature = KeyboardShortcutFeatureModel(settings: settings)
    let findShortcut = try #require(feature.effectiveBindings(for: "find-in-file").first)

    #expect(throws: KeyboardShortcutUpdateError.conflict(commandID: "find-in-file")) {
        try feature.replaceBindings(for: "run", with: [findShortcut])
    }
    #expect(settings.keyboardShortcutOverrides["run"] == nil)
}
```

再增加损坏 JSON 测试：直接向 `settings.keyboardShortcutOverrides` 对应 store key 写入无效 `Data`，新建 `AppSettings` 后应得到空覆盖字典和目录默认值。

- [ ] **步骤 2：运行测试并确认因 API 缺失而失败**

运行：`./scripts/test-macos.sh --filter KeyboardShortcutTests`

预期：FAIL，找不到 `keyboardShortcutOverrides` 和 `KeyboardShortcutFeatureModel`。

- [ ] **步骤 3：在 AppSettings 中保存版本化覆盖值**

新增：

```swift
private struct KeyboardShortcutOverridesPayload: Codable {
    let version: Int
    let commands: [String: [KeyboardShortcutBinding]]
}

@Published private(set) var keyboardShortcutOverrides: [String: [KeyboardShortcutBinding]]

func setKeyboardShortcutOverrides(_ value: [String: [KeyboardShortcutBinding]]) {
    keyboardShortcutOverrides = value
    saveKeyboardShortcutOverrides()
}
```

初始化时只保留目录中存在且全部合法的条目。`restoreDefaults()` 调用 `setKeyboardShortcutOverrides([:])`。载荷版本首版为 `1`，无法解码或版本不支持时回退空字典。

- [ ] **步骤 4：实现功能模型的合成和冲突规则**

```swift
@MainActor
final class KeyboardShortcutFeatureModel: ObservableObject {
    @Published private(set) var recordingCommandID: String?
    private let settings: AppSettings

    var commands: [LitheCommandDefinition] { LitheCommandCatalog.commands }

    func effectiveBindings(for commandID: String) -> [KeyboardShortcutBinding] {
        if let override = settings.keyboardShortcutOverrides[commandID] { return override }
        return LitheCommandCatalog.command(id: commandID)?.defaultBindings ?? []
    }

    func replaceBindings(for commandID: String, with bindings: [KeyboardShortcutBinding]) throws {
        guard LitheCommandCatalog.command(id: commandID) != nil else {
            throw KeyboardShortcutUpdateError.unknownCommand(commandID)
        }
        guard bindings.allSatisfy(\.isAssignable), Set(bindings).count == bindings.count else {
            throw KeyboardShortcutUpdateError.invalidBinding
        }
        if let owner = conflictingCommand(for: bindings, excluding: commandID) {
            throw KeyboardShortcutUpdateError.conflict(commandID: owner.id)
        }
        var overrides = settings.keyboardShortcutOverrides
        overrides[commandID] = bindings
        settings.setKeyboardShortcutOverrides(overrides)
    }
}
```

实现 `resetCommand`、`resetAll`、`beginRecording`、`endRecording`、`filteredCommands(query:)` 和稳定冲突查询。模型订阅 `settings.$keyboardShortcutOverrides` 并转发 `objectWillChange`。

- [ ] **步骤 5：运行定向测试并确认通过**

运行：`./scripts/test-macos.sh --filter KeyboardShortcutTests`

预期：PASS，目录、持久化、禁用、恢复、损坏回退和冲突测试全部通过。

- [ ] **步骤 6：提交持久化与功能模型**

```bash
git add macos/Tests/LitheTests/KeyboardShortcutTests.swift macos/Sources/Lithe/Models/Settings/AppSettings.swift macos/Sources/Lithe/Application/Features/KeyboardShortcutFeatureModel.swift
git commit -m "feat(macOS): 持久化快捷键覆盖设置"
```

---

### 任务 3：macOS 事件映射与动态检测器

**文件：**

- 创建：`macos/Tests/LitheTests/MacKeyboardShortcutTests.swift`
- 修改：`macos/Sources/Lithe/Core/Ports/PlatformUI.swift`
- 修改：`macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift`
- 修改：`macos/Sources/Lithe/Application/Composition/AppServices.swift`
- 修改：`macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`

- [ ] **步骤 1：为纯事件映射与匹配编写失败测试**

```swift
import AppKit
import Testing
@testable import Lithe

@Suite("macOS keyboard shortcut mapping")
struct MacKeyboardShortcutTests {
    @Test
    func mapsCharactersAndModifiersToCanonicalBinding() {
        let binding = MacKeyboardShortcutEventMapper.binding(
            keyCode: 3,
            charactersIgnoringModifiers: "f",
            modifierFlags: [.command, .shift]
        )
        #expect(binding == .keyPress(key: "f", modifiers: [.command, .shift]))
    }

    @Test
    func matcherReturnsTheStableCommandID() {
        let binding = KeyboardShortcutBinding.keyPress(key: "r", modifiers: [.control])
        let registrations = [KeyboardShortcutRegistration(commandID: "run", bindings: [binding])]
        #expect(MacKeyboardShortcutMatcher.commandID(for: binding, registrations: registrations) == "run")
    }
}
```

增加功能键、方向键、Delete 和无字符事件测试。映射器只接受设备无关修饰键，忽略 Caps Lock 和数字小键盘标记。

- [ ] **步骤 2：运行测试并确认因映射器缺失而失败**

运行：`./scripts/test-macos.sh --filter MacKeyboardShortcutTests`

预期：FAIL，找不到 mapper、matcher 和 registration。

- [ ] **步骤 3：扩展平台端口**

把原接口改为：

```swift
struct KeyboardShortcutRegistration: Equatable, Sendable {
    let commandID: String
    let bindings: [KeyboardShortcutBinding]
}

@MainActor
protocol ShortcutDetector: AnyObject {
    func start()
    func stop()
    func update(registrations: [KeyboardShortcutRegistration])
    func setSuspended(_ suspended: Bool)
}

@MainActor
protocol ShortcutDetectorFactory {
    func make(onCommand: @escaping @MainActor (String) -> Void) -> any ShortcutDetector
}
```

`KeyboardShortcutRegistration` 放在 Models 的快捷键文件中；Core 端口只引用平台无关类型。

- [ ] **步骤 4：实现事件映射、匹配和统一监听器**

保留 `macReturnKeyHandler`。把 `MacDoubleShiftDetector` 替换为 `MacShortcutDetector`：

```swift
private final class MacShortcutDetector: ShortcutDetector, @unchecked Sendable {
    private static let doubleTapThreshold: TimeInterval = 0.35
    private var registrations: [KeyboardShortcutRegistration] = []
    private var isSuspended = false
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private let onCommand: @MainActor (String) -> Void

    func update(registrations: [KeyboardShortcutRegistration]) {
        self.registrations = registrations
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }
}
```

普通按键匹配成功时返回 `nil`，并在 `Task { @MainActor in ... }` 中分发命令 ID，防止 SwiftUI 菜单再次执行。`flagsChanged` 保留双击 Shift 阈值逻辑，但只在有效注册中存在 `.doubleTap(.shift)` 时触发。`stop()` 必须移除两个 monitor。

- [ ] **步骤 5：运行映射测试与服务边界检查**

运行：

```bash
./scripts/test-macos.sh --filter MacKeyboardShortcutTests
./scripts/verify-service-boundaries.sh
```

预期：两项均 PASS。

- [ ] **步骤 6：提交 macOS 检测器**

```bash
git add macos/Tests/LitheTests/MacKeyboardShortcutTests.swift macos/Sources/Lithe/Core/Ports/PlatformUI.swift macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift macos/Sources/Lithe/Application/Composition/AppServices.swift macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift
git commit -m "feat(macOS): 统一动态快捷键检测"
```

---

### 任务 4：命令路由、菜单和 Search Everywhere 同步

**文件：**

- 修改：`macos/Tests/LitheTests/KeyboardShortcutTests.swift`
- 修改：`macos/Sources/Lithe/Models/AppModel/AppModel.swift`
- 修改：`macos/Sources/Lithe/Models/AppModel/AppModel+FeatureState.swift`
- 修改：`macos/Sources/Lithe/Models/LitheAction.swift`
- 创建：`macos/Sources/Lithe/Views/App/KeyboardShortcut+SwiftUI.swift`
- 修改：`macos/Sources/Lithe/LitheApp.swift`

- [ ] **步骤 1：编写有效主按键与展示投影的失败测试**

```swift
@Test
func featureProjectsCurrentDisplayAndPrimaryKeyPress() throws {
    let settings = AppSettings(store: KeyboardShortcutTestStore())
    let feature = KeyboardShortcutFeatureModel(settings: settings)
    let replacement = KeyboardShortcutBinding.keyPress(key: "p", modifiers: [.command, .option])
    try feature.replaceBindings(for: "find-in-file", with: [replacement])

    #expect(feature.displayText(for: "find-in-file") == "⌥⌘P")
    #expect(feature.primaryKeyPress(for: "find-in-file") == replacement)
    #expect(feature.registrations.first { $0.commandID == "find-in-file" }?.bindings == [replacement])
}
```

- [ ] **步骤 2：运行测试并确认因投影 API 缺失而失败**

运行：`./scripts/test-macos.sh --filter KeyboardShortcutTests`

预期：FAIL，找不到 `displayText`、`primaryKeyPress` 或 `registrations`。

- [ ] **步骤 3：实现功能模型投影与 AppModel 检测器同步**

`KeyboardShortcutFeatureModel` 增加：

```swift
func displayText(for commandID: String) -> String? {
    let values = effectiveBindings(for: commandID).map(\.displayText)
    return values.isEmpty ? nil : values.joined(separator: "  ")
}

func primaryKeyPress(for commandID: String) -> KeyboardShortcutBinding? {
    effectiveBindings(for: commandID).first {
        if case .keyPress = $0 { return true }
        return false
    }
}
```

`AppModel` 初始化功能模型和检测器，设置 registrations，并在覆盖值或录制状态变化时调用 `update` / `setSuspended`。检测器回调统一进入 `performShortcutCommand(id:)`。

- [ ] **步骤 4：集中路由 27 个命令**

在 `AppModel+FeatureState.swift` 实现稳定 `switch`。已有 22 个操作复用 `LitheActionRegistry.actions(for:)` 的闭包，新增 5 个明确路由：

```swift
func performShortcutCommand(id: String) {
    switch id {
    case "save": saveActiveDocument()
    case "search-everywhere": toggleSearchEverywhere()
    case "find-next": navigateFind(offset: 1)
    case "find-previous": navigateFind(offset: -1)
    case "go-to-implementation": goToImplementation()
    default: LitheActionRegistry.actions(for: self).first { $0.id == id }?.perform()
    }
}
```

`LitheActionRegistry` 从目录读取标题、说明和分组，并用 `model.keyboardShortcutFeature.displayText(for:)` 填充 `keyEquivalent`，删除 9 处硬编码展示文本。

- [ ] **步骤 5：让 SwiftUI 菜单读取当前主按键**

`KeyboardShortcut+SwiftUI.swift` 提供可选绑定 modifier：

```swift
extension View {
    @ViewBuilder
    func litheKeyboardShortcut(_ binding: KeyboardShortcutBinding?) -> some View {
        if let shortcut = binding?.swiftUIValue {
            keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}
```

替换 `LitheApp.swift` 中 13 处硬编码 `.keyboardShortcut`。菜单 Button 点击仍直接调用现有方法；键盘事件由 detector 消费并统一路由。

- [ ] **步骤 6：运行定向测试、完整编译和边界检查**

运行：

```bash
./scripts/test-macos.sh --filter KeyboardShortcutTests
./scripts/test-macos.sh
./scripts/verify-service-boundaries.sh
```

预期：全部 PASS，SwiftUI Commands 可编译，现有测试无回归。

- [ ] **步骤 7：提交命令路由与消费者同步**

```bash
git add macos/Tests/LitheTests/KeyboardShortcutTests.swift macos/Sources/Lithe/Models/AppModel/AppModel.swift macos/Sources/Lithe/Models/AppModel/AppModel+FeatureState.swift macos/Sources/Lithe/Models/LitheAction.swift macos/Sources/Lithe/Views/App/KeyboardShortcut+SwiftUI.swift macos/Sources/Lithe/LitheApp.swift
git commit -m "feat(macOS): 同步快捷键命令入口"
```

---

### 任务 5：Keymap 设置页与录制交互

**文件：**

- 修改：`macos/Tests/LitheTests/KeyboardShortcutTests.swift`
- 创建：`macos/Sources/Lithe/Views/App/KeyboardShortcutSettingsView.swift`
- 创建：`macos/Sources/Lithe/Views/App/KeyboardShortcutRecorderView.swift`
- 修改：`macos/Sources/Lithe/Views/App/SettingsView.swift`
- 修改：`macos/Sources/Lithe/Models/AppModel/AppModel.swift`

- [ ] **步骤 1：编写搜索与分组的失败测试**

```swift
@Test
func filteringMatchesTitleIDGroupAndShortcutText() throws {
    let feature = KeyboardShortcutFeatureModel(settings: AppSettings(store: KeyboardShortcutTestStore()))
    #expect(feature.filteredCommands(query: "find usages").map(\.id) == ["find-usages"])
    #expect(feature.filteredCommands(query: "window").allSatisfy { $0.group == .window })
    #expect(feature.filteredCommands(query: "⌃R").map(\.id).contains("run"))
}
```

- [ ] **步骤 2：运行测试并确认搜索行为尚未实现**

运行：`./scripts/test-macos.sh --filter KeyboardShortcutTests`

预期：FAIL，过滤结果不符合标题、ID、分组和快捷键的联合匹配规则。

- [ ] **步骤 3：实现确定性过滤与分组**

过滤前对 query 做去首尾空白和不区分大小写处理；按目录原始顺序返回结果。`groupedCommands(query:)` 只返回非空分组，并按 `LitheActionGroup.allCases` 排序。

- [ ] **步骤 4：实现 AppKit 行内录制控件**

`KeyboardShortcutRecorderView` 在获得焦点时调用 `feature.beginRecording(commandID:)`，监听一个普通 `keyDown` 或双击 Shift：

- Esc：取消并 `endRecording()`；
- 合法候选：调用 `onRecorded(binding)`；
- 非法普通字符：保留录制并显示「Shortcut needs Command, Control, or Option」；
- 退出视图：保证 `endRecording()`，避免 detector 永久挂起。

录制组件不读写 `AppSettings`，不执行命令，只返回值或取消事件。

- [ ] **步骤 5：实现已确认的 Keymap 页面**

`KeyboardShortcutSettingsView` 使用 `@ObservedObject var feature`，包含：

- 标题、说明、搜索框、全局恢复按钮；
- 按分组显示的 27 个命令；
- 绑定标签、添加、替换、删除和单项 Reset；
- 冲突/非法输入行内错误；
- 无搜索结果空状态；
- `Restore All Defaults` 只调用 `feature.resetAll()`。

点击删除最后一个绑定时写入空覆盖列表，显示「Not Assigned」。冲突异常通过 `KeyboardShortcutUpdateError` 转换为本地化消息，不静默丢弃。

- [ ] **步骤 6：接入 Settings 分类**

在 `SettingsCategory` 增加：

```swift
case keymap = "Keymap"
```

图标使用 `keyboard`。`SettingsView.content` 对 `.keymap` 使用填满剩余空间的 `KeyboardShortcutSettingsView(feature: model.keyboardShortcutFeature)`，其他分类保持当前 ScrollView 行为。底部应用级 Restore Defaults 仍调用 `settings.restoreDefaults()`。

- [ ] **步骤 7：运行定向测试与完整 macOS 测试**

运行：

```bash
./scripts/test-macos.sh --filter KeyboardShortcutTests
./scripts/test-macos.sh
```

预期：全部 PASS，设置页可编译且无 Swift 并发告警升级为错误。

- [ ] **步骤 8：提交设置页**

```bash
git add macos/Tests/LitheTests/KeyboardShortcutTests.swift macos/Sources/Lithe/Views/App/KeyboardShortcutSettingsView.swift macos/Sources/Lithe/Views/App/KeyboardShortcutRecorderView.swift macos/Sources/Lithe/Views/App/SettingsView.swift macos/Sources/Lithe/Models/AppModel/AppModel.swift
git commit -m "feat(macOS): 添加快捷键设置界面"
```

---

### 任务 6：本地化与恢复默认回归

**文件：**

- 修改：`macos/Tests/LitheTests/AppLocalizationTests.swift`
- 修改：`macos/Resources/zh-Hans.lproj/Localizable.strings`
- 修改：`macos/Tests/LitheTests/KeyboardShortcutTests.swift`

- [ ] **步骤 1：编写简体中文资源失败测试**

```swift
@Test
func simplifiedChineseResourcesCoverKeymapControls() throws {
    let translations = try simplifiedChineseTranslations()
    #expect(translations["Keymap"] == "快捷键")
    #expect(translations["Search actions or shortcuts"] == "搜索操作或快捷键")
    #expect(translations["Restore All Defaults"] == "全部恢复默认")
    #expect(translations["Not Assigned"] == "未分配")
    #expect(translations["Press shortcut…"] == "请按下快捷键…")
    #expect(translations["Shortcut needs Command, Control, or Option"] == "快捷键需要包含 Command、Control 或 Option")
}
```

- [ ] **步骤 2：运行本地化测试并确认缺失键失败**

运行：`./scripts/test-macos.sh --filter AppLocalizationTests`

预期：FAIL，新增 key 尚未写入 `Localizable.strings`。

- [ ] **步骤 3：补齐所有新增界面文案**

向 `macos/Resources/zh-Hans.lproj/Localizable.strings` 添加测试中的键，以及「Conflicts with %@」「No matching commands」「Add Shortcut」「Remove」「Reset」等界面实际使用键。保持 plist 字符串格式有效和键唯一。

- [ ] **步骤 4：补充应用级恢复默认测试**

在 `KeyboardShortcutTests.swift` 断言：修改主题与快捷键后调用 `settings.restoreDefaults()`，主题和快捷键都回到目录默认；Keymap 页 `feature.resetAll()` 不改变主题。

- [ ] **步骤 5：运行本地化、快捷键和完整测试**

运行：

```bash
./scripts/test-macos.sh --filter AppLocalizationTests
./scripts/test-macos.sh --filter KeyboardShortcutTests
./scripts/test-macos.sh
```

预期：全部 PASS。

- [ ] **步骤 6：提交本地化与回归测试**

```bash
git add macos/Tests/LitheTests/AppLocalizationTests.swift macos/Tests/LitheTests/KeyboardShortcutTests.swift macos/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "test(macOS): 覆盖快捷键设置本地化"
```

---

### 任务 7：完整验证、界面验收与 PR

**文件：**

- 条件修改：验证发现问题时，只修改前述快捷键文件
- 不修改：`windows/`、`shared/contracts/`、版本号、发布说明和用户的 `test.md`、`test2.md`

- [ ] **步骤 1：运行格式与文件范围检查**

运行：

```bash
git diff --check upstream/preview...HEAD
git diff --name-only upstream/preview...HEAD
git status --short
```

预期：无空白错误；变更只包含设计/计划、macOS Swift、测试和简体中文资源；`.superpowers/`、`test.md`、`test2.md` 保持未跟踪且不暂存。

- [ ] **步骤 2：运行仓库要求的完整验证**

运行：

```bash
./scripts/test-macos.sh
./scripts/verify-service-boundaries.sh
```

预期：两项退出码均为 `0`。

- [ ] **步骤 3：启动应用并执行手动验收**

使用仓库现有 macOS 开发启动方式打开应用，逐项确认：

1. Keymap 分类布局与已确认原型一致；
2. 27 个命令可搜索；
3. 把 Run 改成无冲突组合后立即触发；
4. 为 Toggle Terminal 分配组合后立即触发；
5. 与 Find in File 冲突时无法保存；
6. 单项 Reset、Keymap 全部恢复和应用级恢复范围正确；
7. 重启后用户覆盖保留；
8. 双击 Shift、菜单显示、Search Everywhere 提示一致；
9. 编辑器普通输入、Enter 和 Esc 不受影响。

- [ ] **步骤 4：提交验证中发现的必要修正**

使用 `git status --short` 取得验证修正文件清单，逐个执行 `git add`，且只允许暂存本计划「文件结构」中列出的源码、测试或本地化文件。创建新 commit，不 amend 已有提交；若无修正则跳过此步骤。

- [ ] **步骤 5：推送功能分支并创建 PR**

```bash
git push -u origin codex/issue-10-custom-keymap
lithe_pr_url="$(gh pr create --repo 1lck/Lithe-IDEA --base preview --head Sunwenzhi58:codex/issue-10-custom-keymap --title 'feat(macOS): 支持自定义快捷键' --body-file /tmp/lithe-issue-10-pr.md)"
```

PR 正文包含摘要、完整测试计划、Agent 归属、`Closes #10`、风险和回退方式。临时 PR 正文文件只写入 `/tmp`，不进入仓库。

- [ ] **步骤 6：检查 PR 合并门禁**

从 `gh pr create` 返回的 URL 末段提取编号：

```bash
lithe_pr_number="${lithe_pr_url##*/}"
gh pr view "$lithe_pr_number" --repo 1lck/Lithe-IDEA --json state,isDraft,mergeable,mergeStateStatus,reviewDecision,baseRefName,headRefName,files,url
gh pr diff "$lithe_pr_number" --repo 1lck/Lithe-IDEA --name-only
gh pr checks "$lithe_pr_number" --repo 1lck/Lithe-IDEA
```

预期：PR 为 OPEN、非 Draft、目标为 `preview`、diff 范围正确、mergeable 明确且所有必需 checks 通过。任何信号未知、失败或等待中时不合并。

- [ ] **步骤 7：根据 review 修正并重新验证**

每个有效 review 问题先增加失败测试，再实现修正，运行受影响测试与两条完整验证，创建新 commit 后正常 push，不使用 force push。

- [ ] **步骤 8：squash 合并并确认 Issue 状态**

```bash
gh pr merge "$lithe_pr_number" --repo 1lck/Lithe-IDEA --squash --delete-branch --subject "feat(macOS): 支持自定义快捷键 (#$lithe_pr_number)"
gh pr view "$lithe_pr_number" --repo 1lck/Lithe-IDEA --json state,mergedAt,mergeCommit,url
```

仅在 mergeability、CI 和 review 门禁均明确满足时执行。最终确认 `state == MERGED` 且 `mergedAt` 非空；`Closes #10` 应使 Issue 自动关闭。
