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
}
