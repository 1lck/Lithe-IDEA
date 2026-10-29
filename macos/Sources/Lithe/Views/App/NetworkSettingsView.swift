import LitheModuleAPI
import SwiftUI

/// Settings › Appearance & Behavior › Network.
///
/// Three proxy modes for the application's own HTTP traffic. The custom mode
/// exposes the full server configuration: type, host, port, optional
/// credentials, an exclusion list and a connectivity check. Terminal
/// commands, Git, JVM dependency downloads and the built-in updater keep
/// their own network settings; the updater always follows the system proxy.
struct NetworkSettingsView: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settings: AppSettings

    // The custom server fields commit on Save, like the Git executable row.
    @State private var proxyType: NetworkProxyType = .http
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var exclusions = ""
    @State private var checkInFlight = false
    @State private var checkOutcome: NetworkProxyCheckOutcome?
    @State private var saveMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LitheSettingsSection(title: "Proxy server", accessory: {
                LitheInfoTip("These settings apply to Lithe's own requests: the plugin marketplace, GitHub and AI providers. Terminal commands, Git, JVM dependency downloads and the built-in updater keep their own network settings; the updater always follows the system proxy. Changes apply to new requests.")
            }) {
                row(
                    "Proxy mode",
                    info: "Follow system uses the proxies configured in macOS network settings. No proxy contacts every host directly. Custom routes requests through the server configured below."
                ) {
                    LitheSettingsSelect(
                        selection: $settings.networkProxyMode,
                        options: NetworkProxyMode.allCases,
                        width: 220,
                        accessibilityLabel: "Proxy mode",
                        title: \.title
                    )
                }
                if settings.networkProxyMode == .custom {
                    row("Proxy type", info: "HTTP proxies carry HTTPS requests through CONNECT. SOCKS5 tunnels every protocol and port.") {
                        LitheSettingsSelect(
                            selection: $proxyType,
                            options: NetworkProxyType.allCases,
                            width: 160,
                            accessibilityLabel: "Proxy type",
                            title: \.title
                        )
                    }
                    row("Server address", info: "The proxy server's host name or IP address, for example 127.0.0.1.") {
                        LitheTextField("For example 127.0.0.1", text: $host)
                            .frame(maxWidth: 320)
                    }
                    row("Port", info: "The proxy server's port, for example 7890.") {
                        LitheTextField("For example 7890", text: $port)
                            .frame(maxWidth: 320)
                    }
                    row("Username", info: "Leave empty when the proxy does not require authentication.") {
                        LitheTextField("Optional", text: $username)
                            .frame(maxWidth: 320)
                    }
                    row("Password", info: settings.networkProxyHasSavedPassword
                        ? "A password is saved. Type a new one to replace it; saving an empty field keeps the saved password."
                        : "Leave empty when the proxy does not require authentication. The password is stored in the Keychain, never in settings files.") {
                        HStack(spacing: 6) {
                            LitheTextField("Optional", text: $password, secure: true)
                                .frame(maxWidth: 320)
                            if settings.networkProxyHasSavedPassword {
                                Button("Clear") {
                                    saveMessage = model.saveNetworkProxyPassword("")
                                }
                                .buttonStyle(LitheActionButtonStyle())
                            }
                        }
                    }
                    row(
                        "Exclusion list",
                        info: "Addresses that bypass the proxy, separated by commas. Entries support wildcard domains such as *.internal.example."
                    ) {
                        LitheTextField("For example 127.0.0.1, localhost, *.internal.example", text: $exclusions)
                            .frame(maxWidth: 320)
                    }
                    saveRow
                    testRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { syncDrafts() }
        .onChange(of: settings.networkProxyType) { _ in syncDrafts() }
        .onChange(of: settings.networkProxyHost) { _ in syncDrafts() }
        .onChange(of: settings.networkProxyPort) { _ in syncDrafts() }
        .onChange(of: settings.networkProxyUsername) { _ in syncDrafts() }
        .onChange(of: settings.networkProxyExclusions) { _ in syncDrafts() }
    }

    @ViewBuilder
    private var saveRow: some View {
        HStack(spacing: 8) {
            Button("Save", action: save)
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .disabled(!isDirty)
            Button("Reset", action: resetDrafts)
                .buttonStyle(LitheActionButtonStyle())
                .disabled(!isDirty)
            if let saveMessage {
                Text(saveMessage)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var testRow: some View {
        HStack(spacing: 8) {
            Button("Test connection", action: runCheck)
                .buttonStyle(LitheActionButtonStyle())
                .disabled(checkInFlight || !isDraftConfigured)
            if checkInFlight {
                Text("Testing…")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            } else if let checkOutcome {
                Text(checkOutcome.succeeded
                    ? L10n.string("Connection succeeded in \(String(checkOutcome.elapsedMilliseconds)) ms.")
                    : checkOutcome.detail ?? L10n.string("The connection check failed."))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(checkOutcome.succeeded ? LitheTheme.success : LitheTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 28)
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedPort: Int? {
        guard let parsed = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(parsed) else { return nil }
        return parsed
    }

    private var isDraftConfigured: Bool {
        !trimmedHost.isEmpty && parsedPort != nil
    }

    private var isDirty: Bool {
        guard settings.networkProxyMode == .custom else { return false }
        if proxyType != settings.networkProxyType { return true }
        if trimmedHost != settings.networkProxyHost { return true }
        if parsedPort != settings.networkProxyPort { return true }
        if username.trimmingCharacters(in: .whitespacesAndNewlines) != settings.networkProxyUsername { return true }
        if parsedExclusions != settings.networkProxyExclusions { return true }
        return !password.isEmpty
    }

    private var parsedExclusions: [String] {
        exclusions.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func syncDrafts() {
        proxyType = settings.networkProxyType
        host = settings.networkProxyHost
        port = settings.networkProxyPort > 0 ? String(settings.networkProxyPort) : ""
        username = settings.networkProxyUsername
        exclusions = settings.networkProxyExclusions.joined(separator: ", ")
    }

    private func save() {
        guard let parsedPort = parsedPort, !trimmedHost.isEmpty else {
            saveMessage = L10n.string("Enter a server address and a port between 1 and 65535 first.")
            return
        }
        settings.networkProxyType = proxyType
        settings.networkProxyHost = trimmedHost
        settings.networkProxyPort = parsedPort
        settings.networkProxyUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.networkProxyExclusions = parsedExclusions
        if !password.isEmpty {
            saveMessage = model.saveNetworkProxyPassword(password)
            password = ""
        } else {
            saveMessage = nil
        }
    }

    /// Discards unsaved draft edits and returns every field to the currently
    /// saved, effective values. The password field never syncs from the
    /// Keychain, so resetting clears it too; a stale check result goes with
    /// the values it was measured against.
    private func resetDrafts() {
        syncDrafts()
        password = ""
        saveMessage = nil
        checkOutcome = nil
    }

    private func runCheck() {
        guard let parsedPort = parsedPort else {
            checkOutcome = NetworkProxyCheckOutcome(
                succeeded: false, elapsedMilliseconds: 0,
                detail: L10n.string("Enter a server address and a port between 1 and 65535 first.")
            )
            return
        }
        checkOutcome = nil
        checkInFlight = true
        Task {
            let outcome = await model.checkProxyConnection(
                type: proxyType,
                host: trimmedHost,
                port: parsedPort,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            checkOutcome = outcome
            checkInFlight = false
        }
    }

    private func row<Content: View>(
        _ title: String,
        info: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            LitheSettingsLabel(LocalizedStringKey(title), info: info)
                .frame(minWidth: 230, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}
