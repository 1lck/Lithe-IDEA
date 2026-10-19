import Foundation

/// Placement is distinct from binding: the adapter owns Java syntax and bytecode
/// locations, including brace and declaration lines that may never suspend.
public enum DebugBreakpointLocationValidator {
    public static func canSetSourceBreakpoint(source: String, line: Int) -> Bool {
        line > 0 && line <= source.components(separatedBy: .newlines).count
    }
}
