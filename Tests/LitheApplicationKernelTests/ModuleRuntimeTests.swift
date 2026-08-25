import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Testing

@MainActor
struct ModuleRuntimeTests {
    @Test
    func disabledModuleDoesNotInvokeFactory() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(
            testFactory(
                id: .database,
                defaultState: .disabled,
                recorder: recorder
            )
        )

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.database)) {
            _ = try await runtime.activate(.database)
        }
        #expect(recorder.factoryCalls == [])
        #expect(try runtime.snapshot(for: .database).state == .disabled)
        #expect(try !runtime.snapshot(for: .database).isInstantiated)
    }

    @Test
    func interruptedActivationIsQuarantinedWithoutInvokingFactory() async throws {
        let recorder = ModuleTestRecorder()
        let recoveryStore = TestModuleRecoveryStore(pendingActivation: .search)
        let runtime = ModuleRuntime(recoveryStore: recoveryStore)
        try runtime.register(testFactory(id: .search, recorder: recorder))

        await #expect(throws: ModuleRuntimeError.moduleQuarantined(.search)) {
            _ = try await runtime.activate(.search)
        }

        let snapshot = try runtime.snapshot(for: .search)
        #expect(snapshot.state == .disabled)
        #expect(snapshot.isQuarantined)
        #expect(!snapshot.isInstantiated)
        #expect(recorder.factoryCalls.isEmpty)
        #expect(recoveryStore.pendingActivation() == nil)
    }

    @Test
    func everyInterruptedConcurrentActivationIsQuarantined() async throws {
        let recorder = ModuleTestRecorder()
        let recoveryStore = TestModuleRecoveryStore(
            pendingActivations: [.search, .localHistory]
        )
        let runtime = ModuleRuntime(recoveryStore: recoveryStore)
        try runtime.register(testFactory(id: .search, recorder: recorder))
        try runtime.register(testFactory(id: .localHistory, recorder: recorder))

        await #expect(throws: ModuleRuntimeError.moduleQuarantined(.search)) {
            _ = try await runtime.activate(.search)
        }
        await #expect(throws: ModuleRuntimeError.moduleQuarantined(.localHistory)) {
            _ = try await runtime.activate(.localHistory)
        }

        #expect(recoveryStore.pendingActivations().isEmpty)
        #expect(recoveryStore.isQuarantined(.search))
        #expect(recoveryStore.isQuarantined(.localHistory))
        #expect(recorder.factoryCalls.isEmpty)
    }

    @Test
    func quarantinedModuleCanBeExplicitlyReEnabled() async throws {
        let recorder = ModuleTestRecorder()
        let recoveryStore = TestModuleRecoveryStore(pendingActivation: .search)
        let runtime = ModuleRuntime(recoveryStore: recoveryStore)
        try runtime.register(testFactory(id: .search, recorder: recorder))

        try await runtime.setEnabled(true, for: .search)
        _ = try await runtime.activate(.search)

        let snapshot = try runtime.snapshot(for: .search)
        #expect(snapshot.state == .active)
        #expect(!snapshot.isQuarantined)
        #expect(recorder.factoryCalls == [.search])
        #expect(!recoveryStore.isQuarantined(.search))
        #expect(recoveryStore.pendingActivation() == nil)
    }

    @Test
    func safeModeStartsRequiredModuleWithoutInvokingOptionalFactory() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime(launchMode: .safeMode)
        let requiredManifest = ModuleManifest(
            id: .workspace,
            displayName: "Workspace",
            scope: .workspace,
            activationPolicy: .eager,
            isRequired: true
        )
        try runtime.register(ModuleFactory(manifest: requiredManifest) {
            recorder.factoryCalls.append(.workspace)
            return TestModule(manifest: requiredManifest, recorder: recorder)
        })
        try runtime.register(testFactory(id: .search, recorder: recorder))

        try await runtime.startEagerModules()
        await #expect(throws: ModuleRuntimeError.optionalModuleUnavailableInSafeMode(.search)) {
            _ = try await runtime.activate(.search)
        }

        #expect(recorder.factoryCalls == [.workspace])
        #expect(try runtime.snapshot(for: .workspace).state == .active)
        #expect(try runtime.snapshot(for: .search).isSuppressedBySafeMode)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
    }

    @Test
    func optionalActivationMarkerWrapsFactoryAndClearsAfterSuccess() async throws {
        let recorder = ModuleTestRecorder()
        let recoveryStore = TestModuleRecoveryStore()
        let runtime = ModuleRuntime(recoveryStore: recoveryStore)
        let manifest = ModuleManifest(id: .search, displayName: "Search", scope: .workspace)
        try runtime.register(ModuleFactory(manifest: manifest) {
            #expect(recoveryStore.pendingActivation() == .search)
            recorder.factoryCalls.append(.search)
            return TestModule(manifest: manifest, recorder: recorder)
        })

        _ = try await runtime.activate(.search)

        #expect(recoveryStore.pendingActivation() == nil)
    }

    @Test
    func dependenciesActivateBeforeDependentModule() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(id: .workspace, recorder: recorder))
        try runtime.register(testFactory(
            id: .search,
            dependencies: [.module(.workspace)],
            recorder: recorder
        ))

        _ = try await runtime.activate(.search)

        #expect(recorder.activationOrder == [.workspace, .search])
        #expect(try runtime.snapshot(for: .workspace).state == .active)
        #expect(try runtime.snapshot(for: .search).state == .active)
    }

    @Test
    func capabilityDependencyActivatesItsProvider() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let capability = ModuleCapabilityID("test.workspace")
        try runtime.register(testFactory(
            id: .workspace,
            capabilities: [capability],
            recorder: recorder
        ))
        try runtime.register(testFactory(
            id: .git,
            dependencies: [.capability(capability)],
            recorder: recorder
        ))

        _ = try await runtime.activate(.git)

        #expect(recorder.activationOrder == [.workspace, .git])
        #expect(runtime.capability(capability) != nil)
    }

    @Test
    func activeLeasePreventsSleepWithObservableReason() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(id: .terminal, recorder: recorder))
        let module = try #require(try await runtime.activate(.terminal) as? TestModule)
        let lease = try #require(module.lease)

        await #expect(throws: ModuleRuntimeError.activeLeasesPreventSleep(
            module: .terminal,
            reasons: ["foreground command"]
        )) {
            try await runtime.sleep(.terminal)
        }
        #expect(try runtime.snapshot(for: .terminal).state == .sleepBlocked(reason: "foreground command"))

        lease.release()
        try await runtime.sleep(.terminal)
        #expect(try runtime.snapshot(for: .terminal).state == .sleeping)
    }

    @Test
    func activeDependentPreventsProviderSleepUntilDependentStops() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(id: .languageIntelligence, recorder: recorder))
        try runtime.register(testFactory(
            id: .debug,
            dependencies: [.module(.languageIntelligence)],
            recorder: recorder
        ))
        _ = try await runtime.activate(.debug)

        await #expect(throws: ModuleRuntimeError.activeDependentsPreventSleep(
            module: .languageIntelligence,
            dependents: [.debug]
        )) {
            try await runtime.sleep(.languageIntelligence)
        }
        #expect(try runtime.snapshot(for: .languageIntelligence).state == .sleepBlocked(
            reason: "Active dependents: dev.lithe.debug"
        ))

        try await runtime.sleep(.debug)
        try await runtime.sleep(.languageIntelligence)
        #expect(try runtime.snapshot(for: .languageIntelligence).state == .sleeping)
    }

    @Test
    func sleepStopsResourcesReleasesInstanceAndWakeReconstructsIt() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(id: .database, recorder: recorder))

        let firstReference = WeakReference<TestModule>()
        var first: TestModule? = try #require(try await runtime.activate(.database) as? TestModule)
        firstReference.value = first
        #expect(first?.resource?.isModuleResourceActive == true)
        first = nil
        try await runtime.sleep(.database)

        #expect(recorder.resourceStops == [.database])
        #expect(try runtime.snapshot(for: .database).state == .sleeping)
        #expect(try !runtime.snapshot(for: .database).isInstantiated)
        #expect(firstReference.value == nil)

        let second = try #require(try await runtime.activate(.database) as? TestModule)
        #expect(recorder.factoryCalls == [.database, .database])
        #expect(second !== firstReference.value)
        #expect(try runtime.snapshot(for: .database).state == .active)
    }

    @Test
    func activeResourceCannotUnregisterBeforeItStops() async {
        let recorder = ModuleTestRecorder()
        let scope = ModuleResourceScope(moduleID: .database)
        let resource = TestResource(moduleID: .database, recorder: recorder)
        let resourceID = scope.register(resource)

        scope.unregisterResource(id: resourceID)
        #expect(scope.resourceSnapshots().count == 1)
        #expect(scope.activity.activeResourceCount == 1)

        await scope.stopAllResources()
        scope.unregisterResource(id: resourceID)
        #expect(scope.resourceSnapshots().isEmpty)
        #expect(scope.activity.activeResourceCount == 0)
    }

    @Test
    func shutdownAllStopsEveryInstantiatedModule() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(id: .terminal, recorder: recorder))
        try runtime.register(testFactory(id: .database, recorder: recorder))
        _ = try await runtime.activate(.terminal)
        _ = try await runtime.activate(.database)

        await runtime.shutdownAll()

        #expect(Set(recorder.shutdowns) == Set([.terminal, .database]))
        #expect(runtime.snapshots().allSatisfy { !$0.isInstantiated })
        #expect(runtime.snapshots().allSatisfy { $0.activity.activeResourceCount == 0 })
    }

    @Test
    func duplicateCapabilityProvidersFailGraphValidation() throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let capability = ModuleCapabilityID("test.duplicate")
        try runtime.register(testFactory(id: .git, capabilities: [capability], recorder: recorder))
        try runtime.register(testFactory(id: .search, capabilities: [capability], recorder: recorder))

        #expect(throws: ModuleRuntimeError.capabilityCollision(
            capability: capability,
            providers: [.git, .search]
        )) {
            try runtime.validateGraph()
        }
    }

    @Test
    func builtInRegistryAcceptsTheCanonicalManifestCatalog() throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let registry = ModuleRegistry(runtime: runtime)

        let manifests = BuiltInPluginCatalog.manifests
            .flatMap(\.modules)
            .map(\.manifest)
        for manifest in manifests {
            try registry.register(ModuleFactory(
                manifest: manifest,
                contributions: BuiltInModuleCatalog.contributions(for: manifest.id)
            ) {
                TestModule(manifest: manifest, recorder: recorder)
            })
        }

        try registry.validate()
        #expect(registry.registeredModuleIDs == manifests.map(\.id).sorted())
    }

    @Test
    func builtInRegistryRejectsManifestDrift() throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let registry = ModuleRegistry(runtime: runtime)

        let manifests = BuiltInPluginCatalog.manifests
            .flatMap(\.modules)
            .map(\.manifest)
        for manifest in manifests {
            let registeredManifest: ModuleManifest
            if manifest.id == .database {
                registeredManifest = ModuleManifest(
                    id: manifest.id,
                    displayName: manifest.displayName,
                    scope: manifest.scope,
                    defaultState: .enabled,
                    activationPolicy: manifest.activationPolicy,
                    sleepPolicy: manifest.sleepPolicy,
                    dependencies: manifest.dependencies,
                    providedCapabilities: manifest.providedCapabilities,
                    isRequired: manifest.isRequired
                )
            } else {
                registeredManifest = manifest
            }
            try registry.register(ModuleFactory(
                manifest: registeredManifest,
                contributions: BuiltInModuleCatalog.contributions(for: manifest.id)
            ) {
                TestModule(manifest: registeredManifest, recorder: recorder)
            })
        }

        #expect(throws: PluginCatalogError.moduleFactoryMismatch(
            plugin: BuiltInPluginCatalog.manifest(forModule: .database)!.id,
            module: .database
        )) {
            try registry.validate()
        }
    }

    @Test
    func registryAllowsAnUninstalledOptionalOfficialPlugin() throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let workspacePlugin = try #require(BuiltInPluginCatalog.manifest(forModule: .workspace))
        let registry = ModuleRegistry(runtime: runtime, pluginManifests: [workspacePlugin])
        let workspace = try #require(BuiltInModuleCatalog.manifest(for: .workspace))
        try registry.register(ModuleFactory(manifest: workspace) {
            TestModule(manifest: workspace, recorder: recorder)
        })

        try registry.validate()

        #expect(registry.registeredModuleIDs == [.workspace])
        #expect(recorder.factoryCalls.isEmpty)
    }

    @Test
    func staticPluginManifestsRoundTripWithoutInvokingFactories() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(BuiltInPluginCatalog.manifests)
        let decoded = try JSONDecoder().decode([PluginManifest].self, from: data)

        let catalog = try ValidatedPluginCatalog(
            manifests: decoded,
            hostVersion: BuiltInPluginCatalog.hostVersion
        )

        #expect(decoded == BuiltInPluginCatalog.manifests)
        #expect(catalog.modules.keys.sorted() == BuiltInModuleCatalog.ids)
    }

    @Test
    func aiAssistanceIsBuiltInRatherThanAnOfficialDownload() {
        #expect(BuiltInPluginCatalog.manifest(forModule: .aiAssistance) != nil)
        #expect(OfficialPluginCatalog.manifest(forModule: .aiAssistance) == nil)
    }

    @Test
    func languageSupportManifestBindsIndependentModulesWithoutLoadingCode() throws {
        let lsp = ModuleManifest(
            id: ModuleID("dev.example.go.language-server"),
            displayName: "Go Language Server",
            scope: .workspace
        )
        let execution = ModuleManifest(
            id: ModuleID("dev.example.go.execution"),
            displayName: "Go Execution",
            scope: .workspace
        )
        let manifest = PluginManifest(
            id: PluginID("dev.example.go-support"),
            displayName: "Go Support",
            version: BuiltInPluginCatalog.hostVersion,
            hostCompatibility: PluginHostCompatibility(
                minimum: BuiltInPluginCatalog.hostVersion,
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: BuiltInPluginCatalog.vendor,
            entrypoint: .builtIn(targetName: "ExampleGoSupport"),
            modules: [
                PluginModuleDeclaration(manifest: lsp),
                PluginModuleDeclaration(manifest: execution)
            ],
            languageSupports: [LanguageSupportDeclaration(
                id: "go",
                displayName: "Go",
                fileExtensions: [".GO", "go"],
                projectFileNames: ["go.mod"],
                languageServerModuleID: lsp.id,
                executionModuleID: execution.id,
                testingModuleID: execution.id
            )]
        )

        let catalog = try ValidatedPluginCatalog(
            manifests: [manifest],
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
        let support = try #require(catalog.manifests.first?.languageSupports?.first)
        #expect(support.fileExtensions == ["go"])
        #expect(support.projectFileNames == ["go.mod"])
        #expect(support.languageServerModuleID != support.executionModuleID)
        #expect(support.testingModuleID == support.executionModuleID)
        #expect(catalog.languageSupport(for: URL(fileURLWithPath: "/workspace/main.go"))?.pluginID == manifest.id)
        #expect(catalog.languageSupports(
            recognizingProjectFileNames: ["README.md", "go.mod"]
        ).map(\.pluginID) == [manifest.id])
    }

    @Test
    func languageSupportCannotReferenceAnotherPluginsModule() throws {
        let owned = ModuleManifest(
            id: ModuleID("dev.example.go.language-server"),
            displayName: "Go Language Server",
            scope: .workspace
        )
        let foreignModuleID = ModuleID("dev.example.foreign.execution")
        let manifest = PluginManifest(
            id: PluginID("dev.example.go-support"),
            displayName: "Go Support",
            version: BuiltInPluginCatalog.hostVersion,
            hostCompatibility: PluginHostCompatibility(minimum: BuiltInPluginCatalog.hostVersion),
            vendor: BuiltInPluginCatalog.vendor,
            entrypoint: .builtIn(targetName: "ExampleGoSupport"),
            modules: [PluginModuleDeclaration(manifest: owned)],
            languageSupports: [LanguageSupportDeclaration(
                id: "go",
                displayName: "Go",
                projectFileNames: ["go.mod"],
                languageServerModuleID: owned.id,
                executionModuleID: foreignModuleID
            )]
        )

        #expect(throws: PluginCatalogError.invalidLanguageSupport(
            plugin: manifest.id,
            languageID: "go"
        )) {
            _ = try ValidatedPluginCatalog(
                manifests: [manifest],
                hostVersion: BuiltInPluginCatalog.hostVersion
            )
        }
    }

    @Test
    func incompatiblePluginIsRejectedBeforeFactoryRegistration() throws {
        let workspacePlugin = try #require(BuiltInPluginCatalog.manifest(forModule: .workspace))
        let incompatible = PluginManifest(
            id: workspacePlugin.id,
            displayName: workspacePlugin.displayName,
            version: workspacePlugin.version,
            hostCompatibility: PluginHostCompatibility(
                minimum: PluginVersion(major: 1, minor: 0, patch: 0)
            ),
            vendor: workspacePlugin.vendor,
            entrypoint: workspacePlugin.entrypoint,
            modules: workspacePlugin.modules
        )

        #expect(throws: PluginCatalogError.incompatibleHost(
            plugin: incompatible.id,
            hostVersion: BuiltInPluginCatalog.hostVersion
        )) {
            _ = try ValidatedPluginCatalog(
                manifests: [incompatible],
                hostVersion: BuiltInPluginCatalog.hostVersion
            )
        }
    }

    @Test
    func failedActivationStopsResourcesAndReleasesInstance() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let manifest = ModuleManifest(id: .search, displayName: "Search", scope: .workspace)
        let moduleReference = WeakReference<FailingActivationModule>()
        try runtime.register(ModuleFactory(manifest: manifest) {
            let module = FailingActivationModule(manifest: manifest, recorder: recorder)
            moduleReference.value = module
            return module
        })

        await #expect(throws: TestActivationError.failed) {
            _ = try await runtime.activate(.search)
        }

        #expect(recorder.shutdowns == [.search])
        #expect(recorder.resourceStops == [.search])
        #expect(try runtime.snapshot(for: .search).activity.activeResourceCount == 0)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
        #expect(moduleReference.value == nil)
    }

    @Test
    func missingDeclaredCapabilityRollsBackActivation() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let capability = ModuleCapabilityID("test.missing-export")
        let manifest = ModuleManifest(
            id: .search,
            displayName: "Search",
            scope: .workspace,
            providedCapabilities: [capability]
        )
        try runtime.register(ModuleFactory(manifest: manifest) {
            MissingCapabilityModule(manifest: manifest, recorder: recorder)
        })

        await #expect(throws: ModuleRuntimeError.missingExportedCapability(
            module: .search,
            capability: capability
        )) {
            _ = try await runtime.activate(.search)
        }

        #expect(recorder.shutdowns == [.search])
        #expect(recorder.resourceStops == [.search])
        #expect(runtime.capability(capability) == nil)
        #expect(try runtime.snapshot(for: .search).activity.activeResourceCount == 0)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
    }

    @Test
    func dependencyCyclesFailGraphValidation() throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(
            id: .git,
            dependencies: [.module(.search)],
            recorder: recorder
        ))
        try runtime.register(testFactory(
            id: .search,
            dependencies: [.module(.git)],
            recorder: recorder
        ))

        #expect(throws: ModuleRuntimeError.dependencyCycle([.git, .search, .git])) {
            try runtime.validateGraph()
        }
    }

    @Test
    func requiredModuleCannotBeDisabled() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let manifest = ModuleManifest(
            id: .workspace,
            displayName: "Workspace",
            scope: .workspace,
            isRequired: true
        )
        try runtime.register(ModuleFactory(manifest: manifest) {
            TestModule(manifest: manifest, recorder: recorder)
        })

        await #expect(throws: ModuleRuntimeError.requiredModuleCannotBeDisabled(.workspace)) {
            try await runtime.setEnabled(false, for: .workspace)
        }
        #expect(try runtime.snapshot(for: .workspace).state == .inactive)
    }

    @Test
    func enabledDependentPreventsProviderDisable() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(testFactory(id: .workspace, recorder: recorder))
        try runtime.register(testFactory(
            id: .search,
            dependencies: [.module(.workspace)],
            recorder: recorder
        ))

        await #expect(throws: ModuleRuntimeError.enabledDependentsPreventDisable(
            module: .workspace,
            dependents: [.search]
        )) {
            try await runtime.setEnabled(false, for: .workspace)
        }
    }

    @Test
    func contributionsExistOnlyWhileModuleIsActive() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let contribution = ModuleContribution(
            id: "test.tool-window",
            kind: .toolWindow,
            title: "Test"
        )
        let manifest = ModuleManifest(id: .search, displayName: "Search", scope: .workspace)
        try runtime.register(ModuleFactory(manifest: manifest, contributions: [contribution]) {
            TestModule(manifest: manifest, recorder: recorder, contributions: [contribution])
        })

        #expect(runtime.contributions().isEmpty)
        _ = try await runtime.activate(.search)
        #expect(runtime.contributions()[.search] == [contribution])
        try await runtime.sleep(.search)
        #expect(runtime.contributions().isEmpty)
    }

    @Test
    func availableContributionDoesNotInstantiateAnOnDemandModule() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let contribution = ModuleContribution(
            id: "test.lazy-tool-window",
            kind: .toolWindow,
            title: "Lazy",
            actionID: "test.activate",
            rendererID: "test.lazy"
        )
        let manifest = ModuleManifest(id: .search, displayName: "Search", scope: .workspace)
        try runtime.register(ModuleFactory(
            manifest: manifest,
            contributions: [contribution]
        ) {
            recorder.factoryCalls.append(.search)
            return TestModule(manifest: manifest, recorder: recorder)
        })

        #expect(runtime.availableContributions()[.search] == [contribution])
        #expect(recorder.factoryCalls.isEmpty)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)

        try await runtime.setEnabled(false, for: .search)
        #expect(runtime.availableContributions()[.search] == nil)
        #expect(recorder.factoryCalls.isEmpty)
    }

    @Test
    func idleModuleWithoutResourcesSleepsAfterItsPolicyInterval() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let manifest = ModuleManifest(
            id: .search,
            displayName: "Search",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 60)
        )
        try runtime.register(ModuleFactory(manifest: manifest) {
            TestModule(manifest: manifest, recorder: recorder, registersResource: false)
        })
        _ = try await runtime.activate(.search)
        try runtime.markIdle(.search)
        let lastActivity = try #require(try runtime.snapshot(for: .search).activity.lastActivityAt)

        await runtime.evaluateIdleModules(now: lastActivity.addingTimeInterval(59))
        #expect(try runtime.snapshot(for: .search).state == .idle)
        await runtime.evaluateIdleModules(now: lastActivity.addingTimeInterval(61))
        #expect(try runtime.snapshot(for: .search).state == .sleeping)
    }

    @Test
    func disablingActiveModuleReleasesInstanceCapabilityAndContribution() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let capability = ModuleCapabilityID("test.disable")
        let contribution = ModuleContribution(id: "test.disable.tool", kind: .toolWindow, title: "Test")
        let manifest = ModuleManifest(
            id: .search,
            displayName: "Search",
            scope: .workspace,
            providedCapabilities: [capability]
        )
        try runtime.register(ModuleFactory(manifest: manifest, contributions: [contribution]) {
            recorder.factoryCalls.append(.search)
            return TestModule(manifest: manifest, recorder: recorder, contributions: [contribution])
        })
        _ = try await runtime.activateCapability(capability)

        try await runtime.setEnabled(false, for: .search)

        #expect(try runtime.snapshot(for: .search).state == .disabled)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
        #expect(runtime.capability(capability) == nil)
        #expect(runtime.contributions().isEmpty)
        await #expect(throws: ModuleRuntimeError.moduleDisabled(.search)) {
            _ = try await runtime.activateCapability(capability)
        }
        #expect(recorder.factoryCalls == [.search])
    }

    @Test
    func instanceContributionDriftRollsBackActivation() async throws {
        let recorder = ModuleTestRecorder()
        let runtime = ModuleRuntime()
        let staticContribution = ModuleContribution(
            id: "test.static",
            kind: .toolWindow,
            title: "Static"
        )
        let instanceContribution = ModuleContribution(
            id: "test.instance",
            kind: .toolWindow,
            title: "Instance"
        )
        let manifest = ModuleManifest(id: .search, displayName: "Search", scope: .workspace)
        try runtime.register(ModuleFactory(
            manifest: manifest,
            contributions: [staticContribution]
        ) {
            recorder.factoryCalls.append(.search)
            return TestModule(
                manifest: manifest,
                recorder: recorder,
                contributions: [instanceContribution]
            )
        })

        await #expect(throws: ModuleRuntimeError.contributionCatalogMismatch(.search)) {
            _ = try await runtime.activate(.search)
        }

        #expect(recorder.shutdowns == [.search])
        #expect(recorder.resourceStops == [.search])
        #expect(runtime.contributions().isEmpty)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
        #expect(try runtime.snapshot(for: .search).activity.activeResourceCount == 0)
    }

    private func testFactory(
        id: ModuleID,
        defaultState: ModuleDefaultState = .enabled,
        dependencies: Set<ModuleDependency> = [],
        capabilities: Set<ModuleCapabilityID> = [],
        recorder: ModuleTestRecorder
    ) -> ModuleFactory {
        let manifest = ModuleManifest(
            id: id,
            displayName: id.rawValue,
            scope: .workspace,
            defaultState: defaultState,
            dependencies: dependencies,
            providedCapabilities: capabilities
        )
        return ModuleFactory(manifest: manifest) {
            recorder.factoryCalls.append(id)
            return TestModule(manifest: manifest, recorder: recorder)
        }
    }
}

