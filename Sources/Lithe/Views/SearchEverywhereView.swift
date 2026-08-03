import AppKit
import SwiftUI

enum SearchEverywhereScope: String, CaseIterable, Identifiable {
    case all = "All"
    case classes = "Classes"
    case files = "Files"
    case symbols = "Symbols"
    case text = "Text"
    case actions = "Actions"

    var id: String { rawValue }
}

/// IDEA 风格的全局搜索弹窗：分类标签、双栏结果和可执行 Actions 共用同一套键盘导航。
struct SearchEverywhereView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex = 0
    @State private var scope: SearchEverywhereScope = .all
    @State private var searchOptions = ProjectSearchOptions.default
    @State private var keyMonitor: Any?

    private enum SearchItem {
        case result(FileSearchResult)
        case action(LitheAction)
    }

    private var visibleItems: [SearchItem] {
        switch scope {
        case .all:
            return results(in: model.searchEverywhereResults.fileMatches)
                + results(in: model.searchEverywhereResults.classMatches)
                + results(in: model.searchEverywhereResults.symbolMatches)
                + results(in: model.searchEverywhereResults.contentMatches)
                + model.searchEverywhereResults.actionMatches.map(SearchItem.action)
        case .classes:
            return results(in: model.searchEverywhereResults.classMatches)
        case .files:
            return results(in: model.searchEverywhereResults.fileMatches)
        case .symbols:
            return results(in: model.searchEverywhereResults.symbolMatches)
        case .text:
            return results(in: model.searchEverywhereResults.contentMatches)
        case .actions:
            return model.searchEverywhereResults.actionMatches.map(SearchItem.action)
        }
    }

    private var hasQuery: Bool {
        !model.searchEverywhereQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { model.dismissSearchEverywhere() }

            VStack(spacing: 0) {
                scopeTabs
                searchField
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                resultsList
            }
            .frame(width: 720)
            .frame(maxHeight: 560)
            .lithePopupChrome()
            .padding(.top, 84)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            searchFocused = true
            selectedIndex = 0
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: model.searchEverywhereQuery) { selectedIndex = 0 }
        .onChange(of: scope) { selectedIndex = 0 }
        .task(id: "\(model.searchEverywhereQuery)|\(searchOptions.cacheKey)") {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await model.searchEverywhere(options: searchOptions)
        }
    }

    private var scopeTabs: some View {
        HStack(spacing: 2) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.accent)
                .padding(.leading, 12)

            ForEach(SearchEverywhereScope.allCases) { item in
                Button {
                    scope = item
                } label: {
                    Text(LocalizedStringKey(item.rawValue))
                        .font(.system(size: 12, weight: scope == item ? .semibold : .regular))
                        .foregroundStyle(scope == item ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 11)
                        .frame(height: 38)
                        .overlay(alignment: .bottom) {
                            if scope == item {
                                Rectangle().fill(LitheTheme.accent).frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .lithePointer()
                .contentShape(Rectangle())
            }

            Spacer(minLength: 12)
            if model.isSearchingEverywhere {
                ProgressView().controlSize(.mini)
            }
            Button {
                model.dismissSearchEverywhere()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close (Esc)")
            .padding(.trailing, 6)
        }
        .frame(height: 40)
        .background(LitheTheme.toolHeader)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Search files, classes, symbols, text or actions", text: $model.searchEverywhereQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
            if !model.searchEverywhereQuery.isEmpty {
                Button {
                    model.searchEverywhereQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .lithePointer()
                .foregroundStyle(LitheTheme.secondaryText)
            }
            searchOptionsMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LitheTheme.popupBackground)
    }

    private var searchOptionsMenu: some View {
        Menu {
            Toggle("Match Case", isOn: $searchOptions.caseSensitive)
            Toggle("Whole Words", isOn: $searchOptions.wholeWords)
            Toggle("Regular Expression", isOn: $searchOptions.regularExpression)
        } label: {
            Image(systemName: searchOptions == .default ? "slider.horizontal.3" : "slider.horizontal.3.circle.fill")
                .foregroundStyle(searchOptions == .default ? LitheTheme.secondaryText : LitheTheme.accent)
        }
        .menuStyle(.borderlessButton)
        .lithePointer()
        .help("Search options")
    }

    @ViewBuilder
    private var resultsList: some View {
        if !hasQuery {
            placeholder("Type to search")
        } else if visibleItems.isEmpty && !model.isSearchingEverywhere {
            placeholder("No matches in \(scope.rawValue)")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if scope == .all {
                        groupedResults
                    } else {
                        ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                            itemRow(item, index: index)
                        }
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder
    private var groupedResults: some View {
        groupedSection("Files", results: model.searchEverywhereResults.fileMatches, offset: 0, showsLine: false)
        groupedSection(
            "Classes",
            results: model.searchEverywhereResults.classMatches,
            offset: model.searchEverywhereResults.fileMatches.count,
            showsLine: true
        )
        groupedSection(
            "Symbols",
            results: model.searchEverywhereResults.symbolMatches,
            offset: model.searchEverywhereResults.fileMatches.count + model.searchEverywhereResults.classMatches.count,
            showsLine: true
        )
        groupedSection(
            "Text",
            results: model.searchEverywhereResults.contentMatches,
            offset: model.searchEverywhereResults.fileMatches.count
                + model.searchEverywhereResults.classMatches.count
                + model.searchEverywhereResults.symbolMatches.count,
            showsLine: true
        )
        if !model.searchEverywhereResults.actionMatches.isEmpty {
            sectionHeader("Actions")
            ForEach(Array(model.searchEverywhereResults.actionMatches.enumerated()), id: \.offset) { index, action in
                actionRow(
                    action,
                    index: model.searchEverywhereResults.allMatches.count + index
                )
            }
        }
    }

    @ViewBuilder
    private func groupedSection(
        _ title: String,
        results: [FileSearchResult],
        offset: Int,
        showsLine: Bool
    ) -> some View {
        if !results.isEmpty {
            sectionHeader(title)
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                resultRow(result, index: offset + index, showsLine: showsLine)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: SearchItem, index: Int) -> some View {
        switch item {
        case .result(let result):
            resultRow(result, index: index, showsLine: result.kind != .file)
        case .action(let action):
            actionRow(action, index: index)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: hasQuery ? "magnifyingglass" : "sparkle.magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(text))
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private func resultRow(_ result: FileSearchResult, index: Int, showsLine: Bool) -> some View {
        Button {
            model.openSearchEverywhereResult(result)
        } label: {
            HStack(spacing: 9) {
                LitheIcon(kind: iconKind(for: result), size: 14)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(result.symbolName ?? result.url.lastPathComponent)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                        if showsLine, let line = result.line {
                            Text(":\(line)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.relativePath(for: result.url))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    if result.kind == .content {
                        Text(result.preview)
                            .font(.system(size: 10))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 310, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(index == selectedIndex ? LitheTheme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func actionRow(_ action: LitheAction, index: Int) -> some View {
        Button {
            model.performSearchEverywhereAction(action)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.warning)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(action.title))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(LocalizedStringKey(action.subtitle))
                        .font(.system(size: 10))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(action.group.rawValue))
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                    if let keyEquivalent = action.keyEquivalent {
                        Text(keyEquivalent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(index == selectedIndex ? LitheTheme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func iconKind(for result: FileSearchResult) -> LitheIconKind {
        switch result.kind {
        case .file, .content:
            return LitheIcons.kind(for: result.url, isDirectory: false)
        case .type:
            return .javaClass
        case .symbol:
            return .javaGeneric
        }
    }

    private func results(in results: [FileSearchResult]) -> [SearchItem] {
        results.map(SearchItem.result)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard model.isSearchEverywhereVisible else { return event }
            switch event.keyCode {
            case 125: // Arrow Down
                if !visibleItems.isEmpty { selectedIndex = min(selectedIndex + 1, visibleItems.count - 1) }
                return nil
            case 126: // Arrow Up
                if !visibleItems.isEmpty { selectedIndex = max(selectedIndex - 1, 0) }
                return nil
            case 123, 124: // Arrow Left / Right
                moveScope(by: event.keyCode == 124 ? 1 : -1)
                return nil
            case 48: // Tab / Shift-Tab
                let isShiftDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
                moveScope(by: isShiftDown ? -1 : 1)
                return nil
            case 36, 76: // Return / Enter
                performSelectedItem()
                return nil
            case 53: // Escape
                model.dismissSearchEverywhere()
                return nil
            default:
                return event
            }
        }
    }

    private func moveScope(by offset: Int) {
        let scopes = SearchEverywhereScope.allCases
        guard let currentIndex = scopes.firstIndex(of: scope) else { return }
        let nextIndex = (currentIndex + offset + scopes.count) % scopes.count
        scope = scopes[nextIndex]
    }

    private func performSelectedItem() {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        switch visibleItems[selectedIndex] {
        case .result(let result): model.openSearchEverywhereResult(result)
        case .action(let action): model.performSearchEverywhereAction(action)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
