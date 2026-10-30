import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Workspace-bound application entry points shared by MCP and host API consumers.
@MainActor
final class IdeCapabilitiesFeatureModel: ObservableObject {
    /// Only workflows implemented by this product are advertised. Schema types
    /// and permissions remain in the shared catalog; this list can only narrow it.
    static let toolExposure: [[String: Any]] = [
        "lithe_project_inspect", "lithe_environment_inspect", "lithe_environment_configure",
        "lithe_run_list", "lithe_run_start", "lithe_run_restart", "lithe_operations_list",
        "lithe_operation_output", "lithe_operation_stop", "lithe_build_inspect",
        "lithe_build_reload", "lithe_build_configure", "lithe_build_execute"
    ].map { name in
        name == "lithe_environment_configure"
            ? ["name": name, "arguments": ["javaHomePath", "mavenExecutablePath", "mavenJavaHomePath"]]
            : ["name": name]
    }
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
            let result = try transport.open(workspace: identity.url, permissions: permissions, toolExposure: Self.toolExposure)
            guard let id = result["hostID"] as? String, let config = result["configuration"] else { throw failure("Invalid MCP connection response") }
            hostID = id
            workspace = identity
            configuration = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            isEnabled = true
            model.registerIdeCapabilities(self)
            registerLitheServer(from: config, model: model)
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
        // Project-level Agent entries point at this host only while the grant
        // is active; leaving them behind would advertise a closed connection.
        model?.unregisterLitheMcpServer()
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

