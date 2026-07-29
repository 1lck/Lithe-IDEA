import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let comparison = model.branchComparison {
                BranchComparisonView(comparison: comparison)
            } else if let selectedChange = model.selectedChange {
                DiffReviewView(change: selectedChange)
            } else {
                VStack(spacing: 0) {
                    if model.openDocuments.isEmpty {
                        emptyState
                    } else {
                        editorTabs
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        breadcrumbs
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        externalConflictBanner
                        activeEditor
                    }
                }
            }
        }
        .background(LitheTheme.editor)
    }

    @ViewBuilder
    private var externalConflictBanner: some View {
        if let document = model.activeDocument, document.hasExternalConflict {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text("This file changed outside Lithe while you had unsaved edits.")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button("Keep Editor") { model.keepEditorVersion(of: document) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Load Disk Version") { model.loadExternalVersion(of: document) }
                    .buttonStyle(.borderedProminent)
                    .tint(LitheTheme.warning)
                    .controlSize(.small)
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.orange.opacity(0.10))
            Rectangle().fill(LitheTheme.warning.opacity(0.35)).frame(height: 1)
        }
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
                        .frame(height: 34)
                        .background(model.activeDocumentID == document.id ? LitheTheme.editor : LitheTheme.sidebar)
                        .overlay(alignment: .bottom) {
                            if model.activeDocumentID == document.id {
                                Rectangle().fill(LitheTheme.accent).frame(height: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1, height: 34)
                }
            }
        }
        .frame(height: 34)
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
        .frame(height: 29)
    }

    @ViewBuilder
    private var activeEditor: some View {
        if let document = model.activeDocument {
            CodeEditorView(document: document)
                .id(document.id)
                .clipped()
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
