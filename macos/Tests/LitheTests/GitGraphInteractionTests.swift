import AppKit
import Foundation
import LitheGitModule
import SwiftUI
@testable import Lithe
import Testing

@Suite("Git graph arrow interaction", .serialized)
@MainActor
struct GitGraphInteractionTests {
    @Test("Both arrow hit regions navigate to their real visible endpoint")
    func arrowHitRegions() throws {
        let layout = GitGraphLayoutService.layout(commits: commits())
        let view = GitGraphNSView()
        view.update(snapshot: GitGraphLayoutService.routingSnapshot(for: layout), width: 60, rowHeight: 30)
        var targets = Set<String>()
        for (index, row) in layout.rows.enumerated() {
            for edge in row.printElements where edge.hasArrow {
                let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: 30)
                let point = CGPoint(x: rect.midX, y: CGFloat(index) * 30 + rect.midY)
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
            let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: 30)
            let point = document.convert(CGPoint(x: rect.midX, y: CGFloat(pair.offset) * 30 + rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            document.mouseDown(with: event)
            #expect(selection == edge.targetHash)
            let target = try #require(layout.rows.firstIndex { $0.commit.hash == edge.targetHash })
            #expect(scroll.contentView.bounds.intersects(CGRect(x: 0, y: CGFloat(target) * 30, width: 1, height: 30)))
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 1_230),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        for (index, row) in layout.rows.enumerated() {
            for edge in row.printElements where edge.hasArrow {
                let rect = GitGraphGeometry.arrowHitRect(for: edge, rowHeight: 30)
                let point = CGPoint(x: rect.midX, y: CGFloat(index) * 30 + rect.midY)
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
                let line = GitGraphGeometry.line(for: edge, rowHeight: 30)
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
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
}
