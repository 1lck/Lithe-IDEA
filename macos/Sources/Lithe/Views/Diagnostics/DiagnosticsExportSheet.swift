import LitheModuleAPI
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsExportSheet: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export diagnostic logs").font(LitheTheme.uiFont(size: 17, weight: .semibold))
            Text("Packs recent logs into a zip you can attach to an issue. Nothing is uploaded.")
                .foregroundStyle(.secondary)
            Text("Range").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                rangeRow(.current, title: "Current session")
                rangeRow(.recent, title: "Last 3 sessions", subtitle: "Includes the previous run, useful after a crash")
                rangeRow(.day, title: "Last 24 hours")
            }
            Text("Channels").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            radio("All channels", selected: !feature.currentFilterOnly) { feature.currentFilterOnly = false }
            VStack(alignment: .leading, spacing: 2) {
                radio("Only the current filter", selected: feature.currentFilterOnly) { feature.currentFilterOnly = true }
                    .disabled(!feature.canUseCurrentFilter)
                Text(feature.canUseCurrentFilter
                    ? (feature.selectedChannels.isEmpty ? L10n.string("All channels") : feature.selectedChannels.joined(separator: ", "))
                    : L10n.string("Open export from the log window to use its current filter."))
                    .foregroundStyle(.secondary).padding(.leading, 22)
            }
            Text("Privacy").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            Text("Logs are redacted by Core before they are written to disk, so exports are always redacted: paths, URLs, tokens and user content appear as ‹redacted›.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Include environment summary", isOn: $feature.includeEnvironment).disabled(feature.isBusy)
            Text("App version, macOS version, architecture, enabled plugins")
                .foregroundStyle(.secondary).padding(.leading, 20)
            Text("Contents").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            contents.frame(height: 140)
            if feature.isPlanning { ProgressView().controlSize(.small) }
            if case .exporting = feature.state {
                HStack { ProgressView().controlSize(.small); Text("Packing…") }
            }
            if case .failed(let message) = feature.state {
                HStack { Text(message).foregroundStyle(LitheTheme.error); Button("Retry") { feature.retry() } }
            }
            if case .completed(let url) = feature.state {
                Text("Saved to \((url.path as NSString).abbreviatingWithTildeInPath)")
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(LitheActionButtonStyle())
            }
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Text(String(format: L10n.string("≈ %@ · %lld files"),
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: feature.estimatedBytes), countStyle: .file), Int64(fileCount)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { feature.dismiss() }.buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Export…") { save() }.buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .padding(20).frame(width: 520)
        .accessibilityIdentifier("logs.export-dialog")
    }
    private func rangeRow(_ range: DiagnosticsFeatureModel.Range, title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            radio(title, selected: feature.range == range) { feature.range = range }
            if let subtitle { Text(LocalizedStringKey(subtitle)).foregroundStyle(.secondary).padding(.leading, 22) }
        }
    }
    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(LocalizedStringKey(title)).foregroundStyle(LitheTheme.primaryText)
            }.contentShape(Rectangle())
        }.buttonStyle(.litheNoPress).disabled(feature.isBusy)
    }
    @ViewBuilder private var contents: some View {
        if let manifest = feature.manifest {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(manifest.files, id: \.relativePath) { file in
                        HStack {
                            Text(file.relativePath)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)).foregroundStyle(.secondary)
                        }
                    }
                    HStack { Text(verbatim: "manifest.json"); Spacer(); Text(verbatim: "redaction: core-v2").foregroundStyle(.secondary) }
                }.font(LitheTheme.uiFont(size: 11, design: .monospaced))
            }.litheScrollViewChrome()
        } else { Color.clear }
    }
    private var fileCount: Int { if let manifest = feature.manifest { return manifest.files.count + 1 }; return 0 }
    private var ready: Bool {
        if case .awaitingConfirmation = feature.state { return true }
        return false
    }
    private func save() {
        let panel = NSSavePanel()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "lithe-logs-\(formatter.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        feature.choosingDestination = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                feature.choosingDestination = false
                return
            }
            Task {
                await feature.export(to: url)
                feature.choosingDestination = false
            }
        }
    }
}
