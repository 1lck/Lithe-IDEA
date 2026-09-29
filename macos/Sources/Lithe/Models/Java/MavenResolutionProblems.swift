import Foundation

/// Maven problems JDT LS reports for the open workspace.
///
/// JDT LS imports Maven projects through m2e and reports every failure to read a
/// POM or resolve an artifact as an error marker on that `pom.xml`. Those markers
/// are the resolution result; without surfacing them a failed import looks
/// successful while every third-party import stays unresolved (#970). Warnings
/// such as an out-of-date project configuration stay in the Problems view.
enum MavenResolutionProblems {
    static func problems(
        workspaceURL: URL?,
        diagnosticsByURL: [URL: [EditorDiagnostic]]
    ) -> [EditorDiagnostic] {
        guard let workspaceURL else { return [] }
        let rootPath = workspaceURL.standardizedFileURL.path
        return diagnosticsByURL
            .filter { url, _ in
                let file = url.standardizedFileURL
                return file.lastPathComponent.lowercased() == "pom.xml"
                    && file.path.hasPrefix(rootPath + "/")
            }
            .values
            .flatMap { $0 }
            .filter { $0.severity == .error }
            .sorted {
                if $0.fileURL.path != $1.fileURL.path {
                    return $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending
                }
                if $0.line != $1.line { return $0.line < $1.line }
                if $0.utf16Column != $1.utf16Column { return $0.utf16Column < $1.utf16Column }
                return $0.message < $1.message
            }
    }

    /// Stable identity of a problem set, used to notify once per distinct set.
    static func signature(_ problems: [EditorDiagnostic]) -> String {
        problems
            .map { "\($0.fileURL.path)\u{0}\($0.line)\u{0}\($0.utf16Column)\u{0}\($0.message)" }
            .joined(separator: "\n")
    }
}
