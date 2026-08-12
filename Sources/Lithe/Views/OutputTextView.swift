import AppKit
import SwiftUI

// MARK: - 输出文本视图(ANSI 着色 + 可点击错误定位 + 智能滚动 + 一键复制)

/// 构建/运行输出的统一渲染视图:
/// - 支持 ANSI 转义序列着色(复用终端渲染器)
/// - Maven 错误行 `[ERROR] path:[line,col]` 与 Java 堆栈行 `at x.y.Foo.bar(Foo.java:42)` 可点击跳转源码
/// - 智能滚动:用户上翻后不强制拉底,并显示 "Jump to latest" 按钮
/// - 右上角一键复制全部输出
struct OutputTextView: View {
    let output: String
    let searchRoots: [URL]
    let emptyMessage: String
    let onOpenLocation: (URL, Int, Int?) -> Void

    @State private var isAtBottom = true

    private static let bottomThreshold: CGFloat = 80
    private static let contentID = "output-content"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                if output.isEmpty {
                    Text(emptyMessage)
                        .font(.custom("Menlo", size: 11.5))
                        .foregroundStyle(LitheTheme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .id(Self.contentID)
                } else {
                    Text(renderedOutput)
                        .font(.custom("Menlo", size: 11.5))
                        .tint(LitheTheme.accent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .id(Self.contentID)
                }
            }
            .background(LitheTheme.editor)
            .overlay(alignment: .topTrailing) {
                copyButton
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    jumpToLatestButton(proxy: proxy)
                        .padding(10)
                }
            }
            .background(ScrollPositionTracker { distance in
                isAtBottom = distance <= Self.bottomThreshold
            })
            .environment(\.openURL, OpenURLAction { url in
                guard let location = Self.location(from: url) else { return .systemAction }
                onOpenLocation(location.url, location.line, location.column)
                return .handled
            })
            .onChange(of: output) { _ in
                guard isAtBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.contentID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 渲染

    private var renderedOutput: AttributedString {
        guard !output.isEmpty else { return AttributedString() }
        return Self.renderOutput(output, searchRoots: searchRoots)
    }

    private static func renderOutput(_ source: String, searchRoots: [URL]) -> AttributedString {
        let parsed = ANSIOutputRenderer.parse(source)
        guard !parsed.cleanText.isEmpty else { return AttributedString() }
        var result = ANSIOutputRenderer.render(parsed, fontSize: 11.5)
        applySeverityColors(to: &result, text: parsed.cleanText, ansiStyled: parsed.hasStyling)
        dimTimestamps(in: &result, text: parsed.cleanText)
        for location in matchLocations(in: parsed.cleanText, searchRoots: searchRoots) {
            guard let range = Range(location.range, in: result) else { continue }
            result[range].link = locationURL(path: location.url.path, line: location.line, column: location.column)
            result[range].foregroundColor = location.kind == .warning ? LitheTheme.warning : LitheTheme.error
        }
        return result
    }

    // MARK: - 日志级别着色

    enum Severity {
        case error, warning, info, debug

        var color: Color {
            switch self {
            case .error: LitheTheme.error
            case .warning: LitheTheme.warning
            case .info: Color(red: 0.55, green: 0.72, blue: 0.95)
            case .debug: LitheTheme.secondaryText
            }
        }
    }

    /// Matches the level as its own bracketed or spaced token so a path such as
    /// `src/main/java/Error.java` is not mistaken for an error line.
    private static let severityExpression = try! NSRegularExpression(
        pattern: #"(?:^|\s|\[)(ERROR|SEVERE|FATAL|WARN(?:ING)?|INFO|DEBUG|TRACE)(?:\]|\s|:)"#
    )

    static func severity(ofLine line: String) -> Severity? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = severityExpression.firstMatch(in: line, range: range),
              let token = capture(match, at: 1, in: line) else { return nil }
        switch token.uppercased() {
        case "ERROR", "SEVERE", "FATAL": return .error
        case "WARN", "WARNING": return .warning
        case "INFO": return .info
        case "DEBUG", "TRACE": return .debug
        default: return nil
        }
    }

