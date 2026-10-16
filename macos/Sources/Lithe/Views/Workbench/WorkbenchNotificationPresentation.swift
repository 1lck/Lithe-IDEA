import Foundation

/// Display formatting shared by the notification balloon and the notification
/// center list.
///
/// The model merges repeated messages into one entry and records how often the
/// message appeared. Turning that count into user-visible text stays in the view
/// layer so the model retains a stable localization key and raw arguments.
enum WorkbenchNotificationPresentation {
    /// Resolves the stored message key in the app locale, then appends its occurrence count.
    ///
    /// A message shown once keeps its plain text; only the second and later
    /// appearances carry the `（2）`, `（3）`, … suffix. The bundle is injectable so
    /// a capture or test renders the shipped translation instead of falling back
    /// to the format key, the same way `gitLocalizedFormat` resolves UI text.
    static func message(
        _ message: String,
        arguments: [String] = [],
        occurrenceCount: Int,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let localizedBundle = bundle.url(forResource: locale.identifier, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? bundle
        let template = localizedBundle.localizedString(forKey: message, value: message, table: nil)
        let localizedMessage = arguments.isEmpty ? template
            : String(format: template, locale: locale, arguments: arguments.map { $0 as CVarArg })
        guard occurrenceCount > 1 else { return localizedMessage }
        let format = localizedBundle.localizedString(forKey: "%@ (%lld)",
            value: "%@ (%lld)",
            table: nil)
        return String(format: format, locale: locale, localizedMessage, Int64(occurrenceCount))
    }
}
