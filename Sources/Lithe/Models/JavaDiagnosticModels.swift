import Foundation

enum JavaDiagnosticSeverity: Int, CaseIterable, Hashable, Sendable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4

    var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .information: "Information"
        case .hint: "Hint"
        }
    }

    var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .hint: "lightbulb.fill"
        }
    }
}

struct JavaDiagnostic: Identifiable, Hashable, Sendable {
    let id: String
    let fileURL: URL
    let line: Int
    let utf16Column: Int
    let endLine: Int
    let endUTF16Column: Int
    let severity: JavaDiagnosticSeverity
    let message: String
    let source: String?

    var locationTitle: String {
        fileURL.lastPathComponent + ":" + String(line + 1) + ":" + String(utf16Column + 1)
    }
}
