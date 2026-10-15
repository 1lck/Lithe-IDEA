import Foundation

// Note: .agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md
// UTC time is both the rolling identity and its user-visible label. Keep date
// parsing strict so malformed metadata never invents a build time.
enum AutoBuildTimestamp {
    static func display(timestamp: String?) -> String? {
        timestamp.flatMap { display($0, format: "yyyy-MM-dd'T'HH:mm:ss'Z'") }
    }

    static func display(build: String?) -> String? {
        build.flatMap { display($0, format: "yyyyMMdd.HHmmss") }
    }

    static func label(timestamp: String? = nil, build: String? = nil) -> String {
        guard let time = display(timestamp: timestamp) ?? display(build: build) else { return "AutoBuild" }
        return String(format: String(localized: "AutoBuild — Built at %@"), time)
    }

    private static func display(_ value: String, format: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = format
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }
}
