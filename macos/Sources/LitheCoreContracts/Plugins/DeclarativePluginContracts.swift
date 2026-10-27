import Foundation
import LitheModuleAPI

// Note: 声明式插件的归属与加载流程见 .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md

/// Stable refusal of a declarative manifest or plan request. `code` is one of
/// the `plugin.*` codes in shared/contracts/plugins/v1/README.md.
public struct DeclarativePluginRejection: Error, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let field: String?

    public init(code: String, message: String, field: String? = nil) {
        self.code = code
        self.message = message
        self.field = field
    }

    public var errorDescription: String? { message }

    /// Run workflows already present path failures with their own message.
    public var runError: any Error {
        code == "plugin.path.invalid" ? LanguageRunExtensionError.invalidRelativePath : self
    }

    public func testError(languageID: String) -> any Error {
        switch code {
        case "plugin.path.invalid": LanguageTestExtensionError.invalidRelativePath
        case "plugin.test.invalidIdentifier": LanguageTestExtensionError.invalidTestIdentifier
        case "plugin.test.unsupportedProject": LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        default: self
        }
    }
}

public struct DeclarativeLanguageServer: Equatable, Sendable {
    public enum Launch: Equatable, Sendable {
        /// Executable inside the plugin package, relative to its root.
        case packaged(relativePath: String)
        /// Bare command names resolved by the host's tool discovery.
        case systemCommand([String])
        /// Entry file inside the package, started by a runtime such as `java`
        /// or `node` (plugin API 2). `packagedRuntime` is the template of the
        /// runtime the plugin ships, for example `runtime/${arch}/bin/java`;
        /// `nil` means the host discovers the tool.
        case runtime(tool: String, entryRelativePath: String, packagedRuntime: String?)
    }

    public let languageID: String
    public let languageIdentifier: String
    public let launch: Launch
    public let arguments: [String]
    public let validationArguments: [String]
    /// Runtimes the host discovers for the server, such as `node`.
    public let runtimeTools: [String]
    /// True from plugin API 2 on, where arguments are launch templates that
    /// Rust Core expands with host directories before the server starts.
    public let expandsLaunchTemplates: Bool
    /// Native host integration the server declares, such as `jdt`. The host
    /// enables that integration for this server instead of matching on its
    /// language ID.
    public let hostIntegrationID: String?

    /// Tool of a runtime launch, such as `node`. The executable the host
    /// starts for this server is that runtime, and the server's own child
    /// processes expect to find the same one by name.
    public var launchRuntimeTool: String? {
        if case .runtime(let tool, _, _) = launch { tool } else { nil }
    }

    /// Path inside the plugin package for a packaged server.
    public var packagedRelativePath: String? {
        if case .packaged(let relativePath) = launch { relativePath } else { nil }
    }

    /// Command names the host's tool discovery resolves for a system command.
    /// A packaged server reports its file name for display only; the host
    /// launches the pinned path inside its own package.
    public var executableNames: [String] {
        switch launch {
        case .packaged(let relativePath):
            [relativePath.split(separator: "/").last.map(String.init) ?? relativePath]
        case .systemCommand(let commands):
            commands
        case .runtime(let tool, _, _):
            // The runtime is the process the host starts; the entry file is
            // an argument of the expanded launch plan.
            [tool]
        }
    }
}

/// Identifies the declaration a language server's launch plan is expanded
/// from. It is plain data so launch descriptors stay comparable.
public struct DeclarativeLanguageServerLaunchSource: Hashable, Sendable {
    public let pluginID: String
    public let languageID: String
    /// Normalized `plugin.json` returned by `plugins.declarative.validate`.
    public let manifest: Data
    /// Root of the installed, read-only plugin package.
    public let packageURL: URL

    public init(pluginID: String, languageID: String, manifest: Data, packageURL: URL) {
        self.pluginID = pluginID
        self.languageID = languageID
        self.manifest = manifest
        self.packageURL = packageURL
    }
}

/// Version a discovered executable must report before the host uses it. The
/// probe arguments come from Rust Core, so the host needs no per-tool rules.
public struct LanguageServerExecutableVersionRequirement: Hashable, Sendable {
    public let tool: String
    public let minimumVersion: String
    /// Arguments that make the tool print its version and exit.
    public let probeArguments: [String]

    public init(tool: String, minimumVersion: String, probeArguments: [String]) {
        self.tool = tool
        self.minimumVersion = minimumVersion
        self.probeArguments = probeArguments
    }
}

/// Outcome of `plugins.declarative.checkRuntimeVersion`.
public struct LanguageServerRuntimeVersionCheck: Equatable, Sendable {
    public let satisfied: Bool
    /// Version read from the probe output; `nil` when it contained none.
    public let version: String?

    public init(satisfied: Bool, version: String?) {
        self.satisfied = satisfied
        self.version = version
    }
}

/// Host directories substituted into a server's launch templates.
public struct DeclarativeLanguageServerLaunchRequest: Equatable, Sendable {
    public let pluginDirectory: URL
    public let stateDirectory: URL
    /// Nil for a process bound to no workspace, such as a plugin backend;
    /// Core then refuses a launch that names `${workspaceStateDir}`.
    public let workspaceStateDirectory: URL?
    /// `arm64` or `x86_64`.
    public let architecture: String
    /// Values the user stored for the plugin's settings, by setting ID. Rust
    /// Core falls back to the declared default for a missing or no longer
    /// acceptable value.
    public let settings: [String: ToolingJSONValue]
    /// The workspace's overrides of project-scoped settings.
    public let projectSettings: [String: ToolingJSONValue]

