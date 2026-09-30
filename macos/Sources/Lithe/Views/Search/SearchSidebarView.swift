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
    @State private var searchOptions = ProjectSearchOptions.default

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if feature.isSearching {
                    ProgressView().controlSize(.mini)
                }
                LitheSidebarHideButton(title: "Search") {
                    model.workbenchFeature.hideSidebar()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 39)
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissSearchFieldFocus)

            HStack(spacing: 2) {
                LitheIDEAIcon(
                    resourcePath: "expui/general/search.svg",
                    size: LitheTheme.Metrics.toolbarIconSize,
                    fallbackSystemImage: "magnifyingglass",
                    preservesOriginalColors: true
                )
                LitheSearchTextField("Search files and contents", text: $session.query)
                    .focused($searchFocused)
                    .lineLimit(1)
                if !session.query.isEmpty {
                    Button {
                        session.query = ""
                    } label: {
                        LitheIDEAIcon(
                            resourcePath: "expui/general/closeSmall.svg",
                            size: LitheTheme.Metrics.toolbarIconSize,
                            fallbackSystemImage: "xmark",
                            preservesOriginalColors: true
                        )
                    }
                    .buttonStyle(LitheIconButtonStyle(size: 20, cornerRadius: 4))
                    .padding(.leading, 1)
                    .help("Clear search")
                }
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
            .litheSearchField(isFocused: searchFocused)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            fileMaskField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if session.query.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 28, weight: .light))
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feature.searchResults) { result in
                            Button {
                                openResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        LitheIcon(
                                            kind: LitheIcons.kind(forFilePath: result.url.path),
                                            size: LitheTheme.Metrics.treeIconSize
                                        )
                                        Text(result.url.lastPathComponent)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if let line = result.line {
                                            Text(":\(line)")
                                                .foregroundStyle(LitheTheme.secondaryText)
                                        }
                                    }
                                    Text(result.preview)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                        .lineLimit(2)
                                }
                                .foregroundStyle(LitheTheme.primaryText)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.litheNoPress)
                            .litheRowHover(
                                cornerRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius
                            )
                            .lithePointer()
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
        HStack(spacing: 2) {
            LitheIDEAIcon(
                resourcePath: "expui/general/filter.svg",
                size: LitheTheme.Metrics.toolbarIconSize,
                fallbackSystemImage: "line.3.horizontal.decrease",
                preservesOriginalColors: false
            )
                .foregroundStyle(
                    searchOptions.fileMask.isEmpty ? LitheTheme.secondaryText : LitheTheme.accent
                )
            LitheSearchTextField("File mask, e.g. *.java, *.kt", text: $searchOptions.fileMask)
                .focused($fileMaskFocused)
                .help("Comma-separated glob patterns. Empty searches every file.")
            if !searchOptions.fileMask.isEmpty {
                Button {
                    searchOptions.fileMask = ""
                } label: {
                    LitheIDEAIcon(
                        resourcePath: "expui/general/closeSmall.svg",
                        size: LitheTheme.Metrics.toolbarIconSize,
                        fallbackSystemImage: "xmark",
                        preservesOriginalColors: true
                    )
                }
                .buttonStyle(LitheIconButtonStyle(size: 20, cornerRadius: 4))
                .padding(.leading, 1)
                .help("Clear file mask")
            }
        }
        .litheSearchField(isFocused: fileMaskFocused)
    }

    private var searchOptionsMenu: some View {
        Menu {
            Toggle("Match Case", isOn: $searchOptions.caseSensitive)
            Toggle("Whole Words", isOn: $searchOptions.wholeWords)
            Toggle("Regular Expression", isOn: $searchOptions.regularExpression)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search options")
    }

    private func dismissSearchFieldFocus() {
        searchFocused = false
        fileMaskFocused = false
    }
}
