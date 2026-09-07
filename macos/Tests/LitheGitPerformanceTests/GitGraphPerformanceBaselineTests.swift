@testable import Lithe
import LitheGitModule
import LitheGitPerformanceSupport
import AppKit
import QuartzCore
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
        #expect(benchmark.medianMs < 30)
        #expect(benchmark.p95Ms < 60)
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
        for _ in 0..<3 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.draw(viewport)
            NSGraphicsContext.restoreGraphicsState()
        }
        var samples: [Double] = []
        samples.reserveCapacity(21)
        for _ in 0..<21 {
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
        #expect(scrollView.usesPredominantAxisScrolling)
        #expect(scrollView.scrollsDynamically)
        #expect(documentView.frame.height == CGFloat(rows.count) * GitWorktreeRowsView.rowHeight)
        #expect(documentView.frame.width == scrollView.contentView.bounds.width)
    }

    @Test("Worktree rows preserve the viewport while history grows")
    @MainActor
    func worktreeRowsPreserveScrollOrigin() {
        let previous = CGPoint(x: 0, y: 2_400)

        #expect(
            GitWorktreeRowsScrollView.preservedScrollOrigin(
                previous: previous,
                documentHeight: 5_000 * GitWorktreeRowsView.rowHeight,
                viewportHeight: 420
            ) == previous
        )
        #expect(
            GitWorktreeRowsScrollView.preservedScrollOrigin(
                previous: previous,
                documentHeight: 1_000,
                viewportHeight: 420
            ) == CGPoint(x: 0, y: 580)
        )
        #expect(
            GitWorktreeRowsScrollView.preservedScrollOrigin(
                previous: CGPoint(x: 0, y: -10),
                documentHeight: 1_000,
                viewportHeight: 420
            ) == CGPoint.zero
        )
    }

    @Test("The worktree list uses one native scrolling surface")
    @MainActor
    func nativeWorktreeListScrollContainerBaseline() throws {
        let items = (0..<5_000).map { index in
            makeWorktreeListFixtureItem(index: index, isCurrent: index == 0, status: index == 0 ? .current : .available)
        }
        let scrollView = GitWorktreeListScrollView.makeScrollView(
            items: items,
            selectedWorktreeID: items.first?.id,
            onSelect: { _ in }
        )
        scrollView.frame = CGRect(x: 0, y: 0, width: 360, height: 420)
        scrollView.layoutSubtreeIfNeeded()
        let documentView = try #require(scrollView.documentView as? GitWorktreeListNSView)
        documentView.updateLayout(width: scrollView.contentView.bounds.width)

        #expect(scrollView.documentView === documentView)
        #expect(scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.usesPredominantAxisScrolling)
        #expect(scrollView.scrollsDynamically)
        #expect(documentView.frame.height > CGFloat(items.count) * GitWorktreeListScrollView.rowHeight)
        #expect(documentView.frame.width == scrollView.contentView.bounds.width)
    }

    @Test("The native worktree list draws only visible rows")
    @MainActor
    func nativeWorktreeListFrameBaseline() throws {
        let items = (0..<5_000).map { index in
            makeWorktreeListFixtureItem(index: index, isCurrent: false, status: .available)
        }
        let view = GitWorktreeListNSView(frame: CGRect(
            x: 0,
            y: 0,
            width: 360,
            height: CGFloat(items.count) * (GitWorktreeListScrollView.rowHeight + GitWorktreeListScrollView.rowSpacing)
        ))
        view.update(items: items, selectedWorktreeID: items[2_500].id, onSelect: { _ in })
        let viewport = CGRect(x: 0, y: 2_500 * Int(GitWorktreeListScrollView.rowHeight + GitWorktreeListScrollView.rowSpacing), width: 360, height: 420)
        let visibleRange = try #require(GitWorktreeListNSView.visibleRowRange(
            rowCount: items.count,
            rowHeight: GitWorktreeListScrollView.rowHeight,
            rowSpacing: GitWorktreeListScrollView.rowSpacing,
            inset: GitWorktreeListScrollView.verticalInset,
            dirtyRect: viewport
        ))
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 360,
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
        for _ in 0..<3 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.draw(viewport)
            NSGraphicsContext.restoreGraphicsState()
        }
        var samples: [Double] = []
        samples.reserveCapacity(21)
        for _ in 0..<21 {
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
            "Worktree list native rows: total=\(items.count), visible=\(visibleRange.count), samples=\(samples.count), median=\(String(format: "%.3f", median))ms, p95=\(String(format: "%.3f", p95))ms"
        )
        #expect(visibleRange.count <= 7)
        #expect(median < 30)
        #expect(p95 < 100)
    }

    @Test("The Git log commit list uses one native scrolling viewport")
    @MainActor
    func nativeGitLogScrollContainerBaseline() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 5_000)
        let layout = GitGraphLayoutService.layout(commits: commits)
        let presentation = GitGraphPresentation(
            rows: layout.rows,
            routingSnapshot: GitGraphLayoutService.routingSnapshot(for: layout),
            hasMissingParents: layout.hasMissingParents
        )
        let actions = GitGraphRowActions(
            onSelect: { _ in },
            onCherryPick: { _ in },
            onRevert: { _ in },
            onReset: { _ in },
            onCreateTag: { _ in }
        )
        let scrollView = GitGraphScrollView.makeScrollView(
            presentation: presentation,
            selectedHash: presentation.rows.first?.commit.hash,
            showCommitDecorations: true,
            canLoadMore: true,
            isLoadingMore: false,
            actions: actions,
            onLoadMore: {}
        )
        scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 420)
        scrollView.layoutSubtreeIfNeeded()

        #expect(scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.documentView != nil)
        #expect(scrollView.contentView.bounds.height == 420)
    }

    @Test("Loading more commits preserves the current scroll origin")
    @MainActor
    func loadMorePreservesScrollOrigin() {
        let previous = CGPoint(x: 0, y: 2_400)

        #expect(
            GitGraphScrollView.preservedScrollOrigin(
                previous: previous,
                documentHeight: 5_000 * 30,
                viewportHeight: 420
            ) == previous
        )
        #expect(
            GitGraphScrollView.preservedScrollOrigin(
                previous: previous,
                documentHeight: 1_000,
                viewportHeight: 420
            ) == CGPoint(x: 0, y: 580)
        )
        #expect(
            GitGraphScrollView.preservedScrollOrigin(
                previous: CGPoint(x: 0, y: -10),
                documentHeight: 1_000,
                viewportHeight: 420
            ) == CGPoint.zero
        )
    }

    @Test("The native Git log commit rows draw only the visible viewport")
    @MainActor
    func nativeGitLogCommitRowsFrameBaseline() throws {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 5_000)
        let layout = GitGraphLayoutService.layout(commits: commits)
        let rowsView = GitGraphCommitRowsNSView(frame: CGRect(
            x: 0,
            y: 0,
            width: 620,
            height: CGFloat(layout.rows.count) * 30
        ))
        let actions = GitGraphRowActions(
            onSelect: { _ in },
            onCherryPick: { _ in },
            onRevert: { _ in },
            onReset: { _ in },
            onCreateTag: { _ in }
        )
        rowsView.update(
            rows: layout.rows,
            selectedHash: layout.rows[2_500].commit.hash,
            showDecorations: true,
            graphWidth: 96,
            rowHeight: 30,
            actions: actions
        )
        let viewport = CGRect(x: 0, y: 2_500 * 30, width: 620, height: 420)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 620,
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
            rowsView.draw(viewport)
            NSGraphicsContext.restoreGraphicsState()
            samples.append(milliseconds(clock.now - start))
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print(
            "Git log native rows: total=\(layout.rows.count), visible=14, samples=\(samples.count), median=\(String(format: "%.3f", median))ms, p95=\(String(format: "%.3f", p95))ms"
        )
        #expect(median < 30)
        #expect(p95 < 100)
    }

    @Test("The native Git commit file tree draws only the visible viewport")
    @MainActor
    func nativeGitCommitFileTreeFrameBaseline() throws {
        let files = (0..<5_000).map { index in
            GitCommitFile(
                status: index.isMultiple(of: 5) ? "A" : "M",
                path: "Sources/Feature\(index % 40)/Module\((index / 40) % 12)/File\(index).swift"
            )
        }
        let root = GitCommitFileTreeNode.build(from: files, rootName: "Repository")
        var items: [GitCommitFileTreeItem] = []
        appendVisibleFileTreeItems(root, depth: 0, collapsedFolderIDs: [], into: &items)

        let view = GitCommitFileTreeNSView(frame: CGRect(
            x: 0,
            y: 0,
            width: 900,
            height: CGFloat(items.count) * GitCommitFileTreeNSView.rowHeight + 10
        ))
        view.update(
            items: items,
            selectedFileID: files[2_500].id,
            rootSubtitle: nil,
            collapsedFolderIDs: [],
            onToggleFolder: { _ in },
            onSelectFile: { _ in }
        )

        let dirtyRect = CGRect(
            x: 0,
            y: 2_500 * GitCommitFileTreeNSView.rowHeight,
            width: 900,
            height: 420
        )
        let visibleRange = try #require(GitCommitFileTreeNSView.visibleRowRange(
            itemCount: items.count,
            rowHeight: GitCommitFileTreeNSView.rowHeight,
            dirtyRect: dirtyRect
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
        for _ in 0..<2 {
            drawFileTreeFrame(view: view, dirtyRect: dirtyRect, context: context)
        }
        for _ in 0..<10 {
            let start = clock.now
            drawFileTreeFrame(view: view, dirtyRect: dirtyRect, context: context)
            samples.append(milliseconds(clock.now - start))
        }

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print(
            "Git commit file-tree native rows: total=\(items.count), visible=\(visibleRange.count), samples=\(samples.count), median=\(String(format: "%.3f", median))ms, p95=\(String(format: "%.3f", p95))ms"
        )
        #expect(visibleRange.count <= 17)
        #expect(median < 30)
        #expect(p95 < 100)
    }

    @Test(
        "The native Git log keeps a window display-link cadence while scrolling",
        .enabled(
            if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14,
            "Requires macOS 14 or newer for NSWindow display links."
        )
    )
    @available(macOS 14.0, *)
    @MainActor
    func windowCompositorFrameSample() throws {
        guard NSScreen.main != nil else {
            print("Window compositor sample skipped: no active WindowServer display.")
            return
        }

        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 5_000)
        let layout = GitGraphLayoutService.layout(commits: commits)
        let presentation = GitGraphPresentation(
            rows: layout.rows,
            routingSnapshot: GitGraphLayoutService.routingSnapshot(for: layout),
            hasMissingParents: layout.hasMissingParents
        )
        let actions = GitGraphRowActions(
            onSelect: { _ in },
            onCherryPick: { _ in },
            onRevert: { _ in },
            onReset: { _ in },
            onCreateTag: { _ in }
        )
        let scrollView = GitGraphScrollView.makeScrollView(
            presentation: presentation,
            selectedHash: presentation.rows.first?.commit.hash,
            showCommitDecorations: true,
            canLoadMore: true,
            isLoadingMore: false,
            actions: actions,
            onLoadMore: {}
        )
        scrollView.frame = CGRect(x: 0, y: 0, width: 900, height: 520)

        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: CGRect(
                x: screenFrame.midX - 450,
                y: screenFrame.midY - 260,
                width: 900,
                height: 520
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.contentView = scrollView
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.displayIfNeeded()
        guard window.isVisible, window.screen != nil else {
            print("Window compositor sample skipped: test window is not attached to a display.")
            window.orderOut(nil)
            window.close()
            return
        }
        defer {
            window.orderOut(nil)
            window.close()
        }

        let sampler = WindowCompositorFrameSampler(
            window: window,
            scrollView: scrollView,
            targetFrameCount: 45
        )
        sampler.start()

        let firstSampleDeadline = CACurrentMediaTime() + 0.5
        while sampler.sampleCount == 0 && CACurrentMediaTime() < firstSampleDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard sampler.sampleCount > 0 else {
            sampler.stop()
            print("Window compositor sample skipped: WindowServer did not deliver a display-link callback.")
            return
        }

        let deadline = CACurrentMediaTime() + 3.0
        while !sampler.isComplete && CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard sampler.isComplete else {
            throw TestTimeoutError(
                message: "Window display-link produced \(sampler.sampleCount) samples before the 3-second deadline."
            )
        }

        let result = sampler.result()
        print(
            "Window compositor sample: callbacks=\(result.sampleCount), median=\(String(format: "%.3f", result.medianFrameTimeMs))ms, p95=\(String(format: "%.3f", result.p95FrameTimeMs))ms, effectiveFPS=\(String(format: "%.1f", result.effectiveFPS)), droppedOpportunities=\(result.droppedFrameOpportunities)"
        )
        #expect(result.sampleCount == 45)
        #expect(result.medianFrameTimeMs > 0)
        #expect(result.p95FrameTimeMs < 100)
        #expect(result.effectiveFPS > 1)
    }

    @Test(
        "The native Worktree rows keep a window display-link cadence while scrolling",
        .enabled(
            if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14,
            "Requires macOS 14 or newer for NSWindow display links."
        )
    )
    @available(macOS 14.0, *)
    @MainActor
    func worktreeWindowCompositorFrameSample() throws {
        guard NSScreen.main != nil else {
            print("Worktree window compositor sample skipped: no active WindowServer display.")
            return
        }

        let rows = (0..<5_000).map { index in
            GitWorktreeRowsSnapshot.Row.commit(
                subject: "Synthetic worktree commit \(index)",
                author: "Lithe Performance Fixture",
                date: "2026/09/05 00:00"
            )
        }
        let scrollView = GitWorktreeRowsScrollView.makeScrollView(snapshot: GitWorktreeRowsSnapshot(
            identity: .history(inspectionVersion: 1, query: ""),
            rows: rows
        ))
        scrollView.frame = CGRect(x: 0, y: 0, width: 900, height: 520)

        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: CGRect(
                x: screenFrame.midX - 450,
                y: screenFrame.midY - 260,
                width: 900,
                height: 520
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.contentView = scrollView
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.displayIfNeeded()
        guard window.isVisible, window.screen != nil else {
            print("Worktree window compositor sample skipped: test window is not attached to a display.")
            window.orderOut(nil)
            window.close()
            return
        }
        defer {
            window.orderOut(nil)
            window.close()
        }

        let sampler = WindowCompositorFrameSampler(
            window: window,
            scrollView: scrollView,
            targetFrameCount: 45
        )
        sampler.start()

        let firstSampleDeadline = CACurrentMediaTime() + 0.5
        while sampler.sampleCount == 0 && CACurrentMediaTime() < firstSampleDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard sampler.sampleCount > 0 else {
            sampler.stop()
            print("Worktree window compositor sample skipped: WindowServer did not deliver a display-link callback.")
            return
        }

        let deadline = CACurrentMediaTime() + 3.0
        while !sampler.isComplete && CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard sampler.isComplete else {
            throw TestTimeoutError(
                message: "Worktree window display-link produced \(sampler.sampleCount) samples before the 3-second deadline."
            )
        }

        let result = sampler.result()
        print(
            "Worktree window compositor sample: callbacks=\(result.sampleCount), median=\(String(format: "%.3f", result.medianFrameTimeMs))ms, p95=\(String(format: "%.3f", result.p95FrameTimeMs))ms, effectiveFPS=\(String(format: "%.1f", result.effectiveFPS)), droppedOpportunities=\(result.droppedFrameOpportunities)"
        )
        #expect(result.sampleCount == 45)
        #expect(result.medianFrameTimeMs > 0)
        #expect(result.p95FrameTimeMs < 100)
        #expect(result.effectiveFPS > 1)
    }
}

