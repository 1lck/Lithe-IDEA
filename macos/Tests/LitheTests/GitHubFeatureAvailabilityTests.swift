import Testing
@testable import Lithe

@Suite("GitHub feature availability")
struct GitHubFeatureAvailabilityTests {
    @Test("Pull request integration is disabled without changing ordinary Git destinations")
    func pullRequestIntegrationIsUnavailable() {
        #expect(!LitheFeatureAvailability.githubPullRequests)
        #expect(!SidebarDestination.pullRequests.isAvailable)
        #expect(SidebarDestination.project.isAvailable)
        #expect(SidebarDestination.changes.isAvailable)
        #expect(SidebarDestination.search.isAvailable)
    }
}
