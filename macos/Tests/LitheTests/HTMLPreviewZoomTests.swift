import AppKit
import Testing
@testable import Lithe

struct HTMLPreviewZoomTests {
    @Test func zoomingWalksTheBrowserStopsAndEndsAtTheLimits() {
        #expect(HTMLPreviewZoom.zoomedIn(from: 1) == 1.1)
        #expect(HTMLPreviewZoom.zoomedOut(from: 1) == 0.9)
        #expect(HTMLPreviewZoom.zoomedIn(from: 0.25) == 0.33)
        #expect(HTMLPreviewZoom.zoomedOut(from: 0.25) == nil)
        #expect(HTMLPreviewZoom.zoomedIn(from: 5) == nil)
        #expect(HTMLPreviewZoom.zoomedOut(from: 5) == 4)
    }

    @Test func aFactorBetweenStopsSnapsToTheNeighbouringStop() {
        #expect(HTMLPreviewZoom.zoomedIn(from: 1.05) == 1.1)
        #expect(HTMLPreviewZoom.zoomedOut(from: 1.05) == 1)
        // A float the web view rounded slightly off a stop still counts as that stop.
        #expect(HTMLPreviewZoom.zoomedIn(from: 1.0000001) == 1.1)
        #expect(HTMLPreviewZoom.zoomedOut(from: 0.9999999) == 0.9)
    }

    @Test func percentagesAreRoundedForDisplay() {
        #expect(HTMLPreviewZoom.percent(1) == 100)
        #expect(HTMLPreviewZoom.percent(0.33) == 33)
        #expect(HTMLPreviewZoom.percent(1.1) == 110)
        #expect(HTMLPreviewZoom.percent(0.67) == 67)
    }

    @Test func commandShortcutsMatchBrowsers() {
        #expect(HTMLPreviewZoom.command(forKey: "=", modifiers: [.command]) == .zoomIn)
        #expect(HTMLPreviewZoom.command(forKey: "+", modifiers: [.command, .shift]) == .zoomIn)
        #expect(HTMLPreviewZoom.command(forKey: "-", modifiers: [.command]) == .zoomOut)
        #expect(HTMLPreviewZoom.command(forKey: "0", modifiers: [.command]) == .reset)
        // The numeric keypad adds its own flag, which must not hide the shortcut.
        #expect(HTMLPreviewZoom.command(forKey: "=", modifiers: [.command, .numericPad]) == .zoomIn)
    }

    @Test func otherKeyCombinationsAreLeftToTheirOwners() {
        #expect(HTMLPreviewZoom.command(forKey: "=", modifiers: []) == nil)
        #expect(HTMLPreviewZoom.command(forKey: "-", modifiers: [.control]) == nil)
        #expect(HTMLPreviewZoom.command(forKey: "=", modifiers: [.command, .option]) == nil)
        #expect(HTMLPreviewZoom.command(forKey: "0", modifiers: [.command, .control]) == nil)
        #expect(HTMLPreviewZoom.command(forKey: "a", modifiers: [.command]) == nil)
        #expect(HTMLPreviewZoom.command(forKey: "", modifiers: [.command]) == nil)
    }
}
