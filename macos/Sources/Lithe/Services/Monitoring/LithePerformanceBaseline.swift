import Foundation

enum LithePerformanceScenario: String, CaseIterable, Codable, Sendable {
    case typing = "T"
    case navigation = "N"
    case dragging = "D"
    case search = "S"
    case terminal = "Term"
    case runOutput = "R"

    var title: String {
        switch self {
        case .typing:
            "连续输入"
        case .navigation:
            "打开大文件后空闲"
        case .dragging:
            "连续拖动分栏"
        case .search:
            "Search Everywhere"
        case .terminal:
            "终端高频输出"
        case .runOutput:
            "Run/Tests 输出"
        }
    }
}

struct LithePerformanceFixture: Codable, Equatable, Sendable {
    let label: String
    let byteCount: Int

    static let all: [LithePerformanceFixture] = [
        LithePerformanceFixture(label: "10KiB", byteCount: 10 * 1024),
        LithePerformanceFixture(label: "500KiB", byteCount: 500 * 1024),
        LithePerformanceFixture(label: "2MiB", byteCount: 2 * 1024 * 1024)
    ]
}

enum LithePerformanceBaseline {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1"
    }

    static func configurationMarker(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let scenario = environment["LITHE_PERFORMANCE_SCENARIO"] ?? "unknown"
        let fixtureBytes = environment["LITHE_PERFORMANCE_FIXTURE_BYTES"] ?? "unknown"
        return "LITHE_BASELINE_CONFIG scenario=\(scenario) fixture_bytes=\(fixtureBytes) fps_monitor=disabled"
    }

}