@MainActor
private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
}

@MainActor
private final class ModuleTestRecorder {
    var factoryCalls: [ModuleID] = []
    var activationOrder: [ModuleID] = []
    var shutdowns: [ModuleID] = []
    var resourceStops: [ModuleID] = []
}

private final class TestModuleRecoveryStore: ModuleRecoveryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<ModuleID>
    private var quarantined: Set<ModuleID> = []

    init(pendingActivation: ModuleID? = nil) {
        pending = Set(pendingActivation.map { [$0] } ?? [])
    }

    init(pendingActivations: [ModuleID]) {
        pending = Set(pendingActivations)
    }

    func pendingActivation() -> ModuleID? {
        lock.lock(); defer { lock.unlock() }
        return pending.sorted().first
    }

    func setPendingActivation(_ moduleID: ModuleID?) {
        lock.lock(); defer { lock.unlock() }
        pending = Set(moduleID.map { [$0] } ?? [])
    }

    func pendingActivations() -> [ModuleID] {
        lock.lock(); defer { lock.unlock() }
        return pending.sorted()
    }

    func setPendingActivations(_ moduleIDs: [ModuleID]) {
        lock.lock(); defer { lock.unlock() }
        pending = Set(moduleIDs)
    }

    func isQuarantined(_ moduleID: ModuleID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return quarantined.contains(moduleID)
    }

    func setQuarantined(_ isQuarantined: Bool, for moduleID: ModuleID) {
        lock.lock(); defer { lock.unlock() }
        if isQuarantined {
            quarantined.insert(moduleID)
        } else {
            quarantined.remove(moduleID)
        }
    }
}

