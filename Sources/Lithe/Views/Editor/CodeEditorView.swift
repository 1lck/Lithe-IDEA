import AppKit
import SwiftUI
import LitheGitModule

fileprivate struct CodeEditorPalette {
    let isDark: Bool
    let theme: AppColorTheme

    static let dark = CodeEditorPalette(isDark: true, theme: .lithe)

    var background: NSColor { themeColor(.editor) }
    var gutterBackground: NSColor { themeColor(.editor) }
    var gutterDivider: NSColor {
        color(
            light: (0.78, 0.79, 0.81, 1),
            dark: (0.204, 0.212, 0.231, 1)
        )
    }
    var text: NSColor {
        guard theme == .lithe else { return themeColor(.primaryText) }
        return color(
            light: (0, 0, 0, 0.82),
            dark: (0.737, 0.745, 0.769, 1)
        )
    }
    var caret: NSColor { themeColor(.primaryText) }
    var selection: NSColor { themeColor(.accent).withAlphaComponent(isDark ? 0.42 : 0.24) }
    var selectionText: NSColor { themeColor(.primaryText) }
    var currentLine: NSColor { color(light: (0, 0, 0, 0.035), dark: (1, 1, 1, 0.035)) }
    var bracket: NSColor { color(light: (0.18, 0.43, 0.79, 0.19), dark: (0.72, 0.72, 0.72, 0.22)) }
    var symbol: NSColor { color(light: (0.18, 0.43, 0.79, 0.11), dark: (0.68, 0.68, 0.68, 0.14)) }
    var guide: NSColor { themeColor(.guide) }
    var activeGuide: NSColor { themeColor(.activeGuide) }
    var unusedCode: NSColor { color(light: (0.48, 0.49, 0.52, 1), dark: (0.48, 0.48, 0.48, 1)) }
    var link: NSColor { themeColor(.accent) }
    var lineNumber: NSColor { color(light: (0.43, 0.45, 0.49, 1), dark: (0.34, 0.34, 0.34, 1)) }
    var foldHover: NSColor { color(light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.07)) }
    var foldIndicator: NSColor { color(light: (0.28, 0.30, 0.34, 0.58), dark: (0.62, 0.62, 0.62, 0.46)) }
    var foldIndicatorHover: NSColor { color(light: (0.12, 0.14, 0.17, 0.90), dark: (0.86, 0.86, 0.86, 0.96)) }
    var blameText: NSColor { color(light: (0.38, 0.40, 0.44, 1), dark: (0.53, 0.53, 0.53, 1)) }
    var gitAdded: NSColor { color(light: (0.15, 0.62, 0.31, 1), dark: (0.31, 0.78, 0.45, 1)) }
    var gitModified: NSColor { color(light: (0.16, 0.48, 0.86, 1), dark: (0.31, 0.64, 0.96, 1)) }
    var gitDeleted: NSColor { color(light: (0.82, 0.22, 0.25, 1), dark: (0.94, 0.34, 0.37, 1)) }

    var keyword: NSColor { themeColor(.skill) }
    var annotation: NSColor { themeColor(.warning) }
    var type: NSColor { themeColor(.accent) }
    var number: NSColor { themeColor(.warning) }
    var string: NSColor { themeColor(.success) }
    var comment: NSColor { themeColor(.secondaryText) }

    private func themeColor(_ token: LitheTheme.ResolvedColorToken) -> NSColor {
        LitheTheme.nsColor(token, theme: theme, isDark: isDark)
    }

    private func color(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        let components = isDark ? dark : light
        return NSColor(
            srgbRed: components.0,
            green: components.1,
            blue: components.2,
            alpha: components.3
        )
    }
}

private enum EditorLayoutMetrics {
    static let standardGutterWidth: CGFloat = 45
    static let leadingInset: CGFloat = 0
    static let lineFragmentPadding: CGFloat = 4
    static let caretWidth: CGFloat = 2
}

struct EditorViewportState: Equatable {
    var selectionLocation = 0
    var selectionLength = 0
    var verticalScrollOffset: CGFloat = 0
}

@MainActor
final class EditorViewportStore {
    private var states: [UUID: EditorViewportState] = [:]

    func state(for documentID: UUID) -> EditorViewportState {
        states[documentID] ?? EditorViewportState()
    }

    func updateSelection(_ selection: NSRange, for documentID: UUID) {
        guard selection.location != NSNotFound else { return }
        var state = state(for: documentID)
        state.selectionLocation = selection.location
        state.selectionLength = selection.length
        states[documentID] = state
    }

    func updateScrollOffset(_ offset: CGFloat, for documentID: UUID) {
        var state = state(for: documentID)
        state.verticalScrollOffset = offset
        states[documentID] = state
    }

    func retain(documentIDs: Set<UUID>) {
        states = states.filter { documentIDs.contains($0.key) }
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var chrome: EditorChromeModel
    @EnvironmentObject private var diagnosticsStore: EditorDiagnosticsStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var document: EditorDocument
    var debugService: JavaDebugFeatureModel?
    var shouldFocus = true
    var markdownScrollPosition: Binding<MarkdownScrollPosition>? = nil
    let viewportStore: EditorViewportStore

    func makeCoordinator() -> Coordinator {
        Coordinator(
            document: document,
            model: model,
            debugService: debugService,
            markdownScrollPosition: markdownScrollPosition,
            viewportStore: viewportStore
        )
    }

    static func dismantleNSView(_ nsView: EditorContainerView, coordinator: Coordinator) {
        coordinator.persistViewport()
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let palette = CodeEditorPalette(isDark: colorScheme == .dark, theme: settings.colorTheme)
        let container = EditorContainerView()
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.background
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true

        let gutter = LineNumberGutterView(frame: .zero)
        gutter.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        let gutterWidthConstraint = gutter.widthAnchor.constraint(
            equalToConstant: EditorLayoutMetrics.standardGutterWidth
        )
        gutterWidthConstraint.isActive = true

        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = textView
        textView.string = document.text
        textView.rebuildLineIndex()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: EditorLayoutMetrics.leadingInset, height: 0)
        textView.textContainer?.lineFragmentPadding = EditorLayoutMetrics.lineFragmentPadding
        textView.font = LitheTheme.editorFont(size: settings.editorFontSize)
        textView.defaultParagraphStyle = LitheTheme.editorParagraphStyle
        textView.indentationWidth = settings.tabWidth
        textView.applyAppearance(palette)
        textView.isEditable = !document.isReadOnly
        textView.isSelectable = true
        textView.onWindowAttached = { [weak coordinator = context.coordinator] in
            coordinator?.requestInitialFocusIfNeeded()
        }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.languageServerFeatures = model.languageToolingSessionsIfActive?.features(for: document.url) ?? []
        textView.isLanguageNavigationEnabled = !textView.languageServerFeatures.intersection([
            .definition, .references, .implementation
        ]).isEmpty
        textView.onNavigateToSymbol = { [weak model] line, utf16Column in
            model?.navigateToSymbol(line: line, utf16Column: utf16Column, in: document.url)
        }
        textView.onGoToDefinition = { [weak model] in model?.goToDefinition() }
        textView.onGoToImplementation = { [weak model] in model?.goToImplementation() }
        textView.onFindUsages = { [weak model] in model?.findReferences() }
        textView.onFindRequested = { [weak model] in model?.showFindBar() }
        textView.onFindNextRequested = { [weak model] in model?.navigateFind(offset: 1) }
        textView.onFindPreviousRequested = { [weak model] in model?.navigateFind(offset: -1) }
        textView.onFindStateChange = { [weak coordinator = context.coordinator] index, count in
            coordinator?.scheduleFindStateUpdate(currentIndex: index, count: count)
        }
        textView.isLanguageIntelligenceEnabled = !textView.languageServerFeatures.intersection([
            .hover, .completion, .rename, .formatting, .codeActions
        ]).isEmpty
        textView.onQuickDocumentation = { [weak model, weak textView] line, column in
            model?.requestLanguageHover(line: line, utf16Column: column) { [weak textView] hover in
                guard let textView else { return }
                if let hover {
                    textView.presentLanguageHover(hover)
                } else {
                    model?.showNotification("No documentation is available for this symbol")
                }
            }
        }
        textView.onCompletionRequested = { [weak model, weak textView] line, column in
            model?.requestLanguageCompletions(line: line, utf16Column: column) { [weak textView] items in
                textView?.presentLanguageCompletions(items)
            }
        }
        textView.onCompletionSelected = { [weak model] item, range in
            model?.applyLanguageCompletion(item, fallbackRange: range)
        }
        textView.onRenameRequested = { [weak model] line, column, newName in
            model?.requestLanguageRename(line: line, utf16Column: column, newName: newName)
        }
        textView.onFormatRequested = { [weak model] in model?.requestLanguageFormatting() }
        textView.onCodeActionsRequested = { [weak model, weak textView] line, column in
            model?.requestLanguageCodeActions(line: line, utf16Column: column) { [weak textView, weak model] actions in
                textView?.presentLanguageCodeActions(actions) { action in model?.applyLanguageCodeAction(action) }
            }
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] in
            coordinator?.pasteMarkdownImage() ?? false
        }
        textView.onTerminalTabDrop = { [weak coordinator = context.coordinator] sessionID in
            coordinator?.moveTerminalToEditor(sessionID) ?? false
        }

        scrollView.documentView = textView
        gutter.attach(textView: textView, scrollView: scrollView)
        gutter.applyAppearance(palette)
        context.coordinator.attachMarkdownScrollSync(to: scrollView)
        context.coordinator.attachViewportTracking(to: scrollView)

        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        textView.onCaretPresentationChanged = { [weak gutter] in
            gutter?.needsDisplay = true
        }
        context.coordinator.container = container
        context.coordinator.attachMarkdownImagePasteMonitor(to: scrollView)
        context.coordinator.codeVisionOverlay = CodeVisionOverlayController(textView: textView)
        context.coordinator.inlayHintOverlay = JavaInlayHintOverlayController(textView: textView)
        context.coordinator.isDarkAppearance = palette.isDark
        context.coordinator.colorTheme = settings.colorTheme
        context.coordinator.highlight()
        textView.updateCaretDecorations()
        context.coordinator.scheduleFoldRefresh(useDefaultImportFold: true)
        context.coordinator.scheduleCaretUpdate()
        container.scrollView = scrollView
        container.gutter = gutter
        container.gutterWidthConstraint = gutterWidthConstraint
        context.coordinator.updateCodeVisionAndBlame()
        context.coordinator.updateGitLineChanges()
        context.coordinator.updateDiagnostics()
        context.coordinator.shouldFocus = shouldFocus
        context.coordinator.requestInitialFocusIfNeeded()
        context.coordinator.restoreViewportWhenReady()
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let textView = container.scrollView?.documentView as? NSTextView else { return }
        let palette = CodeEditorPalette(isDark: colorScheme == .dark, theme: settings.colorTheme)
        let appearanceChanged = context.coordinator.isDarkAppearance != palette.isDark
            || context.coordinator.colorTheme != settings.colorTheme
        context.coordinator.document = document
        context.coordinator.model = model
        context.coordinator.debugService = debugService
        context.coordinator.shouldFocus = shouldFocus
        context.coordinator.markdownScrollPosition = markdownScrollPosition
        if let scrollView = container.scrollView {
            if appearanceChanged {
                scrollView.backgroundColor = palette.background
            }
            context.coordinator.attachMarkdownScrollSync(to: scrollView)
            context.coordinator.attachMarkdownImagePasteMonitor(to: scrollView)
            context.coordinator.attachViewportTracking(to: scrollView)
        }
        context.coordinator.isDarkAppearance = palette.isDark
        context.coordinator.colorTheme = settings.colorTheme
        context.coordinator.requestInitialFocusIfNeeded()

        let languageFeatures = model.languageToolingSessionsIfActive?.features(for: document.url) ?? []
        let fontSize = settings.editorFontSize
        let tabWidth = settings.tabWidth
        let chromeChanged = context.coordinator.applyEditorChromeIfNeeded(
            fontSize: fontSize,
            tabWidth: tabWidth,
            languageFeatures: languageFeatures,
            isReadOnly: document.isReadOnly,
            palette: palette,
            textView: textView,
            gutter: container.gutter
        )

