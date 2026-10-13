import AppKit
import CoreText
import Foundation

/// Resolves the code editor's programming font family against the macOS font
/// database and the faces already registered for this process.
///
/// The catalog is strictly read-only. It never installs, downloads, extracts or
/// writes a font, and it caches the discovered family list in memory for the
/// lifetime of the process only: nothing is persisted, so opening the font
/// setting cannot change the signed bundle that Sparkle builds its differential
/// update delta from. Runtime caches for other resources belong to the platform
/// storage adapter, not here.
///
/// Families are matched case-insensitively because the stored preference only
/// keeps a family name and a user may reinstall a font under different casing.
///
/// Note: 编辑器字体族的设置、作用范围与回退规则见
/// .agents/notes/implemented/feature/2026-10-07-macos-editor-programming-font-family.md
enum MacEditorFontCatalog {
    /// Selectable families: the bundled monospaced family first, then every
    /// installed monospaced family in localized order.
    static func editorFamilies() -> [String] {
        index.monospaced
    }

    /// True when the resolved family can actually be rendered. The bundled
    /// family counts as available because its faces ship inside the app bundle.
    static func isAvailable(family: String) -> Bool {
        let normalized = EditorFontResolution.normalizedFamily(family)

        if EditorFontResolution.usesBundledMonospacedFamily(normalized) { return true }
        return index.canonical[normalized.lowercased()] != nil
    }

    /// Family the editor should really use for a configured value. A font that
    /// was uninstalled, renamed or never existed falls back to the bundled
    /// family instead of leaving the editor on a family macOS cannot resolve.
    static func resolvedFamily(_ configured: String) -> String {
        let normalized = EditorFontResolution.normalizedFamily(configured)

        if EditorFontResolution.usesBundledMonospacedFamily(normalized) { return normalized }
        return index.canonical[normalized.lowercased()] ?? EditorFontDefaults.monospacedFamily
    }

    /// AppKit font for a resolved family.
    ///
    /// The bundled family keeps the exact eight-face mapping owned by
    /// `LitheTheme.editorFont`. A user-selected family is asked for the closest
    /// available weight instead, because most system families ship only a few
    /// faces; requesting a missing face must degrade, not silently drop to the
    /// system monospaced font.
    ///
    /// A user-selected family also gets the bundled family as its first cascade
    /// fallback, so a glyph the chosen font does not contain renders in the
    /// shipped font instead of an arbitrary system face. Characters the bundled
    /// family also lacks (Chinese, for example) still fall through to the
    /// system cascade, which is the existing behaviour.
    ///
    /// Resolved faces are cached because callers ask per row while drawing a
    /// diff; resolving a family through `NSFontManager` on every row would put a
    /// font lookup in the text layout path.
    static func font(family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let resolved = resolvedFamily(family)
        let key = FaceKey(family: resolved, size: size, weight: weight.rawValue)

        faceLock.lock()
        if let cached = faces[key] {
            faceLock.unlock()
            return cached
        }
        faceLock.unlock()

        var face: NSFont
        if EditorFontResolution.usesBundledMonospacedFamily(resolved) {
            face = LitheTheme.editorFont(size: size, weight: weight)
        } else if let systemFace = NSFontManager.shared.font(
            withFamily: resolved, traits: [], weight: managerWeight(weight), size: size
        ) {
            face = systemFace
        } else {
            face = NSFont(name: resolved, size: size) ?? LitheTheme.editorFont(size: size, weight: weight)
        }

        if !EditorFontResolution.usesBundledMonospacedFamily(resolved) {
            face = addingBundledFallback(to: face, size: size, weight: weight)
        }

        faceLock.lock()
        faces[key] = face
        faceLock.unlock()
        return face
    }

    /// Whether a family renders every character group the product requires, and
    /// which groups it cannot. Never blocks a choice: the editor keeps the
    /// selected family and relies on the fallback chain for the missing glyphs.
    static func coverage(
        family: String,
        requirements: EditorFontRequirements
    ) -> EditorFontCoverage {
        let resolved = resolvedFamily(family)
        let face = font(family: resolved, size: 13)
        let missing = requirements.scripts.filter { !covers(face, samples: $0.samples) }
        return EditorFontCoverage(family: resolved, missingScripts: missing)
    }

    /// CSS family stack for the embedded editor.
    ///
    /// The embedded editor resolves fonts through CSS, so the shipped family is
    /// appended after the configured one. Without it a glyph missing from the
    /// chosen font would come from Monaco's generic `monospace` fallback, which
    /// differs per machine; with it the fallback is the same bundled font the
    /// native surfaces use.
    static func editorFontStack(_ configured: String) -> String {
        let resolved = resolvedFamily(configured)
        // A family name containing the CSS quote character would break the stack.
        let name = resolved.replacingOccurrences(of: "\"", with: "'")
        let quoted = "\"\(name)\""

        if EditorFontResolution.usesBundledMonospacedFamily(resolved) {
            return "\(quoted), monospace"
        }
        return "\(quoted), \"\(EditorFontDefaults.monospacedFamily)\", monospace"
    }

