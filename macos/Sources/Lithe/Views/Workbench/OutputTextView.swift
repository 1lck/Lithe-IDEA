import AppKit
import SwiftUI

// MARK: - 输出文本视图(ANSI 着色 + 可点击错误定位 + 智能滚动 + 一键复制)

/// 构建/运行输出的统一渲染视图:
/// - 支持 ANSI 转义序列着色(复用终端渲染器)
/// - Maven 错误行 `[ERROR] path:[line,col]` 与 Java 堆栈行 `at x.y.Foo.bar(Foo.java:42)` 可点击跳转源码
/// - 智能滚动:用户上翻后不强制拉底,并显示 "Jump to latest" 按钮
/// - 右上角一键复制全部输出
/// - 可选自动换行:调用方提供切换回调时,右键菜单附带「自动换行」勾选项
enum ConsoleToolbarAction: String, CaseIterable, Identifiable {
    case previous, next, softWraps, scrollToEnd, printOutput, clear
    var id: Self { self }
    var asset: String {
        switch self {
        case .previous: "expui/general/up.svg"
        case .next: "expui/general/down.svg"
        case .softWraps: "expui/general/softWrap.svg"
        case .scrollToEnd: "expui/general/scrollDown.svg"
        case .printOutput: "expui/general/print.svg"
        case .clear: "expui/general/delete.svg"
        }
    }
    var title: String {
        switch self {
        case .previous: "Previous Stack Trace"
        case .next: "Next Stack Trace"
        case .softWraps: "Use soft wraps"
        case .scrollToEnd: "Scroll to the End"
        case .printOutput: "Print"
        case .clear: "Clear Console"
        }
    }
}

struct ConsoleToolbarRequest {
    let id = UUID()
    let action: ConsoleToolbarAction
}

