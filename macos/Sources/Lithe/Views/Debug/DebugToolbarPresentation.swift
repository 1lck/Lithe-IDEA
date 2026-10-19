import AppKit
import SwiftUI
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
    static func mainToolbarControl(state: DebugAdapterState?, debugTarget: String?, selectedTarget: String?) -> DebugToolbarActionID? {
        guard let debugTarget, debugTarget == selectedTarget else { return nil }
        switch state {
        case .paused: return .resume
        case .running: return .pause
        default: return nil
        }
    }

    static func stackFrameLabel(_ frame: DebugStackFrame, showsSourceName: Bool) -> String {
        guard showsSourceName, let source = frame.sourceURL, source.pathExtension.lowercased() == "java" else {
            return frame.name
        }
        let suffix = ", " + source.deletingPathExtension().lastPathComponent
        // ponytail: remove only an exact redundant provider suffix; richer labels need structured DAP segments.
        return frame.name.count > suffix.count && frame.name.hasSuffix(suffix) ? String(frame.name.dropLast(suffix.count)) : frame.name
    }

    static func stackFrameText(_ frame: DebugStackFrame, showsSourceName: Bool, isDark: Bool) -> AttributedString {
        let label = stackFrameLabel(frame, showsSourceName: showsSourceName)
        var result = DiffSyntaxHighlighter.styled(label, fileExtension: frame.sourceURL?.pathExtension ?? "", highlight: nil)
        guard frame.sourceURL?.pathExtension.lowercased() == "java",
              let location = label.range(of: ":\(frame.line)", options: .backwards),
              location.upperBound == label.endIndex || label[location.upperBound...].hasPrefix(", ") else { return result }
        let methodAndType = label[..<location.lowerBound].prefix { $0 != "(" }
        let method = methodAndType.split(separator: ".").last ?? methodAndType
        guard !method.isEmpty else { return result }
        let offset = methodAndType.count - method.count
        let start = result.characters.index(result.startIndex, offsetBy: offset)
        let end = result.characters.index(start, offsetBy: method.count)
        let palette = SyntaxHighlightingColorConfiguration.bundled.palette(formatID: "java",
            base: CodeEditorPalette(isDark: isDark, theme: LitheTheme.activeTheme))
        result[start..<end].foregroundColor = Color(nsColor: palette.functionCall)
        return result
    }

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
    // Standard ActionToolbar buttons retain the original 16pt IDEA glyphs.
    static let iconSize: CGFloat = 16
    static let toolbarHeight: CGFloat = 36

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
            isSessionActive ? "expui/run/restartDebug.svg" : "expui/run/debug.svg"
        case .stop: "expui/run/stop.svg"
        case .resume: "expui/run/resume.svg"
        case .pause: "expui/run/pause.svg"
        case .stepOver: "expui/run/stepOver.svg"
        case .stepInto: "expui/run/stepInto.svg"
        case .stepOut: "expui/run/stepOut.svg"
        case .viewBreakpoints: "expui/run/viewBreakpoints.svg"
        case .muteBreakpoints: "expui/run/muteBreakpoints.svg"
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
