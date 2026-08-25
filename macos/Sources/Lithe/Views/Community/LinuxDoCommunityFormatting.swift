import AppKit
import Foundation

enum LinuxDoCommunityFormatting {
    static func compactNumber(_ value: UInt64) -> String {
        switch value {
        case 1_000_000...:
            compact(Double(value) / 1_000_000, suffix: "M")
        case 1_000...:
            compact(Double(value) / 1_000, suffix: "K")
        default:
            String(value)
        }
    }

    static func relativeDate(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func initials(_ value: String) -> String {
        let parts = value.split(whereSeparator: \.isWhitespace)
        let characters = parts.prefix(2).compactMap(\.first)
        if characters.isEmpty {
            return String(value.prefix(1)).uppercased()
        }
        return String(characters).uppercased()
    }

    static func plainText(_ sanitizedHTML: String) -> String {
        guard let data = sanitizedHTML.data(using: .utf8),
              let value = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else { return sanitizedHTML }
        return value.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let format = value >= 10 ? "%.0f%@" : "%.1f%@"
        return String(format: format, value, suffix)
    }
}
