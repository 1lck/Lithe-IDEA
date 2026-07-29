import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var model: AppModel

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
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FileNodeRow(node: root, depth: 0, initiallyExpanded: true)
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No project loaded")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                if let url = model.workspaceURL {
                    model.openProject(url)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

private struct FileNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: FileNode
    let depth: Int
    @State private var isExpanded: Bool

    init(node: FileNode, depth: Int, initiallyExpanded: Bool = false) {
        self.node = node
        self.depth = depth
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        if node.isDirectory {
            directoryRow
            if isExpanded {
                ForEach(node.children ?? []) { child in
                    FileNodeRow(node: child, depth: depth + 1)
                }
            }
        } else {
            fileRow
        }
    }

    private var directoryRow: some View {
        Button {
            isExpanded.toggle()
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
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(height: 25)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(depth * 14 + 8))
            .padding(.trailing, 8)
            .frame(height: 25)
            .background(model.activeDocument?.url == node.url ? LitheTheme.subtleSelection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { model.openFile(node.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
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