struct OutputTextView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchHasBackgroundImage) private var hasBackgroundImage
    let output: String
    let searchRoots: [URL]
    /// Build Output attributes lines to several commands; a relative path
    /// matching more than one root gets no link rather than a guess.
    var resolvesRelativePathsUniquely = false
    let fileExists: (URL) -> Bool
    let emptyMessage: String
    /// Wraps lines to the pane width; off keeps each line on one row with
    /// horizontal scrolling, the historical behavior of every output pane.
    var wrapsLines = false
    var showsConsoleToolbar = false
    var consoleToolbarPlacement: HorizontalEdge = .leading
    var onClearOutput: (() -> Void)? = nil
    var fontSize: CGFloat = LitheConsoleStyle.defaultFontSize
    private let usesIDEAConsoleStyle = true
    var consolePresentation: ConsoleFoldPresentation? = nil
    var standardInputSessionID: UUID? = nil
    var onSubmitStandardInput: ((String) -> Bool)? = nil
    var decorateOutput: ((NSMutableAttributedString, Bool) -> Void)?
    /// Adds a soft-wrap toggle to the context menu. Callers that do not own a
    /// wrap preference leave it nil and keep the plain text menu.
    var onToggleWrapsLines: (() -> Void)?
    let onOpenLocation: (URL, Int, Int?) -> Void

    @State private var consoleToolbarRequest: ConsoleToolbarRequest?
    @State private var hasConsoleOccurrences = false
    @State private var isAtBottom = true
    @State private var scrollToLatestRequest = 0

    private static let bottomThreshold: CGFloat = 80

    var body: some View {
        HStack(spacing: 0) {
            if showsConsoleToolbar && consoleToolbarPlacement == .leading {
                consoleToolbar
                Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme)).frame(width: 1)
            }
        OutputTextStorageView(
            output: output,
            searchRoots: searchRoots,
            fileExists: fileExists,
            emptyMessage: emptyMessage,
            theme: LitheTheme.activeTheme,
            wrapsLines: wrapsLines,
            usesIDEAConsoleStyle: usesIDEAConsoleStyle,
            consolePresentation: consolePresentation,
            standardInputSessionID: standardInputSessionID,
            onSubmitStandardInput: onSubmitStandardInput,
            fontSize: fontSize,
            onToggleWrapsLines: onToggleWrapsLines,
            scrollToLatestRequest: scrollToLatestRequest,
            bottomThreshold: Self.bottomThreshold,
            copyButton: AnyView(copyButton),
            consoleToolbarRequest: consoleToolbarRequest,
            onConsoleOccurrencesChange: { hasConsoleOccurrences = $0 },
            render: { source, roots, exists, dark, theme, size in
                let rendered = NSMutableAttributedString(attributedString: Self.renderOutput(source, searchRoots: roots, resolvesRelativePathsUniquely: resolvesRelativePathsUniquely, fileExists: exists, isDark: dark, theme: theme, fontSize: size, usesIDEAConsoleStyle: usesIDEAConsoleStyle))
                decorateOutput?(rendered, dark)
                return rendered
            },
            onOpenLocation: onOpenLocation,
            onBottomStateChange: { isAtBottom = $0 }
        )
            .litheWorkbenchSurface(LitheTheme.editor, hasBackgroundImage: hasBackgroundImage)
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    jumpToLatestButton
                        .padding(10)
                }
            }
            if showsConsoleToolbar && consoleToolbarPlacement == .trailing {
                Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme)).frame(width: 1)
                consoleToolbar
            }
        }
    }

    private var consoleToolbar: some View {
        VStack(spacing: LitheTheme.ActionStripe.spacing) {
            ForEach(ConsoleToolbarAction.allCases) { action in
                Button {
                    switch action {
                    case .softWraps: onToggleWrapsLines?()
                    case .clear: onClearOutput?()
                    default: consoleToolbarRequest = ConsoleToolbarRequest(action: action)
                    }
                } label: {
                    LitheIDEAIcon(resourcePath: action.asset, size: LitheTheme.ActionStripe.iconSize, preservesOriginalColors: true,
                                  usesIDEADisabledAppearance: true)
                }
                .buttonStyle(LitheIconButtonStyle(size: LitheTheme.ActionStripe.buttonSize, disabledOpacity: 1,
                    cornerRadius: LitheTheme.ActionStripe.cornerRadius,
                    isSelected: action == .softWraps && wrapsLines))
                .disabled(action == .previous || action == .next ? !hasConsoleOccurrences
                    : action == .softWraps ? onToggleWrapsLines == nil
                    : action == .clear ? onClearOutput == nil || output.isEmpty : output.isEmpty)
                .workbenchHoverHelp(Text(LocalizedStringKey(action.title)), placement: consoleToolbarPlacement == .leading ? .trailing : .leading)
                .accessibilityLabel(LocalizedStringKey(action.title))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, LitheTheme.ActionStripe.topInset)
        .frame(width: LitheTheme.ActionStripe.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .litheWorkbenchSurface(LitheTheme.sidebar, hasBackgroundImage: hasBackgroundImage)
    }

    // MARK: - 渲染

    static func renderOutput(
        _ source: String,
        searchRoots: [URL],
        resolvesRelativePathsUniquely: Bool = false,
        fileExists: @escaping (URL) -> Bool,
        isDark: Bool,
        theme: AppColorTheme,
        fontSize: CGFloat = LitheConsoleStyle.defaultFontSize,
        usesIDEAConsoleStyle: Bool = false
    ) -> NSAttributedString {
        let defaultForeground = usesIDEAConsoleStyle ? LitheConsoleStyle.foreground(dark: isDark)
            : LitheTheme.nsColor(.primaryText, theme: theme, isDark: isDark)
        let parsed = ANSIOutputRenderer.parse(source, defaultForeground: defaultForeground,
            palette: usesIDEAConsoleStyle ? LitheConsoleStyle.palette(dark: isDark) : nil)
        guard !parsed.cleanText.isEmpty else { return NSAttributedString() }
        var result = ANSIOutputRenderer.render(parsed, fontSize: fontSize)
        if usesIDEAConsoleStyle {
            LitheConsoleStyle.normalizeLogLevels(in: result, dark: isDark)
            result.addAttribute(.paragraphStyle, value: LitheConsoleStyle.paragraphStyle(fontSize: fontSize),
                range: NSRange(location: 0, length: result.length))
        }
        if !usesIDEAConsoleStyle {
            dimTimestamps(in: &result, text: parsed.cleanText, theme: theme, isDark: isDark)
        }
        for location in matchLocations(
            in: parsed.cleanText,
            searchRoots: searchRoots,
            resolvesRelativePathsUniquely: resolvesRelativePathsUniquely,
            fileExists: fileExists
        ) {
            let range = NSRange(location.range, in: parsed.cleanText)
            result.addAttribute(
                .link,
                value: locationURL(path: location.url.path, line: location.line, column: location.column),
                range: range
            )
            result.addAttribute(.foregroundColor, value: usesIDEAConsoleStyle
                ? LitheConsoleStyle.hyperlink(dark: isDark)
                : resolvedColor(location.kind == .warning ? .warning : .error, theme: theme, isDark: isDark), range: range)
            if usesIDEAConsoleStyle {
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }

    private static func resolvedColor(
        _ token: LitheTheme.ResolvedColorToken,
        theme: AppColorTheme,
        isDark: Bool
    ) -> NSColor {
        LitheTheme.nsColor(token, theme: theme, isDark: isDark)
    }

    /// Recedes timestamps only in legacy output panes; console producer styling is unchanged.
    private static func dimTimestamps(
        in result: inout NSMutableAttributedString,
        text: String,
        theme: AppColorTheme,
        isDark: Bool
    ) {
        var stamps: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { substring, lineRange, _, _ in
            guard let line = substring,
                  let length = OutputTimestamper.leadingTimeLength(of: line) else { return }
            let end = text.index(
                lineRange.lowerBound,
                offsetBy: length,
                limitedBy: lineRange.upperBound
            ) ?? lineRange.upperBound
            stamps.append(lineRange.lowerBound..<end)
        }
        for stamp in stamps {
            result.addAttribute(
                .foregroundColor,
                value: resolvedColor(.secondaryText, theme: theme, isDark: isDark).withAlphaComponent(0.7),
                range: NSRange(stamp, in: text)
            )
        }
    }

    // MARK: - 错误位置匹配

    private struct OutputLocation {
        enum Kind { case error, warning, stack }
        let range: Range<String.Index>
        let kind: Kind
        let url: URL
        let line: Int
        let column: Int?
    }

    private static let mavenExpression = try! NSRegularExpression(
        pattern: #"\[(ERROR|WARNING)\]\s+(.+?):\[(\d+)(?:,(\d+))?\]"#
    )

    private static let stackExpression = try! NSRegularExpression(
        pattern: #"\bat\s+([\w.$]+(?:\$[\w$]+)?)\.([\w$<>]+)\(([\w$]+\.java):(\d+)\)"#
    )

    private static func matchLocations(
        in text: String,
        searchRoots: [URL],
        resolvesRelativePathsUniquely: Bool,
        fileExists: @escaping (URL) -> Bool
    ) -> [OutputLocation] {
        guard !searchRoots.isEmpty else { return [] }
        var locations: [OutputLocation] = []

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { substring, lineRange, _, _ in
            guard let line = substring, !line.isEmpty else { return }
            let lineNSRange = NSRange(line.startIndex..<line.endIndex, in: line)

            if let match = mavenExpression.firstMatch(in: line, range: lineNSRange),
               let path = capture(match, at: 2, in: line),
               let lineNumber = capture(match, at: 3, in: line).flatMap(Int.init) {
                let column = capture(match, at: 4, in: line).flatMap(Int.init)
                guard let url = resolvePath(
                    path,
                    searchRoots: searchRoots,
                    requiresUniqueMatch: resolvesRelativePathsUniquely,
                    fileExists: fileExists
                ) else { return }
                let kind: OutputLocation.Kind = capture(match, at: 1, in: line) == "ERROR" ? .error : .warning
                locations.append(OutputLocation(
                    range: lineRange,
                    kind: kind,
                    url: url,
                    line: lineNumber,
                    column: column
                ))
                return
            }

            if let match = stackExpression.firstMatch(in: line, range: lineNSRange),
               let className = capture(match, at: 1, in: line),
               let lineNumber = capture(match, at: 4, in: line).flatMap(Int.init),
               let url = resolveClassFile(
                   className,
                   searchRoots: searchRoots,
                   requiresUniqueMatch: resolvesRelativePathsUniquely,
                   fileExists: fileExists
               ),
               let fileRange = Range(match.range(at: 3), in: line),
               let lineNumberRange = Range(match.range(at: 4), in: line) {
                // 仅把 `Foo.java:42` 部分设为可点击链接(覆盖文件名与行号)
                let start = text.index(lineRange.lowerBound, offsetBy: text.distance(from: line.startIndex, to: fileRange.lowerBound))
                let end = text.index(lineRange.lowerBound, offsetBy: text.distance(from: line.startIndex, to: lineNumberRange.upperBound))
                locations.append(OutputLocation(
                    range: start..<end,
                    kind: .stack,
                    url: url,
                    line: lineNumber,
                    column: nil
                ))
            }
        }
        return locations
    }

    private static func capture(_ match: NSTextCheckingResult, at index: Int, in line: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
        return String(line[swiftRange])
    }

    /// Resolves a relative location against the roots of the commands that
    /// wrote this output. A path that exists under several roots is ambiguous,
    /// so it gets no link instead of opening another project's file.
    static func resolvePath(
        _ path: String,
        searchRoots: [URL],
        requiresUniqueMatch: Bool = false,
        fileExists: (URL) -> Bool
    ) -> URL? {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return fileExists(url) ? url : nil
        }
        var matches: [URL] = []
        for root in searchRoots {
            let url = root.appendingPathComponent(path).standardizedFileURL
            if fileExists(url) {
                if !requiresUniqueMatch { return url }
                if !matches.contains(where: { $0.path == url.path }) { matches.append(url) }
            }
        }
        return requiresUniqueMatch && matches.count == 1 ? matches[0] : nil
    }

    /// 根据 Java 类全名(如 com.example.Foo)推断 Maven 源码路径并定位存在的文件。
    static func resolveClassFile(
        _ className: String,
        searchRoots: [URL],
        requiresUniqueMatch: Bool = false,
        fileExists: (URL) -> Bool
    ) -> URL? {
        let outerClassName = className.split(separator: "$", maxSplits: 1).first.map(String.init) ?? className
        let relativePath = outerClassName.replacingOccurrences(of: ".", with: "/") + ".java"
        let candidates = ["src/main/java/", "src/test/java/"].map { $0 + relativePath }
        var matches: [URL] = []
        for root in searchRoots {
            for candidate in candidates {
                let url = root.appendingPathComponent(candidate).standardizedFileURL
                if fileExists(url) {
                    if !requiresUniqueMatch { return url }
                    if !matches.contains(where: { $0.path == url.path }) { matches.append(url) }
                }
            }
        }
        return requiresUniqueMatch && matches.count == 1 ? matches[0] : nil
    }

    // MARK: - 链接编码

    private static func locationURL(path: String, line: Int, column: Int?) -> URL {
        var components = URLComponents()
        components.scheme = "lithe-open"
        components.host = "file"
        var items = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "line", value: String(line))
        ]
        if let column {
            items.append(URLQueryItem(name: "col", value: String(column)))
        }
        components.queryItems = items
        return components.url!
    }

    fileprivate static func location(from url: URL) -> (url: URL, line: Int, column: Int?)? {
        guard url.scheme == "lithe-open", url.host == "file",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              let lineValue = components.queryItems?.first(where: { $0.name == "line" })?.value,
              let line = Int(lineValue) else { return nil }
        let column = components.queryItems?.first(where: { $0.name == "col" })?.value.flatMap(Int.init)
        return (URL(fileURLWithPath: path), line, column)
    }

    // MARK: - 悬浮控件

    private var copyButton: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // 复制不含 ANSI 转义码的纯文本
            pasteboard.setString(ANSIOutputRenderer.parse(output).cleanText, forType: .string)
        } label: {
            LitheIDEAIcon(resourcePath: "expui/general/copy.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
        }
        .litheToolbarIconButton(isEnabled: !output.isEmpty)
        .accessibilityLabel("Copy output")
        .help("Copy output")
    }

    private var jumpToLatestButton: some View {
        Button {
            scrollToLatestRequest &+= 1
            isAtBottom = true
        } label: {
            LitheIDEAIcon(resourcePath: "expui/general/scrollDown.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
        }
        .litheToolbarIconButton()
        .accessibilityLabel("Jump to latest")
        .help("Jump to latest")
    }
}

