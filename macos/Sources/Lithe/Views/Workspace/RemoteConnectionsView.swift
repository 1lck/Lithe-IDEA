import LitheModuleAPI
import AppKit
import SwiftUI

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// Owns the window's state while the sheet is shown, so a re-render of the
/// presenting view does not discard unsaved edits.
struct RemoteConnectionsSheet: View {
    @StateObject private var feature: RemoteConnectionsFeatureModel

    init(feature: @autoclosure @escaping () -> RemoteConnectionsFeatureModel) {
        _feature = StateObject(wrappedValue: feature())
    }

    var body: some View {
        RemoteConnectionsView(feature: feature)
    }
}

/// The Remote Development window, laid out like New Project: saved SSH
/// connections on the left, the selected connection's form on the right.
struct RemoteConnectionsView: View {
    @ObservedObject var feature: RemoteConnectionsFeatureModel
    @Environment(\.dismiss) private var dismiss

    private static let sidebarWidth: CGFloat = 240
    private static let labelWidth: CGFloat = 120
    private static let fieldWidth: CGFloat = 360
    private var sheetSize: CGSize {
        ParentWindowFit.size(preferred: CGSize(width: 880, height: 620), minimum: CGSize(width: 640, height: 420))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: Self.sidebarWidth)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
                .sheet(isPresented: Binding(
                    get: { feature.browser != nil },
                    set: { if !$0 { feature.closeBrowser() } }
                )) {
                    RemoteFolderBrowserView(feature: feature)
                }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(LitheTheme.window)
        .sheet(item: Binding(get: { feature.prompts.first }, set: { _ in })) { prompt in
            RemoteAuthenticationView(prompt: prompt) { feature.answerPrompt($0) }
                .interactiveDismissDisabled()
        }
        .onDisappear { feature.close() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            LitheTreeList(nodes: sidebarNodes, selection: Binding<String?>(
                get: { feature.selectedID?.uuidString },
                set: { id in feature.selectedID = id.flatMap(UUID.init(uuidString:)) }
            ))
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 2) {
                Button { feature.addConnection() } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, fallbackSystemImage: "plus")
                }
                .litheToolbarIconButton()
                .help(Text(LocalizedStringKey("New SSH Connection")))
                Button { feature.removeSelection() } label: {
                    Image(systemName: "minus").font(LitheTheme.uiFont(size: 12, weight: .medium))
                }
                .litheToolbarIconButton(isEnabled: feature.selection != nil)
                .disabled(feature.selection == nil)
                .help(Text(LocalizedStringKey("Remove Connection")))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .background(LitheTheme.settingsSidebar)
    }

    private var sidebarNodes: [LitheTreeListNode] {
        [LitheTreeListNode(id: "heading-ssh", isSelectable: false) { LitheSidebarHeading("SSH") }]
            + feature.connections.map { connection in
                LitheTreeListNode(id: connection.id.uuidString, onSelect: { feature.selectedID = connection.id }) {
                    HStack(spacing: 8) {
                        LitheIDEAIcon(resourcePath: "expui/webReferences/server.svg", size: 16,
                                      fallbackSystemImage: "server.rack")
                        Text(verbatim: connection.displayName.isEmpty
                             ? L10n.string("New Connection") : connection.displayName)
                            .lineLimit(1)
                    }
                }
            }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let connection = feature.selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    summary(connection)
                        .padding(.bottom, 12)
                    LitheSettingsSection("Connection") {
                        LitheSettingsRow("Name") {
                            textField("Name", text: binding(\.name), prompt: connection.displayName)
                        }
                        LitheSettingsRow("Host", info: "A host name, an IP address, or a Host alias from ~/.ssh/config. Settings from that file, such as ProxyJump and IdentityFile, still apply.") {
                            textField("Host", text: binding(\.host), prompt: "devbox.example.com")
                        }
                        LitheSettingsRow("Port", info: "Leave empty to use the port from ~/.ssh/config, or 22.") {
                            numberField("Port", value: binding(\.port), prompt: "22", width: 90)
                        }
                        LitheSettingsRow("User name", info: "Leave empty to use the user from ~/.ssh/config, or your local user name.") {
                            textField("User name", text: binding(\.user), prompt: "")
                        }
                    }
                    authenticationSection(connection)
                    LitheSettingsSection("Remote Project") {
                        LitheSettingsRow("Remote folder", info: "The project folder on the host; empty uses the home directory. Browse connects, installs the Lithe server on the host if needed, and lets you pick a folder.") {
                            textField("Remote folder", text: binding(\.remoteDirectory),
                                      prompt: connection.lastKnownHost?.homeDirectory ?? "~")
                            Button(LocalizedStringKey("Browse…")) { feature.browseRemoteFolder() }
                                .buttonStyle(LitheActionButtonStyle())
                                .disabled(!feature.canConnect || connection.problem != nil
                                          || feature.selectionTestState == .testing)
                        }
                    }
                    hostSection(connection)
                    advancedSection
                    if let error = feature.saveError {
                        notice(error, systemImage: "exclamationmark.triangle.fill", color: LitheTheme.error)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome(alwaysShowVertical: false, usesCompactScrollers: true)
        } else {
            VStack(spacing: 12) {
                LitheIDEAIcon(resourcePath: "expui/webReferences/server.svg", size: 32, fallbackSystemImage: "server.rack")
                Text(LocalizedStringKey("No SSH connections yet."))
                    .foregroundStyle(LitheTheme.secondaryText)
                Button(LocalizedStringKey("New SSH Connection")) { feature.addConnection() }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Name, address, state of the last check, and the test action.
    @ViewBuilder private func summary(_ connection: RemoteSSHConnection) -> some View {
        let state = feature.selectionTestState
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LitheIDEAIcon(resourcePath: "expui/webReferences/server.svg", size: 24, fallbackSystemImage: "server.rack")
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(LitheTheme.settingsPill))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: connection.displayName.isEmpty ? L10n.string("New Connection") : connection.displayName)
                        .font(LitheTheme.uiFont(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: Self.address(of: connection))
                        .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                statusPill(connection, state: state)
                if state == .testing {
                    Button(LocalizedStringKey("Stop")) { feature.cancelTest() }
                        .buttonStyle(LitheActionButtonStyle())
                } else {
                    Button(LocalizedStringKey("Test Connection")) { feature.testSelection() }
                        .buttonStyle(LitheActionButtonStyle())
                        .disabled(connection.problem != nil)
                }
            }
            if let problem = connection.problem {
                Text(verbatim: problem.message)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            switch state {
            case .finished(let result) where result.status != .connected:
                failure(Self.summary(of: result), diagnostics: result.diagnostics,
                        isWarning: result.status == .unsupportedPlatform)
            case .failed(let message):
                failure(message, diagnostics: "", isWarning: false)
            default:
                EmptyView()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LitheTheme.settingsCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LitheTheme.settingsCardRing, lineWidth: 0.5))
    }

    @ViewBuilder private func statusPill(_ connection: RemoteSSHConnection, state: RemoteConnectionsFeatureModel.TestState) -> some View {
        switch state {
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey("Connecting…")).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
            }
        case .finished(let result) where result.status == .connected:
            LitheSettingsPill("Connected", kind: .effect)
        case .finished, .failed:
            LitheSettingsPill("Failed", kind: .neutral)
        case .idle:
            if let checked = connection.lastKnownHost?.checkedAt {
                LitheSettingsPill(verbatim: String(format: L10n.string("Checked %@"),
                                                   checked.formatted(.relative(presentation: .named))))
            } else {
                LitheSettingsPill("Not tested")
            }
        }
    }

    private func failure(_ message: String, diagnostics: String, isWarning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(isWarning ? LitheTheme.warning : LitheTheme.error)
                Text(verbatim: message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !diagnostics.isEmpty {
                Text(verbatim: diagnostics)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(.leading, 24)
            }
        }
        .font(LitheTheme.uiFont(size: 12))
    }

    @ViewBuilder private func authenticationSection(_ connection: RemoteSSHConnection) -> some View {
        LitheSettingsSection("Authentication") {
            LitheSettingsRow("Method", info: "Automatic tries your SSH agent and keys first, then asks for a password. Lithe asks in a dialog whenever the server needs an answer, such as a password, a passphrase, or a verification code.") {
                LitheSettingsSelect(
                    selection: binding(\.authentication),
                    options: RemoteSSHAuthentication.allCases,
                    width: 220,
                    accessibilityLabel: "Authentication",
                    title: Self.title(of:)
                )
            }
            if connection.authentication == .privateKey {
                LitheSettingsRow("Private key") {
                    textField("Private key", text: binding(\.identityFile), prompt: "~/.ssh/id_ed25519")
                    Button { chooseIdentityFile(startingAt: connection.identityFile) } label: {
                        Image(systemName: "folder")
                    }
                    .litheIconButton()
                    .help(Text(LocalizedStringKey("Choose…")))
                }
            }
            if connection.usesSecret {
                let title = connection.authentication == .password ? "Password" : "Passphrase"
                LitheSettingsRow(LocalizedStringKey(title), info: "Without Remember in Keychain, Lithe asks every time it connects. A remembered secret is answered only the first time the server asks for it; if it is rejected, Lithe asks you.") {
                    LitheTextField(
                        feature.hasRememberedSecret ? "Saved in Keychain" : "",
                        text: Binding(get: { feature.secretDraft }, set: { feature.secretDraft = $0 }),
                        secure: true
                    )
                    .frame(maxWidth: 200)
                    .accessibilityLabel(Text(LocalizedStringKey(title)))
                    LitheSettingsCheckbox(isOn: binding(\.remembersSecret), title: "Remember in Keychain")
                }
            }
        }
    }

    /// Facts from the last successful check, shown without reconnecting.
    @ViewBuilder private func hostSection(_ connection: RemoteSSHConnection) -> some View {
        LitheSettingsSection(title: "Host", accessory: {
            if let checked = connection.lastKnownHost?.checkedAt {
                Text(verbatim: checked.formatted(date: .abbreviated, time: .shortened))
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }) {
            if let host = connection.lastKnownHost {
                let details = host.details
                LitheSettingsRow("Operating system") {
                    Text(verbatim: details.operatingSystem ?? host.system)
                } badges: {
                    LitheSettingsPill(verbatim: host.machine, kind: .value)
                }
                if let kernel = details.kernel {
                    LitheSettingsRow("Kernel") { Text(verbatim: kernel) }
                }
                if let name = details.hostName {
                    LitheSettingsRow("Host name") { Text(verbatim: name).textSelection(.enabled) }
                }
                if details.cpuCount != nil || details.memoryBytes != nil {
                    LitheSettingsRow("Resources") {
                        if let cpus = details.cpuCount {
                            LitheSettingsPill(verbatim: String(format: L10n.string("%lld CPU cores"), cpus), kind: .value)
                        }
                        if let memory = details.memoryBytes {
                            LitheSettingsPill(verbatim: String(format: L10n.string("%@ memory"), Self.bytes(memory)), kind: .value)
                        }
                    }
                }
                if let total = details.diskTotalBytes {
                    LitheSettingsRow("Disk", info: "The file system that holds the home directory.") {
                        Text(verbatim: String(format: L10n.string("%@ free of %@"),
                                              Self.bytes(details.diskAvailableBytes ?? 0), Self.bytes(total)))
                    }
                }
                if let uptime = details.uptimeSeconds {
                    LitheSettingsRow("Uptime") { Text(verbatim: Self.duration(uptime)) }
                }
                if let home = host.homeDirectory {
                    LitheSettingsRow("Home directory") { Text(verbatim: home).textSelection(.enabled) }
                }
                if let address = host.address {
                    LitheSettingsRow("Address", info: "Looking up the location sends this address to ipinfo.io. Lithe does this only when you click Look Up.") {
                        Text(verbatim: address).font(LitheTheme.uiFont(size: 12.5, design: .monospaced)).textSelection(.enabled)
                        if let location = host.location {
                            LitheSettingsPill(verbatim: Self.place(of: location), kind: .neutral)
                        }
                    } badges: {
                        if feature.isLocating {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(LocalizedStringKey(host.location == nil ? "Look Up Location" : "Look Up Again")) {
                                feature.locateSelectedHost()
                            }
                            .buttonStyle(LitheActionButtonStyle())
                        }
                    }
                }
                if let error = feature.locationError {
                    Text(verbatim: error).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.warning)
                }
            } else {
                Text(LocalizedStringKey("Test the connection to see the host's system, resources, and address."))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.vertical, 6)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                feature.showsAdvancedSettings.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(feature.showsAdvancedSettings ? 90 : 0))
                    Text(LocalizedStringKey("Advanced Settings"))
                        .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            if feature.showsAdvancedSettings {
                LitheSettingsCard {
                    LitheSettingsRow("Connection timeout", info: "Seconds to wait for the server to answer. Leave empty for 15 seconds.") {
                        numberField("Connection timeout", value: binding(\.connectTimeoutSeconds), prompt: "15", width: 90)
                    }
                    LitheSettingsRow("Keep-alive interval", info: "Seconds between keep-alive messages, which detect a dropped network. Leave empty for 15 seconds.") {
                        numberField("Keep-alive interval", value: binding(\.keepAliveSeconds), prompt: "15", width: 90)
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private static func address(of connection: RemoteSSHConnection) -> String {
        let host = connection.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return L10n.string("No host yet") }
        let user = connection.user.trimmingCharacters(in: .whitespaces)
        let target = user.isEmpty ? host : "\(user)@\(host)"
        return connection.port.map { "\(target):\($0)" } ?? target
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    private static func duration(_ seconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    private static func place(of location: RemoteHostLocation) -> String {
        if location.isPrivate { return L10n.string("Private network") }
        let country = location.country.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? location.country
        let place = [country, location.region, location.city]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
        return [place, location.organization].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
    }

    private static func summary(of result: RemoteProbeResult) -> String {
        switch result.status {
        case .connected:
            L10n.string("Connected. This host can be used for remote development.")
        case .unsupportedPlatform:
            L10n.string("Connected, but Lithe cannot run on this platform yet. Linux on x86_64 or ARM64 is supported.")
        case .authenticationFailed:
            L10n.string("The server rejected the credentials. Check the user name and the authentication method.")
        case .hostKeyRejected:
            L10n.string("The host key was not accepted. If the server was reinstalled, remove its old entry from ~/.ssh/known_hosts.")
        case .unreachable:
            L10n.string("The host could not be reached. Check the host name, the port, and your network.")
        case .failed:
            L10n.string("The connection failed.")
        }
    }

    private static func title(of authentication: RemoteSSHAuthentication) -> String {
        switch authentication {
        case .auto: "Automatic"
        case .agent: "SSH Agent"
        case .privateKey: "Private Key"
        case .password: "Password"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            Spacer()
            Button(LocalizedStringKey("Cancel")) { dismiss() }
                .buttonStyle(LitheActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(LocalizedStringKey("Save")) {
                if feature.save() { dismiss() }
            }
            .buttonStyle(LitheActionButtonStyle())
            .disabled(!feature.canSave)
            Button(LocalizedStringKey("Open")) { feature.openSelection() }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!feature.canSave || !feature.canConnect || feature.selection?.problem != nil
                          || feature.selection == nil)
                .help(Text(LocalizedStringKey("Saves, connects, and opens the remote folder in this window.")))
        }
        .padding(14)
        .background(LitheTheme.toolHeader)
    }

    // MARK: Building blocks

    private func binding<Value>(_ keyPath: WritableKeyPath<RemoteSSHConnection, Value>) -> Binding<Value> {
        Binding(
            get: { feature.selection![keyPath: keyPath] },
            set: { value in feature.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func textField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        LitheTextField(verbatim: prompt, text: text)
            .frame(maxWidth: Self.fieldWidth)
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    /// An optional whole number; an empty field is `nil`.
    private func numberField(_ label: String, value: Binding<Int?>, prompt: String, width: CGFloat) -> some View {
        LitheTextField(
            verbatim: prompt,
            text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { text in
                    let digits = text.filter(\.isNumber)
                    value.wrappedValue = digits.isEmpty ? nil : Int(digits.prefix(6))
                }
            )
        )
        .frame(width: width)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .modifier(RemoteNoticeChrome())
    }

    private func chooseIdentityFile(startingAt path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = L10n.string("Choose")
        let start = (path.isEmpty ? "~/.ssh" : (path as NSString).deletingLastPathComponent)
        panel.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        feature.update { $0.identityFile = (url.path as NSString).abbreviatingWithTildeInPath }
    }
}

/// Shrinks a sheet's preferred size to fit inside the window presenting it.
enum ParentWindowFit {
    /// Space kept around the sheet so it never reaches past its parent window.
    private static let margin: CGFloat = 40

    static func size(preferred: CGSize, minimum: CGSize) -> CGSize {
        guard let parent = NSApp.keyWindow?.contentLayoutRect.size else { return preferred }
        return CGSize(
            width: min(preferred.width, max(minimum.width, parent.width - margin)),
            height: min(preferred.height, max(minimum.height, parent.height - margin))
        )
    }
}

/// Picks a project folder on a connected host.
private struct RemoteFolderBrowserView: View {
    @ObservedObject var feature: RemoteConnectionsFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let browser = feature.browser {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey("Choose Remote Folder")).font(LitheTheme.uiFont(.headline))
                    Spacer()
                    Text(verbatim: [browser.session.userName, browser.session.hostName]
                        .compactMap { $0 }.joined(separator: "@"))
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                RemoteFolderListing(feature: feature, browser: browser)
                HStack(spacing: LitheTheme.ActionButton.spacing) {
                    if browser.session.uploaded {
                        Text(LocalizedStringKey("The Lithe server was installed on this host."))
                            .font(LitheTheme.uiFont(size: 11.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Spacer()
                    Button(LocalizedStringKey("Cancel")) { feature.closeBrowser() }
                        .buttonStyle(LitheActionButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(LocalizedStringKey("Choose This Folder")) { feature.chooseBrowserFolder() }
                        .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(browser.isLoading)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .background(LitheTheme.window)
    }
}

/// The path bar, folder listing, and read error of a connected host's browser.
struct RemoteFolderListing: View {
    @ObservedObject var feature: RemoteConnectionsFeatureModel
    let browser: RemoteConnectionsFeatureModel.DirectoryBrowser

    var body: some View {
        FolderListing(
            path: browser.path, parentPath: browser.parentPath,
            entries: browser.sortedEntries.map { FolderListingEntry(name: $0.name, isDirectory: $0.isDirectory) },
            isLoading: browser.isLoading, error: browser.error,
            go: { feature.openBrowserPath($0) },
            enter: { name in
                if let entry = browser.entries.first(where: { $0.name == name }) { feature.openBrowserEntry(entry) }
            }
        )
    }
}

/// The path bar, folder list, and read error shared by the local and remote
/// folder browsers of the Open panel.
struct FolderListing: View {
    let path: String
    let parentPath: String?
    let entries: [FolderListingEntry]
    let isLoading: Bool
    let error: String?
    /// Lists the typed or parent path.
    let go: (String) -> Void
    /// Lists the folder named `name` inside the current path.
    let enter: (String) -> Void
    @State private var pathText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                LitheTextField(verbatim: "/", text: $pathText)
                    .onSubmit { go(pathText) }
                    .accessibilityLabel(Text(LocalizedStringKey("Path")))
                Button(LocalizedStringKey("Go")) { go(pathText) }
                    .buttonStyle(LitheActionButtonStyle())
            }
            listing
            if let error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LitheTheme.warning)
                    Text(verbatim: error).fixedSize(horizontal: false, vertical: true)
                }
                .font(LitheTheme.uiFont(size: 12))
            }
        }
        .onAppear { pathText = path }
        .onChange(of: path) { pathText = $0 }
    }

    private var listing: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let parentPath {
                    entryRow(name: "..", isDirectory: true) { go(parentPath) }
                }
                ForEach(entries) { entry in
                    entryRow(name: entry.name, isDirectory: entry.isDirectory) { enter(entry.name) }
                }
            }
            .padding(4)
        }
        .litheScrollViewChrome(alwaysShowVertical: false, usesCompactScrollers: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LitheTheme.settingsCard)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1)
            if isLoading { ProgressView().controlSize(.small) }
        }
    }

    private func entryRow(name: String, isDirectory: Bool, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                LitheIDEAIcon(
                    resourcePath: isDirectory ? "expui/nodes/folder.svg" : "fileTypes/text.svg",
                    size: 16,
                    fallbackSystemImage: isDirectory ? "folder" : "doc"
                )
                Text(verbatim: name)
                    .font(LitheTheme.uiFont(size: 12.5))
                    .foregroundStyle(isDirectory ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(!isDirectory)
    }
}

/// The question OpenSSH asked while testing a connection.
struct RemoteAuthenticationView: View {
    let prompt: RemoteAuthenticationPrompt
    let reply: (String?) -> Void
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey("SSH Authentication")).font(LitheTheme.uiFont(.headline))
            Text(verbatim: prompt.prompt)
                .font(LitheTheme.uiFont(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if prompt.attempt > 1 {
                Text(LocalizedStringKey("The server asked again. Check the previous answer."))
                    .foregroundStyle(LitheTheme.warning)
            }
            LitheTextField("", text: $answer, secure: prompt.secret)
                .accessibilityLabel(Text(LocalizedStringKey("Response")))
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button(LocalizedStringKey("Cancel")) { submit(nil) }
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey("Continue")) { submit(answer) }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func submit(_ value: String?) {
        answer = ""
        reply(value)
    }
}

private struct RemoteNoticeChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(LitheTheme.uiFont(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.settingsCard)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1)
            }
    }
}
