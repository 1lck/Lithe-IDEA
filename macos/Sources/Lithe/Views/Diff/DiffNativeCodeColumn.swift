import AppKit
import SwiftUI
import LitheGitModule

/// Split position includes the source gutter: code disappears before the gutter.
/// The existing drag handle remains reachable when either side is fully hidden.
struct DiffSplitWidths {
    let position: CGFloat
    let leftCode: CGFloat
    let leftNumbers: CGFloat
    let divider: CGFloat
    let rightNumbers: CGFloat
    let rightCode: CGFloat

    init(width: CGFloat, position: CGFloat?, gutterWidth: CGFloat = DiffLayoutMetrics.lineNumberGutterWidth) {
        let width = max(0, width)
        self.position = min(max(position ?? width / 2, 0), width)
        divider = min(DiffLayoutMetrics.dividerWidth, self.position * 2, (width - self.position) * 2)
        let left = max(0, self.position - divider / 2)
        let right = max(0, width - self.position - divider / 2)
        leftNumbers = min(left, gutterWidth)
        rightNumbers = min(right, gutterWidth)
        leftCode = max(0, left - leftNumbers)
        rightCode = max(0, right - rightNumbers)
    }
}

/// A view-local prepared projection, not a source document or a comparison engine.
/// Its identity changes with DiffSplitLayout; divider movement never tokenizes text.
@MainActor
final class DiffNativeColumnState: ObservableObject {
    struct Line {
        let item: DiffSplitLayout.Item
        let range: NSRange
        let sourceNumber: Int?
    }
    private var identity: UUID?
    private var fileExtension = ""
    private var dark = false
    private var highlightsWords = false
    private var unified = false
    private(set) var lines: [Line] = []
    private(set) var preparedText = NSAttributedString()
    private(set) var revision = 0
    var currentSearchID: DiffRowID?
    var caretLine: Int?
    var hasCaret = false
    weak var gutter: DiffNativeGutterView?

    func prepare(identity: UUID, items: [DiffSplitLayout.Item], side: DiffSide,
                 fileExtension: String, highlightsWords: Bool, dark: Bool, unified: Bool = false) {
        guard self.identity != identity || self.fileExtension != fileExtension
            || self.highlightsWords != highlightsWords || self.dark != dark || self.unified != unified else { return }
        self.identity = identity
        self.fileExtension = fileExtension
        self.highlightsWords = highlightsWords
        self.dark = dark
        self.unified = unified
        let text = NSMutableAttributedString()
        lines = []
        for item in items {
            let start = text.length
            var sourceNumber: Int?
            if case let .row(row, _) = item.displayRow, item.kind != .information {
                let sourceSide: DiffSide = unified ? (item.kind == .removal ? .left : .right) : side
                let source = sourceSide == .left ? row.left ?? "" : row.rightText ?? ""
                let other = sourceSide == .left ? row.rightText : row.left
                sourceNumber = sourceSide == .left ? row.oldLine : row.newLine
                let styled = unified
                    ? DiffSyntaxHighlighter.styled(source, comparing: other, fileExtension: fileExtension,
                        side: sourceSide, highlightsWords: highlightsWords && row.kind == .changed)
                    : DiffSyntaxHighlighter.styled(source, fileExtension: fileExtension,
                        highlight: highlightsWords ? item.inlineHighlight : nil)
                for run in styled.runs {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if let color = run.foregroundColor { attributes[.foregroundColor] = NSColor(color) }
                    if let color = run.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
                    text.append(NSAttributedString(string: String(styled[run.range].characters), attributes: attributes))
                }
            }
            text.append(NSAttributedString(string: "\n"))
            let range = NSRange(location: start, length: text.length - start)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = item.height
            paragraph.maximumLineHeight = item.height
            paragraph.lineBreakMode = .byClipping
            paragraph.tabStops = []
            paragraph.defaultTabInterval = LitheTheme.editorFont(size: DiffLayoutMetrics.textFontSize)
                .maximumAdvancement.width * 4
            text.addAttributes([.font: LitheTheme.editorFont(size: DiffLayoutMetrics.textFontSize),
                .paragraphStyle: paragraph], range: range)
            lines.append(Line(item: item, range: range, sourceNumber: sourceNumber))
        }
        preparedText = text
        revision += 1
        caretLine = nil
        gutter?.needsDisplay = true
    }

