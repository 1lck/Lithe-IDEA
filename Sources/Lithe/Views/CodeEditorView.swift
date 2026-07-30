import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, model: model)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let container = EditorContainerView()
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.085, green: 0.089, blue: 0.096, alpha: 1)
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
        let gutterWidthConstraint = gutter.widthAnchor.constraint(equalToConstant: 52)
        gutterWidthConstraint.isActive = true

        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.delegate = context.coordinator
        textView.string = document.text
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
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = scrollView.backgroundColor
        textView.textColor = NSColor(white: 0.82, alpha: 1)
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.16, green: 0.31, blue: 0.54, alpha: 1),
            .foregroundColor: NSColor.white
        ]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isJavaNavigationEnabled = document.url.pathExtension.lowercased() == "java"
        textView.onGoToDefinition = { [weak model] in model?.goToDefinition() }
        textView.onFindUsages = { [weak model] in model?.findJavaReferences() }

        scrollView.documentView = textView
        gutter.attach(textView: textView, scrollView: scrollView)

        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        context.coordinator.container = container
        context.coordinator.codeVisionOverlay = CodeVisionOverlayController(textView: textView)
        context.coordinator.highlight()
        context.coordinator.updateCaret()
        container.scrollView = scrollView
        container.gutter = gutter
        container.gutterWidthConstraint = gutterWidthConstraint
        context.coordinator.updateCodeVisionAndBlame()
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let textView = container.scrollView?.documentView as? NSTextView else { return }
        context.coordinator.document = document
        context.coordinator.model = model
        if textView.string != document.text && !context.coordinator.isApplyingEditorChange {
            let selection = textView.selectedRange()
            textView.string = document.text
            textView.setSelectedRange(NSRange(location: min(selection.location, document.text.utf16.count), length: 0))
            context.coordinator.highlight()
            container.gutter?.needsDisplay = true
        }
        context.coordinator.updateCodeVisionAndBlame()
        context.coordinator.applyNavigationTargetIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var document: EditorDocument?
        weak var model: AppModel?
        let fileExtension: String
        weak var textView: NSTextView?
        weak var gutter: LineNumberGutterView?
        weak var container: EditorContainerView?
        var codeVisionOverlay: CodeVisionOverlayController?
        var isApplyingEditorChange = false
        var appliedNavigationTargetID: UUID?

        init(document: EditorDocument, model: AppModel) {
            self.document = document
            self.model = model
            fileExtension = document.url.pathExtension
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isApplyingEditorChange = true
            document?.text = textView.string
            highlight()
            gutter?.needsDisplay = true
            isApplyingEditorChange = false
            updateCaret()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateCaret()
        }

        func highlight() {
            guard let textStorage = textView?.textStorage else { return }
            SyntaxHighlighter.apply(to: textStorage, fileExtension: fileExtension)
        }

        func updateCodeVisionAndBlame() {
            guard let document, let model else { return }
            let url = document.url.standardizedFileURL
            let hints = model.javaCodeVisionHints[url] ?? []
            codeVisionOverlay?.update(
                hints: hints,
                onUsages: { [weak model] hint in model?.findUsages(for: hint, in: url) },
                onAuthor: { [weak model] in model?.showBlame(for: url) }
            )

            let isBlameVisible = model.blameVisibleURL == url
            let blameLines = model.gitBlameLines[url] ?? []
            container?.gutterWidthConstraint?.constant = isBlameVisible ? 224 : 52
            gutter?.update(blameLines: blameLines, isVisible: isBlameVisible) { [weak model] blame in
                Task { await model?.showGitCommit(blame.commitHash) }
            }
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
            updateCaret()
        }

        func updateCaret() {
            guard let textView, let document else { return }
            let text = textView.string as NSString
            let location = min(textView.selectedRange().location, text.length)
            let prefix = text.substring(to: location) as NSString
            var line = 0
            var lineStart = 0
            for index in 0..<prefix.length where prefix.character(at: index) == 10 {
                line += 1
                lineStart = index + 1
            }
            model?.editorCaret = EditorCaret(
                url: document.url.standardizedFileURL,
                line: line,
                utf16Column: location - lineStart
            )
        }
    }
}

@MainActor
final class CodeTextView: NSTextView {
    var isJavaNavigationEnabled = false
    var onGoToDefinition: (() -> Void)?
    var onFindUsages: (() -> Void)?

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
        guard isJavaNavigationEnabled else { return menu }
        menu.insertItem(.separator(), at: 0)

        let usages = NSMenuItem(
            title: "Find Usages",
            action: #selector(findUsagesFromMenu),
            keyEquivalent: ""
        )
        usages.target = self
        menu.insertItem(usages, at: 0)

