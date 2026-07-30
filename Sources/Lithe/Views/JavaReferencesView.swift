import SwiftUI

struct JavaReferencesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if model.javaNavigationLocations.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(LitheTheme.accent)
            Text(model.javaNavigationResultKind.title)
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(model.javaNavigationLocations.count) results")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(model.javaLanguageService.statusMessage)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
            Button {
                model.closeJavaNavigationResults()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Hide navigation results")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 36)
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.toolHeader)
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
                            Text(location.url.lastPathComponent)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text(model.relativePath(for: location.url))
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
