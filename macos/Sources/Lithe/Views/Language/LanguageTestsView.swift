import SwiftUI
import LitheExecutionModule

/// Language-neutral test tool window. Discovery is metadata-only; a process is
/// created only after the user chooses a workspace or file item and presses Run.
struct LanguageTestsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: LanguageTestService

    @State private var testToolActive = false
    @State private var itemListActive = false
    @State private var selectedItemID: String?
    @State private var collapsedProviderIDs: Set<String> = []
    @AppStorage("lithe.tests.itemListWidth") private var itemListWidth = 250.0
    @AppStorage("lithe.tests.itemListCollapsed") private var isItemListCollapsed = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var inspectorTab = "Performance"
    @State private var detailsExpanded = false
    @AppStorage("lithe.tests.detailsWidth") private var detailsWidth = 300.0
    @State private var wrapsLines = false
    @State private var consolePresentation = ConsoleFoldPresentation()
    @State private var resultStatuses: [String: String] = [:]
    @State private var collapsedTestIDs: Set<String> = []

    private var localization: LanguageTestLocalization {
        LanguageTestLocalization(language: model.settings.language)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader
            testToolbar

            if let message = service.errorMessage {
                Text(localization.error(message))
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(LitheTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

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
                            sized: { testItemList.background(LitheToolWindowActivityTracker(isActive: $itemListActive)) },
                            flexible: { selectedTestContent }
                        )
                    }
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheToolWindowActivityTracker(isActive: $testToolActive))
        .onAppear {
            selectDefaultItemIfNeeded()
            syncPerformance()
            resultStatuses = Self.resultStatuses(service.results?.testCases ?? [])
        }
        .onChange(of: service.results) { results in
            resultStatuses = Self.resultStatuses(results?.testCases ?? [])
        }
        .onChange(of: service.itemsByProviderID) { _ in selectDefaultItemIfNeeded() }
    }

    private var toolWindowHeader: some View {
        HStack(spacing: 0) {
            Text("Tests")
                .font(LitheTheme.uiFont(size: 13, weight: .bold))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.trailing, 16)
            if let plan = service.activePlan {
                testRunTab(plan.label)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 12)
            LitheMenu {
                LitheContextMenuItem.action("Show test list", checked: !isItemListCollapsed) {
                    isItemListCollapsed.toggle()
                }
                LitheContextMenuItem.action("Refresh discovered tests", isEnabled: !service.isRunning) {
                    model.refreshTests()
                }
                LitheContextMenuItem.action("Clear test output", action: service.clearOutput)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/moreVertical.svg", size: 16,
                              fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .padding(.horizontal, 2)
            .help("More Test actions")
            LitheSidebarHideButton(title: "Tests") {
                model.workbenchFeature.setVisibility(.tests, isVisible: false)
            }
            .padding(.horizontal, 2)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 41)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) { LitheToolWindowHeaderDivider() }
    }

    private func testRunTab(_ title: String) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                LitheIDEAIcon(resourcePath: "expui/runConfigurations/junit.svg", size: 16,
                              fallbackSystemImage: "play", preservesOriginalColors: true)
                Text(title)
                    .font(LitheTheme.uiFont(size: 13))
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 3)
            LitheToolWindowTabCloseButton(action: service.closeRun)
                .help("Close test run")
                .accessibilityLabel("Close test run")
        }
        .foregroundStyle(LitheTheme.primaryText)
        .modifier(LitheToolWindowTabStyle(isSelected: true, isActive: testToolActive))
    }

    private var testToolbar: some View {
        HStack(spacing: 4) {
            Button {
                guard let item = selectedItem else { return }
                model.runTest(providerID: item.providerID, scope: scope(for: item))
            } label: {
                LitheIDEAIcon(resourcePath: selectedItemWasRun ? "debugger/rerun.svg" : "expui/run/run.svg", size: 16,
                              fallbackSystemImage: "play", preservesOriginalColors: true, usesIDEADisabledAppearance: true)
            }
            .litheToolbarIconButton()
            .help(selectedItemWasRun ? localization.text("Rerun last test") : "Run selected test")
            .accessibilityLabel(selectedItemWasRun ? "Rerun selected test" : "Run selected test")
            .disabled(service.isRunning || selectedItem == nil || model.workspaceURL == nil)

            Button(action: model.stopTests) {
                LitheIDEAIcon(resourcePath: "expui/run/stop.svg", size: 16,
                              fallbackSystemImage: "stop.fill", preservesOriginalColors: true, usesIDEADisabledAppearance: true)
            }
            .litheToolbarIconButton()
            .help("Stop test run")
            .disabled(!service.isRunning)

            if let item = selectedItem, item.providerID == "java", item.kind != .workspace {
                Button {
                    model.debugTest(providerID: item.providerID, scope: scope(for: item))
                } label: {
                    LitheIDEAIcon(resourcePath: "expui/run/debug.svg", size: 16,
                                  fallbackSystemImage: "ladybug", preservesOriginalColors: true, usesIDEADisabledAppearance: true)
                }
                .litheToolbarIconButton()
                .help("Debug selected test")
                .disabled(service.isRunning)
            }

            Button(action: model.refreshTests) {
                LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: 16,
                              fallbackSystemImage: "arrow.clockwise", preservesOriginalColors: true, usesIDEADisabledAppearance: true)
            }
            .litheToolbarIconButton()
            .help("Refresh discovered tests")
            .disabled(service.isRunning)

            Button(action: service.clearOutput) {
                LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: 16,
                              fallbackSystemImage: "trash", preservesOriginalColors: true, usesIDEADisabledAppearance: true)
            }
            .litheToolbarIconButton()
            .help("Clear test output")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) { LitheToolWindowHeaderDivider() }
    }

    private var selectedItemWasRun: Bool {
        guard let item = selectedItem else { return false }
        return service.hasRun(providerID: item.providerID, scope: scope(for: item))
    }

    private var testProviderDescriptors: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.testing) }
            .filter { !(service.itemsByProviderID[$0.id] ?? []).isEmpty }
    }

    private var selectedItem: LanguageTestItem? {
        guard let selectedItemID else { return nil }
        return service.itemsByProviderID.values
            .flatMap { $0 }
            .first { $0.id == selectedItemID }
    }

    private var testItemList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(testProviderDescriptors) { descriptor in
                    providerSection(descriptor)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, LitheTheme.Tree.verticalInset)
        }
        .litheScrollViewChrome()
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func providerSection(_ descriptor: LanguageProviderDescriptor) -> some View {
        let discovered = service.itemsByProviderID[descriptor.id] ?? []
        let reported = discovered.filter { $0.kind == .testCase && resultStatuses[Self.resultKey($0)] != nil }
        let items = reported.isEmpty ? discovered : reported
        let isCollapsed = collapsedProviderIDs.contains(descriptor.id)
        let parentIDs = Set(zip(items, items.dropFirst()).compactMap { current, next in
            next.depth > current.depth ? current.id : nil
        })

        return VStack(alignment: .leading, spacing: 0) {
            if testProviderDescriptors.count > 1 {
                Button {
                    if isCollapsed { collapsedProviderIDs.remove(descriptor.id) }
                    else { collapsedProviderIDs.insert(descriptor.id) }
                } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .frame(width: LitheTheme.Tree.disclosureSlot)
                        providerIcon(for: descriptor)
                        Text(descriptor.displayName).lineLimit(1)
                    }
                    .litheTreeRow()
                }
                .buttonStyle(.litheNoPress)
            }
            if !isCollapsed || testProviderDescriptors.count == 1 {
                ForEach(Self.visibleItems(items, collapsed: collapsedTestIDs)) { item in
                    testItemRow(item, hasChildren: parentIDs.contains(item.id), usesResultTree: !reported.isEmpty)
                }
            }
        }
    }

    private func testItemRow(_ item: LanguageTestItem, hasChildren: Bool, usesResultTree: Bool) -> some View {
        let isCollapsed = collapsedTestIDs.contains(item.id)
        let selected = selectedItemID == item.id
        let status = resultStatuses[Self.resultKey(item)]
        return HStack(spacing: LitheTheme.Tree.iconTextGap) {
            if hasChildren {
                Button {
                    if isCollapsed { collapsedTestIDs.remove(item.id) }
                    else { collapsedTestIDs.insert(item.id) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(LitheTheme.uiFont(size: 9))
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(isCollapsed ? "Expand test group" : "Collapse test group")
            } else {
                Color.clear.frame(width: LitheTheme.Tree.disclosureSlot)
            }
            Button {
                selectedItemID = item.id
            } label: {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    if let status {
                        LitheIDEAIcon(resourcePath: "expui/run/test\(status).svg", size: LitheTheme.Tree.iconSize,
                                      preservesOriginalColors: true)
                    } else {
                        Image(systemName: testItemIcon(item))
                            .frame(width: LitheTheme.Tree.iconSize)
                    }
                    Text(item.label).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .accessibilityValue(Text(status == "Ignored" ? localization.text("Skipped") : status.map(localization.text) ?? ""))
        }
        .padding(.leading, CGFloat(max(0, item.depth - (usesResultTree ? 1 : 0))) * LitheTheme.Tree.indent)
        .padding(.trailing, 4)
        .litheTreeRow(isSelected: selected, isFocused: itemListActive)
    }

    static func resultKey(_ item: LanguageTestItem) -> String {
        (item.testIdentifier ?? item.id).split(separator: "(", maxSplits: 1).first.map(String.init) ?? item.id
    }

    static func resultStatuses(_ outcomes: [MavenTestCaseOutcome]) -> [String: String] {
        var grouped: [String: [String]] = [:]
        for outcome in outcomes {
            let method = outcome.method.split(separator: "(", maxSplits: 1).first.map(String.init) ?? outcome.method
            grouped[outcome.className, default: []].append(outcome.status)
            grouped[outcome.className + "#" + method, default: []].append(outcome.status)
        }
        return grouped.compactMapValues { statuses in
            if statuses.contains("failed") || statuses.contains("error") { return "Failed" }
            if statuses.allSatisfy({ $0 == "skipped" }) { return "Ignored" }
            if statuses.allSatisfy({ $0 == "passed" || $0 == "skipped" }) { return "Passed" }
            return nil
        }
    }

    static func visibleItems(_ items: [LanguageTestItem], collapsed: Set<String>) -> [LanguageTestItem] {
        var hiddenBelowDepth: Int?
        return items.filter { item in
            if let depth = hiddenBelowDepth, item.depth > depth { return false }
            hiddenBelowDepth = collapsed.contains(item.id) ? item.depth : nil
            return true
        }
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

    private var selectedTestContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                LitheSplitPaneView(axis: .horizontal, placement: .trailing,
                    defaultSize: CGFloat(detailsWidth), minimum: 240,
                    maximum: max(240, geometry.size.width - 300), flexibleMinimum: 300,
                    clipsSizedPane: true, isSizedPaneCollapsed: !detailsExpanded,
                    dividerColor: LitheTheme.toolWindowBorder(for: colorScheme),
                    onCommit: { detailsWidth = Double($0) },
                    sized: { testInspector }, flexible: { testConsole })
                if !detailsExpanded {
                    LitheCollapsedActionStripe(title: inspectorTab, expandsToward: .leading) { detailsExpanded = true }
                        .litheWorkbenchSurface(LitheTheme.sidebar)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme)).frame(width: 1)
                        }
                }
            }
        }
        .onAppear { updatePerformanceVisibility() }
        .onChange(of: detailsExpanded) { _ in updatePerformanceVisibility() }
        .onChange(of: inspectorTab) { _ in updatePerformanceVisibility() }
        .onDisappear { model.testPerformanceFeature.setVisible(false) }
    }

    private func syncPerformance() {
        model.testPerformanceFeature.bind(to: service)
    }

    private func updatePerformanceVisibility() {
        model.testPerformanceFeature.setVisible(detailsExpanded && inspectorTab == "Performance")
    }

    private var testInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Performance", "Details"], id: \.self) { tab in
                    Button { inspectorTab = tab } label: {
                        Text(LocalizedStringKey(tab))
                            .font(LitheTheme.ActionStripe.titleFont)
                            .foregroundStyle(LitheTheme.ActionStripe.titleColor)
                            .padding(.horizontal, LitheTheme.ActionStripe.tabHorizontalInset)
                            .frame(height: LitheTheme.Metrics.toolbarHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .litheRowHover(cornerRadius: 0, hoverBackground: LitheTheme.ActionStripe.tabHover)
                    .overlay(alignment: .bottom) {
                        if inspectorTab == tab {
                            RoundedRectangle(cornerRadius: LitheTheme.ActionStripe.tabUnderlineRadius)
                                .fill(LitheTheme.ActionStripe.tabUnderline)
                                .frame(height: LitheTheme.ActionStripe.tabUnderlineHeight)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityAddTraits(inspectorTab == tab ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { detailsExpanded = false } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: 16, preservesOriginalColors: true)
                }
                .litheToolbarIconButton().help("Hide Details")
            }
            .padding(.horizontal, 6)
            .frame(height: LitheTheme.Metrics.toolbarHeight)
            LitheToolWindowHeaderDivider()
            if inspectorTab == "Performance" {
                TestJVMPerformanceView(feature: model.testPerformanceFeature)
            } else {
                ScrollView { if let item = selectedItem { testDetail(item) } }.litheScrollViewChrome()
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    @ViewBuilder
    private var testConsole: some View {
        if let workspaceURL = model.workspaceURL {
            VStack(spacing: 0) {
                testSummary
                OutputTextView(
                    output: service.output,
                    searchRoots: [workspaceURL],
                    fileExists: { model.fileExists(at: $0) },
                    emptyMessage: "Run a test to see its output.",
                    wrapsLines: wrapsLines,
                    showsConsoleToolbar: true,
                    consoleToolbarPlacement: .trailing,
                    onClearOutput: service.clearOutput,
                    consolePresentation: consolePresentation,
                    onToggleWrapsLines: { wrapsLines.toggle() }
                ) { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
            }
        }
    }

    private var testSummary: some View {
        HStack(spacing: 8) {
            if let results = service.results {
                LitheIDEAIcon(resourcePath: "expui/run/test\(results.success ? "Passed" : "Failed").svg", size: 16,
                              preservesOriginalColors: true)
                if results.failures + results.errors > 0 { resultCount("Failed", results.failures + results.errors, color: LitheTheme.error) }
                if results.passed > 0 { resultCount("Passed", results.passed, color: LitheTheme.primaryText) }
                if results.skipped > 0 { resultCount("Skipped", results.skipped, color: LitheTheme.warning) }
                Text(localization.count("Tests", results.testsRun)).foregroundStyle(LitheTheme.secondaryText)
            } else {
                Text(service.isRunning ? "Running tests…" : "Run a test to see its results.")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .font(LitheTheme.uiFont(size: 13))
        .padding(.horizontal, 8)
        .frame(height: LitheTheme.Metrics.toolbarIconButtonSize + 2 * LitheTheme.ActionStripe.topInset)
        .litheWorkbenchSurface(LitheTheme.editor)
        .overlay(alignment: .bottom) {
            if let results = service.results, results.failures + results.errors > 0 || results.passed > 0 {
                Capsule()
                    .fill(results.failures + results.errors > 0 ? LitheTheme.TestResult.failed : LitheTheme.TestResult.passed)
                    .frame(height: LitheTheme.TestResult.stripeHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private func testDetail(_ item: LanguageTestItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Scope")
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 90, alignment: .trailing)
                Text(scopeDescription(item))
                    .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
            }

            if let results = service.results {
                if !results.failureDetails.isEmpty {
                    testFailureList(results.failureDetails)
                }
            }

            if let plan = service.activePlan,
               plan.providerID == item.providerID,
               plan.label == item.label {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Command")
                        .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 90, alignment: .trailing)
                    Text(commandDescription(plan.launchPlan))
                        .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultCount(_ label: String, _ count: Int, color: Color) -> some View {
        Text(localization.count(label, count))
            .foregroundStyle(color)
    }

    private func testFailureList(_ failures: [LanguageTestFailureDetail]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localization.text("Failures"))
                .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            ForEach(failures) { failure in
                Button {
                    guard let fileURL = failure.fileURL else { return }
                    model.openSourceLocation(
                        url: fileURL,
                        line: failure.line ?? 1,
                        column: failure.column
                    )
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: failure.kind == "error" ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                            .foregroundStyle(failure.kind == "error" ? LitheTheme.warning : LitheTheme.error)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(failure.name)
                                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            if let message = failure.message, !message.isEmpty {
                                Text(message)
                                    .font(LitheTheme.uiFont(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        if let fileURL = failure.fileURL {
                            Text(fileURL.lastPathComponent + (failure.line.map { ":\($0)" } ?? ""))
                                .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.litheNoPress)
                .disabled(failure.fileURL == nil)
            }
        }
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

    @ViewBuilder
    private func providerIcon(for descriptor: LanguageProviderDescriptor) -> some View {
        if let kind = Self.iconKind(for: descriptor.id) {
            LitheIcon(kind: kind, size: 14)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(LitheTheme.uiFont(size: 10, weight: .medium))
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
                .font(LitheTheme.uiFont(size: 28))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(message)
                .font(LitheTheme.uiFont(size: 13))
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
