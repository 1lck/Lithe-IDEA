import SwiftUI
import UniformTypeIdentifiers

private enum MarkdownViewMode: String, CaseIterable, Identifiable, Equatable {
    case editor
    case split
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .split: "Editor and Preview"
        case .preview: "Preview"
        }
    }

    var symbolName: String {
        switch self {
        case .editor: "pencil.line"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}

struct EditorAreaView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?
    @State private var splitDocumentID: UUID?
    @State private var markdownViewModes: [UUID: MarkdownViewMode] = [:]
    @State private var markdownScrollPositions: [UUID: MarkdownScrollPosition] = [:]
    @State private var hoveredMarkdownMode: MarkdownViewMode?

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
            markdownViewModes = markdownViewModes.filter { ids.contains($0.key) }
            markdownScrollPositions = markdownScrollPositions.filter { ids.contains($0.key) }
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
        HStack(alignment: .top, spacing: 0) {
            editorTabLayout
                .frame(maxWidth: .infinity, alignment: .leading)
            if let document = model.activeDocument,
               isMarkdownFile(document),
               splitDocumentID == nil {
                markdownModePicker
            }
        }
        .frame(minHeight: LitheTheme.Metrics.tabHeight, alignment: .top)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var editorTabLayout: some View {
        switch settings.editorTabLayoutMode {
        case .singleLine:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    editorTabItems
                }
            }
            .frame(height: LitheTheme.Metrics.tabHeight)
        case .multipleRows:
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 1)
                ],
                alignment: .leading,
                spacing: 1
            ) {
                editorTabItems
            }
            .padding(.vertical, 2)
        }
    }

    private var editorTabItems: some View {
        ForEach(Array(model.openDocuments.enumerated()), id: \.element.id) { index, document in
            editorTab(document, at: index)
        }
    }

    private func editorTab(_ document: EditorDocument, at index: Int) -> some View {
        Group {
            if settings.editorTabLayoutMode == .multipleRows {
                editorTabContent(document)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                editorTabContent(document)
            }
        }
        .contextMenu {
            editorTabContextMenu(for: document, at: index)
        }
        .onHover { isHovering in
            hoveredTabID = isHovering ? document.id : nil
        }
        .onDrag {
            draggedTabID = document.id
            return NSItemProvider(object: document.id.uuidString as NSString)
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .onDrop(
                        of: [UTType.text],
                        delegate: EditorTabDropDelegate(
                            draggedDocumentID: draggedTabID,
                            targetDocumentID: document.id,
                            targetWidth: geometry.size.width,
                            move: { source, target, insertAfter in
                                if insertAfter {
                                    model.moveOpenDocument(source, after: target)
                                } else {
                                    model.moveOpenDocument(source, before: target)
                                }
                            },
                            finish: {
                                draggedTabID = nil
                            }
                        )
                    )
            }
        }
    }

    private func editorTabContent(_ document: EditorDocument) -> some View {
        HStack(spacing: 0) {
            Button {
                model.activeDocumentID = document.id
            } label: {
                HStack(spacing: 7) {
                    LitheIcon(
                        kind: LitheIcons.kind(for: document.url, isDirectory: false),
                        size: 13
                    )
                    editorTabTitle(document)
                    if document.isDirty {
                        Circle()
                            .fill(LitheTheme.primaryText)
                            .frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(model.activeDocumentID == document.id ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .padding(.leading, 11)
                .frame(height: LitheTheme.Metrics.tabHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            Button {
                model.requestCloseDocument(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .opacity(model.activeDocumentID == document.id || hoveredTabID == document.id ? 1 : 0)
            .allowsHitTesting(model.activeDocumentID == document.id || hoveredTabID == document.id)
            .padding(.trailing, 4)
        }
        .background(model.activeDocumentID == document.id ? LitheTheme.activeTabBackground : LitheTheme.inactiveTabBackground)
        .overlay(alignment: .bottom) {
            if model.activeDocumentID == document.id {
                Rectangle().fill(LitheTheme.accent).frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private func editorTabTitle(_ document: EditorDocument) -> some View {
        if settings.editorTabLayoutMode == .multipleRows {
            Text(document.displayName)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
        } else {
            Text(document.displayName)
                .font(.system(size: 12.5))
                .lineLimit(1)
        }
    }

    private var markdownModePicker: some View {
        HStack(spacing: 1) {
            ForEach(MarkdownViewMode.allCases) { mode in
                let isSelected = selectedMarkdownMode == mode
                let isHovered = hoveredMarkdownMode == mode

                Button {
                    selectMarkdownMode(mode)
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected || isHovered ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .frame(width: 29, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    isSelected
                                        ? LitheTheme.selection.opacity(0.82)
                                        : (isHovered ? LitheTheme.hoverBackground : .clear)
                                )
                        )
                        .opacity(isSelected || isHovered ? 1 : 0.72)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help(mode.title)
                .onHover { isHovering in
                    if isHovering {
                        hoveredMarkdownMode = mode
                    } else if hoveredMarkdownMode == mode {
                        hoveredMarkdownMode = nil
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(LitheTheme.inputBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .stroke(LitheTheme.divider, lineWidth: 1)
        }
        .frame(width: 104, height: 26)
        .padding(.horizontal, 7)
        .animation(.easeOut(duration: 0.12), value: hoveredMarkdownMode)
    }

    private var selectedMarkdownMode: MarkdownViewMode {
        guard let document = model.activeDocument else { return .editor }
        return markdownViewModes[document.id] ?? .editor
    }

    private func selectMarkdownMode(_ mode: MarkdownViewMode) {
        guard let document = model.activeDocument else { return }
        markdownViewModes[document.id] = mode
    }

    private func isMarkdownFile(_ document: EditorDocument) -> Bool {
        ["md", "markdown"].contains(document.url.pathExtension.lowercased())
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
                CodeEditorView(
                    document: document,
                    debugService: model.debugFeature,
                    shouldFocus: !showsHeader && document.id == model.activeDocumentID
                )
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
            if isMarkdownFile(document) {
                switch markdownViewModes[document.id] ?? .editor {
                case .editor:
                    editorWithFindBar(document)
                case .split:
                    let scrollPosition = markdownScrollPosition(for: document)
                    HStack(spacing: 0) {
                        editorWithFindBar(document, markdownScrollPosition: scrollPosition)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle()
                            .fill(LitheTheme.divider)
                            .frame(width: 1)
                        MarkdownPreviewView(
                            document: document,
                            scrollPosition: scrollPosition
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .preview:
                    MarkdownPreviewView(document: document)
                }
            } else {
                editorWithFindBar(document)
            }
        } else {
            emptyState
        }
    }

    private func editorWithFindBar(
        _ document: EditorDocument,
        markdownScrollPosition: Binding<MarkdownScrollPosition>? = nil
    ) -> some View {
        codeEditor(document, markdownScrollPosition: markdownScrollPosition)
            .overlay(alignment: .top) {
                if model.isFindBarVisible {
                    FindBarView()
                        .padding(.top, 10)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }

    private func codeEditor(
        _ document: EditorDocument,
        markdownScrollPosition: Binding<MarkdownScrollPosition>? = nil
    ) -> some View {
        CodeEditorView(
            document: document,
            debugService: model.debugFeature,
            shouldFocus: true,
            markdownScrollPosition: markdownScrollPosition
        )
        .id(document.id)
        .clipped()
    }

    private func markdownScrollPosition(for document: EditorDocument) -> Binding<MarkdownScrollPosition> {
        Binding(
            get: { markdownScrollPositions[document.id] ?? MarkdownScrollPosition() },
            set: { markdownScrollPositions[document.id] = $0 }
        )
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

private struct EditorTabDropDelegate: DropDelegate {
    let draggedDocumentID: UUID?
    let targetDocumentID: UUID
    let targetWidth: CGFloat
    let move: (UUID, UUID, Bool) -> Void
    let finish: () -> Void

    func dropEntered(info: DropInfo) {
        moveIfNeeded(using: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        moveIfNeeded(using: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finish()
        return true
    }

    private func moveIfNeeded(using info: DropInfo) {
        guard let draggedDocumentID,
              draggedDocumentID != targetDocumentID else { return }
        move(
            draggedDocumentID,
            targetDocumentID,
            targetWidth > 0 && info.location.x > targetWidth / 2
        )
    }
}
