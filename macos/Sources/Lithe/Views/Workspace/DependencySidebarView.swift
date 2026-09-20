import LitheCoreContracts
import LitheLanguageIntelligenceModule
import SwiftUI

struct DependencySidebarView: View {
    @EnvironmentObject private var model: AppModel
    let refreshRevision: Int
    @State private var activationFailed = false

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                placeholder(systemImage: "shippingbox", title: "No project loaded")
            } else if let feature = model.languageDependencyFeatureIfActive {
                LanguageDependencySidebarContent(
                    feature: feature,
                    refreshRevision: refreshRevision
                )
            } else if activationFailed {
                placeholder(systemImage: "exclamationmark.triangle", title: "Could not load language dependencies")
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
        .task(id: "\(model.workspaceURL?.standardizedFileURL.path ?? ""):\(model.workspaceSnapshotID?.uuidString ?? ""):\(refreshRevision)") {
            await prepareLanguageDependencies()
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
    private func prepareLanguageDependencies() async {
        guard let workspaceURL = model.workspaceURL else { return }
        let prepared = await model.prepareLanguageDependencyFeature(
            workspaceURL: workspaceURL,
            files: model.projectFiles,
            forceRefresh: refreshRevision > 0
        )
        guard model.workspaceURL?.standardizedFileURL == workspaceURL.standardizedFileURL else {
            return
        }
        activationFailed = prepared == nil
    }
}

private struct LanguageDependencySidebarContent: View {
    @ObservedObject var feature: LanguageDependencyFeatureModel
    let refreshRevision: Int

    var body: some View {
        if feature.languages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("No language server provides dependencies")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(feature.languages) { language in
                            LanguageDependencySection(
                                feature: feature,
                                language: language,
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

private struct LanguageDependencySection: View {
    @ObservedObject var feature: LanguageDependencyFeatureModel
    let language: LanguageDependencyDescriptor
    let refreshRevision: Int
    @State private var graph: DependencyGraph?
    @State private var expandedNodeIDs: Set<String> = []
    @State private var isExpanded = false
    @State private var isResolving = false
    @State private var resolutionError: String?
    @State private var resolutionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serviceRow
            if isExpanded { serviceContent }
        }
        .onChange(of: feature.revision) { _ in invalidateAndReload() }
        .onChange(of: refreshRevision) { _ in invalidateAndReload() }
        .onDisappear {
            resolutionTask?.cancel()
            resolutionTask = nil
        }
    }

    private var serviceRow: some View {
        Button {
            isExpanded.toggle()
            if isExpanded, graph == nil { loadDependencies() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 10)
                LitheSystemIcon(systemImage: language.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(language.displayName)
                    .font(.system(size: LitheTheme.Metrics.treeFontSize, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .frame(minWidth: 220)
        .accessibilityIdentifier("dependency-language-\(language.id)")
    }

    @ViewBuilder
    private var serviceContent: some View {
        if isResolving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Resolving language dependencies...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.leading, 28)
            .frame(minHeight: 28)
        } else if let resolutionError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not load language dependencies")
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
                )
            }
        } else {
            Text("No dependencies reported by this language server")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.leading, 28)
                .frame(minHeight: 28)
        }
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
                let expectedRevision = feature.revision
                let resolved = try await feature.resolve(providerID: language.providerID)
                try Task.checkCancellation()
                guard expectedRevision == feature.revision else { return }
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
    @State private var isPathRevealed = false
    @State private var pathRevealTask: Task<Void, Never>?

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
                                expandedNodeIDs: $expandedNodeIDs
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LitheSystemIcon(systemImage: node.kind == .packageNode ? "shippingbox" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(node.title)
                    .font(.system(size: LitheTheme.Metrics.treeFontSize))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(22 + depth * 14))
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)

            if isPathRevealed, let subtitle = node.subtitle {
                DependencyPathRevealStrip(path: subtitle)
                    .padding(.leading, CGFloat(22 + depth * 14))
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { revealPath() }
        .onDisappear {
            pathRevealTask?.cancel()
            pathRevealTask = nil
        }
    }

    private func revealPath() {
        guard node.subtitle != nil else { return }
        pathRevealTask?.cancel()
        isPathRevealed = true
        pathRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isPathRevealed = false
            pathRevealTask = nil
        }
    }

}

private struct DependencyPathRevealStrip: View {
    let path: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(path)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
        .background(LitheTheme.toolHeader.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(LitheTheme.divider, lineWidth: 1)
        }
        .help("Full path")
        .accessibilityLabel(path)
        .accessibilityAddTraits(.isStaticText)
    }
}
