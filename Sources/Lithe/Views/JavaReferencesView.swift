import SwiftUI

struct LanguageReferencesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.languageNavigationResults.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var toolbar: some View {
        LitheToolWindowHeader(
            title: model.languageNavigationKind.title,
            systemImage: "scope",
            ideaAssetPath: "toolwindows/toolWindowFind.svg",
            subtitle: "\(model.languageNavigationResults.count) results",
            onMinimize: { model.closeLanguageNavigationResults() }
        ) {
            Text(LocalizedStringKey(model.languageServerStatusMessage))
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
    }

    private var results: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 1) {
                ForEach(model.languageNavigationResults) { location in
                    Button {
                        model.navigate(to: location)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 11))
                                .foregroundStyle(LitheTheme.accent)
                                .frame(width: 16)
                            Text(location.displayName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text(location.displayPath ?? model.relativePath(for: location.url))
                                .font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(location.line + 1):\(location.utf16Column + 1)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
            .padding(6)
        }
    }

    private var emptyState: some View {
        Text("No navigation results")
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LanguageImplementationChooserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Choose Implementation",
                systemImage: "arrow.triangle.branch",
                subtitle: "\(filteredLocations.count) found",
                onMinimize: { model.closeLanguageNavigationResults() }
            )

            HStack(spacing: 7) {
                LitheSystemIcon(systemImage: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Search implementations", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(LitheTheme.editor)

            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(filteredLocations) { location in
                        Button {
                            model.navigate(to: location)
                        } label: {
                            HStack(spacing: 9) {
                                LitheIcon(kind: LitheIcons.kind(for: location.url, isDirectory: false), size: 15)
                                Text(location.displayName)
                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(LitheTheme.primaryText)
                                Text(location.displayPath ?? model.relativePath(for: location.url))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(location.line + 1):\(location.utf16Column + 1)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                    }
                }
                .padding(5)
            }
        }
        .frame(maxWidth: 760, minHeight: 220, maxHeight: 390)
        .lithePopupChrome(cornerRadius: 7)
    }

    private var filteredLocations: [LanguageNavigationLocation] {
        guard !query.isEmpty else { return model.languageNavigationResults }
        return model.languageNavigationResults.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            ($0.displayPath ?? model.relativePath(for: $0.url)).localizedCaseInsensitiveContains(query)
        }
    }
}
