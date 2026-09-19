import LitheCoreContracts
import LitheExecutionModule
import SwiftUI

struct DependencySidebarView: View {
    @EnvironmentObject private var model: AppModel
    let refreshRevision: Int
    @State private var isPreparing = false
    @State private var activationFailed = false

    var body: some View {
        Group {
            if let feature = model.runFeatureIfActive {
                RunServiceDependencySidebarContent(
                    feature: feature,
                    refreshRevision: refreshRevision
                )
            } else if model.workspaceURL == nil {
                placeholder(systemImage: "shippingbox", title: "No project loaded")
            } else if activationFailed {
                placeholder(systemImage: "exclamationmark.triangle", title: "Could not load service dependencies")
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading dependencies...")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(model.workspaceURL?.standardizedFileURL.path ?? ""):\(refreshRevision)") {
            await prepareRunServices()
        }
    }

    private func placeholder(systemImage: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(title)
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func prepareRunServices() async {
        guard !isPreparing, let workspaceURL = model.workspaceURL else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard await model.activateExecutionModule() != nil else {
            activationFailed = true
            return
        }
        activationFailed = false
        await model.loadProjectServicesForAppliedSnapshot(at: workspaceURL)
    }
}

private struct RunServiceDependencySidebarContent: View {
    @ObservedObject var feature: RunFeatureModel
    let refreshRevision: Int

    var body: some View {
        if feature.isLoadingProject {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading run services...")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feature.dependencyServices.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("No run services configured")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(feature.dependencyServices) { service in
                            DependencyServiceSection(
                                feature: feature,
                                service: service,
                                refreshRevision: refreshRevision
                            )
                        }
                    }
                    .padding(.vertical, LitheTheme.Metrics.projectTreeContentVerticalInset)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
                .scrollContentBackground(.hidden)
                .litheScrollViewChrome(usesCompactScrollers: true)
            }
        }
    }
}

private struct DependencyServiceSection: View {
    @ObservedObject var feature: RunFeatureModel
    let service: DependencyServiceDescriptor
    let refreshRevision: Int
    @State private var graph: DependencyGraph?
    @State private var expandedNodeIDs: Set<String> = []
    @State private var isExpanded = false
    @State private var isResolving = false
    @State private var resolutionError: String?
    @State private var isConfigurationPresented = false
    @State private var resolutionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serviceRow
            if isExpanded { serviceContent }
        }
        .onChange(of: feature.dependencyRevision) { _ in invalidateAndReload() }
        .onChange(of: refreshRevision) { _ in invalidateAndReload() }
        .onDisappear {
            resolutionTask?.cancel()
            resolutionTask = nil
        }
        .popover(isPresented: $isConfigurationPresented, arrowEdge: .trailing) {
            DependencyPathConfigurationEditor(
                serviceName: service.displayName,
                configuration: feature.dependencyPaths(for: service.id),
                saveError: feature.dependencyConfigurationSaveError
            ) {
                feature.updateDependencyPaths($0, serviceID: service.id)
            }
        }
    }

    private var serviceRow: some View {
        HStack(spacing: 0) {
            Button {
                isExpanded.toggle()
                if isExpanded, graph == nil { loadDependencies() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 10)
                    LitheSystemIcon(systemImage: service.systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.displayName)
                            .font(.system(size: LitheTheme.Metrics.treeFontSize, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        Text(hasCustomConfiguration ? String(localized: "Configured") : service.providerDisplayName)
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            Button {
                isConfigurationPresented = true
            } label: {
                LitheSystemIcon(systemImage: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help("Configure dependency search paths")
            .accessibilityIdentifier("dependency-path-settings-\(service.id)")
            .padding(.trailing, 4)
        }
        .frame(minWidth: 220)
        .accessibilityIdentifier("dependency-service-\(service.id)")
    }

    @ViewBuilder
    private var serviceContent: some View {
        if isResolving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Resolving service paths...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.leading, 28)
            .frame(minHeight: 28)
        } else if let resolutionError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not load service dependencies")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(resolutionError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(3)
                Button("Retry") { loadDependencies() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
            }
            .padding(.leading, 28)
            .padding(.vertical, 5)
        } else if let root = graph?.roots.first {
            ForEach(root.children) { node in
                DependencyTreeNodeView(
                    node: node,
                    depth: 1,
                    expandedNodeIDs: $expandedNodeIDs
                ) { path in
                    feature.excludeDependencyPath(path, serviceID: service.id)
                }
            }
        } else {
            Text("No paths resolved for this service")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.leading, 28)
                .frame(minHeight: 28)
        }
    }

    private var hasCustomConfiguration: Bool {
        let paths = feature.dependencyPaths(for: service.id)
        return !paths.sourcePaths.isEmpty
            || !paths.binaryPaths.isEmpty
            || !paths.dependencyPaths.isEmpty
            || !paths.additionalSearchPaths.isEmpty
            || !paths.excludedPaths.isEmpty
    }

    private func invalidateAndReload() {
        resolutionTask?.cancel()
        resolutionTask = nil
        graph = nil
        resolutionError = nil
        isResolving = false
        if isExpanded { loadDependencies() }
    }

    private func loadDependencies() {
        guard !isResolving else { return }
        resolutionTask?.cancel()
        isResolving = true
        resolutionError = nil
        resolutionTask = Task { @MainActor in
            defer {
                isResolving = false
                resolutionTask = nil
            }
            do {
                let expectedRevision = feature.dependencyRevision
                let resolved = try await feature.resolveDependencies(serviceID: service.id)
                try Task.checkCancellation()
                guard expectedRevision == feature.dependencyRevision else { return }
                graph = resolved
            } catch is CancellationError {
                return
            } catch {
                resolutionError = error.localizedDescription
            }
        }
    }
}

