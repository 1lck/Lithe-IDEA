import Foundation

struct LitheCommandDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let group: LitheActionGroup
    let defaultBindings: [KeyboardShortcutBinding]
}

enum KeyboardShortcutPreset: String, CaseIterable, Sendable {
    case macOS = "macOS"
    case ideaClassic = "idea-classic"
    case eclipse = "eclipse"

    var title: String {
        switch self {
        case .macOS: "macOS"
        case .ideaClassic: "IntelliJ IDEA Classic"
        case .eclipse: "Eclipse"
        }
    }

    func bindings(for command: LitheCommandDefinition) -> [KeyboardShortcutBinding] {
        switch self {
        case .macOS: command.defaultBindings
        case .ideaClassic: Self.ideaClassicBindings[command.id] ?? command.defaultBindings
        case .eclipse: Self.eclipseBindings[command.id]
            ?? Self.eclipseParentBindings[command.id]
            ?? command.defaultBindings
        }
    }

    private static func shortcut(_ key: String, _ modifiers: KeyboardShortcutModifiers = []) -> [KeyboardShortcutBinding] {
        [.keyPress(key: key, modifiers: modifiers)]
    }

    // Adapt the matching Lithe actions from IntelliJ Community's $default keymap.
    private static let ideaClassicBindings: [String: [KeyboardShortcutBinding]] = [
        "settings": shortcut("s", [.control, .option]),
        "save": shortcut("s", [.control]),
        "run": shortcut("f10", [.shift]),
        "debug": shortcut("f9", [.shift]),
        // ponytail: JetBrains has one context-aware Stop action. Lithe binds Stop Run only
        // until a shared Stop command can choose the active run or debug session.
        "stop-run": shortcut("f2", [.control]),
        "toggle-breakpoint": shortcut("f8", [.control]),
        "view-breakpoints": shortcut("f8", [.control, .shift]),
        "search-everywhere": [.doubleTap(.shift)],
        "navigate-back": shortcut("left", [.control, .option]),
        "navigate-forward": shortcut("right", [.control, .option]),
        "find-in-file": shortcut("f", [.control]),
        "find-next": shortcut("f3"),
        "find-previous": shortcut("f3", [.shift]),
        "replace-in-file": shortcut("r", [.control]),
        "go-to-line": shortcut("g", [.control]),
        "go-to-definition": shortcut("b", [.control]),
        "go-to-implementation": shortcut("b", [.control, .option]),
        "find-usages": shortcut("f7", [.option]),
        "search-in-project": shortcut("f", [.control, .shift]),
        "replace-in-project": shortcut("r", [.control, .shift]),
        "toggle-terminal": shortcut("f12", [.option]),
        "toggle-run": shortcut("4", [.option]),
        "toggle-debug": shortcut("5", [.option])
    ]

    // Resolved matching actions from Mac OS X 10.5+, including its $default parent.
    // Only Lithe-only commands fall back to Lithe defaults.
    private static let eclipseParentBindings: [String: [KeyboardShortcutBinding]] = [
        "settings": shortcut(",", [.command]),
        "save": shortcut("s", [.control]),
        "run": shortcut("r", [.control]),
        "debug": shortcut("d", [.control]),
        "stop-run": shortcut("f2", [.control]),
        "debug-resume": shortcut("f9"),
        "debug-step-over": shortcut("f8"),
        "debug-step-into": shortcut("f7"),
        "debug-step-out": shortcut("f8", [.shift]),
        "toggle-breakpoint": shortcut("f8", [.control]),
        "view-breakpoints": shortcut("f8", [.control, .shift]),
        "search-everywhere": [.doubleTap(.shift)],
        "navigate-back": shortcut("[", [.command]),
        "navigate-forward": shortcut("]", [.command]),
        "find-in-file": shortcut("f", [.command]),
        "find-next": [
            .keyPress(key: "f3", modifiers: []),
            .keyPress(key: "l", modifiers: [.control])
        ],
        "find-previous": [
            .keyPress(key: "f3", modifiers: [.shift]),
            .keyPress(key: "l", modifiers: [.control, .shift])
        ],
        "replace-in-file": shortcut("r", [.control]),
        "go-to-line": shortcut("l", [.command]),
        "go-to-definition": shortcut("b", [.command]),
        "go-to-implementation": shortcut("b", [.control, .option]),
        "find-usages": shortcut("f7", [.option]),
        "search-in-project": shortcut("f", [.command, .shift]),
        "replace-in-project": shortcut("r", [.command, .shift]),
        "toggle-terminal": shortcut("f12", [.option]),
        "toggle-problems": shortcut("6", [.command]),
        "toggle-run": shortcut("4", [.command]),
        "toggle-debug": shortcut("5", [.command])
    ]

    // Eclipse (Mac OS X).xml overrides its parent; an empty action clears the inherited binding.
    private static let eclipseBindings: [String: [KeyboardShortcutBinding]] = [
        "run": shortcut("f11", [.command, .shift]),
        "debug": shortcut("f11", [.command]),
        "debug-resume": shortcut("f8"),
        "debug-step-over": shortcut("f6"),
        "debug-step-into": shortcut("f5"),
        "debug-step-out": shortcut("f7"),
        "toggle-breakpoint": shortcut("b", [.command, .shift]),
        "find-in-file": [],
        "find-next": shortcut("k", [.command]),
        "find-previous": shortcut("k", [.command, .shift]),
        "replace-in-file": [],
        "find-usages": shortcut("g", [.command, .shift]),
        "go-to-definition": shortcut("f3"),
        "go-to-implementation": [],
        "search-in-project": shortcut("h", [.control]),
        "replace-in-project": []
    ]
}

