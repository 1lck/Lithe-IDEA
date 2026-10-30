import Foundation

/// Application-wide source-editor preferences. Stored values use stable names,
/// while invalid or missing fields fall back individually for older preferences.
struct EditorAppearanceSettings: Equatable {
    enum ColorScheme: String, CaseIterable {
        case lithe, github, one, vscode, idea
        var bracketPairColorization: Bool { self != .idea }
        var title: String {
            switch self { case .lithe: "Lithe"; case .github: "GitHub"; case .one: "One"; case .vscode: "VS Code"; case .idea: "IntelliJ IDEA" }
        }
    }
    enum LineNumbers: String, CaseIterable {
        case on, relative, off
        var title: String {
            switch self { case .on: "Absolute"; case .relative: "Relative"; case .off: "Off" }
        }
    }
    enum Whitespace: String, CaseIterable {
        case none, boundary, selection, trailing, all
        var title: String {
            switch self {
            case .none: "None"
            case .boundary: "Boundary"
            case .selection: "Selection"
            case .trailing: "Trailing"
            case .all: "All"
            }
        }
    }
    enum CursorStyle: String, CaseIterable {
        case line, block, underline
        var title: String {
            switch self { case .line: "Line"; case .block: "Block"; case .underline: "Underline" }
        }
    }
    enum CursorBlinking: String, CaseIterable {
        case blink, smooth, solid
        var title: String {
            switch self { case .blink: "Blink"; case .smooth: "Smooth"; case .solid: "Solid" }
        }
    }

    /// Zero keeps Monaco's platform default; otherwise this is a font-size multiplier.
    var lineHeight: Double
    var colorScheme: ColorScheme
    var lineNumbers: LineNumbers
    var whitespace: Whitespace
    var cursorStyle: CursorStyle
    var cursorBlinking: CursorBlinking
    var indentGuides: Bool
    var fontLigatures: Bool
    var italicComments: Bool
    var stickyScroll: Bool
    var smoothScrolling: Bool
    var scrollBeyondLastLine: Bool
    var highlightCurrentLine: Bool

    init(values: [String: Any] = [:]) {
        let height = values["lineHeight"] as? Double ?? 0
        lineHeight = height.isFinite && height > 0 ? min(max(height, 1), 3) : 0
        colorScheme = ColorScheme(rawValue: values["colorScheme"] as? String ?? "") ?? .lithe
        lineNumbers = LineNumbers(rawValue: values["lineNumbers"] as? String ?? "") ?? .on
        whitespace = Whitespace(rawValue: values["whitespace"] as? String ?? "") ?? .selection
        cursorStyle = CursorStyle(rawValue: values["cursorStyle"] as? String ?? "") ?? .line
        cursorBlinking = CursorBlinking(rawValue: values["cursorBlinking"] as? String ?? "") ?? .blink
        indentGuides = values["indentGuides"] as? Bool ?? true
        fontLigatures = values["fontLigatures"] as? Bool ?? false
        italicComments = values["italicComments"] as? Bool ?? false
        stickyScroll = values["stickyScroll"] as? Bool ?? true
        smoothScrolling = values["smoothScrolling"] as? Bool ?? false
        scrollBeyondLastLine = values["scrollBeyondLastLine"] as? Bool ?? false
        highlightCurrentLine = values["highlightCurrentLine"] as? Bool ?? true
    }

    var storedValues: [String: Any] {
        ["lineHeight": lineHeight, "colorScheme": colorScheme.rawValue,
         "lineNumbers": lineNumbers.rawValue, "whitespace": whitespace.rawValue,
         "cursorStyle": cursorStyle.rawValue, "cursorBlinking": cursorBlinking.rawValue,
         "indentGuides": indentGuides, "fontLigatures": fontLigatures,
         "italicComments": italicComments,
         "stickyScroll": stickyScroll, "smoothScrolling": smoothScrolling,
         "scrollBeyondLastLine": scrollBeyondLastLine, "highlightCurrentLine": highlightCurrentLine]
    }

    /// Only display options cross this boundary; read-only/model lifecycle stays host-owned.
    var monacoOptions: [String: Any] {
        ["lineHeight": lineHeight, "lineNumbers": lineNumbers.rawValue,
         "renderWhitespace": whitespace.rawValue, "cursorStyle": cursorStyle.rawValue,
         "cursorBlinking": cursorBlinking.rawValue, "fontLigatures": fontLigatures,
         "guides": ["indentation": indentGuides, "highlightActiveIndentation": indentGuides],
         "bracketPairColorization": ["enabled": colorScheme.bracketPairColorization],
         "stickyScroll": ["enabled": stickyScroll], "smoothScrolling": smoothScrolling,
         "scrollBeyondLastLine": scrollBeyondLastLine,
         "renderLineHighlight": highlightCurrentLine ? "line" : "none"]
    }

    static func normalizedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 6), 72) : 13
    }
}
