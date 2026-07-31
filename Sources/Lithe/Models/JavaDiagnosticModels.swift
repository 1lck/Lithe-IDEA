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

enum JavaDiagnosticTag: Int, Hashable, Sendable {
    case unnecessary = 1
    case deprecated = 2
}

struct JavaDiagnosticRelatedInformation: Hashable, Sendable {
    let fileURL: URL
    let line: Int
    let utf16Column: Int
    let message: String

    var locationTitle: String {
        fileURL.lastPathComponent + ":" + String(line + 1) + ":" + String(utf16Column + 1)
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
    let code: String?
    let tags: Set<JavaDiagnosticTag>
    let relatedInformation: [JavaDiagnosticRelatedInformation]

    var isUnnecessary: Bool {
        if tags.contains(.unnecessary) { return true }
        let searchableText = ((code ?? "") + " " + message).lowercased()
        return searchableText.contains("unused") ||
            searchableText.contains("unnecessary") ||
            searchableText.contains("never used") ||
            searchableText.contains("not used") ||
            searchableText.contains("never read")
    }

    var reasonSummary: String? {
        if isUnnecessary { return "Unused code" }
        if tags.contains(.deprecated) { return "Deprecated API" }
        guard let code, !code.isEmpty else { return nil }
        return code
    }

    var detailText: String {
        var details = [message]
        if let source, !source.isEmpty { details.append("Source: \(source)") }
        if let code, !code.isEmpty { details.append("Code: \(code)") }
        for related in relatedInformation {
            details.append("Related: \(related.locationTitle) - \(related.message)")
        }
        return details.joined(separator: "\n")
    }

    var locationTitle: String {
        fileURL.lastPathComponent + ":" + String(line + 1) + ":" + String(utf16Column + 1)
    }
}
