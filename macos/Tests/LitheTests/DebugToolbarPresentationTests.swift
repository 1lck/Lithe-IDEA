import AppKit
import Foundation
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("IDEA-aligned Debug toolbar presentation")
struct DebugToolbarPresentationTests {
    @Test
    func mainToolbarUsesPauseAndResumeOnlyForTheSelectedDebugTarget() {
        for state in [DebugAdapterState.idle, .initializing, .ready, .launching, .running, .paused, .terminated, .failed] {
            let control = DebugToolbarPresentation.mainToolbarControl(state: state,
                debugTarget: "CalculatorTest.addsPositiveNumbers", selectedTarget: "CalculatorTest.addsPositiveNumbers")
            #expect(control == (state == .paused ? .resume : state == .running ? .pause : nil))
            #expect(DebugToolbarPresentation.mainToolbarControl(state: state,
                debugTarget: "CalculatorTest.addsPositiveNumbers", selectedTarget: "RunDemo") == nil)
        }
        #expect(DebugToolbarPresentation.mainToolbarControl(state: .paused, debugTarget: nil, selectedTarget: nil) == nil)
        #expect(DebugToolbarPresentation.ideaAssetPath(for: .resume) == "expui/run/resume.svg")
        #expect(DebugToolbarPresentation.ideaAssetPath(for: .pause) == "expui/run/pause.svg")
    }

    @Test
    func sourceNameToggleRemovesOnlyAnExactDuplicateClassSuffix() {
        let source = URL(fileURLWithPath: "/demo/UserService.java")
        let frame = DebugStackFrame(id: 1, name: "findUser:42, UserService", sourceURL: source, line: 42, column: 1)
        #expect(DebugToolbarPresentation.stackFrameLabel(frame, showsSourceName: true) == "findUser:42")
        #expect(DebugToolbarPresentation.stackFrameLabel(frame, showsSourceName: false) == frame.name)
        for name in ["findUser:42, UserService$Inner", "findUser:42, OtherService", "example.UserService.findUser", ", UserService"] {
            let other = DebugStackFrame(id: 2, name: name, sourceURL: source, line: 42, column: 1)
            #expect(DebugToolbarPresentation.stackFrameLabel(other, showsSourceName: true) == name)
        }
        let unknown = DebugStackFrame(id: 3, name: frame.name, sourceURL: nil, line: 42, column: 1)
        #expect(DebugToolbarPresentation.stackFrameLabel(unknown, showsSourceName: true) == frame.name)
    }

    @MainActor
    @Test
    func qualifiedMethodsWithMultipleParametersRetainMethodHighlighting() throws {
        let frame = DebugStackFrame(id: 1, name: "example.UserService.findUser(java.lang.String, int):42, UserService",
            sourceURL: URL(fileURLWithPath: "/demo/UserService.java"), line: 42, column: 1)
        let text = DebugToolbarPresentation.stackFrameText(frame, showsSourceName: true, isDark: true)
        let range = try #require(text.range(of: "findUser"))
        let palette = SyntaxHighlightingColorConfiguration.bundled.palette(formatID: "java",
            base: CodeEditorPalette(isDark: true, theme: LitheTheme.activeTheme))
        #expect(text[range].foregroundColor == Color(nsColor: palette.functionCall))
        #expect(String(text.characters).hasSuffix(":42"))
    }

    @MainActor
    @Test(arguments: [false, true])
    func stackMethodsUseTheConfiguredJavaSyntaxColor(isDark: Bool) {
        let frame = DebugStackFrame(id: 1, name: "findUser:42, UserService",
            sourceURL: URL(fileURLWithPath: "/demo/UserService.java"), line: 42, column: 1)
        let text = DebugToolbarPresentation.stackFrameText(frame, showsSourceName: true, isDark: isDark)
        #expect(String(text.characters) == "findUser:42")
        let end = text.characters.index(text.startIndex, offsetBy: "findUser".count)
        let palette = SyntaxHighlightingColorConfiguration.bundled.palette(formatID: "java",
            base: CodeEditorPalette(isDark: isDark, theme: LitheTheme.activeTheme))
        #expect(text[text.startIndex..<end].foregroundColor == Color(nsColor: palette.functionCall))
        #expect(text.runs.count > 1, "Method, punctuation and line number retain separate syntax attributes")
    }

    @Test
    func primaryActionsKeepTheIDEAOrderAndGrouping() {
        #expect(DebugToolbarPresentation.primaryActions == [
            .restartOrStart,
            .stop,
            .resume,
            .pause,
            .stepOver,
            .stepInto,
            .stepOut,
            .viewBreakpoints,
            .muteBreakpoints
        ])
        #expect(DebugToolbarPresentation.separatorsAfter == [.stop, .stepOut])
    }

    @Test
    func startActionUsesDebugBeforeLaunchAndRestartDuringASession() {
        #expect(DebugToolbarPresentation.ideaAssetPath(
            for: .restartOrStart,
            isSessionActive: false
        ) == "expui/run/debug.svg")
        #expect(DebugToolbarPresentation.ideaAssetPath(
            for: .restartOrStart,
            isSessionActive: true
        ) == "expui/run/restartDebug.svg")
    }

    @Test
    func everyPrimaryActionShipsLightAndDarkIDEAAssets() {
        let iconRoot = repositoryRoot
            .appendingPathComponent("macos/Resources/IDEAIcons", isDirectory: true)

        for action in DebugToolbarPresentation.primaryActions {
            let resourcePath = DebugToolbarPresentation.ideaAssetPath(
                for: action,
                isSessionActive: true
            )
            #expect(FileManager.default.fileExists(
                atPath: iconRoot.appendingPathComponent(resourcePath).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: iconRoot.appendingPathComponent(
                    LitheIcons.darkIdeaAssetPath(for: resourcePath)
                ).path
            ))
        }
    }

    @MainActor
    @Test
    func consoleActionsRenderNativeLightAndDarkAssets() throws {
        let root = repositoryRoot.appendingPathComponent("macos/Resources/IDEAIcons")
        for action in ConsoleToolbarAction.allCases {
            for dark in [false, true] {
                let path = dark ? LitheIcons.darkIdeaAssetPath(for: action.asset) : action.asset
                let image = try #require(NSImage(contentsOf: root.appendingPathComponent(path)), "Missing \(path)")
                #expect(image.size == NSSize(width: 16, height: 16))
                let tiff = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                var opaquePixel: NSColor?
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh {
                        if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.99 {
                            opaquePixel = pixel
                            break
                        }
                    }
                    if opaquePixel != nil { break }
                }
                let pixel = try #require(opaquePixel, "Empty or translucent SVG: \(path)")
                // SVG decoding applies the native color profile; render the reference
                // through that same pipeline instead of comparing sRGB to raw SVG bytes.
                let hex = dark ? "#CED0D6" : "#6C707E"
                let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                #expect(source.contains(hex), "Wrong source palette: \(path)")
                let swatch = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\" fill=\"\(hex)\"/></svg>"
                let reference = try #require(NSImage(data: Data(swatch.utf8)))
                let referenceTIFF = try #require(reference.tiffRepresentation)
                let referenceBitmap = try #require(NSBitmapImageRep(data: referenceTIFF))
                let expected = try #require(referenceBitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.sRGB))
                for (actual, channel) in zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent],
                                             [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                    #expect(abs(actual - channel) < 0.02, "Wrong rendered palette: \(path)")
                }
            }
        }
    }

    @MainActor
    @Test
    func inspectorUsesNativeNewUIAssetsInBothAppearances() throws {
        let root = repositoryRoot.appendingPathComponent("macos/Resources/IDEAIcons")
        for base in ["expui/debugger/addToWatch", "expui/debugger/frame", "expui/debugger/threadCurrent",
                     "expui/debugger/threadRunning", "expui/debugger/threads", "expui/debugger/watch",
                     "expui/nodes/field", "expui/nodes/variable",
                     "expui/general/chevronDown", "expui/general/chevronRight", "expui/general/refresh"] {
            for suffix in [".svg", "_dark.svg"] {
                let path = base + suffix
                let image = try #require(NSImage(contentsOf: root.appendingPathComponent(path)), "Missing \(path)")
                #expect(image.size == NSSize(width: 16, height: 16))
                let tiff = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                #expect((0..<bitmap.pixelsWide).contains { x in
                    (0..<bitmap.pixelsHigh).contains { y in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                    }
                }, "Empty inspector asset: \(path)")
            }
        }
    }

    @Test
    func darkAssetPathKeepsTheIDEADirectoryAndSuffixConvention() {
        #expect(
            LitheIcons.darkIdeaAssetPath(for: "debugger/stepOver.svg")
                == "debugger/stepOver_dark.svg"
        )
    }

    @Test
    func breakpointStatesUseTheIDEAGutterGlyphs() {
        #expect(LitheIcons.debuggerBreakpointAssetPath(
            enabled: true,
            verified: false,
            muted: false
        ) == "debugger/db_set_breakpoint.svg")
        #expect(LitheIcons.debuggerBreakpointAssetPath(
            enabled: true,
            verified: true,
            muted: false
        ) == "debugger/db_verified_breakpoint.svg")
        #expect(LitheIcons.debuggerBreakpointAssetPath(
            enabled: false,
            verified: true,
            muted: false
        ) == "debugger/db_disabled_breakpoint.svg")
        #expect(LitheIcons.debuggerBreakpointAssetPath(
            enabled: true,
            verified: true,
            muted: true
        ) == "debugger/db_muted_breakpoint.svg")
    }

    @Test
    func toolbarCommandIDsMapToTheExistingKeymapCommands() {
        #expect(LitheCommandCatalog.command(id: "debug-resume") != nil)
        #expect(LitheCommandCatalog.command(id: "debug-step-over") != nil)
        #expect(LitheCommandCatalog.command(id: "debug-step-into") != nil)
        #expect(LitheCommandCatalog.command(id: "debug-step-out") != nil)
        #expect(LitheCommandCatalog.command(id: "view-breakpoints") != nil)
    }

    @Test
    func statusTextIncludesTheActualStopReason() {
        #expect(DebugToolbarPresentation.statusText(
            for: .paused,
            stoppedReason: "breakpoint"
        ) == "Paused · Breakpoint")
        #expect(DebugToolbarPresentation.statusText(
            for: .paused,
            stoppedReason: "exception"
        ) == "Paused · Exception")
        #expect(DebugToolbarPresentation.statusText(
            for: .paused,
            stoppedReason: "function breakpoint"
        ) == "Paused · Method breakpoint")
        #expect(DebugToolbarPresentation.statusText(
            for: .paused,
            stoppedReason: "data breakpoint"
        ) == "Paused · Field breakpoint")
        #expect(DebugToolbarPresentation.statusText(
            for: .paused,
            stoppedReason: "  "
        ) == "Paused")
    }

    @Test
    func statusTextMapsLifecycleStatesToStableLabels() {
        #expect(DebugToolbarPresentation.statusText(for: .running, stoppedReason: nil) == "Running")
        #expect(DebugToolbarPresentation.statusText(for: .launching, stoppedReason: nil) == "Launching")
        #expect(DebugToolbarPresentation.statusText(for: .terminated, stoppedReason: nil) == "Finished")
        #expect(DebugToolbarPresentation.statusText(for: .failed, stoppedReason: nil) == "Failed")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
