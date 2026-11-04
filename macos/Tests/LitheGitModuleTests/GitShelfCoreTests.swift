import Foundation
import Testing
@testable import LitheGitModule

struct GitShelfCoreTests {
    @Test func decodesSharedShelfSnapshotAndPlans() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/git/shelf-v1.json"))
        struct Fixture: Decodable {
            let capture: GitShelfSnapshot
            let cleanPlan: GitShelfPlan
            let restorePlan: GitShelfPlan
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(fixture.capture.paths == ["old.txt", "新文件.txt"])
        #expect(fixture.capture.stagedPatch == "staged patch")
        #expect(fixture.cleanPlan.layers == [.working, .staged])
        #expect(fixture.restorePlan.layers == [.staged, .working])
    }
}
