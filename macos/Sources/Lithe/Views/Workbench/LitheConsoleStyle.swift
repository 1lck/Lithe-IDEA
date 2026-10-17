// Portions adapted from IntelliJ Community, Copyright 2000-2024 JetBrains s.r.o. and contributors.
// SPDX-License-Identifier: Apache-2.0
import AppKit

/// IDEA Community c7f91397: ConsoleViewUtil, inherited Islands editor schemes.
/// Single presentation owner for OutputTextView, including Run, Debug and Tests.
@MainActor
enum LitheConsoleStyle {
    static let defaultFontSize: CGFloat = 13
    // FontPreferences.DEFAULT_LINE_SPACING + EditorView.getLineHeight (default registry path).
    static let lineSpacing: CGFloat = 1.2
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil((ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)) * lineSpacing)
    }
    static func paragraphStyle(fontSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight(for: LitheTheme.editorFont(size: fontSize))
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }
    static func resizedFont(current: CGFloat, delta: CGFloat?, defaultSize: CGFloat? = nil) -> CGFloat {
        let requested = delta.map { current + $0 } ?? defaultSize ?? defaultFontSize
        return (8...40).contains(requested) ? requested : current
    }
    static func background(dark: Bool) -> NSColor { color(dark ? 0x191A1C : 0xFFFFFF) }
    static func color(_ value: Int) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func foreground(dark: Bool) -> NSColor { color(dark ? 0xBCBEC4 : 0x000000) }
    static func hyperlink(dark: Bool) -> NSColor { color(dark ? 0x548AF7 : 0x006DCC) }
    static func foldedForeground(dark: Bool) -> NSColor { color(dark ? 0x868991 : 0x414D41) }
    static func foldedBackground(dark: Bool) -> NSColor { color(dark ? 0x393B40 : 0xE9F5E6) }
    // Normalize only the leading level token; producer styles in the message stay intact.
    private static let logLevel = try! NSRegularExpression(pattern:
        #"(?m)^\h*(?:(?:\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\h+){0,2}(?:\[[^\]\r\n]*\]\h+)?(?:\[(INFO|WARN(?:ING)?|ERROR|FATAL)\]|(INFO|WARN(?:ING)?|ERROR|FATAL)(?=\h))"#)

    static func normalizeLogLevels(in text: NSMutableAttributedString, dark: Bool) {
        let source = text.string as NSString
        let colors = palette(dark: dark)
        for match in logLevel.matches(in: text.string, range: NSRange(location: 0, length: source.length)) {
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            let level = source.substring(with: range)
            let index = level == "INFO" ? 2 : level.hasPrefix("WARN") ? 3 : 1
            text.addAttribute(.foregroundColor, value: colors[index], range: range)
        }
    }

    static func palette(dark: Bool) -> [NSColor] {
        (dark ? [0x000000, 0xF0524F, 0x5C962C, 0xA68A0D, 0x3993D4, 0xA771BF, 0x00A3A3, 0x808080, 0x595959, 0xFF4050, 0x4FC414, 0xE5BF00, 0x1FB0FF, 0xED7EED, 0x00E5E5, 0xFFFFFF] : [0x000000, 0xCE0505, 0x067D17, 0xB28C00, 0x063FDB, 0xB309B3, 0x028E8E, 0x929292, 0x656565, 0xFF1616, 0x16B42C, 0xECC32C, 0x2D61F0, 0xE617E6, 0x15C1C1, 0xC9C9C9]).map(color)
    }
}

struct ConsoleFoldRegion: Equatable {
    let range: NSRange
    let label: String
    let kind: String
    var id: String { "\(kind)-\(range.location)" }
}

