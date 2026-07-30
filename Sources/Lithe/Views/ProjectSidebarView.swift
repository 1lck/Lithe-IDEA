import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedDirectoryPaths: Set<String> = []

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
            Button("Cancel", role: .cancel) {
                model.cancelProjectItemDeletion()
            }
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
            Button {
                Task { await model.refreshWorkspace() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .frame(height: 39)
    }
}

private struct FileNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: FileNode
    let depth: Int
    @Binding var expandedDirectoryPaths: Set<String>

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
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.42, green: 0.61, blue: 0.82))
                Text(node.name)
                    .font(.system(size: 12.5, weight: depth == 0 ? .semibold : .regular))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(height: 25)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { directoryContextMenu }
    }

    private var fileRow: some View {
        Button {
            model.openFile(node.url)
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 10)
                Image(systemName: node.systemImage)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .foregroundStyle(fileColor)
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(height: 25)
            .background(model.activeDocument?.url == node.url ? LitheTheme.subtleSelection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { fileContextMenu }
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

    private var fileColor: Color {
        switch node.url.pathExtension.lowercased() {
        case "swift": .orange
        case "java", "kt", "kts": Color(red: 0.42, green: 0.66, blue: 0.95)
        case "js", "jsx", "ts", "tsx": .yellow
        case "json", "yaml", "yml", "xml", "toml": Color(red: 0.72, green: 0.50, blue: 0.88)
        case "md": Color(red: 0.45, green: 0.76, blue: 0.90)
        default: LitheTheme.secondaryText
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
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            TextField(placeholder, text: $name)
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

                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
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
