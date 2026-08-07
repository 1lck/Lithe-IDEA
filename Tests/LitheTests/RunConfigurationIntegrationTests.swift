import Foundation
import Testing
@testable import Lithe

@Suite("Run configuration integration")
@MainActor
struct RunConfigurationIntegrationTests {
    @Test
    func missingConfigurationLeavesRunUnavailableWithoutScanningLegacySettings() async {
        let fixture = makeFixture(status: .missing)

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: fixture.mavenProject
        )

        #expect(fixture.service.configurationStatus == .missing)
        #expect(fixture.service.configurations.isEmpty)
        #expect(fixture.operations.resolveCalls == 0)
        #expect(fixture.operations.migrationCalls == 0)
        #expect(fixture.process.requests.isEmpty)
    }

    @Test
    func readyConfigurationUsesSharedLaunchPlanForProcessRequest() async throws {
        let configuration = JavaRunConfiguration(
            id: "spring:com.example.App",
            name: "App",
            kind: .springBoot,
            modulePath: "backend",
            mainClass: "com.example.App"
        )
        let plan = SharedLaunchPlan(
            toolchainID: "project-maven",
            arguments: ["-B", "-ntp", "-pl", "backend", "-P", "dev", "spring-boot:run"],
            workingDirectory: "backend"
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [EffectiveRunConfiguration(configuration: configuration, options: JavaRunOptions())],
            plans: [configuration.id: plan]
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: fixture.mavenProject
        )
        fixture.service.run(configuration: configuration, currentFileURL: nil)

        let request = try #require(fixture.process.requests.last)
        #expect(request.executablePath == "/toolchains/maven/bin/mvn")
        #expect(request.arguments == plan.arguments)
        #expect(request.workingDirectory == fixture.root.appendingPathComponent("backend").path)
        #expect(request.environment?["JAVA_HOME"] == "/toolchains/jdk")
        #expect(fixture.operations.launchPlanIDs == [configuration.id])
    }

    @Test
    func runAllModulesUsesOneSharedLaunchPlanPerModule() async throws {
        let first = JavaRunConfiguration(
            id: "module:backend",
            name: "backend",
            kind: .mavenModule,
            modulePath: "backend",
            mainClass: nil
        )
        let second = JavaRunConfiguration(
            id: "module:worker",
            name: "worker",
            kind: .mavenModule,
            modulePath: "worker",
            mainClass: nil
        )
        let firstPlan = SharedLaunchPlan(
            toolchainID: "project-maven",
            arguments: ["-B", "-ntp", "-pl", "backend", "spring-boot:run"],
            workingDirectory: "."
        )
        let secondPlan = SharedLaunchPlan(
            toolchainID: "project-maven",
            arguments: ["-B", "-ntp", "-pl", "worker", "-P", "local", "spring-boot:run"],
            workingDirectory: "worker"
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [
                EffectiveRunConfiguration(configuration: first, options: JavaRunOptions()),
                EffectiveRunConfiguration(configuration: second, options: JavaRunOptions())
            ],
            plans: [first.id: firstPlan, second.id: secondPlan]
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: fixture.mavenProject
        )
        fixture.service.runAllModules()

        #expect(fixture.operations.launchPlanIDs == [first.id, second.id])
        #expect(fixture.processFactory.processes.count == 2)
        let requests = try fixture.processFactory.processes.map { try #require($0.requests.last) }
        #expect(requests.map(\.arguments) == [firstPlan.arguments, secondPlan.arguments])
        #expect(requests.map(\.workingDirectory) == [
            fixture.root.path,
            fixture.root.appendingPathComponent("worker").path
        ])
    }

    @Test
    func projectRuntimeUsesAndUpdatesLitheLocalToolchains() throws {
        let root = URL(fileURLWithPath: "/tmp/lithe-runtime-toolchains", isDirectory: true)
        let source = RecordingToolchainSource(selection: ProjectToolchainSelection(
            javaHomePath: "/local/JDK 21",
            mavenExecutablePath: "/local/Maven 3.9/bin/mvn",
            mavenJavaHomePath: "/local/Maven JDK"
        ))
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore(),
            toolchainSource: source
        )
        runtime.openProject(at: root)
        let project = MavenProject(
            rootURL: root,
            pomURL: root.appendingPathComponent("pom.xml"),
            groupID: nil,
            artifactID: "fixture",
            version: nil,
            packaging: "jar",
            modules: [],
            profiles: [],
            hasWrapper: false
        )

        #expect(runtime.javaExecutableURL()?.path == "/local/JDK 21/bin/java")
        #expect(runtime.mavenExecutable(for: project)?.path == "/local/Maven 3.9/bin/mvn")
        #expect(runtime.environment(for: .maven)["JAVA_HOME"] == "/local/Maven JDK")

        runtime.updateJavaHomePath("/updated/jdk")
        let saved = try #require(source.saved.last)
        #expect(saved.javaHomePath == "/updated/jdk")
        #expect(saved.mavenExecutablePath == "/local/Maven 3.9/bin/mvn")
    }

    @Test
    func javaLanguageServerUsesTheSameProjectJDKWithSpaces() throws {
        let root = URL(fileURLWithPath: "/tmp/lithe-language-toolchain", isDirectory: true)
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore(),
            toolchainSource: RecordingToolchainSource(selection: ProjectToolchainSelection(
                javaHomePath: "/local/JDK 21",
                mavenExecutablePath: "",
                mavenJavaHomePath: ""
            ))
        )
        runtime.openProject(at: root)
        let process = RecordingRawProcessSession()
        let service = JavaLanguageService(
            runtimeService: runtime,
            process: process,
            archiveReader: EmptyArchiveEntryReader(),
            fileStorage: RunTestFileStorage(),
            javaMavenOperations: RunTestJavaMavenOperations()
        )

        service.prepare(for: root)

        let request = try #require(process.requests.first)
        #expect(request.executablePath == "/toolchains/jdtls")
        #expect(request.arguments.contains("--java-executable"))
        #expect(request.arguments.contains("/local/JDK 21/bin/java"))
    }

    @Test
    func mavenDebugUsesSharedDebugLaunchPlan() throws {
        let root = URL(fileURLWithPath: "/tmp/lithe-debug-service", isDirectory: true)
        let configuration = JavaRunConfiguration(
            id: "spring:com.example.App",
            name: "App",
            kind: .springBoot,
            modulePath: "backend",
            mainClass: "com.example.App"
        )
        let arguments = [
            "-B", "-ntp", "-pl", "backend",
            "-Dspring-boot.run.jvmArguments=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:5555",
            "spring-boot:run"
        ]
        let operations = RecordingRunConfigurationOperations(
            status: .ready,
            effective: [],
            plans: [configuration.id: SharedLaunchPlan(
                toolchainID: "project-maven",
                arguments: arguments,
                workingDirectory: "backend"
            )]
        )
        let processFactory = RecordingProcessFactory()
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        runtime.openProject(at: root)
        let project = MavenProject(
            rootURL: root,
            pomURL: root.appendingPathComponent("pom.xml"),
            groupID: nil,
            artifactID: "fixture",
            version: nil,
            packaging: "jar",
            modules: [],
            profiles: [],
            hasWrapper: false
        )
        let service = JavaDebugService(
            runtimeService: runtime,
            processFactory: { processFactory.make() },
            fileStorage: RunTestFileStorage(),
            javaMavenOperations: RunTestJavaMavenOperations(),
            runConfigurationOperations: operations
        )

        service.startMaven(
            configuration: configuration,
            project: project,
            projectURL: root,
            options: JavaRunOptions()
        )

        let request = try #require(processFactory.processes.first?.requests.first)
        #expect(request.arguments == arguments)
        #expect(request.workingDirectory == root.appendingPathComponent("backend").path)
        #expect(operations.debugPorts.count == 1)
        #expect(operations.debugPorts[0] != nil)
    }

    @Test
    func generationPublishesNoEntryResultAndKeepsCurrentFileAvailable() async {
        let current = JavaRunConfiguration.currentFile
        let fixture = makeFixture(
            status: .missing,
            effective: [EffectiveRunConfiguration(configuration: current, options: JavaRunOptions())],
            generationEntryCount: 0
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: fixture.mavenProject
        )
        await fixture.service.generateRunConfigurations()

        #expect(fixture.service.configurationStatus == .ready)
        #expect(fixture.service.generationState == .noEntries)
        #expect(fixture.service.configurations == [current])
    }

    @Test
    func projectOptionsAreWrittenToTeamFileWithoutLocalJDKPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-project-options-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".lithe/run"),
            withIntermediateDirectories: true
        )
        try Data(#"{"version":1,"configurations":[]}"#.utf8)
            .write(to: root.appendingPathComponent(".lithe/run/generated.json"))
        let store = MacRunConfigurationStore(
            core: RustCoreBridge(),
            storage: MacFileStorage(),
            preferences: RunTestKeyValueStore(),
            documentMutator: RunTestDocumentMutator()
        )

        try store.saveOptions(
            JavaRunOptions(
                javaHomePath: "/Library/Java/private-jdk",
                workingDirectoryPath: root.appendingPathComponent("backend app").path,
                vmArguments: "-Xmx2g",
                programArguments: "--dev",
                activeProfiles: ["dev"]
            ),
            configurationID: "spring:com.example.App",
            scope: .project,
            at: root
        )

        let data = try Data(contentsOf: root.appendingPathComponent(".lithe/run/configurations.json"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("backend app"))
        #expect(!text.contains("private-jdk"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/toolchains/local.json").path))
        #expect(throws: (any Error).self) {
            try store.saveOptions(
                JavaRunOptions(workingDirectoryPath: "../outside"),
                configurationID: "spring:com.example.App",
                scope: .project,
                at: root
            )
        }
    }

    @Test
    func creatingProjectConfigurationWritesTypedTeamEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-create-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("backend/src/main/java/com/example"),
            withIntermediateDirectories: true
        )
        try Data("package com.example; class App { public static void main(String[] args) {} }".utf8)
            .write(to: root.appendingPathComponent("backend/src/main/java/com/example/App.java"))
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore(), documentMutator: RunTestDocumentMutator())

        let id = try store.createConfiguration(
            RunConfigurationDraft(name: "Backend Dev", kind: .springBoot, modulePath: "backend", mainClass: "com.example.App", scope: .project),
            at: root
        )
        #expect(id == "user:backend-dev")
        let data = try Data(contentsOf: root.appendingPathComponent(".lithe/run/configurations.json"))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let configurations = try #require(document["configurations"] as? [[String: Any]])
        #expect(configurations.first?["type"] as? String == "spring-boot.maven")
        #expect(configurations.first?["module"] as? String == "backend")
        #expect(configurations.first?["mainClass"] as? String == "com.example.App")
    }

    @Test
    func linkedRustCoreMutatesDocumentsThroughTheProductionAdapter() throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-linked-mutation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/main/java/com/example"),
            withIntermediateDirectories: true
        )
        try Data("package com.example; class App { public static void main(String[] args) {} }".utf8)
            .write(to: root.appendingPathComponent("src/main/java/com/example/App.java"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".lithe/run"), withIntermediateDirectories: true)
        try Data(#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file","toolchains":{"java":"project-jdk"}}]}"#.utf8)
            .write(to: root.appendingPathComponent(".lithe/run/generated.json"))
        let store = MacRunConfigurationStore(
            core: core,
            storage: MacFileStorage(),
            preferences: RunTestKeyValueStore()
        )

        try store.saveOptions(
            JavaRunOptions(vmArguments: "\"-Dlabel=hello world\" -Xmx2g"),
            configurationID: "current-file",
            scope: .project,
            at: root
        )
        let id = try store.createConfiguration(
            RunConfigurationDraft(
                name: "Backend Dev",
                kind: .springBoot,
                modulePath: ".",
                mainClass: "com.example.App",
                scope: .project
            ),
            at: root
        )

        #expect(id == "user:backend-dev")
        let data = try Data(contentsOf: root.appendingPathComponent(".lithe/run/configurations.json"))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let configurations = try #require(document["configurations"] as? [[String: Any]])
        #expect(configurations.count == 2)
        #expect(configurations.first?["jvmArguments"] as? [String] == ["-Dlabel=hello world", "-Xmx2g"])
    }

    @Test
    func generationPermissionFailurePreservesExistingGeneratedConfiguration() throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-generation-permission-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("src/App.java")
        try Data("class App { public static void main(String[] args) {} }".utf8).write(to: source)
        let storage = CountingFileStorage(root: root)
        let generatedURL = root.appendingPathComponent(".lithe/run/generated.json")
        let original = Data(#"{"version":1,"configurations":[]}"#.utf8)
        storage.seed(original, at: generatedURL)
        storage.shouldFailWrites = true
        let store = MacRunConfigurationStore(
            core: core,
            storage: storage,
            preferences: RunTestKeyValueStore()
        )

        #expect(throws: (any Error).self) {
            try store.generate(at: root, files: [source], modulePaths: [])
        }
        #expect(try storage.readData(from: generatedURL, options: []) == original)
    }

    @Test
    func creatingLocalConfigurationWritesLocalEntryAndDisambiguatesName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-create-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore(), documentMutator: RunTestDocumentMutator())
        let draft = RunConfigurationDraft(name: "Backend Dev", kind: .mavenModule, modulePath: ".", mainClass: "", scope: .local)
        _ = try store.createConfiguration(draft, at: root)
        let second = try store.createConfiguration(draft, at: root)
        #expect(second == "user:backend-dev-2")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/local.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/configurations.json").path))
    }

    @Test
    func creatingSpringBootConfigurationRequiresMainClassAndRejectsOutsideModule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-create-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore(), documentMutator: RunTestDocumentMutator())
        #expect(throws: (any Error).self) {
            try store.createConfiguration(
                RunConfigurationDraft(name: "Broken", kind: .springBoot, modulePath: ".", mainClass: "", scope: .project),
                at: root
            )
        }
        #expect(throws: (any Error).self) {
            try store.createConfiguration(
                RunConfigurationDraft(name: "Outside", kind: .mavenModule, modulePath: "../other", mainClass: "", scope: .project),
                at: root
            )
        }
    }

    @Test
    func configurationWriteRejectsLitheSymlinkOutsideProject() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-symlink-write-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".lithe"),
            withDestinationURL: outside
        )
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore(), documentMutator: RunTestDocumentMutator())

        #expect(throws: (any Error).self) {
            try store.createConfiguration(
                RunConfigurationDraft(name: "Outside", kind: .mavenModule, modulePath: ".", mainClass: "", scope: .project),
                at: root
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("run/configurations.json").path))
    }

    @Test
    func unchangedLocalOptionsDoNotRewriteTheConfigurationFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-unchanged-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CountingFileStorage(root: root)
        storage.seed(
            Data(#"{"version":1,"configurations":[]}"#.utf8),
            at: root.appendingPathComponent(".lithe/run/generated.json")
        )
        let store = MacRunConfigurationStore(
            core: RustCoreBridge(),
            storage: storage,
            preferences: RunTestKeyValueStore(),
            documentMutator: RunTestDocumentMutator()
        )
        let options = JavaRunOptions(
            workingDirectoryPath: "backend app",
            vmArguments: "-Xmx2g",
            programArguments: "--dev",
            activeProfiles: ["dev"]
        )

        try store.saveOptions(
            options,
            configurationID: "spring:com.example.App",
            scope: .local,
            at: root
        )
        let writesAfterFirstSave = storage.writeCount
        try store.saveOptions(
            options,
            configurationID: "spring:com.example.App",
            scope: .local,
            at: root
        )

        #expect(writesAfterFirstSave == 1)
        #expect(storage.writeCount == writesAfterFirstSave)
    }

    @Test
    func failedAtomicWritePreservesExistingLocalConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-failed-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CountingFileStorage(root: root)
        let localURL = root.appendingPathComponent(".lithe/run/local.json")
        let original = Data(#"{"version":1,"configurations":[]}"#.utf8)
        storage.seed(original, at: localURL)
        storage.shouldFailWrites = true
        let store = MacRunConfigurationStore(
            core: RustCoreBridge(),
            storage: storage,
            preferences: RunTestKeyValueStore(),
            documentMutator: RunTestDocumentMutator()
        )

        #expect(throws: (any Error).self) {
            try store.saveOptions(
                JavaRunOptions(vmArguments: "-Xmx2g"),
                configurationID: "current-file",
                scope: .local,
                at: root
            )
        }
        #expect(try storage.readData(from: localURL, options: []) == original)
    }

    @Test
    func teamDefaultAndEffectiveSourceAreApplied() async throws {
        let first = JavaRunConfiguration.currentFile
        let second = JavaRunConfiguration(
            id: "spring:com.example.App",
            name: "App",
            kind: .springBoot,
            modulePath: nil,
            mainClass: "com.example.App"
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [
                EffectiveRunConfiguration(configuration: first, options: JavaRunOptions()),
                EffectiveRunConfiguration(
                    configuration: second,
                    options: JavaRunOptions(vmArguments: "-Xmx2g"),
                    source: .project
                )
            ],
            defaultConfigurationID: second.id
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: fixture.mavenProject
        )

        #expect(fixture.service.selectedConfigurationID == second.id)
        #expect(fixture.service.source(for: second) == .project)
        #expect(fixture.operations.migrationCalls == 0)
    }

    @Test
    func createdConfigurationIsResolvedAndSelected() async {
        let fixture = makeFixture(
            status: .ready,
            effective: [EffectiveRunConfiguration(configuration: .currentFile, options: JavaRunOptions())]
        )
        await fixture.service.loadProject(at: fixture.root, files: [], mavenProject: fixture.mavenProject)

        let created = fixture.service.createConfiguration(
            RunConfigurationDraft(
                name: "Backend Dev",
                kind: .mavenModule,
                modulePath: "backend",
                mainClass: "",
                scope: .project
            )
        )

        #expect(created)
        #expect(fixture.service.selectedConfigurationID == "user:backend-dev")
        #expect(fixture.service.selectedConfiguration?.name == "Backend Dev")
        #expect(fixture.operations.createdDrafts.count == 1)
    }

    @Test
    func recentConfigurationSelectionIsRestoredFromLocalPreferences() async {
        let preferences = RunTestKeyValueStore()
        let current = EffectiveRunConfiguration(configuration: .currentFile, options: JavaRunOptions())
        let backend = JavaRunConfiguration(
            id: "module:backend",
            name: "backend",
            kind: .mavenModule,
            modulePath: "backend",
            mainClass: nil
        )
        let first = makeFixture(
            status: .ready,
            effective: [current, EffectiveRunConfiguration(configuration: backend, options: JavaRunOptions())],
            preferences: preferences
        )
        await first.service.loadProject(at: first.root, files: [], mavenProject: first.mavenProject)
        first.service.select(backend)

        let reopened = makeFixture(
            status: .ready,
            effective: [current, EffectiveRunConfiguration(configuration: backend, options: JavaRunOptions())],
            preferences: preferences
        )
        await reopened.service.loadProject(at: reopened.root, files: [], mavenProject: reopened.mavenProject)

        #expect(reopened.service.selectedConfigurationID == backend.id)
    }

    @Test
    func staleProjectLoadCannotReplaceTheNewProjectState() async {
        let oldRoot = URL(fileURLWithPath: "/tmp/lithe-old-project", isDirectory: true)
        let newRoot = URL(fileURLWithPath: "/tmp/lithe-new-project", isDirectory: true)
        let operations = BlockingInspectionOperations(blockedProjectURL: oldRoot)
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let service = JavaRunService(
            runtimeService: runtime,
            process: RecordingStreamingProcess(),
            processFactory: { RecordingStreamingProcess() },
            fileStorage: RunTestFileStorage(),
            preferences: RunTestKeyValueStore(),
            javaMavenOperations: RunTestJavaMavenOperations(),
            runConfigurationOperations: operations
        )

        let oldLoad = Task {
            await service.loadProject(at: oldRoot, files: [], mavenProject: nil)
        }
        await Task.detached { operations.waitUntilBlocked() }.value
        await service.loadProject(at: newRoot, files: [], mavenProject: nil)
        operations.releaseBlockedInspection()
        await oldLoad.value

        #expect(service.configurationStatus == .missing)
        #expect(service.configurations.isEmpty)
    }

    @Test
    func inspectionErrorsMapToSafeRecoveryActionsAndFiles() {
        #expect(MacRunConfigurationStore.recoveryAction(for: "not_supported") == .upgradeApplication)
        #expect(MacRunConfigurationStore.recoveryAction(for: "parse_failed") == .editConfiguration)
        #expect(MacRunConfigurationStore.recoveryAction(for: "permission_denied") == .fixPermissions)
        #expect(MacRunConfigurationStore.recoveryPath(
            in: "Configuration JSON is invalid: .lithe/toolchains/local.json: line 1"
        ) == ".lithe/toolchains/local.json")
    }

    @Test
    func appOwnedFileEventSuppressionIsOneShotAndExpires() {
        let first = URL(fileURLWithPath: "/tmp/lithe-self-write-one.json")
        let second = URL(fileURLWithPath: "/tmp/lithe-self-write-two.json")
        let now = Date(timeIntervalSince1970: 1_000)

        MacFileWriteEventSuppression.markWritten(first, now: now)
        #expect(MacFileWriteEventSuppression.consume(first, now: now.addingTimeInterval(1)))
        #expect(!MacFileWriteEventSuppression.consume(first, now: now.addingTimeInterval(1)))

        MacFileWriteEventSuppression.markWritten(second, now: now)
        #expect(!MacFileWriteEventSuppression.consume(second, now: now.addingTimeInterval(3)))
    }

    private func makeFixture(
        status: ProjectRunConfigurationStatus,
        effective: [EffectiveRunConfiguration] = [],
        plans: [String: SharedLaunchPlan] = [:],
        generationEntryCount: Int? = nil,
        defaultConfigurationID: String? = nil,
        preferences: RunTestKeyValueStore = RunTestKeyValueStore()
    ) -> RunServiceFixture {
        let root = URL(fileURLWithPath: "/tmp/lithe-run-service", isDirectory: true)
        let operations = RecordingRunConfigurationOperations(
            status: status,
            effective: effective,
            plans: plans,
            generationEntryCount: generationEntryCount,
            defaultConfigurationID: defaultConfigurationID
        )
        let process = RecordingStreamingProcess()
        let processFactory = RecordingProcessFactory()
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let service = JavaRunService(
            runtimeService: runtime,
            process: process,
            processFactory: { processFactory.make() },
            fileStorage: RunTestFileStorage(),
            preferences: preferences,
            javaMavenOperations: RunTestJavaMavenOperations(),
            runConfigurationOperations: operations
        )
        let modules = ["backend", "worker"].map { path in
            MavenModule(
                relativePath: path,
                url: root.appendingPathComponent(path),
                groupID: nil,
                artifactID: path,
                version: nil,
                packaging: "jar",
                modules: []
            )
        }
        let project = MavenProject(
            rootURL: root,
            pomURL: root.appendingPathComponent("pom.xml"),
            groupID: nil,
            artifactID: "fixture",
            version: nil,
            packaging: "pom",
            modules: modules,
            profiles: [],
            hasWrapper: false
        )
        return RunServiceFixture(
            root: root,
            mavenProject: project,
            service: service,
            operations: operations,
            process: process,
            processFactory: processFactory
        )
    }
}