        // Keep IME marked text (for example, an active Chinese pinyin
        // composition) in the NSTextView until the input method commits it.
        var textChanged = false
        if textView.string != document.text,
           !textView.hasMarkedText(),
           !context.coordinator.isApplyingEditorChange {
            let selection = textView.selectedRange()
            textView.string = document.text
            (textView as? CodeTextView)?.rebuildLineIndex()
            textView.setSelectedRange(NSRange(location: min(selection.location, document.text.utf16.count), length: 0))
            context.coordinator.resetHighlightCache()
            context.coordinator.highlight()
            (textView as? CodeTextView)?.updateEditorDecorations()
            container.gutter?.needsDisplay = true
            textChanged = true
        }
        if appearanceChanged {
            context.coordinator.resetHighlightCache()
            context.coordinator.highlight()
            (textView as? CodeTextView)?.updateEditorDecorations()
        } else if chromeChanged, !textChanged {
            (textView as? CodeTextView)?.updateEditorDecorations()
        }
        context.coordinator.updateCodeVisionAndBlame()
        context.coordinator.updateGitLineChanges()
        context.coordinator.updateDiagnostics()
        context.coordinator.applyNavigationTargetIfNeeded()
        if let codeTextView = textView as? CodeTextView {
            let findVisible = chrome.isFindBarVisible
            let findQuery = chrome.findBarQuery
            if context.coordinator.lastFindVisible != findVisible
                || context.coordinator.lastFindQuery != findQuery {
                context.coordinator.lastFindVisible = findVisible
                context.coordinator.lastFindQuery = findQuery
                codeTextView.syncFindState(isVisible: findVisible, query: findQuery)
            }
        }
        context.coordinator.applySynchronizedMarkdownScrollIfNeeded(to: container.scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var document: EditorDocument?
        weak var model: AppModel?
        weak var debugService: JavaDebugFeatureModel?
        let fileExtension: String
        weak var textView: NSTextView?
        weak var gutter: LineNumberGutterView?
        weak var container: EditorContainerView?
        var codeVisionOverlay: CodeVisionOverlayController?
        var inlayHintOverlay: JavaInlayHintOverlayController?
        var isApplyingEditorChange = false
        var isDarkAppearance = true
        var colorTheme: AppColorTheme = .lithe
        var shouldFocus = true
        var markdownScrollPosition: Binding<MarkdownScrollPosition>?
        var appliedNavigationTargetID: UUID?
        var foldRegions: [JavaFoldRegion] = []
        var collapsedFoldIDs: Set<String> = []
        var implementationMarkers: [JavaImplementationMarker] = []
        var lastFindVisible = false
        var lastFindQuery = ""
        private var pendingHighlightRange: NSRange?
        private var pendingReplacedRange: NSRange?
        private var pendingReplacement: String?
        private var foldRefreshTask: Task<Void, Never>?
        private var decorationRefreshTask: Task<Void, Never>?
        private var documentChangeTask: Task<Void, Never>?
        private var caretUpdateTask: Task<Void, Never>?
        private var findStateUpdateTask: Task<Void, Never>?
        private var highlightedRanges = HighlightedRangeCache()
        private var appliedFontSize: CGFloat?
        private var appliedTabWidth: Int?
        private var appliedLanguageFeatures: LanguageServerFeatureSet?
        private var appliedReadOnly: Bool?
        private var appliedCodeVisionHints: [JavaCodeVisionHint]?
        private var appliedInlayHints: [JavaInlayHint]?
        private var appliedBlameVisible = false
        private var appliedBlameLines: [GitBlameLine] = []
        private var appliedDebugBreakpointLines = Set<Int>()
        private var appliedGitMarkers: [GitLineChangeMarker]?
        private var appliedDiagnostics: [EditorDiagnostic] = []
        private var markdownImagePasteMonitor: Any?
        private weak var markdownScrollView: NSScrollView?
        private var markdownScrollObserver: NSObjectProtocol?
        private var visibleHighlightTask: Task<Void, Never>?
        private var viewportScrollObserver: NSObjectProtocol?
        private var isApplyingSynchronizedMarkdownScroll = false
        private var isRestoringViewport = true
        private var lastObservedMarkdownScrollRevision: UInt64?
        private var isLoadingGitLineChanges = false
        private let viewportStore: EditorViewportStore

        init(
            document: EditorDocument,
            model: AppModel,
            debugService: JavaDebugFeatureModel?,
            markdownScrollPosition: Binding<MarkdownScrollPosition>?,
            viewportStore: EditorViewportStore
        ) {
            self.document = document
            self.model = model
            self.debugService = debugService
            self.markdownScrollPosition = markdownScrollPosition
            self.viewportStore = viewportStore
            fileExtension = document.url.pathExtension
        }

        deinit {
            foldRefreshTask?.cancel()
            decorationRefreshTask?.cancel()
            documentChangeTask?.cancel()
            caretUpdateTask?.cancel()
            findStateUpdateTask?.cancel()
            visibleHighlightTask?.cancel()
            if let markdownImagePasteMonitor {
                NSEvent.removeMonitor(markdownImagePasteMonitor)
            }
            if let markdownScrollObserver {
                NotificationCenter.default.removeObserver(markdownScrollObserver)
            }
            if let viewportScrollObserver {
                NotificationCenter.default.removeObserver(viewportScrollObserver)
            }
        }

        func attachViewportTracking(to scrollView: NSScrollView) {
            guard viewportScrollObserver == nil else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            viewportScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleVisibleRangeHighlight()
                    guard let scrollView, !self.isRestoringViewport,
                          let document = self.document else { return }
                    self.viewportStore.updateScrollOffset(
                        scrollView.contentView.bounds.minY,
                        for: document.id
                    )
                }
            }
        }

        private func scheduleVisibleRangeHighlight() {
            visibleHighlightTask?.cancel()
            visibleHighlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(24))
                guard !Task.isCancelled else { return }
                self?.highlight()
            }
        }

        func restoreViewportWhenReady() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let document, let textView,
                      let scrollView = textView.enclosingScrollView else { return }
                if let target = self.model?.editorNavigationTarget,
                   target.url.standardizedFileURL == document.url.standardizedFileURL,
                   self.appliedNavigationTargetID == target.id {
                    self.isRestoringViewport = false
                    self.persistViewport()
                    return
                }
                let state = self.viewportStore.state(for: document.id)
                let textLength = (textView.string as NSString).length
                let location = min(state.selectionLocation, textLength)
                let length = min(state.selectionLength, textLength - location)
                textView.setSelectedRange(NSRange(location: location, length: length))
                let maximumOffset = max(
                    0,
                    (scrollView.documentView?.frame.height ?? 0)
                        - scrollView.contentView.bounds.height
                )
                scrollView.contentView.scroll(
                    to: NSPoint(
                        x: scrollView.contentView.bounds.minX,
                        y: min(max(0, state.verticalScrollOffset), maximumOffset)
                    )
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.isRestoringViewport = false
                self.scheduleVisibleRangeHighlight()
                self.scheduleCaretUpdate()
            }
        }

        func persistViewport() {
            guard let document, let textView else { return }
            viewportStore.updateSelection(textView.selectedRange(), for: document.id)
            if let scrollView = textView.enclosingScrollView {
                viewportStore.updateScrollOffset(
                    scrollView.contentView.bounds.minY,
                    for: document.id
                )
            }
        }

        func attachMarkdownImagePasteMonitor(to scrollView: NSScrollView) {
            guard markdownImagePasteMonitor == nil,
                  ["md", "markdown"].contains(fileExtension.lowercased()) else { return }
            markdownImagePasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak scrollView] event in
                let shouldConsume = MainActor.assumeIsolated {
                    guard let self,
                          let scrollView,
                          CodeTextView.isStandardPasteShortcut(event),
                          event.window === scrollView.window,
                          self.model?.activeDocumentID == self.document?.id else {
                        return false
                    }

                    let editorHasFocus = scrollView.window?.firstResponder === self.textView
                    let mouseLocation = scrollView.convert(
                        scrollView.window?.mouseLocationOutsideOfEventStream ?? .zero,
                        from: nil
                    )
                    guard editorHasFocus || scrollView.bounds.contains(mouseLocation) else {
                        return false
                    }
                    return self.pasteMarkdownImage()
                }
                return shouldConsume ? nil : event
            }
        }

        func attachMarkdownScrollSync(to scrollView: NSScrollView) {
            guard markdownScrollPosition != nil, markdownScrollObserver == nil else { return }
            markdownScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            markdownScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportMarkdownEditorScroll()
                }
            }
        }

        func applySynchronizedMarkdownScrollIfNeeded(to scrollView: NSScrollView?) {
            guard let position = markdownScrollPosition?.wrappedValue,
                  position.revision != lastObservedMarkdownScrollRevision else { return }
            lastObservedMarkdownScrollRevision = position.revision
            guard position.source == .preview, let scrollView else { return }

            let contentHeight = Double(scrollView.documentView?.frame.height ?? 0)
            let viewportHeight = Double(scrollView.contentView.bounds.height)
            let y = MarkdownScrollMetrics.offset(
                ratio: position.ratio,
                contentHeight: contentHeight,
                viewportHeight: viewportHeight
            )
            isApplyingSynchronizedMarkdownScroll = true
            scrollView.contentView.scroll(
                to: NSPoint(x: scrollView.contentView.bounds.minX, y: y)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingSynchronizedMarkdownScroll = false
        }

        private func reportMarkdownEditorScroll() {
            guard !isApplyingSynchronizedMarkdownScroll,
                  let scrollView = markdownScrollView,
                  var position = markdownScrollPosition?.wrappedValue else { return }
            let ratio = MarkdownScrollMetrics.ratio(
                offset: Double(scrollView.contentView.bounds.minY),
                contentHeight: Double(scrollView.documentView?.frame.height ?? 0),
                viewportHeight: Double(scrollView.contentView.bounds.height)
            )
            guard position.update(ratio: ratio, source: .editor) else { return }
            lastObservedMarkdownScrollRevision = position.revision
            markdownScrollPosition?.wrappedValue = position
        }

        func requestInitialFocusIfNeeded() {
            guard shouldFocus,
                  let textView,
                  let document,
                  let model,
                  model.activeDocumentID == document.id,
                  !hasRequestedInitialFocus else { return }
            guard let window = textView.window else { return }

            hasRequestedInitialFocus = true
            DispatchQueue.main.async { [weak self, weak textView, weak window] in
                guard let self,
                      let textView,
                      let window,
                      self.shouldFocus,
                      self.model?.activeDocumentID == self.document?.id else { return }
                window.makeFirstResponder(textView)
            }
        }

        private var hasRequestedInitialFocus = false

        func pasteMarkdownImage() -> Bool {
            guard let document, let model, let textView,
                  let source = model.markdownImageFromClipboard() else { return false }
            guard ["md", "markdown"].contains(document.url.pathExtension.lowercased()) else {
                model.showNotification("Images can only be pasted into Markdown documents")
                return true
            }
            guard !document.isReadOnly, textView.isEditable else {
                model.showNotification("This Markdown document is read-only")
                return true
            }

            let originalText = textView.string
            let originalSelection = textView.selectedRange()
            Task { @MainActor [weak self, weak document, weak model] in
                guard let self, let document, let model else { return }
                do {
                    let result = try await model.importMarkdownImage(source, for: document)
                    guard self.document?.id == document.id,
                          let textView = self.textView,
                          textView.isEditable else { return }
                    let currentLength = (textView.string as NSString).length
                    let replacementRange: NSRange
                    if textView.string == originalText,
                       originalSelection.location != NSNotFound,
                       NSMaxRange(originalSelection) <= currentLength {
                        replacementRange = originalSelection
                    } else {
                        let selection = textView.selectedRange()
                        replacementRange = selection.location == NSNotFound
                            ? NSRange(location: currentLength, length: 0)
                            : selection
                    }
                    let insertion = MarkdownImageInsertion.blockText(
                        reference: result.markdownReference,
                        in: textView.string,
                        replacing: replacementRange
                    )
                    textView.insertText(insertion, replacementRange: replacementRange)
                    textView.scrollRangeToVisible(textView.selectedRange())
                    textView.window?.makeFirstResponder(textView)
                    model.showNotification("Saved image to \(result.relativePath)")
                } catch {
                    model.showNotification("Could not paste image: \(error.localizedDescription)")
                }
            }
            return true
        }

        func moveTerminalToEditor(_ sessionID: UUID) -> Bool {
            guard let model,
                  model.terminalSessions.contains(where: { $0.id == sessionID }) else {
                return false
            }
            model.moveTerminalToEditor(sessionID)
            return true
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let inserted = replacementString ?? ""
            pendingReplacement = inserted
            pendingReplacedRange = affectedCharRange
            pendingHighlightRange = NSRange(location: affectedCharRange.location, length: (inserted as NSString).length)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard document?.isReadOnly != true else { return }
            let codeTextView = textView as? CodeTextView
            if let replacedRange = pendingReplacedRange, let replacement = pendingReplacement {
                codeTextView?.applyLineIndexEdit(replacedRange: replacedRange, replacement: replacement)
            } else {
                codeTextView?.rebuildLineIndex()
            }
            isApplyingEditorChange = true
            document?.applyLiveEditorText(textView.string)
            if let document {
                scheduleDocumentChange(document)
            }
            highlight(in: pendingHighlightRange)
            let findReplacedRange = pendingReplacedRange
            let findInsertedLength = pendingHighlightRange?.length ?? 0
            pendingHighlightRange = nil
            pendingReplacedRange = nil
            pendingReplacement = nil
            if let codeTextView,
               let findReplacedRange,
               model?.editorChrome.isFindBarVisible == true,
               let query = model?.editorChrome.findBarQuery,
               !query.isEmpty {
                codeTextView.applyFindEdit(
                    replacedRange: findReplacedRange,
                    insertedLength: findInsertedLength,
                    query: query
                )
                codeTextView.updateCaretDecorations()
            } else if model?.editorChrome.isFindBarVisible == true,
                      !(model?.editorChrome.findBarQuery.isEmpty ?? true) {
                scheduleDecorationRefresh()
            } else {
                codeTextView?.updateCaretDecorations()
                scheduleDecorationRefresh()
            }
            scheduleFoldRefresh()
            gutter?.needsDisplay = true
            isApplyingEditorChange = false
            scheduleCaretUpdate()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Typing already refreshed caret chrome in textDidChange. A second
            // full pass here is what dropped the frame rate into the 30s.
            guard !isApplyingEditorChange else { return }
            if !isRestoringViewport, let document, let textView {
                viewportStore.updateSelection(
                    textView.selectedRange(),
                    for: document.id
                )
            }
            (textView as? CodeTextView)?.updateCaretDecorations()
            textView?.needsDisplay = true
            gutter?.needsDisplay = true
            scheduleCaretUpdate()
        }

        fileprivate func applyEditorChromeIfNeeded(
            fontSize: CGFloat,
            tabWidth: Int,
            languageFeatures: LanguageServerFeatureSet,
            isReadOnly: Bool,
            palette: CodeEditorPalette,
            textView: NSTextView,
            gutter: LineNumberGutterView?
        ) -> Bool {
            var changed = false
            if appliedFontSize != fontSize {
                textView.font = LitheTheme.editorFont(size: fontSize)
                textView.defaultParagraphStyle = LitheTheme.editorParagraphStyle
                appliedFontSize = fontSize
                changed = true
            }
            if let codeTextView = textView as? CodeTextView {
                codeTextView.applyAppearance(palette)
                if appliedTabWidth != tabWidth {
                    codeTextView.indentationWidth = tabWidth
                    appliedTabWidth = tabWidth
                    changed = true
                }
                if appliedLanguageFeatures != languageFeatures {
                    codeTextView.languageServerFeatures = languageFeatures
                    codeTextView.isLanguageNavigationEnabled = !languageFeatures.intersection([
                        .definition, .references, .implementation
                    ]).isEmpty
                    codeTextView.isLanguageIntelligenceEnabled = !languageFeatures.intersection([
                        .hover, .completion, .rename, .formatting, .codeActions
                    ]).isEmpty
                    appliedLanguageFeatures = languageFeatures
                    changed = true
                }
            }
            gutter?.applyAppearance(palette)
            if appliedReadOnly != isReadOnly {
                textView.isEditable = !isReadOnly
                textView.isSelectable = true
                appliedReadOnly = isReadOnly
                changed = true
            }
            return changed
        }

        func highlight(in editedRange: NSRange? = nil) {
            guard let textView, let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let font = textView.font ?? LitheTheme.editorFont(size: 13)
            if let editedRange {
                highlightedRanges.removeAll()
                let target = SyntaxHighlighter.targetRange(
                    for: editedRange,
                    in: textStorage.string as NSString,
                    limit: fullRange
                )
                SyntaxHighlighter.applyExact(
                    to: textStorage,
                    font: font,
                    fileExtension: fileExtension,
                    isDark: isDarkAppearance,
                    range: target
                )
                highlightedRanges.insert(target)
                return
            }
            let visible = (textView as? CodeTextView)?.visibleCharacterRange()
                ?? NSRange(location: 0, length: min(8_192, textStorage.length))
            let target = SyntaxHighlighter.targetRange(
                for: visible,
                in: textStorage.string as NSString,
                limit: fullRange
            )
            for range in highlightedRanges.uncoveredRanges(in: target) {
                SyntaxHighlighter.applyExact(
                    to: textStorage,
                    font: font,
                    fileExtension: fileExtension,
                    isDark: isDarkAppearance,
                    range: range
                )
                highlightedRanges.insert(range)
            }
        }

        func resetHighlightCache() {
            highlightedRanges.removeAll()
        }

        func scheduleFoldRefresh(useDefaultImportFold: Bool = false) {
            foldRefreshTask?.cancel()
            foldRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled,
                      let self,
                      let document = self.document,
                      let textView = self.textView as? CodeTextView else { return }
                guard self.fileExtension.lowercased() == "java", let model = self.model else {
                    self.clearJavaStructure()
                    return
                }
                let documentID = document.id
                let source = textView.string
                let structure = await model.javaStructure(source: source)
                guard !Task.isCancelled,
                      self.document?.id == documentID,
                      self.textView?.string == source else { return }
                self.applyJavaStructure(structure, useDefaultImportFold: useDefaultImportFold)
            }
        }

        func scheduleDecorationRefresh() {
            decorationRefreshTask?.cancel()
            decorationRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let textView = self.textView as? CodeTextView else { return }
                if let model = self.model, model.isFindBarVisible, !model.findBarQuery.isEmpty {
                    textView.updateFindMatches(query: model.findBarQuery)
                } else {
                    textView.updateEditorDecorations()
                }
            }
        }

        func scheduleDocumentChange(_ document: EditorDocument) {
            documentChangeTask?.cancel()
            documentChangeTask = Task { @MainActor [weak self, weak document] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let document else { return }
                self?.model?.documentDidChange(document)
            }
        }

        private func applyJavaStructure(
            _ structure: JavaStructureResult?,
            useDefaultImportFold: Bool
        ) {
            guard let structure else {
                clearJavaStructure()
                return
            }
            foldRegions = structure.foldRegions
            implementationMarkers = structure.implementationMarkers
            let availableIDs = Set(foldRegions.map(\.id))
            collapsedFoldIDs.formIntersection(availableIDs)
            if useDefaultImportFold,
               let imports = foldRegions.first(where: { $0.kind == .imports }) {
                collapsedFoldIDs.insert(imports.id)
            }
            applyFoldState()
        }

        private func clearJavaStructure() {
            if !foldRegions.isEmpty || !collapsedFoldIDs.isEmpty || !implementationMarkers.isEmpty {
                foldRegions = []
                collapsedFoldIDs = []
                implementationMarkers = []
                applyFoldState()
            }
        }

        func toggleFold(_ region: JavaFoldRegion) {
            if collapsedFoldIDs.contains(region.id) {
                collapsedFoldIDs.remove(region.id)
            } else {
                collapsedFoldIDs.insert(region.id)
            }
            applyFoldState()
        }

        private func applyFoldState() {
            (textView as? CodeTextView)?.updateFolds(
                regions: foldRegions,
                collapsedIDs: collapsedFoldIDs,
                onToggle: { [weak self] region in self?.toggleFold(region) }
            )
            gutter?.updateFoldRegions(
                foldRegions,
                collapsedIDs: collapsedFoldIDs,
                onToggle: { [weak self] region in self?.toggleFold(region) }
            )
            // `java.structure` is an explicit local editor fallback. It does
            // not validate markers or own any language-server lifecycle.
            gutter?.updateImplementationMarkers(implementationMarkers) { [weak model, weak document] marker in
                guard let document else { return }
                model?.findJavaImplementations(
                    line: marker.line,
                    utf16Column: marker.utf16Column,
                    in: document.url
                )
            }
        }

        func updateCodeVisionAndBlame() {
            guard let document, let model else { return }
            let url = document.url.standardizedFileURL
            let hints = model.settings.showCodeVision ? model.javaCodeVisionHints[url] ?? [] : []
            if appliedCodeVisionHints != hints {
                appliedCodeVisionHints = hints
                codeVisionOverlay?.update(
                    hints: hints,
                    onUsages: { [weak model] hint in model?.findUsages(for: hint, in: url) },
                    onImplementations: { [weak model] hint in
                        model?.findJavaImplementations(
                            line: hint.line,
                            utf16Column: hint.utf16Column,
                            in: url
                        )
                    },
                    onAuthor: { [weak model] in model?.showBlame(for: url) }
                )
            }
            let inlayHints = model.javaInlayHints[url] ?? []
            if appliedInlayHints != inlayHints {
                appliedInlayHints = inlayHints
                inlayHintOverlay?.update(hints: inlayHints)
            }

            let isBlameVisible = model.blameVisibleURL == url
            let blameLines = model.gitBlameLines[url] ?? []
            let javaBreakpointLines = debugService?.breakpoints.filter {
                $0.fileURL.standardizedFileURL == url
            }.map(\.line) ?? []
            let genericBreakpointLines = (model.genericDebugFeatureIfActive?.breakpoints ?? []).filter {
                $0.fileURL.standardizedFileURL == url
            }.map(\.line)
            let debugBreakpointLines = Set(javaBreakpointLines + genericBreakpointLines)
            if appliedBlameVisible != isBlameVisible
                || appliedBlameLines != blameLines
                || appliedDebugBreakpointLines != debugBreakpointLines {
                appliedBlameVisible = isBlameVisible
                appliedBlameLines = blameLines
                appliedDebugBreakpointLines = debugBreakpointLines
                container?.gutterWidthConstraint?.constant = isBlameVisible
                    ? 224
                    : EditorLayoutMetrics.standardGutterWidth
                gutter?.update(blameLines: blameLines, isVisible: isBlameVisible) { [weak model] blame in
                    Task { await model?.showGitCommit(blame.commitHash) }
                }
                gutter?.updateDebugBreakpointLines(debugBreakpointLines) { [weak model] line in
                    model?.toggleDebugBreakpoint(fileURL: url, line: line)
                }
            }
        }

        func updateGitLineChanges() {
            guard let document, let model, let gutter else { return }
            let url = document.url.standardizedFileURL
            if let markers = model.gitLineChangeMarkers(for: url) {
                isLoadingGitLineChanges = false
                guard appliedGitMarkers != markers else { return }
                appliedGitMarkers = markers
                let change = model.gitChange(for: url)
                gutter.updateGitLineChanges(
                    markers,
                    onShow: { [weak model] marker in
                        Task { await model?.showGitLineChange(marker, for: url) }
                    },
                    onStage: change?.hasWorkingTreeChange == true ? { [weak model] marker in
                        Task { await model?.stageGitLineChange(marker, for: url) }
                    } : nil,
                    onUnstage: change?.isStaged == true && change?.hasWorkingTreeChange == false
                        ? { [weak model] marker in
                            Task { await model?.unstageGitLineChange(marker, for: url) }
                        }
                        : nil,
                    onDiscard: change?.hasWorkingTreeChange == true ? { [weak model] marker in
                        Task { await model?.requestDiscardGitLineChange(marker, for: url) }
                    } : nil
                )
                return
            }

            if appliedGitMarkers != [] {
                appliedGitMarkers = []
                gutter.updateGitLineChanges([], onShow: { _ in })
            }
            guard !isLoadingGitLineChanges else { return }
            isLoadingGitLineChanges = true
            Task { @MainActor [weak self, weak model] in
                await model?.loadGitLineChanges(for: url)
                self?.isLoadingGitLineChanges = false
            }
        }

        func updateDiagnostics() {
            guard let document,
                  let textView = textView as? CodeTextView else { return }
            let diagnostics = model?.editorDiagnosticsStore.diagnostics(for: document.url) ?? []
            guard appliedDiagnostics != diagnostics else { return }
            appliedDiagnostics = diagnostics
            textView.updateDiagnostics(diagnostics)
        }

        func applyNavigationTargetIfNeeded() {
            guard let textView, let document, let target = model?.editorNavigationTarget,
                  target.url.standardizedFileURL == document.url.standardizedFileURL,
                  appliedNavigationTargetID != target.id else { return }
            appliedNavigationTargetID = target.id

            let text = textView.string as NSString
            var lineStart = 0
            var currentLine = 0
            while currentLine < target.line, lineStart < text.length {
                let range = text.lineRange(for: NSRange(location: lineStart, length: 0))
                lineStart = NSMaxRange(range)
                currentLine += 1
            }
            let lineRange = text.lineRange(for: NSRange(location: min(lineStart, text.length), length: 0))
            let location = min(NSMaxRange(lineRange), lineStart + target.utf16Column)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            textView.window?.makeFirstResponder(textView)
            scheduleCaretUpdate()
        }

        func scheduleCaretUpdate() {
            guard let textView, let document else { return }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            let selectedText = selectedText(in: text, range: selection)
            let location = min(selection.location, text.length)
            let line: Int
            let lineStart: Int
            if let codeTextView = textView as? CodeTextView {
                line = codeTextView.lineNumber(at: location, in: text)
                lineStart = codeTextView.characterOffset(forLine: line, in: text)
            } else {
                let prefix = text.substring(to: location) as NSString
                var scannedLine = 0
                var scannedStart = 0
                for index in 0..<prefix.length where prefix.character(at: index) == 10 {
                    scannedLine += 1
                    scannedStart = index + 1
                }
                line = scannedLine
                lineStart = scannedStart
            }
            let caret = EditorCaret(
                url: document.url.standardizedFileURL,
                line: line,
                utf16Column: location - lineStart
            )
            let documentID = document.id
            caretUpdateTask?.cancel()
            caretUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.document?.id == documentID,
                      let textView = self.textView,
                      self.model?.activeDocumentID == documentID
                        || textView.window?.firstResponder === textView else { return }
                self.model?.editorSelectedText = selectedText
                self.model?.editorCaret = caret
            }
        }

        func scheduleFindStateUpdate(currentIndex: Int, count: Int) {
            guard let document else { return }
            let documentID = document.id
            findStateUpdateTask?.cancel()
            findStateUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.document?.id == documentID,
                      let textView = self.textView,
                      self.model?.activeDocumentID == documentID
                        || textView.window?.firstResponder === textView else { return }
                self.model?.updateFindState(currentIndex: currentIndex, count: count)
            }
        }

        /// 只取单行、非空白的选区作为预填词；跨行选择在 IDEA 里也不会填进查询框。
        private func selectedText(in text: NSString, range: NSRange) -> String {
            guard range.length > 0, NSMaxRange(range) <= text.length else {
                return ""
            }
            let selected = text.substring(with: range)
            guard !selected.contains("\n"),
                  !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ""
            }
            return selected
        }
    }
}

