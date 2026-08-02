import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject private var model: AppModel
    @State private var hoveredTabID: UUID?
    @State private var splitDocumentID: UUID?

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let comparison = model.branchComparison {
                    BranchComparisonView(comparison: comparison)
                } else if let commitDiff = model.selectedGitCommitDiffContext {
                    GitCommitDiffReviewView(context: commitDiff)
                } else if let selectedChange = model.selectedChange {
                    DiffReviewView(change: selectedChange)
                } else {
                    VStack(spacing: 0) {
                        if model.openDocuments.isEmpty {
                            emptyState
                        } else {
                            editorWorkspace
                        }
                    }
                }
            }

            if model.isImplementationChooserVisible {
                JavaImplementationChooserView()
                    .padding(.top, 48)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background(LitheTheme.editor)
        .onChange(of: model.openDocuments.map(\.id)) { _, ids in
            if let splitDocumentID, !ids.contains(splitDocumentID) {
                self.splitDocumentID = nil
            }
        }
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
                    .lithePointer()
                    .controlSize(.small)
                Button("Load Disk Version") { model.loadExternalVersion(of: document) }
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
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
                ForEach(Array(model.openDocuments.enumerated()), id: \.element.id) { index, document in
                    Button {
                        model.activeDocumentID = document.id
                    } label: {
                        HStack(spacing: 7) {
                            LitheIcon(
                                kind: LitheIcons.kind(for: document.url, isDirectory: false),
                                size: 13
                            )
                            Text(document.displayName)
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
                            .lithePointer()
                            .foregroundStyle(LitheTheme.secondaryText)
                            .opacity(model.activeDocumentID == document.id || hoveredTabID == document.id ? 1 : 0)
                        }
                        .foregroundStyle(model.activeDocumentID == document.id ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 11)
                        .frame(height: LitheTheme.Metrics.tabHeight)
                        .background(model.activeDocumentID == document.id ? LitheTheme.activeTabBackground : LitheTheme.inactiveTabBackground)
                        .overlay(alignment: .bottom) {
                            if model.activeDocumentID == document.id {
                                Rectangle().fill(LitheTheme.accent).frame(height: 2)
                            }
                        }
                        .contextMenu {
                            editorTabContextMenu(for: document, at: index)
                        }
                        .onHover { isHovering in
                            hoveredTabID = isHovering ? document.id : nil
                        }
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
        }
        .frame(height: LitheTheme.Metrics.tabHeight)
        .background(LitheTheme.sidebar)
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            editorTabs
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if let splitDocumentID,
               let splitDocument = model.openDocuments.first(where: { $0.id == splitDocumentID }) {
                HStack(spacing: 0) {
                    editorPane(model.activeDocument)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    editorPane(splitDocument, showsHeader: true)
                }
            } else {
                externalConflictBanner
                activeEditor
            }
        }
    }

    @ViewBuilder
    private func editorPane(
        _ document: EditorDocument?,
        showsHeader: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            if showsHeader, let document {
                HStack(spacing: 7) {
                    LitheIcon(
                        kind: LitheIcons.kind(for: document.url, isDirectory: false),
                        size: 13
                    )
                    Text(document.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        splitDocumentID = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .litheIconButton()
                    .help("Close split")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(LitheTheme.toolHeader)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            if let document {
                CodeEditorView(document: document, debugService: model.javaDebugService)
                    .id(document.id)
                    .clipped()
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func editorTabContextMenu(for document: EditorDocument, at index: Int) -> some View {
        Button("Close") {
            model.requestCloseDocument(document)
        }

        Button("Open in Right Split") {
            splitDocumentID = document.id
        }
        .disabled(model.openDocuments.count < 2)

        Button("Close Other Tabs") {
            model.requestCloseDocuments(
                model.openDocuments.filter { $0.id != document.id },
                preferredDocumentID: document.id
            )
        }
        .disabled(model.openDocuments.count <= 1)

        Button("Close Tabs to the Left") {
            model.requestCloseDocuments(
                Array(model.openDocuments.prefix(index)),
                preferredDocumentID: document.id
            )
        }
        .disabled(index == 0)

        Button("Close Tabs to the Right") {
            let documents = Array(model.openDocuments.dropFirst(index + 1))
            model.requestCloseDocuments(documents, preferredDocumentID: document.id)
        }
        .disabled(index >= model.openDocuments.count - 1)

        Button("Close Unmodified Tabs") {
            model.requestCloseDocuments(
                model.openDocuments.filter { !$0.isDirty },
                preferredDocumentID: document.id
            )
        }

        Button("Close All Tabs") {
            model.requestCloseDocuments(model.openDocuments)
        }

        Divider()

        Menu("Copy Path / Reference") {
            Button("Copy Path") {
                model.copyProjectItemPath(document.url, relative: false)
            }
            Button("Copy Relative Path") {
                model.copyProjectItemPath(document.url, relative: true)
            }
        }

        Button("Show in Finder") {
            model.revealProjectItemInFinder(document.url)
        }
        Button("Local History…") {
            model.showLocalHistory(for: document.url)
        }

        Divider()

        Button("Rename…") {
            model.requestRenameProjectItem(at: document.url)
        }
    }

    @ViewBuilder
    private var activeEditor: some View {
        if let document = model.activeDocument {
            CodeEditorView(document: document, debugService: model.javaDebugService)
                .id(document.id)
                .clipped()
                .overlay(alignment: .top) {
                    if model.isFindBarVisible {
                        FindBarView()
                            .padding(.top, 10)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
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

}
