import Foundation

enum LitheActionGroup: String, CaseIterable, Sendable {
    case run = "Run"
    case navigation = "Navigation"
    case window = "Window"
    case project = "Project"
    case history = "History"
}

struct LitheAction: Identifiable, @unchecked Sendable {
    let id: String
    let title: String
    let subtitle: String
    let group: LitheActionGroup
    let keyEquivalent: String?
    let perform: @MainActor @Sendable () -> Void

    init(
        id: String,
        title: String,
        subtitle: String,
        group: LitheActionGroup,
        keyEquivalent: String? = nil,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.keyEquivalent = keyEquivalent
        self.perform = perform
    }

    var searchText: String { "\(title) \(subtitle) \(group.rawValue)" }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = query
            .lowercased()
            .filter { !$0.isWhitespace }
        guard !normalizedQuery.isEmpty else { return true }
        let candidates = searchText.lowercased()
        var queryIndex = normalizedQuery.startIndex
        for character in candidates {
            guard queryIndex < normalizedQuery.endIndex else { break }
            if character == normalizedQuery[queryIndex] {
                queryIndex = normalizedQuery.index(after: queryIndex)
            }
        }
        return queryIndex == normalizedQuery.endIndex
    }
}

@MainActor
enum LitheActionRegistry {
    static func actions(for model: AppModel) -> [LitheAction] {
        [
            LitheAction(
                id: "run",
                title: "Run",
                subtitle: "Run selected configuration",
                group: .run,
                keyEquivalent: "⌃R"
            ) { model.runSelectedConfiguration() },
            LitheAction(
                id: "debug",
                title: "Debug",
                subtitle: "Start debugging",
                group: .run,
                keyEquivalent: "⌃D"
            ) { model.startDebugging() },
            LitheAction(
                id: "stop-run",
                title: "Stop Run",
                subtitle: "Stop the current run",
                group: .run
            ) { model.stopSelectedRun() },
            LitheAction(
                id: "stop-debug",
                title: "Stop Debug",
                subtitle: "Stop the current debug session",
                group: .run
            ) { model.stopDebugging() },
            LitheAction(
                id: "open-project",
                title: "Open Project",
                subtitle: "Open a local project folder",
                group: .project,
                keyEquivalent: "⌘O"
            ) { model.chooseProject() },
            LitheAction(
                id: "close-project",
                title: "Close Project",
                subtitle: "Return to the Welcome screen",
                group: .project
            ) { model.closeProject() },
            LitheAction(
                id: "settings",
                title: "Settings",
                subtitle: "Configure editor and project behavior",
                group: .project,
                keyEquivalent: "⌘,"
            ) { model.showSettings() },
            LitheAction(
                id: "toggle-terminal",
                title: "Toggle Terminal",
                subtitle: "Show or hide the Terminal tool window",
                group: .window
            ) { model.toggleTerminal() },
            LitheAction(
                id: "toggle-problems",
                title: "Toggle Problems",
                subtitle: "Show or hide language diagnostics",
                group: .window
            ) { model.toggleProblems() },
            LitheAction(
                id: "toggle-maven",
                title: "Toggle Maven",
                subtitle: "Show or hide the Maven tool window",
                group: .window
            ) { model.toggleMaven() },
            LitheAction(
                id: "toggle-git-log",
                title: "Toggle Git Log",
                subtitle: "Show or hide Git history",
                group: .window
            ) { Task { await model.toggleGitLog() } },
            LitheAction(
                id: "toggle-run",
                title: "Toggle Run",
                subtitle: "Show or hide run output",
                group: .window
            ) { model.isRunVisible.toggle() },
            LitheAction(
                id: "toggle-tests",
                title: "Toggle Tests",
                subtitle: "Show or hide language-neutral test runners",
                group: .window
            ) { model.toggleTests() },
            LitheAction(
                id: "toggle-debug",
                title: "Toggle Debug",
                subtitle: "Show or hide the Debug tool window",
                group: .window
            ) { model.toggleDebug() },
            LitheAction(
                id: "search-in-project",
                title: "Find in Files",
                subtitle: "Search text across the workspace",
                group: .navigation,
                keyEquivalent: "⇧⌘F"
            ) { model.openProjectSearch() },
            LitheAction(
                id: "replace-in-project",
                title: "Replace in Files",
                subtitle: "Replace text across the workspace",
                group: .navigation,
                keyEquivalent: "⇧⌘R"
            ) { model.openProjectReplace() },
            LitheAction(
                id: "find-in-file",
                title: "Find in File",
                subtitle: "Search within the active editor",
                group: .navigation,
                keyEquivalent: "⌘F"
            ) { model.showFindBar() },
            LitheAction(
                id: "go-to-usage",
                title: "Go to Usage",
                subtitle: "Navigate to a call site of the selected symbol",
                group: .navigation,
                keyEquivalent: "⌘B"
            ) { model.goToUsages() },
            LitheAction(
                id: "find-usages",
                title: "Find Usages",
                subtitle: "Find references to the selected symbol",
                group: .navigation,
                keyEquivalent: "⌥⌘U"
            ) { model.findReferences() },
            LitheAction(
                id: "local-history",
                title: "Local History",
                subtitle: "Open history for the active file",
                group: .history
            ) {
                if let url = model.activeDocument?.url { model.showLocalHistory(for: url) }
            },
            LitheAction(
                id: "project-local-history",
                title: "Project Local History",
                subtitle: "Open project-wide local history",
                group: .history
            ) { model.showProjectLocalHistory() },
            LitheAction(
                id: "reveal-in-finder",
                title: "Reveal in Finder",
                subtitle: "Show the active file in Finder",
                group: .project
            ) {
                if let url = model.activeDocument?.url { model.revealProjectItemInFinder(url) }
            }
        ]
    }
}