private struct TextLineIndex {
    var textLength: Int
    var starts: [Int]

    init(source: NSString) {
        textLength = source.length
        var starts = [0]
        if source.length > 0 {
            for index in 0..<source.length {
                let character = source.character(at: index)
                if character == 10 {
                    starts.append(index + 1)
                } else if character == 13,
                          (index + 1 == source.length || source.character(at: index + 1) != 10) {
                    starts.append(index + 1)
                }
            }
        }
        self.starts = starts
    }

    /// Shift line starts after a single-line insert/delete. Returns false when
    /// the replaced range crossed a line break and the index must be rebuilt.
    mutating func applySingleLineEdit(replacedRange: NSRange, insertedLength: Int) -> Bool {
        let replacedEnd = NSMaxRange(replacedRange)
        if starts.contains(where: { $0 > replacedRange.location && $0 <= replacedEnd }) {
            return false
        }
        let delta = insertedLength - replacedRange.length
        guard delta != 0 else { return true }
        textLength = max(0, textLength + delta)
        for index in starts.indices where starts[index] > replacedRange.location {
            starts[index] += delta
        }
        return true
    }

    var lineCount: Int {
        guard textLength > 0, starts.last == textLength else { return starts.count }
        return max(1, starts.count - 1)
    }

    func characterOffset(forLine line: Int) -> Int {
        starts[min(max(0, line), starts.count - 1)]
    }

    func lineNumber(at location: Int) -> Int {
        let safeLocation = min(max(0, location), textLength)
        var lowerBound = 0
        var upperBound = starts.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if starts[midpoint] <= safeLocation {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(0, lowerBound - 1)
    }

    func lineRange(forLine line: Int) -> NSRange {
        let safeLine = min(max(0, line), starts.count - 1)
        let start = starts[safeLine]
        let end = safeLine + 1 < starts.count ? starts[safeLine + 1] : textLength
        return NSRange(location: start, length: max(0, end - start))
    }
}

final class CodeTextView: NSTextView, NSLayoutManagerDelegate {
    var onCaretPresentationChanged: (() -> Void)?
    var indentationWidth = 4
    var isLanguageNavigationEnabled = false
    var isLanguageIntelligenceEnabled = false
    var languageServerFeatures: LanguageServerFeatureSet = []
    var onWindowAttached: (() -> Void)?
    var onNavigateToSymbol: ((Int, Int) -> Void)?
    var onGoToDefinition: (() -> Void)?
    var onGoToImplementation: (() -> Void)?
    var onFindUsages: (() -> Void)?
    var onFindRequested: (() -> Void)?
    var onFindNextRequested: (() -> Void)?
    var onFindPreviousRequested: (() -> Void)?
    var onFindStateChange: ((Int, Int) -> Void)?
    var onQuickDocumentation: ((Int, Int) -> Void)?
    var onCompletionRequested: ((Int, Int) -> Void)?
    var onCompletionSelected: ((LanguageServerCompletionItem, LanguageServerRange) -> Void)?
    var onRenameRequested: ((Int, Int, String) -> Void)?
    var onFormatRequested: (() -> Void)?
    var onCodeActionsRequested: ((Int, Int) -> Void)?
    var onPasteImage: (() -> Bool)?
    var onTerminalTabDrop: ((UUID) -> Bool)?

