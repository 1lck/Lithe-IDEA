@testable import Lithe
import LitheGitModule
import LitheGitPerformanceSupport
import AppKit
import Testing

@Suite("Git graph performance baseline", .serialized)
struct GitGraphPerformanceBaselineTests {
    @Test("The synthetic history is deterministic and child-before-parent")
    func syntheticHistoryIsDeterministic() {
        let first = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)
        let second = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)

        #expect(first == second)
        #expect(SyntheticGitGraphFixture.parentsFollowChildren(in: first))
        #expect(first.reduce(0) { $0 + $1.parentHashes.count } == 1_299)
    }

    @Test("The 1,000-commit graph preserves the initial work baseline")
    func oneThousandCommitLayoutBaseline() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)
        let layout = GitGraphLayoutService.layout(commits: commits)

        #expect(GitGraphStructureBaseline(layout: layout) == .expected(commitCount: 1_000))
        #expect(
            GitGraphStructureBaseline.signature(of: layout)
                == GitGraphStructureBaseline.expectedSignature(commitCount: 1_000)
        )
        #expect(layout.rows.map(\.commit.hash) == commits.map(\.hash))
        #expect(GitGraphStructureBaseline.hasContinuousLanes(layout))
    }

    @Test("The 5,000-commit graph scales within the committed work envelope")
    func fiveThousandCommitLayoutBaseline() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 5_000)
        let layout = GitGraphLayoutService.layout(commits: commits)

        #expect(SyntheticGitGraphFixture.parentsFollowChildren(in: commits))
        #expect(GitGraphStructureBaseline(layout: layout) == .expected(commitCount: 5_000))
        #expect(
            GitGraphStructureBaseline.signature(of: layout)
                == GitGraphStructureBaseline.expectedSignature(commitCount: 5_000)
        )
        #expect(layout.rows.map(\.commit.hash) == commits.map(\.hash))
        #expect(GitGraphStructureBaseline.hasContinuousLanes(layout))
    }

    @Test("The native graph view reduces render entry points for a viewport")
    func nativeGraphViewRenderWorkBaseline() {
        let benchmark = GitGraphRenderBenchmark(rowCount: 5_000)

        #expect(benchmark.legacyCanvasInstances == 5_000)
        #expect(benchmark.nativeViewInstances == 1)
        #expect(benchmark.legacyViewportDrawCalls == 40)
        #expect(benchmark.nativeViewportDrawCalls == 1)
        #expect(benchmark.instanceReductionPercent == 99.98)
        #expect(benchmark.viewportDrawReductionPercent == 97.5)
    }

    @Test("The native graph view frame sample stays within the test budget")
    @MainActor
    func nativeGraphViewFrameSample() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)
        let layout = GitGraphLayoutService.layout(commits: commits)
        let view = GitGraphFrameSamplingView(rows: layout.rows, rowHeight: 30)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 120,
            pixelsHigh: 1_000 * 30,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(10)

        for _ in 0..<1 {
            _ = sampleFrame(view: view, context: context, clock: clock)
        }
        for _ in 0..<10 {
            samples.append(sampleFrame(view: view, context: context, clock: clock))
        }

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        let maximum = sorted.last ?? 0
        print("GitGraph frame sample: rows=1000, samples=10, median=\(String(format: "%.3f", median))ms, p95=\(String(format: "%.3f", p95))ms, max=\(String(format: "%.3f", maximum))ms")
        #expect(samples.count == 10)
        #expect(median < 100)
    }

    @Test("The routing snapshot preserves layout topology and ordering")
    func routingSnapshotPreservesTopology() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)
        let layout = GitGraphLayoutService.layout(commits: commits)
        let snapshot = GitGraphLayoutService.routingSnapshot(for: layout)

        #expect(snapshot.laneCount == layout.laneCount)
        #expect(snapshot.rows.count == layout.rows.count)
        for (index, pair) in zip(layout.rows, snapshot.rows).enumerated() {
            let (layoutRow, snapshotRow) = pair
            #expect(snapshotRow.rowIndex == index)
            #expect(snapshotRow.nodeLane == layoutRow.lane)
            #expect(snapshotRow.incoming.map(\.lane) == layoutRow.incomingLaneColors.enumerated().compactMap { lane, color in color.map { _ in lane } })
            #expect(snapshotRow.routes.map(\.targetLane) == layoutRow.parentEdges.map(\.targetLane))
            #expect(snapshotRow.routes.map(\.colorIndex) == layoutRow.parentEdges.map(\.colorIndex))
            #expect(snapshotRow.routes.map(\.isMissing) == layoutRow.parentEdges.map(\.isMissing))
        }
    }

    @Test("The routing snapshot keeps terminal routes for truncated history")
    func routingSnapshotPreservesMissingParent() {
        let commits = [
            GitCommit(
                hash: "HEAD",
                shortHash: "HEAD",
                parentHashes: ["OLDER"],
                authorName: "fixture",
                authorEmail: "fixture@example.invalid",
                date: "2026/09/04",
                subject: "HEAD",
                decorations: "HEAD -> main"
            )
        ]
        let layout = GitGraphLayoutService.layout(commits: commits)
        let snapshot = GitGraphLayoutService.routingSnapshot(for: layout)

        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].routes.count == 1)
        #expect(snapshot.rows[0].routes[0].targetLane == nil)
        #expect(snapshot.rows[0].routes[0].isMissing)
    }

    @Test("The Worktrees projection stays bounded for a large list")
    func worktreeProjectionBaseline() {
        let benchmark = GitWorktreeProjectionBenchmark.run(worktreeCount: 1_000)
        print(
            "GitWorktrees projection: rows=\(benchmark.worktreeCount), matches=\(benchmark.matchedCount), samples=\(benchmark.sampleCount), median=\(String(format: "%.3f", benchmark.medianMs))ms, p95=\(String(format: "%.3f", benchmark.p95Ms))ms"
        )
        #expect(benchmark.matchedCount == 111)
        #expect(benchmark.sampleCount == 21)
        #expect(benchmark.p95Ms < 100)
    }

    @Test("The commit file tree projection stays bounded for large diffs")
    func commitFileTreeProjectionBaseline() {
        let benchmark = GitCommitFileTreeProjectionBenchmark.run(fileCount: 5_000)
        print(
            "Git commit file-tree projection: files=\(benchmark.fileCount), visible=\(benchmark.visibleItemCount), samples=\(benchmark.sampleCount), median=\(String(format: "%.3f", benchmark.medianMs))ms, p95=\(String(format: "%.3f", benchmark.p95Ms))ms"
        )
        #expect(benchmark.visibleItemCount > benchmark.fileCount)
        #expect(benchmark.sampleCount == 21)
        #expect(benchmark.p95Ms < 30)
    }

    @Test("The native Worktree rows surface samples only the visible viewport")
    @MainActor
    func nativeWorktreeRowsSurfaceBaseline() throws {
        let rows = (0..<5_000).map { index in
            GitWorktreeRowsSnapshot.Row.commit(
                subject: "Synthetic worktree commit \(index)",
                author: "Lithe Performance Fixture",
                date: "2026/09/05 00:00"
            )
        }
        let snapshot = GitWorktreeRowsSnapshot(
            identity: .history(inspectionVersion: 1, query: ""),
            rows: rows
        )
        let view = GitWorktreeRowsNSView(frame: CGRect(
            x: 0,
            y: 0,
            width: 900,
            height: CGFloat(rows.count) * GitWorktreeRowsView.rowHeight
        ))
        view.update(snapshot: snapshot, rowHeight: GitWorktreeRowsView.rowHeight)
        let viewport = CGRect(
            x: 0,
            y: CGFloat(2_500) * GitWorktreeRowsView.rowHeight,
            width: 900,
            height: 420
        )
        let visibleRange = try #require(GitWorktreeRowsNSView.visibleRowRange(
            rowCount: rows.count,
            rowHeight: GitWorktreeRowsView.rowHeight,
            dirtyRect: viewport
        ))
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 900,
            pixelsHigh: 420,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(10)
        for _ in 0..<10 {
            let start = clock.now
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.draw(viewport)
            NSGraphicsContext.restoreGraphicsState()
            samples.append(milliseconds(clock.now - start))
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print(
            "Worktree native rows: total=\(rows.count), visible=\(visibleRange.count), samples=\(samples.count), median=\(String(format: "%.3f", median))ms, p95=\(String(format: "%.3f", p95))ms"
        )
        #expect(visibleRange.count <= 14)
        #expect(median < 30)
        #expect(p95 < 100)
    }

    @Test("The Worktree rows container owns one native scrolling viewport")
    @MainActor
    func nativeWorktreeRowsScrollContainerBaseline() throws {
        let rows = (0..<5_000).map { index in
            GitWorktreeRowsSnapshot.Row.commit(
                subject: "Synthetic worktree commit \(index)",
                author: "Lithe Performance Fixture",
                date: "2026/09/05 00:00"
            )
        }
        let snapshot = GitWorktreeRowsSnapshot(
            identity: .history(inspectionVersion: 1, query: ""),
            rows: rows
        )
        let scrollView = GitWorktreeRowsScrollView.makeScrollView(snapshot: snapshot)
        scrollView.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        scrollView.layoutSubtreeIfNeeded()
        let documentView = try #require(scrollView.documentView as? GitWorktreeRowsNSView)
        documentView.updateLayout(width: scrollView.contentView.bounds.width)

        #expect(scrollView.documentView === documentView)
        #expect(scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(documentView.frame.height == CGFloat(rows.count) * GitWorktreeRowsView.rowHeight)
        #expect(documentView.frame.width == scrollView.contentView.bounds.width)
    }
}

