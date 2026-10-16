import AppKit
import SwiftUI

struct ProblemsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var diagnosticsStore: EditorDiagnosticsStore
    private let runnableFileURLs: Set<URL>
    @State private var scope = ProblemsPanelScope.file
    @State private var toolWindowActive = false
    @State private var resultListActive = false
    @State private var previewEnabled = false
    @State private var selectedDiagnosticID: String?
    @State private var resolvedFileIcons: [URL: LitheIconKind] = [:]
    @State private var severityFilter = Set(DiagnosticSeverity.allCases)

    init(initialScope: ProblemsPanelScope = .file, previewEnabled: Bool = false,
         runnableFileURLs: Set<URL> = []) {
        self.runnableFileURLs = runnableFileURLs
        _scope = State(initialValue: initialScope)
        _previewEnabled = State(initialValue: previewEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if previewEnabled, let selectedDiagnostic {
                GeometryReader { geometry in
                    LitheSplitPaneView(
                        axis: .horizontal, placement: .leading,
                        defaultSize: geometry.size.width * 0.5,
                        minimum: 120, maximum: max(120, geometry.size.width - 120),
                        flexibleMinimum: 120
                    ) {
                        listWithToolbar
                    } flexible: {
                        ProblemsSourcePreview(diagnostic: selectedDiagnostic) { url in
                            await model.documentFeature.previewDocument(at: url)
                        }
                        .id(selectedDiagnostic.fileURL)
                    }
                }
            } else {
                listWithToolbar
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheToolWindowActivityTracker(isActive: $toolWindowActive))
    }

    private var listWithToolbar: some View {
        HStack(spacing: 0) {
            toolbar
            problemList
        }
    }

    private var selectedDiagnostic: EditorDiagnostic? {
        diagnostics.first { $0.id == selectedDiagnosticID } ?? diagnostics.first
    }

    private var toolbar: some View {
        VStack(spacing: 2) {
            LitheMenu {
                LitheContextMenuItem.action(
                    "All severities",
                    systemImage: severityFilter.count == DiagnosticSeverity.allCases.count
                        ? "checkmark" : "circle"
                ) {
                    severityFilter = Set(DiagnosticSeverity.allCases)
                }

                LitheContextMenuItem.separator

                for severity in DiagnosticSeverity.allCases {
                    LitheContextMenuItem.action(
                        severity.title, systemImage: severityFilter.contains(severity) ? "checkmark" : "circle"
                    ) {
                        if severityFilter.contains(severity) {
                            severityFilter.remove(severity)
                        } else {
                            severityFilter.insert(severity)
                        }
                    }
                }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/show.svg", size: 16,
                              fallbackSystemImage: "line.3.horizontal.decrease", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .help("View Options")
            .accessibilityLabel("View Options")

            Button { previewEnabled.toggle() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/previewVertically.svg", size: 16,
                              fallbackSystemImage: "rectangle.lefthalf.inset.filled", preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: previewEnabled))
            .disabled(selectedDiagnostic == nil)
            .help("Show Editor Preview")
            .accessibilityLabel("Show Editor Preview")
            .accessibilityValue(previewEnabled ? "On" : "Off")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private var problemList: some View {
        let selectedID = selectedDiagnostic?.id
        return Group {
            if diagnostics.isEmpty {
                ProblemsEmptyState(
                    title: scope.emptyTitle(currentFileURL: currentFileURL),
                    details: (scope == .file && currentFileURL == nil)
                        || severityFilter.count == DiagnosticSeverity.allCases.count
                        ? nil : LocalizedStringKey("Problems could be filtered out")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diagnosticGroups, id: \.key) { group in
                                fileHeader(group.key, count: group.value.count)
                                ForEach(group.value) { diagnostic in
                                    diagnosticRow(diagnostic, isSelected: selectedID == diagnostic.id)
                                }
                            }
                        }
                        .padding(.vertical, LitheTheme.Tree.verticalInset)
                    }
                    .onChange(of: selectedDiagnosticID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .focusable()
                .litheFocusEffectHidden()
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down,
                          let selected = selectedDiagnostic,
                          let index = diagnostics.firstIndex(where: { $0.id == selected.id }) else { return }
                    let next = min(max(index + (direction == .up ? -1 : 1), 0), diagnostics.count - 1)
                    selectedDiagnosticID = diagnostics[next].id
                }
                .onCommand(#selector(NSResponder.insertNewline(_:))) {
                    if let selectedDiagnostic { model.openDiagnostic(selectedDiagnostic) }
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheToolWindowActivityTracker(isActive: $resultListActive))
    }

    private var currentFileURL: URL? {
        ProblemsPanelScope.currentFileURL(in: model)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Problems")
                .font(LitheTheme.uiFont(size: 13, weight: .bold))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.trailing, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProblemsPanelScope.allCases, id: \.self) { tab in
                        Button { scope = tab } label: {
                            HStack(spacing: 6) {
                                Text(tab.title)
                                if tab == scope, !diagnostics.isEmpty {
                                    Text(String(diagnostics.count))
                                        .foregroundStyle(LitheTheme.Tree.secondaryText)
                                }
                            }
                            .font(LitheTheme.uiFont(size: 13))
                            .foregroundStyle(LitheTheme.primaryText)
                            .padding(.horizontal, 8)
                            .modifier(LitheToolWindowTabStyle(isSelected: scope == tab, isActive: toolWindowActive))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.litheNoPress)
                        .accessibilityAddTraits(scope == tab ? [.isSelected] : [])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if errorCount > 0 {
                severityCount(.error, count: errorCount)
            }
            if warningCount > 0 {
                severityCount(.warning, count: warningCount)
            }

            LitheSidebarHideButton(title: "Problems") {
                model.workbenchFeature.setVisibility(.problems, isVisible: false)
            }
        }
        .font(LitheTheme.uiFont(size: 13))
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 41)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) { LitheToolWindowHeaderDivider() }
        .litheContextMenu {
            [LitheContextMenuItem.action("Hide Problems Tool Window", systemImage: "minus") {
                model.workbenchFeature.setVisibility(.problems, isVisible: false)
            }]
        }
    }

    private var scopedDiagnostics: [EditorDiagnostic] {
        scope.diagnostics(in: diagnosticsStore.diagnosticsByURL, currentFileURL: currentFileURL)
            .sorted {
                let left = model.relativePath(for: $0.fileURL)
                let right = model.relativePath(for: $1.fileURL)
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.utf16Column < $1.utf16Column
            }
    }

    private var diagnostics: [EditorDiagnostic] {
        scopedDiagnostics.filter { severityFilter.contains($0.severity) }
    }

    private var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    private var diagnosticGroups: [(key: URL, value: [EditorDiagnostic])] {
        Dictionary(grouping: diagnostics, by: \.fileURL).sorted {
            let comparison = model.relativePath(for: $0.key)
                .localizedStandardCompare(model.relativePath(for: $1.key))
            return comparison == .orderedSame
                ? $0.key.path < $1.key.path : comparison == .orderedAscending
        }
    }

    private func fileHeader(_ url: URL, count: Int) -> some View {
        HStack(spacing: LitheTheme.Tree.iconTextGap) {
            LitheIcon(kind: resolvedFileIcons[url] ?? LitheIcons.kind(for: url, isDirectory: false),
                      size: LitheTheme.Tree.iconSize)
                .overlay {
                    if runnableFileURLs.contains(url) || model.runFeatureIfActive?.configurations.contains(where: {
                        $0.sourcePath == model.relativePath(for: url) && $0.mainClass?.isEmpty == false
                    }) == true {
                        LitheIDEAIcon(resourcePath: "expui/nodes/runnableMark.svg",
                                      size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                    }
                }
                .task(id: url) {
                    guard let kind = await model.javaIconKind(for: url), !Task.isCancelled else { return }
                    resolvedFileIcons[url] = kind
                }
            Text(url.lastPathComponent)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(model.relativePath(for: url.deletingLastPathComponent()))
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .truncationMode(.middle)
            Text(String(count))
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, LitheTheme.Tree.horizontalInset)
        .litheTreeRow()
        .help(model.relativePath(for: url))
        .accessibilityElement(children: .combine)
    }

    private func diagnosticRow(_ diagnostic: EditorDiagnostic, isSelected: Bool) -> some View {
        Button {
            selectedDiagnosticID = diagnostic.id
            if !previewEnabled { model.openDiagnostic(diagnostic) }
        } label: {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                severityIcon(diagnostic.severity)
                Text(diagnostic.message.replacingOccurrences(of: "\n", with: " "))
                    .layoutPriority(1)
                Text(":\(diagnostic.line + 1):\(diagnostic.utf16Column + 1)")
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
                    .fixedSize()
                if let source = diagnostic.source, !source.isEmpty {
                    Text(source).foregroundStyle(LitheTheme.Tree.secondaryText)
                }
                if let reason = diagnostic.reasonSummary {
                    Text(reason).foregroundStyle(LitheTheme.Tree.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.leading, LitheTheme.Tree.horizontalInset + LitheTheme.Tree.indent)
            .padding(.trailing, LitheTheme.Tree.horizontalInset)
            .litheTreeRow(isSelected: isSelected,
                          isFocused: resultListActive)
        }
        .buttonStyle(.litheNoPress)
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openDiagnostic(diagnostic) })
        .help(diagnostic.locationTitle + "\n" + diagnostic.detailText)
        .accessibilityLabel(diagnostic.locationTitle + ": " + diagnostic.detailText)
    }

    private func severityCount(_ severity: DiagnosticSeverity, count: Int) -> some View {
        HStack(spacing: 4) {
            severityIcon(severity, inspection: false)
            Text(String(count))
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(severity.title): \(count)")
    }

    private func severityIcon(_ severity: DiagnosticSeverity, inspection: Bool = true) -> some View {
        let resourcePath: String = switch severity {
        case .error: inspection ? "expui/general/inspections/inspectionsError.svg" : "expui/status/error.svg"
        case .warning: inspection ? "expui/general/inspections/inspectionsWarning.svg" : "expui/status/warning.svg"
        case .information: "expui/status/info.svg"
        case .hint: "expui/codeInsight/intentionBulbGrey.svg"
        case .unknown: "expui/general/questionMark.svg"
        }
        return LitheIDEAIcon(
            resourcePath: resourcePath,
            size: LitheTheme.Tree.iconSize,
            fallbackSystemImage: severity.systemImage,
            preservesOriginalColors: !inspection || (severity != .error && severity != .warning)
        )
        .foregroundStyle(severity == .error ? LitheTheme.error : LitheTheme.warning)
    }

}