@MainActor
private final class TestModule: LitheModule {
    let manifest: ModuleManifest
    private let recorder: ModuleTestRecorder
    private(set) var resource: TestResource?
    private(set) var lease: ModuleLease?
    private let declaredContributions: [ModuleContribution]
    private let registersResource: Bool

    init(
        manifest: ModuleManifest,
        recorder: ModuleTestRecorder,
        contributions: [ModuleContribution] = [],
        registersResource: Bool = true
    ) {
        self.manifest = manifest
        self.recorder = recorder
        declaredContributions = contributions
        self.registersResource = registersResource
    }

    func activate(context: ModuleContext) async throws {
        recorder.activationOrder.append(manifest.id)
        if registersResource {
            let resource = TestResource(moduleID: manifest.id, recorder: recorder)
            self.resource = resource
            context.resources.register(resource)
        }
        if manifest.id == .terminal {
            lease = context.leases.acquireLease(reason: "foreground command")
        }
    }

    func prepareForSleep() async throws {}

    func sleep() async {
        resource = nil
        lease = nil
    }

    func shutdown() async {
        recorder.shutdowns.append(manifest.id)
        lease?.release()
        lease = nil
    }

    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        Dictionary(uniqueKeysWithValues: manifest.providedCapabilities.map { ($0, TestCapability()) })
    }

    func contributions() -> [ModuleContribution] { declaredContributions }
}

