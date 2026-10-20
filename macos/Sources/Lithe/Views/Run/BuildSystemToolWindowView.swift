import LitheCoreContracts
import LitheExecutionModule
import SwiftUI

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

/// The tool window of one plugin build system, laid out like IDEA's Maven
/// and Gradle windows: a toolbar with run, refresh, and the plugin's toolbar
/// options; a tree with the plugin's tree options, then projects with their
/// tasks, tests, and dependencies. Everything comes from Rust Core through
/// `BuildSystemsFeatureModel`, and the build system's declaration decides
/// what is shown, so no build system is named here.
struct BuildSystemToolWindowView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: BuildSystemsFeatureModel
    let title: String
    let toolWindow: WorkbenchFeatureModel.ToolWindow
    let pluginID: String
    let buildSystemID: String
    let icons: BuildSystemToolWindowIcons
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var treeActive = false
    @State private var expandedNodeIDs: Set<String> = []
    @State private var knownRootNodeIDs: Set<String> = []
    @State private var selection: Selection?
    @State private var argumentsPrompt: ArgumentsPrompt?
    @State private var isOptionsPresented = false
    @State private var optionEntryID: String?
    @State private var customValueOptionID: String?
    @State private var customValue = ""

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: title, subtitle: nil) {
                LitheSidebarHideButton(title: title) {
                    model.workbenchFeature.setVisibility(toolWindow, isVisible: false)
                }
            }
            navigationToolbar
            if entries.count > 1, let optionEntry {
                LitheMenu {
                    for entry in entries {
                        LitheContextMenuItem.action(
                            Self.optionRootTitle(entry), localizesTitle: false,
                            checked: entry.id == optionEntry.id, leadingCheckmark: true,
                            initiallySelected: entry.id == optionEntry.id
                        ) {
                            optionEntryID = entry.id
                            customValueOptionID = nil
                            isOptionsPresented = false
                        }
                    }
                } label: {
                    HStack {
                        Text(verbatim: Self.optionRootTitle(optionEntry)).lineLimit(1)
                        Spacer(minLength: 4)
                        treeIcon("expui/general/chevronDown.svg")
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
                .accessibilityLabel(Text("Project options"))
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            }
            ForEach(feature.issues, id: \.self) { issue in
                LitheBanner(status: .warning, layout: .editor) {
                    Text(verbatim: issue).lineLimit(3).textSelection(.enabled)
                }
            }
            ForEach(entries) { entry in
                entryBanners(entry)
            }
            if entries.isEmpty {
                emptyState
            } else {
                treePane
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .workbenchHoverTooltipScope()
        .onAppear(perform: expandNewRoots)
        .onChange(of: rootNodeIDs) { _ in expandNewRoots() }
        .onChange(of: entries.map(\.model)) { _ in clearSelection(); resetOptionEditor() }
        .onChange(of: entries.map(\.id)) { _ in clearSelection(); resetOptionEditor() }
        .onChange(of: feature.workspaceURL) { _ in clearSelection(); optionEntryID = nil; resetOptionEditor() }
        .sheet(item: $argumentsPrompt) { prompt in
            BuildArgumentsSheet(prompt: prompt) { arguments in
                argumentsPrompt = nil
                run(.task(prompt.request.withUserArguments(arguments), title: prompt.title, needsArguments: false),
                    entryID: prompt.entryID)
            } onCancel: {
                argumentsPrompt = nil
            }
        }
    }

    private var entries: [BuildSystemEntry] {
        feature.entries.filter { $0.instance.pluginID == pluginID && $0.instance.buildSystemID == buildSystemID }
    }

    /// Storage is shared, but model choices and effective values belong to
    /// one instance. The root selector keeps every instance's options reachable.
    private var optionEntry: BuildSystemEntry? { Self.optionEntry(in: entries, selectedID: optionEntryID) }
    private var resolvedOptions: [BuildResolvedOption] { optionEntry?.options ?? [] }

    private var declaration: DeclarativeBuildSystem? { optionEntry?.declaration }

    static func optionEntry(in entries: [BuildSystemEntry], selectedID: String?) -> BuildSystemEntry? {
        entries.first { $0.id == selectedID } ?? entries.first
    }

    static func optionRootTitle(_ entry: BuildSystemEntry) -> String {
        entry.instance.root.isEmpty || entry.instance.root == "." ? entry.instance.displayName : entry.instance.root
    }

    private func resetOptionEditor() {
        customValueOptionID = nil
        isOptionsPresented = false
        if !entries.contains(where: { $0.id == optionEntryID }) { optionEntryID = nil }
    }

    // MARK: Toolbar

    // Community ActionToolbarImpl: 22pt surface + 1/2pt button insets + 5/7pt toolbar insets.
    private var navigationToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                toolbarButton(
                    help: feature.isRunning ? String(localized: "Stop build task") : String(localized: "Run selected task"),
                    isEnabled: feature.isRunning || selection != nil
                ) {
                    if feature.isRunning {
                        feature.stopRun()
                    } else if let selection {
                        run(selection.runnable, entryID: selection.entryID)
                    }
                } label: {
                    treeIcon(feature.isRunning ? "expui/run/stop.svg" : "expui/run/run.svg")
                }

                if let entry = selectedEntry, let task = argumentTasks.first(where: { argumentRequest($0, entry: entry) != nil }) {
                    toolbarButton(help: task.displayName, isEnabled: !feature.isRunning) {
                        if let request = argumentRequest(task, entry: entry) {
                            promptArguments(task, entry: entry, request: request)
                        }
                    } label: {
                        treeIcon("expui/general/runAnything.svg")
                    }
                }

                toolbarButton(help: String(format: String(localized: "Reload %@ projects"), title),
                              isEnabled: !feature.isDetecting, action: refresh) {
                    treeIcon("expui/general/refresh.svg")
                }

                ForEach(toolbarOptions, id: \.resolved.id) { option in
                    let isOn = option.resolved.value == .bool(true)
                    toolbarButton(help: option.resolved.displayName, isEnabled: true, isSelected: isOn) {
                        setOption(option.resolved.id, value: .bool(!isOn))
                    } label: {
                        if let asset = icons.option(option.declared) {
                            WorkbenchContributionIcon(asset: asset, role: .action)
                        } else {
                            treeIcon("expui/run/showIgnored.svg")
                        }
                    }
                    .accessibilityValue(isOn ? Text("On") : Text("Off"))
                }

                toolbarButton(help: String(localized: "Collapse all"), isEnabled: true) {
                    expandedNodeIDs.removeAll()
                } label: {
                    treeIcon("expui/general/collapseAll.svg")
                }

                if !listedOptions.isEmpty {
                    toolbarButton(help: String(format: String(localized: "%@ options"), title), isEnabled: true) {
                        isOptionsPresented.toggle()
                    } label: {
                        treeIcon("expui/general/settings.svg")
                    }
                    .litheDropdown(isPresented: $isOptionsPresented) { optionsPanel }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .frame(height: LitheTheme.Metrics.toolbarIconButtonSize + 12)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func toolbarButton<Label: View>(
        help: String,
        isEnabled: Bool,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action, label: label)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(Text(verbatim: help))
            .buttonStyle(LitheIconButtonStyle(
                size: LitheTheme.Metrics.toolbarIconButtonSize, cornerRadius: 4,
                isSelected: isSelected,
                hoverBackground: LitheTheme.toolbarHoverBackground,
                pressedBackground: LitheTheme.toolbarPressedBackground
            ))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .workbenchHoverHelp(Text(verbatim: help))
    }

    private struct PresentedOption {
        let declared: DeclarativeBuildSystem.Option
        let resolved: BuildResolvedOption
    }

    private func presentedOptions(_ presentation: DeclarativeBuildSystem.OptionPresentation, kind: BuildResolvedOption.Kind) -> [PresentedOption] {
        guard let declaration else { return [] }
        return resolvedOptions.compactMap { resolved in
            guard resolved.kind == kind, let declared = declaration.option(resolved.id),
                  declared.presentation == presentation else { return nil }
            return PresentedOption(declared: declared, resolved: resolved)
        }
    }

    private var toolbarOptions: [PresentedOption] { presentedOptions(.toolbar, kind: .boolean) }

    private var treeOptions: [PresentedOption] { presentedOptions(.tree, kind: .multiSelect) }

    /// Options without a toolbar or tree place, and placed options whose
    /// kind does not fit that place.
    private var listedOptions: [BuildResolvedOption] {
        let placed = Set((toolbarOptions + treeOptions).map(\.resolved.id))
        return resolvedOptions.filter { $0.kind != nil && !placed.contains($0.id) }
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: String(localized: "%@ options"), title))
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                .padding(.bottom, 4)
            ForEach(listedOptions) { option in
                let ownerID = optionEntry?.id
                BuildOptionRow(option: option, indent: 0) { value in
                    guard optionEntry?.id == ownerID else { return }
                    setOption(option.id, value: value)
                }
                .id((ownerID ?? "") + ":" + option.id)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func setOption(_ optionID: String, value: ToolingJSONValue?) {
        guard let entry = optionEntry else { return }
        feature.setInstanceOption(entry.id, optionID: optionID, value: value)
    }

    private func refresh() {
        if entries.isEmpty || entries.contains(where: { !$0.instance.loadsModelOnRequest }) {
            feature.detect()
        }
        for entry in entries where entry.instance.loadsModelOnRequest {
            feature.loadModel(entry.id)
        }
    }

    // MARK: Banners and empty state

    @ViewBuilder
    private func entryBanners(_ entry: BuildSystemEntry) -> some View {
        if case .failed(let message) = entry.modelState {
            LitheBanner(status: .error, layout: .editor) {
                Text(verbatim: message).lineLimit(3).textSelection(.enabled)
                Button("Retry") { reloadModel(entry) }
            }
        } else if entry.isReloadRequired {
            LitheBanner(status: .warning, layout: .editor) {
                Text(String(format: String(localized: "%@ build files changed"), entry.instance.displayName))
                Button("Reload") { feature.loadModel(entry.id) }
                    .disabled(entry.modelState == .loading)
            }
        }
        if entry.model?.truncated == true {
            LitheBanner(status: .warning, layout: .editor) {
                Text("The model is too large; some entries are not shown.")
            }
        }
    }

    private func reloadModel(_ entry: BuildSystemEntry) {
        if entry.instance.loadsModelOnRequest { feature.loadModel(entry.id) } else { feature.detect() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if feature.isDetecting {
                ProgressView().controlSize(.small)
                Text("Detecting build systems…")
            } else {
                Text(String(format: String(localized: "No %@ project was detected in this workspace."), title))
                    .multilineTextAlignment(.center)
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tree

    private var treePane: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(treeOptions, id: \.resolved.id) { option in
                    treeOptionNode(option.resolved)
                }
                ForEach(entries) { entry in
                    entryNode(entry)
                }
            }
            .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            .padding(.vertical, LitheTheme.Tree.verticalInset)
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .background(LitheToolWindowActivityTracker(isActive: $treeActive))
    }

    private func treeOptionNode(_ option: BuildResolvedOption) -> some View {
        let nodeID = "option:" + option.id
        let selected = Self.selectedValues(option.value)
        let choices = option.choices.map(\.value) + selected.filter { value in
            !option.choices.contains { $0.value == value }
        }
        return treeNode(id: nodeID, title: option.displayName, iconPath: "expui/nodes/folder.svg") {
            HStack(spacing: 4) {
                if option.allowCustom {
                    Button {
                        customValue = ""
                        customValueOptionID = option.id
                    } label: {
                        treeIcon("expui/general/add.svg").frame(width: 18, height: 20)
                    }
                    .buttonStyle(.litheNoPress)
                    .help(String(format: String(localized: "Add to %@"), option.displayName))
                    .litheDropdown(isPresented: Binding(
                        get: { customValueOptionID == option.id },
                        set: { if !$0 { customValueOptionID = nil } }
                    )) { customValuePanel(option, selected: selected) }
                }
                if option.source == "user" {
                    Button { setOption(option.id, value: nil) } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 18, height: 20)
                    }
                    .buttonStyle(.litheNoPress)
                    .help("Use the default value")
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.leading, 2)
            ForEach(choices, id: \.self) { value in
                Toggle(isOn: Binding(
                    get: { selected.contains(value) },
                    set: { isOn in
                        let next = isOn ? selected + [value] : selected.filter { $0 != value }
                        setOption(option.id, value: .array(next.map(ToolingJSONValue.string)))
                    }
                )) {
                    HStack(spacing: 0) {
                        Text(verbatim: option.choices.first { $0.value == value }?.title ?? value)
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .toggleStyle(.checkbox)
                .padding(.leading, LitheTheme.Tree.indent)
                .litheTreeRow()
            }
        }
    }

    private func customValuePanel(_ option: BuildResolvedOption, selected: [String]) -> some View {
        let ownerID = optionEntry?.id
        let add = {
            guard optionEntry?.id == ownerID else { return }
            let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            customValueOptionID = nil
            guard !selected.contains(value) else { return }
            setOption(option.id, value: .array((selected + [value]).map(ToolingJSONValue.string)))
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(String(format: String(localized: "Add to %@"), option.displayName))
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
            TextField("", text: $customValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel") { customValueOptionID = nil }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(customValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    /// A lone project at the instance root stands for the instance, as in
    /// IDEA; otherwise the instance node holds its root projects.
    private func rootProject(_ entry: BuildSystemEntry) -> BuildModel.Project? {
        guard let model = entry.model else { return nil }
        let roots = Self.rootProjects(model)
        guard roots.count == 1, roots[0].path == entry.instance.root else { return nil }
        return roots[0]
    }

    private var rootNodeIDs: Set<String> {
        Set(entries.map { entry in rootProject(entry).map { projectNodeID(entry, $0) } ?? "entry:" + entry.id })
            .union(treeOptions.map { "option:" + $0.resolved.id })
    }

    private func expandNewRoots() {
        let roots = rootNodeIDs
        expandedNodeIDs.formUnion(roots.subtracting(knownRootNodeIDs))
        knownRootNodeIDs = roots
    }

    @ViewBuilder
    private func entryNode(_ entry: BuildSystemEntry) -> some View {
        if let project = rootProject(entry), let buildModel = entry.model {
            projectNode(entry, model: buildModel, project: project, isRoot: true)
        } else {
            let nodeID = "entry:" + entry.id
            treeNode(
                id: nodeID,
                title: entry.instance.displayName,
                subtitle: entry.instance.root == "." ? nil : entry.instance.root,
                iconPath: nil,
                isLoading: entry.modelState == .loading,
                menu: { scopeMenu(entry, project: nil) }
            ) {
                scopeContent(entry, project: nil, ownerID: nodeID)
                if let buildModel = entry.model {
                    ForEach(Self.rootProjects(buildModel)) { project in
                        projectNode(entry, model: buildModel, project: project, isRoot: false)
                    }
                } else if entry.instance.loadsModelOnRequest, entry.modelState != .loading {
                    actionRow(title: String(localized: "Load Project Model"), iconPath: "expui/general/refresh.svg") {
                        feature.loadModel(entry.id)
                    }
                }
            }
        }
    }

    private func projectNode(
        _ entry: BuildSystemEntry,
        model buildModel: BuildModel,
        project: BuildModel.Project,
        isRoot: Bool
    ) -> AnyView {
        let nodeID = projectNodeID(entry, project)
        let children = buildModel.projects.filter { $0.parentID == project.id }
        return AnyView(treeNode(
            id: nodeID,
            title: project.displayName ?? project.name,
            subtitle: isRoot || project.path == entry.instance.root ? nil : project.path,
            iconPath: nil,
            isLoading: isRoot && entry.modelState == .loading,
            menu: { scopeMenu(entry, project: project, isRoot: isRoot) }
        ) {
            scopeContent(entry, project: project, isRoot: isRoot, ownerID: nodeID)
            ForEach(buildModel.targets.filter { $0.projectID == project.id }) { target in
                targetNode(entry, project: project, target: target)
            }
            ForEach(children) { child in
                projectNode(entry, model: buildModel, project: child, isRoot: false)
            }
        })
    }

    /// Tasks, tests, and dependencies of one node. The instance node, and a
    /// root project standing for it, run workspace-scoped work where the
    /// build system declares it, so a root build covers every project.
    @ViewBuilder
    private func scopeContent(
        _ entry: BuildSystemEntry,
        project: BuildModel.Project?,
        isRoot: Bool = false,
        ownerID: String
    ) -> some View {
        let items = taskItems(entry, project: project, isRoot: isRoot)
        categoryNodes(items, level: 0, ownerID: ownerID, entryID: entry.id)
        if let tests = testRunnable(entry, project: project, isRoot: isRoot) {
            leafRow(
                id: ownerID + ":tests", title: String(localized: "Run Tests"), help: nil,
                iconPath: "expui/nodes/testGroup.svg", entryID: entry.id, project: project, runnable: tests
            )
        }
        if let scope = dependencyScope(entry, project: project, isRoot: isRoot) {
            dependencyNode(entry, project: scope.project, ownerID: ownerID)
        }
    }

    private func targetNode(_ entry: BuildSystemEntry, project: BuildModel.Project, target: BuildModel.Target) -> some View {
        let nodeID = "target:" + entry.id + ":" + target.id
        let declaration = entry.declaration
        let tasks = declaration.tasks.filter {
            !$0.fromModel && $0.scopes.contains(.target) && Self.matches(target, tags: $0.targetTags)
        }
        let testable = declaration.testScopes.contains(.target) && Self.matches(target, tags: declaration.testTargetTags)
        return Group {
            if !tasks.isEmpty || testable {
                treeNode(
                    id: nodeID, title: target.name,
                    subtitle: target.tags.isEmpty ? nil : target.tags.joined(separator: ", "),
                    iconPath: "expui/nodes/runnableMark.svg"
                ) {
                    if testable {
                        leafRow(
                            id: nodeID + ":tests", title: String(localized: "Run Tests"), help: nil,
                            iconPath: "expui/nodes/testGroup.svg", entryID: entry.id, project: project,
                            runnable: .tests(
                                BuildTestRequest(project: BuildSelection(project: project), target: BuildSelection(target: target)),
                                title: Self.title(String(localized: "Tests"), scope: target.name)
                            ), target: target
                        )
                    }
                    ForEach(tasks) { task in
                        leafRow(
                            id: nodeID + ":" + task.id, title: task.displayName, help: task.description,
                            iconPath: "maven/task.svg", entryID: entry.id, project: project,
                            runnable: .task(
                                BuildTaskRequest(task: task.id, project: BuildSelection(project: project), target: BuildSelection(target: target)),
                                title: Self.title(task.displayName, scope: target.name), needsArguments: task.requiresUserArguments
                            ), target: target
                        )
                    }
                }
            }
        }
    }

    // MARK: Tasks

    private struct TaskItem: Identifiable {
        let id: String
        let title: String
        let help: String?
        let category: [String]
        let project: BuildModel.Project?
        let runnable: Runnable
    }

    /// Declared tasks of the node's scope and the model tasks of its project.
    /// Tasks that need arguments are offered from the toolbar and the menu.
    private func taskItems(_ entry: BuildSystemEntry, project: BuildModel.Project?, isRoot: Bool) -> [TaskItem] {
        let declaration = entry.declaration
        let scopeName = project.map { $0.displayName ?? $0.name } ?? entry.instance.displayName
        var items: [TaskItem] = declaration.tasks.compactMap { task in
            guard !task.fromModel, !task.requiresUserArguments else { return nil }
            let selection: BuildModel.Project?
            if project == nil || isRoot, task.scopes.contains(.workspace) {
                selection = nil
            } else if let project, task.scopes.contains(.project) {
                selection = project
            } else {
                return nil
            }
            return TaskItem(
                id: "declared:" + task.id, title: task.displayName, help: task.description,
                category: task.category.isEmpty ? [Self.groupTitle(task.group)] : task.category,
                project: selection,
                runnable: .task(
                    BuildTaskRequest(task: task.id, project: selection.map(BuildSelection.init(project:))),
                    title: Self.title(task.displayName, scope: scopeName), needsArguments: false
                )
            )
        }
        if let project, let buildModel = entry.model {
            for task in buildModel.tasks where task.projectID == project.id {
                let template = declaration.tasks.first { $0.id == task.template }
                let category = !task.category.isEmpty ? task.category
                    : template.map(\.category).flatMap { $0.isEmpty ? nil : $0 } ?? [Self.groupTitle(task.group)]
                let name = task.displayName ?? task.name
                items.append(TaskItem(
                    id: "model:" + task.id, title: name, help: task.description, category: category, project: project,
                    runnable: .task(
                        BuildTaskRequest(task: task.template, project: BuildSelection(project: project), modelTask: BuildSelection(task: task)),
                        title: Self.title(name, scope: scopeName),
                        needsArguments: template?.requiresUserArguments == true
                    )
                ))
            }
        }
        return items
    }

    /// Files tasks under their headings, outermost first, keeping the order
    /// in which each heading first appears.
    private func categoryNodes(_ items: [TaskItem], level: Int, ownerID: String, entryID: String) -> AnyView {
        var headings: [String] = []
        var grouped: [String: [TaskItem]] = [:]
        var leaves: [TaskItem] = []
        for item in items {
            guard level < item.category.count else { leaves.append(item); continue }
            let heading = item.category[level]
            if grouped[heading] == nil { headings.append(heading) }
            grouped[heading, default: []].append(item)
        }
        return AnyView(Group {
            ForEach(headings, id: \.self) { heading in
                let nodeID = ownerID + ":category:\(heading.utf8.count):" + heading
                treeNode(id: nodeID, title: heading, iconPath: "expui/build/taskGroup.svg") {
                    categoryNodes(grouped[heading] ?? [], level: level + 1, ownerID: nodeID, entryID: entryID)
                }
            }
            ForEach(leaves) { item in
                leafRow(
                    id: ownerID + ":" + item.id, title: item.title, help: item.help, iconPath: "maven/task.svg",
                    entryID: entryID, project: item.project, runnable: item.runnable
                )
            }
        })
    }

    private var argumentTasks: [DeclarativeBuildSystem.Task] {
        declaration?.tasks.filter { !$0.fromModel && $0.requiresUserArguments } ?? []
    }

    private var selectedEntry: BuildSystemEntry? {
        selection.flatMap { selection in entries.first { $0.id == selection.entryID } } ?? entries.first
    }

    private func argumentRequest(_ task: DeclarativeBuildSystem.Task, entry: BuildSystemEntry) -> BuildTaskRequest? {
        let project = selection?.project ?? rootProject(entry)
        return Self.argumentRequest(
            task, project: project, target: selection?.target,
            isRoot: project == rootProject(entry)
        )
    }

    /// Use the same scope rules for the toolbar and node menus. In particular,
    /// a project-only task at the root still needs that project selection.
    static func argumentRequest(
        _ task: DeclarativeBuildSystem.Task,
        project: BuildModel.Project?,
        target: BuildModel.Target? = nil,
        isRoot: Bool = false
    ) -> BuildTaskRequest? {
        if let target {
            guard let project, task.scopes.contains(.target), Self.matches(target, tags: task.targetTags) else { return nil }
            return BuildTaskRequest(task: task.id, project: BuildSelection(project: project), target: BuildSelection(target: target))
        }
        if (project == nil || isRoot) && task.scopes.contains(.workspace) {
            return BuildTaskRequest(task: task.id)
        }
        guard let project, task.scopes.contains(.project) else { return nil }
        return BuildTaskRequest(task: task.id, project: BuildSelection(project: project))
    }

    private func promptArguments(_ task: DeclarativeBuildSystem.Task, entry: BuildSystemEntry, request: BuildTaskRequest) {
        let scope = request.target?.name ?? request.project?.name ?? entry.instance.displayName
        argumentsPrompt = ArgumentsPrompt(entryID: entry.id, title: Self.title(task.displayName, scope: scope), request: request)
    }

    private func testRunnable(_ entry: BuildSystemEntry, project: BuildModel.Project?, isRoot: Bool) -> Runnable? {
        let scopes = entry.declaration.testScopes
        let selected: BuildModel.Project?
        if (project == nil || isRoot) && scopes.contains(.workspace) {
            selected = nil
        } else if let project, scopes.contains(.project) {
            selected = project
        } else {
            return nil
        }
        let scope = project.map { $0.displayName ?? $0.name } ?? entry.instance.displayName
        return .tests(
            BuildTestRequest(
                project: selected.map(BuildSelection.init(project:)),
                projects: entry.model?.projects.map(\.path) ?? []
            ),
            title: Self.title(String(localized: "Tests"), scope: scope)
        )
    }

    // MARK: Dependencies

    private struct DependencyScope { let project: BuildModel.Project? }

    private func dependencyScope(_ entry: BuildSystemEntry, project: BuildModel.Project?, isRoot: Bool) -> DependencyScope? {
        let scopes = entry.declaration.dependencyScopes
        if project == nil || isRoot, scopes.contains(.workspace) { return DependencyScope(project: nil) }
        if let project, scopes.contains(.project) { return DependencyScope(project: project) }
        return nil
    }

    private func dependencyNode(_ entry: BuildSystemEntry, project: BuildModel.Project?, ownerID: String) -> some View {
        let key = project?.path ?? entry.instance.root
        let nodeID = ownerID + ":dependencies"
        let toggle = {
            let shouldLoad = !expandedNodeIDs.contains(nodeID)
            toggleNode(nodeID)
            if shouldLoad, entry.dependencies[key] == nil || entry.dependencies[key].map(Self.isFailure) == true {
                feature.loadDependencies(entry.id, project: project)
            }
        }
        return treeNode(
            id: nodeID, title: String(localized: "Dependencies"), iconPath: "expui/nodes/libraryFolder.svg",
            onToggle: toggle,
            menu: {
                [.action("Reload", isEnabled: entry.dependencies[key] != .loading) {
                    feature.loadDependencies(entry.id, project: project)
                }]
            }
        ) {
            switch entry.dependencies[key] {
            case .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading dependencies…").lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
            case .failed(let message)?:
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.error)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Button("Retry") { feature.loadDependencies(entry.id, project: project) }
                        .buttonStyle(.litheNoPress)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            case .loaded(let tree)?:
                if tree.dependencies.isEmpty {
                    Text("No dependencies")
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 28)
                }
                ForEach(Array(tree.dependencies.enumerated()), id: \.offset) { index, node in
                    dependencyTreeNode(node, id: nodeID + "/\(index)")
                }
                if tree.truncated {
                    Text("Some dependencies are not shown.")
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.warning)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 28)
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func dependencyTreeNode(_ node: BuildDependencyNode, id: String) -> AnyView {
        let subtitle = [[node.group, node.version].compactMap { $0 }.joined(separator: ":"), node.scope ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !node.children.isEmpty else {
            return AnyView(HStack(spacing: LitheTheme.Tree.iconTextGap) {
                treeIcon("expui/nodes/library.svg")
                Text(verbatim: node.name).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle).foregroundStyle(LitheTheme.Tree.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, LitheTheme.Tree.indent)
            .litheTreeRow())
        }
        return AnyView(treeNode(id: id, title: node.name, subtitle: subtitle, iconPath: "expui/nodes/library.svg") {
            ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                dependencyTreeNode(child, id: id + "/\(index)")
            }
        })
    }

    // MARK: Menus

    @LitheMenuItemsBuilder
    private func scopeMenu(_ entry: BuildSystemEntry, project: BuildModel.Project?, isRoot: Bool = false) -> [LitheContextMenuItem] {
        if let tests = testRunnable(entry, project: project, isRoot: isRoot) {
            LitheContextMenuItem.action("Run Tests", isEnabled: !feature.isRunning) { run(tests, entryID: entry.id) }
        }
        for task in argumentTasks {
            if let request = Self.argumentRequest(task, project: project, isRoot: isRoot) {
                LitheContextMenuItem.action(
                    task.displayName + "…", localizesTitle: false, isEnabled: !feature.isRunning
                ) {
                    promptArguments(task, entry: entry, request: request)
                }
            }
        }
        if project == nil || isRoot, let workspaceURL = model.workspaceURL {
            LitheContextMenuItem.separator
            for marker in entry.instance.markers {
                LitheContextMenuItem.action(
                    String(format: String(localized: "Open %@"), (marker as NSString).lastPathComponent),
                    localizesTitle: false
                ) {
                    model.openFile(workspaceURL.appendingPathComponent(marker))
                }
            }
        }
        if project == nil || isRoot {
            LitheContextMenuItem.action(
                entry.instance.loadsModelOnRequest && entry.model == nil ? "Load Project Model" : "Reload",
                isEnabled: entry.modelState != .loading && !feature.isDetecting
            ) { reloadModel(entry) }
        }
    }

    // MARK: Rows

    private func treeIcon(_ path: String) -> some View {
        LitheIDEAIcon(resourcePath: path, size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
    }

    /// `iconPath` nil is a project: the build system's own icon.
    private func treeNode<Content: View>(
        id: String,
        title: String,
        subtitle: String? = nil,
        iconPath: String?,
        isLoading: Bool = false,
        onToggle: (() -> Void)? = nil,
        menu: @escaping () -> [LitheContextMenuItem] = { [] },
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let expanded = expandedNodeIDs.contains(id)
        let toggle = onToggle ?? { toggleNode(id) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                Button(action: toggle) {
                    treeIcon(expanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg")
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))

                Button(action: toggle) {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        if let iconPath {
                            treeIcon(iconPath)
                        } else {
                            WorkbenchContributionIcon(asset: icons.window, role: .action)
                                .frame(width: LitheTheme.Tree.iconSize, height: LitheTheme.Tree.iconSize)
                        }
                        Text(verbatim: title).lineLimit(1)
                        if let subtitle, !subtitle.isEmpty {
                            Text(verbatim: "(\(subtitle))").foregroundStyle(LitheTheme.Tree.secondaryText).lineLimit(1)
                        }
                        if isLoading {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
            }
            .litheTreeRow()
            .litheContextMenu(items: menu)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, LitheTheme.Tree.indent)
            }
        }
    }

    /// A runnable row: click selects it for the toolbar's run button,
    /// double-click runs it.
    private func leafRow(
        id: String,
        title: String,
        help: String?,
        iconPath: String,
        entryID: String,
        project: BuildModel.Project?,
        runnable: Runnable,
        target: BuildModel.Target? = nil
    ) -> some View {
        let isSelected = selection?.nodeID == id
        let perform = { run(runnable, entryID: entryID) }
        return Button {
            selection = Selection(nodeID: id, entryID: entryID, project: project, target: target, runnable: runnable)
        } label: {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                treeIcon(iconPath)
                Text(verbatim: title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, LitheTheme.Tree.indent)
            .litheTreeRow(isSelected: isSelected, isFocused: treeActive && controlActiveState == .key)
        }
        .buttonStyle(.litheNoPress)
        .help(help ?? title)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !feature.isRunning else { return }
            perform()
        })
        .litheContextMenu(items: {
            [.action("Run", isEnabled: !feature.isRunning, action: perform)]
        })
    }

    private func actionRow(title: String, iconPath: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                treeIcon(iconPath)
                Text(verbatim: title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, LitheTheme.Tree.indent)
            .litheTreeRow()
        }
        .buttonStyle(.litheNoPress)
    }

    // MARK: Running

    private enum Runnable: Equatable {
        case task(BuildTaskRequest, title: String, needsArguments: Bool)
        case tests(BuildTestRequest, title: String)
    }

    private struct Selection: Equatable {
        let nodeID: String
        let entryID: String
        let project: BuildModel.Project?
        let target: BuildModel.Target?
        let runnable: Runnable
    }

    /// A refreshed model or workspace must not leave a toolbar action holding
    /// selections from the previous tree, including an already open prompt.
    private func clearSelection() {
        selection = nil
        argumentsPrompt = nil
    }

    private func run(_ runnable: Runnable, entryID: String) {
        guard !feature.isRunning else { return }
        switch runnable {
        case .task(let request, let title, true):
            argumentsPrompt = ArgumentsPrompt(entryID: entryID, title: title, request: request)
            return
        case .task(let request, let title, false):
            feature.runTask(entryID, request: request, title: title)
        case .tests(let request, let title):
            feature.runTests(entryID, request: request, title: title)
        }
        model.showToolWindow(.buildOutput)
    }

    // MARK: Node IDs

    private func projectNodeID(_ entry: BuildSystemEntry, _ project: BuildModel.Project) -> String {
        "project:" + entry.id + "\u{1F}" + project.id
    }

    private func toggleNode(_ id: String) {
        if expandedNodeIDs.contains(id) { expandedNodeIDs.remove(id) } else { expandedNodeIDs.insert(id) }
    }

    // MARK: Helpers

    private static func rootProjects(_ model: BuildModel) -> [BuildModel.Project] {
        let ids = Set(model.projects.map(\.id))
        return model.projects.filter { $0.parentID.map { !ids.contains($0) } ?? true }
    }

    private static func matches(_ target: BuildModel.Target, tags: [String]) -> Bool {
        tags.isEmpty || target.tags.contains(where: tags.contains)
    }

    private static func isFailure(_ state: BuildDependencyState) -> Bool {
        if case .failed = state { true } else { false }
    }

    private static func selectedValues(_ value: ToolingJSONValue) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    private static func title(_ task: String, scope: String) -> String { "\(scope): \(task)" }

    static func groupTitle(_ group: BuildTaskGroup) -> String {
        switch group {
        case .lifecycle: String(localized: "Lifecycle")
        case .build: String(localized: "Build")
        case .test: String(localized: "Test")
        case .run: String(localized: "Run")
        case .verification: String(localized: "Verification")
        case .documentation: String(localized: "Documentation")
        case .other: String(localized: "Other")
        }
    }
}

/// A task that needs user arguments before it runs.
private struct ArgumentsPrompt: Identifiable {
    let id = UUID()
    let entryID: String
    let title: String
    let request: BuildTaskRequest
}

private extension BuildTaskRequest {
    func withUserArguments(_ arguments: [String]) -> BuildTaskRequest {
        BuildTaskRequest(task: task, project: project, target: target, modelTask: modelTask, userArguments: arguments)
    }
}

private struct BuildArgumentsSheet: View {
    let prompt: ArgumentsPrompt
    let onRun: ([String]) -> Void
    let onCancel: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.title)
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
            TextField("Arguments", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            Text("Separate arguments with spaces; quote an argument that contains spaces.")
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func run() {
        onRun(BuildArgumentSplitter.split(text))
    }
}

/// Splits an argument line on spaces, keeping quoted text together. No
/// shell runs it: the result is the argv Core appends.
enum BuildArgumentSplitter {
    static func split(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasArgument = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasArgument = true
            } else if character.isWhitespace {
                if hasArgument { arguments.append(current) }
                current = ""
                hasArgument = false
            } else {
                current.append(character)
                hasArgument = true
            }
        }
        if hasArgument { arguments.append(current) }
        return arguments
    }
}

/// Shared edit semantics for native option menus and text inputs. Custom
/// values remain ordinary Core inputs and clearing text remains an override.
enum BuildOptionEditing {
    static func selectedValues(_ option: BuildResolvedOption) -> [String] {
        switch option.value {
        case .string(let value): return [value]
        case .array(let values):
            return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
        default: return []
        }
    }

    static func choices(_ option: BuildResolvedOption) -> [BuildResolvedOption.Choice] {
        var choices = option.choices
        guard option.allowCustom else { return choices }
        for value in selectedValues(option) where !choices.contains(where: { $0.value == value }) {
            choices.append(.init(value: value, title: nil, fromModel: false))
        }
        return choices
    }

    static func selecting(_ value: String, in option: BuildResolvedOption) -> ToolingJSONValue {
        guard option.kind == .multiSelect else { return .string(value) }
        let selected = selectedValues(option)
        let next = selected.contains(value) ? selected.filter { $0 != value } : selected + [value]
        return .array(next.map(ToolingJSONValue.string))
    }

    static func customValue(_ text: String, in option: BuildResolvedOption) -> ToolingJSONValue? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard option.allowCustom, !value.isEmpty else { return nil }
        if option.kind == .singleSelect { return .string(value) }
        guard option.kind == .multiSelect else { return nil }
        let selected = selectedValues(option)
        return .array((selected.contains(value) ? selected : selected + [value]).map(ToolingJSONValue.string))
    }

}

