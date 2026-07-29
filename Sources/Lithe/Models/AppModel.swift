import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published var selectedSidebar: SidebarDestination = .project
    @Published var isRunPlaceholderPresented = false

    var projectName: String {
        workspaceURL?.lastPathComponent ?? "Lithe"
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open a project"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func openProject(_ url: URL) {
        workspaceURL = url.standardizedFileURL
        selectedSidebar = .project
    }

    func closeProject() {
        workspaceURL = nil
        selectedSidebar = .project
    }
}

enum SidebarDestination: String, CaseIterable, Identifiable {
    case project
    case changes
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .changes: "Changes"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .project: "folder"
        case .changes: "arrow.triangle.branch"
        case .search: "magnifyingglass"
        }
    }
}
