import Foundation

/// Localizes presentation using the app selection without changing diagnostic output.
struct LanguageTestLocalization {
    private let bundle: Bundle

    init(language: AppLanguage, resourceBundle: Bundle = .main) {
        bundle = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? resourceBundle
    }

    func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func count(_ label: String, _ count: Int) -> String {
        String(format: text("%@ %lld"), text(label), Int64(count))
    }

    func error(_ message: String) -> String {
        for framework in ["Maven", "JUnit"] {
            let prefix = framework + " test run timed out after "
            let suffix = " seconds."
            guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { continue }
            let seconds = String(message.dropFirst(prefix.count).dropLast(suffix.count))
            guard Int(seconds) != nil else { return message }
            return String(format: text("%@ test run timed out after %@ seconds."), framework, seconds)
        }
        return text(message)
    }
}
