import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.openDocuments.isEmpty {
                emptyState
            } else {
                editorTabs
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                breadcrumbs
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                activeEditor
            }
        }
        .background(LitheTheme.editor)
    }

    private var editorTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.openDocuments) { document in
                    Button {
                        model.activeDocumentID = document.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: icon(for: document.url))
                                .font(.system(size: 11))
                                .foregroundStyle(iconColor(for: document.url))
                            Text(document.url.lastPathComponent)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            if document.isDirty {
                                Circle()
                                    .fill(LitheTheme.primaryText)
                                    .frame(width: 6, height: 6)
                            }
                            Button {
                                model.requestCloseDocument(document)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .foregroundStyle(model.activeDocumentID == document.id ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 11)
                        .frame(height: 38)
                        .background(model.activeDocumentID == document.id ? LitheTheme.editor : LitheTheme.sidebar)
                        .overlay(alignment: .bottom) {
                            if model.activeDocumentID == document.id {
                                Rectangle().fill(LitheTheme.accent).frame(height: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1, height: 38)
                }
            }
        }
        .frame(height: 38)
        .background(LitheTheme.sidebar)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            if let document = model.activeDocument {
                let components = model.relativePath(for: document.url).split(separator: "/")
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Text(String(component))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(index == components.count - 1 ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    if index < components.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
            }
            Spacer()
            Button {
                model.saveActiveDocument()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .litheIconButton()
            .help("Save")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 32)
    }

    @ViewBuilder
    private var activeEditor: some View {
        if let document = model.activeDocument {
            CodeEditorView(document: document)
                .id(document.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Select a file to review")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Changes from external tools will appear automatically.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(for url: URL) -> String {
        FileNode(url: url, isDirectory: false, children: nil).systemImage
    }

    private func iconColor(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift": .orange
        case "java", "kt", "kts": Color(red: 0.42, green: 0.66, blue: 0.95)
        case "js", "jsx", "ts", "tsx": .yellow
        default: LitheTheme.secondaryText
        }
    }
}
