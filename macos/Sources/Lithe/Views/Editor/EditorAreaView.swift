import AppKit
import SwiftUI
import LitheGitModule
import LitheTerminalModule

private let editorTabCoordinateSpaceName = "lithe.editor-tab-strip"

enum EditorDocumentIconResolver {
    static func kind(
        for url: URL,
        resolvedKind: LitheIconKind?
    ) -> LitheIconKind {
        resolvedKind ?? LitheIcons.kind(for: url, isDirectory: false)
    }
}

private struct EditorDocumentTabIcon: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    let size: CGFloat
    @State private var resolvedKind: LitheIconKind?

    private struct ResolutionKey: Hashable {
        let path: String
        let contentRevision: UInt64
    }

    private var resolutionKey: ResolutionKey {
        ResolutionKey(path: document.url.standardizedFileURL.path,
                      contentRevision: document.iconContentRevision)
    }

    var body: some View {
        LitheIcon(
            kind: EditorDocumentIconResolver.kind(for: document.url, resolvedKind: resolvedKind),
            size: size
        )
        .task(id: resolutionKey) {
            let key = resolutionKey
            let url = document.url
            resolvedKind = nil
            if url.pathExtension.lowercased() == "java" {
                guard let kind = await model.javaIconKind(for: url),
                      !Task.isCancelled, resolutionKey == key else { return }
                resolvedKind = kind
            } else if LitheIcons.kind(for: url, isDirectory: false) == .generic {
                let resolved = await WorkspaceFileIconResolver.resolve(
                    for: url,
                    suggested: .generic,
                    storage: model.services.fileStorage
                )
                guard !Task.isCancelled, resolutionKey == key else { return }
                resolvedKind = resolved.kind
            }
        }
    }
}