/// Presentation ranges only: source logs, ANSI attributes and DAP output are unchanged.
/// Rules adapted from Apache-2.0 Community StackTraceFolding and JavaPlugin.xml.
enum ConsoleStackTraceFolding {
    static let internalPatterns: [String] = [
        "at java.awt.EventDispatchThread",
        "at java.awt.Window.dispatchEventImpl(",
        "at java.awt.Container.dispatchEventImpl(",
        "at java.awt.LightweightDispatcher.",
        "at java.awt.Component.dispatchEvent(",
        "at java.awt.event.InvocationEvent.dispatch(",
        "at java.awt.EventQueue",
        "at java.awt.Component.dispatchEventImpl(",
        "at java.awt.Container.processEvent(",
        "at javax.swing.JComponent.processMouseEvent(",
        "at javax.swing.plaf.basic.BasicMenuItemUI",
        "at java.awt.Component.processMouseEvent(",
        "at javax.swing.AbstractButton.doClick(",
        "at java.awt.Component.processEvent(",
        "at java.awt.Container.dispatchEventImpl(",
        "at javax.swing.DefaultButtonModel.fireActionPerformed(",
        "at javax.swing.DefaultButtonModel.setPressed(",
        "at javax.swing.AbstractButton.fireActionPerformed(",
        "at javax.swing.AbstractButton$Handler.actionPerformed(",
        "at java.security.AccessControlContext$1.doIntersectionPrivilege(",
        "at java.awt.EventQueue.dispatchEventImpl(",
        "at java.security.AccessController.doPrivileged(Native Method)",
        "at java.security.ProtectionDomain$1.doIntersectionPrivilege(",
        "at java.security.ProtectionDomain$JavaSecurityAccessImpl.doIntersectionPrivilege(",
        "at com.jgoodies.binding.beans.ExtendedPropertyChangeSupport.firePropertyChange0(",
        "at javax.swing.plaf.basic.BasicComboPopup$Handler.mouseReleased(",
        "at java.util.ArrayList$ArrayListSpliterator",
        "at java.util.stream.ReferencePipeline",
        "at java.util.Spliterators$",
        "at java.util.stream.AbstractPipeline.evaluate(",
        "at java.util.stream.AbstractPipeline.copyInto(",
        "at java.util.stream.AbstractPipeline.wrapAndCopyInto(",
        "at java.util.stream.DistinctOps",
        "at java.util.stream.FindOps",
        "at java.util.stream.ForEachOps",
        "at java.util.stream.MatchOps",
        "at java.util.stream.ReduceOps",
        "at java.util.stream.SliceOps",
        "at java.util.stream.WhileOps",
        "at java.util.concurrent.Executors$",
        "at java.util.concurrent.ThreadPoolExecutor",
        "at java.util.concurrent.FutureTask.",
        "at java.util.concurrent.CompletableFuture$AsyncSupply.run(",
        "java.lang.Thread.run(",
        "java.lang.reflect.Method.invoke(",
        "java.lang.reflect.Constructor.newInstance(",
        "at java.base/jdk.internal",
        "at java.security.AccessController.doPrivileged(",
        "at sun.reflect.",
        "at java.rmi.",
        "at sun.rmi.",
        "at com.sun.proxy.$Proxy",
        "at com.intellij.rt.execution."
    ]
    private static let internalExpression = try! NSRegularExpression(
        pattern: internalPatterns.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    )
    private static let enclosedMore = try! NSRegularExpression(pattern: #"^\t\.\.\. \d+ more$"#)
    private static let modulePrefix = try! NSRegularExpression(pattern: #"(?<=at )[^\s/]+/"#)

    static func regions(in text: String) -> [ConsoleFoldRegion] {
        let source = text as NSString
        var frames = 0
        var longStart: Int?
        var longEnd = 0
        var longCount = 0
        var internalStart: Int?
        var internalAttachPrevious = false
        var internalEnd = 0
        var internalCount = 0
        var hasAsync = false
        var result: [ConsoleFoldRegion] = []
        func finishLong() {
            if let start = longStart {
                result.append(ConsoleFoldRegion(range: NSRange(location: start, length: longEnd - start),
                    label: "\t<\(longCount) folded frames\(hasAsync ? " including async" : "")>", kind: "frames"))
            }
            longStart = nil; longCount = 0; hasAsync = false
        }
        func finishInternal() {
            if let start = internalStart {
                let attached = internalAttachPrevious ? start - 1 : start
                result.append(ConsoleFoldRegion(range: NSRange(location: attached, length: internalEnd - attached),
                    label: "<\(internalCount) internal lines>", kind: "internal"))
            }
            internalStart = nil; internalCount = 0
        }
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            if NSMaxRange(range) == source.length,
               !source.substring(with: range).hasSuffix("\n") {
                finishLong(); finishInternal(); break
            }
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            let end = range.location + (line as NSString).length
            let isFrame = line.hasPrefix("\tat ") || enclosedMore.firstMatch(in: line,
                range: NSRange(location: 0, length: (line as NSString).length)) != nil
            if isFrame {
                frames += 1
                if frames == 9 { finishInternal() }
                if frames > 8 {
                    if longStart == nil { longStart = range.location }
                    longEnd = end; longCount += 1
                    hasAsync = hasAsync || line.hasPrefix("\tat --- Async.Stack.Trace --- ")
                }
            } else { finishLong(); frames = 0 }
            let normalized = line.contains("/") ? modulePrefix.stringByReplacingMatches(in: line,
                range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "") : line
            let matchesInternal = internalExpression.firstMatch(in: line,
                range: NSRange(location: 0, length: (line as NSString).length)) != nil
                || (normalized != line && internalExpression.firstMatch(in: normalized,
                    range: NSRange(location: 0, length: (normalized as NSString).length)) != nil)
            if matchesInternal {
                if internalStart == nil {
                    internalStart = range.location
                    internalAttachPrevious = range.location > 0 && range.location != longStart
                }
                internalEnd = end; internalCount += 1
            } else { finishInternal() }
            offset = NSMaxRange(range)
        }
        finishLong(); finishInternal()
        return result.sorted { $0.range.location == $1.range.location
            ? ($0.range.length == $1.range.length ? $0.kind == "frames" : $0.range.length > $1.range.length) : $0.range.location < $1.range.location }
    }
}

extension NSAttributedString.Key {
    static let consoleFoldSource = NSAttributedString.Key("lithe.console.foldSource")
    static let consoleExpandedFoldID = NSAttributedString.Key("lithe.console.expandedFoldID")
}

@MainActor
final class ConsoleFoldPresentation {
    var regions: [ConsoleFoldRegion] = []
    var expanded: Set<String> = []
    var fontSize = LitheConsoleStyle.defaultFontSize
    var inputSessionID: UUID?
    var inputDraft = ""

