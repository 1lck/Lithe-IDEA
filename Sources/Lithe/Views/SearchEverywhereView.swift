import AppKit
import SwiftUI

/// IDEA 风格的双击 Shift 全局搜索弹窗：文件、类、符号和全文结果统一展示。
struct SearchEverywhereView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?

    private var allResults: [FileSearchResult] {
        model.searchEverywhereResults.allMatches
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { model.dismissSearchEverywhere() }

            VStack(spacing: 0) {
                header
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                searchField
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                resultsList
            }
            .frame(width: 640)
            .frame(maxHeight: 520)
            .background(LitheTheme.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(LitheTheme.divider, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
            .padding(.top, 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            searchFocused = true
            selectedIndex = 0
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: model.searchEverywhereQuery) {
            selectedIndex = 0
        }
        .task(id: model.searchEverywhereQuery) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.searchEverywhere()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LitheTheme.accent)
            Text("Search Everywhere")
                .font(.system(size: 13, weight: .semibold))
            if model.isSearchingEverywhere {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button {
                model.dismissSearchEverywhere()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close (Esc)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.toolHeader)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Type to search files, classes, symbols and contents", text: $model.searchEverywhereQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
            if !model.searchEverywhereQuery.isEmpty {
                Button {
                    model.searchEverywhereQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var resultsList: some View {
        if model.searchEverywhereQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder("Type to search files, classes, symbols and contents")
        } else if allResults.isEmpty && !model.isSearchingEverywhere {
            placeholder("No matches")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if !model.searchEverywhereResults.fileMatches.isEmpty {
                        sectionHeader("Files")
                        ForEach(Array(model.searchEverywhereResults.fileMatches.enumerated()), id: \.offset) { index, result in
                            resultRow(result, flatIndex: index, showsLine: false)
                        }
                    }
                    if !model.searchEverywhereResults.classMatches.isEmpty {
                        sectionHeader("Classes")
                        ForEach(Array(model.searchEverywhereResults.classMatches.enumerated()), id: \.offset) { index, result in
                            resultRow(
                                result,
                                flatIndex: model.searchEverywhereResults.fileMatches.count + index,
                                showsLine: true
                            )
                        }
                    }
                    if !model.searchEverywhereResults.symbolMatches.isEmpty {
                        sectionHeader("Symbols")
                        ForEach(Array(model.searchEverywhereResults.symbolMatches.enumerated()), id: \.offset) { index, result in
                            resultRow(
                                result,
                                flatIndex: model.searchEverywhereResults.fileMatches.count
                                    + model.searchEverywhereResults.classMatches.count
                                    + index,
                                showsLine: true
                            )
                        }
                    }
                    if !model.searchEverywhereResults.contentMatches.isEmpty {
                        sectionHeader("Matches")
                        ForEach(
                            Array(model.searchEverywhereResults.contentMatches.enumerated()),
                            id: \.offset
                        ) { index, result in
                            resultRow(
                                result,
                                flatIndex: model.searchEverywhereResults.fileMatches.count
                                    + model.searchEverywhereResults.classMatches.count
                                    + model.searchEverywhereResults.symbolMatches.count
                                    + index,
                                showsLine: true
                            )
                        }
                    }
                }
                .padding(5)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 40)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func resultRow(
        _ result: FileSearchResult,
        flatIndex: Int,
        showsLine: Bool
    ) -> some View {
        Button {
            model.openSearchEverywhereResult(result)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: result.kind.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 14)
                Text(result.symbolName ?? result.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                if showsLine, let line = result.line {
                    Text(":\(line)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 12)
                Text(showsLine ? result.preview : model.relativePath(for: result.url))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: showsLine ? 340 : 380, alignment: .trailing)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(flatIndex == selectedIndex ? LitheTheme.selection.opacity(0.85) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard model.isSearchEverywhereVisible else { return event }
            switch event.keyCode {
            case 125: // Arrow Down
                let total = model.searchEverywhereResults.totalCount
                let next = min(selectedIndex + 1, max(0, total - 1))
                if total > 0 { selectedIndex = next }
                return nil
            case 126: // Arrow Up
                if model.searchEverywhereResults.totalCount > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                }
                return nil
            case 36, 76: // Return / Enter
                let all = model.searchEverywhereResults.allMatches
                if all.indices.contains(selectedIndex) {
                    model.openSearchEverywhereResult(all[selectedIndex])
                }
                return nil
            case 53: // Escape
                model.dismissSearchEverywhere()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
