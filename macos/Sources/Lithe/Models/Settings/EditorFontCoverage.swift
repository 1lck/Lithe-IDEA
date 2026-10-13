import Foundation

/// Character group used to describe a programming font's coverage.
///
/// A user-selected font may not contain every glyph the product renders; old
/// fonts written for GBK, for example, often miss punctuation, symbols or the
/// Chinese characters the interface itself displays. Lithe never blocks the
/// choice, so the editor needs to know which groups a font is missing in order
/// to fall back deterministically and to tell the user what is happening.
enum EditorFontScript: String, CaseIterable {
    case latin
    case symbols
    case chinese
    case japanese
    case korean
    case greek
    case cyrillic

    /// Representative characters probed with CoreText. Kept to a handful of
    /// widely used glyphs per group so coverage costs a few font lookups rather
    /// than a full character-set scan.
    var samples: String {
        switch self {
        case .latin: "AaZz09éüñ"
        case .symbols: "→≤≥≠…•“”‘’—±×÷"
        case .chinese: "中文测试数据"
        case .japanese: "あいうカタカナ"
        case .korean: "한글테스트"
        case .greek: "αβγΩ"
        case .cyrillic: "абвЯ"
        }
    }

    /// Name shown by the coverage hint in settings.
    var localizedName: String {
        switch self {
        case .latin: String(localized: "basic Latin letters")
        case .symbols: String(localized: "punctuation and symbols")
        case .chinese: String(localized: "Chinese characters")
        case .japanese: String(localized: "Japanese characters")
        case .korean: String(localized: "Korean characters")
        case .greek: String(localized: "Greek letters")
        case .cyrillic: String(localized: "Cyrillic letters")
        }
    }
}

/// Character groups the product expects the editor font to render.
struct EditorFontRequirements {
    let scripts: [EditorFontScript]

    /// Latin letters and UI punctuation are always required, because the app's
    /// own labels, file paths and code use them. Chinese is required only while
    /// the interface language is Chinese: that is when Lithe's own labels need
    /// those glyphs. Japanese, Korean, Greek and Cyrillic stay optional so a
    /// Latin-only programming font is not reported as broken for a user who
    /// never sees those scripts.
    static func forLanguage(_ language: AppLanguage) -> EditorFontRequirements {
        var scripts: [EditorFontScript] = [.latin, .symbols]
        if language == .simplifiedChinese { scripts.append(.chinese) }
        return EditorFontRequirements(scripts: scripts)
    }
}

/// Result of probing one family against the required character groups.
struct EditorFontCoverage {
    /// Resolved family the probe actually measured.
    let family: String
    /// Required groups the family cannot render, in requirement order.
    let missingScripts: [EditorFontScript]

    var isComplete: Bool { missingScripts.isEmpty }

    /// One localized phrase naming what is missing, or nil when nothing is.
    /// A single group is named directly; several groups collapse into a general
    /// phrase so the message does not need locale-specific list grammar.
    var missingDescription: String? {
        switch missingScripts.count {
        case 0: nil
        case 1: missingScripts[0].localizedName
        default: String(localized: "characters used by the interface and your files")
        }
    }
}
