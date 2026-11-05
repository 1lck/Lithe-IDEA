import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// What the New Project window needs from the rest of the application.
struct NewProjectEnvironment {
    /// Every installed plugin with its enabled state, read on each reload so
    /// a plugin enabled from the window takes effect at once.
    let sources: @MainActor () -> [ProjectGeneratorPluginSource]
    let iconResources: [String: PluginUIIconResources]
    /// Discovered JDKs, best first; the window may run without a project.
    let javaRuntimes: @MainActor () async -> [JavaRuntimeCandidate]
    let service: ProjectGenerationService
    let setPluginEnabled: @MainActor (PluginID) async throws -> Void
    /// Opens plugin management on the marketplace with a search.
    let openMarketplace: @MainActor (String) -> Void
    let openProject: @MainActor (CreatedProject) -> Void
    let store: any KeyValueStore
    /// Installations of the tools `tool` fields pick, by tool definition ID and
    /// best first. A new project has no workspace yet, so this is the
    /// machine-wide discovery; a tool nothing defines is simply absent. Throws
    /// when discovery could not run, which is not the same as nothing found.
    var toolInstallations: @MainActor ([String]) async throws -> [String: [ProjectToolInstallation]] = { _ in [:] }
    /// Fires after the installed plugins or their enablement changed, so the
    /// entry list follows an install, update, or removal without reopening.
    var pluginChanges: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher()
}

/// State of the New Project window: the entry list, the host-owned name,
/// location, and Git fields, and the selected generator's form as Rust Core
/// evaluates it. No code here depends on which generator is selected.
@MainActor
final class NewProjectFeatureModel: ObservableObject {
    enum Selection: Hashable {
        /// The host's own empty project.
        case empty
        case generator(String)
    }

    /// A requirement of the selected generator the user should act on.
    struct RequirementNotice: Equatable, Identifiable {
        enum Action: Equatable {
            /// The first installed provider is disabled.
            case enable(PluginID, name: String)
            /// No installed plugin provides it.
            case findInMarketplace(String)
        }

        let subject: ProjectGeneratorRequirement.Subject
        let action: Action

        var id: String {
            switch subject {
            case .language(let id): "language:\(id)"
            case .buildSystem(let id): "buildSystem:\(id)"
            }
        }
    }

    static let locationKey = "lithe.newProject.location"
    static let createGitKey = "lithe.newProject.createGitRepository"
    static let defaultLocation = "~/LitheProjects"

