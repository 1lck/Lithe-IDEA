import Foundation

struct LitheCommandDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let group: LitheActionGroup
    let defaultBindings: [KeyboardShortcutBinding]
}

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