        let definition = NSMenuItem(
            title: "Go to Definition",
            action: #selector(goToDefinitionFromMenu),
            keyEquivalent: ""
        )
        definition.target = self
        menu.insertItem(definition, at: 0)
        return menu
    }

    @objc private func goToDefinitionFromMenu() {
        onGoToDefinition?()
    }

    @objc private func findUsagesFromMenu() {
        onFindUsages?()
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

    override var isFlipped: Bool { true }

    func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.075, green: 0.080, blue: 0.087, alpha: 1).cgColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.needsDisplay = true
                self?.layoutBlameButtons()
            }
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

        NSColor(red: 0.075, green: 0.080, blue: 0.087, alpha: 1).setFill()
        dirtyRect.fill()

        let visibleRect = scrollView.documentVisibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard layoutManager.numberOfGlyphs > 0 else {
            drawLineNumber(1, y: textView.textContainerInset.height)
            return
        }

        let text = textView.string as NSString
        var glyphIndex = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
        let firstCharacter = layoutManager.characterIndexForGlyph(at: glyphIndex)
        var lineNumber = text.substring(to: min(text.length, firstCharacter))
            .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let maxGlyph = min(NSMaxRange(glyphRange), layoutManager.numberOfGlyphs)

        while glyphIndex < maxGlyph {
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            if isBlameVisible, let blame = blameByLine[lineNumber - 1] {
                drawBlame(blame, y: y + 1)
            }
            drawLineNumber(lineNumber, y: y + 1)

            let nextGlyph = NSMaxRange(lineGlyphRange)
            glyphIndex = nextGlyph > glyphIndex ? nextGlyph : glyphIndex + 1
            lineNumber += 1
        }
    }

    private func drawLineNumber(_ number: Int, y: CGFloat) {
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.34, alpha: 1)
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.width - size.width - 9, y: y), withAttributes: attributes)
    }

    private func drawBlame(_ blame: GitBlameLine, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor(white: 0.53, alpha: 1)
        ]
        (blame.date as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
        (blame.authorName as NSString).draw(
            in: NSRect(x: 76, y: y, width: max(0, bounds.width - 128), height: 16),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isBlameVisible,
              let textView,
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
        let prefix = (textView.string as NSString).substring(to: min(characterIndex, textView.string.utf16.count))
        let line = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if let blame = blameByLine[line] {
            onSelectBlame?(blame)
        }
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
        onAuthor: @escaping () -> Void
    ) {
        guard hints != currentHints else { return }
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
            let lineGlyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lineGlyph, effectiveRange: nil)
            let codeWidth = CGFloat(contentEnd - lineRange.location) * 7.83
            var x = min(textView.bounds.width - 190, textView.textContainerOrigin.x + codeWidth + 8)
            x = max(8, x)
            let y = lineRect.minY + textView.textContainerOrigin.y - 1

            let usageButton = makeButton(title: "\(hint.usageCount) usage\(hint.usageCount == 1 ? "" : "s")") {
                onUsages(hint)
            }
            usageButton.frame = NSRect(x: x, y: y, width: 70, height: 18)
            textView.addSubview(usageButton)
            buttons.append(usageButton)

            if let authorName = hint.authorName, !authorName.isEmpty {
                let authorButton = makeButton(title: authorName, systemImage: "person") {
                    onAuthor()
                }
                authorButton.frame = NSRect(x: x + 72, y: y, width: 112, height: 18)
                textView.addSubview(authorButton)
                buttons.append(authorButton)
            }
        }
        textView.setAccessibilityChildren(buttons)
    }

    private func characterOffset(forLine targetLine: Int, in source: NSString) -> Int {
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

    @objc private func invoke() {
        handler()
    }
}

@MainActor
private enum SyntaxHighlighter {
    static func apply(to storage: NSTextStorage, fileExtension: String) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(white: 0.80, alpha: 1)
        ], range: fullRange)

        apply(pattern: #"\b(class|struct|enum|protocol|extension|func|let|var|if|else|guard|switch|case|for|while|return|throw|throws|try|catch|async|await|public|private|internal|protected|static|final|new|import|package|interface|implements|extends|void|boolean|int|long|const|function|def|in|from|as|true|false|null|nil|self|this)\b"#, color: NSColor(red: 0.80, green: 0.48, blue: 0.77, alpha: 1), storage: storage)
        apply(pattern: #"@[A-Za-z_][A-Za-z0-9_]*"#, color: NSColor(red: 0.86, green: 0.72, blue: 0.34, alpha: 1), storage: storage)
        apply(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, color: NSColor(red: 0.42, green: 0.72, blue: 0.90, alpha: 1), storage: storage)
        apply(pattern: #"\b\d+(?:\.\d+)?\b"#, color: NSColor(red: 0.65, green: 0.75, blue: 0.49, alpha: 1), storage: storage)
        apply(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: NSColor(red: 0.55, green: 0.75, blue: 0.48, alpha: 1), storage: storage)
        apply(pattern: #"//.*$|#.*$|/\*[\s\S]*?\*/"#, options: [.anchorsMatchLines], color: NSColor(red: 0.39, green: 0.56, blue: 0.42, alpha: 1), storage: storage)
        storage.endEditing()
    }

    private static func apply(
        pattern: String,
        options: NSRegularExpression.Options = [],
        color: NSColor,
        storage: NSTextStorage
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let range = NSRange(location: 0, length: storage.length)
        expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
