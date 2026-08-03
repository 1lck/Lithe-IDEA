import SwiftUI

struct SearchSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var searchOptions = ProjectSearchOptions.default

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if model.isSearching {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)

            HStack(spacing: 7) {
                LitheSystemIcon(systemImage: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Search files and contents", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.secondaryText)
                }
                Button(action: model.openProjectReplace) {
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
            .padding(.bottom, 10)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.searchQuery.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                    Text("Search across the project")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.searchResults.isEmpty && !model.isSearching {
                Text("No matches")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.searchResults) { result in
                            Button {
                                model.openSearchResult(result)
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
                            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task(id: "\(model.searchQuery)|\(searchOptions.cacheKey)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.searchProject(options: searchOptions)
        }
        .onAppear { searchFocused = true }
        .sheet(isPresented: $model.isProjectReplaceVisible) {
            ProjectReplaceView()
                .environmentObject(model)
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
