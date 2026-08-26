import Foundation

extension AppModel {
    func javaNavigationMarkers(for document: EditorDocument) async -> [JavaImplementationMarker] {
        guard let sessions = languageToolingSessionsIfActive,
              let workspaceURL else { return [] }
        do {
            try sessions.synchronizeLanguageServer(
                for: document.url,
                text: document.text,
                rootURL: workspaceURL
            )
        } catch {
            sessions.recordLanguageServerLog(
                providerID: "java",
                level: .warning,
                message: "Java navigation marker synchronization failed",
                detail: error.localizedDescription
            )
            return []
        }
        return await withCheckedContinuation { continuation in
            do {
                try sessions.javaNavigationMarkers(fileURL: document.url) { result in
                    switch result {
                    case .success(let markers):
                        continuation.resume(returning: markers.map(JavaImplementationMarker.init))
                    case .failure(let error):
                        sessions.recordLanguageServerLog(
                            providerID: "java",
                            level: .warning,
                            message: "Java navigation marker request failed",
                            detail: error.localizedDescription
                        )
                        continuation.resume(returning: [])
                    }
                }
            } catch {
                sessions.recordLanguageServerLog(
                    providerID: "java",
                    level: .warning,
                    message: "Java navigation marker request failed",
                    detail: error.localizedDescription
                )
                continuation.resume(returning: [])
            }
        }
    }
}