// Note: macOS 快捷键的集中目录、覆盖与冲突规则见 .agents/notes/implemented/feature/2026-08-15-macos-keymap-customization.md
enum LitheCommandCatalog {
    static let commands: [LitheCommandDefinition] = validated([
        command("open-project", "Open Project", "Open a local project folder", .project, "o", [.command]),
        command("save", "Save", "Save the active document", .project, "s", [.command]),
        command("close-project", "Close Project", "Return to the Welcome screen", .project, "w", [.shift, .command]),
        command("settings", "Settings", "Configure editor and project behavior", .project, ",", [.command]),
        command("rebuild-java-index", "Java: Rebuild Index", "Clear the current project's Java index and rebuild it on next use", .project),
        command("reveal-in-finder", "Reveal in Finder", "Show the active file in Finder", .project),

        command("run", "Run", "Run selected configuration", .run, "r", [.control]),
        command("debug", "Debug", "Start debugging", .run, "d", [.control]),
        command("stop-run", "Stop Run", "Stop the current run", .run),
        command("stop-debug", "Stop Debug", "Stop the current debug session", .run),
        command("debug-resume", "Debug: Resume", "Resume the paused debug session", .run, "f9"),
        command("debug-step-over", "Debug: Step Over", "Execute the next source line", .run, "f8"),
        command("debug-step-into", "Debug: Step Into", "Enter the next function call", .run, "f7"),
        command("debug-step-out", "Debug: Step Out", "Return from the current function", .run, "f8", [.shift]),
        command("toggle-breakpoint", "Toggle Line Breakpoint", "Add or remove a breakpoint at the caret", .run, "f8", [.command]),
        command("view-breakpoints", "View Breakpoints", "Manage all project breakpoints", .run, "f8", [.shift, .command]),

        LitheCommandDefinition(
            id: "search-everywhere",
            title: "Search Everywhere",
            subtitle: "Find files and actions",
            group: .navigation,
            defaultBindings: [
                .doubleTap(.shift),
                .keyPress(key: "o", modifiers: [.shift, .command])
            ]
        ),
        command("navigate-back", "Back", "Navigate to the previous editor location", .navigation, "[", [.command]),
        command("navigate-forward", "Forward", "Navigate to the next editor location", .navigation, "]", [.command]),
        command("find-in-file", "Find in File", "Search within the active editor", .navigation, "f", [.command]),
        command("find-next", "Find Next", "Move to the next match in the active editor", .navigation, "g", [.command]),
        command("find-previous", "Find Previous", "Move to the previous match in the active editor", .navigation, "g", [.shift, .command]),
        command("replace-in-file", "Replace in File", "Replace within the active editor", .navigation, "r", [.command]),
        command("go-to-line", "Go to Line", "Jump to a line and column in the active editor", .navigation, "l", [.command]),
        command("go-to-definition", "Go to Definition", "Navigate to the declaration of the selected symbol", .navigation, "b", [.command]),
        command("go-to-implementation", "Go to Implementation", "Navigate to an implementation of the selected symbol", .navigation, "b", [.option, .command]),
        command("find-usages", "Find Usages", "Find references to the selected symbol", .navigation, "u", [.option, .command]),
        command("search-in-project", "Find in Files", "Search text across the workspace", .navigation, "f", [.shift, .command]),
        command("replace-in-project", "Replace in Files", "Replace text across the workspace", .navigation, "r", [.shift, .command]),
        command("spring-endpoints", "Spring Endpoints", "Show indexed Spring MVC routes", .navigation),

        command("toggle-terminal", "Toggle Terminal", "Show or hide the Terminal tool window", .window),
        command("toggle-problems", "Toggle Problems", "Show or hide language diagnostics", .window),
        command("toggle-maven", "Toggle Maven", "Show or hide the Maven tool window", .window),
        command("toggle-git-log", "Toggle Git Log", "Show or hide Git history", .window),
        command("toggle-run", "Toggle Run", "Show or hide run output", .window),
        command("toggle-tests", "Toggle Tests", "Show or hide language-neutral test runners", .window),
        command("toggle-debug", "Toggle Debug", "Show or hide the Debug tool window", .window),

        command("local-history", "Local History", "Open history for the active file", .history),
        command("project-local-history", "Project Local History", "Open project-wide local history", .history)
    ])

    static func command(id: String) -> LitheCommandDefinition? {
        commands.first { $0.id == id }
    }

    private static func command(
        _ id: String,
        _ title: String,
        _ subtitle: String,
        _ group: LitheActionGroup,
        _ key: String? = nil,
        _ modifiers: KeyboardShortcutModifiers = []
    ) -> LitheCommandDefinition {
        LitheCommandDefinition(
            id: id,
            title: title,
            subtitle: subtitle,
            group: group,
            defaultBindings: key.map { [.keyPress(key: $0, modifiers: modifiers)] } ?? []
        )
    }

    private static func validated(_ commands: [LitheCommandDefinition]) -> [LitheCommandDefinition] {
        precondition(Set(commands.map(\.id)).count == commands.count, "Duplicate Lithe command ID")

        var owners: [KeyboardShortcutBinding: String] = [:]
        for command in commands {
            precondition(
                Set(command.defaultBindings).count == command.defaultBindings.count,
                "Duplicate shortcut within command \(command.id)"
            )
            for binding in command.defaultBindings {
                precondition(binding.isAssignable, "Invalid shortcut for command \(command.id)")
                precondition(owners[binding] == nil, "Shortcut conflict between \(owners[binding] ?? "") and \(command.id)")
                owners[binding] = command.id
            }
        }
        return commands
    }
}
