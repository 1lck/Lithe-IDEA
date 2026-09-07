import AppKit
import LitheSearchModule
import SwiftUI

enum SearchEverywhereScope: String, CaseIterable, Identifiable {
    case all = "All"
    case classes = "Classes"
    case files = "Files"
    case symbols = "Symbols"
    case actions = "Actions"
    case text = "Text"

    var id: String { rawValue }
}

/// IDEA 风格的全局搜索弹窗：分类标签、双栏结果和可执行 Actions 共用同一套键盘导航。
struct SearchEverywhereView: View {
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    let actionMatches: (String) -> [LitheAction]
    let search: (String, ProjectSearchOptions) async -> Void
    let dismiss: () -> Void
    let openResult: (FileSearchResult) -> Void
    let performAction: (LitheAction) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let relativePath: (URL) -> String
    let moduleLabel: (URL) -> String
    @FocusState private var searchFocused: Bool
    @State private var query = ""
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
            // 对齐 IDEA：默认视图按“名字”找（文件、类、符号、Action），
            // 正文命中只在 Text 标签页出现，避免与 Find in Files 的结果重叠。
            // IDEA 不按 kind 分段，而是把三类混排后按相关度排序。
            let nameMatches = feature.searchEverywhereResults.fileMatches
                + feature.searchEverywhereResults.classMatches
                + feature.searchEverywhereResults.symbolMatches
            return rankedResults(nameMatches)
                + actionMatches(query).map(SearchItem.action)
        case .classes:
            return results(in: feature.searchEverywhereResults.classMatches)
        case .files:
            return results(in: feature.searchEverywhereResults.fileMatches)
        case .symbols:
            return results(in: feature.searchEverywhereResults.symbolMatches)
        case .text:
            return results(in: feature.searchEverywhereResults.contentMatches)
        case .actions:
            return actionMatches(query).map(SearchItem.action)
        }
    }

    private struct RankedResult {
        let index: Int
        let score: Int
        let value: FileSearchResult
    }

    /// 按相关度降序。同分保持原顺序，避免逐字输入时行位置来回跳动。
    private func rankedResults(_ results: [FileSearchResult]) -> [SearchItem] {
        var ranked: [RankedResult] = []
        ranked.reserveCapacity(results.count)
        for (index, value) in results.enumerated() {
            ranked.append(
                RankedResult(index: index, score: SearchRelevance.score(value, query: query), value: value)
            )
        }
        ranked.sort { left, right in
            left.score == right.score ? left.index < right.index : left.score > right.score
        }
        return ranked.map { SearchItem.result($0.value) }
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            // IDEA 不压暗编辑器，所以这层只用来接收“点击外部关闭”，不着色。
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                scopeTabs
                searchField
                if hasQuery {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    resultsList
                }
            }
            .frame(width: 860)
            .frame(maxHeight: 560, alignment: .top)
            .lithePopupChrome()
            .padding(.top, 84)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            searchFocused = true
            selectedIndex = 0
            query = session.everywhereQuery
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _ in selectedIndex = 0 }
        .onChange(of: scope) { _ in selectedIndex = 0 }
        .task(id: "\(query)|\(searchOptions.cacheKey)") {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await search(query, searchOptions)
        }
    }

    private var scopeTabs: some View {
        HStack(spacing: 2) {
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
            if feature.isSearchingEverywhere {
                ProgressView().controlSize(.mini)
            }
            includeNonProjectItemsToggle
            searchOptionsMenu
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close (Esc)")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(LitheTheme.toolHeader)
    }

    /// 占位控件：当前搜索范围只覆盖工作区内的文件，还没有“非项目文件”
    /// （JDK、依赖 jar 里的类）这一概念可供开关，所以先禁用。
    private var includeNonProjectItemsToggle: some View {
        Toggle("Include non-project items", isOn: .constant(false))
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            .foregroundStyle(LitheTheme.secondaryText)
            .disabled(true)
            .opacity(0.45)
            .help("Not available yet: dependencies are not indexed")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if query.isEmpty {
                Text("Type / to see commands")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .allowsHitTesting(false)
            } else {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
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
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .lithePointer()
        .help("Search options")
    }

    @ViewBuilder
    private var resultsList: some View {
        if visibleItems.isEmpty {
            if !feature.isSearchingEverywhere {
                placeholder("No matches in \(scope.rawValue)")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                            itemRow(item, index: index)
                                .id(index)
                        }
                        if isTruncated {
                            moreRow
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedIndex) { index in
                    guard visibleItems.indices.contains(index) else { return }
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    /// 后端按 matchLimit 截断，命中数刚好顶到上限时提示还有更多。
    private var isTruncated: Bool {
        feature.searchEverywhereResults.allMatches.count >= SearchEverywhereResults.matchLimit
    }

    private var moreRow: some View {
        Text("… more")
            .font(.system(size: 11))
            .foregroundStyle(LitheTheme.tertiaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
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
        Text(LocalizedStringKey(text))
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
    }

    private func resultRow(_ result: FileSearchResult, index: Int, showsLine: Bool) -> some View {
        // 文件夹按钮与整行点击是两个独立目标，所以并排放而不是嵌套，
        // 否则嵌套的 Button 收不到点击。
        HStack(spacing: 8) {
            Button {
                openResult(result)
            } label: {
                HStack(spacing: 8) {
                    LitheIcon(kind: iconKind(for: result), size: 14)
                        .frame(width: 16)

                    // 对齐 IDEA：名字和路径左侧连排，而不是把路径推到右端。
                    Text(result.symbolName ?? result.url.lastPathComponent)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if showsLine, let line = result.line {
                        Text(":\(line)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(containerPath(for: result.url))
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if result.kind == .content {
                        Text(result.preview)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(moduleLabel(for: result.url))
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            Button {
                revealInFinder(result.url)
            } label: {
                LitheIcon(kind: .folder, size: 13)
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help("Show in Finder")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(index == selectedIndex ? LitheTheme.selection : .clear)
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: {
                    openResult(result)
                }),
                .action("Show in Finder", systemImage: "folder", action: {
                    revealInFinder(result.url)
                }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: {
                        copyPath(result.url, false)
                    }),
                    .action("Copy Relative Path", action: {
                        copyPath(result.url, true)
                    })
                ])
            ]
        }
    }

    /// 结果所在目录（不含文件名本身），文件直接位于工作区根下时为空。
    private func containerPath(for url: URL) -> String {
        let relative = relativePath(url)
        let parent = (relative as NSString).deletingLastPathComponent
        return parent
    }

    /// 结果归属的 Maven 模块 artifactID；非 Maven 项目或匹配不到时回退到顶层目录名。
    private func moduleLabel(for url: URL) -> String {
        moduleLabel(url)
    }

    private func actionRow(_ action: LitheAction, index: Int) -> some View {
        Button {
            performAction(action)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.warning)
                    .frame(width: 16)
                Text(LocalizedStringKey(action.title))
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(LocalizedStringKey(action.subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(action.group.rawValue))
                        .font(.system(size: 11))
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
            .frame(height: 24)
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
            guard session.isSearchEverywhereVisible else { return event }
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
                dismiss()
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
        case .result(let result): openResult(result)
        case .action(let action): performAction(action)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
