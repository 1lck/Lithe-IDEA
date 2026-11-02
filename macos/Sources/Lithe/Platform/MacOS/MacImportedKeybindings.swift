import Foundation

/// Whitelisted command mappings; conditional, chord and extension semantics are never made global.
enum MacImportedKeybindings {
    static let vscode: [String: String] = [
        "workbench.action.files.save": "save", "workbench.action.openSettings": "settings",
        "workbench.action.navigateBack": "navigate-back", "workbench.action.navigateForward": "navigate-forward",
        "workbench.action.findInFiles": "search-in-project", "workbench.action.replaceInFiles": "replace-in-project",
        "workbench.action.gotoLine": "go-to-line", "workbench.action.terminal.toggleTerminal": "toggle-terminal",
        "workbench.action.debug.start": "debug", "workbench.action.debug.run": "run",
        "workbench.action.debug.continue": "debug-resume", "workbench.action.debug.stepOver": "debug-step-over",
        "workbench.action.debug.stepInto": "debug-step-into", "workbench.action.debug.stepOut": "debug-step-out",
    ]
    static let idea: [String: String] = [
        "ShowSettings": "settings", "Back": "navigate-back", "Forward": "navigate-forward",
        "FindInPath": "search-in-project", "ReplaceInPath": "replace-in-project", "GotoLine": "go-to-line",
        "ActivateTerminalToolWindow": "toggle-terminal", "Run": "run", "Debug": "debug",
        "Resume": "debug-resume", "StepOver": "debug-step-over", "StepInto": "debug-step-into", "StepOut": "debug-step-out",
    ]
    // Matching keyboard actions resolved from JetBrains Community keymaps ($default and macOS),
    // Apache-2.0, revision e12d185a335d02f3831c12f2af64130b3ace46db.
    // Parent control/meta modifiers are swapped by upstream MacOSDefaultKeymap.
    // Mouse bindings and actions without a Lithe equivalent are intentionally not imported.
    static func ideaDefaults(_ name: String) -> [String: [KeyboardShortcutBinding]]? {
        guard let entries = ideaReferenceKeys[name] else { return nil }
        return entries.mapValues { $0.compactMap { binding($0, idea: true) } }
    }
    private static let ideaReferenceKeys: [String: [String: [String]]] = [
        "$default": [
            "debug": ["shift F9"],
            "debug-resume": ["F9"],
            "debug-step-into": ["F7"],
            "debug-step-out": ["shift F8"],
            "debug-step-over": ["F8"],
            "go-to-line": ["control G"],
            "navigate-back": ["control alt LEFT"],
            "navigate-forward": ["control alt RIGHT"],
            "replace-in-project": ["control shift R"],
            "run": ["shift F10"],
            "search-in-project": ["control shift F"],
            "settings": ["control alt S"],
            "toggle-terminal": ["alt F12"],
        ],
        "Mac OS X": [
            "debug": ["shift F9"],
            "debug-resume": ["F9"],
            "debug-step-into": ["F7"],
            "debug-step-out": ["shift F8"],
            "debug-step-over": ["F8"],
            "go-to-line": ["meta G"],
            "navigate-back": ["meta alt LEFT"],
            "navigate-forward": ["meta alt RIGHT"],
            "replace-in-project": ["control shift R"],
            "run": ["shift F10"],
            "search-in-project": ["control shift F"],
            "settings": ["meta COMMA"],
            "toggle-terminal": ["alt F12"],
        ],
        "Mac OS X 10.5+": [
            "debug": ["control D"],
            "debug-resume": ["meta alt R", "F9"],
            "debug-step-into": ["F7"],
            "debug-step-out": ["shift F8"],
            "debug-step-over": ["F8"],
            "go-to-line": ["meta L"],
            "navigate-back": ["meta OPEN_BRACKET", "meta alt LEFT"],
            "navigate-forward": ["meta CLOSE_BRACKET", "meta alt RIGHT"],
            "replace-in-project": ["meta shift R"],
            "run": ["control R"],
            "search-in-project": ["meta shift F"],
            "settings": ["meta COMMA"],
            "toggle-terminal": ["alt F12"],
        ],
    ]
    static let skipped = "Reference shortcuts are merged with supported user overrides. Conditional rules, chords and removals suppress the affected mappings; extension keymaps are skipped."

    static func binding(_ value: String, idea: Bool) -> KeyboardShortcutBinding? {
        let parts = idea ? value.lowercased().split(separator: " ").map(String.init)
            : value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty, last != "delete" else { return nil }
        var modifiers: KeyboardShortcutModifiers = []
        for part in parts.dropLast() {
            let flag: KeyboardShortcutModifiers
            switch part {
            case "ctrl", "control": flag = .control
            case "alt", "option": flag = .option
            case "shift": flag = .shift
            case "cmd", "meta", "command": flag = .command
            default: return nil
            }
            guard !modifiers.contains(flag) else { return nil }
            modifiers.insert(flag)
        }
        let key = ["enter": "return", "backspace": "delete", "back_space": "delete", "comma": ",", "period": ".",
                   "slash": "/", "back_slash": "\\", "open_bracket": "[", "close_bracket": "]",
                   "minus": "-", "equals": "=" ][last] ?? last
        let result = KeyboardShortcutBinding.keyPress(key: key, modifiers: modifiers)
        return result.isAssignable ? result : nil
    }

    static func parseVSCode(_ data: Data, includeDefaults: Bool = false) throws -> [String: [KeyboardShortcutBinding]] {
        guard data.count <= 1_048_576,
              let rows = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [[String: Any]],
              rows.count <= 4096 else { throw EditorSettingsImportError.invalid }
        // VS Code macOS reference: https://code.visualstudio.com/docs/reference/default-keybindings
        // Only context-independent commands with existing Lithe equivalents are included.
        let reference = ["save": "cmd+s", "settings": "cmd+,", "navigate-back": "ctrl+-",
            "navigate-forward": "ctrl+shift+-", "search-in-project": "cmd+shift+f",
            "replace-in-project": "cmd+shift+h", "go-to-line": "ctrl+g", "toggle-terminal": "ctrl+`"]
        var result: [String: [KeyboardShortcutBinding]] = includeDefaults
            ? reference.mapValues { [binding($0, idea: false)!] } : [:]
        var seen: Set<String> = [], rejected: Set<String> = []
        for row in rows {
            // Later rules own their first key even when a chord/command/context cannot be migrated.
            // Apply this to both reference defaults and earlier user mappings.
            if let key = row["key"] as? String,
               let firstKey = key.split(whereSeparator: \.isWhitespace).first,
               let value = binding(String(firstKey), idea: false) {
                result = result.filter { !$0.value.contains(value) }
            }
            guard let name = row["command"] as? String else { continue }
            let removal = name.hasPrefix("-")
            guard let command = vscode[removal ? String(name.dropFirst()) : name] else { continue }
            guard seen.insert(command).inserted, !removal, row["when"] == nil, row["args"] == nil,
                  let key = row["key"] as? String, let binding = binding(key, idea: false) else {
                rejected.insert(command); continue
            }
            result[command] = [binding]
        }
        for command in rejected { result.removeValue(forKey: command) }
        return result
    }
}
