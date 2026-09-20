import Foundation
import LitheLanguageIntelligenceModule

@MainActor
extension AppModel {
    var languageDependencyFeatureIfActive: LanguageDependencyFeatureModel? {
        languageCapability?.dependencies
    }

    func activateLanguageDependencyFeature() async -> LanguageDependencyFeatureModel? {
        if let feature = languageDependencyFeatureIfActive { return feature }
        do {
            let capability: LanguageIntelligenceCapability = try await activateModuleCapability(
                .languageIntelligence,
                moduleID: .languageIntelligence
            )
            bindLanguageIntelligenceCapability(capability)
            return capability.dependencies
        } catch {
            return nil
        }
    }

    func prepareLanguageDependencyFeature(
        workspaceURL: URL,
        files: [URL],
        forceRefresh: Bool
    ) async -> LanguageDependencyFeatureModel? {
        if files.contains(where: { $0.pathExtension.lowercased() == "java" }) {
            switch await services.projectRuntimeService.prepareJavaLanguageServerRuntime() {
            case .ready:
                break
            case .failed, .unprepared:
                return nil
            }
        }
        guard let feature = await activateLanguageDependencyFeature() else { return nil }
        feature.prepare(
            workspaceURL: workspaceURL,
            files: files,
            forceRefresh: forceRefresh
        )
        return feature
    }

    func openLanguageVirtualDocument(_ url: URL, providerID: String) {
        guard let sessions = languageToolingSessionsIfActive else {
            showNotification("Language server is not ready")
            return
        }
        let expectedWorkspace = workspaceURL?.standardizedFileURL
        do {
            try sessions.resolveVirtualDocument(providerID: providerID, uri: url) { [weak self] result in
                guard let self,
                      self.workspaceURL?.standardizedFileURL == expectedWorkspace else { return }
                switch result {
                case .success(let text):
                    self.virtualDocumentProviderIDs[url] = providerID
                    let className = url.path.split(separator: "/").last.map(String.init)
                        ?? "Virtual source"
                    self.documentFeature.openVirtualDocument(
                        url,
                        text: text,
                        displayPath: "Decompiled \(className)"
                    )
                case .failure(let error):
                    self.showNotification(error.localizedDescription)
                }
            }
        } catch {
            showNotification(error.localizedDescription)
        }
    }
}
