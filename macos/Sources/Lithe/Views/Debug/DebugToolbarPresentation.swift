import CoreGraphics
import LitheCoreContracts

/// Stable IDEA-aligned ordering and icon catalog for the macOS Debug toolbar.
/// Keeping these values outside the view prevents platform symbols or ad-hoc
/// reordering from silently changing the debugger's visual language.
enum DebugToolbarActionID: String, CaseIterable, Identifiable {
    case restartOrStart
    case stop
    case resume
    case pause
    case stepOver
    case stepInto
    case stepOut
    case viewBreakpoints
    case muteBreakpoints

    var id: Self { self }
}

enum DebugToolbarPresentation {
    static let primaryActions: [DebugToolbarActionID] = [
        .restartOrStart,
        .stop,
        .resume,
        .pause,
        .stepOver,
        .stepInto,
        .stepOut,
        .viewBreakpoints,
        .muteBreakpoints
    ]

    static let separatorsAfter: Set<DebugToolbarActionID> = [.stop, .stepOut]
    // Keep the primary controls legible at the compact tool-window scale;
    // IDEA's debugger gives these actions a little more visual weight than
    // ordinary tool-window buttons.
    static let iconSize: CGFloat = 18
    static let toolbarHeight: CGFloat = 36
    static let sessionHeaderHeight: CGFloat = 34

    static func statusText(
        for state: DebugAdapterState,
        stoppedReason: String?
    ) -> String {
        switch state {
        case .paused:
            let reason = stoppedReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reason.isEmpty else { return "Paused" }
            return "Paused · \(stopReasonLabel(reason))"
        case .running: return "Running"
        case .launching: return "Launching"
        case .initializing: return "Initializing"
        case .ready: return "Ready"
        case .terminated: return "Finished"
        case .failed: return "Failed"
        case .idle: return "Ready"
        }
    }

    private static func stopReasonLabel(_ reason: String) -> String {
        switch reason.lowercased() {
        case "breakpoint": return "Breakpoint"
        case "function breakpoint": return "Method breakpoint"
        case "data breakpoint": return "Field breakpoint"
        case "instruction breakpoint": return "Instruction breakpoint"
        case "exception": return "Exception"
        case "step": return "Step"
        case "pause": return "Pause"
        case "entry": return "Entry"
        case "goto": return "Run to cursor"
        default: return reason
        }
    }

    static func ideaAssetPath(
        for action: DebugToolbarActionID,
        isSessionActive: Bool = true
    ) -> String {
        switch action {
        case .restartOrStart:
            isSessionActive ? "debugger/restartDebug.svg" : "debugger/debug.svg"
        case .stop: "debugger/stop.svg"
        case .resume: "debugger/resume.svg"
        case .pause: "debugger/pause.svg"
        case .stepOver: "debugger/stepOver.svg"
        case .stepInto: "debugger/stepInto.svg"
        case .stepOut: "debugger/stepOut.svg"
        case .viewBreakpoints: "debugger/viewBreakpoints.svg"
        case .muteBreakpoints: "debugger/muteBreakpoints.svg"
        }
    }

    static func fallbackSystemImage(for action: DebugToolbarActionID) -> String {
        switch action {
        case .restartOrStart: "ladybug.fill"
        case .stop: "stop.fill"
        case .resume: "play.fill"
        case .pause: "pause.fill"
        case .stepOver: "arrow.right.to.line"
        case .stepInto: "arrow.down.to.line"
        case .stepOut: "arrow.up.to.line"
        case .viewBreakpoints: "list.bullet.rectangle"
        case .muteBreakpoints: "eye.slash"
        }
    }
}
