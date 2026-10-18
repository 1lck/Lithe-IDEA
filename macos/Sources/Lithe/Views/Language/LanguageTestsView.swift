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
    @State private var testDurations: [String: String] = [:]
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
            updateResultsAndDurations()
        }
        .onChange(of: service.results) { _ in
            updateResultsAndDurations()
            selectDefaultItemIfNeeded()
        }
        .onChange(of: service.output) { _ in
            updateResultsAndDurations()
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
                .disabled(service.isRunning || item.fileURL == nil)
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
        return testProviderDescriptors
            .flatMap { presentedItems(for: $0.id) }
            .first { $0.id == selectedItemID }
    }

    private var testItemList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(testProviderDescriptors) { descriptor in
                    providerSection(descriptor)
                }
            }
            .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            .padding(.vertical, LitheTheme.Tree.verticalInset)
        }
        .litheScrollViewChrome()
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func presentedItems(for providerID: String) -> [LanguageTestItem] {
        Self.presentedItems(discovered: service.itemsByProviderID[providerID] ?? [],
            results: service.results, resultProviderID: service.activePlan?.providerID, providerID: providerID)
    }

    /// Selection and rendering consume the same nodes, including report-only results.
    static func presentedItems(discovered: [LanguageTestItem], results: MavenTestResults?, resultProviderID: String?, providerID: String) -> [LanguageTestItem] {
        guard resultProviderID == providerID, let outcomes = results?.testCases else { return discovered }
        let statuses = resultStatuses(outcomes)
        let reported = discovered.filter { $0.kind == .testCase && statuses[resultKey($0)] != nil }
        if !reported.isEmpty { return reported }
        return outcomes.isEmpty ? discovered : synthesizeResultItems(from: outcomes, providerID: providerID)
    }

    private func providerSection(_ descriptor: LanguageProviderDescriptor) -> some View {
        let items = presentedItems(for: descriptor.id)
        let isResultTree = !items.isEmpty && items.allSatisfy { $0.kind == .testCase }

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
                        LitheIDEAIcon(resourcePath: "expui/general/chevron\(isCollapsed ? "Right" : "Down").svg",
                            size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
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
                    testItemRow(item, hasChildren: parentIDs.contains(item.id), usesResultTree: isResultTree)
                }
            }
        }
    }

    private func testItemRow(_ item: LanguageTestItem, hasChildren: Bool, usesResultTree: Bool) -> some View {
        let isCollapsed = collapsedTestIDs.contains(item.id)
        let selected = selectedItemID == item.id
        let ownsResults = service.activePlan?.providerID == item.providerID
        let status = ownsResults ? resultStatuses[Self.resultKey(item)] : nil
        let duration = ownsResults ? testDurations[Self.resultKey(item)] : nil
        return HStack(spacing: LitheTheme.Tree.iconTextGap) {
            if hasChildren {
                Button {
                    if isCollapsed { collapsedTestIDs.remove(item.id) }
                    else { collapsedTestIDs.insert(item.id) }
                } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/chevron\(isCollapsed ? "Right" : "Down").svg",
                        size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
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
                    if status == nil, item.kind == .file {
                        LitheIcon(kind: item.fileURL.map { LitheIcons.kind(for: $0, isDirectory: false) } ?? .generic,
                                  size: LitheTheme.Tree.iconSize)
                    } else {
                        LitheIDEAIcon(resourcePath: Self.testItemIcon(status: status, kind: item.kind, hasChildren: hasChildren),
                                      size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                    }
                    HStack(spacing: 4) {
                        Text(item.label)
                            .font(LitheTheme.uiFont(size: 13, weight: .regular))
                            .foregroundStyle(LitheTheme.Tree.text)
                            .lineLimit(1)
                        if let duration, !duration.isEmpty {
                            Text(hasChildren ? ": \(duration)" : duration)
                                .font(LitheTheme.uiFont(size: 11, weight: .regular))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard hasChildren else { return }
                if isCollapsed { collapsedTestIDs.remove(item.id) }
                else { collapsedTestIDs.insert(item.id) }
            })
            .accessibilityValue(Text(status == "Ignored" ? localization.text("Skipped") : status.map(localization.text) ?? ""))
        }
        .padding(.leading, CGFloat(max(0, item.depth - (usesResultTree ? 1 : 0))) * LitheTheme.Tree.indent)
        .padding(.trailing, 4)
        .litheTreeRow(isSelected: selected, isFocused: itemListActive)
    }

    static func parseDurations(
        from output: String,
        outcomes: [MavenTestCaseOutcome] = []
    ) -> [String: String] {
        var durations: [String: String] = [:]

        // Class duration line: Time elapsed: 0.582 s -- in demo.CalculatorTest
        if let classRegex = try? NSRegularExpression(
            pattern: #"Time elapsed:\s*([0-9]+(?:\.[0-9]+)?)\s*s\s*--?\s*in\s+([A-Za-z0-9_$.]+)"#
        ) {
            let matches = classRegex.matches(in: output, range: NSRange(output.startIndex..., in: output))
            for match in matches {
                if let timeRange = Range(match.range(at: 1), in: output),
                   let classRange = Range(match.range(at: 2), in: output) {
                    let timeStr = String(output[timeRange])
                    let fullClassName = String(output[classRange])
                    if let sec = Double(timeStr) {
                        let formatted = formatDuration(seconds: sec)
                        if durations[fullClassName] == nil {
                            durations[fullClassName] = formatted
                            let shortName = fullClassName.split(separator: ".").last.map(String.init) ?? fullClassName
                            durations[shortName] = formatted
                        }
                    }
                }
            }
        }

        for outcome in outcomes {
            guard let milliseconds = outcome.durationMillis, milliseconds >= 0 else { continue }
            let method = outcome.method.split(separator: "(", maxSplits: 1).first.map(String.init) ?? outcome.method
            durations[outcome.className + "#" + method] = formatDuration(seconds: Double(milliseconds) / 1000)
        }

        return durations
    }

    static func formatDuration(seconds: Double) -> String {
        if seconds < 1.0 {
            let ms = Int(round(seconds * 1000.0))
            return "\(ms) ms"
        } else {
            let rounded = round(seconds * 100.0) / 100.0
            if rounded.truncatingRemainder(dividingBy: 1.0) == 0 {
                return "\(Int(rounded)) s"
            } else {
                return String(format: "%.2f s", rounded)
            }
        }
    }

    static func synthesizeResultItems(
        from outcomes: [MavenTestCaseOutcome],
        providerID: String
    ) -> [LanguageTestItem] {
        var classOrder: [String] = []
        var classGroups: [String: [MavenTestCaseOutcome]] = [:]
        for outcome in outcomes {
            if classGroups[outcome.className] == nil {
                classOrder.append(outcome.className)
            }
            classGroups[outcome.className, default: []].append(outcome)
        }

        var items: [LanguageTestItem] = []
        for fullClassName in classOrder {
            let shortClassName = fullClassName.split(separator: ".").last.map(String.init) ?? fullClassName
            let methods = classGroups[fullClassName] ?? []
            let classNode = LanguageTestItem(
                id: "testCase:\(providerID):\(fullClassName)",
                providerID: providerID,
                label: shortClassName,
                kind: .testCase,
                fileURL: nil,
                testIdentifier: fullClassName,
                depth: 1
            )
            items.append(classNode)

            for outcome in methods {
                let methodName = outcome.method.split(separator: "(", maxSplits: 1).first.map(String.init) ?? outcome.method
                let methodID = "\(fullClassName)#\(methodName)"
                let methodNode = LanguageTestItem(
                    id: "testCase:\(providerID):\(methodID)",
                    providerID: providerID,
                    label: methodName,
                    kind: .testCase,
                    fileURL: nil,
                    testIdentifier: methodID,
                    depth: 2
                )
                items.append(methodNode)
            }
        }
        return items
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
            if statuses.contains("error") { return "Error" }
            if statuses.contains("failed") { return "Failed" }
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

    private func updateResultsAndDurations() {
        let outcomes = service.results?.testCases ?? []
        resultStatuses = Self.resultStatuses(outcomes)
        testDurations = Self.parseDurations(from: service.output, outcomes: outcomes)
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
                if service.state != .idle || service.results != nil { testSummary }
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
        HStack(spacing: LitheTheme.TestResult.summaryDescriptionGap) {
            if let results = service.results {
                HStack(spacing: LitheTheme.TestResult.summaryIconTextGap) {
                    LitheIDEAIcon(resourcePath: Self.summaryIcon(for: results, state: service.state), size: 16,
                                  preservesOriginalColors: true)
                    if Self.runFailed(service.state), results.failures + results.errors == 0 {
                        Text(LocalizedStringKey(Self.summaryText(for: service.state)))
                            .foregroundStyle(LitheTheme.TestResult.failedText)
                    }
                    summaryCounts(results)
                }
                Text(localization.number(results.testsRun == 1 ? "%lld test total" : "%lld tests total", results.testsRun))
                    .foregroundStyle(LitheTheme.TestResult.descriptionText)
            } else {
                Text(LocalizedStringKey(Self.summaryText(for: service.state)))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .font(LitheTheme.TestResult.summaryFont)
        .lineLimit(1)
        .foregroundStyle(LitheTheme.searchFieldText)
        .padding(.leading, LitheTheme.TestResult.summaryLeadingInset)
        .padding(.trailing, 8)
        .frame(height: LitheTheme.Metrics.toolbarIconButtonSize + 2 * LitheTheme.ActionStripe.topInset)
        .litheWorkbenchSurface(LitheTheme.editor)
        .overlay(alignment: .bottom) {
            if let color = resultStripeColor {
                Capsule()
                    .fill(color)
                    .frame(height: LitheTheme.TestResult.stripeHeight)
                    .padding(.trailing, LitheTheme.ActionStripe.width + 1)
                    .allowsHitTesting(false)
            }
        }
    }

    static func summaryText(for state: LanguageTestRunState) -> String {
        switch state {
        case .idle: "Run a test to see its results."
        case .running: "Running"
        case .passed: "Passed"
        case .failed: "Failed"
        case .timedOut: "Timed Out"
        case .cancelled: "Cancelled"
        }
    }

    private var resultStripeColor: Color? {
        if Self.runFailed(service.state) { return LitheTheme.TestResult.failed }
        if service.state == .cancelled { return nil }
        if let results = service.results {
            if results.failures + results.errors > 0 { return LitheTheme.TestResult.failed }
            return results.passed > 0 ? LitheTheme.TestResult.passed : nil
        }
        switch service.state {
        case .passed: return LitheTheme.TestResult.passed
        case .failed, .timedOut: return LitheTheme.TestResult.failed
        default: return nil
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

    private func summaryCounts(_ results: MavenTestResults) -> Text {
        let failed = results.failures + results.errors
        let separator = localization.text(", ")
        var fragments: [Text] = []
        if failed > 0 {
            let format = failed == 1 ? "%lld test failed" : "%lld tests failed"
            fragments.append(Text(localization.number(format, failed) + (results.passed + results.skipped > 0 ? separator : ""))
                .foregroundColor(LitheTheme.TestResult.failedText))
        }
        if results.passed > 0 {
            let format = failed + results.skipped == 0
                ? (results.passed == 1 ? "%lld test passed" : "%lld tests passed") : "%lld passed"
            fragments.append(Text(localization.number(format, results.passed) + (results.skipped > 0 ? separator : "")))
        }
        if results.skipped > 0 {
            let format = failed + results.passed == 0
                ? (results.skipped == 1 ? "%lld test ignored" : "%lld tests ignored") : "%lld ignored"
            fragments.append(Text(localization.number(format, results.skipped))
                .foregroundColor(LitheTheme.TestResult.ignoredText))
        }
        return fragments.reduce(Text(""), +).font(LitheTheme.TestResult.summaryFont)
    }

    static func runFailed(_ state: LanguageTestRunState) -> Bool {
        switch state {
        case .failed, .timedOut: true
        default: false
        }
    }

    static func summaryIcon(for results: MavenTestResults, state: LanguageTestRunState = .idle) -> String {
        let status: String
        if results.failures > 0 { status = "Failed" }
        else if results.errors > 0 || runFailed(state) { status = "Error" }
        else if results.passed > 0 { status = results.skipped > 0 ? "PassedIgnored" : "Passed" }
        else { status = results.skipped > 0 ? "Ignored" : "NotRunYet" }
        return "expui/run/test\(status).svg"
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

    static func testItemIcon(status: String?, kind: LanguageTestItemKind? = nil, hasChildren: Bool = false) -> String {
        if let status { return "expui/run/test\(status).svg" }
        switch kind {
        case .workspace: return "expui/nodes/testGroup.svg"
        case .testCase: return "expui/nodes/\(hasChildren ? "class" : "method").svg"
        case .file: return "fileTypes/unknown.svg"
        case nil: return "expui/run/testNotRunYet.svg"
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
            LitheIcon(kind: kind, size: LitheTheme.Tree.iconSize)
        } else {
            Color.clear.frame(width: LitheTheme.Tree.iconSize, height: LitheTheme.Tree.iconSize)
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
        let allItems = testProviderDescriptors.flatMap { presentedItems(for: $0.id) }
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
