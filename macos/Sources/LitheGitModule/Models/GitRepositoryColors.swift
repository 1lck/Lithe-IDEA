import Foundation

/// One bounded page of Core's ordered repository color assignments.
package struct GitRepositoryColorPageRequest: Encodable, Sendable {
    package let offset: Int
    package let totalCount: Int
    package let repositoryIds: [String]

    package init(offset: Int, totalCount: Int, repositoryIds: [String]) {
        self.offset = offset
        self.totalCount = totalCount
        self.repositoryIds = repositoryIds
    }
}

package struct GitRepositoryColorPage: Decodable, Sendable {
    package struct Assignment: Decodable, Sendable {
        package let id: String
        package let slot: Int
    }
    package let assignments: [Assignment]
    package let fallbackSlot: Int
    package let showColors: Bool
}

/// An immutable presentation cache; Core owns assignment and fallback rules.
package struct GitRepositoryColors: Sendable {
    package let slots: [String: Int]
    package let fallbackSlot: Int
    package let showColors: Bool

    package func slot(for repositoryRoot: URL) -> Int {
        slots[repositoryRoot.standardizedFileURL.path] ?? fallbackSlot
    }
}
