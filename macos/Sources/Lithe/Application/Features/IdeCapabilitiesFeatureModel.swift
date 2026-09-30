import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule

/// Workspace-bound application entry points shared by MCP and host API consumers.
@MainActor
final class IdeCapabilitiesFeatureModel: ObservableObject {
    private weak var model: (any IdeCapabilityActions)?
    @Published private(set) var isEnabled = false
    @Published private(set) var configuration = ""
    @Published private(set) var error: String?
    @Published var allowConfigure = false
    @Published var allowExecute = false
    private var hostID: String?
    private var workspace: WorkspaceIdentity?
    private var pollTask: Task<Void, Never>?
    private var requests: [String: Task<Void, Never>] = [:]
    private var mutationInFlight = false
    private var transport: (any IdeHostTransport)? { model?.ideHostTransport }

    init(model: any IdeCapabilityActions) { self.model = model }

    func enable() {
        disable()
        error = nil
        guard let model, let identity = model.currentWorkspaceIdentity, let transport else {
            error = "Open a project before enabling MCP."
            return
        }
        do {
            let result = try transport.open(workspace: identity.url, permissions: permissions)
            guard let id = result["hostID"] as? String, let config = result["configuration"] else { throw failure("Invalid MCP connection response") }
            hostID = id
            workspace = identity
            configuration = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            isEnabled = true
            model.registerIdeCapabilities(self)
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isEnabled else { return }
                    self.poll()
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
        } catch { self.error = error.localizedDescription; disable() }
    }

    func disable() {
        isEnabled = false
        model?.unregisterIdeCapabilities()
        pollTask?.cancel()
        pollTask = nil
        for task in requests.values { task.cancel() }
        requests.removeAll()
        mutationInFlight = false
        if let hostID {
            do { _ = try transport?.control("close", arguments: ["hostID": hostID]) }
            catch { self.error = error.localizedDescription }
        }
        hostID = nil
        workspace = nil
        configuration = ""
    }

    func shutdown() async {
        let activePoll = pollTask
        let activeRequests = Array(requests.values)
        disable()
        await activePoll?.value
        for request in activeRequests { await request.value }
    }

    func copyConfiguration() { model?.copyIdeConfiguration(configuration) }
    private var permissions: [String: Bool] { ["configure": allowConfigure, "execute": allowExecute] }
    private func failure(_ message: String) -> NSError { NSError(domain: "IdeCapabilities", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func failed(_ code: String, _ message: String) -> [String: Any] { ["ok": false, "error": ["code": code, "message": message]] }

    private func poll() {
        guard let model, let workspace, model.isCurrentWorkspace(workspace), let hostID, let transport else { disable(); return }
        do {
            let response = try transport.control("poll", arguments: ["hostID": hostID])
            for request in response["requests"] as? [[String: Any]] ?? [] {
                guard let id = request["requestID"] as? String, let name = request["name"] as? String else { continue }
                let arguments = request["arguments"] as? [String: Any] ?? [:]
                requests[id] = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.call(name, arguments: arguments)
                    if self.hostID == hostID, !Task.isCancelled {
                        do { _ = try transport.control("respond", arguments: ["hostID": hostID, "requestID": id, "result": result]) }
                        catch { self.error = error.localizedDescription }
                    }
                    self.requests[id] = nil
                }
            }
        } catch { self.error = error.localizedDescription; disable() }
    }

    /// A caller cannot provide its own permission grant or redirect the workspace.
    func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        guard isEnabled, let grant = hostID, let model, let workspace, model.isCurrentWorkspace(workspace), let transport else { return failed("WORKSPACE_CLOSED", "The authorized project is no longer open") }
        do {
            let validation = try transport.control("validate", arguments: ["name": name, "arguments": arguments, "permissions": permissions])
            guard validation["ok"] as? Bool == true else { return validation }
            let mutates = validation["mutation"] as? Bool == true
            if mutates && mutationInFlight { return failed("BUSY", "Another configuration or launch request is in progress") }
            if mutates { mutationInFlight = true }
            defer { if mutates && hostID == grant { mutationInFlight = false } }
            let result = try await execute(name, arguments, model: model, identity: workspace, grant: grant)
            if name == "lithe_operation_output", result["error"] == nil {
                return try transport.control("output", arguments: ["snapshot": result, "cursor": arguments["cursor"] ?? NSNull()])
            }
            return result
        } catch { return failed("OPERATION_FAILED", error.localizedDescription) }
    }

