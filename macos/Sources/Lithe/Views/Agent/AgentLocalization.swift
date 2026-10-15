import Foundation

/// Resolve product copy at the presentation edge using the selected interface language.
/// Agent-provided messages, model names and history titles remain verbatim.
enum AgentLocalization {
    static func string(_ key: String.LocalizationValue, locale: Locale, bundle: Bundle = .main) -> String {
        let languages = [locale.identifier, locale.language.languageCode?.identifier ?? locale.identifier]
        let localizedBundle = languages.lazy.compactMap {
            bundle.url(forResource: $0, withExtension: "lproj").flatMap(Bundle.init(url:))
        }.first ?? bundle
        return String(localized: key, bundle: localizedBundle, locale: locale)
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