    public init(
        pluginDirectory: URL,
        stateDirectory: URL,
        workspaceStateDirectory: URL?,
        architecture: String,
        settings: [String: ToolingJSONValue] = [:],
        projectSettings: [String: ToolingJSONValue] = [:]
    ) {
        self.pluginDirectory = pluginDirectory
        self.stateDirectory = stateDirectory
        self.workspaceStateDirectory = workspaceStateDirectory
        self.architecture = architecture
        self.settings = settings
        self.projectSettings = projectSettings
    }
}

/// One option a declarative plugin lets the user change (plugin API 2). The
/// plugin names it in launch templates; the host shows it on the page the
/// declaration places it on and keeps the value per plugin, and per project
/// for project-scoped settings (settings capability 2).
public struct DeclarativePluginSetting: Equatable, Identifiable, Sendable {
    public struct Option: Equatable, Sendable {
        public let value: String
        public let title: String

        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public enum Kind: Equatable, Sendable {
        case integer(minimum: Int, maximum: Int, unit: String?)
        case choice([Option])
        case toggle
        case multiSelect([Option])
        /// Free text matched in whole by `pattern`, which Rust Core requires.
        case text(pattern: String, maxLength: Int, placeholder: String?)
        /// An absolute path, or empty for "not set".
        case path(directory: Bool, placeholder: String?)
    }

    /// Where a value may be kept. A project value overrides the global one.
    public enum Scope: String, Equatable, Sendable {
        case global
        case project
    }

    /// When a changed value takes effect, shown next to the control.
    public enum Effect: String, Equatable, Sendable {
        /// The language server restarts with the new launch.
        case restart
        /// Sent to the running server through workspace configuration.
        case immediate
        /// The build model reloads.
        case reload
        /// The next run, test, or build uses it.
        case nextRun
    }

    /// The generated settings page that shows the declaration. Without one it
    /// stays on the plugin's own page under Tools.
    public enum Page: Hashable, Sendable {
        case language(String)
        case buildSystem(String)
    }

    public let id: String
    public let title: String
    public let summary: String?
    public let kind: Kind
    public let defaultValue: ToolingJSONValue
    public let scope: Scope
    public let effect: Effect
    public let page: Page?
    /// Optional group heading within the page.
    public let section: String?

    public init(
        id: String,
        title: String,
        summary: String?,
        kind: Kind,
        defaultValue: ToolingJSONValue,
        scope: Scope = .global,
        effect: Effect = .restart,
        page: Page? = nil,
        section: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.kind = kind
        self.defaultValue = defaultValue
        self.scope = scope
        self.effect = effect
        self.page = page
        self.section = section
    }

    /// Whether `value` is one this declaration can hold. Mirrors the check Rust
    /// Core applies when it expands a launch, so the page never offers or
    /// stores a value the launch would then replace.
    public func accepts(_ value: ToolingJSONValue) -> Bool {
        switch (kind, value) {
        case (.integer(let minimum, let maximum, _), .integer(let number)):
            return number >= minimum && number <= maximum
        case (.choice(let options), .string(let text)):
            return options.contains { $0.value == text }
        case (.toggle, .bool):
            return true
        case (.multiSelect(let options), .array(let items)):
            var seen = Set<String>()
            return items.allSatisfy { item in
                guard case .string(let text) = item,
                      options.contains(where: { $0.value == text })
                else { return false }
                return seen.insert(text).inserted
            }
        case (.text(let pattern, let maxLength, _), .string(let text)):
            return text.unicodeScalars.count <= maxLength
                && !text.hasPrefix("-")
                && Self.isPrintable(text)
                && Self.matchesWhole(text, pattern: pattern)
        case (.path, .string(let text)):
            return text.isEmpty
                || (Self.isAbsolutePath(text) && text.unicodeScalars.count <= 1024 && Self.isPrintable(text))
        default:
            return false
        }
    }

    /// The stored value when this declaration still accepts it, else the default.
    public func effectiveValue(stored: ToolingJSONValue?) -> ToolingJSONValue {
        if let stored, accepts(stored) { return stored }
        return defaultValue
    }

    /// Rust's `char::is_control`: general category Cc only, not format
    /// characters such as the zero-width joiner.
    private static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// `/…`, or `C:\…` / `C:/…`, as Rust Core accepts on every host.
    private static func isAbsolutePath(_ text: String) -> Bool {
        if text.hasPrefix("/") { return true }
        let bytes = Array(text.utf8.prefix(3))
        guard bytes.count == 3 else { return false }
        let isLetter = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0] | 0x20)
        return isLetter && bytes[1] == UInt8(ascii: ":")
            && (bytes[2] == UInt8(ascii: "\\") || bytes[2] == UInt8(ascii: "/"))
    }

    private static func matchesWhole(_ text: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}

/// A language a plugin declares.
public struct DeclarativePluginLanguage: Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A button a plugin adds to a settings page. The host draws it and invokes
/// the named plugin function of the same plugin; what it does is the
/// plugin's business.
public struct DeclarativePluginSettingAction: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String?
    public let page: DeclarativePluginSetting.Page?
    public let section: String?
    public let functionID: String
    public let requiresConfirmation: Bool

    public init(
        id: String,
        title: String,
        summary: String?,
        page: DeclarativePluginSetting.Page?,
        section: String?,
        functionID: String,
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.page = page
        self.section = section
        self.functionID = functionID
        self.requiresConfirmation = requiresConfirmation
    }
}

/// Which stored layer an effective setting value came from.
public enum PluginSettingSource: String, Equatable, Sendable {
    case `default`
    case global
    case project
}

