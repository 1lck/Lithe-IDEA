import Foundation

/// Editor typography defaults shared by the settings model, the theme font
/// entry points and the macOS font catalog.
///
/// The code editor always starts on the monospaced family that ships inside the
/// app bundle (`macos/Resources/Fonts`, registered by `MacBundledFontRegistry`),
/// so an existing installation that never opened the font setting keeps exactly
/// the rendering it had before the setting existed. Only an explicit user choice
/// moves the editor off the bundled family; the terminal, the output tool window
/// and the commit message field keep using the bundled faces.
enum EditorFontDefaults {
    /// Family name of the bundled JetBrains Mono 2.304 static faces.
    static let monospacedFamily = "JetBrains Mono"
}

/// Platform-neutral policy for the stored editor font family.
///
/// This decides what a stored value *means*; whether the family is actually
/// installed can only be answered by the platform font catalog, so the models
/// layer deliberately stops at normalization and never queries AppKit.
enum EditorFontResolution {
    /// Trims a stored value and replaces a missing or empty one with the bundled
    /// family, so a cleared preference restores the shipped default instead of
    /// leaving the editor on an unbounded empty family name.
    static func normalizedFamily(_ stored: String?) -> String {
        guard let stored else { return EditorFontDefaults.monospacedFamily }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? EditorFontDefaults.monospacedFamily : trimmed
    }

    /// True when the configured family is the bundled monospaced family. Those
    /// requests keep the exact bundled face mapping (all eight weights) instead
    /// of the degraded system-family lookup used for user-selected fonts.
    static func usesBundledMonospacedFamily(_ family: String) -> Bool {
        normalizedFamily(family) == EditorFontDefaults.monospacedFamily
    }
}
