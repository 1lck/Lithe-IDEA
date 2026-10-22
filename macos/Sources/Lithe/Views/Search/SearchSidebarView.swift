import SwiftUI
import LitheSearchModule

struct SearchSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    let openReplace: (ProjectSearchOptions) -> Void
    let openResult: (FileSearchResult) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let searchProject: (ProjectSearchOptions) async -> Void
    @FocusState private var searchFocused: Bool
    @FocusState private var fileMaskFocused: Bool
    @State private var selectedResultID: String?
    @State private var searchOptions = ProjectSearchOptions.default

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search")
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if feature.isSearching {
                    ProgressView().controlSize(.mini)
                }
                LitheSidebarHideButton(title: "Search") {
                    model.workbenchFeature.setVisibility(.search, isVisible: false)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 39)
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissSearchFieldFocus)

            LitheSearchField("Search files and contents", text: $session.query, focus: $searchFocused) {
                Button {
                    openReplace(searchOptions)
                } label: {
                    LitheIDEAIcon(
                        resourcePath: "expui/actions/replace.svg",
                        size: LitheTheme.Metrics.toolbarIconSize,
                        fallbackSystemImage: "arrow.left.arrow.right",
                        preservesOriginalColors: true
                    )
                }
                .litheToolbarIconButton()
                .help("Replace in project")

                searchOptionsMenu
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            fileMaskField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if session.query.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.magnifyingglass")
                        .font(LitheTheme.uiFont(size: 28, weight: .light))
                    Text("Search across the project")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissSearchFieldFocus)
            } else if feature.searchResults.isEmpty && !feature.isSearching {
                Text("No matches")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSearchFieldFocus)
            } else {
                LitheTreeList(
                    feature.searchResults, selection: $selectedResultID,
                    onActivate: openResult, onClick: openResult, multiline: true
                ) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            LitheIcon(
                                kind: LitheIcons.kind(forFilePath: result.url.path),
                                size: LitheTheme.Metrics.treeIconSize
                            )
                            Text(result.url.lastPathComponent)
                                .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let line = result.line {
                                Text(":\(line)")
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                        }
                        Text(result.preview)
                            .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(2)
                    }
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .litheContextMenu {
                        [
                            .action(
                                "Open", systemImage: "doc.text",
                                action: {
                                    openResult(result)
                                }),
                            .action(
                                "Show in Finder", systemImage: "folder",
                                action: {
                                    revealInFinder(result.url)
                                }),
                            .submenu(
                                "Copy Path / Reference",
                                items: [
                                    .action(
                                        "Copy Path",
                                        action: {
                                            copyPath(result.url, false)
                                        }),
                                    .action(
                                        "Copy Relative Path",
                                        action: {
                                            copyPath(result.url, true)
                                        }),
                                ]),
                        ]
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { _ in dismissSearchFieldFocus() })
            }
        }
        .task(id: "\(session.query)|\(searchOptions.cacheKey)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await searchProject(searchOptions)
        }
        .onAppear(perform: focusSearchFieldIfRequested)
        // 侧栏已经打开时再次按 Cmd+Shift+F，靠令牌变化把焦点移回输入框。
        .onChange(of: session.sidebarFocusRequest) { _ in focusSearchFieldIfRequested() }
    }

    private func focusSearchFieldIfRequested() {
        guard session.sidebarFocusRequest > 0 else { return }
        session.sidebarFocusRequest = 0
        searchFocused = true
    }

    private var fileMaskField: some View {
        LitheSearchField("File mask, e.g. *.java, *.kt", text: $searchOptions.fileMask, focus: $fileMaskFocused)
        .help("Comma-separated glob patterns. Empty searches every file.")
    }

    private var searchOptionsMenu: some View {
        LitheMenu {
            LitheContextMenuItem.toggle("Match Case", isOn: $searchOptions.caseSensitive)
            LitheContextMenuItem.toggle("Whole Words", isOn: $searchOptions.wholeWords)
            LitheContextMenuItem.toggle("Regular Expression", isOn: $searchOptions.regularExpression)
        } label: {
            LitheIDEAIcon(
                resourcePath: "expui/general/settings.svg",
                size: LitheTheme.Metrics.toolbarIconSize,
                fallbackSystemImage: "slider.horizontal.3",
                preservesOriginalColors: false
            )
            .foregroundStyle(searchOptions == .default ? LitheTheme.secondaryText : LitheTheme.accent)
            .frame(
                width: LitheTheme.Metrics.toolbarIconButtonSize,
                height: LitheTheme.Metrics.toolbarIconButtonSize
            )
            .contentShape(Rectangle())
            .litheRowHover()
        }
        .buttonStyle(.litheNoPress)
        .fixedSize()
        .help("Search options")
    }

    private func dismissSearchFieldFocus() {
        searchFocused = false
        fileMaskFocused = false
    }
}
