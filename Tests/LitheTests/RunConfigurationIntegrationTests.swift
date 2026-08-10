import Foundation
import Testing
@testable import Lithe

@Suite("Run configuration integration")
@MainActor
struct RunConfigurationIntegrationTests {
    @Test
    func providerCapabilitiesKeepProcessEditorsLanguageNeutral() {
        let process = RunConfigurationKind.process(provider: "python.script").capabilities
        #expect(process.contains(.workingDirectory))
        #expect(process.contains(.arguments))
        #expect(process.contains(.environment))
        #expect(!process.contains(.javaRuntime))
        #expect(!process.contains(.javaVMArguments))
        #expect(!process.contains(.mavenProfiles))

        let maven = RunConfigurationKind.springBoot.capabilities
        #expect(maven.contains(.javaRuntime))
        #expect(maven.contains(.javaVMArguments))
        #expect(maven.contains(.mavenProfiles))
        #expect(maven.contains(.jdwpDebug))

        let current = RunConfiguration.currentFile
        let pythonCapabilities = current.effectiveCapabilities(
            for: URL(fileURLWithPath: "/tmp/scripts/main.py")
        )
        #expect(pythonCapabilities == .process)
        let unknownCapabilities = current.effectiveCapabilities(
            for: URL(fileURLWithPath: "/tmp/scripts/main.rb")
        )
        #expect(unknownCapabilities == .process)
        let javaCapabilities = current.effectiveCapabilities(
            for: URL(fileURLWithPath: "/tmp/Main.java")
        )
        #expect(javaCapabilities.contains(.javaRuntime))
    }

