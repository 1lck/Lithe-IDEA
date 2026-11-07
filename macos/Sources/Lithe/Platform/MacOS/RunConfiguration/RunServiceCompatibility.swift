import Foundation
import LitheCoreContracts
import LitheExecutionModule

@MainActor
extension LitheExecutionModule.RunService {
    convenience init(
        runtimeService: ProjectRuntimeService,
        process: any StreamingProcess,
        processFactory: @escaping () -> any StreamingProcess,
        fileStorage: any FileStorage,
        preferences: any KeyValueStore,
        runConfigurationOperations: any RunConfigurationOperations,
        executableResolver: (any RunExecutableResolving)? = nil,
        languageProviderCatalog: LanguageProviderCatalog = .standard,
        languageRunProviders: LanguageRunProviderRegistry? = nil,
        languagePackRegistry: LanguagePackRegistry? = nil
    ) {
        let catalog = languagePackRegistry?.catalog ?? languageProviderCatalog
        self.init(
            process: process,
            processFactory: processFactory,
            fileAccess: MacRunFileAccess(storage: fileStorage),
            preferences: MacRunPreferenceStore(store: preferences),
            runConfigurationOperations: runConfigurationOperations,
            executableResolver: executableResolver ?? RunExecutableResolver(runtimeService: runtimeService),
            languageProviderCatalog: catalog,
            languageRunProviders: languagePackRegistry?.runProviders
                ?? languageRunProviders
                ?? .standard(catalog: catalog)
        )
    }
}
