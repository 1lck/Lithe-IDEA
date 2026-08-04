import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedDirectoryPaths: Set<String> = []
    @State private var expandedTreeRootPath: String?

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

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
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            FileNodeRow(
                                node: root,
                                depth: 0,
                                availableWidth: geometry.size.width,
                                expandedDirectoryPaths: $expandedDirectoryPaths
                            )
                        }
                        .padding(.vertical, 5)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .topLeading
                        )
                    }
                    .task(id: root.url.path) {
                        guard expandedTreeRootPath != root.url.path else { return }
                        expandedTreeRootPath = root.url.path
                        expandedDirectoryPaths = [root.url.path]
                    }
                    .contextMenu {
                        Button("New File…") {
                            model.requestCreateFile(in: root.url)
                        }
                        Button("New Directory…") {
                            model.requestCreateDirectory(in: root.url)
                        }
                        Divider()
                        Button("Show Project in Finder") {
                            model.revealProjectItemInFinder(root.url)
                        }
                        Button("Show Project Local History…") {
                            model.showProjectLocalHistory()
                        }
                        Button("Copy Project Path") {
                            model.copyProjectItemPath(root.url, relative: false)
                        }
                        Divider()
                        Button("Refresh") {
                            Task { await model.refreshWorkspace() }
                        }
                    }
                }
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
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.confirmProjectItemDeletion() }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {
                model.cancelProjectItemDeletion()
            }
            .lithePointer()
        } message: {
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

private struct FileNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: FileNode
    let depth: Int
    let availableWidth: CGFloat
    @Binding var expandedDirectoryPaths: Set<String>
    @State private var resolvedJavaIconKind: LitheIconKind?

    private var rowWidth: CGFloat {
        max(availableWidth, CGFloat(depth * 14 + 8 + 180))
    }

    private var isExpanded: Bool {
        expandedDirectoryPaths.contains(node.url.path)
    }

    var body: some View {
        if node.isDirectory {
            directoryRow
            if isExpanded {
                ForEach(node.children ?? []) { child in
                    FileNodeRow(
                        node: child,
                        depth: depth + 1,
                        availableWidth: availableWidth,
                        expandedDirectoryPaths: $expandedDirectoryPaths
                    )
                }
            }
        } else {
            fileRow
        }
    }

    private var directoryRow: some View {
        Button {
            if isExpanded {
                expandedDirectoryPaths.remove(node.url.path)
            } else {
                expandedDirectoryPaths.insert(node.url.path)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                    .foregroundStyle(LitheTheme.secondaryText)
                LitheIcon(kind: node.iconKind, size: 14)
                    .frame(width: 14, height: 14)
                Text(node.name)
                    .font(.system(size: 12.5, weight: depth == 0 ? .semibold : .regular))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(width: rowWidth, alignment: .leading)
            .frame(height: 25)
            .contentShape(Rectangle())
            .litheRowHover(cornerRadius: 4)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .contextMenu { directoryContextMenu }
    }

    private var fileRow: some View {
        Button {
            model.openFile(node.url)
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 10)
                LitheIcon(kind: resolvedJavaIconKind ?? node.iconKind, size: 14)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(width: rowWidth, alignment: .leading)
            .frame(height: 25)
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: model.activeDocument?.url == node.url,
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .contextMenu { fileContextMenu }
        .task(id: node.url.standardizedFileURL.path) {
            guard node.url.pathExtension.lowercased() == "java" else { return }
            let url = node.url
            resolvedJavaIconKind = await Task.detached(priority: .utility) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                let data = handle.readData(ofLength: 4 * 1024)
                guard let prefix = String(data: data, encoding: .utf8) else { return nil }
                return LitheIcons.javaSymbolKind(fromSourcePrefix: prefix)
            }.value
        }
    }

    @ViewBuilder
    private var directoryContextMenu: some View {
        Button("New File…") {
            model.requestCreateFile(in: node.url)
        }
        Button("New Directory…") {
            model.requestCreateDirectory(in: node.url)
        }

        Divider()

        Button("Show in Finder") {
            model.revealProjectItemInFinder(node.url)
        }
        Button("Copy Path") {
            model.copyProjectItemPath(node.url, relative: false)
        }
        Button("Copy Relative Path") {
            model.copyProjectItemPath(node.url, relative: true)
        }

        if depth > 0 {
            Divider()

            Button("Duplicate") {
                Task { await model.duplicateProjectItem(at: node.url) }
            }
            Button("Rename…") {
                model.requestRenameProjectItem(at: node.url)
            }
            Button("Move to Trash", role: .destructive) {
                model.requestDeleteProjectItem(at: node.url, isDirectory: true)
            }
        }

        Divider()

        Button("Refresh") {
            Task { await model.refreshWorkspace() }
        }
    }

    @ViewBuilder
    private var fileContextMenu: some View {
        Button("Open") {
            model.openFile(node.url)
        }

        Divider()

        Button("Duplicate") {
            Task { await model.duplicateProjectItem(at: node.url) }
        }
        Button("Rename…") {
            model.requestRenameProjectItem(at: node.url)
        }
        Button("Local History…") {
            model.showLocalHistory(for: node.url)
        }
        Button("Move to Trash", role: .destructive) {
            model.requestDeleteProjectItem(at: node.url, isDirectory: false)
        }

        Divider()

        Button("Show in Finder") {
            model.revealProjectItemInFinder(node.url)
        }
        Button("Copy Path") {
            model.copyProjectItemPath(node.url, relative: false)
        }
        Button("Copy Relative Path") {
            model.copyProjectItemPath(node.url, relative: true)
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