// MARK: - Native cursor ownership for the floating Copy button

/// A real native sibling receives pointer events above NSTextView; the button still uses the shared SwiftUI style.
final class OutputCopyButtonHost: NSHostingView<AnyView> {
    private var pointerTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); pointerTracking = area
    }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) {
        guard LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) else { return }
        NSCursor.arrow.set()
    }
    override func mouseEntered(with event: NSEvent) {
        guard LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) else { return }
        super.mouseEntered(with: event); NSCursor.arrow.set()
    }
    override func mouseMoved(with event: NSEvent) {
        guard LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) else { return }
        super.mouseMoved(with: event); NSCursor.arrow.set()
    }
}

final class OutputNativeScrollView: NSScrollView {
    var copyButtonHost: OutputCopyButtonHost?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let copyButtonHost, copyButtonHost.frame.contains(local) { return copyButtonHost.hitTest(local) }
        return super.hitTest(point)
    }
    override func layout() {
        super.layout()
        if let copyButtonHost {
            let size = NSSize(width: copyButtonHost.fittingSize.width, height: LitheTheme.Metrics.toolbarIconButtonSize)
            copyButtonHost.frame = NSRect(x: bounds.maxX - size.width - 8,
                y: isFlipped ? bounds.minY + 8 : bounds.maxY - size.height - 8, width: size.width, height: size.height)
        }
        if let text = documentView { window?.invalidateCursorRects(for: text) }
    }
}

final class OutputNativeTextView: NSTextView {
    var onToggleConsoleFold: ((String) -> Void)?
    var consoleFoldImage: (String) -> NSImage? = { LitheIcons.ideaImage(resourcePath: $0) }

    // Only visible characters participate in gutter drawing and pointer hit testing.
    func consoleFoldAnchors() -> [(rect: NSRect, id: String, isExpanded: Bool)] {
        guard usesIDEAConsoleStyle, let storage = textStorage, let layout = layoutManager,
              let container = textContainer, storage.length > 0 else { return [] }
        let origin = textContainerOrigin
        let viewport = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: viewport, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var anchors: [(NSRect, String, Bool)] = []
        storage.enumerateAttributes(in: characters) { attributes, range, _ in
            let expandedID = attributes[.consoleExpandedFoldID] as? String
            let link = attributes[.link] as? URL
            guard let id = expandedID ?? (link?.scheme == "lithe-console-fold" ? link?.lastPathComponent : nil) else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0, glyphRange.location < layout.numberOfGlyphs else { return }
            let line = layout.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            anchors.append((NSRect(x: visibleRect.minX + 1, y: floor(line.minY + origin.y + (line.height - 9) / 2 + 0.5), width: 9, height: 9), id, expandedID != nil))
        }
        return anchors
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSTextView clips its drawing to the text container. Restore the
        // caller's clip before painting markers in the left text inset.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for anchor in consoleFoldAnchors() where anchor.rect.intersects(dirtyRect) {
            let name = anchor.isExpanded ? "fold" : "unfold"
            let path = "expui/gutter/\(name)\(dark ? "_dark" : "").svg"
            guard let image = consoleFoldImage(path) else { continue }
            image.draw(in: anchor.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    func invalidateConsoleFoldGutter() {
        guard usesIDEAConsoleStyle else { return }
        setNeedsDisplay(NSRect(x: visibleRect.minX, y: visibleRect.minY,
                               width: textContainerInset.width, height: visibleRect.height))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let anchor = consoleFoldAnchors().first(where: { $0.rect.insetBy(dx: -1, dy: -3).contains(point) }) {
            onToggleConsoleFold?(anchor.id)
            return
        }
        if usesIDEAConsoleStyle && isEditable, let link = consoleLink(at: point),
           delegate?.textView?(self, clickedOnLink: link.url, at: link.index) == true { return }
        super.mouseDown(with: event)
    }

    private func consoleLink(at point: NSPoint) -> (url: URL, index: Int)? {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL else { return nil }
        return (url, index)
    }

    private func updateConsoleLinkCursor(_ event: NSEvent) -> Bool {
        guard usesIDEAConsoleStyle else { return false }
        let point = convert(event.locationInWindow, from: nil)
        if consoleFoldAnchors().contains(where: { $0.rect.insetBy(dx: -1, dy: -3).contains(point) }) {
            NSCursor.arrow.set()
            return true
        }
        guard consoleLink(at: point) != nil else { return false }
        NSCursor.pointingHand.set()
        return true
    }

    var usesIDEAConsoleStyle = false
    override func paste(_ sender: Any?) {
        if usesIDEAConsoleStyle && isEditable { pasteAsPlainText(sender) }
        else { super.paste(sender) }
    }

    override func copy(_ sender: Any?) {
        guard usesIDEAConsoleStyle, let storage = textStorage else { super.copy(sender); return }
        let range = selectedRange()
        guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return }
        let text = ConsoleFoldPresentation.copyText(storage.attributedSubstring(from: range))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    weak var copyButtonView: NSView?
    var copyButtonRect: NSRect? {
        guard let copyButtonView, let window, copyButtonView.window === window else { return nil }
        return convert(copyButtonView.bounds, from: copyButtonView)
    }
    func textCursorRects(_ rect: NSRect) -> [NSRect] {
        guard let button = copyButtonRect else { return [rect] }
        let cut = rect.intersection(button)
        guard !cut.isEmpty else { return [rect] }
        return [
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            NSRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            NSRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            NSRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)
        ].filter { !$0.isEmpty }
    }
    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        for fragment in textCursorRects(rect) { super.addCursorRect(fragment, cursor: cursor) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if LitheTextViewportLayout.isPointerHitTarget(copyButtonView, at: event.locationInWindow) { NSCursor.arrow.set() }
        else if updateConsoleLinkCursor(event) {}
        else if LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) { super.cursorUpdate(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if LitheTextViewportLayout.isPointerHitTarget(copyButtonView, at: event.locationInWindow) { NSCursor.arrow.set() }
        else if updateConsoleLinkCursor(event) {}
        else if LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) { super.mouseMoved(with: event) }
    }
    override func mouseEntered(with event: NSEvent) {
        if LitheTextViewportLayout.isPointerHitTarget(copyButtonView, at: event.locationInWindow) { NSCursor.arrow.set() }
        else if updateConsoleLinkCursor(event) {}
        else if LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) { super.mouseEntered(with: event) }
    }
}