    private func check(_ model: any IdeCapabilityActions, _ identity: WorkspaceIdentity, grant: String) throws {
        guard isEnabled, hostID == grant, model.isCurrentWorkspace(identity), !Task.isCancelled else { throw failure("The authorized project was closed or access was disabled") }
    }

    private func execute(_ name: String, _ args: [String: Any], model: any IdeCapabilityActions, identity: WorkspaceIdentity, grant: String) async throws -> [String: Any] {
        if name == "lithe_project_inspect" { return ["workspaceID": model.id.uuidString, "name": model.projectName, "permissions": permissions] }
        guard let execution = await model.activateExecutionModule() else { return failed("NOT_AVAILABLE", "The execution module is disabled") }
        try check(model, identity, grant: grant)
        let run = execution.runFeature
        let maven = execution.mavenFeature
        if ["lithe_maven_inspect", "lithe_run_list", "lithe_maven_execute"].contains(name), !run.projectLoadState.hasLoadedDocuments(for: identity.url) {
            _ = await model.ensureRunProjectReady(run, for: identity)
            try check(model, identity, grant: grant)
        }
        switch name {
        case "lithe_environment_inspect", "lithe_environment_configure":
            await model.prepareProjectRuntimeSettings()
            try check(model, identity, grant: grant)
            if name == "lithe_environment_configure" {
                guard run.projectLoadState.hasLoadedDocuments(for: identity.url), !run.isLoadingProject else { return failed("NOT_READY", "Project settings are still loading") }
                if maven.project == nil && (args["settingsPath"] != nil || args["localRepositoryPath"] != nil) { return failed("NOT_READY", "No Maven project is loaded") }
                model.runtimeFeature.updateSettings { settings in
                    if let value = args["javaHomePath"] as? String { settings.javaHomePath = value }
                    if let value = args["mavenJavaHomePath"] as? String { settings.mavenJavaHomePath = value }
                    if let value = args["mavenExecutablePath"] as? String {
                        settings.mavenHomeSelection = value.isEmpty ? .automatic : value == "mvnw" ? .wrapper : .custom
                        settings.mavenHomePath = value
                    }
                    if let value = args["settingsPath"] as? String { settings.mavenSettingsPath = value }
                    if let value = args["localRepositoryPath"] as? String { settings.mavenLocalRepositoryPath = value }
                }
                model.persistProjectRuntimeSettings()
                if let error = run.configurationSaveError { throw failure(error) }
                if maven.project != nil, let error = await maven.saveConfiguration() { throw failure(error) }
                try check(model, identity, grant: grant)
            }
            return environment(model, root: identity.url)
        case "lithe_maven_inspect":
            let project: [String: Any]? = maven.project.map {
                ["artifactId": $0.artifactID, "modules": $0.modules.map(moduleJSON), "profiles": $0.profiles.map { ["id": $0.id] }]
            }
            return [
                "project": project as Any? ?? NSNull(),
                "profiles": maven.selectedProfiles.sorted(), "skipTests": maven.skipTests,
                "reloadRequired": maven.isReloadRequired,
                "diagnostic": (maven.reloadError ?? maven.configurationSaveError ?? maven.javaConfigurationError) as Any? ?? NSNull()
            ]
        case "lithe_maven_configure":
            guard maven.project != nil else { return failed("NOT_READY", "Load a Maven project first") }
            if let profiles = args["profiles"] as? [String] {
                for profile in profiles { _ = maven.addCustomProfile(profile) }
                maven.setSelectedProfiles(Set(profiles))
            }
            if let skip = args["skipTests"] as? Bool { maven.setSkipTests(skip) }
            if let error = await maven.saveConfiguration() { throw failure(error) }
            try check(model, identity, grant: grant)
            return ["saved": true, "profiles": maven.selectedProfiles.sorted(), "skipTests": maven.skipTests, "reloadRequired": maven.isReloadRequired]
        case "lithe_maven_reload":
            await model.reloadMavenProject(rescan: true)
            try check(model, identity, grant: grant)
            if let error = maven.reloadError { throw failure(error) }
            return ["outcome": maven.project == nil ? "noProject" : "completed"]
        case "lithe_maven_execute":
            guard let project = maven.project else { return failed("NOT_READY", "Load a Maven project first") }
            guard !maven.isRunning, !maven.isReloading else { return failed("BUSY", "A Maven operation is already active") }
            let path = args["modulePath"] as? String ?? "."
            let module = findModule(path, in: project.modules)
            guard path == "." || module != nil else { return failed("NOT_FOUND", "Unknown Maven module") }
            let goals = args["goals"] as? [String] ?? []
            maven.runCustomGoal(goals.joined(separator: " "), module: module)
            model.showMavenOutput()
            guard let operationID = maven.outputOperationID else { return failed("LAUNCH_FAILED", "Maven launch did not start") }
            return ["operationID": operationID, "state": mavenState(maven)]
        case "lithe_run_list":
            return ["configurations": run.configurations.filter { $0.kind != .currentFile }.map { ["id": $0.id, "name": $0.name, "provider": $0.kind.providerID] }, "status": runStatus(run.configurationStatus)]
        case "lithe_run_start":
            return try await start(args["configurationID"] as? String ?? "", model: model, identity: identity, run: run, grant: grant)
        case "lithe_operations_list":
            return ["operations": operations(run: run, maven: maven).map { $0.filter { $0.key != "output" && $0.key != "sessionID" } }]
        case "lithe_operation_output", "lithe_operation_stop", "lithe_run_restart":
            let id = args["operationID"] as? String ?? ""
            guard let operation = operations(run: run, maven: maven).first(where: { $0["operationID"] as? String == id }) else { return failed("OPERATION_EXPIRED", "This execution was replaced or removed from IDE history") }
            if name == "lithe_operation_output" { return operation }
            if id.hasPrefix("maven:") {
                guard name != "lithe_run_restart" else { return failed("INVALID_ARGUMENTS", "Use Maven execute to start another build") }
                maven.stop()
            } else if let primaryID = run.primaryExecutionID, id == "run:" + primaryID {
                if name == "lithe_run_restart", run.lastConfiguration?.kind == .currentFile {
                    return failed("INVALID_ARGUMENTS", "Restart requires a saved project configuration")
                }
                let configurationID = run.lastConfiguration?.id ?? ""
                run.stop()
                if name == "lithe_run_restart" { return try await start(configurationID, model: model, identity: identity, run: run, grant: grant) }
            } else if let session = run.moduleSessions.first(where: { "run:" + $0.executionID == id }) {
                run.stopModule(session)
                if name == "lithe_run_restart" { return try await start(session.configurationID, model: model, identity: identity, run: run, grant: grant) }
            }
            return ["operationID": id, "stopRequested": true]
        default: return failed("NOT_SUPPORTED", "Unknown IDE capability")
        }
    }