/// The user's values for declarative plugin settings, kept once per plugin.
/// A plugin that is uninstalled and installed again finds its values again.
public protocol PluginSettingsStoring: Sendable {
    func values(forPlugin pluginID: String) -> [String: ToolingJSONValue]
    /// Stores `value`; `nil` forgets it so the declared default applies.
    func setValue(_ value: ToolingJSONValue?, forSetting settingID: String, plugin pluginID: String)
    /// Project-layer values, read from the project itself so they travel with it.
    func projectValues(forPlugin pluginID: String, projectRoot: URL) -> [String: ToolingJSONValue]
    /// Stores a project-layer value; `nil` removes the override.
    func setProjectValue(
        _ value: ToolingJSONValue?,
        forSetting settingID: String,
        plugin pluginID: String,
        projectRoot: URL
    ) throws
}

public extension PluginSettingsStoring {
    func projectValues(forPlugin pluginID: String, projectRoot: URL) -> [String: ToolingJSONValue] { [:] }
    func setProjectValue(
        _ value: ToolingJSONValue?,
        forSetting settingID: String,
        plugin pluginID: String,
        projectRoot: URL
    ) throws {}
}

/// Result of `plugins.declarative.languageServerLaunchPlan`. Rust Core only
/// joins text; the host creates the directories and checks the package paths.
public struct DeclarativeLanguageServerLaunchPlan: Equatable, Sendable {
    public enum RequiredDirectory: String, Sendable {
        case state
        case workspaceState
    }

    public struct RuntimeRequirement: Equatable, Sendable {
        public let tool: String
        public let minimumVersion: String?

        public init(tool: String, minimumVersion: String?) {
            self.tool = tool
            self.minimumVersion = minimumVersion
        }
    }

    /// Complete argument list after the executable.
    public let arguments: [String]
    public let validationArguments: [String]
    public let initializationOptions: ToolingJSONValue?
    /// What the server reads through `workspace/configuration`, expanded with
    /// the current settings; `nil` when the server declares none.
    public var workspaceConfiguration: ToolingJSONValue? = nil
    /// A declared host integration with its package-relative resource paths.
    public struct HostIntegration: Equatable, Sendable {
        public let id: String
        /// Resource name to one or more package-relative paths, in declared order.
        public let resources: [String: [String]]

        public init(id: String, resources: [String: [String]]) {
            self.id = id
            self.resources = resources
        }
    }

    /// Package-relative entry file of a runtime launch.
    public let entryPath: String?
    public let hostIntegration: HostIntegration?
    /// Package-relative path of the runtime the plugin ships, when it does.
    /// The host starts exactly this file instead of discovering the tool.
    public let packagedRuntimePath: String?
    /// Set for a discovered runtime that must meet a minimum version.
    public let executableVersionRequirement: LanguageServerExecutableVersionRequirement?
    public let runtimeRequirements: [RuntimeRequirement]
    public let requiredDirectories: [RequiredDirectory]
    /// Package-relative paths the launch points at.
    public let requiredPackagePaths: [String]
    /// The declared executable. Language servers resolve it from their
    /// descriptor instead; build providers use this.
    public let executable: Executable?
    /// Set when the plan was selected by build system.
    public let buildProvider: BuildProvider?
    /// Set when the plan was selected by VCS provider.
    public var vcsProvider: VcsProvider? = nil
    /// Set when the plan is the plugin's backend: the host services its
    /// permissions grant, passed to the session unchanged.
    public var backend: Backend? = nil

    public struct Backend: Equatable, Sendable {
        public let hostServices: [String]

        public init(hostServices: [String]) {
            self.hostServices = hostServices
        }
    }

    public enum Executable: Equatable, Sendable {
        /// Package-relative file.
        case packaged(String)
        /// Command names looked up on the machine, in order.
        case systemCommand([String])
        /// A runtime the host discovers; `packagedRuntimePath` replaces it
        /// when the plugin ships one.
        case runtime(String)
    }

    public struct BuildProvider: Equatable, Sendable {
        public let buildSystemID: String
        public let executesProjectCode: Bool
        public let mayUseNetwork: Bool
        /// The language whose server of the same plugin answers the build
        /// requests; nil when the provider is a process of its own.
        public let languageServer: String?

        public init(buildSystemID: String, executesProjectCode: Bool, mayUseNetwork: Bool, languageServer: String?) {
            self.buildSystemID = buildSystemID; self.executesProjectCode = executesProjectCode
            self.mayUseNetwork = mayUseNetwork; self.languageServer = languageServer
        }
    }

    /// What the host needs besides the process: the VCS the provider must
    /// negotiate and the client tool it resolves for every request.
    public struct VcsProvider: Equatable, Sendable {
        public let vcs: String
        /// Bare command names, resolved like a `systemCommand` launch.
        public let toolCommands: [String]
        public let toolValidationArguments: [String]
        public let mayUseNetwork: Bool

        public init(vcs: String, toolCommands: [String], toolValidationArguments: [String], mayUseNetwork: Bool) {
            self.vcs = vcs; self.toolCommands = toolCommands
            self.toolValidationArguments = toolValidationArguments; self.mayUseNetwork = mayUseNetwork
        }
    }

    public init(
        arguments: [String],
        validationArguments: [String] = [],
        initializationOptions: ToolingJSONValue? = nil,
        entryPath: String? = nil,
        hostIntegration: HostIntegration? = nil,
        packagedRuntimePath: String? = nil,
        executableVersionRequirement: LanguageServerExecutableVersionRequirement? = nil,
        runtimeRequirements: [RuntimeRequirement] = [],
        requiredDirectories: [RequiredDirectory] = [],
        requiredPackagePaths: [String] = [],
        executable: Executable? = nil,
        buildProvider: BuildProvider? = nil
    ) {
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.initializationOptions = initializationOptions
        self.entryPath = entryPath
        self.hostIntegration = hostIntegration
        self.packagedRuntimePath = packagedRuntimePath
        self.executableVersionRequirement = executableVersionRequirement
        self.runtimeRequirements = runtimeRequirements
        self.requiredDirectories = requiredDirectories
        self.requiredPackagePaths = requiredPackagePaths
        self.executable = executable
        self.buildProvider = buildProvider
    }
}

