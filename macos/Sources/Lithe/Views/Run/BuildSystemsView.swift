import LitheCoreContracts
import LitheExecutionModule
import SwiftUI

/// Build systems that enabled plugins declare: their projects, tasks,
/// options, and dependencies. Everything here comes from Rust Core through
/// `BuildSystemsFeatureModel`; the view only chooses what to run.
struct BuildSystemsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: BuildSystemsFeatureModel
    @State private var expandedIDs: Set<String> = []
    @State private var argumentsPrompt: ArgumentsPrompt?

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Build", subtitle: nil) {
                Button(action: feature.detect) {
                    Image(systemName: "arrow.clockwise")
                }
                .litheIconButton()
                .disabled(feature.isDetecting)
                .help("Detect build systems again")
                if feature.isRunning {
                    Button(action: feature.stopRun) {
                        Image(systemName: "stop.fill")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.warning)
                    .help("Stop build task")
                }
                LitheSidebarHideButton(title: "Build") {
                    model.workbenchFeature.setVisibility(.buildSystems, isVisible: false)
                }
            }
            if !feature.issues.isEmpty {
                issueList
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            if feature.entries.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(feature.entries) { entry in
                            entrySection(entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .workbenchHoverTooltipScope()
        .sheet(item: $argumentsPrompt) { prompt in
            BuildArgumentsSheet(prompt: prompt) { arguments in
                argumentsPrompt = nil
                run(prompt.request.withUserArguments(arguments), title: prompt.title, entryID: prompt.entryID)
            } onCancel: {
                argumentsPrompt = nil
            }
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 8) {
            if feature.isDetecting {
                ProgressView().controlSize(.small)
                Text("Detecting build systems…")
            } else {
                Image(systemName: "hammer")
                    .font(.system(size: 22))
                Text("No build system was detected in this workspace.")
                    .multilineTextAlignment(.center)
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(feature.issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.warning)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entrySection(_ entry: BuildSystemEntry) -> some View {
        let id = "entry:" + entry.id
        row(
            id: id,
            depth: 0,
            systemImage: "hammer",
            title: entry.instance.displayName,
            detail: entry.instance.root == "." ? nil : entry.instance.root,
            expandable: true
        ) {
            entryAccessories(entry)
        }
        .litheContextMenu(items: { entryMenu(entry) })
        if expandedIDs.contains(id) {
            entryContent(entry)
        }
    }

    @ViewBuilder
    private func entryAccessories(_ entry: BuildSystemEntry) -> some View {
        switch entry.modelState {
        case .loading:
            ProgressView().controlSize(.mini)
        case .failed(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(LitheTheme.error)
                .help(message)
        case .loaded, .notLoaded:
            if entry.isReloadRequired {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(LitheTheme.warning)
                    .help("Build files changed. Reload the model to pick up the changes.")
            }
        }
        if entry.instance.modelSource == .command {
            Button { feature.loadModel(entry.id) } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .litheIconButton()
            .disabled(entry.modelState == .loading)
            .help(entry.model == nil ? "Load the project model" : "Reload the project model")
        }
    }

    @LitheMenuItemsBuilder
    private func entryMenu(_ entry: BuildSystemEntry) -> [LitheContextMenuItem] {
        if entry.instance.modelSource == .command {
            LitheContextMenuItem.action(entry.model == nil ? "Load Project Model" : "Reload Project Model") {
                feature.loadModel(entry.id)
            }
        }
        if entry.declaration.testScopes.contains(.workspace) {
            LitheContextMenuItem.action("Run All Tests") { runTests(entry, project: nil, target: nil) }
        }
        if entry.declaration.dependencyScopes.contains(.workspace) {
            LitheContextMenuItem.action("Show Dependencies") { showDependencies(entry, project: nil) }
        }
    }

    @ViewBuilder
    private func entryContent(_ entry: BuildSystemEntry) -> some View {
        if case .failed(let message) = entry.modelState {
            messageRow(message, depth: 1, color: LitheTheme.error)
        }
        if entry.isReloadRequired {
            HStack(spacing: 6) {
                Text("Build files changed.")
                Button("Reload") { feature.loadModel(entry.id) }
                    .buttonStyle(.link)
            }
            .font(LitheTheme.uiFont(size: 11))
            .foregroundStyle(LitheTheme.warning)
            .padding(.leading, indent(1) + 16)
            .padding(.vertical, 3)
        }
        let workspaceTasks = entry.declaration.tasks.filter { !$0.fromModel && $0.scopes.contains(.workspace) }
        if !workspaceTasks.isEmpty || entry.declaration.testScopes.contains(.workspace) {
            groupSection(id: "tasks:" + entry.id, title: String(localized: "Tasks"), depth: 1) {
                if entry.declaration.testScopes.contains(.workspace) {
                    testRow(entry, project: nil, target: nil, depth: 2)
                }
                ForEach(workspaceTasks) { task in
                    declaredTaskRow(entry, task: task, project: nil, target: nil, depth: 2)
                }
            }
        }
        let options = entry.options.filter { $0.kind != nil }
        if !options.isEmpty {
            groupSection(id: "options:" + entry.id, title: String(localized: "Options"), depth: 1) {
                ForEach(options) { option in
                    BuildOptionRow(option: option, indent: indent(2) + 16) { value in
                        feature.setOption(entry.id, optionID: option.id, value: value)
                    }
                }
            }
        }
        if let model = entry.model {
            if model.truncated {
                messageRow(String(localized: "The model is too large; some entries are not shown."), depth: 1, color: LitheTheme.warning)
            }
            ForEach(model.projects.filter { $0.parentID == nil || !model.projects.map(\.id).contains($0.parentID!) }) { project in
                projectSection(entry, model: model, project: project, depth: 1)
            }
        } else if entry.modelState == .notLoaded, entry.instance.modelSource == .command {
            HStack(spacing: 6) {
                Text("The project model is not loaded.")
                Button("Load") { feature.loadModel(entry.id) }
                    .buttonStyle(.link)
            }
            .font(LitheTheme.uiFont(size: 11))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.leading, indent(1) + 16)
            .padding(.vertical, 3)
        }
        if entry.declaration.dependencyScopes.contains(.workspace),
           entry.declaration.dependencyScopes.contains(.project) == false || entry.model == nil {
            dependencySection(entry, project: nil, depth: 1)
        }
    }

    private func projectSection(
        _ entry: BuildSystemEntry,
        model: BuildModel,
        project: BuildModel.Project,
        depth: Int
    ) -> AnyView {
        let id = "project:" + entry.id + ":" + project.id
        let declaration = entry.declaration
        let projectTasks = declaration.tasks.filter { !$0.fromModel && $0.scopes.contains(.project) }
        let modelTasks = model.tasks.filter { $0.projectID == project.id }
        let targets = model.targets.filter { $0.projectID == project.id }
        let children = model.projects.filter { $0.parentID == project.id }
        return AnyView(Group {
            row(
                id: id,
                depth: depth,
                systemImage: "folder",
                title: project.displayName ?? project.name,
                detail: project.path == entry.instance.root ? nil : project.path,
                expandable: true
            ) { EmptyView() }
            .litheContextMenu(items: {
                projectMenu(entry, project: project)
            })
            if expandedIDs.contains(id) {
                if declaration.testScopes.contains(.project) {
                    testRow(entry, project: project, target: nil, depth: depth + 1)
                }
                ForEach(projectTasks) { task in
                    declaredTaskRow(entry, task: task, project: project, target: nil, depth: depth + 1)
                }
                if !modelTasks.isEmpty {
                    groupSection(id: id + ":model-tasks", title: String(localized: "Tasks"), depth: depth + 1) {
                        ForEach(modelTasks) { task in
                            modelTaskRow(entry, task: task, project: project, depth: depth + 2)
                        }
                    }
                }
                ForEach(targets) { target in
                    targetSection(entry, project: project, target: target, depth: depth + 1)
                }
                if declaration.dependencyScopes.contains(.project) {
                    dependencySection(entry, project: project, depth: depth + 1)
                }
                ForEach(children) { child in
                    projectSection(entry, model: model, project: child, depth: depth + 1)
                }
            }
        })
    }

    @LitheMenuItemsBuilder
    private func projectMenu(_ entry: BuildSystemEntry, project: BuildModel.Project) -> [LitheContextMenuItem] {
        if entry.declaration.testScopes.contains(.project) {
            LitheContextMenuItem.action("Run Tests") { runTests(entry, project: project, target: nil) }
        }
        if entry.declaration.dependencyScopes.contains(.project) {
            LitheContextMenuItem.action("Show Dependencies") { showDependencies(entry, project: project) }
        }
    }

    @ViewBuilder
    private func targetSection(
        _ entry: BuildSystemEntry,
        project: BuildModel.Project,
        target: BuildModel.Target,
        depth: Int
    ) -> some View {
        let id = "target:" + entry.id + ":" + target.id
        let tasks = entry.declaration.tasks.filter {
            !$0.fromModel && $0.scopes.contains(.target) && Self.matches(target, tags: $0.targetTags)
        }
        let testable = entry.declaration.testScopes.contains(.target)
            && Self.matches(target, tags: entry.declaration.testTargetTags)
        row(
            id: id,
            depth: depth,
            systemImage: "target",
            title: target.name,
            detail: target.tags.isEmpty ? nil : target.tags.joined(separator: ", "),
            expandable: !tasks.isEmpty || testable
        ) { EmptyView() }
        if expandedIDs.contains(id) {
            if testable {
                testRow(entry, project: project, target: target, depth: depth + 1)
            }
            ForEach(tasks) { task in
                declaredTaskRow(entry, task: task, project: project, target: target, depth: depth + 1)
            }
        }
    }

    @ViewBuilder
    private func dependencySection(_ entry: BuildSystemEntry, project: BuildModel.Project?, depth: Int) -> some View {
        let key = project?.path ?? entry.instance.root
        let id = "dependencies:" + entry.id + ":" + key
        row(
            id: id,
            depth: depth,
            systemImage: "shippingbox",
            title: String(localized: "Dependencies"),
            detail: nil,
            expandable: true,
            onExpand: {
                if entry.dependencies[key] == nil { feature.loadDependencies(entry.id, project: project) }
            }
        ) {
            if entry.dependencies[key] != nil, entry.dependencies[key] != .loading {
                Button { feature.loadDependencies(entry.id, project: project) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .litheIconButton()
                .help("Load the dependencies again")
            }
        }
        if expandedIDs.contains(id) {
            switch entry.dependencies[key] {
            case .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading dependencies…")
                }
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.leading, indent(depth + 1) + 16)
                .padding(.vertical, 3)
            case .failed(let message)?:
                messageRow(message, depth: depth + 1, color: LitheTheme.error)
            case .loaded(let tree)?:
                if tree.dependencies.isEmpty {
                    messageRow(String(localized: "No dependencies."), depth: depth + 1, color: LitheTheme.secondaryText)
                }
                ForEach(Array(tree.dependencies.enumerated()), id: \.offset) { index, node in
                    dependencyRow(node, id: id + "/\(index)", depth: depth + 1)
                }
                if tree.truncated {
                    messageRow(String(localized: "Some dependencies are not shown."), depth: depth + 1, color: LitheTheme.warning)
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func dependencyRow(_ node: BuildDependencyNode, id: String, depth: Int) -> AnyView {
        let coordinate = [node.group, node.name].compactMap { $0 }.joined(separator: ":")
        let detail = [node.version, node.scope].compactMap { $0 }.joined(separator: " · ")
        return AnyView(Group {
            row(
                id: id,
                depth: depth,
                systemImage: "shippingbox",
                title: coordinate,
                detail: detail.isEmpty ? nil : detail,
                expandable: !node.children.isEmpty
            ) { EmptyView() }
            if expandedIDs.contains(id) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                    dependencyRow(child, id: id + "/\(index)", depth: depth + 1)
                }
            }
        })
    }

    // MARK: Runnable rows

    private func testRow(
        _ entry: BuildSystemEntry,
        project: BuildModel.Project?,
        target: BuildModel.Target?,
        depth: Int
    ) -> some View {
        actionRow(
            depth: depth,
            systemImage: "checkmark.seal",
            title: String(localized: "Run Tests"),
            help: nil
        ) {
            runTests(entry, project: project, target: target)
        }
    }

    private func declaredTaskRow(
        _ entry: BuildSystemEntry,
        task: DeclarativeBuildSystem.Task,
        project: BuildModel.Project?,
        target: BuildModel.Target?,
        depth: Int
    ) -> some View {
        actionRow(
            depth: depth,
            systemImage: Self.systemImage(task.group),
            title: task.displayName,
            help: task.description
        ) {
            let request = BuildTaskRequest(
                task: task.id,
                project: project.map(BuildSelection.init(project:)),
                target: target.map(BuildSelection.init(target:))
            )
            let title = Self.title(task.displayName, entry: entry, project: project, target: target)
            if task.requiresUserArguments {
                argumentsPrompt = ArgumentsPrompt(entryID: entry.id, title: title, request: request)
            } else {
                run(request, title: title, entryID: entry.id)
            }
        }
    }

    private func modelTaskRow(
        _ entry: BuildSystemEntry,
        task: BuildModel.Task,
        project: BuildModel.Project,
        depth: Int
    ) -> some View {
        let template = entry.declaration.tasks.first { $0.id == task.template }
        return actionRow(
            depth: depth,
            systemImage: Self.systemImage(task.group),
            title: task.displayName ?? task.name,
            help: task.description
        ) {
            let request = BuildTaskRequest(
                task: task.template,
                project: BuildSelection(project: project),
                modelTask: BuildSelection(task: task)
            )
            let title = Self.title(task.displayName ?? task.name, entry: entry, project: project, target: nil)
            if template?.requiresUserArguments == true {
                argumentsPrompt = ArgumentsPrompt(entryID: entry.id, title: title, request: request)
            } else {
                run(request, title: title, entryID: entry.id)
            }
        }
    }

    private func run(_ request: BuildTaskRequest, title: String, entryID: String) {
        feature.runTask(entryID, request: request, title: title)
        model.showToolWindow(.buildOutput)
    }

    private func runTests(_ entry: BuildSystemEntry, project: BuildModel.Project?, target: BuildModel.Target?) {
        let request = BuildTestRequest(
            project: project.map(BuildSelection.init(project:)),
            target: target.map(BuildSelection.init(target:)),
            projects: entry.model?.projects.map(\.path) ?? []
        )
        let title = Self.title(String(localized: "Tests"), entry: entry, project: project, target: target)
        feature.runTests(entry.id, request: request, title: title)
        model.showToolWindow(.buildOutput)
    }

    private func showDependencies(_ entry: BuildSystemEntry, project: BuildModel.Project?) {
        let key = project?.path ?? entry.instance.root
        expandedIDs.insert("entry:" + entry.id)
        if let project { expandedIDs.insert("project:" + entry.id + ":" + project.id) }
        expandedIDs.insert("dependencies:" + entry.id + ":" + key)
        feature.loadDependencies(entry.id, project: project)
    }

    // MARK: Rows

    private func indent(_ depth: Int) -> CGFloat { 8 + CGFloat(depth) * 14 }

    private func row<Accessories: View>(
        id: String,
        depth: Int,
        systemImage: String,
        title: String,
        detail: String?,
        expandable: Bool,
        onExpand: (() -> Void)? = nil,
        @ViewBuilder accessories: () -> Accessories
    ) -> some View {
        let expanded = expandedIDs.contains(id)
        return HStack(spacing: 5) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 11)
                .opacity(expandable ? 1 : 0)
            Image(systemName: systemImage)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            accessories()
        }
        .font(LitheTheme.uiFont(size: 12))
        .padding(.leading, indent(depth))
        .padding(.trailing, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandable else { return }
            if expanded {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
                onExpand?()
            }
        }
    }

    private func actionRow(
        depth: Int,
        systemImage: String,
        title: String,
        help: String?,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: perform) {
                Image(systemName: "play.fill")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.success)
            .disabled(feature.isRunning)
            .help("Run")
        }
        .font(LitheTheme.uiFont(size: 12))
        .padding(.leading, indent(depth) + 16)
        .padding(.trailing, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .help(help ?? title)
        .onTapGesture(count: 2) {
            guard !feature.isRunning else { return }
            perform()
        }
    }

    @ViewBuilder
    private func groupSection<Content: View>(
        id: String,
        title: String,
        depth: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        row(id: id, depth: depth, systemImage: "list.bullet", title: title, detail: nil, expandable: true) {
            EmptyView()
        }
        if expandedIDs.contains(id) {
            content()
        }
    }

    private func messageRow(_ message: String, depth: Int, color: Color) -> some View {
        Text(message)
            .font(LitheTheme.uiFont(size: 11))
            .foregroundStyle(color)
            .lineLimit(4)
            .textSelection(.enabled)
            .padding(.leading, indent(depth) + 16)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func matches(_ target: BuildModel.Target, tags: [String]) -> Bool {
        tags.isEmpty || target.tags.contains(where: tags.contains)
    }

    private static func title(
        _ task: String,
        entry: BuildSystemEntry,
        project: BuildModel.Project?,
        target: BuildModel.Target?
    ) -> String {
        let scope = target?.name ?? project.map { $0.displayName ?? $0.name } ?? entry.instance.displayName
        return "\(scope): \(task)"
    }

    private static func systemImage(_ group: BuildTaskGroup) -> String {
        switch group {
        case .lifecycle: "arrow.triangle.2.circlepath"
        case .build: "hammer"
        case .test: "checkmark.seal"
        case .run: "play.rectangle"
        case .verification: "checkmark.shield"
        case .documentation: "doc.text"
        case .other: "gearshape"
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

/// One option on one line; the effective value is what Core resolved.
private struct BuildOptionRow: View {
    let option: BuildResolvedOption
    let indent: CGFloat
    let onChange: (ToolingJSONValue?) -> Void
    @State private var text = ""
    @State private var customValue = ""
    @State private var isEnteringCustomValue = false

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
        case .singleSelect?:
            let current = Self.text(option.value)
            if isEnteringCustomValue {
                customValueField { value in
                    onChange(.string(value))
                    isEnteringCustomValue = false
                }
            } else {
                LitheMenu {
                    for choice in option.choices {
                        LitheContextMenuItem.action(
                            choice.title ?? choice.value,
                            localizesTitle: false,
                            checked: choice.value == current,
                            leadingCheckmark: true,
                            initiallySelected: choice.value == current
                        ) { onChange(.string(choice.value)) }
                    }
                    if option.allowCustom {
                        if !option.choices.isEmpty { LitheContextMenuItem.separator }
                        LitheContextMenuItem.action("Custom Value…") {
                            customValue = current
                            isEnteringCustomValue = true
                        }
                    }
                } label: {
                    menuLabel(current.isEmpty ? String(localized: "None") : current)
                }
                .litheToolbarIconButton(isIconOnly: false)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: option.displayName))
            }
        case .multiSelect?:
            if isEnteringCustomValue {
                customValueField { value in
                    let values = selected.contains(value) ? selected : selected + [value]
                    onChange(.array(values.map(ToolingJSONValue.string)))
                    isEnteringCustomValue = false
                }
            } else {
                LitheMenu {
                    for choice in option.choices {
                        LitheContextMenuItem.action(
                            choice.title ?? choice.value,
                            localizesTitle: false,
                            checked: selected.contains(choice.value),
                            leadingCheckmark: true
                        ) { onChange(.array(toggled(choice.value).map(ToolingJSONValue.string))) }
                    }
                    let custom = selected.filter { value in
                        !option.choices.contains { $0.value == value }
                    }
                    if !custom.isEmpty {
                        if !option.choices.isEmpty { LitheContextMenuItem.separator }
                        for value in custom {
                            LitheContextMenuItem.action(
                                value, localizesTitle: false, checked: true, leadingCheckmark: true
                            ) {
                                onChange(.array(
                                    selected.filter { $0 != value }.map(ToolingJSONValue.string)
                                ))
                            }
                        }
                    }
                    if option.allowCustom {
                        LitheContextMenuItem.separator
                        LitheContextMenuItem.action("Add Custom Value…") {
                            customValue = ""
                            isEnteringCustomValue = true
                        }
                    }
                } label: {
                    menuLabel(selected.isEmpty ? String(localized: "None") : selected.joined(separator: ", "))
                }
                .litheToolbarIconButton(isIconOnly: false)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: option.displayName))
            }
        case .text?, .file?, .directory?:
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 180)
                // An empty text is an explicit value; the reset button
                // restores the declaration default.
                .onSubmit { onChange(.string(text)) }
        case nil:
            EmptyView()
        }
    }

    /// Custom values a plugin allows but Core cannot list as choices.
    private func customValueField(onSubmit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            TextField("", text: $customValue)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 150)
                .onSubmit {
                    let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.isEmpty {
                        isEnteringCustomValue = false
                    } else {
                        onSubmit(value)
                    }
                }
            Button { isEnteringCustomValue = false } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Cancel")
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: title).lineLimit(1)
            LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16, preservesOriginalColors: true)
        }
        .padding(.horizontal, 4)
    }

    private var selected: [String] {
        guard case .array(let values) = option.value else { return [] }
        return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    private func toggled(_ value: String) -> [String] {
        selected.contains(value) ? selected.filter { $0 != value } : selected + [value]
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
