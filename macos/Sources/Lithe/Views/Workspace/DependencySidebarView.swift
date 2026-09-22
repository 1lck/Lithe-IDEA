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
                placeholder(systemImage: "exclamationmark.triangle", title: "Could not load dependencies")
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
                Text("Loading dependencies...")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feature.dependencyServices.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("No language dependency sources registered")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView(.vertical) {
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
                    .frame(width: geometry.size.width, alignment: .topLeading)
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
                }
                .scrollContentBackground(.hidden)
                .litheScrollViewChrome(usesCompactScrollers: true)
            }
        }
    }
}

private struct DependencyServiceSection: View {
    @EnvironmentObject private var model: AppModel
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
                workspaceURL: model.workspaceURL,
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
        .frame(maxWidth: .infinity)
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
        } else if let root = graph?.roots.first, root.children.contains(where: { !$0.children.isEmpty }) {
            ForEach(root.children.filter { !$0.children.isEmpty }) { node in
                DependencyTreeNodeView(
                    node: node,
                    depth: 1,
                    expandedNodeIDs: $expandedNodeIDs
                ) { path in
                    feature.excludeDependencyPath(path, serviceID: service.id)
                } onOpenVirtual: { uri in
                    model.navigate(
                        to: EditorNavigationLocation(
                            url: uri,
                            line: 0,
                            utf16Column: 0,
                            isReadOnly: true,
                            virtualProviderID: service.providerID
                        ),
                        recordsHistory: true
                    )
                }
            }
        } else {
            Text("No dependencies resolved")
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
    let onOpenVirtual: (URL) -> Void

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
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
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
                                onExclude: onExclude,
                                onOpenVirtual: onOpenVirtual
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
        Group {
            if case .virtualDocument(let uri) = node.source {
                Button { onOpenVirtual(uri) } label: { pathRowContent }
                    .buttonStyle(.plain)
                    .lithePointer()
            } else {
                pathRowContent
            }
        }
    }

    private var pathRowContent: some View {
        HStack(spacing: 6) {
            LitheSystemIcon(systemImage: nodeIcon)
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: LitheTheme.Metrics.treeFontSize))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let subtitle = compactSubtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(22 + depth * 14))
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .help(node.subtitle ?? node.title)
        .litheContextMenu(items: {
            guard let path = dependencyPath else { return [] }
            return [.action(String(localized: "Exclude from dependency tree")) { onExclude(path) }]
        })
    }

    private var dependencyPath: String? {
        switch node.source {
        case .directory(let url), .archive(let url): url.path
        case .virtualDocument, .generated, .unavailable: nil
        }
    }

    private var compactSubtitle: String? {
        guard let subtitle = node.subtitle else { return nil }
        switch node.source {
        case .directory(let url), .archive(let url):
            let parent = url.deletingLastPathComponent()
            let components = parent.pathComponents
            return components.count > 3
                ? ".../" + components.suffix(2).joined(separator: "/")
                : parent.path
        case .virtualDocument, .generated, .unavailable:
            return subtitle
        }
    }

    private var nodeIcon: String {
        if case .virtualDocument = node.source { return "doc.text" }
        return node.kind == .packageNode ? "shippingbox" : "folder"
    }
}

private struct DependencyPathConfigurationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let serviceName: String
    let workspaceURL: URL?
    let saveError: String?
    let onSave: (DependencyPathConfiguration) -> Void
    @State private var sourcePaths: String
    @State private var binaryPaths: String
    @State private var dependencyPaths: String
    @State private var additionalPaths: String
    @State private var excludedPaths: [String]
    @State private var browsingCategory: DependencyPathCategory?
    @State private var showsTextEditor = false

    init(
        serviceName: String,
        workspaceURL: URL?,
        configuration: DependencyPathConfiguration,
        saveError: String?,
        onSave: @escaping (DependencyPathConfiguration) -> Void
    ) {
        self.serviceName = serviceName
        self.workspaceURL = workspaceURL
        self.saveError = saveError
        self.onSave = onSave
        _sourcePaths = State(initialValue: configuration.sourcePaths.joined(separator: "\n"))
        _binaryPaths = State(initialValue: configuration.binaryPaths.joined(separator: "\n"))
        _dependencyPaths = State(initialValue: configuration.dependencyPaths.joined(separator: "\n"))
        _additionalPaths = State(initialValue: configuration.additionalSearchPaths.joined(separator: "\n"))
        _excludedPaths = State(initialValue: configuration.excludedPaths)
    }

    var body: some View {
        Group {
            if let browsingCategory, let workspaceURL {
                DependencyFolderBrowser(
                    category: browsingCategory,
                    workspaceURL: workspaceURL,
                    existingPaths: lines(pathText(for: browsingCategory).wrappedValue),
                    onCancel: { self.browsingCategory = nil },
                    onAdd: { urls in
                        let text = pathText(for: browsingCategory)
                        text.wrappedValue = DependencyPathSelection.appending(
                            urls,
                            to: text.wrappedValue,
                            workspaceURL: workspaceURL
                        )
                        self.browsingCategory = nil
                    }
                )
            } else {
                configurationContent
            }
        }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search Paths: \(serviceName)")
                .font(.system(size: 14, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(DependencyPathCategory.allCases) { category in
                        pathList(for: category)
                    }
                    DisclosureGroup("Edit Paths as Text", isExpanded: $showsTextEditor) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("One path per line. Relative paths are resolved from the workspace.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                            ForEach(DependencyPathCategory.allCases) { category in
                                pathEditor(title: category.title, text: pathText(for: category))
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 11))
                }
            }
            .frame(maxHeight: 340)

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
        .frame(width: 430)
    }

    private func pathList(for category: DependencyPathCategory) -> some View {
        let text = pathText(for: category)
        let paths = lines(text.wrappedValue)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(category.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 0)
                Button {
                    browsingCategory = category
                } label: {
                    Label("Browse", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
                .disabled(workspaceURL == nil)
            }
            if paths.isEmpty {
                Text("No additional paths")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Text(path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer(minLength: 0)
                        Button {
                            text.wrappedValue = lines(text.wrappedValue)
                                .filter { $0 != path }.joined(separator: "\n")
                        } label: {
                            LitheSystemIcon(systemImage: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove path")
                    }
                }
            }
        }
    }

    private func pathText(for category: DependencyPathCategory) -> Binding<String> {
        switch category {
        case .source: $sourcePaths
        case .output: $binaryPaths
        case .dependency: $dependencyPaths
        case .additional: $additionalPaths
        }
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

private enum DependencyPathCategory: String, CaseIterable, Identifiable {
    case source, output, dependency, additional

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .source: "Source Code"
        case .output: "Build Outputs"
        case .dependency: "Dependencies"
        case .additional: "Additional Search Paths"
        }
    }

    var acceptsArchives: Bool { self == .dependency || self == .additional }
}