// MARK: - AppKit output storage

enum OutputTextUpdate: Equatable {
    case unchanged
    case append(String)
    case replaceTail(length: Int, with: String)
    case trimPrefix(length: Int, append: String)
    case trimPrefixAndReplaceTail(prefixLength: Int, tailLength: Int, with: String)
    case replace

    private static let minimumSlidingOverlapBytes = 4_096

    static func plan(previous: String, next: String, previousHadANSI: Bool) -> Self {
        guard previous != next else { return .unchanged }
        guard !previous.isEmpty, !previousHadANSI else { return .replace }
        guard next.hasPrefix(previous) else {
            return slidingWindowUpdate(previous: previous, next: next) ?? .replace
        }
        guard !previous.hasSuffix("\n") else {
            return .append(String(next.dropFirst(previous.count)))
        }
        let tailStart = previous.lastIndex(of: "\n").map { previous.index(after: $0) } ?? previous.startIndex
        let previousTail = String(previous[tailStart...])
        let nextTail = String(next[tailStart...])
        let cleanTailLength = ANSIOutputRenderer.parse(previousTail).cleanText.utf16.count
        return .replaceTail(length: cleanTailLength, with: nextTail)
    }

    /// Recognizes a bounded console moving forward: `next` begins with a long
    /// suffix of `previous`, followed by newly appended output. KMP keeps the
    /// overlap search linear even when a log contains highly repetitive text.
    private static func slidingWindowUpdate(previous: String, next: String) -> Self? {
        let previousByteCount = previous.utf8.count
        let nextBytes = Array(next.utf8)
        guard previousByteCount >= minimumSlidingOverlapBytes,
              nextBytes.count >= minimumSlidingOverlapBytes else { return nil }

        var prefixLengths = Array(repeating: 0, count: nextBytes.count)
        for index in 1..<nextBytes.count {
            var candidate = prefixLengths[index - 1]
            while candidate > 0, nextBytes[index] != nextBytes[candidate] {
                candidate = prefixLengths[candidate - 1]
            }
            if nextBytes[index] == nextBytes[candidate] {
                candidate += 1
            }
            prefixLengths[index] = candidate
        }

        var overlapByteCount = 0
        for byte in previous.utf8 {
            while overlapByteCount > 0,
                  overlapByteCount == nextBytes.count || byte != nextBytes[overlapByteCount] {
                overlapByteCount = prefixLengths[overlapByteCount - 1]
            }
            if byte == nextBytes[overlapByteCount] {
                overlapByteCount += 1
            }
        }
        guard overlapByteCount >= minimumSlidingOverlapBytes,
              overlapByteCount < previousByteCount else { return nil }

        let removedByteCount = previousByteCount - overlapByteCount
        let removedUTF8End = previous.utf8.index(
            previous.utf8.startIndex,
            offsetBy: removedByteCount
        )
        let appendedUTF8Start = next.utf8.index(
            next.utf8.startIndex,
            offsetBy: overlapByteCount
        )
        guard let removedEnd = String.Index(removedUTF8End, within: previous),
              let appendedStart = String.Index(appendedUTF8Start, within: next) else { return nil }
        let removedLength = ANSIOutputRenderer.parse(String(previous[..<removedEnd]))
            .cleanText.utf16.count
        if !previous.hasSuffix("\n") {
            let previousTailStart = previous.lastIndex(of: "\n")
                .map { previous.index(after: $0) }
                ?? previous.startIndex
            let rerenderStart = previousTailStart > removedEnd ? previousTailStart : removedEnd
            guard let rerenderUTF8Start = rerenderStart.samePosition(in: previous.utf8) else {
                return nil
            }
            let retainedTailOffset = previous.utf8.distance(
                from: removedUTF8End,
                to: rerenderUTF8Start
            )
            let nextTailUTF8Start = next.utf8.index(
                next.utf8.startIndex,
                offsetBy: retainedTailOffset
            )
            guard let nextTailStart = String.Index(nextTailUTF8Start, within: next) else {
                return nil
            }
            let retainedTailLength = ANSIOutputRenderer.parse(String(previous[rerenderStart...]))
                .cleanText.utf16.count
            return .trimPrefixAndReplaceTail(
                prefixLength: removedLength,
                tailLength: retainedTailLength,
                with: String(next[nextTailStart...])
            )
        }
        return .trimPrefix(
            length: removedLength,
            append: String(next[appendedStart...])
        )
    }
}

