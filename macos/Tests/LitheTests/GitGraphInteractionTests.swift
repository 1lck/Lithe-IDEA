import AppKit
import CoreText
import Foundation
@testable import LitheGitModule
import SwiftUI
@testable import Lithe
import Testing

@Suite("Git graph arrow interaction", .serialized)
@MainActor
struct GitGraphInteractionTests {
    @Test("Compact reference groups keep full names and IDEA tracking and shortening rules")
    func referenceGroups() throws {
        let local = GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local,
                                 isCurrent: true, upstreamShortName: "upstream/release")
        func group(_ decorations: String) throws -> GitGraphReferenceGroup {
            let commit = GitCommit(hash: "tip", shortHash: "tip", parentHashes: [], authorName: "Test",
                authorEmail: "", date: "", subject: "Subject", decorations: decorations)
            let row = try #require(GitGraphLayoutService.layout(commits: [commit]).rows.first)
            return GitGraphReferenceGroup(labels: row.labels, references: [local])
        }
        let tracked = try group("HEAD -> main, refs/remotes/upstream/release, tag: v1")
        #expect(tracked.title == "upstream & main")
        #expect(tracked.iconKinds == [.head, .branch, .remote, .tag])
        #expect(tracked.tooltip == "HEAD\nmain\nupstream/release\nv1")
        #expect(try group("main, origin/main").title == "origin & main")
        #expect(try group("tag: v1, tag: v2, tag: v3").iconKinds == [.tag, .tag])
        #expect(try group("tag: v1").title.isEmpty)
        #expect(try group("HEAD").title == "HEAD")
        let long = try group("refs/remotes/origin/codex/frontend-preview-with-long-name")
        let font = LitheTheme.uiNSFont(size: 12)
        #expect(long.shortenedTitle(availableWidth: 1000, font: font) == long.title)
        let short = long.shortenedTitle(availableWidth: 60, font: font)
        #expect(short.hasPrefix("../codex/"))
        #expect(short.hasSuffix("…"))
        #expect(short.count == 22)
        #expect(long.tooltip == "origin/codex/frontend-preview-with-long-name")
    }

    @Test("Native reference hover survives truncation and branch background yields to selection", arguments: [false, true])
    func referenceHoverAndCurrentBranchColor(_ dark: Bool) throws {
        let commit = GitCommit(hash: "tip", shortHash: "tip", parentHashes: [], authorName: "Test", authorEmail: "",
            date: "2026/09/09", subject: "A commit with a long branch reference",
            decorations: "HEAD -> main, origin/main, refs/remotes/origin/codex/frontend-preview-with-long-name")
        let rows = GitGraphLayoutService.layout(commits: [commit]).rows
        let frame = CGRect(x: 0, y: 0, width: 780, height: GitGraphGeometry.rowHeight)
        let view = GitGraphCommitRowsNSView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.update(rows: rows, selectedHash: nil, showDecorations: true, graphWidth: 100,
                    rowHeight: frame.height, actions: actions { _ in })
        view.updateCurrentBranchHashes([commit.hash])
        for width: CGFloat in [780, 500] {
            view.setFrameSize(CGSize(width: width, height: frame.height))
            let end = width - LitheTheme.GitLog.dateColumnWidth(locale: .current) - 120
            #expect(view.referenceTooltip(at: CGPoint(x: end - 2, y: 12))?.contains("origin/codex/frontend-preview-with-long-name") == true)
            #expect(view.referenceTooltip(at: CGPoint(x: 10, y: 12)) == nil)
        }
        func background() throws -> NSColor {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Compare encoded RGB samples; colorAt() converts this display-profile
            // bitmap through the monitor profile a second time on this host.
            var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&samples, atX: 2, y: 2)
            let maximum = CGFloat((1 << bitmap.bitsPerSample) - 1)
            return NSColor(deviceRed: CGFloat(samples[0]) / maximum, green: CGFloat(samples[1]) / maximum,
                           blue: CGFloat(samples[2]) / maximum, alpha: 1)
        }
        let branch = try background()
        let expected = GitGraphColor.currentBranchBackground(isDark: dark)
        #expect(abs(branch.redComponent - expected.redComponent) < 0.01)
        #expect(abs(branch.blueComponent - expected.blueComponent) < 0.01)
        view.updateSelection([commit.hash], isFocused: true)
        let selected = try background()
        #expect(abs(selected.redComponent - branch.redComponent) + abs(selected.greenComponent - branch.greenComponent) > 0.05)
    }

    @Test("Real history matches IDEA for page, repository context and Normal date order", arguments: ["page", "context", "date"])
    func reportedHistoryParity(_ fixture: String) throws {
        let layout = GitGraphLayoutService.layout(commits: try reportedCommits(fixture == "date" ? "issue410-date-history" : "issue410-history"),
            repositoryCommits: fixture == "page" ? [] : try reportedCommits(fixture == "date" ? "issue410-date-context" : "issue410-context"))
        var actual = ["Width|\(layout.recommendedLaneCount)"]
        for (index, row) in layout.rows.enumerated() {
            actual.append("Node|\(index):\(row.lane):\(row.layoutIndex):\(row.nodeColorIndex)")
            for edge in row.printElements {
                let direction = edge.direction == .up ? "UP" : "DOWN"
                let style = edge.isDotted ? "DASHED" : "SOLID"
                actual.append("Edge|\(index):\(edge.position):\(edge.adjacentPosition):\(direction):\(edge.hasArrow):\(edge.isTerminal):\(style):\(edge.colorIndex)")
            }
        }
        let expected = try graphFixture(fixture == "date" ? "issue410-date-idea" : fixture == "context" ? "issue410-context-idea" : "issue410-idea", extension: "txt")
            .split(separator: "\n").map(String.init)
        // Compare the complete multiset, but report only differences on failure.
        let difference = actual.sorted().difference(from: expected)
        #expect(difference.isEmpty, "IDEA print differences: \(difference)")
    }

    @Test("Generated colors match IDEA RGB samples including signed integer overflow")
    func ideaColors() throws {
        for line in try graphFixture("idea-theme-colors", extension: "txt").split(separator: "\n") {
            let columns = line.split(separator: "|")
            let isDark = columns[0] == "dark"
            let id = try #require(Int(columns[1]))
            let expected = columns[2].split(separator: ":").compactMap { Int($0) }
            let color = try #require(GitGraphColor.color(for: id, isDark: isDark).usingColorSpace(.deviceRGB))
            let actual = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
            #expect(actual == expected, "IDEA color ID \(id)")
        }
    }

    @Test("Real merge clusters render in date and legacy order in both appearances", arguments: [false, true])
    func reportedHistoryRendering(_ dateOrder: Bool) throws {
        let layout = GitGraphLayoutService.layout(commits: try reportedCommits(dateOrder ? "issue410-date-history" : "issue410-history"),
            repositoryCommits: try reportedCommits(dateOrder ? "issue410-date-context" : "issue410-context"))
        #expect(layout.rows.count == (dateOrder ? 300 : 200))
        let selectedIndex = try #require(layout.rows.firstIndex { $0.commit.hash.hasPrefix("ba3725bb") })
        var regions = [("reported-\(dateOrder ? "date" : "topo")", selectedIndex - 6, 16, CGFloat(1_050))]
        if dateOrder {
            // The user's IDEA crop starts four rows above the "update" commit.
            let reference = try #require(layout.rows.firstIndex { $0.commit.hash.hasPrefix("de4208d5") })
            regions.append(("idea-reference", reference - 4, 11, 660))
        }
        for dark in [false, true] {
            for (name, first, count, width) in regions {
                // Keep the complete history for layout parity, then render only
                // the captured viewport and one adjacent row at each boundary.
                // Reuse its resolved lanes, colors and edges without relayout:
                // an unbounded hosting view eagerly creates hundreds of rows
                // that contribute no pixels to these regression captures.
                try #require(first > 0 && first + count < layout.rows.count)
                let lowerBound = first - 1
                let viewport = GitGraphLayout(rows: Array(layout.rows[lowerBound..<(first + count + 1)]),
                    laneCount: layout.laneCount, hasMissingParents: false,
                    recommendedLaneCount: layout.recommendedLaneCount)
                let frame = NSRect(x: 0, y: 0, width: 1_050,
                    height: CGFloat(viewport.rows.count) * GitGraphGeometry.rowHeight)
                let surface = GraphCaptureBackground(frame: frame)
                surface.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let hosting = NSHostingView(rootView: GitGraphView(presentation: presentation(viewport),
                    selectedHash: layout.rows[selectedIndex].commit.hash, showCommitDecorations: true,
                    actions: actions { _ in }).environment(\.colorScheme, dark ? .dark : .light))
                hosting.frame = frame
                surface.addSubview(hosting)
                let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = surface
                defer { window.orderOut(nil); window.close() }
                surface.layoutSubtreeIfNeeded()
                let region = NSRect(x: 0, y: CGFloat(first - lowerBound) * GitGraphGeometry.rowHeight, width: width,
                                    height: CGFloat(count) * GitGraphGeometry.rowHeight)
                let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: region))
                surface.cacheDisplay(in: region, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(data.count > 1_000)
                if let directory = ProcessInfo.processInfo.environment["LITHE_GIT_GRAPH_CAPTURE_DIR"] {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: root.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test("Commit time follows app language, including midnight and noon")
    func localizedCommitDates() {
        for (raw, english, chinese) in [
            ("2026/09/03 00:02", "2026/09/03 12:02 AM", "2026/09/03 00:02"),
            ("2026/09/03 11:11", "2026/09/03 11:11 AM", "2026/09/03 11:11"),
            ("2026/09/03 12:02", "2026/09/03 12:02 PM", "2026/09/03 12:02"),
            ("2026/09/03 17:55", "2026/09/03 05:55 PM", "2026/09/03 17:55")
        ] {
            #expect(GitLogDatePresentation.string(raw, locale: Locale(identifier: "en")) == english)
            #expect(GitLogDatePresentation.string(raw, locale: Locale(identifier: "zh-Hans")) == chinese)
        }
        #expect(GitLogDatePresentation.string("unknown date", locale: Locale(identifier: "en")) == "unknown date")
    }

    @Test("Inter timestamp digits and native locale changes keep columns aligned")
    func timestampColumnAlignment() throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts/Inter-Regular.otf")
        let registered = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        defer { if registered { CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, nil) } }
        let font = LitheTheme.GitLog.dateFont
        #expect(font.fontName == "Inter-Regular")
        let digitWidths = (0...9).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
        let reference = try #require(digitWidths.first)
        #expect(digitWidths.allSatisfy { abs($0 - reference) < 0.001 })
        let dates = ["2026/09/03 11:11", "2026/09/03 17:55", "2026/09/03 00:02"]
        let commits = dates.enumerated().map { index, date in
            GitCommit(hash: String(index), shortHash: String(index), parentHashes: [],
                      authorName: "", authorEmail: "", date: date, subject: "", decorations: "")
        }
        let rows = GitGraphLayoutService.layout(commits: commits).rows
        let frame = NSRect(x: 0, y: 0, width: 850, height: CGFloat(rows.count) * GitGraphGeometry.rowHeight)
        let view = GitGraphCommitRowsNSView(frame: frame)
        view.update(rows: rows, selectedHash: nil, showDecorations: false, graphWidth: 100,
                    rowHeight: GitGraphGeometry.rowHeight, actions: actions { _ in })
        let layout = GitGraphLayoutService.layout(commits: commits)
        let hosting = NSHostingView(rootView: GitGraphView(presentation: presentation(layout), selectedHash: nil,
            showCommitDecorations: false, actions: actions { _ in }).environment(\.locale, Locale(identifier: "en")))
        hosting.frame = frame
        var images: [Data] = []
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
            // Same rows, new locale: the native date cache and drawing must refresh.
            view.updateActions(actions { _ in }, locale: locale)
            hosting.rootView = GitGraphView(presentation: presentation(layout), selectedHash: nil,
                showCommitDecorations: false, actions: actions { _ in }).environment(\.locale, locale)
            hosting.layoutSubtreeIfNeeded()
            for surface: NSView in [view, hosting] {
                let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: frame))
                surface.cacheDisplay(in: frame, to: bitmap)
                images.append(try #require(bitmap.representation(using: .png, properties: [:])))
                let scale = CGFloat(bitmap.pixelsWide) / frame.width
                let left = Int((frame.width - LitheTheme.GitLog.dateColumnWidth(locale: locale) - 8) * scale)
                var starts: [Int] = []
                for index in rows.indices {
                    var start = bitmap.pixelsWide
                    for y in Int(CGFloat(index) * GitGraphGeometry.rowHeight * scale)..<Int(CGFloat(index + 1) * GitGraphGeometry.rowHeight * scale) {
                        for x in left..<bitmap.pixelsWide where try #require(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.5 {
                            start = min(start, x)
                        }
                    }
                    starts.append(start)
                }
                #expect(starts.allSatisfy { $0 == starts[0] && $0 < bitmap.pixelsWide }, "Timestamp column starts: \(starts)")
            }
        }
        #expect(images[0] != images[2], "Switching app language must repaint unchanged native rows")
        #expect(images[1] != images[3], "SwiftUI must use the selected app language")
    }

    @Test("IDEA device-pixel geometry reaches the native raster", arguments: [CGFloat(1), CGFloat(2)])
    func pixelAlignedGraph(_ scale: CGFloat) throws {
        let paint = GitGraphGeometry.PaintMetrics(rowHeight: 26, backingScale: scale)
        // Golden dimensions from SimpleGraphCellPainter's FLOOR / ODD rules.
        #expect(paint.lineWidth == (scale == 1 ? 1 : 1.5))
        #expect(paint.nodeDiameter == (scale == 1 ? 9 : 8.5))
        #expect(paint.laneSpacing == (scale == 1 ? 17 : 18.5))
        #expect(paint.rowCenter == (scale == 1 ? 13 : 12.5))
        let edge = GitGraphPrintElement(edgeID: "pixel-fixture", position: 0, adjacentPosition: 0,
            direction: .up, colorIndex: 1, isDotted: false, hasArrow: false, isTerminal: false, targetHash: nil)
        let row = GitGraphRoutingRow(rowIndex: 0, nodeLane: 0, incoming: [], routes: [],
            nodeColorIndex: 1, isMerge: false, printElements: [edge])
        let view = GitGraphNSView(frame: NSRect(x: 0, y: 0, width: 64, height: 26))
        view.update(snapshot: GitGraphRoutingSnapshot(rows: [row], laneCount: 1), width: 64, rowHeight: 26)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(64 * scale),
            pixelsHigh: Int(26 * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(.infinite)
        var widths: [Int] = []
        var coverage: [CGFloat] = []
        for y in 0..<bitmap.pixelsHigh {
            var width = 0
            var alpha: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                let opacity = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
                if opacity > 0.5 { width += 1 }
                alpha += opacity
            }
            if width > 0 { widths.append(width) }
            if alpha > 0 { coverage.append(alpha) }
        }
        #expect(widths.max() == (scale == 1 ? 9 : 17), "Native circle pixel widths: \(widths)")
        // Fractional edge coverage counts toward the stroke; opaque-pixel counts
        // would incorrectly reject a 1px stroke split over two half-covered pixels.
        #expect(coverage.suffix(5).allSatisfy { abs($0 - (scale == 1 ? 1 : 3)) < 0.05 },
                "Native stroke alpha coverage: \(coverage)")
        if let directory = ProcessInfo.processInfo.environment["LITHE_GIT_GRAPH_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("graph-pixel-alignment-\(Int(scale))x.png"))
        }
    }

    @Test("Aligned diagonal arrow arms retain upstream size and clickable tips", arguments: [CGFloat(1), CGFloat(2)])
    func alignedArrowGeometry(_ scale: CGFloat) throws {
        let paint = GitGraphGeometry.PaintMetrics(rowHeight: 26, backingScale: scale)
        for direction in [GitGraphPrintElement.Direction.up, .down] {
            let edge = GitGraphPrintElement(edgeID: "diagonal", position: 2, adjacentPosition: 6,
                direction: direction, colorIndex: 1, isDotted: false, hasArrow: true, isTerminal: false, targetHash: "target")
            let tip = paint.line(for: edge).end
            let expectedX: CGFloat = 9 + 4 * (scale == 1 ? 17 : 18.5)
            #expect(tip.x == expectedX)
            #expect(tip.y == (direction == .up ? (scale == 1 ? 0 : -0.5) : (scale == 1 ? 26 : 25.5)))
            #expect(paint.arrowHitRect(for: edge).contains(tip))
            let arms = paint.arrowArms(for: edge)
            for arm in arms { #expect(abs(hypot(arm.x - tip.x, arm.y - tip.y) - 7.8) < 0.0001) }
            let a = CGPoint(x: arms[0].x - tip.x, y: arms[0].y - tip.y)
            let b = CGPoint(x: arms[1].x - tip.x, y: arms[1].y - tip.y)
            let cosine = (a.x * b.x + a.y * b.y) / CGFloat(7.8 * 7.8)
            #expect(abs(cosine - 0.4) < 0.0001)
        }
    }

    @Test("Both arrow hit regions navigate to their real visible endpoint")
    func arrowHitRegions() throws {
        let layout = GitGraphLayoutService.layout(commits: commits())
        let view = GitGraphNSView()
        view.update(snapshot: GitGraphLayoutService.routingSnapshot(for: layout), width: 60, rowHeight: GitGraphGeometry.rowHeight)
        var targets = Set<String>()
        for (index, row) in layout.rows.enumerated() {
            for edge in row.printElements where edge.hasArrow {
                let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: GitGraphGeometry.rowHeight)
                let point = CGPoint(x: rect.midX, y: CGFloat(index) * GitGraphGeometry.rowHeight + rect.midY)
                #expect(view.navigationTarget(at: point) == edge.targetHash)
                targets.insert(try #require(view.navigationTarget(at: point)))
            }
        }
        #expect(targets == ["0", "40"])
        #expect(view.navigationTarget(at: CGPoint(x: 500, y: 50)) == nil)
        #expect(view.navigationTarget(at: CGPoint(x: 8, y: -1)) == nil)
    }

    @Test("Expanded multi-lane arrow tips hit their drawn destinations")
    func diagonalArrowTips() throws {
        let layout = expandedMergeFixture()
        let view = GitGraphNSView()
        view.update(snapshot: GitGraphLayoutService.routingSnapshot(for: layout), width: 600, rowHeight: GitGraphGeometry.rowHeight)
        var directions = Set<GitGraphPrintElement.Direction>()
        for (index, row) in layout.rows.enumerated() {
            for edge in row.printElements where edge.hasArrow && abs(edge.position - edge.adjacentPosition) >= 2 {
                #expect(!edge.isTerminal)
                let tip = GitGraphGeometry.line(for: edge, rowHeight: GitGraphGeometry.rowHeight).end
                let point = CGPoint(x: tip.x, y: CGFloat(index) * GitGraphGeometry.rowHeight + tip.y)
                #expect(view.navigationTarget(at: point) == edge.targetHash)
                // Also cover the visible stroke just inside the tip, independent
                // of the hit rectangle's own center or edge-inclusion rules.
                let inside = CGPoint(x: point.x, y: point.y + (edge.direction == .up ? 0.5 : -0.5))
                #expect(view.navigationTarget(at: inside) == edge.targetHash)
                directions.insert(edge.direction)
            }
        }
        #expect(directions == [.up, .down])
    }

    @Test("SwiftUI diagonal arrows receive clicks on the tip and its inner stroke", arguments: [CGFloat(0), CGFloat(0.5)])
    func swiftUIDiagonalArrowTips(_ inset: CGFloat) async throws {
        let layout = expandedMergeFixture()
        var targets: [String] = []
        var selections: [String] = []
        var expected: [String] = []
        for direction in [GitGraphPrintElement.Direction.down, .up] {
            let pair = try #require(layout.rows.enumerated().first { row in
                row.element.printElements.contains { $0.hasArrow && $0.direction == direction && abs($0.position - $0.adjacentPosition) >= 2 }
            })
            let edge = try #require(pair.element.printElements.first { $0.hasArrow && $0.direction == direction && abs($0.position - $0.adjacentPosition) >= 2 })
            expected.append(try #require(edge.targetHash))
            let first = max(0, pair.offset - 1)
            let viewport = GitGraphLayout(rows: Array(layout.rows[first...min(layout.rows.count - 1, pair.offset + 1)]),
                laneCount: layout.laneCount, hasMissingParents: false, recommendedLaneCount: layout.recommendedLaneCount)
            var callbacks = actions { selections.append($0.hash) }
            callbacks.onNavigateHash = { targets.append($0) }
            let hosting = NSHostingView(rootView: GitGraphView(presentation: presentation(viewport), selectedHash: nil,
                showCommitDecorations: true, actions: callbacks))
            let frame = NSRect(x: 0, y: 0, width: 850, height: CGFloat(viewport.rows.count) * GitGraphGeometry.rowHeight)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.orderOut(nil); window.close() }
            window.makeKeyAndOrderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            let tip = GitGraphGeometry.line(for: edge, rowHeight: GitGraphGeometry.rowHeight, backingScale: window.backingScaleFactor).end
            let point = CGPoint(x: tip.x, y: CGFloat(pair.offset - first) * GitGraphGeometry.rowHeight + tip.y + (direction == .up ? inset : -inset))
            let location = hosting.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            // Native gesture callbacks arrive asynchronously; observe their
            // public outcome with a bounded deadline before closing the window.
            while targets.count < expected.count && clock.now < deadline { await Task.yield() }
            #expect(targets == expected, "Clicking the drawn diagonal tip must activate its endpoint")
            #expect(selections.isEmpty, "An arrow click must not also select the adjacent row")
        }
    }

    private func expandedMergeFixture() -> GitGraphLayout {
        // Five parents fan out immediately after a long edge's source, then
        // converge just before its destination. The arrow half-edges therefore
        // cross several compacted lanes in both directions.
        let history = commits().enumerated().map { row, value in
            let parents: [String]
            if row == 1 { parents = (2...6).map(String.init) }
            else if (2...6).contains(row) { parents = ["39"] }
            else if row == 39 { parents = [] }
            else { parents = value.parentHashes }
            return GitCommit(hash: value.hash, shortHash: value.shortHash, parentHashes: parents,
                authorName: value.authorName, authorEmail: value.authorEmail, date: value.date,
                subject: value.subject, decorations: value.decorations)
        }
        return GitGraphLayoutService.layout(commits: history, options: .expanded)
    }

    @Test("Native arrow routing leaves ordinary SwiftUI row clicks selectable")
    func swiftUIArrowRoutingPreservesRowSelection() async throws {
        let layout = expandedMergeFixture()
        var selections: [String] = []
        var targets: [String] = []
        var callbacks = actions { selections.append($0.hash) }
        callbacks.onNavigateHash = { targets.append($0) }
        let viewport = GitGraphLayout(rows: Array(layout.rows.prefix(3)), laneCount: layout.laneCount,
            hasMissingParents: false, recommendedLaneCount: layout.recommendedLaneCount)
        let hosting = NSHostingView(rootView: GitGraphView(presentation: presentation(viewport), selectedHash: nil,
            showCommitDecorations: true, actions: callbacks))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 3 * GitGraphGeometry.rowHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        // One click on a node in the drawing surface, one on row text.
        for point in [CGPoint(x: 8, y: 11), CGPoint(x: 200, y: 33)] {
            let location = hosting.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while selections.count < 2 && clock.now < deadline { await Task.yield() }
        #expect(selections == ["0", "1"], "The arrow surface must pass ordinary row clicks through")
        #expect(targets.isEmpty)
    }

    @Test("Arrow activation selects and scrolls to parent, then back to child")
    func bidirectionalNavigation() throws {
        let layout = GitGraphLayoutService.layout(commits: commits())
        var selection: String?
        let scroll = GitGraphScrollView.makeScrollView(
            presentation: presentation(layout), selectedHash: nil, showCommitDecorations: true,
            canLoadMore: false, isLoadingMore: false,
            actions: actions { selection = $0.hash }, onLoadMore: {}
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.orderOut(nil); window.close() }
        let document = try #require(scroll.documentView as? GitGraphScrollDocumentView)
        document.updateLayout(width: 800, viewportHeight: 180)
        for direction in [GitGraphPrintElement.Direction.down, .up] {
            let pair = try #require(layout.rows.enumerated().first { $0.element.printElements.contains { $0.hasArrow && $0.direction == direction } })
            let edge = try #require(pair.element.printElements.first { $0.hasArrow && $0.direction == direction })
            let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: GitGraphGeometry.rowHeight, backingScale: window.backingScaleFactor)
            let point = document.convert(CGPoint(x: rect.midX, y: CGFloat(pair.offset) * GitGraphGeometry.rowHeight + rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            document.mouseDown(with: event)
            #expect(selection == edge.targetHash)
            let target = try #require(layout.rows.firstIndex { $0.commit.hash == edge.targetHash })
            #expect(scroll.contentView.bounds.intersects(CGRect(x: 0, y: CGFloat(target) * GitGraphGeometry.rowHeight, width: 1, height: GitGraphGeometry.rowHeight)))
        }
    }

    @Test("Production SwiftUI arrow buttons deliver clicks to both destinations")
    func swiftUIArrowButtons() async throws {
        let layout = GitGraphLayoutService.layout(commits: commits())
        var targets: [String] = []
        var callbacks = actions { _ in }
        callbacks.onNavigateHash = { targets.append($0) }
        let hosting = NSHostingView(rootView: GitGraphView(presentation: presentation(layout), selectedHash: nil,
                                                          showCommitDecorations: true, actions: callbacks))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: CGFloat(layout.rows.count) * GitGraphGeometry.rowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        for (index, row) in layout.rows.enumerated() {
            for edge in row.printElements where edge.hasArrow {
                let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: GitGraphGeometry.rowHeight, backingScale: window.backingScaleFactor)
                let point = CGPoint(x: rect.midX, y: CGFloat(index) * GitGraphGeometry.rowHeight + rect.midY)
                let windowPoint = hosting.convert(point, to: nil)
                let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                window.sendEvent(down)
                window.sendEvent(up)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        // SwiftUI delivers native gesture actions asynchronously. Observe the
        // public callback with a local monotonic deadline; no timed sleeps.
        while targets.count < 2 && clock.now < deadline { await Task.yield() }
        #expect(Set(targets) == ["0", "40"])
    }

    @Test("The native renderer draws compact and expanded graphs in both appearances")
    func renderSurfaces() throws {
        for expanded in [false, true] {
            for dark in [false, true] {
                let layout = GitGraphLayoutService.layout(commits: commits(), options: expanded ? .expanded : .compact)
                let document = GitGraphScrollDocumentView()
                document.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                document.update(presentation: presentation(layout), selectedHash: "0", showCommitDecorations: true,
                                canLoadMore: false, isLoadingMore: false, actions: actions { _ in }, onLoadMore: {})
                document.updateLayout(width: 850, viewportHeight: 600)
                let surface = GraphCaptureBackground(frame: document.bounds)
                surface.appearance = document.appearance
                surface.addSubview(document)
                surface.layoutSubtreeIfNeeded()
                let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(data.count > 1_000)
                // Optional verification artifacts; ordinary unit runs do no file I/O.
                if let directory = ProcessInfo.processInfo.environment["LITHE_GIT_GRAPH_CAPTURE_DIR"] {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: root.appendingPathComponent("graph-\(expanded ? "expanded" : "compact")-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test("Text follows local graph width and leaves diagonal boundary clearance")
    func compactTextWidth() {
        let layout = GitGraphLayoutService.layout(commits: commits())
        let narrow = GitGraphGeometry.rowWidth(layout.rows[20], recommendedLaneCount: 0)
        let arrow = GitGraphGeometry.rowWidth(layout.rows[1], recommendedLaneCount: 0)
        #expect(narrow < arrow)
        for row in layout.rows {
            let width = GitGraphGeometry.rowWidth(row, recommendedLaneCount: layout.recommendedLaneCount)
            for edge in row.printElements {
                let line = GitGraphGeometry.line(for: edge, rowHeight: GitGraphGeometry.rowHeight)
                #expect(width > max(line.start.x, line.end.x) + 6)
            }
        }
    }

    @Test("Titles reserve the reference six-column gutter and expand for dense rows")
    func titleGutter() {
        let layout = expandedMergeFixture()
        let minimum = floor(6 * GitGraphGeometry.laneSpacing + GitGraphGeometry.graphTextGap) + 2
        for row in layout.rows {
            let offset = GitGraphGeometry.titleOffset(row, recommendedLaneCount: 0)
            #expect(offset >= minimum)
            #expect(offset >= floor(GitGraphGeometry.rowWidth(row, recommendedLaneCount: 0)) + 2)
        }
        let compact = GitGraphLayoutService.layout(commits: commits()).rows[20]
        #expect(GitGraphGeometry.titleOffset(compact, recommendedLaneCount: 0) == minimum)
    }

    @Test("Merge foreground reaches title, author and date in both renderers", arguments: [false, true])
    func mergeColumnsRenderTogether(selected: Bool) throws {
        let commit = GitCommit(hash: "merge", shortHash: "merge", parentHashes: ["left", "right"],
                               authorName: "MMMMMMMM", authorEmail: "test@example.invalid",
                               date: "MMMMMMMM", subject: "MMMMMMMM", decorations: "")
        let layout = GitGraphLayoutService.layout(commits: [commit])
        let row = try #require(layout.rows.first)
        let frame = NSRect(x: 0, y: 0, width: 850, height: GitGraphGeometry.rowHeight)
        let native = GitGraphCommitRowsNSView(frame: frame)
        native.update(rows: [row], selectedHash: selected ? commit.hash : nil, showDecorations: false,
                      graphWidth: 100, rowHeight: frame.height, actions: actions { _ in })
        let swiftUI = NSHostingView(rootView: GitGraphView(
            presentation: presentation(layout), selectedHash: selected ? commit.hash : nil,
            showCommitDecorations: false, actions: actions { _ in })
            .environment(\.colorScheme, .dark))
        for view: NSView in [native, swiftUI] {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            defer { window.orderOut(nil); window.close() }
            view.frame = frame
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / frame.width
            let dateStart = frame.width - LitheTheme.GitLog.dateColumnWidth(locale: .current) - 8
            let ranges = [
                GitGraphGeometry.titleOffset(row, recommendedLaneCount: 0)..<CGFloat(280),
                (dateStart - 112)..<(dateStart - 8), dateStart..<CGFloat(842)
            ]
            let expected = CGFloat(selected ? 209 : 111) / 255
            for range in ranges {
                var brightestRed: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in Int(range.lowerBound * scale)..<Int(range.upperBound * scale) {
                        let pixel = try #require(bitmap.colorAt(x: x, y: y))
                        let color = try #require(NSColor(colorSpace: bitmap.colorSpace,
                            components: [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
                            count: 4).usingColorSpace(.sRGB))
                        if color.alphaComponent > 0.9 {
                            brightestRed = max(brightestRed, color.redComponent)
                        }
                    }
                }
                #expect(abs(brightestRed - expected) < 0.03, "\(type(of: view)) column \(range)")
            }
        }
    }

    @Test("Continuous native viewport resizing retains document, scroll and multiple selections")
    func continuousViewportResize() throws {
        let layout = GitGraphLayoutService.layout(commits: try reportedCommits("issue410-date-history"))
        let data = presentation(layout)
        var clicked: [(String, NSEvent.ModifierFlags)] = []
        var callbacks = actions { _ in }
        callbacks.onSelectWithModifiers = { clicked.append(($0.hash, $1)) }
        let hashes = Set(layout.rows[8...10].map(\.commit.hash))
        let scroll = GitGraphScrollView.makeScrollView(presentation: data,
            selectedHash: layout.rows[10].commit.hash, showCommitDecorations: true,
            canLoadMore: true, isLoadingMore: false, actions: callbacks, onLoadMore: {}, selectedHashes: hashes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.orderOut(nil); window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let document = try #require(scroll.documentView as? GitGraphScrollDocumentView)
        let subviews = document.subviews.map(ObjectIdentifier.init)
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 7 * GitGraphGeometry.rowHeight))
        let origin = scroll.contentView.bounds.origin
        for step in 0..<80 {
            let height = CGFloat(80 + abs(40 - step) * 8)
            scroll.setFrameSize(CGSize(width: step.isMultiple(of: 2) ? 850 : 780, height: height))
            scroll.needsLayout = true
            scroll.layoutSubtreeIfNeeded()
            #expect(scroll.documentView === document)
            #expect(document.subviews.map(ObjectIdentifier.init) == subviews)
            #expect(document.bounds.width == scroll.contentView.bounds.width)
            #expect(scroll.contentView.bounds.origin == origin)
        }
        let accessible = try #require(document.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement })
        #expect(accessible.count == data.rows.count)
        #expect(accessible[8...10].allSatisfy { $0.isAccessibilitySelected() })
        #expect(!accessible[7].isAccessibilitySelected())
        #expect(accessible[9].accessibilityPerformPress())
        #expect(clicked.last?.0 == data.rows[9].commit.hash)
        let rows = try #require(document.subviews.compactMap { $0 as? GitGraphCommitRowsNSView }.first)
        rows.select(rowIndex: 11, modifiers: [.shift])
        rows.select(rowIndex: 12, modifiers: [.command])
        #expect(clicked.suffix(2).map(\.1) == [[.shift], [.command]])
        for (code, expected) in [(UInt16(125), 11), (UInt16(126), 9)] {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            scroll.keyDown(with: key)
            #expect(clicked.last?.0 == data.rows[expected].commit.hash)
            #expect(clicked.last?.1 == [.shift])
        }
        let id = UUID()
        #expect(document.revealNavigation(hash: data.rows[100].commit.hash, id: id))
        #expect(scroll.contentView.bounds.intersects(CGRect(x: 0, y: 100 * GitGraphGeometry.rowHeight, width: 1, height: 26)))
        #expect(!document.revealNavigation(hash: data.rows[100].commit.hash, id: id))
        #expect(document.revealNavigation(hash: data.rows[100].commit.hash, id: UUID()))
    }

    @Test("Split panes receive exact bounds without minimum/ideal size probes", arguments: Array(0..<8))
    func splitPaneBounds(_ scenario: Int) throws {
        let horizontal = scenario & 1 == 0
        let trailing = scenario & 2 != 0
        let collapsed = scenario & 4 != 0
        let tracked = SplitPaneSizeProbe()
        let flexible = SplitPaneSizeProbe()
        let hosting = NSHostingView(rootView: GeometryReader { geometry in
            LitheSplitPaneView(axis: horizontal ? .horizontal : .vertical,
                placement: trailing ? .trailing : .leading, defaultSize: 120,
                minimum: 30, maximum: 400, flexibleMinimum: 30,
                isSizedPaneCollapsed: collapsed,
                sized: { SplitPaneProbeView(probe: tracked) },
                flexible: { SplitPaneProbeView(probe: flexible) })
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        let trackedView = try #require(tracked.view)
        let flexibleView = try #require(flexible.view)
        tracked.proposals.removeAll()
        flexible.proposals.removeAll()
        for size in [CGSize(width: 540, height: 280), CGSize(width: 480, height: 250)] {
            hosting.setFrameSize(size)
            hosting.layoutSubtreeIfNeeded()
            #expect(tracked.view === trackedView && flexible.view === flexibleView)
            let extent = horizontal ? size.width : size.height
            let actualTracked = horizontal ? trackedView.bounds.width : trackedView.bounds.height
            let actualFlexible = horizontal ? flexibleView.bounds.width : flexibleView.bounds.height
            #expect(actualTracked == (collapsed ? 0 : 120))
            #expect(actualFlexible == extent - (collapsed ? 0 : 125))
        }
        // HStack/VStack probe 0 and infinity to negotiate content sizes; a
        // splitter with known bounds must never send those probes to a pane.
        #expect(!flexible.proposals.isEmpty)
        #expect(flexible.proposals.allSatisfy { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 })
        if !collapsed {
            #expect(tracked.proposals.allSatisfy { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 })
        }
    }

    @Test("The production split handle continuously resizes Git Log with a diff above it")
    func dragGitLogWithDiff() async throws {
        let data = presentation(GitGraphLayoutService.layout(commits: try reportedCommits("issue410-date-history")))
        let diff = (0..<1_200).map { index in
            DiffRow(oldLine: index + 1, newLine: index + 1, left: "let value = \(index)",
                    right: nil, kind: .context, sequence: index)
        }
        let root = LitheSplitPaneView(axis: .vertical, placement: .leading, defaultSize: 280,
            minimum: 30, maximum: 600, flexibleMinimum: 0, clipsSizedPane: true,
            sized: { DiffPaneView(rows: diff, fileExtension: "swift", collapsesUnchangedRegions: false, showsDiffMap: false) },
            flexible: { GitGraphScrollView(presentation: data, selectedHash: nil,
                showCommitDecorations: false, canLoadMore: false, isLoadingMore: false,
                actions: actions { _ in }, onLoadMore: {}) })
        let hosting = NSHostingView(rootView: root)
        // The real workbench assigns its split a viewport. Do not let the
        // test's content view resize the window to the split's intrinsic size.
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(hosting)
        let handle = try #require(views.compactMap { $0 as? SplitHandleInteractionView }.first { $0.axis == .vertical })
        let scroll = try #require(views.compactMap { $0 as? GitGraphScrollNSView }.first)
        let document = try #require(scroll.documentView)
        let originalHeight = scroll.bounds.height
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, offset: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x, y: origin.y + offset),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, offset: 0))
        let clock = ContinuousClock()
        let dragStarted = clock.now
        for offset in [CGFloat(-80), -160, -220, -120, -40, 0] {
            handle.mouseDragged(with: try event(.leftMouseDragged, offset: offset))
            let deadline = clock.now.advanced(by: .seconds(1))
            while abs(scroll.bounds.height - (originalHeight + offset)) > 1 && clock.now < deadline {
                await Task.yield()
                hosting.layoutSubtreeIfNeeded()
            }
            #expect(abs(scroll.bounds.height - (originalHeight + offset)) <= 1)
            #expect(scroll.documentView === document)
        }
        handle.mouseUp(with: try event(.leftMouseUp, offset: 0))
        hosting.layoutSubtreeIfNeeded()
        #expect(abs(scroll.bounds.height - originalHeight) <= 1)
        print("GIT_LOG_RESIZE sample=diff-and-log-native-drag events=6 elapsed=\(dragStarted.duration(to: clock.now))")
    }

    @Test("Long split diffs create visible rows and can still scroll to the last row")
    func splitDiffCreatesViewportRows() async throws {
        let rows = (0..<1_200).map { index in
            DiffRow(oldLine: index + 1, newLine: index + 1, left: "let value = \(index)",
                    right: nil, kind: .context, sequence: index)
        }
        let display = rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: rows.map(\.kind))
        var instantiated: Set<DiffRowID> = []
        var builtRows = 0
        let kinds = rows.map(\.kind)
        let view = GeometryReader { geometry in
            DiffSplitPaneView(displayRows: display, kinds: kinds, layout: layout,
                fileExtension: "swift", contentWidth: 980, viewportWidth: 850,
                onExpand: { _ in }) { row, _ in
                    instantiated.insert(row.id)
                    builtRows += 1
                    return EmptyView()
                }
        }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        #expect(!instantiated.isEmpty && instantiated.count < 200,
                "A 240pt viewport must not lay out 1,200 diff rows: \(instantiated.count)")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try #require(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: layout.contentHeight - 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        let last = try #require(rows.last?.id)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !instantiated.contains(last) && clock.now < deadline {
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
        }
        #expect(instantiated.contains(last), "Offscreen rows must appear when scrolled into view")
        // SwiftUI can measure intermediate rows on the first distant jump.
        // The regression is redoing the whole file on subsequent size changes.
        let beforeResize = builtRows
        for height in [CGFloat(180), 300, 200, 280, 240] {
            hosting.setFrameSize(CGSize(width: 850, height: height))
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        #expect(builtRows - beforeResize < 400,
                "Resizing after a distant scroll must not rebuild the whole file: \(builtRows - beforeResize)")
    }

    @Test("Git Log viewport resize comparison with 300 commits")
    func viewportResizeComparison() throws {
        let layout = GitGraphLayoutService.layout(commits: try reportedCommits("issue410-date-history"))
        let data = presentation(layout)
        let callbacks = actions { _ in }
        let legacy = NSHostingView(rootView: ScrollView {
            GitGraphView(presentation: data, selectedHash: nil, showCommitDecorations: false, actions: callbacks)
        })
        let native = GitGraphScrollView.makeScrollView(presentation: data, selectedHash: nil,
            showCommitDecorations: false, canLoadMore: false, isLoadingMore: false, actions: callbacks, onLoadMore: {})
        for (name, view) in [("swiftui-before", legacy as NSView), ("native-after", native as NSView)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.orderOut(nil); window.close() }
            view.layoutSubtreeIfNeeded()
            let start = ContinuousClock.now
            for step in 0..<30 {
                view.setFrameSize(CGSize(width: 850, height: CGFloat(180 + abs(15 - step) * 14)))
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                let region = view.bounds
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: region))
                view.cacheDisplay(in: region, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            }
            // Diagnostic only: machine-dependent time is not a unit-test gate.
            print("GIT_LOG_RESIZE sample=\(name) frames=30 elapsed=\(start.duration(to: .now))")
        }
    }

    private func commits() -> [GitCommit] {
        (0...40).map { row -> GitCommit in
            let hash = String(row)
            let parents: [String]
            if row == 40 { parents = [] }
            else if row == 0 { parents = ["1", "40"] }
            else { parents = [String(row + 1)] }
            let subject: String
            if row == 0 { subject = "Merge a long-running feature" }
            else if row == 40 { subject = "Shared ancestor" }
            else { subject = "Commit \(row)" }
            return GitCommit(hash: hash, shortHash: hash,
                      parentHashes: parents,
                      authorName: "Graph fixture", authorEmail: "fixture@example.invalid", date: "2026/09/11",
                      subject: subject,
                      decorations: row == 0 ? "HEAD -> main" : "")
        }
    }

    private func reportedCommits(_ name: String = "issue410-history") throws -> [GitCommit] {
        try graphFixture(name, extension: "tsv").split(separator: "\n").map { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            precondition(columns.count == 4)
            return GitCommit(hash: columns[0], shortHash: String(columns[0].prefix(8)),
                             parentHashes: columns[1].split(separator: " ").map(String.init),
                             authorName: "Graph fixture", authorEmail: "fixture@example.invalid", date: "2026/09/11",
                             subject: columns[3], decorations: columns[2].trimmingCharacters(in: CharacterSet(charactersIn: " ()")))
        }
    }

    private func graphFixture(_ name: String, extension suffix: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures/GitGraph"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func presentation(_ layout: GitGraphLayout) -> GitGraphPresentation {
        GitGraphPresentation(rows: layout.rows, routingSnapshot: GitGraphLayoutService.routingSnapshot(for: layout),
                             hasMissingParents: layout.hasMissingParents)
    }

    private func actions(_ select: @escaping (GitCommit) -> Void) -> GitGraphRowActions {
        GitGraphRowActions(onSelect: select, onCherryPick: { _ in }, onRevert: { _ in },
                           onReset: { _, _ in }, onCreateTag: { _ in })
    }
}

@MainActor
final class GraphCaptureBackground: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
}

@MainActor
private final class SplitPaneSizeProbe {
    var view: NSView?
    var proposals: [CGSize] = []
}

private struct SplitPaneProbeView: NSViewRepresentable {
    let probe: SplitPaneSizeProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions()
        probe.proposals.append(size)
        return size
    }
}
