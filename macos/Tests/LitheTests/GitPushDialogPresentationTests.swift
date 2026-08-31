@testable import Lithe
@testable import LitheGitModule
import Testing

struct GitPushDialogPresentationTests {
    @Test
    func branchWithoutUpstreamOffersPublication() {
        let reference = GitReference(
            fullName: "refs/heads/feature/recent",
            shortName: "feature/recent",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )

        let presentation = GitPushDialogPresentation(reference: reference)

        #expect(presentation.destination == "Publish feature/recent (Core selects default remote)")
        #expect(presentation.actionTitle == "Publish Branch")
    }

    @Test
    func trackedBranchKeepsItsConfiguredDestination() {
        let reference = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: "upstream/stable"
        )

        let presentation = GitPushDialogPresentation(reference: reference)

        #expect(presentation.destination == "Tracking upstream/stable")
        #expect(presentation.actionTitle == "Push")
    }
}
