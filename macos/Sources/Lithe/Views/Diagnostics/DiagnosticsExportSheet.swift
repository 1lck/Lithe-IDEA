import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsExportSheet: View {
    @ObservedObject var feature: DiagnosticsFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Diagnostics Bundle")
                .font(.system(size: 17, weight: .semibold))

            Text("Only the files below are collected. Credentials, tokens, and home-directory paths are redacted automatically; workspace source, editor buffers, and terminal history are never included.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Cancel") {
                    feature.dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export…") {
                    exportToChosenLocation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReadyToExport)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch feature.state {
        case .idle, .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Gathering diagnostics…")
                    .foregroundStyle(.secondary)
            }
        case .awaitingConfirmation(let manifest):
            fileList(manifest)
        case .exporting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating archive…")
                    .foregroundStyle(.secondary)
            }
        case .completed(let url):
            Label("Saved to \(url.path)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func fileList(_ manifest: RustCoreBridge.DiagnosticsManifestPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(manifest.files, id: \.relativePath) { file in
                HStack {
                    Text(file.relativePath)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private var isReadyToExport: Bool {
        if case .awaitingConfirmation = feature.state { return true }
        return false
    }

    private func exportToChosenLocation() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lithe-Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await feature.export(to: url) }
    }
}