    private func start(_ id: String, model: any IdeCapabilityActions, identity: WorkspaceIdentity, run: RunFeatureModel, grant: String) async throws -> [String: Any] {
        guard let configuration = run.configurations.first(where: { $0.id == id && $0.kind != .currentFile }) else { return failed("NOT_FOUND", "Choose an existing project run configuration") }
        guard !run.moduleSessions.contains(where: { $0.configurationID == id && $0.isRunning }) else { return failed("BUSY", "This configuration is already running") }
        if run.isRunning && run.lastConfiguration?.id == id { return failed("BUSY", "This configuration is already running") }
        let previous = run.moduleSessions.first { $0.configurationID == id }?.executionID
        await model.startAPIConfiguration(configuration)
        try check(model, identity, grant: grant)
        guard let session = run.moduleSessions.first(where: { $0.configurationID == id }), session.executionID != previous else { return failed("LAUNCH_FAILED", "Launch did not start. Check the IDE project readiness and any pending launch decision.") }
        if !session.isRunning, let exitCode = session.exitCode, exitCode != 0 {
            var result = failed("LAUNCH_FAILED", "Launch failed. Read the operation output for details.")
            result["operationID"] = "run:" + session.executionID
            return result
        }
        return ["operationID": "run:" + session.executionID]
    }

