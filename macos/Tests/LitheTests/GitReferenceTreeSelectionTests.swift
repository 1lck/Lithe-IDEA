import Testing
@testable import Lithe
import LitheGitModule

@Suite("Git reference tree selection")
struct GitReferenceTreeSelectionTests {
    @Test(arguments: [false, true], [false, true])
    func headAndCurrentBranchNeverShareSelection(headSelected: Bool, showingAll: Bool) {
        let current = GitReference(fullName: "refs/heads/main", shortName: "main",
                                   kind: .local, isCurrent: true, upstreamShortName: nil)
        for selectedID in [nil, current.id] {
            let head = GitReferenceTreeSelection.isSelected(
                isHead: true, headSelected: headSelected, reference: current,
                selectedReferenceID: selectedID, showingAll: showingAll)
            let branch = GitReferenceTreeSelection.isSelected(
                isHead: false, headSelected: headSelected, reference: current,
                selectedReferenceID: selectedID, showingAll: showingAll)
            #expect(head == (!showingAll && headSelected))
            #expect(branch == (!showingAll && !headSelected))
            #expect(!(head && branch))
        }
    }

    @Test
    func selectingAnotherBranchDoesNotHighlightCurrentOrHead() {
        let current = GitReference(fullName: "refs/heads/main", shortName: "main",
                                   kind: .local, isCurrent: true, upstreamShortName: nil)
        let other = GitReference(fullName: "refs/heads/feature", shortName: "feature",
                                 kind: .local, isCurrent: false, upstreamShortName: nil)
        #expect(GitReferenceTreeSelection.isSelected(isHead: false, headSelected: false, reference: other,
                                                     selectedReferenceID: other.id, showingAll: false))
        #expect(!GitReferenceTreeSelection.isSelected(isHead: false, headSelected: false, reference: current,
                                                      selectedReferenceID: other.id, showingAll: false))
        #expect(!GitReferenceTreeSelection.isSelected(isHead: true, headSelected: true, reference: current,
                                                      selectedReferenceID: other.id, showingAll: false))
    }
}
