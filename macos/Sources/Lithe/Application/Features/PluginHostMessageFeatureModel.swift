import Combine
import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

enum PluginHostMessageSeverity: String, Equatable, Sendable {
    case information
    case warning
    case error
}

/// Why a message ended without the user choosing one of its buttons.
enum PluginHostMessageDismissal: Equatable, Sendable {
    /// The user closed the message.
    case user
    /// The window closed while the message was showing or waiting.
    case windowClosed
    /// The window opened another workspace.
    case workspaceChanged
    /// The plugin's call was cancelled.
    case cancelled
}

enum PluginHostMessageOutcome: Equatable, Sendable {
    /// Index into the request's buttons.
    case selected(index: Int)
    case dismissed(PluginHostMessageDismissal)
}

/// A plugin message as shown. Text and button titles are the plugin's own
/// words and are never translated or rewritten by the host.
struct PluginHostMessageEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let pluginID: String
    let pluginName: String
    let severity: PluginHostMessageSeverity
    let text: String
    let actions: [String]
    let workspaceGeneration: Int
}

/// The plugin message surface of one window.
///
/// Plugin text must be shown verbatim, which the host notification stack
/// does not do (it translates its text and keys), so plugin messages live
/// here. Up to `visibleLimit` messages show at once; the rest wait in order.
/// Every presented message ends exactly once, with the user's choice or a
/// dismissal.
@MainActor
final class PluginHostMessageFeatureModel: ObservableObject {
    static let visibleLimit = 3
    /// Bound for cancellations that arrive before their message registers.
    private static let cancelledBeforePresentLimit = 64

    @Published private(set) var visible: [PluginHostMessageEntry] = []
    @Published private(set) var queued: [PluginHostMessageEntry] = []
    private var continuations: [UUID: CheckedContinuation<PluginHostMessageOutcome, Never>] = [:]
    private var cancelledBeforePresent: Set<UUID> = []

    /// Messages showing or waiting.
    var pendingCount: Int { visible.count + queued.count }

    func pendingCount(forPlugin pluginID: String) -> Int {
        (visible + queued).filter { $0.pluginID == pluginID }.count
    }

    /// Shows `entry` (or queues it) and waits until the user answers or the
    /// message is dismissed. A cancelled caller dismisses its own message.
    func present(_ entry: PluginHostMessageEntry) async -> PluginHostMessageOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PluginHostMessageOutcome, Never>) in
                if cancelledBeforePresent.remove(entry.id) != nil || Task.isCancelled {
                    continuation.resume(returning: .dismissed(.cancelled))
                    return
                }
                continuations[entry.id] = continuation
                if visible.count < Self.visibleLimit {
                    visible.append(entry)
                } else {
                    queued.append(entry)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPresentation(of: entry.id) }
        }
    }

    /// The user pressed button `index` of a showing message.
    func choose(_ id: UUID, index: Int) {
        guard let entry = visible.first(where: { $0.id == id }),
              entry.actions.indices.contains(index) else { return }
        finish(id, with: .selected(index: index))
    }

    /// The user closed a showing message.
    func dismiss(_ id: UUID) {
        guard visible.contains(where: { $0.id == id }) else { return }
        finish(id, with: .dismissed(.user))
    }

    /// Ends every showing and waiting message, for a closing window or a
    /// replaced workspace.
    func dismissAll(_ reason: PluginHostMessageDismissal) {
        let ids = (visible + queued).map(\.id)
        visible = []
        queued = []
        for id in ids { continuations.removeValue(forKey: id)?.resume(returning: .dismissed(reason)) }
    }

    private func cancelPresentation(of id: UUID) {
        guard continuations[id] != nil else {
            // The caller was cancelled before its message registered. Remember
            // it so the message is not shown for a call that is already gone.
            if cancelledBeforePresent.count >= Self.cancelledBeforePresentLimit { cancelledBeforePresent.removeAll() }
            cancelledBeforePresent.insert(id)
            return
        }
        finish(id, with: .dismissed(.cancelled))
    }

    private func finish(_ id: UUID, with outcome: PluginHostMessageOutcome) {
        visible.removeAll { $0.id == id }
        queued.removeAll { $0.id == id }
        continuations.removeValue(forKey: id)?.resume(returning: outcome)
        promoteQueued()
    }

    private func promoteQueued() {
        while visible.count < Self.visibleLimit, !queued.isEmpty {
            visible.append(queued.removeFirst())
        }
    }
}
