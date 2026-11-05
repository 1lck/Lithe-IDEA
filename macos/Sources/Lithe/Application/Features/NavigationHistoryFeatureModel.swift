import Combine
import Foundation
import LitheModuleAPI

struct EditorNavigationLocation: Hashable, Sendable {
    let url: URL
    let line: Int
    let utf16Column: Int
    let isReadOnly: Bool
    let displayPath: String?
    let virtualProviderID: String?
    /// Consume the location with the whole target line selected (Go to Line);
    /// symbol and find navigation keep a zero-length caret.
    let selectsWholeLine: Bool

    init(
        url: URL,
        line: Int,
        utf16Column: Int,
        isReadOnly: Bool = false,
        displayPath: String? = nil,
        virtualProviderID: String? = nil,
        selectsWholeLine: Bool = false
    ) {
        self.url = url.isFileURL ? url.standardizedFileURL : url
        self.line = max(0, line)
        self.utf16Column = max(0, utf16Column)
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
        self.virtualProviderID = virtualProviderID
        self.selectsWholeLine = selectsWholeLine
    }
}

struct NavigationHistorySnapshot: Equatable, Sendable {
    let backLocations: [EditorNavigationLocation]
    let forwardLocations: [EditorNavigationLocation]
}

/// Holds editor-location history independently from document tabs. Rust Core
/// (`editor.navigationHistory.reduce`) owns the stack rules: departure
/// recording, deduplication, branch truncation, capacity and skipping entries
/// equal to the live location. A jump records the live departure location so
/// caret movement since the last navigation is preserved when the user returns.
@MainActor
final class NavigationHistoryFeatureModel: ObservableObject {
    @Published private(set) var backLocations: [EditorNavigationLocation] = []
    @Published private(set) var forwardLocations: [EditorNavigationLocation] = []

    private let logSink: (any LogSink)?

    init(logSink: (any LogSink)?) {
        self.logSink = logSink
    }

    var canNavigateBack: Bool { !backLocations.isEmpty }
    var canNavigateForward: Bool { !forwardLocations.isEmpty }

    func recordJump(
        from departure: EditorNavigationLocation?,
        to destination: EditorNavigationLocation
    ) {
        _ = reduce(.record(departure: departure.map(CoreLocation.init), destination: CoreLocation(destination)))
    }

    func navigateBack(from current: EditorNavigationLocation?) -> EditorNavigationLocation? {
        reduce(.back(current: current.map(CoreLocation.init)))
    }

    func navigateForward(from current: EditorNavigationLocation?) -> EditorNavigationLocation? {
        reduce(.forward(current: current.map(CoreLocation.init)))
    }

    func reset() {
        backLocations.removeAll()
        forwardLocations.removeAll()
    }

    func snapshot() -> NavigationHistorySnapshot {
        NavigationHistorySnapshot(
            backLocations: backLocations,
            forwardLocations: forwardLocations
        )
    }

    func restore(_ snapshot: NavigationHistorySnapshot) {
        backLocations = snapshot.backLocations
        forwardLocations = snapshot.forwardLocations
    }

    /// Applies one Core transition and returns the location to open, if any.
    /// A Core failure leaves history unchanged and is logged.
    private func reduce(_ event: CoreEvent) -> EditorNavigationLocation? {
        struct Request: Encodable { let state: CoreState; let event: CoreEvent }
        struct Response: Decodable { let state: CoreState; let destination: CoreLocation? }
        let state = CoreState(
            back: backLocations.map(CoreLocation.init),
            forward: forwardLocations.map(CoreLocation.init)
        )
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "editor.navigationHistory.reduce", payload: Request(state: state, event: event))
        switch result {
        case .success(let response):
            guard let back = response.state.back.editorLocations,
                  let forward = response.state.forward.editorLocations else {
                logSink?.emit(AppCoreFallbackSelected(
                    error: LogFailure(domain: "RustCore", code: "invalid_location"),
                    stage: "editor.navigationHistory.reduce"))
                return nil
            }
            backLocations = back
            forwardLocations = forward
            return response.destination?.editorLocation
        case .failure(let error):
            logSink?.emit(AppCoreFallbackSelected(
                error: LogFailure(domain: "RustCore", code: error.code),
                stage: "editor.navigationHistory.reduce"))
            return nil
        }
    }
}

/// Wire form of one history location. Core compares `document`, `line` and
/// `column`; `context` carries the macOS presentation fields unchanged.
private struct CoreLocation: Codable {
    struct Context: Codable {
        let isReadOnly: Bool
        let displayPath: String?
        let virtualProviderID: String?
        let selectsWholeLine: Bool
    }

    let document: String
    let line: Int
    let column: Int
    let context: Context?

    init(_ location: EditorNavigationLocation) {
        document = location.url.absoluteString
        line = location.line
        column = location.utf16Column
        context = Context(
            isReadOnly: location.isReadOnly,
            displayPath: location.displayPath,
            virtualProviderID: location.virtualProviderID,
            selectsWholeLine: location.selectsWholeLine
        )
    }

    var editorLocation: EditorNavigationLocation? {
        guard let url = URL(string: document) else { return nil }
        return EditorNavigationLocation(
            url: url,
            line: line,
            utf16Column: column,
            isReadOnly: context?.isReadOnly ?? false,
            displayPath: context?.displayPath,
            virtualProviderID: context?.virtualProviderID,
            selectsWholeLine: context?.selectsWholeLine ?? false
        )
    }
}

private struct CoreState: Codable {
    let back: [CoreLocation]
    let forward: [CoreLocation]
}

private enum CoreEvent: Encodable {
    case record(departure: CoreLocation?, destination: CoreLocation)
    case back(current: CoreLocation?)
    case forward(current: CoreLocation?)

    private enum CodingKeys: String, CodingKey { case type, departure, destination, current }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .record(departure, destination):
            try container.encode("record", forKey: .type)
            try container.encode(departure, forKey: .departure)
            try container.encode(destination, forKey: .destination)
        case let .back(current):
            try container.encode("back", forKey: .type)
            try container.encode(current, forKey: .current)
        case let .forward(current):
            try container.encode("forward", forKey: .type)
            try container.encode(current, forKey: .current)
        }
    }
}

private extension Array where Element == CoreLocation {
    var editorLocations: [EditorNavigationLocation]? {
        var locations: [EditorNavigationLocation] = []
        locations.reserveCapacity(count)
        for element in self {
            guard let location = element.editorLocation else { return nil }
            locations.append(location)
        }
        return locations
    }
}
