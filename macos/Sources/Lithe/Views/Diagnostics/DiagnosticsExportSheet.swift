import LitheModuleAPI
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsExportSheet: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export diagnostic logs").font(.system(size: 15, weight: .semibold))
            Text("Packs recent logs into a zip you can attach to an issue. Nothing is uploaded.")
                .font(.system(size: 12)).foregroundStyle(Color(LogWindowPalette.tx2))
            Text("Range").font(.system(size: 11)).foregroundStyle(Color(LogWindowPalette.tx3)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                rangeRow(.current, title: "Current session")
                rangeRow(.recent, title: "Last 3 sessions", subtitle: "Includes the previous run, useful after a crash")
                rangeRow(.day, title: "Last 24 hours")
            }
            Text("Channels").font(.system(size: 11)).foregroundStyle(Color(LogWindowPalette.tx3)).padding(.top, 2)
            radio("All channels", selected: !feature.currentFilterOnly) { feature.currentFilterOnly = false }
            VStack(alignment: .leading, spacing: 2) {
                radio("Only the current filter", selected: feature.currentFilterOnly) { feature.currentFilterOnly = true }
                Text(feature.selectedChannels.isEmpty ? L10n.string("All channels") : feature.selectedChannels.joined(separator: ", "))
                    .foregroundStyle(Color(LogWindowPalette.tx3)).padding(.leading, 22)
            }
            Text("Privacy").font(.system(size: 11)).foregroundStyle(Color(LogWindowPalette.tx3)).padding(.top, 2)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 10)).accessibilityHidden(true)
                Text("Logs are redacted by Core before they are written to disk, so exports are always redacted: paths, URLs, tokens and user content appear as ‹redacted›.")
                    .fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Color(LogWindowPalette.grn))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(LogWindowPalette.bg2), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(LogWindowPalette.line)))
            Toggle("Include environment summary", isOn: $feature.includeEnvironment).disabled(feature.isBusy)
            Text("App version, macOS version, architecture, enabled plugins")
                .foregroundStyle(Color(LogWindowPalette.tx3)).padding(.leading, 20)
            Text("Contents").font(.system(size: 11)).foregroundStyle(Color(LogWindowPalette.tx3)).padding(.top, 2)
            contents.padding(.horizontal, 10).padding(.vertical, 6).frame(height: 150)
                .background(Color(LogWindowPalette.bg2), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(LogWindowPalette.line)))
            if feature.isPlanning { ProgressView().controlSize(.small) }
            if case .exporting = feature.state {
                HStack { ProgressView().controlSize(.small); Text("Packing…") }
            }
            if case .failed(let message) = feature.state {
                HStack { Text(message).foregroundStyle(Color(LogWindowPalette.red)); Button("Retry") { feature.retry() } }
            }
            if case .completed(let url) = feature.state {
                Text("Saved to \((url.path as NSString).abbreviatingWithTildeInPath)")
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(LogButtonStyle(monospaced: false))
            }
            HStack(spacing: 8) {
                Text(String(format: L10n.string("≈ %@ · %lld files"),
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: feature.estimatedBytes), countStyle: .file), Int64(fileCount)))
                    .foregroundStyle(Color(LogWindowPalette.tx3))
                Spacer()
                Button("Cancel") { feature.dismiss() }.buttonStyle(LogButtonStyle(monospaced: false)).keyboardShortcut(.cancelAction)
                Button("Export…") { save() }.buttonStyle(LogButtonStyle(active: true, monospaced: false))
                    .keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color(LogWindowPalette.tx))
        .padding(.horizontal, 18).padding(.vertical, 16).frame(width: 560)
        .background(Color(LogWindowPalette.menu))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(LogWindowPalette.bd)))
        .accessibilityIdentifier("logs.export-dialog")
    }
    private func rangeRow(_ range: DiagnosticsFeatureModel.Range, title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            radio(title, selected: feature.range == range) { feature.range = range }
            if let subtitle { Text(LocalizedStringKey(subtitle)).foregroundStyle(Color(LogWindowPalette.tx3)).padding(.leading, 22) }
        }
    }
    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Color(LogWindowPalette.blu) : Color(LogWindowPalette.tx3))
                Text(LocalizedStringKey(title)).foregroundStyle(Color(LogWindowPalette.tx))
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
                            Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)).foregroundStyle(Color(LogWindowPalette.tx3))
                        }
                    }
                    HStack { Text(verbatim: "manifest.json"); Spacer(); Text(verbatim: "redaction: core-v2").foregroundStyle(Color(LogWindowPalette.tx3)) }
                }.font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
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
