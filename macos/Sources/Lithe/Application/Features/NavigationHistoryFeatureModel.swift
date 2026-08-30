import Combine
import Foundation

struct EditorNavigationLocation: Hashable, Sendable {
    let url: URL
    let line: Int
    let utf16Column: Int
    let isReadOnly: Bool
    let displayPath: String?
    let virtualProviderID: String?
    /// 消费该位置时整行选中目标行（Go to Line 行为）；符号与查找导航
    /// 保持零长度光标。
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

/// Owns bounded editor-location history independently from document tabs.
/// A jump records the live departure location so caret movement since the last
/// navigation is preserved when the user returns.
@MainActor
final class NavigationHistoryFeatureModel: ObservableObject {
    @Published private(set) var backLocations: [EditorNavigationLocation] = []
    @Published private(set) var forwardLocations: [EditorNavigationLocation] = []

    private let maximumEntryCount: Int

    init(maximumEntryCount: Int = 100) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    var canNavigateBack: Bool { !backLocations.isEmpty }
    var canNavigateForward: Bool { !forwardLocations.isEmpty }

    func recordJump(
        from departure: EditorNavigationLocation?,
        to destination: EditorNavigationLocation
    ) {
        guard let departure, departure != destination else { return }
        append(departure, to: &backLocations)
        forwardLocations.removeAll()
    }

    func navigateBack(from current: EditorNavigationLocation?) -> EditorNavigationLocation? {
        guard let destination = backLocations.popLast() else { return nil }
        if let current, current != destination {
            append(current, to: &forwardLocations)
        }
        return destination
    }

    func navigateForward(from current: EditorNavigationLocation?) -> EditorNavigationLocation? {
        guard let destination = forwardLocations.popLast() else { return nil }
        if let current, current != destination {
            append(current, to: &backLocations)
        }
        return destination
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

    private func append(
        _ location: EditorNavigationLocation,
        to locations: inout [EditorNavigationLocation]
    ) {
        if locations.last != location {
            locations.append(location)
        }
        if locations.count > maximumEntryCount {
            locations.removeFirst(locations.count - maximumEntryCount)
        }
    }
}