    private var findMatchRanges: [NSRange] = []
    private var currentFindMatchIndex = 0
    private var lastReportedFindState: (index: Int, count: Int)?
    private var lastCaretBackgroundRanges: [NSRange] = []
    private var completionItemsByID: [String: LanguageServerCompletionItem] = [:]
    private var languageHoverPopover: NSPopover?

    private var currentLineColor = CodeEditorPalette.dark.currentLine
    private var bracketColor = CodeEditorPalette.dark.bracket
    private var symbolColor = CodeEditorPalette.dark.symbol
    private var guideColor = CodeEditorPalette.dark.guide
    private var activeGuideColor = CodeEditorPalette.dark.activeGuide
    private var unusedCodeColor = CodeEditorPalette.dark.unusedCode
    private var linkColor = CodeEditorPalette.dark.link
    private var appliedDarkAppearance: Bool?
    private var appliedColorTheme: AppColorTheme?
    private var foldRegions: [JavaFoldRegion] = []
    private var collapsedFoldIDs: Set<String> = []
    private var onToggleFold: ((JavaFoldRegion) -> Void)?
    private var diagnostics: [EditorDiagnostic] = []
    private var fadedCodeRanges: [NSRange] = []
    private var linkRange: NSRange?
    private var trackingArea: NSTrackingArea?
    private var hoveredFoldID: String?
    private var lineIndex = TextLineIndex(source: "" as NSString)
    nonisolated(unsafe) private var windowResignObserver: NSObjectProtocol?
    private var caretVisible = true
    private var caretPresentationGeneration = 0

    fileprivate func applyAppearance(_ palette: CodeEditorPalette) {
        guard appliedDarkAppearance != palette.isDark
            || appliedColorTheme != palette.theme else { return }
        appliedDarkAppearance = palette.isDark
        appliedColorTheme = palette.theme
        backgroundColor = palette.background
        textColor = palette.text
        insertionPointColor = palette.caret
        selectedTextAttributes = [
            .backgroundColor: palette.selection,
            .foregroundColor: palette.selectionText
        ]
        currentLineColor = palette.currentLine
        bracketColor = palette.bracket
        symbolColor = palette.symbol
        guideColor = palette.guide
        activeGuideColor = palette.activeGuide
        unusedCodeColor = palette.unusedCode
        linkColor = palette.link
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        if onPasteImage?() == true { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isTerminalTabDrag(sender) else { return super.draggingEntered(sender) }
        return terminalTabDragOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isTerminalTabDrag(sender) else { return super.draggingUpdated(sender) }
        return terminalTabDragOperation(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isTerminalTabDrag(sender) else { return super.prepareForDragOperation(sender) }
        return onTerminalTabDrop != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isTerminalTabDrag(sender) else { return super.performDragOperation(sender) }
        return performTerminalTabDrop(from: sender.draggingPasteboard)
    }

    func performTerminalTabDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let sessionID = TerminalTabDragPayload.sessionID(from: pasteboard),
              let onTerminalTabDrop else { return false }
        return onTerminalTabDrop(sessionID)
    }

    private func isTerminalTabDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(
            from: [TerminalTabDragPayload.pasteboardType]
        ) != nil
    }