private struct OutputTextStorageView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let output: String
    let searchRoots: [URL]
    let fileExists: (URL) -> Bool
    let emptyMessage: String
    let theme: AppColorTheme
    let wrapsLines: Bool
    let usesIDEAConsoleStyle: Bool
    let consolePresentation: ConsoleFoldPresentation?
    let standardInputSessionID: UUID?
    let onSubmitStandardInput: ((String) -> Bool)?
    let fontSize: CGFloat
    let onToggleWrapsLines: (() -> Void)?
    let scrollToLatestRequest: Int
    let bottomThreshold: CGFloat
    let copyButton: AnyView
    let consoleToolbarRequest: ConsoleToolbarRequest?
    let onConsoleOccurrencesChange: (Bool) -> Void
    let render: (String, [URL], @escaping (URL) -> Bool, Bool, AppColorTheme, CGFloat) -> NSAttributedString
    let onOpenLocation: (URL, Int, Int?) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(folds: consolePresentation ?? ConsoleFoldPresentation()) }

    func makeNSView(context: Context) -> NSScrollView {
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        let textView = OutputNativeTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.linkTextAttributes = [
            NSAttributedString.Key.foregroundColor: LitheTheme.nsColor(
                .accent,
                theme: theme,
                isDark: context.environment.colorScheme == .dark
            ),
            NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        let scrollView = OutputNativeScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        let copyHost = OutputCopyButtonHost(rootView: AnyView(copyButton.environment(\.colorScheme, colorScheme)
            .environment(\.locale, context.environment.locale).environment(\.isEnabled, context.environment.isEnabled).fixedSize()))
        scrollView.addSubview(copyHost)
        scrollView.copyButtonHost = copyHost
        textView.copyButtonView = copyHost
        LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: wrapsLines)
        context.coordinator.appliedWrapsLines = wrapsLines
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? OutputNativeScrollView)?.copyButtonHost?.rootView = AnyView(copyButton
            .environment(\.colorScheme, colorScheme).environment(\.locale, context.environment.locale)
            .environment(\.isEnabled, context.environment.isEnabled).fixedSize())
        scrollView.needsLayout = true
        context.coordinator.configureConsole(usesIDEAConsoleStyle, fontSize: fontSize)
        // The shared SwiftUI surface owns theme and wallpaper backgrounds for every output pane.
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        if usesIDEAConsoleStyle {
            context.coordinator.textView?.insertionPointColor = LitheConsoleStyle.foreground(dark: colorScheme == .dark)
        }
        context.coordinator.onOpenLocation = onOpenLocation
        context.coordinator.onBottomStateChange = onBottomStateChange
        context.coordinator.bottomThreshold = bottomThreshold
        context.coordinator.onToggleWrapsLines = onToggleWrapsLines
        context.coordinator.applyWrapsLines(wrapsLines)
        context.coordinator.apply(
            fontSize: fontSize,
            usesIDEAConsoleStyle: usesIDEAConsoleStyle,
            output: output,
            emptyMessage: emptyMessage,
            isDark: colorScheme == .dark,
            theme: theme,
            searchRoots: searchRoots,
            fileExists: fileExists,
            render: render
        )
        context.coordinator.configureStandardInput(sessionID: standardInputSessionID, onSubmit: onSubmitStandardInput)
        context.coordinator.onConsoleOccurrencesChange = onConsoleOccurrencesChange
        context.coordinator.updateConsoleOccurrenceAvailability()
        if let request = consoleToolbarRequest, context.coordinator.lastToolbarRequest != request.id {
            context.coordinator.lastToolbarRequest = request.id
            switch request.action {
            case .previous: context.coordinator.previousConsoleOccurrence(nil)
            case .next: context.coordinator.nextConsoleOccurrence(nil)
            case .scrollToEnd: context.coordinator.scrollToBottom()
            case .printOutput: context.coordinator.textView?.printView(nil)
            default: break
            }
        }
        if context.coordinator.scrollToLatestRequest != scrollToLatestRequest {
            context.coordinator.scrollToLatestRequest = scrollToLatestRequest
            context.coordinator.scrollToBottom()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var onOpenLocation: ((URL, Int, Int?) -> Void)?
        var onBottomStateChange: (@MainActor (Bool) -> Void)?
        var bottomThreshold: CGFloat = 80
        var scrollToLatestRequest = 0
        var onToggleWrapsLines: (() -> Void)?
        var lastToolbarRequest: UUID?
        var onConsoleOccurrencesChange: ((Bool) -> Void)?
        private var lastOccurrencesAvailable = false
        private var pendingOccurrenceNotification: (id: UUID, available: Bool)?
        private var lastFollowedConsoleLink: (range: NSRange, url: URL)?

        private var consoleOccurrences: [(NSRange, URL)] {
            guard let storage = textView?.textStorage else { return [] }
            var links: [(NSRange, URL)] = []
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let url = value as? URL, url.scheme == "lithe-open" { links.append((range, url)) }
            }
            return links
        }

        func updateConsoleOccurrenceAvailability() {
            let available = !consoleOccurrences.isEmpty
            guard pendingOccurrenceNotification?.available != available else { return }
            pendingOccurrenceNotification = nil
            guard available != lastOccurrencesAvailable else { return }
            let id = UUID()
            pendingOccurrenceNotification = (id, available)
            // updateNSView must return before notifying SwiftUI. Only the latest
            // render may publish, and dismantling invalidates queued delivery.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingOccurrenceNotification?.id == id else { return }
                self.pendingOccurrenceNotification = nil
                self.lastOccurrencesAvailable = available
                self.onConsoleOccurrencesChange?(available)
            }
        }

        @objc func nextConsoleOccurrence(_ sender: Any?) { navigateConsoleOccurrence(forward: true) }
        @objc func previousConsoleOccurrence(_ sender: Any?) { navigateConsoleOccurrence(forward: false) }

        private func navigateConsoleOccurrence(forward: Bool) {
            let links = consoleOccurrences
            guard !links.isEmpty, let view = textView else { return }
            let current = links.firstIndex { $0.0 == lastFollowedConsoleLink?.range && $0.1 == lastFollowedConsoleLink?.url } ?? (forward ? -1 : 0)
            let next = (current + (forward ? 1 : -1) + links.count) % links.count
            let (range, url) = links[next]
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            _ = textView(view, clickedOnLink: url, at: range.location)
        }

        private let unfoldedStorage = NSMutableAttributedString()
        private let folds: ConsoleFoldPresentation
        private var usesIDEAConsoleStyle = false
        private var consoleFontSize: CGFloat {
            get { folds.fontSize }
            set { folds.fontSize = newValue }
        }
        init(folds: ConsoleFoldPresentation) { self.folds = folds; super.init() }
        private var onSubmitStandardInput: ((String) -> Bool)?
        private var inputStart: Int?
        private var pendingInputRefresh = false
        private var refreshingInput = false

        func configureStandardInput(sessionID: UUID?, onSubmit: ((String) -> Bool)?) {
            let changedSession = folds.inputSessionID != sessionID
            let changedAvailability = (onSubmitStandardInput == nil) != (onSubmit == nil)
            if changedSession || (changedAvailability && onSubmit == nil) { textView?.unmarkText() }
            if changedSession {
                folds.inputSessionID = sessionID
                folds.inputDraft = ""
                textView?.undoManager?.removeAllActions()
            }
            onSubmitStandardInput = usesIDEAConsoleStyle ? onSubmit : nil
            textView?.isEditable = onSubmitStandardInput != nil
            textView?.allowsUndo = onSubmitStandardInput != nil
            if changedSession || changedAvailability { lastRender?() }
        }

        private var inputAttributes: [NSAttributedString.Key: Any] {
            [.font: LitheTheme.editorFont(size: consoleFontSize),
             .foregroundColor: LitheConsoleStyle.foreground(dark: renderedIsDark ?? false),
             .paragraphStyle: LitheConsoleStyle.paragraphStyle(fontSize: consoleFontSize)]
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let start = inputStart, onSubmitStandardInput != nil,
                  range.location != NSNotFound, NSMaxRange(range) <= (view.textStorage?.length ?? 0) else { return false }
            guard range.location >= start else {
                // Typing while reading old output goes to the input tail; deleting logs is never allowed.
                if let text, !text.isEmpty {
                    view.setSelectedRange(NSRange(location: (view.textStorage?.length ?? 0), length: 0))
                    view.insertText(text, replacementRange: view.selectedRange())
                }
                return false
            }
            view.typingAttributes = inputAttributes
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !refreshingInput, let view = textView, let start = inputStart,
                  start <= (view.textStorage?.length ?? 0) else { return }
            folds.inputDraft = (view.string as NSString).substring(from: start)
            if pendingInputRefresh && !view.hasMarkedText() { lastRender?() }
        }

        func textView(_ view: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSTextView.insertNewline(_:)),
                  let onSubmitStandardInput, let start = inputStart else { return false }
            guard !view.hasMarkedText() else { return false }
            let draft = (view.string as NSString).substring(from: start)
            guard onSubmitStandardInput(draft + "\n") else { return true }
            folds.inputDraft = ""
            view.undoManager?.removeAllActions()
            lastRender?()
            view.setSelectedRange(NSRange(location: (view.textStorage?.length ?? 0), length: 0))
            return true
        }

        private var baseFontSize: CGFloat = LitheConsoleStyle.defaultFontSize
        private var lastRender: (() -> Void)?

        func configureConsole(_ enabled: Bool, fontSize: CGFloat) {
            usesIDEAConsoleStyle = enabled
            baseFontSize = fontSize
            if !enabled { consoleFontSize = fontSize }
            (textView as? OutputNativeTextView)?.usesIDEAConsoleStyle = enabled
            if enabled { textView?.linkTextAttributes = [:] }
            (textView as? OutputNativeTextView)?.onToggleConsoleFold = { [weak self] id in self?.toggleFold(id) }
        }

        var appliedWrapsLines = false
        private var source = ""
        private var sourceHadANSI = false
        private var showingEmptyMessage = false
        private var renderedFontSize: CGFloat?
        private var renderedConsoleStyle: Bool?
        private var renderedTheme: AppColorTheme?
        private var renderedIsDark: Bool?
        private var isAtBottom = true
        private var boundsObserver: NSObjectProtocol?

        func detach() {
            pendingOccurrenceNotification = nil
            onConsoleOccurrencesChange = nil
            onBottomStateChange = nil
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            textView?.delegate = nil
            textView = nil
            scrollView = nil
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportBottomState()
                    (self?.textView as? OutputNativeTextView)?.invalidateConsoleFoldGutter()
                }
            }
        }

        func apply(
            fontSize: CGFloat = LitheConsoleStyle.defaultFontSize,
            usesIDEAConsoleStyle: Bool = false,
            output: String,
            emptyMessage: String,
            isDark: Bool,
            theme: AppColorTheme,
            searchRoots: [URL],
            fileExists: @escaping (URL) -> Bool,
            render: (String, [URL], @escaping (URL) -> Bool, Bool, AppColorTheme, CGFloat) -> NSAttributedString
        ) {
            guard let displayedStorage = textView?.textStorage else { return }
            let storage = usesIDEAConsoleStyle ? unfoldedStorage : displayedStorage
            if !output.hasPrefix(source) { lastFollowedConsoleLink = nil }
            let wasAtBottom = isAtBottom
            let appearanceChanged = renderedTheme != theme || renderedIsDark != isDark
                || renderedFontSize != fontSize || renderedConsoleStyle != usesIDEAConsoleStyle
            if output.isEmpty {
                guard appearanceChanged || !showingEmptyMessage || storage.string != emptyMessage else { return }
                storage.setAttributedString(NSAttributedString(
                    string: emptyMessage,
                    attributes: [
                        .font: LitheTheme.editorFont(size: consoleFontSize),
                        .foregroundColor: usesIDEAConsoleStyle ? LitheConsoleStyle.foreground(dark: isDark)
                            : LitheTheme.nsColor(.primaryText, theme: theme, isDark: isDark),
                        .paragraphStyle: usesIDEAConsoleStyle ? LitheConsoleStyle.paragraphStyle(fontSize: consoleFontSize) : NSParagraphStyle.default
                    ]
                ))
                source = ""
                sourceHadANSI = false
                showingEmptyMessage = true
            } else {
                if usesIDEAConsoleStyle, !output.hasPrefix(source) { folds.expanded.removeAll() }
                let update = appearanceChanged
                    ? OutputTextUpdate.replace
                    : OutputTextUpdate.plan(previous: source, next: output, previousHadANSI: sourceHadANSI)
                switch update {
                case .unchanged:
                    return
                case let .append(suffix):
                    let rendered = render(suffix, searchRoots, fileExists, isDark, theme, consoleFontSize)
                    storage.append(rendered)
                    sourceHadANSI = suffix.unicodeScalars.contains { $0.value == 27 }
                case let .replaceTail(length, suffix):
                    let rendered = render(suffix, searchRoots, fileExists, isDark, theme, consoleFontSize)
                    let replacementRange = NSRange(
                        location: max(0, storage.length - length),
                        length: min(length, storage.length)
                    )
                    storage.replaceCharacters(in: replacementRange, with: rendered)
                    sourceHadANSI = suffix.unicodeScalars.contains { $0.value == 27 }
                case let .trimPrefix(length, suffix):
                    let rendered = render(suffix, searchRoots, fileExists, isDark, theme, consoleFontSize)
                    storage.beginEditing()
                    storage.deleteCharacters(in: NSRange(
                        location: 0,
                        length: min(length, storage.length)
                    ))
                    storage.append(rendered)
                    storage.endEditing()
                    sourceHadANSI = suffix.unicodeScalars.contains { $0.value == 27 }
                case let .trimPrefixAndReplaceTail(prefixLength, tailLength, suffix):
                    let rendered = render(suffix, searchRoots, fileExists, isDark, theme, consoleFontSize)
                    storage.beginEditing()
                    storage.deleteCharacters(in: NSRange(
                        location: 0,
                        length: min(prefixLength, storage.length)
                    ))
                    let replacementLength = min(tailLength, storage.length)
                    storage.replaceCharacters(
                        in: NSRange(
                            location: storage.length - replacementLength,
                            length: replacementLength
                        ),
                        with: rendered
                    )
                    storage.endEditing()
                    sourceHadANSI = suffix.unicodeScalars.contains { $0.value == 27 }
                case .replace:
                    if !output.hasPrefix(source) { folds.expanded.removeAll() }
                    let rendered = render(output, searchRoots, fileExists, isDark, theme, consoleFontSize)
                    storage.setAttributedString(rendered)
                    sourceHadANSI = output.unicodeScalars.contains { $0.value == 27 }
                }
                source = output
                showingEmptyMessage = false
            }
            if usesIDEAConsoleStyle {
                refreshFolds(dark: isDark, force: appearanceChanged)
                lastRender = { [weak self] in self?.refreshFolds(dark: isDark, force: true) }
            }
            renderedFontSize = fontSize
            renderedConsoleStyle = usesIDEAConsoleStyle
            renderedTheme = theme
            renderedIsDark = isDark
            if wasAtBottom { scrollToBottom() }
            reportBottomState()
        }

        private func refreshFolds(dark: Bool, force: Bool) {
            guard let view = textView, let storage = view.textStorage else { return }
            // A producer update must not replace an in-progress native IME composition.
            guard !view.hasMarkedText() else { pendingInputRefresh = true; return }
            pendingInputRefresh = false
            let selection = view.selectedRange()
            let relativeSelection = inputStart.flatMap { start -> NSRange? in
                guard selection.location >= start, selection.location != NSNotFound else { return nil }
                return NSRange(location: selection.location - start, length: selection.length)
            }
            let projected = NSMutableAttributedString(attributedString: folds.project(unfoldedStorage, dark: dark, fontSize: consoleFontSize))
            inputStart = onSubmitStandardInput == nil ? nil : projected.length
            if inputStart != nil {
                var attributes = inputAttributes
                attributes[.foregroundColor] = LitheConsoleStyle.foreground(dark: dark)
                projected.append(NSAttributedString(string: folds.inputDraft, attributes: attributes))
            }
            let prefix = force ? 0 : ConsoleFoldPresentation.firstDifference(storage, projected)
            refreshingInput = true
            defer { refreshingInput = false }
            if prefix != storage.length || prefix != projected.length {
                // ponytail: Output reflow invalidates native undo ranges. Undo is scoped to
                // edits between output updates; a draft-only undo manager can extend it.
                view.undoManager?.removeAllActions()
                storage.replaceCharacters(in: NSRange(location: prefix, length: storage.length - prefix),
                    with: projected.attributedSubstring(from: NSRange(location: prefix, length: projected.length - prefix)))
                (view as? OutputNativeTextView)?.invalidateConsoleFoldGutter()
            }
            if let start = inputStart {
                view.typingAttributes = inputAttributes
                if let relativeSelection {
                    let offset = min(relativeSelection.location, folds.inputDraft.utf16.count)
                    view.setSelectedRange(NSRange(location: start + offset,
                        length: min(relativeSelection.length, folds.inputDraft.utf16.count - offset)))
                }
            }
        }

        private func zoom(_ delta: CGFloat?) {
            let size = LitheConsoleStyle.resizedFont(current: consoleFontSize, delta: delta, defaultSize: baseFontSize)
            guard size != consoleFontSize else { return }
            consoleFontSize = size
            var fonts: [(NSRange, NSFont)] = []
            unfoldedStorage.enumerateAttribute(.font, in: NSRange(location: 0, length: unfoldedStorage.length)) { value, range, _ in
                if let font = value as? NSFont, let resized = NSFont(descriptor: font.fontDescriptor, size: size) { fonts.append((range, resized)) }
            }
            for (range, font) in fonts { unfoldedStorage.addAttribute(.font, value: font, range: range) }
            unfoldedStorage.addAttribute(.paragraphStyle, value: LitheConsoleStyle.paragraphStyle(fontSize: size),
                range: NSRange(location: 0, length: unfoldedStorage.length))
            lastRender?()
        }

        func scrollToBottom() {
            textView?.scrollToEndOfDocument(nil)
            isAtBottom = true
        }

        /// Switches the viewport geometry only when the mode changes, so an
        /// ordinary output append never triggers a full relayout. A reader who
        /// was following the tail stays on it after the lines rewrap.
        func applyWrapsLines(_ wrapsLines: Bool) {
            guard wrapsLines != appliedWrapsLines,
                  let scrollView, let textView else { return }
            let wasAtBottom = isAtBottom
            appliedWrapsLines = wrapsLines
            LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: wrapsLines)
            if wasAtBottom { scrollToBottom() }
            reportBottomState()
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            if usesIDEAConsoleStyle {
                var items: [LitheContextMenuItem] = [
                    .action("Increase Font Size") { [weak self] in self?.zoom(1) },
                    .action("Decrease Font Size") { [weak self] in self?.zoom(-1) },
                    .action("Reset Font Size") { [weak self] in self?.zoom(nil) },
                    .separator,
                    .action("Expand All") { [weak self] in
                        guard let self else { return }
                        folds.expanded = Set(folds.regions.map(\.id)); lastRender?()
                    },
                    .action("Collapse All") { [weak self] in self?.folds.expanded.removeAll(); self?.lastRender?() }
                ]
                if let onToggleWrapsLines { items += [.separator, .action("Use soft wraps", checked: appliedWrapsLines, action: onToggleWrapsLines)] }
                items.insert(.action("Copy", isEnabled: view.selectedRange().length > 0) { [weak view] in view?.copy(nil) }, at: 0)
                items.insert(.separator, at: 1)
                let screenPoint = view.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                LitheContextMenuPresenter.shared.show(items: items, at: screenPoint,
                    appearance: view.effectiveAppearance, locale: .current, parentWindow: view.window)
                return nil
            }
            guard let onToggleWrapsLines else { return menu }
            // AppKit may hand back a reused menu; drop an earlier toggle and its
            // separator so repeated right-clicks never stack duplicate entries.
            if let index = menu.items.firstIndex(where: { $0 is OutputSoftWrapMenuItem }) {
                menu.removeItem(at: index)
                if index > 0, menu.items[index - 1].isSeparatorItem {
                    menu.removeItem(at: index - 1)
                }
            }
            menu.addItem(.separator())
            menu.addItem(OutputSoftWrapMenuItem(isOn: appliedWrapsLines, onToggle: onToggleWrapsLines))
            return menu
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if usesIDEAConsoleStyle, url.scheme == "lithe-console-fold" {
                toggleFold(url.lastPathComponent)
                return true
            }
            guard let location = OutputTextView.location(from: url) else { return false }
            var range = NSRange()
            if let storage = textView.textStorage, charIndex >= 0, charIndex < storage.length {
                _ = storage.attribute(.link, at: charIndex, effectiveRange: &range)
                lastFollowedConsoleLink = (range, url)
            }
            onOpenLocation?(location.url, location.line, location.column)
            return true
        }

        private func toggleFold(_ id: String) {
            if folds.expanded.contains(id) { folds.expanded.remove(id) } else { folds.expanded.insert(id) }
            lastRender?()
            textView?.needsDisplay = true
        }

        private func reportBottomState() {
            guard let scrollView, let textView else { return }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = textView.frame.height
            let next = documentHeight - visibleMaxY <= bottomThreshold
            guard next != isAtBottom else { return }
            isAtBottom = next
            onBottomStateChange?(next)
        }

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }
    }
}

