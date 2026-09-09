import SwiftUI
import LitheGitModule
import LitheTerminalModule

private let editorTabCoordinateSpaceName = "lithe.editor-tab-strip"

enum EditorDocumentIconResolver {
    static func kind(
        for url: URL,
        resolvedJavaKind: LitheIconKind?
    ) -> LitheIconKind {
        if url.pathExtension.lowercased() == "java", let resolvedJavaKind {
            return resolvedJavaKind
        }
        return LitheIcons.kind(for: url, isDirectory: false)
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hoveredTabID: UUID?
    @State private var tabDragState = EditorTabDragState.idle
    @State private var tabFrameStore = EditorTabFrameStore()
    @State private var tabDragStartFrames: [EditorTabItem: CGRect] = [:]
    @State private var tabDragOffsetX: CGFloat = 0
    @State private var tabReorderTarget: EditorTabReorderTarget?
    @State private var isTerminalTabBarDropTargeted = false
    @State private var splitDocumentID: UUID?
    @State private var markdownViewModes: [UUID: MarkdownViewMode] = [:]
    @State private var markdownScrollPositions: [UUID: MarkdownScrollPosition] = [:]
    @State private var editorViewportStore = EditorViewportStore()
    @State private var hoveredMarkdownMode: MarkdownViewMode?
    @State private var resolvedJavaDocumentIconKinds: [String: LitheIconKind] = [:]

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("EditorAreaView")
        ZStack(alignment: .top) {
            Group {
                if model.workbenchFeature.selectedSidebar == .database {
                    if model.isDatabaseModuleActive {
                        DatabaseWorkspaceView()
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
                        }
                    )
                } else if let feature = model.gitFeatureIfActive,
                          let commitDiff = feature.selectedGitCommitDiffContext {
                    GitCommitDiffReviewView(feature: feature, context: commitDiff)
                } else if let feature = model.gitFeatureIfActive,
                          let selectedChange = feature.selectedChange {
                    DiffReviewView(feature: feature, change: selectedChange)
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
        .onChange(of: model.openDocuments.map(\.id)) { ids in
            if let splitDocumentID, !ids.contains(splitDocumentID) {
                self.splitDocumentID = nil
            }
            markdownViewModes = markdownViewModes.filter { ids.contains($0.key) }
            markdownScrollPositions = markdownScrollPositions.filter { ids.contains($0.key) }
            editorViewportStore.retain(documentIDs: Set(ids))
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
               model.activeEditorTerminalSession == nil,
               isMarkdownFile(document),
               splitDocumentID == nil {
                markdownModePicker
            }
        }
        .frame(minHeight: LitheTheme.Metrics.tabHeight, alignment: .top)
        .contentShape(Rectangle())
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
                .frame(height: LitheTheme.Metrics.tabHeight)
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
        .animation(tabAnimation, value: model.editorTabItems)
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
        ForEach(model.editorTabItems) { item in
            switch item {
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
    }

    private func editorTab(_ document: EditorDocument, at index: Int) -> some View {
        let tabItem = EditorTabItem.document(document.id)
        let dropSide: EditorTabDropSide? = {
            if tabReorderTarget?.item == tabItem {
                return tabReorderTarget?.side
            }
            guard tabDragState.dropTarget?.documentID == document.id else { return nil }
            return tabDragState.dropTarget?.side
        }()
        let isDragged = tabDragState.draggedItem == tabItem
        let dragSessionID = tabDragState.sessionID
        let dropTargetRevision = tabDragState.dropTargetRevision

        return ZStack(alignment: .leading) {
            if settings.editorTabLayoutMode == .multipleRows {
                editorTabContent(document, dropSide: dropSide)
                    .frame(minWidth: EditorTabFlowLayout.minimumItemWidth, alignment: .leading)
            } else {
                editorTabContent(document, dropSide: dropSide)
            }
        }
        .contentShape(Rectangle())
        .litheContextMenu {
            editorTabContextMenu(for: document, at: index)
        }
        .onHover { isHovering in
            hoveredTabID = isHovering ? document.id : nil
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
                                    withAnimation(tabAnimation) {
                                        tabDragState.updateTarget(target)
                                    }
                                }
                                guard settlesDrop else { return }
                                withAnimation(tabAnimation) {
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
                                }
                            },
                            clearTarget: { targetDocumentID, sessionID, revision in
                                guard tabDragState.sessionID == sessionID,
                                      tabDragState.dropTargetRevision == revision,
                                      tabDragState.dropTarget?.documentID == targetDocumentID else { return }
                                withAnimation(tabAnimation) {
                                    _ = tabDragState.clearTarget(
                                        documentID: targetDocumentID,
                                        sessionID: sessionID,
                                        revision: revision
                                    )
                                }
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
        .opacity(isDragged ? 0.92 : 1)
        .scaleEffect(isDragged ? 0.99 : 1)
        .offset(x: isDragged ? tabDragOffsetX : 0)
        .zIndex(isDragged ? 1 : 0)
        .animation(tabAnimation, value: isDragged)
    }

    private func editorMediaTab(_ media: MediaDocument) -> some View {
        let isActive = model.activeEditorTerminalSession == nil
            && model.activeMediaDocumentID == media.id
        let tabItem = EditorTabItem.media(media.id)
        let isDragged = tabDragState.draggedItem == tabItem
        let dropSide = tabReorderTarget?.item == tabItem ? tabReorderTarget?.side : nil

        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: media.kind == .image ? "photo" : "film")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(media.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.leading, 11)
            .frame(height: LitheTheme.Metrics.tabHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.selectMediaDocument(media) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(media.displayName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectMediaDocument(media) }
            .gesture(horizontalTabDragGesture(for: tabItem))
            .lithePointer()

            Button {
                model.closeMediaDocument(media)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .litheRowHover(cornerRadius: 10)
            }
            .buttonStyle(LitheTreeRowButtonStyle())
            .lithePointer()
            .foregroundStyle(LitheTheme.secondaryText)
            .opacity(isActive || hoveredTabID == media.id ? 1 : 0)
            .allowsHitTesting(isActive || hoveredTabID == media.id)
            .padding(.trailing, 4)
        }
        .onHover { isHovering in
            hoveredTabID = isHovering ? media.id : nil
        }
        .background(
            isActive
                ? LitheTheme.activeTabBackground
                : (dropSide == nil
                    ? LitheTheme.inactiveTabBackground
                    : LitheTheme.accent.opacity(0.13))
        )
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(LitheTheme.accent).frame(height: 2) }
        }
        .overlay(alignment: .leading) {
            if dropSide == .some(.before) {
                tabDropInsertionIndicator.padding(.vertical, 5)
            }
        }
        .overlay(alignment: .trailing) {
            if dropSide == .some(.after) {
                tabDropInsertionIndicator.padding(.vertical, 5)
            }
        }
        .background { editorTabFrameReader(for: tabItem) }
        .opacity(isDragged ? 0.92 : 1)
        .scaleEffect(isDragged ? 0.99 : 1)
        .offset(x: isDragged ? tabDragOffsetX : 0)
        .zIndex(isDragged ? 1 : 0)
        .animation(tabAnimation, value: isDragged)
    }

    private func editorTerminalTab(_ session: TerminalSession) -> some View {
        let isActive = model.activeEditorTerminalSession?.id == session.id
        let tabItem = EditorTabItem.terminal(session.id)
        let isDragged = tabDragState.draggedItem == tabItem
        let dropSide = tabReorderTarget?.item == tabItem ? tabReorderTarget?.side : nil

        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? LitheTheme.accent : LitheTheme.secondaryText)
                EditorTerminalTabTitle(
                    session: session,
                    fallbackTitle: model.terminalTitle(for: session)
                )
            }
            .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .padding(.leading, 11)
            .frame(height: LitheTheme.Metrics.tabHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectEditorTerminalSession(session)
                session.focus()
            }
            // Keep a compact native marker for cross-container drops without
            // bringing back the free-floating tab card. The clipped tab strip
            // provides the horizontal snap feedback.
            .onDrag {
                TerminalTabDragPayload.provider(for: session.id)
            } preview: {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
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

            Button {
                model.requestCloseTerminalSession(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .litheRowHover(cornerRadius: 10)
            }
            .buttonStyle(LitheTreeRowButtonStyle())
            .lithePointer()
            .foregroundStyle(LitheTheme.secondaryText)
            .opacity(isActive || hoveredTabID == session.id ? 1 : 0)
            .allowsHitTesting(isActive || hoveredTabID == session.id)
            .padding(.trailing, 4)
        }
        .background(
            isActive
                ? LitheTheme.activeTabBackground
                : (dropSide == nil
                    ? LitheTheme.inactiveTabBackground
                    : LitheTheme.accent.opacity(0.13))
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(LitheTheme.accent).frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            if dropSide == .some(.before) {
                tabDropInsertionIndicator
                    .padding(.vertical, 5)
            }
        }
        .overlay(alignment: .trailing) {
            if dropSide == .some(.after) {
                tabDropInsertionIndicator
                    .padding(.vertical, 5)
            }
        }
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
            hoveredTabID = isHovering ? session.id : nil
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
        .opacity(isDragged ? 0.92 : 1)
        .scaleEffect(isDragged ? 0.99 : 1)
        .offset(x: isDragged ? tabDragOffsetX : 0)
        .zIndex(isDragged ? 1 : 0)
        .animation(tabAnimation, value: isDragged)
    }

