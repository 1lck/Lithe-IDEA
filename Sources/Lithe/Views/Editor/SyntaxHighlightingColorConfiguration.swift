import AppKit
import Foundation

/// Semantic syntax roles that can be configured globally or per file format.
enum SyntaxHighlightingColorRole: String, CaseIterable {
    case text
    case keyword
    case annotation
    case type
    case property
    case number
    case string
    case comment
}

/// A color reference shared by both appearances or split into light and dark values.
struct SyntaxHighlightingColorValue: Decodable, Equatable {
    let light: String
    let dark: String

    private enum CodingKeys: String, CodingKey {
        case light
        case dark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let shared = try? container.decode(String.self) {
            light = shared
            dark = shared
            return
        }
        let adaptive = try decoder.container(keyedBy: CodingKeys.self)
        light = try adaptive.decode(String.self, forKey: .light)
        dark = try adaptive.decode(String.self, forKey: .dark)
    }

    func reference(isDark: Bool) -> String {
        isDark ? dark : light
    }
}

/// Optional overrides for the syntax roles used by one file format.
struct SyntaxHighlightingColorOverrides: Decodable, Equatable {
    let text: SyntaxHighlightingColorValue?
    let keyword: SyntaxHighlightingColorValue?
    let annotation: SyntaxHighlightingColorValue?
    let type: SyntaxHighlightingColorValue?
    let property: SyntaxHighlightingColorValue?
    let number: SyntaxHighlightingColorValue?
    let string: SyntaxHighlightingColorValue?
    let comment: SyntaxHighlightingColorValue?

    init(
        text: SyntaxHighlightingColorValue? = nil,
        keyword: SyntaxHighlightingColorValue? = nil,
        annotation: SyntaxHighlightingColorValue? = nil,
        type: SyntaxHighlightingColorValue? = nil,
        property: SyntaxHighlightingColorValue? = nil,
        number: SyntaxHighlightingColorValue? = nil,
        string: SyntaxHighlightingColorValue? = nil,
        comment: SyntaxHighlightingColorValue? = nil
    ) {
        self.text = text
        self.keyword = keyword
        self.annotation = annotation
        self.type = type
        self.property = property
        self.number = number
        self.string = string
        self.comment = comment
    }

    func value(for role: SyntaxHighlightingColorRole) -> SyntaxHighlightingColorValue? {
        switch role {
        case .text: text
        case .keyword: keyword
        case .annotation: annotation
        case .type: type
        case .property: property
        case .number: number
        case .string: string
        case .comment: comment
        }
    }
}

enum SyntaxHighlightingColorConfigurationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidColorReference(context: String, role: String, value: String)
    case missingBundledConfiguration
}

/// Loads the centralized syntax-color mapping and resolves one palette per file format.
struct SyntaxHighlightingColorConfiguration {
    private struct Configuration: Decodable {
        let version: Int
        let defaults: SyntaxHighlightingColorOverrides
        let formats: [String: SyntaxHighlightingColorOverrides]
    }

    static let bundled: SyntaxHighlightingColorConfiguration = {
        do {
            guard let url = SyntaxHighlightingResources.colorConfigurationURL else {
                throw SyntaxHighlightingColorConfigurationError.missingBundledConfiguration
            }
            return try SyntaxHighlightingColorConfiguration(data: Data(contentsOf: url))
        } catch {
            // Invalid packaged colors must not prevent the editor from rendering text.
            NSLog("Syntax highlighting color configuration could not be loaded: %@", String(describing: error))
            return SyntaxHighlightingColorConfiguration()
        }
    }()

    let defaults: SyntaxHighlightingColorOverrides
    let formats: [String: SyntaxHighlightingColorOverrides]

    var formatIDs: Set<String> {
        Set(formats.keys)
    }

    private init() {
        defaults = SyntaxHighlightingColorOverrides()
        formats = [:]
    }

    init(data: Data) throws {
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard configuration.version == 1 else {
            throw SyntaxHighlightingColorConfigurationError.unsupportedVersion(configuration.version)
        }
        try Self.validate(configuration.defaults, context: "defaults")
        for (formatID, overrides) in configuration.formats {
            try Self.validate(overrides, context: formatID)
        }
        defaults = configuration.defaults
        formats = configuration.formats
    }

