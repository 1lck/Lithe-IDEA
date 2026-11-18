import Foundation

/// Documentation.
@MainActor
final class ViewModel: ObservableObject, Identifiable {
    @Published private(set) var count: Int = 0
    let id = UUID()
    static let limit = 0x1F

    init(count: Int = 0) {
        self.count = count
    }

    // A comment
    func increment(by step: Double = 1.5e3) async throws -> String? {
        guard count < Self.limit else { return nil }
        count += 1
        return "Count: \(count)\n"
    }
}

enum Direction { case north, south }
let closure: (Int) -> Bool = { $0 > 2 }