// Converts browser selections into the same workspace-relative values accepted by the JSON editor.
enum DependencyPathSelection {
    static func storedPath(for url: URL, workspaceURL: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = workspaceURL.standardizedFileURL.path
        if path == root { return "." }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    static func appending(_ urls: [URL], to text: String, workspaceURL: URL) -> String {
        var paths = text.split(whereSeparator: \.isNewline).map(String.init)
        var existing = Set(paths.map { resolvedURL(for: $0, workspaceURL: workspaceURL).path })
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let normalized = url.standardizedFileURL
            if existing.insert(normalized.path).inserted {
                paths.append(storedPath(for: normalized, workspaceURL: workspaceURL))
            }
        }
        return paths.joined(separator: "\n")
    }

    static func resolvedURL(for path: String, workspaceURL: URL) -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL
    }
}

struct DependencyFolderEntry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }

    static func contents(of folder: URL, acceptsArchives: Bool) throws -> [Self] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        return try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { url -> Self? in
            let isDirectory = try url.resourceValues(forKeys: keys).isDirectory == true
            guard isDirectory || (acceptsArchives && ["jar", "zip", "aar", "whl"]
                .contains(url.pathExtension.lowercased())) else { return nil }
            return Self(url: url.standardizedFileURL, isDirectory: isDirectory)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

private struct DependencyFolderBrowser: View {
    let category: DependencyPathCategory
    let workspaceURL: URL
    let existingPaths: [String]
    let onCancel: () -> Void
    let onAdd: ([URL]) -> Void

    @State private var folderURL: URL
    @State private var selectedURLs: Set<URL> = []
    @State private var entries: [DependencyFolderEntry] = []
    @State private var loadError: String?
    @State private var isLoading = false

    init(
        category: DependencyPathCategory,
        workspaceURL: URL,
        existingPaths: [String],
        onCancel: @escaping () -> Void,
        onAdd: @escaping ([URL]) -> Void
    ) {
        self.category = category
        self.workspaceURL = workspaceURL
        self.existingPaths = existingPaths
        self.onCancel = onCancel
        self.onAdd = onAdd
        _folderURL = State(initialValue: workspaceURL.standardizedFileURL)
    }

    private var existingURLs: Set<URL> {
        Set(existingPaths.map { DependencyPathSelection.resolvedURL(for: $0, workspaceURL: workspaceURL) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(category.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Button("Open Folder...") { openFolder() }
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Button { folderURL = folderURL.deletingLastPathComponent() } label: {
                    LitheSystemIcon(systemImage: "arrow.up")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(folderURL.path == "/")
                .help("Parent folder")
                Button { folderURL = workspaceURL.standardizedFileURL } label: {
                    LitheSystemIcon(systemImage: "house")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Workspace folder")
                Text(folderURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folderURL.path)
            }

            VStack(alignment: .leading, spacing: 0) {
                folderRow(folderURL, isDirectory: true, isCurrent: true)
                Divider()
                if isLoading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.error)
                        .padding(10)
                } else if entries.isEmpty {
                    Text("No selectable items")
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(10)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                folderRow(entry.url, isDirectory: entry.isDirectory)
                            }
                        }
                    }
                }
            }
            .frame(height: 290, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(LitheTheme.divider, lineWidth: 1)
            }

            HStack {
                Text("\(selectedURLs.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected") { onAdd(Array(selectedURLs)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedURLs.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 500)
        .task(id: folderURL) {
            isLoading = true
            loadError = nil
            entries = []
            let folder = folderURL
            let acceptsArchives = category.acceptsArchives
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try DependencyFolderEntry.contents(of: folder, acceptsArchives: acceptsArchives)
                }.value
                try Task.checkCancellation()
                entries = loaded
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func folderRow(_ url: URL, isDirectory: Bool, isCurrent: Bool = false) -> some View {
        let isExisting = existingURLs.contains(url)
        return HStack(spacing: 7) {
            Toggle(isOn: Binding(
                get: { selectedURLs.contains(url) || isExisting },
                set: { selected in
                    if selected { selectedURLs.insert(url) } else { selectedURLs.remove(url) }
                }
            )) {
                HStack(spacing: 6) {
                    LitheSystemIcon(systemImage: isDirectory ? "folder" : "shippingbox")
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(isCurrent ? String(localized: "This Folder") : url.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isExisting {
                        Text("Added")
                            .font(.system(size: 10))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isExisting)
            .help(url.path)
            Spacer(minLength: 0)
            if isDirectory && !isCurrent {
                Button { folderURL = url } label: {
                    LitheSystemIcon(systemImage: "chevron.right")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Open folder")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url.standardizedFileURL
    }
}
