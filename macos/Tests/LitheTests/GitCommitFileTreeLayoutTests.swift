import AppKit
import Testing

@testable import Lithe
@testable import LitheGitModule

@Suite("Commit file tree layout", .serialized)
@MainActor
struct GitCommitFileTreeLayoutTests {
    @Test
    func longRowsKeepTheirFullWidthAcrossViewportResizes() throws {
        let file = GitCommitFile(
            status: "M", path: "Sources/" + String(repeating: "LongName", count: 12) + ".swift")
        let scroll = try makeScroll(items: [.file(file, depth: 8)], width: 240)
        let document = try #require(scroll.documentView as? GitCommitFileTreeNSView)
        let fullWidth = document.frame.width
        #expect(scroll.hasHorizontalScroller)
        #expect(fullWidth > scroll.contentView.bounds.width)

        for width: CGFloat in [0, 180, 420, 240] {
            scroll.frame.size.width = width
            scroll.tile()
            scroll.updateDocumentLayout()
            #expect(document.frame.width == fullWidth)
            #expect(document.frame.height > 0)
        }

        scroll.frame.size.width = fullWidth + 100
        scroll.tile()
        scroll.updateDocumentLayout()
        #expect(document.frame.width == scroll.contentView.bounds.width)
    }

    @Test
    func replacingRowsAtTheSameViewportSizeUpdatesBothScrollExtents() throws {
        let file = GitCommitFile(status: "M", path: String(repeating: "LongName", count: 12) + ".swift")
        let rows = (0..<40).map { GitCommitFileTreeItem.file(file, depth: $0) }
        let scroll = try makeScroll(items: rows, width: 240)
        let document = try #require(scroll.documentView as? GitCommitFileTreeNSView)
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 600))
        #expect(scroll.contentView.bounds.minX > 0)
        #expect(scroll.contentView.bounds.minY > 0)

        document.update(
            items: [], selectedFileID: nil, rootSubtitle: nil, collapsedFolderIDs: [],
            onToggleFolder: { _ in }, onSelectFile: { _ in })
        scroll.updateDocumentLayout()
        #expect(document.frame.width == scroll.contentView.bounds.width)
        #expect(document.frame.height < scroll.contentView.bounds.height)
        #expect(scroll.contentView.bounds.origin == .zero)
    }

    @Test
    func clippedFolderAnnotationsExpandOnHoverAndFitAfterWidening() throws {
        let root = GitCommitFileTreeNode.build(
            from: [GitCommitFile(status: "M", path: "File.swift")], rootName: "Repository")
        let scroll = try makeScroll(
            items: [.folder(root, depth: 0)], width: 180,
            subtitle: String(repeating: "ParentDirectory/", count: 8) + "Repository")
        let document = try #require(scroll.documentView as? GitCommitFileTreeNSView)
        try hover(document, at: CGPoint(x: 60, y: 15))
        #expect(document.allowsExpansionToolTips)
        let expansion = document.expansionFrame(withFrame: document.bounds)
        #expect(!expansion.isEmpty)
        #expect(expansion.maxX > document.visibleRect.maxX)
        #expect(expansion.minY >= 0)
        #expect(expansion.height <= GitCommitFileTreeNSView.rowHeight)

        scroll.frame.size.width = document.frame.width + 100
        scroll.tile()
        scroll.updateDocumentLayout()
        #expect(document.expansionFrame(withFrame: document.bounds).isEmpty)
    }

    @Test
    func fileHoverExpansionFollowsTheHoveredRowAndClearsOnExit() throws {
        let longFile = GitCommitFile(status: "M", path: String(repeating: "LongName", count: 12) + ".swift")
        let shortFile = GitCommitFile(status: "A", path: "File.swift")
        let scroll = try makeScroll(
            items: [.file(longFile, depth: 1), .file(shortFile, depth: 1)], width: 240)
        let document = try #require(scroll.documentView as? GitCommitFileTreeNSView)
        try hover(document, at: CGPoint(x: 70, y: 15))
        #expect(!document.expansionFrame(withFrame: document.bounds).isEmpty)
        try hover(document, at: CGPoint(x: 70, y: 43))
        #expect(document.expansionFrame(withFrame: document.bounds).isEmpty)
        try hover(document, at: CGPoint(x: 70, y: 15))
        let exit = try #require(
            NSEvent.enterExitEvent(
                with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        document.mouseExited(with: exit)
        #expect(document.expansionFrame(withFrame: document.bounds).isEmpty)
    }

    @Test(arguments: [false, true])
    func treeUsesStatusColoredNamesWithoutRowSeparators(isDark: Bool) throws {
        let file = GitCommitFile(status: "M", path: "MMMMMMMM.swift")
        let root = GitCommitFileTreeNode.build(from: [file], rootName: "Repository")
        let scroll = try makeScroll(items: [.folder(root, depth: 0), .file(file, depth: 1)], width: 300)
        scroll.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let document = try #require(scroll.documentView as? GitCommitFileTreeNSView)
        document.appearance = scroll.appearance
        document.viewDidChangeEffectiveAppearance()
        scroll.updateDocumentLayout()
        #expect(GitCommitFileTreeNSView.rowHeight == 24)
        let bitmap = try #require(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / document.bounds.width
        // Every former folder/file row had a full-width opaque bottom border.
        for row in [0, 1] {
            let y = Int((4 + CGFloat(row + 1) * 24 - 1) * scale)
            #expect(try #require(bitmap.colorAt(x: Int(260 * scale), y: y)).alphaComponent < 0.05)
        }
        // Read actual glyph pixels, away from the file icon, in the modified row.
        var textColor: NSColor?
        var opacity: CGFloat = 0
        for y in Int(28 * scale)..<Int(52 * scale) {
            for x in Int(100 * scale)..<Int(200 * scale) {
                let pixel = try #require(bitmap.colorAt(x: x, y: y))
                if pixel.alphaComponent > opacity {
                    opacity = pixel.alphaComponent
                    textColor = NSColor(colorSpace: bitmap.colorSpace,
                        components: [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
                        count: 4).usingColorSpace(.sRGB)
                }
            }
        }
        let color = try #require(textColor)
        #expect(opacity > 0.9)
        #expect(abs(color.redComponent - (isDark ? 112.0/255 : 0)) < 0.02)
        #expect(abs(color.greenComponent - (isDark ? 174.0/255 : 51.0/255)) < 0.02)
        #expect(abs(color.blueComponent - (isDark ? 1 : 179.0/255)) < 0.02)
        if let directory = ProcessInfo.processInfo.environment["LITHE_GIT_GRAPH_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent("commit-files-\(isDark ? "dark" : "light").png"))
        }
    }

    private func makeScroll(items: [GitCommitFileTreeItem], width: CGFloat, subtitle: String? = nil) throws
        -> GitCommitFileTreeScrollNSView
    {
        let scroll = try #require(
            GitCommitFileTreeScrollView.makeScrollView(
                items: items, selectedFileID: nil, rootSubtitle: subtitle, collapsedFolderIDs: [],
                onToggleFolder: { _ in }, onSelectFile: { _ in }) as? GitCommitFileTreeScrollNSView)
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        scroll.tile()
        scroll.updateDocumentLayout()
        return scroll
    }

    private func hover(_ view: NSView, at point: CGPoint) throws {
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: event)
    }
}