    @Test
    func currentFileRunProvidersBuildPlansWithoutJavaAssumptions() throws {
        let registry = LanguageRunProviderRegistry.standard()
        let root = URL(fileURLWithPath: "/tmp/current-file-runners", isDirectory: true)
        let python = root.appendingPathComponent("scripts/server.py")
        let node = root.appendingPathComponent("web/index.js")
        let go = root.appendingPathComponent("cmd/api/main.go")

        let pythonPlan = try registry.launchPlan(
            for: python,
            workspaceURL: root,
            options: RunOptions(programArguments: "--port 8080 \"hello world\"")
        )
        #expect(pythonPlan.toolchainID == "project-python")
        #expect(pythonPlan.arguments == ["scripts/server.py", "--port", "8080", "hello world"])

        let nodePlan = try registry.launchPlan(for: node, workspaceURL: root)
        #expect(nodePlan.toolchainID == "project-node")
        #expect(nodePlan.arguments == ["web/index.js"])

        let typeScriptPlan = try registry.launchPlan(
            for: root.appendingPathComponent("web/index.ts"),
            workspaceURL: root
        )
        #expect(typeScriptPlan.toolchainID == "project-tsx")

        let goPlan = try registry.launchPlan(for: go, workspaceURL: root)
        #expect(goPlan.toolchainID == "project-go")
        #expect(goPlan.arguments == ["run", "cmd/api/main.go"])

        #expect(throws: LanguageRunPlanError.noProvider(fileExtension: "java")) {
            _ = try registry.launchPlan(
                for: root.appendingPathComponent("Main.java"),
                workspaceURL: root
            )
        }
        #expect(throws: LanguageRunPlanError.fileOutsideWorkspace(
            URL(fileURLWithPath: "/tmp/outside.py")
        )) {
            _ = try registry.launchPlan(
                for: URL(fileURLWithPath: "/tmp/outside.py"),
                workspaceURL: root
            )
        }
    }

    @Test
    func languageProviderCatalogKeepsOnlyCompatibilityFallbackInSwiftWhenRustCoreIsUnavailable() {
        let catalog = LanguageProviderCatalog.standard
        let go = catalog.provider(for: URL(fileURLWithPath: "/tmp/cmd/main.go"))
        let python = catalog.provider(for: URL(fileURLWithPath: "/tmp/api/server.py"))
        let node = catalog.provider(for: URL(fileURLWithPath: "/tmp/web/App.tsx"))

        #expect(go?.id == "go")
        #expect(python?.id == "python")
        #expect(node?.id == "node")
        #expect(node?.languageIdentifier(for: URL(fileURLWithPath: "/tmp/web/App.tsx")) == "typescriptreact")
        #expect(go?.activationPolicy == .onDemand)
        #expect(go?.capabilities.contains(.languageServer) == true)
        #expect(go?.capabilities.contains(.debugAdapter) == true)
        #expect(catalog.provider(for: URL(fileURLWithPath: "/tmp/Main.java"))?.capabilities.contains(.debugAdapter) == false)
        if !RustCoreBridge().isAvailable {
            #expect(catalog.provider(for: URL(fileURLWithPath: "/tmp/Package.swift")) == nil)
            #expect(catalog.provider(for: URL(fileURLWithPath: "/tmp/Dockerfile")) == nil)
        }
    }

    @Test
    func standardLanguagePackRegistryDerivesAllFocusedRegistries() {
        let registry = LanguagePackRegistry.standard()
        let providerIDs = registry.packs.map(\.descriptor.id)
        let providerIDSet = Set(providerIDs)

        #expect(providerIDs.starts(with: ["java", "go", "python", "node", "rust"]))
        #expect(registry.catalog.provider(for: URL(fileURLWithPath: "/tmp/main.go"))?.id == "go")
        #expect(registry.runProviders.provider(for: URL(fileURLWithPath: "/tmp/main.py"))?.descriptor.id == "python")
        #expect(registry.testProviders.provider(id: "python")?.descriptor.id == "python")
        #expect(registry.toolchainRegistry.contains(identifier: "project-go"))
        #expect(registry.toolchainRegistry.contains(identifier: "project-python"))
        #expect(registry.toolchainRegistry.contains(identifier: "project-tsx"))
        #expect(registry.toolchainRegistry.contains(identifier: "project-cargo"))
        #expect(registry.pack(id: "go")?.toolchainProviders.contains {
            $0.languageProviderID == "go" && $0.identifiers.contains("project-go")
        } == true)
        #expect(registry.pack(id: "go")?.debugAdapterLaunch?.executableNames == ["dlv"])
        #expect(registry.pack(id: "python")?.debugAdapterLaunch?.adapterID == "python")
        #expect(registry.pack(id: "rust")?.debugAdapterLaunch?.fallbacks.first?.executableName == "xcrun")
        #expect(registry.pack(id: "java")?.debugAdapterLaunch?.adapterID == "java")
        if !RustCoreBridge().isAvailable {
            #expect(providerIDSet == ["java", "go", "python", "node", "rust"])
            #expect(registry.catalog.provider(for: URL(fileURLWithPath: "/tmp/Dockerfile")) == nil)
        }
    }

    @Test
    func customLanguagePackRegistersWithoutChangingCoreServices() {
        let descriptor = LanguageProviderDescriptor(
            id: "ruby",
            displayName: "Ruby",
            fileExtensions: ["rb"],
            capabilities: [.run, .testing],
            activationPolicy: .onDemand
        )
        let registry = LanguagePackRegistry(packs: [
            LanguagePack(
                descriptor: descriptor,
                runProvider: StandardLanguageRunProvider(descriptor: descriptor),
                testProviders: [StandardLanguageTestProvider(descriptor: descriptor)]
            )
        ])

        #expect(registry.catalog.provider(for: URL(fileURLWithPath: "/tmp/app.rb"))?.id == "ruby")
        #expect(registry.runProviders.provider(id: "ruby")?.descriptor.id == "ruby")
        #expect(registry.testProviders.provider(id: "ruby")?.descriptor.id == "ruby")
    }

    @Test
    func genericDebugCapabilityReflectsTheRuntimeFactoryWithoutStartingIt() throws {
        let catalog = LanguageProviderCatalog.standard
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        var nodeFactoryCalls = 0
        let nodeRuntime = try #require(StdioLanguageProviderRuntime.standard(
            catalog: catalog,
            runtimeService: runtimeService,
            processFactory: { RecordingRawProcessSession() },
            debugSessionFactories: ["node": {
                nodeFactoryCalls += 1
                return TestDebugAdapterSession()
            }]
        ).first { $0.descriptor.id == "node" })
        let javaDescriptor = try #require(catalog.provider(for: URL(fileURLWithPath: "/tmp/Main.java")))
        let javaRuntime = TestDebugLanguageProviderRuntime(descriptor: javaDescriptor)
        let manager = LanguageToolingSessionManager(
            catalog: catalog,
            runtimes: [nodeRuntime, javaRuntime]
        )

        #expect(manager.supportsGenericDebugging(for: URL(fileURLWithPath: "/tmp/app.ts")))
        #expect(!manager.supportsGenericDebugging(for: URL(fileURLWithPath: "/tmp/Main.java")))
        #expect(nodeFactoryCalls == 0)
        #expect(manager.activeDebugAdapterIDs.isEmpty)
    }

    @Test
    func aFutureJavaDAPRuntimeCanOverrideTheLegacyDebugBoundary() throws {
        let javaDescriptor = LanguageProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        )
        let catalog = LanguageProviderCatalog(descriptors: [javaDescriptor])
        let runtime = TestDebugLanguageProviderRuntime(
            descriptor: javaDescriptor,
            supportsDebugAdapter: true
        )
        let manager = LanguageToolingSessionManager(
            catalog: catalog,
            runtimes: [runtime]
        )
        let source = URL(fileURLWithPath: "/tmp/Main.java")

        #expect(manager.supportsGenericDebugging(for: source))
        _ = try manager.activateDebugAdapter(
            for: source,
            rootURL: URL(fileURLWithPath: "/tmp/java-project")
        )
        #expect(runtime.debugAdapters.count == 1)
    }

    @Test
    func javaGenericDebugConfigurationUsesLanguageNeutralDapArguments() throws {
        let provider = try #require(LanguageProviderCatalog.standard.provider(
            for: URL(fileURLWithPath: "/tmp/java-project/src/main/java/com/acme/Main.java")
        ))
        let resolver = DebugLaunchConfigurationResolver(fileExists: { _ in true })
        let root = URL(fileURLWithPath: "/tmp/java-project", isDirectory: true)
        let configuration = try resolver.resolve(
            provider: provider,
            documentURL: root.appendingPathComponent("src/main/java/com/acme/Main.java"),
            workspaceURL: root,
            configurations: [],
            selectedConfiguration: nil,
            options: { _ in RunOptions() }
        )

        #expect(configuration.request == .launch)
        #expect(configuration.arguments["mainClass"] == .string("com.acme.Main"))
        #expect(configuration.arguments["cwd"] == .string(root.path))
    }

    @Test
    func macToolDiscoveryReportsProjectHomebrewAndXcodeSources() {
        let root = URL(fileURLWithPath: "/tmp/mac-tool-project", isDirectory: true)
        let executablePaths: Set<String> = [
            root.appendingPathComponent(".lithe/toolchains/bin/dlv").path,
            "/custom/bin/dlv",
            "/opt/homebrew/bin/dlv",
            "/Library/Developer/CommandLineTools/usr/bin/lldb-dap"
        ]
        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            isExecutable: { executablePaths.contains($0.path) }
        )

        let goCandidates = discovery.candidates(
            for: "dlv",
            projectURL: root,
            environment: ["PATH": "/custom/bin"]
        )
        #expect(goCandidates.map(\.source) == [.project, .path, .homebrew])
        #expect(goCandidates.map(\.executableURL.path) == [
            root.appendingPathComponent(".lithe/toolchains/bin/dlv").path,
            "/custom/bin/dlv",
            "/opt/homebrew/bin/dlv"
        ])

        let lldbCandidates = discovery.candidates(
            for: "lldb-dap",
            projectURL: root,
            environment: [:]
        )
        #expect(lldbCandidates.first?.source == .xcode)
        #expect(discovery.guidance(for: "java-debug-adapter", projectURL: root, environment: [:])
            .recovery.contains("LITHE_JAVA_DEBUG_PATH"))
    }

    @Test
    func legacyJavaDoesNotAcceptGenericDAPBreakpointsWithoutAnAdapter() throws {
        let source = URL(fileURLWithPath: "/tmp/Main.java")
        #expect(throws: LanguageToolingSessionError.capabilityUnavailable(
            provider: "Java",
            capability: "debug adapter breakpoints"
        )) {
            try LanguageToolingSessionManager(catalog: .standard).setDebugBreakpoints(
                [DebugSourceBreakpoint(line: 1)],
                in: source
            )
        }
    }

    @Test
    func standardTestProvidersDiscoverFilesAndBuildLanguageNeutralPlans() throws {
        let root = URL(fileURLWithPath: "/tmp/polyglot-tests", isDirectory: true)
        let files = [
            root.appendingPathComponent("src/test/java/UserServiceTest.java"),
            root.appendingPathComponent("cmd/api/api_test.go"),
            root.appendingPathComponent("tests/test_api.py"),
            root.appendingPathComponent("web/src/app.spec.ts"),
            root.appendingPathComponent("tests/parser.rs"),
            root.appendingPathComponent("src/production.py")
        ]
        let registry = LanguageTestProviderRegistry.standard()

        for (providerID, source) in [
            ("java", files[0]), ("go", files[1]), ("python", files[2]),
            ("node", files[3]), ("rust", files[4])
        ] {
            let provider = try #require(registry.provider(for: source))
            #expect(provider.descriptor.id == providerID)
            let items = provider.discoverTests(workspaceURL: root, files: files)
            #expect(items.first?.kind == .workspace)
            #expect(items.count == 2)
            #expect(items.last?.fileURL == source.standardizedFileURL)
        }

        let goProvider = try #require(registry.provider(id: "go"))
        let goPlan = try goProvider.testPlan(scope: .file(files[1]), workspaceURL: root)
        #expect(goPlan.launchPlan.toolchainID == "project-go")
        #expect(goPlan.launchPlan.arguments == ["test", "./cmd/api"])

        let pythonProvider = try #require(registry.provider(id: "python"))
        let pythonPlan = try pythonProvider.testPlan(
            scope: .testCase(identifier: "test_health", fileURL: files[2]),
            workspaceURL: root
        )
        #expect(pythonPlan.launchPlan.toolchainID == "project-python")
        #expect(pythonPlan.launchPlan.arguments == ["-m", "pytest", "tests/test_api.py::test_health"])

        let javaProvider = try #require(registry.provider(id: "java"))
        let javaPlan = try javaProvider.testPlan(scope: .file(files[0]), workspaceURL: root)
        #expect(javaPlan.launchPlan.toolchainID == "project-maven")
        #expect(javaPlan.launchPlan.arguments == ["-Dtest=UserServiceTest", "test"])

        let gradlePlan = try javaProvider.testPlan(
            scope: .workspace,
            context: LanguageTestContext(
                workspaceURL: root,
                projectFiles: [root.appendingPathComponent("build.gradle.kts")]
            )
        )
        #expect(gradlePlan.frameworkID == "gradle")
        #expect(gradlePlan.launchPlan.arguments == ["test"])
        if case .toolchain(let executable) = gradlePlan.launchPlan.executable {
            #expect(executable == "project-gradle")
        } else {
            Issue.record("Expected Gradle projects to use the registered Gradle toolchain")
        }

        let nodeProvider = try #require(registry.provider(id: "node"))
        let nodePlan = try nodeProvider.testPlan(scope: .workspace, workspaceURL: root)
        if case .command(let executable) = nodePlan.launchPlan.executable {
            #expect(executable == "npm")
        } else {
            Issue.record("Expected the Node test provider to use npm")
        }
        #expect(nodePlan.launchPlan.arguments == ["test", "--"])

        let pnpmPlan = try nodeProvider.testPlan(
            scope: .testCase(identifier: "parses", fileURL: files[3]),
            context: LanguageTestContext(
                workspaceURL: root,
                projectFiles: [root.appendingPathComponent("pnpm-lock.yaml")]
            )
        )
        #expect(pnpmPlan.frameworkID == "pnpm")
        #expect(pnpmPlan.launchPlan.arguments == ["test", "--", "web/src/app.spec.ts", "-t", "parses"])

        let rustProvider = try #require(registry.provider(id: "rust"))
        let rustPlan = try rustProvider.testPlan(scope: .file(files[4]), workspaceURL: root)
        #expect(rustPlan.launchPlan.toolchainID == "project-cargo")
        #expect(rustPlan.launchPlan.arguments == ["test", "--test", "parser"])
    }

    @Test
    func testDiscoveryDoesNotInventAFrameworkForAPlainWorkspace() throws {
        let root = URL(fileURLWithPath: "/tmp/plain-polyglot", isDirectory: true)
        let javaFile = root.appendingPathComponent("src/test/java/PlainTest.java")
        let nodeFile = root.appendingPathComponent("src/app.spec.ts")
        let registry = LanguageTestProviderRegistry.standard()
        let javaProvider = try #require(registry.provider(id: "java"))
        let nodeProvider = try #require(registry.provider(id: "node"))

        #expect(javaProvider.discoverTests(context: LanguageTestContext(
            workspaceURL: root,
            projectFiles: [javaFile]
        )).isEmpty)
        #expect(nodeProvider.discoverTests(context: LanguageTestContext(
            workspaceURL: root,
            projectFiles: [nodeFile]
        )).isEmpty)
        #expect(throws: LanguageTestPlanError.unsupportedProvider("Java")) {
            _ = try javaProvider.testPlan(
                scope: .file(javaFile),
                context: LanguageTestContext(
                    workspaceURL: root,
                    projectFiles: [javaFile]
                )
            )
        }

        let mavenItems = javaProvider.discoverTests(context: LanguageTestContext(
            workspaceURL: root,
            projectFiles: [
                javaFile,
                root.appendingPathComponent("pom.xml")
            ]
        ))
        #expect(mavenItems.count == 2)
        #expect(mavenItems.last?.fileURL == javaFile.standardizedFileURL)
    }

    @Test
    func testProvidersRejectFilesOutsideTheWorkspace() throws {
        let provider = try #require(LanguageTestProviderRegistry.standard().provider(id: "python"))
        #expect(throws: LanguageTestPlanError.fileOutsideWorkspace(
            URL(fileURLWithPath: "/tmp/outside/test_api.py")
        )) {
            _ = try provider.testPlan(
                scope: .file(URL(fileURLWithPath: "/tmp/outside/test_api.py")),
                workspaceURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            )
        }
    }

    @Test
    func languageTestServiceDiscoversWithoutStartingAndRunsOnDemand() async throws {
        let root = URL(fileURLWithPath: "/tmp/language-test-service", isDirectory: true)
        let source = root.appendingPathComponent("cmd/api/api_test.go")
        let manifest = root.appendingPathComponent("go.mod")
        let processFactory = RecordingProcessFactory()
        let resolver = RecordingRunExecutableResolver()
        let service = LanguageTestService(
            executableResolver: resolver,
            processFactory: { processFactory.make() }
        )

        service.discover(workspaceURL: root, files: [source, manifest])
        #expect(processFactory.processes.isEmpty)
        #expect(service.itemsByProviderID["go"]?.count == 2)

        let didStart = service.run(
            providerID: "go",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [source, manifest]
        )
        #expect(didStart)
        #expect(processFactory.processes.count == 1)
        #expect(resolver.resolveCalls == 1)
        #expect(service.state == .running)
        #expect(processFactory.processes[0].requests.first?.arguments == ["test", "./cmd/api"])

        processFactory.processes[0].onOutput?("ok\n")
        processFactory.processes[0].onTermination?(0)
        await Task.yield()
        await Task.yield()

        #expect(service.state == .passed)
        #expect(service.output.contains("ok"))
    }

    @Test
    func rustDebugLaunchResolvesTheClosestCargoBinaryArtifact() throws {
        let root = URL(fileURLWithPath: "/tmp/rust-debug-workspace", isDirectory: true)
        let source = root.appendingPathComponent("worker/src/main.rs")
        let expectedExecutable = root.appendingPathComponent("worker/build/debug/worker-api")
        let configuration = RunConfiguration(
            id: "cargo.binary:worker/worker-api",
            name: "worker-api",
            kind: .process(provider: "cargo.binary"),
            execution: .application,
            modulePath: "worker",
            mainClass: nil
        )
        let resolver = DebugLaunchConfigurationResolver { url in
            url.standardizedFileURL == expectedExecutable.standardizedFileURL
        }
        let provider = try #require(LanguageProviderCatalog.standard.provider(for: source))

        let launch = try resolver.resolve(
            provider: provider,
            documentURL: source,
            workspaceURL: root,
            configurations: [configuration],
            selectedConfiguration: nil,
            options: { _ in RunOptions(environment: ["CARGO_TARGET_DIR": "build"]) }
        )

        #expect(launch.name == "worker-api")
        #expect(launch.arguments["program"] == .string(expectedExecutable.path))
        #expect(launch.arguments["cwd"] == .string(root.appendingPathComponent("worker").path))
    }

    @Test
    func rustDebugLaunchExplainsHowToBuildAMissingArtifact() throws {
        let root = URL(fileURLWithPath: "/tmp/rust-debug-missing", isDirectory: true)
        let source = root.appendingPathComponent("src/main.rs")
        let configuration = RunConfiguration(
            id: "cargo.binary:server",
            name: "server",
            kind: .process(provider: "cargo.binary"),
            execution: .application,
            modulePath: nil,
            mainClass: nil
        )
        let resolver = DebugLaunchConfigurationResolver(fileExists: { _ in false })
        let provider = try #require(LanguageProviderCatalog.standard.provider(for: source))

        do {
            _ = try resolver.resolve(
                provider: provider,
                documentURL: source,
                workspaceURL: root,
                configurations: [configuration],
                selectedConfiguration: configuration,
                options: { _ in RunOptions() }
            )
            Issue.record("Expected a missing Rust artifact error")
        } catch let error as DebugLaunchConfigurationResolutionError {
            guard case .rustExecutableNotBuilt(let url, let binary) = error else {
                Issue.record("Unexpected resolver error: \(error)")
                return
            }
            #expect(binary == "server")
            #expect(url.path == root.appendingPathComponent("target/debug/server").path)
            #expect(error.localizedDescription.contains("cargo build --bin server"))
        }
    }

    @Test
    func goDebugLaunchUsesTheNearestDetectedCommandDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/go-debug-workspace", isDirectory: true)
        let source = root.appendingPathComponent("cmd/gateway/main.go")
        let configuration = RunConfiguration(
            id: "go.command:cmd/gateway/gateway",
            name: "gateway",
            kind: .process(provider: "go.command"),
            execution: .application,
            modulePath: "cmd/gateway",
            mainClass: nil
        )
        let resolver = DebugLaunchConfigurationResolver(fileExists: { _ in false })
        let provider = try #require(LanguageProviderCatalog.standard.provider(for: source))

        let launch = try resolver.resolve(
            provider: provider,
            documentURL: source,
            workspaceURL: root,
            configurations: [configuration],
            selectedConfiguration: nil,
            options: { _ in RunOptions() }
        )

        let commandURL = root.appendingPathComponent("cmd/gateway").standardizedFileURL
        #expect(launch.name == "gateway")
        #expect(launch.arguments["mode"] == .string("debug"))
        #expect(launch.arguments["program"] == .string(commandURL.path))
        #expect(launch.arguments["cwd"] == .string(commandURL.path))
    }

    @Test
    func nodeDebugLaunchUsesTheNearestNPMScriptAndGenericOptions() throws {
        let root = URL(fileURLWithPath: "/tmp/node-debug-workspace", isDirectory: true)
        let source = root.appendingPathComponent("apps/web/src/server.ts")
        let configuration = RunConfiguration(
            id: "npm.script:apps/web/dev",
            name: "dev",
            kind: .process(provider: "npm.script"),
            execution: .service,
            modulePath: "apps/web",
            mainClass: nil
        )
        let resolver = DebugLaunchConfigurationResolver(fileExists: { _ in false })
        let provider = try #require(LanguageProviderCatalog.standard.provider(for: source))

        let launch = try resolver.resolve(
            provider: provider,
            documentURL: source,
            workspaceURL: root,
            configurations: [configuration],
            selectedConfiguration: nil,
            options: { _ in
                RunOptions(
                    programArguments: "--port 4100 --name \"web api\"",
                    environment: ["NODE_ENV": "development"]
                )
            }
        )

        #expect(launch.name == "dev")
        #expect(launch.arguments["type"] == .string("pwa-node"))
        #expect(launch.arguments["runtimeExecutable"] == .string("npm"))
        #expect(launch.arguments["runtimeArgs"] == .array([.string("run"), .string("dev")]))
        #expect(launch.arguments["cwd"] == .string(root.appendingPathComponent("apps/web").path))
        #expect(launch.arguments["args"] == .array([
            .string("--port"), .string("4100"), .string("--name"), .string("web api")
        ]))
        #expect(launch.arguments["env"] == .object(["NODE_ENV": .string("development")]))
    }

    @Test
    func nodeDebugLaunchFallsBackToTheCurrentJavaScriptFile() throws {
        let root = URL(fileURLWithPath: "/tmp/node-current-file", isDirectory: true)
        let source = root.appendingPathComponent("scripts/worker.mjs")
        let resolver = DebugLaunchConfigurationResolver(fileExists: { _ in false })
        let provider = try #require(LanguageProviderCatalog.standard.provider(for: source))

        let launch = try resolver.resolve(
            provider: provider,
            documentURL: source,
            workspaceURL: root,
            configurations: [],
            selectedConfiguration: nil,
            options: { _ in RunOptions() }
        )

        #expect(launch.name == "worker.mjs")
        #expect(launch.arguments["program"] == .string(source.path))
        #expect(launch.arguments["runtimeExecutable"] == nil)
    }

    @Test
    func delveTransportQueuesDAPBytesUntilTheTCPAnnouncementIsReady() async throws {
        let process = RecordingRawProcessSession()
        let socket = TestDlvSocketConnection()
        var endpoint: (String, UInt16)?
        let transport = MacDlvDebugAdapterTransport(
            executableURL: URL(fileURLWithPath: "/toolchains/dlv"),
            environment: ["PATH": "/toolchains"],
            process: process,
            socketFactory: { host, port in
                endpoint = (host, port)
                return socket
            }
        )
        var received: [Data] = []
        transport.onData = { received.append($0) }
        let initializeFrame = Data("Content-Length: 2\r\n\r\n{}".utf8)

        try transport.start(rootURL: URL(fileURLWithPath: "/tmp/go-dap"))
        try transport.send(initializeFrame)
        #expect(socket.sent.isEmpty)
        let request = try #require(process.requests.first)
        #expect(request.executablePath == "/toolchains/dlv")
        #expect(request.arguments == ["dap", "--listen=127.0.0.1:0"])
        #expect(request.keepsStandardInputOpen == false)

        process.onError?(Data("DAP server listening at: 127.0.0.1:43127\n".utf8))
        await Self.drainMainActorTasks()
        #expect(endpoint?.0 == "127.0.0.1")
        #expect(endpoint?.1 == 43127)
        #expect(socket.startCount == 1)
        #expect(socket.sent.isEmpty)

        socket.onReady?()
        #expect(socket.sent == [initializeFrame])
        let response = Data("Content-Length: 2\r\n\r\n{}".utf8)
        socket.onData?(response)
        #expect(received == [response])
    }

    @Test
    func nodeTransportDiscoversTheOfficialBundleAndQueuesUntilTCPIsReady() async throws {
        let root = URL(fileURLWithPath: "/tmp/node-dap", isDirectory: true)
        let adapterRoot = root.appendingPathComponent(".lithe/toolchains/js-debug")
        let adapterScript = adapterRoot.appendingPathComponent("js-debug/src/dapDebugServer.js")
        let process = RecordingRawProcessSession()
        let socket = TestDlvSocketConnection()
        var endpoint: (String, UInt16)?
        let locator = MacJavaScriptDebugAdapterLocator(
            environment: ["PATH": "/toolchains"],
            homeDirectoryURL: URL(fileURLWithPath: "/users/test", isDirectory: true),
            fileExists: { $0.standardizedFileURL.path == adapterScript.standardizedFileURL.path },
            isDirectory: { $0.standardizedFileURL.path == adapterRoot.standardizedFileURL.path },
            executableOnPath: { _ in nil }
        )
        let transport = MacNodeDebugAdapterTransport(
            nodeExecutableURL: URL(fileURLWithPath: "/toolchains/node"),
            locator: locator,
            process: process,
            socketFactory: { host, port in
                endpoint = (host, port)
                return socket
            }
        )
        let initializeFrame = Data("Content-Length: 2\r\n\r\n{}".utf8)

        try transport.start(rootURL: root)
        try transport.send(initializeFrame)
        let request = try #require(process.requests.first)
        #expect(request.executablePath == "/toolchains/node")
        #expect(request.arguments == [adapterScript.path, "0", "127.0.0.1"])
        #expect(request.keepsStandardInputOpen == false)
        #expect(socket.sent.isEmpty)

        process.onOutput?(Data("Debug server listening at 127.0.0.1:49321\n".utf8))
        await Self.drainMainActorTasks()
        #expect(endpoint?.0 == "127.0.0.1")
        #expect(endpoint?.1 == 49321)
        socket.onReady?()
        #expect(socket.sent == [initializeFrame])
    }

    @Test
    func nodeProviderCreatesItsDebugSessionOnlyOnDemand() throws {
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        var factoryCalls = 0
        let expected = TestDebugAdapterSession()
        let runtimes = StdioLanguageProviderRuntime.standard(
            catalog: .standard,
            runtimeService: runtimeService,
            processFactory: { RecordingRawProcessSession() },
            debugSessionFactories: [
                "node": {
                    factoryCalls += 1
                    return expected
                }
            ]
        )
        let node = try #require(runtimes.first(where: { $0.descriptor.id == "node" }))

        #expect(factoryCalls == 0)
        let created = try #require(node.makeDebugAdapterSession())
        #expect(factoryCalls == 1)
        #expect(created === expected)
    }

    @Test
    func goProviderCreatesItsInjectedTCPDebugSessionOnlyOnDemand() throws {
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        var factoryCalls = 0
        let expected = TestDebugAdapterSession()
        let runtimes = StdioLanguageProviderRuntime.standard(
            catalog: .standard,
            runtimeService: runtimeService,
            processFactory: { RecordingRawProcessSession() },
            debugSessionFactories: [
                "go": {
                    factoryCalls += 1
                    return expected
                }
            ]
        )
        let go = try #require(runtimes.first(where: { $0.descriptor.id == "go" }))

        #expect(factoryCalls == 0)
        let created = try #require(go.makeDebugAdapterSession())
        #expect(factoryCalls == 1)
        #expect(created === expected)
    }

    @Test
    func editorDiagnosticsMergeLanguagesAndMapLSPSeverities() throws {
        let javaURL = URL(fileURLWithPath: "/tmp/mixed/src/Main.java")
        let pythonURL = URL(fileURLWithPath: "/tmp/mixed/api/main.py")
        let javaDiagnostic = EditorDiagnostic(
            id: "java-warning",
            fileURL: javaURL,
            line: 2,
            utf16Column: 4,
            endLine: 2,
            endUTF16Column: 8,
            severity: .warning,
            message: "Java warning",
            source: "java",
            code: "java-warning",
            tags: [],
            relatedInformation: []
        )
        let severities = [1, 2, 3, 4]
        let languageDiagnostics = severities.map { severity in
            LanguageServerDiagnostic(
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: severity, utf16Column: 0),
                    end: LanguageServerPosition(line: severity, utf16Column: 3)
                ),
                severity: severity,
                message: "Python diagnostic \(severity)",
                source: "pyright",
                code: "python-\(severity)"
            )
        }

        let merged = EditorDiagnostic.merging(
            [javaURL: [javaDiagnostic]],
            languageServerDiagnostics: [pythonURL: languageDiagnostics]
        )

        #expect(merged[javaURL.standardizedFileURL] == [javaDiagnostic])
        let python = try #require(merged[pythonURL.standardizedFileURL])
        #expect(python.map(\.severity) == [.error, .warning, .information, .hint])
        #expect(python.allSatisfy { $0.source == "pyright" })
    }

    @Test
    func editorDiagnosticsDeduplicateTheSameProviderResult() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/mixed/src/Main.java")
        let lsp = LanguageServerDiagnostic(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 3, utf16Column: 7),
                end: LanguageServerPosition(line: 3, utf16Column: 10)
            ),
            severity: 1,
            message: "Cannot resolve symbol",
            source: "java",
            code: "resolve"
        )
        let existing = EditorDiagnostic(languageServerDiagnostic: lsp, fileURL: fileURL)

        let merged = EditorDiagnostic.merging(
            [fileURL: [existing]],
            languageServerDiagnostics: [fileURL: [lsp]]
        )

        #expect(merged[fileURL.standardizedFileURL] == [existing])
    }

    @Test
    func runOptionsDecodeLegacyJavaPreferencesIntoGenericFields() throws {
        let data = Data(
            #"{"javaHomePath":"/jdk","workingDirectoryPath":"backend","vmArguments":"-Xmx1g","programArguments":"--port 8080","activeProfiles":["dev"]}"#.utf8
        )
        let options = try JSONDecoder().decode(RunOptions.self, from: data)

        #expect(options.javaHomePath == "/jdk")
        #expect(options.workingDirectoryPath == "backend")
        #expect(options.vmArguments == "-Xmx1g")
        #expect(options.arguments == "--port 8080")
        #expect(options.activeProfiles == ["dev"])
    }

    @Test
    func executableResolverRejectsUnknownToolchainsInsteadOfUsingMaven() throws {
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-unknown"),
            arguments: [],
            workingDirectory: "."
        )

        #expect(throws: RunExecutableResolutionError.self) {
            try resolver.resolve(
                plan,
                projectURL: URL(fileURLWithPath: "/tmp/lithe-toolchain-test"),
                options: RunOptions()
            )
        }
    }

    @Test
    func commandResolverLayersGenericEnvironmentWithoutJavaInjection() throws {
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let plan = SharedLaunchPlan(
            executable: .command("python3"),
            arguments: ["app.py"],
            workingDirectory: ".",
            environment: ["FROM_PLAN": "yes"]
        )
        let resolved = try resolver.resolve(
            plan,
            projectURL: URL(fileURLWithPath: "/tmp/lithe-command-test"),
            options: RunOptions(environment: ["APP_ENV": "test"])
        )

        #expect(resolved.executableURL.path == "/usr/bin/python3")
        #expect(resolved.environment["PATH"] == "/usr/bin")
        #expect(resolved.environment["FROM_PLAN"] == "yes")
        #expect(resolved.environment["APP_ENV"] == "test")
        #expect(resolved.environment["JAVA_HOME"] == nil)
    }

    @Test
    func registeredGoToolchainResolvesWithoutMavenFallback() throws {
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let resolved = try resolver.resolve(
            SharedLaunchPlan(
                executable: .toolchain("project-go"),
                arguments: ["run", "."],
                workingDirectory: "."
            ),
            projectURL: URL(fileURLWithPath: "/tmp/lithe-go-toolchain"),
            options: RunOptions(environment: ["GO_ENV": "test"])
        )

        #expect(resolved.executableURL.path == "/usr/bin/go")
        #expect(resolved.environment["GO_ENV"] == "test")
        #expect(resolved.environment["JAVA_HOME"] == nil)
    }

    @Test
    func registeredGradleToolchainPrefersTheProjectWrapper() throws {
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let resolved = try resolver.resolve(
            SharedLaunchPlan(
                executable: .toolchain("project-gradle"),
                arguments: ["test"],
                workingDirectory: "."
            ),
            projectURL: URL(fileURLWithPath: "/tmp/gradle-project"),
            options: RunOptions()
        )

        #expect(resolved.executableURL.path == "/tmp/gradle-project/gradlew")
        #expect(resolved.environment["JAVA_HOME"] == nil)
    }

    @Test
    func genericToolchainVersionsAreProbedOffTheResolutionPathAndCachedPerAlias() async throws {
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let runner = ToolchainVersionProcessRunner()
        let resolver = RunExecutableResolver(
            runtimeService: runtime,
            metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: runner)
        )
        let root = URL(fileURLWithPath: "/tmp/lithe-version-probes")

        #expect(resolver.candidates(projectURL: root).first { $0.id == "project-go" }?.version == "")
        await resolver.refreshCandidates(projectURL: root)
        let candidates = Dictionary(uniqueKeysWithValues: resolver.candidates(projectURL: root).map {
            ($0.id, $0)
        })

        #expect(candidates["project-go"]?.version == "1.24.3")
        #expect(candidates["project-python"]?.version == "3.13.5")
        #expect(candidates["project-node"]?.version == "22.18.0")
        #expect(candidates["project-cargo"]?.version == "1.89.0")
        #expect(runner.executedCommands.sorted() == ["go", "node", "python3", "rustc"])
    }

    @Test
    func languageToolingSessionsKeepSwiftLSPAtTheRustHostBoundary() throws {
        let descriptor = try #require(LanguageProviderCatalog.standard.provider(
            for: URL(fileURLWithPath: "/tmp/main.go")
        ))
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let process = RecordingRawProcessSession()
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            processFactory: { process }
        )
        let manager = LanguageToolingSessionManager(runtimes: [runtime])
        let root = URL(fileURLWithPath: "/tmp/go-project", isDirectory: true)
        let source = root.appendingPathComponent("main.go")

        #expect(manager.activeLanguageServerIDs.isEmpty)
        #expect(manager.features(for: source).isEmpty)
        #expect(!manager.supportsGenericEditing(for: source))
        try manager.synchronizeLanguageServer(
            for: source,
            text: "package main\nfunc main() {}\n",
            rootURL: root
        )
        #expect(process.requests.isEmpty)
        #expect(process.sentData.isEmpty)

        #expect(throws: LanguageToolingSessionError.self) {
            try manager.hover(
                fileURL: source,
                text: "package main\n",
                position: LanguageServerPosition(line: 0, utf16Column: 0),
                rootURL: root
            ) { _ in }
        }
        #expect(throws: LanguageToolingSessionError.self) {
            try manager.format(fileURL: source, text: "package main\n", rootURL: root) { _ in }
        }
        #expect(manager.activeLanguageServerIDs.isEmpty)
    }

    @Test
    func languageServerRuntimeStartsFromRustCatalogLaunchMetadata() async throws {
        let descriptor = LanguageProviderDescriptor(
            id: "swift",
            displayName: "Swift",
            fileExtensions: ["swift"],
            capabilities: [.languageServer, .formatting],
            activationPolicy: .onDemand,
            languageIdentifier: "swift",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["sourcekit-lsp"],
                arguments: []
            )
        )
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let process = RecordingRawProcessSession()
        let root = URL(fileURLWithPath: "/tmp/swift-project", isDirectory: true)
        let source = root.appendingPathComponent("App.swift")
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            processFactory: { process },
            languageServerLaunch: descriptor.languageServerLaunch,
            languageServerCore: TestLspClientCore(diagnosticURL: source)
        )
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime]
        )

        try manager.synchronizeLanguageServer(
            for: source,
            text: "struct App {}\n",
            rootURL: root
        )
        let startRequest = try #require(process.requests.first)
        #expect(startRequest.executablePath == "/usr/bin/sourcekit-lsp")
        #expect(startRequest.arguments.isEmpty)
        #expect(manager.activeLanguageServerIDs == ["swift"])
        #expect(String(data: try #require(process.sentData.first), encoding: .utf8)?.contains("\"method\":\"initialize\"") == true)

        process.emitJSON([
            "jsonrpc": "2.0",
            "id": "1",
            "result": [
                "capabilities": [
                    "hoverProvider": true,
                    "completionProvider": [:]
                ]
            ]
        ])
        await Self.drainMainActorTasks()

        let framedOutput = process.sentData.compactMap { String(data: $0, encoding: .utf8) }.joined()
        #expect(framedOutput.contains("\"method\":\"initialized\""))
        #expect(framedOutput.contains("\"method\":\"textDocument/didOpen\""))

        process.emitJSON([
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": source.standardizedFileURL.absoluteString,
                "diagnostics": [[
                    "range": [
                        "start": ["line": 0, "character": 7],
                        "end": ["line": 0, "character": 10]
                    ],
                    "severity": 2,
                    "source": "sourcekit-lsp",
                    "message": "example warning"
                ]]
            ]
        ])
        await Self.drainMainActorTasks()
        #expect(manager.diagnostics[source.standardizedFileURL]?.first?.message == "example warning")

        var completionsResult: Result<[LanguageServerCompletionItem], Error>?
        try manager.completions(
            fileURL: source,
            text: "struct App { let tit }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 20),
            rootURL: root
        ) { result in
            completionsResult = result
        }
        #expect(process.sentData.compactMap { String(data: $0, encoding: .utf8) }.joined()
            .contains("\"method\":\"textDocument/completion\""))
        process.emitJSON([
            "jsonrpc": "2.0",
            "id": "2",
            "result": [
                "items": [[
                    "label": "title",
                    "insertText": "title",
                    "kind": 6,
                    "detail": "String"
                ]]
            ]
        ])
        await Self.drainMainActorTasks()
        #expect(try completionsResult?.get().first?.label == "title")

        var renameResult: Result<LanguageServerWorkspaceEdit, Error>?
        try manager.rename(
            fileURL: source,
            text: "struct App { let title = 1 }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 17),
            newName: "headline",
            rootURL: root
        ) { result in
            renameResult = result
        }
        process.emitJSON([
            "jsonrpc": "2.0",
            "id": "3",
            "result": [
                "changes": [
                    source.standardizedFileURL.absoluteString: [[
                        "range": [
                            "start": ["line": 0, "character": 17],
                            "end": ["line": 0, "character": 22]
                        ],
                        "newText": "headline"
                    ]]
                ]
            ]
        ])
        await Self.drainMainActorTasks()
        #expect(try renameResult?.get().changes[source.standardizedFileURL]?.first?.newText == "headline")

        var formatResult: Result<[LanguageServerTextEdit], Error>?
        try manager.format(
            fileURL: source,
            text: "struct App{ }\n",
            rootURL: root
        ) { result in
            formatResult = result
        }
        process.emitJSON([
            "jsonrpc": "2.0",
            "id": "4",
            "result": [[
                "range": [
                    "start": ["line": 0, "character": 10],
                    "end": ["line": 0, "character": 10]
                ],
                "newText": " "
            ]]
        ])
        await Self.drainMainActorTasks()
        #expect(try formatResult?.get().first?.newText == " ")

        var actionsResult: Result<[LanguageServerCodeAction], Error>?
        try manager.codeActions(
            fileURL: source,
            text: "struct App{ }\n",
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 0, utf16Column: 0),
                end: LanguageServerPosition(line: 0, utf16Column: 0)
            ),
            diagnostics: [
                LanguageServerDiagnostic(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: 0, utf16Column: 7),
                        end: LanguageServerPosition(line: 0, utf16Column: 10)
                    ),
                    severity: 2,
                    message: "example warning",
                    source: "sourcekit-lsp",
                    code: nil
                )
            ],
            rootURL: root
        ) { result in
            actionsResult = result
        }
        process.emitJSON([
            "jsonrpc": "2.0",
            "id": "5",
            "result": [[
                "title": "Fix warning",
                "kind": "quickfix",
                "isPreferred": true,
                "command": [
                    "title": "Apply fix",
                    "command": "source.fix",
                    "arguments": [["uri": source.standardizedFileURL.absoluteString]]
                ],
                "data": ["token": "fix-1"]
            ]]
        ])
        await Self.drainMainActorTasks()
        let actions = try actionsResult?.get()
        #expect(actions?.first?.title == "Fix warning")
        #expect(actions?.first?.command?.command == "source.fix")
    }

    @Test
    func stoppingToolingSessionsClearsProjectScopedBreakpoints() throws {
        let descriptor = try #require(LanguageProviderCatalog.standard.provider(
            for: URL(fileURLWithPath: "/tmp/main.py")
        ))
        let runtime = TestDebugLanguageProviderRuntime(descriptor: descriptor)
        let manager = LanguageToolingSessionManager(catalog: .standard, runtimes: [runtime])
        let firstRoot = URL(fileURLWithPath: "/tmp/first-python-project")
        let firstSource = firstRoot.appendingPathComponent("main.py")
        try manager.setDebugBreakpoints([DebugSourceBreakpoint(line: 12)], in: firstSource)

        _ = try manager.activateDebugAdapter(for: firstSource, rootURL: firstRoot)
        #expect(runtime.debugAdapters.first?.breakpointUpdates.count == 1)
        manager.stopAll()

        let secondRoot = URL(fileURLWithPath: "/tmp/second-python-project")
        _ = try manager.activateDebugAdapter(
            for: secondRoot.appendingPathComponent("main.py"),
            rootURL: secondRoot
        )
        #expect(runtime.debugAdapters.count == 2)
        #expect(runtime.debugAdapters.last?.breakpointUpdates.isEmpty == true)
    }

    @Test
    func stdioDebugAdapterImplementsLaunchBreakpointsInspectionAndControl() async throws {
        let descriptor = try #require(LanguageProviderCatalog.standard.provider(
            for: URL(fileURLWithPath: "/tmp/main.py")
        ))
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let process = RecordingRawProcessSession()
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            processFactory: { process },
            debugLaunch: StdioDebugAdapterLaunch(
                adapterID: "python",
                executableNames: ["python3"],
                arguments: ["-m", "debugpy.adapter"]
            )
        )
        let manager = LanguageToolingSessionManager(runtimes: [runtime])
        let root = URL(fileURLWithPath: "/tmp/python-project", isDirectory: true)
        let source = root.appendingPathComponent("main.py")
        try manager.setDebugBreakpoints([DebugSourceBreakpoint(line: 7)], in: source)

        let session = try manager.activateDebugAdapter(for: source, rootURL: root)
        let controlling = try #require(session as? any DebugAdapterControllingSession)
        let processRequest = try #require(process.requests.first)
        #expect(processRequest.executablePath == "/usr/bin/python3")
        #expect(processRequest.arguments == ["-m", "debugpy.adapter"])
        #expect(manager.debugStates["python"] == .initializing)
        let initialize = try #require(Self.debugRequest(named: "initialize", in: process.sentData))
        let initializeSequence = try #require(initialize["seq"] as? Int)

        _ = try manager.launchDebugAdapter(
            for: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Python Current File",
                request: .launch,
                arguments: [
                    "program": .string(source.path),
                    "console": .string("internalConsole"),
                    "justMyCode": .bool(true)
                ]
            )
        )
        #expect(Self.debugRequest(named: "launch", in: process.sentData) == nil)

        process.emitJSON([
            "seq": 1,
            "type": "response",
            "request_seq": initializeSequence,
            "success": true,
            "command": "initialize",
            "body": ["supportsConfigurationDoneRequest": true]
        ])
        await Self.drainMainActorTasks()
        #expect(controlling.state == .launching)
        #expect(manager.debugStates["python"] == .launching)
        let launch = try #require(Self.debugRequest(named: "launch", in: process.sentData))
        let launchSequence = try #require(launch["seq"] as? Int)
        let launchArguments = try #require(launch["arguments"] as? [String: Any])
        #expect(launchArguments["program"] as? String == source.path)
        #expect(launchArguments["cwd"] as? String == root.path)

        process.emitJSON(["seq": 2, "type": "event", "event": "initialized", "body": [:]])
        await Self.drainMainActorTasks()
        let setBreakpoints = try #require(Self.debugRequest(named: "setBreakpoints", in: process.sentData))
        let breakpointSequence = try #require(setBreakpoints["seq"] as? Int)
        let breakpointArguments = try #require(setBreakpoints["arguments"] as? [String: Any])
        let requested = try #require(breakpointArguments["breakpoints"] as? [[String: Any]])
        #expect(requested.first?["line"] as? Int == 7)
        let configurationDone = try #require(Self.debugRequest(named: "configurationDone", in: process.sentData))
        let configurationDoneSequence = try #require(configurationDone["seq"] as? Int)

        process.emitJSON([
            "seq": 3,
            "type": "response",
            "request_seq": breakpointSequence,
            "success": true,
            "command": "setBreakpoints",
            "body": ["breakpoints": [[
                "id": 91,
                "verified": true,
                "line": 7,
                "source": ["path": source.path]
            ]]]
        ])
        process.emitJSON([
            "seq": 4, "type": "response", "request_seq": configurationDoneSequence,
            "success": true, "command": "configurationDone", "body": [:]
        ])
        process.emitJSON([
            "seq": 5, "type": "response", "request_seq": launchSequence,
            "success": true, "command": "launch", "body": [:]
        ])
        await Self.drainMainActorTasks()
        #expect(manager.verifiedBreakpoints["python"]?.first?.verified == true)
        #expect(controlling.state == .running)

        process.emitJSON([
            "seq": 6,
            "type": "event",
            "event": "stopped",
            "body": ["reason": "breakpoint", "threadId": 42, "description": "Paused on breakpoint"]
        ])
        await Self.drainMainActorTasks()
        #expect(controlling.state == .paused)
        #expect(manager.lastDebugEvents["python"] == .stopped(
            reason: "breakpoint",
            threadID: 42,
            description: "Paused on breakpoint"
        ))

        var threadsResult: Result<[DebugThread], Error>?
        controlling.requestThreads { threadsResult = $0 }
        let threadsRequest = try #require(Self.debugRequest(named: "threads", in: process.sentData))
        process.emitJSON([
            "seq": 7, "type": "response", "request_seq": threadsRequest["seq"] as! Int,
            "success": true, "command": "threads",
            "body": ["threads": [["id": 42, "name": "MainThread"]]]
        ])
        await Self.drainMainActorTasks()
        #expect(try threadsResult?.get() == [DebugThread(id: 42, name: "MainThread")])

        var stackResult: Result<[DebugStackFrame], Error>?
        controlling.requestStackTrace(threadID: 42) { stackResult = $0 }
        let stackRequest = try #require(Self.debugRequest(named: "stackTrace", in: process.sentData))
        process.emitJSON([
            "seq": 8, "type": "response", "request_seq": stackRequest["seq"] as! Int,
            "success": true, "command": "stackTrace",
            "body": ["stackFrames": [[
                "id": 100, "name": "main", "line": 7, "column": 1,
                "source": ["path": source.path]
            ]]]
        ])
        await Self.drainMainActorTasks()
        let frame = try #require(try stackResult?.get().first)
        #expect(frame.id == 100)
        #expect(frame.sourceURL == source.standardizedFileURL)

        var scopesResult: Result<[DebugScope], Error>?
        controlling.requestScopes(frameID: frame.id) { scopesResult = $0 }
        let scopesRequest = try #require(Self.debugRequest(named: "scopes", in: process.sentData))
        process.emitJSON([
            "seq": 9, "type": "response", "request_seq": scopesRequest["seq"] as! Int,
            "success": true, "command": "scopes",
            "body": ["scopes": [[
                "name": "Locals", "variablesReference": 200, "expensive": false
            ]]]
        ])
        await Self.drainMainActorTasks()
        let scope = try #require(try scopesResult?.get().first)
        #expect(scope.variablesReference == 200)

        var variablesResult: Result<[DebugVariable], Error>?
        controlling.requestVariables(reference: scope.variablesReference) { variablesResult = $0 }
        let variablesRequest = try #require(Self.debugRequest(named: "variables", in: process.sentData))
        process.emitJSON([
            "seq": 10, "type": "response", "request_seq": variablesRequest["seq"] as! Int,
            "success": true, "command": "variables",
            "body": ["variables": [[
                "name": "count", "value": "3", "type": "int",
                "evaluateName": "count", "variablesReference": 0
            ]]]
        ])
        await Self.drainMainActorTasks()
        #expect(try variablesResult?.get().first?.value == "3")

        var evaluateResult: Result<DebugVariable, Error>?
        controlling.evaluate("count + 1", frameID: frame.id) { evaluateResult = $0 }
        let evaluateRequest = try #require(Self.debugRequest(named: "evaluate", in: process.sentData))
        process.emitJSON([
            "seq": 11, "type": "response", "request_seq": evaluateRequest["seq"] as! Int,
            "success": true, "command": "evaluate",
            "body": ["result": "4", "type": "int", "variablesReference": 0]
        ])
        await Self.drainMainActorTasks()
        #expect(try evaluateResult?.get().value == "4")

        controlling.execute(.next, threadID: 42)
        let next = try #require(Self.debugRequest(named: "next", in: process.sentData))
        process.emitJSON([
            "seq": 12, "type": "response", "request_seq": next["seq"] as! Int,
            "success": true, "command": "next", "body": [:]
        ])
        await Self.drainMainActorTasks()
        #expect(controlling.state == .running)

        manager.stopDebugAdapter(providerID: "python")
        #expect(!process.isRunning)
        #expect(manager.debugStates["python"] == .idle)
    }

    @Test
    func dapStartDebuggingCreatesAChildSessionAndRoutesInspection() async throws {
        let root = URL(fileURLWithPath: "/tmp/node-child-session", isDirectory: true)
        let source = root.appendingPathComponent("server.js")
        let parentTransport = RecordingDebugAdapterTransport()
        let session = DebugAdapterProtocolSession(adapterID: "pwa-node", transport: parentTransport)
        session.setBreakpoints([DebugSourceBreakpoint(line: 2)], in: source)

        try session.start(rootURL: root)
        try session.launch(DebugLaunchConfiguration(
            name: "Node root",
            request: .launch,
            arguments: ["type": .string("pwa-node"), "program": .string(source.path)]
        ))
        let parentInitialize = try #require(Self.debugRequest(named: "initialize", in: parentTransport.sentData))
        let parentInitializeSequence = try #require(parentInitialize["seq"] as? Int)
        parentTransport.emitJSON([
            "seq": 1, "type": "response", "request_seq": parentInitializeSequence,
            "success": true, "command": "initialize",
            "body": ["supportsConfigurationDoneRequest": true]
        ])
        parentTransport.emitJSON(["seq": 2, "type": "event", "event": "initialized", "body": [:]])
        await Self.drainMainActorTasks()
        #expect(Self.debugRequest(named: "launch", in: parentTransport.sentData) != nil)

        parentTransport.emitJSON([
            "seq": 8,
            "type": "request",
            "command": "startDebugging",
            "arguments": [
                "request": "launch",
                "configuration": [
                    "name": "server.js",
                    "type": "pwa-node",
                    "request": "launch",
                    "__pendingTargetId": "target-1",
                    "program": source.path
                ]
            ]
        ])
        await Self.drainMainActorTasks()

        let childTransport = try #require(parentTransport.children.first)
        let startResponse = try #require(parentTransport.sentData.compactMap(Self.framedJSON).first {
            $0["type"] as? String == "response" && $0["request_seq"] as? Int == 8
        })
        #expect(startResponse["success"] as? Bool == true)
        let childInitialize = try #require(Self.debugRequest(named: "initialize", in: childTransport.sentData))
        let childInitializeSequence = try #require(childInitialize["seq"] as? Int)
        childTransport.emitJSON([
            "seq": 1, "type": "response", "request_seq": childInitializeSequence,
            "success": true, "command": "initialize",
            "body": ["supportsConfigurationDoneRequest": true]
        ])
        childTransport.emitJSON(["seq": 2, "type": "event", "event": "initialized", "body": [:]])
        await Self.drainMainActorTasks()

        let childLaunch = try #require(Self.debugRequest(named: "launch", in: childTransport.sentData))
        let childArguments = try #require(childLaunch["arguments"] as? [String: Any])
        #expect(childArguments["__pendingTargetId"] as? String == "target-1")
        #expect(Self.debugRequest(named: "setBreakpoints", in: childTransport.sentData) != nil)

        childTransport.emitJSON([
            "seq": 3, "type": "event", "event": "stopped",
            "body": ["reason": "breakpoint", "threadId": 17]
        ])
        await Self.drainMainActorTasks()
        #expect(session.state == .paused)

        var threadsResult: Result<[DebugThread], Error>?
        session.requestThreads { threadsResult = $0 }
        let threadsRequest = try #require(Self.debugRequest(named: "threads", in: childTransport.sentData))
        let threadsSequence = try #require(threadsRequest["seq"] as? Int)
        childTransport.emitJSON([
            "seq": 4, "type": "response", "request_seq": threadsSequence,
            "success": true, "command": "threads",
            "body": ["threads": [["id": 17, "name": "Main Thread"]]]
        ])
        await Self.drainMainActorTasks()
        #expect(try threadsResult?.get().first?.id == 17)
    }

    @Test
    func rustDebugAdapterFallsBackToXcrunDeveloperToolDiscovery() throws {
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: XcrunOnlyRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let process = RecordingRawProcessSession()
        let runtime = try #require(StdioLanguageProviderRuntime.standard(
            catalog: .standard,
            runtimeService: runtimeService,
            processFactory: { process }
        ).first(where: { $0.descriptor.id == "rust" }))
        let adapter = try #require(runtime.makeDebugAdapterSession())

        try adapter.start(rootURL: URL(fileURLWithPath: "/tmp/rust-xcrun"))

        let request = try #require(process.requests.first)
        #expect(request.executablePath == "/usr/bin/xcrun")
        #expect(request.arguments == ["lldb-dap"])
    }

    @Test
    func genericDebugFeatureQueuesPythonLaunchDuringAdapterInitialization() async throws {
        let descriptor = try #require(LanguageProviderCatalog.standard.provider(
            for: URL(fileURLWithPath: "/tmp/app.py")
        ))
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        let process = RecordingRawProcessSession()
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            processFactory: { process },
            debugLaunch: StdioDebugAdapterLaunch(
                adapterID: "python",
                executableNames: ["python3"],
                arguments: ["-m", "debugpy.adapter"]
            )
        )
        let manager = LanguageToolingSessionManager(runtimes: [runtime])
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/python-feature", isDirectory: true)
        let source = root.appendingPathComponent("app.py")
        feature.toggleBreakpoint(fileURL: source, line: 4)

        let started = feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "app.py",
                request: .launch,
                arguments: ["program": .string(source.path)]
            )
        )

        #expect(started)
        #expect(feature.providerID == "python")
        #expect(feature.state == .initializing)
        #expect(feature.breakpoints.map(\.line) == [4])
        #expect(Self.debugRequest(named: "launch", in: process.sentData) == nil)
        let initialize = try #require(Self.debugRequest(named: "initialize", in: process.sentData))
        process.emitJSON([
            "seq": 1, "type": "response", "request_seq": initialize["seq"] as! Int,
            "success": true, "command": "initialize", "body": [:]
        ])
        await Self.drainMainActorTasks()

        #expect(feature.state == .launching)
        #expect(Self.debugRequest(named: "launch", in: process.sentData) != nil)
    }

    @Test
    func reloadingRunConfigurationsDoesNotStopAnUnrelatedProcessSession() async {
        let configuration = RunConfiguration(
            id: "python:api",
            name: "API",
            kind: .process(provider: "python.script"),
            modulePath: nil,
            mainClass: nil
        )
        let plan = SharedLaunchPlan(
            executable: .command("python3"),
            arguments: ["app.py"],
            workingDirectory: "."
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [EffectiveRunConfiguration(configuration: configuration, options: RunOptions())],
            plans: [configuration.id: plan]
        )

        await fixture.service.loadProject(at: fixture.root, files: [], mavenProject: nil)
        fixture.service.run(configuration: configuration, currentFileURL: nil)
        #expect(fixture.process.isRunning)
        let stopCountAfterStart = fixture.process.stopCount
        await fixture.service.loadProject(at: fixture.root, files: [], mavenProject: nil)
        #expect(fixture.process.isRunning)
        #expect(fixture.process.stopCount == stopCountAfterStart)
    }

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
            executable: .toolchain("project-maven"),
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
    func toolchainBackedGoPlanUsesTheRegisteredProviderInRunService() async throws {
        let configuration = RunConfiguration(
            id: "go:api",
            name: "Go API",
            kind: .process(provider: "go.main"),
            modulePath: nil,
            mainClass: nil
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", "./cmd/api"],
            workingDirectory: ".",
            environment: ["APP_ENV": "test"]
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [EffectiveRunConfiguration(configuration: configuration, options: RunOptions())],
            plans: [configuration.id: plan]
        )

        await fixture.service.loadProject(at: fixture.root, files: [], mavenProject: nil)
        fixture.service.run(configuration: configuration, currentFileURL: nil)

        let request = try #require(fixture.process.requests.last)
        #expect(request.executablePath == "/usr/bin/go")
        #expect(request.arguments == ["run", "./cmd/api"])
        #expect(request.environment?["APP_ENV"] == "test")
        #expect(request.environment?["JAVA_HOME"] == nil)
        #expect(fixture.operations.lastToolchainCandidates.contains {
            $0.id == "project-go" && $0.type == "go"
        })
    }

    @Test
    func currentFilePythonRunUsesTheLanguageProviderInsteadOfJavaCore() async throws {
        let current = RunConfiguration.currentFile
        let fixture = makeFixture(
            status: .ready,
            effective: []
        )
        let source = fixture.root.appendingPathComponent("scripts/main.py")

        await fixture.service.loadProject(
            at: fixture.root,
            files: [source],
            mavenProject: nil
        )
        #expect(fixture.service.configurations == [current])
        fixture.service.run(configuration: current, currentFileURL: source)

        let request = try #require(fixture.process.requests.last)
        #expect(request.executablePath == "/usr/bin/python3")
        #expect(request.arguments == ["scripts/main.py"])
        #expect(request.environment?["JAVA_HOME"] == nil)
        #expect(fixture.operations.launchPlanIDs.isEmpty)
    }

    @Test
    func runAllServicesUsesOneSharedLaunchPlanPerService() async throws {
        let first = JavaRunConfiguration(
            id: "module:backend",
            name: "backend",
            kind: .mavenModule,
            execution: .service,
            modulePath: "backend",
            mainClass: nil
        )
        let second = JavaRunConfiguration(
            id: "module:worker",
            name: "worker",
            kind: .mavenModule,
            execution: .service,
            modulePath: "worker",
            mainClass: nil
        )
        let firstPlan = SharedLaunchPlan(
            executable: .toolchain("project-maven"),
            arguments: ["-B", "-ntp", "-pl", "backend", "spring-boot:run"],
            workingDirectory: "."
        )
        let secondPlan = SharedLaunchPlan(
            executable: .toolchain("project-maven"),
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
        fixture.service.runAllServices()

        #expect(fixture.operations.launchPlanIDs == [first.id, second.id])
        #expect(fixture.processFactory.processes.count == 2)
        let requests = try fixture.processFactory.processes.map { try #require($0.requests.last) }
        #expect(requests.map(\.arguments) == [firstPlan.arguments, secondPlan.arguments])
        #expect(requests.map(\.workingDirectory) == [
            fixture.root.path,
            fixture.root.appendingPathComponent("worker").path
        ])
    }

    /// The concurrent-session path was written for Maven and hard-required a
    /// `project-maven` toolchain. A full-stack project has to bring up its Java
    /// service and its Node service side by side, each resolved its own way.
    @Test
    func runAllServicesStartsMavenAndProcessServicesTogether() async throws {
        let backend = JavaRunConfiguration(
            id: "module:backend",
            name: "backend",
            kind: .mavenModule,
            execution: .service,
            modulePath: "backend",
            mainClass: nil
        )
        let frontend = JavaRunConfiguration(
            id: "npm.script:frontend-web/dev",
            name: "dev",
            kind: .process(provider: "npm.script"),
            execution: .service,
            modulePath: nil,
            mainClass: nil
        )
        let backendPlan = SharedLaunchPlan(
            executable: .toolchain("project-maven"),
            arguments: ["-B", "-ntp", "-pl", "backend", "spring-boot:run"],
            workingDirectory: "."
        )
        let frontendPlan = SharedLaunchPlan(
            executable: .command("pnpm"),
            arguments: ["run", "dev"],
            workingDirectory: "frontend-web",
            environment: ["PORT": "5173"]
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [
                EffectiveRunConfiguration(configuration: backend, options: JavaRunOptions()),
                EffectiveRunConfiguration(configuration: frontend, options: JavaRunOptions())
            ],
            plans: [backend.id: backendPlan, frontend.id: frontendPlan]
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: fixture.mavenProject
        )
        fixture.service.runAllServices()

        #expect(fixture.processFactory.processes.count == 2)
        #expect(fixture.service.moduleSessions.map(\.id) == [backend.id, frontend.id])
        #expect(fixture.service.moduleSessions.allSatisfy { $0.isRunning })

        let requests = try fixture.processFactory.processes.map { try #require($0.requests.last) }
        #expect(requests[0].executablePath == "/toolchains/maven/bin/mvn")
        #expect(requests[1].executablePath == "/usr/bin/pnpm")
        #expect(requests[1].arguments == ["run", "dev"])
        #expect(requests[1].workingDirectory == fixture.root.appendingPathComponent("frontend-web").path)
        // A process plan carries its own environment and must not inherit Maven's.
        #expect(requests[1].environment?["PORT"] == "5173")
        #expect(requests[1].environment?["JAVA_HOME"] == nil)
    }

    @Test
    func runAllServicesExcludesApplicationsAndTasks() async throws {
        let service = JavaRunConfiguration(
            id: "npm.script:web/dev",
            name: "dev",
            kind: .process(provider: "npm.script"),
            execution: .service,
            modulePath: nil,
            mainClass: nil
        )
        let application = JavaRunConfiguration(
            id: "go.command:cmd/migrate/migrate",
            name: "migrate",
            kind: .process(provider: "go.command"),
            execution: .application,
            modulePath: nil,
            mainClass: nil
        )
        let task = JavaRunConfiguration(
            id: "npm.script:web/build",
            name: "build",
            kind: .process(provider: "npm.script"),
            execution: .task,
            modulePath: nil,
            mainClass: nil
        )
        let servicePlan = SharedLaunchPlan(
            executable: .command("npm"),
            arguments: ["run", "dev"],
            workingDirectory: "web"
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [service, application, task].map {
                EffectiveRunConfiguration(configuration: $0, options: JavaRunOptions())
            },
            plans: [service.id: servicePlan]
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: nil
        )
        fixture.service.runAllServices()

        #expect(fixture.operations.launchPlanIDs == [service.id])
        #expect(fixture.service.moduleSessions.map(\.id) == [service.id])
        #expect(fixture.processFactory.processes.count == 1)
    }

    /// Services start individually, not only as an all-at-once batch.
    @Test
    func startingASingleProcessServiceCreatesItsOwnSession() async throws {
        let frontend = JavaRunConfiguration(
            id: "npm.script:frontend-web/dev",
            name: "dev",
            kind: .process(provider: "npm.script"),
            execution: .service,
            modulePath: nil,
            mainClass: nil
        )
        let plan = SharedLaunchPlan(
            executable: .command("pnpm"),
            arguments: ["run", "dev"],
            workingDirectory: "frontend-web"
        )
        let fixture = makeFixture(
            status: .ready,
            effective: [EffectiveRunConfiguration(configuration: frontend, options: JavaRunOptions())],
            plans: [frontend.id: plan]
        )

        await fixture.service.loadProject(
            at: fixture.root,
            files: [],
            mavenProject: nil
        )
        fixture.service.startConfiguration(frontend)

        let session = try #require(fixture.service.moduleSessions.first)
        #expect(session.configurationID == frontend.id)
        #expect(session.isRunning)
        #expect(fixture.processFactory.processes.count == 1)    }

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
    func projectRuntimePublishesAReadyJavaEnvironmentReport() async throws {
        let root = URL(fileURLWithPath: "/tmp/lithe-java-health", isDirectory: true)
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        runtime.openProject(at: root)
        await runtime.refreshAvailableRuntimes()

        let report = try #require(runtime.javaEnvironmentReport)
        #expect(report.status == .ready)
        #expect(report.javaHomePath == "/toolchains/jdk")
        #expect(report.jdbExecutablePath == "/toolchains/jdk/bin/jdb")
        #expect(!report.status.blocksJavaRun)
    }

    @Test
    func projectRuntimeStronglyReportsMissingJDK() async throws {
        let root = URL(fileURLWithPath: "/tmp/lithe-java-health-missing", isDirectory: true)
        let runtime = ProjectRuntimeService(
            runtimeLocator: MissingJavaRuntimeLocator(),
            store: RunTestKeyValueStore()
        )
        runtime.openProject(at: root)
        await runtime.refreshAvailableRuntimes()

        let report = try #require(runtime.javaEnvironmentReport)
        #expect(report.status == .jdkMissing)
        #expect(report.status.blocksJavaRun)
        #expect(report.recovery.contains("JAVA_HOME"))
    }

    @Test
    func javaImplementationMarkersStayBehindTheRustLSPHostBoundary() async {
        let service = JavaImplementationMarkerService()
        let root = URL(fileURLWithPath: "/tmp/lithe-java-marker-boundary", isDirectory: true)
        let document = EditorDocument(
            url: root.appendingPathComponent("src/Main.java"),
            text: "interface Service {}\nclass Impl implements Service {}\n",
            modificationDate: nil
        )
        let candidates = [
            JavaImplementationMarker(line: 0, utf16Column: 10, isType: true),
            JavaImplementationMarker(line: 1, utf16Column: 6, isType: false)
        ]

        service.invalidate(document)
        let markers = await service.markers(for: document, candidates: candidates)

        #expect(markers.isEmpty)
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
                executable: .toolchain("project-maven"),
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
    func goRuntimeToolchainFlowsFromSharedJSONIntoProcessRequest() async throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-go-runtime-toolchain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".lithe/run"),
            withIntermediateDirectories: true
        )
        try Data(#"{"version":2,"configurations":[{"id":"go:api","name":"Go API","provider":"go.main","execution":"application","args":["run","./cmd/api"],"cwd":".","env":{"APP_ENV":"test"},"toolchains":{"runtime":"project-go"}}]}"#.utf8)
            .write(to: root.appendingPathComponent(".lithe/run/generated.json"))

        let preferences = RunTestKeyValueStore()
        let store = MacRunConfigurationStore(
            core: core,
            storage: MacFileStorage(),
            preferences: preferences
        )
        let runtime = ProjectRuntimeService(
            runtimeLocator: RunTestRuntimeLocator(),
            store: preferences,
            toolchainSource: store
        )
        let process = RecordingStreamingProcess()
        let service = RunService(
            runtimeService: runtime,
            process: process,
            processFactory: { RecordingStreamingProcess() },
            fileStorage: MacFileStorage(),
            preferences: preferences,
            javaMavenOperations: RunTestJavaMavenOperations(),
            runConfigurationOperations: store
        )

        await service.loadProject(at: root, files: [], mavenProject: nil)
        let configuration = try #require(service.configurations.first { $0.id == "go:api" })
        service.run(configuration: configuration, currentFileURL: nil)

        let request = try #require(process.requests.last)
        #expect(request.executablePath == "/usr/bin/go")
        #expect(request.arguments == ["run", "./cmd/api"])
        #expect(request.workingDirectory == root.path)
        #expect(request.environment?["APP_ENV"] == "test")
        #expect(request.environment?["JAVA_HOME"] == nil)
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

    private static func framedJSON(_ data: Data?) -> [String: Any]? {
        guard let data,
              let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = data.subdata(in: separator.upperBound..<data.endIndex)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func debugRequest(named command: String, in frames: [Data]) -> [String: Any]? {
        frames.lazy
            .compactMap(framedJSON)
            .first { message in
                message["type"] as? String == "request" && message["command"] as? String == command
            }
    }

    private static func drainMainActorTasks() async {
        await Task.yield()
        await Task.yield()
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
    private(set) var lastToolchainCandidates: [ProjectToolchainCandidate] = []

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
        lastToolchainCandidates = toolchainCandidates
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
    private(set) var stopCount = 0

    func start(_ request: ProcessRequest) throws {
        requests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {}
    func stop() {
        stopCount += 1
        isRunning = false
    }
}

@MainActor
private final class RecordingRunExecutableResolver: RunExecutableResolving {
    private(set) var resolveCalls = 0

    func resolve(
        _ plan: SharedLaunchPlan,
        projectURL: URL,
        options: RunOptions
    ) throws -> ResolvedRunExecutable {
        resolveCalls += 1
        return ResolvedRunExecutable(
            executableURL: URL(fileURLWithPath: "/usr/bin/go"),
            environment: [:]
        )
    }
}

private struct TestLspClientCore: LspClientCore {
    let diagnosticURL: URL

    func lspClientInitialize(rootURL _: URL) -> RustCoreBridge.LspClientResponsePayload? {
        response(
            messages: [#"{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}"#]
        )
    }

    func lspClientOpenDocument(
        state _: ToolingJSONValue,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> RustCoreBridge.LspClientResponsePayload? {
        response(messages: [
            #"{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"\#(fileURL.standardizedFileURL.absoluteString)","languageId":"\#(languageID)","version":1,"text":"\#(text)"}}}"#
        ])
    }

    func lspClientChangeDocument(
        state _: ToolingJSONValue,
        fileURL _: URL,
        text _: String
    ) -> RustCoreBridge.LspClientResponsePayload? {
        response()
    }

    func lspClientRequest(
        state _: ToolingJSONValue,
        fileURL _: URL,
        method: String,
        position _: LanguageServerPosition?,
        newName _: String?,
        range _: LanguageServerRange?,
        diagnostics _: [LanguageServerDiagnostic]
    ) -> RustCoreBridge.LspClientResponsePayload? {
        let id: String
        switch method {
        case "textDocument/rename":
            id = "3"
        case "textDocument/formatting":
            id = "4"
        case "textDocument/codeAction":
            id = "5"
        default:
            id = "2"
        }
        return response(messages: [
            #"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":{}}"#
        ])
    }

    func lspClientApplyServerMessage(
        state _: ToolingJSONValue,
        message: String
    ) -> RustCoreBridge.LspClientResponsePayload? {
        if message.contains("publishDiagnostics") {
            return response(events: [
                RustCoreBridge.LspClientEventPayload(
                    kind: "diagnostics",
                    requestId: nil,
                    method: nil,
                    uri: diagnosticURL.standardizedFileURL.absoluteString,
                    diagnostics: [
                        RustCoreBridge.LspClientDiagnosticPayload(
                            range: RustCoreBridge.LspRangePayload(
                                start: RustCoreBridge.LspPositionPayload(line: 0, utf16Column: 7),
                                end: RustCoreBridge.LspPositionPayload(line: 0, utf16Column: 10)
                            ),
                            severity: 2,
                            message: "example warning",
                            source: "sourcekit-lsp",
                            code: nil
                        )
                    ],
                    result: nil,
                    error: nil
                )
            ])
        }
        if message.contains(#""id":"2""#) {
            return response(events: [
                RustCoreBridge.LspClientEventPayload(
                    kind: "response",
                    requestId: "2",
                    method: "textDocument/completion",
                    uri: nil,
                    diagnostics: nil,
                    result: .object([
                        "items": .array([
                            .object([
                                "label": .string("title"),
                                "insertText": .string("title"),
                                "kind": .integer(6),
                                "detail": .string("String"),
                                "additionalTextEdits": .array([]),
                                "data": .null
                            ])
                        ])
                    ]),
                    error: nil
                )
            ])
        }
        if message.contains(#""id":"3""#) {
            return response(events: [
                RustCoreBridge.LspClientEventPayload(
                    kind: "response",
                    requestId: "3",
                    method: "textDocument/rename",
                    uri: nil,
                    diagnostics: nil,
                    result: .object([
                        "changes": .object([
                            diagnosticURL.standardizedFileURL.path: .array([
                                .object([
                                    "range": .object([
                                        "start": .object(["line": .integer(0), "utf16Column": .integer(17)]),
                                        "end": .object(["line": .integer(0), "utf16Column": .integer(22)])
                                    ]),
                                    "newText": .string("headline")
                                ])
                            ])
                        ])
                    ]),
                    error: nil
                )
            ])
        }
        if message.contains(#""id":"4""#) {
            return response(events: [
                RustCoreBridge.LspClientEventPayload(
                    kind: "response",
                    requestId: "4",
                    method: "textDocument/formatting",
                    uri: nil,
                    diagnostics: nil,
                    result: .object([
                        "edits": .array([
                            .object([
                                "range": .object([
                                    "start": .object(["line": .integer(0), "utf16Column": .integer(10)]),
                                    "end": .object(["line": .integer(0), "utf16Column": .integer(10)])
                                ]),
                                "newText": .string(" ")
                            ])
                        ])
                    ]),
                    error: nil
                )
            ])
        }
        if message.contains(#""id":"5""#) {
            return response(events: [
                RustCoreBridge.LspClientEventPayload(
                    kind: "response",
                    requestId: "5",
                    method: "textDocument/codeAction",
                    uri: nil,
                    diagnostics: nil,
                    result: .object([
                        "actions": .array([
                            .object([
                                "title": .string("Fix warning"),
                                "kind": .string("quickfix"),
                                "isPreferred": .bool(true),
                                "command": .object([
                                    "title": .string("Apply fix"),
                                    "command": .string("source.fix"),
                                    "arguments": .array([
                                        .object(["uri": .string(diagnosticURL.standardizedFileURL.absoluteString)])
                                    ])
                                ]),
                                "data": .object(["token": .string("fix-1")])
                            ])
                        ])
                    ]),
                    error: nil
                )
            ])
        }
        return response(
            messages: [#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#],
            events: [
                RustCoreBridge.LspClientEventPayload(
                    kind: "response",
                    requestId: "1",
                    method: "initialize",
                    uri: nil,
                    diagnostics: nil,
                    result: nil,
                    error: nil
                )
            ]
        )
    }

    private func response(
        messages: [String] = [],
        events: [RustCoreBridge.LspClientEventPayload] = []
    ) -> RustCoreBridge.LspClientResponsePayload {
        RustCoreBridge.LspClientResponsePayload(
            state: .object([:]),
            messages: messages,
            events: events
        )
    }
}

private final class RecordingRawProcessSession: RawProcessSession, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    private(set) var requests: [ProcessRequest] = []
    private(set) var sentData: [Data] = []

    func start(_ request: ProcessRequest) throws {
        requests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws { sentData.append(input) }
    func stop() { isRunning = false }

    func emitJSON(_ object: [String: Any], splitAt: Int? = nil) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        if let splitAt, splitAt > 0, splitAt < framed.count {
            onOutput?(framed.subdata(in: 0..<splitAt))
            onOutput?(framed.subdata(in: splitAt..<framed.count))
        } else {
            onOutput?(framed)
        }
    }
}

@MainActor
private final class RecordingDebugAdapterTransport: DebugAdapterTransport, DebugAdapterChildTransportProviding {
    private(set) var isRunning = false
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?
    private(set) var sentData: [Data] = []
    private(set) var children: [RecordingDebugAdapterTransport] = []

    func start(rootURL: URL) throws { isRunning = true }
    func send(_ data: Data) throws { sentData.append(data) }
    func stop() { isRunning = false }

    func makeChildTransport() -> (any DebugAdapterTransport)? {
        let child = RecordingDebugAdapterTransport()
        children.append(child)
        return child
    }

    func emitJSON(_ object: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        onData?(framed)
    }
}

private final class RecordingProcessFactory: @unchecked Sendable {
    private(set) var processes: [RecordingStreamingProcess] = []

    func make() -> RecordingStreamingProcess {
        let process = RecordingStreamingProcess()
        processes.append(process)
        return process
    }
}

private final class ToolchainVersionProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    var executedCommands: [String] {
        lock.withLock { commands }
    }

    func run(_ request: ProcessRequest) -> ProcessResult {
        let command = URL(fileURLWithPath: request.executablePath).lastPathComponent
        lock.withLock { commands.append(command) }
        let output: String
        switch command {
        case "go": output = "go version go1.24.3 darwin/arm64"
        case "python3": output = "Python 3.13.5"
        case "node": output = "v22.18.0"
        case "rustc": output = "rustc 1.89.0 (29483883e 2025-08-04)"
        default: output = ""
        }
        return ProcessResult(output: output, exitCode: output.isEmpty ? 1 : 0)
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
}

private struct MissingJavaRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/usr/bin"] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func systemJDBExecutable() -> URL? { nil }
}

private struct XcrunOnlyRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/usr/bin"] }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { url.path == "/usr/bin/xcrun" }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func systemJDBExecutable() -> URL? { nil }
}

@MainActor
private final class TestDebugAdapterSession: DebugAdapterControllingSession {
    private(set) var isRunning = false
    var state: DebugAdapterState { isRunning ? .ready : .idle }
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?
    private(set) var breakpointUpdates: [(URL, [DebugSourceBreakpoint])] = []

    func start(rootURL: URL) throws { isRunning = true }
    func stop() { isRunning = false }
    func launch(_ configuration: DebugLaunchConfiguration) throws {}
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {
        breakpointUpdates.append((fileURL.standardizedFileURL, breakpoints))
    }
    func execute(_ command: DebugExecutionCommand, threadID: Int?) {}
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
        completion(.success([]))
    }
    func requestStackTrace(
        threadID: Int,
        completion: @escaping (Result<[DebugStackFrame], Error>) -> Void
    ) { completion(.success([])) }
    func requestScopes(
        frameID: Int,
        completion: @escaping (Result<[DebugScope], Error>) -> Void
    ) { completion(.success([])) }
    func requestVariables(
        reference: Int,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) { completion(.success([])) }
    func evaluate(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {}
}

@MainActor
private final class TestDebugLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let supportsDebugAdapterSession: Bool
    private(set) var debugAdapters: [TestDebugAdapterSession] = []

    init(descriptor: LanguageProviderDescriptor, supportsDebugAdapter: Bool = false) {
        self.descriptor = descriptor
        supportsDebugAdapterSession = supportsDebugAdapter
    }

    func makeDebugAdapterSession() -> (any DebugAdapterSession)? {
        let session = TestDebugAdapterSession()
        debugAdapters.append(session)
        return session
    }
}

@MainActor
private final class TestDlvSocketConnection: DlvSocketConnection {
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [Data] = []

    func start() { startCount += 1 }
    func send(_ data: Data) { sent.append(data) }
    func stop() { stopCount += 1 }
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

@Suite("Core payload decoding")
struct CorePayloadDecodingTests {
    /// The core spells Maven coordinates the way Maven does -- `groupId` and
    /// `artifactId`. Swift spells the same properties with a capital D, and
    /// `artifactId` is non-optional, so a missing key mapping made the whole
    /// scan decode to nil and the Maven panel claimed the project had no pom.
    /// The failure is silent: the bridge discards decoding errors.
    @Test
    func mavenScanDecodesTheCoordinateSpellingTheCoreEmits() throws {
        let json = """
        {
          "groupId": "com.lithe.demo",
          "artifactId": "full-stack-demo",
          "version": "1.0.0-SNAPSHOT",
          "packaging": "pom",
          "hasWrapper": true,
          "profiles": [],
          "modules": [
            {
              "groupId": "com.lithe.demo",
              "artifactId": "backend-api",
              "relativePath": "backend-api",
              "version": "1.0.0-SNAPSHOT",
              "packaging": "jar",
              "modules": []
            }
          ]
        }
        """

        let payload = try JSONDecoder().decode(
            RustCoreBridge.MavenScanPayload.self,
            from: Data(json.utf8)
        )
        let project = payload.makeProject(rootURL: URL(fileURLWithPath: "/tmp/demo"))

        #expect(project.artifactID == "full-stack-demo")
        #expect(project.modules.map(\.artifactID) == ["backend-api"])
        #expect(project.modules.map(\.relativePath) == ["backend-api"])
    }

    /// Same root cause, quieter symptom: `hunkId` decoded as nil left every
    /// diff row unattached to its hunk instead of failing outright.
    @Test
    func gitDiffRowDecodesItsHunkIdentifier() throws {
        let json = """
        {"oldLine":1,"newLine":1,"left":"a","right":"b","kind":"changed","hunkId":"h1"}
        """

        let row = try JSONDecoder().decode(
            RustCoreBridge.GitDiffPayload.Row.self,
            from: Data(json.utf8)
        )

        #expect(row.hunkID == "h1")
    }
}
