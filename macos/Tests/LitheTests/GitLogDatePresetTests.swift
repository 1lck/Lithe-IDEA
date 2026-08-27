import Foundation
@testable import Lithe
@testable import LitheGitModule
import Testing

struct GitLogDatePresetTests {
    @Test
    func calendarRangePresetsExcludeFutureCommits() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 27,
            hour: 12
        )))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        let futureDate = try #require(calendar.date(byAdding: .hour, value: 12, to: tomorrow))
        let futureCommit = GitCommit(
            hash: "3333333333333333",
            shortHash: "3333333",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: ISO8601DateFormatter().string(from: futureDate),
            subject: "Future commit",
            decorations: ""
        )

        for preset in [GitLogDatePreset.today, .lastSevenDays, .lastThirtyDays] {
            let query = GitLogQuery.parse(preset.queryTokens(now: now).joined(separator: " "))

            #expect(query.beforeDate == tomorrow)
            #expect(!query.matchesMetadata(futureCommit, identity: nil))
        }
    }
}
