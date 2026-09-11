import AppKit
import Foundation
import LitheGitModule
import SwiftUI
@testable import Lithe
import Testing

@Suite("Git graph arrow interaction", .serialized)
@MainActor
struct GitGraphInteractionTests {
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
            let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: GitGraphGeometry.rowHeight)
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
                let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: GitGraphGeometry.rowHeight)
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
                           onReset: { _ in }, onCreateTag: { _ in })
    }
}

@MainActor
private final class GraphCaptureBackground: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
}