public struct DeclarativeExecutionProvider: Equatable, Sendable {
    public let languageID: String
    public let providesRun: Bool
    public let providesTest: Bool
}

/// API level 2 UI declarations. Host controls own rendering and activation.
public struct DeclarativeUIContributions: Equatable, Codable, Sendable {
    public struct ToolWindow: Equatable, Codable, Sendable {
        public let id: String
        public let title: String
        public let placement: String
        public let order: Int
        /// Core accepts exactly one of `text` and `web`.
        public let text: String?
        /// `ui` 2: a package HTML page shown inside the host-owned window shell.
        public let web: Web?
        public let native: PluginNativeUI?
        public let icon: PluginUIIcon?
    }
    public struct Web: Equatable, Codable, Sendable {
        /// Package-relative `.html` path that Core already checked for traversal.
        public let entry: String
    }
    public struct Command: Equatable, Codable, Sendable {
        public let id: String
        public let title: String
        public let toolWindowID: String
        public let order: Int
        public let placements: [ModuleContributionPlacement]
        public let icon: PluginUIIcon?
    }
    public let toolWindows: [ToolWindow]
    public let commands: [Command]

    public var contributions: [ModuleContribution] {
        toolWindows.map { window in
            ModuleContribution(
                id: window.id, kind: .toolWindow, title: window.title,
                placement: window.placement == "left" ? .leftSidebar : (window.placement == "right" ? .rightSidebar : .activityBar),
                order: window.order, actionID: window.id + ".toggle", rendererID: window.id,
                text: window.text, uiIcon: window.icon, webEntry: window.web?.entry, nativeUI: window.native
            )
        } + commands.flatMap { command in
            command.placements.map { placement in
                ModuleContribution(
                    id: command.id + "." + placement.rawValue, kind: .command,
                    title: command.title, placement: placement, order: command.order,
                    actionID: command.id, visibility: ["toolWindowID": command.toolWindowID], uiIcon: command.icon
                )
            }
        }
    }
}

/// A manifest accepted by `plugins.declarative.validate`, in the normalized
/// form Rust Core returned. Hosts never interpret command templates
/// themselves; they pass `normalizedManifest` back to Core to expand them.
public struct DeclarativePluginDescriptor: Equatable, Sendable {
    public let pluginManifest: PluginManifest
    public let languageServers: [DeclarativeLanguageServer]
    public let executionProviders: [DeclarativeExecutionProvider]
    public let buildSystems: [DeclarativeBuildSystem]
    /// VCS providers the plugin adds (`vcsProviders` capability).
    public let vcsProviders: [DeclarativeVcsProvider]
    public let settings: [DeclarativePluginSetting]
    /// Buttons the plugin adds to settings pages (settings capability 2).
    public let settingActions: [DeclarativePluginSettingAction]
    /// Languages the plugin declares, with their display names.
    public let languages: [DeclarativePluginLanguage]
    public let permissions: [String]
    public let activationEvents: [String]
    public let ui: DeclarativeUIContributions?
    /// Entries the plugin adds to the New Project window.
    public let projectGenerators: [DeclarativeProjectGenerator]
    /// Whether the plugin declares its own backend process (`backend` 1).
    public let declaresBackend: Bool
    public let normalizedManifest: Data

    public var id: PluginID { pluginManifest.id }