    func project(_ raw: NSAttributedString, dark: Bool, fontSize: CGFloat) -> NSAttributedString {
        // ponytail: Debug caps output at 400k characters and publishes at 10Hz. This
        // bounded scan preserves nested rules; above that ceiling index dirty lines.
        regions = ConsoleStackTraceFolding.regions(in: raw.string)
        expanded.formIntersection(Set(regions.map(\.id)))
        let result = NSMutableAttributedString()
        var offset = 0
        var anchors: [(Int, String)] = []
        for region in regions {
            guard region.range.location >= offset else { continue }
            result.append(raw.attributedSubstring(from: NSRange(location: offset, length: region.range.location - offset)))
            let isExpanded = expanded.contains(region.id)
            if isExpanded {
                anchors.append((result.length, region.id))
                offset = region.range.location
                continue
            }
            let label = region.label
            let attributes: [NSAttributedString.Key: Any] = [
                .font: LitheTheme.editorFont(size: fontSize),
                .paragraphStyle: LitheConsoleStyle.paragraphStyle(fontSize: fontSize),
                .foregroundColor: LitheConsoleStyle.foldedForeground(dark: dark),
                .backgroundColor: LitheConsoleStyle.foldedBackground(dark: dark),
                .link: URL(string: "lithe-console-fold://toggle/" + region.id)!,
                .consoleFoldSource: (raw.string as NSString).substring(with: region.range)
            ]
            result.append(NSAttributedString(string: label, attributes: attributes))
            offset = NSMaxRange(region.range)
        }
        result.append(raw.attributedSubstring(from: NSRange(location: offset, length: raw.length - offset)))
        for (index, id) in anchors where index < result.length {
            result.addAttribute(.consoleExpandedFoldID, value: id, range: NSRange(location: index, length: 1))
        }
        return result
    }

    static func firstDifference(_ old: NSAttributedString, _ next: NSAttributedString) -> Int {
        let left = old.string as NSString, right = next.string as NSString
        var prefix = 0
        while prefix < min(left.length, right.length), left.character(at: prefix) == right.character(at: prefix) { prefix += 1 }
        var attributesPrefix = 0
        while attributesPrefix < prefix {
            var leftRange = NSRange(), rightRange = NSRange()
            let lhs = old.attributes(at: attributesPrefix, effectiveRange: &leftRange)
            let rhs = next.attributes(at: attributesPrefix, effectiveRange: &rightRange)
            guard NSDictionary(dictionary: lhs).isEqual(NSDictionary(dictionary: rhs)) else { break }
            attributesPrefix = min(NSMaxRange(leftRange), NSMaxRange(rightRange))
        }
        prefix = min(prefix, attributesPrefix)
        if prefix > 0, prefix < right.length, (0xDC00...0xDFFF).contains(right.character(at: prefix)) { prefix -= 1 }
        return prefix
    }

    static func copyText(_ selection: NSAttributedString) -> String {
        let result = NSMutableAttributedString(attributedString: selection)
        var replacements: [(NSRange, String)] = []
        selection.enumerateAttribute(.consoleFoldSource, in: NSRange(location: 0, length: selection.length)) { value, range, _ in
            if let text = value as? String { replacements.append((range, text)) }
        }
        for (range, text) in replacements.reversed() { result.replaceCharacters(in: range, with: text) }
        return result.string
    }
}