    private func editorTabContent(
        _ document: EditorDocument,
        dropSide: EditorTabDropSide? = nil
    ) -> some View {
        let isActive = model.activeEditorTerminalSession == nil
            && model.activeDocumentID == document.id

        return HStack(spacing: 0) {
            editorDocumentTabDragSource(document, isActive: isActive)

            Button {
                model.requestCloseDocument(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .litheRowHover(cornerRadius: 10)
            }
            .buttonStyle(LitheTreeRowButtonStyle())
            .lithePointer()
            .foregroundStyle(LitheTheme.secondaryText)
            .opacity(isActive || hoveredTabID == document.id ? 1 : 0)
            .allowsHitTesting(isActive || hoveredTabID == document.id)
            .padding(.trailing, 4)
        }
        .background(
            isActive
                ? LitheTheme.activeTabBackground
                : (dropSide == nil
                    ? LitheTheme.inactiveTabBackground
                    : LitheTheme.accent.opacity(0.13))
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(LitheTheme.accent).frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            if dropSide == .some(.before) {
                tabDropInsertionIndicator
                    .padding(.vertical, 5)
            }
        }
        .overlay(alignment: .trailing) {
            if dropSide == .some(.after) {
                tabDropInsertionIndicator
                    .padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder
    private func editorDocumentTabDragSource(
        _ document: EditorDocument,
        isActive: Bool
    ) -> some View {
        let label = HStack(spacing: 7) {
            editorDocumentIcon(document, size: 13)
            editorTabTitle(document)
            EditorTabDirtyIndicator(document: document)
        }
        .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .padding(.leading, 11)
        .frame(height: LitheTheme.Metrics.tabHeight)
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
        .lithePointer()

        if settings.editorTabLayoutMode == .multipleRows {
            // Native dragging carries the tab between flow-layout rows. The
            // custom single-line gesture intentionally remains horizontal.
            label
                .contentShape(
                    .dragPreview,
                    RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                )
                .onDrag {
                    beginTabDrag(.document(document.id))
                    return EditorTabDragPayload.provider(for: document.id)
                } preview: {
                    editorTabDragPreview(document)
                }
        } else {
            // Keep the drag source on a plain view. On macOS a nested Button
            // can win the mouse gesture before a parent drag gesture starts.
            label.highPriorityGesture(
                horizontalTabDragGesture(for: .document(document.id))
            )
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

    private var tabDropInsertionIndicator: some View {
        Capsule()
            .fill(LitheTheme.accent)
            .frame(width: 3)
            .shadow(color: LitheTheme.accent.opacity(0.7), radius: 4)
            .transition(.opacity.combined(with: .scale))
    }

    private func editorTabDragPreview(_ document: EditorDocument) -> some View {
        HStack(spacing: 7) {
            editorDocumentIcon(document, size: 13)
                .foregroundStyle(LitheTheme.accent)

            Text(document.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)

            if document.isDirty {
                Circle()
                    .fill(LitheTheme.primaryText)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: LitheTheme.Metrics.tabHeight, alignment: .leading)
        .background(LitheTheme.activeTabBackground)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
        .shadow(color: .black.opacity(0.42), radius: 10, y: 6)
        .compositingGroup()
    }

    private var tabAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .interactiveSpring(response: 0.22, dampingFraction: 0.86, blendDuration: 0.10)
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

    private func horizontalTabDragGesture(for item: EditorTabItem) -> some Gesture {
        DragGesture(
            minimumDistance: 8,
            coordinateSpace: .named(editorTabCoordinateSpaceName)
        )
        .onChanged { value in
            if tabDragState.draggedItem != item {
                beginTabDrag(item)
            }
            updateHorizontalTabDrag(item, translationX: value.translation.width)
        }
        .onEnded { value in
            finishHorizontalTabDrag(item, translationX: value.translation.width)
        }
    }

    private func beginTabDrag(_ item: EditorTabItem) {
        tabDragStartFrames = tabFrameStore.frames
        tabDragOffsetX = 0
        tabReorderTarget = nil
        withAnimation(tabAnimation) {
            tabDragState.begin(item: item)
        }
    }

    private func updateHorizontalTabDrag(
        _ item: EditorTabItem,
        translationX: CGFloat
    ) {
        guard tabDragState.draggedItem == item,
              let plan = horizontalTabDragPlan(for: item, translationX: translationX) else { return }
        tabDragOffsetX = plan.offset
        guard tabReorderTarget != plan.target else { return }
        withAnimation(tabAnimation) {
            tabReorderTarget = plan.target
        }
    }

    private func finishHorizontalTabDrag(
        _ item: EditorTabItem,
        translationX: CGFloat
    ) {
        guard tabDragState.draggedItem == item else {
            finishTabDrag()
            return
        }
        let target = horizontalTabDragPlan(for: item, translationX: translationX)?.target
        withAnimation(tabAnimation) {
            if let target {
                if target.side == .after {
                    model.moveEditorTab(item, after: target.item)
                } else {
                    model.moveEditorTab(item, before: target.item)
                }
            }
            tabDragOffsetX = 0
            tabReorderTarget = nil
            tabDragState.finish()
        }
        tabDragStartFrames = [:]
    }

    private func horizontalTabDragPlan(
        for item: EditorTabItem,
        translationX: CGFloat
    ) -> (offset: CGFloat, target: EditorTabReorderTarget?)? {
        guard let sourceFrame = tabDragStartFrames[item] else { return nil }
        let rowFrames = tabDragStartFrames.filter { _, frame in
            frame.maxY > sourceFrame.minY && frame.minY < sourceFrame.maxY
        }
        guard let rowMinX = rowFrames.values.map(\.minX).min(),
              let rowMaxX = rowFrames.values.map(\.maxX).max() else { return nil }

        let offset = min(
            max(translationX, rowMinX - sourceFrame.minX),
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

        return (offset, target)
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
        withAnimation(tabAnimation) {
            tabReorderTarget = target
        }
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
        withAnimation(tabAnimation) {
            tabReorderTarget = nil
        }
    }

    private func finishTabDrag() {
        guard tabDragState != .idle
            || tabReorderTarget != nil
            || tabDragOffsetX != 0 else { return }
        withAnimation(tabAnimation) {
            tabDragOffsetX = 0
            tabReorderTarget = nil
            tabDragState.finish()
        }
        tabDragStartFrames = [:]
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

            if model.activeEditorTerminalSession == nil,
               model.activeMediaDocument == nil,
               let splitDocumentID,
               let splitDocument = model.openDocuments.first(where: { $0.id == splitDocumentID }) {
                HStack(spacing: 0) {
                    editorPane(model.activeDocument)
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
                    editorDocumentIcon(document, size: 13)
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
            }

            if let document {
                CodeEditorView(
                    document: document,
                    shouldFocus: !showsHeader && document.id == model.activeDocumentID,
                    viewportStore: editorViewportStore
                )
                    .id(document.id)
                    .clipped()
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editorDocumentIcon(
        _ document: EditorDocument,
        size: CGFloat
    ) -> some View {
        let path = document.url.standardizedFileURL.path
        let resolvedKind = resolvedJavaDocumentIconKinds[path]
        return LitheIcon(
            kind: EditorDocumentIconResolver.kind(
                for: document.url,
                resolvedJavaKind: resolvedKind
            ),
            size: size
        )
        .task(id: path) {
            guard document.url.pathExtension.lowercased() == "java",
                  resolvedKind == nil else { return }
            let kind = await model.javaIconKind(for: document.url)
            guard !Task.isCancelled, let kind else { return }
            resolvedJavaDocumentIconKinds[path] = kind
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
            if isMarkdownFile(document) {
                switch markdownViewModes[document.id] ?? .editor {
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
    }

    private func codeEditor(
        _ document: EditorDocument,
        markdownScrollPosition: Binding<MarkdownScrollPosition>? = nil
    ) -> some View {
        CodeEditorView(
            document: document,
            shouldFocus: true,
            markdownScrollPosition: markdownScrollPosition,
            viewportStore: editorViewportStore
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
            .font(.system(size: 12.5))
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

private struct FindBarOverlay: View {
    @EnvironmentObject private var chrome: EditorChromeModel

    var body: some View {
        if chrome.isFindBarVisible {
            FindBarView()
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