    /// - Parameter enabledByDefault: `true` for a package that ships inside
    ///   the application. It replaces a built-in feature, so it must work on
    ///   first launch; a downloaded plugin stays off until the user enables it.
    public init(normalizedManifest: Data, enabledByDefault: Bool = false) throws {
        let decoded = try JSONDecoder().decode(NormalizedManifest.self, from: normalizedManifest)
        guard let version = PluginVersion(decoded.version) else {
            throw DeclarativePluginRejection(
                code: "plugin.manifest.invalid",
                message: "The plugin version must use major.minor.patch.",
                field: "version"
            )
        }
        let displayNames = Dictionary(uniqueKeysWithValues: decoded.languages.map { ($0.id, $0.displayName) })
        languageServers = decoded.languageServers.map { server in
            DeclarativeLanguageServer(
                languageID: server.languageID,
                languageIdentifier: server.languageIdentifier ?? server.languageID,
                launch: Self.launch(server.launch),
                arguments: server.arguments,
                validationArguments: server.validationArguments,
                runtimeTools: server.runtimeDependencies.map(\.tool),
                expandsLaunchTemplates: decoded.pluginAPIVersion >= 2,
                hostIntegrationID: server.hostIntegration?.id
            )
        }
        executionProviders = decoded.executionProviders.map { provider in
            DeclarativeExecutionProvider(
                languageID: provider.languageID,
                providesRun: provider.run != nil,
                providesTest: provider.test != nil
            )
        }
        buildSystems = decoded.buildSystems.map { $0.declaration() }
        vcsProviders = decoded.vcsProviders.map { DeclarativeVcsProvider(id: $0.id, displayName: $0.displayName) }
        projectGenerators = decoded.projectGenerators.map {
            DeclarativeProjectGenerator(id: $0.id, displayName: $0.displayName, icon: $0.icon)
        }
        ui = decoded.ui
        declaresBackend = decoded.backend != nil
        settings = try decoded.settings.map { try $0.declaration() }
        settingActions = decoded.settingActions.map { $0.declaration() }
        languages = decoded.languages.map { DeclarativePluginLanguage(id: $0.id, displayName: $0.displayName) }
        permissions = decoded.permissions
        activationEvents = decoded.activationEvents
        self.normalizedManifest = normalizedManifest

        let serverLanguages = Set(languageServers.map(\.languageID))
        // Rust Core has already refused a capability the integration does not
        // provide, so a name unknown here comes from a newer contract and is
        // a feature this host cannot supply.
        let hostCapabilitiesByLanguage = Dictionary(
            decoded.languageServers.map { server in
                (
                    server.languageID,
                    Set((server.hostIntegration?.capabilities ?? []).compactMap {
                        LanguageHostCapability(rawValue: $0)
                    })
                )
            },
            uniquingKeysWith: { $0.union($1) }
        )
        let executionByLanguage = Dictionary(uniqueKeysWithValues: executionProviders.map { ($0.languageID, $0) })
        var modules = languageServers.map { server in
            PluginModuleDeclaration(manifest: LanguageExtensionModuleManifests.languageServer(
                languageID: server.languageID,
                displayName: displayNames[server.languageID] ?? server.languageID,
                enabledByDefault: enabledByDefault
            ))
        }
        modules += executionProviders.map { provider in
            PluginModuleDeclaration(manifest: LanguageExtensionModuleManifests.execution(
                languageID: provider.languageID,
                displayName: displayNames[provider.languageID] ?? provider.languageID
            ))
        }
        if !buildSystems.isEmpty {
            // One tool window per build system, enabled with the plugin.
            modules.append(PluginModuleDeclaration(
                manifest: LanguageExtensionModuleManifests.buildSystems(
                    pluginID: decoded.id,
                    displayName: decoded.displayName,
                    enabledByDefault: enabledByDefault
                ),
                contributions: buildSystems.enumerated().flatMap { index, buildSystem in
                    buildSystem.contributions(pluginID: decoded.id, order: index)
                }
            ))
        }
        if !vcsProviders.isEmpty {
            // One version-control window per provider, enabled with the
            // plugin. Root detection, launch, and replies belong to Rust Core.
            modules.append(PluginModuleDeclaration(
                manifest: LanguageExtensionModuleManifests.vcsProviders(
                    pluginID: decoded.id,
                    displayName: decoded.displayName,
                    enabledByDefault: enabledByDefault
                ),
                contributions: vcsProviders.enumerated().flatMap { index, provider in
                    provider.contributions(pluginID: decoded.id, order: index)
                }
            ))
        }
        if !projectGenerators.isEmpty {
            modules.append(PluginModuleDeclaration(
                manifest: LanguageExtensionModuleManifests.projectGenerators(
                    pluginID: decoded.id,
                    displayName: decoded.displayName,
                    enabledByDefault: enabledByDefault
                )
            ))
        }
        if let ui = decoded.ui {
            modules.append(PluginModuleDeclaration(
                manifest: ModuleManifest(
                    id: ModuleID(decoded.id + ".ui"), displayName: decoded.displayName,
                    scope: .workspace, activationPolicy: .onDemand
                ),
                contributions: ui.contributions
            ))
        }
        let languageSupports = decoded.languages.map { language in
            let execution = executionByLanguage[language.id]
            return LanguageSupportDeclaration(
                id: language.id,
                displayName: language.displayName,
                fileExtensions: language.fileExtensions,
                fileNames: language.fileNames,
                projectFileNames: language.projectFileNames,
                dependencies: language.dependencies.map {
                    LanguageDependencyDeclaration(
                        managementFileNames: $0.managementFileNames,
                        projectDependencyPaths: $0.projectDependencyPaths,
                        projectBinaryPaths: $0.projectBinaryPaths
                    )
                },
                languageServerModuleID: serverLanguages.contains(language.id)
                    ? .languageServerExtension(language.id)
                    : nil,
                // One execution module serves both run and test capabilities.
                executionModuleID: execution?.providesRun == true
                    ? .languageExecutionExtension(language.id)
                    : nil,
                testingModuleID: execution?.providesTest == true
                    ? .languageExecutionExtension(language.id)
                    : nil,
                hostCapabilities: hostCapabilitiesByLanguage[language.id] ?? []
            )
        }
        pluginManifest = PluginManifest(
            schemaVersion: PluginManifest.declarativeSchemaVersion,
            id: PluginID(decoded.id),
            displayName: decoded.displayName,
            version: version,
            apiVersion: decoded.pluginAPIVersion,
            // Unused for declarative packages: compatibility is decided by the
            // plugin API level, never by the Lithe application version.
            hostCompatibility: PluginHostCompatibility(minimum: PluginVersion(major: 0, minor: 0, patch: 0)),
            vendor: PluginVendor(
                id: decoded.vendor.id,
                displayName: decoded.vendor.displayName,
                signatureRequirement: decoded.vendor.signatureRequirement
            ),
            entrypoint: .declarative,
            modules: modules,
            languageSupports: languageSupports
        )
    }

    private static func launch(_ launch: NormalizedManifest.Launch) -> DeclarativeLanguageServer.Launch {
        switch launch.kind {
        case "packaged":
            .packaged(relativePath: launch.path ?? "")
        case "runtime":
            .runtime(
                tool: launch.tool ?? "",
                entryRelativePath: launch.entry ?? "",
                packagedRuntime: launch.packagedRuntime
            )
        default:
            .systemCommand(launch.commands ?? [])
        }
    }

