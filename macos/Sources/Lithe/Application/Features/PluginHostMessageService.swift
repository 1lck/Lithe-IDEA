import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

struct PluginHostMessageRequest: Equatable, Sendable {
    let context: PluginHostCallContext
    let severity: PluginHostMessageSeverity
    /// Shown as written; the host does not translate or rewrite it.
    let text: String
    /// Button titles, shown as written. The answer is an index into this list.
    let actions: [String]

    init(context: PluginHostCallContext, severity: PluginHostMessageSeverity, text: String, actions: [String] = []) {
        self.context = context
        self.severity = severity
        self.text = text
        self.actions = actions
    }
}

struct PluginHostMessageLimits: Equatable, Sendable {
    /// Messages one plugin may send to one window within `interval`.
    var maxRequestsPerInterval = 5
    var interval: TimeInterval = 10
    /// Messages of one plugin showing or waiting in one window.
    var maxPendingPerPlugin = 3
    /// Messages of all plugins showing or waiting in one window.
    var maxPendingPerWindow = 10
    var maxTextLength = 2000
    var maxActions = 3
    var maxActionLength = 40
}

/// Counts requests per key over a sliding window. The caller supplies the
/// time, so tests run without sleeping.
struct PluginHostRateLimiter {
    enum Admission: Equatable {
        case allowed
        /// `shouldNotify` is true for the first denial in a window, so the
        /// user hears about a flood once rather than once per message.
        case denied(shouldNotify: Bool)
    }

    private var requests: [String: [TimeInterval]] = [:]
    private var lastNotice: [String: TimeInterval] = [:]
    private let maxRequests: Int
    private let interval: TimeInterval

    init(maxRequests: Int, interval: TimeInterval) {
        self.maxRequests = maxRequests
        self.interval = interval
    }

    mutating func admit(key: String, now: TimeInterval) -> Admission {
        prune(now: now)
        var recent = requests[key] ?? []
        guard recent.count < maxRequests else {
            requests[key] = recent
            let noticed = lastNotice[key].map { now - $0 < interval } ?? false
            if !noticed { lastNotice[key] = now }
            return .denied(shouldNotify: !noticed)
        }
        recent.append(now)
        requests[key] = recent
        return .allowed
    }

    private mutating func prune(now: TimeInterval) {
        for (key, times) in requests {
            let live = times.filter { now - $0 < interval }
            if live.isEmpty { requests[key] = nil } else { requests[key] = live }
        }
        for (key, time) in lastNotice where now - time >= interval { lastNotice[key] = nil }
    }
}

/// `window.showInformation`, `showWarning` and `showError`.
///
/// A message belongs to one window, so it shows there even when the user is
/// working in another one, and ends when that window closes. A plugin gets
/// a bounded number of messages: a request over the rate or the queue limit
/// is refused, and the user is told once that the plugin was throttled.
@MainActor
final class PluginHostMessageService {
    private let gate: PluginHostScopeGate
    private let limits: PluginHostMessageLimits
    private let now: @MainActor () -> TimeInterval
    private var limiter: PluginHostRateLimiter

    init(
        directory: any PluginHostWindowDirectory,
        limits: PluginHostMessageLimits = PluginHostMessageLimits(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        gate = PluginHostScopeGate(directory: directory)
        self.limits = limits
        self.now = now
        limiter = PluginHostRateLimiter(maxRequests: limits.maxRequestsPerInterval, interval: limits.interval)
    }

    /// Shows the message and waits for the user's choice or a dismissal.
    func show(_ request: PluginHostMessageRequest) async throws -> PluginHostMessageOutcome {
        try validate(request)
        let scope = try gate.enter(request.context)
        let caller = request.context.caller
        let key = "\(caller.pluginID)\n\(request.context.windowID.uuidString)"
        if case .denied(let shouldNotify) = limiter.admit(key: key, now: now()) {
            if shouldNotify { scope.port.hostNoteMessageLimit(pluginName: caller.pluginName) }
            throw PluginHostError.rateLimited
        }
        let center = scope.port.hostMessages
        guard center.pendingCount(forPlugin: caller.pluginID) < limits.maxPendingPerPlugin,
              center.pendingCount < limits.maxPendingPerWindow else {
            throw PluginHostError.messageQueueFull
        }
        let entry = PluginHostMessageEntry(
            id: UUID(), pluginID: caller.pluginID, pluginName: caller.pluginName,
            severity: request.severity, text: request.text, actions: request.actions,
            workspaceGeneration: scope.snapshot.workspaceGeneration
        )
        return await center.present(entry)
    }

    private func validate(_ request: PluginHostMessageRequest) throws {
        let text = request.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= limits.maxTextLength,
              !Self.hasControlCharacters(text, allowing: ["\n", "\t"]),
              request.actions.count <= limits.maxActions else {
            throw PluginHostError.invalidMessage
        }
        for action in request.actions {
            guard !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  action.count <= limits.maxActionLength,
                  !Self.hasControlCharacters(action, allowing: []) else {
                throw PluginHostError.invalidMessage
            }
        }
    }

    private static func hasControlCharacters(_ text: String, allowing allowed: Set<Unicode.Scalar>) -> Bool {
        text.unicodeScalars.contains { ($0.value < 0x20 || $0.value == 0x7f) && !allowed.contains($0) }
    }
}