    func firstVisibleLine(at y: CGFloat) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            let item = lines[mid].item
            if item.top + item.height <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func line(atCharacter index: Int) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].range) <= index { low = mid + 1 } else { high = mid }
        }
        return low < lines.count ? low : nil
    }

    func selectedSource(in selected: NSRange) -> String {
        let source = preparedText.string as NSString
        return lines.compactMap { line -> String? in
            guard case .row = line.item.displayRow, line.item.kind != .information else { return nil }
            let range = NSIntersectionRange(line.range, selected)
            return range.length > 0 ? source.substring(with: range) : nil
        }.joined()
    }

    func background(_ item: DiffSplitLayout.Item, muted: Bool) -> NSColor {
        switch item.kind {
        case .changed: NSColor(muted && highlightsWords ? LitheTheme.Diff.modifiedLine : LitheTheme.Diff.modified)
        case .addition: NSColor(LitheTheme.Diff.inserted)
        case .removal: NSColor(LitheTheme.Diff.deleted)
        default: NSColor(LitheTheme.Diff.background)
        }
    }
}

struct DiffNativeCodeColumn: NSViewRepresentable {
    let state: DiffNativeColumnState
    let layoutIdentity: UUID
    let items: [DiffSplitLayout.Item]
    let side: DiffSide
    let fileExtension: String
    let highlightsWords: Bool
    let selectedRowIDs: Set<DiffRowID>
    let currentSearchMatchID: DiffRowID?
    var unified = false
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> DiffNativeTextView {
        let view = DiffNativeTextView(frame: .zero)
        view.column = state
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: DiffLayoutMetrics.textHorizontalPadding, height: 0)
        view.textContainer?.lineFragmentPadding = 0
        // Native selection/layout stay mounted. The split only clips this fixed
        // text container, like IDEA resizing existing editors with setBounds.
        view.textContainer?.widthTracksTextView = false
        // ponytail: lines wider than one million points are clipped; grow this
        // fixed ceiling on input changes if such files become a product requirement.
        view.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.delegate = view
        view.setAccessibilityLabel(side == .left ? "Original diff code" : "Modified diff code")
        return view
    }

    func updateNSView(_ view: DiffNativeTextView, context: Context) {
        state.prepare(identity: layoutIdentity, items: items, side: side,
            fileExtension: fileExtension, highlightsWords: highlightsWords, dark: colorScheme == .dark, unified: unified)
        state.currentSearchID = currentSearchMatchID
        view.selectedTextAttributes = [.backgroundColor: NSColor(LitheTheme.Diff.selection)]
        if view.appliedRevision != state.revision {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(state.preparedText)
            let start = min(selection.location, view.string.utf16.count)
            view.setSelectedRange(NSRange(location: start, length: min(selection.length, view.string.utf16.count - start)))
            view.appliedRevision = state.revision
        }
        view.needsDisplay = true
    }
}

final class DiffNativeTextView: NSTextView, NSTextViewDelegate {
    var column: DiffNativeColumnState?
    var appliedRevision = -1
    private let menuPresenter = LitheContextMenuPresenter()

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        column?.hasCaret = accepted
        column?.gutter?.needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { column?.hasCaret = false; column?.gutter?.needsDisplay = true }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let column else { super.draw(dirtyRect); return }
        NSColor(LitheTheme.Diff.background).setFill()
        dirtyRect.fill()
        let first = column.firstVisibleLine(at: dirtyRect.minY)
        for line in column.lines[first...] {
            let item = line.item
            guard item.top < dirtyRect.maxY else { break }
            // Adjacent row rectangles must share an opaque pixel edge even
            // when the clip view is scrolled by a fractional point.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            column.background(item, muted: true).setFill()
            NSRect(x: dirtyRect.minX, y: item.top, width: dirtyRect.width, height: item.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            if case let .row(row, _) = item.displayRow {
                if column.currentSearchID == row.id {
                    NSColor.systemYellow.setStroke()
                    NSBezierPath(rect: NSRect(x: 0.5, y: item.top + 0.5,
                        width: max(0, bounds.width - 1), height: item.height - 1)).stroke()
                }
            }
        }
        super.draw(dirtyRect)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let column else { return }
        var index = NSMaxRange(selectedRange())
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged || event.type == .leftMouseDown {
            index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        }
        column.caretLine = column.line(atCharacter: index)
        column.gutter?.needsDisplay = true
    }

