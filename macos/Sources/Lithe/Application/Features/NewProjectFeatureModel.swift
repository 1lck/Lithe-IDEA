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

    private let environment: NewProjectEnvironment
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
        evaluate()
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
        return entry.pluginEnabled && formState?.valid == true
    }

    private var parentURL: URL {
        let path = (location.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func input(for entry: ProjectGeneratorEntry) -> ProjectGeneratorFormInput {
        var input = inputs[entry.id] ?? ProjectGeneratorFormInput(projectName: projectName)
        input.projectName = projectName
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