    /// Mirrors the manifest fields the host needs. Optional lists default to
    /// empty so the same decoder reads Rust Core's normalized output and an
    /// unnormalized `plugin.json` in packaging checks.
    private struct NormalizedManifest: Decodable {
        struct Vendor: Decodable {
            let id: String
            let displayName: String
            let signatureRequirement: PluginSignatureRequirement
        }
        struct Dependencies: Decodable {
            let managementFileNames: [String]
            let projectDependencyPaths: [String]
            let projectBinaryPaths: [String]

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                managementFileNames = try values.decodeIfPresent([String].self, forKey: .managementFileNames) ?? []
                projectDependencyPaths = try values.decodeIfPresent([String].self, forKey: .projectDependencyPaths) ?? []
                projectBinaryPaths = try values.decodeIfPresent([String].self, forKey: .projectBinaryPaths) ?? []
            }

            private enum CodingKeys: String, CodingKey {
                case managementFileNames, projectDependencyPaths, projectBinaryPaths
            }
        }
        struct Language: Decodable {
            let id: String
            let displayName: String
            let fileExtensions: [String]
            let fileNames: [String]
            let projectFileNames: [String]
            let dependencies: Dependencies?

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                displayName = try values.decode(String.self, forKey: .displayName)
                fileExtensions = try values.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
                fileNames = try values.decodeIfPresent([String].self, forKey: .fileNames) ?? []
                projectFileNames = try values.decodeIfPresent([String].self, forKey: .projectFileNames) ?? []
                dependencies = try values.decodeIfPresent(Dependencies.self, forKey: .dependencies)
            }

