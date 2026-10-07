import Foundation

/// Display formatting shared by the notification balloon and the notification
/// center list.
///
/// The model merges repeated messages into one entry and records how often the
/// message appeared. Turning that count into user-visible text stays in the view
/// layer so `WorkbenchNotification.message` remains a plain localization key.
enum WorkbenchNotificationPresentation {
    /// Appends the accumulated occurrence count to an already localized message.
    ///
    /// A message shown once keeps its plain text; only the second and later
    /// appearances carry the `（2）`, `（3）`, … suffix. The bundle is injectable so
    /// a capture or test renders the shipped translation instead of falling back
    /// to the format key, the same way `gitLocalizedFormat` resolves UI text.
    static func message(
        _ message: String,
        occurrenceCount: Int,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        guard occurrenceCount > 1 else { return message }
        let localizedBundle = bundle.url(forResource: locale.identifier, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? bundle
        let format = localizedBundle.localizedString(forKey: "%@ (%lld)",
            value: "%@ (%lld)",
            table: nil)
        return String(format: format, locale: locale, message, Int64(occurrenceCount))
    }
}