private func makeWorktreeListFixtureItem(
    index: Int,
    isCurrent: Bool,
    status: GitWorktreeStatusKind
) -> GitWorktreeListItem {
    let path = "/tmp/lithe-worktree-\(index)"
    let head = String(format: "%040llx", UInt64(index + 1))
    let branch = "refs/heads/feature-\(index)"
    let worktree = GitWorktree(
        path: path,
        head: head,
        branch: branch,
        isCurrent: isCurrent,
        isPrimary: index == 0,
        isBare: false,
        isDetached: false,
        isLocked: false,
        lockReason: nil,
        isPrunable: false,
        pruneReason: nil
    )
    return GitWorktreeListItem(worktree: worktree, status: status)
}

private struct TestTimeoutError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

@available(macOS 14.0, *)
@MainActor
private final class WindowCompositorFrameSampler: NSObject {
    struct Result {
        let sampleCount: Int
        let medianFrameTimeMs: Double
        let p95FrameTimeMs: Double
        let effectiveFPS: Double
        let droppedFrameOpportunities: Int
    }

    private weak var window: NSWindow?
    private weak var scrollView: NSScrollView?
    private let targetFrameCount: Int
    private var displayLink: CADisplayLink?
    private var timestamps: [CFTimeInterval] = []
    private var expectedDuration: CFTimeInterval?
    private var tickCount = 0
    private(set) var isComplete = false

