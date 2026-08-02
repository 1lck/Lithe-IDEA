import SwiftUI

struct JavaReferencesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.javaNavigationLocations.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var toolbar: some View {
        LitheToolWindowHeader(
            title: model.javaNavigationResultKind.title,
            systemImage: "scope",
            ideaAssetPath: "toolwindows/toolWindowFind.svg",
            subtitle: "\(model.javaNavigationLocations.count) results",
            onMinimize: { model.closeJavaNavigationResults() }
        ) {
            Text(model.javaLanguageService.statusMessage)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
    }

    private var results: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 1) {
                ForEach(model.javaNavigationLocations) { location in
                    Button {
                        model.navigate(to: location)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "cup.and.saucer.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
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
        Text("No Java navigation results")
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JavaImplementationChooserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Choose Implementation",
                systemImage: "arrow.triangle.branch",
                subtitle: "\(filteredLocations.count) found",
                onMinimize: { model.closeJavaNavigationResults() }
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
                                Image(systemName: "c.circle")
                                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 0.95))
                                Text(location.displayName.replacingOccurrences(of: ".java", with: ""))
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

    private var filteredLocations: [JavaNavigationLocation] {
        guard !query.isEmpty else { return model.javaNavigationLocations }
        return model.javaNavigationLocations.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            ($0.displayPath ?? model.relativePath(for: $0.url)).localizedCaseInsensitiveContains(query)
        }
    }
}
