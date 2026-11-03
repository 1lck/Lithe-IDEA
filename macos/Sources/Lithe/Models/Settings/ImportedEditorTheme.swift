import Foundation

/// A bounded editor-only overlay. The original IDE configuration is never modified.
struct ImportedEditorTheme: Codable, Equatable {
    struct Style: Codable, Equatable {
        var foreground: String?
        var fontStyle: String?
    }
    var name: String
    var dark: Bool
    var colors: [String: String]
    var tokens: [String: Style]

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
    static func validColor(_ color: String) -> Bool {
        color.count == 7 && color.first == "#" && color.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII }
    }
    static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 32_768, let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              !value.name.isEmpty, value.name.count <= 128,
              !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.colors.count <= 10, value.tokens.count <= 128,
              value.colors.allSatisfy({ ["background", "foreground", "cursor", "selection", "lineHighlight", "lineNumber", "activeLineNumber", "guide", "activeGuide", "link"].contains($0.key) && validColor($0.value) }),
              value.tokens.allSatisfy({ key, style in
                  !key.isEmpty && key.count <= 100 && key.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 }
                  && (style.foreground.map(validColor) ?? true)
                  && (style.fontStyle.map { ["", "bold", "italic", "bold italic"].contains($0) } ?? true)
              }) else { return nil }
        return value
    }
}
