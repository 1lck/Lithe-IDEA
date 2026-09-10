import SwiftUI
import LitheSearchModule

struct SearchSidebarView: View {
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    let openReplace: (ProjectSearchOptions) -> Void
    let openResult: (FileSearchResult) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let searchProject: (ProjectSearchOptions) async -> Void
    @FocusState private var searchFocused: Bool
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
            }
            .padding(.horizontal, 13)
            .frame(height: 44)

            HStack(spacing: 7) {
                LitheSystemIcon(systemImage: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Search files and contents", text: $session.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !session.query.isEmpty {
                    Button {
                        session.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.secondaryText)
                }
                Button {
                    openReplace(searchOptions)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .litheIconButton()
                .help("Replace in project")

                searchOptionsMenu
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .stroke(LitheTheme.inputBorder, lineWidth: 1)
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
                        .font(.system(size: 28, weight: .light))
                    Text("Search across the project")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.searchResults.isEmpty && !feature.isSearching {
                Text("No matches")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feature.searchResults) { result in
                            Button {
                                openResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        LitheSystemIcon(systemImage: "doc.text")
                                        Text(result.url.lastPathComponent)
                                            .font(.system(size: 12.5, weight: .medium))
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
                            .buttonStyle(.plain)
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
                            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task(id: "\(session.query)|\(searchOptions.cacheKey)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await searchProject(searchOptions)
        }
        .onAppear { searchFocused = true }
        // 侧栏已经打开时再次按 Cmd+Shift+F，靠令牌变化把焦点移回输入框。
        .onChange(of: session.sidebarFocusRequest) { _ in searchFocused = true }
    }

    private var fileMaskField: some View {
        HStack(spacing: 7) {
            LitheSystemIcon(systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(
                    searchOptions.fileMask.isEmpty ? LitheTheme.secondaryText : LitheTheme.accent
                )
            TextField("File mask, e.g. *.java, *.kt", text: $searchOptions.fileMask)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .help("Comma-separated glob patterns. Empty searches every file.")
            if !searchOptions.fileMask.isEmpty {
                Button {
                    searchOptions.fileMask = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(LitheTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                .stroke(LitheTheme.inputBorder, lineWidth: 1)
        }
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
}
