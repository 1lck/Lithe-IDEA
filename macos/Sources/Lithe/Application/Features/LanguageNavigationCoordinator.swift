import Combine
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

struct LanguageNavigationRequest {
    let method: String
    let fileURL: URL
    let text: String
    let position: LanguageServerPosition
    let rootURL: URL
}

/// Owns the in-flight navigation request and converts language-server
/// locations into application navigation results.
///
/// The state is held here rather than on the application aggregate so a
/// superseded request cannot publish over a newer one: every completion handler
/// checks `owns(operationID)` before writing, and only the coordinator can
/// mint an operation ID.
/// Where a language-server jump may go. Targets outside the workspace open
/// read-only, and only when they are sources of the originating language.
enum ExternalNavigationDecision: Equatable, Sendable {
    case workspace
    case externalReadOnly
    case rejected
}

@MainActor
final class LanguageNavigationCoordinator: ObservableObject {
    struct ImplementationFallbackDecision {
        let shouldRequestImplementations: Bool
        let originalValues: [LanguageServerLocation]
    }

    @Published private(set) var state: LanguageNavigationState = .idle

    private let notify: @MainActor (String) -> Void

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    /// Clears any in-flight or displayed navigation, used when the results are
    /// dismissed or the workspace changes.
    func reset() {
        state = .idle
    }

    func navigate(
        to location: EditorNavigationLocation,
        recordsHistory: Bool,
        providerID: String?,
        sessions: LanguageToolingSessionManager?,
        recordHistory: @escaping @MainActor (EditorNavigationLocation) -> Void,
        openFile: @escaping @MainActor (EditorNavigationLocation) -> Void,
        openVirtualDocument: @escaping @MainActor (URL, String, String?) -> Void,
        setTarget: @escaping @MainActor (EditorNavigationLocation) -> Void,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        if location.url.isFileURL {
            if recordsHistory { recordHistory(location) }
            openFile(location)
            setTarget(location)
            return
        }
        guard let providerID = location.virtualProviderID ?? providerID else {
            notify("The virtual source provider is no longer available")
            onFailure?()
            return
        }
        guard let sessions else {
            notify("The language source provider is not running")
            onFailure?()
            return
        }
        let operationID = begin(providerID: providerID, kind: state.kind)
        do {
            try sessions.resolveVirtualDocument(providerID: providerID, uri: location.url) { [weak self] result in
                guard let self, self.owns(operationID) else { return }
                self.state = .idle
                switch result {
                case .success(let text):
                    if recordsHistory { recordHistory(location) }
                    openVirtualDocument(location.url, text, location.displayPath)
                    setTarget(location)
                case .failure(let error):
                    onFailure?()
                    self.notify(error.localizedDescription)
                }
            }
        } catch {
            if owns(operationID) {
                state = .idle
            }
            onFailure?()
            notify(error.localizedDescription)
        }
    }

    func handleResult(
        _ values: [LanguageServerLocation],
        providerID: String?,
        kind: LanguageNavigationResultKind,
        onEmpty: @escaping @MainActor () -> Void,
        onResults: @escaping @MainActor ([LanguageNavigationLocation]) -> Void
    ) {
        guard let resolved = resultState(from: values, providerID: providerID, kind: kind) else {
            state = .idle
            onEmpty()
            return
        }
        state = resolved
        onResults(resolved.locations)
    }

    /// Reports a failed request, clearing the state only when the failing
    /// request is still the current one.
    func fail(_ operationID: UUID, message: String) {
        if owns(operationID) {
            state = .idle
        }
        notify(message)
    }

    func implementationFallbackDecision(
        method: String,
        kind: LanguageNavigationResultKind,
        values: [LanguageServerLocation],
        documentURL: URL,
        supportsImplementation: Bool
    ) -> ImplementationFallbackDecision {
        let shouldFallback = method == "textDocument/definition"
            && kind == .definitions
            && values.count == 1
            && values[0].url.standardizedFileURL == documentURL.standardizedFileURL
            && supportsImplementation
        return ImplementationFallbackDecision(
            shouldRequestImplementations: shouldFallback,
            originalValues: values
        )
    }