    override func copy(_ sender: Any?) {
        guard let column else { return }
        let text = column.selectedSource(in: selectedRange())
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window else { return nil }
        var item = LitheContextMenuItem.action("Copy", shortcut: "⌘C",
            isEnabled: selectedRange().length > 0) { [weak self] in self?.copy(nil) }
        item.icon = AnyView(LitheIDEAIcon(resourcePath: "expui/general/copy", size: 16, preservesOriginalColors: true))
        menuPresenter.show(items: [item], at: window.convertPoint(toScreen: event.locationInWindow),
            appearance: effectiveAppearance, locale: Locale.current, parentWindow: window)
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { menuPresenter.dismiss() }
    }

}

struct DiffNativeLineNumbers: NSViewRepresentable {
    let state: DiffNativeColumnState
    var showsBothNumbers = false
    var mirrored = false
    func makeNSView(context: Context) -> DiffNativeGutterView {
        let view = DiffNativeGutterView()
        view.column = state
        state.gutter = view
        return view
    }
    func updateNSView(_ view: DiffNativeGutterView, context: Context) {
        view.showsBothNumbers = showsBothNumbers
        view.mirrored = mirrored
        view.needsDisplay = true
    }
}

final class DiffNativeGutterView: NSView {
    var showsBothNumbers = false
    var mirrored = false
    var column: DiffNativeColumnState?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let column else { return }
        NSColor(LitheTheme.Diff.background).setFill()
        dirtyRect.fill()
        // New UI's whitespace separator is 3pt inside the code edge. Diff
        // line markers paint over it and use editor-mode color in that edge.
        let edgeWidth = DiffLayoutMetrics.gutterCodeEdgeWidth
        let separatorX = mirrored ? edgeWidth - 1 : bounds.width - edgeWidth
        NSColor(LitheTheme.Diff.separator).setFill()
        NSRect(x: separatorX, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        let first = column.firstVisibleLine(at: dirtyRect.minY)
        let font = LitheTheme.editorFont(size: DiffLayoutMetrics.textFontSize)
        for index in first..<column.lines.count {
            let line = column.lines[index]
            guard line.item.top < dirtyRect.maxY else { break }
            if line.item.kind.isSplitDifference {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.shouldAntialias = false
                column.background(line.item, muted: false).setFill()
                NSRect(x: 0, y: line.item.top, width: bounds.width, height: line.item.height).fill()
                column.background(line.item, muted: true).setFill()
                NSRect(x: mirrored ? 0 : bounds.width - edgeWidth, y: line.item.top,
                       width: edgeWidth, height: line.item.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let numbers: [Int?]
            if showsBothNumbers, case let .row(row, _) = line.item.displayRow {
                numbers = [line.item.kind == .addition ? nil : row.oldLine,
                           line.item.kind == .removal ? nil : row.newLine]
            } else { numbers = [line.sourceNumber] }
            for (columnIndex, number) in numbers.enumerated() {
                guard let number else { continue }
                let text = NSAttributedString(string: String(number), attributes: [.font: font,
                    .foregroundColor: NSColor(column.hasCaret && index == column.caretLine
                        ? LitheTheme.Diff.caretLineNumber : LitheTheme.Diff.lineNumber)])
                let size = text.size()
                let rightEdge = showsBothNumbers ? CGFloat(columnIndex + 1) * bounds.width / 2
                    : mirrored ? bounds.width : bounds.width - DiffLayoutMetrics.lineNumberChromeWidth
                        + 2 * DiffLayoutMetrics.lineNumberTrailingPadding
                text.draw(at: NSPoint(x: rightEdge - DiffLayoutMetrics.lineNumberTrailingPadding - size.width,
                    y: line.item.top + (line.item.height - size.height) / 2))
            }
        }
    }
}

/// Paint only the dirty viewport; a long Diff must not create a full-height
/// Canvas backing image or traverse every off-screen change during resizing.
final class DiffNativeTransitionsView: NSView {
    var transitions: [DiffSplitLayout.Transition] = []
    var leftOffset: CGFloat = 0
    var rightOffset: CGFloat = 0
    var leftX: CGFloat = 0
    var rightX: CGFloat = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        guard rightX > leftX else { return }
        var low = 0, high = transitions.count
        while low < high {
            let mid = (low + high) / 2
            let transition = transitions[mid]
            if max(transition.leftRange.upperBound - leftOffset, transition.rightRange.upperBound - rightOffset) < dirtyRect.minY {
                low = mid + 1
            } else { high = mid }
        }
        for index in low..<transitions.count {
            let transition = transitions[index]
            if min(transition.leftRange.lowerBound - leftOffset, transition.rightRange.lowerBound - rightOffset) > dirtyRect.maxY { break }
            let path = NSBezierPath()
            let c1 = leftX + (rightX - leftX) * 0.3
            let c2 = leftX + (rightX - leftX) * 0.7
            // DividerPolygon converts exclusive line ends to inclusive pixels
            // before drawCurveTrapezium adds one back. Nonempty edges must stop
            // exactly at the adjacent gutter's row boundary.
            let leftEmpty = transition.leftRange.lowerBound == transition.leftRange.upperBound
            let rightEmpty = transition.rightRange.lowerBound == transition.rightRange.upperBound
            let leftTop = transition.leftRange.lowerBound - leftOffset - (leftEmpty ? 1 : 0)
            let rightTop = transition.rightRange.lowerBound - rightOffset - (rightEmpty ? 1 : 0)
            let leftBottom = transition.leftRange.upperBound - leftOffset + (leftEmpty ? 1 : 0)
            let rightBottom = transition.rightRange.upperBound - rightOffset + (rightEmpty ? 1 : 0)
            path.move(to: NSPoint(x: leftX, y: leftTop))
            path.curve(to: NSPoint(x: rightX, y: rightTop),
                controlPoint1: NSPoint(x: c1, y: leftTop), controlPoint2: NSPoint(x: c2, y: rightTop))
            path.line(to: NSPoint(x: rightX, y: rightBottom))
            path.curve(to: NSPoint(x: leftX, y: leftBottom),
                controlPoint1: NSPoint(x: c2, y: rightBottom), controlPoint2: NSPoint(x: c1, y: leftBottom))
            path.close()
            NSColor(transition.isAddition ? LitheTheme.Diff.inserted : transition.isRemoval
                ? LitheTheme.Diff.deleted : LitheTheme.Diff.modified).setFill()
            path.fill()
            // DiffDrawUtil.drawCurveTrapezium keeps steep/empty-edge chunks at
            // least one logical pixel thick, including the flattened state.
            let center = NSBezierPath()
            let leftY = (transition.leftRange.lowerBound + transition.leftRange.upperBound) / 2 - leftOffset
            let rightY = (transition.rightRange.lowerBound + transition.rightRange.upperBound) / 2 - rightOffset
            center.move(to: NSPoint(x: leftX, y: leftY))
            center.curve(to: NSPoint(x: rightX, y: rightY),
                controlPoint1: NSPoint(x: c1, y: leftY), controlPoint2: NSPoint(x: c2, y: rightY))
            center.lineWidth = 1; NSColor(transition.isAddition ? LitheTheme.Diff.inserted
                : transition.isRemoval ? LitheTheme.Diff.deleted : LitheTheme.Diff.modified).setStroke()
            center.stroke()
            if transition.isAddition || transition.isRemoval {
                NSColor(transition.isAddition ? LitheTheme.Diff.inserted : LitheTheme.Diff.deleted).setFill()
                NSRect(x: transition.isAddition ? 0 : rightX,
                    y: transition.isAddition ? transition.leftRange.lowerBound - leftOffset : transition.rightRange.lowerBound - rightOffset,
                    width: max(0, transition.isAddition ? leftX : bounds.width - rightX), height: 1).fill()
            }
        }
    }
}