    func palette(formatID: String?, base: CodeEditorPalette) -> SyntaxHighlightingPalette {
        SyntaxHighlightingPalette(
            base: base,
            defaults: defaults,
            overrides: formatID.flatMap { formats[$0] }
        )
    }

    private static func validate(
        _ overrides: SyntaxHighlightingColorOverrides,
        context: String
    ) throws {
        for role in SyntaxHighlightingColorRole.allCases {
            guard let value = overrides.value(for: role) else { continue }
            for reference in [value.light, value.dark] where !isValidReference(reference) {
                throw SyntaxHighlightingColorConfigurationError.invalidColorReference(
                    context: context,
                    role: role.rawValue,
                    value: reference
                )
            }
        }
    }

    private static func isValidReference(_ reference: String) -> Bool {
        if SyntaxHighlightingPalette.themeToken(for: reference) != nil || reference == "editor:text" {
            return true
        }
        return SyntaxHighlightingPalette.hexComponents(for: reference) != nil
    }
}

/// Fully resolved AppKit colors consumed by syntax-highlighting adapters.
struct SyntaxHighlightingPalette {
    let text: NSColor
    let keyword: NSColor
    let annotation: NSColor
    let type: NSColor
    let property: NSColor
    let number: NSColor
    let string: NSColor
    let comment: NSColor

    init(
        base: CodeEditorPalette,
        defaults: SyntaxHighlightingColorOverrides,
        overrides: SyntaxHighlightingColorOverrides?
    ) {
        text = Self.resolve(.text, base: base, defaults: defaults, overrides: overrides) ?? base.text
        keyword = Self.resolve(.keyword, base: base, defaults: defaults, overrides: overrides) ?? base.keyword
        annotation = Self.resolve(.annotation, base: base, defaults: defaults, overrides: overrides) ?? base.annotation
        type = Self.resolve(.type, base: base, defaults: defaults, overrides: overrides) ?? base.type
        property = Self.resolve(.property, base: base, defaults: defaults, overrides: overrides) ?? base.property
        number = Self.resolve(.number, base: base, defaults: defaults, overrides: overrides) ?? base.number
        string = Self.resolve(.string, base: base, defaults: defaults, overrides: overrides) ?? base.string
        comment = Self.resolve(.comment, base: base, defaults: defaults, overrides: overrides) ?? base.comment
    }

    private static func resolve(
        _ role: SyntaxHighlightingColorRole,
        base: CodeEditorPalette,
        defaults: SyntaxHighlightingColorOverrides,
        overrides: SyntaxHighlightingColorOverrides?
    ) -> NSColor? {
        guard let value = overrides?.value(for: role) ?? defaults.value(for: role) else { return nil }
        let reference = value.reference(isDark: base.isDark)
        if reference == "editor:text" {
            return base.text
        }
        if let token = themeToken(for: reference) {
            return LitheTheme.nsColor(token, theme: base.theme, isDark: base.isDark)
        }
        guard let components = hexComponents(for: reference) else { return nil }
        return NSColor(
            srgbRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }

    static func themeToken(for reference: String) -> LitheTheme.ResolvedColorToken? {
        switch reference {
        case "theme:editor": .editor
        case "theme:sidebar": .sidebar
        case "theme:primaryText": .primaryText
        case "theme:secondaryText": .secondaryText
        case "theme:accent": .accent
        case "theme:success": .success
        case "theme:warning": .warning
        case "theme:error": .error
        case "theme:skill": .skill
        case "theme:guide": .guide
        case "theme:activeGuide": .activeGuide
        case "theme:divider": .divider
        default: nil
        }
    }

    static func hexComponents(
        for reference: String
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard reference.first == "#" else { return nil }
        let hexadecimal = reference.dropFirst()
        guard hexadecimal.count == 6 || hexadecimal.count == 8,
              let value = UInt64(String(hexadecimal), radix: 16) else { return nil }
        let hasAlpha = hexadecimal.count == 8
        let red = hasAlpha ? (value >> 24) & 0xFF : (value >> 16) & 0xFF
        let green = hasAlpha ? (value >> 16) & 0xFF : (value >> 8) & 0xFF
        let blue = hasAlpha ? (value >> 8) & 0xFF : value & 0xFF
        let alpha = hasAlpha ? value & 0xFF : 0xFF
        return (
            CGFloat(red) / 255,
            CGFloat(green) / 255,
            CGFloat(blue) / 255,
            CGFloat(alpha) / 255
        )
    }
}