    /// Forwards the helper command the host generated so the library can write
    /// the same server into the open project's Codex and Claude configuration.
    private func registerLitheServer(from configuration: Any, model: any IdeCapabilityActions) {
        guard let servers = (configuration as? [String: Any])?["mcpServers"] as? [String: Any],
              let lithe = servers["lithe"] as? [String: Any],
              let command = lithe["command"] as? String else { return }
        model.registerLitheMcpServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: command,
            args: lithe["args"] as? [String] ?? []
        ))
    }

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
            let validation = try transport.control("validate", arguments: ["name": name, "arguments": arguments, "permissions": permissions, "toolExposure": Self.toolExposure])
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
        if name == "lithe_environment_inspect" || name == "lithe_environment_configure" {
            await model.runtimeFeature.ensureRuntimesDiscovered()
            try check(model, identity, grant: grant)
            guard !model.runtimeFeature.hasChanges, !model.runtimeFeature.isSaving else {
                return failed("BUSY", "Save or cancel the open environment settings draft before using this capability")
            }
            guard model.runtimeFeature.reloadToolchainSettings() else {
                throw failure(model.runtimeFeature.settingsError ?? L10n.string("Could not verify the saved project environment settings. The previous preferences have been kept when possible."))
            }
            if name == "lithe_environment_configure" {
                model.runtimeFeature.updateSettings { settings in
                    if let value = args["javaHomePath"] as? String { settings.javaHomePath = value }
                    if let value = args["mavenJavaHomePath"] as? String { settings.mavenJavaHomePath = value }
                    if let value = args["mavenExecutablePath"] as? String {
                        settings.mavenHomeSelection = value.isEmpty ? .automatic : value == "mvnw" ? .wrapper : .custom
                        settings.mavenHomePath = value
                    }
                }
                guard model.runtimeFeature.saveSettings() else {
                    throw failure(model.runtimeFeature.settingsError ?? L10n.string("Could not verify the saved project environment settings. The previous preferences have been kept when possible."))
                }
                model.runtimeFeature.finishSaving()
                try check(model, identity, grant: grant)
            }
            return environment(model, root: identity.url)
        }
        guard let execution = await model.activateExecutionModule() else { return failed("NOT_AVAILABLE", "The execution module is disabled") }
        try check(model, identity, grant: grant)
        let run = execution.runFeature
        if name == "lithe_run_list", !run.projectLoadState.hasLoadedDocuments(for: identity.url) {
            _ = await model.ensureRunProjectReady(run, for: identity)
            try check(model, identity, grant: grant)
        }
        switch name {
        case "lithe_build_inspect":
            guard let build = execution.buildSystems else { return failed("NOT_AVAILABLE", L10n.string("Build plugins are unavailable")) }
            return ["detecting": build.isDetecting, "issues": build.issues,
                    "instances": build.entries.map(buildEntryJSON)]
        case "lithe_build_reload":
            guard let build = execution.buildSystems, let entry = build.entry(args["instanceID"] as? String ?? "") else {
                return failed("NOT_FOUND", L10n.string("Choose a detected build instance"))
            }
            build.loadModel(entry.id, reason: .refresh)
            return ["instanceID": entry.id, "reloadRequested": true]
        case "lithe_build_configure":
            guard let build = execution.buildSystems, let entry = build.entry(args["instanceID"] as? String ?? "") else {
                return failed("NOT_FOUND", L10n.string("Choose a detected build instance"))
            }
            let value = try JSONDecoder().decode(ToolingJSONValue.self,
                from: JSONSerialization.data(withJSONObject: args["value"] ?? NSNull(), options: [.fragmentsAllowed]))
            let option = try build.configureOption(entry.id, optionID: args["optionID"] as? String ?? "", value: value == .null ? nil : value)
            return ["saved": true, "instanceID": entry.id, "option": try buildOptionJSON(option),
                    "reloadRequired": build.entry(entry.id)?.isReloadRequired == true]
        case "lithe_build_execute":
            guard let build = execution.buildSystems, let entry = build.entry(args["instanceID"] as? String ?? "") else {
                return failed("NOT_FOUND", L10n.string("Choose a detected build instance"))
            }
            guard !build.isRunning else { return failed("BUSY", L10n.string("A build operation is already active")) }
            let taskID = args["taskID"] as? String ?? ""
            guard let declaration = entry.declaration.tasks.first(where: { $0.id == taskID }) else {
                return failed("NOT_FOUND", L10n.string("Choose a declared build task"))
            }
            let projectID = args["projectID"] as? String
            let targetID = args["targetID"] as? String
            let modelTaskID = args["modelTaskID"] as? String
            if projectID != nil || targetID != nil || modelTaskID != nil {
                guard entry.modelState == .loaded, !entry.isReloadRequired else {
                    return failed("NOT_READY", L10n.string("Reload the build model before selecting a project, target or model task"))
                }
            }
            let project = entry.model?.projects.first { $0.id == projectID }
            let target = entry.model?.targets.first { $0.id == targetID && $0.projectID == projectID }
            let task = entry.model?.tasks.first { $0.id == modelTaskID && $0.projectID == projectID && $0.template == taskID }
            guard (projectID == nil || project != nil), (targetID == nil || target != nil),
                  declaration.fromModel == (modelTaskID != nil), (modelTaskID == nil || task != nil) else {
                return failed("NOT_FOUND", L10n.string("The build selection is no longer available"))
            }
            let request = BuildTaskRequest(task: taskID, project: project.map(BuildSelection.init(project:)),
                target: target.map(BuildSelection.init(target:)), modelTask: task.map(BuildSelection.init(task:)),
                userArguments: args["userArguments"] as? [String] ?? [])
            guard let id = build.runTask(entry.id, request: request, title: task?.displayName ?? declaration.displayName) else {
                return failed("LAUNCH_FAILED", L10n.string("Build launch did not start"))
            }
            return ["operationID": "build:" + id.uuidString, "state": "running"]
        case "lithe_run_list":
            return ["configurations": run.configurations.filter { $0.kind != .currentFile }.map { ["id": $0.id, "name": $0.name, "provider": $0.kind.providerID] }, "status": runStatus(run.configurationStatus)]
        case "lithe_run_start":
            return try await start(args["configurationID"] as? String ?? "", model: model, identity: identity, run: run, grant: grant)
        case "lithe_operations_list":
            return ["operations": operations(run: run, build: execution.buildSystems).map { $0.filter { $0.key != "output" && $0.key != "sessionID" } }]
        case "lithe_operation_output", "lithe_operation_stop", "lithe_run_restart":
            let id = args["operationID"] as? String ?? ""
            guard let operation = operations(run: run, build: execution.buildSystems).first(where: { $0["operationID"] as? String == id }) else { return failed("OPERATION_EXPIRED", "This execution was replaced or removed from IDE history") }
            if name == "lithe_operation_output" { return operation }
            if id.hasPrefix("build:") {
                guard name != "lithe_run_restart" else { return failed("INVALID_ARGUMENTS", L10n.string("Use Build execute to start another build")) }
                if let retained = execution.buildSystems?.operation {
                    execution.buildSystems?.cancelRun(retained.id)
                }
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
        let previousPrimary = run.primaryExecutionID
        let previous = run.moduleSessions.first { $0.configurationID == id }?.executionID
        await model.startAPIConfiguration(configuration)
        try check(model, identity, grant: grant)
        if configuration.buildProvider != nil && (configuration.buildProvider?.execution ?? .application) == .application {
            guard let operationID = run.primaryExecutionID, operationID != previousPrimary,
                  run.lastConfiguration?.id == id else {
                return failed("LAUNCH_FAILED", "Launch did not start. Check the IDE project readiness and any pending launch decision.")
            }
            if !run.isRunning, let exitCode = run.lastExitCode, exitCode != 0 {
                var result = failed("LAUNCH_FAILED", "Launch failed. Read the operation output for details.")
                result["operationID"] = "run:" + operationID
                return result
            }
            return ["operationID": "run:" + operationID]
        }
        guard let session = run.moduleSessions.first(where: { $0.configurationID == id }), session.executionID != previous else { return failed("LAUNCH_FAILED", "Launch did not start. Check the IDE project readiness and any pending launch decision.") }
        if !session.isRunning, let exitCode = session.exitCode, exitCode != 0 {
            var result = failed("LAUNCH_FAILED", "Launch failed. Read the operation output for details.")
            result["operationID"] = "run:" + session.executionID
            return result
        }
        return ["operationID": "run:" + session.executionID]
    }

    private func operations(run: RunFeatureModel, build: BuildSystemsFeatureModel?) -> [[String: Any]] {
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
        if let operation = build?.operation {
            let id = "build:" + operation.id.uuidString
            values.append(["operationID": id, "kind": "build", "configurationID": "", "sessionID": id,
                "title": operation.title, "state": buildState(operation.state),
                "exitCode": operation.exitCode as Any? ?? NSNull(), "output": operation.output])
        }
        return values.sorted { ($0["operationID"] as? String ?? "") < ($1["operationID"] as? String ?? "") }
    }

    private func buildState(_ state: BuildRunState) -> String {
        switch state {
        case .running: "running"
        case .succeeded: "completed"
        case .failed: "failed"
        case .cancelled, .idle: "cancelled"
        }
    }

    private func buildEntryJSON(_ entry: BuildSystemEntry) -> [String: Any] {
        ["instanceID": entry.id, "pluginID": entry.source.pluginID, "buildSystemID": entry.instance.buildSystemID,
         "root": entry.instance.root, "name": entry.instance.displayName, "reloadRequired": entry.isReloadRequired,
         "modelState": entry.modelState == .loaded ? "ready" : entry.modelState == .loading ? "loading" : "unavailable",
         "tasks": entry.declaration.tasks.map { ["id": $0.id, "name": $0.displayName, "fromModel": $0.fromModel,
             "scopes": $0.scopes.map(\.rawValue), "requiresUserArguments": $0.requiresUserArguments] as [String: Any] },
         "projects": entry.model?.projects.map { ["id": $0.id, "name": $0.name, "path": $0.path] } ?? [],
         "targets": entry.model?.targets.map { ["id": $0.id, "projectID": $0.projectID, "name": $0.name] } ?? [],
         "modelTasks": entry.model?.tasks.map { ["id": $0.id, "projectID": $0.projectID, "taskID": $0.template,
             "name": $0.displayName ?? $0.name] } ?? [],
         "options": entry.options.compactMap { try? buildOptionJSON($0) },
         "nativeConfiguration": entry.declaration.nativeConfiguration]
    }

    private func buildOptionJSON(_ option: BuildResolvedOption) throws -> [String: Any] {
        ["id": option.id, "name": option.displayName, "kind": option.kind?.rawValue as Any? ?? NSNull(),
         "value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(option.value), options: [.fragmentsAllowed]),
         "source": option.source, "scope": option.scope.rawValue, "allowCustom": option.allowCustom,
         "choices": option.choices.map { ["value": $0.value, "name": $0.title ?? $0.value] }]
    }

    private func runStatus(_ status: ProjectRunConfigurationStatus) -> String {
        switch status { case .missing: "missing"; case .ready: "ready"; case .invalid: "invalid" }
    }

    private func environment(_ model: any IdeCapabilityActions, root: URL) -> [String: Any] {
        let feature = model.runtimeFeature
        let settings = feature.settings
        return ["scope": "project-local", "settings": ["javaHomePath": settings.javaHomePath, "mavenExecutablePath": settings.mavenExecutableOverride, "mavenJavaHomePath": settings.mavenJavaHomePath], "discovered": ["java": feature.javaRuntimes.map { ["homePath": $0.homePath, "version": $0.version, "vendor": $0.vendor] }, "maven": feature.mavenRuntimes.map { ["executablePath": $0.executablePath, "version": $0.version] }], "effective": ["java": choice(feature.javaChoice(overridePath: nil)), "mavenJava": choice(feature.mavenJavaChoice(overridePath: nil)), "maven": choice(feature.mavenChoice(at: root, overridePath: nil))]]
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
        case .warning(let url, let source, let message):
            return ["status": "resolved", "path": url.path, "source": choiceSource(source), "warning": message]
        case .unavailable(let message): return ["status": "invalid", "message": message]
        case .notFound: return ["status": "notFound"]
        case nil: return ["status": "loading"]
        }
    }
}