@MainActor
private struct RunServiceFixture {
    let root: URL
    let mavenProject: MavenProject
    let service: JavaRunService
    let operations: RecordingRunConfigurationOperations
    let process: RecordingStreamingProcess
    let processFactory: RecordingProcessFactory
}

private final class RecordingRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    let status: ProjectRunConfigurationStatus
    private var effective: [EffectiveRunConfiguration]
    let plans: [String: SharedLaunchPlan]
    let generationEntryCount: Int?
    let defaultConfigurationID: String?
    private(set) var resolveCalls = 0
    private(set) var migrationCalls = 0
    private(set) var launchPlanIDs: [String] = []
    private(set) var debugPorts: [Int?] = []
    private(set) var createdDrafts: [RunConfigurationDraft] = []

    init(
        status: ProjectRunConfigurationStatus,
        effective: [EffectiveRunConfiguration],
        plans: [String: SharedLaunchPlan],
        generationEntryCount: Int? = nil,
        defaultConfigurationID: String? = nil
    ) {
        self.status = status
        self.effective = effective
        self.plans = plans
        self.generationEntryCount = generationEntryCount
        self.defaultConfigurationID = defaultConfigurationID
    }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: status, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: generationEntryCount ?? effective.count)
    }
    func resolve(
        at projectURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) throws -> RunConfigurationResolution {
        resolveCalls += 1
        return RunConfigurationResolution(
            configurations: effective,
            diagnostics: [],
            defaultConfigurationID: defaultConfigurationID
        )
    }
    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan {
        launchPlanIDs.append(configurationID)
        debugPorts.append(debugPort)
        guard let plan = plans[configurationID] else {
            throw RunConfigurationOperationFailure(message: "Missing test launch plan")
        }
        return plan
    }
    func saveOptions(
        _ options: JavaRunOptions,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws {}
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String {
        createdDrafts.append(draft)
        let slug = draft.name.lowercased().replacingOccurrences(of: " ", with: "-")
        let id = "user:\(slug)"
        let configuration = JavaRunConfiguration(
            id: id,
            name: draft.name,
            kind: draft.kind,
            modulePath: draft.modulePath,
            mainClass: draft.mainClass.isEmpty ? nil : draft.mainClass
        )
        effective.append(EffectiveRunConfiguration(
            configuration: configuration,
            options: JavaRunOptions(),
            source: draft.scope == .local ? .local : .project
        ))
        return id
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {
        migrationCalls += 1
    }
    func loadLocalToolchains(at projectURL: URL) -> ProjectToolchainSelection {
        ProjectToolchainSelection()
    }
    func saveLocalToolchains(_ selection: ProjectToolchainSelection, at projectURL: URL) throws {}
}

private final class BlockingInspectionOperations: RunConfigurationOperations, @unchecked Sendable {
    private let blockedProjectPath: String
    private let didBlock = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(blockedProjectURL: URL) {
        blockedProjectPath = blockedProjectURL.standardizedFileURL.path
    }

    func waitUntilBlocked() {
        didBlock.wait()
    }

    func releaseBlockedInspection() {
        release.signal()
    }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        if projectURL.standardizedFileURL.path == blockedProjectPath {
            didBlock.signal()
            release.wait()
            return ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
        }
        return ProjectRunConfigurationInspection(status: .missing, diagnostics: [])
    }

    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }

    func resolve(
        at projectURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }

    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "No launch plan")
    }

    func saveOptions(
        _ options: JavaRunOptions,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws {}
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String {
        throw RunConfigurationOperationFailure(message: "Creation is unavailable in this test double")
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
    func loadLocalToolchains(at projectURL: URL) -> ProjectToolchainSelection { ProjectToolchainSelection() }
    func saveLocalToolchains(_ selection: ProjectToolchainSelection, at projectURL: URL) throws {}
}

private final class RecordingStreamingProcess: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    private(set) var requests: [ProcessRequest] = []

    func start(_ request: ProcessRequest) throws {
        requests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {}
    func stop() { isRunning = false }
}

private final class RecordingRawProcessSession: RawProcessSession, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    private(set) var requests: [ProcessRequest] = []

    func start(_ request: ProcessRequest) throws {
        requests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {}
    func stop() { isRunning = false }
}

private struct EmptyArchiveEntryReader: ArchiveEntryReader {
    func read(entry: String, from archive: URL) -> String? { nil }
}

private final class RecordingProcessFactory: @unchecked Sendable {
    private(set) var processes: [RecordingStreamingProcess] = []

    func make() -> RecordingStreamingProcess {
        let process = RecordingStreamingProcess()
        processes.append(process)
        return process
    }
}

private final class RecordingToolchainSource: ProjectToolchainConfigurationSource, @unchecked Sendable {
    let selection: ProjectToolchainSelection
    private(set) var saved: [ProjectToolchainSelection] = []

    init(selection: ProjectToolchainSelection) {
        self.selection = selection
    }

    func loadLocalToolchains(at projectURL: URL) -> ProjectToolchainSelection { selection }
    func saveLocalToolchains(_ selection: ProjectToolchainSelection, at projectURL: URL) throws {
        saved.append(selection)
    }
}

private struct RunTestRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/usr/bin"] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(
            javaRuntimes: [JavaRuntimeCandidate(homePath: "/toolchains/jdk", version: "21", vendor: "Test")],
            mavenRuntimes: []
        )
    }
    func validJavaHome(path: String) -> URL? { URL(fileURLWithPath: path, isDirectory: true) }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        JavaRuntimeCandidate(homePath: homeURL.path, version: "21", vendor: "Test")
    }
    func isExecutable(at url: URL) -> Bool { url.lastPathComponent != "mvnw" }
    func systemMavenExecutable() -> URL? { URL(fileURLWithPath: "/toolchains/maven/bin/mvn") }
    func mavenExecutable(forHomePath path: String) -> URL? {
        URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("bin/mvn")
    }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? {
        MavenRuntimeCandidate(
            homePath: executableURL.deletingLastPathComponent().deletingLastPathComponent().path,
            executablePath: executableURL.path,
            version: "3.9.9"
        )
    }
    func systemJDBExecutable() -> URL? { URL(fileURLWithPath: "/toolchains/jdk/bin/jdb") }
    func javaLanguageServerExecutable() -> URL? { URL(fileURLWithPath: "/toolchains/jdtls") }
}

