import Foundation

/// Owns short-lived source snapshots for the backend session that requested them.
/// A token grants access only together with the plugin, session and provider IDs.
@MainActor
final class MacKeymapImportSnapshots {
    enum Failure: Error { case expired }

    private struct Entry {
        let pluginID: String
        let sessionID: String
        let providerID: String
        let snapshot: MacKeymapImportSnapshot
    }

    private var entries: [String: Entry] = [:]

    func insert(_ snapshot: MacKeymapImportSnapshot, pluginID: String, sessionID: String, providerID: String) -> String {
        let superseded = entries.compactMap { token, entry in
            entry.pluginID == pluginID && entry.sessionID == sessionID && entry.providerID == providerID ? token : nil
        }
        for token in superseded { remove(token) }
        let token = UUID().uuidString
        entries[token] = Entry(pluginID: pluginID, sessionID: sessionID, providerID: providerID, snapshot: snapshot)
        return token
    }

    func snapshot(_ token: String, pluginID: String, sessionID: String, providerID: String) throws -> MacKeymapImportSnapshot {
        guard let entry = entries[token], entry.pluginID == pluginID,
              entry.sessionID == sessionID, entry.providerID == providerID else { throw Failure.expired }
        return entry.snapshot
    }

    func remove(_ token: String) {
        entries.removeValue(forKey: token)?.snapshot.close()
    }

    func endSession(pluginID: String, sessionID: String) {
        let tokens = entries.compactMap { token, entry in
            entry.pluginID == pluginID && entry.sessionID == sessionID ? token : nil
        }
        for token in tokens { remove(token) }
    }
}
