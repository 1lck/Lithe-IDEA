import AppKit
import LitheModuleAPI
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
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var toolbar: some View {
        LitheToolWindowHeader(
            title: model.languageNavigationKind.title,
            subtitle: L10n.string("\(model.languageNavigationResults.count) results"),
            onMinimize: { model.closeLanguageNavigationResults() }
        ) {
            Text(LocalizedStringKey(model.languageServerStatusMessage))
                .font(LitheTheme.uiFont(size: 10.5))
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
                                .font(LitheTheme.uiFont(size: 11))
                                .foregroundStyle(LitheTheme.accent)
                                .frame(width: 16)
                            Text(location.displayName)
                                .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text(location.displayPath ?? model.relativePath(for: location.url))
                                .font(LitheTheme.uiFont(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(location.line + 1):\(location.utf16Column + 1)")
                                .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
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
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Choose Implementation",
                subtitle: L10n.string("\(filteredLocations.count) found"),
                onMinimize: { model.closeLanguageNavigationResults() }
            )
            LitheSearchField("Search implementations", text: $query)
                .padding(LitheDropdownMetrics.popupPadding)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredLocations.indices, id: \.self) { index in
                            let location = filteredLocations[index]
                            Button { model.navigate(to: location) } label: {
                                HStack(spacing: 8) {
                                    LitheIcon(kind: LitheIcons.kind(for: location.url, isDirectory: false), size: LitheDropdownMetrics.iconSize)
                                    Text(location.displayName).lineLimit(1)
                                    Text(location.displayPath ?? model.relativePath(for: location.url))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text("\(location.line + 1):\(location.utf16Column + 1)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(LitheDropdownRowStyle(isSelected: selectedIndex == index))
                            .id(index)
                        }
                    }
                    .padding(LitheDropdownMetrics.popupPadding)
                }
                .frame(height: min(300, CGFloat(filteredLocations.count) * LitheDropdownMetrics.rowHeight
                    + LitheDropdownMetrics.verticalPadding))
                .onChange(of: selectedIndex) { proxy.scrollTo($0) }
            }
        }
        .frame(width: 640)
        .onChange(of: query) { _ in selectedIndex = 0 }
        .litheDropdownKeyHandler { event in
            guard !filteredLocations.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
            switch event.keyCode {
            case 125: selectedIndex = min(selectedIndex + 1, filteredLocations.count - 1)
            case 126: selectedIndex = max(selectedIndex - 1, 0)
            case 36, 76:
                guard filteredLocations.indices.contains(selectedIndex) else { return false }
                model.navigate(to: filteredLocations[selectedIndex])
            default: return false
            }
            return true
        }
    }

    private var filteredLocations: [LanguageNavigationLocation] {
        guard !query.isEmpty else { return model.languageNavigationResults }
        return model.languageNavigationResults.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            ($0.displayPath ?? model.relativePath(for: $0.url)).localizedCaseInsensitiveContains(query)
        }
    }
}