@MainActor
private final class TestResource: ModuleResource {
    let moduleID: ModuleID
    let recorder: ModuleTestRecorder
    private(set) var isModuleResourceActive = true
    var moduleResourceKind: String { "test.\(moduleID.rawValue)" }

    init(moduleID: ModuleID, recorder: ModuleTestRecorder) {
        self.moduleID = moduleID
        self.recorder = recorder
    }

    func stopModuleResource() async {
        guard isModuleResourceActive else { return }
        isModuleResourceActive = false
        recorder.resourceStops.append(moduleID)
    }
}

private final class TestCapability: @unchecked Sendable {}

private enum TestActivationError: Error {
    case failed
}

@MainActor
private final class FailingActivationModule: LitheModule {
    let manifest: ModuleManifest
    private let recorder: ModuleTestRecorder

    init(manifest: ModuleManifest, recorder: ModuleTestRecorder) {
        self.manifest = manifest
        self.recorder = recorder
    }

    func activate(context: ModuleContext) async throws {
        context.resources.register(TestResource(moduleID: manifest.id, recorder: recorder))
        throw TestActivationError.failed
    }

    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async { recorder.shutdowns.append(manifest.id) }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

@MainActor
private final class MissingCapabilityModule: LitheModule {
    let manifest: ModuleManifest
    private let recorder: ModuleTestRecorder

    init(manifest: ModuleManifest, recorder: ModuleTestRecorder) {
        self.manifest = manifest
        self.recorder = recorder
    }

    func activate(context: ModuleContext) async throws {
        context.resources.register(TestResource(moduleID: manifest.id, recorder: recorder))
    }

    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async { recorder.shutdowns.append(manifest.id) }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