            private enum CodingKeys: String, CodingKey {
                case id, displayName, fileExtensions, fileNames, projectFileNames, dependencies
            }
        }
        struct Launch: Decodable {
            let kind: String
            let path: String?
            let commands: [String]?
            let tool: String?
            let entry: String?
            let packagedRuntime: String?
        }
        struct RuntimeDependency: Decodable {
            let tool: String
        }
        struct HostIntegration: Decodable {
            let id: String
            let capabilities: [String]?
        }
        struct LanguageServer: Decodable {
            let languageID: String
            let languageIdentifier: String?
            let launch: Launch
            let arguments: [String]
            let validationArguments: [String]
            let runtimeDependencies: [RuntimeDependency]
            let hostIntegration: HostIntegration?

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                languageID = try values.decode(String.self, forKey: .languageID)
                languageIdentifier = try values.decodeIfPresent(String.self, forKey: .languageIdentifier)
                launch = try values.decode(Launch.self, forKey: .launch)
                arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
                validationArguments = try values.decodeIfPresent([String].self, forKey: .validationArguments) ?? []
                runtimeDependencies = try values.decodeIfPresent([RuntimeDependency].self, forKey: .runtimeDependencies) ?? []
                hostIntegration = try values.decodeIfPresent(HostIntegration.self, forKey: .hostIntegration)
            }

            private enum CodingKeys: String, CodingKey {
                case languageID, languageIdentifier, launch, arguments, validationArguments, runtimeDependencies
                case hostIntegration
            }
        }
        struct Setting: Decodable {
            struct Option: Decodable {
                let value: String
                let title: String
            }
            struct Page: Decodable {
                let languageID: String?
                let buildSystemID: String?

                var placement: DeclarativePluginSetting.Page? {
                    if let languageID { return .language(languageID) }
                    if let buildSystemID { return .buildSystem(buildSystemID) }
                    return nil
                }
            }

            let id: String
            let type: String
            let title: String
            let description: String?
            let `default`: ToolingJSONValue
            let minimum: Int?
            let maximum: Int?
            let unit: String?
            let options: [Option]?
            let scope: String?
            let effect: String?
            let page: Page?
            let section: String?
            let pattern: String?
            let maxLength: Int?
            let placeholder: String?

            /// Rust Core has already checked the declaration, so a shape that
            /// does not fit comes from a newer contract this host cannot show.
            func declaration() throws -> DeclarativePluginSetting {
                let kind: DeclarativePluginSetting.Kind
                let options = (options ?? []).map { DeclarativePluginSetting.Option(value: $0.value, title: $0.title) }
                switch (type, minimum, maximum) {
                case ("integer", let minimum?, let maximum?):
                    kind = .integer(minimum: minimum, maximum: maximum, unit: unit)
                case ("enum", _, _):
                    kind = .choice(options)
                case ("boolean", _, _):
                    kind = .toggle
                case ("multiSelect", _, _):
                    kind = .multiSelect(options)
                case ("text", _, _) where pattern != nil:
                    kind = .text(pattern: pattern ?? "", maxLength: maxLength ?? 256, placeholder: placeholder)
                case ("file", _, _):
                    kind = .path(directory: false, placeholder: placeholder)
                case ("directory", _, _):
                    kind = .path(directory: true, placeholder: placeholder)
                default:
                    throw unsupported("The setting type \(type) is not supported by this version of Lithe.")
                }
                guard let scope = DeclarativePluginSetting.Scope(rawValue: scope ?? "global"),
                      let effect = DeclarativePluginSetting.Effect(rawValue: effect ?? "restart")
                else { throw unsupported("The setting scope or effect is not supported by this version of Lithe.") }
                let placement = page?.placement
                return DeclarativePluginSetting(
                    id: id,
                    title: title,
                    summary: description,
                    kind: kind,
                    defaultValue: `default`,
                    scope: scope,
                    effect: effect,
                    page: placement,
                    section: section
                )
            }

            private func unsupported(_ message: String) -> DeclarativePluginRejection {
                DeclarativePluginRejection(code: "plugin.manifest.invalid", message: message, field: "settings.\(id)")
            }
        }
        struct SettingAction: Decodable {
            let id: String
            let title: String
            let description: String?
            let page: Setting.Page?
            let section: String?
            let function: String
            let confirm: Bool?

            func declaration() -> DeclarativePluginSettingAction {
                DeclarativePluginSettingAction(
                    id: id,
                    title: title,
                    summary: description,
                    page: page?.placement,
                    section: section,
                    functionID: function,
                    requiresConfirmation: confirm ?? false
                )
            }
        }
        /// Templates stay opaque to the host; only their presence matters here.
        struct ExecutionProvider: Decodable {
            let languageID: String
            let run: JSONPresence?
            let test: JSONPresence?
        }
        struct JSONPresence: Decodable {
            init(from decoder: Decoder) throws {}
        }
        /// The parts of a VCS provider the host shows. Root detection,
        /// commands, and reply checks stay with Rust Core.
        struct VcsProvider: Decodable {
            let id: String
            let displayName: String
        }

        /// The parts of a build system the tool window lists. Detection,
        /// commands, and decoders stay with Rust Core.
        struct BuildSystem: Decodable {
            struct Source: Decodable {
                let source: String
                let scopes: [BuildScope]?
            }
            struct Task: Decodable {
                let id: String
                let displayName: String
                let group: BuildTaskGroup
                let scopes: [BuildScope]
                let fromModel: Bool
                let targetTags: [String]
                let requiresUserArguments: Bool
                let description: String?
                let category: [String]

                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    id = try values.decode(String.self, forKey: .id)
                    displayName = try values.decode(String.self, forKey: .displayName)
                    group = try values.decode(BuildTaskGroup.self, forKey: .group)
                    scopes = try values.decodeIfPresent([BuildScope].self, forKey: .scopes) ?? []
                    fromModel = try values.decodeIfPresent(Bool.self, forKey: .fromModel) ?? false
                    targetTags = try values.decodeIfPresent([String].self, forKey: .targetTags) ?? []
                    requiresUserArguments = try values.decodeIfPresent(Bool.self, forKey: .requiresUserArguments)
                        ?? false
                    description = try values.decodeIfPresent(String.self, forKey: .description)
                    category = try values.decodeIfPresent([String].self, forKey: .category) ?? []
                }

                private enum CodingKeys: String, CodingKey {
                    case id, displayName, group, scopes, fromModel, targetTags, requiresUserArguments, description
                    case category
                }
            }
            /// Only where the window offers the option; Core resolves the rest.
            struct Option: Decodable {
                let id: String
                let presentation: String?
                let icon: PluginUIIcon?
            }
            struct Test: Decodable {
                let scopes: [BuildScope]
                let targetTags: [String]?
                let discovery: Bool?
            }

            let id: String
            let displayName: String
            let icon: PluginUIIcon?
            let options: [Option]
            let model: Source?
            let tasks: [Task]
            let test: Test?
            let dependencies: Source?
            let declaresProvider: Bool

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                displayName = try values.decode(String.self, forKey: .displayName)
                icon = try values.decodeIfPresent(PluginUIIcon.self, forKey: .icon)
                options = try values.decodeIfPresent([Option].self, forKey: .options) ?? []
                model = try values.decodeIfPresent(Source.self, forKey: .model)
                tasks = try values.decodeIfPresent([Task].self, forKey: .tasks) ?? []
                test = try values.decodeIfPresent(Test.self, forKey: .test)
                dependencies = try values.decodeIfPresent(Source.self, forKey: .dependencies)
                declaresProvider = values.contains(.provider)
            }

            private enum CodingKeys: String, CodingKey {
                case id, displayName, icon, options, model, tasks, test, dependencies, provider
            }

            func declaration() -> DeclarativeBuildSystem {
                DeclarativeBuildSystem(
                    id: id,
                    displayName: displayName,
                    icon: icon,
                    modelSource: model.flatMap { DeclarativeBuildSystem.ModelSource(rawValue: $0.source) },
                    options: options.map {
                        .init(
                            id: $0.id,
                            presentation: $0.presentation.flatMap(DeclarativeBuildSystem.OptionPresentation.init),
                            icon: $0.icon
                        )
                    },
                    tasks: tasks.map {
                        .init(
                            id: $0.id, displayName: $0.displayName, group: $0.group, scopes: $0.scopes,
                            fromModel: $0.fromModel, targetTags: $0.targetTags,
                            requiresUserArguments: $0.requiresUserArguments, description: $0.description,
                            category: $0.category
                        )
                    },
                    testScopes: test?.scopes ?? [],
                    testTargetTags: test?.targetTags ?? [],
                    // A host integration lists the whole instance and each
                    // project; the other sources declare their scopes.
                    dependencyScopes: dependencies.map { $0.scopes ?? [.workspace, .project] } ?? [],
                    declaresProvider: declaresProvider,
                    testDiscovery: test?.discovery ?? false
                )
            }
        }

        let id: String
        let displayName: String
        let version: String
        let pluginAPIVersion: Int
        let vendor: Vendor
        let permissions: [String]
        let activationEvents: [String]
        let languages: [Language]
        let languageServers: [LanguageServer]
        let executionProviders: [ExecutionProvider]
        let buildSystems: [BuildSystem]
        let vcsProviders: [VcsProvider]
        let ui: DeclarativeUIContributions?
        let settings: [Setting]
        let settingActions: [SettingAction]
        let projectGenerators: [ProjectGenerator]
        /// Launch fields stay with Rust Core; the host only needs to know
        /// a backend exists.
        let backend: ToolingJSONValue?

        /// What plugin management lists. Fields and steps stay with Rust Core,
        /// which evaluates the New Project form and plans every step.
        struct ProjectGenerator: Decodable {
            let id: String
            let displayName: String
            let icon: PluginUIIcon?
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            displayName = try values.decode(String.self, forKey: .displayName)
            version = try values.decode(String.self, forKey: .version)
            pluginAPIVersion = try values.decode(Int.self, forKey: .pluginAPIVersion)
            vendor = try values.decode(Vendor.self, forKey: .vendor)
            permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
            activationEvents = try values.decodeIfPresent([String].self, forKey: .activationEvents) ?? []
            languages = try values.decodeIfPresent([Language].self, forKey: .languages) ?? []
            ui = try values.decodeIfPresent(DeclarativeUIContributions.self, forKey: .ui)
            languageServers = try values.decodeIfPresent([LanguageServer].self, forKey: .languageServers) ?? []
            executionProviders = try values.decodeIfPresent([ExecutionProvider].self, forKey: .executionProviders) ?? []
            buildSystems = try values.decodeIfPresent([BuildSystem].self, forKey: .buildSystems) ?? []
            vcsProviders = try values.decodeIfPresent([VcsProvider].self, forKey: .vcsProviders) ?? []
            settings = try values.decodeIfPresent([Setting].self, forKey: .settings) ?? []
            settingActions = try values.decodeIfPresent([SettingAction].self, forKey: .settingActions) ?? []
            projectGenerators = try values.decodeIfPresent([ProjectGenerator].self, forKey: .projectGenerators) ?? []
            backend = try values.decodeIfPresent(ToolingJSONValue.self, forKey: .backend)
        }

        private enum CodingKeys: String, CodingKey {
            case id, displayName, version, pluginAPIVersion, vendor, permissions, activationEvents
            case languages, languageServers, executionProviders, buildSystems, vcsProviders, ui, settings, settingActions
            case projectGenerators, backend
        }
    }
}