@MainActor
private func sampleFrame(
    view: GitGraphFrameSamplingView,
    context: NSGraphicsContext,
    clock: ContinuousClock
) -> Double {
    let start = clock.now
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    for _ in 0..<20 {
        view.draw(view.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    return milliseconds(clock.now - start) / 20
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
}

private final class GitGraphFrameSamplingView: NSView {
    private let rows: [GitGraphRow]
    private let rowHeight: CGFloat

    init(rows: [GitGraphRow], rowHeight: CGFloat) {
        self.rows = rows
        self.rowHeight = rowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: CGFloat(rows.count) * rowHeight))
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow = min(rows.count - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }
        for index in firstRow...lastRow {
            let row = rows[index]
            let centerY = CGFloat(index) * rowHeight + rowHeight / 2
            let x = 8 + CGFloat(row.lane) * 13
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fillEllipse(in: CGRect(x: x - 4, y: centerY - 4, width: 8, height: 8))
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1.6)
            for edge in row.parentEdges {
                guard let targetLane = edge.targetLane else { continue }
                let targetX = 8 + CGFloat(targetLane) * 13
                context.move(to: CGPoint(x: x, y: centerY))
                context.addLine(to: CGPoint(x: targetX, y: centerY + rowHeight / 2))
                context.strokePath()
            }
        }
    }
}
