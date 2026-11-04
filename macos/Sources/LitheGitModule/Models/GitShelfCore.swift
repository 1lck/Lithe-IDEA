import Foundation

package struct GitShelfSnapshot: Codable, Sendable {
    package let stagedPatch: String
    package let workingPatch: String
    package let paths: [String]

    package init(stagedPatch: String, workingPatch: String, paths: [String]) {
        self.stagedPatch = stagedPatch
        self.workingPatch = workingPatch
        self.paths = paths
    }

    package init(_ entry: GitShelfEntry) {
        self.init(stagedPatch: entry.stagedPatch, workingPatch: entry.workingPatch, paths: entry.paths)
    }
}

package enum GitShelfPhase: String, Codable, Sendable { case clean, restore }
package enum GitShelfLayer: String, Codable, Sendable { case staged, working }
package struct GitShelfPlan: Decodable, Sendable {
    package let layers: [GitShelfLayer]
    package init(layers: [GitShelfLayer]) { self.layers = layers }
}
