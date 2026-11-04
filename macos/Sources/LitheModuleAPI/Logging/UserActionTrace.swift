import Foundation

/// The UI surface that invoked a user action, written as the catalog token.
public enum UserActionSurface: String, Sendable {
    case menu, shortcut, palette, toolbar, button, contextMenu = "context_menu", notification, plugin
}

/// One user-started action. `operationID` becomes the `op` of the action line and
/// of every Core request and Git process the action causes.
public struct UserAction: Sendable {
    public let id: String
    public let surface: UserActionSurface
    public let operationID: String
    public let startedAt: ContinuousClock.Instant

    public init(id: String, surface: UserActionSurface, operationID: String = UUID().uuidString,
        startedAt: ContinuousClock.Instant = .now) {
        self.id = id
        self.surface = surface
        self.operationID = operationID
        self.startedAt = startedAt
    }
}

public enum UserActionContext {
    /// `Task {}` inherits this value; `Task.detached` and GCD hops do not, so
    /// detached work that serves the action must start through `detached`.
    @TaskLocal public static var current: UserAction?

    /// `Task.detached` that keeps the current action for Core request origins.
    @discardableResult
    public static func detached<T: Sendable>(priority: TaskPriority? = nil,
        operation: sending @escaping () async -> T) -> Task<T, Never> {
        let action = current
        return Task.detached(priority: priority) { await $current.withValue(action) { await operation() } }
    }

    @discardableResult
    public static func detached<T: Sendable>(priority: TaskPriority? = nil,
        operation: sending @escaping () async throws -> T) -> Task<T, any Error> {
        let action = current
        return Task.detached(priority: priority) { try await $current.withValue(action) { try await operation() } }
    }

    /// `DispatchQueue.main.async` that keeps the current action, for UI that must
    /// finish dismissing a sheet or menu before the action's work starts.
    public static func mainAsync(_ body: @escaping @MainActor () -> Void) {
        let action = current
        DispatchQueue.main.async { MainActor.assumeIsolated { $current.withValue(action) { body() } } }
    }
}

/// Records the outermost UI entry point once and binds it for the work it starts.
/// Nested entry points inside an already traced action neither log nor rebind.
public enum UserActionTrace {
    /// The application log, installed once at launch for entry points that have
    /// no service container, such as AppKit menus. Tests pass their own sink.
    @MainActor public static var applicationSink: (any LogSink)?

    @discardableResult
    public static func run<T>(_ id: String, surface: UserActionSurface, sink: (any LogSink)?,
        _ body: () throws -> T) rethrows -> T {
        guard UserActionContext.current == nil else { return try body() }
        return try UserActionContext.$current.withValue(start(id, surface: surface, sink: sink), operation: body)
    }

    /// Runs on the caller's isolation, so main-actor UI work stays on the main actor.
    @discardableResult
    public static func run<T>(_ id: String, surface: UserActionSurface, sink: (any LogSink)?,
        isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        guard UserActionContext.current == nil else { return try await body() }
        return try await UserActionContext.$current.withValue(start(id, surface: surface, sink: sink)) {
            try await body()
        }
    }

    /// A traced control action for SwiftUI controls that call a model directly.
    /// `body` is a plain closure so method references and stored callbacks pass
    /// without a Sendable conversion; the returned closure runs it on the main actor.
    @MainActor
    public static func action(_ id: String, surface: UserActionSurface = .button,
        _ body: @escaping () -> Void) -> @MainActor () -> Void {
        { run(id, surface: surface, sink: applicationSink, body) }
    }

    /// Action ids are catalog tokens, never localized titles.
    public static func normalizedID(_ id: String) -> String {
        let allowed = Set("._:/-$".utf8)
        let valid = !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || allowed.contains($0)
        }
        return valid ? id : "invalid"
    }

    private static func start(_ id: String, surface: UserActionSurface, sink: (any LogSink)?) -> UserAction {
        let action = UserAction(id: normalizedID(id), surface: surface)
        sink?.emit(AppActionPerformed(action: action.id, surface: surface.rawValue, operationID: action.operationID))
        return action
    }
}
