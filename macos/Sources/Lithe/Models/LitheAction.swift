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
            action("run", model: model) { model.runSelectedConfiguration() },
            action("debug", model: model) { model.startDebugging() },
            action("stop-run", model: model) { model.stopSelectedRun() },
            action("stop-debug", model: model) { model.stopDebugging() },
            action("debug-resume", model: model) { model.resumeDebugging() },
            action("debug-step-over", model: model) { model.stepOverDebugging() },
            action("debug-step-into", model: model) { model.stepIntoDebugging() },
            action("debug-step-out", model: model) { model.stepOutDebugging() },
            action("view-breakpoints", model: model) { model.showDebugBreakpointManager() },
            action("open-project", model: model) { model.chooseProject() },
            action("close-project", model: model) { model.closeProject() },
            action("settings", model: model) { model.showSettings() },
            action("rebuild-java-index", model: model) { model.rebuildJavaIndex() },
            action("save", model: model) { model.saveActiveDocument() },
            action("search-everywhere", model: model) { model.toggleSearchEverywhere() },
            action("navigate-back", model: model) { model.navigateBack() },
            action("navigate-forward", model: model) { model.navigateForward() },
            action("find-next", model: model) { model.navigateFind(offset: 1) },
            action("find-previous", model: model) { model.navigateFind(offset: -1) },
            action("go-to-implementation", model: model) { model.goToImplementation() },
            action("toggle-terminal", model: model) { model.toggleTerminal() },
            action("toggle-problems", model: model) { model.toggleProblems() },
            action("toggle-maven", model: model) { model.toggleMaven() },
            action("toggle-git-log", model: model) { Task { await model.toggleGitLog() } },
            action("toggle-run", model: model) { model.isRunVisible.toggle() },
            action("toggle-tests", model: model) { model.toggleTests() },
            action("toggle-debug", model: model) { model.toggleDebug() },
            action("search-in-project", model: model) { model.openProjectSearch() },
            action("replace-in-project", model: model) { model.openProjectReplace() },
            action("find-in-file", model: model) { model.showFindBar() },
            action("go-to-definition", model: model) { model.goToDefinition() },
            action("find-usages", model: model) { model.findReferences() },
            action("spring-endpoints", model: model) { model.toggleSpringEndpoints() },
            action("local-history", model: model) {
                if let url = model.activeDocument?.url { model.showLocalHistory(for: url) }
            },
            action("project-local-history", model: model) { model.showProjectLocalHistory() },
            action("reveal-in-finder", model: model) {
                if let url = model.activeDocument?.url { model.revealProjectItemInFinder(url) }
            }
        ]
    }

    private static func action(
        _ id: String,
        model: AppModel,
        perform: @escaping @MainActor @Sendable () -> Void
    ) -> LitheAction {
        guard let definition = LitheCommandCatalog.command(id: id) else {
            preconditionFailure("Missing Lithe command definition for \(id)")
        }
        return LitheAction(
            id: definition.id,
            title: definition.title,
            subtitle: definition.subtitle,
            group: definition.group,
            keyEquivalent: model.keyboardShortcutFeature.displayText(for: id),
            perform: perform
        )
    }
}
