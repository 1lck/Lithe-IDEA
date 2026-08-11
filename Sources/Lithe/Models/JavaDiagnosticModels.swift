import Foundation

enum DiagnosticSeverity: Int, CaseIterable, Hashable, Sendable {
    case unknown = 0
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .error: "Error"
        case .warning: "Warning"
        case .information: "Information"
        case .hint: "Hint"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .hint: "lightbulb.fill"
        }
    }
}

enum DiagnosticTag: Int, Hashable, Sendable {
    case unnecessary = 1
    case deprecated = 2
}

struct DiagnosticRelatedInformation: Hashable, Sendable {
    let fileURL: URL
    let line: Int
    let utf16Column: Int
    let message: String

    var locationTitle: String {
        fileURL.lastPathComponent + ":" + String(line + 1) + ":" + String(utf16Column + 1)
    }
}

struct EditorDiagnostic: Identifiable, Hashable, Sendable {
    let id: String
    let fileURL: URL
    let line: Int
    let utf16Column: Int
    let endLine: Int
    let endUTF16Column: Int
    let severity: DiagnosticSeverity
    let message: String
    let source: String?
    let code: String?
    let tags: Set<DiagnosticTag>
    let relatedInformation: [DiagnosticRelatedInformation]

    init(
        id: String,
        fileURL: URL,
        line: Int,
        utf16Column: Int,
        endLine: Int,
        endUTF16Column: Int,
        severity: DiagnosticSeverity,
        message: String,
        source: String?,
        code: String?,
        tags: Set<DiagnosticTag>,
        relatedInformation: [DiagnosticRelatedInformation]
    ) {
        self.id = id
        self.fileURL = fileURL
        self.line = line
        self.utf16Column = utf16Column
        self.endLine = endLine
        self.endUTF16Column = endUTF16Column
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
        self.tags = tags
        self.relatedInformation = relatedInformation
    }

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

    init(languageServerDiagnostic diagnostic: LanguageServerDiagnostic, fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        let line = max(0, diagnostic.range.start.line)
        let column = max(0, diagnostic.range.start.utf16Column)
        let endLine = max(line, diagnostic.range.end.line)
        let endColumn = max(0, diagnostic.range.end.utf16Column)
        self.init(
            id: [
                normalizedURL.path,
                String(line),
                String(column),
                diagnostic.source ?? "lsp",
                diagnostic.code ?? "",
                diagnostic.message
            ].joined(separator: ":"),
            fileURL: normalizedURL,
            line: line,
            utf16Column: column,
            endLine: endLine,
            endUTF16Column: endColumn,
            severity: diagnostic.severity.flatMap(DiagnosticSeverity.init(rawValue:)) ?? .unknown,
            message: diagnostic.message,
            source: diagnostic.source,
            code: diagnostic.code,
            tags: Set(diagnostic.tags.compactMap(DiagnosticTag.init(rawValue:))),
            relatedInformation: diagnostic.relatedInformation.map {
                DiagnosticRelatedInformation(
                    fileURL: $0.fileURL.standardizedFileURL,
                    line: max(0, $0.range.start.line),
                    utf16Column: max(0, $0.range.start.utf16Column),
                    message: $0.message
                )
            }
        )
    }

    static func fromLanguageServerDiagnostics(
        _ diagnosticsByFile: [URL: [LanguageServerDiagnostic]]
    ) -> [URL: [EditorDiagnostic]] {
        diagnosticsByFile.reduce(into: [URL: [EditorDiagnostic]]()) { mapped, entry in
            let (fileURL, diagnostics) = entry
            let normalizedURL = fileURL.standardizedFileURL
            mapped[normalizedURL, default: []].append(contentsOf: diagnostics.map {
                EditorDiagnostic(languageServerDiagnostic: $0, fileURL: normalizedURL)
            })
        }
    }
}
