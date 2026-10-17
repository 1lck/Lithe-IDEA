import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Performance chart presentation", .serialized)
struct DebugPerformanceChartTests {
    private let samples = [
        DebugPerformanceSample(timestamp: 10, cpuPercent: 40, memoryUsedBytes: 400, memoryCapacityBytes: 1_000),
        DebugPerformanceSample(timestamp: 40, cpuPercent: 60, memoryUsedBytes: 600, memoryCapacityBytes: 1_000),
        DebugPerformanceSample(timestamp: 70, cpuPercent: nil, memoryUsedBytes: 500, memoryCapacityBytes: 1_000)
    ]

    @Test func hoverSnapsToRealSamplesAndKeepsMissingCPU() throws {
        #expect(DebugPerformanceChart.nearestSample(in: [], to: 40) == nil)
        #expect(DebugPerformanceChart.nearestSample(in: samples, to: .nan) == nil)
        #expect(DebugPerformanceChart.nearestSample(in: samples, to: -.infinity) == nil)
        #expect(DebugPerformanceChart.nearestSample(in: samples, to: -100)?.timestamp == 10)
        #expect(DebugPerformanceChart.nearestSample(in: samples, to: 38)?.timestamp == 40)
        #expect(DebugPerformanceChart.nearestSample(in: samples, to: 100)?.timestamp == 70)
        let missing = try #require(DebugPerformanceChart.nearestSample(in: samples, to: 69))
        #expect(missing.cpuPercent == nil)
        #expect(missing.memoryUsedBytes == 500)
    }

    @Test func timeAdvancesLeftAndKeepsTheLatestSampleAtTheRightEdge() {
        let first = DebugPerformanceChart.timeDomain(latestTimestamp: 10)
        let next = DebugPerformanceChart.timeDomain(latestTimestamp: 11)
        #expect(first.upperBound == 10)
        #expect(next.upperBound == 11)
        #expect(first.upperBound - first.lowerBound == 60)
        #expect(next.upperBound - next.lowerBound == 60)
        let xBefore = (10 - first.lowerBound) / 60
        let xAfter = (10 - next.lowerBound) / 60
        #expect(xBefore == 1)
        #expect(xAfter < xBefore)
        #expect(!next.contains(-50))
    }

    @Test(arguments: [true, false], [true, false])
    func plotsHaveFilledAreaInBothThemes(dark: Bool, shortHistory: Bool) throws {
        let points = shortHistory ? samples.enumerated().map { offset, sample in
            DebugPerformanceSample(timestamp: 10 + Double(offset), cpuPercent: sample.cpuPercent,
                memoryUsedBytes: sample.memoryUsedBytes, memoryCapacityBytes: sample.memoryCapacityBytes)
        } : samples
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            DebugPerformanceChart(samples: points, cpu: true, hoveredTime: .constant(shortHistory ? 11 : 40))
            DebugPerformanceChart(samples: points, cpu: false, hoveredTime: .constant(shortHistory ? 11 : 40))
        }.frame(width: 360, height: 320)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        // At the first quarter of the plot, the CPU area covers many rows.
        // A lone 1pt LineMark cannot satisfy this assertion.
        func filledRows(at x: Int) -> Int {
            (0..<(bitmap.pixelsHigh / 2)).filter { y in
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.greenComponent - c.redComponent > 0.015 && c.greenComponent - c.blueComponent > 0.005
            }.count
        }
        if shortHistory {
            #expect(filledRows(at: bitmap.pixelsWide / 4) == 0, "Unsampled time must stay blank")
            #expect(filledRows(at: bitmap.pixelsWide * 340 / 360) > 20, "New history must begin at the right edge")
        } else {
            #expect(filledRows(at: bitmap.pixelsWide / 4) > 20, "CPU area missing")
        }
        if let directory = ProcessInfo.processInfo.environment["LITHE_CHART_SNAPSHOT_DIRECTORY"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("performance-\(dark ? "dark" : "light")\(shortHistory ? "-startup" : "").png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }
}
