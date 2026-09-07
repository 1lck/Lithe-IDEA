import SwiftUI
import LitheExecutionModule

/// Language-neutral test tool window. Discovery is metadata-only; a process is
/// created only after the user chooses a workspace or file item and presses Run.
struct LanguageTestsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: LanguageTestService

    @State private var selectedItemID: String?
    @State private var collapsedProviderIDs: Set<String> = []
    @AppStorage("lithe.tests.itemListWidth") private var itemListWidth = 250.0
    @AppStorage("lithe.tests.itemListCollapsed") private var isItemListCollapsed = false
    @State private var liveItemListWidth: CGFloat?
    @State private var itemListDragStart: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader

            if model.workspaceURL == nil {
                emptyState("Open a project to discover tests.")
            } else if testProviderDescriptors.isEmpty {
                emptyState("No supported test provider is available in this project.")
            } else {
                GeometryReader { geometry in
                    let minimumListWidth: CGFloat = 190
                    let minimumContentWidth: CGFloat = 320
                    let maximumListWidth = max(
                        minimumListWidth,
                        geometry.size.width - SplitHandleView.thickness - minimumContentWidth
                    )

                    if isItemListCollapsed {
                        HStack(spacing: 0) {
                            collapsedItemListBar
                                .frame(width: 32)
                            Rectangle()
                                .fill(LitheTheme.divider)
                                .frame(width: 1)
                            selectedTestContent
                        }
                    } else {
                        LitheSplitPaneView(
                            axis: .horizontal,
                            placement: .leading,
                            defaultSize: CGFloat(itemListWidth),
                            minimum: minimumListWidth,
                            maximum: maximumListWidth,
                            onCommit: { itemListWidth = Double($0) },
                            sized: { testItemList },
                            flexible: { selectedTestContent }
                        )
                    }
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .onAppear(perform: selectDefaultItemIfNeeded)
        .onChange(of: service.itemsByProviderID) { _ in selectDefaultItemIfNeeded() }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Tests",
            systemImage: "checkmark.seal",
            subtitle: testCount > 0 ? String(testCount) : nil,
            onMinimize: { model.workbenchFeature.setVisibility(.tests, isVisible: false) }
        ) {
            statusView

            Button(action: model.refreshTests) {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh discovered tests")
            .disabled(service.isRunning)

            if service.isRunning {
                Button(action: model.stopTests) {
                    Image(systemName: "stop.fill")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.warning)
                .help("Stop test run")
            }

            Button(action: service.clearOutput) {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear test output")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch service.state {
        case .idle:
            EmptyView()
        case .running:
            Label("Running", systemImage: "circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.success)
        case .passed:
            Label("Passed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.success)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.error)
        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.warning)
        }
    }

    private var testProviderDescriptors: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.testing) }
            .filter { !(service.itemsByProviderID[$0.id] ?? []).isEmpty }
    }

    private var testCount: Int {
        service.itemsByProviderID.values.reduce(0) { count, items in
            count + itemCount(items)
        }
    }

    private var selectedItem: LanguageTestItem? {
        guard let selectedItemID else { return nil }
        return service.itemsByProviderID.values
            .flatMap { $0 }
            .first { $0.id == selectedItemID }
    }

    private var testItemList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Tests")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    isItemListCollapsed = true
                } label: {
                    Image(systemName: "chevron.left")
                }
                .litheIconButton()
                .help("Hide test list")
                .accessibilityLabel("Hide test list")
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 30)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(testProviderDescriptors) { descriptor in
                        providerSection(descriptor)
                    }
                }
                .padding(7)
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private func providerSection(_ descriptor: LanguageProviderDescriptor) -> some View {
        let items = service.itemsByProviderID[descriptor.id] ?? []
        let isCollapsed = collapsedProviderIDs.contains(descriptor.id)

        return VStack(alignment: .leading, spacing: 1) {
            Button {
                if isCollapsed {
                    collapsedProviderIDs.remove(descriptor.id)
                } else {
                    collapsedProviderIDs.insert(descriptor.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    providerIcon(for: descriptor)
                        .frame(width: 14, height: 14)
                    Text(descriptor.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(itemCount(items)))
                        .font(.system(size: 10))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .litheRowHover(isActive: false, cornerRadius: 5, activeBackground: LitheTheme.subtleSelection)

            if !isCollapsed {
                ForEach(items) { item in
                    testItemRow(item)
                }
            }
        }
    }

    private func testItemRow(_ item: LanguageTestItem) -> some View {
        Button {
            selectedItemID = item.id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: testItemIcon(item))
                    .font(.system(size: 11))
                    .foregroundStyle(item.depth > 0 ? LitheTheme.accent : LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(item.label)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 25 + CGFloat(item.depth * 14))
            .padding(.trailing, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: selectedItemID == item.id,
                cornerRadius: 5,
                activeBackground: LitheTheme.selection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private var collapsedItemListBar: some View {
        VStack(spacing: 0) {
            Button {
                isItemListCollapsed = false
            } label: {
                Image(systemName: "chevron.right")
            }
            .litheIconButton()
            .help("Show test list")
            .accessibilityLabel("Show test list")
            .frame(height: 30)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var selectedTestContent: some View {
        if let item = selectedItem,
           let workspaceURL = model.workspaceURL {
            VStack(spacing: 0) {
                testDetail(item)
                    .frame(maxHeight: 220, alignment: .top)
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(height: 1)
                OutputTextView(
                    output: service.output,
                    searchRoots: [workspaceURL],
                    fileExists: { model.fileExists(at: $0) },
                    emptyMessage: "Run a test to see its output."
                ) { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
            }
            .litheWorkbenchSurface(LitheTheme.editor)
        } else {
            emptyState("Select a test scope to view its details.")
        }
    }

    private func testDetail(_ item: LanguageTestItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: testItemIcon(item))
                    .font(.system(size: 20))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(LitheTheme.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.system(size: 14, weight: .semibold))
                        .textSelection(.enabled)
                    Text(providerName(for: item.providerID))
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Button {
                    model.runTest(providerID: item.providerID, scope: scope(for: item))
                } label: {
                    Label(service.isRunning ? "Running" : "Run", systemImage: service.isRunning ? "hourglass" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(service.isRunning)

                if item.providerID == "java", item.kind != .workspace {
                    Button {
                        model.debugTest(providerID: item.providerID, scope: scope(for: item))
                    } label: {
                        Label("Debug", systemImage: "ladybug.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.isRunning)
                }
            }

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Scope")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 90, alignment: .trailing)
                Text(scopeDescription(item))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
            }

            if let plan = service.activePlan,
               plan.providerID == item.providerID,
               plan.label == item.label {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Command")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 90, alignment: .trailing)
                    Text(commandDescription(plan.launchPlan))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scope(for item: LanguageTestItem) -> LanguageTestScope {
        switch item.kind {
        case .workspace:
            return .workspace
        case .file:
            return .file(item.fileURL ?? model.workspaceURL ?? URL(fileURLWithPath: "."))
        case .testCase:
            return .testCase(
                identifier: item.testIdentifier ?? item.label,
                fileURL: item.fileURL
            )
        }
    }

    private func itemCount(_ items: [LanguageTestItem]) -> Int {
        let exactTests = items.filter { $0.kind == .testCase }.count
        return exactTests > 0 ? exactTests : items.filter { $0.kind != .workspace }.count
    }

    private func testItemIcon(_ item: LanguageTestItem) -> String {
        switch item.kind {
        case .workspace: "square.stack.3d.up"
        case .file: "doc.text.magnifyingglass"
        case .testCase: item.depth > 1 ? "function" : "cube"
        }
    }

    private func scopeDescription(_ item: LanguageTestItem) -> String {
        switch item.kind {
        case .workspace:
            return "Workspace"
        case .file:
            return item.fileURL?.path ?? item.label
        case .testCase:
            return item.testIdentifier ?? item.label
        }
    }

    private func providerName(for providerID: String) -> String {
        model.languageProviderCatalog.descriptors.first { $0.id == providerID }?.displayName ?? providerID
    }

    @ViewBuilder
    private func providerIcon(for descriptor: LanguageProviderDescriptor) -> some View {
        if let kind = Self.iconKind(for: descriptor.id) {
            LitheIcon(kind: kind, size: 14)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
        }
    }

    private static func iconKind(for providerID: String) -> LitheIconKind? {
        switch providerID {
        case "java": .javaGeneric
        case "go": .goSource
        case "python": .pythonSource
        case "node": .javaScript
        case "rust": .rustSource
        default: nil
        }
    }

    private func commandDescription(_ plan: SharedLaunchPlan) -> String {
        let executable: String
        switch plan.executable {
        case .toolchain(let id): executable = "toolchain:\(id)"
        case .command(let command): executable = command
        }
        let arguments = plan.arguments.joined(separator: " ")
        return arguments.isEmpty ? executable : executable + " " + arguments
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func selectDefaultItemIfNeeded() {
        let allItems = service.itemsByProviderID.values.flatMap { $0 }
        guard !allItems.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let selectedItemID,
              allItems.contains(where: { $0.id == selectedItemID }) else {
            let item = allItems.first(where: { $0.kind == .workspace }) ?? allItems[0]
            self.selectedItemID = item.id
            return
        }
    }
}