    var sampleCount: Int { timestamps.count }

    init(window: NSWindow, scrollView: NSScrollView, targetFrameCount: Int) {
        self.window = window
        self.scrollView = scrollView
        self.targetFrameCount = targetFrameCount
        super.init()
    }

    func start() {
        guard let window else { return }
        let link = window.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .default)
    }

    func result() -> Result {
        let intervals = zip(timestamps, timestamps.dropFirst()).map { max(0, $1 - $0) * 1_000 }
        let sorted = intervals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95Index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95 = sorted.isEmpty ? 0 : sorted[p95Index]
        let totalSeconds = intervals.reduce(0, +) / 1_000
        let fps = totalSeconds > 0 ? Double(intervals.count) / totalSeconds : 0
        let duration = expectedDuration ?? 1.0 / 60.0
        let dropped = intervals.reduce(into: 0) { total, interval in
            total += max(0, Int((interval / 1_000 / duration).rounded()) - 1)
        }
        return Result(
            sampleCount: intervals.count,
            medianFrameTimeMs: median,
            p95FrameTimeMs: p95,
            effectiveFPS: fps,
            droppedFrameOpportunities: dropped
        )
    }

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        if timestamps.last != nil {
            timestamps.append(sender.timestamp)
        } else {
            timestamps.append(sender.timestamp)
        }
        expectedDuration = sender.duration > 0 ? sender.duration : expectedDuration
        tickCount += 1

        if let scrollView,
           let documentView = scrollView.documentView {
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let phase = CGFloat(tickCount % 240) / 239
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: maxY * phase))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            window?.displayIfNeeded()
        }

        if timestamps.count >= targetFrameCount + 1 {
            isComplete = true
            stop()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

@MainActor
private func drawFileTreeFrame(
    view: GitCommitFileTreeNSView,
    dirtyRect: CGRect,
    context: NSGraphicsContext
) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    view.draw(dirtyRect)
    NSGraphicsContext.restoreGraphicsState()
}

private func appendVisibleFileTreeItems(
    _ node: GitCommitFileTreeNode,
    depth: Int,
    collapsedFolderIDs: Set<String>,
    into items: inout [GitCommitFileTreeItem]
) {
    items.append(.folder(node, depth: depth))
    guard !collapsedFolderIDs.contains(node.id) else { return }
    for directory in node.directories {
        appendVisibleFileTreeItems(
            directory,
            depth: depth + 1,
            collapsedFolderIDs: collapsedFolderIDs,
            into: &items
        )
    }
    for file in node.files {
        items.append(.file(file, depth: depth + 1))
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
