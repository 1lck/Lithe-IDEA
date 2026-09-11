import Foundation

/// Resolves display strings using the selected app language, including values
/// passed through String-based tree rows. Maven identifiers and diagnostics stay exact.
struct MavenDependencyLocalization {
    private let bundle: Bundle

    init(language: AppLanguage, resourceBundle: Bundle = .main) {
        bundle = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? resourceBundle
    }

    func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func subtitle(_ dependency: MavenDependency) -> String {
        let classifier = dependency.classifier.map { ":" + $0 } ?? ""
        let marker: String
        switch dependency.resolution {
        case .resolved:
            marker = ""
        case .omittedDuplicate:
            marker = text(" (duplicate omitted)")
        case .omittedConflict:
            marker = String(format: text(" (conflict -> %@)"),
                            dependency.selectedVersion ?? text("selected version"))
        }
        return dependency.groupID + ":" + dependency.version + ":" + dependency.type
            + classifier + " [" + dependency.scope + "]" + marker
    }

    func error(_ message: String) -> String {
        let startupPrefix = "Unable to start Maven dependency resolution: "
        if message.hasPrefix(startupPrefix) {
            return String(format: text("Unable to start Maven dependency resolution: %@"),
                          String(message.dropFirst(startupPrefix.count)))
        }
        let exitPrefix = "Maven dependency resolution exited with code "
        if message.hasPrefix(exitPrefix), message.hasSuffix(".") {
            let code = String(message.dropFirst(exitPrefix.count).dropLast())
            if Int32(code) != nil {
                return String(format: text("Maven dependency resolution exited with code %@."), code)
            }
        }
        // Unknown Core, Maven and platform errors retain their original detail.
        return text(message)
    }
}
