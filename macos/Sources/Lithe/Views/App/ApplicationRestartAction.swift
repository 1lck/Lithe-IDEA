import SwiftUI

/// Restarts Lithe through the normal quit confirmations, like IntelliJ IDEA's
/// "Restart IDE" after plugin changes. The app scene injects it; previews and
/// tests leave it nil and the restart button is hidden.
struct ApplicationRestartAction {
    let perform: @MainActor () -> Void

    @MainActor func callAsFunction() { perform() }
}

private struct ApplicationRestartActionKey: EnvironmentKey {
    static let defaultValue: ApplicationRestartAction? = nil
}

extension EnvironmentValues {
    var restartApplication: ApplicationRestartAction? {
        get { self[ApplicationRestartActionKey.self] }
        set { self[ApplicationRestartActionKey.self] = newValue }
    }
}

/// "Restart Lithe" button shown wherever a plugin change waits for a restart.
struct RestartLitheButton: View {
    @Environment(\.restartApplication) private var restartApplication
    var prominent = true

    var body: some View {
        if let restartApplication {
            if prominent {
                Button(LocalizedStringKey("Restart Lithe")) { restartApplication() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button(LocalizedStringKey("Restart Lithe")) { restartApplication() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
