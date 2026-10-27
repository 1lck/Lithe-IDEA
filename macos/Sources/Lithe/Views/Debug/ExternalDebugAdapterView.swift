import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

struct ExternalDebugAdapterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = "127.0.0.1"
    @State private var port = ""
    @State private var request = DebugRequestKind.attach
    @State private var arguments = "{}"
    @State private var errorMessage: String?
    @State private var connectTask: Task<Void, Never>?
    let onConnect: (DebugLaunchConfiguration) async -> String?

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var parsedPort: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LitheSettingsLabel(
                Text("Connect to Debug Adapter"),
                info: L10n.string("Connect to an already running DAP server using the active file's installed debugger. This is not a JVM JDWP or gdbserver port. No proxy or tunnel is created.")
            )
            .font(LitheTheme.uiFont(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 10) {
                LitheTextField(verbatim: "127.0.0.1", text: $host, label: L10n.string("Host"))
                LitheTextField(verbatim: "1-65535", text: $port, label: L10n.string("Port"))
            }
            Picker("Request", selection: $request) {
                Text("Attach Request").tag(DebugRequestKind.attach)
                Text("Launch Request").tag(DebugRequestKind.launch)
            }
            .pickerStyle(.segmented)
            LitheTextEditor(
                text: $arguments, rows: 8, label: L10n.string("Adapter Arguments (JSON)"),
                info: L10n.string("Enter the launch or attach arguments required by this adapter, including its source path mappings if needed. These are separate from the DAP server's TCP address.")
            )
            if let errorMessage {
                Text(errorMessage).foregroundStyle(LitheTheme.error)
            }
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    connectTask?.cancel()
                    dismiss()
                }
                    .buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .disabled(parsedPort == nil || trimmedHost.isEmpty || connectTask != nil)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func connect() {
        guard let parsedPort else { return }
        errorMessage = nil
        let configuration: DebugLaunchConfiguration
        do {
            configuration = try ExternalDebugAdapterConfiguration.make(
                host: trimmedHost, port: parsedPort, request: request, argumentsJSON: arguments
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Stay open until the connection has started, so a rejected endpoint or a
        // declined consent leaves the host, port and arguments editable.
        connectTask = Task {
            let failure = await onConnect(configuration)
            connectTask = nil
            if let failure { errorMessage = failure } else { dismiss() }
        }
    }
}