/// The checkable soft-wrap entry appended to an output pane's context menu. It
/// carries its own action so the text view's standard menu items are untouched.
final class OutputSoftWrapMenuItem: NSMenuItem {
    private let onToggle: () -> Void

    init(isOn: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(
            title: String(localized: "Use soft wraps"),
            action: #selector(toggle),
            keyEquivalent: ""
        )
        target = self
        state = isOn ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggle() {
        onToggle()
    }
}

// MARK: - ANSI 渲染器

/// 将含 ANSI 转义序列的文本解析为「干净文本 + 样式段」,再组装成 NSAttributedString。
/// 终端、Maven 构建输出与运行输出共用。
enum ANSIOutputRenderer {
    struct Style {
        var foreground: NSColor
        var background: NSColor?
        var bold = false

        init(foreground: NSColor = .labelColor, background: NSColor? = nil, bold: Bool = false) {
            self.foreground = foreground
            self.background = background
            self.bold = bold
        }
    }

    struct Segment {
        var range: Range<String.Index>
        var foreground: NSColor
        var background: NSColor?
        var bold: Bool
    }

    struct ParsedOutput {
        var cleanText: String
        var segments: [Segment]
        /// True when the source carried SGR color codes, meaning the producing
        /// tool already colored its output and callers should not recolor it.
        var hasStyling = false
    }

