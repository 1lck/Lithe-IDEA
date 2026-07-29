import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
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
        scrollView.backgroundColor = NSColor(red: 0.105, green: 0.110, blue: 0.120, alpha: 1)
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
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

        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.highlight()
        container.scrollView = scrollView
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let textView = container.scrollView?.documentView as? NSTextView else { return }
        context.coordinator.document = document
        if textView.string != document.text && !context.coordinator.isApplyingEditorChange {
            let selection = textView.selectedRange()
            textView.string = document.text
            textView.setSelectedRange(NSRange(location: min(selection.location, document.text.utf16.count), length: 0))
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var document: EditorDocument?
        let fileExtension: String
        weak var textView: NSTextView?
        var isApplyingEditorChange = false

        init(document: EditorDocument) {
            self.document = document
            fileExtension = document.url.pathExtension
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isApplyingEditorChange = true
            document?.text = textView.string
            highlight()
            isApplyingEditorChange = false
        }

        func highlight() {
            guard let textStorage = textView?.textStorage else { return }
            SyntaxHighlighter.apply(to: textStorage, fileExtension: fileExtension)
        }
    }
}

@MainActor
final class EditorContainerView: NSView {
    weak var scrollView: NSScrollView?

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