/// One entry of the New Project window, as plugin management lists it.
public struct DeclarativeProjectGenerator: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let icon: PluginUIIcon?

    public init(id: String, displayName: String, icon: PluginUIIcon?) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
    }

    /// Key of the generator's icon among the plugin icon resources.
    public static func iconID(pluginID: String, generatorID: String) -> String {
        "\(pluginID).project-generator.\(generatorID)"
    }
}

/// Validates `plugin.json` contents through the shared contract implementation.
public protocol DeclarativePluginManifestValidating: Sendable {
    /// Throws `DeclarativePluginRejection` for a refused manifest.
    func validate(manifest: Data) throws -> DeclarativePluginDescriptor
}

/// Expands a declarative plugin's run and test templates. Implementations
/// throw `DeclarativePluginRejection`, translated with `runError` /
/// `testError(languageID:)` where an existing workflow error applies.
public protocol DeclarativeExecutionPlanning: Sendable {
    func runPlan(
        manifest: Data,
        languageID: String,
        request: LanguageRunExtensionRequest
    ) throws -> LanguageRunExtensionPlan

    func discoverTests(
        manifest: Data,
        languageID: String,
        request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem]

    func testPlan(
        manifest: Data,
        languageID: String,
        request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan
}

/// Expands a declarative language server's launch declaration. Implementations
/// throw `DeclarativePluginRejection`.
/// One declared setting's effective value and the layer it came from, as
/// Rust Core resolves it for launches.
public struct ResolvedPluginSetting: Equatable, Sendable {
    public let id: String
    public let value: ToolingJSONValue
    public let source: PluginSettingSource

    public init(id: String, value: ToolingJSONValue, source: PluginSettingSource) {
        self.id = id
        self.value = value
        self.source = source
    }
}

/// Rust Core's view of plugin settings: the values a launch would use and the
/// workspace configuration an `immediate` change sends to a running server.
public protocol DeclarativePluginSettingsResolving: Sendable {
    func resolveSettings(
        manifest: Data,
        settings: [String: ToolingJSONValue],
        projectSettings: [String: ToolingJSONValue]
    ) throws -> [ResolvedPluginSetting]
    func workspaceConfiguration(
        manifest: Data,
        languageID: String,
        settings: [String: ToolingJSONValue],
        projectSettings: [String: ToolingJSONValue]
    ) throws -> ToolingJSONValue?
}

public protocol DeclarativeLanguageServerLaunchPlanning: Sendable {
    func languageServerLaunchPlan(
        manifest: Data,
        languageID: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan
    /// The launch plan of a build system's provider. A provider that shares
    /// a language server gets that server's plan with
    /// `buildProvider.languageServer` set.
    func buildProviderLaunchPlan(
        manifest: Data,
        buildSystemID: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan
    /// The launch plan of a VCS provider, with `vcsProvider` set.
    func vcsProviderLaunchPlan(
        manifest: Data,
        vcs: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan
    /// The launch plan of the plugin's backend, with `backend` set.
    func backendLaunchPlan(
        manifest: Data,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan
}

public extension DeclarativeLanguageServerLaunchPlanning {
    func buildProviderLaunchPlan(
        manifest _: Data,
        buildSystemID _: String,
        request _: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        throw DeclarativePluginRejection(
            code: "plugin.launch.unavailable",
            message: "This host cannot plan build provider launches."
        )
    }

    func vcsProviderLaunchPlan(
        manifest _: Data,
        vcs _: String,
        request _: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        throw DeclarativePluginRejection(
            code: "plugin.launch.unavailable",
            message: "This host cannot plan VCS provider launches."
        )
    }

    func backendLaunchPlan(
        manifest _: Data,
        request _: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        throw DeclarativePluginRejection(
            code: "plugin.launch.unavailable",
            message: "This host cannot plan plugin backend launches."
        )
    }
}

/// Reads a launch runtime's version from its probe output and compares it
/// with the declared minimum. Implementations throw `DeclarativePluginRejection`.
public protocol LanguageServerRuntimeVersionChecking: Sendable {
    func checkRuntimeVersion(
        _ requirement: LanguageServerExecutableVersionRequirement,
        output: String
    ) throws -> LanguageServerRuntimeVersionCheck
}
