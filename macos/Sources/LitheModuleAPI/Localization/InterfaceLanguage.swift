import Foundation

/// Process-wide holder of the interface language chosen in Settings.
///
/// `String(localized:)` picks a `.lproj` from the *system* languages, and its `locale:`
/// argument only affects number and date formatting. Product copy that is built outside a
/// SwiftUI view (errors, alerts, status text, notifications) therefore passes
/// `bundle: .appLanguage` so it follows the application language instead.
public enum InterfaceLanguage {
    private static let state = LockedState()

    /// Records the language identifier (for example `en` or `zh-Hans`) used by `Bundle.appLanguage`.
    public static func select(_ identifier: String) {
        state.select(identifier)
    }

    fileprivate static func bundle() -> Bundle {
        state.bundle()
    }

    /// Locale of the selected language, used for number and date formatting.
    public static var locale: Locale { state.locale() }

    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var identifier: String?
        private var cached: Bundle?

        func select(_ identifier: String) {
            lock.lock()
            defer { lock.unlock() }
            guard self.identifier != identifier else { return }
            self.identifier = identifier
            // Resolve once per change: looking up the `.lproj` per call is measurably slow in long lists.
            cached = Bundle.main.url(forResource: identifier, withExtension: "lproj").flatMap(Bundle.init(url:))
        }

        func locale() -> Locale {
            lock.lock()
            defer { lock.unlock() }
            return identifier.map(Locale.init(identifier:)) ?? .current
        }

        func bundle() -> Bundle {
            lock.lock()
            defer { lock.unlock() }
            return cached ?? .main
        }
    }
}

public extension Bundle {
    /// The `.lproj` bundle of the application language, or `Bundle.main` before one is selected.
    static var appLanguage: Bundle { InterfaceLanguage.bundle() }
}

/// The single entry point for product copy resolved outside a SwiftUI `Text`.
///
/// Every call follows the application language chosen in Settings, never the system
/// language. `scripts/i18n/verify-app-language-localization.mjs` rejects direct
/// `String(localized:)` and `NSLocalizedString` use elsewhere.
public enum L10n {
    /// Resolves a literal or interpolated string, for example `L10n.string("Saved \(name)")`.
    public static func string(_ value: String.LocalizationValue, locale: Locale? = nil) -> String {
        String(localized: value, bundle: .appLanguage, locale: locale ?? InterfaceLanguage.locale)
    }

    /// Resolves a runtime key verbatim, such as a `%lld` format string chosen at the call site.
    public static func string(key: String) -> String {
        Bundle.appLanguage.localizedString(forKey: key, value: key, table: nil)
    }
}
