import Combine
import Foundation

/// Latest editor diagnostics for the open workspace. Language-server publish
/// storms stay on this object so the workbench tree does not rebuild.
@MainActor
final class EditorDiagnosticsStore: ObservableObject {
    @Published private(set) var diagnosticsByURL: [URL: [EditorDiagnostic]] = [:]

    func replace(_ diagnostics: [URL: [EditorDiagnostic]]) {
        guard diagnosticsByURL != diagnostics else { return }
        diagnosticsByURL = diagnostics
    }

    func reset() {
        replace([:])
    }

    func diagnostics(for url: URL) -> [EditorDiagnostic] {
        diagnosticsByURL[url.standardizedFileURL] ?? []
    }
}