    private func operations(run: RunFeatureModel, maven: MavenFeatureModel) -> [[String: Any]] {
        var values: [[String: Any]] = run.moduleSessions.map { session in
            ["operationID": "run:" + session.executionID, "kind": "run", "configurationID": session.configurationID, "sessionID": session.id, "title": session.title, "state": session.isRunning ? "running" : session.exitCode == nil ? "cancelled" : session.exitCode == 0 ? "completed" : "failed", "exitCode": session.exitCode as Any? ?? NSNull(), "output": session.output]
        }
        if let id = run.primaryExecutionID {
            values.append([
                "operationID": "run:" + id, "kind": "run",
                "configurationID": run.lastConfiguration?.id ?? "", "sessionID": "primary",
                "title": run.lastConfiguration?.name ?? "Run",
                "state": run.isRunning ? "running" : run.lastExitCode == nil ? "cancelled" : run.lastExitCode == 0 ? "completed" : "failed",
                "exitCode": run.lastExitCode as Any? ?? NSNull(), "output": run.output
            ])
        }
        if let id = maven.outputOperationID {
            values.append(["operationID": id, "kind": "maven", "configurationID": "", "sessionID": id, "title": maven.runningTitle ?? "Maven", "state": mavenState(maven), "exitCode": maven.lastExitCode as Any? ?? NSNull(), "output": maven.output])
        }
        return values.sorted { ($0["operationID"] as? String ?? "") < ($1["operationID"] as? String ?? "") }
    }

    private func mavenState(_ maven: MavenFeatureModel) -> String {
        switch maven.taskState {
        case .running: "running"
        case .stopping: "stopping"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .idle: maven.lastExitCode == 0 ? "completed" : "cancelled"
        }
    }

    private func moduleJSON(_ module: MavenModule) -> [String: Any] {
        ["relativePath": module.relativePath, "artifactId": module.artifactID, "modules": module.modules.map(moduleJSON)]
    }
    private func findModule(_ path: String, in modules: [MavenModule]) -> MavenModule? {
        for module in modules { if module.relativePath == path { return module }; if let found = findModule(path, in: module.modules) { return found } }
        return nil
    }
    private func runStatus(_ status: ProjectRunConfigurationStatus) -> String {
        switch status { case .missing: "missing"; case .ready: "ready"; case .invalid: "invalid" }
    }

    private func environment(_ model: any IdeCapabilityActions, root: URL) -> [String: Any] {
        let feature = model.runtimeFeature
        let settings = feature.settings
        return ["scope": "project-local", "settings": ["javaHomePath": settings.javaHomePath, "mavenExecutablePath": settings.mavenExecutableOverride, "mavenJavaHomePath": settings.mavenJavaHomePath, "settingsPath": settings.mavenSettingsPath, "localRepositoryPath": settings.mavenLocalRepositoryPath], "discovered": ["java": feature.javaRuntimes.map { ["homePath": $0.homePath, "version": $0.version, "vendor": $0.vendor] }, "maven": feature.mavenRuntimes.map { ["executablePath": $0.executablePath, "version": $0.version] }], "effective": ["java": choice(feature.javaChoice(overridePath: nil)), "mavenJava": choice(feature.mavenJavaChoice(overridePath: nil)), "maven": choice(feature.mavenChoice(at: root, overridePath: nil))]]
    }
    private func choiceSource(_ source: RuntimeChoiceSource) -> String {
        switch source {
        case .configured: "configured"
        case .projectSetting: "project"
        case .javaHomeEnvironment: "javaHome"
        case .detected: "detected"
        case .projectJDK: "projectJdk"
        case .mavenWrapper: "mavenWrapper"
        case .systemMaven: "path"
        }
    }
    private func choice(_ value: RuntimeChoice?) -> [String: Any] {
        switch value {
        case .found(let url, let source): return ["status": "resolved", "path": url.path, "source": choiceSource(source)]
        case .invalid(let path): return ["status": "invalid", "message": "Invalid toolchain: " + path]
        case .fallback(let path, let next): var result = choice(next); result["invalidOverride"] = path; return result
        case .notFound: return ["status": "notFound"]
        case nil: return ["status": "loading"]
        }
    }
}
