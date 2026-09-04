import AppKit
import SwiftUI

struct GitWorktreeRowsSnapshot: Equatable, Sendable {
    enum Identity: Equatable, Sendable {
        case changes(inspectionVersion: Int)
        case history(inspectionVersion: Int, query: String)
    }

    enum StatusColor: Equatable, Sendable {
        case success
        case warning
        case error
    }

    enum Row: Equatable, Sendable {
        case change(status: String, path: String, isStaged: Bool, color: StatusColor)
        case commit(subject: String, author: String, date: String)
    }

    let identity: Identity
    let rows: [Row]
}

struct GitWorktreeRowsView: NSViewRepresentable {
    static let rowHeight: CGFloat = 35

    let snapshot: GitWorktreeRowsSnapshot

    func makeNSView(context: Context) -> GitWorktreeRowsNSView {
        GitWorktreeRowsNSView()
    }

    func updateNSView(_ nsView: GitWorktreeRowsNSView, context: Context) {
        nsView.update(snapshot: snapshot, rowHeight: Self.rowHeight)
    }
}

/// A single native drawing surface replaces one SwiftUI subtree per row. Its
/// dirty-rect range is the scrolling contract: moving the viewport visits only
/// the visible rows rather than rebuilding the entire Worktree section.
final class GitWorktreeRowsNSView: NSView {
    private var snapshot = GitWorktreeRowsSnapshot(
        identity: .changes(inspectionVersion: 0),
        rows: []
    )
    private var rowHeight = GitWorktreeRowsView.rowHeight
    private var drawingStyle: DrawingStyle?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(snapshot: GitWorktreeRowsSnapshot, rowHeight: CGFloat) {
        guard self.snapshot.identity != snapshot.identity
                || self.rowHeight != rowHeight else { return }
        self.snapshot = snapshot
        self.rowHeight = rowHeight
        setAccessibilityLabel(snapshot.accessibilityLabel)
        setAccessibilityValue(String(
            format: String(localized: "%lld rows"),
            snapshot.rows.count
        ))
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawingStyle = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let range = Self.visibleRowRange(
                rowCount: snapshot.rows.count,
                rowHeight: rowHeight,
                dirtyRect: dirtyRect
              ) else { return }
        let style = resolvedDrawingStyle()
        context.setShouldAntialias(true)

        for index in range {
            let rowRect = CGRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: bounds.width,
                height: rowHeight
            )
            switch snapshot.rows[index] {
            case let .change(status, path, isStaged, color):
                drawChange(
                    status: status,
                    path: path,
                    isStaged: isStaged,
                    color: color,
                    in: rowRect,
                    style: style
                )
            case let .commit(subject, author, date):
                drawCommit(
                    subject: subject,
                    author: author,
                    date: date,
                    in: rowRect,
                    style: style,
                    context: context
                )
            }
            context.setFillColor(style.divider.cgColor)
            context.fill(CGRect(x: 0, y: rowRect.maxY - 1, width: rowRect.width, height: 1))
        }
    }

    static func visibleRowRange(
        rowCount: Int,
        rowHeight: CGFloat,
        dirtyRect: CGRect
    ) -> ClosedRange<Int>? {
        guard rowCount > 0, rowHeight > 0, !dirtyRect.isEmpty else { return nil }
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last = min(rowCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        return first <= last ? first...last : nil
    }

    private func drawChange(
        status: String,
        path: String,
        isStaged: Bool,
        color: GitWorktreeRowsSnapshot.StatusColor,
        in rect: CGRect,
        style: DrawingStyle
    ) {
        let stageText = isStaged ? String(localized: "Staged") : String(localized: "Unstaged")
        let stageWidth: CGFloat = 78
        drawText(
            status,
            in: CGRect(x: 2, y: rect.minY, width: 22, height: rect.height),
            font: style.monospacedFont,
            color: style.statusColor(color),
            lineBreakMode: .byClipping,
            alignment: .center
        )
        drawText(
            path,
            in: CGRect(
                x: 32,
                y: rect.minY,
                width: max(0, rect.width - 32 - stageWidth - 8),
                height: rect.height
            ),
            font: style.bodyFont,
            color: style.primaryText,
            lineBreakMode: .byTruncatingMiddle
        )
        drawText(
            stageText,
            in: CGRect(x: max(32, rect.maxX - stageWidth), y: rect.minY, width: stageWidth - 8, height: rect.height),
            font: style.metadataFont,
            color: style.secondaryText,
            lineBreakMode: .byTruncatingTail,
            alignment: .right
        )
    }

    private func drawCommit(
        subject: String,
        author: String,
        date: String,
        in rect: CGRect,
        style: DrawingStyle,
        context: CGContext
    ) {
        let dotSize: CGFloat = 7
        context.setFillColor(style.accent.cgColor)
        context.fillEllipse(in: CGRect(
            x: 3,
            y: rect.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        ))
        let authorWidth: CGFloat = 116
        let dateWidth: CGFloat = 128
        let subjectX: CGFloat = 20
        drawText(
            subject,
            in: CGRect(
                x: subjectX,
                y: rect.minY,
                width: max(0, rect.width - subjectX - authorWidth - dateWidth - 16),
                height: rect.height
            ),
            font: style.bodyMediumFont,
            color: style.primaryText,
            lineBreakMode: .byTruncatingTail
        )
        drawText(
            author,
            in: CGRect(
                x: max(subjectX, rect.maxX - authorWidth - dateWidth - 8),
                y: rect.minY,
                width: authorWidth,
                height: rect.height
            ),
            font: style.metadataFont,
            color: style.secondaryText,
            lineBreakMode: .byTruncatingTail
        )
        drawText(
            date,
            in: CGRect(x: max(subjectX, rect.maxX - dateWidth), y: rect.minY, width: dateWidth - 8, height: rect.height),
            font: style.metadataFont,
            color: style.secondaryText,
            lineBreakMode: .byTruncatingTail,
            alignment: .right
        )
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode,
        alignment: NSTextAlignment = .left
    ) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.alignment = alignment
        let height = ceil(font.ascender - font.descender)
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        )
        (text as NSString).draw(
            in: textRect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func resolvedDrawingStyle() -> DrawingStyle {
        if let drawingStyle { return drawingStyle }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let style = DrawingStyle(isDark: isDark)
        drawingStyle = style
        return style
    }

    private struct DrawingStyle {
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let bodyMediumFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let metadataFont = NSFont.systemFont(ofSize: 12.5)
        let monospacedFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let primaryText: NSColor
        let secondaryText: NSColor
        let accent: NSColor
        let success: NSColor
        let warning: NSColor
        let error: NSColor
        let divider: NSColor

        init(isDark: Bool) {
            primaryText = LitheTheme.nsColor(.primaryText, isDark: isDark)
            secondaryText = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            accent = LitheTheme.nsColor(.accent, isDark: isDark)
            success = LitheTheme.nsColor(.success, isDark: isDark)
            warning = LitheTheme.nsColor(.warning, isDark: isDark)
            error = LitheTheme.nsColor(.error, isDark: isDark)
            divider = LitheTheme.nsColor(.divider, isDark: isDark)
        }

        func statusColor(_ color: GitWorktreeRowsSnapshot.StatusColor) -> NSColor {
            switch color {
            case .success: success
            case .warning: warning
            case .error: error
            }
        }
    }
}

private extension GitWorktreeRowsSnapshot {
    var accessibilityLabel: String {
        switch identity {
        case .changes: String(localized: "Worktree changes")
        case .history: String(localized: "Worktree commit history")
        }
    }
}
