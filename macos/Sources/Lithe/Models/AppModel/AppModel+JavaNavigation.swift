import LitheModuleAPI
import Foundation

extension AppModel {
    func javaNavigationMarkers(for document: EditorDocument) async -> [JavaImplementationMarker] {
        guard !languageToolingFeature.isDisabled("java"),
              let sessions = languageToolingSessionsIfActive,
              let workspaceURL else { return [] }
        do {
            try sessions.synchronizeLanguageServer(
                for: document.url,
                text: document.text,
                rootURL: workspaceURL
            )
        } catch {
            sessions.recordHostFailure(providerID: "java", stage: "navigationSync", error: error)
            return []
        }
        return await withCheckedContinuation { continuation in
            do {
                try sessions.javaNavigationMarkers(fileURL: document.url) { result in
                    switch result {
                    case .success(let markers):
                        continuation.resume(returning: markers.map(JavaImplementationMarker.init))
                    case .failure(let error):
                        sessions.recordHostFailure(providerID: "java", stage: "navigation", error: error)
                        continuation.resume(returning: [])
                    }
                }
            } catch {
                sessions.recordHostFailure(providerID: "java", stage: "navigation", error: error)
                continuation.resume(returning: [])
            }
        }
    }
}