    @Published private(set) var entries: [ProjectGeneratorEntry] = []
    var isJavaSupportMissing: Bool {
        !sources.contains { $0.pluginID == OfficialPluginCatalog.javaPluginID }
    }
    @Published private(set) var catalogError: String?
    @Published var selection: Selection = .empty {
        didSet { if oldValue != selection { selectionChanged() } }
    }
    @Published var searchText = ""
    @Published var projectName = "untitled" {
        didSet { if oldValue != projectName { evaluate() } }
    }
    @Published var location: String {
        didSet { environment.store.set(location, forKey: Self.locationKey) }
    }
    @Published var createGitRepository: Bool {
        didSet { environment.store.set(createGitRepository, forKey: Self.createGitKey) }
    }
    @Published var showsAdvancedFields = false
    @Published private(set) var formState: ProjectGeneratorFormState?
    @Published private(set) var nameProblem: ProjectFieldProblem?
    @Published private(set) var formError: String?
    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate] = []
    /// Set once JDK discovery finished, so an empty list reads as "none
    /// installed" rather than "still looking".
    @Published private(set) var hasLoadedJavaRuntimes = false
    @Published private(set) var isCreating = false
    @Published private(set) var progressOutput = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var enablingPluginID: PluginID?
    /// True from the moment tool installations are requested until they arrive,
    /// so an empty list reads as "none installed" rather than "still looking".
    @Published private(set) var isListingTools = false
    /// Why the installations of a tool could not be looked up, by tool
    /// definition ID. Such a tool has no listing, so Create stays disabled.
    @Published private(set) var toolListingFailures: [String: String] = [:]

    private let environment: NewProjectEnvironment
    /// Installations found per tool definition ID. A listing replaces the
    /// entries it asked for; the others keep their last answer until a plugin
    /// change drops them all. A tool with no entry has not been listed yet.
    private var listedTools: [String: [ProjectToolInstallation]] = [:]
    private var toolListing: Task<Void, Never>?
    private var pluginChangeObservation: AnyCancellable?
    /// Inputs per generator, so switching entries keeps what the user typed.
    private var inputs: [String: ProjectGeneratorFormInput] = [:]
    private var creation: Task<Void, Never>?
    /// Plugin sources as of the last catalog load. Reading them is not
    /// cheap (every plugin's management snapshot), so form evaluation on
    /// each keystroke reuses these; `reloadCatalog()` refreshes them.
    private var sources: [ProjectGeneratorPluginSource] = []

    init(environment: NewProjectEnvironment) {
        self.environment = environment
        location = environment.store.string(forKey: Self.locationKey) ?? Self.defaultLocation
        createGitRepository = environment.store.object(forKey: Self.createGitKey) as? Bool ?? false
        pluginChangeObservation = environment.pluginChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.reloadCatalog() }
            }
    }

    // MARK: Catalog

    /// Loads the entries and JDKs; called when the window appears.
    func load() async {
        reloadCatalog()
        if selection == .empty, let first = entries.first(where: { $0.generator.section == .project }) {
            selection = .generator(first.id)
        }
        javaRuntimes = await environment.javaRuntimes()
        hasLoadedJavaRuntimes = true
        evaluate()
    }

    func reloadCatalog() {
        sources = environment.sources()
        do {
            let catalog = try environment.service.planner.catalog(sources)
            entries = catalog.generators
            catalogError = nil
        } catch let rejection as CoreRejection {
            entries = []
            catalogError = rejection.message
        } catch {
            entries = []
            catalogError = error.localizedDescription
        }
        if case .generator(let id) = selection, !entries.contains(where: { $0.id == id }) {
            selection = .empty
        }
        // A plugin change may add or remove the definition of any tool, not
        // only the selected entry's, so every listing is dropped: an entry
        // selected later is looked up again instead of offering a home the
        // removed definition found.
        listedTools = [:]
        toolListingFailures = [:]
        evaluate()
        listToolInstallations()
    }

    var selectedEntry: ProjectGeneratorEntry? {
        guard case .generator(let id) = selection else { return nil }
        return entries.first { $0.id == id }
    }

    func entries(in section: ProjectGeneratorSection) -> [ProjectGeneratorEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            $0.generator.section == section
                && (query.isEmpty || $0.generator.displayName.localizedCaseInsensitiveContains(query))
        }
    }

    var showsEmptyProject: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || L10n.string("Empty Project").localizedCaseInsensitiveContains(query)
    }

    func icon(for entry: ProjectGeneratorEntry) -> PluginUIIconResources? {
        environment.iconResources[entry.iconID]
    }

    // MARK: Form

    /// Fields the window shows, in declaration order.
    func visibleFields(advanced: Bool) -> [ProjectGeneratorField] {
        guard let entry = selectedEntry else { return [] }
        return entry.generator.fields.filter { field in
            field.advanced == advanced && formState?.field(field.id)?.visible != false
        }
    }

    func value(of field: ProjectGeneratorField) -> ToolingJSONValue {
        formState?.field(field.id)?.value ?? .null
    }

    func problem(of field: ProjectGeneratorField) -> ProjectFieldProblem? {
        formState?.field(field.id)?.problem
    }

    func setValue(_ value: ToolingJSONValue, for field: ProjectGeneratorField) {
        guard let entry = selectedEntry else { return }
        var input = input(for: entry)
        input.values[field.id] = value
        if field.kind == .text { input.edited.insert(field.id) }
        inputs[entry.id] = input
        evaluate()
    }

    /// The JDK chosen for a runtime field, by home path.
    func selectedRuntimeHome(for field: ProjectGeneratorField) -> String {
        guard let entry = selectedEntry else { return "" }
        return input(for: entry).runtimes[field.id]?.home ?? ""
    }

    func selectRuntime(home: String, for field: ProjectGeneratorField) {
        guard let entry = selectedEntry,
              let runtime = javaRuntimes.first(where: { $0.homePath == home }) else { return }
        var input = input(for: entry)
        input.runtimes[field.id] = ProjectRuntimeSelection(home: runtime.homePath, version: runtime.version)
        inputs[entry.id] = input
        evaluate()
    }

    /// Requirements of the selected generator that no enabled plugin meets.
    var requirementNotices: [RequirementNotice] {
        guard let entry = selectedEntry, let state = formState else { return [] }
        return state.activeRequirements.compactMap { index -> RequirementNotice? in
            guard entry.requirements.indices.contains(index) else { return nil }
            let requirement = entry.requirements[index]
            guard !requirement.providers.contains(where: \.enabled) else { return nil }
            // A plugin that provides what its own templates need is covered
            // by the notice that offers to enable the template's plugin.
            guard !requirement.providers.contains(where: { $0.pluginID == entry.pluginID }) else { return nil }
            if let provider = requirement.providers.first {
                return RequirementNotice(
                    subject: requirement.subject,
                    action: .enable(PluginID(provider.pluginID), name: provider.pluginName)
                )
            }
            return RequirementNotice(subject: requirement.subject, action: .findInMarketplace(requirement.subjectID))
        }
    }

    var destinationPath: String {
        (parentURL.appendingPathComponent(projectName).path as NSString).abbreviatingWithTildeInPath
    }

    var canCreate: Bool {
        guard !isCreating, nameProblem == nil, formError == nil,
              !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let entry = selectedEntry else { return selection == .empty }
        // Until its tools are listed the form has judged an empty list, so an
        // optional tool would read as "none" and be left out of the project.
        return entry.pluginEnabled && formState?.valid == true
            && toolIDs(of: entry).allSatisfy { listedTools[$0] != nil }
    }

    private var parentURL: URL {
        let path = (location.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func input(for entry: ProjectGeneratorEntry) -> ProjectGeneratorFormInput {
        var input = inputs[entry.id] ?? ProjectGeneratorFormInput(projectName: projectName)
        input.projectName = projectName
        // Core accepts only installations the host listed, so each tool field
        // is sent what was found for its tool.
        for field in entry.generator.fields where field.kind == .tool {
            input.tools[field.id] = field.tool.flatMap { listedTools[$0] } ?? []
        }
        // Every runtime field starts on the best JDK the generator accepts.
        for field in entry.generator.fields where field.kind == .runtime && input.runtimes[field.id] == nil {
            if let runtime = Self.preferredRuntime(javaRuntimes, minimum: field.minimumVersion) {
                input.runtimes[field.id] = ProjectRuntimeSelection(home: runtime.homePath, version: runtime.version)
            }
        }
        return input
    }

    static func preferredRuntime(_ runtimes: [JavaRuntimeCandidate], minimum: String?) -> JavaRuntimeCandidate? {
        let minimumMajor = minimum.flatMap { Int($0.split(separator: ".").first ?? "") } ?? 0
        return runtimes
            .filter { ($0.majorVersion ?? 0) >= minimumMajor }
            .max { ($0.majorVersion ?? 0) < ($1.majorVersion ?? 0) }
            ?? runtimes.first
    }

    private func selectionChanged() {
        errorMessage = nil
        showsAdvancedFields = false
        evaluate()
        // Tools another generator already needed are not looked up again.
        if toolIDs(of: selectedEntry).contains(where: { listedTools[$0] == nil }) {
            listToolInstallations()
        }
    }

    /// Asks Rust Core for the form after every change.
    func evaluate() {
        do {
            nameProblem = try environment.service.planner.nameProblem(projectName)
        } catch {
            nameProblem = .invalidFormat
        }
        guard let entry = selectedEntry, let target = target(for: entry) else {
            formState = nil
            formError = nil
            return
        }
        let input = input(for: entry)
        inputs[entry.id] = input
        do {
            let state = try environment.service.planner.form(target, input: input)
            formState = state
            formError = nil
            // A problem in a collapsed section would leave Create disabled
            // with no visible reason (a project name with a space makes the
            // derived ArtifactId invalid), so the section opens.
            let advancedIDs = Set(entry.generator.fields.filter(\.advanced).map(\.id))
            if state.fields.contains(where: { advancedIDs.contains($0.id) && $0.visible && $0.problem != nil }) {
                showsAdvancedFields = true
            }
        } catch let rejection as CoreRejection {
            formState = nil
            formError = rejection.message
        } catch {
            formState = nil
            formError = error.localizedDescription
        }
    }

    private func target(for entry: ProjectGeneratorEntry) -> ProjectGeneratorTarget? {
        guard let source = sources.first(where: { $0.pluginID.rawValue == entry.pluginID }) else {
            return nil
        }
        return ProjectGeneratorTarget(
            pluginID: source.pluginID,
            generatorID: entry.generator.id,
            manifest: source.manifest,
            packageURL: source.packageURL
        )
    }

    // MARK: Tool fields

    /// The installations a tool field offers, with Core's verdict on each.
    func toolChoices(for field: ProjectGeneratorField) -> [ProjectGeneratorFormState.ToolChoice] {
        formState?.field(field.id)?.installations ?? []
    }

    /// The homes a tool field's picker lists. Core leaves an optional field
    /// empty when every installation is too old, so "" comes first then and
    /// the picker shows that rather than a blank control.
    func toolOptions(for field: ProjectGeneratorField) -> [String] {
        let homes = toolChoices(for: field).map(\.home)
        guard case .string(let chosen) = value(of: field), !chosen.isEmpty else { return [""] + homes }
        return homes
    }

    /// Whether the picker lets the user choose `home`: "no tool" and the
    /// installations Core says are new enough. An older one stays listed so the
    /// user sees why it is not used.
    func isToolChoosable(_ home: String, for field: ProjectGeneratorField) -> Bool {
        home.isEmpty || toolChoices(for: field).first { $0.home == home }?.meetsMinimum == true
    }

    /// What to offer when a tool field found no installation because no enabled
    /// plugin defines its tool: enable the plugin that does, or look for one.
    /// Nil while listing, when installations exist, and when the defining
    /// plugin is already enabled (the tool is then just not installed).
    func toolNoticeAction(for field: ProjectGeneratorField) -> RequirementNotice.Action? {
        guard !isListingTools, toolListingError(for: field) == nil, toolChoices(for: field).isEmpty,
              let tool = selectedEntry?.tools.first(where: { $0.fieldID == field.id }),
              !tool.providers.contains(where: \.enabled) else { return nil }
        if let provider = tool.providers.first {
            return .enable(PluginID(provider.pluginID), name: provider.pluginName)
        }
        // A third-party definition is `<pluginID>:<id>`; the plugin is what the
        // marketplace lists.
        let query = tool.tool.split(separator: ":").first.map(String.init) ?? tool.tool
        return .findInMarketplace(query)
    }

    /// The distinct tools the entry's tool fields pick, in declaration order.
    private func toolIDs(of entry: ProjectGeneratorEntry?) -> [String] {
        var seen = Set<String>()
        return (entry?.generator.fields ?? [])
            .filter { $0.kind == .tool }
            .compactMap(\.tool)
            .filter { seen.insert($0).inserted }
    }

    /// Why the installations of the field's tool could not be looked up, or
    /// nil when they were (or are still being) looked up.
    func toolListingError(for field: ProjectGeneratorField) -> String? {
        guard !isListingTools else { return nil }
        return field.tool.flatMap { toolListingFailures[$0] }
    }

    /// Looks the selected generator's tools up again after a failure.
    func retryToolListing() {
        listToolInstallations()
    }

    /// Looks up the installations of the selected generator's tools and
    /// re-evaluates the form with them. A newer request replaces an older one.
    private func listToolInstallations() {
        toolListing?.cancel()
        let tools = toolIDs(of: selectedEntry)
        guard !tools.isEmpty else {
            isListingTools = false
            return
        }
        isListingTools = true
        toolListing = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await environment.toolInstallations(tools)
                guard !Task.isCancelled else { return }
                for tool in tools {
                    listedTools[tool] = found[tool] ?? []
                    toolListingFailures[tool] = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The tools stay unlisted, so the field says the lookup failed
                // instead of "not installed", and Create waits for a retry.
                // A tool listed before keeps that listing.
                let message = String(
                    format: L10n.string("Could not look for installed tools: %@"), error.localizedDescription
                )
                for tool in tools where listedTools[tool] == nil { toolListingFailures[tool] = message }
            }
            isListingTools = false
            evaluate()
        }
    }

    // MARK: Actions

    func enablePlugin(_ pluginID: PluginID) async {
        enablingPluginID = pluginID
        defer { enablingPluginID = nil }
        do {
            try await environment.setPluginEnabled(pluginID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadCatalog()
    }

    func openMarketplace(searching query: String) {
        environment.openMarketplace(query)
    }

    func create(onCreated: @escaping @MainActor () -> Void) {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        progressOutput = ""
        let parent = parentURL
        let name = projectName
        let createGit = createGitRepository
        let service = environment.service
        let entry = selectedEntry
        let target = entry.flatMap(target(for:))
        let input = entry.map(input(for:))
        let relay = OutputRelay(model: self)
        creation = Task { [weak self] in
            do {
                let project: CreatedProject
                if let target, let input {
                    project = try await service.create(
                        target, input: input, in: parent, createGitRepository: createGit,
                        onOutput: { relay.deliver($0) }
                    )
                } else {
                    project = try await service.createEmptyProject(
                        named: name, in: parent, createGitRepository: createGit
                    )
                }
                guard let self else { return }
                self.isCreating = false
                self.environment.openProject(project)
                onCreated()
            } catch is CancellationError {
                self?.isCreating = false
            } catch {
                self?.isCreating = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelCreation() {
        creation?.cancel()
    }

    fileprivate func appendOutput(_ text: String) {
        progressOutput += text
        // Only the end is shown; keep memory bounded for chatty tools.
        if progressOutput.count > 20_000 {
            progressOutput = String(progressOutput.suffix(16_000))
        }
    }
}

/// Hands tool output from the process reader to the window on the main
/// actor without keeping the window's model alive.
private final class OutputRelay: @unchecked Sendable {
    private weak var model: NewProjectFeatureModel?

    @MainActor init(model: NewProjectFeatureModel) {
        self.model = model
    }

    func deliver(_ text: String) {
        Task { @MainActor [self] in model?.appendOutput(text) }
    }
}
