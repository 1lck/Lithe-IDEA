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
        javaMavenOperations: any JavaMavenOperations,
        runConfigurationOperations: any RunConfigurationOperations,
        executableResolver: (any RunExecutableResolving)? = nil,
        languageProviderCatalog: LanguageProviderCatalog = .standard,
        languageRunProviders: LanguageRunProviderRegistry? = nil,
        languagePackRegistry: LanguagePackRegistry? = nil
    ) {
        let catalog = languagePackRegistry?.catalog ?? languageProviderCatalog
        self.init(
            runtime: runtimeService,
            process: process,
            processFactory: processFactory,
            fileAccess: MacRunFileAccess(storage: fileStorage),
            preferences: MacRunPreferenceStore(store: preferences),
            serverPortParser: javaMavenOperations,
            runConfigurationOperations: runConfigurationOperations,
            executableResolver: executableResolver ?? RunExecutableResolver(runtimeService: runtimeService),
            languageProviderCatalog: catalog,
            languageRunProviders: languagePackRegistry?.runProviders
                ?? languageRunProviders
                ?? .standard(catalog: catalog)
        )
    }
}
