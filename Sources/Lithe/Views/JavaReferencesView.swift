import SwiftUI

struct LanguageReferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            filterBar
            if filteredLocations.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Filter results", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .litheIconButton()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(LitheTheme.popupBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
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
                ForEach(filteredLocations) { location in
                    Button {
                        model.navigate(to: location)
                    } label: {
                        LanguageNavigationResultRow(
                            location: location,
                            parentPath: parentPath(for: location),
                            preview: model.languageNavigationPreviews[location.id] ?? "",
                            isSelected: false
                        )
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
            .padding(6)
        }
    }

    private var filteredLocations: [LanguageNavigationLocation] {
        guard !query.isEmpty else { return model.languageNavigationResults }
        return model.languageNavigationResults.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || parentPath(for: $0).localizedCaseInsensitiveContains(query)
                || (model.languageNavigationPreviews[$0.id] ?? "")
                    .localizedCaseInsensitiveContains(query)
        }
    }

    private func parentPath(for location: LanguageNavigationLocation) -> String {
        let path = location.displayPath ?? model.relativePath(for: location.url)
        return (path as NSString).deletingLastPathComponent
    }

    private var emptyState: some View {
        Text("No navigation results")
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LanguageNavigationChooserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.closeLanguageNavigationResults() }

            VStack(spacing: 0) {
                header
                toolbar
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                resultList
            }
            .frame(width: 900, height: 500)
            .lithePopupChrome(cornerRadius: 8)
            .padding(.top, 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: filteredLocations.count) { count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
        .onChange(of: query) { _ in selectedIndex = 0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.languageNavigationKind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.accent)
            Text(headerTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer()
            if model.isLoadingNavigation {
                ProgressView().controlSize(.small)
            }
            Text("\(model.languageNavigationResults.count) \(model.languageNavigationKind.countLabel)")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Button { model.closeLanguageNavigationResults() } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(LitheTheme.toolHeader)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Filter results", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Spacer()
            Text("↑↓ Select   ↩ Jump   esc Close")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LitheTheme.popupBackground)
    }

    @ViewBuilder
    private var resultList: some View {
        if filteredLocations.isEmpty {
            VStack(spacing: 10) {
                if model.isLoadingNavigation {
                    ProgressView()
                    Text("Finding \(model.languageNavigationKind.countLabel)…")
                } else {
                    Text("No matching results")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filteredLocations.enumerated()), id: \.element.id) { index, location in
                            resultRow(location, index: index)
                                .id(location.id)
                        }
                    }
                    .padding(5)
                }
                .onChange(of: selectedIndex) { index in
                    guard filteredLocations.indices.contains(index) else { return }
                    proxy.scrollTo(filteredLocations[index].id, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ location: LanguageNavigationLocation, index: Int) -> some View {
        Button { navigate(to: location) } label: {
            LanguageNavigationResultRow(
                location: location,
                parentPath: parentPath(for: location),
                preview: model.languageNavigationPreviews[location.id] ?? "",
                isSelected: index == selectedIndex
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
    }

    private var filteredLocations: [LanguageNavigationLocation] {
        guard !query.isEmpty else { return model.languageNavigationResults }
        return model.languageNavigationResults.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            ($0.displayPath ?? model.relativePath(for: $0.url)).localizedCaseInsensitiveContains(query)
        }
    }

    private var headerTitle: String {
        let subject = model.languageNavigationSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty
            ? model.languageNavigationKind.title
            : "\(model.languageNavigationKind.title) of \(subject)"
    }

    private func parentPath(for location: LanguageNavigationLocation) -> String {
        let path = location.displayPath ?? model.relativePath(for: location.url)
        return (path as NSString).deletingLastPathComponent
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard model.isLanguageNavigationChooserVisible else { return event }
            switch event.keyCode {
            case 125:
                if !filteredLocations.isEmpty {
                    selectedIndex = min(selectedIndex + 1, filteredLocations.count - 1)
                }
                return nil
            case 126:
                if !filteredLocations.isEmpty { selectedIndex = max(selectedIndex - 1, 0) }
                return nil
            case 36, 76:
                guard filteredLocations.indices.contains(selectedIndex) else { return nil }
                navigate(to: filteredLocations[selectedIndex])
                return nil
            case 53:
                model.closeLanguageNavigationResults()
                return nil
            default:
                return event
            }
        }
    }

    private func navigate(to location: LanguageNavigationLocation) {
        model.navigate(to: location)
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct LanguageNavigationResultRow: View {
    let location: LanguageNavigationLocation
    let parentPath: String
    let preview: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            LitheIcon(kind: LitheIcons.kind(for: location.url, isDirectory: false), size: 15)
                .frame(width: 18)
            Text(location.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            Text(parentPath)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            Text("\(location.line + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 44, alignment: .trailing)
            Text(preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 29)
        .background(isSelected ? LitheTheme.selection : .clear)
        .contentShape(Rectangle())
    }
}
