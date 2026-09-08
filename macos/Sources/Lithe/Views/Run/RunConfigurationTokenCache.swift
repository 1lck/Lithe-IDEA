import Foundation

/// Parses the comma- and newline-separated token lists the Run tool window keeps
/// in `@AppStorage`, memoized on the raw string.
///
/// The stored strings are re-parsed on every access, and `isPinned` is called
/// inside a filter over every configuration, so a body pass re-split the whole
/// list once per configuration. Caching on the raw value turns that O(n·m) back
/// into O(m) while keeping `@AppStorage` the source of truth.
///
/// Held as a reference box in `@State` (like `EditorViewportStore`) so caching
/// never invalidates the view that reads it.
@MainActor
final class RunConfigurationTokenCache {
    private var lastRawValue: String?
    private var lastTokens: Set<String> = []

    /// - Parameter separator: `,` for collapsed executions, `\n` for pin tokens.
    func tokens(from rawValue: String, separator: Character) -> Set<String> {
        if lastRawValue == rawValue { return lastTokens }
        let tokens = Set(rawValue.split(separator: separator).map(String.init))
        lastRawValue = rawValue
        lastTokens = tokens
        return tokens
    }
}
