import AppKit
import CoreText
import SwiftUI
import Testing
import LitheGitModule
@testable import Lithe

@Suite("Native Diff appearance", .serialized)
@MainActor
struct DiffAppearanceTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func replacementWithAnExtraLineUsesOnePairedFragment(appearance: NSAppearance.Name) async throws {
        let rows = [
            DiffRow(oldLine: 77, newLine: 77, left: "before", right: nil, kind: .context, sequence: 0),
            DiffRow(oldLine: 78, newLine: 78, left: "    \"tests::git::git_write_edits_a_local_commit_message_\"",
                right: "    \"tests::git::git_write_edits_a_local_commit_message_\",", kind: .changed, sequence: 1),
            DiffRow(oldLine: nil, newLine: 79, left: nil,
                right: "    \"tests::git_patch_exchange::patch_metadata\"", kind: .addition, sequence: 2),
            DiffRow(oldLine: 79, newLine: 80, left: ")) {", right: nil, kind: .context, sequence: 3)
        ]
        let layout = DiffSplitLayout.plan(displayRows: rows.enumerated().map { .row($0.element, index: $0.offset) },
            kinds: rows.map(\.kind))
        let fragment = try #require(layout.transitions.first)
        #expect(layout.transitions.count == 1)
        #expect(fragment.kind == .changed)
        #expect(fragment.leftRange == 22...44 && fragment.rightRange == 22...66)
        #expect(layout.rightItems.map(\.kind) == [.context, .changed, .changed, .context])
        let state = DiffNativeColumnState()
        state.prepare(identity: layout.identity, items: layout.rightItems, side: .right,
            fileExtension: "ps1", highlightsWords: true, dark: true)
        #expect(state.preparedText.string == rows.compactMap(\.rightText).joined(separator: "\n") + "\n")
        #expect(state.lines.map(\.sourceNumber) == [77, 78, 79, 80])
        // The extra line is an inline insertion inside a blue replacement,
        // never a separate green gutter/connector with a misplaced anchor.
        let inline = try #require(state.preparedText.attribute(.backgroundColor,
            at: state.lines[2].range.location + 5, effectiveRange: nil) as? NSColor)
        #expect(inline.usingColorSpace(.deviceRGB) == NSColor(LitheTheme.Diff.inserted).usingColorSpace(.deviceRGB))
        let reversed = rows.map { row in DiffRow(oldLine: row.newLine, newLine: row.oldLine,
            left: row.rightText, right: row.left, kind: row.kind == .addition ? .removal : row.kind,
            sequence: row.id.sequence) }
        let reverse = DiffSplitLayout.plan(displayRows: reversed.enumerated().map { .row($0.element, index: $0.offset) },
            kinds: reversed.map(\.kind))
        #expect(reverse.transitions.count == 1 && reverse.transitions[0].kind == .changed)
        #expect(reverse.transitions[0].leftRange == 22...66 && reverse.transitions[0].rightRange == 22...44)
        let dark = appearance == .darkAqua
        let hosting = NSHostingView(rootView: DiffSplitPaneView(
            displayRows: rows.enumerated().map { .row($0.element, index: $0.offset) },
            kinds: rows.map(\.kind), layout: layout, fileExtension: "ps1", contentWidth: 1_600,
            viewportWidth: 1_200, onExpand: { _ in }).environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 1_200, height: 160)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        // Sample to the right of the glyphs: the added text has a green inline fill
        // inside the muted blue line, while the paired gutter stays solid blue.
        for (point, hex) in [(NSPoint(x: 1_180, y: 55), dark ? 0x25323E : 0xE6EFFA),
                             (NSPoint(x: 600, y: 33), dark ? 0x385570 : 0xC2D8F2)] {
            let color = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
            #expect(abs(color.redComponent - CGFloat((hex >> 16) & 255) / 255) < 0.03
                && abs(color.greenComponent - CGFloat((hex >> 8) & 255) / 255) < 0.03
                && abs(color.blueComponent - CGFloat(hex & 255) / 255) < 0.03,
                "The extra source line and paired connector must render as one replacement: \(color)")
        }
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("paired-\(dark).png"))
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func rendersCentralSourceNumbersAndIDEAColors(appearance: NSAppearance.Name) async throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/JetBrainsMono-Regular.ttf")
        let ownsFont = NSFont(name: "JetBrainsMono-Regular", size: 13) == nil
        if ownsFont { #expect(CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)) }
        defer { if ownsFont { CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, nil) } }
        #expect(LitheTheme.editorFont(size: DiffLayoutMetrics.textFontSize).fontName == "JetBrainsMono-Regular")
        #expect(DiffLayoutMetrics.textFontSize == 13)

        let rows = [
            DiffRow(oldLine: 581, newLine: 681, left: "if let view = textView {", right: nil, kind: .context, sequence: 0),
            DiffRow(oldLine: nil, newLine: 682, left: nil, right: "view.refresh()", kind: .addition, sequence: 1),
            DiffRow(oldLine: 582, newLine: 683, left: "let text = \"中文\"", right: nil, kind: .context, sequence: 2),
            DiffRow(oldLine: 583, newLine: nil, left: "oldMethod()", right: nil, kind: .removal, sequence: 3),
            DiffRow(oldLine: 584, newLine: 684, left: "let value = 1", right: "let value = 2", kind: .changed, sequence: 4)
        ]
        let display = rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: rows.map(\.kind))
        #expect(layout.leftItems.compactMap { item -> Int? in
            guard case let .row(row, _) = item.displayRow else { return nil }; return row.oldLine
        } == [581, 582, 583, 584])
        #expect(layout.rightItems.compactMap { item -> Int? in
            guard case let .row(row, _) = item.displayRow else { return nil }; return row.newLine
        } == [681, 682, 683, 684])

        let dark = appearance == .darkAqua
        let view = DiffSplitPaneView(displayRows: display, kinds: rows.map(\.kind), layout: layout,
            fileExtension: "swift", contentWidth: 1_600, viewportWidth: 900,
            onExpand: { _ in }).environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let scale = CGFloat(image.width) / 900
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)))
        }
        func matches(_ color: NSColor, _ hex: UInt32, tolerance: CGFloat = 0.025) -> Bool {
            abs(color.redComponent - CGFloat((hex >> 16) & 255) / 255) < tolerance
                && abs(color.greenComponent - CGFloat((hex >> 8) & 255) / 255) < tolerance
                && abs(color.blueComponent - CGFloat(hex & 255) / 255) < tolerance
        }
        // The outer 14pt now contains whole-file change markers; sample the code surface.
        let background = try color(20, 140)
        let inserted = try color(880, 33)
        let deleted = try color(300, 55)
        let modified = try color(880, 77)
        #expect(matches(background, dark ? 0x191A1C : 0xFFFFFF), "Background: \(background)")
        #expect(matches(inserted, dark ? 0x294436 : 0xBEE6BE), "Inserted: \(inserted)")
        #expect(matches(deleted, dark ? 0x25323E : 0xE6EFFA), "Replacement: \(deleted)")
        #expect(matches(modified, dark ? 0x25323E : 0xE6EFFA), "Modified: \(modified)")
        let paneWidth = (900 - DiffLayoutMetrics.centerGutterWidth) / 2
        // Both columns must actually draw source numbers in the central gutter.
        for start in [paneWidth, paneWidth + DiffLayoutMetrics.lineNumberGutterWidth + DiffLayoutMetrics.dividerWidth] {
            var numberPixels = 0
            for x in Int(start + 10)..<Int(start + DiffLayoutMetrics.lineNumberGutterWidth - 5) {
                for y in 3..<20 {
                    if matches(try color(CGFloat(x), CGFloat(y)), dark ? 0x4B5059 : 0xAEB3C2, tolerance: 0.04) {
                        numberPixels += 1
                    }
                }
            }
            #expect(numberPixels > 5, "Source numbers must render beside the divider")
        }
        // Exercise the production native handle: numbers and curves must
        // follow the resized pane rather than the original 50/50 division.
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let handle = try #require(descendants(hosting).compactMap { $0 as? SplitHandleInteractionView }.first)
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, offset: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x + offset, y: origin.y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, offset: 0))
        handle.mouseDragged(with: try event(.leftMouseDragged, offset: 70))
        handle.mouseUp(with: try event(.leftMouseUp, offset: 70))
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        let resized = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: resized)
        let resizedBackground = try #require(resized.colorAt(x: Int(450 * scale), y: Int(28 * scale)))
        let resizedCurve = try #require(resized.colorAt(x: Int(520 * scale), y: Int(28 * scale)))
        #expect(matches(resizedBackground, dark ? 0x191A1C : 0xFFFFFF))
        #expect(matches(resizedCurve, dark ? 0x294436 : 0xBEE6BE))
        let editors = descendants(hosting).compactMap { $0 as? DiffNativeTextView }
        #expect(editors.count == 2)
        let editor = try #require(editors.first)
        let column = try #require(editor.column)
        let revision = column.revision
        let caret = column.lines[1].range.location
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: caret, length: column.lines[1].range.length + 3))
        #expect((editor.string as NSString).substring(with: editor.selectedRange()).contains("\n"))
        #expect(column.caretLine == 2)
        let hitPoint = editor.convert(NSPoint(x: 24, y: 10), to: hosting.superview)
        #expect(hosting.hitTest(hitPoint) === editor, "Transparent anchors/curves must not intercept code selection: point=\(hitPoint), bounds=\(hosting.bounds)")
        let selected = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: selected)
        let numberView = try #require(column.gutter)
        let caretY = column.lines[2].item.top + 5
        let numberOrigin = hosting.convert(NSPoint(x: 0, y: caretY), from: numberView)
        var brightNumberPixels = 0
        for x in 10..<50 {
            for y in 0..<12 {
                let pixel = try #require(selected.colorAt(x: Int((numberOrigin.x + CGFloat(x)) * scale),
                    y: Int((numberOrigin.y + CGFloat(y)) * scale)))
                if matches(pixel, dark ? 0xA1A3AB : 0x767A8A, tolerance: 0.04) { brightNumberPixels += 1 }
            }
        }
        #expect(brightNumberPixels > 5, "Only the active caret row uses IDEA's bright source-number color")
        // Move all the way to each boundary, then reopen the editors. Native
        // text storage and its multi-line selection must survive every move.
        for target in [72.0, 0.0, 900.0, 450.0] {
            let handlePoint = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let delta = CGFloat(target) - handlePoint.x
            func dragEvent(_ type: NSEvent.EventType, _ dx: CGFloat) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: handlePoint.x + dx, y: handlePoint.y), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            handle.mouseDown(with: try dragEvent(.leftMouseDown, 0))
            handle.mouseDragged(with: try dragEvent(.leftMouseDragged, delta))
            handle.mouseUp(with: try dragEvent(.leftMouseUp, delta))
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            #expect(column.revision == revision, "Dragging must not tokenize or replace text storage")
            #expect(editor.selectedRange().length > column.lines[1].range.length)
            let widths = DiffSplitWidths(width: 900, position: CGFloat(target))
            #expect(abs(widths.leftCode + widths.leftNumbers + widths.divider + widths.rightNumbers + widths.rightCode - 900) < 0.001)
            if target == 72 { #expect(widths.leftCode == 0); #expect(widths.leftNumbers == 55) }
            if target == 0 { #expect(widths.leftNumbers == 0); #expect(widths.divider == 0) }
            if target == 900 { #expect(widths.rightNumbers == 0); #expect(widths.divider == 0) }
            let clipped = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: clipped)
            if target == 0 || target == 72 || target == 900 {
                let x: CGFloat = target == 900 ? 860 : 10
                let pixel = try #require(clipped.colorAt(x: Int(x * scale), y: Int(28 * scale)))
                #expect(matches(pixel, target == 0 ? (dark ? 0x294436 : 0xBEE6BE)
                    : (dark ? 0x191A1C : 0xFFFFFF)), "The old gutter persists before complete collapse; the new gutter starts at the edge afterward")
                if dark, let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                    try #require(clipped.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("collapse-\(Int(target)).png"))
                }
            }

        }
        let contextEvent = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
            location: editor.convert(NSPoint(x: 24, y: 10), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(editor.menu(for: contextEvent) == nil, "Diff copy must use the shared popup, not NSTextView's system menu")
        let menuPanel = try #require(window.childWindows?.first)
        #expect(menuPanel.animationBehavior == .none)
        #expect(menuPanel.frame.height == LitheDropdownMetrics.verticalPadding + LitheDropdownMetrics.rowHeight)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: menuPanel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        menuPanel.sendEvent(escape)
        #expect(!menuPanel.isVisible)
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent(dark ? "diff-dark.png" : "diff-light.png"))
        }
    }
    @Test
    func splitWidthsStayValidInNarrowWindowsAndRecoverBothSides() {
        for width in [0.0, 1.0, 20.0, 100.0, 900.0] {
            for position in [-100.0, 0.0, 72.0, 450.0, 1_000.0] {
                let panes = DiffSplitWidths(width: width, position: position)
                let parts = [panes.leftCode, panes.leftNumbers, panes.divider, panes.rightNumbers, panes.rightCode]
                #expect(parts.allSatisfy { $0 >= 0 })
                #expect(abs(parts.reduce(0, +) - width) < 0.001)
            }
        }
    }

    @Test
    func nativeLayoutKeepsSourceRowsAndPreparedStorageDuringResize() async throws {
        let rows = (0..<1_200).map { index in
            DiffRow(oldLine: index + 1, newLine: index + 1,
                left: "let value_\(index) = \(index)", right: index.isMultiple(of: 2) ? "let value_\(index) = \(index + 1)" : nil,
                kind: index.isMultiple(of: 2) ? .changed : .context, sequence: index)
        }
        let display = rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: rows.map(\.kind))
        let view = DiffSplitPaneView(displayRows: display, kinds: rows.map(\.kind), layout: layout,
            fileExtension: "swift", contentWidth: 1_600, viewportWidth: 900, onExpand: { _ in })
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editors = descendants(hosting).compactMap { $0 as? DiffNativeTextView }
        #expect(editors.count == 2)
        let handle = try #require(descendants(hosting).compactMap { $0 as? SplitHandleInteractionView }.first)
        let revisions = editors.map { $0.column?.revision }
        let manager = try #require(editors.first?.layoutManager)
        let container = try #require(editors.first?.textContainer)
        manager.ensureLayout(for: container)
        for editor in editors {
            let column = try #require(editor.column)
            #expect(column.lines.count == 1_200)
            #expect(column.preparedText.string.components(separatedBy: "\n").count == 1_201)
            let line = column.lines[1]
            let rect = try #require(editor.layoutManager).boundingRect(forGlyphRange:
                try #require(editor.layoutManager).glyphRange(forCharacterRange: line.range, actualCharacterRange: nil),
                in: try #require(editor.textContainer))
            #expect(abs(rect.minY - line.item.top) < 0.5, "Native paragraph positions must match gutter/fold geometry")
        }
        var durations: [Double] = []
        for frame in 0..<60 {
            let origin = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let target = CGFloat(80 + (frame * 67) % 740)
            func event(_ type: NSEvent.EventType, dx: CGFloat) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x + dx, y: origin.y),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: frame, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            let start = ContinuousClock.now
            handle.mouseDown(with: try event(.leftMouseDown, dx: 0))
            handle.mouseDragged(with: try event(.leftMouseDragged, dx: target - origin.x))
            handle.mouseUp(with: try event(.leftMouseUp, dx: target - origin.x))
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            #expect(editors.map { $0.column?.revision } == revisions)
            #expect(manager.firstUnlaidCharacterIndex() == editors[0].string.utf16.count,
                "Changing the clip must not invalidate the fixed text-container layout")
        }
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            let values = durations.sorted()
            let data = try JSONSerialization.data(withJSONObject: ["rows": 1_200, "frames": values.count,
                "componentLayoutAndCaptureP95MS": values[Int(Double(values.count - 1) * 0.95)],
                "textRebuildsDuringResize": 0], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("resize-cost.json"))
        }
    }

    @Test
    func nativeSelectionSkipsPatchHeadersAndFoldBands() async throws {
        let header = DiffRow(oldLine: nil, newLine: nil, left: "@@ patch header @@", right: "@@ patch header @@",
            kind: .information, sequence: 0)
        let first = DiffRow(oldLine: 675, newLine: 675, left: "first", right: nil, kind: .context, sequence: 1)
        let last = DiffRow(oldLine: 690, newLine: 690, left: "last", right: nil, kind: .context, sequence: 2)
        let display: [DiffDisplayRow] = [.row(header, index: 0), .row(first, index: 1),
            .collapsed(DiffCollapsedRegion(id: "fold", startIndex: 2, endIndex: 15)), .row(last, index: 15)]
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: [.information, .context, .information, .context])
        let column = DiffNativeColumnState()
        column.prepare(identity: layout.identity, items: layout.leftItems, side: .left,
            fileExtension: "txt", highlightsWords: false, dark: true)
        #expect(column.selectedSource(in: NSRange(location: 0, length: column.preparedText.length)) == "first\nlast\n")
        let editor = DiffNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.column = column
        editor.textContainerInset = .zero
        editor.textStorage?.setAttributedString(column.preparedText)
        let manager = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        manager.ensureLayout(for: container)
        let range = manager.glyphRange(forCharacterRange: try #require(column.lines.last).range, actualCharacterRange: nil)
        #expect(abs(manager.boundingRect(forGlyphRange: range, in: container).minY - 76) < 0.5)
        // Information-row actions belong to the viewport edge, even though
        // the native code storage is wider and does not resize with the split.
        let view = DiffSplitPaneView(displayRows: display, kinds: [.information, .context, .information, .context],
            layout: layout, fileExtension: "txt", contentWidth: 900, viewportWidth: 900, onExpand: { _ in }) { row, side in
                if row.kind == .information, side == .right {
                    Color(NSColor.magenta).frame(width: 60, height: 27)
                }
            }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / 900
        let actionPixel = try #require(bitmap.colorAt(x: Int(870 * scale), y: Int(13 * scale)))
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("header-actions.png"))
        }
        #expect(actionPixel.redComponent > 0.8 && actionPixel.greenComponent < 0.5 && actionPixel.blueComponent > 0.8,
            "Existing hunk actions must remain visible at the right code viewport edge: \(actionPixel)")

    }

}