enum DocumentPreviewMode: String, CaseIterable, Identifiable, Equatable {
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
    @State private var editorIsActive = true
    @State private var hoveredTabItem: EditorTabItem?
    @State private var tabDragState = EditorTabDragState.idle
    @State private var tabFrameStore = EditorTabFrameStore()
    @State private var tabDragStartFrames: [EditorTabItem: CGRect] = [:]
    @State private var tabDragPreview = EditorTabDragPreviewStore()
    @State private var tabDragCancelled = false
    @State private var tabReorderTarget: EditorTabReorderTarget?
    @State private var isTerminalTabBarDropTargeted = false
    @State private var splitDocumentID: UUID?
    @State private var documentPreviewModes: [UUID: DocumentPreviewMode] = [:]
    @State private var markdownScrollPositions: [UUID: MarkdownScrollPosition] = [:]
    @State private var hoveredPreviewMode: DocumentPreviewMode?

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("EditorAreaView")
        ZStack(alignment: .top) {
            Group {
                if model.workbenchFeature.selectedSidebar == .database {
                    if let feature = model.databaseFeatureIfActive {
                        DatabaseWorkspaceView()
                            .environmentObject(feature)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let feature = model.gitFeatureIfActive,
                          let comparison = feature.branchComparison {
                    BranchComparisonView(
                        feature: feature,
                        comparison: comparison,
                        onRefresh: { [weak model] in
                            if let target = comparison.targetReference {
                                await model?.showComparison(from: comparison.reference, to: target)
                            } else {
                                await model?.showComparisonWithWorkingTree(for: comparison.reference)
                            }
                        },
                        fontFamily: settings.editorFontFamily
                    )
                } else if let feature = model.gitFeatureIfActive,
                          let selectedChange = feature.selectedChange {
                    DiffReviewView(feature: feature, change: selectedChange,
                        fontFamily: settings.editorFontFamily)
                } else {
                    VStack(spacing: 0) {
                        if model.editorTabItems.isEmpty {
                            emptyState
                        } else {
                            editorWorkspace
                        }
                    }
                }
            }

            if model.isImplementationChooserVisible {
                LanguageImplementationChooserView()
                    .padding(.top, 48)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
        .background(GoToLineDialogPresenter())
        .background(LitheToolWindowActivityTracker(isActive: $editorIsActive))
        .onChange(of: model.openDocuments.map(\.id)) { ids in
            if let splitDocumentID, !ids.contains(splitDocumentID) {
                self.splitDocumentID = nil
            }
            documentPreviewModes = documentPreviewModes.filter { ids.contains($0.key) }
            markdownScrollPositions = markdownScrollPositions.filter { ids.contains($0.key) }
        }
        .onChange(of: model.editorTabItems) { items in
            isTerminalTabBarDropTargeted = false
            if let draggedItem = tabDragState.draggedItem,
               !items.contains(draggedItem) {
                finishTabDrag()
            }
        }
        .onDisappear {
            isTerminalTabBarDropTargeted = false
            finishTabDrag()
        }
        .onChange(of: settings.editorTabLayoutMode) { _ in
            finishTabDrag()
        }
    }

    @ViewBuilder
    private var externalConflictBanner: some View {
        if model.activeEditorTerminalSession == nil,
           let document = model.activeDocument,
           document.hasExternalConflict {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text(LocalizedStringKey(document.externalFileMissing ? "This file was deleted outside Lithe. Your editor content is preserved." : "This file changed outside Lithe while you had unsaved edits."))
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                Spacer()
                Button(LocalizedStringKey(document.externalFileMissing ? "Allow Recreating File" : "Keep Editor")) { model.keepEditorVersion(of: document) }
                    .buttonStyle(.bordered)
                    .lithePointer()
                    .controlSize(.small)
                Button("Load Disk Version") { model.loadExternalVersion(of: document) }
                    .disabled(document.externalFileMissing)
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
            if !model.isRepositoryDiffSelected, let document = model.activeDocument,
               model.activeEditorTerminalSession == nil,
               (isMarkdownFile(document) || isSVGFile(document) || isHTMLFile(document)),
               splitDocumentID == nil {
                documentPreviewModePicker
            }
        }
        .frame(minHeight: 36, alignment: .top)
        .contentShape(Rectangle())
        .background {
            EditorTabMiddleClickMonitor(hoveredItem: hoveredTabItem) { item in
                closeEditorTab(item)
            }
        }
        .background(
            isTerminalTabBarDropTargeted
                ? LitheTheme.accent.opacity(0.08)
                : (model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
        )
        .onDrop(
            of: [TerminalTabDragPayload.type],
            delegate: EditorTabBarDropDelegate(
                setTargeted: { isTerminalTabBarDropTargeted = $0 },
                updateTarget: { location in
                    updateTerminalTabBarDropTarget(at: location)
                },
                clearTarget: { clearTerminalTabBarDropTarget() },
                resolveTarget: { location in
                    terminalTabBarDropTarget(at: location)
                },
                finish: { finishTabDrag() },
                receiveTerminal: { sessionID, target in
                    guard let target,
                          model.editorTabItems.contains(target.item) else {
                        if !model.editorTerminalSessions.contains(where: { $0.id == sessionID }) {
                            model.moveTerminalToEditor(sessionID)
                        }
                        return
                    }
                    if target.side == .after {
                        model.moveEditorTab(.terminal(sessionID), after: target.item)
                    } else {
                        model.moveEditorTab(.terminal(sessionID), before: target.item)
                    }
                }
            )
        )
    }

    @ViewBuilder
    private var editorTabLayout: some View {
        Group {
            switch settings.editorTabLayoutMode {
            case .singleLine:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        editorTabItems
                    }
                }
                .frame(height: 36)
            case .multipleRows:
                multipleRowsEditorTabLayout
            }
        }
        .coordinateSpace(name: editorTabCoordinateSpaceName)
        .onPreferenceChange(EditorTabFramePreferenceKey.self) { frames in
            guard tabDragState.draggedItem == nil else { return }
            tabFrameStore.update(frames)
        }
        .clipped()
        // Tab placement and placeholder restoration are immediate, including
        // when a parent workbench update carries an animation transaction.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var multipleRowsEditorTabLayout: some View {
        EditorTabFlowLayout(horizontalSpacing: 4, verticalSpacing: 2) {
            editorTabItems
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var editorTabItems: some View {
        // Index once per pass. Scanning `openDocuments` and `terminalSessions`
        // per tab made this quadratic, and it re-runs on every layout pass.
        let documentIndices = Dictionary(
            model.openDocuments.enumerated().map { ($0.element.id, $0.offset) },
            // First match wins, matching the `firstIndex(where:)` this replaces.
            uniquingKeysWith: { first, _ in first }
        )
        let sessionsByID = Dictionary(
            model.terminalSessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        ForEach(displayedTabItems) { item in
            Group {
                switch item {
                case .repositoryDiff:
                    repositoryDiffTab
                case .document(let documentID):
                    if let index = documentIndices[documentID] {
                        editorTab(model.openDocuments[index], at: index)
                    }
                case .terminal(let sessionID):
                    if let session = sessionsByID[sessionID] {
                        editorTerminalTab(session)
                    }
                case .media(let mediaID):
                    if let media = model.openMediaDocuments.first(where: { $0.id == mediaID }) {
                        editorMediaTab(media)
                    }
                }
            }
            .background(EditorTabDragPreviewAnchor(item: item, store: tabDragPreview))
            .opacity(tabDragState.draggedItem == item ? 0 : 1)
            .overlay {
                if tabDragState.draggedItem == item {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LitheTheme.editorTabDropBackground)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var displayedTabItems: [EditorTabItem] {
        var items = model.editorTabItems
        guard let source = tabDragState.draggedItem, let target = tabReorderTarget,
              source != target.item else { return items }
        items.removeAll { $0 == source }
        guard let index = items.firstIndex(of: target.item) else { return model.editorTabItems }
        items.insert(source, at: index + (target.side == .after ? 1 : 0))
        return items
    }

    private var repositoryDiffTab: some View {
        let selected = model.isRepositoryDiffSelected
        let title = model.selectedGitCommitDiffContext.map { "Repository Diff: " + $0.url.lastPathComponent }
            ?? "Repository Diff"
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                LitheIDEAIcon(resourcePath: "expui/vcs/diff.svg", size: 16, preservesOriginalColors: true)
                Text(title.count > 30 ? String(title.prefix(27)) + "..." : title).font(LitheTheme.uiFont(size: 13)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture { model.selectRepositoryDiffTab() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectRepositoryDiffTab() }
            .highPriorityGesture(editorTabDragGesture(for: .repositoryDiff))
            LitheToolWindowTabCloseButton { model.closeGitCommitDiff() }
                .opacity(selected || hoveredTabItem == .repositoryDiff ? 1 : 0)
                .allowsHitTesting(selected || hoveredTabItem == .repositoryDiff)
        }
        .foregroundStyle(selected ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .modifier(LitheToolWindowTabStyle(isSelected: selected, isActive: editorIsActive))
        .padding(.horizontal, 4).padding(.vertical, 4)
        .onHover { updateHoveredTab(.repositoryDiff, isHovering: $0) }
        .help(title)
        .background { editorTabFrameReader(for: .repositoryDiff) }
        .zIndex(tabDragState.draggedItem == .repositoryDiff ? 1 : 0)
    }

    private func editorTab(_ document: EditorDocument, at index: Int) -> some View {
        let tabItem = EditorTabItem.document(document.id)
        let dragSessionID = tabDragState.sessionID
        let dropTargetRevision = tabDragState.dropTargetRevision

        return ZStack(alignment: .leading) {
            if settings.editorTabLayoutMode == .multipleRows {
                editorTabContent(document)
                    .frame(minWidth: EditorTabFlowLayout.minimumItemWidth, alignment: .leading)
            } else {
                editorTabContent(document)
            }
        }
        .contentShape(Rectangle())
        .litheContextMenu {
            editorTabContextMenu(for: document, at: index)
        }
        .onHover { isHovering in
            updateHoveredTab(.document(document.id), isHovering: isHovering)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [EditorTabDragPayload.type, TerminalTabDragPayload.type],
                        delegate: EditorTabDropDelegate(
                            draggedItem: tabDragState.draggedItem,
                            targetDocumentID: document.id,
                            targetWidth: geometry.size.width,
                            dragSessionID: dragSessionID,
                            dropTargetRevision: dropTargetRevision,
                            updateTarget: { target, sessionID, revision, settlesDrop in
                                guard tabDragState.sessionID == sessionID,
                                      tabDragState.dropTargetRevision == revision,
                                      let source = tabDragState.draggedItem,
                                      source != .document(target.documentID) else { return }
                                if tabDragState.dropTarget != target {
                                    tabDragState.updateTarget(target)
                                }
                                guard settlesDrop else { return }
                                if target.side == .after {
                                    model.moveEditorTab(
                                        source,
                                        after: .document(target.documentID)
                                    )
                                } else {
                                    model.moveEditorTab(
                                        source,
                                        before: .document(target.documentID)
                                    )
                                }
                            },
                            clearTarget: { targetDocumentID, sessionID, revision in
                                guard tabDragState.sessionID == sessionID,
                                      tabDragState.dropTargetRevision == revision,
                                      tabDragState.dropTarget?.documentID == targetDocumentID else { return }
                                _ = tabDragState.clearTarget(
                                    documentID: targetDocumentID,
                                    sessionID: sessionID,
                                    revision: revision
                                )
                            },
                            updateTerminalTarget: { target in
                                updateTerminalTabBarDropTarget(target)
                            },
                            clearTerminalTarget: { item in
                                clearTerminalTabBarDropTarget(matching: item)
                            },
                            resolveTerminalSide: { proposedSide in
                                resolveTerminalDropSide(
                                    proposedSide,
                                    target: .document(document.id)
                                )
                            },
                            finish: { finishTabDrag() },
                            receiveTerminal: { sessionID, side in
                                if side == .after {
                                    model.moveEditorTab(
                                        .terminal(sessionID),
                                        after: .document(document.id)
                                    )
                                } else {
                                    model.moveEditorTab(
                                        .terminal(sessionID),
                                        before: .document(document.id)
                                    )
                                }
                            }
                        )
                    )
            }
        }
        .background {
            editorTabFrameReader(for: tabItem)
        }
    }

    private func editorMediaTab(_ media: MediaDocument) -> some View {
        let isActive = !model.isRepositoryDiffSelected && model.activeEditorTerminalSession == nil
            && model.activeMediaDocumentID == media.id
        let tabItem = EditorTabItem.media(media.id)

        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: media.kind == .image ? "photo" : "film")
                    .font(LitheTheme.uiFont(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(media.displayName)
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture { model.selectMediaDocument(media) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(media.displayName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectMediaDocument(media) }
            .gesture(editorTabDragGesture(for: tabItem))

            LitheToolWindowTabCloseButton { model.closeMediaDocument(media) }
            .opacity(isActive || hoveredTabItem == tabItem ? 1 : 0)
            .allowsHitTesting(isActive || hoveredTabItem == tabItem)
            .padding(.trailing, 4)
        }
        .onHover { isHovering in
            updateHoveredTab(tabItem, isHovering: isHovering)
        }
        .modifier(LitheToolWindowTabStyle(isSelected: isActive, isActive: editorIsActive))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background { editorTabFrameReader(for: tabItem) }
    }

    private func editorTerminalTab(_ session: TerminalSession) -> some View {
        let isActive = !model.isRepositoryDiffSelected && model.activeEditorTerminalSession?.id == session.id
        let tabItem = EditorTabItem.terminal(session.id)

        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "terminal")
                    .font(LitheTheme.uiFont(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? LitheTheme.accent : LitheTheme.secondaryText)
                EditorTerminalTabTitle(
                    session: session,
                    fallbackTitle: model.terminalTitle(for: session)
                )
            }
            .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .padding(.leading, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectEditorTerminalSession(session)
                session.focus()
            }
            // Terminal sessions retain their native cross-container transfer.
            .onDrag {
                TerminalTabDragPayload.provider(for: session.id)
            } preview: {
                Image(systemName: "terminal")
                    .font(LitheTheme.uiFont(size: 10, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 20, height: 20)
                    .background(LitheTheme.activeTabBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.terminalTitle(for: session))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.selectEditorTerminalSession(session)
            }
            .lithePointer()

            LitheToolWindowTabCloseButton { model.requestCloseTerminalSession(session) }
            .opacity(isActive || hoveredTabItem == tabItem ? 1 : 0)
            .allowsHitTesting(isActive || hoveredTabItem == tabItem)
            .padding(.trailing, 4)
        }
        .modifier(LitheToolWindowTabStyle(isSelected: isActive, isActive: editorIsActive))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [EditorTabDragPayload.type, TerminalTabDragPayload.type],
                        delegate: EditorTerminalTabDropDelegate(
                            draggedItem: tabDragState.draggedItem,
                            targetSessionID: session.id,
                            targetWidth: geometry.size.width,
                            moveItemBefore: { item in
                                model.moveEditorTab(item, before: tabItem)
                            },
                            moveItemAfter: { item in
                                model.moveEditorTab(item, after: tabItem)
                            },
                            moveTerminalBefore: { sourceID in
                                model.moveTerminalToEditor(sourceID, before: session.id)
                            },
                            moveTerminalAfter: { sourceID in
                                model.moveTerminalToEditor(sourceID, after: session.id)
                            },
                            updateTerminalTarget: { target in
                                updateTerminalTabBarDropTarget(target)
                            },
                            clearTerminalTarget: { item in
                                clearTerminalTabBarDropTarget(matching: item)
                            },
                            resolveTerminalSide: { proposedSide in
                                resolveTerminalDropSide(
                                    proposedSide,
                                    target: .terminal(session.id)
                                )
                            },
                            finish: { finishTabDrag() }
                        )
                    )
            }
        }
        .background {
            editorTabFrameReader(for: tabItem)
        }
        .onHover { isHovering in
            updateHoveredTab(tabItem, isHovering: isHovering)
        }
        .litheContextMenu {
            [
                .action("Interrupt", systemImage: "stop.fill", action: session.interrupt),
                .action("Restart", systemImage: "arrow.clockwise", action: session.restart),
                .action("Clear", systemImage: "eraser", action: session.clear),
                .separator,
                .action("Close", systemImage: "xmark", action: {
                    model.requestCloseTerminalSession(session)
                })
            ]
        }
    }

    private func editorTabContent(
        _ document: EditorDocument
    ) -> some View {
        let isActive = !model.isRepositoryDiffSelected && model.activeEditorTerminalSession == nil
            && model.activeDocumentID == document.id

        return HStack(spacing: 0) {
            editorDocumentTabDragSource(document, isActive: isActive)

            LitheToolWindowTabCloseButton { model.requestCloseDocument(document) }
            .opacity(isActive || hoveredTabItem == .document(document.id) ? 1 : 0)
            .allowsHitTesting(isActive || hoveredTabItem == .document(document.id))
            .padding(.trailing, 4)
        }
        .modifier(LitheToolWindowTabStyle(isSelected: isActive, isActive: editorIsActive))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func editorDocumentTabDragSource(
        _ document: EditorDocument,
        isActive: Bool
    ) -> some View {
        let label = HStack(spacing: 7) {
            EditorDocumentTabIcon(document: document, size: 16)
            editorTabTitle(document)
            EditorTabDirtyIndicator(document: document)
        }
        .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .padding(.leading, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectEditorDocument(document)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            model.selectEditorDocument(document)
        }

        // File, media and Diff tabs share the same gesture in either layout.
        // A native onDrag source here could not drop onto a Diff tab.
        label.highPriorityGesture(editorTabDragGesture(for: .document(document.id)))
    }

    @ViewBuilder
    private func editorTabTitle(_ document: EditorDocument) -> some View {
        if settings.editorTabLayoutMode == .multipleRows {
            Text(document.displayName)
                .font(LitheTheme.uiFont(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
        } else {
            Text(document.displayName)
                .font(LitheTheme.uiFont(size: 13))
                .lineLimit(1)
        }
    }

    private func updateHoveredTab(_ item: EditorTabItem, isHovering: Bool) {
        if isHovering {
            hoveredTabItem = item
        } else if hoveredTabItem == item {
            hoveredTabItem = nil
        }
    }

    private func closeEditorTab(_ item: EditorTabItem) {
        switch item {
        case .repositoryDiff:
            model.closeGitCommitDiff()
        case .document(let documentID):
            guard let document = model.openDocuments.first(where: { $0.id == documentID }) else { return }
            model.requestCloseDocument(document)
        case .terminal(let sessionID):
            guard let session = model.terminalSessions.first(where: { $0.id == sessionID }) else { return }
            model.requestCloseTerminalSession(session)
        case .media(let mediaID):
            guard let media = model.openMediaDocuments.first(where: { $0.id == mediaID }) else { return }
            model.closeMediaDocument(media)
        }
    }

    private func editorTabFrameReader(for item: EditorTabItem) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: EditorTabFramePreferenceKey.self,
                value: [
                    item: geometry.frame(in: .named(editorTabCoordinateSpaceName))
                ]
            )
        }
    }

    private func editorTabDragGesture(for item: EditorTabItem) -> some Gesture {
        DragGesture(
            minimumDistance: 8,
            // The strip stays fixed while its tab slots move. Use that same
            // coordinate space for both the pointer and the recorded tab frames.
            coordinateSpace: .named(editorTabCoordinateSpaceName)
        )
        .onChanged { value in
            guard !tabDragCancelled else { return }
            if tabDragState.draggedItem != item {
                beginTabDrag(item)
            }
            updateTabDrag(item, translation: value.translation, location: value.location)
        }
        .onEnded { value in
            defer { tabDragCancelled = false }
            guard !tabDragCancelled else { return }
            finishTabReorder(item, translation: value.translation, location: value.location)
        }
    }

    private func beginTabDrag(_ item: EditorTabItem) {
        tabDragStartFrames = tabFrameStore.frames
        tabDragPreview.begin(item, onCancel: { cancelTabDrag() })
        tabReorderTarget = nil
        tabDragState.begin(item: item)
    }

    private func updateTabDrag(
        _ item: EditorTabItem,
        translation: CGSize,
        location: CGPoint
    ) {
        guard tabDragState.draggedItem == item,
              let plan = tabDragPlan(for: item, translation: translation, location: location) else { return }
        tabDragPreview.move(by: translation)
        guard tabReorderTarget != plan.target else { return }
        tabReorderTarget = plan.target
    }

    private func finishTabReorder(
        _ item: EditorTabItem,
        translation: CGSize,
        location: CGPoint
    ) {
        guard tabDragState.draggedItem == item else {
            finishTabDrag()
            return
        }
        let target = tabDragPlan(for: item, translation: translation, location: location)?.target
        if let target {
            if target.side == .after {
                model.moveEditorTab(item, after: target.item)
            } else {
                model.moveEditorTab(item, before: target.item)
            }
        }
        tabDragPreview.finish()
        tabReorderTarget = nil
        tabDragState.finish()
        tabDragStartFrames = [:]
    }

    private func tabDragPlan(
        for item: EditorTabItem,
        translation: CGSize,
        location: CGPoint
    ) -> (offset: CGSize, target: EditorTabReorderTarget?)? {
        guard let sourceFrame = tabDragStartFrames[item] else { return nil }
        let wraps = settings.editorTabLayoutMode == .multipleRows
        let minY = tabDragStartFrames.values.map(\.minY).min() ?? sourceFrame.minY
        let maxY = tabDragStartFrames.values.map(\.maxY).max() ?? sourceFrame.maxY
        let offsetY = wraps ? min(max(translation.height, minY - sourceFrame.minY), maxY - sourceFrame.maxY) : 0
        guard location.y >= minY, location.y <= maxY else {
            return (translation, nil)
        }
        let rowAnchor = tabDragStartFrames.values.min { abs($0.midY - location.y) < abs($1.midY - location.y) } ?? sourceFrame
        let rowFrames = tabDragStartFrames.filter { _, frame in
            frame.maxY > rowAnchor.minY && frame.minY < rowAnchor.maxY
        }
        // Across rows, resolve insertion against the destination row's tab centers.
        if wraps, !rowFrames.keys.contains(item), !rowFrames.isEmpty {
            let leadingX = sourceFrame.minX + translation.width
            let ordered = rowFrames.sorted { $0.value.minX < $1.value.minX }
            let before = ordered.first { leadingX < $0.value.midX }
            let target = before ?? ordered[ordered.count - 1]
            return (CGSize(width: translation.width, height: offsetY),
                    EditorTabReorderTarget(item: target.key, side: before == nil ? .after : .before))
        }
        guard let rowMinX = rowFrames.values.map(\.minX).min(),
              let rowMaxX = rowFrames.values.map(\.maxX).max() else { return nil }

        let offset = min(
            max(translation.width, rowMinX - sourceFrame.minX),
            rowMaxX - sourceFrame.maxX
        )
        let candidates = rowFrames.filter { $0.key != item }
        let target: EditorTabReorderTarget?

        if offset > 0 {
            let probeX = sourceFrame.maxX + offset
            target = candidates
                .filter { _, frame in
                    frame.midX > sourceFrame.midX
                        && probeX > frame.midX
                            + frame.width * EditorTabDropGeometry.hoverDeadZoneRatio
                }
                .max { $0.value.midX < $1.value.midX }
                .map { EditorTabReorderTarget(item: $0.key, side: .after) }
        } else if offset < 0 {
            let probeX = sourceFrame.minX + offset
            target = candidates
                .filter { _, frame in
                    frame.midX < sourceFrame.midX
                        && probeX < frame.midX
                            - frame.width * EditorTabDropGeometry.hoverDeadZoneRatio
                }
                .min { $0.value.midX < $1.value.midX }
                .map { EditorTabReorderTarget(item: $0.key, side: .before) }
        } else {
            target = nil
        }

        return (CGSize(width: offset, height: offsetY), target)
    }

    private func updateTerminalTabBarDropTarget(at location: CGPoint) {
        guard let target = terminalTabBarDropTarget(at: location) else {
            clearTerminalTabBarDropTarget()
            return
        }
        updateTerminalTabBarDropTarget(target)
    }

    private func terminalTabBarDropTarget(at location: CGPoint) -> EditorTabReorderTarget? {
        let activeTerminalItem = TerminalTabDragPayload.activeSessionID.map {
            EditorTabItem.terminal($0)
        }
        if let activeTerminalItem,
           let sourceFrame = tabFrameStore[activeTerminalItem],
           sourceFrame.contains(location) {
            return nil
        }
        let candidates = tabFrameStore.frames.filter { item, _ in
            item != tabDragState.draggedItem && item != activeTerminalItem
        }
        guard let nearest = candidates.min(by: { lhs, rhs in
            tabDropDistance(from: location, to: lhs.value)
                < tabDropDistance(from: location, to: rhs.value)
        }) else { return nil }

        let frame = nearest.value
        let side: EditorTabDropSide
        if let activeTerminalItem,
           let sourceIndex = model.editorTabItems.firstIndex(of: activeTerminalItem),
           let targetIndex = model.editorTabItems.firstIndex(of: nearest.key) {
            side = targetIndex < sourceIndex ? .before : .after
        } else if location.x <= frame.minX {
            side = .before
        } else if location.x >= frame.maxX {
            side = .after
        } else {
            side = EditorTabDropGeometry.finalSide(
                locationX: location.x - frame.minX,
                width: frame.width
            )
        }
        return EditorTabReorderTarget(item: nearest.key, side: side)
    }

    private func updateTerminalTabBarDropTarget(_ target: EditorTabReorderTarget) {
        guard tabReorderTarget != target else { return }
        tabReorderTarget = target
    }

    private func resolveTerminalDropSide(
        _ proposedSide: EditorTabDropSide,
        target: EditorTabItem
    ) -> EditorTabDropSide {
        guard let sessionID = TerminalTabDragPayload.activeSessionID,
              let sourceIndex = model.editorTabItems.firstIndex(of: .terminal(sessionID)),
              let targetIndex = model.editorTabItems.firstIndex(of: target) else {
            return proposedSide
        }
        return targetIndex < sourceIndex ? .before : .after
    }

    private func tabDropDistance(from location: CGPoint, to frame: CGRect) -> CGFloat {
        let horizontalDistance = max(
            max(frame.minX - location.x, location.x - frame.maxX),
            0
        )
        let verticalDistance = max(
            max(frame.minY - location.y, location.y - frame.maxY),
            0
        )
        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }

    private func clearTerminalTabBarDropTarget(matching item: EditorTabItem? = nil) {
        guard let currentTarget = tabReorderTarget,
              item == nil || currentTarget.item == item else { return }
        tabReorderTarget = nil
    }

    private func cancelTabDrag() {
        guard tabDragState.draggedItem != nil else { return }
        tabDragCancelled = true
        finishTabDrag()
    }

    private func finishTabDrag() {
        guard tabDragState != .idle
            || tabReorderTarget != nil
            || tabDragPreview.panel != nil else { return }
        tabDragPreview.finish()
        tabReorderTarget = nil
        tabDragState.finish()
        tabDragStartFrames = [:]
    }

    private var documentPreviewModePicker: some View {
        HStack(spacing: 1) {
            ForEach(DocumentPreviewMode.allCases) { mode in
                let isSelected = selectedDocumentPreviewMode == mode
                let isHovered = hoveredPreviewMode == mode

                Button {
                    selectDocumentPreviewMode(mode)
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(LitheTheme.uiFont(size: 11, weight: .medium))
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
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .onHover { isHovering in
                    if isHovering {
                        hoveredPreviewMode = mode
                    } else if hoveredPreviewMode == mode {
                        hoveredPreviewMode = nil
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
    }

    private var selectedDocumentPreviewMode: DocumentPreviewMode {
        guard let document = model.activeDocument else { return .editor }
        return documentPreviewModes[document.id] ?? (isSVGFile(document) || isHTMLFile(document) ? .split : .editor)
    }

    private func selectDocumentPreviewMode(_ mode: DocumentPreviewMode) {
        guard let document = model.activeDocument else { return }
        documentPreviewModes[document.id] = mode
    }

    private func isSVGFile(_ document: EditorDocument) -> Bool {
        document.url.pathExtension.lowercased() == "svg"
    }

    private func isMarkdownFile(_ document: EditorDocument) -> Bool {
        ["md", "markdown"].contains(document.url.pathExtension.lowercased())
    }

    private func isHTMLFile(_ document: EditorDocument) -> Bool {
        ["html", "htm"].contains(document.url.pathExtension.lowercased())
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            editorTabs
            LitheToolWindowHeaderDivider()

            if model.isRepositoryDiffSelected {
                if let feature = model.gitFeatureIfActive, let context = feature.selectedGitCommitDiffContext {
                    GitCommitDiffReviewView(feature: feature, context: context,
                        onClose: { model.closeGitCommitDiff() },
                        onOpenFile: { model.openFile(context.url) },
                        onOpenCommitDiff: { model.showGitCommitDiff(for: $0) },
                        fontFamily: settings.editorFontFamily)
                } else {
                    Text("Select a changed file in Git Log")
                        .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.activeEditorTerminalSession == nil,
               model.activeMediaDocument == nil,
               let splitDocumentID,
               let splitDocument = model.openDocuments.first(where: { $0.id == splitDocumentID }) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Text(splitDocument.displayName).font(LitheTheme.uiFont(size: 11))
                        Button("Close split") { self.splitDocumentID = nil }.buttonStyle(.litheNoPress)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    MonacoWorkbenchEditor(document: model.activeDocument ?? splitDocument, secondaryDocument: splitDocument)
                }
            } else {
                externalConflictBanner
                activeEditor
            }
        }
    }

    private func editorTabContextMenu(
        for document: EditorDocument,
        at index: Int
    ) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = [
            .action("Close", action: { model.requestCloseDocument(document) }),
            .action(
                "Open in Right Split",
                isEnabled: model.openDocuments.count >= 2,
                action: { splitDocumentID = document.id }
            ),
            .action(
                "Close Other Tabs",
                isEnabled: model.openDocuments.count > 1,
                action: {
                    model.requestCloseDocuments(
                        model.openDocuments.filter { $0.id != document.id },
                        preferredDocumentID: document.id
                    )
                }
            ),
            .action(
                "Close Tabs to the Left",
                isEnabled: index > 0,
                action: {
                    model.requestCloseDocuments(
                        Array(model.openDocuments.prefix(index)),
                        preferredDocumentID: document.id
                    )
                }
            ),
            .action(
                "Close Tabs to the Right",
                isEnabled: index < model.openDocuments.count - 1,
                action: {
                    model.requestCloseDocuments(
                        Array(model.openDocuments.dropFirst(index + 1)),
                        preferredDocumentID: document.id
                    )
                }
            ),
            .action(
                "Close Unmodified Tabs",
                action: {
                    model.requestCloseDocuments(
                        model.openDocuments.filter { !$0.isDirty },
                        preferredDocumentID: document.id
                    )
                }
            ),
            .action("Close All Tabs", action: { model.requestCloseDocuments(model.openDocuments) }),
            .separator,
            .submenu("Copy Path / Reference", items: [
                .action("Copy Path", action: { model.copyProjectItemPath(document.url, relative: false) }),
                .action("Copy Relative Path", action: { model.copyProjectItemPath(document.url, relative: true) })
            ])
        ]

        if model.canRevealInProjectTree(document.url) {
            items.append(
                .action("Reveal in Project Tree", action: {
                    model.activeDocumentID = document.id
                    model.revealInProjectTree(document.url)
                })
            )
        }
        items += [
            .action("Show in Finder", action: { model.revealProjectItemInFinder(document.url) }),
            .action("Local History…", action: { model.showLocalHistory(for: document.url) }),
            .separator,
            .action("Rename…", action: { model.requestRenameProjectItem(at: document.url) })
        ]
        return items
    }

    @ViewBuilder
    private var activeEditor: some View {
        if let session = model.activeEditorTerminalSession {
            TerminalSurfaceView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
        } else if let media = model.activeMediaDocument {
            MediaViewerView(media: media)
                .id(media.id)
        } else if let document = model.activeDocument {
            if isSVGFile(document) {
                switch documentPreviewModes[document.id] ?? .split {
                case .editor:
                    editorWithFindBar(document)
                case .split:
                    SVGEditorSplitView(editor: editorWithFindBar(document), document: document)
                case .preview:
                    SVGPreviewView(document: document)
                }
            } else if isMarkdownFile(document) {
                switch documentPreviewModes[document.id] ?? .editor {
                case .editor:
                    editorWithFindBar(document)
                case .split:
                    let scrollPosition = markdownScrollPosition(for: document)
                    HStack(spacing: 0) {
                        editorWithFindBar(document, markdownScrollPosition: scrollPosition)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        MarkdownPreviewView(
                            document: document,
                            scrollPosition: scrollPosition
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .preview:
                    MarkdownPreviewView(document: document)
                }
            } else if isHTMLFile(document) {
                switch documentPreviewModes[document.id] ?? .split {
                case .editor:
                    editorWithFindBar(document)
                case .split:
                    HStack(spacing: 0) {
                        editorWithFindBar(document)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        HTMLPreviewView(document: document)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .preview:
                    HTMLPreviewView(document: document)
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
                FindBarOverlay()
            }
            .overlay(alignment: .topTrailing) {
                EditorSoftWrapToggle()
                    .padding(.top, 8)
                    .padding(.trailing, 10)
            }
    }

    private func codeEditor(
        _ document: EditorDocument,
        markdownScrollPosition: Binding<MarkdownScrollPosition>? = nil
    ) -> some View {
        MonacoWorkbenchEditor(document: document, markdownScrollPosition: markdownScrollPosition)
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
                .font(LitheTheme.uiFont(size: 44, weight: .ultraLight))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Select a file to review")
                .font(LitheTheme.uiFont(size: 15, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Changes from external tools will appear automatically.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
    }

}

private struct EditorTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [EditorTabItem: CGRect] = [:]

    static func reduce(
        value: inout [EditorTabItem: CGRect],
        nextValue: () -> [EditorTabItem: CGRect]
    ) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct EditorTabBarDropDelegate: DropDelegate {
    let setTargeted: (Bool) -> Void
    let updateTarget: (CGPoint) -> Void
    let clearTarget: () -> Void
    let resolveTarget: (CGPoint) -> EditorTabReorderTarget?
    let finish: () -> Void
    let receiveTerminal: @MainActor (UUID, EditorTabReorderTarget?) -> Void

    func dropEntered(info: DropInfo) {
        setTargeted(true)
        updateTarget(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setTargeted(true)
        updateTarget(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
        clearTarget()
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        updateTarget(info.location)
        let terminalProviders = info.itemProviders(for: [TerminalTabDragPayload.type])
        if !terminalProviders.isEmpty {
            let target = resolveTarget(info.location)
            finish()
            return TerminalTabDragPayload.loadSessionID(from: terminalProviders) { sessionID in
                receiveTerminal(sessionID, target)
            }
        }
        finish()
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [TerminalTabDragPayload.type]).isEmpty
    }
}

private struct EditorTabDropDelegate: DropDelegate {
    let draggedItem: EditorTabItem?
    let targetDocumentID: UUID
    let targetWidth: CGFloat
    let dragSessionID: UUID?
    let dropTargetRevision: UInt
    let updateTarget: (EditorTabDropTarget, UUID?, UInt, Bool) -> Void
    let clearTarget: (UUID, UUID?, UInt) -> Void
    let updateTerminalTarget: (EditorTabReorderTarget) -> Void
    let clearTerminalTarget: (EditorTabItem) -> Void
    let resolveTerminalSide: (EditorTabDropSide) -> EditorTabDropSide
    let finish: () -> Void
    let receiveTerminal: @MainActor (UUID, EditorTabDropSide) -> Void

    func dropEntered(info: DropInfo) {
        updateTerminalTargetIfNeeded(using: info)
        updateTargetIfNeeded(using: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTerminalTargetIfNeeded(using: info)
        updateTargetIfNeeded(using: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if draggedItem == nil,
           !info.itemProviders(for: [TerminalTabDragPayload.type]).isEmpty {
            clearTerminalTarget(.document(targetDocumentID))
        }
        guard !info.itemProviders(for: [EditorTabDragPayload.type]).isEmpty else { return }
        clearTarget(targetDocumentID, dragSessionID, dropTargetRevision)
    }

    func performDrop(info: DropInfo) -> Bool {
        if draggedItem != nil,
           !info.itemProviders(for: [EditorTabDragPayload.type]).isEmpty {
            updateTargetIfNeeded(using: info, settlesDrop: true)
            finish()
            return true
        }
        let terminalProviders = info.itemProviders(for: [TerminalTabDragPayload.type])
        if !terminalProviders.isEmpty {
            let side = resolveTerminalSide(
                EditorTabDropGeometry.finalSide(
                    locationX: info.location.x,
                    width: targetWidth
                )
            )
            updateTerminalTarget(
                EditorTabReorderTarget(
                    item: .document(targetDocumentID),
                    side: side
                )
            )
            finish()
            return TerminalTabDragPayload.loadSessionID(from: terminalProviders) { sessionID in
                receiveTerminal(sessionID, side)
            }
        }
        finish()
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [EditorTabDragPayload.type, TerminalTabDragPayload.type]).isEmpty
    }

    private func updateTargetIfNeeded(using info: DropInfo, settlesDrop: Bool = false) {
        guard let draggedItem,
              draggedItem != .document(targetDocumentID),
              !info.itemProviders(for: [EditorTabDragPayload.type]).isEmpty else { return }
        let side: EditorTabDropSide
        if settlesDrop {
            side = EditorTabDropGeometry.finalSide(
                locationX: info.location.x,
                width: targetWidth
            )
        } else {
            guard let hoverSide = EditorTabDropGeometry.hoverSide(
                locationX: info.location.x,
                width: targetWidth
            ) else { return }
            side = hoverSide
        }
        updateTarget(
            EditorTabDropTarget(
                documentID: targetDocumentID,
                side: side
            ),
            dragSessionID,
            dropTargetRevision,
            settlesDrop
        )
    }

    private func updateTerminalTargetIfNeeded(using info: DropInfo) {
        guard draggedItem == nil,
              !info.itemProviders(for: [TerminalTabDragPayload.type]).isEmpty else { return }
        updateTerminalTarget(
            EditorTabReorderTarget(
                item: .document(targetDocumentID),
                side: resolveTerminalSide(
                    EditorTabDropGeometry.finalSide(
                        locationX: info.location.x,
                        width: targetWidth
                    )
                )
            )
        )
    }
}

private struct EditorTerminalTabDropDelegate: DropDelegate {
    let draggedItem: EditorTabItem?
    let targetSessionID: UUID
    let targetWidth: CGFloat
    let moveItemBefore: @MainActor (EditorTabItem) -> Void
    let moveItemAfter: @MainActor (EditorTabItem) -> Void
    let moveTerminalBefore: @MainActor (UUID) -> Void
    let moveTerminalAfter: @MainActor (UUID) -> Void
    let updateTerminalTarget: (EditorTabReorderTarget) -> Void
    let clearTerminalTarget: (EditorTabItem) -> Void
    let resolveTerminalSide: (EditorTabDropSide) -> EditorTabDropSide
    let finish: () -> Void

    func dropEntered(info: DropInfo) {
        updateTerminalTargetIfNeeded(using: info)
        moveItemIfNeeded(using: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTerminalTargetIfNeeded(using: info)
        moveItemIfNeeded(using: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard !info.itemProviders(
            for: [EditorTabDragPayload.type, TerminalTabDragPayload.type]
        ).isEmpty else { return }
        clearTerminalTarget(.terminal(targetSessionID))
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [EditorTabDragPayload.type, TerminalTabDragPayload.type]).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        if draggedItem != nil,
           !info.itemProviders(for: [EditorTabDragPayload.type]).isEmpty {
            moveItemIfNeeded(using: info, settlesDrop: true)
            finish()
            return true
        }
        let terminalProviders = info.itemProviders(for: [TerminalTabDragPayload.type])
        guard !terminalProviders.isEmpty else {
            finish()
            return !info.itemProviders(for: [EditorTabDragPayload.type]).isEmpty
        }
        let side = resolveTerminalSide(
            EditorTabDropGeometry.finalSide(
                locationX: info.location.x,
                width: targetWidth
            )
        )
        updateTerminalTarget(
            EditorTabReorderTarget(
                item: .terminal(targetSessionID),
                side: side
            )
        )
        finish()
        return TerminalTabDragPayload.loadSessionID(from: terminalProviders) { sourceSessionID in
            guard sourceSessionID != targetSessionID else { return }
            if side == .after {
                moveTerminalAfter(sourceSessionID)
            } else {
                moveTerminalBefore(sourceSessionID)
            }
        }
    }

    private func moveItemIfNeeded(using info: DropInfo, settlesDrop: Bool = false) {
        guard let draggedItem,
              draggedItem != .terminal(targetSessionID),
              !info.itemProviders(for: [EditorTabDragPayload.type]).isEmpty else { return }
        let side: EditorTabDropSide
        if settlesDrop {
            side = EditorTabDropGeometry.finalSide(
                locationX: info.location.x,
                width: targetWidth
            )
        } else {
            guard let hoverSide = EditorTabDropGeometry.hoverSide(
                locationX: info.location.x,
                width: targetWidth
            ) else { return }
            side = hoverSide
        }
        updateTerminalTarget(
            EditorTabReorderTarget(
                item: .terminal(targetSessionID),
                side: side
            )
        )
        guard settlesDrop else { return }
        if side == .after {
            moveItemAfter(draggedItem)
        } else {
            moveItemBefore(draggedItem)
        }
    }

    private func updateTerminalTargetIfNeeded(using info: DropInfo) {
        guard draggedItem == nil,
              !info.itemProviders(for: [TerminalTabDragPayload.type]).isEmpty else { return }
        updateTerminalTarget(
            EditorTabReorderTarget(
                item: .terminal(targetSessionID),
                side: resolveTerminalSide(
                    EditorTabDropGeometry.finalSide(
                        locationX: info.location.x,
                        width: targetWidth
                    )
                )
            )
        )
    }
}

private struct EditorTerminalTabTitle: View {
    @ObservedObject var session: TerminalSession
    let fallbackTitle: String

    var body: some View {
        Text(session.processTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle)
            .font(LitheTheme.uiFont(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 240, alignment: .leading)
    }
}

private struct EditorTabDirtyIndicator: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        if document.isDirty {
            Circle()
                .fill(LitheTheme.primaryText)
                .frame(width: 6, height: 6)
        }
    }
}

enum EditorTabMiddleClick {
    static func shouldCloseTab(eventType: NSEvent.EventType, buttonNumber: Int) -> Bool {
        eventType == .otherMouseUp && buttonNumber == 2
    }
}

private struct EditorTabMiddleClickMonitor: NSViewRepresentable {
    var hoveredItem: EditorTabItem?
    var onMiddleClick: (EditorTabItem) -> Void

    func makeNSView(context: Context) -> EditorTabMiddleClickMonitorView {
        let view = EditorTabMiddleClickMonitorView()
        view.hoveredItem = hoveredItem
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: EditorTabMiddleClickMonitorView, context: Context) {
        nsView.hoveredItem = hoveredItem
        nsView.onMiddleClick = onMiddleClick
    }

    static func dismantleNSView(
        _ nsView: EditorTabMiddleClickMonitorView,
        coordinator: ()
    ) {
        nsView.stopMonitoring()
    }
}

private final class EditorTabMiddleClickMonitorView: NSView {
    var hoveredItem: EditorTabItem?
    var onMiddleClick: ((EditorTabItem) -> Void)?
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        startMonitoring()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard EditorTabMiddleClick.shouldCloseTab(
            eventType: event.type,
            buttonNumber: event.buttonNumber
        ),
        let hoveredItem,
        let window,
        event.window === window else {
            return event
        }

        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return event }

        onMiddleClick?(hoveredItem)
        return nil
    }
}

private struct FindBarOverlay: View {
    @EnvironmentObject private var chrome: EditorChromeModel

    var body: some View {
        if chrome.isFindBarVisible {
            FindBarView()
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
