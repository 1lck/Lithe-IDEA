import Foundation

/// Resolve product copy at the presentation edge using the selected interface language.
/// Agent-provided messages, model names and history titles remain verbatim.
enum AgentLocalization {
    /// Every Agent label resolves through here on each render. Looking up the
    /// `.lproj` directory per call made long transcripts and lists measurably slow.
    private static let localizedBundles = NSCache<NSString, Bundle>()

    static func string(_ key: String.LocalizationValue, locale: Locale, bundle: Bundle = .main) -> String {
        String(localized: key, bundle: localizedBundle(bundle, locale: locale), locale: locale)
    }

    private static func localizedBundle(_ bundle: Bundle, locale: Locale) -> Bundle {
        let cacheKey = "\(bundle.bundlePath)|\(locale.identifier)" as NSString
        if let cached = localizedBundles.object(forKey: cacheKey) { return cached }
        let languages = [locale.identifier, locale.language.languageCode?.identifier ?? locale.identifier]
        let resolved = languages.lazy.compactMap {
            bundle.url(forResource: $0, withExtension: "lproj").flatMap(Bundle.init(url:))
        }.first ?? bundle
        localizedBundles.setObject(resolved, forKey: cacheKey)
        return resolved
    }

    static func message(_ value: String, locale: Locale, bundle: Bundle = .main) -> String {
        let prefix = "Cannot create a new conversation: "
        if value.hasPrefix(prefix) {
            let reason = String(value.dropFirst(prefix.count))
            return String(format: string("Cannot create a new conversation: %@", locale: locale, bundle: bundle),
                          string(String.LocalizationValue(reason), locale: locale, bundle: bundle))
        }
        return string(String.LocalizationValue(value), locale: locale, bundle: bundle)
    }

}