    private func terminalTabDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onTerminalTabDrop != nil else { return [] }
        let sourceMask = sender.draggingSourceOperationMask
        if sourceMask.contains(.move) { return .move }
        if sourceMask.contains(.copy) { return .copy }
        return []
    }

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        synchronizeCaretPresentation()
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting flag: Bool
    ) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
        synchronizeCaretPresentation()
    }

    private func synchronizeCaretPresentation() {
        updateCaretDecorations()
        needsDisplay = true
        onCaretPresentationChanged?()
        updateInsertionPointStateAndRestartTimer(true)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        guard restartFlag else { return }
        caretPresentationGeneration &+= 1
        let generation = caretPresentationGeneration
        caretVisible = true
        needsDisplay = true

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.startCaretBlinking(for: generation)
        }
    }

    private func startCaretBlinking(for generation: Int) {
        guard generation == caretPresentationGeneration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, generation == self.caretPresentationGeneration else { return }
            self.caretVisible.toggle()
            self.needsDisplay = true
            self.startCaretBlinking(for: generation)
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn _: Bool) {
        // The editor paints the caret from draw(_:) so AppKit's independent
        // insertion-point blink callbacks cannot overwrite its width or phase.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isStandardPasteShortcut(event), onPasteImage?() == true {
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let character = event.charactersIgnoringModifiers
        if languageServerFeatures.contains(.completion),
           (modifiers == .control && character == " "
            || modifiers == .option && character == "\u{1B}") {
            requestLanguageCompletions()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isStandardPasteShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.type == .keyDown
            && modifiers == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    func rebuildLineIndex() {
        lineIndex = TextLineIndex(source: string as NSString)
    }

    func applyLineIndexEdit(replacedRange: NSRange, replacement: String) {
        if replacement.contains("\n") || replacement.contains("\r")
            || !lineIndex.applySingleLineEdit(replacedRange: replacedRange, insertedLength: (replacement as NSString).length) {
            rebuildLineIndex()
        }
    }

    func visibleCharacterRange() -> NSRange? {
        guard let layoutManager,
              let textContainer,
              let scrollView = enclosingScrollView else { return nil }
        let visibleRect = scrollView.documentVisibleRect
        let textContainerVisibleRect = NSRect(
            x: visibleRect.minX - textContainerOrigin.x,
            y: visibleRect.minY - textContainerOrigin.y,
            width: visibleRect.width,
            height: visibleRect.height
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: textContainerVisibleRect,
            in: textContainer
        )
        guard glyphRange.length > 0 else { return nil }
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    #if DEBUG
    var currentFindMatchCountForTesting: Int { findMatchRanges.count }
    var findMatchLocationsForTesting: [Int] { findMatchRanges.map(\.location) }
    #endif

    func applyFindEdit(replacedRange: NSRange, insertedLength: Int, query: String) {
        guard !query.isEmpty else {
            clearFindHighlights()
            return
        }
        let source = string as NSString
        let delta = insertedLength - replacedRange.length
        let replacedEnd = NSMaxRange(replacedRange)
        findMatchRanges = findMatchRanges.compactMap { range in
            if NSMaxRange(range) <= replacedRange.location { return range }
            if range.location >= replacedEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            return nil
        }
        let safeLocation = min(replacedRange.location, max(0, source.length - 1))
        let lineRange = source.length == 0
            ? NSRange(location: 0, length: 0)
            : source.lineRange(for: NSRange(location: safeLocation, length: 0))
        let searchEnd = min(source.length, max(NSMaxRange(lineRange), replacedRange.location + insertedLength))
        let searchRange = NSRange(
            location: lineRange.location,
            length: max(0, searchEnd - lineRange.location)
        )
        findMatchRanges.removeAll { range in
            NSIntersectionRange(range, searchRange).length > 0
                || (range.location >= searchRange.location && range.location < NSMaxRange(searchRange))
        }
        if searchRange.length > 0, !query.isEmpty {
            var cursor = searchRange
            while cursor.length > 0 {
                let found = source.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: cursor
                )
                if found.location == NSNotFound { break }
                findMatchRanges.append(found)
                let nextLocation = NSMaxRange(found)
                cursor = NSRange(location: nextLocation, length: NSMaxRange(searchRange) - nextLocation)
            }
            findMatchRanges.sort { $0.location < $1.location }
        }
        currentFindMatchIndex = min(currentFindMatchIndex, max(0, findMatchRanges.count - 1))
        applyFindHighlights()
        reportFindState(
            index: findMatchRanges.isEmpty ? -1 : currentFindMatchIndex,
            count: findMatchRanges.count
        )
    }

    func characterOffset(forLine targetLine: Int, in _: NSString) -> Int {
        lineIndex.characterOffset(forLine: targetLine)
    }

    func lineNumber(at location: Int, in _: NSString) -> Int {
        lineIndex.lineNumber(at: location)
    }

    func lineRange(forLine line: Int, in _: NSString) -> NSRange {
        lineIndex.lineRange(forLine: line)
    }

    func updateDiagnostics(_ diagnostics: [EditorDiagnostic]) {
        self.diagnostics = diagnostics
        updateEditorDecorations()
    }

    func updateCaretDecorations() {
        guard let layoutManager else { return }
        let fullLength = (string as NSString).length
        for range in lastCaretBackgroundRanges where NSMaxRange(range) <= fullLength {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        lastCaretBackgroundRanges = []
        guard fullLength > 0 else { return }

        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: caret, length: 0))
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: currentLineColor,
            forCharacterRange: lineRange
        )
        lastCaretBackgroundRanges.append(lineRange)

        for range in matchingBracketRanges(in: source, caret: caret) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: bracketColor, forCharacterRange: range)
            lastCaretBackgroundRanges.append(range)
        }

        if isLanguageNavigationEnabled,
           let symbol = identifier(at: caret, in: source),
           let scope = enclosingCodeScope(at: caret, in: source) {
            let escaped = NSRegularExpression.escapedPattern(for: symbol.text)
            if let expression = try? NSRegularExpression(pattern: "\\b\(escaped)\\b") {
                expression.enumerateMatches(in: string, range: scope) { [weak layoutManager] match, _, _ in
                    guard let match else { return }
                    layoutManager?.addTemporaryAttribute(
                        .backgroundColor,
                        value: self.symbolColor,
                        forCharacterRange: match.range
                    )
                    self.lastCaretBackgroundRanges.append(match.range)
                }
            }
        }

        if !findMatchRanges.isEmpty {
            applyFindHighlights()
        }
        applyLinkHighlight()
    }

    func updateEditorDecorations() {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: string.utf16.count)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        removeUnusedCodeFade()
        fadedCodeRanges = []
        guard fullRange.length > 0 else {
            linkRange = nil
            return
        }

        lastCaretBackgroundRanges = []
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: caret, length: 0))
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: currentLineColor,
            forCharacterRange: lineRange
        )
        lastCaretBackgroundRanges.append(lineRange)

        for range in matchingBracketRanges(in: source, caret: caret) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: bracketColor, forCharacterRange: range)
            lastCaretBackgroundRanges.append(range)
        }

        if isLanguageNavigationEnabled,
           let symbol = identifier(at: caret, in: source),
           let scope = enclosingCodeScope(at: caret, in: source) {
            let escaped = NSRegularExpression.escapedPattern(for: symbol.text)
            if let expression = try? NSRegularExpression(pattern: "\\b\(escaped)\\b") {
                expression.enumerateMatches(in: string, range: scope) { [weak layoutManager] match, _, _ in
                    guard let match else { return }
                    layoutManager?.addTemporaryAttribute(
                        .backgroundColor,
                        value: self.symbolColor,
                        forCharacterRange: match.range
                    )
                    self.lastCaretBackgroundRanges.append(match.range)
                }
            }
        }

        for diagnostic in diagnostics {
            guard let range = diagnosticRange(for: diagnostic, in: source) else { continue }
            layoutManager.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: range
            )
            layoutManager.addTemporaryAttribute(
                .underlineColor,
                value: diagnosticColor(for: diagnostic.severity),
                forCharacterRange: range
            )
        }

        fadedCodeRanges = diagnostics.compactMap { diagnostic in
            guard diagnostic.isUnnecessary else { return nil }
            return diagnosticRange(for: diagnostic, in: source)
        }
        applyUnusedCodeFade()
        applyCollapsedFoldForeground()

        if !findMatchRanges.isEmpty {
            // 文本可能已变化，过滤越界 range 后再应用，避免无效 range 异常
            let validRanges = findMatchRanges.filter {
                $0.location >= 0 && NSMaxRange($0) <= fullRange.length
            }
            if validRanges.count != findMatchRanges.count {
                findMatchRanges = validRanges
                currentFindMatchIndex = min(currentFindMatchIndex, max(0, validRanges.count - 1))
            }
            if !findMatchRanges.isEmpty {
                applyFindHighlights()
            }
        }
        applyLinkHighlight()
    }

    // MARK: - Find in file

    /// 重新计算匹配范围并刷新高亮，用于 Find Bar 查询变化。
    /// 通过 updateEditorDecorations 统一重画，避免旧查询高亮残留。
    func updateFindMatches(query: String) {
        let source = string as NSString
        var newRanges: [NSRange] = []
        if !query.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                if found.location == NSNotFound { break }
                newRanges.append(found)
                let nextLocation = NSMaxRange(found)
                searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
            }
        }
        let needsRefresh = !findMatchRanges.isEmpty || !newRanges.isEmpty
        let previousIndex = currentFindMatchIndex
        let previousRanges = findMatchRanges
        findMatchRanges = newRanges
        currentFindMatchIndex = 0
        if !newRanges.isEmpty, newRanges == previousRanges {
            // 匹配列表未变（如光标移动触发的重算），保留当前匹配位置
            currentFindMatchIndex = min(previousIndex, newRanges.count - 1)
        }
        if needsRefresh {
            updateEditorDecorations()
        }
        reportFindState(
            index: findMatchRanges.isEmpty ? -1 : currentFindMatchIndex,
            count: findMatchRanges.count
        )
    }

    /// 跳转到下一个/上一个匹配并选中。
    func navigateFind(offset: Int) {
        guard !findMatchRanges.isEmpty else { return }
        let total = findMatchRanges.count
        currentFindMatchIndex = (currentFindMatchIndex + offset + total) % total
        applyFindHighlights()
        let range = findMatchRanges[currentFindMatchIndex]
        scrollRangeToVisible(range)
        setSelectedRange(range)
        reportFindState(index: currentFindMatchIndex, count: total)
    }

    /// Publishes only meaningful find-state transitions so SwiftUI updates do
    /// not create a feedback loop through `updateNSView`.
    private func reportFindState(index: Int, count: Int) {
        if let lastReportedFindState,
           lastReportedFindState.index == index,
           lastReportedFindState.count == count {
            return
        }
        lastReportedFindState = (index, count)
        onFindStateChange?(index, count)
    }

    /// 清除匹配高亮（Find Bar 关闭时调用）。
    func clearFindHighlights() {
        findMatchRanges = []
        currentFindMatchIndex = 0
        updateEditorDecorations()
    }

    /// 文档或查询变化时同步 Find Bar 状态；Find Bar 关闭时仅清理已有高亮。
    func syncFindState(isVisible: Bool, query: String) {
        if isVisible {
            updateFindMatches(query: query)
        } else if !findMatchRanges.isEmpty {
            clearFindHighlights()
        }
    }

    private func applyFindHighlights() {
        guard let layoutManager else { return }
        let matchColor = NSColor.systemYellow.withAlphaComponent(0.32)
        let currentColor = NSColor.systemOrange.withAlphaComponent(0.55)
        for (index, range) in findMatchRanges.enumerated() {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: index == currentFindMatchIndex ? currentColor : matchColor,
                forCharacterRange: range
            )
        }
    }

    override func performFindPanelAction(_ sender: Any?) {
        // 系统 Edit ▸ Find 子菜单（若存在）共享此 action，靠 tag 区分：
        // 1 = Find…(⌘F)、2 = Find Next(⌘G)、3 = Find Previous(⇧⌘G)
        switch (sender as? NSMenuItem)?.tag {
        case 1:
            onFindRequested?()
        case 2:
            onFindNextRequested?()
        case 3:
            onFindPreviousRequested?()
        default:
            break
        }
    }

    func updateFolds(
        regions: [JavaFoldRegion],
        collapsedIDs: Set<String>,
        onToggle: @escaping (JavaFoldRegion) -> Void
    ) {
        foldRegions = regions
        collapsedFoldIDs = collapsedIDs
        onToggleFold = onToggle
        if let hoveredFoldID,
           !collapsedIDs.contains(hoveredFoldID) {
            self.hoveredFoldID = nil
        }
        applyFoldAttributes()
        applyUnusedCodeFade()
        applyCollapsedFoldForeground()
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: string.utf16.count)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        if let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        needsDisplay = true
    }

    private func applyFoldAttributes() {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: string.utf16.count)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.paragraphStyle, forCharacterRange: fullRange)
        for region in foldRegions where collapsedFoldIDs.contains(region.id) {
            guard NSMaxRange(region.hiddenRange) <= fullRange.length else { continue }
            layoutManager.addTemporaryAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular),
                forCharacterRange: region.hiddenRange
            )
            let collapsedParagraph = NSMutableParagraphStyle()
            collapsedParagraph.minimumLineHeight = 0.1
            collapsedParagraph.maximumLineHeight = 0.1
            collapsedParagraph.lineSpacing = 0
            layoutManager.addTemporaryAttribute(
                .paragraphStyle,
                value: collapsedParagraph,
                forCharacterRange: region.hiddenRange
            )
        }
    }

    private func applyCollapsedFoldForeground() {
        guard let layoutManager else { return }
        let fullLength = string.utf16.count
        for region in foldRegions where collapsedFoldIDs.contains(region.id) {
            guard region.hiddenRange.location >= 0,
                  NSMaxRange(region.hiddenRange) <= fullLength else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.clear,
                forCharacterRange: region.hiddenRange
            )
        }
    }

    private func applyUnusedCodeFade() {
        guard let layoutManager else { return }
        for range in fadedCodeRanges {
            guard range.location >= 0,
                  NSMaxRange(range) <= string.utf16.count else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: unusedCodeColor,
                forCharacterRange: range
            )
        }
    }

    private func removeUnusedCodeFade() {
        guard let layoutManager else { return }
        let fullLength = string.utf16.count
        for range in fadedCodeRanges {
            guard range.location >= 0,
                  NSMaxRange(range) <= fullLength else { continue }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard collapsedFoldIDs.contains(where: { id in
            guard let region = foldRegions.first(where: { $0.id == id }) else { return false }
            return NSLocationInRange(characterRange.location, region.hiddenRange)
        }) else { return false }

        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }

    /// Draws IDEA-style indentation guides for every text file. Guides are
    /// calculated from visible lines plus a bounded context window so large
    /// files do not trigger a full-document scan on every redraw.
    private func drawIndentGuides(in dirtyRect: NSRect) {
        guard let layoutManager,
              let textContainer,
              layoutManager.numberOfGlyphs > 0 else { return }

        let source = string as NSString
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let width = max(1, indentationWidth)
        guard spaceWidth > 0 else { return }

        let containerDirtyRect = dirtyRect.offsetBy(
            dx: -textContainerOrigin.x,
            dy: -textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: containerDirtyRect,
            in: textContainer
        )
        let firstVisibleCharacter = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let lastVisibleGlyph = min(
            max(glyphRange.location, NSMaxRange(glyphRange) - 1),
            layoutManager.numberOfGlyphs - 1
        )
        let lastVisibleCharacter = layoutManager.characterIndexForGlyph(at: lastVisibleGlyph)
        let firstVisibleLine = lineNumber(at: firstVisibleCharacter, in: source)
        let lastVisibleLine = lineNumber(at: lastVisibleCharacter, in: source)
        let firstLine = max(0, firstVisibleLine - 200)
        let lastLine = min(lineIndex.lineCount - 1, lastVisibleLine + 200)
        guard firstLine <= lastLine else { return }

        var indentations: [Int: Int] = [:]
        var blankLines: Set<Int> = []
        for line in firstLine...lastLine {
            guard !isLineHiddenByCollapsedFold(line) else { continue }
            let indentation = leadingIndentationColumns(forLine: line, in: source)
            indentations[line] = indentation
            if lineIsBlank(line, in: source) {
                blankLines.insert(line)
            }
        }

        // Blank lines inherit the nearest non-empty line's indentation, so a
        // vertical guide continues through intentionally spaced-out code.
        var previousNonEmpty: Int?
        for line in firstLine...lastLine {
            guard indentations[line] != nil else {
                previousNonEmpty = nil
                continue
            }
            if blankLines.contains(line) {
                if let previousNonEmpty {
                    indentations[line] = indentations[previousNonEmpty] ?? 0
                }
            } else {
                previousNonEmpty = line
            }
        }
        var nextNonEmpty: Int?
        for line in stride(from: lastLine, through: firstLine, by: -1) {
            guard indentations[line] != nil else {
                nextNonEmpty = nil
                continue
            }
            if blankLines.contains(line) {
                if previousNonEmpty == nil, let nextNonEmpty {
                    indentations[line] = indentations[nextNonEmpty] ?? 0
                }
            } else {
                nextNonEmpty = line
            }
        }

        let maximumIndentation = indentations.values.max() ?? 0
        guard maximumIndentation >= width else { return }
        let caretLine = lineNumber(at: min(selectedRange().location, source.length), in: source)
        let caretIndentation = indentations[caretLine] ?? leadingIndentationColumns(forLine: caretLine, in: source)

        for level in stride(from: width, through: maximumIndentation, by: width) {
            var segmentStart: Int?
            for line in firstLine...lastLine {
                let qualifies = (indentations[line] ?? 0) >= level
                if qualifies, segmentStart == nil {
                    segmentStart = line
                }
                let isLastLine = line == lastLine
                if !qualifies || isLastLine {
                    guard let start = segmentStart else { continue }
                    let end = qualifies && isLastLine ? line : line - 1
                    drawIndentGuide(
                        level: level,
                        startLine: start,
                        endLine: end,
                        source: source,
                        spaceWidth: spaceWidth,
                        isActive: caretIndentation >= level,
                        dirtyRect: dirtyRect,
                        layoutManager: layoutManager
                    )
                    segmentStart = nil
                }
            }
        }
    }

    private func isLineHiddenByCollapsedFold(_ line: Int) -> Bool {
        foldRegions.contains { region in
            collapsedFoldIDs.contains(region.id) &&
                line > region.startLine &&
                line <= region.endLine
        }
    }

    private func drawIndentGuide(
        level: Int,
        startLine: Int,
        endLine: Int,
        source: NSString,
        spaceWidth: CGFloat,
        isActive: Bool,
        dirtyRect: NSRect,
        layoutManager: NSLayoutManager
    ) {
        guard startLine <= endLine,
              let firstRect = lineFragmentRect(forLine: startLine, in: source, layoutManager: layoutManager),
              let lastRect = lineFragmentRect(forLine: endLine, in: source, layoutManager: layoutManager) else { return }
        let x = textContainerOrigin.x + CGFloat(level) * spaceWidth
        let y1 = textContainerOrigin.y + firstRect.minY + 2
        let y2 = textContainerOrigin.y + lastRect.maxY - 2
        let guideRect = NSRect(x: x - 1, y: y1, width: 2, height: max(0, y2 - y1))
        guard guideRect.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) else { return }

        (isActive ? activeGuideColor : guideColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: y1))
        path.line(to: NSPoint(x: x, y: y2))
        path.stroke()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineBackground(in: rect)
        drawIndentGuides(in: rect)
    }

    private func drawCurrentLineBackground(in rect: NSRect) {
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: caret, length: 0))
        guard let layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: lineRange,
            actualCharacterRange: nil
        )
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        let currentLineRect = NSRect(
            x: 0,
            y: textContainerOrigin.y + lineRect.minY,
            width: bounds.width,
            height: lineRect.height
        )
        guard currentLineRect.intersects(rect) else { return }
        currentLineColor.setFill()
        currentLineRect.intersection(rect).fill()
    }

    private func lineFragmentRect(
        forLine line: Int,
        in source: NSString,
        layoutManager: NSLayoutManager
    ) -> NSRect? {
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let offset = characterOffset(forLine: line, in: source)
        let glyphIndex = min(max(0, offset), layoutManager.numberOfGlyphs - 1)
        return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }

    private func leadingIndentationColumns(forLine line: Int, in source: NSString) -> Int {
        let lineRange = lineIndex.lineRange(forLine: line)
        var columns = 0
        for index in lineRange.location..<NSMaxRange(lineRange) {
            switch source.character(at: index) {
            case 32:
                columns += 1
            case 9:
                let width = max(1, indentationWidth)
                columns += width - (columns % width)
            default:
                return columns
            }
        }
        return columns
    }

    private func foldSummaryRect(for region: JavaFoldRegion) -> NSRect? {
        guard let layoutManager, textContainer != nil else { return nil }
        let source = string as NSString
        let firstLineStart = characterOffset(forLine: region.startLine, in: source)
        let lineRange = source.lineRange(for: NSRange(location: min(firstLineStart, source.length), length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location,
              [10, 13].contains(source.character(at: contentEnd - 1)) { contentEnd -= 1 }
        guard contentEnd > lineRange.location else { return nil }
        let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: contentRange, actualCharacterRange: nil)
        let contentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer!)
        let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        return NSRect(
            x: min(bounds.width - 32, textContainerOrigin.x + contentRect.maxX + 7),
            y: textContainerOrigin.y + lineRect.minY + max(0, (lineRect.height - 17) / 2),
            width: 28,
            height: 17
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for region in foldRegions where collapsedFoldIDs.contains(region.id) {
            guard let rect = foldSummaryRect(for: region), rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            let isHovered = hoveredFoldID == region.id
            NSColor(white: isHovered ? 0.34 : 0.25, alpha: isHovered ? 0.80 : 0.38).setFill()
            path.fill()
            ("…" as NSString).draw(
                in: rect.offsetBy(dx: 0, dy: -1),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor(
                        white: isHovered ? 0.90 : 0.68,
                        alpha: isHovered ? 1 : 0.62
                    ),
                    .paragraphStyle: centeredParagraphStyle
                ]
            )
        }
        drawCaret()
    }

    private func drawCaret() {
        guard caretVisible,
              window?.firstResponder === self,
              let layoutManager,
              let textContainer else { return }

        let sourceLength = string.utf16.count
        let location = min(selectedRange().location, sourceLength)
        let caretRect: NSRect
        if layoutManager.numberOfGlyphs == 0 {
            let lineHeight = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 13))
            caretRect = NSRect(
                x: textContainerOrigin.x,
                y: textContainerOrigin.y,
                width: EditorLayoutMetrics.caretWidth,
                height: lineHeight
            )
        } else {
            let isAtDocumentEnd = location == sourceLength
            let glyphIndex = layoutManager.glyphIndexForCharacter(
                at: min(location, sourceLength - 1)
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            caretRect = NSRect(
                x: textContainerOrigin.x + (isAtDocumentEnd ? glyphRect.maxX : glyphRect.minX),
                y: textContainerOrigin.y + lineRect.minY,
                width: EditorLayoutMetrics.caretWidth,
                height: lineRect.height
            )
        }

        insertionPointColor.setFill()
        caretRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let region = foldRegions.first(where: {
            collapsedFoldIDs.contains($0.id) && foldSummaryRect(for: $0)?.contains(point) == true
        }) {
            onToggleFold?(region)
            return
        }

        if hasNavigationModifier(event.modifierFlags) {
            updateLinkHighlight(at: point)
            if let linkRange,
               let characterIndex = characterIndex(at: point),
               NSLocationInRange(characterIndex, linkRange) {
                let (line, column) = lineAndColumn(for: linkRange.location)
                onNavigateToSymbol?(line, column)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Cmd/Ctrl symbol navigation

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        if let window {
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.clearLinkHighlight()
                }
            }
        }
        updateTrackingAreas()
        onWindowAttached?()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard isLanguageNavigationEnabled, hasNavigationModifier(event.modifierFlags) else {
            clearLinkHighlight()
            return
        }
        if let window {
            updateLinkHighlight(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateFoldHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateFoldHover(at: point)
        guard isLanguageNavigationEnabled,
              hasNavigationModifier(event.modifierFlags) else { return }
        updateLinkHighlight(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateFoldHover(at: nil)
        clearLinkHighlight()
    }

    override func resignFirstResponder() -> Bool {
        updateFoldHover(at: nil)
        clearLinkHighlight()
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            updateInsertionPointStateAndRestartTimer(true)
        }
        return becameFirstResponder
    }

    private func updateFoldHover(at point: NSPoint?) {
        let nextID = point.flatMap { point in
            foldRegions.first(where: {
                collapsedFoldIDs.contains($0.id) && foldSummaryRect(for: $0)?.contains(point) == true
            })?.id
        }
        guard hoveredFoldID != nextID else { return }
        hoveredFoldID = nextID
        needsDisplay = true
    }

    private func updateLinkHighlight(at point: NSPoint) {
        guard isLanguageNavigationEnabled,
              let target = linkRange(at: point) else {
            clearLinkHighlight()
            return
        }
        guard linkRange != target else {
            NSCursor.pointingHand.set()
            return
        }
        linkRange = target
        updateEditorDecorations()
        NSCursor.pointingHand.set()
    }

    private func clearLinkHighlight() {
        guard linkRange != nil else {
            NSCursor.iBeam.set()
            return
        }
        linkRange = nil
        updateEditorDecorations()
        NSCursor.iBeam.set()
    }

    private func applyLinkHighlight() {
        guard isLanguageNavigationEnabled,
              let linkRange,
              linkRange.location >= 0,
              NSMaxRange(linkRange) <= string.utf16.count,
              let layoutManager else { return }
        layoutManager.addTemporaryAttribute(
            .foregroundColor,
            value: linkColor,
            forCharacterRange: linkRange
        )
        layoutManager.addTemporaryAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            forCharacterRange: linkRange
        )
        layoutManager.addTemporaryAttribute(
            .underlineColor,
            value: linkColor,
            forCharacterRange: linkRange
        )
    }

    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let characterIndex = characterIndex(at: point),
              let layoutManager,
              let textContainer else { return nil }
        let source = string as NSString
        guard let identifier = identifier(at: characterIndex, in: source) else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: identifier.range,
            actualCharacterRange: nil
        )
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return identifier.range
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager,
              let textContainer,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex >= 0, glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    private func hasNavigationModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        let mask = flags.intersection(.deviceIndependentFlagsMask)
        return mask.contains(.command) || mask.contains(.control)
    }

    private func lineAndColumn(for location: Int) -> (line: Int, column: Int) {
        let source = string as NSString
        let safeLocation = min(max(0, location), source.length)
        let line = lineIndex.lineNumber(at: safeLocation)
        let lineStart = lineIndex.characterOffset(forLine: line)
        return (line, safeLocation - lineStart)
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private func lineIsBlank(_ line: Int, in source: NSString) -> Bool {
        let range = lineIndex.lineRange(forLine: line)
        for index in range.location..<NSMaxRange(range) {
            let character = source.character(at: index)
            if character != 9, character != 10, character != 13, character != 32 {
                return false
            }
        }
        return true
    }

    private func diagnosticRange(for diagnostic: EditorDiagnostic, in source: NSString) -> NSRange? {
        guard source.length > 0 else { return nil }
        let lastLine = max(0, lineIndex.lineCount - 1)
        let startLine = min(max(0, diagnostic.line), lastLine)
        let endLine = min(max(startLine, diagnostic.endLine), lastLine)
        let start = characterOffset(forLine: startLine, column: diagnostic.utf16Column, in: source)
        var end = characterOffset(forLine: endLine, column: diagnostic.endUTF16Column, in: source)
        if end <= start { end = min(source.length, start + 1) }
        guard start < source.length, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func characterOffset(forLine line: Int, column: Int, in source: NSString) -> Int {
        let lineStart = characterOffset(forLine: line, in: source)
        let lineRange = lineIndex.lineRange(forLine: line)
        return min(NSMaxRange(lineRange), lineStart + max(0, column))
    }

    func lineCount() -> Int {
        lineIndex.lineCount
    }

    private func diagnosticColor(for severity: DiagnosticSeverity) -> NSColor {
        switch severity {
        case .unknown: NSColor.systemGray
        case .error: NSColor.systemRed
        case .warning: NSColor.systemOrange
        case .information: NSColor.systemBlue
        case .hint: NSColor.systemGray
        }
    }

    private func matchingBracketRanges(in source: NSString, caret: Int) -> [NSRange] {
        let candidates = [caret, caret - 1].filter { $0 >= 0 && $0 < source.length }
        let pairs: [unichar: (unichar, Int)] = [
            40: (41, 1), 91: (93, 1), 123: (125, 1),
            41: (40, -1), 93: (91, -1), 125: (123, -1)
        ]
        for position in candidates {
            let character = source.character(at: position)
            guard let (match, direction) = pairs[character] else { continue }
            var depth = 0
            var index = position
            while true {
                index += direction
                guard index >= 0, index < source.length else { break }
                let next = source.character(at: index)
                if next == character { depth += 1 }
                if next == match {
                    if depth == 0 {
                        return [NSRange(location: position, length: 1), NSRange(location: index, length: 1)]
                    }
                    depth -= 1
                }
            }
        }
        return []
    }

    private func identifier(at caret: Int, in source: NSString) -> (text: String, range: NSRange)? {
        guard source.length > 0 else { return nil }
        let characterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        var location = min(caret, source.length - 1)
        if !characterSet.contains(UnicodeScalar(source.character(at: location))!), location > 0 {
            location -= 1
        }
        guard characterSet.contains(UnicodeScalar(source.character(at: location))!) else { return nil }
        var start = location
        var end = location + 1
        while start > 0,
              let scalar = UnicodeScalar(source.character(at: start - 1)),
              characterSet.contains(scalar) { start -= 1 }
        while end < source.length,
              let scalar = UnicodeScalar(source.character(at: end)),
              characterSet.contains(scalar) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        let text = source.substring(with: range)
        guard text.first?.isLetter == true || text.first == "_" || text.first == "$" else { return nil }
        return (text, range)
    }

    private func enclosingCodeScope(at caret: Int, in source: NSString) -> NSRange? {
        var start: Int?
        var depth = 0
        if caret > 0 {
            for index in stride(from: min(caret - 1, source.length - 1), through: 0, by: -1) {
                let character = source.character(at: index)
                if character == 125 { depth += 1 }
                if character == 123 {
                    if depth == 0 {
                        start = index
                        break
                    }
                    depth -= 1
                }
            }
        }
        guard let start else { return nil }
        depth = 0
        for index in start..<source.length {
            let character = source.character(at: index)
            if character == 123 { depth += 1 }
            if character == 125 {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: start, length: index - start + 1)
                }
            }
        }
        return nil
    }

    override func insertTab(_ sender: Any?) {
        insertText(String(repeating: " ", count: indentationWidth), replacementRange: selectedRange())
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let layoutManager, let textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let containerPoint = NSPoint(
                x: point.x - textContainerOrigin.x,
                y: point.y - textContainerOrigin.y
            )
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if characterIndex <= string.utf16.count {
                setSelectedRange(NSRange(location: characterIndex, length: 0))
            }
        }

        let menu = super.menu(for: event) ?? NSMenu()
        let languageItems = languageContextMenuItems()
        guard !languageItems.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in languageItems.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    func languageContextMenuItems() -> [NSMenuItem] {
        var languageItems: [NSMenuItem] = []
        func add(_ feature: LanguageServerFeatureSet, _ title: String, _ action: Selector) {
            guard languageServerFeatures.contains(feature) else { return }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            languageItems.append(item)
        }
        add(.implementation, "Go to Implementation", #selector(goToImplementationFromMenu))
        add(.definition, "Go to Definition", #selector(goToDefinitionFromMenu))
        add(.references, "Find Usages", #selector(findUsagesFromMenu))
        add(.hover, "Quick Documentation", #selector(showQuickDocumentationFromMenu))
        add(.completion, "Complete Symbol", #selector(completeSymbolFromMenu))
        add(.rename, "Rename Symbol", #selector(renameSymbolFromMenu))
        add(.formatting, "Format Document", #selector(formatDocumentFromMenu))
        add(.codeActions, "Source Actions…", #selector(codeActionsFromMenu))
        return languageItems
    }

    @objc private func goToDefinitionFromMenu() {
        onGoToDefinition?()
    }

    @objc private func showQuickDocumentationFromMenu() {
        let position = languageServerPosition(at: selectedRange().location)
        onQuickDocumentation?(position.line, position.utf16Column)
    }

    @objc private func completeSymbolFromMenu() {
        requestLanguageCompletions()
    }

    @objc private func renameSymbolFromMenu() {
        let position = languageServerPosition(at: selectedRange().location)
        let alert = NSAlert()
        alert.messageText = "Rename Symbol"
        alert.informativeText = "Enter the new symbol name."
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onRenameRequested?(position.line, position.utf16Column, field.stringValue)
    }

    @objc private func formatDocumentFromMenu() { onFormatRequested?() }

    @objc private func codeActionsFromMenu() {
        let position = languageServerPosition(at: selectedRange().location)
        onCodeActionsRequested?(position.line, position.utf16Column)
    }

    private func requestLanguageCompletions() {
        let position = languageServerPosition(at: selectedRange().location)
        onCompletionRequested?(position.line, position.utf16Column)
    }

    func presentLanguageCompletions(_ items: [LanguageServerCompletionItem]) {
        guard !items.isEmpty, window != nil else { return }
        completionItemsByID = [:]
        for item in items.prefix(200) { completionItemsByID[item.id] = item }
        let menu = NSMenu(title: "Completions")
        for item in items.prefix(200) {
            let title = item.detail.map { "\(item.label)  —  \($0)" } ?? item.label
            let entry = NSMenuItem(
                title: title,
                action: #selector(insertLanguageCompletion(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = item.id
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: caretMenuPoint(), in: self)
    }

    func presentLanguageCodeActions(
        _ actions: [LanguageServerCodeAction],
        onSelect: @escaping (LanguageServerCodeAction) -> Void
    ) {
        guard !actions.isEmpty, window != nil else { return }
        let menu = NSMenu(title: "Source Actions")
        for action in actions.prefix(50) {
            let item = NSMenuItem(title: action.title, action: #selector(selectLanguageCodeAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        languageCodeActionHandler = onSelect
        menu.popUp(positioning: nil, at: caretMenuPoint(), in: self)
    }

    private var languageCodeActionHandler: ((LanguageServerCodeAction) -> Void)?

    @objc private func selectLanguageCodeAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? LanguageServerCodeAction else { return }
        languageCodeActionHandler?(action)
        languageCodeActionHandler = nil
    }

    func presentLanguageHover(_ hover: LanguageServerHover) {
        languageHoverPopover?.close()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        textView.string = hover.contents
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = NSColor(white: 0.88, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 9)
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
        let controller = NSViewController()
        controller.view = scrollView
        controller.preferredContentSize = NSSize(width: 480, height: 220)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.show(relativeTo: caretAnchorRect(), of: self, preferredEdge: .maxY)
        languageHoverPopover = popover
    }

    @objc private func insertLanguageCompletion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = completionItemsByID[id] else { return }
        let fallbackRange = rangeForUserCompletion
        let start = languageServerPosition(at: fallbackRange.location)
        let end = languageServerPosition(at: NSMaxRange(fallbackRange))
        let languageRange = LanguageServerRange(
            start: LanguageServerPosition(line: start.line, utf16Column: start.utf16Column),
            end: LanguageServerPosition(line: end.line, utf16Column: end.utf16Column)
        )
        if let onCompletionSelected {
            onCompletionSelected(item, languageRange)
        } else {
            insertText(LanguageServerSnippet.plainText(item.insertText), replacementRange: fallbackRange)
        }
        completionItemsByID = [:]
    }

    private func languageServerPosition(at location: Int) -> (line: Int, utf16Column: Int) {
        let line = lineIndex.lineNumber(at: location)
        let start = lineIndex.characterOffset(forLine: line)
        return (line, max(0, location - start))
    }

    private func caretAnchorRect() -> NSRect {
        guard let layoutManager, let textContainer else {
            return NSRect(x: textContainerInset.width, y: textContainerInset.height, width: 1, height: 18)
        }
        let length = string.utf16.count
        let location = length == 0 ? 0 : min(selectedRange().location, length - 1)
        let glyph = length == 0 ? 0 : layoutManager.glyphIndexForCharacter(at: location)
        var rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 0),
            in: textContainer
        )
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size = NSSize(width: max(1, rect.width), height: max(18, rect.height))
        return rect
    }

    private func caretMenuPoint() -> NSPoint {
        let rect = caretAnchorRect()
        return NSPoint(x: rect.minX, y: rect.maxY)
    }

    @objc private func goToImplementationFromMenu() {
        onGoToImplementation?()
    }

    @objc private func findUsagesFromMenu() {
        onFindUsages?()
    }

    override init(frame frameRect: NSRect) {
        // Build the TextKit 1 object graph explicitly. Calling NSTextView's
        // convenience init(frame:) makes AppKit create the text system through
        // its newer TextKit path; on current macOS releases that can trap while
        // initializing an NSTextView subclass. The editor relies on
        // NSLayoutManager for folding and temporary decorations, so the
        // explicit graph is also the intended compatibility mode.
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: max(frameRect.width, 1),
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        super.init(frame: frameRect, textContainer: textContainer)
        registerForDraggedTypes([TerminalTabDragPayload.pasteboardType])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFindQueryChanged(_:)),
            name: .litheFindQueryChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFindNavigate(_:)),
            name: .litheFindNavigate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFindDismiss(_:)),
            name: .litheFindDismiss,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
    }

    @objc private func handleFindQueryChanged(_ notification: Notification) {
        let query = notification.userInfo?[FindNotificationKeys.query] as? String ?? ""
        updateFindMatches(query: query)
    }

    @objc private func handleFindNavigate(_ notification: Notification) {
        let direction = notification.userInfo?[FindNotificationKeys.direction] as? Int ?? 1
        navigateFind(offset: direction)
    }

    @objc private func handleFindDismiss(_ notification: Notification) {
        clearFindHighlights()
        window?.makeFirstResponder(self)
    }
}

@MainActor
final class EditorContainerView: NSView {
    weak var scrollView: NSScrollView?
    weak var gutter: LineNumberGutterView?
    var gutterWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    private var blameByLine: [Int: GitBlameLine] = [:]
    private var isBlameVisible = false
    private var onSelectBlame: ((GitBlameLine) -> Void)?
    private var blameButtons: [Int: NSButton] = [:]
    private var foldRegions: [JavaFoldRegion] = []
    private var collapsedFoldIDs: Set<String> = []
    private var onToggleFold: ((JavaFoldRegion) -> Void)?
    private var implementationMarkers: [JavaImplementationMarker] = []
    private var onSelectImplementation: ((JavaImplementationMarker) -> Void)?
    private var debugBreakpointLines: Set<Int> = []
    private var onToggleDebugBreakpoint: ((Int) -> Void)?
    private var scrollRefreshScheduled = false
    private var hoveredFoldID: String?
    private var trackingArea: NSTrackingArea?
    private var palette = CodeEditorPalette.dark
    private var gitLineChangeMarkersByLine: [Int: GitLineChangeMarker] = [:]
    private var onShowGitLineChange: ((GitLineChangeMarker) -> Void)?
    private var onStageGitLineChange: ((GitLineChangeMarker) -> Void)?
    private var onUnstageGitLineChange: ((GitLineChangeMarker) -> Void)?
    private var onDiscardGitLineChange: ((GitLineChangeMarker) -> Void)?
    private var contextGitLineChange: GitLineChangeMarker?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        wantsLayer = true
        layer?.backgroundColor = palette.gutterBackground.cgColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleScrollRefresh()
            }
        }
    }

    fileprivate func applyAppearance(_ palette: CodeEditorPalette) {
        guard self.palette.isDark != palette.isDark || self.palette.theme != palette.theme else { return }
        self.palette = palette
        layer?.backgroundColor = palette.gutterBackground.cgColor
        needsDisplay = true
    }

    private func scheduleScrollRefresh() {
        guard !scrollRefreshScheduled else { return }
        scrollRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scrollRefreshScheduled = false
            self.needsDisplay = true
            self.layoutBlameButtons()
        }
    }

    func update(
        blameLines: [GitBlameLine],
        isVisible: Bool,
        onSelect: @escaping (GitBlameLine) -> Void
    ) {
        blameByLine = Dictionary(uniqueKeysWithValues: blameLines.map { ($0.line, $0) })
        isBlameVisible = isVisible
        onSelectBlame = onSelect
        blameButtons.values.forEach { $0.removeFromSuperview() }
        blameButtons = [:]
        if isVisible {
            for blame in blameLines {
                let button = ClosureButton(title: "") { onSelect(blame) }
                button.isBordered = false
                button.setAccessibilityElement(true)
                button.setAccessibilityRole(.button)
                button.setAccessibilityLabel(
                    "Line \(blame.line + 1): \(blame.date), \(blame.authorName)"
                )
                addSubview(button)
                blameButtons[blame.line] = button
            }
        }
        layoutBlameButtons()
        needsDisplay = true
    }

    func updateFoldRegions(
        _ regions: [JavaFoldRegion],
        collapsedIDs: Set<String>,
        onToggle: @escaping (JavaFoldRegion) -> Void
    ) {
        foldRegions = regions
        collapsedFoldIDs = collapsedIDs
        onToggleFold = onToggle
        if let hoveredFoldID,
           !regions.contains(where: { $0.id == hoveredFoldID }) {
            self.hoveredFoldID = nil
        }
        needsDisplay = true
    }

    func updateImplementationMarkers(
        _ markers: [JavaImplementationMarker],
        onSelect: @escaping (JavaImplementationMarker) -> Void
    ) {
        implementationMarkers = markers
        onSelectImplementation = onSelect
        needsDisplay = true
    }

    func updateDebugBreakpointLines(
        _ lines: Set<Int>,
        onToggle: @escaping (Int) -> Void
    ) {
        debugBreakpointLines = Set(lines.map { max(0, $0 - 1) })
        onToggleDebugBreakpoint = onToggle
        needsDisplay = true
    }

    func updateGitLineChanges(
        _ markers: [GitLineChangeMarker],
        onShow: @escaping (GitLineChangeMarker) -> Void,
        onStage: ((GitLineChangeMarker) -> Void)? = nil,
        onUnstage: ((GitLineChangeMarker) -> Void)? = nil,
        onDiscard: ((GitLineChangeMarker) -> Void)? = nil
    ) {
        gitLineChangeMarkersByLine = Dictionary(uniqueKeysWithValues: markers.map { ($0.line, $0) })
        onShowGitLineChange = onShow
        onStageGitLineChange = onStage
        onUnstageGitLineChange = onUnstage
        onDiscardGitLineChange = onDiscard
        needsDisplay = true
    }

    private func layoutBlameButtons() {
        guard isBlameVisible,
              let textView,
              let scrollView,
              let layoutManager = textView.layoutManager else { return }
        let source = textView.string as NSString
        let visibleRect = scrollView.documentVisibleRect
        for (line, button) in blameButtons {
            let characterIndex = characterOffset(forLine: line, in: source)
            guard characterIndex < source.length else {
                button.isHidden = true
                continue
            }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            button.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(16, lineRect.height))
            button.isHidden = button.frame.maxY < 0 || button.frame.minY > bounds.height
        }
        setAccessibilityChildren(Array(blameButtons.values))
    }

    private func characterOffset(forLine targetLine: Int, in source: NSString) -> Int {
        if let codeTextView = textView as? CodeTextView {
            return codeTextView.characterOffset(forLine: targetLine, in: source)
        }
        var line = 0
        var offset = 0
        while line < targetLine, offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            line += 1
        }
        return offset
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        palette.gutterBackground.setFill()
        dirtyRect.fill()

        let visibleRect = scrollView.documentVisibleRect
        let textContainerVisibleRect = NSRect(
            x: visibleRect.minX - textView.textContainerOrigin.x,
            y: visibleRect.minY - textView.textContainerOrigin.y,
            width: visibleRect.width,
            height: visibleRect.height
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: textContainerVisibleRect,
            in: textContainer
        )
        guard layoutManager.numberOfGlyphs > 0 else {
            let lineHeight = max(
                18,
                layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
            )
            drawLineNumber(1, y: textView.textContainerInset.height, height: lineHeight)
            drawEditorDivider(in: dirtyRect)
            return
        }

        let text = textView.string as NSString
        let codeTextView = textView as? CodeTextView
        let caret = min(textView.selectedRange().location, text.length)
        let currentLine = codeTextView?.lineNumber(at: caret, in: text)
            ?? text.substring(to: caret).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        var glyphIndex = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
        let firstCharacter = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let firstLine = codeTextView?.lineNumber(at: firstCharacter, in: text)
            ?? text.substring(to: min(text.length, firstCharacter))
                .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        var lineNumber = firstLine + 1
        let maxGlyph = min(NSMaxRange(glyphRange), layoutManager.numberOfGlyphs)

        while glyphIndex < maxGlyph {
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = codeTextView?.lineRange(forLine: lineNumber - 1, in: text)
                ?? text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            let isCollapsedHiddenLine = foldRegions.contains { region in
                collapsedFoldIDs.contains(region.id) &&
                    lineNumber - 1 > region.startLine && lineNumber - 1 <= region.endLine
            }
            if isCollapsedHiddenLine {
                let nextGlyph = NSMaxRange(lineGlyphRange)
                glyphIndex = nextGlyph > glyphIndex ? nextGlyph : glyphIndex + 1
                lineNumber += 1
                continue
            }
            if lineNumber - 1 == currentLine {
                palette.currentLine.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: lineRect.height).fill()
            }
            if isBlameVisible, let blame = blameByLine[lineNumber - 1] {
                drawBlame(blame, y: y + 1)
            }
            if let marker = implementationMarkers.first(where: { $0.line == lineNumber - 1 }) {
                drawImplementationMarker(marker, y: y, height: lineRect.height)
            }
            if !isBlameVisible, debugBreakpointLines.contains(lineNumber - 1) {
                drawDebugBreakpoint(y: y, height: lineRect.height)
            }
            if let marker = gitLineChangeMarkersByLine[lineNumber - 1] {
                drawGitLineChange(marker, y: y, height: lineRect.height)
            }
            drawLineNumber(lineNumber, y: y, height: lineRect.height)

            let nextGlyph = NSMaxRange(lineGlyphRange)
            glyphIndex = nextGlyph > glyphIndex ? nextGlyph : glyphIndex + 1
            lineNumber += 1
        }

        drawFoldIndicators(
            in: foldRegions,
            source: text,
            visibleRect: visibleRect,
            layoutManager: layoutManager
        )
        drawEditorDivider(in: dirtyRect)
    }

    private func drawEditorDivider(in dirtyRect: NSRect) {
        palette.gutterDivider.setFill()
        NSRect(
            x: bounds.width - 1,
            y: dirtyRect.minY,
            width: 1,
            height: dirtyRect.height
        ).fill()
    }

    private func drawFoldIndicators(
        in regions: [JavaFoldRegion],
        source: NSString,
        visibleRect: NSRect,
        layoutManager: NSLayoutManager
    ) {
        guard !regions.isEmpty else { return }
        for region in regions {
            let isHiddenByParent = regions.contains { parent in
                parent.id != region.id &&
                    collapsedFoldIDs.contains(parent.id) &&
                    region.startLine > parent.startLine &&
                    region.startLine <= parent.endLine
            }
            guard !isHiddenByParent else { continue }

            let characterIndex = characterOffset(forLine: region.startLine, in: source)
            guard characterIndex < source.length else { continue }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            guard glyphIndex < layoutManager.numberOfGlyphs else { continue }
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + (textView?.textContainerOrigin.y ?? 0) - visibleRect.minY
            guard y + lineRect.height >= 0, y <= bounds.height else { continue }
            drawFoldIndicator(region, y: y, height: max(lineRect.height, 16))
        }
    }

    private func drawLineNumber(_ number: Int, y: CGFloat, height: CGFloat) {
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: palette.lineNumber
        ]
        let size = label.size(withAttributes: attributes)
        let centeredY = y + max(0, (height - size.height) / 2)
        label.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: centeredY),
            withAttributes: attributes
        )
    }

    private func drawFoldIndicator(_ region: JavaFoldRegion, y: CGFloat, height: CGFloat) {
        let isHovered = hoveredFoldID == region.id
        let centerY = y + height / 2
        if isHovered {
            let hoverRect = NSRect(
                x: 1,
                y: y + max(0, (height - 17) / 2),
                width: 18,
                height: 17
            )
            palette.foldHover.setFill()
            NSBezierPath(roundedRect: hoverRect, xRadius: 3, yRadius: 3).fill()
        }
        let path = NSBezierPath()
        if collapsedFoldIDs.contains(region.id) {
            path.move(to: NSPoint(x: 6, y: centerY - 4))
            path.line(to: NSPoint(x: 11, y: centerY))
            path.line(to: NSPoint(x: 6, y: centerY + 4))
        } else {
            path.move(to: NSPoint(x: 5, y: centerY - 2))
            path.line(to: NSPoint(x: 9, y: centerY + 3))
            path.line(to: NSPoint(x: 13, y: centerY - 2))
        }
        path.close()
        (isHovered ? palette.foldIndicatorHover : palette.foldIndicator).setFill()
        path.fill()
    }

    private func drawImplementationMarker(_ marker: JavaImplementationMarker, y: CGFloat, height: CGFloat) {
        let rect = NSRect(x: 18, y: y + max(0, (height - 13) / 2), width: 13, height: 13)
        if let image = LitheIcons.implementationMarkerImage(
            pointingDown: marker.direction == .down,
            size: 13
        ) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        NSColor(red: 0.31, green: 0.67, blue: 0.43, alpha: 0.92).setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.2
        path.stroke()
    }

    private func drawDebugBreakpoint(y: CGFloat, height: CGFloat) {
        NSColor(red: 0.92, green: 0.28, blue: 0.30, alpha: 0.96).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: 29, y: y + max(0, (height - 8) / 2), width: 8, height: 8)
        ).fill()
    }

    private func drawGitLineChange(
        _ marker: GitLineChangeMarker,
        y: CGFloat,
        height: CGFloat
    ) {
        let color: NSColor
        switch marker.kind {
        case .added: color = palette.gitAdded
        case .modified: color = palette.gitModified
        case .deleted: color = palette.gitDeleted
        }
        color.setFill()
        let markerHeight = marker.kind == .deleted ? 3 : max(4, height - 2)
        NSBezierPath(
            roundedRect: NSRect(
                x: bounds.width - 4,
                y: y + max(1, (height - markerHeight) / 2),
                width: 3,
                height: markerHeight
            ),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private func drawBlame(_ blame: GitBlameLine, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: palette.blameText
        ]
        (blame.date as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
        (blame.authorName as NSString).draw(
            in: NSRect(x: 76, y: y, width: max(0, bounds.width - 128), height: 16),
            withAttributes: attributes
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateFoldHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateFoldHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateFoldHover(at: nil)
    }

    private func updateFoldHover(at point: NSPoint?) {
        let nextID = point.flatMap { foldRegion(at: $0)?.id }
        guard hoveredFoldID != nextID else { return }
        hoveredFoldID = nextID
        needsDisplay = true
    }

    private func foldRegion(at point: NSPoint) -> JavaFoldRegion? {
        guard point.x <= 18,
              let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let documentY = point.y + scrollView.documentVisibleRect.minY - textView.textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(
            for: NSPoint(x: textView.textContainerInset.width, y: documentY),
            in: textContainer
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let source = textView.string as NSString
        let line = (textView as? CodeTextView)?.lineNumber(at: characterIndex, in: source)
            ?? source.substring(to: min(characterIndex, source.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return foldRegions.first(where: { $0.startLine == line })
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let documentY = point.y + scrollView.documentVisibleRect.minY - textView.textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(
            for: NSPoint(x: textView.textContainerInset.width, y: documentY),
            in: textContainer
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let source = textView.string as NSString
        let line = (textView as? CodeTextView)?.lineNumber(at: characterIndex, in: source)
            ?? source.substring(to: min(characterIndex, source.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if point.x >= bounds.width - 8, let marker = gitLineChangeMarkersByLine[line] {
            onShowGitLineChange?(marker)
        } else if point.x <= 16, let region = foldRegions.first(where: { $0.startLine == line }) {
            onToggleFold?(region)
        } else if point.x <= 34,
                  let marker = implementationMarkers.first(where: { $0.line == line }) {
            onSelectImplementation?(marker)
        } else if !isBlameVisible, point.x <= 52 {
            onToggleDebugBreakpoint?(line)
        } else if isBlameVisible, let blame = blameByLine[line] {
            onSelectBlame?(blame)
        } else {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: characterIndex, length: 0))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= bounds.width - 10,
              let line = editorLine(at: point),
              let marker = gitLineChangeMarkersByLine[line] else {
            return super.menu(for: event)
        }
        contextGitLineChange = marker
        let menu = NSMenu(title: "Git Line Change")
        menu.addItem(withTitle: "Show Git Diff", action: #selector(showGitLineChangeFromMenu), keyEquivalent: "")
        menu.items.last?.target = self
        if onStageGitLineChange != nil {
            menu.addItem(withTitle: "Stage Change Block", action: #selector(stageGitLineChangeFromMenu), keyEquivalent: "")
            menu.items.last?.target = self
        }
        if onUnstageGitLineChange != nil {
            menu.addItem(withTitle: "Unstage Change Block", action: #selector(unstageGitLineChangeFromMenu), keyEquivalent: "")
            menu.items.last?.target = self
        }
        if onDiscardGitLineChange != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Discard Change Block…", action: #selector(discardGitLineChangeFromMenu), keyEquivalent: "")
            menu.items.last?.target = self
        }
        return menu
    }

    private func editorLine(at point: NSPoint) -> Int? {
        guard let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let documentY = point.y + scrollView.documentVisibleRect.minY - textView.textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(
            for: NSPoint(x: textView.textContainerInset.width, y: documentY),
            in: textContainer
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let source = textView.string as NSString
        return (textView as? CodeTextView)?.lineNumber(at: characterIndex, in: source)
            ?? source.substring(to: min(characterIndex, source.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    @objc private func showGitLineChangeFromMenu() {
        if let contextGitLineChange { onShowGitLineChange?(contextGitLineChange) }
    }

    @objc private func stageGitLineChangeFromMenu() {
        if let contextGitLineChange { onStageGitLineChange?(contextGitLineChange) }
    }

    @objc private func unstageGitLineChangeFromMenu() {
        if let contextGitLineChange { onUnstageGitLineChange?(contextGitLineChange) }
    }

    @objc private func discardGitLineChangeFromMenu() {
        if let contextGitLineChange { onDiscardGitLineChange?(contextGitLineChange) }
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
}

@MainActor
final class CodeVisionOverlayController {
    private weak var textView: NSTextView?
    private var buttons: [NSButton] = []
    private var currentHints: [JavaCodeVisionHint] = []

    init(textView: NSTextView) {
        self.textView = textView
    }

    func update(
        hints: [JavaCodeVisionHint],
        onUsages: @escaping (JavaCodeVisionHint) -> Void,
        onImplementations: @escaping (JavaCodeVisionHint) -> Void,
        onAuthor: @escaping () -> Void
    ) {
        currentHints = hints
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let source = textView.string as NSString

        for hint in hints {
            let lineStart = characterOffset(forLine: hint.line, in: source)
            let lineRange = source.lineRange(for: NSRange(location: min(lineStart, source.length), length: 0))
            guard lineRange.length > 0 else { continue }
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location {
                let character = source.character(at: contentEnd - 1)
                guard character == 10 || character == 13 else { break }
                contentEnd -= 1
            }
            guard contentEnd > lineRange.location else { continue }
            let contentRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: contentRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { continue }
            let contentRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let x = textView.textContainerOrigin.x + contentRect.maxX + 8
            let y = lineRect.minY + textView.textContainerOrigin.y - 1

            let requiredWidth = buttonWidth(for: hint)
            guard x + requiredWidth <= textView.bounds.maxX - 8 else { continue }

            let usageButton = makeButton(title: "\(hint.usageCount) usage\(hint.usageCount == 1 ? "" : "s")") {
                onUsages(hint)
            }
            usageButton.frame = NSRect(x: x, y: y, width: 70, height: 18)
            textView.addSubview(usageButton)
            buttons.append(usageButton)

            var nextX = x + 72
            if hint.implementationCount > 0 {
                let title = "\(hint.implementationCount) implementation\(hint.implementationCount == 1 ? "" : "s")"
                let implementationButton = makeButton(title: title) {
                    onImplementations(hint)
                }
                let width = max(108, CGFloat(title.count) * 5.8 + 16)
                implementationButton.frame = NSRect(x: nextX, y: y, width: width, height: 18)
                textView.addSubview(implementationButton)
                buttons.append(implementationButton)
                nextX += width + 2
            }

            if let authorName = hint.authorName, !authorName.isEmpty {
                let authorButton = makeButton(title: authorName, systemImage: "person") {
                    onAuthor()
                }
                authorButton.frame = NSRect(x: nextX, y: y, width: 112, height: 18)
                textView.addSubview(authorButton)
                buttons.append(authorButton)
            }
        }
        textView.setAccessibilityChildren(buttons)
    }

    private func characterOffset(forLine targetLine: Int, in source: NSString) -> Int {
        if let codeTextView = textView as? CodeTextView {
            return codeTextView.characterOffset(forLine: targetLine, in: source)
        }
        var line = 0
        var offset = 0
        while line < targetLine, offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            line += 1
        }
        return offset
    }

    private func makeButton(
        title: String,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10.5)
        button.contentTintColor = NSColor(white: 0.52, alpha: 1)
        button.alignment = .left
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(title)
        if let systemImage {
            button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func buttonWidth(for hint: JavaCodeVisionHint) -> CGFloat {
        var width: CGFloat = 70
        if hint.implementationCount > 0 {
            let title = "\(hint.implementationCount) implementation\(hint.implementationCount == 1 ? "" : "s")"
            width += max(108, CGFloat(title.count) * 5.8 + 16) + 2
        }
        if let authorName = hint.authorName, !authorName.isEmpty {
            width += 114
        }
        return width
    }
}

@MainActor
final class JavaInlayHintOverlayController {
    private weak var textView: NSTextView?
    private var labels: [NSTextField] = []
    private var currentHints: [JavaInlayHint] = []

    init(textView: NSTextView) {
        self.textView = textView
    }

    func update(hints: [JavaInlayHint]) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage,
              let textContainer = textView.textContainer else { return }
        currentHints = hints
        labels.forEach { $0.removeFromSuperview() }
        labels = []
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        let source = textView.string as NSString
        var placements: [(hint: JavaInlayHint, location: Int, label: NSTextField, width: CGFloat)] = []

        for hint in hints {
            let lineStart = characterOffset(forLine: hint.line, in: source)
            let location = min(source.length, lineStart + hint.utf16Column)
            guard location > 0, location < source.length else { continue }
            let label = NSTextField(labelWithString: normalizedLabel(hint.label))
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = NSColor(white: 0.61, alpha: 1)
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor(white: 0.23, alpha: 0.88).cgColor
            label.layer?.cornerRadius = 3
            label.sizeToFit()
            let width = label.frame.width + 9
            placements.append((hint, location, label, width))
        }

        textStorage.beginEditing()
        textStorage.removeAttribute(.kern, range: fullRange)
        for placement in placements {
            textStorage.addAttribute(
                .kern,
                value: placement.width + 3,
                range: NSRange(location: placement.location - 1, length: 1)
            )
        }
        textStorage.endEditing()
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)

        for placement in placements {
            let glyph = layoutManager.glyphIndexForCharacter(at: placement.location)
            let point = layoutManager.location(forGlyphAt: glyph)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let label = placement.label
            label.frame = NSRect(
                x: textView.textContainerOrigin.x + point.x - placement.width - 3,
                y: textView.textContainerOrigin.y + lineRect.minY + 1,
                width: placement.width,
                height: max(16, lineRect.height - 2)
            )
            label.setAccessibilityLabel("Parameter \(placement.hint.label)")
            textView.addSubview(label)
            labels.append(label)
        }
    }

    private func normalizedLabel(_ label: String) -> String {
        label.hasSuffix(":") ? label : "\(label):"
    }

    private func characterOffset(forLine targetLine: Int, in source: NSString) -> Int {
        if let codeTextView = textView as? CodeTextView {
            return codeTextView.characterOffset(forLine: targetLine, in: source)
        }
        var line = 0
        var offset = 0
        while line < targetLine, offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            line += 1
        }
        return offset
    }
}

@MainActor
private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func invoke() {
        handler()
    }
}

struct HighlightedRangeCache {
    private(set) var ranges: [NSRange] = []

    mutating func insert(_ range: NSRange) {
        guard range.length > 0 else { return }
        var merged = range
        var result: [NSRange] = []
        var didInsert = false

        for existing in ranges {
            if NSMaxRange(existing) < merged.location {
                result.append(existing)
            } else if NSMaxRange(merged) < existing.location {
                if !didInsert {
                    result.append(merged)
                    didInsert = true
                }
                result.append(existing)
            } else {
                merged = NSUnionRange(merged, existing)
            }
        }
        if !didInsert {
            result.append(merged)
        }
        ranges = result
    }

    func uncoveredRanges(in target: NSRange) -> [NSRange] {
        guard target.length > 0 else { return [] }
        let targetEnd = NSMaxRange(target)
        var cursor = target.location
        var uncovered: [NSRange] = []

        for existing in ranges {
            if NSMaxRange(existing) <= cursor { continue }
            if existing.location >= targetEnd { break }
            if existing.location > cursor {
                uncovered.append(NSRange(
                    location: cursor,
                    length: min(existing.location, targetEnd) - cursor
                ))
            }
            cursor = max(cursor, min(NSMaxRange(existing), targetEnd))
            if cursor >= targetEnd { break }
        }
        if cursor < targetEnd {
            uncovered.append(NSRange(location: cursor, length: targetEnd - cursor))
        }
        return uncovered
    }

    mutating func removeAll() {
        ranges.removeAll(keepingCapacity: true)
    }
}

@MainActor
fileprivate enum SyntaxHighlighter {
    private static let keywordExpression = try! NSRegularExpression(
        pattern: #"\b(class|struct|enum|protocol|extension|func|let|var|if|else|guard|switch|case|for|while|return|throw|throws|try|catch|async|await|public|private|internal|protected|static|final|new|import|package|interface|implements|extends|void|boolean|int|long|const|function|def|in|from|as|true|false|null|nil|self|this)\b"#
    )
    private static let annotationExpression = try! NSRegularExpression(
        pattern: #"@[A-Za-z_][A-Za-z0-9_]*"#
    )
    private static let typeExpression = try! NSRegularExpression(
        pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#
    )
    private static let numberExpression = try! NSRegularExpression(
        pattern: #"\b\d+(?:\.\d+)?\b"#
    )
    private static let stringExpression = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
    )
    private static let commentExpression = try! NSRegularExpression(
        pattern: #"//.*$|#.*$|/\*[\s\S]*?\*/"#,
        options: [.anchorsMatchLines]
    )

    static func apply(
        to storage: NSTextStorage,
        font: NSFont,
        fileExtension: String,
        isDark: Bool,
        range: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        let target = targetRange(for: range, in: storage.string as NSString, limit: fullRange)
        applyExact(
            to: storage,
            font: font,
            fileExtension: fileExtension,
            isDark: isDark,
            range: target
        )
    }

    static func applyExact(
        to storage: NSTextStorage,
        font: NSFont,
        fileExtension: String,
        isDark: Bool,
        range target: NSRange
    ) {
        guard target.length > 0 else { return }
        let palette = CodeEditorPalette(isDark: isDark, theme: LitheTheme.activeTheme)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .paragraphStyle: LitheTheme.editorParagraphStyle,
            .ligature: 0,
            .foregroundColor: palette.text
        ], range: target)

        apply(keywordExpression, color: palette.keyword, storage: storage, range: target)
        apply(annotationExpression, color: palette.annotation, storage: storage, range: target)
        apply(typeExpression, color: palette.type, storage: storage, range: target)
        apply(numberExpression, color: palette.number, storage: storage, range: target)
        apply(stringExpression, color: palette.string, storage: storage, range: target)
        apply(commentExpression, color: palette.comment, storage: storage, range: target)
        storage.endEditing()
    }

    private static func apply(
        _ expression: NSRegularExpression,
        color: NSColor,
        storage: NSTextStorage,
        range: NSRange
    ) {
        expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    /// Re-color the edited lines plus a small pad so a token that crosses the
    /// caret, or a nearby block comment, is not left half-styled.
    static func targetRange(for range: NSRange?, in source: NSString, limit: NSRange) -> NSRange {
        guard let range else { return limit }
        let safe = NSIntersectionRange(range, limit)
        guard source.length > 0 else { return safe }
        let startLine = source.lineRange(for: NSRange(location: safe.location, length: 0))
        let endIndex = max(safe.location, NSMaxRange(safe) > 0 ? NSMaxRange(safe) - 1 : 0)
        let endLine = source.lineRange(for: NSRange(location: min(endIndex, source.length - 1), length: 0))
        var combined = NSUnionRange(startLine, endLine)
        if combined.location > 0 {
            combined = NSUnionRange(
                source.lineRange(for: NSRange(location: combined.location - 1, length: 0)),
                combined
            )
        }
        if NSMaxRange(combined) < source.length {
            combined = NSUnionRange(
                combined,
                source.lineRange(for: NSRange(location: NSMaxRange(combined), length: 0))
            )
        }
        return NSIntersectionRange(combined, limit)
    }
}
