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
            gutter.widthAnchor.constraint(equalToConstant: 52),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

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
        context.coordinator.highlight()
        context.coordinator.updateCaret()
        container.scrollView = scrollView
        container.gutter = gutter
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
        context.coordinator.applyNavigationTargetIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var document: EditorDocument?
        weak var model: AppModel?
        let fileExtension: String
        weak var textView: NSTextView?
        weak var gutter: LineNumberGutterView?
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
            Task { @MainActor in self?.needsDisplay = true }
        }
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

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
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
