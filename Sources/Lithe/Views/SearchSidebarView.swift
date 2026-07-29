import SwiftUI

struct SearchSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

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
                Image(systemName: "magnifyingglass")
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
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(LitheTheme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
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
                                model.openFile(result.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task(id: model.searchQuery) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.searchProject()
        }
        .onAppear { searchFocused = true }
    }
}
