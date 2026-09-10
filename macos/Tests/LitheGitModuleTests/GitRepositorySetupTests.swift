import Foundation
@testable import LitheGitModule
import Testing

struct GitRepositorySetupTests {
    @Test
    func sharedFixtureDistinguishesUnbornBranchFromMissingRepositoryAndInheritedIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/git/repository-setup-v1.json"))
        struct Fixture: Decodable {
            let uninitialized: GitRepositorySetup
            let unborn: GitRepositorySetup
            let configured: GitRepositorySetup
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(!fixture.uninitialized.isRepository)
        #expect(fixture.unborn.isRepository && !fixture.unborn.hasCommits)
        #expect(fixture.unborn.branch == "fixture-branch")
        #expect(fixture.unborn.configuredName == nil)
        #expect(!fixture.unborn.needsIdentity)
        #expect(fixture.configured.configuredEmail == "local@example.invalid")
        #expect(fixture.configured.hasCommits)
    }
}