private struct RunTestFileStorage: FileStorage {
    func homeDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func cacheDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func applicationSupportDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func metadata(for url: URL) -> FileMetadata? {
        FileMetadata(byteCount: nil, modificationDate: nil, isRegularFile: false, isDirectory: true)
    }
    func fileExists(at url: URL) -> Bool { false }
    func isExecutable(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func removeItem(at url: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
}

private final class CountingFileStorage: FileStorage, @unchecked Sendable {
    private let root: URL
    private var files: [String: Data] = [:]
    private(set) var writeCount = 0
    var shouldFailWrites = false

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func seed(_ data: Data, at url: URL) {
        files[url.standardizedFileURL.path] = data
    }

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root }
    func applicationSupportDirectory() -> URL { root }
    func metadata(for url: URL) -> FileMetadata? {
        if url.standardizedFileURL == root {
            return FileMetadata(byteCount: nil, modificationDate: nil, isRegularFile: false, isDirectory: true)
        }
        guard let data = files[url.standardizedFileURL.path] else { return nil }
        return FileMetadata(byteCount: data.count, modificationDate: nil, isRegularFile: true, isDirectory: false)
    }
    func fileExists(at url: URL) -> Bool { files[url.standardizedFileURL.path] != nil }
    func isExecutable(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data {
        guard let data = files[url.standardizedFileURL.path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        if shouldFailWrites { throw CocoaError(.fileWriteNoPermission) }
        files[url.standardizedFileURL.path] = data
        writeCount += 1
    }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func removeItem(at url: URL) throws { files.removeValue(forKey: url.standardizedFileURL.path) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let data = files.removeValue(forKey: sourceURL.standardizedFileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files[destinationURL.standardizedFileURL.path] = data
    }
}

final class RunTestDocumentMutator: RunConfigurationDocumentMutating, @unchecked Sendable {
    func updateOptionsDocument(
        at projectURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: JavaRunOptions
    ) throws -> RunConfigurationDocumentMutation {
        let url = documentURL(projectURL, scope: scope)
        var document = readDocument(url)
        var configurations = document["configurations"] as? [[String: Any]] ?? []
        let rootPath = projectURL.standardizedFileURL.path + "/"
        let workingDirectory = options.workingDirectoryPath.hasPrefix(rootPath)
            ? String(options.workingDirectoryPath.dropFirst(rootPath.count))
            : (options.workingDirectoryPath.isEmpty ? "." : options.workingDirectoryPath)
        guard !workingDirectory.split(separator: "/").contains("..") else {
            throw RunConfigurationOperationFailure(message: "Path leaves project")
        }
        let value: [String: Any] = [
            "id": configurationID,
            "workingDirectory": workingDirectory,
            "jvmArguments": split(options.vmArguments),
            "programArguments": split(options.programArguments),
            "mavenProfiles": options.activeProfiles.sorted()
        ]
        if let index = configurations.firstIndex(where: { $0["id"] as? String == configurationID }) {
            configurations[index].merge(value) { _, new in new }
        } else {
            configurations.append(value)
        }
        document["version"] = 1
        document["configurations"] = configurations.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return RunConfigurationDocumentMutation(configurationID: nil, document: try encode(document))
    }

    func createConfigurationDocument(
        at projectURL: URL,
        draft: RunConfigurationDraft
    ) throws -> RunConfigurationDocumentMutation {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              draft.kind == .mavenModule || !draft.mainClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.modulePath.split(separator: "/").contains("..") else {
            throw RunConfigurationOperationFailure(message: "Invalid configuration draft")
        }
        let url = documentURL(projectURL, scope: draft.scope)
        var document = readDocument(url)
        var configurations = document["configurations"] as? [[String: Any]] ?? []
        let base = "user:" + name.lowercased().replacingOccurrences(of: " ", with: "-")
        let ids = Set(configurations.compactMap { $0["id"] as? String })
        var id = base
        var suffix = 2
        while ids.contains(id) { id = "\(base)-\(suffix)"; suffix += 1 }
        var value: [String: Any] = [
            "id": id,
            "name": name,
            "type": draft.kind == .springBoot ? "spring-boot.maven" : "maven.module",
            "module": draft.modulePath.isEmpty ? "." : draft.modulePath,
            "toolchains": ["java": "project-jdk", "maven": "project-maven"],
            "workingDirectory": ".",
            "jvmArguments": [],
            "programArguments": [],
            "mavenProfiles": []
        ]
        if draft.kind == .springBoot { value["mainClass"] = draft.mainClass }
        configurations.append(value)
        document["version"] = 1
        document["configurations"] = configurations
        return RunConfigurationDocumentMutation(configurationID: id, document: try encode(document))
    }

    private func documentURL(_ root: URL, scope: RunConfigurationSaveScope) -> URL {
        root.appendingPathComponent(scope == .local ? ".lithe/run/local.json" : ".lithe/run/configurations.json")
    }

    private func readDocument(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["version": 1, "configurations": []]
        }
        return value
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    private func split(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in input {
            if character == "'" || character == "\"" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private final class RunTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct RunTestJavaMavenOperations: JavaMavenOperations {
    func scanMavenProject(at rootURL: URL) -> MavenProject? { nil }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
    func codeVision(at rootURL: URL, targetPath: String, paths: [String]) -> [JavaCodeVisionValue] { [] }
    func className(source: String, simpleName: String) -> String? { nil }
    func sourceDefinition(source: String, declarationName: String, memberName: String?) -> (line: Int, utf16Column: Int)? { nil }
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
    func scanRunConfigurations(at rootURL: URL, files: [URL], mavenProject: MavenProject?) -> [JavaRunConfiguration] { [] }
    func structure(source: String, declarationSources: [String]) -> JavaStructureResult? { nil }
}