/// One option on one line; the effective value is what Core resolved.
struct BuildOptionRow: View {
    let option: BuildResolvedOption
    let indent: CGFloat
    let onChange: (ToolingJSONValue?) -> Void
    @State private var text = ""
    @State private var customText = ""
    @State private var isCustomPresented = false

    var body: some View {
        HStack(spacing: 6) {
            Text(option.displayName)
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            control
            if option.source == "user" {
                Button { onChange(nil) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .litheIconButton()
                .help("Use the default value")
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .frame(minHeight: 24)
        .onAppear { text = Self.text(option.value) }
        .onChange(of: option.value) { text = Self.text($0) }
    }

    @ViewBuilder
    private var control: some View {
        switch option.kind {
        case .boolean?:
            Toggle("", isOn: Binding(
                get: { option.value == .bool(true) },
                set: { onChange(.bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        case .singleSelect?, .multiSelect?:
            let current = option.kind == .multiSelect ? selected.joined(separator: ", ") : Self.text(option.value)
            HStack(spacing: 2) {
                LitheMenu {
                    Self.choiceItems(option: option, onChange: onChange)
                } label: {
                    menuLabel(current.isEmpty ? String(localized: "None") : current)
                }
                .litheToolbarIconButton(isIconOnly: false)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: option.displayName))
                if option.allowCustom {
                    Button {
                        customText = ""
                        isCustomPresented = true
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true)
                    }
                    .litheIconButton()
                    .help(String(format: String(localized: "Add to %@"), option.displayName))
                    .litheDropdown(isPresented: $isCustomPresented) { customValuePanel }
                }
            }
        case .text?, .file?, .directory?:
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 180)
                .onSubmit { onChange(.string(text)) }
        case nil:
            EmptyView()
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: title).lineLimit(1)
            LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16, preservesOriginalColors: true)
        }
        .padding(.horizontal, 4)
    }

    static func choiceItems(option: BuildResolvedOption, onChange: @escaping (ToolingJSONValue?) -> Void) -> [LitheContextMenuItem] {
        let selected = BuildOptionEditing.selectedValues(option)
        return BuildOptionEditing.choices(option).map { choice in
            .action(
                choice.title ?? choice.value, localizesTitle: false,
                checked: selected.contains(choice.value), leadingCheckmark: true,
                initiallySelected: option.kind == .singleSelect && selected.contains(choice.value)
            ) { onChange(BuildOptionEditing.selecting(choice.value, in: option)) }
        }
    }

    private var selected: [String] { BuildOptionEditing.selectedValues(option) }

    private var customValuePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: String(localized: "Add to %@"), option.displayName))
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
            TextField("", text: $customText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(submitCustomValue)
            HStack {
                Spacer()
                Button("Cancel") { isCustomPresented = false }
                Button("Add", action: submitCustomValue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(BuildOptionEditing.customValue(customText, in: option) == nil)
            }
        }
        .padding(14)
    }

    private func submitCustomValue() {
        guard let value = BuildOptionEditing.customValue(customText, in: option) else { return }
        onChange(value)
        isCustomPresented = false
    }

    private static func text(_ value: ToolingJSONValue) -> String {
        switch value {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .bool(let value): String(value)
        case .array, .object, .null: ""
        }
    }
}