    /// 便捷渲染:直接由源文本生成 NSAttributedString。
    static func render(_ source: String, fontSize: CGFloat) -> NSMutableAttributedString {
        render(parse(source), fontSize: fontSize)
    }

    static func render(_ parsed: ParsedOutput, fontSize: CGFloat) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for segment in parsed.segments {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: segment.foreground,
                .font: LitheTheme.editorFont(size: fontSize, weight: segment.bold ? .bold : .regular)
            ]
            if let background = segment.background {
                attributes[.backgroundColor] = background
            }
            result.append(NSAttributedString(
                string: String(parsed.cleanText[segment.range]),
                attributes: attributes
            ))
        }
        return result
    }

    static func parse(
        _ source: String,
        defaultForeground: NSColor = .labelColor,
        palette: [NSColor]? = nil
    ) -> ParsedOutput {
        let scalars = Array(source.unicodeScalars)
        var cleanText = ""
        cleanText.reserveCapacity(scalars.count)
        var segments: [Segment] = []
        var buffer = ""
        var segmentStart: String.Index?
        var style = Style(foreground: defaultForeground)
        var index = 0
        var sawColorCode = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let start = segmentStart ?? cleanText.endIndex
            cleanText.append(contentsOf: buffer)
            segments.append(Segment(
                range: start..<cleanText.endIndex,
                foreground: style.foreground,
                background: style.background,
                bold: style.bold
            ))
            buffer = ""
            segmentStart = cleanText.endIndex
        }

        func appendScalar(_ scalar: Unicode.Scalar) {
            if buffer.isEmpty, segmentStart == nil {
                segmentStart = cleanText.endIndex
            }
            buffer.unicodeScalars.append(scalar)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 27, index + 1 < scalars.count {
                flush()
                if scalars[index + 1] == "[" {
                    var end = index + 2
                    while end < scalars.count, !(64...126).contains(scalars[end].value) { end += 1 }
                    if end < scalars.count {
                        if scalars[end] == "m" {
                            let parameters = String(String.UnicodeScalarView(scalars[(index + 2)..<end]))
                            applySGR(parameters, defaultForeground: defaultForeground, palette: palette, to: &style)
                            if parameters != "0" && !parameters.isEmpty { sawColorCode = true }
                        }
                        index = end + 1
                        continue
                    }
                } else if scalars[index + 1] == "]" {
                    var end = index + 2
                    while end < scalars.count, scalars[end].value != 7 { end += 1 }
                    index = min(end + 1, scalars.count)
                    continue
                }
            }

            switch scalar.value {
            case 8, 127:
                if !buffer.isEmpty { buffer.removeLast() }
            case 13:
                break
            case 9, 10:
                appendScalar(scalar)
            case 0..<32:
                break
            default:
                appendScalar(scalar)
            }
            index += 1
        }
        flush()
        return ParsedOutput(cleanText: cleanText, segments: segments, hasStyling: sawColorCode)
    }

    private static func applySGR(
        _ parameters: String,
        defaultForeground: NSColor,
        palette: [NSColor]?,
        to style: inout Style
    ) {
        let codes = parameters.isEmpty ? [0] : parameters.split(separator: ";").compactMap { Int($0) }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = Style(foreground: defaultForeground)
            case 1: style.bold = true
            case 22: style.bold = false
            case 30...37, 90...97: style.foreground = paletteColor(code, palette: palette)
            case 39: style.foreground = defaultForeground
            case 40...47, 100...107: style.background = paletteColor(code - 10, palette: palette)
            case 49: style.background = nil
            case 38, 48:
                let isForeground = code == 38
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    if (0...255).contains(codes[index + 2]) {
                        setColor(color256(codes[index + 2], palette: palette), foreground: isForeground, style: &style)
                    }
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    if codes[(index + 2)...(index + 4)].allSatisfy({ (0...255).contains($0) }) {
                    let color = NSColor(
                        srgbRed: Double(codes[index + 2]) / 255,
                        green: Double(codes[index + 3]) / 255,
                        blue: Double(codes[index + 4]) / 255,
                        alpha: 1
                    )
                    setColor(color, foreground: isForeground, style: &style)
                    }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private static func setColor(_ color: NSColor, foreground: Bool, style: inout Style) {
        if foreground { style.foreground = color } else { style.background = color }
    }

    private static func paletteColor(_ code: Int, palette: [NSColor]? = nil) -> NSColor {
        if let palette, palette.count == 16 { return palette[code >= 90 ? code - 90 + 8 : code - 30] }
        let values: [NSColor] = [
            .black, NSColor(srgbRed: 0.80, green: 0.27, blue: 0.29, alpha: 1),
            NSColor(srgbRed: 0.31, green: 0.72, blue: 0.39, alpha: 1),
            NSColor(srgbRed: 0.86, green: 0.68, blue: 0.31, alpha: 1),
            NSColor(srgbRed: 0.35, green: 0.55, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 0.72, green: 0.40, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 0.35, green: 0.72, blue: 0.75, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.80, blue: 0.82, alpha: 1)
        ]
        return values[(code >= 90 ? code - 90 : code - 30) % values.count]
    }

    private static func color256(_ value: Int, palette: [NSColor]? = nil) -> NSColor {
        if value < 16 { return paletteColor(value < 8 ? value + 30 : value - 8 + 90, palette: palette) }
        if value >= 232 {
            let component = Double(8 + (value - 232) * 10) / 255
            return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
        }
        let offset = value - 16
        let components = [offset / 36, (offset / 6) % 6, offset % 6].map { $0 == 0 ? 0 : 55 + $0 * 40 }
        return NSColor(
            srgbRed: Double(components[0]) / 255,
            green: Double(components[1]) / 255,
            blue: Double(components[2]) / 255,
            alpha: 1
        )
    }
}
