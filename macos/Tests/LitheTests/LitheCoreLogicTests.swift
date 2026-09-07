import AppKit
import Combine
import CoreServices
import Foundation
import LitheApplicationKernel
@testable import LitheDatabaseModule
@testable import LitheGitModule
import LitheLocalHistoryModule
import LitheModuleAPI
import LitheSearchModule
import Testing
import LitheTerminalModule
@testable import Lithe

@Suite("Lithe core logic")
struct LitheCoreLogicTests {
    @Test
    func workspaceRelativeFilePathsUseDefaultFileIcons() {
        let expectations: [(path: String, kind: LitheIconKind)] = [
            ("rust/lithe-core/src/lib.rs", .rustSource),
            ("Cargo.toml", .toml),
            ("src/main/java/App.java", .javaGeneric),
            ("docs/README.md", .markdown),
            (".gitignore", .gitignore),
            ("Dockerfile", .docker),
            ("assets/unknown.custom", .generic),
            ("LICENSE", .generic)
        ]

        for expectation in expectations {
            #expect(LitheIcons.kind(forFilePath: expectation.path) == expectation.kind)
        }
    }

    @Test
    func fileURLAndWorkspaceRelativePathIconKindsStayAligned() {
        let paths = [
            "pom.xml",
            ".env.production",
            "build.gradle.kts",
            "Sources/App.swift",
            "config/settings.yaml"
        ]

        for path in paths {
            let url = URL(fileURLWithPath: "/workspace").appendingPathComponent(path)
            #expect(
                LitheIcons.kind(for: url, isDirectory: false)
                    == LitheIcons.kind(forFilePath: path)
            )
        }
    }

    @Test
    func javaInterfaceSymbolAcceptsUnicodeIdentifiers() {
        #expect(
            LitheIcons.javaSymbolKind(fromSourcePrefix: "public interface 用户服务 {}")
                == .javaInterface
        )
    }

    @Test
    func javaNavigationMarkersUseTheFourIntelliJGutterAssets() {
        #expect(
            LitheIcons.implementationMarkerAssetPath(isInterface: true, pointingDown: true)
                == "gutter/implementedMethod.svg"
        )
        #expect(
            LitheIcons.implementationMarkerAssetPath(isInterface: true, pointingDown: false)
                == "gutter/implementingMethod.svg"
        )
        #expect(
            LitheIcons.implementationMarkerAssetPath(isInterface: false, pointingDown: true)
                == "gutter/overridenMethod.svg"
        )
        #expect(
            LitheIcons.implementationMarkerAssetPath(isInterface: false, pointingDown: false)
                == "gutter/overridingMethod.svg"
        )
    }

    @Test
    @MainActor
    func closingAWorkspaceWindowClosesTheProjectInsteadOfTheWindow() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = NSWindow()

        #expect(!coordinator.windowShouldClose(window))
        #expect(sessions.closeActiveProjectCallCount == 1)
    }

    @Test
    @MainActor
    func commandWClosesActiveWorkbenchContentBeforeTheWindow() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        sessions.consumesWorkbenchCloseCommand = true
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = CloseCommandTestWindow()
        coordinator.attach(to: window, layout: .workspace)

        coordinator.performCloseCommand()

        #expect(sessions.closeActiveWorkbenchItemCallCount == 1)
        #expect(window.performCloseCallCount == 0)
        #expect(sessions.closeActiveProjectCallCount == 0)
    }

    @Test
    @MainActor
    func commandWUsesNativeWindowCloseAfterWorkbenchContentIsGone() async {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = CloseCommandTestWindow()
        coordinator.attach(to: window, layout: .workspace)

        coordinator.performCloseCommand()

        #expect(sessions.closeActiveWorkbenchItemCallCount == 1)
        #expect(window.performCloseCallCount == 1)
        #expect(!window.delegateAllowedClose)
        #expect(await window.waitUntilNativeCloseAllowed())
        #expect(window.performCloseCallCount == 2)
        #expect(window.delegateAllowedClose)
        #expect(sessions.resetForProjectWindowCloseCallCount == 1)
        #expect(sessions.closeActiveProjectCallCount == 0)
    }

    @Test
    @MainActor
    func commandWWaitsForProjectCleanupBeforeAllowingNativeClose() async {
        let cleanupStarted = TestGate()
        let releaseCleanup = TestGate()
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        sessions.projectWindowCleanupStarted = cleanupStarted
        sessions.projectWindowCleanupRelease = releaseCleanup
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = CloseCommandTestWindow()
        coordinator.attach(to: window, layout: .workspace)
        defer { releaseCleanup.open() }

        coordinator.performCloseCommand()

        #expect(await cleanupStarted.waitUntilOpen())
        #expect(window.performCloseCallCount == 1)
        #expect(!window.delegateAllowedClose)

        releaseCleanup.open()

        #expect(await window.waitUntilNativeCloseAllowed())
        #expect(window.performCloseCallCount == 2)
        #expect(window.delegateAllowedClose)
        #expect(sessions.resetForProjectWindowCloseCallCount == 1)
    }

    @Test
    @MainActor
    func commandWCancelDoesNotResetSessionsOrLeakIntoTheNextWindowClose() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        let coordinator = LitheWindowCoordinator(
            projectSessions: sessions,
            confirmUnsavedDocuments: { _ in false }
        )
        let window = CloseCommandTestWindow()
        coordinator.attach(to: window, layout: .workspace)

        coordinator.performCloseCommand()

        #expect(window.performCloseCallCount == 1)
        #expect(!window.delegateAllowedClose)
        #expect(sessions.resetForProjectWindowCloseCallCount == 0)

        #expect(!coordinator.windowShouldClose(window))
        #expect(sessions.requestCloseActiveSessionCallCount == 1)
    }

    @Test
    @MainActor
    func commandWSaveFailureDoesNotResetSessions() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        sessions.hasUnsavedDocuments = true
        sessions.saveAllDocumentsResult = false
        let coordinator = LitheWindowCoordinator(
            projectSessions: sessions,
            confirmUnsavedDocuments: { owner in
                #expect(owner.hasUnsavedDocuments)
                #expect(!owner.saveAllDocuments())
                return false
            }
        )
        let window = CloseCommandTestWindow()
        coordinator.attach(to: window, layout: .workspace)

        coordinator.performCloseCommand()

        #expect(!window.delegateAllowedClose)
        #expect(sessions.saveAllDocumentsCallCount == 1)
        #expect(sessions.resetForProjectWindowCloseCallCount == 0)
    }

    @Test
    @MainActor
    func ordinaryWindowCloseStillClosesOnlyTheActiveSession() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)

        #expect(!coordinator.windowShouldClose(NSWindow()))
        #expect(sessions.requestCloseActiveSessionCallCount == 1)
        #expect(sessions.resetForProjectWindowCloseCallCount == 0)
    }

    @Test
    @MainActor
    func closingAProjectWindowReplacesAllSessionsWithAnEmptyActiveSession() async {
        let store = MutableKeyValueStore()
        let settings = AppSettings(store: store)
        var createdModels: [AppModel] = []
        let manager = ProjectSessionManager(
            settings: settings,
            modelFactory: {
                let model = AppModel(
                    settings: settings,
                    services: MacServiceContainer(
                        store: store,
                        settings: settings,
                        moduleLaunchMode: .safeMode
                    ).services
                )
                createdModels.append(model)
                return model
            },
            newWindowOpener: { _ in }
        )

        manager.openStandaloneFile(URL(fileURLWithPath: "/tmp/lithe-close-first.swift"))
        manager.openStandaloneFile(URL(fileURLWithPath: "/tmp/lithe-close-second.swift"))
        let oldIDs = Set(manager.sessions.map(\.id))
        manager.pendingProjectOpen = PendingProjectOpen(
            url: URL(fileURLWithPath: "/tmp/lithe-close-pending"),
            sourceSessionID: manager.activeSessionID
        )

        await manager.resetForProjectWindowClose()

        #expect(manager.sessions.count == 1)
        #expect(!oldIDs.contains(manager.activeSessionID))
        #expect(manager.activeModel.workspaceURL == nil)
        #expect(manager.activeModel.standaloneFileURL == nil)
        #expect(manager.pendingProjectOpen == nil)
        #expect(manager.activeModel === createdModels.last)
    }

    @Test
    @MainActor
    func projectWindowResetWaitsForModuleShutdownBeforeReplacingSessions() async throws {
        let shutdownStarted = TestGate()
        let releaseShutdown = TestGate()
        let store = MutableKeyValueStore()
        let settings = AppSettings(store: store)
        let manager = ProjectSessionManager(
            settings: settings,
            modelFactory: {
                AppModel(
                    settings: settings,
                    services: MacServiceContainer(store: store, settings: settings).services
                )
            },
            newWindowOpener: { _ in }
        )
        let previousModel = manager.activeModel
        let runtime = previousModel.services.moduleRuntime
        try runtime.register(ModuleFactory(manifest: projectWindowShutdownTestManifest) {
            ProjectWindowShutdownTestModule(
                shutdownStarted: shutdownStarted,
                releaseShutdown: releaseShutdown
            )
        })
        _ = try await runtime.activate(projectWindowShutdownTestManifest.id)
        defer { releaseShutdown.open() }

        let resetTask = Task { await manager.resetForProjectWindowClose() }

        #expect(await shutdownStarted.waitUntilOpen())
        #expect(manager.activeModel === previousModel)

        releaseShutdown.open()
        await resetTask.value

        #expect(manager.activeModel !== previousModel)
    }

    @Test
    @MainActor
    func closingTheWelcomeWindowAllowsTheApplicationToTerminate() {
        let sessions = TestProjectWindowSessions(hasActiveProject: false)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = NSWindow()

        #expect(coordinator.windowShouldClose(window))
        #expect(sessions.closeActiveProjectCallCount == 0)
    }

    @Test
    @MainActor
    func applicationTerminatesAfterItsLastWindowCloses() {
        let appDelegate = LitheAppDelegate()

        #expect(appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test
    func workbenchKeepsAppKitBackedControlsOutOfDrawingGroups() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/Lithe/Views/Workbench/WorkbenchView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(".drawingGroup()"))
    }

    @Test
    @MainActor
    func welcomeAndWorkspaceUseDistinctWindowSizes() {
        let sessions = TestProjectWindowSessions(hasActiveProject: false)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = NSWindow()

        coordinator.attach(to: window, layout: .welcome)
        #expect(window.contentMinSize == LitheWindowLayout.welcome.minimumContentSize)
        #expect(window.contentLayoutRect.size == LitheWindowLayout.welcome.contentSize)

        coordinator.attach(to: window, layout: .workspace)
        #expect(window.contentMinSize == LitheWindowLayout.workspace.minimumContentSize)
        #expect(window.contentLayoutRect.width <= LitheWindowLayout.workspace.contentSize.width)
        #expect(window.contentLayoutRect.height <= LitheWindowLayout.workspace.contentSize.height)
        #expect(window.contentLayoutRect.width >= LitheWindowLayout.workspace.minimumContentSize.width)
        #expect(window.contentLayoutRect.height >= LitheWindowLayout.workspace.minimumContentSize.height)
    }

    @Test
    @MainActor
    func workspaceWindowKeepsAnAccessibleTitleWithoutShowingTheNativeTitle() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = NSWindow()

        coordinator.attach(to: window, layout: .workspace, title: "Lithe-IDEA")

        #expect(window.title == "Lithe-IDEA")
        #expect(window.titleVisibility == .hidden)
    }

    @Test
    func workspaceWindowFitsInsideTheVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 1280, height: 776)
        let oversizedFrame = NSRect(x: -80, y: -40, width: 1440, height: 900)

        let fittedFrame = LitheWindowLayout.frame(oversizedFrame, fitting: visibleFrame)

        #expect(fittedFrame.minX >= visibleFrame.minX)
        #expect(fittedFrame.maxX <= visibleFrame.maxX)
        #expect(fittedFrame.minY >= visibleFrame.minY)
        #expect(fittedFrame.maxY <= visibleFrame.maxY)
    }

    @Test
    func standaloneWindowUsesScreenRatioWithinSizeLimits() {
        let regularScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let compactScreen = NSRect(x: 0, y: 0, width: 900, height: 600)
        let largeScreen = NSRect(x: 0, y: 0, width: 2560, height: 1600)

        #expect(
            LitheWindowLayout.standaloneContentSize(fitting: regularScreen)
                == NSSize(width: 936, height: 648)
        )
        #expect(
            LitheWindowLayout.standaloneContentSize(fitting: compactScreen)
                == LitheWindowLayout.standaloneMinimumContentSize
        )
        #expect(
            LitheWindowLayout.standaloneContentSize(fitting: largeScreen)
                == LitheWindowLayout.standaloneMaximumContentSize
        )
    }

    @Test
    @MainActor
    func workspaceTitleBarZoomsToTheVisibleScreenAndRestores() {
        let sessions = TestProjectWindowSessions(hasActiveProject: true)
        let coordinator = LitheWindowCoordinator(projectSessions: sessions)
        let window = NSWindow()
        coordinator.attach(to: window, layout: .workspace)
        let restoredFrame = NSRect(x: 120, y: 70, width: 1000, height: 680)
        let visibleFrame = NSRect(x: 0, y: 24, width: 1280, height: 776)
        window.setFrame(restoredFrame, display: false)

        coordinator.toggleWorkspaceZoom(fitting: visibleFrame)
        #expect(window.frame == visibleFrame)

        coordinator.toggleWorkspaceZoom(fitting: visibleFrame)
        #expect(window.frame == restoredFrame)
    }

    @Test
    func databaseSidecarParsesCapabilitiesWithoutStartingUntilRequested() throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            return ProcessResult(
                output: #"{"id":"\#(id)","ok":true,"result":{"protocolVersion":1,"databaseTypes":["mysql","postgresql","sqlite"],"features":["schema"]}}"#,
                exitCode: 0
            )
        }
        let service = DatabaseSidecarService(
            processRunner: runner,
            executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")
        )

        #expect(runner.requests.isEmpty)
        #expect(try service.capabilities() == DatabaseCapabilities(
            protocolVersion: 1,
            databaseTypes: ["mysql", "postgresql", "sqlite"],
            features: ["schema"]
        ))
        #expect(runner.requests.count == 1)
        #expect(runner.requests[0].arguments.isEmpty)
        #expect(runner.requests[0].standardInput != nil)
        #expect(runner.requests[0].timeoutMilliseconds == 30_000)
    }

    @Test
    func databaseSidecarSerializesRedisAndNacosWorkspaceRequests() throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result: String
            switch method {
            case "redisScan":
                result = #"{"keys":[{"key":"session:42","type":"string","ttl":60,"size":9}],"nextCursor":"19"}"#
            case "nacosListConfigs":
                result = #"{"items":[{"dataId":"app.yaml","group":"DEFAULT_GROUP","namespace":"dev","type":"yaml","md5":"abc"}],"totalCount":1}"#
            default:
                Issue.record("Unexpected sidecar method: \(method)")
                result = "{}"
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let service = DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar"))

        let redis = DatabaseConnection(kind: .redis, host: "127.0.0.1", port: 6379, database: "0")
        let scan = try service.redisScan(connection: redis, cursor: "0", pattern: "session:*", count: 50)
        #expect(scan.keys.first?.key == "session:42")
        #expect(scan.nextCursor == "19")

        let nacos = DatabaseConnection(kind: .nacos, host: "127.0.0.1", port: 8848, database: "dev", path: "/nacos")
        let configs = try service.nacosListConfigs(connection: nacos, dataId: "app", group: "DEFAULT_GROUP")
        #expect(configs.items.first?.dataId == "app.yaml")
        #expect(configs.totalCount == 1)

        let redisRequest = String(decoding: try #require(runner.requests[0].standardInput), as: UTF8.self)
        let nacosRequest = String(decoding: try #require(runner.requests[1].standardInput), as: UTF8.self)
        #expect(redisRequest.contains(#""method":"redisScan""#))
        #expect(redisRequest.contains(#""kind":"redis""#))
        #expect(!redisRequest.contains("127.0.0.1:6379"))
        #expect(nacosRequest.contains(#""method":"nacosListConfigs""#))
        #expect(nacosRequest.contains(#""kind":"nacos""#))
    }

    @Test
    func databaseSidecarSerializesRedisSizePreference() throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            return ProcessResult(
                output: #"{"id":"\#(id)","ok":true,"result":{"keys":[],"nextCursor":"0"}}"#,
                exitCode: 0
            )
        }
        let service = DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar"))
        let redis = DatabaseConnection(kind: .redis, host: "127.0.0.1", port: 6379, database: "0")

        _ = try service.redisScan(connection: redis, includeSize: false)

        let request = String(decoding: try #require(runner.requests[0].standardInput), as: UTF8.self)
        #expect(request.contains(#""includeSize":false"#))
    }

    @Test
    func databaseSidecarDecodesLegacyMongoMetadataRowsEnvelope() throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result: String
            switch method {
            case "listTables": result = #"{"rows":[{"table_name":"events","table_type":"collection"}],"truncated":false}"#
            case "describeTable": result = #"{"rows":[{"column_name":"_id","data_type":"objectId"}],"truncated":false}"#
            case "listIndexes": result = #"{"rows":[{"index_name":"_id_","definition":"{\"_id\":1}"}],"truncated":false}"#
            case "listForeignKeys": result = #"{"rows":[],"truncated":false}"#
            case "listObjects": result = #"{"rows":[{"object_name":"events","object_kind":"collection"}],"truncated":false}"#
            default: result = "[]"
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let service = DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar"))
        let mongo = DatabaseConnection(kind: .mongodb, host: "127.0.0.1", port: 27017, database: "lithe_test")
        func stringValue(_ row: DatabaseRow?, _ key: String) -> String? {
            guard case let .string(value) = row?[key] else { return nil }
            return value
        }

        #expect(stringValue(try service.listTables(connection: mongo).first, "table_name") == "events")
        #expect(stringValue(try service.describeTable(connection: mongo, table: "events").first, "column_name") == "_id")
        #expect(stringValue(try service.listIndexes(connection: mongo, table: "events").first, "index_name") == "_id_")
        #expect((try service.listForeignKeys(connection: mongo, table: "events")).isEmpty)
        #expect(stringValue(try service.listObjects(connection: mongo, kind: DatabaseObjectKind.tables).first, "object_name") == "events")
    }

    @Test
    func databaseSidecarMapsFailedProcessToStableError() {
        let runner = RecordingProcessRunner(result: ProcessResult(output: "connection store failed", exitCode: 2))
        let service = DatabaseSidecarService(
            processRunner: runner,
            executableURL: URL(fileURLWithPath: "/tmp/dbx")
        )

        #expect(throws: DatabaseSidecarError.processFailed(exitCode: 2, output: "connection store failed")) {
            try service.capabilities()
        }
    }

    @Test
    func databaseSidecarErrorsAreSingleLineAndBounded() {
        let error = DatabaseSidecarError.requestFailed(code: "database_error", message: String(repeating: "x", count: 800) + "\nnext line")
        let description = error.localizedDescription
        #expect(description.count <= 500 + "Database request failed (database_error): ".count)
        #expect(!description.contains("\n"))
        #expect(description.hasSuffix("..."))
    }

    @Test
    func databaseValueDisplayKeepsNullAndEmptyStringDistinct() {
        #expect(DatabaseValue.null.displayText == "NULL")
        #expect(DatabaseValue.string("").displayText == "\"\"")
        #expect(DatabaseValue.string("NULL").displayText == "NULL")
        #expect(DatabaseValue.object(["empty": .string("")]).displayText == #"{"empty":""}"#)
    }

    @Test
    func databaseProfilesKeepPasswordsOutOfPreferences() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let profile = DatabaseProfile(name: "Local", kind: .mysql, username: "root", database: "app")

        try store.save([profile])
        try store.savePassword("secret-value", for: profile.id)

        #expect(store.load() == [profile])
        #expect(store.password(for: profile.id) == "secret-value")
        let encodedProfiles = try #require(preferences.data(forKey: "database.profiles.v1"))
        #expect(!String(decoding: encodedProfiles, as: UTF8.self).contains("secret-value"))
    }

    @Test
    @MainActor
    func databaseRepeatedConnectionEditsPreserveTheSavedPasswordAndProfileID() async throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            return ProcessResult(
                output: #"{"id":"\#(id)","ok":true,"result":{"connected":true}}"#,
                exitCode: 0
            )
        }
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let operations = DatabaseSidecarService(
            processRunner: runner,
            executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")
        )
        let feature = DatabaseFeatureModel(operations: operations, connectionStore: store)
        let profile = DatabaseProfile(name: "Local Redis", kind: .redis, port: 6379)

        #expect(await feature.add(profile, password: "1234"))
        var firstRename = profile
        firstRename.name = "Renamed Redis"
        #expect(await feature.update(firstRename, password: nil))
        var secondRename = firstRename
        secondRename.name = "Renamed Again"
        #expect(await feature.update(secondRename, password: nil))

        #expect(feature.profiles.first?.id == profile.id)
        #expect(feature.profiles.first?.name == "Renamed Again")
        #expect(store.password(for: profile.id) == "1234")
        #expect(runner.requests.count == 3)
        for request in runner.requests {
            let payload = String(decoding: try #require(request.standardInput), as: UTF8.self)
            #expect(payload.contains(#""password":"1234""#))
        }
    }

    @Test
    func databaseDBXImportMapsConnectionsFoldersAndUnsupportedTypes() throws {
        let data = Data(dbxPlainConnectionExport.utf8)
        let duplicate = DatabaseProfile(name: "Production MySQL", kind: .mysql, host: "db.example.com", port: 3306)
        let plan = try DatabaseDBXImportService().parse(data: data, passphrase: nil, existingProfiles: [duplicate])

        #expect(plan.wasEncrypted == false)
        #expect(plan.candidates.count == 2)
        #expect(plan.duplicateCount == 1)
        #expect(plan.unsupportedTypes == ["oracle": 1])
        #expect(plan.folders.count == 2)
        let production = try #require(plan.candidates.first { $0.sourceID == "mysql-1" })
        #expect(production.profile.kind == .mysql)
        #expect(production.profile.username == "root")
        #expect(production.password == "db-secret")
        #expect(production.profile.readOnly)
        #expect(production.profile.productionProtection)
        #expect(production.profile.sshHost == "jump.example.com")
        let sqlite = try #require(plan.candidates.first { $0.sourceID == "sqlite-1" })
        #expect(sqlite.profile.kind == .sqlite)
        #expect(sqlite.profile.path == "/tmp/local.sqlite")
        let localFolder = try #require(plan.folders.first { $0.id == sqlite.profile.folderID })
        #expect(localFolder.name == "Local")
        #expect(localFolder.parentID != nil)
    }

    @Test
    func databaseDBXImportDecryptsTheVersionOneWebCryptoEnvelope() throws {
        let data = Data(dbxEncryptedConnectionExport.utf8)
        let service = DatabaseDBXImportService()
        #expect(service.isEncrypted(data))
        let plan = try service.parse(data: data, passphrase: "migration-pass", existingProfiles: [])
        #expect(plan.wasEncrypted)
        #expect(plan.candidates.count == 1)
        #expect(plan.candidates[0].profile.name == "M")
        #expect(plan.candidates[0].password == "p")
        #expect(throws: DatabaseDBXImportError.wrongPassphrase) {
            try service.parse(data: data, passphrase: "wrong", existingProfiles: [])
        }
    }

    @Test
    @MainActor
    func databaseDBXImportPersistsProfilesFoldersAndKeychainPasswordsOffline() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let operations = DatabaseSidecarService(
            processRunner: RecordingProcessRunner(result: ProcessResult(output: "", exitCode: 1)),
            executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")
        )
        let feature = DatabaseFeatureModel(operations: operations, connectionStore: store)
        let plan = try DatabaseDBXImportService().parse(
            data: Data(dbxPlainConnectionExport.utf8),
            passphrase: nil,
            existingProfiles: []
        )

        let count = feature.importDBXConnections(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)))
        #expect(count == 2)
        #expect(feature.profiles.count == 2)
        #expect(feature.folders.count == 2)
        let mysql = try #require(feature.profiles.first { $0.name == "Production MySQL" })
        #expect(store.password(for: mysql.id) == "db-secret")
        #expect(mysql.folderID != nil)
        let sqlite = try #require(feature.profiles.first { $0.name == "Local SQLite" })
        let localFolder = try #require(feature.folders.first { $0.id == sqlite.folderID })
        #expect(localFolder.parentID == mysql.folderID)
    }

    @Test
    func databaseConnectionFoldersPersistWithProfiles() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let folder = DatabaseConnectionFolder(name: "Development")
        let profile = DatabaseProfile(name: "Local MySQL", kind: .mysql, folderID: folder.id)

        try store.saveFolders([folder])
        try store.save([profile])

        #expect(store.loadFolders() == [folder])
        #expect(store.load().first?.folderID == folder.id)
        #expect(store.load().first?.group == "")
    }

    @Test
    @MainActor
    func databaseLegacyGroupsMigrateToFoldersAndFolderRemovalKeepsConnections() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let profile = DatabaseProfile(name: "Legacy MySQL", kind: .mysql, group: "Team A")
        try store.save([profile])

        let operations = DatabaseSidecarService(
            processRunner: RecordingProcessRunner(result: ProcessResult(output: "", exitCode: 0)),
            executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")
        )
        let feature = DatabaseFeatureModel(operations: operations, connectionStore: store)
        let folder = try #require(feature.folders.first)
        let migrated = try #require(feature.profiles.first)

        #expect(folder.name == "Team A")
        #expect(migrated.folderID == folder.id)
        #expect(migrated.group.isEmpty)
        #expect(store.loadFolders() == [folder])

        feature.removeFolder(folder)

        let remaining = try #require(feature.profiles.first)
        #expect(feature.folders.isEmpty)
        #expect(remaining.id == profile.id)
        #expect(remaining.folderID == nil)
        #expect(store.load().first?.folderID == nil)
    }

    @Test
    @MainActor
    func databaseConnectionMovePersistsFolderAssignment() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let first = DatabaseConnectionFolder(name: "One")
        let second = DatabaseConnectionFolder(name: "Two")
        let profile = DatabaseProfile(name: "Move me", kind: .sqlite, path: "/tmp/test.sqlite")
        try store.saveFolders([first, second])
        try store.save([profile])

        let operations = DatabaseSidecarService(
            processRunner: RecordingProcessRunner(result: ProcessResult(output: "", exitCode: 0)),
            executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")
        )
        let feature = DatabaseFeatureModel(operations: operations, connectionStore: store)
        feature.move(profile, toFolder: second.id)

        #expect(feature.profiles.first?.folderID == second.id)
        #expect(store.load().first?.folderID == second.id)
    }

    @Test
    @MainActor
    func databaseNestedFolderAndDuplicateConnectionKeepAssignments() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let parent = DatabaseConnectionFolder(name: "Team")
        let child = DatabaseConnectionFolder(name: "Backend", parentID: parent.id)
        let profile = DatabaseProfile(name: "Local", kind: .sqlite, path: "/tmp/local.sqlite", folderID: child.id)
        try store.saveFolders([parent, child])
        try store.save([profile])
        try store.savePassword("password", for: profile.id)

        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: RecordingProcessRunner(result: ProcessResult(output: "", exitCode: 0)), executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )
        #expect(feature.createFolder(name: "Queries", parentID: parent.id))
        #expect(feature.folders.first(where: { $0.name == "Queries" })?.parentID == parent.id)
        let copy = try #require(feature.duplicate(profile))
        #expect(copy.folderID == child.id)
        #expect(copy.id != profile.id)
        #expect(store.password(for: copy.id) == "password")

        feature.removeFolder(parent)
        #expect(feature.folders.first(where: { $0.id == child.id })?.parentID == nil)
        #expect(feature.profiles.first(where: { $0.id == profile.id })?.folderID == child.id)
    }

    @Test
    func databaseBrandIconCatalogCoversSupportedKinds() {
        #expect(DatabaseKind.allCases.map(\.brandIconFilename) == [
            "mysql.svg", "mariadb.svg", "postgres.svg", "sqlite.svg",
            "sqlserver.svg", "mongodb.svg", "redis.svg", "nacos.png"
        ])
    }

    @Test
    @MainActor
    func databaseDisconnectResetsSelectedConnectionState() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Disconnect me", kind: .sqlite, path: "/tmp/disconnect.sqlite")
        try store.save([profile])
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":[]}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")), connectionStore: store)
        await feature.select(profile)
        #expect(feature.connectionStatus(for: profile) == .connected)
        feature.disconnect(profile)
        #expect(feature.connectionStatus(for: profile) == .idle)
        #expect(feature.selectedProfileID == nil)
    }

    @Test
    @MainActor
    func databaseProfileSwitchResetsProfileScopedWorkspaceState() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let first = DatabaseProfile(name: "First", kind: .sqlite, host: "first", path: "/tmp/first.sqlite")
        let second = DatabaseProfile(name: "Second", kind: .sqlite, host: "second", path: "/tmp/second.sqlite")
        try store.save([first, second])
        let tableRequestCounter = TestCounter()
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result: String
            switch method {
            case "listTables":
                tableRequestCounter.value += 1
                let tableName = tableRequestCounter.value == 1 ? "first_table" : "second_table"
                result = #"[{"table_name":"\#(tableName)"}]"#
            default:
                result = "[]"
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(first)
        #expect(feature.tables == ["first_table"])
        feature.addSQLTab(sql: "SELECT from_first")
        #expect(feature.selectedSQLTab?.sql == "SELECT from_first")

        await feature.select(second)
        #expect(feature.tables == ["second_table"])
        #expect(feature.rows.isEmpty)
        #expect(feature.selectedTable == nil)
        #expect(feature.sqlTabs.count == 1)
        #expect(feature.selectedSQLTab?.sql.isEmpty == true)
    }

    @Test
    @MainActor
    func databaseMySQLDatabaseSelectionPersistsAndRefreshesTables() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "MySQL", kind: .mysql, host: "localhost", username: "root")
        try store.save([profile])
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result: String
            switch method {
            case "listDatabases": result = #"["alpha","beta"]"#
            case "listTables": result = #"[{"table_name":"items"}]"#
            default: result = "[]"
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        #expect(feature.databaseOptions == ["alpha", "beta"])
        #expect(feature.connectionStatus(for: profile) == .connected)
        await feature.selectDatabase("beta", for: profile)

        #expect(feature.selectedProfile?.database == "beta")
        #expect(feature.tables == ["items"])
        #expect(store.load().first?.database == "beta")
    }

    @Test
    @MainActor
    func databaseRefreshingTablesReloadsTheCurrentlyOpenTable() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "SQLite", kind: .sqlite, path: "/tmp/lithe-refresh.sqlite")
        try store.save([profile])
        let pageCounter = TestCounter()
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result: String
            switch method {
            case "listTables":
                result = #"[{"table_name":"items"}]"#
            case "describeTable":
                result = #"[{"column_name":"id","data_type":"integer","column_key":"PRI"}]"#
            case "pageTable":
                pageCounter.value += 1
                result = #"{"columns":["id"],"rows":[{"id":\#(pageCounter.value)}],"truncated":false,"totalRows":1}"#
            default:
                result = "[]"
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        await feature.openTable("items")
        #expect(feature.errorMessage == nil)
        #expect(feature.rows.first?["id"] == DatabaseValue.integer(1))

        await feature.refreshTables()

        #expect(feature.tables == ["items"])
        #expect(feature.selectedTable == "items")
        #expect(feature.rows.first?["id"] == DatabaseValue.integer(2))
        #expect(pageCounter.value == 2)
    }

    @Test
    @MainActor
    func databaseInvalidSQLClearsPreviousExecutionState() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "SQLite", kind: .sqlite, path: "/tmp/lithe-test.sqlite")
        try store.save([profile])
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result: String
            if method == "query" {
                result = #"{"rows":[{"value":1}],"columns":["value"],"truncated":false}"#
            } else {
                result = "[]"
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        feature.addSQLTab(sql: "SELECT 1")
        let tabID = try #require(feature.selectedSQLTabID)
        await feature.runSQL(in: tabID)
        #expect(feature.selectedSQLTab?.result?.rows.count == 1)
        #expect(feature.selectedSQLTab?.execution != nil)

        feature.updateSQL("SELEC 1", in: tabID)
        await feature.runSQL(in: tabID)
        #expect(feature.selectedSQLTab?.result == nil)
        #expect(feature.selectedSQLTab?.execution == nil)
        #expect(feature.selectedSQLTab?.rowsAffected == nil)
        #expect(feature.selectedSQLTab?.errorMessage != nil)
    }

    @Test
    @MainActor
    func databaseRedisStatusRecoversAfterSuccessfulKeyLoad() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Redis", kind: .redis, host: "127.0.0.1", port: 6379, database: "0")
        try store.save([profile])
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            if method == "redisScan" {
                return ProcessResult(output: #"{"id":"\#(id)","ok":false,"error":{"code":"redis_error","message":"NOAUTH"}}"#, exitCode: 0)
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"key":"session:42","type":"string","ttl":60,"size":9,"stringValue":"ready","hashEntries":[]}}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        await feature.loadRedisKeys(pattern: "*")
        #expect(feature.connectionStatus(for: profile) == .failed)
        await feature.loadRedisKey("session:42")
        #expect(feature.connectionStatus(for: profile) == .connected)
        #expect(feature.redisSelectedKey?.stringValue == "ready")
    }

    @Test
    @MainActor
    func databaseRedisRescanFailureDoesNotLeaveOldKeysVisible() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Redis", kind: .redis, host: "127.0.0.1", port: 6379, database: "0")
        try store.save([profile])
        let calls = TestCounter()
        let runner = RecordingProcessRunner { request in
            calls.value += 1
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            if calls.value == 1 {
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"keys":[{"key":"session:42","type":"string","ttl":60,"size":9}],"nextCursor":"0"}}"#, exitCode: 0)
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":false,"error":{"code":"redis_error","message":"NOAUTH"}}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        await feature.loadRedisKeys(pattern: "*")
        #expect(feature.redisKeys.map(\.key) == ["session:42"])
        await feature.loadRedisKeys(pattern: "*")
        #expect(feature.redisKeys.isEmpty)
        #expect(feature.errorMessage?.contains("NOAUTH") == true)
        #expect(feature.connectionStatus(for: profile) == .failed)
    }

    @Test
    @MainActor
    func databaseRedisWriteRefreshesKeySummaryAndDetail() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Redis", kind: .redis, host: "127.0.0.1", port: 6379, database: "0")
        try store.save([profile])
        let scanCount = TestCounter()
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            switch method {
            case "redisScan":
                scanCount.value += 1
                let key = scanCount.value == 1 ? "session:old" : "session:new"
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"keys":[{"key":"\#(key)","type":"string","ttl":60,"size":9}],"nextCursor":"0"}}"#, exitCode: 0)
            case "redisSetString":
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{}}"#, exitCode: 0)
            case "redisGetKey":
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"key":"session:new","type":"string","ttl":120,"size":12,"stringValue":"updated","hashEntries":[]}}"#, exitCode: 0)
            default:
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{}}"#, exitCode: 0)
            }
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        await feature.loadRedisKeys(pattern: "session:*")
        #expect(feature.redisKeys.first?.key == "session:old")

        #expect(await feature.saveRedisString(key: "session:new", value: "updated", ttl: 120, confirmed: true))
        #expect(feature.redisKeys.first?.key == "session:new")
        #expect(feature.redisSelectedKey?.key == "session:new")
        #expect(feature.redisSelectedKey?.ttl == 120)
        #expect(scanCount.value == 2)
    }

    @Test
    @MainActor
    func databaseNacosPublishRefreshesConfigListAndDetail() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Nacos", kind: .nacos, host: "127.0.0.1", port: 8848, database: "public")
        try store.save([profile])
        let listCount = TestCounter()
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            switch method {
            case "nacosListConfigs":
                listCount.value += 1
                let dataID = listCount.value == 1 ? "old.yaml" : "new.yaml"
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"items":[{"dataId":"\#(dataID)","group":"DEFAULT_GROUP","namespace":"public","type":"yaml","md5":"abc"}],"totalCount":1}}"#, exitCode: 0)
            case "nacosPublishConfig":
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{}}"#, exitCode: 0)
            case "nacosGetConfig":
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"dataId":"new.yaml","group":"DEFAULT_GROUP","namespace":"public","type":"yaml","md5":"def","content":"updated"}}"#, exitCode: 0)
            default:
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{}}"#, exitCode: 0)
            }
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        await feature.loadNacosConfigs(dataId: "", group: "")
        #expect(feature.nacosConfigs.first?.dataId == "old.yaml")

        #expect(await feature.publishNacosConfig(dataId: "new.yaml", group: "DEFAULT_GROUP", content: "updated", type: "yaml", confirmed: true))
        #expect(feature.nacosConfigs.first?.dataId == "new.yaml")
        #expect(feature.nacosSelectedConfig?.dataId == "new.yaml")
        #expect(feature.nacosSelectedConfig?.content == "updated")
        #expect(listCount.value == 2)
    }

    @Test
    @MainActor
    func databaseConnectionStatusTracksSuccessfulConnection() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Status success", kind: .sqlite, path: "/tmp/status-success.sqlite")
        try store.save([profile])

        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":[]}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)

        #expect(feature.connectionStatus(for: profile) == .connected)
        #expect(feature.connectedProfileCount == 1)
    }

    @Test
    @MainActor
    func databaseConnectionStatusRetainsFailure() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "Status failure", kind: .sqlite, path: "/tmp/status-failure.sqlite")
        try store.save([profile])

        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(
                processRunner: RecordingProcessRunner(result: ProcessResult(output: "connection refused", exitCode: 1)),
                executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")
            ),
            connectionStore: store
        )

        await feature.select(profile)

        #expect(feature.connectionStatus(for: profile) == .failed)
        #expect(feature.connectedProfileCount == 0)
        #expect(feature.errorMessage != nil)
    }

    @Test
    func databaseSQLBackupUsesStdinAndExtendedTimeout() throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"encoding":"base64","data":"U0VMRUNUIDE7"}}"#, exitCode: 0)
        }
        let service = DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar"))
        let data = try service.exportSQL(connection: DatabaseConnection(kind: .sqlite, path: "/tmp/test.sqlite"))

        #expect(String(decoding: data, as: UTF8.self) == "SELECT 1;")
        #expect(runner.requests[0].arguments.isEmpty)
        #expect(runner.requests[0].timeoutMilliseconds == 120_000)
        let requestText = String(decoding: try #require(runner.requests[0].standardInput), as: UTF8.self)
        #expect(requestText.contains(#""method":"exportSql""#))
    }

    @Test
    func databaseFileBackupUsesPathProtocolAndExtendedTimeout() throws {
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let result = method == "exportSqlToFile"
                ? #"{"path":"/tmp/backup.sql","byteCount":12,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#
                : #"{"rowsAffected":1}"#
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":\#(result)}"#, exitCode: 0)
        }
        let service = DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar"))
        let output = try service.exportSQLToFile(connection: DatabaseConnection(kind: .sqlite, path: "/tmp/test.sqlite"), outputURL: URL(fileURLWithPath: "/tmp/backup.sql"))
        #expect(output.byteCount == 12)
        #expect(runner.requests[0].timeoutMilliseconds == 120_000)
        let requestText = String(decoding: try #require(runner.requests[0].standardInput), as: UTF8.self)
        #expect(requestText.contains(#""method":"exportSqlToFile""#))
        #expect(requestText.contains("outputPath"))

        _ = try service.importSQLFile(connection: DatabaseConnection(kind: .sqlite, path: "/tmp/test.sqlite"), fileURL: URL(fileURLWithPath: "/tmp/backup.sql"), confirmed: true, allowWrite: true)
        #expect(runner.requests[1].timeoutMilliseconds == 120_000)

        _ = try service.restoreSQLFile(connection: DatabaseConnection(kind: .sqlite, path: "/tmp/test.sqlite"), fileURL: URL(fileURLWithPath: "/tmp/backup.sql"), confirmed: true, allowWrite: true)
        #expect(runner.requests[2].timeoutMilliseconds == 120_000)
        let restoreRequest = String(decoding: try #require(runner.requests[2].standardInput), as: UTF8.self)
        #expect(restoreRequest.contains(#""method":"restoreSqlFile""#))
        #expect(DatabaseSQLExportOptions().limit == 0)
    }

    @Test
    func databaseSQLAnalyzerProtectsUnqualifiedAndDestructiveStatements() {
        let unsafeUpdate = DatabaseSQLAnalyzer.analyze("UPDATE users SET active = 0")
        #expect(unsafeUpdate.kind == .mutation)
        #expect(unsafeUpdate.requiresConfirmation)
        #expect(unsafeUpdate.warning?.contains("WHERE") == true)

        let safeDelete = DatabaseSQLAnalyzer.analyze("delete from users where id = 1")
        #expect(safeDelete.kind == .mutation)
        #expect(!safeDelete.requiresConfirmation)

        let drop = DatabaseSQLAnalyzer.analyze("-- review first\nDROP TABLE `temporary users`")
        #expect(drop.kind == .definition)
        #expect(drop.requiresConfirmation)

        let query = DatabaseSQLAnalyzer.analyze("SELECT 'UPDATE users SET x = 1' AS example")
        #expect(query.kind == .query)
        #expect(!query.requiresConfirmation)

        let invalid = DatabaseSQLAnalyzer.analyze("SELEC 1")
        #expect(invalid.kind == .unknown)
        #expect(!invalid.requiresConfirmation)
        #expect(invalid.warning?.contains("not recognized") == true)
    }

    @Test
    func databaseSQLAnalyzerSplitsBatchesWithoutBreakingQuotedSemicolons() {
        let analysis = DatabaseSQLAnalyzer.analyze("SELECT ';' AS marker; -- keep this comment\nSELECT 2;")

        #expect(analysis.canExecute)
        #expect(analysis.statementCount == 2)
        #expect(analysis.kind == .batch)
        #expect(analysis.statements.first?.contains("';'") == true)
        #expect(analysis.statements.last?.contains("SELECT 2") == true)

        let escapedQuote = DatabaseSQLAnalyzer.analyze(#"SELECT 'a\';b'; SELECT 2"#)
        #expect(escapedQuote.statementCount == 2)

        let commentsOnly = DatabaseSQLAnalyzer.analyze("-- review later\n/* no statement */")
        #expect(!commentsOnly.canExecute)
        #expect(commentsOnly.statementCount == 0)
    }

    @Test
    @MainActor
    func databaseSQLBatchRunsInOrderAndAggregatesResults() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "SQLite", kind: .sqlite, path: "/tmp/lithe-batch.sqlite")
        let recoveryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-batch-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        try store.save([profile])
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let params = object["params"] as? [String: Any]
            let sql = params?["sql"] as? String ?? ""
            switch method {
            case "exportSqlToFile":
                if let path = params?["outputPath"] as? String {
                    try? Data().write(to: URL(fileURLWithPath: path))
                }
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"path":"/tmp/backup.sql","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}}"#, exitCode: 0)
            case "query":
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"rows":[{"value":1}],"columns":["value"],"truncated":false}}"#, exitCode: 0)
            case "execute":
                let affected = sql.contains("UPDATE") ? 3 : 2
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"rowsAffected":\#(affected)}}"#, exitCode: 0)
            default:
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":[]}"#, exitCode: 0)
            }
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store,
            recoveryStore: MacDatabaseRecoveryStore(rootURL: recoveryRoot),
            fileStorage: MacFileStorage()
        )

        await feature.select(profile)
        feature.addSQLTab(sql: "INSERT INTO items VALUES (1); SELECT 1; UPDATE items SET value = 2 WHERE id = 1;")
        let tabID = try #require(feature.selectedSQLTabID)
        await feature.runSQL(in: tabID, confirmedRisk: true)

        let sqlRequests = runner.requests.compactMap { request -> (String, String)? in
            guard let input = request.standardInput,
                  let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                  let method = object["method"] as? String,
                  method == "query" || method == "execute",
                  let params = object["params"] as? [String: Any],
                  let sql = params["sql"] as? String else { return nil }
            return (method, sql)
        }
        #expect(sqlRequests.map(\.0) == ["execute", "query", "execute"])
        #expect(sqlRequests.map(\.1) == [
            "INSERT INTO items VALUES (1)",
            "SELECT 1",
            "UPDATE items SET value = 2 WHERE id = 1"
        ])
        #expect(feature.selectedSQLTab?.result?.rows.count == 1)
        #expect(feature.selectedSQLTab?.rowsAffected == 5)
        #expect(feature.selectedSQLTab?.execution?.rowsReturned == 1)
        #expect(feature.sqlHistory.first?.sql.contains("SELECT 1") == true)
    }

    @Test
    @MainActor
    func databaseSQLBatchStopsAfterTheFirstFailedStatement() async throws {
        let preferences = DatabaseTestKeyValueStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseTestSecureStore())
        let profile = DatabaseProfile(name: "SQLite", kind: .sqlite, path: "/tmp/lithe-batch-failure.sqlite")
        try store.save([profile])
        let runner = RecordingProcessRunner { request in
            let input = try! #require(request.standardInput)
            let object = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
            let id = object["id"] as! String
            let method = object["method"] as! String
            let params = object["params"] as? [String: Any]
            let sql = params?["sql"] as? String ?? ""
            if method == "query", sql.contains("bad") {
                return ProcessResult(output: #"{"id":"\#(id)","ok":false,"error":{"code":"syntax_error","message":"near bad"}}"#, exitCode: 0)
            }
            if method == "query" {
                return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":{"rows":[{"value":1}],"columns":["value"],"truncated":false}}"#, exitCode: 0)
            }
            return ProcessResult(output: #"{"id":"\#(id)","ok":true,"result":[]}"#, exitCode: 0)
        }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/tmp/lithe-db-sidecar")),
            connectionStore: store
        )

        await feature.select(profile)
        feature.addSQLTab(sql: "SELECT 1; SELECT bad; SELECT 3;")
        let tabID = try #require(feature.selectedSQLTabID)
        await feature.runSQL(in: tabID)

        let querySQL = runner.requests.compactMap { request -> String? in
            guard let input = request.standardInput,
                  let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                  object["method"] as? String == "query",
                  let params = object["params"] as? [String: Any] else { return nil }
            return params["sql"] as? String
        }
        #expect(querySQL == ["SELECT 1", "SELECT bad"])
        #expect(feature.selectedSQLTab?.errorMessage?.contains("Statement 2 failed") == true)
        #expect(feature.sqlHistory.isEmpty)
    }

    @Test
    func databaseQueryResultPreservesProtocolColumnOrder() throws {
        let data = Data(#"{"columns":["z_col","a_col"],"rows":[{"z_col":1,"a_col":2}],"truncated":false}"#.utf8)
        let result = try JSONDecoder().decode(DatabaseQueryResult.self, from: data)
        #expect(result.columns == ["z_col", "a_col"])
        #expect(result.rows.first?["z_col"] == .integer(1))
    }

    @Test
    func databaseMongoQueryFixtureDecodesExtendedJSONWithoutLosingDocuments() throws {
        let data = Data(#"{"rows":[{"_id":{"$oid":"507f1f77bcf86cd799439011"},"empty":"","null":null,"nested":{"base64":"AAEC"},"array":[1,{"$date":"2024-01-01T00:00:00Z"}],"binary":{"$binary":{"base64":"AAEC","subType":"00"}}}],"truncated":false}"#.utf8)
        let result = try JSONDecoder().decode(DatabaseQueryResult.self, from: data)
        let row = try #require(result.rows.first)
        #expect(row["empty"] == .string(""))
        #expect(row["null"] == .null)
        #expect(row["_id"] == .object(["$oid": .string("507f1f77bcf86cd799439011")]))
        #expect(row["nested"] == .object(["base64": .string("AAEC")]))
        #expect(row["binary"] == .object(["$binary": .object(["base64": .string("AAEC"), "subType": .string("00")])]))
    }

    @Test
    func databaseValuePreservesTaggedDecimalAndBinaryValues() throws {
        let data = Data(#"[{"decimal":"0.00"},{"binary":"AAEC"}]"#.utf8)
        let values = try JSONDecoder().decode([DatabaseValue].self, from: data)
        #expect(values == [.decimal("0.00"), .binary(Data([0, 1, 2]))])
        let encoded = try JSONEncoder().encode(values)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""decimal":"0.00""#))
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""binary":"AAEC""#))
        let mongoObject = try JSONDecoder().decode(DatabaseValue.self, from: Data(#"{"base64":"AAEC"}"#.utf8))
        #expect(mongoObject == .object(["base64": .string("AAEC")]))
    }

    @Test
    func databaseSQLFormatterPreservesQuotedTextAndNormalizesKeywords() {
        let formatted = DatabaseSQLFormatter.format("select  name, 'a  b' from users where id=1;")
        #expect(formatted.contains("SELECT name, 'a  b' FROM users WHERE id = 1;"))
        let withComment = DatabaseSQLFormatter.format("select -- keep this text\nfrom users")
        #expect(withComment.contains("-- keep this text"))
        #expect(withComment.contains("FROM users"))
    }

    @Test
    func databaseSQLHistoryIsBoundedAndKeepsOnlyProfileReferences() throws {
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let profileID = UUID()

        for index in 0..<105 {
            try store.appendSQLHistory(DatabaseSQLHistoryEntry(
                profileID: profileID,
                sql: "SELECT \(index)",
                kind: .query,
                executedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                durationMilliseconds: index
            ))
        }

        let history = store.loadSQLHistory()
        #expect(history.count == 100)
        #expect(history.first?.sql == "SELECT 104")
        #expect(history.allSatisfy { $0.profileID == profileID })
        let encoded = try #require(preferences.data(forKey: "database.sql-history.v1"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("password"))
    }

    @Test
    func databaseRecoveryStoreRoundTripsCompressedSnapshotsAndAudit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacDatabaseRecoveryStore(rootURL: root)
        let profileID = UUID()
        let snapshot = Data(repeating: 65, count: 128 * 1_024)
        let point = try store.createRecoveryPoint(profileID: profileID, reason: "test", data: snapshot)

        #expect(point.profileID == profileID)
        #expect(point.isCompressed)
        #expect(point.sha256.count == 64)
        #expect(try store.data(for: point) == snapshot)

        let audit = DatabaseAuditEntry(id: UUID(), profileID: profileID, action: "test", summary: "snapshot", createdAt: Date(), recoveryPointID: point.id, rowsAffected: nil, succeeded: true, errorMessage: nil)
        try store.appendAudit(audit)
        let loadedAudit = try #require(store.auditEntries(for: profileID).first)
        #expect(loadedAudit.id == audit.id)
        #expect(loadedAudit.profileID == profileID)
        #expect(loadedAudit.recoveryPointID == point.id)
        #expect(loadedAudit.summary == "snapshot")

        let event = DatabaseExecutionEvent(
            id: UUID(), profileID: profileID, profileName: "Test DB", source: .sql,
            operation: "query", startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationMilliseconds: 12,
            status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: "syntax error"
        )
        try store.appendExecutionEvent(event)
        let loadedEvent = try #require(store.executionEvents(for: profileID).first)
        #expect(loadedEvent == event)
        try store.deleteExecutionEvents(for: profileID)
        #expect(store.executionEvents(for: profileID).isEmpty)
    }

    @Test
    func databaseRecoveryStoreCopiesAndValidatesFileBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-recovery-file-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source.sql")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = Data("CREATE TABLE items (id INTEGER);\n".utf8)
        try contents.write(to: source)

        let store = MacDatabaseRecoveryStore(rootURL: root.appendingPathComponent("store"))
        let point = try store.createRecoveryPoint(profileID: UUID(), reason: "file", fileURL: source)
        #expect(!point.isCompressed)
        #expect(point.originalByteCount == contents.count)
        #expect(try store.fileURL(for: point).lastPathComponent == point.fileName)
        #expect(try store.data(for: point) == contents)

        try Data("tampered".utf8).write(to: root.appendingPathComponent("store").appendingPathComponent(point.fileName))
        #expect(throws: CocoaError(.fileReadCorruptFile)) { try store.data(for: point) }
    }

    @Test
    func databaseProfilesDecodeLegacyPreferencesWithSafeDefaults() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","kind":"mysql","host":"127.0.0.1","port":3306,"username":"root","database":"app","path":"","ssl":false}]
        """
        let preferences = DatabaseTestKeyValueStore()
        let secrets = DatabaseTestSecureStore()
        preferences.set(Data(legacy.utf8), forKey: "database.profiles.v1")
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let profile = try #require(store.load().first)

        #expect(profile.readOnly == false)
        #expect(profile.productionProtection == false)
        #expect(profile.maskSensitiveFields == false)
        #expect(profile.sensitiveColumnPatterns.contains("password"))
    }

    @Test
    func databaseSensitiveFieldMaskerMasksConfiguredColumnsWithoutChangingNulls() {
        let rows: [DatabaseRow] = [[
            "id": .integer(7),
            "email": .string("user@example.com"),
            "api_token": .string("secret-value"),
            "password": .null
        ]]

        let masked = DatabaseSensitiveFieldMasker.mask(
            rows: rows,
            enabled: true,
            patterns: ["token", "password"]
        )

        #expect(masked[0]["id"] == .integer(7))
        #expect(masked[0]["email"] == .string("user@example.com"))
        #expect(masked[0]["api_token"] == .string("******"))
        #expect(masked[0]["password"] == .null)
        #expect(DatabaseSensitiveFieldMasker.mask(rows: rows, enabled: false, patterns: ["token"]) == rows)
    }

    @Test
    func databaseSchemaDiffReportsTableColumnAndDestructiveChanges() {
        let source = DatabaseSchemaSnapshot(
            profileID: UUID(),
            profileName: "Source",
            kind: .sqlite,
            schema: "",
            tables: [DatabaseSchemaTableSnapshot(
                name: "users",
                columns: [
                    DatabaseSchemaColumnSnapshot(name: "id", dataType: "INTEGER", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                    DatabaseSchemaColumnSnapshot(name: "email", dataType: "TEXT", isNullable: false, defaultValue: nil, isPrimaryKey: false),
                    DatabaseSchemaColumnSnapshot(name: "active", dataType: "INTEGER", isNullable: true, defaultValue: "1", isPrimaryKey: false)
                ],
                indexes: [],
                foreignKeys: []
            )]
        )
        let target = DatabaseSchemaSnapshot(
            profileID: UUID(),
            profileName: "Target",
            kind: .sqlite,
            schema: "",
            tables: [DatabaseSchemaTableSnapshot(
                name: "users",
                columns: [
                    DatabaseSchemaColumnSnapshot(name: "id", dataType: "INTEGER", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                    DatabaseSchemaColumnSnapshot(name: "name", dataType: "TEXT", isNullable: true, defaultValue: nil, isPrimaryKey: false)
                ],
                indexes: [],
                foreignKeys: []
            )]
        )

        let diff = DatabaseSchemaDiffEngine.compare(source: source, target: target)
        #expect(diff.items.map(\.kind).contains(.addColumn))
        #expect(diff.items.map(\.kind).contains(.dropColumn))
        #expect(diff.requiresConfirmation)
        #expect(diff.migrationSQL.contains("ADD COLUMN \"email\" TEXT NOT NULL"))
        #expect(diff.migrationSQL.contains("DROP COLUMN \"name\""))
    }

    @Test
    func databaseSchemaDiffCreatesReferencedTablesBeforeIndexes() {
        let source = DatabaseSchemaSnapshot(
            profileID: UUID(),
            profileName: "Source",
            kind: .sqlite,
            schema: "",
            tables: [
                DatabaseSchemaTableSnapshot(
                    name: "posts",
                    columns: [
                        DatabaseSchemaColumnSnapshot(name: "id", dataType: "INTEGER", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                        DatabaseSchemaColumnSnapshot(name: "user_id", dataType: "INTEGER", isNullable: false, defaultValue: nil, isPrimaryKey: false)
                    ],
                    indexes: [DatabaseSchemaIndexSnapshot(name: "idx_posts_user", definition: "CREATE INDEX \"idx_posts_user\" ON \"posts\" (\"user_id\")")],
                    foreignKeys: [DatabaseSchemaForeignKeySnapshot(name: "0", column: "user_id", referencedTable: "users", referencedColumn: "id")]
                ),
                DatabaseSchemaTableSnapshot(
                    name: "users",
                    columns: [DatabaseSchemaColumnSnapshot(name: "id", dataType: "INTEGER", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
                    indexes: [],
                    foreignKeys: []
                )
            ]
        )
        let target = DatabaseSchemaSnapshot(profileID: UUID(), profileName: "Target", kind: .sqlite, schema: "", tables: [])

        let diff = DatabaseSchemaDiffEngine.compare(source: source, target: target)
        let createdTables = diff.items.filter { $0.kind == .addTable }.map(\.table)
        let indexPosition = try! #require(diff.items.firstIndex { $0.id == "add-index:posts:idx_posts_user" })
        let postPosition = try! #require(diff.items.firstIndex { $0.id == "add-table:posts" })

        #expect(createdTables == ["users", "posts"])
        #expect(indexPosition > postPosition)
        #expect(diff.items[postPosition].sql.contains("FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\")"))
    }

    @Test
    func updateDownloadProgressReportsKnownAndUnknownTotals() {
        let progress = UpdateDownloadProgress(downloadedBytes: 512, totalBytes: 2_048)

        #expect(progress.fractionCompleted == 0.25)
        #expect(progress.percentage == 25)
        #expect(UpdateDownloadProgress.initial.fractionCompleted == nil)
        #expect(UpdateDownloadProgress.initial.percentage == nil)
    }

    @Test
    func textFilePolicyRecognizesPlainTextRegardlessOfExtension() {
        #expect(WorkspaceTextFilePolicy.isPlainText("{\n  \"version\": 3\n}\n"))
        #expect(WorkspaceTextFilePolicy.isPlainText("plain text with an unknown suffix"))
        #expect(WorkspaceTextFilePolicy.isPlainText(Data("Package.resolved\n".utf8)))
        #expect(!WorkspaceTextFilePolicy.isPlainText("text\0binary"))
        #expect(!WorkspaceTextFilePolicy.isPlainText("text\u{1B}[31m"))
        #expect(!WorkspaceTextFilePolicy.isPlainText(Data([0x00, 0x01, 0x02])))
    }

    @Test
    @MainActor
    func standaloneEditorLoadsUtf8TextAndLeavesBinaryFilesInFailedState() async {
        let storage = InMemoryFileStorage()
        let textURL = URL(fileURLWithPath: "/in-memory/notes.txt")
        let binaryURL = URL(fileURLWithPath: "/in-memory/archive.bin")
        storage.seed(Data("let answer = 42\n".utf8), at: textURL)
        storage.seed(Data([0x00, 0x01, 0x02]), at: binaryURL)

        let feature = DocumentFeatureModel(
            operations: EmptyWorkspaceOperations(readFileValue: nil),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: storage,
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        feature.configure(
            workspaceURLProvider: { nil },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )

        feature.openStandaloneFile(textURL)
        for _ in 0..<100 where feature.standaloneFileLoadState == .loading {
            await Task.yield()
        }
        #expect(feature.standaloneFileLoadState == .loaded)
        #expect(feature.activeDocument?.text == "let answer = 42\n")

        feature.openStandaloneFile(binaryURL)
        for _ in 0..<100 where feature.standaloneFileLoadState == .loading {
            await Task.yield()
        }
        #expect(feature.standaloneFileLoadState == .failed(.notText))
        #expect(feature.activeDocument == nil)
    }

    @Test @MainActor
    func binaryFileViewerRegistryPrefersMagicAndDefaultsToDeny() async {
        let registry = BinaryFileViewerRegistry()
        var opened: [BinaryFileOpenRequest] = []

        // This deliberately uses a fictional suffix and magic value. It tests
        // the extension point without implying that the app supports any real
        // binary format such as PNG or JPEG.
        registry.register(BinaryFileViewerRegistration(
            identifier: "test.fixture-viewer",
            fileExtensions: [".lithe-binary-fixture"],
            magicSignatures: [BinaryFileMagicSignature(
                bytes: Data([0xDE, 0xAD, 0xBE, 0xEF])
            )],
            open: { opened.append($0) }
        ))

        // A magic match must work even when the filename suffix does not match.
        let magicMatchedURL = URL(fileURLWithPath: "/tmp/fixture.bin")
        let fixtureHeader = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00])
        #expect(await registry.openIfSupported(url: magicMatchedURL, header: fixtureHeader))
        #expect(opened.last?.match == .magicSignature)

        // Extensions are normalized and used only when no magic value matches.
        let extensionURL = URL(fileURLWithPath: "/tmp/fixture.LITHE-BINARY-FIXTURE")
        #expect(await registry.openIfSupported(url: extensionURL, header: Data([0x00])))
        #expect(opened.last?.match == .fileExtension("lithe-binary-fixture"))

        // Anything not explicitly registered remains denied by default.
        let unsupportedURL = URL(fileURLWithPath: "/tmp/archive.bin")
        #expect(!(await registry.openIfSupported(url: unsupportedURL, header: Data([0x00]))))
        #expect(opened.count == 2)
    }

    @Test @MainActor
    func staleBinaryFileOpenDoesNotCrossWorkspaceBoundaries() async throws {
        let firstWorkspace = URL(fileURLWithPath: "/workspace-a", isDirectory: true)
        let secondWorkspace = URL(fileURLWithPath: "/workspace-b", isDirectory: true)
        let imageURL = firstWorkspace.appendingPathComponent("preview.png")
        let storage = InMemoryFileStorage()
        storage.seed(Data([0x89, 0x50, 0x4E, 0x47]), at: imageURL)
        let operations = BlockingBinaryWorkspaceOperations()
        let registry = BinaryFileViewerRegistry()
        var openedURLs: [URL] = []
        registry.register(BinaryFileViewerRegistration(
            identifier: "test.image-viewer",
            fileExtensions: ["png"],
            open: { openedURLs.append($0.url) }
        ))
        var workspaceURL: URL? = firstWorkspace
        let feature = DocumentFeatureModel(
            operations: operations,
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: storage,
            binaryFileViewerRegistry: registry
        )
        feature.configure(
            workspaceURLProvider: { workspaceURL },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )

        let openTask = Task {
            await feature.openFileAsync(
                imageURL,
                isReadOnly: false,
                displayPath: nil,
                activateWhenReady: true
            )
        }
        defer {
            openTask.cancel()
            operations.releaseRead()
        }
        try #require(await operations.waitUntilReadingStarts())
        workspaceURL = secondWorkspace
        feature.reset()
        operations.releaseRead()
        await openTask.value

        #expect(!operations.didTimeOut)
        #expect(openedURLs.isEmpty)
    }

    @Test
    func languageServerTextEditsUseUTF16AndApplyFromTheEnd() throws {
        let result = try LanguageServerTextEditApplicator.apply([
            LanguageServerTextEdit(
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: 0, utf16Column: 4),
                    end: LanguageServerPosition(line: 0, utf16Column: 6)
                ),
                newText: "rocket"
            ),
            LanguageServerTextEdit(
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: 1, utf16Column: 4),
                    end: LanguageServerPosition(line: 1, utf16Column: 9)
                ),
                newText: "four"
            )
        ], to: "one 😀\ntwo three\n")

        #expect(result == "one rocket\ntwo four\n")
    }

    @Test
    func languageServerTextEditsRejectInvalidAndOverlappingRanges() {
        #expect(throws: LanguageServerTextEditApplicator.Error.invalidRange) {
            try LanguageServerTextEditApplicator.apply([
                LanguageServerTextEdit(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: 9, utf16Column: 0),
                        end: LanguageServerPosition(line: 9, utf16Column: 1)
                    ),
                    newText: "x"
                )
            ], to: "one line")
        }
        #expect(throws: LanguageServerTextEditApplicator.Error.overlappingEdits) {
            try LanguageServerTextEditApplicator.apply([
                LanguageServerTextEdit(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: 0, utf16Column: 0),
                        end: LanguageServerPosition(line: 0, utf16Column: 4)
                    ),
                    newText: "a"
                ),
                LanguageServerTextEdit(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: 0, utf16Column: 2),
                        end: LanguageServerPosition(line: 0, utf16Column: 6)
                    ),
                    newText: "b"
                )
            ], to: "one line")
        }
    }

    @Test
    func fileVisibilityRulesHideBuiltInAndCustomPatterns() {
        let root = URL(fileURLWithPath: "/tmp/lithe-visibility-tests")
        let rules = FileVisibilityRules(hiddenDirectoryNames: ["generated"], hiddenFilePatterns: ["*.generated.swift"])

        #expect(
            rules.isHidden(
                root.appendingPathComponent(".git/config"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent(".worktree/feature/src/App.java"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent(".worktrees/feature"),
                relativeTo: root,
                isDirectory: true
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent("Sources/generated"),
                relativeTo: root,
                isDirectory: true
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent("Sources/Model.generated.swift"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent(".lithe/run/local.json"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            !rules.isHidden(
                root.appendingPathComponent(".lithe/run/configurations.json"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            !rules.isHidden(
                root.appendingPathComponent("Sources/Model.swift"),
                relativeTo: root,
                isDirectory: false
            )
        )
    }

    @Test
    func diffParserPairsChangedRowsAndTracksHunk() {
        let patch = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,2 +1,2 @@
         title
        -old text
        +new text
        """

        let document = DiffParser.parseDocument(patch)
        #expect(document.hunks.count == 1)
        #expect(document.hunks[0].id == "hunk-0")
        #expect(document.rows.contains { row in
            row.kind == .changed && row.left == "old text" && row.rightText == "new text"
        })
    }

    @Test
    func diffParserStoresSharedContextTextOnceAndKeepsRowIdentityStable() {
        let patch = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,3 +1,3 @@
         title
        -old text
        +new text
         footer
        """

        let first = DiffParser.parseDocument(patch)
        let context = first.rows.filter { $0.kind == .context }
        #expect(context.count == 2)

        // Context rows carry identical text on both sides, so only `left` is
        // stored and `rightText` falls back to it.
        for row in context {
            #expect(row.storedRight == nil)
            #expect(row.rightText == row.left)
        }

        // Hunks no longer duplicate rows; grouping happens via hunkID.
        #expect(first.rows.allSatisfy { $0.hunkID == "hunk-0" })

        // Row identity is derived, not random, so re-parsing keeps scroll and
        // selection state anchored across a refresh.
        let second = DiffParser.parseDocument(patch)
        #expect(first.rows.map(\.id) == second.rows.map(\.id))
        #expect(Set(first.rows.map(\.id)).count == first.rows.count)
    }

    @Test
    func diffContentWidthGrowsPastViewportSoLongLinesStayReachable() {
        let longLine = String(repeating: "x", count: 400)
        let rows = [
            DiffRow(oldLine: 1, newLine: 1, left: "short", right: nil, kind: .context, sequence: 0),
            DiffRow(
                oldLine: nil,
                newLine: 2,
                left: nil,
                right: longLine,
                kind: .addition,
                sequence: 1
            )
        ]

        // A wide window used to clamp content width to the viewport, which left
        // the tail of a long line truncated and unreachable.
        let viewport: CGFloat = 1_600
        let width = DiffLayoutMetrics.contentWidth(
            rows: rows,
            viewportWidth: viewport,
            minimumWidth: 980,
            paneCount: 2
        )
        #expect(width > viewport)

        let expectedText = CGFloat(400) * DiffLayoutMetrics.characterWidth
        let expected = (DiffLayoutMetrics.paneChromeWidth + expectedText) * 2
            + DiffLayoutMetrics.centerGutterWidth
        #expect(abs(width - expected) < 0.5)

        // Short content still fills the viewport rather than collapsing.
        let shortRows = [
            DiffRow(oldLine: 1, newLine: 1, left: "hi", right: nil, kind: .context, sequence: 0)
        ]
        #expect(
            DiffLayoutMetrics.contentWidth(
                rows: shortRows,
                viewportWidth: viewport,
                minimumWidth: 980,
                paneCount: 2
            ) == viewport
        )
    }

    @Test
    func diffContentWidthCountsTabsAsFourColumns() {
        let rows = [
            DiffRow(oldLine: 1, newLine: 1, left: "\t\tend", right: nil, kind: .context, sequence: 0)
        ]

        // Two tabs plus three characters render as 11 columns, not 5.
        #expect(DiffLayoutMetrics.longestLineLength(rows: rows) == 11)
    }

    @Test
    func splitDiffLayoutKeepsBothCodeStreamsDenseAcrossInsertionsAndDeletions() {
        let insertionRows = [
            DiffRow(oldLine: 1, newLine: 1, left: "before", right: nil, kind: .context, sequence: 0),
            DiffRow(oldLine: nil, newLine: 2, left: nil, right: "added 1", kind: .addition, sequence: 1),
            DiffRow(oldLine: nil, newLine: 3, left: nil, right: "added 2", kind: .addition, sequence: 2),
            DiffRow(oldLine: nil, newLine: 4, left: nil, right: "added 3", kind: .addition, sequence: 3),
            DiffRow(oldLine: 2, newLine: 5, left: "after", right: nil, kind: .context, sequence: 4)
        ]
        let insertionDisplay = insertionRows.enumerated().map {
            DiffDisplayRow.row($0.element, index: $0.offset)
        }
        let insertion = DiffSplitLayout.plan(
            displayRows: insertionDisplay,
            kinds: insertionRows.map(\.kind)
        )

        // The old side advances directly from `before` to `after`; it does not
        // receive three synthetic blank rows to match the new side.
        #expect(insertion.leftItems.map(\.top) == [0, 24])
        #expect(insertion.rightItems.map(\.top) == [0, 24, 48, 72, 96])
        #expect(insertion.leftHeight == 48)
        #expect(insertion.rightHeight == 120)
        #expect(insertion.transitions.count == 1)
        #expect(insertion.transitions[0].isAddition)
        #expect(insertion.transitions[0].leftRange == 24...24)
        #expect(insertion.transitions[0].rightRange == 24...96)

        let removalRows = insertionRows.map { row in
            switch row.kind {
            case .addition:
                return DiffRow(
                    oldLine: row.newLine,
                    newLine: nil,
                    left: row.rightText,
                    right: nil,
                    kind: .removal,
                    sequence: row.id.sequence
                )
            default:
                return row
            }
        }
        let removal = DiffSplitLayout.plan(
            displayRows: removalRows.enumerated().map {
                DiffDisplayRow.row($0.element, index: $0.offset)
            },
            kinds: removalRows.map(\.kind)
        )

        #expect(removal.leftItems.map(\.top) == [0, 24, 48, 72, 96])
        #expect(removal.rightItems.map(\.top) == [0, 24])
        #expect(removal.transitions.count == 1)
        #expect(removal.transitions[0].isRemoval)
        #expect(removal.transitions[0].leftRange == 24...96)
        #expect(removal.transitions[0].rightRange == 24...24)
    }

    @Test
    func diffCollapseFoldsLongUnchangedRunsAndKeepsSurroundingContext() {
        var rows: [DiffRow] = []
        for line in 1...40 {
            rows.append(
                DiffRow(
                    oldLine: line,
                    newLine: line,
                    left: "line \(line)",
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                )
            )
        }
        rows.append(
            DiffRow(oldLine: 41, newLine: 41, left: "old", right: "new", kind: .changed, sequence: 40)
        )

        let plan = DiffCollapse.plan(rows: rows)
        let bands = plan.compactMap { row -> DiffCollapsedRegion? in
            guard case let .collapsed(region) = row else { return nil }
            return region
        }

        #expect(bands.count == 1)
        // Leading run starts the file, so only trailing context is retained.
        #expect(bands[0].startIndex == 0)
        #expect(bands[0].endIndex == 37)
        #expect(bands[0].hiddenRowCount == 37)

        // Three context rows plus the change survive alongside the band.
        #expect(plan.count == 5)
        guard case let .row(lastRow, lastIndex) = plan[4] else {
            Issue.record("Expected the changed row to stay visible")
            return
        }
        #expect(lastRow.kind == .changed)
        // The carried index still points at the row's slot in the source list.
        #expect(lastIndex == rows.count - 1)

        // Expanding the band restores every row.
        let expanded = DiffCollapse.plan(rows: rows, expandedRegionIDs: [bands[0].id])
        #expect(expanded.count == rows.count)
        #expect(!expanded.contains { if case .collapsed = $0 { return true } else { return false } })
    }

    @Test
    func diffCollapseKeepsPinnedRowsRenderedSoNavigationCanReachThem() {
        var rows: [DiffRow] = []
        for line in 1...40 {
            rows.append(
                DiffRow(
                    oldLine: line,
                    newLine: line,
                    left: "line \(line)",
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                )
            )
        }

        // Row 20 sits well inside the fold; a search hit there must not be hidden.
        let target = rows[19]
        let plan = DiffCollapse.plan(rows: rows, pinnedRowIDs: [target.id])

        #expect(!plan.contains { if case .collapsed = $0 { return true } else { return false } })
        #expect(plan.count == rows.count)
    }

    @Test
    func diffCollapseLeavesShortRunsAndHunkHeadersAlone() {
        var rows = [
            DiffRow(oldLine: nil, newLine: nil, left: "@@ -1,4 +1,4 @@", right: nil, kind: .information, sequence: 0)
        ]
        for line in 1...6 {
            rows.append(
                DiffRow(
                    oldLine: line,
                    newLine: line,
                    left: "line \(line)",
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                )
            )
        }

        // Six unchanged lines fall under the threshold, so nothing folds and the
        // `@@` header is never swallowed.
        let plan = DiffCollapse.plan(rows: rows)
        #expect(plan.count == rows.count)
        #expect(!plan.contains { if case .collapsed = $0 { return true } else { return false } })
    }

    @Test
    func localHistoryDiffBuilderProducesChangedRow() {
        let rows = LocalHistoryDiffBuilder.rows(old: "before\n", current: "after\n")

        #expect(rows.count == 1)
        #expect(rows[0].kind == .changed)
        #expect(rows[0].left == "before")
        #expect(rows[0].rightText == "after")
    }

    @Test
    func localHistoryDiffPairsSimilarLinesAndSeparatesUnrelatedOnes() {
        // The added comment used to be paired positionally with the statement,
        // labelling two unrelated lines as one modification.
        let rows = LocalHistoryDiffBuilder.rows(
            old: "let total = compute(a, b)\n",
            current: "// recompute\nlet total = compute(a, b, c)\n"
        )

        #expect(rows.map(\.kind) == [.addition, .changed])
        #expect(rows[1].left == "let total = compute(a, b)")
        #expect(rows[1].rightText == "let total = compute(a, b, c)")
    }

    @Test
    func diffPairingMatchesRustSimilarityRules() {
        // Single-line replacements always read as a modification.
        #expect(DiffPairing.pairs(removed: ["before"], added: ["after"]).count == 1)

        // Nothing clears the floor, so no pair keeps both sides.
        let unrelated = DiffPairing.pairs(
            removed: ["import Foundation", "import AppKit"],
            added: ["let x = 1", "let y = 2", "let z = 3"]
        )
        #expect(unrelated.count == 5)
        #expect(unrelated.allSatisfy { $0.0 == nil || $0.1 == nil })

        // Reindentation alone is a perfect match; empty against text is none.
        #expect(DiffPairing.similarity("    return value", "\t\treturn value") == 1)
        #expect(DiffPairing.similarity("abc", "") == 0)
    }

    @Test
    @MainActor
    func diffMapGroupsAdjacentChangesAndKeepsSingleLinesVisible() {
        var rows: [DiffRow] = []
        func append(_ kind: DiffRowKind, count: Int) {
            for _ in 0..<count {
                rows.append(
                    DiffRow(
                        oldLine: rows.count + 1,
                        newLine: rows.count + 1,
                        left: "l",
                        right: "r",
                        kind: kind,
                        sequence: rows.count
                    )
                )
            }
        }

        append(.context, count: 40)
        append(.addition, count: 3)
        append(.context, count: 50)
        append(.removal, count: 1)
        append(.context, count: 6)

        let markers = DiffMapView(rows: rows) { _ in }.markers

        // A three-line run is one band, not three ticks.
        #expect(markers.count == 2)
        #expect(markers.map(\.kind) == [.addition, .removal])
        #expect(abs(markers[0].start - 40.0 / 100.0) < 0.001)
        #expect(abs(markers[0].extent - 3.0 / 100.0) < 0.001)

        // A single removal is floored so it stays clickable rather than
        // collapsing to a sub-pixel sliver.
        #expect(markers[1].extent >= DiffMapView.minimumExtent)
        #expect(markers[1].id == rows[93].id)
    }

    @Test
    func markdownPreviewUsesAdaptiveDebouncingAndDecodesCorePayload() throws {
        #expect(MarkdownPreviewDebounce.nanoseconds(forByteCount: 1_000) == 120_000_000)
        #expect(MarkdownPreviewDebounce.nanoseconds(forByteCount: 20_000) == 220_000_000)
        #expect(MarkdownPreviewDebounce.nanoseconds(forByteCount: 200_000) == 360_000_000)

        let payload = try JSONDecoder().decode(
            RustCoreBridge.MarkdownRenderPayload.self,
            from: Data(#"{"html":"<h1>Preview</h1>"}"#.utf8)
        )
        #expect(payload.html == "<h1>Preview</h1>")
    }

    @Test
    func markdownPreviewResourcesAreBundledAndPlantUMLFree() throws {
        let templateURL = try #require(MarkdownPreviewResources.templateURL)
        let directoryURL = try #require(MarkdownPreviewResources.directoryURL)
        #expect(FileManager.default.fileExists(atPath: templateURL.path))
        #expect(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("preview.js").path))
        #expect(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("vendor/katex.min.js").path))
        #expect(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("vendor/mermaid.min.js").path))

        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let runtime = try String(
            contentsOf: directoryURL.appendingPathComponent("preview.js"),
            encoding: .utf8
        )
        #expect(!template.lowercased().contains("plantuml"))
        #expect(!runtime.lowercased().contains("plantuml"))
        #expect(!template.contains("script src=\"http"))
        #expect(template.contains("connect-src 'none'"))
    }

    @Test
    func markdownAssetResolverStaysInsideWorkspaceAndRejectsSymlinkEscapes() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-markdown-assets-\(UUID().uuidString)", isDirectory: true)
        let workspace = temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
        let documents = workspace.appendingPathComponent("docs", isDirectory: true)
        let assets = workspace.appendingPathComponent("assets", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let image = assets.appendingPathComponent("preview.png")
        let secret = outside.appendingPathComponent("secret.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: secret)
        try fileManager.createSymbolicLink(
            at: workspace.appendingPathComponent("escaped.png"),
            withDestinationURL: secret
        )
        let document = documents.appendingPathComponent("guide.md")

        func request(scope: String, path: String) throws -> URL {
            var components = URLComponents()
            components.scheme = MarkdownPreviewAssetResolver.scheme
            components.host = scope
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            return try #require(components.url)
        }

        #expect(
            MarkdownPreviewAssetResolver.resolve(
                requestURL: try request(scope: "document", path: "../assets/preview.png"),
                documentURL: document,
                workspaceURL: workspace
            ) == image.standardizedFileURL
        )
        #expect(
            MarkdownPreviewAssetResolver.resolve(
                requestURL: try request(scope: "workspace", path: "assets/preview.png"),
                documentURL: document,
                workspaceURL: workspace
            ) == image.standardizedFileURL
        )
        #expect(
            MarkdownPreviewAssetResolver.resolve(
                requestURL: try request(scope: "document", path: "../../outside/secret.png"),
                documentURL: document,
                workspaceURL: workspace
            ) == nil
        )
        #expect(
            MarkdownPreviewAssetResolver.resolve(
                requestURL: try request(scope: "workspace", path: "escaped.png"),
                documentURL: document,
                workspaceURL: workspace
            ) == nil
        )
    }

    @Test
    func markdownImageImportStoresAssetsAndAvoidsFilenameCollisions() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-markdown-image-import-\(UUID().uuidString)", isDirectory: true)
        let workspace = temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
        let documents = workspace.appendingPathComponent("docs", isDirectory: true)
        let document = documents.appendingPathComponent("guide.md")
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try "# Guide".write(to: document, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let importer = MarkdownImageImportService(storage: MacFileStorage())
        let source = MarkdownImageSource.encoded(
            data: imageData,
            format: .png,
            suggestedName: "Screen Shot (Final)"
        )
        let first = try await importer.importImage(
            source,
            forDocumentAt: document,
            workspaceRoot: workspace
        )
        let second = try await importer.importImage(
            source,
            forDocumentAt: document,
            workspaceRoot: workspace
        )

        #expect(first.relativePath == "assets/screen-shot-final.png")
        #expect(first.markdownReference == "![screen shot final](assets/screen-shot-final.png)")
        #expect(second.relativePath == "assets/screen-shot-final-2.png")
        #expect(try Data(contentsOf: first.fileURL) == imageData)
        #expect(try Data(contentsOf: second.fileURL) == imageData)
    }

    @Test
    func markdownImageImportRejectsAssetSymlinkOutsideWorkspace() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-markdown-image-symlink-\(UUID().uuidString)", isDirectory: true)
        let workspace = temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
        let documents = workspace.appendingPathComponent("docs", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        let document = documents.appendingPathComponent("guide.md")
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# Guide".write(to: document, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: documents.appendingPathComponent("assets", isDirectory: true),
            withDestinationURL: outside
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let importer = MarkdownImageImportService(storage: MacFileStorage())
        await #expect(throws: MarkdownImageImportError.destinationOutsideWorkspace) {
            try await importer.importImage(
                .encoded(data: Data([1, 2, 3]), format: .png, suggestedName: nil),
                forDocumentAt: document,
                workspaceRoot: workspace
            )
        }
    }

    @Test
    func markdownClipboardReaderRecognizesPNGData() throws {
        let pasteboard = NSPasteboard(name: .init("lithe-markdown-image-\(UUID().uuidString)"))
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: .png)
        defer { pasteboard.clearContents() }

        let source = try #require(MarkdownClipboardImageReader.read(from: pasteboard))
        guard case let .encoded(data, format, suggestedName) = source else {
            Issue.record("Expected encoded PNG clipboard data")
            return
        }
        #expect(data == imageData)
        #expect(format == .png)
        #expect(suggestedName == nil)
    }

    @Test
    func markdownClipboardReaderRecognizesQtScreenshotPNGData() throws {
        let pasteboard = NSPasteboard(name: .init("lithe-markdown-qt-image-\(UUID().uuidString)"))
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let qtPNGType = NSPasteboard.PasteboardType("com.trolltech.anymime.image--png")
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: qtPNGType)
        defer { pasteboard.clearContents() }

        let source = try #require(MarkdownClipboardImageReader.read(from: pasteboard))
        guard case let .encoded(data, format, suggestedName) = source else {
            Issue.record("Expected encoded Qt PNG clipboard data")
            return
        }
        #expect(data == imageData)
        #expect(format == .png)
        #expect(suggestedName == nil)
    }

    @Test
    func markdownClipboardReaderRecognizesFinderImageFile() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lithe Screenshot \(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let pasteboard = NSPasteboard(name: .init("lithe-markdown-file-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([imageURL as NSURL])
        defer { pasteboard.clearContents() }

        let source = try #require(MarkdownClipboardImageReader.read(from: pasteboard))
        guard case let .file(url, format) = source else {
            Issue.record("Expected a Finder image file URL")
            return
        }
        #expect(url == imageURL)
        #expect(format == .png)
    }

    @Test
    @MainActor
    func codeEditorInterceptsHandledImagePaste() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "before"
        var handled = false
        textView.onPasteImage = {
            handled = true
            return true
        }

        textView.paste(nil)

        #expect(handled)
        #expect(textView.string == "before")
    }

    @Test
    @MainActor
    func codeEditorDoesNotRegisterThePrivateTerminalTabDropType() {
        let textView = CodeTextView(frame: .zero)

        #expect(!textView.registeredDraggedTypes.contains(TerminalTabDragPayload.pasteboardType))
    }

    @Test
    @MainActor
    func codeEditorInterceptsCommandVPasteBeforeMenuRouting() throws {
        let textView = CodeTextView(frame: .zero)
        var handled = false
        textView.onPasteImage = {
            handled = true
            return true
        }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )

        #expect(textView.performKeyEquivalent(with: event))
        #expect(handled)
    }

    @Test
    @MainActor
    func codeEditorLanguageMenuTracksCurrentServerFeatures() {
        let textView = CodeTextView(frame: .zero)

        textView.languageServerFeatures = [.definition, .hover]
        #expect(textView.languageContextMenuItems().map(\.title) == [
            "Go to Definition", "Quick Documentation"
        ])

        textView.languageServerFeatures = [.completion, .formatting, .codeActions]
        #expect(textView.languageContextMenuItems().map(\.title) == [
            "Complete Symbol", "Format Document", "Source Actions…"
        ])

        textView.languageServerFeatures = []
        #expect(textView.languageContextMenuItems().isEmpty)
    }

    @Test
    @MainActor
    func codeEditorDoesNotRepublishUnchangedFindState() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "sample"
        var updates: [(index: Int, count: Int)] = []
        textView.onFindStateChange = { index, count in
            updates.append((index, count))
        }

        textView.syncFindState(isVisible: true, query: "", options: .default)
        textView.syncFindState(isVisible: true, query: "", options: .default)

        #expect(updates.count == 1)
        #expect(updates.first?.index == -1)
        #expect(updates.first?.count == 0)
    }

    @Test
    @MainActor
    func codeEditorLineIndexKeepsLineNumbersAfterSingleLineEdit() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "one\ntwo\nthree"
        textView.rebuildLineIndex()
        #expect(textView.lineNumber(at: 4, in: textView.string as NSString) == 1)

        textView.string = "oneX\ntwo\nthree"
        textView.applyLineIndexEdit(replacedRange: NSRange(location: 3, length: 0), replacement: "X")
        let source = textView.string as NSString
        #expect(textView.lineNumber(at: 0, in: source) == 0)
        #expect(textView.lineNumber(at: 5, in: source) == 1)
        #expect(textView.lineNumber(at: 9, in: source) == 2)
        #expect(textView.characterOffset(forLine: 2, in: source) == 9)
    }

    @Test
    func highlightedRangeCacheOnlyReturnsUncoveredText() {
        var cache = HighlightedRangeCache()
        cache.insert(NSRange(location: 10, length: 10))
        cache.insert(NSRange(location: 30, length: 10))

        #expect(cache.uncoveredRanges(in: NSRange(location: 0, length: 50)) == [
            NSRange(location: 0, length: 10),
            NSRange(location: 20, length: 10),
            NSRange(location: 40, length: 10)
        ])

        cache.insert(NSRange(location: 20, length: 10))
        #expect(cache.ranges == [NSRange(location: 10, length: 30)])
        #expect(cache.uncoveredRanges(in: NSRange(location: 15, length: 20)).isEmpty)

        cache.removeAll()
        #expect(cache.uncoveredRanges(in: NSRange(location: 5, length: 5)) == [
            NSRange(location: 5, length: 5)
        ])
    }

    @Test
    func highlightedRangeCacheShiftsUnchangedRangesAfterAnEdit() {
        var cache = HighlightedRangeCache()
        cache.insert(NSRange(location: 0, length: 10))
        cache.insert(NSRange(location: 20, length: 10))
        cache.insert(NSRange(location: 40, length: 10))

        cache.applyEdit(
            replacedRange: NSRange(location: 12, length: 4),
            replacementLength: 8
        )
        #expect(cache.ranges == [
            NSRange(location: 0, length: 10),
            NSRange(location: 24, length: 10),
            NSRange(location: 44, length: 10)
        ])

        cache.applyEdit(
            replacedRange: NSRange(location: 24, length: 10),
            replacementLength: 0
        )
        #expect(cache.ranges == [
            NSRange(location: 0, length: 10),
            NSRange(location: 34, length: 10)
        ])
    }

    @Test
    @MainActor
    func codeEditorShiftsFindMatchesAcrossASingleLineEdit() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "alpha beta alpha"
        textView.rebuildLineIndex()
        textView.updateFindMatches(query: "alpha", options: .default)
        #expect(textView.currentFindMatchCountForTesting == 2)

        textView.string = "Xalpha beta alpha"
        textView.applyFindEdit(replacedRange: NSRange(location: 0, length: 0), insertedLength: 1, query: "alpha")
        #expect(textView.currentFindMatchCountForTesting == 2)
        #expect(textView.findMatchLocationsForTesting == [1, 12])
    }

    @Test
    @MainActor
    func codeEditorReportsEachFindStateOnlyOnce() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "alpha beta alpha"
        var reportedStates: [String] = []
        textView.onFindStateChange = { index, count in
            reportedStates.append("\(index):\(count)")
        }

        textView.syncFindState(isVisible: true, query: "", options: .default)
        textView.syncFindState(isVisible: true, query: "alpha", options: .default)
        textView.syncFindState(isVisible: true, query: "alpha", options: .default)

        #expect(reportedStates == ["-1:0", "0:2"])
    }

    @Test
    @MainActor
    func codeEditorKeepsCrossLineRegexMatchesAcrossEdits() {
        // 正则可能产生跨行匹配：在匹配所在行附近编辑无关内容后，
        // 整篇重算必须找回该匹配（行窗口增量曾把它移除且无法在窗口内复原）。
        let textView = CodeTextView(frame: .zero)
        textView.string = "alpha\nbeta gamma"
        textView.rebuildLineIndex()
        let options = FindInFileOptions(regularExpression: true)
        textView.updateFindMatches(query: "a\\nb", options: options)
        #expect(textView.currentFindMatchCountForTesting == 1)
        #expect(textView.findMatchLocationsForTesting == [4])

        textView.string = "alpha\nbeXta gamma"
        textView.applyFindEdit(
            replacedRange: NSRange(location: 8, length: 0),
            insertedLength: 1,
            query: "a\\nb"
        )
        #expect(textView.currentFindMatchCountForTesting == 1)
        #expect(textView.findMatchLocationsForTesting == [4])
    }

    @Test
    @MainActor
    func replaceNotificationsOnlyApplyToTheBoundDocument() {
        let textView = CodeTextView(frame: .zero)
        let documentID = UUID()
        textView.documentID = documentID
        textView.string = "foo bar"
        textView.updateFindMatches(query: "foo", options: .default)

        // 文档不匹配的替换通知必须被忽略，防止分栏时误伤其他编辑器
        NotificationCenter.default.post(
            name: .litheFindReplaceNext,
            object: nil,
            userInfo: [
                FindNotificationKeys.documentID: UUID(),
                FindNotificationKeys.replacement: "baz"
            ]
        )
        #expect(textView.string == "foo bar")

        NotificationCenter.default.post(
            name: .litheFindReplaceNext,
            object: nil,
            userInfo: [
                FindNotificationKeys.documentID: documentID,
                FindNotificationKeys.replacement: "baz"
            ]
        )
        #expect(textView.string == "baz bar")

        NotificationCenter.default.post(
            name: .litheFindReplaceAll,
            object: nil,
            userInfo: [
                FindNotificationKeys.documentID: UUID(),
                FindNotificationKeys.replacement: "qux"
            ]
        )
        #expect(textView.string == "baz bar")
    }

    @Test
    func doubleShiftRecognizerRequiresTwoStandaloneTaps() {
        var recognizer = DoubleShiftGestureRecognizer(threshold: 0.35)

        var triggered = recognizer.handleFlagsChanged(
            isShiftDown: true,
            hasOtherModifiers: false,
            timestamp: 1.00
        )
        #expect(!triggered)
        triggered = recognizer.handleFlagsChanged(
            isShiftDown: false,
            hasOtherModifiers: false,
            timestamp: 1.05
        )
        #expect(!triggered)
        triggered = recognizer.handleFlagsChanged(
            isShiftDown: true,
            hasOtherModifiers: false,
            timestamp: 1.20
        )
        #expect(!triggered)
        triggered = recognizer.handleFlagsChanged(
            isShiftDown: false,
            hasOtherModifiers: false,
            timestamp: 1.25
        )
        #expect(triggered)
    }

    @Test
    func doubleShiftRecognizerRejectsUppercaseTypingAndInterveningKeys() {
        var recognizer = DoubleShiftGestureRecognizer(threshold: 0.35)

        _ = recognizer.handleFlagsChanged(
            isShiftDown: true,
            hasOtherModifiers: false,
            timestamp: 1.00
        )
        recognizer.handleKeyDown()
        var triggered = recognizer.handleFlagsChanged(
            isShiftDown: false,
            hasOtherModifiers: false,
            timestamp: 1.05
        )
        #expect(!triggered)
        _ = recognizer.handleFlagsChanged(
            isShiftDown: true,
            hasOtherModifiers: false,
            timestamp: 1.20
        )
        recognizer.handleKeyDown()
        triggered = recognizer.handleFlagsChanged(
            isShiftDown: false,
            hasOtherModifiers: false,
            timestamp: 1.25
        )
        #expect(!triggered)

        _ = recognizer.handleFlagsChanged(
            isShiftDown: true,
            hasOtherModifiers: false,
            timestamp: 2.00
        )
        _ = recognizer.handleFlagsChanged(
            isShiftDown: false,
            hasOtherModifiers: false,
            timestamp: 2.05
        )
        recognizer.handleKeyDown()
        _ = recognizer.handleFlagsChanged(
            isShiftDown: true,
            hasOtherModifiers: false,
            timestamp: 2.20
        )
        triggered = recognizer.handleFlagsChanged(
            isShiftDown: false,
            hasOtherModifiers: false,
            timestamp: 2.25
        )
        #expect(!triggered)
    }

    @Test
    func markdownImageInsertionSeparatesTheReferenceFromRawHTML() {
        let source = "<table>\n</table>\n"
        let reference = "![pasted image](assets/pasted-image.png)"
        let insertion = MarkdownImageInsertion.blockText(
            reference: reference,
            in: source,
            replacing: NSRange(location: (source as NSString).length, length: 0)
        )

        #expect(insertion == "\n\(reference)")
        #expect(source + insertion == "<table>\n</table>\n\n\(reference)")
    }

    @Test
    func markdownImageInsertionCreatesABlockInsideParagraphText() {
        let source = "beforeafter"
        let reference = "![diagram](assets/diagram.png)"
        let insertion = MarkdownImageInsertion.blockText(
            reference: reference,
            in: source,
            replacing: NSRange(location: 6, length: 0)
        )

        #expect(insertion == "\n\n\(reference)\n\n")
        #expect(
            (source as NSString).replacingCharacters(
                in: NSRange(location: 6, length: 0),
                with: insertion
            ) == "before\n\n\(reference)\n\nafter"
        )
    }

    @Test
    func markdownImageInsertionReusesExistingBlankLines() {
        let source = "before\n\n\n\nafter"
        let reference = "![diagram](assets/diagram.png)"
        let insertion = MarkdownImageInsertion.blockText(
            reference: reference,
            in: source,
            replacing: NSRange(location: 8, length: 0)
        )

        #expect(insertion == reference)
    }

    @Test
    func markdownScrollPositionClampsAndTracksItsControllingPane() {
        var position = MarkdownScrollPosition()

        let acceptedEditorUpdate = position.update(ratio: 1.4, source: .editor)
        #expect(acceptedEditorUpdate)
        #expect(position.ratio == 1)
        #expect(position.source == .editor)
        let ignoredDuplicateUpdate = position.update(ratio: 0.9999, source: .editor)
        #expect(!ignoredDuplicateUpdate)
        let acceptedPreviewUpdate = position.update(ratio: 1, source: .preview)
        #expect(acceptedPreviewUpdate)
        #expect(position.source == .preview)
        #expect(position.revision == 2)

        #expect(
            MarkdownScrollMetrics.ratio(
                offset: 450,
                contentHeight: 1_000,
                viewportHeight: 100
            ) == 0.5
        )
        #expect(
            MarkdownScrollMetrics.offset(
                ratio: 0.5,
                contentHeight: 1_000,
                viewportHeight: 100
            ) == 450
        )
        #expect(MarkdownScrollMetrics.ratio(offset: 20, contentHeight: 100, viewportHeight: 100) == 0)
    }

    @Test
    func workspaceTreeCompactsMiddlePackagesOnlyUnderSourceRoots() throws {
        // 目录树按 Rust core 实际发出的 JSON 形状构造，避免测试绕过解码路径。
        func dir(_ path: String, _ children: String...) -> String {
            let name = (path as NSString).lastPathComponent
            let list = children.joined(separator: ",")
            return "{\"path\":\"\(path)\",\"name\":\"\(name)\",\"isDirectory\":true,\"children\":[\(list)]}"
        }
        func file(_ path: String) -> String {
            let name = (path as NSString).lastPathComponent
            return "{\"path\":\"\(path)\",\"name\":\"\(name)\",\"isDirectory\":false}"
        }

        let aiPackage = dir(
            "src/main/java/com",
            dir(
                "src/main/java/com/alibaba",
                dir(
                    "src/main/java/com/alibaba/nacos",
                    dir(
                        "src/main/java/com/alibaba/nacos/ai",
                        file("src/main/java/com/alibaba/nacos/ai/App.java"),
                        dir("src/main/java/com/alibaba/nacos/ai/config")
                    )
                )
            )
        )
        // 有文件就不是空中间包，不该被压缩。
        let soloPackage = dir(
            "src/main/java/solo",
            file("src/main/java/solo/Solo.java"),
            dir("src/main/java/solo/inner")
        )
        let sourceTree = dir(
            "src",
            dir(
                "src/main",
                dir("src/main/java", aiPackage, soloPackage),
                dir("src/main/resources", dir("src/main/resources/META-INF"))
            )
        )
        // 源码根之外的单子目录链保持原样。
        let docsTree = dir("docs", dir("docs/guide"))
        let json = "{\"root\":\(dir("", sourceTree, docsTree)),\"files\":[]}"

        let payload = try JSONDecoder().decode(
            RustCoreBridge.WorkspaceSnapshotPayload.self,
            from: Data(json.utf8)
        )
        let root = URL(fileURLWithPath: "/tmp/lithe-workspace-tree")
        let tree = payload.makeSnapshot(at: root).root

        func child(_ node: FileNode, _ name: String) throws -> FileNode {
            let match = node.children?.first { $0.name == name }
            return try #require(match, "missing child '\(name)' in \(node.name)")
        }

        let javaRoot = try child(child(child(tree, "src"), "main"), "java")
        #expect(javaRoot.iconKind == .sourceFolder)

        // com/alibaba/nacos/ai 压缩成一行，url 仍指向最深的真实目录。
        let compacted = try child(javaRoot, "com.alibaba.nacos.ai")
        #expect(compacted.iconKind == .packageFolder)
        #expect(compacted.url.lastPathComponent == "ai")
        #expect(compacted.collapsedAncestorPaths.map { ($0 as NSString).lastPathComponent }
            == ["com", "alibaba", "nacos"])
        #expect(compacted.children?.map(\.name).sorted() == ["App.java", "config"])
        #expect(try child(compacted, "config").iconKind == .packageFolder)

        // 含文件的目录不是空中间包，不压缩。
        let solo = try child(javaRoot, "solo")
        #expect(solo.collapsedAncestorPaths.isEmpty)
        #expect(try child(solo, "inner").iconKind == .packageFolder)

        // 资源根用资源图标；META-INF 名字不是合法包名，保持普通文件夹。
        let resources = try child(child(child(tree, "src"), "main"), "resources")
        #expect(resources.iconKind == .resourceFolder)
        #expect(try child(resources, "META-INF").iconKind == .folder)

        // 源码根之外不压缩，也不用包图标。
        let docs = try child(tree, "docs")
        #expect(docs.iconKind == .folder)
        #expect(docs.collapsedAncestorPaths.isEmpty)
        #expect(try child(docs, "guide").iconKind == .folder)
    }

    @Test
    func gitCommitFileTreePreservesHierarchyAndCompactsSingleChildPaths() {
        let tree = GitCommitFileTreeNode.build(
            from: [
                GitCommitFile(status: "M", path: "README.md"),
                GitCommitFile(status: "M", path: "docs/README.md"),
                GitCommitFile(status: "M", path: "docs/architecture/repository-layout.md"),
                GitCommitFile(status: "A", path: "src/main/java/example/App.java"),
                GitCommitFile(status: "A", path: "service/Service.java"),
                GitCommitFile(status: "A", path: "service/impl/ServiceImpl.java")
            ],
            rootName: "Lithe-IDEA"
        )

        #expect(tree.name == "Lithe-IDEA")
        #expect(tree.fileCount == 6)
        #expect(tree.files.map(\.path) == ["README.md"])
        #expect(tree.directories.map(\.name) == ["docs", "service", "src/main/java/example"])

        let docs = tree.directories[0]
        #expect(docs.fileCount == 2)
        #expect(docs.files.map(\.path) == ["docs/README.md"])
        #expect(docs.directories.map(\.name) == ["architecture"])

        let service = tree.directories[1]
        #expect(service.fileCount == 2)
        #expect(service.files.map(\.path) == ["service/Service.java"])
        #expect(service.directories.map(\.name) == ["impl"])
    }

    @Test
    @MainActor
    func fileVisibilityChangesNotifyEveryOpenProjectObserver() {
        let settings = AppSettings(store: EmptyKeyValueStore())
        var firstObserverCalls = 0
        var secondObserverCalls = 0

        let firstID = settings.addFileVisibilityRulesObserver { firstObserverCalls += 1 }
        _ = settings.addFileVisibilityRulesObserver { secondObserverCalls += 1 }
        settings.hiddenDirectoryNames.append("generated")

        #expect(firstObserverCalls == 1)
        #expect(secondObserverCalls == 1)

        settings.removeFileVisibilityRulesObserver(firstID)
        settings.hiddenFilePatterns.append("*.generated.swift")

        #expect(firstObserverCalls == 1)
        #expect(secondObserverCalls == 2)
    }

    @Test
    func runConfigurationMigrationWritesToolchainsIntoServiceOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-run-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MutableKeyValueStore()
        let projectKey = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        store.set(try JSONEncoder().encode(JavaRunOptions(
            javaHomePath: "/jdk/legacy",
            workingDirectoryPath: "backend",
            vmArguments: "-Xmx2g",
            programArguments: "--spring.profiles.active=dev",
            activeProfiles: ["dev"]
        )), forKey: "lithe.java-run-options.\(projectKey).current-file")
        store.set(try JSONEncoder().encode(ProjectRuntimeSettings(
            javaHomePath: "/Library/Java/jdk-21",
            mavenHomeSelection: .custom,
            mavenHomePath: "/opt/maven",
            mavenJavaHomePath: "/Library/Java/jdk-17"
        )), forKey: "lithe.project-runtime.\(projectKey)")

        let adapter = MacRunConfigurationStore(
            core: RustCoreBridge(),
            storage: MacFileStorage(),
            preferences: store,
            documentMutator: RunTestDocumentMutator()
        )
        try adapter.migrateLegacySettings(at: root, configurationIDs: ["current-file"])
        try adapter.saveOptions(
            JavaRunOptions(
                javaHomePath: "/Library/Java/jdk-22",
                workingDirectoryPath: "backend app",
                vmArguments: "\"-Dlabel=hello world\" -Xmx1g",
                programArguments: "--dev",
                activeProfiles: ["local"]
            ),
            configurationID: "current-file",
            scope: .local,
            at: root
        )

        let local = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".lithe/run/local.json"))) as? [String: Any]
        let configs = local?["configurations"] as? [[String: Any]]
        #expect(configs?.first?["workingDirectory"] as? String == "backend app")
        #expect(configs?.first?["jvmArguments"] as? [String] == ["-Dlabel=hello world", "-Xmx1g"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/toolchains/local.json").path))
        #expect(store.object(forKey: "lithe.run-configuration-migrated.\(projectKey)") as? Bool == true)
        #expect(store.data(forKey: "lithe.java-run-options.\(projectKey).current-file") != nil)
        #expect(store.data(forKey: "lithe.java-run-options.\(projectKey).current-file") != nil)
    }
}

private let projectWindowShutdownTestManifest = ModuleManifest(
    id: ModuleID("dev.lithe.tests.project-window-shutdown"),
    displayName: "Project Window Shutdown Test Module",
    scope: .application,
    defaultState: .enabled,
    activationPolicy: .onDemand
)

@MainActor
private final class ProjectWindowShutdownTestModule: LitheModule {
    let manifest = projectWindowShutdownTestManifest
    private let shutdownStarted: TestGate
    private let releaseShutdown: TestGate

    init(shutdownStarted: TestGate, releaseShutdown: TestGate) {
        self.shutdownStarted = shutdownStarted
        self.releaseShutdown = releaseShutdown
    }

    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}

    func shutdown() async {
        shutdownStarted.open()
        _ = await releaseShutdown.waitUntilOpen()
    }

    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

@MainActor
private final class TestProjectWindowSessions: ProjectWindowSessionHandling {
    var hasActiveProject: Bool
    var hasActiveStandaloneFile = false
    var consumesWorkbenchCloseCommand = false
    var hasUnsavedDocuments = false
    var unsavedDocumentNames: [String] = []
    var saveAllDocumentsResult = true
    var projectWindowCleanupStarted: TestGate?
    var projectWindowCleanupRelease: TestGate?
    private(set) var closeActiveProjectCallCount = 0
    private(set) var closeActiveWorkbenchItemCallCount = 0
    private(set) var requestCloseActiveSessionCallCount = 0
    private(set) var resetForProjectWindowCloseCallCount = 0
    private(set) var saveAllDocumentsCallCount = 0

    init(hasActiveProject: Bool) {
        self.hasActiveProject = hasActiveProject
    }

    func closeActiveProject() {
        closeActiveProjectCallCount += 1
    }

    func requestCloseActiveWorkbenchItem() -> Bool {
        closeActiveWorkbenchItemCallCount += 1
        return consumesWorkbenchCloseCommand
    }

    func requestCloseActiveSession() -> Bool {
        requestCloseActiveSessionCallCount += 1
        closeActiveProject()
        return false
    }

    func saveAllDocuments() -> Bool {
        saveAllDocumentsCallCount += 1
        return saveAllDocumentsResult
    }

    func resetForProjectWindowClose() async {
        resetForProjectWindowCloseCallCount += 1
        projectWindowCleanupStarted?.open()
        if let projectWindowCleanupRelease {
            _ = await projectWindowCleanupRelease.waitUntilOpen()
        }
    }
}

@MainActor
private final class CloseCommandTestWindow: NSWindow {
    private(set) var performCloseCallCount = 0
    private(set) var delegateAllowedClose = false
    private let nativeCloseAllowed = TestGate()

    override func performClose(_ sender: Any?) {
        performCloseCallCount += 1
        delegateAllowedClose = delegate?.windowShouldClose?(self) ?? true
        if delegateAllowedClose {
            nativeCloseAllowed.open()
        }
    }

    func waitUntilNativeCloseAllowed() async -> Bool {
        await nativeCloseAllowed.waitUntilOpen()
    }
}

private final class RecordingProcessRunner: ProcessRunner, DatabaseProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (ProcessRequest) -> ProcessResult
    private let requestsLock = NSLock()
    private var recordedRequests: [ProcessRequest] = []

    var requests: [ProcessRequest] {
        requestsLock.lock()
        defer { requestsLock.unlock() }
        return recordedRequests
    }

    init(result: ProcessResult) {
        handler = { _ in result }
    }

    init(handler: @escaping (ProcessRequest) -> ProcessResult) {
        self.handler = handler
    }

    func run(_ request: ProcessRequest) -> ProcessResult {
        requestsLock.lock()
        recordedRequests.append(request)
        requestsLock.unlock()
        return handler(request)
    }

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        let result = run(ProcessRequest(
            executablePath: request.executablePath,
            environment: request.environment,
            standardInput: request.standardInput,
            timeoutMilliseconds: request.timeoutMilliseconds
        ))
        return DatabaseProcessResult(output: result.output, exitCode: result.exitCode)
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class DatabaseTestKeyValueStore: KeyValueStore, DatabasePreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class DatabaseTestSecureStore: SecureStore, DatabaseSecureStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    func read(key: String) -> String? { values[key] }
    func write(_ value: String, key: String) throws { values[key] = value }
    func delete(key: String) throws { values.removeValue(forKey: key) }
}

@Suite("Editor documents")
@MainActor
struct EditorDocumentTests {
    @Test
    func documentTracksDirtyStateAndSaves() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-editor-document-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let document = EditorDocument(url: url, text: "before", modificationDate: nil)
        #expect(!document.isDirty)

        document.text = "after"
        #expect(document.isDirty)
        try document.save()

        #expect(!document.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after")
    }

    @Test
    @MainActor
    func liveEditorTextPublishesOnlyWhenDirtyStateChanges() {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/live-editor.txt"),
            text: "before",
            modificationDate: nil
        )
        var publishCount = 0
        let observation = document.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        document.applyLiveEditorText("before")
        #expect(publishCount == 0)

        document.applyLiveEditorText("after")
        #expect(document.isDirty)
        #expect(publishCount == 1)

        document.applyLiveEditorText("after more")
        #expect(document.isDirty)
        #expect(publishCount == 1)

        document.applyLiveEditorText("before")
        #expect(!document.isDirty)
        #expect(publishCount == 2)
    }

    @Test
    @MainActor
    func liveEditorEditsProduceOrderedLanguageServerChanges() {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/live-editor-lsp.txt"),
            text: "one\ntwo",
            modificationDate: nil
        )

        document.applyLiveEditorEdit(
            replacedRange: NSRange(location: 4, length: 3),
            replacement: "second"
        )
        document.applyLiveEditorEdit(
            replacedRange: NSRange(location: 0, length: 0),
            replacement: "A"
        )

        let changes = document.takePendingLanguageServerChanges()
        #expect(changes.map(\.text) == ["second", "A"])
        #expect(changes[0].start == LanguageServerDocumentPosition(line: 1, utf16Column: 0))
        #expect(changes[0].end == LanguageServerDocumentPosition(line: 1, utf16Column: 3))
        #expect(document.takePendingLanguageServerChanges().isEmpty)
    }

    @Test
    @MainActor
    func liveEditorEditAppliesUTF16ReplacementWithoutFullEditorSnapshot() {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/live-editor-edit.txt"),
            text: "before\nvalue",
            modificationDate: nil
        )

        document.applyLiveEditorEdit(
            replacedRange: NSRange(location: 7, length: 5),
            replacement: "updated"
        )

        #expect(document.text == "before\nupdated")
        #expect(document.isDirty)

        document.applyLiveEditorEdit(
            replacedRange: NSRange(location: 0, length: 0),
            replacement: "A"
        )
        #expect(document.text == "Abefore\nupdated")
    }

    @Test
    func rustDocumentLifecyclePreservesDirtyEditorTextOnExternalChange() throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
        let decider = RustDocumentLifecycleDecider(core: core)

        let decision = try decider.decide(
            state: .dirty(revision: 3, savedRevision: 1),
            event: .externalChanged,
            operationID: "mac-watcher-1"
        )

        #expect(decision.state.status == .conflict)
        #expect(decision.action == .showConflict)
    }

    @Test
    func readOnlyDocumentRejectsSave() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-read-only-\(UUID().uuidString).txt")
        let document = EditorDocument(
            url: url,
            text: "content",
            modificationDate: nil,
            isReadOnly: true
        )

        #expect(throws: EditorDocument.DocumentError.self) {
            try document.save()
        }
    }

    @Test
    func virtualDocumentOpensFromMemoryAsReadOnly() throws {
        let model = DocumentFeatureModel(
            operations: EmptyWorkspaceOperations(),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        let url = try #require(URL(string: "jdt://contents/java.base/java/lang/String.class"))

        model.openVirtualDocument(
            url,
            text: "public final class String {}",
            displayPath: "java.base/java/lang/String.class"
        )

        let document = try #require(model.activeDocument)
        #expect(document.url == url)
        #expect(document.text == "public final class String {}")
        #expect(document.isReadOnly)
        #expect(document.displayName == "String.class")
    }

    @Test
    func searchRelevanceRanksMatchFormsInOrder() {
        let root = "/tmp/project/src/"
        func result(_ name: String) -> FileSearchResult {
            FileSearchResult(
                url: URL(fileURLWithPath: root + name),
                line: nil,
                preview: "",
                kind: .file
            )
        }

        let query = "DeviceHandler"
        let exact = SearchRelevance.score(result("DeviceHandler.java"), query: query)
        let prefix = SearchRelevance.score(result("DeviceHandlerFactory.java"), query: query)
        let substring = SearchRelevance.score(result("AbstractDeviceHandlerBase.java"), query: query)
        let miss = SearchRelevance.score(result("PadController.java"), query: query)

        #expect(exact > prefix)
        #expect(prefix > substring)
        #expect(substring > 0)
        #expect(miss == 0)
    }

    @Test
    func searchRelevanceMatchesCamelCaseInitials() {
        let target = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/src/DeviceHandler.java"),
            line: nil,
            preview: "",
            kind: .file
        )
        let unrelated = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/src/PadController.java"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(target, query: "dh") > 0)
        #expect(SearchRelevance.score(unrelated, query: "dh") == 0)
    }

    @Test
    func searchRelevancePrefersNameMatchOverPathMatch() {
        let query = "handler"
        let byName = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/Handler.java"),
            line: nil,
            preview: "",
            kind: .file
        )
        let byPathOnly = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/handler/Pad.java"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(byName, query: query) > SearchRelevance.score(byPathOnly, query: query))
    }

    @Test
    func searchRelevancePrefersShallowerFiles() {
        let shallow = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/Device.java"),
            line: nil,
            preview: "",
            kind: .file
        )
        let deep = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/a/b/c/d/Device.java"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(shallow, query: "Device") > SearchRelevance.score(deep, query: "Device"))
    }

    @Test
    func searchRelevanceRanksTypeAboveContentForEqualNames() {
        let url = URL(fileURLWithPath: "/tmp/project/src/DeviceHandler.java")
        let type = FileSearchResult(
            url: url,
            line: 10,
            preview: "",
            kind: .type,
            symbolName: "DeviceHandler"
        )
        let content = FileSearchResult(
            url: url,
            line: 42,
            preview: "new DeviceHandler()",
            kind: .content,
            symbolName: "DeviceHandler"
        )

        #expect(
            SearchRelevance.score(type, query: "DeviceHandler")
                > SearchRelevance.score(content, query: "DeviceHandler")
        )
    }

    @Test
    @MainActor
    func terminalSessionKeepsNativeSurfaceAndOwnsLifecycle() {
        let transport = TestTerminalTransport()
        let factory: @MainActor () -> any TerminalTransport = { transport }
        let feature = TerminalFeatureModel(terminalFactory: factory)
        let workspace = URL(fileURLWithPath: "/tmp/lithe-terminal-tests")

        let session = feature.createSession(in: workspace, shellPath: "/bin/zsh")
        let nativeViewID = ObjectIdentifier(transport.nativeView)

        #expect(session.isRunning)
        #expect(session.isReady)
        #expect(session.shellName == "zsh")
        #expect(ObjectIdentifier(session.nativeView) == nativeViewID)
        #expect(transport.startRequests == ["/bin/zsh"])

        feature.closeSession(session)

        #expect(!session.isRunning)
        #expect(transport.stopCount == 1)
        #expect(feature.terminalSessions.isEmpty)
        #expect(feature.activeTerminalSessionID == nil)
    }

    @Test
    func shelveStoragePersistsVersionedEntriesPerRepositoryAndDeletesThem() async throws {
        let storage = InMemoryFileStorage()
        let service = ShelveService(storage: storage)
        let repository = URL(fileURLWithPath: "/tmp/repository-one")
        let otherRepository = URL(fileURLWithPath: "/tmp/repository-two")

        let entry = try #require(
            await service.save(
                message: "before checkout",
                repositoryRoot: repository,
                paths: ["Sources/App.swift"],
                stagedPatch: "staged patch",
                workingPatch: "working patch"
            )
        )

        let loaded = await service.entries(for: repository)
        #expect(loaded == [entry])
        let isolated = await service.entries(for: otherRepository)
        #expect(isolated.isEmpty)

        let raw = try #require(storage.firstStoredData())
        let object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 1)
        #expect(object["stagedPatch"] as? String == "staged patch")
        #expect(object["workingPatch"] as? String == "working patch")

        #expect(await service.delete(entry, repositoryRoot: repository))
        #expect((await service.entries(for: repository)).isEmpty)
    }

    @Test
    @MainActor
    func terminalSessionRestartUsesExistingSurfaceAndSelectedShell() {
        let transport = TestTerminalTransport()
        let factory: @MainActor () -> any TerminalTransport = { transport }
        let feature = TerminalFeatureModel(terminalFactory: factory)
        let workspace = URL(fileURLWithPath: "/tmp/lithe-terminal-tests")
        let session = feature.createSession(in: workspace, shellPath: "/bin/bash")
        let nativeViewID = ObjectIdentifier(session.nativeView)
        session.restart(using: "/bin/zsh")

        #expect(session.isRunning)
        #expect(session.shellName == "zsh")
        #expect(ObjectIdentifier(session.nativeView) == nativeViewID)
        #expect(transport.startRequests == ["/bin/bash", "/bin/zsh"])
        #expect(transport.stopCount == 1)
    }

    @Test
    func terminalLinkResolverResolvesWorkspacePathAndLocation() {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-terminal-link-tests")
        let sourceURL = workspace.appendingPathComponent("Sources/App.swift")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workspace) }
        fileManager.createFile(atPath: sourceURL.path, contents: Data())

        let target = TerminalLinkResolver.resolve(
            "Sources/App.swift:12:4",
            relativeTo: workspace,
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        )

        #expect(target == .file(
            TerminalLinkLocation(url: sourceURL.standardizedFileURL, line: 12, column: 4)
        ))
    }

    @Test
    func terminalLinkResolverKeepsExternalURLsAsExternalTargets() {
        let target = TerminalLinkResolver.resolve(
            "https://example.com/docs",
            relativeTo: URL(fileURLWithPath: "/tmp"),
            fileExists: { _ in false }
        )

        #expect(target == .external(URL(string: "https://example.com/docs")!))
    }

    @Test
    @MainActor
    func terminalSessionPublishesTitleDirectoryAndExitState() {
        let transport = TestTerminalTransport()
        let session = TerminalSession(transport: transport)
        let workspace = URL(fileURLWithPath: "/tmp/lithe-terminal-tests")
        session.start(in: workspace, shellPath: "/bin/zsh")
        transport.onTitle?("codex")
        transport.onDirectoryUpdate?(workspace.appendingPathComponent("Sources").path)
        transport.onTermination?(7)

        #expect(session.displayTitle == "codex")
        #expect(session.currentDirectory?.path == workspace.appendingPathComponent("Sources").path)
        #expect(session.lastExitCode == 7)
        #expect(!session.isRunning)
        #expect(session.elapsedDescription(at: Date().addingTimeInterval(1)) != nil)
    }

    @Test
    @MainActor
    func workspaceDirectoryMarksLoadAndPersistByRelativePath() async {
        let workspace = URL(fileURLWithPath: "/tmp/directory-mark-workspace")
        let markStore = RecordingWorkspaceDirectoryMarkStore(initial: ["Sources": .sources])
        let model = WorkspaceFeatureModel(
            operations: EmptyWorkspaceOperations(),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore()),
            directoryMarkStore: markStore
        )

        model.beginWorkspace(at: workspace, visibilityRules: .default)
        #expect(model.directoryMarks == ["Sources": .sources])

        await model.markDirectory(
            workspace.appendingPathComponent("assets", isDirectory: true),
            as: .resources
        )

        #expect(model.directoryMarks["assets"] == .resources)
        #expect(markStore.savedMarks?["Sources"] == .sources)
        #expect(markStore.savedMarks?["assets"] == .resources)
    }

    /// A preference write can outlive the workspace that initiated it. Releasing
    /// the controlled store after switching projects must not publish old marks.
    @Test
    @MainActor
    func directoryMarkSaveDoesNotPublishIntoAReplacementWorkspace() async {
        let firstWorkspace = URL(fileURLWithPath: "/tmp/directory-mark-first")
        let secondWorkspace = URL(fileURLWithPath: "/tmp/directory-mark-second")
        let saveStarted = TestGate()
        let releaseSave = TestGate()
        defer { releaseSave.open() }
        let markStore = BlockingWorkspaceDirectoryMarkStore(
            initialByWorkspace: [secondWorkspace.standardizedFileURL.path: ["Sources": .sources]],
            saveStarted: saveStarted,
            releaseSave: releaseSave
        )
        let model = WorkspaceFeatureModel(
            operations: EmptyWorkspaceOperations(),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore()),
            directoryMarkStore: markStore
        )

        model.beginWorkspace(at: firstWorkspace, visibilityRules: .default)
        let saveTask = Task {
            await model.markDirectory(
                firstWorkspace.appendingPathComponent("assets", isDirectory: true),
                as: .resources
            )
        }

        #expect(await saveStarted.waitUntilOpen(timeout: .seconds(5)))
        model.beginWorkspace(at: secondWorkspace, visibilityRules: .default)
        releaseSave.open()
        await saveTask.value

        #expect(model.directoryMarks == ["Sources": .sources])
    }

    @Test
    @MainActor
    func consecutiveDirectoryMarksPersistInInvocationOrder() async {
        let workspace = URL(fileURLWithPath: "/tmp/directory-mark-consecutive")
        let saveStarted = TestGate()
        let releaseSave = TestGate()
        defer { releaseSave.open() }
        let markStore = BlockingWorkspaceDirectoryMarkStore(
            initialByWorkspace: [:],
            saveStarted: saveStarted,
            releaseSave: releaseSave
        )
        let model = WorkspaceFeatureModel(
            operations: EmptyWorkspaceOperations(),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore()),
            directoryMarkStore: markStore
        )

        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let firstSave = Task {
            await model.markDirectory(
                workspace.appendingPathComponent("Sources", isDirectory: true),
                as: .sources
            )
        }
        #expect(await saveStarted.waitUntilOpen(timeout: .seconds(5)))
        let secondSave = Task {
            await model.markDirectory(
                workspace.appendingPathComponent("assets", isDirectory: true),
                as: .resources
            )
        }

        releaseSave.open()
        await firstSave.value
        await secondSave.value

        #expect(markStore.savedMarks == ["Sources": .sources, "assets": .resources])
        #expect(model.directoryMarks == markStore.savedMarks)
    }

    @Test
    @MainActor
    func renamingDirectoryMigratesItsMarkAndDescendantMarks() async {
        let workspace = URL(fileURLWithPath: "/tmp/directory-mark-rename")
        let source = workspace.appendingPathComponent("Sources", isDirectory: true)
        let markStore = RecordingWorkspaceDirectoryMarkStore(
            initial: ["Sources": .sources, "Sources/generated": .excluded, "assets": .resources]
        )
        let model = makeWorkspaceObservationUnitModel(
            fileOperations: EmptyWorkspaceFileOperations(),
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: TestDirectoryWatcherFactory(),
            refreshGit: {},
            directoryMarkStore: markStore
        )
        model.beginWorkspace(at: workspace, visibilityRules: .default)

        model.requestRenameProjectItem(at: source)
        await model.performProjectItemEdit(named: "SourceCode")

        let expected: [String: WorkspaceDirectoryMark] = [
            "SourceCode": .sources,
            "SourceCode/generated": .excluded,
            "assets": .resources
        ]
        #expect(model.directoryMarks == expected)
        #expect(markStore.savedMarks == expected)
    }

    @Test
    @MainActor
    func deletingDirectoryRemovesItsMarkAndDescendantMarks() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/directory-mark-delete")
        let target = workspace.appendingPathComponent("generated", isDirectory: true)
        let markStore = RecordingWorkspaceDirectoryMarkStore(
            initial: ["generated": .excluded, "generated/cache": .plain, "Sources": .sources]
        )
        let model = makeWorkspaceObservationUnitModel(
            fileOperations: EmptyWorkspaceFileOperations(),
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: TestDirectoryWatcherFactory(),
            refreshGit: {},
            directoryMarkStore: markStore
        )
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        model.requestDeleteProjectItem(at: target, isDirectory: true)
        let request = try #require(model.pendingProjectItemDeletion)

        await model.confirmProjectItemDeletion(request)

        #expect(model.directoryMarks == ["Sources": .sources])
        #expect(markStore.savedMarks == ["Sources": .sources])
    }

    @Test
    @MainActor
    func workspaceInitialLoadFailureCanRetryWithoutLeavingAnEmptyProject() async {
        let operations = SequencedWorkspaceOperations(snapshotAvailability: [false, true])
        let model = WorkspaceFeatureModel(
            operations: operations,
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore())
        )
        model.configure(
            documentsProvider: { [] },
            activeDocumentProvider: { nil },
            selectedSidebarProvider: { "project" },
            setSelectedSidebar: { _ in },
            restoreSession: { _, _ in },
            openFile: { _ in },
            notify: { _ in },
            recordHistory: { _, _ in },
            relocateHistory: { _, _ in },
            relocateOpenDocuments: { _, _ in },
            closeDocuments: { _ in },
            processExternalChanges: { _ in false },
            reloadProjectServices: {},
            refreshGit: {},
            updateHistoryVisibilityRules: { _ in },
            onSnapshotLoaded: { _, _, _ in }
        )

        let workspace = URL(fileURLWithPath: "/tmp/retry-workspace")
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let firstResult = await model.rebuild(at: workspace, rules: .default, isCurrent: { true })

        if case .unavailable = firstResult {} else {
            Issue.record("The first unavailable snapshot should report a load failure")
        }
        #expect(model.loadErrorMessage != nil)
        #expect(!model.isLoadingWorkspace)
        #expect(model.rootNode == nil)

        let retryResult = await model.rebuild(at: workspace, rules: .default, isCurrent: { true })

        if case .loaded = retryResult {} else {
            Issue.record("Retry should publish the available workspace snapshot")
        }
        #expect(model.loadErrorMessage == nil)
        #expect(!model.isLoadingWorkspace)
        #expect(model.rootNode?.url.standardizedFileURL == workspace.standardizedFileURL)
    }

    @Test
    @MainActor
    func workspaceInitialRebuildRequestsOneGitRefresh() async {
        let operations = SequencedWorkspaceOperations(snapshotAvailability: [true])
        let model = WorkspaceFeatureModel(
            operations: operations,
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore())
        )
        var snapshotLoadCount = 0
        var gitRefreshCount = 0
        model.configure(
            documentsProvider: { [] },
            activeDocumentProvider: { nil },
            selectedSidebarProvider: { "project" },
            setSelectedSidebar: { _ in },
            restoreSession: { _, _ in },
            openFile: { _ in },
            notify: { _ in },
            recordHistory: { _, _ in },
            relocateHistory: { _, _ in },
            relocateOpenDocuments: { _, _ in },
            closeDocuments: { _ in },
            processExternalChanges: { _ in false },
            reloadProjectServices: {},
            refreshGit: { gitRefreshCount += 1 },
            updateHistoryVisibilityRules: { _ in },
            onSnapshotLoaded: { _, _, _ in snapshotLoadCount += 1 }
        )
        let workspace = URL(fileURLWithPath: "/tmp/lithe-initial-refresh")
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let result = await model.rebuild(at: workspace, rules: .default, isCurrent: { true })

        guard case .loaded = result else {
            Issue.record("The initial workspace snapshot should load")
            return
        }
        #expect(snapshotLoadCount == 1)
        #expect(gitRefreshCount == 1)
    }

    /// After the snapshot is published, restoreSession and watch setup can still
    /// suspend. A project switch in that window must not deliver the old scan
    /// through onSnapshotLoaded under the new workspace identity.
    @Test
    @MainActor
    func rebuildRejectsStaleWorkspaceBeforeSnapshotCallback() async {
        let enteredRestore = TestGate()
        let releaseRestore = TestGate()
        defer { releaseRestore.open() }

        let operations = SequencedWorkspaceOperations(snapshotAvailability: [true])
        let sessionStore = WorkspaceSessionStore(store: MutableKeyValueStore())
        let workspace = URL(fileURLWithPath: "/tmp/lithe-stale-snapshot-callback")
        sessionStore.save(
            WorkspaceSession(openPaths: [], activePath: nil, selectedSidebar: "project"),
            for: workspace
        )

        var snapshotLoadCount = 0
        var isCurrent = true
        let model = WorkspaceFeatureModel(
            operations: operations,
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: sessionStore
        )
        model.configure(
            documentsProvider: { [] },
            activeDocumentProvider: { nil },
            selectedSidebarProvider: { "project" },
            setSelectedSidebar: { _ in },
            restoreSession: { _, _ in
                enteredRestore.open()
                _ = await releaseRestore.waitUntilOpen(timeout: .seconds(5))
            },
            openFile: { _ in },
            notify: { _ in },
            recordHistory: { _, _ in },
            relocateHistory: { _, _ in },
            relocateOpenDocuments: { _, _ in },
            closeDocuments: { _ in },
            processExternalChanges: { _ in false },
            reloadProjectServices: {},
            refreshGit: {},
            updateHistoryVisibilityRules: { _ in },
            onSnapshotLoaded: { _, _, _ in snapshotLoadCount += 1 }
        )

        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let rebuildTask = Task {
            await model.rebuild(
                at: workspace,
                rules: .default,
                isCurrent: { isCurrent }
            )
        }

        #expect(await enteredRestore.waitUntilOpen(timeout: .seconds(5)))
        #expect(model.appliedSnapshot != nil, "the snapshot should already be published")
        isCurrent = false
        releaseRestore.open()

        let result = await rebuildTask.value
        if case .stale = result {} else {
            Issue.record("A rebuild that lost isCurrent before the callback should report stale")
        }
        #expect(snapshotLoadCount == 0, "the stale rebuild must not deliver onSnapshotLoaded")
    }

    /// Closing and reopening the same path leaves the workspace URL unchanged, so
    /// only the opening's generation can tell a refresh that outlived the close
    /// from one that belongs to the current session. Without it, the earlier
    /// refresh would publish its scan into the new opening after `reset`.
    @Test
    @MainActor
    func refreshFromAnEarlierOpeningOfTheSamePathDoesNotDeliverItsSnapshot() async {
        let enteredRestore = TestGate()
        let releaseRestore = TestGate()
        defer { releaseRestore.open() }

        let operations = SequencedWorkspaceOperations(snapshotAvailability: [true])
        let sessionStore = WorkspaceSessionStore(store: MutableKeyValueStore())
        let workspace = URL(fileURLWithPath: "/tmp/lithe-same-path-reopen-refresh")
        sessionStore.save(
            WorkspaceSession(openPaths: [], activePath: nil, selectedSidebar: "project"),
            for: workspace
        )

        var snapshotLoadCount = 0
        let model = WorkspaceFeatureModel(
            operations: operations,
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: TestDirectoryWatcherFactory(),
            workspaceSessionStore: sessionStore
        )
        model.configure(
            documentsProvider: { [] },
            activeDocumentProvider: { nil },
            selectedSidebarProvider: { "project" },
            setSelectedSidebar: { _ in },
            restoreSession: { _, _ in
                enteredRestore.open()
                _ = await releaseRestore.waitUntilOpen(timeout: .seconds(5))
            },
            openFile: { _ in },
            notify: { _ in },
            recordHistory: { _, _ in },
            relocateHistory: { _, _ in },
            relocateOpenDocuments: { _, _ in },
            closeDocuments: { _ in },
            processExternalChanges: { _ in false },
            reloadProjectServices: {},
            refreshGit: {},
            updateHistoryVisibilityRules: { _ in },
            onSnapshotLoaded: { _, _, _ in snapshotLoadCount += 1 }
        )

        model.beginWorkspace(at: workspace, visibilityRules: .default)
        // The refresh builds its own current guard, so this exercises production
        // identity rather than a guard supplied by the test.
        let refreshTask = Task { await model.refreshCurrent() }

        #expect(await enteredRestore.waitUntilOpen(timeout: .seconds(5)))
        #expect(model.appliedSnapshot != nil, "the snapshot should already be published")

        // Close and reopen the same path while the refresh is suspended.
        model.reset()
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        releaseRestore.open()
        await refreshTask.value

        #expect(
            snapshotLoadCount == 0,
            "a refresh from the previous opening must not deliver its snapshot to the new one"
        )
        #expect(
            model.appliedSnapshot == nil,
            "the new opening has not scanned yet, so no snapshot should be applied"
        )
    }

    @Test
    @MainActor
    func capturedProjectDeletionSurvivesConfirmationDialogDismissal() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-delete-confirmation")
        let target = workspace.appendingPathComponent("obsolete.swift")
        let fileOperations = RecordingTrashWorkspaceFileOperations()
        defer { fileOperations.release() }
        let operations = SequencedWorkspaceOperations(
            snapshotAvailability: [true, false],
            files: [target]
        )
        var historyRecordCount = 0
        let model = makeWorkspaceObservationUnitModel(
            operations: operations,
            fileOperations: fileOperations,
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: TestDirectoryWatcherFactory(),
            refreshGit: {},
            recordHistory: { _, _ in historyRecordCount += 1 }
        )
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        _ = await model.rebuild(at: workspace, rules: .default, isCurrent: { true })
        model.requestDeleteProjectItem(at: target, isDirectory: false)
        let request = try #require(model.pendingProjectItemDeletion)

        // SwiftUI dismisses the confirmation dialog before its asynchronous
        // action runs, so the captured request must not depend on pending state.
        model.cancelProjectItemDeletion()
        let deletionTask = Task { await model.confirmProjectItemDeletion(request) }

        #expect(await fileOperations.waitUntilStarted())
        #expect(model.projectFiles.isEmpty)
        #expect(model.rootNode?.children?.isEmpty == true)

        fileOperations.release()
        await deletionTask.value

        #expect(model.pendingProjectItemDeletion == nil)
        #expect(fileOperations.trashedURLs == [target.standardizedFileURL])
        #expect(historyRecordCount == 0)
        #expect(model.projectFiles.isEmpty)
        #expect(model.rootNode?.children?.isEmpty == true)
    }

    @Test
    @MainActor
    func failedProjectDeletionRestoresOptimisticallyRemovedItem() async {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-delete-failure")
        let target = workspace.appendingPathComponent("still-here.swift")
        let operations = SequencedWorkspaceOperations(
            snapshotAvailability: [true, true],
            files: [target]
        )
        let model = makeWorkspaceObservationUnitModel(
            operations: operations,
            fileOperations: FailingTrashWorkspaceFileOperations(),
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: TestDirectoryWatcherFactory(),
            refreshGit: {}
        )
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        _ = await model.rebuild(at: workspace, rules: .default, isCurrent: { true })
        model.requestDeleteProjectItem(at: target, isDirectory: false)
        guard let request = model.pendingProjectItemDeletion else {
            Issue.record("The deletion request should be available")
            return
        }

        await model.confirmProjectItemDeletion(request)

        #expect(model.projectFiles == [target])
        #expect(model.rootNode?.children?.map(\.url) == [target])
    }

    @Test
    func workspaceFilesystemFallbackBuildsAVisibleTreeAndHonorsHiddenRules() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-workspace-fallback-\(UUID().uuidString)")
        let sources = workspace.appendingPathComponent("Sources")
        let hiddenGit = workspace.appendingPathComponent(".git")
        let hiddenWorktree = workspace.appendingPathComponent(".worktree/feature/Sources")
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hiddenGit, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hiddenWorktree, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: sources.appendingPathComponent("App.swift").path,
            contents: Data("print(1)".utf8)
        )
        fileManager.createFile(
            atPath: workspace.appendingPathComponent("README.md").path,
            contents: Data("project".utf8)
        )
        fileManager.createFile(
            atPath: hiddenGit.appendingPathComponent("config").path,
            contents: Data()
        )
        fileManager.createFile(
            atPath: hiddenWorktree.appendingPathComponent("App.swift").path,
            contents: Data("print(2)".utf8)
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let snapshot = try #require(
            FileSystemWorkspaceSnapshotBuilder().snapshot(
                at: workspace,
                visibilityRules: .default
            )
        )

        #expect(snapshot.root.children?.map(\.name) == ["Sources", "README.md"])
        #expect(snapshot.files.map(\.lastPathComponent).sorted() == ["App.swift", "README.md"])
        #expect(!snapshot.files.contains { $0.path.contains("/.git/") })
        #expect(!snapshot.files.contains { $0.path.contains("/.worktree/") })
    }

    @Test
    @MainActor
    func gitOperationFreezeBatchesWatcherRefreshUntilTheOuterOperationEnds() async {
        let watcherFactory = TestDirectoryWatcherFactory()
        let model = WorkspaceFeatureModel(
            operations: EmptyWorkspaceOperations(),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            gitWatchContextProvider: SequencedGitWatchContextProvider([nil]),
            directoryWatcherFactory: watcherFactory,
            workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore())
        )
        var refreshCount = 0
        model.configure(
            documentsProvider: { [] },
            activeDocumentProvider: { nil },
            selectedSidebarProvider: { "project" },
            setSelectedSidebar: { _ in },
            restoreSession: { _, _ in },
            openFile: { _ in },
            notify: { _ in },
            recordHistory: { _, _ in },
            relocateHistory: { _, _ in },
            relocateOpenDocuments: { _, _ in },
            closeDocuments: { _ in },
            processExternalChanges: { _ in false },
            reloadProjectServices: {},
            refreshGit: { refreshCount += 1 },
            updateHistoryVisibilityRules: { _ in },
            onSnapshotLoaded: { _, _, _ in }
        )

        let workspace = URL(fileURLWithPath: "/tmp/frozen-workspace")
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        model.startWatchingCurrent()
        guard let source = watcherFactory.source else {
            Issue.record("The directory watcher was not created")
            return
        }

        model.beginGitOperationFreeze()
        model.beginGitOperationFreeze()
        source.emit([workspace.appendingPathComponent("Sources/App.swift").path])
        await Task.yield()
        await model.endGitOperationFreeze()

        #expect(model.gitOperationFreezeDepth == 1)
        #expect(refreshCount == 0)

        await model.endGitOperationFreeze()
        #expect(model.gitOperationFreezeDepth == 0)
        #expect(refreshCount == 1)
    }

    @Test
    func directoryWatchConfigurationNormalizesAndDeduplicatesCoveredRoots() {
        let repository = URL(fileURLWithPath: "/tmp/lithe-watch/repository")
        let workspace = repository.appendingPathComponent("apps/opened")
        let commonDirectory = URL(fileURLWithPath: "/tmp/lithe-watch/metadata/repository.git")
        let context = GitWatchContext(
            repositoryRoot: repository,
            gitDirectory: commonDirectory.appendingPathComponent("worktrees/opened"),
            gitCommonDirectory: commonDirectory
        )

        let configuration = DirectoryWatchConfiguration(
            workspaceRoot: workspace,
            gitContext: context
        )

        #expect(configuration.physicalRoots.map(\.path) == [repository.path, commonDirectory.path])
    }

    @Test
    func macDirectoryWatcherClassifiesWorkspaceGitOnlyAndRecoveryEvents() {
        let repository = URL(fileURLWithPath: "/tmp/lithe-classification/repository")
        let workspace = repository.appendingPathComponent("apps/opened")
        let gitDirectory = repository.appendingPathComponent(".git")
        let configuration = DirectoryWatchConfiguration(
            workspaceRoot: workspace,
            gitContext: GitWatchContext(
                repositoryRoot: repository,
                gitDirectory: gitDirectory,
                gitCommonDirectory: gitDirectory
            )
        )
        let watcher = MacDirectoryWatcher(configuration: configuration) { _ in }
        let visible = workspace.appendingPathComponent("Sources/App.swift").path
        let hidden = workspace.appendingPathComponent("dist/bundle.js").path
        let outsideWorkspace = repository.appendingPathComponent("outside.txt").path
        let index = gitDirectory.appendingPathComponent("index").path

        let classified = watcher.classify(
            paths: [visible, hidden, outsideWorkspace, index],
            eventFlags: Array(repeating: FSEventStreamEventFlags(0), count: 4)
        )

        #expect(classified.workspacePaths == [visible])
        #expect(classified.gitStateMayHaveChanged)
        #expect(!classified.requiresFullRescan)
        #expect(!classified.watchRootsChanged)

        let workspaceOnly = DirectoryWatchConfiguration(workspaceRoot: workspace, gitContext: nil)
        let workspaceWatcher = MacDirectoryWatcher(configuration: workspaceOnly) { _ in }
        let gitCreated = workspaceWatcher.classify(
            paths: [workspace.appendingPathComponent(".git").path],
            eventFlags: [FSEventStreamEventFlags(0)]
        )
        #expect(gitCreated.workspacePaths.isEmpty)
        #expect(gitCreated.gitStateMayHaveChanged)
        #expect(gitCreated.watchRootsChanged)

        let dropped = watcher.classify(
            paths: [repository.path],
            eventFlags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]
        )
        #expect(dropped.workspacePaths.isEmpty)
        #expect(dropped.gitStateMayHaveChanged)
        #expect(dropped.requiresFullRescan)

        let rootChanged = watcher.classify(
            paths: [repository.path],
            eventFlags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)]
        )
        #expect(rootChanged.requiresFullRescan)
        #expect(rootChanged.watchRootsChanged)
    }

    @Test
    @MainActor
    func gitRefreshBurstCoalescesAndARequestDuringRefreshRunsAgain() async {
        let watcherFactory = TestDirectoryWatcherFactory()
        var refreshCount = 0
        let model = makeWorkspaceObservationUnitModel(
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: watcherFactory,
            refreshGit: {
                refreshCount += 1
                if refreshCount == 1 {
                    watcherFactory.source?.emit(
                        DirectoryChangeBatch(gitStateMayHaveChanged: true)
                    )
                    await Task.yield()
                }
            }
        )
        defer { model.reset() }
        let workspace = URL(fileURLWithPath: "/tmp/lithe-git-refresh-state")
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let source = watcherFactory.source

        source?.emit(DirectoryChangeBatch(gitStateMayHaveChanged: true))
        source?.emit(DirectoryChangeBatch(gitStateMayHaveChanged: true))
        source?.emit(DirectoryChangeBatch(gitStateMayHaveChanged: true))
        let refreshed = await waitForWorkspaceObservation(timeout: .seconds(15)) {
            refreshCount == 2
        }

        #expect(refreshed)
        #expect(refreshCount == 2)
    }

    @Test
    @MainActor
    func workspaceWatcherProjectsTypedJavaChangesWithoutReloadingForSourceEdits() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-java-watcher")
        let source = workspace.appendingPathComponent("src/Main.java")
        let build = workspace.appendingPathComponent("pom.xml")
        let watcherFactory = TestDirectoryWatcherFactory()
        let delayStarted = TestGate()
        let releaseDelay = TestGate()
        let refreshFinished = TestGate()
        var projectedChanges: [WorkspaceFileChange] = []
        var projectReloadCount = 0
        let model = makeWorkspaceObservationUnitModel(
            operations: SequencedWorkspaceOperations(
                snapshotAvailability: [true],
                files: [source, build]
            ),
            fileOperations: ExistingWorkspaceFileOperations(paths: [source.path, build.path]),
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: watcherFactory,
            refreshGit: {
                if projectReloadCount > 0 { refreshFinished.open() }
            },
            notifyWorkspaceFileChanges: { projectedChanges.append(contentsOf: $0) },
            reloadProjectServices: { projectReloadCount += 1 },
            observationDelay: { duration in
                #expect(duration == .milliseconds(350))
                delayStarted.open()
                guard await releaseDelay.waitUntilOpen() else { throw CancellationError() }
                try Task.checkCancellation()
            }
        )
        defer {
            model.reset()
            releaseDelay.open()
        }
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        _ = await model.rebuild(at: workspace, rules: .default, isCurrent: { true })
        let watcher = try #require(watcherFactory.source)

        watcher.emit([source.path, build.path])
        #expect(await delayStarted.waitUntilOpen(), "The event did not reach the refresh scheduler")
        #expect(projectedChanges.isEmpty)
        #expect(projectReloadCount == 0)
        releaseDelay.open()
        #expect(await refreshFinished.waitUntilOpen(), "Released refresh did not finish")
        #expect(projectedChanges == [
            WorkspaceFileChange(fileURL: build, kind: .changed),
            WorkspaceFileChange(fileURL: source, kind: .changed),
        ])
        #expect(projectReloadCount == 1)
    }

    @Test
    @MainActor
    func resettingWorkspaceCancelsAnEventWaitingForItsRefreshDelay() async throws {
        let started = TestGate()
        let release = TestGate()
        let finished = TestGate()
        let watcherFactory = TestDirectoryWatcherFactory()
        var externalChanges = 0
        var gitRefreshes = 0
        let model = makeWorkspaceObservationUnitModel(
            provider: SequencedGitWatchContextProvider([nil]),
            watcherFactory: watcherFactory,
            refreshGit: { gitRefreshes += 1 },
            processExternalChanges: { _ in externalChanges += 1; return false },
            observationDelay: { _ in
                started.open()
                defer { finished.open() }
                guard await release.waitUntilOpen() else { throw CancellationError() }
                try Task.checkCancellation()
            }
        )
        defer {
            model.reset()
            release.open()
        }
        let workspace = URL(fileURLWithPath: "/in-memory/cancelled-observation")
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let watcher = try #require(watcherFactory.source)
        watcher.emit(DirectoryChangeBatch(
            workspacePaths: [workspace.appendingPathComponent("Main.java").path],
            gitStateMayHaveChanged: true
        ))
        #expect(await started.waitUntilOpen(), "The event did not reach the refresh scheduler")

        model.reset()

        #expect(await finished.waitUntilOpen(), "Reset did not cancel the pending delay")
        #expect(externalChanges == 0)
        #expect(gitRefreshes == 0)
        #expect(model.projectFiles.isEmpty)
    }

    @Test
    @MainActor
    func recoveryBatchRebuildsSnapshotReplacesRootsAndRefreshesOnlyGit() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-recovery-\(UUID().uuidString)/repository")
        let gitDirectory = repository.appendingPathComponent(".git")
        let context = GitWatchContext(
            repositoryRoot: repository,
            gitDirectory: gitDirectory,
            gitCommonDirectory: gitDirectory
        )
        let watcherFactory = TestDirectoryWatcherFactory()
        var externalChangeCount = 0
        var projectReloadCount = 0
        var refreshCount = 0
        let model = makeWorkspaceObservationUnitModel(
            operations: SequencedWorkspaceOperations(snapshotAvailability: [true]),
            provider: SequencedGitWatchContextProvider([context]),
            watcherFactory: watcherFactory,
            refreshGit: { refreshCount += 1 },
            processExternalChanges: { paths in
                externalChangeCount += paths.count
                return false
            },
            reloadProjectServices: { projectReloadCount += 1 }
        )
        defer { model.reset() }
        model.beginWorkspace(at: repository, visibilityRules: .default)
        let source = try #require(watcherFactory.source)
        source.emit(
            DirectoryChangeBatch(
                gitStateMayHaveChanged: true,
                requiresFullRescan: true,
                watchRootsChanged: true
            )
        )
        let recovered = await waitForWorkspaceObservation(timeout: .seconds(15)) {
            model.rootNode != nil && refreshCount == 1
        }

        #expect(recovered)
        #expect(model.rootNode != nil)
        #expect(watcherFactory.configurations.last?.repositoryRoot == repository)
        #expect(refreshCount == 1)
        #expect(externalChangeCount == 0)
        #expect(projectReloadCount == 0)
    }

    @Test
    @MainActor
    func watchRootsRecoveryRetainsWorkspacePathsAndRefreshesSnapshotAndDocuments() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-watch-roots-recovery-\(UUID().uuidString)/workspace")
        let changedFile = workspace.appendingPathComponent("Sources/App.swift")
        let gitDirectory = workspace.appendingPathComponent(".git")
        let context = GitWatchContext(
            repositoryRoot: workspace,
            gitDirectory: gitDirectory,
            gitCommonDirectory: gitDirectory
        )
        let watcherFactory = TestDirectoryWatcherFactory()
        var processedPaths: [URL] = []
        var refreshCount = 0
        let model = makeWorkspaceObservationUnitModel(
            operations: SequencedWorkspaceOperations(snapshotAvailability: [true]),
            fileOperations: ExistingWorkspaceFileOperations(paths: [changedFile.path]),
            provider: SequencedGitWatchContextProvider([context]),
            watcherFactory: watcherFactory,
            refreshGit: { refreshCount += 1 },
            processExternalChanges: { paths in
                processedPaths.append(contentsOf: paths)
                return false
            }
        )
        defer { model.reset() }
        model.beginWorkspace(at: workspace, visibilityRules: .default)
        let source = try #require(watcherFactory.source)
        source.emit(
            DirectoryChangeBatch(
                workspacePaths: [changedFile.path],
                gitStateMayHaveChanged: true,
                watchRootsChanged: true
            )
        )

        let recovered = await waitForWorkspaceObservation(timeout: .seconds(15)) {
            model.rootNode != nil && processedPaths.map(\.path) == [changedFile.path]
                && refreshCount == 1
        }

        #expect(recovered)
        #expect(model.rootNode != nil)
        #expect(processedPaths.map(\.path) == [changedFile.path])
        #expect(watcherFactory.configurations.last?.repositoryRoot == workspace)
        #expect(refreshCount == 1)
    }

    @Test
    @MainActor
    func foregroundRecoveryReparsesContextReplacesWatcherAndRefreshes() async {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-foreground/workspace")
        let gitDirectory = URL(fileURLWithPath: "/tmp/lithe-foreground/metadata.git")
        let context = GitWatchContext(
            repositoryRoot: workspace,
            gitDirectory: gitDirectory,
            gitCommonDirectory: gitDirectory
        )
        let watcherFactory = TestDirectoryWatcherFactory()
        var refreshCount = 0
        let model = makeWorkspaceObservationUnitModel(
            provider: SequencedGitWatchContextProvider([nil, context]),
            watcherFactory: watcherFactory,
            refreshGit: { refreshCount += 1 }
        )
        defer { model.reset() }
        model.beginWorkspace(at: workspace, visibilityRules: .default)

        await model.resumeObservationAfterActivation()
        await model.resumeObservationAfterActivation()

        #expect(watcherFactory.configurations.count == 3)
        #expect(watcherFactory.configurations.last?.gitDirectory == gitDirectory)
        #expect(refreshCount == 2)
    }

    @Test
    @MainActor
    func openDocumentOrderCanBeMovedAndRestored() async {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-editor-order-tests")
        let urls = [
            workspace.appendingPathComponent("A.swift"),
            workspace.appendingPathComponent("B.swift"),
            workspace.appendingPathComponent("C.swift")
        ]
        let model = DocumentFeatureModel(
            operations: EmptyWorkspaceOperations(readFileValue: "text"),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        model.configure(
            workspaceURLProvider: { workspace },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )

        for url in urls {
            await model.openFileAsync(
                url,
                isReadOnly: false,
                displayPath: nil,
                activateWhenReady: false
            )
        }

        let ids = model.openDocuments.map(\.id)
        model.moveDocument(ids[0], before: ids[2])
        #expect(model.openDocuments.map(\.url.lastPathComponent) == ["B.swift", "A.swift", "C.swift"])

        model.moveDocument(ids[0], after: ids[2])
        #expect(model.openDocuments.map(\.url.lastPathComponent) == ["B.swift", "C.swift", "A.swift"])

        model.reorderDocuments(orderedPaths: urls.reversed().map(\.path))
        #expect(model.openDocuments.map(\.url.lastPathComponent) == ["C.swift", "B.swift", "A.swift"])

        model.reorderDocuments(orderedIDs: [ids[0], ids[2], ids[1]])
        #expect(model.openDocuments.map(\.url.lastPathComponent) == ["A.swift", "C.swift", "B.swift"])
    }

    @Test
    @MainActor
    func switchingToAnOpenDocumentWinsOverAPendingFileOpen() async {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-pending-open-tests")
        let fileA = workspace.appendingPathComponent("A.swift")
        let fileB = workspace.appendingPathComponent("B.swift")
        let operations = BlockingWorkspaceOperations()
        defer { operations.releaseA() }
        let model = DocumentFeatureModel(
            operations: operations,
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        model.configure(
            workspaceURLProvider: { workspace },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )

        await model.openFileAsync(fileB, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        guard let documentB = model.openDocuments.first else {
            Issue.record("B.swift did not open")
            return
        }
        let pendingA = Task { @MainActor in
            await model.openFileAsync(fileA, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        }

        #expect(await operations.waitUntilReadingA())

        model.openFile(fileB)
        #expect(model.activeDocumentID == documentB.id)

        operations.releaseA()
        await pendingA.value
        #expect(model.activeDocumentID == documentB.id)
    }

    @Test
    @MainActor
    func foregroundRequestActivatesAnEquivalentPendingBackgroundOpen() async {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-equivalent-pending-open-tests")
        let fileA = workspace.appendingPathComponent("A.swift")
        let operations = BlockingWorkspaceOperations()
        defer { operations.releaseA() }
        let model = DocumentFeatureModel(
            operations: operations,
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        model.configure(
            workspaceURLProvider: { workspace },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )

        let pendingA = Task { @MainActor in
            await model.openFileAsync(
                fileA,
                isReadOnly: false,
                displayPath: nil,
                activateWhenReady: false
            )
        }
        #expect(await operations.waitUntilReadingA())

        await model.openFileAsync(
            workspace.appendingPathComponent("nested/../A.swift"),
            isReadOnly: false,
            displayPath: nil,
            activateWhenReady: true
        )
        operations.releaseA()
        await pendingA.value

        #expect(model.openDocuments.count == 1)
        #expect(model.activeDocumentID == model.openDocuments.first?.id)
    }

    @Test
    @MainActor
    func standardizedFilePathsReuseTheExistingDirtyDocument() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-standardized-path-tests")
        let featureDirectory = workspace.appendingPathComponent("Sources/Feature")
        let fileURL = featureDirectory.appendingPathComponent("Example.swift")

        let model = DocumentFeatureModel(
            operations: EmptyWorkspaceOperations(readFileValue: "original"),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        model.configure(
            workspaceURLProvider: { workspace },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )

        await model.openFileAsync(
            fileURL,
            isReadOnly: false,
            displayPath: nil,
            activateWhenReady: true
        )
        let originalDocument = try #require(model.openDocuments.first)
        originalDocument.text = "unsaved change"

        await model.openFileAsync(
            workspace.appendingPathComponent("Sources/Nested/../Feature/Example.swift"),
            isReadOnly: false,
            displayPath: nil,
            activateWhenReady: true
        )

        #expect(model.openDocuments.count == 1)
        #expect(model.openDocuments.first === originalDocument)
        #expect(originalDocument.text == "unsaved change")
        #expect(originalDocument.isDirty)
    }

    @Test
    func projectTreeLocatorMatchesStandardizedPathsAndExpandsParents() {
        let root = URL(fileURLWithPath: "/tmp/lithe-tree-locator-tests")
        let sourcesDirectory = root.appendingPathComponent("Sources")
        let featureDirectory = root.appendingPathComponent("Sources/Feature")
        let fileURL = featureDirectory.appendingPathComponent("Example.swift")
        let tree = FileNode(
            url: root,
            isDirectory: true,
            children: [
                FileNode(
                    url: featureDirectory,
                    isDirectory: true,
                    children: [FileNode(url: fileURL, isDirectory: false, children: nil)],
                    collapsedAncestorPaths: [sourcesDirectory.path]
                )
            ]
        )

        let equivalentFile = root.appendingPathComponent("Sources/Nested/../Feature/Example.swift")
        #expect(ProjectTreeLocator.matchingURL(for: equivalentFile, among: [fileURL]) == fileURL)
        #expect(
            ProjectTreeLocator.expandedDirectoryPaths(for: fileURL, rootURL: root)
                == Set([
                    root.standardizedFileURL.path,
                    root.appendingPathComponent("Sources").standardizedFileURL.path,
                    featureDirectory.standardizedFileURL.path
                ])
        )
        #expect(
            ProjectTreeLocator.matchingURL(
                for: root.deletingLastPathComponent().appendingPathComponent("Outside.swift"),
                among: [fileURL]
            ) == nil
        )
        #expect(ProjectTreeLocator.matchingURL(for: featureDirectory, in: tree) == featureDirectory)
        #expect(ProjectTreeLocator.matchingURL(for: sourcesDirectory, in: tree) == featureDirectory)
        #expect(ProjectTreeLocator.matchingURL(for: fileURL, in: tree) == fileURL)
        #expect(
            ProjectTreeLocator.expandedDirectoryPaths(
                for: featureDirectory,
                rootURL: root,
                includeItem: true
            ) == Set([
                root.standardizedFileURL.path,
                root.appendingPathComponent("Sources").standardizedFileURL.path,
                featureDirectory.standardizedFileURL.path
            ])
        )
        #expect(ProjectTreeLocator.matchingURL(for: root.appendingPathComponent("Hidden"), in: tree) == nil)
        #expect(
            ProjectTreeLocator.matchingURL(
                for: root.deletingLastPathComponent().appendingPathComponent("Outside"),
                in: tree
            ) == nil
        )
    }

    @Test
    @MainActor
    func editorViewportStoreRetainsStateForOpenDocuments() {
        let retainedID = UUID()
        let closedID = UUID()
        let store = EditorViewportStore()
        store.updateSelection(NSRange(location: 18, length: 4), for: retainedID)
        store.updateScrollOffset(240, for: retainedID)
        store.updateSelection(NSRange(location: 7, length: 0), for: closedID)

        #expect(
            store.state(for: retainedID)
                == EditorViewportState(
                    selectionLocation: 18,
                    selectionLength: 4,
                    verticalScrollOffset: 240
                )
        )

        store.retain(documentIDs: [retainedID])
        #expect(store.state(for: retainedID).selectionLocation == 18)
        #expect(store.state(for: closedID) == EditorViewportState())
    }
}

@MainActor
private func makeWorkspaceObservationUnitModel(
    operations: any WorkspaceOperations = EmptyWorkspaceOperations(),
    fileOperations: any WorkspaceFileOperations = EmptyWorkspaceFileOperations(),
    provider: any GitWatchContextProviding,
    watcherFactory: TestDirectoryWatcherFactory,
    refreshGit: @escaping @MainActor () async -> Void,
    processExternalChanges: @escaping @MainActor ([URL]) -> Bool = { _ in false },
    notifyWorkspaceFileChanges: @escaping @MainActor ([WorkspaceFileChange]) -> Void = { _ in },
    reloadProjectServices: @escaping @MainActor () async -> Void = {},
    recordHistory: @escaping @MainActor (URL, LocalHistoryReason) async -> Void = { _, _ in },
    directoryMarkStore: any WorkspaceDirectoryMarkStoring = EmptyWorkspaceDirectoryMarkStore(),
    observationDelay: (@Sendable (Duration) async throws -> Void)? = nil
) -> WorkspaceFeatureModel {
    let model = WorkspaceFeatureModel(
        operations: operations,
        fileOperations: fileOperations,
        fileStorage: InMemoryFileStorage(),
        gitWatchContextProvider: provider,
        directoryWatcherFactory: watcherFactory,
        workspaceSessionStore: WorkspaceSessionStore(store: EmptyKeyValueStore()),
        directoryMarkStore: directoryMarkStore,
        observationDelay: observationDelay
    )
    model.configure(
        documentsProvider: { [] },
        activeDocumentProvider: { nil },
        selectedSidebarProvider: { "project" },
        setSelectedSidebar: { _ in },
        restoreSession: { _, _ in },
        openFile: { _ in },
        notify: { _ in },
        recordHistory: recordHistory,
        relocateHistory: { _, _ in },
        relocateOpenDocuments: { _, _ in },
        closeDocuments: { _ in },
        processExternalChanges: processExternalChanges,
        notifyWorkspaceFileChanges: notifyWorkspaceFileChanges,
        reloadProjectServices: reloadProjectServices,
        refreshGit: refreshGit,
        updateHistoryVisibilityRules: { _ in },
        onSnapshotLoaded: { _, _, _ in }
    )
    return model
}

private final class RecordingWorkspaceDirectoryMarkStore: WorkspaceDirectoryMarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let initial: [String: WorkspaceDirectoryMark]
    private var storedSavedMarks: [String: WorkspaceDirectoryMark]?

    init(initial: [String: WorkspaceDirectoryMark]) {
        self.initial = initial
    }

    var savedMarks: [String: WorkspaceDirectoryMark]? {
        lock.lock()
        defer { lock.unlock() }
        return storedSavedMarks
    }

    func loadDirectoryMarks(
        for workspaceURL: URL
    ) throws -> [String: WorkspaceDirectoryMark] {
        initial
    }

    func saveDirectoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        for workspaceURL: URL
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        storedSavedMarks = marks
    }
}

private final class BlockingWorkspaceDirectoryMarkStore: WorkspaceDirectoryMarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let initialByWorkspace: [String: [String: WorkspaceDirectoryMark]]
    private let saveStarted: TestGate
    private let releaseSave: TestGate
    private var storedSavedMarks: [String: WorkspaceDirectoryMark]?

    init(
        initialByWorkspace: [String: [String: WorkspaceDirectoryMark]],
        saveStarted: TestGate,
        releaseSave: TestGate
    ) {
        self.initialByWorkspace = initialByWorkspace
        self.saveStarted = saveStarted
        self.releaseSave = releaseSave
    }

    var savedMarks: [String: WorkspaceDirectoryMark]? {
        lock.withLock { storedSavedMarks }
    }

    func loadDirectoryMarks(
        for workspaceURL: URL
    ) throws -> [String: WorkspaceDirectoryMark] {
        initialByWorkspace[workspaceURL.standardizedFileURL.path] ?? [:]
    }

    func saveDirectoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        for workspaceURL: URL
    ) throws {
        saveStarted.open()
        guard releaseSave.waitSynchronously(timeout: 5) else {
            throw CocoaError(.fileWriteUnknown)
        }
        lock.withLock {
            storedSavedMarks = marks
        }
    }
}

@MainActor
private func waitForWorkspaceObservation(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

private actor SequencedGitWatchContextProvider: GitWatchContextProviding {
    private var contexts: [GitWatchContext?]

    init(_ contexts: [GitWatchContext?]) {
        self.contexts = contexts
    }

    func watchContext(for workspace: URL) async -> GitWatchContext? {
        guard contexts.count > 1 else { return contexts.first ?? nil }
        return contexts.removeFirst()
    }
}

@MainActor
private final class TestTerminalTransport: TerminalTransport {
    let nativeView: AnyObject = NSView(frame: .zero)
    var isRunning = false
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var startRequests: [String] = []
    var stopCount = 0

    func defaultShellPath() -> String { "/bin/zsh" }

    func defaultEnvironment() -> [String: String] { [:] }

    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws {
        startRequests.append(shellPath)
        shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        isRunning = true
    }

    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        startRequests.append(launch.executablePath)
        shellName = URL(fileURLWithPath: launch.executablePath).lastPathComponent
        isRunning = true
        return 1234
    }

    func send(_ input: Data) throws {}

    func interrupt() throws {}

    func focus() {}

    func clear() {}

    func stop() {
        guard isRunning else { return }
        stopCount += 1
        isRunning = false
    }
}

private final class InMemoryFileStorage: FileStorage, GitShelfStorage, DatabaseFileStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let support = URL(fileURLWithPath: "/in-memory-application-support", isDirectory: true)
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []

    func homeDirectory() -> URL { support }
    func cacheDirectory() -> URL { support }
    func applicationSupportDirectory() -> URL { support }
    func temporaryDirectory() -> URL { support }
    func metadata(for url: URL) -> FileMetadata? {
        lock.lock()
        defer { lock.unlock() }
        if let data = files[url.path] {
            return FileMetadata(
                byteCount: data.count,
                modificationDate: nil,
                isRegularFile: true,
                isDirectory: false
            )
        }
        if directories.contains(url.path) {
            return FileMetadata(
                byteCount: nil,
                modificationDate: nil,
                isRegularFile: false,
                isDirectory: true
            )
        }
        return nil
    }

    func seed(_ data: Data, at url: URL) {
        lock.lock()
        files[url.path] = data
        lock.unlock()
    }

    func fileExists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[url.path] != nil || directories.contains(url.path)
    }

    func isExecutable(at url: URL) -> Bool { false }

    func listDirectory(at url: URL) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return files.keys
            .filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == url.path }
            .map { URL(fileURLWithPath: $0) }
    }

    func readData(from url: URL, options: Data.ReadingOptions = []) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let value = files[url.path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return value
    }

    func readData(from url: URL) throws -> Data {
        try readData(from: url, options: [])
    }

    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        try readData(from: url, options: []).prefix(byteCount)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        lock.lock()
        files[url.path] = data
        lock.unlock()
    }


    func writeData(_ data: Data, to url: URL) throws {
        try writeData(data, to: url, options: [])
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        lock.lock()
        directories.insert(url.path)
        lock.unlock()
    }


    func createDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard files.removeValue(forKey: url.path) != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let value = files.removeValue(forKey: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files[destinationURL.path] = value
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let value = files[sourceURL.path] else { throw CocoaError(.fileNoSuchFile) }
        files[destinationURL.path] = value
    }

    func firstStoredData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files.values.first
    }
}

private struct EmptyKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}

private final class MutableKeyValueStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private let dbxPlainConnectionExport = #"""
{
  "connections": [
    {
      "id": "mysql-1", "name": "Production MySQL", "db_type": "mysql",
      "host": "db.example.com", "port": 3306, "username": "root",
      "password": "db-secret", "database": "app", "color": "#ff5500",
      "read_only": true, "is_production": true, "ssl": true,
      "ca_cert_path": "/tmp/ca.pem",
      "transport_layers": [{"type":"ssh","enabled":true,"host":"jump.example.com","port":22,"user":"deploy","key_path":"/tmp/id_ed25519"}]
    },
    { "id": "sqlite-1", "name": "Local SQLite", "db_type": "sqlite", "host": "/tmp/local.sqlite", "port": 0, "username": "", "password": "", "database": "" },
    { "id": "oracle-1", "name": "Oracle", "db_type": "oracle", "host": "oracle.example.com", "port": 1521, "username": "scott", "password": "tiger" }
  ],
  "layout": {
    "groups": [{"id":"g1","name":"Production","collapsed":false},{"id":"g2","name":"Local","collapsed":false}],
    "order": [{"type":"group","id":"g1","connectionIds":["mysql-1"],"children":[{"type":"group","id":"g2","connectionIds":["sqlite-1"]}]}]
  }
}
"""#

private let dbxEncryptedConnectionExport = #"""
{"format":"dbx-encrypted","version":1,"salt":"AAECAwQFBgcICQoLDA0ODw==","iv":"EBESExQVFhcYGRob","data":"fdwV5NDM/8LXPJqMyQgoQVkuOwMe+0VDPFR8HsEWD1AMIhPz1sHRRkmzd6ZLcBqnfcA57xCJz3Jtnbf+djnYI83EiNkr6iukZq1Ahd8aGy/r61/JdThx/NTaUgzn0mwAIcpxDl9uyBDwI0PO8WAaXbZyWbFumsLn3SJSEb8d"}
"""#

@Suite("Editor session coordination")
@MainActor
struct EditorSessionCoordinatorTests {
    @Test(arguments: [true, false])
    func restorationPreservesSavedOrderAndSelectsAvailableDocument(activePathExists: Bool) async throws {
        let document = DocumentFeatureModel(
            operations: EmptyWorkspaceOperations(readFileValue: "restored"),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        document.configure(
            workspaceURLProvider: { URL(fileURLWithPath: "/in-memory") },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { Issue.record("Unexpected restoration notification: \($0)") },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )
        defer { document.reset() }
        let order = EditorTabOrderFeatureModel()
        let coordinator = EditorSessionCoordinator(
            document: document,
            media: MediaDocumentFeatureModel(),
            terminalPlacement: TerminalPlacementFeatureModel(),
            tabOrder: order
        )
        let first = URL(fileURLWithPath: "/in-memory/first.txt")
        let second = URL(fileURLWithPath: "/in-memory/second.txt")
        let missing = URL(fileURLWithPath: "/in-memory/missing.txt")
        await coordinator.restoreDocuments(
            orderedPaths: [second.path, missing.path, first.path],
            activePath: activePathExists ? second.path : missing.path,
            availableFiles: [first, second]
        )

        #expect(document.openDocuments.map(\.url) == [second, first])
        #expect(document.activeDocument?.url == (activePathExists ? second : first))
        #expect(order.items == document.openDocuments.map { .document($0.id) })
    }

    @Test
    func documentActivationSynchronizesTabsAndDeactivatesOtherEditors() throws {
        let document = makeDocumentFeature()
        let media = MediaDocumentFeatureModel()
        let terminal = TerminalPlacementFeatureModel()
        let order = EditorTabOrderFeatureModel()
        let coordinator = EditorSessionCoordinator(
            document: document, media: media, terminalPlacement: terminal, tabOrder: order
        )
        defer {
            withExtendedLifetime(coordinator) {}
            document.reset()
        }
        let image = media.open(url: URL(fileURLWithPath: "/in-memory/image.png"), kind: .image)
        let terminalID = UUID()
        terminal.registerSession(terminalID)
        terminal.moveToEditor(terminalID)
        terminal.activateEditorSession(terminalID)
        order.move(.terminal(terminalID), before: .media(image.id))
        #expect(media.activeMediaDocumentID == image.id)
        #expect(terminal.activeEditorSessionID == terminalID)

        document.openVirtualDocument(
            try #require(URL(string: "lithe-test://document/one")),
            text: "one",
            displayPath: nil
        )
        let opened = try #require(document.openDocuments.first)
        #expect(order.items == [.terminal(terminalID), .media(image.id), .document(opened.id)])
        #expect(media.activeMediaDocumentID == nil)
        #expect(terminal.activeEditorSessionID == nil)
        #expect(document.activeDocumentID == opened.id)

        media.close(image)
        #expect(order.items == [.terminal(terminalID), .document(opened.id)])
    }

    @Test
    func releasingCoordinatorCancelsCollectionAndSelectionSubscriptions() throws {
        let document = makeDocumentFeature()
        defer { document.reset() }
        let media = MediaDocumentFeatureModel()
        let terminal = TerminalPlacementFeatureModel()
        let order = EditorTabOrderFeatureModel()
        var coordinator: EditorSessionCoordinator? = EditorSessionCoordinator(
            document: document, media: media, terminalPlacement: terminal, tabOrder: order
        )
        weak var released = coordinator
        #expect(coordinator != nil)
        coordinator = nil
        #expect(released == nil)

        let image = media.open(url: URL(fileURLWithPath: "/in-memory/image.png"), kind: .image)
        let terminalID = UUID()
        terminal.registerSession(terminalID)
        terminal.moveToEditor(terminalID)
        terminal.activateEditorSession(terminalID)
        document.openVirtualDocument(
            try #require(URL(string: "lithe-test://document/unobserved")),
            text: "unobserved",
            displayPath: nil
        )
        #expect(order.items.isEmpty)
        #expect(media.activeMediaDocumentID == image.id)
        #expect(terminal.activeEditorSessionID == terminalID)
    }

    private func makeDocumentFeature() -> DocumentFeatureModel {
        DocumentFeatureModel(
            operations: EmptyWorkspaceOperations(),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: EmptyWorkspaceFileOperations(),
            fileStorage: InMemoryFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
    }
}

private struct EmptyWorkspaceOperations: WorkspaceOperations {
    let readFileValue: String?

    init(readFileValue: String? = nil) {
        self.readFileValue = readFileValue
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? { nil }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? { readFileValue }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class BlockingWorkspaceOperations: WorkspaceOperations, @unchecked Sendable {
    private let startedA = TestGate()
    private let releaseAGate = TestGate()

    var didStartReadingA: Bool {
        startedA.isOpen
    }

    func releaseA() {
        releaseAGate.open()
    }

    func waitUntilReadingA() async -> Bool {
        await startedA.waitUntilOpen()
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? { nil }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        if relativePath == "A.swift" {
            startedA.open()
            _ = releaseAGate.waitSynchronously()
            return "A"
        }
        return "B"
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class BlockingBinaryWorkspaceOperations: WorkspaceOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let readStarted = TestGate()
    private let releaseReadGate = TestGate()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func waitUntilReadingStarts() async -> Bool {
        await readStarted.waitUntilOpen()
    }

    func releaseRead() {
        releaseReadGate.open()
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? { nil }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        readStarted.open()
        if !releaseReadGate.waitSynchronously() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }
        return nil
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class SequencedWorkspaceOperations: WorkspaceOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotAvailability: [Bool]
    private let files: [URL]

    init(snapshotAvailability: [Bool], files: [URL] = []) {
        self.snapshotAvailability = snapshotAvailability
        self.files = files
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        lock.lock()
        let isAvailable = snapshotAvailability.isEmpty ? true : snapshotAvailability.removeFirst()
        lock.unlock()
        guard isAvailable else { return nil }
        return WorkspaceSnapshot(
            root: FileNode(
                url: rootURL,
                isDirectory: true,
                children: files.map { FileNode(url: $0, isDirectory: false, children: nil) }
            ),
            files: files
        )
    }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? { nil }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private struct ExistingWorkspaceFileOperations: WorkspaceFileOperations {
    let paths: Set<String>

    init(paths: [String]) {
        self.paths = Set(paths)
    }

    func fileExists(at url: URL) -> Bool { paths.contains(url.standardizedFileURL.path) }
    func isDirectory(at url: URL) -> Bool { false }
    func createFile(at url: URL) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func removeItem(at url: URL) throws {}
    func trashItem(at url: URL) throws {}
    func writeText(_ text: String, to url: URL) throws {}
    func readText(from url: URL) throws -> String { throw CocoaError(.fileReadNoSuchFile) }
}

private struct EmptyWorkspaceFileOperations: WorkspaceFileOperations {
    func fileExists(at url: URL) -> Bool { false }
    func isDirectory(at url: URL) -> Bool { false }
    func createFile(at url: URL) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func removeItem(at url: URL) throws {}
    func trashItem(at url: URL) throws {}
    func writeText(_ text: String, to url: URL) throws {}
    func readText(from url: URL) throws -> String { "" }
}

private final class RecordingTrashWorkspaceFileOperations: WorkspaceFileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let started = TestGate()
    private let releaseGate = TestGate()
    private var recordedTrashedURLs: [URL] = []

    var trashedURLs: [URL] {
        lock.withLock { recordedTrashedURLs }
    }

    var hasStarted: Bool {
        started.isOpen
    }

    func release() {
        releaseGate.open()
    }

    func waitUntilStarted() async -> Bool {
        await started.waitUntilOpen()
    }

    func fileExists(at url: URL) -> Bool { true }
    func isDirectory(at url: URL) -> Bool { false }
    func createFile(at url: URL) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func removeItem(at url: URL) throws {}
    func trashItem(at url: URL) throws {
        started.open()
        _ = releaseGate.waitSynchronously()
        lock.withLock {
            recordedTrashedURLs.append(url.standardizedFileURL)
        }
    }
    func writeText(_ text: String, to url: URL) throws {}
    func readText(from url: URL) throws -> String { "" }
}

private struct FailingTrashWorkspaceFileOperations: WorkspaceFileOperations {
    func fileExists(at url: URL) -> Bool { true }
    func isDirectory(at url: URL) -> Bool { false }
    func createFile(at url: URL) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func removeItem(at url: URL) throws {}
    func trashItem(at url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    func writeText(_ text: String, to url: URL) throws {}
    func readText(from url: URL) throws -> String { "" }
}

private final class TestDirectoryChangeSource: DirectoryChangeSource {
    private let onChange: @Sendable (DirectoryChangeBatch) -> Void

    init(onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) {
        self.onChange = onChange
    }

    func start() {}
    func stop() {}

    func emit(_ paths: [String]) {
        emit(DirectoryChangeBatch(workspacePaths: paths, gitStateMayHaveChanged: true))
    }

    func emit(_ batch: DirectoryChangeBatch) {
        onChange(batch)
    }
}

private final class TestDirectoryWatcherFactory: DirectoryWatcherFactory {
    private(set) var source: TestDirectoryChangeSource?
    private(set) var configurations: [DirectoryWatchConfiguration] = []

    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource {
        configurations.append(configuration)
        let source = TestDirectoryChangeSource(onChange: onChange)
        self.source = source
        return source
    }
}