    func owns(_ operationID: UUID) -> Bool {
        state.owns(operationID: operationID)
    }

    func request(
        method: String,
        document: EditorDocument,
        caret: EditorCaret,
        workspaceURL: URL
    ) -> LanguageNavigationRequest {
        LanguageNavigationRequest(
            method: method,
            fileURL: document.url,
            text: document.text,
            position: LanguageServerPosition(
                line: max(0, caret.line),
                utf16Column: max(0, caret.utf16Column)
            ),
            rootURL: workspaceURL
        )
    }

    /// Starts a request and publishes its loading state, returning the ID that
    /// later results must present to write back.
    @discardableResult
    func begin(
        providerID: String,
        kind: LanguageNavigationResultKind
    ) -> UUID {
        let operationID = UUID()
        state = .loading(operationID: operationID, providerID: providerID, kind: kind)
        return operationID
    }

    func results(
        providerID: String?,
        kind: LanguageNavigationResultKind,
        locations: [LanguageNavigationLocation]
    ) -> LanguageNavigationState {
        .results(providerID: providerID, kind: kind, locations: locations)
    }

    func resultState(
        from values: [LanguageServerLocation],
        providerID: String?,
        kind: LanguageNavigationResultKind
    ) -> LanguageNavigationState? {
        let locations = locations(from: values)
        guard !locations.isEmpty else { return nil }
        return results(providerID: providerID, kind: kind, locations: locations)
    }

    func locations(
        from values: [LanguageServerLocation]
    ) -> [LanguageNavigationLocation] {
        values.map {
            LanguageNavigationLocation(
                url: $0.url,
                line: $0.range.start.line,
                utf16Column: $0.range.start.utf16Column,
                isReadOnly: $0.isReadOnly,
                displayPath: $0.displayPath
            )
        }
    }

    /// Classifies a jump target by both the path it is opened under and its
    /// real location. Only a target whose path and resolved path are both
    /// inside the workspace is a workspace file: an in-workspace symlink to
    /// the outside must not skip the source-file check or the read-only rule,
    /// and an outside symlink to a workspace file is opened under its outside
    /// path, which the document layer only accepts as an external read-only
    /// document.
    nonisolated static func externalNavigationDecision(
        for url: URL,
        workspaceURL: URL?,
        languageID: String?,
        languageOf: (URL) -> String?
    ) -> ExternalNavigationDecision {
        guard url.isFileURL, let workspaceURL else { return .workspace }
        let roots = [workspaceURL.standardizedFileURL, workspaceURL.resolvingSymlinksInPath()]
            .map(\.path)
        let opensInside = roots.contains { url.standardizedFileURL.path.hasPrefix($0 + "/") }
        let resolvesInside = url.resolvingSymlinksInPath().path
            .hasPrefix(workspaceURL.resolvingSymlinksInPath().path + "/")
        if opensInside && resolvesInside {
            return .workspace
        }
        return allowsExternalSource(url, languageID: languageID, languageOf: languageOf)
            ? .externalReadOnly
            : .rejected
    }

    /// A jump may leave the workspace only into a source file of the language
    /// that produced it: a Go definition opens `.go` files, a PHP definition
    /// `.php` files. Configuration, credentials, and other files a server
    /// might point to stay closed, and a symlink must resolve to a file that
    /// passes the same check. Such files are always opened read-only.
    nonisolated static func allowsExternalSource(
        _ url: URL,
        languageID: String?,
        languageOf: (URL) -> String?
    ) -> Bool {
        guard let languageID, url.isFileURL else { return false }
        return [url, url.resolvingSymlinksInPath()].allSatisfy { languageOf($0) == languageID }
    }

    func editorLocation(
        for location: LanguageNavigationLocation,
        virtualProviderID: String?
    ) -> EditorNavigationLocation {
        EditorNavigationLocation(
            url: location.url,
            line: location.line,
            utf16Column: location.utf16Column,
            isReadOnly: location.isReadOnly,
            displayPath: location.displayPath,
            virtualProviderID: virtualProviderID
        )
    }
}