/// File/Project Errors only change presentation; the workspace diagnostic store retains every file.
enum ProblemsPanelScope: CaseIterable {
    case file
    case projectErrors

    var title: LocalizedStringKey {
        switch self {
        case .file: "File"
        case .projectErrors: "Project Errors"
        }
    }

    @MainActor
    static func currentFileURL(in model: AppModel) -> URL? {
        // Match FileEditorManager.selectedEditor, including non-text editor selection.
        guard !model.isAgentEditorSelected, !model.isDatabaseWorkspaceSelected, !model.isRepositoryDiffSelected,
              model.gitFeatureIfActive?.selectedChange == nil,
              model.gitFeatureIfActive?.branchComparison == nil,
              model.activeEditorTerminalSession == nil,
              model.activeMediaDocument == nil else { return nil }
        return model.activeDocument?.url.standardizedFileURL
    }

    func diagnostics(in byURL: [URL: [EditorDiagnostic]], currentFileURL: URL?) -> [EditorDiagnostic] {
        switch self {
        case .file:
            guard let currentFileURL else { return [] }
            return byURL[currentFileURL.standardizedFileURL] ?? []
        case .projectErrors:
            return byURL.values.flatMap { $0 }
        }
    }

    func emptyTitle(currentFileURL: URL?) -> LocalizedStringKey {
        switch self {
        case .file:
            guard let currentFileURL else {
                return "Open file in editor to see problems"
            }
            return "No problems in \(currentFileURL.lastPathComponent)"
        case .projectErrors:
            return "No problems"
        }
    }
}