private struct DependencyTreeNodeView: View {
    let node: DependencyNode
    let depth: Int
    @Binding var expandedNodeIDs: Set<String>
    let onExclude: (String) -> Void

    private var isExpanded: Bool { expandedNodeIDs.contains(node.id) }

    var body: some View {
        if node.kind == .group {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if isExpanded {
                        expandedNodeIDs.remove(node.id)
                    } else {
                        expandedNodeIDs.insert(node.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(width: 10)
                        LitheSystemIcon(systemImage: node.title == "Dependencies" ? "shippingbox" : "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(width: 16)
                        Text(LocalizedStringKey(node.title))
                            .font(.system(size: LitheTheme.Metrics.treeFontSize))
                            .foregroundStyle(LitheTheme.primaryText)
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, CGFloat(8 + depth * 14))
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()

                if isExpanded {
                    if node.children.isEmpty {
                        Text("No paths")
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .padding(.leading, CGFloat(42 + depth * 14))
                            .frame(minHeight: 26)
                    } else {
                        ForEach(node.children) { child in
                            DependencyTreeNodeView(
                                node: child,
                                depth: depth + 1,
                                expandedNodeIDs: $expandedNodeIDs,
                                onExclude: onExclude
                            )
                        }
                    }
                }
            }
        } else {
            pathRow
        }
    }

    private var pathRow: some View {
        HStack(spacing: 6) {
            LitheSystemIcon(systemImage: node.kind == .packageNode ? "shippingbox" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: LitheTheme.Metrics.treeFontSize))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(22 + depth * 14))
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .litheContextMenu(items: {
            guard let path = dependencyPath else { return [] }
            return [.action(String(localized: "Exclude from dependency tree")) { onExclude(path) }]
        })
    }

    private var dependencyPath: String? {
        switch node.source {
        case .directory(let url), .archive(let url): url.path
        case .generated, .unavailable: nil
        }
    }
}

private struct DependencyPathConfigurationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let serviceName: String
    let saveError: String?
    let onSave: (DependencyPathConfiguration) -> Void
    @State private var sourcePaths: String
    @State private var binaryPaths: String
    @State private var dependencyPaths: String
    @State private var additionalPaths: String
    @State private var excludedPaths: [String]

    init(
        serviceName: String,
        configuration: DependencyPathConfiguration,
        saveError: String?,
        onSave: @escaping (DependencyPathConfiguration) -> Void
    ) {
        self.serviceName = serviceName
        self.saveError = saveError
        self.onSave = onSave
        _sourcePaths = State(initialValue: configuration.sourcePaths.joined(separator: "\n"))
        _binaryPaths = State(initialValue: configuration.binaryPaths.joined(separator: "\n"))
        _dependencyPaths = State(initialValue: configuration.dependencyPaths.joined(separator: "\n"))
        _additionalPaths = State(initialValue: configuration.additionalSearchPaths.joined(separator: "\n"))
        _excludedPaths = State(initialValue: configuration.excludedPaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search Paths: \(serviceName)")
                .font(.system(size: 14, weight: .semibold))
            Text("One path per line. Relative paths are resolved from the workspace.")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)

            pathEditor(title: "Source Code", text: $sourcePaths)
            pathEditor(title: "Build Outputs", text: $binaryPaths)
            pathEditor(title: "Dependencies", text: $dependencyPaths)
            pathEditor(title: "Additional Search Paths", text: $additionalPaths)

            if !excludedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Paths")
                        .font(.system(size: 11, weight: .medium))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(excludedPaths, id: \.self) { path in
                                HStack(spacing: 6) {
                                    Text(path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button {
                                        excludedPaths.removeAll { $0 == path }
                                    } label: {
                                        LitheSystemIcon(systemImage: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Restore path")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 84)
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.error)
                    .lineLimit(2)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(DependencyPathConfiguration(
                        sourcePaths: lines(sourcePaths),
                        binaryPaths: lines(binaryPaths),
                        dependencyPaths: lines(dependencyPaths),
                        additionalSearchPaths: lines(additionalPaths),
                        excludedPaths: excludedPaths
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func pathEditor(title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 42)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(LitheTheme.divider, lineWidth: 1)
                }
        }
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map(String.init)
    }
}