    /// Adds the bundled descriptor to a face's cascade list.
    private static func addingBundledFallback(
        to face: NSFont,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont {
        let bundled = LitheTheme.editorFont(size: size, weight: weight).fontDescriptor
        let descriptor = face.fontDescriptor.addingAttributes([.cascadeList: [bundled]])
        return NSFont(descriptor: descriptor, size: size) ?? face
    }

    /// True when every sample character has a real glyph in `face`.
    ///
    /// One character is probed at a time so a single missing glyph cannot be
    /// hidden by a batch result, and a zero glyph id (`.notdef`) counts as
    /// missing even when CoreText reports success.
    private static func covers(_ face: NSFont, samples: String) -> Bool {
        let ctFace = face as CTFont

        for character in samples {
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let mapped = CTFontGetGlyphsForCharacters(ctFace, &units, &glyphs, units.count)
            guard mapped, !glyphs.contains(0) else { return false }
        }
        return true
    }

    /// Identity of a resolved face. Sizes and weights come from a small fixed set
    /// of diff and editor metrics, so this cache stays bounded.
    private struct FaceKey: Hashable {
        let family: String
        let size: CGFloat
        let weight: CGFloat
    }

    private static let faceLock = NSLock()
    private static var faces: [FaceKey: NSFont] = [:]

    // MARK: - Discovery

    private struct FamilyIndex {
        /// Lowercased family name to its canonical spelling.
        let canonical: [String: String]
        /// Selectable monospaced families, bundled family first.
        let monospaced: [String]
    }

    /// Built once per process. `NSFontManager` enumeration and per-family
    /// measurement are expensive enough that a settings page must not repeat
    /// them on every redraw.
    private static let index = buildIndex()

    private static func buildIndex() -> FamilyIndex {
        var canonical: [String: String] = [:]
        var monospaced: [String] = []

        for family in NSFontManager.shared.availableFontFamilies {
            let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            if canonical[key] == nil { canonical[key] = trimmed }
            if isMonospaced(family: trimmed) { monospaced.append(trimmed) }
        }

        // The bundled family must stay selectable even when the system also has
        // no matching face, and it must not appear twice when it does.
        let bundled = EditorFontDefaults.monospacedFamily
        let bundledKey = bundled.lowercased()
        if canonical[bundledKey] == nil { canonical[bundledKey] = bundled }
        monospaced.removeAll { $0.lowercased() == bundledKey }
        monospaced.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        return FamilyIndex(canonical: canonical, monospaced: [bundled] + monospaced)
    }

    /// Detects fixed pitch from the family's regular face.
    ///
    /// The symbolic trait is authoritative when a font declares it, but several
    /// monospaced families (and most screen fonts shipped by other vendors)
    /// omit it. Measured advances catch those without trusting the name.
    private static func isMonospaced(family: String) -> Bool {
        guard let face = regularFace(family: family) else { return false }

        if face.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }

        let advances = ["i", "W", "0"].map {
            ($0 as NSString).size(withAttributes: [.font: face]).width
        }
        guard let first = advances.first, first > 0 else { return false }
        return advances.allSatisfy { abs($0 - first) < 0.01 }
    }

    /// Regular face of a family. `availableMembers(ofFontFamily:)` reports
    /// `[postScriptName, styleName, weight, traits]` per face; the style name is
    /// used because the numeric weight index differs between vendors.
    private static func regularFace(family: String) -> NSFont? {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let regular = members.first { member in
            guard let style = member.dropFirst().first as? String else { return false }
            return style.localizedCaseInsensitiveContains("regular")
        } ?? members.first

        if let name = regular?.first as? String, let font = NSFont(name: name, size: 12) {
            return font
        }
        return NSFont(name: family, size: 12)
    }

    /// Closest `NSFontManager` weight index (0...15, regular is 5) for a
    /// requested AppKit weight.
    private static func managerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight.rawValue {
        case ..<NSFont.Weight.thin.rawValue: 2
        case ..<NSFont.Weight.light.rawValue: 3
        case ..<NSFont.Weight.regular.rawValue: 4
        case ..<NSFont.Weight.medium.rawValue: 5
        case ..<NSFont.Weight.semibold.rawValue: 6
        case ..<NSFont.Weight.bold.rawValue: 8
        case ..<NSFont.Weight.heavy.rawValue: 9
        default: 11
        }
    }
}