struct ProblemsEmptyState: View {
    let title: LocalizedStringKey
    let details: LocalizedStringKey?
    var bundle: Bundle = .main

    var body: some View {
        // Community StatusText: x=(width-textWidth)/2, y=(height-textHeight)/3.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text(title, bundle: bundle)
                if let details { Text(details, bundle: bundle) }
            }
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(LitheTheme.Tree.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// The preview shares live document text but has its own read-only Monaco presentation.
struct ProblemsSourcePreview: View {
    let diagnostic: EditorDiagnostic
    let loadDocument: (URL) async -> EditorDocument?
    @State private var document: EditorDocument?
    @State private var isLoading = true
    @State private var presentationID = UUID()

    var body: some View {
        Group {
            if let document {
                MonacoWorkbenchEditor(document: document, preview: MonacoPreviewConfiguration(
                    line: diagnostic.line + 1, query: "", matchCase: false, wholeWord: false, regex: false,
                    utf16Column: diagnostic.utf16Column, presentationID: presentationID))
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProblemsEmptyState(title: "Could not load file preview", details: nil)
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .clipped()
        .task(id: diagnostic.fileURL) {
            isLoading = true
            document = nil
            let loaded = await loadDocument(diagnostic.fileURL)
            guard !Task.isCancelled else { return }
            document = loaded
            isLoading = false
        }
    }
}
