import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("IDEA-aligned Debug toolbar presentation")
struct DebugToolbarPresentationTests {
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
        ) == "debugger/debug.svg")
        #expect(DebugToolbarPresentation.ideaAssetPath(
            for: .restartOrStart,
            isSessionActive: true
        ) == "debugger/restartDebug.svg")
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
