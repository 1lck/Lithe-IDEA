import Combine
import LitheLocalHistoryModule

/// Owns storage feedback for the settings page, including failed clears and retries.
@MainActor
final class LocalHistoryStorageSettingsModel: ObservableObject {
    @Published private(set) var usage: LocalHistoryUsage?
    @Published private(set) var isClearing = false
    @Published private(set) var clearFailed = false

    func refreshUsage(using readUsage: @MainActor () async -> LocalHistoryUsage?) async {
        usage = await readUsage()
    }

    func clear(
        using clearHistory: @MainActor () async -> Bool,
        readUsage: @MainActor () async -> LocalHistoryUsage?
    ) async {
        guard !isClearing else { return }
        isClearing = true
        clearFailed = false
        defer { isClearing = false }
        let cleared = await clearHistory()
        await refreshUsage(using: readUsage)
        clearFailed = !cleared
    }
}
