import Foundation
import Testing
@testable import Lithe

@Suite("macOS performance baseline definitions")
struct LithePerformanceBaselineTests {
    @Test
    func keepsTheThreeEditorFixtureSizesStable() {
        #expect(LithePerformanceFixture.all.map(\.label) == ["10KiB", "500KiB", "2MiB"])
        #expect(LithePerformanceFixture.all.map(\.byteCount) == [10 * 1024, 500 * 1024, 2 * 1024 * 1024])
    }

    @Test
    func keepsTheScenarioOrderStableForReports() {
        #expect(LithePerformanceScenario.allCases.map(\.rawValue) == ["T", "N", "D", "S", "Term", "R"])
    }

    @Test
    func configurationMarkerIncludesTheMeasurementIdentity() {
        let marker = LithePerformanceBaseline.configurationMarker(environment: [
            "LITHE_PERFORMANCE_SCENARIO": "T",
            "LITHE_PERFORMANCE_FIXTURE_BYTES": "512000"
        ])

        #expect(marker == "LITHE_BASELINE_CONFIG scenario=T fixture_bytes=512000 fps_monitor=disabled")
    }
}
