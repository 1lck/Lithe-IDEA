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
        for preset in [GitLogDatePreset.today, .lastSevenDays, .lastThirtyDays] {
            let query = preset.applying(to: GitLogQuery(), now: now)

            #expect(query.beforeDate == tomorrow)
            #expect(futureDate >= query.beforeDate!)
        }
    }

    @Test
    func todayUsesSystemCalendarBoundariesAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let cases: [(Double, Double, Double)] = [
            (1773000000, 1772956800, 1773039600), // 23-hour spring day
            (1793560000, 1793516400, 1793606400), // 25-hour autumn day
        ]
        for (now, start, end) in cases {
            let query = GitLogDatePreset.today.applying(to: GitLogQuery(), now: Date(timeIntervalSince1970: now), calendar: calendar)
            #expect(query.afterDate == Date(timeIntervalSince1970: start))
            #expect(query.beforeDate == Date(timeIntervalSince1970: end))
        }
    }

}