    /// Colors whole lines by log level so a wall of white output separates into
    /// scannable bands. Skipped when the process emitted its own ANSI colors --
    /// overriding those would fight the tool's intended formatting.
    private static func applySeverityColors(
        to result: inout AttributedString,
        text: String,
        ansiStyled: Bool
    ) {
        guard !ansiStyled else { return }
        var colored: [(Range<String.Index>, Severity)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { substring, lineRange, _, _ in
            guard let line = substring, let severity = severity(ofLine: line) else { return }
            colored.append((lineRange, severity))
        }
        for (lineRange, severity) in colored {
            guard let range = Range(lineRange, in: result) else { continue }
            result[range].foregroundColor = severity.color
        }
    }

    /// Recedes the leading clock on every line so the timestamps read as a
    /// gutter rather than competing with the message for attention. Applied
    /// after severity coloring, which paints whole lines including the stamp.
    private static func dimTimestamps(in result: inout AttributedString, text: String) {
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
            guard let range = Range(stamp, in: result) else { continue }
            result[range].foregroundColor = LitheTheme.secondaryText.opacity(0.7)
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

    private static func matchLocations(in text: String, searchRoots: [URL]) -> [OutputLocation] {
        guard !searchRoots.isEmpty else { return [] }
        var locations: [OutputLocation] = []

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { substring, lineRange, _, _ in
            guard let line = substring, !line.isEmpty else { return }
            let lineNSRange = NSRange(line.startIndex..<line.endIndex, in: line)

            if let match = mavenExpression.firstMatch(in: line, range: lineNSRange),
               let path = capture(match, at: 2, in: line),
               let lineNumber = capture(match, at: 3, in: line).flatMap(Int.init) {
                let column = capture(match, at: 4, in: line).flatMap(Int.init)
                guard let url = resolvePath(path, searchRoots: searchRoots) else { return }
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
               let url = resolveClassFile(className, searchRoots: searchRoots),
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

    private static func resolvePath(_ path: String, searchRoots: [URL]) -> URL? {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        for root in searchRoots {
            let url = root.appendingPathComponent(path).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 根据 Java 类全名(如 com.example.Foo)推断 Maven 源码路径并定位存在的文件。
    private static func resolveClassFile(_ className: String, searchRoots: [URL]) -> URL? {
        let outerClassName = className.split(separator: "$", maxSplits: 1).first.map(String.init) ?? className
        let relativePath = outerClassName.replacingOccurrences(of: ".", with: "/") + ".java"
        let candidates = ["src/main/java/", "src/test/java/"].map { $0 + relativePath }
        for root in searchRoots {
            for candidate in candidates {
                let url = root.appendingPathComponent(candidate).standardizedFileURL
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
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

    private static func location(from url: URL) -> (url: URL, line: Int, column: Int?)? {
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
            pasteboard.setString(String(renderedOutput.characters), forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LitheTheme.raised.opacity(0.9))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(LitheTheme.panelBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .lithePointer()
        .foregroundStyle(LitheTheme.primaryText)
        .disabled(output.isEmpty)
        .opacity(output.isEmpty ? 0.4 : 1)
        .help("Copy output")
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.contentID, anchor: .bottom)
            }
            isAtBottom = true
        } label: {
            Label("Jump to latest", systemImage: "arrow.down.to.line")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LitheTheme.raised.opacity(0.92))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(LitheTheme.panelBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .lithePointer()
        .foregroundStyle(LitheTheme.primaryText)
    }
}

// MARK: - 滚动位置跟踪

/// 以 NSViewRepresentable 形式挂在 ScrollView 内,通过 NSScrollView 的
/// boundsDidChange 通知回调"距底部距离",用于智能滚动。
private struct ScrollPositionTracker: NSViewRepresentable {
    var onScroll: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    @MainActor
    final class Coordinator {
        var onScroll: @MainActor (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
        nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

        init(onScroll: @escaping @MainActor (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            guard let scrollView = view.enclosingScrollView, scrollView !== self.scrollView else { return }
            detachObservers()
            self.scrollView = scrollView
            let center = NotificationCenter.default
            boundsObserver = center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            frameObserver = center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        @MainActor
        private func report() {
            guard let scrollView else { return }
            let bounds = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            onScroll(max(0, documentHeight - bounds.maxY))
        }

        @MainActor
        private func detachObservers() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
                self.frameObserver = nil
            }
            scrollView = nil
        }

        deinit {
            // deinit 非 MainActor:仅移除通知 token,不触碰隔离属性
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }
    }
}

// MARK: - ANSI 渲染器

/// 将含 ANSI 转义序列的文本解析为「干净文本 + 样式段」,再组装成 AttributedString。
/// 终端、Maven 构建输出与运行输出共用。
enum ANSIOutputRenderer {
    struct Style {
        var foreground = LitheTheme.primaryText
        var background: Color?
        var bold = false
    }

    struct Segment {
        var range: Range<String.Index>
        var foreground: Color
        var background: Color?
        var bold: Bool
    }

    struct ParsedOutput {
        var cleanText: String
        var segments: [Segment]
        /// True when the source carried SGR color codes, meaning the producing
        /// tool already colored its output and callers should not recolor it.
        var hasStyling = false
    }

    /// 便捷渲染:直接由源文本生成 AttributedString。
    static func render(_ source: String, fontSize: CGFloat) -> AttributedString {
        render(parse(source), fontSize: fontSize)
    }

    static func render(_ parsed: ParsedOutput, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        for segment in parsed.segments {
            var run = AttributedString(String(parsed.cleanText[segment.range]))
            run.foregroundColor = segment.foreground
            run.backgroundColor = segment.background
            run.font = segment.bold
                ? .custom("Menlo-Bold", size: fontSize)
                : .custom("Menlo", size: fontSize)
            result.append(run)
        }
        return result
    }

    static func parse(_ source: String) -> ParsedOutput {
        let scalars = Array(source.unicodeScalars)
        var cleanText = ""
        cleanText.reserveCapacity(scalars.count)
        var segments: [Segment] = []
        var buffer = ""
        var segmentStart: String.Index?
        var style = Style()
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
                            applySGR(parameters, to: &style)
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

    private static func applySGR(_ parameters: String, to style: inout Style) {
        let codes = parameters.isEmpty ? [0] : parameters.split(separator: ";").compactMap { Int($0) }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 22: style.bold = false
            case 30...37, 90...97: style.foreground = paletteColor(code)
            case 39: style.foreground = Style().foreground
            case 40...47, 100...107: style.background = paletteColor(code - 10)
            case 49: style.background = nil
            case 38, 48:
                let isForeground = code == 38
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    setColor(color256(codes[index + 2]), foreground: isForeground, style: &style)
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    let color = Color(
                        red: Double(codes[index + 2]) / 255,
                        green: Double(codes[index + 3]) / 255,
                        blue: Double(codes[index + 4]) / 255
                    )
                    setColor(color, foreground: isForeground, style: &style)
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private static func setColor(_ color: Color, foreground: Bool, style: inout Style) {
        if foreground { style.foreground = color } else { style.background = color }
    }

    private static func paletteColor(_ code: Int) -> Color {
        let values: [Color] = [
            .black, Color(red: 0.80, green: 0.27, blue: 0.29),
            Color(red: 0.31, green: 0.72, blue: 0.39), Color(red: 0.86, green: 0.68, blue: 0.31),
            Color(red: 0.35, green: 0.55, blue: 0.90), Color(red: 0.72, green: 0.40, blue: 0.78),
            Color(red: 0.35, green: 0.72, blue: 0.75), Color(red: 0.78, green: 0.80, blue: 0.82)
        ]
        return values[(code >= 90 ? code - 90 : code - 30) % values.count]
    }

    private static func color256(_ value: Int) -> Color {
        if value < 16 { return paletteColor(value < 8 ? value + 30 : value - 8 + 90) }
        if value >= 232 {
            let component = Double(8 + (value - 232) * 10) / 255
            return Color(red: component, green: component, blue: component)
        }
        let offset = value - 16
        let components = [offset / 36, (offset / 6) % 6, offset % 6].map { $0 == 0 ? 0 : 55 + $0 * 40 }
        return Color(
            red: Double(components[0]) / 255,
            green: Double(components[1]) / 255,
            blue: Double(components[2]) / 255
        )
    }
}
