import LitheGitModule
import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var model: AppModel
    let rowHeight: CGFloat
    @State private var expandedDirectoryPaths: Set<String> = []
    @State private var expandedTreeRootPath: String?
    @State private var contextMenuPath: String?

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            if model.isLoadingWorkspace {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading project…")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root = model.rootNode {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            // The recursive tree is one scroll-content child. An eager stack
                            // must measure its full height so AppKit receives a real scroll range.
                            VStack(
                                alignment: .leading,
                                spacing: LitheTheme.Metrics.projectTreeRowSpacing
                            ) {
                                ProjectFileTreeContent(
                                    root: root,
                                    availableWidth: geometry.size.width,
                                    rowHeight: rowHeight,
                                    activeDocumentURL: model.activeDocument?.url,
                                    gitStatus: ProjectGitStatusSnapshot(
                                        repositoryRoot: model.gitRepositoryRoot,
                                        projection: model.gitTreeStatusProjection
                                    ),
                                    actions: ProjectTreeActions(model: model),
                                    expandedDirectoryPathsSnapshot: expandedDirectoryPaths,
                                    expandedDirectoryPaths: $expandedDirectoryPaths,
                                    contextMenuPath: $contextMenuPath
                                )
                                .equatable()
                            }
                            .padding(.vertical, LitheTheme.Metrics.projectTreeContentVerticalInset)
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height,
                                alignment: .topLeading
                            )
                        }
                        .scrollContentBackground(.hidden)
                        .litheScrollViewChrome(usesCompactScrollers: true)
                        .task(
                            id: ProjectTreeTaskID(
                                rootPath: root.url.standardizedFileURL.path,
                                revealRequestID: model.projectTreeRevealRequest?.id
                            )
                        ) {
                            let rootPath = root.url.standardizedFileURL.path
                            let revealRequest = model.projectTreeRevealRequest
                            let shouldRefreshGit = expandedTreeRootPath != rootPath
                            if shouldRefreshGit {
                                expandedTreeRootPath = rootPath
                                expandedDirectoryPaths = [rootPath]
                            }
                            if let request = revealRequest {
                                expandedDirectoryPaths.formUnion(
                                    ProjectTreeLocator.expandedDirectoryPaths(
                                        for: request.fileURL,
                                        rootURL: root.url,
                                        includeItem: request.isDirectory
                                    )
                                )
                                await Task.yield()
                                proxy.scrollTo(
                                    request.fileURL.standardizedFileURL.path,
                                    anchor: .center
                                )
                            }
                            if shouldRefreshGit {
                                await model.refreshGit()
                            }
                            if let request = revealRequest {
                                model.consumeProjectTreeRevealRequest(id: request.id)
                            }
                        }
                    }
                }
            } else if let error = model.workspaceLoadErrorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(LitheTheme.warning)
                    Text("Could not load project")
                        .font(.system(size: 12, weight: .semibold))
                    Text(LocalizedStringKey(error))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 250)
                    Button("Retry") {
                        Task { await model.refreshWorkspace() }
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No project loaded")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $model.projectItemEditRequest) { request in
            ProjectItemNameDialog(request: request) { name in
                Task { await model.performProjectItemEdit(named: name) }
            } onCancel: {
                model.cancelProjectItemEdit()
            }
        }
        .confirmationDialog(
            "Move '\(model.pendingProjectItemDeletion?.url.lastPathComponent ?? "")' to Trash?",
            isPresented: Binding(
                get: { model.pendingProjectItemDeletion != nil },
                set: { if !$0 { model.cancelProjectItemDeletion() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingProjectItemDeletion
        ) { request in
            Button("Move to Trash", role: .destructive) {
                Task { await model.confirmProjectItemDeletion(request) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {
                model.cancelProjectItemDeletion()
            }
            .lithePointer()
        } message: { _ in
            Text("The item can be recovered from the macOS Trash.")
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Text("Project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            if model.isRefreshingWorkspace {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help("Refreshing project")
            } else {
                Button {
                    Task { await model.refreshWorkspace() }
                } label: {
                    LitheSystemIcon(systemImage: "arrow.clockwise")
                }
                .litheIconButton()
                .help("Refresh")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 39)
    }
}

private struct ProjectTreeTaskID: Equatable {
    let rootPath: String
    let revealRequestID: UUID?
}

private struct ProjectGitStatusSnapshot: Equatable {
    let repositoryRoot: URL?
    let projection: GitTreeStatusProjection

    func kind(for url: URL, isDirectory: Bool) -> GitChangeKind? {
        guard let repositoryRoot,
              let relative = Self.relativePath(for: url, root: repositoryRoot) else { return nil }
        return projection.kind(relativePath: relative, isDirectory: isDirectory)
    }

    func change(for url: URL) -> GitChange? {
        guard let repositoryRoot,
              let relative = Self.relativePath(for: url, root: repositoryRoot) else { return nil }
        return projection.change(relativePath: relative)
    }

    private static func relativePath(for url: URL, root: URL) -> String? {
        let normalizedRoot = root.standardizedFileURL.path
        let normalizedPath = url.standardizedFileURL.path
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else { return nil }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }
}

private final class ProjectTreeActions: @unchecked Sendable {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    // Button and context-menu closures are not MainActor-isolated under the
    // Swift 6 test/release check. Keep these methods synchronous and hop.
    nonisolated func openFile(_ url: URL) {
        Task { @MainActor in self.model.openFile(url) }
    }
    nonisolated func requestCreateFile(_ url: URL) {
        Task { @MainActor in self.model.requestCreateFile(in: url) }
    }
    nonisolated func requestCreateDirectory(_ url: URL) {
        Task { @MainActor in self.model.requestCreateDirectory(in: url) }
    }
    nonisolated func revealInFinder(_ url: URL) {
        Task { @MainActor in self.model.revealProjectItemInFinder(url) }
    }
    nonisolated func copyPath(_ url: URL, relative: Bool) {
        Task { @MainActor in self.model.copyProjectItemPath(url, relative: relative) }
    }
    nonisolated func duplicate(_ url: URL) {
        Task { await self.model.duplicateProjectItem(at: url) }
    }
    nonisolated func requestRename(_ url: URL) {
        Task { @MainActor in self.model.requestRenameProjectItem(at: url) }
    }
    nonisolated func requestDelete(_ url: URL, _ isDirectory: Bool) {
        Task { @MainActor in
            self.model.requestDeleteProjectItem(at: url, isDirectory: isDirectory)
        }
    }
    nonisolated func refreshWorkspace() {
        Task { await self.model.refreshWorkspace() }
    }
    nonisolated func showGitDirectoryDiff(_ url: URL) {
        Task { await self.model.showGitDirectoryDiff(for: url) }
    }
    nonisolated func selectChange(_ change: GitChange) {
        Task { @MainActor in self.model.selectChange(change) }
    }
    nonisolated func showLocalHistory(_ url: URL) {
        Task { @MainActor in self.model.showLocalHistory(for: url) }
    }
    nonisolated func showProjectLocalHistory() {
        Task { @MainActor in self.model.showProjectLocalHistory() }
    }
    func javaIconKind(_ url: URL) async -> LitheIconKind? {
        await model.javaIconKind(for: url)
    }
}

private struct ProjectFileTreeContent: View, Equatable {
    let root: FileNode
    let availableWidth: CGFloat
    let rowHeight: CGFloat
    let activeDocumentURL: URL?
    let gitStatus: ProjectGitStatusSnapshot
    let actions: ProjectTreeActions
    let expandedDirectoryPathsSnapshot: Set<String>
    @Binding var expandedDirectoryPaths: Set<String>
    @Binding var contextMenuPath: String?

    static func == (lhs: ProjectFileTreeContent, rhs: ProjectFileTreeContent) -> Bool {
        lhs.root == rhs.root
            && lhs.availableWidth == rhs.availableWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.activeDocumentURL == rhs.activeDocumentURL
            && lhs.gitStatus == rhs.gitStatus
            && lhs.expandedDirectoryPathsSnapshot == rhs.expandedDirectoryPathsSnapshot
            && lhs.contextMenuPath == rhs.contextMenuPath
    }

    var body: some View {
        FileNodeRow(
            node: root,
            depth: 0,
            availableWidth: availableWidth,
            rowHeight: rowHeight,
            activeDocumentURL: activeDocumentURL,
            gitStatus: gitStatus,
            actions: actions,
            expandedDirectoryPaths: $expandedDirectoryPaths,
            contextMenuPath: $contextMenuPath
        )
        .id(root.url.standardizedFileURL.path)
    }
}

private struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    let availableWidth: CGFloat
    let rowHeight: CGFloat
    let activeDocumentURL: URL?
    let gitStatus: ProjectGitStatusSnapshot
    let actions: ProjectTreeActions
    @Binding var expandedDirectoryPaths: Set<String>
    @Binding var contextMenuPath: String?
    @State private var resolvedJavaIconKind: LitheIconKind?

    private var rowWidth: CGFloat {
        max(
            availableWidth - (LitheTheme.Metrics.projectTreeContentHorizontalInset * 2),
            CGFloat(depth * 14 + 8 + 180)
        )
    }

    private var isExpanded: Bool {
        expandedDirectoryPaths.contains(node.url.path)
    }

    var body: some View {
        if node.isDirectory {
            VStack(
                alignment: .leading,
                spacing: LitheTheme.Metrics.projectTreeRowSpacing
            ) {
                directoryRow
                if isExpanded {
                    ForEach(node.children ?? []) { child in
                        FileNodeRow(
                            node: child,
                            depth: depth + 1,
                            availableWidth: availableWidth,
                            rowHeight: rowHeight,
                            activeDocumentURL: activeDocumentURL,
                            gitStatus: gitStatus,
                            actions: actions,
                            expandedDirectoryPaths: $expandedDirectoryPaths,
                            contextMenuPath: $contextMenuPath
                        )
                        .id(child.url.standardizedFileURL.path)
                    }
                }
            }
        } else {
            fileRow
        }
    }

    private var directoryRow: some View {
        Button {
            contextMenuPath = nil
            if isExpanded {
                expandedDirectoryPaths.remove(node.url.path)
                node.collapsedAncestorPaths.forEach { expandedDirectoryPaths.remove($0) }
            } else {
                expandedDirectoryPaths.insert(node.url.path)
                // 被压缩掉的中间包也要标记为展开，否则再次折叠时状态残留。
                node.collapsedAncestorPaths.forEach { expandedDirectoryPaths.insert($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                    .foregroundStyle(LitheTheme.secondaryText)
                LitheIcon(kind: node.iconKind, size: LitheTheme.Metrics.treeIconSize)
                    .frame(width: LitheTheme.Metrics.treeIconSize, height: LitheTheme.Metrics.treeIconSize)
                Text(node.name)
                    .font(.system(size: LitheTheme.Metrics.treeFontSize, weight: depth == 0 ? .semibold : .regular))
                    .foregroundStyle(gitStatusColor ?? LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(width: rowWidth, alignment: .leading)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: contextMenuPath == node.url.standardizedFileURL.path,
                cornerRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius,
                activeBackground: LitheTheme.subtleSelection,
                animation: nil
            )
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .lithePointer()
        .padding(.horizontal, LitheTheme.Metrics.projectTreeContentHorizontalInset)
        .litheContextMenu(
            items: { directoryContextMenuItems },
            onRightClick: { contextMenuPath = node.url.standardizedFileURL.path }
        )
    }

    private var fileRow: some View {
        Button {
            contextMenuPath = nil
            actions.openFile(node.url)
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 10)
                LitheIcon(kind: resolvedJavaIconKind ?? node.iconKind, size: LitheTheme.Metrics.treeIconSize)
                    .frame(width: LitheTheme.Metrics.treeIconSize)
                Text(node.name)
                    .font(.system(size: LitheTheme.Metrics.treeFontSize))
                    .foregroundStyle(gitStatusColor ?? LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let status = gitStatus.change(for: node.url) {
                    Text(status.displayStatus)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(gitStatusColor ?? LitheTheme.secondaryText)
                        .accessibilityLabel(status.kind.title)
                }
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(width: rowWidth, alignment: .leading)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: activeDocumentURL?.standardizedFileURL.path
                    == node.url.standardizedFileURL.path
                    || contextMenuPath == node.url.standardizedFileURL.path,
                cornerRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius,
                activeBackground: LitheTheme.subtleSelection,
                animation: nil
            )
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .lithePointer()
        .padding(.horizontal, LitheTheme.Metrics.projectTreeContentHorizontalInset)
        .litheContextMenu(
            items: { fileContextMenuItems },
            onRightClick: { contextMenuPath = node.url.standardizedFileURL.path }
        )
        .task(id: node.url.standardizedFileURL.path) {
            guard node.url.pathExtension.lowercased() == "java" else { return }
            resolvedJavaIconKind = await actions.javaIconKind(node.url)
        }
    }

    private var directoryContextMenuItems: [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []

        items += [
            .submenu("New", items: [
                .action("New File…", systemImage: "doc") {
                    actions.requestCreateFile(node.url)
                },
                .action("New Directory…", systemImage: "folder") {
                    actions.requestCreateDirectory(node.url)
                }
            ]),
            .separator
        ]

        if gitStatus.kind(for: node.url, isDirectory: true) != nil {
            items += [
                .action("Show Git Diff", systemImage: "arrow.triangle.branch") {
                    actions.showGitDirectoryDiff(node.url)
                },
                .separator
            ]
        }

        if depth == 0 {
            items += [
                .action("Show Project in Finder", systemImage: "folder") {
                    actions.revealInFinder(node.url)
                },
                .action("Show Project Local History…", systemImage: "clock.arrow.circlepath") {
                    actions.showProjectLocalHistory()
                },
                .action("Copy Project Path", systemImage: "doc.on.doc") {
                    actions.copyPath(node.url, relative: false)
                },
                .action("Copy Relative Path") {
                    actions.copyPath(node.url, relative: true)
                }
            ]
        } else {
            items += [
                .action("Show in Finder", systemImage: "folder") {
                    actions.revealInFinder(node.url)
                },
                .action("Copy Path", systemImage: "doc.on.doc") {
                    actions.copyPath(node.url, relative: false)
                },
                .action("Copy Relative Path") {
                    actions.copyPath(node.url, relative: true)
                },
                .separator,
                .action("Duplicate") {
                    actions.duplicate(node.url)
                },
                .action("Rename…") {
                    actions.requestRename(node.url)
                },
                .action("Move to Trash", systemImage: "trash", role: .destructive) {
                    actions.requestDelete(node.url, true)
                }
            ]
        }

        items += [
            .separator,
            .action("Refresh", systemImage: "arrow.clockwise") {
                actions.refreshWorkspace()
            }
        ]
        return items
    }

    private var fileContextMenuItems: [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = [
            .action("Open") {
                actions.openFile(node.url)
            }
        ]

        if let change = gitStatus.change(for: node.url) {
            items += [
                .action("Show Git Diff", systemImage: "arrow.triangle.branch") {
                    actions.selectChange(change)
                }
            ]
        }

        items += [
            .separator,
            .action("Duplicate") {
                actions.duplicate(node.url)
            },
            .action("Rename…") {
                actions.requestRename(node.url)
            },
            .action("Local History…", systemImage: "clock.arrow.circlepath") {
                actions.showLocalHistory(node.url)
            },
            .action("Move to Trash", systemImage: "trash", role: .destructive) {
                actions.requestDelete(node.url, false)
            },
            .separator,
            .action("Show in Finder", systemImage: "folder") {
                actions.revealInFinder(node.url)
            },
            .action("Copy Path", systemImage: "doc.on.doc") {
                actions.copyPath(node.url, relative: false)
            },
            .action("Copy Relative Path") {
                actions.copyPath(node.url, relative: true)
            }
        ]
        return items
    }

    private var gitStatusColor: Color? {
        guard let kind = gitStatus.kind(for: node.url, isDirectory: node.isDirectory) else {
            return nil
        }
        switch kind {
        case .modified: return LitheTheme.accent
        case .added, .copied: return LitheTheme.success
        case .deleted: return LitheTheme.error
        case .moved: return LitheTheme.skill
        case .conflicted: return LitheTheme.warning
        }
    }

}

private struct ProjectItemNameDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: ProjectItemEditRequest
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var nameFieldFocused: Bool

    init(
        request: ProjectItemEditRequest,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: request.kind == .rename ? request.targetURL.lastPathComponent : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(LocalizedStringKey(message))
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            TextField(LocalizedStringKey(placeholder), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .lithePointer()

                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
                    .tint(LitheTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
        .background(LitheTheme.raised)
        .onAppear { nameFieldFocused = true }
    }

    private var title: String {
        switch request.kind {
        case .createFile: "New File"
        case .createDirectory: "New Directory"
        case .rename: "Rename"
        }
    }

    private var message: String {
        switch request.kind {
        case .createFile: "Create a file in '\(request.targetURL.lastPathComponent)'."
        case .createDirectory: "Create a directory in '\(request.targetURL.lastPathComponent)'."
        case .rename: "Rename '\(request.targetURL.lastPathComponent)'."
        }
    }

    private var placeholder: String {
        switch request.kind {
        case .createFile: "File name"
        case .createDirectory: "Directory name"
        case .rename: "New name"
        }
    }

    private var actionTitle: String {
        request.kind == .rename ? "Rename" : "Create"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName)
    }
}
